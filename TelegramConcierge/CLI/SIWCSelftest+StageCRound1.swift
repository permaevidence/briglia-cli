import Foundation

/// Codex stage-C round 1 (CHATGPT_SIWC_IMPL_C_CODEX_REVIEW_2026-11-07):
/// R1 token boundary (escaping, store dedupe), R2 truthful reporting after a
/// replacement, R3 logout admission during the write-free wait.
extension SIWCSelftest {
    @MainActor
    static func stageCRound1Tests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        let store = SIWCStore.resolved()
        let fake = FakeAuth()
        let signIn = SIWCSignIn(store: store, auth: fake.client, hostPaths: .live, ownerLease: { nil })
        func save(_ client: String, sub: String, tokens t: SIWCTokens, new: Bool) async throws -> SIWCSaveCommit {
            let attempt = try await signIn.start(port: 40200, expectedClientId: new ? nil : client, owner: nil, profile: "default")
            return await writer.commitSIWCSave(SIWCSaveRequest(result: SIWCSignInResult(clientId: client, newRegistration: new, tokens: t,
                claims: claims(sub: sub)), attempt: attempt, signIn: signIn, epoch: try ReplacementEpoch.read()))
        }
        defer { PrivateStorage.failPostRenameBarrierForTesting = nil }

        // R1a: a token JSON would escape ("/") is still found.
        var slashed = tokens("slash"); slashed.access = "synthetic/opaque/access/probe-token"
        _ = try await save("oaiappR1A", sub: "sub-r1a", tokens: slashed, new: true)
        var smuggled = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappR1A", model: slashed.access, effort: nil,
                                                          textOnly: false, origin: "selftest", acceptPending: true)
        c.check("R1: a token JSON escapes is still refused (model value)", SIWCTypeBoundary.violation(smuggled) != nil)
        c.check("R1: staging refuses it", (try? SettingsWriter.stage(smuggled)) == nil
                && ((try? SettingsPendingStore.read())?.slots["ai"]?.staged == nil))
        smuggled = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappR1A", model: "gpt-6.1-sol", effort: nil,
                                                      textOnly: false, origin: "selftest", acceptPending: true)
        smuggled.reply = PreparedChange.jsonText(["ok": true, "message": slashed.access])
        let r1 = await writer.commit(smuggled)
        c.check("R1: a reply carrying an escaped token is refused, nothing returned", r1.state == .refused && r1.reply == nil)
        // R1b: a store listed twice never hides another store's tokens.
        let a = SIWCStore(directory: root.appendingPathComponent("r1-shared")), b = SIWCStore(directory: root.appendingPathComponent("r1-own"))
        let pa = hostPaths(root.appendingPathComponent("r1-host"), stores: [a.directory, b.directory])
        _ = try await Self.signIn(a, pa, clientId: "oaiappR1Shared", sub: "s-shared", new: true, tokens: tokens("r1-shared"))
        _ = try await Self.signIn(b, pa, clientId: "oaiappR1Own", sub: "s-own", new: true, tokens: tokens("r1-own"))
        c.check("R1: the boundary's token set survives a duplicated store", SIWCTypeBoundary.tokens(in: [a.directory, b.directory, a.directory])
                .contains("synthetic-access-r1-own"))
        c.check("R1: redaction labels do not collide either", Set(CredentialCatalog.siwcRedactionValues([a.directory, b.directory, a.directory]).values)
                .contains("synthetic-access-r1-own"))
        c.check("R1: no length heuristic (any stored token value counts)", SIWCTypeBoundary.tokens(in: [a.directory]).contains("synthetic.id.r1-shared"))

        // R2a: activation whose promotion is replaced but not durable, pointer write refused → partial, truthful.
        try resetLive()
        _ = try await save("oaiappR2", sub: "sub-r2", tokens: tokens("r2"), new: true)
        _ = await writer.commit(try SIWCSettings.prepareActivation(store: store, clientId: "oaiappR2", model: "gpt-6.1-sol", effort: nil,
                                                                   textOnly: false, origin: "selftest", acceptPending: true))
        let boundBefore = KeychainHelper.load(key: ChatGPTRoute.siwcGenerationKey)
        guard case .saved(.staged(_, _, let toBe)) = try await save("oaiappR2", sub: "sub-r2", tokens: tokens("r2-next"), new: false) else {
            c.check("R2: fixture", false); return
        }
        let promote = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappR2", model: "gpt-6.1-sol", effort: nil,
                                                         textOnly: false, origin: "selftest", acceptPending: true)
        let tokenPath = store.tokenFile.standardizedFileURL.path
        PrivateStorage.failPostRenameBarrierForTesting = { $0 == tokenPath }
        let r2 = await writer.commit(promote)
        PrivateStorage.failPostRenameBarrierForTesting = nil
        let after = try? store.readTokens()?.record("oaiappR2")
        c.check("R2: promotion visible but pointer/settings not written → partial, never 'interrupted before saving'",
                r2.state == .partial && !(r2.message ?? "").contains("interrupted before saving"), "\(r2.state) \(r2.message ?? "")")
        c.check("R2: the store shows the promotion; the binding is unchanged (next operation rebinds)",
                after?.generation == toBe && KeychainHelper.load(key: ChatGPTRoute.siwcGenerationKey) == boundBefore)
        c.check("R2: the result is recorded as partial", (try? SettingsPendingStore.read())?.lastResults.last?.state == "partial")
        // R2b: every effect visible, durability unconfirmed → applied with the note, settings saved.
        guard case .saved(.staged) = try await save("oaiappR2", sub: "sub-r2", tokens: tokens("r2-third"), new: false) else {
            c.check("R2: fixture b", false); return
        }
        let promote2 = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappR2", model: "gpt-6.1-sol", effort: nil,
                                                          textOnly: false, origin: "selftest", acceptPending: true)
        let regPath = store.registrationsFile.standardizedFileURL.path
        PrivateStorage.failPostRenameBarrierForTesting = { $0 == regPath }
        let r2b = await writer.commit(promote2)
        PrivateStorage.failPostRenameBarrierForTesting = nil
        c.check("R2: all effects visible but not confirmed durable → applied with that note, binding moved",
                r2b.state == .applied && ((r2b.reply?["note"] as? String) ?? "").contains("did not confirm")
                && KeychainHelper.load(key: ChatGPTRoute.siwcGenerationKey) == promote2.siwc?.projectedGeneration, "\(r2b.state) \(r2b.message ?? "")")
        // R2c: a save whose token file is replaced but not durable → published, never revoked.
        let revokedBefore = fake.revoked.count
        let attemptC = try await signIn.start(port: 40201, expectedClientId: nil, owner: nil, profile: "default")
        PrivateStorage.failPostRenameBarrierForTesting = { $0 == tokenPath }
        let r2c = await writer.commitSIWCSave(SIWCSaveRequest(result: SIWCSignInResult(clientId: "oaiappR2Save", newRegistration: true,
            tokens: tokens("r2-save"), claims: claims(sub: "sub-r2s")), attempt: attemptC, signIn: signIn, epoch: try ReplacementEpoch.read()))
        PrivateStorage.failPostRenameBarrierForTesting = nil
        c.check("R2: a visible but unconfirmed save is reported as such, not as failed",
                { if case .savedUnconfirmed(.saved) = r2c { return true }; return false }(), "\(r2c)")
        c.check("R2: a published login is never revoked", fake.revoked.count == revokedBefore
                && (try? store.readTokens())?.record("oaiappR2Save")?.tokens?.access == "synthetic-access-r2-save")
        // R2d: own → shared retirement replaced but not durable → retired (unconfirmed) with revoke material.
        let own = SIWCStore(directory: root.appendingPathComponent("r2-own"))
        let po = hostPaths(root.appendingPathComponent("r2-own-host"), stores: [own.directory])
        _ = try await Self.signIn(own, po, clientId: "oaiappR2Own", sub: "sub-r2o", new: true, tokens: tokens("r2-own"))
        let old = try own.readTokens()
        let fp = SIWCEndpoint.registrationFingerprint(clientId: "oaiappR2Own")
        let effect = SIWCJournalEffect(effectId: UUID().uuidString, kind: .retire, storePath: own.directory.path, file: "tokens", targets: [fp],
                                       oldEvidence: [fp: .record(old?.record("oaiappR2Own"))])
        let ownPath = own.tokenFile.standardizedFileURL.path
        PrivateStorage.failPostRenameBarrierForTesting = { $0 == ownPath }
        let r2d = await SIWCScopeRetire.retire(own, effect: effect, attempt: UUID().uuidString, old: old)
        PrivateStorage.failPostRenameBarrierForTesting = nil
        if case .retiredUnconfirmed(let material) = r2d {
            c.check("R2: scope retirement visible but unconfirmed → retired (unconfirmed), never 'not signed out'",
                    (try? own.readTokens())?.record("oaiappR2Own")?.tokens == nil)
            c.check("R2: revoke material survives the late error", material.first?.revoke.contains("synthetic-refresh-r2-own") == true)
        } else {
            c.check("R2: scope retirement visible but unconfirmed → retired (unconfirmed), never 'not signed out'", false, "\(r2d)")
            c.check("R2: revoke material survives the late error", false)
        }
        let untouched = SIWCStore(directory: root.appendingPathComponent("r2-own-b"))
        _ = try await Self.signIn(untouched, hostPaths(root.appendingPathComponent("r2-own-b-host"), stores: [untouched.directory]),
                             clientId: "oaiappR2OwnB", sub: "sub-r2ob", new: true, tokens: tokens("r2-ownb"))
        let oldB = try untouched.readTokens()
        let fpB = SIWCEndpoint.registrationFingerprint(clientId: "oaiappR2OwnB")
        var failing = untouched; failing.beforeTokenWrite = { throw SIWCError(.local, "synthetic pre-replace failure") }
        let effectB = SIWCJournalEffect(effectId: UUID().uuidString, kind: .retire, storePath: untouched.directory.path, file: "tokens", targets: [fpB],
                                        oldEvidence: [fpB: .record(oldB?.record("oaiappR2OwnB"))])
        let r2e = await SIWCScopeRetire.retire(failing, effect: effectB, attempt: UUID().uuidString, old: oldB)
        c.check("R2: a failure before the replacement is 'not retired'", { if case .notRetired = r2e { return true }; return false }(), "\(r2e)")

        // R3: admission closes during the write-free wait → refused, nothing interrupted.
        try resetLive()
        let (source, _) = try await liveSelection(clientId: "oaiappR3", sub: "sub-r3")
        let running = Hanging(); running.start(source); await running.waitStarted()
        let epochBefore = SIWCFence.shared.epoch(source.fenceKey)
        let holder = Task.detached { try await source.store.locked { try await Task.sleep(nanoseconds: 700_000_000) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let logout = Task { @MainActor in await writer.commitSIWCLogout(store: source.store, revoke: { _ in true }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let prevalidation = writer.gate.isHeld && !writer.gate.holderInterrupting
        let closedAt = Date()
        writer.gate.closeAdmission(reason: "probe lifecycle")
        let r3 = await logout.value
        let promptly = Date().timeIntervalSince(closedAt) < 0.4
        _ = try? await holder.value
        writer.gate.reopenAdmission()
        c.check("R3: the logout was still in its write-free wait", prevalidation)
        c.check("R3: the wait is cancelled at once by the lifecycle operation", promptly)
        c.check("R3: admission closed during validation → refused (not partial)", { if case .refused = r3 { return true }; return false }(), "\(r3)")
        c.check("R3: nothing interrupted, no fence, no epoch bump", !running.isFinished && !SIWCFence.shared.isFenced(source.fenceKey)
                && SIWCFence.shared.epoch(source.fenceKey) == epochBefore)
        // The second layer alone: owner admission refused during the wait
        // (no gate cancellation) → refused by the recheck before fencing.
        let holder2 = Task.detached { try await source.store.locked { try await Task.sleep(nanoseconds: 300_000_000) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let logout2 = Task { @MainActor in await writer.commitSIWCLogout(store: source.store, revoke: { _ in true }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        owner.admission = "probe restore"
        let r3b = await logout2.value
        _ = try? await holder2.value
        owner.admission = nil
        c.check("R3: admission refused during the wait is rechecked before the fence (refused, no epoch bump)",
                { if case .refused = r3b { return true }; return false }() && !running.isFinished
                && SIWCFence.shared.epoch(source.fenceKey) == epochBefore, "\(r3b)")
        running.task?.cancel()

        // Jobs (§3.7/§3.9 R2): an operation between model requests (tool
        // work) is cancelled by the sign-out and drained, not left running.
        let (jobSource, _) = try await liveSelection(clientId: "oaiappJobs", sub: "sub-jobs")
        final class Flag: @unchecked Sendable { var ended = false; var cancelled = false }
        let flag = Flag()
        let job = Task.detached {
            let token = try? SIWCFence.shared.registerCurrentTask(jobSource)
            defer { SIWCFence.shared.unregisterJob(token ?? nil) }
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }   // "tool work"
            flag.cancelled = Task.isCancelled
            try? await Task.sleep(nanoseconds: 100_000_000)                                // its own cleanup
            flag.ended = true
        }
        let other = SIWCCredentialSource(storeDirectory: root.appendingPathComponent("jobs-other"), clientId: "oaiappJobsOther",
                                         generation: UUID().uuidString, epoch: 0, identityFingerprint: String(repeating: "d", count: 64))
        let otherJob = Task.detached {
            let token = try? SIWCFence.shared.registerCurrentTask(other)
            defer { SIWCFence.shared.unregisterJob(token ?? nil) }
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        for _ in 0..<100 where SIWCFence.shared.jobCount(jobSource.fenceKey) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        c.check("jobs: an operation of the login is registered as a job", SIWCFence.shared.jobCount(jobSource.fenceKey) == 1)
        let out = await writer.commitSIWCLogout(store: jobSource.store, revoke: { _ in true })
        c.check("jobs: the sign-out cancels a job in tool work and waits for it to end", out == .signedOut(remoteConfirmed: true)
                && flag.cancelled && flag.ended && SIWCFence.shared.jobCount(jobSource.fenceKey) == 0)
        c.check("jobs: the sign-out reports how many running jobs it stopped", writer.lastLogoutStoppedJobs == 1)
        c.check("jobs: a job of another login keeps running", SIWCFence.shared.jobCount(other.fenceKey) == 1)
        otherJob.cancel(); _ = await job.value; _ = await otherJob.value
        // A fenced (partially signed-out) login refuses new jobs at once.
        let (fencedSource, _) = try await liveSelection(clientId: "oaiappJobs", sub: "sub-jobs")
        SIWCFence.shared.fenceAndBump(fencedSource.fenceKey)
        c.check("jobs: a fenced login refuses to start a job", (try? SIWCFence.shared.registerCurrentTask(fencedSource)) == nil)
        try resetLive()
    }
}
