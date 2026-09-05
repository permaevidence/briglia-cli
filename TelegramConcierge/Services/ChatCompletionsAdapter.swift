import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Chat Completions wire encoding/decoding. No profile lookup, persistence or
/// harness decisions happen here; the owner supplies one immutable context.
struct ChatCompletionsAdapter {
    let context: ProviderExecutionContext

    func makeRequest(messages apiMessages: [OpenRouterAPIMessage], tools: [ToolDefinition]?) throws -> URLRequest {
        let effectiveModel = context.model
        let currentProvider = context.provider
        let effectiveProvenance = context.provenance
        let requestMessages = OpenRouterService.assembleRequestMessages(
            apiMessages,
            provider: currentProvider,
            useReasoningContent: context.useReasoningContent,
            effectiveProvenance: effectiveProvenance
        )

        let body = OpenRouterRequest(
            model: effectiveModel,
            messages: requestMessages,
            tools: tools,
            provider: context.providerPreferences,
            reasoning: context.reasoning,
            reasoningEffort: context.reasoningEffort,
            thinking: context.thinkingType.map { ThinkingConfig(type: $0) },
            reasoningHistory: context.reasoningHistory
        )

        let url = URL(string: context.endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(context.authorization, forHTTPHeaderField: "Authorization")
        try SessionAffinity.decorate(&request, apiKey: context.affinityKey, lane: context.lane)
        // Local inference and large reasoning models can legitimately take a long time.
        request.timeoutInterval = context.usingCustomEndpoint ? 1200 : 360

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(body)

        return request
    }

    func decodeResponse(_ data: Data) throws -> LLMResponse {
        let effectiveModel = context.model
        let currentProvider = context.provider
        let effectiveProvenance = context.provenance
        let decoded: OpenRouterResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
        } catch {
            // Log the raw response for debugging
            let rawResponse = String(data: data, encoding: .utf8) ?? "Unable to decode response as string"
            print("[OpenRouterService] JSON decode failed. Raw response: \(rawResponse.prefix(1000))")
            print("[OpenRouterService] Decode error: \(error)")
            // Surface a useful message up the call stack. Swift's default
            // DecodingError description is "The data couldn't be read because
            // it is missing." — generic and actionable to nobody. Include
            // the specific key path + a snippet of the raw body so the
            // Telegram error reply tells us exactly what's malformed.
            let decodeDetail: String
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let ctx):
                    decodeDetail = "missing key '\(key.stringValue)' at path [\(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))]"
                case .valueNotFound(let type, let ctx):
                    decodeDetail = "nil value for \(type) at path [\(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))]"
                case .typeMismatch(let type, let ctx):
                    decodeDetail = "type mismatch: expected \(type) at path [\(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))]"
                case .dataCorrupted(let ctx):
                    decodeDetail = "data corrupted at path [\(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))]: \(ctx.debugDescription)"
                @unknown default:
                    decodeDetail = String(describing: decodingError)
                }
            } else {
                decodeDetail = error.localizedDescription
            }
            let bodySnippet = String(rawResponse.prefix(500))
            throw OpenRouterError.apiError("Response decode failed — \(decodeDetail). Body: \(bodySnippet)")
        }

        guard let choice = decoded.choices.first else {
            throw OpenRouterError.noContent
        }

        // Extract usage info for token tracking
        let promptTokens = decoded.usage?.promptTokens
        let completionTokens = decoded.usage?.completionTokens
        let cachedTokens = decoded.usage?.promptTokensDetails?.cachedTokens ?? 0
        let directCost = decoded.usage?.cost?.value
        let upstreamInferenceCost = decoded.usage?.costDetails?.upstreamInferenceCost?.value
        let callSpendUSD = [directCost, upstreamInferenceCost]
            .compactMap { $0 }
            .filter { $0.isFinite && $0 >= 0 }
            .max()

        if let pt = promptTokens, let ct = completionTokens {
            print("[OpenRouterService] Usage: \(pt - cachedTokens) uncached prompt + \(cachedTokens) cached prompt, \(ct) completion tokens")
        }
        if let spend = callSpendUSD {
            print("[OpenRouterService] Usage spend: $\(Self.formatUSD(spend)) (direct=\(directCost.map { Self.formatUSD($0) } ?? "n/a"), upstream=\(upstreamInferenceCost.map { Self.formatUSD($0) } ?? "n/a"))")
        } else {
            print("[OpenRouterService] Usage spend: unavailable")
        }

        let shouldNormalizeMiniMaxInlineThinking = currentProvider == .openAICompatible
            && OpenRouterService.isOpenCodeMiniMaxModel(effectiveModel)
        let responseContentAndReasoning: (content: String?, reasoning: JSONValue?) = shouldNormalizeMiniMaxInlineThinking
            ? OpenRouterService.splitInlineThinking(from: choice.message.content)
            : (content: choice.message.content, reasoning: nil)
        let responseContent = responseContentAndReasoning.content
        let responseReasoning = choice.message.reasoning
            ?? choice.message.reasoningContent
            ?? responseContentAndReasoning.reasoning

        // Check if the model wants to call tools
        if let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {
            return .toolCalls(
                assistantMessage: AssistantToolCallMessage(
                    content: responseContent,
                    toolCalls: toolCalls,
                    reasoning: responseReasoning,
                    reasoningDetails: choice.message.reasoningDetails,
                    producedByModel: effectiveProvenance
                ),
                calls: toolCalls,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                spendUSD: callSpendUSD
            )
        }

        // Regular text response
        guard let content = responseContent else {
            throw OpenRouterError.noContent
        }

        return .text(
            content,
            reasoning: responseReasoning,
            reasoningDetails: choice.message.reasoningDetails,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            spendUSD: callSpendUSD
        )
    }

    static func formatUSD(_ value: Double) -> String {
        var formatted = String(format: "%.6f", value)
        while formatted.contains(".") && formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return formatted
    }

}
