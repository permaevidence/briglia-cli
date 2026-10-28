import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Background children for the race tests.
final class MAChild {
    let process: Process
    private let pipe: Pipe
    private let lock = NSLock()
    private var buffer = Data()

    /// The child's stdin (kept open so a test can type into it).
    var input: Pipe?

    init(process: Process, pipe: Pipe, input: Pipe? = nil) {
        self.process = process; self.pipe = pipe; self.input = input
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            self.lock.lock(); self.buffer.append(d); self.lock.unlock()
        }
    }

    var output: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buffer, as: UTF8.self) }
    var running: Bool { process.isRunning }

    /// Wait until `predicate(output)` or the timeout; true when it held.
    @discardableResult
    func waitFor(_ timeout: TimeInterval, _ predicate: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(output) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return predicate(output)
    }

    @discardableResult
    func waitExit(_ timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { return nil }
        Thread.sleep(forTimeInterval: 0.1)
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); buffer.append(pipe.fileHandleForReading.readDataToEndOfFile()); lock.unlock()
        return process.terminationStatus
    }

    func kill(_ sig: Int32 = SIGKILL) {
        if process.isRunning { Darwin_or_Glibc_kill(process.processIdentifier, sig) }
        _ = waitExit(5)
    }

    /// The first JSON line the probe printed.
    var probeInfo: [String: Any]? {
        for line in output.split(separator: "\n") where line.hasPrefix("{") {
            if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { return o }
        }
        return nil
    }
}

func Darwin_or_Glibc_kill(_ pid: pid_t, _ sig: Int32) {
    _ = kill(pid, sig)
}

extension ProfileHarness {
    // MARK: - Helpers

    func startChild(_ args: [String], extraEnv: [String: String] = [:], stdin: String? = nil, keepStdinOpen: Bool = false) -> MAChild? {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        var e = env
        for (k, v) in extraEnv { e[k] = v }
        p.environment = e
        p.currentDirectoryURL = root
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = input
        do { try p.run() } catch { return nil }
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        if keepStdinOpen { return MAChild(process: p, pipe: out, input: input) }
        try? input.fileHandleForWriting.close()
        return MAChild(process: p, pipe: out)
    }

    var defaultData: String { dataBase + "/briglia" }
    var machineDir: String { defaultData + "/machine" }
    var sharedDir: String { dataBase + "/" + AssistantProfile.sharedDirName }
    var regPaths: AssistantRegistry.Paths { AssistantRegistry.Paths(root: URL(fileURLWithPath: sharedDir, isDirectory: true)) }
    var barrierPaths: UpgradeBarrier.Paths { UpgradeBarrier.Paths(root: URL(fileURLWithPath: machineDir + "/upgrade", isDirectory: true)) }

    func registryDoc() -> AssistantRegistry.Document? { (try? AssistantRegistry.read(regPaths)) ?? nil }

    func generation(_ name: String) -> String? { registryDoc()?.record(name)?.generation }

    func extraLeaseDir(_ name: String) -> URL? {
        guard let g = generation(name) else { return nil }
        return URL(fileURLWithPath: sharedDir).appendingPathComponent("members/\(name)/\(g)", isDirectory: true)
    }

    /// `profiles add <name>` (offline, no bot) once per harness.
    @discardableResult
    func ensureExtra(_ name: String, display: String, bot: String? = nil) -> Bool {
        if registryDoc()?.record(name) != nil { return true }
        var args = ["profiles", "add", name, "--name", display, "--home", root.appendingPathComponent("home-\(name)").path]
        if bot != nil { args.append("--bot-token-stdin") }
        let r = run(args, stdin: bot.map { $0 + "\n" })
        if r.status != 0 { print("   (profiles add \(name) failed: \(r.out))") }
        return r.status == 0
    }

    func writeBarrier(state: UpgradeBarrier.State, id: String = "b-test") {
        let record = UpgradeBarrier.Record(id: id, state: state, targetVersion: "9.9.9", targetSequence: 999, openedAt: Date(),
                                           coordinator: .init(lease: "none", pid: 1, processStartTime: "x"),
                                           participants: [], committedBinarySHA256: nil, reason: nil)
        try? UpgradeBarrier.writeBarrier(record, barrierPaths)
    }

    func clearBarrier() { try? FileManager.default.removeItem(atPath: barrierPaths.barrier.path) }

    func mutateRegistry(_ body: (inout AssistantRegistry.Document) -> Void) {
        _ = try? AssistantRegistry.withLock(regPaths) { doc in
            guard var d = doc else { return }
            body(&d)
            doc = d
        }
    }

    // MARK: - Leases and the entry protocol (§4.4)

    func leasesSection() {
        leaseInactiveWithoutSwitch()
        leasePrimitives()
        leaseEntryRoles()
        leaseBarrierAtEntry()
        leaseRemovedAndRegenerated()
        leaseSettingsAdmission()
    }

    /// Never-multi without the switch: no lease, no machine/ directory.
    private func leaseInactiveWithoutSwitch() {
        let data = root.appendingPathComponent("inactive-data"), config = root.appendingPathComponent("inactive-config")
        let r = run(["__member-probe"], extraEnv: ["XDG_DATA_HOME": data.path, "XDG_CONFIG_HOME": config.path],
                    removeEnv: [AssistantProfile.experimentalKey])
        let info = r.out.split(separator: "\n").first.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        check("inactive (no switch, no registry): no member lease", r.status == 0 && info?["uuid"] == nil, r.out)
        check("inactive: no machine/ directory is created",
              !FileManager.default.fileExists(atPath: data.path + "/briglia/machine"))
    }

    private func leasePrimitives() {
        let dir = root.appendingPathComponent("lease-prims", isDirectory: true)
        guard let lease = try? MemberLease.create(in: dir, role: "assistant", sessionKind: "daemon", profile: "default") else {
            check("lease: create", false); return
        }
        check("lease: file and sidecar exist, owner-only",
              mode(lease.lockURL.path) == 0o600 && mode(lease.sidecarURL.path) == 0o600 && mode(dir.path) == 0o700)
        let entries = MemberLeases.list(dir)
        check("lease: a held lease probes live with its sidecar", entries.count == 1 && entries[0].probe == .live
              && entries[0].sidecar?.role == "assistant" && entries[0].sidecar?.pid == getpid())
        check("lease: sweep never removes a held lease", MemberLeases.sweep(dir) == 0 && FileManager.default.fileExists(atPath: lease.lockURL.path))
        // A live lease whose sidecar is unreadable is unknown, never absent.
        try? "garbage".write(to: lease.sidecarURL, atomically: true, encoding: .utf8)
        check("lease: held lease with an unreadable sidecar = unknown", MemberLeases.list(dir).first?.probe == .unknown)
        check("lease: unknown counts as a user", MemberLeases.users(dir, assistantsOnly: true).count == 1)
        try? lease.writeSidecar()
        try? lease.update { $0.coordinator = true }
        check("lease: attribute update keeps the role", MemberLeases.list(dir).first?.sidecar?.coordinator == true
              && MemberLeases.list(dir).first?.sidecar?.role == "assistant")
        lease.release()
        check("lease: release removes both files", !FileManager.default.fileExists(atPath: lease.lockURL.path)
              && !FileManager.default.fileExists(atPath: lease.sidecarURL.path))
        // A leftover (crashed holder) is dead and swept.
        FileManager.default.createFile(atPath: dir.appendingPathComponent("dead.lock").path, contents: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("dead.json").path, contents: Data("{}".utf8))
        check("lease: a free leftover probes dead", MemberLeases.list(dir).first?.probe == .dead)
        check("lease: sweep removes a free leftover and its sidecar", MemberLeases.sweep(dir) == 1
              && (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true)
        // Process identity used by `profiles stop`.
        check("process identity: own start time and executable readable",
              ProcessIdentity.startTime(getpid()) != nil && ProcessIdentity.executable(getpid()) != nil)
    }

    private func leaseEntryRoles() {
        guard ensureExtra("work", display: "Work") else { check("entry: extra created", false); return }
        guard let session = startChild(["__member-probe", "--hold", "3"]),
              session.waitFor(10, { $0.contains("\"uuid\"") }) else { check("entry: default session probe", false); return }
        let sInfo = session.probeInfo
        check("entry: a default session holds a lease under machine/members",
              sInfo?["role"] as? String == "session" && canon(sInfo?["directory"] as? String) == canon(machineDir + "/members"))
        guard let asst = startChild(["--profile", "work", "__member-probe", "--assistant", "--hold", "3"]),
              asst.waitFor(10, { $0.contains("\"uuid\"") }) else { check("entry: extra assistant probe", false); return }
        let aInfo = asst.probeInfo
        check("entry: an extra assistant's lease lives in briglia-shared/members/<n>/<generation>",
              aInfo?["role"] as? String == "assistant" && aInfo?["generation"] as? String == generation("work")
              && canon(aInfo?["directory"] as? String) == canon(extraLeaseDir("work")?.path))
        check("entry: the extra's lease is outside its removable roots",
              !(aInfo?["directory"] as? String ?? "").hasPrefix(dataBase + "/briglia-profiles"))
        _ = session.waitExit(10); _ = asst.waitExit(10)
        check("entry: leases are removed at exit",
              MemberLeases.list(URL(fileURLWithPath: machineDir + "/members")).isEmpty
              && (extraLeaseDir("work").map { MemberLeases.list($0).isEmpty } ?? false))
        // Exempt commands take no lease.
        check("entry: exempt commands (version, __release-identity, selftests) take no lease",
              MemberEntry.classify(["--version"]) == nil && MemberEntry.classify(["__release-identity"]) == nil
              && MemberEntry.classify(["__setsid-exec", "x"]) == nil && MemberEntry.classify(["doctor", "--read-only"]) == nil
              && MemberEntry.classify(["__chat-wire-selftest"]) == nil && MemberEntry.classify(["daemon", "--all"]) == nil)
        check("entry: daemon and chat are assistants, the rest sessions, upgrade --recover recovery",
              MemberEntry.classify(["daemon"]) == .assistant(kind: "daemon") && MemberEntry.classify([]) == .assistant(kind: "chat")
              && MemberEntry.classify(["menu"]) == .session(kind: "menu") && MemberEntry.classify(["upgrade", "--recover"]) == .recovery
              && MemberEntry.classify(["trigger", "w1"]) == .session(kind: "trigger"))
        let unit = AgentServiceSupport.templateUnitText(adaPath: "/opt/b/briglia", home: "/home/u")
        check("linux: the extras' template passes --profile %i in argv (never only the environment)",
              unit.contains("ExecStart=\"/opt/b/briglia\" --profile %i daemon") && unit.contains("BRIGLIA_EXPERIMENTAL_PROFILES=1")
              && AgentServiceSupport.extraUnitName("work") == "briglia@work.service" && AgentServiceSupport.userUnitName == "briglia.service")
        let promo = run(["__member-probe", "--promote"])
        let uuid = (promo.out.split(separator: "\n").first { $0.hasPrefix("{") }).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }?["uuid"] as? String
        check("promotion: menu → terminal chat changes the role on the SAME lease (no admission gap)",
              promo.out.contains("PROMOTED:ok:assistant:chat:") && uuid != nil && promo.out.contains(":\(uuid ?? "-")"), promo.out)
        let rid = run(["__release-identity"])
        check("__release-identity prints version and compiled sequence",
              rid.status == 0 && rid.out.contains("\"sequence\":\(adaCLIReleaseSequence)"), rid.out)
    }

    private func leaseBarrierAtEntry() {
        // A live coordinator holds upgrade.lock (otherwise a starter would
        // rightly take over recovery of an orphaned barrier, R7).
        try? FileManager.default.createDirectory(at: barrierPaths.root, withIntermediateDirectories: true)
        let coordinatorLock: ProfileFileLock? = { if case .acquired(let l) = ProfileFileLock.take(barrierPaths.lock) { return l }; return nil }()
        defer { coordinatorLock?.release() }
        writeBarrier(state: .open)
        let s = run(["__member-probe"])
        check("barrier: a session that finds an open barrier exits 75 with the updating message",
              s.status == 75 && s.out.contains("Briglia is updating") && !s.out.contains("PROBE_DONE"), "\(s.status) \(s.out)")
        check("barrier: the refused session left no lease", MemberLeases.list(URL(fileURLWithPath: machineDir + "/members")).isEmpty)
        guard let a = startChild(["--profile", "work", "__member-probe", "--assistant"]) else { check("barrier: assistant start", false); return }
        let parked = a.waitFor(6) { _ in
            guard let dir = try? FileManager.default.contentsOfDirectory(atPath: self.barrierPaths.ackDir.path) else { return false }
            return dir.contains { n in UpgradeBarrier.readAck(String(n.dropLast(5)), self.barrierPaths)?.state == .parked }
        }
        check("barrier: a starting assistant parks before touching state and acks parked", parked && !a.output.contains("PROBE_DONE"), a.output)
        writeBarrier(state: .cancelled)
        check("barrier: on cancelled the parked starter continues", a.waitExit(10) == 0 && a.output.contains("PROBE_DONE"), a.output)
        writeBarrier(state: .stuck)
        let st = run(["__member-probe"])
        check("barrier: a stuck barrier refuses sessions", st.status == 75, st.out)
        check("barrier: a malformed barrier fails closed (sessions refused)", { () -> Bool in
            try? "{".write(to: barrierPaths.barrier, atomically: true, encoding: .utf8)
            return run(["__member-probe"]).status == 75
        }())
        let rec = run(["upgrade", "--recover", "--help"])
        check("barrier: help still works during a barrier (exempt)", rec.status == 0, rec.out)
        clearBarrier()
        UpgradeBarrier.clearAcks(barrierPaths)
    }

    private func leaseRemovedAndRegenerated() {
        // A starter suspended between publishing its lease and looking: the
        // profile is regenerated meanwhile → it must exit (§4.4 step 3).
        guard let a = startChild(["--profile", "work", "__member-probe"], extraEnv: ["BRIGLIA_TEST_ENTRY_PAUSE_MS": "1500"]),
              a.waitFor(5, { _ in self.extraLeaseDir("work").map { !MemberLeases.users($0).isEmpty } ?? false }) else {
            check("regenerate: starter published its lease", false); return
        }
        let oldGen = generation("work")
        mutateRegistry { d in if let i = d.index("work") { d.records[i].generation = "regenerated-" + UUID().uuidString.lowercased() } }
        let status = a.waitExit(10)
        check("regenerate: a starter suspended across a regeneration exits (removed)",
              status == 2 && a.output.contains("removed") && !a.output.contains("PROBE_DONE"), "\(status ?? -9) \(a.output)")
        mutateRegistry { d in if let i = d.index("work"), let oldGen { d.records[i].generation = oldGen } }
        mutateRegistry { d in if let i = d.index("work") { d.records[i].state = "removing" } }
        let r = run(["--profile", "work", "__member-probe"])
        check("removing: a start during removal is refused", r.status == 2 && r.out.contains("being removed"), r.out)
        mutateRegistry { d in if let i = d.index("work") { d.records[i].state = "active" } }
    }

    private func leaseSettingsAdmission() {
        // An offline setter holds a live transaction for work's bot …
        guard let setter = startChild(["--profile", "work", "__member-probe", "--hold-tx", "bot:4242:TOKEN", "--hold", "3"]),
              setter.waitFor(8, { $0.contains("TX_HELD") || $0.contains("TX_REFUSED") }) else {
            check("admission: offline setter started", false); return
        }
        check("admission: an offline setter reserves while no assistant runs", setter.output.contains("TX_HELD"), setter.output)
        // … so a starting assistant waits outside every lock until it ends.
        guard let starter = startChild(["--profile", "work", "__member-probe", "--assistant"]) else { check("admission: starter", false); return }
        Thread.sleep(forTimeInterval: 1.2)
        check("admission: a starting assistant waits while the setter's transaction is live",
              starter.running && !starter.output.contains("PROBE_DONE") && starter.output.contains("settings change"), starter.output)
        _ = setter.waitExit(10)
        check("admission: the starter proceeds once the transaction finished", starter.waitExit(10) == 0, starter.output)
        // Reverse order: with the assistant running, the offline setter refuses.
        guard let running = startChild(["--profile", "work", "__member-probe", "--assistant", "--hold", "4"]),
              running.waitFor(8, { $0.contains("\"uuid\"") }) else { check("admission: running assistant", false); return }
        let refused = run(["--profile", "work", "__member-probe", "--hold-tx", "bot:4343:TOKEN"])
        check("admission: an offline setter refuses while the assistant runs",
              refused.out.contains("TX_REFUSED") && refused.out.contains("This assistant is running"), refused.out)
        check("admission: the refusal left no reservation", registryDoc()?.record("work")?.bot.pending == nil
              && registryDoc()?.record("work")?.activeTx.isEmpty == true)
        _ = running.waitExit(10)
        // Never-multi default: the identity lock is the whole admission.
        let data = root.appendingPathComponent("nm-data"), config = root.appendingPathComponent("nm-config")
        let nm = ["XDG_DATA_HOME": data.path, "XDG_CONFIG_HOME": config.path]
        let lockDir = data.appendingPathComponent("briglia/machine", isDirectory: true)
        try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        guard case .acquired(let held) = ProfileFileLock.take(lockDir.appendingPathComponent("identity-tx.lock")) else {
            check("never-multi admission: identity lock", false); return
        }
        guard let nmStarter = startChild(["__member-probe", "--assistant"], extraEnv: nm) else { return }
        Thread.sleep(forTimeInterval: 1.2)
        check("never-multi admission: a default start waits while identity-tx.lock is held", nmStarter.running, nmStarter.output)
        held.release()
        check("never-multi admission: then proceeds", nmStarter.waitExit(10) == 0, nmStarter.output)
    }
}
