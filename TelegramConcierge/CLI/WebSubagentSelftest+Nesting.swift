import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Third part of the Web researcher battery (R1b, WEB_SUBAGENT_PLAN §4.6 and
// §14): depth-1 delegation (group 6), cancellation and the nested batch timer
// (group 7), and the first field test's amendments — research prompt without
// the user's profile, ambient block off for research requests, compact result
// packet, delegation wording (group 15). Its own file for the same reason as
// `+Late`: one function of the combined size does not compile inside the
// 8 GB Linux CI container.
extension WebSubagentSelftest {
    static func runNestingGroups(_ h: Harness) async throws {
        let state = h.state, fixtures = h.fixtures, images = h.images, documents = h.documents, service = h.service
        let serverA = h.serverA, serverB = h.serverB, serverC = h.serverC
        _ = (fixtures, h.serverD, h.serverS, h.baseA, h.baseB, h.baseC, h.baseD, h.baseS)
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
            h.at(year, month, day, hour, minute, second)
        }
        func toolNames(_ tools: [ToolDefinition]) -> [String] { h.toolNames(tools) }
        func chatMessages(_ request: WebFixtureServer.Request) throws -> [(String, String)] { try h.chatMessages(request) }
        func body(_ request: WebFixtureServer.Request) -> [String: Any] { h.body(request) }
        func resultJSON(_ result: SubagentRunner.RunResult) -> [String: Any] { h.resultJSON(result) }
        func agentRequests(_ server: WebFixtureServer) -> [WebFixtureServer.Request] { h.agentRequests(server) }
        func requestToolNames(_ request: WebFixtureServer.Request) -> [String] {
            ((body(request)["tools"] as? [[String: Any]]) ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        }
        func agentCall(_ arguments: [String: Any]) -> (String, String) {
            ("Agent", String(decoding: try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self))
        }
        /// A chat body whose usage carries a provider cost, for spend composition.
        func chatBodyWithCost(_ text: String, cost: Double, calls: [(String, String)] = []) -> String {
            WebFixtureServer.chatBody(text, calls: calls).replacingOccurrences(of: "\"usage\":{", with: "\"usage\":{\"cost\":\(cost),")
        }
        /// Wraps a server's route so requests whose body contains `marker`
        /// are answered after `delay` seconds (the fixture serves each client
        /// on its own thread). The scripted body is popped BEFORE the sleep,
        /// so script order follows request order.
        func delayRoute(_ server: WebFixtureServer, marker: String, delay: TimeInterval) -> (@Sendable (WebFixtureServer.Request) -> WebFixtureServer.Response)? {
            let base = server.route
            server.route = { request in
                let response = base?(request) ?? .init(status: 500, body: "{}")
                if String(decoding: request.body, as: UTF8.self).contains(marker) { Thread.sleep(forTimeInterval: delay) }
                return response
            }
            return base
        }
        let registry = SubagentSessionRegistry.shared
        // Every group below runs with the switch ON; the parent surface is
        // computed after the flip (group 14 leaves the switch off).
        state.webFlag = true
        let all = AvailableTools.all(includeWebSearch: true)
        // A main executor with the service wired, exactly as ConversationManager
        // configures it; depth-1 executors come from makeChildExecutor as in production.
        let mainExecutor = ToolExecutor(outputMode: .mainAgent)
        await mainExecutor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        await mainExecutor.configureOpenRouter(service, imagesDirectory: images, documentsDirectory: documents)

        print("6. Depth-1 delegation")
        do {
            state.webFlag = true
            WebSearchBackend.processOverride = .opencode
            fixtures.serperMode = .normal
            state.clock = at(2026, 4, 12, 9, 0, 0)
            serverA.clear(); serverB.clear()
            let ledgerBefore = UserDefaults.standard.object(forKey: KeychainHelper.openRouterSpendLedgerDefaultsKey) as? Data
            serverA.script([
                WebFixtureServer.chatBody("delegating", calls: [agentCall(["subagent_type": "Web", "description": "quick check", "prompt": "What is zeta? The user is in Italy.", "deliverable": "short"])]),
                WebFixtureServer.chatBody("Parent done: zeta relayed.")])
            serverB.script([
                WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"zeta\"]}")]),
                chatBodyWithCost("Zeta is Z. Sources: https://example.test/zeta", cost: 0.02)])
            let depth1 = await mainExecutor.makeChildExecutor()
            let parentRunner = SubagentRunner()
            let parent = await parentRunner.run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "parent", taskPrompt: "Find out about zeta.", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: depth1, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let parentSession = await registry.get(parent.sessionId)
            let childContent = parentSession?.toolInteractions.last?.results.first?.content ?? ""
            let childJSON = (try? JSONSerialization.jsonObject(with: Data(childContent.utf8)) as? [String: Any]) ?? [:]
            let childSid = childJSON["session_id"] as? String ?? ""
            let childSession = await registry.get(childSid)
            let webRows = await registry.list(limit: 100, kind: .web).sessions
            let parentRequestTools = serverA.requests.first.map(requestToolNames) ?? []
            let parentAgent = ((body(serverA.requests[0])["tools"] as? [[String: Any]]) ?? []).first { ($0["function"] as? [String: Any])?["name"] as? String == "Agent" }
            let parentAgentEnum = (((parentAgent?["function"] as? [String: Any])?["parameters"] as? [String: Any])?["properties"] as? [String: Any])
                .flatMap { ($0["subagent_type"] as? [String: Any])?["enum"] as? [String] }
            let parentPrompt = (try? chatMessages(serverA.requests[0]))?.first?.1 ?? ""
            let childRequests = agentRequests(serverB)
            check("6.1 live nested run: general-purpose (depth 1) calls Agent(Web) → the run executes on B in the foreground, the parent gets the Web packet as its tool result and finishes; the parent's request carried Agent with enum [Web] and no legacy research tools; the parent's messaging prompt names the delegation",
                  parent.error == nil && parent.finalMessage == "Parent done: zeta relayed." && parent.toolsCalled == ["Agent"]
                  && parentRequestTools.contains("Agent") && !parentRequestTools.contains("web_search") && !parentRequestTools.contains("web_research_sweep") && !parentRequestTools.contains("subagent_manage")
                  && parentAgentEnum == ["Web"] && parentPrompt.contains("delegate web research to the Web subagent")
                  && childJSON["evidence_provenance"] as? String == "retrieved_this_run" && childJSON["search_results_seen"] as? String == "2 results across 1 queries"
                  && (childJSON["final_message"] as? String)?.hasPrefix("Zeta is Z.") == true && !childSid.isEmpty,
                  parent.error ?? childContent.prefix(600).description)
            check("6.2 the nested run executed on a depth-2 executor: every Web request on B carried exactly web_query, web_extract, web_fetch — no Agent",
                  childRequests.count == 2 && childRequests.allSatisfy { requestToolNames($0) == ["web_query", "web_extract", "web_fetch"] },
                  childRequests.map { requestToolNames($0).joined(separator: ",") }.joined(separator: " | "))
            check("6.3 the Web session is an ordinary Web-pool session described `via <parent session>`, listed in the web pool, resumable by the main agent",
                  childSession?.kind == .web && childSession?.description == "via \(parent.sessionId): quick check" && webRows.contains { $0.id == childSid },
                  childSession?.description ?? "no child session")
            let ledgerAfter = UserDefaults.standard.object(forKey: KeychainHelper.openRouterSpendLedgerDefaultsKey) as? Data
            let childSpend = childJSON["spend_usd"] as? Double ?? -1
            check("6.4 spend composes once: the child's spend_usd rides on the parent's tool result into the parent's spend_usd; no direct ledger record for the nested run",
                  childSpend > 0 && abs(parent.spendUSD - childSpend) < 1e-9 && ledgerBefore == ledgerAfter,
                  "child \(childSpend) parent \(parent.spendUSD)")
            // A follow-up resumes the same Web session from a fresh depth-1 run.
            serverA.clear(); serverB.clear()
            serverA.script([
                WebFixtureServer.chatBody("following up", calls: [agentCall(["subagent_type": "Web", "description": "follow-up", "prompt": "And eta?", "session_id": childSid, "deliverable": "short"])]),
                WebFixtureServer.chatBody("Parent done again.")])
            serverB.script([WebFixtureServer.chatBody("Eta, from what I read."), WebFixtureServer.chatBody("Eta, from what I read.")])
            let depth1b = await mainExecutor.makeChildExecutor()
            let parent2 = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "parent2", taskPrompt: "Ask about eta.", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: depth1b, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let followContent = (await registry.get(parent2.sessionId))?.toolInteractions.last?.results.first?.content ?? ""
            let followJSON = (try? JSONSerialization.jsonObject(with: Data(followContent.utf8)) as? [String: Any]) ?? [:]
            check("6.5 a later depth-1 run resumes the nested Web session by session_id: same session, is_new_session false, prior_sources_only with the retained search results counted",
                  parent2.error == nil && followJSON["session_id"] as? String == childSid && followJSON["is_new_session"] as? Bool == false
                  && followJSON["evidence_provenance"] as? String == "prior_sources_only" && followJSON["prior_search_results_in_context"] as? String == "2 of 2",
                  followContent.prefix(400).description)

            // Refusals at depth 1: anything but Web, and background runs.
            serverA.clear(); serverB.clear()
            serverA.script([
                WebFixtureServer.chatBody("trying", calls: [
                    agentCall(["subagent_type": "general-purpose", "description": "helper", "prompt": "do things"]),
                    agentCall(["subagent_type": "Web", "description": "bg", "prompt": "look", "run_in_background": true])]),
                WebFixtureServer.chatBody("gave up")])
            let depth1c = await mainExecutor.makeChildExecutor()
            let refusing = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "refusals", taskPrompt: "try", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: depth1c, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let refusals = (await registry.get(refusing.sessionId))?.toolInteractions.last?.results.map(\.content) ?? []
            let running = await SubagentBackgroundRegistry.shared.runningHandles()
            check("6.6 depth 1 refuses a nested type other than Web and a background nested run, before anything starts (no request on B, nothing running)",
                  refusing.error == nil && refusals.count == 2 && refusals[0].contains("may only delegate to Web") && refusals[1].contains("foreground only")
                  && agentRequests(serverB).isEmpty && running.isEmpty, refusals.joined(separator: " | "))

            // Depth 2 is structural: no Agent in the inventory, and the executor refuses even Web.
            let depth2 = await depth1.makeChildExecutor()
            let depth2Inventory = toolNames(SubagentRunner.nativeToolInventory(parentTools: all, type: SubagentTypes.generalPurpose, nestingAllowed: false))
            let depth2Refusal = await depth2.executeAgentToolResult(ToolCall(id: "c1", type: "function", function: FunctionCall(name: "Agent", arguments: agentCall(["subagent_type": "Web", "description": "x", "prompt": "y"]).1)))
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("trying", calls: [agentCall(["subagent_type": "Web", "description": "x", "prompt": "y"])]), WebFixtureServer.chatBody("blocked")])
            let deep = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "deep", taskPrompt: "try", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: depth2, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let deepResults = (await registry.get(deep.sessionId))?.toolInteractions.last?.results.map(\.content) ?? []
            check("6.7 depth 2 (a child of a depth-1 executor): depth counter 2, no Agent in the inventory, the executor refuses even Web, a run there has its Agent call blocked as unavailable and B is never contacted",
                  depth2.depth == 2 && depth1.depth == 1 && mainExecutor.depth == 0 && !depth2Inventory.contains("Agent")
                  && depth2Refusal.content.contains("cannot spawn subagents (depth 2)")
                  && !(serverA.requests.first.map(requestToolNames) ?? []).contains("Agent")
                  && deepResults.first?.contains("not available to this subagent") == true && agentRequests(serverB).isEmpty,
                  deepResults.joined(separator: " | "))

            // Eligibility across types (matrix §4.6.1, R1b on).
            func names(_ type: SubagentType) -> [String] { toolNames(SubagentRunner.nativeToolInventory(parentTools: all, type: type)) }
            let browse = names(SubagentTypes.browse)
            let customNil = names(SubagentType(name: "nil-tools", description: "", systemPromptSuffix: "", allowedToolNames: nil, defaultMaxTurns: 1, preferredModel: .inherit))
            let customSweep = names(SubagentType(name: "sweeper", description: "", systemPromptSuffix: "", allowedToolNames: ["web_research_sweep", "grep"], defaultMaxTurns: 1, preferredModel: .inherit))
            let customReader = names(SubagentType(name: "reader", description: "", systemPromptSuffix: "", allowedToolNames: ["read_file", "web_fetch"], defaultMaxTurns: 1, preferredModel: .inherit))
            let triage = names(SubagentTypes.watcherTriage)
            let web = names(SubagentTypes.webResearcher)
            check("6.8 eligibility: Browse (whitelist names web_search) → Agent(Web) + web_fetch, no web_search; nil-whitelist custom → Agent(Web), no subagent_manage; custom naming web_research_sweep → Agent(Web) + grep; custom without a legacy tool → no Agent; watcher-triage and Web unchanged",
                  browse.first == "Agent" && browse.contains("web_fetch") && !browse.contains("web_search") && browse.contains("bash")
                  && customNil.first == "Agent" && !customNil.contains("subagent_manage") && !customNil.contains("web_search")
                  && customSweep == ["Agent", "grep"] && customReader == ["web_fetch", "read_file"] && !customReader.contains("Agent")
                  && triage == ["read_file", "grep", "list_dir", "list_recent_files"] && web == ["web_query", "web_extract", "web_fetch"],
                  "browse \(browse.prefix(3)) nil \(customNil.prefix(2)) sweep \(customSweep) reader \(customReader)")
            // Switch off: the same executors get the baseline inventory (no delegation, subagent_manage kept).
            state.webFlag = false
            let offGeneral = toolNames(SubagentRunner.nativeToolInventory(parentTools: AvailableTools.all(includeWebSearch: true), type: SubagentTypes.generalPurpose))
            check("6.9 switch off: general-purpose keeps the legacy research tools and subagent_manage, no Agent (baseline)",
                  offGeneral.prefix(3) == ["web_search", "web_research_sweep", "web_fetch"] && !offGeneral.contains("Agent") && offGeneral.contains("subagent_manage"))
            state.webFlag = true
            serverA.clear(); serverB.clear()
        }

        print("7. Cancellation and the nested batch timer")
        do {
            state.webFlag = true
            WebSearchBackend.processOverride = .opencode
            fixtures.serperMode = .normal
            defer {
                SubagentRunner.stalenessTimeoutOverrideForTesting = nil
                SubagentRunner.nestedRunCeilingOverrideForTesting = nil
            }
            // 7.1 Cancel the parent while the child's model request is in flight.
            serverA.clear(); serverB.clear()
            let baseB = delayRoute(serverB, marker: "SLOW-CHILD", delay: 3)
            serverA.script([WebFixtureServer.chatBody("delegating", calls: [agentCall(["subagent_type": "Web", "description": "slow", "prompt": "SLOW-CHILD question", "deliverable": "short"])]), WebFixtureServer.chatBody("never")])
            serverB.script([WebFixtureServer.chatBody("Slow answer."), WebFixtureServer.chatBody("Slow answer.")])
            let depth1 = await mainExecutor.makeChildExecutor()
            let cancelled = Task {
                await SubagentRunner().run(
                    invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "cancel-parent", taskPrompt: "delegate slowly", modelOverride: nil, runInBackground: false),
                    sessionId: nil, openRouterService: service, toolExecutor: depth1, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            }
            // Wait until the child's request has reached B, then cancel the parent.
            for _ in 0..<100 where serverB.requests.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
            let cancelStarted = Date()
            cancelled.cancel()
            let cancelledParent = await cancelled.value
            let cancelLatency = Date().timeIntervalSince(cancelStarted)
            let cancelledChild = await registry.list(limit: 100, kind: .web).sessions.first { $0.description == "via \(cancelledParent.sessionId): slow" }
            let parentHeld = await SubagentSessionLocks.shared.isHeld(cancelledParent.sessionId)
            var childHeld = true
            if let cancelledChild { childHeld = await SubagentSessionLocks.shared.isHeld(cancelledChild.id) }
            let runningAfterCancel = await SubagentBackgroundRegistry.shared.runningHandles()
            serverB.route = baseB
            check("7.1 cancelling the parent mid-child-request: the parent commits 'Subagent cancelled' promptly (not after the 3 s fixture delay), the nested Web session exists and is committed, both FIFO locks are released, nothing is left running",
                  cancelledParent.error == "Subagent cancelled" && cancelLatency < 2.5 && cancelledChild != nil && !parentHeld && !childHeld && runningAfterCancel.isEmpty,
                  "error \(cancelledParent.error ?? "nil") latency \(cancelLatency)")

            // 7.2 The parent's batch timer is re-armed by the child's progress.
            SubagentRunner.stalenessTimeoutOverrideForTesting = 1.0
            SubagentRunner.nestedRunCeilingOverrideForTesting = 10
            serverA.clear(); serverB.clear()
            let steadyBase = delayRoute(serverB, marker: "STEADY-CHILD", delay: 0.25)
            serverA.script([WebFixtureServer.chatBody("delegating", calls: [agentCall(["subagent_type": "Web", "description": "steady", "prompt": "STEADY-CHILD question", "deliverable": "short"])]), WebFixtureServer.chatBody("Parent survived.")])
            serverB.script([
                WebFixtureServer.chatBody("s1", calls: [("web_query", "{\"queries\":[\"one\"]}")]),
                WebFixtureServer.chatBody("s2", calls: [("web_query", "{\"queries\":[\"two\"]}")]),
                WebFixtureServer.chatBody("s3", calls: [("web_query", "{\"queries\":[\"three\"]}")]),
                WebFixtureServer.chatBody("s4", calls: [("web_query", "{\"queries\":[\"four\"]}")]),
                WebFixtureServer.chatBody("Steady answer. Sources: https://example.test/one")])
            let steadyStart = Date()
            let steady = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "steady-parent", taskPrompt: "delegate steadily", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let steadyElapsed = Date().timeIntervalSince(steadyStart)
            serverB.route = steadyBase
            check("7.2 a child that keeps reporting progress (5 requests × 0.25 s, staleness 1.0 s) keeps the parent's batch timer from firing: the parent finishes normally after > 1.2 s (longer than one staleness window)",
                  steady.error == nil && steady.finalMessage == "Parent survived." && steadyElapsed > 1.2 && agentRequests(serverB).count == 5,
                  "error \(steady.error ?? "nil") elapsed \(steadyElapsed) requests \(agentRequests(serverB).count)")

            // 7.3 A stalled child (no progress) is killed by the parent's staleness clock; the parent gets the error.
            serverA.clear(); serverB.clear()
            let stalledBase = delayRoute(serverB, marker: "STALLED-CHILD", delay: 4)
            serverA.script([WebFixtureServer.chatBody("delegating", calls: [agentCall(["subagent_type": "Web", "description": "stalled", "prompt": "STALLED-CHILD question", "deliverable": "short"])]), WebFixtureServer.chatBody("never")])
            serverB.script([WebFixtureServer.chatBody("Late answer."), WebFixtureServer.chatBody("Late answer.")])
            let stalledStart = Date()
            let stalled = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "stalled-parent", taskPrompt: "delegate to a stall", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let stalledElapsed = Date().timeIntervalSince(stalledStart)
            serverB.route = stalledBase
            let stalledChild = await registry.list(limit: 100, kind: .web).sessions.first { $0.description == "via \(stalled.sessionId): stalled" }
            var stalledLocks = (await SubagentSessionLocks.shared.isHeld(stalled.sessionId), true)
            if let stalledChild { stalledLocks.1 = await SubagentSessionLocks.shared.isHeld(stalledChild.id) }
            check("7.3 a stalled child (one 4 s request, staleness 1.0 s) is killed by the parent's clock: the parent reports the staleness error at ~1 s (well before the 4 s response), the child's session is committed and both locks are released",
                  stalled.error?.hasPrefix("Subagent killed: no progress") == true && stalledElapsed >= 0.9 && stalledElapsed < 3.0 && stalledChild != nil && !stalledLocks.0 && !stalledLocks.1,
                  "error \(stalled.error ?? "nil") elapsed \(stalledElapsed)")

            // 7.4 The absolute ceiling bounds a child that never stops making progress.
            SubagentRunner.nestedRunCeilingOverrideForTesting = 2.0
            serverA.clear(); serverB.clear()
            let ceilingBase = delayRoute(serverB, marker: "CEILING-CHILD", delay: 0.25)
            serverA.script([WebFixtureServer.chatBody("delegating", calls: [agentCall(["subagent_type": "Web", "description": "endless", "prompt": "CEILING-CHILD question", "deliverable": "short"])]), WebFixtureServer.chatBody("never")])
            serverB.script((1...20).map { WebFixtureServer.chatBody("r\($0)", calls: [("web_query", "{\"queries\":[\"q\($0)\"]}")]) } + [WebFixtureServer.chatBody("Endless answer.")])
            let ceilingStart = Date()
            let ceiling = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "ceiling-parent", taskPrompt: "delegate endlessly", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let ceilingElapsed = Date().timeIntervalSince(ceilingStart)
            serverB.route = ceilingBase
            let ceilingChild = await registry.list(limit: 100, kind: .web).sessions.first { $0.description == "via \(ceiling.sessionId): endless" }
            var ceilingLocks = (await SubagentSessionLocks.shared.isHeld(ceiling.sessionId), true)
            if let ceilingChild { ceilingLocks.1 = await SubagentSessionLocks.shared.isHeld(ceilingChild.id) }
            let ceilingRequests = agentRequests(serverB).count
            check("7.4 a child that progresses forever (0.25 s per request, staleness 1.0 s) is bounded by the absolute nested ceiling (2.0 s here, 60 min in production): the parent reports the CEILING error (not staleness) at ~2 s after several child requests, the child is cancelled and committed, locks released",
                  ceiling.error?.contains("nested Web run exceeded") == true && ceilingElapsed >= 1.9 && ceilingElapsed < 4.0 && ceilingRequests >= 4 && ceilingChild != nil && !ceilingLocks.0 && !ceilingLocks.1,
                  "error \(ceiling.error ?? "nil") elapsed \(ceilingElapsed) child requests \(ceilingRequests)")
            // Ordinary batches keep the single deadline: a slow ordinary tool with no nested call is killed at staleness.
            SubagentRunner.nestedRunCeilingOverrideForTesting = 10
            serverA.clear()
            serverA.script([WebFixtureServer.chatBody("fetching", calls: [("web_fetch", "{\"url\":\"https://example.test/SLOW-ORDINARY\",\"prompt\":\"read\"}")]), WebFixtureServer.chatBody("never")])
            let readerBase = h.serverS.route
            h.serverS.route = { request in
                if request.path.contains("SLOW-ORDINARY") { Thread.sleep(forTimeInterval: 3) }
                return readerBase?(request) ?? .init(status: 500, body: "{}")
            }
            let ordinaryStart = Date()
            let ordinary = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "ordinary-slow", taskPrompt: "fetch slowly", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let ordinaryElapsed = Date().timeIntervalSince(ordinaryStart)
            h.serverS.route = readerBase
            check("7.5 an ordinary batch (no nested call) keeps the single staleness deadline: a 3 s tool with staleness 1.0 s is killed at ~1 s as before, the ceiling plays no part",
                  ordinary.error?.hasPrefix("Subagent killed: no progress") == true && ordinaryElapsed >= 0.9 && ordinaryElapsed < 2.5, "error \(ordinary.error ?? "nil") elapsed \(ordinaryElapsed)")
            serverA.clear(); serverB.clear()
        }

        print("15. First field test: prompt, ambient block, packet, wording")
        do {
            state.webFlag = true
            WebSearchBackend.processOverride = .opencode
            fixtures.serperMode = .normal
            state.clock = at(2026, 4, 12, 10, 0, 0)
            try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: "PROFILE-MARKER: the user is 40, vegan, prefers replies in Italian.")
            defer { try? KeychainHelper.delete(key: KeychainHelper.structuredUserContextKey) }
            serverA.clear(); serverB.clear()
            serverB.script([WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"sigma\"]}")]), WebFixtureServer.chatBody("Sigma. Sources: https://example.test/sigma")])
            let executor = await mainExecutor.makeChildExecutor()
            let webRun = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "Web", description: "profile", taskPrompt: "About sigma.", modelOverride: nil, runInBackground: false, deliverable: .short),
                sessionId: nil, openRouterService: service, toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let researchPrompt = (try? chatMessages(agentRequests(serverB)[0]))?.first?.1 ?? ""
            serverA.script([WebFixtureServer.chatBody("ok")])
            _ = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "profile-general", taskPrompt: "look", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: [AvailableTools.readFile])
            let generalPrompt = (try? chatMessages(serverA.requests[0]))?.first?.1 ?? ""
            let summarizerShape = await service.prepareConversation(messages: [Message(role: .user, content: "summarize", timestamp: state.clock)], imagesDirectory: images, documentsDirectory: documents,
                tools: [], toolResultMessages: nil, calendarContext: nil, emailContext: nil, chunkSummaries: nil, totalChunkCount: 0,
                turnStartDate: state.clock, finalResponseInstruction: nil, tailSystemMessage: nil, tailUserMessage: nil, deferredMCPSummaries: nil, promptStyle: .research)
            check("15.1 the research prompt carries no user profile and no user name — one identity line with the assistant's name; an ordinary subagent's prompt still carries the profile; the research-style summarizer shape (tools: []) carries neither",
                  webRun.error == nil && researchPrompt.hasPrefix("You are the web research subagent of Fixture Assistant.\n\n") && !researchPrompt.contains("PROFILE-MARKER") && !researchPrompt.contains("Fixture User")
                  && generalPrompt.contains("PROFILE-MARKER") && summarizerShape.systemPrompt.hasPrefix("You are the web research subagent of Fixture Assistant.")
                  && !summarizerShape.systemPrompt.contains("PROFILE-MARKER") && summarizerShape.omitAmbientStatus,
                  researchPrompt.prefix(200).description)
            check("15.2 identity line: assistant name when set, a neutral line otherwise",
                  OpenRouterService.researchIdentityLine(assistantName: " Bree ") == "You are the web research subagent of Bree."
                  && OpenRouterService.researchIdentityLine(assistantName: nil) == "You are the web research subagent of a Briglia assistant.")

            // Wording: the main tool's nesting bullet and usage notes, the children's schema.
            let onAgent = AvailableTools.all(includeWebSearch: true).first { $0.function.name == "Agent" }!.function.description
            let childAgent = AvailableTools.agentToolForChildren.function.description
            state.webFlag = false
            let offAgent = AvailableTools.all(includeWebSearch: true).first { $0.function.name == "Agent" }!.function.description
            state.webFlag = true
            check("15.3 wording: switch on → the nesting bullet says subagents may delegate web research to Web (one level) and the usage notes say the researcher sees neither the conversation nor the profile; switch off → the legacy CANNOT-spawn bullet; the children's schema says the same and names the count",
                  onAgent.contains(AvailableTools.nestingSentenceWhileWebPresent) && !onAgent.contains("Subagents CANNOT spawn other subagents")
                  && onAgent.contains("The researcher sees none of this conversation and not the user's profile") && onAgent.contains("a search_results_seen count")
                  && offAgent.contains("- Subagents CANNOT spawn other subagents. Provide a self-contained prompt") && !offAgent.contains("delegate web research")
                  && childAgent.contains("not the user's profile") && childAgent.contains("search_results_seen count") && childAgent.contains("only in the foreground"))

            // Ambient block: absent from research requests on both transports, present for an ordinary subagent.
            serverA.clear(); serverB.clear(); serverC.clear()
            let slowBase = delayRoute(serverA, marker: "SLOW-BG", delay: 4)
            serverA.script([WebFixtureServer.chatBody("bg done"), WebFixtureServer.chatBody("fg ok")])
            let bgExecutor = await mainExecutor.makeChildExecutor()
            _ = await SubagentBackgroundRegistry.shared.spawn(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "SLOW-BG job", taskPrompt: "SLOW-BG task", modelOverride: nil, runInBackground: true),
                sessionId: nil, parentTools: [AvailableTools.readFile], openRouterService: service, toolExecutor: bgExecutor, imagesDirectory: images, documentsDirectory: documents)
            for _ in 0..<100 where serverA.requests.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
            serverB.script([WebFixtureServer.chatBody("Ambient probe."), WebFixtureServer.chatBody("Ambient probe.")])
            let ambientWeb = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "Web", description: "ambient", taskPrompt: "probe", modelOverride: nil, runInBackground: false, deliverable: .short),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            WebSearchBackend.processOverride = .openai
            serverC.script([WebFixtureServer.responsesBody("Ambient probe.", id: "amb1"), WebFixtureServer.responsesBody("Ambient probe.", id: "amb2")])
            let ambientResponses = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "Web", description: "ambient-responses", taskPrompt: "probe", modelOverride: nil, runInBackground: false, deliverable: .short),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            WebSearchBackend.processOverride = .opencode
            let ambientGeneral = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "ambient-general", taskPrompt: "probe", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: [AvailableTools.readFile])
            let webBodies = agentRequests(serverB).map { String(decoding: $0.body, as: UTF8.self) }
            let responsesBodies = agentRequests(serverC).map { String(decoding: $0.body, as: UTF8.self) }
            let generalBody = serverA.requests.count >= 2 ? String(decoding: serverA.requests[1].body, as: UTF8.self) : ""
            var drained: [SubagentBackgroundRegistry.Completion] = []
            for _ in 0..<200 where drained.isEmpty {
                drained = await SubagentBackgroundRegistry.shared.drainCompletions()
                if drained.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            serverA.route = slowBase
            check("15.4 while a background subagent runs, research requests carry no [Ambient status] block on either transport; an ordinary subagent's request still does",
                  ambientWeb.error == nil && ambientResponses.error == nil && ambientGeneral.error == nil
                  && webBodies.count == 2 && webBodies.allSatisfy { !$0.contains("Ambient status") }
                  && responsesBodies.count == 2 && responsesBodies.allSatisfy { !$0.contains("Ambient status") }
                  && generalBody.contains("[Ambient status") && generalBody.contains("SLOW-BG") && drained.count == 1,
                  "web \(webBodies.count) responses \(responsesBodies.count) general has ambient: \(generalBody.contains("[Ambient status"))")

            // Compact packet shape.
            serverA.clear(); serverB.clear()
            fixtures.pages["https://example.test/tau"] = "# Tau\n\nTau facts."
            serverB.script([
                WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"tau\",\"tau facts\"]}")]),
                WebFixtureServer.chatBody("reading", calls: [("web_extract", "{\"requests\":[{\"url\":\"https://example.test/tau\",\"focus\":\"facts\"}]}")]),
                WebFixtureServer.chatBody("Tau is T. Sources: https://example.test/tau")])
            let packetRun = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "Web", description: "packet", taskPrompt: "About tau.", modelOverride: nil, runInBackground: false, deliverable: .short),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let packet = packetRun.asJSON()
            let packetJSON = resultJSON(packetRun)
            let packetLines = packet.components(separatedBy: "\n")
            check("15.5 compact packet: valid JSON, one key per line, queries_used compact on one line, sources_consulted one object per line, search_results_seen a count (hits across distinct queries), no inventory of unread URLs",
                  packetRun.error == nil && packetJSON["session_id"] as? String == packetRun.sessionId
                  && packetLines.contains("  \"queries_used\": [\"tau\",\"tau facts\"],")
                  && packetLines.contains("  \"sources_consulted\": [") && packetLines.contains { $0.hasPrefix("    {\"retrieved_at\":\"") && $0.contains("\"url\":\"https://example.test/tau\"}") }
                  && packetJSON["search_results_seen"] as? String == "4 results across 2 queries"
                  && (packetJSON["sources_consulted"] as? [[String: Any]])?.count == 1 && !packet.contains("example.test/tau-2")
                  && packet.utf8.count < 900, packet)
            let ordinaryPacket = SubagentRunner.RunResult(sessionId: "zzzzz", isNewSession: true, finalMessage: "done", turnsUsed: 1, toolsCalled: [], filesTouched: ["/tmp/x"], spendUSD: 0.5, error: nil, modelUsed: "m").asJSON()
            check("15.6 an ordinary run's result JSON keeps the legacy pretty-printed shape (no web keys, no compact renderer)",
                  ordinaryPacket.contains("\"session_id\"") && ordinaryPacket.contains("\n") && !ordinaryPacket.contains("search_results_seen") && !ordinaryPacket.contains("evidence_provenance"), ordinaryPacket)
            state.webFlag = false
            serverA.clear(); serverB.clear(); serverC.clear()
        }

        print("16. Codex R1b review (R1 emergency prompt, R2 queued resume cancellation, R3 session identity)")
        do {
            state.webFlag = true
            WebSearchBackend.processOverride = .opencode
            fixtures.serperMode = .normal
            let locks = SubagentSessionLocks.shared
            defer {
                SubagentRunner.stalenessTimeoutOverrideForTesting = nil
                SubagentRunner.nestedRunCeilingOverrideForTesting = nil
            }
            // ---- R1: a real emergency compaction of a Web run, on both transports, with a
            // profile sentinel stored and a background subagent running (ambient sentinel).
            try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: "PRIVATE-PROFILE-SENTINEL age 40 vegan")
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "60000")
            defer {
                try? KeychainHelper.delete(key: KeychainHelper.structuredUserContextKey)
                try? KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "250000")
            }
            serverA.clear(); serverB.clear(); serverC.clear()
            let bgBase = delayRoute(serverA, marker: "SLOW-BG", delay: 6)
            serverA.script([WebFixtureServer.chatBody("bg done")])
            _ = await SubagentBackgroundRegistry.shared.spawn(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "SLOW-BG job", taskPrompt: "SLOW-BG task", modelOverride: nil, runInBackground: true),
                sessionId: nil, parentTools: [AvailableTools.readFile], openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents)
            for _ in 0..<100 where serverA.requests.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
            let bigTask = "Research the emergency topic. " + String(repeating: "Relevant task context. ", count: 1000)
            serverB.script([
                WebFixtureServer.chatBody("searching", calls: [("web_query", "{\"queries\":[\"emergency topic\"]}")], prompt: 60000),
                WebFixtureServer.chatBody("Compact summary."),
                WebFixtureServer.chatBody("Finished. Sources: https://example.test/emergency-topic"), WebFixtureServer.chatBody("Finished. Sources: https://example.test/emergency-topic")])
            let emergencyChat = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "Web", description: "emergency-chat", taskPrompt: bigTask, modelOverride: nil, runInBackground: false, deliverable: .short),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let chatBodies = serverB.requests.map { String(decoding: $0.body, as: UTF8.self) }
            let chatEmergency = chatBodies.filter { $0.contains("[OVERSIZED BATCH SUMMARY") }
            check("16.1 R1 (Chat Completions): a real emergency compaction of a Web run — every oversized-batch summary request and every later research request carries the research identity, no user profile and no ambient block",
                  emergencyChat.error == nil && !chatEmergency.isEmpty
                  && chatBodies.allSatisfy { !$0.contains("PRIVATE-PROFILE-SENTINEL") && !$0.contains("Ambient status") && !$0.contains("Fixture User") }
                  && chatEmergency.allSatisfy { $0.contains("You are the web research subagent of Fixture Assistant.") },
                  "error \(emergencyChat.error ?? "nil") requests \(chatBodies.count) emergency \(chatEmergency.count) profile-leaks \(chatBodies.filter { $0.contains("PRIVATE-PROFILE-SENTINEL") }.count)")
            WebSearchBackend.processOverride = .openai
            serverC.script([
                WebFixtureServer.responsesBody("searching", id: "e1", calls: [("web_query", "{\"queries\":[\"emergency topic\"]}")], prompt: 60000),
                WebFixtureServer.responsesBody("Compact summary.", id: "e2"),
                WebFixtureServer.responsesBody("Finished. Sources: https://example.test/emergency-topic", id: "e3"), WebFixtureServer.responsesBody("Finished. Sources: https://example.test/emergency-topic", id: "e4")])
            let emergencyResponses = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "Web", description: "emergency-responses", taskPrompt: bigTask, modelOverride: nil, runInBackground: false, deliverable: .short),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            WebSearchBackend.processOverride = .opencode
            let responsesBodies = serverC.requests.map { String(decoding: $0.body, as: UTF8.self) }
            let responsesEmergency = responsesBodies.filter { $0.contains("[OVERSIZED BATCH SUMMARY") }
            check("16.2 R1 (Responses): the same on the native transport",
                  emergencyResponses.error == nil && !responsesEmergency.isEmpty
                  && responsesBodies.allSatisfy { !$0.contains("PRIVATE-PROFILE-SENTINEL") && !$0.contains("Ambient status") && !$0.contains("Fixture User") }
                  && responsesEmergency.allSatisfy { $0.contains("You are the web research subagent of Fixture Assistant.") },
                  "error \(emergencyResponses.error ?? "nil") requests \(responsesBodies.count) emergency \(responsesEmergency.count)")
            var bgDrained: [SubagentBackgroundRegistry.Completion] = []
            for _ in 0..<300 where bgDrained.isEmpty {
                bgDrained = await SubagentBackgroundRegistry.shared.drainCompletions()
                if bgDrained.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            serverA.route = bgBase
            try KeychainHelper.delete(key: KeychainHelper.structuredUserContextKey)
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "250000")

            // ---- R2: a nested resume queued behind the session's owner, cancelled while waiting.
            let (busySid, _) = await registry.create(subagentType: "Web", description: "busy-web", initialPrompt: "Original web task", webPool: true)
            _ = await locks.acquire(busySid)   // the owner: somebody else is running this session
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("delegate", calls: [agentCall(["subagent_type": "Web", "description": "queued", "prompt": "CANCELLED-CONTINUATION-MUST-NOT-APPEAR", "session_id": busySid])])])
            let queuedParent = Task {
                await SubagentRunner().run(
                    invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "cancel-queued", taskPrompt: "resume research", modelOverride: nil, runInBackground: false),
                    sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            }
            for _ in 0..<200 where await locks.waiterCount(busySid) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
            let queuedBefore = await locks.waiterCount(busySid)
            queuedParent.cancel()
            let queuedStart = Date()
            let stopped = await queuedParent.value
            let queuedLatency = Date().timeIntervalSince(queuedStart)
            let queuedAfterCancel = await locks.waiterCount(busySid)
            let ownerStillHeld = await locks.isHeld(busySid)
            // A successor queues behind the same owner, then the owner releases: the successor
            // (not the cancelled waiter) gets the lane and runs.
            serverB.script([WebFixtureServer.chatBody("Successor answer, from what I read."), WebFixtureServer.chatBody("Successor answer, from what I read.")])
            let successor = Task {
                await SubagentRunner().run(
                    invocation: SubagentRunner.Invocation(subagentType: "Web", description: "successor", taskPrompt: "SUCCESSOR-CONTINUATION", modelOverride: nil, runInBackground: false, deliverable: .short),
                    sessionId: busySid, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            }
            for _ in 0..<200 where await locks.waiterCount(busySid) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
            let sessionBeforeRelease = await registry.get(busySid)
            await locks.release(busySid)
            let successorRun = await successor.value
            try await Task.sleep(nanoseconds: 300_000_000)
            let sessionAfter = await registry.get(busySid)
            let busyHeldAfter = await locks.isHeld(busySid)
            let busyQueueAfter = await locks.waiterCount(busySid)
            let busyFree = !busyHeldAfter && busyQueueAfter == 0
            check("16.3 R2: a nested Web resume queued behind the session owner and cancelled while waiting returns 'Subagent cancelled' at once, leaves the queue, never touches the session; the owner keeps the lane; a successor waiter gets the handoff and its continuation is the only new message",
                  queuedBefore == 1 && stopped.error == "Subagent cancelled" && queuedLatency < 1.0 && queuedAfterCancel == 0 && ownerStillHeld
                  && sessionBeforeRelease?.messages.count == 1 && successorRun.error == nil && successorRun.sessionId == busySid
                  && sessionAfter?.messages.count == 2 && sessionAfter?.messages.contains { $0.content.contains("SUCCESSOR-CONTINUATION") } == true
                  && sessionAfter?.messages.contains { $0.content.contains("CANCELLED-CONTINUATION-MUST-NOT-APPEAR") } == false && busyFree,
                  "queued \(queuedBefore)/\(queuedAfterCancel) error \(stopped.error ?? "nil") latency \(queuedLatency) msgs \(sessionBeforeRelease?.messages.count ?? -1)→\(sessionAfter?.messages.count ?? -1) successor \(successorRun.error ?? "ok")")
            // The parent's own batch timer cancels the same queued waiter.
            SubagentRunner.stalenessTimeoutOverrideForTesting = 1.0
            SubagentRunner.nestedRunCeilingOverrideForTesting = 10
            _ = await locks.acquire(busySid)
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("delegate", calls: [agentCall(["subagent_type": "Web", "description": "queued-timeout", "prompt": "TIMED-OUT-CONTINUATION-MUST-NOT-APPEAR", "session_id": busySid])])])
            let timedOutStart = Date()
            let timedOut = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "timeout-queued", taskPrompt: "resume research", modelOverride: nil, runInBackground: false),
                sessionId: nil, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let timedOutElapsed = Date().timeIntervalSince(timedOutStart)
            let timedOutQueue = await locks.waiterCount(busySid)
            await locks.release(busySid)
            try await Task.sleep(nanoseconds: 300_000_000)
            let sessionAfterTimeout = await registry.get(busySid)
            SubagentRunner.stalenessTimeoutOverrideForTesting = nil
            SubagentRunner.nestedRunCeilingOverrideForTesting = nil
            let busyHeldAfterTimeout = await locks.isHeld(busySid)
            check("16.4 R2: the parent's staleness timer (1.0 s) cancels a nested resume still queued behind a busy owner: the parent reports staleness at ~1 s, the waiter leaves the queue, the session is unchanged after the owner releases, the lane ends free",
                  timedOut.error?.hasPrefix("Subagent killed: no progress") == true && timedOutElapsed >= 0.9 && timedOutElapsed < 3.0 && timedOutQueue == 0
                  && sessionAfterTimeout?.messages.count == 2 && sessionAfterTimeout?.messages.contains { $0.content.contains("TIMED-OUT-CONTINUATION") } == false
                  && !busyHeldAfterTimeout,
                  "error \(timedOut.error ?? "nil") elapsed \(timedOutElapsed) queue \(timedOutQueue) msgs \(sessionAfterTimeout?.messages.count ?? -1)")

            // ---- R3: session identity — a nested Web call may resume only Web-pool sessions.
            let (ordinarySid, _) = await registry.create(subagentType: "general-purpose", description: "ordinary-private", initialPrompt: "ORDINARY-HISTORY-PRIVATE-SENTINEL")
            let (customWebSid, _) = await registry.create(subagentType: "Web", description: "custom web (ordinary)", initialPrompt: "CUSTOM-WEB-HISTORY-SENTINEL", webPool: false)
            serverA.clear(); serverB.clear()
            serverB.script([WebFixtureServer.chatBody("Read history"), WebFixtureServer.chatBody("Read history")])
            let depth1 = await mainExecutor.makeChildExecutor()
            let ordinaryResume = await depth1.executeAgentToolResult(ToolCall(id: "k1", type: "function", function: FunctionCall(name: "Agent", arguments: agentCall(["subagent_type": "Web", "description": "resume research", "prompt": "Continue", "session_id": ordinarySid]).1)))
            let customResume = await depth1.executeAgentToolResult(ToolCall(id: "k2", type: "function", function: FunctionCall(name: "Agent", arguments: agentCall(["subagent_type": "Web", "description": "resume research", "prompt": "Continue", "session_id": customWebSid]).1)))
            let ordinaryAfter = await registry.get(ordinarySid), customAfter = await registry.get(customWebSid)
            let leaked = serverB.requests.contains { String(decoding: $0.body, as: UTF8.self).contains("SENTINEL") }
            let ordinaryHeld = await locks.isHeld(ordinarySid), customHeld = await locks.isHeld(customWebSid)
            check("16.5 R3: a nested Web call naming an ordinary session, or a general-pool session that merely carries the name Web, is refused before any history is appended or a provider contacted",
                  ordinaryResume.content.contains("belongs to an ordinary subagent (general-purpose)") && customResume.content.contains("belongs to an ordinary subagent (Web)")
                  && serverB.requests.isEmpty && !leaked && ordinaryAfter?.messages.count == 1 && customAfter?.messages.count == 1
                  && !ordinaryHeld && !customHeld,
                  ordinaryResume.content + " | " + customResume.content)
            // A resumed parent naming its OWN session: refused at once, no wait on the lane the parent holds.
            let (parentSid, _) = await registry.create(subagentType: "general-purpose", description: "self-resume parent", initialPrompt: "first run")
            serverA.clear(); serverB.clear()
            serverA.script([WebFixtureServer.chatBody("delegate to myself", calls: [agentCall(["subagent_type": "Web", "description": "self", "prompt": "Continue", "session_id": parentSid])]), WebFixtureServer.chatBody("parent finished")])
            let selfStart = Date()
            let selfResume = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "self-resume", taskPrompt: "second run", modelOverride: nil, runInBackground: false),
                sessionId: parentSid, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let selfElapsed = Date().timeIntervalSince(selfStart)
            let selfResults = (await registry.get(parentSid))?.toolInteractions.last?.results.map(\.content) ?? []
            check("16.6 R3: a resumed parent whose nested call names the parent's own session gets the refusal in its tool result immediately (no wait on the lane it holds) and finishes",
                  selfResume.error == nil && selfResume.finalMessage == "parent finished" && selfElapsed < 3.0 && selfResults.first?.contains("belongs to an ordinary subagent") == true && serverB.requests.isEmpty,
                  "error \(selfResume.error ?? "nil") elapsed \(selfElapsed) \(selfResults.first ?? "")")
            // Valid reuse from depth 0 (the main agent) and the reverse mismatch.
            let (webSid, _) = await registry.create(subagentType: "Web", description: "valid web", initialPrompt: "web task", webPool: true)
            serverA.clear(); serverB.clear()
            serverB.script([WebFixtureServer.chatBody("Still valid."), WebFixtureServer.chatBody("Still valid.")])
            let validResume = await mainExecutor.executeAgentToolResult(ToolCall(id: "k3", type: "function", function: FunctionCall(name: "Agent", arguments: agentCall(["subagent_type": "Web", "description": "valid", "prompt": "Continue", "session_id": webSid, "deliverable": "short"]).1)))
            let validJSON = (try? JSONSerialization.jsonObject(with: Data(validResume.content.utf8)) as? [String: Any]) ?? [:]
            serverA.script([WebFixtureServer.chatBody("ordinary on web")])
            let reverse = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "reverse", taskPrompt: "Continue", modelOverride: nil, runInBackground: false),
                sessionId: webSid, openRouterService: service, toolExecutor: await mainExecutor.makeChildExecutor(), imagesDirectory: images, documentsDirectory: documents, parentTools: all)
            let webSessionAfter = await registry.get(webSid)
            check("16.7 R3: a valid Web session is still resumed by the main agent (depth 0); the reverse — an ordinary type resuming a Web session — is refused without touching it",
                  validJSON["session_id"] as? String == webSid && validJSON["is_new_session"] as? Bool == false && validJSON["error"] == nil
                  && reverse.error?.contains("is a Web research session; it can only be resumed with subagent_type=Web") == true && serverA.requests.isEmpty
                  && webSessionAfter?.messages.count == 2,
                  "valid \(validJSON["error"] as? String ?? "ok") reverse \(reverse.error ?? "nil")")
            state.webFlag = false
            serverA.clear(); serverB.clear(); serverC.clear()
        }
    }
}
