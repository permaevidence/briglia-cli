import Foundation

/// Crash recovery (T11) and startup order (T14): typed evidence in a saved
/// history or a recovered turn file settles the record without a second
/// copy; without evidence, today's idle recovery delivers it (at-least-once).
extension MidturnHarness {

    func roundCrashSection() async throws {
        try await roundCrashAfterDurableRound()
        try await roundCrashBeforeDurableWrite()
        try await roundCrashWithPlainSalvage()
        try await roundStartupOrderCrafted()
    }

    /// Run one turn that appends a background result, with `faults` applied
    /// right after the append. Returns the completion id.
    private func crashTurn(_ tag: String, faults: @escaping @MainActor () -> Void) async -> UUID? {
        let manager = await roundFresh()
        onceAt("after-append") { faults() }
        server.script([
            Self.chatTools([Self.bgCall("\(tag)-bg", "sleep 0.1; echo \(tag)_BG"), Self.fgCall("\(tag)-fg", "sleep 1.2")]),
            Self.chatText("\(tag) final"),
        ])
        manager._testStartTurn(for: user("\(tag) crash scenario"))
        _ = await manager._testAwaitIdle(timeout: 30)
        return manager._testRoundReservations.keys.first ?? carriers(manager).first?.deliveredCompletions.first
    }

    /// T11a: the saved history carries the round, but the process "dies"
    /// before the record is marked: startup settles it from the typed
    /// evidence — delivered, nothing appended, no wake.
    private func roundCrashAfterDurableRound() async throws {
        let id = await crashTurn("T11A") {
            DetachedJobStore.faultForTesting = { label in if label == "delivered-midturn" { throw Injected() } }
        }
        DetachedJobStore.faultForTesting = nil
        let owedBefore = records().contains { $0.completion == .owed && $0.completionMessageId == id }
        let manager = await restart()
        check("T11a durable round + unmarked record → startup marks it delivered, no copy, no wake",
              owedBefore && records().isEmpty && !manager._testMessages.contains { $0.kind == .bashComplete }
                && manager._testRecoveredWakeTrigger == nil, "owed before \(owedBefore), records \(records().count)")
    }

    /// T11b: no durable write carried the round before the "crash": startup
    /// delivers the notice at idle and wakes (today's path).
    private func roundCrashBeforeDurableWrite() async throws {
        _ = await crashTurn("T11B") {
            ConversationManager.plainSalvageFaultForTesting = { throw Injected() }
            ConversationManager.historyWriteFaultForTesting = { throw Injected() }
        }
        roundResetSeams()
        try? FileManager.default.removeItem(at: StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json"))
        let manager = await restart()
        let notice = manager._testMessages.filter { $0.kind == .bashComplete && $0.content.contains("T11B_BG") }
        check("T11b no durable round → recovered at startup as today (one notice, wake queued)",
              notice.count == 1 && manager._testRecoveredWakeTrigger != nil)
    }

    /// T11c / T14: the outcome save failed but the plain turn file holds the
    /// round: startup recovers the turn FIRST, then reconciliation finds the
    /// typed evidence — no copy.
    private func roundCrashWithPlainSalvage() async throws {
        _ = await crashTurn("T11C") { ConversationManager.historyWriteFaultForTesting = { throw Injected() } }
        roundResetSeams()
        let salvageExists = FileManager.default.fileExists(atPath: StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json").path)
        let manager = await restart()
        check("T11c turn file recovered, then the record settled from its typed evidence (no copy, no wake)",
              salvageExists && carriers(manager).count == 1 && records().isEmpty
                && !manager._testMessages.contains { $0.kind == .bashComplete } && manager._testRecoveredWakeTrigger == nil,
              "salvage \(salvageExists), carriers \(carriers(manager).count), records \(records().count)")
    }

    /// T14: crafted turn file + foreign owed record: the recovery precedes
    /// reconciliation in `init`.
    private func roundStartupOrderCrafted() async throws {
        let trigger = user("T14 trigger")
        _ = await roundFresh(history: [trigger])
        let completionId = UUID()
        var round = Self.round(callId: "t14", content: "fg", binding: nil)
        round.results[0].deliveredCompletions = [completionId]
        try PrivateStorage.writeAtomically(try JSONEncoder().encode([round]),
                                           to: StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json"))
        let base = Self.record(anchor: trigger.id)
        let record = DetachedJobRecord(jobId: base.jobId, instanceId: UUID(), turnRunId: nil, toolCallId: "t14",
                                       callFingerprint: nil, handle: "bash_14", command: "true", description: nil, workdir: nil,
                                       startedAt: Date(), launch: .background, completionMessageId: completionId,
                                       historyAnchorMessageId: trigger.id)
        try DetachedJobStore.create(record)
        let manager = await restart()
        check("T14 startup: turn recovery before job reconciliation → delivered from the recovered round",
              records().isEmpty && carriers(manager).count == 1 && !manager._testMessages.contains { $0.kind == .bashComplete })
    }
}
