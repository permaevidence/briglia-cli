import Foundation

/// K12 one-time restore of 0.2.48–0.2.57 pointers (§6), K8b restore
/// invalidation of the cached measurement (§4.4, R3-2).
extension RetentionHarness {

    /// Five anchors A0…A4 (recorded complete coverage); `demote` of them
    /// shortened by the frozen 0.2.57 demotion into ONE snapshot.
    func legacySetup(demote: [Int] = [0, 1], measured: Int? = nil,
                     edit: ((inout [Message]) -> Void)? = nil) throws -> (history: [Message], snapshot: PruneArchiveReference) {
        var h: [Message] = []
        for i in 0..<5 {
            h.append(user("U_A\(i)", at: at(2026, 9, 1 + i, 9, 0)))
            var a = anchor("A\(i)", at: at(2026, 9, 1 + i, 10, 0))
            a.measuredTokens = measured
            h.append(a)
        }
        edit?(&h)
        let anchors = h.indices.filter { PruneSummaryRetention.isFullAnchor(h[$0]) }
        return try LegacyDemotionOracle.legacyHistory(h, demote: demote.map { anchors[$0] })
    }

    /// A restarted manager over a legacy history and a ≤0.2.57 usage file.
    func legacyManager(_ history: [Message], usage: Int? = 5_000) async throws -> ConversationManager {
        // No reset here: the caller already reset and wrote the snapshots.
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(history), to: historyURL)
        if let usage { try writeUsage(["lastPromptTokens": usage, "lastCompletionTokens": 7, "updatedAt": 800_000_000.0]) }
        return await restart()
    }

    func withoutStubs(_ history: [Message]) -> [Message] {
        history.map { var m = $0; m.prunedContextSummaryStub = nil; return m }
    }

    /// K12 accepted: the exact case, a multi-anchor snapshot read once, the
    /// reverse measuredTokens delta, a later request equal to 0.2.57's.
    func restoreAcceptSection() async throws {
        _ = await freshManager()
        let (legacy, snapshot) = try legacySetup(demote: [0, 1], measured: 1_000)
        let manager = try await legacyManager(legacy)
        PruneSummaryRestore.indexCountForTesting = 0
        let report = manager.summaryRetentionIdlePass()
        let restored = manager._testMessages
        let a0 = message(restored, "REPLY_A0"), a1 = message(restored, "REPLY_A1")
        check("K12a exact restore: both summaries of one multi-anchor snapshot back in full, coverage restored, stub reusing the record; file read and indexed once",
              report.restored == 2 && PruneSummaryRestore.indexCountForTesting == 1
              && a0?.prunedContextSummary == "FULL_SUMMARY_A0" && a1?.prunedContextSummary == "FULL_SUMMARY_A1"
              && a0?.demotedPruneSummaries.isEmpty == true && a0?.prunedContextSummaryCoverage?.complete == true
              && a0?.prunedContextSummaryStub?.record == message(legacy, "REPLY_A0")?.demotedPruneSummaries.first
              && a0?.prunedContextSummaryStub?.record.snapshot == snapshot, "\(report)")
        check("K12b reverse measuredTokens delta returns the pre-demotion value",
              a0?.measuredTokens == 1_000 && message(legacy, "REPLY_A0")?.measuredTokens != 1_000,
              "\(String(describing: a0?.measuredTokens)) vs legacy \(String(describing: message(legacy, "REPLY_A0")?.measuredTokens))")
        check("K12c default 3: the restored history composes to exactly the 0.2.57 messages (same request bytes)",
              encodedSorted(withoutStubs(composed(restored))) == encodedSorted(legacy))
        check("K12d the restored history is on disk; the measurement was cleared first",
              records(diskHistory() ?? []).isEmpty && message(diskHistory() ?? [], "REPLY_A1")?.prunedContextSummary == "FULL_SUMMARY_A1"
              && manager._testLastPromptTokens == nil && usageFile()?["lastPromptTokens"] == nil)
        // A real request after the restore under the default equals 0.2.57's
        // metadata: every rendered note identical.
        var same = true
        for (new, old) in zip(composed(restored), legacy) where await manager._testMetadataNote(new) != (await manager._testMetadataNote(old)) { same = false }
        check("K12e every rendered history note after restore equals the 0.2.57 note", same)

        // Exact bytes: Unicode, internal CRLF, two trailing LFs, a line that
        // merely starts like a marker inside a sentence.
        _ = await freshManager()
        let tricky = "Ünïcode ✓ résumé\r\nline two\nPrior pruning summary: (inline mention)\n\n"
        let (legacy2, _) = try legacySetup(demote: [0]) { h in h[1].prunedContextSummary = tricky }
        let m2 = try await legacyManager(legacy2)
        let r2 = m2.summaryRetentionIdlePass()
        check("K12f exact bytes preserved (Unicode, CRLF, trailing LFs, a marker-like phrase that is not the marker line)",
              r2.restored == 1 && message(m2._testMessages, "REPLY_A0")?.prunedContextSummary == tricky, "\(r2)")
    }

    /// One refusal fixture: `edit` shapes the anchors before demotion,
    /// `damage` the history/snapshot after; the message must stay identical.
    func refusalRow(_ label: String, demote: [Int] = [0], edit: ((inout [Message]) -> Void)? = nil,
                    damage: ((inout [Message], PruneArchiveReference) throws -> Void)? = nil) async throws {
        _ = await freshManager()
        var (history, snapshot) = try legacySetup(demote: demote, edit: edit)
        try damage?(&history, snapshot)
        let manager = try await legacyManager(history)
        func target() -> Data {
            // A non-candidate full anchor may legitimately gain a repaired
            // stub; everything else about the message must stay identical.
            guard var m = manager._testMessages.first(where: { $0.content == "REPLY_A0" }) else { return Data() }
            m.prunedContextSummaryStub = nil
            return encodedSorted(m)
        }
        let before = target()
        let report = manager.summaryRetentionIdlePass()
        let a0 = manager._testMessages.first { $0.content == "REPLY_A0" }
        check("K12 refused — \(label): the message is left byte-identical (stays a pointer)",
              report.restored == 0 && !before.isEmpty && target() == before
              && (a0?.demotedPruneSummaries.isEmpty == false || a0?.prunedContextSummary == "NEWER"), "\(report)")
    }

    func restoreRefusalSection() async throws {
        let coverageDay = { (h: [Message]) -> PruneSummaryCoverage in h[1].prunedContextSummaryCoverage! }
        try await refusalRow("nil-coverage record whose summary contains 'Compact tool log:'", edit: { h in
            h[1].prunedContextSummary = "alpha\nCompact tool log:\nbeta"
        }, damage: { h, snapshot in
            let old = h[1].demotedPruneSummaries[0]
            h[1].demotedPruneSummaries = [try DemotedPruneSummary(line: old.line, snapshot: snapshot, coverage: nil)]
        })
        try await refusalRow("fallback (unrecorded) coverage: no coverage line in the snapshot", edit: { h in
            h[1].prunedContextSummaryCoverage = nil
        })
        try await refusalRow("Codex round 3: fallback coverage C with the summary alpha + L(C) + beta", edit: { h in
            h[1].prunedContextSummaryCoverage = nil
            let fallback = PruneSummaryRetention.legacyCoverage(in: h, anchor: 1)!
            h[1].prunedContextSummary = "alpha\n" + PruneSummaryRestore.coverageLine(fallback) + "\nbeta"
        })
        try await refusalRow("recorded approximate coverage", edit: { h in
            let c = coverageDay(h)
            h[1].prunedContextSummaryCoverage = try! PruneSummaryCoverage(start: c.start, startOffsetSeconds: c.startOffsetSeconds, end: c.end,
                endOffsetSeconds: c.endOffsetSeconds, complete: false, files: c.files)
        })
        try await refusalRow("a duplicated summary marker line", edit: { h in h[1].prunedContextSummary = "alpha\nPrior pruning summary:\nbeta" })
        try await refusalRow("a duplicated coverage marker line", edit: { h in
            h[1].prunedContextSummary = "alpha\n" + PruneSummaryRestore.coveragePrefix + "fake"
        })
        try await refusalRow("several records on one message", damage: { h, snapshot in
            h[1].demotedPruneSummaries.append(self.record(snapshot, label: "second"))
        })
        try await refusalRow("a record plus a newer full summary", damage: { h, _ in h[1].prunedContextSummary = "NEWER" })
        try await refusalRow("wrong lead note (an ordinary prune snapshot)", damage: { h, _ in
            let plain = try PruneArchiveStore.write(messages: [h[1]], trigger: "manual", removedIDs: [h[1].id])
            let old = h[1].demotedPruneSummaries[0]
            h[1].demotedPruneSummaries = [try DemotedPruneSummary(line: old.line, snapshot: plain, coverage: old.coverage)]
        })
        try await refusalRow("message id not listed in the snapshot", damage: { h, _ in
            let other = try PruneArchiveStore.write(messages: [h[3]], trigger: "manual", removedIDs: [h[3].id],
                                                    leadNote: PruneSummaryRetention.snapshotLeadNote)
            let old = h[1].demotedPruneSummaries[0]
            h[1].demotedPruneSummaries = [try DemotedPruneSummary(line: old.line, snapshot: other, coverage: old.coverage)]
        })
        try await refusalRow("malformed UTF-8 inside the file", damage: { _, snapshot in
            let url = self.snapshotDir.appendingPathComponent(snapshot.basename)
            var bytes = [UInt8](try Data(contentsOf: url))
            let needle = Array("FULL_SUMMARY_A0".utf8)
            if let at = (0...(bytes.count - needle.count)).first(where: { Array(bytes[$0..<($0 + needle.count)]) == needle }) { bytes[at] = 0xFF }
            try Data(bytes).write(to: url)
        })
        try await refusalRow("an incomplete file (no end marker)", damage: { _, snapshot in
            let url = self.snapshotDir.appendingPathComponent(snapshot.basename)
            let data = try Data(contentsOf: url)
            try data.prefix(data.count - 40).write(to: url)
        })
        try await refusalRow("a missing file", damage: { _, snapshot in
            try FileManager.default.removeItem(at: self.snapshotDir.appendingPathComponent(snapshot.basename))
        })
    }

    /// Boundary injection (R4-1): headers and end markers inside raw text.
    func restoreInjectionSection() async throws {
        try await refusalRow("an embedded '=== MESSAGE' header with the SAME id", edit: { h in
            h[1].prunedContextSummary = "alpha\n=== MESSAGE 1 | view=durable | id=\(h[1].id) | role=assistant | kind=userText | time=x ===\nbeta"
        })
        try await refusalRow("an embedded '=== MESSAGE' header with ANOTHER id", edit: { h in
            h[1].prunedContextSummary = "alpha\n=== MESSAGE 2 | view=durable | id=\(h[3].id) | role=assistant | kind=userText | time=x ===\nbeta"
        })
        try await refusalRow("combined R4-1: complete coverage C, L(C), then a valid header H for another id", edit: { h in
            let line = PruneSummaryRestore.coverageLine(h[1].prunedContextSummaryCoverage!)
            let header = "=== MESSAGE 2 | view=durable | id=\(h[3].id) | role=assistant | kind=userText | time=2026-09-02T08:00:00Z ==="
            h[1].prunedContextSummary = "alpha\n" + line + "\n" + header + "\nbeta"
        })
        try await refusalRow("combined R4-1 inside a two-anchor snapshot", demote: [0, 1], edit: { h in
            let line = PruneSummaryRestore.coverageLine(h[1].prunedContextSummaryCoverage!)
            let header = "=== MESSAGE 2 | view=durable | id=\(h[3].id) | role=assistant | kind=userText | time=2026-09-02T08:00:00Z ==="
            h[1].prunedContextSummary = "alpha\n" + line + "\n" + header + "\nbeta"
        })
        try await refusalRow("an embedded 'BRIGLIA SNAPSHOT END' line", edit: { h in
            h[1].prunedContextSummary = "alpha\nBRIGLIA SNAPSHOT END 00000000-0000-0000-0000-000000000000\nbeta"
        })
        // Direct parser rows (no history): malformed header-looking line,
        // text after the end marker, swapped ids.
        let ref = randomRef()
        func parse(_ text: String) -> String {
            switch PruneSummaryRestore.index(bytes: Array(text.utf8), reference: ref) {
            case .success: return "accepted"
            case .failure(let refusal): return refusal.reason
            }
        }
        let a = UUID(), b = UUID()
        let header = #"BRIGLIA SNAPSHOT 1 {"created":0,"id":"\#(ref.id.uuidString)","messages":2,"rounds":0,"trigger":"manual","version":1}"#
        let preamble = [header, PruneSummaryRetention.snapshotLeadNote, "c", "c", "c", "c", "c", "Removed message IDs:", a.uuidString, b.uuidString,
                        "Removed active-turn call IDs:", ""]
        let good = preamble + ["=== MESSAGE 1 | view=durable | id=\(a.uuidString) | role=assistant ===", "x",
                               "=== MESSAGE 2 | view=durable | id=\(b.uuidString) | role=assistant ===", "y",
                               "BRIGLIA SNAPSHOT END \(ref.id.uuidString)"]
        let control = parse(good.joined(separator: "\n") + "\n")
        var malformed = good; malformed.insert("=== MESSAGE broken", at: 13)
        var trailing = good; trailing.append("after the end")
        var swapped = good; swapped[12] = "=== MESSAGE 1 | view=durable | id=\(b.uuidString) | role=assistant ==="
        swapped[14] = "=== MESSAGE 2 | view=durable | id=\(a.uuidString) | role=assistant ==="
        var view = good; view[14] = "=== MESSAGE 2 | view=in-flight differing view | id=\(b.uuidString) | role=assistant ==="
        var dup = good; dup[9] = a.uuidString
        let results = [parse(malformed.joined(separator: "\n") + "\n"), parse(trailing.joined(separator: "\n") + "\n"),
                       parse(swapped.joined(separator: "\n") + "\n"), parse(view.joined(separator: "\n") + "\n"),
                       parse(dup.joined(separator: "\n") + "\n"), parse(good.joined(separator: "\n"))]
        check("K12 parser: control accepted; a malformed candidate counts, text after END, swapped ids, a non-durable view, a duplicate listed id (two blocks for one id) and a missing final LF are refused",
              control == "accepted" && results.allSatisfy { $0 != "accepted" }, "\(control) | \(results)")
    }

    /// K8b: the cached measurement is durably cleared BEFORE any restored
    /// text is published; failures never publish a restore.
    func invalidationSection() async throws {
        for (name, limit) in [("all", KeepSummariesLimit.all), ("restored inside the newest N", .count(5))] {
            _ = await freshManager()
            let (legacy, _) = try legacySetup()
            let manager = try await legacyManager(legacy)
            KeepSummariesSetting.store(limit)
            let measuredBefore = manager._testLastPromptTokens
            let report = manager.summaryRetentionIdlePass()
            server.router = { _ in (RetentionHarness.chat("ok", prompt: 4_000), 0) }
            await runTurn(manager, "after restore \(name)")
            server.router = nil
            let userMessage = manager._testMessages.last { $0.content == "after restore \(name)" }
            let restarted = await restart()
            check("K8b (\(name)) restore at idle clears the cached measurement on disk and in memory first; the next turn attributes nothing to its user message; a restart does not bring the old measurement back",
                  measuredBefore == 5_000 && report.restored == 2 && userMessage?.measuredTokens == nil
                  && restarted._testLastPromptTokens == 4_000 && restarted._testPromptRenderKey != PruneSummaryRetention.unknownRenderKey,
                  "before \(String(describing: measuredBefore)) \(report) user \(String(describing: userMessage?.measuredTokens)) restart \(String(describing: restarted._testLastPromptTokens))")
            UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
        }
        // Restart straight after the restore: no measurement at all.
        _ = await freshManager()
        let (legacy, _) = try legacySetup()
        let manager = try await legacyManager(legacy)
        _ = manager.summaryRetentionIdlePass()
        let restarted = await restart()
        check("K8b restart right after a restore: the old measurement is not reloaded",
              restarted._testLastPromptTokens == nil && message(restarted._testMessages, "REPLY_A0")?.prunedContextSummary == "FULL_SUMMARY_A0")
    }

    /// K8b failure points: usage write before rename, after rename (folder
    /// sync), history write before and after replacement.
    func invalidationFaultSection() async throws {
        for point in ["before-write", "after-rename"] {
            _ = await freshManager()
            let (legacy, _) = try legacySetup()
            let manager = try await legacyManager(legacy)
            let diskBefore = try Data(contentsOf: historyURL)
            ConversationManager.usageClearFaultForTesting = { stage in if stage == point { throw PruneArchiveStore.Failure("injected \(point)") } }
            let report = manager.summaryRetentionIdlePass()
            ConversationManager.usageClearFaultForTesting = nil
            let usage = usageFile()
            let usageOK = point == "before-write" ? usage?["lastPromptTokens"] as? Int == 5_000 : usage?["lastPromptTokens"] == nil
            // An independent stub-repair commit may land in the same pass;
            // the two restore candidates stay pointers on disk and in memory.
            _ = diskBefore
            let noRestore = report.restored == 0 && report.measurementClearFailed
                && records(diskHistory() ?? []).count == 2 && records(manager._testMessages).count == 2
            let retry = manager.summaryRetentionIdlePass()
            check("K8b usage clear fails (\(point)): no restored text is published (on disk or in memory; usage \(point == "before-write" ? "old" : "cleared on disk")); retryable",
                  noRestore && usageOK && retry.restored == 2, "\(report) usage \(String(describing: usage)) retry \(retry)")
        }
        for (name, before) in [("before replacement", true), ("after replacement", false)] {
            _ = await freshManager()
            let (legacy, _) = try legacySetup()
            let manager = try await legacyManager(legacy)
            let diskBefore = try Data(contentsOf: historyURL)
            if before { ConversationManager.historyWriteFaultForTesting = { throw PruneArchiveStore.Failure("injected history fault") } }
            else { ConversationManager.historyPostWriteFaultForTesting = { throw PruneArchiveStore.Failure("injected post-write fault") } }
            let report = manager.summaryRetentionIdlePass()
            ConversationManager.historyWriteFaultForTesting = nil
            ConversationManager.historyPostWriteFaultForTesting = nil
            let disk = try Data(contentsOf: historyURL)
            let diskState = before ? disk == diskBefore : (records(diskHistory() ?? []).isEmpty && disk != diskBefore)
            let memoryUnchanged = records(manager._testMessages).count == 2
            let retry = manager.summaryRetentionIdlePass()
            check("K8b history write fails \(name): usage already cleared, the file is \(before ? "old" : "new"), memory unchanged, the restore stays retryable",
                  report.historyWriteFailed && usageFile()?["lastPromptTokens"] == nil && diskState && memoryUnchanged
                  && retry.restored == 2 && records(manager._testMessages).isEmpty, "\(report) retry \(retry)")
        }
    }
}
