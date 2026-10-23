import Foundation

/// Durable state of the update-available notice (security plan v8 §5.4.1):
/// `~/.local/share/briglia/update/notice.json`. Everything here is bounded
/// (≤ 4 trust domains, ≤ 256 advisory classes, ≤ 3 attempt records); the
/// writer refuses a file above `UpdateNotice.maxStateBytes`.
///
/// None of this is a trust floor: it never makes `/upgrade` refuse anything
/// and is never written into `ReleaseTrustStore` (§5.1).
struct UpdateNoticeState: Codable, Equatable {
    var schema = 1

    // Checker fields (§5.1)
    var lastAttempt: Date?
    var lastSuccess: Date?
    /// When the next regular check is due (6 h ± 30 min after `lastAttempt`).
    var nextCheckAt: Date?
    /// Short reason of the last failed check (status only).
    var lastCheckProblem: String?

    var domains: [DomainRecord] = []
    /// The trust domain the class tables below belong to (the running binary's).
    var runningDomain: String?
    /// The installed sequence `I` the class tables were computed for.
    var installedBaseline: Int?
    /// Highest release sequence a release notice named (monotonic; reset
    /// only on an installed-sequence decrease or a domain change).
    var announcedThrough = 0
    var lastReleaseNoticeAt: Date?
    var lastOutcome: OutcomeRecord?
    var classes: [AdvisoryClass] = []
    /// Creation counter: "earliest-created" for merges (classIds are random).
    var nextOrdinal = 1
    var saturated: Saturation?
    /// At most one per kind (release, reminder); UT advisory notices arrive
    /// with Phase 3.
    var attempts: [AttemptRecord] = []

    func domain(_ id: String) -> DomainRecord? { domains.first { $0.domain == id } }

    mutating func withDomain(_ id: String, now: Date, _ body: (inout DomainRecord) -> Void) {
        if let i = domains.firstIndex(where: { $0.domain == id }) {
            body(&domains[i])
            domains[i].touchedAt = now
            return
        }
        var record = DomainRecord(domain: id, touchedAt: now)
        body(&record)
        domains.append(record)
        // ≤ 4 domains, oldest dropped first (never the running one).
        while domains.count > UpdateNotice.maxDomains,
              let victim = domains.enumerated()
                .filter({ $0.element.domain != runningDomain && $0.element.domain != id })
                .min(by: { $0.element.touchedAt < $1.element.touchedAt }) {
            domains.remove(at: victim.offset)
        }
    }

    func attempt(_ kind: AttemptRecord.Kind) -> AttemptRecord? { attempts.first { $0.kind == kind } }
}

struct DomainRecord: Codable, Equatable {
    var domain: String
    var observed: ObservedRelease?
    var lowerSince: Date?
    var lastLowerSequence: Int?
    var inconsistentSince: Date?
    var touchedAt: Date
}

/// The durable highest-observed record of one trust domain (§5.2).
struct ObservedRelease: Codable, Equatable {
    var sequence: Int
    var version: String
    var contentId: String
    var manifestDigest: String
    var expires: Date
    var firstSeenAt: Date
    var lastConfirmedAt: Date
    var security: SecurityRecord
    var components: ReleaseSecurity.Components
    var hasBuild: Bool
}

/// Codable form of `ReleaseSecurity.Parsed`.
struct SecurityRecord: Codable, Equatable {
    var state: String           // absent | unknown | known
    var reason: String?
    var block: ReleaseSecurity.Block?

    init(_ parsed: ReleaseSecurity.Parsed) {
        switch parsed {
        case .absent: state = "absent"
        case .unknown(let why): state = "unknown"; reason = String(why.prefix(200))
        case .known(let b): state = "known"; block = b
        }
    }

    var parsed: ReleaseSecurity.Parsed {
        switch state {
        case "absent": return .absent
        case "known": return block.map { .known($0) } ?? .unknown("stored block missing")
        default: return .unknown(reason ?? "unknown")
        }
    }
}

/// One real-world advisory as this installation has come to know it
/// (§5.4.1). Synthetic floor classes have `floor` set and
/// `members == ["floor:<level>"]` (lower-case, so they never collide with
/// upper-cased advisory IDs).
struct AdvisoryClass: Codable, Equatable {
    var classId: String
    var ordinal: Int
    var members: [String]
    var floor: ReleaseSecurity.Level?
    /// Highest level ever NOTIFIED (only a consume raises it).
    var level: ReleaseSecurity.Level
    var affectsFrom: Int
    var fixedIn: Int
    var firstNoticeAt: Date
    var reminderDueAt: Date?
    var reminderAttempted: Bool
    var supersededBy: String?

    static func floorKey(_ level: ReleaseSecurity.Level) -> String { "floor:\(level.rawValue)" }
}

struct Saturation: Codable, Equatable {
    var since: Date
    var droppedCount: Int
}

struct OutcomeRecord: Codable, Equatable {
    var kind: AttemptRecord.Kind
    var at: Date
    var outcome: AttemptRecord.State
    var sequence: Int?
}

/// A self-contained delivery record (§5.4.1, §5.5): everything a retry is
/// checked against after a restart is stored here, never inferred.
struct AttemptRecord: Codable, Equatable {
    enum Kind: String, Codable { case release, reminder }
    enum State: String, Codable { case inFlight = "in-flight", refused, ambiguous, lost, accepted, dropped }

    var kind: Kind
    /// Release sequence the notice names (release: L; reminder: the observed
    /// release it named).
    var sequence: Int
    /// Reminder: the classes it covers (rewritten to the survivor on merge).
    var classIds: [String]
    var domain: String
    var observedContentId: String
    var installedBaseline: Int
    var noticeGeneration: UInt64
    var channelKind: String?
    var chatId: String?
    var channelGeneration: UInt64
    var text: String
    var attempt: Int
    var firstAttemptAt: Date
    var deadline: Date
    var state: State
    var retryAfter: Date?
}

/// `~/.config/briglia/update-check.json` (§5.6): the user's setting plus
/// the notice generation, which `/deleteuserdata` bumps (it survives the
/// deletion of `notice.json`, so a check or send already in progress can
/// never write its result back).
struct UpdateCheckSetting: Codable, Equatable {
    var schema = 1
    var enabled: Bool
    var generation: UInt64 = 0
    var changedAt: Date?
}
