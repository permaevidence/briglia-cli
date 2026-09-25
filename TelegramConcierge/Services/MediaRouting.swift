import Foundation

/// Which backend serves voice transcription, image generation and OCR.
///
/// Owner decision 2026-09-25: on the OpenRouter lane Briglia needs only the
/// OpenRouter key. The rule, decided at call time from ONE settings snapshot
/// so a /provider switch is followed immediately:
///
/// 1. An OpenAI API key is configured → exactly today's behavior (OpenAI,
///    byte-identical requests, GPT Image 2.5 schema, OpenAI OCR).
/// 2. Otherwise, the main provider is OpenRouter with a key → OpenRouter
///    (`openai/gpt-transcribe`, Gemini image models, `openai/gpt-6-luna` OCR).
/// 3. Otherwise → today's behavior (and today's "no key" errors).
///
/// The ChatGPT subscription lane is untouched: its main provider is not
/// OpenRouter, so rule 2 never applies there.
enum MediaRouting {

    enum TranscriptionRoute: Equatable {
        case openAI(key: String)
        case openRouter(key: String)

        var key: String {
            switch self {
            case .openAI(let key), .openRouter(let key): return key
            }
        }
        var viaOpenRouter: Bool { if case .openRouter = self { return true }; return false }
    }

    /// The image backend the tool schema and the executor both use.
    enum ImageBackend: String, Equatable {
        case gemini, openAI, openRouter
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Main provider = OpenRouter with a key (the same pure rule the web
    /// page-reading follow uses).
    static func followsOpenRouter(stored: [String: String]) -> Bool {
        WebSearchBackend.followsOpenRouter(stored: stored)
    }

    static func openRouterKey(stored: [String: String]) -> String {
        trimmed(stored[KeychainHelper.openRouterApiKeyKey])
    }

    // MARK: Transcription

    static func transcription(stored: [String: String]) -> TranscriptionRoute {
        let openAI = trimmed(stored[KeychainHelper.openAITranscriptionApiKeyKey])
        if !openAI.isEmpty { return .openAI(key: openAI) }
        if followsOpenRouter(stored: stored) { return .openRouter(key: openRouterKey(stored: stored)) }
        return .openAI(key: "")
    }

    static var transcription: TranscriptionRoute { transcription(stored: KeychainHelper.loadSnapshot()) }

    // MARK: Images

    /// Rule 1 is read strictly: any configured OpenAI image key keeps the
    /// stored provider exactly as today. A configured Gemini (Google) key
    /// with the Gemini provider also stays as today. Only when neither
    /// applies does the OpenRouter lane take over.
    static func imageBackend(stored: [String: String]) -> ImageBackend {
        let provider = ImageGenerationProvider.fromStoredValue(stored[KeychainHelper.imageGenerationProviderKey])
        let legacy: ImageBackend = provider == .openAI ? .openAI : .gemini
        if !trimmed(stored[KeychainHelper.openAIImageApiKeyKey]).isEmpty { return legacy }
        if provider == .gemini, !trimmed(stored[KeychainHelper.geminiApiKeyKey]).isEmpty { return .gemini }
        if followsOpenRouter(stored: stored) { return .openRouter }
        return legacy
    }

    static var imageBackend: ImageBackend { imageBackend(stored: KeychainHelper.loadSnapshot()) }

    // MARK: OCR

    /// Whether the vision preprocessor must use OpenRouter even though the
    /// stored backend says "openai": that key was removed (or never set) and
    /// the OpenRouter lane is active. Without this, a removed OpenAI key left
    /// the stored "openai" choice pointing at nothing.
    static func ocrFollowsOpenRouter(stored: [String: String], openAIKey: String) -> Bool {
        openAIKey.isEmpty && followsOpenRouter(stored: stored)
    }

    // MARK: Status wording

    /// "openai" / "openrouter" / nil (nothing configured) — for /status,
    /// doctor, setup-api and the menu dashboard.
    static func voiceAndImagesVia(stored: [String: String]) -> String? {
        switch transcription(stored: stored) {
        case .openAI(let key): return key.isEmpty ? nil : "openai"
        case .openRouter: return "openrouter"
        }
    }
}
