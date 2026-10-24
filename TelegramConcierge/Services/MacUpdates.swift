import Foundation

/// The macOS weekly "updates are waiting" message (security plan v17/v18
/// §9.5.9, owner direction H2). Homebrew formulae and casks are never matched
/// against advisories; instead Briglia tells the user, at most once a week and
/// only when something NEW is waiting, which watchlisted tools have a newer
/// version in Homebrew's own cached catalogue (plus LibreOffice.app from the
/// website and pending macOS Software Update entries). Only files are read:
/// `brew` is never executed and nothing goes to the network. The text says
/// "update available", never "vulnerable" or "safe".
enum MacUpdates {
    static let maxNotified = 64
    static let messageInterval: TimeInterval = 7 * 24 * 3600
    static let evaluationInterval: TimeInterval = 6 * 3600
    static let freshness: TimeInterval = 7 * 24 * 3600
    static let futureSkew: TimeInterval = 3600
    static let maxNamed = 8
    static let maxCommandNames = 20

    enum Kind: String, Codable { case formula, cask, app, macos }

    /// One waiting update. `key` never contains the available version: a
    /// version bump of an item that is still waiting is not news.
    struct Item: Codable, Equatable {
        var key: String
        var kind: Kind
        var toolId: String?
        /// Display name (a watch-tool name or a validated Apple display name).
        var name: String
        var installed: String?
        var available: String?
        /// formula / cask token for the command (validated locally).
        var command: String?
    }

    /// Per watched tool: what the Security line shows.
    struct ToolLine: Codable, Equatable {
        enum State: String, Codable { case waiting, current, pinned, unknown }
        var toolId: String
        var name: String
        var installed: String?
        var available: String?
        var state: State
        var reason: LocalTools.Text?
        var command: String?
        var kind: Kind?
    }

    struct Evaluation: Codable, Equatable {
        var at: Date
        /// Items with POSITIVE waiting evidence, in display order.
        var waiting: [Item]
        /// Keys with POSITIVE evidence that they are no longer waiting.
        var resolved: [String]
        /// Every input was readable and fresh (needed to clear quiet overflow).
        var complete: Bool
        var catalogueAsOf: Date?
        var softwareUpdateAsOf: Date?
        var tools: [ToolLine]
        var problems: [LocalTools.Text]
    }

    struct Notified: Codable, Equatable {
        var key: String
        var at: Date
    }
}

struct MacUpdatesAttempt: Codable, Equatable {
    var keys: [String]
    var noticeGeneration: UInt64
    var channelKind: String?
    var chatId: String?
    var channelGeneration: UInt64
    var text: String
    var attempt: Int
    var firstAttemptAt: Date
    var deadline: Date
    var state: AttemptRecord.State
    var retryAfter: Date?
}

/// `~/.local/share/briglia/update/macupdates.json`.
struct MacUpdatesState: Codable, Equatable {
    var schema = 1
    var notified: [MacUpdates.Notified] = []
    var lastMessageAt: Date?
    /// R17-4: set when a consume could not record every key; while set, a
    /// waiting key outside `notified` is not news (never a resend).
    var quietOverflow: Date?
    var attempt: MacUpdatesAttempt?
    var lastOutcome: LocalVulnOutcome?
    var report: MacUpdates.Evaluation?
}

/// Pure rules (§9.5.9), tested as a table.
extension MacUpdates {
    /// Positive resolution only; the overflow flag is cleared only by a
    /// complete evaluation whose whole waiting set fits and is recorded.
    static func reconcile(_ s: inout MacUpdatesState, _ e: Evaluation) {
        let resolved = Set(e.resolved)
        let waiting = Set(e.waiting.map(\.key))
        // "macos:*": a fresh Software Update record, so every recorded macOS
        // key that it no longer lists is positively gone.
        let suFresh = resolved.contains("macos:*")
        s.notified.removeAll { resolved.contains($0.key) || (suFresh && $0.key.hasPrefix("macos:") && !waiting.contains($0.key)) }
        if s.quietOverflow != nil, e.complete, e.waiting.count <= maxNotified {
            let recorded = Set(s.notified.map(\.key))
            if e.waiting.allSatisfy({ recorded.contains($0.key) }) { s.quietOverflow = nil }
        }
    }

    /// A `lastMessageAt` more than a day in the future (the clock moved
    /// back) is clamped to now: it counts as "just sent".
    static func clampClock(_ s: inout MacUpdatesState, now: Date) {
        if let last = s.lastMessageAt, last > now.addingTimeInterval(24 * 3600) { s.lastMessageAt = now }
    }

    static func newItems(_ s: MacUpdatesState, _ e: Evaluation) -> [Item] {
        guard s.quietOverflow == nil else { return [] }
        let recorded = Set(s.notified.map(\.key))
        return e.waiting.filter { !recorded.contains($0.key) }
    }

    /// Whether a message may be sent now (new items, no ACTIVE attempt,
    /// seven days since the last one).
    static func sendDue(_ s: MacUpdatesState, _ e: Evaluation, now: Date) -> Bool {
        guard s.attempt == nil, !newItems(s, e).isEmpty else { return false }
        guard let last = s.lastMessageAt else { return true }
        return now.timeIntervalSince(last) >= messageInterval
    }

    /// Consume before the single send: every currently waiting key is
    /// recorded (bounded; overflow is quiet and persisted), the time, and the
    /// attempt record — the caller writes all of it in ONE atomic replacement.
    static func consume(_ s: inout MacUpdatesState, _ e: Evaluation, text: String, noticeGeneration: UInt64,
                        destination: UpdateNotice.Destination, now: Date) {
        var recorded = Set(s.notified.map(\.key))
        for item in e.waiting where !recorded.contains(item.key) {
            guard s.notified.count < maxNotified else { s.quietOverflow = s.quietOverflow ?? now; break }
            s.notified.append(Notified(key: item.key, at: now))
            recorded.insert(item.key)
        }
        s.lastMessageAt = now
        s.attempt = MacUpdatesAttempt(keys: e.waiting.map(\.key), noticeGeneration: noticeGeneration,
                                      channelKind: destination.channelKind, chatId: destination.chatId,
                                      channelGeneration: destination.channelGeneration, text: text, attempt: 1,
                                      firstAttemptAt: now, deadline: now.addingTimeInterval(UpdateNotice.retryWindow),
                                      state: .inFlight, retryAfter: nil)
    }

    /// A terminal outcome is archived and the active slot cleared (so one
    /// message never blocks the next); only a proven refusal stays, for a
    /// bounded retry.
    static func recordOutcome(_ s: inout MacUpdatesState, _ outcome: UpdateNotice.SendOutcome, now: Date) {
        guard var a = s.attempt else { return }
        switch outcome {
        case .accepted: a.state = .accepted
        case .ambiguous: a.state = .ambiguous
        case .dropped: a.state = .dropped
        case .refused(let after):
            a.state = .refused
            a.retryAfter = now.addingTimeInterval(max(1, after))
        }
        s.lastOutcome = LocalVulnOutcome(at: now, outcome: a.state)
        s.attempt = a.state == .refused && a.attempt < UpdateNotice.maxAttempts && now < a.deadline ? a : nil
    }

    static func settleCrashed(_ s: inout MacUpdatesState, now: Date) -> Bool {
        guard let a = s.attempt, a.state == .inFlight else { return false }
        s.lastOutcome = LocalVulnOutcome(at: now, outcome: .lost)
        s.attempt = nil
        return true
    }

    enum RetryDecision: Equatable { case none, notYet, drop, retry }

    static func retryDecision(_ s: MacUpdatesState, now: Date, noticeGeneration: UInt64,
                              channelGeneration: (String?) -> UInt64) -> RetryDecision {
        guard let a = s.attempt, a.state == .refused else { return .none }
        if a.attempt >= UpdateNotice.maxAttempts || now >= a.deadline { return .drop }
        if a.noticeGeneration != noticeGeneration || channelGeneration(a.channelKind) != a.channelGeneration { return .drop }
        if let after = a.retryAfter, now < after { return .notYet }
        return .retry
    }

    static func markRetryInFlight(_ s: inout MacUpdatesState) {
        guard var a = s.attempt else { return }
        a.attempt += 1
        a.state = .inFlight
        a.retryAfter = nil
        s.attempt = a
    }

    /// A retry is allowed only while every consumed key is still waiting.
    static func stillValid(_ a: MacUpdatesAttempt, _ e: Evaluation) -> Bool {
        let waiting = Set(e.waiting.map(\.key))
        return a.keys.allSatisfy { waiting.contains($0) }
    }
}
