import Foundation

/// K14 downgrade round trip: candidate → 0.2.57 → candidate.
///
/// The permanent in-binary row emulates the 0.2.57 side with what 0.2.57
/// actually does to the history: its `Message` decoder ignores the unknown
/// `prunedContextSummaryStub` key and its re-encode drops it (emulated by
/// deleting the key from the JSON), its home has no stub snapshots (they
/// are deleted), its prune commit adds a summary to a new anchor and the
/// frozen 0.2.57 demotion (`LegacyDemotionOracle`) shortens all but the
/// newest three into one demotion snapshot, and its usage file carries no
/// composition key. `scripts/keep_summaries_downgrade_real_test.py` runs
/// the same round trip with a real pinned 0.2.57 build in the middle,
/// through the `downgrade-export` / `downgrade-import` phases below.
extension RetentionHarness {

    static let downgradeLabels = (0..<5).map { "A\($0)" } + ["TAIL"]

    /// Phase 1: six full anchors with usable stubs, left by a real candidate
    /// prune commit (five older anchors + the pruned tail turn).
    func downgradeCandidateHistory() async throws -> [Message] {
        let manager = await freshManager(history: anchoredHistory(5))
        try await pruneLast(manager, summary: "FULL_SUMMARY_TAIL")
        return manager._testMessages
    }

    /// The 0.2.57 decode + re-encode of a candidate history file.
    func decodedBy057(_ data: Data) throws -> [Message] {
        guard var array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PruneArchiveStore.Failure("history is not an array")
        }
        for i in array.indices { array[i].removeValue(forKey: "prunedContextSummaryStub") }
        return try JSONDecoder().decode([Message].self, from: try JSONSerialization.data(withJSONObject: array))
    }

    /// Phase 3 checks, shared by the emulated and the real round trip.
    func downgradeVerify(_ manager: ConversationManager, prefix: String) {
        let report = manager.summaryRetentionIdlePass()
        let history = manager._testMessages
        let labels = Self.downgradeLabels + ["OLD7"]
        let exact = labels.allSatisfy { message(history, "REPLY_" + $0)?.prunedContextSummary == "FULL_SUMMARY_" + $0 }
        check("\(prefix)a the four summaries 0.2.57 shortened come back byte-for-byte; the three it kept stay in full",
              report.restored == 4 && exact && records(history).isEmpty, "\(report)")
        let anchors = history.filter(PruneSummaryRetention.isFullAnchor)
        check("\(prefix)b every one of the seven anchors has a usable pointer to a complete snapshot (the missing stub snapshots were rebuilt)",
              anchors.count == 7 && anchors.allSatisfy {
                  guard let stub = $0.prunedContextSummaryStub, stub.isUsable(for: $0.prunedContextSummary) else { return false }
                  return PruneArchiveStore.isCompleteSnapshot(stub.record.snapshot)
              })
        let full = { (limit: KeepSummariesLimit) in self.composed(history, limit).filter(PruneSummaryRetention.isFullAnchor).count }
        check("\(prefix)c composition: all → 7 in full, default → 3 in full", full(.all) == 7 && full(.defaultValue) == 3,
              "all \(full(.all)) default \(full(.defaultValue))")
        check("\(prefix)d the 0.2.57 measurement was durably cleared before the restore was published",
              manager._testLastPromptTokens == nil && usageFile()?["lastPromptTokens"] == nil)
        check("\(prefix)e the committed history on disk equals memory",
              encodedSorted(diskHistory() ?? []) == encodedSorted(history))
    }

    /// K14 (emulated 0.2.57 side; runs in CI through smoke).
    func downgradeSection() async throws {
        let candidate = try await downgradeCandidateHistory()
        check("K14 setup: the candidate commit left six full anchors with usable stubs",
              candidate.filter { PruneSummaryRetention.isFullAnchor($0) && $0.prunedContextSummaryStub?.isUsable(for: $0.prunedContextSummary) == true }.count == 6)
        // 0.2.57 side.
        var old = try decodedBy057(try Data(contentsOf: historyURL))
        for ref in Set(candidate.compactMap { $0.prunedContextSummaryStub?.record.snapshot.basename }) {
            try? FileManager.default.removeItem(at: snapshotDir.appendingPathComponent(ref))
        }
        old.append(user("U_OLD7", at: at(2026, 9, 25, 9, 0)))
        old.append(anchor("OLD7", at: at(2026, 9, 25, 10, 0)))
        let anchors = old.indices.filter { PruneSummaryRetention.isFullAnchor(old[$0]) }
        let (demoted, _) = try LegacyDemotionOracle.legacyHistory(old, demote: Array(anchors.prefix(anchors.count - 3)), trigger: "automatic")
        check("K14 0.2.57 side: no stub survives its decode; four anchors are shortened, three stay in full",
              demoted.allSatisfy { $0.prunedContextSummaryStub == nil } && records(demoted).count == 4
              && demoted.filter(PruneSummaryRetention.isFullAnchor).count == 3)
        // Back on the candidate.
        let manager = try await legacyManager(demoted)
        downgradeVerify(manager, prefix: "K14")
    }

    // MARK: Real 0.2.57 round trip phases (only when named explicitly)

    var downgradeTransfer: URL? {
        ProcessInfo.processInfo.environment["KS_DOWNGRADE_TRANSFER"].map { URL(fileURLWithPath: $0) }
    }

    /// Copies conversation.json, context_usage.json and prune-archives/.
    func copyState(from: URL, to: URL, snapshots: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in ["conversation.json", "context_usage.json"] where fm.fileExists(atPath: from.appendingPathComponent(name).path) {
            try? fm.removeItem(at: to.appendingPathComponent(name))
            try fm.copyItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name))
        }
        guard snapshots else { return }
        let src = from.appendingPathComponent("prune-archives"), dst = to.appendingPathComponent("prune-archives")
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where name.hasSuffix(".txt") {
            try? fm.removeItem(at: dst.appendingPathComponent(name))
            try fm.copyItem(at: src.appendingPathComponent(name), to: dst.appendingPathComponent(name))
        }
    }

    func downgradeRealPhases() async throws {
        guard let transfer = downgradeTransfer else { return }
        if only == "downgrade-export" {
            let candidate = try await downgradeCandidateHistory()
            try writeUsage(["lastPromptTokens": 5_000, "lastCompletionTokens": 7, "updatedAt": 800_000_000.0,
                            "lastPromptRenderKey": PruneSummaryRetention.emptyRenderKey])
            // The stub snapshots stay behind (the 0.2.57 home never had them).
            try copyState(from: StoragePaths.dataRoot, to: transfer.appendingPathComponent("candidate"), snapshots: false)
            check("K14R export: six full anchors with usable stubs written for the 0.2.57 side",
                  candidate.filter { $0.prunedContextSummaryStub?.isUsable(for: $0.prunedContextSummary) == true }.count == 6)
        } else if only == "downgrade-import" {
            _ = await freshManager()
            try copyState(from: transfer.appendingPathComponent("old"), to: StoragePaths.dataRoot, snapshots: true)
            let manager = await restart()
            let loaded = manager._testMessages
            check("K14R 0.2.57 output: no stub field, four anchors shortened, three in full",
                  loaded.allSatisfy { $0.prunedContextSummaryStub == nil } && records(loaded).count == 4
                  && loaded.filter(PruneSummaryRetention.isFullAnchor).count == 3,
                  "records \(records(loaded).count) full \(loaded.filter(PruneSummaryRetention.isFullAnchor).count)")
            downgradeVerify(manager, prefix: "K14R")
        }
    }
}
