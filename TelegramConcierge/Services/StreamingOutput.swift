import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Streaming building blocks for subprocess output capture.
///
/// Foreground bash previously read its pipes only after the child exited,
/// which deadlocks once a chatty command fills the ~64KB kernel pipe buffer
/// (child blocks on write, Briglia waits for exit, timeout fires and mislabels
/// the run). These types let the pipes be drained continuously while keeping
/// two invariants that whole-buffer processing used to provide:
///
/// - UTF-8 sequences split across pipe chunks decode correctly
///   (`IncrementalUTF8Decoder` holds incomplete trailing bytes).
/// - Secrets split across pipe chunks are still redacted before any byte
///   reaches disk (`StreamingRedactor` holds back a carry window sized to
///   the longest secret).

// MARK: - Incremental UTF-8 decoding

/// Decodes UTF-8 across arbitrary chunk boundaries. A multibyte character
/// split between two kernel reads is held back until its continuation bytes
/// arrive. Genuinely invalid bytes decode lossily (U+FFFD) instead of the
/// old behavior of discarding the entire chunk.
struct IncrementalUTF8Decoder {
    private var pending: [UInt8] = []

    mutating func decode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var bytes = pending
        pending = []
        bytes.append(contentsOf: data)
        let hold = Self.incompleteSuffixLength(bytes)
        if hold > 0 {
            pending = Array(bytes.suffix(hold))
            bytes.removeLast(hold)
        }
        guard !bytes.isEmpty else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Decode whatever is still pending (stream ended mid-character → U+FFFD).
    mutating func flush() -> String {
        guard !pending.isEmpty else { return "" }
        let rest = pending
        pending = []
        return String(decoding: rest, as: UTF8.self)
    }

    /// Number of trailing bytes that form an incomplete (but so far valid)
    /// multibyte sequence. 0 when the buffer ends on a complete character or
    /// on bytes that can never become valid (those decode lossily instead).
    static func incompleteSuffixLength(_ bytes: [UInt8]) -> Int {
        let n = bytes.count
        guard n > 0 else { return 0 }
        var i = n - 1
        let lowest = max(0, n - 4)
        while i >= lowest {
            let b = bytes[i]
            if b & 0b1000_0000 == 0 { return 0 }                 // ASCII — complete
            if b & 0b1100_0000 == 0b1100_0000 {                  // lead byte
                let needed: Int
                if b & 0b1110_0000 == 0b1100_0000 { needed = 2 }
                else if b & 0b1111_0000 == 0b1110_0000 { needed = 3 }
                else if b & 0b1111_1000 == 0b1111_0000 { needed = 4 }
                else { return 0 }                                // invalid lead — lossy decode
                let have = n - i
                return have < needed ? have : 0
            }
            i -= 1                                               // continuation byte — keep scanning
        }
        return 0                                                 // 4+ continuations — invalid, lossy decode
    }
}

// MARK: - Streaming secret redaction

/// Redacts secrets from a stream without ever emitting a partial secret.
/// Text is emitted only up to a cut point that (a) leaves a carry window of
/// `longest secret - 1` characters, so a secret straddling two chunks can
/// still complete, and (b) never splits an occurrence that is already fully
/// present. Everything returned by `process`/`flush` is safe to persist.
final class StreamingRedactor {
    private let redactor: BashTools.SecretRedactor
    private let secrets: [String]
    private let holdback: Int
    private var carry = ""

    init(environment: [String: String] = KeychainHelper.redactionEnvironment()) {
        self.redactor = BashTools.SecretRedactor(environment: environment)
        self.secrets = environment.values.filter { !$0.isEmpty }
        self.holdback = max(0, (secrets.map { $0.count }.max() ?? 0) - 1)
    }

    /// Feed a decoded chunk; returns the redacted prefix that is safe to emit
    /// now (possibly empty while the carry window fills).
    func process(_ text: String) -> String {
        guard holdback > 0 else { return redactor.redact(text) }
        carry += text
        guard carry.count > holdback else { return "" }
        var cut = carry.count - holdback

        // Collect every occurrence of every secret, then lower the cut until
        // no fully-present occurrence straddles it. Lowering the cut for one
        // secret can newly straddle another, so iterate to a fixpoint (the
        // cut is monotonically decreasing → terminates).
        var occurrences: [(start: Int, end: Int)] = []
        for s in secrets {
            var searchFrom = carry.startIndex
            while let r = carry.range(of: s, range: searchFrom..<carry.endIndex) {
                occurrences.append((
                    start: carry.distance(from: carry.startIndex, to: r.lowerBound),
                    end: carry.distance(from: carry.startIndex, to: r.upperBound)
                ))
                searchFrom = r.upperBound
            }
        }
        var changed = true
        while changed {
            changed = false
            for occ in occurrences where occ.start < cut && occ.end > cut {
                cut = occ.start
                changed = true
            }
        }
        guard cut > 0 else { return "" }
        let cutIdx = carry.index(carry.startIndex, offsetBy: cut)
        let emit = String(carry[..<cutIdx])
        carry = String(carry[cutIdx...])
        return redactor.redact(emit)
    }

    /// Stream ended — redact and release the carry window.
    func flush() -> String {
        guard !carry.isEmpty else { return "" }
        let rest = carry
        carry = ""
        return redactor.redact(rest)
    }

    /// The held-back carry window, redacted, WITHOUT consuming it. A live
    /// view (bash_manage output of a running job) shows it after the
    /// emitted text so nothing the process wrote is hidden; a secret still
    /// incomplete at the very end shows as its visible prefix, exactly as the
    /// old wholesale re-redaction of the rolling buffer did.
    func pendingRedacted() -> String {
        guard !carry.isEmpty else { return "" }
        return redactor.redact(carry)
    }
}

// MARK: - Bounded string surgery

/// UTF-8-byte-based helpers for bounded buffers. `String.suffix(n)` walks n
/// grapheme clusters, so trimming a rolling buffer with it on EVERY chunk made
/// per-chunk cost proportional to the buffer, not the chunk (bash flood fix,
/// 2026-10-08). These cut on Unicode-scalar boundaries by byte count instead.
enum BoundedText {
    /// The last `maxBytes` UTF-8 bytes of `s`, advanced to the next scalar
    /// boundary (never splits a multibyte character).
    static func suffix(_ s: String, maxBytes: Int) -> String {
        let u = s.utf8
        guard u.count > maxBytes else { return s }
        var i = u.index(u.endIndex, offsetBy: -max(0, maxBytes))
        while i < u.endIndex, (u[i] & 0xC0) == 0x80 { i = u.index(after: i) }
        return String(decoding: u[i...], as: UTF8.self)
    }

    /// The first `maxBytes` UTF-8 bytes of `s`, cut back to a scalar
    /// boundary (never splits a multibyte character).
    static func prefix(_ s: String, maxBytes: Int) -> String {
        prefix(s[...], maxBytes: maxBytes)
    }

    static func prefix(_ s: Substring, maxBytes: Int) -> String {
        let u = s.utf8
        guard u.count > maxBytes else { return String(s) }
        guard maxBytes > 0 else { return "" }
        var i = u.index(u.startIndex, offsetBy: maxBytes)
        while i > u.startIndex, (u[i] & 0xC0) == 0x80 { i = u.index(before: i) }
        return String(decoding: u[u.startIndex..<i], as: UTF8.self)
    }
}

// MARK: - Pipe stream reader

/// Byte-level consumer for a `PipeStreamReader`. An empty `Data` marks EOF
/// (all writers closed); it may never arrive if an orphan holds the write
/// end, so owners must be able to finalize without it.
protocol PipeByteSink: AnyObject, Sendable {
    func ingest(_ data: Data)
}

/// Drains one pipe read-end on a detached task using nonblocking `read(2)`.
///
/// Deliberately NOT built on FileHandle.readabilityHandler: on Linux,
/// swift-corelibs-foundation stopped delivering the final pipe-buffered
/// chunks and never surfaced EOF once the child exited — CI lost exactly
/// ≤64KB (one pipe buffer) from the tail of every large stream, and the
/// orphan-pipe grace never engaged. A plain poll loop over the fd has
/// identical semantics on Darwin and Glibc, guarantees per-stream ordering,
/// and owns the post-exit grace itself:
///
/// - data → ingest into the collector, keep reading
/// - EOF (read()==0) → done (all writers closed)
/// - EAGAIN → if the process has exited and the stream has been idle for
///   `graceIdle` (an orphan writer is holding the pipe open, silently), or
///   the post-exit hard cap has passed (an orphan spewing forever), stop;
///   otherwise sleep briefly and poll again.
final class PipeStreamReader: @unchecked Sendable {
    private let fd: Int32
    private let collector: any PipeByteSink
    private let lock = NSLock()
    private var processExitedAt: Date?
    private var task: Task<Void, Never>?

    static let graceIdle: TimeInterval = 0.1
    static let graceHardCap: TimeInterval = 5.0

    init(fd: Int32, collector: any PipeByteSink) {
        self.fd = fd
        self.collector = collector
    }

    func start() {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        task = Task.detached(priority: .utility) { [self] in await loop() }
    }

    /// The child (or its killed tree) is gone — begin the grace countdown.
    func noteProcessExited() {
        lock.lock(); defer { lock.unlock() }
        if processExitedAt == nil { processExitedAt = Date() }
    }

    /// Wait for the reader to drain to EOF or give up per the grace rules.
    /// Bounded: the loop self-terminates within graceHardCap of exit.
    func finish() async {
        noteProcessExited()
        await task?.value
    }

    private func exitedAt() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return processExitedAt
    }

    private func loop() async {
        var buf = [UInt8](repeating: 0, count: 65_536)
        var lastByteAt = Date()
        while true {
            // poll(2) before read: never trust the fd to actually be
            // nonblocking (Linux CI showed a blocking read here waiting out
            // a 15s orphan despite the O_NONBLOCK fcntl). A POLLIN'd pipe
            // read returns immediately with whatever is available; POLLHUP
            // with no data reads as EOF.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, 0)
            if rc < 0 {
                if errno == EINTR { continue }
                return
            }
            let readable = rc > 0
                && (Int32(pfd.revents) & (Int32(POLLIN) | Int32(POLLHUP) | Int32(POLLERR))) != 0
            if readable {
                let n = buf.withUnsafeMutableBytes { raw -> Int in
                    read(fd, raw.baseAddress, raw.count)
                }
                if n > 0 {
                    lastByteAt = Date()
                    collector.ingest(Data(bytes: buf, count: n))
                    continue
                }
                if n == 0 {
                    collector.ingest(Data())  // EOF marker
                    return
                }
                let err = errno
                if err == EINTR || err == EAGAIN || err == EWOULDBLOCK {
                    // Spurious readiness — fall through to the wait path.
                } else {
                    return  // EBADF etc. — pipe torn down
                }
            }
            if let exited = exitedAt() {
                let now = Date()
                if now.timeIntervalSince(exited) >= Self.graceHardCap { return }
                if now.timeIntervalSince(lastByteAt) >= Self.graceIdle,
                   now.timeIntervalSince(exited) >= Self.graceIdle { return }
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}

// MARK: - Foreground stream collector

/// Owns one stream (stdout or stderr) of a foreground command: drains pipe
/// chunks as they arrive, decodes and redacts them statefully, keeps a
/// bounded in-memory tail for the model, and spills the complete redacted
/// stream to a mode-600 file once it exceeds the inline limits. Raw
/// (unredacted) output never touches disk.
///
/// Thread model: `ingest` runs on the pipe's readabilityHandler thread;
/// `eofReached`/`lastDataAt` are read from the async poll loop; `finalize`
/// runs after handlers are detached. A single lock guards all state.
final class ForegroundStreamCollector: PipeByteSink, @unchecked Sendable {
    struct FinalOutput {
        /// Text for the tool result: full output when small, tail preview +
        /// spill hint when large.
        let text: String
        let truncated: Bool
        let spillPath: String?
        let totalBytes: Int
        let totalLines: Int
    }

    private let lock = NSLock()
    private var decoder = IncrementalUTF8Decoder()
    private let redactor: StreamingRedactor
    private let streamLabel: String

    /// Complete redacted output while below the spill threshold.
    private var buffered = ""
    /// Rolling tail kept for the preview after spilling starts.
    private var tail = ""
    private var totalBytes = 0
    private var totalLines = 0
    private var spillHandle: FileHandle?
    private var spillPath: String?
    private var spillFailed = false

    private var _eofReached = false
    private var _lastDataAt = Date()
    private var finalized = false

    /// Keep twice the inline cap so the preview can always fill it.
    private static let tailCapBytes = TruncationService.maxBytes * 2
    /// Byte budget kept by the amortized trim (≥ `tailCapBytes` characters
    /// unless they average over 4 bytes), and the size that triggers it.
    private static let tailKeepBytes = tailCapBytes * 4
    private static let tailTrimTriggerBytes = tailCapBytes * 6

    init(streamLabel: String, secrets: [String: String]) {
        self.streamLabel = streamLabel
        self.redactor = StreamingRedactor(environment: secrets)
    }

    var eofReached: Bool {
        lock.lock(); defer { lock.unlock() }
        return _eofReached
    }

    /// Current spill path, if spilling has started. Readable mid-stream —
    /// background processes surface it while still running.
    var spillPathSnapshot: String? {
        lock.lock(); defer { lock.unlock() }
        return spillPath
    }

    var lastDataAt: Date {
        lock.lock(); defer { lock.unlock() }
        return _lastDataAt
    }

    /// Pipe chunk arrived. Empty data means EOF (all writers closed).
    func ingest(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        // A callback can race the tail end of finalize(); the result is
        // already computed by then, and appending would write to a closed
        // spill handle and tear down the just-returned spill file.
        guard !finalized else { return }
        if data.isEmpty {
            _eofReached = true
            return
        }
        _lastDataAt = Date()
        let safe = redactor.process(decoder.decode(data))
        appendLocked(safe)
    }

    /// Drain decoder + redactor carries and close the spill file. Call once,
    /// after the readability handlers are detached.
    func finalize() -> FinalOutput {
        lock.lock(); defer { lock.unlock() }
        finalized = true
        var remainder = redactor.process(decoder.flush())
        remainder += redactor.flush()
        appendLocked(remainder)

        if let handle = spillHandle {
            try? handle.close()
            spillHandle = nil
        }

        if spillPath == nil && !spillFailed {
            // Everything fit in memory — apply the normal inline policy
            // (can still truncate on the line limit, which never triggers
            // a byte-threshold spill).
            let (text, truncated, path) = TruncationService.truncate(buffered, direction: .tail)
            return FinalOutput(text: text, truncated: truncated, spillPath: path,
                               totalBytes: totalBytes, totalLines: totalLines)
        }

        if tail.utf8.count > Self.tailCapBytes {
            tail = String(tail.suffix(Self.tailCapBytes))
        }
        let preview = TruncationService.streamedTailPreview(
            tail: tail, totalBytes: totalBytes, totalLines: totalLines, outputPath: spillPath
        )
        return FinalOutput(text: preview, truncated: true, spillPath: spillPath,
                           totalBytes: totalBytes, totalLines: totalLines)
    }

    // MARK: - Locked internals

    private func appendLocked(_ safe: String) {
        guard !safe.isEmpty else { return }
        totalBytes += safe.utf8.count
        for ch in safe where ch == "\n" { totalLines += 1 }

        if spillHandle == nil && !spillFailed {
            buffered += safe
            let overBytes = buffered.utf8.count > TruncationService.maxBytes
            let overLines = totalLines > TruncationService.maxLines
            if overBytes || overLines {
                // Test hook: BRIGLIA_TEST_SPILL_FAULT=write closes the handle
                // right after open so the first write throws — exercises the
                // failure path deterministically (same pattern as
                // BRIGLIA_UPGRADE_FAULT).
                openSpillLocked()
                if let fault = getenv("BRIGLIA_TEST_SPILL_FAULT"), String(cString: fault) == "write",
                   let handle = spillHandle {
                    try? handle.close()
                }
                if let handle = spillHandle {
                    if let data = buffered.data(using: .utf8) {
                        do { try handle.write(contentsOf: data) }
                        catch {
                            // markSpillFailedLocked moves buffered into the
                            // rolling tail — return NOW; falling through
                            // would overwrite tail with the emptied buffer.
                            markSpillFailedLocked()
                            return
                        }
                    }
                    tail = String(buffered.suffix(Self.tailCapBytes))
                    buffered = ""
                }
                // On open failure markSpillFailedLocked has moved buffered
                // into the rolling tail; later chunks take the tail-only path.
            }
            return
        }

        if let handle = spillHandle {
            if let data = safe.data(using: .utf8) {
                do { try handle.write(contentsOf: data) }
                catch { markSpillFailedLocked() }
            }
        }
        tail += safe
        // Amortized trim: keep 4× the cap in bytes and cut only when well
        // past that, so a flood costs O(chunk) per chunk instead of
        // re-walking the whole tail every time. finalize() applies the old
        // character cap before rendering. The preview equals the old one
        // whenever the kept bytes hold at least `tailCapBytes` characters,
        // i.e. unless characters average over 4 UTF-8 bytes (long combining
        // sequences, joined emoji); then the preview may start later.
        if tail.utf8.count > Self.tailTrimTriggerBytes {
            tail = BoundedText.suffix(tail, maxBytes: Self.tailKeepBytes)
        }
    }

    private func openSpillLocked() {
        let dir = TruncationService.truncationDir
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            markSpillFailedLocked()
            return
        }
        // "tool_" prefix rides the existing 7-day cleanup sweep. 0600: spill
        // files hold command output that, while redacted, is still private.
        let name = "tool_stream_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))_\(streamLabel).txt"
        let path = dir + name
        guard FileManager.default.createFile(
            atPath: path, contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let handle = FileHandle(forWritingAtPath: path) else {
            markSpillFailedLocked()
            return
        }
        spillHandle = handle
        spillPath = path
    }

    private func markSpillFailedLocked() {
        spillFailed = true
        if let handle = spillHandle {
            try? handle.close()
            spillHandle = nil
        }
        if let path = spillPath {
            try? FileManager.default.removeItem(atPath: path)
            spillPath = nil
        }
        // Degrade to a bounded in-memory tail — same information the
        // pre-streaming implementation kept on its best day.
        if !buffered.isEmpty {
            tail = String((buffered + tail).suffix(Self.tailCapBytes))
            buffered = ""
        }
    }
}

// MARK: - Watch line accumulation

/// Splits a stream into complete lines for bash watches with bounded memory
/// and O(chunk) work, REDACTING BEFORE ANY CUT (Codex R1, 2026-10-08).
///
/// Raw text of the current line passes through a carry-window
/// `StreamingRedactor` (flushed at every newline, so each line is redacted
/// exactly as a whole-line `SecretRedactor.redact` would), and only the
/// redacted output enters the bounded head. Once the head reaches `capBytes`
/// the rest of the line is dropped and `truncated` is set, so the marker is
/// appended whenever anything was cut, however much redaction shortened the
/// kept part. A cut never lands inside a redaction placeholder: placeholders
/// are produced whole within one redactor emission, and the cut backs off to
/// the start of a placeholder it would otherwise split.
///
/// Newlines are found by a byte scan of the NEW chunk only (CR-LF lines
/// split and lose the CR). An unterminated tail at EOF is not a line and is
/// never delivered — same as before.
struct WatchLineAccumulator {
    static let truncationMarker = " …[line truncated for watch matching]"
    private static let placeholderStart = "[REDACTED:"

    let capBytes: Int
    /// nil when the input is already redacted (watch replay from the rolling buffer).
    private let redactor: StreamingRedactor?
    private var head = ""
    private(set) var truncated = false

    init(capBytes: Int, redactionEnvironment: [String: String]?) {
        self.capBytes = capBytes
        self.redactor = redactionEnvironment.map { StreamingRedactor(environment: $0) }
    }

    /// Redacted bytes held for the current unterminated line (test seam).
    var pendingBytes: Int { head.utf8.count }

    /// Feed raw (or, without a redactor, already-redacted) text; returns the
    /// lines completed by it, redacted and capped.
    mutating func feed(_ chunk: String) -> [String] {
        var out: [String] = []
        var rest = Substring(chunk)
        while let nl = rest.utf8.firstIndex(of: 0x0A) {
            ingest(rest[rest.startIndex..<nl])
            if let redactor {
                let tail = redactor.flush()
                if !truncated { append(Substring(tail)) }
            }
            var line = head
            if !truncated, line.utf8.last == 0x0D { line.removeLast() }
            if truncated { line += Self.truncationMarker }
            out.append(line)
            head = ""
            truncated = false
            rest = rest[rest.utf8.index(after: nl)...]
        }
        ingest(rest)
        return out
    }

    private mutating func ingest(_ piece: Substring) {
        guard !piece.isEmpty else { return }
        if let redactor {
            // After truncation the rest of the line is dropped; the carry is
            // discarded by the flush at the next newline.
            guard !truncated else { return }
            append(Substring(redactor.process(String(piece))))
        } else {
            guard !truncated else { return }
            append(piece)
        }
    }

    private mutating func append(_ text: Substring) {
        guard !text.isEmpty, !truncated else { return }
        let room = capBytes - head.utf8.count
        if text.utf8.count <= room {
            head.append(contentsOf: text)
            return
        }
        truncated = true
        guard room > 0 else { return }
        var kept = BoundedText.prefix(text, maxBytes: room)
        // Never split a placeholder: if the kept part ends inside one, cut
        // before it. (An unclosed "[REDACTED:" whose "]" lies past the cut.)
        if let r = kept.range(of: Self.placeholderStart, options: .backwards),
           !kept[r.upperBound...].contains("]") {
            kept = String(kept[..<r.lowerBound])
        }
        head.append(kept)
    }
}
