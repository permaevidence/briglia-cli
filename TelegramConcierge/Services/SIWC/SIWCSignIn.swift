import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One SIWC sign-in attempt, owned by one process (§3.2, §3.8). The PKCE
/// verifier, `state` and `nonce` exist only here, in memory; the store keeps
/// the pending id, owner and expiry; the machine keeps a host reservation.
struct SIWCAttempt {
    let id: String
    let pending: String
    let storeDirectory: URL
    let port: Int
    let state: String
    let nonce: String
    let verifier: String
    let expectedClientId: String?
    let hostId: String
    let hostFingerprint: String
    let expiresAt: Int
    let prompt: String?

    var redirectURI: String { "http://127.0.0.1:\(port)\(SIWCEndpoint.callbackPath)" }
    var challenge: String { SIWCEndpoint.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    var expectation: SIWCCallbackExpectation { SIWCCallbackExpectation(port: port, state: state, expectedClientId: expectedClientId) }
    var newRegistration: Bool { expectedClientId == nil }
}

/// Sign-in core (stage A): start, authorize URL, callback, exchange, ID-token
/// check, scope handling and publication through `SIWCStore.save`. No user
/// surface calls this yet (stage D); the settings-writer integration of the
/// publication and activation is stage C.
struct SIWCSignIn {
    var store: SIWCStore
    var auth = SIWCAuthClient()
    var hostPaths = SIWCHost.Paths.live
    var clock: () -> Date = Date.init
    /// The member lease that names the owner of host reservations.
    var ownerLease: () -> String? = { MemberEntry.current?.lockURL.path }

    var now: Int { Int(clock().timeIntervalSince1970) }

    /// Start an attempt: the store's one pending marker, then the host
    /// reservation (read-or-create host ID). The listener's port is chosen by
    /// the caller (OS-chosen, `SIWCCallbackListener`).
    func start(port: Int, expectedClientId: String?, owner: String? = SubscriptionSharing.ownerTag,
               profile: String = AssistantProfile.selectedName, consent: Bool = false) async throws -> SIWCAttempt {
        guard SIWCEndpoint.disabledByEnvironment() == false else { throw SIWCError(.disabled, SIWCEndpoint.disabledMessage) }
        if let expectedClientId { guard SIWCStore.wellFormedClientId(expectedClientId) else { throw SIWCError(.local, "Invalid saved ChatGPT registration") } }
        let pending = try await store.beginPending(owner: owner)
        let id = UUID().uuidString
        do {
            let host = try SIWCHost.reserve(hostPaths, attemptId: id, profile: profile, storePath: store.directory.path,
                                            ownerLease: ownerLease(), now: now)
            return SIWCAttempt(id: id, pending: pending, storeDirectory: store.directory, port: port,
                               state: SIWCEndpoint.randomToken(bytes: 24), nonce: SIWCEndpoint.randomToken(bytes: 24),
                               verifier: SIWCEndpoint.randomToken(bytes: 32), expectedClientId: expectedClientId,
                               hostId: host.hostId, hostFingerprint: host.fingerprint,
                               expiresAt: now + Int(SIWCEndpoint.attemptLifetime), prompt: consent ? "consent" : nil)
        } catch {
            try? await store.cancelPending(pending)
            throw error
        }
    }

    /// Cancel this attempt (pending marker and reservation). Best effort.
    func cancel(_ attempt: SIWCAttempt) async {
        try? await store.cancelPending(attempt.pending)
        try? SIWCHost.release(hostPaths, attemptId: attempt.id)
    }

    /// The authorize URL (§1, §3.2 step 3). `localHint` = the link is opened
    /// locally by Briglia itself: only then may `id_token_hint` be added.
    /// Telegram links never carry any hint (§3.4).
    static func authorizeURL(_ attempt: SIWCAttempt, idTokenHint: String? = nil) -> String {
        var items: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", attempt.expectedClientId ?? SIWCEndpoint.dynamicClient),
            ("redirect_uri", attempt.redirectURI),
            ("scope", SIWCEndpoint.fullScopes.joined(separator: " ")),
            ("resource", SIWCEndpoint.resource),
            ("state", attempt.state),
            ("nonce", attempt.nonce),
            ("code_challenge", attempt.challenge),
            ("code_challenge_method", "S256"),
            ("ext_agent_host_id", attempt.hostId),
        ]
        if attempt.newRegistration { items.append(("agent_name_hint", SIWCEndpoint.agentNameHint)) }
        else if let idTokenHint, !idTokenHint.isEmpty { items.append(("id_token_hint", idTokenHint)) }
        if let prompt = attempt.prompt { items.append(("prompt", prompt)) }
        return SIWCEndpoint.authorizeURL + "?" + SIWCAuthClient.formEncode(items)
    }

    // MARK: Token responses

    /// Parse a token-endpoint reply (exchange or refresh). Requires a Bearer
    /// access token, a refresh token (rotated every refresh, §1), a bounded
    /// `expires_in`; `scope` absent keeps `previousScopes` only if there are
    /// some. Never echoes body text.
    /// Parse a token-endpoint reply. Returns nil tokens for a verified-to-be
    /// identity-only grant (no plan-usage scope and no refresh token, P4a);
    /// a plan grant without a refresh token is refused.
    static func parseTokens(_ data: Data, now: Int, previousScopes: [String]?) throws -> (SIWCTokens?, String?) {
        let object = try SIWCAuthClient.object(data)
        guard let access = object["access_token"] as? String, !access.isEmpty,
              let type = object["token_type"] as? String, type.lowercased() == "bearer" else {
            throw SIWCError(.local, "ChatGPT sign-in returned an incomplete credential. Nothing was saved.")
        }
        guard let number = object["expires_in"] as? NSNumber, String(cString: number.objCType) != "c",
              number.doubleValue > 0, number.doubleValue <= 30 * 86400 else {
            throw SIWCError(.local, "ChatGPT sign-in returned an invalid expiry. Nothing was saved.")
        }
        let scopes: [String]
        if let scope = object["scope"] {
            guard let text = scope as? String else { throw SIWCError(.local, "ChatGPT sign-in returned malformed scopes. Nothing was saved.") }
            scopes = text.split(separator: " ").map(String.init)
        } else if let previousScopes, !previousScopes.isEmpty { scopes = previousScopes }
        else { throw SIWCError(.local, "ChatGPT sign-in returned no scopes. Nothing was saved.") }
        var earliest: Int? = nil
        if let value = object["earliest_refresh_at"] {
            if let n = value as? NSNumber, String(cString: n.objCType) != "c", n.doubleValue.isFinite {
                let e = Int(n.doubleValue)
                if abs(e - now) < 366 * 86400 { earliest = e }
            } else if let text = value as? String, let date = ISO8601DateFormatter().date(from: text) {
                let e = Int(date.timeIntervalSince1970)
                if abs(e - now) < 366 * 86400 { earliest = e }
            }
        }
        let idToken = (object["id_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if object["id_token"] != nil && idToken == nil { throw SIWCError(.local, "ChatGPT sign-in returned a malformed ID token. Nothing was saved.") }
        if object["refresh_token"] != nil && (object["refresh_token"] as? String ?? "").isEmpty {
            throw SIWCError(.local, "ChatGPT sign-in returned an incomplete credential. Nothing was saved.")
        }
        guard let refresh = object["refresh_token"] as? String else {
            guard !scopes.contains(SIWCEndpoint.planScope) else {
                throw SIWCError(.local, "ChatGPT sign-in returned an incomplete credential. Nothing was saved.")
            }
            return (nil, idToken)   // identity only: the access token is never kept or sent
        }
        let tokens = SIWCTokens(access: access, refresh: refresh, idToken: idToken, tokenType: "Bearer", scopes: scopes,
                                expiresAt: now + Int(number.doubleValue), earliestRefreshAt: earliest)
        guard tokens.valid else { throw SIWCError(.local, "ChatGPT sign-in returned an invalid credential. Nothing was saved.") }
        return (tokens, idToken)
    }

    /// Token-endpoint failure classification (§3.3). Only codes are read.
    static func tokenFailure(status: Int, data: Data) -> SIWCError {
        let code = ((try? SIWCAuthClient.object(data))?["error"] as? String) ?? ""
        if code == "invalid_client" { return SIWCError(.invalidClient, SIWCError.invalidClientMessage) }
        if SIWCEndpoint.terminalRefreshErrors.contains(code) || [400, 401, 403].contains(status) {
            return SIWCError(.signInRequired, SIWCError.signInMessage)
        }
        return SIWCError(.transient, "ChatGPT sign-in is temporarily unavailable (HTTP \(status)); try again.")
    }

    // MARK: Callback → exchange → verify (§3.2 steps 4–8)

    /// Exchange a validated callback code and verify the ID token. On
    /// `invalid_grant` the code is discarded (start a fresh attempt).
    func exchange(_ attempt: SIWCAttempt, code: String, clientId: String) async throws -> SIWCSignInResult {
        guard now < attempt.expiresAt else { throw SIWCError(.local, CallbackPaste.Rejection.expired.rawValue) }
        let reply = try await auth.token([
            ("grant_type", "authorization_code"), ("code", code), ("code_verifier", attempt.verifier),
            ("client_id", clientId), ("redirect_uri", attempt.redirectURI), ("resource", SIWCEndpoint.resource)])
        guard reply.status == 200 else { throw Self.tokenFailure(status: reply.status, data: reply.data) }
        let (tokens, idToken) = try Self.parseTokens(reply.data, now: now, previousScopes: nil)
        guard let idToken else { throw SIWCError(.local, "ChatGPT sign-in returned no ID token. Nothing was saved.") }
        let discovery = try await auth.discovery()
        let jwks = try await auth.jwks(discovery)
        let claims = try await SIWCJWT.verify(idToken, jwks: jwks, clientId: clientId, nonce: attempt.nonce, now: clock(),
                                               refetch: { try await auth.jwks(discovery) })
        return SIWCSignInResult(clientId: clientId, newRegistration: attempt.newRegistration, tokens: tokens, claims: claims)
    }

    /// The refresh request for one registration (§3.5): `grant_type`,
    /// issued `client_id`, refresh token and `resource`, without `scope`.
    /// The ID token, when returned, is verified (nonce not checked).
    static func refresher(auth: SIWCAuthClient, clientId: String, previousScopes: [String],
                          clock: @escaping () -> Date = Date.init) -> (String) async throws -> SIWCRefreshed {
        return { refreshToken in
            let reply = try await auth.token([("grant_type", "refresh_token"), ("client_id", clientId),
                                              ("refresh_token", refreshToken), ("resource", SIWCEndpoint.resource)])
            guard reply.status == 200 else { throw tokenFailure(status: reply.status, data: reply.data) }
            let now = Int(clock().timeIntervalSince1970)
            let (parsed, idToken) = try parseTokens(reply.data, now: now, previousScopes: previousScopes)
            guard let tokens = parsed else {
                throw SIWCError(.local, "ChatGPT returned a refresh without plan usage. Nothing was changed.")
            }
            var claims: SIWCJWT.Claims? = nil
            if let idToken {
                let discovery = try await auth.discovery()
                let jwks = try await auth.jwks(discovery)
                claims = try await SIWCJWT.verify(idToken, jwks: jwks, clientId: clientId, nonce: nil, now: clock(),
                                                   refetch: { try await auth.jwks(discovery) })
            }
            return SIWCRefreshed(tokens: tokens, claims: claims)
        }
    }

    /// Publish a verified sign-in (route-neutral save). Plan usage absent →
    /// the registration is saved with plan usage off and no inference.
    func save(_ result: SIWCSignInResult, attempt: SIWCAttempt, inUseByCaller: Bool = false,
              effect: SIWCEffectMark? = nil) async throws -> SIWCSaveOutcome {
        guard now < attempt.expiresAt else {
            if let refresh = result.tokens?.refresh { await revokeBestEffort(refresh, clientId: result.clientId) }
            throw SIWCError(.local, SIWCHost.expiredMessage)
        }
        do {
            return try await store.save(result, pending: attempt.pending, attemptId: attempt.id,
                                        hostFingerprint: attempt.hostFingerprint, hostPaths: hostPaths,
                                        inUseByCaller: inUseByCaller, effect: effect)
        } catch {
            // A refused publication revokes the issued tokens best effort.
            if let refresh = result.tokens?.refresh { await revokeBestEffort(refresh, clientId: result.clientId) }
            throw error
        }
    }

    func revokeBestEffort(_ refreshToken: String, clientId: String) async {
        guard let discovery = try? await auth.discovery() else { return }
        _ = try? await auth.revoke(refreshToken, clientId: clientId, discovery: discovery)
    }

    /// Revoke a tombstone's tokens outside every lock with bounded backoff
    /// (§3.6). Returns true only when every revocation was confirmed.
    func revokeAll(_ tombstone: SIWCStore.Tombstone, attempts: Int = 3) async -> Bool {
        guard !tombstone.revoke.isEmpty else { return true }
        var discovery: SIWCAuthClient.Discovery?
        for attempt in 0..<attempts {
            if let d = try? await auth.discovery() { discovery = d; break }
            try? await Task.sleep(nanoseconds: UInt64(1 << attempt) * 500_000_000)
        }
        guard let discovery else { return false }
        var allConfirmed = true
        for token in Set(tombstone.revoke) {
            var confirmed = false
            for attempt in 0..<attempts {
                if (try? await auth.revoke(token, clientId: tombstone.clientId, discovery: discovery)) == true { confirmed = true; break }
                try? await Task.sleep(nanoseconds: UInt64(1 << attempt) * 500_000_000)
            }
            allConfirmed = allConfirmed && confirmed
        }
        return allConfirmed
    }
}

/// The strict 127.0.0.1 callback listener (§3.2 step 2): OS-chosen port,
/// exact `Host`, exact path, the strict query decoding; one valid callback
/// is consumed, invalid ones never consume it. Never the paste parser.
actor SIWCCallbackListener {
    private(set) var expectation: SIWCCallbackExpectation?
    private var outcome: SIWCCallbackOutcome?
    private var consumed = false
    private var server: QuickSetupHTTPServer?

    /// Bind 127.0.0.1 with an OS-chosen port; returns the port.
    func start() throws -> Int {
        let server = QuickSetupHTTPServer(port: 0) { [weak self] request in
            guard let self else { return .status(400) }
            return await self.receive(request)
        }
        try server.start()
        self.server = server
        return Int(server.port)
    }

    func arm(_ expectation: SIWCCallbackExpectation) { self.expectation = expectation }

    func stop() { server?.stop(); server = nil }

    func take() -> SIWCCallbackOutcome? { let o = outcome; if o != nil { outcome = nil }; return o }

    func receive(_ request: QuickSetupHTTPServer.Request) -> QuickSetupHTTPServer.Response {
        guard let expectation, !consumed, request.method == "GET", request.path == SIWCEndpoint.callbackPath,
              request.headers["host"] == "127.0.0.1:\(expectation.port)" else { return .status(400) }
        let result = CallbackPaste.evaluate(query: request.query ?? "", expectation: expectation)
        switch result {
        case .rejected: return .status(400)
        case .error, .code:
            consumed = true; outcome = result
            let text = { if case .code = result { return "Briglia received the sign-in. You can close this tab." }
                         return "Sign-in did not complete. Return to Briglia." }()
            return .init(status: 200, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Cache-Control", "no-store")],
                         body: Data(text.utf8))
        }
    }
}
