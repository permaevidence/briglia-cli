import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Group 24 (WEB_OFFLINE_HANG, 2026-10-18): the Web researcher's own model
// rounds have a per-round deadline. Reproduces the Thread v5 trial hang: the
// researcher's round-2 request (after a web_query) is accepted by the
// endpoint but never answered (`silentFor`). Before the fix the run waited on
// the transport's idle clock (360 s hosted / 1200 s custom) and up to three
// adapter retries; every row below has its own short watchdog, so the old
// code fails them instead of hanging the selftest. Own file (Linux CI
// frontend memory).
extension WebSubagentSelftest {
    /// Research rounds on the main endpoint whose body carries a tool result
    /// (round ≥ 2) are held silent: the first `stalls` of them, after `skip`.
    final class RoundStallPlan: @unchecked Sendable {
        private let lock = NSLock()
        private var skip: Int, stalls: Int
        private(set) var stalled = 0
        let silentFor: TimeInterval
        init(skip: Int = 0, stalls: Int, silentFor: TimeInterval = 8) { self.skip = skip; self.stalls = stalls; self.silentFor = silentFor }
        func shouldStall() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if skip > 0 { skip -= 1; return false }
            guard stalls > 0 else { return false }
            stalls -= 1; stalled += 1; return true
        }
    }

    /// `op` or nil when `seconds` pass first (the row's own watchdog).
    static func withinSeconds<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async -> T) async -> (value: T?, elapsed: TimeInterval) {
        let start = Date()
        let value: T? = await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return (value, Date().timeIntervalSince(start))
    }

    static func runRoundDeadlineGroup(_ h: Harness) async throws {
        print("24. Web researcher model-round deadline (offline hang)")
        let state = h.state, fixtures = h.fixtures, images = h.images, documents = h.documents, service = h.service
        let serverA = h.serverA, serverB = h.serverB
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        let marker = "You are the web research subagent"
        func isResearch(_ r: WebFixtureServer.Request) -> Bool { String(decoding: r.body, as: UTF8.self).contains(marker) }
        func hasToolResult(_ r: WebFixtureServer.Request) -> Bool {
            guard let messages = h.body(r)["messages"] as? [[String: Any]] else { return false }
            return messages.contains { $0["role"] as? String == "tool" }
        }
        let routeA = serverA.route, routeB = serverB.route
        let savedOverride = WebSearchBackend.processOverride
        defer {
            serverA.route = routeA; serverB.route = routeB; serverA.divert = nil
            WebRoundDeadline.overrideForTesting = nil
            WebSearchBackend.processOverride = savedOverride
            fixtures.serperMode = .normal
        }
        func installStall(_ server: WebFixtureServer, base: (@Sendable (WebFixtureServer.Request) -> WebFixtureServer.Response)?, _ plan: RoundStallPlan) {
            server.route = { request in
                var response = base?(request) ?? .init(status: 500, body: "{}")  // pops the script first
                if isResearch(request), hasToolResult(request), plan.shouldStall() { response.silentFor = plan.silentFor }
                return response
            }
        }
        state.webFlag = true
        WebSearchBackend.processOverride = .opencode
        fixtures.serperMode = .normal
        let webQuery = ("web_query", "{\"queries\":[\"theta\"]}")
        func webInvocation(_ prompt: String) -> SubagentRunner.Invocation {
            SubagentRunner.Invocation(subagentType: "Web", description: "round deadline", taskPrompt: prompt,
                                      modelOverride: nil, runInBackground: false, deliverable: .short)
        }
        func directRun(_ prompt: String) async -> SubagentRunner.RunResult {
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            await executor.configureOpenRouter(service, imagesDirectory: images, documentsDirectory: documents)
            return await SubagentRunner().run(invocation: webInvocation(prompt), sessionId: nil, openRouterService: service,
                toolExecutor: executor, imagesDirectory: images, documentsDirectory: documents,
                parentTools: AvailableTools.all(includeWebSearch: true))
        }

        // 24.1 The trial hang: round 2 is never answered, twice.
        do {
            WebRoundDeadline.overrideForTesting = 1
            serverA.clear()
            let plan = RoundStallPlan(stalls: 2)
            installStall(serverA, base: routeA, plan)
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery]),
                            WebFixtureServer.chatBody("never delivered 1"), WebFixtureServer.chatBody("never delivered 2")])
            let outcome = await withinSeconds(6) { await directRun("HANG-1 What is theta?") }
            let research = serverA.requests.filter(isResearch)
            let error = outcome.value?.error ?? ""
            check("24.1 a Web round whose request is never answered ends the run with web_model_timeout after the round deadline, one identical retry and a second expiry; nothing waits for the transport's 360/1200 s clock (row watchdog 6 s)",
                  outcome.value != nil && error.hasPrefix("web_model_timeout:") && outcome.elapsed < 6
                  && research.count == 3 && plan.stalled == 2 && research[1].body == research[2].body
                  && outcome.value?.toolsCalled == ["web_query"],
                  "value \(outcome.value == nil ? "nil (hung)" : "set") error '\(error)' elapsed \(String(format: "%.1f", outcome.elapsed)) requests \(research.count)")
            check("24.2 the timed-out run is still committed and resumable (session persisted, web evidence of round 1 kept)",
                  outcome.value?.sessionPersisted == true && !(outcome.value?.sessionId ?? "").isEmpty,
                  outcome.value?.sessionId ?? "no result")
        }

        // 24.3 A transient stall: the retry is answered and the run completes.
        do {
            WebRoundDeadline.overrideForTesting = 1
            serverA.clear()
            let plan = RoundStallPlan(stalls: 1)
            installStall(serverA, base: routeA, plan)
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery]),
                            WebFixtureServer.chatBody("never delivered"),
                            WebFixtureServer.chatBody("Theta is T. Sources: https://example.test/theta")])
            let outcome = await withinSeconds(6) { await directRun("HANG-2 What is theta?") }
            let research = serverA.requests.filter(isResearch)
            check("24.3 one stalled round is cancelled and sent again once; the answered retry completes the run normally (no error, final text, three research requests)",
                  outcome.value?.error == nil && outcome.value?.finalMessage.contains("Theta is T.") == true
                  && research.count == 3 && plan.stalled == 1 && outcome.elapsed < 6,
                  "error \(outcome.value?.error ?? "none") elapsed \(String(format: "%.1f", outcome.elapsed))")
        }

        // 24.4 A slow but answered round inside the deadline is never cut.
        do {
            WebRoundDeadline.overrideForTesting = 3
            serverA.clear()
            let plan = RoundStallPlan(stalls: 1, silentFor: 1)
            installStall(serverA, base: routeA, plan)
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery]),
                            WebFixtureServer.chatBody("Theta, slowly. Sources: https://example.test/theta")])
            let outcome = await withinSeconds(8) { await directRun("SLOW What is theta?") }
            check("24.4 a round answered after 1 s under a 3 s deadline is kept: no retry, no error",
                  outcome.value?.error == nil && outcome.value?.finalMessage.contains("Theta, slowly.") == true
                  && serverA.requests.filter(isResearch).count == 2,
                  outcome.value?.error ?? "ok")
        }

        // 24.5 The deadline applies only to the Web researcher.
        do {
            WebRoundDeadline.overrideForTesting = 0.5
            serverA.clear()
            serverA.route = { request in
                var response = routeA?(request) ?? .init(status: 500, body: "{}")
                if String(decoding: request.body, as: UTF8.self).contains("GENERAL-SLOW") { response.silentFor = 1.5 }
                return response
            }
            serverA.script([WebFixtureServer.chatBody("General done.")])
            let outcome = await withinSeconds(8) { () -> SubagentRunner.RunResult in
                let executor = ToolExecutor(outputMode: .subagent)
                await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
                return await SubagentRunner().run(
                    invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "g", taskPrompt: "GENERAL-SLOW hello",
                                                          modelOverride: nil, runInBackground: false),
                    sessionId: nil, openRouterService: service, toolExecutor: executor, imagesDirectory: images,
                    documentsDirectory: documents, parentTools: [AvailableTools.readFile])
            }
            check("24.5 a general-purpose subagent round slower than the Web deadline is unaffected (no deadline outside the Web researcher)",
                  outcome.value?.error == nil && outcome.value?.finalMessage == "General done." && serverA.requests.count == 1,
                  outcome.value?.error ?? "ok")
            serverA.route = routeA
        }

        // 24.6 Caller cancellation during a stalled round returns at once.
        do {
            WebRoundDeadline.overrideForTesting = 60
            serverA.clear()
            let plan = RoundStallPlan(stalls: 1, silentFor: 8)
            installStall(serverA, base: routeA, plan)
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery]), WebFixtureServer.chatBody("never")])
            let task = Task { await directRun("CANCEL What is theta?") }
            let deadline = Date().addingTimeInterval(5)
            while plan.stalled == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            try await Task.sleep(nanoseconds: 200_000_000)
            let start = Date()
            task.cancel()
            let outcome = await withinSeconds(4) { await task.value }
            check("24.6 /stop (task cancellation) during a stalled Web round returns promptly as \"Subagent cancelled\", without waiting for the 60 s round deadline",
                  plan.stalled == 1 && outcome.value?.error == "Subagent cancelled" && Date().timeIntervalSince(start) < 3,
                  "error \(outcome.value?.error ?? "nil (hung)")")
        }

        // 24.7 The benchmark paths: Agent(Web) nested in a general subagent.
        do {
            WebRoundDeadline.overrideForTesting = 1
            serverA.clear(); serverB.clear()
            serverA.divert = { request in isResearch(request) ? serverB : nil }
            let plan = RoundStallPlan(stalls: 2)
            installStall(serverB, base: routeB, plan)
            let agentArgs = String(decoding: try JSONSerialization.data(withJSONObject: [
                "subagent_type": "Web", "description": "nested hang", "prompt": "NESTED-HANG What is theta?", "deliverable": "short"], options: [.sortedKeys]), as: UTF8.self)
            serverA.script([WebFixtureServer.chatBody("delegating", calls: [("Agent", agentArgs)]),
                            WebFixtureServer.chatBody("Parent: research timed out, reported.")])
            serverB.script([WebFixtureServer.chatBody("searching", calls: [webQuery]),
                            WebFixtureServer.chatBody("never 1"), WebFixtureServer.chatBody("never 2")])
            let mainExecutor = ToolExecutor(outputMode: .mainAgent)
            await mainExecutor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            await mainExecutor.configureOpenRouter(service, imagesDirectory: images, documentsDirectory: documents)
            let depth1 = await mainExecutor.makeChildExecutor()
            let outcome = await withinSeconds(8) {
                await SubagentRunner().run(
                    invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "parent", taskPrompt: "Find out about theta.",
                                                          modelOverride: nil, runInBackground: false),
                    sessionId: nil, openRouterService: service, toolExecutor: depth1, imagesDirectory: images,
                    documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            }
            let parentSession = await SubagentSessionRegistry.shared.get(outcome.value?.sessionId ?? "")
            let childContent = parentSession?.toolInteractions.last?.results.first?.content ?? ""
            let childJSON = (try? JSONSerialization.jsonObject(with: Data(childContent.utf8)) as? [String: Any]) ?? [:]
            check("24.7 subagent.Agent(Web): a nested researcher whose rounds stall returns web_model_timeout to its parent as a tool result, and the parent finishes its turn (row watchdog 8 s)",
                  outcome.value?.error == nil && outcome.value?.finalMessage == "Parent: research timed out, reported."
                  && (childJSON["error"] as? String)?.hasPrefix("web_model_timeout:") == true && plan.stalled == 2,
                  "value \(outcome.value == nil ? "nil (hung)" : "set") child \(childContent.prefix(300))")
            serverA.divert = nil
        }

        // 24.8 Deadline policy.
        check("24.8 policy: hosted 180 s, local 1200 s, two expiries per run; loopback, private-LAN, CGNAT and mDNS hosts count as local, public API hosts do not",
              WebRoundDeadline.hostedSeconds == 180 && WebRoundDeadline.localSeconds == 1200 && WebRoundDeadline.maxTimeoutsPerRun == 2
              && WebRoundDeadline.isLocalHost("http://127.0.0.1:1234/v1") && WebRoundDeadline.isLocalHost("http://192.168.1.20:8080/v1")
              && WebRoundDeadline.isLocalHost("http://10.0.0.5/v1") && WebRoundDeadline.isLocalHost("http://172.20.1.1/v1")
              && WebRoundDeadline.isLocalHost("http://100.101.1.2/v1") && WebRoundDeadline.isLocalHost("http://gpu-box.local:8000/v1")
              && WebRoundDeadline.isLocalHost("http://localhost:11434/v1")
              && !WebRoundDeadline.isLocalHost("https://api.openai.com/v1") && !WebRoundDeadline.isLocalHost("https://opencode.ai/zen/go/v1")
              && !WebRoundDeadline.isLocalHost("https://openrouter.ai/api/v1") && !WebRoundDeadline.isLocalHost("https://172.32.0.1/v1"))
        serverA.clear(); serverB.clear()
    }
}
