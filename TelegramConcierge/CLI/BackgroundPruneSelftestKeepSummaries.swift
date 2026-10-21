import Foundation

/// /keepsummaries with background pruning (KEEP_SUMMARIES_PLAN K10, K13):
/// N changed while the worker runs, while the result is ready and inside the
/// apply never trips the frozen guard (N never touches persisted bytes); the
/// apply attaches the pointer; the idle pass never runs while a job exists.
enum BackgroundPruneSelftestKeepSummaries {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        for seam in ["worker", "ready", "apply"] { await changeDuring(h, seam: seam) }
        UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
    }

    /// Four older anchors with full summaries and usable pointers, prepended.
    @MainActor static func withStubbedAnchors(_ manager: ConversationManager) throws {
        var anchors: [Message] = []
        for i in 0..<4 {
            var a = Message(role: .assistant, content: "KS_ANCHOR_\(i)", timestamp: Date(timeIntervalSince1970: 1_780_000_000 + Double(i) * 3600))
            a.prunedContextSummary = "KS_FULL_SUMMARY_\(i)"
            anchors.append(a)
        }
        let ref = try PruneArchiveStore.write(messages: anchors, trigger: "manual", removedIDs: anchors.map(\.id),
                                              leadNote: PruneSummaryRetention.snapshotLeadNote)
        for i in anchors.indices { anchors[i].prunedContextSummaryStub = PruneSummaryRetention.makeStub(for: anchors, anchor: i, snapshot: ref) }
        manager._testReplaceMessages(anchors + manager._testMessages)
        _ = manager._testSave()
    }

    @MainActor static func changeDuring(_ h: BackgroundPruneSelftestHarness, seam: String) async {
        UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
        let manager = await h.freshManager(history: h.prunableHistory())
        do { try withStubbedAnchors(manager) } catch { h.check("K10 [\(seam)] setup", false, "\(error)"); return }
        _ = await h.frozenRunningJob(manager)
        let blocked = manager.summaryRetentionIdlePass().blocked
        if seam == "worker" { KeepSummariesSetting.store(.count(1)) }
        h.router.gate.release()
        _ = await h.waitPhase(manager, "ready")
        // Ready: the worker's activity has ended; only the job itself blocks.
        let blockedReady = manager.summaryRetentionIdlePass().blocked
        if seam == "ready" { KeepSummariesSetting.store(.all) }
        if seam == "apply" { ConversationManager.beforePruneHistoryWriteForTesting = { KeepSummariesSetting.store(.count(2)) } }
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "apply with N changed (\(seam))")
        ConversationManager.beforePruneHistoryWriteForTesting = nil
        let applied: Bool = {
            guard let record = manager.bgPruneTestLastApply else { return false }
            if case .applied = record.outcome { return true }
            return false
        }()
        let anchors = manager._testMessages.filter(PruneSummaryRetention.isFullAnchor)
        let stubbed = anchors.allSatisfy { $0.prunedContextSummaryStub?.isUsable(for: $0.prunedContextSummary) == true }
        h.check("K10 [\(seam)] N changed \(seam == "apply" ? "inside the apply" : "while the job was " + (seam == "worker" ? "running" : "ready")): the frozen guard does not trip, the prune applies and its anchor gets a pointer; every full text kept",
                applied, "outcome \(String(describing: manager.bgPruneTestLastApply?.outcome))")
        h.check("K10 [\(seam)] all \(anchors.count) anchors keep their full summary with a usable pointer",
                anchors.count == 5 && stubbed && anchors.filter { $0.content.hasPrefix("KS_ANCHOR_") }.map(\.prunedContextSummary)
                    == (0..<4).map { "KS_FULL_SUMMARY_\($0)" }, "\(anchors.count) anchors, stubbed \(stubbed)")
        h.check("K13 [\(seam)] the idle pass refuses to run while a background prune job exists (running and ready)",
                blocked == "background prune" && blockedReady == "background prune",
                "\(String(describing: blocked)) / \(String(describing: blockedReady))")
        UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
    }
}
