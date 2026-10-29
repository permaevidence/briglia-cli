import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden child of `__multi-assistant-selftest` (an assistant member in the
/// harness's scratch roots, with at least one extra registered): the
/// default's coordinated `/upgrade` beside the poll loop (S2-12) and the
/// multi-assistant `/status` and `/board` surfaces of a REAL manager.
struct Stage3ManagerCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__stage3-manager-check",
        abstract: "Internal: stage-3 checks of a real manager.",
        shouldDisplay: false
    )

    @Flag(name: .customLong("wipe")) var wipeOnly = false

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev"), let lease = MemberEntry.current else {
            print("CHECK 0 needs a development build and a member lease"); return
        }
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("CHECK \(ok ? 1 : 0) \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        }
        let m = ConversationManager()
        if wipeOnly {
            await wipeKeepsProtectedClaims(m, check: check)
            print("STAGE3_WIPE_DONE")
            return
        }
        let paths = UpgradeBarrier.Paths.live
        let held: ProfileFileLock? = { if case .acquired(let l) = ProfileFileLock.take(paths.lock) { return l }; return nil }()
        let other = UpgradeBarrier.Participant(profile: "work", generation: "g", lease: "0ther-1ease", incarnation: "inc-1", coordinator: false)
        let me = UpgradeBarrier.Participant(profile: "default", generation: nil, lease: lease.uuid, incarnation: lease.sidecar.incarnation, coordinator: true)
        let barrier = UpgradeBarrier.Record(id: "s3-1", state: .open, targetVersion: "9.9.9", targetSequence: 999, openedAt: Date(),
                                            coordinator: .init(lease: lease.uuid, pid: getpid(), processStartTime: ProcessIdentity.selfStartTime),
                                            participants: [me, other], committedBinarySHA256: nil, reason: nil)
        try? UpgradeBarrier.writeBarrier(barrier, paths)
        MemberEntry.isCoordinator = true
        m.upgradeCoordinatorTask = Task { try? await Task.sleep(nanoseconds: 120_000_000_000) }
        m.upgradeWaitingFor = ["‘Work’ (a job to finish)"]

        await m.upgradeMonitorTick(lease: lease)
        check("S2-12: the coordinating assistant does not park while another participant is still busy",
              !m.admissionPaused && UpgradeBarrier.readAck(lease.uuid, paths) == nil)
        let status = (await m.handleTerminalCommand("/status") ?? []).joined(separator: "\n")
        check("S2-12: /status answers during the wait and names who is still busy",
              status.contains("waiting for ‘Work’") && status.contains("Assistant: ") && status.contains("others: Work"), status)
        let again = (await m.handleTerminalCommand("/upgrade") ?? []).joined()
        check("S2-12: a second /upgrade answers at once (already in progress)", again.contains("already in progress"), again)
        let stop = (await m.handleTerminalCommand("/stop") ?? []).joined()
        check("S2-12: /stop is read during the wait and cancels the waiting update", m.upgradeCancelFlag.value
              && stop.contains("cancelled"), stop)
        m.upgradeCancelFlag.reset()
        _ = await m.handleTerminalCommand("/upgrade cancel")
        check("S2-12: /upgrade cancel raises the coordinator's cancel flag", m.upgradeCancelFlag.value)
        m.upgradeCancelFlag.reset()

        UpgradeBarrier.writeAck(.init(barrierId: barrier.id, incarnation: "inc-1", state: .parked, reason: nil,
                                      releaseSequence: ReleaseSequence.compiled), lease: other.lease, paths)
        await m.upgradeMonitorTick(lease: lease)
        check("S2-12: once every other participant parked, the coordinator parks itself (admission paused, acked parked)",
              m.admissionPaused && UpgradeBarrier.readAck(lease.uuid, paths)?.state == .parked)
        let parkedUpgrade = (await m.handleTerminalCommand("/upgrade cancel") ?? []).joined()
        check("S2-12: while parked, /upgrade cancel is still accepted (not the generic 'updating' refusal)",
              m.upgradeCancelFlag.value && !parkedUpgrade.contains("try again in a minute"), parkedUpgrade)
        m.upgradeCancelFlag.reset()
        m.browserSettingsCommandIngress += 1
        let busy = await m.upgradeBusyReason(initiating: true)
        m.browserSettingsCommandIngress -= 1
        check("S2-12: with the coordinator running as a task, a command in its handler counts as busy (no allowance)",
              busy == "a command", busy ?? "nil")

        var cancelled = barrier; cancelled.state = .cancelled
        try? UpgradeBarrier.writeBarrier(cancelled, paths)
        await m.upgradeMonitorTick(lease: lease)
        check("S2-12: cancelled → the coordinator resumes", !m.admissionPaused)
        m.upgradeCoordinatorTask?.cancel()
        m.upgradeCoordinatorTask = nil
        MemberEntry.isCoordinator = false
        try? FileManager.default.removeItem(at: paths.barrier)
        held?.release()

        let board = (await m.handleTerminalCommand("/board") ?? []).joined(separator: "\n")
        check("/board answers with the full board while several assistants exist", board.contains("Assistant board"), board)
        // S3-7: a terminal/app /upgrade receives the delayed result.
        UpgradeService.checkOverrideForTesting = {
            try? await Task.sleep(nanoseconds: 800_000_000)
            return .upToDate("9.9.9-test")
        }
        let local = (await m.handleTerminalCommand("/upgrade") ?? []).joined(separator: "\n")
        UpgradeService.checkOverrideForTesting = nil
        check("S3-7: a terminal/app /upgrade gets the acknowledgement and the delayed result in its reply",
              local.contains("Checking for an update") && local.contains("Already up to date (9.9.9-test)") && m.upgradeCoordinatorTask == nil, local)
        await successfulUpgradeDeliversBeforeRestart(m, lease: lease, check: check)
        print("STAGE3_DONE")
    }

    /// Codex stage-3 S3-R7-1: the real `/deleteuserdata` wipe must not
    /// delete claims bound to jobs its registry purge kept (join limit
    /// expired while a queued /stop batch was still terminating them).
    @MainActor private func wipeKeepsProtectedClaims(_ m: ConversationManager,
                                                     check: @escaping (String, Bool, String) -> Void) async {
        guard let ctx = MultiAssistant.context() else { check("S3-R7-1: multi-assistant context", false, "nil"); return }
        let reg = BackgroundProcessRegistry.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s3r71-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = MultiAssistant.canonical(dir.appendingPathComponent("claimed.txt").path)
        let trigger = dir.appendingPathComponent("TRIGGER").path
        FileManager.default.createFile(atPath: file, contents: Data("OWNER\n".utf8))
        let turn = UUID(), scope = "turn:" + turn.uuidString.lowercased()
        ClaimScopes.shared.turnStarted(turn)
        try? FileClaims.reserve(ctx, paths: [file], opId: "wipe1")
        try? FileClaims.settle(ctx, opId: "wipe1", changed: true, scopes: [scope])
        let body = "open(P,\">\",$ARGV[0]); print P $$; close P; while(1){ if(-e $ARGV[1]){ open(F,\">>\",$ARGV[2]); print F \"JOB\\n\"; close F; exit 0 } sleep 0.001 }"
        var jobs: [String] = [], pidFiles: [String] = []
        for i in 0..<6 {
            let pidFile = dir.appendingPathComponent("pid-\(i)").path
            let cmd = "exec /usr/bin/perl -MTime::HiRes=sleep -e '\(body)' \"\(pidFile)\" \"\(trigger)\" \"\(file)\""
            guard let j = try? await reg.start(command: cmd, workdir: dir.path, description: "s3r71-\(i)") else {
                check("S3-R7-1: start job \(i)", false, ""); return
            }
            jobs.append(j.id); pidFiles.append(pidFile)
        }
        let readyBy = Date().addingTimeInterval(15)
        while !pidFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) && Date() < readyBy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        ClaimScopes.shared.turnEnded(turn)
        let stop = Task.detached { _ = await reg.stopAllMainOwned() }
        let stampedBy = Date().addingTimeInterval(5)
        while await reg.runningBackgroundJobCount() != 0 && Date() < stampedBy {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await reg._testSetWipeJoinLimit(0.2)
        let failures = await m.deleteAllMemory()
        await reg._testSetWipeJoinLimit(nil)
        let liveAfter = await reg.unsettledEntryIds().intersection(jobs).count
        await ClaimScopes.shared.tick()
        let held = FileClaims.claims(ofSelf: ctx).contains { $0.path == file }
        check("S3-R7-1: /deleteuserdata reports the background commands it kept",
              failures.contains { $0.contains("still stopping") } && liveAfter > 0, "live \(liveAfter) failures \(failures)")
        check("S3-R7-1: the claim bound to those jobs survives the wipe while they are live (a peer edit stays refused)",
              held && ClaimScopes.shared.pendingScopesForTesting[scope] != nil, "held \(held)")
        FileManager.default.createFile(atPath: trigger, contents: Data())
        try? await Task.sleep(nanoseconds: 300_000_000)
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        check("S3-R7-1: every job was already signalled (no late write)", !text.contains("JOB"), text.debugDescription)
        await stop.value
        let cleared = await reg.purgeAllForWipeReporting()
        await ClaimScopes.shared.tick()
        check("S3-R7-1: once the jobs ended, the claim is released by ordinary scope settlement",
              cleared.retained == 0 && !FileClaims.claims(ofSelf: ctx).contains { $0.path == file }
              && ClaimScopes.shared.pendingScopesForTesting[scope] == nil, "retained \(cleared.retained)")
        // The ordinary case: nothing live, the wipe removes the claims file.
        try? FileClaims.reserve(ctx, paths: [file], opId: "wipe2")
        try? FileClaims.settle(ctx, opId: "wipe2", changed: true, scopes: ["op:wipe2-gone"])
        let second = await m.deleteAllMemory()
        check("S3-R7-1: with nothing live, the wipe still removes this assistant's claims file",
              !FileManager.default.fileExists(atPath: ctx.paths.claimsFile(ctx.me.profile).path)
              && !second.contains { $0.contains("still stopping") }, "\(second)")
    }

    /// Codex stage-3 S3-R2-4: a terminal/app /upgrade whose coordinated
    /// update commits must hand its captured reply to the client BEFORE the
    /// non-returning restart. Synthetic check/staging/barrier; the restart
    /// is intercepted (the process then exits 0, so this runs last and
    /// prints STAGE3_DONE from inside the intercept).
    @MainActor private func successfulUpgradeDeliversBeforeRestart(_ m: ConversationManager, lease: MemberLease,
                                                                  check: @escaping (String, Bool, String) -> Void) async {
        var fds: [Int32] = [0, 0]
        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        guard socketpair(AF_UNIX, streamType, 0, &fds) == 0 else { check("S3-R2-4: socket pair", false, "\(errno)"); return }
        let client = ClientHandle(id: 9_001, fd: fds[0])
        final class Seen { var lines: [String]? }
        let seen = Seen()
        UpgradeService.checkOverrideForTesting = {
            .available(UpgradeService.Update(version: "9.9.10", sequence: 999, url: "https://invalid.example/briglia.tar.gz", sha256: "00", size: 1))
        }
        UpgradeService.stageOverrideForTesting = { u in
            StagedUpgrade(version: u.version, sequence: u.sequence, binary: URL(fileURLWithPath: "/nonexistent/briglia"),
                          bundle: URL(fileURLWithPath: "/nonexistent/bundle"), tempDirectory: nil)
        }
        UpgradeCoordinator.runOverrideForTesting = { staged, afterCommit in
            let record = UpgradeBarrier.Record(id: "s3r24", state: .committed, targetVersion: staged.version, targetSequence: staged.sequence,
                                               openedAt: Date(), coordinator: .init(lease: lease.uuid, pid: getpid(), processStartTime: ProcessIdentity.selfStartTime),
                                               participants: nil, committedBinarySHA256: nil, reason: nil)
            await afterCommit(record)
            return .committed(version: staged.version, barrierId: record.id)
        }
        UpgradeService.restartInterceptForTesting = {
            let terminal = (seen.lines ?? []).joined(separator: "\n")
            check("S3-R2-4: a terminal /upgrade whose update commits gets its whole reply (acknowledgement through \"installed — restarting now\") before the restart",
                  seen.lines != nil && terminal.contains("Checking for an update") && terminal.contains("9.9.10 installed — restarting now"), terminal)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
            let n = read(fds[1], &buffer, buffer.count)
            let wire = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
            check("S3-R2-4: the app socket's command_result is written before the restart",
                  wire.contains("\"command_result\"") && wire.contains("restarting now"), wire.isEmpty ? "nothing on the socket" : String(wire.prefix(300)))
            print("STAGE3_DONE")
        }
        await m.handleTerminalCommand("/upgrade", deliver: { lines in
            seen.lines = lines
            client.send(["type": "command_result", "handled": lines != nil, "lines": lines ?? []])
        }, drainBeforeExit: { client.waitForPendingWrites(timeout: 2) })
        // Only reached when the restart did not happen.
        UpgradeService.restartInterceptForTesting = nil
        check("S3-R2-4: the committed update reached the restart", false, (seen.lines ?? []).joined(separator: " | "))
    }
}
