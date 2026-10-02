import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Drains a child process's stdout / stderr pipes on dedicated threads WHILE
/// the child runs.
///
/// Reading a pipe only after the child exits deadlocks as soon as the child
/// writes more than one pipe buffer (~64 KB on macOS and Linux): the child
/// blocks in write(), the parent blocks waiting for its exit. Each pipe here
/// is read with plain read(2) on its own thread from launch to EOF, so the
/// child can never fill a buffer. No readabilityHandler is used, so the whole
/// stream is captured on Linux corelibs too (handlers drop the tail there).
///
/// Use: create the pipes, `try process.run()`, then `start()`, wait for the
/// exit however the call site already does, then `finish(within:)`.
///
/// Each stream keeps at most `limit` bytes; anything beyond is still read
/// (so the child never blocks) but dropped, and the stream is flagged as
/// truncated. Reading after exit used to bound memory at one pipe buffer;
/// this keeps a child that writes without end from growing Briglia's memory
/// until its timeout.
final class ProcessOutputCapture: @unchecked Sendable {
    /// Far above any real output of these helpers (gws JSON, unzip listings,
    /// brew/pip logs, shortcut results).
    static let defaultLimit = 64 * 1024 * 1024

    struct Output {
        let stdout: Data
        let stderr: Data
        let stdoutTruncated: Bool
        let stderrTruncated: Bool
    }

    private let stdoutReader: Reader?
    private let stderrReader: Reader?
    private let started = DispatchSemaphore(value: 0)

    init(stdout: Pipe?, stderr: Pipe?, limit: Int = defaultLimit) {
        stdoutReader = stdout.map { Reader($0.fileHandleForReading, limit: limit) }
        stderrReader = stderr.map { Reader($0.fileHandleForReading, limit: limit) }
    }

    /// Starts the readers. Call only after `process.run()` succeeded: before
    /// that the parent still holds the pipes' write ends, so EOF would never
    /// arrive.
    func start() {
        stdoutReader?.start()
        stderrReader?.start()
        started.signal()
    }

    /// Waits up to `grace` for both streams to reach EOF (the child has
    /// normally exited by now, so this is the time to read what is left in
    /// the pipe, microseconds in practice) and returns everything read. If a
    /// descendant still holds a write end, returns what was read so far and
    /// abandons the blocked reader thread instead of waiting forever.
    func finish(within grace: TimeInterval) -> Output {
        let deadline = Date().addingTimeInterval(grace)
        // A terminationHandler can fire before the launching code reached
        // start(); give it the same grace.
        if started.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success {
            started.signal()
        } else {
            return Output(stdout: Data(), stderr: Data(), stdoutTruncated: false, stderrTruncated: false)
        }
        stdoutReader?.wait(until: deadline)
        stderrReader?.wait(until: deadline)
        let out = stdoutReader?.snapshot ?? (Data(), false)
        let err = stderrReader?.snapshot ?? (Data(), false)
        return Output(stdout: out.0, stderr: err.0, stdoutTruncated: out.1, stderrTruncated: err.1)
    }

    /// Polls for exit instead of calling the unbounded waitUntilExit (which on
    /// Linux can also be held open by descriptors a grandchild inherited).
    static func waitForExit(_ process: Process, until deadline: Date, pollMicroseconds: UInt32 = 2_000) -> Bool {
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(pollMicroseconds)
        }
        return true
    }

    /// Reads one pipe to EOF on its own thread, keeping a snapshot readable.
    private final class Reader: @unchecked Sendable {
        private let handle: FileHandle
        private let limit: Int
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var buffer = Data()
        private var truncated = false

        init(_ handle: FileHandle, limit: Int) { self.handle = handle; self.limit = limit }

        func start() {
            let thread = Thread { [self] in
                let fd = handle.fileDescriptor
                var chunk = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if n > 0 {
                        lock.lock()
                        let room = max(0, limit - buffer.count)
                        if n > room { truncated = true }
                        if room > 0 { buffer.append(contentsOf: chunk[0..<min(n, room)]) }
                        lock.unlock()
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        break // EOF or a read error
                    }
                }
                done.signal()
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }

        func wait(until deadline: Date) {
            if done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success {
                done.signal() // keep later waits non-blocking
            }
        }

        var snapshot: (Data, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (buffer, truncated)
        }
    }
}
