import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Group 24 (WEB_OFFLINE_HANG, owner decision 2026-10-18): the Web
// researcher's model rounds retry a SILENCE timeout once, then stop the run
// with web_model_timeout. Transport timing is 0.2.55's; only the silence
// retry count changes, only for the researcher. The adapters' 360/1200 s
// request timeout is scaled by the dev seam
// (ModelSilenceTimeout.requestTimeoutOverrideForTesting) so a silence timeout
// takes about a second. Reproduces the Thread v5 trial hang: round 2 (after
// a web_query) is accepted but never answered (`silentFor`). Every row has
// its own watchdog, so old wiring fails instead of hanging. Own file (Linux
// CI frontend memory).
extension WebSubagentSelftest {
    /// Matching requests are held silent: the first `stalls` of them, after `skip`.
    final class SilencePlan: @unchecked Sendable {
        private let lock = NSLock()
        private var skip: Int, stalls: Int
        private(set) var stalled = 0
        let silentFor: TimeInterval
        init(skip: Int = 0, stalls: Int, silentFor: TimeInterval = 4) { self.skip = skip; self.stalls = stalls; self.silentFor = silentFor }
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

    static func runSilenceTimeoutGroup(_ h: Harness) async throws {
        print("24. Web researcher silence-timeout retry limit (offline hang)")
        let state = h.state, fixtures = h.fixtures, images = h.images, documents = h.documents, service = h.service
        let serverA = h.serverA, serverB = h.serverB, serverC = h.serverC, serverD = h.serverD
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        let marker = "You are the web research subagent"
        func text(_ r: WebFixtureServer.Request) -> String { String(decoding: r.body, as: UTF8.self) }
        func isResearch(_ r: WebFixtureServer.Request) -> Bool { text(r).contains(marker) }
        /// Round ≥ 2 of a research run: chat `tool` message or Responses
        /// `function_call_output` item.
        func hasToolResult(_ r: WebFixtureServer.Request) -> Bool {
            if let messages = h.body(r)["messages"] as? [[String: Any]], messages.contains(where: { $0["role"] as? String == "tool" }) { return true }
            if let input = h.body(r)["input"] as? [[String: Any]], input.contains(where: { $0["type"] as? String == "function_call_output" }) { return true }
            return false
        }
        func isResearchRound2(_ r: WebFixtureServer.Request) -> Bool { isResearch(r) && hasToolResult(r) }
        let routeA = serverA.route, routeB = serverB.route, routeC = serverC.route, routeD = serverD.route
        let savedOverride = WebSearchBackend.processOverride
        let savedHooks = OpenRouterService.chatRetryTestHooks
        defer {
            serverA.route = routeA; serverB.route = routeB; serverC.route = routeC; serverD.route = routeD; serverA.divert = nil
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = nil
            OpenRouterService.chatRetryTestHooks = savedHooks
            WebSearchBackend.processOverride = savedOverride
            fixtures.serperMode = .normal
        }
        /// `base` runs first (pops the status / script queue), then a
        /// matching request may be held silent.
        func installSilence(_ server: WebFixtureServer, base: (@Sendable (WebFixtureServer.Request) -> WebFixtureServer.Response)?,
                            _ plan: SilencePlan, match: @escaping @Sendable (WebFixtureServer.Request) -> Bool) {
            server.route = { request in
                var response = base?(request) ?? .init(status: 500, body: "{}")
                if match(request), plan.shouldStall() { response.silentFor = plan.silentFor }
                return response
            }
        }
        state.webFlag = true
        WebSearchBackend.processOverride = .opencode
        fixtures.serperMode = .normal
        // Chat transport backoff (1–4 s) scaled; the silence clock itself is
        // the scaled request timeout below.
        OpenRouterService.chatRetryTestHooks.sleepScale = 0.02
        let silence: TimeInterval = 1
        let webQuery = ("web_query", "{\"queries\":[\"theta\"]}")
        func webInvocation(_ prompt: String) -> SubagentRunner.Invocation {
            SubagentRunner.Invocation(subagentType: "Web", description: "silence timeout", taskPrompt: prompt,
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
        func secs(_ t: TimeInterval) -> String { String(format: "%.1f", t) }

        // 24.1 The trial hang (chat completions): round 2 is never answered.
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = silence
            serverA.clear()
            let plan = SilencePlan(stalls: 6)
            installSilence(serverA, base: routeA, plan, match: isResearchRound2)
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery])]
                           + (1...6).map { WebFixtureServer.chatBody("never delivered \($0)") })
            let outcome = await withinSeconds(10) { await directRun("HANG-1 What is theta?") }
            let research = serverA.requests.filter(isResearch)
            let error = outcome.value?.error ?? ""
            check("24.1 a Web round whose request is never answered: one silence timeout, one identical retry, a second silence timeout, then web_model_timeout (2 attempts, not 0.2.55's 4)",
                  outcome.value != nil && error.hasPrefix("web_model_timeout:") && research.count == 3 && plan.stalled == 2
                  && research[1].body == research[2].body && outcome.value?.toolsCalled == ["web_query"],
                  "value \(outcome.value == nil ? "nil (hung)" : "set") error '\(error)' elapsed \(secs(outcome.elapsed)) research requests \(research.count) stalled \(plan.stalled)")
            check("24.2 the timed-out run is still committed and resumable (session persisted)",
                  outcome.value?.sessionPersisted == true && !(outcome.value?.sessionId ?? "").isEmpty,
                  outcome.value?.sessionId ?? "no result")
        }

        // 24.3 A transient silence: the retry is answered and the run completes.
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = silence
            serverA.clear()
            let plan = SilencePlan(stalls: 1)
            installSilence(serverA, base: routeA, plan, match: isResearchRound2)
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery]),
                            WebFixtureServer.chatBody("never delivered"),
                            WebFixtureServer.chatBody("Theta is T. Sources: https://example.test/theta")])
            let outcome = await withinSeconds(10) { await directRun("HANG-2 What is theta?") }
            let research = serverA.requests.filter(isResearch)
            check("24.3 one silent attempt is retried once; the answered retry completes the run normally (no error, final text, three research requests)",
                  outcome.value?.error == nil && outcome.value?.finalMessage.contains("Theta is T.") == true
                  && research.count == 3 && plan.stalled == 1,
                  "error \(outcome.value?.error ?? "none") elapsed \(secs(outcome.elapsed)) research \(research.count)")
        }

        // 24.4 Slow but streaming: keepalive bytes for 2.6 s (2.6× the scaled
        // silence clock, 5.2× the withdrawn 180 s-equivalent deadline).
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = silence
            serverA.clear()
            serverA.route = { request in
                var response = routeA?(request) ?? .init(status: 500, body: "{}")
                if isResearchRound2(request) { response.trickle = (interval: 0.25, duration: 2.6) }
                return response
            }
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery]),
                            WebFixtureServer.chatBody("Theta, slowly. Sources: https://example.test/theta")])
            let outcome = await withinSeconds(10) { await directRun("SLOW What is theta?") }
            let research = serverA.requests.filter(isResearch)
            check("24.4 a researcher round that keeps sending bytes for 2.6 s (silence clock 1 s, old 180 s-equivalent 0.5 s) is never cut: no retry, no error, answer kept",
                  outcome.value?.error == nil && outcome.value?.finalMessage.contains("Theta, slowly.") == true
                  && research.count == 2 && outcome.elapsed >= 2.5,
                  "error \(outcome.value?.error ?? "none") elapsed \(secs(outcome.elapsed)) research \(research.count)")
            serverA.route = routeA
        }

        // 24.5 Non-timeout retries unchanged: three 503s, then the answer.
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = silence
            serverA.clear()
            serverA.route = routeA
            serverA.scriptStatuses([200, 503, 503, 503])
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery]),
                            WebFixtureServer.chatBody("Theta after 503s. Sources: https://example.test/theta")])
            let ok = await withinSeconds(10) { await directRun("R503 What is theta?") }
            let okResearch = serverA.requests.filter(isResearch)
            serverA.clear()
            serverA.scriptStatuses([200, 503, 503, 503, 503])
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery]), WebFixtureServer.chatBody("unreached")])
            let failed = await withinSeconds(10) { await directRun("R503X What is theta?") }
            let failedResearch = serverA.requests.filter(isResearch)
            check("24.5 non-timeout retries are 0.2.55's: three HTTP 503s are retried and the 4th attempt answers (5 requests); four 503s end after 4 attempts with the ordinary 'Subagent error' (not web_model_timeout)",
                  ok.value?.error == nil && ok.value?.finalMessage.contains("Theta after 503s.") == true && okResearch.count == 5
                  && failedResearch.count == 5 && (failed.value?.error ?? "").hasPrefix("Subagent error:") && (failed.value?.error ?? "").contains("503"),
                  "ok \(ok.value?.error ?? "none")/\(okResearch.count) failed '\(failed.value?.error ?? "nil")'/\(failedResearch.count)")
        }

        // 24.6 Only silence timeouts are counted: 503, silence, 503, answer.
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = silence
            serverA.clear()
            let plan = SilencePlan(skip: 1, stalls: 1)  // round-2 attempt 1 is the 503
            installSilence(serverA, base: routeA, plan, match: isResearchRound2)
            serverA.scriptStatuses([200, 503, 200, 503])
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery]),
                            WebFixtureServer.chatBody("never delivered"),
                            WebFixtureServer.chatBody("Theta, mixed. Sources: https://example.test/theta")])
            let outcome = await withinSeconds(10) { await directRun("MIXED What is theta?") }
            let research = serverA.requests.filter(isResearch)
            check("24.6 mixed failures on one researcher request (503, silence, 503) keep the standard schedule; the single silence uses the one silence retry and the 4th attempt answers",
                  outcome.value?.error == nil && outcome.value?.finalMessage.contains("Theta, mixed.") == true
                  && research.count == 5 && plan.stalled == 1,
                  "error \(outcome.value?.error ?? "none") research \(research.count) stalled \(plan.stalled)")
        }

        // 24.7 Other subagents keep 0.2.55's silence retries.
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = silence
            serverA.clear()
            let plan = SilencePlan(stalls: 2)
            installSilence(serverA, base: routeA, plan, match: { text($0).contains("GENERAL-SILENCE") })
            serverA.script([WebFixtureServer.chatBody("lost 1"), WebFixtureServer.chatBody("lost 2"), WebFixtureServer.chatBody("General done.")])
            let outcome = await withinSeconds(10) { () -> SubagentRunner.RunResult in
                let executor = ToolExecutor(outputMode: .subagent)
                await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
                return await SubagentRunner().run(
                    invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "g", taskPrompt: "GENERAL-SILENCE hello",
                                                          modelOverride: nil, runInBackground: false),
                    sessionId: nil, openRouterService: service, toolExecutor: executor, imagesDirectory: images,
                    documentsDirectory: documents, parentTools: [AvailableTools.readFile])
            }
            check("24.7 a general-purpose subagent request silent twice is retried as in 0.2.55 and the 3rd attempt answers (no limit outside the Web researcher)",
                  outcome.value?.error == nil && outcome.value?.finalMessage == "General done." && serverA.requests.count == 3 && plan.stalled == 2,
                  "error \(outcome.value?.error ?? "none") requests \(serverA.requests.count)")
        }

        // 24.8 The main agent keeps 0.2.55's silence retries.
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = silence
            serverA.clear()
            let plan = SilencePlan(stalls: 3)
            installSilence(serverA, base: routeA, plan, match: { text($0).contains("MAIN-SILENCE") })
            serverA.script([WebFixtureServer.chatBody("lost 1"), WebFixtureServer.chatBody("lost 2"), WebFixtureServer.chatBody("lost 3"),
                            WebFixtureServer.chatBody("Main done.")])
            let outcome = await withinSeconds(12) { () -> String in
                do {
                    let response = try await service.generateResponse(
                        messages: [Message(role: .user, content: "MAIN-SILENCE hello", timestamp: state.clock)],
                        imagesDirectory: images, documentsDirectory: documents, lane: .main)
                    if case .text(let t, _, _, _, _, _, _, _) = response { return t }
                    return "other"
                } catch { return "error: \(error.localizedDescription)" }
            }
            check("24.8 a main-agent request silent three times is retried as in 0.2.55 and the 4th attempt answers",
                  outcome.value == "Main done." && serverA.requests.count == 4 && plan.stalled == 3,
                  "value \(outcome.value ?? "nil (hung)") requests \(serverA.requests.count)")
        }

        // 24.9 /stop during a silent researcher round returns at once (0.2.55).
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = 60
            serverA.clear()
            let plan = SilencePlan(stalls: 1, silentFor: 8)
            installSilence(serverA, base: routeA, plan, match: isResearchRound2)
            serverA.script([WebFixtureServer.chatBody("searching", calls: [webQuery]), WebFixtureServer.chatBody("never")])
            let task = Task { await directRun("CANCEL What is theta?") }
            let deadline = Date().addingTimeInterval(5)
            while plan.stalled == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            try await Task.sleep(nanoseconds: 200_000_000)
            let start = Date()
            task.cancel()
            let outcome = await withinSeconds(4) { await task.value }
            check("24.9 /stop (task cancellation) during a silent Web round returns promptly as \"Subagent cancelled\" (60 s silence clock not waited)",
                  plan.stalled == 1 && outcome.value?.error == "Subagent cancelled" && Date().timeIntervalSince(start) < 3,
                  "error \(outcome.value?.error ?? "nil (hung)")")
        }

        // 24.10 The benchmark path: Agent(Web) nested in a general subagent.
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = silence
            serverA.clear(); serverB.clear()
            serverA.route = routeA
            serverA.divert = { request in isResearch(request) ? serverB : nil }
            let plan = SilencePlan(stalls: 6)
            installSilence(serverB, base: routeB, plan, match: isResearchRound2)
            let agentArgs = String(decoding: try JSONSerialization.data(withJSONObject: [
                "subagent_type": "Web", "description": "nested hang", "prompt": "NESTED-HANG What is theta?", "deliverable": "short"], options: [.sortedKeys]), as: UTF8.self)
            serverA.script([WebFixtureServer.chatBody("delegating", calls: [("Agent", agentArgs)]),
                            WebFixtureServer.chatBody("Parent: research timed out, reported.")])
            serverB.script([WebFixtureServer.chatBody("searching", calls: [webQuery])] + (1...6).map { WebFixtureServer.chatBody("never \($0)") })
            let mainExecutor = ToolExecutor(outputMode: .mainAgent)
            await mainExecutor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            await mainExecutor.configureOpenRouter(service, imagesDirectory: images, documentsDirectory: documents)
            let depth1 = await mainExecutor.makeChildExecutor()
            let outcome = await withinSeconds(12) {
                await SubagentRunner().run(
                    invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "parent", taskPrompt: "Find out about theta.",
                                                          modelOverride: nil, runInBackground: false),
                    sessionId: nil, openRouterService: service, toolExecutor: depth1, imagesDirectory: images,
                    documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
            }
            let parentSession = await SubagentSessionRegistry.shared.get(outcome.value?.sessionId ?? "")
            let childContent = parentSession?.toolInteractions.last?.results.first?.content ?? ""
            let childJSON = (try? JSONSerialization.jsonObject(with: Data(childContent.utf8)) as? [String: Any]) ?? [:]
            check("24.10 subagent.Agent(Web): a nested researcher whose round 2 is silent returns web_model_timeout to its parent as a tool result after 2 attempts, and the parent finishes its turn",
                  outcome.value?.error == nil && outcome.value?.finalMessage == "Parent: research timed out, reported."
                  && (childJSON["error"] as? String)?.hasPrefix("web_model_timeout:") == true && plan.stalled == 2,
                  "value \(outcome.value == nil ? "nil (hung)" : "set") stalled \(plan.stalled) child \(childContent.prefix(300))")
            serverA.divert = nil
        }

        // 24.11 Responses protocol (the benchmark's OpenAI path): same limit.
        // A custom endpoint has connect = idle = overall clocks (1200 s in
        // production, scaled here), so whichever fires first must count.
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = silence
            serverC.clear()
            let plan = SilencePlan(stalls: 6)
            installSilence(serverC, base: routeC, plan, match: isResearchRound2)
            serverC.script([WebFixtureServer.responsesBody("searching", id: "s1", calls: [webQuery])]
                           + (1...6).map { WebFixtureServer.responsesBody("never \($0)", id: "n\($0)") })
            let outcome = await withMainSlots(mainSlots(profile: "openai", base: h.baseC + "/v1", model: "gpt-6-sol",
                                                        key: "synthetic-main-openai-key", effort: "low", responses: true)) {
                await withinSeconds(14) { await directRun("HANG-R What is theta?") }
            }
            let research = serverC.requests.filter(isResearch)
            let error = outcome.value?.error ?? ""
            check("24.11 Responses: a silent researcher round ends with web_model_timeout after 2 attempts (equal connect/idle/overall clocks counted as silence)",
                  outcome.value != nil && error.hasPrefix("web_model_timeout:") && research.count == 3 && plan.stalled == 2,
                  "value \(outcome.value == nil ? "nil (hung)" : "set") error '\(error)' elapsed \(secs(outcome.elapsed)) research \(research.count)")
        }

        // 24.12 Responses transport labelling: an overall expiry during an
        // active stream is not silence; a silent attempt is.
        do {
            serverD.route = { request in
                if request.path.hasPrefix("/trickle") { return .init(body: "{}", trickle: (interval: 0.1, duration: 3)) }
                return .init(body: "{}", silentFor: 3)
            }
            var request = URLRequest(url: URL(string: h.baseD + "/trickle")!)
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.timeoutInterval = 10
            var activeSilence: Bool?
            do { _ = try await ResponsesHTTPTransport().send(request, overallTimeout: 0.6, connectTimeout: 3, idleTimeout: 0.4) }
            catch { activeSilence = ModelSilenceTimeout.isSilence(error) }
            request.url = URL(string: h.baseD + "/silent")!
            var deadSilence: Bool?
            do { _ = try await ResponsesHTTPTransport().send(request, overallTimeout: 0.5, connectTimeout: 0.5, idleTimeout: 0.5) }
            catch { deadSilence = ModelSilenceTimeout.isSilence(error) }
            check("24.12 Responses transport: an overall expiry while bytes flow is NOT a silence timeout (standard retries); a silent attempt with equal clocks IS",
                  activeSilence == false && deadSilence == true,
                  "active \(String(describing: activeSilence)) dead \(String(describing: deadSilence))")
            serverD.route = routeD
        }

        // 24.13 Policy: production clocks unchanged, one silence retry.
        ModelSilenceTimeout.requestTimeoutOverrideForTesting = nil
        check("24.13 policy: researcher silence retry limit 1; the adapters' request timeout is still 360 s hosted / 1200 s custom (0.2.55); other errors are not silence",
              ModelSilenceTimeout.researcherRetryLimit == 1
              && ModelSilenceTimeout.requestTimeout(customEndpoint: false) == 360 && ModelSilenceTimeout.requestTimeout(customEndpoint: true) == 1200
              && ModelSilenceTimeout.isSilence(URLError(.timedOut))
              && !ModelSilenceTimeout.isSilence(URLError(.networkConnectionLost))
              && !ModelSilenceTimeout.isSilence(URLError(.timedOut, userInfo: ["BrigliaResponsesDeadline": "overall", ModelSilenceTimeout.silenceKey: false]))
              && ModelSilenceTimeout.isSilence(URLError(.timedOut, userInfo: ["BrigliaResponsesDeadline": "idle", ModelSilenceTimeout.silenceKey: true])))
        serverA.clear(); serverB.clear(); serverC.clear()
    }
}
