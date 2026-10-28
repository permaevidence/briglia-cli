import ArgumentParser
import Foundation

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
        print("STAGE3_DONE")
    }
}
