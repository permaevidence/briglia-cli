import Foundation

/// L1–L7: the deterministic demotion line and its hard 300-scalar budget.
extension RetentionHarness {

    var link: String { PruneSummaryRetention.linkPrefix + Self.fixedBasename }

    /// L1 exact golden lines; L4 sanitized names; L5 byte stability.
    func lineGoldenSection() {
        let snapshot = ref()
        func line(_ c: PruneSummaryCoverage) -> String { PruneSummaryRetention.line(for: c, snapshot: snapshot) ?? "<nil>" }
        let sameDay = coverage(at(2026, 9, 28, 14, 2), at(2026, 9, 28, 16, 40))
        check("L1a same-day span, no files",
              line(sameDay) == "Earlier work 28 Sep 2026 14:02–16:40 (UTC+02:00)" + link, line(sameDay))
        let crossDay = coverage(at(2026, 9, 28, 14, 2), at(2026, 9, 29, 9, 40), files: ["/Users/x/proj/ui/index.html", "Package.swift"])
        check("L1b cross-day span with two-component file names",
              line(crossDay) == "Earlier work 28 Sep 2026 14:02 – 29 Sep 2026 09:40 (UTC+02:00) · ui/index.html, Package.swift" + link, line(crossDay))
        let dst = coverage(at(2026, 9, 28, 14, 2, offset: 7200), at(2026, 10, 29, 9, 40, offset: 3600), so: 7200, eo: 3600)
        check("L1c DST: each endpoint carries its own offset",
              line(dst) == "Earlier work 28 Sep 2026 14:02 (UTC+02:00) – 29 Oct 2026 09:40 (UTC+01:00)" + link, line(dst))
        let year = coverage(at(2026, 12, 31, 23, 30, offset: 3600), at(2027, 1, 1, 0, 15, offset: 3600), so: 3600, eo: 3600)
        check("L1d cross-year span shows both years",
              line(year) == "Earlier work 31 Dec 2026 23:30 – 1 Jan 2027 00:15 (UTC+01:00)" + link, line(year))
        let approx = coverage(at(2026, 9, 28, 14, 2), at(2026, 9, 28, 16, 40), complete: false)
        check("L1e incomplete coverage uses the approx. prefix",
              line(approx) == "Earlier work, approx. 28 Sep 2026 14:02–16:40 (UTC+02:00)" + link, line(approx))
        let five = coverage(at(2026, 9, 28, 14, 2), at(2026, 9, 28, 16, 40), files: (1...5).map { "src/f\($0).swift" })
        check("L1f exactly five files, no omission suffix",
              line(five) == "Earlier work 28 Sep 2026 14:02–16:40 (UTC+02:00) · src/f1.swift, src/f2.swift, src/f3.swift, src/f4.swift, src/f5.swift" + link, line(five))
        let seven = coverage(at(2026, 9, 28, 14, 2), at(2026, 9, 28, 16, 40), files: (1...7).map { "src/f\($0).swift" })
        check("L1g seven files → newest five and (+2 more)",
              line(seven) == "Earlier work 28 Sep 2026 14:02–16:40 (UTC+02:00) · src/f1.swift, src/f2.swift, src/f3.swift, src/f4.swift, src/f5.swift (+2 more)" + link, line(seven))

        // L4: control characters and newlines in a path become spaces.
        let dirty = coverage(at(2026, 9, 28, 14, 2), at(2026, 9, 28, 16, 40), files: ["src/a\nb\u{7}c\u{2028}d.swift"])
        let cleaned = line(dirty)
        let controls = cleaned.unicodeScalars.filter { [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
        check("L4a newline/control characters in a path are replaced",
              controls.isEmpty && cleaned.contains("src/a b c d.swift"), cleaned)

        // L5: stored once; identical after a JSON round trip.
        let stored = try? DemotedPruneSummary(line: line(crossDay), snapshot: snapshot, coverage: crossDay)
        let reloaded = stored.flatMap { try? JSONDecoder().decode(DemotedPruneSummary.self, from: JSONEncoder().encode($0)) }
        check("L5a the stored line is byte-stable across save and load",
              reloaded != nil && reloaded == stored && reloaded?.line == line(crossDay)
              && PruneSummaryRetention.line(for: crossDay, snapshot: snapshot) == line(crossDay))
    }

    /// L2 shortening order; L3 Codex's 307-character case.
    func lineOrderSection() {
        let snapshot = ref()
        let start = at(2026, 9, 28, 14, 2), end = at(2026, 9, 29, 9, 40)
        let head = "Earlier work 28 Sep 2026 14:02 – 29 Sep 2026 09:40 (UTC+02:00)"
        // Five long two-component paths that cannot all fit → basenames.
        let long = (1...5).map { "dir\($0)" + String(repeating: "d", count: 30) + "/file\($0)" + String(repeating: "n", count: 30) }
        let c = coverage(start, end, files: long)
        let l = PruneSummaryRetention.line(for: c, snapshot: snapshot) ?? ""
        let basenames = long.map { String($0.split(separator: "/").last!) }
        check("L2a two-component form that does not fit falls back to basenames",
              !l.contains("dir1") && l.contains(basenames[0]) && l.unicodeScalars.count <= 300, l)
        // Many basenames: the newest are kept, the oldest dropped first.
        let many = (1...5).map { "f\($0)" + String(repeating: "x", count: 36) }
        let m = PruneSummaryRetention.filesSegment(many, budget: 3 + 39 * 2 + 2 + 10)
        check("L2b basenames drop the oldest first, newest kept, with (+K more)",
              m == " · " + many[0] + ", " + many[1] + " (+3 more)", m)
        let none = PruneSummaryRetention.line(for: coverage(start, end, files: ["src/main.swift"]), snapshot: snapshot, filesBudget: 5)
        check("L2c no files when even one basename cannot fit (test budget)", none == head + link, none ?? "<nil>")
        // Grapheme-safe middle shortening.
        let decomposed = String(repeating: "e\u{0301}", count: 60)
        let shortDecomposed = PruneSummaryRetention.shorten(decomposed)
        let marks = shortDecomposed.split(separator: "…").map { String($0) }
        check("L2d accented/combining characters are cut only between graphemes",
              shortDecomposed.unicodeScalars.count <= 40 && marks.count == 2
              && marks.allSatisfy { $0.allSatisfy { $0 == "e\u{0301}" } } && marks[1].unicodeScalars.first != "\u{0301}", shortDecomposed)
        let family = "👨‍👩‍👧‍👦"
        let shortFamily = PruneSummaryRetention.shorten(String(repeating: family, count: 10))
        check("L2e emoji ZWJ sequences are never split",
              shortFamily.unicodeScalars.count <= 40 && shortFamily.filter { $0 != "…" }.allSatisfy { String($0) == family }, shortFamily)
        let rtl = PruneSummaryRetention.shorten(String(repeating: "שלום", count: 15))
        check("L2f right-to-left text is shortened to the cap", rtl.unicodeScalars.count <= 40 && rtl.contains("…"), rtl)
        let huge = coverage(start, end, files: (0..<20).map { "\($0)" + String(repeating: "z", count: 900) })
        let hl = PruneSummaryRetention.line(for: huge, snapshot: snapshot) ?? ""
        check("L2g span and link are never shortened", hl.hasPrefix(head) && hl.hasSuffix(link) && hl.unicodeScalars.count <= 300, hl)

        // L3: Codex's v3 counter-example (cross-DST, two legal 159-character paths).
        let p1 = String(repeating: "a", count: 40) + "/" + String(repeating: "b", count: 35)
        let p2 = String(repeating: "c", count: 40) + "/" + String(repeating: "d", count: 40)
        let codex = coverage(at(2026, 9, 28, 14, 2, offset: 7200), at(2026, 10, 29, 9, 40, offset: 3600), so: 7200, eo: 3600, files: [p1, p2])
        let span = "28 Sep 2026 14:02 (UTC+02:00) – 29 Oct 2026 09:40 (UTC+01:00)"
        let v3Length = "Earlier work ".count + span.count + " · ".count + (p1 + ", " + p2).count + link.count
        let golden = "Earlier work " + span + " · " + String(repeating: "b", count: 35) + ", " + String(repeating: "d", count: 40) + link
        let got = PruneSummaryRetention.line(for: codex, snapshot: snapshot) ?? ""
        check("L3 Codex's case (over 300 under the old rule) falls back to basenames and fits",
              v3Length > 300 && got == golden && got.unicodeScalars.count <= 300, "v3 \(v3Length), got \(got.unicodeScalars.count): \(got)")
    }

    /// L6 `(+K more)` digit boundaries at the exact budget edge.
    func lineBoundarySection() {
        for (nine, ten) in [(9, 10), (99, 100), (999, 1000)] {
            let fewer = (1...(5 + nine)).map { "f\($0)" }
            let more = (1...(5 + ten)).map { "f\($0)" }
            let edge = " · f1, f2, f3, f4, f5 (+\(nine) more)"
            let budget = edge.unicodeScalars.count
            let atEdge = PruneSummaryRetention.filesSegment(fewer, budget: budget)
            let past = PruneSummaryRetention.filesSegment(more, budget: budget)
            check("L6 K=\(nine)→\(ten): the extra digit forces one more file out",
                  atEdge == edge && past == " · f1, f2, f3, f4 (+\(ten + 1) more)" && past.unicodeScalars.count <= budget,
                  "edge \(atEdge) past \(past) budget \(budget)")
        }
    }

    /// L7 property/fuzz (fixed seed, reproducible).
    func lineFuzzSection() {
        var rng = RetentionRNG(seed: 0x5EED_B2)
        let pools: [[UInt32]] = [
            Array(0x61...0x7A), [0x2F, 0x2F, 0x2E, 0x20, 0x2D], Array(0x300...0x36F), [0x200D, 0x1F468, 0x1F469, 0x1F467, 0x1F3FD],
            [0x202E, 0x202B, 0x05D0, 0x05E9, 0x0627, 0x0644], Array(0x01...0x1F) + [0x7F, 0x85, 0x2028, 0x2029],
            [0x4E2D, 0x6587, 0xAC00, 0x3042], [0x1F600, 0x1F680, 0x2764, 0xFE0F],
        ]
        func randomText(_ maxLen: Int) -> String {
            let n = Int(rng.next() % UInt64(maxLen + 1))
            var scalars = String.UnicodeScalarView()
            for _ in 0..<n {
                let pool = pools[Int(rng.next() % UInt64(pools.count))]
                if let s = Unicode.Scalar(pool[Int(rng.next() % UInt64(pool.count))]) { scalars.append(s) }
            }
            return String(scalars)
        }
        let offsets = (-48...56).map { $0 * 900 }
        func randomDate(_ offset: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: offset)!
            let comps = DateComponents(year: 1000 + Int(rng.next() % 9000), month: 1 + Int(rng.next() % 12), day: 1 + Int(rng.next() % 28),
                                       hour: Int(rng.next() % 24), minute: Int(rng.next() % 60))
            return calendar.date(from: comps)!
        }
        var bad: [String] = []
        var lineCases = 0, segmentCases = 0
        for _ in 0..<fuzzCases {
            let so = offsets[Int(rng.next() % UInt64(offsets.count))], eo = rng.next() % 3 == 0 ? so : offsets[Int(rng.next() % UInt64(offsets.count))]
            var a = randomDate(so), b = randomDate(eo)
            if a > b { swap(&a, &b) }
            var files: [String] = []
            for _ in 0..<Int(rng.next() % 21) {
                var kept = String.UnicodeScalarView(), bytes = 0
                for scalar in randomText(rng.next() % 4 == 0 ? 1024 : 80).unicodeScalars where scalar != "\u{0}" {
                    let n = String(scalar).utf8.count
                    if bytes + n > 1024 { break }
                    kept.append(scalar); bytes += n
                }
                files.append(String(kept))
            }
            guard let c = try? PruneSummaryCoverage(start: a, startOffsetSeconds: so, end: b, endOffsetSeconds: eo,
                                                    complete: rng.next() % 2 == 0, files: files) else { continue }
            lineCases += 1
            let snapshot = randomRef()
            let linkText = PruneSummaryRetention.linkPrefix + snapshot.basename
            let span = PruneSummaryRetention.span(c)
            guard let line = PruneSummaryRetention.line(for: c, snapshot: snapshot) else { bad.append("refused"); continue }
            let prefix = c.complete ? PruneSummaryRetention.exactPrefix : PruneSummaryRetention.approxPrefix
            let controls = line.unicodeScalars.contains { [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
            if line.unicodeScalars.count > 300 || !line.hasPrefix(prefix + span) || !line.hasSuffix(linkText) || controls
                || PruneSummaryRetention.line(for: c, snapshot: snapshot) != line {
                bad.append("\(line.unicodeScalars.count): \(line)")
            }
            // Raw segment fuzz: up to 2,000 names of up to 4,096 scalars.
            // Counts span 0–2,000 (large lists in a fixed share of cases).
            let count = rng.next() % 25 == 0 ? Int(rng.next() % 2001) : Int(rng.next() % 41)
            let names = (0..<count).map { _ in randomText(rng.next() % 50 == 0 ? 4096 : 60) }
            let budget = 136 + Int(rng.next() % 165)
            let segment = PruneSummaryRetention.filesSegment(names, budget: budget)
            segmentCases += 1
            if segment.unicodeScalars.count > budget { bad.append("segment \(segment.unicodeScalars.count) > \(budget)") }
        }
        check("L7 fuzz: \(lineCases) lines ≤ 300 scalars, span+link intact, no control chars, deterministic; \(segmentCases) segments within budget",
              bad.isEmpty && lineCases >= fuzzCases * 9 / 10, "\(bad.count) bad; first: \(bad.first ?? "")")
    }
}

/// Small deterministic generator (fixed seed → reproducible fuzz cases).
struct RetentionRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
