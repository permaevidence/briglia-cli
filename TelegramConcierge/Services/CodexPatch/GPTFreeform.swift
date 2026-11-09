import Foundation

/// The freeform `apply_patch` wire form (GPT_APPLY_PATCH_PLAN §5, amendment
/// A1: OpenRouter's Responses endpoint only). The grammar is Codex's, byte
/// for byte (openai/codex 4e4767f `apply_patch.lark`, Apache-2.0; see
/// scripts/fixtures/codex-apply-patch/NOTICE.codex); the selftest checks its
/// SHA-256 against the vendored file.
enum GPTFreeform {
    static let grammar = "start: begin_patch hunk+ end_patch\nbegin_patch: \"*** Begin Patch\" LF\nend_patch: \"*** End Patch\" LF?\n\nhunk: add_hunk | delete_hunk | update_hunk\nadd_hunk: \"*** Add File: \" filename LF add_line+\ndelete_hunk: \"*** Delete File: \" filename LF\nupdate_hunk: \"*** Update File: \" filename LF change_move? change?\n\nfilename: /(.+)/\nadd_line: \"+\" /(.*)/ LF -> line\n\nchange_move: \"*** Move to: \" filename LF\nchange: (change_context | change_line)+ eof_line?\nchange_context: (\"@@\" | \"@@ \" /(.+)/) LF\nchange_line: (\"+\" | \"-\" | \" \") /(.*)/ LF\neof_line: \"*** End of File\" LF\n\n%import common.LF\n"
    static let grammarSHA256 = "d6367f4826ed608c424b0a308f3d6163527df63c22513d089b91863552f8bfeb"

    /// The custom tool entry that takes `apply_patch`'s slot (§5.2).
    static func customToolEntry() -> JSONValue {
        .object(["type": .string("custom"), "name": .string("apply_patch"),
                 "description": .string(AvailableTools.gptApplyPatchFreeformDescription),
                 "format": .object(["type": .string("grammar"), "syntax": .string("lark"), "definition": .string(grammar)])])
    }

    /// The stored, function-shaped arguments of a freeform call (§5.3):
    /// exactly `{"input": …}`, sorted keys.
    static func canonicalArguments(_ input: String) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(["input": input])).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The patch of a stored call whose arguments are exactly one string
    /// key `input` (§5.5), else nil (legacy `patch_text` calls never qualify).
    static func patchInput(_ call: ToolCall) -> String? {
        guard call.function.name == "apply_patch", let data = call.function.arguments.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object.count == 1, let input = object["input"] as? String else { return nil }
        return input
    }
}

/// §5.6 classifier: a provider's refusal of the freeform `apply_patch`
/// entry's TYPE or FORMAT itself (Codex S2 R5: conservative until a live
/// rejection fixture exists). Produced only when ALL hold: HTTP 400; the
/// request carried a `custom` tool entry at index k; and either
/// - `param` is `tools[k].type` or `tools[k].format` (or a sub-path of the
///   format), with a code from `refusalCodes`; or
/// - `param` is the whole entry `tools[k]` with a type-specific code from
///   `typeCodes`.
/// Errors about the entry's name, description or any other field, generic
/// `tools` errors, other tools' errors and history/namespace errors never
/// classify. OpenRouter may wrap the upstream body in
/// `error.metadata.raw`; both shapes are read.
enum GPTCustomToolRejection {
    struct Rejected: Error, LocalizedError {
        let status: Int
        let detail: String
        let underlying: Error
        var errorDescription: String? { (underlying as? LocalizedError)?.errorDescription ?? "\(underlying)" }
    }

    /// Codes that state the tool type or its format is unsupported or
    /// invalid (OpenAI's invalid_request_error vocabulary).
    static let refusalCodes: Set<String> = ["invalid_value", "unsupported_value", "invalid_type",
                                            "unsupported_tool_type", "invalid_tool_type", "unsupported_parameter", "unknown_parameter"]
    /// Codes that by themselves name the tool type as the problem.
    static let typeCodes: Set<String> = ["unsupported_tool_type", "invalid_tool_type"]

    static func customIndices(_ requestBody: Data?) -> Set<Int> {
        guard let requestBody, let object = (try? JSONSerialization.jsonObject(with: requestBody)) as? [String: Any],
              let tools = object["tools"] as? [[String: Any]] else { return [] }
        return Set(tools.indices.filter { tools[$0]["type"] as? String == "custom" })
    }

    /// The error object: the body's own `error`, or the upstream one carried
    /// in OpenRouter's `error.metadata.raw`.
    static func errorObjects(_ rawBody: Data) -> [[String: Any]] {
        guard let object = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return [] }
        var out = [error]
        if let metadata = error["metadata"] as? [String: Any], let raw = metadata["raw"] as? String,
           let inner = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
           let innerError = inner["error"] as? [String: Any] {
            out.append(innerError)
        }
        return out
    }

    static func classify(status: Int, rawBody: Data, requestBody: Data?, underlying: Error) -> Error? {
        guard status == 400 else { return nil }
        let indices = customIndices(requestBody)
        guard !indices.isEmpty, rawBody.count <= 64 * 1024 else { return nil }
        for error in errorObjects(rawBody) {
            guard let param = error["param"] as? String, let code = error["code"] as? String, refusalCodes.contains(code) else { continue }
            for k in indices {
                let base = "tools[\(k)]"
                let typeOrFormat = param == base + ".type" || param == base + ".format"
                    || param.hasPrefix(base + ".format.") || param.hasPrefix(base + ".format[")
                if typeOrFormat || (param == base && typeCodes.contains(code)) {
                    return Rejected(status: status, detail: "\(code) at \(param)", underlying: underlying)
                }
            }
        }
        return nil
    }
}
