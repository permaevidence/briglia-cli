import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// User-configured "cheap model" lanes for subagent runs.
///
/// The main agent never picks concrete model IDs for subagents — it picks an
/// INTENT: inherit the parent model, or route to one of (at most) two cheap
/// lanes the user configured with /subagentmodels. Lanes are stored PER
/// PROVIDER, so switching the main provider (OpenRouter ↔ OpenCode ↔ local)
/// swaps in that provider's own picks and a lane can never point across
/// gateways: the override only ever replaces the model string on the same
/// endpoint with the same key.
///
/// Lane semantics double as the vision decision — no per-model capability
/// database needed:
///   - cheap-vision: the user picked a vision-capable model; images flow
///     natively in that run.
///   - cheap-text: text-only by definition; any multimodal content in the
///     run goes through the OCR preprocessor regardless of the global
///     text-only flag (which describes the MAIN model, not this run's).
enum SubagentModelLane: String, CaseIterable {
    case cheapVision = "cheap-vision"
    case cheapText = "cheap-text"

    /// Whether runs on this lane must treat the model as text-only.
    var isTextOnly: Bool { self == .cheapText }

    /// Human label for command output.
    var displayName: String {
        switch self {
        case .cheapVision: return "cheap vision"
        case .cheapText: return "cheap text-only"
        }
    }
}

enum SubagentModelLanes {

    /// The provider whose lane configuration is active — always the main
    /// agent's current provider, resolved per call so /llm switches take
    /// effect immediately.
    static func activeProvider() -> LLMProvider {
        LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey))
    }

    /// Storage key for one lane under one provider (lives in secrets.json
    /// alongside the other KeychainHelper-managed settings).
    ///
    /// Both custom-endpoint provider slots additionally namespace by the
    /// FULL configured endpoint: "OpenAI-compatible" is one slot but many
    /// gateways (OpenCode Go, a corporate proxy, an ssh tunnel on a local
    /// port…), and "Local Inference" is any local runtime (LM Studio,
    /// Ollama, vLLM — often distinguished only by port). A lane model valid
    /// on one endpoint is gibberish on another, so changing the base URL —
    /// including just the port or path — must not carry lane picks across.
    static func storageKey(_ lane: SubagentModelLane, provider: LLMProvider) -> String {
        let laneSlug = lane.rawValue.replacingOccurrences(of: "-", with: "_")
        var key = "subagent_\(laneSlug)_model_\(provider.rawValue)"
        if provider.isCustomEndpoint {
            key += "_\(endpointNamespace(provider: provider))"
        }
        return key
    }

    /// Namespace slug for a custom provider's configured endpoint:
    /// "<host>-<8-hex sha256 of the normalized full URL>", or "default" when
    /// unset. The host keeps the key human-readable in secrets.json; the
    /// hash makes different ports/paths on the same host distinct.
    /// Normalization lowercases only the scheme and host (case-insensitive
    /// by spec) — the path keeps its case, so two endpoints differing only
    /// by path case stay distinct.
    static func endpointNamespace(provider: LLMProvider) -> String {
        let urlKey = provider == .lmStudio
            ? KeychainHelper.lmStudioBaseURLKey
            : KeychainHelper.openAICompatibleBaseURLKey
        var raw = (KeychainHelper.load(key: urlKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw = String(raw.dropLast()) }
        guard !raw.isEmpty else { return "default" }
        let normalized: String
        let host: String
        if let url = URL(string: raw), let urlHost = url.host {
            host = urlHost.lowercased()
            let scheme = (url.scheme ?? "https").lowercased()
            let port = url.port.map { ":\($0)" } ?? ""
            normalized = "\(scheme)://\(host)\(port)\(url.path)"
        } else {
            host = "endpoint"
            normalized = raw
        }
        let sanitizedHost = String(host.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "." || ch == "-") ? ch : "_"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let hash8 = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(sanitizedHost.isEmpty ? "endpoint" : String(sanitizedHost.prefix(48)))-\(hash8)"
    }

    /// The model stored for `lane` under `provider`, ignoring the host-pin
    /// bypass — for display (/subagentmodels) only; routing decisions use
    /// `configuredModel`.
    static func storedModel(_ lane: SubagentModelLane, provider: LLMProvider? = nil) -> String? {
        let p = provider ?? activeProvider()
        guard let stored = KeychainHelper.load(key: storageKey(lane, provider: p))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !stored.isEmpty else { return nil }
        return stored
    }

    /// While an `/orprovider` host pin is set on the OpenRouter provider,
    /// the lanes are bypassed: every subagent runs on exactly the main
    /// model, on the pinned host (owner decision 2026-09-19 — someone who
    /// pinned a host wants its characteristics for the subagents too, and
    /// a pin validated for the main model must not be applied to a lane
    /// model the host may not serve). The picks stay stored and return
    /// when the pin is released. OpenCode/custom/local lane picks are
    /// never affected: the pin does not apply to those providers.
    static func hostPinBypass(provider: LLMProvider? = nil) -> Bool {
        (provider ?? activeProvider()) == .openRouter && OpenRouterProviderPin.isPinned
    }

    /// The configured model for `lane` under the active provider, or nil —
    /// also nil while the lanes are bypassed by a host pin (see
    /// `hostPinBypass`), so the Agent schema offers only 'inherit', a
    /// custom agent's frontmatter lane degrades to inherit, and a stored
    /// watcher lane runs inherit.
    static func configuredModel(_ lane: SubagentModelLane, provider: LLMProvider? = nil) -> String? {
        let p = provider ?? activeProvider()
        if hostPinBypass(provider: p) { return nil }
        return storedModel(lane, provider: p)
    }

    /// Set (non-empty) or clear (nil/empty) a lane for the active provider.
    static func setModel(_ lane: SubagentModelLane, model: String?, provider: LLMProvider? = nil) throws {
        let p = provider ?? activeProvider()
        let key = storageKey(lane, provider: p)
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try KeychainHelper.delete(key: key)
        } else {
            try KeychainHelper.save(key: key, value: trimmed)
        }
    }

    /// All lanes currently configured for the active provider, in stable order.
    static func configuredLanes(provider: LLMProvider? = nil) -> [(lane: SubagentModelLane, model: String)] {
        let p = provider ?? activeProvider()
        return SubagentModelLane.allCases.compactMap { lane in
            configuredModel(lane, provider: p).map { (lane, $0) }
        }
    }

    /// Outcome of resolving an Agent-tool `model` hint against the active
    /// provider's lane configuration.
    enum Resolution: Equatable {
        /// nil / "" / "inherit" — no lane requested by this hint. The caller
        /// falls through to its next precedence level: a custom agent's
        /// frontmatter lane if one is declared, otherwise the parent model.
        case inherit
        /// A configured lane: run on `model`, honoring the lane's text-only
        /// semantics.
        case lane(SubagentModelLane, model: String)
        /// A valid lane name whose model the user has not configured for the
        /// active provider. Callers surfacing this to the main agent must
        /// fail LOUDLY (point at /subagentmodels), never fall back silently.
        case unconfigured(SubagentModelLane)
        /// Not a lane name at all (includes the retired sonnet/opus/haiku
        /// hints). Same loud-failure contract as `unconfigured`.
        case unknown(String)
    }

    static func resolve(hint: String?) -> Resolution {
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty,
              raw != "inherit" else {
            return .inherit
        }
        guard let lane = SubagentModelLane(rawValue: raw) else {
            return .unknown(raw)
        }
        // A lane hint that arrives while the lanes are bypassed by a host
        // pin (a watcher's stored triage_model, a custom agent's frontmatter,
        // a stale schema) runs the main model — quietly, not as the loud
        // "not configured" refusal, which would point the agent at
        // /subagentmodels for a setting the user deliberately overrode.
        if hostPinBypass() { return .inherit }
        guard let model = configuredModel(lane) else {
            return .unconfigured(lane)
        }
        return .lane(lane, model: model)
    }
}
