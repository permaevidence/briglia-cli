import Foundation

/// Process death between exchange and save, and after the send (plan §7
/// step 4, §7.1 steps 1 and 4). Each crash is a real worker process that
/// `_exit`s; the restart is this process opening the same store.
extension RefreshSettleSelftest {
    func crashTests(_ h: Harness, _ c: Checks) async throws {
        try await crashBeforeCheckpoint(h, c)
        try await crashAfterCheckpoint(h, c)
        try await crashAfterSend(h, c)
        try await crashTwice(h, c)
        try await crashAfterReservation(h, c)
    }

    /// The honest limit: the new tokens die with the process. Restart makes
    /// one recovery attempt; a strict server refuses it → sign in again.
    func crashBeforeCheckpoint(_ h: Harness, _ c: Checks) async throws {
        for lenient in [false, true] {
            let label = lenient ? "lenient server" : "strict server"
            let s = try await h.scenario("crash-before-checkpoint-\(lenient)", lenient: lenient)
            try await Self.join([try Self.spawn(s, mode: "exit-after-exchange-1")])
            c.check("crash before checkpoint (\(label)): op record survives the crash", Self.disk(s.store)["refreshOp"] != nil)
            let first = await Self.outcome(s)
            let again = await Self.outcome(s)
            if lenient {
                c.check("crash before checkpoint (lenient): one recovery recovers the login", first.hasPrefix("ok:") && Self.diskRefresh(s.store) == s.server.current())
            } else {
                c.check("crash before checkpoint (strict): recovery refused → sign-in required", first.hasPrefix("error:") && Self.diskBlocked(s.store))
                c.check("crash before checkpoint (strict): blocked login sends nothing more", again.hasPrefix("error:"))
            }
            c.check("crash before checkpoint (\(label)): exactly one recovery send", s.server.sends() == 2)
        }
    }

    /// The checkpoint is durable: restart promotes it, nothing is sent.
    func crashAfterCheckpoint(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("crash-after-checkpoint")
        try await Self.join([try Self.spawn(s, mode: "exit-after-exchange-2")])
        let restarted = await Self.outcome(s)
        c.check("crash after checkpoint: restart promotes the rotated tokens", restarted == "ok:" + s.server.current())
        c.check("crash after checkpoint: no send on restart", s.server.sends() == 1)
        c.check("crash after checkpoint: checkpoint cleared", Self.disk(s.store)["pendingRotation"] == nil && Self.disk(s.store)["refreshOp"] == nil)
    }

    /// Death after the request left (outcome unknown): one recovery send.
    func crashAfterSend(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("crash-after-send", script: ["exit-sent"], lenient: true)
        try await Self.join([try Self.spawn(s, mode: "refresh")])
        c.check("crash after send: interrupted original recorded as sending", (Self.disk(s.store)["refreshOp"] as? [String: Any])?["state"] as? String == "sending")
        let restarted = await Self.outcome(s)
        c.check("crash after send: one recovery restores the login", restarted.hasPrefix("ok:") && s.server.sends() == 2)
        c.check("crash after send: recovery records cleared after success",
                Self.disk(s.store)["refreshOp"] == nil && Self.disk(s.store)["refreshRecovery"] == nil)
    }

    /// Original and recovery both die after sending: the path is exhausted.
    func crashTwice(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("crash-twice", script: ["exit-sent", "exit-sent"], lenient: true)
        try await Self.join([try Self.spawn(s, mode: "refresh")])
        try await Self.join([try Self.spawn(s, mode: "refresh")])
        let third = await Self.outcome(s)
        let fourth = await Self.outcome(s)
        c.check("crash twice: no third send after restart", s.server.sends() == 2)
        c.check("crash twice: user told sign-in may be required", third.contains("may need to be repeated") && fourth.hasPrefix("error:"))
        c.check("crash twice: credentials kept, not erased", Self.diskRefresh(s.store) == "r0")
    }

    /// Death after the recovery was reserved but before it reached the server:
    /// the reservation is spent; no process gets another attempt.
    func crashAfterReservation(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("crash-after-reservation", script: ["exit-sent", "exit-early"], lenient: true)
        try await Self.join([try Self.spawn(s, mode: "refresh")])
        try await Self.join([try Self.spawn(s, mode: "refresh")])
        c.check("crash after reservation: reservation is durable", Self.disk(s.store)["refreshRecovery"] != nil)
        let restarted = await Self.outcome(s)
        c.check("crash after reservation: restart sends nothing", restarted.hasPrefix("error:") && s.server.sends() == 2)
    }
}
