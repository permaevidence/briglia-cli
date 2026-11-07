import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Codex round 1 (CHATGPT_SIWC_IMPL_AB_CODEX_REVIEW_2026-11-06): each
/// reproduction R1–R8 turned into an assertion of the required behaviour.
extension SIWCSelftest {
    static func round1Tests(_ root: URL, _ c: Checks) async throws {
        let client = "oaiappClientA"
        // R1 (a): an edit that keeps the old MAC string, made during the send.
        let (s1, _, g1) = try await activeStore(root, tokens: tokens("R1", expiresIn: 10))
        var r1Error: SIWCError?
        do {
            _ = try await s1.credential(clientId: client, generation: g1) { refresh in
                try tamper(s1, client) { $0.tokens?.access = "synthetic-tampered-access" }
                return rotated(refresh, tag: "R1-received")
            }
        } catch let e as SIWCError { r1Error = e }
        let disk1 = s1.readTokens_unsafe(client)
        c.check("R1: a record edited during the refresh is never activated", r1Error?.kind == .signInRequired
                && disk1?.tokens?.access == "synthetic-tampered-access")
        c.check("R1: the received refresh token is kept for revocation only", disk1?.cleanup?.contains("synthetic-refresh-R1-R1-received") == true)
        c.check("R1: the edited record stays unusable (never repaired)", (try? s1.validate(clientId: client, generation: g1)) == nil)
        // R1 (b): a legitimately rebound replacement during the send.
        let (s1b, _, g1b) = try await activeStore(root, tokens: tokens("R1B", expiresIn: 10))
        let refused1b = (try? await s1b.credential(clientId: client, generation: g1b) { refresh in
            try rewriteBound(s1b, client) { $0.tokens?.access = "synthetic-rebound-access" }
            return rotated(refresh, tag: "R1B-received")
        }) == nil
        let disk1b = s1b.readTokens_unsafe(client)
        c.check("R1: a rebound replacement during the refresh is kept, the received set is not activated",
                refused1b && disk1b?.tokens?.access == "synthetic-rebound-access" && disk1b?.cleanup?.contains("synthetic-refresh-R1B-R1B-received") == true
                && (try? s1b.validate(clientId: client, generation: g1b)) != nil)
        // R2: another account's tokens, rejection write failing after the checkpoint.
        let (s2, _, g2) = try await activeStore(root, tokens: tokens("R2", expiresIn: 10))
        let writes = Sends()
        var failing = s2
        failing.beforeTokenWrite = { writes.add(); if writes.value >= 3 { throw SIWCError(.local, "injected disk failure after checkpoint") } }
        _ = try? await failing.credential(clientId: client, generation: g2) { _ in
            SIWCRefreshed(tokens: tokens("OTHER-ACCOUNT"), claims: claims(sub: "other-sub", account: "other-account"))
        }
        let checkpointed = s2.readTokens_unsafe(client)?.pendingRotation != nil
        let sends2 = Sends()
        let promoted = try? await s2.credential(clientId: client, generation: g2) { _ in sends2.add(); throw SIWCError(.local, "unexpected network") }
        c.check("R2: a checkpoint of another account's tokens is never promoted after a restart", checkpointed && promoted == nil
                && sends2.value == 0 && (try? s2.validate(clientId: client, generation: g2)) == nil)
        c.check("R2: the foreign refresh token is kept for revocation", s2.readTokens_unsafe(client)?.cleanup?.contains("synthetic-refresh-OTHER-ACCOUNT") == true)
        // R2 (b): lost plan usage at the same boundary.
        let (s2b, _, g2b) = try await activeStore(root, tokens: tokens("R2B", expiresIn: 10))
        let writesB = Sends()
        var failingB = s2b
        failingB.beforeTokenWrite = { writesB.add(); if writesB.value >= 3 { throw SIWCError(.local, "injected") } }
        _ = try? await failingB.credential(clientId: client, generation: g2b) { r in
            var t = tokens("NOPLAN", plan: false); t.refresh = r + "-noplan"; return SIWCRefreshed(tokens: t, claims: nil)
        }
        let promotedB = try? await s2b.credential(clientId: client, generation: g2b) { _ in throw SIWCError(.local, "unexpected network") }
        c.check("R2: a checkpoint that lost plan usage is never promoted", promotedB == nil && (try? s2b.validate(clientId: client, generation: g2b)) == nil)
        // R3: a fence between the caller's last check and admission → nothing sent.
        let (source3, _) = try await liveSelection(clientId: "oaiappR1Fence")
        let context = ProviderExecutionContext.siwcContext(source: source3, model: "gpt-6.1-sol", effort: nil, lane: .main, textOnly: false, nativeToolMedia: false)
        var request = try ResponsesAdapter(context: context).siwcRequest(input: [user("x")], tools: nil)
        request.setValue("Bearer synthetic-access", forHTTPHeaderField: "Authorization")
        try ResponsesAdapter.siwcPreSend(source3, request: request)
        let orphanSends = Sends()
        ResponsesAdapter.siwcSendOverride = { _ in orphanSends.add(); return completed() }
        SIWCFence.shared.fenceAndBump(source3.fenceKey)
        var refused3 = false
        do { _ = try await ResponsesAdapter.siwcTransportSend(source3, request: request, context: context, overallTimeout: 10,
                                                              connectTimeout: nil, idleTimeout: nil, transport: ResponsesHTTPTransport()) }
        catch { refused3 = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        c.check("R3: a send fenced before admission never starts", refused3 && orphanSends.value == 0)
        // R3 (b): cancellation racing the task installation still cancels it.
        let (source3b, _) = try await liveSelection(clientId: "oaiappR1Race")
        let started3b = Sends()
        ResponsesAdapter.siwcSendOverride = { _ in started3b.add(); try await Task.sleep(nanoseconds: 2_000_000_000); return completed() }
        let race = Task { try await ResponsesAdapter.siwcTransportSend(source3b, request: request, context: nil, overallTimeout: 10,
                                                                       connectTimeout: nil, idleTimeout: nil, transport: ResponsesHTTPTransport()) }
        while SIWCFence.shared.inflightCount(source3b.fenceKey) == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        SIWCFence.shared.fenceAndBump(source3b.fenceKey)
        SIWCFence.shared.cancelAll(source3b.fenceKey)
        let raceResult = await race.result
        c.check("R3: a registered send is cancelled by the sign-out, outcome signed out",
                { if case .failure(let e as SIWCError) = raceResult { return e.kind == .signedOut }; return false }())
        // R4: /v1/models is registered, cancelled, and never cached after logout.
        let (source4, _) = try await liveSelection(clientId: "oaiappR1Models")
        SIWCModels.resetForTests()
        let started = Sends()
        SIWCModels.fetchOverride = { _ in
            started.add()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return (Data(#"{"models":[{"slug":"gpt-6-luna","visibility":"list"}]}"#.utf8), 200)
        }
        let modelsTask = Task { try await SIWCModels.fetch(source4) }
        while started.value == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        let registered = SIWCFence.shared.inflightCount(source4.fenceKey)
        SIWCFence.shared.fenceAndBump(source4.fenceKey)
        let cancelled = SIWCFence.shared.cancelAll(source4.fenceKey)
        let models = try? await modelsTask.value
        c.check("R4: the models fetch is registered and cancelled by a sign-out", registered == 1 && cancelled == 1)
        c.check("R4: no models result and no cache after the sign-out", models == nil && SIWCModels.cached(source4) == nil)
        // R5: a web run's route is captured once; a later account switch does not rebind it.
        _ = try await liveSelection(clientId: "oaiappR1WebA", sub: "web-sub-A")
        let capturedA = SIWCOperationCapture.capture()
        SIWCModels.resetForTests()
        SIWCModels.fetchOverride = { _ in (Data(#"{"models":[{"slug":"gpt-6-luna","visibility":"list"}]}"#.utf8), 200) }
        let wire = Wire(); wire.install()
        wire.replies = [.success(completed()), .success(completed())]
        let lane = AffinityLane.ephemeral(UUID())
        let body: [String: JSONValue] = ["model": .string("gpt-6-luna"), "input": .array([user("round")])]
        _ = try await SubscriptionWebTransport.post(body: body, lane: lane, timeout: 10, operation: capturedA)
        let (sourceB, _) = try await liveSelection(clientId: "oaiappR1WebB", sub: "web-sub-B")
        _ = try await SubscriptionWebTransport.post(body: body, lane: lane, timeout: 10, operation: capturedA)
        c.check("R5: every round of a web run uses the source captured at its start", wire.count == 2
                && wire.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access-live-oaiappR1WebA" })
        if case .source(let a) = capturedA { _ = try await a.store.tombstone(a.clientId) }
        let beforeTomb = wire.count
        wire.replies = [.success(completed())]
        c.check("R5: a run whose captured login was signed out does not rebind to the new account",
                (try? await SubscriptionWebTransport.post(body: body, lane: lane, timeout: 10, operation: capturedA)) == nil && wire.count == beforeTomb)
        c.check("R5: a run captured on the legacy route never switches to SIWC mid-run", {
            if case .notSIWC = SIWCOperationCapture.capture(stored: [ProviderProfiles.activeProfileKey: "chatgpt"]) { return true }; return false }())
        _ = sourceB
        // R6: identity-only grant (P4a).
        let noRefresh = Data(#"{"access_token":"synthetic-identity-only","id_token":"synthetic.id.token","token_type":"Bearer","expires_in":3600,"scope":"openid profile email"}"#.utf8)
        let parsed = try? SIWCSignIn.parseTokens(noRefresh, now: Int(Date().timeIntervalSince1970), previousScopes: nil)
        c.check("R6: an identity-only response parses with no plan credential", parsed != nil && parsed?.0 == nil)
        let planNoRefresh = Data(#"{"access_token":"a","token_type":"Bearer","expires_in":3600,"scope":"openid offline_access chatgpt.tokens.use.direct"}"#.utf8)
        c.check("R6: a plan grant without a refresh token is still refused", (try? SIWCSignIn.parseTokens(planNoRefresh, now: 0, previousScopes: nil)) == nil)
        let s6 = SIWCStore(directory: root.appendingPathComponent("identity-only"))
        let p6 = hostPaths(root.appendingPathComponent("identity-only-host"), stores: [s6.directory])
        let pending6 = try await s6.beginPending(owner: nil)
        let host6 = try SIWCHost.reserve(p6, attemptId: "r6", profile: "default", storePath: s6.directory.path, ownerLease: nil, now: s6.nowSeconds)
        let saved6 = try await s6.save(SIWCSignInResult(clientId: "oaiappIdentity", newRegistration: true, tokens: nil, claims: claims()),
                                       pending: pending6, attemptId: "r6", hostFingerprint: host6.fingerprint, hostPaths: p6)
        if case .saved(_, let g6) = saved6 {
            c.check("R6: the verified registration is saved with plan usage off", try! s6.readRegistrations()?.registrations.first?.planUsageEnabled == false)
            await c.rejectsKind("R6: plan usage off sends nothing", .planUsageOff) { try s6.validate(clientId: "oaiappIdentity", generation: g6) }
        } else { c.check("R6: the verified registration is saved with plan usage off", false) }
        let (sIn, pIn, gIn) = try await activeStore(root)
        await c.rejectsKind("R6: an identity-only re-sign-in never downgrades the login in use", .planUsageOff) {
            let pending = try await sIn.beginPending(owner: nil)
            let host = try SIWCHost.reserve(pIn, attemptId: "r6b", profile: "default", storePath: sIn.directory.path, ownerLease: nil, now: sIn.nowSeconds)
            _ = try await sIn.save(SIWCSignInResult(clientId: client, newRegistration: false, tokens: nil, claims: claims()),
                                   pending: pending, attemptId: "r6b", hostFingerprint: host.fingerprint, hostPaths: pIn)
        }
        c.check("R6: the login in use still works", (try? sIn.validate(clientId: client, generation: gIn)) != nil)
        // R7: the recovery records are bound.
        let (s7, _, g7) = try await activeStore(root, tokens: tokens("R7", expiresIn: 10))
        let sends7 = Sends()
        for _ in 0..<2 { _ = try? await s7.credential(clientId: client, generation: g7) { _ in sends7.add(); throw URLError(.networkConnectionLost) } }
        try tamper(s7, client) { $0.refreshOp = nil; $0.refreshRecovery = nil }
        c.check("R7: clearing the recovery records breaks the binding", (try? s7.validate(clientId: client, generation: g7)) == nil)
        _ = try? await s7.credential(clientId: client, generation: g7) { r in sends7.add(); return rotated(r) }
        c.check("R7: no third send of the same refresh token", sends7.value == 2)
        // Deviation 4: an expired token before earliest_refresh_at is not refreshed without a 401.
        let now = Int(Date().timeIntervalSince1970)
        let (sE, _, gE) = try await activeStore(root, tokens: tokens("E2", expiresIn: -5, earliest: now + 600))
        let sendsE = Sends()
        _ = try? await sE.credential(clientId: client, generation: gE) { r in sendsE.add(); return rotated(r) }
        c.check("dev4: never before earliest_refresh_at without a 401, even when expired", sendsE.value == 0)
        // Deviation 6: definitive catalogue failures propagate; transient ones don't.
        let (source6, _) = try await liveSelection(clientId: "oaiappR1List")
        SIWCModels.resetForTests()
        SIWCModels.fetchOverride = { _ in (Data(#"{"error":{"code":"user_not_eligible"}}"#.utf8), 403) }
        await c.rejectsKind("dev6: a definitive refusal of the model list stops the lane", .notAvailable) { try await SIWCModels.requireListed("gpt-6-luna", source: source6) }
        SIWCModels.fetchOverride = { _ in (Data(), 502) }
        c.check("dev6: a temporarily unavailable list lets the request decide", (try? await SIWCModels.requireListed("gpt-6-luna", source: source6)) != nil)
    }

    /// R8 with the production `.live` resolver, under the temporary XDG roots.
    static func round1HostTests(_ root: URL, _ c: Checks) async throws {
        let name = "r8-orphan"
        let store = SIWCStore(directory: AssistantProfile.extraConfigRoot(name))
        try PrivateStorage.ensureDirectory(store.directory)
        let meta = AssistantProfile.Metadata(version: 1, name: name, displayName: "Test", createdAt: Date(), homeFolder: root.path, template: nil)
        _ = try PrivateStorage.writeAtomically(try AssistantProfile.encodeMetadata(meta), to: AssistantProfile.metadataURL(name))
        let paths = SIWCHost.Paths.live
        _ = try await signIn(store, paths, clientId: "oaiappHiddenHost", new: true, tokens: tokens("host"))
        c.check("R8: a valid extra keeps the host", try SIWCHost.removeIfUnused(paths, now: store.nowSeconds) == .keptInUse)
        _ = try PrivateStorage.writeAtomically(Data("{}".utf8), to: AssistantProfile.metadataURL(name))
        c.check("R8: an extra with corrupt metadata still counts (host kept)", try SIWCHost.removeIfUnused(paths, now: store.nowSeconds) == .keptInUse
                && (try? store.readRegistrations()?.registrations.count) == 1)
        try FileManager.default.removeItem(at: AssistantProfile.metadataURL(name))
        c.check("R8: an extra with missing metadata still counts", try SIWCHost.removeIfUnused(paths, now: store.nowSeconds) == .keptInUse)
        // An extras root that cannot be enumerated is uncertain (nil), never "no extras".
        let odd = root.appendingPathComponent("odd-config")
        try PrivateStorage.ensureDirectory(odd)
        _ = try PrivateStorage.writeAtomically(Data("not a directory".utf8), to: odd.appendingPathComponent(AssistantProfile.extrasDirName))
        c.check("R8: an unreadable extras root makes the census uncertain", SIWCHost.Paths.liveStoreDirectories(environment: ["XDG_CONFIG_HOME": odd.path]) == nil)
        let empty = root.appendingPathComponent("empty-config")
        try PrivateStorage.ensureDirectory(empty)
        c.check("R8: no extras root means no extras", SIWCHost.Paths.liveStoreDirectories(environment: ["XDG_CONFIG_HOME": empty.path])?.count == 1)
        _ = try await store.retireAll()
        _ = try store.removeFiles()
        try? FileManager.default.removeItem(at: store.directory)
    }
}
