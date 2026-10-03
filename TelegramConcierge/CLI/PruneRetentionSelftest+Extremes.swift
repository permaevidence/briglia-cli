import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// X1–X8: persisted coverage metadata is untrusted. Extreme or malformed
/// numbers (Int.min/Int.max offsets, huge or pre-year-1000 dates, extreme
/// measuredTokens) are dropped as absent and never trap: through startup,
/// load, prune + demotion, merge, retention protection and Mind import.
extension RetentionHarness {

    /// ±50,401 is just past the accepted ±14:00; ±53,969/53,970 straddle the
    /// Linux `DateFormatter` trap (≥ ±53,970 s rounds to ±15:00 and traps);
    /// ±64,800 (±18:00) was accepted before and crashed Linux.
    static let extremeOffsets: [Int] = [Int.min, Int.min + 1, Int.max, -64_801, 64_801, -64_800, 64_800,
                                        -54_000, 54_000, -53_970, 53_970, -53_969, 53_969, -50_401, 50_401]
    /// A date that renders as year "2000" in yyyy (year of era), but BC.
    func bcYear2000() -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(era: 0, year: 2000, month: 6, day: 1))!.timeIntervalSinceReferenceDate
    }
    var extremeDates: [(String, Double)] {
        [("1e308", 1e308), ("-1e308", -1e308), ("greatestFinite", Double.greatestFiniteMagnitude),
         ("9.3e18", 9.3e18), ("-9.3e18", -9.3e18), ("2000 BC", bcYear2000())]
    }

    func goodCoverageJSON() -> [String: Any] {
        ["version": 1, "start": 800_000_000.0, "startOffsetSeconds": 7200, "end": 800_000_100.0,
         "endOffsetSeconds": 7200, "complete": true, "files": ["a"]]
    }

    /// Every invalid coverage variant: each offset field at each extreme,
    /// each date field at each extreme date.
    func extremeCoverageVariants() -> [(String, [String: Any])] {
        var out: [(String, [String: Any])] = []
        for field in ["startOffsetSeconds", "endOffsetSeconds"] {
            for value in Self.extremeOffsets { var c = goodCoverageJSON(); c[field] = value; out.append(("\(field)=\(value)", c)) }
        }
        for field in ["start", "end"] {
            for (name, value) in extremeDates {
                var c = goodCoverageJSON(); c[field] = value
                if field == "start" { c["end"] = max(value, 800_000_100.0) } else { c["start"] = min(value, 800_000_000.0) }
                out.append(("\(field)=\(name)", c))
            }
        }
        return out
    }

    func demotedJSON(_ ref: PruneArchiveReference, coverage: [String: Any]) throws -> [String: Any] {
        var r = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record(ref, label: "x"))) as! [String: Any]
        r["coverage"] = coverage
        return r
    }

    func extremesSection() async throws {
        _ = await freshManager() // creates the scratch data root
        startupChildRows()
        constructionRows()
        try await loadRows()
        try await pruneAndMergeRows()
        try await protectionAndMindRows()
    }

    // MARK: X1 startup in a child process (a trap must not kill the suite)

    func startupChildRows() {
        // The child's own (hard-linked, privately named) executable, NOT the
        // resolved build product: the preference domain follows the name.
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        guard source.lastPathComponent == PruneRetentionSelftest.childName,
              ProcessInfo.processInfo.environment["HOME"]?.contains("briglia-prune-retention-") == true else {
            check("X1 startup child probe (refused: not running as the isolated child)", false); return
        }
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("x1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        var results: [String] = []
        var allOK = true
        let cases: [(String, String, Int)] = [("full", "startOffsetSeconds", Int.min), ("full", "endOffsetSeconds", Int.min),
                                              ("demoted", "startOffsetSeconds", Int.min), ("demoted", "endOffsetSeconds", Int.min),
                                              ("full", "startOffsetSeconds", Int.max), ("full", "startOffsetSeconds", 72_000),
                                              ("full", "startOffsetSeconds", 64_800), ("demoted", "endOffsetSeconds", -64_800),
                                              ("full", "endOffsetSeconds", 53_970), ("demoted", "startOffsetSeconds", -54_000)]
        for (index, (placement, field, value)) in cases.enumerated() {
            let root = probe.appendingPathComponent("\(index)")
            let config = root.appendingPathComponent("config"), data = root.appendingPathComponent("data/briglia")
            try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            var coverage = goodCoverageJSON(); coverage[field] = value
            var message: [String: Any] = ["id": UUID().uuidString, "role": "assistant", "content": "fixture",
                                          "timestamp": 800_000_100.0, "prunedContextSummary": "Keep this summary"]
            if placement == "full" { message["prunedContextSummaryCoverage"] = coverage }
            else { message["demotedPruneSummaries"] = [try! demotedJSON(randomRef(), coverage: coverage)] }
            let history = data.appendingPathComponent("conversation.json")
            let bytes = try! JSONSerialization.data(withJSONObject: [message])
            try! bytes.write(to: history)
            var env = ProcessInfo.processInfo.environment
            env["XDG_CONFIG_HOME"] = config.path
            env["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
            env["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
            env["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
            let process = Process()
            process.executableURL = source
            process.arguments = ["chat"]
            process.environment = env
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var line = "\(placement) \(field)=\(value): "
            do {
                try process.run()
                input.fileHandleForWriting.write(Data("/exit\n".utf8))
                try? input.fileHandleForWriting.close()
                let deadline = Date().addingTimeInterval(30)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { process.terminate(); process.waitUntilExit(); line += "timeout"; allOK = false }
                else {
                    let exited = process.terminationReason == .exit
                    let preserved = (try? Data(contentsOf: history)) == bytes
                    line += exited ? "exit \(process.terminationStatus)" : "SIGNAL \(process.terminationStatus)"
                    if !preserved { line += " history changed" }
                    if !exited || !preserved { allOK = false }
                }
            } catch { line += "launch failed \(error)"; allOK = false }
            results.append(line)
        }
        check("X1 startup with Int.min/Int.max/out-of-range saved offsets (full and demoted coverage): no trap, history bytes kept",
              allOK, results.joined(separator: "; "))
    }

    // MARK: X2 direct construction and rendering helpers

    func constructionRows() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var bad: [String] = []
        for value in Self.extremeOffsets {
            if (try? PruneSummaryCoverage(start: base, startOffsetSeconds: value, end: base, endOffsetSeconds: 0, complete: true, files: [])) != nil { bad.append("so=\(value)") }
            if (try? PruneSummaryCoverage(start: base, startOffsetSeconds: 0, end: base, endOffsetSeconds: value, complete: true, files: [])) != nil { bad.append("eo=\(value)") }
            if PruneSummaryRetention.localYear(base, offset: value) != nil { bad.append("localYear(\(value))") }
        }
        let nonFinite: [Double] = [.nan, .infinity, -.infinity] + extremeDates.map(\.1)
        for t in nonFinite {
            let d = Date(timeIntervalSinceReferenceDate: t)
            if (try? PruneSummaryCoverage(start: d, startOffsetSeconds: 0, end: d, endOffsetSeconds: 0, complete: true, files: [])) != nil { bad.append("date \(t)") }
            if PruneSummaryRetention.localYear(d, offset: 0) != nil { bad.append("localYear(date \(t))") }
        }
        for o in [-50_400, 50_400] {
            if (try? PruneSummaryCoverage(start: base, startOffsetSeconds: o, end: base, endOffsetSeconds: o, complete: true, files: [])) == nil { bad.append("boundary \(o) rejected") }
        }
        check("X2 extreme offsets/dates (Int.min/max, ±64,801, ±64,800, ±54,000, ±53,970, ±53,969, ±50,401, NaN, ±inf, ±1e308, 9.3e18, 2000 BC) rejected without trapping; ±50,400 accepted",
              bad.isEmpty, bad.joined(separator: ", "))
        renderRows()
        let labels = [Chronology.offsetLabel(seconds: 7200), Chronology.offsetLabel(seconds: -34_200), Chronology.offsetLabel(seconds: 0),
                      Chronology.offsetLabel(seconds: 64_800), Chronology.offsetLabel(seconds: -64_800)]
        let extreme = [Chronology.offsetLabel(seconds: Int.min), Chronology.offsetLabel(seconds: Int.max)]
        check("X2b offsetLabel output unchanged for real offsets and non-trapping at Int.min/Int.max",
              labels == ["UTC+02:00", "UTC-09:30", "UTC+00:00", "UTC+18:00", "UTC-18:00"] && extreme.allSatisfy { $0.hasPrefix("UTC") },
              (labels + extreme).joined(separator: " "))
    }

    // MARK: X2c/X2d rendering every accepted offset (Linux formatter trap)

    /// Every offset the validator accepts must format on both Foundations.
    /// Quarter hours across ±14:00 plus odd seconds, each at the earliest and
    /// latest renderable local minute and a present-day date, same and mixed
    /// endpoint offsets. A trap here kills the suite (as on Linux CI).
    func renderRows() {
        // Odd seconds only at present-day dates: Foundation rounds a
        // sub-minute zone, so midnight 1 Jan 1000 in it can render as 999
        // and is (correctly) rejected; real offsets are whole minutes.
        let oddSeconds = [-50_399, 50_399, -1, 1, 12_345, -12_345]
        let offsets = Array(stride(from: -50_400, through: 50_400, by: 900)) + [19_800, 20_700, 31_500, 45_900, -34_200] + oddSeconds
        var bad: [String] = []
        var rendered = 0
        for o in offsets {
            let odd = oddSeconds.contains(o)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: o)!
            let first = calendar.date(from: DateComponents(year: 1000, month: 1, day: 1, hour: 0, minute: 0))!
            let last = calendar.date(from: DateComponents(year: 9999, month: 12, day: 31, hour: 23, minute: 59))!
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let cases = [(now, now.addingTimeInterval(86_400), o), (now, now, -o)] + (odd ? [] : [(first, first, o), (last, last, o)])
            for (start, end, eo) in cases {
                guard let c = try? PruneSummaryCoverage(start: start, startOffsetSeconds: o, end: end, endOffsetSeconds: eo, complete: true, files: []) else {
                    bad.append("\(o)/\(eo) rejected"); continue
                }
                let span = PruneSummaryRetention.span(c)
                rendered += 1
                if span.isEmpty || !span.contains("UTC") { bad.append("\(o) span '\(span)'") }
            }
            if !odd, PruneSummaryRetention.localYear(first, offset: o) != 1000 { bad.append("\(o) first year") }
            if !odd, PruneSummaryRetention.localYear(last, offset: o) != 9999 { bad.append("\(o) last year") }
        }
        check("X2c every accepted offset (±14:00 quarter hours, real half/three-quarter hours; odd seconds today only) formats at years 1000/9999 and today without trapping (\(rendered) spans)",
              bad.isEmpty, bad.prefix(10).joined(separator: ", "))
        // The formatter cache itself never hands an out-of-range offset to
        // Foundation, even if a future caller skips validation.
        let probe = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let utc = PruneSummaryRetention.formatter("yyyy-MM-dd HH:mm", offset: 0).string(from: probe)
        let direct = [64_800, -64_800, 54_000, -53_970, Int.min, Int.max].map {
            PruneSummaryRetention.formatter("yyyy-MM-dd HH:mm", offset: $0).string(from: probe)
        }
        check("X2d formatter(_:offset:) with unvalidated ±64,800/54,000/−53,970/Int.min/Int.max falls back to UTC without trapping",
              utc == "2026-05-09 06:13" && direct.allSatisfy { $0 == utc }, ([utc] + direct).joined(separator: " | "))
    }

    // MARK: X3 loader

    func loadRows() async throws {
        var failed: [String] = []
        for (name, coverage) in extremeCoverageVariants() {
            resetState()
            let snapshot = randomRef()
            let full: [String: Any] = ["id": UUID().uuidString, "role": "assistant", "content": "X3_FULL", "timestamp": 800_000_000.0,
                                       "prunedContextSummary": "X3_SUMMARY", "prunedContextSummaryCoverage": coverage]
            let demoted: [String: Any] = ["id": UUID().uuidString, "role": "assistant", "content": "X3_DEMOTED", "timestamp": 800_000_100.0,
                                          "demotedPruneSummaries": [try demotedJSON(snapshot, coverage: coverage)]]
            try PrivateStorage.writeAtomically(try JSONSerialization.data(withJSONObject: [full, demoted]), to: historyURL)
            let loaded = (await restart())._testMessages
            let f = message(loaded, "X3_FULL"), d = message(loaded, "X3_DEMOTED")
            let ok = loaded.count == 2 && f?.prunedContextSummary == "X3_SUMMARY" && f?.prunedContextSummaryCoverage == nil
                && d?.demotedPruneSummaries.count == 1 && d?.demotedPruneSummaries.first?.coverage == nil
                && d?.demotedPruneSummaries.first?.snapshot == snapshot && d?.demotedPruneSummaries.first?.line.isEmpty == false
            if !ok { failed.append(name) }
        }
        check("X3 loader: each extreme coverage (\(extremeCoverageVariants().count) variants) drops only the coverage; full summary kept; demoted line + snapshot kept",
              failed.isEmpty, failed.joined(separator: ", "))
    }

    // MARK: X4 prune + demotion render + merge (and saturating measuredTokens)

    func pruneAndMergeRows() async throws {
        var failed: [String] = []
        for (name, coverage) in [("startOffsetSeconds=Int.min", Int.min), ("endOffsetSeconds=Int.max", Int.max)].map({ pair -> (String, [String: Any]) in
            var c = goodCoverageJSON(); c[pair.0.hasPrefix("start") ? "startOffsetSeconds" : "endOffsetSeconds"] = pair.1; return (pair.0, c)
        }) + [("start=2000 BC", { var c = goodCoverageJSON(); c["start"] = bcYear2000(); return c }())] {
            resetState()
            var history = try JSONSerialization.jsonObject(with: JSONEncoder().encode(anchoredHistory(3))) as! [[String: Any]]
            // A0 (oldest anchor, demoted by this prune) and the tail (the prune's
            // own anchor, merged onto) both carry the bad coverage; A0 also
            // carries an extreme measuredTokens.
            history[1]["prunedContextSummaryCoverage"] = coverage
            // Both overflow directions of the demotion's token adjustment:
            // Int.max with a short summary (the wrapper adds tokens), Int.min
            // with a long one (the demotion removes tokens).
            let positive = name.hasPrefix("start=") || name.hasPrefix("startOffset")
            history[1]["measuredTokens"] = positive ? Int.max : Int.min
            if !positive { history[1]["prunedContextSummary"] = String(repeating: "long summary ", count: 400) }
            history[history.count - 1]["prunedContextSummary"] = "TAIL_PRIOR"
            history[history.count - 1]["prunedContextSummaryCoverage"] = coverage
            try PrivateStorage.writeAtomically(try JSONSerialization.data(withJSONObject: history), to: historyURL)
            let manager = await restart()
            try await pruneLast(manager)
            let after = manager._testMessages
            let a0 = message(after, "REPLY_A0"), tail = message(after, "REPLY_TAIL")
            let line = a0?.demotedPruneSummaries.first?.line ?? ""
            let merged = tail?.prunedContextSummaryCoverage
            let ok = line.hasPrefix(PruneSummaryRetention.approxPrefix) && a0?.prunedContextSummary == nil
                && a0?.measuredTokens == (positive ? Int.max : 1)
                && merged?.isValid == true && merged?.complete == false
                && (diskHistory().map { message($0, "REPLY_A0")?.demotedPruneSummaries.count == 1 } ?? false)
            if !ok { failed.append("\(name): line '\(line)' merged \(String(describing: merged)) measured \(String(describing: a0?.measuredTokens))") }
        }
        check("X4 prune over extreme saved coverage: demotes under the legacy approx. rule, merge falls back to approx., measuredTokens saturates; no trap",
              failed.isEmpty, failed.joined(separator: " | "))
    }

    // MARK: X5 protection, X6 Mind import

    func protectionAndMindRows() async throws {
        let (manager, f) = try await protectionFixture()
        var history = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manager._testMessages)) as! [[String: Any]]
        var bad = goodCoverageJSON(); bad["startOffsetSeconds"] = Int.min
        history[1]["demotedPruneSummaries"] = [try demotedJSON(f.protected[0], coverage: bad), try demotedJSON(f.protected[1], coverage: bad)]
        try PrivateStorage.writeAtomically(try JSONSerialization.data(withJSONObject: history), to: historyURL)
        var live: Set<UUID> = []
        if case .snapshots(let ids) = PruneSummaryRetention.liveDemotionSnapshots(historyFile: historyURL) { live = ids }
        try PruneArchiveStore.retainLatest()
        check("X5 retention with Int.min coverage on surviving demoted records: still live, snapshots protected",
              live.isSuperset(of: Set(f.protected.map(\.id))), "live \(live.count)")
        protectionHolds("X5b ... and the oldest unprotected snapshot is still deleted", f)

        // The committed history (with the extreme values) goes into the
        // Mind archive as saved; import stages, validates and applies it.
        let mind = FileManager.default.temporaryDirectory.appendingPathComponent("x6-\(UUID().uuidString).mind")
        defer { try? FileManager.default.removeItem(at: mind) }
        var mindError = ""
        do {
            try await MindExportService.shared.exportMind(to: mind)
            resetState()
            try await MindExportService.shared.applyStagedMind(try await MindExportService.shared.stageMind(from: mind))
        } catch { mindError = "\(error)" }
        let restored = (await restart())._testMessages
        let holder = message(restored, "HOLDER_1")
        check("X6 Mind export/import with extreme saved coverage: import completes, records kept with coverage dropped",
              mindError.isEmpty && holder?.demotedPruneSummaries.count == 2 && holder?.demotedPruneSummaries.allSatisfy { $0.coverage == nil } == true,
              "\(mindError) records \(holder?.demotedPruneSummaries.count ?? -1)")
    }
}
