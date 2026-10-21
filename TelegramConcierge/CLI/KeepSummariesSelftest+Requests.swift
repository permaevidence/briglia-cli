import Foundation

/// K6 immediate effect (between turns and between rounds of one turn),
/// K7 one view per request, K16 nothing leaks into the saved history,
/// K15 pressure with a large N.
extension RetentionHarness {

    func mainBodies() -> [String] {
        server.completeRequests.filter(isMainRequest).map { decodedText(String(decoding: $0.body, as: UTF8.self)) }
    }

    func runTurn(_ manager: ConversationManager, _ text: String) async {
        manager._testStartTurn(for: user(text, at: Date()))
        _ = await manager._testAwaitIdle(timeout: 60)
    }

    /// K6 between turns, K16.
    func requestSection() async throws {
        let labels = (0..<6).map { "K\($0)" }
        let manager = try await freshStubbed(6)
        let seeded = manager._testMessages
        let before = try Data(contentsOf: historyURL)
        server.router = { request in (RetentionHarness.chat("ok", prompt: 1_000), 0) }
        defer { server.router = nil }
        var counts: [Int] = []
        var pointerLines: [Int] = []
        for limit in [nil, KeepSummariesLimit.all, .count(1), .count(5), .count(3)] as [KeepSummariesLimit?] {
            if let limit { KeepSummariesSetting.store(limit) }
            server.clear()
            await runTurn(manager, "turn with \(limit?.description ?? "default")")
            let body = mainBodies().last ?? ""
            counts.append(fullCount(body, labels: labels))
            pointerLines.append(Self.occurrences(PruneSummaryRetention.wrapperPrefix, in: body))
        }
        check("K6a each turn's request shows the newest N in full (default 3, all, 1, 5, back to 3): changes apply from the next request, both ways",
              counts == [3, 6, 1, 5, 3] && pointerLines == [3, 0, 5, 1, 3], "full \(counts) pointers \(pointerLines)")
        let disk = diskHistory() ?? []
        let summaries = disk.filter(PruneSummaryRetention.isFullAnchor).map { $0.prunedContextSummary ?? "" }
        let seededAnchors = seeded.filter(PruneSummaryRetention.isFullAnchor)
        check("K16 after requests with N = 1 and all, the saved file still holds every full summary, its coverage and stub; no record was written",
              summaries == labels.map { "FULL_SUMMARY_" + $0 } && records(disk).isEmpty
              && disk.filter(PruneSummaryRetention.isFullAnchor).map(\.prunedContextSummaryStub) == seededAnchors.map(\.prunedContextSummaryStub)
              && disk.filter(PruneSummaryRetention.isFullAnchor).map(\.prunedContextSummaryCoverage) == seededAnchors.map(\.prunedContextSummaryCoverage),
              "\(summaries.count) summaries, \(records(disk).count) records")
        // The prefix of the saved file up to the seeded messages is unchanged
        // (the turns only appended).
        let seededDisk = Array(disk.prefix(seeded.count))
        let original = try JSONDecoder().decode([Message].self, from: before)
        check("K6b the persisted seeded history is byte-identical after five turns with different N",
              encodedSorted(seededDisk) == encodedSorted(Array(original.prefix(seeded.count))))
        UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
    }

    /// K6 between rounds of one turn; K7 one view per request.
    func requestViewSection() async throws {
        let labels = (0..<6).map { "K\($0)" }
        var manager = try await freshStubbed(6)
        let switched = LockedFlag()
        server.router = { request in
            let body = String(decoding: request.body, as: UTF8.self)
            if body.contains("[PRUNE SUMMARY") { return nil }
            if !switched.value {
                switched.value = true
                KeepSummariesSetting.store(.all)
                return (RetentionHarness.tools("call-1", prompt: 1_000), 0)
            }
            return (RetentionHarness.chat("done", prompt: 1_200), 0)
        }
        server.clear()
        await runTurn(manager, "two rounds")
        server.router = nil
        let bodies = mainBodies()
        check("K6c N changed between rounds of one turn: round 1 composed with 3, round 2 with all",
              bodies.count == 2 && fullCount(bodies[0], labels: labels) == 3 && fullCount(bodies[1], labels: labels) == 6,
              "\(bodies.map { fullCount($0, labels: labels) })")
        UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)

        // K7: the setting changes right after the request view is built (the
        // round already captured its limit): estimate and send keep that view.
        manager = try await freshStubbed(6)
        var observed: [KeepSummariesLimit] = []
        ConversationManager.requestViewObserverForTesting = { view in
            observed.append(view.limit)
            KeepSummariesSetting.store(.count(1))
        }
        server.router = { _ in (RetentionHarness.chat("ok", prompt: 1_000), 0) }
        server.clear()
        await runTurn(manager, "change while composing")
        ConversationManager.requestViewObserverForTesting = nil
        server.router = nil
        let body = mainBodies().last ?? ""
        check("K7 a change while a request is composed does not split it: that request keeps the view it was built with",
              observed.first == .defaultValue && fullCount(body, labels: labels) == 3 && KeepSummariesSetting.current() == .count(1),
              "observed \(observed), full \(fullCount(body, labels: labels))")
        UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)

        // K15: N = all over a budget-exceeding history: the pre-request prune
        // sees the composed full view (it prunes), and the request still
        // shows every summary in full (no automatic override of N).
        try KeychainHelper.save(key: KeychainHelper.maxContextTokensKey, value: "40000")
        try KeychainHelper.save(key: KeychainHelper.targetContextTokensKey, value: "20000")
        defer {
            try? KeychainHelper.delete(key: KeychainHelper.maxContextTokensKey)
            try? KeychainHelper.delete(key: KeychainHelper.targetContextTokensKey)
        }
        manager = try await freshStubbed(6) { history in
            var turn = self.toolTurn("HEAVY", at: self.at(2026, 9, 29, 10, 0), issued: [self.at(2026, 9, 29, 9, 30)])
            turn.toolInteractions[0].results[0].content = String(repeating: "HEAVY OUTPUT ", count: 16_000)
            history.append(turn)
        }
        KeepSummariesSetting.store(.all)
        server.router = { request in
            let text = String(decoding: request.body, as: UTF8.self)
            return (text.contains("[PRUNE SUMMARY") ? RetentionHarness.chat("PRESSURE_SUMMARY", prompt: 50) : RetentionHarness.chat("ok", prompt: 1_000), 0)
        }
        server.clear()
        await runTurn(manager, "over budget with all")
        server.router = nil
        let pressureBodies = server.completeRequests.map { String(decoding: $0.body, as: UTF8.self) }
        let main = mainBodies().last ?? ""
        let heavyPruned = message(manager._testMessages, "REPLY_HEAVY")?.toolInteractions.isEmpty == true
        check("K15 N = all over the budget: the prune runs on the composed view (the heavy turn is pruned) and the request still shows all six summaries",
              heavyPruned && pressureBodies.count > 1 && fullCount(main, labels: labels) == 6,
              "\(pressureBodies.count) requests, full \(fullCount(main, labels: labels))")
        UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
    }
}

/// A flag shared with the loopback server's thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

