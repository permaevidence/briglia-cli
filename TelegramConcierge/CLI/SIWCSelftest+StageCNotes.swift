import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A large page (two web_fetch sections) served locally.
final class SIWCOfflineLargeReader: URLProtocol {
    static let page: Data = {
        var text = "# Large synthetic page\n"
        let line = "Local review fixture line for the chunked fetch path. "
        while text.utf8.count < 1_700_000 { text += line }
        return Data(text.utf8)
    }()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "r.jina.ai" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.page)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Codex's non-blocking A+B notes (CHATGPT_SIWC_IMPL_AB_CODEX_REVIEW_ROUND3):
/// a large-page `web_fetch` that switches account and provider between its
/// chunks and its merge pass, and an end-to-end retry count for
/// "login changed".
extension SIWCSelftest {
    static func stageCNotesTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        try await loginChangedRetryTests(root, c)
        #if os(macOS)
        try await largePageTests(root, c)
        #endif
        try resetLive()
    }

    /// A 401, then a refresh that finds the login replaced → "login changed":
    /// exactly one inference request, no retry, no rebind.
    static func loginChangedRetryTests(_ root: URL, _ c: Checks) async throws {
        let (source, _) = try await liveSelection(clientId: "oaiappChanged", tokens: tokens("changed", expiresIn: 3600))
        let wire = Wire(); wire.install()
        wire.replies = [.failure(ResponsesFailure.http(401, nil)), .success(completed())]
        let tokenCalls = Wire()
        SIWCAuthClient.sendOverride = { request, _ in
            tokenCalls.lock.lock(); tokenCalls.requests.append(request); tokenCalls.lock.unlock()
            if request.url?.absoluteString == SIWCEndpoint.tokenURL {
                // Another process replaced the login while this refresh was in flight.
                try rewriteBound(source.store, source.clientId) { $0.tokens?.access = "synthetic-access-replaced" }
                return tokenReply("changed-next", idToken: nil)
            }
            return (Data(), 404)
        }
        let context = ProviderExecutionContext.siwcContext(source: source, model: "gpt-6.1-sol", effort: nil, lane: .main,
                                                           textOnly: false, nativeToolMedia: false)
        var kind: SIWCError.Kind?
        do { _ = try await ResponsesAdapter(context: context).send(input: [user("x")], tools: nil, receipt: receipt()) }
        catch let e as SIWCError { kind = e.kind } catch {}
        c.check("login changed: ends the operation with 'login changed'", kind == .loginChanged, "\(String(describing: kind))")
        c.check("login changed: exactly one inference request (never retried)", wire.count == 1)
        c.check("login changed: exactly one token-endpoint call", tokenCalls.requests.filter { $0.url?.absoluteString == SIWCEndpoint.tokenURL }.count == 1)
        c.check("login changed: the replacement is kept, the captured operation does not rebind",
                (try? source.store.readTokens())?.record(source.clientId)?.tokens?.access == "synthetic-access-replaced"
                && KeychainHelper.load(key: ChatGPTRoute.siwcGenerationKey) == source.generation)
        SIWCAuthClient.sendOverride = { _, _ in throw SIWCError(.local, "selftest: network disabled") }
    }

    /// A page of two sections plus a merge pass, with an account switch and a
    /// provider switch after the first chunk: every request stays on the
    /// captured registration, nothing reaches another bearer or backend.
    static func largePageTests(_ root: URL, _ c: Checks) async throws {
        URLProtocol.registerClass(SIWCOfflineLargeReader.self)
        defer { URLProtocol.unregisterClass(SIWCOfflineLargeReader.self) }
        SIWCModels.resetForTests()
        SIWCModels.fetchOverride = { _ in (Data(#"{"models":[{"slug":"gpt-6-luna","visibility":"list"}]}"#.utf8), 200) }
        setenv("BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE", "http://127.0.0.1:9", 1)
        defer { unsetenv("BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE"); WebSearchBackend.processOverride = nil }
        let (a, _) = try await liveSelection(clientId: "oaiappLargeA", sub: "large-A")
        let wire = Wire()
        let section = String(repeating: "Relevant section text. ", count: 1_000)   // ~23k chars per section
        ResponsesAdapter.siwcSendOverride = { request in
            wire.lock.lock(); wire.requests.append(request); let n = wire.requests.count; wire.lock.unlock()
            if n == 1 {
                // Between the chunks: another account becomes the store's
                // active one, and the web backend moves to OpenRouter.
                _ = try await liveSelection(clientId: "oaiappLargeB", sub: "large-B")
                WebSearchBackend.processOverride = .openrouter
            }
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            return completed(text: body.contains("page section") ? "MERGED-ON-A" : section)
        }
        let result = try? await WebOrchestrator().readUrlContentWithMetadata(url: "https://example.invalid/large", prompt: "Extract the relevant text")
        let bearers = Set(wire.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") })
        let mergeSent = wire.requests.contains { (String(data: $0.httpBody ?? Data(), encoding: .utf8) ?? "").contains("page section") }
        c.check("large page: two sections and a merge pass were sent", wire.count >= 3 && mergeSent, "\(wire.count) merge=\(mergeSent)")
        c.check("large page: every request used the captured registration's bearer", bearers == ["Bearer synthetic-access-live-\(a.clientId)"], "\(bearers)")
        c.check("large page: the merged result came from the captured route", (result?.result.content ?? "").contains("MERGED-ON-A"))
    }
}
