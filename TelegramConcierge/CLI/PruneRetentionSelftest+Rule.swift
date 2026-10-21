import Foundation

/// R1–R9: the three-anchor rule, now applied when a request is composed
/// (/keepsummaries default 3): every commit keeps the full summaries and
/// prepares their pointers; the composed view shows the newest three in full.
extension RetentionHarness {

    func fullAnchorContents(_ history: [Message]) -> [String] {
        history.filter(PruneSummaryRetention.isFullAnchor).map(\.content)
    }

    /// R1, R2, R3, R4, R6, R8, R9.
    func ruleSection() async throws {
        // R1: ≤ 3 → nothing composed as a pointer; 4 → oldest; 6 → oldest 3.
        // Every commit keeps all full summaries and prepares the missing
        // pointers in ONE stub snapshot next to the prune's own.
        var manager = await freshManager(history: anchoredHistory(2))
        try await pruneLast(manager)
        let allStubbed = manager._testMessages.filter(PruneSummaryRetention.isFullAnchor)
            .allSatisfy { $0.prunedContextSummaryStub?.isUsable(for: $0.prunedContextSummary) == true }
        check("R1a three anchors → nothing shown as a pointer; their three pointers prepared in one stub snapshot",
              records(composed(manager._testMessages)).isEmpty && snapshotIDs().count == 2 && allStubbed
              && records(manager._testMessages).isEmpty, "\(snapshotIDs().count) snapshots")
        manager = await freshManager(history: anchoredHistory(3))
        try await pruneLast(manager)
        check("R1b four anchors → the oldest is shown as a pointer; every full summary is kept",
              message(composed(manager._testMessages), "REPLY_A0")?.demotedPruneSummaries.count == 1
              && fullAnchorContents(composed(manager._testMessages)) == ["REPLY_A1", "REPLY_A2", "REPLY_TAIL"]
              && fullAnchorContents(manager._testMessages).count == 4)
        let six = anchoredHistory(5)
        manager = await freshManager(history: six)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try await pruneLast(manager)
        let kept = ["REPLY_A3", "REPLY_A4"].allSatisfy { label in
            var shown = message(composed(manager._testMessages), label)!
            shown.prunedContextSummaryStub = nil
            return (try? encoder.encode(shown)) == (try? encoder.encode(message(six, label)!))
        }
        check("R1c six anchors → oldest three shown as pointers; newest three in full, untouched ones byte-identical apart from their pointer",
              records(composed(manager._testMessages)).count == 3 && kept
              && fullAnchorContents(composed(manager._testMessages)) == ["REPLY_A3", "REPLY_A4", "REPLY_TAIL"]
              && fullAnchorContents(manager._testMessages).count == 6)

        // R2: an anchor with several appended summaries is demoted as one.
        var h = anchoredHistory(3)
        h[1].prunedContextSummary = "FIRST_PART_A0\n\nSECOND_PART_A0"
        manager = await freshManager(history: h)
        try await pruneLast(manager)
        let r2 = message(composed(manager._testMessages), "REPLY_A0")?.demotedPruneSummaries ?? []
        let r2text = r2.first.map { snapshotText($0.snapshot) } ?? ""
        check("R2a several appended summaries shown as one pointer; its snapshot holds every part and its coverage",
              r2.count == 1 && r2text.contains("FIRST_PART_A0") && r2text.contains("SECOND_PART_A0")
              && r2text.contains("Prior pruning summary coverage: 1 Sep 2026 09:50–10:00 (UTC+02:00); files: [") && r2text.contains("A0.swift\"]"),
              String(r2text.prefix(400)))
        h = anchoredHistory(2)
        h[3].prunedContextSummary = "PART_ONE\n\nPART_TWO"
        manager = await freshManager(history: h)
        try await pruneLast(manager)
        check("R2b three anchors holding four summaries → nothing demoted (anchors are counted, not summaries)",
              records(composed(manager._testMessages)).isEmpty)

        // R3: active-turn summaries are never counted or demoted.
        h = anchoredHistory(2)
        for i in 0..<2 {
            var finished = Message(role: .assistant, content: "FINISHED_\(i)", timestamp: at(2026, 9, 15, 10 + i, 0))
            finished.activeTurnCompaction = carried("unpruned active summary \(i)")
            h.insert(finished, at: 2)
        }
        manager = await freshManager(history: h)
        try await pruneLast(manager)
        check("R3a finished turns' unpruned active-turn summaries are not anchors: three anchors → no pointer",
              records(composed(manager._testMessages)).isEmpty
              && manager._testMessages.filter { $0.activeTurnCompaction != nil }.count == 2)
        h.insert(contentsOf: [user("U_X", at: at(2026, 8, 31, 9, 0)), anchor("X", at: at(2026, 8, 31, 10, 0))], at: 0)
        manager = await freshManager(history: h)
        try await pruneLast(manager)
        check("R3b with four summary anchors only the oldest summary anchor is a pointer; active-turn summaries untouched",
              records(composed(manager._testMessages)).count == 1 && message(composed(manager._testMessages), "REPLY_X")?.demotedPruneSummaries.count == 1
              && manager._testMessages.filter { $0.activeTurnCompaction != nil }.count == 2)

        // R4: /prune nosnapshot → no demotion, coverage still recorded.
        manager = await freshManager(history: anchoredHistory(4))
        try await pruneLast(manager, noSnapshot: true)
        let tail = message(manager._testMessages, "REPLY_TAIL")
        check("R4 /prune nosnapshot: no stub snapshot (so no pointer), no snapshot, coverage still recorded",
              records(composed(manager._testMessages)).isEmpty && snapshotIDs().isEmpty && fullAnchorContents(manager._testMessages).count == 5
              && tail?.prunedContextSummaryCoverage?.start == at(2026, 9, 20, 9, 30))

        // R6: one history write per commit; no request is sent.
        manager = await freshManager(history: anchoredHistory(3))
        var writes = 0
        ConversationManager.historyWriteFaultForTesting = { writes += 1 }
        server.clear()
        try await pruneLast(manager)
        ConversationManager.historyWriteFaultForTesting = nil
        check("R6a pointer preparation rides the prune's single history write; no request is sent; full texts on disk",
              writes == 1 && server.completeRequests.isEmpty && records(composed(diskHistory() ?? [])).count == 1
              && records(diskHistory() ?? []).isEmpty && fullAnchorContents(diskHistory() ?? []).count == 4, "writes \(writes)")
        try await realManualPruneRow()

        // R8: an extended summary's fresh stub snapshot is protected through
        // the committed history; the replaced one is no longer referenced.
        manager = await freshManager(history: anchoredHistory(3))
        try await pruneLast(manager)
        var view = manager._testMessages
        let a0 = view.firstIndex { $0.content == "REPLY_A0" }!
        let oldStub = view[a0].prunedContextSummaryStub?.record.snapshot
        view[a0].toolInteractions = [round("again", issued: at(2026, 9, 25, 8, 0))]
        manager._testReplaceMessages(view); _ = manager._testSave()
        _ = try await manager._testRetentionPrune(affected: [a0], trigger: "manual", summary: "A0_AGAIN")
        let newStub = message(manager._testMessages, "REPLY_A0")?.prunedContextSummaryStub?.record.snapshot
        _ = try fillSnapshots(305, future: true)
        try PruneArchiveStore.retainLatest()
        let ids = snapshotIDs()
        let live: Set<UUID>
        if case .snapshots(let found) = PruneSummaryRetention.liveDemotionSnapshots(historyFile: historyURL) { live = found } else { live = [] }
        check("R8 extension: the fresh stub snapshot survives retention (the shared older one too, still referenced by the other anchors)",
              newStub != nil && newStub != oldStub && ids.contains(newStub!.id) && live.contains(newStub!.id)
              && ids.contains(oldStub?.id ?? UUID()) && ids.count == 300, "\(ids.count) snapshots")

        // R9: the demotion snapshot carries the enclosing trigger; body starts with the note.
        for trigger in ["manual", "automatic", "mid-turn"] {
            manager = await freshManager(history: anchoredHistory(3))
            try await pruneLast(manager, trigger: trigger)
            let snapshot = message(composed(manager._testMessages), "REPLY_A0")?.demotedPruneSummaries.first?.snapshot
            let lines = snapshot.map { snapshotText($0).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
            check("R9 \(trigger): stub snapshot header trigger = enclosing prune trigger; body starts with the demotion note",
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
        check("R6b real manual /prune: one prune-summary request, pointers prepared in the same commit",
              bodies.count == 1 && bodies[0].contains("[PRUNE SUMMARY")
              && message(composed(manager._testMessages), "REPLY_A0")?.demotedPruneSummaries.count == 1
              && message(manager._testMessages, "REPLY_A0")?.prunedContextSummary == "FULL_SUMMARY_A0"
              && message(manager._testMessages, "REPLY_TAIL")?.prunedContextSummary == "REAL_PRUNE_SUMMARY",
              "\(bodies.count) requests; notice \(manager._testMaintenanceNotice ?? "")")
    }

    /// R5 snapshot failure fallback; R7 summary outside the source.
    func ruleFailureSection() async throws {
        var manager = await freshManager(history: anchoredHistory(3))
        var writes = 0
        PruneArchiveStore.faultForTesting = { stage in
            if stage == "write" { writes += 1; if writes == 2 { throw PruneArchiveStore.Failure("injected stub write failure") } }
        }
        let committed = try? await pruneLast(manager)
        PruneArchiveStore.faultForTesting = nil
        let a0 = message(manager._testMessages, "REPLY_A0")
        check("R5a stub snapshot fails → no pointer, every anchor shown in full, the prune still commits, a notice is shown",
              committed != nil && a0?.prunedContextSummary == "FULL_SUMMARY_A0" && a0?.prunedContextSummaryCoverage != nil
              && a0?.prunedContextSummaryStub == nil && records(composed(manager._testMessages)).isEmpty
              && message(manager._testMessages, "REPLY_TAIL")?.prunedContextSummary == "NEW_SUMMARY"
              && (manager._testMaintenanceNotice ?? "").contains("Summaries stay in full"),
              "notice \(manager._testMaintenanceNotice ?? "nil")")
        var view = manager._testMessages
        view.append(user("U_NEXT", at: at(2026, 9, 21, 9, 0)))
        view.append(toolTurn("NEXT", at: at(2026, 9, 21, 10, 0), issued: [at(2026, 9, 21, 9, 30)]))
        manager._testSeedHistory(view)
        try await pruneLast(manager)
        check("R5b the next prune prepares every missing pointer", message(composed(manager._testMessages), "REPLY_A0")?.demotedPruneSummaries.count == 1
              && message(composed(manager._testMessages), "REPLY_A1")?.demotedPruneSummaries.count == 1)

        // R7: a live summary outside the prune's source gets no pointer at
        // that commit (the idle pass prepares it); source anchors get theirs.
        var h = anchoredHistory(3)
        h.append(anchor("OUTSIDE", at: at(2026, 9, 22, 10, 0)))
        manager = await freshManager(history: h)
        _ = try await manager._testRetentionPrune(affected: [h.count - 2], trigger: "mid-turn", sourceCount: h.count - 1, summary: "R7")
        let outside = message(manager._testMessages, "REPLY_OUTSIDE")
        check("R7 a live summary outside the prune source gets no pointer at that commit; the source anchors do; every text kept",
              outside?.prunedContextSummaryStub == nil && records(composed(manager._testMessages)).count == 2
              && fullAnchorContents(manager._testMessages).count == 5
              && message(manager._testMessages, "REPLY_A0")?.prunedContextSummaryStub != nil)
    }
}
