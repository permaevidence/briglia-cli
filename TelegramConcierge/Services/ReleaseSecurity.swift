import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Signed security metadata inside the release manifest (security plan v8
/// §4): the optional `security` block and `componentAdvisories` list.
///
/// Parsed AFTER, and separately from, the required manifest verification
/// (`ReleaseSigning.verifyEnvelope`): any problem here makes only this
/// metadata `unknown`; the manifest still verifies and `/upgrade` behaves
/// exactly as before. Pure functions only — no I/O.
enum ReleaseSecurity {

    // MARK: - Model

    enum Level: String, Codable, Comparable {
        case recommended, critical
        static func < (a: Level, b: Level) -> Bool { a == .recommended && b == .critical }
    }

    /// One cumulative advisory after the §4.2 transitive in-manifest merge:
    /// `ids` = {id} ∪ aliases, upper-cased, the published `id` first.
    struct Entry: Codable, Equatable {
        var ids: [String]
        var level: Level
        var affectsFrom: Int
        var fixedIn: Int
    }

    struct Block: Codable, Equatable {
        var cumulative: [Entry]
        /// Release-notes wording only (§4.3); identity sets, merged.
        var introduces: [Entry]
        var floorRecommended: Int
        var floorCritical: Int
        var summary: String?
    }

    /// `absent`: the manifest has no `security` field (every release before
    /// this feature) → "none known", never a claim. `unknown`: present but
    /// invalid → plain wording plus attention.
    enum Parsed: Equatable {
        case absent
        case unknown(String)
        case known(Block)
    }

    struct ComponentAdvisory: Codable, Equatable {
        var ecosystem: String
        var identity: [String: String]
        var minimumSafe: String
        var advisories: [String]
        var level: Level
    }

    /// `componentAdvisories` (§4.1): validated entries; an entry with a
    /// problem is counted as unknown, never dropped silently.
    struct Components: Codable, Equatable {
        var entries: [ComponentAdvisory]
        var unknownEntries: Int
        /// The whole field was malformed (not a list, too long).
        var invalid: Bool
        static let none = Components(entries: [], unknownEntries: 0, invalid: false)
    }

    /// Classification of a release for installed sequence I (§4.3).
    enum Classification: String, Equatable {
        case critical, recommended, none, noneKnown, unknown
        var includesSecurityFixes: Bool { self == .critical || self == .recommended }
    }

    // MARK: - Limits (§4.2)

    static let maxListEntries = 64
    static let maxStringBytes = 512
    static let maxSummaryBytes = 200
    static let maxIdentityIds = 16
    static let maxComponentAdvisoryIds = 16
    static let maxSequence: Int = 1 << 53
    static let idPattern = "^[A-Za-z0-9][A-Za-z0-9._:-]{2,63}$"
    static let ecosystems: [String: [String]] = [
        "deb": ["distro", "release", "arch"],
        "brew": ["tap", "formula", "versionScheme"],
        "npm": ["package"],
        "pypi": ["distribution"],
        "binary": ["vendor", "product", "platform"],
    ]

    struct Invalid: Error { let reason: String }

    // MARK: - Entry points

    /// Parses both fields from the AUTHENTICATED payload bytes. Never throws.
    static func parse(payload: Data, sequence: Int) -> (security: Parsed, components: Components) {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: payload),
              case .object(let object) = root else {
            return (.unknown("payload is not a JSON object"), Components(entries: [], unknownEntries: 0, invalid: true))
        }
        let security: Parsed
        if let raw = object["security"] {
            do { security = .known(try parseSecurity(raw, sequence: sequence)) }
            catch let e as Invalid { security = .unknown(e.reason) }
            catch { security = .unknown("unreadable") }
        } else {
            security = .absent
        }
        let components = object["componentAdvisories"].map(parseComponents) ?? .none
        return (security, components)
    }

    /// SHA-256 of the canonical payload EXCLUDING `expires` and `published`
    /// (§5.2: a renewal re-signs the same content with a new validity). The
    /// key ID and signature live in the envelope, not the payload.
    static func contentId(payload: Data) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        object.removeValue(forKey: "expires")
        object.removeValue(forKey: "published")
        guard let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return hex(SHA256.hash(data: canonical))
    }

    static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// §4.3 for installed sequence `installed`.
    static func classify(_ parsed: Parsed, installed: Int) -> Classification {
        switch parsed {
        case .absent: return .noneKnown
        case .unknown: return .unknown
        case .known(let block):
            var level: Level? = nil
            for e in block.cumulative where e.affectsFrom <= installed && installed < e.fixedIn {
                level = max(level ?? e.level, e.level)
            }
            if installed < block.floorCritical { level = .critical }
            if installed < block.floorRecommended { level = max(level ?? .recommended, .recommended) }
            switch level {
            case .critical?: return .critical
            case .recommended?: return .recommended
            case nil: return .none
            }
        }
    }

    // MARK: - security

    static func parseSecurity(_ raw: JSONValue, sequence: Int) throws -> Block {
        guard case .object(let o) = raw else { throw Invalid(reason: "security is not an object") }
        try onlyKeys(o, ["introduces", "cumulative", "securityFloor", "summary"], what: "security")
        let cumulativeRaw = try list(o["cumulative"] ?? .array([]), "cumulative")
        let introducesRaw = try list(o["introduces"] ?? .array([]), "introduces")
        var cumulative: [Entry] = []
        for item in cumulativeRaw {
            guard case .object(let e) = item else { throw Invalid(reason: "cumulative entry is not an object") }
            try onlyKeys(e, ["id", "aliases", "level", "fixedInSequence", "affectsFromSequence"], what: "cumulative entry")
            let ids = try identity(e)
            let level = try parseLevel(e["level"])
            let fixed = try seq(e["fixedInSequence"], "fixedInSequence")
            let from = try seq(e["affectsFromSequence"], "affectsFromSequence")
            guard from < fixed, fixed <= sequence else {
                throw Invalid(reason: "entry range [\(from), \(fixed)) violates affectsFrom < fixedIn ≤ \(sequence)")
            }
            cumulative.append(Entry(ids: ids, level: level, affectsFrom: from, fixedIn: fixed))
        }
        var introduces: [Entry] = []
        for item in introducesRaw {
            guard case .object(let e) = item else { throw Invalid(reason: "introduces entry is not an object") }
            try onlyKeys(e, ["id", "aliases", "level", "component"], what: "introduces entry")
            let ids = try identity(e)
            let level = try parseLevel(e["level"])
            if let c = e["component"] { _ = try string(c, "component", max: maxStringBytes) }
            introduces.append(Entry(ids: ids, level: level, affectsFrom: 0, fixedIn: sequence))
        }
        guard case .object(let floors)? = o["securityFloor"] else { throw Invalid(reason: "securityFloor missing or not an object") }
        try onlyKeys(floors, ["recommended", "critical"], what: "securityFloor")
        let floorR = try seq(floors["recommended"] ?? .int(0), "securityFloor.recommended")
        let floorC = try seq(floors["critical"] ?? .int(0), "securityFloor.critical")
        guard floorR <= sequence, floorC <= sequence else { throw Invalid(reason: "a security floor is above the release's own sequence") }
        var summary: String? = nil
        if let s = o["summary"] { summary = try string(s, "summary", max: maxSummaryBytes) }
        return Block(cumulative: try mergeTransitively(cumulative),
                     introduces: try mergeTransitively(introduces),
                     floorRecommended: floorR, floorCritical: floorC, summary: summary)
    }

    /// §4.2: entries whose identity sets intersect are one advisory,
    /// transitively (union-find). Highest level wins, ranges widen; a merged
    /// set above 16 IDs is rejected, never truncated.
    static func mergeTransitively(_ entries: [Entry]) throws -> [Entry] {
        var parent = Array(entries.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        var owner: [String: Int] = [:]
        for (i, e) in entries.enumerated() {
            for id in e.ids {
                if let j = owner[id] { let a = find(i), b = find(j); if a != b { parent[max(a, b)] = min(a, b) } }
                else { owner[id] = i }
            }
        }
        var groups: [Int: Entry] = [:]
        var order: [Int] = []
        for (i, e) in entries.enumerated() {
            let r = find(i)
            if var g = groups[r] {
                for id in e.ids where !g.ids.contains(id) { g.ids.append(id) }
                g.level = max(g.level, e.level)
                g.affectsFrom = min(g.affectsFrom, e.affectsFrom)
                g.fixedIn = max(g.fixedIn, e.fixedIn)
                groups[r] = g
            } else {
                groups[r] = e
                order.append(r)
            }
        }
        return try order.map { r in
            let g = groups[r]!
            guard g.ids.count <= maxIdentityIds else {
                throw Invalid(reason: "a merged identity set has \(g.ids.count) IDs (limit \(maxIdentityIds))")
            }
            return g
        }
    }

    // MARK: - componentAdvisories

    static func parseComponents(_ raw: JSONValue) -> Components {
        guard case .array(let items) = raw, items.count <= maxListEntries else {
            return Components(entries: [], unknownEntries: 0, invalid: true)
        }
        var out = Components(entries: [], unknownEntries: 0, invalid: false)
        for item in items {
            if let entry = try? parseComponent(item) { out.entries.append(entry) } else { out.unknownEntries += 1 }
        }
        return out
    }

    static func parseComponent(_ raw: JSONValue) throws -> ComponentAdvisory {
        guard case .object(let o) = raw else { throw Invalid(reason: "not an object") }
        try onlyKeys(o, ["ecosystem", "identity", "minimumSafe", "advisories", "level"], what: "component advisory")
        let eco = try string(o["ecosystem"], "ecosystem", max: 16)
        guard let required = ecosystems[eco] else { throw Invalid(reason: "unknown ecosystem") }
        guard case .object(let idObject)? = o["identity"] else { throw Invalid(reason: "identity missing") }
        var identity: [String: String] = [:]
        for (k, v) in idObject {
            if case .int(let n) = v, k == "versionScheme", n >= 0, n < 1000 { identity[k] = String(n); continue }
            identity[k] = try string(v, "identity.\(k)", max: maxStringBytes)
        }
        var expected = Set(required)
        if eco == "deb" {
            let named = ["sourcePackage", "binaryPackage"].filter { identity[$0] != nil }
            guard named.count == 1 else { throw Invalid(reason: "deb identity needs exactly one of sourcePackage/binaryPackage") }
            expected.insert(named[0])
        }
        guard Set(identity.keys) == expected else { throw Invalid(reason: "identity fields do not match the ecosystem") }
        let minimum = try string(o["minimumSafe"], "minimumSafe", max: 128)
        let ids = try list(o["advisories"] ?? .null, "advisories").map { try advisoryId($0) }
        guard (1...maxComponentAdvisoryIds).contains(ids.count) else { throw Invalid(reason: "advisories must hold 1–16 IDs") }
        return ComponentAdvisory(ecosystem: eco, identity: identity, minimumSafe: minimum,
                                 advisories: ids, level: try parseLevel(o["level"]))
    }

    // MARK: - Field helpers

    private static func onlyKeys(_ o: [String: JSONValue], _ allowed: Set<String>, what: String) throws {
        if let extra = o.keys.first(where: { !allowed.contains($0) }) {
            throw Invalid(reason: "\(what) has an unknown field '\(extra.prefix(40))'")
        }
    }

    private static func list(_ v: JSONValue, _ name: String) throws -> [JSONValue] {
        guard case .array(let items) = v else { throw Invalid(reason: "\(name) is not a list") }
        guard items.count <= maxListEntries else { throw Invalid(reason: "\(name) has more than \(maxListEntries) entries") }
        return items
    }

    private static func string(_ v: JSONValue?, _ name: String, max: Int) throws -> String {
        guard case .string(let s)? = v else { throw Invalid(reason: "\(name) is not a string") }
        guard s.utf8.count <= max else { throw Invalid(reason: "\(name) is longer than \(max) bytes") }
        return s
    }

    private static func seq(_ v: JSONValue?, _ name: String) throws -> Int {
        guard case .int(let n)? = v, n >= 0, n < maxSequence else {
            throw Invalid(reason: "\(name) is not an integer in [0, 2^53)")
        }
        return Int(n)
    }

    private static func parseLevel(_ v: JSONValue?) throws -> Level {
        guard case .string(let s)? = v, let level = Level(rawValue: s) else { throw Invalid(reason: "level is not recommended|critical") }
        return level
    }

    private static func advisoryId(_ v: JSONValue) throws -> String {
        guard case .string(let s) = v, s.range(of: idPattern, options: .regularExpression) != nil else {
            throw Invalid(reason: "an advisory ID does not match the ID pattern")
        }
        return s.uppercased()
    }

    /// {id} ∪ aliases, upper-cased, id first, duplicates removed, ≤ 16.
    private static func identity(_ e: [String: JSONValue]) throws -> [String] {
        var ids = [try advisoryId(e["id"] ?? .null)]
        for alias in try list(e["aliases"] ?? .array([]), "aliases") {
            let a = try advisoryId(alias)
            if !ids.contains(a) { ids.append(a) }
        }
        guard ids.count <= maxIdentityIds else { throw Invalid(reason: "an identity set has more than \(maxIdentityIds) IDs") }
        return ids
    }

    // MARK: - Display

    /// `summary` as plain text: control characters and markup stripped,
    /// length-capped; links are never rendered from it.
    static func plainSummary(_ text: String?) -> String? {
        guard let text else { return nil }
        var out = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .format { out.append(" "); continue }
            if "<>*_`[]#|~".unicodeScalars.contains(scalar) { continue }
            out.unicodeScalars.append(scalar)
        }
        let collapsed = out.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        let capped = String(collapsed.prefix(200))
        return capped.isEmpty ? nil : capped
    }
}
