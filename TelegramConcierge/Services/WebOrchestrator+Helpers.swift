import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Persistent Web Pipeline Log

/// Appends web-pipeline diagnostics to ~/.local/share/briglia/logs/
/// web-pipeline.log — stdout prints vanish for Finder-launched installs, so
/// this is the only forensic trail in production. Rotates daily: the first
/// write of a new day moves the file to web-pipeline.previous.log, and that
/// previous file is dropped once it is older than 7 days. A 10 MB in-day cap
/// guards pathological volume. Owner-only files in an owner-only directory
/// (every search query and fetched URL lands here). Local-only; never leaves
/// the Mac.
final class WebPipelineLog: @unchecked Sendable {
    static let shared = WebPipelineLog()

    private let queue = DispatchQueue(label: "com.permaevidence.briglia.web-pipeline-log")
    private let maxBytes = 10_000_000
    /// `web-pipeline.previous.log` older than this is removed at write time.
    static let previousLogRetention: TimeInterval = 7 * 24 * 60 * 60

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var logsDirectory: URL {
        StoragePaths.dataRoot
            .appendingPathComponent("logs", isDirectory: true)
    }

    /// Absolute path of the current log file, for error messages that point
    /// the agent (or the user) at the request-level diagnostics.
    var logFilePath: String {
        logsDirectory.appendingPathComponent("web-pipeline.log").path
    }

    func append(_ message: String) {
        let line = "\(Self.stampFormatter.string(from: Date())) \(message)\n"
        queue.async { self.write(line) }
    }

    /// Selftest seam: blocks until every line appended so far is on disk.
    func flushForTesting() {
        queue.sync {}
    }

    private func write(_ line: String) {
        let fm = FileManager.default
        let dir = logsDirectory
        let current = dir.appendingPathComponent("web-pipeline.log")
        let previous = dir.appendingPathComponent("web-pipeline.previous.log")
        try? PrivateStorage.ensureDirectory(dir)

        // Retention (plan H2.7): the rotated file is forensic material for a
        // few days, not forever.
        if let prevAttrs = try? fm.attributesOfItem(atPath: previous.path),
           let prevModified = prevAttrs[.modificationDate] as? Date,
           Date().timeIntervalSince(prevModified) > Self.previousLogRetention {
            try? fm.removeItem(at: previous)
        }

        if let attrs = try? fm.attributesOfItem(atPath: current.path) {
            let modified = attrs[.modificationDate] as? Date
            let size = attrs[.size] as? Int ?? 0
            let isStale = modified.map { !Calendar.current.isDate($0, inSameDayAs: Date()) } ?? false
            if isStale || size > maxBytes {
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: current, to: previous)
            }
        }

        // Created 0600 (or tightened) and appended through its own
        // descriptor; a symlink at the log path is refused.
        guard let handle = try? PrivateStorage.openForAppend(current) else { return }
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

/// Print to the console (visible from Xcode/terminal) AND persist to the
/// rotated log file (visible in production).
func webLog(_ message: String) {
    print(message)
    WebPipelineLog.shared.append(message)
}

/// Tool-facing text for a failed web pipeline operation: names the cause and
/// points at the on-disk log holding the request-level detail (per-stage
/// responses, PARSE_FAILED previews, TRUNCATED_GENERATION and retry lines),
/// so the agent can read it and self-diagnose instead of guessing.
/// Cancellation gets no pointer — the user stopped the turn; there is
/// nothing to diagnose.
func webPipelineFailureText(_ prefix: String, error: Error) -> String {
    let base = "\(prefix): \(error.localizedDescription)"
    if error is CancellationError { return base }
    if let urlError = error as? URLError, urlError.code == .cancelled { return base }
    return "\(base) — diagnostic log: \(WebPipelineLog.shared.logFilePath)"
}

// MARK: - HTTP Helpers

/// Send a request, retrying transient failures (429/5xx/timeouts/connection
/// drops) with exponential backoff before giving up. Cancellation is never
/// retried and always surfaces as CancellationError so /stop keeps working
/// mid-request.
func httpDataWithRetry(request: URLRequest, label: String, maxAttempts: Int = 4, retryTimeouts: Bool = true, usageRecord: ResponsesUsageStore.Record? = nil,
                       fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
                       deadline: ExtractorDeadline? = nil) async throws -> Data {
    var attempt = 1
    var lastError: Error?

    while attempt <= maxAttempts {
        try Task.checkCancellation()
        let usage = ResponsesUsageStore()
        var ticket: ResponsesUsageStore.Ticket?
        if var record = usageRecord {
            record.attempt = attempt
            do { ticket = try usage.begin(record) } catch { ResponsesUsageStore.warn() }
        }
        let started = ProcessInfo.processInfo.systemUptime
        var counts = ResponsesUsageCounts()
        var status: Int?
        var completed = false
        do {
            defer {
                if let ticket {
                    do { try usage.finish(ticket, outcome: completed ? .completed : (Task.isCancelled ? .cancelled : .failed),
                        status: status, durationMs: Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                        counts: counts, receivedRoutingState: false) }
                    catch { ResponsesUsageStore.warn() }
                }
            }
            let (data, response): (Data, URLResponse)
            if let fetch { (data, response) = try await fetch(request) } else { (data, response) = try await URLSession.shared.data(for: request) }
            status = (response as? HTTPURLResponse)?.statusCode
            if usageRecord != nil { counts = ResponsesUsageCounts.parse(data) }
            try HTTPError.throwIfBad(response, data: data)
            // Truncation forensics: URLSession should never deliver fewer
            // bytes than the server announced as a success — if this ever
            // fires, the truncation is client/transport-side; if it never
            // does, short responses were short as sent. (-1 = no
            // Content-Length header, e.g. chunked encoding — unverifiable.)
            let expected = response.expectedContentLength
            if expected >= 0 && expected != Int64(data.count) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                webLog("[WebPipeline] SHORT_BODY \(label) status=\(status) content_length=\(expected) received_bytes=\(data.count)")
            }
            if attempt > 1 {
                webLog("[WebPipeline] \(label) succeeded on attempt \(attempt)")
            }
            completed = true
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            lastError = error
            // retryTimeouts: false marks calls where the response is a single
            // long non-streaming generation — hitting timeoutInterval there
            // means the model legitimately ran past the ceiling, and a retry
            // would re-bill the same slow generation just to time out again.
            if !retryTimeouts, let urlError = error as? URLError, urlError.code == .timedOut {
                webLog("[WebPipeline] \(label) timed out after \(Int(request.timeoutInterval))s — not retried (generation-length timeout)")
                throw error
            }
            guard attempt < maxAttempts, isRetryableHTTPFailure(error) else { throw error }
            let delay = httpRetryDelay(forAttempt: attempt, retryAfter: (error as? HTTPError)?.retryAfter)
            // A total deadline covers the backoff too: when the retry could
            // only start at or past it, stop now (no request is in flight).
            if let deadline, delay >= deadline.remaining {
                webLog("[WebPipeline] \(label) failed (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription). Not retrying: the \(String(format: "%.2f", delay))s backoff reaches the total deadline")
                throw deadline.exceeded(requestInFlight: false)
            }
            webLog("[WebPipeline] \(label) failed (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription). Retrying in \(String(format: "%.2f", delay))s")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            attempt += 1
        }
    }

    throw lastError ?? URLError(.unknown)
}

func httpJSONPostWithRetry<T: Encodable>(url: URL, body: T, headers: [String: String], timeout: TimeInterval, label: String, retryTimeouts: Bool = true, usageRecord: ResponsesUsageStore.Record? = nil,
                                         fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
                                         deadline: ExtractorDeadline? = nil) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = timeout
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    request.httpBody = try JSONEncoder().encode(body)
    return try await httpDataWithRetry(request: request, label: label, retryTimeouts: retryTimeouts, usageRecord: usageRecord, fetch: fetch, deadline: deadline)
}

// MARK: - Total wall-clock deadline (extractor stages, every backend)

/// A request that ran past its TOTAL wall-clock deadline. Not a transport
/// failure: httpDataWithRetry never retries it (isRetryableHTTPFailure is
/// false); the caller decides (the extractor retries on another host).
struct ExtractorDeadlineExceeded: LocalizedError {
    let seconds: TimeInterval
    let elapsed: TimeInterval
    /// True when the clock stopped Briglia waiting on a request that was
    /// still open. Only Briglia's wait ends: a non-streaming OpenRouter
    /// request keeps running and billing upstream after the client leaves,
    /// so its cost is UNKNOWN (never zero). False when the deadline was
    /// reached with nothing in flight (before a send, or in a transport
    /// retry's backoff after a completed error response).
    let requestInFlight: Bool
    /// X-Generation-Id of the CURRENT transport attempt only (nil when that
    /// attempt received no such header, or no headers at all).
    let generationId: String?
    /// X-Provider-Name of the current transport attempt only.
    let provider: String?
    /// Generation ids seen on EARLIER transport attempts of this request
    /// (completed error responses), kept apart for the log.
    let earlierGenerationIds: [String]
    /// Spend-tracked sends only: the unknown-amount incident (charge id) the
    /// cut request became, and whether it was saved yet.
    var incidentChargeId: UUID? = nil
    var incidentSaved = true
    var errorDescription: String? {
        "request reached its \(Int(seconds.rounded())) s total deadline after \(String(format: "%.1f", elapsed)) s"
    }
}

/// One logical request's total wall-clock deadline, counted from the first
/// send and shared by its transport retries AND their backoff sleeps.
/// URLRequest.timeoutInterval is an IDLE timeout: OpenRouter answers headers
/// in ~1 s and then sends keepalive whitespace every second until the
/// completion, so a host stuck in a reasoning loop never trips it. This
/// clock ignores bytes entirely. It limits Briglia's wait only; the request
/// body (and its output cap — none) is untouched, and the upstream
/// generation is not stopped by it.
/// Response identity (generation id, host) is tracked PER transport
/// attempt: each send starts with none, a response without the headers
/// leaves them unset, and callbacks of an older attempt are ignored.
final class ExtractorDeadline: @unchecked Sendable {
    let seconds: TimeInterval
    /// Stage name when every actual HTTP send is a paid, spend-tracked
    /// extractor request (a backend billed per request: OpenRouter, the
    /// OpenAI API key); nil = plain deadline only (flat plans).
    let spendStage: String?
    /// Backend name for log lines and refusals ("openrouter", "openai", …).
    let backendLabel: String
    /// OpenRouter's X-Generation-Id / X-Provider-Name are read (and a cut
    /// request's generation id recorded for the later cost lookup) only on
    /// OpenRouter: another backend's headers never feed that lookup.
    let readsGenerationHeaders: Bool
    /// Host named in an incident when the reply named none (e.g. "OpenAI").
    let hostLabel: String?
    private let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var attempt = 0
    private var generationId: String?
    private var provider: String?
    private var earlierGenerationIds: [String] = []
    private var cancelledOpen = false

    init(seconds: TimeInterval, spendStage: String? = nil, backendLabel: String = "openrouter",
         readsGenerationHeaders: Bool = true, hostLabel: String? = nil) {
        self.seconds = seconds; self.spendStage = spendStage; self.backendLabel = backendLabel
        self.readsGenerationHeaders = readsGenerationHeaders; self.hostLabel = hostLabel
    }

    /// True when a cancellation interrupted an OPEN transport attempt (sent,
    /// no reply yet): that request may still be billed upstream.
    var cancelledWhileOpen: Bool { lock.lock(); defer { lock.unlock() }; return cancelledOpen }
    /// X-Generation-Id / X-Provider-Name of the current attempt.
    var currentIdentity: (generationId: String?, provider: String?) {
        lock.lock(); defer { lock.unlock() }; return (generationId, provider)
    }

    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - started }
    var remaining: TimeInterval { seconds - elapsed }

    /// Start a new transport attempt: its identity starts empty.
    func beginAttempt() -> Int {
        lock.lock(); defer { lock.unlock() }
        if let generationId { earlierGenerationIds.append(generationId) }
        attempt += 1
        generationId = nil; provider = nil
        return attempt
    }

    /// Record the response headers of `attempt` (ignored when a later
    /// attempt has started). Absent headers stay absent.
    func observe(_ response: HTTPURLResponse, attempt: Int) {
        lock.lock(); defer { lock.unlock() }
        guard readsGenerationHeaders, attempt == self.attempt else { return }
        generationId = response.value(forHTTPHeaderField: "X-Generation-Id").flatMap { $0.isEmpty ? nil : $0 }
        provider = response.value(forHTTPHeaderField: "X-Provider-Name").flatMap { $0.isEmpty ? nil : $0 }
    }

    func exceeded(requestInFlight: Bool) -> ExtractorDeadlineExceeded {
        lock.lock(); defer { lock.unlock() }
        return ExtractorDeadlineExceeded(seconds: seconds, elapsed: elapsed, requestInFlight: requestInFlight,
                                         generationId: requestInFlight ? generationId : nil,
                                         provider: requestInFlight ? provider : nil,
                                         earlierGenerationIds: earlierGenerationIds + (requestInFlight ? [] : generationId.map { [$0] } ?? []))
    }

    private func markCancelledOpen() { lock.lock(); cancelledOpen = true; lock.unlock() }

    /// Send one HTTP attempt within what is left of the deadline.
    /// With `spendStage` set, EVERY actual send — the first and each
    /// transport retry of httpDataWithRetry — is a paid request: it checks
    /// the spend gate right before sending (a pause opened meanwhile by
    /// another request stops it; work already sent is left alone) and is
    /// written ahead under its own charge id (no durable record → not sent).
    /// A send whose billable outcome is unknown — cut at the deadline,
    /// cancelled while open, or a connection that failed after the request
    /// may have reached the host — becomes an unknown-amount incident BEFORE
    /// the error returns to the retry loop. Only a complete HTTP response, or
    /// a failure that demonstrably happened before anything was sent (DNS,
    /// connect, TLS), ends the record without one.
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let remaining = self.remaining
        guard remaining > 0 else { throw exceeded(requestInFlight: false) }
        var chargeId: UUID? = nil
        let sentAt = Date()
        try Task.checkCancellation()
        if let stage = spendStage { chargeId = try Self.admitPaidSend(stage: stage, backend: backendLabel) }
        let attempt = beginAttempt()
        let transport = DeadlineHTTPTransport(owner: self, attempt: attempt)
        do {
            let result = try await transport.send(request, remaining: remaining)
            if let chargeId { ToolChargeLedger.endInFlight(chargeId: chargeId) }
            return result
        } catch var cut as ExtractorDeadlineExceeded {
            if let chargeId, let stage = spendStage {
                if cut.requestInFlight {
                    cut.incidentSaved = ToolChargeLedger.abandonInFlight(chargeId: chargeId, generationId: cut.generationId, provider: cut.provider ?? hostLabel,
                                                                         stage: stage, reason: "cut at its deadline", startedAt: sentAt)
                    cut.incidentChargeId = chargeId
                } else {
                    ToolChargeLedger.endInFlight(chargeId: chargeId)
                }
            }
            throw cut
        } catch is CancellationError {
            markCancelledOpen()
            if let chargeId, let stage = spendStage {
                let identity = currentIdentity
                ToolChargeLedger.abandonInFlight(chargeId: chargeId, generationId: identity.generationId, provider: identity.provider ?? hostLabel,
                                                 stage: stage, reason: "cancelled while open", startedAt: sentAt)
            }
            throw CancellationError()
        } catch {
            if let chargeId, let stage = spendStage {
                if !transport.receivedResponse && Self.demonstrablyUnsent(error) {
                    ToolChargeLedger.endInFlight(chargeId: chargeId)
                } else {
                    let identity = currentIdentity
                    let saved = ToolChargeLedger.abandonInFlight(chargeId: chargeId, generationId: identity.generationId, provider: identity.provider ?? hostLabel,
                                                                 stage: stage, reason: "connection failed before its reply completed", startedAt: sentAt)
                    webLog("[WebOrchestrator] \(backendLabel) stage=\(stage) CONNECTION_FAILED provider=\(identity.provider ?? "-") gen=\(identity.generationId ?? "-") cost=unknown incident=unknown-amount:\(chargeId.uuidString.lowercased())\(saved ? "" : " UNSAVED(kept, retried)") error=\(error.localizedDescription.prefix(160))")
                    CutRequestCostLookup.logAfterFailure(stage: stage, generationId: identity.generationId, after: "connection_failed")
                }
            }
            throw error
        }
    }

    /// Spend gate + write-ahead for one paid send. Throws (not retryable)
    /// when paid work is paused or the send can't be tracked durably.
    private static func admitPaidSend(stage: String, backend: String) throws -> UUID {
        if let pause = SpendGate.pauseReason() {
            webLog("[WebOrchestrator] \(backend) stage=\(stage) not sent: spend gate paused (\(pause.prefix(160)))")
            throw NSError(domain: "WebOrchestrator", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "\(backend) stage '\(stage)' not sent: \(pause)"
            ])
        }
        let id = UUID()
        do { try ToolChargeLedger.beginInFlight(chargeId: id, stage: stage) } catch {
            webLog("[WebOrchestrator] \(backend) stage=\(stage) not sent: in-flight record could not be saved (\(error.localizedDescription))")
            throw NSError(domain: "WebOrchestrator", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "\(backend) stage '\(stage)' not sent: its spend could not be tracked durably (\(error.localizedDescription))"
            ])
        }
        return id
    }

    /// Failures that happen before any request byte can reach the host
    /// (name resolution, connecting, TLS, an unusable URL) and no response
    /// arrived: nothing was generated, so nothing can be billed.
    static func demonstrablyUnsent(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .notConnectedToInternet,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired,
             .badURL, .unsupportedURL:
            return true
        default:
            return false
        }
    }
}

extension ExtractorDeadline {
    /// Run ONE open request that does not go through `fetch` (the ChatGPT
    /// subscription's streamed Responses transport) within what is left of
    /// the deadline. On expiry the request task is cancelled (the connection
    /// closes) and the call throws ExtractorDeadlineExceeded with
    /// `requestInFlight`; an error or cancellation of the request itself
    /// propagates unchanged. Keepalive bytes cannot extend it: the clock
    /// ignores the stream entirely.
    func race<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let remaining = self.remaining
        guard remaining > 0 else { throw exceeded(requestInFlight: false) }
        _ = beginAttempt()
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, remaining) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            if let value = first { return value }
            throw self.exceeded(requestInFlight: true)
        }
    }
}

/// URLSessionDataDelegate transport (Foundation and FoundationNetworking)
/// with a hard wall-clock cut: on expiry the local task is cancelled (the
/// connection closes; the upstream generation is NOT known to stop) and the
/// call throws ExtractorDeadlineExceeded. Response headers are recorded, for
/// this attempt only, as soon as they arrive so the cut can name the
/// generation (and host, if sent).
/// Outer task cancellation cancels the request and throws CancellationError.
/// Redirects follow the session default, like URLSession.shared.
final class DeadlineHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let owner: ExtractorDeadline
    private let attempt: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchWorkItem?
    private var completed = false
    private var response: URLResponse?
    private var data = Data()

    init(owner: ExtractorDeadline, attempt: Int) { self.owner = owner; self.attempt = attempt; super.init() }

    /// True once response headers arrived: the host received the request.
    var receivedResponse: Bool { lock.lock(); defer { lock.unlock() }; return response != nil }

    func send(_ request: URLRequest, remaining: TimeInterval) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if completed { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                // Idle clock as before (request.timeoutInterval); the resource
                // clock is only a backstop behind the wall-clock timer.
                config.timeoutIntervalForRequest = request.timeoutInterval
                config.timeoutIntervalForResource = remaining + 60
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                let timer = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.finish(.failure(self.owner.exceeded(requestInFlight: true)))
                }
                self.timer = timer
                DispatchQueue.global().asyncAfter(deadline: .now() + remaining, execute: timer)
                task.resume(); lock.unlock()
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let callback = continuation; continuation = nil
        let task = task; self.task = nil
        let session = session; self.session = nil
        timer?.cancel(); timer = nil
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
        callback?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse { owner.observe(http, attempt: attempt) }
        lock.lock(); self.response = response; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        lock.lock(); if !completed { data.append(bytes) }; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let response = self.response, data = self.data
        lock.unlock()
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled { finish(.failure(CancellationError())); return }
            finish(.failure(error)); return
        }
        guard let response else { finish(.failure(URLError(.badServerResponse))); return }
        finish(.success((data, response)))
    }
}

func isRetryableHTTPFailure(_ error: Error) -> Bool {
    if let httpError = error as? HTTPError {
        switch httpError.statusCode {
        case 408, 409, 425, 429, 500, 502, 503, 504, 529:
            return true
        default:
            return false
        }
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .requestBodyStreamExhausted:
            return true
        default:
            return false
        }
    }
    return false
}

func httpRetryDelay(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
    if let retryAfter, retryAfter.isFinite, retryAfter >= 0 {
        return min(retryAfter, 30)
    }
    let exponential = min(pow(2.0, Double(attempt - 1)), 4.0)
    let jitter = Double.random(in: 0...0.25)
    return exponential + jitter
}

// MARK: - HTTP Error

enum HTTPError: LocalizedError {
    case badStatus(Int, String?, TimeInterval?)

    static func throwIfBad(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8)
            throw HTTPError.badStatus(http.statusCode, body, Self.retryAfterDelay(from: http))
        }
    }

    var statusCode: Int {
        switch self {
        case .badStatus(let code, _, _): return code
        }
    }

    var retryAfter: TimeInterval? {
        switch self {
        case .badStatus(_, _, let retryAfter): return retryAfter
        }
    }

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body, _):
            return "HTTP \(code): \(body ?? "No body")"
        }
    }

    private static func retryAfterDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds.isFinite {
            return max(0, min(seconds, 30))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, min(date.timeIntervalSinceNow, 30))
    }
}

// MARK: - JSON Extraction

/// Extract the first JSON object from a string that may contain other text
func extractFirstJSONObjectData(from text: String) -> Data? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    
    var depth = 0
    var inString = false
    var escape = false
    var endIndex: String.Index?
    
    for i in text.indices[start...] {
        let char = text[i]
        
        if escape {
            escape = false
            continue
        }
        
        if char == "\\" && inString {
            escape = true
            continue
        }
        
        if char == "\"" {
            inString = !inString
            continue
        }
        
        if inString { continue }
        
        if char == "{" {
            depth += 1
        } else if char == "}" {
            depth -= 1
            if depth == 0 {
                endIndex = text.index(after: i)
                break
            }
        }
    }
    
    guard let end = endIndex else { return nil }
    let jsonString = String(text[start..<end])
    return jsonString.data(using: .utf8)
}

// BEGIN JSON-REPAIR (extraction markers for the standalone test harness)
/// Structural salvage for model-malformed JSON: rebuilds the first object in
/// `text` with delimiter closers that match the actual open stack. Exists
/// because some models emit deterministically swapped closers at the tail
/// (Luna: `}]}` where `]}]` belongs — three independent occurrences with the
/// same signature in web-pipeline.log), and a deterministic malformation
/// defeats retries: same prompt, same broken tail, every attempt billed.
///
/// Scanning is string- and escape-aware. Repairs performed:
///   - a closer that mismatches the innermost open delimiter is replaced
///     with the expected one (the swap signature)
///   - closers still missing at end-of-text are appended
/// Returns nil when there is nothing to repair (no object start, no change
/// needed, or the text ends INSIDE a string literal — that is truncation,
/// where regenerating is the right medicine, not guessing at content).
/// Callers must re-decode the returned data and fall back to the normal
/// retry path if it still fails; `note` is a log-friendly change summary.
func repairFirstJSONObjectData(from text: String) -> (data: Data, note: String)? {
    guard let start = text.firstIndex(of: "{") else { return nil }

    func closer(for open: Character) -> Character { open == "{" ? "}" : "]" }

    var out = ""
    var stack: [Character] = []
    var inString = false
    var escape = false
    var cascaded = 0     // inner frames auto-closed before a matching closer
    var substituted = 0  // closers replaced because their opener isn't open
    var appended = 0     // closers appended at end-of-text

    for char in text[start...] {
        if inString {
            out.append(char)
            if escape { escape = false }
            else if char == "\\" { escape = true }
            else if char == "\"" { inString = false }
            continue
        }
        switch char {
        case "\"":
            inString = true
            out.append(char)
        case "{", "[":
            stack.append(char)
            out.append(char)
        case "}", "]":
            let opener: Character = char == "}" ? "{" : "["
            if stack.contains(opener) {
                // The frame this closer belongs to IS open, just not
                // innermost — auto-close the inner frames above it first
                // (handles both a missing inner closer and swapped order).
                while let top = stack.last, top != opener {
                    out.append(closer(for: top))
                    stack.removeLast()
                    cascaded += 1
                }
                stack.removeLast()
                out.append(char)
            } else if let top = stack.popLast() {
                // No such frame open — the closer itself is the wrong
                // character; substitute the one the innermost frame needs.
                out.append(closer(for: top))
                substituted += 1
            } else {
                return nil // closer before any opener — beyond salvage
            }
        default:
            out.append(char)
        }
        if !stack.isEmpty { continue }
        // Object complete — trailing text (prose, stray closers, a second
        // object) is ignored, matching extractFirstJSONObjectData.
        break
    }

    if inString { return nil }
    while let open = stack.popLast() {
        out.append(closer(for: open))
        appended += 1
    }
    guard cascaded > 0 || substituted > 0 || appended > 0 else { return nil }
    guard let data = out.data(using: .utf8) else { return nil }
    // The repair must yield structurally valid JSON, or it is no repair at
    // all — callers additionally re-decode against their expected schema.
    guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
    return (data, "cascade=\(cascaded) subst=\(substituted) append=\(appended)")
}
// END JSON-REPAIR

/// Renders a JSONDecoder failure as a single log-friendly line: the error
/// case, the coding path, and — for corrupt data — Foundation's underlying
/// "around character N" offset, which pinpoints where the payload breaks.
/// Offsets are relative to the extracted JSON candidate, not the raw response.
func describeJSONDecodeError(_ error: Error) -> String {
    func path(_ ctx: DecodingError.Context) -> String {
        let p = ctx.codingPath.map { key in
            key.intValue.map { "[\($0)]" } ?? key.stringValue
        }.joined(separator: ".")
        return p.isEmpty ? "<root>" : p
    }
    guard let decoding = error as? DecodingError else { return String(describing: error) }
    switch decoding {
    case .dataCorrupted(let ctx):
        var detail = ctx.debugDescription
        if let underlying = ctx.underlyingError as NSError?,
           let debug = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
            detail += " — \(debug)"
        }
        return "dataCorrupted at \(path(ctx)): \(detail)"
    case .keyNotFound(let key, let ctx):
        return "keyNotFound '\(key.stringValue)' at \(path(ctx))"
    case .typeMismatch(let type, let ctx):
        return "typeMismatch expecting \(type) at \(path(ctx)): \(ctx.debugDescription)"
    case .valueNotFound(let type, let ctx):
        return "valueNotFound \(type) at \(path(ctx)): \(ctx.debugDescription)"
    @unknown default:
        return String(describing: decoding)
    }
}

// MARK: - Time Helpers

func nowStamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm (EEEE)"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: Date())
}

// MARK: - String Extensions

extension String {
    func prefixing(_ maxLength: Int) -> String {
        if self.count <= maxLength { return self }
        return String(self.prefix(maxLength))
    }
}
