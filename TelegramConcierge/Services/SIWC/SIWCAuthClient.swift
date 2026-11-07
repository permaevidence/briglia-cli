import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The SIWC authentication transport (§3.6 last bullet): exactly the
/// discovery document, the JWKS URI and revocation endpoint that discovery
/// names (HTTPS on auth.openai.com, reviewed allowlist), and the SIWC token
/// path. Redirects are refused, replies are bounded, bodies never reach an
/// error message. The network send is injectable for selftests only; the
/// allowlist runs before it either way.
struct SIWCAuthClient {
    typealias Reply = (data: Data, status: Int)
    typealias Send = (URLRequest, TimeInterval) async throws -> Reply

    /// Selftest seam (development builds only): replaces every default send.
    nonisolated(unsafe) static var sendOverride: Send?

    var send: Send = { request, deadline in
        if adaCLIVersion.hasSuffix("-dev"), let override = SIWCAuthClient.sendOverride { return try await override(request, deadline) }
        let reply = try await SubscriptionAuthHTTP(deadline: deadline).perform(request)
        return (reply.0, reply.1)
    }

    struct Discovery: Equatable {
        let jwksURI: String
        let revocationEndpoint: String
    }

    /// Accept only `https://auth.openai.com/<path>` with no userinfo, port,
    /// query or fragment (the reviewed allowlist for discovered URIs).
    static func allowedAuthURL(_ text: String) -> Bool {
        guard let url = URLComponents(string: text), url.scheme == "https", url.host == SIWCEndpoint.authHost,
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.percentEncodedPath.hasPrefix("/"), url.percentEncodedPath.count > 1,
              !url.percentEncodedPath.contains("..") else { return false }
        return URL(string: text) != nil
    }

    private func request(_ url: String, method: String, form: [(String, String)]? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue(SessionAffinity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formEncode(form).utf8)
        }
        return request
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.map { $0.0.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
            + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 131072, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SIWCError(.local, "ChatGPT sign-in returned a malformed response. Nothing was saved.")
        }
        return object
    }

    func discovery() async throws -> Discovery {
        let reply = try await send(request(SIWCEndpoint.discoveryURL, method: "GET"), 10)
        guard reply.status == 200 else { throw SIWCError(.transient, "ChatGPT sign-in discovery is unavailable (HTTP \(reply.status)); try again.") }
        let object = try Self.object(reply.data)
        guard object["issuer"] as? String == SIWCEndpoint.issuer,
              let jwks = object["jwks_uri"] as? String, Self.allowedAuthURL(jwks),
              let revocation = object["revocation_endpoint"] as? String, Self.allowedAuthURL(revocation) else {
            throw SIWCError(.local, "ChatGPT sign-in discovery named an unreviewed endpoint. Nothing was sent.")
        }
        return Discovery(jwksURI: jwks, revocationEndpoint: revocation)
    }

    func jwks(_ discovery: Discovery) async throws -> [String: Any] {
        guard Self.allowedAuthURL(discovery.jwksURI) else { throw SIWCError(.local, "Unreviewed JWKS endpoint") }
        let reply = try await send(request(discovery.jwksURI, method: "GET"), 10)
        guard reply.status == 200 else { throw SIWCError(.transient, "ChatGPT sign-in keys are unavailable (HTTP \(reply.status)); try again.") }
        return try Self.object(reply.data)
    }

    /// POST to the SIWC token endpoint (exchange or refresh).
    func token(_ fields: [(String, String)]) async throws -> Reply {
        try await send(request(SIWCEndpoint.tokenURL, method: "POST", form: fields), 30)
    }

    /// Revoke one refresh token (§3.6). Returns true only on HTTP 200.
    func revoke(_ refreshToken: String, clientId: String, discovery: Discovery) async throws -> Bool {
        guard Self.allowedAuthURL(discovery.revocationEndpoint) else { throw SIWCError(.local, "Unreviewed revocation endpoint") }
        let reply = try await send(request(discovery.revocationEndpoint, method: "POST", form: [
            ("token", refreshToken), ("token_type_hint", "refresh_token"), ("client_id", clientId)]), 30)
        return reply.status == 200
    }
}
