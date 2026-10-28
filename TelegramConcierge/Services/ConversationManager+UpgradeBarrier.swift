import Foundation

/// Counts startup work that reads the bundle or converges private runtimes
/// (MULTI_ASSISTANT_PLAN §6.2): an assistant is not ready to park while any
/// of it runs.
@MainActor
enum UpgradeReadiness {
    static var convergence = 0

    static func tracking(_ body: () async -> Void) async {
        convergence += 1
        defer { convergence -= 1 }
        await body()
    }
}

/// The assistant side of the upgrade barrier (§6.2–§6.4): a monitor task,
/// independent of the poll loop, watches `barrier.json`; at a restart-ready
/// point the assistant pauses admission (reversibly; never `stopPolling()`),
/// re-checks, and acks `parked`; on commit it restarts in place (same PID);
/// on cancel it resumes; a stuck barrier keeps it paused.
extension ConversationManager {
    /// nil = ready to park (§6.2). `initiating`: this process runs the
    /// `/upgrade` that opened the barrier (its handler is not a turn, and its
    /// own poll tick is the handler itself).
    func upgradeBusyReason(initiating: Bool) async -> String? {
        if activeRunId != nil || activeProcessingTask != nil || isTurnActive { return "a reply in progress" }
        if await BackgroundProcessRegistry.shared.runningBackgroundJobCount() > 0 { return "a background command" }
        if !(await SubagentBackgroundRegistry.shared.activeRunIds()).isEmpty { return "a background agent" }
        if !watcherChecksInFlight.isEmpty || !triageRunsInFlight.isEmpty { return "a watcher check" }
        if !maintenanceActivities.isEmpty || archiveRecoveryTask != nil { return "memory maintenance" }
        if backgroundPruneEngaged && backgroundPruneBlocksExit { return "a background prune" }
        if UpgradeReadiness.convergence > 0 { return "startup setup" }
        if browserSettingsMutation || isRestoringMind || subscriptionLoginTask != nil
            || botSwitchCutoverInProgress { return "a settings change" }
        // Commands already inside the handler (terminal, app socket, Telegram);
        // the initiating /upgrade handler is itself one of them.
        if browserSettingsCommandIngress > (initiating && MemberEntry.isCoordinator ? 1 : 0) { return "a command" }
        if !parkedOutbound.isEmpty || parkedOutbound.isFlushing { return "a message waiting to be sent" }
        if stalledConfirmUpdateId != nil { return "storage problems" }
        if !initiating && (browserSettingsPollIngress > 0 || browserSettingsAppIngress > 0) { return "receiving a message" }
        return nil
    }

    /// Stop taking in new work from every source (§6.4): the poll loop idles
    /// at its top (no getUpdates in flight, the last batch processed and
    /// confirmed), app/terminal input and email arrivals are refused or kept
    /// for redelivery. The polling preference is untouched.
    func pauseAdmission() { admissionPaused = true }
    func resumeAdmission() { admissionPaused = false }

    static let updatingRefusal = "Briglia is updating — try again in a minute."

    func startUpgradeMonitor(poll: TimeInterval = 2) {
        guard CoordinationMode.active, let lease = MemberEntry.current, lease.sidecar.role == "assistant",
              upgradeMonitorTask == nil else { return }
        upgradeMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                guard let self else { return }
                await self.upgradeMonitorTick(lease: lease)
            }
        }
    }

    func upgradeMonitorTick(lease: MemberLease, paths: UpgradeBarrier.Paths = .live) async {
        guard let barrier = UpgradeBarrier.current(paths), barrier.isActive else {
            if upgradeParkedFor != nil { upgradeParkedFor = nil; resumeAdmission() }
            return
        }
        // A dead coordinator (open/committed and `upgrade.lock` free): the
        // first assistant to get the lock owns recovery or closure (§6.5).
        if !MemberEntry.isCoordinator, barrier.state == .open || barrier.state == .committed,
           case .acquired(let lock) = ProfileFileLock.take(paths.lock) {
            defer { lock.release() }
            if let again = UpgradeBarrier.current(paths), again.id == barrier.id {
                if again.state == .open {
                    let outcome = UpgradeJournal.recover(again, allowStuck: false, paths: paths)
                    print("[upgrade] recovered an interrupted update: \(outcome)")
                    return
                }
                if again.state == .committed, UpgradeCoordinator.closeIfPossible(.init(paths: paths), holdingLock: true) {
                    return
                }
            }
        }
        switch barrier.state {
        case .open:
            if upgradeParkedFor == barrier.id {
                // Re-evaluated every tick: `parked` must stay true, not cached
                // (Codex stage-2 R2). Admission stays closed either way.
                if let reason = await upgradeBusyReason(initiating: true) {
                    ackUpgrade(barrier, lease: lease, state: .busy, reason: reason, paths: paths)
                } else {
                    ackUpgrade(barrier, lease: lease, state: .parked, reason: nil, paths: paths)
                }
                return
            }
            let initiating = MemberEntry.isCoordinator
            // Before pausing, a poll tick in progress is normal (the loop is
            // always inside one): only work counts. Ingress is checked after
            // the pause, once the current tick drained.
            if let reason = await upgradeBusyReason(initiating: true) {
                ackUpgrade(barrier, lease: lease, state: .busy, reason: reason, paths: paths)
                return
            }
            pauseAdmission()
            if !initiating {
                // A tick already inside a channel fetch finishes first (its
                // batch is processed normally — that is work, so re-check).
                let deadline = ProcessInfo.processInfo.systemUptime + 35
                while (browserSettingsPollIngress > 0 || browserSettingsAppIngress > 0),
                      ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            if let reason = await upgradeBusyReason(initiating: initiating) {
                resumeAdmission()
                ackUpgrade(barrier, lease: lease, state: .busy, reason: reason, paths: paths)
                return
            }
            upgradeParkedFor = barrier.id
            ackUpgrade(barrier, lease: lease, state: .parked, reason: nil, paths: paths)
            print("[upgrade] parked for the update to \(barrier.targetVersion)")
        case .committed:
            // The initiating /upgrade execs itself after confirming its own
            // update; followers restart here (same PID), confirming nothing.
            guard !MemberEntry.isCoordinator, upgradeParkedFor == barrier.id
                    || (barrier.participants?.contains { $0.lease == lease.uuid } ?? false) else { return }
            // Exec only into the committed pair (Codex stage-2 R1 Q1): a disk
            // that no longer matches the commit keeps this assistant parked.
            guard UpgradeBarrier.committedPairOnDisk(barrier, paths: paths) else {
                if upgradeParkedFor == nil { upgradeParkedFor = barrier.id; pauseAdmission() }
                print("[upgrade] the installed files do not match the committed update; staying paused")
                return
            }
            UpgradeService.writeRestartMarker(version: barrier.targetVersion, kind: .upgrade,
                                              barrierId: barrier.id, oldLease: lease.uuid)
            saveConversation()
            await telegramService.persistOffsetNow()
            print("[upgrade] restarting into \(barrier.targetVersion)")
            UpgradeService.restartNow()
        case .stuck:
            if upgradeParkedFor == nil {
                upgradeParkedFor = barrier.id
                pauseAdmission()
                print("[upgrade] \(UpgradeBarrier.stuckMessage)")
            }
        default:
            break
        }
    }

    private func ackUpgrade(_ barrier: UpgradeBarrier.Record, lease: MemberLease, state: UpgradeBarrier.AckState,
                            reason: String?, paths: UpgradeBarrier.Paths) {
        UpgradeBarrier.writeAck(.init(barrierId: barrier.id, incarnation: lease.sidecar.incarnation, state: state,
                                      reason: reason, releaseSequence: ReleaseSequence.compiled),
                                lease: lease.uuid, paths)
    }

    /// Startup after an upgrade restart: ack `restarted` under the OLD lease
    /// uuid (the closure predicate keys on it), then try to close.
    static func acknowledgeUpgradeRestart(barrierId: String, oldLease: String, paths: UpgradeBarrier.Paths = .live) {
        guard let lease = MemberEntry.current else { return }
        UpgradeBarrier.writeAck(.init(barrierId: barrierId, incarnation: lease.sidecar.incarnation, state: .restarted,
                                      reason: nil, releaseSequence: ReleaseSequence.compiled),
                                lease: oldLease, paths)
        UpgradeCoordinator.closeIfPossible(.init(paths: paths), holdingLock: false)
    }
}
