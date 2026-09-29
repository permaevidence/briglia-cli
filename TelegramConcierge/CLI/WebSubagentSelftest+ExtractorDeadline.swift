import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Group 21 (OpenRouter extractor total deadline, 2026-09-29). While OpenRouter
// is the MAIN provider, each extractor request (extract.assets,
// extract.excerpts, web_fetch compression and its chunks) has a TOTAL
// wall-clock deadline counted from the send, whatever keepalive bytes arrive
// (OpenRouter trickles whitespace while a host reasons, so the idle timeout
// never fires). On expiry: cancel, log kind=deadline with host/elapsed/
// generation id, and retry through the host steering with the same
// 3-attempt ceiling. A time limit only: no output cap is ever sent.
extension WebSubagentSelftest {
    static func runExtractorDeadlineGroup(_ h: Harness) async throws {
        print("21. OpenRouter extractor total deadline: cut, steer, retry; slow replies and cancellation untouched")
        let fixtures = h.fixtures, serverD = h.serverD
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        let body = h.body
        func stageOf(_ request: WebFixtureServer.Request) -> String? {
            let t = String(decoding: request.body, as: UTF8.self)
            if t.contains("focus-relevant page assets") { return "assets" }
            if t.contains("Cite verbatim and in full") { return "excerpts" }
            if t.contains("You extract information from a web page") { return "compression" }
            return nil
        }
        func only(_ r: WebFixtureServer.Request) -> [String]? { (body(r)["provider"] as? [String: Any])?["only"] as? [String] }
        func uncapped(_ r: WebFixtureServer.Request) -> Bool {
            let b = body(r)
            return b["max_tokens"] == nil && b["max_completion_tokens"] == nil && b["max_output_tokens"] == nil
        }
        func okBody(_ stage: String, provider: String) -> String {
            let content: String
            switch stage {
            case "assets": content = "{\"links\":[{\"text\":\"Docs\",\"url\":\"https://example.test/docs\"}],\"images\":[]}"
            case "excerpts": content = "{\"excerpts\":[\"deadline excerpt\"]}"
            default: content = "COMPRESSED: deadline page"
            }
            let object: [String: Any] = [
                "id": "gen-deadline-ok", "object": "chat.completion", "created": 1_790_000_000, "model": "deepseek/deepseek-v4-flash-0731",
                "provider": provider,
                "choices": [["index": 0, "finish_reason": "stop", "native_finish_reason": "stop",
                             "message": ["role": "assistant", "content": content, "reasoning": "thinking"] as [String: Any]]],
                "usage": ["prompt_tokens": 9000, "completion_tokens": 700, "total_tokens": 9700, "cost": 0.0003,
                          "completion_tokens_details": ["reasoning_tokens": 500]]]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        /// A host that never finishes: headers at once, then whitespace
        /// forever (30 s, far past any deadline used here).
        func runaway(gen: String, provider: String?) -> WebFixtureServer.Response {
            var headers = ["X-Generation-Id": gen]
            if let provider { headers["X-Provider-Name"] = provider }
            return .init(body: "", headers: headers, trickle: (interval: 0.2, duration: 30))
        }
        /// Slow but finishing: whitespace for `seconds`, then a real answer.
        func slow(_ stage: String, seconds: TimeInterval) -> WebFixtureServer.Response {
            .init(body: okBody(stage, provider: "Reka"), headers: ["X-Generation-Id": "gen-slow"], trickle: (interval: 0.2, duration: seconds))
        }

        let queue = ResponseScripts()
        let baseRoute = serverD.route
        serverD.route = { request in
            guard let stage = stageOf(request) else { return baseRoute?(request) ?? .init(status: 500, body: "{}") }
            return queue.pop(stage) ?? .init(body: okBody(stage, provider: "DigitalOcean"))
        }
        defer { serverD.route = baseRoute }
        defer { WebSearchBackend.extractorDeadlineOverride = nil }

        let routerMain: [String: String?] = [ProviderProfiles.activeProfileKey: "openrouter", KeychainHelper.llmProviderKey: LLMProvider.openRouter.rawValue,
                                             KeychainHelper.openRouterApiKeyKey: "synthetic-or-key",
                                             KeychainHelper.openRouterModelKey: "deepseek/deepseek-v4.1-flash", KeychainHelper.openRouterReasoningEffortKey: "medium",
                                             ProviderProfiles.runtimeProtocolKey: nil]
        let page = "# Deadline page\n\n[Docs](https://example.test/docs)\n\n" + String(repeating: "Extractor deadline page text. ", count: 700)
        let orchestrator = WebOrchestrator()
        await orchestrator.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        WebSearchBackend.processOverride = nil
        defer { WebSearchBackend.processOverride = .opencode }
        var urlCounter = 0
        func nextURL() -> String { urlCounter += 1; return "https://example.test/deadline-\(urlCounter)" }
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        func extract(_ focus: String) async -> (WebOrchestrator.WebExtractOutcome?, [WebFixtureServer.Request], TimeInterval) {
            let url = nextURL()
            fixtures.pages[url] = page
            serverD.clear()
            let t0 = now()
            let outcome = await withMainSlots(routerMain) {
                try? await orchestrator.executeWebExtract(requests: [.init(url: url, focus: focus)], mode: .webSearch)
            }
            return (outcome, serverD.requests, now() - t0)
        }
        func fetch(_ prompt: String) async -> (String?, [WebFixtureServer.Request]) {
            let url = nextURL()
            fixtures.pages[url] = page
            serverD.clear()
            let content = await withMainSlots(routerMain) {
                try? await orchestrator.readUrlContentWithMetadata(url: url, prompt: prompt, refresh: true).result.content
            }
            return (content, serverD.requests)
        }
        func logText() -> String {
            WebPipelineLog.shared.flushForTesting()
            return (try? String(contentsOfFile: WebPipelineLog.shared.logFilePath, encoding: .utf8)) ?? ""
        }
        /// The first retry line logged after the failed attempt naming `gen`
        /// (the log is cumulative across groups, so match by position).
        func retryAfter(_ gen: String) -> String {
            let lines = logText().components(separatedBy: "\n")
            guard let i = lines.lastIndex(where: { $0.contains("gen=\(gen) ") }) else { return "" }
            return lines[(i + 1)...].first { $0.contains(" retrying (attempt ") } ?? ""
        }
        func logLines(_ needle: String) -> String {
            String(logText().components(separatedBy: "\n").filter { $0.contains(needle) }.joined(separator: " | ").prefix(600))
        }

        check("21.0 the extractor deadline is a named 300 s constant, and only a test override changes it",
              WebSearchBackend.openRouterExtractorDeadlineSeconds == 300 && WebSearchBackend.extractorDeadlineOverride == nil
              && WebSearchBackend.openRouterExtractorDeadline == 300)

        // 21.1 A runaway host (whitespace forever) is cut at the deadline and
        // the retry goes to the other host.
        WebSearchBackend.extractorDeadlineOverride = 2
        queue.reset()
        queue.push("assets", runaway(gen: "gen-dl-runaway", provider: "DigitalOcean"))
        let (cutOut, cutReqs, cutElapsed) = await extract("deadline runaway")
        let cutAssets = cutReqs.filter { stageOf($0) == "assets" }
        check("21.1 a host trickling whitespace forever is cut at the 2 s test deadline and retried once on the other pinned host (digitalocean excluded), both requests uncapped; the retry's links are used",
              cutAssets.count == 2 && only(cutAssets[0]) == ["reka", "digitalocean"] && only(cutAssets[1]) == ["reka"]
              && cutAssets.allSatisfy(uncapped) && cutOut?.docs.first?.links.map(\.url) == ["https://example.test/docs"]
              && cutElapsed >= 2 && cutElapsed < 15,
              "\(cutAssets.map { only($0) ?? [] }) elapsed \(String(format: "%.1f", cutElapsed))s links \(cutOut?.docs.first?.links.map(\.url) ?? [])")
        check("21.2 the cut is logged as a failed attempt: kind=deadline, host from X-Provider-Name, elapsed, deadline, generation id from X-Generation-Id, cost unknown; then the steered retry",
              logText().contains("openrouter stage=extract.assets NO_COMPLETION attempt=1/3 kind=deadline provider=DigitalOcean elapsed_s=")
              && logText().contains("deadline_s=2 gen=gen-dl-runaway cost=unknown")
              && retryAfter("gen-dl-runaway").hasSuffix("stage=extract.assets retrying (attempt 2/3) hosts=reka excluded=digitalocean"),
              logLines("kind=deadline"))
        check("21.3 spend: the cut attempt reports no usage, so only the successful calls are counted",
              cutOut.map { abs($0.spendUSD - 0.0003 * Double(cutReqs.count - 1)) < 1e-12 } ?? false,
              "\(cutOut?.spendUSD ?? -1) over \(cutReqs.count) calls")

        // 21.4 Host unknown (no X-Provider-Name): retried on the same hosts.
        queue.reset()
        queue.push("excerpts", runaway(gen: "gen-dl-anon", provider: nil))
        let (anonOut, anonReqs, _) = await extract("deadline anonymous")
        let anonEx = anonReqs.filter { stageOf($0) == "excerpts" }
        check("21.4 a cut request whose host OpenRouter did not name is retried on the same pinned hosts, logged provider=- with its generation id",
              anonEx.count == 2 && only(anonEx[0]) == ["reka", "digitalocean"] && only(anonEx[1]) == ["reka", "digitalocean"]
              && anonOut?.docs.first?.excerpts == ["deadline excerpt"]
              && logText().contains("kind=deadline provider=- elapsed_s=") && logText().contains("gen=gen-dl-anon cost=unknown")
              && retryAfter("gen-dl-anon").hasSuffix("stage=extract.excerpts retrying (attempt 2/3) same hosts (failing host unknown)"),
              "\(anonEx.map { only($0) ?? [] }) \(logLines("gen-dl-anon"))")

        // 21.5 Slow but finishing under the deadline: untouched.
        WebSearchBackend.extractorDeadlineOverride = 4
        queue.reset()
        queue.push("excerpts", slow("excerpts", seconds: 1.5))
        let (slowOut, slowReqs, slowElapsed) = await extract("deadline slow")
        let slowEx = slowReqs.filter { stageOf($0) == "excerpts" }
        check("21.5 a reply that trickles whitespace for 1.5 s and then answers, under a 4 s deadline, succeeds on the first request with no deadline log",
              slowEx.count == 1 && slowOut?.docs.first?.excerpts == ["deadline excerpt"] && slowElapsed >= 1.5
              && !logText().contains("gen=gen-slow"),
              "\(slowEx.count) requests, \(String(format: "%.1f", slowElapsed))s")

        // 21.6 Three cuts: the 3-attempt ceiling holds; web_fetch falls back.
        WebSearchBackend.extractorDeadlineOverride = 1
        queue.reset()
        queue.push("compression", runaway(gen: "gen-dl-x1", provider: "Reka"))
        queue.push("compression", runaway(gen: "gen-dl-x2", provider: "DigitalOcean"))
        queue.push("compression", runaway(gen: "gen-dl-x3", provider: "Reka"))
        let (exFetch, exReqs) = await fetch("deadline exhausted")
        let exComp = exReqs.filter { stageOf($0) == "compression" }
        check("21.6 three cut web_fetch compression attempts: exactly 3 requests (reka,digitalocean → digitalocean → reka,digitalocean), then the stage fails naming the deadline and web_fetch falls back to raw markdown",
              exComp.count == 3 && only(exComp[0]) == ["reka", "digitalocean"] && only(exComp[1]) == ["digitalocean"] && only(exComp[2]) == ["reka", "digitalocean"]
              && exComp.allSatisfy(uncapped)
              && exFetch?.contains("Extractor deadline page text.") == true
              && logText().contains("after 3 attempts: deadline from Reka"),
              "\(exComp.map { only($0) ?? [] })")

        // 21.7 Outer cancellation still stops a request mid-trickle: no retry,
        // no deadline record, prompt return.
        WebSearchBackend.extractorDeadlineOverride = 60
        queue.reset()
        queue.push("assets", runaway(gen: "gen-dl-cancel-a", provider: "Reka"))
        queue.push("excerpts", runaway(gen: "gen-dl-cancel-e", provider: "Reka"))
        let cancelURL = nextURL()
        fixtures.pages[cancelURL] = page
        serverD.clear()
        let t0 = now()
        let job = Task {
            await withMainSlots(routerMain) {
                try? await orchestrator.executeWebExtract(requests: [.init(url: cancelURL, focus: "deadline cancel")], mode: .webSearch)
            }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        job.cancel()
        _ = await job.value
        let cancelElapsed = now() - t0
        try? await Task.sleep(nanoseconds: 2_500_000_000)   // a wrongly scheduled retry would land here
        let cancelStages = serverD.requests.filter { stageOf($0) != nil }
        check("21.7 cancelling the outer job mid-trickle (60 s deadline) returns within seconds, sends no retry and records no deadline cut",
              cancelElapsed < 6 && cancelStages.filter { stageOf($0) == "assets" }.count <= 1
              && cancelStages.filter { stageOf($0) == "excerpts" }.count <= 1
              && !logText().contains("gen=gen-dl-cancel-a") && !logText().contains("gen=gen-dl-cancel-e"),
              "\(String(format: "%.1f", cancelElapsed))s, \(cancelStages.compactMap(stageOf))")

        // 21.8 Scope: /websearch openrouter without the follow has no deadline.
        WebSearchBackend.extractorDeadlineOverride = 1
        queue.reset()
        queue.push("excerpts", slow("excerpts", seconds: 2))
        let nfURL = nextURL()
        fixtures.pages[nfURL] = page
        serverD.clear()
        WebSearchBackend.processOverride = .openrouter
        await orchestrator.configure(openRouterKey: "synthetic-or-key", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        let nfOut = try? await orchestrator.executeWebExtract(requests: [.init(url: nfURL, focus: "deadline non-follow")], mode: .webSearch)
        WebSearchBackend.processOverride = nil
        let nfEx = serverD.requests.filter { stageOf($0) == "excerpts" }
        check("21.8 /websearch openrouter without the follow: no total deadline (a 2 s trickle under a 1 s test deadline still answers on the first request)",
              nfEx.count == 1 && nfOut?.docs.first?.excerpts == ["deadline excerpt"],
              "\(nfEx.count) requests \(nfOut?.docs.first?.excerpts ?? [])")
        WebSearchBackend.extractorDeadlineOverride = nil
    }
}

/// Per-stage scripted fixture responses for group 21 (thread-safe).
final class ResponseScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [WebFixtureServer.Response]] = [:]
    func reset() { lock.lock(); queues = [:]; lock.unlock() }
    func push(_ stage: String, _ response: WebFixtureServer.Response) { lock.lock(); queues[stage, default: []].append(response); lock.unlock() }
    func pop(_ stage: String) -> WebFixtureServer.Response? {
        lock.lock(); defer { lock.unlock() }
        guard var q = queues[stage], !q.isEmpty else { return nil }
        let first = q.removeFirst(); queues[stage] = q
        return first
    }
}
