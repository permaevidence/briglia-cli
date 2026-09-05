import Foundation

/// The single classification of every key Briglia keeps in its secret store
/// (`KeychainHelper` and `ProviderProfiles` constants) plus the dynamic key
/// families. Two consumers read it and nothing else enumerates credentials
/// ad hoc:
///
/// - `KeychainHelper.redactionEnvironment()` seeds `SecretRedactor` with the
///   values tagged `.redact`;
/// - the secret-store selftest scans both source files for `static let …Key`
///   constants and fails when one is missing here, so a new key cannot be
///   added without deciding its treatment.
///
/// Treatment is an owner decision (2026-09-02), not a security ranking:
/// the Telegram bot token is remote control of the machine and is the only
/// first-class key in the redaction set; the provider, search, image,
/// transcription, Google OAuth and AgentMail keys are spend-capped or
/// revocable and stay deliberately visible to the agent because it uses them
/// for debugging and for scripts it writes. Service keys (the labelled
/// deployment-token feature) were designed around redaction and keep it.
/// Changing a tag is a one-line reviewed edit.
enum CredentialCatalog {
    enum Treatment: Equatable {
        /// Scrubbed from bash output, grep matches, MCP results and `read_file`
        /// of the harness secret store.
        case redact
        /// A secret the agent may see and use in full.
        case visible
        /// Configuration, identifiers or preferences — not a credential.
        case notSecret
    }

    struct Entry {
        let key: String
        let treatment: Treatment
    }

    /// A key family whose members are constructed at runtime (prefix match).
    struct Family {
        let prefix: String
        let treatment: Treatment
    }

    static let entries: [Entry] = [
        // Telegram pairing
        Entry(key: KeychainHelper.telegramBotTokenKey, treatment: .redact),
        Entry(key: KeychainHelper.telegramChatIdKey, treatment: .notSecret),
        Entry(key: KeychainHelper.whatsappOwnerPhoneKey, treatment: .notSecret),

        // Model providers (visible by owner decision)
        Entry(key: KeychainHelper.openRouterApiKeyKey, treatment: .visible),
        Entry(key: KeychainHelper.openAICompatibleApiKeyKey, treatment: .visible),
        Entry(key: ProviderProfiles.opencodeApiKeyKey, treatment: .visible),
        Entry(key: ProviderProfiles.customApiKeyKey, treatment: .visible),
        Entry(key: ProviderProfiles.openaiApiKeyKey, treatment: .visible),

        // Web search / extraction
        Entry(key: KeychainHelper.serperApiKeyKey, treatment: .visible),
        Entry(key: KeychainHelper.jinaApiKeyKey, treatment: .visible),
        Entry(key: KeychainHelper.webSearchOpenAIApiKeyKey, treatment: .visible),
        Entry(key: KeychainHelper.webSearchOpenCodeApiKeyKey, treatment: .visible),

        // Voice transcription
        Entry(key: KeychainHelper.openAITranscriptionApiKeyKey, treatment: .visible),

        // Image generation
        Entry(key: KeychainHelper.geminiApiKeyKey, treatment: .visible),
        Entry(key: KeychainHelper.openAIImageApiKeyKey, treatment: .visible),

        // Email / calendar
        Entry(key: KeychainHelper.agentMailApiKeyKey, treatment: .visible),
        Entry(key: KeychainHelper.gwsOAuthClientIDKey, treatment: .visible),
        Entry(key: KeychainHelper.gwsOAuthClientSecretKey, treatment: .visible),
        Entry(key: KeychainHelper.agentMailInboxAddressKey, treatment: .notSecret),
        Entry(key: KeychainHelper.emailCalendarProviderKey, treatment: .notSecret),

        // Balance thresholds
        Entry(key: KeychainHelper.balanceThresholdOpenRouterUSDKey, treatment: .notSecret),
        Entry(key: KeychainHelper.balanceThresholdSerperCreditsKey, treatment: .notSecret),
        Entry(key: KeychainHelper.balanceThresholdJinaTokensKey, treatment: .notSecret),

        // Image generation settings
        Entry(key: KeychainHelper.imageGenerationProviderKey, treatment: .notSecret),
        Entry(key: KeychainHelper.geminiImageModelKey, treatment: .notSecret),
        Entry(key: KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey, treatment: .notSecret),
        Entry(key: KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey, treatment: .notSecret),
        Entry(key: KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openAIImageModelKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openAIImageQualityKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openAIImageOutputFormatKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openAIImageModerationKey, treatment: .notSecret),

        // Persona
        Entry(key: KeychainHelper.assistantNameKey, treatment: .notSecret),
        Entry(key: KeychainHelper.userNameKey, treatment: .notSecret),
        Entry(key: KeychainHelper.userContextKey, treatment: .notSecret),
        Entry(key: KeychainHelper.structuredUserContextKey, treatment: .notSecret),

        // Model settings
        Entry(key: KeychainHelper.openRouterModelKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openRouterWebSearchModelKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openRouterProvidersKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openRouterReasoningEffortKey, treatment: .notSecret),
        Entry(key: KeychainHelper.legacyReasoningMigrationDoneKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey, treatment: .notSecret),
        Entry(key: KeychainHelper.voiceTranscriptionProviderKey, treatment: .notSecret),
        Entry(key: KeychainHelper.llmProviderKey, treatment: .notSecret),
        Entry(key: KeychainHelper.lmStudioBaseURLKey, treatment: .notSecret),
        Entry(key: KeychainHelper.lmStudioModelKey, treatment: .notSecret),
        Entry(key: KeychainHelper.lmStudioDescriptionModelKey, treatment: .notSecret),
        Entry(key: KeychainHelper.lmStudioDescriptionBaseURLKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openAICompatibleBaseURLKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openAICompatibleModelKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openAICompatibleReasoningEffortKey, treatment: .notSecret),
        Entry(key: KeychainHelper.textOnlyModelEnabledKey, treatment: .notSecret),
        Entry(key: KeychainHelper.visionPreprocessorModelKey, treatment: .notSecret),
        Entry(key: KeychainHelper.visionPreprocessorProviderKey, treatment: .notSecret),
        Entry(key: KeychainHelper.visionPreprocessorBackendKey, treatment: .notSecret),
        Entry(key: KeychainHelper.visionPreprocessorReasoningEffortKey, treatment: .notSecret),
        Entry(key: KeychainHelper.archiveChunkSizeKey, treatment: .notSecret),
        Entry(key: KeychainHelper.maxContextTokensKey, treatment: .notSecret),
        Entry(key: KeychainHelper.targetContextTokensKey, treatment: .notSecret),
        Entry(key: KeychainHelper.subagentTurnTokenBudgetKey, treatment: .notSecret),

        // Provider profiles
        Entry(key: ProviderProfiles.activeProfileKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.openaiModelKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.openaiEffortKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.openaiTextOnlyKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.customProtocolKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.runtimeProtocolKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.customNativeMediaKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.runtimeNativeMediaKey, treatment: .notSecret),

        Entry(key: ProviderProfiles.opencodeModelKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.opencodeReasoningEffortKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.opencodeTextOnlyKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.customBaseURLKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.customModelKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.customReasoningEffortKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.customTextOnlyKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.openrouterTextOnlyKey, treatment: .notSecret),
        Entry(key: ProviderProfiles.localTextOnlyKey, treatment: .notSecret),

        // UserDefaults-backed bookkeeping (not in the secret store, listed so
        // the completeness scan has no exceptions)
        Entry(key: KeychainHelper.serviceKeysMetadataDefaultsKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openRouterSpendLedgerDefaultsKey, treatment: .notSecret),
        Entry(key: KeychainHelper.openRouterSpendLimitBoostDefaultsKey, treatment: .notSecret),
    ]

    static let families: [Family] = [
        // Labelled deployment tokens: `servicekey_<NAME>`; surfaced to the
        // redactor as BRIGLIA_KEY_<NAME> by KeychainHelper.serviceKeyEnvironment().
        Family(prefix: KeychainHelper.serviceKeyPrefix, treatment: .redact),
        // MCP server secrets: `mcp_env_<server>_<variable>` (MCPRegistry).
        Family(prefix: "mcp_env_", treatment: .visible),
    ]

    static func treatment(forKey key: String) -> Treatment? {
        if let entry = entries.first(where: { $0.key == key }) { return entry.treatment }
        if let family = families.first(where: { key.hasPrefix($0.prefix) }) { return family.treatment }
        return nil
    }

    /// Keys of the first-class entries tagged `.redact` (the dynamic service-key
    /// family is contributed separately by `KeychainHelper.serviceKeyEnvironment()`).
    static var redactedKeys: [String] {
        entries.filter { $0.treatment == .redact }.map(\.key)
    }
}

/// Rules for the harness's own secret store (`secrets.json` under the config
/// root) as seen through the model-facing file tools. The file stays
/// agent-editable field by field — the agent legitimately updates Serper,
/// Jina, AgentMail or provider keys when the user pastes a new one — but the
/// Telegram bot token is masked on read and owned by `/switchbot`, so:
///
/// - `read_file` returns the token value as the placeholder;
/// - `edit_file` / `apply_patch` refuse any edit whose old or new text touches
///   the token field or carries a placeholder back into the file;
/// - `write_file` refuses the file outright: a whole-file rewrite composed
///   from a masked read would write the placeholder over the real token.
///
/// Files anywhere else (a project `.env`, another app's config) are untouched
/// by these rules.
enum HarnessSecretStore {
    static let tokenPlaceholder = "[REDACTED:\(KeychainHelper.telegramBotTokenKey)]"
    static let placeholderPrefix = "[REDACTED:"

    /// Minimum length for a value to be treated as a secret worth matching;
    /// shorter strings would produce false positives on ordinary text.
    static let minimumSecretLength = 8

    static var storePath: String { KeychainHelper.secretStorePath }

    /// True when `path` (already absolute) denotes the secret store, after
    /// resolving symlinks on both sides so `/var` vs `/private/var` and a
    /// linked config directory compare equal.
    static func isSecretStore(_ path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let store = URL(fileURLWithPath: storePath).resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == store
    }

    private static func storedToken() -> String? {
        guard let token = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey),
              token.count >= minimumSecretLength else { return nil }
        return token
    }

    /// The store's text with the Telegram token value replaced by the placeholder.
    static func maskedForRead(_ text: String) -> String {
        guard let token = storedToken() else { return text }
        return text.replacingOccurrences(of: token, with: tokenPlaceholder)
    }

    /// Reason to refuse an in-place edit of the store, or nil when the edit is
    /// a targeted change to some other field.
    static func editRefusal(oldText: String, newText: String) -> String? {
        if newText.contains(placeholderPrefix) {
            return "edit refused: new_string contains a \(placeholderPrefix)…] placeholder. That is the masked display of the Telegram bot token, not file content — never write it back. The token field is managed by /switchbot; every other field of this file can be edited one at a time."
        }
        return refusalForTokenField(texts: [oldText, newText])
    }

    /// Reason to refuse an apply_patch hunk set on the store, or nil.
    static func patchRefusal(hunks: [ApplyPatch.Hunk]) -> String? {
        var touched: [String] = []
        for hunk in hunks {
            for (kind, line) in hunk.diff where kind != .context {
                if kind == .added, line.contains(placeholderPrefix) {
                    return "patch refused: an added line contains a \(placeholderPrefix)…] placeholder. That is the masked display of the Telegram bot token, not file content — never write it back."
                }
                touched.append(line)
            }
        }
        return refusalForTokenField(texts: touched)
    }

    static var wholeFileRewriteRefusal: String {
        "write_file refused: \(storePath) is Briglia's own secret store and is read with the Telegram bot token masked, so a whole-file rewrite would overwrite the real token with the placeholder. Use edit_file for individual fields (Serper, Jina, AgentMail, provider keys…); the token itself is managed by /switchbot."
    }

    static var deleteOrMoveRefusal: String {
        "refused: \(storePath) is Briglia's own secret store and cannot be deleted or moved by the file tools. Use edit_file for individual fields; /deleteuserdata removes the store."
    }

    /// Post-edit invariant, the check the text-level refusals cannot provide
    /// (an edit may target a substring of the token or of the field name):
    /// parse both versions of the store and require the token entry to be
    /// byte-identical. A result that is no longer a JSON object of strings is
    /// refused too — the store's own loader would reject it and every key
    /// would be lost to the daemon.
    static func tokenInvariantViolation(original: String, updated: String) -> String? {
        func parse(_ s: String) -> [String: String]? {
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            var out: [String: String] = [:]
            for (k, v) in obj {
                guard let str = v as? String else { return nil }
                out[k] = str
            }
            return out
        }
        guard let after = parse(updated) else {
            return "edit refused: the result is not a JSON object of string values, which is the only shape Briglia's secret store accepts — the daemon would lose every key. Edit one field at a time and keep the file valid JSON."
        }
        let before = parse(original)
        let key = KeychainHelper.telegramBotTokenKey
        if before?[key] != after[key] {
            return "edit refused: the result changes the Telegram bot token entry of Briglia's secret store (the edit overlapped the token or its field name). The token is managed by /switchbot (and `briglia setup`); every other field of this file can be edited one at a time."
        }
        return nil
    }

    private static func refusalForTokenField(texts: [String]) -> String? {
        let fieldMarker = "\"\(KeychainHelper.telegramBotTokenKey)\""
        let token = storedToken()
        for text in texts {
            if text.contains(fieldMarker) || (token.map { text.contains($0) } ?? false) {
                return "edit refused: this change touches the Telegram bot token field of Briglia's secret store. The token is managed by /switchbot (and `briglia setup`); every other field of this file can be edited one at a time."
            }
        }
        return nil
    }
}
