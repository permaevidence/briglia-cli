import Foundation

/// Durability (T10), crash recovery (T11, T14), the removal gate and
/// retention (T12b), failed record settlement (Codex check 3).
extension MidturnHarness {

    struct Injected: Error {}

    func roundDurabilitySection() async throws {
        try await roundAckOnlyAfterHistorySave()
        try await roundBothWritesFail()
        try await roundRecordWriteFailureRetried()
        try await roundRemovalGate()
        try roundRetentionPin()
    }

    /// T10a: the in-progress salvage write fails (checked, recorded); the
    /// item stays reserved and unacknowledged until the saved outcome
    /// carries it — never acknowledged at append or on a salvage write.
    private func roundAckOnlyAfterHistorySave() async throws {
        let manager = await roundFresh()
        ConversationManager.plainSalvageFaultForTesting = { throw Injected() }
        var midTurn: (reserved: Bool, queued: Bool, owed: Bool, salvageFailed: Bool) = (false, false, false, false)
        var boundaries = 0
        ConversationManager.roundDeliveryInterleaveForTesting = { stage in
            guard stage == "after-reads" else { return }
            boundaries += 1
            guard boundaries == 2 else { return }
            let pending = await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery()
            midTurn = (manager._testRoundReservations.values.contains { $0.state == .reserved },
                       pending.contains { $0.completion.stdoutTail.contains("T10A_BG") },
                       self.records().contains { $0.completion == .owed },
                       !manager._testSalvageWriteFailedRuns.isEmpty)
        }
        server.script([
            Self.chatTools([Self.bgCall("t10a-bg", "sleep 0.1; echo T10A_BG"), Self.fgCall("t10a-fg", "sleep 1.2")]),
            Self.chatTools([Self.fgCall("t10a-next", "sleep 0.2")]),
            Self.chatText("t10a final"),
        ])
        manager._testStartTurn(for: user("T10a salvage fails"))
        _ = await manager._testAwaitIdle(timeout: 30)
        roundResetSeams()
        check("T10a the failed salvage write was checked and recorded for the run", midTurn.salvageFailed)
        check("T10a' mid-turn (before the outcome save) the item was still reserved, queued and owed",
              midTurn.reserved && midTurn.queued && midTurn.owed, "\(midTurn)")
        check("T10a'' acknowledged at the outcome save", await roundSettled(manager) && carriers(manager).count == 1)
    }

    /// T10b: salvage AND history writes fail: nothing is acknowledged, no
    /// idle copy while the unsaved round carries it; the next successful
    /// save acknowledges it.
    private func roundBothWritesFail() async throws {
        let manager = await roundFresh()
        onceAt("after-append") {
            ConversationManager.plainSalvageFaultForTesting = { throw Injected() }
            ConversationManager.historyWriteFaultForTesting = { throw Injected() }
        }
        server.script([
            Self.chatTools([Self.bgCall("t10b-bg", "sleep 0.1; echo T10B_BG"), Self.fgCall("t10b-fg", "sleep 1.2")]),
            Self.chatText("t10b final"),
        ])
        manager._testStartTurn(for: user("T10b every write fails"))
        _ = await manager._testAwaitIdle(timeout: 30)
        await manager._testIdleDrains()
        let held = manager._testRoundReservations.values.contains { $0.state == .reserved }
        let queued = !(await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery().isEmpty)
        check("T10b no durable write: kept reserved and queued, record owed, no idle copy",
              held && queued && records().contains { $0.completion == .owed }
                && !manager._testMessages.contains { $0.kind == .bashComplete && $0.content.contains("T10B_BG") },
              "held \(held) queued \(queued) records \(records().map(\.completion.rawValue)) reservations \(manager._testRoundReservations.count) notices \(manager._testMessages.filter { $0.kind == .bashComplete }.map { String($0.content.prefix(120)) })")
        ConversationManager.historyWriteFaultForTesting = nil
        ConversationManager.plainSalvageFaultForTesting = nil
        _ = manager._testSave()
        check("T10b' the next successful save acknowledges it", await roundSettled(manager))
        roundResetSeams()
    }

    /// Codex check 3: the crash record's `.delivered` write fails after the
    /// registry withdrawal: kept for a retry after the next save.
    private func roundRecordWriteFailureRetried() async throws {
        let manager = await roundFresh()
        DetachedJobStore.faultForTesting = { label in if label == "delivered-midturn" { throw Injected() } }
        server.script([
            Self.chatTools([Self.bgCall("t10c-bg", "sleep 0.1; echo T10C_BG"), Self.fgCall("t10c-fg", "sleep 1.2")]),
            Self.chatText("t10c final"),
        ])
        manager._testStartTurn(for: user("T10c record write fails"))
        _ = await manager._testAwaitIdle(timeout: 30)
        _ = await waitUntil(timeout: 5) { manager._testRoundReservations.isEmpty }
        check("T10c failed record write: record still owed, retry pending, no idle copy",
              records().contains { $0.completion == .owed } && !manager._testRoundRecordRetries.isEmpty
                && !manager._testMessages.contains { $0.kind == .bashComplete })
        await manager._testIdleDrains()
        check("T10c' registry withdrawn anyway (no idle notice even with the record owed)",
              !manager._testMessages.contains { $0.kind == .bashComplete } && server.completeRequests.count == 2)
        DetachedJobStore.faultForTesting = nil
        _ = manager._testSave()
        check("T10c'' the retry after the next save settles the record", records().isEmpty && manager._testRoundRecordRetries.isEmpty)
    }

    /// T12b / B8: a message carrying typed delivery evidence cannot leave
    /// history before its record is settled; unreadable records refuse.
    private func roundRemovalGate() async throws {
        let trigger = user("gate anchor")
        let completionId = UUID()
        var record = Self.record(anchor: trigger.id)
        record = DetachedJobRecord(jobId: record.jobId, instanceId: DetachedJobStore.instanceId, turnRunId: nil, toolCallId: "g",
                                   callFingerprint: nil, handle: "bash_7", command: "true", description: nil, workdir: nil,
                                   startedAt: Date(), launch: .background, completionMessageId: completionId,
                                   historyAnchorMessageId: trigger.id)
        var round = Self.round(callId: "g1", content: "fg", binding: nil)
        round.results[0].deliveredCompletions = [completionId]
        let carrier = Self.assistant("done", rounds: [round])
        let manager = await roundFresh(history: [trigger, carrier])
        try DetachedJobStore.create(record)
        try manager._testSettleBeforeRemoval([carrier])
        check("T12b removal settles the delivered record first", records().isEmpty)
        try DetachedJobStore.create(record)
        let url = DetachedJobStore.fileURL
        try Data("not json".utf8).write(to: url)
        var refused = false
        do { try manager._testSettleBeforeRemoval([carrier]) } catch { refused = true }
        check("T12b' unreadable records: a carrier of delivery evidence stays in history", refused)
        try? FileManager.default.removeItem(at: url)
    }

    /// Retention: a snapshot whose sidecar delivery names an open record's
    /// completion is pinned; once settled it is not.
    private func roundRetentionPin() throws {
        let completionId = UUID()
        let snapId = UUID()
        let dir = PruneArchiveStore.root
        try PrivateStorage.ensureDirectory(dir)
        try SettlementEvidence.ensureLegacyListInitialized()
        let base = "2026-09-28_120000Z_" + snapId.uuidString.lowercased().replacingOccurrences(of: "-", with: "") + ".txt"
        let ref = try PruneArchiveReference(id: snapId, basename: base)
        var sidecar = SettlementSidecar(snapshotId: snapId, created: Date(), turnOutcome: true, predecessors: [], entries: [])
        sidecar.deliveries = [.init(toolCallId: "p", completionIds: [completionId], view: .carried)]
        try SettlementEvidence.writeSidecar(sidecar, snapshots: dir)
        var record = Self.record()
        record = DetachedJobRecord(jobId: record.jobId, instanceId: DetachedJobStore.instanceId, turnRunId: nil, toolCallId: "p",
                                   callFingerprint: nil, handle: "bash_8", command: "true", description: nil, workdir: nil,
                                   startedAt: Date(), launch: .background, completionMessageId: completionId, historyAnchorMessageId: nil)
        try DetachedJobStore.create(record)
        let entry = PruneArchiveStore.Entry(reference: ref, created: Date(), bytes: 0)
        check("T12c retention pins a snapshot proving an open record's delivery",
              SettlementEvidence.pinnedSnapshotIds(snapshots: dir, entries: [entry]).contains(snapId))
        try? FileManager.default.removeItem(at: DetachedJobStore.fileURL)
        check("T12c' not pinned once the record is gone", !SettlementEvidence.pinnedSnapshotIds(snapshots: dir, entries: [entry]).contains(snapId))
        SettlementEvidence.removeSidecar(snapId, snapshots: dir)
    }
}
