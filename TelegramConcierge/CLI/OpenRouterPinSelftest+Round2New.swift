import Foundation

/// Round-2 checks that use the new helper signatures (`listingBasis`,
/// `settingsDigest`); the public-surface reproductions are in `+Round2`.
@MainActor
extension ORPinSuite {
    func reviewRound2NewAPI() async {
        // The wizard's path: basis read before the listing, a newer user pin
        // written during it, then the save.
        reset(orStore(model: dflt)); PM.ensureMigrated()
        setEntry(haiku, ["google-vertex"], by: .user)
        let before = basis()
        _ = host(haiku, .pin(["deepinfra"]))
        let r = Result { try Pin.saveOpenRouterProfile(apiKey: nil, model: haiku, effort: "high", textOnly: false,
                                                       listing: listing(haiku, ["google-vertex"]), presetHostPin: true,
                                                       activate: false, listingBasis: before, now: now) }
        check("V1 wizard path: the listing basis keeps a newer user pin (kept, not verified)",
              (try? r.get())?.outcome == .keptUnverified(["deepinfra"], reason: "saved hosts changed while checking")
              && entry(haiku)?.hosts == ["deepinfra"], "\(r)")

        let store = orStore(model: dflt, extra: [KeychainHelper.openRouterReasoningEffortKey: "high"])
        var edited = store
        edited[KeychainHelper.openRouterReasoningEffortKey] = "max"
        check("V2 settings digest: a projection digests like its store; effort is part of it; no key bytes",
              Pin.settingsDigest(store) == Pin.settingsDigest(Pin.settingsProjection(store))
              && Pin.settingsDigest(store) != Pin.settingsDigest(edited)
              && Pin.settingsProjection(store)[KeychainHelper.openRouterApiKeyKey] == "set")
    }
}
