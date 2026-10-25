import Foundation

/// H rows: the missing-argument hint (ToolArgumentHint, ToolCallRouting).
extension RemLoadHarness {
    static let setPrefix = "For action 'set', trigger_datetime and prompt are required"
    var setError: String { #"{"error":"For action 'set', trigger_datetime and prompt are required"}"# }

    func hint(_ tool: String, _ content: String, _ args: String, _ setup: ToolCallRouting.Setup? = nil) -> String? {
        ToolArgumentHint.annotate(content: content, toolName: tool, argumentsJSON: args, setup: setup)
    }

    func errorText(_ content: String?) -> String {
        guard let content, let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return object["error"] as? String ?? ""
    }

    /// The incident shape, for each request setup (owner wording 2026-10-25).
    func rowH1() {
        let args = #"{"action":"set"}"#
        let pinned = errorText(hint("manage_reminders", setError, args, .openRouterPinned(["inference-net"])))
        check("H1 original error is a verbatim prefix", pinned.hasPrefix(Self.setPrefix))
        check("H1 lists the arrived key", pinned.contains("(the call arrived with only: action"))
        check("H1 pinned: names the host and /orprovider", pinned.contains("(inference-net)") && pinned.contains("/orprovider"))
        let auto = errorText(hint("manage_reminders", setError, args, .openRouterAutomatic))
        check("H1 automatic routing: /model, no /orprovider", auto.contains("/model") && !auto.contains("/orprovider"))
        let other = errorText(hint("manage_reminders", setError, args, .otherProvider))
        check("H1 other provider: no /orprovider, checks the provider/server", !other.contains("/orprovider") && other.contains("provider/server"))
        let unknown = errorText(hint("manage_reminders", setError, args, nil))
        check("H1 unknown setup: generic wording", unknown.contains("may be dropping tool arguments") && !unknown.contains("/orprovider") && !unknown.contains("/model"))
        let all = [pinned, auto, other, unknown]
        check("H1 never '/orprovider off'", !all.contains { $0.contains("/orprovider off") })
        let secret = errorText(hint("bash_manage", #"{"error": "bash_manage requires 'handle'"}"#, #"{"mode":"sk-or-v1-SECRETVALUE123"}"#, .openRouterAutomatic))
        check("H1 argument values never appear", secret.contains("only: mode") && !secret.contains("SECRETVALUE"))
        let empty = errorText(hint("list_dir", #"{"error": "list_dir requires 'path'"}"#, "{}", nil))
        check("H1 no keys → 'no arguments'", empty.contains("arrived with no arguments"))
    }

    /// No hint / key list without the routing clause.
    func rowH2() {
        let none: [(String, String, String, String)] = [
            ("edit_file non-unique (replace_all remedy)", "edit_file", #"{"error": "old_string matches 2 times. Provide more surrounding context to make it unique, or pass replace_all=true"}"#, #"{"path":"/a","old_string":"x","new_string":"y"}"#),
            ("nested edits[0]", "edit_file", #"{"error": "edits[0] requires 'new_string'"}"#, #"{"path":"/a","edits":[{"old_string":"x"}]}"#),
            ("mcp_call forwarded JSON", "mcp_call", #"{"error":"missing arguments"}"#, #"{"server":"s","tool":"t"}"#),
            ("MCP tool", "mcp__srv__tool", #"{"error":"x requires 'y'"}"#, #"{"a":1}"#),
            ("success result", "manage_reminders", #"{"success":true}"#, #"{"action":"set"}"#),
            ("blank supplied field", "manage_reminders", setError, #"{"action":"set","trigger_datetime":"","prompt":""}"#),
            ("malformed arguments", "manage_reminders", setError, #"{"action":"set""#),
            ("two-key error object", "manage_reminders", #"{"error":"For action 'set', trigger_datetime and prompt are required","hint":"x"}"#, #"{"action":"set"}"#),
            ("blank reminder_id", "manage_reminders", #"{"error":"For action 'delete', provide one of: reminder_id, reminder_ids, delete_all=true, or delete_recurring=true"}"#, #"{"action":"delete","reminder_id":" "}"#),
            ("empty reminder_ids", "manage_reminders", #"{"error":"For action 'delete', provide one of: reminder_id, reminder_ids, delete_all=true, or delete_recurring=true"}"#, #"{"action":"delete","reminder_ids":[]}"#),
            ("delete_all false", "manage_reminders", #"{"error":"For action 'delete', provide one of: reminder_id, reminder_ids, delete_all=true, or delete_recurring=true"}"#, #"{"action":"delete","delete_all":false}"#),
            ("edits format chosen (blank)", "edit_file", #"{"error": "edit_file requires either 'edits' array or 'old_string'+'new_string'"}"#, #"{"path":"/a","edits":[]}"#),
            ("pair format complete (blank)", "edit_file", #"{"error": "edit_file requires either 'edits' array or 'old_string'+'new_string'"}"#, #"{"path":"/a","old_string":"","new_string":""}"#),
            ("plain-text result", "bash", "bash requires 'command'", "{}"),
        ]
        for (label, tool, content, args) in none {
            check("H2 no hint: \(label)", hint(tool, content, args, .openRouterAutomatic) == nil)
        }
        let delete = errorText(hint("manage_reminders", #"{"error":"For action 'delete', provide one of: reminder_id, reminder_ids, delete_all=true, or delete_recurring=true"}"#, #"{"action":"delete"}"#, .openRouterAutomatic))
        check("H2 delete with no selector at all → hint", delete.contains("only: action"))
        let pair = errorText(hint("edit_file", #"{"error": "edit_file requires either 'edits' array or 'old_string'+'new_string'"}"#, #"{"old_string":"x","path":"/a"}"#, .openRouterAutomatic))
        check("H2 pair half-arrived → key list, no routing clause (2 keys)", pair.contains("(the call arrived with only: old_string, path)") && !pair.contains("dropping"))
        let three = errorText(hint("manage_reminders", setError, #"{"action":"set","notify":"main","prompt":"p"}"#, .openRouterPinned(["x"])))
        check("H2 3-key qualifying call → key list, no routing clause", three.hasSuffix("(the call arrived with only: action, notify, prompt)"))
    }

    /// Through ToolExecutor.execute: the hint lands before appended payloads,
    /// and the result still classifies as an error.
    func rowH3() async {
        let executor = ToolExecutor()
        var call = ToolCall(id: "h3", type: "function", function: FunctionCall(name: "manage_reminders", arguments: #"{"action":"set"}"#))
        call.routing = .openRouterPinned(["inference-net"])
        let result = try? await executor.execute(call)
        let content = result?.content ?? ""
        check("H3 executor result carries the hint", errorText(content).contains("arrived with only: action") && content.contains("inference-net"))
        check("H3 still classified as an error", content.contains("\"error\""))
        check("H3 attachments untouched", (result?.fileAttachments.isEmpty ?? false) && result?.spendUSD == nil)
        var plain = call
        plain.routing = nil
        let unknown = (try? await executor.execute(plain))?.content ?? ""
        check("H3 unstamped call → generic wording", errorText(unknown).contains("may be dropping") && !unknown.contains("/orprovider"))
    }

    /// Carrier: stamping per request, never encoded, nil when decoded.
    func rowH4() {
        let call = ToolCall(id: "c1", type: "function", function: FunctionCall(name: "bash", arguments: #"{"x":1}"#))
        let assistant = AssistantToolCallMessage(content: nil, toolCalls: [call])
        let response = LLMResponse.toolCalls(assistantMessage: assistant, calls: [call], promptTokens: 1, completionTokens: 2, spendUSD: 0.5)
        let stamped = ToolCallRouting.stamp(response, setup: .openRouterPinned(["a", "b"]))
        if case .toolCalls(_, let calls, let p, let c, let s) = stamped {
            check("H4 every call stamped; counters kept", calls.map { $0.routing } == [ToolCallRouting.Setup.openRouterPinned(["a", "b"])] && p == 1 && c == 2 && s == 0.5)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            check("H4 a stamped call encodes byte-identically", (try? encoder.encode(calls[0])) == (try? encoder.encode(call)))
            let decoded = (try? encoder.encode(calls[0])).flatMap { try? JSONDecoder().decode(ToolCall.self, from: $0) }
            check("H4 a decoded call has no routing", decoded != nil && decoded?.routing == nil)
        } else {
            check("H4 stamping keeps .toolCalls", false)
        }
        let text = LLMResponse.text("hi", reasoning: nil, reasoningDetails: nil, promptTokens: nil, completionTokens: nil, spendUSD: nil)
        if case .text = ToolCallRouting.stamp(text, setup: .otherProvider) { check("H4 text responses untouched", true) } else { check("H4 text responses untouched", false) }
    }
}

extension RemLoadHarness {
    /// The setup comes from the service's real per-request context; a call
    /// returned by generateResponse is stamped; a later settings change does
    /// not touch an already-stamped call.
    func rowH5() async {
        let router = LLMProvider.openRouter.rawValue
        try? KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: router)
        try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "deepseek/deepseek-v4.1-flash-1017")
        let service = OpenRouterService()
        await service.configure(apiKey: "synthetic-h5-key")
        try? OpenRouterProviderPin._testSetPin(["inference-net"])
        let pinned = await service.executionContext(modelOverride: nil, providerOverride: nil,
            reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main)
        check("H5 OpenRouter + pin → pinned setup naming the host", ToolCallRouting.setup(for: pinned) == .openRouterPinned(["inference-net"]))
        try? OpenRouterProviderPin._testSetPin(nil)
        let automatic = await service.executionContext(modelOverride: nil, providerOverride: nil,
            reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main)
        check("H5 OpenRouter without pin → automatic", ToolCallRouting.setup(for: automatic) == .openRouterAutomatic)

        guard let server = try? CaptureServer() else { check("H5 loopback server", false); return }
        defer { server.stop() }
        let body = #"{"choices":[{"message":{"role":"assistant","content":"calling","tool_calls":[{"id":"c1","type":"function","function":{"name":"manage_reminders","arguments":"{\"action\":\"set\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
        server.script([body])
        try? KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openAICompatible.rawValue)
        try? KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: "http://127.0.0.1:\(server.port)/v1")
        try? KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "custom-model")
        try? KeychainHelper.save(key: KeychainHelper.openAICompatibleApiKeyKey, value: "synthetic-h5-key")
        let custom = OpenRouterService()
        await custom.configure(apiKey: "synthetic-h5-key")
        let scratch = dataRoot.appendingPathComponent("h5", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let response = try? await custom.generateResponse(messages: [Message(role: .user, content: "hi", timestamp: Date())],
            imagesDirectory: scratch, documentsDirectory: scratch, lane: .main)
        guard case .toolCalls(let assistant, let calls, let prompt, _, _)? = response else {
            check("H5 custom endpoint returned tool calls", false, "\(String(describing: response))"); return
        }
        check("H5 generateResponse stamps the call with the request's setup (other provider)", calls.map { $0.routing } == [ToolCallRouting.Setup.otherProvider])
        check("H5 stamping keeps assistant text and usage", assistant.content == "calling" && prompt == 10)
        try? KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: router)
        check("H5 a settings change after the response leaves the stamped call as it was", calls[0].routing == .otherProvider)
        let withKey = #"{"id":"c9","type":"function","function":{"name":"bash","arguments":"{}"},"routing":"openRouterAutomatic"}"#
        let decoded = try? JSONDecoder().decode(ToolCall.self, from: Data(withKey.utf8))
        check("H5 a serialized 'routing' key is ignored on decode", decoded != nil && decoded?.routing == nil)
        try? FileManager.default.removeItem(at: scratch)
    }
}
