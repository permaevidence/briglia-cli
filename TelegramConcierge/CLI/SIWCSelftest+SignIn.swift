import Foundation

extension SIWCSelftest {
    static func attempt(_ store: SIWCStore, expected: String?, pending: String, id: String, host: (hostId: String, fingerprint: String),
                        nonce: String = SIWCSelftestVectors.nonce, expiresAt: Int) -> SIWCAttempt {
        SIWCAttempt(id: id, pending: pending, storeDirectory: store.directory, port: 62602, state: "STATE", nonce: nonce,
                    verifier: "verifier-" + String(repeating: "v", count: 40), expectedClientId: expected,
                    hostId: host.hostId, hostFingerprint: host.fingerprint, expiresAt: expiresAt, prompt: nil)
    }

    /// Authorize URL, discovery allowlist, exchange + ID-token check, scope
    /// handling and publication (§3.2, §3.6 last bullet).
    static func signInTests(_ root: URL, _ c: Checks) async throws {
        let store = SIWCStore(directory: root.appendingPathComponent("store"))
        let paths = hostPaths(root.appendingPathComponent("host"), stores: [store.directory])
        var signIn = SIWCSignIn(store: store)
        let fake = FakeAuth()
        signIn.auth = fake.client
        signIn.hostPaths = paths
        signIn.clock = { vectorNow }
        signIn.ownerLease = { nil }
        // Start: pending + reservation; authorize URL rules.
        let started = try await signIn.start(port: 62602, expectedClientId: nil, owner: nil, profile: "default")
        let url = URLComponents(string: SIWCSignIn.authorizeURL(started))!
        let q = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        c.check("authorize: the SIWC authorize endpoint", url.host == "auth.openai.com" && url.path == "/api/accounts/authorize")
        c.check("authorize: new registration uses dynamic_agent_client and agent_name_hint=Briglia (D22)",
                q["client_id"] == "dynamic_agent_client" && q["agent_name_hint"] == "Briglia")
        c.check("authorize: host ID always present", q["ext_agent_host_id"] == started.hostId && SIWCHost.wellFormed(started.hostId))
        c.check("authorize: full scope set incl. plan usage, resource, PKCE S256, nonce, state",
                q["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
                && q["resource"] == "https://api.openai.com/v1" && q["code_challenge_method"] == "S256"
                && q["code_challenge"] == started.challenge && q["nonce"] == started.nonce && q["state"] == started.state)
        c.check("authorize: 127.0.0.1 redirect with the attempt's port, never localhost",
                q["redirect_uri"] == "http://127.0.0.1:62602/auth/callback")
        c.check("authorize: a new registration carries no hints", q["id_token_hint"] == nil && q["login_hint"] == nil)
        await signIn.cancel(started)
        c.check("start/cancel: the pending marker and reservation are cleared", (try store.readTokens()?.pendingLogin) == nil
                && (try! SIWCHost.readReservations(paths).reservations.isEmpty))
        // Returning link.
        let back = SIWCAttempt(id: "x", pending: "p", storeDirectory: store.directory, port: 5, state: "s", nonce: "n", verifier: "v",
                               expectedClientId: "oaiappTestClientA", hostId: started.hostId, hostFingerprint: started.hostFingerprint, expiresAt: 0, prompt: "consent")
        let backQ = Dictionary((URLComponents(string: SIWCSignIn.authorizeURL(back))!.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        c.check("authorize: returning sign-in uses the issued client, no agent_name_hint", backQ["client_id"] == "oaiappTestClientA" && backQ["agent_name_hint"] == nil)
        c.check("authorize: id_token_hint only when Briglia opens the link locally",
                backQ["id_token_hint"] == nil && URLComponents(string: SIWCSignIn.authorizeURL(back, idTokenHint: "hint"))!.queryItems!.contains { $0.name == "id_token_hint" })
        c.check("authorize: enable plan usage uses prompt=consent", backQ["prompt"] == "consent")
        // Discovery allowlist.
        for (label, uri) in [("http", "http://auth.openai.com/jwks"), ("other host", "https://evil.example/jwks"),
                             ("port", "https://auth.openai.com:8443/jwks"), ("query", "https://auth.openai.com/jwks?x=1"),
                             ("userinfo", "https://u@auth.openai.com/jwks"), ("subdomain", "https://x.auth.openai.com/jwks")] {
            let bad = FakeAuth(); bad.discoveryBody["jwks_uri"] = uri
            c.check("discovery: \(label) JWKS URI refused", (try? await bad.client.discovery()) == nil)
        }
        let badRevoke = FakeAuth(); badRevoke.discoveryBody["revocation_endpoint"] = "https://evil.example/revoke"
        c.check("discovery: an off-allowlist revocation endpoint is refused", (try? await badRevoke.client.discovery()) == nil)
        let badIssuer = FakeAuth(); badIssuer.discoveryBody["issuer"] = "https://evil.example"
        c.check("discovery: another issuer is refused", (try? await badIssuer.client.discovery()) == nil)
        // Exchange (fixture attempt whose nonce matches the signed vector).
        let pending = try await store.beginPending(owner: nil)
        let host = try SIWCHost.reserve(paths, attemptId: "att-1", profile: "default", storePath: store.directory.path, ownerLease: nil,
                                        now: Int(Date().timeIntervalSince1970))
        let att = attempt(store, expected: nil, pending: pending, id: "att-1", host: host, expiresAt: Int(vectorNow.timeIntervalSince1970) + 600)
        fake.tokenReplies = [tokenReply("X", extra: ["earliest_refresh_at": SIWCSelftestVectors.issuedAt + 3238])]
        let result = try await signIn.exchange(att, code: "C", clientId: SIWCSelftestVectors.clientId)
        let sent = fake.tokenRequests.last ?? ""
        c.check("exchange: issued client, code, verifier, exact redirect and resource; no secret",
                sent.contains("grant_type=authorization_code") && sent.contains("client_id=oaiappTestClientA")
                && sent.contains("code_verifier=verifier-") && sent.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A62602%2Fauth%2Fcallback")
                && sent.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1") && !sent.contains("client_secret"))
        c.check("exchange: the ID token is verified (sub, nonce, aud)", result.claims.sub == SIWCSelftestVectors.sub && result.newRegistration)
        c.check("exchange: earliest_refresh_at kept as an absolute time", result.tokens?.earliestRefreshAt == SIWCSelftestVectors.issuedAt + 3238)
        c.check("exchange: only auth.openai.com was contacted", Set(fake.hosts) == ["auth.openai.com"])
        // Publication through the store (clock: real, the reservation is real-time).
        var realClock = signIn; realClock.clock = Date.init
        let saved = try await realClock.save(result, attempt: SIWCAttempt(id: att.id, pending: att.pending, storeDirectory: att.storeDirectory,
            port: att.port, state: att.state, nonce: att.nonce, verifier: att.verifier, expectedClientId: nil, hostId: att.hostId,
            hostFingerprint: att.hostFingerprint, expiresAt: Int(Date().timeIntervalSince1970) + 600, prompt: nil))
        c.check("publish: saved route-neutral, reservation released", { if case .saved = saved { return true }; return false }()
                && (try! SIWCHost.readReservations(paths).reservations.isEmpty))
        // Failures.
        fake.tokenReplies = [(Data("{\"error\":\"invalid_grant\"}".utf8), 400)]
        await c.rejectsKind("exchange: invalid_grant → start again (sign-in required)", .signInRequired) { _ = try await signIn.exchange(att, code: "C", clientId: SIWCSelftestVectors.clientId) }
        fake.tokenReplies = [tokenReply("Y", idToken: nil)]
        await c.rejects("exchange: no ID token → nothing saved") { _ = try await signIn.exchange(att, code: "C", clientId: SIWCSelftestVectors.clientId) }
        fake.tokenReplies = [tokenReply("Y", idToken: SIWCSelftestVectors.tokens["bad_sig"])]
        await c.rejects("exchange: a bad ID-token signature → nothing saved") { _ = try await signIn.exchange(att, code: "C", clientId: SIWCSelftestVectors.clientId) }
        let wrongNonce = attempt(store, expected: nil, pending: pending, id: "att-1", host: host, nonce: "OTHER", expiresAt: att.expiresAt)
        fake.tokenReplies = [tokenReply("Y")]
        await c.rejects("exchange: a nonce from another attempt → nothing saved") { _ = try await signIn.exchange(wrongNonce, code: "C", clientId: SIWCSelftestVectors.clientId) }
        fake.tokenReplies = [tokenReply("Y", extra: ["token_type": "mac"])]
        await c.rejects("exchange: a non-Bearer token is refused") { _ = try await signIn.exchange(att, code: "C", clientId: SIWCSelftestVectors.clientId) }
        fake.tokenReplies = [tokenReply("Y", expiresIn: 0)]
        await c.rejects("exchange: an invalid expiry is refused") { _ = try await signIn.exchange(att, code: "C", clientId: SIWCSelftestVectors.clientId) }
        fake.tokenReplies = [(try! JSONSerialization.data(withJSONObject: ["access_token": "a", "refresh_token": "r", "token_type": "Bearer", "expires_in": true]), 200)]
        await c.rejects("exchange: a boolean expires_in is refused") { _ = try await signIn.exchange(att, code: "C", clientId: SIWCSelftestVectors.clientId) }
        fake.tokenReplies = [tokenReply("Y", scope: "openid profile email")]
        let identityOnly = try await signIn.exchange(att, code: "C", clientId: SIWCSelftestVectors.clientId)
        c.check("scope: the granted scope (token response) decides plan usage", identityOnly.tokens?.planUsage == false)
        let expired = attempt(store, expected: nil, pending: pending, id: "att-1", host: host, expiresAt: Int(vectorNow.timeIntervalSince1970) - 1)
        let before = fake.tokenCount()
        await c.rejects("exchange: an expired attempt contacts nobody") { _ = try await signIn.exchange(expired, code: "C", clientId: SIWCSelftestVectors.clientId) }
        c.check("exchange: no token request after expiry", fake.tokenCount() == before)
        // Kill switch.
        setenv("BRIGLIA_CHATGPT_ROUTE", "legacy", 1)
        await c.rejectsKind("kill switch: a new SIWC sign-in is refused", .disabled) { _ = try await signIn.start(port: 1, expectedClientId: nil, owner: nil) }
        unsetenv("BRIGLIA_CHATGPT_ROUTE")
        // Revocation (§3.6).
        let tomb = SIWCStore.Tombstone(clientId: "oaiappTestClientA", generation: UUID().uuidString, revoke: ["synthetic-refresh-Q", "synthetic-refresh-Q"])
        c.check("revoke: form-encoded token, hint and issued client, deduplicated", await signIn.revokeAll(tomb, attempts: 1)
                && fake.revoked.count == 1 && fake.revoked[0].contains("token_type_hint=refresh_token") && fake.revoked[0].contains("client_id=oaiappTestClientA"))
        fake.revokeStatus = 503
        c.check("revoke: an unconfirmed revoke is reported, never assumed", await signIn.revokeAll(tomb, attempts: 1) == false)
    }
}
