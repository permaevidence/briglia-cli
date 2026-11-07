import Foundation

/// Fixture and probe for `scripts/siwc_older_binary_test.py` (SIWC plan §8
/// "Older binary guard", round-1 R1, round-2 R1, D25): run by the NEW
/// binary inside the script's scratch roots; the script then runs a
/// tag-built v0.2.67 binary against the same roots.
extension SIWCSelftest {
    /// A usable LEGACY login in this assistant's store, a usable SIWC login
    /// selected on the SIWC route (what the new binary writes), and the
    /// legacy selection a ChatGPT install had before.
    static func olderBinaryFixture() async throws {
        try StoragePaths.ensureRootsChecked()
        try PrivateStorage.ensureDirectory(StoragePaths.configRoot)
        let legacy = SubscriptionAuthStore()
        var state = SubscriptionAuthState(generation: UUID().uuidString)
        state.credential = SubscriptionCredential(access: "synthetic-legacy-access", refresh: "synthetic-legacy-refresh",
                                                  expires: Date().addingTimeInterval(86_400), account: "acct-legacy", residency: nil)
        try legacy.write(state)
        let before: [String: String?] = [
            ProviderProfiles.activeProfileKey: "chatgpt", KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
            ProviderProfiles.subscriptionModelKey: "gpt-6.1-sol", ProviderProfiles.subscriptionEffortKey: "high",
            ProviderProfiles.subscriptionTextOnlyKey: "false", ProviderProfiles.subscriptionGenerationKey: state.generation,
            KeychainHelper.openAICompatibleApiKeyKey: state.generation, KeychainHelper.openAICompatibleBaseURLKey: SubscriptionEndpoint.inference,
            KeychainHelper.openAICompatibleModelKey: "gpt-6.1-sol", ProviderProfiles.runtimeProtocolKey: "responses",
            ProviderProfiles.runtimeNativeMediaKey: "false",
        ]
        try KeychainHelper.saveBatch(before)
        // The SIWC login, saved and activated through the real primitives.
        let store = SIWCStore.resolved()
        let host = SIWCHost.Paths.live
        let outcome = try await signIn(store, host, clientId: "oaiappOlder", sub: "sub-older", new: true, tokens: tokens("older"))
        guard case .saved(_, let generation) = outcome else { throw SIWCError(.local, "fixture") }
        let active = try await store.activate(.init(clientId: "oaiappOlder", generation: generation, replacementId: nil))
        try KeychainHelper.saveBatch(SIWCSelection.activationDelta(.init(clientId: "oaiappOlder", sub: "sub-older", generation: active,
                                                                         model: "gpt-6.1-sol", effort: "high", textOnly: false)))
        printRoute()
    }

    /// One JSON line: this assistant's route as the NEW binary resolves it.
    static func printRoute() {
        let stored = KeychainHelper.loadSnapshot()
        let route: String
        switch ChatGPTRoute.resolve(stored: stored) {
        case .notChatGPT: route = "not_chatgpt"
        case .legacy: route = "legacy"
        case .siwc: route = "siwc"
        case .ambiguous: route = "ambiguous"
        case .disabled: route = "disabled"
        }
        let object: [String: Any] = ["route": route, "configured": ProviderProfiles.isConfigured(.chatgpt),
                                     "slot": stored[KeychainHelper.openAICompatibleApiKeyKey] != nil,
                                     "endpoint": stored[KeychainHelper.openAICompatibleBaseURLKey] ?? "",
                                     "legacy_model": stored[ProviderProfiles.subscriptionModelKey] != nil]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
