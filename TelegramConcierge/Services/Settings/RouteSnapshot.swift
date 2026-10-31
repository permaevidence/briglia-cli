import Foundation

/// Every key of the secret store belongs to exactly one role
/// (KEYLESS_WEB_AND_LIVE_MENU plan B.4 completeness guard):
///
/// - `route`: its value decides what the model, its tools, the media paths
///   or the email path use (provider, profile, endpoint, model, effort,
///   protocol, vision flags, pins, lanes, OCR / transcription / image /
///   page-reading / search choices, email provider and inbox, the bot);
/// - `credential`: an API key — its VALUE never decides a route (a new key
///   for the same service applies at once, even mid-task), its PRESENCE may;
/// - `other`: persona, budgets, thresholds, bookkeeping — never a route.
///
/// A key no pattern matches is treated as a route input (conservative: the
/// change waits for an idle point instead of landing mid-task), and the
/// settings-writer selftest fails on any key constant the code defines that
/// is unmatched.
enum SettingsKeyRole: String {
    case route, credential, other
}

enum SettingsKeyRoles {
    // MARK: Exact keys

    static let routeKeys: Set<String> = [
        KeychainHelper.llmProviderKey, ProviderProfiles.activeProfileKey,
        ProviderProfiles.runtimeProtocolKey, ProviderProfiles.runtimeNativeMediaKey,
        ProviderProfiles.customProtocolKey, ProviderProfiles.customNativeMediaKey,
        KeychainHelper.openRouterModelKey, KeychainHelper.openRouterWebSearchModelKey,
        KeychainHelper.openRouterProvidersKey, OpenRouterPinMap.storageKey, OpenRouterPinMap.corruptBackupKey,
        KeychainHelper.openRouterReasoningEffortKey, ProviderProfiles.openrouterTextOnlyKey,
        KeychainHelper.lmStudioBaseURLKey, KeychainHelper.lmStudioModelKey,
        KeychainHelper.lmStudioDescriptionModelKey, KeychainHelper.lmStudioDescriptionBaseURLKey,
        ProviderProfiles.localTextOnlyKey, ProviderServers.localBindingKey,
        KeychainHelper.openAICompatibleBaseURLKey, KeychainHelper.openAICompatibleModelKey,
        KeychainHelper.openAICompatibleReasoningEffortKey, KeychainHelper.textOnlyModelEnabledKey,
        KeychainHelper.visionPreprocessorModelKey, KeychainHelper.visionPreprocessorProviderKey,
        KeychainHelper.visionPreprocessorBackendKey, KeychainHelper.visionPreprocessorReasoningEffortKey,
        ProviderProfiles.opencodeModelKey, ProviderProfiles.opencodeReasoningEffortKey, ProviderProfiles.opencodeTextOnlyKey,
        ProviderProfiles.customBaseURLKey, ProviderProfiles.customModelKey, ProviderProfiles.customReasoningEffortKey,
        ProviderProfiles.customTextOnlyKey, ProviderServers.customBindingKey, ProviderServers.listKey,
        ProviderProfiles.subscriptionModelKey, ProviderProfiles.subscriptionEffortKey, ProviderProfiles.subscriptionTextOnlyKey,
        ProviderProfiles.subscriptionGenerationKey, SubscriptionSharing.scopeKey, SubscriptionSharing.accountFingerprintKey,
        ProviderProfiles.openaiModelKey, ProviderProfiles.openaiEffortKey, ProviderProfiles.openaiTextOnlyKey,
        KeychainHelper.voiceTranscriptionProviderKey,
        KeychainHelper.imageGenerationProviderKey, KeychainHelper.geminiImageModelKey,
        KeychainHelper.openAIImageModelKey, KeychainHelper.openAIImagePreciseModelKey,
        KeychainHelper.openAIImageQualityKey, KeychainHelper.openAIImageOutputFormatKey, KeychainHelper.openAIImageModerationKey,
        KeychainHelper.keylessSearchKey, WebSearchBackend.secretsSelectionKey,
        KeychainHelper.emailCalendarProviderKey, KeychainHelper.agentMailInboxAddressKey,
        KeychainHelper.telegramBotTokenKey, KeychainHelper.telegramChatIdKey,
    ]

    static let credentialKeys: Set<String> = [
        KeychainHelper.openRouterApiKeyKey, KeychainHelper.openAICompatibleApiKeyKey,
        ProviderProfiles.opencodeApiKeyKey, ProviderProfiles.customApiKeyKey, ProviderProfiles.openaiApiKeyKey,
        KeychainHelper.serperApiKeyKey, KeychainHelper.jinaApiKeyKey,
        KeychainHelper.webSearchOpenAIApiKeyKey, KeychainHelper.webSearchOpenCodeApiKeyKey,
        KeychainHelper.openAITranscriptionApiKeyKey, KeychainHelper.geminiApiKeyKey, KeychainHelper.openAIImageApiKeyKey,
        KeychainHelper.agentMailApiKeyKey,
        KeychainHelper.retiredGwsOAuthClientIDKey, KeychainHelper.retiredGwsOAuthClientSecretKey,
    ]

    static let otherKeys: Set<String> = [
        KeychainHelper.telegramBotUsernameKey, KeychainHelper.assistantGreetingPendingKey,
        KeychainHelper.retiredWhatsappOwnerPhoneKey,
        KeychainHelper.balanceThresholdOpenRouterUSDKey, KeychainHelper.balanceThresholdSerperCreditsKey,
        KeychainHelper.balanceThresholdJinaTokensKey,
        KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey, KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey,
        KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey,
        KeychainHelper.assistantNameKey, KeychainHelper.userNameKey, KeychainHelper.userContextKey,
        KeychainHelper.structuredUserContextKey, KeychainHelper.legacyReasoningMigrationDoneKey,
        KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey, KeychainHelper.openRouterToolSpendLimitDailyUSDKey,
        KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey,
        KeychainHelper.archiveChunkSizeKey, KeychainHelper.maxContextTokensKey, KeychainHelper.targetContextTokensKey,
        KeychainHelper.subagentTurnTokenBudgetKey,
        SetupWizard.completeKey, SetupWizard.progressKey, "playwright_auto_configured",
        // UserDefaults-backed keys the source scan also sees (never in the store).
        KeychainHelper.serviceKeysMetadataDefaultsKey, KeychainHelper.openRouterSpendLedgerDefaultsKey,
        KeychainHelper.openRouterSpendLimitBoostDefaultsKey,
        // Settings-writer bookkeeping (plan B.4a 8.3, B.4c step 5).
        SettingsWriter.scopePublishedKey,
    ]

    // MARK: Generated key families

    struct Family { let role: SettingsKeyRole; let matches: (String) -> Bool; let name: String }

    static let families: [Family] = [
        // SubagentModelLanes.storageKey: subagent_<lane>_model_<provider>[_<endpoint>]
        Family(role: .route, matches: { $0.hasPrefix("subagent_") && $0.contains("_model_") }, name: "subagent lane"),
        Family(role: .credential, matches: { $0.hasPrefix(KeychainHelper.serviceKeyPrefix) }, name: "service key"),
        Family(role: .credential, matches: { $0.hasPrefix("mcp_env_") }, name: "MCP secret"),
        Family(role: .other, matches: { $0.hasPrefix(SettingsWriter.attemptMarkerPrefix) }, name: "attempt marker"),
    ]

    /// nil = no pattern matches (callers treat it as `route`).
    static func roleIfKnown(_ key: String) -> SettingsKeyRole? {
        if routeKeys.contains(key) { return .route }
        if credentialKeys.contains(key) { return .credential }
        if otherKeys.contains(key) { return .other }
        return families.first { $0.matches(key) }?.role
    }

    static func role(_ key: String) -> SettingsKeyRole { roleIfKnown(key) ?? .route }

    /// Number of patterns matching `key` (the guard requires exactly one).
    static func matchCount(_ key: String) -> Int {
        [routeKeys.contains(key), credentialKeys.contains(key), otherKeys.contains(key)].filter { $0 }.count
            + families.filter { $0.matches(key) }.count
    }

    static let emailKeys: Set<String> = [
        KeychainHelper.emailCalendarProviderKey, KeychainHelper.agentMailApiKeyKey, KeychainHelper.agentMailInboxAddressKey,
        KeychainHelper.retiredGwsOAuthClientIDKey, KeychainHelper.retiredGwsOAuthClientSecretKey,
    ]

    /// The pending slot of a change: email when it touches only the email
    /// path (or an inbox), otherwise ai.
    static func category(of change: PreparedChange) -> String {
        if change.identity?.kind == "inbox" { return "email" }
        let keys = change.touchedKeys
        if !keys.isEmpty, keys.isSubset(of: emailKeys.union(otherKeys)), !keys.isDisjoint(with: emailKeys) { return "email" }
        return "ai"
    }

    /// Keys a same-account automatic rebind rewrites (plan B.5: maintenance,
    /// not a user change) — left out of the whole-store digest so a rebind
    /// while a change is staged does not refuse it.
    static let maintenanceKeys: Set<String> = [ProviderProfiles.subscriptionGenerationKey, SubscriptionSharing.accountFingerprintKey]

    /// Digest of the route and credential keys (values) of `store`.
    static func routeDigest(_ store: [String: String]) -> String {
        var pairs: [String: String] = [:]
        for (k, v) in store where role(k) != .other && !maintenanceKeys.contains(k) { pairs[k] = v }
        return SettingsDigest.of(pairs: pairs)
    }
}

/// The facts of the subscription store a route depends on.
struct SubscriptionRouteFacts: Equatable {
    var present: Bool
    var requiresLogin: Bool
    var accountFingerprint: String?

    static let absent = SubscriptionRouteFacts(present: false, requiresLogin: false, accountFingerprint: nil)

    init(present: Bool, requiresLogin: Bool, accountFingerprint: String?) {
        self.present = present; self.requiresLogin = requiresLogin; self.accountFingerprint = accountFingerprint
    }

    init(_ state: SubscriptionAuthState?) {
        guard let state, let credential = state.credential else { self = .absent; return }
        self.init(present: true, requiresLogin: state.requiresLogin == true,
                  accountFingerprint: SubscriptionSharing.fingerprint(credential.account))
    }
}

/// The tool-inventory switches (Telegram-only, in the daemon's preferences).
struct SettingsToolSwitches: Equatable {
    var subagents: Bool
    var webSubagent: Bool

    static func current(_ defaults: UserDefaults = Prefs.store) -> SettingsToolSwitches {
        SettingsToolSwitches(subagents: defaults.object(forKey: "ada.subagentsEnabled") as? Bool ?? true,
                             webSubagent: defaults.object(forKey: "ada.webSubagentEnabled") as? Bool ?? true)
    }
}

/// What every request, schema and media path would use for a settings
/// state (plan B.4). Two snapshots differ ⇔ some route input differs:
/// a route key's value, a credential's presence, the subscription facts or
/// a tool switch — plus the outputs of the request path's own resolvers,
/// evaluated as pure functions of the dictionary (`SettingsCapture.evaluate`).
/// It is a superset of what the builders read, so it is conservative: a
/// change whose effect a fallback masks is still classified as a route
/// change (it waits for an idle point); it can never classify a real route
/// change as a plain key replacement.
struct RouteSnapshot: Equatable {
    var fields: [String: String]

    static func of(stored: [String: String], subscription: SubscriptionRouteFacts,
                   switches: SettingsToolSwitches) -> RouteSnapshot {
        var fields: [String: String] = [:]
        for (key, value) in stored {
            switch SettingsKeyRoles.role(key) {
            case .route: fields["k:" + key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .credential:
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["c:" + key] = "present" }
            case .other: break
            }
        }
        // The login is a route input only while ChatGPT is the active lane:
        // publishing a login for another lane is a plain save, the same
        // account signing in again is a credential replacement; a different
        // account, a sign-out or activating ChatGPT changes the route.
        if stored[ProviderProfiles.activeProfileKey] == ProviderProfiles.Profile.chatgpt.rawValue {
            fields["sub"] = subscription.present ? "account|\(subscription.accountFingerprint ?? "")" : "absent"
        }
        fields["switch"] = "\(switches.subagents)|\(switches.webSubagent)"
        // The request path's resolvers, evaluated on this dictionary.
        SettingsCapture.evaluate(store: stored) {
            fields["r:transcription"] = String(describing: MediaRouting.transcription(stored: stored))
            fields["r:image"] = String(describing: MediaRouting.imageBackend(stored: stored))
            fields["r:protocol"] = ProviderProfiles.runtimeProtocolValue(stored: stored, model: nil) ?? ""
            fields["r:extraction"] = String(describing: WebSearchBackend.selection(stored: stored))
            fields["r:search"] = KeylessSearchSwitch.resolve(snapshot: stored).rawValue
            fields["r:email"] = stored[KeychainHelper.emailCalendarProviderKey] ?? ""
        }
        return RouteSnapshot(fields: fields)
    }

    /// The fields that differ (for logs and tests).
    func difference(_ other: RouteSnapshot) -> [String] {
        Set(fields.keys).union(other.fields.keys).filter { fields[$0] != other.fields[$0] }.sorted()
    }
}
