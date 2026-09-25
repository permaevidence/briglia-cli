import Foundation

/// Named servers (owner request 2026-09-25): any number of OpenAI-compatible
/// servers — a model on this computer or the home network (LM Studio,
/// Ollama, vLLM…) or a hosted provider with its API key — each with a name
/// the user chose, instead of the single "local server" + single "custom
/// endpoint" pair.
///
/// Design: the request path is untouched. The two existing profiles stay
/// the runtime CARRIERS: a keyless server runs through the local profile
/// (`lmstudio_*` slots, llm_provider = lmstudio) and a server with an API
/// key through the custom-endpoint profile (`custom_endpoint_*` slots,
/// copied into `openai_compatible_*` by activation) — exactly the slots and
/// values `ProviderProfiles.activate(.local/.custom)` writes, so every model
/// request stays byte-identical. Each carrier is BOUND to at most one server
/// (`lmstudio_server_id`, `custom_endpoint_server_id`), and a bound carrier's
/// slots are authoritative for that server: every older writer — the setup
/// wizard, setup-api's provider section, Quick Setup, `/model`, `/effort` —
/// keeps writing the carrier slots, and `reconcile` folds those writes back
/// into the bound server's record. Servers that aren't bound live only in
/// the list (`provider_servers`, one JSON value in the secret store — it
/// holds API keys, so it follows the profiles' rules: never in a Mind
/// export, kept by /deleteuserdata, visible to the agent like other keys).
///
/// `reconcile` is also the migration: an install with a configured local
/// server and/or custom endpoint gets one named server per carrier ("Local
/// server", "Custom endpoint"), bound to it, the active selection untouched.
/// It is idempotent and never drops data: a list that doesn't decode is left
/// byte-for-byte alone and every server operation refuses until it is fixed.
enum ProviderServers {
    static let listKey = "provider_servers"
    static let customBindingKey = "custom_endpoint_server_id"
    static let localBindingKey = "lmstudio_server_id"
    static let maxServers = 20
    static let maxNameLength = 40
    static let idPrefix = "srv-"
    /// Names a server can't take: `/provider <name>` would be ambiguous.
    static let reservedNames: Set<String> = Set(ProviderProfiles.Profile.allCases.map(\.rawValue))

    struct Server: Codable, Equatable {
        var id: String
        var name: String
        var baseURL: String
        var apiKey: String?
        var model: String
        /// Keyed servers only (the local carrier takes no effort).
        var effort: String?
        var textOnly: Bool
        /// "responses" or nil (chat completions). Keyed servers only.
        var wireProtocol: String?
        var nativeToolMedia: Bool?

        var keyed: Bool { !(apiKey ?? "").isEmpty }
        /// The profile whose slots run this server.
        var carrier: ProviderProfiles.Profile { keyed ? .custom : .local }
        var responses: Bool { keyed && wireProtocol == ProviderWireProtocol.responses.rawValue }

        var maskedKey: String? {
            guard let raw = apiKey, !raw.isEmpty else { return nil }
            guard raw.count > 10 else { return "•••" }
            return "\(raw.prefix(5))…\(raw.suffix(4))"
        }

        enum CodingKeys: String, CodingKey {
            case id, name, model, effort
            case baseURL = "base_url"
            case apiKey = "api_key"
            case textOnly = "text_only"
            case wireProtocol = "protocol"
            case nativeToolMedia = "native_tool_media"
        }
    }

    enum Failure: Error, Equatable {
        case damaged
        case notFound
        case active
        case full
        case invalid(String)

        var message: String {
            switch self {
            case .damaged: return "The saved server list can't be read (\(ProviderServers.listKey) in secrets.json is damaged). Fix or remove that entry, then try again."
            case .notFound: return "That server doesn't exist (it may have been removed)."
            case .active: return "Briglia is using this server right now. Switch to another one before removing it."
            case .full: return "You can save up to \(ProviderServers.maxServers) servers. Remove one first."
            case .invalid(let why): return why
            }
        }
    }

    /// What a save asks for. `apiKey`: nil = keep the saved key when the
    /// address is unchanged (none otherwise), "" = no key, else the new key.
    struct Input {
        var id: String?
        var name: String
        var baseURL: String
        var apiKey: String?
        var model: String
        var effort: String?
        var textOnly: Bool
        var wireProtocol: String?
        var nativeToolMedia: Bool?
        var activate = false
    }

    // MARK: Pure helpers (over one store snapshot)

    private static func text(_ store: [String: String], _ key: String) -> String? {
        let trimmed = store[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    static func bindingKey(_ carrier: ProviderProfiles.Profile) -> String {
        carrier == .custom ? customBindingKey : localBindingKey
    }

    /// The decoded list; nil when the stored value exists but doesn't decode.
    static func decode(_ store: [String: String]) -> [Server]? {
        guard let raw = store[listKey], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try? JSONDecoder().decode([Server].self, from: Data(raw.utf8))
    }

    static func encode(_ list: [Server]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(list)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// A carrier's slots as a server (no id/name), nil when not configured
    /// (same rule as `ProviderProfiles.isConfigured`).
    static func carrierState(_ carrier: ProviderProfiles.Profile, _ store: [String: String]) -> Server? {
        switch carrier {
        case .local:
            guard let base = text(store, KeychainHelper.lmStudioBaseURLKey),
                  let model = text(store, KeychainHelper.lmStudioModelKey) else { return nil }
            return Server(id: "", name: "", baseURL: base, apiKey: nil, model: model, effort: nil,
                          textOnly: text(store, ProviderProfiles.localTextOnlyKey) == "true",
                          wireProtocol: nil, nativeToolMedia: nil)
        case .custom:
            guard let base = text(store, ProviderProfiles.customBaseURLKey),
                  let key = text(store, ProviderProfiles.customApiKeyKey),
                  let model = text(store, ProviderProfiles.customModelKey) else { return nil }
            let proto = text(store, ProviderProfiles.customProtocolKey)
            let media = text(store, ProviderProfiles.customNativeMediaKey)
            return Server(id: "", name: "", baseURL: base, apiKey: key, model: model,
                          effort: text(store, ProviderProfiles.customReasoningEffortKey),
                          textOnly: text(store, ProviderProfiles.customTextOnlyKey) == "true",
                          wireProtocol: proto == ProviderWireProtocol.responses.rawValue ? proto : nil,
                          nativeToolMedia: media.map { $0 == "true" })
        default:
            return nil
        }
    }

    static func baseKey(_ carrier: ProviderProfiles.Profile) -> String {
        carrier == .custom ? ProviderProfiles.customBaseURLKey : KeychainHelper.lmStudioBaseURLKey
    }

    /// The carrier's slot keys (the set setup-api's remove clears).
    static func carrierKeys(_ carrier: ProviderProfiles.Profile) -> [String] {
        carrier == .custom
            ? [ProviderProfiles.customProtocolKey, ProviderProfiles.customNativeMediaKey, ProviderProfiles.customBaseURLKey,
               ProviderProfiles.customApiKeyKey, ProviderProfiles.customModelKey, ProviderProfiles.customReasoningEffortKey,
               ProviderProfiles.customTextOnlyKey]
            : [KeychainHelper.lmStudioBaseURLKey, KeychainHelper.lmStudioModelKey, ProviderProfiles.localTextOnlyKey]
    }

    static func activeProfileRaw(_ store: [String: String]) -> String? { text(store, ProviderProfiles.activeProfileKey) }

    /// The server Briglia runs on now, nil when the active profile isn't a
    /// carrier (or the carrier isn't bound).
    static func activeServerID(_ store: [String: String]) -> String? {
        guard let raw = activeProfileRaw(store), let profile = ProviderProfiles.Profile(rawValue: raw),
              profile == .local || profile == .custom else { return nil }
        return text(store, bindingKey(profile))
    }

    static func uniqueName(_ base: String, in list: [Server]) -> String {
        let taken = Set(list.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    static func newID(in list: [Server]) -> String {
        let taken = Set(list.map(\.id))
        while true {
            var bytes = [UInt8](repeating: 0, count: 4)
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
            let id = idPrefix + bytes.map { String(format: "%02x", $0) }.joined()
            if !taken.contains(id) { return id }
        }
    }

    /// Fold the carriers into the list (see the type comment). Throws only
    /// `.damaged`, before changing anything.
    static func reconcile(_ store: inout [String: String]) throws {
        guard var list = decode(store) else { throw Failure.damaged }
        var changed = false
        var seen = Set<String>()
        for carrier in [ProviderProfiles.Profile.local, .custom] {
            let key = bindingKey(carrier)
            let state = carrierState(carrier, store)
            if let bound = text(store, key), !seen.contains(bound) {
                seen.insert(bound)
                if let index = list.firstIndex(where: { $0.id == bound }) {
                    if let state {
                        var merged = state
                        merged.id = list[index].id
                        merged.name = list[index].name
                        if merged != list[index] { list[index] = merged; changed = true }
                    } else if text(store, baseKey(carrier)) == nil {
                        // The carrier was cleared (setup-api remove, a wipe of
                        // the profile): the server it held is gone with it.
                        list.remove(at: index)
                        store.removeValue(forKey: key)
                        changed = true
                    }
                } else if var state {
                    state.id = bound
                    state.name = uniqueName(carrier == .custom ? "Custom endpoint" : "Local server", in: list)
                    list.append(state)
                    changed = true
                } else {
                    store.removeValue(forKey: key)
                    changed = true
                }
            } else {
                if text(store, key) != nil { store.removeValue(forKey: key); changed = true }  // same id bound twice
                if var state {
                    state.id = newID(in: list)
                    state.name = uniqueName(carrier == .custom ? "Custom endpoint" : "Local server", in: list)
                    list.append(state)
                    store[key] = state.id
                    seen.insert(state.id)
                    changed = true
                }
            }
        }
        if changed { store[listKey] = encode(list) }
    }

    /// Write a server into its carrier's slots.
    static func writeCarrier(_ server: Server, _ store: inout [String: String]) {
        func set(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { store[key] = value } else { store.removeValue(forKey: key) }
        }
        switch server.carrier {
        case .custom:
            set(ProviderProfiles.customBaseURLKey, server.baseURL)
            set(ProviderProfiles.customApiKeyKey, server.apiKey)
            set(ProviderProfiles.customModelKey, server.model)
            set(ProviderProfiles.customReasoningEffortKey, server.effort)
            set(ProviderProfiles.customTextOnlyKey, server.textOnly ? "true" : "false")
            set(ProviderProfiles.customProtocolKey, server.responses ? ProviderWireProtocol.responses.rawValue : nil)
            set(ProviderProfiles.customNativeMediaKey, server.nativeToolMedia.map { $0 ? "true" : "false" })
        default:
            set(KeychainHelper.lmStudioBaseURLKey, server.baseURL)
            set(KeychainHelper.lmStudioModelKey, server.model)
            set(ProviderProfiles.localTextOnlyKey, server.textOnly ? "true" : "false")
        }
    }

    static func clearCarrier(_ carrier: ProviderProfiles.Profile, _ store: inout [String: String]) {
        for key in carrierKeys(carrier) { store.removeValue(forKey: key) }
        store.removeValue(forKey: bindingKey(carrier))
    }

    /// The runtime-slot writes that make `carrier` the active profile —
    /// the same keys and values `ProviderProfiles.activate(.custom/.local)`
    /// writes from the same stored slots (selftest-pinned), computed from
    /// the store snapshot so the whole switch is one transaction.
    static func activationChanges(_ carrier: ProviderProfiles.Profile, _ store: [String: String]) throws -> [String: String?] {
        var changes: [String: String?] = [:]
        let proto = text(store, ProviderProfiles.customProtocolKey)
        switch carrier {
        case .custom:
            if let proto, ProviderWireProtocol(rawValue: proto) == nil { throw ResponsesFailure.malformed("unsupported explicit custom protocol") }
            guard let base = text(store, ProviderProfiles.customBaseURLKey), let model = text(store, ProviderProfiles.customModelKey),
                  let key = text(store, ProviderProfiles.customApiKeyKey) else { throw Failure.invalid("The server isn't complete (address, key and model are needed).") }
            changes[KeychainHelper.openAICompatibleBaseURLKey] = base
            changes[KeychainHelper.openAICompatibleModelKey] = model
            changes[KeychainHelper.openAICompatibleApiKeyKey] = key
            changes[KeychainHelper.openAICompatibleReasoningEffortKey] = text(store, ProviderProfiles.customReasoningEffortKey)
            changes[KeychainHelper.llmProviderKey] = LLMProvider.openAICompatible.rawValue
        case .local:
            guard text(store, KeychainHelper.lmStudioBaseURLKey) != nil, text(store, KeychainHelper.lmStudioModelKey) != nil else {
                throw Failure.invalid("The server isn't complete (address and model are needed).")
            }
            changes[KeychainHelper.llmProviderKey] = LLMProvider.lmStudio.rawValue
        default:
            throw Failure.invalid("not a server carrier")
        }
        let textOnlyKey = carrier == .custom ? ProviderProfiles.customTextOnlyKey : ProviderProfiles.localTextOnlyKey
        if let stored = text(store, textOnlyKey) {
            changes[KeychainHelper.textOnlyModelEnabledKey] = stored == "true" ? "true" : "false"
        }
        let responses = carrier == .custom && (proto.flatMap(ProviderWireProtocol.init(rawValue:)) ?? .chatCompletions) == .responses
        changes[ProviderProfiles.runtimeProtocolKey] = responses ? "responses" : String?.none
        changes[ProviderProfiles.runtimeNativeMediaKey] = responses ? text(store, ProviderProfiles.customNativeMediaKey) : String?.none
        changes[ProviderProfiles.activeProfileKey] = carrier.rawValue
        return changes
    }

    private static func applyChanges(_ changes: [String: String?], _ store: inout [String: String]) {
        for (key, value) in changes {
            if let value { store[key] = value } else { store.removeValue(forKey: key) }
        }
    }

    // MARK: Validation

    /// A usable base URL: http(s), a host, no credentials, query or
    /// fragment; trailing slashes dropped; "http://" added when missing.
    static func normalizeBase(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500, !text.contains(where: { $0.isNewline || $0 == " " }) else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return text
    }

    /// Whether an API key may be sent to this address: always over https,
    /// and over plain http only to this computer or a private network, so a
    /// key never crosses the internet unencrypted.
    static func keySafe(_ base: String) -> Bool {
        guard let url = URL(string: base), let host = url.host?.lowercased() else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// nil when `raw` is a good name for a server not called `excluding`.
    static func nameProblem(_ raw: String, in list: [Server], excluding id: String?) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the server a name." }
        if name.count > maxNameLength { return "Keep the name under \(maxNameLength + 1) characters." }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) { return "The name can't contain line breaks." }
        if reservedNames.contains(name.lowercased()) || name.lowercased().hasPrefix(idPrefix) { return "“\(name)” is reserved. Choose another name." }
        if list.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) { return "You already have a server called “\(name)”." }
        return nil
    }

    // MARK: Operations (pure over a store, then wrapped in a transaction)

    static func save(_ input: Input, in store: inout [String: String]) throws -> Server {
        try reconcile(&store)
        guard var list = decode(store) else { throw Failure.damaged }
        guard let base = normalizeBase(input.baseURL) else { throw Failure.invalid("That address doesn’t look right. It looks like http://localhost:1234/v1.") }
        let model = input.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 300, !model.contains(where: { $0.isWhitespace }) else { throw Failure.invalid("Choose a model.") }
        let existingIndex = input.id.flatMap { id in list.firstIndex { $0.id == id } }
        if input.id != nil && existingIndex == nil { throw Failure.notFound }
        if existingIndex == nil && list.count >= maxServers { throw Failure.full }
        if let why = nameProblem(input.name, in: list, excluding: input.id) { throw Failure.invalid(why) }
        let existing = existingIndex.map { list[$0] }
        let key: String?
        if let typed = input.apiKey {
            key = typed.isEmpty ? nil : typed
        } else {
            key = existing.flatMap { $0.baseURL == base ? $0.apiKey : nil }
        }
        if let key {
            guard key.count <= 4096, !key.contains(where: { $0.isNewline }) else { throw Failure.invalid("That key doesn’t look right.") }
            guard keySafe(base) else { throw Failure.invalid("To send an API key, the address must start with https:// (plain http only works for this computer or your home network).") }
        }
        var server = Server(id: existing?.id ?? newID(in: list), name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
                            baseURL: base, apiKey: key, model: model, effort: nil, textOnly: input.textOnly,
                            wireProtocol: nil, nativeToolMedia: nil)
        if server.keyed {
            let effort = (input.effort ?? existing?.effort ?? "high").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !effort.isEmpty, effort.count <= 20, effort.allSatisfy({ $0.isLetter }) else { throw Failure.invalid("Unknown thinking level.") }
            server.effort = effort
            let proto = input.wireProtocol ?? (existing?.keyed == true ? existing?.wireProtocol : nil)
            if let proto, proto != ProviderWireProtocol.responses.rawValue, proto != ProviderWireProtocol.chatCompletions.rawValue {
                throw Failure.invalid("protocol must be chatCompletions|responses")
            }
            server.wireProtocol = proto == ProviderWireProtocol.responses.rawValue ? proto : nil
            server.nativeToolMedia = server.responses ? (input.nativeToolMedia ?? existing?.nativeToolMedia) : nil
        }
        let wasActive = existing != nil && activeServerID(store) == server.id
        let boundTo = [ProviderProfiles.Profile.local, .custom].first { text(store, bindingKey($0)) == server.id }
        if let index = existingIndex { list[index] = server } else { list.append(server) }
        store[listKey] = encode(list)
        if wasActive || input.activate {
            try place(server, boundTo: boundTo, in: &store)
            applyChanges(try activationChanges(server.carrier, store), &store)
        } else if let boundTo {
            if boundTo == server.carrier { writeCarrier(server, &store) } else { clearCarrier(boundTo, &store) }
        }
        return server
    }

    /// Make `server`'s carrier hold it (the server it displaces keeps its
    /// record: `reconcile` already folded the carrier into it).
    private static func place(_ server: Server, boundTo: ProviderProfiles.Profile?, in store: inout [String: String]) throws {
        if let boundTo, boundTo != server.carrier { clearCarrier(boundTo, &store) }
        writeCarrier(server, &store)
        store[bindingKey(server.carrier)] = server.id
    }

    static func use(_ id: String, in store: inout [String: String]) throws -> Server {
        try reconcile(&store)
        guard let list = decode(store) else { throw Failure.damaged }
        guard let server = list.first(where: { $0.id == id }) else { throw Failure.notFound }
        let boundTo = [ProviderProfiles.Profile.local, .custom].first { text(store, bindingKey($0)) == id }
        try place(server, boundTo: boundTo, in: &store)
        applyChanges(try activationChanges(server.carrier, store), &store)
        return server
    }

    static func remove(_ id: String, in store: inout [String: String]) throws {
        try reconcile(&store)
        guard var list = decode(store) else { throw Failure.damaged }
        guard let index = list.firstIndex(where: { $0.id == id }) else { throw Failure.notFound }
        guard activeServerID(store) != id else { throw Failure.active }
        for carrier in [ProviderProfiles.Profile.local, .custom] where text(store, bindingKey(carrier)) == id {
            clearCarrier(carrier, &store)
        }
        list.remove(at: index)
        store[listKey] = encode(list)
    }

    // MARK: Stored API

    private static func transact<T>(_ body: (inout [String: String]) throws -> T) throws -> T {
        var result: T?
        try KeychainHelper.transaction { store in result = try body(&store) }
        guard let result else { throw Failure.invalid("internal: no result") }
        return result
    }

    /// Migration + sync, writing only when something changed. Silent on a
    /// damaged list (doctor reports it; operations refuse).
    static func reconcileStored() {
        let snapshot = KeychainHelper.loadSnapshot()
        var copy = snapshot
        guard (try? reconcile(&copy)) != nil, copy != snapshot else { return }
        do { try KeychainHelper.transaction { try reconcile(&$0) } } catch {
            FileHandle.standardError.write(Data("⚠ named-server sync failed: \(error.localizedDescription)\n".utf8))
        }
    }

    @discardableResult static func save(_ input: Input) throws -> Server { try transact { try save(input, in: &$0) } }
    @discardableResult static func use(_ id: String) throws -> Server { try transact { try use(id, in: &$0) } }
    static func remove(_ id: String) throws { try transact { try remove(id, in: &$0) } }

    /// The current list (carriers folded in, nothing written); nil when the
    /// stored list is damaged.
    static func list(_ store: [String: String] = KeychainHelper.loadSnapshot()) -> [Server]? {
        var copy = store
        guard (try? reconcile(&copy)) != nil else { return nil }
        return decode(copy)
    }

    static func activeServer(_ store: [String: String] = KeychainHelper.loadSnapshot()) -> Server? {
        var copy = store
        guard (try? reconcile(&copy)) != nil, let id = activeServerID(copy) else { return nil }
        return decode(copy)?.first { $0.id == id }
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        return error.localizedDescription
    }

    // MARK: /provider

    /// What a `/provider <argument>` names: a built-in profile, or a server
    /// (by id — the buttons — or by its name, case-insensitive). The legacy
    /// `custom` / `local` names stay profiles: they switch to the server
    /// their carrier holds.
    enum Target: Equatable {
        case profile(ProviderProfiles.Profile)
        case server(String)
    }

    static func resolve(_ argument: String, store: [String: String] = KeychainHelper.loadSnapshot()) -> Target? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let servers = list(store) ?? []
        if lower.hasPrefix(idPrefix), let server = servers.first(where: { $0.id == lower }) { return .server(server.id) }
        if let profile = ProviderProfiles.Profile(rawValue: lower) { return .profile(profile) }
        if let server = servers.first(where: { $0.name.lowercased() == lower }) { return .server(server.id) }
        return nil
    }

    /// A `/provider` button naming a server that no longer exists.
    static func staleProviderTap(_ value: String, store: [String: String] = KeychainHelper.loadSnapshot()) -> String? {
        guard value.hasPrefix(idPrefix) else { return nil }
        guard let servers = list(store) else { return "the saved server list can't be read. Send /provider again." }
        return servers.contains { $0.id == value } ? nil
            : "this menu is outdated: that server was removed. Send /provider again."
    }

    /// One status line per server (for /provider and the wizard summary).
    static func statusLines(_ store: [String: String] = KeychainHelper.loadSnapshot()) -> [String] {
        guard let servers = list(store) else { return ["• servers — the saved list can't be read (\(listKey) is damaged)"] }
        var copy = store
        try? reconcile(&copy)
        let active = activeServerID(copy)
        return servers.map { server in
            var line = "• \(server.name) [server]"
            if server.id == active { line += " — ACTIVE" }
            var parts = [server.model, "@ \(server.baseURL)"]
            if let masked = server.maskedKey { parts.append("key \(masked)") }
            if let effort = server.effort { parts.append("effort \(effort)") }
            if server.responses { parts.append("Responses API") }
            parts.append(server.textOnly ? "text-only (OCR preprocessing)" : "vision")
            return line + " — " + parts.joined(separator: ", ")
        }
    }
}
