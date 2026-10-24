import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - §8.2 AgentMail installer battery

extension SelftestContext {
    struct Fixture {
        let archive: URL
        let sums: URL
        let version: String
        let binarySHA: String
    }

    /// A fake `agentmail` binary: a shell script that prints its version,
    /// and — through the wrapper (AGENTMAIL_API_KEY exported) — fails when
    /// `failWrapped` is set, so a "published wrapper smoke test fails" can be
    /// produced deterministically.
    func makeFixture(version: String, failWrapped: Bool = false, failDirect: Bool = false, flat: Bool = false) throws -> Fixture {
        let dir = tempDir("fixture-\(version)")
        // Mirrors the upstream (cargo-dist) layout: one top-level directory
        // holding the binary and docs; the installer strips it.
        let top = flat ? dir : dir.appendingPathComponent("agentmail-cli-test", isDirectory: true)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        let bin = top.appendingPathComponent("agentmail")
        var script = "#!/bin/sh\n"
        if failDirect { script += "exit 1\n" }
        if failWrapped { script += "if [ \"${AGENTMAIL_API_KEY+set}\" = set ]; then exit 1; fi\n" }
        script += "echo agentmail \(version)\n"
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        try "readme".write(to: top.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let asset = "agentmail-cli-test-\(version).tar.gz"
        let archive = dir.appendingPathComponent(asset)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", dir.path, flat ? "agentmail" : "agentmail-cli-test"]
        try tar.run(); tar.waitUntilExit()
        let data = try Data(contentsOf: archive)
        let sums = dir.appendingPathComponent("checksums.txt")
        try "\(AgentMailService.sha256Hex(data))  \(asset)\n".write(to: sums, atomically: true, encoding: .utf8)
        return Fixture(archive: archive, sums: sums, version: version, binarySHA: AgentMailService.sha256Hex(try Data(contentsOf: bin)))
    }

    func useFixture(_ f: Fixture, slow: AsyncGate? = nil) {
        AgentMailService.downloadOverride = { _ in
            if let slow { await slow.wait() }
            return (f.version, f.archive.lastPathComponent, try Data(contentsOf: f.archive), try Data(contentsOf: f.sums))
        }
    }

    func entries(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { ($0.hasPrefix("agentmail") || $0.hasPrefix(".agentmail")) && $0 != ".agentmail.lock" }.sorted()
    }

    func wrapperAnswers(_ dir: URL, _ version: String) -> Bool {
        let r = ProcessRunner.runBlockingProcess(executable: dir.appendingPathComponent("agentmail").path, args: ["--version"], timeoutSeconds: 10)
        return (r.stdout ?? "").contains("agentmail \(version)")
    }

    func dirHash(_ dir: URL) -> String {
        var parts: [String] = []
        for e in entries(dir) {
            let p = dir.appendingPathComponent(e)
            var st = stat()
            lstat(p.path, &st)
            let data = (try? Data(contentsOf: p)) ?? Data()
            parts.append("\(e):\(st.st_mode):\(AgentMailService.sha256Hex(data))")
        }
        return parts.joined(separator: "|")
    }

    /// Pinned upstream release (2026-09-04): the installer never asks GitHub
    /// for "latest"; the archive for this target is authenticated against
    /// the compiled-in SHA-256, extracted from its nested top directory, and
    /// the prompt syntax follows the installed binary's version.
    func agentMailPinning() async throws {
        AgentMailService.brigliaPathOverride = "/usr/bin/true"
        defer { AgentMailService.brigliaPathOverride = nil; AgentMailService.downloadOverride = nil; AgentMailService.installDirectoryOverride = nil; AgentMailService.cliSyntaxOverrideForTesting = nil }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        func isSHA(_ s: String) -> Bool { s.count == 64 && s.unicodeScalars.allSatisfy { hex.contains($0) } }
        check("pinned version is a plain semver", AgentMailService.pinnedVersion.split(separator: ".").count == 3 && !AgentMailService.pinnedVersion.hasPrefix("v"))
        check("every pinned entry is a lowercase 64-hex SHA-256", AgentMailService.pinnedArchiveSHA256.values.allSatisfy(isSHA) && AgentMailService.pinnedArchiveSHA256.count == 4)
        let pin = AgentMailService.pinnedAsset()
        check("this platform (\(AgentMailService.currentTargetTriple)) has a pinned build", pin != nil)
        if let pin {
            check("asset name follows the cargo-dist layout", pin.asset == "agentmail-cli-\(AgentMailService.currentTargetTriple).tar.gz")
            check("download URL is the immutable tag path on github.com",
                  pin.url.host == "github.com" && pin.url.path == "/agentmail-to/agentmail-cli/releases/download/v\(AgentMailService.pinnedVersion)/\(pin.asset)")
            check("Linux pins the static musl build (no libssl.so.3 dependency)",
                  !AgentMailService.currentTargetTriple.contains("linux") || AgentMailService.currentTargetTriple.hasSuffix("-musl"))
        }
        check("no pinned build for an unknown target", AgentMailService.pinnedAsset(triple: "sparc-unknown-plan9") == nil)

        func freshDir() -> URL {
            let d = tempDir("pin")
            AgentMailService.installDirectoryOverride = d
            return d
        }

        // A flat archive (binary at the top level, the pre-1.0 layout) is
        // rejected after extraction: nothing is published.
        var dir = freshDir()
        let flat = try makeFixture(version: "1.3.0", flat: true)
        useFixture(flat)
        var failure = await AgentMailService.installAgentMailBinary()
        check("flat archive → 'did not contain' failure, nothing published", (failure ?? "").contains("did not contain") && entries(dir).isEmpty, "\(failure ?? "") \(entries(dir))")

        // The synthesized checksum line is what authenticates the download:
        // a record that does not match the bytes fails closed.
        let good = try makeFixture(version: "1.3.0")
        AgentMailService.downloadOverride = { _ in
            (good.version, good.archive.lastPathComponent, try Data(contentsOf: good.archive),
             Data("\(String(repeating: "0", count: 64))  \(good.archive.lastPathComponent)\n".utf8))
        }
        failure = await AgentMailService.installAgentMailBinary()
        check("compiled-in hash mismatch → checksum failure, nothing published", (failure ?? "").contains("checksum mismatch") && entries(dir).isEmpty, "\(failure ?? "") \(entries(dir))")
        AgentMailService.downloadOverride = { _ in
            (good.version, good.archive.lastPathComponent, try Data(contentsOf: good.archive),
             Data("\(AgentMailService.sha256Hex(try Data(contentsOf: good.archive))) *\(good.archive.lastPathComponent)\n".utf8))
        }
        failure = await AgentMailService.installAgentMailBinary()
        check("nested archive with a matching record installs (upstream `hash *name` line form accepted)", failure == nil && wrapperAnswers(dir, "1.3.0"), failure ?? "")
        check("installed version parsed from the versioned target", AgentMailService.installedCLIVersion() == "1.3.0")
        check("1.x installed → nested prompt syntax", AgentMailService.cliSyntax == .v1Nested && AgentMailService.messagesResource == "inboxes messages")

        // A crash between the wrapper temp's creation and its rename leaves
        // `.agentmail.tmp-<uuid>`; repair and install sweep it under the lock.
        let stale = dir.appendingPathComponent(".agentmail.tmp-DEADBEEF-0000")
        try Data("half-written".utf8).write(to: stale)
        let sweepOutcome = await AgentMailService.repairTransaction()
        check("stale wrapper temp: repair (nothing to do) sweeps it", { if case .nothingToDo = sweepOutcome { return true }; return false }() && !entries(dir).contains(".agentmail.tmp-DEADBEEF-0000") && wrapperAnswers(dir, "1.3.0"), "\(sweepOutcome) \(entries(dir))")
        try Data("half-written".utf8).write(to: stale)
        failure = await AgentMailService.installAgentMailBinary()
        check("stale wrapper temp: install sweeps it, pair intact", failure == nil && entries(dir) == ["agentmail", AgentMailService.versionedName(version: "1.3.0", sha256: good.binarySHA)], "\(failure ?? "") \(entries(dir))")

        // A device still on the Go CLI keeps the colon syntax until upgraded.
        dir = freshDir()
        let old = try makeFixture(version: "0.7.14")
        useFixture(old)
        failure = await AgentMailService.installAgentMailBinary()
        check("0.7.14 fixture installs", failure == nil && AgentMailService.installedCLIVersion() == "0.7.14", failure ?? "")
        check("0.x installed → colon prompt syntax", AgentMailService.cliSyntax == .v0Colon && AgentMailService.messagesResource == "inboxes:messages")
        useFixture(good)
        failure = await AgentMailService.installAgentMailBinary()
        check("upgrade 0.7.14 → 1.3.0 flips the prompt syntax", failure == nil && AgentMailService.installedCLIVersion() == "1.3.0" && AgentMailService.cliSyntax == .v1Nested, failure ?? "")
        check("not installed → nested syntax (what a fresh install gets)", { AgentMailService.installDirectoryOverride = tempDir("empty"); return AgentMailService.installedCLIVersion() == nil && AgentMailService.cliSyntax == .v1Nested }())

        // Opt-in live check (network): the real pinned download installs and
        // answers with the pinned version. BRIGLIA_AGENTMAIL_LIVE=1.
        if ProcessInfo.processInfo.environment["BRIGLIA_AGENTMAIL_LIVE"] == "1" {
            dir = freshDir()
            AgentMailService.downloadOverride = nil
            var lines: [String] = []
            failure = await AgentMailService.installAgentMailBinary(progress: { lines.append($0) })
            check("LIVE: pinned \(AgentMailService.pinnedVersion) downloads, verifies and installs", failure == nil, failure ?? "")
            let r = ProcessRunner.runBlockingProcess(executable: dir.appendingPathComponent("agentmail").path, args: ["--version"], timeoutSeconds: 20)
            check("LIVE: wrapper answers `agentmail \(AgentMailService.pinnedVersion)`", (r.stdout ?? "").contains("agentmail \(AgentMailService.pinnedVersion)"), r.stdout ?? r.failureDetail ?? "")
            check("LIVE: installed version parsed", AgentMailService.installedCLIVersion() == AgentMailService.pinnedVersion)
            let nested = ProcessRunner.runBlockingProcess(executable: dir.appendingPathComponent("agentmail").path, args: ["inboxes", "messages", "--help"], timeoutSeconds: 20)
            check("LIVE: the pinned CLI has the nested `inboxes messages` resource", (nested.stdout ?? "").contains("List Messages"), nested.stdout ?? nested.failureDetail ?? "")
        }
    }

    func agentMailInstaller() async throws {
        AgentMailService.brigliaPathOverride = "/usr/bin/true"
        defer { AgentMailService.brigliaPathOverride = nil; AgentMailService.downloadOverride = nil; AgentMailService.installDirectoryOverride = nil }
        let v1 = try makeFixture(version: "1.0.0")
        let v2 = try makeFixture(version: "2.0.0")
        let vBadWrapped = try makeFixture(version: "3.0.0", failWrapped: true)
        let vBadDirect = try makeFixture(version: "4.0.0", failDirect: true)
        let v1name = AgentMailService.versionedName(version: "1.0.0", sha256: v1.binarySHA)
        let v2name = AgentMailService.versionedName(version: "2.0.0", sha256: v2.binarySHA)
        let fm = FileManager.default

        func freshDir() -> URL {
            let d = tempDir("bin")
            AgentMailService.installDirectoryOverride = d
            return d
        }
        func txState(_ dir: URL) -> String? {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("agentmail.tx.json")),
                  let tx = try? JSONDecoder.iso.decode(AgentMailService.Transaction.self, from: data) else { return nil }
            return tx.state
        }

        // Fresh install.
        var dir = freshDir()
        useFixture(v1)
        var failure = await AgentMailService.installAgentMailBinary()
        check("fresh install succeeds", failure == nil, failure ?? "")
        check("published pair: wrapper + versioned binary, no tx, no staging", entries(dir) == ["agentmail", v1name], "\(entries(dir))")
        check("agentMailBrokerInstalled true and the wrapper answers", AgentMailService.agentMailBrokerInstalled() && wrapperAnswers(dir, "1.0.0"))
        check("wrapper target is the versioned path", AgentMailService.wrapperTarget(try Data(contentsOf: dir.appendingPathComponent("agentmail"))) == dir.appendingPathComponent(v1name).path)

        // Upgrade.
        useFixture(v2)
        failure = await AgentMailService.installAgentMailBinary()
        check("upgrade succeeds; previous binary removed, new pair live", failure == nil && entries(dir) == ["agentmail", v2name] && wrapperAnswers(dir, "2.0.0"), "\(failure ?? "") \(entries(dir))")

        // Existing versioned binary shortcut (matching hash) and mismatch.
        useFixture(v1)
        failure = await AgentMailService.installAgentMailBinary()
        var st = stat()
        lstat(dir.appendingPathComponent(v1name).path, &st)
        let inodeBefore = st.st_ino
        useFixture(v1)
        failure = await AgentMailService.installAgentMailBinary()
        lstat(dir.appendingPathComponent(v1name).path, &st)
        check("existing versioned file with matching hash: metadata written, binary not renamed over (inode unchanged), commit proceeds", failure == nil && st.st_ino == inodeBefore && txState(dir) == nil && wrapperAnswers(dir, "1.0.0"))
        try Data("garbage".utf8).write(to: dir.appendingPathComponent(v2name))
        useFixture(v2)
        failure = await AgentMailService.installAgentMailBinary()
        check("existing file with the expected name and wrong content → fails closed, byte-identical, no metadata",
              (failure ?? "").contains("unexpected content") && (try? String(contentsOf: dir.appendingPathComponent(v2name), encoding: .utf8)) == "garbage" && txState(dir) == nil && wrapperAnswers(dir, "1.0.0"))
        unlink(dir.appendingPathComponent(v2name).path)

        // Staged smoke failure never touches the published pair.
        useFixture(vBadDirect)
        let before = dirHash(dir)
        failure = await AgentMailService.installAgentMailBinary()
        check("staged binary failing its smoke test → published pair untouched", (failure ?? "").contains("failed to run") && dirHash(dir) == before)

        // Published-wrapper smoke failure on an upgrade → one atomic rollback.
        useFixture(vBadWrapped)
        failure = await AgentMailService.installAgentMailBinary()
        check("published wrapper failing → rolled back: previous wrapper restored, old binary intact, answers --version", (failure ?? "").contains("previous installation was restored") && entries(dir) == ["agentmail", v1name] && wrapperAnswers(dir, "1.0.0"), "\(failure ?? "") \(entries(dir))")

        // Fresh-install rollback: no prior installation.
        dir = freshDir()
        useFixture(vBadWrapped)
        failure = await AgentMailService.installAgentMailBinary()
        check("fresh install whose published wrapper fails → back to no installation", failure != nil && entries(dir).isEmpty && !AgentMailService.agentMailBrokerInstalled(), "\(entries(dir))")

        // Legacy fixture: unversioned agentmail-bin + old wrapper.
        dir = freshDir()
        try "#!/bin/sh\necho agentmail legacy\n".write(to: dir.appendingPathComponent("agentmail-bin"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("agentmail-bin").path)
        try AgentMailService.wrapperScript(adaPath: "/usr/bin/true", realBinaryPath: dir.appendingPathComponent("agentmail-bin").path).write(to: dir.appendingPathComponent("agentmail"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("agentmail").path)
        check("legacy pair counts as installed", AgentMailService.agentMailBrokerInstalled() && wrapperAnswers(dir, "legacy"))
        useFixture(v1)
        failure = await AgentMailService.installAgentMailBinary()
        check("legacy install upgrades and leaves no legacy file", failure == nil && entries(dir) == ["agentmail", v1name] && wrapperAnswers(dir, "1.0.0"), "\(entries(dir))")

        // Rotation (checkpoint throws) at every point, from a working install.
        struct Abort: Error {}
        for n in 1...9 {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            useFixture(v2)
            var calls = 0
            let f = await AgentMailService.installAgentMailBinary(checkpoint: { calls += 1; if calls == n { throw Abort() } })
            if calls < n { break }   // fewer checkpoints than n: the install completed
            let live = (try? Data(contentsOf: dir.appendingPathComponent("agentmail"))).flatMap(AgentMailService.wrapperTarget)
            let liveOK = live != nil && fm.fileExists(atPath: live!)
            let repaired = await AgentMailService.repairTransaction()
            let answers = wrapperAnswers(dir, "1.0.0") || wrapperAnswers(dir, "2.0.0")
            check("checkpoint abort #\(n): aborted (\(f != nil)), live wrapper complete with an existing target, repair settles, no tx/staging left, wrapper answers",
                  f != nil && liveOK && txState(dir) == nil && !entries(dir).contains { $0.hasPrefix(".agentmail-staging") } && answers && repaired != .busy,
                  "\(f ?? "nil") entries=\(entries(dir)) repair=\(repaired)")
        }
        // Rotation during a slow download → transfer cancelled, staging gone, old pair untouched.
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let gate = AsyncGate()
            useFixture(v2, slow: gate)
            let task = Task { await AgentMailService.installAgentMailBinary() }
            try? await Task.sleep(nanoseconds: 200_000_000)
            task.cancel()
            gate.open()
            let f = await task.value
            check("cancellation during the download → install failed, staging gone, old pair answers", f != nil && entries(dir) == ["agentmail", v1name] && wrapperAnswers(dir, "1.0.0"), "\(f ?? "") \(entries(dir))")
        }

        // Crash injection (subprocess) at every point, then repair.
        for point in ["after-metadata", "after-binary", "after-committing", "after-swap", "after-committed"] {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: selfPath)
            p.arguments = ["__quicksetup-selftest", "--agentmail-crash", point, "--dir", dir.path, "--fixture", v2.archive.path, "--sums", v2.sums.path]
            var env = ProcessInfo.processInfo.environment
            env["BRIGLIA_SELFTEST_AM_VERSION"] = "2.0.0"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            let crashed = p.terminationStatus != 0
            let stateBefore = txState(dir)
            let liveTarget = (try? Data(contentsOf: dir.appendingPathComponent("agentmail"))).flatMap(AgentMailService.wrapperTarget)
            let liveIntact = liveTarget != nil && fm.fileExists(atPath: liveTarget!)
            // Doctor reports, never mutates.
            let hashBefore = dirHash(dir)
            let report = AgentMailService.transactionReport()
            check("crash at \(point): process died, tx state \(stateBefore ?? "nil"), live wrapper intact, doctor reports without mutating",
                  crashed && stateBefore != nil && liveIntact && (report ?? "").contains("interrupted") && dirHash(dir) == hashBefore, "state=\(stateBefore ?? "nil") report=\(report ?? "nil")")
            let outcome = await AgentMailService.repairTransaction()
            let expectedVersion: String
            switch point {
            case "after-swap", "after-committed": expectedVersion = "2.0.0"
            default: expectedVersion = "1.0.0"
            }
            check("repair after \(point): settled, no tx, wrapper answers \(expectedVersion), no orphan binary",
                  { if case .settled = outcome { return true }; return false }() && txState(dir) == nil && wrapperAnswers(dir, expectedVersion)
                  && entries(dir) == ["agentmail", expectedVersion == "2.0.0" ? v2name : v1name], "\(outcome) \(entries(dir))")
        }
        // Crash after the rollback swap, before cleanup (upgrade whose wrapper fails).
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: selfPath)
            p.arguments = ["__quicksetup-selftest", "--agentmail-crash", "after-rollback-swap", "--dir", dir.path, "--fixture", vBadWrapped.archive.path, "--sums", vBadWrapped.sums.path]
            var env = ProcessInfo.processInfo.environment
            env["BRIGLIA_SELFTEST_AM_VERSION"] = "3.0.0"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            let stateBefore = txState(dir)
            let outcome = await AgentMailService.repairTransaction()
            check("crash after the rollback swap: old wrapper live, metadata \(stateBefore ?? "nil"), repair removes the new binary and the old wrapper answers",
                  stateBefore == "committing" && { if case .settled = outcome { return true }; return false }() && entries(dir) == ["agentmail", v1name] && wrapperAnswers(dir, "1.0.0"), "\(outcome) \(entries(dir))")
        }
        // Hand-edited wrapper under committing → fail closed.
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: selfPath)
            p.arguments = ["__quicksetup-selftest", "--agentmail-crash", "after-committing", "--dir", dir.path, "--fixture", v2.archive.path, "--sums", v2.sums.path]
            var env = ProcessInfo.processInfo.environment
            env["BRIGLIA_SELFTEST_AM_VERSION"] = "2.0.0"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            try "#!/bin/sh\nexec '/somewhere/else' \"$@\"\n".write(to: dir.appendingPathComponent("agentmail"), atomically: true, encoding: .utf8)
            let hashBefore = dirHash(dir)
            let outcome = await AgentMailService.repairTransaction()
            check("hand-edited wrapper under committing → repair fails closed, deletes nothing, prints instructions",
                  { if case .failedClosed(let why) = outcome { return why.contains("does not match") }; return false }() && dirHash(dir) == hashBefore && txState(dir) == "committing", "\(outcome)")
            check("doctor keeps reporting it", (AgentMailService.transactionReport() ?? "").contains("interrupted"))
        }
        // Invalid metadata: absolute path, .., symlink at the named path, bad hash.
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let good = AgentMailService.Transaction(state: "staged", newBinary: v2name, newSHA256: v2.binarySHA, newWrapperSHA256: String(repeating: "a", count: 64), previousWrapper: nil, previousBinary: v1name, startedAt: Date())
            func writeTx(_ tx: AgentMailService.Transaction) throws {
                try JSONEncoder.iso.encode(tx).write(to: dir.appendingPathComponent("agentmail.tx.json"))
            }
            var tx = good; tx.newBinary = "/tmp/agentmail-bin-2.0.0-" + String(v2.binarySHA.prefix(12))
            try writeTx(tx)
            var hash = dirHash(dir)
            var outcome = await AgentMailService.repairTransaction()
            check("metadata with an absolute path → refused, nothing deleted", { if case .failedClosed = outcome { return true }; return false }() && dirHash(dir) == hash)
            tx = good; tx.previousBinary = "../agentmail-bin"
            try writeTx(tx)
            hash = dirHash(dir)
            outcome = await AgentMailService.repairTransaction()
            check("metadata with a .. segment → refused", { if case .failedClosed = outcome { return true }; return false }() && dirHash(dir) == hash)
            tx = good
            try writeTx(tx)
            symlink("/etc/hosts", dir.appendingPathComponent(v2name).path)
            hash = dirHash(dir)
            outcome = await AgentMailService.repairTransaction()
            check("symlink at the named path → refused, link untouched", { if case .failedClosed = outcome { return true }; return false }() && dirHash(dir) == hash)
            unlink(dir.appendingPathComponent(v2name).path)
            tx = good; tx.previousWrapper = .init(bytesB64: Data("x".utf8).base64EncodedString(), sha256: String(repeating: "b", count: 64), mode: 493)
            try writeTx(tx)
            hash = dirHash(dir)
            outcome = await AgentMailService.repairTransaction()
            check("previous wrapper bytes not matching their hash → refused", { if case .failedClosed = outcome { return true }; return false }() && dirHash(dir) == hash)
            unlink(dir.appendingPathComponent("agentmail.tx.json").path)
            check("validBasename rules", AgentMailService.validBasename("agentmail-bin") && AgentMailService.validBasename(v1name) && !AgentMailService.validBasename("agentmail") && !AgentMailService.validBasename("agentmail-bin-x-zz") && !AgentMailService.validBasename("../x") && !AgentMailService.validBasename(""))
        }
        // Wrapper state: absent | valid | invalid — never conflated.
        do {
            dir = freshDir()
            symlink("/etc/hosts", dir.appendingPathComponent("agentmail").path)
            check("wrapper state: symlink → invalid", { if case .invalid = AgentMailService.liveWrapperState() { return true }; return false }())
            useFixture(v1)
            failure = await AgentMailService.installAgentMailBinary()
            var st2 = stat()
            let stillLink = lstat(dir.appendingPathComponent("agentmail").path, &st2) == 0 && (st2.st_mode & S_IFMT) == S_IFLNK
            check("install refuses to overwrite an invalid agentmail entry (symlink kept, no metadata)", (failure ?? "").contains("refusing") && stillLink && txState(dir) == nil, failure ?? "")
            unlink(dir.appendingPathComponent("agentmail").path)
            check("wrapper state: absent", AgentMailService.liveWrapperState() == .absent)
            // A transaction with the wrapper turned into a symlink mid-way → repair fails closed.
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: selfPath)
            p.arguments = ["__quicksetup-selftest", "--agentmail-crash", "after-committing", "--dir", dir.path, "--fixture", v2.archive.path, "--sums", v2.sums.path]
            var env = ProcessInfo.processInfo.environment
            env["BRIGLIA_SELFTEST_AM_VERSION"] = "2.0.0"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            unlink(dir.appendingPathComponent("agentmail").path)
            symlink("/etc/hosts", dir.appendingPathComponent("agentmail").path)
            let hashBefore = dirHash(dir)
            let outcome = await AgentMailService.repairTransaction()
            check("repair with a symlinked wrapper under committing → fails closed, nothing deleted", { if case .failedClosed(let why) = outcome { return why.contains("invalid") }; return false }() && dirHash(dir) == hashBefore && txState(dir) == "committing", "\(outcome)")
            check("doctor reports the interrupted transaction", (AgentMailService.transactionReport() ?? "").contains("interrupted"))
            unlink(dir.appendingPathComponent("agentmail").path)
            let missingPrevOutcome = await AgentMailService.repairTransaction()
            check("an ABSENT wrapper where a previous one is recorded matches neither → fails closed", { if case .failedClosed = missingPrevOutcome { return true }; return false }())
            // Fresh transaction (no previous wrapper): absent IS pre-commit.
            dir = freshDir()
            let p2 = Process()
            p2.executableURL = URL(fileURLWithPath: selfPath)
            p2.arguments = ["__quicksetup-selftest", "--agentmail-crash", "after-committing", "--dir", dir.path, "--fixture", v1.archive.path, "--sums", v1.sums.path]
            p2.environment = ProcessInfo.processInfo.environment
            p2.standardOutput = FileHandle.nullDevice; p2.standardError = FileHandle.nullDevice
            try p2.run(); p2.waitUntilExit()
            let absentOutcome = await AgentMailService.repairTransaction()
            check("fresh transaction: an ABSENT wrapper (not an invalid one) classifies as pre-commit; repair settles to no installation", { if case .settled = absentOutcome { return true }; return false }() && txState(dir) == nil && entries(dir).isEmpty, "\(absentOutcome) \(entries(dir))")
        }
        // Cleanup and barrier failures are retryable, never silent success.
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            useFixture(v2)
            AgentMailService.injectFsyncFailure = true
            failure = await AgentMailService.installAgentMailBinary()
            AgentMailService.injectFsyncFailure = false
            check("directory-barrier failure after verification → retryable failure, new pair live, metadata kept", (failure ?? "").contains("cleanup did not complete") && wrapperAnswers(dir, "2.0.0") && txState(dir) != nil, failure ?? "")
            check("doctor reports it", (AgentMailService.transactionReport() ?? "").contains("interrupted"))
            let settled = await AgentMailService.repairTransaction()
            check("repair settles once the barrier works: no metadata, previous binary gone", { if case .settled = settled { return true }; return false }() && txState(dir) == nil && entries(dir) == ["agentmail", v2name], "\(settled) \(entries(dir))")
            useFixture(v1)
            AgentMailService.injectStagingRemovalFailure = true
            failure = await AgentMailService.installAgentMailBinary()
            AgentMailService.injectStagingRemovalFailure = false
            check("staging-removal failure → retryable failure, staging debris reported by doctor", (failure ?? "").contains("cleanup did not complete") && (AgentMailService.transactionReport() ?? "").contains("interrupted"), failure ?? "")
            let settled2 = await AgentMailService.repairTransaction()
            check("repair removes the debris", { if case .settled = settled2 { return true }; return false }() && !entries(dir).contains { $0.hasPrefix(".agentmail-staging") } && txState(dir) == nil, "\(settled2) \(entries(dir))")
        }
        // Deletion failures preserve the evidence (never "restored" while the failed wrapper is live).
        do {
            dir = freshDir()
            useFixture(vBadWrapped)
            AgentMailService.injectUnlinkFailure = "agentmail"
            failure = await AgentMailService.installAgentMailBinary()
            AgentMailService.injectUnlinkFailure = nil
            let liveIsNew = wrapperAnswers(dir, "3.0.0") == false && FileManager.default.fileExists(atPath: dir.appendingPathComponent("agentmail").path)
            check("fresh rollback whose wrapper unlink fails → reported as rollback failure, metadata kept at committing, failed wrapper still live", (failure ?? "").contains("rollback failed") && txState(dir) == "committing" && liveIsNew, "\(failure ?? "") state=\(txState(dir) ?? "nil")")
            check("doctor reports it", (AgentMailService.transactionReport() ?? "").contains("interrupted"))
            let settled = await AgentMailService.repairTransaction()
            check("repair (unlink working again) → verifies, fails, rolls back to no installation", { if case .settled = settled { return true }; return false }() && txState(dir) == nil && entries(dir).isEmpty, "\(settled) \(entries(dir))")
            // Unreferenced previous binary that cannot be deleted after a verified upgrade.
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            useFixture(v2)
            AgentMailService.injectUnlinkFailure = v1name
            failure = await AgentMailService.installAgentMailBinary()
            AgentMailService.injectUnlinkFailure = nil
            check("previous-binary deletion failure → retryable, new pair live, metadata kept", (failure ?? "").contains("cleanup did not complete") && wrapperAnswers(dir, "2.0.0") && txState(dir) != nil && entries(dir).contains(v1name), failure ?? "")
            let settled2 = await AgentMailService.repairTransaction()
            check("repair completes the cleanup", { if case .settled = settled2 { return true }; return false }() && txState(dir) == nil && entries(dir) == ["agentmail", v2name], "\(settled2) \(entries(dir))")
        }
        // Locks.
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let fd = open(dir.appendingPathComponent(".agentmail.lock").path, O_RDWR | O_CREAT, 0o600)
            check("lock file present after an install", fd >= 0)
            flock(fd, LOCK_EX)
            useFixture(v2)
            let busy = await AgentMailService.installAgentMailBinary()
            check("installer while the lock is held → 'in progress', nothing changed", (busy ?? "").contains("in progress") && entries(dir) == ["agentmail", v1name])
            let repairBusy = await AgentMailService.repairTransaction()
            check("repair while the lock is held → busy", repairBusy == .busy)
            check("doctor while the lock is held → 'in progress', no state read", (AgentMailService.transactionReport() ?? "").contains("in progress"))
            flock(fd, LOCK_UN); close(fd)
            unlink(dir.appendingPathComponent(".agentmail.lock").path)
            symlink("/tmp/whatever", dir.appendingPathComponent(".agentmail.lock").path)
            let sym = await AgentMailService.installAgentMailBinary()
            let symRepair = await AgentMailService.repairTransaction()
            check("symlink planted at the lock path → every path refuses", (sym ?? "").contains("refused") && { if case .failedClosed = symRepair { return true }; return false }(), "\(sym ?? "") \(symRepair)")
            unlink(dir.appendingPathComponent(".agentmail.lock").path)
            // Two installer processes at once: exactly one runs.
            let procs: [Process] = (0..<2).map { _ in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: selfPath)
                p.arguments = ["__quicksetup-selftest", "--agentmail-install", "--dir", dir.path, "--fixture", v2.archive.path, "--sums", v2.sums.path, "--hold-seconds", "1.5"]
                var env = ProcessInfo.processInfo.environment
                env["BRIGLIA_SELFTEST_AM_VERSION"] = "2.0.0"
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                return p
            }
            for p in procs { try p.run() }
            var outputs: [String] = []
            for p in procs {
                let data = (p.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                outputs.append(String(data: data, encoding: .utf8) ?? "")
            }
            let successes = outputs.filter { $0.contains("OK") }.count
            let inProgress = outputs.filter { $0.contains("in progress") }.count
            check("two concurrent installers: exactly one runs, the other reports in progress; result consistent", successes == 1 && inProgress == 1 && wrapperAnswers(dir, "2.0.0") && txState(dir) == nil, "\(outputs)")
        }
    }
}
