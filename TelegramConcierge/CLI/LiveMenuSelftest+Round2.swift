import Foundation

/// Codex live-menu implementation review, round 2: R2-1 … R2-4 and the
/// lookup note, each reproducing the reviewer's sequence.
extension LiveMenuHarness {
    func round2Section() async {
        await r2TelegramPublishSection()
        await r2DirectWriterQuarantineSection()
        await r2SelectionFactsSection()
        await r2ShareLockSection()
        await r2LookupEvictionSection()
    }

    /// The exact preparation of the Telegram sign-in hook.
    func telegramHookPrepare(pending: String, credential c: SubscriptionCredential) async -> (PreparedChange?, String?) {
        do {
            let r = try await SettingsCapture.prepareThrowing(origin: "telegram", label: "ChatGPT sign-in", acceptPending: true) { () async throws -> String in
                let generation = try await self.authStore.commitLogin(c, pending: pending)
                try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil,
                    model: ProviderProfiles.configuredModel(.chatgpt) ?? ResponsesAdapter.subscriptionDefaultModel,
                    effort: ProviderProfiles.configuredEffort(.chatgpt) ?? "high", textOnly: false)
                return generation
            }
            return (r.change, r.value)
        } catch { return (nil, "\(error)") }
    }

    // MARK: R2-1

    func r2TelegramPublishSection() async {
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        // First sign-in: no previous credential.
        reset(Self.routeBase)
        let p1 = UUID().uuidString
        writeAuth(pendingLoginState(p1))
        let (c1, g1) = await telegramHookPrepare(pending: p1, credential: credential("acct-1", "first"))
        check("R2-1: a first Telegram sign-in prepares publication + profile in one change", c1 != nil, g1 ?? "")
        if let c1 {
            let r = await writer.commit(c1)
            let auth = try? authStore.read()
            check("R2-1: first sign-in: the saved profile names the published login",
                  r.state == .applied && auth?.credential?.account == "acct-1"
                  && store()[ProviderProfiles.subscriptionGenerationKey] == auth?.generation, "\(r.state) \(r.message ?? "")")
        }
        // Re-login while ChatGPT is NOT active: profile follows the new login.
        let p2 = UUID().uuidString
        var re = (try? authStore.read()) ?? SubscriptionAuthState(generation: UUID().uuidString)
        re.startPending(p2)
        writeAuth(re)
        let (c2, _) = await telegramHookPrepare(pending: p2, credential: credential("acct-1", "second"))
        if let c2 {
            let r = await writer.commit(c2)
            let auth = try? authStore.read()
            check("R2-1: re-login (inactive lane): the profile generation matches the new login",
                  r.state == .applied && auth?.credential?.access == "access-synthetic-second"
                  && store()[ProviderProfiles.subscriptionGenerationKey] == auth?.generation, "\(r.state)")
        } else { check("R2-1: re-login prepared", false) }
        // Re-login while ChatGPT IS the active lane: profile and runtime binding move together.
        let (base, state) = activeChatGPTStore()
        var active = base
        active[KeychainHelper.openAICompatibleApiKeyKey] = state.generation
        reset(active)
        var withPending = state
        let p3 = UUID().uuidString
        withPending.startPending(p3)
        writeAuth(withPending)
        let (c3, _) = await telegramHookPrepare(pending: p3, credential: credential("acct-1", "third"))
        if let c3 {
            let r = await writer.commit(c3)
            let auth = try? authStore.read()
            check("R2-1: re-login (active lane): profile and runtime binding name the new login",
                  r.state == .applied && store()[ProviderProfiles.subscriptionGenerationKey] == auth?.generation
                  && store()[KeychainHelper.openAICompatibleApiKeyKey] == auth?.generation && auth?.generation != state.generation,
                  "\(r.state) \(r.message ?? "")")
        } else { check("R2-1: active re-login prepared", false) }
    }

    // MARK: R2-2

    func r2DirectWriterQuarantineSection() async {
        reset(Self.routeBase.merging([KeychainHelper.keylessSearchKey: "true"]) { $1 })
        ConversationManager.settingsRetrySecondsForTesting = 600
        let manager = ConversationManager()
        manager.startSettingsOwner()
        defer {
            ConversationManager.settingsRetrySecondsForTesting = 10
            SettingsPendingStore.failWritesForTesting = false
            SettingsSupersede.discardInvalidations()
            SettingsClient.inProcessOwner = nil
            SettingsAgentEdit.immediateOwner = nil
            SettingsSupersede.uninstall()
            ProcessKind.isDaemon = false
        }
        let channel = SVRecordingChannel(kind: .telegram)
        manager._svRegisterChannel(channel)
        manager._svSetLastUserAddress(ChannelAddress(kind: .telegram, chatId: "515151"))
        manager._svSetPairedChatId(515151)
        manager._testSetActiveProcessing(true)
        guard let staged = await prepare(label: "Free search", { try KeychainHelper.save(key: KeychainHelper.keylessSearchKey, value: "false") }) else { return }
        let rs = await SettingsClient.commit(staged)
        check("R2-2: fixture: the free-search change is staged", rs.state == .pending, "\(rs.state)")
        manager._testSetActiveProcessing(false)
        SettingsPendingStore.failWritesForTesting = true
        var n = channel.delivered.count
        _ = await manager.handleControlCommandIfNeeded("/freesearch off")
        _ = await waitUntil(10) { channel.delivered.count >= n + 2 }
        check("R2-2: a direct command write whose invalidation fails says so",
              store()[KeychainHelper.keylessSearchKey] == "false"
              && channel.delivered.suffix(2).contains { $0.contains("could not be cancelled") }, "\(channel.delivered.suffix(2))")
        check("R2-2: the invalidated change is recorded outside the pending file",
              SettingsSupersede.tombstonedIds().contains(staged.id))
        n = channel.delivered.count
        _ = await manager.handleControlCommandIfNeeded("/freesearch on")
        _ = await waitUntil(10) { channel.delivered.count > n }
        check("R2-2: the next direct command write is refused while the invalidation is unsaved",
              store()[KeychainHelper.keylessSearchKey] == "false" && channel.delivered.last?.contains("could not be cancelled") == true,
              "\(channel.delivered.suffix(1))")
        // A new owner (the in-memory record gone) still honours it.
        SettingsSupersede._testForgetInMemory()
        SettingsPendingStore.failWritesForTesting = false
        let applied = await manager.settingsWriter.applyStaged(category: "ai")
        let doc = pendingDoc()
        check("R2-2: after an owner restart the superseded change is dropped, never applied",
              applied == nil && doc.slots.values.allSatisfy { $0.staged == nil }
              && doc.lastResults.contains { $0.clientRequestId == staged.id && $0.state == "dropped" }
              && !FileManager.default.fileExists(atPath: SettingsSupersede.tombstoneURL.path),
              "applied \(String(describing: applied?.state))")
    }

    // MARK: R2-3

    func r2SelectionFactsSection() async {
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        for kind in ["requireLogin", "beginLogin"] {
            reset(Self.routeBase)
            var a = SubscriptionAuthState(generation: UUID().uuidString)
            a.credential = credential("acct-1", "a")
            writeAuth(a)
            let select = await prepare(label: "ChatGPT selection") {
                try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: "gpt-6-sol", effort: "high", textOnly: false)
                try ProviderProfiles.activate(.chatgpt)
            }
            if kind == "requireLogin" {
                try? await authStore.requireLogin(generation: a.generation, rejectedAccess: a.credential?.access)
            } else {
                _ = try? await authStore.beginLogin()
            }
            guard let select else { check("R2-3: \(kind): selection prepared", false); continue }
            let r = await writer.commit(select)
            check("R2-3: a selection is refused when the login became \(kind == "requireLogin" ? "unusable" : "pending") (same generation)",
                  r.state == .refused && store()[ProviderProfiles.activeProfileKey] == "openrouter", "\(r.state) \(r.message ?? "")")
        }
    }

    // MARK: R2-4

    func r2ShareLockSection() async {
        reset(Self.routeBase)
        var a = SubscriptionAuthState(generation: UUID().uuidString)
        a.credential = credential("acct-1", "a")
        writeAuth(a)
        guard let logout = await prepareSubscription({ try await self.authStore.logout() }) else { return }
        let registry = AssistantRegistry.Paths.live.registry
        try? FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: registry.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: registry) }
        check("R2-4: fixture: multi coordination", CoordinationMode.multi)
        guard let held = try? ChatGPTShare.takeLock(wait: 0) else { check("R2-4: fixture: share lock", false); return }
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        let commit = Task { @MainActor in await writer.commit(logout) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        writer.gate.closeAdmission(reason: "lifecycle test")
        let freed = await waitUntil(1) { !writer.gate.isHeld }
        check("R2-4: closing admission cancels a writer waiting for the sharing lock", freed)
        held.release()
        let r = await commit.value
        check("R2-4: that writer refused with nothing written", r.state == .refused && (try? authStore.read())?.credential != nil, "\(r.state)")
    }

    // MARK: lookup

    func r2LookupEvictionSection() async {
        reset(Self.routeBase)
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        owner.busy = true
        guard let first = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "first/model") }) else { return }
        _ = await writer.commit(first)
        owner.busy = false
        _ = await writer.applyStaged(category: "ai")
        // Push the first result out of the 20-entry persisted history.
        owner.busy = true
        for i in 0..<21 {
            guard let c = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "m/\(i)") }) else { continue }
            let r = await writer.commit(c)
            if let ticket = r.ticket { _ = try? SettingsWriter.cancelStaged(ticket: ticket) }
        }
        owner.busy = false
        let after = writer.lookup(first.id)
        check("R2 note: an evicted result never resurrects an obsolete pending answer",
              after == nil, "\(String(describing: after?.state))")
    }
}
