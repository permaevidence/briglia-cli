import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Group 20 (OpenRouter extractor room, 2026-09-29). While OpenRouter is the
// MAIN provider, every extractor stage (extract.assets, extract.excerpts,
// web_fetch compression) runs DeepSeek V4 Flash on the pinned hosts and:
//  - sends no output-token cap at all (owner rule 2026-09-29), effort low;
//  - on an empty completion (length-starved, repetition, provider error)
//    retries AWAY from the host that failed, same body, same 3-attempt
//    ceiling; an empty body (host unknown) retries on the same hosts;
//  - logs each failed attempt's host, finish reasons, token split and
//    generation id; counts the failed attempt's billed cost in spend.
// Other backends keep their retry behaviour; no backend sends a cap.
extension WebSubagentSelftest {
    static func runExtractorRoomGroups(_ h: Harness) async throws {
        print("20. OpenRouter extractor room: no output cap, host steering, diagnostics, spend")
        let fixtures = h.fixtures, serverB = h.serverB, serverD = h.serverD
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        let body = h.body
        func text(_ request: WebFixtureServer.Request) -> String { String(decoding: request.body, as: UTF8.self) }
        func stageOf(_ request: WebFixtureServer.Request) -> String? {
            let t = text(request)
            if t.contains("Select the parts of the provided TEXT") { return "excerpts" }
            if t.contains("You extract information from a web page") { return "compression" }
            return nil
        }
        func only(_ r: WebFixtureServer.Request) -> [String]? { (body(r)["provider"] as? [String: Any])?["only"] as? [String] }
        func uncapped(_ r: WebFixtureServer.Request) -> Bool {
            let b = body(r)
            return b["max_tokens"] == nil && b["max_completion_tokens"] == nil && b["max_output_tokens"] == nil
        }
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-12 } ?? false }
        /// Canonical JSON bytes (sorted keys) of a decoded body. Portable:
        /// NSDictionary.isEqual(to:) with nested JSON values reports unequal
        /// on Linux corelibs-foundation even for identical bodies.
        func canonical(_ d: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) }
        func sameBody(_ a: [String: Any], _ b: [String: Any]) -> Bool {
            guard let x = canonical(a), let y = canonical(b) else { return false }
            return x == y
        }
        /// A body identical to `a` except for the provider block.
        func sameButProvider(_ a: WebFixtureServer.Request, _ b: WebFixtureServer.Request) -> Bool {
            var x = body(a), y = body(b)
            x["provider"] = nil; y["provider"] = nil
            return sameBody(x, y)
        }

        // An OpenRouter chat envelope as the hosts return it (keepalive
        // whitespace before the JSON included).
        func envelope(content: String?, provider: String, finish: String, native: String,
                      completion: Int, reasoning: Int, cost: Double, id: String) -> String {
            var message: [String: Any] = ["role": "assistant", "reasoning": String(repeating: "thinking ", count: 20)]
            message["content"] = content ?? NSNull()
            let object: [String: Any] = [
                "id": id, "object": "chat.completion", "created": 1_790_000_000, "model": "openai/gpt-6-luna",
                "provider": provider,
                "choices": [["index": 0, "finish_reason": finish, "native_finish_reason": native, "message": message]],
                "usage": ["prompt_tokens": 9000, "completion_tokens": completion, "total_tokens": 9000 + completion, "cost": cost,
                          "completion_tokens_details": ["reasoning_tokens": reasoning]]]
            return "\n\n   \n" + String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        func ok(_ stage: String, provider: String) -> String {
            let content: String
            switch stage {
            // One pass (2026-09-30): quotes plus picks; L1 = Docs.
            case "excerpts": content = "{\"blocks\":[\"P1\"],\"links\":[1],\"images\":[]}"
            default: content = "COMPRESSED: room page"
            }
            return envelope(content: content, provider: provider, finish: "stop", native: "stop", completion: 700, reasoning: 500, cost: 0.0003, id: "gen-fixture-ok")
        }
        func starved(_ host: String, id: String) -> String {
            envelope(content: "", provider: host, finish: "length", native: "length", completion: 32000, reasoning: 31990, cost: 0.02, id: id)
        }
        func repeated(_ host: String, id: String) -> String {
            envelope(content: nil, provider: host, finish: "stop", native: "repetition", completion: 4100, reasoning: 4100, cost: 0.004, id: id)
        }
        let providerError = "{\"error\":{\"message\":\"Provider returned error\",\"code\":502,\"metadata\":{\"provider_name\":\"OpenAI\",\"raw\":\"upstream reset\"}}}"

        // Per-stage scripted replies; an exhausted queue answers ok from Azure.
        let scripts = StageScripts()
        let baseRoute = serverD.route
        serverD.route = { request in
            let t = String(decoding: request.body, as: UTF8.self)
            let stage: String? = t.contains("Select the parts of the provided TEXT") ? "excerpts"
                : t.contains("You extract information from a web page") ? "compression" : nil
            guard let stage else { return baseRoute?(request) ?? .init(status: 500, body: "{}") }
            return .init(body: scripts.pop(stage) ?? ok(stage, provider: "Azure"))
        }
        defer { serverD.route = baseRoute }

        let routerMain: [String: String?] = [ProviderProfiles.activeProfileKey: "openrouter", KeychainHelper.llmProviderKey: LLMProvider.openRouter.rawValue,
                                             KeychainHelper.openRouterApiKeyKey: "synthetic-or-key",
                                             KeychainHelper.openRouterModelKey: "deepseek/deepseek-v4.1-flash", KeychainHelper.openRouterReasoningEffortKey: "medium",
                                             ProviderProfiles.runtimeProtocolKey: nil]
        let page = "# Room page\n\n[Docs](https://example.test/docs)\n\n" + String(repeating: "Extractor room page text. ", count: 700)
        let orchestrator = WebOrchestrator()
        await orchestrator.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        WebSearchBackend.processOverride = nil
        defer { WebSearchBackend.processOverride = .opencode }
        var urlCounter = 0
        func nextURL() -> String { urlCounter += 1; return "https://example.test/room-\(urlCounter)" }
        func extract(_ focus: String) async -> (WebOrchestrator.WebExtractOutcome?, [WebFixtureServer.Request]) {
            let url = nextURL()
            fixtures.pages[url] = page
            serverD.clear()
            let outcome = await withMainSlots(routerMain) {
                try? await orchestrator.executeWebExtract(requests: [.init(url: url, focus: focus)], mode: .webSearch)
            }
            return (outcome, serverD.requests)
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

        // 20.1 Output room on every follow stage.
        scripts.reset()
        let (plain, plainReqs) = await extract("room cap")
        let (plainFetch, fetchReqs) = await fetch("room cap fetch")
        let followStages = (plainReqs + fetchReqs).filter { stageOf($0) != nil }
        let stagesSeen = Set(followStages.compactMap(stageOf))
        check("20.1 OpenRouter follow: extract.excerpts (one pass, no assets request) and web_fetch compression send no output cap, effort medium as on the OpenAI lane (reasoning never capped or disabled)",
              stagesSeen == ["excerpts", "compression"]
              && followStages.allSatisfy { uncapped($0) && (body($0)["reasoning"] as? [String: Any])?["effort"] as? String == "medium"
                  && (body($0)["reasoning"] as? [String: Any])?["max_tokens"] == nil && (body($0)["reasoning"] as? [String: Any])?["enabled"] == nil }
              && plain?.docs.isEmpty == false && plainFetch?.contains("COMPRESSED: room page") == true,
              "\(followStages.map { "\(stageOf($0) ?? "?"):\(body($0)["max_tokens"] ?? "none")" })")

        // 20.2 Length-starved on OpenAI (a host default cap) → the retry excludes OpenAI.
        scripts.reset()
        scripts.push("excerpts", starved("OpenAI", id: "gen-fixture-starved"))
        let (starvedOut, starvedReqs) = await extract("room starved")
        let starvedEx = starvedReqs.filter { stageOf($0) == "excerpts" }
        check("20.2 length-starved excerpts reply (finish length, 0 content) from OpenAI: exactly one retry, pinned set minus openai, still uncapped, body otherwise identical; the retry's excerpts are used",
              starvedEx.count == 2 && only(starvedEx[0]) == ["openai", "azure"] && only(starvedEx[1]) == ["azure"]
              && uncapped(starvedEx[1]) && sameButProvider(starvedEx[0], starvedEx[1])
              && (body(starvedEx[1])["provider"] as? [String: Any])?["sort"] == nil
              && (body(starvedEx[1])["provider"] as? [String: Any])?["require_parameters"] as? Bool == true
              && starvedOut?.docs.first?.excerpts == ["# Room page"],
              "\(starvedEx.map { only($0) ?? [] }) \(starvedOut?.docs.first?.excerpts ?? [])")
        check("20.3 spend counts the failed (billed) attempt: 0.02 starved + 0.0003 per successful stage call",
              near(starvedOut?.spendUSD, 0.02 + 0.0003 * Double(starvedReqs.count - 1)), "\(starvedOut?.spendUSD ?? -1) over \(starvedReqs.count) calls")
        let log1 = logText()
        check("20.4 diagnostics: the failed attempt's log line names kind, host, finish and native reasons, completion/reasoning tokens, generation id and cost; no opaque body snippet",
              log1.contains("openrouter stage=extract.excerpts NO_COMPLETION attempt=1/3 kind=length_starved provider=OpenAI finish=length native=length completion_tokens=32000 reasoning_tokens=31990 gen=gen-fixture-starved")
              && log1.contains("cost=0.02") && log1.contains("retrying (attempt 2/3) hosts=azure excluded=openai")
              && !log1.contains("openrouter stage=extract.excerpts returned no completion"),
              String(log1.components(separatedBy: "\n").filter { $0.contains("NO_COMPLETION") || $0.contains("retrying") }.joined(separator: " | ").prefix(600)))

        // 20.5 Repetition on both pinned hosts in turn → the third attempt
        // gets the full pinned set again (never an empty or unpinned route).
        scripts.reset()
        scripts.push("excerpts", repeated("Azure", id: "gen-rep-1"))
        scripts.push("excerpts", repeated("OpenAI", id: "gen-rep-2"))
        let (repOut, repReqs) = await extract("room repetition")
        let repAssets = repReqs.filter { stageOf($0) == "excerpts" }
        check("20.5 repetition (native_finish_reason repetition, no content) from Azure then OpenAI: the second attempt excludes Azure, the third (both failed) restores the full pinned set, uncapped, 3 attempts; links kept",
              repAssets.count == 3 && only(repAssets[0]) == ["openai", "azure"] && only(repAssets[1]) == ["openai"] && only(repAssets[2]) == ["openai", "azure"]
              && repAssets.allSatisfy(uncapped) && sameButProvider(repAssets[0], repAssets[2])
              && repOut?.docs.first?.links.map(\.url) == ["https://example.test/docs"],
              "\(repAssets.map { only($0) ?? [] }) links \(repOut?.docs.first?.links.map(\.url) ?? [])")
        check("20.6 spend counts both failed repetition attempts (0.004 each) plus the successful calls",
              near(repOut?.spendUSD, 0.008 + 0.0003 * Double(repReqs.count - 2)), "\(repOut?.spendUSD ?? -1) over \(repReqs.count) calls")
        check("20.7 repetition diagnostics name the host and the native reason",
              logText().contains("NO_COMPLETION attempt=1/3 kind=repetition provider=Azure finish=stop native=repetition completion_tokens=4100 reasoning_tokens=4100 gen=gen-rep-1"))

        // 20.8 Empty body: host unknown → same hosts, logged as empty_body; nothing billed.
        scripts.reset()
        scripts.push("excerpts", "  \n\n   \n")
        let (emptyOut, emptyReqs) = await extract("room empty")
        let emptyEx = emptyReqs.filter { stageOf($0) == "excerpts" }
        check("20.8 empty (whitespace-only) body: retried once on the same pinned hosts (the failing host is unknown), logged kind=empty_body with its byte count, no spend for it",
              emptyEx.count == 2 && only(emptyEx[1]) == ["openai", "azure"] && sameButProvider(emptyEx[0], emptyEx[1])
              && emptyOut?.docs.first?.excerpts == ["# Room page"]
              && near(emptyOut?.spendUSD, 0.0003 * Double(emptyReqs.count - 1))
              && logText().contains("stage=extract.excerpts NO_COMPLETION attempt=1/3 kind=empty_body provider=- finish=- native=- completion_tokens=- reasoning_tokens=- gen=- body_bytes=")
              && logText().contains("retrying (attempt 2/3) same hosts (failing host unknown)"),
              "\(emptyEx.map { only($0) ?? [] }) spend \(emptyOut?.spendUSD ?? -1)")

        // 20.9 Provider error object in a 2xx body names its host → steered.
        scripts.reset()
        scripts.push("compression", providerError)
        let (errFetch, errReqs) = await fetch("room provider error")
        let errComp = errReqs.filter { stageOf($0) == "compression" }
        check("20.9 a 2xx error object whose metadata names OpenAI: logged kind=provider_error with the message, retried without openai",
              errComp.count == 2 && only(errComp[1]) == ["azure"] && errFetch?.contains("COMPRESSED: room page") == true
              && logText().contains("kind=provider_error provider=OpenAI"),
              "\(errComp.map { only($0) ?? [] })")

        // 20.10 Three failures: the ceiling holds, the error names the cause.
        scripts.reset()
        scripts.push("compression", starved("OpenAI", id: "gen-x1"))
        scripts.push("compression", starved("Azure", id: "gen-x2"))
        scripts.push("compression", starved("OpenAI", id: "gen-x3"))
        let (exhaustedFetch, exReqs) = await fetch("room exhausted")
        let exComp = exReqs.filter { stageOf($0) == "compression" }
        check("20.10 three length-starved attempts: exactly 3 requests (openai,azure → azure → openai,azure once both failed), then the stage fails with the named cause and web_fetch falls back to raw markdown",
              exComp.count == 3 && only(exComp[0]) == ["openai", "azure"] && only(exComp[1]) == ["azure"] && only(exComp[2]) == ["openai", "azure"]
              && exhaustedFetch?.contains("Extractor room page text.") == true
              && logText().contains("after 3 attempts: length_starved from OpenAI"),
              "\(exComp.map { only($0) ?? [] })")

        // 20.11 Non-follow OpenRouter backend (/websearch openrouter, Luna):
        // cap unchanged, no steering; diagnostics and spend still apply.
        scripts.reset()
        scripts.push("excerpts", starved("OpenAI", id: "gen-nf"))
        let nfURL = nextURL()
        fixtures.pages[nfURL] = page
        serverD.clear()
        WebSearchBackend.processOverride = .openrouter
        await orchestrator.configure(openRouterKey: "synthetic-or-key", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        let nfOut = try? await orchestrator.executeWebExtract(requests: [.init(url: nfURL, focus: "non-follow")], mode: .webSearch)
        WebSearchBackend.processOverride = nil
        let nfReqs = serverD.requests
        let nfEx = nfReqs.filter { stageOf($0) == "excerpts" }, nfAssets = nfReqs.filter { stageOf($0) == "assets" }
        check("20.11 /websearch openrouter without the follow: the Luna model is unchanged, no cap on any stage, the retry is NOT steered (identical body), but the failed attempt is logged and counted in spend",
              nfEx.count == 2 && body(nfEx[0])["model"] as? String == ORModel.webExcerpts
              && nfAssets.isEmpty && nfEx.allSatisfy(uncapped)
              && sameBody(body(nfEx[0]), body(nfEx[1]))
              && (nfOut?.spendUSD ?? 0) >= 0.02 - 1e-12
              && logText().contains("gen=gen-nf"),
              "\(nfEx.map { only($0) ?? ["nil"] }) \(nfOut?.spendUSD ?? -1)")

        // 20.12 Other backends: no cap on OpenCode either (owner rule: none anywhere).
        serverB.clear(); serverD.clear()
        WebSearchBackend.processOverride = .opencode
        let ocURL = nextURL()
        fixtures.pages[ocURL] = page
        _ = try? await orchestrator.executeWebExtract(requests: [.init(url: ocURL, focus: "opencode room")], mode: .webSearch)
        _ = try? await orchestrator.readUrlContentWithMetadata(url: ocURL, prompt: "opencode room fetch", refresh: true)
        let ocStages = serverB.requests.filter { stageOf($0) != nil }
        check("20.12 OpenCode backend: excerpts (one pass) and web_fetch compression send no output cap (was 8000/32000/8000), no provider block, the pipeline model (GPT-6 Luna over Responses since v0.2.44); nothing reaches OpenRouter",
              !ocStages.isEmpty && ocStages.allSatisfy { uncapped($0) && body($0)["provider"] == nil && body($0)["model"] as? String == "gpt-6-luna" && $0.path.hasSuffix("/zen/go/v1/responses") }
              && Set(ocStages.compactMap(stageOf)) == ["excerpts", "compression"]
              && serverD.requests.filter { stageOf($0) != nil }.isEmpty,
              "\(ocStages.map { "\(stageOf($0) ?? "?"):\(body($0)["max_tokens"] ?? "none")" })")
        WebSearchBackend.processOverride = nil

        // 20.13 Pure rules: classifier, host slugs, steering never empties the set.
        func classify(_ s: String) -> StageNoCompletion { StageNoCompletion.classify(Data(s.utf8)) }
        let pinned = ORChatReq.Provider(order: nil, only: WebSearchBackend.openRouterExtractorHosts, allow_fallbacks: true, sort: nil)
        check("20.13 classifier + helpers: length/repetition/empty/error/no-content/unparseable kinds; usage decoded for spend; display names map to pinned slugs (Cohere, Bedrock and the former DeepSeek hosts Reka, DigitalOcean and Makora do not); excluding every host restores the full set",
              classify(starved("OpenAI", id: "g")).kind == .lengthStarved && classify(starved("OpenAI", id: "g")).usage?.cost?.value == 0.02
              && classify(repeated("Azure", id: "g")).kind == .repetition && classify(" \n").kind == .emptyBody
              && classify(providerError).kind == .providerError && classify(providerError).provider == "OpenAI"
              && classify(envelope(content: "", provider: "OpenAI", finish: "stop", native: "stop", completion: 3, reasoning: 0, cost: 0, id: "g")).kind == .noContent
              && classify("<html>bad gateway</html>").kind == .unparseable
              && WebSearchBackend.extractorHostSlug(servedBy: "Azure") == "azure" && WebSearchBackend.extractorHostSlug(servedBy: "OpenAI") == "openai"
              && WebSearchBackend.extractorHostSlug(servedBy: "Cohere") == nil && WebSearchBackend.extractorHostSlug(servedBy: nil) == nil
              && WebSearchBackend.extractorHostSlug(servedBy: "Makora") == nil && WebSearchBackend.extractorHostSlug(servedBy: "Reka") == nil
              && WebSearchBackend.extractorHostSlug(servedBy: "DigitalOcean") == nil && WebSearchBackend.extractorHostSlug(servedBy: "Amazon Bedrock") == nil
              && WebSearchBackend.steeredProvider(pinned, excluding: ["openai", "azure"]).only == ["openai", "azure"])
        check("20.14 host pin is exactly openai + azure for GPT-6 Luna (standard list-price endpoints; the DeepSeek hosts Reka/DigitalOcean are gone since 2026-09-30, Makora since 2026-09-29)",
              WebSearchBackend.openRouterExtractorHosts == ["openai", "azure"], "\(WebSearchBackend.openRouterExtractorHosts)")
    }
}

/// Per-stage scripted replies for group 20 (thread-safe: the fixture server
/// answers on its own thread).
final class StageScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [String]] = [:]
    func reset() { lock.lock(); queues = [:]; lock.unlock() }
    func push(_ stage: String, _ body: String) { lock.lock(); queues[stage, default: []].append(body); lock.unlock() }
    func pop(_ stage: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var q = queues[stage], !q.isEmpty else { return nil }
        let first = q.removeFirst(); queues[stage] = q
        return first
    }
}
