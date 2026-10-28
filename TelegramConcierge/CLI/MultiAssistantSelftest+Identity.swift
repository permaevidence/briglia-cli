import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Identity transactions (§5.6), profile removal (§5.7) and stop (§4.3).
extension ProfileHarness {
    func identitySection() {
        identityReservationsInProcess()
        identitySetupAPIRefusesWhileRunning()
        identityDefaultNeverMulti()
    }

    /// Pure registry behaviour against scratch paths: the own pending
    /// reservation admits discovery; the old bot stays `releasing` through
    /// cutover; abort/finish release exactly their own entries.
    private func identityReservationsInProcess() {
        let paths = Reg.Paths(root: root.appendingPathComponent("id-reg", isDirectory: true))
        _ = try? Reg.withLock(paths) { doc in
            var d = Reg.Document(version: 1, records: [Reg.newRecord(name: "default", displayName: "Bree"),
                                                       Reg.newRecord(name: "work", displayName: "Work")])
            d.records[1].bot.current = Reg.digest(.bot, "100:OLD")
            doc = d
        }
        let leaseDirs = root.appendingPathComponent("id-leases", isDirectory: true)
        func ticket(_ profile: String, _ value: String, _ mode: IdentityChange.Mode = .assistant) throws -> IdentityChange.Ticket {
            try IdentityChange.begin(kind: .bot, rawValue: value, mode: mode, profile: profile, paths: paths,
                                     identityLockURL: root.appendingPathComponent("id-identity.lock"), ownLease: nil,
                                     leaseDirectory: { leaseDirs.appendingPathComponent($0.name) })
        }
        guard let t = try? ticket("work", "200:NEW") else { check("identity: begin reserves", false); return }
        check("identity: begin publishes pending + activeTx before any network use",
              (try? Reg.read(paths))??.record("work")?.bot.pending?.value == Reg.digest(.bot, "200:NEW")
              && (try? Reg.read(paths))??.record("work")?.activeTx["bot"]?.phase == "reserving")
        check("identity: discovery of the own pending bot is admitted (multi mode)",
              Reg.telegramDiscoveryRefusal(profile: "work", token: "200:NEW", paths: paths) == nil)
        check("identity: another assistant may not scan or reserve that bot",
              Reg.telegramDiscoveryRefusal(profile: "default", token: "200:NEW", paths: paths)?.contains("Work") == true
              && (try? ticket("default", "200:NEW")) == nil)
        check("identity: a second change of the same kind is refused while the first is live",
              (try? ticket("work", "300:OTHER")) == nil)
        var wrote = false
        try? t.commit { wrote = true }
        let afterCommit = (try? Reg.read(paths))??.record("work")
        check("identity: commit writes the secret and keeps the old bot releasing",
              wrote && afterCommit?.bot.current == Reg.digest(.bot, "200:NEW")
              && afterCommit?.bot.releasing?.value == Reg.digest(.bot, "100:OLD") && afterCommit?.activeTx["bot"]?.phase == "cutover")
        check("identity: the old bot cannot be reserved while it is releasing", (try? ticket("default", "100:OLD")) == nil)
        t.finish()
        let afterFinish = (try? Reg.read(paths))??.record("work")
        check("identity: finish releases the old bot and ends the transaction",
              afterFinish?.bot.releasing == nil && afterFinish?.activeTx.isEmpty == true)
        if let t2 = try? ticket("default", "100:OLD") { t2.abort(); check("identity: the released bot is free for another assistant", true) }
        else { check("identity: the released bot is free for another assistant", false) }
        check("identity: abort removed only its own reservation", (try? Reg.read(paths))??.record("default")?.bot.pending == nil)
        // Without a reservation the discovery stopgap is gone only for the
        // owner of a live pending entry; a stranger's bot is still refused.
        check("identity: discovery of an unreserved new bot is refused in multi mode",
              Reg.telegramDiscoveryRefusal(profile: "work", token: "999:FRESH", paths: paths) != nil)
        // Offline mode refuses when the profile has a live assistant lease.
        let workDir = leaseDirs.appendingPathComponent("work", isDirectory: true)
        if let lease = try? MemberLease.create(in: workDir, role: "assistant", sessionKind: "daemon", profile: "work") {
            check("identity: an offline setter refuses while the assistant's lease is live",
                  (try? ticket("work", "400:X", .offline)) == nil)
            check("identity: the running assistant itself may change it", { () -> Bool in
                guard let own = try? ticket("work", "400:X", .assistant) else { return false }
                own.abort(); return true
            }())
            lease.release()
        }
        check("identity: offline allowed once nothing runs", { () -> Bool in
            guard let t = try? ticket("work", "400:X", .offline) else { return false }
            t.abort(); return true
        }())
        // A ticket dropped without commit aborts (deinit).
        do { _ = try? ticket("work", "500:Y") }
        check("identity: a dropped ticket releases its reservation", (try? Reg.read(paths))??.record("work")?.activeTx.isEmpty == true)
    }

    /// Real setup-api process (the phone app / standalone menu path) while
    /// the extra's assistant runs: refused, nothing written or reserved.
    private func identitySetupAPIRefusesWhileRunning() {
        guard ensureExtra("work", display: "Work"),
              let running = startChild(["--profile", "work", "__member-probe", "--assistant", "--hold", "4"]),
              running.waitFor(8, { $0.contains("\"uuid\"") }) else { check("setup-api: running assistant", false); return }
        let body = #"{"telegram":{"token":"5151:ABC","chat_id":"12345"}}"#
        let r = run(["--profile", "work", "setup-api", "apply"], stdin: body)
        check("setup-api: a bot change refuses while the assistant runs",
              r.out.contains("identity_refused") && r.out.contains("This assistant is running"), r.out)
        let secrets = readJSON(configBase + "/briglia-profiles/work/secrets.json")
        check("setup-api: nothing was written", secrets?[KeychainHelper.telegramBotTokenKey] == nil)
        _ = running.waitExit(10)
        let ok = run(["--profile", "work", "setup-api", "apply"], stdin: body)
        let after = readJSON(configBase + "/briglia-profiles/work/secrets.json")
        check("setup-api: with the assistant stopped the change commits and is reserved",
              ok.out.contains("\"ok\":true") && after?[KeychainHelper.telegramBotTokenKey] as? String == "5151:ABC"
              && registryDoc()?.record("work")?.bot.current == Reg.digest(.bot, "5151:ABC")
              && registryDoc()?.record("work")?.activeTx.isEmpty == true, ok.out)
        let dup = run(["setup-api", "apply"], stdin: #"{"telegram":{"token":"5151:ZZZ","chat_id":"999"}}"#)
        check("setup-api: default cannot take work's bot (same bot id)",
              dup.out.contains("already used by the assistant ‘Work’"), dup.out)
    }

    /// Never-multi default: setters run as today, under the identity lock.
    private func identityDefaultNeverMulti() {
        let data = root.appendingPathComponent("nm2-data"), config = root.appendingPathComponent("nm2-config")
        let nm = ["XDG_DATA_HOME": data.path, "XDG_CONFIG_HOME": config.path]
        let ok = run(["setup-api", "apply"], extraEnv: nm, stdin: #"{"telegram":{"token":"6161:ABC","chat_id":"12345"}}"#)
        check("never-multi: a default bot change writes as today (no registry created)",
              ok.out.contains("\"ok\":true") && !FileManager.default.fileExists(atPath: data.path + "/" + AssistantProfile.sharedDirName), ok.out)
        let lockDir = data.appendingPathComponent("briglia/machine", isDirectory: true)
        try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        guard case .acquired(let held) = ProfileFileLock.take(lockDir.appendingPathComponent("identity-tx.lock")) else { return }
        let busy = run(["setup-api", "apply"], extraEnv: nm, stdin: #"{"telegram":{"token":"7171:ABC","chat_id":"12345"}}"#)
        check("never-multi: a default bot change waits for, then refuses on, a held identity lock",
              busy.out.contains("identity_refused"), busy.out)
        held.release()
    }

    // MARK: - Remove and stop

    func removeSection() {
        guard ensureExtra("gone", display: "Gone") else { check("remove: extra created", false); return }
        let config = configBase + "/briglia-profiles/gone", data = dataBase + "/briglia-profiles/gone"
        let homeGone = root.appendingPathComponent("home-gone").path
        // Refused while its assistant runs; restored to active.
        guard let running = startChild(["--profile", "gone", "__member-probe", "--assistant", "--hold", "20"]),
              running.waitFor(8, { $0.contains("\"uuid\"") }) else { check("remove: running assistant", false); return }
        let refused = run(["profiles", "remove", "gone", "--yes"])
        check("remove: refused while the assistant runs", refused.status != 0 && refused.out.contains("in use by a running assistant"), refused.out)
        check("remove: refusal restores the record to active", registryDoc()?.record("gone")?.state == "active"
              && registryDoc()?.record("gone")?.removingOp == nil && FileManager.default.fileExists(atPath: config))
        // Stop: validated SIGTERM.
        let stop = run(["profiles", "stop", "gone"])
        check("stop: signals the validated lease holder and waits for its lease to end",
              stop.status == 0 && stop.out.contains("Stopped") && running.waitExit(10) != nil, stop.out)
        let again = run(["profiles", "stop", "gone"])
        check("stop: nothing running → says so", again.out.contains("not running"), again.out)
        // A forged sidecar (pid of an unrelated process) is never signalled.
        if let dir = extraLeaseDir("gone"), let fake = try? MemberLease.create(in: dir, role: "assistant", sessionKind: "daemon", profile: "gone") {
            try? fake.update { $0.pid = getppid(); $0.processStartTime = "forged" }
            let forged = run(["profiles", "stop", "gone"])
            check("stop: a sidecar whose pid is not the lease holder is refused, nothing signalled",
                  forged.status != 0 && forged.out.contains("not the one that holds its lease"), forged.out)
            fake.release()
        }
        // Mind export first (outside every lock), then removal.
        let exportDir = root.appendingPathComponent("exports", isDirectory: true)
        let removed = run(["profiles", "remove", "gone", "--yes", "--export-to", exportDir.path])
        let exported = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        check("remove: the memory export ran first (a .mind file of that assistant)",
              exported.contains { $0.hasPrefix("briglia-mind-gone-") }, "\(exported) \(removed.out)")
        check("remove: removes the assistant", removed.status == 0 && registryDoc()?.record("gone") == nil, removed.out)
        check("remove: roots deleted, home folder kept and printed",
              !FileManager.default.fileExists(atPath: config) && !FileManager.default.fileExists(atPath: data)
              && FileManager.default.fileExists(atPath: homeGone) && removed.out.contains(homeGone), removed.out)
        check("remove: the generation's lease directory is gone",
              !FileManager.default.fileExists(atPath: sharedDir + "/members/gone"))
        // Re-add gets a new generation.
        ensureExtra("gone", display: "Gone")
        check("remove: a re-added profile gets a new generation", generation("gone") != nil)
        // Concurrent remover: a live removing op → refused; once it is dead,
        // the next remover adopts and finishes the interrupted removal.
        let opLock = URL(fileURLWithPath: sharedDir + "/tx/foreign-remover.lock")
        guard case .acquired(let foreign) = ProfileFileLock.take(opLock) else { return }
        mutateRegistry { d in if let i = d.index("gone") { d.records[i].state = "removing"; d.records[i].removingOp = "foreign-remover" } }
        let concurrent = run(["profiles", "remove", "gone", "--yes", "--no-export"])
        check("remove: a second remover is refused while the first lives", concurrent.status != 0 && concurrent.out.contains("another removal"), concurrent.out)
        foreign.release()
        let resumed = run(["profiles", "remove", "gone", "--yes", "--no-export"])
        check("remove: resumes a dead remover's interrupted removal", resumed.status == 0 && registryDoc()?.record("gone") == nil, resumed.out)
        ensureExtra("gone", display: "Gone")
        removeRaceInProcess()
        _ = run(["profiles", "remove", "gone", "--yes", "--no-export"])
    }

    /// Publish-then-look: a starter whose lease appeared after `removing`
    /// was published but before the probe is seen → refused and restored.
    /// Generation changed since the confirmation → refused.
    private func removeRaceInProcess() {
        let paths = Reg.Paths(root: root.appendingPathComponent("rm-reg", isDirectory: true))
        _ = try? Reg.withLock(paths) { doc in
            doc = Reg.Document(version: 1, records: [Reg.newRecord(name: "default", displayName: "Bree"),
                                                     Reg.newRecord(name: "w", displayName: "W")])
        }
        let gen = (try? Reg.read(paths))??.record("w")?.generation ?? ""
        let leases = root.appendingPathComponent("rm-leases", isDirectory: true)
        let cfg = root.appendingPathComponent("rm-config", isDirectory: true), dat = root.appendingPathComponent("rm-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dat, withIntermediateDirectories: true)
        var late: MemberLease?
        var hooks = ProfileLifecycle.Hooks()
        hooks.paths = paths
        hooks.leaseDirectory = { _, _ in leases }
        hooks.configRoot = { _ in cfg }
        hooks.dataRoot = { _ in dat }
        hooks.barrierActive = { false }
        hooks.disableUnit = { _ in }
        hooks.removePreferences = { _ in }
        hooks.homeFolder = { _ in nil }
        hooks.shareLock = { nil }
        hooks.afterPublish = { late = try? MemberLease.create(in: leases, role: "session", sessionKind: "menu", profile: "w") }
        let first = Result { try ProfileLifecycle.remove(name: "w", confirmedGeneration: gen, hooks: hooks) }
        check("remove race: a member that entered before the probe is seen; removal refused",
              (try? first.get()) == nil && FileManager.default.fileExists(atPath: cfg.path))
        check("remove race: the record is active again", (try? Reg.read(paths))??.record("w")?.state == "active")
        late?.release()
        hooks.afterPublish = {}
        let wrongGen = Result { try ProfileLifecycle.remove(name: "w", confirmedGeneration: "old-generation", hooks: hooks) }
        check("remove: a generation changed since the confirmation is refused", (try? wrongGen.get()) == nil
              && (try? Reg.read(paths))??.record("w") != nil)
        hooks.barrierActive = { true }
        check("remove: refused while an upgrade barrier exists",
              (try? ProfileLifecycle.remove(name: "w", confirmedGeneration: gen, hooks: hooks)) == nil)
        hooks.barrierActive = { false }
        let ok = Result { try ProfileLifecycle.remove(name: "w", confirmedGeneration: gen, hooks: hooks) }
        check("remove: succeeds with no member", (try? ok.get()) != nil && (try? Reg.read(paths))??.record("w") == nil
              && !FileManager.default.fileExists(atPath: cfg.path))
    }
}
