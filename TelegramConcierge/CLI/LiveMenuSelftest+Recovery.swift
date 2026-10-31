import Foundation

// Crash recovery (plan B.5 table, B.4c scope table) and the commit token /
// lifecycle protocol (B.4b).
extension LiveMenuHarness {
    func attempt(_ id: String, auth: Bool, kind: String? = "publish", old: SubscriptionAuthState? = nil,
                 operation: String = "commit", category: String = "ai") -> SettingsPendingStore.Attempt {
        SettingsPendingStore.Attempt(attempt: id, operation: operation, category: category, ticket: nil, clientRequestId: id,
            label: "row", authEffect: auth, authKind: auth ? kind : nil, storePath: auth ? StoragePaths.configRoot.path : nil,
            oldEvidence: auth ? SettingsPendingStore.AuthEvidence(old) : nil, projectedEvidence: nil,
            secretsKeys: ["k"], steps: ["intent"], direction: nil, retirement: nil, startedAt: Date())
    }

    func recoverySection() {
        let old = SubscriptionAuthState(generation: UUID().uuidString)
        // Rule 0: no auth effect → no auth store is opened (a damaged one must
        // not turn a persisted settings-only save into uncertain).
        let a0 = UUID().uuidString
        var opened = false
        let e0 = SettingsRecovery.authEvidence(attempt(a0, auth: false)) { _ in opened = true; throw SubscriptionError("damaged") }
        check("recovery rule 0: no auth effect → none, without opening the auth store", e0 == .none && !opened)
        // Rule 1: unreadable → unknown.
        check("recovery rule 1: an unreadable auth store → unknown",
              SettingsRecovery.authEvidence(attempt(a0, auth: true, old: old)) { _ in throw SubscriptionError("damaged") } == .unknown)
        // Rule 2: lastAttempt == attempt → applied (generation-preserving cancel too).
        var cancelled = old; cancelled.lastAttempt = a0
        check("recovery rule 2: lastAttempt == attempt → applied (a generation-preserving cancel included)",
              SettingsRecovery.authEvidence(attempt(a0, auth: true, kind: "cancel", old: old)) { _ in cancelled } == .applied)
        // Rule 3: matches old evidence and lastAttempt differs → not applied.
        check("recovery rule 3: old evidence → not applied",
              SettingsRecovery.authEvidence(attempt(a0, auth: true, old: old)) { _ in old } == .notApplied)
        check("recovery rule 3: still absent → not applied",
              SettingsRecovery.authEvidence(attempt(a0, auth: true, old: nil)) { _ in nil } == .notApplied)
        // Rule 4: anything else → unknown.
        let otherWriter = SubscriptionAuthState(generation: UUID().uuidString)
        check("recovery rule 4: changed by another writer → unknown",
              SettingsRecovery.authEvidence(attempt(a0, auth: true, old: old)) { _ in otherWriter } == .unknown)
        // The table.
        let rec = attempt(a0, auth: true)
        let rows: [(SettingsRecovery.AuthEvidence, Bool, String)] = [
            (.none, false, "failed"), (.notApplied, false, "failed"), (.applied, false, "partial"),
            (.none, true, "persisted"), (.applied, true, "persisted"), (.notApplied, true, "uncertain"),
            (.unknown, false, "uncertain"), (.unknown, true, "uncertain"),
        ]
        var wrong: [String] = []
        for (e, marker, want) in rows where SettingsRecovery.classify(rec, evidence: e, marker: marker).state != want {
            wrong.append("\(e.rawValue)/\(marker)")
        }
        check("recovery: every row of the table gives its result", wrong.isEmpty, wrong.joined(separator: ", "))
        check("recovery: a partial publish says the login was published and settings not saved",
              SettingsRecovery.classify(rec, evidence: .applied, marker: false).message.contains("published; settings not saved"))
        // End to end: journals on disk, run() finalizes them, nothing replayed.
        reset(Self.routeBase)
        let persisted = UUID().uuidString, interrupted = UUID().uuidString, claimedOnly = UUID().uuidString
        try? KeychainHelper.save(key: SettingsWriter.attemptMarkerKey("ai"), value: persisted)
        let stagedChange = PreparedChange(origin: "x", label: "claimed", epoch: 0)
        _ = try? SettingsPendingStore.update { doc in
            doc.attempts[persisted] = self.attempt(persisted, auth: false, operation: "pending-apply")
            doc.attempts[interrupted] = self.attempt(interrupted, auth: false, category: "email")
            doc.slots["ai"] = .init(staged: nil, active: .init(ticket: "T-ai", attempt: persisted, change: stagedChange, state: "persisted", claimedAt: Date()))
            doc.slots["email"] = .init(staged: nil, active: .init(ticket: "T-email", attempt: claimedOnly, change: stagedChange, state: "claimed", claimedAt: Date()))
        }
        let before = store()
        let report = (try? SettingsRecovery.run()) ?? .init()
        let doc = pendingDoc()
        check("recovery: a pending apply with its marker is persisted, its slot cleared",
              report.persisted == [persisted] && doc.slots["ai"] == nil)
        check("recovery: an attempt without marker or auth effect fails as interrupted",
              doc.lastResults.contains { $0.clientRequestId == interrupted && $0.state == "failed" })
        check("recovery: a claim interrupted before intent returns to staged",
              doc.slots["email"]?.staged?.ticket == "T-email" && doc.slots["email"]?.active == nil && report.restaged == ["T-email"])
        check("recovery: the journal is empty and nothing was replayed", doc.attempts.isEmpty && store() == before)
    }

    func recoveryScopeSection() {
        func scope(_ retirement: String, _ direction: String = "own->shared") -> SettingsPendingStore.Attempt {
            var r = attempt(UUID().uuidString, auth: retirement == "own", kind: "logout", operation: "scope")
            r.retirement = retirement; r.direction = direction
            return r
        }
        let own = scope("own")
        check("scope: the publication marker → target scope published",
              SettingsRecovery.classifyScope(own, evidence: .unknown, published: true).state == "persisted")
        check("scope: no marker, retired store applied → signed out, scope unchanged (partial)",
              SettingsRecovery.classifyScope(own, evidence: .applied, published: false).state == "partial")
        check("scope: no marker, retired store not applied → nothing changed",
              SettingsRecovery.classifyScope(own, evidence: .notApplied, published: false).state == "failed")
        check("scope: no marker, retired store unknown → uncertain",
              SettingsRecovery.classifyScope(own, evidence: .unknown, published: false).state == "uncertain")
        let none = scope("none", "shared->own")
        check("scope: no retirement, no marker → scope unchanged, nothing retired",
              SettingsRecovery.classifyScope(none, evidence: .none, published: false).state == "failed")
        check("scope: the table is parameterized by direction",
              SettingsRecovery.classifyScope(none, evidence: .none, published: true).message.contains("own login"))
        check("scope: a retire-failed label with applied evidence is reported from the evidence",
              { var r = own; r.steps.append("retire-failed-before-replace"); return SettingsRecovery.classifyScope(r, evidence: .applied, published: false).state }() == "partial")
    }

    // MARK: Gate and lifecycle (B.4b)

    func gateSection() async {
        let gate = SettingsCommitGate()
        var order: [Int] = []
        guard let first = await gate.acquire() else { check("gate: first acquire", false); return }
        let t2 = Task { @MainActor in if let t = await gate.acquire() { order.append(2); gate.release(t) } }
        let t3 = Task { @MainActor in if let t = await gate.acquire() { order.append(3); gate.release(t) } }
        await Task.yield(); await Task.yield()
        check("gate: one holder at a time (others queue)", gate.queued == 2)
        order.append(1)
        gate.release(first)
        await t2.value; await t3.value
        check("gate: FIFO order", order == [1, 2, 3], "\(order)")
        // closeAdmission: queued waiters refused, holder's wait cancelled.
        guard let holder = await gate.acquire() else { return }
        var cancelled = false
        gate.setCancelHandler(holder) { cancelled = true }
        var waiterGot: SettingsCommitGate.Token?? = .none
        let waiter = Task { @MainActor in waiterGot = .some(await gate.acquire()) }
        await Task.yield(); await Task.yield()
        gate.closeAdmission(reason: "wipe")
        await waiter.value
        check("lifecycle: a queued writer is settled with a refusal", waiterGot == .some(nil))
        check("lifecycle: the holder's write-free wait is cancelled", cancelled)
        let refused = await gate.acquire()
        check("lifecycle: a new writer is refused at once while admission is closed", refused == nil)
        var lifecycleGot = false
        let life = Task { @MainActor in let t = await gate.acquireForLifecycle(); lifecycleGot = true; gate.release(t) }
        await Task.yield(); await Task.yield()
        check("lifecycle: the operation waits for the holder", !lifecycleGot)
        gate.release(holder)
        await life.value
        check("lifecycle: then takes the token", lifecycleGot)
        gate.reopenAdmission()
        // A holder in its durable phase is never cancelled.
        guard let durable = await gate.acquire() else { return }
        var cancelled2 = false
        gate.setCancelHandler(durable) { cancelled2 = true }
        gate.enterDurablePhase(durable)
        gate.closeAdmission(reason: "upgrade")
        check("lifecycle: a holder past its first durable write is not cancelled", !cancelled2 && gate.holderInDurablePhase)
        gate.release(durable); gate.reopenAdmission()
    }

    func lifecycleSection() async {
        // A forwarded commit vs a wipe winning the token: refused, no hang.
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        reset(Self.routeBase)
        guard let change = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-late") }) else { return }
        writer.gate.closeAdmission(reason: "Briglia is deleting its memory")
        let token = await writer.gate.acquireForLifecycle()
        let result = await writer.commit(change)
        check("lifecycle: a commit arriving during a wipe is refused at once (no hang)", result.state == .refused && store()[KeychainHelper.serperApiKeyKey] == "serper-synthetic-old-0001")
        // The operation's own writes run under its token.
        let own = await writer.commitHolding(token, change, policy: .classify)
        check("lifecycle: the operation's own commit uses the token it holds", own.state == .applied)
        writer.gate.release(token); writer.gate.reopenAdmission()
        // A holder in the barrier wait is cancelled by the lifecycle (refused).
        reset(Self.routeBase)
        guard let d = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "z/z") }) else { return }
        @MainActor final class SlowOwner: SettingsOwnerHost {
            var isDaemon: Bool { true }
            var entered = false
            func beginRouteBarrier() async -> Bool {
                entered = true
                var n = 0
                while !Task.isCancelled && n < 500 { try? await Task.sleep(nanoseconds: 10_000_000); n += 1 }
                return false
            }
            func endRouteBarrier() {}
            func admissionRefusal() -> String? { nil }
            func reconcile(after change: PreparedChange, routeChanged: Bool) async {}
            var toolSwitches: SettingsToolSwitches { SettingsToolSwitches(subagents: true, webSubagent: true) }
        }
        let slow = SlowOwner()
        let w2 = SettingsWriter(host: slow)
        let commit = Task { @MainActor in await w2.commit(d) }
        var spins = 0
        while !slow.entered && spins < 400 { try? await Task.sleep(nanoseconds: 5_000_000); spins += 1 }
        guard slow.entered else {
            check("lifecycle: the D commit reached the barrier wait", false)
            commit.cancel(); _ = await commit.value
            return
        }
        w2.gate.closeAdmission(reason: "Mind import")
        let r = await commit.value
        check("lifecycle: a holder waiting for the barrier is cancelled → refused, slot staged nothing", r.state == .refused && pendingDoc().slots.isEmpty, "\(r.state)")
        w2.gate.reopenAdmission()
        withExtendedLifetime(slow) {}
    }
}
