import Foundation

/// Stage C (SIWC plan §3.8, §3.9): selection keys and the older-binary
/// guard, the operation-start rebind, file tools and redaction, this
/// process's auth activity. Offline, temporary XDG roots.
extension SIWCSelftest {
    /// Clear the live (temporary) roots of SIWC state and selection keys.
    static func resetLive() throws {
        // Every store of the (temporary) machine: the census of the live host.
        for dir in SIWCHost.Paths.liveStoreDirectories() ?? [SIWCStore.resolved().directory] {
            let store = SIWCStore(directory: dir)
            _ = try? store.removeFiles()
            try? FileManager.default.removeItem(at: store.directory.appendingPathComponent(SIWCEndpoint.lockFileName))
        }
        _ = try? SIWCHost.removeIfUnused(.live, now: Int(Date().timeIntervalSince1970) + 100_000)
        try? FileManager.default.removeItem(at: SIWCHost.Paths.live.hostFile)
        try? FileManager.default.removeItem(at: SIWCHost.Paths.live.reservationsFile)
        let snapshot = KeychainHelper.loadSnapshot()
        var delta: [String: String?] = [:]
        for key in snapshot.keys { delta[key] = String?.none }
        if !delta.isEmpty { try KeychainHelper.saveBatch(delta) }
        try? SettingsPendingStore.remove()
        SIWCFence.shared.resetForTests()
        SIWCActivity.shared.resetForTests()
    }

    static func secretsText() -> String {
        (try? String(contentsOf: URL(fileURLWithPath: KeychainHelper.secretStorePath), encoding: .utf8)) ?? ""
    }

    // MARK: Selection keys and the older-binary guard (§3.8 R1, round 2)

    static func stageCSelectionTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        let choice = SIWCSelection.Choice(clientId: "oaiappSelA", sub: "sub-sel-A", generation: UUID().uuidString,
                                          model: "gpt-6.1-sol", effort: "high", textOnly: false)
        var legacyInstall: [String: String] = [
            ProviderProfiles.activeProfileKey: "chatgpt", ProviderProfiles.subscriptionModelKey: "gpt-6.1-sol",
            ProviderProfiles.subscriptionEffortKey: "high", ProviderProfiles.subscriptionTextOnlyKey: "false",
            ProviderProfiles.subscriptionGenerationKey: UUID().uuidString, SubscriptionSharing.accountFingerprintKey: String(repeating: "c", count: 64),
            KeychainHelper.openAICompatibleApiKeyKey: UUID().uuidString, KeychainHelper.openAICompatibleBaseURLKey: SubscriptionEndpoint.inference,
            KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue, ProviderProfiles.runtimeProtocolKey: "responses",
        ]
        for (k, v) in SIWCSelection.activationDelta(choice) { if let v { legacyInstall[k] = v } else { legacyInstall.removeValue(forKey: k) } }
        let after = legacyInstall
        c.check("select: the SIWC selection removes this assistant's legacy selection keys",
                SIWCSelection.legacySelectionKeys.allSatisfy { after[$0] == nil })
        c.check("select: the runtime credential slot is deleted (no sentinel)", after[KeychainHelper.openAICompatibleApiKeyKey] == nil)
        c.check("select: the runtime endpoint is the SIWC base, protocol responses", after[KeychainHelper.openAICompatibleBaseURLKey] == SIWCEndpoint.apiBase
                && after[ProviderProfiles.runtimeProtocolKey] == "responses")
        c.check("select: the route resolves to this exact SIWC selection",
                ChatGPTRoute.resolve(stored: after) == .siwc(.init(registrationFingerprint: SIWCEndpoint.registrationFingerprint(clientId: choice.clientId),
                    identityFingerprint: SIWCEndpoint.identityFingerprint(clientId: choice.clientId, sub: choice.sub), generation: choice.generation)))
        c.check("select: SIWC model, effort and text-only live under SIWC keys", after[ChatGPTRoute.siwcModelKey] == "gpt-6.1-sol"
                && after[ChatGPTRoute.siwcEffortKey] == "high" && after[ChatGPTRoute.siwcTextOnlyKey] == "false")
        // What a pre-SIWC binary reads (§3.8 layer 1, traced at v0.2.67).
        c.check("older binary: no subscription_model → its isConfigured(.chatgpt) is false", after[ProviderProfiles.subscriptionModelKey] == nil)
        c.check("older binary: its adapter refuses the non-legacy endpoint (not the legacy inference URL)",
                after[KeychainHelper.openAICompatibleBaseURLKey] != SubscriptionEndpoint.inference)
        c.check("older binary: its web lane needs a non-empty runtime slot (absent)", (after[KeychainHelper.openAICompatibleApiKeyKey] ?? "").isEmpty)
        var oldSaved = after
        oldSaved[ProviderProfiles.subscriptionGenerationKey] = UUID().uuidString
        oldSaved[ProviderProfiles.subscriptionModelKey] = "gpt-6.1-sol"
        c.check("older binary (D25): legacy keys written beside the SIWC route → ambiguous, nothing sent", ChatGPTRoute.resolve(stored: oldSaved) == .ambiguous)
        // An extra an old binary provisioned from an SIWC default: route key
        // absent, copied legacy generation, SIWC endpoint, no subscription_model.
        var oldExtra = after
        for key in SIWCSelection.selectionKeys { oldExtra.removeValue(forKey: key) }
        oldExtra[ProviderProfiles.subscriptionGenerationKey] = UUID().uuidString
        c.check("older binary: an old-provisioned extra reads as legacy and not configured",
                ChatGPTRoute.resolve(stored: oldExtra) == .legacy && oldExtra[ProviderProfiles.subscriptionModelKey] == nil
                && ProviderExecutionContext.siwcFromStored(oldExtra, model: "m", effort: nil, lane: .main, textOnly: false) == nil)
        // Clear / reactivation.
        let cleared = SIWCSelection.clearDelta(stored: after)
        c.check("select: clearing removes every SIWC key and the SIWC runtime endpoint",
                SIWCSelection.selectionKeys.allSatisfy { cleared.keys.contains($0) } && cleared[KeychainHelper.openAICompatibleBaseURLKey] == .some(nil))
        let reactivation = SIWCSelection.reactivationDelta(stored: after)
        c.check("select: re-activation writes runtime keys only (slot deleted, SIWC base)",
                reactivation?[KeychainHelper.openAICompatibleApiKeyKey] == .some(nil) && reactivation?[KeychainHelper.openAICompatibleBaseURLKey] == .some(SIWCEndpoint.apiBase)
                && reactivation?[ChatGPTRoute.siwcGenerationKey] == nil)
        c.check("select: no re-activation from an ambiguous selection", SIWCSelection.reactivationDelta(stored: oldSaved) == nil)
        // Live: ProviderProfiles on the SIWC route.
        let (source, secrets) = try await liveSelection(clientId: "oaiappSelLive", sub: "sub-sel-live")
        try KeychainHelper.save(key: ChatGPTRoute.siwcModelKey, value: "gpt-6.1-sol")
        c.check("profiles: isConfigured(.chatgpt) on a usable SIWC selection", ProviderProfiles.isConfigured(.chatgpt))
        c.check("profiles: configured model/endpoint come from the SIWC keys",
                ProviderProfiles.configuredModel(.chatgpt) == "gpt-6.1-sol" && ProviderProfiles.configuredEndpoint(.chatgpt) == SIWCEndpoint.apiBase)
        try KeychainHelper.saveBatch([ProviderProfiles.activeProfileKey: "openrouter", KeychainHelper.llmProviderKey: LLMProvider.openRouter.rawValue,
                                      KeychainHelper.openAICompatibleBaseURLKey: "https://example.invalid/v1"])
        try ProviderProfiles.activate(.chatgpt)
        let reactivated = KeychainHelper.loadSnapshot()
        c.check("profiles: activating ChatGPT again restores the SIWC runtime (no slot, SIWC base) and the same source",
                reactivated[KeychainHelper.openAICompatibleBaseURLKey] == SIWCEndpoint.apiBase && reactivated[KeychainHelper.openAICompatibleApiKeyKey] == nil
                && (try? ChatGPTRoute.currentSource())?.generation == source.generation)
        _ = try await source.store.tombstone(source.clientId)
        c.check("profiles: a signed-out SIWC login is not configured", !ProviderProfiles.isConfigured(.chatgpt))
        // Explicit legacy selection clears the SIWC keys (never ambiguous).
        let legacyStore = SubscriptionAuthStore()
        var legacyState = SubscriptionAuthState(generation: UUID().uuidString)
        legacyState.credential = SubscriptionCredential(access: "synthetic-legacy-access", refresh: "synthetic-legacy-refresh",
                                                         expires: Date().addingTimeInterval(3600), account: "acct-legacy", residency: nil)
        try legacyStore.write(legacyState)
        try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: "gpt-6.1-sol", effort: nil, textOnly: false)
        let switched = KeychainHelper.loadSnapshot()
        c.check("profiles: an explicit legacy selection removes the SIWC selection keys",
                SIWCSelection.selectionKeys.allSatisfy { switched[$0] == nil } && switched[ProviderProfiles.subscriptionGenerationKey] == legacyState.generation)
        try ProviderProfiles.activate(.chatgpt)
        c.check("profiles: switching back to legacy rebinds legacy explicitly (resolves as legacy)",
                ChatGPTRoute.resolve(stored: KeychainHelper.loadSnapshot()) == .legacy
                && KeychainHelper.loadSnapshot()[KeychainHelper.openAICompatibleBaseURLKey] == SubscriptionEndpoint.inference)
        try? legacyStore.write(SubscriptionAuthState(generation: UUID().uuidString))
        for key in secrets.keys { try? KeychainHelper.delete(key: key) }
        // Route snapshot (§3.9): the SIWC keys and facts are route inputs.
        let switches = SettingsToolSwitches(subagents: true, webSubagent: true)
        let base = RouteSnapshot.of(stored: after, subscription: .siwcOnly(.absent), switches: switches)
        var genMoved = after; genMoved[ChatGPTRoute.siwcGenerationKey] = UUID().uuidString
        c.check("snapshot: the SIWC generation is a route input", RouteSnapshot.of(stored: genMoved, subscription: .siwcOnly(.absent), switches: switches) != base)
        let factsA = SIWCRouteFacts(present: true, usable: true, planUsage: true, registrationFingerprint: "a", generation: "g1", activeRegistration: "a")
        var factsB = factsA; factsB.activeRegistration = "b"
        c.check("snapshot: the store's active registration is a route input",
                RouteSnapshot.of(stored: after, subscription: .siwcOnly(factsA), switches: switches)
                != RouteSnapshot.of(stored: after, subscription: .siwcOnly(factsB), switches: switches))
        c.check("snapshot: the SIWC generation is a maintenance key (route digest)", SettingsKeyRoles.maintenanceKeys.contains(ChatGPTRoute.siwcGenerationKey)
                && SettingsKeyRoles.routeDigest(after) == SettingsKeyRoles.routeDigest(genMoved))
        c.check("roles: every SIWC selection key has exactly one role and is a route input",
                SIWCSelection.selectionKeys.allSatisfy { SettingsKeyRoles.matchCount($0) == 1 && SettingsKeyRoles.role($0) == .route })
        c.check("catalogue: every SIWC selection key is classified and not secret",
                SIWCSelection.selectionKeys.allSatisfy { CredentialCatalog.treatment(forKey: $0) == .notSecret })
        try await copyKeysTests(root, c)
    }

    /// `profiles add --copy-keys` (§3.8 "Adding an assistant").
    static func copyKeysTests(_ root: URL, _ c: Checks) async throws {
        let (store, _, generation) = try await activeStore(root, clientId: "oaiappCopyA")
        let registration = try store.readRegistrations()!.registration("oaiappCopyA")!
        var defaultStored: [String: String] = [:]
        for (k, v) in SIWCSelection.activationDelta(.init(clientId: "oaiappCopyA", sub: registration.sub, generation: generation,
                                                          model: "gpt-6.1-sol", effort: "high", textOnly: false)) { if let v { defaultStored[k] = v } }
        let current = try store.readTokens()!.record("oaiappCopyA")!.generation
        let copied = SIWCSelection.copyForNewExtra(defaultStored: defaultStored, machineStore: store)
        let text = copied.values.joined(separator: "\n")
        c.check("copy-keys: route and SIWC selection keys are copied", copied[ChatGPTRoute.routeKey] == "siwc"
                && copied[ChatGPTRoute.siwcRegistrationKey] == defaultStored[ChatGPTRoute.siwcRegistrationKey]
                && copied[ChatGPTRoute.siwcGenerationKey] == current)
        c.check("copy-keys: never a token, never a runtime slot", !text.contains("synthetic-") && copied[KeychainHelper.openAICompatibleApiKeyKey] == nil)
        _ = try await store.tombstone("oaiappCopyA")
        c.check("copy-keys: an unusable login binds nothing", SIWCSelection.copyForNewExtra(defaultStored: defaultStored, machineStore: store).isEmpty)
        var other = defaultStored; other[ChatGPTRoute.siwcRegistrationKey] = String(repeating: "f", count: 64)
        c.check("copy-keys: another registration binds nothing", SIWCSelection.copyForNewExtra(defaultStored: other, machineStore: store).isEmpty)
        c.check("copy-keys: the init child accepts the SIWC keys", SIWCSelection.selectionKeys.allSatisfy { ProfileProvisioning.initAcceptedKeys.contains($0) })
    }

    // MARK: Operation-start rebind (§3.8, D21)

    static func stageCRebindTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        let client = "oaiappRebind"
        let (first, _) = try await liveSelection(clientId: client, sub: "sub-rebind")
        let store = first.store
        // Another sharer signs in again to the SAME registration and activates it.
        guard case .staged(_, let replacement, let toBe) = try await signIn(store, .live, clientId: client, sub: "sub-rebind",
                                                                              new: false, tokens: tokens("rebind-2")) else {
            c.check("rebind: fixture", false); return
        }
        _ = try await store.activate(.init(clientId: client, generation: nil, replacementId: replacement))
        // A staged settings change whose precondition names the SIWC generation.
        SettingsSupersede.install()
        defer { SettingsSupersede.uninstall() }
        var staged = PreparedChange(origin: "selftest", label: "waiting", epoch: (try? ReplacementEpoch.read()) ?? 0)
        staged.writes[KeychainHelper.jinaApiKeyKey] = "jina-synthetic-rebind"
        staged.expected[ChatGPTRoute.siwcGenerationKey] = SettingsDigest.of(first.generation)
        _ = try SettingsWriter.stage(staged)
        c.check("rebind: a captured source never rebinds (its next validation refuses)",
                (try? store.validate(clientId: client, generation: first.generation)) == nil)
        let next = try ChatGPTRoute.currentSource()
        c.check("rebind: the next operation follows the same registration's new record", next?.generation == toBe
                && KeychainHelper.load(key: ChatGPTRoute.siwcGenerationKey) == toBe)
        c.check("rebind: a maintenance write never supersedes a staged change",
                (try? SettingsPendingStore.read())?.slots["ai"]?.staged?.change.id == staged.id)
        try? SettingsPendingStore.remove()
        // A pending sign-in in the store: no rebind (validation refuses).
        guard case .staged(_, let r3, _) = try await signIn(store, .live, clientId: client, sub: "sub-rebind", new: false, tokens: tokens("rebind-3")) else {
            c.check("rebind: fixture 3", false); return
        }
        _ = try await store.activate(.init(clientId: client, generation: nil, replacementId: r3))
        let pending = try await store.beginPending(owner: nil)
        let before = KeychainHelper._testWriteCount
        await c.rejects("rebind: none while a sign-in is pending in the store") { _ = try ChatGPTRoute.currentSource() }
        c.check("rebind: nothing written while pending", KeychainHelper._testWriteCount == before)
        try await store.cancelPending(pending)
        _ = try ChatGPTRoute.currentSource()
        // The store's active registration moves to another account: D18.
        let (other, _) = try await liveSelection(clientId: "oaiappRebindOther", sub: "sub-other")
        _ = other
        var selection = KeychainHelper.loadSnapshot()
        for (k, v) in SIWCSelection.activationDelta(.init(clientId: client, sub: "sub-rebind",
            generation: try store.readTokens()!.record(client)!.generation, model: "gpt-6.1-sol", effort: nil, textOnly: false)) {
            if let v { selection[k] = v } else { selection.removeValue(forKey: k) }
        }
        let writesBefore = KeychainHelper._testWriteCount
        do {
            _ = try ChatGPTRoute.currentSource(stored: selection)
            c.check("rebind: another active registration refuses (D18), never rebinds", false)
        } catch let e as SIWCError {
            c.check("rebind: another active registration refuses (D18), never rebinds", e.message.contains("different account")
                    && KeychainHelper._testWriteCount == writesBefore)
        }
        // An unusable record (tombstoned) is not rebound to.
        for (k, v) in SIWCSelection.activationDelta(.init(clientId: "oaiappRebindOther", sub: "sub-other",
            generation: UUID().uuidString, model: "m", effort: nil, textOnly: false)) {
            if let v { try KeychainHelper.save(key: k, value: v) } else { try? KeychainHelper.delete(key: k) }
        }
        _ = try await store.tombstone("oaiappRebindOther")
        await c.rejects("rebind: never to an unusable record") { _ = try ChatGPTRoute.currentSource() }
    }

    // MARK: File tools and redaction (§3.8)

    static func stageCFilesTests(_ root: URL, _ c: Checks) async throws {
        let machine = root.appendingPathComponent("files-machine"), own = root.appendingPathComponent("files-own")
        let paths = hostPaths(root.appendingPathComponent("files-host"), stores: [machine, own])
        for dir in [machine, own] {
            for name in SIWCEndpoint.storeFileNames {
                c.check("files: \(dir.lastPathComponent)/\(name) is protected",
                        SIWCProtectedFiles.isProtected(dir.appendingPathComponent(name).path, storeDirectories: [machine, own], hostPaths: paths))
            }
        }
        c.check("files: the host file is protected", SIWCProtectedFiles.isProtected(paths.hostFile.path, storeDirectories: [machine], hostPaths: paths))
        c.check("files: the reservations file is protected", SIWCProtectedFiles.isProtected(paths.reservationsFile.path, storeDirectories: [machine], hostPaths: paths))
        try PrivateStorage.ensureDirectory(own)
        let link = root.appendingPathComponent("files-link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: own)
        c.check("files: a path through a symbolic link is protected too",
                SIWCProtectedFiles.isProtected(link.appendingPathComponent(SIWCEndpoint.tokenFileName).path, storeDirectories: [machine, own], hostPaths: paths))
        c.check("files: an ordinary file is not", !SIWCProtectedFiles.isProtected(own.appendingPathComponent("notes.txt").path, storeDirectories: [machine, own], hostPaths: paths))
        c.check("files: the live protected set covers the live stores and host",
                SIWCProtectedFiles.isProtected(SIWCStore.resolved().tokenFile.path) && SIWCProtectedFiles.isProtected(SIWCHost.Paths.live.hostFile.path))
        // Redaction: committed, staged, checkpoint and cleanup tokens of both stores, distinct labels.
        let (sm, _, _) = try await activeStore(root, clientId: "oaiappRedactM", tokens: tokens("redact-m"))
        let (so, _, _) = try await activeStore(root, clientId: "oaiappRedactO", tokens: tokens("redact-o"))
        try rewriteBound(so, "oaiappRedactO") { record in
            record.staged = SIWCStagedReplacement(replacementId: UUID().uuidString, tokens: tokens("redact-staged"), identity: record.identity!,
                                                  hostFingerprint: String(repeating: "a", count: 64), generationToBe: UUID().uuidString)
            record.cleanup = ["synthetic-cleanup-redact"]
        }
        var file = try so.readTokens()!
        file.update("oaiappRedactO") { $0.pendingRotation = SIWCPendingRotation(generation: UUID().uuidString,
            replaces: SubscriptionRefreshFingerprint.of("x"), tokens: tokens("redact-pending"), identity: $0.identity!,
            mac: String(repeating: "0", count: 64)) }
        _ = try PrivateStorage.writeAtomically(try SIWCStore.encode(file), to: so.tokenFile)
        let values = CredentialCatalog.siwcRedactionValues([sm.directory, so.directory])
        let set = Set(values.values)
        c.check("redaction: committed tokens of both stores", set.contains("synthetic-access-redact-m") && set.contains("synthetic-refresh-redact-o")
                && set.contains("synthetic.id.redact-m"))
        c.check("redaction: staged replacement, checkpoint and cleanup tokens", set.contains("synthetic-access-redact-staged")
                && set.contains("synthetic-refresh-redact-pending") && set.contains("synthetic-cleanup-redact"))
        c.check("redaction: labels are distinct per store", values.keys.contains { $0.hasPrefix("siwc_0_") } && values.keys.contains { $0.hasPrefix("siwc_own_0_") })
    }

    // MARK: This process's auth activity (§3.8 "Upgrade pause", §3.1 Mind)

    static func stageCActivityTests(_ root: URL, _ c: Checks) async throws {
        SIWCActivity.shared.resetForTests()
        let store = SIWCStore(directory: root.appendingPathComponent("activity-store"))
        let paths = hostPaths(root.appendingPathComponent("activity-host"), stores: [store.directory])
        let signIn = SIWCSignIn(store: store, hostPaths: paths, ownerLease: { nil })
        c.check("activity: idle → no busy reason", SIWCActivity.shared.busyReason() == nil)
        let attempt = try await signIn.start(port: 40001, expectedClientId: nil, owner: nil, profile: "default")
        c.check("activity: a pending sign-in this process owns parks the upgrade", SIWCActivity.shared.busyReason() == "a ChatGPT sign-in")
        c.check("activity: an expired attempt no longer does", SIWCActivity.shared.busyReason(now: attempt.expiresAt + 1) == nil)
        await SIWCActivity.shared.cancelOwned()
        c.check("activity: quiescence cancels this process's attempt (marker and reservation cleared)",
                SIWCActivity.shared.busyReason() == nil && (try? store.readTokens())?.pendingLogin == nil
                && ((try? SIWCHost.readReservations(paths))?.reservations.isEmpty ?? false))
        SIWCActivity.shared.beginSettle()
        c.check("activity: an in-flight refresh settle parks the upgrade", SIWCActivity.shared.busyReason() == "a ChatGPT sign-in refresh")
        SIWCActivity.shared.endSettle(); SIWCActivity.shared.beginRevoke()
        c.check("activity: an in-flight revoke parks the upgrade", SIWCActivity.shared.busyReason() == "a ChatGPT sign-out")
        SIWCActivity.shared.endRevoke()
        // A foreign pending marker (another assistant) is never cancelled here.
        _ = try await store.beginPending(owner: "health")
        await SIWCActivity.shared.cancelOwned()
        c.check("activity: another assistant's pending sign-in is untouched", (try? store.readTokens())?.pendingLoginBy == "health")
        c.check("activity: own-profile cancel refuses a foreign marker", (try? await store.cancelOwnedPending(profile: "default")) == .foreign)
        // A real settle (fake refresh) is tracked while it runs.
        let (s2, _, g2) = try await activeStore(root, tokens: tokens("act", expiresIn: 10))
        let observed = Wire()
        _ = try await s2.credential(clientId: "oaiappClientA", generation: g2) { r in
            observed.lock.lock(); observed.replies.append(.success(Data((SIWCActivity.shared.busyReason() ?? "").utf8))); observed.lock.unlock()
            return rotated(r)
        }
        let during = (try? observed.replies.first?.get()).flatMap { String(data: $0, encoding: .utf8) }
        c.check("activity: a running refresh settle is tracked, and released after", during == "a ChatGPT sign-in refresh"
                && SIWCActivity.shared.busyReason() == nil)
    }
}
