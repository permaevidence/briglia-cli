import Foundation

/// Sign-out wins over any refresh (plan §7 step 5, §7.1 step 5).
extension RefreshSettleSelftest {
    func logoutTests(_ h: Harness, _ c: Checks) async throws {
        try await logoutDuringStoppedRefresh(h, c)
        try await logoutBeforeRecovery(h, c)
        try await logoutBeforeQueuedSettle(h, c)
        try await reloginClearsExhaustion(h, c)
        try await lateCallbackAfterLogout(h, c)
    }

    /// A browser/device login that completes after sign-out (or the
    /// `/deleteuserdata` wipe, which signs out through the same store) is inert.
    func lateCallbackAfterLogout(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("late-callback")
        let pending = try await s.store.beginLogin()
        try await s.store.logout()
        var late = SubscriptionSelftest.credential(); late.refresh = "late"
        var refused = false
        do { _ = try await s.store.commitLogin(late, pending: pending) } catch { refused = true }
        c.check("late callback after logout: refused, nothing revived", refused && Self.disk(s.store)["credential"] == nil)
    }

    /// `/stop` then sign-out while the 200 is still arriving: the settle
    /// finishes first (it owns the lock), then the tombstone; nothing revives.
    func logoutDuringStoppedRefresh(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("logout-during-refresh", script: ["slow"])
        let task = Task { try await Self.refresh(s) }
        while s.server.sends() < 1 { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        _ = await task.result
        try await s.store.logout()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await Self.settled(s.store)
        c.check("logout during refresh: tombstone holds, no credential", Self.disk(s.store)["credential"] == nil)
        c.check("logout during refresh: no checkpoint or op left to promote",
                Self.disk(s.store)["pendingRotation"] == nil && Self.disk(s.store)["refreshOp"] == nil)
        let late = await Self.outcome(s)
        c.check("logout during refresh: old generation cannot refresh", late.hasPrefix("error:") && s.server.sends() == 1)
    }

    func logoutBeforeRecovery(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("logout-before-recovery", script: ["timeout"])
        _ = await Self.outcome(s)
        try await s.store.logout()
        let after = await Self.outcome(s)
        c.check("logout before recovery: no recovery send", after.hasPrefix("error:") && s.server.sends() == 1)
        c.check("logout before recovery: recovery records gone", Self.disk(s.store)["refreshOp"] == nil && Self.disk(s.store)["refreshRecovery"] == nil)
    }

    /// The stopped caller's settle was still waiting for the lock when the
    /// user signed out: it finds the new generation and sends nothing.
    func logoutBeforeQueuedSettle(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("logout-before-queued-settle")
        let gate = RefreshTestGate()
        let holder = Task {
            try await s.store.locked {
                await gate.markStarted(); await gate.wait()
                // What logout does under the lock: a credential-free tombstone.
                try s.store.write(SubscriptionAuthState(generation: UUID().uuidString))
            }
        }
        while !(await gate.started) { try await Task.sleep(nanoseconds: 2_000_000) }
        let task = Task { try await Self.refresh(s) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await gate.release()
        _ = try await holder.value
        _ = await task.result
        try await Self.settled(s.store)
        c.check("queued settle after logout: nothing sent, nothing revived", s.server.sends() == 0 && Self.disk(s.store)["credential"] == nil)
    }

    func reloginClearsExhaustion(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("relogin", script: ["timeout", "timeout"])
        for _ in 0..<3 { _ = await Self.outcome(s) }
        let pending = try await s.store.beginLogin()
        var fresh = SubscriptionSelftest.credential(expired: true); fresh.refresh = s.server.current()
        let generation = try await s.store.commitLogin(fresh, pending: pending)
        c.check("new sign-in clears every refresh record", Self.disk(s.store)["refreshOp"] == nil && Self.disk(s.store)["refreshRecovery"] == nil)
        let renewed = Scenario(store: s.store, server: s.server, generation: generation)
        let result = await Self.outcome(renewed)
        c.check("new sign-in refreshes normally again", result == "ok:" + s.server.current() && s.server.sends() == 3)
    }
}
