import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// OpenAI's official "Sign in with ChatGPT" route for local apps (SIWC plan
/// v3.2). Everything here is opt-in: nothing in the legacy subscription
/// route reads these constants, and no user-facing surface reaches them
/// until stage D. Endpoints and parameter names follow the documented
/// preview contract and the 2026-10-15 live probes (§12).
enum SIWCEndpoint {
    static let issuer = "https://auth.openai.com"
    static let authHost = "auth.openai.com"
    static let authorizeURL = issuer + "/api/accounts/authorize"
    static let tokenPath = "/api/accounts/oauth/token"
    static let tokenURL = issuer + tokenPath
    static let discoveryURL = issuer + "/.well-known/openid-configuration"

    static let apiHost = "api.openai.com"
    /// The runtime endpoint an SIWC selection stores (§3.8: never the legacy
    /// inference URL, so an older binary's legacy adapter refuses it).
    static let apiBase = "https://api.openai.com/v1"
    static let responsesURL = apiBase + "/responses"
    static let modelsURL = apiBase + "/models"
    static let resource = apiBase

    static let dynamicClient = "dynamic_agent_client"
    /// D22 (owner, 2026-11-06): plain "Briglia" everywhere, own logins included.
    static let agentNameHint = "Briglia"
    static let identityScopes = ["openid", "profile", "email"]
    static let planScopes = ["offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    static var fullScopes: [String] { identityScopes + planScopes }
    static let planScope = "chatgpt.tokens.use.direct"
    static let callbackPath = "/auth/callback"
    /// The single tool namespace on the SIWC route (§4.2).
    static let namespace = "briglia"

    // Files (§3.1).
    static let hostFileName = "chatgpt-host.json"
    static let reservationsFileName = "chatgpt-host-reservations.json"
    static let registrationsFileName = "chatgpt-siwc-registrations.json"
    static let tokenFileName = "subscription-siwc-auth.json"
    static let lockFileName = "subscription-siwc.lock"
    /// The per-store integrity key of the token records (§3.1 binding).
    static let keyFileName = "subscription-siwc.key"

    /// Every SIWC file name of one store directory (file tools, wipe).
    static let storeFileNames = [registrationsFileName, tokenFileName, lockFileName, keyFileName]

    /// Pending browser/paste-back attempts expire after 10 minutes (§3.4).
    static let attemptLifetime: TimeInterval = 600
    /// Refresh 5 minutes before expiry, never before `earliest_refresh_at` (§3.5).
    static let refreshMargin: TimeInterval = 300

    /// Terminal refresh errors (§3.3): tokens cleared, sign-in required.
    static let terminalRefreshErrors: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]

    /// The kill switch (§5): `BRIGLIA_CHATGPT_ROUTE=legacy` disables the SIWC
    /// route. It never moves an SIWC account to legacy.
    static func disabledByEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["BRIGLIA_CHATGPT_ROUTE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "legacy"
    }
    static let disabledMessage = "ChatGPT plan sign-in is disabled in this build; choose a route in settings."

    static func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Selection-key fingerprints (§3.8). Unkeyed: they live in secrets.json
    /// and are compared across processes and binaries.
    static func registrationFingerprint(clientId: String) -> String {
        hex(SHA256.hash(data: Data("chatgpt-siwc-client:\(clientId)".utf8)))
    }
    static func identityFingerprint(clientId: String, sub: String) -> String {
        var data = Data("chatgpt-siwc-identity\u{0}".utf8)
        data.append(Data(clientId.utf8)); data.append(0); data.append(Data(sub.utf8))
        return hex(SHA256.hash(data: data))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Strict base64url (no padding, no other characters).
    static func base64URLDecode(_ text: String) -> Data? {
        guard text.utf8.allSatisfy({ c in
            (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 45 || c == 95
        }), text.utf8.count % 4 != 1 else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.utf8.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    static func randomToken(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }
}

/// Typed SIWC failures (§5). Every message is a fixed string: provider body
/// text, unknown error codes and `error_description` never reach a reply.
struct SIWCError: Error, LocalizedError, Equatable {
    enum Kind: String, Equatable {
        case signInRequired      // plan state `sign_in_required`
        case limitReached        // plan state `limit_reached`
        case notAvailable        // plan state `not_available`
        case transient           // 503 usage/user unavailable: keep credentials
        case unsupported         // unsupported_capability: stop, no paid path
        case routeIncompatible   // e.g. system items refused: stop and report
        case signedOut           // sign-out fenced this registration (§3.7)
        case disabled            // kill switch
        case busy                // lock wait expired
        case local               // local refusal (destination, normalizer, store)
        case invalidClient       // registration configuration broken (§3.3)
        case planUsageOff        // granted scopes lack plan usage (§3.2 step 7)
        case loginChanged        // the login changed under this operation: terminal for it, never retried
    }
    let kind: Kind
    let message: String
    /// For `unsupported`: the reported parameter name only (bounded, safe).
    var parameter: String? = nil
    init(_ kind: Kind, _ message: String, parameter: String? = nil) {
        self.kind = kind; self.message = message; self.parameter = parameter
    }
    var errorDescription: String? { message }

    static let loginChangedMessage = "The ChatGPT login changed while this request was running; start a new request."
    static let signInMessage = "ChatGPT sign-in for Briglia has expired or was revoked. Sign in again."
    static let signedOutMessage = "Signed out of ChatGPT."
    static let limitMessage = "ChatGPT usage limit reached for Briglia. Review your plan or this app's limit in ChatGPT settings (Manage usage: chatgpt.com/settings/usage). No API billing fallback was attempted."
    static let notEnabledMessage = "OpenAI has not enabled Briglia for plan sharing. Nothing will be retried."
    static let notEligibleMessage = "ChatGPT says this account or workspace can't use its plan in Briglia. Nothing will be retried."
    static let routeNotSupportedMessage = "ChatGPT refused this request as an unsupported route (a Briglia bug). Nothing was retried."
    static let systemRefusedMessage = "ChatGPT's plan route refused this request's format (system notes). Briglia stopped this request and changed nothing; please report it."
    static let invalidClientMessage = "This ChatGPT sign-in's app registration is broken. Register Briglia again from settings; nothing was replaced."
    static let planUsageOffMessage = "This ChatGPT sign-in doesn't include plan usage. Enable plan usage (sign in again and allow it) or choose another route."
}

/// Error classification for the SIWC route (§5). Codes only; status and a
/// bounded parameter name are the only other inputs.
enum SIWCErrors {
    /// Pre-stream HTTP error (status + bounded body).
    static func classify(status: Int, body: Data) -> SIWCError? {
        let object = (try? JSONSerialization.jsonObject(with: body.prefix(64 * 1024))) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = (error?["code"] as? String) ?? (error?["type"] as? String) ?? ""
        let param = (error?["param"] as? String).flatMap { p -> String? in
            p.utf8.count <= 64 && p.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) ? p : nil
        }
        if let mapped = classify(code: code, parameter: param) { return mapped }
        // `{"detail": "..."}` bodies: the text is diagnostic only (§1 table);
        // the one recognised refusal is the system-message rejection (§4.2).
        if let detail = object?["detail"] as? String, status == 400,
           detail.range(of: "system messages are not allowed", options: .caseInsensitive) != nil {
            return SIWCError(.routeIncompatible, SIWCError.systemRefusedMessage)
        }
        switch status {
        case 401: return nil   // one refresh, then sign-in (adapter)
        case 403: return SIWCError(.notAvailable, SIWCError.notEligibleMessage)
        case 503: return SIWCError(.transient, "ChatGPT's plan service is temporarily unavailable; retrying later. Your sign-in is kept.")
        default: return nil
        }
    }

    static func classify(code: String, parameter: String? = nil) -> SIWCError? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded", "usage_limit_exceeded":
            return SIWCError(.limitReached, SIWCError.limitMessage)
        case "usage_unavailable", "user_unavailable":
            return SIWCError(.transient, "ChatGPT's plan service is temporarily unavailable; retrying later. Your sign-in is kept.")
        case "unsupported_capability":
            return SIWCError(.unsupported, "ChatGPT's plan route doesn't support part of this request\(parameter.map { " (\($0))" } ?? ""). Nothing was retried and no paid path was used.", parameter: parameter)
        case "user_not_eligible":
            return SIWCError(.notAvailable, SIWCError.notEligibleMessage)
        case "subscription_sharing_v2_client_not_enabled", "v2_client_not_enabled":
            return SIWCError(.notAvailable, SIWCError.notEnabledMessage)
        case "route_not_supported", "subscription_sharing_route_not_supported":
            return SIWCError(.local, SIWCError.routeNotSupportedMessage)
        case "invalid_client":
            return SIWCError(.invalidClient, SIWCError.invalidClientMessage)
        default:
            if code.hasPrefix("chatpass_v2_") { return SIWCError(.notAvailable, SIWCError.notEligibleMessage) }
            return nil
        }
    }

    /// The same classification inside an HTTP-200 stream (`error` event or
    /// `response.failed`).
    static func streamed(_ event: [String: JSONValue]) -> SIWCError? {
        func codes(_ object: [String: JSONValue]?) -> [String] {
            guard let object else { return [] }
            return [object["code"]?.responsesString, object["type"]?.responsesString].compactMap { $0 }
        }
        var candidates = [event["code"]?.responsesString].compactMap { $0 }
        candidates += codes(event["error"]?.responsesObject)
        candidates += codes(event["response"]?.responsesObject?["error"]?.responsesObject)
        for code in candidates { if let mapped = classify(code: code) { return mapped } }
        return nil
    }
}
