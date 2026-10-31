import Foundation

/// Codex live-menu implementation review, round 1: one regression row per
/// finding (R1-1 … R1-8 and the stale lookup), each reproducing the
/// reviewer's sequence against the fixed code.
final class LMSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func add(_ v: Bool) { lock.lock(); values.append(v); lock.unlock() }
    var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}

final class LMFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

extension LiveMenuHarness {
    func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    func round1Section() async {
        await r1OfflineSerialSection()
        await r1TelegramSection()
        await r1ExpectationSection()
        await r1SupersedeFailureSection()
        await r1LifecycleSection()
        await r1PreDecisionSection()
        await r1CaptureIntentSection()
        await r1ForwardAndLookupSection()
    }

    // MARK: R1-1 one offline owner per process

    func r1OfflineSerialSection() async {
        reset(Self.routeBase)
        SettingsClient.inProcessOwner = nil
        ProcessKind.isDaemon = false
        SettingsClient.socketRetrySecondsForTesting = 1
        defer {
            SettingsClient.socketRetrySecondsForTesting = nil
            OfflineOwner.writer.beforeDecisionPointForTesting = nil
            SettingsWriter.afterSecretsWriteForTesting = nil
        }
        let gateOpen = LMFlag()
        let reached = LMFlag()
        var first = true
        OfflineOwner.writer.beforeDecisionPointForTesting = {
            guard first else { return }
            first = false
            reached.set()
            while !gateOpen.isSet { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        let samples = LMSamples()
        SettingsWriter.afterSecretsWriteForTesting = { samples.add(InstanceLease.isHeldInThisProcess) }
        guard let a = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-r1-a") }),
              let b = await prepare(label: "OpenRouter key", { try KeychainHelper.save(key: KeychainHelper.openRouterApiKeyKey, value: "sk-or-r1-b") })
        else { check("R1-1: fixtures", false); return }
        let ta = Task { @MainActor in await SettingsClient.commit(a) }
        let up = await waitUntil(10) { reached.isSet }
        let tb = Task { @MainActor in await SettingsClient.commit(b) }
        let queued = await waitUntil(5) { OfflineCommitQueue.waitingForTesting == 1 }
        check("R1-1: a second offline save waits for the first (one local commit at a time)",
              up && queued && SettingsClient.shortCommitsInProgress == 1,
              "reached \(up) queued \(queued) inFlight \(SettingsClient.shortCommitsInProgress)")
        gateOpen.set()
        let ra = await ta.value
        let rb = await tb.value
        check("R1-1: both saves applied, each while this process held the instance lease",
              ra.state == .applied && rb.state == .applied && samples.all == [true, true]
              && store()[KeychainHelper.serperApiKeyKey] == "serper-r1-a" && store()[KeychainHelper.openRouterApiKeyKey] == "sk-or-r1-b",
              "\(ra.state) \(rb.state) samples \(samples.all)")
        check("R1-1: the lease is released after the last commit", !InstanceLease.isHeldInThisProcess)

        // The pairing lease ends while a save borrowing it runs: the release
        // waits for that save.
        let pairing = MenuPairingLease()
        guard pairing.begin() else { check("R1-1: pairing lease", false); return }
        let open2 = LMFlag(); let reached2 = LMFlag()
        first = true
        OfflineOwner.writer.beforeDecisionPointForTesting = {
            guard first else { return }
            first = false
            reached2.set()
            while !open2.isSet { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        guard let c = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-r1-c") }) else { return }
        let tc = Task { @MainActor in await SettingsClient.commit(c) }
        _ = await waitUntil(10) { reached2.isSet }
        pairing.end()
        check("R1-1: closing the pairing step during a borrowing save keeps the lease until it ends",
              InstanceLease.isHeldInThisProcess)
        open2.set()
        let rc = await tc.value
        check("R1-1: the borrowing save completes under the lease, then the lease is released",
              rc.state == .applied && samples.all.last == true && !InstanceLease.isHeldInThisProcess,
              "\(rc.state) \(samples.all)")
    }

    // MARK: R1-2 Telegram subscription through the transaction

    func activeChatGPTStore() -> (base: [String: String], state: SubscriptionAuthState) {
        var state = SubscriptionAuthState(generation: UUID().uuidString)
        state.credential = credential("acct-1", "a")
        var base = Self.routeBase
        base[ProviderProfiles.activeProfileKey] = "chatgpt"
        base[KeychainHelper.llmProviderKey] = "openai_compatible"
        base[ProviderProfiles.subscriptionGenerationKey] = state.generation
        base[ProviderProfiles.subscriptionModelKey] = "gpt-6-sol"
        return (base, state)
    }

    func r1TelegramSection() async {
        let (base, state) = activeChatGPTStore()
        reset(base)
        writeAuth(state)
        ConversationManager.settingsRetrySecondsForTesting = 600
        let manager = ConversationManager()
        manager.startSettingsOwner()
        defer {
            ConversationManager.settingsRetrySecondsForTesting = 10
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
        let before = channel.delivered.count
        _ = await manager.handleControlCommandIfNeeded("/subscription logout")
        _ = await waitUntil(10) { channel.delivered.count > before }
        let after = try? authStore.read()
        check("R1-2: a Telegram sign-out of the login a running turn uses waits for idle (nothing deleted)",
              after?.credential != nil && after?.generation == state.generation && after?.lastAttempt == nil,
              "\(channel.delivered.suffix(1))")
        check("R1-2: the reply says Briglia is busy", channel.delivered.last?.lowercased().contains("busy") == true
              || channel.delivered.last?.contains("task") == true, "\(channel.delivered.suffix(1))")
        // Idle: the same command goes through the transaction (attempt recorded).
        manager._testSetActiveProcessing(false)
        let before2 = channel.delivered.count
        _ = await manager.handleControlCommandIfNeeded("/subscription logout")
        _ = await waitUntil(10) { channel.delivered.count > before2 }
        let out = try? authStore.read()
        check("R1-2: idle, the sign-out is committed by the writer (auth state records the attempt)",
              out?.credential == nil && out?.lastAttempt != nil, "\(channel.delivered.suffix(1))")
        // A direct route writer without its own guard refuses while busy.
        manager._testSetActiveProcessing(true)
        let before3 = channel.delivered.count
        _ = await manager.handleControlCommandIfNeeded("/freesearch off")
        _ = await waitUntil(10) { channel.delivered.count > before3 }
        check("R1-2: /freesearch off during a turn is refused (route setting, idle rule)",
              store()[KeychainHelper.keylessSearchKey] == nil && channel.delivered.last?.contains("A turn is running") == true,
              "\(channel.delivered.suffix(1))")
        manager._testSetActiveProcessing(false)
    }

    // MARK: R1-3 auth basis expectations

    func r1ExpectationSection() async {
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        // Logout prepared against login A; login B published meanwhile.
        var base = Self.routeBase
        reset(base)
        var a = SubscriptionAuthState(generation: UUID().uuidString)
        a.credential = credential("acct-1", "a")
        writeAuth(a)
        let logout = await prepareSubscription { try await self.authStore.logout() }
        check("R1-3: a prepared logout records the login it read", logout?.subscriptionExpectations.contains { $0.generation == a.generation } == true)
        var b = SubscriptionAuthState(generation: UUID().uuidString)
        b.credential = credential("acct-2", "b")
        writeAuth(b)
        if let logout {
            let r = await writer.commit(logout)
            check("R1-3: a stale logout is refused and the newer login survives",
                  r.state == .refused && (try? authStore.read())?.credential?.account == "acct-2", "\(r.state) \(r.message ?? "")")
        }
        // Logout prepared against an absent store; a login appears.
        reset(base)
        let absent = await prepareSubscription { try await self.authStore.logout() }
        writeAuth(b)
        if let absent {
            let r = await writer.commit(absent)
            check("R1-3: a logout prepared against no login is refused once a login exists",
                  r.state == .refused && (try? authStore.read())?.credential != nil, "\(r.state)")
        }
        // Selection (saveProfile + activate) prepared against A; B appears.
        base[ProviderProfiles.activeProfileKey] = "openrouter"
        reset(base)
        writeAuth(a)
        let select = await prepare(label: "ChatGPT selection") {
            try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: "gpt-6-sol", effort: "high", textOnly: false)
            try ProviderProfiles.activate(.chatgpt)
        }
        writeAuth(b)
        if let select {
            let r = await writer.commit(select)
            check("R1-3: a stale ChatGPT selection is refused (no binding to a replaced login)",
                  r.state == .refused && store()[ProviderProfiles.activeProfileKey] == "openrouter", "\(r.state) \(r.message ?? "")")
        } else {
            check("R1-3: selection prepared", false)
        }
    }

    // MARK: R1-4 failed superseding persistence

    func r1SupersedeFailureSection() async {
        reset(Self.routeBase)
        SettingsSupersede.install()
        defer { SettingsSupersede.uninstall(); SettingsPendingStore.failWritesForTesting = false }
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        owner.busy = true
        let original = Self.routeBase[KeychainHelper.openRouterModelKey]!
        guard let staged = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "stale/model") }) else { return }
        let rs = await writer.commit(staged)
        check("R1-4: fixture: the model change is staged", rs.state == .pending, "\(rs.state)")
        SettingsPendingStore.failWritesForTesting = true
        guard let toB = await prepare(label: "agent", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "b/model") }) else { return }
        let r1 = await writer.commit(toB, policy: .immediate)
        check("R1-4: the write is saved and says the waiting change could not be cancelled on disk",
              r1.state == .applied && r1.message?.contains("could not be cancelled") == true, "\(r1.state) \(r1.message ?? "")")
        guard let toA = await prepare(label: "agent", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: original) }) else { return }
        let r2 = await writer.commit(toA, policy: .immediate)
        check("R1-4: while the invalidation is unsaved, the next write is refused (fail closed)",
              r2.state == .refused && store()[KeychainHelper.openRouterModelKey] == "b/model", "\(r2.state) \(r2.message ?? "")")
        owner.busy = false
        let applied = await writer.applyStaged(category: "ai")
        check("R1-4: the stale staged change is not applied while the failure lasts",
              applied == nil && store()[KeychainHelper.openRouterModelKey] == "b/model")
        SettingsPendingStore.failWritesForTesting = false
        let r3 = await writer.commit(toA, policy: .immediate)
        _ = await writer.applyStaged(category: "ai")
        check("R1-4: once writable, the invalidation lands first: the staged change is dropped, never revived by A→B→A",
              r3.state == .applied && store()[KeychainHelper.openRouterModelKey] == original
              && pendingDoc().slots["ai"]?.staged == nil && pendingDoc().lastResults.contains { $0.state == "dropped" },
              "\(r3.state) model \(store()[KeychainHelper.openRouterModelKey] ?? "nil")")
    }

    // MARK: R1-5 lifecycle cancellation

    func r1LifecycleSection() async {
        // An auth-lock wait is cancelled by closing admission.
        reset(Self.routeBase)
        var a = SubscriptionAuthState(generation: UUID().uuidString)
        a.credential = credential("acct-1", "a")
        writeAuth(a)
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        guard let logout = await prepareSubscription({ try await self.authStore.logout() }) else { return }
        let release = LMFlag(); let holding = LMFlag()
        let holder = Task.detached { [store = authStore] in
            try? await store.locked {
                holding.set()
                while !release.isSet { try? await Task.sleep(nanoseconds: 10_000_000) }
            }
        }
        _ = await waitUntil(5) { holding.isSet }
        let commit = Task { @MainActor in await writer.commit(logout) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        writer.gate.closeAdmission(reason: "lifecycle test")
        let freed = await waitUntil(2) { !writer.gate.isHeld }
        check("R1-5: closing admission cancels a writer waiting for an auth lock (holder freed at once)", freed)
        release.set()
        _ = await holder.value
        let r = await commit.value
        check("R1-5: that writer refused with nothing written", r.state == .refused && (try? authStore.read())?.credential != nil, "\(r.state)")
        writer.gate.reopenAdmission()

        // A durable pending apply is not cancelled by the upgrade pause.
        reset(Self.routeBase)
        ConversationManager.settingsRetrySecondsForTesting = 600
        let manager = ConversationManager()
        manager.startSettingsOwner()
        defer {
            ConversationManager.settingsRetrySecondsForTesting = 10
            SettingsClient.inProcessOwner = nil
            SettingsAgentEdit.immediateOwner = nil
            SettingsSupersede.uninstall()
            ProcessKind.isDaemon = false
        }
        manager._testSetActiveProcessing(true)
        guard let d = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "durable/model") }) else { return }
        _ = await SettingsClient.commit(d)
        let cancelled = LMSamples()
        manager.settingsWriter.duringReconciliationForTesting = { [weak manager] in
            manager?.pauseAdmission()
            try? await Task.sleep(nanoseconds: 50_000_000)
            cancelled.add(Task.isCancelled)
        }
        manager._testSetActiveProcessing(false)
        manager.kickSettingsApply()
        _ = await waitUntil(10) { !cancelled.all.isEmpty && !manager.settingsApplyInFlight }
        check("R1-5: the upgrade pause does not cancel a pending apply in its durable phase",
              cancelled.all == [false] && store()[KeychainHelper.openRouterModelKey] == "durable/model"
              && pendingDoc().lastResults.last?.state == "applied", "\(cancelled.all)")
        manager.settingsWriter.duringReconciliationForTesting = nil
        manager.resumeAdmission()
    }

    // MARK: R1-6 pre-decision failures and unreadable evidence

    func r1PreDecisionSection() async {
        reset(Self.routeBase)
        var a = SubscriptionAuthState(generation: UUID().uuidString)
        a.credential = credential("acct-1", "a")
        writeAuth(a)
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        owner.busy = true
        guard var logout = await prepareSubscription({ try await self.authStore.logout() }) else { return }
        logout.acceptPending = true
        // Make the logout a staged (route) change: ChatGPT active.
        try? KeychainHelper.saveBatch([ProviderProfiles.activeProfileKey: "chatgpt"])
        logout.expected[ProviderProfiles.activeProfileKey] = SettingsDigest.of("chatgpt")
        let stagedResult = await writer.commit(logout)
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("lm-r1-6-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: bad.path, contents: Data("x".utf8))
        SettingsWriter.authStoreForTesting = { _ in SubscriptionAuthStore(directory: bad) }
        defer { SettingsWriter.authStoreForTesting = nil; try? FileManager.default.removeItem(at: bad) }
        owner.busy = false
        // The lock setup of the change's own store fails before the decision.
        try? FileManager.default.removeItem(at: StoragePaths.configRoot.appendingPathComponent("subscription-auth.lock"))
        try? FileManager.default.createDirectory(at: StoragePaths.configRoot.appendingPathComponent("subscription-auth.lock"), withIntermediateDirectories: true)
        let r = await writer.applyStaged(category: "ai")
        check("R1-6: a lock failure before the decision point returns the claimed change to staged",
              stagedResult.state == .pending && r == nil && pendingDoc().slots["ai"]?.staged != nil && pendingDoc().slots["ai"]?.active == nil,
              "staged \(stagedResult.state) result \(String(describing: r?.state))")
        try? FileManager.default.removeItem(at: StoragePaths.configRoot.appendingPathComponent("subscription-auth.lock"))

        // Unreadable secrets: recovery keeps the record and decides nothing.
        reset(Self.routeBase)
        let attempt = UUID().uuidString
        _ = try? SettingsPendingStore.update { doc in
            doc.attempts[attempt] = SettingsPendingStore.Attempt(
                attempt: attempt, operation: "commit", category: "ai", ticket: nil, clientRequestId: "r1-6", label: "AI model",
                authEffect: false, authKind: nil, storePath: nil, oldEvidence: nil, projectedEvidence: nil,
                secretsKeys: [KeychainHelper.openRouterModelKey], steps: ["intent"], direction: nil, retirement: nil, startedAt: Date())
        }
        try? KeychainHelper.save(key: SettingsWriter.attemptMarkerKey("ai"), value: attempt)
        let secretsURL = StoragePaths.configRoot.appendingPathComponent("secrets.json")
        try? Data("{ not json".utf8).write(to: secretsURL)
        var deferred = false
        do { _ = try SettingsRecovery.run() } catch is SettingsRecovery.RecoveryDeferred { deferred = true } catch {}
        check("R1-6: unreadable secrets defer recovery; the attempt record is kept (never \"interrupted before saving\")",
              deferred && pendingDoc().attempts[attempt] != nil)
        try? FileManager.default.removeItem(at: secretsURL)
    }

    // MARK: R1-7 explicit write intents and transaction bases

    func r1CaptureIntentSection() async {
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        reset(Self.routeBase)
        guard let same = await prepare(label: "Name", { try KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Tester") }) else { return }
        check("R1-7: saving the current value still records the key (validated at commit)",
              same.expected[KeychainHelper.userNameKey] != nil && same.validateOnly == true && !same.isNoop)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Newer")
        let r = await writer.commit(same)
        check("R1-7: a no-op save prepared before a newer value is refused (not reported as applied)",
              r.state == .refused && store()[KeychainHelper.userNameKey] == "Newer", "\(r.state)")
        reset(Self.routeBase)
        guard let derived = await prepare(label: "Assistant name", {
            try KeychainHelper.conditionalTransaction { s in s[KeychainHelper.assistantNameKey] = s[KeychainHelper.userNameKey] }
        }) else { return }
        check("R1-7: a dictionary transaction carries a whole-store basis", derived.storeDigest != nil)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Changed")
        let r2 = await writer.commit(derived)
        check("R1-7: a value derived from a key that changed meanwhile is refused",
              r2.state == .refused && store()[KeychainHelper.assistantNameKey] == nil, "\(r2.state)")
    }

    // MARK: R1-8 forwarding revalidation, lookup

    func r1ForwardAndLookupSection() async {
        reset(Self.routeBase)
        guard let change = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-fwd") }) else { return }
        let revoked = LMFlag()
        var sends = 0
        OwnerSocket.transportForTesting = { _ in
            sends += 1
            revoked.set()          // the menu revokes the action meanwhile
            throw OwnerSocket.Failure.unavailable
        }
        SettingsClient.socketRetrySecondsForTesting = 5
        defer { OwnerSocket.transportForTesting = nil; SettingsClient.socketRetrySecondsForTesting = nil }
        let r = await SettingsClient.forward(change, stillValid: { if revoked.isSet { throw SettingsCommitError.refused("revoked") } })
        check("R1-8: an action revoked while the owner was unavailable is never sent on a later attempt",
              r.state == .refused && sends == 1, "\(r.state) sends \(sends)")

        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        owner.busy = true
        guard let staged = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "lookup/model") }) else { return }
        let rs = await writer.commit(staged)
        owner.busy = false
        _ = await writer.applyStaged(category: "ai")
        check("R1 note: a remembered pending answer reports the applied result after the apply",
              rs.state == .pending && writer.lookup(staged.id)?.state == .applied, "\(String(describing: writer.lookup(staged.id)?.state))")
    }
}
