import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// §4.1–§4.3, §15 items 2 and 7 (client side): conservative parsing,
/// transitive merge with the 16-ID cap after merging, classification, and
/// a manifest whose security block is invalid still verifying and still
/// `available` for `/upgrade`.
extension UpdateNoticeSelftest {
    static let testPrefix = "https://example.invalid/v{version}/"

    static func manifestJSON(seq: Int, version: String? = nil, security: Any? = nil, components: Any? = nil,
                             published: String = "2027-01-01T00:00:00Z", expires: String = "2027-06-30T00:00:00Z") -> Data {
        let v = version ?? "0.3.\(seq)"
        var m: [String: Any] = [
            "schema": 1, "channel": "briglia-cli", "sequence": seq, "version": v,
            "published": published, "expires": expires,
            "platforms": ["macos-arm64": ["url": "https://example.invalid/v\(v)/briglia-macos-arm64.tar.gz",
                                          "sha256": String(repeating: "a", count: 64), "size": 10],
                          "linux-x64": ["url": "https://example.invalid/v\(v)/briglia-linux-x64.tar.gz",
                                        "sha256": String(repeating: "b", count: 64), "size": 10],
                          "linux-arm64": ["url": "https://example.invalid/v\(v)/briglia-linux-arm64.tar.gz",
                                          "sha256": String(repeating: "c", count: 64), "size": 10]],
        ]
        if let security { m["security"] = security }
        if let components { m["componentAdvisories"] = components }
        return try! JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])
    }

    static func secJSON(_ entries: [[String: Any]], floorR: Int = 0, floorC: Int = 0, summary: String? = nil) -> [String: Any] {
        var s: [String: Any] = ["cumulative": entries, "securityFloor": ["recommended": floorR, "critical": floorC]]
        if let summary { s["summary"] = summary }
        return s
    }

    static func cve(_ id: String, aliases: [String] = [], level: String = "recommended", from: Any = 101, fixed: Any = 120) -> [String: Any] {
        ["id": id, "aliases": aliases, "level": level, "affectsFromSequence": from, "fixedInSequence": fixed]
    }

    static func parsed(_ seq: Int, _ security: Any) -> ReleaseSecurity.Parsed {
        ReleaseSecurity.parse(payload: manifestJSON(seq: seq, security: security), sequence: seq).security
    }

    static func isUnknown(_ p: ReleaseSecurity.Parsed) -> Bool { if case .unknown = p { return true }; return false }

    static func metadataGroup(_ t: Tally) {
        metadataValid(t)
        metadataInvalid(t)
        metadataMerge(t)
        metadataComponents(t)
        metadataContentId(t)
        metadataUpgradeUnaffected(t)
    }

    static func metadataValid(_ t: Tally) {
        let p = parsed(121, secJSON([cve("CVE-2026-1", aliases: ["ghsa-aaaa-bbbb-cccc"], fixed: 120)], floorR: 110, floorC: 100, summary: "Fixes a TLS issue"))
        guard case .known(let b) = p else { return t.check("valid security block parses", false, "\(p)") }
        t.check("valid security block parses; IDs upper-cased, id first", b.cumulative.first?.ids == ["CVE-2026-1", "GHSA-AAAA-BBBB-CCCC"], "\(b)")
        t.check("floors and summary parsed", b.floorRecommended == 110 && b.floorCritical == 100 && b.summary == "Fixes a TLS issue")
        let absent = ReleaseSecurity.parse(payload: manifestJSON(seq: 121), sequence: 121).security
        t.check("manifest without security → absent (none known, never a claim)", absent == .absent)
        t.check("absent classifies as noneKnown", ReleaseSecurity.classify(absent, installed: 100) == .noneKnown)
    }

    static func metadataInvalid(_ t: Tally) {
        let cases: [(String, Any)] = [
            ("security not an object", "x"),
            ("unknown level enum", secJSON([cve("CVE-2026-1", level: "urgent")])),
            ("negative sequence", secJSON([cve("CVE-2026-1", from: -1)])),
            ("sequence ≥ 2^53", secJSON([cve("CVE-2026-1", fixed: 9_007_199_254_740_992)])),
            ("fixedIn above the release", secJSON([cve("CVE-2026-1", fixed: 122)])),
            ("affectsFrom ≥ fixedIn", secJSON([cve("CVE-2026-1", from: 120, fixed: 120)])),
            ("floor above the release", secJSON([], floorR: 122)),
            ("boolean as a sequence", secJSON([cve("CVE-2026-1", fixed: true)])),
            ("fractional sequence", secJSON([cve("CVE-2026-1", fixed: 110.5)])),
            ("bad ID pattern", secJSON([cve("-bad id")])),
            ("unknown field in an entry", secJSON([cve("CVE-2026-1").merging(["extra": 1]) { a, _ in a }])),
            ("more than 64 entries", secJSON((0..<65).map { cve("CVE-2026-\(1000 + $0)") })),
            ("17 IDs in one entry", secJSON([cve("CVE-2026-1", aliases: (0..<16).map { "GHSA-x\($0)" })])),
            ("summary over 200 bytes", secJSON([], summary: String(repeating: "x", count: 201))),
            ("securityFloor missing", ["cumulative": [] as [Any]]),
        ]
        for (label, security) in cases {
            let p = parsed(121, security)
            t.check("invalid security (\(label)) → unknown", isUnknown(p), "\(p)")
        }
        t.check("unknown classifies as unknown (plain notice + attention, never a claim)",
                ReleaseSecurity.classify(.unknown("x"), installed: 100) == .unknown)
    }

    static func metadataMerge(_ t: Tally) {
        let ten1 = (0..<9).map { "GHSA-a\($0)" }, ten2 = (0..<9).map { "GHSA-b\($0)" }
        let p = parsed(121, secJSON([cve("CVE-2026-1", aliases: ten1), cve("CVE-2026-1", aliases: ten2)]))
        t.check("two 10-ID entries overlapping in one ID (19-ID union) → unknown, never truncated", isUnknown(p), "\(p)")
        let chain = parsed(121, secJSON([cve("CVE-2026-1", aliases: ["GHSA-AB"], fixed: 110),
                                         cve("GHSA-AB", aliases: ["GHSA-BC"], level: "critical", fixed: 115),
                                         cve("GHSA-BC", from: 90, fixed: 112)]))
        if case .known(let b) = chain {
            t.check("chain A∩B, B∩C (A∩C empty) → one entry", b.cumulative.count == 1, "\(b.cumulative)")
            t.check("merged entry: highest level, widest range", b.cumulative.first.map { $0.level == .critical && $0.affectsFrom == 90 && $0.fixedIn == 115 } ?? false)
        } else {
            t.check("chain merge parses", false, "\(chain)")
        }
    }

    static func metadataComponents(_ t: Tally) {
        let good: [String: Any] = ["ecosystem": "deb", "identity": ["distro": "ubuntu", "release": "noble", "arch": "arm64", "sourcePackage": "ffmpeg"],
                                   "minimumSafe": "7:6.1.1-3ubuntu5.2", "advisories": ["USN-1234-1", "CVE-2026-9"], "level": "recommended"]
        var bad = good; bad["extra"] = true
        var noIdentity = good; noIdentity["identity"] = ["distro": "ubuntu"]
        let r = ReleaseSecurity.parse(payload: manifestJSON(seq: 121, components: [good, bad, noIdentity]), sequence: 121)
        t.check("componentAdvisories: valid entry kept, problem entries counted unknown",
                r.components.entries.count == 1 && r.components.unknownEntries == 2 && !r.components.invalid, "\(r.components)")
        t.check("componentAdvisories problems leave the security block alone", r.security == .absent)
        let notList = ReleaseSecurity.parse(payload: manifestJSON(seq: 121, components: "x"), sequence: 121)
        t.check("componentAdvisories not a list → invalid", notList.components.invalid)
    }

    static func metadataContentId(_ t: Tally) {
        let a = ReleaseSecurity.contentId(payload: manifestJSON(seq: 121, published: "2027-01-01T00:00:00Z", expires: "2027-06-30T00:00:00Z"))
        let b = ReleaseSecurity.contentId(payload: manifestJSON(seq: 121, published: "2027-02-01T00:00:00Z", expires: "2027-08-30T00:00:00Z"))
        let c = ReleaseSecurity.contentId(payload: manifestJSON(seq: 121, security: secJSON([])))
        t.check("contentId ignores published/expires (renewal = same content)", a != nil && a == b)
        t.check("contentId changes with the content", a != c)
        let s = ReleaseSecurity.plainSummary("Fix **TLS**\u{0007} <b>now</b>\n[link](x)")
        t.check("summary: control characters and markup stripped", s == "Fix TLS bnow/b link(x)", s ?? "nil")
    }

    static var testKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    }

    static var testPolicy: ReleasePolicy {
        let pub = testKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return ReleasePolicy(keys: [ReleaseKey(keyId: "briglia-cli-release-v1-test", publicKeyHex: pub)!],
                             channel: "briglia-cli", artifactURLPrefix: testPrefix)
    }

    static func envelope(_ payload: Data) -> Data {
        let keyId = "briglia-cli-release-v1-test"
        let sig = try! testKey.signature(for: ReleaseSigning.domainInput(channel: "briglia-cli", keyId: keyId, payload: payload))
        let env: [String: String] = ["format": ReleaseSigning.formatName, "channel": "briglia-cli", "keyId": keyId,
                                     "payload": payload.base64EncodedString(), "signature": sig.base64EncodedString()]
        return try! JSONSerialization.data(withJSONObject: env)
    }

    static func metadataUpgradeUnaffected(_ t: Tally) {
        let now = ISO8601DateFormatter().date(from: "2027-02-01T00:00:00Z")!
        let payload = manifestJSON(seq: 121, security: secJSON([cve("CVE-2026-1", level: "urgent")]))
        do {
            let m = try ReleaseSigning.verifyEnvelope(envelope(payload), policy: testPolicy, now: now)
            t.check("invalid security block: the manifest still verifies", m.sequence == 121)
            let d = UpgradeService.decide(manifest: m, installedVersion: "0.3.119", ownSequence: 119, persistedSequence: nil, platform: "linux-x64")
            if case .available = d { t.check("…and /upgrade's decision is unchanged (available)", true) }
            else { t.check("…and /upgrade's decision is unchanged (available)", false, "\(d)") }
            t.check("verified manifest exposes its payload bytes for the separate parse", m.payload == payload)
        } catch {
            t.check("invalid security block: the manifest still verifies", false, "\(error)")
        }
    }

    // MARK: - Classification (§4.3, §15 item 2)

    static func classificationGroup(_ t: Tally) {
        // installed 119, 120 fixes a CVE, 121 is feature-only and carries it.
        let carried = parsed(121, secJSON([cve("CVE-2026-1", from: 101, fixed: 120)]))
        t.check("skipped version: 121 carries 120's fix → recommended for 119", ReleaseSecurity.classify(carried, installed: 119) == .recommended)
        t.check("…and none for 120", ReleaseSecurity.classify(carried, installed: 120) == .none)
        let floors = parsed(121, secJSON([], floorR: 118, floorC: 110))
        t.check("below securityFloor.recommended → recommended", ReleaseSecurity.classify(floors, installed: 115) == .recommended)
        t.check("below securityFloor.critical → critical", ReleaseSecurity.classify(floors, installed: 105) == .critical)
        t.check("above both floors → none", ReleaseSecurity.classify(floors, installed: 118) == .none)
        let crit = parsed(121, secJSON([cve("CVE-2026-2", level: "critical", fixed: 121)]))
        t.check("critical entry → critical", ReleaseSecurity.classify(crit, installed: 119) == .critical)
    }
}
