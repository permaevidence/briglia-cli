import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `__siwc-selftest`: Sign in with ChatGPT, stages A and B (SIWC plan v3.2
/// §8). Offline only: fake auth/inference transports, synthetic tokens,
/// temporary XDG roots. Groups are separate functions in separate files
/// (Linux CI frontend memory, feedback_linux_selftest_size_split).
struct SIWCSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__siwc-selftest",
        abstract: "Internal Sign in with ChatGPT tests (offline)", shouldDisplay: false)
    @Option var worker: String?
    @Option var only: String?

    final class Checks {
        var total = 0, failed = 0
        var failures: [String] = []
        func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !condition { failed += 1; failures.append(label) }
            let extra = condition ? "" : { let d = detail(); return d.isEmpty ? "" : " — \(d)" }()
            print("\(condition ? "✔" : "✖") \(label)\(extra)")
        }
        func rejects(_ label: String, _ operation: () async throws -> Void) async {
            do { try await operation(); check(label, false, "no error") } catch { check(label, true) }
        }
        func rejectsKind(_ label: String, _ kind: SIWCError.Kind, _ operation: () async throws -> Void) async {
            do { try await operation(); check(label, false, "no error") }
            catch let error as SIWCError { check(label, error.kind == kind, "kind \(error.kind)") }
            catch { check(label, false, "\(type(of: error))") }
        }
    }

    func run() async throws {
        AdaCLI.prepareIO()
        guard adaCLIVersion.hasSuffix("-dev") else { throw ValidationError("Development build required") }
        if let worker { try await Self.refreshWorker(URL(fileURLWithPath: worker)); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-siwc-test-\(UUID())")
        for (key, directory) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(directory).path, 1)
        }
        unsetenv("BRIGLIA_PROFILE"); unsetenv("BRIGLIA_CHATGPT_ROUTE")
        try PrivateStorage.ensureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = Checks()
        // No live network, ever: every SIWC transport seam refuses unless a
        // group installs its fake.
        let offline = SIWCError(.local, "selftest: network disabled")
        SIWCAuthClient.sendOverride = { _, _ in throw offline }
        SIWCModels.fetchOverride = { _ in throw offline }
        ResponsesAdapter.siwcSendOverride = { _ in throw offline }
        let groups: [(String, (URL, Checks) async throws -> Void)] = [
            ("jwt", Self.jwtTests), ("paste", Self.pasteTests), ("listener", Self.listenerTests),
            ("store", Self.storeTests), ("binding", Self.bindingTests), ("host", Self.hostTests),
            ("login", Self.loginTests), ("signin", Self.signInTests), ("refresh", Self.refreshTests),
            ("refresh2", Self.refreshRecoveryTests), ("fence", Self.fenceTests),
            ("body", Self.bodyTests), ("route", Self.routeTests), ("adapter", Self.adapterTests),
            ("adapter2", Self.adapterSignOutTests), ("web", Self.webTests), ("models", Self.modelsTests),
            ("errors", Self.errorTests), ("hostile", Self.hostilePrefixTests), ("legacy", Self.legacyUnchangedTests),
            ("round1", Self.round1Tests), ("round1host", Self.round1HostTests), ("round2", Self.round2Tests),
        ]
        for (name, group) in groups where only == nil || only == name {
            print("— \(name)")
            SIWCFence.shared.resetForTests()
            SIWCAuthClient.sendOverride = { _, _ in throw offline }
            SIWCModels.fetchOverride = { _ in throw offline }
            ResponsesAdapter.siwcSendOverride = { _ in throw offline }
            let dir = root.appendingPathComponent(name)
            try PrivateStorage.ensureDirectory(dir)
            try await group(dir, c)
        }
        print("SIWC selftest: \(c.total - c.failed)/\(c.total)")
        if c.failed > 0 {
            print("Failed: \(c.failures.joined(separator: "; "))")
            throw ExitCode.failure
        }
    }

    // MARK: Shared fixtures

    static var vectorNow: Date { Date(timeIntervalSince1970: TimeInterval(SIWCSelftestVectors.issuedAt + 60)) }

    static func hostPaths(_ root: URL, stores: [URL]) -> SIWCHost.Paths {
        SIWCHost.Paths(machineConfigRoot: root.appendingPathComponent("machine-config"),
                       machineDir: root.appendingPathComponent("machine"),
                       storeDirectories: { stores }, shareLock: root.appendingPathComponent("machine/chatgpt-share.lock"))
    }

    static func tokens(_ tag: String, expiresIn: Int = 3600, now: Int = Int(Date().timeIntervalSince1970),
                       plan: Bool = true, earliest: Int? = nil) -> SIWCTokens {
        SIWCTokens(access: "synthetic-access-\(tag)", refresh: "synthetic-refresh-\(tag)", idToken: "synthetic.id.\(tag)",
                   tokenType: "Bearer", scopes: plan ? SIWCEndpoint.fullScopes : SIWCEndpoint.identityScopes,
                   expiresAt: now + expiresIn, earliestRefreshAt: earliest)
    }

    static func claims(sub: String = "user-sub-A", account: String? = "acct-A") -> SIWCJWT.Claims {
        SIWCJWT.Claims(sub: sub, email: "user@example.invalid", emailVerified: true, accountId: account,
                       issuedAt: 0, expires: 0)
    }

    /// One full local sign-in through the real store primitives (pending,
    /// host reservation, save). Returns the outcome.
    @discardableResult
    static func signIn(_ store: SIWCStore, _ paths: SIWCHost.Paths, clientId: String, sub: String = "user-sub-A",
                       new: Bool, tokens: SIWCTokens, inUse: Bool = false, owner: String? = nil,
                       effect: SIWCEffectMark? = nil) async throws -> SIWCSaveOutcome {
        let pending = try await store.beginPending(owner: owner)
        let attempt = UUID().uuidString
        let host = try SIWCHost.reserve(paths, attemptId: attempt, profile: owner ?? "default", storePath: store.directory.path,
                                        ownerLease: nil, now: store.nowSeconds)
        return try await store.save(SIWCSignInResult(clientId: clientId, newRegistration: new, tokens: tokens,
                                                     claims: claims(sub: sub)),
                                    pending: pending, attemptId: attempt, hostFingerprint: host.fingerprint,
                                    hostPaths: paths, inUseByCaller: inUse, effect: effect)
    }

    /// A store with one active, usable registration. Returns (generation).
    static func activeStore(_ dir: URL, clientId: String = "oaiappClientA", tokens t: SIWCTokens? = nil) async throws -> (SIWCStore, SIWCHost.Paths, String) {
        let store = SIWCStore(directory: dir.appendingPathComponent("store-\(UUID().uuidString.prefix(6))"))
        let paths = hostPaths(dir.appendingPathComponent("host-\(UUID().uuidString.prefix(6))"), stores: [store.directory])
        let outcome = try await signIn(store, paths, clientId: clientId, new: true, tokens: t ?? tokens("A"))
        guard case .saved(_, let generation) = outcome else { throw SIWCError(.local, "fixture") }
        let active = try await store.activate(.init(clientId: clientId, generation: generation, replacementId: nil))
        return (store, paths, active)
    }

    /// Rewrite one record on disk without rebinding (tamper fixture).
    static func tamper(_ store: SIWCStore, _ clientId: String, _ change: (inout SIWCTokenRecord) -> Void) throws {
        var file = try store.readTokens()!
        file.update(clientId, change)
        _ = try PrivateStorage.writeAtomically(try SIWCStore.encode(file), to: store.tokenFile)
    }

    /// Rewrite one record and REBIND it with the store's key: what a
    /// cooperating process (the same store code, another moment) leaves.
    static func rewriteBound(_ store: SIWCStore, _ clientId: String, _ change: (inout SIWCTokenRecord) -> Void) throws {
        let key = try store.integrityKey(create: false)!
        var file = try store.readTokens()!
        var record = file.record(clientId)!
        change(&record)
        try SIWCStore.bind(&record, key: key)
        file.update(clientId) { $0 = record }
        _ = try PrivateStorage.writeAtomically(try SIWCStore.encode(file), to: store.tokenFile)
    }

    /// Fake auth server: discovery, JWKS and a programmable token endpoint.
    final class FakeAuth: @unchecked Sendable {
        let lock = NSLock()
        var tokenReplies: [(Data, Int)] = []
        var tokenRequests: [String] = []
        var revoked: [String] = []
        var revokeStatus = 200
        var discoveryBody: [String: Any] = ["issuer": SIWCEndpoint.issuer,
            "jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
            "revocation_endpoint": "https://auth.openai.com/oauth/revoke"]
        var jwks: [String: Any] = ["keys": [SIWCSelftestVectors.jwk1]]
        var jwksFetches = 0
        var hosts: [String] = []

        var client: SIWCAuthClient {
            SIWCAuthClient(send: { [self] request, _ in
                lock.lock(); defer { lock.unlock() }
                let url = request.url!.absoluteString
                hosts.append(request.url!.host ?? "")
                if url == SIWCEndpoint.discoveryURL { return (try JSONSerialization.data(withJSONObject: discoveryBody), 200) }
                if url == discoveryBody["jwks_uri"] as? String { jwksFetches += 1; return (try JSONSerialization.data(withJSONObject: jwks), 200) }
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if url == discoveryBody["revocation_endpoint"] as? String { revoked.append(body); return (Data(), revokeStatus) }
                if url == SIWCEndpoint.tokenURL {
                    tokenRequests.append(body)
                    guard !tokenReplies.isEmpty else { return (Data("{\"error\":\"server_error\"}".utf8), 500) }
                    return tokenReplies.removeFirst()
                }
                return (Data(), 404)
            })
        }
        func tokenCount() -> Int { lock.lock(); defer { lock.unlock() }; return tokenRequests.count }
    }

    static func tokenReply(_ tag: String, idToken: String? = SIWCSelftestVectors.tokens["good"], scope: String? = SIWCEndpoint.fullScopes.joined(separator: " "),
                           expiresIn: Int = 3600, extra: [String: Any] = [:]) -> (Data, Int) {
        var object: [String: Any] = ["access_token": "synthetic-access-\(tag)", "refresh_token": "synthetic-refresh-\(tag)",
                                     "token_type": "Bearer", "expires_in": expiresIn]
        if let idToken { object["id_token"] = idToken }
        if let scope { object["scope"] = scope }
        for (k, v) in extra { object[k] = v }
        return (try! JSONSerialization.data(withJSONObject: object), 200)
    }

    // MARK: Two-process refresh worker (§8 several assistants, §7)

    static func refreshWorker(_ dir: URL) async throws {
        let store = SIWCStore(directory: dir)
        guard let file = try store.readTokens(), let record = file.records.first else { throw ExitCode.failure }
        let log = dir.appendingPathComponent("sends.log")
        _ = try await store.credential(clientId: record.clientId, generation: record.generation) { refresh in
            let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(getpid()) \(refresh)\n".utf8)); try handle.close()
            try await Task.sleep(nanoseconds: 300_000_000)
            var t = tokens("rotated"); t.refresh = refresh + "-next"
            return SIWCRefreshed(tokens: t, claims: nil)
        }
    }
}
