import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The monotonic release sequence this source tree publishes as. It doubles
/// as this binary's anti-rollback floor: signed release metadata with a lower
/// sequence is never accepted, whatever its version string says. The release
/// workflow's authorize job checks that this constant, the tag, and the
/// stamped version agree, and that the sequence is strictly greater than the
/// last successfully released one. Bump it in the release-prep commit.
let adaCLIReleaseSequence = 81

/// The canonical release repository this binary trusts artifacts from. The
/// staging pipeline stamps its own repo here (STAMP-RELEASE-REPO); production
/// builds always carry the canonical value.
let adaCLIReleaseRepository = "permaevidence/briglia-cli" // STAMP-RELEASE-REPO

/// One pinned Ed25519 release-verification key.
struct ReleaseKey {
    let keyId: String
    let publicKey: Data // exactly 32 raw bytes

    init?(keyId: String, publicKeyHex: String) {
        let hex = publicKeyHex.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.keyId = keyId
        self.publicKey = Data(bytes)
    }
}

/// The pinned production release-key set. Clients trust a SET so key
/// rotation can overlap (ship v1+v2, then sign with v2, then retire v1).
enum ReleaseKeys {
    // STAMP-KEYS-BEGIN — edited only by the key ceremony (production key)
    static let pinnedKeyHex: [(keyId: String, publicKeyHex: String)] = [
        (keyId: "briglia-cli-release-v1-94d967bae0867c2e",
         publicKeyHex: "621031636aa2bb2edb64a58f2f72de7bc3559b08d717c79b4251f8b1e35b8a95"),
    ]
    // STAMP-KEYS-END

    static let active: [ReleaseKey] = pinnedKeyHex.compactMap {
        ReleaseKey(keyId: $0.keyId, publicKeyHex: $0.publicKeyHex)
    }
}

/// What the verifier accepts: keys, channel, and where artifacts are allowed
/// to live. Injectable so the selftest exercises every rule with test keys;
/// production callers use `.production`.
struct ReleasePolicy {
    let keys: [ReleaseKey]
    let channel: String
    /// Allowed artifact URL prefix with "{version}" substituted at check
    /// time. Everything a manifest points at must live under this prefix.
    let artifactURLPrefix: String

    /// The anti-rollback trust domain this policy's sequences belong to:
    /// channel + the pinned artifact location (which embeds the release
    /// repository). Sequences are compared only within one domain — see
    /// ReleaseTrustStore.
    var trustDomain: String { "\(channel)|\(artifactURLPrefix)" }

    static let production = ReleasePolicy(
        keys: ReleaseKeys.active,
        channel: "briglia-cli",
        artifactURLPrefix: "https://github.com/\(adaCLIReleaseRepository)/releases/download/v{version}/")

    /// The policy live checks use. Identical to `.production` in every
    /// stamped release build. ONLY a "-dev" source build (never stamped by
    /// the release pipeline — the authorize job verifies stamping) honors
    /// the smoke-test overrides, so the end-to-end upgrade tests can serve
    /// a signed mock channel: BRIGLIA_RELEASE_TEST_KEY ("keyId:64hex", replaces
    /// the pinned key set) and BRIGLIA_RELEASE_URL_PREFIX (replaces the artifact
    /// prefix template). This is deliberately NOT a runtime escape hatch in
    /// released binaries: the gate is the compiled version constant.
    static var effective: ReleasePolicy {
        guard adaCLIVersion.hasSuffix("-dev") else { return .production }
        let env = ProcessInfo.processInfo.environment
        var keys = ReleaseKeys.active
        if let spec = env["BRIGLIA_RELEASE_TEST_KEY"] {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let key = ReleaseKey(keyId: parts[0], publicKeyHex: parts[1]) {
                keys = [key]
            }
        }
        return ReleasePolicy(
            keys: keys,
            channel: "briglia-cli",
            artifactURLPrefix: env["BRIGLIA_RELEASE_URL_PREFIX"] ?? production.artifactURLPrefix)
    }
}

enum ReleaseVerifyError: Error, LocalizedError {
    case noPinnedKeys
    case envelopeTooLarge(Int)
    case malformedEnvelope(String)
    case unsupportedFormat(String)
    case wrongChannel(String)
    case unknownKey(String)
    case badSignature
    case payloadTooLarge(Int)
    case malformedManifest(String)
    case expired(String)
    case notYetValid(String)
    case badPlatformEntry(String)

    var errorDescription: String? {
        switch self {
        case .noPinnedKeys:
            return "this build carries no pinned release key — signed update checks are unavailable (development build)"
        case .envelopeTooLarge(let n):
            return "release envelope exceeds the \(ReleaseSigning.maxEnvelopeBytes)-byte limit (\(n) bytes) — refusing"
        case .malformedEnvelope(let why):
            return "malformed release envelope: \(why)"
        case .unsupportedFormat(let f):
            return "unsupported envelope format '\(f)'"
        case .wrongChannel(let c):
            return "envelope is for channel '\(c)', not this product's channel"
        case .unknownKey(let id):
            return "envelope signed by unknown key '\(id)' — not in this build's pinned key set"
        case .badSignature:
            return "release envelope signature is INVALID — refusing this metadata"
        case .payloadTooLarge(let n):
            return "release manifest exceeds the \(ReleaseSigning.maxPayloadBytes)-byte limit (\(n) bytes) — refusing"
        case .malformedManifest(let why):
            return "malformed release manifest: \(why)"
        case .expired(let when):
            return "release metadata expired \(when) — the release channel looks stale or frozen; not updating"
        case .notYetValid(let when):
            return "release metadata is published in the future (\(when)) — check this machine's clock; not updating"
        case .badPlatformEntry(let why):
            return "release manifest platform entry rejected: \(why)"
        }
    }
}

/// Verifies the signed release envelope (`manifest.sig.json`) exactly as
/// specified in docs/RELEASE_SIGNING_PLAN.md §5: strict structure, strict
/// canonical base64, domain-separated Ed25519 signature over
/// `"ada-release-envelope-v1\0" + channel + "\0" + keyId + "\0" + payload`,
/// then strict validation of the authenticated manifest payload. Every
/// failure is a distinct, actionable error; there is no fallback path.
enum ReleaseSigning {
    static let formatName = "ada-release-envelope-v1"
    static let maxEnvelopeBytes = 128 * 1024
    static let maxPayloadBytes = 64 * 1024
    /// Not-before tolerance for `published` (client clock skew allowance).
    static let clockSkewAllowance: TimeInterval = 24 * 3600
    /// Sanity ceiling for a single platform tarball.
    static let maxArtifactBytes: Int64 = 2 * 1024 * 1024 * 1024

    private struct Envelope: Decodable {
        let format: String
        let channel: String
        let keyId: String
        let payload: String
        let signature: String
    }

    struct Manifest {
        struct Platform {
            let url: String
            let sha256: String
            let size: Int64
        }
        let schema: Int
        let channel: String
        let sequence: Int
        let version: String
        let published: Date
        let expires: Date
        let platforms: [String: Platform]
    }

    private struct RawManifest: Decodable {
        struct RawPlatform: Decodable {
            let url: String
            let sha256: String
            let size: Int64
        }
        let schema: Int
        let channel: String
        let sequence: Int
        let version: String
        let published: String
        let expires: String
        let platforms: [String: RawPlatform]
    }

    /// Strict, canonical base64: decodes AND re-encodes to the identical
    /// string, so noncanonical trailing bits, whitespace, and length games
    /// are all rejected.
    static func strictBase64(_ string: String, field: String) throws -> Data {
        guard let data = Data(base64Encoded: string) else {
            throw ReleaseVerifyError.malformedEnvelope("field '\(field)' is not valid base64")
        }
        guard data.base64EncodedString() == string else {
            throw ReleaseVerifyError.malformedEnvelope("field '\(field)' is not canonical base64")
        }
        return data
    }

    static func domainInput(channel: String, keyId: String, payload: Data) -> Data {
        var input = Data("\(formatName)\0\(channel)\0\(keyId)\0".utf8)
        input.append(payload)
        return input
    }

    /// Raw Ed25519 verification (also used directly by the RFC 8032 vector
    /// selftests).
    static func ed25519Verify(publicKey: Data, signature: Data, message: Data) -> Bool {
        guard publicKey.count == 32, signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// Full envelope verification: returns the authenticated, validated
    /// manifest or throws a distinct error. `now` is injectable for tests.
    static func verifyEnvelope(
        _ raw: Data, policy: ReleasePolicy, now: Date = Date()
    ) throws -> Manifest {
        guard !policy.keys.isEmpty else { throw ReleaseVerifyError.noPinnedKeys }
        guard raw.count <= maxEnvelopeBytes else {
            throw ReleaseVerifyError.envelopeTooLarge(raw.count)
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: raw)
        } catch {
            throw ReleaseVerifyError.malformedEnvelope("not a valid envelope JSON object")
        }
        guard envelope.format == formatName else {
            throw ReleaseVerifyError.unsupportedFormat(envelope.format)
        }
        guard envelope.channel == policy.channel else {
            throw ReleaseVerifyError.wrongChannel(envelope.channel)
        }
        guard let key = policy.keys.first(where: { $0.keyId == envelope.keyId }) else {
            throw ReleaseVerifyError.unknownKey(envelope.keyId)
        }
        let signature = try strictBase64(envelope.signature, field: "signature")
        guard signature.count == 64 else {
            throw ReleaseVerifyError.malformedEnvelope("signature is \(signature.count) bytes, not 64")
        }
        let payload = try strictBase64(envelope.payload, field: "payload")
        guard payload.count <= maxPayloadBytes else {
            throw ReleaseVerifyError.payloadTooLarge(payload.count)
        }
        let message = domainInput(channel: envelope.channel, keyId: envelope.keyId, payload: payload)
        guard ed25519Verify(publicKey: key.publicKey, signature: signature, message: message) else {
            throw ReleaseVerifyError.badSignature
        }
        return try validateManifest(payload, policy: policy, now: now)
    }

    private static func parseISO8601(_ string: String, field: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) else {
            throw ReleaseVerifyError.malformedManifest("'\(field)' is not an ISO 8601 timestamp")
        }
        return date
    }

    static let versionPattern = "^[0-9]+\\.[0-9]+\\.[0-9]+$"

    /// Validates the AUTHENTICATED payload only — callers must have verified
    /// the signature first (verifyEnvelope does both).
    static func validateManifest(
        _ payload: Data, policy: ReleasePolicy, now: Date = Date()
    ) throws -> Manifest {
        let raw: RawManifest
        do {
            raw = try JSONDecoder().decode(RawManifest.self, from: payload)
        } catch {
            throw ReleaseVerifyError.malformedManifest("payload is not a valid manifest JSON object")
        }
        guard raw.schema == 1 else {
            throw ReleaseVerifyError.malformedManifest("unsupported schema \(raw.schema)")
        }
        guard raw.channel == policy.channel else {
            throw ReleaseVerifyError.wrongChannel(raw.channel)
        }
        guard raw.sequence >= 1 else {
            throw ReleaseVerifyError.malformedManifest("sequence \(raw.sequence) is not positive")
        }
        guard raw.version.range(of: versionPattern, options: .regularExpression) != nil else {
            throw ReleaseVerifyError.malformedManifest("version '\(raw.version)' is not exact SemVer")
        }
        let published = try parseISO8601(raw.published, field: "published")
        let expires = try parseISO8601(raw.expires, field: "expires")
        guard expires > now else {
            throw ReleaseVerifyError.expired(raw.expires)
        }
        guard published <= now.addingTimeInterval(clockSkewAllowance) else {
            throw ReleaseVerifyError.notYetValid(raw.published)
        }
        guard !raw.platforms.isEmpty else {
            throw ReleaseVerifyError.malformedManifest("manifest lists no platforms")
        }
        let allowedPrefix = policy.artifactURLPrefix
            .replacingOccurrences(of: "{version}", with: raw.version)
        var platforms: [String: Manifest.Platform] = [:]
        for (name, entry) in raw.platforms {
            guard entry.url.hasPrefix(allowedPrefix) else {
                throw ReleaseVerifyError.badPlatformEntry(
                    "\(name): url is outside the pinned release location")
            }
            let filename = String(entry.url.dropFirst(allowedPrefix.count))
            guard !filename.isEmpty,
                  filename.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
                  !filename.contains("..")
            else {
                throw ReleaseVerifyError.badPlatformEntry("\(name): url filename is not a plain asset name")
            }
            guard entry.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw ReleaseVerifyError.badPlatformEntry("\(name): sha256 is not 64 lowercase hex characters")
            }
            guard entry.size > 0, entry.size <= maxArtifactBytes else {
                throw ReleaseVerifyError.badPlatformEntry("\(name): size \(entry.size) is out of range")
            }
            platforms[name] = Manifest.Platform(url: entry.url, sha256: entry.sha256, size: entry.size)
        }
        return Manifest(
            schema: raw.schema, channel: raw.channel, sequence: raw.sequence,
            version: raw.version, published: published, expires: expires,
            platforms: platforms)
    }
}

/// Durable anti-rollback state: the highest release sequence this install
/// has ever successfully verified, PER TRUST DOMAIN (channel + pinned
/// artifact location, i.e. at least channel + repository). Sequences are
/// only comparable inside one signed channel served from one location — a
/// staging build's sequence 60 says nothing about production, so it must
/// never become production's floor (the cross-channel block observed on the
/// staging Mac). Written only AFTER a manifest passed every check.
///
/// Every access runs under a cross-process flock(2) on a sibling lock file,
/// and a store is a locked read-modify-write that keeps `max(stored, new)`:
/// two concurrent update checks can never regress the floor (60 → 59),
/// whatever order their writes land in.
///
/// A corrupt or unrecognized file (including the pre-domain v1 format,
/// whose single global sequence cannot be attributed to a domain) is
/// reported and treated as absent — the binary's embedded
/// `adaCLIReleaseSequence` floor still applies, so a power-loss-corrupted
/// file bounds exposure instead of bricking updates.
enum ReleaseTrustStore {
    static let schemaVersion = 2

    struct State: Codable {
        var schema: Int
        var domains: [String: Int]
    }

    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["BRIGLIA_RELEASE_TRUST_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return StoragePaths.dataRoot.appendingPathComponent("release_trust.json")
    }

    /// Sibling lock, never inside the state file itself (the state file is
    /// replaced by rename on every store).
    static var lockURL: URL { fileURL.appendingPathExtension("lock") }

    struct LockError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs `body` holding the cross-process lock (shared for readers,
    /// exclusive for writers). flock is advisory and dies with the process,
    /// so a crashed writer can never wedge later checks.
    private static func withLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        try PrivateStorage.ensureDirectoryScoped(fileURL.deletingLastPathComponent())
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw LockError(message: "cannot open \(lockURL.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        guard flock(fd, exclusive ? LOCK_EX : LOCK_SH) == 0 else {
            throw LockError(message: "cannot lock \(lockURL.path): \(String(cString: strerror(errno)))")
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// nil when the bytes are not a well-formed current-schema state.
    private static func parse(_ data: Data) -> State? {
        guard let state = try? JSONDecoder().decode(State.self, from: data),
              state.schema == schemaVersion,
              state.domains.values.allSatisfy({ $0 >= 1 })
        else { return nil }
        return state
    }

    /// (state, corrupt): state nil when the file is absent or corrupt;
    /// corrupt true only when a file existed but could not be parsed.
    private static func readUnlocked() -> (state: State?, corrupt: Bool) {
        guard let data = try? Data(contentsOf: fileURL) else { return (nil, false) }
        guard let state = parse(data) else { return (nil, true) }
        return (state, false)
    }

    /// (sequence, corrupt) for ONE trust domain: sequence nil when the file
    /// is absent, corrupt, or has no entry for this domain.
    static func load(domain: String) -> (sequence: Int?, corrupt: Bool) {
        // If the lock cannot be taken (read-only location), a lockless read
        // is still consistent: stores are whole-file renames.
        let read = (try? withLock(exclusive: false) { readUnlocked() }) ?? readUnlocked()
        return (read.state?.domains[domain], read.corrupt)
    }

    /// Locked monotonic merge: persists max(stored, sequence) for `domain`,
    /// leaving every other domain untouched, and returns the value that is
    /// now on disk. A corrupt existing file is replaced (it carried no
    /// trustworthy floor to preserve).
    @discardableResult
    static func store(_ sequence: Int, domain: String) throws -> Int {
        precondition(sequence >= 1, "release sequences are positive")
        return try withLock(exclusive: true) {
            var state = readUnlocked().state ?? State(schema: schemaVersion, domains: [:])
            let merged = max(state.domains[domain] ?? 0, sequence)
            state.domains[domain] = merged
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(state)
            try PrivateStorage.writeAtomically(data, to: fileURL)
            return merged
        }
    }
}

/// Size-bounded HTTP fetches for the update channel. Both paths enforce
/// their byte budget WHILE receiving (the task is cancelled the moment the
/// budget is exceeded), never after buffering an unbounded response.
final class BoundedHTTP: NSObject, @unchecked Sendable {
    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let maxBytes: Int64
    private let destination: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var buffer = Data()
    private var httpStatus = 0
    private var overLimit = false
    private var writeError: Error?

    private init(maxBytes: Int64, destination: FileHandle?) {
        self.maxBytes = maxBytes
        self.destination = destination
    }

    /// Small metadata fetch fully into memory, hard byte cap.
    static func fetchData(url: URL, maxBytes: Int, timeout: TimeInterval = 60) async throws -> Data {
        let fetcher = BoundedHTTP(maxBytes: Int64(maxBytes), destination: nil)
        _ = try await fetcher.run(url: url, timeout: timeout)
        return fetcher.buffer
    }

    /// Streams an artifact to `file`, enforcing the authenticated exact size
    /// and computing SHA-256 incrementally. Returns the lowercase hex digest.
    static func downloadFile(
        url: URL, to file: URL, expectedBytes: Int64, timeout: TimeInterval = 600
    ) async throws -> String {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: file.path) else {
            throw FetchError(message: "cannot open \(file.path) for writing")
        }
        defer { try? handle.close() }
        let fetcher = BoundedHTTP(maxBytes: expectedBytes, destination: handle)
        _ = try await fetcher.run(url: url, timeout: timeout)
        guard fetcher.received == expectedBytes else {
            throw FetchError(message: "download is \(fetcher.received) bytes, expected \(expectedBytes) — refusing")
        }
        return fetcher.hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func run(url: URL, timeout: TimeInterval) async throws -> Int64 {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: Delegate(owner: self), delegateQueue: delegateQueue)
        // invalidateAndCancel, not finishTasksAndInvalidate: by the time the
        // continuation resumed, the one task is settled — anything left is a
        // lingering keep-alive connection, and on Linux those can hold up
        // teardown of whatever the connection points at.
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = session.delegate as! Delegate
            delegate.continuation = continuation
            session.dataTask(with: request).resume()
        }
        if let writeError { throw writeError }
        guard httpStatus == 200 else {
            throw FetchError(message: "HTTP \(httpStatus) fetching \(url.absoluteString)")
        }
        return received
    }

    fileprivate func handleResponse(_ response: URLResponse) {
        httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Returns false when the task must be cancelled (budget exceeded or the
    /// destination write failed).
    fileprivate func handleChunk(_ data: Data) -> Bool {
        received += Int64(data.count)
        if received > maxBytes {
            overLimit = true
            return false
        }
        if let destination {
            do {
                try destination.write(contentsOf: data)
            } catch {
                writeError = error
                return false
            }
            hasher.update(data: data)
        } else {
            buffer.append(data)
        }
        return true
    }

    fileprivate func finish(error: Error?, continuation: CheckedContinuation<Void, Error>) {
        if overLimit {
            continuation.resume(throwing: FetchError(
                message: "response exceeded the \(maxBytes)-byte limit — refusing"))
        } else if let writeError {
            continuation.resume(throwing: writeError)
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    fileprivate final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let owner: BoundedHTTP
        var continuation: CheckedContinuation<Void, Error>?
        init(owner: BoundedHTTP) { self.owner = owner }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            owner.handleResponse(response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if !owner.handleChunk(data) {
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            owner.finish(error: error, continuation: continuation)
        }
    }
}

/// Hidden verifier over a local envelope file, using the binary's own pinned
/// key set and policy — exactly what `check()` trusts. Used by the release
/// workflow's verify jobs (candidate + production) and by the Phase E
/// watcher; also handy for manual channel diagnostics.
struct VerifyEnvelopeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__verify-envelope",
        abstract: "Verify a signed release envelope with this binary's pinned keys.",
        shouldDisplay: false
    )

    @Argument(help: "Path to manifest.sig.json")
    var path: String

    @Option(help: "Fail unless the authenticated version equals this.")
    var expectVersion: String?

    @Option(help: "Fail unless the authenticated sequence equals this.")
    var expectSequence: Int?

    func run() throws {
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        let manifest: ReleaseSigning.Manifest
        do {
            manifest = try ReleaseSigning.verifyEnvelope(raw, policy: .production)
        } catch {
            print("✖ VERIFY FAILED: \(error.localizedDescription)")
            throw ExitCode(1)
        }
        print("✔ envelope verified: \(manifest.channel) v\(manifest.version) sequence \(manifest.sequence)")
        for (platform, entry) in manifest.platforms.sorted(by: { $0.key < $1.key }) {
            print("  \(platform): \(entry.sha256)  \(entry.size) bytes")
            print("    \(entry.url)")
        }
        if let expectVersion, expectVersion != manifest.version {
            print("✖ expected version \(expectVersion), authenticated \(manifest.version)")
            throw ExitCode(1)
        }
        if let expectSequence, expectSequence != manifest.sequence {
            print("✖ expected sequence \(expectSequence), authenticated \(manifest.sequence)")
            throw ExitCode(1)
        }
    }
}

/// Hidden TEST-ONLY signer for the smoke suite's mock release channel:
/// derives a deterministic Ed25519 key from --seed-hex, signs the manifest
/// into a production-shaped envelope, and prints the keyId + public key so
/// the harness can hand them to the client via BRIGLIA_RELEASE_TEST_KEY.
/// Refuses to run in stamped release builds — same gate as the policy
/// overrides in ReleasePolicy.effective.
struct TestSignEnvelopeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__test-sign-envelope",
        abstract: "Sign a manifest with a throwaway test key (dev builds only).",
        shouldDisplay: false
    )

    @Argument(help: "Path to manifest.json")
    var manifestPath: String

    @Argument(help: "Output path for manifest.sig.json")
    var outputPath: String

    @Option(help: "64 hex chars deterministic key seed.")
    var seedHex: String

    func run() throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ __test-sign-envelope is available only in -dev builds")
            throw ExitCode(1)
        }
        guard let seed = ReleaseSigningSelftest.hexData(seedHex), seed.count == 32 else {
            print("✖ --seed-hex must be 64 hex characters")
            throw ExitCode(1)
        }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicKey = privateKey.publicKey.rawRepresentation
        let fingerprint = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        let keyId = "briglia-cli-release-v1-\(fingerprint.prefix(16))"
        let payload = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let message = ReleaseSigning.domainInput(channel: "briglia-cli", keyId: keyId, payload: payload)
        let signature = try privateKey.signature(for: message)
        let envelope: [String: String] = [
            "format": ReleaseSigning.formatName,
            "channel": "briglia-cli",
            "keyId": keyId,
            "payload": payload.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        try data.write(to: URL(fileURLWithPath: outputPath))
        let publicKeyHex = publicKey.map { String(format: "%02x", $0) }.joined()
        print("keyId=\(keyId)")
        print("publicKeyHex=\(publicKeyHex)")
    }
}
