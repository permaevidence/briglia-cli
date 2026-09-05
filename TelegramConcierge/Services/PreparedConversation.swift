import Foundation

/// Ephemeral harness input, never a second transcript or a wire/persisted object.
/// Message.kind, tool-result ownership, attachments and typed annotations remain
/// intact here. Only the selected adapter renders them into protocol roles.
/// In P1 media stays lazy to preserve the legacy read/OCR order and failure paths.
struct PreparedConversation {
    let systemPrompt: String
    let messages: [Message]
    let imagesDirectory: URL
    let documentsDirectory: URL
    let tools: [ToolDefinition]?
    let toolResultMessages: [ToolInteraction]?
    let tailSystemMessage: String?
    let tailUserMessage: String?
}

/// Immutable configuration for one existing generateResponse invocation and all
/// its HTTP retries. This is not yet a whole multi-round operation lease: P2
/// must carry a resolved context through request owners before enabling Responses.
/// Credentials are private in-memory data, never Codable or included in logging.
struct ProviderExecutionContext {
    let provider: LLMProvider
    let model: String
    let endpoint: String
    let authorization: String
    let affinityKey: String
    let lane: AffinityLane
    let provenance: String
    let providerPreferences: ProviderPreferences?
    let reasoning: ReasoningConfig?
    let reasoningEffort: String?
    let thinkingType: String?
    let reasoningHistory: String?
    let useReasoningContent: Bool
    let textOnly: Bool
    let anthropicCacheControl: Bool
    let renderPDFAsImages: Bool
    var wireProtocol: ProviderWireProtocol = .chatCompletions
    var profileIdentity: String = "legacy"
    var nativeToolMedia: Bool = true
    var configurationError: String? = nil

    var responsesScope: ResponsesScope {
        ResponsesScope(endpoint: (try? ResponsesAdapter.endpoint(endpoint)) ?? endpoint, profile: profileIdentity, model: model,
            credentialFingerprint: ResponsesReplayEnvelope.hash(Data(("briglia-responses-key-v1:" + affinityKey).utf8)))
    }

    var usingCustomEndpoint: Bool { provider.isCustomEndpoint }
    var providerLabel: String { usingCustomEndpoint ? provider.displayName : "OpenRouter" }
}
