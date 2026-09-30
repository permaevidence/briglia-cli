import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Group 23 (v0.2.44, owner decisions 2026-09-30). (1) The extractor's total
// wall-clock deadline is 120 s and applies on EVERY page-reading backend —
// OpenRouter (follow or /websearch), the OpenAI API key, the ChatGPT
// subscription and OpenCode Go — keepalive bytes never extend it, each cut is
// logged `kind=deadline` and retried within the 3 completion attempts. A cut
// on a backend billed per request (OpenAI API key) becomes an unknown-amount
// incident exactly like OpenRouter's; the flat plans record nothing.
// (2) OpenCode Go's page stages run GPT-6 Luna over the Responses API.
// Kept in its own file (Linux CI frontend memory).
extension WebSubagentSelftest {
    static func runAllLaneDeadlineGroup(_ h: Harness) async throws {
        print("23. Extractor deadline on every backend (120 s) + OpenCode extraction on GPT-6 Luna over Responses")
        let fixtures = h.fixtures, serverB = h.serverB, serverC = h.serverC
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        let body = h.body
        func stageOf(_ request: WebFixtureServer.Request) -> String? { extractorStage(request) }
        func uncappedNoTemperature(_ r: WebFixtureServer.Request) -> Bool {
            let b = body(r)
            return b["max_tokens"] == nil && b["max_completion_tokens"] == nil && b["max_output_tokens"] == nil && b["temperature"] == nil
        }
        let excerptJSON = "{\"blocks\":[\"P1\"],\"links\":[],\"images\":[]}"
        /// Headers at once, then keepalive whitespace for 30 s (past any test
        /// deadline). `generation` sets an X-Generation-Id header a non-
        /// OpenRouter backend must ignore.
        func runaway(generation: String? = nil) -> WebFixtureServer.Response {
            .init(body: "", headers: generation.map { ["X-Generation-Id": $0, "X-Provider-Name": "Fake"] } ?? [:], trickle: (interval: 0.2, duration: 30))
        }

        // Scratch ledger (never the real data root) and a restored state.
        let ledgerDir = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-websub-alllane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        let previousLedgerDir = ToolChargeLedger.directoryForTesting
        ToolChargeLedger.directoryForTesting = ledgerDir
        ToolChargeLedger.resetForTesting()
        let savedOverride = WebSearchBackend.processOverride
        let routeB = serverB.route, routeC = serverC.route
        let queue = ResponseScripts()
        setenv("BRIGLIA_DEV_OPENAI_WEB_BASE", h.baseC, 1)
        defer {
            unsetenv("BRIGLIA_DEV_OPENAI_WEB_BASE")
            serverB.route = routeB; serverC.route = routeC
            WebSearchBackend.processOverride = savedOverride
            WebSearchBackend.extractorDeadlineOverride = nil
            SubscriptionWebTransport.resetForTests()
            ToolChargeLedger.resetForTesting()
            ToolChargeLedger.directoryForTesting = previousLedgerDir
            try? FileManager.default.removeItem(at: ledgerDir)
        }
        func incidents() -> [SpendIncident] {
            if case .readable(let list) = ToolChargeLedger.loadIncidents() { return list }
            return []
        }
        func inFlight() -> [ToolChargeLedger.InFlightRequest] {
            if case .readable(let list) = ToolChargeLedger.loadInFlight() { return list }
            return []
        }
        func logText() -> String {
            WebPipelineLog.shared.flushForTesting()
            return (try? String(contentsOfFile: WebPipelineLog.shared.logFilePath, encoding: .utf8)) ?? ""
        }
        func logCount(_ needle: String) -> Int { logText().components(separatedBy: "\n").filter { $0.contains(needle) }.count }
        // Stage replies: a queued scripted reply first, else a normal answer.
        serverC.route = { request in
            if let stage = stageOf(request) {
                if let scripted = queue.pop("openai-" + stage) { return scripted }
                return .init(body: WebFixtureServer.chatBody(stage == "excerpts" ? excerptJSON : "OPENAI COMPRESSED"))
            }
            return routeC?(request) ?? .init(status: 500, body: "{}")
        }
        serverB.route = { request in
            if let stage = stageOf(request) {
                if let scripted = queue.pop("opencode-" + stage) { return scripted }
                let reply = stage == "excerpts" ? excerptJSON : "OPENCODE COMPRESSED"
                return .init(body: request.path.hasSuffix("/responses") ? WebFixtureServer.responsesBody(reply, id: "oc") : WebFixtureServer.chatBody(reply))
            }
            return routeB?(request) ?? .init(status: 500, body: "{}")
        }
        let page = "# Lane page\n\n[Docs](https://example.test/docs)\n\n" + String(repeating: "All-lane deadline page text. ", count: 700)
        var counter = 0
        func nextURL() -> String { counter += 1; fixtures.pages["https://example.test/alllane-\(counter)"] = page; return "https://example.test/alllane-\(counter)" }
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        let orchestrator = WebOrchestrator()
        await orchestrator.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")

        // 23.0 Constants and the billing split.
        check("23.0 one 120 s extractor deadline for every backend; OpenRouter and the OpenAI API key are billed per request, the ChatGPT subscription and OpenCode Go are not; OpenCode's page stages name GPT-6 Luna",
              WebSearchBackend.extractorDeadlineSeconds == 120 && WebSearchBackend.extractorDeadline == 120
              && WebSearchBackend.openrouter.billedPerRequest && WebSearchBackend.openai.billedPerRequest
              && !WebSearchBackend.chatgpt.billedPerRequest && !WebSearchBackend.opencode.billedPerRequest
              && WebOrchestrator.opencodeExtractorModel == "gpt-6-luna" && WebSearchBackend.opencode.modelSummary.contains("GPT-6 Luna")
              && WebSearchBackend.openCodeResponsesEndpoint.path.hasSuffix("/zen/go/v1/responses"),
              WebSearchBackend.opencode.modelSummary)

        // ---- OpenCode Go: GPT-6 Luna over Responses.
        WebSearchBackend.processOverride = .opencode
        WebSearchBackend.extractorDeadlineOverride = 60
        serverB.clear()
        let ocURL = nextURL()
        let ocOut = try? await orchestrator.executeWebExtract(requests: [.init(url: ocURL, focus: "opencode luna")], mode: .webSearch)
        let ocFetch = try? await orchestrator.readUrlContentWithMetadata(url: ocURL, prompt: "opencode luna fetch", refresh: true)
        let ocStages = serverB.requests.filter { stageOf($0) != nil }
        let ocEx = ocStages.first { stageOf($0) == "excerpts" }.map(body) ?? [:]
        let ocComp = ocStages.first { stageOf($0) == "compression" }.map(body) ?? [:]
        let fmt = (ocEx["text"] as? [String: Any])?["format"] as? [String: Any]
        let input = (ocEx["input"] as? [[String: Any]]) ?? []
        check("23.1 OpenCode excerpts: POST /zen/go/v1/responses with the web key, model gpt-6-luna, reasoning.effort medium, strict json_schema text.format (excerpts), store:false, stream:false, the system prompt as instructions and the page as user input, no temperature, no output cap, no chat fields",
              ocStages.filter { stageOf($0) == "excerpts" }.count == 1
              && ocStages.allSatisfy { $0.path == "/zen/go/v1/responses" && $0.headers["authorization"] == "Bearer synthetic-web-opencode-key" && uncappedNoTemperature($0) }
              && ocEx["model"] as? String == "gpt-6-luna" && (ocEx["reasoning"] as? [String: Any])?["effort"] as? String == "medium"
              && fmt?["type"] as? String == "json_schema" && fmt?["name"] as? String == WebExtractionSchemas.excerpts.json_schema.name && fmt?["strict"] as? Bool == true
              && ocEx["store"] as? Bool == false && ocEx["stream"] as? Bool == false
              && (ocEx["instructions"] as? String)?.contains("Select the parts of the provided TEXT") == true
              && input.count == 1 && input[0]["role"] as? String == "user"
              && ocEx["messages"] == nil && ocEx["reasoning_effort"] == nil && ocEx["response_format"] == nil && ocEx["provider"] == nil,
              "\(ocStages.map(\.path)) keys \(ocEx.keys.sorted())")
        check("23.2 OpenCode results parse from the Responses reply: the picked block is copied, web_fetch compression returns the model's text; the compression request carries no text.format",
              ocOut?.docs.first?.excerpts == ["# Lane page"] && ocFetch?.result.content.contains("OPENCODE COMPRESSED") == true
              && ocComp["model"] as? String == "gpt-6-luna" && ocComp["text"] == nil && (ocComp["reasoning"] as? [String: Any])?["effort"] as? String == "medium",
              "\(ocOut?.docs.first?.excerpts ?? []) | \(ocFetch?.result.content.prefix(120) ?? "nil")")

        // 23.3 OpenCode deadline: a runaway (keepalive forever) is cut at the
        // 1 s test deadline, logged kind=deadline, no incident (flat plan),
        // nothing left in flight; the retry answers.
        WebSearchBackend.extractorDeadlineOverride = 1
        queue.reset()
        queue.push("opencode-excerpts", runaway())
        serverB.clear()
        let incidentsBefore = incidents().count
        let deadlineLinesBefore = logCount("opencode stage=extract.excerpts NO_COMPLETION attempt=1/3 kind=deadline")
        let t0 = now()
        let ocCut = try? await orchestrator.executeWebExtract(requests: [.init(url: nextURL(), focus: "opencode deadline")], mode: .webSearch)
        let ocCutElapsed = now() - t0
        let ocCutEx = serverB.requests.filter { stageOf($0) == "excerpts" }
        check("23.3 OpenCode: a host trickling keepalive bytes forever is cut at the deadline (not reset by the bytes), logged kind=deadline with cost=none(flat plan), no incident, nothing in flight, and the retry's picks are used",
              ocCutEx.count == 2 && ocCut?.docs.first?.excerpts == ["# Lane page"] && ocCutElapsed < 8
              && incidents().count == incidentsBefore && inFlight().isEmpty
              && logCount("opencode stage=extract.excerpts NO_COMPLETION attempt=1/3 kind=deadline") == deadlineLinesBefore + 1
              && logText().contains("deadline_s=1 gen=- cost=none(flat plan)"),
              "\(ocCutEx.count) requests in \(String(format: "%.1f", ocCutElapsed)) s, incidents \(incidents().count - incidentsBefore)")

        // 23.4 Three cuts in a row: the stage fails after 3 attempts naming
        // the deadline; three requests; bounded wait.
        queue.reset()
        for _ in 0..<3 { queue.push("opencode-compression", runaway()) }
        serverB.clear()
        let t1 = now()
        var threeCutError = ""
        do { _ = try await orchestrator.compressPageForPrompt(pageURL: "https://example.test/three", pageTitle: nil, markdown: "Three cuts page", prompt: "q", executionID: UUID()) }
        catch { threeCutError = error.localizedDescription }
        let threeElapsed = now() - t1
        check("23.4 OpenCode: three deadline cuts in a row fail the stage after 3 attempts, naming the deadline (bounded: 3 deadlines plus the 1.5 s + 3 s pauses)",
              serverB.requests.filter { stageOf($0) == "compression" }.count == 3
              && threeCutError.contains("opencode returned no completion") && threeCutError.contains("after 3 attempts") && threeCutError.contains("deadline")
              && threeElapsed < 12,
              "\(threeCutError.prefix(200)) in \(String(format: "%.1f", threeElapsed)) s")

        // ---- OpenAI API key: chat completions, billed per request.
        WebSearchBackend.processOverride = .openai
        WebSearchBackend.extractorDeadlineOverride = 1
        queue.reset()
        queue.push("openai-excerpts", runaway(generation: "gen-must-not-be-read"))
        serverC.clear()
        let oaBefore = incidents().count
        let oaURL = nextURL()
        let t2 = now()
        let oaOut = try? await orchestrator.executeWebExtract(requests: [.init(url: oaURL, focus: "openai deadline")], mode: .webSearch)
        let oaElapsed = now() - t2
        let oaEx = serverC.requests.filter { stageOf($0) == "excerpts" }
        let oaNew = Array(incidents().dropFirst(oaBefore))
        let oaIncident = oaNew.first
        check("23.5 OpenAI API key: a runaway is cut at the deadline and retried; the answer is used; both sends go to /v1/chat/completions with GPT-6 Luna, no temperature, no output cap",
              oaEx.count == 2 && oaOut?.docs.first?.excerpts == ["# Lane page"] && oaElapsed < 8
              && oaEx.allSatisfy { $0.path == "/v1/chat/completions" && body($0)["model"] as? String == "gpt-6-luna" && uncappedNoTemperature($0)
                  && $0.headers["authorization"] == "Bearer synthetic-web-openai-key" },
              "\(oaEx.count) requests in \(String(format: "%.1f", oaElapsed)) s")
        check("23.6 OpenAI API key: the cut send becomes ONE unknown-amount incident (billed per request, like OpenRouter) naming host OpenAI, with no generation id (another backend's headers never feed the OpenRouter cost lookup); nothing left in flight; the line says kind=deadline and the incident",
              oaNew.count == 1 && oaIncident?.kind == .unknownAmount && oaIncident?.state == .open && oaIncident?.generationId == nil
              && oaIncident?.detail?.hasPrefix(ToolChargeLedger.cutRequestDetailPrefix) == true && oaIncident?.detail?.contains("host OpenAI") == true
              && inFlight().isEmpty && ToolChargeLedger.pendingCutRequests().allSatisfy { $0.id != oaIncident?.id }
              && logText().contains("openai stage=extract.excerpts NO_COMPLETION attempt=1/3 kind=deadline provider=- ")
              && logText().contains("cost=unknown incident=\(oaIncident?.id ?? "?")"),
              "\(oaNew.map { "\($0.id) \($0.detail ?? "") gen=\($0.generationId ?? "nil")" })")

        // 23.7 OpenAI API key: the spend gate is checked before each paid
        // send — with a daily cap and that open unknown, nothing is sent.
        let cappedSlots: [String: String?] = [KeychainHelper.openRouterToolSpendLimitDailyUSDKey: "50"]
        serverC.clear()
        let pausedOut: WebOrchestrator.WebExtractOutcome? = await withMainSlots(cappedSlots) {
            try? await orchestrator.executeWebExtract(requests: [.init(url: nextURL(), focus: "openai paused")], mode: .webSearch)
        }
        check("23.7 OpenAI API key: with a spend cap and an open unknown charge, paid work is paused — no extraction request is sent and the page fails naming the pause",
              serverC.requests.filter { stageOf($0) != nil }.isEmpty
              && (pausedOut?.failures.first ?? "").contains("openai stage 'extract.excerpts' not sent"),
              "\(serverC.requests.count) requests; \(pausedOut?.failures ?? [])")
        _ = ToolChargeLedger.acceptOpenIncidents(channel: "selftest")
        ToolChargeLedger.resetForTesting()

        // ---- ChatGPT subscription: streamed Responses, no per-request charge.
        let subSlots: [String: String?] = [ProviderProfiles.activeProfileKey: "chatgpt",
                                           KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
                                           KeychainHelper.openAICompatibleApiKeyKey: "gen-fixture"]
        WebSearchBackend.processOverride = nil
        final class Sends: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let sends = Sends()
        SubscriptionWebTransport.sendOverride = { _ in
            if sends.next() == 1 {
                // A stream that never ends (keepalive only): only the
                // deadline's cancellation ends it.
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
            return Data(WebFixtureServer.responsesBody("SUB COMPRESSED", id: "sub").utf8)
        }
        let subBefore = incidents().count
        let t3 = now()
        let subText: String? = await withMainSlots(subSlots) {
            try? await orchestrator.compressPageForPrompt(pageURL: "https://example.test/sub", pageTitle: nil, markdown: "Sub page", prompt: "q", executionID: UUID())
        }
        let subElapsed = now() - t3
        check("23.8 ChatGPT subscription: a send still open at the deadline is cancelled and retried (the login refresh is outside the clock), logged kind=deadline cost=none(flat plan), no incident; the retry answers",
              subText == "SUB COMPRESSED" && sends.count == 2 && subElapsed < 8 && incidents().count == subBefore && inFlight().isEmpty
              && logText().contains("chatgpt stage=web_fetch_compression NO_COMPLETION attempt=1/3 kind=deadline"),
              "\(subText ?? "nil") after \(sends.count) sends in \(String(format: "%.1f", subElapsed)) s")

        // 23.9 A deadline error is never swallowed by the subscription's
        // transient-retry loop: a slow send answered after the deadline is
        // not waited for.
        SubscriptionWebTransport.sendOverride = { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return Data(WebFixtureServer.responsesBody("late", id: "late").utf8)
        }
        let deadline = ExtractorDeadline(seconds: 0.5, backendLabel: "chatgpt", readsGenerationHeaders: false)
        let t4 = now()
        var directError: Error?
        do {
            _ = try await withMainSlots(subSlots) {
                try await SubscriptionWebTransport.post(body: ["model": .string("gpt-6-luna"), "input": .array([])], lane: .ephemeral(UUID()), timeout: 120, deadline: deadline)
            }
        } catch { directError = error }
        let directElapsed = now() - t4
        check("23.9 SubscriptionWebTransport.post with a deadline: the open send is cut at 0.5 s and ExtractorDeadlineExceeded (request in flight) is thrown, not retried as a timeout",
              (directError as? ExtractorDeadlineExceeded)?.requestInFlight == true && directElapsed < 3,
              "\(String(describing: directError)) in \(String(format: "%.2f", directElapsed)) s")
        SubscriptionWebTransport.resetForTests()
    }
}
