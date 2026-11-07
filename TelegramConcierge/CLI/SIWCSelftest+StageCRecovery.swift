import Foundation

/// Stage C: crash recovery from per-record SIWC evidence (SIWC plan §3.9
/// "Recovery evidence", round-1 R4, round-2 attribution).
extension SIWCSelftest {
    static func journal(_ attempt: String, label: String = "ChatGPT sign-in", secretsKeys: [String] = [],
                        effects: [SIWCJournalEffect], operation: String = "commit", direction: String? = nil,
                        retirement: String? = nil, legacy: Bool = false) throws {
        let record = SettingsPendingStore.Attempt(attempt: attempt, operation: operation, category: "ai", ticket: nil,
            clientRequestId: attempt, label: label, authEffect: legacy, authKind: nil, storePath: legacy ? "/nonexistent-legacy" : nil,
            oldEvidence: legacy ? SettingsPendingStore.AuthEvidence(nil) : nil, projectedEvidence: nil, secretsKeys: secretsKeys,
            steps: ["intent"], direction: direction, retirement: retirement, startedAt: Date(), siwcEffects: effects)
        try SettingsPendingStore.update { $0.attempts[attempt] = record }
    }

    static func recover(_ c: Checks, secrets: [String: String] = [:],
                        legacy: @escaping (String) throws -> SubscriptionAuthState? = { _ in nil }) -> SettingsPendingStore.Result? {
        let report = try? SettingsRecovery.run(secrets: secrets, read: legacy)
        return report?.results.last
    }

    static func stageCRecoveryTests(_ root: URL, _ c: Checks) async throws {
        try? SettingsPendingStore.remove()
        let (store, _, _) = try await activeStore(root, clientId: "oaiappRecA")
        let fpA = SIWCEndpoint.registrationFingerprint(clientId: "oaiappRecA")
        func effect(_ kind: SIWCJournalEffect.Kind, targets: [String], file: String = "tokens") throws -> SIWCJournalEffect {
            let tokens = try store.readTokens(), regs = try store.readRegistrations()
            var old: [String: SIWCRecordEvidence] = [:]
            for t in targets {
                switch kind {
                case .pointer: old[t] = .pointer(regs)
                case .cancel: old[t] = .pendingMarker(tokens)
                default: old[t] = .record(tokens?.records.first { SIWCEndpoint.registrationFingerprint(clientId: $0.clientId) == t })
                }
            }
            return SIWCJournalEffect(effectId: UUID().uuidString, kind: kind, storePath: store.directory.path, file: file, targets: targets, oldEvidence: old)
        }
        // 1. Intent only, crash before the write → failed (interrupted), never "nothing changed" with an effect.
        var a1 = UUID().uuidString
        try journal(a1, effects: [try effect(.tombstone, targets: [fpA])])
        let r1 = recover(c)
        c.check("recovery: crash before the tombstone → interrupted before saving", r1?.state == "failed")
        // 2. Tombstone written with this attempt's mark → persisted.
        a1 = UUID().uuidString
        let e2 = try effect(.tombstone, targets: [fpA])
        try journal(a1, label: "ChatGPT sign-out", effects: [e2])
        _ = try await store.tombstone("oaiappRecA", effect: e2.mark(attempt: a1))
        let tombed = try store.readTokens()
        let r2 = recover(c)
        c.check("recovery: tombstone durable → persisted", r2?.state == "persisted")
        c.check("recovery: never replays a sign-out (store unchanged)", (try? store.readTokens())?.record("oaiappRecA")?.generation
                == tombed?.record("oaiappRecA")?.generation)
        // 3. Activation: promotion + pointer applied, secrets marker missing → partial ("settings not saved").
        let (s3, p3, _) = try await activeStore(root, clientId: "oaiappRecB")
        let fpB = SIWCEndpoint.registrationFingerprint(clientId: "oaiappRecB")
        guard case .staged(_, let rid, _) = try await signIn(s3, p3, clientId: "oaiappRecB", new: false, tokens: tokens("recB2"), inUse: true) else {
            c.check("recovery: fixture", false); return
        }
        let t3 = try s3.readTokens(), g3 = try s3.readRegistrations()
        let promote = SIWCJournalEffect(effectId: UUID().uuidString, kind: .promote, storePath: s3.directory.path, file: "tokens",
                                        targets: [fpB], oldEvidence: [fpB: .record(t3?.record("oaiappRecB"))])
        let pointer = SIWCJournalEffect(effectId: UUID().uuidString, kind: .pointer, storePath: s3.directory.path, file: "registrations",
                                        targets: ["store"], oldEvidence: ["store": .pointer(g3)])
        let a3 = UUID().uuidString
        try journal(a3, label: SIWCSettings.label, secretsKeys: [ChatGPTRoute.siwcGenerationKey], effects: [promote, pointer])
        _ = try await s3.locked { try s3.activateLocked(.init(clientId: "oaiappRecB", generation: nil, replacementId: rid),
                                                         effect: promote.mark(attempt: a3), pointerEffect: pointer.mark(attempt: a3)) }
        let r3 = recover(c)
        c.check("recovery: SIWC activated but settings not saved → partial", r3?.state == "partial" && (r3?.message ?? "").contains("settings not saved"))
        // 4. Same, with the secrets marker → persisted.
        let a4 = UUID().uuidString
        let p4 = SIWCJournalEffect(effectId: UUID().uuidString, kind: .pointer, storePath: s3.directory.path, file: "registrations",
                                   targets: ["store"], oldEvidence: ["store": .pointer(try? s3.readRegistrations())])
        try journal(a4, label: SIWCSettings.label, secretsKeys: [ChatGPTRoute.siwcGenerationKey], effects: [p4])
        _ = try await s3.locked { try s3.activateLocked(.init(clientId: "oaiappRecB", generation: try s3.readTokens()!.record("oaiappRecB")!.generation,
                                                                replacementId: nil), effect: nil, pointerEffect: p4.mark(attempt: a4)) }
        let r4 = recover(c, secrets: [SettingsWriter.attemptMarkerKey("ai"): a4])
        c.check("recovery: SIWC activated and settings saved → persisted", r4?.state == "persisted")
        // 5. Unreadable store → uncertain (unknown), never a guess.
        let a5 = UUID().uuidString
        let e5 = try effect(.save, targets: [fpA])
        try journal(a5, effects: [e5])
        try Data("{not json".utf8).write(to: store.tokenFile)
        chmod(store.tokenFile.path, 0o600)
        let r5 = recover(c)
        c.check("recovery: unreadable evidence → uncertain", r5?.state == "uncertain")
        // 6. A later unrelated write to the record (its mark replaced) → unknown, never "applied".
        let (s6, _, _) = try await activeStore(root, clientId: "oaiappRecC")
        let fpC = SIWCEndpoint.registrationFingerprint(clientId: "oaiappRecC")
        let a6 = UUID().uuidString
        let e6 = SIWCJournalEffect(effectId: UUID().uuidString, kind: .tombstone, storePath: s6.directory.path, file: "tokens",
                                   targets: [fpC], oldEvidence: [fpC: .record(try s6.readTokens()?.record("oaiappRecC"))])
        try journal(a6, effects: [e6])
        _ = try await s6.tombstone("oaiappRecC", effect: e6.mark(attempt: a6))
        try rewriteBound(s6, "oaiappRecC") { $0.lastEffect = SIWCEffectMark(attempt: UUID().uuidString, effectId: UUID().uuidString) }
        let r6 = recover(c)
        c.check("recovery: a later write by another sharer → uncertain", r6?.state == "uncertain")
        // 7. One grouped retirement over A and B where only A carries the mark: never "retired" from A's marker.
        let s7 = SIWCStore(directory: root.appendingPathComponent("rec-group"))
        let p7 = hostPaths(root.appendingPathComponent("rec-group-host"), stores: [s7.directory])
        _ = try await signIn(s7, p7, clientId: "oaiappGroupA", sub: "sub-gA", new: true, tokens: tokens("gA"))
        _ = try await signIn(s7, p7, clientId: "oaiappGroupB", sub: "sub-gB", new: true, tokens: tokens("gB"))
        let fpGA = SIWCEndpoint.registrationFingerprint(clientId: "oaiappGroupA"), fpGB = SIWCEndpoint.registrationFingerprint(clientId: "oaiappGroupB")
        let before7 = try s7.readTokens()
        let e7 = SIWCJournalEffect(effectId: UUID().uuidString, kind: .retire, storePath: s7.directory.path, file: "tokens", targets: [fpGA, fpGB],
                                   oldEvidence: [fpGA: .record(before7?.record("oaiappGroupA")), fpGB: .record(before7?.record("oaiappGroupB"))])
        let a7 = UUID().uuidString
        try journal(a7, label: "ChatGPT login scope", effects: [e7])
        // Only A's record carries the mark (B as before): a state one replacement cannot produce.
        try rewriteBound(s7, "oaiappGroupA") { $0.lastEffect = e7.mark(attempt: a7); $0.tokens = nil; $0.identity = nil }
        let r7 = recover(c)
        c.check("recovery: B is never reported retired from A's marker", r7?.state == "uncertain")
        c.check("recovery: per-target evidence is exact", SIWCRecovery.evaluate(e7, attempt: a7) == [fpGA: .applied, fpGB: .notApplied])
        // 8. Scope own → shared: legacy retired, SIWC retirement failed → partial naming both; published → persisted.
        let a8 = UUID().uuidString
        let e8 = SIWCJournalEffect(effectId: UUID().uuidString, kind: .retire, storePath: s7.directory.path, file: "tokens", targets: [fpGB],
                                   oldEvidence: [fpGB: .record(try s7.readTokens()?.record("oaiappGroupB"))])
        try journal(a8, label: "ChatGPT login scope", secretsKeys: [SubscriptionSharing.scopeKey], effects: [e8], operation: "scope",
                    direction: "own->shared", retirement: "own", legacy: true)
        var legacyTomb = SubscriptionAuthState(generation: UUID().uuidString); legacyTomb.lastAttempt = a8
        let r8 = recover(c, legacy: { _ in legacyTomb })
        c.check("recovery: scope with legacy retired and SIWC not → partial naming both, scope still own",
                r8?.state == "partial" && (r8?.message ?? "").contains("Own legacy login signed out")
                && (r8?.message ?? "").contains("own Sign in with ChatGPT login not signed out"))
        let a9 = UUID().uuidString
        try journal(a9, label: "ChatGPT login scope", secretsKeys: [SubscriptionSharing.scopeKey], effects: [e8], operation: "scope",
                    direction: "own->shared", retirement: "own", legacy: true)
        let r9 = recover(c, secrets: [SettingsWriter.scopePublishedKey: a9], legacy: { _ in legacyTomb })
        c.check("recovery: scope published → persisted", r9?.state == "persisted")
        // 10. Cancel: marker gone → applied.
        let s10 = SIWCStore(directory: root.appendingPathComponent("rec-cancel"))
        let pending = try await s10.beginPending(owner: nil)
        let e10 = SIWCJournalEffect(effectId: UUID().uuidString, kind: .cancel, storePath: s10.directory.path, file: "tokens", targets: ["store"],
                                    oldEvidence: ["store": .pendingMarker(try? s10.readTokens())])
        let a10 = UUID().uuidString
        try journal(a10, effects: [e10])
        try await s10.cancelPending(pending)
        c.check("recovery: a cancelled pending sign-in → persisted", recover(c)?.state == "persisted")
        c.check("recovery: the journal is empty afterwards", ((try? SettingsPendingStore.read())?.attempts.isEmpty ?? false))
        try? SettingsPendingStore.remove()
    }
}
