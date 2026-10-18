import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Group 24, continued (WEB_OFFLINE_HANG round 4, Codex round-3 R1): a timeout
// that ends an ACTIVE Responses stream is never counted as silence, whichever
// clock wins. Codex's reproduction: URLSession's resource clock (configured to
// the same value as the explicit overall timer) can win the race during an
// active stream and complete the task with a bare -1001; 2cef0e1 counted that
// as silence and stopped the researcher early. The dev seam
// `ResponsesHTTPTransport.overallTimerDelayForTesting` schedules the explicit
// overall timer 0.5 s late so URLSession's resource expiry wins every time; no
// clock duration changes. Plus Codex's finalization/compaction assertions
// (round-limit summary, context-limit refusal summary, two separate requests,
// oversized resume compaction). Own file (Linux CI frontend memory).
extension WebSubagentSelftest {
    static func runSilenceTimeoutRaceGroup(_ h: Harness) async throws {
        print("24b. Web researcher silence classification: resource-timer race and finalization paths")
        let state = h.state, images = h.images, documents = h.documents, service = h.service
        let serverA = h.serverA, serverC = h.serverC, serverD = h.serverD
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        let routeA = serverA.route, routeC = serverC.route, routeD = serverD.route
        let savedOverride = WebSearchBackend.processOverride
        let savedHooks = OpenRouterService.chatRetryTestHooks
        defer {
            serverA.route = routeA; serverC.route = routeC; serverD.route = routeD
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = nil
            ResponsesHTTPTransport.overallTimerDelayForTesting = nil
            OpenRouterService.chatRetryTestHooks = savedHooks
            WebSearchBackend.processOverride = savedOverride
            try? AgentTurnOverrides.setOverride(nil, forAgent: "Web")
            try? KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "250000")
        }
        state.webFlag = true
        WebSearchBackend.processOverride = .opencode
        OpenRouterService.chatRetryTestHooks.sleepScale = 0.02
        let marker = "You are the web research subagent"
        func isResearch(_ r: WebFixtureServer.Request) -> Bool { String(decoding: r.body, as: UTF8.self).contains(marker) }
        let webQuery = ("web_query", "{\"queries\":[\"theta\"]}")
        func run(_ prompt: String, session: String? = nil) async -> SubagentRunner.RunResult {
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
            await executor.configureOpenRouter(service, imagesDirectory: images, documentsDirectory: documents)
            return await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "Web", description: "silence r4", taskPrompt: prompt,
                                                      modelOverride: nil, runInBackground: false, deliverable: .short),
                sessionId: session, openRouterService: service, toolExecutor: executor, imagesDirectory: images,
                documentsDirectory: documents, parentTools: AvailableTools.all(includeWebSearch: true))
        }
        func secs(_ t: TimeInterval) -> String { String(format: "%.1f", t) }
        func deadline(_ error: Error) -> String { ((error as NSError).userInfo["BrigliaResponsesDeadline"] as? String) ?? "URLSession" }

        // 24.14 Transport: with the explicit overall timer delayed, URLSession's
        // own resource expiry ends an active stream. It must be labelled
        // non-silence; a silent attempt under the same scheduling stays silence.
        do {
            ResponsesHTTPTransport.overallTimerDelayForTesting = 0.5
            serverD.route = { request in
                if request.path.hasPrefix("/active") { return .init(body: "{}", trickle: (interval: 0.05, duration: 4)) }
                return .init(body: "{}", silentFor: 4)
            }
            var active: [String] = [], silent: [String] = []
            for shared in [false, true] {
                SharedDataTaskSession.forceForTesting = shared
                for budget in [0.6, 1.0] {
                    var request = URLRequest(url: URL(string: h.baseD + "/active")!)
                    request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.timeoutInterval = budget
                    do { _ = try await ResponsesHTTPTransport().send(request, overallTimeout: budget, connectTimeout: budget, idleTimeout: budget) }
                    catch { active.append("\(deadline(error)) silent=\(ModelSilenceTimeout.isSilence(error)) shared=\(shared)") }
                    request.url = URL(string: h.baseD + "/silent")!
                    do { _ = try await ResponsesHTTPTransport().send(request, overallTimeout: budget, connectTimeout: budget, idleTimeout: budget) }
                    catch { silent.append("\(deadline(error)) silent=\(ModelSilenceTimeout.isSilence(error)) shared=\(shared)") }
                }
            }
            SharedDataTaskSession.forceForTesting = false
            ResponsesHTTPTransport.overallTimerDelayForTesting = nil
            serverD.route = routeD
            // Darwin per-request sessions: URLSession's resource clock wins
            // (no Briglia deadline label). Shared session: its resource clock
            // is seven days, so the delayed overall timer ends it.
            let darwinResourceWon = active.filter { $0.hasSuffix("shared=false") }.allSatisfy { $0.hasPrefix("URLSession") }
            check("24.14 Responses transport, overall timer scheduled late: URLSession's resource expiry during an active stream is labelled NOT silence; a silent attempt under the same scheduling IS silence (per-request and shared sessions)",
                  active.count == 4 && active.allSatisfy { $0.contains("silent=false") } && darwinResourceWon
                  && silent.count == 4 && silent.allSatisfy { $0.contains("silent=true") },
                  "active \(active) silent \(silent)")
        }

        // 24.15 Codex's R1 reproduction, end to end: a Responses researcher's
        // round 2 streams bytes past its overall clock twice while URLSession's
        // resource timer wins; 0.2.55's standard retries apply and the third
        // attempt answers (4 research requests). 2cef0e1 stopped after 3.
        func responsesRun(_ prompt: String, seconds: TimeInterval) async -> (value: SubagentRunner.RunResult?, elapsed: TimeInterval) {
            await withMainSlots(mainSlots(profile: "openai", base: h.baseC + "/v1", model: "gpt-6-sol",
                                          key: "synthetic-main-openai-key", effort: "low", responses: true)) {
                await withinSeconds(seconds) { await run(prompt) }
            }
        }
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = 1
            ResponsesHTTPTransport.overallTimerDelayForTesting = 0.5
            serverC.clear()
            serverC.route = { request in
                var response = routeC?(request) ?? .init(status: 500, body: "{}")
                if String(decoding: request.body, as: UTF8.self).contains("function_call_output"), response.body.contains("streaming-never") {
                    response.trickle = (interval: 0.05, duration: 3)
                }
                return response
            }
            serverC.script([WebFixtureServer.responsesBody("searching", id: "a1", calls: [webQuery])]
                           + (1...2).map { WebFixtureServer.responsesBody("streaming-never \($0)", id: "a\($0 + 1)") }
                           + [WebFixtureServer.responsesBody("Theta recovered on the third attempt. Sources: https://example.test/theta", id: "a4")])
            let outcome = await responsesRun("ACTIVE-R What is theta?", seconds: 16)
            let research = serverC.requests.filter(isResearch)
            check("24.15 Responses researcher: two attempts that keep streaming past the overall clock (URLSession's resource timer winning) keep 0.2.55's standard retries; the third attempt answers (4 research requests, no web_model_timeout)",
                  outcome.value?.error == nil && outcome.value?.finalMessage.contains("Theta recovered on the third attempt.") == true && research.count == 4,
                  "error \(outcome.value?.error ?? "none") elapsed \(secs(outcome.elapsed)) research \(research.count)")
            serverC.route = routeC
            ResponsesHTTPTransport.overallTimerDelayForTesting = nil
        }

        // 24.16 The genuinely silent Responses round under the same late
        // scheduling: still two attempts, then web_model_timeout.
        do {
            ModelSilenceTimeout.requestTimeoutOverrideForTesting = 1
            ResponsesHTTPTransport.overallTimerDelayForTesting = 0.5
            serverC.clear()
            serverC.route = { request in
                var response = routeC?(request) ?? .init(status: 500, body: "{}")
                if String(decoding: request.body, as: UTF8.self).contains("function_call_output") { response.silentFor = 4 }
                return response
            }
            serverC.script([WebFixtureServer.responsesBody("searching", id: "s1", calls: [webQuery])]
                           + (1...4).map { WebFixtureServer.responsesBody("never \($0)", id: "s\($0 + 1)") })
            let outcome = await responsesRun("SILENT-R What is theta?", seconds: 14)
            let research = serverC.requests.filter(isResearch)
            check("24.16 Responses researcher, same late scheduling: a genuinely silent round 2 still ends with web_model_timeout after 2 attempts (3 research requests)",
                  (outcome.value?.error ?? "").hasPrefix("web_model_timeout:") && research.count == 3,
                  "error \(outcome.value?.error ?? "nil") elapsed \(secs(outcome.elapsed)) research \(research.count)")
            serverC.route = routeC
            ResponsesHTTPTransport.overallTimerDelayForTesting = nil
        }

        // Chat finalization paths (Codex round-3 extra assertions).
        ModelSilenceTimeout.requestTimeoutOverrideForTesting = 1
        func stallToolRounds() {
            serverA.route = { request in
                var response = routeA?(request) ?? .init(status: 500, body: "{}")
                if String(decoding: request.body, as: UTF8.self).contains("\"role\":\"tool\"") { response.silentFor = 10 }
                return response
            }
        }

        // 24.17 Round-limit final summary silent twice.
        do {
            serverA.clear(); stallToolRounds()
            try AgentTurnOverrides.setOverride(1, forAgent: "Web")
            serverA.script([WebFixtureServer.chatBody("search", calls: [webQuery])] + (1...5).map { WebFixtureServer.chatBody("late \($0)") })
            let outcome = await withinSeconds(12) { await run("SUMMARY-SILENT What is theta?") }
            try AgentTurnOverrides.setOverride(nil, forAgent: "Web")
            check("24.17 round-limit final summary silent twice: two attempts, then web_model_timeout with the maxTurns prefix (3 research requests)",
                  outcome.value?.error?.hasPrefix("web_model_timeout: Subagent exhausted maxTurns (1)") == true && serverA.requests.count == 3,
                  "error \(outcome.value?.error ?? "nil") requests \(serverA.requests.count)")
        }

        // 24.18 Context-limit refusal summary silent twice: no tools run.
        do {
            serverA.clear(); stallToolRounds()
            serverA.script([WebFixtureServer.chatBody("no lookup", prompt: 300_000), WebFixtureServer.chatBody("refused", calls: [webQuery])]
                           + (1...5).map { WebFixtureServer.chatBody("late \($0)") })
            let outcome = await withinSeconds(12) { await run("REFUSAL-SILENT What is theta?") }
            check("24.18 context-limit refusal summary silent twice: web_model_timeout after 4 research requests, no tool executed",
                  outcome.value?.error?.hasPrefix("web_model_timeout:") == true && serverA.requests.count == 4 && outcome.value?.toolsCalled.isEmpty == true,
                  "error \(outcome.value?.error ?? "nil") requests \(serverA.requests.count) tools \(outcome.value?.toolsCalled ?? [])")
        }

        // 24.19 One recovered silence in each of two separate requests; then
        // 24.20 an oversized resume whose compaction summarizer is silent
        // twice keeps compaction's standard retries (not the researcher limit).
        do {
            serverA.clear()
            serverA.route = { request in
                var response = routeA?(request) ?? .init(status: 500, body: "{}")
                if response.body.contains("R4_STALL") { response.silentFor = 10 }
                return response
            }
            serverA.script([WebFixtureServer.chatBody("R4_STALL one"), WebFixtureServer.chatBody("search", calls: [webQuery]),
                            WebFixtureServer.chatBody("R4_STALL two"), WebFixtureServer.chatBody("recovered across rounds")])
            let across = await withinSeconds(12) { await run("ACROSS What is theta?") }
            check("24.19 each researcher request gets its own silence retry: one silence in round 1 and one in round 2 both recover (4 requests, normal final)",
                  across.value?.error == nil && across.value?.finalMessage == "recovered across rounds" && serverA.requests.count == 4,
                  "error \(across.value?.error ?? "none") requests \(serverA.requests.count) final \(across.value?.finalMessage.prefix(80) ?? "")")
            var compactOK = false, compactDetail = "no session"
            if let id = across.value?.sessionId, !id.isEmpty {
                let big = (0..<6).map { Message(role: $0 % 2 == 0 ? .user : .assistant, content: String(repeating: "old work ", count: 1000), timestamp: state.clock) }
                await SubagentSessionRegistry.shared.applyCompaction(sessionId: id, messages: big, toolInteractions: [])
                try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "1000")
                serverA.clear()
                let plan = SilencePlan(stalls: 2, silentFor: 10)
                serverA.route = { request in
                    var response = routeA?(request) ?? .init(status: 500, body: "{}")
                    if String(decoding: request.body, as: UTF8.self).contains("TRANSCRIPT TO SUMMARIZE"), plan.shouldStall() { response.silentFor = 10 }
                    return response
                }
                serverA.script([WebFixtureServer.chatBody("lost1"), WebFixtureServer.chatBody("lost2"), WebFixtureServer.chatBody("compacted old work"),
                                WebFixtureServer.chatBody("resume done"), WebFixtureServer.chatBody("resume done")])
                let compact = await withinSeconds(12) { await run("RESUME oversized", session: id) }
                try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "250000")
                compactOK = compact.value?.error == nil && plan.stalled == 2 && compact.value?.finalMessage.contains("resume done") == true
                compactDetail = "error \(compact.value?.error ?? "none") stalled \(plan.stalled) requests \(serverA.requests.count)"
            }
            check("24.20 oversized Web resume: the compaction summarizer silent twice keeps its standard retries (third attempt succeeds, run completes)",
                  compactOK, compactDetail)
        }

        // 24.21 Classifier policy: nothing unlabelled is Responses silence;
        // chat classifies at its own boundary against the resource clock.
        check("24.21 classifier: an unlabelled timeout is not Responses silence; a chat timeout before the resource clock is silence, one at the resource clock is not",
              !ModelSilenceTimeout.isSilence(URLError(.timedOut))
              && ModelSilenceTimeout.isChatSilence(URLError(.timedOut), elapsed: 1.2, resourceTimeout: 604_800)
              && !ModelSilenceTimeout.isChatSilence(URLError(.timedOut), elapsed: 604_800, resourceTimeout: 604_800)
              && !ModelSilenceTimeout.isChatSilence(URLError(.networkConnectionLost), elapsed: 1, resourceTimeout: 604_800)
              && URLSession.shared.configuration.timeoutIntervalForResource >= 604_800)
        ModelSilenceTimeout.requestTimeoutOverrideForTesting = nil
        serverA.clear(); serverC.clear()
    }
}
