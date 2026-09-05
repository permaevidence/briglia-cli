import Foundation

extension Probes {
    static func responses(baseURL: String, apiKey: String, model: String,
                          lane: AffinityLane = .probe(UUID())) async -> String? {
        do {
            let context = ProviderExecutionContext.responsesAPI(baseURL: baseURL, key: apiKey, model: model, lane: lane)
            _ = try await ResponsesAuxiliary.text(context: context,
                messages: [("user", "Reply OK.")], maxOutputTokens: 128)
            return nil
        } catch { return error.localizedDescription }
    }
}

extension ProviderExecutionContext {
    static func responsesAPI(baseURL: String, key: String, model: String,
                             lane: AffinityLane, effort: String? = nil) -> ProviderExecutionContext {
        ProviderExecutionContext(provider: .openAICompatible, model: model, endpoint: baseURL,
            authorization: "Bearer \(key)", affinityKey: key, lane: lane, provenance: model + "#responses",
            providerPreferences: nil, reasoning: nil, reasoningEffort: effort, thinkingType: nil,
            reasoningHistory: nil, useReasoningContent: false, textOnly: false,
            anthropicCacheControl: false, renderPDFAsImages: true, wireProtocol: .responses,
            profileIdentity: "explicit-api")
    }
}

enum ResponsesAuxiliary {
    static func text(context: ProviderExecutionContext, messages: [(String, String)],
                     maxOutputTokens: Int? = nil) async throws -> String {
        let input = messages.map { ResponsesAdapter.message(role: $0.0, text: MarkerNeutralizer.escape($0.1)) }
        let receipt = PreparedRequestReceipt(requestID: UUID(),
            historyFingerprint: ResponsesReplayEnvelope.hash(try JSONEncoder().encode(input)), deliveryNonces: [])
        let response = try await ResponsesAdapter(context: context).send(input: input, tools: nil,
            receipt: receipt, maxOutputTokens: maxOutputTokens)
        guard case .text(let text, _, _, _, _, _, _) = response else { throw ResponsesFailure.malformed("auxiliary request returned tools") }
        return text
    }
}
