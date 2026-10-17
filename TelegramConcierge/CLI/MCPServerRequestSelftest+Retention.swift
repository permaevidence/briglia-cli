import Foundation

/// §5 of `__mcp-server-request-selftest` (Codex 0.2.55 round-2 R1): a frame
/// the writer has delivered must be released at once. The memory the
/// queue holds is bounded by the bytes still waiting to be written, even
/// when fewer than 257 frames were sent and the client stays open and idle.
/// Real pipes and a reader that keeps draining; production limits.
extension MCPServerRequestSelftest {

    static func runRetention(tempRoot: URL, check: (String, Bool, String) -> Void) async throws {
        print("— §5 delivered frames are released")
        retentionPipe(frames: 200, size: 128 << 10, id: "5.1", check: check)   // Codex's shape: 25 MiB
        retentionPipe(frames: 40, size: 1 << 20, id: "5.2", check: check)      // 40 MiB in 40 frames
        try await retentionClient(tempRoot: tempRoot, check: check)
        retentionBacklog(check: check)
        retentionClose(check: check)
    }

    /// A backlog that never empties: two frames are kept outstanding the
    /// whole time (the next is queued as soon as one is delivered), so the
    /// queue is never drained before the end. Delivered frames must still
    /// be released one by one.
    static func retentionBacklog(check: (String, Bool, String) -> Void) {
        let size = 256 << 10, frames = 100
        let pipe = Pipe()
        let readFD = pipe.fileHandleForReading.fileDescriptor
        let fd = dup(pipe.fileHandleForWriting.fileDescriptor)
        try? pipe.fileHandleForWriting.close()
        let readerDone = DispatchSemaphore(value: 0)
        Thread {
            var buf = [UInt8](repeating: 0, count: 16384)
            while read(readFD, &buf, buf.count) > 0 { usleep(50) }
            readerDone.signal()
        }.start()
        let writer = MCPOutboundPipe(fd: fd, label: "retention-backlog", limits: .standard) { _ in }
        var worst = 0, emptied = 0, ok = true
        func sample() {
            let a = writer.accountingForTesting
            worst = max(worst, a.retained - a.pending)
        }
        for n in 0..<frames {
            do { try writer.enqueue(Data(repeating: UInt8(n & 0xff), count: size)) } catch { ok = false; break }
            if n == 0 { continue }
            let deadline = Date().addingTimeInterval(5)
            // Wait until at most one frame is outstanding, then queue the next.
            while writer.accountingForTesting.pending > size && Date() < deadline { sample(); usleep(200) }
            sample()
            if writer.accountingForTesting.pending == 0 { emptied += 1 }
            if writer.accountingForTesting.pending > size { ok = false; break }
        }
        let deadline = Date().addingTimeInterval(5)
        while writer.accountingForTesting.pending != 0 && Date() < deadline { sample(); usleep(200) }
        usleep(100_000)
        let idle = writer.accountingForTesting
        check("5.5 constant backlog (\(frames) × 256 KiB, queue emptied early \(emptied)×): never held more than pending (worst excess \(worst) bytes), idle \(idle.retained)/\(idle.pending)",
              ok && worst == 0 && idle.retained == 0 && idle.pending == 0, "ok=\(ok)")
        writer.close()
        _ = readerDone.wait(timeout: .now() + 3)
        try? pipe.fileHandleForReading.close()
    }

    /// Nobody reads: frames pile up behind the full pipe; close() drops
    /// them and releases their memory at once.
    static func retentionClose(check: (String, Bool, String) -> Void) {
        let pipe = Pipe()
        let fd = dup(pipe.fileHandleForWriting.fileDescriptor)
        try? pipe.fileHandleForWriting.close()
        let writer = MCPOutboundPipe(fd: fd, label: "retention-close", limits: .standard) { _ in }
        for n in 0..<12 { try? writer.enqueue(Data(repeating: UInt8(n), count: 256 << 10)) }
        usleep(100_000)
        let before = writer.accountingForTesting
        writer.close()
        let after = writer.accountingForTesting
        check("5.6 close() with \(before.pending >> 10) KiB still queued releases it all (now \(after.retained)/\(after.pending))",
              before.pending > 0 && after.retained == 0 && after.pending == 0, "")
        try? pipe.fileHandleForReading.close()
    }

    /// Enqueue `frames` separately allocated frames one at a time, waiting
    /// for each to drain. A sampler checks, under the writer's lock, that
    /// the queue never holds more payload than it still has to write.
    static func retentionPipe(frames: Int, size: Int, id: String, check: (String, Bool, String) -> Void) {
        let pipe = Pipe()
        let readFD = pipe.fileHandleForReading.fileDescriptor
        let fd = dup(pipe.fileHandleForWriting.fileDescriptor)
        try? pipe.fileHandleForWriting.close()
        let readerDone = DispatchSemaphore(value: 0)
        Thread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while read(readFD, &buf, buf.count) > 0 {}
            readerDone.signal()
        }.start()
        let failure = RetentionBox<String?>(nil)
        let writer = MCPOutboundPipe(fd: fd, label: "retention-\(id)", limits: .standard) { reason in
            failure.set(reason)
        }
        let worst = RetentionBox(0)          // largest (retained - pending) seen
        let sampling = RetentionBox(true)
        let samplerDone = DispatchSemaphore(value: 0)
        Thread {
            while sampling.get() {
                let a = writer.accountingForTesting
                if a.retained - a.pending > worst.get() { worst.set(a.retained - a.pending) }
                usleep(200)
            }
            samplerDone.signal()
        }.start()
        var drained = true
        for n in 0..<frames {
            do { try writer.enqueue(Data(repeating: UInt8(n & 0xff), count: size)) } catch { drained = false; break }
            let deadline = Date().addingTimeInterval(5)
            while writer.accountingForTesting.pending != 0 && Date() < deadline { usleep(500) }
            if writer.accountingForTesting.pending != 0 { drained = false; break }
        }
        sampling.set(false)
        samplerDone.wait()
        // Idle and still open: nothing delivered may stay behind.
        usleep(100_000)
        let idle = writer.accountingForTesting
        let total = frames * size
        check("\(id) \(frames) × \(size >> 10) KiB sent and drained (\(total >> 20) MiB, cap \(MCPOutboundPipe.Limits.standard.maxQueuedBytes >> 20) MiB)",
              drained && failure.get() == nil, "drained=\(drained) failure=\(failure.get() ?? "none")")
        check("\(id) idle open writer retains \(idle.retained) bytes with \(idle.pending) pending (must be 0/0)",
              idle.retained == 0 && idle.pending == 0, "")
        check("\(id) queue never held more than its pending bytes (worst excess \(worst.get()) bytes)",
              worst.get() == 0, "")
        writer.close()
        _ = readerDone.wait(timeout: .now() + 3)
        try? pipe.fileHandleForReading.close()
    }

    /// Through a real MCPClient: 40 sequential 1 MiB tool calls (well past
    /// the 16 MiB cap in total, fewer than 257 frames), each answered by the
    /// server, then the client sits idle and open.
    static func retentionClient(tempRoot: URL, check: (String, Bool, String) -> Void) async throws {
        let client = try await floodClient(tempRoot: tempRoot, mode: "slow-reader")
        try await client.initialize(timeout: 5)
        let blob = String(repeating: "y", count: 1 << 20)
        var answered = 0
        for _ in 0..<40 {
            if let r = try? await client.callTool(name: "big", arguments: ["blob": blob]),
               r.text == "big:\(1 << 20)" { answered += 1 }
        }
        _ = await waitFor(seconds: 2) { (await client.outboundAccountingForTesting())?.pending == 0 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let a = await client.outboundAccountingForTesting()
        let alive = await client.isAlive
        await client.shutdown()
        check("5.3 client: 40 × 1 MiB calls answered (\(answered)/40), client still open",
              answered == 40 && alive, "")
        check("5.4 client: idle writer retains \(a?.retained ?? -1) bytes with \(a?.pending ?? -1) pending (must be 0/0)",
              a?.retained == 0 && a?.pending == 0, "")
    }
}

/// Minimal lock box for the sampler/reader threads above.
final class RetentionBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
