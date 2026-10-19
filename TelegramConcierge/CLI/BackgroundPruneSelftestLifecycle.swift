import Foundation

/// Commands and lifecycle (§12, §4): OFF on running / uncooperative /
/// applying jobs (O5, O5b, O5c), OFF→ON while draining, /stop on running
/// and applying jobs, /restart gating, generation bumps (wipe/import),
/// the command itself and the status line.
enum BackgroundPruneSelftestLifecycle {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        await command(h)
        await offRunning(h)
        await offUncooperative(h)
        await offDuringApply(h, holdPoint: "apply.lookup")
        await offDuringApply(h, holdPoint: "apply.save")
        await stopRunningAndApplying(h)
        await generation(h)
    }

    /// History with one describable file (a send_document_to_chat output)
    /// in a message the prune removes.
    @MainActor static func describableHistory(_ h: BackgroundPruneSelftestHarness, file: String) -> [Message] {
        let path = h.filesRoot.appendingPathComponent(file)
        try? "Quarterly figures for the fixture company: revenue up 3%.\n".write(to: path, atomically: true, encoding: .utf8)
        var history = h.prunableHistory()
        let args = "{\"file_path\":\"\(path.path)\"}"
        history[1].toolInteractions.append(h.toolRound(id: "doc-call", size: 40, name: "send_document_to_chat", args: args))
        return history
    }

    @MainActor static func command(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory(pairs: 2, size: 200), switchOn: nil)
        let help = await manager.bgPruneTestCommand("/prunebackground")
        h.check("§13 /prunebackground shows the state, default off, and the OFF note",
                help.contains("Background pruning: OFF (default: off)") && help.contains("Turning it off cancels a summary being prepared."), help)
        let on = await manager.bgPruneTestCommand("/prunebackground on")
        h.check("D1 /prunebackground on persists ON", on.contains("Background pruning: ON")
                && UserDefaults.standard.bool(forKey: ConversationManager.backgroundPruneDefaultsKey), on)
        let status = await manager.bgPruneTestCommand("/status")
        h.check("§13 /status line while ON", status.contains("✂️ Background pruning: on"), status)
        let again = await manager.bgPruneTestCommand("/prunebackground on")
        h.check("§12 repeated on is a no-op", again.contains("already ON"), again)
        let off = await manager.bgPruneTestCommand("/prunebackground off")
        h.check("§12.2 OFF with an empty slot completes at once", off == "Background pruning: OFF."
                && !manager.bgPruneTestPendingOff && h.eventCount("bgprune.off.completed") == 1, off)
        let usage = await manager.bgPruneTestCommand("/prunebackground maybe")
        h.check("§12 usage on a bad argument", usage.hasPrefix("Usage: /prunebackground on|off"), usage)
        let statusOff = await manager.bgPruneTestCommand("/status")
        h.check("O3 /status back to today's text after a completed OFF", !statusOff.contains("Background pruning"), statusOff)
    }

    /// O5(a): OFF on a running job — drained, nothing applied, nothing saved.
    @MainActor static func offRunning(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: describableHistory(h, file: "off-running.txt"))
        _ = await h.frozenRunningJob(manager)
        let reply = await manager.bgPruneTestCommand("/prunebackground off")
        h.check("O5 OFF on a running job: drained, exact reply", reply == "Background pruning: OFF. The summary being prepared was cancelled; no prune was applied.", reply)
        h.check("O5 completed OFF: slot empty, nothing owed, pending cleared", manager.bgPruneTestPhase == "none"
                && !manager.bgPruneTestFallbackDue && !manager.bgPruneTestPendingOff && h.eventCount("bgprune.off.completed") == 1)
        h.router.gate.release()
        await h.sleep(0.3)
        let described = await manager.bgPruneTestDescription("off-running.txt")
        h.check("O5 nothing applied, no description saved", h.prunedIds(manager).isEmpty
                && described == nil && h.router.descriptions == 0)
        manager.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(manager, "after OFF")
        h.check("O5 after OFF the boundary is today's inline prune (no job)", manager.bgPruneTestPhase == "none"
                && h.eventCount(prefix: "bgprune.freeze") == 1 && h.prunedIds(manager).count >= 6)
    }

    /// O5c: the OFF reply never claims termination when only the phase
    /// changed; OFF→ON while draining starts nothing until release.
    @MainActor static func offUncooperative(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        let hold = BackgroundPruneSelftestGate()
        ConversationManager.bgPruneHoldForTesting = { point in if point == "worker.summary" { await hold.awaitRelease() } }
        ConversationManager.bgPruneDrainSecondsForTesting = 0.5
        manager.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(manager, "freeze with an uncooperative worker")
        let reply = await manager.bgPruneTestCommand("/prunebackground off")
        h.check("O5c OFF reply says it is still finishing (drain wait, not the phase change)",
                reply.contains("it is still finishing") && manager.bgPruneTestPendingOff
                && manager.bgPruneTestPhase == "retiring:off", reply)
        h.check("O5c memory commands still refused (the worker's activity is alive)", manager.bgPruneTestMaintenanceKinds.contains(.pruning))
        let restart = await manager.bgPruneTestCommand("/restart")
        h.check("B14 /restart refused while retiring", restart.contains("A background prune is finishing"), restart)
        let on = await manager.bgPruneTestCommand("/prunebackground on")
        h.check("O5 OFF→ON while draining: ON, but no job until release", on.contains("still being cancelled"), on)
        manager.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(manager, "over the maximum while the old job drains")
        h.check("O5 a retiring slot → today's inline prune, no new freeze", h.eventCount(prefix: "bgprune.freeze") == 1
                && h.eventCount("bgprune.inline.unusable") == 1 && h.prunedIds(manager).count >= 6 && manager.bgPruneTestInlineDebtConsumed)
        hold.release()
        let released = await h.waitUntil { manager.bgPruneTestPhase == "none" }
        h.check("O5 release after OFF→ON logs 'superseded'; nothing owed; the old job never published", released
                && h.eventCount("bgprune.off.superseded") == 1 && !manager.bgPruneTestFallbackDue
                && h.eventCount("bgprune.applied") == 0, "\(h.allEvents)")
        ConversationManager.bgPruneHoldForTesting = nil
        ConversationManager.bgPruneDrainSecondsForTesting = nil
    }

    /// O5b: OFF during an apply (held at the fill-only lookup, or at the
    /// first submitted save): revoked, no publication, exact wording.
    @MainActor static func offDuringApply(_ h: BackgroundPruneSelftestHarness, holdPoint: String) async {
        let file = "apply-\(holdPoint).txt"
        let manager = await h.freshManager(history: describableHistory(h, file: file))
        _ = await h.frozenRunningJob(manager, holdSummary: false)
        _ = await h.waitPhase(manager, "ready")
        let workerSaved = await manager.bgPruneTestDescription(file)
        h.check("O5b[\(holdPoint)] precondition: the worker described the file (write-free)",
                h.router.descriptions == 1 && workerSaved == nil)
        let hold = BackgroundPruneSelftestGate()
        ConversationManager.bgPruneHoldForTesting = { point in if point == holdPoint { await hold.awaitRelease() } }
        manager.bgPruneTestSetLastPromptTokens(1_000)
        let historyBefore = h.encoded(manager._testMessages)
        h.startTurn(manager, "apply turn", replies: [BackgroundPruneSelftestHarness.chat("done", prompt: 100)])
        _ = await h.waitUntil { hold.arrived == 1 }
        h.check("O5b[\(holdPoint)] the apply is in progress (applying; the /restart and /upgrade gate is busy)",
                manager.bgPruneTestPhase == "applying" && manager.bgPruneTestBlocksExit)
        async let offReply = manager.bgPruneTestCommand("/prunebackground off")
        await h.sleep(0.3)
        h.check("O5b[\(holdPoint)] OFF never releases an applying slot early", manager.bgPruneTestPhase == "applying" && manager.bgPruneTestPendingOff)
        hold.release()
        let reply = await offReply
        let idle = await manager._testAwaitIdle(timeout: 30)
        ConversationManager.bgPruneHoldForTesting = nil
        let saved = holdPoint == "apply.save"
        h.check("O5b[\(holdPoint)] the revoked apply published no history", h.prunedIds(manager).isEmpty
                && h.eventCount("bgprune.apply.revoked") == 1 && h.eventCount("bgprune.applied") == 0, "\(h.allEvents)")
        let stored = await manager.bgPruneTestDescription(file)
        h.check("O5b[\(holdPoint)] \(saved ? "the submitted save completed" : "no save after the revocation")",
                (stored != nil) == saved)
        let expected = saved
            ? "Background pruning: OFF. The prune being applied was stopped before it changed the conversation, 1 file description it had already saved is kept."
            : "Background pruning: OFF. The prune being applied was stopped before it changed the conversation."
        h.check("O5b[\(holdPoint)] exact OFF wording", reply == expected, reply)
        h.check("O5b[\(holdPoint)] the user's run was not cancelled", idle && h.mainRequests.count >= 1 && manager._testLastError == nil,
                String(describing: manager._testLastError))
        h.check("O5b[\(holdPoint)] OFF completed only after the apply returned; activities and pin released once",
                h.eventCount("bgprune.off.completed") == 1 && h.eventCount("bgprune.released") == 1
                && !manager.bgPruneTestMaintenanceKinds.contains(.pruning) && !manager.bgPruneTestFallbackDue)
        _ = historyBefore
    }

    /// B13: /stop on a running job and during an apply.
    @MainActor static func stopRunningAndApplying(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager)
        let reply = await manager.bgPruneTestCommand("/stop")
        h.check("B13 /stop cancels a running worker and says nothing changed",
                reply.contains("The background prune being prepared was cancelled (nothing changed)."), reply)
        h.router.gate.release()
        let released = await h.waitUntil { manager.bgPruneTestPhase == "none" }
        h.check("B13 the stopped worker is released, nothing owed", released && !manager.bgPruneTestFallbackDue && h.prunedIds(manager).isEmpty)

        let ready = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(ready, holdSummary: false)
        _ = await h.waitPhase(ready, "ready")
        let keep = await ready.bgPruneTestCommand("/stop")
        h.check("B13 /stop keeps a ready job (applied at the next turn)", ready.bgPruneTestPhase == "ready"
                && !keep.contains("background prune"), keep)
        h.check("B14 a ready job does not block /restart", !ready.bgPruneTestBlocksExit)

        let applying = await h.freshManager(history: describableHistory(h, file: "stop-apply.txt"))
        _ = await h.frozenRunningJob(applying, holdSummary: false)
        _ = await h.waitPhase(applying, "ready")
        let hold = BackgroundPruneSelftestGate()
        ConversationManager.bgPruneHoldForTesting = { point in if point == "apply.lookup" { await hold.awaitRelease() } }
        applying.bgPruneTestSetLastPromptTokens(1_000)
        h.startTurn(applying, "apply then stop", replies: [BackgroundPruneSelftestHarness.chat("done", prompt: 100)])
        _ = await h.waitUntil { hold.arrived == 1 }
        async let stopReply = applying.bgPruneTestCommand("/stop")
        await h.sleep(0.2)
        hold.release()
        let text = await stopReply
        _ = await applying._testAwaitIdle(timeout: 20)
        ConversationManager.bgPruneHoldForTesting = nil
        h.check("B13 /stop during an apply: not published, abandon + owed inline decision", applying.bgPruneTestPhase == "none"
                && h.prunedIds(applying).isEmpty && applying.bgPruneTestFallbackDue && h.eventCount("bgprune.abandon.stopped") == 1,
                "\(h.allEvents)")
        h.check("B13 /stop reply names the unapplied prune", text.contains("The background prune was not applied."), text)
    }

    /// §12.1: wipe / Mind restore bump the generation; a ready job is
    /// released; a running job is retired and owes nothing.
    @MainActor static func generation(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager, holdSummary: false)
        _ = await h.waitPhase(manager, "ready")
        let before = manager.bgPruneTestGeneration
        manager.bgPruneTestReplaceHistory()
        h.check("§12.1 generation bump releases a ready job", manager.bgPruneTestGeneration == before + 1
                && manager.bgPruneTestPhase == "none" && h.eventCount("bgprune.released") == 1)

        let running = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(running)
        running.bgPruneTestReplaceHistory()
        h.check("§12.1 generation bump retires a running job", running.bgPruneTestPhase == "retiring:generation")
        h.router.gate.release()
        let released = await h.waitUntil { running.bgPruneTestPhase == "none" }
        h.check("O6 the stale termination publishes nothing and owes nothing", released && !running.bgPruneTestFallbackDue
                && h.eventCount("bgprune.applied") == 0 && h.eventCount("bgprune.terminated.generation") == 1)
    }
}
