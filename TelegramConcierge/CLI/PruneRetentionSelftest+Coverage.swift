import Foundation

/// C1–C10: coverage recorded at prune time (v5 rule: exact only from
/// recorded times; a carried active-turn summary or an undated round is
/// approximate; proximity never certifies a start).
extension RetentionHarness {

    func carried(_ text: String) -> ActiveTurnCompaction {
        try! ActiveTurnCompaction(summaryText: text, reference: randomRef(), through: 1)
    }

    /// C1, C3, C4, C5, C7, C8, C10.
    func coverageRecordSection() async throws {
        // C1: manifest messages only; in-flight rounds and others ignored.
        var history = [
            user("U0", at: at(2026, 9, 27, 7, 0)),
            toolTurn("C1A", at: at(2026, 9, 27, 10, 0), issued: [at(2026, 9, 27, 9, 0), at(2026, 9, 27, 9, 30)], edited: ["src/a.swift"]),
            user("U1", at: at(2026, 9, 27, 10, 5)),
            toolTurn("C1B", at: at(2026, 9, 27, 10, 20), issued: [at(2026, 9, 27, 10, 10)], generated: ["out/b.txt"]),
        ]
        var outside = user("U2", at: at(2026, 9, 27, 12, 0)); outside.editedFilePaths = ["src/outside.swift"]
        history.append(outside)
        var manager = await freshManager(history: history)
        let inFlight = [round("live", issued: at(2026, 9, 27, 6, 0))]
        _ = try await manager._testRetentionPrune(affected: [1, 3], trigger: "manual", currentRounds: inFlight, summary: "C1_SUMMARY")
        let c1 = manager._testMessages[3].prunedContextSummaryCoverage
        check("C1 coverage = min/max of manifest times with offsets and manifest files; others ignored",
              c1?.start == at(2026, 9, 27, 9, 0) && c1?.end == at(2026, 9, 27, 10, 20) && c1?.startOffsetSeconds == 7200
              && c1?.endOffsetSeconds == 7200 && c1?.complete == true && c1?.files == ["out/b.txt", "src/a.swift"],
              "\(String(describing: c1))")

        // C3: append onto recorded coverage → union, complete ANDed.
        var withRecorded = anchor("C3", at: at(2026, 9, 26, 10, 0), files: ["old.swift"])
        withRecorded.prunedContextSummaryCoverage = coverage(at(2026, 9, 26, 9, 0), at(2026, 9, 26, 10, 0), complete: false, files: ["old.swift"])
        withRecorded.toolInteractions = [round("c3", issued: at(2026, 9, 28, 8, 0))]
        withRecorded.generatedFilePaths = ["new.swift"]
        manager = await freshManager(history: [withRecorded])
        _ = try await manager._testRetentionPrune(affected: [0], trigger: "manual", summary: "C3_APPENDED")
        let c3 = manager._testMessages[0].prunedContextSummaryCoverage
        check("C3a append onto recorded coverage: union of times and files, complete ANDed",
              c3?.start == at(2026, 9, 26, 9, 0) && c3?.end == at(2026, 9, 28, 8, 0) && c3?.complete == false
              && c3?.files == ["old.swift", "new.swift"] && manager._testMessages[0].prunedContextSummary == "FULL_SUMMARY_C3\n\nC3_APPENDED",
              "\(String(describing: c3))")
        var legacy = anchor("C3L", at: at(2026, 9, 26, 10, 0), recorded: false)
        legacy.toolInteractions = [round("c3l", issued: at(2026, 9, 26, 9, 50))]
        manager = await freshManager(history: [legacy])
        _ = try await manager._testRetentionPrune(affected: [0], trigger: "manual", summary: "C3L_APPENDED")
        let c3l = manager._testMessages[0].prunedContextSummaryCoverage
        let c3line = c3l.flatMap { PruneSummaryRetention.line(for: $0, snapshot: ref()) } ?? ""
        check("C3b append onto a legacy summary → complete = false → approx. prefix",
              c3l?.complete == false && c3line.hasPrefix(PruneSummaryRetention.approxPrefix), c3line)

        // C4: archive boundary through recorded coverage (Codex's example).
        history = [
            user("U27", at: at(2026, 9, 27, 9, 0)),
            toolTurn("D27", at: at(2026, 9, 27, 10, 0), issued: [at(2026, 9, 27, 9, 30)], edited: ["src/day27.swift"]),
            user("U28", at: at(2026, 9, 28, 9, 0)),
            toolTurn("D28", at: at(2026, 9, 28, 10, 0), issued: [at(2026, 9, 28, 9, 30)], edited: ["src/day28.swift"]),
            user("U29", at: at(2026, 9, 29, 9, 0)),
            toolTurn("D29", at: at(2026, 9, 29, 10, 0), issued: [at(2026, 9, 29, 9, 30)], edited: ["src/day29.swift"]),
        ]
        manager = await freshManager(history: history)
        _ = try await manager._testRetentionPrune(affected: [1, 3, 5], trigger: "manual", summary: "C4_SUMMARY")
        var after = Array(manager._testMessages.dropFirst(2)) // the 27 Sep messages leave live history
        for i in 0..<3 { after.append(user("UN\(i)", at: at(2026, 9, 30 - 0, 9 + i, 0))); after.append(anchor("N\(i)", at: at(2026, 9, 30, 9 + i, 30))) }
        after.append(user("U_TAIL", at: at(2026, 9, 30, 15, 0)))
        after.append(toolTurn("TAIL", at: at(2026, 9, 30, 16, 0), issued: [at(2026, 9, 30, 15, 30)]))
        manager._testSeedHistory(after)
        try await pruneLast(manager)
        let c4 = message(manager._testMessages, "REPLY_D29")?.demotedPruneSummaries.first?.line ?? ""
        check("C4 archived start: the demoted line still shows 27 Sep and its files",
              c4.hasPrefix("Earlier work 27 Sep 2026 09:30 – 29 Sep 2026 10:00 (UTC+02:00)") && c4.contains("day27.swift"), c4)

        // C5: re-demotion uses the second prune's coverage; the first record stays.
        manager = await freshManager(history: anchoredHistory(3))
        try await pruneLast(manager)
        let first = message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries
        var reanchored = manager._testMessages
        let a0 = reanchored.firstIndex { $0.content == "REPLY_A0" }!
        reanchored[a0].toolInteractions = [round("again", issued: at(2026, 9, 25, 8, 0))]
        manager._testReplaceMessages(reanchored); _ = manager._testSave()
        _ = try await manager._testRetentionPrune(affected: [a0], trigger: "manual", summary: "A0_AGAIN")
        let second = message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries ?? []
        check("C5 re-demotion: second record carries the second prune's coverage; first unchanged",
              second.count == 2 && second.first == first?.first && second[1].coverage?.start == at(2026, 9, 1, 10, 0)
              && second[1].coverage?.end == at(2026, 9, 25, 8, 0) && second[1].snapshot != second[0].snapshot,
              "\(second.map(\.line))")

        // C7: rendering does not depend on the device zone at demotion.
        var lines: [String] = []
        for deviceZone in [TimeZone(secondsFromGMT: -18000)!, TimeZone(secondsFromGMT: 32400)!] {
            var h = anchoredHistory(3)
            h[1].prunedContextSummaryCoverage = coverage(at(2026, 10, 24, 22, 0, offset: 7200), at(2027, 1, 2, 3, 0, offset: 3600), so: 7200, eo: 3600)
            manager = await freshManager(history: h)
            PruneSummaryRetention.timeZoneForTesting = deviceZone
            try await pruneLast(manager)
            let line = message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries.first?.line ?? ""
            lines.append(line.components(separatedBy: PruneSummaryRetention.linkPrefix).first ?? "")
        }
        PruneSummaryRetention.timeZoneForTesting = zone
        check("C7 cross-DST + cross-year recorded coverage renders identically under any device zone",
              lines.count == 2 && lines[0] == lines[1] && lines[0].hasPrefix("Earlier work 24 Oct 2026 22:00 (UTC+02:00) – 2 Jan 2027 03:00 (UTC+01:00)"),
              lines.joined(separator: " | "))

        try await invalidCoverageRows()
        try await undatedRoundRows()
    }

    /// C8: invalid coverage decodes as absent; history still loads.
    func invalidCoverageRows() async throws {
        func json(_ c: [String: Any]) -> [String: Any] {
            ["id": UUID().uuidString, "role": "assistant", "content": "REPLY_BAD", "timestamp": 800_000_000.0,
             "prunedContextSummary": "BAD_COVERAGE_SUMMARY", "prunedContextSummaryCoverage": c]
        }
        let good: [String: Any] = ["version": 1, "start": 800_000_000.0, "startOffsetSeconds": 7200, "end": 800_000_100.0,
                                   "endOffsetSeconds": 7200, "complete": true, "files": ["a"]]
        var variants: [(String, [String: Any])] = []
        var v = good; v["end"] = 799_000_000.0; variants.append(("end < start", v))
        v = good; v["start"] = -63_000_000_000.0; variants.append(("year 0001", v))
        v = good; v["endOffsetSeconds"] = 72_000; variants.append(("offset +20 h", v))
        v = good; v["files"] = (0..<21).map { "f\($0)" }; variants.append(("21 files", v))
        v = good; v["files"] = ["a\u{0}b"]; variants.append(("NUL in a file", v))
        var allAbsent = true, details: [String] = []
        for (name, coverage) in variants {
            resetState()
            let data = try JSONSerialization.data(withJSONObject: [json(good), json(coverage)])
            try PrivateStorage.writeAtomically(data, to: historyURL)
            let manager = await restart()
            let loaded = manager._testMessages
            if loaded.count != 2 || manager._testHistoryLoadFailure != nil || loaded[1].prunedContextSummaryCoverage != nil
                || loaded[0].prunedContextSummaryCoverage == nil || loaded[1].prunedContextSummary != "BAD_COVERAGE_SUMMARY" {
                allAbsent = false; details.append(name)
            }
        }
        check("C8a invalid coverage (end<start, year 0001, +20 h, 21 files, NUL) decodes as absent; history loads",
              allAbsent, details.joined(separator: ", "))
        // ...and the legacy (approx.) rule applies at demotion.
        var h = anchoredHistory(3)
        h[1].prunedContextSummaryCoverage = nil
        let manager = await freshManager(history: h)
        try await pruneLast(manager)
        let line = message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries.first?.line ?? ""
        check("C8b an anchor without valid coverage is demoted under the legacy approx. rule",
              line.hasPrefix(PruneSummaryRetention.approxPrefix), line)
    }

    /// C10: no verified start → approx.; all-dated control is exact and
    /// starts at the earliest issuedAt, not at the reply's own time.
    func undatedRoundRows() async throws {
        let mixed = toolTurn("C10M", at: at(2026, 9, 27, 10, 0), issued: [at(2026, 9, 27, 9, 10), nil])
        var manager = await freshManager(history: [user("U", at: at(2026, 9, 27, 9, 0)), mixed])
        _ = try await manager._testRetentionPrune(affected: [1], trigger: "manual", summary: "C10_MIXED")
        let cm = manager._testMessages[1].prunedContextSummaryCoverage
        let lm = cm.flatMap { PruneSummaryRetention.line(for: $0, snapshot: ref()) } ?? ""
        check("C10a one dated + one undated round → complete = false, approx. prefix",
              cm?.complete == false && lm.hasPrefix(PruneSummaryRetention.approxPrefix), lm)
        let dated = toolTurn("C10D", at: at(2026, 9, 27, 10, 0), issued: [at(2026, 9, 27, 9, 10), at(2026, 9, 27, 9, 20)])
        manager = await freshManager(history: [user("U", at: at(2026, 9, 27, 8, 0)), dated])
        _ = try await manager._testRetentionPrune(affected: [1], trigger: "manual", summary: "C10_DATED")
        let cd = manager._testMessages[1].prunedContextSummaryCoverage
        let ld = cd.flatMap { PruneSummaryRetention.line(for: $0, snapshot: ref()) } ?? ""
        check("C10b every round dated, nothing carried → exact; start = earliest issuedAt (09:10), not the reply (10:00)",
              cd?.complete == true && cd?.start == at(2026, 9, 27, 9, 10) && ld.hasPrefix("Earlier work 27 Sep 2026 09:10–10:00"), ld)
    }

    /// C2, C6, C9.
    func coverageCarriedSection() async throws {
        // C2: a carried active-turn summary is always approximate.
        for withUser in [true, false] {
            var reply = toolTurn("C2", at: at(2026, 9, 27, 10, 0), issued: [at(2026, 9, 27, 9, 50)])
            reply.activeTurnCompaction = carried("compacted earlier work")
            let history = (withUser ? [user("U_C2", at: at(2026, 9, 27, 8, 30))] : []) + [reply]
            let manager = await freshManager(history: history)
            _ = try await manager._testRetentionPrune(affected: [history.count - 1], trigger: "manual", summary: "C2_SUMMARY")
            let c = manager._testMessages.last?.prunedContextSummaryCoverage
            let l = c.flatMap { PruneSummaryRetention.line(for: $0, snapshot: ref()) } ?? ""
            check("C2\(withUser ? "a" : "b") carried activeTurnCompaction → complete = false, approx. prefix (\(withUser ? "user hint widens the start" : "no preceding user"))",
                  c?.complete == false && l.hasPrefix(PruneSummaryRetention.approxPrefix)
                  && c?.start == (withUser ? at(2026, 9, 27, 8, 30) : at(2026, 9, 27, 9, 50)), l)
        }

        // C6: legacy anchor; same derivation before and after a restart.
        var h = anchoredHistory(3)
        h.insert(user("U_LEGACY", at: at(2026, 8, 30, 9, 0)), at: 0)
        h[2].prunedContextSummaryCoverage = nil
        h[2].editedFilePaths = ["legacy/kept.swift"]
        var manager = await freshManager(history: h)
        let before = PruneSummaryRetention.legacyCoverage(in: manager._testMessages, anchor: 2)
            .flatMap { PruneSummaryRetention.line(for: $0, snapshot: ref()) }
        manager = await restart()
        let afterRestart = PruneSummaryRetention.legacyCoverage(in: manager._testMessages, anchor: 2)
            .flatMap { PruneSummaryRetention.line(for: $0, snapshot: ref()) }
        try await pruneLast(manager)
        let demoted = message(manager._testMessages, "REPLY_A0")?.demotedPruneSummaries.first?.line ?? ""
        check("C6 legacy anchor after restart: approx. prefix, span/files from surviving messages, same before and after",
              before != nil && before == afterRestart && demoted.hasPrefix("Earlier work, approx. 30 Aug 2026 09:00 – 1 Sep 2026 10:00 (UTC+02:00)")
              && demoted.contains("kept.swift"), "\(before ?? "nil") | \(demoted)")

        try await codexFollowUpRows()
    }

    /// C9: opening request 09:00, compacted work, mid-turn follow-up 09:45,
    /// reply with the carried summary 10:00. Never an exact 09:45 start.
    func codexFollowUpRows() async throws {
        func history(openArchived: Bool, progress: Bool) -> [Message] {
            var h: [Message] = []
            if !openArchived { h.append(user("open the task", at: at(2026, 9, 27, 9, 0))) }
            if progress {
                h.append(Message(role: .assistant, content: "progress: halfway", timestamp: at(2026, 9, 27, 9, 20)))
                h.append(Message(role: .assistant, content: "⛔ Turn interrupted", timestamp: at(2026, 9, 27, 9, 30)))
                h.append(user("continue", at: at(2026, 9, 27, 9, 40)))
            }
            h.append(user("follow-up instructions", at: at(2026, 9, 27, 9, 45)))
            var reply = toolTurn("C9", at: at(2026, 9, 27, 10, 0), issued: [at(2026, 9, 27, 9, 50)], edited: ["src/c9.swift"])
            reply.activeTurnCompaction = carried("work from 09:00 onward, compacted")
            h.append(reply)
            for i in 0..<3 { h.append(user("UN\(i)", at: at(2026, 9, 28, 9 + i, 0))); h.append(anchor("N\(i)", at: at(2026, 9, 28, 9 + i, 30))) }
            return h
        }
        let variants: [(String, Bool, Bool, Bool)] = [("a as described", false, false, false), ("b after a restart", true, false, false),
                                                      ("c opening request archived", false, true, false), ("d progress + interrupted/resumed turn", false, false, true)]
        for (name, restartFirst, openArchived, progress) in variants {
            let h = history(openArchived: openArchived, progress: progress)
            var manager = await freshManager(history: h)
            if restartFirst { manager = await restart() }
            let replyIndex = manager._testMessages.firstIndex { $0.content == "REPLY_C9" }!
            _ = try await manager._testRetentionPrune(affected: [replyIndex], trigger: "manual", summary: "C9_SUMMARY")
            let reply = message(manager._testMessages, "REPLY_C9")
            let record = reply?.demotedPruneSummaries.first
            let notes = await manager._testMetadataNote(reply ?? Message(role: .assistant, content: "")) ?? ""
            check("C9\(name.prefix(1)) \(name): demoted with complete = false and the approx. prefix, never an exact 09:45 start",
                  record?.coverage?.complete == false && record?.line.hasPrefix(PruneSummaryRetention.approxPrefix) == true
                  && !notes.contains(PruneSummaryRetention.wrapperPrefix + PruneSummaryRetention.exactPrefix),
                  record?.line ?? "no record")
        }
    }
}
