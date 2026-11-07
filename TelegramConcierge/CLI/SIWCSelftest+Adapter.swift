import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension SIWCSelftest {
    /// Captured SIWC sends (the network seam).
    final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        var replies: [Result<Data, Error>] = []
        var delayNanos: UInt64 = 0
        func install() {
            ResponsesAdapter.siwcSendOverride = { [self] request in
                lock.lock(); requests.append(request)
                let reply = replies.isEmpty ? Result<Data, Error>.failure(ResponsesFailure.disconnected) : replies.removeFirst()
                let delay = delayNanos
                lock.unlock()
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                return try reply.get()
            }
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
        func body(_ i: Int) -> [String: JSONValue] {
            lock.lock(); defer { lock.unlock() }
            return (try? JSONDecoder().decode(JSONValue.self, from: requests[i].httpBody ?? Data()))?.responsesObject ?? [:]
        }
    }

    static func completed(text: String? = "OK", calls: [(String, String?)] = []) -> Data {
        var output: [[String: Any]] = []
        if let text {
            output.append(["type": "message", "id": "msg_1", "role": "assistant", "status": "completed",
                           "content": [["type": "output_text", "text": text, "annotations": []]]])
        }
        for (i, call) in calls.enumerated() {
            var item: [String: Any] = ["type": "function_call", "id": "fc_\(i)", "call_id": "call_\(i)", "name": call.0, "arguments": "{}", "status": "completed"]
            if let ns = call.1 { item["namespace"] = ns }
            output.append(item)
        }
        let object: [String: Any] = ["id": "resp_1", "status": "completed", "output": output,
                                     "usage": ["input_tokens": 10, "output_tokens": 2, "input_tokens_details": ["cached_tokens": 0]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func receipt() -> PreparedRequestReceipt {
        PreparedRequestReceipt(requestID: UUID(), historyFingerprint: "fp", deliveryNonces: [])
    }

    static let readTool = ToolDefinition(function: FunctionDefinition(name: "read_file", description: "Read a file",
        parameters: FunctionParameters(properties: ["path": ParameterProperty(type: "string", description: "path")], required: ["path"])))

    /// Adapter wire shape, headers, `session_id`, namespace decode, errors.
    static func adapterTests(_ root: URL, _ c: Checks) async throws {
        let (source, _) = try await liveSelection(clientId: "oaiappAdapter")
        let wire = Wire(); wire.install()
        let context = ProviderExecutionContext.siwcContext(source: source, model: "gpt-6.1-sol", effort: "high", lane: .main,
                                                           textOnly: false, nativeToolMedia: false)
        var adapter = ResponsesAdapter(context: context)
        let prompt = "You are Bree."
        adapter.typedPrompt = prompt
        let input = [sys(prompt), user("hello"), sys("[Ambient status] x")]
        wire.replies = [.success(completed())]
        let answer = try await adapter.send(input: input, tools: [readTool], receipt: receipt(), maxOutputTokens: 512)
        guard wire.count == 1 else { c.check("adapter: one send", false); return }
        let request = wire.requests[0], body = wire.body(0)
        c.check("adapter: POST https://api.openai.com/v1/responses", request.url?.absoluteString == SIWCEndpoint.responsesURL && request.httpMethod == "POST")
        c.check("adapter: bearer from the SIWC store", request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access-live-oaiappAdapter")
        c.check("adapter: no legacy-only headers (originator, ChatGPT-Account-Id, x-codex-turn-state)",
                request.value(forHTTPHeaderField: "originator") == nil && request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil
                && request.value(forHTTPHeaderField: ResponsesTurn.header) == nil)
        let sessionId = request.value(forHTTPHeaderField: "session_id")
        c.check("adapter: session_id present and equal to prompt_cache_key", sessionId != nil && sessionId == body["prompt_cache_key"]?.responsesString)
        c.check("adapter: Accept text/event-stream, User-Agent set", request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
                && request.value(forHTTPHeaderField: "User-Agent") == SessionAffinity.userAgent)
        c.check("adapter: instructions = typed prompt; other system notes kept", body["instructions"]?.responsesString == prompt
                && body["input"]?.responsesArray?.count == 2)
        c.check("adapter: no truncation / max_output_tokens even when asked", body["truncation"] == nil && body["max_output_tokens"] == nil)
        c.check("adapter: store false, stream true, encrypted reasoning, effort", { if case .bool(false)? = body["store"], case .bool(true)? = body["stream"] { return true }; return false }()
                && encode(body).contains("reasoning.encrypted_content") && body["reasoning"]?.responsesObject?["effort"]?.responsesString == "high")
        c.check("adapter: tools in the briglia namespace", body["tools"]?.responsesArray?.first?.responsesObject?["name"]?.responsesString == "briglia")
        c.check("adapter: answer decoded, no API spend", { if case .text("OK", _, _, _, _, let spend, _, _) = answer { return spend == nil }; return false }())
        // session_id stability and scope.
        wire.replies = [.success(completed()), .success(completed())]
        _ = try await adapter.send(input: input, tools: nil, receipt: receipt())
        var other = context; other = ProviderExecutionContext.siwcContext(source: source, model: "gpt-6.1-sol", effort: "high", lane: .subagent("s1"),
                                                                          textOnly: false, nativeToolMedia: false)
        _ = try await ResponsesAdapter(context: other).send(input: [user("x")], tools: nil, receipt: receipt())
        c.check("session_id: stable across requests of one operation lane", wire.requests[1].value(forHTTPHeaderField: "session_id") == sessionId)
        c.check("session_id: another lane gets another id", wire.requests[2].value(forHTTPHeaderField: "session_id") != sessionId)
        let legacyDerived = SessionAffinity.wireId(state: try SessionAffinity.loadState(), apiKey: "briglia-subscription-v1:" + source.generation, lane: .main)
        c.check("session_id: never the legacy derivation", sessionId != legacyDerived)
        let (sourceB, _) = try await liveSelection(clientId: "oaiappAdapterB", sub: "user-sub-B")
        c.check("session_id: differs between registrations", (try? ResponsesAdapter.siwcSessionId(sourceB, lane: .main)) != sessionId)
        let apiCtx = ProviderExecutionContext.responsesAPI(baseURL: "https://api.openai.com/v1", key: "sk-test-synthetic", model: "gpt-6.1-sol", lane: .main)
        c.check("session_id: API-key requests carry none", (try? ResponsesAdapter(context: apiCtx).request(input: [user("x")], tools: nil))?.value(forHTTPHeaderField: "session_id") == nil)
        // Re-select A for the remaining checks.
        let (sourceA2, _) = try await liveSelection(clientId: "oaiappAdapter")
        let ctxA = ProviderExecutionContext.siwcContext(source: sourceA2, model: "gpt-6.1-sol", effort: nil, lane: .main, textOnly: false, nativeToolMedia: false)
        // Namespace decode.
        func roundCalls(_ calls: [(String, String?)]) async -> Result<LLMResponse, Error> {
            wire.replies = [.success(completed(text: nil, calls: calls))]
            do { return .success(try await ResponsesAdapter(context: ctxA).send(input: [user("x")], tools: [readTool], receipt: receipt())) }
            catch { return .failure(error) }
        }
        if case .success(.toolCalls(_, let calls, _, _, _)) = await roundCalls([("read_file", "briglia"), ("read_file", "briglia")]) {
            c.check("decode: parallel namespaced calls accepted", calls.count == 2)
        } else { c.check("decode: parallel namespaced calls accepted", false) }
        c.check("decode: a missing namespace is rejected", { if case .failure = $0 { return true }; return false }(await roundCalls([("read_file", nil)])))
        c.check("decode: an unknown namespace is rejected even with a known name", { if case .failure = $0 { return true }; return false }(await roundCalls([("read_file", "evil")])))
        c.check("decode: an unknown tool is rejected", { if case .failure = $0 { return true }; return false }(await roundCalls([("rm_rf", "briglia")])))
        // Errors.
        func failing(_ error: Error, _ replies: [Result<Data, Error>] = []) async -> (Error?, Int) {
            let before = wire.count
            wire.replies = [.failure(error)] + replies
            do { _ = try await ResponsesAdapter(context: ctxA).send(input: [user("x")], tools: nil, receipt: receipt()); return (nil, wire.count - before) }
            catch { return (error, wire.count - before) }
        }
        let limit = await failing(SIWCErrors.classify(status: 429, body: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#.utf8))!)
        // Stage D: the plan-state gate would also stop a retried send, so the
        // row checks that the answer reported is the server's own (a retry
        // would end on the gate's paused message instead).
        c.check("errors: usage limit → no retry, no API billing, limit message", (limit.0 as? SIWCError)?.kind == .limitReached && limit.1 == 1
                && (limit.0 as? SIWCError)?.message == SIWCError.limitMessage)
        // Stage D: that answer paused the plan for background lanes; the rows
        // below exercise the transport itself, so they start from a fresh state.
        clearPlanState(sourceA2.store)
        let refused = await failing(SIWCErrors.classify(status: 400, body: Data(#"{"detail":"System messages are not allowed"}"#.utf8))!)
        c.check("errors: a system-item refusal stops the request (no resend, no rewrite)", (refused.0 as? SIWCError)?.kind == .routeIncompatible && refused.1 == 1)
        let unsupported = await failing(SIWCErrors.classify(status: 400, body: Data(#"{"error":{"code":"unsupported_capability","param":"input[3]"}}"#.utf8))!)
        c.check("errors: unsupported_capability → param reported, not retried", (unsupported.0 as? SIWCError)?.parameter == "input[3]" && unsupported.1 == 1)
        let transient = await failing(SIWCErrors.classify(status: 503, body: Data(#"{"error":{"code":"usage_unavailable"}}"#.utf8))!, [.success(completed())])
        c.check("errors: usage_unavailable keeps credentials and retries (bounded)", transient.0 == nil && transient.1 == 2)
        // 401 → one refresh (fake token endpoint), one retry; a second 401
        // requires sign-in, no fallback.
        let fake = FakeAuth()
        fake.tokenReplies = [tokenReply("refreshed", idToken: nil)]
        SIWCAuthClient.sendOverride = fake.client.send
        let unauth = await failing(ResponsesFailure.http(401, nil), [.failure(ResponsesFailure.http(401, nil))])
        c.check("errors: 401 → exactly one refresh, one retry", fake.tokenCount() == 1 && unauth.1 == 2
                && fake.tokenRequests.first?.contains("grant_type=refresh_token") == true && fake.tokenRequests.first?.contains("resource=") == true
                && fake.tokenRequests.first?.contains("scope=") == false)
        c.check("errors: a second 401 after the refresh requires sign-in, no fallback", (unauth.0 as? SIWCError)?.kind == .signInRequired)
        // Pre-send: a tombstoned login sends nothing.
        let (sourceT, _) = try await liveSelection(clientId: "oaiappAdapterT", sub: "user-sub-T")
        let ctxT = ProviderExecutionContext.siwcContext(source: sourceT, model: "gpt-6.1-sol", effort: nil, lane: .main, textOnly: false, nativeToolMedia: false)
        _ = try await sourceT.store.tombstone(sourceT.clientId)
        let before = wire.count
        wire.replies = [.success(completed())]
        await c.rejectsKind("presend: a tombstoned login sends nothing (on-disk generation)", .signInRequired) {
            _ = try await ResponsesAdapter(context: ctxT).send(input: [user("x")], tools: nil, receipt: receipt())
        }
        c.check("presend: zero sends after the tombstone", wire.count == before)
        wire.replies = []
        _ = root
    }

    /// Sign-out stops running jobs (§3.7, §3.9 R2): fence, cancel, no revival.
    static func adapterSignOutTests(_ root: URL, _ c: Checks) async throws {
        let (source, secrets) = try await liveSelection(clientId: "oaiappStop")
        let wire = Wire(); wire.install()
        let ctx = ProviderExecutionContext.siwcContext(source: source, model: "gpt-6.1-sol", effort: nil, lane: .main, textOnly: false, nativeToolMedia: false)
        wire.delayNanos = 800_000_000
        wire.replies = [.success(completed(text: "late answer"))]
        let running = Task { try await ResponsesAdapter(context: ctx).send(input: [user("x")], tools: nil, receipt: receipt()) }
        try await Task.sleep(nanoseconds: 200_000_000)
        SIWCFence.shared.fenceAndBump(source.fenceKey)
        let cancelledCount = SIWCFence.shared.cancelAll(source.fenceKey)
        let result = await running.result
        c.check("signout: a running stream is cancelled", cancelledCount == 1)
        c.check("signout: the job ends signed out; the partial answer is not delivered",
                { if case .failure(let e as SIWCError) = result { return e.kind == .signedOut }; return false }())
        wire.delayNanos = 0
        let before = wire.count
        wire.replies = [.success(completed())]
        await c.rejectsKind("signout: the next round cannot send (fenced)", .signedOut) {
            _ = try await ResponsesAdapter(context: ctx).send(input: [user("x")], tools: nil, receipt: receipt())
        }
        c.check("signout: zero sends after the fence", wire.count == before)
        SIWCFence.shared.unfence(source.fenceKey)
        await c.rejectsKind("signout: a job that captured the old epoch is not revived by unfencing", .signedOut) {
            _ = try await ResponsesAdapter(context: ctx).send(input: [user("x")], tools: nil, receipt: receipt())
        }
        // A new operation captures a fresh source (new epoch) and works.
        let fresh = ProviderExecutionContext.siwcFromStored(secrets, model: "gpt-6.1-sol", effort: nil, lane: .main, textOnly: false)!
        wire.replies = [.success(completed())]
        c.check("signout: a new operation start captures the new epoch", (try? await ResponsesAdapter(context: fresh).send(input: [user("x")], tools: nil, receipt: receipt())) != nil)
        // /provider switch mid-turn: the captured route still finishes.
        try KeychainHelper.save(key: ChatGPTRoute.routeKey, value: "legacy")
        wire.replies = [.success(completed())]
        c.check("route: a /provider switch mid-operation keeps the captured SIWC route", (try? await ResponsesAdapter(context: fresh).send(input: [user("x")], tools: nil, receipt: receipt())) != nil)
        try KeychainHelper.save(key: ChatGPTRoute.routeKey, value: "siwc")
        // Another registration is unaffected by A's fence.
        let (sourceB, _) = try await liveSelection(clientId: "oaiappStopB", sub: "user-sub-B")
        SIWCFence.shared.fenceAndBump(source.fenceKey)
        let ctxB = ProviderExecutionContext.siwcContext(source: sourceB, model: "gpt-6.1-sol", effort: nil, lane: .main, textOnly: false, nativeToolMedia: false)
        wire.replies = [.success(completed())]
        c.check("signout: another registration keeps working", (try? await ResponsesAdapter(context: ctxB).send(input: [user("x")], tools: nil, receipt: receipt())) != nil)
        for key in secrets.keys { try? KeychainHelper.delete(key: key) }
        _ = root
    }
}
