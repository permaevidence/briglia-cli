import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Second half of the Web researcher battery (groups 8–14: pools, background
// resume, commands, matrix, chronology, Codex rounds 1–2). Split out of
// `WebSubagentSelftest.run()` because one function of the original size no
// longer compiled inside the 8 GB Linux CI container (the same reason the
// Playwright selftest was split, f970441); nothing checked changed.
extension WebSubagentSelftest {
    /// The pinned clock and the flag seams, shared by both halves so either
    /// can move the clock or flip a switch and the other sees it.
    final class MutableState {
        var clock: Date
        var subagentsFlag: Bool?
        var webFlag: Bool?
        /// The Web session group 3 creates; groups 8–14 reuse and reseed it.
        var webSessionId = ""
        init(clock: Date, subagentsFlag: Bool?, webFlag: Bool?) {
            self.clock = clock; self.subagentsFlag = subagentsFlag; self.webFlag = webFlag
        }
    }

    /// The harness locals of `run()` that groups 8–14 use.
    struct Harness {
        let state: MutableState
        let fixtures: WebFixtureState
        let images: URL, documents: URL
        let serverA: WebFixtureServer, serverB: WebFixtureServer, serverC: WebFixtureServer, serverD: WebFixtureServer, serverS: WebFixtureServer
        let baseA: String, baseB: String, baseC: String, baseD: String, baseS: String
        let service: OpenRouterService
        let check: (String, Bool, String) -> Void
        let at: (Int, Int, Int, Int, Int, Int) -> Date
        let toolNames: ([ToolDefinition]) -> [String]
        let toolJSON: ([ToolDefinition]) throws -> Data
        let chatMessages: (WebFixtureServer.Request) throws -> [(String, String)]
        let body: (WebFixtureServer.Request) -> [String: Any]
        let resultJSON: (SubagentRunner.RunResult) -> [String: Any]
        let agentRequests: (WebFixtureServer) -> [WebFixtureServer.Request]
    }

    static func runLateGroups(_ h: Harness) async throws {
        let state = h.state, fixtures = h.fixtures, images = h.images, documents = h.documents, service = h.service
        let serverA = h.serverA, serverB = h.serverB, serverC = h.serverC, serverD = h.serverD, serverS = h.serverS
        let baseA = h.baseA, baseB = h.baseB, baseC = h.baseC, baseD = h.baseD, baseS = h.baseS
        _ = (fixtures, images, documents, service, serverA, serverB, serverC, serverD, serverS, baseA, baseB, baseC, baseD, baseS)
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
            h.at(year, month, day, hour, minute, second)
        }
        func toolNames(_ tools: [ToolDefinition]) -> [String] { h.toolNames(tools) }
        func toolJSON(_ tools: [ToolDefinition]) throws -> Data { try h.toolJSON(tools) }
        func chatMessages(_ request: WebFixtureServer.Request) throws -> [(String, String)] { try h.chatMessages(request) }
        func body(_ request: WebFixtureServer.Request) -> [String: Any] { h.body(request) }
        func resultJSON(_ result: SubagentRunner.RunResult) -> [String: Any] { h.resultJSON(result) }
        func agentRequests(_ server: WebFixtureServer) -> [WebFixtureServer.Request] { h.agentRequests(server) }

        do {
            let registry = SubagentSessionRegistry.shared
            let generalBefore = await registry.list(limit: 1000, kind: .general).total
            var webIds: [String] = []
            for index in 0..<41 {
                state.clock = at(2026, 4, 10, 11, 0, index)
                webIds.append(await registry.create(subagentType: "Web", description: "w\(index)", initialPrompt: "topic \(index)  with   spaces", webPool: true).id)
            }
            let webAfter = await registry.list(limit: 1000, kind: .web)
            let oldestGone = await registry.get(webIds[0]) == nil
            let newest = await registry.get(webIds[40])
            let generalAfter = await registry.list(limit: 1000, kind: .general).total
            check("8.1 41st Web session evicts the oldest unpinned Web session; general pool untouched",
                  webAfter.total == SubagentSessionRegistry.maxWebSessions && oldestGone && newest != nil
                  && generalAfter == generalBefore, "\(webAfter.total)")
            check("8.2 topic: first 80 chars, whitespace collapsed", newest?.topic == "topic 40 with spaces")
            let webCountBefore = await registry.list(limit: 1000, kind: .web).total
            for index in 0..<(SubagentSessionRegistry.maxSessions + 5 - generalBefore) {
                state.clock = at(2026, 4, 10, 12, 0, 0).addingTimeInterval(Double(index))
                _ = await registry.create(subagentType: "general-purpose", description: "g\(index)", initialPrompt: "g")
            }
            let generalCapped = await registry.list(limit: 1000, kind: .general).total
            let webUnchanged = await registry.list(limit: 1000, kind: .web).total
            check("8.3 the general pool at its cap evicts general sessions only, never Web ones",
                  generalCapped == SubagentSessionRegistry.maxSessions && webUnchanged == webCountBefore)
            // TTL: 15 days old deleted on reload, 13 days kept.
            let iso = ISO8601DateFormatter()
            let dir = StoragePaths.dataRoot.appendingPathComponent("subagent_sessions")
            func age(_ id: String, days: Double) throws {
                let url = dir.appendingPathComponent("\(id).json")
                var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                raw["lastUsed"] = iso.string(from: Date().addingTimeInterval(-days * 86_400))
                try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]).write(to: url)
            }
            try age(webIds[40], days: 15)
            try age(webIds[39], days: 13)
            await registry.reloadFromDisk()
            let expiredGone = await registry.get(webIds[40]) == nil
            let youngKept = await registry.get(webIds[39]) != nil
            check("8.4 Web session older than 14 days is deleted on reload; a 13-day one is kept", expiredGone && youngKept)
            // list_sessions through the tool: two sections while on, legacy while off.
            state.webFlag = true
            let executor = ToolExecutor(outputMode: .mainAgent)
            let listing = await executor.executeSubagentManage(ToolCall(id: "l1", type: "function", function: FunctionCall(name: "subagent_manage", arguments: "{\"mode\":\"list_sessions\",\"limit\":3}")))
            let listObject = body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(listing.utf8)))
            let webRows = listObject["web_sessions"] as? [[String: Any]] ?? []
            check("8.5 list_sessions (switch on): general page plus newest 5 web rows with topic; web_total; kind=web pages the pool",
                  (listObject["sessions"] as? [[String: Any]])?.count == 3 && webRows.count == 5 && webRows.allSatisfy { $0["topic"] != nil }
                  && (listObject["web_total"] as? Int) == 39 && listObject["web_has_more"] as? Bool == true, listing.prefix(300).description)
            let webPage = await executor.executeSubagentManage(ToolCall(id: "l2", type: "function", function: FunctionCall(name: "subagent_manage", arguments: "{\"mode\":\"list_sessions\",\"kind\":\"web\",\"limit\":10,\"offset\":30}")))
            let webPageObject = body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(webPage.utf8)))
            check("8.6 kind=web: paged web pool only", (webPageObject["web_sessions"] as? [[String: Any]])?.count == 9 && webPageObject["sessions"] == nil && webPageObject["web_has_more"] as? Bool == false)
            state.webFlag = false
            let legacyListing = await executor.executeSubagentManage(ToolCall(id: "l3", type: "function", function: FunctionCall(name: "subagent_manage", arguments: "{\"mode\":\"list_sessions\",\"limit\":3}")))
            let legacyObject = body(WebFixtureServer.Request(method: "", path: "", headers: [:], body: Data(legacyListing.utf8)))
            check("8.7 list_sessions (switch off): the legacy single-pool shape, no topic, no web section",
                  legacyObject["web_sessions"] == nil && (legacyObject["sessions"] as? [[String: Any]])?.count == 3 && !legacyListing.contains("\"topic\"")
                  && (legacyObject["total"] as? Int) == SubagentSessionRegistry.maxSessions + 39)
            state.clock = at(2026, 4, 10, 10, 0, 0)
        }

        print("9. Background resume")
        do {
            state.webFlag = true
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            // A fresh Web session (the group-3 one was LRU-evicted by group 8's 41 sessions).
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"iota\"]}")]), WebFixtureServer.chatBody("Iota.")])
            let seed = await SubagentRunner().run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "seed", taskPrompt: "About iota.", modelOverride: nil, runInBackground: false, deliverable: .short),
                                                  sessionId: nil, openRouterService: service, toolExecutor: executor,
                                                  imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            state.webSessionId = seed.sessionId
            let invocation = SubagentRunner.Invocation(subagentType: "Web", description: "bg", taskPrompt: "continue", modelOverride: "inherit", runInBackground: true, deliverable: .short)
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("bg resumed answer"), WebFixtureServer.chatBody("bg resumed answer 2"), WebFixtureServer.chatBody("fg answer"), WebFixtureServer.chatBody("fg answer 2")])
            let handle = await SubagentBackgroundRegistry.shared.spawn(invocation: invocation, sessionId: state.webSessionId, parentTools: AvailableTools.all(includeWebSearch: true),
                                                                         openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents)
            let foreground = await SubagentRunner().run(invocation: invocation, sessionId: state.webSessionId, openRouterService: service, toolExecutor: await executor.makeChildExecutor(),
                                                        imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            var completions: [SubagentBackgroundRegistry.Completion] = []
            for _ in 0..<100 where completions.isEmpty {
                completions = await SubagentBackgroundRegistry.shared.drainCompletions()
                if completions.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            check("9.1 Agent(session_id, run_in_background) resumes the session (handle carries it); a concurrent foreground resume serializes on the FIFO lock; both commit",
                  handle.sessionId == state.webSessionId && completions.count == 1 && completions[0].handle.sessionId == state.webSessionId
                  && completions[0].result.sessionId == state.webSessionId && completions[0].result.isNewSession == false && completions[0].result.error == nil
                  && foreground.error == nil && foreground.isNewSession == false, "\(completions.first?.result.error ?? "") / \(foreground.error ?? "")")
            state.webFlag = false
        }

        print("10. Commands and switches")
        do {
            let command = ChatCommandRegistry.commands.first { $0.name == "websubagent" }
            check("10.1 /websubagent registered, hidden from the Telegram menu, Models category; menu unchanged",
                  command?.inMenu == false && command?.category == "Models" && command?.usage == "[on|off]"
                  && ChatCommandRegistry.menuCommands.map(\.command) == ChatCommandRegistry.menuOrder)
            state.webFlag = true; state.subagentsFlag = true
            check("10.2 flag seams: active only with both switches on", AvailableTools.webSubagentActive)
            state.subagentsFlag = false
            check("10.3 subagents off → web subagent inactive (O5)", !AvailableTools.webSubagentActive && AvailableTools.webSubagentEnabled)
            state.subagentsFlag = true; state.webFlag = false
        }

        print("11. Tool-access matrix (R1a rows)")
        do {
            let parent = AvailableTools.all(includeWebSearch: true)
            let custom = SubagentType(name: "analyst", description: "custom", systemPromptSuffix: "", allowedToolNames: ["read_file", "web_search", "web_fetch"], defaultMaxTurns: 10, preferredModel: .inherit)
            func names(_ type: SubagentType, _ tools: [ToolDefinition]) -> [String] { toolNames(SubagentRunner.nativeToolInventory(parentTools: tools, type: type)) }
            state.webFlag = false
            let offMain = toolNames(parent)
            let offGeneral = names(SubagentTypes.generalPurpose, parent), offCustom = names(custom, parent), offTriage = names(SubagentTypes.watcherTriage, parent)
            check("11.1 switch off: main list legacy; general-purpose = main minus Agent/mid_turn; custom names its legacy tool; triage read-only",
                  offMain.prefix(3) == ["web_search", "web_research_sweep", "web_fetch"] && offGeneral == offMain.filter { $0 != "Agent" && $0 != "mid_turn_message_user" }
                  && offCustom == ["web_search", "web_fetch", "read_file"] && offTriage == ["read_file", "grep", "list_dir", "list_recent_files"], offCustom.joined(separator: ","))
            state.webFlag = true
            let onParent = AvailableTools.all(includeWebSearch: true)
            let onMain = toolNames(onParent)
            let onGeneral = names(SubagentTypes.generalPurpose, onParent), onCustom = names(custom, onParent), onTriage = names(SubagentTypes.watcherTriage, onParent)
            let onWeb = names(SubagentTypes.webResearcher, onParent)
            check("11.2 switch on (R1a): main = web_fetch + Agent(Web), no legacy; general-purpose keeps the legacy tools + web_fetch, no Agent; custom unchanged; Web = its three; triage unchanged",
                  onMain.first == "web_fetch" && onMain.contains("Agent") && !onMain.contains("web_search")
                  && onGeneral.prefix(3) == ["web_search", "web_research_sweep", "web_fetch"] && !onGeneral.contains("Agent") && !onGeneral.contains("web_query")
                  && onCustom == ["web_search", "web_fetch", "read_file"] && onWeb == ["web_query", "web_extract", "web_fetch"] && onTriage == offTriage,
                  onGeneral.prefix(4).joined(separator: ",") + " | " + onCustom.joined(separator: ","))
            check("11.3 switch off restores every inventory to its baseline bytes",
                  { state.webFlag = false; defer { state.webFlag = true }
                    return (try? toolJSON(SubagentRunner.nativeToolInventory(parentTools: AvailableTools.all(includeWebSearch: true), type: SubagentTypes.generalPurpose)))
                        == (try? toolJSON(SubagentRunner.nativeToolInventory(parentTools: parent, type: SubagentTypes.generalPurpose))) }())
            state.webFlag = false
        }

        print("12. Chronology through the shared formatter")
        do {
            state.webFlag = true
            let runner = SubagentRunner()
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            state.clock = at(2026, 4, 11, 9, 30, 0)
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"theta\"]}")]), WebFixtureServer.chatBody("Theta.")])
            let invocation = SubagentRunner.Invocation(subagentType: "Web", description: "chrono", taskPrompt: "About theta.", modelOverride: nil, runInBackground: false, deliverable: .short)
            let run = await runner.run(invocation: invocation, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                       imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            let rows = try chatMessages(agentRequests(serverB)[1])
            check("12.1 Web run (chat): day header + [HH:mm] on the task, issued note, dated tool result, run clock tail",
                  run.error == nil && rows.contains { $0.0 == "user" && $0.1.hasPrefix("--- Saturday, 11 April 2026 ---\n[09:30] About theta.") }
                  && rows.contains { $0 == ("system", "[System Note: The following tool calls were issued at 09:30:00]") }
                  && rows.contains { $0.0 == "tool" && $0.1.hasSuffix("\n\n[System Note: Current time is now 09:30:00]") }
                  && rows.last?.1 == Chronology.runClockNote(startedAt: at(2026, 4, 11, 9, 30, 0)), rows.map { "\($0.0): \($0.1.prefix(60))" }.joined(separator: " || "))
            WebSearchBackend.processOverride = .openai
            serverC.clear()
            serverC.script([WebFixtureServer.responsesBody("searching", id: "c1", calls: [("web_query", "{\"queries\":[\"theta\"]}")]), WebFixtureServer.responsesBody("Theta.", id: "c2")])
            let native = await runner.run(invocation: invocation, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                          imagesDirectory: images, documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            let items = (body(agentRequests(serverC)[1])["input"] as? [[String: Any]]) ?? []
            func text(_ item: [String: Any]) -> String {
                if let parts = item["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
                if let parts = item["output"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
                return (item["output"] as? String) ?? (item["content"] as? String) ?? ""
            }
            check("12.2 Web run (Responses): the same chronology on the native transport",
                  native.error == nil && items.contains { text($0).hasPrefix("--- Saturday, 11 April 2026 ---\n[09:30] About theta.") }
                  && items.contains { text($0).hasSuffix("[System Note: Current time is now 09:30:00]") }
                  && items.contains { text($0) == "[System Note: The following tool calls were issued at 09:30:00]" }, native.error ?? items.map(text).joined(separator: " || ").prefix(600).description)
            WebSearchBackend.processOverride = .opencode
            state.webFlag = false
        }


        print("13. Codex R1a review corrections (R1–R4, N1, N2)")
        do {
            state.webFlag = true
            let runner = SubagentRunner()
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            let all = AvailableTools.all(includeWebSearch: true)
            state.clock = at(2026, 4, 10, 10, 0, 0)
            // ---- R1: one backend/model resolver; the OpenAI backend never receives a foreign slug.
            WebSearchBackend.processOverride = .openai
            try KeychainHelper.save(key: KeychainHelper.openRouterWebSearchModelKey, value: "google/gemini-test")
            let profileBefore = KeychainHelper.loadSnapshot()
            let foreign = try await service.webExecutionContextWithNote(lane: .subagent("foreign"))
            serverA.clear(); serverC.clear()
            serverC.script([WebFixtureServer.responsesBody("Foreign answer.", id: "f1"), WebFixtureServer.responsesBody("Foreign answer.", id: "f2")])
            let foreignRun = await runner.run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "foreign", taskPrompt: "stable?", modelOverride: nil, runInBackground: false, deliverable: .short),
                                              sessionId: nil, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let foreignRequests = agentRequests(serverC)
            check("13.1 R1: a foreign OpenRouter slug configured for the OpenAI backend → the default native model in the context AND on the wire, a note in the result, main profile untouched",
                  foreign.context.model == "gpt-5.6-luna" && foreign.note?.contains("google/gemini-test") == true
                  && foreignRun.error == nil && !foreignRequests.isEmpty && foreignRequests.allSatisfy { body($0)["model"] as? String == "gpt-5.6-luna" } && serverA.requests.isEmpty
                  && (resultJSON(foreignRun)["note"] as? String)?.contains("not usable on the openai web backend") == true
                  && foreignRun.modelUsed == "gpt-5.6-luna (web backend: openai)" && KeychainHelper.loadSnapshot() == profileBefore, foreignRun.asJSON())
            try KeychainHelper.save(key: KeychainHelper.openRouterWebSearchModelKey, value: "openai/gpt-5.6-terra")
            let terra = try await service.webExecutionContextWithNote(lane: .subagent("terra"))
            try KeychainHelper.save(key: KeychainHelper.openRouterWebSearchModelKey, value: "gpt-5.6-terra")
            let bare = try await service.webExecutionContextWithNote(lane: .subagent("bare"))
            check("13.2 R1: an openai/ slug is honoured without a note; a bare id (no vendor prefix) is not honoured — default plus a note, exactly the pipeline's rule",
                  terra.context.model == "gpt-5.6-terra" && terra.note == nil && bare.context.model == "gpt-5.6-luna" && bare.note != nil, "\(terra.context.model) \(bare.context.model)")
            let shared = [WebSearchBackend.researchModel(for: .openrouter, requested: "google/gemini-test"),
                          WebSearchBackend.researchModel(for: .openai, requested: "google/gemini-test"),
                          WebSearchBackend.researchModel(for: .openai, requested: "openai/gpt-5.6-luna"),
                          WebSearchBackend.researchModel(for: .opencode, requested: "google/gemini-test")]
            check("13.3 R1: the shared resolver — OpenRouter honours any slug, OpenAI only openai/…, OpenCode pins by design (honoured, no note)",
                  shared[0] == ("google/gemini-test", true) && shared[1] == ("gpt-5.6-luna", false) && shared[2] == ("gpt-5.6-luna", true) && shared[3] == ("mimo-v2.5", true))
            try KeychainHelper.delete(key: KeychainHelper.openRouterWebSearchModelKey)
            WebSearchBackend.processOverride = .opencode

            // ---- R3: search-only evidence is durable, distinct from page reads, classified on resume.
            serverB.clear(); fixtures.serperMode = .normal
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"alpha\"]}")]), WebFixtureServer.chatBody("Alpha, from the snippets.")])
            let ask = SubagentRunner.Invocation(subagentType: "web", description: "search-only", taskPrompt: "Find alpha using search snippets.", modelOverride: nil, runInBackground: false, deliverable: .short)
            let searched = await runner.run(invocation: ask, sessionId: nil, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let searchedJSON = resultJSON(searched)
            let seen = searchedJSON["search_results_seen"] as? [[String: Any]] ?? []
            check("13.4 R3: a search-only run — retrieved_this_run, sources_consulted EMPTY (nothing read), search_results_seen lists the hits with query and retrieved_at",
                  searched.error == nil && searched.evidenceProvenance == .retrievedThisRun && (searchedJSON["sources_consulted"] as? [[String: Any]])?.isEmpty == true
                  && seen.map { $0["url"] as? String } == ["https://example.test/alpha", "https://example.test/alpha-2"]
                  && seen.allSatisfy { $0["query"] as? String == "alpha" && ($0["retrieved_at"] as? String)?.hasPrefix("2026-04-10 10:00:00") == true }, searched.asJSON())
            // N1: a lowercase invocation runs the Web preset and lives in the Web pool under the canonical name.
            let savedSearch = await SubagentSessionRegistry.shared.get(searched.sessionId)
            await SubagentSessionRegistry.shared.reloadFromDisk()
            let reloadedSearch = await SubagentSessionRegistry.shared.get(searched.sessionId)
            let impostor = await SubagentSessionRegistry.shared.create(subagentType: "Web", description: "impostor", initialPrompt: "x", webPool: false)
            check("13.5 N1: subagent_type 'web' → stored as the canonical 'Web', pool marker set, Web pool before and after reload; a session created without the marker is general even under that name",
                  savedSearch?.subagentType == "Web" && savedSearch?.pool == "web" && savedSearch?.kind == .web && reloadedSearch?.kind == .web && reloadedSearch?.topic != nil
                  && impostor.session.kind == .general,
                  "stored type: \(savedSearch?.subagentType ?? "missing") pool: \(savedSearch?.pool ?? "nil")")
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("Alpha, still from the retained snippets."), WebFixtureServer.chatBody("Alpha, still from the retained snippets.")])
            let continued = await runner.run(invocation: ask, sessionId: searched.sessionId, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            check("13.6 R3: the no-retrieval follow-up of a search-only session is prior_sources_only (never no_evidence): 0 of 0 extracts, 2 of 2 search results, prefix with both figures, records survive save/reload with their query",
                  continued.error == nil && continued.evidenceProvenance == .priorSourcesOnly
                  && resultJSON(continued)["prior_extracts_in_context"] as? String == "0 of 0" && resultJSON(continued)["prior_search_results_in_context"] as? String == "2 of 2"
                  && continued.finalMessage.hasPrefix("[FROM RETAINED HISTORY — no new retrieval in this run; 0 of 0 earlier extracts and 2 of 2 earlier search results still in context]\n")
                  && reloadedSearch?.webEvidence?.count == 2 && reloadedSearch?.webEvidence?.allSatisfy { !$0.isExtract && $0.query == "alpha" && $0.inContext } == true, continued.asJSON())
            // Empty and failed searches leave no evidence; the follow-up is no_evidence.
            fixtures.serperMode = .empty
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"omicron\"]}")]), WebFixtureServer.chatBody("Nothing about omicron.")])
            let emptyRun = await runner.run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "empty", taskPrompt: "omicron?", modelOverride: nil, runInBackground: false, deliverable: .short),
                                            sessionId: nil, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            fixtures.serperMode = .failing
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"omicron\"]}")]), WebFixtureServer.chatBody("Search failed.")])
            let failedRun = await runner.run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "failed", taskPrompt: "more?", modelOverride: nil, runInBackground: false, deliverable: .short),
                                             sessionId: emptyRun.sessionId, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            fixtures.serperMode = .normal
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("Omicron from memory."), WebFixtureServer.chatBody("Omicron from memory.")])
            let afterEmpty = await runner.run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "after", taskPrompt: "so?", modelOverride: nil, runInBackground: false, deliverable: .short),
                                              sessionId: emptyRun.sessionId, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let emptyEvidence = await SubagentSessionRegistry.shared.get(emptyRun.sessionId)?.webEvidence ?? []
            check("13.7 R3: empty and failed searches add no evidence records (queries stay logged); the later no-retrieval run is no_evidence, not prior_sources_only",
                  emptyRun.evidenceProvenance == .attemptedNoResults && failedRun.error?.hasPrefix("web_tools_failed") == true && emptyEvidence.isEmpty
                  && afterEmpty.evidenceProvenance == .noEvidence && (resultJSON(afterEmpty)["queries_used"] as? [String]) == ["omicron", "omicron"], afterEmpty.asJSON())
            // Answer-box-only evidence: usable, URL-less, no URL invented.
            fixtures.serperMode = .answerBoxOnly
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"meaning\"]}")]), WebFixtureServer.chatBody("It is 42.")])
            let boxRun = await runner.run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "box", taskPrompt: "meaning?", modelOverride: nil, runInBackground: false, deliverable: .short),
                                          sessionId: nil, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            fixtures.serperMode = .normal
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("Still 42."), WebFixtureServer.chatBody("Still 42.")])
            let boxFollow = await runner.run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "box2", taskPrompt: "sure?", modelOverride: nil, runInBackground: false, deliverable: .short),
                                             sessionId: boxRun.sessionId, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let boxEvidence = await SubagentSessionRegistry.shared.get(boxRun.sessionId)?.webEvidence ?? []
            check("13.8 R3: answer-box-only evidence — retrieved_this_run, no hit URLs, search_results_seen_urlless = 1, record with an EMPTY url (none invented); the follow-up counts it as 1 of 1 search results",
                  boxRun.evidenceProvenance == .retrievedThisRun && (resultJSON(boxRun)["search_results_seen"] as? [[String: Any]])?.isEmpty == true
                  && resultJSON(boxRun)["search_results_seen_urlless"] as? Int == 1 && boxEvidence.count == 1 && boxEvidence[0].url == "" && boxEvidence[0].isExtract == false
                  && boxFollow.evidenceProvenance == .priorSourcesOnly && resultJSON(boxFollow)["prior_search_results_in_context"] as? String == "1 of 1", boxRun.asJSON())
            // Compaction of the search result's round flips the search records' flags.
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "1000")
            let bigDialogue = (0..<6).map { i in Message(role: i % 2 == 0 ? .user : .assistant, content: String(repeating: "older content ", count: 100), timestamp: at(2026, 4, 9, 11, i, 0)) }
            let storedSearch = await SubagentSessionRegistry.shared.get(searched.sessionId)!
            // A bulkier NEWER round after the search, so the compaction's verbatim tail holds that one and the search round is evicted.
            let bulkyRound = ToolInteraction(
                assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: [ToolCall(id: "bulky-1", type: "function", function: FunctionCall(name: "web_extract", arguments: "{}"))]),
                results: [ToolResultMessage(toolCallId: "bulky-1", content: String(repeating: "bulky result ", count: 200))])
            await SubagentSessionRegistry.shared.applyCompaction(sessionId: searched.sessionId, messages: bigDialogue, toolInteractions: storedSearch.toolInteractions + [bulkyRound])
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("EVICTED_SUMMARY"), WebFixtureServer.chatBody("From the summary: alpha.", prompt: 300), WebFixtureServer.chatBody("From the summary: alpha.", prompt: 300)])
            let compactedSearch = await runner.run(invocation: ask, sessionId: searched.sessionId, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "250000")
            let compactedRecords = await SubagentSessionRegistry.shared.get(searched.sessionId)?.webEvidence ?? []
            check("13.9 R3: a committed compaction that evicts the search round → 0 of 2 search results in context, records kept",
                  compactedSearch.error == nil && compactedSearch.evidenceProvenance == .priorSourcesOnly && resultJSON(compactedSearch)["prior_search_results_in_context"] as? String == "0 of 2"
                  && compactedRecords.count == 2 && compactedRecords.allSatisfy { !$0.inContext }, compactedSearch.asJSON())
            // Bound: the newest 400 search records are kept, extracts never dropped.
            let bounded = WebEvidenceLedger(records: [WebEvidenceRecord(url: "x", fetchedAt: state.clock, toolCallId: "e0")], deliverable: .short)
            bounded.append((0..<410).map { WebEvidenceRecord(url: "s\($0)", fetchedAt: state.clock, toolCallId: "s", isExtract: false, query: "q") })
            check("13.10 R3: the per-session search-record bound (400, oldest dropped first) never touches page extracts",
                  bounded.searchCounts.total == 400 && bounded.extractCounts.total == 1 && bounded.allRecords.contains { $0.url == "s409" } && !bounded.allRecords.contains { $0.url == "s9" })

            // ---- R4: in-context flags reconcile against the retained results.
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "60000")
            fixtures.pages["https://example.test/cutoff"] = "# Cutoff\n\nCutoff facts."
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("extract", calls: [("web_extract", "{\"requests\":[{\"url\":\"https://example.test/cutoff\",\"focus\":\"facts\"}]}")], prompt: 60000), WebFixtureServer.chatBody("Cutoff; results omitted.")])
            let cutoff = await runner.run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "cutoff", taskPrompt: "Read this page.", modelOverride: nil, runInBackground: false, deliverable: .short),
                                          sessionId: nil, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "250000")
            let cutSaved = await SubagentSessionRegistry.shared.get(cutoff.sessionId)
            let retainedIds = Set((cutSaved?.toolInteractions ?? []).flatMap { $0.results.map(\.toolCallId) } + (cutSaved?.messages ?? []).flatMap { $0.toolInteractions.flatMap { $0.results.map(\.toolCallId) } })
            let cutEvidence = cutSaved?.webEvidence ?? []
            check("13.11 R4: a hard cutoff that drops the executed extract's round → the record stays (audit: sources_consulted lists the page) but is NOT in context in the saved session",
                  cutoff.error == nil && retainedIds.isEmpty && cutEvidence.count == 1 && cutEvidence[0].inContext == false && cutEvidence[0].url == "https://example.test/cutoff"
                  && ((resultJSON(cutoff)["sources_consulted"] as? [[String: Any]])?.first?["url"] as? String) == "https://example.test/cutoff", "retained ids: \(retainedIds.count); \(cutoff.asJSON())")
            // Resume after a cutoff: prior_sources_only with 0 of 1 (never claims the extract is available).
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("Cannot recall the page."), WebFixtureServer.chatBody("Cannot recall the page.")])
            let afterCut = await runner.run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "after-cut", taskPrompt: "what did it say?", modelOverride: nil, runInBackground: false, deliverable: .short),
                                            sessionId: cutoff.sessionId, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            check("13.12 R4: the resume after the cutoff reports 0 of 1 extracts in context", afterCut.evidenceProvenance == .priorSourcesOnly && resultJSON(afterCut)["prior_extracts_in_context"] as? String == "0 of 1", afterCut.asJSON())
            // Orphan record (crash between the ledger write and the result commit) and an uncertain Responses placeholder: both absent at resume.
            fixtures.pages["https://example.test/kept"] = "# Kept\n\nKept facts."
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("extract", calls: [("web_extract", "{\"requests\":[{\"url\":\"https://example.test/kept\",\"focus\":\"facts\"}]}")]), WebFixtureServer.chatBody("Kept.")])
            let kept = await runner.run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "kept", taskPrompt: "Read kept.", modelOverride: nil, runInBackground: false, deliverable: .short),
                                        sessionId: nil, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let keptSession = await SubagentSessionRegistry.shared.get(kept.sessionId)!
            let placeholderRound = ToolInteraction(
                assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: [ToolCall(id: "uncertain-1", type: "function", function: FunctionCall(name: "web_extract", arguments: "{}"))]),
                results: [ToolResultMessage(toolCallId: "uncertain-1", content: SubagentRunner.interruptedToolIntentPlaceholder)])
            let doctored = (keptSession.webEvidence ?? []) + [
                WebEvidenceRecord(url: "https://example.test/ghost", fetchedAt: state.clock, toolCallId: "ghost-1"),
                WebEvidenceRecord(url: "https://example.test/uncertain", fetchedAt: state.clock, toolCallId: "uncertain-1")]
            await SubagentSessionRegistry.shared.applyCompaction(sessionId: kept.sessionId, messages: keptSession.messages, toolInteractions: keptSession.toolInteractions + [placeholderRound], webEvidence: doctored)
            await SubagentSessionRegistry.shared.reloadFromDisk()
            serverB.clear()
            serverB.script([WebFixtureServer.chatBody("From kept."), WebFixtureServer.chatBody("From kept.")])
            let resumedKept = await runner.run(invocation: SubagentRunner.Invocation(subagentType: "Web", description: "kept2", taskPrompt: "and?", modelOverride: nil, runInBackground: false, deliverable: .short),
                                               sessionId: kept.sessionId, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let reconciled = await SubagentSessionRegistry.shared.get(kept.sessionId)?.webEvidence ?? []
            check("13.13 R4: at resume an orphan record (result never persisted) and a record behind an uncertain Responses placeholder lose the flag; the really retained extract keeps it → 1 of 3",
                  resumedKept.evidenceProvenance == .priorSourcesOnly && resultJSON(resumedKept)["prior_extracts_in_context"] as? String == "1 of 3"
                  && reconciled.count == 3 && reconciled.first { $0.url.hasSuffix("/kept") }?.inContext == true
                  && reconciled.first { $0.url.hasSuffix("/ghost") }?.inContext == false && reconciled.first { $0.url.hasSuffix("/uncertain") }?.inContext == false, resumedKept.asJSON())

            // ---- R2: the background completion message carries the Web result contract.
            try KeychainHelper.delete(key: KeychainHelper.webSearchOpenCodeApiKeyKey)
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"kappa\"]}")]), WebFixtureServer.chatBody("# Kappa report\n\nKappa. Sources: https://example.test/kappa")])
            let bgInvocation = SubagentRunner.Invocation(subagentType: "Web", description: "bg report", taskPrompt: "Report on kappa.", modelOverride: nil, runInBackground: true, deliverable: .report)
            _ = await SubagentBackgroundRegistry.shared.spawn(invocation: bgInvocation, sessionId: nil, parentTools: all, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents)
            var completions: [SubagentBackgroundRegistry.Completion] = []
            for _ in 0..<200 where completions.isEmpty {
                completions = await SubagentBackgroundRegistry.shared.drainCompletions()
                if completions.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            try KeychainHelper.save(key: KeychainHelper.webSearchOpenCodeApiKeyKey, value: "synthetic-web-opencode-key")
            let bgBody = completions.first.map { ConversationManager.backgroundSubagentCompletionBody($0, durationStr: "1.0s") } ?? ""
            let bgLines = bgBody.components(separatedBy: "\n")
            let bgResult = completions.first?.result
            check("13.14 R2: a background Web run's [SUBAGENT COMPLETE] message (the manager's template) carries evidence_provenance, queries_used, sources_consulted, search_results_seen, report_path, the backend-fallback note and model_used, before final_message",
                  completions.count == 1 && bgResult?.error == nil
                  && bgLines.contains("evidence_provenance: retrieved_this_run") && bgLines.contains("queries_used: [\"kappa\"]")
                  && bgLines.contains("sources_consulted: []") && bgLines.contains { $0.hasPrefix("search_results_seen: [{") && $0.contains("\"url\":\"https://example.test/kappa\"") }
                  && bgLines.contains { $0.hasPrefix("report_path: ") && $0.hasSuffix(".md") && FileManager.default.fileExists(atPath: String($0.dropFirst("report_path: ".count))) }
                  && bgLines.contains { $0.hasPrefix("note: web backend unavailable") } && bgLines.contains("model_used: main-model (inherited)")
                  && (bgLines.firstIndex(of: "final_message:") ?? -1) > (bgLines.firstIndex { $0.hasPrefix("report_path: ") } ?? Int.max)
                  && bgBody.hasSuffix("\n# Kappa report\n\nKappa. Sources: https://example.test/kappa"), bgBody.prefix(900).description)
            // Failed/partial and prior-sources shapes through the same template; ordinary runs byte-identical to the legacy layout.
            var failedResult = SubagentRunner.RunResult(sessionId: "abcde", isNewSession: false, finalMessage: "partial", turnsUsed: 2, toolsCalled: ["web_query"], filesTouched: [], spendUSD: 0.01, error: "web_tools_failed: search — boom", modelUsed: "mimo-v2.5 (web backend: opencode)")
            failedResult.evidenceProvenance = .priorSourcesOnly
            failedResult.queriesUsed = ["a"]
            failedResult.sourcesConsulted = [(url: "https://example.test/a", retrievedAt: state.clock)]
            failedResult.searchEvidence = WebSearchEvidenceSummary(hits: [], urlless: 2)
            failedResult.priorEvidence = WebPriorEvidence(extracts: .init(inContext: 1, total: 2), searchResults: .init(inContext: 0, total: 3))
            let handle = SubagentBackgroundRegistry.Handle(id: "subagent_9", subagentType: "Web", description: "d", startedAt: state.clock, sessionId: "abcde")
            let failedBody = ConversationManager.backgroundSubagentCompletionBody(SubagentBackgroundRegistry.Completion(handle: handle, result: failedResult, completedAt: state.clock), durationStr: "2.0s")
            let ordinary = SubagentRunner.RunResult(sessionId: "zzzzz", isNewSession: true, finalMessage: "done", turnsUsed: 1, toolsCalled: [], filesTouched: ["/tmp/x"], spendUSD: 0.5, error: nil, modelUsed: "main-model (inherited)")
            let ordinaryBody = ConversationManager.backgroundSubagentCompletionBody(SubagentBackgroundRegistry.Completion(handle: SubagentBackgroundRegistry.Handle(id: "subagent_2", subagentType: "general-purpose", description: "g", startedAt: state.clock), result: ordinary, completedAt: state.clock), durationStr: "3.5s")
            let legacyLayout = "[SUBAGENT COMPLETE]\nhandle: subagent_2\nsubagent_type: general-purpose\ndescription: g\nsession_id: zzzzz\nturns_used: 1\ntools_called: (none)\nfiles_touched: /tmp/x\nspend_usd: 0.5000\nduration: 3.5s\nfinal_message:\ndone"
            check("13.15 R2: failed/partial Web result → contract lines then error + 'final_message (possibly partial)'; prior counts for both classes; urlless count; an ordinary run's message is the legacy layout byte for byte",
                  failedBody.contains("\nevidence_provenance: prior_sources_only\nqueries_used: [\"a\"]\nsources_consulted: [{\"retrieved_at\":\"\(ToolExecutor.webTimestamp(state.clock))\",\"url\":\"https://example.test/a\"}]\nsearch_results_seen: []\nsearch_results_seen_urlless: 2\nprior_extracts_in_context: 1 of 2\nprior_search_results_in_context: 0 of 3\nmodel_used: mimo-v2.5 (web backend: opencode)\nerror: web_tools_failed: search — boom\nfinal_message (possibly partial):\npartial")
                  && ordinaryBody == legacyLayout, failedBody + "\n---\n" + ordinaryBody)

            // ---- N2: report files are payload — full Mind export carries them, lite skips them, /deleteuserdata targets them.
            let researchDir = StoragePaths.dataRoot.appendingPathComponent("research", isDirectory: true)
            check("13.16 N2: the report directory is a payload folder (full export yes, lite no), restored on import, classified as user content (0600 sweep), and the report file exists 0600",
                  MindExportService.ExportScope.payloadFolderNames.contains("research") && MindExportService.restoredFolderNames.contains("research")
                  && PrivateStorage.classify(researchDir.appendingPathComponent("abcde-1.md").path) == .inScope
                  && (bgResult?.reportPath).map { FileManager.default.fileExists(atPath: $0) && (try? FileManager.default.attributesOfItem(atPath: $0)[.posixPermissions] as? Int) == 0o600 } == true,
                  bgResult?.reportPath ?? "no report")
            state.webFlag = false
            state.clock = at(2026, 4, 10, 10, 0, 0)
        }

        print("14. Built-in identity, not display name (Codex round 2) — and Browse vs Web wording")
        do {
            state.webFlag = false
            state.subagentsFlag = true
            WebSearchBackend.processOverride = .opencode
            // A REAL user-defined agent named `Web`, loaded through UserAgentLoader.
            let agentsDir = StoragePaths.configRoot.appendingPathComponent("agents", isDirectory: true)
            try PrivateStorage.ensureDirectory(agentsDir)
            let definition = agentsDir.appendingPathComponent("custom-web.md")
            try "---\nname: Web\ndescription: User-defined offline reader\ntools: read_file\nmodel: inherit\n---\nAnswer from the supplied task only.\n".write(to: definition, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: definition) }

            let custom = SubagentTypes.find(name: "Web")
            let parentOn = AvailableTools.all(includeWebSearch: true)
            let inventory = custom.map { SubagentRunner.nativeToolInventory(parentTools: parentOn, type: $0).map { $0.function.name } } ?? []
            check("14.1 switch off: the loaded custom Web is ORDINARY (role, not researcher), keeps its read_file whitelist, messaging prompt, inherit lane",
                  custom != nil && custom?.builtInRole == .ordinary && custom?.isWebResearcher == false && inventory == ["read_file"]
                  && custom?.promptStyle == .messaging && custom?.forbidMCP == false && custom?.description == "User-defined offline reader",
                  "role=\(String(describing: custom?.builtInRole)) tools=\(inventory)")
            let schemaOff = parentOn.first { $0.function.name == "Agent" }!
            check("14.2 switch off: the custom Web is listed by name but enables NO researcher schema (no deliverable, no Web usage notes, no Browse scope)",
                  schemaOff.function.parameters.properties["subagent_type"]?.enumValues?.contains("Web") == true
                  && schemaOff.function.parameters.properties["deliverable"] == nil
                  && !schemaOff.function.description.contains("Web research: use subagent_type=Web")
                  && !schemaOff.function.description.contains("OPERATE a browser")
                  && schemaOff.function.description.contains("  - Web: User-defined offline reader (tools: read_file)"))
            check("14.3 switch off: deliverable validation treats the custom Web as ordinary (no default, parameter refused)",
                  ToolExecutor.agentDeliverable(nil, subagentType: "Web").deliverable == nil
                  && ToolExecutor.agentDeliverable("report", subagentType: "Web").error == "{\"error\": \"deliverable is only valid for subagent_type=Web\"}")
            // Real runner: main profile (A), general pool, no research metadata.
            let customExecutor = ToolExecutor(outputMode: .subagent)
            await customExecutor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("Custom offline answer")])
            serverB.script([WebFixtureServer.chatBody("Custom offline answer"), WebFixtureServer.chatBody("Custom offline answer")])
            let customRun = await SubagentRunner().run(
                invocation: .init(subagentType: "Web", description: "custom offline", taskPrompt: "Summarize the supplied text.", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: customExecutor, imagesDirectory: images, documentsDirectory: documents, parentTools: parentOn)
            let customSession = await SubagentSessionRegistry.shared.get(customRun.sessionId)
            let customJSON = resultJSON(customRun)
            check("14.4 switch off: the custom Web runs on the MAIN profile (1 request on A, 0 on the web backend), lands in the general pool, carries no provenance / queries / report / backend note",
                  customRun.error == nil && serverA.requests.count == 1 && serverB.requests.isEmpty
                  && customSession?.kind == .general && customSession?.pool == nil && customSession?.subagentType == "Web"
                  && customRun.evidenceProvenance == nil && customJSON["evidence_provenance"] == nil && customJSON["queries_used"] == nil
                  && customJSON["report_path"] == nil && customJSON["note"] == nil
                  && (customJSON["model_used"] as? String)?.contains("web backend") != true,
                  "A=\(serverA.requests.count) B=\(serverB.requests.count) pool=\(customSession?.pool ?? "nil") model=\(customRun.modelUsed ?? "nil") err=\(customRun.error ?? "nil")")
            let customBody = serverA.requests.first.map(body) ?? [:]
            let customToolNames = ((customBody["tools"] as? [[String: Any]]) ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            let customSystem = ((customBody["messages"] as? [[String: Any]]) ?? []).first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
            check("14.5 switch off: the custom Web's request carries the messaging prompt with its own suffix and its own whitelist (read_file only, no web_query)",
                  customToolNames == ["read_file"]
                  && customSystem.contains("Reply with short direct messages")
                  && customSystem.contains("Answer from the supplied task only."),
                  "tools=\(customToolNames) system=\(customSystem.prefix(200))")
            // Main prompt: with the custom Web listed, the legacy guidance whether web search is available or not.
            let offAvailable = await service.prepareConversation(messages: [Message(role: .user, content: "hi", timestamp: state.clock)], imagesDirectory: images, documentsDirectory: documents,
                tools: AvailableTools.all(includeWebSearch: true), toolResultMessages: nil, calendarContext: nil, emailContext: nil, chunkSummaries: nil, totalChunkCount: 0,
                turnStartDate: state.clock, finalResponseInstruction: nil, tailSystemMessage: nil, tailUserMessage: nil, deferredMCPSummaries: nil)
            let offUnavailable = await service.prepareConversation(messages: [Message(role: .user, content: "hi", timestamp: state.clock)], imagesDirectory: images, documentsDirectory: documents,
                tools: AvailableTools.all(includeWebSearch: false), toolResultMessages: nil, calendarContext: nil, emailContext: nil, chunkSummaries: nil, totalChunkCount: 0,
                turnStartDate: state.clock, finalResponseInstruction: nil, tailSystemMessage: nil, tailUserMessage: nil, deferredMCPSummaries: nil)
            let unavailableAgent = AvailableTools.all(includeWebSearch: false).first { $0.function.name == "Agent" }
            check("14.6 switch off, custom Web in the enum: main-prompt guidance is the legacy line with web search available AND unavailable (no web_search tool, 'Web' in the enum)",
                  offAvailable.systemPrompt.contains("- Use web tools for current or unstable facts, and cite sources when useful.") && !offAvailable.systemPrompt.contains("Web subagent")
                  && offUnavailable.systemPrompt.contains("- Use web tools for current or unstable facts, and cite sources when useful.") && !offUnavailable.systemPrompt.contains("Web subagent")
                  && unavailableAgent?.function.parameters.properties["subagent_type"]?.enumValues?.contains("Web") == true
                  && AvailableTools.all(includeWebSearch: false).contains { $0.function.name == "web_search" } == false)
            // Switch on: the built-in shadows the file; the lowercase call resolves to the built-in (13.5 keeps the pool check).
            state.webFlag = true
            let builtIn = SubagentTypes.find(name: "web")
            let onTypes = SubagentTypes.all(webSearchAvailable: true)
            check("14.7 switch on: the built-in shadows the custom file — one Web in the listing, lowercase resolves to the researcher by identity, the file's description absent from the schema",
                  builtIn?.builtInRole == .webResearcher && builtIn?.isWebResearcher == true && onTypes.filter { $0.name.lowercased() == "web" }.count == 1
                  && onTypes.first { $0.name == "Web" }?.builtInRole == .webResearcher
                  && !AvailableTools.all(includeWebSearch: true).first { $0.function.name == "Agent" }!.function.description.contains("User-defined offline reader"))
            // Browse vs Web wording (owner question 2026-09-16): gated on the researcher's presence, by identity.
            let browseOn = AvailableTools.agentListingLine(for: SubagentTypes.browse, webPresent: true)
            let browseOff = AvailableTools.agentListingLine(for: SubagentTypes.browse, webPresent: false)
            let customBrowse = SubagentType(name: "Browse", description: "my browse", systemPromptSuffix: "", allowedToolNames: ["read_file"], defaultMaxTurns: 1, preferredModel: .inherit)
            let onSchema = AvailableTools.all(includeWebSearch: true).first { $0.function.name == "Agent" }!.function.description
            check("14.8 Browse line: legacy byte for byte while Web is absent; the OPERATE-a-browser scope while Web is present; a user agent named Browse (ordinary role) never gets it",
                  browseOff == "  - Browse: browser automation via Playwright MCP (tools: bash, grep, inspect_media, read_file, web_fetch, web_search; MCP: mcp__playwright__*)"
                  && browseOn == "  - Browse: browser automation via Playwright MCP" + AvailableTools.browseScopeWhileWebPresent + " (tools: bash, grep, inspect_media, read_file, web_fetch, web_search; MCP: mcp__playwright__*)"
                  && SubagentTypes.browse.builtInRole == .browser && customBrowse.builtInRole == .ordinary
                  && !AvailableTools.agentListingLine(for: customBrowse, webPresent: true).contains("OPERATE"),
                  browseOff + "\n" + browseOn)
            check("14.9 Web usage notes (switch on) tell the model Browse is only for operating a browser and research goes to Web",
                  onSchema.contains("Browse (when listed) is only for operating a browser") && onSchema.contains("use subagent_type=Web instead of searching yourself — for any lookup, fact check, or reading of public pages"))
            state.webFlag = false
            serverA.clear(); serverB.clear()
        }
    }
}
