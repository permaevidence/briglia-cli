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
/// request carried a `custom` tool entry at index k (or a namespaced one,
/// below); and either
/// - `param` is `tools[k].type` or `tools[k].format` (or a sub-path of the
///   format), with a code from `refusalCodes`; or
/// - `param` is the whole entry `tools[k]` with a type-specific code from
///   `typeCodes`.
/// Explicit subfield errors about the entry's name, description or any other
/// field, other tools' errors and history/namespace errors never classify
/// (OpenRouter's coarse whole-entry validation issue below does not say
/// which nested field failed; accepted because the entry is fixed — plan §24). OpenRouter may
/// wrap the upstream body in `error.metadata.raw`; both shapes are read.
///
/// Real refusals captured live on 2026-11-09 (fixtures
/// scripts/fixtures/codex-apply-patch/provider-errors/) add two shapes:
/// - OpenAI names the whole array: `param` exactly `tools`, and either a
///   code from `refusalCodes` with a message naming the `'custom'` type
///   ("Invalid value: 'custom'", unknown_parameter: a model without custom
///   tools) or a message starting "Invalid lark grammar" (code null: the
///   host refused the entry's grammar). Any other `tools` error never
///   classifies.
/// - OpenRouter's own request validation: `error.code` `invalid_prompt` with
///   a top-level `metadata.raw` JSON array of validation issues, one of
///   them at path exactly `["tools", k]` for a custom entry k. Issues at any
///   other path (input, reasoning, tool_choice, other tools) never classify.
///
/// Stage 3 (ChatGPT routes, 2026-11-09): "the entry" is a top-level
/// `tools[k]` or, on Sign in with ChatGPT where every tool sits inside the
/// `briglia` namespace, `tools[i].tools[j]` (`customEntries`); SIWC's own
/// `unsupported_capability` naming that entry (`classifySIWCCapability`);
/// and the HTTP-200 streamed grammar refusal (`classifyTerminal`).
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

    /// Where the request carried a `custom` tool entry: the `param` base
    /// string OpenAI-style errors use and the JSON path OpenRouter's
    /// validation issues use. Top-level entries (`tools[k]`, ["tools", k])
    /// and, for Sign in with ChatGPT, entries inside a `namespace` tool
    /// (`tools[i].tools[j]`, ["tools", i, "tools", j]; stage 3).
    struct CustomEntry: Equatable {
        let param: String
        let path: [JSONPathElement]
    }
    enum JSONPathElement: Equatable { case key(String), index(Int) }

    static func customEntries(_ requestBody: Data?) -> [CustomEntry] {
        guard let requestBody, requestBody.count <= ResponsesLimits.roundBytes,
              let object = (try? JSONSerialization.jsonObject(with: requestBody)) as? [String: Any],
              let tools = object["tools"] as? [[String: Any]] else { return [] }
        var out: [CustomEntry] = []
        for (i, tool) in tools.enumerated() {
            if tool["type"] as? String == "custom" {
                out.append(CustomEntry(param: "tools[\(i)]", path: [.key("tools"), .index(i)]))
            } else if tool["type"] as? String == "namespace", let inner = tool["tools"] as? [[String: Any]] {
                for (j, entry) in inner.enumerated() where entry["type"] as? String == "custom" {
                    out.append(CustomEntry(param: "tools[\(i)].tools[\(j)]", path: [.key("tools"), .index(i), .key("tools"), .index(j)]))
                }
            }
        }
        return out
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

    /// `param` names the entry's type or format (or a sub-path of the format).
    static func namesTypeOrFormat(_ param: String, _ base: String) -> Bool {
        param == base + ".type" || param == base + ".format" || param.hasPrefix(base + ".format.") || param.hasPrefix(base + ".format[")
    }

    static func classify(status: Int, rawBody: Data, requestBody: Data?, underlying: Error) -> Error? {
        guard status == 400 else { return nil }
        let entries = customEntries(requestBody)
        guard !entries.isEmpty, rawBody.count <= 64 * 1024 else { return nil }
        for error in errorObjects(rawBody) {
            guard let param = error["param"] as? String, let code = error["code"] as? String, refusalCodes.contains(code) else { continue }
            for entry in entries {
                if namesTypeOrFormat(param, entry.param) || (param == entry.param && typeCodes.contains(code)) {
                    return Rejected(status: status, detail: "\(code) at \(param)", underlying: underlying)
                }
            }
        }
        for error in errorObjects(rawBody) {
            guard error["param"] as? String == "tools", let message = error["message"] as? String else { continue }
            if let code = error["code"] as? String, refusalCodes.contains(code), message.contains("'custom'") {
                return Rejected(status: status, detail: "\(code) at tools (custom type)", underlying: underlying)
            }
            if message.hasPrefix(larkRefusalPrefix) {
                return Rejected(status: status, detail: "grammar refused at tools", underlying: underlying)
            }
        }
        for path in openRouterValidationPaths(rawBody) {
            guard let entry = entries.first(where: { $0.path == path }) else { continue }
            return Rejected(status: status, detail: "invalid_prompt at \(entry.param)", underlying: underlying)
        }
        return nil
    }

    /// Sign in with ChatGPT names an unsupported part of the request with
    /// `unsupported_capability` and its `param` (SIWCErrors). Checked BEFORE
    /// the SIWC classification, and only when that `param` is exactly a
    /// custom entry the request carried or its type/format: the route then
    /// refuses the freeform tool itself, and the one JSON fallback on the same
    /// route (no paid path) is the right answer. Any other SIWC error, and an
    /// `unsupported_capability` naming anything else, keep today's handling.
    static func classifySIWCCapability(status: Int, rawBody: Data, requestBody: Data?, underlying: Error) -> Error? {
        guard status == 400, rawBody.count <= 64 * 1024 else { return nil }
        let entries = customEntries(requestBody)
        guard !entries.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any],
              let error = object["error"] as? [String: Any], error["code"] as? String == "unsupported_capability",
              let param = error["param"] as? String else { return nil }
        guard entries.contains(where: { param == $0.param || namesTypeOrFormat(param, $0.param) }) else { return nil }
        return Rejected(status: status, detail: "unsupported_capability at \(param)", underlying: underlying)
    }

    /// §5.6 streamed refusals (stage 3): HTTP 200 whose stream ends in a
    /// `response.failed` terminal instead of an HTTP 400. `bytes` is the
    /// terminal snapshot the stream assembled (or the JSON body). Produced
    /// only when ALL hold: the request carried a `custom` entry (top level or
    /// in a namespace); the stream carried no output item and no delta of any
    /// kind (`streamedOutput == false`); the terminal has an explicit, empty
    /// `output` array; its status is `failed`; and its error message starts
    /// "Invalid lark grammar" (any code; OpenRouter automatic routing,
    /// captured 2026-11-09: code `invalid_prompt`) — positive evidence that
    /// the host refused the patch tool's grammar. A generic failure
    /// (`server_error` "Provider returned an empty response", Bedrock, same
    /// capture) never classifies.
    ///
    /// Deliberately NOT classified (Codex S3 R1 F1): the ChatGPT routes'
    /// empty `response.incomplete` (probes P1/P2 R5 with a malformed grammar).
    /// An empty incomplete answer does not say why it stopped, and a
    /// classification records a persistent per-route downgrade; it surfaces
    /// as an ordinary incomplete error. Revisit only with a captured body
    /// that names the tool or grammar.
    static func classifyTerminal(_ bytes: Data, requestBody: Data?, streamedOutput: Bool, underlying: Error) -> Error? {
        // One terminal record at most (the stream's own record bound): the
        // snapshot echoes the request's whole tool list on some hosts
        // (OpenRouter), far above an error body's 64 KiB.
        guard !streamedOutput, bytes.count <= ResponsesLimits.recordBytes, !customEntries(requestBody).isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              object["status"] as? String == "failed",
              let output = object["output"] as? [Any], output.isEmpty,
              let error = object["error"] as? [String: Any], let message = error["message"] as? String,
              message.hasPrefix(larkRefusalPrefix) else { return nil }
        return Rejected(status: 200, detail: "grammar refused in the stream", underlying: underlying)
    }

    static let larkRefusalPrefix = "Invalid lark grammar"

    /// The issue paths of OpenRouter's own request-validation refusal:
    /// `{"error":{"code":"invalid_prompt",…},"metadata":{"raw":"[issues]"}}`.
    static func openRouterValidationPaths(_ rawBody: Data) -> [[JSONPathElement]] {
        guard let object = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any],
              let error = object["error"] as? [String: Any], error["code"] as? String == "invalid_prompt",
              let metadata = object["metadata"] as? [String: Any], let raw = metadata["raw"] as? String,
              let issues = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]] else { return [] }
        return issues.compactMap { issue -> [JSONPathElement]? in
            guard let path = issue["path"] as? [Any] else { return nil }
            var out: [JSONPathElement] = []
            for element in path {
                // A JSON string is a key, an integer an index (as before).
                if let key = element as? String { out.append(.key(key)); continue }
                guard let index = element as? Int else { return nil }
                out.append(.index(index))
            }
            return out
        }
    }
}
