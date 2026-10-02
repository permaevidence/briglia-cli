import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Unified-diff helper for write_file / edit_file / apply_patch results.
/// Shells out to /usr/bin/diff (always present on macOS) to produce a
/// standard unified-diff payload, then caps large output so huge rewrites do
/// not bloat the tool result. The diff goes into the *current turn's*
/// tool result only — it never enters the cached system-prompt prefix, so
/// there is no prompt-cache impact.
enum DiffUtil {

    /// Return a unified diff of `old` → `new`, or nil if diff is empty / the
    /// subprocess fails. The caller should treat nil as "no diff to show".
    ///
    /// - Parameters:
    ///   - old: pre-image text. Pass "" when creating a new file.
    ///   - new: post-image text.
    ///   - path: absolute path of the file — used only in the diff headers
    ///     (`--- a/<path>` / `+++ b/<path>`) so the model sees a meaningful
    ///     location instead of a tmpfile path.
    ///   - context: number of context lines around each hunk (default 3).
    ///   - maxLines: cap on total diff lines returned (default 400).
    ///   - maxBytes: cap on total diff bytes returned (default 64 KB).
    ///   - timeout: backstop deadline for the diff subprocess; on expiry it is
    ///     killed and reaped and the result is nil ("no diff").
    ///   - executable: diff binary (tests substitute a stand-in).
    static func unifiedDiff(
        old: String,
        new: String,
        path: String,
        context: Int = 3,
        maxLines: Int = 400,
        maxBytes: Int = 64 * 1024,
        timeout: TimeInterval = defaultTimeout,
        executable: String = "/usr/bin/diff"
    ) -> String? {
        if old == new { return nil }

        let tmpDir = FileManager.default.temporaryDirectory
        let stamp = UUID().uuidString.prefix(8)
        let oldURL = tmpDir.appendingPathComponent("ada-diff-\(stamp).old")
        let newURL = tmpDir.appendingPathComponent("ada-diff-\(stamp).new")
        defer {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: newURL)
        }
        do {
            try (old.data(using: .utf8) ?? Data()).write(to: oldURL, options: .atomic)
            try (new.data(using: .utf8) ?? Data()).write(to: newURL, options: .atomic)
        } catch {
            return nil
        }

        guard let data = runDiff(
            arguments: ["-u", "-U", String(context), oldURL.path, newURL.path],
            executable: executable,
            timeout: timeout
        ) else { return nil }
        guard var text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return nil
        }

        // Replace tmpfile paths in the two header lines with the real path.
        text = text.replacingOccurrences(of: oldURL.path, with: "a/" + path)
        text = text.replacingOccurrences(of: newURL.path, with: "b/" + path)

        return cap(text, maxLines: maxLines, maxBytes: maxBytes)
    }

    /// Backstop only: diff of two files Briglia just held in memory finishes
    /// in well under a second even for megabyte rewrites.
    static let defaultTimeout: TimeInterval = 10

    /// Runs diff and returns its stdout when it exits 1 ("files differ"),
    /// nil otherwise.
    ///
    /// stdout is read to EOF on a background thread WHILE diff runs. Waiting
    /// for exit first deadlocks as soon as the output exceeds the pipe buffer
    /// (~64 KB): diff blocks writing, Briglia blocks waiting. stderr goes to
    /// /dev/null so it can never fill a pipe either. readDataToEndOfFile on a
    /// thread (no readabilityHandler) captures the whole stream on Linux
    /// corelibs too. A deadline backs this up: on expiry diff is killed, its
    /// reader is given a bounded time to see EOF, and the process is reaped.
    static func runDiff(arguments: [String], executable: String, timeout: TimeInterval) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let reader = PipeDrain(outPipe.fileHandleForReading)
        let deadline = Date().addingTimeInterval(timeout)
        guard reader.wait(until: deadline), waitForExit(proc, until: deadline) else {
            kill(proc.processIdentifier, SIGKILL)
            _ = reader.wait(until: Date().addingTimeInterval(2))
            _ = waitForExit(proc, until: Date().addingTimeInterval(2))
            return nil
        }
        // `diff` exits 0 when identical, 1 when different, 2 on trouble.
        guard proc.terminationReason == .exit, proc.terminationStatus == 1 else { return nil }
        return reader.data
    }

    /// Polls instead of calling waitUntilExit, which is unbounded (and on
    /// Linux can be held open by inherited descriptors).
    private static func waitForExit(_ proc: Process, until deadline: Date) -> Bool {
        while proc.isRunning {
            if Date() >= deadline { return false }
            usleep(2_000)
        }
        return true
    }

    /// Reads a pipe to EOF on its own thread.
    private final class PipeDrain: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var buffer = Data()
        private var finished = false

        init(_ handle: FileHandle) {
            let thread = Thread { [self] in
                let data = handle.readDataToEndOfFile()
                lock.lock(); buffer = data; finished = true; lock.unlock()
                done.signal()
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }

        /// True once EOF was reached before `deadline`.
        func wait(until deadline: Date) -> Bool {
            lock.lock(); let already = finished; lock.unlock()
            if already { return true }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            if done.wait(timeout: .now() + remaining) == .success {
                done.signal() // keep later waits non-blocking
                return true
            }
            return false
        }

        var data: Data {
            lock.lock(); defer { lock.unlock() }
            return buffer
        }
    }

    private static func cap(_ text: String, maxLines: Int, maxBytes: Int) -> String {
        var truncated = false
        var working = text
        let rawLines = working.split(separator: "\n", omittingEmptySubsequences: false)
        if rawLines.count > maxLines {
            working = rawLines.prefix(maxLines).joined(separator: "\n")
            truncated = true
        }
        if working.utf8.count > maxBytes {
            let clipped = Array(working.utf8).prefix(maxBytes)
            working = String(bytes: clipped, encoding: .utf8) ?? working
            truncated = true
        }
        if truncated {
            working += "\n… [diff truncated at \(maxLines) lines / \(maxBytes) bytes]"
        }
        return working
    }
}
