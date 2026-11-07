import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// KEYLESS_WEB_AND_LIVE_MENU plan, Part B — the data the single settings
// writer works on. A `PreparedChange` is a pure description produced by
// `SettingsCapture.prepare` (validation, probes and listings ran; nothing was
// written) and committed by `SettingsWriter` in the process that owns the
// profile's instance lease.

/// Value digests for preconditions. Values never appear in clear outside the
/// change itself (the change is secret-bearing by design, D18).
enum SettingsDigest {
    static let absent = "-"

    static func of(_ value: String?) -> String {
        guard let value else { return absent }
        let digest = SHA256.hash(data: Data(("briglia-settings-v1\u{0}" + value).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The whole store's values (attempt markers excluded): the basis of a
    /// preparation that ran a dictionary transaction.
    static func ofStore(_ store: [String: String]) -> String {
        of(pairs: store.filter { !$0.key.hasPrefix(SettingsWriter.attemptMarkerPrefix) })
    }

    /// One digest of several key/value pairs, order-independent.
    static func of(pairs: [String: String]) -> String {
        let body = pairs.keys.sorted().map { "\($0)=\(of(pairs[$0]))" }.joined(separator: "\n")
        return of(body)
    }
}

/// `dataRoot/replacement-epoch` (plan B.8): an integer that a wipe and a Mind
/// import advance durably BEFORE their first destructive step. Every prepared
/// change, staged slot and menu ticket carries the epoch read before
/// preparing; commit and apply refuse on mismatch. The file itself is never
/// deleted (a wipe keeps it).
enum ReplacementEpoch {
    static let fileName = "replacement-epoch"
    static var url: URL { StoragePaths.dataRoot.appendingPathComponent(fileName) }

    struct Damaged: Error, CustomStringConvertible {
        let description: String
    }

    /// Absent → 0. An unreadable or malformed file throws (fail closed: a
    /// commit is refused rather than pairing an unknown epoch with data).
    static func read(at url: URL = ReplacementEpoch.url) throws -> Int {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return 0 }
            throw Damaged(description: "\(url.path) cannot be read: \(error.localizedDescription)")
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let value = Int(text), value >= 0 else {
            throw Damaged(description: "\(url.path) is not a valid replacement epoch")
        }
        return value
    }

    /// Durably writes `epoch + 1` and returns it. A post-rename durability
    /// failure is reported as an error: the caller stops before destroying
    /// anything (the advanced value may already be visible, which only
    /// refuses more old requests — never fewer).
    @discardableResult
    static func advance(at url: URL = ReplacementEpoch.url) throws -> Int {
        let next = try read(at: url) + 1
        try PrivateStorage.ensureDirectory(url.deletingLastPathComponent())
        try PrivateStorage.writeAtomically(Data("\(next)\n".utf8), to: url, mode: 0o600)
        return next
    }
}

/// An AgentMail inbox or Telegram bot change carried by a prepared change
/// (plan B.4a step 5): reserved at commit with `IdentityChange.begin`.
struct SettingsIdentityOp: Codable, Equatable {
    /// "bot" or "inbox".
    var kind: String
    /// The new value; nil = removal.
    var value: String?
}

/// A ChatGPT login operation carried by a prepared change (plan B.4a 8.2,
/// B.5 "Sign-in and the subscription commands").
struct SettingsSubscriptionOp: Codable, Equatable {
    enum Kind: String, Codable {
        /// Publish a finished login (credential + new generation).
        case publish
        /// Cancel a pending login (generation-preserving).
        case cancel
        /// Sign out (durable tombstone, new generation).
        case logout
    }
    var kind: Kind
    /// The exact auth-store directory, resolved at preparation (B.4c).
    var store: String
    /// publish: the pending login it completes; cancel: the pending id.
    var pending: String?
    /// publish: the device-flow poll attempt that must still own the
    /// challenge (setup-api poll), nil for browser/device logins.
    var deviceAttempt: String?
    var credential: SubscriptionCredential?
    /// publish / logout: the new generation id, generated once here so the
    /// projection at the decision point is exact and no second id exists.
    var projectedGeneration: String?
    /// publish: recheck the active-login replacement guard at commit.
    var guardActiveLogin: Bool = false

    static func == (a: SettingsSubscriptionOp, b: SettingsSubscriptionOp) -> Bool {
        a.kind == b.kind && a.store == b.store && a.pending == b.pending && a.deviceAttempt == b.deviceAttempt
            && a.credential?.access == b.credential?.access && a.projectedGeneration == b.projectedGeneration
            && a.guardActiveLogin == b.guardActiveLogin
    }
}

/// A subscription state a prepared change was computed from (e.g. "select"
/// was validated against this generation).
struct SettingsSubscriptionExpectation: Codable, Equatable {
    var store: String
    /// "" = the store had no state (absent) when the change was prepared.
    var generation: String
    var requireUsable: Bool
    var requireNoPending: Bool
    /// Recorded automatically from a preparation's read (R1-3).
    var basis: Bool = false

    init(store: String, generation: String, requireUsable: Bool, requireNoPending: Bool) {
        self.store = store; self.generation = generation
        self.requireUsable = requireUsable; self.requireNoPending = requireNoPending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        store = try c.decode(String.self, forKey: .store)
        generation = try c.decode(String.self, forKey: .generation)
        requireUsable = try c.decode(Bool.self, forKey: .requireUsable)
        requireNoPending = try c.decode(Bool.self, forKey: .requireNoPending)
        basis = try c.decodeIfPresent(Bool.self, forKey: .basis) ?? false
    }
}

struct PreparedChange: Codable {
    var version = 1
    /// The client request id (also the default attempt id).
    var id: String = UUID().uuidString
    /// "menu", "setup-api", "wizard", "subscription", "telegram", "agent-edit", …
    var origin: String
    /// Human label for the page and /status ("Search key", "AI model", …).
    var label: String
    /// Pending slot: "ai" or "email".
    var category: String = "ai"
    var writes: [String: String] = [:]
    var deletes: [String] = []
    /// key → `SettingsDigest` of the value the change was prepared from.
    var expected: [String: String] = [:]
    /// When preparation read the whole store: the digest of its route and
    /// credential keys (plan B.4 "every key whose value it was prepared from").
    var routeDigest: String?
    /// The whole store's values when preparation ran a dictionary
    /// transaction (`SettingsDigest.ofStore`; R1-7).
    var storeDigest: String?
    /// No net write, but explicit writes/transaction reads to validate.
    var validateOnly: Bool?
    /// `ReplacementEpoch` read before preparation (plan B.8).
    var epoch: Int
    var identity: SettingsIdentityOp?
    var subscription: SettingsSubscriptionOp?
    var subscriptionExpectations: [SettingsSubscriptionExpectation] = []
    /// Sign in with ChatGPT activation (SIWC plan §3.9): token-free by type.
    var siwc: SIWCSettingsOp?
    /// `AgentMailService.wipePrivateInstall` after the secrets write
    /// (email provider none + remove credentials).
    var wipeAgentMailInstall = false
    /// /websearch now lives in secrets.json (plan B.4); this value is also
    /// mirrored to the old preference so a downgraded binary still sees it.
    var webBackendMirror: String?
    /// The reply the prepared request produced (setup-api shape), JSON text.
    var reply: String?
    /// The client accepts `pending` for a route change while busy.
    var acceptPending = false

    var touchedKeys: Set<String> { Set(writes.keys).union(deletes) }
    var hasAuthEffect: Bool { subscription != nil || siwc != nil }
    var isEmpty: Bool { writes.isEmpty && deletes.isEmpty && identity == nil && subscription == nil && siwc == nil && !wipeAgentMailInstall }
    /// Nothing to write AND nothing to validate: the caller may skip the commit.
    var isNoop: Bool { isEmpty && validateOnly != true }

    /// The secrets mutation in `mutateHolding` form.
    var secretsDelta: [String: String?] {
        var out: [String: String?] = [:]
        for (k, v) in writes { out[k] = .some(v) }
        for k in deletes { out[k] = .some(nil) }
        return out
    }

    var replyObject: [String: Any]? {
        guard let reply, let data = reply.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> PreparedChange {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let change = try decoder.decode(PreparedChange.self, from: data)
        guard change.version == 1, change.writes.count + change.deletes.count <= 4096,
              ["ai", "email"].contains(change.category) else {
            throw SettingsCommitError.refused("malformed settings change")
        }
        return change
    }

    static func jsonText(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum SettingsCommitError: Error, CustomStringConvertible, LocalizedError {
    case refused(String)
    var description: String { if case .refused(let m) = self { return m }; return "" }
    var errorDescription: String? { description }
}

/// The owner's answer to one commit (plan B.6).
struct SettingsCommitResult {
    enum State: String {
        /// Durably written (and, in the daemon, reconciled).
        case applied
        /// Staged: busy + route change; applies at the next idle point.
        case pending
        /// Busy + route change and the client did not accept pending.
        case busy
        /// Refused before anything was written (precondition, epoch,
        /// admission, shape…).
        case refused
        /// The first durable effect happened, but not all of them (B.5).
        case partial
        /// The outcome is not known (crash or unreadable evidence).
        case uncertain
        case error
    }
    var state: State
    var message: String?
    var ticket: String?
    /// A machine-readable refusal code (`owner_protocol_unsupported`, …).
    var code: String?
    /// The prepared reply (setup-api shape), returned on `applied`.
    var reply: [String: Any]?
    /// Refused before the decision point (identity reservation, sharing or
    /// auth lock, barrier): nothing was evaluated or written, so a claimed
    /// pending change goes back to staged (plan B.5, Codex R1-6).
    var preDecision = false

    static func refused(_ message: String) -> SettingsCommitResult { .init(state: .refused, message: message) }

    var json: [String: Any] {
        var out: [String: Any] = ["state": state.rawValue]
        if let message { out["message"] = message }
        if let ticket { out["ticket"] = ticket }
        if let code { out["code"] = code }
        if let reply { out["reply"] = reply }
        return out
    }

    init(state: State, message: String? = nil, ticket: String? = nil, reply: [String: Any]? = nil) {
        self.state = state; self.message = message; self.ticket = ticket; self.reply = reply
    }

    init?(json: [String: Any]) {
        guard let raw = json["state"] as? String, let state = State(rawValue: raw) else { return nil }
        self.init(state: state, message: json["message"] as? String, ticket: json["ticket"] as? String,
                  reply: json["reply"] as? [String: Any])
        code = json["code"] as? String
    }
}
