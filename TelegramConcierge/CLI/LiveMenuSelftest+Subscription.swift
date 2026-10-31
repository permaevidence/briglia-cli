import Foundation

// Subscription operations through the writer (plan B.4a 8.2, B.5): publish,
// cancel, logout with `lastAttempt`, the journal, partial results.
extension LiveMenuHarness {
    func pendingLoginState(_ pending: String, owner: String? = nil) -> SubscriptionAuthState {
        var s = SubscriptionAuthState(generation: UUID().uuidString)
        s.startPending(pending, owner: owner)
        return s
    }

    func subscriptionSection() async {
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        // Publish: credential + projected generation + lastAttempt, journal cleaned.
        reset(Self.routeBase)
        let pending = UUID().uuidString
        writeAuth(pendingLoginState(pending))
        let login = SubscriptionLogin(store: authStore)
        let (change, generation): (PreparedChange?, String?) = await {
            do {
                let r = try await SettingsCapture.prepareThrowing(origin: "selftest", label: "ChatGPT sign-in") {
                    try await login.store.commitLogin(credential(), pending: pending)
                }
                return (r.change, r.value)
            } catch { return (nil, nil) }
        }()
        let unpublished = try? authStore.read()
        check("publish: preparing a login writes nothing", unpublished?.credential == nil && unpublished?.pendingLogin == pending)
        guard let change, let generation else { check("publish: prepared", false); return }
        check("publish: the operation is recorded with a pre-generated generation",
              change.subscription?.kind == .publish && change.subscription?.projectedGeneration == generation)
        let r = await writer.commit(change)
        let after = try? authStore.read()
        check("publish: applied (OpenRouter is active: a plain save)", r.state == .applied, "\(r.state) \(r.message ?? "")")
        check("publish: the credential is published under the projected generation",
              after?.credential?.account == "acct-1" && after?.generation == generation && after?.pendingLogin == nil)
        check("publish: the auth state records the attempt", after?.lastAttempt != nil)
        check("publish: the attempt journal is cleaned and its result recorded",
              pendingDoc().attempts.isEmpty && pendingDoc().lastResults.last?.state == "applied")
        check("publish: the secrets attempt marker equals the auth state's attempt",
              store()[SettingsWriter.attemptMarkerKey("ai")] == after?.lastAttempt)
        // Publish against a superseded pending login → zero writes.
        let pendingB = UUID().uuidString
        writeAuth(pendingLoginState(pendingB))
        var stale = change
        stale.subscription?.pending = UUID().uuidString
        let writes = KeychainHelper._testWriteCount
        let r2 = await writer.commit(stale)
        check("publish: a superseded pending login is refused with zero writes", r2.state == .refused && KeychainHelper._testWriteCount == writes
              && ((try? authStore.read())?.pendingLogin == pendingB))
        // The active-login guard is rechecked at commit.
        reset(Self.routeBase.merging([ProviderProfiles.activeProfileKey: "chatgpt"]) { $1 })
        var active = SubscriptionAuthState(generation: UUID().uuidString)
        active.credential = credential("acct-1", "old")
        let pendingC = UUID().uuidString
        active.startPending(pendingC)
        writeAuth(active)
        var guarded = change
        guarded.subscription?.pending = pendingC
        guarded.subscription?.guardActiveLogin = true
        guarded.expected = [:]; guarded.routeDigest = nil
        let r3 = await writer.commit(guarded)
        check("publish: the active-login replacement guard refuses at the decision point", r3.state == .refused
              && ((try? authStore.read())?.credential?.access == "access-synthetic-old"))
        // Cancel: owned → cleared (generation kept); foreign → refused; none → no effect.
        reset(Self.routeBase)
        let pendingD = UUID().uuidString
        let base = pendingLoginState(pendingD)
        writeAuth(base)
        let cancel = await prepareSubscription { _ = try await self.authStore.cancelOwnedPending() }
        let rc = await writer.commit(cancel ?? PreparedChange(origin: "x", label: "x", epoch: 0))
        let cancelled = try? authStore.read()
        check("cancel: an owned pending login is cancelled; the generation is kept",
              rc.state == .applied && cancelled?.pendingLogin == nil && cancelled?.generation == base.generation && cancelled?.lastAttempt != nil)
        writeAuth(pendingLoginState(UUID().uuidString, owner: "work"))
        var foreignOutcome: SubscriptionAuthStore.OwnedCancel = .none
        _ = await prepareSubscription { foreignOutcome = try await self.authStore.cancelOwnedPending() }
        check("cancel: another assistant's pending login is not cancelled", foreignOutcome == .foreign)
        writeAuth(SubscriptionAuthState(generation: UUID().uuidString))
        let none = await prepareSubscription { _ = try await self.authStore.cancelOwnedPending() }
        check("cancel: nothing to cancel prepares no effect (no journal, no write)", none?.isEmpty == true)
        // Logout: tombstone with lastAttempt; D while ChatGPT runs.
        reset(Self.routeBase.merging([ProviderProfiles.activeProfileKey: "chatgpt"]) { $1 })
        var signedIn = SubscriptionAuthState(generation: UUID().uuidString)
        signedIn.credential = credential()
        writeAuth(signedIn)
        let logout = await prepareSubscription { try await self.authStore.logout() }
        owner.busy = true
        let rl = await writer.commit(logout ?? PreparedChange(origin: "x", label: "x", epoch: 0))
        check("logout: signing out the active ChatGPT login while busy is staged (route change)", rl.state == .pending, "\(rl.state)")
        check("logout: the staged logout wrote nothing", ((try? authStore.read())?.credential != nil))
        owner.busy = false
        _ = await writer.applyStaged(category: "ai")
        let out = try? authStore.read()
        check("logout: at idle the tombstone is written with the attempt", out?.credential == nil && out?.lastAttempt != nil)
    }

    func prepareSubscription(_ body: () async throws -> Void) async -> PreparedChange? {
        do { return try await SettingsCapture.prepareThrowing(origin: "selftest", label: "ChatGPT", acceptPending: true) { try await body() }.change }
        catch { check("subscription change prepared", false, "\(error)"); return nil }
    }

    func subscriptionFailureSection() async {
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        // Auth written, secrets write fails → partial; no replay.
        reset(Self.routeBase)
        let pending = UUID().uuidString
        writeAuth(pendingLoginState(pending))
        var change = await prepareSubscription {
            _ = try await self.authStore.commitLogin(self.credential(), pending: pending)
        }
        change?.writes[ProviderProfiles.subscriptionModelKey] = "gpt-6-sol"
        SettingsWriter.afterAuthWriteForTesting = { KeychainHelper._testFailWrites = true }
        let r = await writer.commit(change ?? PreparedChange(origin: "x", label: "x", epoch: 0))
        KeychainHelper._testFailWrites = false
        SettingsWriter.afterAuthWriteForTesting = nil
        check("partial: auth published, settings not saved → partial", r.state == .partial, "\(r.state) \(r.message ?? "")")
        check("partial: the result says what happened", r.message?.contains("ChatGPT login published") == true)
        check("partial: the journal is cleaned with a partial result", pendingDoc().attempts.isEmpty && pendingDoc().lastResults.last?.state == "partial")
        check("partial: the settings key was not written", store()[ProviderProfiles.subscriptionModelKey] == nil)
        // The auth write fails before replacement → failed, nothing changed.
        reset(Self.routeBase)
        let pendingB = UUID().uuidString
        writeAuth(pendingLoginState(pendingB))
        let change2 = await prepareSubscription {
            _ = try await self.authStore.commitLogin(self.credential(), pending: pendingB)
        }
        struct Injected: Error {}
        SettingsWriter.authStoreForTesting = { path in
            var s = SubscriptionAuthStore(directory: URL(fileURLWithPath: path, isDirectory: true))
            s.beforeWrite = { throw Injected() }
            return s
        }
        let r2 = await writer.commit(change2 ?? PreparedChange(origin: "x", label: "x", epoch: 0))
        SettingsWriter.authStoreForTesting = nil
        check("auth failure before replacement: an error, nothing published", r2.state == .error && ((try? authStore.read())?.credential == nil))
        // After replacement (the afterWrite seam) → handled as written.
        let change3 = await prepareSubscription {
            _ = try await self.authStore.commitLogin(self.credential(), pending: pendingB)
        }
        SettingsWriter.authStoreForTesting = { path in
            var s = SubscriptionAuthStore(directory: URL(fileURLWithPath: path, isDirectory: true))
            s.afterWrite = { throw Injected() }
            return s
        }
        let r3 = await writer.commit(change3 ?? PreparedChange(origin: "x", label: "x", epoch: 0))
        SettingsWriter.authStoreForTesting = nil
        check("auth failure after replacement: handled as written (visible, durability unconfirmed)",
              r3.state == .applied && ((try? authStore.read())?.credential != nil))
    }
}
