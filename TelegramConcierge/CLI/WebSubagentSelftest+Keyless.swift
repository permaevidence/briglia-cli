import Foundation

/// Keyless Web researcher requests (KEYLESS_WEB_AND_LIVE_MENU_PLAN A.10,
/// D14): with no Serper key the actual Web subagent request differs from
/// the keyed one ONLY in the `web_query` description; searches go to the
/// fake Parallel server under the conversation search ID; a resumed session
/// and a nested delegation get the same variant. Reviewed side by side with
/// the keyed run (same script, same clock), not against a frozen file: the
/// keyed request bytes are themselves pinned by the wire fixtures.
/// Its own file (feedback_linux_selftest_size_split).
extension WebSubagentSelftest {
    static func runKeylessGroup(_ h: Harness) async throws {
        let state = h.state, images = h.images, documents = h.documents, service = h.service
        let serverA = h.serverA, serverB = h.serverB, serverS = h.serverS
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        func body(_ request: WebFixtureServer.Request) -> [String: Any] { h.body(request) }
        func agentRequests(_ server: WebFixtureServer) -> [WebFixtureServer.Request] { h.agentRequests(server) }
        func sortedJSON(_ object: Any) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        func toolsJSON(_ request: WebFixtureServer.Request) -> String { sortedJSON(body(request)["tools"] ?? []) }
        func messagesJSON(_ request: WebFixtureServer.Request) -> String { sortedJSON(body(request)["messages"] ?? []) }
        func agentCall(_ arguments: [String: Any]) -> (String, String) { ("Agent", sortedJSON(arguments)) }

        print("23. Keyless Web researcher (free search, D14)")
        // Fake Parallel on the Serper/reader fixture, under /mcp.
        let fake = FakeParallel()
        let baseRoute = serverS.route
        serverS.route = { request in
            request.path == "/mcp" ? fake.handle(request) : (baseRoute?(request) ?? .init(status: 404, body: "{}"))
        }
        setenv("BRIGLIA_DEV_PARALLEL_BASE", h.baseS, 1)
        await ParallelSearchClient.shared.installForTesting(send: nil)
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-websub-keyless-\(UUID().uuidString).json")
        ParallelSessionStore.fileURLOverrideForTesting = sessionFile
        let savedSerper = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey)
        defer {
            serverS.route = baseRoute
            unsetenv("BRIGLIA_DEV_PARALLEL_BASE")
            ParallelSessionStore.fileURLOverrideForTesting = nil
            try? FileManager.default.removeItem(at: sessionFile)
            if let savedSerper { try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: savedSerper) }
        }
        state.webFlag = true
        state.subagentsFlag = true
        let all = AvailableTools.all(includeWebSearch: true)
        let script = [WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"kappa\"]}")]),
                      WebFixtureServer.chatBody("Kappa is K. Sources: https://example.test/kappa/0")]

        func runWeb(serperKey: String, sessionId: String? = nil, prompt: String = "What is kappa?") async -> (SubagentRunner.RunResult, [WebFixtureServer.Request]) {
            serverA.clear(); serverB.clear()
            serverB.script(script)
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.configure(openRouterKey: "", serperKey: serperKey, jinaKey: "synthetic-jina-key")
            await executor.configureOpenRouter(service, imagesDirectory: images, documentsDirectory: documents)
            let run = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "Web", description: "kappa", taskPrompt: prompt, modelOverride: nil, runInBackground: false, deliverable: .short),
                sessionId: sessionId, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            return (run, agentRequests(serverB))
        }

        // Keyed reference run (the Serper key in the store and in the executor).
        if savedSerper == nil { try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "synthetic-serper-key") }
        let (keyedRun, keyedRequests) = await runWeb(serperKey: "synthetic-serper-key")
        // Keyless run: no Serper key anywhere, free search on by default.
        try? KeychainHelper.delete(key: KeychainHelper.serperApiKeyKey)
        fake.reset()
        let (keylessRun, keylessRequests) = await runWeb(serperKey: "")
        let keyedDesc = AvailableTools.webQuery.function.description
        let keylessDesc = AvailableTools.webQueryKeyless.function.description
        let keylessTools = keylessRequests.first.map(toolsJSON) ?? ""
        let keyedTools = keyedRequests.first.map(toolsJSON) ?? ""
        let sessionId = (try? ParallelSessionStore.idForSearch()) ?? ""
        let parallelCalls = fake.requests.filter { $0.method == "tools/call" }
        let sentSession = parallelCalls.first.flatMap { (($0.body["params"] as? [String: Any])?["arguments"] as? [String: Any])?["session_id"] as? String }
        check("23.1 the actual keyless Web subagent request: tools identical to the keyed request except the web_query description (D14); keyed request carries the Serper description",
              keylessTools.contains("title, excerpt, link") && keylessTools.replacingOccurrences(of: keylessDesc, with: keyedDesc) == keyedTools && keyedTools.contains("answer boxes and knowledge panels")
              && keylessTools != keyedTools, String(keylessTools.prefix(300)))
        check("23.2 the keyless request's messages (system prompt, task) are byte-identical to the keyed request's",
              keylessRequests.first.map(messagesJSON) == keyedRequests.first.map(messagesJSON) && keylessRequests.count == keyedRequests.count)
        check("23.3 the researcher's search went to Parallel (one tools/call per query) under the conversation search ID; no Serper call; the run finished with the same answer",
              keylessRun.error == nil && keyedRun.error == nil && parallelCalls.count == 1 && sentSession == sessionId && !sessionId.isEmpty
              && keylessRun.finalMessage == keyedRun.finalMessage, keylessRun.error ?? "\(parallelCalls.count) calls, session \(sentSession ?? "-")")
        let secondRoundTool = keylessRequests.count > 1 ? (((body(keylessRequests[1])["messages"] as? [[String: Any]]) ?? []).last { $0["role"] as? String == "tool" }?["content"] as? String ?? "") : ""
        check("23.4 the Parallel results reach the researcher's next round as an ordinary web_query result",
              secondRoundTool.contains("https://example.test/kappa/0") && secondRoundTool.contains("first excerpt 0"), String(secondRoundTool.prefix(300)))

        // Resumed keyless session: the same variant, the same search ID.
        let (resumed, resumedRequests) = await runWeb(serperKey: "", sessionId: keylessRun.sessionId, prompt: "And kappa again?")
        let resumedCalls = fake.requests.filter { $0.method == "tools/call" }
        let resumedSessions = Set(resumedCalls.compactMap { (($0.body["params"] as? [String: Any])?["arguments"] as? [String: Any])?["session_id"] as? String })
        check("23.5 a resumed Web session gets the keyless web_query again and searches under the same conversation search ID",
              resumed.error == nil && resumed.sessionId == keylessRun.sessionId && resumedRequests.allSatisfy { toolsJSON($0).contains("title, excerpt, link") }
              && resumedCalls.count == 2 && resumedSessions == [sessionId], resumed.error ?? "\(resumedSessions)")

        // Nested delegation from a depth-1 general-purpose subagent.
        serverA.clear(); serverB.clear(); fake.reset()
        serverA.script([WebFixtureServer.chatBody("delegating", calls: [agentCall(["subagent_type": "Web", "description": "nested kappa", "prompt": "What is kappa?", "deliverable": "short"])]),
                        WebFixtureServer.chatBody("Parent done.")])
        serverB.script(script)
        let mainExecutor = ToolExecutor(outputMode: .mainAgent)
        await mainExecutor.configure(openRouterKey: "", serperKey: "", jinaKey: "synthetic-jina-key")
        await mainExecutor.configureOpenRouter(service, imagesDirectory: images, documentsDirectory: documents)
        let depth1 = await mainExecutor.makeChildExecutor()
        let parent = await SubagentRunner().run(
            invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "parent", taskPrompt: "Find kappa.", modelOverride: nil, runInBackground: false),
            sessionId: nil, openRouterService: service, toolExecutor: depth1, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
        let nestedRequests = agentRequests(serverB)
        let nestedCalls = fake.requests.filter { $0.method == "tools/call" }
        let nestedSession = nestedCalls.first.flatMap { (($0.body["params"] as? [String: Any])?["arguments"] as? [String: Any])?["session_id"] as? String }
        check("23.6 a nested Web delegation (depth 2, no Serper key) gets the keyless web_query and searches Parallel under the same conversation ID",
              parent.error == nil && !nestedRequests.isEmpty && nestedRequests.allSatisfy { toolsJSON($0).contains("title, excerpt, link") }
              && nestedCalls.count == 1 && nestedSession == sessionId, parent.error ?? "\(nestedRequests.count) requests, \(nestedCalls.count) calls")
        _ = state
    }
}
