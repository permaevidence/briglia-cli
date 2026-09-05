import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ResponsesAdapter {
    let context: ProviderExecutionContext

    /// Documented model capabilities, separate from Codex subscription settings.
    /// Unknown models retain the common API enum; max is opt-in for documented models.
    static func allowedEfforts(model: String) -> [String] {
        if model == "gpt-6-astra" || model.hasPrefix("gpt-6-astra-20") {
            return ["low", "medium", "high", "xhigh", "max"]
        }
        if ["gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"].contains(where: {
            model == $0 || model.hasPrefix($0 + "-20")
        }) {
            return ["none", "low", "medium", "high", "xhigh", "max"]
        }
        return ["none", "minimal", "low", "medium", "high", "xhigh"]
    }

    static func probeEffort(model: String) -> String? {
        // Pro models have narrower ranges; non-reasoning models omit the field.
        if model == "gpt-5-pro" || model.hasPrefix("gpt-5-pro-20") { return "high" }
        if ["gpt-5.4-pro", "gpt-5.5-pro"].contains(where: { model == $0 || model.hasPrefix($0 + "-20") }) { return "medium" }
        if model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6") || model.hasPrefix("o3") || model.hasPrefix("o4") { return "low" }
        return nil
    }

    /// Independent normalizer; the legacy Chat Completions normalizer is frozen.
    static func endpoint(_ base: String) throws -> String {
        guard var url = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              (scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ResponsesFailure.malformed("Responses requires an HTTPS base URL (HTTP only for loopback), without credentials/query/fragment")
        }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        if !url.path.hasSuffix("/responses") { url.path += "/responses" }
        guard let result = url.url?.absoluteString else { throw ResponsesFailure.malformed("Responses URL") }
        return result
    }

    func request(input: [JSONValue], tools: [ToolDefinition]?, stream: Bool = true,
                 maxOutputTokens: Int? = nil) throws -> URLRequest {
        if let error = context.configurationError { throw ResponsesFailure.malformed(error) }
        var body: [String: JSONValue] = [
            "model": .string(context.model), "input": .array(input), "store": .bool(false),
            "stream": .bool(stream), "truncation": .string("disabled"),
            "include": .array([.string("reasoning.encrypted_content")])
        ]
        if let effort = context.reasoningEffort ?? context.reasoning?.effort {
            guard Self.allowedEfforts(model: context.model).contains(effort) else {
                throw ResponsesFailure.unsupported("reasoning effort \(effort) for \(context.model); use /effort off or a supported value")
            }
            body["reasoning"] = .object(["effort": .string(effort)])
        }
        if let maxOutputTokens { body["max_output_tokens"] = .int(maxOutputTokens) }
        if let tools {
            guard Set(tools.map { $0.function.name }).count == tools.count else {
                throw ResponsesFailure.malformed("duplicate exposed tool name")
            }
            body["tools"] = .array(try tools.map { tool in
                let parameters = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tool.function.parameters))
                return .object(["type": .string("function"), "name": .string(tool.function.name),
                    "description": .string(MarkerNeutralizer.escape(tool.function.description)),
                    "parameters": Self.filterSchema(parameters), "strict": .bool(false)])
            })
        }
        let normalized = try Self.endpoint(context.endpoint)
        var request = URLRequest(url: URL(string: normalized)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue(context.authorization, forHTTPHeaderField: "Authorization")
        try SessionAffinity.decorate(&request, apiKey: context.affinityKey, lane: context.lane)
        request.timeoutInterval = context.usingCustomEndpoint ? 1200 : 360
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(JSONValue.object(body))
        guard request.httpBody!.count <= ResponsesLimits.roundBytes else { throw ResponsesFailure.overflow }
        return request
    }

    private static func filterSchema(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return .string(MarkerNeutralizer.escape(s))
        case .object(let o): return .object(o.mapValues(filterSchema))
        case .array(let a): return .array(a.map(filterSchema))
        default: return value
        }
    }

    func send(input: [JSONValue], tools: [ToolDefinition]?, receipt: PreparedRequestReceipt,
              maxOutputTokens: Int? = nil) async throws -> LLMResponse {
        let request = try request(input: input, tools: tools, maxOutputTokens: maxOutputTokens)
        let allowed = Set((tools ?? []).map { $0.function.name })
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                let bytes = try await ResponsesHTTPTransport().send(request, overallTimeout: request.timeoutInterval)
                try Task.checkCancellation()
                let round = try ResponsesRoundDecoder.decode(bytes, scope: context.responsesScope, receipt: receipt, allowedTools: allowed)
                DebugTelemetry.log(.info, summary: "Responses usage",
                    detail: "input=\(round.inputTokens.map(String.init) ?? "unknown") output=\(round.outputTokens.map(String.init) ?? "unknown") cached_input=\(round.metadata.cachedInputTokens.map(String.init) ?? "unknown") reasoning_output_subset=\(round.metadata.reasoningTokens.map(String.init) ?? "unknown")")
                if !round.calls.isEmpty {
                    var assistant = AssistantToolCallMessage(content: round.text, toolCalls: round.calls,
                        producedByModel: context.provenance)
                    assistant.responsesReplay = round.metadata.envelope
                    assistant.responsesReceipt = receipt
                    return .toolCalls(assistantMessage: assistant, calls: round.calls,
                        promptTokens: round.inputTokens, completionTokens: round.outputTokens, spendUSD: nil)
                }
                return .text(round.text ?? "", reasoning: nil, reasoningDetails: nil,
                    promptTokens: round.inputTokens, completionTokens: round.outputTokens,
                    spendUSD: nil, responses: round.metadata)
            } catch {
                try Task.checkCancellation()
                var delay = Double(1 << attempt)
                let retry: Bool
                if case ResponsesFailure.http(let code, let after) = error {
                    retry = [408, 409, 429, 500, 502, 503, 504].contains(code)
                    if let after { delay = after }
                } else if let e = error as? URLError {
                    retry = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(e.code)
                } else { retry = false }
                guard retry, attempt < 3 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(min(30, max(0, delay)) * 1_000_000_000))
            }
        }
        throw ResponsesFailure.disconnected
    }

    static func message(role: String, text: String) -> JSONValue {
        .object(["role": .string(role), "content": .array([
            .object(["type": .string(role == "assistant" ? "output_text" : "input_text"), "text": .string(text)])])])
    }

    /// Returns nil for invalid/foreign optional metadata. Canonical history then
    /// supplies semantic replay; no raw persisted object is forwarded.
    static func nativeItems(envelope: ResponsesReplayEnvelope?, scope: ResponsesScope,
                            text: String?, calls: [ToolCall]) -> [JSONValue]? {
        guard let envelope, envelope.matches(scope: scope, text: text, calls: calls) else { return nil }
        let bytes = Array((text ?? "").utf8)
        var offset = 0, seenCalls = Set<Int>(), seenIDs = Set<String>(), output: [JSONValue] = []
        for entry in envelope.entries {
            if let id = entry.id {
                guard !id.isEmpty, id.utf8.count < 512, seenIDs.insert(id).inserted else { return nil }
            }
            var item: [String: JSONValue] = ["type": .string(entry.type)]
            if let id = entry.id { item["id"] = .string(id) }
            switch entry.type {
            case "reasoning":
                guard let encrypted = entry.encryptedContent, !encrypted.isEmpty, entry.id != nil else { return nil }
                item["encrypted_content"] = .string(encrypted)
                item["summary"] = .array((entry.summary ?? []).map {
                    .object(["type": .string("summary_text"), "text": .string(MarkerNeutralizer.escape($0))])
                })
            case "function_call":
                guard let index = entry.callIndex, index >= 0, index < calls.count,
                      seenCalls.insert(index).inserted else { return nil }
                let call = calls[index]
                item["call_id"] = .string(call.id)
                item["name"] = .string(call.function.name)
                item["arguments"] = .string(MarkerNeutralizer.escape(call.function.arguments))
                item["status"] = .string("completed")
            case "message":
                guard let lengths = entry.textParts, let refusals = entry.refusalParts,
                      lengths.count == refusals.count else { return nil }
                var content: [JSONValue] = []
                for (length, refusal) in zip(lengths, refusals) {
                    guard length >= 0, length <= bytes.count - offset,
                          let part = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) else { return nil }
                    offset += length
                    var value: [String: JSONValue] = ["type": .string(refusal ? "refusal" : "output_text"),
                        refusal ? "refusal" : "text": .string(MarkerNeutralizer.escape(part))]
                    if !refusal { value["annotations"] = .array([]) }
                    content.append(.object(value))
                }
                item["role"] = .string("assistant"); item["status"] = .string("completed")
                item["content"] = .array(content)
            default: return nil
            }
            output.append(.object(item))
        }
        guard offset == bytes.count, seenCalls.count == calls.count else { return nil }
        return output
    }
}
