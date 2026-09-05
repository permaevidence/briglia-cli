import Foundation

/// Multi-provider profiles for the main agent (2026-08-16).
///
/// Before this, OpenCode Go and a custom endpoint squatted on the SAME
/// storage slots (`openai_compatible_*`), so configuring one overwrote the
/// other; OpenRouter's native slots existed (Ada.app heritage) but nothing in
/// the CLI could set them. Now each of the four providers keeps its own
/// remembered configuration — key, endpoint, model, reasoning effort, and
/// vision/text-only state — and hopping between them (`/provider`) is a pure
/// storage operation.
///
/// Design: the existing runtime slots (`llm_provider`, `openai_compatible_*`,
/// `openrouter_*`, `lmstudio_*`, `text_only_model_enabled`) stay authoritative
/// for OpenRouterService and everything downstream — nothing in the request
/// path changed. Profiles are the durable per-provider memory BEHIND those
/// slots; `activate()` copies a profile into the runtime slots, and the
/// `/model` + `/effort` commands mirror their writes back into the active
/// profile so a hop away and back restores what the user last used.
/// OpenRouter and local profiles ARE their native runtime slots (no copy);
/// only OpenCode and custom need dedicated namespaces because they share the
/// `openai_compatible_*` runtime slots.
enum ProviderProfiles {

    enum Profile: String, CaseIterable {
        case opencode
        case openrouter
        case custom
        case local
        case openai

        var displayName: String {
            switch self {
            case .opencode: return "OpenCode Go"
            case .openrouter: return "OpenRouter"
            case .custom: return "Custom endpoint"
            case .local: return "Local server"
            case .openai: return "OpenAI API (Responses)"
            }
        }
    }

    // MARK: Storage keys

    /// Which profile the runtime slots currently mirror. Absent on
    /// pre-profile installs until `ensureMigrated()` runs, and on fresh
    /// installs until the wizard configures a provider.
    static let activeProfileKey = "active_provider_profile"

    // OpenCode profile namespace (base URL is fixed: OpenCodeGo.baseURL).
    static let opencodeApiKeyKey = "opencode_api_key"
    static let opencodeModelKey = "opencode_model"
    static let opencodeReasoningEffortKey = "opencode_reasoning_effort"
    static let opencodeTextOnlyKey = "opencode_text_only"

    // Custom-endpoint profile namespace.
    static let customBaseURLKey = "custom_endpoint_base_url"
    static let customApiKeyKey = "custom_endpoint_api_key"
    static let customModelKey = "custom_endpoint_model"
    static let customReasoningEffortKey = "custom_endpoint_reasoning_effort"
    static let customTextOnlyKey = "custom_endpoint_text_only"

    static let openaiApiKeyKey = "openai_platform_api_key"
    static let openaiModelKey = "openai_platform_model"
    static let openaiEffortKey = "openai_platform_effort"
    static let openaiTextOnlyKey = "openai_platform_text_only"
    static let customProtocolKey = "custom_endpoint_protocol"
    static let runtimeProtocolKey = "active_provider_protocol"
    static let customNativeMediaKey = "custom_responses_native_tool_media"
    static let runtimeNativeMediaKey = "responses_native_tool_media"

    static func wireProtocol(_ profile: Profile) -> ProviderWireProtocol {
        if profile == .openai { return .responses }
        if profile == .custom { return value(customProtocolKey).flatMap(ProviderWireProtocol.init(rawValue:)) ?? .chatCompletions }
        return .chatCompletions
    }

    static var usesResponses: Bool {
        KeychainHelper.load(key: KeychainHelper.llmProviderKey) == LLMProvider.openAICompatible.rawValue
            && value(runtimeProtocolKey).map { $0 != ProviderWireProtocol.chatCompletions.rawValue } == true
    }

    // OpenRouter + local profiles ride their existing native slots
    // (openrouter_api_key/model/reasoning_effort, lmstudio_base_url/model);
    // only the vision/text-only memory is new.
    static let openrouterTextOnlyKey = "openrouter_text_only"
    static let localTextOnlyKey = "lmstudio_text_only"

    // MARK: Reads

    private static func value(_ key: String) -> String? {
        let trimmed = KeychainHelper.load(key: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    static func activeProfile() -> Profile? {
        value(activeProfileKey).flatMap(Profile.init(rawValue:))
    }

    /// Whether a profile has enough saved state to be hopped to.
    /// OpenRouter needs only a key: the runtime falls back to its default
    /// model, and Ada.app-heritage installs may have a key without a model.
    static func isConfigured(_ profile: Profile) -> Bool {
        switch profile {
        case .openai: return value(openaiApiKeyKey) != nil && value(openaiModelKey) != nil
        case .opencode:
            return value(opencodeApiKeyKey) != nil && value(opencodeModelKey) != nil
        case .openrouter:
            return value(KeychainHelper.openRouterApiKeyKey) != nil
        case .custom:
            return value(customBaseURLKey) != nil && value(customApiKeyKey) != nil
                && value(customModelKey) != nil
        case .local:
            return value(KeychainHelper.lmStudioBaseURLKey) != nil
                && value(KeychainHelper.lmStudioModelKey) != nil
        }
    }

    /// The model a profile would run — nil when not configured (except
    /// OpenRouter, which reports its runtime default).
    static func configuredModel(_ profile: Profile) -> String? {
        switch profile {
        case .openai: return value(openaiModelKey)
        case .opencode: return value(opencodeModelKey)
        case .openrouter:
            guard isConfigured(.openrouter) else { return nil }
            return value(KeychainHelper.openRouterModelKey) ?? "google/gemini-3-flash-preview"
        case .custom: return value(customModelKey)
        case .local: return value(KeychainHelper.lmStudioModelKey)
        }
    }

    static func configuredEndpoint(_ profile: Profile) -> String? {
        switch profile {
        case .openai: return isConfigured(.openai) ? "https://api.openai.com/v1" : nil
        case .opencode: return isConfigured(.opencode) ? OpenCodeGo.baseURL : nil
        case .openrouter: return isConfigured(.openrouter) ? "https://openrouter.ai/api/v1" : nil
        case .custom: return value(customBaseURLKey)
        case .local: return value(KeychainHelper.lmStudioBaseURLKey)
        }
    }

    /// Masked API key for listings — never the full value.
    static func maskedKey(_ profile: Profile) -> String? {
        let raw: String?
        switch profile {
        case .openai: raw = value(openaiApiKeyKey)
        case .opencode: raw = value(opencodeApiKeyKey)
        case .openrouter: raw = value(KeychainHelper.openRouterApiKeyKey)
        case .custom: raw = value(customApiKeyKey)
        case .local: return nil  // keyless by definition
        }
        guard let raw else { return nil }
        guard raw.count > 10 else { return "•••" }
        return "\(raw.prefix(5))…\(raw.suffix(4))"
    }

    static func configuredEffort(_ profile: Profile) -> String? {
        switch profile {
        case .openai: return value(openaiEffortKey)
        case .opencode: return value(opencodeReasoningEffortKey)
        case .openrouter: return value(KeychainHelper.openRouterReasoningEffortKey)
        case .custom: return value(customReasoningEffortKey)
        case .local: return nil  // local provider takes no effort setting
        }
    }

    /// Profile-remembered vision state: true = text-only, false = vision,
    /// nil = unknown (legacy OpenRouter key never configured via the wizard).
    static func textOnly(_ profile: Profile) -> Bool? {
        let key: String
        switch profile {
        case .openai: key = openaiTextOnlyKey
        case .opencode: key = opencodeTextOnlyKey
        case .openrouter: key = openrouterTextOnlyKey
        case .custom: key = customTextOnlyKey
        case .local: key = localTextOnlyKey
        }
        guard let stored = value(key) else { return nil }
        return stored == "true"
    }

    // MARK: Writes

    private static func setOptional(_ key: String, _ newValue: String?) throws {
        if let newValue, !newValue.isEmpty {
            try KeychainHelper.save(key: key, value: newValue)
        } else {
            try KeychainHelper.delete(key: key)
        }
    }

    /// Save a full profile configuration (wizard path). Does NOT activate.
    /// One atomic batch write — a failure saves nothing.
    static func saveProfile(
        _ profile: Profile,
        apiKey: String?,
        baseURL: String?,
        model: String,
        effort: String?,
        textOnly: Bool,
        wireProtocol: ProviderWireProtocol? = nil,
        nativeToolMedia: Bool? = nil
    ) throws {
        // nil-valued EXPRESSIONS on the right store String?.none (= delete in
        // saveBatch); never assign a literal nil here — that removes the key
        // from the batch instead of recording a deletion.
        var changes: [String: String?] = [:]
        switch profile {
        case .openai:
            changes[openaiApiKeyKey] = apiKey
            changes[openaiModelKey] = model
            changes[openaiEffortKey] = effort
            changes[openaiTextOnlyKey] = textOnly ? "true" : "false"
        case .opencode:
            changes[opencodeApiKeyKey] = apiKey
            changes[opencodeModelKey] = model
            changes[opencodeReasoningEffortKey] = effort
            changes[opencodeTextOnlyKey] = textOnly ? "true" : "false"
        case .openrouter:
            changes[KeychainHelper.openRouterApiKeyKey] = apiKey
            changes[KeychainHelper.openRouterModelKey] = model
            changes[KeychainHelper.openRouterReasoningEffortKey] = effort
            changes[openrouterTextOnlyKey] = textOnly ? "true" : "false"
        case .custom:
            if let nativeToolMedia { changes[customNativeMediaKey] = nativeToolMedia ? "true" : "false" }
            if let wireProtocol {
                changes[customProtocolKey] = wireProtocol == .responses ? wireProtocol.rawValue : String?.none
            }
            changes[customApiKeyKey] = apiKey
            changes[customBaseURLKey] = baseURL
            changes[customModelKey] = model
            changes[customReasoningEffortKey] = effort
            changes[customTextOnlyKey] = textOnly ? "true" : "false"
        case .local:
            changes[KeychainHelper.lmStudioBaseURLKey] = baseURL
            changes[KeychainHelper.lmStudioModelKey] = model
            changes[localTextOnlyKey] = textOnly ? "true" : "false"
        }
        try KeychainHelper.saveBatch(changes)
    }

    /// Copy a profile into the runtime slots and mark it active. Pure
    /// storage — in-process service reconfiguration (OpenRouterService key,
    /// change notification) is the caller's job. The runtime slots, vision
    /// flag, and active-profile marker commit as ONE atomic batch write, so
    /// a storage failure activates nothing — never a half-switch.
    static func activate(_ profile: Profile) throws {
        if profile == .custom, let raw = value(customProtocolKey), ProviderWireProtocol(rawValue: raw) == nil {
            throw ResponsesFailure.malformed("unsupported explicit custom protocol")
        }
        guard isConfigured(profile) else {
            throw ActivationError.notConfigured(profile)
        }
        // Same literal-nil caveat as saveProfile: nil-valued expressions mean
        // "delete this key" in the batch.
        var changes: [String: String?] = [:]
        switch profile {
        case .openai:
            changes[KeychainHelper.openAICompatibleBaseURLKey] = "https://api.openai.com/v1"
            changes[KeychainHelper.openAICompatibleModelKey] = value(openaiModelKey)!
            changes[KeychainHelper.openAICompatibleApiKeyKey] = value(openaiApiKeyKey)!
            changes[KeychainHelper.openAICompatibleReasoningEffortKey] = value(openaiEffortKey)
            changes[KeychainHelper.llmProviderKey] = LLMProvider.openAICompatible.rawValue
        case .opencode:
            changes[KeychainHelper.openAICompatibleBaseURLKey] = OpenCodeGo.baseURL
            changes[KeychainHelper.openAICompatibleModelKey] = value(opencodeModelKey)!
            changes[KeychainHelper.openAICompatibleApiKeyKey] = value(opencodeApiKeyKey)!
            changes[KeychainHelper.openAICompatibleReasoningEffortKey] = value(opencodeReasoningEffortKey)
            changes[KeychainHelper.llmProviderKey] = LLMProvider.openAICompatible.rawValue
        case .custom:
            changes[KeychainHelper.openAICompatibleBaseURLKey] = value(customBaseURLKey)!
            changes[KeychainHelper.openAICompatibleModelKey] = value(customModelKey)!
            changes[KeychainHelper.openAICompatibleApiKeyKey] = value(customApiKeyKey)!
            changes[KeychainHelper.openAICompatibleReasoningEffortKey] = value(customReasoningEffortKey)
            changes[KeychainHelper.llmProviderKey] = LLMProvider.openAICompatible.rawValue
        case .openrouter:
            // Native slots are already the profile storage.
            changes[KeychainHelper.llmProviderKey] = LLMProvider.openRouter.rawValue
        case .local:
            changes[KeychainHelper.llmProviderKey] = LLMProvider.lmStudio.rawValue
        }
        // Restore the profile's vision/text-only state. nil (legacy
        // OpenRouter key never touched by the wizard) leaves the global flag
        // as it was — better unchanged than a wrong deterministic guess.
        if let profileTextOnly = textOnly(profile) {
            changes[KeychainHelper.textOnlyModelEnabledKey] = profileTextOnly ? "true" : "false"
        }
        changes[runtimeProtocolKey] = wireProtocol(profile) == .responses ? "responses" : String?.none
        changes[runtimeNativeMediaKey] = profile == .custom && wireProtocol(profile) == .responses ? value(customNativeMediaKey) : String?.none
        changes[activeProfileKey] = profile.rawValue
        try KeychainHelper.saveBatch(changes)
    }

    enum ActivationError: Error, LocalizedError {
        case notConfigured(Profile)
        /// Explicit message: corelibs Foundation on Linux does not reliably
        /// route errorDescription through localizedDescription, so callers
        /// use this instead of error.localizedDescription.
        var message: String {
            switch self {
            case .notConfigured(let profile):
                return "\(profile.displayName) is not configured yet — run `briglia setup` (step 1) to add it."
            }
        }
        var errorDescription: String? { message }
    }

    /// User-facing text for any error thrown by activate().
    static func describeActivationError(_ error: Error) -> String {
        (error as? ActivationError)?.message ?? error.localizedDescription
    }

    // MARK: /model + /effort mirrors

    /// Mirror a `/model` switch into the active profile so hopping away and
    /// back restores it. The runtime-slot write stays in the command handler
    /// (it already existed); this records the durable per-profile memory.
    /// `textOnly` is passed only when the switch determined it (OpenCode
    /// catalog match); nil leaves the remembered state untouched.
    static func recordModelChange(_ model: String, textOnly: Bool?) {
        guard let profile = activeProfile() else { return }
        let modelKey: String
        let textOnlyKey: String
        switch profile {
        case .openai: modelKey = openaiModelKey; textOnlyKey = openaiTextOnlyKey
        case .opencode: modelKey = opencodeModelKey; textOnlyKey = opencodeTextOnlyKey
        case .openrouter: modelKey = KeychainHelper.openRouterModelKey; textOnlyKey = openrouterTextOnlyKey
        case .custom: modelKey = customModelKey; textOnlyKey = customTextOnlyKey
        case .local: modelKey = KeychainHelper.lmStudioModelKey; textOnlyKey = localTextOnlyKey
        }
        try? KeychainHelper.save(key: modelKey, value: model)
        if let textOnly {
            try? KeychainHelper.save(key: textOnlyKey, value: textOnly ? "true" : "false")
        }
    }

    /// Mirror an `/effort` change into the active profile (nil = cleared).
    static func recordEffortChange(_ effort: String?) {
        guard let profile = activeProfile() else { return }
        let key: String
        switch profile {
        case .openai: key = openaiEffortKey
        case .opencode: key = opencodeReasoningEffortKey
        case .openrouter: key = KeychainHelper.openRouterReasoningEffortKey
        case .custom: key = customReasoningEffortKey
        case .local: return
        }
        try? setOptional(key, effort)
    }

    // MARK: Migration

    /// One-time, idempotent: derive the active profile from a pre-profile
    /// install's runtime slots and seed that profile's namespace. Runs at
    /// startup, wizard entry, and defensively in the /provider handler.
    /// A fresh install (no stored llm_provider) is left unmigrated — the
    /// wizard creates its first profile explicitly.
    static func ensureMigrated() {
        guard activeProfile() == nil else { return }
        // fromStoredValue silently defaults to .lmStudio — read raw so an
        // absent key (fresh install) is distinguishable from a real choice.
        guard let rawProvider = value(KeychainHelper.llmProviderKey),
              let provider = LLMProvider(rawValue: rawProvider) else { return }
        let globalTextOnly = KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "true"

        do {
            switch provider {
            case .openAICompatible:
                guard let baseURL = value(KeychainHelper.openAICompatibleBaseURLKey),
                      let model = value(KeychainHelper.openAICompatibleModelKey),
                      let apiKey = value(KeychainHelper.openAICompatibleApiKeyKey) else { return }
                let effort = value(KeychainHelper.openAICompatibleReasoningEffortKey)
                if SessionAffinity.isOpenCodeBaseURL(baseURL) {
                    try saveProfile(.opencode, apiKey: apiKey, baseURL: nil, model: model,
                                    effort: effort, textOnly: globalTextOnly)
                    try KeychainHelper.save(key: activeProfileKey, value: Profile.opencode.rawValue)
                } else {
                    try saveProfile(.custom, apiKey: apiKey, baseURL: baseURL, model: model,
                                    effort: effort, textOnly: globalTextOnly)
                    try KeychainHelper.save(key: activeProfileKey, value: Profile.custom.rawValue)
                }
            case .openRouter:
                guard isConfigured(.openrouter) else { return }
                try KeychainHelper.save(key: openrouterTextOnlyKey, value: globalTextOnly ? "true" : "false")
                try KeychainHelper.save(key: activeProfileKey, value: Profile.openrouter.rawValue)
            case .lmStudio:
                guard isConfigured(.local) else { return }
                try KeychainHelper.save(key: localTextOnlyKey, value: globalTextOnly ? "true" : "false")
                try KeychainHelper.save(key: activeProfileKey, value: Profile.local.rawValue)
            }
        } catch {
            // A failed migration write means storage is broken; every later
            // save will fail loudly on its own. Don't block startup here.
            FileHandle.standardError.write(Data("⚠ provider-profile migration failed: \(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: Listing

    /// Human-readable status lines for /provider and the wizard summary.
    static func statusLines() -> [String] {
        let active = activeProfile()
        return Profile.allCases.map { profile in
            var line = "• \(profile.rawValue)"
            if profile == active { line += " — ACTIVE" }
            guard isConfigured(profile) else { return line + " — not configured" }
            var parts: [String] = []
            if let model = configuredModel(profile) { parts.append(model) }
            if let endpoint = configuredEndpoint(profile) { parts.append("@ \(endpoint)") }
            if let masked = maskedKey(profile) { parts.append("key \(masked)") }
            if let effort = configuredEffort(profile) { parts.append("effort \(effort)") }
            switch textOnly(profile) {
            case .some(true): parts.append("text-only (OCR preprocessing)")
            case .some(false): parts.append("vision")
            case .none: parts.append("vision unknown")
            }
            return line + " — " + parts.joined(separator: ", ")
        }
    }
}
