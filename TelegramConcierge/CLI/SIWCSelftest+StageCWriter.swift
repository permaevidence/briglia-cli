import Foundation

/// Stage C: SIWC through the single settings writer (SIWC plan §3.9):
/// route-neutral save, token-free activation (D, staged when busy), cancel,
/// superseding, the type boundary and the lock order.
extension SIWCSelftest {
    @MainActor
    static func stageCWriterTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        let store = SIWCStore.resolved()
        let fake = FakeAuth()
        let signIn = SIWCSignIn(store: store, auth: fake.client, hostPaths: .live, ownerLease: { nil })

        func save(_ client: String, sub: String, tag: String, new: Bool) async throws -> SIWCSaveCommit {
            let attempt = try await signIn.start(port: 40100, expectedClientId: new ? nil : client, owner: nil, profile: "default")
            let result = SIWCSignInResult(clientId: client, newRegistration: new, tokens: tokens(tag), claims: claims(sub: sub))
            return await writer.commitSIWCSave(SIWCSaveRequest(result: result, attempt: attempt, signIn: signIn,
                                                               epoch: try ReplacementEpoch.read()))
        }

        // 1. Save a new login: route-neutral, nothing activated, journaled with per-record evidence.
        let writes0 = KeychainHelper._testWriteCount
        let savedA = try await save("oaiappWriterA", sub: "sub-wA", tag: "wA", new: true)
        let fileA = try store.readTokens()
        c.check("save: a new login is saved", { if case .saved(.saved) = savedA { return true }; return false }())
        c.check("save: route-neutral (no active pointer, no secrets write)", (try? store.readRegistrations())?.active == nil
                && KeychainHelper._testWriteCount == writes0)
        c.check("save: the record carries this attempt's effect mark", fileA?.record("oaiappWriterA")?.lastEffect != nil)
        let doc1 = try SettingsPendingStore.read()
        c.check("save: journal cleaned, result applied", doc1.attempts.isEmpty && doc1.lastResults.last?.state == "applied")

        // 2. Activation while idle: D, applied at the barrier.
        let change = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappWriterA", model: "gpt-6.1-sol", effort: "high",
                                                        textOnly: false, origin: "selftest", acceptPending: true)
        let encoded = String(data: try change.encoded(), encoding: .utf8) ?? ""
        c.check("activate: the prepared change carries no token", !encoded.contains("synthetic-access") && !encoded.contains("synthetic-refresh")
                && change.siwc?.replacementId == nil && change.siwc?.expectGeneration != nil)
        let barriers0 = owner.barriersTaken
        let r1 = await writer.commit(change)
        let secrets1 = KeychainHelper.loadSnapshot()
        let regs1 = try store.readRegistrations()
        c.check("activate: applied while idle", r1.state == .applied, "\(r1.state) \(r1.message ?? "")")
        c.check("activate: classified D (the barrier was taken)", owner.barriersTaken == barriers0 + 1)
        c.check("activate: the store's active pointer moves, with its effect mark", regs1?.active == "oaiappWriterA" && regs1?.activeLastEffect != nil)
        c.check("activate: the selection keys bind the record in use", secrets1[ChatGPTRoute.siwcGenerationKey] == fileA?.record("oaiappWriterA")?.generation
                && secrets1[ChatGPTRoute.routeKey] == "siwc" && secrets1[KeychainHelper.openAICompatibleApiKeyKey] == nil)
        c.check("activate: the secrets attempt marker and the pointer evidence name the same attempt",
                secrets1[SettingsWriter.attemptMarkerKey("ai")] == regs1?.activeLastEffect?.attempt)
        c.check("activate: the operation can capture its source", (try? ChatGPTRoute.currentSource()) != nil)

        // 3. Busy: a second login's activation is staged; tokens never reach settings-pending.json.
        _ = try await save("oaiappWriterB", sub: "sub-wB", tag: "wB", new: true)
        let changeB = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappWriterB", model: "gpt-6.1-sol", effort: nil,
                                                         textOnly: false, origin: "selftest", acceptPending: true)
        owner.busy = true
        let r2 = await writer.commit(changeB)
        let pendingText = (try? String(contentsOf: SettingsPendingStore.url, encoding: .utf8)) ?? ""
        c.check("busy: the activation is staged (saved, will switch when idle)", r2.state == .pending)
        c.check("busy: settings-pending.json holds no SIWC token", !pendingText.isEmpty && !pendingText.contains("synthetic-access")
                && !pendingText.contains("synthetic-refresh") && !pendingText.contains("synthetic.id"))
        c.check("busy: nothing moved meanwhile", (try? store.readRegistrations())?.active == "oaiappWriterA"
                && KeychainHelper.load(key: ChatGPTRoute.siwcRegistrationKey) == SIWCEndpoint.registrationFingerprint(clientId: "oaiappWriterA"))
        // 4. A later SIWC store write (another sign-in saved) supersedes the staged activation.
        _ = try await save("oaiappWriterC", sub: "sub-wC", tag: "wC", new: true)
        let doc2 = try SettingsPendingStore.read()
        c.check("supersede: a later SIWC store write drops the staged activation", doc2.slots["ai"]?.staged == nil
                && doc2.lastResults.contains { $0.state == "dropped" && $0.message == SettingsWriter.supersededMessage })
        c.check("supersede: the dropped login stays saved (not revoked)", (try? store.readTokens())?.record("oaiappWriterB")?.tokens != nil
                && fake.revoked.isEmpty)
        // 5. Staged again, then applied at the idle point.
        let changeB2 = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappWriterB", model: "gpt-6.1-sol", effort: nil,
                                                          textOnly: true, origin: "selftest", acceptPending: true)
        _ = await writer.commit(changeB2)
        owner.busy = false
        let applied = await writer.applyStaged(category: "ai")
        c.check("idle: the staged activation applies", applied?.state == .applied && (try? store.readRegistrations())?.active == "oaiappWriterB"
                && KeychainHelper.load(key: ChatGPTRoute.siwcRegistrationKey) == SIWCEndpoint.registrationFingerprint(clientId: "oaiappWriterB")
                && KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "true")
        // 6. An activation prepared from an older state never activates a later, different login.
        let stale = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappWriterC", model: "m", effort: nil, textOnly: false,
                                                       origin: "selftest", acceptPending: false)
        _ = try await store.tombstone("oaiappWriterC")
        let writes6 = KeychainHelper._testWriteCount
        let r6 = await writer.commit(stale)
        c.check("activate: prepared from an older record state → refused, nothing written",
                r6.state == .refused && KeychainHelper._testWriteCount == writes6 && (try? store.readRegistrations())?.active == "oaiappWriterB")
        // 7. Same registration while in use → staged replacement; activation promotes it (new generation).
        let before7 = try ChatGPTRoute.currentSource()
        let r7save = try await save("oaiappWriterB", sub: "sub-wB", tag: "wB-2", new: false)
        guard case .saved(.staged(_, _, let toBe)) = r7save else { c.check("replacement: staged", false, "\(r7save)"); return }
        c.check("replacement: the record in use is unchanged until activation", (try? store.readTokens())?.record("oaiappWriterB")?.tokens?.access == "synthetic-access-wB"
                && (try? store.validate(clientId: "oaiappWriterB", generation: before7!.generation)) != nil)
        SIWCFence.shared.fenceAndBump(before7!.fenceKey)   // a partial logout left a fence
        let promote = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappWriterB", model: "gpt-6.1-sol", effort: nil,
                                                         textOnly: false, origin: "selftest", acceptPending: true)
        c.check("replacement: the activation promotes it (token-free)", promote.siwc?.replacementId != nil && promote.siwc?.projectedGeneration == toBe)
        let r7 = await writer.commit(promote)
        c.check("replacement: promoted to a new generation", r7.state == .applied && (try? store.readTokens())?.record("oaiappWriterB")?.generation == toBe
                && KeychainHelper.load(key: ChatGPTRoute.siwcGenerationKey) == toBe)
        c.check("replacement: a captured operation never rebinds (its validation refuses)",
                (try? store.validate(clientId: "oaiappWriterB", generation: before7!.generation)) == nil)
        c.check("replacement: an admitted activation of a new generation clears the fence", !SIWCFence.shared.isFenced(before7!.fenceKey))
        // 8. Type boundary: a change that would carry a credential is never staged, journaled or applied.
        var smuggled = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappWriterB", model: "gpt-6.1-sol", effort: nil,
                                                          textOnly: false, origin: "selftest", acceptPending: true)
        smuggled.writes[ChatGPTRoute.siwcModelKey] = "synthetic-access-wB-2"
        c.check("boundary: staging refuses a change carrying an SIWC token", (try? SettingsWriter.stage(smuggled)) == nil)
        let writes8 = KeychainHelper._testWriteCount
        let r8 = await writer.commit(smuggled)
        c.check("boundary: committing refuses it, nothing written", r8.state == .refused && KeychainHelper._testWriteCount == writes8
                && ((try? SettingsPendingStore.read())?.attempts.isEmpty ?? false))
        var replied = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappWriterB", model: "gpt-6.1-sol", effort: nil,
                                                         textOnly: false, origin: "selftest", acceptPending: true)
        replied.reply = PreparedChange.jsonText(["ok": true, "echo": "synthetic-refresh-wB-2"])
        c.check("boundary: a reply carrying an SIWC token is refused", SIWCTypeBoundary.violation(replied) != nil)
        var credentialKey = replied; credentialKey.reply = nil; credentialKey.writes[ProviderProfiles.openaiApiKeyKey] = "sk-synthetic"
        c.check("boundary: an SIWC change cannot write a credential key", SIWCTypeBoundary.violation(credentialKey) != nil)
        c.check("boundary: the op type has no credential field",
                !String(data: try JSONEncoder().encode(promote.siwc!), encoding: .utf8)!.contains("credential"))
        // 9. Cancel: own pending → cancelled with reservation released; foreign → refused.
        let attempt9 = try await signIn.start(port: 40101, expectedClientId: nil, owner: nil, profile: "default")
        let r9 = await writer.commitSIWCCancel(store: store, profile: "default")
        c.check("cancel: this profile's pending sign-in is cancelled (S)", r9.state == .applied && (try? store.readTokens())?.pendingLogin == nil
                && !((try? SIWCHost.readReservations(.live))?.reservations.contains { $0.attemptId == attempt9.id } ?? true))
        _ = try await store.beginPending(owner: "health")
        let r9b = await writer.commitSIWCCancel(store: store, profile: "default")
        c.check("cancel: another assistant's pending sign-in is refused", r9b.state == .refused && (try? store.readTokens())?.pendingLoginBy == "health")
        _ = try await store.cancelOwnedPending(profile: "health")
        // 10. A save refused after a wipe/import epoch change revokes the issued tokens and writes nothing.
        let attempt10 = try await signIn.start(port: 40102, expectedClientId: nil, owner: nil, profile: "default")
        let result10 = SIWCSignInResult(clientId: "oaiappWriterD", newRegistration: true, tokens: tokens("wD"), claims: claims(sub: "sub-wD"))
        let epoch = try ReplacementEpoch.read()
        try ReplacementEpoch.advance()
        let r10 = await writer.commitSIWCSave(SIWCSaveRequest(result: result10, attempt: attempt10, signIn: signIn, epoch: epoch))
        c.check("save: refused after a wipe/import (epoch), tokens revoked, nothing saved",
                { if case .refused = r10 { return true }; return false }() && (try? store.readTokens())?.record("oaiappWriterD") == nil
                && fake.revoked.contains { $0.contains("synthetic-refresh-wD") })
        // 11. Lock order pin: legacy before SIWC before secrets.
        var order: [String] = []
        SettingsWriter.lockOrderForTesting = { order.append($0) }
        let lockA = root.appendingPathComponent("lock-legacy"), lockB = root.appendingPathComponent("lock-siwc")
        try PrivateStorage.ensureDirectory(lockA); try PrivateStorage.ensureDirectory(lockB)
        var inside = false
        try await SettingsWriter.withAuthLocks([lockA.path], siwc: [lockB.path]) {
            inside = (try? KeychainHelper.withStoreLock { _ in true }) == true
        }
        SettingsWriter.lockOrderForTesting = nil
        c.check("locks: legacy auth lock, then SIWC lock, then secrets.lock", order == ["legacy:" + lockA.path, "siwc:" + lockB.path] && inside)
        c.check("locks: an activation locks exactly its SIWC store", SettingsWriter.siwcStoresToLock(promote) == [store.directory.standardizedFileURL.path]
                && SettingsWriter.storesToLock(promote).isEmpty)
        try resetLive()
    }
}
