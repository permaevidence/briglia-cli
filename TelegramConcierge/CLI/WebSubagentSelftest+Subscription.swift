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
        /// Never let one broken path abort the group: an error becomes the
        /// value "ERROR: …", so every later row still runs and reports.
        func attempt(_ work: () async throws -> String) async -> String {
            do { return try await work() } catch { return "ERROR: \(error.localizedDescription)" }
        }

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
        check("16.3 follow rule: only the active ChatGPT subscription profile with a login generation",
              WebSearchBackend.followsSubscription(stored: sub)
              && !WebSearchBackend.followsSubscription(stored: other)
              && !WebSearchBackend.followsSubscription(stored: noGeneration)
              && !WebSearchBackend.followsSubscription(stored: routerMain), "")
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
        check("16.5 active follows the subscription; configured stays the stored choice; the chatgpt key is the login generation",
              WebSearchBackend.active == .chatgpt && WebSearchBackend.configured == .opencode
              && WebSearchBackend.storedKey(for: .chatgpt) == "gen-fixture", "\(WebSearchBackend.active)")
        let usage = SubscriptionEndpoint.providerError(status: 429, body: Data("{\"error\":{\"code\":\"usage_limit_reached\"}}".utf8))
        func streamed(_ json: String) -> SubscriptionError? {
            guard let event = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))?.responsesObject else { return nil }
            return SubscriptionEndpoint.streamedUsageError(event)
        }
        check("16.6 usage codes are typed as exhausted from an HTTP body, a top-level or nested SSE error and a response.failed; rate limits, server errors and model errors are not",
              usage?.usageExhausted == true
              && SubscriptionEndpoint.providerError(status: 404, body: Data("{\"error\":{\"code\":\"model_not_found\"}}".utf8))?.usageExhausted == false
              && streamed("{\"type\":\"error\",\"code\":\"usage_limit_reached\"}")?.usageExhausted == true
              && streamed("{\"type\":\"error\",\"error\":{\"code\":\"usage_not_included\"}}")?.usageExhausted == true
              && streamed("{\"type\":\"error\",\"error\":{\"type\":\"insufficient_quota\"}}")?.usageExhausted == true
              && streamed("{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"usage_limit_reached\"}}}")?.usageExhausted == true
              && streamed("{\"type\":\"error\",\"code\":\"rate_limit_exceeded\"}") == nil
              && streamed("{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\"}}}") == nil,
              "")

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
        let compressed = await attempt { try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/p", pageTitle: nil,
            markdown: "Some page", prompt: "what?", executionID: UUID()) }
        let sent = captured.all.first.map(body) ?? [:]
        check("16.9 web_fetch compression on the subscription: one Responses request, GPT-6 Luna, medium effort, instructions from the system prompt; nothing on the OpenCode fixture",
              compressed == "SUBSCRIPTION COMPRESSED" && captured.all.count == 1 && sent["model"] as? String == "gpt-6-luna"
              && (sent["reasoning"] as? [String: Any])?["effort"] as? String == "medium"
              && (sent["instructions"] as? String)?.contains("You extract information from a web page") == true
              && h.serverB.requests.isEmpty, "\(compressed) \(captured.all.count)")

        // 16.10 Usage exhaustion (owner decision 2026-09-23): no fallback and
        // no cooldown; the main agent is on the same allowance, so the stage
        // fails with the subscription's usage message like the main agent.
        captured.clear(); h.serverB.clear()
        SubscriptionWebTransport.sendOverride = { request in
            captured.add(request)
            throw SubscriptionEndpoint.providerError(status: 429, body: Data("{\"error\":{\"code\":\"usage_limit_reached\"}}".utf8))!
        }
        let exhausted = await attempt { try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/p", pageTitle: nil,
            markdown: "Exhausted page", prompt: "what?", executionID: UUID()) }
        check("16.10 usage limit: one subscription attempt (never retried), a clear usage error, nothing sent to the configured backend, research still follows the subscription",
              captured.all.count == 1 && exhausted.hasPrefix("ERROR:") && exhausted.contains("usage is exhausted")
              && h.serverB.requests.isEmpty && WebSearchBackend.active == .chatgpt,
              "\(captured.all.count) \(exhausted.prefix(80)) \(h.serverB.requests.count)")
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
        let retried = await attempt { try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/p", pageTitle: nil,
            markdown: "x", prompt: "y", executionID: UUID()) }
        counter.n = 0; captured.clear()
        SubscriptionWebTransport.sendOverride = { request in captured.add(request); throw ResponsesFailure.http(400, nil) }
        var badRequestThrew = false
        do { _ = try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/p", pageTitle: nil, markdown: "x", prompt: "y", executionID: UUID()) }
        catch { badRequestThrew = true }
        check("16.11 a 503 is retried and succeeds; a 400 fails at once without falling back",
              retried == "after retry" && badRequestThrew && captured.all.count == 1, retried)

        // 16.12 The Web researcher's context on the subscription.
        if let web = try? await h.service.webExecutionContextWithNote(lane: .subagent("sub-web")),
           let adapterRequest = try? ResponsesAdapter(context: web.context).request(input: [ResponsesAdapter.message(role: "system", text: "S"), ResponsesAdapter.message(role: "user", text: "U")], tools: nil) {
        let ab = body(adapterRequest)
        check("16.12 researcher context: subscription endpoint + login generation, GPT-6 Luna, high effort, Responses, no bearer in the context; the adapter builds a streamed subscription request",
              web.note == nil && web.context.endpoint == SubscriptionEndpoint.inference && web.context.subscriptionGeneration == "gen-fixture"
              && web.context.model == "gpt-6-luna" && web.context.reasoningEffort == "high" && web.context.wireProtocol == .responses
              && web.context.authorization.isEmpty && web.context.profileIdentity == "web-chatgpt"
              && adapterRequest.url?.absoluteString == SubscriptionEndpoint.inference && ab["stream"] as? Bool == true
              && ab["instructions"] as? String == "S" && adapterRequest.value(forHTTPHeaderField: "Authorization") == nil,
              "\(web.context.endpoint) \(web.context.model)")
        } else { check("16.12 researcher context on the subscription", false, "context or adapter request threw") }
        // The persistent researcher's adapter reads the same stream assembler:
        // a failed terminal with a quota code is the typed usage error there
        // too; on a non-subscription stream the same event is left to the
        // round decoder's generic failure (API-key paths are unchanged).
        func assemble(_ event: String, subscription: Bool) -> Result<Data, Error> {
            var stream = ResponsesStreamAssembler(); stream.subscription = subscription
            return Result { try stream.append(Data("data: \(event)\n\n".utf8)); return try stream.finish() }
        }
        let failedQuota = "{\"type\":\"response.failed\",\"response\":{\"id\":\"resp_q\",\"status\":\"failed\",\"error\":{\"code\":\"usage_limit_reached\"},\"output\":[]}}"
        let onSubscription = assemble(failedQuota, subscription: true)
        let onAPI = assemble(failedQuota, subscription: false)
        check("16.13 stream assembler: a quota response.failed on the subscription throws the usage error (researcher adapter included); the API-key stream keeps its terminal snapshot for the decoder",
              { if case .failure(let e) = onSubscription { return (e as? SubscriptionError)?.usageExhausted == true }; return false }()
              && { if case .success = onAPI { return true }; return false }(), "\(onSubscription) \(onAPI)")

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
        let legacy = await attempt { try await orchestrator.answer(userPrompt: "alpha?", historyPairs: [], executionID: UUID()) }
        let rounds = captured.all.map(body)
        check("16.14 legacy web_search loop on the subscription: Responses rounds with the search tools, reasoning replay include, GPT-6 Luna",
              legacy.contains("Legacy answer") && rounds.count == 2
              && rounds.allSatisfy { $0["model"] as? String == "gpt-6-luna" && ($0["tools"] as? [[String: Any]])?.count == 2
                  && ($0["include"] as? [String]) == ["reasoning.encrypted_content"] && $0["stream"] as? Bool == true },
              "\(rounds.count) \(legacy.prefix(60))")
        // Exhaustion mid-loop: the loop fails with the usage message; nothing
        // moves to the configured backend.
        captured.clear()
        SubscriptionWebTransport.sendOverride = { request in
            captured.add(request)
            throw SubscriptionEndpoint.providerError(status: 429, body: Data("{\"error\":{\"code\":\"usage_limit_reached\"}}".utf8))!
        }
        var legacyError = ""
        do { _ = try await orchestrator.answer(userPrompt: "beta?", historyPairs: [], executionID: UUID()) }
        catch { legacyError = error.localizedDescription }
        check("16.15 legacy loop exhausted: a clear usage error, one attempt, research still follows the subscription",
              legacyError.contains("usage is exhausted") && captured.all.count == 1 && WebSearchBackend.active == .chatgpt, legacyError)
        SubscriptionWebTransport.resetForTests()

        // 16.16 Codex review 2026-09-23 (R1/R2), through the production
        // stream assembler over real SSE framing: streamed quota errors are
        // the typed usage error, and a failed/incomplete terminal never
        // becomes output or executed tool calls.
        func sse(_ event: [String: Any]) -> (URLRequest) async throws -> Data {
            return { request in
                captured.add(request)
                var stream = ResponsesStreamAssembler(); stream.subscription = true
                let json = try JSONSerialization.data(withJSONObject: event)
                try stream.append(Data("data: ".utf8) + json + Data("\n\n".utf8))
                return try stream.finish()
            }
        }
        for nested in [false, true] {
            captured.clear(); h.serverB.clear()
            SubscriptionWebTransport.sendOverride = sse(nested
                ? ["type": "error", "error": ["code": "usage_limit_reached", "message": "fixture"]]
                : ["type": "error", "code": "usage_limit_reached", "message": "fixture"])
            let value = await attempt { try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/sse", pageTitle: nil,
                markdown: "x", prompt: "y", executionID: UUID()) }
            check("16.16\(nested ? "b" : "a") SSE error with a quota code (\(nested ? "nested" : "top-level")): the usage error, one send, no fallback",
                  value.contains("usage is exhausted") && captured.all.count == 1 && h.serverB.requests.isEmpty,
                  "value=\(value.prefix(80)) sends=\(captured.all.count) fallback=\(h.serverB.requests.count)")
        }
        for partial in [false, true] {
            captured.clear(); h.serverB.clear()
            let output: [[String: Any]] = partial ? [["type": "message", "id": "msg_failed", "role": "assistant",
                "status": "completed", "content": [["type": "output_text", "text": "FAILED_PARTIAL_MUST_NOT_SUCCEED", "annotations": []]]]] : []
            SubscriptionWebTransport.sendOverride = sse(["type": "response.failed", "response": ["id": "resp_failed", "status": "failed",
                "error": ["code": "usage_limit_reached", "message": "fixture"], "output": output]])
            let value = await attempt { try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/failed", pageTitle: nil,
                markdown: "x", prompt: "y", executionID: UUID()) }
            check("16.16\(partial ? "d" : "c") response.failed with a quota code (\(partial ? "partial text" : "empty output")): the usage error after one send, partial text never returned, no fallback",
                  value.contains("usage is exhausted") && !value.contains("FAILED_PARTIAL") && captured.all.count == 1 && h.serverB.requests.isEmpty,
                  "value=\(value.prefix(80)) sends=\(captured.all.count) fallback=\(h.serverB.requests.count)")
        }
        captured.clear()
        SubscriptionWebTransport.sendOverride = sse(["type": "response.failed", "response": ["id": "resp_err", "status": "failed",
            "error": ["code": "server_error", "message": "fixture"], "output": [["type": "message", "id": "msg_x", "role": "assistant",
            "status": "completed", "content": [["type": "output_text", "text": "FAILED_TEXT_MUST_NOT_SUCCEED", "annotations": []]]]]]])
        let failedStage = await attempt { try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/err", pageTitle: nil,
            markdown: "x", prompt: "y", executionID: UUID()) }
        check("16.16e a failed (non-quota) response with text is an error, never a compression result",
              failedStage.hasPrefix("ERROR:") && !failedStage.contains("FAILED_TEXT") && captured.all.count == 1, failedStage)
        for incomplete in [false, true] {
            captured.clear()
            let searchesBefore = h.fixtures.serperCalls
            SubscriptionWebTransport.sendOverride = { request in
                captured.add(request)
                if captured.all.count > 1 && incomplete {
                    return Data(WebFixtureServer.responsesBody("Answer after refused round", id: "r_after").utf8)
                }
                var response = try JSONSerialization.jsonObject(with: Data(WebFixtureServer.responsesBody("", id: "r_bad",
                    calls: [("search", "{\"queries\":[\"must-never-run\"]}")]).utf8)) as! [String: Any]
                if incomplete {
                    response["status"] = "incomplete"
                    response["incomplete_details"] = ["reason": "max_output_tokens"]
                    return try JSONSerialization.data(withJSONObject: response)
                }
                response["status"] = "failed"
                response["error"] = ["code": "server_error", "message": "fixture"]
                var stream = ResponsesStreamAssembler(); stream.subscription = true
                let json = try JSONSerialization.data(withJSONObject: ["type": "response.failed", "response": response])
                try stream.append(Data("data: ".utf8) + json + Data("\n\n".utf8))
                return try stream.finish()
            }
            let result = await attempt { try await orchestrator.answer(userPrompt: "tool round \(incomplete)", historyPairs: [], executionID: UUID()) }
            check("16.16\(incomplete ? "g" : "f") legacy loop never executes tool calls from \(incomplete ? "an incomplete" : "a failed") response",
                  h.fixtures.serperCalls == searchesBefore && (incomplete ? captured.all.count >= 2 : (result.hasPrefix("ERROR:") && captured.all.count == 1)),
                  "searches=\(h.fixtures.serperCalls - searchesBefore) sends=\(captured.all.count) result=\(result.prefix(80))")
        }
        SubscriptionWebTransport.resetForTests()

        // 16.16h–n (Codex round 2): usage exhaustion is terminal through the
        // OUTER pipeline — no salvage request, no raw-page fallback, no
        // further sequential requests — and never reaches another backend.
        let quotaText = "usage is exhausted"
        captured.clear(); h.serverB.clear(); h.serverC.clear(); h.serverD.clear()
        SubscriptionWebTransport.sendOverride = { request in
            captured.add(request)
            if captured.all.count == 1 {
                return Data(WebFixtureServer.responsesBody("searching", id: "r_before_quota", calls: [("search", "{\"queries\":[\"quota after evidence\"]}")]).utf8)
            }
            throw SubscriptionEndpoint.usageExhaustedError()
        }
        let midLoopQuota = await attempt { try await orchestrator.answer(userPrompt: "quota after evidence", historyPairs: [], executionID: UUID()) }
        check("16.16h quota after a successful search is terminal: no forced-final request",
              midLoopQuota.contains(quotaText) && captured.all.count == 2,
              "sends=\(captured.all.count) result=\(midLoopQuota.prefix(80))")
        check("16.16i mid-loop quota never reaches another backend",
              h.serverB.requests.isEmpty && h.serverC.requests.isEmpty && h.serverD.requests.isEmpty, "")

        captured.clear()
        SubscriptionWebTransport.sendOverride = { request in captured.add(request); throw SubscriptionEndpoint.usageExhaustedError() }
        h.fixtures.pages["https://example.test/r2-short"] = "# Page\n\nRAW_PAGE_RETURNED_AFTER_QUOTA"
        let shortQuota = await attempt { try await orchestrator.readUrlContentWithMetadata(url: "https://example.test/r2-short", prompt: "extract", refresh: true).result.content }
        check("16.16j web_fetch (small page): quota is an error, never the raw page",
              shortQuota.hasPrefix("ERROR:") && shortQuota.contains(quotaText) && !shortQuota.contains("RAW_PAGE_RETURNED_AFTER_QUOTA"),
              "sends=\(captured.all.count) result=\(shortQuota.prefix(80))")
        // Not cached as a success: the next read asks the model again.
        captured.clear()
        _ = await attempt { try await orchestrator.readUrlContentWithMetadata(url: "https://example.test/r2-short", prompt: "extract", refresh: false).result.content }
        check("16.16k web_fetch quota result is not cached", captured.all.count == 1, "sends=\(captured.all.count)")

        captured.clear()
        h.fixtures.pages["https://example.test/r2-large"] = String(repeating: "large fetch content ", count: 90000)
        let largeQuota = await attempt { try await orchestrator.readUrlContentWithMetadata(url: "https://example.test/r2-large", prompt: "extract", refresh: true).result.content }
        check("16.16l web_fetch (chunked page): quota is an error, never the raw-window fallback",
              largeQuota.hasPrefix("ERROR:") && largeQuota.contains(quotaText),
              "sends=\(captured.all.count) result=\(largeQuota.prefix(80))")

        captured.clear()
        h.fixtures.pages["https://example.test/r2-long"] = String(repeating: "long source content ", count: 90000)
        var extractQuota = "", docCount = -1
        do {
            let outcome = try await orchestrator.executeWebExtract(requests: [.init(url: "https://example.test/r2-long", focus: "source content")], mode: .webSearch)
            docCount = outcome.docs.count
            extractQuota = "returned: " + outcome.failures.joined(separator: ";")
        } catch { extractQuota = "threw: " + error.localizedDescription }
        check("16.16m chunked web_extract stops at the first quota and keeps the error",
              captured.all.count == 1 && extractQuota.hasPrefix("threw: ") && extractQuota.contains(quotaText),
              "sends=\(captured.all.count) docs=\(docCount) error=\(extractQuota.prefix(80))")

        captured.clear()
        h.fixtures.pages["https://example.test/r2-assets"] = "# Assets\n\nSee [the spec](https://example.test/spec) for details."
        var assetQuota = ""
        do {
            let outcome = try await orchestrator.executeWebExtract(requests: [.init(url: "https://example.test/r2-assets", focus: "spec")], mode: .webSearch)
            assetQuota = "docs=\(outcome.docs.count) failures=\(outcome.failures.count)"
        } catch { assetQuota = error.localizedDescription }
        check("16.16n web_extract asset step: quota is an error, not an empty best-effort result",
              captured.all.count == 1 && assetQuota.contains(quotaText),
              "sends=\(captured.all.count) result=\(assetQuota.prefix(80))")

        // Merge pass: dense sections overflow the 30KB cap, then the merge
        // request hits the quota — an error, not a hard-truncated stitch.
        captured.clear()
        let denseSection = String(repeating: "dense relevant fact. ", count: 800)
        SubscriptionWebTransport.sendOverride = { request in
            captured.add(request)
            if captured.all.count <= 3 { return Data(WebFixtureServer.responsesBody(denseSection, id: "r_section").utf8) }
            throw SubscriptionEndpoint.usageExhaustedError()
        }
        let mergeQuota = await attempt { try await orchestrator.readUrlContentWithMetadata(url: "https://example.test/r2-large", prompt: "extract", refresh: true).result.content }
        check("16.16p web_fetch merge pass: quota is an error, not a truncated stitch",
              captured.all.count == 4 && mergeQuota.hasPrefix("ERROR:") && mergeQuota.contains(quotaText),
              "sends=\(captured.all.count) result=\(mergeQuota.prefix(80))")

        // Control: an ORDINARY failure keeps the old skip-and-continue path.
        captured.clear()
        SubscriptionWebTransport.sendOverride = { request in
            captured.add(request)
            throw NSError(domain: "fixture", code: 500, userInfo: [NSLocalizedDescriptionKey: "ordinary failure"])
        }
        var ordinary = ""
        do {
            let outcome = try await orchestrator.executeWebExtract(requests: [.init(url: "https://example.test/r2-long", focus: "source content")], mode: .webSearch)
            ordinary = "docs=\(outcome.docs.count)"
        } catch { ordinary = "threw: \(error.localizedDescription)" }
        check("16.16o ordinary chunk failures still skip and continue",
              ordinary == "docs=1" && captured.all.count >= 2,
              "sends=\(captured.all.count) result=\(ordinary)")
        SubscriptionWebTransport.resetForTests()

        // 16.17 Other providers never touch the subscription path.
        try KeychainHelper.save(key: ProviderProfiles.activeProfileKey, value: "openai")
        check("16.17 main provider not the subscription: active is the configured backend; chatgpt has no key",
              WebSearchBackend.active == .opencode && WebSearchBackend.storedKey(for: .chatgpt).isEmpty && SubscriptionWebTransport.activeGeneration() == nil, "")
    }
}
