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
/// is read with plain read(2) on its own thread from launch, so the child can
/// never fill a buffer. No readabilityHandler is used, so the whole stream is
/// captured on Linux corelibs too (handlers drop the tail there).
///
/// Use: create the pipes, `try process.run()`, then `start()`, wait for the
/// exit however the call site already does, then `finish(within:)`.
///
/// Completeness is reported, never implied: each stream says whether it
/// reached EOF, hit a read error, or was cut at `limit`. Callers that need
/// the whole output must check `stdoutProblem` and fail on it.
///
/// Reader lifetime is bounded by `finish`: if a stream has not reached EOF
/// by the grace deadline (a descendant still holds the write end), its
/// reader is told to stop, leaves its poll loop within one poll interval,
/// closes its read end and exits. Nothing is left running after `finish`
/// returns; a descendant that keeps writing afterwards gets EPIPE / SIGPIPE,
/// as with any reader that stops reading. Descendants are never signalled.
///
/// Each stream keeps at most `limit` bytes; anything beyond is still read
/// (so the child never blocks) but dropped, and the stream is flagged as
/// truncated.
final class ProcessOutputCapture: @unchecked Sendable {
    /// Far above any real output of these helpers (gws JSON, unzip listings,
    /// brew/pip logs, shortcut results).
    static let defaultLimit = 64 * 1024 * 1024
    static var defaultLimitLabel: String { "\(defaultLimit / 1_048_576) MB" }

    /// How a stream ended.
    enum StreamEnd: Equatable, Sendable {
        /// Read to EOF: every byte the child wrote was read.
        case eof
        /// Still open at the grace deadline (a descendant holds the write
        /// end, or the child never exited); the reader was stopped.
        case stillOpen
        /// read(2) failed with this errno.
        case readError(Int32)
        /// The readers were never started (finish before start).
        case notStarted
    }

    struct Output: Sendable {
        let stdout: Data
        let stderr: Data
        let stdoutTruncated: Bool
        let stderrTruncated: Bool
        let stdoutEnd: StreamEnd
        let stderrEnd: StreamEnd

        var stdoutComplete: Bool { stdoutProblem == nil }

        /// Why stdout is not the child's complete output, or nil when it is.
        /// Worded to follow "output …" in an error message.
        var stdoutProblem: String? { Self.problem(truncated: stdoutTruncated, end: stdoutEnd) }

        static func problem(truncated: Bool, end: StreamEnd) -> String? {
            if truncated { return "exceeded \(ProcessOutputCapture.defaultLimitLabel)" }
            switch end {
            case .eof: return nil
            case .stillOpen: return "was still open when the process ended (a background process kept it open); it may be incomplete"
            case .readError(let code): return "could not be read completely (read error \(code))"
            case .notStarted: return "was not captured"
            }
        }
    }

    // MARK: - Test hooks

    private static let countersLock = NSLock()
    nonisolated(unsafe) private static var _liveReaderThreads = 0
    nonisolated(unsafe) private static var _bufferedBytes = 0
    /// Reader threads still running (selftest: must return to its baseline
    /// right after `finish`, even while a descendant holds the pipe).
    static var liveReaderThreads: Int { countersLock.lock(); defer { countersLock.unlock() }; return _liveReaderThreads }
    /// Bytes still held in reader buffers (moved out to the caller by
    /// `finish`, so this also returns to its baseline).
    static var bufferedBytes: Int { countersLock.lock(); defer { countersLock.unlock() }; return _bufferedBytes }
    fileprivate static func adjust(threads: Int = 0, bytes: Int = 0) {
        countersLock.lock(); _liveReaderThreads += threads; _bufferedBytes += bytes; countersLock.unlock()
    }

    // MARK: -

    private let stdoutReader: Reader?
    private let stderrReader: Reader?
    private let stateLock = NSLock()
    private var startedFlag = false
    private let started = DispatchSemaphore(value: 0)

    init(stdout: Pipe?, stderr: Pipe?, limit: Int = defaultLimit) {
        stdoutReader = stdout.map { Reader($0.fileHandleForReading, limit: limit) }
        stderrReader = stderr.map { Reader($0.fileHandleForReading, limit: limit) }
    }

    /// Starts the readers. Call only after `process.run()` succeeded: before
    /// that the parent still holds the pipes' write ends, so EOF would never
    /// arrive.
    func start() {
        stateLock.lock()
        guard !startedFlag else { stateLock.unlock(); return }
        startedFlag = true
        stateLock.unlock()
        stdoutReader?.start()
        stderrReader?.start()
        started.signal()
    }

    /// Waits up to `grace` for both streams to reach EOF (the child has
    /// normally exited by now, so this is the time to read what is left in
    /// the pipe, microseconds in practice), then stops any reader still
    /// waiting and returns what was read with how each stream ended. Returns
    /// within `grace` plus one reader poll interval; no reader thread is left
    /// running. Call once.
    func finish(within grace: TimeInterval) -> Output {
        let deadline = Date().addingTimeInterval(grace)
        // A terminationHandler can fire before the launching code reached
        // start(); give it the same grace.
        if started.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success {
            started.signal()
        } else {
            return Output(stdout: Data(), stderr: Data(), stdoutTruncated: false, stderrTruncated: false,
                          stdoutEnd: stdoutReader == nil ? .eof : .notStarted,
                          stderrEnd: stderrReader == nil ? .eof : .notStarted)
        }
        stdoutReader?.wait(until: deadline)
        stderrReader?.wait(until: deadline)
        // Stop whatever has not reached EOF, then wait for the threads to
        // leave (bounded by one poll interval; the extra seconds are only a
        // guard against a stalled scheduler).
        stdoutReader?.cancel()
        stderrReader?.cancel()
        stdoutReader?.waitStopped(seconds: 5)
        stderrReader?.waitStopped(seconds: 5)
        let out = stdoutReader?.take() ?? (Data(), false, .eof)
        let err = stderrReader?.take() ?? (Data(), false, .eof)
        return Output(stdout: out.0, stderr: err.0, stdoutTruncated: out.1, stderrTruncated: err.1,
                      stdoutEnd: out.2, stderrEnd: err.2)
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

    /// Valid UTF-8 text for `data` that is never empty when `data` is not:
    /// invalid or cut sequences become U+FFFD instead of discarding the text.
    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Reads one pipe on its own thread. The descriptor is owned by the
    /// reader thread: it is made non-blocking, polled with a short timeout so
    /// a cancel request is seen promptly, and closed by that thread when it
    /// stops, so no other thread ever closes an fd the reader may be using.
    private final class Reader: @unchecked Sendable {
        static let pollMilliseconds: Int32 = 50

        private let handle: FileHandle
        private let limit: Int
        private let stopped = DispatchSemaphore(value: 0)
        private let eofReached = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var buffer = Data()
        private var truncated = false
        private var end: StreamEnd = .stillOpen
        private var cancelled = false

        init(_ handle: FileHandle, limit: Int) {
            self.handle = handle
            self.limit = limit
        }

        deinit { ProcessOutputCapture.adjust(bytes: -buffer.count) }

        func start() {
            ProcessOutputCapture.adjust(threads: 1)
            let thread = Thread { [self] in
                run()
                try? handle.close()
                ProcessOutputCapture.adjust(threads: -1)
                stopped.signal()
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }

        private func run() {
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            var chunk = [UInt8](repeating: 0, count: 262_144)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while true {
                lock.lock(); let stop = cancelled; lock.unlock()
                if stop { return } // end stays .stillOpen
                pfd.revents = 0
                let ready = poll(&pfd, 1, Self.pollMilliseconds)
                if ready < 0 {
                    if errno == EINTR { continue }
                    finishWith(.readError(errno)); return
                }
                if ready == 0 { continue }
                // Readable, hung up or error: drain until EAGAIN or EOF.
                while true {
                    lock.lock(); let stopNow = cancelled; lock.unlock()
                    if stopNow { return } // a child writing without pause
                    let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if n > 0 {
                        lock.lock()
                        let room = max(0, limit - buffer.count)
                        if n > room { truncated = true }
                        let kept = min(n, room)
                        if kept > 0 { buffer.append(contentsOf: chunk[0..<kept]) }
                        lock.unlock()
                        if kept > 0 { ProcessOutputCapture.adjust(bytes: kept) }
                        continue
                    }
                    if n == 0 { finishWith(.eof); return }
                    let code = errno
                    if code == EINTR { continue }
                    if code == EAGAIN || code == EWOULDBLOCK { break }
                    finishWith(.readError(code)); return
                }
            }
        }

        private func finishWith(_ e: StreamEnd) {
            lock.lock(); end = e; lock.unlock()
            eofReached.signal()
        }

        /// Waits until the stream ended on its own (EOF / error) or `deadline`.
        func wait(until deadline: Date) {
            if eofReached.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success {
                eofReached.signal()
            }
        }

        func cancel() { lock.lock(); cancelled = true; lock.unlock() }

        func waitStopped(seconds: TimeInterval) {
            if stopped.wait(timeout: .now() + seconds) == .success { stopped.signal() }
        }

        /// Moves the captured bytes out (the reader keeps no copy) together
        /// with how the stream ended.
        func take() -> (Data, Bool, StreamEnd) {
            lock.lock(); defer { lock.unlock() }
            let data = buffer
            buffer = Data()
            ProcessOutputCapture.adjust(bytes: -data.count)
            return (data, truncated, end)
        }
    }
}
