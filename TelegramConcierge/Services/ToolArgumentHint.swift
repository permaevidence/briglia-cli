import Foundation

/// Names the argument keys a tool call actually arrived with when a tool's
/// LOCAL validation rejects it for a missing top-level argument (0.2.63,
/// REMINDERS_LOAD_AND_ARG_HINT_PLAN §1). Incident: an OpenRouter host
/// delivered every call with only its first argument (`{"action":"set"}`);
/// the agent read "trigger_datetime and prompt are required" and could not
/// tell a broken host from its own mistake.
///
/// Only the TEXT of a qualifying error result changes: the original error
/// stays a verbatim prefix; keys are listed, values never are (they may hold
/// secrets).
enum ToolArgumentHint {
    /// When a message counts as "a top-level argument did not arrive".
    enum Presence {
        /// Every listed field is required: at least one is absent.
        case anyAbsent([String])
        /// Alternatives (choose one): none of them arrived. A supplied but
        /// blank/invalid alternative is the model's value problem → no hint.
        case noneArrived([String])
        /// edit_file formats: neither format started, or exactly one of the
        /// old_string/new_string pair arrived (and no `edits`).
        case editFormats

        func dropped(_ sent: Set<String>) -> Bool {
            switch self {
            case .anyAbsent(let fields): return fields.contains { !sent.contains($0) }
            case .noneArrived(let fields): return !fields.contains { sent.contains($0) }
            case .editFormats:
                if sent.contains("edits") { return false }
                return !(sent.contains("old_string") && sent.contains("new_string"))
            }
        }
    }

    struct Rule {
        let tool: String
        let prefix: String
        let presence: Presence
        init(tool: String, prefix: String, fields: [String]) {
            self.tool = tool; self.prefix = prefix; self.presence = .anyAbsent(fields)
        }
        init(tool: String, prefix: String, presence: Presence) {
            self.tool = tool; self.prefix = prefix; self.presence = presence
        }
    }

    /// The local top-level validation messages and the fields each is about.
    /// Explicit on purpose (Codex round 1): nested validation, optional-remedy
    /// suggestions, MCP tools and `mcp_call` (it forwards server text) are not
    /// listed and never get a hint. A smoke check asserts every prefix still
    /// occurs verbatim in the sources.
    static let rules: [Rule] = [
        Rule(tool: "manage_reminders", prefix: "For action 'set', trigger_datetime and prompt are required", fields: ["trigger_datetime", "prompt"]),
        Rule(tool: "manage_reminders", prefix: "For an external-trigger watcher, prompt is required", fields: ["prompt"]),
        Rule(tool: "manage_reminders", prefix: "For action 'delete', provide one of: reminder_id, reminder_ids, delete_all=true", presence: .noneArrived(["reminder_id", "reminder_ids", "delete_all", "delete_recurring"])),
        Rule(tool: "manage_reminders", prefix: "For action 'resume', provide reminder_id", fields: ["reminder_id"]),
        Rule(tool: "manage_reminders", prefix: "For action 'update_triage', provide reminder_id", fields: ["reminder_id"]),
        Rule(tool: "manage_reminders", prefix: "For action 'update_triage', provide notify, triage_instructions and/or triage_model", presence: .noneArrived(["notify", "triage_instructions", "triage_model"])),
        Rule(tool: "manage_calendar", prefix: "For action 'add', title and datetime are required", fields: ["title", "datetime"]),
        Rule(tool: "manage_calendar", prefix: "For action 'delete', event_id is required", fields: ["event_id"]),
        Rule(tool: "manage_calendar", prefix: "For action 'edit', event_id is required", fields: ["event_id"]),
        Rule(tool: "read_file", prefix: "read_file requires 'path'", fields: ["path"]),
        Rule(tool: "write_file", prefix: "write_file requires 'path'", fields: ["path"]),
        Rule(tool: "write_file", prefix: "write_file requires 'content'", fields: ["content"]),
        Rule(tool: "edit_file", prefix: "edit_file requires 'path'", fields: ["path"]),
        Rule(tool: "edit_file", prefix: "edit_file requires either 'edits' array or 'old_string'+'new_string'", presence: .editFormats),
        Rule(tool: "apply_patch", prefix: "apply_patch requires 'patch_text'", fields: ["patch_text"]),
        Rule(tool: "grep", prefix: "grep requires 'pattern' and 'path'", fields: ["pattern", "path"]),
        Rule(tool: "glob", prefix: "glob requires 'pattern'", fields: ["pattern"]),
        Rule(tool: "list_dir", prefix: "list_dir requires 'path'", fields: ["path"]),
        Rule(tool: "lsp", prefix: "lsp requires 'mode'", fields: ["mode"]),
        Rule(tool: "lsp", prefix: "lsp requires 'path'", fields: ["path"]),
        Rule(tool: "lsp", prefix: "mode='workspace_symbols' requires 'query'", fields: ["query"]),
        Rule(tool: "bash", prefix: "bash requires 'command'", fields: ["command"]),
        Rule(tool: "bash_manage", prefix: "bash_manage requires 'handle'", fields: ["handle"]),
        Rule(tool: "bash_manage", prefix: "bash_manage requires 'mode'", fields: ["mode"]),
        Rule(tool: "bash_manage", prefix: "mode='wait' requires 'wait_seconds'", fields: ["wait_seconds"]),
        Rule(tool: "bash_manage", prefix: "mode='input' requires 'text'", fields: ["text"]),
        Rule(tool: "bash_manage", prefix: "mode='watch' requires 'pattern'", fields: ["pattern"]),
        Rule(tool: "subagent_manage", prefix: "subagent_manage requires 'mode'", fields: ["mode"]),
        Rule(tool: "todo_write", prefix: "todo_write requires 'todos'", fields: ["todos"]),
        Rule(tool: "skill", prefix: "skill_name is required", fields: ["skill_name"]),
        Rule(tool: "tool_search", prefix: "'server' parameter is required.", fields: ["server"]),
        Rule(tool: "inspect_media", prefix: "inspect_media requires 'filename'", fields: ["filename"]),
        Rule(tool: "inspect_media", prefix: "inspect_media requires 'question'", fields: ["question"]),
        Rule(tool: "web_fetch", prefix: "Failed to parse web_fetch arguments. Required: url (string), prompt (string).", fields: ["url", "prompt"]),
        Rule(tool: "web_fetch", prefix: "web_fetch requires a non-empty prompt", fields: ["prompt"]),
        Rule(tool: "shortcuts", prefix: "shortcuts action='run' requires a non-empty name", fields: ["name"]),
        Rule(tool: "read_chunk_summaries", prefix: "Provide chunk_ids", presence: .noneArrived(["chunk_ids", "from", "to"])),
        Rule(tool: "list_conversation_chunks", prefix: "Provide chunk_ids", presence: .noneArrived(["chunk_ids", "from", "to"])),
    ]

    /// The new result content, or nil to leave it unchanged.
    static func annotate(content: String, toolName: String, argumentsJSON: String,
                         setup: ToolCallRouting.Setup?) -> String? {
        let candidates = rules.filter { $0.tool == toolName }
        guard !candidates.isEmpty,
              content.contains("\"error\""),
              let contentData = content.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: contentData)) as? [String: Any],
              object.count == 1,
              let error = object["error"] as? String,
              let rule = candidates.first(where: { error.hasPrefix($0.prefix) }) else { return nil }
        let raw = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent: Set<String>
        if raw.isEmpty {
            sent = []
        } else {
            guard let argsData = raw.data(using: .utf8),
                  let args = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any] else { return nil }
            sent = Set(args.keys)
        }
        // A field that arrived (even blank or invalid) is the model's value
        // problem, not a dropped key.
        guard rule.presence.dropped(sent) else { return nil }

        let keyList = sent.isEmpty ? "no arguments" : "only: " + sent.sorted().joined(separator: ", ")
        var note = " (the call arrived with \(keyList)"
        if sent.count <= 1 {
            note += " — the call may have lost arguments on the way: " + hostClause(setup)
        }
        note += ")"
        guard let out = try? JSONSerialization.data(withJSONObject: ["error": error + note], options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8) else { return nil }
        return text
    }

    /// Owner wording (2026-10-25): depends on the setup of the request that
    /// produced the call; never "/orprovider off".
    static func hostClause(_ setup: ToolCallRouting.Setup?) -> String {
        switch setup {
        case .openRouterPinned(let hosts)?:
            let names = hosts.isEmpty ? "" : " (\(hosts.joined(separator: ", ")))"
            return "if you did send the other fields, the OpenRouter host this model is pinned to\(names) may be dropping tool arguments; tell the user — choosing a different host with /orprovider may fix it"
        case .openRouterAutomatic?:
            return "if you did send the other fields, the model provider may be dropping tool arguments; tell the user — trying another model with /model may fix it"
        case .otherProvider?:
            return "if you did send the other fields, the model provider or server may be dropping tool arguments; tell the user — trying another model, or checking that provider/server, may help"
        case nil:
            return "if you did send the other fields, the model provider may be dropping tool arguments; tell the user"
        }
    }
}

/// The provider setup of the request that produced a tool call, taken from
/// that request's own `ProviderExecutionContext` snapshot when the response
/// arrives and carried on the call itself (`ToolCall.routing`, never
/// serialised). Nothing is read at execution time, so concurrent `/model` or
/// `/orprovider` changes cannot affect it; only the provider kind and the
/// pinned host slugs are kept (no credentials).
enum ToolCallRouting {
    enum Setup: Equatable {
        case openRouterPinned([String])
        case openRouterAutomatic
        case otherProvider
    }

    static func setup(for context: ProviderExecutionContext) -> Setup {
        guard context.provider == .openRouter else { return .otherProvider }
        if let only = context.providerPreferences?.only, !only.isEmpty { return .openRouterPinned(only) }
        return .openRouterAutomatic
    }

    /// The response with every call stamped with `setup`; other cases as is.
    static func stamp(_ response: LLMResponse, setup: Setup) -> LLMResponse {
        guard case .toolCalls(let assistant, let calls, let prompt, let completion, let spend) = response else { return response }
        let stamped = calls.map { call -> ToolCall in
            var copy = call
            copy.routing = setup
            return copy
        }
        return .toolCalls(assistantMessage: assistant, calls: stamped, promptTokens: prompt, completionTokens: completion, spendUSD: spend)
    }
}
