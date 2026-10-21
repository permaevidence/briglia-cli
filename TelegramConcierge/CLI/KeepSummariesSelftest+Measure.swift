import Foundation

/// K8 measurement validity (§4.4): a measurement is used only under the
/// composition that produced it; attribution only against a baseline with
/// the request's own key; old snapshots mean the empty key exactly.
extension RetentionHarness {

    func pruneRequested() -> Bool {
        server.completeRequests.contains { String(decoding: $0.body, as: UTF8.self).contains("[PRUNE SUMMARY") }
    }

    /// K8 between turns: decision and user attribution.
    func measureBetweenTurnsSection() async throws {
        var outcomes: [String: (pruned: Bool, user: Int?)] = [:]
        for (name, limit) in [("equal keys", nil), ("composition changed", KeepSummariesLimit.all)] as [(String, KeepSummariesLimit?)] {
            let manager = try await freshStubbed(6) { $0.insert(self.toolTurn("PRUNABLE", at: self.at(2026, 9, 28, 10, 0), issued: [self.at(2026, 9, 28, 9, 30)]), at: $0.count - 1) }
            // A measurement far over the budget, taken under the default view.
            let key3 = PruneSummaryRetention.compose(manager._testMessages, limit: .defaultValue).renderKey
            manager._testSetPromptMeasurement(5_000_000, key: key3)
            if let limit { KeepSummariesSetting.store(limit) }
            server.router = { request in
                let text = String(decoding: request.body, as: UTF8.self)
                return (text.contains("[PRUNE SUMMARY") ? RetentionHarness.chat("K8_SUMMARY", prompt: 50) : RetentionHarness.chat("ok", prompt: 5_000_400), 0)
            }
            server.clear()
            await runTurn(manager, "K8 \(name)")
            server.router = nil
            let userMessage = manager._testMessages.last { $0.role == .user && $0.content == "K8 \(name)" }
            outcomes[name] = (pruneRequested(), userMessage?.measuredTokens)
            UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
        }
        check("K8a equal keys keep today's behaviour: the cached measurement decides (a prune runs) and the user delta is attributed",
              outcomes["equal keys"]?.pruned == true, "\(String(describing: outcomes["equal keys"]))")
        check("K8b an older anchor's composition changed (default → all): the cached measurement is ignored (estimate, no prune) and no user tokens are attributed",
              outcomes["composition changed"]?.pruned == false && outcomes["composition changed"]?.user == nil,
              "\(String(describing: outcomes["composition changed"]))")

        // Attribution control on the same keys: a real previous turn.
        let manager = try await freshStubbed(6)
        server.router = { _ in (RetentionHarness.chat("ok", prompt: 1_000), 0) }
        await runTurn(manager, "K8 first")
        server.router = { _ in (RetentionHarness.chat("ok", prompt: 1_100), 0) }
        await runTurn(manager, "K8 same")
        let same = manager._testMessages.last { $0.content == "K8 same" }?.measuredTokens
        KeepSummariesSetting.store(.count(1))
        server.router = { _ in (RetentionHarness.chat("ok", prompt: 900), 0) }
        await runTurn(manager, "K8 changed")
        server.router = nil
        let changed = manager._testMessages.last { $0.content == "K8 changed" }
        check("K8c consecutive turns: same composition → the user message gets its delta; changed composition → nothing is written to it",
              same == 1_100 - 1_000 - 10 && changed?.measuredTokens == nil && manager._testLastPromptTokens == 900
              && manager._testPromptRenderKey == PruneSummaryRetention.compose(manager._testMessages, limit: .count(1)).renderKey,
              "same \(String(describing: same)) changed \(String(describing: changed?.measuredTokens))")
        UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
    }

    /// K8i the fallback estimate is made on the composed view, not on the
    /// canonical history (40 long summaries: in full they exceed the budget,
    /// composed with the default 3 they do not).
    func measureEstimateSection() async throws {
        try KeychainHelper.save(key: KeychainHelper.maxContextTokensKey, value: "60000")
        try KeychainHelper.save(key: KeychainHelper.targetContextTokensKey, value: "30000")
        defer {
            try? KeychainHelper.delete(key: KeychainHelper.maxContextTokensKey)
            try? KeychainHelper.delete(key: KeychainHelper.targetContextTokensKey)
        }
        let manager = try await freshStubbed(0) { h in
            let long = String(repeating: "summary detail ", count: 400)
            var anchors: [Message] = []
            for i in 0..<40 {
                var a = self.anchor("L\(i)", at: self.at(2026, 8, 1, 0, 0).addingTimeInterval(Double(i) * 3600))
                a.prunedContextSummary = "FULL_SUMMARY_L\(i) " + long
                anchors.append(a)
            }
            if let ref = try? PruneArchiveStore.write(messages: anchors, trigger: "manual", removedIDs: anchors.map(\.id),
                                                      leadNote: PruneSummaryRetention.snapshotLeadNote) {
                for i in anchors.indices { anchors[i].prunedContextSummaryStub = PruneSummaryRetention.makeStub(for: anchors, anchor: i, snapshot: ref) }
            }
            h.insert(contentsOf: anchors + [self.toolTurn("SMALL", at: self.at(2026, 9, 28, 10, 0), issued: [self.at(2026, 9, 28, 9, 30)])], at: 0)
        }
        server.router = { request in
            let text = String(decoding: request.body, as: UTF8.self)
            return (text.contains("[PRUNE SUMMARY") ? RetentionHarness.chat("K8I_SUMMARY", prompt: 50) : RetentionHarness.chat("ok", prompt: 1_000), 0)
        }
        server.clear()
        await runTurn(manager, "K8i estimate")
        server.router = nil
        check("K8i no cached measurement: the pre-request estimate is made on the composed view (no prune; the canonical history would exceed the budget)",
              !pruneRequested() && message(manager._testMessages, "REPLY_SMALL")?.toolInteractions.isEmpty == false)
    }

    /// K8 mid-turn, late response, forced final.
    func measureMidTurnSection() async throws {
        var deltas: [String: Int?] = [:]
        var lateKeyOK = false
        for name in ["control", "switched"] {
            let manager = try await freshStubbed(6)
            let switched = LockedFlag()
            let first = LockedFlag()
            var keys: [String] = []
            ConversationManager.requestViewObserverForTesting = { view in keys.append(view.renderKey + "|" + manager._testPromptRenderKey) }
            server.router = { request in
                if !first.value {
                    first.value = true
                    if name == "switched" { KeepSummariesSetting.store(.all); switched.value = true }
                    return (RetentionHarness.tools("k8-call", prompt: 1_000), 0)
                }
                return (RetentionHarness.chat("done", prompt: 1_250), 0)
            }
            await runTurn(manager, "K8 mid \(name)")
            ConversationManager.requestViewObserverForTesting = nil
            server.router = nil
            let reply = manager._testMessages.last { $0.role == .assistant }
            deltas.updateValue(reply?.toolInteractions.first?.measuredTokenCost, forKey: name)
            if name == "switched", keys.count >= 2 {
                // Round 2's view is built after round 1's late response: that
                // response was stored under round 1's key, not the new setting.
                let round1 = keys[0].split(separator: "|").first.map(String.init) ?? ""
                let storedAtRound2 = keys[1].split(separator: "|").last.map(String.init) ?? ""
                lateKeyOK = storedAtRound2 == round1 && round1 != PruneSummaryRetention.emptyRenderKey
            }
            UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
        }
        check("K8d mid-turn: same composition → the round's delta is attributed (250); N changed between rounds → no tool attribution",
              deltas["control"] == .some(250) && deltas["switched"] == .some(nil), "\(deltas)")
        check("K8e a response that arrives after the command is stored under the key of the request it answers", lateKeyOK)

        // Forced final (per-turn spend cap reached after round 2's reply):
        // round 2 attributes 100 to round 1; the final overwrites it with its
        // own delta (200) only under the same composition.
        try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey, value: "0.5")
        defer { try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey) }
        var finals: [String: Int?] = [:]
        var sawFinal = true
        for name in ["control", "switched"] {
            let manager = try await freshStubbed(6)
            let count = LockedCounter()
            server.router = { request in
                count.increment()
                switch count.value {
                case 1: return (RetentionHarness.costed(RetentionHarness.tools("k8-final-1", prompt: 1_000), cost: 0.3), 0)
                case 2:
                    if name == "switched" { KeepSummariesSetting.store(.all) }
                    return (RetentionHarness.costed(RetentionHarness.tools("k8-final-2", prompt: 1_100), cost: 0.3), 0)
                default: return (RetentionHarness.chat("final", prompt: 1_300), 0)
                }
            }
            server.clear()
            await runTurn(manager, "K8 final \(name)")
            server.router = nil
            sawFinal = sawFinal && mainBodies().contains { $0.contains("[SPEND LIMIT]") }
            let reply = manager._testMessages.last { $0.role == .assistant }
            finals.updateValue(reply?.toolInteractions.first?.measuredTokenCost, forKey: name)
            UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
        }
        check("K8f forced final: same composition → the final's delta is attributed (200); composition changed before the final → round 2's value (100) is kept",
              sawFinal && finals["control"] == .some(200) && finals["switched"] == .some(100), "final seen \(sawFinal) \(finals)")
    }

    /// A Chat Completions body with an OpenRouter-style `usage.cost`.
    nonisolated static func costed(_ body: String, cost: Double) -> String {
        guard var object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              var usage = object["usage"] as? [String: Any] else { return body }
        usage["cost"] = cost
        object["usage"] = usage
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    /// K8 restart: a ≤0.2.57 snapshot (no key) is the empty key, exactly;
    /// an invalid or wrongly typed key is unknown (the measurement is ignored).
    func measureRestartSection() async throws {
        var results: [String] = []
        let cases: [(String, Any?, String)] = [
            ("no key (≤0.2.57)", nil, PruneSummaryRetention.emptyRenderKey),
            ("valid hex key", String(repeating: "ab", count: 32), String(repeating: "ab", count: 32)),
            ("invalid string", "zzz", PruneSummaryRetention.unknownRenderKey),
            ("wrong type", 42, PruneSummaryRetention.unknownRenderKey),
        ]
        for (name, key, expected) in cases {
            resetState()
            var object: [String: Any] = ["lastPromptTokens": 777, "lastCompletionTokens": 7, "updatedAt": 800_000_000.0]
            if let key { object["lastPromptRenderKey"] = key }
            try writeUsage(object)
            let manager = await restart()
            if manager._testPromptRenderKey != expected || manager._testLastPromptTokens != 777 || manager._testLastCompletionTokens != 7 {
                results.append("\(name): \(manager._testPromptRenderKey) \(String(describing: manager._testLastPromptTokens))")
            }
        }
        check("K8g restart: no key → the empty-set key (exact for ≤0.2.57); a valid key kept; an invalid or wrongly typed key → unknown; tokens still load",
              results.isEmpty, results.joined(separator: "; "))
        // A saved measurement carries its key; a cleared one carries none.
        resetState()
        let manager = try await freshStubbed(5)
        let key = PruneSummaryRetention.compose(manager._testMessages, limit: .defaultValue).renderKey
        manager._testSetPromptMeasurement(1_234, key: key)
        let saved = usageFile()
        manager._testSetPromptMeasurement(nil, key: key)
        let cleared = usageFile()
        check("K8h the usage snapshot saves the measurement and its key together; a cleared measurement saves no key",
              saved?["lastPromptTokens"] as? Int == 1_234 && saved?["lastPromptRenderKey"] as? String == key
              && cleared?["lastPromptTokens"] == nil && cleared?["lastPromptRenderKey"] == nil,
              "\(String(describing: saved)) | \(String(describing: cleared))")
    }
}
