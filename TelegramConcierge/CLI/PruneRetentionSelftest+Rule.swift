import Foundation

/// R1–R9: the three-anchor rule inside the real prune commit.
extension RetentionHarness {

    func fullAnchorContents(_ history: [Message]) -> [String] {
        history.filter(PruneSummaryRetention.isFullAnchor).map(\.content)
    }

    /// R1, R2, R3, R4, R6, R8, R9.
    func ruleSection() async throws {
        // R1: ≤ 3 → nothing; 4 → oldest; 6 → oldest 3, newest 3 byte-identical.
        var manager = await freshManager(history: anchoredHistory(2))
        try await pruneLast(manager)
        check("R1a three anchors → nothing demoted, no demotion snapshot",
              records(manager._testMessages).isEmpty && snapshotIDs().count == 1, "\(snapshotIDs().count) snapshots")
        manager = await freshManager(history: anchoredHistory(3))
        try await pruneLast(manager)
        check("R1b four anchors → the oldest is demoted",
              message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries.count == 1
              && fullAnchorContents(manager._testMessages) == ["REPLY_A1", "REPLY_A2", "REPLY_TAIL"])
        let six = anchoredHistory(5)
        manager = await freshManager(history: six)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try await pruneLast(manager)
        let kept = ["REPLY_A3", "REPLY_A4"].allSatisfy { label in
            (try? encoder.encode(message(manager._testMessages, label)!)) == (try? encoder.encode(message(six, label)!))
        }
        check("R1c six anchors → oldest three demoted; newest three in full, untouched ones byte-identical",
              records(manager._testMessages).count == 3 && kept
              && fullAnchorContents(manager._testMessages) == ["REPLY_A3", "REPLY_A4", "REPLY_TAIL"])

        // R2: an anchor with several appended summaries is demoted as one.
        var h = anchoredHistory(3)
        h[1].prunedContextSummary = "FIRST_PART_A0\n\nSECOND_PART_A0"
        manager = await freshManager(history: h)
        try await pruneLast(manager)
        let r2 = message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries ?? []
        let r2text = r2.first.map { snapshotText($0.snapshot) } ?? ""
        check("R2a several appended summaries demoted as one; the snapshot holds every part and its coverage",
              r2.count == 1 && r2text.contains("FIRST_PART_A0") && r2text.contains("SECOND_PART_A0")
              && r2text.contains("Prior pruning summary coverage: 1 Sep 2026 09:50–10:00 (UTC+02:00); files: [") && r2text.contains("A0.swift\"]"),
              String(r2text.prefix(400)))
        h = anchoredHistory(2)
        h[3].prunedContextSummary = "PART_ONE\n\nPART_TWO"
        manager = await freshManager(history: h)
        try await pruneLast(manager)
        check("R2b three anchors holding four summaries → nothing demoted (anchors are counted, not summaries)",
              records(manager._testMessages).isEmpty)

        // R3: active-turn summaries are never counted or demoted.
        h = anchoredHistory(2)
        for i in 0..<2 {
            var finished = Message(role: .assistant, content: "FINISHED_\(i)", timestamp: at(2026, 9, 15, 10 + i, 0))
            finished.activeTurnCompaction = carried("unpruned active summary \(i)")
            h.insert(finished, at: 2)
        }
        manager = await freshManager(history: h)
        try await pruneLast(manager)
        check("R3a finished turns' unpruned active-turn summaries are not anchors: three anchors → nothing demoted",
              records(manager._testMessages).isEmpty
              && manager._testMessages.filter { $0.activeTurnCompaction != nil }.count == 2)
        h.insert(contentsOf: [user("U_X", at: at(2026, 8, 31, 9, 0)), anchor("X", at: at(2026, 8, 31, 10, 0))], at: 0)
        manager = await freshManager(history: h)
        try await pruneLast(manager)
        check("R3b with four summary anchors only the oldest summary anchor is demoted; active-turn summaries untouched",
              records(manager._testMessages).count == 1 && message(manager._testMessages, "REPLY_X")?.demotedPruneSummaries.count == 1
              && manager._testMessages.filter { $0.activeTurnCompaction != nil }.count == 2)

        // R4: /prune nosnapshot → no demotion, coverage still recorded.
        manager = await freshManager(history: anchoredHistory(4))
        try await pruneLast(manager, noSnapshot: true)
        let tail = message(manager._testMessages, "REPLY_TAIL")
        check("R4 /prune nosnapshot: no demotion, no snapshot, coverage still recorded",
              records(manager._testMessages).isEmpty && snapshotIDs().isEmpty && fullAnchorContents(manager._testMessages).count == 5
              && tail?.prunedContextSummaryCoverage?.start == at(2026, 9, 20, 9, 30))

        // R6: one history write per commit; no request is sent.
        manager = await freshManager(history: anchoredHistory(3))
        var writes = 0
        ConversationManager.historyWriteFaultForTesting = { writes += 1 }
        server.clear()
        try await pruneLast(manager)
        ConversationManager.historyWriteFaultForTesting = nil
        check("R6a demotion rides the prune's single history write; no request is sent",
              writes == 1 && server.completeRequests.isEmpty && records(diskHistory() ?? []).count == 1, "writes \(writes)")
        try await realManualPruneRow()

        // R8: re-demotion appends a second record; both snapshots protected.
        manager = await freshManager(history: anchoredHistory(3))
        try await pruneLast(manager)
        var view = manager._testMessages
        let a0 = view.firstIndex { $0.content == "REPLY_A0" }!
        view[a0].toolInteractions = [round("again", issued: at(2026, 9, 25, 8, 0))]
        manager._testReplaceMessages(view); _ = manager._testSave()
        _ = try await manager._testRetentionPrune(affected: [a0], trigger: "manual", summary: "A0_AGAIN")
        let both = message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries ?? []
        _ = try fillSnapshots(305, future: true)
        try PruneArchiveStore.retainLatest()
        let ids = snapshotIDs()
        check("R8 re-demotion: second record appended with its own snapshot; both survive retention",
              both.count == 2 && both.allSatisfy { ids.contains($0.snapshot.id) } && ids.count == 300, "\(both.count) records, \(ids.count) snapshots")

        // R9: the demotion snapshot carries the enclosing trigger; body starts with the note.
        for trigger in ["manual", "automatic", "mid-turn"] {
            manager = await freshManager(history: anchoredHistory(3))
            try await pruneLast(manager, trigger: trigger)
            let snapshot = message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries.first?.snapshot
            let lines = snapshot.map { snapshotText($0).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
            check("R9 \(trigger): demotion snapshot header trigger = enclosing prune trigger; body starts with the demotion note",
                  snapshot.flatMap(snapshotHeaderTrigger) == trigger && lines.count > 1 && lines[1] == PruneSummaryRetention.snapshotLeadNote,
                  "trigger \(snapshot.flatMap(snapshotHeaderTrigger) ?? "nil")")
        }
    }

    /// R6 end to end: a real manual /prune through the scripted provider
    /// sends exactly the one prune-summary request, and demotes.
    func realManualPruneRow() async throws {
        try KeychainHelper.save(key: KeychainHelper.targetContextTokensKey, value: "5000")
        defer { try? KeychainHelper.delete(key: KeychainHelper.targetContextTokensKey) }
        var h = anchoredHistory(3)
        let big = String(repeating: "EVIDENCE ", count: 6000)
        h[h.count - 1].toolInteractions = [ToolInteraction(
            assistantMessage: { var a = AssistantToolCallMessage(content: nil, toolCalls: [
                ToolCall(id: "bigread", type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))])
                a.issuedAt = at(2026, 9, 20, 9, 30); return a }(),
            results: [ToolResultMessage(toolCallId: "bigread", content: big)])]
        let manager = await freshManager(history: h)
        server.clear()
        let reply = MidturnHarness.chatText("REAL_PRUNE_SUMMARY")
        server.router = { request in
            String(decoding: request.body, as: UTF8.self).contains("[PRUNE SUMMARY") ? (reply, 0) : nil
        }
        await manager._testManualPrune()
        server.router = nil
        let bodies = requestBodies()
        check("R6b real manual /prune: one prune-summary request, demotion in the same commit",
              bodies.count == 1 && bodies[0].contains("[PRUNE SUMMARY")
              && message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries.count == 1
              && message(manager._testMessages, "REPLY_TAIL")?.prunedContextSummary == "REAL_PRUNE_SUMMARY",
              "\(bodies.count) requests; notice \(manager._testMaintenanceNotice ?? "")")
    }

    /// R5 snapshot failure fallback; R7 summary outside the source.
    func ruleFailureSection() async throws {
        var manager = await freshManager(history: anchoredHistory(3))
        var writes = 0
        PruneArchiveStore.faultForTesting = { stage in
            if stage == "write" { writes += 1; if writes == 2 { throw PruneArchiveStore.Failure("injected demotion write failure") } }
        }
        let committed = try? await pruneLast(manager)
        PruneArchiveStore.faultForTesting = nil
        let a0 = message(manager._testMessages, "REPLY_A0")
        check("R5a demotion snapshot fails → full text and coverage kept, the prune still commits, a notice is shown",
              committed != nil && a0?.prunedContextSummary == "FULL_SUMMARY_A0" && a0?.prunedContextSummaryCoverage != nil
              && a0?.demotedPruneSummaries.isEmpty == true && message(manager._testMessages, "REPLY_TAIL")?.prunedContextSummary == "NEW_SUMMARY"
              && (manager._testMaintenanceNotice ?? "").contains("Older summaries stay in full"),
              "notice \(manager._testMaintenanceNotice ?? "nil")")
        var view = manager._testMessages
        view.append(user("U_NEXT", at: at(2026, 9, 21, 9, 0)))
        view.append(toolTurn("NEXT", at: at(2026, 9, 21, 10, 0), issued: [at(2026, 9, 21, 9, 30)]))
        manager._testSeedHistory(view)
        try await pruneLast(manager)
        check("R5b the next prune demotes", message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries.count == 1
              && message(manager._testMessages, "REPLY_A1")?.demotedPruneSummaries.count == 1)

        // R7: a live summary outside the prune's source → demotion skipped.
        var h = anchoredHistory(3)
        h.append(anchor("OUTSIDE", at: at(2026, 9, 22, 10, 0)))
        manager = await freshManager(history: h)
        _ = try await manager._testRetentionPrune(affected: [h.count - 2], trigger: "mid-turn", sourceCount: h.count - 1, summary: "R7")
        check("R7 a live summary outside the prune source → demotion skipped for that prune",
              records(manager._testMessages).isEmpty && fullAnchorContents(manager._testMessages).count == 5)
    }
}
