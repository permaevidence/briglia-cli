import Foundation

/// The OpenRouter model picker's presets (owner request 2026-10-18), in the
/// owner's order. A preset with `autoHost` gets that host pinned
/// automatically the first time it is picked without a host decision for
/// that model (plan §4 row 1); a user's own choice always wins.
enum OpenRouterPresets {
    struct Preset: Equatable {
        /// Telegram callback key (`bm1:r:<key>`), immutable.
        let key: String
        let id: String
        let label: String
        let autoHost: String?
        let autoHostName: String?
    }

    static let all: [Preset] = [
        Preset(key: "default", id: ProviderProfiles.openRouterSetupDefaultModel, label: "DeepSeek V4.1 Flash",
               autoHost: "together", autoHostName: "Together"),
        Preset(key: "dsflash1017", id: "deepseek/deepseek-v4.1-flash-1017", label: "DeepSeek V4.1 Flash 1017",
               autoHost: nil, autoHostName: nil),
        Preset(key: "haiku55", id: "anthropic/claude-haiku-5.5", label: "Claude Haiku 5.5",
               autoHost: "google-vertex", autoHostName: "Google Vertex"),
        Preset(key: "luna", id: "openai/gpt-6-luna", label: "GPT-6 Luna",
               autoHost: "openai", autoHostName: "OpenAI"),
        Preset(key: "glm53flash", id: "z-ai/glm-5.3-flash", label: "GLM 5.3 Flash",
               autoHost: "together", autoHostName: "Together"),
    ]

    static func preset(forKey key: String) -> Preset? { all.first { $0.key == key } }
    static func preset(forModel id: String) -> Preset? { all.first { $0.id == id } }
    static func isCatalogModel(_ id: String) -> Bool { preset(forModel: id) != nil }

    /// Display name of a host slug (preset hosts by name, others verbatim).
    static func hostName(_ slug: String) -> String {
        all.first { $0.autoHost == slug }?.autoHostName ?? slug
    }

    /// Host status of one model for the picker, decided from one store
    /// snapshot (plan §7 / §13.4 / §13.6).
    enum HostState: String {
        case autoWillPin = "auto_will_pin"
        case autoPinned = "auto_pinned"
        case autoUnavailable = "auto_unavailable"
        case upgradePending = "upgrade_pending"
        case userHost = "user_host"
        case userAutomatic = "user_automatic"
        case released
        case corrupt
        case unsupported
        case pendingLegacy = "pending_legacy"
        case none
    }

    struct HostStatus: Equatable {
        let state: HostState
        /// Host slugs involved (pinned, or released `was`), possibly empty.
        let hosts: [String]
    }

    static func hostStatus(model: String, store: [String: String], autoFailed: Bool = false) -> HostStatus {
        let preset = preset(forModel: model)
        if let pending = OpenRouterPinMap.pendingLegacy(store), pending.model == model {
            return HostStatus(state: .pendingLegacy, hosts: OpenRouterPinMap.legacySlugs(store))
        }
        let legacy = OpenRouterPinMap.legacySlugs(store)
        if !legacy.isEmpty, OpenRouterPinMap.effectiveORModel(store) == model {
            return HostStatus(state: .userHost, hosts: legacy)
        }
        switch OpenRouterPinMap.state(store) {
        case .corrupt: return HostStatus(state: .corrupt, hosts: [])
        case .unsupported: return HostStatus(state: .unsupported, hosts: [])
        case .absent:
            let inUse = OpenRouterPinMap.effectiveORModel(store) == model && !OpenRouterPinMap.broken(35)
            return HostStatus(state: preset?.autoHost == nil ? .none : inUse ? .autoUnavailable : .autoWillPin,
                              hosts: preset?.autoHost.map { [$0] } ?? [])
        case .valid(let map):
            if let entry = map.models[model] {
                switch entry.by {
                case .preset: return HostStatus(state: .autoPinned, hosts: entry.hosts)
                case .released: return HostStatus(state: .released, hosts: entry.was ?? [])
                case .user, .migrated:
                    return HostStatus(state: entry.hosts.isEmpty ? .userAutomatic : .userHost, hosts: entry.hosts)
                }
            }
            if map.upgrade?.model == model, let host = preset?.autoHost {
                return HostStatus(state: .upgradePending, hosts: [host])
            }
            if let host = preset?.autoHost {
                // The model IN USE with no entry and no pending operation:
                // its auto-pin was attempted on the switch and didn't land
                // (failed or unchecked listing), so it is not applied.
                // Other models: it will be pinned when picked.
                let inUse = OpenRouterPinMap.effectiveORModel(store) == model && !OpenRouterPinMap.broken(35)
                return HostStatus(state: autoFailed || inUse ? .autoUnavailable : .autoWillPin, hosts: [host])
            }
            return HostStatus(state: .none, hosts: [])
        }
    }

    /// One English clause for Telegram/terminal (D4: new text English-only).
    static func hostClause(_ status: HostStatus) -> String {
        let names = status.hosts.map(hostName).joined(separator: ", ")
        switch status.state {
        case .autoWillPin: return "Host: \(names), pinned automatically when picked"
        case .autoPinned: return "Host: \(names) (pinned automatically)"
        case .autoUnavailable: return "Host: chosen by OpenRouter (Briglia's host \(names) not pinned yet; /orprovider default retries)"
        case .upgradePending: return "Host: \(names) will be applied when OpenRouter confirms it"
        case .userHost: return "Host: \(names) (your choice)"
        case .userAutomatic: return "Host: chosen by OpenRouter (your choice)"
        case .released: return "Host: chosen by OpenRouter (\(names) stopped serving this model)"
        case .corrupt, .unsupported: return "Host: saved hosts unreadable (routing automatic until you choose a host)"
        case .pendingLegacy: return "Host: old pin \(names) still in use (choose a host with /orprovider before switching model)"
        case .none: return "Host: chosen by OpenRouter (nothing pinned automatically)"
        }
    }
}
