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
            if request.path.hasPrefix("/deadline-direct") { return queue.pop("direct") ?? .init(status: 500, body: "{}") }
            guard let stage = stageOf(request) else { return baseRoute?(request) ?? .init(status: 500, body: "{}") }
            return queue.pop(stage) ?? .init(body: okBody(stage, provider: "DigitalOcean"))
        }
        defer { serverD.route = baseRoute }
        defer { WebSearchBackend.extractorDeadlineOverride = nil }
        // Spend accounting on a scratch directory (never the real data root).
        let ledgerDir = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-websub-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        let previousLedgerDir = ToolChargeLedger.directoryForTesting
        ToolChargeLedger.directoryForTesting = ledgerDir
        ToolChargeLedger.resetForTesting()
        defer {
            ToolChargeLedger.resetForTesting()
            ToolChargeLedger.directoryForTesting = previousLedgerDir
            try? FileManager.default.removeItem(at: ledgerDir)
            CutRequestCostLookup.lookupOverride = nil
        }
        func incidents() -> [SpendIncident] {
            if case .readable(let list) = ToolChargeLedger.loadIncidents() { return list }
            return []
        }
        func incident(gen: String?) -> SpendIncident? {
            incidents().first { $0.generationId == gen && $0.detail?.hasPrefix(ToolChargeLedger.cutRequestDetailPrefix) == true }
        }

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
        check("21.3 spend: the known spend is the successful calls only (the cut attempt reports no usage and is never counted as a number)",
              cutOut.map { abs($0.spendUSD - 0.0003 * Double(cutReqs.count - 1)) < 1e-12 } ?? false,
              "\(cutOut?.spendUSD ?? -1) over \(cutReqs.count) calls")
        let cutIncident = incident(gen: "gen-dl-runaway")
        let cutSnap = ToolChargeLedger.snapshot()
        check("21.3b R1 cut then success: the cut request is a durable OPEN unknown-amount incident for today keyed by its generation id and host; the tool-charge snapshot is incomplete and lists it, and holds no invented amount",
              cutIncident?.kind == .unknownAmount && cutIncident?.state == .open
              && cutIncident?.periods == [ToolChargeLedger.dayKey(Date())]
              && cutIncident?.detail?.contains("host DigitalOcean") == true
              && logText().contains("gen=gen-dl-runaway cost=unknown incident=\(cutIncident?.id ?? "?")")
              && !cutSnap.isComplete && cutSnap.incidents.contains { $0.id == cutIncident?.id }
              && cutSnap.today == 0
              && cutSnap.incidents.map(ToolChargeLedger.describe).contains { $0.hasPrefix("unknown cost of a web extraction request cut at its deadline") },
              "\(String(describing: cutIncident)) today=\(cutSnap.today)")

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
        let allCut = ["gen-dl-x1", "gen-dl-x2", "gen-dl-x3"].compactMap { incident(gen: $0) }
        check("21.6b R1 all cuts: each of the three cut requests is its own open unknown-amount incident (distinct ids), none settled as zero",
              allCut.count == 3 && Set(allCut.map(\.id)).count == 3 && allCut.allSatisfy { $0.state == .open }
              && ToolChargeLedger.snapshot().today == 0,
              "\(allCut.map(\.id))")

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

        let cancelledIncidents = incidents().filter { $0.detail?.contains("cancelled while open") == true }.count
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

        // ---- Round 3 (review of the deadline commit).

        // 21.9 R2: the transport backoff is inside the total deadline. A
        // 0.25 s deadline and an immediate 503 with Retry-After: 2 must not
        // sleep the 2 s: one request, the deadline error at once, nothing in
        // flight (so no unknown charge).
        let directURL = URL(string: "http://127.0.0.1:\(serverD.port)/deadline-direct")!
        func direct(_ deadlineSeconds: TimeInterval) async -> (Result<Data, Error>, [WebFixtureServer.Request], TimeInterval) {
            serverD.clear()
            let d = ExtractorDeadline(seconds: deadlineSeconds)
            let t0 = now()
            do {
                let data = try await httpJSONPostWithRetry(url: directURL, body: ["probe": "r3"], headers: [:], timeout: 30,
                                                           label: "deadline-direct", fetch: { @Sendable r in try await d.fetch(r) }, deadline: d)
                return (.success(data), serverD.requests.filter { $0.path.hasPrefix("/deadline-direct") }, now() - t0)
            } catch {
                return (.failure(error), serverD.requests.filter { $0.path.hasPrefix("/deadline-direct") }, now() - t0)
            }
        }
        queue.reset()
        queue.push("direct", .init(status: 503, body: "{\"error\":\"busy\"}", headers: ["Retry-After": "2"]))
        let (r2, r2Reqs, r2Elapsed) = await direct(0.25)
        let r2Error: ExtractorDeadlineExceeded? = { if case .failure(let e) = r2 { return e as? ExtractorDeadlineExceeded }; return nil }()
        check("21.9 R2 a 0.25 s deadline with an immediate 503 + Retry-After: 2 ends within the deadline envelope (not after the 2 s backoff): exactly 1 request, the deadline error, no request in flight",
              r2Reqs.count == 1 && r2Error != nil && r2Error?.requestInFlight == false && r2Elapsed < 1.0,
              "\(r2Reqs.count) requests, \(String(format: "%.3f", r2Elapsed))s, \(r2)")
        queue.reset()
        queue.push("direct", .init(status: 503, body: "{\"error\":\"busy\"}", headers: ["Retry-After": "1"]))
        queue.push("direct", .init(body: "{\"ok\":true}"))
        let (r2ok, r2okReqs, _) = await direct(5)
        check("21.9b R2 control: a backoff that fits inside the deadline still retries (2 requests, success)",
              r2okReqs.count == 2 && (try? r2ok.get()) != nil, "\(r2okReqs.count) requests \(r2ok)")

        // 21.10 R3: identity is per transport attempt. First 503 names Reka
        // and gen-old; the second answers anonymous 200 headers and trickles
        // until the deadline: the cut must not inherit Reka/gen-old.
        queue.reset()
        queue.push("direct", .init(status: 503, body: "{\"error\":\"busy\"}", headers: ["X-Provider-Name": "Reka", "X-Generation-Id": "gen-old", "Retry-After": "0"]))
        queue.push("direct", .init(body: "", trickle: (interval: 0.2, duration: 30)))
        let (r3a, r3aReqs, _) = await direct(2)
        let r3aError: ExtractorDeadlineExceeded? = { if case .failure(let e) = r3a { return e as? ExtractorDeadlineExceeded }; return nil }()
        check("21.10 R3 an anonymous second response cut at the deadline is reported with NO host and NO generation id (gen-old kept apart as an earlier attempt), in flight; exactly 2 requests",
              r3aReqs.count == 2 && r3aError?.requestInFlight == true && r3aError?.provider == nil && r3aError?.generationId == nil
              && r3aError?.earlierGenerationIds == ["gen-old"],
              "\(r3aReqs.count) requests \(String(describing: r3aError))")
        // 21.11 The second attempt receives no headers at all before expiry.
        queue.reset()
        queue.push("direct", .init(status: 503, body: "{\"error\":\"busy\"}", headers: ["X-Provider-Name": "Reka", "X-Generation-Id": "gen-old2", "Retry-After": "0"]))
        queue.push("direct", .init(body: "", silentFor: 8))
        let (r3b, r3bReqs, _) = await direct(2)
        let r3bError: ExtractorDeadlineExceeded? = { if case .failure(let e) = r3b { return e as? ExtractorDeadlineExceeded }; return nil }()
        check("21.11 R3 a second attempt that receives no headers before the deadline is reported with no host and no generation id (gen-old2 earlier), in flight; exactly 2 requests",
              r3bReqs.count == 2 && r3bError?.requestInFlight == true && r3bError?.provider == nil && r3bError?.generationId == nil
              && r3bError?.earlierGenerationIds == ["gen-old2"],
              "\(r3bReqs.count) requests \(String(describing: r3bError))")
        // 21.11b A late callback of an older attempt cannot rename the current one.
        let lateDeadline = ExtractorDeadline(seconds: 60)
        let firstAttempt = lateDeadline.beginAttempt()
        _ = lateDeadline.beginAttempt()
        lateDeadline.observe(HTTPURLResponse(url: directURL, statusCode: 200, httpVersion: nil,
                                             headerFields: ["X-Provider-Name": "Reka", "X-Generation-Id": "gen-late"])!, attempt: firstAttempt)
        let lateCut = lateDeadline.exceeded(requestInFlight: true)
        check("21.11b R3 headers delivered late by an older attempt are ignored for the current attempt",
              lateCut.provider == nil && lateCut.generationId == nil, "\(lateCut)")

        // 21.12 The response-format fallback resends within the SAME attempt
        // and deadline: a 400 rejecting response_format after 1.2 s, then a
        // runaway, is cut at ~2 s from the attempt start (not 3.2 s).
        WebSearchBackend.extractorDeadlineOverride = 2
        queue.reset()
        queue.push("excerpts", .init(status: 400, body: "{\"error\":{\"message\":\"response_format json_schema is not supported by this provider\"}}",
                                     trickle: (interval: 0.2, duration: 1.2)))
        queue.push("excerpts", runaway(gen: "gen-dl-fmt", provider: "Reka"))
        let (fmtOut, fmtReqs, fmtTotal) = await extract("deadline format fallback")
        let fmtEx = fmtReqs.filter { stageOf($0) == "excerpts" }
        let fmtLine = logText().components(separatedBy: "\n").last { $0.contains("gen=gen-dl-fmt ") } ?? ""
        // Attempt 1 = 2 s (400 at 1.2 s + resend cut at the SAME 2 s clock),
        // then the 1.5 s pause and a fast attempt 2: ~3.5 s. A fresh clock
        // for the resend would make attempt 1 last 3.2 s (~4.7 s total).
        check("21.12 the response_format fallback shares the attempt's deadline: the resent request is cut when the attempt's 2 s clock runs out (total ~3.5 s, not ~4.7 s), then attempt 2 answers",
              fmtEx.count == 3 && fmtLine.contains("attempt=1/3") && fmtTotal >= 3.3 && fmtTotal < 4.3
              && fmtOut?.docs.first?.excerpts == ["deadline excerpt"],
              "\(fmtEx.count) requests, total \(String(format: "%.2f", fmtTotal))s")

        // 21.13 Restart: the unknown stays (the incident is on disk).
        ToolChargeLedger.forgetHeldForTesting()
        let afterRestart = incident(gen: "gen-dl-runaway")
        check("21.13 R1 restart: a cut request's unknown-amount incident survives a restart (on disk) and still makes the snapshot incomplete",
              afterRestart?.state == .open && !ToolChargeLedger.snapshot().isComplete, "\(String(describing: afterRestart))")

        // 21.14 Later usage recovery, deduplicated across lookups/restarts.
        let costs: [String: Double] = ["gen-dl-runaway": 0.0042, "gen-dl-x1": 0]
        let lookup: (String) async -> Double? = { gen in costs[gen] }
        let settledFirst = await ToolChargeLedger.reconcileCutRequests(lookup: lookup)
        let recovered = incident(gen: "gen-dl-runaway")
        let zeroCost = incident(gen: "gen-dl-x1")
        let todayAfter = ToolChargeLedger.snapshot().today
        let ledgerEntries: [ToolChargeEntry] = { if case .readable(_, let e, _) = ToolChargeLedger.loadLedger() { return e }; return [] }()
        check("21.14 R1 later usage recovery: a looked-up cost settles exactly that cut request (ledger entry kind web-cut under the incident's id, dated at the cut; incident closed); a reported $0 or a missing record leaves the others unknown",
              settledFirst == 1 && recovered?.state == .closed && zeroCost?.state == .open
              && ledgerEntries.filter { $0.kind == ToolChargeLedger.cutRequestChargeKind }.count == 1
              && ledgerEntries.first { $0.kind == ToolChargeLedger.cutRequestChargeKind }.map {
                  "unknown-amount:\($0.chargeId.uuidString.lowercased())" == recovered?.id && abs($0.amountUSD - 0.0042) < 1e-12 } == true
              && abs(todayAfter - 0.0042) < 1e-12,
              "settled \(settledFirst) today \(todayAfter) \(ledgerEntries)")
        ToolChargeLedger.forgetHeldForTesting()
        let settledAgain = await ToolChargeLedger.reconcileCutRequests(lookup: lookup)
        let entriesAgain: [ToolChargeEntry] = { if case .readable(_, let e, _) = ToolChargeLedger.loadLedger() { return e }; return [] }()
        check("21.14b R1 dedup: looking up again (after a simulated restart) settles nothing new and never counts the recovered cost twice",
              settledAgain == 0 && entriesAgain.filter { $0.kind == ToolChargeLedger.cutRequestChargeKind }.count == 1
              && abs(ToolChargeLedger.snapshot().today - 0.0042) < 1e-12,
              "settled \(settledAgain) \(entriesAgain.count) entries")
        check("21.14c the generation record parser reads data.total_cost and nothing else",
              CutRequestCostLookup.parseTotalCost(Data("{\"data\":{\"id\":\"gen-x\",\"total_cost\":0.0123,\"provider_name\":\"Reka\"}}".utf8)) == 0.0123
              && CutRequestCostLookup.parseTotalCost(Data("{\"error\":{\"code\":404}}".utf8)) == nil
              && CutRequestCostLookup.parseTotalCost(Data("{\"data\":{\"id\":\"gen-x\"}}".utf8)) == nil)

        // 21.15 Configured cap: a cut opens an unknown, so the cap can't be
        // verified and the paid retry does not start; /spend accept-unknown
        // (acceptance of the incidents open now) lets paid work resume.
        ToolChargeLedger.resetForTesting()
        let capped = routerMain.merging([KeychainHelper.openRouterToolSpendLimitDailyUSDKey: "50"]) { _, new in new }
        WebSearchBackend.extractorDeadlineOverride = 1
        queue.reset()
        queue.push("excerpts", runaway(gen: "gen-dl-cap", provider: "Reka"))
        let capURL = nextURL()
        fixtures.pages[capURL] = page
        serverD.clear()
        let (_, pauseAfterCut): (WebOrchestrator.WebExtractOutcome?, String?) = await withMainSlots(capped) {
            let out = try? await orchestrator.executeWebExtract(requests: [.init(url: capURL, focus: "deadline cap")], mode: .webSearch)
            return (out, SpendGate.pauseReason())
        }
        let capEx = serverD.requests.filter { stageOf($0) == "excerpts" }
        check("21.15 R1 with a daily cap configured, a cut makes spend unverifiable: the paid retry is NOT sent (1 excerpts request), the stage says why, and the spend gate pauses paid work",
              capEx.count == 1 && logText().contains("stage=extract.excerpts not sent: spend gate paused")
              && pauseAfterCut?.contains("unknown cost of a web extraction request cut at its deadline") == true,
              "\(capEx.count) requests, pause: \(pauseAfterCut?.prefix(120) ?? "nil")")
        let (accepted, pauseAfterAccept): (ToolChargeLedger.Acceptance, String?) = await withMainSlots(capped) {
            (ToolChargeLedger.acceptOpenIncidents(channel: "selftest"), SpendGate.pauseReason())
        }
        check("21.15b R1 /spend accept-unknown accepts exactly that open cut incident; the gate then allows paid work again",
              accepted.accepted.count == 1 && accepted.accepted.first?.generationId == "gen-dl-cap" && pauseAfterAccept == nil,
              "\(accepted.accepted.map(\.id)) \(pauseAfterAccept ?? "nil")")

        func faults(_ labels: Set<String>) {
            ToolChargeLedger.faultForTesting = labels.isEmpty ? nil : { label in
                if labels.contains(label) { throw ToolChargeLedger.Failure("injected \(label) failure") }
            }
        }
        func inFlight() -> [ToolChargeLedger.InFlightRequest] {
            if case .readable(let list) = ToolChargeLedger.loadInFlight() { return list }
            return []
        }
        func extractCapped(_ focus: String) async -> ([String], String?) {
            let url = nextURL()
            fixtures.pages[url] = page
            serverD.clear()
            let pause = await withMainSlots(capped) {
                _ = try? await orchestrator.executeWebExtract(requests: [.init(url: url, focus: focus)], mode: .webSearch)
                return SpendGate.pauseReason()
            }
            return (serverD.requests.compactMap(stageOf), pause)
        }

        // 21.16 The incident can't be saved at the cut: the obligation is
        // kept (write-ahead record on disk + memory), the snapshot stays
        // incomplete, the save is retried, and a restart keeps it.
        ToolChargeLedger.resetForTesting()
        faults(["incident-open"])
        queue.reset()
        queue.push("excerpts", runaway(gen: "gen-dl-unrec", provider: "Reka"))
        let (_, unrecReqs, _) = await extract("deadline unrecorded")
        let unrecSnap = ToolChargeLedger.snapshot()
        let unrecInFlight = inFlight()
        faults([])
        let unrecAfter = ToolChargeLedger.snapshot()
        let unrecSaved = incidents().first { $0.generationId == "gen-dl-unrec" }
        check("21.16 R2 a cut whose incident can't be saved stays an OPEN unknown (write-ahead record kept on disk, snapshot incomplete and listing it, logged UNSAVED); once writes work the next snapshot saves the incident and clears the record",
              unrecReqs.filter { stageOf($0) == "excerpts" }.count == 2
              && logText().contains("gen=gen-dl-unrec cost=unknown incident=unknown-amount:") && logText().contains("UNSAVED(kept, retried)")
              && !unrecSnap.isComplete && unrecSnap.incidents.contains { $0.generationId == "gen-dl-unrec" }
              && unrecInFlight.count == 1
              && unrecSaved?.state == .open && !unrecAfter.isComplete && inFlight().isEmpty,
              "snap complete \(unrecSnap.isComplete) inFlight \(unrecInFlight.count) saved \(String(describing: unrecSaved?.id))")
        let refused = ToolChargeLedger.acceptOpenIncidents(channel: "selftest")
        check("21.16b accept-unknown accepts the saved incident normally", refused.failure == nil && refused.accepted.contains { $0.generationId == "gen-dl-unrec" },
              "\(refused.failure ?? "") \(refused.accepted.map(\.id))")
        // Restart while the incident still can't be saved: the write-ahead
        // record of the previous process becomes an incident afterwards.
        ToolChargeLedger.resetForTesting()
        faults(["incident-open"])
        queue.reset()
        queue.push("excerpts", runaway(gen: "gen-dl-unrec-restart", provider: "Reka"))
        _ = await extract("deadline unrecorded restart")
        let pendingAccept = ToolChargeLedger.acceptOpenIncidents(channel: "selftest")
        ToolChargeLedger.simulateRestartForTesting()
        let restartSnapFaulted = ToolChargeLedger.snapshot()
        faults([])
        let restartSnap = ToolChargeLedger.snapshot()
        let restarted = incidents().filter { $0.detail?.contains("interrupted by a restart") == true }
        check("21.16c R2 restart: accept-unknown refuses while the unknown is unsaved; after a restart the previous process's write-ahead record is still an open unknown (faulted) and becomes a saved incident once writes work",
              pendingAccept.failure != nil && pendingAccept.accepted.isEmpty
              && !restartSnapFaulted.isComplete && restarted.count == 1 && restarted.first?.state == .open
              && !restartSnap.isComplete && inFlight().isEmpty,
              "accept \(pendingAccept.failure ?? "nil") faulted complete \(restartSnapFaulted.isComplete) restarted \(restarted.count)")
        // No durable write-ahead record → the request is not sent.
        ToolChargeLedger.resetForTesting()
        faults(["inflight-begin"])
        queue.reset()
        let (_, noTrackReqs, _) = await extract("deadline untracked")
        faults([])
        check("21.16d R2 if the write-ahead record can't be saved the extractor request is refused before sending (no excerpts/assets request)",
              noTrackReqs.filter { stageOf($0) != nil }.isEmpty && logText().contains("not sent: in-flight record could not be saved"),
              "\(noTrackReqs.compactMap(stageOf))")
        // 21.7b Cancellation while open abandons the request: unknown cost.
        check("21.7b a job cancelled while its extractor request was open left that request as an unknown (\"cancelled while open\"), not as nothing",
              cancelledIncidents > 0, "\(cancelledIncidents)")

        // CODEX-A (round 3 reproduction): an optional asset cut must not let
        // a new paid excerpts request start.
        ToolChargeLedger.resetForTesting()
        queue.reset()
        queue.push("assets", runaway(gen: "gen-codex-assets-cap", provider: "Reka"))
        let (afterAssetRequests, assetPause) = await extractCapped("asset cap")
        check("CODEX-A no paid excerpts after asset cut opens cap pause", !afterAssetRequests.contains("excerpts") && assetPause != nil,
              "stages=\(afterAssetRequests), paused=\(assetPause != nil)")
        // Also a web_fetch compression after the pause: nothing paid sent.
        let fetchURL = nextURL()
        fixtures.pages[fetchURL] = page
        serverD.clear()
        let pausedFetch = await withMainSlots(capped) {
            try? await orchestrator.readUrlContentWithMetadata(url: fetchURL, prompt: "paused", refresh: true).result.content
        }
        check("21.17 R1 while paused, a new web_fetch compression sends no paid request and falls back to the raw page",
              serverD.requests.compactMap(stageOf).isEmpty && pausedFetch?.contains("Extractor deadline page text.") == true,
              "\(serverD.requests.compactMap(stageOf))")

        // CODEX-B (round 3 reproduction).
        ToolChargeLedger.resetForTesting()
        faults(["incident-open"])
        queue.reset()
        queue.push("excerpts", runaway(gen: "gen-codex-unrecorded", provider: "Reka"))
        let failedURL = nextURL()
        fixtures.pages[failedURL] = page
        let lostPause = await withMainSlots(capped) {
            _ = try? await orchestrator.executeWebExtract(requests: [.init(url: failedURL, focus: "unrecorded cap")], mode: .webSearch)
            ToolChargeLedger.faultForTesting = nil
            return SpendGate.pauseReason()
        }
        let lostSnapshot = ToolChargeLedger.snapshot()
        check("CODEX-B failed incident save does not erase unknown spend", !lostSnapshot.isComplete && lostPause != nil,
              "complete=\(lostSnapshot.isComplete), incidents=\(incidents().count), paused=\(lostPause != nil)")

        // CODEX-C (round 3 reproduction).
        ToolChargeLedger.resetForTesting()
        let knownID = UUID()
        try ToolChargeLedger.openCutRequestUnknown(chargeId: knownID, generationId: "gen-codex-known", provider: "Reka", stage: "test")
        faults(["ledger-write"])
        _ = await ToolChargeLedger.reconcileCutRequests { _ in 0.7 }
        ToolChargeLedger.faultForTesting = nil
        let beforeAcceptance = ToolChargeLedger.snapshot().today
        _ = ToolChargeLedger.acceptOpenIncidents(channel: "selftest")
        _ = await ToolChargeLedger.reconcileCutRequests { _ in nil }
        let afterAcceptance = ToolChargeLedger.snapshot()
        check("CODEX-C known lookup cost retained despite ledger write failure and unknown acceptance", abs(afterAcceptance.today - 0.7) < 1e-9,
              "before=\(beforeAcceptance) after=\(afterAcceptance.today) complete=\(afterAcceptance.isComplete)")

        func ledgerCut() -> [ToolChargeEntry] {
            if case .readable(_, let e, _) = ToolChargeLedger.loadLedger() { return e.filter { $0.kind == ToolChargeLedger.cutRequestChargeKind } }
            return []
        }
        // 21.18 Ledger write fails, restart before it is retried: the known
        // amount survives on the incident; settlement needs no new lookup.
        ToolChargeLedger.resetForTesting()
        try ToolChargeLedger.openCutRequestUnknown(chargeId: UUID(), generationId: "gen-known-restart", provider: "Reka", stage: "test")
        faults(["ledger-write"])
        _ = await ToolChargeLedger.reconcileCutRequests { _ in 0.7 }
        ToolChargeLedger.simulateRestartForTesting()
        let restartKnown = ToolChargeLedger.snapshot()
        let lookupsAfterRestart = LookupCounter()
        _ = await ToolChargeLedger.reconcileCutRequests { _ in lookupsAfterRestart.bump(); return nil }
        let stillFaulted = ledgerCut().count
        faults([])
        _ = ToolChargeLedger.settleCutRequestCharges()
        let settledKnown = incidents().first { $0.generationId == "gen-known-restart" }
        check("21.18 R3 restart after a failed ledger write: the known $0.70 stays counted (kept on the incident), the incident no longer counts as unknown, no new lookup is made, and the retry writes it to the ledger once and closes the incident",
              abs(restartKnown.today - 0.7) < 1e-9 && restartKnown.isComplete && lookupsAfterRestart.value == 0 && stillFaulted == 0
              && ledgerCut().count == 1 && settledKnown?.state == .closed && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "today \(restartKnown.today) complete \(restartKnown.isComplete) lookups \(lookupsAfterRestart.value) ledger \(ledgerCut().count) state \(String(describing: settledKnown?.state))")
        // 21.19 Both the incident and the ledger writes fail: the amount is
        // memory-held (counted), accept-unknown keeps it, and it settles
        // once storage works.
        ToolChargeLedger.resetForTesting()
        try ToolChargeLedger.openCutRequestUnknown(chargeId: UUID(), generationId: "gen-known-held", provider: "Reka", stage: "test")
        faults(["ledger-write", "incident-known"])
        _ = await ToolChargeLedger.reconcileCutRequests { _ in 0.7 }
        let heldBefore = ToolChargeLedger.snapshot().today
        faults(["ledger-write", "incident-known", "incident-reconcile"])
        let heldAccept = ToolChargeLedger.acceptOpenIncidents(channel: "selftest")
        faults([])
        let heldAfterAccept = ToolChargeLedger.snapshot().today
        _ = ToolChargeLedger.settleCutRequestCharges()
        check("21.19 R3 incident and ledger writes both failing: the $0.70 is memory-held and counted, survives accept-unknown, and is written to the ledger exactly once when storage works",
              abs(heldBefore - 0.7) < 1e-9 && heldAccept.failure == nil && abs(heldAfterAccept - 0.7) < 1e-9
              && ledgerCut().count == 1 && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9 && ToolChargeLedger.heldCharges().isEmpty,
              "before \(heldBefore) accept \(heldAccept.failure ?? "ok") after \(heldAfterAccept) ledger \(ledgerCut().count)")
        // 21.20 The incident close fails after the ledger write: counted once.
        ToolChargeLedger.resetForTesting()
        try ToolChargeLedger.openCutRequestUnknown(chargeId: UUID(), generationId: "gen-known-close", provider: "Reka", stage: "test")
        faults(["incident-reconcile"])
        _ = await ToolChargeLedger.reconcileCutRequests { _ in 0.7 }
        faults([])
        let closeSnap = ToolChargeLedger.snapshot()
        check("21.20 R3 incident closure failing after the ledger write: the $0.70 counts once (ledger and incident share the charge id) and the incident no longer counts as unknown",
              abs(closeSnap.today - 0.7) < 1e-9 && closeSnap.isComplete && ledgerCut().count == 1,
              "today \(closeSnap.today) complete \(closeSnap.isComplete)")

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

final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
