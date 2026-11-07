import Foundation

/// Writing an assistant's ChatGPT selection on the SIWC route (SIWC plan
/// §3.8 "Selection keys" and "Older binaries", round-1 R1, round-2 runtime
/// representation, D25). Every function here is a pure description of a
/// secrets delta (nil = delete); the settings writer commits it.
enum SIWCSelection {
    /// This assistant's LEGACY selection keys. An SIWC selection removes them
    /// in the same transaction, so a pre-SIWC binary finds no
    /// `subscription_model` (its `isConfigured(.chatgpt)` is false and its
    /// `activate(.chatgpt)` refuses), in every mode and scope.
    static let legacySelectionKeys: [String] = [
        ProviderProfiles.subscriptionModelKey, ProviderProfiles.subscriptionEffortKey,
        ProviderProfiles.subscriptionTextOnlyKey, ProviderProfiles.subscriptionGenerationKey,
        SubscriptionSharing.accountFingerprintKey,
    ]

    /// The SIWC selection keys (never exported to a Mind, never written by an
    /// import, cleared by `/deleteuserdata` and by both scope directions).
    static let selectionKeys: [String] = [
        ChatGPTRoute.routeKey, ChatGPTRoute.siwcRegistrationKey, ChatGPTRoute.siwcIdentityKey,
        ChatGPTRoute.siwcGenerationKey, ChatGPTRoute.siwcModelKey, ChatGPTRoute.siwcEffortKey,
        ChatGPTRoute.siwcTextOnlyKey,
    ]

    /// One verified, saved login this assistant selects.
    struct Choice: Equatable {
        var clientId: String
        var sub: String
        /// The generation the selection binds to (the record's, or the staged
        /// replacement's `generationToBe` when activation promotes it).
        var generation: String
        var model: String
        var effort: String?
        var textOnly: Bool
    }

    /// The runtime keys of an active SIWC selection. The runtime credential
    /// slot is DELETED (no sentinel) and the runtime endpoint is the SIWC
    /// base, so an older binary's main/auxiliary paths refuse the non-legacy
    /// endpoint before any send, its web lane (non-empty slot required) is
    /// off, and its `profiles add --copy-keys` (overwrites the slot only when
    /// it exists) provisions an extra with no slot.
    static func runtimeDelta(model: String, effort: String?, textOnly: Bool) -> [String: String?] {
        [
            ProviderProfiles.activeProfileKey: ProviderProfiles.Profile.chatgpt.rawValue,
            KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
            KeychainHelper.openAICompatibleBaseURLKey: SIWCEndpoint.apiBase,
            KeychainHelper.openAICompatibleModelKey: model,
            KeychainHelper.openAICompatibleReasoningEffortKey: effort,
            KeychainHelper.openAICompatibleApiKeyKey: String?.none,
            ProviderProfiles.runtimeProtocolKey: "responses",
            ProviderProfiles.runtimeNativeMediaKey: "false",
            KeychainHelper.textOnlyModelEnabledKey: textOnly ? "true" : "false",
        ]
    }

    /// Selecting `choice` on the SIWC route, as this assistant's active
    /// provider: the SIWC selection keys, the runtime keys, and the removal
    /// of this assistant's legacy selection keys — ONE secrets transaction.
    static func activationDelta(_ choice: Choice) -> [String: String?] {
        var delta = runtimeDelta(model: choice.model, effort: choice.effort, textOnly: choice.textOnly)
        delta[ChatGPTRoute.routeKey] = "siwc"
        delta[ChatGPTRoute.siwcRegistrationKey] = SIWCEndpoint.registrationFingerprint(clientId: choice.clientId)
        delta[ChatGPTRoute.siwcIdentityKey] = SIWCEndpoint.identityFingerprint(clientId: choice.clientId, sub: choice.sub)
        delta[ChatGPTRoute.siwcGenerationKey] = choice.generation
        delta[ChatGPTRoute.siwcModelKey] = choice.model
        delta[ChatGPTRoute.siwcEffortKey] = choice.effort
        delta[ChatGPTRoute.siwcTextOnlyKey] = choice.textOnly ? "true" : "false"
        for key in legacySelectionKeys { delta[key] = String?.none }
        return delta
    }

    /// Removing every SIWC selection key (route absent = legacy). Used by the
    /// explicit legacy selection, by both scope directions and by the wipe.
    /// When this assistant's ACTIVE runtime is the SIWC endpoint, the runtime
    /// endpoint is cleared too, so nothing is left pointing ChatGPT at a
    /// route it no longer selects.
    static func clearDelta(stored: [String: String]) -> [String: String?] {
        var delta: [String: String?] = [:]
        for key in selectionKeys where stored[key] != nil { delta[key] = String?.none }
        if stored[ProviderProfiles.activeProfileKey] == ProviderProfiles.Profile.chatgpt.rawValue,
           stored[KeychainHelper.openAICompatibleBaseURLKey] == SIWCEndpoint.apiBase,
           stored[ChatGPTRoute.routeKey] == "siwc" {
            delta[KeychainHelper.openAICompatibleBaseURLKey] = String?.none
            delta[KeychainHelper.openAICompatibleApiKeyKey] = String?.none
        }
        return delta
    }

    /// Re-activating ChatGPT (after another provider was used) when this
    /// assistant's saved ChatGPT selection is on the SIWC route: only the
    /// runtime keys, from the saved SIWC choices. nil when the saved
    /// selection is not a complete SIWC selection (the caller then says
    /// "choose ChatGPT again").
    static func reactivationDelta(stored: [String: String]) -> [String: String?]? {
        guard stored[ChatGPTRoute.routeKey] == "siwc", stored[ProviderProfiles.subscriptionGenerationKey] == nil,
              let model = stored[ChatGPTRoute.siwcModelKey], !model.isEmpty,
              stored[ChatGPTRoute.siwcRegistrationKey] != nil, stored[ChatGPTRoute.siwcIdentityKey] != nil,
              stored[ChatGPTRoute.siwcGenerationKey] != nil else { return nil }
        return runtimeDelta(model: model, effort: stored[ChatGPTRoute.siwcEffortKey],
                            textOnly: stored[ChatGPTRoute.siwcTextOnlyKey] == "true")
    }

    /// The SIWC selection keys (plus the legacy generation key, whose
    /// presence makes a selection ambiguous) read one by one through `load`.
    static func selectionSnapshot(load: (String) -> String?) -> [String: String] {
        var out: [String: String] = [:]
        for key in selectionKeys + [ProviderProfiles.subscriptionGenerationKey] { if let v = load(key) { out[key] = v } }
        return out
    }

    /// The new binary's `isConfigured(.chatgpt)` on the SIWC route: a complete
    /// selection whose registration is the store's active one with the same
    /// verified identity and a usable record (its generation, or a newer one
    /// of the same registration that the next operation rebinds to).
    static func isConfigured(_ selection: [String: String], store: SIWCStore = .resolved()) -> Bool {
        guard reactivationDelta(stored: selection) != nil,
              let registrations = try? store.readRegistrations(), let active = registrations.active,
              let registration = registrations.registration(active),
              selection[ChatGPTRoute.siwcRegistrationKey] == SIWCEndpoint.registrationFingerprint(clientId: active),
              selection[ChatGPTRoute.siwcIdentityKey] == SIWCEndpoint.identityFingerprint(clientId: active, sub: registration.sub),
              let file = try? store.readTokens(), let record = file.record(active) else { return false }
        return store.usability(record, registration: registration, key: try? store.integrityKey(create: false)) == .usable
    }

    /// Whether this assistant's saved ChatGPT selection is on the SIWC route.
    static func selectsSIWC(_ stored: [String: String]) -> Bool { stored[ChatGPTRoute.routeKey] == "siwc" }

    /// `profiles add --copy-keys` from a default on the SIWC route (§3.8
    /// "Adding an assistant"): the route and the SIWC selection keys, bound
    /// to the shared store's CURRENT record of the same registration and
    /// verified identity, from one validated read. No token is ever copied.
    /// An unusable login, a different active registration or an incomplete
    /// selection binds nothing (the extra is shared and unbound).
    static func copyForNewExtra(defaultStored: [String: String], machineStore: SIWCStore) -> [String: String] {
        guard case .siwc(let selection) = ChatGPTRoute.resolve(stored: defaultStored),
              let model = defaultStored[ChatGPTRoute.siwcModelKey], !model.isEmpty,
              let registrations = try? machineStore.readRegistrations(), let active = registrations.active,
              let registration = registrations.registration(active),
              SIWCEndpoint.registrationFingerprint(clientId: active) == selection.registrationFingerprint,
              SIWCEndpoint.identityFingerprint(clientId: active, sub: registration.sub) == selection.identityFingerprint,
              let file = try? machineStore.readTokens(), let record = file.record(active),
              machineStore.usability(record, registration: registration, key: try? machineStore.integrityKey(create: false)) == .usable,
              file.pendingLogin == nil else { return [:] }
        var out: [String: String] = [:]
        let choice = Choice(clientId: active, sub: registration.sub, generation: record.generation, model: model,
                            effort: defaultStored[ChatGPTRoute.siwcEffortKey],
                            textOnly: defaultStored[ChatGPTRoute.siwcTextOnlyKey] == "true")
        for (key, value) in activationDelta(choice) { if let value { out[key] = value } }
        return out
    }
}

/// Route facts of the SIWC store a route depends on (§3.9 "Route snapshot"):
/// what the request path reads — record present and usable, plan usage, the
/// registration and identity fingerprints, the generation in use, and the
/// store's active registration. Non-secret.
struct SIWCRouteFacts: Equatable {
    var present: Bool
    var usable: Bool
    var planUsage: Bool
    var registrationFingerprint: String?
    var identityFingerprint: String?
    var generation: String?
    var activeRegistration: String?

    static let absent = SIWCRouteFacts(present: false, usable: false, planUsage: false)

    init(present: Bool, usable: Bool, planUsage: Bool, registrationFingerprint: String? = nil,
         identityFingerprint: String? = nil, generation: String? = nil, activeRegistration: String? = nil) {
        self.present = present; self.usable = usable; self.planUsage = planUsage
        self.registrationFingerprint = registrationFingerprint; self.identityFingerprint = identityFingerprint
        self.generation = generation; self.activeRegistration = activeRegistration
    }

    /// The facts of `clientId` in one read of a store (nil = no record).
    init(tokens: SIWCTokenFile?, registrations: SIWCRegistrationsFile?, clientId: String?, store: SIWCStore) {
        guard let clientId, let record = tokens?.record(clientId) else {
            self = .absent
            self.activeRegistration = registrations?.active.map { SIWCEndpoint.registrationFingerprint(clientId: $0) }
            return
        }
        let registration = registrations?.registration(clientId)
        let usability = store.usability(record, registration: registration, key: try? store.integrityKey(create: false))
        self.init(present: true, usable: usability == .usable, planUsage: record.tokens?.planUsage ?? false,
                  registrationFingerprint: SIWCEndpoint.registrationFingerprint(clientId: clientId),
                  identityFingerprint: registration.map { SIWCEndpoint.identityFingerprint(clientId: clientId, sub: $0.sub) },
                  generation: record.generation,
                  activeRegistration: registrations?.active.map { SIWCEndpoint.registrationFingerprint(clientId: $0) })
    }

    /// The route-input text for `RouteSnapshot` (fingerprints only).
    var snapshotText: String {
        guard present else { return "absent|\(activeRegistration ?? "")" }
        return [usable ? "usable" : "unusable", planUsage ? "plan" : "noplan", registrationFingerprint ?? "",
                identityFingerprint ?? "", generation ?? "", activeRegistration ?? ""].joined(separator: "|")
    }
}
