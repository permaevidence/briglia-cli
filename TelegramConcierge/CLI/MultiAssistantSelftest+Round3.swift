import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Codex stage-2 round 2 findings F1–F4, each reproduced first (these checks
/// fail on `32316ac`), then fixed. F3 runs inside the upgrade section (it
/// needs the scratch install), see `upgradeCommittedPairMismatch`.
extension ProfileHarness {
    func stage2Round3Section() {
        for name in ["crashy", "solo", "sup", "gone", "sb"] where registryDoc()?.record(name) != nil {
            _ = run(["profiles", "remove", name, "--yes", "--no-export"])
        }
        f1AnotherStartersLeaseDoesNotCertifyTheOwner()
        g1UnprobeableInstanceLockFailsClosed()
        f2TerminalPruneRefusedWhileParked()
        f4ProvisionalAddIsNeverAdmitted()
    }

    /// Own XDG roots (like `freshRoots` of round 2), with the switch value given.
    private func roots3(_ tag: String) -> [String: String] {
        let data = root.appendingPathComponent("\(tag)-data"), config = root.appendingPathComponent("\(tag)-config")
        let secretsDir = config.appendingPathComponent("briglia", isDirectory: true)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        let secrets: [String: String] = ["llm_provider": "openai_compatible", "openai_compatible_base_url": "http://127.0.0.1:9/v1",
                                         "openai_compatible_model": "m", "openai_compatible_api_key": "k",
                                         "assistant_name": "Bree", "user_name": "Test"]
        try? JSONSerialization.data(withJSONObject: secrets).write(to: secretsDir.appendingPathComponent("secrets.json"))
        chmod(secretsDir.appendingPathComponent("secrets.json").path, 0o600)
        return ["XDG_DATA_HOME": data.path, "XDG_CONFIG_HOME": config.path, "BRIGLIA_TEST_NO_BROWSER_BOOTSTRAP": "1"]
    }

    /// F1: daemon A runs unleased (started inactive); daemon B (switch on)
    /// publishes its assistant lease and is still before its instance lock.
    /// B's lease must not certify A: first add and the upgrader refuse.
    private func f1AnotherStartersLeaseDoesNotCertifyTheOwner() {
        let e = roots3("f1")
        let data = e["XDG_DATA_HOME"]!
        let dataRoot = URL(fileURLWithPath: data + "/briglia", isDirectory: true)
        let members = URL(fileURLWithPath: data + "/briglia/machine/members", isDirectory: true)
        let reg = AssistantRegistry.Paths(root: URL(fileURLWithPath: data + "/" + AssistantProfile.sharedDirName, isDirectory: true))
        guard let a = startChild(["daemon"], extraEnv: e.merging([AssistantProfile.experimentalKey: ""]) { $1 }),
              a.waitFor(30, { $0.contains("daemon running") }) else { check("F1: inactive daemon A starts", false); return }
        defer { a.kill(SIGTERM) }
        guard let b = startChild(["daemon"], extraEnv: e.merging([AssistantProfile.experimentalKey: "1",
                                                                  "BRIGLIA_TEST_ENTRY_PAUSE_MS": "20000"]) { $1 }) else { return }
        defer { b.kill(SIGTERM) }
        let bLease = b.waitFor(15) { _ in MemberLeases.users(members, assistantsOnly: true).contains { $0.sidecar?.pid == b.process.processIdentifier } }
        check("F1: setup — B's assistant lease is live while A holds the instance lock",
              bLease && UnleasedInstances.instanceHeld(dataRoot) && UnleasedInstances.holderPid(dataRoot) == a.process.processIdentifier)
        let found = UnleasedInstances.find(registryPaths: reg, defaultData: dataRoot, defaultLeases: members)
        check("F1: the instance owner is still reported unleased (another process's lease never certifies it)",
              found == [AssistantProfile.defaultName], "\(found)")
        let add = run(["profiles", "add", "work", "--name", "Work", "--home", root.appendingPathComponent("f1-home").path], extraEnv: e)
        check("F1: first `profiles add` refuses (duplicate start) and creates no registry",
              add.status != 0 && add.out.contains("without coordination") && !FileManager.default.fileExists(atPath: reg.registry.path), add.out)
        _ = try? AssistantRegistry.withLock(reg) { doc in doc = AssistantRegistry.Document(version: 1, records: [AssistantRegistry.newRecord(name: "default", displayName: "Bree")]) }
        let up = run(["upgrade", "--yes"], extraEnv: e.merging(["BRIGLIA_TEST_UPGRADE_STAGED": root.appendingPathComponent("nonexistent").path]) { $1 })
        check("F1: the upgrader refuses too (duplicate start)", up.status != 0 && up.out.contains("without coordination"), up.out)
        check("F1: A was never touched", a.running)
        b.kill(SIGTERM); a.kill(SIGTERM)
        // Control: once the owner itself holds the lease, it is coordinated.
        try? FileManager.default.removeItem(at: reg.registry)
        guard let c = startChild(["daemon"], extraEnv: e.merging([AssistantProfile.experimentalKey: "1"]) { $1 }),
              c.waitFor(30, { $0.contains("daemon running") }) else { check("F1: control daemon", false); return }
        let none = UnleasedInstances.find(registryPaths: reg, defaultData: dataRoot, defaultLeases: members)
        check("F1: control — an owner holding its own assistant lease is coordinated", none.isEmpty, "\(none)")
        c.kill(SIGTERM)
    }

    /// G1 (Codex round 3): an instance lock that cannot be probed (not
    /// writable, or not readable) never counts as "nobody runs".
    private func g1UnprobeableInstanceLockFailsClosed() {
        let e = roots3("g1")
        let data = e["XDG_DATA_HOME"]!
        let dataRoot = URL(fileURLWithPath: data + "/briglia", isDirectory: true)
        let lockPath = data + "/briglia/instance.lock"
        let members = URL(fileURLWithPath: data + "/briglia/machine/members", isDirectory: true)
        let reg = AssistantRegistry.Paths(root: URL(fileURLWithPath: data + "/" + AssistantProfile.sharedDirName, isDirectory: true))
        guard let a = startChild(["daemon"], extraEnv: e.merging([AssistantProfile.experimentalKey: ""]) { $1 }),
              a.waitFor(30, { $0.contains("daemon running") }) else { check("G1: inactive daemon A starts", false); return }
        defer { chmod(lockPath, 0o600); a.kill(SIGTERM) }
        for (mode, label) in [(mode_t(0o400), "readable but not writable"), (mode_t(0o000), "unreadable")] {
            chmod(lockPath, mode)
            let add = run(["profiles", "add", "work", "--name", "Work", "--home", root.appendingPathComponent("g1-home").path], extraEnv: e)
            check("G1: an unleased owner behind a \(label) instance.lock still refuses first add (no registry)",
                  add.status != 0 && add.out.contains("without coordination") && !FileManager.default.fileExists(atPath: reg.registry.path), add.out)
            _ = try? AssistantRegistry.withLock(reg) { doc in doc = AssistantRegistry.Document(version: 1, records: [AssistantRegistry.newRecord(name: "default", displayName: "Bree")]) }
            let up = run(["upgrade", "--yes"], extraEnv: e.merging(["BRIGLIA_TEST_UPGRADE_STAGED": root.appendingPathComponent("nonexistent").path]) { $1 })
            check("G1: … and the upgrader (\(label))", up.status != 0 && up.out.contains("without coordination"), up.out)
            try? FileManager.default.removeItem(at: reg.registry)
        }
        chmod(lockPath, 0o600)
        a.kill(SIGTERM)
        // Control: a leased owner behind a read-only lock is still recognised.
        guard let c = startChild(["daemon"], extraEnv: e.merging([AssistantProfile.experimentalKey: "1"]) { $1 }),
              c.waitFor(30, { $0.contains("daemon running") }) else { check("G1: control daemon", false); return }
        chmod(lockPath, 0o400)
        let none = UnleasedInstances.find(registryPaths: reg, defaultData: dataRoot, defaultLeases: members)
        check("G1: control — a leased owner behind a read-only instance.lock is coordinated", none.isEmpty, "\(none)")
        chmod(lockPath, 0o600)
        c.kill(SIGTERM)
    }

    /// F2: a chat parked for an update refuses `/prune` typed in the terminal
    /// (real stdin dispatch), before any work.
    private func f2TerminalPruneRefusedWhileParked() {
        let e = roots3("f2")
        let data = e["XDG_DATA_HOME"]!
        let members = URL(fileURLWithPath: data + "/briglia/machine/members", isDirectory: true)
        let paths = UpgradeBarrier.Paths(root: URL(fileURLWithPath: data + "/briglia/machine/upgrade", isDirectory: true))
        guard let chat = startChild(["chat"], extraEnv: e.merging([AssistantProfile.experimentalKey: "1"]) { $1 }, keepStdinOpen: true),
              let input = chat.input else { check("F2: chat starts", false); return }
        let p = chat.process
        defer { try? input.fileHandleForWriting.close(); chat.kill(SIGTERM) }
        func send(_ line: String) { input.fileHandleForWriting.write(Data((line + "\n").utf8)) }
        guard chat.waitFor(30, { _ in MemberLeases.users(members, assistantsOnly: true).contains { $0.sidecar?.pid == p.processIdentifier } }),
              let lease = MemberLeases.users(members, assistantsOnly: true).first(where: { $0.sidecar?.pid == p.processIdentifier }) else {
            check("F2: chat runs with an assistant lease", false, String(chat.output.suffix(800))); return
        }
        Thread.sleep(forTimeInterval: 2)
        // Control first: not parked → /prune runs.
        send("/prune")
        let ran = chat.waitFor(20) { $0.contains("Nothing to compact") || $0.contains("Manual prune") }
        check("F2: control — /prune runs in the terminal when not parked", ran, String(chat.output.suffix(600)))
        let mark = chat.output.count
        // Park: hold upgrade.lock (a live coordinator), publish an open barrier.
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        guard case .acquired(let held) = ProfileFileLock.take(paths.lock) else { check("F2: upgrade.lock", false); return }
        defer { held.release() }
        let record = UpgradeBarrier.Record(id: "f2-park", state: .open, targetVersion: "9.9.9", targetSequence: 999, openedAt: Date(),
                                           coordinator: .init(lease: "f2", pid: getpid(), processStartTime: ProcessIdentity.selfStartTime),
                                           participants: [], committedBinarySHA256: nil, reason: nil)
        try? UpgradeBarrier.writeBarrier(record, paths)
        let parked = chat.waitFor(20) { _ in UpgradeBarrier.readAck(lease.uuid, paths)?.state == .parked }
        check("F2: setup — the chat acknowledged `parked`", parked, String(chat.output.suffix(600)))
        send("/prune")
        let refused = chat.waitFor(10) { String($0.dropFirst(mark)).contains(ConversationManager.updatingRefusal) }
        Thread.sleep(forTimeInterval: 1.5)
        let after = String(chat.output.dropFirst(mark))
        check("F2: terminal /prune is refused while parked and starts no work",
              refused && !after.contains("Manual prune") && !after.contains("Nothing to compact"), after)
        try? FileManager.default.removeItem(at: paths.barrier)
    }

    /// F4: the first add publishes its record provisional (`adding`), which
    /// the entry protocol never admits; the rollback deletes only that.
    private func f4ProvisionalAddIsNeverAdmitted() {
        let e = roots3("f4")
        let data = e["XDG_DATA_HOME"]!
        let reg = AssistantRegistry.Paths(root: URL(fileURLWithPath: data + "/" + AssistantProfile.sharedDirName, isDirectory: true))
        try? FileManager.default.createDirectory(at: reg.root, withIntermediateDirectories: true)
        guard case .acquired(let regLock) = ProfileFileLock.take(reg.lock) else { check("F4: registry.lock", false); return }
        var regHeld: ProfileFileLock? = regLock
        defer { regHeld?.release() }
        guard let add = startChild(["profiles", "add", "work", "--name", "Work", "--home", root.appendingPathComponent("f4-home").path],
                                   extraEnv: e) else { return }
        defer { add.kill() }
        Thread.sleep(forTimeInterval: 1.5)    // past its first unleased check, blocked on registry.lock
        guard let d = startChild(["daemon"], extraEnv: e.merging([AssistantProfile.experimentalKey: ""]) { $1 }),
              d.waitFor(30, { $0.contains("daemon running") }) else { check("F4: inactive daemon starts", false); return }
        defer { d.kill(SIGTERM) }
        regHeld?.release(); regHeld = nil
        let published = add.waitFor(10) { _ in ((try? AssistantRegistry.read(reg)) ?? nil)?.record("work") != nil }
        let rec = ((try? AssistantRegistry.read(reg)) ?? nil)?.record("work")
        check("F4: the new record is published provisional (`adding`, with its operation)",
              published && rec?.state == "adding" && rec?.addingOp != nil, "\(String(describing: rec))")
        let probe = run(["--profile", "work", "__member-probe", "--assistant", "--hold", "15"], extraEnv: e)
        check("F4: an assistant of the provisional profile is refused (never admitted)",
              probe.status != 0 && !probe.out.contains("PROBE_DONE") && probe.out.contains("being set up"), probe.out)
        let status = add.waitExit(30)
        let workData = data + "/briglia-profiles/work"
        check("F4: the add rolls back its own provisional record and roots, refusing the unleased daemon",
              status == 1 && add.output.contains("without coordination") && !FileManager.default.fileExists(atPath: workData)
              && ((try? AssistantRegistry.read(reg)) ?? nil)?.record("work") == nil, "\(String(describing: status)) \(add.output)")
        check("F4: the daemon was never touched", d.running)
        d.kill(SIGTERM)
        // A successful add activates the record (control).
        let ok = run(["profiles", "add", "work", "--name", "Work", "--home", root.appendingPathComponent("f4-home").path], extraEnv: e)
        check("F4: control — with nothing unleased the add activates its record",
              ok.status == 0 && ((try? AssistantRegistry.read(reg)) ?? nil)?.record("work")?.state == "active"
              && ((try? AssistantRegistry.read(reg)) ?? nil)?.record("work")?.addingOp == nil, ok.out)
        // An `adding` record whose `profiles add` died: inert for the upgrader,
        // removable; a live one is refused by remove.
        _ = try? AssistantRegistry.withLock(reg) { doc in
            guard var dd = doc, let i = dd.index("work") else { return }
            dd.records[i].state = "adding"; dd.records[i].addingOp = "dead-op"; doc = dd
        }
        let up = run(["upgrade", "--yes"], extraEnv: e.merging(["BRIGLIA_TEST_UPGRADE_STAGED": root.appendingPathComponent("nonexistent").path]) { $1 })
        check("F4: a dead provisional record does not block the upgrader", !up.out.contains("being set up"), up.out)
        try? FileManager.default.createDirectory(at: reg.txDir, withIntermediateDirectories: true)
        if case .acquired(let liveOp) = ProfileFileLock.take(reg.txLease("live-op")) {
            _ = try? AssistantRegistry.withLock(reg) { doc in
                guard var dd = doc, let i = dd.index("work") else { return }
                dd.records[i].addingOp = "live-op"; doc = dd
            }
            let rm = run(["profiles", "remove", "work", "--yes", "--no-export"], extraEnv: e)
            check("F4: remove refuses a provisional record whose add is still running",
                  rm.status != 0 && rm.out.contains("still being added")
                  && ((try? AssistantRegistry.read(reg)) ?? nil)?.record("work")?.state == "adding", rm.out)
            liveOp.release()
        }
        let rm2 = run(["profiles", "remove", "work", "--yes", "--no-export"], extraEnv: e)
        check("F4: a provisional record whose add died can be removed",
              rm2.status == 0 && ((try? AssistantRegistry.read(reg)) ?? nil)?.record("work") == nil, rm2.out)
        f4RollbackDeletesOnlyItsOwnProvisionalRecord()
    }

    /// The rollback itself (scratch registry and roots only): an active record,
    /// or a provisional one of another operation, is never deleted.
    private func f4RollbackDeletesOnlyItsOwnProvisionalRecord() {
        let reg = AssistantRegistry.Paths(root: root.appendingPathComponent("f4u-reg", isDirectory: true))
        let cfg = root.appendingPathComponent("f4u-config", isDirectory: true), dat = root.appendingPathComponent("f4u-data", isDirectory: true)
        func setUp(state: String, op: String) -> String {
            try? FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: dat, withIntermediateDirectories: true)
            var rec = AssistantRegistry.newRecord(name: "work", displayName: "Work")
            rec.state = state; rec.addingOp = state == "adding" ? op : nil
            _ = try? AssistantRegistry.withLock(reg) { doc in
                doc = AssistantRegistry.Document(version: 1, records: [AssistantRegistry.newRecord(name: "default", displayName: "Bree"), rec])
            }
            return rec.generation
        }
        func kept() -> Bool {
            ((try? AssistantRegistry.read(reg)) ?? nil)?.record("work") != nil
                && FileManager.default.fileExists(atPath: cfg.path) && FileManager.default.fileExists(atPath: dat.path)
        }
        var g = setUp(state: "active", op: "op-a")
        ProfileProvisioning.rollbackAdd(name: "work", op: "op-a", generation: g, registryPaths: reg, removeRegistry: true, configRoot: cfg, dataRoot: dat)
        check("F4: rollback never deletes an active record or its roots", kept())
        g = setUp(state: "adding", op: "op-other")
        ProfileProvisioning.rollbackAdd(name: "work", op: "op-a", generation: g, registryPaths: reg, removeRegistry: true, configRoot: cfg, dataRoot: dat)
        check("F4: rollback never deletes another operation's provisional record", kept())
        g = setUp(state: "adding", op: "op-a")
        ProfileProvisioning.rollbackAdd(name: "work", op: "op-a", generation: "other-generation", registryPaths: reg, removeRegistry: true, configRoot: cfg, dataRoot: dat)
        check("F4: rollback never deletes a record of another generation", kept())
        ProfileProvisioning.rollbackAdd(name: "work", op: "op-a", generation: g, registryPaths: reg, removeRegistry: true, configRoot: cfg, dataRoot: dat)
        check("F4: rollback deletes its own provisional record and roots",
              !kept() && !FileManager.default.fileExists(atPath: cfg.path) && !FileManager.default.fileExists(atPath: reg.registry.path))
    }

    /// F3 (called from the upgrade section with its scratch install): a
    /// committed barrier whose installed pair no longer matches is never
    /// closed; it becomes `stuck` with journal and backups kept, through
    /// startup, the shared closure routine, and `upgrade --recover`.
    func upgradeCommittedPairMismatch(_ fx: UpgradeFixture) {
        func killAtCommitThenTamper(_ seq: Int) -> String? {
            setStagedSequence(fx.staged, seq)
            let before = installedMarker(fx)
            let k = runFrom(fx, ["upgrade", "--yes"], extra: ["BRIGLIA_UPGRADE_KILL": "barrier-committed"])
            guard k.status == 91, UpgradeBarrier.current(barrierPaths)?.state == .committed else {
                check("F3: coordinator died at barrier-committed (seq \(seq))", false, k.out); return nil
            }
            try? "F3-TAMPERED".write(to: fx.bundle.appendingPathComponent("staged-marker"), atomically: true, encoding: .utf8)
            return before
        }
        func assetsKept() -> Bool {
            guard case .value(let j) = UpgradeBarrier.journal(barrierPaths) else { return false }
            return FileManager.default.fileExists(atPath: j.backupBinary)
        }
        // (a) Startup with upgrade.lock free.
        if let before = killAtCommitThenTamper(190), let starter = startChild(["__member-probe", "--assistant"]) {
            let admitted = starter.waitFor(4) { $0.contains("PROBE_DONE") }
            starter.kill()
            check("F3: startup never closes a committed barrier whose pair changed: stays parked, barrier `stuck`, journal and backups kept",
                  !admitted && UpgradeBarrier.current(barrierPaths)?.state == .stuck && assetsKept(),
                  "\(String(describing: UpgradeBarrier.current(barrierPaths))) \(starter.output)")
            let rec = run(["upgrade", "--recover"])
            check("F3: then --recover re-verifies and restores the previous pair (cancelled; installed.json no longer names the removed pair)",
                  rec.status == 0 && UpgradeBarrier.current(barrierPaths)?.state == .cancelled && installedMarker(fx) == before
                  && !FileManager.default.fileExists(atPath: barrierPaths.installed.path), rec.out)
        }
        // (b) The shared closure routine (assistants' monitor, coordinator, startup).
        if killAtCommitThenTamper(191) != nil {
            let r = UpgradeCoordinator.closeAttempt(.init(paths: barrierPaths, registryPaths: regPaths), holdingLock: false)
            check("F3: the closure routine validates the pair first (pairMismatch → stuck, journal and backups kept)",
                  r == .pairMismatch && UpgradeBarrier.current(barrierPaths)?.state == .stuck && assetsKept(), "\(r)")
            _ = run(["upgrade", "--recover"])
        }
        // (c) `upgrade --recover` straight on the committed barrier.
        if let before = killAtCommitThenTamper(192) {
            let rec = run(["upgrade", "--recover"])
            check("F3: --recover on a committed barrier whose pair changed restores the previous pair instead of closing",
                  rec.status == 0 && rec.out.contains(UpgradeCoordinator.pairMismatchReason)
                  && UpgradeBarrier.current(barrierPaths)?.state == .cancelled && installedMarker(fx) == before, rec.out)
        }
        check("F3: afterwards Briglia runs normally", runFrom(fx, ["__member-probe"]).status == 0)
    }

    /// Purge the throwaway preference domain of every extra profile the
    /// stage-2 sections create (the isolation harness purges only its own
    /// names; a smoke run caught `up` left behind), in the harness roots and
    /// in the round-2/3 `<tag>-data` roots.
    func purgeProfileDomains() {
        var names: Set<String> = ["up", "work", "rm4", "sc5", "own6", "sa", "sb", "sup", "crashy", "solo", "gone"]
        for r in registryDoc()?.records ?? [] where r.name != AssistantProfile.defaultName { names.insert(r.name) }
        var envs = [env]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasSuffix("-data") {
            let tag = String(name.dropLast(5))
            var e = env
            e["XDG_DATA_HOME"] = root.appendingPathComponent("\(tag)-data").path
            e["XDG_CONFIG_HOME"] = root.appendingPathComponent("\(tag)-config").path
            envs.append(e)
        }
        for e in envs {
            for name in names {
                TestPrefsDomains.purge(Self.suitePrefix + "briglia.profile.\(name).\(AssistantProfile.installationHash(name, environment: e))")
            }
        }
    }

    /// Stop every process still holding an assistant or session lease under
    /// this harness's roots (a break run can leave daemons behind, e.g. M17).
    func reapLeasedProcesses() {
        var dirs = [defaultMembers]
        let membersRoot = URL(fileURLWithPath: sharedDir + "/members", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: membersRoot.path)) ?? [] {
            let profileDir = membersRoot.appendingPathComponent(name, isDirectory: true)
            for g in (try? FileManager.default.contentsOfDirectory(atPath: profileDir.path)) ?? [] {
                dirs.append(profileDir.appendingPathComponent(g, isDirectory: true))
            }
        }
        // Round-2/3 scenarios use their own `<tag>-data` roots.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasSuffix("-data") {
            dirs.append(root.appendingPathComponent(name + "/briglia/machine/members", isDirectory: true))
        }
        let me = getpid()
        for dir in dirs {
            for e in MemberLeases.list(dir) where e.probe != .dead {
                guard let s = e.sidecar, s.pid != me, s.pid > 1, ProcessIdentity.startTime(s.pid) == s.processStartTime else { continue }
                _ = kill(s.pid, SIGTERM)
                var waited = 0.0
                while kill(s.pid, 0) == 0, waited < 5 { Thread.sleep(forTimeInterval: 0.1); waited += 0.1 }
                if kill(s.pid, 0) == 0 { _ = kill(s.pid, SIGKILL) }
            }
        }
    }
}
