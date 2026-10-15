import Foundation

/// `/stop` (task cancellation) at each point of a refresh (plan §7 tests).
extension RefreshSettleSelftest {
    func cancelTests(_ h: Harness, _ c: Checks) async throws {
        try await cancelAfterExchange(h, c)
        try await cancelDuringSend(h, c)
        try await cancelBeforeSend(h, c)
        try await cancelAfterCommit(h, c)
    }

    /// Codex's reproduction: the 200 arrives while the caller is cancelled.
    /// 0.2.53 threw at `checkCancellation()` before saving: rotated tokens lost.
    func cancelAfterExchange(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("cancel-after-exchange", script: ["slow"])
        let started = ProcessInfo.processInfo.systemUptime
        let task = Task { try await Self.refresh(s) }
        while s.server.sends() < 1 { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        let result = await task.result
        let waited = ProcessInfo.processInfo.systemUptime - started
        c.check("cancel after exchange: caller sees cancellation", { if case .failure(let e) = result { return e is CancellationError }; return false }())
        c.check("cancel after exchange: caller stops waiting before the reply (\(String(format: "%.2f", waited)) s)", waited < 0.3)
        try await Self.settled(s.store)
        c.check("cancel after exchange: rotated tokens are persisted", Self.diskRefresh(s.store) == s.server.current())
        let next = await Self.outcome(s)
        c.check("cancel after exchange: next request uses them without a send", next == "ok:" + s.server.current() && s.server.sends() == 1)
        c.check("cancel after exchange: no checkpoint or op record left", Self.disk(s.store)["pendingRotation"] == nil && Self.disk(s.store)["refreshOp"] == nil)
    }

    /// Cancellation while the request is on the wire: the send is not torn
    /// down (it would leave an ambiguous outcome); it settles normally.
    func cancelDuringSend(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("cancel-during-send", script: ["slow-cancellable"])
        let task = Task { try await Self.refresh(s) }
        while s.server.sends() < 1 { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        _ = await task.result
        try await Self.settled(s.store)
        c.check("cancel during send: request not torn down, tokens persisted", Self.diskRefresh(s.store) == s.server.current())
        c.check("cancel during send: no recovery record", Self.disk(s.store)["refreshOp"] == nil && Self.disk(s.store)["refreshRecovery"] == nil)
        c.check("cancel during send: login still usable", await Self.outcome(s) == "ok:" + s.server.current() && s.server.sends() == 1)
    }

    /// Cancelled while waiting for the lock: nothing is sent.
    func cancelBeforeSend(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("cancel-before-send")
        let holder = Task { try await s.store.locked { try await Task.sleep(nanoseconds: 300_000_000) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let task = Task { try await Self.refresh(s) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.result
        _ = try await holder.value
        try await Self.settled(s.store)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await Self.settled(s.store)
        c.check("cancel before send: nothing sent", s.server.sends() == 0)
        c.check("cancel before send: credential and records unchanged",
                Self.diskRefresh(s.store) == "r0" && Self.disk(s.store)["refreshOp"] == nil)
    }

    /// Cancelled after the commit: the caller still sees cancellation, the
    /// saved login is intact.
    func cancelAfterCommit(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("cancel-after-commit")
        let gate = RefreshTestGate()
        let task = Task { () -> SubscriptionCredential in
            let value = try await Self.refresh(s)
            await gate.markStarted(); await gate.wait()
            try Task.checkCancellation()
            return value
        }
        while !(await gate.started) { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel(); await gate.release()
        var failed = false
        if case .failure = await task.result { failed = true }
        c.check("cancel after commit: caller cancelled", failed)
        c.check("cancel after commit: committed login intact", Self.diskRefresh(s.store) == s.server.current() && s.server.sends() == 1)
    }
}
