import Foundation

extension SIWCSelftest {
    final class Sends: @unchecked Sendable {
        let lock = NSLock(); var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    static func rotated(_ refresh: String, tag: String = "next", in seconds: Int = 3600) -> SIWCRefreshed {
        var t = tokens(tag, expiresIn: seconds); t.refresh = refresh + "-" + tag
        return SIWCRefreshed(tokens: t, claims: nil)
    }

    /// §7 against the SIWC store: freshness, rotation, cancellation, terminal
    /// errors, invalid_client, earliest_refresh_at, account change, two
    /// processes, tombstone during refresh.
    static func refreshTests(_ root: URL, _ c: Checks) async throws {
        let (store, _, g) = try await activeStore(root)
        let sends = Sends()
        let fresh = try await store.credential(clientId: "oaiappClientA", generation: g) { _ in sends.add(); throw SIWCError(.local, "x") }
        c.check("refresh: a fresh credential is returned without sending", fresh.access == "synthetic-access-A" && sends.value == 0)
        var later = store; later.clock = { Date().addingTimeInterval(3400) }
        let refreshed = try await later.credential(clientId: "oaiappClientA", generation: g) { r in sends.add(); return rotated(r) }
        let disk = store.readTokens_unsafe("oaiappClientA")
        c.check("refresh: due 5 min before expiry → one send, rotated and saved bound", sends.value == 1
                && refreshed.refresh == "synthetic-refresh-A-next" && disk?.tokens?.refresh == "synthetic-refresh-A-next"
                && (try? store.validate(clientId: "oaiappClientA", generation: g)) != nil)
        c.check("refresh: the generation is unchanged by a rotation", disk?.generation == g && disk?.refreshOp == nil && disk?.pendingRotation == nil)
        // earliest_refresh_at.
        let (s2, _, g2) = try await activeStore(root, tokens: tokens("E", expiresIn: 200, earliest: Int(Date().timeIntervalSince1970) + 100))
        let s2sends = Sends()
        _ = try await s2.credential(clientId: "oaiappClientA", generation: g2) { r in s2sends.add(); return rotated(r) }
        c.check("refresh: never before earliest_refresh_at while the token is still valid", s2sends.value == 0)
        _ = try await s2.credential(clientId: "oaiappClientA", generation: g2, rejectedAccess: "synthetic-access-E") { r in s2sends.add(); return rotated(r) }
        c.check("refresh: a 401-rejected access token is refreshed", s2sends.value == 1)
        // Cancellation after the send: the settle still saves.
        let (s3, _, g3) = try await activeStore(root, tokens: tokens("C", expiresIn: 10))
        let task = Task { try await s3.credential(clientId: "oaiappClientA", generation: g3) { r in
            try await Task.sleep(nanoseconds: 300_000_000); return rotated(r) } }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let cancelled = await task.result
        try await Task.sleep(nanoseconds: 600_000_000)
        c.check("refresh: /stop after the send — caller stops waiting", { if case .failure = cancelled { return true }; return false }())
        c.check("refresh: /stop after the send — the rotated token is still saved", s3.readTokens_unsafe("oaiappClientA")?.tokens?.refresh == "synthetic-refresh-C-next")
        // Cancellation before the send.
        let (s4, _, g4) = try await activeStore(root, tokens: tokens("D", expiresIn: 10))
        let s4sends = Sends()
        let early = Task { try await s4.credential(clientId: "oaiappClientA", generation: g4) { r in s4sends.add(); return rotated(r) } }
        early.cancel()
        _ = await early.result
        try await Task.sleep(nanoseconds: 200_000_000)
        c.check("refresh: /stop before the send — nothing is sent", s4sends.value == 0)
        // Terminal error: requires login, tokens kept only for revocation.
        let (s5, _, g5) = try await activeStore(root, tokens: tokens("T", expiresIn: 10))
        await c.rejectsKind("refresh: a terminal refresh error requires sign-in", .signInRequired) {
            _ = try await s5.credential(clientId: "oaiappClientA", generation: g5) { _ in throw SIWCError(.signInRequired, "x") }
        }
        let r5 = s5.readTokens_unsafe("oaiappClientA")
        c.check("refresh: terminal → tokens cleared, refresh kept for revocation, record still bound",
                r5?.tokens == nil && r5?.requiresLogin == true && r5?.cleanup?.contains("synthetic-refresh-T") == true && r5?.binding != nil)
        await c.rejectsKind("refresh: the next request sends nothing", .signInRequired) { try s5.validate(clientId: "oaiappClientA", generation: g5) }
        // invalid_client.
        let (s6, _, g6) = try await activeStore(root, tokens: tokens("I", expiresIn: 10))
        await c.rejectsKind("refresh: invalid_client marks the registration, keeps the client", .invalidClient) {
            _ = try await s6.credential(clientId: "oaiappClientA", generation: g6) { _ in throw SIWCError(.invalidClient, "x") }
        }
        c.check("refresh: invalid_client keeps the record and client id", s6.readTokens_unsafe("oaiappClientA")?.invalidClient == true
                && (try! s6.readRegistrations()?.registration("oaiappClientA")) != nil)
        // Account changed in a refresh.
        let (s7, _, g7) = try await activeStore(root, tokens: tokens("W", expiresIn: 10))
        await c.rejectsKind("refresh: a refresh naming another account is never activated", .signInRequired) {
            _ = try await s7.credential(clientId: "oaiappClientA", generation: g7) { r in
                var x = rotated(r); x = SIWCRefreshed(tokens: x.tokens, claims: claims(sub: "user-sub-OTHER")); return x }
        }
        let r7 = s7.readTokens_unsafe("oaiappClientA")
        c.check("refresh: the other account's tokens kept only for revocation", r7?.requiresLogin == true && r7?.tokens?.access == "synthetic-access-W"
                && r7?.cleanup?.contains("synthetic-refresh-W-next") == true)
        // Changed generation: refused.
        await c.rejectsKind("refresh: a stale generation is refused", .signInRequired) {
            _ = try await store.credential(clientId: "oaiappClientA", generation: UUID().uuidString) { r in rotated(r) }
        }
        // Tombstone during a refresh: it waits, then wins.
        let (s8, _, g8) = try await activeStore(root, tokens: tokens("L", expiresIn: 10))
        let running = Task { try await s8.credential(clientId: "oaiappClientA", generation: g8) { r in
            try await Task.sleep(nanoseconds: 400_000_000); return rotated(r) } }
        try await Task.sleep(nanoseconds: 100_000_000)
        let tomb = try await s8.tombstone("oaiappClientA")
        _ = await running.result
        c.check("refresh: sign-out waits for the in-flight settle and then tombstones it",
                tomb.revoke.contains("synthetic-refresh-L-next") && s8.readTokens_unsafe("oaiappClientA")?.tokens == nil)
        // Two processes: one send.
        let (s9, _, _) = try await activeStore(root, tokens: tokens("P", expiresIn: 10))
        let log = s9.directory.appendingPathComponent("sends.log")
        try PrivateStorage.writeExclusive(Data(), to: log)
        let processes = (0..<2).map { _ -> Process in
            let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            p.arguments = ["__siwc-selftest", "--worker", s9.directory.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            return p
        }
        for p in processes { try p.run() }
        while processes.contains(where: { $0.isRunning }) { try await Task.sleep(nanoseconds: 30_000_000) }
        let lines = (try String(contentsOf: log, encoding: .utf8)).split(separator: "\n")
        c.check("refresh: two processes on one store → exactly one token-endpoint call", processes.allSatisfy { $0.terminationStatus == 0 } && lines.count == 1)
        c.check("refresh: the other process re-read the renewed record", s9.readTokens_unsafe("oaiappClientA")?.tokens?.refresh == "synthetic-refresh-P-next")
    }

    /// §7.1 against the SIWC store: one recovery per (generation, token).
    static func refreshRecoveryTests(_ root: URL, _ c: Checks) async throws {
        let (store, _, g) = try await activeStore(root, tokens: tokens("A", expiresIn: 10))
        let sends = Sends()
        await c.rejects("recovery: an ambiguous send surfaces its error") {
            _ = try await store.credential(clientId: "oaiappClientA", generation: g) { _ in sends.add(); throw URLError(.timedOut) }
        }
        c.check("recovery: the op record says ambiguous", store.readTokens_unsafe("oaiappClientA")?.refreshOp?.state == "ambiguous")
        await c.rejectsKind("recovery: the second ambiguous outcome exhausts the path", .signInRequired) {
            _ = try await store.credential(clientId: "oaiappClientA", generation: g) { _ in sends.add(); throw URLError(.networkConnectionLost) }
        }
        let before = sends.value
        await c.rejectsKind("recovery: no further attempt for that token", .signInRequired) {
            _ = try await store.credential(clientId: "oaiappClientA", generation: g) { r in sends.add(); return rotated(r) }
        }
        c.check("recovery: exactly two sends in total, the third call sends nothing", before == 2 && sends.value == 2)
        c.check("recovery: credentials are kept after exhaustion (transient never erases)", store.readTokens_unsafe("oaiappClientA")?.tokens != nil)
        // Process death after `sending`: the next call is THE recovery.
        let (s2, _, g2) = try await activeStore(root, tokens: tokens("B", expiresIn: 10))
        try tamper(s2, "oaiappClientA") { $0.refreshOp = SubscriptionRefreshOp(opId: UUID().uuidString,
            tokenFingerprint: SubscriptionRefreshFingerprint.of("synthetic-refresh-B"), generation: g2, startedAt: Date(), state: "sending") }
        let ok = try await s2.credential(clientId: "oaiappClientA", generation: g2) { r in rotated(r) }
        c.check("recovery: an interrupted original makes the next send the recovery, which succeeds", ok.refresh == "synthetic-refresh-B-next"
                && s2.readTokens_unsafe("oaiappClientA")?.refreshRecovery == nil)
        // A valid checkpoint on disk is promoted without sending.
        let (s3, _, g3) = try await activeStore(root, tokens: tokens("K", expiresIn: 10))
        let key = try s3.integrityKey(create: false)!
        let identity = s3.readTokens_unsafe("oaiappClientA")!.identity!
        var rotation = SIWCPendingRotation(generation: g3, replaces: SubscriptionRefreshFingerprint.of("synthetic-refresh-K"),
                                           tokens: tokens("K2", expiresIn: 3600), identity: identity, mac: String(repeating: "0", count: 64))
        rotation.mac = try SIWCStore.rotationMAC(key: key, rotation)
        try tamper(s3, "oaiappClientA") { $0.pendingRotation = rotation }
        let s3sends = Sends()
        let promoted = try await s3.credential(clientId: "oaiappClientA", generation: g3) { r in s3sends.add(); return rotated(r) }
        c.check("recovery: a valid checkpoint is promoted, no send", promoted.access == "synthetic-access-K2" && s3sends.value == 0
                && (try? s3.validate(clientId: "oaiappClientA", generation: g3)) != nil)
        // A tampered checkpoint is never promoted.
        let (s4, _, g4) = try await activeStore(root, tokens: tokens("M", expiresIn: 10))
        var forged = rotation; forged.generation = g4
        forged.replaces = SubscriptionRefreshFingerprint.of("synthetic-refresh-M")
        try tamper(s4, "oaiappClientA") { $0.pendingRotation = forged }
        let s4sends = Sends()
        let fresh = try await s4.credential(clientId: "oaiappClientA", generation: g4) { r in s4sends.add(); return rotated(r) }
        c.check("recovery: a checkpoint with a wrong MAC is discarded, never promoted", fresh.refresh == "synthetic-refresh-M-next" && s4sends.value == 1)
        // Failed final write: the checkpoint survives and is promoted next time.
        let (s5, _, g5) = try await activeStore(root, tokens: tokens("F", expiresIn: 10))
        let writes = WriteCounter()
        var failing = s5
        failing.beforeTokenWrite = { writes.count += 1; if writes.count == 3 { throw SIWCError(.local, "disk full") } }
        await c.rejects("recovery: a failed final write is reported") {
            _ = try await failing.credential(clientId: "oaiappClientA", generation: g5) { r in rotated(r) }
        }
        let s5sends = Sends()
        let healed = try await s5.credential(clientId: "oaiappClientA", generation: g5) { r in s5sends.add(); return rotated(r, tag: "again") }
        c.check("recovery: the next call promotes the checkpoint without a retry send", healed.refresh == "synthetic-refresh-F-next" && s5sends.value == 0)
        // Op record write failure: nothing is sent.
        let (s6, _, g6) = try await activeStore(root, tokens: tokens("G", expiresIn: 10))
        var noRecord = s6
        noRecord.beforeTokenWrite = { throw SIWCError(.local, "disk full") }
        let s6sends = Sends()
        await c.rejects("recovery: if the op record cannot be written, nothing is sent") {
            _ = try await noRecord.credential(clientId: "oaiappClientA", generation: g6) { r in s6sends.add(); return rotated(r) }
        }
        c.check("recovery: zero sends without a durable op record", s6sends.value == 0)
        // Logout before recovery: no send.
        let (s7, _, g7) = try await activeStore(root, tokens: tokens("H", expiresIn: 10))
        _ = try? await s7.credential(clientId: "oaiappClientA", generation: g7) { _ in throw URLError(.timedOut) }
        _ = try await s7.tombstone("oaiappClientA")
        let s7sends = Sends()
        _ = try? await s7.credential(clientId: "oaiappClientA", generation: g7) { r in s7sends.add(); return rotated(r) }
        c.check("recovery: never after sign-out", s7sends.value == 0)
    }

    /// The sign-out fence and in-flight registry (§3.7, §3.9 R2 step 2).
    static func fenceTests(_ root: URL, _ c: Checks) async throws {
        let fence = SIWCFence.shared
        let key = SIWCFence.key(store: root, clientId: "oaiappClientA")
        let epoch = fence.epoch(key)
        var cancelled = 0
        let token = try fence.register(key, epoch: epoch) { cancelled += 1 }
        c.check("fence: a running request is registered", fence.inflightCount(key) == 1)
        fence.fenceAndBump(key)
        c.check("fence: the pre-send check refuses after the fence", (try? fence.check(key, capturedEpoch: epoch)) == nil)
        c.check("fence: a request started after the fence is refused", (try? fence.register(key, epoch: fence.epoch(key)) {}) == nil)
        c.check("fence: sign-out cancels every registered request", fence.cancelAll(key) == 1 && cancelled == 1)
        fence.unregister(key, token)
        fence.unfence(key)
        c.check("fence: a captured epoch stays refused after unfencing (no revival)", (try? fence.check(key, capturedEpoch: epoch)) == nil)
        c.check("fence: a new operation captures the new epoch", (try? fence.check(key, capturedEpoch: fence.epoch(key))) != nil)
        let other = SIWCFence.key(store: root, clientId: "oaiappClientB")
        c.check("fence: other registrations are unaffected", (try? fence.check(other, capturedEpoch: fence.epoch(other))) != nil)
    }
}
