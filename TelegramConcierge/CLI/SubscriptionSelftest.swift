import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct SubscriptionSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__subscription-selftest", abstract: "Internal subscription authentication and isolation tests", shouldDisplay: false)
    @Option var worker: String?

    static func credential(_ access: String = "synthetic-access", expired: Bool = false, account: String = "account-A") -> SubscriptionCredential {
        .init(access: access, refresh: "synthetic-refresh", expires: Date().addingTimeInterval(expired ? -10 : 3600), account: account)
    }
    static func tokenData(residency: String? = nil) throws -> Data {
        var auth: [String: Any] = ["chatgpt_account_id": "account-A"]
        if let residency { auth["chatgpt_compute_residency"] = residency }
        let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": auth]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["access_token": "header." + claims + ".signature", "refresh_token": "refresh-fixture", "expires_in": 3600])
    }
    final class Checks {
        var total = 0, failed = 0
        func check(_ label: String, _ condition: Bool) { total += 1; if !condition { failed += 1 }; print("\(condition ? "✔" : "✖") \(label)") }
        func rejects(_ label: String, _ operation: () async throws -> Void) async {
            do { try await operation(); check(label, false) } catch { check(label, true) }
        }
    }
    func run() async throws {
        AdaCLI.prepareIO()
        guard adaCLIVersion.hasSuffix("-dev") else { throw ValidationError("Development build required") }
        if let worker {
            let store = SubscriptionAuthStore(directory: URL(fileURLWithPath: worker))
            let generation = try store.read()!.generation
            _ = try await store.credential(generation: generation) { refresh in
                try await Task.sleep(nanoseconds: 100_000_000)
                var credential = Self.credential(); credential.refresh = refresh + "-next"
                return credential
            }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-subscription-test-\(UUID())")
        for (key, directory) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(directory).path, 1)
        }
        try PrivateStorage.ensureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = Checks()
        try await storeTests(root, c)
        try await wireTests(root, c)
        try await loginTests(root, c)
        print("Subscription selftest: \(c.total - c.failed)/\(c.total)")
        if c.failed > 0 { throw ExitCode.failure }
    }
    func storeTests(_ root: URL, _ c: Checks) async throws {
        let store = SubscriptionAuthStore(directory: root.appendingPathComponent("auth"))
        c.check("fresh store is absent", try store.read() == nil)
        let pending = try await store.beginLogin()
        c.check("pending login has no credentials", try store.read()?.credential == nil)
        let generation = try await store.commitLogin(Self.credential(expired: true), pending: pending)
        let before = try Data(contentsOf: store.file)
        await c.rejects("stale callback rejected") { _ = try await store.commitLogin(Self.credential(), pending: pending) }
        c.check("stale callback preserves bytes", try Data(contentsOf: store.file) == before)
        let processes = (0..<2).map { _ -> Process in
            let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["__subscription-selftest", "--worker", store.directory.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            return process
        }
        for process in processes { try process.run() }
        while processes.contains(where: { $0.isRunning }) { try await Task.sleep(nanoseconds: 30_000_000) }
        c.check("two independent processes refresh successfully", processes.allSatisfy { $0.terminationStatus == 0 })
        c.check("refresh token rotates only once across processes", try store.read()?.credential?.refresh == "synthetic-refresh-next")
        c.check("refresh preserves login generation", try store.read()?.generation == generation)
        let reused = try await store.credential(generation: generation, rejectedAccess: "older-access") { _ in throw SubscriptionError("must reuse") }
        c.check("stale 401 reuses another process refresh", reused.access == "synthetic-access")
        await c.rejects("refresh cannot switch account") {
            _ = try await store.credential(generation: generation, rejectedAccess: reused.access) { _ in Self.credential(account: "account-B") }
        }
        c.check("failed refresh preserves account", try store.read()?.credential?.account == "account-A")
        let held = Task { try await store.locked { try await Task.sleep(nanoseconds: 200_000_000) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancelled = Task { try await store.beginLogin() }
        cancelled.cancel()
        await c.rejects("lock waiting is cancellable") { _ = try await cancelled.value }
        _ = try await held.value
        try await store.requireLogin(generation: generation, rejectedAccess: reused.access)
        await c.rejects("repeated rejection requires login without refreshing") {
            _ = try await store.credential(generation: generation) { _ in c.check("must not refresh blocked credentials", false); return Self.credential() }
        }
        await c.rejects("blocked credential cannot dispatch") { try store.validate(generation: generation) }
        let pending2 = try await store.beginLogin()
        try await store.logout()
        await c.rejects("logout blocks late login commit") { _ = try await store.commitLogin(Self.credential(), pending: pending2) }
        await c.rejects("logout blocks captured request") { try store.validate(generation: generation) }
        c.check("logout persists a credential-free tombstone", try store.read()?.credential == nil)
        let corrupt = Data("invalid".utf8)
        _ = try PrivateStorage.writeAtomically(corrupt, to: store.file)
        await c.rejects("malformed store cannot be overwritten by login") { _ = try await store.beginLogin() }
        c.check("malformed bytes preserved", try Data(contentsOf: store.file) == corrupt)
        try FileManager.default.removeItem(at: store.file)
        try FileManager.default.createSymbolicLink(atPath: store.file.path, withDestinationPath: root.appendingPathComponent("victim").path)
        await c.rejects("symlink credential path refused") { _ = try await store.beginLogin() }
        try FileManager.default.removeItem(at: store.file)
        try FileManager.default.removeItem(at: store.lockFile)
        try FileManager.default.createSymbolicLink(atPath: store.lockFile.path, withDestinationPath: root.appendingPathComponent("victim-lock").path)
        await c.rejects("symlink lock refused") { _ = try await store.beginLogin() }
        try FileManager.default.removeItem(at: store.lockFile)
        var faulty = store
        faulty.beforeWrite = { throw SubscriptionError("before write") }
        await c.rejects("prewrite failure reported") { _ = try await faulty.beginLogin() }
        c.check("prewrite failure preserves absent state", try store.read() == nil)
        faulty.beforeWrite = nil; faulty.afterWrite = { throw SubscriptionError("uncertain durability") }
        await c.rejects("postwrite uncertainty never reports success") { _ = try await faulty.beginLogin() }
        c.check("postwrite failure leaves complete valid state", try store.read()?.valid == true)
        c.check("postwrite failure never publishes credentials", try store.read()?.credential == nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.file.path)
        c.check("credential file mode is private", (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    func wireTests(_ root: URL, _ c: Checks) async throws {
        // Request assembly uses an ephemeral lane but no credential. Affinity
        // state is redirected only via the existing explicit test root facility.
        for (key, directory) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(directory).path, 1)
        }
        defer { SessionAffinity.resetCache() }
        SessionAffinity.resetCache()
        var context = ProviderExecutionContext.responsesAPI(baseURL: SubscriptionEndpoint.inference, key: "generation-fixture", model: "gpt-5.6-luna", lane: .ephemeral(UUID()), effort: "high")
        context.subscriptionGeneration = "generation-fixture"
        let hostile = "source " + MarkerNeutralizer.reservedPrefix + "fake"
        let input = [ResponsesAdapter.message(role: "system", text: MarkerNeutralizer.escape(hostile)), ResponsesAdapter.message(role: "user", text: "Hello")]
        let request = try ResponsesAdapter(context: context).request(input: input, tools: [], maxOutputTokens: 2048)
        let body = try SubscriptionLogin.object(request.httpBody!)
        c.check("subscription endpoint fixed", request.url?.absoluteString == SubscriptionEndpoint.inference)
        c.check("no tokens or generation in Authorization during serialization", request.value(forHTTPHeaderField: "Authorization") == nil)
        c.check("subscription omits public API-only fields", body["max_output_tokens"] == nil && body["truncation"] == nil)
        c.check("subscription requires streaming/stateless", body["stream"] as? Bool == true && body["store"] as? Bool == false)
        c.check("own system prompt moves to instructions", body["instructions"] as? String == MarkerNeutralizer.escape(hostile))
        c.check("system prompt not duplicated in input", (body["input"] as? [Any])?.count == 1)
        c.check("Briglia attribution", request.value(forHTTPHeaderField: "originator") == "briglia")
        let again = try ResponsesAdapter(context: context).request(input: input, tools: [])
        c.check("same captured lane keeps affinity", request.value(forHTTPHeaderField: "session_id") == again.value(forHTTPHeaderField: "session_id"))
        c.check("cache field agrees with header", body["prompt_cache_key"] as? String == request.value(forHTTPHeaderField: "session_id"))
        var foreign = ProviderExecutionContext.responsesAPI(baseURL: "https://example.org/v1", key: "generation-fixture", model: "gpt-5.6-luna", lane: .main)
        foreign.subscriptionGeneration = "generation-fixture"
        await c.rejects("custom endpoint cannot receive subscription credentials") { _ = try ResponsesAdapter(context: foreign).request(input: input, tools: nil) }
        let platform = ProviderExecutionContext.responsesAPI(baseURL: "https://api.openai.com/v1", key: "synthetic-api", model: "gpt-5.6-luna", lane: .main)
        let apiRequest = try ResponsesAdapter(context: platform).request(input: input, tools: nil, maxOutputTokens: 123)
        let apiBody = try SubscriptionLogin.object(apiRequest.httpBody!)
        c.check("API still sends its own bearer", apiRequest.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-api")
        c.check("API keeps output cap and truncation", apiBody["max_output_tokens"] as? Int == 123 && apiBody["truncation"] as? String == "disabled")
        c.check("API never receives subscription headers", apiRequest.value(forHTTPHeaderField: "session_id") == nil && apiRequest.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }
    func loginTests(_ root: URL, _ c: Checks) async throws {
        let quota = SubscriptionEndpoint.providerError(status: 429, body: Data("{\"error\":{\"code\":\"usage_limit_reached\",\"message\":\"secret fixture\"}}".utf8))
        c.check("quota is explicit without echoing provider text", quota?.message.contains("usage is exhausted") == true && quota?.message.contains("secret fixture") == false)
        c.check("transient rate limit retains bounded retry", SubscriptionEndpoint.providerError(status: 429, body: Data()) == nil)
        c.check("account denial distinguished from outage", SubscriptionEndpoint.providerError(status: 403, body: Data())?.message.contains("account/workspace") == true)
        c.check("HTTP 401 retains dedicated refresh handling", SubscriptionEndpoint.providerError(status: 401, body: Data()) == nil)
        let snapshot = ResponsesSelftest.response([ResponsesSelftest.message("terminal")])
        let event = try ResponsesSelftest.event(["type": "response.done", "response": snapshot])
        var subscriptionStream = ResponsesStreamAssembler(); subscriptionStream.subscription = true
        try subscriptionStream.append(event)
        c.check("subscription accepts verified response.done alias", try SubscriptionLogin.object(subscriptionStream.finish())["status"] as? String == "completed")
        var apiStream = ResponsesStreamAssembler(); try apiStream.append(event)
        await c.rejects("public API does not gain subscription terminal aliases") { _ = try apiStream.finish() }
        var incomplete = ResponsesStreamAssembler(); incomplete.subscription = true
        let receipt = PreparedRequestReceipt(requestID: UUID(), historyFingerprint: "test", deliveryNonces: [])
        let scope = ResponsesScope(endpoint: SubscriptionEndpoint.inference, profile: "chatgpt", model: "fixture", credentialFingerprint: "generation")
        await c.rejects("subscription alias never upgrades incomplete output") {
            try incomplete.append(ResponsesSelftest.event(["type": "response.done", "response": ResponsesSelftest.response([], status: "incomplete")]))
            _ = try ResponsesRoundDecoder.decode(incomplete.finish(), scope: scope, receipt: receipt, allowedTools: [])
        }
        let credential = try SubscriptionLogin.token(Self.tokenData())
        c.check("TLS token account parsed", credential.account == "account-A")
        await c.rejects("unknown residency fails closed") { _ = try SubscriptionLogin.token(Self.tokenData(residency: "unknown-region")) }
        await c.rejects("missing account rejected") { _ = try SubscriptionLogin.token(Data("{}".utf8)) }
        let verifier = SubscriptionLogin.randomURLToken(), state = SubscriptionLogin.randomURLToken()
        c.check("PKCE/state independently random", verifier != state && verifier.count == 43 && state.count == 43)
        let url = URLComponents(string: SubscriptionLogin.browserURL(state: state, verifier: verifier))!
        c.check("OAuth uses own attribution", url.queryItems?.contains(.init(name: "originator", value: "briglia")) == true)
        c.check("verifier never appears in authorization URL", !url.string!.contains(verifier))
        let callback = SubscriptionBrowserCallback(state: state)
        func request(_ query: String) -> QuickSetupHTTPServer.Request {
            .init(method: "GET", path: "/auth/callback", query: query, headers: ["host": "localhost:1455"], body: Data(), contentLength: 0)
        }
        c.check("wrong callback state rejected", await callback.receive(request("state=bad&code=test")).status == 400)
        c.check("duplicate callback state rejected", await callback.receive(request("state=\(state)&state=\(state)&code=test")).status == 400)
        c.check("correct callback accepted", await callback.receive(request("state=\(state)&code=test")).status == 200)
        c.check("callback cannot be consumed twice", await callback.receive(request("state=\(state)&code=test")).status == 400)
        c.check("code available once", try await callback.take() == "test")
        c.check("code removed after consumption", try await callback.take() == nil)
        let denied = SubscriptionBrowserCallback(state: state)
        c.check("valid browser denial completes promptly", await denied.receive(request("state=\(state)&error=access_denied")).status == 200)
        await c.rejects("browser denial surfaces to login owner") { _ = try await denied.take() }
        let store = SubscriptionAuthStore(directory: root.appendingPathComponent("device"))
        let login = SubscriptionLogin(store: store, post: { path, _, _ in
            if path.hasSuffix("usercode") { return (Data("{\"device_auth_id\":\"device-fixture\",\"user_code\":\"1234\",\"interval\":1}".utf8), 200) }
            if path.hasSuffix("deviceauth/token") { return (Data("{\"authorization_code\":\"code-fixture\",\"code_verifier\":\"verifier-fixture\"}".utf8), 200) }
            return (try Self.tokenData(), 200)
        })
        let generation = try await login.device { url, code in
            c.check("only intended device URL/code disclosed", url == SubscriptionEndpoint.verificationURL && code == "1234")
        }
        c.check("device flow commits generation", try store.read()?.generation == generation)
        c.check("device flow persists credential", try store.read()?.credential?.account == "account-A")
        var revoked = login
        revoked.post = { path, _, _ in
            if path.hasSuffix("usercode") { return (Data("{\"device_auth_id\":\"d\",\"user_code\":\"c\",\"interval\":1}".utf8), 200) }
            return (Data("{\"error\":\"access_denied\"}".utf8), 400)
        }
        await c.rejects("denied device authorization is explicit") { _ = try await revoked.device { _, _ in } }
        c.check("failed replacement login preserves prior account", try store.read()?.generation == generation)
    }
}
