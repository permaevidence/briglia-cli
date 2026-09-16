import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Hidden deterministic test of `PrivateStorage`: scope classification, the
/// atomic owner-only writer (mode policy, three-way symlink policy, refusals),
/// directory and append-handle creation, the startup sweep, and the doctor
/// report. Runs against throwaway XDG roots under a temp directory and never
/// touches a real installation.
struct StorageSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__storage-selftest",
        abstract: "Internal: verify private-by-default storage (modes, symlink policy, sweep).",
        shouldDisplay: false
    )

    func run() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("briglia-storage-selftest-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        // A permissive umask so "new files are 0600" is the helper's doing,
        // not the environment's.
        umask(0o022)

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func mode(_ path: String) -> Int {
            var st = stat()
            guard lstat(path, &st) == 0 else { return -1 }
            return Int(st.st_mode & 0o7777)
        }
        func octal(_ m: Int) -> String { m < 0 ? "absent" : String(m, radix: 8) }
        func isLink(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
        }
        func contents(_ path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable>"
        }
        func plant(_ path: String, _ text: String, _ m: Int) throws {
            try fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: false, encoding: .utf8)
            _ = chmod(path, mode_t(m))
        }

        let configRoot = StoragePaths.configRoot
        let dataRoot = StoragePaths.dataRoot
        let external = tempRoot.appendingPathComponent("external")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)

        // MARK: 1. Roots and classification
        print("\n[1] roots and scope classification")
        StoragePaths.ensureRoots()
        check("1.1 config root created 0700", mode(configRoot.path) == 0o700, octal(mode(configRoot.path)))
        check("1.2 data root created 0700", mode(dataRoot.path) == 0o700, octal(mode(dataRoot.path)))
        _ = chmod(dataRoot.path, 0o755)
        StoragePaths.ensureRoots()
        check("1.3 ensureRoots re-tightens a widened root", mode(dataRoot.path) == 0o700, octal(mode(dataRoot.path)))

        typealias S = PrivateStorage.Scope
        let cases: [(String, S)] = [
            (dataRoot.appendingPathComponent("conversation.json").path, .harnessState),
            (dataRoot.appendingPathComponent("reminders.json").path, .harnessState),
            (configRoot.appendingPathComponent("secrets.json").path, .harnessState),
            (configRoot.appendingPathComponent("mcp.json").path, .harnessState),
            (dataRoot.appendingPathComponent("archive/2026-01.json").path, .harnessState),
            (dataRoot.appendingPathComponent("subagent_sessions/abcde.json").path, .harnessState),
            (dataRoot.appendingPathComponent("logs/web-pipeline.log").path, .harnessState),
            (dataRoot.appendingPathComponent("reminder-scripts/state/x.json").path, .harnessState),
            (dataRoot.appendingPathComponent("reminder-scripts/daily.sh").path, .inScope),
            (dataRoot.appendingPathComponent("documents/a.pdf").path, .inScope),
            (dataRoot.appendingPathComponent("research/abcde-1.md").path, .inScope),
            (configRoot.appendingPathComponent("skills/pdf/helper.sh").path, .inScope),
            (configRoot.appendingPathComponent("agents/x.md").path, .inScope),
            (dataRoot.appendingPathComponent("projects/p/main.py").path, .outside),
            (dataRoot.appendingPathComponent("toolchain/bin/pdftotext").path, .outside),
            (external.appendingPathComponent("x").path, .outside),
            (dataRoot.path, .harnessState),
        ]
        for (path, expected) in cases {
            let got = PrivateStorage.classify(path)
            check("1.4 classify \(path.replacingOccurrences(of: tempRoot.path, with: "…")) → \(expected)", got == expected, "got \(got)")
        }
        // Classification of a path not yet on disk under a root reached via a symlinked prefix.
        let aliasRoot = tempRoot.appendingPathComponent("alias")
        symlink(tempRoot.appendingPathComponent("data").path, aliasRoot.path)
        check("1.5 classify through a symlinked root prefix",
              PrivateStorage.classify(aliasRoot.appendingPathComponent("briglia/todos.json").path) == .harnessState)
        check("1.6 isUnderRoots covers excluded areas too",
              PrivateStorage.isUnderRoots(dataRoot.appendingPathComponent("projects/x").path)
              && !PrivateStorage.isUnderRoots(external.path))

        // MARK: 2. Atomic writer mode policy
        print("\n[2] atomic writer")
        let fresh = dataRoot.appendingPathComponent("fresh.json")
        try PrivateStorage.writeAtomically(Data("{}".utf8), to: fresh)
        check("2.1 new file is 0600 under umask 022", mode(fresh.path) == 0o600, octal(mode(fresh.path)))
        check("2.2 new file content", contents(fresh.path) == "{}")
        let wide = dataRoot.appendingPathComponent("wide.json")
        try plant(wide.path, "old", 0o644)
        try PrivateStorage.writeAtomically(Data("new".utf8), to: wide)
        check("2.3 existing 0644 becomes 0600 on rewrite", mode(wide.path) == 0o600, octal(mode(wide.path)))
        check("2.4 rewrite replaced the content", contents(wide.path) == "new")
        let helper = configRoot.appendingPathComponent("skills/demo/helper.sh")
        try plant(helper.path, "#!/bin/sh\necho old\n", 0o755)
        try PrivateStorage.writeAtomically(Data("#!/bin/sh\necho new\n".utf8), to: helper)
        check("2.5 existing 0755 helper keeps owner exec, loses group/other (0700)", mode(helper.path) == 0o700, octal(mode(helper.path)))
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sh")
        run.arguments = [helper.path]
        let pipe = Pipe()
        run.standardOutput = pipe
        try run.run()
        run.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        check("2.6 rewritten helper still executes", run.terminationStatus == 0 && out == "new\n", out)
        let private700 = dataRoot.appendingPathComponent("reminder-scripts/keep.sh")
        try plant(private700.path, "a", 0o700)
        try PrivateStorage.writeAtomically(Data("b".utf8), to: private700)
        check("2.7 existing 0700 stays 0700", mode(private700.path) == 0o700, octal(mode(private700.path)))
        let explicit = dataRoot.appendingPathComponent("reminder-scripts/new.sh")
        try PrivateStorage.writeAtomically(Data("x".utf8), to: explicit, mode: 0o700)
        check("2.8 explicit mode applied to a new file", mode(explicit.path) == 0o700, octal(mode(explicit.path)))
        let leftovers = (try? fm.contentsOfDirectory(atPath: dataRoot.path))?.filter { $0.hasPrefix(".") && $0.contains(".tmp-") } ?? []
        check("2.9 no staging temp left behind", leftovers.isEmpty, leftovers.joined(separator: ","))
        let dirTarget = dataRoot.appendingPathComponent("documents")
        try fm.createDirectory(at: dirTarget, withIntermediateDirectories: true)
        var refused = false
        do { try PrivateStorage.writeAtomically(Data(), to: dirTarget) } catch { refused = true }
        check("2.10 writing over a directory is refused", refused && fm.fileExists(atPath: dirTarget.path))
        let fifo = dataRoot.appendingPathComponent("pipe")
        if mkfifo(fifo.path, 0o600) == 0 {
            refused = false
            do { try PrivateStorage.writeAtomically(Data(), to: fifo) } catch { refused = true }
            check("2.11 writing over a FIFO is refused", refused)
            unlink(fifo.path)
        }

        // MARK: 3. Symlink policy
        print("\n[3] symlink policy")
        // (i) link at a user path resolving to harness state → refused, state untouched.
        let conv = dataRoot.appendingPathComponent("conversation.json")
        try plant(conv.path, "HISTORY", 0o600)
        let evil = configRoot.appendingPathComponent("skills/evil")
        symlink(conv.path, evil.path)
        refused = false
        do { try PrivateStorage.writeAtomically(Data("pwn".utf8), to: evil) } catch { refused = true }
        check("3.1 link resolving to harness state is refused", refused)
        check("3.2 harness state untouched after the refusal", contents(conv.path) == "HISTORY" && !isLink(conv.path))
        // (i') link placed AT a harness state path → refused regardless of target.
        let extPlain = external.appendingPathComponent("plain.json")
        try plant(extPlain.path, "ext", 0o644)
        let rem = dataRoot.appendingPathComponent("reminders.json")
        symlink(extPlain.path, rem.path)
        refused = false
        do { try PrivateStorage.writeAtomically(Data("x".utf8), to: rem) } catch { refused = true }
        check("3.3 a symlink at a harness-state path is refused", refused)
        check("3.4 its external target is untouched", contents(extPlain.path) == "ext" && mode(extPlain.path) == 0o644)
        unlink(rem.path)
        // (ii) in-scope link: helper → another in-root file, 0755.
        let shared = dataRoot.appendingPathComponent("documents/shared.sh")
        try plant(shared.path, "old", 0o755)
        let link2 = configRoot.appendingPathComponent("skills/demo/link.sh")
        symlink(shared.path, link2.path)
        let written = try PrivateStorage.writeAtomically(Data("new".utf8), to: link2)
        check("3.5 in-scope link written through (target updated)", contents(shared.path) == "new" && written == PrivateStorage.canonical(shared.path))
        check("3.6 the link is still a link", isLink(link2.path))
        check("3.7 in-scope target stripped to 0700", mode(shared.path) == 0o700, octal(mode(shared.path)))
        // (iii) external target keeps its exact mode.
        let extScript = external.appendingPathComponent("script.sh")
        try plant(extScript.path, "old", 0o755)
        let link3 = configRoot.appendingPathComponent("skills/demo/ext.sh")
        symlink(extScript.path, link3.path)
        try PrivateStorage.writeAtomically(Data("new".utf8), to: link3)
        check("3.8 external target content updated through the link", contents(extScript.path) == "new")
        check("3.9 external target mode preserved exactly (0755)", mode(extScript.path) == 0o755, octal(mode(extScript.path)))
        check("3.10 external link still a link", isLink(link3.path))
        let proj = dataRoot.appendingPathComponent("projects/p/build.sh")
        try plant(proj.path, "old", 0o755)
        let link4 = configRoot.appendingPathComponent("skills/demo/proj.sh")
        symlink(proj.path, link4.path)
        try PrivateStorage.writeAtomically(Data("new".utf8), to: link4)
        check("3.11 projects/ target keeps 0755 through the link", contents(proj.path) == "new" && mode(proj.path) == 0o755, octal(mode(proj.path)))
        // dangling and cycle
        let dangling = configRoot.appendingPathComponent("skills/demo/dangling")
        symlink(external.appendingPathComponent("missing").path, dangling.path)
        refused = false
        do { try PrivateStorage.writeAtomically(Data("x".utf8), to: dangling) } catch { refused = true }
        check("3.12 dangling link refused", refused)
        check("3.13 dangling target not created", !fm.fileExists(atPath: external.appendingPathComponent("missing").path))
        let cycA = configRoot.appendingPathComponent("skills/demo/cycA")
        let cycB = configRoot.appendingPathComponent("skills/demo/cycB")
        symlink(cycB.path, cycA.path)
        symlink(cycA.path, cycB.path)
        refused = false
        var cycleMessage = ""
        do { try PrivateStorage.writeAtomically(Data("x".utf8), to: cycA) } catch { refused = true; cycleMessage = "\(error)" }
        check("3.14 symlink cycle refused", refused && cycleMessage.contains("cycle"), cycleMessage)
        let linkToDir = configRoot.appendingPathComponent("skills/demo/todir")
        symlink(dirTarget.path, linkToDir.path)
        refused = false
        do { try PrivateStorage.writeAtomically(Data("x".utf8), to: linkToDir) } catch { refused = true }
        check("3.15 link to a directory refused", refused)

        // MARK: 4. Directories and append handles
        print("\n[4] directories and append handles")
        let nested = dataRoot.appendingPathComponent("reminder-scripts/state/deep")
        try PrivateStorage.ensureDirectory(nested)
        check("4.1 nested directories created 0700 under umask 022",
              mode(nested.path) == 0o700 && mode(nested.deletingLastPathComponent().path) == 0o700,
              "\(octal(mode(nested.path))) / \(octal(mode(nested.deletingLastPathComponent().path)))")
        let wideDir = dataRoot.appendingPathComponent("images")
        try fm.createDirectory(at: wideDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try PrivateStorage.ensureDirectory(wideDir)
        check("4.2 existing 0755 directory tightened to 0700", mode(wideDir.path) == 0o700, octal(mode(wideDir.path)))
        try PrivateStorage.ensureDirectory(wideDir)
        check("4.3 ensureDirectory is idempotent", mode(wideDir.path) == 0o700)
        refused = false
        do { try PrivateStorage.ensureDirectory(fresh) } catch { refused = true }
        check("4.4 a regular file in the way is an error", refused)
        let log = dataRoot.appendingPathComponent("logs/web-pipeline.log")
        try PrivateStorage.ensureDirectory(log.deletingLastPathComponent())
        do {
            let h = try PrivateStorage.openForAppend(log)
            try h.write(contentsOf: Data("a\n".utf8))
            try h.close()
        }
        check("4.5 append handle creates the file 0600", mode(log.path) == 0o600, octal(mode(log.path)))
        _ = chmod(log.path, 0o644)
        do {
            let h = try PrivateStorage.openForAppend(log)
            try h.write(contentsOf: Data("b\n".utf8))
            try h.close()
        }
        check("4.6 append handle tightens a 0644 log and appends", mode(log.path) == 0o600 && contents(log.path) == "a\nb\n")
        let logLink = dataRoot.appendingPathComponent("logs/other.log")
        symlink(extPlain.path, logLink.path)
        let extBefore = contents(extPlain.path)
        refused = false
        do { _ = try PrivateStorage.openForAppend(logLink) } catch { refused = true }
        check("4.7 append through a symlink refused", refused && contents(extPlain.path) == extBefore)

        // MARK: 5. Sweep
        print("\n[5] startup sweep")
        // Plant the plan's fixture: 0644 file, 0755 directory, 0755 script,
        // symlink to an external file, wide entries in the excluded areas.
        let sweepFile = dataRoot.appendingPathComponent("todos.json")
        try plant(sweepFile.path, "[]", 0o644)
        let sweepDir = dataRoot.appendingPathComponent("subagent_sessions")
        try fm.createDirectory(at: sweepDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try plant(sweepDir.appendingPathComponent("abcde.json").path, "{}", 0o664)
        let sweepScript = configRoot.appendingPathComponent("skills/demo/run.sh")
        try plant(sweepScript.path, "#!/bin/sh\necho ok\n", 0o755)
        let extForLink = external.appendingPathComponent("linked.txt")
        try plant(extForLink.path, "x", 0o644)
        let sweepLink = dataRoot.appendingPathComponent("documents/linked.txt")
        symlink(extForLink.path, sweepLink.path)
        let projWide = dataRoot.appendingPathComponent("projects/p/readme.md")
        try plant(projWide.path, "x", 0o644)
        let toolWide = dataRoot.appendingPathComponent("toolchain/bin/tool")
        try plant(toolWide.path, "x", 0o755)
        _ = chmod(dataRoot.appendingPathComponent("projects").path, 0o755)
        _ = chmod(configRoot.path, 0o755)

        let dry = PrivateStorage.sweep(apply: false)
        check("5.1 dry run counts wide entries without changing them",
              dry.tightened >= 5 && mode(sweepFile.path) == 0o644, "tightened=\(dry.tightened)")
        let report = PrivateStorage.sweep()
        check("5.2 sweep reports the same count it then fixes", report.tightened == dry.tightened, "\(report.tightened) vs \(dry.tightened)")
        check("5.3 0644 file → 0600", mode(sweepFile.path) == 0o600, octal(mode(sweepFile.path)))
        check("5.4 0755 directory → 0700", mode(sweepDir.path) == 0o700, octal(mode(sweepDir.path)))
        check("5.5 0664 file inside → 0600", mode(sweepDir.appendingPathComponent("abcde.json").path) == 0o600)
        check("5.6 0755 script → 0700, still executable by owner", mode(sweepScript.path) == 0o700, octal(mode(sweepScript.path)))
        check("5.7 widened config root → 0700", mode(configRoot.path) == 0o700, octal(mode(configRoot.path)))
        check("5.8 symlink skipped, external target untouched (0644)",
              isLink(sweepLink.path) && mode(extForLink.path) == 0o644 && report.skipped >= 1, "skipped=\(report.skipped)")
        check("5.9 projects/ content untouched (0644)", mode(projWide.path) == 0o644, octal(mode(projWide.path)))
        check("5.10 projects/ directory itself untouched (0755)", mode(dataRoot.appendingPathComponent("projects").path) == 0o755)
        check("5.11 toolchain/ content untouched (0755)", mode(toolWide.path) == 0o755, octal(mode(toolWide.path)))
        check("5.12 external target's mode preserved through the earlier write-through (0755)", mode(extScript.path) == 0o755)
        let again = PrivateStorage.sweep()
        check("5.13 second sweep is a no-op", again.tightened == 0 && again.errors.isEmpty, "tightened=\(again.tightened) errors=\(again.errors)")
        let doctor = PrivateStorage.sweep(apply: false)
        check("5.14 doctor view reports zero wide entries after the sweep", doctor.tightened == 0)
        // Budget: a tiny budget truncates instead of stalling.
        let bounded = PrivateStorage.sweep(apply: false, budget: 3)
        check("5.15 entry budget truncates the scan", bounded.truncated && bounded.scanned <= 4, "scanned=\(bounded.scanned)")
        // Execution after sweep: the 0700 script still runs.
        let run2 = Process()
        run2.executableURL = URL(fileURLWithPath: "/bin/sh")
        run2.arguments = ["-c", "\"\(sweepScript.path)\""]
        let pipe2 = Pipe()
        run2.standardOutput = pipe2
        try run2.run()
        run2.waitUntilExit()
        let out2 = String(data: pipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        check("5.16 swept skill helper executes directly (exec bit kept)", run2.terminationStatus == 0 && out2 == "ok\n", out2)

        // MARK: 7. Symlinked roots, child umask, bundled copies
        print("\n[7] symlinked roots, child umask, bundled copies")
        // A root that is a symlink to a directory elsewhere (data moved to
        // another disk): ensureDirectory tightens the TARGET and the sweep
        // walks the target tree.
        let realData = tempRoot.appendingPathComponent("moved/briglia")
        try fm.createDirectory(at: realData, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try plant(realData.appendingPathComponent("conversation.json").path, "[]", 0o644)
        let linkRoot = tempRoot.appendingPathComponent("linkroot/briglia")
        try fm.createDirectory(at: linkRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        symlink(realData.path, linkRoot.path)
        let dryLinked = PrivateStorage.sweep(configRoot: configRoot, dataRoot: linkRoot, apply: false)
        check("7.1 doctor view sees the wide entries behind a symlinked root",
              dryLinked.tightened >= 2 && dryLinked.errors.isEmpty, "tightened=\(dryLinked.tightened) errors=\(dryLinked.errors)")
        try PrivateStorage.ensureDirectory(linkRoot)
        check("7.2 ensureDirectory on a symlinked root tightens the target directory",
              mode(realData.path) == 0o700 && isLink(linkRoot.path), octal(mode(realData.path)))
        let sweptLinked = PrivateStorage.sweep(configRoot: configRoot, dataRoot: linkRoot)
        check("7.3 sweep through a symlinked root tightens the target tree",
              mode(realData.appendingPathComponent("conversation.json").path) == 0o600 && sweptLinked.errors.isEmpty,
              octal(mode(realData.appendingPathComponent("conversation.json").path)))
        check("7.4 the root link itself is untouched (still a link)", isLink(linkRoot.path))
        let brokenRoot = tempRoot.appendingPathComponent("linkroot/broken")
        symlink(tempRoot.appendingPathComponent("nowhere").path, brokenRoot.path)
        let brokenSweep = PrivateStorage.sweep(configRoot: configRoot, dataRoot: brokenRoot, apply: false)
        check("7.5 a root symlink that resolves to nothing is reported, not silently skipped",
              !brokenSweep.errors.isEmpty, "\(brokenSweep.errors)")

        // Child umask through the setsid trampoline (WhatsApp bridge / npm).
        if let ada = BashTools.selfExecutablePath {
            let umaskDir = dataRoot.appendingPathComponent("umask-probe")
            try PrivateStorage.ensureDirectory(umaskDir)
            let probeFile = umaskDir.appendingPathComponent("child.txt").path
            let child = Process()
            child.executableURL = URL(fileURLWithPath: ada)
            child.arguments = ["__setsid-exec", "--", "/bin/sh", "-c", "umask > \"\(probeFile)\"; env | grep -c BRIGLIA_CHILD_UMASK >> \"\(probeFile)\" || true"]
            var env = ProcessInfo.processInfo.environment
            env["BRIGLIA_CHILD_UMASK"] = "077"
            child.environment = env
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            let probe = contents(probeFile).split(separator: "\n").map(String.init)
            check("7.6 trampoline applies BRIGLIA_CHILD_UMASK=077 (child umask 077, file created 0600)",
                  probe.first == "0077" && mode(probeFile) == 0o600, "\(probe) mode=\(octal(mode(probeFile)))")
            check("7.7 the umask variable is consumed, not passed on to the child",
                  probe.count >= 2 && probe[1] == "0", "\(probe)")
            let plainFile = umaskDir.appendingPathComponent("plain.txt").path
            let plain = Process()
            plain.executableURL = URL(fileURLWithPath: ada)
            plain.arguments = ["__setsid-exec", "--", "/bin/sh", "-c", "umask 022; : > \"\(plainFile)\""]
            plain.standardOutput = FileHandle.nullDevice
            plain.standardError = FileHandle.nullDevice
            try plain.run()
            plain.waitUntilExit()
            check("7.8 without the variable the trampoline leaves the umask alone (control: 0644)",
                  mode(plainFile) == 0o644, octal(mode(plainFile)))
        } else {
            check("7.6 trampoline umask (skipped: executable path unresolved)", true)
        }

        // WhatsApp bundled sources land owner-only.
        let bundledSrc = tempRoot.appendingPathComponent("bundled")
        try plant(bundledSrc.appendingPathComponent("index.js").path, "console.log(1)", 0o644)
        try plant(bundledSrc.appendingPathComponent("package.json").path, "{}", 0o644)
        let bridgeDir = dataRoot.appendingPathComponent("whatsapp-bridge")
        try PrivateStorage.ensureDirectory(bridgeDir)
        try WhatsAppChannelService.installBundledFiles(from: bundledSrc, into: bridgeDir)
        check("7.9 WhatsApp bundled index.js / package.json copied 0600 (source was 0644)",
              mode(bridgeDir.appendingPathComponent("index.js").path) == 0o600
              && mode(bridgeDir.appendingPathComponent("package.json").path) == 0o600
              && contents(bridgeDir.appendingPathComponent("index.js").path) == "console.log(1)")

        // MARK: 8. Streaming copy, mid-copy failure, non-directory roots
        print("\n[8] streaming copy, mid-copy failure, non-directory roots")
        do {
            // A 64 MB sparse file: copying it must not need 64 MB of memory,
            // and the copy must be byte-identical (holes read as zeros).
            let bigSrc = tempRoot.appendingPathComponent("stage/documents/big.bin")
            try fm.createDirectory(at: bigSrc.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(bigSrc.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            let marker = Data("END-MARKER".utf8)
            let size = 64 * 1024 * 1024
            _ = lseek(fd, off_t(size - marker.count), SEEK_SET)
            _ = marker.withUnsafeBytes { write(fd, $0.baseAddress, marker.count) }
            close(fd)
            let bigDst = dataRoot.appendingPathComponent("documents/big.bin")
            let before = mach_or_rss()
            try PrivateStorage.copyTree(from: bigSrc, to: bigDst)
            let after = mach_or_rss()
            var st = stat()
            let sizeOK = stat(bigDst.path, &st) == 0 && Int(st.st_size) == size
            let tailFD = open(bigDst.path, O_RDONLY)
            var tail = [UInt8](repeating: 0, count: marker.count)
            _ = lseek(tailFD, off_t(size - marker.count), SEEK_SET)
            let n = tail.withUnsafeMutableBytes { read(tailFD, $0.baseAddress, marker.count) }
            close(tailFD)
            check("8.1 64 MB sparse file streamed to a byte-identical 0600 copy",
                  sizeOK && n == marker.count && Data(tail) == marker && mode(bigDst.path) == 0o600,
                  "sizeOK=\(sizeOK) n=\(n) mode=\(octal(mode(bigDst.path)))")
            check("8.2 resident memory did not grow by the file size (streamed, not buffered)",
                  after - before < 32 * 1024 * 1024, "grew by \(after - before) bytes")
            // Injected mid-copy failure: temp removed, destination untouched.
            try plant(bigDst.path, "PREVIOUS", 0o600)
            PrivateStorage.copyFaultAfterBytes = 1 << 20
            var failed = false
            var message = ""
            do { try PrivateStorage.copyTree(from: bigSrc, to: bigDst) } catch { failed = true; message = "\(error)" }
            PrivateStorage.copyFaultAfterBytes = nil
            let temps = (try? fm.contentsOfDirectory(atPath: bigDst.deletingLastPathComponent().path))?.filter { $0.contains(".tmp-") } ?? []
            check("8.3 mid-copy failure surfaces as an error", failed && message.contains("injected"), message)
            check("8.4 mid-copy failure leaves the destination as it was and no temp behind",
                  contents(bigDst.path) == "PREVIOUS" && temps.isEmpty, "temps=\(temps)")
            try? fm.removeItem(at: bigSrc)
            try? fm.removeItem(at: bigDst)
        }
        // Roots that exist as the wrong kind are errors, absent roots are not.
        let fileRoot = tempRoot.appendingPathComponent("file-root")
        try plant(fileRoot.path, "x", 0o600)
        let fileRootSweep = PrivateStorage.sweep(configRoot: configRoot, dataRoot: fileRoot, apply: false)
        check("8.5 a data root that is a regular file is reported as an error",
              fileRootSweep.errors.contains { $0.contains("not a directory") }, "\(fileRootSweep.errors)")
        let fifoRoot = tempRoot.appendingPathComponent("fifo-root")
        if mkfifo(fifoRoot.path, 0o600) == 0 {
            let fifoSweep = PrivateStorage.sweep(configRoot: configRoot, dataRoot: fifoRoot, apply: false)
            check("8.6 a data root that is a FIFO is reported as an error", !fifoSweep.errors.isEmpty, "\(fifoSweep.errors)")
            unlink(fifoRoot.path)
        }
        let absentSweep = PrivateStorage.sweep(configRoot: configRoot, dataRoot: tempRoot.appendingPathComponent("absent-root"), apply: false)
        check("8.7 an absent root is not an error (diagnostics never create roots)", absentSweep.errors.isEmpty, "\(absentSweep.errors)")
        var rootRefused = false
        do { try PrivateStorage.ensureDirectory(fileRoot, mode: 0o700) } catch { rootRefused = true }
        check("8.8 ensureDirectory on a root that is a regular file throws (startup refuses)", rootRefused)

        // MARK: 6. Writer-level checks (routing work adds them here)
        print("\n[6] state writers")
        await StorageWritersSelftest.run(tempRoot: tempRoot, check: check)

        print(failures == 0 ? "\nStorage selftest: all checks passed." : "\nStorage selftest: \(failures) check(s) FAILED.")
        if failures > 0 { throw ExitCode(1) }
    }
}

/// Resident set size in bytes (best effort; 0 when unavailable).
private func mach_or_rss() -> Int {
    #if os(macOS)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return rc == KERN_SUCCESS ? Int(info.resident_size) : 0
    #else
    guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
          let pages = text.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return 0 }
    return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
    #endif
}
