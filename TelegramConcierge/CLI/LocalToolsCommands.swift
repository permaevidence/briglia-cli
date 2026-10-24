import ArgumentParser
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Development-build-only drivers for the local-tools check (security plan
/// v16 §9.5): test signing, the client's parse (cross-language parity with
/// the publisher), a read-only inventory dump, and one fetch + evaluation +
/// delivery pass against a test channel. Every one refuses in stamped
/// release builds; the stateful one also refuses without isolated XDG roots.
struct TestSignAdvisoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__test-sign-advisory",
        abstract: "Sign an advisory-list payload with a throwaway test key (development builds only).",
        shouldDisplay: false)

    @Argument var payloadPath: String
    @Argument var outputPath: String
    @Option(help: "64 hex chars deterministic key seed.") var seedHex: String
    @Option(help: "Override the domain string (tests of the domain check).") var domain: String = LocalAdvisory.domainString

    func run() throws {
        guard adaCLIVersion.hasSuffix("-dev") else { print("✖ development builds only"); throw ExitCode(2) }
        guard let seed = AdvisoryKeys.hexData(seedHex), seed.count == 32 else { print("✖ --seed-hex must be 64 hex characters"); throw ExitCode(2) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let pub = key.publicKey.rawRepresentation
        let keyId = "briglia-advisories-v1-" + ReleaseSecurity.hex(SHA256.hash(data: pub)).prefix(16)
        let payload = try Data(contentsOf: URL(fileURLWithPath: payloadPath))
        let sig = try key.signature(for: LocalAdvisory.signatureInput(domain: domain, keyId: keyId, payload: payload))
        let env: [String: String] = ["format": LocalAdvisory.envelopeFormat, "domain": domain, "keyId": keyId,
                                     "payload": payload.base64EncodedString(), "signature": sig.base64EncodedString()]
        try JSONSerialization.data(withJSONObject: env, options: [.sortedKeys]).write(to: URL(fileURLWithPath: outputPath))
        print("keyId=\(keyId)")
        print("publicKeyHex=\(ReleaseSecurity.hex(pub))")
    }
}

struct AdvisoryListParseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__advisory-list-parse",
        abstract: "Print the client's verification/parse of an advisory list (development builds only).",
        shouldDisplay: false)

    @Argument var path: String
    @Flag(help: "The file is a bare payload (no envelope, no signature).") var payload = false
    @Option(help: "Fixed clock, seconds since 1970.") var now: Double?

    func run() throws {
        guard adaCLIVersion.hasSuffix("-dev") else { print("✖ development builds only"); throw ExitCode(2) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let clock = now.map { Date(timeIntervalSince1970: $0) } ?? Date()
        var out: [String: Any] = [:]
        do {
            let doc = payload ? try LocalAdvisory.parseDocument(data)
                              : try LocalAdvisory.verify(data, policy: .effective, now: clock).document
            out["ok"] = true
            out["sequence"] = doc.sequence
            out["identities"] = doc.entries.map(\.identity.key)
            out["advisories"] = doc.entries.reduce(0) { $0 + $1.advisories.count }
            out["coverage"] = doc.coverage.count
            out["declared"] = doc.declared.keys.sorted()
        } catch {
            out["ok"] = false
            out["reason"] = error.localizedDescription
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
    }
}

/// Read-only: what the inventory sees on this machine (no state is read or
/// written, nothing is fetched).
struct LocalToolsInventoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__local-tools-inventory",
        abstract: "Print the read-only local-tools inventory of this machine (development builds only).",
        shouldDisplay: false)

    func run() throws {
        guard adaCLIVersion.hasSuffix("-dev") else { print("✖ development builds only"); throw ExitCode(2) }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .secondsSince1970
        print(String(decoding: try e.encode(LocalTools.inventory(.live)), as: UTF8.self))
    }
}

/// One fetch (when due or forced) + evaluation + delivery pass against
/// BRIGLIA_ADVISORY_URL with BRIGLIA_ADVISORY_TEST_KEY, isolated XDG roots
/// required. `--fixture` replaces the live inventory with a JSON list of
/// resolutions (so the e2e test is deterministic); the transport prints
/// `NOTICE: <text>` and reports `--outcome`.
struct LocalToolsCheckOnceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__local-tools-check-once",
        abstract: "Run one local-tools fetch/evaluation/delivery pass (development builds only).",
        shouldDisplay: false)

    @Option(help: "Fixed clock, seconds since 1970.") var now: Double?
    @Option(help: "accepted | refused | ambiguous") var outcome: String = "accepted"
    @Option(help: "JSON file with [Resolution] replacing the live inventory.") var fixture: String?
    @Flag(help: "Do not fetch; evaluate and deliver only.") var noFetch = false

    @MainActor
    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else { print("✖ development builds only"); throw ExitCode(2) }
        let env = ProcessInfo.processInfo.environment
        guard env["BRIGLIA_ADVISORY_URL"] != nil, env["BRIGLIA_ADVISORY_TEST_KEY"] != nil,
              env["XDG_CONFIG_HOME"] != nil, env["XDG_DATA_HOME"] != nil else {
            print("✖ needs a test channel (BRIGLIA_ADVISORY_URL, BRIGLIA_ADVISORY_TEST_KEY) and isolated XDG_CONFIG_HOME/XDG_DATA_HOME")
            throw ExitCode(2)
        }
        let clock = now.map { Date(timeIntervalSince1970: $0) }
        let policy = AdvisoryPolicy.effective
        var resolutions: [LocalTools.Resolution]? = nil
        if let fixture {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .secondsSince1970
            resolutions = try d.decode([LocalTools.Resolution].self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
        }
        let wanted = outcome
        let service = LocalToolsService(deps: LocalToolsService.Deps(
            paths: .live, now: { clock ?? Date() }, policy: policy,
            fetch: { try await BoundedHTTP.fetchData(url: policy.url, maxBytes: LocalAdvisory.maxEnvelopeBytes, timeout: 30) },
            inventory: { if let r = resolutions { return r }; return LocalTools.inventory(.live) },
            language: { env["BRIGLIA_TEST_LANG"] ?? "en" }, isIdle: { true },
            destination: { UpdateNotice.Destination(channelKind: "telegram", chatId: "1", channelGeneration: 0) },
            channelGeneration: { _ in 0 },
            send: { _, _, _, text in
                print("NOTICE: \(text.replacingOccurrences(of: "\n", with: " | "))")
                switch wanted {
                case "refused": return .refused(retryAfter: 1)
                case "ambiguous": return .ambiguous
                default: return .accepted
                }
            },
            log: { print("log: \($0)") }))
        service.start()
        if !noFetch, service.fetchDue() { _ = await service.runFetch() }
        await service.evaluate()
        await service.deliver()
        let status = LocalToolsText.liveStatus(now: clock ?? Date())
        print("STATUS: \(status.part)")
        for r in status.reasons { print("ATTENTION: \(r.en)") }
        for d in status.details { print("DETAIL: \(d)") }
        print("FETCHES: \(service.fetchesStarted)")
    }
}

/// Dev-only: the client's comparator on pairs (`a b` per line on stdin) →
/// one result per line (-1, 0, 1, unknown). Lets the test suite cross-check
/// the native Debian ordering against `dpkg --compare-versions` on Linux.
struct LocalToolsVersionCompareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__local-tools-version-compare",
        abstract: "Compare version pairs with the local-tools comparator (development builds only).",
        shouldDisplay: false)

    @Option(help: "deb | brew | semver | dotted") var scheme: String = "deb"

    func run() throws {
        guard adaCLIVersion.hasSuffix("-dev") else { print("✖ development builds only"); throw ExitCode(2) }
        guard let s = LocalToolsVersion.Scheme(rawValue: scheme) else { print("✖ unknown scheme"); throw ExitCode(2) }
        while let line = readLine() {
            let p = line.split(separator: " ").map(String.init)
            guard p.count == 2 else { print("unknown"); continue }
            print(LocalToolsVersion.compare(p[0], p[1], scheme: s).map(String.init) ?? "unknown")
        }
    }
}
