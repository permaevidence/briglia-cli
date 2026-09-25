import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Group 19 (researcher-on-main-model, round 1, 2026-09-25):
//  - paid OpenAI research spend (legacy loop and Web researcher) is priced
//    from tokens at the served model's rates; subscriptions stay $0;
//  - the Web researcher ignores cheap-lane hints (direct, resumed, nested);
//  - OpenRouter as the MAIN provider moves page extraction and web_fetch
//    compression to DeepSeek V4 Flash on the fastest host (sort=throughput),
//    ignoring an /orprovider pin, priced by the host-reported cost.
extension WebSubagentSelftest {
    static func runRound1Groups(_ h: Harness) async throws {
        print("19. Round 1: research spend, main model only, OpenRouter extractor")
        let fixtures = h.fixtures, images = h.images, documents = h.documents, service = h.service
        let serverA = h.serverA, serverB = h.serverB, serverC = h.serverC, serverD = h.serverD
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        let body = h.body
        func text(_ request: WebFixtureServer.Request) -> String { String(decoding: request.body, as: UTF8.self) }
        func research(_ server: WebFixtureServer) -> [WebFixtureServer.Request] {
            server.requests.filter { text($0).contains("You are the web research subagent") }
        }
        func legacy(_ server: WebFixtureServer) -> [WebFixtureServer.Request] {
            server.requests.filter { text($0).contains("You are a research agent") || text($0).contains("You are a deep research agent") }
        }
        func pageStages(_ server: WebFixtureServer) -> [WebFixtureServer.Request] { stageFilter(server.requests) }
        func stageFilter(_ requests: [WebFixtureServer.Request]) -> [WebFixtureServer.Request] {
            requests.filter { text($0).contains("Cite verbatim and in full") || text($0).contains("You extract information from a web page")
                || text($0).contains("focus-relevant page assets") }
        }
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-12 } ?? false }
        h.state.webFlag = true
        WebSearchBackend.processOverride = .opencode
        fixtures.serperMode = .normal
        defer { h.state.webFlag = false; WebSearchBackend.processOverride = .opencode }
        let all = AvailableTools.all(includeWebSearch: true)
        let executor = ToolExecutor(outputMode: .subagent)
        await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        func web(_ prompt: String, model: String? = nil) -> SubagentRunner.Invocation {
            SubagentRunner.Invocation(subagentType: "Web", description: "round1", taskPrompt: prompt, modelOverride: model, runInBackground: false, deliverable: .short)
        }
        func run(_ invocation: SubagentRunner.Invocation, session: String? = nil) async -> SubagentRunner.RunResult {
            await SubagentRunner().run(invocation: invocation, sessionId: session, openRouterService: service, toolExecutor: executor,
                                       imagesDirectory: images, documentsDirectory: documents, parentTools: all)
        }
        let orchestrator = WebOrchestrator()
        await orchestrator.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        let openAIMain = mainSlots(profile: "openai", base: h.baseC + "/v1", model: "gpt-6-sol", key: "synthetic-main-openai-key", effort: "low", responses: true)
        // gpt-6-sol: $2/M in, $10/M out; each Responses fixture reports 100 in / 30 out.
        let solRound = (100.0 * 2.0 + 30.0 * 10.0) / 1_000_000

        // 19.1 (Codex R1 reproduction): the legacy loop on a paid OpenAI Responses main.
        serverC.clear()
        serverC.script([WebFixtureServer.responsesBody("From memory.", id: "sp1"),
                        WebFixtureServer.responsesBody("searching", id: "sp2", calls: [("search", "{\"queries\":[\"paid legacy\"]}")]),
                        WebFixtureServer.responsesBody("Paid legacy answer <https://example.test/paid-legacy>", id: "sp3")])
        let paidLegacy = try? await withMainSlots(openAIMain) { try await orchestrator.executeForTool(query: "paid legacy?", agentService: service) }
        let paidRounds = legacy(serverC)
        check("19.1 CODEX R1 paid OpenAI legacy rounds retain nonzero spend from token usage: three gpt-6-sol rounds (nudge, tool call, answer) priced at $2/$10 per M",
              paidLegacy != nil && paidRounds.count == 3 && near(paidLegacy?.spendUSD, 3 * solRound),
              "spend \(paidLegacy?.spendUSD.map(String.init(describing:)) ?? "nil"), rounds \(paidRounds.count)")

        // 19.2 Error settlement after paid work: the loop fails after two paid rounds; the error carries their spend.
        serverC.clear()
        serverC.script([WebFixtureServer.responsesBody("searching", id: "se1", calls: [("search", "{\"queries\":[\"paid error\"]}")])])
        serverC.scriptStatuses([200, 400, 400])
        var settledError: Double? = nil
        do { _ = try await withMainSlots(openAIMain) { try await orchestrator.executeForTool(query: "paid error?", agentService: service) } }
        catch { settledError = (error as? ResearchExecutionError)?.spendUSD }
        check("19.2 a legacy run that fails after a paid round still reports that round's spend on the error",
              near(settledError, solRound), "\(settledError.map(String.init(describing:)) ?? "nil")")

        // 19.3 Flat subscriptions stay $0: OpenCode Responses main (GPT on OpenCode Go).
        serverB.clear()
        serverB.script([WebFixtureServer.responsesBody("searching", id: "fl1", calls: [("search", "{\"queries\":[\"flat legacy\"]}")]),
                        WebFixtureServer.responsesBody("Flat legacy answer <https://example.test/flat>", id: "fl2")])
        let flat = try? await withMainSlots(mainSlots(profile: "opencode", base: h.baseB + "/zen/go/v1", model: "gpt-5.6-luna",
                                                       key: "synthetic-main-opencode-key", effort: "medium", responses: false)) {
            try await orchestrator.executeForTool(query: "flat legacy?", agentService: service)
        }
        check("19.3 legacy loop on an OpenCode Go Responses main (flat subscription): no invented API dollars",
              flat?.summary.contains("Flat legacy answer") == true && legacy(serverB).count == 2 && flat?.spendUSD == nil,
              "\(flat?.spendUSD.map(String.init(describing:)) ?? "nil")")

        // 19.4 The Web researcher on the same paid OpenAI main: priced too.
        serverC.clear()
        serverC.script([WebFixtureServer.responsesBody("searching", id: "wr1", calls: [("web_query", "{\"queries\":[\"paid web\"]}")]),
                        WebFixtureServer.responsesBody("Paid web answer. Sources: https://example.test/paid-web", id: "wr2")])
        let paidWeb = await withMainSlots(openAIMain) { await run(web("Paid web?")) }
        let paidWebRounds = research(serverC)
        check("19.4 Web researcher on a paid OpenAI Responses main: every round priced from tokens at gpt-6-sol rates",
              paidWeb.error == nil && paidWebRounds.count == 2 && abs(paidWeb.spendUSD - 2 * solRound) < 1e-12,
              paidWeb.error ?? "\(paidWeb.spendUSD) rounds \(paidWebRounds.count)")

        // 19.5 Rates and the settle rule (pure).
        let paidContext = await withMainSlots(openAIMain) {
            await service.researcherExecutionContext(modelOverride: nil, textOnlyOverride: nil, lane: .subagent("rates"))
        }
        var subscriptionContext = paidContext
        subscriptionContext.subscriptionGeneration = "g1"
        let customOpenAI = await withMainSlots(mainSlots(profile: "custom", base: "https://api.openai.com/v1", model: "gpt-6-luna",
                                                         key: "k", effort: nil, responses: false)) {
            await service.researcherExecutionContext(modelOverride: nil, textOnlyOverride: nil, lane: .subagent("rates"))
        }
        let customOther = await withMainSlots(mainSlots(profile: "custom", base: h.baseA + "/v1", model: "gpt-6-sol",
                                                        key: "k", effort: nil, responses: false)) {
            await service.researcherExecutionContext(modelOverride: nil, textOnlyOverride: nil, lane: .subagent("rates"))
        }
        check("19.5 rates: model-appropriate (Luna, Sol, Astra, dated snapshot, openai/ prefix); an unknown OpenAI model is priced like Terra, never at Luna's rate",
              ResearchSpend.rates(forOpenAIModel: "gpt-6-luna") == (0.10, 0.50) && ResearchSpend.rates(forOpenAIModel: "gpt-6-sol") == (2.0, 10.0)
              && ResearchSpend.rates(forOpenAIModel: "gpt-6-astra") == (10.0, 50.0) && ResearchSpend.rates(forOpenAIModel: "gpt-6-sol-2026-09-01") == (2.0, 10.0)
              && ResearchSpend.rates(forOpenAIModel: "openai/gpt-5.6-luna") == (0.20, 1.20) && ResearchSpend.rates(forOpenAIModel: "gpt-7-nova") == (2.0, 12.0))
        check("19.6 settle: a reported cost wins; paid OpenAI (profile or api.openai.com host) is estimated; subscription, other custom endpoints and no context stay nil; >272K input doubles the input rate",
              ResearchSpend.settle(reported: 0.5, promptTokens: 100, completionTokens: 30, context: paidContext) == 0.5
              && near(ResearchSpend.settle(reported: nil, promptTokens: 100, completionTokens: 30, context: paidContext), solRound)
              && ResearchSpend.settle(reported: nil, promptTokens: 100, completionTokens: 30, context: subscriptionContext) == nil
              && near(ResearchSpend.settle(reported: nil, promptTokens: 200_000, completionTokens: 0, context: customOpenAI), 0.02)
              && ResearchSpend.settle(reported: nil, promptTokens: 100, completionTokens: 30, context: customOther) == nil
              && ResearchSpend.settle(reported: nil, promptTokens: 100, completionTokens: 30, context: nil) == nil
              && near(ResearchSpend.estimate(model: "gpt-6-sol", promptTokens: 300_000, completionTokens: 0), 300_000 * 4.0 / 1_000_000))

        // 19.7–19.9 The Web researcher always runs the main model.
        try SubagentModelLanes.setModel(.cheapText, model: "cheap-text-model")
        serverA.clear()
        serverA.script([WebFixtureServer.chatBody("Main answer despite the hint."), WebFixtureServer.chatBody("Main answer despite the hint.")])
        let hinted = await run(web("Hinted?", model: "cheap-text"))
        let hintedRounds = research(serverA)
        serverA.clear()
        serverA.script([WebFixtureServer.chatBody("Resumed on main."), WebFixtureServer.chatBody("Resumed on main.")])
        let hintedResume = await run(web("Hinted resume?", model: "cheap-text"), session: hinted.sessionId)
        let resumeRounds = research(serverA)
        check("19.7 Web + model 'cheap-text' (a configured lane), direct and on resume: every round on the MAIN model, model_used '(inherited)', the result notes the hint was ignored",
              hinted.error == nil && !hintedRounds.isEmpty && hintedRounds.allSatisfy { body($0)["model"] as? String == "main-model" }
              && hinted.modelUsed == "main-model (inherited)" && (hinted.note ?? "").contains("ignored: the Web researcher always runs the main model")
              && hintedResume.error == nil && !resumeRounds.isEmpty && resumeRounds.allSatisfy { body($0)["model"] as? String == "main-model" }
              && hintedResume.modelUsed == "main-model (inherited)",
              hinted.error ?? "\(hintedRounds.map { body($0)["model"] as? String ?? "nil" }) \(hinted.modelUsed ?? "nil") \(hinted.note ?? "no note")")
        // Nested: a depth-1 executor's Agent(Web, model=cheap-text).
        let mainExecutor = ToolExecutor(outputMode: .mainAgent)
        await mainExecutor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        await mainExecutor.configureOpenRouter(service, imagesDirectory: images, documentsDirectory: documents)
        let depth1 = await mainExecutor.makeChildExecutor()
        serverA.clear()
        serverA.script([WebFixtureServer.chatBody("Nested main answer."), WebFixtureServer.chatBody("Nested main answer.")])
        let nestedArgs = "{\"subagent_type\":\"Web\",\"description\":\"nested hint\",\"prompt\":\"Nested hinted?\",\"model\":\"cheap-text\",\"deliverable\":\"short\"}"
        let nested = await depth1.executeAgentToolResult(ToolCall(id: "n1", type: "function", function: FunctionCall(name: "Agent", arguments: nestedArgs)))
        let nestedRounds = research(serverA)
        try SubagentModelLanes.setModel(.cheapText, model: nil)
        check("19.8 nested Agent(Web, model=cheap-text) from a depth-1 subagent: runs on the main model and says the hint was ignored",
              !nestedRounds.isEmpty && nestedRounds.allSatisfy { body($0)["model"] as? String == "main-model" }
              && nested.content.contains("main-model (inherited)") && nested.content.contains("the Web researcher always runs the main model"),
              String(nested.content.prefix(400)))
        check("19.9 hint validation: an UNCONFIGURED lane or unknown hint is not an error for Web (ignored), still an error for an ordinary subagent; inherit is never a note",
              ToolExecutor.agentModelHintError("cheap-vision", subagentType: "Web") == nil
              && ToolExecutor.agentModelHintError("gpt-x", subagentType: "Web") == nil
              && ToolExecutor.agentModelHintError("cheap-vision", subagentType: "general-purpose") != nil
              && SubagentRunner.webModelHintIgnoredNote("cheap-vision").contains("cheap-vision"))

        // 19.10–19.14 OpenRouter as the MAIN provider: the extractor follows.
        let routerMain: [String: String?] = [ProviderProfiles.activeProfileKey: "openrouter", KeychainHelper.llmProviderKey: LLMProvider.openRouter.rawValue,
                                             KeychainHelper.openRouterApiKeyKey: "synthetic-or-key",
                                             KeychainHelper.openRouterModelKey: "deepseek/deepseek-v4.1-flash", KeychainHelper.openRouterReasoningEffortKey: "medium",
                                             ProviderProfiles.runtimeProtocolKey: nil]
        var stored = KeychainHelper.loadSnapshot()
        stored[KeychainHelper.llmProviderKey] = LLMProvider.openRouter.rawValue; stored[KeychainHelper.openRouterApiKeyKey] = "k"
        var noKey = stored; noKey[KeychainHelper.openRouterApiKeyKey] = " "
        var custom = stored; custom[KeychainHelper.llmProviderKey] = LLMProvider.openAICompatible.rawValue
        let followed = WebSearchBackend.stageRoute(followsMainOpenRouter: true, model: ORModel.webExcerpts, reasoning: makeReasoning(.medium),
                                                   provider: nil, hasResponseFormat: true)
        let followedNoFormat = WebSearchBackend.stageRoute(followsMainOpenRouter: true, model: ORModel.webFetchCompression, reasoning: makeReasoning(.medium),
                                                           provider: nil, hasResponseFormat: false)
        let unchanged = WebSearchBackend.stageRoute(followsMainOpenRouter: false, model: ORModel.webExcerpts, reasoning: makeReasoning(.medium),
                                                    provider: nil, hasResponseFormat: true)
        check("19.10 follow rule + stage route: OpenRouter main with a key follows (not without a key, not on other providers); the route is deepseek/deepseek-v4-flash-0731, effort low, sort=throughput, fallbacks on, no host list, require_parameters only with a strict format; off → untouched",
              WebSearchBackend.followsOpenRouter(stored: stored) && !WebSearchBackend.followsOpenRouter(stored: noKey) && !WebSearchBackend.followsOpenRouter(stored: custom)
              && followed.model == "deepseek/deepseek-v4-flash-0731" && followed.reasoning?.effort == "low"
              && followed.provider?.sort == "throughput" && followed.provider?.allow_fallbacks == true && followed.provider?.only == nil
              && followed.provider?.order == nil && followed.provider?.require_parameters == true
              && followedNoFormat.provider?.require_parameters == nil && followedNoFormat.model == "deepseek/deepseek-v4-flash-0731"
              && unchanged.model == ORModel.webExcerpts && unchanged.reasoning?.effort == "medium" && unchanged.provider == nil)

        // Live stages against the OpenRouter fixture (D): excerpt extraction,
        // web_fetch compression, and the legacy loop's fetch_and_extract.
        WebSearchBackend.processOverride = nil
        let baseDRoute = serverD.route
        serverD.route = { request in
            let t = String(decoding: request.body, as: UTF8.self)
            let content: String
            if t.contains("You extract information from a web page") { content = "COMPRESSED: deepseek page" }
            else if t.contains("Cite verbatim and in full") { content = "{\"excerpts\":[\"deepseek excerpt\"]}" }
            else if t.contains("focus-relevant page assets") { content = "{\"links\":[],\"images\":[]}" }
            else { return baseDRoute?(request) ?? .init(status: 500, body: "{}") }
            var object = (try? JSONSerialization.jsonObject(with: Data(WebFixtureServer.chatBody(content).utf8)) as? [String: Any]) ?? [:]
            var usage = (object["usage"] as? [String: Any]) ?? [:]
            usage["cost"] = 0.0003
            object["usage"] = usage
            object["provider"] = "Cohere"
            return .init(body: String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
        }
        defer { serverD.route = baseDRoute }
        let extractURL = "https://example.test/or-extract"
        fixtures.pages[extractURL] = "# OR page\n\n" + String(repeating: "OpenRouter extraction page text. ", count: 700)
        serverA.clear(); serverB.clear(); serverC.clear(); serverD.clear()
        let (extracted, extractCalls, fetched, pinnedExtract) = await withMainSlots(routerMain) { () -> (WebOrchestrator.WebExtractOutcome?, Int, String?, [WebFixtureServer.Request]) in
            let e = try? await orchestrator.executeWebExtract(requests: [.init(url: extractURL, focus: "facts")], mode: .webSearch)
            let calls = serverD.requests.count
            let f = try? await orchestrator.readUrlContentWithMetadata(url: extractURL, prompt: "what is on it", refresh: true).result.content
            let before = serverD.requests.count
            try? OpenRouterProviderPin.setPin(["together"])
            _ = try? await orchestrator.executeWebExtract(requests: [.init(url: extractURL, focus: "pinned")], mode: .webSearch)
            try? OpenRouterProviderPin.setPin(nil)
            return (e, calls, f, Array(serverD.requests.dropFirst(before)))
        }
        let stagesD = pageStages(serverD)
        func provider(_ r: WebFixtureServer.Request) -> [String: Any] { (body(r)["provider"] as? [String: Any]) ?? [:] }
        func effortOf(_ r: WebFixtureServer.Request) -> String? { (body(r)["reasoning"] as? [String: Any])?["effort"] as? String }
        let excerptStages = stagesD.filter { text($0).contains("Cite verbatim and in full") }
        let fetchStages = stagesD.filter { text($0).contains("You extract information from a web page") }
        check("19.11 OpenRouter main: web_extract's excerpt stage and web_fetch compression go to OpenRouter (D) with the OpenRouter key, deepseek/deepseek-v4-flash-0731, reasoning low, provider sort=throughput; nothing on the /websearch backend",
              !excerptStages.isEmpty && !fetchStages.isEmpty && pageStages(serverB).isEmpty && pageStages(serverC).isEmpty
              && stagesD.allSatisfy { $0.path == "/api/v1/chat/completions" && $0.headers["authorization"] == "Bearer synthetic-or-key"
                  && body($0)["model"] as? String == "deepseek/deepseek-v4-flash-0731" && effortOf($0) == "low"
                  && provider($0)["sort"] as? String == "throughput" && provider($0)["only"] == nil }
              && excerptStages.allSatisfy { provider($0)["require_parameters"] as? Bool == true && body($0)["response_format"] != nil }
              && extracted?.docs.isEmpty == false && fetched?.contains("COMPRESSED: deepseek page") == true,
              "\(stagesD.count) stages: \(stagesD.map { "\(body($0)["model"] as? String ?? "nil")/\(effortOf($0) ?? "nil")/\(provider($0))" })")
        check("19.12 extraction spend is the served host's reported cost (0.0003 per stage call on OpenRouter), not a Luna estimate",
              extractCalls > 0 && near(extracted?.spendUSD, 0.0003 * Double(extractCalls)), "\(extracted?.spendUSD ?? -1) over \(extractCalls) calls")
        let pinnedStages = stageFilter(pinnedExtract)
        check("19.13 an /orprovider pin governs the main model only: the extractor keeps sort=throughput and never sends the pinned host list",
              !pinnedStages.isEmpty && pinnedStages.allSatisfy { provider($0)["only"] == nil && provider($0)["sort"] as? String == "throughput" && provider($0)["allow_fallbacks"] as? Bool == true },
              "\(pinnedStages.map { provider($0) })")
        // Legacy loop on an OpenRouter main: agent rounds on the main model, fetch_and_extract on DeepSeek.
        serverD.clear()
        let legacyURL = "https://example.test/or-legacy"
        fixtures.pages[legacyURL] = "# Legacy OR\n\n" + String(repeating: "Legacy page text. ", count: 700)
        let scriptRounds = [WebFixtureServer.chatBody("fetching", calls: [("fetch_and_extract", "{\"requests\":[{\"url\":\"\(legacyURL)\",\"focus\":\"facts\"}]}")]),
                            WebFixtureServer.chatBody("searching", calls: [("search", "{\"queries\":[\"or legacy\"]}")]),
                            WebFixtureServer.chatBody("OR legacy answer <\(legacyURL)>")]
        serverD.script(scriptRounds)
        // No service: the main OpenRouter transport's URL is a literal (no
        // loopback seam), so the loop's agent rounds run on the pipeline's own
        // OpenRouter transport here (D) — this row is about the page stage.
        let orLegacy = try? await withMainSlots(routerMain) { try await orchestrator.executeForTool(query: "or legacy?", agentService: nil) }
        let orLegacyRounds = legacy(serverD), orLegacyStages = pageStages(serverD)
        check("19.14 legacy loop's fetch_and_extract while OpenRouter is the main provider: the page stage on deepseek/deepseek-v4-flash-0731 at low with sort=throughput (agent rounds are not rerouted to the extractor)",
              orLegacy?.summary.contains("OR legacy answer") == true && orLegacyRounds.count == 3
              && orLegacyRounds.allSatisfy { body($0)["model"] as? String != "deepseek/deepseek-v4-flash-0731" }
              && !orLegacyStages.isEmpty && orLegacyStages.allSatisfy { body($0)["model"] as? String == "deepseek/deepseek-v4-flash-0731" && effortOf($0) == "low" && provider($0)["sort"] as? String == "throughput" },
              "\(orLegacy?.summary.prefix(80) ?? "nil") rounds \(orLegacyRounds.map { body($0)["model"] as? String ?? "nil" }) stages \(orLegacyStages.map { body($0)["model"] as? String ?? "nil" })")
        // Other providers unchanged: a custom main keeps the /websearch backend and the pipeline model.
        serverB.clear(); serverD.clear()
        WebSearchBackend.processOverride = nil
        let savedSelection = UserDefaults.standard.string(forKey: WebSearchBackend.selectionKey)
        UserDefaults.standard.set("opencode", forKey: WebSearchBackend.selectionKey)
        let customURL = "https://example.test/custom-main-extract"
        fixtures.pages[customURL] = "# Custom\n\n" + String(repeating: "Custom main page text. ", count: 700)
        _ = try? await orchestrator.executeWebExtract(requests: [.init(url: customURL, focus: "custom main")], mode: .webSearch)
        if let savedSelection { UserDefaults.standard.set(savedSelection, forKey: WebSearchBackend.selectionKey) } else { UserDefaults.standard.removeObject(forKey: WebSearchBackend.selectionKey) }
        let customStages = pageStages(serverB)
        check("19.15 other main providers unchanged: a custom main keeps extraction on the /websearch backend (opencode here) with its pipeline model; nothing on OpenRouter",
              !customStages.isEmpty && pageStages(serverD).isEmpty && customStages.allSatisfy { body($0)["model"] as? String == "mimo-v2.6-flash" && body($0)["provider"] == nil },
              "\(customStages.count) B, \(pageStages(serverD).count) D")
        WebSearchBackend.processOverride = .opencode
    }
}
