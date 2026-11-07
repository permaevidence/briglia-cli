import Foundation

extension SIWCSelftest {
    /// Save vs activation (§3.9 R3), staged replacements, tombstones,
    /// retirement in one replacement, per-record evidence (R4).
    static func loginTests(_ root: URL, _ c: Checks) async throws {
        let (store, paths, g1) = try await activeStore(root)
        c.check("login: activation sets the store's active registration", try store.readRegistrations()?.active == "oaiappClientA")
        // Same registration while in use → staged replacement.
        let effect1 = SIWCEffectMark(attempt: UUID().uuidString, effectId: UUID().uuidString)
        let outcome = try await signIn(store, paths, clientId: "oaiappClientA", new: false, tokens: tokens("A2"), effect: effect1)
        guard case .staged(_, let replacementId, let toBe) = outcome else { c.check("login: in-use re-sign-in is staged", false); return }
        c.check("login: in-use re-sign-in is staged, not activated", true)
        c.check("login: the record in use keeps its generation and tokens", (try? store.validate(clientId: "oaiappClientA", generation: g1)) != nil
                && store.readTokens_unsafe("oaiappClientA")?.tokens?.access == "synthetic-access-A")
        c.check("login: the staged tokens are inside the record's binding", store.readTokens_unsafe("oaiappClientA")?.staged?.tokens.access == "synthetic-access-A2"
                && (try? store.validate(clientId: "oaiappClientA", generation: g1)) != nil)
        c.check("login: the record carries the save's own effect mark", store.readTokens_unsafe("oaiappClientA")?.lastEffect == effect1)
        // Refresh never promotes a staged replacement.
        let fake = FakeAuth(); fake.tokenReplies = [tokenReply("R")]
        var expiring = store; expiring.clock = { Date().addingTimeInterval(3600) }
        _ = try? await expiring.credential(clientId: "oaiappClientA", generation: g1,
            refresh: { _ in SIWCRefreshed(tokens: tokens("R", now: Int(Date().timeIntervalSince1970) + 3600), claims: nil) })
        c.check("login: refresh settlement keeps a waiting staged replacement", store.readTokens_unsafe("oaiappClientA")?.staged?.replacementId == replacementId)
        // A newer sign-in replaces the waiting one; the older refresh goes to cleanup.
        let outcome2 = try await signIn(store, paths, clientId: "oaiappClientA", new: false, tokens: tokens("A3"))
        guard case .staged(_, let replacement2, let toBe2) = outcome2 else { c.check("login: newer staged", false); return }
        let rec = store.readTokens_unsafe("oaiappClientA")
        c.check("login: a newer sign-in replaces the waiting replacement", rec?.staged?.replacementId == replacement2
                && rec?.cleanup?.contains("synthetic-refresh-A2") == true)
        await c.rejects("login: activating the superseded replacement is refused") {
            _ = try await store.activate(.init(clientId: "oaiappClientA", generation: nil, replacementId: replacementId))
        }
        _ = toBe
        let effect2 = SIWCEffectMark(attempt: UUID().uuidString, effectId: UUID().uuidString)
        let g2 = try await store.activate(.init(clientId: "oaiappClientA", generation: nil, replacementId: replacement2), effect: effect2)
        c.check("login: activation promotes the replacement with its prepared generation", g2 == toBe2 && g2 != g1)
        await c.rejectsKind("login: an operation that captured the old generation is refused (never rebinds)", .signInRequired) {
            try store.validate(clientId: "oaiappClientA", generation: g1)
        }
        c.check("login: the new generation is usable", (try? store.validate(clientId: "oaiappClientA", generation: g2)) != nil)
        c.check("login: the pointer change carries its own evidence", try store.readRegistrations()?.activeLastEffect == effect2)
        await c.rejects("login: an activation prepared from an older state is refused") {
            _ = try await store.activate(.init(clientId: "oaiappClientA", generation: g1, replacementId: nil))
        }
        // A second registration saved while A is active: route-neutral.
        let saveB = try await signIn(store, paths, clientId: "oaiappClientB", sub: "user-sub-B", new: true, tokens: tokens("B"))
        c.check("login: saving another registration never moves the pointer", try store.readRegistrations()?.active == "oaiappClientA"
                && { if case .saved = saveB { return true }; return false }())
        // Tombstone (sign-out core).
        let before = try store.readRegistrations()
        let tomb = try await store.tombstone("oaiappClientA", expectedGeneration: g2)
        c.check("signout: the tombstone lists every refresh token for revocation", Set(tomb.revoke).isSuperset(of: ["synthetic-refresh-A3", "synthetic-refresh-A2"]))
        c.check("signout: tokens cleared, generation changed", store.readTokens_unsafe("oaiappClientA")?.tokens == nil && tomb.generation != g2)
        c.check("signout: registrations and the host are kept (D4)", try store.readRegistrations() == before
                && FileManager.default.fileExists(atPath: paths.hostFile.path))
        await c.rejectsKind("signout: the old generation is refused before any send", .signInRequired) {
            try store.validate(clientId: "oaiappClientA", generation: g2)
        }
        await c.rejects("signout: a stale sign-out (older generation) changes nothing") {
            _ = try await store.tombstone("oaiappClientB", expectedGeneration: g2)
        }
        c.check("signout: the other registration is untouched", store.readTokens_unsafe("oaiappClientB")?.tokens?.access == "synthetic-access-B")
        // Retire all in one replacement, same effect mark on each record.
        let effect3 = SIWCEffectMark(attempt: UUID().uuidString, effectId: UUID().uuidString)
        let writesBefore = WriteCounter()
        var counted = store; counted.afterTokenWrite = { writesBefore.count += 1 }
        let retired = try await counted.retireAll(effect: effect3)
        let after = try store.readTokens()!
        c.check("retire: every record changes in ONE token-file replacement", writesBefore.count == 1 && retired.count == 2)
        c.check("retire: each record carries the same effect mark", after.records.allSatisfy { $0.lastEffect == effect3 && $0.tokens == nil })
        // Per-record evidence: a later unrelated write to one record replaces its mark.
        let effect4 = SIWCEffectMark(attempt: UUID().uuidString, effectId: UUID().uuidString)
        _ = try await signIn(store, paths, clientId: "oaiappClientB", sub: "user-sub-B", new: false, tokens: tokens("B2"), effect: effect4)
        let marks = try store.readTokens()!.records.map { ($0.clientId, $0.lastEffect) }
        c.check("evidence: a later write to one record leaves the other's mark alone",
                marks.first { $0.0 == "oaiappClientA" }?.1 == effect3 && marks.first { $0.0 == "oaiappClientB" }?.1 == effect4)
        // Plan usage off: saved, unusable for inference (§3.2 step 7).
        let planStore = SIWCStore(directory: root.appendingPathComponent("plan-off"))
        let planPaths = hostPaths(root.appendingPathComponent("plan-off-host"), stores: [planStore.directory])
        guard case .saved(_, let gp) = try await signIn(planStore, planPaths, clientId: "oaiappClientP", new: true,
                                                     tokens: tokens("P", plan: false)) else { return }
        c.check("scope: identity-only grant saved with plan usage off", try planStore.readRegistrations()?.registrations.first?.planUsageEnabled == false)
        await c.rejectsKind("scope: plan usage off sends no inference", .planUsageOff) { try planStore.validate(clientId: "oaiappClientP", generation: gp) }
        await c.rejects("scope: plan usage off cannot be activated") {
            _ = try await planStore.activate(.init(clientId: "oaiappClientP", generation: gp, replacementId: nil))
        }
    }

    final class WriteCounter: @unchecked Sendable { var count = 0 }
}

extension SIWCStore {
    /// Selftest convenience.
    func readTokens_unsafe(_ clientId: String) -> SIWCTokenRecord? { (try? readTokens())??.record(clientId) }
}
