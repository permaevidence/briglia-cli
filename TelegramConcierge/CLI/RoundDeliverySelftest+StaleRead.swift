import Foundation

/// Stale queue readers (Codex round-delivery review R1): a drain that read
/// the registry queue BEFORE a mid-turn delivery's withdrawal and resumes
/// AFTER the reservation is gone must still never append that completion
/// again — in the active-turn drain or either idle drain, for bash and for
/// subagents, and when the delivered carrier has moved into a compaction
/// snapshot. No duplicate tool result, no synthetic idle message, no extra
/// wake, no second charge.
extension MidturnHarness {

    func roundStaleReaderSection() async throws {
        try await roundStaleBashActive()
        try await roundStaleSubagentActive()
        try await roundStaleBashIdle()
        try await roundStaleSubagentIdle()
        try await roundStaleCompactedCarrier()
    }

    /// First turn: a background bash job arrives mid-turn and is
    /// acknowledged while the registry withdrawal is held. Returns the
    /// manager, the completion id, and the release switch.
    private func staleFirstBashTurn(_ tag: String) async -> (ConversationManager, UUID?, () -> Void) {
        let manager = await roundFresh()
        var release = false
        ConversationManager.roundWithdrawalHoldForTesting = { _ = await self.waitUntil(timeout: 25) { release } }
        server.script([
            Self.chatTools([Self.bgCall("\(tag)-bg", "sleep 0.1; echo \(tag)_STALE_READ"), Self.fgCall("\(tag)-fg", "sleep 1.2")]),
            Self.chatText("\(tag) first turn done"),
        ])
        manager._testStartTurn(for: user("\(tag) first turn"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let id = carriers(manager).first?.deliveredCompletions.first
        return (manager, id, { release = true })
    }

    /// First turn: an injected (unrecorded, costed) subagent completion
    /// arrives mid-turn and is acknowledged while the withdrawal is held.
    private func staleFirstSubagentTurn(_ tag: String) async -> (ConversationManager, UUID, () -> Void) {
        let manager = await roundFresh()
        clearModelSpend()
        var release = false
        ConversationManager.roundWithdrawalHoldForTesting = { _ = await self.waitUntil(timeout: 25) { release } }
        let completion = Self.injectedCompletion("\(tag.lowercased())_sub", final: "\(tag)_SUB_FINAL", spend: 0.25)
        onceAt("bash-read") { await SubagentBackgroundRegistry.shared._testEnqueueCompletion(completion) }
        server.script([
            Self.chatTools([Self.fgCall("\(tag)-fg", "echo first")]),
            Self.chatText("\(tag) first turn done"),
        ])
        manager._testStartTurn(for: user("\(tag) first turn"))
        _ = await manager._testAwaitIdle(timeout: 20)
        return (manager, completion.messageId, { release = true })
    }

    /// Release the held withdrawal from inside a drain (after its queue
    /// read) and wait until the reservation is gone, so the drain resumes
    /// with a stale snapshot and no reservation.
    private func releaseAndWaitWithdrawn(_ manager: ConversationManager, _ id: UUID?, _ release: () -> Void) async -> Bool {
        release()
        return await waitUntil(timeout: 10) { id.map { manager._testRoundReservations[$0] == nil } ?? false }
    }

    /// SR1 (Codex CX1–CX3, verbatim scenario): bash, active-turn drain, the
    /// withdrawal finishes at the `subagent-read` suspension (after the
    /// bash snapshot, before eligibility).
    private func roundStaleBashActive() async throws {
        let (manager, id, release) = await staleFirstBashTurn("SR1")
        check("SR1a first turn safely carries the completion and withdrawal is pending",
              id != nil && manager._testRoundReservations[id!] != nil)
        var withdrawn = false
        onceAt("subagent-read") { withdrawn = await self.releaseAndWaitWithdrawn(manager, id, release) }
        server.script([
            Self.chatTools([Self.fgCall("sr1-second", "echo next-turn")]),
            Self.chatText("SR1 second turn done"),
        ])
        let before = server.completeRequests.count
        manager._testStartTurn(for: user("SR1 second turn"))
        _ = await manager._testAwaitIdle(timeout: 25)
        let matching = carriers(manager).filter { $0.deliveredCompletions.contains(id ?? UUID()) }
        check("SR1b withdrawal finished after the drain read and before its eligibility check", withdrawn)
        check("SR1c already delivered completion is not delivered again from a stale read", matching.count == 1,
              "same completion appears in \(matching.count) saved tool results: \(matching.map(\.toolCallId))")
        check("SR1d no idle copy, no extra wake, settled",
              await roundSettled(manager) && !manager._testMessages.contains { $0.kind == .bashComplete }
                && server.completeRequests.count == before + 2, "requests \(server.completeRequests.count) vs \(before) + 2")
        roundResetSeams()
    }

    /// SR2: subagent, active-turn drain, withdrawal finishes after both
    /// queue reads; charged exactly once.
    private func roundStaleSubagentActive() async throws {
        let (manager, id, release) = await staleFirstSubagentTurn("SR2")
        check("SR2a first turn carries the subagent report; withdrawal pending; charged once",
              carriers(manager).contains { $0.deliveredCompletions.contains(id) } && manager._testRoundReservations[id] != nil
                && abs(modelSpendToday() - 0.25) < 0.0001, "today \(modelSpendToday())")
        var withdrawn = false
        onceAt("after-reads") { withdrawn = await self.releaseAndWaitWithdrawn(manager, id, release) }
        server.script([
            Self.chatTools([Self.fgCall("sr2-second", "echo next-turn")]),
            Self.chatText("SR2 second turn done"),
        ])
        let before = server.completeRequests.count
        manager._testStartTurn(for: user("SR2 second turn"))
        _ = await manager._testAwaitIdle(timeout: 25)
        let matching = carriers(manager).filter { $0.deliveredCompletions.contains(id) }
        check("SR2b withdrawal finished between the reads and the eligibility check", withdrawn)
        check("SR2c the subagent report is not delivered again; no second charge",
              matching.count == 1 && abs(modelSpendToday() - 0.25) < 0.0001,
              "carriers \(matching.map(\.toolCallId)) today \(modelSpendToday())")
        check("SR2d no idle copy, no extra wake, settled",
              await roundSettled(manager) && !manager._testMessages.contains { $0.kind == .subagentComplete }
                && server.completeRequests.count == before + 2, "requests \(server.completeRequests.count) vs \(before) + 2")
        clearModelSpend()
        roundResetSeams()
    }

    /// SR3: bash, idle drain, withdrawal finishes between its read and its
    /// eligibility check.
    private func roundStaleBashIdle() async throws {
        let (manager, id, release) = await staleFirstBashTurn("SR3")
        check("SR3a first turn carries the completion; withdrawal pending", id != nil && manager._testRoundReservations[id!] != nil)
        var withdrawn = false
        var fired = false
        ConversationManager.idleDrainAfterReadForTesting = { stage in
            guard stage == "idle-bash", !fired else { return }
            fired = true
            withdrawn = await self.releaseAndWaitWithdrawn(manager, id, release)
        }
        let requests = server.completeRequests.count
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 10)
        check("SR3b the idle drain read the queue, then the withdrawal finished", fired && withdrawn)
        check("SR3c no synthetic idle message, no wake, one carrier",
              !manager._testMessages.contains { $0.kind == .bashComplete } && server.completeRequests.count == requests
                && carriers(manager).filter { $0.deliveredCompletions.contains(id ?? UUID()) }.count == 1,
              "requests \(server.completeRequests.count) vs \(requests)")
        check("SR3d settled", await roundSettled(manager))
        roundResetSeams()
    }

    /// SR4: subagent, idle drain, withdrawal finishes between its read and
    /// its eligibility check; the unrecorded run is not charged again.
    private func roundStaleSubagentIdle() async throws {
        let (manager, id, release) = await staleFirstSubagentTurn("SR4")
        check("SR4a first turn carries the report; withdrawal pending", manager._testRoundReservations[id] != nil)
        var withdrawn = false
        var fired = false
        ConversationManager.idleDrainAfterReadForTesting = { stage in
            guard stage == "idle-subagent", !fired else { return }
            fired = true
            withdrawn = await self.releaseAndWaitWithdrawn(manager, id, release)
        }
        let requests = server.completeRequests.count
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 10)
        check("SR4b the idle drain read the queue, then the withdrawal finished", fired && withdrawn)
        check("SR4c no synthetic idle message, no wake, no second charge",
              !manager._testMessages.contains { $0.kind == .subagentComplete } && server.completeRequests.count == requests
                && abs(modelSpendToday() - 0.25) < 0.0001,
              "requests \(server.completeRequests.count) vs \(requests), today \(modelSpendToday())")
        check("SR4d settled", await roundSettled(manager))
        clearModelSpend()
        roundResetSeams()
    }
}
