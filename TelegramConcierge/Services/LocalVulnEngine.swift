import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// `localvuln.json` (security plan v16 §9.5.5): the send-once table keyed by
/// (identity, installed version), its single attempt record, and the last
/// evaluation (for display only). Bounded: ≤ 256 rows with quiet overflow
/// (§5.4.4), ≤ 512 KiB on disk.
struct LocalVulnState: Codable, Equatable {
    var schema = 1
    var rows: [LocalVulnRow] = []
    var saturated: Saturation?
    var attempt: LocalVulnAttempt?
    var lastOutcome: LocalVulnOutcome?
    var report: LocalToolsSnapshot?
}

struct LocalVulnOutcome: Codable, Equatable {
    var at: Date
    var outcome: AttemptRecord.State
}

/// What the first message for a key actually communicated (v16 R15-3:
/// recorded in the same atomic write as its attempt). `floor` stays false
/// until the §9.5.8 support floor is implemented.
struct LocalVulnCommunicated: Codable, Equatable {
    var floor: Bool
    var level: ReleaseSecurity.Level
    var kev: Bool
    var kevNoFix: Bool
}

struct LocalVulnRow: Codable, Equatable {
    var key: String
    var identityKey: String
    /// Every watched tool seen at this (identity, installed version), e.g.
    /// curl and libcurl from source `curl` (R6).
    var toolIds: [String]
    var installedVersion: String
    var firstAt: Date
    var communicated: LocalVulnCommunicated
    var escalationUsed: Bool
    var fixFollowUpSent: Bool
}

struct LocalToolsSnapshot: Codable, Equatable {
    var evaluatedAt: Date
    var listSequence: Int?
    var listContentId: String?
    var reports: [LocalTools.ToolReport]
}

struct LocalVulnAttempt: Codable, Equatable {
    struct Line: Codable, Equatable {
        var key: String
        var kind: LocalVuln.LineKind
        var toolId: String
        var installedVersion: String
        /// What the stored text claims (R4): a retry is sent only while the
        /// fresh evaluation still yields exactly this condition.
        var condition: String
    }
    var lines: [Line]
    var listContentId: String
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

/// Pure V4/V5 rules for the local-tool messages.
enum LocalVuln {
    static let maxRows = 256
    static let maxNamedLines = 5

    enum LineKind: String, Codable { case initial, escalation, followUp = "follow-up" }

    struct Proposal: Equatable {
        var key: String
        var kind: LineKind
        var report: LocalTools.ToolReport
    }

    static func rowKey(identityKey: String, installedVersion: String) -> String {
        ReleaseSecurity.hex(SHA256.hash(data: Data("\(identityKey)\n\(installedVersion)".utf8)))
    }

    /// Rows leave only on POSITIVE evidence (R6: identity-wide): no running
    /// instance is at this (identity, installed version) any more, and every
    /// tool that was seen at it is now positively absent or runs the same
    /// identity at another version. An unknown resolution, a missing one, or
    /// a tool that now resolves to a different identity keeps the row.
    static func reconcile(_ s: inout LocalVulnState, _ resolutions: [LocalTools.Resolution]) {
        var kept: [LocalVulnRow] = []
        for var row in s.rows {
            let matching = resolutions.compactMap { r -> String? in
                if case .present(let i) = r, i.identity.key == row.identityKey, i.installedVersion == row.installedVersion { return i.toolId }
                return nil
            }
            if !matching.isEmpty {
                for t in matching where !row.toolIds.contains(t) { row.toolIds.append(t) }
                kept.append(row)
                continue
            }
            let evidence = row.toolIds.map { tool -> Bool in
                guard let r = resolutions.first(where: { $0.toolId == tool }) else { return false }
                switch r {
                case .absent: return true
                case .unknown: return false
                case .present(let i): return i.identity.key == row.identityKey   // same identity, other version
                }
            }
            if evidence.isEmpty || evidence.contains(false) { kept.append(row) }
        }
        s.rows = kept
        if s.rows.count < maxRows { s.saturated = nil }
    }

    /// The lines one check would send, in watchlist order. Overflow (a new
    /// key while 256 rows exist) is quiet: no line, `saturated` recorded by
    /// the caller's state-only write.
    static func proposals(_ s: LocalVulnState, reports: [LocalTools.ToolReport]) -> (lines: [Proposal], overflow: Int) {
        var out: [Proposal] = [], overflow = 0
        var newKeys = 0
        var seen = Set<String>()
        for r in reports where r.messageable {
            guard let identity = r.identityKey, let version = r.installedVersion else { continue }
            let key = rowKey(identityKey: identity, installedVersion: version)
            // Two watched tools can share one identity (curl and libcurl
            // both come from the `curl` source): one key, one line.
            guard seen.insert(key).inserted else { continue }
            guard let row = s.rows.first(where: { $0.key == key }) else {
                if s.rows.count + newKeys >= maxRows { overflow += 1; continue }
                newKeys += 1
                out.append(Proposal(key: key, kind: .initial, report: r))
                continue
            }
            // R5: the follow-up needs a KEV advisory that itself gained an
            // installable fix (another advisory's fix is no such evidence).
            if row.communicated.kevNoFix, r.affected.contains(where: { $0.kev && $0.fix == .installable }), !row.fixFollowUpSent {
                out.append(Proposal(key: key, kind: .followUp, report: r))
                continue
            }
            let exceeds = (r.level == .critical && row.communicated.level == .recommended) || (r.kevAffected && !row.communicated.kev)
            if exceeds, !row.escalationUsed { out.append(Proposal(key: key, kind: .escalation, report: r)) }
        }
        return (out, overflow)
    }

    /// Consume: rows and the attempt record change together (the caller
    /// writes them in ONE atomic replacement before the single send).
    /// `reports`: the whole evaluation the lines were derived from. A new
    /// row records EVERY tool seen at its (identity, version) in it, in this
    /// same atomic write (R2-R6), so a member's later failure cannot reset
    /// the send-once guarantee.
    static func consume(_ s: inout LocalVulnState, _ lines: [Proposal], reports: [LocalTools.ToolReport] = [],
                        text: String, listContentId: String,
                        noticeGeneration: UInt64, destination: UpdateNotice.Destination, now: Date) {
        for p in lines {
            let r = p.report
            switch p.kind {
            case .initial:
                var members = [r.toolId]
                for o in reports where o.identityKey == r.identityKey && o.installedVersion == r.installedVersion
                    && o.identityKey != nil && !members.contains(o.toolId) {
                    members.append(o.toolId)
                }
                s.rows.append(LocalVulnRow(
                    key: p.key, identityKey: r.identityKey ?? "?", toolIds: members, installedVersion: r.installedVersion ?? "?",
                    firstAt: now,
                    communicated: LocalVulnCommunicated(floor: false, level: r.level, kev: r.kevAffected,
                                                        kevNoFix: r.kevWithoutFix && !r.hasInstallableFix),
                    escalationUsed: false, fixFollowUpSent: false))
            case .followUp:
                if let i = s.rows.firstIndex(where: { $0.key == p.key }) {
                    s.rows[i].fixFollowUpSent = true
                    // A follow-up that also carries a higher condition uses
                    // the one escalation.
                    if r.level == .critical && s.rows[i].communicated.level == .recommended {
                        s.rows[i].communicated.level = .critical
                        s.rows[i].escalationUsed = true
                    }
                }
            case .escalation:
                if let i = s.rows.firstIndex(where: { $0.key == p.key }) {
                    s.rows[i].escalationUsed = true
                    if r.level == .critical { s.rows[i].communicated.level = .critical }
                    if r.kevAffected { s.rows[i].communicated.kev = true }
                }
            }
        }
        s.attempt = LocalVulnAttempt(
            lines: lines.map { .init(key: $0.key, kind: $0.kind, toolId: $0.report.toolId,
                                     installedVersion: $0.report.installedVersion ?? "?",
                                     condition: condition($0.report, kind: $0.kind)) },
            listContentId: listContentId, noticeGeneration: noticeGeneration, channelKind: destination.channelKind,
            chatId: destination.chatId, channelGeneration: destination.channelGeneration, text: text,
            attempt: 1, firstAttemptAt: now, deadline: now.addingTimeInterval(UpdateNotice.retryWindow),
            state: .inFlight, retryAfter: nil)
    }

    static func recordOutcome(_ s: inout LocalVulnState, _ outcome: UpdateNotice.SendOutcome, now: Date) {
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

    /// A process that crashed with an attempt in flight: lost (terminal).
    static func settleCrashed(_ s: inout LocalVulnState, now: Date) -> Bool {
        guard let a = s.attempt, a.state == .inFlight else { return false }
        s.lastOutcome = LocalVulnOutcome(at: now, outcome: .lost)
        s.attempt = nil
        return true
    }

    enum RetryDecision: Equatable { case none, notYet, drop, retry }

    /// Retry only a PROVEN refusal, ≤ 3 attempts within 1 h, against the
    /// fields stored in the record; the caller then re-validates every line
    /// with a fresh probe before sending the stored text.
    static func retryDecision(_ s: LocalVulnState, now: Date, noticeGeneration: UInt64,
                              channelGeneration: (String?) -> UInt64, listContentId: String?) -> RetryDecision {
        guard let a = s.attempt, a.state == .refused else { return .none }
        if a.attempt >= UpdateNotice.maxAttempts || now >= a.deadline { return .drop }
        if a.noticeGeneration != noticeGeneration || channelGeneration(a.channelKind) != a.channelGeneration
            || listContentId != a.listContentId { return .drop }
        if let after = a.retryAfter, now < after { return .notYet }
        return .retry
    }

    /// Durably re-marked in flight with the next attempt number before each
    /// retry: a crash before its outcome makes it lost, never a replay.
    static func markRetryInFlight(_ s: inout LocalVulnState) {
        guard var a = s.attempt else { return }
        a.attempt += 1
        a.state = .inFlight
        a.retryAfter = nil
        s.attempt = a
    }

    /// The message-relevant condition of a line: every applicable advisory
    /// with its severity, KEV flag and fix class, plus the fix action.
    static func condition(_ r: LocalTools.ToolReport, kind: LineKind) -> String {
        func fixClass(_ f: LocalTools.FixState) -> String {
            switch f {
            case .installable: return "installable"
            case .notInstallable: return "not-installable"
            case .noFix: return "no-fix"
            case .unknown: return "unknown"
            }
        }
        let adv = r.affected.map { "\($0.primaryId)|\($0.severity.rawValue)|\($0.kev)|\(fixClass($0.fix))|\($0.fixedVersion ?? "")" }.sorted()
        let action = (try? JSONEncoder().encode(r.action)).map { String(decoding: $0, as: UTF8.self) } ?? "none"
        return ([kind.rawValue, r.identityKey ?? "", r.installedVersion ?? "", action] + adv).joined(separator: "\n")
    }

    /// Every consumed line must still describe EXACTLY the consumed
    /// condition (R4): same key, same advisories and fix classes, same
    /// action; otherwise the stored text is obsolete and is never resent.
    static func linesStillValid(_ a: LocalVulnAttempt, reports: [LocalTools.ToolReport]) -> Bool {
        a.lines.allSatisfy { line in
            guard let r = reports.first(where: { $0.toolId == line.toolId }), r.messageable,
                  r.installedVersion == line.installedVersion, let id = r.identityKey else { return false }
            if rowKey(identityKey: id, installedVersion: line.installedVersion) != line.key { return false }
            return condition(r, kind: line.kind) == line.condition
        }
    }
}
