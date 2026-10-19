import Foundation

/// §10 overflow convergence through the real chat transport (E group):
/// in-band 400 → one reduction (no job: today's mid-loop prune, no
/// compaction) and one resend; no effective change → original error, no
/// resend; out of band and ineligible statuses → original error; the
/// shared inline allowance (B4b(h)).
enum BackgroundPruneSelftestConverge {
    static let errorBody = "{\"error\":{\"message\":\"This model's maximum context length was exceeded\",\"code\":400}}"

    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        // E1: admitted in band (bytes above the maximum), no job, 400.
        let manager = await h.freshManager(history: h.prunableHistory())
        manager.bgPruneTestSetLastPromptTokens(1_000)
        h.server.script([errorBody, BackgroundPruneSelftestHarness.chat("recovered", prompt: 100)], statuses: [400, 200])
        h.observeMainRequests()
        manager._testStartTurn(for: Message(role: .user, content: "in-band failure"))
        let idle = await manager._testAwaitIdle(timeout: 40)
        h.server.requestObserver = nil
        h.check("E in-band 400 → one reduction (inline mid-loop prune) and one resend", idle && manager._testLastError == nil
                && h.eventCount("bgprune.converge.reduce") == 1 && h.eventCount("bgprune.inline") == 1
                && h.eventCount("bgprune.converge.resent") == 1 && h.mainRequests.count == 2 && h.router.summaries == 1,
                "error \(String(describing: manager._testLastError)) events \(h.allEvents) main \(h.mainRequests.count)")
        h.check("E the resend was rebuilt from live state (pruned output gone)", h.mainRequests.count == 2
                && h.bodyText(h.mainRequests[0]).contains("RESULT-h-call-0 ") && !h.bodyText(h.mainRequests[1]).contains("RESULT-h-call-0 "))
        h.check("§9.2 a learned bound is recorded for the identity (only lowers C)",
                manager.bgPruneTestObservedBounds.count == 1)
        h.check("§10.3 convergence ran no compaction", !h.log.all.contains("compaction"))

        // E2: no effective change → the original error, no resend.
        var plain = (0..<6).map { i in Message(role: i % 2 == 0 ? .user : .assistant, content: "plain-\(i) " + String(repeating: "word ", count: 9_000)) }
        plain.append(Message(role: .user, content: "tail"))
        let stuck = await h.freshManager(history: plain)
        stuck.bgPruneTestSetLastPromptTokens(1_000)
        h.server.script([errorBody], statuses: [400])
        stuck._testStartTurn(for: Message(role: .user, content: "nothing prunable"))
        _ = await stuck._testAwaitIdle(timeout: 40)
        h.check("E no effective change → original error, no resend", (stuck._testLastError ?? "").contains("400")
                && h.mainRequests.count == 1 && h.eventCount("bgprune.converge.no-change") == 1,
                "error \(String(describing: stuck._testLastError)) events \(h.allEvents) main \(h.mainRequests.count)")

        // E3: out of band (admitted under the maximum) → original error.
        let small = await h.freshManager(history: h.prunableHistory(pairs: 2, size: 200))
        small.bgPruneTestSetLastPromptTokens(1_000)
        h.server.script([errorBody], statuses: [400])
        small._testStartTurn(for: Message(role: .user, content: "out of band"))
        _ = await small._testAwaitIdle(timeout: 40)
        h.check("E out of band → original error, no convergence", (small._testLastError ?? "").contains("400")
                && h.mainRequests.count == 1 && h.eventCount(prefix: "bgprune.converge") == 0)

        // E4: an ineligible status in band → original error.
        let auth = await h.freshManager(history: h.prunableHistory())
        auth.bgPruneTestSetLastPromptTokens(1_000)
        h.server.script(["{\"error\":{\"message\":\"bad key\"}}"], statuses: [401])
        auth._testStartTurn(for: Message(role: .user, content: "unauthorized in band"))
        _ = await auth._testAwaitIdle(timeout: 40)
        h.check("E 401 in band → original error, no convergence", (auth._testLastError ?? "").contains("401")
                && h.eventCount(prefix: "bgprune.converge") == 0, "\(String(describing: auth._testLastError))")

        await sharedAllowance(h)
    }

    /// B4b(h): D's inline block used the logical request's allowance; an
    /// in-band failure of the same send gets no second inline block and no
    /// resend (target above the maximum keeps the request in band).
    @MainActor static func sharedAllowance(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        let hold = BackgroundPruneSelftestGate()
        ConversationManager.bgPruneHoldForTesting = { point in if point == "worker.summary" { await hold.awaitRelease() } }
        ConversationManager.bgPruneDeadlineSecondsForTesting = 0.5
        manager.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(manager, "freeze with an uncooperative worker")
        _ = await h.waitUntil { manager.bgPruneTestPhase == "retiring:deadline" }
        // The prune target above the maximum keeps the request in band after
        // the inline block; the window cap puts D at or over C.
        try? KeychainHelper.save(key: KeychainHelper.targetContextTokensKey, value: "52000")
        BackgroundPruneContextWindow.overrides = [h.model: 50_000 + 32_768]
        h.clearEvents()
        h.server.clear()
        manager.bgPruneTestSetLastPromptTokens(1_000)
        h.server.script([errorBody], statuses: [400])
        manager._testStartTurn(for: Message(role: .user, content: "D inline, then an in-band failure"))
        _ = await manager._testAwaitIdle(timeout: 40)
        h.check("B4b(h) one inline block for the logical request; the in-band failure gets no second one and no resend",
                h.eventCount("bgprune.inline") == 1 && h.eventCount("bgprune.converge.reduce") == 1
                && h.eventCount("bgprune.converge.resent") == 0 && h.eventCount("bgprune.admit.overceiling") == 1
                && h.mainRequests.count == 1 && (manager._testLastError ?? "").contains("400"),
                "events \(h.allEvents) main \(h.mainRequests.count) error \(String(describing: manager._testLastError))")
        hold.release()
        _ = await h.waitUntil { manager.bgPruneTestPhase == "none" }
        ConversationManager.bgPruneHoldForTesting = nil
        ConversationManager.bgPruneDeadlineSecondsForTesting = nil
        try? KeychainHelper.save(key: KeychainHelper.targetContextTokensKey, value: String(h.target))
        BackgroundPruneContextWindow.overrides = [:]
    }
}
