import Foundation

/// F1–F3 field handling; W1–W2 (and L4/L5's request half) on real requests.
extension RetentionHarness {

    /// A real demotion; returns the manager and the demoted message.
    func demotedFixture(files: [String] = []) async throws -> (ConversationManager, Message) {
        var h = anchoredHistory(3)
        if !files.isEmpty { h[1].prunedContextSummaryCoverage = coverage(at(2026, 9, 1, 9, 0), at(2026, 9, 1, 10, 0), files: files) }
        let manager = await freshManager(history: h)
        try await pruneLast(manager)
        return (manager, message(manager._testMessages, "REPLY_A0")!)
    }

    func fieldsSection() async throws {
        let (manager, demoted) = try await demotedFixture()
        let record = demoted.demotedPruneSummaries[0]

        // F1: serialization.
        let encoded = try JSONEncoder().encode(demoted)
        let decoded = try JSONDecoder().decode(Message.self, from: encoded)
        var withCoverage = anchor("F1", at: at(2026, 9, 5, 10, 0))
        withCoverage.prunedContextSummaryCoverage = coverage(at(2026, 9, 5, 9, 0), at(2026, 9, 5, 10, 0), complete: false, files: ["x"])
        let cov2 = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(withCoverage))
        check("F1a both fields round-trip", decoded == demoted && decoded.demotedPruneSummaries == [record]
              && cov2.prunedContextSummaryCoverage == withCoverage.prunedContextSummaryCoverage)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "demotedPruneSummaries")
        let older = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: object))
        let olderNote = await manager._testMetadataNote(older) ?? ""
        check("F1b older-shape history without the fields loads; the snapshot reference stays visible as a link",
              older.demotedPruneSummaries.isEmpty && olderNote.contains(record.snapshot.relativePath))
        let plain = Message(role: .assistant, content: "plain", editedFilePaths: ["a"])
        let keys = Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]).keys)
        check("F1c a message without the fields encodes no new keys (byte-identical to before)",
              !keys.contains("prunedContextSummaryCoverage") && !keys.contains("demotedPruneSummaries"), "\(keys.sorted())")
        object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let damagedRecords: [Any] = [["version": 1, "line": "", "snapshot": ["bad": true]] as [String: Any]] + (object["demotedPruneSummaries"] as! [Any])
        object["demotedPruneSummaries"] = damagedRecords
        let damaged = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: object))
        check("F1d a malformed record is dropped and the valid one kept; the message still loads",
              damaged.demotedPruneSummaries == [record])

        // F2: estimates count the wrapper in each estimator's units, exclude
        // the suppressed link, count nothing for coverage.
        let wrapper = PruneSummaryRetention.wrapper(record.line)
        var base = demoted
        base.demotedPruneSummaries = []
        base.pruneArchiveReferences.removeAll { $0.id == record.snapshot.id }
        check("F2a Message.displayTokenCount: + wrapper/4, demotion link not counted",
              demoted.displayTokenCount == base.displayTokenCount + wrapper.count / 4, "\(demoted.displayTokenCount) vs \(base.displayTokenCount)+\(wrapper.count / 4)")
        check("F2b ActiveTurnBudget.message: + text(wrapper), demotion link not counted",
              ActiveTurnBudget.message(demoted) == ActiveTurnBudget.message(base) + ActiveTurnBudget.text(wrapper))
        check("F2c prunedContextSummaryTokens (mid-loop/pre-request estimates): wrapper/4",
              manager._testSummaryNoteTokens(demoted) == wrapper.count / 4 && manager._testSummaryNoteTokens(base) == 0)
        check("F2d estimatedPromptTokens: + wrapper/4, demotion link not counted",
              manager._testPromptTokens(demoted) == manager._testPromptTokens(base) + wrapper.count / 4)
        check("F2e manual-prune noteTokens: + wrapper/4, demotion link not counted",
              ConversationManager.manualPruneNoteTokens([demoted]) == ConversationManager.manualPruneNoteTokens([base]) + wrapper.count / 4)
        var noCoverage = withCoverage; noCoverage.prunedContextSummaryCoverage = nil
        check("F2f coverage metadata adds no tokens in any estimator",
              withCoverage.displayTokenCount == noCoverage.displayTokenCount
              && ActiveTurnBudget.message(withCoverage) == ActiveTurnBudget.message(noCoverage)
              && manager._testPromptTokens(withCoverage) == manager._testPromptTokens(noCoverage)
              && ConversationManager.manualPruneNoteTokens([withCoverage]) == ConversationManager.manualPruneNoteTokens([noCoverage]))
        var measured = anchoredHistory(3)
        measured[1].measuredTokens = 1000
        let m2 = await freshManager(history: measured)
        try await pruneLast(m2)
        let after = message(m2._testMessages, "REPLY_A0")!
        let expected = 1000 - "FULL_SUMMARY_A0".count / 4 + PruneSummaryRetention.wrapper(after.demotedPruneSummaries[0].line).count / 4
        check("F2g measuredTokens adjusted on demotion: − summary/4 + wrapper/4",
              after.measuredTokens == expected, "\(after.measuredTokens ?? -1) vs \(expected)")

        // F3: the archive sanitizer drops both fields.
        let archive = manager._testArchiveService
        let sanitized = await archive._testSanitizeForArchive(demoted)
        let sanitizedCoverage = await archive._testSanitizeForArchive(withCoverage)
        var onlyCoverage = Message(role: .assistant, content: "c"); onlyCoverage.prunedContextSummaryCoverage = withCoverage.prunedContextSummaryCoverage
        var onlyRecords = Message(role: .assistant, content: "r"); onlyRecords.demotedPruneSummaries = [record]
        let needs = await archive._testNeedsArchiveSanitization(onlyCoverage)
        let needsRecords = await archive._testNeedsArchiveSanitization(onlyRecords)
        check("F3 archive sanitizer drops both fields (new chunks), and flags existing archive files holding either for rewrite",
              sanitized.demotedPruneSummaries.isEmpty && sanitizedCoverage.prunedContextSummaryCoverage == nil
              && sanitized.pruneArchiveReferences.contains(record.snapshot) && needs && needsRecords)
    }

    func wireSection() async throws {
        // W1: before demotion, rendering is byte-identical with or without
        // coverage recording, and no request carries a coverage object.
        var notes: [[String]] = []
        let fixed = anchoredHistory(2)
        for recording in [true, false] {
            let manager = await freshManager(history: fixed)
            let snapshotIdentity = (Date(timeIntervalSince1970: 1_790_000_000), UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
            PruneArchiveStore.identityForTesting = { snapshotIdentity }
            defer { PruneArchiveStore.identityForTesting = nil }
            ConversationManager.coverageRecordingDisabledForTesting = !recording
            try await pruneLast(manager)
            ConversationManager.coverageRecordingDisabledForTesting = false
            var rendered: [String] = []
            for m in manager._testMessages { rendered.append(await manager._testMetadataNote(m) ?? "") }
            notes.append(rendered)
        }
        check("W1a every rendered history note before demotion is byte-identical with and without coverage recording",
              notes.count == 2 && notes[0] == notes[1])
        for responses in [false, true] {
            let restore: () -> Void = responses ? try useResponses() : {}
            defer { restore() }
            let (manager, demoted) = try await demotedFixture(files: ["ui/a" + MarkerNeutralizer.markerPrefixPart1 + MarkerNeutralizer.markerPrefixPart2 + "b.html", "src/main.swift"])
            server.clear()
            let reply = text("OK", responses: responses)
            server.router = { _ in (reply, 0) }
            manager._testStartTurn(for: user("next request", at: Date()))
            _ = await manager._testAwaitIdle(timeout: 60)
            server.router = nil
            let bodies = requestBodies()
            let main = bodies.last { $0.contains("next request") } ?? ""
            let text = decodedText(main)
            let record = demoted.demotedPruneSummaries[0]
            let label = responses ? "Responses" : "Chat Completions"
            check("W1b (\(label)) no request carries a separately serialized coverage object",
                  !main.isEmpty && !bodies.contains { $0.contains("prunedContextSummaryCoverage") || $0.contains("startOffsetSeconds")
                                                       || $0.contains("demotedPruneSummaries") })
            let expectedLine = MarkerNeutralizer.escape(PruneSummaryRetention.wrapper(record.line))
            check("W2 (\(label)) the demoted wrapper line replaces the full summary, with exactly one snapshot link",
                  Self.occurrences(expectedLine, in: text) == 1 && !text.contains("FULL_SUMMARY_A0")
                  && Self.occurrences(record.snapshot.basename, in: text) == 1 && text.contains("FULL_SUMMARY_A1"),
                  String(text.prefix(300)))
            check("L4b (\(label)) marker text in a file name is neutralized in the rendered request",
                  // The system prompt legitimately explains the marker, so
                  // assert on the rendered file name itself.
                  record.line.contains("ui/a" + MarkerNeutralizer.reservedPrefix + "b.html")
                  && !text.contains("ui/a" + MarkerNeutralizer.reservedPrefix) && text.contains("ui/a" + MarkerNeutralizer.neutralizedForm + "b.html"),
                  "line has marker \(record.line.contains(MarkerNeutralizer.reservedPrefix)) raw \(main.contains(MarkerNeutralizer.reservedPrefix)) text \(text.contains(MarkerNeutralizer.reservedPrefix)) neutral \(text.contains(MarkerNeutralizer.neutralizedForm)) line: \(record.line)")
            let note = await manager._testMetadataNote(demoted) ?? ""
            let again = await manager._testMetadataNote(demoted) ?? ""
            check("L5b (\(label)) the generic link for the demotion snapshot is not rendered twice; rendering is stable",
                  note == again && Self.occurrences(record.snapshot.basename, in: note) == 1)
        }
    }
}
