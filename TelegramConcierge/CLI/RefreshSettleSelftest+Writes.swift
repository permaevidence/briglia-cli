import Foundation

/// Failed checkpoint/final writes and a parent-fsync failure after the
/// rename (plan §7 step 6, §7.1 step 3). Write 1 after the exchange is the
/// checkpoint, write 2 the commit.
extension RefreshSettleSelftest {
    func writeFailureTests(_ h: Harness, _ c: Checks) async throws {
        try await checkpointWriteFails(h, c)
        try await finalWriteFails(h, c)
        try await bothWritesFail(h, c)
        try await fsyncAfterRenameFails(h, c)
    }

    static func faulty(_ s: Scenario, _ actions: [Int: WriteFault.Action]) -> (SubscriptionAuthStore, WriteFault) {
        let fault = WriteFault(); fault.actions = actions
        var store = s.store
        store.beforeWrite = { try fault.before() }
        store.afterWrite = { try fault.after() }
        return (store, fault)
    }

    func checkpointWriteFails(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("checkpoint-write-fails")
        let (store, fault) = Self.faulty(s, [1: .throwBefore])
        let result = await Self.outcome(s, store: store, fault: fault)
        c.check("checkpoint write fails: commit still saves the rotated tokens", result == "ok:" + s.server.current() && Self.diskRefresh(s.store) == s.server.current())
    }

    func finalWriteFails(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("final-write-fails")
        let (store, fault) = Self.faulty(s, [2: .throwBefore])
        let result = await Self.outcome(s, store: store, fault: fault)
        c.check("final write fails: caller gets no unsaved token", result.hasPrefix("error:") && result.contains("could not be saved"))
        c.check("final write fails: checkpoint is on disk", Self.disk(s.store)["pendingRotation"] != nil && Self.diskRefresh(s.store) == "r0")
        let next = await Self.outcome(s)
        c.check("final write fails: next request promotes it without a send", next == "ok:" + s.server.current() && s.server.sends() == 1)
    }

    /// Both writes fail: the op record (`sending`) is what remains; the next
    /// request gets its one recovery, which a strict server refuses.
    func bothWritesFail(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("both-writes-fail")
        let (store, fault) = Self.faulty(s, [1: .throwBefore, 2: .throwBefore])
        let result = await Self.outcome(s, store: store, fault: fault)
        c.check("both writes fail: caller told sign-in may be needed, no token", result.contains("may need to be repeated"))
        c.check("both writes fail: interrupted op recorded", (Self.disk(s.store)["refreshOp"] as? [String: Any])?["state"] as? String == "sending")
        _ = await Self.outcome(s)
        _ = await Self.outcome(s)
        c.check("both writes fail: one recovery, then sign-in (strict)", s.server.sends() == 2 && Self.diskBlocked(s.store))
    }

    /// The rename landed but the directory fsync failed: the replacement is
    /// on disk and is used; the failure doesn't trigger a retry.
    func fsyncAfterRenameFails(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("fsync-after-rename-fails")
        let (store, fault) = Self.faulty(s, [2: .throwAfter])
        _ = await Self.outcome(s, store: store, fault: fault)
        let next = await Self.outcome(s)
        c.check("fsync after rename fails: saved replacement used, no retry", next == "ok:" + s.server.current() && s.server.sends() == 1)
    }
}
