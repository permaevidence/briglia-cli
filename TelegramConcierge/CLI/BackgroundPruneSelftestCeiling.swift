import Foundation

/// The ceiling, the phase wait and R (§7.3, §7.7, §9): B5, B4b(a)/(d),
/// L-debt both orders, /stop during the wait, the live maximum
/// (L-maxchange) and a model change re-capping a job before the send.
enum BackgroundPruneSelftestCeiling {
    /// W such that C = W − 32,768 is `ceiling` (window-capped ceiling).
    static func window(for ceiling: Int) -> Int { ceiling + 32_768 }

    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        await waitAtCeiling(h)
        await belowCeiling(h)
        await jumpAtFreeze(h)
        await deadlineDuringWait(h)
        await deadlineIdle(h)
        await stopDuringWait(h)
        await insufficientApply(h)
        await liveMaximum(h)
    }

    @MainActor static func capped(_ h: BackgroundPruneSelftestHarness, _ ceiling: Int) {
        BackgroundPruneContextWindow.overrides = [h.model: window(for: ceiling)]
    }

    /// B5: at ≥ C the turn waits for the same job (one summary request, no inline).
    @MainActor static func waitAtCeiling(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        capped(h, 80_000)
        let limits = await manager.bgPruneTestLiveLimits()
        h.check("§9.1 window-capped ceiling for the identity", limits.ceiling == 80_000 && limits.maximum == h.maximum, "\(limits)")
        let running = await h.frozenRunningJob(manager)
        h.check("B5 precondition: running job below C", running)
        manager.bgPruneTestSetLastPromptTokens(85_000)
        h.server.clear()
        h.startTurn(manager, "at the ceiling", replies: [BackgroundPruneSelftestHarness.chat("done", prompt: 100)])
        let waiting = await h.waitUntil { h.eventCount("bgprune.wait.begin") == 1 }
        let run = manager.bgPruneTestActiveRunId
        h.check("B5 the turn waits at ≥ C (pruneWait phase, no request sent)", waiting
                && run.map { manager.bgPruneTestRunPhase($0) } == "pruneWait" && h.mainRequests.isEmpty)
        let status = await manager.bgPruneTestCommand("/status")
        h.check("B5 /status names the wait", status.contains("(waiting for the prune to finish)"), status)
        h.check("§7.3 /stop wording names the wait", run.map { manager.bgPruneTestDescribe($0) }?.contains("waiting for a background prune") == true)
        h.router.gate.release()
        let idle = await manager._testAwaitIdle(timeout: 40)
        h.check("B5 the same job is applied after the wait; one summary request; no inline block", idle
                && h.eventCount("bgprune.applied") == 1 && h.router.summaries == 1 && h.eventCount(prefix: "bgprune.inline") == 0,
                "\(h.allEvents) summaries \(h.router.summaries)")
        h.check("B5 one phase wait, closed", h.eventCount("bgprune.wait.begin") == 1 && h.eventCount("bgprune.wait.end") == 1)
        h.check("B5 the request after the wait carries the applied history",
                h.mainRequests.count == 1 && !h.bodyText(h.mainRequests[0]).contains("RESULT-h-call-0 "))
    }

    /// B5: below C, no wait.
    @MainActor static func belowCeiling(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        capped(h, 80_000)
        _ = await h.frozenRunningJob(manager)
        manager.bgPruneTestSetLastPromptTokens(65_000)
        let idle = await h.turn(manager, "above the maximum, below the ceiling")
        h.check("B5 below C: no wait, the turn completes, the job keeps running", idle
                && h.eventCount("bgprune.wait.begin") == 0 && manager.bgPruneTestPhase == "running")
        h.check("§7.2 no new inline prune while a job runs below C", h.router.summaries == 1 && h.eventCount(prefix: "bgprune.inline") == 0)
        h.router.gate.release()
        _ = await h.waitPhase(manager, "ready")
    }

    /// B5/R5.2: a trigger already at or over C is never frozen; it runs inline.
    @MainActor static func jumpAtFreeze(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        capped(h, 80_000)
        manager.bgPruneTestSetLastPromptTokens(90_000)
        let idle = await h.turn(manager, "one jump past the ceiling")
        h.check("B5 a jump to ≥ C at the freeze runs today's inline prune", idle && manager.bgPruneTestPhase == "none"
                && h.eventCount("bgprune.ineligible.at-ceiling") == 1 && h.router.summaries == 1 && h.prunedIds(manager).count >= 6,
                "\(h.allEvents)")
        // Headroom below 25k (W cap) → inline.
        let small = await h.freshManager(history: h.prunableHistory())
        capped(h, h.maximum + 24_999)
        small.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(small, "too little headroom")
        h.check("§9.1 under 25k of headroom → inline, no job", small.bgPruneTestPhase == "none"
                && h.eventCount("bgprune.ineligible.headroom") == 1 && h.router.summaries == 1)
        // Exactly 25k → background allowed.
        let exact = await h.freshManager(history: h.prunableHistory())
        capped(h, h.maximum + 25_000)
        exact.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(exact, "exactly 25k of headroom")
        h.check("§9.1 exactly 25k of headroom → background job", h.eventCount("bgprune.freeze.pre-request") == 1
                && h.eventCount(prefix: "bgprune.ineligible") == 0, "\(h.allEvents)")
    }

    /// B4b(a) + L-debt (boundary first): the deadline fires during the
    /// wait while the worker ignores cancellation → the inline block runs
    /// once and the late termination owes nothing.
    @MainActor static func deadlineDuringWait(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        capped(h, 80_000)
        let hold = BackgroundPruneSelftestGate()
        ConversationManager.bgPruneHoldForTesting = { point in if point == "worker.summary" { await hold.awaitRelease() } }
        ConversationManager.bgPruneDeadlineSecondsForTesting = 1.5
        manager.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(manager, "freeze with an uncooperative worker")
        h.check("B4b(a) precondition: running", manager.bgPruneTestPhase == "running")
        manager.bgPruneTestSetLastPromptTokens(85_000)
        let idle = await h.turn(manager, "at the ceiling while the deadline passes", timeout: 40)
        h.check("B4b(a) wait → deadline → retiring → today's inline prune once, then the send", idle
                && h.eventCount("bgprune.deadline") == 1 && h.eventCount("bgprune.wait.begin") == 1
                && h.eventCount("bgprune.inline") == 1 && h.router.summaries == 1 && h.prunedIds(manager).count >= 6,
                "\(h.allEvents) summaries \(h.router.summaries)")
        h.check("QN2 the blocking inline fallback keeps today's notice (exactly one)", h.noticeTexts.count == 1,
                "\(h.channel.delivered)")
        h.check("§7.6 the inline block consumed the job's debt; the slot is still occupied (retiring)",
                manager.bgPruneTestPhase == "retiring:deadline" && manager.bgPruneTestInlineDebtConsumed)
        hold.release()
        let released = await h.waitUntil { manager.bgPruneTestPhase == "none" }
        h.check("L-debt delayed termination owes no second inline decision", released && !manager.bgPruneTestFallbackDue
                && h.eventCount(prefix: "bgprune.fallback-owed") == 0, "\(h.allEvents)")
        ConversationManager.bgPruneHoldForTesting = nil
        ConversationManager.bgPruneDeadlineSecondsForTesting = nil
    }

    /// B7 + L-debt mirror: the deadline of an idle job; termination first
    /// → one owed inline decision at the next over-maximum boundary.
    @MainActor static func deadlineIdle(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        let hold = BackgroundPruneSelftestGate()
        ConversationManager.bgPruneHoldForTesting = { point in if point == "worker.summary" { await hold.awaitRelease() } }
        ConversationManager.bgPruneDeadlineSecondsForTesting = 1.0
        manager.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(manager, "freeze, then idle")
        let retired = await h.waitUntil(timeout: 10) { manager.bgPruneTestPhase == "retiring:deadline" }
        h.check("B7 deadline fires on an idle job (monotonic watchdog)", retired)
        hold.release()
        let released = await h.waitUntil { manager.bgPruneTestPhase == "none" }
        h.check("L-debt mirror: termination first → one owed decision", released && manager.bgPruneTestFallbackDue
                && h.eventCount("bgprune.fallback-owed.deadline") == 1)
        h.check("B7 a cancelled worker sent no summary request", h.router.summaries == 0)
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "below the maximum")
        h.check("§7.6 the owed decision waits while under the maximum", manager.bgPruneTestFallbackDue && h.router.summaries == 0)
        manager.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(manager, "over the maximum again")
        h.check("§7.6 the next over-maximum boundary runs today's inline prune once and freezes nothing",
                !manager.bgPruneTestFallbackDue && h.eventCount("bgprune.owed-inline") == 1
                && h.eventCount(prefix: "bgprune.freeze") == 1 && h.router.summaries == 1 && manager.bgPruneTestPhase == "none",
                "\(h.allEvents)")
        h.check("QN2 the owed inline prune keeps today's notice (exactly one)", h.noticeTexts.count == 1,
                "\(h.channel.delivered)")
        ConversationManager.bgPruneHoldForTesting = nil
        ConversationManager.bgPruneDeadlineSecondsForTesting = nil
    }

    /// B13: /stop during the wait exits the run without an inline prune.
    @MainActor static func stopDuringWait(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        capped(h, 80_000)
        _ = await h.frozenRunningJob(manager)
        manager.bgPruneTestSetLastPromptTokens(85_000)
        h.server.clear()
        h.startTurn(manager, "wait, then stop", replies: [BackgroundPruneSelftestHarness.chat("done", prompt: 100)])
        _ = await h.waitUntil { h.eventCount("bgprune.wait.begin") == 1 }
        let reply = await manager.bgPruneTestCommand("/stop")
        let idle = await manager._testAwaitIdle(timeout: 20)
        h.router.gate.release()
        let released = await h.waitUntil { manager.bgPruneTestPhase == "none" }
        h.check("B13 /stop during the wait: the run exits, no inline prune, no request", idle
                && h.eventCount(prefix: "bgprune.inline") == 0 && h.mainRequests.isEmpty && h.router.summaries == 1,
                "\(h.allEvents)")
        h.check("B13 /stop reports the cancelled background prune", reply.contains("The background prune being prepared was cancelled (nothing changed)."), reply)
        h.check("B13 the cancelled worker is released without applying", released && h.prunedIds(manager).isEmpty
                && h.eventCount("bgprune.terminated.stop") == 1 && !manager.bgPruneTestFallbackDue, "\(h.allEvents)")
    }

    /// B4b(d) at T1 + B6 model change: a job that becomes ready between
    /// T0 and T1 is applied at T1; when the request still is ≥ C (the
    /// identity's window shrank meanwhile) the inline block runs once,
    /// before the send; a sufficient apply runs none.
    @MainActor static func insufficientApply(_ h: BackgroundPruneSelftestHarness) async {
        for shrink in [false, true] {
            let manager = await h.freshManager(history: h.prunableHistory())
            _ = await h.frozenRunningJob(manager)
            let gate = BackgroundPruneSelftestGate()
            ConversationManager.bgPruneHoldForTesting = { point in if point == "t1.entry" { await gate.awaitRelease() } }
            manager.bgPruneTestSetLastPromptTokens(1_000)
            h.server.clear()
            h.clearEvents()
            h.observeMainRequests()
            h.startTurn(manager, shrink ? "window shrank" : "sufficient apply", replies: [BackgroundPruneSelftestHarness.chat("done", prompt: 100)])
            _ = await h.waitUntil { gate.arrived == 1 }
            h.router.gate.release()
            _ = await h.waitPhase(manager, "ready")
            if shrink { capped(h, 4_000) }
            gate.release()
            _ = await manager._testAwaitIdle(timeout: 40)
            ConversationManager.bgPruneHoldForTesting = nil
            h.server.requestObserver = nil
            if shrink {
                h.check("B4b(d)/B6 insufficient apply (re-capped C) → the inline block ran once, before the send",
                        h.eventCount("bgprune.applied") == 1 && h.eventCount("bgprune.inline") == 1 && h.logged("bgprune.inline"),
                        "\(h.log.all)")
            } else {
                h.check("B4b(d) negative: a sufficient apply runs no inline block",
                        h.eventCount("bgprune.applied") == 1 && h.eventCount(prefix: "bgprune.inline") == 0, "\(h.allEvents)")
            }
            BackgroundPruneContextWindow.overrides = [:]
        }
    }

    /// L-maxchange: the maximum is read live; a running job is not re-frozen.
    @MainActor static func liveMaximum(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager)
        let manifest = manager.bgPruneTestJobManifest
        try? KeychainHelper.save(key: KeychainHelper.maxContextTokensKey, value: "30000")
        let lowered = await manager.bgPruneTestLiveLimits()
        h.check("L-maxchange lowered maximum moves C (30k → 130k) at the next evaluation", lowered == (30_000, 130_000), "\(lowered)")
        try? KeychainHelper.save(key: KeychainHelper.maxContextTokensKey, value: "50000")
        manager.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(manager, "raised maximum while running")
        h.check("L-maxchange raised maximum: no second job, no re-freeze", h.eventCount(prefix: "bgprune.freeze") == 1
                && manager.bgPruneTestJobManifest == manifest)
        h.router.gate.release()
        _ = await h.waitPhase(manager, "ready")
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "apply the frozen range")
        h.check("L-maxchange the frozen range is applied as frozen", h.eventCount("bgprune.applied") == 1
                && Set(manifest).isSubset(of: Set(manager._testMessages.map(\.id))))
        try? KeychainHelper.save(key: KeychainHelper.maxContextTokensKey, value: String(h.maximum))
        try? KeychainHelper.save(key: KeychainHelper.maxContextTokensKey, value: String(Int.max))
        let extreme = await manager.bgPruneTestLiveLimits()
        h.check("v4.1 an absurd stored maximum saturates (+100k never traps)", extreme.ceiling == Int.max)
        try? KeychainHelper.save(key: KeychainHelper.maxContextTokensKey, value: String(h.maximum))
    }
}
