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

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev"), let lease = MemberEntry.current else {
            print("CHECK 0 needs a development build and a member lease"); return
        }
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("CHECK \(ok ? 1 : 0) \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        }
        let m = ConversationManager()
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
