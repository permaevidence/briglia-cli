import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GPT apply_patch stage 3 on Sign in with ChatGPT (GPT_APPLY_PATCH_PLAN
/// §5.2–5.6; probe P2, 2026-11-09): the freeform grammar tool inside the
/// `briglia` namespace, namespaced custom calls and their replay, and the
/// §5.6 transition on the route's empty `response.incomplete` refusal.
extension SIWCSelftest {
    static func completedOutput(_ output: [[String: Any]], id: String = "resp_gp") -> Data {
        let object: [String: Any] = ["id": id, "status": "completed", "output": output,
                                     "usage": ["input_tokens": 10, "output_tokens": 2, "input_tokens_details": ["cached_tokens": 0]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func customItem(_ input: String, namespace: String?, callID: String = "call_gp1") -> [String: Any] {
        var item: [String: Any] = ["type": "custom_tool_call", "id": "ctc_1", "status": "completed", "call_id": callID,
                                   "name": "apply_patch", "input": input]
        if let namespace { item["namespace"] = namespace }
        return item
    }

    static func gptPatchTests(_ root: URL, _ c: Checks) async throws {
        GPTPatchFormStore.fileURLOverrideForTesting = root.appendingPathComponent("gpt-patch-form.json")
        GPTPatchFormStore.shared.resetCacheForTesting()
        GPTPatchSwitch.storedOverrideForTesting = { nil }
        defer {
            try? GPTPatchFormStore.shared.deleteAll()
            GPTPatchFormStore.fileURLOverrideForTesting = nil
            GPTPatchFormStore.shared.resetCacheForTesting()
            GPTPatchSwitch.storedOverrideForTesting = nil
        }
        let (source, _) = try await liveSelection(clientId: "oaiappGPTPatch")
        let wire = Wire(); wire.install()
        let context = ProviderExecutionContext.siwcContext(source: source, model: "gpt-6-luna", effort: "medium", lane: .main,
                                                           textOnly: false, nativeToolMedia: false)
        let run = EditingRun.start(context)
        c.check("gpt-patch: a GPT run on Sign in with ChatGPT starts in the freeform form", run.config == .gptFreeform)
        let tools = AvailableTools.all(includeWebSearch: false, editing: run.config)
        let patch = "*** Begin Patch\n*** Update File: /tmp/siwc.txt\n@@\n-a\n+b\n*** End Patch\n"
        let service = OpenRouterService()
        let human = Message(role: .user, content: "edit it")
        func send(_ rounds: [ToolInteraction]? = nil, run: EditingRun) async throws -> LLMResponse {
            try await service.generateResponse(messages: [human], imagesDirectory: root, documentsDirectory: root, tools: tools,
                                               toolResultMessages: rounds, execution: context, lane: .main, editingRun: run)
        }
        func namespaceTools(_ body: [String: JSONValue]) -> [[String: JSONValue]] {
            guard let top = body["tools"]?.responsesArray, top.count == 1, let ns = top[0].responsesObject,
                  ns["type"]?.responsesString == "namespace", ns["name"]?.responsesString == SIWCEndpoint.namespace else { return [] }
            return (ns["tools"]?.responsesArray ?? []).compactMap { $0.responsesObject }
        }
        func input(_ body: [String: JSONValue]) -> [[String: JSONValue]] {
            (body["input"]?.responsesArray ?? []).compactMap { $0.responsesObject }
        }

        // R1 shape: the grammar tool inside the namespace; a namespaced custom call decodes.
        wire.replies = [.success(completedOutput([customItem(patch, namespace: SIWCEndpoint.namespace)]))]
        let first = try? await send(run: run)
        let inner = wire.count > 0 ? namespaceTools(wire.body(0)) : []
        let slot = tools.firstIndex { $0.function.name == "apply_patch" } ?? -1
        c.check("gpt-patch: request: every tool inside the one `briglia` namespace, the grammar tool in apply_patch's slot",
                inner.count == tools.count && slot >= 0 && inner[slot]["type"]?.responsesString == "custom"
                && inner[slot]["name"]?.responsesString == "apply_patch"
                && inner[slot]["format"]?.responsesObject?["definition"]?.responsesString == GPTFreeform.grammar
                && inner.enumerated().allSatisfy { $0.offset == slot || $0.element["type"]?.responsesString == "function" })
        c.check("gpt-patch: the body passes the SIWC invariants", wire.count > 0 && (try? SIWCBody.check(wire.body(0))) != nil)
        let firstRaw = wire.count > 0 ? wire.rawBody(0) : ""
        c.check("gpt-patch: the request body names no tool GPT lacks (pre-release review S2)",
                !firstRaw.isEmpty && !["edit_file", "write_file", "old_string"].contains(where: { firstRaw.contains($0) }))
        guard case .toolCalls(let assistant, let calls, _, _, _)? = first, let call = calls.first else {
            c.check("gpt-patch: a namespaced custom_tool_call decodes", false); return
        }
        c.check("gpt-patch: a namespaced custom_tool_call decodes as apply_patch {\"input\"}",
                call.function.name == "apply_patch" && GPTFreeform.patchInput(call) == patch)
        // The decoder refuses a custom call outside the advertised namespace.
        let scope = ResponsesScope(endpoint: "x", profile: "p", model: "m", credentialFingerprint: "f")
        let receipt = PreparedRequestReceipt(requestID: UUID(), historyFingerprint: "gp", deliveryNonces: [])
        for (label, ns) in [("missing", nil), ("foreign", "evil")] as [(String, String?)] {
            c.check("gpt-patch: decoder refuses a custom call with a \(label) namespace",
                    (try? ResponsesRoundDecoder.decode(completedOutput([customItem(patch, namespace: ns)]), scope: scope, receipt: receipt,
                                                       allowedTools: ["apply_patch"], requiredNamespace: SIWCEndpoint.namespace,
                                                       freeformTools: ["apply_patch"])) == nil)
        }
        c.check("gpt-patch: decoder still refuses a namespaced custom call when freeform is not exposed",
                (try? ResponsesRoundDecoder.decode(completedOutput([customItem(patch, namespace: SIWCEndpoint.namespace)]), scope: scope,
                                                   receipt: receipt, allowedTools: ["apply_patch"], requiredNamespace: SIWCEndpoint.namespace)) == nil)

        // R2 shape: native replay of the custom item carries the namespace; its output does not.
        let round = ToolInteraction(assistantMessage: assistant, results: [ToolResultMessage(toolCallId: call.id, content: "Success. Updated the following files:\nM /tmp/siwc.txt")])
        wire.replies = [.success(completed(text: "done"))]
        let sentBefore = wire.count
        _ = try? await send([round], run: run)
        let replay = wire.count > sentBefore ? input(wire.body(sentBefore)) : []
        let nativeCall = replay.first { $0["type"]?.responsesString == "custom_tool_call" }
        let nativeOut = replay.first { $0["type"]?.responsesString == "custom_tool_call_output" }
        c.check("gpt-patch: native replay: custom_tool_call in the namespace, string output without one",
                nativeCall?["namespace"]?.responsesString == SIWCEndpoint.namespace && nativeCall?["input"]?.responsesString == patch
                && nativeOut?["call_id"]?.responsesString == nativeCall?["call_id"]?.responsesString
                && nativeOut?["namespace"] == nil && nativeOut?["output"]?.responsesString?.contains("Success. Updated") == true)
        var semanticAssistant = assistant
        semanticAssistant.responsesReplay = nil
        wire.replies = [.success(completed(text: "done"))]
        let semanticBefore = wire.count
        _ = try? await send([ToolInteraction(assistantMessage: semanticAssistant, results: round.results)], run: run)
        let semantic = wire.count > semanticBefore ? input(wire.body(semanticBefore)) : []
        c.check("gpt-patch: semantic replay renders a namespaced custom item while freeform is exposed",
                semantic.contains { $0["type"]?.responsesString == "custom_tool_call" && $0["namespace"]?.responsesString == SIWCEndpoint.namespace }
                && semantic.contains { $0["type"]?.responsesString == "custom_tool_call_output" })
        var stray = wire.body(wire.count - 1)
        stray["input"] = .array((stray["input"]?.responsesArray ?? []) + [.object(["type": .string("custom_tool_call"),
            "call_id": .string("c9"), "name": .string("apply_patch"), "input": .string("x")])])
        c.check("gpt-patch: SIWCBody.check refuses a custom call outside the namespace", (try? SIWCBody.check(stray)) == nil)
        if let namespacedAgain = try? SIWCBody.namespaced([.object(["type": .string("custom_tool_call"), "call_id": .string("c"),
                                                                    "name": .string("apply_patch"), "input": .string("x")])]) {
            c.check("gpt-patch: SIWCBody.namespaced adds the namespace to a replayed custom call",
                    namespacedAgain.first?.responsesObject?["namespace"]?.responsesString == SIWCEndpoint.namespace)
        } else { c.check("gpt-patch: SIWCBody.namespaced adds the namespace to a replayed custom call", false) }
        c.check("gpt-patch: SIWCBody.namespaced refuses a custom call in another namespace",
                (try? SIWCBody.namespaced([.object(["type": .string("custom_tool_call"), "call_id": .string("c"), "name": .string("apply_patch"),
                                                    "input": .string("x"), "namespace": .string("evil")])])) == nil)

        // §5.6 on SIWC, positive evidence: a streamed grammar refusal →
        // one transition, the same request resent once with apply_patch as a
        // namespaced function; one notice; recorded for this route key.
        let larkFailed: [String: Any] = ["error": ["code": "invalid_prompt", "message": "Invalid lark grammar. 1(3): x"]]
        guard let (terminal, sawOutput) = GPTProfileSelftest.assemble(GPTProfileSelftest.emptyTerminalSSE("response.failed", extra: larkFailed), siwc: true),
              !sawOutput else { c.check("gpt-patch: synthetic SIWC grammar refusal assembles", false); return }
        let notices = GPTProfileSelftest.NoticeBox()
        let run2 = EditingRun.start(context)
        run2.setNotifier { await notices.add($0) }
        wire.replies = [.success(terminal), .success(completed(text: "fallback ok"))]
        let before = wire.count
        let response = try? await send(run: run2)
        let sentFirst = wire.count > before ? namespaceTools(wire.body(before)) : []
        let sentSecond = wire.count > before + 1 ? namespaceTools(wire.body(before + 1)) : []
        let notes = await notices.all
        c.check("gpt-patch: SIWC streamed grammar refusal → resent once in JSON form inside the namespace",
                response != nil && wire.count == before + 2
                && sentFirst.contains { $0["type"]?.responsesString == "custom" }
                && !sentSecond.contains { $0["type"]?.responsesString == "custom" }
                && sentSecond.contains { $0["name"]?.responsesString == "apply_patch" && $0["type"]?.responsesString == "function" })
        c.check("gpt-patch: SIWC transition: run JSON, one notice, recorded for the siwc route key",
                run2.config == .gptJSON && notes == [GPTPatchRoute.transitionNotice]
                && GPTPatchFormStore.shared.records().keys.contains { $0.hasPrefix("siwc|") }
                && EditingConfig.resolveAtRunStart(context) == .gptJSON, "\(notes)")
        // The route's own empty `response.incomplete` (probe P2 R5) is NOT a
        // refusal (Codex S3 R1 F1): ordinary error, no resend, nothing recorded.
        try? GPTPatchFormStore.shared.deleteAll()
        for (label, extra) in [("no reason", [:]), ("server_error reason", ["incomplete_details": ["reason": "server_error"]]),
                               ("unrelated error", ["error": ["code": "server_error", "message": "Temporary backend failure"]])] as [(String, [String: Any])] {
            guard let (empty, _) = GPTProfileSelftest.assemble(GPTProfileSelftest.emptyTerminalSSE("response.incomplete", extra: extra), siwc: true) else {
                c.check("gpt-patch: SIWC empty incomplete (\(label)) assembles", false); continue
            }
            let runI = EditingRun.start(context)
            wire.replies = [.success(empty), .success(completed(text: "should not be sent"))]
            let beforeI = wire.count
            var surfaced = false
            do { _ = try await send(run: runI) } catch {
                if let failure = error as? ResponsesFailure, case .incomplete = failure { surfaced = true }
            }
            c.check("gpt-patch: SIWC empty incomplete (\(label)) surfaces as an ordinary incomplete: no resend, nothing recorded",
                    surfaced && wire.count == beforeI + 1 && runI.config == .gptFreeform
                    && GPTPatchFormStore.shared.records().isEmpty && EditingConfig.resolveAtRunStart(context) == .gptFreeform)
            wire.replies = []
        }
        // §10 foreign-call repair, now on SIWC too (decodeRound): namespaced
        // foreign edit calls decode as blocked calls in both directions; the
        // namespace and every other decoder check still apply.
        func fnCall(_ name: String, namespace: String?) -> [String: Any] {
            var item: [String: Any] = ["type": "function_call", "id": "fc_r", "call_id": "call_r", "name": name, "arguments": "{\"path\":\"/a\"}", "status": "completed"]
            if let namespace { item["namespace"] = namespace }
            return item
        }
        var siwcRequest = URLRequest(url: URL(string: SIWCEndpoint.responsesURL)!)
        siwcRequest.httpBody = Data("{}".utf8)
        func repaired(_ name: String, namespace: String?, editing: EditingConfig, exposed: Set<String>) -> String? {
            var ctx = context; ctx.editing = editing
            let round = try? ResponsesAdapter.decodeRound(completedOutput([fnCall(name, namespace: namespace)]), request: siwcRequest, context: ctx,
                                                          receipt: receipt, allowed: exposed, requiredNamespace: SIWCEndpoint.namespace,
                                                          streamedOutput: false)
            return round?.calls.first?.function.name
        }
        c.check("gpt-patch: SIWC repair: a GPT model's namespaced edit_file decodes as a blocked call (hint names apply_patch)",
                repaired("edit_file", namespace: SIWCEndpoint.namespace, editing: .gptFreeform, exposed: ["apply_patch", "read_file"]) == "edit_file"
                && GPTForeignCall.hint(name: "edit_file", editing: .gptFreeform, exposed: ["apply_patch", "read_file"]) != nil)
        c.check("gpt-patch: SIWC repair: a standard model's namespaced apply_patch decodes as a blocked call (hint names edit_file)",
                repaired("apply_patch", namespace: SIWCEndpoint.namespace, editing: .standard, exposed: ["edit_file", "read_file"]) == "apply_patch"
                && GPTForeignCall.hint(name: "apply_patch", editing: .standard, exposed: ["edit_file", "read_file"]) != nil)
        c.check("gpt-patch: SIWC repair keeps the namespace check (missing or foreign namespace refused)",
                repaired("edit_file", namespace: nil, editing: .gptFreeform, exposed: ["apply_patch"]) == nil
                && repaired("edit_file", namespace: "evil", editing: .gptFreeform, exposed: ["apply_patch"]) == nil)
        c.check("gpt-patch: SIWC repair never admits an unrelated unexposed tool",
                repaired("bash", namespace: SIWCEndpoint.namespace, editing: .gptFreeform, exposed: ["apply_patch"]) == nil)
        // A completed answer with no output is NOT a refusal on SIWC.
        try? GPTPatchFormStore.shared.deleteAll()
        let run3 = EditingRun.start(context)
        wire.replies = [.success(completedOutput([]))]
        let before3 = wire.count
        var ordinary = false
        do { _ = try await send(run: run3) } catch { ordinary = !(error is GPTCustomToolRejection.Rejected) }
        c.check("gpt-patch: an empty completed answer surfaces as today (no transition, no resend)",
                ordinary && run3.config == .gptFreeform && wire.count == before3 + 1)
    }
}
