import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Group 16: web research follows the ChatGPT subscription (owner decision
// 2026-09-23) and runs GPT-6 Luna. The subscription endpoint is pinned and
// its credential store is real, so the network send is replaced through the
// development-build seam `SubscriptionWebTransport.sendOverride`; the
// requests it captures are exactly what the transport would put on the wire
// (minus the per-request bearer and account headers).
extension WebSubagentSelftest {
    static func runSubscriptionGroups(_ h: Harness) async throws {
        print("16. ChatGPT subscription follow + GPT-6 Luna")
        let check = h.check
        let keys = [ProviderProfiles.activeProfileKey, KeychainHelper.llmProviderKey, KeychainHelper.openAICompatibleApiKeyKey]
        let snapshot = KeychainHelper.loadSnapshot()
        let savedOverride = WebSearchBackend.processOverride
        let savedVolatile = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            for key in keys {
                if let value = snapshot[key] { try? KeychainHelper.save(key: key, value: value) }
                else { try? KeychainHelper.delete(key: key) }
            }
            WebSearchBackend.processOverride = savedOverride
            UserDefaults.standard.setVolatileDomain(savedVolatile, forName: UserDefaults.argumentDomain)
            SubscriptionWebTransport.resetForTests()
        }
        func body(_ request: URLRequest) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
        }
        final class Captured: @unchecked Sendable {
            private let lock = NSLock(); private var items: [URLRequest] = []
            func add(_ r: URLRequest) { lock.lock(); items.append(r); lock.unlock() }
            var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return items }
            func clear() { lock.lock(); items = []; lock.unlock() }
        }
        let captured = Captured()

        // 16.1 Defaults moved to GPT-6 Luna (web stages, researcher default, OCR).
        check("16.1 GPT-6 Luna everywhere by default: extraction, deep excerpt, web_fetch compression, the web model and the OCR preprocessor",
              ORModel.webExcerpts == "openai/gpt-6-luna" && ORModel.deepExcerpt == "openai/gpt-6-luna"
              && ORModel.webFetchCompression == "openai/gpt-6-luna" && KeychainHelper.defaultWebSearchModel == "openai/gpt-6-luna"
              && KeychainHelper.defaultVisionPreprocessorModel == "openai/gpt-6-luna", "")
        let r6 = WebOrchestrator.openAIRates(forModel: "openai/gpt-6-luna"), r56 = WebOrchestrator.openAIRates(forModel: "gpt-5.6-luna")
        check("16.2 spend estimate: GPT-6 Luna at $0.10/$0.50, GPT-5.6 Luna kept at $0.20/$1.20; the >272K surcharge still applies",
              r6 == (0.10, 0.50) && r56 == (0.20, 1.20)
              && abs((WebOrchestrator().estimatedOpenAISpendUSD(model: "gpt-6-luna", promptTokens: 100_000, completionTokens: 100_000) ?? 0) - 0.06) < 1e-9
              && abs((WebOrchestrator().estimatedOpenAISpendUSD(model: "gpt-6-luna", promptTokens: 300_000, completionTokens: 0) ?? 0) - 0.06) < 1e-9,
              "\(r6) \(r56)")

        // 16.3 The pure follow rule.
        let sub: [String: String] = [ProviderProfiles.activeProfileKey: "chatgpt",
                                     KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
                                     KeychainHelper.openAICompatibleApiKeyKey: "gen-fixture"]
        var other = sub; other[ProviderProfiles.activeProfileKey] = "openai"
        var noGeneration = sub; noGeneration[KeychainHelper.openAICompatibleApiKeyKey] = " "
        var routerMain = sub; routerMain[KeychainHelper.llmProviderKey] = LLMProvider.openRouter.rawValue
        check("16.3 follow rule: only the active ChatGPT subscription profile with a login generation; never while exhausted",
              WebSearchBackend.followsSubscription(stored: sub, exhausted: false)
              && !WebSearchBackend.followsSubscription(stored: sub, exhausted: true)
              && !WebSearchBackend.followsSubscription(stored: other, exhausted: false)
              && !WebSearchBackend.followsSubscription(stored: noGeneration, exhausted: false)
              && !WebSearchBackend.followsSubscription(stored: routerMain, exhausted: false), "")
        check("16.4 chatgpt is never a stored choice: parseSelectable and resolve reject it; the selectable list is unchanged",
              WebSearchBackend.parseSelectable("chatgpt") == nil && WebSearchBackend.parseSelectable("openai") == .openai
              && WebSearchBackend.resolve(override: nil, stored: "chatgpt", hasOpenAIKey: true, hasLegacyOpenRouterKey: false) == .openai
              && WebSearchBackend.resolve(override: nil, stored: "chatgpt", hasOpenAIKey: false, hasLegacyOpenRouterKey: false) == .opencode
              && WebSearchBackend.selectable == [.openai, .opencode, .openrouter], "")

        // Make the subscription the main provider in the isolated store, with
        // an explicit configured web backend = opencode (served by fixture B).
        for (key, value) in sub { try KeychainHelper.save(key: key, value: value) }
        var volatile = savedVolatile
        volatile[WebSearchBackend.selectionKey] = WebSearchBackend.opencode.rawValue
        UserDefaults.standard.setVolatileDomain(volatile, forName: UserDefaults.argumentDomain)
        WebSearchBackend.processOverride = nil
        SubscriptionWebTransport.resetForTests()
        check("16.5 active follows the subscription; configured stays the stored choice; exhaustion hands back to it; the cooldown expires",
              WebSearchBackend.active == .chatgpt && WebSearchBackend.configured == .opencode
              && { SubscriptionWebTransport.markExhausted(); defer { SubscriptionWebTransport.resetForTests() }
                   return WebSearchBackend.active == .opencode && SubscriptionWebTransport.isExhausted()
                       && !SubscriptionWebTransport.isExhausted(now: Date().addingTimeInterval(SubscriptionWebTransport.exhaustionCooldown + 1)) }()
              && WebSearchBackend.storedKey(for: .chatgpt) == "gen-fixture", "\(WebSearchBackend.active)")
        let usage = SubscriptionEndpoint.providerError(status: 429, body: Data("{\"error\":{\"code\":\"usage_limit_reached\"}}".utf8))
        check("16.6 a usage_limit_reached response is typed as exhausted and arms the web cooldown; other provider errors do not",
              usage?.usageExhausted == true && SubscriptionWebTransport.isExhausted()
              && SubscriptionEndpoint.providerError(status: 404, body: Data("{\"error\":{\"code\":\"model_not_found\"}}".utf8))?.usageExhausted == false,
              "")
        SubscriptionWebTransport.resetForTests()

        // 16.7 Request construction (pure).
        let request = try SubscriptionWebTransport.buildRequest(
            body: ["model": .string("gpt-6-luna"), "input": .array([]), "max_output_tokens": .int(9), "truncation": .string("auto")],
            generation: "gen-fixture", lane: .ephemeral(UUID()), timeout: 120)
        let b = body(request)
        check("16.7 subscription request: pinned endpoint, streamed, store:false, no max_output_tokens/truncation, instructions, cache key = session_id, originator, no bearer from the builder",
              request.url?.absoluteString == SubscriptionEndpoint.inference && b["stream"] as? Bool == true && b["store"] as? Bool == false
              && b["max_output_tokens"] == nil && b["truncation"] == nil && (b["instructions"] as? String)?.isEmpty == false
              && (b["prompt_cache_key"] as? String).map { $0 == request.value(forHTTPHeaderField: "session_id") } == true
              && request.value(forHTTPHeaderField: "originator") == "briglia" && request.value(forHTTPHeaderField: "Authorization") == nil
              && request.value(forHTTPHeaderField: "Accept") == "text/event-stream", "\(b.keys.sorted())")
        let stage = SubscriptionWebTransport.stageBody(model: "gpt-6-luna",
            messages: [(role: "system", text: "SYS"), (role: "user", text: "U"), (role: "assistant", text: "A")],
            effort: "medium", jsonSchema: (name: "excerpts", schema: .object(["type": .string("object")])))
        let fmt = stage["text"]?.objectValue?["format"]?.objectValue
        let input = stage["input"]?.arrayValue ?? []
        check("16.8 stage body: system → instructions, user/assistant as input_text/output_text, effort, strict json_schema text.format",
              stage["instructions"]?.stringValue == "SYS" && input.count == 2
              && input[0].objectValue?["role"]?.stringValue == "user" && input[1].objectValue?["role"]?.stringValue == "assistant"
              && stage["reasoning"]?.objectValue?["effort"]?.stringValue == "medium"
              && fmt?["type"]?.stringValue == "json_schema" && fmt?["name"]?.stringValue == "excerpts" && { if case .bool(true)? = fmt?["strict"] { return true }; return false }(), "")

        // 16.9 A web_fetch compression stage goes through the subscription.
        let orchestrator = WebOrchestrator()
        captured.clear()
        SubscriptionWebTransport.sendOverride = { request in
            captured.add(request)
            return Data(WebFixtureServer.responsesBody("SUBSCRIPTION COMPRESSED", id: "s1").utf8)
        }
        h.serverB.clear()
        let compressed = try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/p", pageTitle: nil,
            markdown: "Some page", prompt: "what?", executionID: UUID())
        let sent = captured.all.first.map(body) ?? [:]
        check("16.9 web_fetch compression on the subscription: one Responses request, GPT-6 Luna, medium effort, instructions from the system prompt; nothing on the OpenCode fixture",
              compressed == "SUBSCRIPTION COMPRESSED" && captured.all.count == 1 && sent["model"] as? String == "gpt-6-luna"
              && (sent["reasoning"] as? [String: Any])?["effort"] as? String == "medium"
              && (sent["instructions"] as? String)?.contains("You extract information from a web page") == true
              && h.serverB.requests.isEmpty, "\(compressed) \(captured.all.count)")

        // 16.10 Usage exhaustion: the same stage is served by the configured
        // backend (fixture B) and the cooldown moves `active` off the subscription.
        captured.clear(); h.serverB.clear()
        SubscriptionWebTransport.sendOverride = { request in
            captured.add(request)
            throw SubscriptionEndpoint.providerError(status: 429, body: Data("{\"error\":{\"code\":\"usage_limit_reached\"}}".utf8))!
        }
        let fallback = try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/p", pageTitle: nil,
            markdown: "Fallback page", prompt: "what?", executionID: UUID())
        check("16.10 usage limit: one subscription attempt (never retried), the stage answered by the configured backend, active leaves the subscription for the cooldown",
              captured.all.count == 1 && fallback.hasPrefix("COMPRESSED:") && h.serverB.requests.count == 1
              && WebSearchBackend.active == .opencode, "\(captured.all.count) \(fallback.prefix(40)) \(h.serverB.requests.count)")
        SubscriptionWebTransport.resetForTests()

        // 16.11 Transient failures are retried; an HTTP 400 is not.
        captured.clear()
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        SubscriptionWebTransport.sendOverride = { request in
            captured.add(request); counter.n += 1
            if counter.n == 1 { throw ResponsesFailure.http(503, 0) }
            return Data(WebFixtureServer.responsesBody("after retry", id: "s2").utf8)
        }
        let retried = try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/p", pageTitle: nil,
            markdown: "x", prompt: "y", executionID: UUID())
        counter.n = 0; captured.clear()
        SubscriptionWebTransport.sendOverride = { request in captured.add(request); throw ResponsesFailure.http(400, nil) }
        var badRequestThrew = false
        do { _ = try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/p", pageTitle: nil, markdown: "x", prompt: "y", executionID: UUID()) }
        catch { badRequestThrew = true }
        check("16.11 a 503 is retried and succeeds; a 400 fails at once without falling back",
              retried == "after retry" && badRequestThrew && captured.all.count == 1 && !SubscriptionWebTransport.isExhausted(), retried)

        // 16.12 The Web researcher's context on the subscription.
        let web = try await h.service.webExecutionContextWithNote(lane: .subagent("sub-web"))
        let adapterRequest = try ResponsesAdapter(context: web.context).request(input: [ResponsesAdapter.message(role: "system", text: "S"), ResponsesAdapter.message(role: "user", text: "U")], tools: nil)
        let ab = body(adapterRequest)
        check("16.12 researcher context: subscription endpoint + login generation, GPT-6 Luna, high effort, Responses, no bearer in the context; the adapter builds a streamed subscription request",
              web.note == nil && web.context.endpoint == SubscriptionEndpoint.inference && web.context.subscriptionGeneration == "gen-fixture"
              && web.context.model == "gpt-6-luna" && web.context.reasoningEffort == "high" && web.context.wireProtocol == .responses
              && web.context.authorization.isEmpty && web.context.profileIdentity == "web-chatgpt"
              && adapterRequest.url?.absoluteString == SubscriptionEndpoint.inference && ab["stream"] as? Bool == true
              && ab["instructions"] as? String == "S" && adapterRequest.value(forHTTPHeaderField: "Authorization") == nil,
              "\(web.context.endpoint) \(web.context.model)")
        SubscriptionWebTransport.markExhausted()
        let exhaustedWeb = try await h.service.webExecutionContextWithNote(lane: .subagent("sub-web-2"))
        check("16.13 while exhausted a new researcher run starts on the configured backend (OpenCode here)",
              exhaustedWeb.context.endpoint != SubscriptionEndpoint.inference && exhaustedWeb.context.subscriptionGeneration == nil
              && exhaustedWeb.context.model == WebOrchestrator.opencodeResearchModel, exhaustedWeb.context.endpoint)
        SubscriptionWebTransport.resetForTests()

        // 16.14 Legacy loop (web_search tool): rounds on the subscription.
        captured.clear()
        SubscriptionWebTransport.sendOverride = { request in
            captured.add(request)
            let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if text.contains("function_call_output") {
                return Data(WebFixtureServer.responsesBody("Legacy answer <https://example.test/alpha>", id: "l2").utf8)
            }
            return Data(WebFixtureServer.responsesBody("searching", id: "l1", calls: [("search", "{\"queries\":[\"alpha\"]}")]).utf8)
        }
        await orchestrator.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        h.fixtures.serperMode = .normal
        let legacy = try await orchestrator.answer(userPrompt: "alpha?", historyPairs: [], executionID: UUID())
        let rounds = captured.all.map(body)
        check("16.14 legacy web_search loop on the subscription: Responses rounds with the search tools, reasoning replay include, GPT-6 Luna",
              legacy.contains("Legacy answer") && rounds.count == 2
              && rounds.allSatisfy { $0["model"] as? String == "gpt-6-luna" && ($0["tools"] as? [[String: Any]])?.count == 2
                  && ($0["include"] as? [String]) == ["reasoning.encrypted_content"] && $0["stream"] as? Bool == true },
              "\(rounds.count) \(legacy.prefix(60))")
        // Exhaustion mid-loop with a non-OpenAI configured backend: the loop
        // cannot move its Responses transcript, so it fails clearly (the next
        // search resolves to the configured backend through the cooldown).
        captured.clear()
        SubscriptionWebTransport.sendOverride = { request in
            captured.add(request)
            throw SubscriptionEndpoint.providerError(status: 429, body: Data("{\"error\":{\"code\":\"usage_limit_reached\"}}".utf8))!
        }
        var legacyError = ""
        do { _ = try await orchestrator.answer(userPrompt: "beta?", historyPairs: [], executionID: UUID()) }
        catch { legacyError = error.localizedDescription }
        check("16.15 legacy loop exhausted with a non-OpenAI configured backend: a clear usage error, one attempt, cooldown armed",
              legacyError.contains("usage is exhausted") && captured.all.count == 1 && WebSearchBackend.active == .opencode, legacyError)
        SubscriptionWebTransport.resetForTests()
        let transcript = WebAgentResponsesTranscript(instructions: "i", user: "u")
        transcript.appendOutputItems([.object(["type": .string("reasoning"), "id": .string("rs_1"), "encrypted_content": .string("x")]),
                                      .object(["type": .string("function_call"), "call_id": .string("c1"), "name": .string("search"), "arguments": .string("{}")])])
        transcript.dropReasoningItems()
        check("16.16 moving a legacy transcript off the subscription drops only its reasoning items",
              transcript.input.count == 2 && transcript.input.allSatisfy { $0.objectValue?["type"]?.stringValue != "reasoning" }, "\(transcript.input.count)")

        // 16.17 Other providers never touch the subscription path.
        try KeychainHelper.save(key: ProviderProfiles.activeProfileKey, value: "openai")
        check("16.17 main provider not the subscription: active is the configured backend; chatgpt has no key",
              WebSearchBackend.active == .opencode && WebSearchBackend.storedKey(for: .chatgpt).isEmpty && SubscriptionWebTransport.activeGeneration() == nil, "")
    }
}
