import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The upgrade barrier end to end (§6, §16 items 6, 6a–6f): real headless
/// daemons (default + an extra) running from a scratch install, a local
/// "newer" pair (same binary, a bundle whose test sequence is higher),
/// `briglia upgrade` as the session coordinator, kill points and recovery.
extension ProfileHarness {
    struct UpgradeFixture {
        var install: URL
        var exe: URL
        var bundle: URL
        var staged: URL
        var env: [String: String]
    }

    func makeUpgradeFixture() -> UpgradeFixture? {
        let fm = FileManager.default
        let install = root.appendingPathComponent("install", isDirectory: true)
        let staged = root.appendingPathComponent("staged", isDirectory: true)
        try? fm.createDirectory(at: install, withIntermediateDirectories: true)
        try? fm.createDirectory(at: staged, withIntermediateDirectories: true)
        let realExe = UpgradeService.executableURL
        // The resource bundle this binary really uses (next to it, or the
        // build directory's when it runs through a hard link elsewhere).
        let besideExe = realExe.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName)
        let realBundle = FileManager.default.fileExists(atPath: besideExe.path) ? besideExe : Bundle.module.bundleURL
        let exe = install.appendingPathComponent(Self.exeName)
        let bundle = install.appendingPathComponent(BundleCheck.bundleName)
        guard link(realExe.path, exe.path) == 0 || (try? fm.copyItem(at: realExe, to: exe)) != nil,
              (try? fm.copyItem(at: realBundle, to: bundle)) != nil,
              link(realExe.path, staged.appendingPathComponent("briglia").path) == 0
                || (try? fm.copyItem(at: realExe, to: staged.appendingPathComponent("briglia"))) != nil,
              (try? fm.copyItem(at: realBundle, to: staged.appendingPathComponent(BundleCheck.bundleName))) != nil else { return nil }
        try? "123".write(to: bundle.appendingPathComponent(ReleaseSequence.testFileName), atomically: true, encoding: .utf8)
        setStagedSequence(staged, 124)
        try? "9.9.9-test".write(to: staged.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        var e: [String: String] = [ReleaseSequence.testKey: "1", "BRIGLIA_TEST_NO_BROWSER_BOOTSTRAP": "1",
                                   "BRIGLIA_TEST_UPGRADE_STAGED": staged.path]
        e["BRIGLIA_TEST_UPGRADE_WAIT_SECONDS"] = "60"
        return UpgradeFixture(install: install, exe: exe, bundle: bundle, staged: staged, env: e)
    }

    func setStagedSequence(_ staged: URL, _ n: Int) {
        let b = staged.appendingPathComponent(BundleCheck.bundleName)
        try? "\(n)".write(to: b.appendingPathComponent(ReleaseSequence.testFileName), atomically: true, encoding: .utf8)
        try? "staged-\(n)".write(to: b.appendingPathComponent("staged-marker"), atomically: true, encoding: .utf8)
    }

    func installedMarker(_ fx: UpgradeFixture) -> String? {
        try? String(contentsOf: fx.bundle.appendingPathComponent("staged-marker"), encoding: .utf8)
    }

    func runFrom(_ fx: UpgradeFixture, _ args: [String], extra: [String: String] = [:]) -> Run {
        let p = Process()
        p.executableURL = fx.exe
        p.arguments = args
        var e = env
        for (k, v) in fx.env { e[k] = v }
        for (k, v) in extra { e[k] = v }
        p.environment = e
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Run(status: -1, out: "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(status: p.terminationStatus, out: String(decoding: data, as: UTF8.self))
    }

    func startFrom(_ fx: UpgradeFixture, _ args: [String], extra: [String: String] = [:]) -> MAChild? {
        let p = Process()
        p.executableURL = fx.exe
        p.arguments = args
        var e = env
        for (k, v) in fx.env { e[k] = v }
        for (k, v) in extra { e[k] = v }
        p.environment = e
        p.currentDirectoryURL = root
        let out = Pipe(), input = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = input
        do { try p.run() } catch { return nil }
        return MAChild(process: p, pipe: out)
    }

    func liveAssistants(_ dir: URL?) -> [MemberLeases.Entry] {
        guard let dir else { return [] }
        return MemberLeases.list(dir).filter { $0.probe == .live && $0.isAssistant }
    }

    var defaultMembers: URL { URL(fileURLWithPath: machineDir + "/members", isDirectory: true) }

    func upgradeSection() {
        guard let fx = makeUpgradeFixture() else { check("upgrade: fixture", false); return }
        try? writeDefaultSecrets(["llm_provider": "openai_compatible", "openai_compatible_base_url": "http://127.0.0.1:9/v1",
                                  "openai_compatible_model": "mock-model", "openai_compatible_api_key": "k",
                                  "assistant_name": "Bree", "user_name": "Test"])
        ensureExtra("work", display: "Work")      // the busy participant below (independent of other sections)
        let add = run(["profiles", "add", "up", "--name", "Up", "--home", root.appendingPathComponent("home-up").path, "--copy-keys"])
        guard add.status == 0 else { check("upgrade: extra with copied keys", false, add.out); return }
        // Real-manager readiness first: later steps leave an installed.json
        // whose (test) sequence would make harness children re-exec.
        readinessInRealManager()
        // Trust rule (pure, §5.1).
        check("trust: floor equal to the candidate is accepted", UpgradeCoordinator.trustRefusal(candidate: 102, floor: 102, installed: 100) == nil)
        check("trust: a floor above the candidate refuses", UpgradeCoordinator.trustRefusal(candidate: 101, floor: 102, installed: 100) != nil)
        check("trust: old image offering 101 after 102 was installed is refused",
              UpgradeCoordinator.trustRefusal(candidate: 101, floor: 100, installed: 102) != nil)
        check("trust: candidate > floor is not required (equality case, retry after failed download)",
              UpgradeCoordinator.trustRefusal(candidate: 103, floor: 103, installed: nil) == nil)

        guard let d0 = startFrom(fx, ["daemon"]), let d1 = startFrom(fx, ["--profile", "up", "daemon"]) else {
            check("upgrade: daemons start", false); return
        }
        defer { d0.kill(SIGTERM); d1.kill(SIGTERM) }
        let upDir = extraLeaseDir("up")
        let up = d0.waitFor(30) { _ in self.liveAssistants(self.defaultMembers).count == 1 }
            && d1.waitFor(30) { _ in self.liveAssistants(upDir).count == 1 }
            && d0.waitFor(30) { $0.contains("daemon running") } && d1.waitFor(30) { $0.contains("daemon running") }
        check("upgrade: default and an extra daemon run with assistant leases", up, d0.output + d1.output)
        guard up else { return }
        let pid0 = d0.process.processIdentifier, pid1 = d1.process.processIdentifier

        // Busy participant → timeout cancels, nothing changed.
        if let busy = startChild(["--profile", "work", "__member-probe", "--assistant", "--hold", "60"]),
           busy.waitFor(10, { $0.contains("\"uuid\"") }) {
            let r = runFrom(fx, ["upgrade", "--yes"], extra: ["BRIGLIA_TEST_UPGRADE_WAIT_SECONDS": "6"])
            check("barrier: a busy assistant makes the update wait, then cancel naming it; nothing changed",
                  r.status != 0 && r.out.contains("cancelled") && r.out.contains("Work") && installedMarker(fx) == nil
                  && UpgradeBarrier.current(barrierPaths)?.state == .cancelled, r.out)
            busy.kill()
        }
        check("barrier: after a cancel both daemons keep running", d0.running && d1.running)
        // …and keep polling: a cancelled barrier resumed admission, it did
        // not stop the poll loop (never stopPolling, §6.4).
        let ticksBefore = d0.output.components(separatedBy: "Listening...").count
        Thread.sleep(forTimeInterval: 3.5)
        check("barrier: after a cancel the daemon's poll loop still runs (admission resumed, not stopped)",
              d0.output.components(separatedBy: "Listening...").count > ticksBefore && !d0.output.contains("· Stopped"))
        // A session that does not close itself (not long-lived) is waited
        // for: the barrier never publishes past it (§6.1, §6.3 step 5).
        if let sess = startChild(["__member-probe", "--hold", "60"]), sess.waitFor(10, { $0.contains("\"uuid\"") }) {
            let r = runFrom(fx, ["upgrade", "--yes"], extra: ["BRIGLIA_TEST_UPGRADE_WAIT_SECONDS": "5"])
            check("barrier: an open session makes the update wait, then cancel; nothing changed",
                  r.status != 0 && r.out.contains("probe open") && installedMarker(fx) == nil, r.out)
            sess.kill()
        }

        // A long-lived session closes itself; everyone parks; swap; restart.
        guard let session = startChild(["__member-probe", "--long-lived", "--hold", "120"]),
              session.waitFor(10, { $0.contains("\"uuid\"") }) else { check("barrier: long-lived session", false); return }
        let r = runFrom(fx, ["upgrade", "--yes"])
        check("barrier: the update commits once every assistant parked", r.status == 0 && r.out.contains("updated to 9.9.9-test"), r.out)
        check("barrier: a long-lived session closed itself with the updating message (exit 75)",
              session.waitExit(10) == 75 && session.output.contains("Briglia is updating"), session.output)
        check("barrier: the new pair is installed", installedMarker(fx) == "staged-124")
        let installed = UpgradeBarrier.readFile(barrierPaths.installed, as: UpgradeBarrier.Installed.self)
        if case .value(let rec) = installed { check("barrier: installed.json records sequence 124", rec.sequence == 124) }
        else { check("barrier: installed.json records sequence 124", false) }
        let restarted = d0.waitFor(30) { _ in self.liveAssistants(self.defaultMembers).first?.sidecar?.releaseSequence == 124 }
            && d1.waitFor(30) { _ in self.liveAssistants(upDir).first?.sidecar?.releaseSequence == 124 }
        check("barrier: both assistants restarted in place (same pid) on the new pair",
              restarted && d0.running && d1.running && d0.process.processIdentifier == pid0 && d1.process.processIdentifier == pid1,
              d0.output.suffix(800) + "\n" + d1.output.suffix(800))
        let closed = d0.waitFor(20) { _ in UpgradeBarrier.current(self.barrierPaths)?.state == .closed }
        check("barrier: closed from disk once every participant acked restarted; journal and backups gone",
              closed && !FileManager.default.fileExists(atPath: barrierPaths.journal.path)
              && !((try? FileManager.default.contentsOfDirectory(atPath: fx.install.path)) ?? []).contains { $0.contains(".briglia-upgrade-") })

        // Same release again: not newer → cancelled (old-image regression shape).
        let again = runFrom(fx, ["upgrade", "--yes"], extra: ["BRIGLIA_TEST_UPGRADE_WAIT_SECONDS": "30"])
        check("barrier: a release not newer than the installed one is refused under the barrier",
              again.status != 0 && again.out.contains("not newer"), again.out)

        // An unfinished turn checkpoint in ANY registered profile refuses.
        setStagedSequence(fx.staged, 125)
        let salvage = URL(fileURLWithPath: dataBase + "/briglia-profiles/up/turn_salvage.json")
        try? "not json".write(to: salvage, atomically: true, encoding: .utf8)
        chmod(salvage.path, 0o600)
        let cp = runFrom(fx, ["upgrade", "--yes"], extra: ["BRIGLIA_TEST_UPGRADE_WAIT_SECONDS": "30"])
        check("barrier: an extra's unfinished turn checkpoint refuses the update",
              cp.status != 0 && cp.out.contains("unfinished"), cp.out)
        try? FileManager.default.removeItem(at: salvage)

        // Coordinator killed after the swap: an assistant's monitor becomes
        // the recovery owner and rolls back (journal placed, barrier open).
        let killed = runFrom(fx, ["upgrade", "--yes"], extra: ["BRIGLIA_UPGRADE_KILL": "placed"])
        check("recovery: coordinator killed at `placed`", killed.status == 91, killed.out)
        let rolledBack = d0.waitFor(30) { _ in
            UpgradeBarrier.current(self.barrierPaths)?.state == .cancelled
        }
        check("recovery: a running assistant took over and rolled the swap back (old pair restored)",
              rolledBack && installedMarker(fx) == "staged-124", "\(String(describing: UpgradeBarrier.current(barrierPaths)))")
        check("recovery: both assistants resumed (still running)", d0.running && d1.running)
        d0.kill(SIGTERM); d1.kill(SIGTERM)

        upgradeKillPoints(fx)
        upgradeStuckAndConcurrentRecovery(fx)
        // The scratch install's records must not follow later sections: its
        // installed.json names a test sequence the harness binary never has.
        try? FileManager.default.removeItem(at: barrierPaths.installed)
        try? FileManager.default.removeItem(at: barrierPaths.barrier)
        UpgradeBarrier.clearAcks(barrierPaths)
    }

    /// Every kill point, coordinator alone (zero assistants), then
    /// `briglia upgrade --recover` from a fresh process (§6.5 table).
    private func upgradeKillPoints(_ fx: UpgradeFixture) {
        var seq = 130
        let rollBack = ["prepared", "moved-binary-aside", "moved-bundle-aside", "moved-binary-in", "moved-bundle-in", "placed"]
        let finish = ["verified", "installed", "journal-committed", "barrier-committed"]
        for point in rollBack + finish {
            seq += 1
            setStagedSequence(fx.staged, seq)
            let before = installedMarker(fx)
            let k = runFrom(fx, ["upgrade", "--yes"], extra: ["BRIGLIA_UPGRADE_KILL": point])
            guard k.status == 91 else { check("kill \(point): coordinator died there", false, k.out); continue }
            if point != "prepared", rollBack.contains(point), case .value(let j) = UpgradeBarrier.journal(barrierPaths) {
                check("kill \(point): the old binary's backup is retained until commit",
                      FileManager.default.fileExists(atPath: j.backupBinary))
            }
            // The install's binary may be moved aside: probe and recover
            // with the harness binary (same code, same scratch records).
            let refused = run(["__member-probe"])
            let rec = run(["upgrade", "--recover"])
            let state = UpgradeBarrier.current(barrierPaths)?.state
            if rollBack.contains(point) {
                check("kill \(point): sessions refused, then --recover restores the old pair (cancelled)",
                      refused.status == 75 && rec.status == 0 && state == .cancelled && installedMarker(fx) == before
                      && FileManager.default.fileExists(atPath: fx.exe.path), "\(refused.status) \(rec.out) \(String(describing: state))")
            } else {
                check("kill \(point): --recover finishes the committed install and closes",
                      rec.status == 0 && state == .closed && installedMarker(fx) == "staged-\(seq)",
                      "\(rec.out) \(String(describing: state)) \(installedMarker(fx) ?? "nil")")
            }
            check("kill \(point): afterwards Briglia runs normally", runFrom(fx, ["__member-probe"]).status == 0)
        }
    }

    private func upgradeStuckAndConcurrentRecovery(_ fx: UpgradeFixture) {
        setStagedSequence(fx.staged, 160)
        let k = runFrom(fx, ["upgrade", "--yes"], extra: ["BRIGLIA_UPGRADE_KILL": "moved-binary-aside"])
        guard k.status == 91, case .value(let j) = UpgradeBarrier.journal(barrierPaths) else { check("stuck: setup", false, k.out); return }
        // Lose the backup: nothing can be verified → stuck, never reopened.
        let saved = root.appendingPathComponent("saved-backup")
        try? FileManager.default.moveItem(atPath: j.backupBinary, toPath: saved.path)
        let r1b = run(["upgrade", "--recover"])
        check("stuck: a failed restore leaves the barrier stuck and says how to fix it",
              UpgradeBarrier.current(barrierPaths)?.state == .stuck && r1b.status != 0 && r1b.out.contains("restore"), r1b.out)
        check("stuck: sessions stay refused while stuck (time never reopens)", run(["__member-probe"]).status == 75)
        // A second recovery while one holds the lock is refused.
        if case .acquired(let held) = ProfileFileLock.take(barrierPaths.lock) {
            let busy = run(["upgrade", "--recover"])
            check("recovery: a second recovery is refused while one runs", busy.status != 0 && busy.out.contains("already running"), busy.out)
            held.release()
        }
        try? FileManager.default.moveItem(at: saved, to: URL(fileURLWithPath: j.backupBinary))
        let r2 = run(["upgrade", "--recover"])
        check("stuck: --recover with the backup back restores the old pair (cancelled)",
              r2.status == 0 && UpgradeBarrier.current(barrierPaths)?.state == .cancelled
              && FileManager.default.fileExists(atPath: fx.exe.path), r2.out)
        check("stuck: Briglia runs normally again", runFrom(fx, ["__member-probe"]).status == 0)
    }

    /// §6.2 readiness of a real manager, in an isolated child member.
    private func readinessInRealManager() {
        let r = run(["__upgrade-readiness-check"], extraEnv: ["BRIGLIA_TEST_NO_BROWSER_BOOTSTRAP": "1"])
        let lines = r.out.split(separator: "\n").filter { $0.hasPrefix("CHECK ") }
        check("readiness: the real-manager child ran", r.out.contains("READINESS_DONE") && !lines.isEmpty, String(r.out.suffix(600)))
        for line in lines {
            let ok = line.hasPrefix("CHECK 1 ")
            check(String(line.dropFirst(8)), ok)
        }
    }
}
