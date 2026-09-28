import Foundation

/// Real-manager bash rows: the production tool loop, the scripted loopback
/// provider (Chat Completions and Responses), real background bash jobs.
extension MidturnHarness {

    func roundLoopSection() async throws {
        try await roundBashDelivered(responses: false)
        let restore = try useResponses()
        do { try await roundBashDelivered(responses: true) }
        restore()
        try await roundIdleUnchanged()
        try await roundKillSwitch()
        try await roundTwoBoundaries()
        try await roundWithdrawalInFlight()
        try await roundReceiptsSkipped()
    }

    /// T8d (Codex check 3): between the acknowledgement and the registry
    /// withdrawal, an idle drain finds the item still queued — and skips it.
    private func roundWithdrawalInFlight() async throws {
        let manager = await roundFresh()
        var release = false
        ConversationManager.roundWithdrawalHoldForTesting = { _ = await self.waitUntil(timeout: 20) { release } }
        server.script([
            Self.chatTools([Self.bgCall("t8d-bg", "sleep 0.1; echo T8D_BG"), Self.fgCall("t8d-fg", "sleep 1.2")]),
            Self.chatText("t8d final"), Self.chatText("t8d unwanted follow-up"),
        ])
        manager._testStartTurn(for: user("T8d withdrawal in flight"))
        _ = await manager._testAwaitIdle(timeout: 30)
        let acknowledging = manager._testRoundReservations.values.contains { $0.state == .acknowledging }
        let queued = await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery().contains { $0.completion.stdoutTail.contains("T8D_BG") }
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 10)
        check("T8d withdrawal in flight: the idle drain skips the acknowledged-but-queued item",
              acknowledging && queued && !manager._testMessages.contains { $0.kind == .bashComplete && $0.content.contains("T8D_BG") }
                && server.completeRequests.count == 2, "acknowledging \(acknowledging) queued \(queued) requests \(server.completeRequests.count)")
        release = true
        check("T8d' after the withdrawal the reservation is gone", await roundSettled(manager))
        ConversationManager.roundWithdrawalHoldForTesting = nil
    }

    /// T1: a background bash job that finishes during round k is appended to
    /// round k's last result, rides request k+1, is acknowledged after the
    /// saved history carries it, and never starts a follow-up turn.
    private func roundBashDelivered(responses: Bool) async throws {
        let tag = responses ? "T1r" : "T1"
        let manager = await roundFresh()
        server.script([
            tools([Self.bgCall("t1-bg", "sleep 0.1; echo T1_BG_DONE"), Self.fgCall("t1-fg", "sleep 1.2; echo fg-done")], responses: responses),
            text("final after the background result", responses: responses),
        ])
        manager._testStartTurn(for: user("\(tag) run a background job and keep working"))
        _ = await manager._testAwaitIdle(timeout: 30)
        let carrier = carriers(manager)
        let id = carrier.first?.deliveredCompletions.first
        check("\(tag)a exactly one saved result carries the background result, on the round's LAST result",
              carrier.count == 1 && carrier.first?.toolCallId == "t1-fg" && carrier.first?.deliveredCompletions.count == 1,
              "\(carrier.map(\.toolCallId))")
        let content = carrier.first?.content ?? ""
        check("\(tag)b content = foreground output, then the framed section (body, completion_id, footer)",
              content.hasPrefix(carrier.first.map { RoundDelivery.foregroundContent(of: $0) } ?? "#")
                && content.contains("fg-done") && content.contains("[BACKGROUND BASH COMPLETE]") && content.contains("T1_BG_DONE")
                && content.contains("completion_id: \(id?.uuidString ?? "?")") && content.hasSuffix(RoundDelivery.frameFooter))
        let second = requestBodies().dropFirst().first ?? ""
        check("\(tag)c the next request carries it as tool output", second.contains(Self.frameProbe) && second.contains("T1_BG_DONE"))
        let settled = await roundSettled(manager)
        check("\(tag)d acknowledged after the save: registry withdrawn, record retired, no reservation", settled)
        await manager._testIdleDrains()
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 10)
        check("\(tag)e no idle copy and no follow-up turn",
              !manager._testMessages.contains { $0.kind == .bashComplete } && server.completeRequests.count == 2,
              "requests \(server.completeRequests.count)")
        check("\(tag)f the bookkeeping field reached conversation.json", savedConversationText().contains("deliveredCompletions"))
    }

    /// T3: an ordinary turn and idle delivery are unchanged.
    private func roundIdleUnchanged() async throws {
        let manager = await roundFresh()
        server.script([Self.chatTools([Self.fgCall("t3-fg", "echo t3")]), Self.chatText("t3 done")])
        manager._testStartTurn(for: user("T3 ordinary turn"))
        _ = await manager._testAwaitIdle(timeout: 20)
        check("T3a an ordinary turn: no section on the wire, no bookkeeping in history",
              !requestBodies().contains { $0.contains(Self.frameProbe) } && carriers(manager).isEmpty
                && !savedConversationText().contains("deliveredCompletions"))
        // A job that finishes while idle is delivered by today's path.
        server.clear()
        server.script([Self.chatTools([Self.bgCall("t3-bg", "sleep 0.1; echo T3_IDLE")]), Self.chatText("launched"), Self.chatText("saw it")])
        manager._testStartTurn(for: user("T3 launch and stop"))
        _ = await manager._testAwaitIdle(timeout: 20)
        _ = await waitUntil(timeout: 10) { !(await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery().isEmpty) }
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 20)
        let notices = manager._testMessages.filter { $0.kind == .bashComplete && $0.content.contains("T3_IDLE") }
        check("T3b idle: a .bashComplete message wakes one turn (unchanged)",
              notices.count == 1 && server.completeRequests.count == 3 && carriers(manager).isEmpty)
    }

    /// T21: kill switch off = exact idle-only behaviour.
    private func roundKillSwitch() async throws {
        let manager = await roundFresh()
        RoundDelivery.overrideForTesting = false
        defer { RoundDelivery.overrideForTesting = nil }
        server.script([
            Self.chatTools([Self.bgCall("t21-bg", "sleep 0.1; echo T21_BG"), Self.fgCall("t21-fg", "sleep 1.2")]),
            Self.chatText("t21 final"), Self.chatText("t21 saw the notice"),
        ])
        manager._testStartTurn(for: user("T21 switch off"))
        _ = await manager._testAwaitIdle(timeout: 30)
        check("T21a switch off: nothing appended mid-turn", carriers(manager).isEmpty && !requestBodies().contains { $0.contains(Self.frameProbe) })
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 20)
        check("T21b switch off: delivered at idle as today (one notice, one wake)",
              manager._testMessages.filter { $0.kind == .bashComplete && $0.content.contains("T21_BG") }.count == 1
                && server.completeRequests.count == 3)
    }

    /// T8: a later boundary of the same turn skips an item already appended
    /// and still awaiting acknowledgement (the reservation, not the registry).
    private func roundTwoBoundaries() async throws {
        let manager = await roundFresh()
        server.script([
            Self.chatTools([Self.bgCall("t8-bg", "sleep 0.1; echo T8_ONCE"), Self.fgCall("t8-fg1", "sleep 1.2")]),
            Self.chatTools([Self.fgCall("t8-fg2", "sleep 0.2")]),
            Self.chatTools([Self.fgCall("t8-fg3", "sleep 0.2")]),
            Self.chatText("t8 final"),
        ])
        var stillQueued = false
        var boundaries = 0
        ConversationManager.roundDeliveryInterleaveForTesting = { stage in
            guard stage == "after-reads" else { return }
            boundaries += 1
            if boundaries == 2 {
                stillQueued = await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery()
                    .contains { $0.completion.stdoutTail.contains("T8_ONCE") }
            }
        }
        manager._testStartTurn(for: user("T8 two boundaries"))
        _ = await manager._testAwaitIdle(timeout: 30)
        ConversationManager.roundDeliveryInterleaveForTesting = nil
        let all = results(manager).map(\.content).joined()
        check("T8a at the second boundary the item was still queued (not yet acknowledged)", stillQueued)
        check("T8b it was appended exactly once across the turn's boundaries",
              occurrences(RoundDelivery.frameHeader, in: all) == 1 && carriers(manager).count == 1,
              "frames \(occurrences(RoundDelivery.frameHeader, in: all)), carriers \(carriers(manager).count)")
        check("T8c acknowledged after the turn's save", await roundSettled(manager))
    }

    /// T9: jobs the model observed with bash_manage (receipt, this round or
    /// an earlier round of the turn) are never appended.
    private func roundReceiptsSkipped() async throws {
        let manager = await roundFresh()
        // Round 1 lasts ~0.4 s (foreground sleep), so the rest of the script
        // is queued before the second request; the job outlives round 1.
        server.script([Self.chatTools([Self.bgCall("t9-bg", "sleep 1.2; echo T9_OBSERVED"), Self.fgCall("t9-hold", "sleep 0.4")])])
        manager._testStartTurn(for: user("T9 launch then wait for it"))
        var found: BackgroundProcessRegistry.RunningJob?
        _ = await waitUntil(timeout: 15) {
            found = await BackgroundProcessRegistry.shared.runningMainOwnedJobs().first { $0.command.contains("T9_OBSERVED") }
            return found != nil
        }
        guard let job = found else { check("T9 job started", false); return }
        server.script([
            Self.chatTools([(id: "t9-wait", name: "bash_manage", args: ["mode": "wait", "handle": job.handle, "wait_seconds": 20])]),
            Self.chatTools([Self.fgCall("t9-next", "sleep 0.2")]),
            Self.chatText("t9 final"),
        ])
        _ = await manager._testAwaitIdle(timeout: 30)
        let waited = results(manager).first { $0.toolCallId == "t9-wait" }
        check("T9a the wait observed the settlement (receipt bound)", waited?.outcomeBinding?.kind == .receiptObserved)
        check("T9b the observed completion was never appended (same round nor a later one)",
              carriers(manager).isEmpty && !results(manager).contains { $0.content.contains(Self.frameProbe) })
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 10)
        check("T9c nor delivered at idle; the record settled",
              !manager._testMessages.contains { $0.kind == .bashComplete } && !records().contains { $0.jobId == job.jobUUID })
    }
}
