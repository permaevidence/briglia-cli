import Foundation

/// Wire forms, replay and pairing, mixed-model history, decoder repair and
/// the §5.6 freeform → JSON fallback, against a loopback fixture server
/// standing in for OpenRouter's Responses endpoint (amendment A1).
extension GPTProfileSelftest {

    static func body(_ data: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }
    static func items(_ data: Data) -> [[String: Any]] { (body(data)["input"] as? [[String: Any]]) ?? [] }
    static func tools(_ data: Data) -> [[String: Any]] { (body(data)["tools"] as? [[String: Any]]) ?? [] }
    static func jsonText(_ v: Any) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])) ?? Data(), as: UTF8.self) }

    static func reply(_ output: [[String: Any]], id: String = "resp_1") -> String {
        jsonText(["id": id, "status": "completed", "output": output,
                  "usage": ["input_tokens": 10, "output_tokens": 5, "input_tokens_details": ["cached_tokens": 0],
                            "output_tokens_details": ["reasoning_tokens": 0]]])
    }
    static let doneText: [String: Any] = ["type": "message", "id": "msg_d", "status": "completed", "role": "assistant",
                                          "content": [["type": "output_text", "text": "done", "annotations": []]]]
    static func customCall(_ input: String, id: String = "call_ff1") -> [String: Any] {
        ["type": "custom_tool_call", "status": "completed", "call_id": id, "name": "apply_patch", "input": input]
    }

    static func request(_ service: OpenRouterService, _ ctx: ProviderExecutionContext, run: EditingRun?, messages: [Message],
                        rounds: [ToolInteraction]? = nil, tools: [ToolDefinition], root: URL) async throws -> LLMResponse {
        try await service.generateResponse(messages: messages, imagesDirectory: root, documentsDirectory: root,
            tools: tools, toolResultMessages: rounds, execution: ctx, lane: .main, editingRun: run)
    }

    // MARK: W — wire forms, replay, pairing, mixed history (§5.2–5.5, §10)

    static func wireTests(_ t: CPTest) async {
        GPTPatchFormStore.fileURLOverrideForTesting = URL(fileURLWithPath: t.dir("wireform")).appendingPathComponent("f.json")
        GPTPatchFormStore.shared.resetCacheForTesting()
        GPTPatchRoute.freeformHostsOverrideForTesting = ["127.0.0.1"]
        defer { GPTPatchRoute.freeformHostsOverrideForTesting = nil }
        guard let server = try? CaptureServer() else { t.check("W fixture server", false); return }
        defer { server.stop() }
        let root = URL(fileURLWithPath: t.dir("wire"))
        let base = "http://127.0.0.1:\(server.port)/v1"
        let service = OpenRouterService()
        let gptCtx = responses("openai/gpt-6-luna", base: base)
        let run = EditingRun.start(gptCtx)
        t.check("W the loopback fixture route resolves to freeform", run.config == .gptFreeform)
        let gptTools = AvailableTools.all(includeWebSearch: false, editing: run.config)
        let human = Message(role: .user, content: "edit it")
        let patch = "*** Begin Patch\n*** Update File: /tmp/w.txt\n@@\n-a\n+b\n*** End Patch\n"
        server.script([reply([customCall(patch)])])
        let first = try? await request(service, gptCtx, run: run, messages: [human], tools: gptTools, root: root)
        guard let firstBody = server.completeRequests.last?.body else { t.check("W first request captured", false); return }
        let ts = tools(firstBody)
        let slot = gptTools.firstIndex { $0.function.name == "apply_patch" } ?? -1
        t.check("W freeform request: Codex grammar tool in apply_patch's slot (§5.2)",
                slot >= 0 && slot < ts.count && ts[slot]["type"] as? String == "custom" && ts[slot]["name"] as? String == "apply_patch"
                && (ts[slot]["format"] as? [String: Any])?["definition"] as? String == GPTFreeform.grammar
                && ts[slot]["description"] as? String == AvailableTools.gptApplyPatchFreeformDescription)
        t.check("W freeform request: every other tool stays a function", ts.enumerated().allSatisfy { $0.offset == slot || $0.element["type"] as? String == "function" })
        let system = (items(firstBody).first?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        t.check("W freeform prompt says FREEFORM", system.contains("It is a FREEFORM tool"))
        guard case .toolCalls(let assistant, let calls, _, _, _)? = first, let fc = calls.first else {
            t.check("W custom_tool_call decoded", false); return
        }
        t.check("W custom_tool_call decoded as apply_patch {\"input\"} (§5.3)",
                fc.function.name == "apply_patch" && GPTFreeform.patchInput(fc) == patch && fc.function.arguments == GPTFreeform.canonicalArguments(patch))
        t.check("W the call carries the producing request's stamp (§3.2)", fc.editing == .gptFreeform)
        t.check("W native replay entry type is custom_tool_call", assistant.responsesReplay?.entries.contains { $0.type == "custom_tool_call" } == true)
        // Native replay and output pairing (§5.4–5.5).
        let round = ToolInteraction(assistantMessage: assistant, results: [ToolResultMessage(toolCallId: fc.id, content: "Success. Updated the following files:\nM /tmp/w.txt")])
        server.script([reply([doneText])])
        _ = try? await request(service, gptCtx, run: run, messages: [human], rounds: [round], tools: gptTools, root: root)
        let second = items(server.completeRequests.last?.body ?? Data())
        let nativeCall = second.first { $0["type"] as? String == "custom_tool_call" }
        let nativeOut = second.first { $0["type"] as? String == "custom_tool_call_output" }
        t.check("W native replay renders the custom item", nativeCall?["call_id"] as? String == fc.id && nativeCall?["input"] as? String == patch)
        t.check("W its output is a string custom_tool_call_output (P37)",
                nativeOut?["call_id"] as? String == fc.id && (nativeOut?["output"] as? String)?.contains("Success. Updated") == true
                && !second.contains { $0["type"] as? String == "function_call_output" })
        // Semantic replay: the same round without native metadata.
        var semanticAssistant = assistant
        semanticAssistant.responsesReplay = nil
        let semanticRound = ToolInteraction(assistantMessage: semanticAssistant, results: round.results)
        server.script([reply([doneText])])
        _ = try? await request(service, gptCtx, run: run, messages: [human], rounds: [semanticRound], tools: gptTools, root: root)
        let third = items(server.completeRequests.last?.body ?? Data())
        let semCall = third.first { $0["type"] as? String == "custom_tool_call" }
        let semOut = third.first { $0["type"] as? String == "custom_tool_call_output" }
        t.check("W semantic replay renders {\"input\"} apply_patch as custom while freeform is exposed",
                semCall != nil && semCall?["input"] as? String == patch && semOut?["call_id"] as? String == semCall?["call_id"] as? String)
        // The same history in a JSON-form request: function items (P18, P37).
        let jsonCtx = responses("openai/gpt-6-luna", base: base)
        let jsonRun = EditingRun(context: jsonCtx, config: .gptJSON, switchOn: true)
        server.script([reply([doneText])])
        _ = try? await request(service, jsonCtx, run: jsonRun, messages: [human], rounds: [round], tools: gptTools, root: root)
        let jsonBody = server.completeRequests.last?.body ?? Data()
        let jsonItems = items(jsonBody)
        t.check("W JSON-form request: apply_patch is a function tool", tools(jsonBody).contains { $0["name"] as? String == "apply_patch" && $0["type"] as? String == "function" })
        t.check("W JSON-form request: a native custom round replays semantically as function_call (P18)",
                !jsonItems.contains { ($0["type"] as? String)?.hasPrefix("custom_tool_call") == true }
                && jsonItems.contains { $0["type"] as? String == "function_call" && $0["name"] as? String == "apply_patch" }
                && jsonItems.contains { $0["type"] as? String == "function_call_output" })
        let jsonSystem = (jsonItems.first?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        t.check("W JSON-form prompt asks for the `input` string", jsonSystem.contains("Put the whole patch in the `input` string."))
        // Mixed models (§10): GPT history in a standard request, standard
        // history in a GPT request.
        let stdCtx = responses("deepseek/deepseek-v4.1-flash", base: base)
        let stdRun = EditingRun.start(stdCtx)
        let stdTools = AvailableTools.all(includeWebSearch: false, editing: stdRun.config)
        server.script([reply([doneText])])
        _ = try? await request(service, stdCtx, run: stdRun, messages: [human], rounds: [round], tools: stdTools, root: root)
        let stdBody = server.completeRequests.last?.body ?? Data()
        t.check("W standard run: config standard, tools are today's (no GPT apply_patch)",
                stdRun.config == .standard && !tools(stdBody).contains { $0["name"] as? String == "apply_patch" }
                && tools(stdBody).contains { $0["name"] as? String == "edit_file" })
        t.check("W standard run replays GPT apply_patch history as function items (never custom)",
                !items(stdBody).contains { ($0["type"] as? String)?.hasPrefix("custom_tool_call") == true }
                && items(stdBody).contains { $0["type"] as? String == "function_call" && $0["name"] as? String == "apply_patch" })
        let editCall = ToolCall(id: "call_ed1", type: "function", function: FunctionCall(name: "edit_file", arguments: "{\"path\":\"/tmp/a\",\"old_string\":\"a\",\"new_string\":\"b\"}"))
        let editAssistant = AssistantToolCallMessage(content: "", toolCalls: [editCall])
        let editRound = ToolInteraction(assistantMessage: editAssistant, results: [ToolResultMessage(toolCallId: "call_ed1", content: "{\"success\":true}")])
        server.script([reply([doneText])])
        _ = try? await request(service, gptCtx, run: run, messages: [human], rounds: [editRound], tools: gptTools, root: root)
        let mixed = items(server.completeRequests.last?.body ?? Data())
        t.check("W GPT run replays edit_file history as a function_call",
                mixed.contains { $0["type"] as? String == "function_call" && $0["name"] as? String == "edit_file" })
        // Standard identity (I1): with the switch on, a non-GPT request built
        // through its lease equals the request built without any lease.
        server.script([reply([doneText]), reply([doneText])])
        _ = try? await request(service, stdCtx, run: nil, messages: [human], tools: AvailableTools.all(includeWebSearch: false), root: root)
        let noLease = server.completeRequests.last?.body
        _ = try? await request(service, stdCtx, run: EditingRun.start(stdCtx), messages: [human], tools: AvailableTools.all(includeWebSearch: false, editing: .standard), root: root)
        let withLease = server.completeRequests.last?.body
        t.check("W standard request bytes identical with and without the lease (I1)", noLease != nil && noLease == withLease)
        // Decoder (§5.3, §10): custom calls only for the exposed freeform tool;
        // bounded foreign-call repair.
        let scope = ResponsesScope(endpoint: "x", profile: "p", model: "m", credentialFingerprint: "f")
        let receipt = PreparedRequestReceipt(requestID: UUID(), historyFingerprint: "fixture", deliveryNonces: [])
        let customBytes = Data(reply([customCall(patch)]).utf8)
        t.check("W decoder refuses a custom call when freeform is not exposed (P16)",
                (try? ResponsesRoundDecoder.decode(customBytes, scope: scope, receipt: receipt, allowedTools: ["apply_patch"])) == nil)
        t.check("W decoder refuses a custom call for another name",
                (try? ResponsesRoundDecoder.decode(Data(reply([["type": "custom_tool_call", "call_id": "c", "name": "bash", "input": "ls"]]).utf8),
                                                   scope: scope, receipt: receipt, allowedTools: ["bash"], freeformTools: ["apply_patch"])) == nil)
        t.check("W decoder accepts the exposed freeform apply_patch",
                (try? ResponsesRoundDecoder.decode(customBytes, scope: scope, receipt: receipt, allowedTools: ["apply_patch"], freeformTools: ["apply_patch"]))?.calls.first?.function.name == "apply_patch")
        t.check("W decoder refuses a namespaced (SIWC) custom call",
                (try? ResponsesRoundDecoder.decode(customBytes, scope: scope, receipt: receipt, allowedTools: ["apply_patch"], requiredNamespace: "briglia", freeformTools: ["apply_patch"])) == nil)
        let editBytes = Data(reply([["type": "function_call", "call_id": "c2", "name": "edit_file", "arguments": "{\"path\":\"/a\"}"]]).utf8)
        t.check("W unexposed edit_file without repair: whole round refused (today)",
                (try? ResponsesRoundDecoder.decode(editBytes, scope: scope, receipt: receipt, allowedTools: ["apply_patch"])) == nil)
        let gptForeign = ResponsesAdapter.blockedForeignNames(.gptJSON, exposed: ["apply_patch"])
        t.check("W GPT repair decodes edit_file as a (blocked) call", gptForeign == ["edit_file", "write_file"]
                && (try? ResponsesRoundDecoder.decode(editBytes, scope: scope, receipt: receipt, allowedTools: ["apply_patch"], blockedForeignNames: gptForeign))?.calls.first?.function.name == "edit_file")
        t.check("W repair never widens the executable allowlist", !gptForeign.contains("apply_patch") && ResponsesAdapter.blockedForeignNames(.gptJSON, exposed: ["edit_file"]) == ["write_file"])
        t.check("W standard repair names only an unexposed apply_patch",
                ResponsesAdapter.blockedForeignNames(.standard, exposed: ["edit_file"]) == ["apply_patch"] && ResponsesAdapter.blockedForeignNames(.standard, exposed: ["apply_patch"]).isEmpty)
        t.check("W repair keeps the other checks (bad JSON arguments still refused)",
                (try? ResponsesRoundDecoder.decode(Data(reply([["type": "function_call", "call_id": "c3", "name": "edit_file", "arguments": "[1]"]]).utf8),
                                                   scope: scope, receipt: receipt, allowedTools: [], blockedForeignNames: gptForeign)) == nil)
        t.check("W foreign-call hints", GPTForeignCall.message(name: "edit_file", editing: .gptJSON) == "edit_file is not available with this model; use apply_patch"
                && GPTForeignCall.message(name: "apply_patch", editing: .standard) == "apply_patch is not available with this model; use edit_file"
                && GPTForeignCall.message(name: "bash", editing: .gptJSON) == nil
                && GPTForeignCall.hint(name: "edit_file", editing: .gptJSON, exposed: ["edit_file"]) == nil)
    }

    // MARK: X — §5.6 transition

    static func errorBody(param: String, code: String, wrapped: Bool = false) -> String {
        let inner: [String: Any] = ["error": ["message": "Invalid value for the tool", "type": "invalid_request_error", "param": param, "code": code]]
        if wrapped {
            return jsonText(["error": ["code": 400, "message": "Provider returned error", "metadata": ["raw": jsonText(inner), "provider_name": "OpenAI"]]])
        }
        return jsonText(inner)
    }

    static func transitionTests(_ t: CPTest) async {
        // Classifier (P41).
        let requestWithCustom = Data(jsonText(["tools": [["type": "function", "name": "read_file"], ["type": "custom", "name": "apply_patch"]]]).utf8)
        let requestWithout = Data(jsonText(["tools": [["type": "function", "name": "read_file"], ["type": "function", "name": "apply_patch"]]]).utf8)
        let underlying = ResponsesFailure.http(400, nil)
        func classify(_ b: String, status: Int = 400, request: Data? = requestWithCustom) -> Bool {
            GPTCustomToolRejection.classify(status: status, rawBody: Data(b.utf8), requestBody: request, underlying: underlying) != nil
        }
        t.check("X classifies tools[k] with a refusal code", classify(errorBody(param: "tools[1]", code: "invalid_value")))
        t.check("X classifies a sub-path tools[k].format", classify(errorBody(param: "tools[1].format", code: "unsupported_value")))
        t.check("X classifies OpenRouter's wrapped upstream error", classify(errorBody(param: "tools[1].format.definition", code: "invalid_value", wrapped: true)))
        t.check("X does not classify a generic `tools` error (P41)", !classify(errorBody(param: "tools", code: "invalid_value")))
        t.check("X does not classify another tool's error", !classify(errorBody(param: "tools[0]", code: "invalid_value")))
        t.check("X does not classify tools[10] for k = 1", !classify(errorBody(param: "tools[10]", code: "invalid_value")))
        t.check("X does not classify an unknown code", !classify(errorBody(param: "tools[1]", code: "rate_limit_exceeded")))
        t.check("X does not classify an input/history error", !classify(errorBody(param: "input[3]", code: "invalid_value")))
        t.check("X does not classify without a custom entry in the request", !classify(errorBody(param: "tools[1]", code: "invalid_value"), request: requestWithout))
        t.check("X does not classify a non-400", !classify(errorBody(param: "tools[1]", code: "invalid_value"), status: 422))
        // End to end through the loopback route.
        GPTPatchFormStore.fileURLOverrideForTesting = URL(fileURLWithPath: t.dir("xform")).appendingPathComponent("f.json")
        GPTPatchFormStore.shared.resetCacheForTesting()
        GPTPatchRoute.freeformHostsOverrideForTesting = ["127.0.0.1"]
        defer { GPTPatchRoute.freeformHostsOverrideForTesting = nil }
        guard let server = try? CaptureServer() else { t.check("X fixture server", false); return }
        defer { server.stop() }
        let root = URL(fileURLWithPath: t.dir("xwire"))
        let service = OpenRouterService()
        let ctx = responses("openai/gpt-6-luna", base: "http://127.0.0.1:\(server.port)/v1")
        let gptTools = AvailableTools.all(includeWebSearch: false, editing: .gptFreeform)
        let k = gptTools.firstIndex { $0.function.name == "apply_patch" } ?? 0
        let notices = NoticeBox()
        let run = EditingRun.start(ctx)
        run.setNotifier { await notices.add($0) }
        server.script([errorBody(param: "tools[\(k)].format", code: "invalid_value"), reply([doneText])], statuses: [400, 200])
        let response = try? await request(service, ctx, run: run, messages: [Message(role: .user, content: "go")], tools: gptTools, root: root)
        let sent = server.completeRequests.suffix(2).map(\.body)
        t.check("X a classified rejection is resent once in JSON form",
                response != nil && sent.count == 2 && tools(sent[0]).contains { $0["type"] as? String == "custom" }
                && tools(sent[1]).contains { $0["name"] as? String == "apply_patch" && $0["type"] as? String == "function" }
                && !tools(sent[1]).contains { $0["type"] as? String == "custom" })
        let resentSystem = (items(sent.last ?? Data()).first?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        t.check("X the resend's prompt is rebuilt for JSON (P36)", resentSystem.contains("Put the whole patch in the `input` string.") && !resentSystem.contains("FREEFORM"))
        t.check("X the run is JSON for the rest of the run", run.config == .gptJSON && run.didTransition)
        t.check("X the route is recorded; the next run starts in JSON", EditingConfig.resolveAtRunStart(ctx) == .gptJSON)
        let first = await notices.all
        t.check("X exactly one notice (P19)", first == [GPTPatchRoute.transitionNotice], "\(first)")
        // A second run on the same key: no second notice, no custom entry.
        let run2 = EditingRun.start(ctx)
        run2.setNotifier { await notices.add($0) }
        server.script([reply([doneText])])
        _ = try? await request(service, ctx, run: run2, messages: [Message(role: .user, content: "again")], tools: gptTools, root: root)
        let afterSecond = await notices.all
        t.check("X a later run starts in JSON with no notice", run2.config == .gptJSON
                && !tools(server.completeRequests.last?.body ?? Data()).contains { $0["type"] as? String == "custom" } && afterSecond.count == 1)
        // Resend failure is reported accurately.
        try? GPTPatchFormStore.shared.deleteAll()
        let notices2 = NoticeBox()
        let run3 = EditingRun.start(ctx)
        run3.setNotifier { await notices2.add($0) }
        server.script([errorBody(param: "tools[\(k)]", code: "unsupported_value"), errorBody(param: "input", code: "invalid_value")], statuses: [400, 400])
        var failed = false
        do { _ = try await request(service, ctx, run: run3, messages: [Message(role: .user, content: "x")], tools: gptTools, root: root) }
        catch { failed = true }
        let failedNotices = await notices2.all
        t.check("X a failed resend surfaces the error with the 'fallback failed' notice",
                failed && failedNotices == [GPTPatchRoute.transitionFailedNotice], "\(failedNotices)")
        // An unrelated 400 never transitions.
        try? GPTPatchFormStore.shared.deleteAll()
        let run4 = EditingRun.start(ctx)
        server.script([errorBody(param: "input[0]", code: "invalid_value")], statuses: [400])
        _ = try? await request(service, ctx, run: run4, messages: [Message(role: .user, content: "y")], tools: gptTools, root: root)
        t.check("X an unrelated 400 does not transition", run4.config == .gptFreeform && EditingConfig.resolveAtRunStart(ctx) == .gptFreeform)
        try? GPTPatchFormStore.shared.deleteAll()
    }

    actor NoticeBox {
        private var texts: [String] = []
        func add(_ t: String) { texts.append(t) }
        var all: [String] { texts }
    }
}
