import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// What a past-turn prune summary covers, recorded when the prune commits it
/// (summary retention Part B, §5a). Local bookkeeping only: never sent to a
/// model as a field or block. Invalid values decode as absent, so a damaged
/// record falls back to the approximate legacy rule instead of failing the
/// history load.
struct PruneSummaryCoverage: Codable, Equatable {
    static let maxFiles = 20
    static let maxFileBytes = 1024
    static let maxOffsetSeconds = 64_800

    /// Overflow-safe: an inclusive range check, never `abs`, which traps on
    /// `Int.min`. Persisted values are untrusted.
    static func isValidOffset(_ seconds: Int) -> Bool {
        (-maxOffsetSeconds...maxOffsetSeconds).contains(seconds)
    }

    /// Reference-date seconds that can render a year in 1000...9999 in some
    /// valid offset (one day of slack each side; the exact year check runs
    /// after this). Bounds the date before any formatting, so a huge or
    /// negative persisted value never reaches the date formatter.
    static let renderableSeconds: ClosedRange<TimeInterval> = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let low = calendar.date(from: DateComponents(era: 1, year: 999, month: 12, day: 31))!
        let high = calendar.date(from: DateComponents(era: 1, year: 10_000, month: 1, day: 2))!
        return low.timeIntervalSinceReferenceDate...high.timeIntervalSinceReferenceDate
    }()

    static func isRenderableDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSinceReferenceDate
        return seconds.isFinite && renderableSeconds.contains(seconds)
    }

    let version: Int
    let start: Date
    let startOffsetSeconds: Int
    let end: Date
    let endOffsetSeconds: Int
    /// True only when every summarized message's work is dated by recorded
    /// times (v5 rule). Rendered with the `approx.` prefix otherwise.
    let complete: Bool
    /// Selected files, newest first; a navigation list, not an inventory.
    let files: [String]

    init(start: Date, startOffsetSeconds: Int, end: Date, endOffsetSeconds: Int,
         complete: Bool, files: [String], version: Int = 1) throws {
        self.version = version
        self.start = start; self.startOffsetSeconds = startOffsetSeconds
        self.end = end; self.endOffsetSeconds = endOffsetSeconds
        self.complete = complete; self.files = files
        guard isValid else { throw PruneArchiveStore.Failure("invalid prune summary coverage") }
    }

    enum CodingKeys: String, CodingKey {
        case version, start, startOffsetSeconds, end, endOffsetSeconds, complete, files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: c.decode(Date.self, forKey: .start),
                      startOffsetSeconds: c.decode(Int.self, forKey: .startOffsetSeconds),
                      end: c.decode(Date.self, forKey: .end),
                      endOffsetSeconds: c.decode(Int.self, forKey: .endOffsetSeconds),
                      complete: c.decode(Bool.self, forKey: .complete),
                      files: c.decode([String].self, forKey: .files),
                      version: c.decode(Int.self, forKey: .version))
    }

    var isValid: Bool {
        guard version == 1,
              Self.isRenderableDate(start), Self.isRenderableDate(end),
              start <= end,
              Self.isValidOffset(startOffsetSeconds), Self.isValidOffset(endOffsetSeconds),
              files.count <= Self.maxFiles,
              files.allSatisfy({ $0.utf8.count <= Self.maxFileBytes && !$0.unicodeScalars.contains("\u{0}") })
        else { return false }
        // Years are checked as rendered (in each endpoint's own offset).
        for (date, offset) in [(start, startOffsetSeconds), (end, endOffsetSeconds)] {
            guard let year = PruneSummaryRetention.localYear(date, offset: offset), (1000...9999).contains(year) else { return false }
        }
        return true
    }
}

/// One demoted summary anchor: a deterministic navigation line (≤ 300
/// Unicode scalars), the snapshot holding the full text, and the coverage the
/// line was built from.
struct DemotedPruneSummary: Codable, Equatable {
    let version: Int
    let line: String
    let snapshot: PruneArchiveReference
    let coverage: PruneSummaryCoverage?

    init(line: String, snapshot: PruneArchiveReference, coverage: PruneSummaryCoverage?, version: Int = 1) throws {
        guard version == 1, !line.isEmpty, line.unicodeScalars.count <= PruneSummaryRetention.lineCap else {
            throw PruneArchiveStore.Failure("invalid demoted summary record")
        }
        self.version = version; self.line = line; self.snapshot = snapshot; self.coverage = coverage
    }

    enum CodingKeys: String, CodingKey { case version, line, snapshot, coverage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A bad coverage drops only the coverage; a bad snapshot or line
        // drops the record.
        try self.init(line: c.decode(String.self, forKey: .line),
                      snapshot: c.decode(PruneArchiveReference.self, forKey: .snapshot),
                      coverage: try? c.decodeIfPresent(PruneSummaryCoverage.self, forKey: .coverage),
                      version: c.decode(Int.self, forKey: .version))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(line, forKey: .line)
        try c.encode(snapshot, forKey: .snapshot)
        try c.encodeIfPresent(coverage, forKey: .coverage)
    }

    /// One decoder per element, like `PruneArchiveReference.decodeLeniently`:
    /// a damaged element never discards later valid ones or fails the load.
    static func decodeLeniently<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> [Self] {
        guard container.contains(key), (try? container.decodeNil(forKey: key)) != true else { return [] }
        do {
            var array = try container.nestedUnkeyedContainer(forKey: key)
            var records: [Self] = []
            while !array.isAtEnd {
                let element = try array.superDecoder()
                do { records.append(try Self(from: element)) }
                catch { print("[PruneRetention] Dropped invalid demoted summary record.") }
            }
            return records
        } catch {
            print("[PruneRetention] Dropped malformed demoted summary collection.")
            return []
        }
    }
}

/// Past-turn summary retention (Part B): the newest three summary anchors
/// stay in full; older ones become a fixed one-line pointer to a snapshot.
/// Everything here is deterministic and makes no model request.
enum PruneSummaryRetention {
    /// Anchors (messages with a live prune summary) kept in full. A count of
    /// anchors, not a token ceiling: one anchor may hold several summaries.
    static let maxFullPruneSummaryAnchors = 3
    static let lineCap = 300
    static let componentCap = 40
    static let wrapperPrefix = "Earlier work summarized (full text in snapshot): "
    static let exactPrefix = "Earlier work "
    static let approxPrefix = "Earlier work, approx. "
    static let linkPrefix = " · full summary: snapshot "
    static let snapshotLeadNote = "Summary demotion snapshot: full text of demoted summary anchors."

    /// Test-only: the device zone used for recording offsets.
    static var timeZoneForTesting: TimeZone?
    static var deviceTimeZone: TimeZone { timeZoneForTesting ?? .current }

    static func isFullAnchor(_ message: Message) -> Bool {
        guard let summary = message.prunedContextSummary else { return false }
        return !summary.isEmpty
    }

    static func wrapper(_ line: String) -> String { wrapperPrefix + line }

    // MARK: Coverage

    /// Coverage of one prune, from the exact manifest messages (v5 rule):
    /// candidates are each message's timestamp plus the `issuedAt` of its
    /// tool rounds. Exact only when every message's work is dated by recorded
    /// times; a carried active-turn summary or an undated round makes it
    /// approximate. The nearest preceding user message only widens the hint
    /// span for a carried summary; it never certifies a start.
    static func coverage(of source: [Message], manifest: [Int], timeZone: TimeZone? = nil) -> PruneSummaryCoverage? {
        let indices = Array(Set(manifest)).filter { source.indices.contains($0) }.sorted()
        guard !indices.isEmpty else { return nil }
        var times: [Date] = []
        var complete = true
        for i in indices {
            let message = source[i]
            times.append(message.timestamp)
            for round in message.toolInteractions {
                if let issued = round.assistantMessage.issuedAt { times.append(issued) } else { complete = false }
            }
            if message.activeTurnCompaction != nil {
                complete = false
                if let hint = source[..<i].last(where: { $0.role == .user }) { times.append(hint.timestamp) }
            }
        }
        guard let start = times.min(), let end = times.max() else { return nil }
        let files = selectedFiles(indices.reversed().map { source[$0] })
        let zone = timeZone ?? deviceTimeZone
        return try? PruneSummaryCoverage(start: start, startOffsetSeconds: zone.secondsFromGMT(for: start),
                                         end: end, endOffsetSeconds: zone.secondsFromGMT(for: end),
                                         complete: complete, files: files)
    }

    /// Edited then generated paths, newest message first, exact-string
    /// de-duplicated, at most 20, each at most 1,024 UTF-8 bytes.
    static func selectedFiles(_ newestFirst: [Message]) -> [String] {
        var seen: Set<String> = []
        var files: [String] = []
        for message in newestFirst {
            for path in message.editedFilePaths + message.generatedFilePaths {
                guard files.count < PruneSummaryCoverage.maxFiles else { return files }
                guard !path.isEmpty, path.utf8.count <= PruneSummaryCoverage.maxFileBytes,
                      !path.unicodeScalars.contains("\u{0}"), seen.insert(path).inserted else { continue }
                files.append(path)
            }
        }
        return files
    }

    /// Coverage after appending a new summary part to an anchor.
    static func merged(hadSummary: Bool, previous: PruneSummaryCoverage?, fresh: PruneSummaryCoverage?) -> PruneSummaryCoverage? {
        guard let fresh, fresh.isValid else { return nil }
        guard hadSummary else { return fresh }
        // Part of the text has unknown coverage: keep what is known, approx.
        guard let previous, previous.isValid else {
            return try? PruneSummaryCoverage(start: fresh.start, startOffsetSeconds: fresh.startOffsetSeconds,
                                             end: fresh.end, endOffsetSeconds: fresh.endOffsetSeconds,
                                             complete: false, files: fresh.files)
        }
        let early = previous.start <= fresh.start ? (previous.start, previous.startOffsetSeconds) : (fresh.start, fresh.startOffsetSeconds)
        let late = previous.end >= fresh.end ? (previous.end, previous.endOffsetSeconds) : (fresh.end, fresh.endOffsetSeconds)
        var seen: Set<String> = []
        let files = (fresh.files + previous.files).filter { seen.insert($0).inserted }.prefix(PruneSummaryCoverage.maxFiles)
        return try? PruneSummaryCoverage(start: early.0, startOffsetSeconds: early.1, end: late.0, endOffsetSeconds: late.1,
                                         complete: previous.complete && fresh.complete, files: Array(files))
    }

    /// Legacy anchors (no valid recorded coverage): a navigation hint from
    /// surviving history, from the first message after the previous anchor
    /// (full or demoted) to the anchor itself. Always approximate.
    static func legacyCoverage(in view: [Message], anchor: Int, timeZone: TimeZone? = nil) -> PruneSummaryCoverage? {
        guard view.indices.contains(anchor) else { return nil }
        let previous = view[..<anchor].lastIndex { isFullAnchor($0) || !$0.demotedPruneSummaries.isEmpty }
        let range = ((previous ?? -1) + 1)...anchor
        let slice = Array(view[range])
        var times = slice.map(\.timestamp)
        for message in slice { for round in message.toolInteractions { if let t = round.assistantMessage.issuedAt { times.append(t) } } }
        guard let start = times.min(), let end = times.max() else { return nil }
        let zone = timeZone ?? deviceTimeZone
        return try? PruneSummaryCoverage(start: start, startOffsetSeconds: zone.secondsFromGMT(for: start),
                                         end: end, endOffsetSeconds: zone.secondsFromGMT(for: end),
                                         complete: false, files: selectedFiles(slice.reversed()))
    }

    // MARK: The line

    private static let formatterLock = NSLock()
    private static var formatters: [String: DateFormatter] = [:]

    static func formatter(_ format: String, offset: Int) -> DateFormatter {
        let key = "\(offset)|" + format
        formatterLock.lock(); defer { formatterLock.unlock() }
        if let cached = formatters[key] { return cached }
        if formatters.count > 512 { formatters.removeAll() }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(secondsFromGMT: 0)!
        f.dateFormat = format
        formatters[key] = f
        return f
    }

    static func localYear(_ date: Date, offset: Int) -> Int? {
        guard PruneSummaryCoverage.isValidOffset(offset), PruneSummaryCoverage.isRenderableDate(date) else { return nil }
        return Int(formatter("yyyy", offset: offset).string(from: date))
    }

    /// `d MMM yyyy HH:mm` per endpoint in its own recorded offset; at most 61
    /// scalars for a valid coverage.
    static func span(_ coverage: PruneSummaryCoverage) -> String {
        let (so, eo) = (coverage.startOffsetSeconds, coverage.endOffsetSeconds)
        let startDay = formatter("d MMM yyyy", offset: so).string(from: coverage.start)
        let startTime = formatter("HH:mm", offset: so).string(from: coverage.start)
        let endDay = formatter("d MMM yyyy", offset: eo).string(from: coverage.end)
        let endTime = formatter("HH:mm", offset: eo).string(from: coverage.end)
        if so == eo {
            let label = Chronology.offsetLabel(seconds: so)
            if startDay == endDay { return "\(startDay) \(startTime)–\(endTime) (\(label))" }
            return "\(startDay) \(startTime) – \(endDay) \(endTime) (\(label))"
        }
        return "\(startDay) \(startTime) (\(Chronology.offsetLabel(seconds: so))) – \(endDay) \(endTime) (\(Chronology.offsetLabel(seconds: eo)))"
    }

    /// Control characters, line and paragraph separators become a space.
    static func sanitize(_ path: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// Middle-`…` shortening to at most `cap` scalars, cutting only at
    /// grapheme boundaries; a grapheme too large for its side is dropped.
    static func shorten(_ text: String, cap: Int = componentCap) -> String {
        guard text.unicodeScalars.count > cap else { return text }
        let room = cap - 1
        let headRoom = (room + 1) / 2, tailRoom = room / 2
        var head = "", used = 0
        for g in text {
            let n = g.unicodeScalars.count
            if used + n > headRoom { break }
            head.append(g); used += n
        }
        var tail: [Character] = []; used = 0
        for g in text.reversed() {
            let n = g.unicodeScalars.count
            if used + n > tailRoom { break }
            tail.append(g); used += n
        }
        return head + "…" + String(tail.reversed())
    }

    static func twoComponent(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return shorten(path) }
        return parts.suffix(2).map { shorten($0) }.joined(separator: "/")
    }

    static func basename(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return shorten(parts.last ?? path)
    }

    static func moreSuffix(_ omitted: Int) -> String { omitted > 0 ? " (+\(omitted) more)" : "" }

    /// The files segment that fits `budget` scalars, in the fixed order:
    /// two-component form (≤ 5), basenames dropping the oldest, or nothing.
    static func filesSegment(_ rawFiles: [String], budget: Int) -> String {
        var seen: Set<String> = []
        let candidates = rawFiles.map(sanitize).filter { !$0.isEmpty && seen.insert($0).inserted }
        let total = candidates.count
        guard total > 0 else { return "" }
        func segment(_ names: [String], omitted: Int) -> (text: String, fitLength: Int) {
            let body = " · " + names.joined(separator: ", ")
            let suffixForFit = moreSuffix(omitted)
            return (body + moreSuffix(omitted), (body + suffixForFit).unicodeScalars.count)
        }
        let first = min(5, total)
        let two = segment(candidates.prefix(first).map(twoComponent), omitted: total - first)
        if two.fitLength <= budget { return two.text }
        for n in stride(from: first, through: 1, by: -1) {
            let base = segment(candidates.prefix(n).map(basename), omitted: total - n)
            if base.fitLength <= budget { return base.text }
        }
        return ""
    }

    /// The stored line, or nil when even the fixed parts cannot fit (only
    /// possible through a defect): the anchor then stays in full.
    static func line(for coverage: PruneSummaryCoverage, snapshot: PruneArchiveReference, filesBudget: Int? = nil) -> String? {
        guard coverage.isValid else { return nil }
        let prefix = coverage.complete ? exactPrefix : approxPrefix
        let fixedHead = prefix + span(coverage)
        let link = linkPrefix + snapshot.basename
        let budget = filesBudget ?? (lineCap - fixedHead.unicodeScalars.count - link.unicodeScalars.count)
        var line = fixedHead + filesSegment(coverage.files, budget: budget) + link
        if line.unicodeScalars.count > lineCap { line = fixedHead + link }
        guard line.unicodeScalars.count <= lineCap else { return nil }
        return line
    }

    // MARK: Retention protection

    enum LiveHistory {
        case absent
        case snapshots(Set<UUID>)
        case unreadable(String)
    }

    /// Snapshot ids referenced by demoted lines in the COMMITTED history file
    /// next to a snapshot directory. Decoded with the same decoder as the
    /// conversation loader, so both always agree on which lines are live.
    static func liveDemotionSnapshots(historyFile: URL) -> LiveHistory {
        var st = stat()
        if lstat(historyFile.path, &st) != 0 {
            if errno == ENOENT { return .absent }
            return .unreadable(String(cString: strerror(errno)))
        }
        do {
            let data = try Data(contentsOf: historyFile)
            let history = try JSONDecoder().decode([Message].self, from: data)
            return .snapshots(Set(history.flatMap { $0.demotedPruneSummaries.map(\.snapshot.id) }))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }
}
