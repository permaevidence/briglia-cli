import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Codex round-1 findings on da414b2 (R1–R5), each as a permanent test.
extension RefreshSettleSelftest {
    func round2Tests(_ h: Harness, _ c: Checks) async throws {
        try await refusalDuringRecoveryKeepsLimit(h, c)
        try await accountBlockSaveFails(h, c)
        try await accountBlockCrash(h, c)
        try await cancelDuringOpWrite(h, c)
        try await cancelDuringRecoveryWrite(h, c)
        try await rotatedServerErrors(h, c)
        try await authDeadline(c)
    }

    /// R1: a recovery refused before sending (budget) must not erase the
    /// earlier uncertain send, or the limit resets (da414b2: 3 sends).
    func refusalDuringRecoveryKeepsLimit(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("r1-refusal-in-recovery", script: ["timeout", "timeout", "timeout", "timeout"])
        _ = await Self.outcome(s)
        let budget = SendBudget(limit: 0, exhausted: { AuthBudgetExhausted(limit: $0) })
        let login = Self.login(s)
        _ = try? await s.store.credential(generation: s.generation, refresh: ResponsesAdapter.refresher(login, budget))
        let op = Self.disk(s.store)["refreshOp"] as? [String: Any]
        c.check("R1 refused recovery: earlier ambiguous op kept, reservation released",
                op?["state"] as? String == "ambiguous" && Self.disk(s.store)["refreshRecovery"] == nil && s.server.sends() == 1)
        try await Self.join([try Self.spawn(s, mode: "refresh")])   // restart: a fresh process
        for _ in 0..<3 { _ = await Self.outcome(s) }
        c.check("R1 refused recovery: at most two sends in total, across a restart", s.server.sends() == 2)
    }

    /// R2: the account-change block fails to save; the bound checkpoint must
    /// still refuse the old token (da414b2: a second send).
    func accountBlockSaveFails(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("r2-block-save-fails", script: ["other-account"], lenient: true)
        let (store, fault) = Self.faulty(s, [2: .throwBefore])
        _ = await Self.outcome(s, store: store, fault: fault)
        c.check("R2 block save failed: checkpoint on disk, block not saved",
                Self.disk(s.store)["pendingRotation"] != nil && !Self.diskBlocked(s.store))
        let next = await Self.outcome(s)
        c.check("R2 block save failed: next request refuses, old token not sent again",
                next.hasPrefix("error:") && s.server.sends() == 1 && Self.diskBlocked(s.store))
        c.check("R2 block save failed: other account's tokens never active", Self.diskRefresh(s.store) == "r0")
    }

    /// R2, crash variant: the process dies right after the checkpoint.
    func accountBlockCrash(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("r2-block-crash", script: ["other-account"], lenient: true)
        try await Self.join([try Self.spawn(s, mode: "exit-after-exchange-2")])
        let next = await Self.outcome(s)
        c.check("R2 crash after mismatched checkpoint: restart refuses, no second send",
                next.hasPrefix("error:") && s.server.sends() == 1 && Self.diskBlocked(s.store) && Self.diskRefresh(s.store) == "r0")
    }

    /// A store whose first write (after arming) blocks until released.
    static func blockingStore(_ s: Scenario) -> (SubscriptionAuthStore, DispatchSemaphore, DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = OnceFlag()
        var store = s.store
        store.beforeWrite = { if first.claim() { entered.signal(); release.wait() } }
        return (store, entered, release)
    }

    /// R4: `/stop` lands while the pre-send record is being written
    /// (da414b2: the refresh was still sent once).
    func cancelDuringOpWrite(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("r4-cancel-during-op-write")
        let (store, entered, release) = Self.blockingStore(s)
        let task = Task { try await Self.refresh(s, store: store) }
        await Self.waitSemaphore(entered)
        task.cancel()
        _ = await task.result
        release.signal()
        try await Self.settled(s.store)
        c.check("R4 cancel during op write: nothing sent", s.server.sends() == 0)
        c.check("R4 cancel during op write: op record undone, login unchanged",
                Self.disk(s.store)["refreshOp"] == nil && Self.diskRefresh(s.store) == "r0")
        c.check("R4 cancel during op write: next request refreshes normally", await Self.outcome(s) == "ok:" + s.server.current() && s.server.sends() == 1)
    }

    /// R4 + R1: the stopped attempt was a recovery; undoing it keeps the
    /// earlier uncertain op, so the limit still holds.
    func cancelDuringRecoveryWrite(_ h: Harness, _ c: Checks) async throws {
        let s = try await h.scenario("r4-cancel-during-recovery-write", script: ["timeout", "timeout", "timeout"])
        _ = await Self.outcome(s)
        let (store, entered, release) = Self.blockingStore(s)
        let task = Task { try await Self.refresh(s, store: store) }
        await Self.waitSemaphore(entered)
        task.cancel()
        _ = await task.result
        release.signal()
        try await Self.settled(s.store)
        let op = Self.disk(s.store)["refreshOp"] as? [String: Any]
        c.check("R4 cancel during recovery write: not sent, earlier op restored, reservation released",
                s.server.sends() == 1 && op?["state"] as? String == "ambiguous" && Self.disk(s.store)["refreshRecovery"] == nil)
        for _ in 0..<3 { _ = await Self.outcome(s) }
        c.check("R4 cancel during recovery write: still at most two sends", s.server.sends() == 2)
    }

    /// R3: 500/503 after a rotation are ambiguous: one recovery, which a
    /// strict server refuses (sign-in) and a lenient one honours.
    func rotatedServerErrors(_ h: Harness, _ c: Checks) async throws {
        for status in ["500", "503"] {
            let strict = try await h.scenario("r3-rotated-\(status)-strict", script: ["rotated-\(status)"])
            for _ in 0..<3 { _ = await Self.outcome(strict) }
            c.check("R3 \(status) after rotation (strict): one recovery, then sign-in", strict.server.sends() == 2 && Self.diskBlocked(strict.store))
            let lenient = try await h.scenario("r3-rotated-\(status)-lenient", script: ["rotated-\(status)"], lenient: true)
            _ = await Self.outcome(lenient)
            let second = await Self.outcome(lenient)
            c.check("R3 \(status) after rotation (lenient): the one recovery restores the login",
                    second == "ok:" + lenient.server.current() && lenient.server.sends() == 2)
        }
    }

    /// R5: a reply that keeps trickling must not outlive the auth deadline,
    /// on the shared session (Linux production path) and the private one.
    func authDeadline(_ c: Checks) async throws {
        let server = try TrickleServer(seconds: 8)
        defer { server.stop() }
        for shared in [true, false] {
            let label = shared ? "shared session (forced on macOS)" : "private session"
            SharedDataTaskSession.forceForTesting = shared
            defer { SharedDataTaskSession.forceForTesting = false }
            let http = SubscriptionAuthHTTP(deadline: 1.5, issuer: "http://127.0.0.1:\(server.port)")
            let started = ProcessInfo.processInfo.systemUptime
            var failed = false
            do { _ = try await http.post(path: "/oauth/token", fields: ["grant_type": "refresh_token"], form: true) } catch { failed = !(error is CancellationError) }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            c.check("R5 \(label): trickling reply ends at the deadline (\(String(format: "%.2f", elapsed)) s), as a network failure",
                    failed && elapsed < 4)
        }
        c.check("R5 shared session: no route left behind", SharedDataTaskSession.shared.routedTaskCount == 0)
        c.check("R5 trickle server was reached", server.connections > 0)
    }

    static func waitSemaphore(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { semaphore.wait(); done.resume() }
        }
    }
}

/// True exactly once (the first call), for gating the first write.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

/// Loopback HTTP server: answers 200 with a large Content-Length, then sends
/// one byte every 200 ms for `seconds`. Each byte resets an idle timeout, so
/// only an overall deadline ends the request early.
final class TrickleServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private var accepted = 0
    var connections: Int { lock.lock(); defer { lock.unlock() }; return accepted }

    init(seconds: Double) throws {
        #if canImport(Glibc)
        let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard sock >= 0 else { throw SubscriptionError("trickle socket") }
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(sock, 8) == 0 else { close(sock); throw SubscriptionError("trickle bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) } }
        fd = sock
        port = Int(UInt16(bigEndian: address.sin_port))
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                guard let self else { close(client); return }
                self.lock.lock(); self.accepted += 1; let done = self.stopped; self.lock.unlock()
                if done { close(client); return }
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    _ = read(client, &buffer, buffer.count)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100000\r\n\r\n"
                    _ = head.withCString { write(client, $0, strlen($0)) }
                    let end = ProcessInfo.processInfo.systemUptime + seconds
                    while ProcessInfo.processInfo.systemUptime < end {
                        if write(client, " ", 1) != 1 { break }
                        usleep(200_000)
                    }
                    close(client)
                }
            }
        }
    }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        shutdown(fd, Int32(SHUT_RDWR)); close(fd)
    }
}
