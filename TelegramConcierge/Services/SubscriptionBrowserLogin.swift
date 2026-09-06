import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One callback is consumed before the token exchange. Invalid callbacks cannot
/// consume it; concurrent valid callbacks cannot exchange twice.
actor SubscriptionBrowserCallback {
    let state: String
    let deadline = Date().addingTimeInterval(300)
    private var code: String?
    private var consumed = false
    private var denied = false
    init(state: String) { self.state = state }
    func receive(_ request: QuickSetupHTTPServer.Request) -> QuickSetupHTTPServer.Response {
        guard request.method == "GET", request.path == "/auth/callback",
              ["localhost:1455", "127.0.0.1:1455"].contains(request.headers["host"] ?? ""),
              Date() < deadline, !consumed else { return .status(400) }
        let items = URLComponents(string: "http://localhost/?" + (request.query ?? ""))?.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        guard states.count == 1, states[0].value == state else { return .status(400) }
        let errors = items.filter { $0.name == "error" }
        if errors.count == 1 && codes.isEmpty {
            consumed = true; denied = true
            return .init(status: 200, headers: [("Content-Type", "text/plain"), ("Cache-Control", "no-store")], body: Data("Login declined. Return to Briglia.".utf8))
        }
        guard errors.isEmpty, codes.count == 1,
              let code = codes[0].value, !code.isEmpty, code.utf8.count <= 1024 else { return .status(400) }
        consumed = true; self.code = code
        return .init(status: 200, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Cache-Control", "no-store")],
                     body: Data("Authorization received. Return to Briglia to check completion.".utf8))
    }
    func take() throws -> String? { if denied { throw SubscriptionError("Browser authorization was declined") }; let result = code; code = nil; return result }
}

extension SubscriptionLogin {
    static func randomURLToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func browserURL(state: String, verifier: String) -> String {
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(string: SubscriptionEndpoint.issuer + "/oauth/authorize")!
        url.queryItems = ["response_type": "code", "client_id": SubscriptionEndpoint.clientID,
            "redirect_uri": "http://localhost:1455/auth/callback", "scope": "openid profile email offline_access",
            "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
            "id_token_add_organizations": "true", "codex_cli_simplified_flow": "true", "originator": "briglia"]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!.absoluteString
    }
    func browser(show: (String) async throws -> Void) async throws -> String {
        let pending = try await store.beginLogin()
        let state = Self.randomURLToken(), verifier = Self.randomURLToken()
        let callback = SubscriptionBrowserCallback(state: state)
        let server = QuickSetupHTTPServer(port: 1455) { await callback.receive($0) }
        defer { server.stop() }
        do {
            try server.start()
            try await show(Self.browserURL(state: state, verifier: verifier))
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                try Task.checkCancellation()
                guard try store.read()?.pendingLogin == pending else { throw SubscriptionError("Login cancelled or superseded") }
                if let code = try await callback.take() {
                    let (data, status) = try await post("/oauth/token", ["grant_type": "authorization_code", "code": code,
                        "code_verifier": verifier, "client_id": SubscriptionEndpoint.clientID,
                        "redirect_uri": "http://localhost:1455/auth/callback"], true)
                    guard status == 200 else { throw SubscriptionError("Browser token exchange failed (HTTP \(status))") }
                    return try await store.commitLogin(Self.token(data), pending: pending)
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw SubscriptionError("Browser login expired")
        } catch { try? await store.cancelLogin(pending); throw error }
    }
}
