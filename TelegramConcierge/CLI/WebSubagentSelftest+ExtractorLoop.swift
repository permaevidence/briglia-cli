import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Group 22 (extractor redesign, 2026-09-29/30). DeepSeek V4 Flash at
// temperature 0.1 looped in its hidden reasoning; a separate extract.assets
// request picked links it could not see in context; quotes were retyped.
// Now: no temperature on any request, and ONE extraction request per chunk
// that writes no text: the page is split into numbered blocks, every link
// and image numbered inside them (page-wide); the model answers with block
// numbers/ranges and link/image numbers; Briglia copies the blocks verbatim
// from the original and maps numbers to exact URLs. Pages ≤ 8,000 chars make
// no model call. Nothing is dropped by category; no candidate or pick cap.
extension WebSubagentSelftest {
    struct LoopKit {
        let check: (String, Bool, String) -> Void
        let body: (WebFixtureServer.Request) -> [String: Any]
        let stageOf: (WebFixtureServer.Request) -> String?
        let userContent: (WebFixtureServer.Request) -> String
        let logText: () -> String
        let extract: (String, String) async -> (WebOrchestrator.WebExtractOutcome?, [WebFixtureServer.Request])
        let scripts: StageScripts
        let envelope: (String?, String, String, String, Double) -> String
    }

    /// A shop-like page: reader header, a self-anchor, 60 titled menu links,
    /// the product heading, body links wrapping images, text, then a footer
    /// (login, social, privacy, returns — never dropped by category).
    static let loopShopPage: String = {
        var menu = ""
        for i in 1...60 { menu += "[MENU\(i)](https://shop.test/menu/\(i) \"MENU\(i)\")\n\n" }
        let bodyLinks = ["Widget X100 spare cable", "Widget X100 manual PDF", "Wall mount for X100", "X100 battery pack", "Compare X100 and X200"]
        var body = "# Widget X100 Pro\n\n![Image 7: Widget X100 front view](https://cdn.shop.test/x100-front.jpg)\n\n"
        for (i, text) in bodyLinks.enumerated() { body += "[\(text) ![Image \(10 + i): \(text)](https://cdn.shop.test/p\(i).png?ts=1) Details](https://shop.test/p/x100-\(i) \"\(text)\")\n\n" }
        body += String(repeating: "The Widget X100 Pro is a sample product. ", count: 40) + "\n\n"
        body += "See the [manual again](https://shop.test/p/x100-1) and [the top](#top) or [js](javascript:void(0)).\n\n"
        let footer = "[Login](https://shop.test/login)\n\n[Instagram](https://instagram.com/shop)\n\n[Privacy](https://shop.test/privacy)\n\n[Returns](https://shop.test/returns \"Returns\")\n\n"
        return "Title: Widget X100 Pro\n\nURL Source: https://shop.test/p/x100\n\nMarkdown Content:\n[Skip to content](https://shop.test/p/x100#main)\n\n"
            + menu + body + footer + String(repeating: "Filler text so the page is not small. ", count: 250)
    }()

    static func runExtractorLoopGroup(_ h: Harness) async throws {
        print("22. Extractor redesign: no temperature, one-pass block selection + numbered link picks, generation lookup logging")
        let fixtures = h.fixtures, serverB = h.serverB, serverD = h.serverD
        let body = h.body
        let stageOf: (WebFixtureServer.Request) -> String? = { request in
            let t = String(decoding: request.body, as: UTF8.self)
            if t.contains("Select the parts of the provided TEXT") { return "excerpts" }
            if t.contains("You extract information from a web page") { return "compression" }
            return nil
        }
        let envelope: (String?, String, String, String, Double) -> String = { content, finish, native, id, cost in
            var message: [String: Any] = ["role": "assistant", "reasoning": "thinking"]
            message["content"] = content ?? NSNull()
            let object: [String: Any] = [
                "id": id, "object": "chat.completion", "created": 1_790_000_000, "model": "openai/gpt-6-luna",
                "provider": "OpenAI", "choices": [["index": 0, "finish_reason": finish, "native_finish_reason": native, "message": message]],
                "usage": ["prompt_tokens": 9000, "completion_tokens": 700, "total_tokens": 9700, "cost": cost,
                          "completion_tokens_details": ["reasoning_tokens": 500]]]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        let scripts = StageScripts()
        let baseRoute = serverD.route
        serverD.route = { request in
            guard let stage = stageOf(request) else { return baseRoute?(request) ?? .init(status: 500, body: "{}") }
            if let scripted = scripts.pop(stage) { return .init(body: scripted) }
            return .init(body: envelope(stage == "excerpts" ? "{\"blocks\":[\"P1\"],\"links\":[1],\"images\":[1]}" : "COMPRESSED: loop page",
                                        "stop", "stop", "gen-loop-ok", 0.0003))
        }
        defer { serverD.route = baseRoute }
        let routerMain: [String: String?] = [ProviderProfiles.activeProfileKey: "openrouter", KeychainHelper.llmProviderKey: LLMProvider.openRouter.rawValue,
                                             KeychainHelper.openRouterApiKeyKey: "synthetic-or-key",
                                             KeychainHelper.openRouterModelKey: "deepseek/deepseek-v4.1-flash", KeychainHelper.openRouterReasoningEffortKey: "medium",
                                             ProviderProfiles.runtimeProtocolKey: nil]
        let orchestrator = WebOrchestrator()
        await orchestrator.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        WebSearchBackend.processOverride = nil
        defer { WebSearchBackend.processOverride = .opencode }
        var urlCounter = 0
        func nextURL() -> String { urlCounter += 1; return "https://example.test/loop-\(urlCounter)" }
        func extract(_ page: String, _ focus: String) async -> (WebOrchestrator.WebExtractOutcome?, [WebFixtureServer.Request]) {
            let url = nextURL()
            fixtures.pages[url] = page
            serverD.clear()
            let outcome = await withMainSlots(routerMain) {
                try? await orchestrator.executeWebExtract(requests: [.init(url: url, focus: focus)], mode: .webSearch)
            }
            return (outcome, serverD.requests)
        }
        let kit = LoopKit(
            check: { h.check($0, $1, $2) }, body: body, stageOf: stageOf,
            userContent: { ((body($0)["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? "" },
            logText: { WebPipelineLog.shared.flushForTesting(); return (try? String(contentsOfFile: WebPipelineLog.shared.logFilePath, encoding: .utf8)) ?? "" },
            extract: extract, scripts: scripts, envelope: envelope)
        let noTemperatureNoCap: (WebFixtureServer.Request) -> Bool = { r in
            let b = body(r)
            return b["temperature"] == nil && b["max_tokens"] == nil && b["max_completion_tokens"] == nil && b["max_output_tokens"] == nil
        }

        // 22.1 OpenRouter follow: no temperature, no cap, on every stage.
        let (_, shopReqs) = await extract(loopShopPage, "Widget X100 battery pack and wall mount")
        let fetchURL = nextURL()
        fixtures.pages[fetchURL] = loopShopPage
        serverD.clear()
        _ = await withMainSlots(routerMain) { try? await orchestrator.readUrlContentWithMetadata(url: fetchURL, prompt: "Widget X100 accessories", refresh: true) }
        let orStages = (shopReqs + serverD.requests).filter { stageOf($0) != nil }
        kit.check("22.1 OpenRouter follow: extract.excerpts and web_fetch compression send NO temperature (was 0.1) and still no output cap; reasoning effort medium (the OpenAI lane's)",
                  Set(orStages.compactMap(stageOf)) == ["excerpts", "compression"] && orStages.allSatisfy(noTemperatureNoCap)
                  && orStages.allSatisfy { (body($0)["reasoning"] as? [String: Any])?["effort"] as? String == "medium" },
                  "\(orStages.map { "\(stageOf($0) ?? "?"):t=\(body($0)["temperature"] ?? "none")" })")

        // 22.2 OpenCode backend: same.
        serverB.clear()
        WebSearchBackend.processOverride = .opencode
        let ocURL = nextURL()
        fixtures.pages[ocURL] = loopShopPage
        _ = try? await orchestrator.executeWebExtract(requests: [.init(url: ocURL, focus: "opencode loop")], mode: .webSearch)
        _ = try? await orchestrator.readUrlContentWithMetadata(url: ocURL, prompt: "opencode loop fetch", refresh: true)
        WebSearchBackend.processOverride = nil
        let ocStages = serverB.requests.filter { stageOf($0) != nil }
        kit.check("22.2 OpenCode backend: excerpts and web_fetch compression send NO temperature (was 0.1) and no output cap; the reasoning effort still sent (Responses reasoning.effort medium since v0.2.44)",
                  Set(ocStages.compactMap(stageOf)) == ["excerpts", "compression"] && ocStages.allSatisfy(noTemperatureNoCap)
                  && ocStages.allSatisfy { (body($0)["reasoning"] as? [String: Any])?["effort"] as? String == "medium" },
                  "\(ocStages.map { "\(stageOf($0) ?? "?"):t=\(body($0)["temperature"] ?? "none")" })")

        try await runExtractorOnePassRows(kit, shopRequests: shopReqs)
        try await runExtractorLookupLogRows(kit)
    }

    /// 22.10–22.11: background generation lookups after a failed attempt.
    static func runExtractorLookupLogRows(_ kit: LoopKit) async throws {
        CutRequestCostLookup.recordOverride = { gen in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard gen == "gen-loop-starved" else { return nil }
            var record = OpenRouterGenerationRecord(totalCost: 0, cancelled: true, provider: "OpenAI")
            record.upstreamStatus = 499; record.completionTokens = 31540; record.reasoningTokens = 31540; record.promptTokens = 17920
            return record
        }
        defer { CutRequestCostLookup.recordOverride = { _ in nil } }
        func waitLine(_ needle: String) async -> String {
            var line = ""
            for _ in 0..<90 where line.isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
                line = kit.logText().components(separatedBy: "\n").last { $0.contains(needle) } ?? ""
            }
            return line
        }
        kit.scripts.reset()
        kit.scripts.push("excerpts", kit.envelope("", "length", "length", "gen-loop-starved", 0.01))
        let started = ProcessInfo.processInfo.systemUptime
        _ = await kit.extract(loopShopPage, "starved loop")
        let stageSeconds = ProcessInfo.processInfo.systemUptime - started
        let lineBefore = kit.logText().contains("GENERATION_LOOKUP gen=gen-loop-starved")
        let lookupLine = await waitLine("GENERATION_LOOKUP gen=gen-loop-starved")
        kit.check("22.10 a failed attempt (length-starved, generation id known) gets its generation record looked up off the critical path: the stage finished before the lookup returned, then the log names host, upstream status, cancelled, tokens and cost",
                  !lineBefore && stageSeconds < 4.0
                  && lookupLine.contains("stage=extract.excerpts GENERATION_LOOKUP gen=gen-loop-starved after=length_starved provider=OpenAI upstream_status=499 cancelled=true")
                  && lookupLine.contains("completion_tokens=31540 reasoning_tokens=31540") && lookupLine.contains("cost=0"),
                  "stage \(String(format: "%.2f", stageSeconds))s line: \(lookupLine)")
        kit.scripts.reset()
        kit.scripts.push("excerpts", kit.envelope("", "length", "length", "gen-loop-missing", 0.0003))
        _ = await kit.extract(loopShopPage, "starved loop missing")
        let missingLine = await waitLine("GENERATION_LOOKUP gen=gen-loop-missing")
        kit.check("22.11 no record found: the lookup logs not_found after its bounded tries (one line, no retry loop)",
                  missingLine.contains("after=length_starved not_found tries=1"), missingLine)
    }
}
