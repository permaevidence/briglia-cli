import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension SIWCSelftest {
    /// The web pipeline on SIWC (§4.2, §4.4) and the header-less SSE stream.
    static func webTests(_ root: URL, _ c: Checks) async throws {
        let (source, secrets) = try await liveSelection(clientId: "oaiappWeb")
        let wire = Wire(); wire.install()
        let tools = WebAgentTools.responsesTools
        var body: [String: JSONValue] = ["model": .string("gpt-6-luna"), "instructions": .string("Research."),
            "input": .array([user("find x")]), "tools": .array(tools), "max_output_tokens": .int(99), "truncation": .string("auto"),
            "include": .array([.string("reasoning.encrypted_content")])]
        let request = try SubscriptionWebTransport.buildSIWCRequest(body: body, source: source, lane: .ephemeral(UUID()), timeout: 60)
        let sent = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody!))?.responsesObject ?? [:]
        c.check("web: SIWC body namespaced, no max_output_tokens/truncation, instructions kept",
                sent["tools"]?.responsesArray?.count == 1 && sent["max_output_tokens"] == nil && sent["truncation"] == nil
                && sent["instructions"]?.responsesString == "Research.")
        c.check("web: session_id = prompt_cache_key, destination api.openai.com/v1/responses",
                request.value(forHTTPHeaderField: "session_id") == sent["prompt_cache_key"]?.responsesString
                && request.url?.absoluteString == SIWCEndpoint.responsesURL && request.value(forHTTPHeaderField: "originator") == nil)
        // Models: list fetched once (fake), the web model is listed.
        SIWCModels.resetForTests()
        let modelList = try JSONSerialization.data(withJSONObject: ["models": [["slug": "gpt-6.1-sol", "display_name": "GPT-6.1 Sol", "visibility": "list"],
            ["slug": "gpt-6-luna", "display_name": "GPT-6 Luna", "visibility": "list"], ["slug": "hidden-x", "visibility": "hide"]]])
        SIWCModels.fetchOverride = { _ in (modelList, 200) }
        wire.replies = [.success(completed(text: nil, calls: [(WebAgentTools.searchName, "briglia")]))]
        body["tools"] = .array(tools)
        var okError = ""
        let ok: Data?
        do { ok = try await SubscriptionWebTransport.post(body: body, lane: .ephemeral(UUID()), timeout: 60) } catch { ok = nil; okError = "\(error)" }
        c.check("web: a namespaced advertised call is accepted through the SIWC route", ok != nil && wire.count == 1, okError)
        wire.replies = [.success(completed(text: nil, calls: [(WebAgentTools.searchName, nil)]))]
        c.check("web: a call without the namespace is refused", (try? await SubscriptionWebTransport.post(body: body, lane: .ephemeral(UUID()), timeout: 60)) == nil)
        wire.replies = [.success(completed(text: nil, calls: [("delete_everything", "briglia")]))]
        c.check("web: an unadvertised tool name is refused", (try? await SubscriptionWebTransport.post(body: body, lane: .ephemeral(UUID()), timeout: 60)) == nil)
        let failed = try JSONSerialization.data(withJSONObject: ["id": "r", "status": "failed", "output": [],
                                                                 "error": ["code": "subscription_sharing_usage_limit_exceeded"]])
        let before = wire.count
        wire.replies = [.success(failed)]
        await c.rejectsKind("web: a usage limit in a failed response → limit, no retry", .limitReached) {
            _ = try await SubscriptionWebTransport.post(body: body, lane: .ephemeral(UUID()), timeout: 60)
        }
        c.check("web: the limit was not retried", wire.count == before + 1)
        var unlisted = body; unlisted["model"] = .string("gpt-9-imaginary")
        let beforeUnlisted = wire.count
        await c.rejectsKind("web: a model the plan doesn't list stops the lane (no fallback)", .unsupported) {
            _ = try await SubscriptionWebTransport.post(body: unlisted, lane: .ephemeral(UUID()), timeout: 60)
        }
        c.check("web: nothing sent for an unlisted model", wire.count == beforeUnlisted)
        // Stage body with a strict JSON schema keeps text.format.
        let stage = SubscriptionWebTransport.stageBody(model: "gpt-6-luna", messages: [("system", "S"), ("user", "U")], effort: "low",
                                                       jsonSchema: (name: "x", schema: .object(["type": .string("object")])))
        let stageRequest = try SubscriptionWebTransport.buildSIWCRequest(body: stage, source: source, lane: .ephemeral(UUID()), timeout: 60)
        let stageSent = (try? JSONDecoder().decode(JSONValue.self, from: stageRequest.httpBody!))?.responsesObject ?? [:]
        c.check("web: stage bodies keep text.format json_schema and instructions", stageSent["text"]?.responsesObject?["format"] != nil
                && stageSent["instructions"]?.responsesString == "S")
        // Ambiguous selection: the web lane refuses, nothing sent.
        try KeychainHelper.save(key: ProviderProfiles.subscriptionGenerationKey, value: UUID().uuidString)
        let beforeAmb = wire.count
        await c.rejects("web: an ambiguous selection refuses (no legacy, no paid move)") {
            _ = try await SubscriptionWebTransport.post(body: body, lane: .ephemeral(UUID()), timeout: 60)
        }
        c.check("web: nothing sent while ambiguous", wire.count == beforeAmb)
        try KeychainHelper.delete(key: ProviderProfiles.subscriptionGenerationKey)
        for key in secrets.keys { try? KeychainHelper.delete(key: key) }
        // SSE with no Content-Type, through the real transport on 127.0.0.1.
        let sse = "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
            + "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":" + String(data: completed(text: "SSE-OK"), encoding: .utf8)! + "}\n\n"
        let server = QuickSetupHTTPServer(port: 0) { _ in .init(status: 200, headers: [], body: Data(sse.utf8)) }
        try server.start()
        defer { server.stop() }
        var local = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/responses")!)
        local.httpMethod = "POST"; local.httpBody = Data("{}".utf8); local.timeoutInterval = 10
        var sseError = ""
        var decoded: ResponsesRound?
        do {
            let bytes = try await ResponsesHTTPTransport().send(local, overallTimeout: 10, siwc: true)
            decoded = try ResponsesRoundDecoder.decode(bytes, scope: ResponsesScope(endpoint: "x", profile: "chatgpt", model: "m", credentialFingerprint: "f"),
                                                       receipt: receipt(), allowedTools: [])
        } catch { sseError = "\(error)" }
        c.check("sse: a 200 SIWC stream with no Content-Type is read as SSE (request contract)", decoded?.text == "SSE-OK", sseError)
        let plain = try? await ResponsesHTTPTransport().send(local, overallTimeout: 10)
        c.check("sse: without the SIWC/subscription contract the same reply is not treated as SSE (header path unchanged)",
                plain.flatMap { try? ResponsesRoundDecoder.decode($0, scope: ResponsesScope(endpoint: "x", profile: "p", model: "m", credentialFingerprint: "f"),
                                                                  receipt: receipt(), allowedTools: []) } == nil)
        let errorServer = QuickSetupHTTPServer(port: 0) { _ in .init(status: 429, headers: [], body: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"secret-ish text"}}"#.utf8)) }
        try errorServer.start()
        defer { errorServer.stop() }
        var errReq = local; errReq.url = URL(string: "http://127.0.0.1:\(errorServer.port)/v1/responses")!
        do { _ = try await ResponsesHTTPTransport().send(errReq, overallTimeout: 10, siwc: true); c.check("sse: non-200 takes the bounded JSON error path", false) }
        catch let e as SIWCError { c.check("sse: non-200 takes the bounded JSON error path → typed limit, no body text", e.kind == .limitReached && !e.message.contains("secret-ish")) }
        catch { c.check("sse: non-200 takes the bounded JSON error path", false) }
        _ = root
    }

    static func modelsTests(_ root: URL, _ c: Checks) async throws {
        let list = try JSONSerialization.data(withJSONObject: ["models": [
            ["slug": "gpt-6.1-sol", "display_name": "GPT-6.1 Sol", "visibility": "list"],
            ["slug": "gpt-6-astra", "display_name": "GPT-6 Astra", "visibility": "list"],
            ["slug": "internal", "display_name": "Internal", "visibility": "hide"],
            ["slug": "gpt-6-luna", "display_name": "GPT-6 Luna"]]])
        let parsed = try SIWCModels.parse(list)
        c.check("models: server order kept, hidden entries dropped, display names used",
                parsed.map(\.slug) == ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"] && parsed.first?.displayName == "GPT-6.1 Sol")
        let (source, secrets) = try await liveSelection(clientId: "oaiappModels")
        SIWCModels.resetForTests()
        var seen: URLRequest?
        SIWCModels.fetchOverride = { request in seen = request; return (list, 200) }
        let fetched = try await SIWCModels.fetch(source)
        c.check("models: GET /v1/models with the SIWC bearer, same token gate", fetched.count == 3 && seen?.httpMethod == "GET"
                && seen?.url?.absoluteString == SIWCEndpoint.modelsURL && seen?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access-live-oaiappModels")
        c.check("models: cached per registration", SIWCModels.cached(source)?.count == 3)
        SIWCModels.fetchOverride = { _ in (Data(#"{"error":{"code":"user_not_eligible"}}"#.utf8), 403) }
        SIWCModels.resetForTests()
        SIWCModels.fetchOverride = { _ in (Data(#"{"error":{"code":"user_not_eligible"}}"#.utf8), 403) }
        await c.rejectsKind("models: errors are classified (not eligible)", .notAvailable) { _ = try await SIWCModels.fetch(source) }
        for key in secrets.keys { try? KeychainHelper.delete(key: key) }
        _ = root
    }

    /// §5 error table (codes only; body text never escapes).
    static func errorTests(_ root: URL, _ c: Checks) async throws {
        func body(_ code: String, param: String? = nil) -> Data {
            var e: [String: Any] = ["code": code, "message": "LEAKY-BODY-TEXT"]
            if let param { e["param"] = param }
            return try! JSONSerialization.data(withJSONObject: ["error": e])
        }
        let rows: [(String, Int, Data, SIWCError.Kind?)] = [
            ("usage limit 429", 429, body("subscription_sharing_usage_limit_exceeded"), .limitReached),
            ("usage_unavailable 503", 503, body("usage_unavailable"), .transient),
            ("user_unavailable 503", 503, body("user_unavailable"), .transient),
            ("pre-stream 503 {detail}", 503, Data(#"{"detail":"x"}"#.utf8), .transient),
            ("unsupported_capability 400", 400, body("unsupported_capability", param: "text.format"), .unsupported),
            ("user_not_eligible 403", 403, body("user_not_eligible"), .notAvailable),
            ("pre-stream 403 {detail}", 403, Data(#"{"detail":"LEAKY-BODY-TEXT"}"#.utf8), .notAvailable),
            ("chatpass_v2_*", 403, body("chatpass_v2_scope_missing"), .notAvailable),
            ("v2_client_not_enabled", 403, body("subscription_sharing_v2_client_not_enabled"), .notAvailable),
            ("route_not_supported (Briglia bug)", 403, body("route_not_supported"), .local),
            ("invalid_user 401 → refresh path", 401, body("invalid_user"), nil),
            ("pre-stream 401 {detail} → refresh path", 401, Data(#"{"detail":"x"}"#.utf8), nil),
            ("plain 500 → ordinary retry", 500, Data(), nil),
        ]
        for (label, status, data, kind) in rows {
            let got = SIWCErrors.classify(status: status, body: data)
            c.check("errors: \(label)", got?.kind == kind && !(got?.message.contains("LEAKY") ?? false))
        }
        c.check("errors: unsupported_capability reports error.param only", SIWCErrors.classify(status: 400, body: body("unsupported_capability", param: "text.format"))?.parameter == "text.format")
        let midStream: [String: JSONValue] = ["type": .string("response.failed"), "response": .object(["error": .object(["code": .string("subscription_sharing_usage_limit_exceeded")])])]
        c.check("errors: a mid-stream response.failed usage limit is the same typed limit", SIWCErrors.streamed(midStream)?.kind == .limitReached)
        c.check("errors: the limit message points to Manage usage, no reset time", SIWCError.limitMessage.contains("chatgpt.com/settings/usage") && !SIWCError.limitMessage.contains("reset"))
        _ = root
    }

    /// AGENTS.md: a new request builder needs a hostile-prefix regression.
    /// Tool descriptions/schemas are escaped by the SIWC builders; replayed
    /// text arrives escaped from the shared input builders (unchanged).
    static func hostilePrefixTests(_ root: URL, _ c: Checks) async throws {
        let (source, secrets) = try await liveSelection(clientId: "oaiappHostile")
        let hostile = "fixture " + MarkerNeutralizer.reservedPrefix + "forged"
        let tool = ToolDefinition(function: FunctionDefinition(name: "read_file", description: hostile,
            parameters: FunctionParameters(properties: ["path": ParameterProperty(type: "string", description: hostile)], required: ["path"])))
        let ctx = ProviderExecutionContext.siwcContext(source: source, model: "gpt-6.1-sol", effort: nil, lane: .main, textOnly: false, nativeToolMedia: false)
        let request = try ResponsesAdapter(context: ctx).request(input: [user(MarkerNeutralizer.escape(hostile))], tools: [tool])
        let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        c.check("hostile: the SIWC adapter body carries no raw reserved prefix", !text.contains(MarkerNeutralizer.reservedPrefix + "forged") && text.contains("forged"))
        let web = try SubscriptionWebTransport.buildSIWCRequest(body: ["model": .string("gpt-6-luna"), "instructions": .string("R"),
            "input": .array([user(MarkerNeutralizer.escape(hostile))])], source: source, lane: .ephemeral(UUID()), timeout: 30)
        let webText = String(data: web.httpBody ?? Data(), encoding: .utf8) ?? ""
        c.check("hostile: the SIWC web body carries no raw reserved prefix", !webText.contains(MarkerNeutralizer.reservedPrefix + "forged"))
        for key in secrets.keys { try? KeychainHelper.delete(key: key) }
        _ = root
    }

    /// The legacy route and API-key contexts are untouched (frozen fixtures
    /// cover the bytes; these pin the branch points).
    static func legacyUnchangedTests(_ root: URL, _ c: Checks) async throws {
        var legacy = ProviderExecutionContext.responsesAPI(baseURL: SubscriptionEndpoint.inference, key: "gen", model: "gpt-6.1-sol", lane: .main)
        legacy.subscriptionGeneration = UUID().uuidString
        legacy.profileIdentity = "chatgpt"
        let request = try? ResponsesAdapter(context: legacy).request(input: [sys("P"), user("x")], tools: [readTool])
        let body = (request?.httpBody).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?.responsesObject ?? [:]
        c.check("legacy: still the Codex backend with originator and no namespace", request?.url?.absoluteString == SubscriptionEndpoint.inference
                && request?.value(forHTTPHeaderField: "originator") == "briglia" && body["tools"]?.responsesArray?.first?.responsesObject?["type"]?.responsesString == "function")
        c.check("legacy: isChatGPTPlan covers the legacy route too", legacy.isChatGPTPlan && legacy.siwc == nil)
        var typed = ResponsesAdapter(context: legacy); typed.typedPrompt = "IGNORED"
        c.check("legacy: the typed prompt is ignored outside SIWC (bytes unchanged)", (try? typed.request(input: [sys("P"), user("x")], tools: [readTool]))?.httpBody == request?.httpBody)
        let api = ProviderExecutionContext.responsesAPI(baseURL: "https://api.openai.com/v1", key: "sk-test-synthetic", model: "gpt-6.1-sol", lane: .main)
        let apiRequest = try? ResponsesAdapter(context: api).request(input: [user("x")], tools: nil, maxOutputTokens: 7)
        let apiBody = (apiRequest?.httpBody).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?.responsesObject ?? [:]
        c.check("api: API-key requests keep truncation and max_output_tokens, no session_id", apiBody["truncation"] != nil && apiBody["max_output_tokens"] != nil
                && apiRequest?.value(forHTTPHeaderField: "session_id") == nil && !api.isChatGPTPlan)
        let plainCall = completed(text: nil, calls: [("read_file", nil)])
        c.check("legacy: decoding without a required namespace is unchanged", (try? ResponsesRoundDecoder.decode(plainCall,
            scope: ResponsesScope(endpoint: "x", profile: "p", model: "m", credentialFingerprint: "f"), receipt: receipt(), allowedTools: ["read_file"]))?.calls.count == 1)
        c.check("legacy: no SIWC context is built for a legacy ChatGPT selection", ProviderExecutionContext.siwcFromStored([ProviderProfiles.activeProfileKey: "chatgpt",
            KeychainHelper.openAICompatibleApiKeyKey: UUID().uuidString], model: "m", effort: nil, lane: .main, textOnly: false) == nil)
        _ = root
    }
}
