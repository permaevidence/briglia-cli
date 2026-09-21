import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Web researcher subagent (WEB_SUBAGENT_PLAN §6, R1a groups 1–5, 8–11
/// partial, 12). Hermetic: scripted loopback fixtures for the main profile
/// (A), the web backends (B OpenCode, C OpenAI Responses, D OpenRouter),
/// Serper and the Jina reader (S); isolated XDG roots; the flag seams
/// instead of the machine's UserDefaults; `HarnessClock` pinned.
struct WebSubagentSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__web-subagent-selftest",
        abstract: "Internal: verify the Web researcher subagent (schema gating, tools, provider context, provenance, deliverable, pools, background resume).",
        shouldDisplay: false
    )

    struct Failure: Error, CustomStringConvertible { let description: String }

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else { throw ValidationError("Needs a development build") }
        setenv("TZ", "Europe/Rome", 1)
        NSTimeZone.default = TimeZone(identifier: "Europe/Rome")!
        var total = 0
        var failures = 0
        func check(_ name: String, _ value: Bool, _ detail: String = "") {
            total += 1
            if !value { failures += 1 }
            print("\(value ? "✔" : "✖") \(name)\(value || detail.isEmpty ? "" : " — \(String(detail.prefix(700)))")")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
        }

        // ---- Isolation.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-websub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, child) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(name, root.appendingPathComponent(child).path, 1)
        }
        UserDefaults.standard.setVolatileDomain([
            "ada.applyPatchEnabled": false, "ada.shortcutsEnabled": false,
            KeychainHelper.serviceKeysMetadataDefaultsKey: Data("[]".utf8)
        ], forName: UserDefaults.argumentDomain)
        FileDescriptionsStore._testStoreURL = root.appendingPathComponent("descriptions.json")
        let images = root.appendingPathComponent("images"), documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: "Fixture Assistant")
        try KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Fixture User")
        try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: EmailCalendarProvider.none.rawValue)
        try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "250000")
        try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "synthetic-serper-key")
        try KeychainHelper.save(key: KeychainHelper.jinaApiKeyKey, value: "synthetic-jina-key")
        let state = MutableState(clock: at(2026, 4, 10, 10, 0, 0), subagentsFlag: true, webFlag: false)
        HarnessClock.overrideForTesting = { state.clock }
        defer { HarnessClock.overrideForTesting = nil }
        // Flag seams (never the machine's UserDefaults).
        AvailableTools.subagentsStoredFlagOverrideForTesting = { state.subagentsFlag }
        AvailableTools.webSubagentStoredFlagOverrideForTesting = { state.webFlag }
        defer {
            AvailableTools.subagentsStoredFlagOverrideForTesting = nil
            AvailableTools.webSubagentStoredFlagOverrideForTesting = nil
            WebSearchBackend.processOverride = nil
            OpenRouterService.chatRetryTestHooks = .init()
        }

        // ---- Fixtures: A (main), B (OpenCode web backend), C (OpenAI Responses), D (OpenRouter), S (Serper + reader).
        let serverA = try WebFixtureServer(), serverB = try WebFixtureServer(), serverC = try WebFixtureServer()
        let serverD = try WebFixtureServer(), serverS = try WebFixtureServer()
        defer { serverA.stop(); serverB.stop(); serverC.stop(); serverD.stop(); serverS.stop() }
        let baseA = "http://127.0.0.1:\(serverA.port)", baseB = "http://127.0.0.1:\(serverB.port)"
        let baseC = "http://127.0.0.1:\(serverC.port)", baseD = "http://127.0.0.1:\(serverD.port)", baseS = "http://127.0.0.1:\(serverS.port)"
        setenv("BRIGLIA_DEV_AFFINITY_OPENCODE_BASE", baseB, 1)
        setenv("BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE", baseD, 1)
        setenv("BRIGLIA_DEV_WEB_OPENAI_BASE", baseC + "/v1", 1)
        setenv("BRIGLIA_DEV_SERPER_BASE", baseS, 1)
        setenv("BRIGLIA_DEV_JINA_READER_BASE", baseS + "/reader/", 1)
        try KeychainHelper.save(key: KeychainHelper.webSearchOpenCodeApiKeyKey, value: "synthetic-web-opencode-key")
        try KeychainHelper.save(key: KeychainHelper.webSearchOpenAIApiKeyKey, value: "synthetic-web-openai-key")
        WebSearchBackend.processOverride = .opencode

        // Serper / reader fixture state.
        let fixtures = WebFixtureState()
        serverS.route = { request in
            if request.method == "POST", request.path.hasSuffix("/search") {
                fixtures.serperCalls += 1
                let query = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["q"] as? String ?? "?"
                fixtures.serperQueries.append(query)
                switch fixtures.serperMode {
                case .failing: return .init(status: 500, body: "{\"error\":\"injected\"}")
                case .empty: return .init(body: "{\"organic\":[]}")
                case .answerBoxOnly: return .init(body: "{\"organic\":[],\"answerBox\":{\"answer\":\"42\",\"snippet\":\"The answer to \(query) is 42.\"}}")
                case .normal:
                    let slug = query.lowercased().replacingOccurrences(of: " ", with: "-")
                    let organic: [[String: Any]] = [
                        ["title": "Result for \(query)", "link": "https://example.test/\(slug)", "snippet": "Snippet about \(query)."],
                        ["title": "Second for \(query)", "link": "https://example.test/\(slug)-2", "snippet": "More about \(query)."]]
                    let body = try! JSONSerialization.data(withJSONObject: ["organic": organic])
                    return .init(body: String(decoding: body, as: UTF8.self))
                }
            }
            if request.method == "GET", request.path.hasPrefix("/reader/") {
                let target = String(request.path.dropFirst("/reader/".count))
                fixtures.readerGets.append(target)
                let page = fixtures.pages[target] ?? "# Page\n\nPage text for \(target). Nothing to see."
                return .init(contentType: "text/plain", body: page)
            }
            return .init(status: 404, body: "{}")
        }
        // Model fixtures: pipeline stages (compression, excerpts, assets) are
        // answered mechanically; agent rounds pop the server's script queue.
        func modelRoute(_ server: WebFixtureServer, responses: Bool) -> @Sendable (WebFixtureServer.Request) -> WebFixtureServer.Response {
            { request in
                let text = String(decoding: request.body, as: UTF8.self)
                if text.contains("You extract information from a web page") {
                    let start = text.range(of: "--- PAGE CONTENT (markdown) ---")?.upperBound ?? text.startIndex
                    let end = text.range(of: "--- END PAGE CONTENT ---")?.lowerBound ?? text.endIndex
                    let raw = String(text[start..<end]).replacingOccurrences(of: "\\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    return .init(body: WebFixtureServer.chatBody("COMPRESSED: " + raw))
                }
                if text.contains("Cite verbatim and in full") {
                    return .init(body: WebFixtureServer.chatBody(fixtures.excerptResponse))
                }
                if text.contains("focus-relevant page assets") {
                    return .init(body: WebFixtureServer.chatBody("{\"links\":[],\"images\":[]}"))
                }
                if let status = server.popStatus(), status != 200 {
                    return .init(status: status, body: "{\"error\":{\"message\":\"injected \(status)\"}}")
                }
                guard let scripted = server.popScript() else {
                    return .init(status: 500, body: "{\"error\":{\"message\":\"no scripted response\"}}")
                }
                _ = responses  // a JSON snapshot is accepted by the Responses decoder (no SSE framing needed)
                return .init(body: scripted)
            }
        }
        serverA.route = modelRoute(serverA, responses: false)
        serverB.route = modelRoute(serverB, responses: false)
        serverC.route = modelRoute(serverC, responses: true)
        serverD.route = modelRoute(serverD, responses: false)

        // Main profile A: custom loopback, chat completions.
        try ProviderProfiles.saveProfile(.custom, apiKey: "synthetic-main-key", baseURL: baseA + "/v1", model: "main-model",
                                         effort: nil, textOnly: false, wireProtocol: .chatCompletions)
        try ProviderProfiles.activate(.custom)
        let service = OpenRouterService(); await service.configure(apiKey: "synthetic-main-key")

        func toolNames(_ tools: [ToolDefinition]) -> [String] { tools.map { $0.function.name } }
        func toolJSON(_ tools: [ToolDefinition]) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(tools)
        }
        func chatMessages(_ request: WebFixtureServer.Request) throws -> [(String, String)] {
            let object = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            return (object["messages"] as! [[String: Any]]).map { message in
                let role = message["role"] as! String
                if let text = message["content"] as? String { return (role, text) }
                let parts = (message["content"] as? [[String: Any]]) ?? []
                return (role, parts.compactMap { $0["text"] as? String }.joined(separator: "\u{1}"))
            }
        }
        func body(_ request: WebFixtureServer.Request) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
        }
        func resultJSON(_ result: SubagentRunner.RunResult) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(result.asJSON().utf8)) as? [String: Any]) ?? [:]
        }
        func agentRequests(_ server: WebFixtureServer) -> [WebFixtureServer.Request] {
            server.requests.filter { request in
                let text = String(decoding: request.body, as: UTF8.self)
                return !text.contains("You extract information from a web page") && !text.contains("Cite verbatim and in full") && !text.contains("focus-relevant page assets")
            }
        }
        let webQueryCall = { (id: String, queries: [String]) -> (String, String) in
            ("web_query", "{\"queries\":\(String(decoding: try! JSONSerialization.data(withJSONObject: queries), as: UTF8.self))}")
        }
        let webExtractCall = { (urls: [String]) -> (String, String) in
            let requests = urls.map { ["url": $0, "focus": "the facts"] }
            return ("web_extract", "{\"requests\":\(String(decoding: try! JSONSerialization.data(withJSONObject: requests), as: UTF8.self))}")
        }

        print("1. Schema and gating")
        do {
            state.webFlag = false
            let off = AvailableTools.all(includeWebSearch: true)
            let offNames = toolNames(off)
            let offAgent = off.first { $0.function.name == "Agent" }!
            check("1.1 switch off: legacy web tools first, no Web in the Agent enum, no deliverable, no refresh, no research note",
                  Array(offNames.prefix(3)) == ["web_search", "web_research_sweep", "web_fetch"]
                  && !(offAgent.function.parameters.properties["subagent_type"]?.enumValues ?? []).contains("Web")
                  && offAgent.function.parameters.properties["deliverable"] == nil
                  && off.first { $0.function.name == "web_fetch" }!.function.parameters.properties["refresh"] == nil
                  && !offAgent.function.description.contains("Web research:")
                  && off.first { $0.function.name == "subagent_manage" }!.function.parameters.properties["kind"] == nil, offNames.joined(separator: ","))
            let legacyBytes = try toolJSON([AvailableTools.webSearch, AvailableTools.webResearchSweep, AvailableTools.webFetch] + AvailableTools.coreToolsWithoutWebSearch)
            check("1.2 switch off: the full tool array serializes byte-identically to the legacy statics", try toolJSON(off) == legacyBytes)
            let offNoWeb = try toolJSON(AvailableTools.all(includeWebSearch: false))
            state.webFlag = true
            let on = AvailableTools.all(includeWebSearch: true)
            let onNames = toolNames(on)
            let onAgent = on.first { $0.function.name == "Agent" }!
            let deliverable = onAgent.function.parameters.properties["deliverable"]
            check("1.3 switch on + web available: no legacy research tools, web_fetch with refresh, Web in the enum, deliverable enum, the R1b delegation sentence, research note, list_sessions kind",
                  !onNames.contains("web_search") && !onNames.contains("web_research_sweep") && onNames.first == "web_fetch"
                  && on.first { $0.function.name == "web_fetch" }!.function.parameters.properties["refresh"]?.type == "boolean"
                  && (onAgent.function.parameters.properties["subagent_type"]?.enumValues ?? []).contains("Web")
                  && deliverable?.enumValues == ["short", "standard", "report"]
                  && onAgent.function.description.contains(AvailableTools.nestingSentenceWhileWebPresent) && !onAgent.function.description.contains("Subagents CANNOT spawn other subagents")
                  && onAgent.function.description.contains("Web research: use subagent_type=Web")
                  && onAgent.function.description.contains("- Web: web research")
                  && on.first { $0.function.name == "subagent_manage" }!.function.parameters.properties["kind"]?.enumValues == ["all", "general", "web"],
                  onNames.joined(separator: ",") + " | " + onAgent.function.description.suffix(300))
            check("1.4 switch on, web search unavailable: byte-identical to switch off", try toolJSON(AvailableTools.all(includeWebSearch: false)) == offNoWeb)
            check("1.5 deliverable validation: non-Web type refused, Web defaults to standard, unknown value refused",
                  ToolExecutor.agentDeliverable("report", subagentType: "general-purpose").error?.contains("only valid for subagent_type=Web") == true
                  && ToolExecutor.agentDeliverable(nil, subagentType: "Web").deliverable == .standard
                  && ToolExecutor.agentDeliverable("epic", subagentType: "Web").error?.contains("Unknown deliverable") == true
                  && ToolExecutor.agentDeliverable(nil, subagentType: "general-purpose").deliverable == nil)
            let web = SubagentTypes.find(name: "web")
            check("1.6 Web preset resolves only while the switch is on; research prompt style; three tools; MCP forbidden",
                  web?.isWebResearcher == true && web?.promptStyle == .research && web?.allowedToolNames == ["web_query", "web_extract", "web_fetch"]
                  && web?.forbidMCP == true && web?.preferredModel.lane == nil)
            state.webFlag = false
            check("1.7 switch off: the Web type is unknown to the runner", SubagentTypes.find(name: "Web") == nil && !SubagentTypes.allNames().contains("Web"))
            state.subagentsFlag = false; state.webFlag = true
            check("1.8 subagents off wins (O5): no Web even with the web flag on", !AvailableTools.webSubagentActive && !toolNames(AvailableTools.all(includeWebSearch: true)).contains("Agent")
                  && toolNames(AvailableTools.all(includeWebSearch: true)).first == "web_search")
            state.subagentsFlag = true; state.webFlag = false
        }

        print("2. Tools")
        do {
            state.webFlag = true
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            let ledger = WebEvidenceLedger(deliverable: .standard)
            await executor.setWebEvidenceLedger(ledger)
            fixtures.serperCalls = 0
            let (qname, qargs) = webQueryCall("q1", ["alpha", "beta", "gamma", "delta", "epsilon"])
            let query = try await executor.executeParallel([ToolCall(id: "q1", type: "function", function: FunctionCall(name: qname, arguments: qargs))])[0]
            let queryObject = body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(query.content.utf8)))
            check("2.1 web_query: 5 queries → 4 executed, dropped_queries 1, hits listed, queries recorded in order",
                  fixtures.serperCalls == 4 && queryObject["dropped_queries"] as? Int == 1
                  && (queryObject["results"] as? [[String: Any]])?.count == 8
                  && ledger.queriesUsed == ["alpha", "beta", "gamma", "delta"], query.content.prefix(300).description)
            fixtures.pages["https://example.test/alpha"] = "# Alpha\n\nAlpha page body with the facts."
            fixtures.readerGets = []
            let (xname, xargs) = webExtractCall(["https://example.test/alpha", "https://example.test/beta", "https://example.test/gamma", "https://example.test/delta"])
            let extract = try await executor.executeParallel([ToolCall(id: "x1", type: "function", function: FunctionCall(name: xname, arguments: xargs))])[0]
            let extractObject = body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(extract.content.utf8)))
            let pages = extractObject["pages"] as? [[String: Any]] ?? []
            let alpha = pages.first { ($0["url"] as? String) == "https://example.test/alpha" }
            check("2.2 web_extract: 4 requests → 3 reader requests, dropped_requests 1, short page passed through raw, fetched_at present",
                  fixtures.readerGets.count == 3 && extractObject["dropped_requests"] as? Int == 1 && pages.count == 3
                  && (alpha?["excerpts"] as? [String]) == ["# Alpha\n\nAlpha page body with the facts."]
                  && (alpha?["fetched_at"] as? String)?.hasPrefix("2026-04-10 10:00:00") == true
                  && alpha?["previously_fetched"] == nil, extract.content.prefix(400).description)
            // Long page → excerpt model; oversized excerpt → clamped and marked.
            fixtures.pages["https://example.test/long"] = String(repeating: "long page text ", count: 700)
            fixtures.excerptResponse = "{\"excerpts\":[\"" + String(repeating: "x", count: 130_000) + "\"]}"
            let (lname, largs) = webExtractCall(["https://example.test/long"])
            let long = try await executor.executeParallel([ToolCall(id: "x2", type: "function", function: FunctionCall(name: lname, arguments: largs))])[0]
            let longObject = body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(long.content.utf8)))
            let longPage = (longObject["pages"] as? [[String: Any]])?.first
            check("2.3 web_extract: long page goes through the excerpt model; a 130k excerpt is clamped to the 120k payload budget and marked excerpts_truncated",
                  longPage?["excerpts_truncated"] as? Bool == true
                  && ((longPage?["excerpts"] as? [String])?.first?.count ?? 0) <= 120_000 + 20, long.content.prefix(200).description)
            let (rname, rargs) = webQueryCall("q2", ["alpha"])
            let again = try await executor.executeParallel([ToolCall(id: "q2", type: "function", function: FunctionCall(name: rname, arguments: rargs))])[0]
            let againHits = (body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(again.content.utf8)))["results"] as? [[String: Any]]) ?? []
            let alphaHit = againHits.first { ($0["link"] as? String) == "https://example.test/alpha" }
            check("2.4 web_query never hides a result: a URL extracted earlier is listed with its retrieval time and in-context flag",
                  againHits.count == 2 && (alphaHit?["previously_retrieved"] as? String)?.hasPrefix("2026-04-10 10:00:00") == true
                  && alphaHit?["extract_in_context"] as? Bool == true, again.content.prefix(400).description)
            check("2.5 ledger: one record per retrieval result; sources_consulted in first-retrieved order; activity counted",
                  ledger.allRecords.filter(\.isExtract).count == 4 && ledger.sourcesConsulted.map(\.url).first == "https://example.test/alpha"
                  && ledger.runActivity.attempted == 4 && ledger.runActivity.usable == 4)
            state.webFlag = false
        }

        print("3. Provider context")
        do {
            state.webFlag = true
            let runner = SubagentRunner()
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            let invocation = SubagentRunner.Invocation(subagentType: "Web", description: "Web fixture", taskPrompt: "What is alpha?",
                                                       modelOverride: nil, runInBackground: false, deliverable: .short)
            let profileBefore = KeychainHelper.loadSnapshot()
            serverA.clear(); serverB.clear(); fixtures.serperCalls = 0
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"alpha\"]}")]),
                            WebFixtureServer.chatBody("Alpha is a letter. Sources: https://example.test/alpha")])
            let first = await runner.run(invocation: invocation, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                         imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            state.webSessionId = first.sessionId
            let bRequests = agentRequests(serverB)
            check("3.1 OpenCode backend: every round on B with B's key and pinned model, high effort, zero requests on A",
                  first.error == nil && bRequests.count == 2 && serverA.requests.isEmpty
                  && bRequests.allSatisfy { $0.headers["authorization"] == "Bearer synthetic-web-opencode-key" && body($0)["model"] as? String == "mimo-v2.6-flash"
                      && body($0)["reasoning_effort"] as? String == "high" && $0.path == "/zen/go/v1/chat/completions" },
                  first.error ?? "\(bRequests.count) B, \(serverA.requests.count) A")
            let sessionHeader = bRequests.first?.headers["x-opencode-session"]
            check("3.2 affinity: x-opencode-session derived from the subagent lane, identical across the run", sessionHeader != nil && bRequests.allSatisfy { $0.headers["x-opencode-session"] == sessionHeader })
            check("3.3 main profile untouched before/after", KeychainHelper.loadSnapshot() == profileBefore)
            check("3.4 result: model_used names the web backend; provenance retrieved_this_run; queries_used; no note",
                  first.modelUsed == "mimo-v2.6-flash (web backend: opencode)" && resultJSON(first)["evidence_provenance"] as? String == "retrieved_this_run"
                  && resultJSON(first)["queries_used"] as? [String] == ["alpha"] && resultJSON(first)["note"] == nil, first.asJSON())
            // Resume: same header, still B; forced final (round limit 1) also on B.
            try AgentTurnOverrides.setOverride(1, forAgent: "Web")
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("more", calls: [("web_query", "{\"queries\":[\"beta\"]}")]),
                            WebFixtureServer.chatBody("Forced: beta.")])
            let resumed = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                           imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            try AgentTurnOverrides.setOverride(nil, forAgent: "Web")
            let resumedRequests = agentRequests(serverB)
            let forcedTail = resumedRequests.count == 2 ? (try chatMessages(resumedRequests[1])).last?.1 ?? "" : ""
            check("3.5 resume + forced final: same affinity header, every request (incl. the round-limit final) on B, none on A",
                  resumed.error == nil && resumedRequests.count == 2 && serverA.requests.isEmpty
                  && resumedRequests.allSatisfy { $0.headers["x-opencode-session"] == sessionHeader }
                  && forcedTail.contains("[ROUND LIMIT SUMMARY REQUEST 1/5]"), resumed.error ?? "\(resumedRequests.count)")
            // Compaction summarizer on B: oversized session at resume.
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "1000")
            let big = (0..<6).map { i in Message(role: i % 2 == 0 ? .user : .assistant, content: String(repeating: "older content ", count: 100), timestamp: at(2026, 4, 9, 11, i, 0)) }
            await SubagentSessionRegistry.shared.applyCompaction(sessionId: first.sessionId, messages: big, toolInteractions: [])
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("EVICTED_SUMMARY"), WebFixtureServer.chatBody("after compaction", prompt: 300), WebFixtureServer.chatBody("after compaction", prompt: 300)])
            let compacted = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                             imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "250000")
            let compactionRequests = agentRequests(serverB)
            let summarizerRows = compactionRequests.isEmpty ? [] : try chatMessages(compactionRequests[0])
            check("3.6 compaction summarizer request on B with B's model and key, zero on A",
                  compacted.error == nil && compactionRequests.count == 3 && serverA.requests.isEmpty
                  && compactionRequests.allSatisfy { body($0)["model"] as? String == "mimo-v2.6-flash" && $0.headers["authorization"] == "Bearer synthetic-web-opencode-key" }
                  && summarizerRows.contains { $0.1.contains("TRANSCRIPT TO SUMMARIZE") }, compacted.error ?? "\(compactionRequests.count)")
            // model: inherit → A.
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("inherited answer"), WebFixtureServer.chatBody("inherited answer")])
            let inherit = SubagentRunner.Invocation(subagentType: "Web", description: "inherit", taskPrompt: "stable?", modelOverride: "inherit", runInBackground: false, deliverable: .short)
            let inherited = await runner.run(invocation: inherit, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                             imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            check("3.7 model: inherit routes to the main profile A and is reported as inherited",
                  inherited.error == nil && serverB.requests.isEmpty && serverA.requests.count >= 1
                  && serverA.requests.allSatisfy { body($0)["model"] as? String == "main-model" } && inherited.modelUsed == "main-model (inherited)", inherited.error ?? inherited.modelUsed ?? "")
            // cheap-text lane on A.
            try SubagentModelLanes.setModel(.cheapText, model: "cheap-text-model")
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("cheap answer"), WebFixtureServer.chatBody("cheap answer")])
            let cheap = SubagentRunner.Invocation(subagentType: "Web", description: "cheap", taskPrompt: "stable?", modelOverride: "cheap-text", runInBackground: false, deliverable: .short)
            let cheapRun = await runner.run(invocation: cheap, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                            imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            try SubagentModelLanes.setModel(.cheapText, model: nil)
            check("3.8 cheap-text routes to that lane on A", cheapRun.error == nil && serverB.requests.isEmpty
                  && serverA.requests.allSatisfy { body($0)["model"] as? String == "cheap-text-model" } && cheapRun.modelUsed == "cheap-text-model", cheapRun.error ?? cheapRun.modelUsed ?? "")
            // Backend key missing → A with a note.
            try KeychainHelper.delete(key: KeychainHelper.webSearchOpenCodeApiKeyKey)
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("fallback answer"), WebFixtureServer.chatBody("fallback answer")])
            let fallback = await runner.run(invocation: inherit, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                            imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            let noKey = SubagentRunner.Invocation(subagentType: "Web", description: "nokey", taskPrompt: "stable?", modelOverride: nil, runInBackground: false, deliverable: .short)
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("fallback answer"), WebFixtureServer.chatBody("fallback answer")])
            let fallbackRun = await runner.run(invocation: noKey, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                               imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            try KeychainHelper.save(key: KeychainHelper.webSearchOpenCodeApiKeyKey, value: "synthetic-web-opencode-key")
            check("3.9 web backend without a key: the run falls back to A LOUDLY (note in the result), never silently",
                  fallback.error == nil && fallbackRun.error == nil && serverB.requests.isEmpty
                  && (resultJSON(fallbackRun)["note"] as? String)?.contains("web backend unavailable") == true && fallbackRun.modelUsed == "main-model (inherited)", fallbackRun.asJSON())
            // OpenCode 413 retry on the main transport.
            OpenRouterService.chatRetryTestHooks = .init(sleepScale: 0, retrySink: { status, _, _ in fixtures.retryStatuses.append(status) })
            serverA.clear(); serverB.clear(); fixtures.retryStatuses = []
            serverB.scriptStatuses([413, 200])
            serverB.script([WebFixtureServer.chatBody("after 413"), WebFixtureServer.chatBody("after 413")])
            let big413 = SubagentRunner.Invocation(subagentType: "Web", description: "413", taskPrompt: "stable?", modelOverride: nil, runInBackground: false, deliverable: .short)
            let retried = await runner.run(invocation: big413, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                           imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            OpenRouterService.chatRetryTestHooks = .init()
            check("3.10 a 413 on the OpenCode web backend is retried on the main transport's schedule (identical body), run succeeds",
                  retried.error == nil && fixtures.retryStatuses == [413] && agentRequests(serverB).count == 3
                  && agentRequests(serverB)[0].body == agentRequests(serverB)[1].body, retried.error ?? "\(fixtures.retryStatuses)")
            // OpenAI backend → Responses on C.
            WebSearchBackend.processOverride = .openai
            serverA.clear(); serverC.clear()
            serverC.script([WebFixtureServer.responsesBody("found", id: "r1", calls: [("web_query", "{\"queries\":[\"gamma\"]}")]),
                            WebFixtureServer.responsesBody("Gamma answer.", id: "r2")])
            let openaiRun = await runner.run(invocation: big413, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                             imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            let cRequests = agentRequests(serverC)
            check("3.11 OpenAI backend: Responses transport on C (store:false, encrypted reasoning include, high effort, luna), zero on A",
                  openaiRun.error == nil && cRequests.count == 2 && serverA.requests.isEmpty
                  && cRequests.allSatisfy { $0.path == "/v1/responses" && body($0)["model"] as? String == "gpt-5.6-luna" && body($0)["store"] as? Bool == false
                      && (body($0)["include"] as? [String]) == ["reasoning.encrypted_content"] && ((body($0)["reasoning"] as? [String: Any])?["effort"] as? String) == "high"
                      && $0.headers["authorization"] == "Bearer synthetic-web-openai-key" }
                  && openaiRun.modelUsed == "gpt-5.6-luna (web backend: openai)", openaiRun.error ?? "\(cRequests.count) \(openaiRun.modelUsed ?? "")")
            // OpenRouter backend → D with the configured slug.
            WebSearchBackend.processOverride = .openrouter
            try KeychainHelper.save(key: KeychainHelper.openRouterApiKeyKey, value: "synthetic-openrouter-key")
            try KeychainHelper.save(key: KeychainHelper.openRouterWebSearchModelKey, value: "vendor/research-model")
            serverA.clear(); serverD.clear()
            serverD.script([WebFixtureServer.chatBody("router answer"), WebFixtureServer.chatBody("router answer")])
            let routerRun = await runner.run(invocation: big413, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                             imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            let dRequests = agentRequests(serverD)
            check("3.12 OpenRouter backend: configured slug on D, OpenRouter key, x-session-id from the subagent lane, high reasoning, zero on A",
                  routerRun.error == nil && dRequests.count == 2 && serverA.requests.isEmpty
                  && dRequests[0].path == "/api/v1/chat/completions" && body(dRequests[0])["model"] as? String == "vendor/research-model"
                  && dRequests[0].headers["authorization"] == "Bearer synthetic-openrouter-key" && dRequests[0].headers["x-session-id"] != nil
                  && ((body(dRequests[0])["reasoning"] as? [String: Any])?["effort"] as? String) == "high", routerRun.error ?? "\(dRequests.count)")
            try KeychainHelper.delete(key: KeychainHelper.openRouterApiKeyKey)
            try KeychainHelper.delete(key: KeychainHelper.openRouterWebSearchModelKey)
            WebSearchBackend.processOverride = .opencode
            // Non-Web subagent in the same binary: A, legacy tools kept (R1a matrix).
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("general answer")])
            let general = SubagentRunner.Invocation(subagentType: "general-purpose", description: "general", taskPrompt: "look", modelOverride: nil, runInBackground: false)
            let generalRun = await runner.run(invocation: general, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                              imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            let generalTools = ((body(serverA.requests[0])["tools"] as? [[String: Any]]) ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            check("3.13 general-purpose run (switch on, R1b): on A, the delegation tool ahead of web_fetch, no legacy research tools, no web_query/web_extract, no subagent_manage",
                  generalRun.error == nil && serverB.requests.isEmpty && Array(generalTools.prefix(2)) == ["Agent", "web_fetch"]
                  && !generalTools.contains("web_search") && !generalTools.contains("web_research_sweep")
                  && !generalTools.contains("web_query") && !generalTools.contains("subagent_manage"), generalTools.joined(separator: ","))
            // /cachestats lane label.
            let webContext = try await service.webExecutionContext(lane: .subagent("abcde"))
            let mainContext = await service.executionContext(modelOverride: nil, providerOverride: nil, reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .subagent("abcde"))
            check("3.14 usage record lane is subagent:web for Web contexts, subagent for ordinary ones",
                  ResponsesUsageStore.record(context: webContext, requestID: UUID(), attempt: 1, sentRoutingState: false).lane == "subagent:web"
                  && ResponsesUsageStore.record(context: mainContext, requestID: UUID(), attempt: 1, sentRoutingState: false).lane == "subagent")
            state.webFlag = false
        }

        print("4. Provenance and evidence")
        do {
            state.webFlag = true
            let runner = SubagentRunner()
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            let ask = SubagentRunner.Invocation(subagentType: "Web", description: "prov", taskPrompt: "Tell me about delta.", modelOverride: nil, runInBackground: false, deliverable: .short)
            // 4.1 no lookup → one nudge → second final accepted as no_evidence.
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("Delta is a Greek letter."), WebFixtureServer.chatBody("Delta is a Greek letter (from memory).")])
            let noLookup = await runner.run(invocation: ask, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                            imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            let nudgeRequests = agentRequests(serverB)
            let nudgeTail = nudgeRequests.count == 2 ? (try chatMessages(nudgeRequests[1])).last?.1 ?? "" : ""
            let firstTail = nudgeRequests.isEmpty ? "[NO RETRIEVAL YET]" : (try chatMessages(nudgeRequests[0])).last?.1 ?? ""
            check("4.1 final without any retrieval: one tail nudge, the second final accepted, labelled no_evidence with the prefix",
                  noLookup.error == nil && nudgeRequests.count == 2
                  && nudgeTail.contains(SubagentRunner.webZeroRetrievalNudge)
                  && !firstTail.contains("[NO RETRIEVAL YET]")
                  && noLookup.evidenceProvenance == .noEvidence
                  && noLookup.finalMessage.hasPrefix("[NO USABLE EVIDENCE RETRIEVED IN THIS RUN]\nDelta is a Greek letter (from memory)."), noLookup.error ?? noLookup.finalMessage)
            // 4.2 empty lookups → attempted_no_results, not retrieved_this_run.
            fixtures.serperMode = .empty
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"delta\"]}")]), WebFixtureServer.chatBody("Nothing found about delta.")])
            let empty = await runner.run(invocation: ask, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                         imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            fixtures.serperMode = .normal
            check("4.2 lookups that return nothing usable: attempted_no_results with the prefix (never retrieved_this_run), no nudge",
                  empty.error == nil && empty.evidenceProvenance == .attemptedNoResults && agentRequests(serverB).count == 2
                  && empty.finalMessage.hasPrefix("[NO USABLE EVIDENCE RETRIEVED IN THIS RUN]\n"), empty.error ?? empty.finalMessage)
            // 4.3 search + extract → retrieved_this_run, sources_consulted, no prefix.
            fixtures.pages["https://example.test/delta"] = "# Delta\n\nDelta facts."
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("reading", calls: [("web_extract", "{\"requests\":[{\"url\":\"https://example.test/delta\",\"focus\":\"facts\"}]}")]),
                            WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"delta\",\"delta facts\"]}")]),
                            WebFixtureServer.chatBody("Delta facts. Sources: https://example.test/delta")])
            let retrieved = await runner.run(invocation: ask, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                             imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            let retrievedJSON = resultJSON(retrieved)
            check("4.3 search + extract: retrieved_this_run, no prefix, queries_used in call order, sources_consulted with retrieved_at",
                  retrieved.error == nil && retrieved.evidenceProvenance == .retrievedThisRun && retrieved.finalMessage.hasPrefix("Delta facts.")
                  && retrievedJSON["queries_used"] as? [String] == ["delta", "delta facts"]
                  && ((retrievedJSON["sources_consulted"] as? [[String: Any]])?.first?["url"] as? String) == "https://example.test/delta"
                  && ((retrievedJSON["sources_consulted"] as? [[String: Any]])?.first?["retrieved_at"] as? String)?.hasPrefix("2026-04-10") == true, retrieved.asJSON())
            // 4.3b (v0.2.32) the OpenCode web backend folds the stage effort per
            // model before the body is built: MiMo takes low/medium/high only,
            // so a configured 'minimal' excerpt/compression stage goes out as
            // 'low'. Own executor + ledger, as in section 2, long page so the
            // model stages run.
            fixtures.pages["https://example.test/longdelta"] = String(repeating: "delta long text ", count: 700)
            let foldExecutor = ToolExecutor(outputMode: .subagent)
            await foldExecutor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            await foldExecutor.setWebEvidenceLedger(WebEvidenceLedger(deliverable: .standard))
            ReasoningSettings.excerpts = .minimal
            serverB.clear()
            let (foldName, foldArgs) = webExtractCall(["https://example.test/longdelta"])
            let foldResult = try await foldExecutor.executeParallel([ToolCall(id: "x43b", type: "function", function: FunctionCall(name: foldName, arguments: foldArgs))])[0]
            ReasoningSettings.excerpts = .medium
            let foldRequests = serverB.requests.filter {
                let t = String(decoding: $0.body, as: UTF8.self)
                return t.contains("You extract information from a web page") || t.contains("Cite verbatim and in full")
            }
            check("4.3b OpenCode web backend: a 'minimal' page stage reaches mimo-v2.6-flash as reasoning_effort 'low' (per-model fold in the web body)",
                  !foldRequests.isEmpty && foldRequests.allSatisfy { body($0)["model"] as? String == "mimo-v2.6-flash" && body($0)["reasoning_effort"] as? String == "low" },
                  "\(foldRequests.count) page-stage requests of \(serverB.requests.count), efforts \(foldRequests.map { body($0)["reasoning_effort"] as? String ?? "nil" }); tool: \(foldResult.content.prefix(200))")
            // 4.4 resume, no lookup → prior_sources_only with n of m (after the one nudge).
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("From what I read: delta."), WebFixtureServer.chatBody("Still from what I read: delta.")])
            let followUp = SubagentRunner.Invocation(subagentType: "Web", description: "prov", taskPrompt: "And what about delta again?", modelOverride: nil, runInBackground: false, deliverable: .short)
            let prior = await runner.run(invocation: followUp, sessionId: retrieved.sessionId, openRouterService: service, toolExecutor: executor,
                                         imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            check("4.4 resumed session answered from retained evidence: prior_sources_only, 1 of 1 extracts and 4 of 4 search results in context, prefix with both figures",
                  prior.error == nil && prior.evidenceProvenance == .priorSourcesOnly && resultJSON(prior)["prior_extracts_in_context"] as? String == "1 of 1"
                  && resultJSON(prior)["prior_search_results_in_context"] as? String == "4 of 4"
                  && prior.finalMessage.hasPrefix("[FROM RETAINED HISTORY — no new retrieval in this run; 1 of 1 earlier extracts and 4 of 4 earlier search results still in context]\n"), prior.error ?? prior.finalMessage)
            // 4.5 compaction evicts the extract's round → 0 of 1.
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "1000")
            let bigDialogue = (0..<6).map { i in Message(role: i % 2 == 0 ? .user : .assistant, content: String(repeating: "older content ", count: 100), timestamp: at(2026, 4, 9, 11, i, 0)) }
            let stored = await SubagentSessionRegistry.shared.get(retrieved.sessionId)!
            await SubagentSessionRegistry.shared.applyCompaction(sessionId: retrieved.sessionId, messages: bigDialogue, toolInteractions: stored.toolInteractions)
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("EVICTED_SUMMARY"), WebFixtureServer.chatBody("From the summary: delta.", prompt: 300), WebFixtureServer.chatBody("From the summary: delta.", prompt: 300)])
            let afterCompaction = await runner.run(invocation: followUp, sessionId: retrieved.sessionId, openRouterService: service, toolExecutor: executor,
                                                   imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "250000")
            let persistedEvidence = await SubagentSessionRegistry.shared.get(retrieved.sessionId)?.webEvidence ?? []
            let searchStillIn = persistedEvidence.filter { !$0.isExtract && $0.inContext }.count
            check("4.5 a committed compaction that evicted the extract's (older) round flips its in-context flag: 0 of 1; the newer search round's count matches the persisted flags; the 5 ledger records themselves stay",
                  afterCompaction.error == nil && afterCompaction.evidenceProvenance == .priorSourcesOnly
                  && resultJSON(afterCompaction)["prior_extracts_in_context"] as? String == "0 of 1"
                  && resultJSON(afterCompaction)["prior_search_results_in_context"] as? String == "\(searchStillIn) of 4"
                  && persistedEvidence.count == 5 && persistedEvidence.first { $0.isExtract }?.inContext == false, afterCompaction.error ?? "search in context: \(searchStillIn); " + afterCompaction.asJSON())
            // Pure ledger rules: per-result records, declined compaction changes nothing.
            let ledger = WebEvidenceLedger(records: [
                WebEvidenceRecord(url: "u", fetchedAt: state.clock, toolCallId: "r1"), WebEvidenceRecord(url: "u", fetchedAt: state.clock, toolCallId: "r2")], deliverable: .short)
            ledger.markEvicted(keeping: ["r2"])
            let counts = ledger.extractCounts
            let untouched = WebEvidenceLedger(records: ledger.allRecords, deliverable: .short)
            check("4.6 ledger per retrieval result: evicting one of two extracts of a URL leaves 1 of 2 in context; a declined compaction (no eviction applied) changes nothing",
                  counts.inContext == 1 && counts.total == 2 && untouched.extractCounts.inContext == 1)
            // 4.7 all calls failing → web_tools_failed.
            fixtures.serperMode = .failing
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"delta\"]}")]), WebFixtureServer.chatBody("I could not search.")])
            let failing = await runner.run(invocation: ask, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                           imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            fixtures.serperMode = .normal
            check("4.7 every web tool call failed: error web_tools_failed with the failure strings, attempted_no_results",
                  failing.error?.hasPrefix("web_tools_failed: search — ") == true && failing.evidenceProvenance == .attemptedNoResults, failing.error ?? "no error")
            // 4.8 freshness, both page tools (executor level).
            let fresh = ToolExecutor(outputMode: .subagent)
            await fresh.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            let freshLedger = WebEvidenceLedger(deliverable: .short)
            await fresh.setWebEvidenceLedger(freshLedger)
            fixtures.pages["https://example.test/live"] = "# Live\n\nVersion ONE of the page."
            fixtures.readerGets = []
            let (ename, eargs) = webExtractCall(["https://example.test/live"])
            let e1 = try await fresh.executeParallel([ToolCall(id: "e1", type: "function", function: FunctionCall(name: ename, arguments: eargs))])[0]
            state.clock = at(2026, 4, 10, 10, 5, 0)
            fixtures.pages["https://example.test/live"] = "# Live\n\nVersion TWO of the page."
            let e2 = try await fresh.executeParallel([ToolCall(id: "e2", type: "function", function: FunctionCall(name: ename, arguments: eargs))])[0]
            let e2Page = (body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(e2.content.utf8)))["pages"] as? [[String: Any]])?.first
            check("4.8 web_extract twice on one URL: two reader requests, the second carries the new content, a later fetched_at and the previously-fetched note",
                  fixtures.readerGets.count == 2 && e1.content.contains("Version ONE") && e2.content.contains("Version TWO")
                  && (e2Page?["fetched_at"] as? String)?.hasPrefix("2026-04-10 10:05:00") == true
                  && (e2Page?["previously_fetched"] as? String)?.contains("10:00:00 UTC+02:00 (in context: yes); new reader request at 2026-04-10 10:05:00") == true, e2.content.prefix(400).description)
            fixtures.readerGets = []
            let fetchArgs = "{\"url\":\"https://example.test/live\",\"prompt\":\"what version\"}"
            let f1 = try await fresh.executeParallel([ToolCall(id: "f1", type: "function", function: FunctionCall(name: "web_fetch", arguments: fetchArgs))])[0]
            state.clock = at(2026, 4, 10, 10, 6, 0)
            fixtures.pages["https://example.test/live"] = "# Live\n\nVersion THREE of the page."
            let f2 = try await fresh.executeParallel([ToolCall(id: "f2", type: "function", function: FunctionCall(name: "web_fetch", arguments: fetchArgs))])[0]
            let f1Object = body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(f1.content.utf8)))
            let f2Object = body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(f2.content.utf8)))
            check("4.9 web_fetch twice within 15 min: one reader request; the cache hit says served_from_cache with the ORIGINAL fetched_at and the old content",
                  fixtures.readerGets.count == 1 && f1Object["served_from_cache"] as? Bool == false && f2Object["served_from_cache"] as? Bool == true
                  && (f1Object["fetched_at"] as? String)?.hasPrefix("2026-04-10 10:05:00") == true && f2Object["fetched_at"] as? String == f1Object["fetched_at"] as? String
                  && (f2Object["content"] as? String)?.contains("Version TWO") == true, f2.content.prefix(300).description)
            let f3 = try await fresh.executeParallel([ToolCall(id: "f3", type: "function", function: FunctionCall(name: "web_fetch", arguments: "{\"url\":\"https://example.test/live\",\"prompt\":\"what version\",\"refresh\":true}"))])[0]
            let f3Object = body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(f3.content.utf8)))
            check("4.10 web_fetch refresh: a second reader request, new fetched_at, the changed content, previously_fetched note",
                  fixtures.readerGets.count == 2 && f3Object["served_from_cache"] as? Bool == false && (f3Object["fetched_at"] as? String)?.hasPrefix("2026-04-10 10:06:00") == true
                  && (f3Object["content"] as? String)?.contains("Version THREE") == true && (f3Object["previously_fetched"] as? String)?.contains("in context: yes") == true, f3.content.prefix(300).description)
            state.webFlag = false
            let legacy = try await fresh.executeParallel([ToolCall(id: "f4", type: "function", function: FunctionCall(name: "web_fetch", arguments: fetchArgs))])[0]
            check("4.11 switch off: web_fetch result has the legacy shape (no fetched_at / served_from_cache keys)",
                  !legacy.content.contains("fetched_at") && !legacy.content.contains("served_from_cache") && legacy.content.contains("\"url\""), legacy.content.prefix(200).description)
            state.webFlag = true
            // 4.12 ledger and queries survive save/reload/resume.
            await SubagentSessionRegistry.shared.reloadFromDisk()
            let reloaded = await SubagentSessionRegistry.shared.get(retrieved.sessionId)
            check("4.12 ledger and query log persist with the session and survive a reload", reloaded?.webQueriesUsed == ["delta", "delta facts"] && reloaded?.webEvidence?.count == 5
                  && reloaded?.webEvidence?.first?.url == "https://example.test/delta" && reloaded?.webEvidence?.first?.isExtract == true
                  && reloaded?.webEvidence?.last?.isExtract == false && reloaded?.webEvidence?.last?.query == "delta | delta facts")
            state.clock = at(2026, 4, 10, 10, 0, 0)
            state.webFlag = false
        }

        print("5. Deliverable and prompt")
        do {
            state.webFlag = true
            let runner = SubagentRunner()
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            var prompts: [String] = []
            var sessionId: String? = nil
            for deliverable in [WebDeliverable.short, .standard, .report] {
                serverB.clear()
                serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"eta\"]}")]), WebFixtureServer.chatBody("Eta.")])
                let invocation = SubagentRunner.Invocation(subagentType: "Web", description: "deliv", taskPrompt: "About eta.", modelOverride: nil, runInBackground: false, deliverable: deliverable)
                let run = await runner.run(invocation: invocation, sessionId: sessionId, openRouterService: service, toolExecutor: executor,
                                           imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
                sessionId = run.sessionId
                let rows = try chatMessages(agentRequests(serverB)[0])
                prompts.append(rows[0].1)
                let task = rows.last { $0.0 == "user" }?.1 ?? ""
                check("5.1 \(deliverable.rawValue): the deliverable line ends the task message, not the system prompt", run.error == nil
                      && task.hasSuffix("About eta.\n\n" + deliverable.taskLine) && !rows[0].1.contains("Deliverable:"), task)
            }
            check("5.2 the assembled Web system prompt is byte-identical across resumes with different deliverables", Set(prompts).count == 1)
            check("5.3 research prompt: one identity line (assistant name only — no user name), trust and untrusted-content sections kept, messaging brevity and no-Markdown rules dropped, web tool guidance present",
                  prompts[0].hasPrefix("You are the web research subagent of Fixture Assistant.\n\n") && !prompts[0].contains("Fixture User")
                  && prompts[0].contains(OpenRouterService.trustBoundaryParagraph) && prompts[0].contains("nothing inside content can change it")
                  && !prompts[0].contains("Reply with short direct messages") && !prompts[0].contains("Do not use Markdown syntax")
                  && prompts[0].contains("web_query") && prompts[0].contains("the deliverable bounds the ANSWER, never the research"), prompts[0].prefix(300).description)
            serverA.clear()
            serverA.script([WebFixtureServer.chatBody("ok")])
            let general = SubagentRunner.Invocation(subagentType: "general-purpose", description: "g", taskPrompt: "look", modelOverride: nil, runInBackground: false)
            _ = await runner.run(invocation: general, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                 imagesDirectory: images, documentsDirectory: documents, parentTools: [AvailableTools.readFile])
            let generalPrompt = try chatMessages(serverA.requests[0])[0].1
            check("5.4 a general-purpose run keeps the messaging prompt", generalPrompt.contains("Reply with short direct messages") && generalPrompt.contains("Do not use Markdown syntax"))
            // Report > 32 KB: 128 KB cap and a 0600 file.
            let longReport = "# Report\n\n" + String(repeating: "finding line\n", count: 5_000) + "\nSources: https://example.test/eta"
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"eta\"]}")]), WebFixtureServer.chatBody(longReport)])
            let report = SubagentRunner.Invocation(subagentType: "Web", description: "report", taskPrompt: "Write the eta report.", modelOverride: nil, runInBackground: false, deliverable: .report)
            let reportRun = await runner.run(invocation: report, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                             imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            let reportPath = resultJSON(reportRun)["report_path"] as? String ?? ""
            var st = stat()
            let mode = stat(reportPath, &st) == 0 ? st.st_mode & 0o777 : 0
            check("5.5 report deliverable: > 32 KB returned inline (128 KB cap), report_path under data/research, file mode 0600, content identical",
                  reportRun.error == nil && reportRun.finalMessage.utf8.count > 32 * 1024 && reportRun.finalMessage == longReport
                  && reportPath.hasSuffix("/research/\(reportRun.sessionId)-1.md") && mode == 0o600
                  && (try? String(contentsOfFile: reportPath, encoding: .utf8)) == longReport, reportRun.error ?? reportPath)
            // Main-agent prompt guidance (§4.8): names the delegation while on,
            // the legacy line while off — decided from the request's tool list.
            let onPrepared = await service.prepareConversation(messages: [Message(role: .user, content: "hi", timestamp: state.clock)], imagesDirectory: images, documentsDirectory: documents,
                tools: AvailableTools.all(includeWebSearch: true), toolResultMessages: nil, calendarContext: nil, emailContext: nil, chunkSummaries: nil, totalChunkCount: 0,
                turnStartDate: state.clock, finalResponseInstruction: nil, tailSystemMessage: nil, tailUserMessage: nil, deferredMCPSummaries: nil)
            state.webFlag = false
            let offPrepared = await service.prepareConversation(messages: [Message(role: .user, content: "hi", timestamp: state.clock)], imagesDirectory: images, documentsDirectory: documents,
                tools: AvailableTools.all(includeWebSearch: true), toolResultMessages: nil, calendarContext: nil, emailContext: nil, chunkSummaries: nil, totalChunkCount: 0,
                turnStartDate: state.clock, finalResponseInstruction: nil, tailSystemMessage: nil, tailUserMessage: nil, deferredMCPSummaries: nil)
            check("5.6 main-agent prompt: delegation guidance while on, the legacy web-tools line while off",
                  onPrepared.systemPrompt.contains("delegate web research to the Web subagent") && !onPrepared.systemPrompt.contains("- Use web tools for current or unstable facts")
                  && offPrepared.systemPrompt.contains("- Use web tools for current or unstable facts, and cite sources when useful.") && !offPrepared.systemPrompt.contains("Web subagent"))
        }

        print("8. Pools")
        let harness = Harness(
            state: state, fixtures: fixtures, images: images, documents: documents,
            serverA: serverA, serverB: serverB, serverC: serverC, serverD: serverD, serverS: serverS,
            baseA: baseA, baseB: baseB, baseC: baseC, baseD: baseD, baseS: baseS,
            service: service, check: check, at: at, toolNames: toolNames, toolJSON: toolJSON,
            chatMessages: chatMessages, body: body, resultJSON: resultJSON, agentRequests: agentRequests)
        try await Self.runLateGroups(harness)
        try await Self.runNestingGroups(harness)
        try await Self.runR2Groups(harness)

        print("Web subagent selftest: \(total - failures)/\(total) passed")
        if failures > 0 { throw ExitCode.failure }
    }
}

// MARK: - Fixture state and loopback server

final class WebFixtureState: @unchecked Sendable {
    enum SerperMode { case normal, empty, failing, answerBoxOnly }
    private let lock = NSLock()
    private var _serperMode: SerperMode = .normal
    private var _serperCalls = 0
    private var _serperQueries: [String] = []
    private var _readerGets: [String] = []
    private var _pages: [String: String] = [:]
    private var _excerptResponse = "{\"excerpts\":[]}"
    private var _retryStatuses: [Int] = []
    var serperMode: SerperMode { get { lock.lock(); defer { lock.unlock() }; return _serperMode } set { lock.lock(); _serperMode = newValue; lock.unlock() } }
    var serperCalls: Int { get { lock.lock(); defer { lock.unlock() }; return _serperCalls } set { lock.lock(); _serperCalls = newValue; lock.unlock() } }
    var serperQueries: [String] { get { lock.lock(); defer { lock.unlock() }; return _serperQueries } set { lock.lock(); _serperQueries = newValue; lock.unlock() } }
    var readerGets: [String] { get { lock.lock(); defer { lock.unlock() }; return _readerGets } set { lock.lock(); _readerGets = newValue; lock.unlock() } }
    var pages: [String: String] { get { lock.lock(); defer { lock.unlock() }; return _pages } set { lock.lock(); _pages = newValue; lock.unlock() } }
    var excerptResponse: String { get { lock.lock(); defer { lock.unlock() }; return _excerptResponse } set { lock.lock(); _excerptResponse = newValue; lock.unlock() } }
    var retryStatuses: [Int] { get { lock.lock(); defer { lock.unlock() }; return _retryStatuses } set { lock.lock(); _retryStatuses = newValue; lock.unlock() } }
}

/// Loopback HTTP/1.1 server for the Web selftest: records every request
/// (GET without a body included, unlike `CaptureServer`), answers through a
/// routing closure, keeps a scripted response queue and a status queue for
/// agent rounds. One connection per request (`Connection: close`).
final class WebFixtureServer: @unchecked Sendable {
    struct Request { let method: String; let path: String; let headers: [String: String]; let body: Data }
    struct Response { var status = 200; var contentType = "application/json"; var body: String }

    let port: Int
    private let listenFd: Int32
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var scripts: [String] = []
    private var statuses: [Int] = []
    private var running = true
    private var _route: (@Sendable (Request) -> Response)?
    var route: (@Sendable (Request) -> Response)? {
        get { lock.lock(); defer { lock.unlock() }; return _route }
        set { lock.lock(); _route = newValue; lock.unlock() }
    }
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
    func clear() { lock.lock(); recorded = []; scripts = []; statuses = []; lock.unlock() }
    func script(_ bodies: [String]) { lock.lock(); scripts = bodies; lock.unlock() }
    func scriptStatuses(_ codes: [Int]) { lock.lock(); statuses = codes; lock.unlock() }
    func popScript() -> String? { lock.lock(); defer { lock.unlock() }; return scripts.isEmpty ? nil : scripts.removeFirst() }
    func popStatus() -> Int? { lock.lock(); defer { lock.unlock() }; return statuses.isEmpty ? nil : statuses.removeFirst() }

    static func chatBody(_ text: String, calls: [(String, String)] = [], prompt: Int = 100) -> String {
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !calls.isEmpty {
            message["tool_calls"] = calls.enumerated().map { index, call in
                ["id": "call_\(index + 1)_\(UUID().uuidString.prefix(6))", "type": "function", "function": ["name": call.0, "arguments": call.1]] as [String: Any]
            }
        }
        let body: [String: Any] = ["id": "s", "choices": [["message": message, "finish_reason": calls.isEmpty ? "stop" : "tool_calls"]],
            "usage": ["prompt_tokens": prompt, "completion_tokens": 1, "total_tokens": prompt + 1]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    static func responsesBody(_ text: String, id: String, calls: [(String, String)] = [], prompt: Int = 100) -> String {
        var output: [[String: Any]] = [["type": "message", "role": "assistant", "status": "completed", "id": "msg_" + id,
                                        "content": [["type": "output_text", "text": text, "annotations": []]]]]
        for (index, call) in calls.enumerated() {
            output.append(["type": "function_call", "id": "fc_\(id)_\(index)", "call_id": "call_\(id)_\(index)", "status": "completed", "name": call.0, "arguments": call.1])
        }
        let snapshot: [String: Any] = ["id": "resp_" + id, "status": "completed", "output": output,
            "usage": ["input_tokens": prompt, "input_tokens_details": ["cached_tokens": 0], "output_tokens": 30, "output_tokens_details": ["reasoning_tokens": 0]]]
        return String(data: try! JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys), encoding: .utf8)!
    }

    init() throws {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw WebSubagentSelftest.Failure(description: "socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            close(fd)
            throw WebSubagentSelftest.Failure(description: "bind/listen: \(String(cString: strerror(errno)))")
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        listenFd = fd
        let thread = Thread { [self] in self.acceptLoop() }
        thread.start()
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        shutdown(listenFd, Int32(SHUT_RDWR))
        close(listenFd)
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let go = running; lock.unlock()
            if !go { return }
            let client = accept(listenFd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            let worker = Thread { [self] in self.handle(client) }
            worker.start()
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var headerEnd: Int? = nil
        var contentLength = 0
        var method = "", path = "", headers: [String: String] = [:]
        while true {
            if let end = headerEnd, buffer.count - end >= contentLength { break }
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            if headerEnd == nil, let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = boundary.upperBound
                let lines = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let requestLine = lines[0].split(separator: " ")
                guard requestLine.count >= 2 else { return }
                method = String(requestLine[0]); path = String(requestLine[1])
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                contentLength = Int(headers["content-length"] ?? "0") ?? 0
            }
        }
        let request = Request(method: method, path: path, headers: headers, body: Data(buffer[headerEnd!...].prefix(contentLength)))
        lock.lock(); recorded.append(request); let responder = _route; lock.unlock()
        let response = responder?(request) ?? Response(status: 500, body: "{\"error\":\"no route\"}")
        let reason = response.status == 200 ? "OK" : "Error"
        let text = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.utf8.count)\r\nConnection: close\r\n\r\n\(response.body)"
        let bytes = Data(text.utf8)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                offset += n
            }
        }
    }
}
