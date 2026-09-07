import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One section per request. Stored credentials stay server-side and are part
/// of the verification digest, so a stale probe can never authorize a new key.
@MainActor
final class BrowserSettingsWorkflow {
    struct Environment {
        var probe: ([String: Any]) async -> [String: Any] = { await SetupAPICore.probe($0) }
        var apply: ([String: Any], () throws -> Void) async -> [String: Any] = {
            await SetupAPICore.apply($0, ownsLease: true, checkpoint: $1)
        }
        var subscription: ([String: Any], () throws -> Void) async -> [String: Any] = {
            await SubscriptionSetup().perform($0, ownsLease: true, checkpoint: $1)
        }
        var beginMutation: () async -> Bool = { true }
        var endMutation: () -> Void = {}
        var reload: () async -> Void = {}
        var running = false
    }
    let auth: QuickSetupWorkflow
    var env: Environment
    private var busy = false
    private var receipt: (digest: Data, generation: Int, time: Date)?
    private var pending: String?
    init(auth: QuickSetupWorkflow, env: Environment = Environment()) { self.auth = auth; self.env = env }
    private func failure(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }
    func handle(_ verb: String, body: [String: Any], generation g: Int) async -> (Int, [String: Any]) {
        do { try await auth.beginSettingsOperation(g) } catch { return (404, [:]) }
        let result: (Int, [String: Any])
        do { result = try await perform(verb, body: body, generation: g) }
        catch is QuickSetupWorkflow.Superseded { result = (404, [:]) }
        catch is SetupAPICore.CheckpointRevoked { result = (404, [:]) }
        catch { result = (400, failure("invalid_request", error.localizedDescription)) }
        await auth.endSettingsOperation()
        return result
    }
    private func perform(_ verb: String, body: [String: Any], generation g: Int) async throws -> (Int, [String: Any]) {
        try auth.checkpointSync(g)
        if verb == "status" { return (200, status()) }
        guard !busy else { return (409, failure("busy", "Another settings operation is running. Retry shortly.")) }
        busy = true; defer { busy = false }
        let checkpoint = { try self.auth.checkpointSync(g); try Task.checkCancellation() }
        if verb == "subscription" {
            guard let action = body["action"] as? String,
                  ["status", "start", "poll", "cancel", "logout"].contains(action) else {
                return (400, failure("invalid_action", "Unknown account action."))
            }
            if action != "status" {
                guard await env.beginMutation() else { return (409, failure("agent_busy", "Briglia is working. Retry when the current turn and background work finish.")) }
            }
            defer { if action != "status" { env.endMutation() } }
            try checkpoint()
            let result = await env.subscription(body, checkpoint)
            if action == "start", let handle = result["pending"] as? String { pending = handle }
            if ["signed_in", "cancelled", "signed_out"].contains(result["state"] as? String ?? "") { pending = nil }
            try checkpoint()
            if action != "status" { receipt = nil }
            return (result["ok"] as? Bool == true ? 200 : 400, result)
        }
        guard verb == "verify" || verb == "save" else { return (404, [:]) }
        let request = try resolve(body)
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let digest = Data(SHA256.hash(data: data))
        if verb == "verify" {
            receipt = nil
            let result: [String: Any]
            if let provider = request["provider"] as? [String: Any], provider["profile"] as? String == "chatgpt" {
                result = await env.subscription(subscriptionRequest(provider, action: "probe"), checkpoint)
            } else if let probe = probeRequest(request) { result = await env.probe(probe) }
            else { result = ["ok": true] }
            try checkpoint()
            guard result["ok"] as? Bool == true else { return (400, result) }
            receipt = (digest, g, Date())
            return (200, ["ok": true, "message": "Verified. Save to apply this section."])
        }
        guard let proof = receipt, proof.digest == digest, proof.generation == g,
              Date().timeIntervalSince(proof.time) < 300 else {
            return (409, failure("not_verified", "This value changed or verification expired. Verify it again before saving."))
        }
        guard await env.beginMutation() else { return (409, failure("agent_busy", "Briglia is working. Retry Save when the current turn and background work finish.")) }
        defer { env.endMutation() }
        try checkpoint()
        let current = try JSONSerialization.data(withJSONObject: resolve(body), options: [.sortedKeys])
        guard Data(SHA256.hash(data: current)) == digest else {
            receipt = nil
            return (409, failure("not_verified", "Stored settings changed. Verify again."))
        }
        receipt = nil
        let result: [String: Any]
        if let provider = request["provider"] as? [String: Any], provider["profile"] as? String == "chatgpt" {
            result = await env.subscription(subscriptionRequest(provider, action: "select"), checkpoint)
        } else { result = await env.apply(request, checkpoint) }
        // A save can commit before revocation. Reload before lifting the gate.
        await env.reload()
        try checkpoint()
        guard result["ok"] as? Bool == true else { return (400, result) }
        return (200, ["ok": true, "message": "Saved. Changes apply to the next message."])
    }
    func cancelPendingLogin() async {
        if let pending {
            _ = await env.subscription(["action": "cancel", "pending": pending], {})
            self.pending = nil
        }
        receipt = nil
    }
    struct Invalid: LocalizedError { let text: String; var errorDescription: String? { text } }
    private func resolve(_ body: [String: Any]) throws -> [String: Any] {
        guard Set(body.keys) == ["section", "values"], let section = body["section"] as? String,
              let values = body["values"] as? [String: Any] else { throw Invalid(text: "Choose one settings section.") }
        func text(_ name: String, fallback: String? = nil, required: Bool = true) throws -> String {
            if let value = values[name], !(value is String) { throw Invalid(text: "Invalid \(name).") }
            let value = ((values[name] as? String) ?? fallback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if required && value.isEmpty && name == "api_key" { throw Invalid(text: "Enter an API key.") }
            guard (!required || !value.isEmpty), value.utf8.count <= 4096,
                  !value.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else { throw Invalid(text: "Invalid \(name).") }
            return value
        }
        func boolean(_ name: String, default defaultValue: Bool) throws -> Bool {
            guard let v = values[name] else { return defaultValue }
            guard let n = v as? NSNumber, String(cString: n.objCType) == "c" else { throw Invalid(text: "\(name) must be a Boolean.") }
            return n.boolValue
        }
        if section == "provider" {
            guard Set(values.keys).isSubset(of: ["profile", "api_key", "base_url", "model", "effort", "text_only", "protocol", "native_tool_media", "activate", "generation"]),
                  let profile = ProviderProfiles.Profile(rawValue: try text("profile")) else { throw Invalid(text: "Unknown provider settings.") }
            let model = try text("model")
            let effort = try text("effort", required: false)
            let wire = try text("protocol", fallback: ProviderProfiles.wireProtocol(profile).rawValue)
            guard let parsedWire = ProviderWireProtocol(rawValue: wire),
                  profile == .custom || parsedWire == ProviderProfiles.wireProtocol(profile) else { throw Invalid(text: "Unsupported provider protocol.") }
            if parsedWire == .responses, !effort.isEmpty, !ResponsesAdapter.allowedEfforts(model: model).contains(effort) {
                throw Invalid(text: "Unsupported reasoning effort for this model.")
            }
            if parsedWire == .chatCompletions, !effort.isEmpty,
               !["none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(effort) {
                throw Invalid(text: "Unsupported reasoning effort.")
            }
            var provider: [String: Any] = ["profile": profile.rawValue, "model": model, "effort": effort,
                "text_only": try boolean("text_only", default: ProviderProfiles.textOnly(profile) ?? true),
                "activate": try boolean("activate", default: ProviderProfiles.activeProfile() == nil || ProviderProfiles.activeProfile() == profile)]
            // Updating the active profile must also update its runtime slots.
            if ProviderProfiles.activeProfile() == profile { provider["activate"] = true }
            if profile == .chatgpt {
                guard !effort.isEmpty else { throw Invalid(text: "Choose a reasoning effort.") }
                provider["generation"] = try text("generation")
            } else {
                if profile != .local { provider["api_key"] = try text("api_key", fallback: Self.key(profile)) }
                if profile == .custom || profile == .local {
                    let base = try text("base_url", fallback: ProviderProfiles.configuredEndpoint(profile))
                    guard let url = URL(string: base), ["https", "http"].contains(url.scheme), url.host != nil,
                          url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else { throw Invalid(text: "Enter an HTTP(S) endpoint without credentials or a query.") }
                    provider["base_url"] = base
                }
                if profile == .custom {
                    provider["protocol"] = wire
                    provider["native_tool_media"] = try boolean("native_tool_media", default: KeychainHelper.load(key: ProviderProfiles.customNativeMediaKey) != "false")
                }
            }
            return ["provider": provider]
        }
        guard ["openai", "serper", "jina"].contains(section), Set(values.keys) == ["api_key"] else { throw Invalid(text: "Unknown settings section or fields.") }
        return [section: ["api_key": try text("api_key")]]
    }
    static func key(_ profile: ProviderProfiles.Profile) -> String? {
        let name: String
        switch profile {
        case .opencode: name = ProviderProfiles.opencodeApiKeyKey
        case .openrouter: name = KeychainHelper.openRouterApiKeyKey
        case .openai: name = ProviderProfiles.openaiApiKeyKey
        case .custom: name = ProviderProfiles.customApiKeyKey
        case .local, .chatgpt: return nil
        }
        return KeychainHelper.load(key: name)
    }
    private func subscriptionRequest(_ provider: [String: Any], action: String) -> [String: Any] {
        var out: [String: Any] = ["action": action, "model": provider["model"]!, "effort": provider["effort"]!, "generation": provider["generation"]!]
        if action == "select" { out["activate"] = provider["activate"] }
        return out
    }
    private func probeRequest(_ request: [String: Any]) -> [String: Any]? {
        if let p = request["provider"] as? [String: Any], let raw = p["profile"] as? String,
           let profile = ProviderProfiles.Profile(rawValue: raw) {
            let wire = p["protocol"] as? String ?? ProviderProfiles.wireProtocol(profile).rawValue
            var result: [String: Any] = ["kind": wire == "responses" ? "responses" : profile == .local ? "local" : "custom", "model": p["model"]!]
            result["base_url"] = p["base_url"] ?? (profile == .opencode ? OpenCodeGo.baseURL : profile == .openrouter ? "https://openrouter.ai/api/v1" : "https://api.openai.com/v1")
            result["api_key"] = p["api_key"]
            return result
        }
        for section in ["openai", "serper", "jina"] {
            if let v = request[section] as? [String: Any] { return ["kind": section, "api_key": v["api_key"]!] }
        }
        return nil
    }
    func status() -> [String: Any] {
        var profiles: [[String: Any]] = []
        for p in ProviderProfiles.Profile.allCases {
            let model = ProviderProfiles.configuredModel(p) ?? (p == .opencode ? OpenCodeGo.defaultModel : p == .openrouter ? "google/gemini-3-flash-preview" : p == .chatgpt || p == .openai ? "gpt-5.6-luna" : "")
            profiles.append(["id": p.rawValue, "label": p.displayName,
                "configured": ProviderProfiles.isConfigured(p), "model": model,
                "effort": ProviderProfiles.configuredEffort(p) ?? (p == .local || (ProviderProfiles.isConfigured(p) && ProviderProfiles.wireProtocol(p) == .responses) ? "" : "high"),
                "endpoint": ProviderProfiles.configuredEndpoint(p) ?? "",
                "text_only": ProviderProfiles.textOnly(p) ?? !(p == .chatgpt || p == .openai),
                "protocol": ProviderProfiles.wireProtocol(p).rawValue,
                "native_tool_media": p == .custom && KeychainHelper.load(key: ProviderProfiles.customNativeMediaKey) != "false",
                "has_key": Self.key(p)?.isEmpty == false])
        }
        let tools: [[String: Any]] = [("openai", "OpenAI tools", KeychainHelper.openAITranscriptionApiKeyKey),
            ("serper", "Serper", KeychainHelper.serperApiKeyKey), ("jina", "Jina", KeychainHelper.jinaApiKeyKey)].map {
                ["id": $0.0, "label": $0.1, "configured": KeychainHelper.load(key: $0.2)?.isEmpty == false]
            }
        return ["ok": true, "mode": "settings", "profiles": profiles, "tools": tools,
            "active": ProviderProfiles.activeProfile()?.rawValue ?? "", "busy": busy, "running": env.running,
            "opencode_models": OpenCodeGo.choices.map { ["id": $0.id, "label": $0.label] }]
    }
}
