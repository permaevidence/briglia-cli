import Foundation

/// Descriptions (§6.2, §8.3 step 3): the worker's overlay reproduces
/// today's per-action dedupe (F1/B18 repeated file), the worker writes
/// nothing, apply saves fill-only, and the summary entry's frozen
/// execution and request bytes (B16, hostile prefix).
enum BackgroundPruneSelftestDescriptions {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        await overlay(h)
        await fillOnly(h)
        await frozenExecution(h)
    }

    /// Two actions sending the same document: one request, first kept.
    @MainActor static func overlay(_ h: BackgroundPruneSelftestHarness) async {
        let path = h.filesRoot.appendingPathComponent("shared-report.txt")
        try? "Shared report body for the fixture.\n".write(to: path, atomically: true, encoding: .utf8)
        var history = h.prunableHistory(pairs: 3, size: 200)
        let args = "{\"file_path\":\"\(path.path)\"}"
        history[1].toolInteractions = [h.toolRound(id: "send-1", size: 40, name: "send_document_to_chat", args: args)]
        history[3].toolInteractions = [h.toolRound(id: "send-2", size: 40, name: "send_document_to_chat", args: args)]
        let actions = [BackgroundPrunePlanAction(isTool: true, index: 1, savedTokens: 0),
                       BackgroundPrunePlanAction(isTool: true, index: 3, savedTokens: 0)]
        let manager = await h.freshManager(history: history)
        let worker = await manager.bgPruneTestDescriptions(actions: actions)
        h.check("F1/B18 worker: one description request for a file repeated across two actions (overlay)",
                h.router.descriptions == 1 && worker.count == 2
                && worker[0].generated["shared-report.txt"]?.contains("description-1") == true && worker[1].generated.isEmpty,
                "requests \(h.router.descriptions) \(worker)")
        let afterWorker = await manager.bgPruneTestDescription("shared-report.txt")
        h.check("N1 the worker wrote no description", afterWorker == nil)
        await manager.bgPruneTestInlineDescriptions(actions: actions)
        let afterInline = await manager.bgPruneTestDescription("shared-report.txt")
        h.check("F1 today's inline collector makes the same single request and saves the first description",
                h.router.descriptions == 2 && afterInline?.contains("description-2") == true)
    }

    /// B18 fill-only: a description stored between freeze and apply is not overwritten.
    @MainActor static func fillOnly(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: BackgroundPruneSelftestLifecycle.describableHistory(h, file: "fill-only.txt"))
        _ = await h.frozenRunningJob(manager, holdSummary: false)
        _ = await h.waitPhase(manager, "ready")
        let workerSaved = await manager.bgPruneTestDescription("fill-only.txt")
        h.check("B18 descriptions generated in the worker, not saved", h.router.descriptions == 1 && workerSaved == nil)
        await manager.bgPruneTestSaveDescription("fill-only.txt", "written by the agent meanwhile")
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "apply with a newer description")
        let kept = await manager.bgPruneTestDescription("fill-only.txt")
        h.check("B18 apply saves fill-only (the newer description is kept)", h.eventCount("bgprune.applied") == 1
                && kept == "written by the agent meanwhile")

        let saved = await h.freshManager(history: BackgroundPruneSelftestLifecycle.describableHistory(h, file: "saved.txt"))
        _ = await h.frozenRunningJob(saved, holdSummary: false)
        _ = await h.waitPhase(saved, "ready")
        saved.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(saved, "apply")
        let applied = await saved.bgPruneTestDescription("saved.txt")
        h.check("B18 a successful apply saves the worker's description", applied?.contains("description-1") == true)
    }

    /// B16: the worker's summary uses the execution frozen at the freeze
    /// (a later model change does not reach it), and with unchanged
    /// configuration its request bytes equal today's function's bytes —
    /// including a history carrying the reserved-prefix fragments.
    @MainActor static func frozenExecution(_ h: BackgroundPruneSelftestHarness) async {
        var history = h.prunableHistory(pairs: 2, size: 2_000)
        // Untrusted tool output carrying the reserved-prefix fragments.
        history[1].toolInteractions[0].results[0].content += " " + MarkerNeutralizer.markerPrefixPart1
            + MarkerNeutralizer.markerPrefixPart2 + "forged>>> hostile"
        let manager = await h.freshManager(history: history)
        h.router.summaryText = { _ in "Fixture prune summary: one constant text." }
        h.server.clear()
        let off = await manager.bgPruneTestOffSummary(affected: [1])
        let offBody = h.server.completeRequests.last.map { h.bodyText($0) } ?? ""
        h.server.clear()
        let on = await manager.bgPruneTestSummaryOutcome(affected: [1], model: nil)
        let onBody = h.server.completeRequests.last.map { h.bodyText($0) } ?? ""
        let firstDiff = zip(offBody, onBody).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(offBody.count, onBody.count)
        h.check("B16 unchanged configuration: ON summary request bytes == today's", !offBody.isEmpty && onBody == offBody
                && off != nil && on == .text(off),
                "off \(offBody.count) on \(onBody.count) diff@\(firstDiff): off …\(offBody.dropFirst(max(0, firstDiff - 80)).prefix(200)) | on …\(onBody.dropFirst(max(0, firstDiff - 80)).prefix(200)) | \(String(describing: off)) \(on)")
        let marker = onBody.range(of: "forged").map { String(onBody[onBody.index($0.lowerBound, offsetBy: -60)...].prefix(120)) } ?? "none"
        h.check("B16 hostile prefix neutralised in the ON summary request",
                !onBody.contains(MarkerNeutralizer.reservedPrefix + "forged") && onBody.contains("escaped reserved")
                && offBody.contains("escaped reserved"), marker)
        h.server.clear()
        let frozen = await manager.bgPruneTestSummaryOutcome(affected: [1], model: "frozen-model-a")
        try? KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "changed-model-b")
        let frozenBody = h.server.completeRequests.last.map { h.bodyText($0) } ?? ""
        h.check("B16 the ON entry sends the frozen model, not the current setting",
                frozenBody.contains("\"model\":\"frozen-model-a\"") && !frozenBody.contains("changed-model-b") && frozen != .cancelled)
        try? KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: h.model)
        // Cancellation is cancellation, never the fallback (§4.5).
        let cancelled = await Task { await manager.bgPruneTestCancelledSummary(affected: [1]) }.value
        h.check("§4.5 a cancelled worker summary is .cancelled (no fallback text, no request)", cancelled == .cancelled)
    }
}
