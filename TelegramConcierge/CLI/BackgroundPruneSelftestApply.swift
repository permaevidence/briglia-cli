import Foundation

/// Freeze (§5), worker (§6) and apply (§8): B3, T0/T1 apply, the §8.2 guard
/// (F2), write-set assertion (F3), checked-write failure (F5), token resets
/// (B10) and the frozen-transaction equivalence with today's prune (F1).
enum BackgroundPruneSelftestApply {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        await freezeAndApply(h)
        await equivalence(h)
        await guardAbandon(h)
        await writeSet(h)
        await writeFailure(h)
        await readyBetweenT0AndT1(h)
    }

    /// B3 + T0 apply + B10.
    @MainActor static func freezeAndApply(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        let seeded = manager._testMessages
        h.router.holdSummaries = [1]
        manager.bgPruneTestSetLastPromptTokens(60_000)
        let idle = await h.turn(manager, "freeze turn")
        h.check("B3 the turn completes without waiting for the summary", idle && manager.bgPruneTestPhase == "running",
                "idle \(idle), phase \(manager.bgPruneTestPhase)")
        h.check("B3 the request carried the unchanged conversation (old tool output still present)",
                h.mainRequests.count == 1 && h.bodyText(h.mainRequests[0]).contains("RESULT-h-call-0"))
        h.check("B3 freeze changed no history byte", h.encoded(Array(manager._testMessages.prefix(seeded.count))) == h.encoded(seeded))
        h.check("B3 no prune notice at freeze (Q3: at apply)", h.noticeTexts.isEmpty, "\(h.channel.delivered)")
        h.check("B3 the worker holds a .pruning activity", manager.bgPruneTestMaintenanceKinds.contains(.pruning))
        h.check("B3 /restart refused while the worker runs",
                (await manager.bgPruneTestCommand("/restart")).contains("A background prune is finishing"))
        let status = await manager.bgPruneTestCommand("/status")
        h.check("§13 /status: preparing a prune", status.contains("✂️ Background pruning: on (preparing a prune"), status)
        let snapshotId = manager.bgPruneTestSnapshotId
        h.check("§5 a pinned freeze snapshot exists", snapshotId != nil
                && FileManager.default.fileExists(atPath: PruneArchiveStore.root.path))
        // The worker finishes → ready; nothing is published until a boundary.
        h.router.gate.release()
        let ready = await h.waitPhase(manager, "ready")
        h.check("§4.3 worker terminated with a result → ready; activity ended", ready
                && !manager.bgPruneTestMaintenanceKinds.contains(.pruning))
        h.check("§8 nothing applied before a boundary", h.prunedIds(manager).isEmpty && h.summaryAnchors(manager).isEmpty)
        let readyStatus = await manager.bgPruneTestCommand("/status")
        h.check("§13 /status: ready", readyStatus.contains("(ready, applies at the next step)"), readyStatus)
        let manual = await manager.bgPruneTestCommand("/prune")
        h.check("B15 manual /prune refused while a prune is ready", manual.contains("A background prune will apply at your next message"), manual)
        let trigger = manager._testMessages.first { $0.content == "freeze turn" }
        h.check("§8.2 the trigger's measuredTokens changed after the freeze (allow-listed field)", trigger?.measuredTokens != nil)
        // Next turn: T0 applies.
        h.server.clear()
        let applied = await h.turn(manager, "apply turn")
        h.check("§8 T0 applies the ready job", applied && manager.bgPruneTestPhase == "none"
                && h.eventCount("bgprune.t0.applied") == 1 && h.prunedIds(manager).count >= 6,
                "phase \(manager.bgPruneTestPhase), pruned \(h.prunedIds(manager).count), events \(h.allEvents)")
        h.check("§8 the summary is merged into the anchor", h.summaryAnchors(manager).count == 1)
        h.check("§8 append-only growth preserved (the freeze turn's reply and this turn's message kept)",
                manager._testMessages.contains { $0.content == "freeze turn" } && manager._testMessages.contains { $0.content == "apply turn" })
        h.check("§8 the apply's request no longer carries the pruned output",
                h.mainRequests.count == 1 && !h.bodyText(h.mainRequests[0]).contains("RESULT-h-call-0 "))
        h.check("Q3 one notice, sent at apply", h.noticeTexts.count == 1, "\(h.channel.delivered)")
        h.check("§8.3 the apply wrote the history file", h.diskHistory().filter { $0.toolInteractions.isEmpty && $0.content.contains(" answer ") }.count >= 6)
        h.check("§8.3 one summary request in total", h.router.summaries == 1)
        h.check("§4.2 slot released, activities ended", !manager.bgPruneTestMaintenanceKinds.contains(.pruning)
                && h.eventCount("bgprune.released") == 1)
        h.check("B10 no immediate re-prune at T1 after the T0 apply", h.router.summaries == 1 && h.eventCount(prefix: "bgprune.freeze") == 1)
        let record = manager.bgPruneTestLastApply
        h.check("§8.3 apply record: applied and committed", record?.outcome == .applied && record?.committed == true)
    }

    /// F1 (lite): with nothing but append-only growth, the frozen
    /// transaction leaves the frozen range exactly as today's inline prune
    /// with the same plan and summary text.
    @MainActor static func equivalence(_ h: BackgroundPruneSelftestHarness) async {
        let history = h.prunableHistory(label: "eq")
        func normalized(_ messages: [Message], ids: Set<UUID>) -> Data {
            let kept = messages.filter { ids.contains($0.id) }.map { message -> Message in
                var copy = message
                copy.pruneArchiveReferences = []
                copy.prunedContextSummaryCoverage = nil
                copy.measuredTokens = nil
                return copy
            }
            return h.encoded(kept)
        }
        let frozenIds = Set(history.map(\.id))
        let off = await h.freshManager(history: history, switchOn: nil)
        off.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(off, "equivalence turn")
        let offView = normalized(off._testMessages, ids: frozenIds)
        let on = await h.freshManager(history: history, switchOn: true)
        _ = await h.frozenRunningJob(on, holdSummary: false)
        _ = await h.waitPhase(on, "ready")
        _ = await h.turn(on, "apply turn")
        let onView = normalized(on._testMessages, ids: frozenIds)
        h.check("F1 frozen range after ON apply ≡ today's inline prune (same plan, same summary)", onView == offView && !onView.isEmpty,
                "off pruned \(h.prunedIds(off).count), on pruned \(h.prunedIds(on).count)")
    }

    /// F2: a mutation of a frozen message → abandon, live data intact, one
    /// inline decision at the next over-maximum boundary.
    @MainActor static func guardAbandon(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager, holdSummary: false)
        _ = await h.waitPhase(manager, "ready")
        var live = manager._testMessages
        live[0].content += " (edited)"
        manager._testReplaceMessages(live)
        _ = manager._testSave()
        let edited = manager._testMessages
        h.check("F2 guard detects a byte change in the frozen prefix", manager.bgPruneTestGuardFailure() == "bytes",
                String(describing: manager.bgPruneTestGuardFailure()))
        manager.bgPruneTestSetLastPromptTokens(60_000)
        let summariesBefore = h.router.summaries
        _ = await h.turn(manager, "abandon turn")
        h.check("F2 abandon counted and logged", h.eventCount("bgprune.abandon.guard-bytes") == 1, "\(h.allEvents)")
        h.check("F2 live data intact at the abandon (edited message kept, no anchor from the job)",
                manager._testMessages.first?.content == edited.first?.content)
        h.check("§7.6 one inline decision at T1 (owed), no new freeze at that boundary",
                h.eventCount("bgprune.owed-inline") == 1 && h.router.summaries == summariesBefore + 1
                && h.eventCount(prefix: "bgprune.freeze") == 1 && !manager.bgPruneTestFallbackDue,
                "\(h.allEvents) summaries \(h.router.summaries)")
        h.check("F2 the owed inline prune pruned the history", h.prunedIds(manager).count >= 6)

        // Insertion before the end and reorder → abandon.
        for (label, mutate) in [("order", { (m: inout [Message]) in m.swapAt(0, 1) }),
                                ("duplicate", { (m: inout [Message]) in m.append(m[2]) }),
                                ("shrunk", { (m: inout [Message]) in m.removeLast(3) })] as [(String, (inout [Message]) -> Void)] {
            let other = await h.freshManager(history: h.prunableHistory())
            _ = await h.frozenRunningJob(other, holdSummary: false)
            _ = await h.waitPhase(other, "ready")
            var messages = other._testMessages
            mutate(&messages)
            other._testReplaceMessages(messages)
            h.check("F2 guard: \(label) → abandon reason", other.bgPruneTestGuardFailure() == label,
                    String(describing: other.bgPruneTestGuardFailure()))
        }
        // The trigger's measuredTokens is the one allowed field; another field on it is not.
        let trig = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(trig, holdSummary: false)
        _ = await h.waitPhase(trig, "ready")
        var messages = trig._testMessages
        if let index = messages.firstIndex(where: { $0.content == "trigger a background prune" }) {
            messages[index].measuredTokens = 12_345
            trig._testReplaceMessages(messages)
            h.check("F2 trigger measuredTokens change accepted", trig.bgPruneTestGuardFailure() == nil)
            messages[index].content += "!"
            trig._testReplaceMessages(messages)
            h.check("F2 another field on the trigger → abandon", trig.bgPruneTestGuardFailure() == "bytes")
        } else {
            h.check("F2 trigger present", false)
        }
    }

    /// F3: the write-set ⊆ dependency-set assertion fires on a forced violation.
    @MainActor static func writeSet(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager, holdSummary: false)
        _ = await h.waitPhase(manager, "ready")
        ConversationManager.bgPruneWriteSetViolationForTesting = true
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "violation turn")
        ConversationManager.bgPruneWriteSetViolationForTesting = nil
        h.check("F3 write-set assertion → abandon, nothing written", h.eventCount("bgprune.assert.write-set") == 1
                && h.eventCount("bgprune.abandon.write-set") == 1 && h.prunedIds(manager).isEmpty, "\(h.allEvents)")
        h.check("F3 an owed decision remains while under the maximum (§7.6)", manager.bgPruneTestFallbackDue)
    }

    /// F5: checked-write failure at apply.
    @MainActor static func writeFailure(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager, holdSummary: false)
        _ = await h.waitPhase(manager, "ready")
        let snapshotId = manager.bgPruneTestSnapshotId
        let armed = BackgroundPruneSelftestGate()
        // Armed by the prune commit's own pre-write seam, so only the
        // apply's checked write fails (not the turn's ordinary saves).
        ConversationManager.beforePruneHistoryWriteForTesting = { armed.release() }
        ConversationManager.historyWriteFaultForTesting = {
            if armed.isReleased, ConversationManager.beforePruneHistoryWriteForTesting != nil {
                ConversationManager.beforePruneHistoryWriteForTesting = nil
                throw PruneArchiveStore.Failure("injected history write fault")
            }
        }
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "write fault turn")
        ConversationManager.historyWriteFaultForTesting = nil
        ConversationManager.beforePruneHistoryWriteForTesting = nil
        h.check("F5 write failure → live memory unchanged, fallback owed", h.prunedIds(manager).isEmpty
                && manager.bgPruneTestFallbackDue && manager.bgPruneTestLastApply?.outcome == .writeFailed,
                "pruned \(h.prunedIds(manager).count), due \(manager.bgPruneTestFallbackDue), \(String(describing: manager.bgPruneTestLastApply))")
        let snapshotFile = (try? FileManager.default.contentsOfDirectory(atPath: PruneArchiveStore.root.path))?
            .contains { name in snapshotId.map { name.contains($0.uuidString.lowercased().replacingOccurrences(of: "-", with: "")) } ?? false } ?? false
        h.check("F5 the freeze snapshot is still on disk", snapshotFile)
        manager.bgPruneTestSetLastPromptTokens(60_000)
        let before = h.router.summaries
        _ = await h.turn(manager, "owed turn")
        h.check("F5 the owed inline prune runs at the next over-maximum boundary",
                h.router.summaries == before + 1 && h.prunedIds(manager).count >= 6 && !manager.bgPruneTestFallbackDue)
    }

    /// A job that becomes ready between T0 and T1 is applied at T1, once,
    /// with one notice (B4, §8.5, Codex note 3).
    @MainActor static func readyBetweenT0AndT1(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager)
        let gate = BackgroundPruneSelftestGate()
        ConversationManager.bgPruneHoldForTesting = { point in
            if point == "t1.entry" { await gate.awaitRelease() }
        }
        manager.bgPruneTestSetLastPromptTokens(1_000)
        h.server.clear()
        h.startTurn(manager, "t1 apply turn", replies: [BackgroundPruneSelftestHarness.chat("done", prompt: 100)])
        let atT1 = await h.waitUntil { gate.arrived == 1 }
        h.check("T1 precondition: T0 saw a running job (no T0 apply)", atT1 && h.eventCount("bgprune.t0.applied") == 0)
        h.router.gate.release()
        _ = await h.waitPhase(manager, "ready")
        gate.release()
        let idle = await manager._testAwaitIdle(timeout: 40)
        ConversationManager.bgPruneHoldForTesting = nil
        h.check("§8.5 the job is applied at T1, once, with one notice", idle && h.eventCount("bgprune.applied") == 1
                && h.eventCount("bgprune.t0.applied") == 0 && h.noticeTexts.count == 1 && h.prunedIds(manager).count >= 6,
                "\(h.allEvents) notices \(h.noticeTexts.count)")
        h.check("§8.5 the request after the T1 apply carries the applied history",
                h.mainRequests.count == 1 && !h.bodyText(h.mainRequests[0]).contains("RESULT-h-call-0 "))
    }
}
