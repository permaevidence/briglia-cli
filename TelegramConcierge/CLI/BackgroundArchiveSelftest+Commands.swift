import Foundation

/// Plan §13 test 14 (lifecycle commands, exits, /stop) and the pure units.
extension BackgroundArchiveHarness {

    func commandSection() async {
        // While the job runs: every replacing or exiting command refuses.
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        _ = await startBackgroundJob(manager)
        let restart = await manager._baCommand("/restart")
        check("BK1 /restart during the job refuses (no wait)", restart.contains("Memory archiving is in flight — send /restart again"), restart)
        let upgrade = await manager._baCommand("/upgrade")
        check("BK1 /upgrade during the job refuses before any check", upgrade.contains("Memory archiving is in flight — send /upgrade again"), upgrade)
        let export = await manager._baCommand("/exportmind")
        check("BK1 /exportmind during the job refuses", export.contains("Memory maintenance is in flight"), export)
        let wipe = await manager._baCommand("/deleteuserdata CONFIRM")
        check("BK1 /deleteuserdata during the job refuses", wipe.contains("Memory maintenance is in flight"), wipe)
        let browser = await manager.beginBrowserSettingsMutation()
        if browser { manager.endBrowserSettingsMutation() }
        check("BK1 browser settings refuse during the job", !browser)
        let prune = await manager._baCommand("/prune")
        check("BK1 /prune refuses during the job", prune.contains("busy"), prune)
        check("BK1 exitPending stays clear after refusals", !manager._baExitPending)

        // /stop during the job: answered at once; the job keeps running.
        server.script([MidturnHarness.chatTools([(id: "ba-hold", name: "bash", args: ["command": "sleep 30"])]),
                       MidturnHarness.chatText("after stop")])
        manager._testStartTurn(for: Message(role: .user, content: "long work during the archive"))
        _ = await waitUntil(timeout: 10) { manager._testIsActive }
        let stopStart = Date()
        await manager._svStop(notify: nil)
        _ = await manager._testAwaitIdle(timeout: 20)
        check("BK2 /stop during a background archive returns promptly and never waits for the archive",
              Date().timeIntervalSince(stopStart) < 8 && manager._baJobOutcome == "running", "\(Date().timeIntervalSince(stopStart))s")
        router.gate.release()
        let finished = await waitForJob(manager, "succeeded")
        check("BK2 the archive finished after the /stop and commits at the next turn", finished)
        let batch = manager._baJobBatchIds
        await turn(manager, "after the stop", reply: "ok")
        check("BK2 committed", containsNone(manager, batch))

        await gapSection()
        await exitPendingSection()
    }

    /// The finished-not-committed gap: wipe and import may run; the stale
    /// job is discarded (pin and leases released); the imported state then
    /// commits by coverage.
    private func gapSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        _ = await startBackgroundJob(manager, hold: [])
        _ = await waitForJob(manager, "succeeded")
        let batch = manager._baJobBatchIds
        let generation = manager._baGeneration
        // Mind import's in-process step (stage, quiesce, reload).
        let began = manager.beginMindRestore()
        await manager.reloadAfterMindRestore()
        manager.endMindRestore()
        let leases = await manager._testArchiveService._testLeaseCount
        check("BK3 import in the gap: the stale job is discarded and its leases released",
              began && manager._baJobOutcome == nil && manager._baGeneration > generation && leases == 0, "leases \(leases)")
        await turn(manager, "after import", reply: "ok")
        check("BK3 the imported finished-not-committed state commits by coverage at the next turn", containsNone(manager, batch))

        let channel2 = SVRecordingChannel(kind: .telegram)
        let manager2 = await freshManager(channel: channel2, history: archiveSizedHistory())
        _ = await startBackgroundJob(manager2, hold: [])
        _ = await waitForJob(manager2, "succeeded")
        _ = await MaintenanceAlertCenter.shared.reportFailure(.archiveCommit, error: "an earlier commit failure", deterministic: false)
        let wipe = await manager2._baCommand("/deleteuserdata CONFIRM")
        check("BK4 /deleteuserdata in the gap runs and discards the job",
              wipe.contains("All user data deleted") && manager2._baJobOutcome == nil && manager2._testMessages.isEmpty, wipe)
        let reopened = await MaintenanceAlertCenter.shared.reportSuccess(.archiveCommit)
        check("BK4 the replaced history's commit episode is discarded silently (no recovery message)",
              !reopened && !channel2.delivered.contains { $0.hasPrefix("✅ Recovered: removing archived messages") }, "\(channel2.delivered)")
    }

    /// Every non-exiting /upgrade path resets exitPending; a later archive
    /// then starts.
    private func exitPendingSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        let upgrade = await manager._baCommand("/upgrade")
        check("BK5 /upgrade whose check fails returns without exec", upgrade.contains("Update check failed"), upgrade)
        check("BK5 ...and resets exitPending", !manager._baExitPending)
        let started = await startBackgroundJob(manager, hold: [])
        check("BK5 a later archive starts", started)
        router.gate.release()
    }

    // MARK: Units

    func unitSection() async {
        let sanitize: (Message) -> Message = { ConversationArchiveService.sanitizedForArchive($0) }
        let stub: (MessageKind, String) -> String? = { ConversationManager.archivedStub(kind: $0, content: $1) }
        let ref = try! PruneArchiveReference(id: UUID(), basename: "2026-10-06_120000Z_" + String(repeating: "a", count: 32) + ".txt")
        var start = Message(role: .assistant, content: "answer")
        start.toolInteractions = [toolRound(id: "u1", result: "R")]
        start.finalReasoning = .string("thinking")
        // Pruning: interactions → compact log, reasoning dropped, a new ref,
        // a summary set.
        var pruned = start
        pruned.toolInteractions = []
        pruned.compactToolLog = "[compact]"
        pruned.finalReasoning = nil
        pruned.pruneArchiveReferences = [ref]
        pruned.prunedContextSummary = "summary"
        pruned.measuredTokens = 12
        check("BU1 baseline A: pruning's own transformations are allowed",
              ArchiveCommitCheck.baselineADelta(start: start, live: pruned, sanitize: sanitize, stub: stub) == nil)
        var summaryNoRef = start
        summaryNoRef.prunedContextSummary = "summary"
        check("BU2 baseline A: a summary set without a new snapshot is unexplained",
              ArchiveCommitCheck.baselineADelta(start: start, live: summaryNoRef, sanitize: sanitize, stub: stub) != nil)
        var changedResult = start
        changedResult.toolInteractions[0].results[0].content = "R2"
        check("BU3 baseline A: a changed tool result (a sanitize-dropped field) is unexplained",
              ArchiveCommitCheck.baselineADelta(start: start, live: changedResult, sanitize: sanitize, stub: stub) != nil)
        var lostRef = pruned
        lostRef.pruneArchiveReferences = []
        check("BU4 baseline A: a lost reference is unexplained",
              ArchiveCommitCheck.baselineADelta(start: pruned, live: lostRef, sanitize: sanitize, stub: stub) != nil)
        let email = Message(role: .user, content: "[EMAIL ARRIVED]\nfrom: a@b.c\nsubject: Hi\n\nbody", kind: .emailArrived)
        var stubbed = email
        stubbed.content = stub(.emailArrived, email.content) ?? "?"
        check("BU5 the deterministic stub of a compressible message is allowed (both baselines)",
              ArchiveCommitCheck.baselineADelta(start: email, live: stubbed, sanitize: sanitize, stub: stub) == nil
                && ArchiveCommitCheck.baselineBDelta(raw: sanitize(email), live: stubbed, sanitize: sanitize, stub: stub) == nil)
        var userEdit = Message(role: .user, content: "typed")
        let typed = userEdit
        userEdit.content = "typed (edited)"
        check("BU6 a typed user message never accepts a content change",
              ArchiveCommitCheck.baselineBDelta(raw: sanitize(typed), live: userEdit, sanitize: sanitize, stub: stub) != nil)
        var rawWithReceipt = sanitize(start)
        rawWithReceipt.pruneArchiveReferences = [ref]
        check("BU7 baseline B: a reference present only on the archived copy is allowed",
              ArchiveCommitCheck.baselineBDelta(raw: rawWithReceipt, live: start, sanitize: sanitize, stub: stub) == nil)

        // Leases: reference counting and deferred deletion.
        await resetState()
        let archive = ConversationArchiveService()
        let id = UUID()
        let lease = await archive.registerLease(chunkIds: [id])
        await archive.retainLease(lease)
        await archive.releaseLease(lease)
        check("BU8 a lease survives while any owner holds it", await archive._testLeaseReferences(lease) == 1)
        let next = await archive.registerLease(chunkIds: [id])
        await archive.releaseLease(lease)
        check("BU8 registering the new view before releasing the old keeps exactly one", await archive._testLeaseCount == 1)
        await archive.releaseLease(next)
        await archive.releaseLease(next)
        check("BU8 an over-release is harmless", await archive._testLeaseCount == 0)
    }
}
