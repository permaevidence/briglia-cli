import Foundation
#if canImport(Glibc)
import Glibc
#endif
#if canImport(Darwin)
import Darwin
#endif

extension Notification.Name {
    static let adaLLMProviderDidChange = Notification.Name("ada.llmProviderDidChange")
}

enum LLMProvider: String, CaseIterable, Identifiable {
    case openRouter = "openrouter"
    case lmStudio = "lmstudio" // Kept as "lmstudio" for backward compatibility; represents any local provider
    case openAICompatible = "openai_compatible" // Any remote OpenAI-compatible endpoint (base URL + API key)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .lmStudio: return "Local Inference"
        case .openAICompatible: return "OpenAI-Compatible"
        }
    }

    /// Non-OpenRouter, OpenAI-compatible `/chat/completions` endpoints (local or remote custom API).
    /// These share the same request format and provider-routing behavior; they differ only in auth.
    var isCustomEndpoint: Bool {
        switch self {
        case .lmStudio, .openAICompatible: return true
        case .openRouter: return false
        }
    }

    static var defaultProvider: LLMProvider { .lmStudio }

    static func fromStoredValue(_ value: String?) -> LLMProvider {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let provider = LLMProvider(rawValue: normalized) else {
            return .defaultProvider
        }
        return provider
    }
}

enum VoiceTranscriptionProvider: String, CaseIterable, Identifiable {
    // Order matters: allCases drives the pickers, OpenAI is shown first.
    case openAI = "openai"
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:
            return "Local (Whisper)"
        case .openAI:
            return "OpenAI (gpt-transcribe)"
        }
    }

    // Briglia CLI is cloud-only: the WhisperKit shim never reports a ready model,
    // so .local would break every voice message. Default to OpenAI and
    // normalize any stored "local" (older/incomplete installs, imported
    // Ada.app state) at the single read choke point.
    static var defaultProvider: VoiceTranscriptionProvider { .openAI }

    static func fromStoredValue(_ value: String?) -> VoiceTranscriptionProvider {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let provider = VoiceTranscriptionProvider(rawValue: normalized) else {
            return .defaultProvider
        }
        return provider == .local ? .openAI : provider
    }
}

enum KeychainHelper {
    
    enum KeychainError: Error {
        case duplicateItem
        case itemNotFound
        case unexpectedStatus(Int32)
    }
    
    // File-backed secret store. Briglia CLI deliberately does NOT use the macOS
    // Keychain: a from-source CLI gets a new ad-hoc code identity on every
    // rebuild, so the Keychain would pop an authorization dialog for every
    // stored item after every update — and block forever in headless runs.
    // Secrets live in ~/.config/briglia/secrets.json with 0600 permissions, the
    // same mechanism Phase 2 uses on Linux. The KeychainHelper name and the
    // save/load/delete surface are kept so the ported Ada.app services are
    // untouched.
    private static let storeURL = StoragePaths.configRoot.appendingPathComponent("secrets.json")
    /// Absolute path of the secret store, for the file-tool rules in
    /// `HarnessSecretStore` (read masking, edit/write refusals).
    static var secretStorePath: String { storeURL.path }
    // Cross-process write lock. The store file itself is replaced atomically
    // on every write (new inode), so a lock must live on a stable sidecar.
    private static let lockURL = StoragePaths.configRoot.appendingPathComponent("secrets.lock")
    private static let lock = NSLock()

    // The cache mirrors ONE specific on-disk state, identified by
    // inode + mtime(ns) + size. secrets.json has more than one writer — the
    // daemon plus every short-lived `briglia setup-api`/wizard process — and a
    // per-process forever-cache silently reverted the other writer's keys on
    // the next save (field incident 2026-08-29: keys saved from the UT app
    // were at risk of dying with the daemon's next persona write, and the
    // daemon couldn't even see them until restart). Reads revalidate the
    // stamp; writes re-read the disk under the sidecar flock.
    private struct DiskStamp: Equatable {
        var inode: UInt64
        var mtimeSec: Int
        var mtimeNSec: Int
        var size: Int64
    }
    nonisolated(unsafe) private static var cache: [String: String]?
    nonisolated(unsafe) private static var cacheStamp: DiskStamp?

    static func save(key: String, value: String) throws {
        try mutate { $0[key] = value }
    }

    static func load(key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storeLocked()[key]
    }

    /// One coherent file version for an operation's provider selection. Callers
    /// must never log or persist this in-memory snapshot. Atomic store replacement
    /// gives a complete old-or-new dictionary even across another process's write.
    static func loadSnapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storeLocked()
    }

    static func delete(key: String) throws {
        try mutate { $0.removeValue(forKey: key) }
    }

    /// Read-only health check used by the identity-migration probe: nil
    /// when the store is absent or decodes; otherwise the strict reader's
    /// diagnosis. Never writes, never caches.
    static func storeReadProblem() -> String? {
        lock.lock()
        defer { lock.unlock() }
        do { _ = try readDiskStrict(); return nil } catch {
            return (error as? StoreDamagedError)?.message ?? error.localizedDescription
        }
    }

    /// Apply several writes (nil value = delete) as ONE atomic file write.
    /// Multi-key state transitions (provider-profile activation) use this so
    /// a mid-sequence failure can't leave half the keys switched — the store
    /// either commits every change or none.
    static func saveBatch(_ changes: [String: String?]) throws {
        try mutate { store in
            for (key, value) in changes {
                if let value {
                    store[key] = value
                } else {
                    store.removeValue(forKey: key)
                }
            }
        }
    }

    private static func mutate(_ change: (inout [String: String]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        // Writes materialize the config root; reads never do (StoragePaths:
        // diagnostics must not create empty new roots that mask the
        // identity-migration detection).
        try? PrivateStorage.ensureDirectory(StoragePaths.configRoot)
        // Serialize against every OTHER Briglia process before deciding what the
        // store contains. Held across read-modify-write so two concurrent
        // writers can't both start from the same base and last-writer-wins.
        let fd = open(lockURL.path, O_CREAT | O_WRONLY, 0o600)
        guard fd >= 0 else {
            throw KeychainError.unexpectedStatus(errno)
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw KeychainError.unexpectedStatus(errno)
        }
        // Fresh read from DISK, never from the cache: the cache may predate
        // another process's write, and rewriting the whole file from a stale
        // snapshot is exactly the clobber this function must prevent.
        // STRICT read (Codex, 2026-08-29): only a genuinely absent file may
        // mean "empty store" — an unreadable or undecodable existing file
        // must fail the mutation and keep its bytes, or this write would
        // replace every stored secret with empty-plus-delta and report ok.
        var store = try readDiskStrict().store
        change(&store)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        // Disk write FIRST, cache second: if the write throws (read-only
        // config dir, full disk), in-memory reads must not pretend the value
        // was saved — that made `briglia setup` look successful and break only
        // after restart.
        // 0600 is applied to the temp file BEFORE the rename, so the store
        // never exists with a wider mode (PrivateStorage).
        try PrivateStorage.writeAtomically(data, to: storeURL, mode: 0o600)
        cache = store
        cacheStamp = statStore()  // still under flock: the stamp is ours
    }

    private static func storeLocked() -> [String: String] {
        // Cache hit only while the file on disk is byte-for-byte the state
        // this cache was built from (nil == nil covers a still-absent file).
        if let cache, cacheStamp == statStore() { return cache }
        let fresh = readDisk()
        cache = fresh.store
        cacheStamp = fresh.stamp
        return fresh.store
    }

    /// Stamp BEFORE content: if a writer replaces the file between the two,
    /// we pair new content with an old stamp and merely re-read next time —
    /// the reverse order could pin stale content under a fresh stamp.
    ///
    /// Lenient variant, READS ONLY: a damaged store degrades to an empty
    /// view (keys look unset), which cannot destroy data. Writes must use
    /// readDiskStrict() instead.
    private static func readDisk() -> (store: [String: String], stamp: DiskStamp?) {
        let stamp = statStore()
        let loaded = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return (loaded, stamp)
    }

    struct StoreDamagedError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Strict variant for mutations: absent file → empty store; an EXISTING
    /// file that cannot be read or decoded throws, so the caller's write
    /// never replaces real (possibly recoverable) secrets with emptiness.
    private static func readDiskStrict() throws -> (store: [String: String], stamp: DiskStamp?) {
        guard let stamp = statStore() else { return ([:], nil) }
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch {
            throw StoreDamagedError(message:
                "secrets store exists but cannot be read (\(storeURL.path): "
                + "\(error.localizedDescription)) — refusing to overwrite it; "
                + "fix its permissions and retry")
        }
        do {
            return (try JSONDecoder().decode([String: String].self, from: data), stamp)
        } catch {
            throw StoreDamagedError(message:
                "secrets store is not valid JSON (\(storeURL.path)) — refusing "
                + "to overwrite it; repair or move the file aside and retry")
        }
    }

    private static func statStore() -> DiskStamp? {
        var st = stat()
        guard stat(storeURL.path, &st) == 0 else { return nil }
        #if os(Linux)
        return DiskStamp(inode: UInt64(st.st_ino),
                         mtimeSec: Int(st.st_mtim.tv_sec),
                         mtimeNSec: Int(st.st_mtim.tv_nsec),
                         size: Int64(st.st_size))
        #else
        return DiskStamp(inode: UInt64(st.st_ino),
                         mtimeSec: Int(st.st_mtimespec.tv_sec),
                         mtimeNSec: Int(st.st_mtimespec.tv_nsec),
                         size: Int64(st.st_size))
        #endif
    }
}

// MARK: - Credential Keys
extension KeychainHelper {
    static let defaultGeminiImageModel = ""
    static let defaultGeminiImageInputCostPerMillionTokensUSD = "2"
    static let defaultGeminiImageOutputTextCostPerMillionTokensUSD = "12"
    static let defaultGeminiImageOutputImageCostPerMillionTokensUSD = "120"
    static let defaultImageGenerationProvider = "gemini"
    static let defaultOpenAIImageModel = "gpt-image-2.5-flare"
    static let defaultOpenAIImagePreciseModel = "gpt-image-2.5-sunburst"
    static let defaultOpenAIImageQuality = "auto"
    static let defaultOpenAIImageOutputFormat = "png"
    static let defaultOpenAIImageModeration = "auto"

    static let telegramBotTokenKey = "telegram_bot_token"
    static let telegramChatIdKey = "telegram_chat_id"
    static let whatsappOwnerPhoneKey = "whatsapp_owner_phone"
    static let openRouterApiKeyKey = "openrouter_api_key"
    
    // Web Search Tool Keys
    static let serperApiKeyKey = "serper_api_key"
    static let jinaApiKeyKey = "jina_api_key"

    // Low-balance warning thresholds (BalanceMonitor). Empty/unset → built-in
    // defaults ($5 / 200 credits / 1M tokens, settled 2026-07-07).
    static let balanceThresholdOpenRouterUSDKey = "balance_threshold_openrouter_usd"
    static let balanceThresholdSerperCreditsKey = "balance_threshold_serper_credits"
    static let balanceThresholdJinaTokensKey = "balance_threshold_jina_tokens"
    
    // Google Workspace (Gmail / Calendar / Contacts / Drive) is reached through
    // the `gws` CLI — auth tokens live in gws's own keyring, not here. The
    // former imap/smtp/gmail-OAuth keys were removed as part of that migration.
    // The user-provided OAuth client (Briglia no longer ships one embedded) is
    // stored here so the wizard can rewrite ~/.config/gws/client_secret.json
    // if it's ever deleted.
    static let gwsOAuthClientIDKey = "gws_oauth_client_id"
    static let gwsOAuthClientSecretKey = "gws_oauth_client_secret"

    // Email/calendar provider selection: "none" (default), "agentmail", "gws".
    // Read through EmailCalendarProvider.current — never directly.
    static let emailCalendarProviderKey = "email_calendar_provider"
    // AgentMail: dedicated agent inbox (api.agentmail.to). The inbox address
    // is captured at wizard time from the live key probe so prompt text can
    // name it without a network call.
    static let agentMailApiKeyKey = "agentmail_api_key"
    static let agentMailInboxAddressKey = "agentmail_inbox_address"

    // Google Gemini API Key
    static let geminiApiKeyKey = "gemini_api_key"
    static let imageGenerationProviderKey = "image_generation_provider"
    static let geminiImageModelKey = "gemini_image_model"
    static let geminiImageInputCostPerMillionTokensUSDKey = "gemini_image_input_cost_per_million_tokens_usd"
    static let geminiImageOutputTextCostPerMillionTokensUSDKey = "gemini_image_output_text_cost_per_million_tokens_usd"
    static let geminiImageOutputImageCostPerMillionTokensUSDKey = "gemini_image_output_image_cost_per_million_tokens_usd"
    static let openAIImageApiKeyKey = "openai_image_api_key"
    static let openAIImageModelKey = "openai_image_model"
    static let openAIImagePreciseModelKey = "openai_image_precise_model"
    static let openAIImageQualityKey = "openai_image_quality"
    static let openAIImageOutputFormatKey = "openai_image_output_format"
    static let openAIImageModerationKey = "openai_image_moderation"
    
    // Persona Settings Keys
    static let assistantNameKey = "assistant_name"
    static let userNameKey = "user_name"
    static let userContextKey = "user_context"
    static let structuredUserContextKey = "structured_user_context"
    
    // Model Settings
    static let openRouterModelKey = "openrouter_model"
    static let openRouterWebSearchModelKey = "openrouter_websearch_model"
    // GPT-5.6 Luna: cheaper than Gemini 3 Flash on OpenRouter ($0.10/$0.60 vs
    // $0.50/$3.00 per M tokens, 2026-08-01) and stronger at legal synthesis.
    // Effort comes from openrouter_reasoning_effort (defaults to high).
    static let defaultWebSearchModel = "openai/gpt-5.6-luna"
    static let openRouterProvidersKey = "openrouter_providers"
    static let openRouterReasoningEffortKey = "openrouter_reasoning_effort"
    // Dedicated key slots for the alternative web-search backends (see
    // WebSearchBackend). Empty today: the resolver in WebOrchestrator falls
    // back to keys the user already provided for other features.
    static let webSearchOpenAIApiKeyKey = "web_search_openai_api_key"
    static let webSearchOpenCodeApiKeyKey = "web_search_opencode_api_key"
    /// One-shot gate for the pre-v0.1.28 reasoning-provenance migration —
    /// see OpenRouterService.legacyMigrationPermitted.
    static let legacyReasoningMigrationDoneKey = "legacy_reasoning_migration_done"
    static let openRouterToolSpendLimitPerTurnUSDKey = "openrouter_tool_spend_limit_per_turn_usd"
    static let openRouterToolSpendLimitDailyUSDKey = "openrouter_tool_spend_limit_daily_usd"
    static let openRouterToolSpendLimitMonthlyUSDKey = "openrouter_tool_spend_limit_monthly_usd"

    // Voice Transcription Settings
    static let voiceTranscriptionProviderKey = "voice_transcription_provider"
    static let openAITranscriptionApiKeyKey = "openai_transcription_api_key"
    
    // LLM Provider Selection
    static let llmProviderKey = "llm_provider"  // "openrouter", "lmstudio", or "openai_compatible"
    static let lmStudioBaseURLKey = "lmstudio_base_url"
    static let lmStudioModelKey = "lmstudio_model"
    static let defaultLMStudioBaseURL = "http://localhost:1234/v1"
    static let lmStudioDescriptionModelKey = "lmstudio_description_model"
    static let lmStudioDescriptionBaseURLKey = "lmstudio_description_base_url"

    // OpenAI-Compatible Provider (remote endpoint + API key; behaves like Local for the main model)
    static let openAICompatibleBaseURLKey = "openai_compatible_base_url"
    static let openAICompatibleModelKey = "openai_compatible_model"
    static let openAICompatibleApiKeyKey = "openai_compatible_api_key"
    static let openAICompatibleReasoningEffortKey = "openai_compatible_reasoning_effort"

    // Text-Only Model Settings
    static let textOnlyModelEnabledKey = "text_only_model_enabled"  // "true" or absent
    static let visionPreprocessorModelKey = "vision_preprocessor_model"
    static let visionPreprocessorProviderKey = "vision_preprocessor_provider"
    static let visionPreprocessorBackendKey = "vision_preprocessor_backend"  // "openai" (default when an OpenAI key exists) or "openrouter"
    static let visionPreprocessorReasoningEffortKey = "vision_preprocessor_reasoning_effort"
    // GPT-5.6 Luna: cheaper than Gemini 3 Flash on OpenRouter and verified
    // (2026-08-01) to OCR correctly with zdr-only routing (lands on Azure's
    // ZDR endpoint; OpenAI first-party is not ZDR-eligible).
    static let defaultVisionPreprocessorModel = "openai/gpt-5.6-luna"

    // Archive Settings
    static let archiveChunkSizeKey = "archive_chunk_size"

    // Context Budget Settings (tool interaction pruning)
    static let maxContextTokensKey = "max_context_tokens"
    static let targetContextTokensKey = "target_context_tokens"

    // Subagent per-turn context budget (prompt_tokens ceiling during a single run)
    static let subagentTurnTokenBudgetKey = "subagent_turn_token_budget"
    static let defaultSubagentTurnTokenBudget = 250000
}

// MARK: - User-defined Service Keys

/// A user-defined API key for an external service (Vercel, Supabase, etc.).
///
/// - `label`: the user-friendly name they typed ("Vercel Token", "Supabase", …).
/// - `name`:  normalized internal key derived from label at creation time
///            ("VERCEL_TOKEN", "SUPABASE"). Used for Keychain storage and fallback
///            global env vars (`BRIGLIA_KEY_VERCEL_TOKEN`).
/// - `description`: optional extra context.
struct ServiceKey: Identifiable, Equatable, Codable {
    var id: String { name }
    let name: String        // normalized key, e.g. "VERCEL_TOKEN"
    let label: String       // user-friendly name, e.g. "Vercel Token"
    var description: String // optional description

    init(name: String, label: String, description: String) {
        self.name = name
        self.label = label
        self.description = description
    }

    // Backward-compatible decoding: keys saved before the `label` field
    // was added only have `name` + `description`. Fall back to `name`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? name
        description = try container.decode(String.self, forKey: .description)
    }

    /// Derive a safe env-var-style key from an arbitrary user label.
    static func normalizeName(from label: String) -> String {
        label
            .uppercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .unicodeScalars.filter { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57) || $0.value == 95 }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }
}

extension KeychainHelper {
    static let serviceKeyEnvironmentPrefix = "BRIGLIA_KEY_"

    // The legacy "ada." UserDefaults name is deliberate: the key is internal,
    // never user-visible, and survived the Ada→Briglia migration untouched.
    // Renaming it would need a two-process verification protocol for no
    // user-visible gain (hardening plan 2026-09, §H8.3).
    static let serviceKeysMetadataDefaultsKey = "ada.service_keys_metadata"
    static let serviceKeyPrefix = "servicekey_"

    static func serviceKeyEnvironmentName(for name: String) -> String {
        serviceKeyEnvironmentPrefix + name
    }

    /// Load the list of registered service keys (metadata only, no secrets).
    static func loadServiceKeys() -> [ServiceKey] {
        guard let data = UserDefaults.standard.data(forKey: serviceKeysMetadataDefaultsKey),
              let keys = try? JSONDecoder().decode([ServiceKey].self, from: data) else {
            return []
        }
        return keys
    }

    /// Persist the metadata list (names + descriptions) to UserDefaults.
    static func saveServiceKeys(_ keys: [ServiceKey]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        UserDefaults.standard.set(data, forKey: serviceKeysMetadataDefaultsKey)
    }

    /// Read a service key's secret value from the Keychain.
    static func loadServiceKeyValue(name: String) -> String? {
        load(key: serviceKeyPrefix + name)
    }

    /// Store a service key's secret value in the Keychain.
    static func saveServiceKeyValue(name: String, value: String) throws {
        try save(key: serviceKeyPrefix + name, value: value)
    }

    /// Delete a service key's secret from the Keychain.
    static func deleteServiceKeyValue(name: String) {
        try? delete(key: serviceKeyPrefix + name)
    }

    /// Returns all service keys as a dictionary:
    /// `["BRIGLIA_KEY_VERCEL_TOKEN": "sk-...", ...]`.
    /// NOT injected into subprocess environments (only per-command
    /// `service_key_env` mappings are) — this seeds the SecretRedactor so
    /// every stored secret gets scrubbed from tool output.
    static func serviceKeyEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for key in loadServiceKeys() {
            if let value = loadServiceKeyValue(name: key.name), !value.isEmpty {
                env[serviceKeyEnvironmentName(for: key.name)] = value
            }
        }
        return env
    }

    /// Resolve a per-command `service_key_env` mapping.
    ///
    /// Input:  `{"VERCEL_TOKEN": "Vercel Token"}` — maps desired env-var name
    ///         to the friendly label the user gave the key.
    /// Output: `{"VERCEL_TOKEN": "sk-real-secret-..."}` — resolved secrets.
    ///
    /// Unrecognised labels are silently skipped (the agent gets an error in
    /// the tool result via BashTools).
    static func resolveServiceKeyEnv(_ mapping: [String: String]) -> (resolved: [String: String], missing: [String]) {
        let allKeys = loadServiceKeys()
        var resolved: [String: String] = [:]
        var missing: [String] = []
        for (envVar, label) in mapping {
            // Match by label (case-insensitive) first, fall back to internal name.
            let match = allKeys.first { $0.label.lowercased() == label.lowercased() }
                     ?? allKeys.first { $0.name.lowercased() == label.lowercased() }
            if let key = match, let value = loadServiceKeyValue(name: key.name), !value.isEmpty {
                resolved[envVar] = value
            } else {
                missing.append(label)
            }
        }
        return (resolved, missing)
    }

    /// Seed environment for SecretRedactor: label → secret value for every
    /// stored credential tagged `.redact` in `CredentialCatalog` — the service
    /// keys (as BRIGLIA_KEY_<NAME>) and the Telegram bot token. Values shorter
    /// than `HarnessSecretStore.minimumSecretLength` are skipped (they would
    /// match ordinary text) and a value stored under two labels is emitted
    /// once. The provider, search, image, transcription and AgentMail keys are
    /// deliberately NOT here (owner decision, 2026-09-02): the redactor is
    /// hygiene against accidental echo of the token, not a boundary against
    /// the model. NOT an injection map — redaction only.
    static func redactionEnvironment() -> [String: String] {
        var candidates = serviceKeyEnvironment()
        candidates.merge(CredentialCatalog.subscriptionRedactionValues()) { _, oauth in oauth }
        for key in CredentialCatalog.redactedKeys {
            if let value = load(key: key), !value.isEmpty {
                candidates[key] = value
            }
        }
        var seen = Set<String>()
        var env: [String: String] = [:]
        for (label, value) in candidates.sorted(by: { $0.key < $1.key }) {
            guard value.count >= HarnessSecretStore.minimumSecretLength,
                  !seen.contains(value) else { continue }
            seen.insert(value)
            env[label] = value
        }
        return env
    }

    /// All secret values currently stored, for redaction purposes.
    static func allServiceKeySecrets() -> [String: String] {
        var secrets: [String: String] = [:]
        for key in loadServiceKeys() {
            if let value = loadServiceKeyValue(name: key.name), !value.isEmpty {
                secrets[key.name] = value
            }
        }
        return secrets
    }
}

// MARK: - OpenRouter Spend Ledger (UserDefaults-backed)
extension KeychainHelper {
    static let openRouterSpendLedgerDefaultsKey = "openrouter_spend_ledger_v1"
    private static let openRouterSpendLedgerRetentionDays = 500
    static let openRouterSpendLimitBoostDefaultsKey = "openrouter_spend_limit_boost_v1"
    private static let openRouterSpendLimitBoostRetentionMonths = 24

    private struct OpenRouterSpendLedger: Codable {
        var byDay: [String: Double]
    }

    private struct OpenRouterSpendLimitBoostLedger: Codable {
        var dailyByDay: [String: Double]
        var monthlyByMonth: [String: Double]
    }

    static func recordOpenRouterSpend(_ amountUSD: Double, at date: Date = Date()) {
        guard amountUSD.isFinite, amountUSD > 0 else { return }
        var ledger = loadOpenRouterSpendLedger()
        pruneOldSpendEntries(&ledger, referenceDate: date)
        let key = dayKey(for: date)
        ledger.byDay[key, default: 0] += amountUSD
        saveOpenRouterSpendLedger(ledger)
    }

    static func openRouterSpendSnapshot(referenceDate: Date = Date()) -> (today: Double, month: Double) {
        var ledger = loadOpenRouterSpendLedger()
        pruneOldSpendEntries(&ledger, referenceDate: referenceDate)
        saveOpenRouterSpendLedger(ledger)

        let todayKey = dayKey(for: referenceDate)
        let monthPrefix = monthPrefixKey(for: referenceDate)

        let today = ledger.byDay[todayKey] ?? 0
        let month = ledger.byDay
            .filter { $0.key.hasPrefix(monthPrefix) }
            .reduce(0) { $0 + $1.value }

        return (today: max(0, today), month: max(0, month))
    }

    static func addOpenRouterSpendLimitIncrease(
        _ amountUSD: Double,
        applyToDaily: Bool,
        applyToMonthly: Bool,
        at date: Date = Date()
    ) {
        guard amountUSD.isFinite,
              amountUSD > 0,
              applyToDaily || applyToMonthly else { return }

        var ledger = loadOpenRouterSpendLimitBoostLedger()
        pruneOldSpendLimitBoostEntries(&ledger, referenceDate: date)

        if applyToDaily {
            let key = dayKey(for: date)
            ledger.dailyByDay[key, default: 0] += amountUSD
        }

        if applyToMonthly {
            let key = monthKey(for: date)
            ledger.monthlyByMonth[key, default: 0] += amountUSD
        }

        saveOpenRouterSpendLimitBoostLedger(ledger)
    }

    static func openRouterSpendLimitIncreaseSnapshot(referenceDate: Date = Date()) -> (daily: Double, monthly: Double) {
        var ledger = loadOpenRouterSpendLimitBoostLedger()
        pruneOldSpendLimitBoostEntries(&ledger, referenceDate: referenceDate)
        saveOpenRouterSpendLimitBoostLedger(ledger)

        let daily = ledger.dailyByDay[dayKey(for: referenceDate)] ?? 0
        let monthly = ledger.monthlyByMonth[monthKey(for: referenceDate)] ?? 0

        return (daily: max(0, daily), monthly: max(0, monthly))
    }

    private static func loadOpenRouterSpendLedger() -> OpenRouterSpendLedger {
        guard let data = UserDefaults.standard.data(forKey: openRouterSpendLedgerDefaultsKey),
              let ledger = try? JSONDecoder().decode(OpenRouterSpendLedger.self, from: data) else {
            return OpenRouterSpendLedger(byDay: [:])
        }
        return ledger
    }

    private static func saveOpenRouterSpendLedger(_ ledger: OpenRouterSpendLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        UserDefaults.standard.set(data, forKey: openRouterSpendLedgerDefaultsKey)
    }

    private static func loadOpenRouterSpendLimitBoostLedger() -> OpenRouterSpendLimitBoostLedger {
        guard let data = UserDefaults.standard.data(forKey: openRouterSpendLimitBoostDefaultsKey),
              let ledger = try? JSONDecoder().decode(OpenRouterSpendLimitBoostLedger.self, from: data) else {
            return OpenRouterSpendLimitBoostLedger(dailyByDay: [:], monthlyByMonth: [:])
        }
        return ledger
    }

    private static func saveOpenRouterSpendLimitBoostLedger(_ ledger: OpenRouterSpendLimitBoostLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        UserDefaults.standard.set(data, forKey: openRouterSpendLimitBoostDefaultsKey)
    }

    private static func pruneOldSpendEntries(_ ledger: inout OpenRouterSpendLedger, referenceDate: Date) {
        guard !ledger.byDay.isEmpty else { return }

        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -openRouterSpendLedgerRetentionDays, to: referenceDate) ?? referenceDate
        let cutoffKey = dayKey(for: cutoffDate)

        ledger.byDay = ledger.byDay.filter { day, value in
            day >= cutoffKey && value.isFinite && value > 0
        }
    }

    private static func pruneOldSpendLimitBoostEntries(_ ledger: inout OpenRouterSpendLimitBoostLedger, referenceDate: Date) {
        let calendar = Calendar.current

        if !ledger.dailyByDay.isEmpty {
            let dailyCutoffDate = calendar.date(byAdding: .day, value: -openRouterSpendLedgerRetentionDays, to: referenceDate) ?? referenceDate
            let dailyCutoffKey = dayKey(for: dailyCutoffDate)
            ledger.dailyByDay = ledger.dailyByDay.filter { day, value in
                day >= dailyCutoffKey && value.isFinite && value > 0
            }
        }

        if !ledger.monthlyByMonth.isEmpty {
            let monthlyCutoffDate = calendar.date(byAdding: .month, value: -openRouterSpendLimitBoostRetentionMonths, to: referenceDate) ?? referenceDate
            let monthlyCutoffKey = monthKey(for: monthlyCutoffDate)
            ledger.monthlyByMonth = ledger.monthlyByMonth.filter { month, value in
                month >= monthlyCutoffKey && value.isFinite && value > 0
            }
        }
    }

    private static func dayKey(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func monthPrefixKey(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d-", year, month)
    }

    private static func monthKey(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }
}
