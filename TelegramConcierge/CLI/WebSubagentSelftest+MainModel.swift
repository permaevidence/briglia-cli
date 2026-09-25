import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Shared fixture helpers for the "researcher runs the main model" rules
// (owner decision 2026-09-25). The main provider is whatever the runtime
// slots say, read per request by OpenRouterService, so a block can point
// them at a loopback fixture and restore every slot byte for byte after.
extension WebSubagentSelftest {
    /// The runtime slots of an OpenAI-compatible main profile (OpenCode,
    /// OpenAI, custom, subscription) at `base`.
    static func mainSlots(profile: String, base: String, model: String, key: String, effort: String?,
                          responses: Bool, textOnly: Bool = false) -> [String: String?] {
        [ProviderProfiles.activeProfileKey: profile,
         KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
         KeychainHelper.openAICompatibleBaseURLKey: base,
         KeychainHelper.openAICompatibleModelKey: model,
         KeychainHelper.openAICompatibleApiKeyKey: key,
         KeychainHelper.openAICompatibleReasoningEffortKey: effort,
         ProviderProfiles.runtimeProtocolKey: responses ? ProviderWireProtocol.responses.rawValue : nil,
         ProviderProfiles.runtimeNativeMediaKey: nil,
         KeychainHelper.textOnlyModelEnabledKey: textOnly ? "true" : "false"]
    }

    /// Apply `slots` for the duration of `body`, then restore each slot to
    /// its previous value (absent keys are deleted again).
    static func withMainSlots<T>(_ slots: [String: String?], _ body: () async throws -> T) async rethrows -> T {
        let before = KeychainHelper.loadSnapshot()
        try? KeychainHelper.saveBatch(slots)
        defer {
            var restore: [String: String?] = [:]
            for key in slots.keys { restore.updateValue(before[key], forKey: key) }
            try? KeychainHelper.saveBatch(restore)
        }
        return try await body()
    }
}

// Group 18: the researcher (and the legacy loop's agent rounds) run the MAIN
// agent's provider, model and effort; extraction, web_fetch compression and
// OCR stay on the /websearch backend (owner decision 2026-09-25).
extension WebSubagentSelftest {
    static func runMainModelGroups(_ h: Harness) async throws {
        print("18. Researcher on the main model (owner decision 2026-09-25)")
        let fixtures = h.fixtures, images = h.images, documents = h.documents, service = h.service
        let serverA = h.serverA, serverB = h.serverB, serverC = h.serverC, serverS = h.serverS
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        let body = h.body
        func text(_ request: WebFixtureServer.Request) -> String { String(decoding: request.body, as: UTF8.self) }
        func research(_ server: WebFixtureServer) -> [WebFixtureServer.Request] {
            server.requests.filter { text($0).contains("You are the web research subagent") }
        }
        func legacy(_ server: WebFixtureServer) -> [WebFixtureServer.Request] {
            server.requests.filter { text($0).contains("You are a research agent") || text($0).contains("You are a deep research agent") }
        }
        func pageStages(_ server: WebFixtureServer) -> [WebFixtureServer.Request] {
            server.requests.filter { text($0).contains("Cite verbatim and in full") || text($0).contains("You extract information from a web page") }
        }
        func effort(_ request: WebFixtureServer.Request) -> String? {
            let b = body(request)
            return (b["reasoning_effort"] as? String) ?? ((b["reasoning"] as? [String: Any])?["effort"] as? String)
        }
        func toolNamesIn(_ request: WebFixtureServer.Request) -> [String] {
            ((body(request)["tools"] as? [[String: Any]]) ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String ?? $0["name"] as? String }
        }
        h.state.webFlag = true
        WebSearchBackend.processOverride = .opencode
        fixtures.serperMode = .normal
        defer { h.state.webFlag = false; WebSearchBackend.processOverride = .opencode }
        let all = AvailableTools.all(includeWebSearch: true)
        let executor = ToolExecutor(outputMode: .subagent)
        await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        let longURL = "https://example.test/main-model-long"
        fixtures.pages[longURL] = String(repeating: "main model long page text ", count: 700)
        fixtures.excerptResponse = "{\"excerpts\":[\"main model excerpt\"]}"
        func web(_ prompt: String) -> SubagentRunner.Invocation {
            SubagentRunner.Invocation(subagentType: "Web", description: "main-model", taskPrompt: prompt, modelOverride: nil, runInBackground: false, deliverable: .short)
        }
        func run(_ invocation: SubagentRunner.Invocation, session: String? = nil) async -> SubagentRunner.RunResult {
            await SubagentRunner().run(invocation: invocation, sessionId: session, openRouterService: service, toolExecutor: executor,
                                       imagesDirectory: images, documentsDirectory: documents, parentTools: all)
        }
        let opencodeMain = mainSlots(profile: "opencode", base: h.baseB + "/zen/go/v1", model: "mimo-v2.6-pro",
                                     key: "synthetic-main-opencode-key", effort: "xhigh", responses: false)

        // 18.1 OpenCode chat main: MiMo with the main effort folded (xhigh → high).
        serverA.clear(); serverB.clear()
        serverB.script([WebFixtureServer.chatBody("reading", calls: [("web_extract", "{\"requests\":[{\"url\":\"\(longURL)\",\"focus\":\"facts\"}]}")]),
                        WebFixtureServer.chatBody("Main-model answer. Sources: \(longURL)")])
        let oc = await withMainSlots(opencodeMain) { await run(web("OpenCode main?")) }
        let ocRounds = research(serverB), ocStages = pageStages(serverB)
        let session1 = ocRounds.first?.headers["x-opencode-session"]
        check("18.1 OpenCode chat main: every research round on the main OpenCode endpoint with the MAIN key and model, the main effort through the MiMo fold (xhigh → high), nothing on A",
              oc.error == nil && ocRounds.count == 2 && serverA.requests.isEmpty
              && ocRounds.allSatisfy { $0.path == "/zen/go/v1/chat/completions" && $0.headers["authorization"] == "Bearer synthetic-main-opencode-key"
                  && body($0)["model"] as? String == "mimo-v2.6-pro" && effort($0) == "high" }
              && oc.modelUsed == "mimo-v2.6-pro (inherited)",
              oc.error ?? "rounds \(ocRounds.count) models \(ocRounds.map { body($0)["model"] as? String ?? "nil" }) efforts \(ocRounds.map { effort($0) ?? "nil" })")
        check("18.2 the page extractor is unchanged: its stage runs on the web backend with the WEB key and the pipeline model, never the main model",
              !ocStages.isEmpty && ocStages.allSatisfy { $0.headers["authorization"] == "Bearer synthetic-web-opencode-key" && body($0)["model"] as? String == "mimo-v2.6-flash" },
              "\(ocStages.count) stages, models \(ocStages.map { body($0)["model"] as? String ?? "nil" })")
        serverB.clear()
        serverB.script([WebFixtureServer.chatBody("Second session answer."), WebFixtureServer.chatBody("Second session answer.")])
        _ = await withMainSlots(opencodeMain) { await run(web("Another question?")) }
        let session2 = research(serverB).first?.headers["x-opencode-session"]
        check("18.3 affinity stays per Web session: one x-opencode-session across a run's rounds, a different one for another session",
              session1 != nil && ocRounds.allSatisfy { $0.headers["x-opencode-session"] == session1 } && session2 != nil && session2 != session1,
              "\(session1 ?? "nil") \(session2 ?? "nil")")

        // 18.4 OpenCode Responses main (a GPT model on OpenCode Go).
        serverB.clear()
        serverB.script([WebFixtureServer.responsesBody("OpenCode Responses answer.", id: "ocr1"), WebFixtureServer.responsesBody("OpenCode Responses answer.", id: "ocr2")])
        let ocr = await withMainSlots(mainSlots(profile: "opencode", base: h.baseB + "/zen/go/v1", model: "gpt-5.6-luna",
                                                key: "synthetic-main-opencode-key", effort: "medium", responses: false)) { await run(web("OpenCode Responses main?")) }
        let ocrRounds = research(serverB)
        check("18.4 OpenCode Responses main: the research rounds use the main Responses transport on OpenCode (per-model protocol) with the main model and effort",
              ocr.error == nil && !ocrRounds.isEmpty
              && ocrRounds.allSatisfy { $0.path == "/zen/go/v1/responses" && body($0)["model"] as? String == "gpt-5.6-luna" && effort($0) == "medium"
                  && $0.headers["authorization"] == "Bearer synthetic-main-opencode-key" },
              ocr.error ?? "\(ocrRounds.map { $0.path })")

        // 18.5 OpenAI API main (Responses): the main effort, not a forced high.
        serverC.clear()
        serverC.script([WebFixtureServer.responsesBody("OpenAI main answer.", id: "oa1"), WebFixtureServer.responsesBody("OpenAI main answer.", id: "oa2")])
        let oa = await withMainSlots(mainSlots(profile: "openai", base: h.baseC + "/v1", model: "gpt-6-sol",
                                               key: "synthetic-main-openai-key", effort: "low", responses: true)) { await run(web("OpenAI main?")) }
        let oaRounds = research(serverC)
        check("18.5 OpenAI API main: Responses on the main endpoint with the main key, gpt-6-sol and the main effort 'low' (no forced high, no GPT-6 Luna)",
              oa.error == nil && !oaRounds.isEmpty
              && oaRounds.allSatisfy { $0.path == "/v1/responses" && body($0)["model"] as? String == "gpt-6-sol" && effort($0) == "low"
                  && $0.headers["authorization"] == "Bearer synthetic-main-openai-key" && body($0)["store"] as? Bool == false },
              oa.error ?? "\(oaRounds.count)")

        // 18.6 Local server main, text-only: the researcher runs; nothing refuses.
        serverA.clear()
        serverA.script([WebFixtureServer.chatBody("Local answer."), WebFixtureServer.chatBody("Local answer.")])
        let localSlots: [String: String?] = [ProviderProfiles.activeProfileKey: "local", KeychainHelper.llmProviderKey: LLMProvider.lmStudio.rawValue,
                                             KeychainHelper.lmStudioBaseURLKey: h.baseA, KeychainHelper.lmStudioModelKey: "local-model",
                                             KeychainHelper.textOnlyModelEnabledKey: "true", ProviderProfiles.runtimeProtocolKey: nil]
        let local = await withMainSlots(localSlots) { await run(web("Local main?")) }
        let localRounds = research(serverA)
        check("18.6 local server main, text-only model: the researcher runs on it (no vision needed, nothing refuses), no reasoning field sent",
              local.error == nil && !localRounds.isEmpty
              && localRounds.allSatisfy { $0.path == "/v1/chat/completions" && body($0)["model"] as? String == "local-model" && effort($0) == nil }
              && local.modelUsed == "local-model (inherited)", local.error ?? local.asJSON())

        // 18.7 OpenRouter main with an /orprovider pin: the researcher carries it.
        let routerSlots: [String: String?] = [ProviderProfiles.activeProfileKey: "openrouter", KeychainHelper.llmProviderKey: LLMProvider.openRouter.rawValue,
                                              KeychainHelper.openRouterModelKey: "deepseek/deepseek-v4.1-flash", KeychainHelper.openRouterReasoningEffortKey: "medium",
                                              ProviderProfiles.runtimeProtocolKey: nil]
        let (pinned, unpinned) = await withMainSlots(routerSlots) { () -> (ProviderExecutionContext, ProviderExecutionContext) in
            try? OpenRouterProviderPin.setPin(["together"])
            let p = await service.researcherExecutionContext(modelOverride: nil, textOnlyOverride: nil, lane: .subagent("pin-web"))
            try? OpenRouterProviderPin.setPin(nil)
            let u = await service.researcherExecutionContext(modelOverride: nil, textOnlyOverride: nil, lane: .subagent("pin-web"))
            return (p, u)
        }
        check("18.7 OpenRouter main with an /orprovider pin: the researcher context is the main model on the pinned host (only + no fallbacks) with the main effort; released pin → automatic routing",
              pinned.provider == .openRouter && pinned.model == "deepseek/deepseek-v4.1-flash" && pinned.providerPreferences?.only == ["together"]
              && pinned.providerPreferences?.allow_fallbacks == false && pinned.reasoning?.effort == "medium"
              && unpinned.providerPreferences == nil && unpinned.model == "deepseek/deepseek-v4.1-flash",
              "\(pinned.model) \(String(describing: pinned.providerPreferences))")

        // 18.8 A /model change during a run never reaches it; the next run follows.
        serverA.clear()
        let baseRoute = serverS.route
        serverS.route = { request in
            if request.method == "POST", request.path.hasSuffix("/search"), String(decoding: request.body, as: UTF8.self).contains("switch-now") {
                try? KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "switched-model")
            }
            return baseRoute?(request) ?? .init(status: 404, body: "{}")
        }
        serverA.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"switch-now\"]}")]), WebFixtureServer.chatBody("Answer before the switch.")])
        let during = await run(web("Mid-run model change?"))
        let duringRounds = research(serverA)
        serverS.route = baseRoute
        serverA.clear()
        serverA.script([WebFixtureServer.chatBody("Answer after the switch."), WebFixtureServer.chatBody("Answer after the switch.")])
        let after = await run(web("After the model change?"), session: during.sessionId)
        let afterRounds = research(serverA)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "main-model")
        check("18.8 /model mid-run: the running research run keeps the model it started with on every round; the next run (a resume) follows the new main model",
              during.error == nil && duringRounds.count == 2 && duringRounds.allSatisfy { body($0)["model"] as? String == "main-model" }
              && after.error == nil && !afterRounds.isEmpty && afterRounds.allSatisfy { body($0)["model"] as? String == "switched-model" },
              "\(duringRounds.map { body($0)["model"] as? String ?? "nil" }) → \(afterRounds.map { body($0)["model"] as? String ?? "nil" })")

        // 18.9 Spend: the main transport's pricing (the provider-reported cost here), not Luna rates.
        func costBody(_ text: String, calls: [(String, String)] = [], cost: Double) -> String {
            var object = (try? JSONSerialization.jsonObject(with: Data(WebFixtureServer.chatBody(text, calls: calls).utf8)) as? [String: Any]) ?? [:]
            var usage = (object["usage"] as? [String: Any]) ?? [:]
            usage["cost"] = cost
            object["usage"] = usage
            return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        serverA.clear()
        serverA.script([costBody("searching", calls: [("web_query", "{\"queries\":[\"priced\"]}")], cost: 0.0125), costBody("Priced answer.", cost: 0.0075)])
        let priced = await run(web("Priced?"))
        check("18.9 spend: researcher tokens are priced by the main transport (provider-reported cost 0.0125 + 0.0075), not by GPT-6 Luna rates",
              priced.error == nil && abs(priced.spendUSD - 0.02) < 1e-9, "\(priced.spendUSD) \(priced.error ?? "")")

        // 18.10 Cross-provider resume: Responses (with encrypted reasoning) → OpenCode chat → Responses.
        serverC.clear()
        let encrypted: String = {
            var object = (try? JSONSerialization.jsonObject(with: Data(WebFixtureServer.responsesBody("searching", id: "x1", calls: [("web_query", "{\"queries\":[\"crossover\"]}")]).utf8)) as? [String: Any]) ?? [:]
            var output = (object["output"] as? [[String: Any]]) ?? []
            output.insert(["type": "reasoning", "id": "rs_x1", "encrypted_content": "ENC-CROSS-SECRET", "summary": [["type": "summary_text", "text": "planning the crossover search"]]], at: 0)
            object["output"] = output
            return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }()
        serverC.script([encrypted, WebFixtureServer.responsesBody("Crossover answer.", id: "x2")])
        let responsesSlots = mainSlots(profile: "openai", base: h.baseC + "/v1", model: "gpt-6-sol", key: "synthetic-main-openai-key", effort: "high", responses: true)
        let first = await withMainSlots(responsesSlots) { await run(web("Crossover?")) }
        serverB.clear()
        serverB.script([WebFixtureServer.chatBody("Resumed on OpenCode."), WebFixtureServer.chatBody("Resumed on OpenCode.")])
        let onChat = await withMainSlots(opencodeMain) { await run(web("Crossover follow-up?"), session: first.sessionId) }
        let chatBody = research(serverB).first.map(text) ?? ""
        let chatMessages = (research(serverB).first.map { (body($0)["messages"] as? [[String: Any]]) ?? [] }) ?? []
        check("18.10 resume on another provider (Responses → OpenCode chat): succeeds on the new main model; the earlier web_query round is replayed as chat history; no encrypted reasoning crosses providers",
              first.error == nil && onChat.error == nil && !chatBody.isEmpty
              && chatMessages.contains { ($0["tool_calls"] as? [[String: Any]])?.contains { (($0["function"] as? [String: Any])?["name"] as? String) == "web_query" } == true }
              && chatMessages.contains { $0["role"] as? String == "tool" }
              && !chatBody.contains("ENC-CROSS-SECRET") && !chatBody.contains("encrypted_content"),
              onChat.error ?? String(chatBody.prefix(300)))
        serverC.clear()
        serverC.script([WebFixtureServer.responsesBody("Back on Responses.", id: "x3"), WebFixtureServer.responsesBody("Back on Responses.", id: "x4")])
        let back = await withMainSlots(responsesSlots) { await run(web("Crossover again?"), session: first.sessionId) }
        let backItems = (research(serverC).first.map { (body($0)["input"] as? [[String: Any]]) ?? [] }) ?? []
        check("18.11 and back (chat → Responses): the chat-era history replays semantically (function_call items, no foreign native items) and the run succeeds",
              back.error == nil && backItems.contains { $0["type"] as? String == "function_call" && $0["name"] as? String == "web_query" }
              && backItems.contains { $0["type"] as? String == "function_call_output" },
              back.error ?? "\(backItems.count) items")

        // 18.12 Legacy loop (/websubagent off): agent rounds on the main model, extraction unchanged.
        let orchestrator = WebOrchestrator()
        await orchestrator.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        serverA.clear(); serverB.clear()
        serverB.script([WebFixtureServer.chatBody("fetching", calls: [("fetch_and_extract", "{\"requests\":[{\"url\":\"\(longURL)\",\"focus\":\"facts\"}]}")]),
                        WebFixtureServer.chatBody("searching", calls: [("search", "{\"queries\":[\"legacy main\"]}")]),
                        WebFixtureServer.chatBody("Legacy main answer <\(longURL)>")])
        let legacyResult = try? await withMainSlots(opencodeMain) { try await orchestrator.executeForTool(query: "legacy on main?", agentService: service) }
        let legacyRounds = legacy(serverB), legacyStages = pageStages(serverB)
        check("18.12 legacy web_search loop: every agent round on the main OpenCode endpoint with the main key, model and folded effort, the loop's two tools, no persona/profile",
              legacyResult?.summary.contains("Legacy main answer") == true && legacyRounds.count == 3 && serverA.requests.isEmpty
              && legacyRounds.allSatisfy { $0.path == "/zen/go/v1/chat/completions" && $0.headers["authorization"] == "Bearer synthetic-main-opencode-key"
                  && body($0)["model"] as? String == "mimo-v2.6-pro" && effort($0) == "high"
                  && Set(toolNamesIn($0)) == ["search", "fetch_and_extract"] && !text($0).contains("Fixture User") }
              && legacyResult?.searchQueriesUsed == ["legacy main"],
              "rounds \(legacyRounds.count) result \(legacyResult?.summary.prefix(60) ?? "nil")")
        let secondLegacy = legacyRounds.count >= 2 ? ((body(legacyRounds[1])["messages"] as? [[String: Any]]) ?? []) : []
        check("18.12b legacy loop transcript: the second round replays the first round's fetch_and_extract call and its tool result (main serializer)",
              secondLegacy.contains { ($0["tool_calls"] as? [[String: Any]])?.contains { (($0["function"] as? [String: Any])?["name"] as? String) == "fetch_and_extract" } == true }
              && secondLegacy.contains { $0["role"] as? String == "tool" && (($0["content"] as? String) ?? "").contains("main model excerpt") },
              "\(secondLegacy.count) messages")
        check("18.13 legacy loop extraction unchanged: fetch_and_extract's page stage on the web backend with the web key and the pipeline model",
              !legacyStages.isEmpty && legacyStages.allSatisfy { $0.headers["authorization"] == "Bearer synthetic-web-opencode-key" && body($0)["model"] as? String == "mimo-v2.6-flash" },
              "\(legacyStages.count)")

        // 18.14 Legacy loop on a Responses main: zero-search nudge as the next request's tail, main effort.
        serverC.clear()
        serverC.script([WebFixtureServer.responsesBody("From memory.", id: "lg1"),
                        WebFixtureServer.responsesBody("searching", id: "lg2", calls: [("search", "{\"queries\":[\"legacy responses\"]}")]),
                        WebFixtureServer.responsesBody("Legacy Responses answer <https://example.test/legacy-responses>", id: "lg3")])
        let legacyResponses = try? await withMainSlots(mainSlots(profile: "openai", base: h.baseC + "/v1", model: "gpt-6-sol",
                                                                  key: "synthetic-main-openai-key", effort: "low", responses: true)) {
            try await orchestrator.executeForTool(query: "legacy on responses?", agentService: service)
        }
        let lrRounds = legacy(serverC)
        let secondTail = lrRounds.count >= 2 ? (((body(lrRounds[1])["input"] as? [[String: Any]]) ?? []).last.map { item -> String in
            ((item["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined() } ?? "") : ""
        check("18.14 legacy loop on a Responses main: rounds on the main endpoint with gpt-6-sol and the main effort 'low'; the zero-search nudge rides as the next request's tail; the answer comes back",
              legacyResponses?.summary.contains("Legacy Responses answer") == true && lrRounds.count == 3
              && lrRounds.allSatisfy { $0.path == "/v1/responses" && body($0)["model"] as? String == "gpt-6-sol" && effort($0) == "low" }
              && secondTail.contains("No search has been attempted yet"),
              "rounds \(lrRounds.count) tail \(secondTail.prefix(80))")

        // Legacy loop: a /model change mid-loop never reaches the running loop.
        serverA.clear()
        let legacyBaseRoute = serverS.route
        serverS.route = { request in
            if request.method == "POST", request.path.hasSuffix("/search"), String(decoding: request.body, as: UTF8.self).contains("legacy-switch") {
                try? KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "switched-model")
            }
            return legacyBaseRoute?(request) ?? .init(status: 404, body: "{}")
        }
        serverA.script([WebFixtureServer.chatBody("searching", calls: [("search", "{\"queries\":[\"legacy-switch\"]}")]), WebFixtureServer.chatBody("Legacy before switch <https://example.test/s>")])
        let legacySwitch = try? await orchestrator.executeForTool(query: "legacy mid-run switch?", agentService: service)
        serverS.route = legacyBaseRoute
        let legacySwitchRounds = legacy(serverA)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "main-model")
        check("18.16 legacy loop /model mid-run: the snapshot taken at the loop's start serves every round",
              legacySwitch != nil && legacySwitchRounds.count == 2 && legacySwitchRounds.allSatisfy { body($0)["model"] as? String == "main-model" },
              "\(legacySwitchRounds.map { body($0)["model"] as? String ?? "nil" })")

        // 18.15 Legacy loop spend: the main transport's pricing.
        serverA.clear()
        serverA.script([costBody("searching", calls: [("search", "{\"queries\":[\"legacy priced\"]}")], cost: 0.004), costBody("Legacy priced <https://example.test/p>", cost: 0.006)])
        let legacyPriced = try? await orchestrator.executeForTool(query: "legacy priced?", agentService: service)
        check("18.15 legacy loop spend is the main transport's (provider-reported 0.004 + 0.006)",
              legacyPriced.map { abs(($0.spendUSD ?? 0) - 0.01) < 1e-9 } == true, "\(legacyPriced?.spendUSD ?? -1)")
    }
}
