import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden test of Briglia's private runtimes (security plan v24 §7.8.1,
/// §7.9; §15 items 27-30): AgentMail receipt/current/journal/hold/repair with
/// crash recovery at every write, the per-use exec validation and probe mode,
/// legacy inspect-only, the Node selection and private copy, the Python venv,
/// and the PATH contract. Re-execs itself in a scratch home (files AND
/// preferences isolated; never the live install). Fixtures only: no network.
struct PrivateRuntimeSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__private-runtime-selftest",
        abstract: "Internal: verify Briglia's private AgentMail / Node / Python runtimes.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var op: String?
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-runtime-selftest"

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else { print("✖ development build required"); throw ExitCode(1) }
        setvbuf(stdout, nil, _IOLBF, 0)
        if let op { try await RuntimeSelftestOps.run(op); return }
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = RuntimeHarness(only: only)
        await h.runAll()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) private-runtime check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) private-runtime checks passed")
    }

    static func reexecIsolated(only: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("briglia-runtime-selftest-" + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "home/.local/bin", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        for k in env.keys where k.hasPrefix("BRIGLIA_") || k.hasPrefix("AGENTMAIL_") { env.removeValue(forKey: k) }
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__private-runtime-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep(settle: 25)
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// Subprocess operations for the crash tests (`--op`).
enum RuntimeSelftestOps {
    static func run(_ op: String) async throws {
        switch op {
        case "agentmail-converge":
            guard let pin = AgentMailService.runtimePin else { Foundation.exit(3) }
            let r = await PrivateRuntimeEngine.converge(AgentMailService.runtimeSpec(pin: pin), trigger: .explicit)
            print("RESULT \(r)")
        case "agentmail-repair":
            guard let pin = AgentMailService.runtimePin else { Foundation.exit(3) }
            let r = await AgentMailRepair.run(spec: AgentMailService.runtimeSpec(pin: pin), automatic: false, idle: nil)
            print("RESULT \(r)")
        case "agentmail-recover":
            guard let pin = AgentMailService.runtimePin else { Foundation.exit(3) }
            let r = await PrivateRuntimeEngine.recover(AgentMailService.runtimeSpec(pin: pin))
            print("RESULT \(r)")
        case "selection-update":
            _ = try RuntimeSelectionStore.update { _ in }
            print("RESULT updated")
        case "node-converge":
            guard let pin = NodeRuntime.runtimePin else { Foundation.exit(3) }
            let r = await PrivateRuntimeEngine.converge(NodeRuntime.spec(pin: pin), trigger: .explicit)
            print("RESULT \(r)")
        default:
            print("unknown op \(op)"); Foundation.exit(64)
        }
    }
}

final class RuntimeHarness {
    var total = 0
    var failures = 0
    let only: String?
    let home = NSHomeDirectory()
    let fm = FileManager.default
    let scratch: URL

    init(only: String?) {
        self.only = only
        scratch = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    /// Entries under `root` (symlinks excepted) with any group/other bit.
    func widePaths(_ root: URL) -> [String] {
        var out: [String] = []
        let all = [""] + ((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? [])
        for rel in all {
            let path = rel.isEmpty ? root.path : root.path + "/" + rel
            var st = stat()
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK, st.st_mode & 0o077 != 0 { out.append(rel.isEmpty ? "." : rel) }
        }
        return out
    }

    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { print("  ✔ \(label)") } else { failures += 1; print("  ✖ \(label)\(detail().isEmpty ? "" : " — \(detail())")") }
    }

    func section(_ name: String, _ body: () async throws -> Void) async {
        if let only, !name.lowercased().contains(only.lowercased()) { return }
        print("\n[\(name)]")
        do { try await body() } catch { failures += 1; total += 1; print("  ✖ section threw: \(error)") }
    }

    func runAll() async {
        await section("agentmail: install, update, rollback") { try await agentMailBasics() }
        await section("agentmail: exec validation and probe mode") { try await agentMailExec() }
        await section("agentmail: hold and repair") { try await agentMailRepair() }
        await section("agentmail: crash recovery (ordinary)") { try await agentMailCrashes() }
        await section("agentmail: crash recovery (repair)") { try await agentMailRepairCrashes() }
        await section("agentmail: legacy inspect-only, wipe, corrupt state") { try await agentMailLegacy() }
        await section("containment (no redirect out of the data root)") { try await containment() }
        await section("node: selection and private copy") { try await nodeSelection() }
        await section("python: private venv") { try await pythonEnv() }
        await section("path contract") { pathContract() }
    }

    // MARK: Containment (review R1)

    func containment() async throws {
        let a = try agentMailFixture("1.3.0")
        func outsideDir() throws -> URL {
            let o = scratch.appendingPathComponent("outside-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try fm.createDirectory(at: o, withIntermediateDirectories: true)
            chmod(o.path, 0o755)
            return o
        }
        func untouched(_ o: URL) -> Bool {
            var st = stat()
            return ((try? fm.contentsOfDirectory(atPath: o.path)) ?? ["?"]).isEmpty && lstat(o.path, &st) == 0 && st.st_mode & 0o777 == 0o755
        }
        // Component directory redirected out.
        resetRuntime()
        useAgentMail(a, version: "1.3.0")
        var o = try outsideDir()
        try fm.createDirectory(at: RuntimePaths.runtimeRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: am.path, withDestinationPath: o.path)
        let r1 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
        check("runtime/agentmail → outside: nothing installed, the outside directory untouched (no lock, receipt, link or copy)",
              { if case .converged = r1 { return false }; return true }() && untouched(o), "\(r1)")
        check("…and the wrapper refuses", wrapper(["--version"], key: "k").status != 0)
        // The runtime root redirected out.
        resetRuntime()
        o = try outsideDir()
        try fm.createSymbolicLink(atPath: RuntimePaths.runtimeRoot.path, withDestinationPath: o.path)
        let r2 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
        check("runtime → outside: nothing installed, the outside directory untouched",
              { if case .converged = r2 { return false }; return true }() && untouched(o), "\(r2)")
        // A published version directory swapped for a link to an outside copy.
        resetRuntime()
        _ = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
        let rec = receipt(.agentmail)!.verifiedRecord!
        let vdir = am.appendingPathComponent(rec.directory)
        o = try outsideDir()
        let copy = o.appendingPathComponent("copy")
        try fm.copyItem(at: vdir, to: copy)
        try fm.removeItem(at: vdir)
        try fm.createSymbolicLink(atPath: vdir.path, withDestinationPath: copy.path)
        let run = wrapper(["--version"], key: "k")
        check("v/<name> → an outside copy with the same bytes: the wrapper refuses, never executes it", run.status != 0 && !run.stdout.contains("agentmail 1.3.0"), run.stdout)
        let h = await PrivateRuntimeEngine.recover(amSpec())
        check("…recovery does not report it ready", { if case .ready = h { return false }; return true }(), "\(h)")
        // Briglia's bin directory redirected out: the wrapper is not written there.
        resetRuntime()
        o = try outsideDir()
        try fm.createSymbolicLink(atPath: RuntimePaths.binDir.path, withDestinationPath: o.path)
        check("bin → outside: writing the wrapper refuses, outside untouched", (try? AgentMailService.ensureWrapper()) == nil && untouched(o))
        try? fm.removeItem(at: RuntimePaths.binDir)
        // A deliberately relocated data root (the root itself a link) still works.
        // (Run in a subprocess: the post-publication probe resolves the data
        // root from the environment, like the real daemon.)
        resetRuntime()
        let xdg = scratch.appendingPathComponent("xdg-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let realRoot = scratch.appendingPathComponent("relocated-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: xdg, withIntermediateDirectories: true)
        try fm.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: xdg.appendingPathComponent("briglia").path, withDestinationPath: realRoot.path)
        let r3 = subprocess("agentmail-converge", extraEnv: ["XDG_DATA_HOME": xdg.path])
        #if os(macOS)
        // /private alias spellings (/tmp ↔ /private/tmp, /var ↔ /private/var) of an existing root.
        let xdgA = scratch.appendingPathComponent("xdg-alias-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: xdgA.appendingPathComponent("briglia"), withIntermediateDirectories: true)
        let p0 = xdgA.path
        let alias = p0.hasPrefix("/private/") ? String(p0.dropFirst("/private".count))
            : (p0.hasPrefix("/tmp/") || p0.hasPrefix("/var/")) ? "/private" + p0 : nil
        if let alias {
            let rA = subprocess("agentmail-converge", extraEnv: ["XDG_DATA_HOME": alias])
            check("an existing data root spelled through a /private alias installs normally (missing descendants under it)",
                  rA.stdout.contains("RESULT converged"), rA.stdout + rA.stderr)
        }
        #endif
        check("a relocated data root (the root itself a symlink) installs normally",
              r3.stdout.contains("RESULT converged") && RuntimeFS.kind(realRoot.appendingPathComponent("runtime/agentmail/current").path) == .symlink, r3.stdout + r3.stderr)
        resetRuntime()
    }

    // MARK: Shared helpers

    var dataRoot: URL { RuntimePaths.dataRoot }
    var am: URL { RuntimePaths.dir(.agentmail) }

    func resetRuntime() {
        try? fm.removeItem(at: RuntimePaths.runtimeRoot)
        try? fm.removeItem(at: RuntimePaths.binDir)
        try? fm.removeItem(at: RuntimePaths.fallbackBinDir)
    }

    /// A fake upstream archive whose `agentmail` prints its version and the
    /// key it received. `failPublished`: fails when run from a published
    /// v/ directory (staged probe passes, post-publication probe fails).
    func agentMailFixture(_ version: String, failPublished: Bool = false, failStaged: Bool = false) throws -> (path: String, sha: String) {
        let dir = scratch.appendingPathComponent("am-\(version)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let top = dir.appendingPathComponent("agentmail-cli-test", isDirectory: true)
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        var s = "#!/bin/sh\n"
        if failStaged { s += "exit 7\n" }
        if failPublished { s += "case \"$0\" in */v/*) exit 9;; esac\n" }
        s += "echo \"agentmail \(version) key=${AGENTMAIL_API_KEY:-none}\"\n"
        try s.write(to: top.appendingPathComponent("agentmail"), atomically: true, encoding: .utf8)
        chmod(top.appendingPathComponent("agentmail").path, 0o755)
        let archive = dir.appendingPathComponent("am.tar.gz")
        let r = RuntimeProcess.runBlocking("/usr/bin/tar", ["-czf", archive.path, "-C", dir.path, "agentmail-cli-test"], env: nil, cwd: nil, timeout: 30)
        guard r.status == 0 else { throw RuntimeError("tar failed") }
        return (archive.path, RuntimeFS.sha256(file: archive)!)
    }

    func useAgentMail(_ fx: (path: String, sha: String), version: String) {
        setenv("BRIGLIA_AGENTMAIL_TEST_ARCHIVE", fx.path, 1)
        setenv("BRIGLIA_AGENTMAIL_TEST_SHA256", fx.sha, 1)
        setenv("BRIGLIA_AGENTMAIL_TEST_VERSION", version, 1)
    }

    func amSpec() -> RuntimeSpec { AgentMailService.runtimeSpec(pin: AgentMailService.runtimePin!) }
    func receipt(_ c: RuntimeComponent) -> RuntimeReceipt? { (try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c))) ?? nil }
    func current(_ c: RuntimeComponent) -> String? { RuntimeFS.readLink(RuntimePaths.current(c)) }
    func sel() -> RuntimeSelectionFile { RuntimeSelectionStore.peek() ?? RuntimeSelectionFile() }

    /// Runs the wrapper like the agent's Bash would.
    func wrapper(_ args: [String], key: String? = nil, extraEnv: [String: String] = [:]) -> RuntimeProcess.Result {
        var env = ["PATH": "/usr/bin:/bin", "HOME": home, "XDG_CONFIG_HOME": home + "/.config", "XDG_DATA_HOME": home + "/.local/share",
                   "CFFIXED_USER_HOME": home]
        for k in ["BRIGLIA_AGENTMAIL_TEST_ARCHIVE", "BRIGLIA_AGENTMAIL_TEST_SHA256", "BRIGLIA_AGENTMAIL_TEST_VERSION"] {
            if let v = ProcessInfo.processInfo.environment[k] { env[k] = v }
        }
        if let key { env["AGENTMAIL_API_KEY"] = key }
        for (k, v) in extraEnv { env[k] = v }
        return RuntimeProcess.runBlocking(AgentMailService.wrapperURL.path, args, env: env, cwd: nil, timeout: 30)
    }

    func subprocess(_ op: String, crash: String? = nil, extraEnv: [String: String] = [:]) -> RuntimeProcess.Result {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        if let crash { env["BRIGLIA_RUNTIME_CRASH"] = crash } else { env.removeValue(forKey: "BRIGLIA_RUNTIME_CRASH") }
        let me = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).path
        return RuntimeProcess.runBlocking(me, ["__private-runtime-selftest", "--op", op], env: env, cwd: nil, timeout: 120)
    }

    // MARK: AgentMail

    func agentMailBasics() async throws {
        resetRuntime()
        let a = try agentMailFixture("1.3.0")
        useAgentMail(a, version: "1.3.0")
        let r1 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
        try? AgentMailService.ensureWrapper()
        guard case .converged(let rec) = r1 else { check("first install converges", false, "\(r1)"); return }
        check("first install (no current yet): staged probe direct, then current → v/, verified, mirror", current(.agentmail) == rec.directory
              && receipt(.agentmail)?.verified == rec.directory && sel()[.agentmail].mirror?.directory == rec.directory,
              "current \(current(.agentmail) ?? "-") verified \(receipt(.agentmail)?.verified ?? "-") mirror \(sel()[.agentmail].mirror?.directory ?? "-")")
        check("journal deleted after a successful commit", RuntimeFS.kind(RuntimePaths.journal(.agentmail).path) == .absent)
        check("nothing written to ~/.local/bin", ((try? fm.contentsOfDirectory(atPath: home + "/.local/bin")) ?? []).isEmpty)
        let w = wrapper(["--version"], key: "caller-key")
        check("wrapper runs the validated binary with the caller's key", w.status == 0 && w.stdout.contains("agentmail 1.3.0 key=caller-key"), w.stdout + w.stderr)
        try fm.removeItem(atPath: a.path)
        let r2 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .auto)
        check("second start: equality fast path, no download (archive gone)", { if case .upToDate = r2 { return true }; return false }(), "\(r2)")

        // A → B, B staged while A stays current.
        let b = try agentMailFixture("1.4.0")
        useAgentMail(b, version: "1.4.0")
        let r3 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .explicit)
        guard case .converged(let recB) = r3 else { check("A → B converges", false, "\(r3)"); return }
        check("A → B: current and verified move to B, A kept until GC", current(.agentmail) == recB.directory
              && fm.fileExists(atPath: am.appendingPathComponent(rec.directory).path))
        let gc = PrivateRuntimeEngine.collectGarbage(amSpec())
        check("GC removes the unreferenced, receipt-matching A", !fm.fileExists(atPath: am.appendingPathComponent(rec.directory).path)
              && receipt(.agentmail)?.record(directory: rec.directory) == nil, gc.joined(separator: "; "))

        // B → C whose published probe fails → back to B.
        let c = try agentMailFixture("1.5.0", failPublished: true)
        useAgentMail(c, version: "1.5.0")
        let r4 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .auto)
        check("post-publication probe failure → rollback to the copy that was running", { if case .failed = r4 { return true }; return false }()
              && current(.agentmail) == recB.directory && receipt(.agentmail)?.verified == recB.directory
              && RuntimeFS.kind(RuntimePaths.journal(.agentmail).path) == .absent, "\(r4)")
        check("failed attempt recorded with the reason", sel()[.agentmail].attempts.last?.result?.hasPrefix("failed: probe") == true)
        let r5 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .auto)
        check("automatic retry inside the hour is throttled", { if case .throttled = r5 { return true }; return false }(), "\(r5)")

        // Archive hash mismatch → nothing committed.
        setenv("BRIGLIA_AGENTMAIL_TEST_SHA256", String(repeating: "0", count: 64), 1)
        let r6 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .explicit)
        check("archive hash mismatch → refused, current unchanged", { if case .failed(let w) = r6 { return w.contains("checksum") }; return false }()
              && current(.agentmail) == recB.directory, "\(r6)")

        // First install whose published probe fails → no current, unavailable.
        resetRuntime()
        let d = try agentMailFixture("1.3.0", failPublished: true)
        useAgentMail(d, version: "1.3.0")
        let r7 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
        check("failed first install → no current link, no verified record", { if case .failed = r7 { return true }; return false }()
              && current(.agentmail) == nil && receipt(.agentmail)?.verified == nil, "\(r7)")
        check("…and the wrapper refuses instead of running anything", !AgentMailService.agentMailBrokerInstalled())

        // Generation bump between staging and commit → abandoned.
        resetRuntime()
        let e = try agentMailFixture("1.3.0")
        useAgentMail(e, version: "1.3.0")
        let gate = RuntimeIdleGate(acquire: { RuntimeSelectionStore.bumpGeneration(); return true }, release: {}, stillWanted: { true })
        let t8 = Date()
        let r8 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install, idle: gate)
        let elapsed8 = Date().timeIntervalSince(t8)
        check("wipe/import/provider change (generation bump) before the commit → abandoned, nothing published",
              { if case .abandoned = r8 { return true }; return false }() && current(.agentmail) == nil
              && ((try? fm.contentsOfDirectory(atPath: RuntimePaths.versions(.agentmail).path)) ?? []).isEmpty, "\(r8)")
        let last8 = sel()[.agentmail].attempts.last
        check("…the abandonment is persisted (result + finish time) and returns promptly (< 10 s, never the 30 s self-lock wait)",
              last8?.result == "abandoned" && last8?.finishedAt != nil && elapsed8 < 10, "\(String(describing: last8)) \(elapsed8)s")
        // A real provider transition (the settings store, not a synthetic bump).
        resetRuntime()
        try fm.createDirectory(at: RuntimePaths.runtimeRoot, withIntermediateDirectories: true)
        try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: EmailCalendarProvider.agentmail.rawValue)
        let gateP = RuntimeIdleGate(acquire: { (try? KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: EmailCalendarProvider.none.rawValue)) != nil },
                                    release: {}, stillWanted: { true })
        let rP = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install, idle: gateP)
        check("a real email-provider change (settings store) during staging bumps the generation → abandoned, nothing published",
              { if case .abandoned = rP { return true }; return false }() && current(.agentmail) == nil, "\(rP)")
        try? KeychainHelper.delete(key: KeychainHelper.emailCalendarProviderKey)
        let gate2 = RuntimeIdleGate(acquire: { true }, release: {}, stillWanted: { false })
        let r9 = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install, idle: gate2)
        check("provider no longer AgentMail at commit → abandoned", { if case .abandoned = r9 { return true }; return false }(), "\(r9)")
    }

    func agentMailExec() async throws {
        resetRuntime()
        let a = try agentMailFixture("1.3.0")
        useAgentMail(a, version: "1.3.0")
        _ = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
        try AgentMailService.ensureWrapper()
        let noKey = wrapper(["inboxes", "list"])
        check("ordinary call without a stored key → refused before the binary runs", noKey.status == 1 && noKey.stderr.contains("no AgentMail API key"), noKey.stderr)
        let probeOther = wrapper(["--version"], key: "k", extraEnv: ["BRIGLIA_AGENTMAIL_PROBE": "deadbeef"])
        check("probe variable naming no live attempt → refused", probeOther.status == 1 && probeOther.stderr.contains("probe refused"), probeOther.stderr)
        // A live committing journal for the current target: probe mode allowed, placeholder key forced.
        let rec = receipt(.agentmail)!.verifiedRecord!
        let j = RuntimeJournal(attemptId: "a1b2", oldTarget: nil, newTarget: rec.directory, newRecord: rec, state: "committing")
        try RuntimeFS.writeJSON(j, RuntimePaths.journal(.agentmail))
        let probe = wrapper(["--version"], key: "caller-key", extraEnv: ["BRIGLIA_AGENTMAIL_PROBE": "a1b2"])
        check("probe mode: matching journal → runs with the PLACEHOLDER key (caller key ignored)",
              probe.status == 0 && probe.stdout.contains("key=\(AgentMailService.probePlaceholderKey)"), probe.stdout + probe.stderr)
        let probeArgs = wrapper(["inboxes", "list"], key: "k", extraEnv: ["BRIGLIA_AGENTMAIL_PROBE": "a1b2"])
        check("probe mode allows only --version", probeArgs.status == 1 && probeArgs.stderr.contains("only --version"))
        try RuntimeFS.remove(RuntimePaths.journal(.agentmail))
        // Hold: ordinary calls refused even with a caller key; matching probe allowed.
        _ = try RuntimeSelectionStore.update { s in var st = s[.agentmail]; st.hold = RuntimeHold(pin: rec.pin, reason: "repair-in-progress", since: Date(), attemptId: "r9"); s[.agentmail] = st }
        let held = wrapper(["inboxes", "list"], key: "caller-key")
        check("hold: ordinary call with a caller-supplied key → still refused", held.status == 1 && held.stderr.contains("AgentMail is off"), held.stderr)
        try RuntimeFS.writeJSON(RuntimeJournal(attemptId: "r9", oldTarget: nil, newTarget: rec.directory, newRecord: rec, state: "committing", mode: "repair"), RuntimePaths.journal(.agentmail))
        let p5 = wrapper(["--version"], extraEnv: ["BRIGLIA_AGENTMAIL_PROBE": "r9"])
        check("hold: the repair's own p5 probe (matching attempt) is permitted", p5.status == 0, p5.stderr)
        let p5other = wrapper(["--version"], extraEnv: ["BRIGLIA_AGENTMAIL_PROBE": "zz"])
        check("hold: a probe for another attempt is refused", p5other.status == 1)
        try RuntimeFS.remove(RuntimePaths.journal(.agentmail))
        _ = try RuntimeSelectionStore.update { s in var st = s[.agentmail]; st.hold = nil; s[.agentmail] = st }
        // Tampered binary.
        let bin = am.appendingPathComponent(rec.directory).appendingPathComponent("agentmail-bin")
        try "#!/bin/sh\necho evil\n".write(to: bin, atomically: false, encoding: .utf8)
        let tampered = wrapper(["--version"], key: "k")
        check("an altered binary (current link intact) → refused, never executed", tampered.status == 1 && !tampered.stdout.contains("evil"), tampered.stdout)
        check("…syntax falls back to the pin, never to the altered copy", AgentMailService.cliSyntax(forInstalledVersion: AgentMailService.installedCLIVersion()) == .v1Nested)
    }

    func agentMailRepair() async throws {
        resetRuntime()
        let a = try agentMailFixture("1.3.0")
        useAgentMail(a, version: "1.3.0")
        _ = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
        // A hold on an otherwise intact install (e.g. a repair that was
        // interrupted after its copy passed) still wins: AgentMail stays off.
        _ = try RuntimeSelectionStore.update { $0[.agentmail].hold = RuntimeHold(pin: amSpec().pin, reason: "repair-interrupted", since: Date(), attemptId: nil) }
        let intactHeld = await PrivateRuntimeEngine.recover(amSpec())
        check("hold on an intact install → recovery reports held (never ready), mirror cleared",
              { if case .held(let x) = intactHeld { return x.reason == "repair-interrupted" }; return false }() && sel()[.agentmail].mirror == nil, "\(intactHeld)")
        _ = try RuntimeSelectionStore.update { $0[.agentmail].hold = nil }
        let rec = receipt(.agentmail)!.verifiedRecord!
        let bin = am.appendingPathComponent(rec.directory).appendingPathComponent("agentmail-bin")
        try "#!/bin/sh\necho damaged\n".write(to: bin, atomically: false, encoding: .utf8)
        let h = await PrivateRuntimeEngine.recover(amSpec())
        check("damaged copy → startup recovery writes the hold (reason unknown), AgentMail off", { if case .held(let x) = h { return x.reason == "unknown" }; return false }(), "\(h)")
        let r = await PrivateRuntimeEngine.converge(amSpec(), trigger: .auto)
        check("held, same pin → no automatic convergence", { if case .held = r { return true }; return false }(), "\(r)")
        let auto = await AgentMailRepair.run(spec: amSpec(), automatic: true, idle: nil)
        check("held, same pin → no automatic repair either", { if case .throttled = auto { return true }; return false }(), "\(auto)")
        // Repair whose staged probe fails → stays off, nothing re-selected.
        let bad = try agentMailFixture("1.3.0", failStaged: true)
        useAgentMail(bad, version: "1.3.0")
        let f = await AgentMailRepair.run(spec: amSpec(), automatic: false, idle: nil)
        check("failed repair → AgentMail stays off (hold reason repair-failed), the damaged copy is not touched",
              { if case .failed = f { return true }; return false }() && sel()[.agentmail].hold?.reason == "repair-failed"
              && (try? String(contentsOf: bin, encoding: .utf8))?.contains("damaged") == true, "\(f)")
        for i in 1...2 {
            let again = await PrivateRuntimeEngine.recover(amSpec())
            check("clean restart \(i) after the failed repair: still held, no older copy restored", { if case .held = again { return true }; return false }() && !AgentMailService.agentMailBrokerInstalled())
        }
        // Repair whose post-publication (p5) probe fails → link removed, off.
        let p5bad = try agentMailFixture("1.3.0", failPublished: true)
        useAgentMail(p5bad, version: "1.3.0")
        let f5 = await AgentMailRepair.run(spec: amSpec(), automatic: false, idle: nil)
        check("repair whose p5 probe fails → no current link at all (never the prior copy), hold repair-failed",
              { if case .failed = f5 { return true }; return false }() && current(.agentmail) == nil
              && sel()[.agentmail].hold?.reason == "repair-failed" && RuntimeFS.kind(RuntimePaths.journal(.agentmail).path) == .absent, "\(f5)")
        // Explicit repair with a good archive.
        useAgentMail(a, version: "1.3.0")
        let ok = await AgentMailRepair.run(spec: amSpec(), automatic: false, idle: nil)
        check("explicit repair → repaired into a NEW directory, hold removed, working", { if case .repaired = ok { return true }; return false }()
              && sel()[.agentmail].hold == nil && AgentMailService.agentMailBrokerInstalled()
              && receipt(.agentmail)?.verified != rec.directory, "\(ok)")
        check("the damaged directory is kept and reported by GC, never deleted",
              fm.fileExists(atPath: bin.path) && PrivateRuntimeEngine.collectGarbage(amSpec()).contains { $0.contains("does not match") })
        // New pin while held: one automatic repair.
        try "#!/bin/sh\necho damaged\n".write(to: URL(fileURLWithPath: am.appendingPathComponent(receipt(.agentmail)!.verified!).path + "/agentmail-bin"), atomically: false, encoding: .utf8)
        _ = await PrivateRuntimeEngine.recover(amSpec())
        let n = try agentMailFixture("1.4.0")
        useAgentMail(n, version: "1.4.0")
        let autoNew = await AgentMailRepair.run(spec: amSpec(), automatic: true, idle: nil)
        check("held pin ≠ compiled pin (after /upgrade) → ONE automatic repair for the new pin", { if case .repaired = autoNew { return true }; return false }()
              && receipt(.agentmail)?.verifiedRecord?.version == "1.4.0", "\(autoNew)")
        // A failing automatic new-pin repair stays held for the new pin.
        try "#!/bin/sh\necho damaged\n".write(to: URL(fileURLWithPath: am.appendingPathComponent(receipt(.agentmail)!.verified!).path + "/agentmail-bin"), atomically: false, encoding: .utf8)
        _ = await PrivateRuntimeEngine.recover(amSpec())
        let n2 = try agentMailFixture("1.5.0", failStaged: true)
        useAgentMail(n2, version: "1.5.0")
        let autoFail = await AgentMailRepair.run(spec: amSpec(), automatic: true, idle: nil)
        let held = sel()[.agentmail].hold
        check("failed automatic new-pin repair → held FOR THE NEW PIN, off", { if case .failed = autoFail { return true }; return false }()
              && held?.pin.version == "1.5.0" && held?.reason == "repair-failed", "\(autoFail) \(String(describing: held))")
        let autoAgain = await AgentMailRepair.run(spec: amSpec(), automatic: true, idle: nil)
        check("…no second automatic attempt for that pin", { if case .throttled = autoAgain { return true }; return false }(), "\(autoAgain)")
    }

    /// One crash point of the ordinary commit; a fresh process then recovers.
    func agentMailCrashes() async throws {
        let points: [(String, Bool)] = [   // (point, the new copy must be the one in use after recovery)
            ("after-stage", false), ("after-receipt", false), ("after-committing", false), ("after-switch", true),
            ("after-probed", true), ("after-verified", true), ("after-mirror", true)]
        for (point, newWins) in points {
            resetRuntime()
            let a = try agentMailFixture("1.3.0")
            useAgentMail(a, version: "1.3.0")
            _ = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
            let recA = receipt(.agentmail)!.verifiedRecord!
            let b = try agentMailFixture("1.4.0")
            useAgentMail(b, version: "1.4.0")
            let crashed = subprocess("agentmail-converge", crash: "agentmail:\(point)")
            let rec = subprocess("agentmail-recover")
            let r = receipt(.agentmail)
            let inUse = r?.verifiedRecord?.version
            let consistent = current(.agentmail) == r?.verified && RuntimeFS.kind(RuntimePaths.journal(.agentmail).path) == .absent
            check("crash at \(point) (killed: \(crashed.status != 0)) → recovery: current = verified = \(newWins ? "1.4.0" : "1.3.0"), journal gone",
                  inUse == (newWins ? "1.4.0" : "1.3.0") && consistent && sel()[.agentmail].mirror == r?.verifiedRecord,
                  "in use \(inUse ?? "-") current \(current(.agentmail) ?? "-") journal \(RuntimeFS.kind(RuntimePaths.journal(.agentmail).path)) — \(rec.stdout)")
            if !newWins {
                check("…the old copy \(recA.version) still runs after recovery", wrapper(["--version"], key: "k").stdout.contains("1.3.0"))
            }
            let again = await PrivateRuntimeEngine.converge(amSpec(), trigger: .explicit)
            check("…and the next convergence completes or is up to date", { switch again { case .upToDate, .converged: return true; default: return false } }(), "\(again)")
        }
        // Crash during the recovery probe itself (journal committing + current = new): next run probes again.
        resetRuntime()
        let a = try agentMailFixture("1.3.0")
        useAgentMail(a, version: "1.3.0")
        _ = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
        let b = try agentMailFixture("1.4.0", failPublished: true)
        useAgentMail(b, version: "1.4.0")
        _ = subprocess("agentmail-converge", crash: "agentmail:after-switch")
        let h = await PrivateRuntimeEngine.recover(amSpec())
        check("committing + new current whose re-probe FAILS → rolled back to the old copy, metadata never advanced",
              { if case .ready(let r) = h { return r.version == "1.3.0" }; return false }() && current(.agentmail) == receipt(.agentmail)?.verified, "\(h)")
    }

    func agentMailRepairCrashes() async throws {
        // (point, outcome after recovery: true = repaired, false = off)
        let points: [(String, Bool)] = [("repair-after-hold", false), ("repair-after-stage", false), ("repair-after-p1a", false),
                                         ("repair-after-p1b", false), ("repair-after-p2", false), ("repair-after-p3", false),
                                         ("repair-after-p4", false), ("repair-after-probed", true), ("repair-after-e1", true),
                                         ("repair-after-e3", true)]
        for (point, repaired) in points {
            resetRuntime()
            let a = try agentMailFixture("1.3.0")
            useAgentMail(a, version: "1.3.0")
            _ = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
            let first = receipt(.agentmail)!.verifiedRecord!
            try "#!/bin/sh\necho damaged\n".write(to: URL(fileURLWithPath: am.appendingPathComponent(first.directory).path + "/agentmail-bin"), atomically: false, encoding: .utf8)
            _ = await PrivateRuntimeEngine.recover(amSpec())
            _ = subprocess("agentmail-repair", crash: "agentmail:\(point)")
            for i in 1...2 {
                let h = await PrivateRuntimeEngine.recover(amSpec())
                let ok: Bool = { if repaired, case .ready = h { return sel()[.agentmail].hold == nil }
                                 if !repaired, case .held = h { return !AgentMailService.agentMailBrokerInstalled() }
                                 return false }()
                check("repair crash at \(point), restart \(i) → \(repaired ? "repaired (no re-probe)" : "AgentMail off, no older copy selected")", ok, "\(h)")
            }
            check("…the damaged copy was never deleted and never made usable again", fm.fileExists(atPath: am.appendingPathComponent(first.directory).path)
                  && (repaired ? receipt(.agentmail)?.verified != first.directory : !AgentMailService.agentMailBrokerInstalled()))
            if ["repair-after-p3", "repair-after-p4"].contains(point) {
                check("…a repair journal found at committing: the link is removed, no re-probe, no fallback", current(.agentmail) == nil
                      && RuntimeFS.kind(RuntimePaths.journal(.agentmail).path) == .absent && sel()[.agentmail].hold?.reason == "repair-interrupted")
            }
        }
    }

    func agentMailLegacy() async throws {
        resetRuntime()
        let lb = URL(fileURLWithPath: home + "/.local/bin", isDirectory: true)
        let legacyBin = lb.appendingPathComponent("agentmail-bin-1.3.0-0123456789ab")
        try "#!/bin/sh\necho legacy\n".write(to: legacyBin, atomically: true, encoding: .utf8)
        chmod(legacyBin.path, 0o755)
        try AgentMailService.legacyWrapperScript(adaPath: "/old/briglia", realBinaryPath: legacyBin.path).write(to: lb.appendingPathComponent("agentmail"), atomically: true, encoding: .utf8)
        chmod(lb.appendingPathComponent("agentmail").path, 0o755)
        try "{\"state\": \"committing\"}".write(to: lb.appendingPathComponent("agentmail.tx.json"), atomically: true, encoding: .utf8)
        func snapshot() -> [String: String] {
            var out: [String: String] = [:]
            for n in (try? fm.contentsOfDirectory(atPath: lb.path)) ?? [] {
                let p = lb.appendingPathComponent(n).path
                let attrs = try? fm.attributesOfItem(atPath: p)
                out[n] = "\(RuntimeFS.sha256(file: URL(fileURLWithPath: p)) ?? "-")@\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }
            return out
        }
        let before = snapshot()
        check("legacy version read inspect-only for the prompt syntax while no private copy exists", AgentMailService.installedCLIVersion() == "1.3.0")
        let a = try agentMailFixture("1.3.0")
        useAgentMail(a, version: "1.3.0")
        _ = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
        _ = await AgentMailRepair.run(spec: amSpec(), automatic: false, idle: nil)
        let findings = AgentMailService.legacyFindings()
        check("every ~/.local/bin file byte-identical, mtime unchanged after install + repair", snapshot() == before, "\(snapshot())")
        check("doctor reports the old copy and the interrupted public journal (with manual commands)",
              findings.contains { $0.contains("old Briglia copy") && $0.contains("rm '") } && findings.contains { $0.contains("interrupted older AgentMail install") && $0.contains("committing") },
              findings.joined(separator: " | "))
        // /deleteuserdata
        try AgentMailService.wipePrivateInstall()
        check("wipe: Briglia's private AgentMail copy, receipt and hold gone; ~/.local/bin untouched",
              current(.agentmail) == nil && receipt(.agentmail) == nil && sel()[.agentmail].hold == nil && snapshot() == before)
        check("wipe bumps the lifecycle generation", sel().generation >= 1)
        // Corrupt selected.json → quarantined, AgentMail held.
        _ = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
        try "{not json".write(to: RuntimePaths.selectionFile, atomically: true, encoding: .utf8)
        let h = await PrivateRuntimeEngine.recover(amSpec())
        let set = ((try? fm.contentsOfDirectory(atPath: RuntimePaths.runtimeRoot.path)) ?? []).filter { $0.hasPrefix("selected.json.corrupt-") }
        check("corrupt selected.json → set aside (kept), AgentMail held until a repair (its hold may have been lost)",
              !set.isEmpty && { if case .held = h { return true }; return false }(), "\(h) \(set)")
        // R2: whichever component reads the corrupt file first, AgentMail's
        // hold survives (settled failed repair: hold, no current link).
        for first in ["node", "generic update", "crash right after the quarantine", "crash between the copy and the replacement", "unreadable bytes", "non-regular entry"] {
            // chmod 000 does not stop root (Linux CI containers run as root):
            // there the "non-regular entry" variant below exercises the same
            // refusal branch of RuntimeSelectionStore.load() root-proof.
            if first == "unreadable bytes" && geteuid() == 0 {
                print("  · R2: unreadable selection bytes skipped: running as root, which can read a mode-000 file (the non-regular-entry variant covers the same refusal)")
                continue
            }
            resetRuntime()
            useAgentMail(a, version: "1.3.0")
            _ = await PrivateRuntimeEngine.converge(amSpec(), trigger: .install)
            try RuntimeFS.remove(RuntimePaths.current(.agentmail))
            _ = try RuntimeSelectionStore.update { $0[.agentmail].hold = RuntimeHold(pin: amSpec().pin, reason: "repair-interrupted", since: Date(), attemptId: nil) }
            try "{not json".write(to: RuntimePaths.selectionFile, atomically: true, encoding: .utf8)
            switch first {
            case "node":
                setenv("BRIGLIA_NODE_TEST_ARCHIVE", scratch.appendingPathComponent("no-such-node.tar.gz").path, 1)
                setenv("BRIGLIA_NODE_TEST_SHA256", String(repeating: "2", count: 64), 1)
                setenv("BRIGLIA_NODE_TEST_VERSION", "24.22.1", 1)
                if let np = NodeRuntime.runtimePin { _ = await PrivateRuntimeEngine.converge(NodeRuntime.spec(pin: np), trigger: .explicit) }
                unsetenv("BRIGLIA_NODE_TEST_ARCHIVE"); unsetenv("BRIGLIA_NODE_TEST_SHA256"); unsetenv("BRIGLIA_NODE_TEST_VERSION")
            case "generic update":
                _ = try RuntimeSelectionStore.update { _ in }
            case "crash between the copy and the replacement":
                _ = subprocess("selection-update", crash: "agentmail:after-selection-copy")
                check("R2: interrupted between copy and replacement → the corrupt file is still in place",
                      (try? String(contentsOf: RuntimePaths.selectionFile, encoding: .utf8)) == "{not json")
            case "unreadable bytes":
                chmod(RuntimePaths.selectionFile.path, 0o000)
                let threw = (try? RuntimeSelectionStore.update { _ in }) == nil
                check("R2: unreadable selection bytes → the writer refuses and leaves the file in place",
                      threw && RuntimeFS.kind(RuntimePaths.selectionFile.path) == .regular)
            case "non-regular entry":
                // A directory where the selection file belongs: unreadable for
                // every user, root included.
                try fm.removeItem(at: RuntimePaths.selectionFile)
                try fm.createDirectory(at: RuntimePaths.selectionFile, withIntermediateDirectories: false)
                let threw = (try? RuntimeSelectionStore.update { _ in }) == nil
                check("R2: non-regular selection entry (root-proof) → the writer refuses and leaves it in place",
                      threw && RuntimeFS.kind(RuntimePaths.selectionFile.path) == .directory)
            default:
                _ = subprocess("selection-update", crash: "agentmail:after-selection-quarantine")
            }
            for restart in 1...2 {
                let rh = await PrivateRuntimeEngine.recover(amSpec())
                let run = wrapper(["--version"], key: "placeholder")
                let off: Bool = { if case .ready = rh { return false }; if case .held = rh { return true }; return first == "unreadable bytes" || first == "non-regular entry" }()
                check("R2: \(first) → restart \(restart): AgentMail still off, no old copy restored",
                      off && current(.agentmail) == nil && run.status != 0, "\(rh) \(run.status)")
            }
            if first == "non-regular entry" {
                try fm.removeItem(at: RuntimePaths.selectionFile)
            } else {
                chmod(RuntimePaths.selectionFile.path, 0o600)
            }
        }
    }

    // MARK: Node

    func nodeFixture(_ version: String) throws -> (path: String, sha: String) {
        let dir = scratch.appendingPathComponent("node-\(version)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let top = dir.appendingPathComponent("node-v\(version)-test", isDirectory: true)
        try fm.createDirectory(at: top.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try "#!/bin/sh\necho v\(version)\n".write(to: top.appendingPathComponent("bin/node"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho 11.0.0\n".write(to: top.appendingPathComponent("bin/npm"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho 11.0.0\n".write(to: top.appendingPathComponent("bin/npx"), atomically: true, encoding: .utf8)
        for n in ["node", "npm", "npx"] { chmod(top.appendingPathComponent("bin/\(n)").path, 0o755) }
        let archive = dir.appendingPathComponent("node.tar.gz")
        _ = RuntimeProcess.runBlocking("/usr/bin/tar", ["-czf", archive.path, "-C", dir.path, top.lastPathComponent], env: nil, cwd: nil, timeout: 30)
        return (archive.path, RuntimeFS.sha256(file: archive)!)
    }

    func sharedNode(_ version: String, npm: Bool = true) throws -> String {
        let dir = scratch.appendingPathComponent("shared-node-\(version)-\(UUID().uuidString.prefix(6))/bin", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "#!/bin/sh\necho v\(version)\n".write(to: dir.appendingPathComponent("node"), atomically: true, encoding: .utf8)
        chmod(dir.appendingPathComponent("node").path, 0o755)
        if npm {
            try "#!/bin/sh\necho 10.0.0\n".write(to: dir.appendingPathComponent("npm"), atomically: true, encoding: .utf8)
            chmod(dir.appendingPathComponent("npm").path, 0o755)
        }
        return dir.path
    }

    func nodeSelection() async throws {
        resetRuntime()
        let fx = try nodeFixture("24.22.1")
        setenv("BRIGLIA_NODE_TEST_ARCHIVE", fx.path, 1)
        setenv("BRIGLIA_NODE_TEST_SHA256", fx.sha, 1)
        setenv("BRIGLIA_NODE_TEST_VERSION", "24.22.1", 1)
        // Legacy ~/.local/node (an older Briglia's copy) that must never change.
        let legacy = URL(fileURLWithPath: home + "/.local/node/bin", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "#!/bin/sh\necho v22.1.0\n".write(to: legacy.appendingPathComponent("node"), atomically: true, encoding: .utf8)
        chmod(legacy.appendingPathComponent("node").path, 0o755)
        let legacyHash = RuntimeFS.sha256(file: legacy.appendingPathComponent("node"))

        let newer = try sharedNode("26.12.1")
        setenv("BRIGLIA_NODE_TEST_SHARED_DIRS", newer + ":" + legacy.path, 1)
        let r1 = await NodeRuntime.select()
        check("a user Node ≥ the pin with npm → shared-accepted, used by full path, no private copy",
              r1.providerClass == "shared-accepted" && r1.directory == newer && receipt(.node) == nil, "\(r1)")
        check("…no fallback shims", RuntimeFS.kind(RuntimePaths.fallbackBinDir.appendingPathComponent("node").path) == .absent)

        let older = try sharedNode("22.20.0")
        setenv("BRIGLIA_NODE_TEST_SHARED_DIRS", older + ":" + legacy.path, 1)
        let r2 = await NodeRuntime.select()
        check("only Nodes older than the pin (22.x, the legacy copy) → private 24.22.1 installed and selected",
              r2.providerClass == "private-exact" && r2.version == "24.22.1" && receipt(.node)?.verifiedRecord?.version == "24.22.1", "\(r2)")
        check("…fallback shims point at the concrete verified runtime/node/v/<name>/bin (never through current)",
              RuntimeFS.readLink(RuntimePaths.fallbackBinDir.appendingPathComponent("node"))
                == receipt(.node)?.verifiedRecord.map { RuntimePaths.dir(.node).appendingPathComponent($0.directory).appendingPathComponent("bin/node").path })
        let wideNode = widePaths(RuntimePaths.versions(.node))
        check("the private Node tree is owner-only (private storage)", wideNode.isEmpty, wideNode.prefix(5).joined(separator: ", "))
        check("status: the validated private copy reads pinned", RuntimeStatus.node()?.state == .pinned, "\(String(describing: RuntimeStatus.node()))")
        if let vr = receipt(.node)?.verifiedRecord {
            let bin = RuntimePaths.dir(.node).appendingPathComponent(vr.directory).appendingPathComponent(NodeRuntime.spec(pin: NodeRuntime.runtimePin!).binaryRelPath)
            let saved = try Data(contentsOf: bin)
            try Data("#!/bin/sh\necho damaged\n".utf8).write(to: bin)
            check("status: a damaged private copy is not reported pinned (receipt checked, not the cached version)",
                  RuntimeStatus.node()?.state == .unknownState, "\(String(describing: RuntimeStatus.node()))")
            try saved.write(to: bin)
        }
        // R1 round 2: the private selection resolves to the validated concrete
        // binary, never through an unchecked `current`, `v/<name>` or `bin` redirect.
        let concrete = receipt(.node)?.verifiedRecord.map { RuntimePaths.dir(.node).appendingPathComponent($0.directory).appendingPathComponent("bin/node").path }
        check("private selection → the concrete validated v/<name>/bin/node", NodeRuntime.selectedNodeBinary() == concrete && concrete != nil,
              "\(String(describing: NodeRuntime.selectedNodeBinary()))")
        if let target = current(.node) {
            let outside = scratch.appendingPathComponent("outside-node-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try fm.createDirectory(at: outside.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try "#!/bin/sh\necho OUTSIDE_NODE\n".write(to: outside.appendingPathComponent("bin/node"), atomically: true, encoding: .utf8)
            chmod(outside.appendingPathComponent("bin/node").path, 0o755)
            let vtest = RuntimePaths.dir(.node).appendingPathComponent("v/test")
            func picked() -> Bool { (NodeRuntime.selectedNodeBinary().map { !$0.hasPrefix(RuntimePaths.runtimeRoot.path + "/") }) ?? false }
            try RuntimeFS.switchLink(RuntimePaths.current(.node), to: outside.path)
            check("current → outside: not selected", !picked() && NodeRuntime.selectedNodeBinary() == nil)
            try fm.createSymbolicLink(atPath: vtest.path, withDestinationPath: outside.path)
            try RuntimeFS.switchLink(RuntimePaths.current(.node), to: "v/test")
            check("current → v/test → outside: not selected", NodeRuntime.selectedNodeBinary() == nil)
            try fm.removeItem(at: vtest)
            try fm.createDirectory(at: vtest, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: vtest.appendingPathComponent("bin").path, withDestinationPath: outside.appendingPathComponent("bin").path)
            check("current → real v/test whose bin → outside: not selected", NodeRuntime.selectedNodeBinary() == nil)
            try fm.removeItem(at: vtest)
            try RuntimeFS.switchLink(RuntimePaths.current(.node), to: target)
            check("…restored: selected again", NodeRuntime.selectedNodeBinary() == concrete)
            // Receipt and current still agree; the VERIFIED directory itself (or its bin) is redirected
            // to an outside copy with identical bytes (round-3 note: descendant containment on its own).
            let vreal = RuntimePaths.dir(.node).appendingPathComponent(target)
            let moved = scratch.appendingPathComponent("moved-node-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try fm.moveItem(at: vreal, to: moved)
            try fm.createSymbolicLink(atPath: vreal.path, withDestinationPath: moved.path)
            check("verified v/<name> itself → outside identical copy (receipt/current agree): not selected", NodeRuntime.selectedNodeBinary() == nil)
            try fm.removeItem(at: vreal)
            try fm.moveItem(at: moved, to: vreal)
            let realBin = vreal.appendingPathComponent("bin")
            let movedBin = scratch.appendingPathComponent("moved-node-bin-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try fm.moveItem(at: realBin, to: movedBin)
            try fm.createSymbolicLink(atPath: realBin.path, withDestinationPath: movedBin.path)
            check("verified v/<name>/bin → outside identical copy (receipt/current agree): not selected", NodeRuntime.selectedNodeBinary() == nil)
            try fm.removeItem(at: realBin)
            try fm.moveItem(at: movedBin, to: realBin)
            check("…restored: selected again (2)", NodeRuntime.selectedNodeBinary() == concrete)
        }
        let noNpm = try sharedNode("30.0.0", npm: false)
        setenv("BRIGLIA_NODE_TEST_SHARED_DIRS", noNpm, 1)
        let r3 = await NodeRuntime.select()
        check("a newer Node without npm is not accepted", r3.providerClass == "private-exact", "\(r3)")
        // Briglia's own shim on PATH is never selected as a shared Node.
        setenv("BRIGLIA_NODE_TEST_SHARED_DIRS", RuntimePaths.fallbackBinDir.path, 1)
        check("Briglia's own fallback directory is excluded from shared discovery", NodeRuntime.sharedCandidatePaths().isEmpty)
        // The user's Node is upgraded later → switch to it, shims removed, private kept.
        setenv("BRIGLIA_NODE_TEST_SHARED_DIRS", newer, 1)
        let privateDir = receipt(.node)?.verified
        let r4 = await NodeRuntime.select()
        check("user Node later upgraded above the pin → selection switches to it, shims removed, private dir kept",
              r4.providerClass == "shared-accepted" && RuntimeFS.kind(RuntimePaths.fallbackBinDir.appendingPathComponent("node").path) == .absent
              && privateDir.map { fm.fileExists(atPath: RuntimePaths.dir(.node).appendingPathComponent($0).path) } == true, "\(r4)")
        check("legacy ~/.local/node byte-identical throughout", RuntimeFS.sha256(file: legacy.appendingPathComponent("node")) == legacyHash)

        // Managed mcp.json entry resolves only to the selection.
        let layout = ManagedPlaywright.Layout()
        let token = String(repeating: "a", count: 16)
        let inv = ManagedPlaywright.managedInvocation(token: token, layout: layout)
        let managed = MCPServerConfig(name: ManagedPlaywright.serverName, command: inv.command, arguments: inv.arguments,
                                      environment: [:], disabled: false, secretRefs: [], description: nil,
                                      managed: ManagedPlaywright.managedMarker(token: token))
        if case .managed = ManagedPlaywright.shape(of: managed, layout: layout) {
            check("managed entry's bare node → the selected Node (not PATH)", MCPRegistry.resolveExecutable(config: managed).command == newer + "/node")
        } else {
            check("fixture managed entry classified managed", false)
        }
        let user = MCPServerConfig(name: ManagedPlaywright.serverName, command: "node", arguments: ["x.js"], environment: [:],
                                   disabled: false, secretRefs: [], description: nil, managed: nil)
        check("a user-authored entry named playwright keeps PATH resolution", MCPRegistry.resolveExecutable(config: user).command != newer + "/node")
        _ = try RuntimeSelectionStore.update { s in var st = s[.node]; st.selection = nil; s[.node] = st }
        check("no selection → the managed server is not spawned with some other node",
              MCPRegistry.resolveExecutable(config: managed).command.hasPrefix("/nonexistent/"))

        // Damaged private Node → unknown → fresh copy into a NEW directory.
        setenv("BRIGLIA_NODE_TEST_SHARED_DIRS", older, 1)
        _ = await NodeRuntime.select()
        let v1 = receipt(.node)!.verified!
        let nodeBin = RuntimePaths.dir(.node).appendingPathComponent(v1).appendingPathComponent("bin/node")
        try "#!/bin/sh\necho evil\n".write(to: nodeBin, atomically: false, encoding: .utf8)
        _ = try RuntimeSelectionStore.update { s in var st = s[.node]; st.attempts = []; s[.node] = st }
        let r5 = await NodeRuntime.select()
        check("damaged private Node → fresh verified copy in a new directory, damaged one kept",
              r5.providerClass == "private-exact" && receipt(.node)?.verified != v1 && fm.fileExists(atPath: nodeBin.path), "\(r5)")
        // Hash mismatch → nothing committed (and nothing selected when no valid copy exists).
        resetRuntime()
        setenv("BRIGLIA_NODE_TEST_SHA256", String(repeating: "1", count: 64), 1)
        let r6 = await NodeRuntime.select()
        check("archive hash mismatch with no other Node → unavailable, nothing installed", r6.providerClass == "unavailable" && receipt(.node)?.verified == nil, "\(r6)")
        // Crash after the switch → recovery finishes.
        setenv("BRIGLIA_NODE_TEST_SHA256", fx.sha, 1)
        resetRuntime()
        _ = subprocess("node-converge", crash: "node:after-switch")
        let h = await PrivateRuntimeEngine.recover(NodeRuntime.spec(pin: NodeRuntime.runtimePin!))
        check("Node crash after the switch → recovery re-probes and finishes", { if case .ready = h { return true }; return false }(), "\(h)")
        unsetenv("BRIGLIA_NODE_TEST_SHARED_DIRS")
    }

    // MARK: Python

    func pythonEnv() async throws {
        resetRuntime()
        guard let base = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first(where: { dir in
            ["python3.14", "python3.13", "python3.12", "python3.11", "python3"].contains { fm.isExecutableFile(atPath: dir + "/" + $0) }
        }) else { check("python: a base interpreter exists on this runner (skipped otherwise)", true); return }
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", base, 1)
        setenv("BRIGLIA_PYTHON_MIN_MINOR", "8", 1)
        let (found, _) = await PythonRuntime.findBase()
        guard let found else { print("  · no base python with venv/ensurepip on this runner: Python build checks skipped"); return }
        // A local wheel + its lock (no network).
        let wheels = scratch.appendingPathComponent("wheels", isDirectory: true)
        try fm.createDirectory(at: wheels, withIntermediateDirectories: true)
        let mk = """
        import sys, zipfile, hashlib, base64
        d, name, ver = sys.argv[1], sys.argv[2], sys.argv[3]
        whl = f"{d}/{name}-{ver}-py3-none-any.whl"
        files = {f"{name}/__init__.py": f"VERSION = '{ver}'\\n",
                 f"{name}-{ver}.dist-info/METADATA": f"Metadata-Version: 2.1\\nName: {name}\\nVersion: {ver}\\n",
                 f"{name}-{ver}.dist-info/WHEEL": "Wheel-Version: 1.0\\nGenerator: briglia-selftest\\nRoot-Is-Purelib: true\\nTag: py3-none-any\\n"}
        rec = []
        with zipfile.ZipFile(whl, "w") as z:
            for p, c in files.items():
                z.writestr(p, c)
                h = base64.urlsafe_b64encode(hashlib.sha256(c.encode()).digest()).rstrip(b"=").decode()
                rec.append(f"{p},sha256={h},{len(c)}")
            rec.append(f"{name}-{ver}.dist-info/RECORD,,")
            z.writestr(f"{name}-{ver}.dist-info/RECORD", "\\n".join(rec) + "\\n")
        print(hashlib.sha256(open(whl, "rb").read()).hexdigest())
        """
        func wheel(_ ver: String) -> String {
            RuntimeProcess.runBlocking(found.path, ["-c", mk, wheels.path, "brigliaprobe", ver], env: ["PATH": "/usr/bin:/bin"], cwd: nil, timeout: 60)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func lock(_ ver: String, _ hash: String) throws -> URL {
            let u = scratch.appendingPathComponent("lock-\(ver)-\(hash.prefix(6)).txt")
            try "# briglia-python-lock v1\nbrigliaprobe==\(ver) \\\n    --hash=sha256:\(hash)\n".write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        let h1 = wheel("1.0")
        setenv("BRIGLIA_PYTHON_TEST_FIND_LINKS", wheels.path, 1)
        setenv("BRIGLIA_PYTHON_TEST_PROBE", "brigliaprobe", 1)
        setenv("BRIGLIA_PYTHON_TEST_LOCK", try lock("1.0", h1).path, 1)
        check("before any venv: briglia-python refuses (never the shared python3)", { if case .refuse(let w) = PythonRuntime.execDecision() { return w.contains("not set up") }; return false }())
        setenv("BRIGLIA_PYTHON_TEST_LEGACY_PROBE", "brigliaprobe_never_installed", 1)
        let auto0 = await PythonRuntime.converge(trigger: .auto)
        check("startup on a machine that never set up Python features → nothing built", auto0 == .notSetUp && receipt(.python) == nil, "\(auto0)")
        setenv("BRIGLIA_PYTHON_TEST_LEGACY_PROBE", "json", 1)   // stands for a package already importable from the shared python3
        let auto1 = await PythonRuntime.converge(trigger: .auto)
        check("startup where the shared python3 already had the packages (old setup) → one-time private build", { if case .ready = auto1 { return true }; return false }(), "\(auto1)")
        resetRuntime()
        unsetenv("BRIGLIA_PYTHON_TEST_LEGACY_PROBE")
        let s1 = await PythonRuntime.converge(trigger: .install)
        check("install → venv built at a new v/ path, probed (imports, pip check, installed set = lock + bootstrap)", { if case .ready = s1 { return true }; return false }(), "\(s1)")
        guard case .run(let py) = PythonRuntime.execDecision() else { check("execDecision runs the venv", false); return }
        let imp = RuntimeProcess.runBlocking(py, ["-c", "import brigliaprobe; print(brigliaprobe.VERSION)"], env: ["PATH": "/usr/bin:/bin"], cwd: nil, timeout: 30)
        check("the venv imports the locked package", imp.stdout.contains("1.0"), imp.stderr)
        let widePy = widePaths(RuntimePaths.versions(.python))
        check("the built venv is owner-only (private storage)", widePy.isEmpty, widePy.prefix(5).joined(separator: ", "))
        let shared = RuntimeProcess.runBlocking(py, ["-c", "import json, sys; print(sys.prefix != sys.base_prefix)"], env: ["PATH": "/usr/bin:/bin"], cwd: nil, timeout: 30)
        check("…isolated from the shared site-packages", shared.stdout.contains("True"))
        let dir1 = receipt(.python)?.verified
        let s2 = await PythonRuntime.converge(trigger: .auto)
        check("second start: up to date, nothing rebuilt", { if case .ready = s2 { return true }; return false }() && receipt(.python)?.verified == dir1, "\(s2)")
        // Lock change → rebuild into a new directory.
        let h2 = wheel("2.0")
        setenv("BRIGLIA_PYTHON_TEST_LOCK", try lock("2.0", h2).path, 1)
        let s3 = await PythonRuntime.converge(trigger: .auto)
        check("new lock → rebuilt into a new directory, the old one kept until GC", { if case .ready = s3 { return true }; return false }()
              && receipt(.python)?.verified != dir1, "\(s3)")
        // R3: the tree just replaced survives this start; a tree a running
        // briglia-python uses survives every collection while it lives.
        let dir2 = receipt(.python)?.verified
        check("R3: the replaced tree survives the start that replaced it",
              dir1.map { RuntimeFS.kind(RuntimePaths.dir(.python).appendingPathComponent($0).path) == .directory } == true)
        let go = scratch.appendingPathComponent("python-go-\(UUID().uuidString.prefix(6))")
        let live = Process()
        live.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        live.arguments = ["__python-exec", "-u", "-c",
                          "import sys,time,pathlib,os\nwhile not os.path.exists(sys.argv[1]): time.sleep(0.2)\nimport brigliaprobe\nprint('LIVE', brigliaprobe.VERSION, pathlib.Path(sys.prefix,'pyvenv.cfg').exists(), flush=True)",
                          go.path]
        let liveOut = Pipe(); live.standardOutput = liveOut; live.standardError = FileHandle.nullDevice
        try live.run()
        var leased = false
        for _ in 0..<100 where !leased {
            leased = !((try? fm.contentsOfDirectory(atPath: PythonRuntime.leaseDir.path)) ?? []).isEmpty
            if !leased { usleep(100_000) }
        }
        check("R3: a running briglia-python holds a lease (pid + start time)", leased)
        let h3 = wheel("3.0")
        setenv("BRIGLIA_PYTHON_TEST_LOCK", try lock("3.0", h3).path, 1)
        let s3b = await PythonRuntime.converge(trigger: .install)
        check("R3: an explicit install collects nothing (the older tree is still there)",
              dir1.map { RuntimeFS.kind(RuntimePaths.dir(.python).appendingPathComponent($0).path) == .directory } == true)
        let s3c = await PythonRuntime.converge(trigger: .auto)   // a later start: collects
        let d2alive = dir2.map { RuntimeFS.kind(RuntimePaths.dir(.python).appendingPathComponent($0).path) == .directory } ?? false
        let d1gone = dir1.map { RuntimeFS.kind(RuntimePaths.dir(.python).appendingPathComponent($0).path) == .absent } ?? false
        check("R3: install of a new lock while it runs, then a later start → its tree kept, an unused old tree collected",
              { if case .ready = s3b { return true }; return false }() && { if case .ready = s3c { return true }; return false }() && d2alive && d1gone,
              "\(s3b) \(s3c) d2=\(d2alive) d1gone=\(d1gone)")
        try Data().write(to: go)
        for _ in 0..<300 where live.isRunning { usleep(100_000) }   // (waitUntilExit can miss the exit inside async code)
        let liveText = String(decoding: liveOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check("R3: the live process still imports its package and finds its own venv files", liveText.contains("LIVE 2.0 True"), liveText)
        _ = await PythonRuntime.converge(trigger: .auto)
        check("R3: after it exits, the next start collects that tree and its stale lease",
              dir2.map { RuntimeFS.kind(RuntimePaths.dir(.python).appendingPathComponent($0).path) == .absent } == true
              && ((try? fm.contentsOfDirectory(atPath: PythonRuntime.leaseDir.path)) ?? []).isEmpty)
        setenv("BRIGLIA_PYTHON_TEST_LOCK", try lock("2.0", h2).path, 1)
        _ = await PythonRuntime.converge(trigger: .install)
        // A lock whose hash does not match the wheel → pip refuses; previous venv stays.
        setenv("BRIGLIA_PYTHON_TEST_LOCK", try lock("2.0", String(repeating: "a", count: 64)).path, 1)
        let goodDir = receipt(.python)?.verified
        let s4 = await PythonRuntime.converge(trigger: .install)
        check("hash mismatch → pip refuses, the previous venv stays selected", { if case .failed = s4 { return true }; return false }()
              && receipt(.python)?.verified == goodDir && { if case .run = PythonRuntime.execDecision() { return true }; return false }(), "\(s4)")
        // An extra distribution beyond the lock fails the closure check.
        setenv("BRIGLIA_PYTHON_TEST_LOCK", try lock("2.0", h2).path, 1)
        let lockText = try String(contentsOfFile: ProcessInfo.processInfo.environment["BRIGLIA_PYTHON_TEST_LOCK"]!, encoding: .utf8)
        let probeLock = scratch.appendingPathComponent("lock-missing.txt")
        try (lockText + "otherpkg==1.0 \\\n    --hash=sha256:\(String(repeating: "b", count: 64))\n").write(to: probeLock, atomically: true, encoding: .utf8)
        guard case .run(let pyNow) = PythonRuntime.execDecision() else { check("venv still selected", false); return }
        let closure = await PythonRuntime.probe(python: pyNow, lock: probeLock)
        check("installed-set check: a locked distribution that is not installed fails", closure?.contains("missing otherpkg") == true, closure ?? "nil")
        // A locked wheel that declares a dependency the lock lacks → pip check fails the build.
        let depWheel = RuntimeProcess.runBlocking(found.path, ["-c", mk.replacingOccurrences(of: "Version: {ver}\\n\"", with: "Version: {ver}\\nRequires-Dist: briglia-absent-dep\\n\""), wheels.path, "brigliadep", "1.0"],
                                                  env: ["PATH": "/usr/bin:/bin"], cwd: nil, timeout: 60).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let depLock = scratch.appendingPathComponent("lock-dep.txt")
        try "# briglia-python-lock v1\nbrigliadep==1.0 \\\n    --hash=sha256:\(depWheel)\n".write(to: depLock, atomically: true, encoding: .utf8)
        setenv("BRIGLIA_PYTHON_TEST_LOCK", depLock.path, 1)
        setenv("BRIGLIA_PYTHON_TEST_PROBE", "brigliadep", 1)
        let sDep = await PythonRuntime.converge(trigger: .install)
        check("a lock missing part of the closure (unsatisfied Requires-Dist) → pip check fails the build, previous venv stays",
              { if case .failed(let w) = sDep { return w.contains("pip check") }; return false }() && receipt(.python)?.verified == goodDir, "\(sDep)")
        setenv("BRIGLIA_PYTHON_TEST_PROBE", "brigliaprobe", 1)
        setenv("BRIGLIA_PYTHON_TEST_LOCK", try lock("2.0", h2).path, 1)
        // Base < minimum → unavailable with the command.
        setenv("BRIGLIA_PYTHON_MIN_MINOR", "99", 1)
        let s5 = await PythonRuntime.converge(trigger: .install)
        check("no python ≥ the minimum → unavailable with the install hint", { if case .unavailable(let w) = s5 { return w.contains("install Python") }; return false }(), "\(s5)")
        setenv("BRIGLIA_PYTHON_MIN_MINOR", "8", 1)
        // R4: the base interpreter's identity is recorded and enforced.
        let baseDir = scratch.appendingPathComponent("pybase-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let baseLink = baseDir.appendingPathComponent("python3")
        try fm.createSymbolicLink(atPath: baseLink.path, withDestinationPath: found.path)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", baseDir.path, 1)
        resetRuntime()   // a fresh build through the scratch base path
        let r4a = await PythonRuntime.converge(trigger: .install)
        let r4rec = receipt(.python)?.verifiedRecord
        check("R4: the record carries the resolved base interpreter, its full version and a file-tree hash",
              { if case .ready = r4a { return true }; return false }() && r4rec?.extra?["baseResolved"] == URL(fileURLWithPath: found.path).resolvingSymlinksInPath().path
              && r4rec?.extra?["baseVersion"] == found.version && r4rec?.extra?["treeSHA256"]?.count == 64, "\(r4a) \(String(describing: r4rec?.extra))")
        // Same path, other interpreter → refused at use and in status.
        let other = baseDir.appendingPathComponent("other-python")
        try "#!/bin/sh\nexec '\(found.path)' \"$@\"\n".write(to: other, atomically: true, encoding: .utf8)
        chmod(other.path, 0o755)
        try fm.removeItem(at: baseLink)
        try fm.createSymbolicLink(atPath: baseLink.path, withDestinationPath: other.path)
        check("R4: base path retargeted → briglia-python refuses", { if case .refuse(let w) = PythonRuntime.execDecision() { return w.contains("does not match") }; return false }())
        check("R4: …and status is not 'pinned'", RuntimeStatus.python()?.state != .pinned, "\(String(describing: RuntimeStatus.python()))")
        // Same path, same minor, new patch version → startup rebuilds (no fast path).
        // First rebuild through the retargeted path so only the version differs next.
        _ = await PythonRuntime.converge(trigger: .install)
        let r4dirB = receipt(.python)?.verified
        let minor = found.version.split(separator: ".")[1]
        try "#!/bin/sh\ncase \"$*\" in *'import sys, venv, ensurepip'*) echo 3.\(minor).99; exit 0;; esac\nexec '\(found.path)' \"$@\"\n".write(to: other, atomically: true, encoding: .utf8)
        // An atomic write replaces the file: corelibs Foundation (Linux) does
        // not carry the old mode over, so the wrapper must be made executable
        // again or the base would simply vanish from the candidate list.
        chmod(other.path, 0o755)
        check("R4: same path, new version (file rewritten in place) → briglia-python refuses BEFORE any startup",
              { if case .refuse(let w) = PythonRuntime.execDecision() { return w.contains("does not match") }; return false }())
        check("R4: …and status is not 'pinned' before any startup", RuntimeStatus.python()?.state != .pinned, "\(String(describing: RuntimeStatus.python()))")
        let r4b = await PythonRuntime.converge(trigger: .auto)
        check("R4: same path and minor, new patch version → rebuilt at startup into a new directory",
              { if case .ready = r4b { return true }; return false }() && receipt(.python)?.verified != r4dirB && r4dirB != nil
              && receipt(.python)?.verifiedRecord?.extra?["baseVersion"] == "3.\(minor).99", "\(r4b)")
        // Removed base → refused.
        try fm.removeItem(at: baseLink)
        check("R4: base removed → briglia-python refuses", { if case .refuse = PythonRuntime.execDecision() { return true }; return false }())
        check("R4: doctor's tree check names the built files", PythonRuntime.doctorTreeLine()?.ok == true)
        if let v = receipt(.python)?.verified {
            let extraFile = RuntimePaths.dir(.python).appendingPathComponent(v).appendingPathComponent("env/lib/injected.py")
            try "x = 1\n".write(to: extraFile, atomically: true, encoding: .utf8)
            check("R4: an added file in the environment → doctor's tree check fails", PythonRuntime.doctorTreeLine()?.ok == false)
            try fm.removeItem(at: extraFile)
        }
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", base, 1)
        _ = await PythonRuntime.converge(trigger: .install)
        // Damaged pyvenv.cfg → refuse.
        if let v = receipt(.python)?.verified {
            let cfg = RuntimePaths.dir(.python).appendingPathComponent(v).appendingPathComponent("env/pyvenv.cfg")
            try (try String(contentsOf: cfg, encoding: .utf8) + "# changed\n").write(to: cfg, atomically: false, encoding: .utf8)
            check("a changed venv → briglia-python refuses (rebuilt at the next start)", { if case .refuse(let w) = PythonRuntime.execDecision() { return w.contains("does not match") }; return false }())
        }
        for k in ["BRIGLIA_PYTHON_TEST_BASE_DIRS", "BRIGLIA_PYTHON_MIN_MINOR", "BRIGLIA_PYTHON_TEST_FIND_LINKS", "BRIGLIA_PYTHON_TEST_PROBE", "BRIGLIA_PYTHON_TEST_LOCK"] { unsetenv(k) }
    }

    // MARK: PATH contract

    func pathContract() {
        // Wrappers embed the running briglia path shell-quoted (a path with an apostrophe still works).
        let odd = scratch.appendingPathComponent("it's here", isDirectory: true)
        try? fm.createDirectory(at: odd, withIntermediateDirectories: true)
        let fake = odd.appendingPathComponent("briglia")
        try? "#!/bin/sh\necho \"ARGS $*\"\n".write(to: fake, atomically: true, encoding: .utf8)
        chmod(fake.path, 0o755)
        for (label, script) in [("agentmail", AgentMailService.wrapperScript(brigliaPath: fake.path)), ("briglia-python", PythonRuntime.wrapperScript(brigliaPath: fake.path))] {
            let w = odd.appendingPathComponent("w-\(label)")
            try? script.write(to: w, atomically: true, encoding: .utf8)
            chmod(w.path, 0o700)
            let r = RuntimeProcess.runBlocking(w.path, ["x"], env: ["PATH": "/usr/bin:/bin"], cwd: nil, timeout: 10)
            check("\(label) wrapper: a briglia path containing an apostrophe is quoted correctly", r.status == 0 && r.stdout.contains("ARGS __") && r.stdout.contains(" x"), r.stdout + r.stderr)
        }
        let p = BashTools.augmentedPath("/opt/homebrew/bin:\(home)/.local/bin:/usr/bin")
        let parts = p.split(separator: ":").map(String.init)
        check("agent PATH: Briglia's own bin first, ahead of ~/.local/bin", parts.first == RuntimePaths.binDir.path
              && (parts.firstIndex(of: RuntimePaths.binDir.path) ?? 99) < (parts.firstIndex(of: home + "/.local/bin") ?? -1), p)
        check("agent PATH: the Node fallback shims last", parts.last == RuntimePaths.fallbackBinDir.path, p)
        check("the PATH order is re-applied after login-shell initialisation (command text unchanged)",
              BashTools.shellInvocation(for: "echo hi").arguments.last == BashTools.loginPathPrefix + "echo hi"
              && BashTools.loginPathPrefix.contains("$BRIGLIA_PATH_FRONT") && BashTools.loginPathPrefix.contains("$BRIGLIA_PATH_BACK"))
        let mcp = MCPRegistry.baseEnvironment()["PATH"] ?? ""
        check("MCP servers: fallback shims last, so a user Node always wins", mcp.split(separator: ":").last.map(String.init) == RuntimePaths.fallbackBinDir.path, mcp)
    }
}
