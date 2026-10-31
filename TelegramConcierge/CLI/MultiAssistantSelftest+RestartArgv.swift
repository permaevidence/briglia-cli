import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// 2026-10-31 (docs/review/UPGRADE_TERMINAL_COORDINATOR_EXIT_2026-10-31.md):
/// a chat promoted from `briglia menu` / `briglia quicksetup` re-executed
/// its original argv on /upgrade and /restart, so the new image ran the menu,
/// refused during the committed update (exit 75), and the barrier closed
/// without anyone noticing. Section `restartargv`: the restart argv (pure,
/// the real `restartNow`, a real `execv` through `reexecIfOlder`), the
/// original refusal as a negative control, and the not-restarted surfacing.
extension ProfileHarness {
    func restartArgvSection() {
        clearBarrier()
        try? FileManager.default.removeItem(at: barrierPaths.installed)
        _ = ensureExtra("work", display: "Work")

        // RA1 pure.
        let a0 = "/x/briglia"
        let cases: [([String], [String])] = [
            ([a0, "menu"], [a0, "chat"]),
            ([a0, "quicksetup"], [a0, "chat"]),
            ([a0, "quicksetup", "--name", "Sofia", "--yes", "--telegram-chat-id", "5551234567", "--no-tools"], [a0, "chat"]),
            ([a0, "--profile", "health", "quicksetup", "--yes"], [a0, "--profile", "health", "chat"]),
            ([a0, "--profile", "work", "menu"], [a0, "--profile", "work", "chat"]),
            ([a0, "--profile=work", "menu", "--no-open"], [a0, "--profile=work", "chat"]),
            ([a0, "menu", "--profile", "work"], [a0, "chat"]),
            ([a0], [a0, "chat"]),
        ]
        for (input, want) in cases {
            check("RA1: chat restart argv of \(input.dropFirst()) is \(want.dropFirst())",
                  RestartArgv.chatArguments(from: input) == want, "\(RestartArgv.chatArguments(from: input))")
        }

        // RA2 a promoted probe (the menu's / quick setup's promotion path).
        func argvLine(_ out: String, _ tag: String) -> [String]? {
            guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix(tag) }) else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(tag.count).utf8))) as? [String]
        }
        let plain = run(["__member-probe", "--promote", "--print-restart-argv"])
        let before = argvLine(plain.out, "RESTART_ARGV_BEFORE:"), after = argvLine(plain.out, "RESTART_ARGV_AFTER:")
        check("RA2: before the promotion the restart argv is the process's own argv, verbatim",
              before.map { Array($0.dropFirst()) } == ["__member-probe", "--promote", "--print-restart-argv"], plain.out)
        check("RA2: after the promotion it is `<argv0> chat`",
              after != nil && after == [before?.first ?? "?", "chat"] && plain.out.contains("PROMOTED:ok:assistant:chat"), plain.out)
        for flag in [["--profile", "work"], ["--profile=work"]] {
            let r = run(flag + ["__member-probe", "--promote", "--print-restart-argv"])
            let got = argvLine(r.out, "RESTART_ARGV_AFTER:")
            check("RA2: a promoted extra keeps its leading \(flag.joined(separator: " ")) (→ chat)",
                  got.map { Array($0.dropFirst()) } == flag + ["chat"], r.out)
        }
        let viaEnv = run(["__member-probe", "--promote", "--print-restart-argv"], extraEnv: [AssistantProfile.environmentKey: "work"])
        check("RA2: an extra selected by BRIGLIA_PROFILE restarts as `chat` (the variable is inherited by the exec)",
              argvLine(viaEnv.out, "RESTART_ARGV_AFTER:").map { Array($0.dropFirst()) } == ["chat"]
                && viaEnv.out.contains("\"profile\":\"work\""), viaEnv.out)

        let single = run(["__member-probe", "--promote", "--print-restart-argv", "--restart-now"],
                         extraEnv: ["XDG_DATA_HOME": root.appendingPathComponent("ra-single-data").path,
                                    "XDG_CONFIG_HOME": root.appendingPathComponent("ra-single-config").path],
                         removeEnv: [AssistantProfile.experimentalKey])
        check("RA2: a single assistant without coordination (no member lease) also restarts as `chat`",
              single.out.contains("PROMOTED-UNLEASED:ok")
                && argvLine(single.out, "RESTART_EXEC:").map { Array($0.dropFirst()) } == ["chat"], single.out)

        // RA3 the real restartNow (dev intercept records the argv it would exec).
        let ordinary = run(["__member-probe", "--assistant", "--restart-now"])
        check("RA3: /restart and /upgrade of an ordinary process exec its own argv byte for byte",
              ordinary.status == 0 && argvLine(ordinary.out, "RESTART_EXEC:").map { Array($0.dropFirst()) } == ["__member-probe", "--assistant", "--restart-now"],
              ordinary.out)
        let promoted = run(["--profile", "work", "__member-probe", "--promote", "--restart-now"])
        check("RA3: /restart and /upgrade of a menu-promoted chat exec `--profile work chat`, never the menu",
              promoted.status == 0 && argvLine(promoted.out, "RESTART_EXEC:").map { Array($0.dropFirst()) } == ["--profile", "work", "chat"],
              promoted.out)

        // RA4 a real execv through reexecIfOlder (the barrier's re-exec of an
        // older image): the installed record appears after the probe started
        // and names a capture script.
        let capture = root.appendingPathComponent("ra-install/briglia")
        let captured = root.appendingPathComponent("ra-captured.txt")
        func installCapture() -> Bool {
            let fm = FileManager.default
            try? fm.createDirectory(at: capture.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName), withIntermediateDirectories: true)
            try? "x".write(to: capture.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName).appendingPathComponent("f"), atomically: true, encoding: .utf8)
            try? "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > '\(captured.path)'\n".write(to: capture, atomically: true, encoding: .utf8)
            chmod(capture.path, 0o755)
            guard let sha = UpgradeBarrier.sha256(file: capture),
                  let bh = UpgradeBarrier.bundleHash(capture.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName)) else { return false }
            return (try? UpgradeBarrier.writeFile(UpgradeBarrier.Installed(version: "9.9.9-ra", sequence: 999_999, executable: capture.path,
                                                                           binarySHA256: sha, bundleHash: bh), to: barrierPaths.installed)) != nil
        }
        func execCase(_ args: [String]) -> [String]? {
            try? FileManager.default.removeItem(at: captured)
            try? FileManager.default.removeItem(at: barrierPaths.installed)
            guard let child = startChild(args + ["--reexec-after", "2"]) else { return nil }
            defer { child.kill() }
            guard child.waitFor(10, { $0.contains("\"pid\"") }), installCapture() else { return nil }
            _ = child.waitFor(15) { _ in FileManager.default.fileExists(atPath: captured.path) && !child.running }
            return (try? String(contentsOf: captured, encoding: .utf8)).map { $0.split(separator: "\n").map(String.init) }
        }
        let execPlain = execCase(["__member-probe", "--assistant"])
        check("RA4: a real re-exec of an ordinary assistant passes its own argv unchanged",
              execPlain == ["__member-probe", "--assistant", "--reexec-after", "2"], "\(String(describing: execPlain))")
        let execPromoted = execCase(["--profile", "work", "__member-probe", "--promote"])
        check("RA4: a real re-exec of a promoted chat runs `--profile work chat`",
              execPromoted == ["--profile", "work", "chat"], "\(String(describing: execPromoted))")
        try? FileManager.default.removeItem(at: barrierPaths.installed)
        try? FileManager.default.removeItem(at: captured)

        // RA5 negative control: why the old argv failed.
        writeBarrier(state: .committed, id: "ra-committed")
        let menu = run(["menu"])
        check("RA5 (original failure): under a committed update the old argv `menu` refuses with exit 75",
              menu.status == 75 && menu.out.contains("Briglia is updating"), "status \(menu.status): \(menu.out)")
        check("RA5: `chat` is the assistant entry (parks instead of refusing)",
              MemberEntry.classify(["chat"]) == .assistant(kind: "chat"))
        if let chat = startChild(["chat"]) {
            let refused = chat.waitFor(4) { _ in !chat.running }
            check("RA5: `chat` under the same barrier does not exit 75: it waits for the update to finish",
                  !refused || chat.process.terminationStatus != 75, chat.output)
            chat.kill()
        }
        clearBarrier()

        notRestartedChecks()
        startupReexecIsNotMissed()
    }

    /// Codex R1: a late starter enrolled in an open barrier, re-executed by
    /// `reexecIfOlder` on commit (no restart marker), must not be recorded
    /// or told that it did not restart.
    func startupReexecIsNotMissed() {
        let fm = FileManager.default
        let install = root.appendingPathComponent("ra-up-install", isDirectory: true)
        try? fm.removeItem(at: install)
        try? fm.createDirectory(at: install, withIntermediateDirectories: true)
        let realExe = UpgradeService.executableURL
        let besideExe = realExe.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName)
        let realBundle = fm.fileExists(atPath: besideExe.path) ? besideExe : Bundle.module.bundleURL
        let exe = install.appendingPathComponent(Self.exeName)
        let bundle = install.appendingPathComponent(BundleCheck.bundleName)
        guard link(realExe.path, exe.path) == 0 || (try? fm.copyItem(at: realExe, to: exe)) != nil,
              (try? fm.copyItem(at: realBundle, to: bundle)) != nil else { check("RA6: fixture", false); return }
        let seqFile = bundle.appendingPathComponent(ReleaseSequence.testFileName)
        try? "123".write(to: seqFile, atomically: true, encoding: .utf8)
        defer {
            try? fm.removeItem(at: barrierPaths.installed); clearBarrier(); UpgradeBarrier.clearAcks(barrierPaths)
            try? fm.removeItem(at: install)
        }
        guard case .acquired(let lock) = ProfileFileLock.take(barrierPaths.lock, waitSeconds: 5) else { check("RA6: upgrade.lock", false); return }
        var held: ProfileFileLock? = lock
        defer { held?.release() }
        UpgradeBarrier.clearAcks(barrierPaths)
        var barrier = UpgradeBarrier.Record(id: "ra6", state: .open, targetVersion: "test-124", targetSequence: 124, openedAt: Date(),
                                            coordinator: .init(lease: "gone", pid: 1, processStartTime: "x"), participants: [],
                                            committedBinarySHA256: nil, reason: nil)
        try? UpgradeBarrier.writeBarrier(barrier, barrierPaths)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["__member-probe", "--assistant", "--hold", "4"]
        var e = env
        e[ReleaseSequence.testKey] = "1"
        e["BRIGLIA_TEST_NO_BROWSER_BOOTSTRAP"] = "1"
        p.environment = e
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { check("RA6: probe starts", false); return }
        let child = MAChild(process: p, pipe: out)
        defer { child.kill() }
        // Late enrollment: the starter parks and acks; the coordinator adds it.
        var parked: (String, UpgradeBarrier.Ack)?
        let deadline = Date().addingTimeInterval(20)
        while parked == nil, Date() < deadline {
            for name in (try? fm.contentsOfDirectory(atPath: barrierPaths.ackDir.path)) ?? [] where name.hasSuffix(".json") {
                let uuid = String(name.dropLast(5))
                if let ack = UpgradeBarrier.readAck(uuid, barrierPaths), ack.barrierId == "ra6", ack.state == .parked { parked = (uuid, ack) }
            }
            if parked == nil { usleep(100_000) }
        }
        guard let (oldLease, ack) = parked else { check("RA6: the late starter parks", false, child.output); return }
        try? "124".write(to: seqFile, atomically: true, encoding: .utf8)
        guard let sha = UpgradeBarrier.sha256(file: exe), let bh = UpgradeBarrier.bundleHash(bundle),
              (try? UpgradeBarrier.writeFile(UpgradeBarrier.Installed(version: "test-124", sequence: 124, executable: exe.resolvingSymlinksInPath().path,
                                                                      binarySHA256: sha, bundleHash: bh), to: barrierPaths.installed)) != nil
        else { check("RA6: installed record", false); return }
        barrier.participants = [.init(profile: AssistantProfile.defaultName, generation: nil, lease: oldLease, incarnation: ack.incarnation, coordinator: false)]
        barrier.state = .committed
        barrier.committedBinarySHA256 = sha
        try? UpgradeBarrier.writeBarrier(barrier, barrierPaths)
        held?.release(); held = nil
        let done = child.waitFor(40) { $0.contains("PROBE_DONE") }
        let after = UpgradeBarrier.current(barrierPaths)
        check("RA6: the late starter re-execs into the new image and the barrier closes",
              done && after?.state == .closed && child.output.contains("\"reexecBarrier\":\"ra6\""), child.output)
        check("RA6: a successful startup re-exec is not recorded as not restarted",
              after?.notRestarted == nil, "\(String(describing: after))")
        check("RA6: and its own start does not tell the user it failed to restart",
              UpgradeBarrier.resolveOwnMissedRestart(profile: AssistantProfile.defaultName, restartedFromBarrier: "ra6", paths: barrierPaths) == nil)
    }

    /// Part 2: an assistant gone after the commit without a `restarted` ack.
    func notRestartedChecks() {
        let fm = FileManager.default
        let fake = root.appendingPathComponent("nr-install/briglia")
        let bundle = fake.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName)
        try? fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try? "nr".write(to: fake, atomically: true, encoding: .utf8)
        try? "b".write(to: bundle.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        guard let sha = UpgradeBarrier.sha256(file: fake), let bh = UpgradeBarrier.bundleHash(bundle),
              (try? UpgradeBarrier.writeFile(UpgradeBarrier.Installed(version: "9.9.9", sequence: 999, executable: fake.path,
                                                                      binarySHA256: sha, bundleHash: bh), to: barrierPaths.installed)) != nil
        else { check("NR: fixture", false); return }
        defer { try? fm.removeItem(at: barrierPaths.installed); clearBarrier() }
        let settings = UpgradeCoordinator.Settings(paths: barrierPaths, registryPaths: regPaths)
        func committed(_ id: String, acked: [String]) {
            let parts = [UpgradeBarrier.Participant(profile: AssistantProfile.defaultName, generation: nil, lease: "\(id)-lease-default",
                                                    incarnation: "i0", coordinator: true),
                         UpgradeBarrier.Participant(profile: "work", generation: generation("work"), lease: "\(id)-lease-work",
                                                    incarnation: "i1", coordinator: false)]
            UpgradeBarrier.clearAcks(barrierPaths)
            for p in parts where acked.contains(p.profile) {
                UpgradeBarrier.writeAck(.init(barrierId: id, incarnation: p.incarnation, state: .restarted, reason: nil, releaseSequence: 999),
                                        lease: p.lease, barrierPaths)
            }
            try? UpgradeBarrier.writeBarrier(.init(id: id, state: .committed, targetVersion: "9.9.9", targetSequence: 999, openedAt: Date(),
                                                   coordinator: .init(lease: "\(id)-lease-default", pid: 1, processStartTime: "x"),
                                                   participants: parts, committedBinarySHA256: sha, reason: nil), barrierPaths)
        }
        // NR1 closure records the missing participant.
        committed("nr1", acked: ["work"])
        let closed1 = UpgradeCoordinator.closeAttempt(settings, holdingLock: false)
        let b1 = UpgradeBarrier.current(barrierPaths)
        check("NR1: a participant gone after the commit without `restarted` is recorded at closure (never silent)",
              closed1 == .closed && b1?.state == .closed && b1?.notRestarted == [AssistantProfile.defaultName] && b1?.closedAt != nil,
              "\(closed1) \(String(describing: b1))")
        // NR2 everyone back → the record is unchanged in shape.
        committed("nr2", acked: [AssistantProfile.defaultName, "work"])
        let closed2 = UpgradeCoordinator.closeAttempt(settings, holdingLock: false)
        let raw2 = (try? String(contentsOf: barrierPaths.barrier, encoding: .utf8)) ?? ""
        check("NR2: when everyone restarted nothing is recorded (no new keys in barrier.json)",
              closed2 == .closed && UpgradeBarrier.current(barrierPaths)?.notRestarted == nil
                && !raw2.contains("notRestarted") && !raw2.contains("closedAt"), raw2)

        // The closed records below need no installed pair; an installed.json
        // newer than this image would make the live probe re-exec at entry.
        try? fm.removeItem(at: barrierPaths.installed)

        // NR3 pure grace / liveness.
        var rec = UpgradeBarrier.Record(id: "nr3", state: .closed, targetVersion: "9.9.9", targetSequence: 999, openedAt: Date(),
                                        coordinator: .init(lease: "c", pid: 1, processStartTime: "x"), participants: [],
                                        committedBinarySHA256: nil, reason: nil)
        rec.notRestarted = ["default"]
        rec.closedAt = Date(timeIntervalSince1970: 1_000_000)
        let t0 = rec.closedAt!
        check("NR3: inside the grace period nothing is reported (a restart may be mid-exec)",
              UpgradeBarrier.stillNotRestarted(rec, now: t0.addingTimeInterval(10), grace: 90) { _ in false }.isEmpty)
        check("NR3: after the grace a profile still not running is reported",
              UpgradeBarrier.stillNotRestarted(rec, now: t0.addingTimeInterval(100), grace: 90) { _ in false } == ["default"])
        check("NR3: a profile running again is not reported",
              UpgradeBarrier.stillNotRestarted(rec, now: t0.addingTimeInterval(100), grace: 90) { _ in true }.isEmpty)
        var open = rec; open.state = .committed
        check("NR3: only a closed barrier reports", UpgradeBarrier.stillNotRestarted(open, now: t0.addingTimeInterval(100), grace: 90) { _ in false }.isEmpty)

        // NR4 /status and doctor line, with real leases.
        func closedRecord(_ id: String, _ missing: [String], age: TimeInterval) {
            var r = rec
            r.id = id
            r.notRestarted = missing
            r.closedAt = Date().addingTimeInterval(-age)
            try? UpgradeBarrier.writeBarrier(r, barrierPaths)
        }
        closedRecord("nr4", ["default"], age: 1000)
        let line = UpgradeBarrier.notRestartedStatusLine(paths: barrierPaths, registryPaths: regPaths)
        check("NR4: /status names the assistant that did not restart",
              line?.contains("did not restart by itself") == true && line?.contains("9.9.9") == true, line ?? "nil")
        let doctor = Doctor.readOnlyReport(paths: barrierPaths, registryPaths: regPaths)
        check("NR4: `briglia doctor --read-only` shows it too", doctor.contains { $0.contains("did not restart by itself") }, doctor.joined(separator: "\n"))
        if let live = startChild(["__member-probe", "--assistant", "--hold", "20"]) {
            let up = live.waitFor(10) { $0.contains("\"uuid\"") }
            check("NR4: once that assistant runs again the line disappears",
                  up && UpgradeBarrier.notRestartedStatusLine(paths: barrierPaths, registryPaths: regPaths) == nil, live.output)
            live.kill()
        } else { check("NR4: live probe", false) }
        closedRecord("nr4b", ["default"], age: 5)
        check("NR4: within the grace period /status says nothing",
              UpgradeBarrier.notRestartedStatusLine(paths: barrierPaths, registryPaths: regPaths) == nil)

        // NR5 the other assistants' one-time Telegram notice.
        func onMain(_ body: @MainActor () -> Void) {
            if Thread.isMainThread { MainActor.assumeIsolated(body) } else { DispatchQueue.main.sync { MainActor.assumeIsolated(body) } }
        }
        onMain {
            closedRecord("nr5", ["default"], age: 1000)
            MissedRestartNotices.handledBarrier = nil
            let first = MissedRestartNotices.pending(me: "work", paths: barrierPaths, registryPaths: regPaths)
            let second = MissedRestartNotices.pending(me: "work", paths: barrierPaths, registryPaths: regPaths)
            check("NR5: another running assistant sends one notice per closed barrier", first?.contains("did not restart") == true && second == nil,
                  "\(String(describing: first)) / \(String(describing: second))")
            MissedRestartNotices.handledBarrier = nil
            check("NR5: an assistant never reports itself as not running",
                  MissedRestartNotices.pending(me: AssistantProfile.defaultName, paths: barrierPaths, registryPaths: regPaths) == nil)
            closedRecord("nr5b", ["default"], age: 5)
            MissedRestartNotices.handledBarrier = nil
            check("NR5: no notice inside the grace period, and it stays pending",
                  MissedRestartNotices.pending(me: "work", paths: barrierPaths, registryPaths: regPaths) == nil
                    && MissedRestartNotices.handledBarrier == nil)
            MissedRestartNotices.handledBarrier = nil
        }

        // NR6 the assistant's own next start.
        closedRecord("nr6", [AssistantProfile.defaultName, "work"], age: 1000)
        let own = UpgradeBarrier.resolveOwnMissedRestart(profile: AssistantProfile.defaultName, restartedFromBarrier: nil, paths: barrierPaths)
        check("NR6: a later start of the missing assistant tells its user once and leaves the list",
              own?.id == "nr6" && UpgradeBarrier.current(barrierPaths)?.notRestarted == ["work"], "\(String(describing: UpgradeBarrier.current(barrierPaths)))")
        check("NR6: the next start says nothing again",
              UpgradeBarrier.resolveOwnMissedRestart(profile: AssistantProfile.defaultName, restartedFromBarrier: nil, paths: barrierPaths) == nil)
        let slow = UpgradeBarrier.resolveOwnMissedRestart(profile: "work", restartedFromBarrier: "nr6", paths: barrierPaths)
        let after6 = UpgradeBarrier.current(barrierPaths)
        check("NR6: a slow but real restart of the same update is not a missed restart (no notice; removed from the list)",
              slow == nil && after6?.notRestarted == nil && after6?.closedAt == nil, "\(String(describing: after6))")
    }
}
