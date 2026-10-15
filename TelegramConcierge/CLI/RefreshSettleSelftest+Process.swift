import Foundation

/// Concurrent processes on one store (plan §7 step 1, §7.1 steps 2–4).
extension RefreshSettleSelftest {
    func processTests(_ h: Harness, _ c: Checks) async throws {
        try await concurrentRefresh(h, c)
        try await concurrentRecovery(h, c)
        try await concurrentRecoveryExhausted(h, c)
    }

    func concurrentRefresh(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("concurrent-refresh", script: ["slow"])
        try await Self.join([try Self.spawn(s, mode: "refresh"), try Self.spawn(s, mode: "refresh")])
        c.check("two processes: one refresh send, both share its result", s.server.sends() == 1 && Self.diskRefresh(s.store) == s.server.current())
    }

    /// After an ambiguous send, two waiting processes: only one recovers.
    func concurrentRecovery(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("concurrent-recovery", script: ["timeout", "slow"])
        _ = await Self.outcome(s)
        try await Self.join([try Self.spawn(s, mode: "refresh"), try Self.spawn(s, mode: "refresh")])
        c.check("two processes after ambiguous: exactly one recovery send", s.server.sends() == 2)
        c.check("two processes after ambiguous: recovered login saved", Self.diskRefresh(s.store) == s.server.current())
    }

    /// The recovery itself is ambiguous: the other process must not retry.
    func concurrentRecoveryExhausted(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("concurrent-recovery-exhausted", script: ["timeout", "lost-slow"])
        _ = await Self.outcome(s)
        try await Self.join([try Self.spawn(s, mode: "refresh"), try Self.spawn(s, mode: "refresh")])
        let after = await Self.outcome(s)
        c.check("ambiguous recovery: no process sends a second recovery", s.server.sends() == 2)
        c.check("ambiguous recovery: later calls send nothing", after.contains("may need to be repeated") && s.server.sends() == 2)
    }
}
