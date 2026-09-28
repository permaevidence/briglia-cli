import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Persistent per-stage diagnostics for tool execution (write_file stall
/// investigation, 2026-09-28).
///
/// Every tool call, and the internal stages of the file tools, Git
/// checkpointing and MCP start-up, emit ENTER/EXIT records to an
/// append-only JSON-lines file, by default
/// `~/.local/share/briglia/logs/stage-markers.log` (0600, rotated at
/// `maxBytes` to `stage-markers.log.1`). The records name the call id, the
/// tool, the stage, monotonic and wall-clock time, the elapsed time and the
/// outcome. They never carry file contents, argument values or secrets;
/// `detail` is limited to fixed labels, counts and path basenames.
///
/// Latency contract. The tool path only appends a small struct to an
/// in-memory queue under a private lock (no disk I/O, no formatting, no
/// actor hop). A dedicated writer thread formats each record and issues ONE
/// `write(2)` per record, without fsync: a record that has been written
/// survives a hang or SIGKILL of the process (it is in the kernel's page
/// cache); only a record still queued at the instant of a SIGKILL — normally
/// microseconds — can be lost. If the log's volume is slow or hangs, only the
/// writer thread waits; the queue is bounded (`maxQueued`), and records that
/// overflow it are counted and reported in the next written record.
///
/// Stall REPORTER, not a killer. A separate watchdog thread writes ONE
/// `stall_suspected` record (log file and stderr) for a stage open longer
/// than `BRIGLIA_STALL_REPORT_SECONDS` (default 120 s), with every open
/// stage and, on Linux, the state/wait channel of each thread. It never
/// cancels, fails, retries or otherwise touches the stage: the operation may
/// still complete, and reporting it failed could cause overlapping writes.
///
/// Environment:
/// - `BRIGLIA_STAGE_MARKERS=0` disables everything (no thread is started).
/// - `BRIGLIA_STAGE_MARKERS_PATH=/abs/file` writes elsewhere, e.g. to
///   container-local storage when the data directory is a slow mount.
/// - `BRIGLIA_STAGE_MARKERS_STDERR=1` mirrors every record to stderr.
/// - `BRIGLIA_STALL_REPORT_SECONDS=<n>` sets the reporter threshold.
enum StageMarkers {

    // MARK: - Context

    /// The tool call a stage belongs to. Carried as a task-local so nested
    /// helpers (FilesystemTools, GitCheckpointTracker, LSP, ledgers) inherit
    /// it without signature changes.
    struct CallContext: Sendable {
        let callId: String
        let tool: String
        let depth: Int
    }

    @TaskLocal static var call: CallContext?
    /// The main loop's round number, when known.
    @TaskLocal static var round: Int?

    enum Outcome: String, Sendable {
        case ok, error, cancelled
    }

    struct Token: Sendable {
        let id: UInt64
        let startNanos: UInt64
        let stage: String
        /// 0 when markers are disabled: exit() is then a no-op.
        var isLive: Bool { id != 0 }
    }

    // MARK: - Configuration

    static let enabled: Bool = ProcessInfo.processInfo.environment["BRIGLIA_STAGE_MARKERS"] != "0"
    static let mirrorToStderr: Bool = ProcessInfo.processInfo.environment["BRIGLIA_STAGE_MARKERS_STDERR"] == "1"
    static let stallThresholdSeconds: Double = {
        if let raw = ProcessInfo.processInfo.environment["BRIGLIA_STALL_REPORT_SECONDS"],
           let value = Double(raw), value > 0 { return value }
        return 120
    }()
    static let maxBytes: Int = {
        if let raw = ProcessInfo.processInfo.environment["BRIGLIA_STAGE_MARKERS_MAX_BYTES"],
           let value = Int(raw), value >= 4096 { return value }
        return 8 * 1024 * 1024
    }()
    static let maxQueued = 10_000

    /// Where the records go. Resolved once, on first use.
    static var logURL: URL {
        if let override = ProcessInfo.processInfo.environment["BRIGLIA_STAGE_MARKERS_PATH"],
           override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        return StoragePaths.dataRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("stage-markers.log")
    }

    // MARK: - API (tool path: queue append only)

    /// Opens a stage. Returns a token to pass to `exit`.
    static func enter(_ stage: String, detail: String? = nil,
                      call: CallContext? = StageMarkers.call) -> Token {
        guard enabled else { return Token(id: 0, startNanos: 0, stage: stage) }
        let now = monotonicNanos()
        let id = Engine.shared.open(stage: stage, call: call, round: round, startNanos: now, detail: detail)
        return Token(id: id, startNanos: now, stage: stage)
    }

    /// Closes a stage opened by `enter`.
    static func exit(_ token: Token, _ outcome: Outcome, detail: String? = nil) {
        guard token.isLive else { return }
        Engine.shared.close(token: token, outcome: outcome, endNanos: monotonicNanos(), detail: detail)
    }

    /// A point-in-time record (no pairing).
    static func event(_ stage: String, detail: String? = nil, call: CallContext? = StageMarkers.call) {
        guard enabled else { return }
        Engine.shared.point(stage: stage, call: call, round: round, detail: detail)
    }

    /// Runs synchronous `body` inside a stage; the outcome is `error` when it
    /// throws (`cancelled` for CancellationError), else `ok`. There is
    /// deliberately no async variant: a nonisolated async wrapper would add
    /// an actor hop around the body, and markers must not change scheduling.
    /// Async stages use `enter`/`exit` inline.
    @discardableResult
    static func measure<T>(_ stage: String, detail: String? = nil, _ body: () throws -> T) rethrows -> T {
        let token = enter(stage, detail: detail)
        do {
            let value = try body()
            exit(token, .ok)
            return value
        } catch {
            exit(token, error is CancellationError ? .cancelled : .error)
            throw error
        }
    }

    /// Blocks until every record queued so far has been written (or the
    /// timeout passes). For tests and the hidden reader command only.
    @discardableResult
    static func flush(timeout: TimeInterval = 5) -> Bool {
        guard enabled else { return true }
        return Engine.shared.flush(timeout: timeout)
    }

    /// Currently open stages (for tests and the doctor line).
    static func openStages() -> [(stage: String, callId: String?, tool: String?, elapsedMs: Int)] {
        guard enabled else { return [] }
        return Engine.shared.openSnapshot(now: monotonicNanos()).map {
            ($0.stage, $0.callId, $0.tool, Int(($0.elapsedNanos) / 1_000_000))
        }
    }

    /// A path basename, safe to log.
    static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func monotonicNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    // MARK: - Engine

    /// One queued record. Formatting happens on the writer thread.
    struct Record {
        enum Kind: String { case enter, exit, event, stall = "stall_suspected", note }
        let seq: UInt64
        let kind: Kind
        let stage: String
        let token: UInt64
        let callId: String?
        let tool: String?
        let depth: Int?
        let round: Int?
        let monoNanos: UInt64
        let wall: Double
        let elapsedNanos: UInt64?
        let outcome: String?
        let detail: String?
        /// Pre-rendered extra JSON members (stall report), without braces.
        let extraJSON: String?
    }

    struct OpenStage {
        let token: UInt64
        let stage: String
        let callId: String?
        let tool: String?
        let startNanos: UInt64
        var reported: Bool
        var elapsedNanos: UInt64 = 0
    }

    final class Engine: @unchecked Sendable {
        static let shared = Engine()

        private let lock = NSCondition()
        private var queue: [Record] = []
        private var dropped = 0
        private var nextToken: UInt64 = 1
        private var nextSeq: UInt64 = 1
        private var written: UInt64 = 0   // highest seq written (or skipped)
        private var open: [UInt64: OpenStage] = [:]
        private var lastRecord: (seq: UInt64, kind: String, stage: String)?
        private var started = false

        // Writer-thread-only state.
        private var handle: FileHandle?
        private var usingStderrFallback = false
        private var openFailureReported = false

        private func startIfNeeded() {
            // Caller holds `lock`.
            guard !started else { return }
            started = true
            let writer = Thread { [unowned self] in self.writerLoop() }
            writer.name = "briglia.stage-markers.writer"
            writer.stackSize = 256 * 1024
            writer.start()
            let watchdog = Thread { [unowned self] in self.watchdogLoop() }
            watchdog.name = "briglia.stage-markers.watchdog"
            watchdog.stackSize = 256 * 1024
            watchdog.start()
        }

        private func enqueue(_ make: (UInt64) -> Record) {
            // Caller holds `lock`.
            startIfNeeded()
            let seq = nextSeq
            nextSeq += 1
            let record = make(seq)
            lastRecord = (seq, record.kind.rawValue, record.stage)
            if queue.count >= StageMarkers.maxQueued {
                dropped += 1
                written = max(written, seq)
            } else {
                queue.append(record)
            }
            lock.signal()
        }

        func open(stage: String, call: CallContext?, round: Int?, startNanos: UInt64, detail: String?) -> UInt64 {
            let wall = Date().timeIntervalSince1970
            lock.lock()
            let token = nextToken
            nextToken += 1
            open[token] = OpenStage(token: token, stage: stage, callId: call?.callId, tool: call?.tool,
                                    startNanos: startNanos, reported: false)
            enqueue { seq in
                Record(seq: seq, kind: .enter, stage: stage, token: token, callId: call?.callId, tool: call?.tool,
                       depth: call?.depth, round: round, monoNanos: startNanos, wall: wall,
                       elapsedNanos: nil, outcome: nil, detail: detail, extraJSON: nil)
            }
            lock.unlock()
            return token
        }

        func close(token: Token, outcome: Outcome, endNanos: UInt64, detail: String?) {
            let wall = Date().timeIntervalSince1970
            lock.lock()
            let entry = open.removeValue(forKey: token.id)
            let elapsed = endNanos >= token.startNanos ? endNanos - token.startNanos : 0
            enqueue { seq in
                Record(seq: seq, kind: .exit, stage: token.stage, token: token.id, callId: entry?.callId,
                       tool: entry?.tool, depth: nil, round: nil, monoNanos: endNanos, wall: wall,
                       elapsedNanos: elapsed, outcome: outcome.rawValue, detail: detail, extraJSON: nil)
            }
            lock.unlock()
        }

        func point(stage: String, call: CallContext?, round: Int?, detail: String?) {
            let wall = Date().timeIntervalSince1970
            let mono = StageMarkers.monotonicNanos()
            lock.lock()
            enqueue { seq in
                Record(seq: seq, kind: .event, stage: stage, token: 0, callId: call?.callId, tool: call?.tool,
                       depth: call?.depth, round: round, monoNanos: mono, wall: wall,
                       elapsedNanos: nil, outcome: nil, detail: detail, extraJSON: nil)
            }
            lock.unlock()
        }

        func openSnapshot(now: UInt64) -> [OpenStage] {
            lock.lock()
            defer { lock.unlock() }
            return open.values.sorted { $0.startNanos < $1.startNanos }.map {
                var copy = $0
                copy.elapsedNanos = now >= $0.startNanos ? now - $0.startNanos : 0
                return copy
            }
        }

        func flush(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            lock.lock()
            defer { lock.unlock() }
            let target = nextSeq - 1
            while written < target {
                if !lock.wait(until: deadline) { return written >= target }
            }
            return true
        }

        // MARK: Writer thread

        private func writerLoop() {
            while true {
                lock.lock()
                while queue.isEmpty { lock.wait() }
                let batch = queue
                queue.removeAll(keepingCapacity: true)
                let droppedNow = dropped
                dropped = 0
                lock.unlock()

                var droppedNote = droppedNow
                for record in batch {
                    let line = Self.render(record, dropped: droppedNote)
                    droppedNote = 0
                    writeLine(line)
                    if StageMarkers.mirrorToStderr { Self.writeStderr(line) }
                    lock.lock()
                    written = max(written, record.seq)
                    lock.broadcast()
                    lock.unlock()
                }
            }
        }

        private func writeLine(_ line: String) {
            if handle == nil || (!usingStderrFallback && currentFileWasRemoved()) {
                reopen()
            }
            guard let handle else { return }
            let bytes = Array(line.utf8)
            let fd = handle.fileDescriptor
            // ONE write per record; O_APPEND keeps concurrent writers
            // (other Briglia processes) line-atomic for small records.
            _ = bytes.withUnsafeBytes { raw in
                Glibc_write(fd, raw.baseAddress, raw.count)
            }
            rotateIfNeeded(fd: fd)
        }

        private func currentFileWasRemoved() -> Bool {
            // /deleteuserdata removes logs/: a descriptor on an unlinked
            // file would swallow every later record.
            guard let handle else { return true }
            var st = stat()
            guard fstat(handle.fileDescriptor, &st) == 0 else { return true }
            return st.st_nlink == 0
        }

        private func reopen() {
            if !usingStderrFallback { try? handle?.close() }
            handle = nil
            usingStderrFallback = false
            let url = StageMarkers.logURL
            do {
                try PrivateStorage.ensureDirectory(url.deletingLastPathComponent())
                handle = try PrivateStorage.openForAppend(url)
            } catch {
                if !openFailureReported {
                    openFailureReported = true
                    Self.writeStderr("[StageMarkers] cannot open \(url.path): \(error.localizedDescription); markers go to stderr only\n")
                }
            }
            if handle == nil, !StageMarkers.mirrorToStderr {
                // Keep diagnostics alive somewhere (never closed by us).
                handle = FileHandle.standardError
                usingStderrFallback = true
            }
        }

        private func rotateIfNeeded(fd: Int32) {
            guard !usingStderrFallback else { return }
            var st = stat()
            guard fstat(fd, &st) == 0, Int(st.st_size) >= StageMarkers.maxBytes else { return }
            let url = StageMarkers.logURL
            let rotated = url.path + ".1"
            _ = unlink(rotated)
            _ = rename(url.path, rotated)
            reopen()
        }

        static func writeStderr(_ line: String) {
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBytes { raw in
                Glibc_write(STDERR_FILENO, raw.baseAddress, raw.count)
            }
        }

        // MARK: Watchdog thread (reporter only)

        private func watchdogLoop() {
            let threshold = StageMarkers.stallThresholdSeconds
            let interval = max(0.1, min(5, threshold / 4))
            let thresholdNanos = UInt64(threshold * 1_000_000_000)
            while true {
                Thread.sleep(forTimeInterval: interval)
                let now = StageMarkers.monotonicNanos()
                lock.lock()
                var stalled: [OpenStage] = []
                for (token, var stage) in open where !stage.reported {
                    if now >= stage.startNanos && now - stage.startNanos >= thresholdNanos {
                        stage.reported = true
                        open[token] = stage
                        stage.elapsedNanos = now - stage.startNanos
                        stalled.append(stage)
                    }
                }
                guard !stalled.isEmpty else { lock.unlock(); continue }
                let openNow = open.values.sorted { $0.startNanos < $1.startNanos }.prefix(50).map { entry -> String in
                    let ms = now >= entry.startNanos ? (now - entry.startNanos) / 1_000_000 : 0
                    return "{\"stage\":\(Self.q(entry.stage)),\"call\":\(Self.q(entry.callId)),\"tool\":\(Self.q(entry.tool)),\"open_ms\":\(ms)}"
                }
                let last = lastRecord
                lock.unlock()

                let threads = Self.threadStates()
                for stage in stalled.sorted(by: { $0.startNanos < $1.startNanos }) {
                    var extra = "\"open_stages\":[\(openNow.joined(separator: ","))]"
                    if let last {
                        extra += ",\"last_marker\":{\"seq\":\(last.seq),\"ev\":\(Self.q(last.kind)),\"stage\":\(Self.q(last.stage))}"
                    }
                    extra += ",\"threshold_s\":\(threshold)"
                    extra += ",\"note\":\"reporter only: the stage was NOT cancelled, failed or retried\""
                    if let threads { extra += ",\"threads\":[\(threads.joined(separator: ","))]" }
                    let wall = Date().timeIntervalSince1970
                    let elapsed = stage.elapsedNanos
                    lock.lock()
                    enqueue { seq in
                        Record(seq: seq, kind: .stall, stage: stage.stage, token: stage.token, callId: stage.callId,
                               tool: stage.tool, depth: nil, round: nil, monoNanos: now, wall: wall,
                               elapsedNanos: elapsed, outcome: nil, detail: nil, extraJSON: extra)
                    }
                    lock.unlock()
                    // Also straight to stderr from this thread, so a report
                    // exists even if the log volume itself is what hangs.
                    Self.writeStderr("[StageMarkers] STALL SUSPECTED: stage \(stage.stage) open \(elapsed / 1_000_000) ms (call \(stage.callId ?? "-"), tool \(stage.tool ?? "-")); see \(StageMarkers.logURL.path)\n")
                }
            }
        }

        /// Linux: comm, state, wait channel and syscall number of each
        /// thread of this process. nil elsewhere.
        static func threadStates() -> [String]? {
            #if os(Linux)
            let fm = FileManager.default
            guard let tids = try? fm.contentsOfDirectory(atPath: "/proc/self/task") else { return nil }
            var out: [String] = []
            for tid in tids.sorted().prefix(256) {
                let base = "/proc/self/task/\(tid)"
                let comm = (try? String(contentsOfFile: base + "/comm", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                let wchan = (try? String(contentsOfFile: base + "/wchan", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                var state = "?"
                if let stat = try? String(contentsOfFile: base + "/stat", encoding: .utf8),
                   let close = stat.range(of: ") ", options: .backwards) {
                    state = String(stat[close.upperBound...].prefix(1))
                }
                let syscall = (try? String(contentsOfFile: base + "/syscall", encoding: .utf8))?
                    .split(separator: " ").first.map(String.init) ?? "?"
                out.append("{\"tid\":\(q(tid)),\"comm\":\(q(comm)),\"state\":\(q(state)),\"wchan\":\(q(wchan)),\"syscall\":\(q(syscall))}")
            }
            return out
            #else
            return nil
            #endif
        }

        // MARK: Rendering

        private static let isoFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        static func render(_ r: Record, dropped: Int) -> String {
            var s = "{\"v\":1,\"seq\":\(r.seq),\"t\":\(q(isoFormatter.string(from: Date(timeIntervalSince1970: r.wall))))"
            s += ",\"mono_ms\":\(String(format: "%.3f", Double(r.monoNanos) / 1_000_000))"
            s += ",\"pid\":\(getpid()),\"ev\":\(q(r.kind.rawValue)),\"stage\":\(q(r.stage))"
            if r.token != 0 { s += ",\"id\":\(r.token)" }
            if let callId = r.callId { s += ",\"call\":\(q(callId))" }
            if let tool = r.tool { s += ",\"tool\":\(q(tool))" }
            if let depth = r.depth { s += ",\"depth\":\(depth)" }
            if let round = r.round { s += ",\"round\":\(round)" }
            if let elapsed = r.elapsedNanos { s += ",\"elapsed_ms\":\(String(format: "%.3f", Double(elapsed) / 1_000_000))" }
            if let outcome = r.outcome { s += ",\"outcome\":\(q(outcome))" }
            if let detail = r.detail { s += ",\"detail\":\(q(String(detail.prefix(200))))" }
            if dropped > 0 { s += ",\"dropped_before\":\(dropped)" }
            if let extra = r.extraJSON { s += "," + extra }
            return s + "}\n"
        }

        static func q(_ value: String?) -> String {
            guard let value else { return "null" }
            var out = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if scalar.value < 0x20 {
                        out += String(format: "\\u%04x", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out + "\""
        }
    }
}

/// `write(2)` under a name that does not collide with FileHandle.write.
@inline(__always)
private func Glibc_write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.write(fd, buffer, count)
    #else
    return Darwin.write(fd, buffer, count)
    #endif
}
