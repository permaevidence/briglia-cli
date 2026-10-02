import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// P1–P8: snapshots behind demoted lines in the committed history survive
/// every retention entry point; unreadable history deletes nothing.
extension RetentionHarness {

    struct ProtectionFixture {
        let protected: [PruneArchiveReference]
        let fillers: [PruneArchiveReference]
    }

    /// 310 old snapshots; the three oldest are referenced by live demoted
    /// lines (one message with two records, one snapshot shared by two).
    func protectionFixture() async throws -> (ConversationManager, ProtectionFixture) {
        let manager = await freshManager()
        let refs = try fillSnapshots(310)
        let (p0, p1, p2) = (refs[0], refs[1], refs[2])
        var m1 = Message(role: .assistant, content: "HOLDER_1", timestamp: at(2026, 9, 1, 10, 0))
        m1.demotedPruneSummaries = [record(p0, label: "one"), record(p1, label: "two")]; m1.pruneArchiveReferences = [p0, p1]
        var m2 = Message(role: .assistant, content: "HOLDER_2", timestamp: at(2026, 9, 2, 10, 0))
        m2.demotedPruneSummaries = [record(p2, label: "shared")]; m2.pruneArchiveReferences = [p2]
        var m3 = Message(role: .assistant, content: "HOLDER_3", timestamp: at(2026, 9, 3, 10, 0))
        m3.demotedPruneSummaries = [record(p2, label: "shared")]; m3.pruneArchiveReferences = [p2]
        let history = [user("U1", at: at(2026, 9, 1, 9, 0)), m1, user("U2", at: at(2026, 9, 2, 9, 0)), m2,
                       user("U3", at: at(2026, 9, 3, 9, 0)), m3, user("U_TAIL", at: at(2026, 9, 20, 9, 0)),
                       toolTurn("TAIL", at: at(2026, 9, 20, 10, 0), issued: [at(2026, 9, 20, 9, 30)])]
        manager._testSeedHistory(history)
        return (manager, ProtectionFixture(protected: [p0, p1, p2], fillers: Array(refs.dropFirst(3))))
    }

    func protectionHolds(_ label: String, _ f: ProtectionFixture) {
        let ids = snapshotIDs()
        let protectedKept = f.protected.allSatisfy { ids.contains($0.id) }
        let oldestUnprotectedGone = !ids.contains(f.fillers[0].id)
        check(label, protectedKept && oldestUnprotectedGone && ids.count == 300,
              "protected kept \(protectedKept), oldest unprotected gone \(oldestUnprotectedGone), \(ids.count) snapshots")
    }

    /// P1 every entry point; P7 Mind round trip.
    func protectionEntrySection() async throws {
        var (manager, f) = try await protectionFixture()
        try await pruneLast(manager)
        protectionHolds("P1a after a prune: live demotion snapshots survive, older unprotected ones are deleted", f)

        (manager, f) = try await protectionFixture()
        let compaction = try PruneArchiveStore.write(messages: [], trigger: "active-turn-compaction", removedIDs: [])
        try PruneArchiveStore.retainLatest(protecting: [compaction.id]) // the active-turn compaction call site
        protectionHolds("P1b after active-turn compaction (its retention call)", f)

        (manager, f) = try await protectionFixture()
        manager._testSeedHistory(Array(manager._testMessages.dropFirst())) // an unrelated message archived away
        try PruneArchiveStore.retainLatest()                               // the chunk-archive call site
        protectionHolds("P1c after a chunk archive of unrelated messages (its retention call)", f)

        (manager, f) = try await protectionFixture()
        manager = await restart()
        try await pruneLast(manager)
        protectionHolds("P1d after a restart (new manager, retention via the next prune)", f)

        (manager, f) = try await protectionFixture()
        let mind = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString).mind")
        defer { try? FileManager.default.removeItem(at: mind) }
        do {
            try await MindExportService.shared.exportMind(to: mind)
            resetState()
            try await MindExportService.shared.applyStagedMind(try await MindExportService.shared.stageMind(from: mind))
            protectionHolds("P1e after Mind import (retention on the restored pair)", f)
        } catch { check("P1e after Mind import (retention on the restored pair)", false, "\(error)") }

        // P7: a real demotion round-trips through Mind export/import.
        manager = await freshManager(history: anchoredHistory(3))
        try await pruneLast(manager)
        let before = diskHistory() ?? []
        let demotion = records(before).map(\.snapshot)
        _ = try fillSnapshots(305, future: true)
        let whitelist = ["manual", "automatic", "mid-turn", "chunk-archive", "active-turn-compaction"] // v0.2.45, literal
        let triggersOK = demotion.allSatisfy { snapshotHeaderTrigger($0).map(whitelist.contains) == true }
        var mindError = ""
        do {
            try? FileManager.default.removeItem(at: mind)
            try await MindExportService.shared.exportMind(to: mind)
            resetState()
            try await MindExportService.shared.applyStagedMind(try await MindExportService.shared.stageMind(from: mind))
        } catch { mindError = "\(error)" }
        let restored = diskHistory() ?? []
        let ids = snapshotIDs()
        check("P7 Mind round trip: lines, coverage and snapshots restored; protection holds; triggers in the unchanged whitelist",
              mindError.isEmpty && !demotion.isEmpty && triggersOK && records(restored) == records(before)
              && restored.map(\.prunedContextSummaryCoverage) == before.map(\.prunedContextSummaryCoverage)
              && demotion.allSatisfy { ids.contains($0.id) } && ids.count == 300,
              "\(records(restored).count) records, \(ids.count) snapshots, triggers \(triggersOK) \(mindError)")
    }

    /// P2 unreadable history; P3/P4 both sides of a failed write; P5 pin;
    /// P6 release; P8 decoder agreement.
    func protectionFailureSection() async throws {
        // P2: unreadable → delete nothing, never throw; absent → normal.
        var variants: [(String, () throws -> Void)] = [
            ("malformed JSON", { try Data("[{\"id\": broken".utf8).write(to: self.historyURL) }),
            ("a directory in its place", {
                try? FileManager.default.removeItem(at: self.historyURL)
                try FileManager.default.createDirectory(at: self.historyURL, withIntermediateDirectories: false) }),
        ]
        if geteuid() != 0 { variants.append(("EACCES", { chmod(self.historyURL.path, 0) })) }
        for (name, damage) in variants {
            _ = try await protectionFixture()
            try damage()
            var threw = false
            do { try PruneArchiveStore.retainLatest() } catch { threw = true }
            check("P2 unreadable history (\(name)) → nothing deleted, no throw", !threw && snapshotIDs().count == 310, "\(snapshotIDs().count)")
            chmod(historyURL.path, 0o600)
        }
        _ = try await protectionFixture()
        try FileManager.default.removeItem(at: historyURL)
        try PruneArchiveStore.retainLatest()
        check("P2 absent history → normal retention", snapshotIDs().count == 300)
        _ = try await protectionFixture()
        try Data("not json".utf8).write(to: historyURL)
        let mind = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString).mind")
        defer { try? FileManager.default.removeItem(at: mind) }
        try await MindExportService.shared.exportMind(to: mind)
        resetState()
        var imported = true
        do { try await MindExportService.shared.applyStagedMind(try await MindExportService.shared.stageMind(from: mind)) } catch { imported = false }
        check("P2 Mind import with unreadable history completes and deletes nothing", imported && snapshotIDs().count == 310, "\(snapshotIDs().count)")

        try await writeFailureRows()
        try await pinAndReleaseRows()
        try await decoderAgreementRows()
    }

    /// P3 pre-rename failure; P4 post-rename failure.
    func writeFailureRows() async throws {
        var manager = await freshManager(history: anchoredHistory(3))
        var demotionRef: PruneArchiveReference?
        ConversationManager.afterDemotionSnapshotForTesting = { demotionRef = $0 }
        let diskBefore = try Data(contentsOf: historyURL)
        ConversationManager.historyWriteFaultForTesting = { throw PruneArchiveStore.Failure("injected pre-rename failure") }
        let failed = (try? await pruneLast(manager)) == nil
        ConversationManager.historyWriteFaultForTesting = nil
        let unchanged = (try? Data(contentsOf: historyURL)) == diskBefore
        let fullInMemory = message(manager._testMessages, "REPLY_A0")?.prunedContextSummary == "FULL_SUMMARY_A0"
        _ = try fillSnapshots(305, future: true)
        try PruneArchiveStore.retainLatest()
        let expired = demotionRef.map { !snapshotIDs().contains($0.id) } ?? false
        check("P3 history write fails before rename → disk unchanged, memory full; the unreferenced snapshot may expire without loss",
              failed && unchanged && fullInMemory && expired && message(diskHistory() ?? [], "REPLY_A0")?.prunedContextSummary == "FULL_SUMMARY_A0",
              "failed \(failed) unchanged \(unchanged) full \(fullInMemory) expired \(expired)")

        manager = await freshManager(history: anchoredHistory(3))
        demotionRef = nil
        ConversationManager.afterDemotionSnapshotForTesting = { demotionRef = $0 }
        ConversationManager.historyPostWriteFaultForTesting = { throw PruneArchiveStore.Failure("injected post-rename failure") }
        let failedAfter = (try? await pruneLast(manager)) == nil
        ConversationManager.historyPostWriteFaultForTesting = nil
        let onDisk = records(diskHistory() ?? []).map(\.snapshot.id)
        _ = try fillSnapshots(305, future: true)
        try PruneArchiveStore.retainLatest()
        let kept = demotionRef.map { snapshotIDs().contains($0.id) } ?? false
        manager = await restart()
        _ = try fillSnapshots(5, future: true)
        try PruneArchiveStore.retainLatest()
        let keptAfterRestart = demotionRef.map { snapshotIDs().contains($0.id) } ?? false
        check("P4 failure after rename → disk holds the line; its snapshot stays protected, after a restart too",
              failedAfter && demotionRef.map { onDisk.contains($0.id) } == true && kept && keptAfterRestart
              && records(manager._testMessages).count == 1,
              "failed \(failedAfter) kept \(kept) restart \(keptAfterRestart)")
        ConversationManager.afterDemotionSnapshotForTesting = nil
    }

    /// P5 pin through commit; P6 release when the line leaves history.
    func pinAndReleaseRows() async throws {
        var manager = await freshManager(history: anchoredHistory(3))
        _ = try fillSnapshots(305, future: true)
        var demotionRef: PruneArchiveReference?
        var injectedSurvived = false
        ConversationManager.afterDemotionSnapshotForTesting = { demotionRef = $0 }
        ConversationManager.beforePruneHistoryWriteForTesting = {
            try? PruneArchiveStore.retainLatest()
            injectedSurvived = demotionRef.map { self.snapshotIDs().contains($0.id) } ?? false
        }
        try await pruneLast(manager)
        ConversationManager.beforePruneHistoryWriteForTesting = nil
        ConversationManager.afterDemotionSnapshotForTesting = nil
        check("P5 the demotion snapshot is pinned from creation through commit exit (injected retention cannot delete it)",
              injectedSurvived && demotionRef.map { snapshotIDs().contains($0.id) } == true)

        manager = await freshManager(history: anchoredHistory(3))
        try await pruneLast(manager)
        let holder = message(manager._testMessages, "REPLY_A0")!
        let snapshot = holder.demotedPruneSummaries[0].snapshot
        let sanitized = await manager._testArchiveService._testSanitizeForArchive(holder)
        manager._testSeedHistory(manager._testMessages.filter { $0.id != holder.id && $0.content != "U_A0" })
        _ = try fillSnapshots(305, future: true)
        try PruneArchiveStore.retainLatest()
        check("P6 the archive drops both fields and keeps the reference; once the line leaves history the snapshot can expire",
              sanitized.demotedPruneSummaries.isEmpty && sanitized.prunedContextSummaryCoverage == nil
              && sanitized.pruneArchiveReferences.contains(snapshot) && !snapshotIDs().contains(snapshot.id))
    }

    /// P8: retention's decode and the loader agree on which lines are live.
    func decoderAgreementRows() async throws {
        let good = randomRef(), other = randomRef()
        let goodRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record(good, label: "ok")))
        let badCoverage: Any = { var r = goodRecord as! [String: Any]; r["snapshot"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(other))
                                 r["coverage"] = ["version": 9]; return r }()
        let badBasename: Any = { var r = goodRecord as! [String: Any]; r["snapshot"] = ["id": UUID().uuidString, "basename": "../x.txt", "version": 1]; return r }()
        func message(_ extra: [String: Any]) -> [String: Any] {
            ["id": UUID().uuidString, "role": "assistant", "content": "P8", "timestamp": 800_000_000.0].merging(extra) { $1 }
        }
        let cases: [(String, Any)] = [
            ("valid, damaged-element and bad-coverage records", [message(["demotedPruneSummaries": [goodRecord, badBasename, badCoverage]])]),
            ("older shape without the field", [message([:])]),
            ("field of the wrong type", [message(["demotedPruneSummaries": "not an array"])]),
        ]
        for (name, json) in cases {
            resetState()
            try PrivateStorage.writeAtomically(try JSONSerialization.data(withJSONObject: json), to: historyURL)
            let loaded = Set((await restart())._testMessages.flatMap { $0.demotedPruneSummaries.map(\.snapshot.id) })
            var live: Set<UUID>? = nil
            if case .snapshots(let ids) = PruneSummaryRetention.liveDemotionSnapshots(historyFile: historyURL) { live = ids }
            check("P8 retention decode and loader agree (\(name))", live == loaded, "live \(String(describing: live)) loaded \(loaded)")
        }
        resetState()
        try Data("[{]".utf8).write(to: historyURL)
        let manager = await restart()
        var unreadable = false
        if case .unreadable = PruneSummaryRetention.liveDemotionSnapshots(historyFile: historyURL) { unreadable = true }
        check("P8 malformed history: the loader fails and retention treats it as unreadable",
              manager._testHistoryLoadFailure != nil && unreadable)
    }
}
