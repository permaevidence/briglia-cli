import Foundation

/// The one recovery retry after an ambiguous refresh (plan §7.1), in process.
extension RefreshSettleSelftest {
    func retryTests(_ h: Harness, _ c: Checks) async throws {
        try await twoAmbiguous(h, c)
        try await ambiguousThenRecovered(h, c)
        try await lostReplyStrict(h, c)
        try await invalidGrantStops(h, c)
        try await answeredIsNotAmbiguous(h, c)
        try await budgetIsNotSent(h, c)
        try await gatewayTimeoutIsAmbiguous(h, c)
        try await accountChangeBlocks(h, c)
    }

    /// A gateway 504 may follow a rotation the server already made: it is
    /// ambiguous, so the one recovery is used (and a strict server ends it).
    func gatewayTimeoutIsAmbiguous(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("rotated-504", script: ["rotated-504"], lenient: true)
        _ = await Self.outcome(s)
        c.check("504: recorded as an ambiguous send", (Self.disk(s.store)["refreshOp"] as? [String: Any])?["state"] as? String == "ambiguous")
        let second = await Self.outcome(s)
        c.check("504: one recovery restores the login", second == "ok:" + s.server.current() && s.server.sends() == 2)
    }

    /// A rotation naming another account is never used, and the old refresh
    /// token (already rotated away) is never sent again.
    func accountChangeBlocks(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("account-change", script: ["other-account"], lenient: true)
        let first = await Self.outcome(s)
        let again = await Self.outcome(s)
        c.check("account change: other account's tokens never saved", first.hasPrefix("error:") && Self.diskRefresh(s.store) == "r0"
                && Self.disk(s.store)["pendingRotation"] == nil)
        c.check("account change: login blocked, no second send", Self.diskBlocked(s.store) && again.hasPrefix("error:") && s.server.sends() == 1)
    }

    /// Two consecutive ambiguous outcomes exhaust the path: two sends total,
    /// however many later calls, and the credential is kept.
    func twoAmbiguous(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("two-ambiguous", script: ["timeout", "timeout"])
        var outcomes: [String] = []
        for _ in 0..<4 { outcomes.append(await Self.outcome(s)) }
        c.check("two ambiguous: exactly two sends across four calls", s.server.sends() == 2)
        c.check("two ambiguous: later calls say sign-in may be required", outcomes[1...].allSatisfy { $0.contains("may need to be repeated") })
        c.check("two ambiguous: credential kept, login not marked blocked", Self.diskRefresh(s.store) == "r0" && !Self.diskBlocked(s.store))
    }

    func ambiguousThenRecovered(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("ambiguous-then-recovered", script: ["timeout"])
        let first = await Self.outcome(s)
        c.check("ambiguous: op record marked ambiguous", (Self.disk(s.store)["refreshOp"] as? [String: Any])?["state"] as? String == "ambiguous")
        let second = await Self.outcome(s)
        c.check("ambiguous: the one recovery succeeds", first.hasPrefix("error:") && second == "ok:" + s.server.current() && s.server.sends() == 2)
        c.check("ambiguous: success clears op and recovery records", Self.disk(s.store)["refreshOp"] == nil && Self.disk(s.store)["refreshRecovery"] == nil)
    }

    /// The reply was lost after the server rotated; a strict server refuses
    /// the old token, which ends in sign-in, never a loop.
    func lostReplyStrict(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("lost-reply-strict", script: ["lost"])
        _ = await Self.outcome(s)
        _ = await Self.outcome(s)
        _ = await Self.outcome(s)
        c.check("lost reply (strict): one recovery, then sign-in required", s.server.sends() == 2 && Self.diskBlocked(s.store))
    }

    /// An explicit terminal refusal never retries, now or after an ambiguous send.
    func invalidGrantStops(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("invalid-grant", script: ["invalid"])
        _ = await Self.outcome(s)
        let again = await Self.outcome(s)
        c.check("invalid_grant: login blocked, no retry", Self.diskBlocked(s.store) && again.hasPrefix("error:") && s.server.sends() == 1)
        c.check("invalid_grant: no op record left", Self.disk(s.store)["refreshOp"] == nil)
        let r = try await h.scenario("invalid-grant-in-recovery", script: ["timeout", "invalid"])
        for _ in 0..<3 { _ = await Self.outcome(r) }
        c.check("invalid_grant during recovery: blocked after two sends", Self.diskBlocked(r.store) && r.server.sends() == 2)
    }

    /// A 503 is an answer, not an ambiguous send: no recovery is spent.
    func answeredIsNotAmbiguous(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("answered-503", script: ["http503", "http503"])
        _ = await Self.outcome(s)
        c.check("503: no op or recovery record", Self.disk(s.store)["refreshOp"] == nil && Self.disk(s.store)["refreshRecovery"] == nil)
        _ = await Self.outcome(s)
        let third = await Self.outcome(s)
        c.check("503: ordinary refreshes continue afterwards", third == "ok:" + s.server.current() && s.server.sends() == 3)
    }

    /// A budget refusal happens before anything is built: not a send.
    func budgetIsNotSent(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("budget")
        let budget = SendBudget(limit: 0, exhausted: { AuthBudgetExhausted(limit: $0) })
        let login = Self.login(s)
        let refresher = ResponsesAdapter.refresher(login, budget)
        var refused = false
        do { _ = try await s.store.credential(generation: s.generation, refresh: refresher) } catch { refused = error is AuthBudgetExhausted }
        c.check("budget: refused before sending", refused && s.server.sends() == 0)
        let noRecord = Self.disk(s.store)["refreshOp"] == nil
        let next = await Self.outcome(s)
        c.check("budget: no op record, next refresh is ordinary", noRecord && next.hasPrefix("ok:"))
    }
}
