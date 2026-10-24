import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The signed advisory list for the user's own tools (security plan v16
/// §9.5.3): a small curated document the private daily job signs with its
/// own Ed25519 key, fetched once a day by every client from the same URL and
/// matched locally (§9.5.4). It authorises nothing and carries no commands or
/// display text: every command and sentence is compiled into Briglia and
/// filled only with locally validated names.
///
/// Trust is separate from the release keys: own envelope format, own
/// domain-separation string, own pinned key set. Until the owner provisions
/// the production key (docs: LOCAL_TOOLS_KEY_PROVISIONING), the pinned set
/// holds a marked placeholder that verifies nothing; the feature then reports
/// "unknown" and makes no request.
enum LocalAdvisory {
    static let envelopeFormat = "briglia-advisory-envelope-v1"
    /// Domain-separation string of this trust domain. Rotating the key set
    /// after a compromise also rotates this string (§9.5.3 recovery), so the
    /// clients' highest-observed record starts afresh for the new domain.
    static let domainString = "briglia-local-tool-advisories-v1"
    static let schemaVersion = 1

    static let maxPayloadBytes = 256 * 1024
    /// Base64 of the payload plus the small envelope fields.
    static let maxEnvelopeBytes = 360 * 1024
    static let maxIdentities = 64
    static let maxAdvisoriesPerIdentity = 64
    static let maxStringBytes = 512
    static let maxIdsPerAdvisory = 16
    static let maxCoverageRows = 512
    static let maxDeclaredEcosystems = 64
    static let maxSourcesPerEcosystem = 8
    static let maxEventsPerRange = 64
    static let maxRangesPerAdvisory = 16
    static let maxVersionsPerAdvisory = 256
    static let maxFixedLines = 16
    static let maxBinaries = 64
    static let maxValidity: TimeInterval = 72 * 3600
    static let futureSkew: TimeInterval = 3600
    static let coverageFreshness: TimeInterval = 48 * 3600
    static let maxSequence = 1 << 53
    static let idPattern = ReleaseSecurity.idPattern
    /// Names inside identities (source packages, formulae, tokens, vendors):
    /// conservative printable subset; they are never used in commands (the
    /// command is built from the LOCAL package database).
    static let namePattern = "^[A-Za-z0-9][A-Za-z0-9@+._:/-]{0,127}$"

    // MARK: - Model

    enum IdentityKind: String, Codable { case deb, brew, cask, vendor }

    /// One watched identity (§9.5.3 `entries[]` key). `key` is the canonical
    /// string used by coverage rows, the localvuln table and display.
    struct Identity: Hashable, Codable {
        var kind: IdentityKind
        var distro: String? = nil      // deb: debian | ubuntu
        var release: String? = nil     // deb: VERSION_ID ("12", "24.04")
        var source: String? = nil      // deb: SOURCE package
        var tap: String? = nil         // brew
        var formula: String? = nil     // brew
        var versionScheme: Int? = nil  // brew
        var token: String? = nil       // cask
        var vendor: String? = nil      // vendor build
        var product: String? = nil
        var platform: String? = nil
        var flavour: String? = nil

        var key: String {
            switch kind {
            case .deb: return "deb:\(distro ?? "?"):\(release ?? "?"):\(source ?? "?")"
            case .brew: return "brew:\(tap ?? "?"):\(formula ?? "?"):\(versionScheme ?? 0)"
            case .cask: return "cask:\(token ?? "?")"
            case .vendor: return "vendor:\(vendor ?? "?"):\(product ?? "?"):\(platform ?? "?"):\(flavour ?? "?")"
            }
        }

        /// The ecosystem whose declared sources an identity must have fresh
        /// coverage for (§9.5.3 "every source the list declares for its
        /// ecosystem").
        var ecosystemKey: String {
            switch kind {
            case .deb: return "deb:\(distro ?? "?"):\(release ?? "?")"
            case .brew: return "brew:\(tap ?? "?")"
            case .cask: return "cask"
            case .vendor: return "vendor:\(vendor ?? "?"):\(product ?? "?")"
            }
        }
    }

    enum CoverageStatus: String, Codable { case ok, failed, notCovered = "not-covered", partial }

    struct CoverageRow: Codable, Equatable {
        var identity: String
        var source: String
        /// nil = a status value this client does not know (treated as not ok).
        var status: CoverageStatus?
        var checkedAt: Date
    }

    enum EventKind: String, Codable { case introduced, fixed, lastAffected = "last_affected", limit }

    struct Event: Codable, Equatable {
        var kind: EventKind
        var version: String
    }

    /// One OSV-style range: its `type` and events. A type or event this
    /// client does not support makes the advisory unknown.
    struct Range: Codable, Equatable {
        var type: String
        var events: [Event]
        var unsupported: Bool
    }

    /// OSV applicability: the UNION of every range and every explicitly
    /// listed version (a version is affected if any range contains it or it
    /// is listed). `unknown` when the source gives neither.
    struct Affected: Codable, Equatable {
        var ranges: [Range]
        var versions: [String]
        var unknown: Bool

        static let unknownValue = Affected(ranges: [], versions: [], unknown: true)
        static func ranges(_ r: [Range]) -> Affected { Affected(ranges: r, versions: [], unknown: false) }
        static func versions(_ v: [String]) -> Affected { Affected(ranges: [], versions: v, unknown: false) }
    }

    enum Pocket: String, Codable { case archive, esmInfra = "esm-infra", esmApps = "esm-apps" }

    struct FixedVersion: Codable, Equatable {
        /// Release line ("20" for Node 20.x); nil = applies to every line.
        var line: String?
        var version: String
    }

    struct Remediation: Codable, Equatable {
        var fixed: [FixedVersion]
        var pocket: Pocket?
    }

    enum NoFixReason: String, Codable {
        case noDsa = "no-dsa", postponed, willNotFix = "will-not-fix", notYet = "not-yet", unknown
    }

    struct Advisory: Codable, Equatable {
        var ids: [String]
        var severity: ReleaseSecurity.Level
        var kev: Bool
        var kevAdded: String?
        var affected: Affected
        var remediation: Remediation?
        var noFixReason: NoFixReason?
        var binaries: [String]?
        var withdrawn: Bool

        var primaryId: String {
            ids.first(where: { $0.hasPrefix("CVE-") }) ?? ids.first ?? "?"
        }
    }

    struct Entry: Codable, Equatable {
        var identity: Identity
        /// deb | brew | semver | dotted; anything else → every advisory of
        /// the entry is unknown (unsupported comparator).
        var scheme: String
        var advisories: [Advisory]
    }

    struct Document: Codable, Equatable {
        var schema: Int
        var sequence: Int
        var published: Date
        var expires: Date
        /// ecosystemKey → declared source IDs (set).
        var declared: [String: [String]]
        var coverage: [CoverageRow]
        var entries: [Entry]

        func entry(for key: String) -> Entry? { entries.first { $0.identity.key == key } }
    }

    struct Verified: Equatable {
        var document: Document
        var payload: Data
        /// SHA-256 of the exact signed payload bytes: a same-sequence
        /// document with any other bytes is a conflict (§9.5.3).
        var contentId: String
        var keyId: String
    }

    struct Invalid: Error, LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }
}

// MARK: - Keys and policy

/// One pinned Ed25519 advisory-list key.
struct AdvisoryKey: Equatable {
    let keyId: String
    let publicKey: Data
}

enum AdvisoryKeys {
    /// Marked placeholder: NOT a key. No signature can verify against it, and
    /// `isProvisioned` is false while it is the only entry, so the client
    /// makes no request and reports the check as not yet available. The
    /// owner-approved provisioning replaces this block (key ID + 64 hex).
    // ADVISORY-KEYS-BEGIN — edited only by the advisory key provisioning
    static let pinnedKeyHex: [(keyId: String, publicKeyHex: String)] = [
        (keyId: placeholderKeyId, publicKeyHex: String(repeating: "0", count: 64)),
    ]
    // ADVISORY-KEYS-END
    static let placeholderKeyId = "PLACEHOLDER-advisory-key-not-provisioned"

    static func parse(keyId: String, hex: String) -> AdvisoryKey? {
        guard keyId != placeholderKeyId, let data = hexData(hex), data.count == 32,
              keyId.range(of: "^briglia-advisories-v[0-9]+-[0-9a-f]{16}$", options: .regularExpression) != nil
        else { return nil }
        return AdvisoryKey(keyId: keyId, publicKey: data)
    }

    static let active: [AdvisoryKey] = pinnedKeyHex.compactMap { parse(keyId: $0.keyId, hex: $0.publicKeyHex) }

    static func hexData(_ hex: String) -> Data? {
        let h = hex.lowercased()
        guard h.count % 2 == 0, h.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []
        var i = h.startIndex
        while i < h.endIndex {
            let n = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<n], radix: 16) else { return nil }
            bytes.append(b)
            i = n
        }
        return Data(bytes)
    }
}

struct AdvisoryPolicy {
    let keys: [AdvisoryKey]
    let domain: String
    let url: URL

    static let productionURL = URL(string: "https://briglia.dev/advisories/v1/local-tools.sig.json")!

    /// Placeholder-only key set: the feature is not available yet.
    var isProvisioned: Bool { !keys.isEmpty }

    /// Trust domain of the observation record (key set + domain string).
    var trustDomain: String {
        let ids = keys.map(\.keyId).sorted().joined(separator: ",")
        return ReleaseSecurity.hex(SHA256.hash(data: Data(ids.utf8))).prefix(16) + "|" + domain
    }

    static let production = AdvisoryPolicy(keys: AdvisoryKeys.active, domain: LocalAdvisory.domainString,
                                           url: productionURL)

    /// Live policy. ONLY a "-dev" build honours the test overrides
    /// (BRIGLIA_ADVISORY_TEST_KEY "keyId:64hex", BRIGLIA_ADVISORY_URL), the
    /// same gate the release channel uses: stamped releases always use the
    /// compiled key set and URL.
    static var effective: AdvisoryPolicy {
        guard adaCLIVersion.hasSuffix("-dev") else { return .production }
        let env = ProcessInfo.processInfo.environment
        var keys = AdvisoryKeys.active
        if let spec = env["BRIGLIA_ADVISORY_TEST_KEY"] {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let k = AdvisoryKeys.parse(keyId: parts[0], hex: parts[1]) { keys = [k] }
        }
        let url = env["BRIGLIA_ADVISORY_URL"].flatMap(URL.init(string:)) ?? productionURL
        return AdvisoryPolicy(keys: keys, domain: LocalAdvisory.domainString, url: url)
    }
}

// MARK: - Verification

extension LocalAdvisory {
    private struct Envelope: Decodable {
        let format: String
        let domain: String
        let keyId: String
        let payload: String
        let signature: String
    }

    static func signatureInput(domain: String, keyId: String, payload: Data) -> Data {
        var input = Data("\(envelopeFormat)\0\(domain)\0\(keyId)\0".utf8)
        input.append(payload)
        return input
    }

    /// Envelope → authenticated, validated document. Every rule of §9.5.3's
    /// "Client verification" that does not need the observation record is
    /// here: pinned key + domain, signature, payload bounds, schema,
    /// `expires - published ≤ 72 h` (enforced by the verifier), `published ≤
    /// now + 1 h`, not expired, sequence in [0, 2^53), structural limits.
    static func verify(_ raw: Data, policy: AdvisoryPolicy, now: Date) throws -> Verified {
        guard policy.isProvisioned else { throw Invalid(reason: "the advisory-list key is not provisioned in this build") }
        guard raw.count <= maxEnvelopeBytes else { throw Invalid(reason: "envelope is \(raw.count) bytes") }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: raw) else {
            throw Invalid(reason: "not an advisory envelope")
        }
        guard env.format == envelopeFormat else { throw Invalid(reason: "unsupported envelope format") }
        guard env.domain == policy.domain else { throw Invalid(reason: "wrong domain") }
        guard let key = policy.keys.first(where: { $0.keyId == env.keyId }) else {
            throw Invalid(reason: "unknown key \(env.keyId.prefix(64))")
        }
        let signature: Data, payload: Data
        do {
            signature = try ReleaseSigning.strictBase64(env.signature, field: "signature")
            payload = try ReleaseSigning.strictBase64(env.payload, field: "payload")
        } catch {
            throw Invalid(reason: "envelope fields are not canonical base64")
        }
        guard signature.count == 64 else { throw Invalid(reason: "signature is not 64 bytes") }
        guard payload.count <= maxPayloadBytes else { throw Invalid(reason: "payload is \(payload.count) bytes (limit \(maxPayloadBytes))") }
        let message = signatureInput(domain: env.domain, keyId: env.keyId, payload: payload)
        guard ReleaseSigning.ed25519Verify(publicKey: key.publicKey, signature: signature, message: message) else {
            throw Invalid(reason: "bad signature")
        }
        let doc = try parseDocument(payload)
        guard doc.expires.timeIntervalSince(doc.published) <= maxValidity else {
            throw Invalid(reason: "validity longer than 72 h")
        }
        guard doc.expires > doc.published else { throw Invalid(reason: "expires before published") }
        guard doc.published <= now.addingTimeInterval(futureSkew) else { throw Invalid(reason: "published in the future") }
        guard doc.expires > now else { throw Invalid(reason: "expired") }
        return Verified(document: doc, payload: payload,
                        contentId: ReleaseSecurity.hex(SHA256.hash(data: payload)), keyId: env.keyId)
    }
}
