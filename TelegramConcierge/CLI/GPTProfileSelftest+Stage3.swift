import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stage 3 (GPT_APPLY_PATCH_PLAN §5.1/§5.6, live format checks 2026-11-09):
/// the freeform form on both ChatGPT routes, the classifier for tools inside
/// the SIWC namespace, and the HTTP-200 streamed refusals (OpenRouter's
/// `response.failed` "Invalid lark grammar", the ChatGPT routes' empty
/// `response.incomplete`). The SIWC wire rows run in `__siwc-selftest --only
/// gpt-patch` (its store and credential fixtures).
extension GPTProfileSelftest {

    static func sse(_ events: [[String: Any]]) -> String {
        events.map { "data: " + jsonText($0) + "\n\n" }.joined()
    }

    /// The terminal events of a response with no output at all.
    static func emptyTerminalSSE(_ type: String, id: String = "resp_s3", extra: [String: Any] = [:],
                                 streamItem: Bool = false, textDelta: Bool = false) -> String {
        var events: [[String: Any]] = [
            ["type": "response.created", "sequence_number": 0, "response": ["id": id, "status": "in_progress", "output": []]],
            ["type": "response.in_progress", "sequence_number": 1, "response": ["id": id, "status": "in_progress", "output": []]]]
        if streamItem {
            events.append(["type": "response.output_item.added", "sequence_number": 2, "output_index": 0,
                           "item": ["type": "reasoning", "id": "rs_1", "summary": []]])
        }
        if textDelta {
            events.append(["type": "response.output_text.delta", "sequence_number": 3, "item_id": "msg_1",
                           "output_index": 0, "content_index": 0, "delta": "x"])
        }
        var response: [String: Any] = ["id": id, "status": String(type.dropFirst("response.".count)), "output": []]
        for (k, v) in extra { response[k] = v }
        events.append(["type": type, "sequence_number": 10, "response": response])
        return sse(events)
    }

    static func assemble(_ body: String, subscription: Bool = false, siwc: Bool = false) -> (Data, Bool)? {
        var a = ResponsesStreamAssembler()
        a.subscription = subscription || siwc
        a.siwc = siwc
        guard (try? a.append(Data(body.utf8))) != nil, let terminal = try? a.finish() else { return nil }
        return (terminal, a.sawOutput)
    }

    static func sseCompleted(_ output: [[String: Any]], id: String = "resp_ok") -> String {
        sse([["type": "response.created", "sequence_number": 0, "response": ["id": id, "status": "in_progress", "output": []]],
             ["type": "response.completed", "sequence_number": 1, "response": [
                "id": id, "status": "completed", "output": output,
                "usage": ["input_tokens": 10, "output_tokens": 5, "input_tokens_details": ["cached_tokens": 0],
                          "output_tokens_details": ["reasoning_tokens": 0]]]]])
    }

    static func stage3Tests(_ t: CPTest) async {
        GPTPatchFormStore.fileURLOverrideForTesting = URL(fileURLWithPath: t.dir("yform")).appendingPathComponent("f.json")
        GPTPatchFormStore.shared.resetCacheForTesting()
        defer { try? GPTPatchFormStore.shared.deleteAll() }
        let gptTools = AvailableTools.all(includeWebSearch: false, editing: .gptFreeform)
        let k = gptTools.firstIndex { $0.function.name == "apply_patch" } ?? 0
        let topLevel = Data(jsonText(["tools": [["type": "function", "name": "read_file"], ["type": "custom", "name": "apply_patch"]]]).utf8)
        let namespaced = Data(jsonText(["tools": [["type": "namespace", "name": "briglia", "tools": [
            ["type": "function", "name": "read_file"], ["type": "function", "name": "bash"], ["type": "custom", "name": "apply_patch"]]]]]).utf8)
        let namespacedNoCustom = Data(jsonText(["tools": [["type": "namespace", "name": "briglia", "tools": [
            ["type": "function", "name": "read_file"], ["type": "function", "name": "apply_patch"]]]]]).utf8)
        let underlying = ResponsesFailure.http(400, nil)

        // Legacy ChatGPT request shape (§5.2): the grammar tool in apply_patch's slot.
        var legacy = responses("gpt-6-luna", base: SubscriptionEndpoint.inference)
        legacy.subscriptionGeneration = "g1"
        let legacyRun = EditingRun.start(legacy)
        t.check("Y legacy ChatGPT run starts in the freeform form", legacyRun.config == .gptFreeform)
        legacy.editing = legacyRun.config
        if let request = try? ResponsesAdapter(context: legacy).request(input: [ResponsesAdapter.message(role: "system", text: "p"),
                                                                         ResponsesAdapter.message(role: "user", text: "u")], tools: gptTools),
           let body = request.httpBody {
            let ts = tools(body)
            t.check("Y legacy ChatGPT request: Codex grammar tool in apply_patch's slot, top level, every other tool a function",
                    k < ts.count && ts[k]["type"] as? String == "custom" && ts[k]["name"] as? String == "apply_patch"
                    && (ts[k]["format"] as? [String: Any])?["definition"] as? String == GPTFreeform.grammar
                    && ts.enumerated().allSatisfy { $0.offset == k || $0.element["type"] as? String == "function" }
                    && request.url?.absoluteString == SubscriptionEndpoint.inference)
        } else { t.check("Y legacy ChatGPT request builds", false) }
        var legacyJSON = legacy
        legacyJSON.editing = .gptJSON
        if let body = (try? ResponsesAdapter(context: legacyJSON).request(input: [ResponsesAdapter.message(role: "user", text: "u")], tools: gptTools))?.httpBody {
            t.check("Y legacy ChatGPT after a transition: apply_patch is a function tool",
                    !tools(body).contains { $0["type"] as? String == "custom" }
                    && tools(body).contains { $0["name"] as? String == "apply_patch" && $0["type"] as? String == "function" })
        } else { t.check("Y legacy ChatGPT JSON request builds", false) }

        // HTTP 400 classifier: entries inside the SIWC namespace (§5.6).
        func classify(_ body: String, _ request: Data?) -> Bool {
            GPTCustomToolRejection.classify(status: 400, rawBody: Data(body.utf8), requestBody: request, underlying: underlying) != nil
        }
        t.check("Y namespaced entries are found (tools[0].tools[2])",
                GPTCustomToolRejection.customEntries(namespaced).map(\.param) == ["tools[0].tools[2]"]
                && GPTCustomToolRejection.customEntries(topLevel).map(\.param) == ["tools[1]"]
                && GPTCustomToolRejection.customEntries(namespacedNoCustom).isEmpty)
        t.check("Y classifies a namespaced entry's format", classify(errorBody(param: "tools[0].tools[2].format", code: "invalid_value"), namespaced))
        t.check("Y classifies a namespaced entry's type", classify(errorBody(param: "tools[0].tools[2].type", code: "unsupported_value"), namespaced))
        t.check("Y classifies a namespaced whole entry only with a type code",
                classify(errorBody(param: "tools[0].tools[2]", code: "unsupported_tool_type"), namespaced)
                && !classify(errorBody(param: "tools[0].tools[2]", code: "invalid_value"), namespaced))
        t.check("Y does not classify another namespaced tool", !classify(errorBody(param: "tools[0].tools[1].type", code: "invalid_value"), namespaced))
        t.check("Y does not classify the namespace itself", !classify(errorBody(param: "tools[0]", code: "unsupported_tool_type"), namespaced)
                && !classify(errorBody(param: "tools[0].type", code: "invalid_value"), namespaced))
        t.check("Y does not classify the top-level index form for a namespaced entry", !classify(errorBody(param: "tools[2].format", code: "invalid_value"), namespaced))
        t.check("Y does not classify a namespace without a custom entry", !classify(errorBody(param: "tools[0].tools[1].format", code: "invalid_value"), namespacedNoCustom))
        t.check("Y the whole-array `'custom'` refusal also classifies with a namespaced entry",
                classify(jsonText(["error": ["message": "Invalid value: 'custom'. Supported values are: 'function'.", "param": "tools", "code": "unknown_parameter"]]), namespaced))

        // SIWC unsupported_capability naming the custom entry.
        func capability(_ param: String, code: String = "unsupported_capability", request: Data? = namespaced) -> Bool {
            let body = jsonText(["error": ["code": code, "param": param, "message": "not supported"]])
            return GPTCustomToolRejection.classifySIWCCapability(status: 400, rawBody: Data(body.utf8), requestBody: request,
                                                                 underlying: SIWCError(.unsupported, "x")) != nil
        }
        t.check("Y SIWC unsupported_capability at the custom entry classifies", capability("tools[0].tools[2]") && capability("tools[0].tools[2].format"))
        t.check("Y SIWC unsupported_capability elsewhere does not classify",
                !capability("tools[0].tools[1]") && !capability("reasoning") && !capability("tools") && !capability("tools[0]"))
        t.check("Y SIWC: another code at the custom entry is not this rule", !capability("tools[0].tools[2]", code: "usage_limit_exceeded"))
        t.check("Y SIWC: no custom entry, no classification", !capability("tools[0].tools[1]", request: namespacedNoCustom))

        // Streamed refusals: the real OpenRouter SSE captures (2026-11-09).
        let dir = URL(fileURLWithPath: t.fixtures).appendingPathComponent("provider-errors")
        var streamed = 0
        if let manifestData = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
           let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
           let cases = manifest["cases"] as? [[String: Any]] {
            for c in cases {
                guard let expect = c["expect_stream_classified"] as? Bool, let file = c["file"] as? String,
                      let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                      let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let body = o["body"] as? String, let request = o["request"],
                      let requestData = try? JSONSerialization.data(withJSONObject: request) else { continue }
                streamed += 1
                guard let (terminal, sawOutput) = assemble(body) else { t.check("Y live SSE fixture \(file) assembles", false); continue }
                let fires = GPTCustomToolRejection.classifyTerminal(terminal, requestBody: requestData, chatGPTRoute: false,
                                                                    streamedOutput: sawOutput, underlying: underlying) != nil
                t.check("Y live SSE fixture \(file): stream-classified = \(expect)", fires == expect)
                if expect {
                    let without = Data(jsonText(["tools": [["type": "function", "name": "apply_patch"]]]).utf8)
                    t.check("Y live SSE fixture \(file): not classified without a custom entry",
                            GPTCustomToolRejection.classifyTerminal(terminal, requestBody: without, chatGPTRoute: false,
                                                                    streamedOutput: false, underlying: underlying) == nil)
                    t.check("Y live SSE fixture \(file): not classified when output streamed",
                            GPTCustomToolRejection.classifyTerminal(terminal, requestBody: requestData, chatGPTRoute: false,
                                                                    streamedOutput: true, underlying: underlying) == nil)
                }
            }
        }
        t.check("Y live SSE fixtures: both streamed captures are covered", streamed >= 2, "\(streamed)")

        // The ChatGPT routes' shape (probes P1/P2 R5, 2026-11-09: HTTP 200,
        // `response.incomplete`, no output items). Synthetic events built from
        // the recorded summary; the incomplete reason was not recorded, so
        // every reason variant is pinned here.
        func incomplete(_ extra: [String: Any] = [:], subscription: Bool = true, siwc: Bool = false, chatGPT: Bool = true,
                        request: Data? = topLevel, streamItem: Bool = false, textDelta: Bool = false) -> Bool? {
            // nil = the fixture did not assemble (never counts as a pass).
            guard let (terminal, sawOutput) = assemble(emptyTerminalSSE("response.incomplete", extra: extra, streamItem: streamItem, textDelta: textDelta),
                                                       subscription: subscription, siwc: siwc) else { return nil }
            return GPTCustomToolRejection.classifyTerminal(terminal, requestBody: request, chatGPTRoute: chatGPT,
                                                           streamedOutput: sawOutput, underlying: underlying) != nil
        }
        t.check("Y ChatGPT empty incomplete classifies (no reason)", incomplete() == true)
        t.check("Y ChatGPT empty incomplete classifies (null details, zero output tokens)",
                incomplete(["incomplete_details": NSNull(), "usage": ["input_tokens": 400, "output_tokens": 0]]) == true)
        t.check("Y SIWC empty incomplete with a namespaced entry classifies", incomplete(subscription: false, siwc: true, request: namespaced) == true)
        t.check("Y ChatGPT incomplete: max_output_tokens is ordinary", incomplete(["incomplete_details": ["reason": "max_output_tokens"]]) == false)
        t.check("Y ChatGPT incomplete: content_filter is ordinary", incomplete(["incomplete_details": ["reason": "content_filter"]]) == false)
        t.check("Y ChatGPT incomplete with output tokens is ordinary", incomplete(["usage": ["input_tokens": 400, "output_tokens": 12]]) == false)
        t.check("Y ChatGPT incomplete with a streamed output item is ordinary", incomplete(streamItem: true) == false)
        t.check("Y ChatGPT incomplete with streamed text is ordinary", incomplete(textDelta: true) == false)
        t.check("Y incomplete with terminal output is ordinary",
                incomplete(["output": [["type": "message", "id": "m", "role": "assistant", "content": []]]]) == false)
        t.check("Y empty incomplete on a non-ChatGPT route never classifies", incomplete(subscription: false, chatGPT: false) == false)
        t.check("Y empty incomplete without a custom entry never classifies", incomplete(request: namespacedNoCustom) == false
                && incomplete(request: nil) == false)
        // Generic failures and other terminals never classify.
        func terminalFires(_ type: String, _ extra: [String: Any], chatGPT: Bool = true) -> Bool? {
            guard let (terminal, sawOutput) = assemble(emptyTerminalSSE(type, extra: extra), subscription: chatGPT) else { return nil }
            return GPTCustomToolRejection.classifyTerminal(terminal, requestBody: topLevel, chatGPTRoute: chatGPT,
                                                           streamedOutput: sawOutput, underlying: underlying) != nil
        }
        t.check("Y a generic streamed failure never classifies",
                terminalFires("response.failed", ["error": ["code": "server_error", "message": "Provider returned an empty response"]]) == false
                && terminalFires("response.failed", ["error": ["code": "invalid_prompt", "message": "Something else about the prompt"]]) == false
                && terminalFires("response.failed", [:]) == false)
        t.check("Y a streamed lark-grammar failure classifies on every route",
                terminalFires("response.failed", ["error": ["code": "invalid_prompt", "message": "Invalid lark grammar. 1(3): x"]], chatGPT: false) == true
                && terminalFires("response.failed", ["error": ["code": NSNull(), "message": "Invalid lark grammar. 1(3): x"]]) == true)
        // Real Briglia requests carry ~30 tools that OpenRouter echoes in the
        // terminal snapshot: far above 64 KiB.
        let echoedTools: [[String: Any]] = (0..<120).map { ["type": "function", "name": "tool_\($0)", "description": String(repeating: "d", count: 1_000)] }
        let bigFailed = jsonText(["id": "resp_big", "status": "failed", "output": [], "tools": echoedTools,
                                  "error": ["code": "invalid_prompt", "message": "Invalid lark grammar. 1(3): x"]])
        t.check("Y a lark refusal whose terminal echoes a large tool list (>64 KiB) still classifies",
                bigFailed.utf8.count > 64 * 1024
                && GPTCustomToolRejection.classifyTerminal(Data(bigFailed.utf8), requestBody: topLevel, chatGPTRoute: false,
                                                           streamedOutput: false, underlying: underlying) != nil)
        t.check("Y a completed-but-empty answer never classifies",
                GPTCustomToolRejection.classifyTerminal(Data(reply([]).utf8), requestBody: topLevel, chatGPTRoute: true,
                                                        streamedOutput: false, underlying: underlying) == nil)

        // decodeRound (the adapter's one decode): the classification reaches
        // the run as Rejected with the decoder's own error underneath.
        if let (terminal, _) = assemble(emptyTerminalSSE("response.incomplete"), subscription: true) {
            var request = URLRequest(url: URL(string: SubscriptionEndpoint.inference)!)
            request.httpBody = topLevel
            let receipt = PreparedRequestReceipt(requestID: UUID(), historyFingerprint: "y", deliveryNonces: [])
            var legacyCtx = legacy; legacyCtx.editing = .gptFreeform
            do {
                _ = try ResponsesAdapter.decodeRound(terminal, request: request, context: legacyCtx, receipt: receipt,
                                                     allowed: ["apply_patch"], requiredNamespace: nil, streamedOutput: false)
                t.check("Y decodeRound: a ChatGPT empty incomplete becomes a freeform rejection", false)
            } catch let rejected as GPTCustomToolRejection.Rejected {
                var kept = false
                if let failure = rejected.underlying as? ResponsesFailure, case .incomplete = failure { kept = true }
                t.check("Y decodeRound: a ChatGPT empty incomplete becomes a freeform rejection (underlying kept)", kept, "\(rejected.underlying)")
            } catch { t.check("Y decodeRound: a ChatGPT empty incomplete becomes a freeform rejection", false, "\(error)") }
            let api = responses("gpt-6-luna", base: "https://openrouter.ai/api/v1")
            do {
                _ = try ResponsesAdapter.decodeRound(terminal, request: request, context: api, receipt: receipt,
                                                     allowed: ["apply_patch"], requiredNamespace: nil, streamedOutput: false)
                t.check("Y decodeRound: the same terminal elsewhere stays an ordinary incomplete", false)
            } catch {
                t.check("Y decodeRound: the same terminal elsewhere stays an ordinary incomplete", !(error is GPTCustomToolRejection.Rejected))
            }
        } else { t.check("Y synthetic incomplete assembles", false) }

        // End to end through the loopback OpenRouter route with the REAL
        // streamed captures: auto routing → one transition; Bedrock → none.
        GPTPatchRoute.freeformHostsOverrideForTesting = ["127.0.0.1"]
        defer { GPTPatchRoute.freeformHostsOverrideForTesting = nil }
        guard let server = try? CaptureServer() else { t.check("Y fixture server", false); return }
        defer { server.stop() }
        let root = URL(fileURLWithPath: t.dir("ywire"))
        let service = OpenRouterService()
        let ctx = responses("openai/gpt-6-luna", base: "http://127.0.0.1:\(server.port)/v1")
        func realBody(_ file: String) -> String? {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return o["body"] as? String
        }
        // SIWC capability refusal through the REAL transport (siwc mode):
        // classified before the SIWC error map only when it names the entry.
        func siwcTransport(_ param: String) async -> Error? {
            server.script([jsonText(["error": ["code": "unsupported_capability", "param": param, "message": "not supported"]])], statuses: [400])
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/responses")!)
            request.httpMethod = "POST"; request.httpBody = namespaced; request.timeoutInterval = 10
            do { _ = try await ResponsesHTTPTransport().send(request, overallTimeout: 10, siwc: true); return nil } catch { return error }
        }
        let atEntry = await siwcTransport("tools[0].tools[2]")
        t.check("Y SIWC transport: unsupported_capability at the custom entry → freeform rejection (SIWC error underneath)",
                (atEntry as? GPTCustomToolRejection.Rejected).map { ($0.underlying as? SIWCError)?.kind == .unsupported } == true, "\(String(describing: atEntry))")
        let elsewhere = await siwcTransport("tools[0].tools[1]")
        t.check("Y SIWC transport: unsupported_capability elsewhere stays the SIWC error",
                (elsewhere as? SIWCError)?.kind == .unsupported, "\(String(describing: elsewhere))")
        if let auto = realBody("or-badgrammar.json"), let bedrock = realBody("or-badgrammar-bedrock.json") {
            try? GPTPatchFormStore.shared.deleteAll()
            let notices = NoticeBox()
            let run = EditingRun.start(ctx)
            run.setNotifier { await notices.add($0) }
            server.script([auto, sseCompleted([doneText])], statuses: [200, 200])
            let response = try? await request(service, ctx, run: run, messages: [Message(role: .user, content: "go")], tools: gptTools, root: root)
            let sent = server.completeRequests.suffix(2).map(\.body)
            let notes = await notices.all
            t.check("Y the real streamed grammar refusal transitions and resends once in JSON form",
                    response != nil && run.config == .gptJSON && sent.count == 2
                    && tools(sent[0]).contains { $0["type"] as? String == "custom" }
                    && !tools(sent[1]).contains { $0["type"] as? String == "custom" }
                    && notes == [GPTPatchRoute.transitionNotice], "\(notes)")
            t.check("Y the streamed refusal is recorded for the route", EditingConfig.resolveAtRunStart(ctx) == .gptJSON)
            try? GPTPatchFormStore.shared.deleteAll()
            let before = server.completeRequests.count
            let run2 = EditingRun.start(ctx)
            server.script([bedrock], statuses: [200])
            var failed = false
            do { _ = try await request(service, ctx, run: run2, messages: [Message(role: .user, content: "x")], tools: gptTools, root: root) }
            catch { failed = !(error is GPTCustomToolRejection.Rejected) }
            t.check("Y the real generic streamed failure (Bedrock) surfaces as today, no transition, no resend",
                    failed && run2.config == .gptFreeform && server.completeRequests.count == before + 1
                    && EditingConfig.resolveAtRunStart(ctx) == .gptFreeform)
        } else { t.check("Y real streamed captures load", false) }
        try? GPTPatchFormStore.shared.deleteAll()
    }
}
