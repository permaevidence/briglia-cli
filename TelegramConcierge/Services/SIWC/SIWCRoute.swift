import Foundation

/// The authoritative credential source of an SIWC operation (§4.1): captured
/// once per operation and carried through rounds, retries, refresh,
/// `requireLogin` and compaction, with the resolved store directory (§3.8).
struct SIWCCredentialSource: Equatable {
    let storeDirectory: URL
    let clientId: String
    let generation: String
    /// This process's revocation epoch for the registration at capture time.
    let epoch: Int
    /// `SIWCEndpoint.identityFingerprint(client, sub)`: replay scope, cache
    /// key and `session_id` derive from it, never from the legacy salt.
    let identityFingerprint: String

    var fenceKey: String { SIWCFence.key(store: storeDirectory, clientId: clientId) }
    var store: SIWCStore { SIWCStore(directory: storeDirectory) }
    /// The affinity key (`SessionAffinity.wireId` input) of this registration.
    var affinityKey: String { "briglia-siwc-v1:" + identityFingerprint }
}

/// The ChatGPT route of this assistant (§3.8 selection keys, §5 kill switch).
/// Read-only in stage B: stage C's settings writer is the only writer.
enum ChatGPTRoute {
    static let routeKey = "subscription_route"
    static let siwcRegistrationKey = "subscription_siwc_registration_fp"
    static let siwcIdentityKey = "subscription_siwc_identity_fp"
    static let siwcGenerationKey = "subscription_siwc_generation"
    static let siwcModelKey = "subscription_siwc_model"
    static let siwcEffortKey = "subscription_siwc_effort"
    static let siwcTextOnlyKey = "subscription_siwc_text_only"

    struct Selection: Equatable {
        let registrationFingerprint: String
        let identityFingerprint: String
        let generation: String
    }

    enum Resolved: Equatable {
        case notChatGPT
        /// Today's route, untouched.
        case legacy
        case siwc(Selection)
        /// Both routes' bindings, or a runtime endpoint/slot that does not
        /// match the route (an older binary wrote legacy keys meanwhile, D25):
        /// nothing is sent on either route.
        case ambiguous
        case disabled
    }

    static let chooseAgainMessage = "Choose ChatGPT again: this assistant's ChatGPT selection is incomplete or was changed by an older Briglia. Nothing was sent. (/provider chatgpt)"

    /// Whether this assistant's ChatGPT route is Sign in with ChatGPT. Such a
    /// selection deliberately has NO runtime credential slot (older-binary
    /// guard, D25): its credential lives in the SIWC store and is checked per
    /// request, so startup and configuration checks must not require the
    /// OpenAI-compatible key. An incomplete or disabled SIWC selection also
    /// counts: it starts, and every request reports the specific reason.
    static func isSIWCSelected(stored: [String: String]) -> Bool {
        stored[ProviderProfiles.activeProfileKey] == ProviderProfiles.Profile.chatgpt.rawValue && stored[routeKey] == "siwc"
    }

    /// Pure rule over one secrets snapshot.
    static func resolve(stored: [String: String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Resolved {
        guard stored[ProviderProfiles.activeProfileKey] == ProviderProfiles.Profile.chatgpt.rawValue else { return .notChatGPT }
        guard stored[routeKey] == "siwc" else { return .legacy }
        if SIWCEndpoint.disabledByEnvironment(environment) { return .disabled }
        let slot = (stored[KeychainHelper.openAICompatibleApiKeyKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored[ProviderProfiles.subscriptionGenerationKey] == nil, slot.isEmpty,
              stored[KeychainHelper.openAICompatibleBaseURLKey] == SIWCEndpoint.apiBase,
              let registration = stored[siwcRegistrationKey], SIWCStore.wellFormedMAC(registration),
              let identity = stored[siwcIdentityKey], SIWCStore.wellFormedMAC(identity),
              let generation = stored[siwcGenerationKey], UUID(uuidString: generation) != nil else { return .ambiguous }
        return .siwc(Selection(registrationFingerprint: registration, identityFingerprint: identity, generation: generation))
    }

    /// Capture the credential source for one operation: the selection must
    /// name the store's ACTIVE registration (D21) with the same verified
    /// identity, and the bound generation must still be the record's.
    /// Several assistants: a re-sign-in to the same registration is picked up
    /// only by stage C's rebind at operation start; here a changed generation
    /// is refused before any send (captured operations never rebind).
    static func capture(_ selection: Selection, store: SIWCStore, rebind: Bool = true) throws -> SIWCCredentialSource {
        guard let registrations = try store.readRegistrations(), let active = registrations.active,
              let registration = registrations.registration(active) else {
            throw SIWCError(.signInRequired, SIWCError.signInMessage)
        }
        guard SIWCEndpoint.registrationFingerprint(clientId: active) == selection.registrationFingerprint,
              SIWCEndpoint.identityFingerprint(clientId: active, sub: registration.sub) == selection.identityFingerprint else {
            throw SIWCError(.signInRequired, SubscriptionSharing.differentAccountMessage(changedBy: nil))
        }
        // Stage C (§3.8, D21): at the START of an operation, a re-sign-in to
        // the same registration (a new record generation, usable, same
        // verified identity, no pending sign-in) is followed automatically.
        // This is the only place a selection's generation moves on its own;
        // an operation that already captured a source never rebinds.
        var generation = selection.generation
        if rebind, (try? store.readTokens())?.record(active)?.generation != selection.generation {
            generation = try SIWCRebind.rebind(selection, clientId: active, store: store)
        }
        try store.validate(clientId: active, generation: generation)
        let key = SIWCFence.key(store: store.directory, clientId: active)
        return SIWCCredentialSource(storeDirectory: store.directory, clientId: active, generation: generation,
                                    epoch: SIWCFence.shared.epoch(key), identityFingerprint: selection.identityFingerprint)
    }

    /// The source for the selected route of THIS assistant now, or nil when
    /// ChatGPT is not selected on the SIWC route. Throws for an ambiguous or
    /// disabled selection, and when the login is unusable.
    static func currentSource(stored: [String: String] = KeychainHelper.loadSnapshot(),
                              store: SIWCStore = SIWCStore.resolved()) throws -> SIWCCredentialSource? {
        switch resolve(stored: stored) {
        case .notChatGPT, .legacy: return nil
        case .ambiguous: throw SIWCError(.local, chooseAgainMessage)
        case .disabled: throw SIWCError(.disabled, SIWCEndpoint.disabledMessage)
        case .siwc(let selection): return try capture(selection, store: store)
        }
    }
}

/// The ChatGPT route of one multi-request operation that is not carried by a
/// `ProviderExecutionContext` (a raw web run), captured once at its start.
enum SIWCOperationCapture: Equatable {
    case notSIWC
    case source(SIWCCredentialSource)
    case failure(String)

    static func capture(stored: [String: String] = KeychainHelper.loadSnapshot()) -> SIWCOperationCapture {
        switch ChatGPTRoute.resolve(stored: stored) {
        case .notChatGPT, .legacy: return .notSIWC
        case .ambiguous, .disabled, .siwc:
            do {
                guard let source = try ChatGPTRoute.currentSource(stored: stored) else { return .notSIWC }
                return .source(source)
            } catch { return .failure((error as? SIWCError)?.message ?? SIWCError.signInMessage) }
        }
    }
}

extension ProviderExecutionContext {
    /// Whether this operation runs on the ChatGPT plan (legacy or SIWC):
    /// spend gates and usage buckets treat both the same (§4.3).
    var isChatGPTPlan: Bool { subscriptionGeneration != nil || siwc != nil }

    /// An SIWC context. `authorization` is never used (the bearer comes from
    /// the SIWC store per send); `subscriptionGeneration` stays nil so no
    /// legacy path can fire. A context whose source could not be captured
    /// carries a `configurationError` and sends nothing.
    static func siwcContext(source: SIWCCredentialSource?, configurationError: String? = nil, model: String,
                            effort: String?, lane: AffinityLane, textOnly: Bool, nativeToolMedia: Bool) -> ProviderExecutionContext {
        var context = ProviderExecutionContext(provider: .openAICompatible, model: model, endpoint: SIWCEndpoint.apiBase,
            authorization: "", affinityKey: source?.affinityKey ?? "briglia-siwc-v1:unbound", lane: lane,
            provenance: model + "#responses", providerPreferences: nil, reasoning: nil, reasoningEffort: effort,
            thinkingType: nil, useReasoningContent: false, textOnly: textOnly, anthropicCacheControl: false,
            renderPDFAsImages: true, wireProtocol: .responses, profileIdentity: ProviderProfiles.Profile.chatgpt.rawValue,
            nativeToolMedia: nativeToolMedia, configurationError: configurationError ?? (source == nil ? "ChatGPT sign-in is not available" : nil))
        context.siwc = source
        if source == nil { context.siwcFailure = configurationError ?? SIWCError.signInMessage }
        switch lane {
        case .archive: context.responsesOperation = .archive
        case .probe: context.responsesOperation = .probe
        default: break
        }
        return context
    }

    /// The SIWC context for the selected ChatGPT profile from one secrets
    /// snapshot, or nil when the route is not SIWC (legacy and every other
    /// provider keep their constructors).
    static func siwcFromStored(_ stored: [String: String], model: String, effort: String?, lane: AffinityLane,
                               textOnly: Bool) -> ProviderExecutionContext? {
        switch ChatGPTRoute.resolve(stored: stored) {
        case .notChatGPT, .legacy: return nil
        case .ambiguous, .disabled, .siwc:
            var failure: String? = nil
            var source: SIWCCredentialSource? = nil
            do { source = try ChatGPTRoute.currentSource(stored: stored) }
            catch { failure = (error as? SIWCError)?.message ?? SIWCError.signInMessage }
            return siwcContext(source: source, configurationError: failure, model: model, effort: effort, lane: lane,
                               textOnly: textOnly, nativeToolMedia: stored[ProviderProfiles.runtimeNativeMediaKey] != "false")
        }
    }
}
