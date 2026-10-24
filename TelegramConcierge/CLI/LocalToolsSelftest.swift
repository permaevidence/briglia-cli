import ArgumentParser
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The known-vulnerability check of the user's own tools (security plan v16
/// §9.5, §15 items 15-16): list verification and the observation record,
/// comparators and ranges, coverage incl. F3 trimming, remediation and
/// candidates, the read-only inventory parsers and fake-machine inventories,
/// the V4/V5 send-once rules, delivery (one attempt, consume first, retry
/// only after a proven refusal), the service against a fake channel, the
/// toolchain input, and wording. Hermetic: fake clock, temp directories,
/// fake probes and transports. Groups live in `LocalToolsSelftest+*.swift`
/// (small functions: the Linux CI frontend runs out of memory on huge ones).
struct LocalToolsSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__local-tools-selftest",
        abstract: "Internal: verify the local-tools known-vulnerability check.",
        shouldDisplay: false)

    @Option(help: "Run only groups whose name contains this.") var only: String?

    typealias Tally = UpdateNoticeSelftest.Tally

    @MainActor
    func run() async throws {
        let t = Tally()
        let groups: [(String, (Tally) -> Void)] = [
            ("verify", Self.verifyGroup),
            ("parse", Self.parseGroup),
            ("observation", Self.observationGroup),
            ("version", Self.versionGroup),
            ("ranges", Self.rangesGroup),
            ("coverage", Self.coverageGroup),
            ("remediation", Self.remediationGroup),
            ("parsers", Self.parsersGroup),
            ("inventory-deb", Self.debInventoryGroup),
            ("inventory-mac", Self.macInventoryGroup),
            ("rules", Self.rulesGroup),
            ("wording", Self.wordingGroup),
            ("toolchain", Self.toolchainGroup),
            ("store", Self.storeGroup),
            ("mac-updates-rules", Self.macUpdatesRulesGroup),
            ("mac-updates-evaluate", Self.macUpdatesEvaluationGroup),
            ("mac-updates-wording", Self.macUpdatesWordingGroup),
            ("vendor-node", Self.vendorNodeGroup),
            ("node-list", Self.nodeListGroup),
            ("libreoffice-list", Self.libreOfficeListGroup),
            ("impl-round1", Self.implRound1Group),
            ("deb-floor", Self.debFloorGroup),
        ]
        for (name, run) in groups where only.map({ name.contains($0) }) ?? true {
            print("— \(name) —")
            run(t)
        }
        if only.map({ "service".contains($0) }) ?? true {
            print("— service —")
            await Self.serviceGroup(t)
        }
        if only.map({ "mac-updates-service".contains($0) }) ?? true {
            print("— mac-updates-service —")
            await Self.macUpdatesServiceGroup(t)
        }
        print(t.failures == 0 ? "\nALL \(t.total) LOCAL TOOLS CHECKS PASSED" : "\n\(t.failures) of \(t.total) FAILED")
        if t.failures > 0 { throw ExitCode(1) }
    }
}

/// Fixture builders (synthetic data only: test keys from fixed seeds,
/// made-up advisory IDs in the CVE-2099 range).
enum LTF {
    static let now = Date(timeIntervalSince1970: 1_792_800_000)   // 2026-10-24
    static let seed = Data(repeating: 0x22, count: 32)
    static let otherSeed = Data(repeating: 0x33, count: 32)

    static func signer(_ seed: Data = seed) -> (Curve25519.Signing.PrivateKey, AdvisoryKey) {
        let k = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let pub = k.publicKey.rawRepresentation
        let id = "briglia-advisories-v1-" + ReleaseSecurity.hex(SHA256.hash(data: pub)).prefix(16)
        return (k, AdvisoryKey(keyId: String(id), publicKey: pub))
    }

    static var policy: AdvisoryPolicy {
        AdvisoryPolicy(keys: [signer().1], domain: LocalAdvisory.domainString, url: URL(string: "http://127.0.0.1:9/list.sig.json")!)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func nn(_ s: String?) -> Any { s.map { $0 as Any } ?? NSNull() }

    static let debian12 = ["deb:debian:12": ["osv:Debian:12", "cisa-kev"]]

    static func cov(_ identity: String, _ source: String, _ status: String = "ok", _ at: Date = now) -> [String: Any] {
        ["identity": identity, "source": source, "status": status, "checkedAt": iso(at)]
    }

    static func covAll(_ identity: String, sources: [String] = ["osv:Debian:12", "cisa-kev"], status: String = "ok", at: Date = now) -> [[String: Any]] {
        sources.map { cov(identity, $0, status, at) }
    }

    static func adv(_ ids: [String], severity: String = "recommended", kev: Bool = false,
                    events: [[String: String]]? = [["introduced": "0"], ["fixed": "7:5.1.7-0+deb12u1"]],
                    fixed: String? = "7:5.1.7-0+deb12u1", lines: [(String?, String)]? = nil,
                    pocket: String? = nil, noFix: String? = nil, withdrawn: Bool = false,
                    affected: Any? = nil) -> [String: Any] {
        var a: [String: Any] = ["ids": ids, "severity": severity, "kev": kev, "withdrawn": withdrawn]
        if let affected { a["affected"] = affected }
        else if let events { a["affected"] = ["ranges": [["type": "ECOSYSTEM", "events": events]]] }
        else { a["affected"] = "unknown" }
        if let lines {
            a["remediation"] = ["fixed": lines.map { ["line": nn($0.0), "version": $0.1] }, "pocket": nn(pocket)]
        } else if let fixed {
            a["remediation"] = ["fixed": [["line": NSNull(), "version": fixed]], "pocket": nn(pocket)]
        } else {
            a["remediation"] = NSNull()
            a["noFixReason"] = noFix ?? "not-yet"
        }
        return a
    }

    static func debEntry(scheme: String = "deb", _ advisories: [[String: Any]]) -> [String: Any] {
        debEntry("ffmpeg", scheme: scheme, advisories)
    }

    static func debEntry(_ source: String, release: String = "12", distro: String = "debian",
                         scheme: String = "deb", _ advisories: [[String: Any]]) -> [String: Any] {
        ["identity": ["kind": "deb", "distro": distro, "release": release, "source": source],
         "scheme": scheme, "advisories": advisories]
    }

    static func payload(seq: Int = 100, published: Date = now.addingTimeInterval(-3600), validity: TimeInterval = 72 * 3600,
                        declared: [String: [String]] = debian12, coverage: [[String: Any]], entries: [[String: Any]],
                        extra: [String: Any] = [:]) -> Data {
        var o: [String: Any] = [
            "schema": 1, "sequence": seq, "published": iso(published), "expires": iso(published.addingTimeInterval(validity)),
            "declared": declared.map { ["ecosystem": $0.key, "sources": $0.value] }.sorted { "\($0["ecosystem"]!)" < "\($1["ecosystem"]!)" },
            "coverage": coverage, "entries": entries,
        ]
        for (k, v) in extra { o[k] = v }
        return try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    static func envelope(_ payload: Data, seed: Data = seed, domain: String = LocalAdvisory.domainString,
                         format: String = LocalAdvisory.envelopeFormat, tamper: Bool = false) -> Data {
        let (k, key) = signer(seed)
        var sig = try! k.signature(for: LocalAdvisory.signatureInput(domain: domain, keyId: key.keyId, payload: payload))
        if tamper { sig[0] ^= 0x01 }
        let env = ["format": format, "domain": domain, "keyId": key.keyId,
                   "payload": payload.base64EncodedString(), "signature": sig.base64EncodedString()]
        return try! JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])
    }

    static func doc(_ payload: Data) -> LocalAdvisory.Document { try! LocalAdvisory.parseDocument(payload) }

    static func verified(_ payload: Data) -> LocalAdvisory.Verified {
        try! LocalAdvisory.verify(envelope(payload), policy: policy, now: now)
    }

    /// A Debian 12 ffmpeg instance (binNMU-free), with a candidate.
    static func debInstance(tool: String = "ffmpeg", source: String = "ffmpeg", version: String = "7:5.1.6-0+deb12u1",
                            sourceVersion: String? = nil, release: String = "12", distro: String = "debian",
                            candidate: String? = "7:5.1.7-0+deb12u1", candidateSource: String? = nil,
                            candidateSourceName: String? = nil,
                            pocket: LocalAdvisory.Pocket? = .archive, originProblem: LocalTools.Text? = nil,
                            binaries: [String]? = nil, asOf: Date = now, problem: LocalTools.Text? = nil) -> LocalTools.Instance {
        let bins = binaries ?? [tool, "libavcodec59"]
        let cands = candidate.map { c in
            bins.map { LocalTools.DebCandidate(binary: $0, version: c, sourceName: candidateSourceName ?? source,
                                               sourceVersion: candidateSource ?? c, originOK: pocket != nil, pocket: pocket) }
        } ?? []
        return LocalTools.Instance(toolId: tool, identity: LocalAdvisory.Identity(kind: .deb, distro: distro, release: release, source: source),
                                   installedVersion: version, compareVersion: sourceVersion ?? version, originProblem: originProblem,
                                   binaries: bins, candidates: .deb(list: cands, asOf: asOf, problem: problem),
                                   usedPath: "/usr/bin/\(tool)", statusOnly: nil)
    }

    static func listFor(_ entries: [[String: Any]], identities: [String] = ["deb:debian:12:ffmpeg"],
                        status: String = "ok") -> LocalAdvisory.Document {
        doc(payload(coverage: identities.flatMap { covAll($0, status: status) }, entries: entries))
    }

    static func tempDir(_ name: String) -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lt-selftest-\(name)-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func paths(_ root: URL) -> LocalAdvisoryStore.Paths {
        .under(UpdateNoticeStore.Paths(setting: root.appendingPathComponent("config/update-check.json"),
                                       lock: root.appendingPathComponent("config/update-check.lock"),
                                       state: root.appendingPathComponent("data/update/notice.json")))
    }
}
