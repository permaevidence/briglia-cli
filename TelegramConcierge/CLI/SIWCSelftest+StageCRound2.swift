import Foundation

/// Codex stage-C round 2 (CHATGPT_SIWC_IMPL_C_CODEX_REVIEW_ROUND2): a
/// whitespace-prefixed reply, post-replacement logout and cancel, and the
/// per-attempt stopped-jobs count. (The real-turn final-delivery test is in
/// `__midturn-wake-selftest --only siwc`.)
extension SIWCSelftest {
    @MainActor
    static func stageCRound2Tests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        defer { PrivateStorage.failPostRenameBarrierForTesting = nil }
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        let store = SIWCStore.resolved()
        let fake = FakeAuth()
        let signIn = SIWCSignIn(store: store, auth: fake.client, hostPaths: .live, ownerLease: { nil })

        // Whitespace before a JSON reply (what the reply parser accepts).
        var slashed = tokens("ws"); slashed.access = "synthetic/opaque/access/ws-token"
        let attempt = try await signIn.start(port: 40300, expectedClientId: nil, owner: nil, profile: "default")
        _ = await writer.commitSIWCSave(SIWCSaveRequest(result: SIWCSignInResult(clientId: "oaiappWS", newRegistration: true, tokens: slashed,
            claims: claims(sub: "sub-ws")), attempt: attempt, signIn: signIn, epoch: try ReplacementEpoch.read()))
        var change = try SIWCSettings.prepareActivation(store: store, clientId: "oaiappWS", model: "gpt-6.1-sol", effort: nil,
                                                        textOnly: false, origin: "selftest", acceptPending: true)
        change.reply = " \n" + PreparedChange.jsonText(["ok": true, "message": slashed.access])!
        c.check("R2-1: a whitespace-prefixed reply carrying a token is refused", SIWCTypeBoundary.violation(change) != nil)
        c.check("R2-1: staging refuses it", (try? SettingsWriter.stage(change)) == nil)
        let committed = await writer.commit(change)
        c.check("R2-1: committing refuses it, nothing returned", committed.state == .refused && committed.reply == nil)

        // Logout whose tombstone is replaced but not durable.
        try resetLive()
        var (source, _) = try await liveSelection(clientId: "oaiappPostLogout", sub: "sub-pl")
        let tokenPath = source.store.tokenFile.standardizedFileURL.path
        var revoked: [String] = []
        PrivateStorage.failPostRenameBarrierForTesting = { $0 == tokenPath }
        let out = await writer.commitSIWCLogout(store: source.store, revoke: { t in revoked += t.revoke; return true })
        PrivateStorage.failPostRenameBarrierForTesting = nil
        c.check("R2-2: a visible but unconfirmed tombstone is partial, never 'not saved' and never a durable sign-out",
                out == .partial(SIWCLogoutOutcome.unconfirmedTombstoneMessage), "\(out)")
        c.check("R2-2: its revoke material survives the late error", revoked.contains("synthetic-refresh-live-oaiappPostLogout"))
        c.check("R2-2: the fence stays until a confirmed sign-out", SIWCFence.shared.isFenced(source.fenceKey)
                && (try? source.store.readTokens())?.record(source.clientId)?.tokens == nil)
        let retry = await writer.commitSIWCLogout(store: source.store, revoke: { _ in true })
        c.check("R2-2: a retry confirms the sign-out and clears the fence", retry == .signedOut(remoteConfirmed: true)
                && !SIWCFence.shared.isFenced(source.fenceKey))
        // Codex round 3: a refresh by another process between the writer's
        // early read and the tombstone lock (same generation, new tokens),
        // then a late write error: the NEW refresh token is revoked.
        for armed in [false, true] {
            (source, _) = try await liveSelection(clientId: "oaiappPostLogout", sub: "sub-pl")
            revoked = []
            let refreshed = "synthetic-refresh-concurrent-\(armed)"
            SettingsWriter.siwcBeforeTombstoneForTesting = {
                try rewriteBound(source.store, source.clientId) { $0.tokens?.refresh = refreshed; $0.tokens?.access = "synthetic-access-concurrent" }
                if armed { PrivateStorage.failPostRenameBarrierForTesting = { $0 == tokenPath } }
            }
            let result = await writer.commitSIWCLogout(store: source.store, revoke: { t in revoked += t.revoke; return true })
            SettingsWriter.siwcBeforeTombstoneForTesting = nil
            PrivateStorage.failPostRenameBarrierForTesting = nil
            c.check("R3: a refresh between the early read and the lock → its new token is revoked (\(armed ? "late write error" : "control"))",
                    revoked.contains(refreshed) && (armed ? result == .partial(SIWCLogoutOutcome.unconfirmedTombstoneMessage)
                                                          : result == .signedOut(remoteConfirmed: true)), "\(result) \(revoked)")
            if armed {
                let retry = await writer.commitSIWCLogout(store: source.store, revoke: { _ in true })
                c.check("R3: the retry after it confirms the sign-out", retry == .signedOut(remoteConfirmed: true))
            }
        }
        // Codex round 4: a NEWER sign-in (another generation, bound, as a
        // second process publishing and activating leaves it) between the
        // early read and the lock: a known refusal before any write. The
        // newer login stays saved and its tokens never reach revocation.
        for armed in [false, true] {
            (source, _) = try await liveSelection(clientId: "oaiappPostLogout", sub: "sub-pl")
            revoked = []
            let newer = "synthetic-refresh-newer-login-\(armed)"
            SettingsWriter.siwcBeforeTombstoneForTesting = {
                try rewriteBound(source.store, source.clientId) {
                    $0.generation = UUID().uuidString
                    $0.tokens?.refresh = newer; $0.tokens?.access = "synthetic-access-newer-login"
                }
                if armed { PrivateStorage.failPostRenameBarrierForTesting = { $0 == tokenPath } }
            }
            let result = await writer.commitSIWCLogout(store: source.store, expectedGeneration: source.generation,
                                                       revoke: { t in revoked += t.revoke; return true })
            SettingsWriter.siwcBeforeTombstoneForTesting = nil
            PrivateStorage.failPostRenameBarrierForTesting = nil
            let stored = (try? source.store.readTokens())?.record(source.clientId)
            c.check("R4: a newer sign-in before the lock → partial, nothing revoked, the newer login kept (\(armed ? "barrier armed" : "control"))",
                    result == .partial(SIWCLogoutOutcome.partialMessage) && revoked.isEmpty && stored?.tokens?.refresh == newer,
                    "\(result) \(revoked)")
            _ = await writer.commitSIWCLogout(store: source.store, revoke: { _ in true })
        }
        // Nothing replaced: the old partial wording, nothing revoked.
        (source, _) = try await liveSelection(clientId: "oaiappPostLogout", sub: "sub-pl")
        revoked = []
        SettingsWriter.siwcBeforeTombstoneForTesting = { throw SIWCError(.local, "synthetic") }
        let unchanged = await writer.commitSIWCLogout(store: source.store, revoke: { t in revoked += t.revoke; return true })
        SettingsWriter.siwcBeforeTombstoneForTesting = nil
        c.check("R2-2: a failure before the replacement keeps the login and revokes nothing",
                unchanged == .partial(SIWCLogoutOutcome.partialMessage) && revoked.isEmpty)
        writer.lastLogoutStoppedJobs = 7   // as left by an earlier attempt
        _ = await writer.commitSIWCLogout(store: source.store, expectedGeneration: UUID().uuidString, revoke: { _ in true })
        c.check("R2-2: the count belongs to the latest attempt", writer.lastLogoutStoppedJobs == 0)
        _ = await writer.commitSIWCLogout(store: source.store, revoke: { _ in true })

        // Cancel whose marker removal is replaced but not durable.
        let attempt2 = try await signIn.start(port: 40301, expectedClientId: nil, owner: nil, profile: "default")
        PrivateStorage.failPostRenameBarrierForTesting = { $0 == tokenPath }
        let cancelled = await writer.commitSIWCCancel(store: store, profile: "default")
        PrivateStorage.failPostRenameBarrierForTesting = nil
        c.check("R2-3: a visible but unconfirmed cancel is partial, not failed", cancelled.state == .partial, "\(cancelled.state) \(cancelled.message ?? "")")
        c.check("R2-3: the attempt's reservation is released and the marker gone",
                (try? store.readTokens())?.pendingLogin == nil
                && !((try? SIWCHost.readReservations(.live))?.reservations.contains { $0.attemptId == attempt2.id } ?? true))
        c.check("R2-3: the result is recorded", (try? SettingsPendingStore.read())?.lastResults.last?.state == "partial")
        try resetLive()
    }
}
