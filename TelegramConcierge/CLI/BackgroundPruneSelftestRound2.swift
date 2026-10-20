import Foundation

/// Codex implementation review round 1: the reproduced traces (R1 OFF during
/// a held main response, R2a direct inline paths, R2b M before a forced
/// final) and the essential additions of its answer 4. Every inline check
/// counts actual helper entries (`bgprune.helper.*`), logged at the call
/// into today's prune helper, not the ledger event.
enum BackgroundPruneSelftestRound2 {
    static let errorBody = "{\"error\":{\"message\":\"This model's maximum context length was exceeded\",\"code\":400}}"

    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        await offDuringHeldToolLoopResponse(h)
        await offDuringHeldFinalResponse(h)
        await directInlineSharesAllowance(h)
        await midLoopSharesFinalAllowance(h)
        await insufficientApplyAtFinal(h)
        await inlineErrorPreventsDispatch(h)
        await committedDuringNotice(h)
        await freezeAwaitChanges(h)
        await postRenameWriteFault(h)
        await restartDropsJobs(h)
    }

    // MARK: helpers

    @MainActor static func helperEntries(_ h: BackgroundPruneSelftestHarness) -> Int {
        h.eventCount("bgprune.helper.pre-request") + h.eventCount("bgprune.helper.mid-loop")
    }

    /// Helper entries logged before the `n`-th main request (1-based).
    @MainActor static func helperEntriesBeforeRequest(_ h: BackgroundPruneSelftestHarness, _ n: Int) -> Int {
        var seen = 0
        var helpers = 0
        for item in h.log.all {
            if item == "request.main" { seen += 1; if seen == n { break } }
            if item.hasPrefix("bgprune.helper.") { helpers += 1 }
        }
        return helpers
    }

    /// Main requests wait on `gate` (other requests are routed as usual).
    @MainActor static func holdMainRequests(_ h: BackgroundPruneSelftestHarness, _ gate: BackgroundPruneSelftestGate) {
        let router = h.router
        let log = h.log
        h.server.requestObserver = nil
        h.server.router = { request in
            if BackgroundPruneSelftestRouter.isMain(request) {
                log.append("request.main")
                gate.wait()
                return nil
            }
            return router.route(request)
        }
    }

    @MainActor static func readCall(_ h: BackgroundPruneSelftestHarness, _ id: String) -> (id: String, name: String, args: [String: Any]) {
        BackgroundPruneSelftestMidLoop.readCall(h, id)
    }

    @MainActor static func snapshotCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: PruneArchiveStore.root.path).count) ?? 0
    }

    // MARK: R1

    /// R1: OFF completes while the main request is held; the request then
    /// fails in band. No convergence (no summary, no resend, no bound).
    @MainActor static func offDuringHeldToolLoopResponse(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        manager.bgPruneTestSetLastPromptTokens(1_000)
        let gate = BackgroundPruneSelftestGate()
        holdMainRequests(h, gate)
        h.server.script([errorBody, BackgroundPruneSelftestHarness.chat("resent after OFF", prompt: 100)], statuses: [400, 200])
        manager._testStartTurn(for: Message(role: .user, content: "held request, then OFF"))
        _ = await h.waitUntil { gate.arrived == 1 }
        let reply = await manager.bgPruneTestCommand("/prunebackground off")
        let offDone = manager.bgPruneTestPhase == "none" && !manager.bgPruneTestPendingOff
        gate.release()
        _ = await manager._testAwaitIdle(timeout: 30)
        h.check("R1 OFF completes while the main request is held", reply == "Background pruning: OFF." && offDone, reply)
        h.check("R1 the in-band failure after a completed OFF surfaces as OFF: no reduction, no summary, no resend",
                (manager._testLastError ?? "").contains("400") && h.eventCount("bgprune.converge.reduce") == 0
                && h.router.summaries == 0 && h.mainRequests.count == 1 && helperEntries(h) == 0
                && manager.bgPruneTestObservedBounds.isEmpty && h.eventCount("bgprune.converge.disengaged") == 1,
                "events \(h.allEvents) main \(h.mainRequests.count) error \(String(describing: manager._testLastError))")
    }

    /// R1 at a forced final: OFF completes while attempt 0 is held.
    @MainActor static func offDuringHeldFinalResponse(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        try? AgentTurnOverrides.setOverride(1, forAgent: "main")
        defer { try? AgentTurnOverrides.setOverride(nil, forAgent: "main") }
        manager.bgPruneTestSetLastPromptTokens(1_000)
        let gate = BackgroundPruneSelftestGate()
        let router = h.router
        let log = h.log
        // Hold only the second main request (the forced final).
        let count = BackgroundPruneSelftestLog()
        h.server.router = { request in
            if BackgroundPruneSelftestRouter.isMain(request) {
                log.append("request.main")
                count.append("x")
                if count.all.count == 2 { gate.wait() }
                return nil
            }
            return router.route(request)
        }
        h.server.script([BackgroundPruneSelftestHarness.tools([readCall(h, "ff-call-1")], prompt: 1_000), errorBody,
                         BackgroundPruneSelftestHarness.chat("resent final", prompt: 100)], statuses: [200, 400, 200])
        manager._testStartTurn(for: Message(role: .user, content: "one round, then a held forced final"))
        _ = await h.waitUntil { gate.arrived == 1 }
        let reply = await manager.bgPruneTestCommand("/prunebackground off")
        gate.release()
        _ = await manager._testAwaitIdle(timeout: 30)
        h.check("R1 forced final: OFF during the held attempt → original error, no convergence, no inline",
                reply == "Background pruning: OFF." && (manager._testLastError ?? "").contains("400")
                && h.eventCount("bgprune.converge.reduce") == 0 && h.mainRequests.count == 2 && helperEntries(h) == 0
                && h.router.summaries == 0,
                "reply \(reply) events \(h.allEvents) main \(h.mainRequests.count) error \(String(describing: manager._testLastError))")
    }

    // MARK: R2

    /// R2a: a direct T1 inline path consumes round 1's allowance; D and
    /// convergence of the same request get no second inline block.
    @MainActor static func directInlineSharesAllowance(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        let hold = BackgroundPruneSelftestGate()
        ConversationManager.bgPruneHoldForTesting = { point in if point == "worker.summary" { await hold.awaitRelease() } }
        ConversationManager.bgPruneDeadlineSecondsForTesting = 0.5
        manager.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(manager, "freeze with an uncooperative worker")
        _ = await h.waitUntil { manager.bgPruneTestPhase == "retiring:deadline" }
        try? KeychainHelper.save(key: KeychainHelper.targetContextTokensKey, value: "52000")
        BackgroundPruneContextWindow.overrides = [h.model: 50_000 + 32_768]
        h.clearEvents()
        h.server.clear()
        h.observeMainRequests()
        manager.bgPruneTestSetLastPromptTokens(60_000)
        h.server.script([errorBody], statuses: [400])
        manager._testStartTurn(for: Message(role: .user, content: "T1 direct inline, D at the ceiling, in-band failure"))
        _ = await manager._testAwaitIdle(timeout: 40)
        h.server.requestObserver = nil
        h.check("R2a one helper entry for round 1 (T1's direct inline); D and convergence find the allowance used",
                helperEntries(h) == 1 && h.eventCount("bgprune.helper.pre-request") == 1
                && helperEntriesBeforeRequest(h, 1) == 1 && h.eventCount("bgprune.admit.overceiling") >= 1
                && h.eventCount("bgprune.converge.resent") == 0 && (manager._testLastError ?? "").contains("400"),
                "events \(h.allEvents) error \(String(describing: manager._testLastError))")
        hold.release()
        _ = await h.waitUntil { manager.bgPruneTestPhase == "none" }
        ConversationManager.bgPruneHoldForTesting = nil
        ConversationManager.bgPruneDeadlineSecondsForTesting = nil
        try? KeychainHelper.save(key: KeychainHelper.targetContextTokensKey, value: String(h.target))
        BackgroundPruneContextWindow.overrides = [:]
    }

    /// R2b + B4b(j): M's inline block belongs to the forced final that
    /// follows it; the final's convergence gets no second block, and M's
    /// own result handling does not run after R's inline step.
    @MainActor static func midLoopSharesFinalAllowance(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        try? AgentTurnOverrides.setOverride(1, forAgent: "main")
        defer { try? AgentTurnOverrides.setOverride(nil, forAgent: "main") }
        let toolGate = BackgroundPruneSelftestGate()
        ToolExecutor.toolBodyHoldForTesting = { name in if name == "read_file" { toolGate.wait() } }
        manager.bgPruneTestSetLastPromptTokens(60_000)
        h.observeMainRequests()
        let refusal = BackgroundPruneSelftestHarness.tools([(id: "refused-1", name: "read_file",
                                                             args: ["file_path": String(repeating: "x", count: 180_000)])], prompt: 1_000)
        h.server.script([BackgroundPruneSelftestHarness.tools([readCall(h, "r2b-call-1")], prompt: 1_000), refusal, errorBody],
                        statuses: [200, 200, 400])
        manager._testStartTurn(for: Message(role: .user, content: "M before a forced final"))
        let ready = await h.waitUntil { manager.bgPruneTestPhase == "ready" && toolGate.arrived == 1 }
        BackgroundPruneContextWindow.overrides = [h.model: 32_768 + 1_000]
        toolGate.release()
        _ = await manager._testAwaitIdle(timeout: 40)
        ToolExecutor.toolBodyHoldForTesting = nil
        BackgroundPruneContextWindow.overrides = [:]
        h.server.requestObserver = nil
        h.check("R2b precondition: job ready while the round's tool runs", ready)
        h.check("R2b M's inline block uses the forced final's allowance; the final's convergence runs none",
                h.eventCount("bgprune.applied") == 1 && h.eventCount("bgprune.helper.mid-loop") == 1
                && h.eventCount("bgprune.converge.reduce") == 1 && h.eventCount("bgprune.converge.resent") == 0
                && h.mainRequests.count == 3 && (manager._testLastError ?? "").contains("400"),
                "events \(h.allEvents) main \(h.mainRequests.count) error \(String(describing: manager._testLastError))")
        h.check("B4b(j) M after an insufficient apply: R's inline block ran; the applied-result handling did not run again",
                h.eventCount("bgprune.handling.applied") == 0)
    }

    /// B4b(d-ff): a ready job applied at a forced-final D whose rebuilt
    /// request (refusal suffix and tail included) is still ≥ C runs the
    /// inline block once, before that attempt is sent.
    @MainActor static func insufficientApplyAtFinal(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        try? AgentTurnOverrides.setOverride(1, forAgent: "main")
        defer { try? AgentTurnOverrides.setOverride(nil, forAgent: "main") }
        let admitGate = BackgroundPruneSelftestGate()
        ConversationManager.bgPruneHoldForTesting = { point in if point == "admit.round2" { await admitGate.awaitRelease() } }
        h.router.holdSummaries = [1]
        manager.bgPruneTestSetLastPromptTokens(60_000)
        h.observeMainRequests()
        h.server.script([BackgroundPruneSelftestHarness.tools([readCall(h, "dff-call-1")], prompt: 1_000),
                         BackgroundPruneSelftestHarness.chat("final", prompt: 100)])
        manager._testStartTurn(for: Message(role: .user, content: "forced final with a job ready at D"))
        let atD = await h.waitUntil { admitGate.arrived == 1 }
        h.router.gate.release()
        let ready = await h.waitPhase(manager, "ready")
        BackgroundPruneContextWindow.overrides = [h.model: 32_768 + 1_000]
        admitGate.release()
        _ = await manager._testAwaitIdle(timeout: 40)
        ConversationManager.bgPruneHoldForTesting = nil
        BackgroundPruneContextWindow.overrides = [:]
        h.server.requestObserver = nil
        h.check("B4b(d-ff) precondition: forced-final D reached with a running job that then became ready", atD && ready)
        h.check("B4b(d-ff) applied at the final's D, still ≥ C → one inline block before the final request",
                h.eventCount("bgprune.applied") == 1 && h.eventCount("bgprune.helper.mid-loop") == 1
                && helperEntriesBeforeRequest(h, 2) == 1 && h.mainRequests.count == 2,
                "events \(h.allEvents) main \(h.mainRequests.count)")
    }

    // MARK: Answer-4 additions

    /// B4b(k): an error thrown by the inline block propagates and nothing is sent.
    @MainActor static func inlineErrorPreventsDispatch(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        BackgroundPruneContextWindow.overrides = [h.model: 50_000 + 32_768]   // headroom 10k → inline
        let armed = BackgroundPruneSelftestGate()
        ConversationManager.beforePruneHistoryWriteForTesting = { armed.release() }
        ConversationManager.historyWriteFaultForTesting = {
            if armed.isReleased { throw PruneArchiveStore.Failure("injected inline write fault") }
        }
        manager.bgPruneTestSetLastPromptTokens(60_000)
        h.server.script([BackgroundPruneSelftestHarness.chat("should not be sent", prompt: 100)])
        manager._testStartTurn(for: Message(role: .user, content: "inline prune that fails"))
        _ = await manager._testAwaitIdle(timeout: 30)
        ConversationManager.historyWriteFaultForTesting = nil
        ConversationManager.beforePruneHistoryWriteForTesting = nil
        BackgroundPruneContextWindow.overrides = [:]
        h.check("B4b(k) the inline block's error propagates; no main request is sent",
                h.eventCount("bgprune.helper.pre-request") == 1 && h.mainRequests.isEmpty
                && (manager._testLastError ?? "").contains("Could not commit pruned conversation"),
                "error \(String(describing: manager._testLastError)) main \(h.mainRequests.count) events \(h.allEvents)")
    }

    /// §8.3 step 9: OFF during the post-commit notice await → "finished
    /// first", outcome applied, nothing owed, no abandon.
    @MainActor static func committedDuringNotice(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager, holdSummary: false)
        _ = await h.waitPhase(manager, "ready")
        let noticeCall = h.channel.callCount + 1
        h.channel.hold(call: noticeCall)
        manager.bgPruneTestSetLastPromptTokens(1_000)
        h.startTurn(manager, "apply with a held notice", replies: [BackgroundPruneSelftestHarness.chat("done", prompt: 100)])
        _ = await h.waitUntil { h.channel.hasStarted(call: noticeCall) }
        async let offReply = manager.bgPruneTestCommand("/prunebackground off")
        await h.sleep(0.3)
        h.channel.release(call: noticeCall)
        let reply = await offReply
        _ = await manager._testAwaitIdle(timeout: 30)
        h.check("§8.3 OFF during the notice await: the committed prune is reported as finished first",
                reply == "Background pruning: OFF. The prune that was being applied finished first."
                && manager.bgPruneTestLastApply?.outcome == .applied && !manager.bgPruneTestFallbackDue
                && h.eventCount(prefix: "bgprune.abandon") == 0 && h.prunedIds(manager).count >= 6, reply)
    }

    /// B9: /stop, OFF and a generation bump while the freeze is suspended
    /// after its awaits.
    @MainActor static func freezeAwaitChanges(_ h: BackgroundPruneSelftestHarness) async {
        for variant in ["stop", "off", "generation"] {
            let manager = await h.freshManager(history: h.prunableHistory())
            let gate = BackgroundPruneSelftestGate()
            ConversationManager.bgPruneHoldForTesting = { point in if point == "freeze.afterAwait" { await gate.awaitRelease() } }
            let before = snapshotCount()
            manager.bgPruneTestSetLastPromptTokens(60_000)
            h.startTurn(manager, "freeze held after its awaits (\(variant))", replies: [BackgroundPruneSelftestHarness.chat("done", prompt: 100)])
            _ = await h.waitUntil { gate.arrived == 1 }
            switch variant {
            case "stop": _ = await manager.bgPruneTestCommand("/stop")
            case "off": _ = await manager.bgPruneTestCommand("/prunebackground off")
            default: manager.bgPruneTestReplaceHistory()
            }
            gate.release()
            _ = await manager._testAwaitIdle(timeout: 30)
            ConversationManager.bgPruneHoldForTesting = nil
            if variant == "stop" {
                h.check("B9 /stop during the freeze's await: no job, no snapshot, no worker, no activity, no inline prune",
                        manager.bgPruneTestPhase == "none" && snapshotCount() == before && h.router.summaries == 0
                        && !manager.bgPruneTestMaintenanceKinds.contains(.pruning) && helperEntries(h) == 0,
                        "phase \(manager.bgPruneTestPhase) snapshots \(snapshotCount() - before) events \(h.allEvents)")
            } else {
                h.check("B9 \(variant) during the freeze's await: no job; today's inline prune instead",
                        manager.bgPruneTestPhase == "none" && h.eventCount("bgprune.freeze.recheck-failed") == 1
                        && h.eventCount("bgprune.helper.pre-request") == 1 && h.router.summaries == 1,
                        "events \(h.allEvents)")
            }
        }
    }

    /// F5b: a post-rename (fsync) failure of the apply's checked write.
    @MainActor static func postRenameWriteFault(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager, holdSummary: false)
        _ = await h.waitPhase(manager, "ready")
        let armed = BackgroundPruneSelftestGate()
        ConversationManager.beforePruneHistoryWriteForTesting = { armed.release() }
        ConversationManager.historyPostWriteFaultForTesting = {
            if armed.isReleased, ConversationManager.beforePruneHistoryWriteForTesting != nil {
                ConversationManager.beforePruneHistoryWriteForTesting = nil
                throw PruneArchiveStore.Failure("injected post-rename fsync fault")
            }
        }
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "post-rename fault")
        ConversationManager.historyPostWriteFaultForTesting = nil
        ConversationManager.beforePruneHistoryWriteForTesting = nil
        let disk = h.diskHistory()
        h.check("F5b post-rename fault: memory keeps the live history, fallback owed, no cleanup claimed",
                h.prunedIds(manager).isEmpty && manager.bgPruneTestFallbackDue
                && manager.bgPruneTestLastApply?.outcome == .writeFailed)
        h.check("F5b the disk holds a complete old or new history (today's checked-write semantics)",
                disk.count >= 16)
    }

    /// B12/O7: a restart drops a running or ready job; disk history is the
    /// last saved one; the snapshot stays an ordinary snapshot; the next
    /// over-maximum boundary re-triggers normally.
    @MainActor static func restartDropsJobs(_ h: BackgroundPruneSelftestHarness) async {
        for held in [true, false] {
            let manager = await h.freshManager(history: h.prunableHistory())
            _ = await h.frozenRunningJob(manager, holdSummary: held)
            if !held { _ = await h.waitPhase(manager, "ready") }
            let disk = h.encoded(h.diskHistory())
            let restarted = ConversationManager()
            await restarted._testPrepareScriptedProvider(apiKey: h.apiKey)
            restarted._svRegisterChannel(h.channel)
            restarted._svSetLastUserAddress(h.telegramAddress)
            h.check("B12 restart with a \(held ? "running" : "ready") job: no job carried over, history as last saved",
                    restarted.bgPruneTestPhase == "none" && h.encoded(restarted._testMessages) == disk
                    && h.prunedIds(restarted).isEmpty)
            h.clearEvents()
            restarted.bgPruneTestSetLastPromptTokens(60_000)
            h.server.script([BackgroundPruneSelftestHarness.chat("after restart", prompt: 100)])
            restarted._testStartTurn(for: Message(role: .user, content: "over the maximum after restart"))
            _ = await restarted._testAwaitIdle(timeout: 30)
            h.check("B12 the next over-maximum boundary freezes normally after restart", h.eventCount("bgprune.freeze.pre-request") == 1)
            h.router.gate.release()
            _ = await h.waitUntil { manager.bgPruneTestPhase == "none" || manager.bgPruneTestPhase == "ready" }
        }
    }
}
