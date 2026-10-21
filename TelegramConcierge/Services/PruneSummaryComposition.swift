import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// /keepsummaries (KEEP_SUMMARIES_PLAN v5): full past-turn summaries stay in
// the saved conversation; how many are shown in full is decided only when a
// request is composed. Everything here is pure: no file I/O, no settings
// read inside `compose`, the input is never mutated.

/// How many past-turn summary anchors a request shows in full.
enum KeepSummariesLimit: Equatable, CustomStringConvertible {
    case count(Int)
    case all

    static let defaultCount = 3
    static let maxCount = 50
    static let defaultValue = KeepSummariesLimit.count(defaultCount)

    var description: String {
        switch self {
        case .count(let n): return String(n)
        case .all: return "all"
        }
    }
}

/// The persisted `/keepsummaries` setting (`switchDefaults` key
/// `ada.keepSummaries`): an Int 1…50 or the string "all". Absent means the
/// default 3; the value 3 is never stored (setting 3 removes the key).
enum KeepSummariesSetting {
    static let defaultsKey = "ada.keepSummaries"
    /// The chat-switch store (`switchDefaults`), read and written only here.
    private static var defaults: UserDefaults { UserDefaults.standard }
    private static let logLock = NSLock()
    nonisolated(unsafe) private static var invalidLogged = false

    static func current() -> KeepSummariesLimit {
        guard let object = defaults.object(forKey: defaultsKey) else { return .defaultValue }
        if let value = parseStored(object) { return value }
        logLock.lock()
        let first = !invalidLogged
        invalidLogged = true
        logLock.unlock()
        if first { print("[KeepSummaries] Ignoring an invalid stored /keepsummaries value; using the default 3.") }
        return .defaultValue
    }

    /// Strict object-type validation: only a genuine integer 1…50 or the
    /// exact string "all". Bool, Double and numeric strings never pass.
    static func parseStored(_ object: Any) -> KeepSummariesLimit? {
        if let string = object as? String { return string == "all" ? .all : nil }
        if type(of: object) == Bool.self || type(of: object) == Double.self || type(of: object) == Float.self { return nil }
        if let number = object as? NSNumber {
            #if canImport(Darwin)
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return nil }
            #endif
            let kind = String(cString: number.objCType)
            guard ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(kind) else { return nil }
            let value = number.int64Value
            guard (1...Int64(KeepSummariesLimit.maxCount)).contains(value) else { return nil }
            return .count(Int(value))
        }
        if let value = object as? Int, (1...KeepSummariesLimit.maxCount).contains(value) { return .count(value) }
        return nil
    }

    /// Parses a command argument: "all", or 1–50 written as `^[1-9][0-9]?$`.
    static func parseArgument(_ argument: String) -> KeepSummariesLimit? {
        let text = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == "all" { return .all }
        guard text.range(of: #"^[1-9][0-9]?$"#, options: .regularExpression) != nil,
              let value = Int(text), value <= KeepSummariesLimit.maxCount else { return nil }
        return .count(value)
    }

    /// Stores `limit`; the default removes the key.
    static func store(_ limit: KeepSummariesLimit) {
        switch limit {
        case .count(KeepSummariesLimit.defaultCount): defaults.removeObject(forKey: defaultsKey)
        case .count(let n): defaults.set(n, forKey: defaultsKey)
        case .all: defaults.set("all", forKey: defaultsKey)
        }
        #if !canImport(Darwin)
        // corelibs Foundation: flush now so another process (a restart, the
        // cross-process selftest row) reads the new value.
        defaults.synchronize()
        #endif
    }
}

/// The pointer standing for one live summary (§3).
struct PruneSummaryStub: Codable, Equatable {
    static let currentVersion = 1
    let version: Int
    /// SHA-256 hex of the exact `prunedContextSummary` it stands for.
    let summaryDigest: String
    let record: DemotedPruneSummary

    init(summary: String, record: DemotedPruneSummary) {
        self.version = Self.currentVersion
        self.summaryDigest = Self.digest(summary)
        self.record = record
    }

    static func digest(_ summary: String) -> String {
        SHA256.hash(data: Data(summary.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Usable only when its version is known and its digest matches the
    /// summary it is asked to stand for.
    func isUsable(for summary: String?) -> Bool {
        guard version == Self.currentVersion, let summary, !summary.isEmpty else { return false }
        return summaryDigest == Self.digest(summary)
    }
}

/// One request's view of the history (§4.2): built once per model request;
/// that request's estimate and its send consume the same value. Never
/// persisted, never written back.
struct ComposedHistory {
    let messages: [Message]
    let limit: KeepSummariesLimit
    /// Identifies the set of anchors composed as pointers.
    let renderKey: String
    let stubIDs: Set<UUID>
}

extension PruneSummaryRetention {
    /// The key of a composition with no pointer-composed anchor; also what a
    /// ≤0.2.57 usage snapshot (no key) means, exactly (§4.4).
    static let emptyRenderKey = "keepsummaries:none"
    /// The key a stored measurement gets when its key could not be read:
    /// never equal to a composed key, so the measurement is ignored.
    static let unknownRenderKey = "keepsummaries:unknown"

    static func renderKey(stubIDs: Set<UUID>) -> String {
        guard !stubIDs.isEmpty else { return emptyRenderKey }
        let joined = stubIDs.map(\.uuidString).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A stored key is valid when it is the empty constant or 64 lowercase hex.
    static func isValidRenderKey(_ key: String) -> Bool {
        key == emptyRenderKey || key.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    /// §4.1: the newest `limit` anchors (by position) in full; every older
    /// anchor with a usable stub becomes a copy in 0.2.57's demoted shape.
    /// An anchor without a usable stub is shown in full.
    static func compose(_ history: [Message], limit: KeepSummariesLimit) -> ComposedHistory {
        let anchors = history.indices.filter { isFullAnchor(history[$0]) }
        let keepFull: Set<Int>
        switch limit {
        case .all: keepFull = Set(anchors)
        case .count(let n): keepFull = Set(anchors.suffix(max(0, n)))
        }
        var output = history
        var stubIDs: Set<UUID> = []
        for index in anchors where !keepFull.contains(index) {
            let message = history[index]
            guard let stub = message.prunedContextSummaryStub, stub.isUsable(for: message.prunedContextSummary) else { continue }
            output[index] = pointerShape(message, stub: stub)
            stubIDs.insert(message.id)
        }
        return ComposedHistory(messages: stubIDs.isEmpty ? history : output, limit: limit,
                               renderKey: renderKey(stubIDs: stubIDs), stubIDs: stubIDs)
    }

    /// Exactly what 0.2.57's destructive demotion left on the message: the
    /// summary and its coverage removed, the record appended, its snapshot
    /// in the references (rendered only inside the line), and the
    /// saturating `measuredTokens` delta.
    static func pointerShape(_ message: Message, stub: PruneSummaryStub) -> Message {
        var copy = message
        let summary = message.prunedContextSummary ?? ""
        copy.prunedContextSummary = nil
        copy.prunedContextSummaryCoverage = nil
        copy.prunedContextSummaryStub = nil
        copy.demotedPruneSummaries.append(stub.record)
        if !copy.pruneArchiveReferences.contains(stub.record.snapshot) { copy.pruneArchiveReferences.append(stub.record.snapshot) }
        if let measured = copy.measuredTokens {
            copy.measuredTokens = saturatingMeasured(measured, delta: wrapper(stub.record.line).count / 4 - summary.count / 4)
        }
        return copy
    }

    /// The pointer for the anchor at `index`, built exactly like 0.2.57's
    /// demotion record (recorded coverage, else the approximate legacy hint
    /// from surviving history). nil when the line cannot fit (a defect).
    static func makeStub(for view: [Message], anchor index: Int, snapshot: PruneArchiveReference) -> PruneSummaryStub? {
        guard view.indices.contains(index), let summary = view[index].prunedContextSummary, !summary.isEmpty else { return nil }
        let recorded = view[index].prunedContextSummaryCoverage.flatMap { $0.isValid ? $0 : nil }
        guard let coverage = recorded ?? legacyCoverage(in: view, anchor: index),
              let line = line(for: coverage, snapshot: snapshot),
              let record = try? DemotedPruneSummary(line: line, snapshot: snapshot, coverage: coverage) else { return nil }
        return PruneSummaryStub(summary: summary, record: record)
    }

    /// 0.2.57's saturating arithmetic: measuredTokens is persisted, so never
    /// trap on it; the result stays ≥ 1.
    static func saturatingMeasured(_ measured: Int, delta: Int) -> Int {
        let (sum, overflow) = measured.addingReportingOverflow(delta)
        return max(1, overflow ? (delta < 0 ? 1 : Int.max) : sum)
    }
}
