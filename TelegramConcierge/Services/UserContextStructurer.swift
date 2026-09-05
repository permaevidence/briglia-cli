import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Turns the free-text "Su di te" input into the structured user context via
/// the configured LLM. Shared by the Settings panel ("Elabora e salva") and
/// the onboarding flow, which runs it automatically in the background.
struct UserContextStructurer {

    struct Config {
        var provider: LLMProvider
        var openRouterApiKey: String
        var openRouterModel: String
        var openAICompatibleBaseURL: String
        var openAICompatibleModel: String
        var openAICompatibleApiKey: String
        var lmStudioBaseURL: String
        var lmStudioModel: String
        var wireProtocol: ProviderWireProtocol = .chatCompletions
        var nativeEffort: String? = nil
        var nativeConfigurationError: String? = nil

        /// Builds a config from the persisted settings — used by callers that
        /// don't hold the provider fields in local state (onboarding).
        static func fromKeychain() -> Config {
            // The lane here is not dispatched: structure() allocates its own
            // operation lane. All inherited provider fields come from one read.
            if let native = ResponsesAuxiliary.inheritedSnapshot(lane: .archive) {
                return Config(provider: .openAICompatible, openRouterApiKey: "", openRouterModel: "",
                    openAICompatibleBaseURL: native.endpoint, openAICompatibleModel: native.model,
                    openAICompatibleApiKey: native.affinityKey, lmStudioBaseURL: "", lmStudioModel: "",
                    wireProtocol: .responses, nativeEffort: native.reasoningEffort,
                    nativeConfigurationError: native.configurationError)
            }
            return Config(
                provider: LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey)),
                openRouterApiKey: KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? "",
                openRouterModel: KeychainHelper.load(key: KeychainHelper.openRouterModelKey) ?? "",
                openAICompatibleBaseURL: KeychainHelper.load(key: KeychainHelper.openAICompatibleBaseURLKey) ?? "",
                openAICompatibleModel: KeychainHelper.load(key: KeychainHelper.openAICompatibleModelKey) ?? "",
                openAICompatibleApiKey: KeychainHelper.load(key: KeychainHelper.openAICompatibleApiKeyKey) ?? "",
                lmStudioBaseURL: KeychainHelper.load(key: KeychainHelper.lmStudioBaseURLKey) ?? "",
                lmStudioModel: KeychainHelper.load(key: KeychainHelper.lmStudioModelKey) ?? "",
                wireProtocol: .chatCompletions
            )
        }
    }

    static func structure(
        assistantName: String,
        userName: String,
        rawContext: String,
        existingContext: String,
        config: Config
    ) async throws -> String {
        let provider = config.provider
        let trimmedOpenRouterAPIKey = config.openRouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        func normalizeCompletionsURL(_ raw: String, fallback: String) -> URL {
            var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = fallback }
            while base.hasSuffix("/") { base.removeLast() }
            if base.hasSuffix("/chat/completions"), let url = URL(string: base) {
                return url
            }
            if !base.hasSuffix("/v1") {
                base += "/v1"
            }
            return URL(string: base + "/chat/completions")!
        }

        func configuredURL() -> URL {
            switch provider {
            case .lmStudio:
                return normalizeCompletionsURL(config.lmStudioBaseURL, fallback: KeychainHelper.defaultLMStudioBaseURL)
            case .openAICompatible:
                return normalizeCompletionsURL(config.openAICompatibleBaseURL, fallback: "")
            case .openRouter:
                return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            }
        }

        let configuredModel: String = {
            switch provider {
            case .lmStudio:
                return config.lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines)
            case .openAICompatible:
                return config.openAICompatibleModel.trimmingCharacters(in: .whitespacesAndNewlines)
            case .openRouter:
                let configured = config.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
                return configured.isEmpty ? "google/gemini-3-flash-preview" : configured
            }
        }()

        if provider.isCustomEndpoint && configuredModel.isEmpty {
            throw NSError(
                domain: "StructureAI",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Model name is not configured for the selected provider"]
            )
        }

        if provider == .openAICompatible && config.openAICompatibleBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(
                domain: "StructureAI",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Endpoint URL is not configured for the OpenAI-compatible provider"]
            )
        }

        if provider == .openRouter && trimmedOpenRouterAPIKey.isEmpty {
            throw NSError(
                domain: "StructureAI",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "The OpenRouter API key is not configured"]
            )
        }

        // Resolve reasoning effort for the current provider:
        // - OpenRouter: default "high" when unspecified (existing behavior).
        // - OpenAI-Compatible: read its own setting; empty means omit.
        // - Local (lmStudio): never sends reasoning.
        let configuredReasoningEffort: String? = {
            switch provider {
            case .openRouter:
                let stored = (KeychainHelper.load(key: KeychainHelper.openRouterReasoningEffortKey) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stored.isEmpty ? "high" : stored
            case .openAICompatible:
                let stored = (KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stored.isEmpty ? nil : stored
            case .lmStudio:
                return nil
            }
        }()

        let prompt: String
        let maxChars = 20000
        let existingCharCount = existingContext.count
        let currentTokens = existingCharCount / 4
        let remainingTokens = (maxChars - existingCharCount) / 4

        if existingContext.isEmpty {
            // No existing context - structure from user input
            prompt = """
            You are helping configure an AI assistant. Based on the user's input, create a structured context.

            ⚠️ TOKEN LIMIT: ~5000 tokens (~20,000 characters). Currently using 0 tokens. You have ~5000 tokens available.

            Assistant Name: \(assistantName.isEmpty ? "not specified" : assistantName)
            User Name: \(userName.isEmpty ? "not specified" : userName)
            Raw User Input: \(rawContext)

            Write ONLY the structured context, no explanations. It should:
            1. Establish the assistant's identity and name (if provided)
            2. Establish who the user is and their name (if provided)
            3. Prioritize durable profile information: relationship network (family, friends, frequent colleagues, nicknames, pets, homes), stable preferences, and communication style
            4. Be written in second person ("You are...")
            5. Organize by categories if there's enough information (Personal, Work, Preferences, etc.)
            6. Exclude contingent one-off details tied to a specific moment/situation
            7. Stay within the token limit - be concise but comprehensive
            """
        } else {
            // Existing context exists - Gemini decides how to handle the update
            prompt = """
            You are helping update an AI assistant's persistent memory about the user.

            ⚠️ TOKEN LIMIT: ~5000 tokens (~20,000 characters). Currently using ~\(currentTokens) tokens. You have ~\(remainingTokens) tokens remaining.

            EXISTING CONTEXT (current memory):
            ---
            \(existingContext)
            ---

            NEW USER INPUT:
            ---
            \(rawContext.isEmpty ? "(empty - user cleared the field)" : rawContext)
            ---

            Your task: Decide how to update the context intelligently.

            IMPORTANT RULES:
            - If the new input is EMPTY or just a few words, DO NOT delete the existing context. Keep it as-is or make minimal changes.
            - If the new input contains corrections (e.g., "birthday is actually April"), UPDATE the relevant parts.
            - If the new input adds new information, APPEND it to the appropriate section.
            - If the new input is a complete rewrite with substantial content, you may restructure entirely.
            - NEVER lose important information from the existing context unless explicitly told to remove it.
            - Keep only durable profile memory: relationship network (family, friends, frequent colleagues, nicknames, pets, homes), stable preferences, and communication style.
            - Remove or avoid contingent one-off details (situational comparisons, temporary opinions, single-instance choices).
            - Stay within the 5000 token limit. If space is tight, remove less important details.

            Assistant Name: \(assistantName.isEmpty ? "not specified" : assistantName)
            User Name: \(userName.isEmpty ? "not specified" : userName)

            Output ONLY the final structured context (no explanations). Keep it organized and concise.
            """
        }

        if config.wireProtocol == .responses {
            let operationLane = AffinityLane.ephemeral(UUID())
            var context = ProviderExecutionContext.responsesAPI(baseURL: config.openAICompatibleBaseURL,
                key: config.openAICompatibleApiKey, model: configuredModel,
                lane: operationLane, effort: config.nativeEffort)
            context.configurationError = config.nativeConfigurationError
            return try await ResponsesAuxiliary.text(context: context, messages: [("user", prompt)])
        }
        let body: [String: Any] = [
            "model": configuredModel,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        var requestPayload = body
        if let configuredReasoningEffort {
            switch provider {
            case .openRouter:
                requestPayload["reasoning"] = ["effort": configuredReasoningEffort]
            case .openAICompatible:
                requestPayload["reasoning_effort"] = configuredReasoningEffort
            case .lmStudio:
                break
            }
        }

        var request = URLRequest(url: configuredURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let credential: String
        switch provider {
        case .lmStudio:
            credential = "lm-studio"
            request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 1200
        case .openAICompatible:
            let key = config.openAICompatibleApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            credential = key
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 1200
        case .openRouter:
            credential = trimmedOpenRouterAPIKey
            request.setValue("Bearer \(trimmedOpenRouterAPIKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 360
        }
        // One ephemeral lane per structuring operation (plan §3.1).
        try SessionAffinity.decorate(&request, apiKey: credential, lane: .ephemeral(UUID()))
        request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "StructureAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Richiesta API non riuscita"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "StructureAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Formato di risposta non valido"])
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
