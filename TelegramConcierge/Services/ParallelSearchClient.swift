import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Parallel keyless search (KEYLESS_WEB_AND_LIVE_MENU_PLAN A.4)
//
// Parallel's free Search MCP (`https://search.parallel.ai/mcp`) spoken as
// plain MCP Streamable HTTP (2025-06-18) over URLSession — no MCP library:
// `initialize` → `notifications/initialized` → `tools/call web_search`.
// No Authorization header, no affinity header: no account identifiers are
// sent; the query text and network metadata (IP) do reach Parallel.

/// One search result in the shape the pipeline already consumes.
struct ParallelSearchHit: Equatable, Sendable {
    let title: String
    let link: String
    let snippet: String
    let date: String?
}

enum ParallelSearchError: LocalizedError, Equatable {
    case rateLimited(String)
    case server(Int, String)
    case http(Int, String)
    case rpc(String)
    case tool(String)
    case protocolChanged(String)
    case badPayload(String)
    case transport(String)
    case deadline
    case budget
    case busy

    /// Counts toward the breaker (rate-limit and server failures only).
    var opensBreaker: Bool {
        switch self {
        case .rateLimited, .server: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .rateLimited(let d): return "Free search (Parallel) is rate limited right now\(d.isEmpty ? "" : " (\(d))"). Try again shortly, or add a Serper.dev key in briglia menu."
        case .server(let code, let d): return "Free search (Parallel) failed: HTTP \(code)\(d.isEmpty ? "" : " — \(d)")"
        case .http(let code, let d): return "Free search (Parallel) refused the request: HTTP \(code)\(d.isEmpty ? "" : " — \(d)")"
        case .rpc(let d): return "Free search (Parallel) returned an error: \(d)"
        case .tool(let d): return "Free search (Parallel) returned an error: \(d)"
        case .protocolChanged(let d): return "Free search protocol changed (\(d)). Add a Serper.dev key in briglia menu, or update Briglia."
        case .badPayload(let d): return "Free search (Parallel) returned an unexpected response: \(d)"
        case .transport(let d): return "Free search (Parallel) could not be reached: \(d)"
        case .deadline: return "Free search (Parallel) did not answer in time. Try again shortly."
        case .budget: return "Free search (Parallel) failed after its retry allowance. Try again shortly."
        case .busy: return "Free search is busy right now (Parallel). Try again in a few minutes, or add a Serper.dev key in briglia menu."
        }
    }
}

/// One HTTP exchange as the client sees it (test seam: `sendOverride`).
struct ParallelHTTPReply: Sendable {
    let status: Int
    let headers: [String: String]  // lower-cased names
    /// `application/json`: the whole body. `text/event-stream`: the data of
    /// each complete event, in order (the transport stops reading once the
    /// response with `stopAtID` arrived).
    let jsonBody: Data?
    let events: [String]
}

actor ParallelSearchClient {
    static let shared = ParallelSearchClient()

    static let endpoint = URL(string: "https://search.parallel.ai/mcp")!
    /// Development builds only, where `BRIGLIA_DEV_SERPER_BASE` is honoured.
    static var endpointURL: URL {
        if adaCLIVersion.hasSuffix("-dev"), let raw = ProcessInfo.processInfo.environment["BRIGLIA_DEV_PARALLEL_BASE"],
           !raw.isEmpty, let url = URL(string: raw.hasSuffix("/mcp") ? raw : raw + "/mcp") { return url }
        return endpoint
    }

    static let sentProtocolVersion = "2025-06-18"
    static let acceptedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26"]

    // Budget (A.4).
    struct Limits: Sendable {
        var totalDeadline: TimeInterval = 45
        var perRequestTimeout: TimeInterval = 20
        var maxSearchAttempts = 2
        var maxRecoveries = 1
        var maxRequests = 8
        var maxConcurrent = 4
        var breakerThreshold = 3
        var breakerOpenFor: TimeInterval = 300
        var bodyCap = 2 * 1024 * 1024
        var eventCap = 1024 * 1024
        /// Backoff when a retryable failure carries no Retry-After.
        var defaultBackoff: TimeInterval = 1
    }
    var limits = Limits()

    typealias Send = @Sendable (_ request: URLRequest, _ stopAtID: Int?, _ limits: Limits,
                                _ onServerRequest: @escaping ServerRequestHandler) async throws -> ParallelHTTPReply
    private var sendOverride: Send?
    private var clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    // MARK: Transport session (generation-guarded)
    struct TransportSession: Sendable {
        let generation: Int
        let mcpSessionID: String?
        let protocolVersion: String
    }
    private var generation = 0
    private var session: TransportSession?
    private var initializing: (generation: Int, task: Task<Void, Never>)?
    private var nextRPCID = 1

    // MARK: Breaker
    enum BreakerState: Equatable, Sendable { case closed, open(until: TimeInterval), halfOpen(probeInFlight: Bool) }
    private var consecutiveFailures = 0
    private var breaker: BreakerState = .closed

    // MARK: Concurrency cap
    private var inFlight = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    // MARK: Telemetry (selftests, doctor)
    struct Counters: Sendable, Equatable {
        var httpRequests = 0
        var initializes = 0
        var searchCalls = 0
        var errorReplies = 0
        var maxObservedInFlight = 0
    }
    private(set) var counters = Counters()

    // MARK: - Test seams

    func installForTesting(send: Send?, limits: Limits = Limits(), clock: (@Sendable () -> TimeInterval)? = nil) {
        sendOverride = send
        self.limits = limits
        self.clock = clock ?? { ProcessInfo.processInfo.systemUptime }
        resetStateForTesting()
    }

    func resetStateForTesting() {
        generation += 1
        session = nil
        initializing?.task.cancel()
        initializing = nil
        consecutiveFailures = 0
        breaker = .closed
        counters = Counters()
    }

    func breakerStateForTesting() -> BreakerState { breaker }
    func sessionForTesting() -> TransportSession? { session }

    /// Doctor/status line.
    func breakerSummary() -> String {
        switch breaker {
        case .closed: return "ok"
        case .open(let until): return "cooling down (\(max(0, Int(until - clock())))s left after repeated rate limits or server errors)"
        case .halfOpen: return "recovering (next search is a probe)"
        }
    }

    // MARK: - Search

    /// One logical search (one Briglia query). `sessionID` is the
    /// conversation search ID (A.5), passed in, never minted here.
    func search(query: String, sessionID: String, depth: Int) async throws -> [ParallelSearchHit] {
        let started = clock()
        let deadline = started + limits.totalDeadline
        let isProbe = try admitThroughBreaker()
        // A probe that ends without settling the breaker (cancelled, or a
        // failure that doesn't count) gives the probe slot back; a settled
        // breaker (closed/open) is left as it is.
        defer { if isProbe { releaseProbe() } }
        try Task.checkCancellation()

        try await acquireSlot(deadline: deadline)
        defer { releaseSlot() }

        let budget = RequestBudget(maxRequests: limits.maxRequests)
        do {
            let hits = try await searchWithinBudget(query: query, sessionID: sessionID, depth: depth, deadline: deadline, budget: budget)
            recordOutcome(success: true, error: nil, probe: isProbe)
            return hits
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ParallelSearchError {
            // A caller that cancelled while a shared request failed never
            // charges that failure to health or the breaker.
            if Task.isCancelled { throw CancellationError() }
            recordOutcome(success: false, error: error, probe: isProbe)
            throw error
        }
    }

    /// One logical call's allowance. A reference: server-request replies are
    /// sent from the transport callback while the stream is still open.
    final class RequestBudget: @unchecked Sendable {
        let maxRequests: Int
        private let lock = NSLock()
        private var _used = 0
        var searchAttempts = 0
        var recoveries = 0
        init(maxRequests: Int) { self.maxRequests = maxRequests }
        var used: Int { lock.lock(); defer { lock.unlock() }; return _used }
        /// Takes `n` requests from the allowance, or none at all.
        func take(_ n: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard _used + n <= maxRequests else { return false }
            _used += n
            return true
        }
    }

    private func searchWithinBudget(query: String, sessionID: String, depth: Int, deadline: TimeInterval,
                                    budget: RequestBudget) async throws -> [ParallelSearchHit] {
        var lastError: ParallelSearchError = .budget
        while budget.searchAttempts < limits.maxSearchAttempts {
            try Task.checkCancellation()
            let current = try await ensureSession(deadline: deadline, budget: budget)
            budget.searchAttempts += 1
            do {
                return try await callSearch(query: query, sessionID: sessionID, depth: depth, session: current,
                                            deadline: deadline, budget: budget)
            } catch let failure as CallFailure {
                switch failure {
                case .expired:
                    // Recognizable expiry only: HTTP 404 on a request that
                    // carried Mcp-Session-Id. Recovery consumes the second
                    // attempt; an older generation can't clobber a newer one.
                    guard budget.recoveries < limits.maxRecoveries else { throw ParallelSearchError.budget }
                    budget.recoveries += 1
                    invalidate(generation: current.generation)
                    lastError = .http(404, "session expired")
                    continue
                case .retryable(let error, let retryAfter):
                    lastError = error
                    guard budget.searchAttempts < limits.maxSearchAttempts else { throw error }
                    let wait = retryAfter ?? limits.defaultBackoff
                    // Never retry earlier than the server asked; never past the deadline.
                    guard clock() + wait < deadline else { throw error }
                    try await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                    continue
                case .final(let error):
                    throw error
                }
            }
        }
        throw lastError
    }

    private enum CallFailure: Error {
        case expired
        case retryable(ParallelSearchError, retryAfter: TimeInterval?)
        case final(ParallelSearchError)
    }

    // MARK: Session

    private func ensureSession(deadline: TimeInterval, budget: RequestBudget) async throws -> TransportSession {
        if let session { return session }
        if initializing?.generation != generation {
            // This call starts the initialize: its requests count against ITS
            // budget. The initialize runs on its own and settles EVERY waiter;
            // a waiter that leaves (cancelled, out of time) never stops it.
            guard budget.take(2) else { throw ParallelSearchError.budget }
            let gen = generation
            let task = Task { [weak self] in
                guard let self else { return }
                let result: Result<TransportSession, Error>
                do { result = .success(try await self.performInitialize(generation: gen, deadline: deadline, budget: budget)) }
                catch { result = .failure(error) }
                await self.finishInitialize(generation: gen, result)
            }
            initializing = (gen, task)
        }
        return try await waitForInitialize(deadline: deadline)
    }

    /// Each waiter settles independently: on the initialize's outcome, its
    /// own cancellation, or its own deadline — whichever comes first.
    private func waitForInitialize(deadline: TimeInterval) async throws -> TransportSession {
        let id = UUID()
        let remaining = deadline - clock()
        guard remaining > 0 else { throw ParallelSearchError.deadline }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            await self?.failInitWaiter(id, with: ParallelSearchError.deadline)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransportSession, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                initWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.failInitWaiter(id, with: CancellationError()) }
        }
    }

    private var initWaiters: [(id: UUID, continuation: CheckedContinuation<TransportSession, Error>)] = []

    private func failInitWaiter(_ id: UUID, with error: Error) {
        guard let index = initWaiters.firstIndex(where: { $0.id == id }) else { return }
        initWaiters.remove(at: index).continuation.resume(throwing: error)
    }

    private func finishInitialize(generation gen: Int, _ result: Result<TransportSession, Error>) {
        if initializing?.generation == gen { initializing = nil }
        let mapped: Result<TransportSession, Error> = result.mapError { error in
            switch error as? CallFailure {
            case .final(let e)?: return e
            case .retryable(let e, _)?: return e
            case .expired?: return ParallelSearchError.http(404, "session expired during initialize")
            case nil: return error
            }
        }
        let waiters = initWaiters
        initWaiters = []
        for waiter in waiters { waiter.continuation.resume(with: mapped) }
    }

    private func performInitialize(generation gen: Int, deadline: TimeInterval, budget: RequestBudget) async throws -> TransportSession {
        let id = takeRPCID()
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "initialize",
            "params": ["protocolVersion": Self.sentProtocolVersion, "capabilities": [String: Any](),
                       "clientInfo": ["name": "Briglia", "version": adaCLIVersion]]
        ]
        counters.initializes += 1
        let reply = try await send(body, sessionID: nil, protocolVersion: nil, stopAtID: id, deadline: deadline,
                                   serverRequests: rejectServerRequests(session: nil, protocolVersion: nil, deadline: deadline, budget: budget))
        if let failure = classifyHTTP(reply, carriedSession: false) { throw failure }
        let message = try responseMessage(reply, id: id)
        if let error = message["error"] as? [String: Any] { throw CallFailure.final(rpcError(error)) }
        guard let result = message["result"] as? [String: Any] else { throw CallFailure.final(.badPayload("initialize returned no result")) }
        guard let version = result["protocolVersion"] as? String, Self.acceptedProtocolVersions.contains(version) else {
            throw CallFailure.final(.protocolChanged("server speaks \((result["protocolVersion"] as? String) ?? "an unknown version")"))
        }
        let mcpSession = reply.headers["mcp-session-id"].flatMap { $0.isEmpty ? nil : $0 }
        // notifications/initialized: no id, HTTP 202 with an empty body is the expected answer.
        let note: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        let ack = try await send(note, sessionID: mcpSession, protocolVersion: version, stopAtID: nil, deadline: deadline)
        if let failure = classifyHTTP(ack, carriedSession: mcpSession != nil) {
            if case .expired = failure { throw CallFailure.final(.http(404, "session rejected right after initialize")) }
            throw failure
        }
        let established = TransportSession(generation: gen, mcpSessionID: mcpSession, protocolVersion: version)
        if generation == gen { session = established }
        return established
    }

    private func invalidate(generation gen: Int) {
        // Compare before replacing: a failure seen on an OLD session never
        // drops a newer one another call already established.
        guard session?.generation == gen || (session == nil && generation == gen) else { return }
        session = nil
        generation += 1
    }

    // MARK: tools/call

    private func callSearch(query: String, sessionID: String, depth: Int, session current: TransportSession,
                            deadline: TimeInterval, budget: RequestBudget) async throws -> [ParallelSearchHit] {
        guard budget.take(1) else { throw ParallelSearchError.budget }
        let id = takeRPCID()
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": "web_search",
                       "arguments": ["objective": query, "search_queries": [query], "session_id": sessionID] as [String: Any]]
        ]
        counters.searchCalls += 1
        // Server requests on the stream are answered WHILE it is open (the
        // server may wait for the answer before it sends the result).
        let reply = try await send(body, sessionID: current.mcpSessionID, protocolVersion: current.protocolVersion,
                                   stopAtID: id, deadline: deadline,
                                   serverRequests: rejectServerRequests(session: current.mcpSessionID, protocolVersion: current.protocolVersion,
                                                                        deadline: deadline, budget: budget))
        if let failure = classifyHTTP(reply, carriedSession: current.mcpSessionID != nil) { throw failure }
        let message = try responseMessage(reply, id: id)
        if let error = message["error"] as? [String: Any] {
            let classified = rpcError(error)
            if case .rateLimited = classified { throw CallFailure.retryable(classified, retryAfter: retryAfter(reply)) }
            throw CallFailure.final(classified)
        }
        guard let result = message["result"] as? [String: Any] else { throw CallFailure.final(.badPayload("no result")) }
        if (result["isError"] as? Bool) == true {
            let text = Self.texts(result).joined(separator: " ").prefixing(300)
            if Self.looksRateLimited(text) { throw CallFailure.retryable(.rateLimited(text), retryAfter: retryAfter(reply)) }
            throw CallFailure.final(.tool(text.isEmpty ? "tool error" : text))
        }
        guard let hits = Self.decodeHits(result, depth: depth) else {
            throw CallFailure.final(.badPayload("no search results payload"))
        }
        return hits
    }

    // MARK: Decoding

    private struct Payload: Decodable {
        struct Item: Decodable { let url: String?; let title: String?; let publish_date: String?; let excerpts: [String]? }
        let results: [Item]
    }

    static func texts(_ result: [String: Any]) -> [String] {
        (result["content"] as? [[String: Any]] ?? []).compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
    }

    /// `structuredContent` when present and decodable; otherwise the first
    /// text block whose text decodes as `{results:[…]}`.
    static func decodeHits(_ result: [String: Any], depth: Int) -> [ParallelSearchHit]? {
        var payload: Payload?
        if let structured = result["structuredContent"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = decoded
        }
        if payload == nil {
            for text in texts(result) {
                if let decoded = try? JSONDecoder().decode(Payload.self, from: Data(text.utf8)) { payload = decoded; break }
            }
        }
        guard let payload else { return nil }
        var hits: [ParallelSearchHit] = []
        for item in payload.results {
            guard let link = item.url, !link.isEmpty else { continue }
            let snippet = (item.excerpts ?? []).joined(separator: " … ")
            hits.append(ParallelSearchHit(title: item.title ?? link, link: link, snippet: snippet,
                                          date: item.publish_date.flatMap { $0.isEmpty ? nil : $0 }))
            if hits.count >= depth { break }
        }
        return hits
    }

    static func looksRateLimited(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("rate limit") || lower.contains("rate-limit") || lower.contains("too many requests")
    }

    private func rpcError(_ error: [String: Any]) -> ParallelSearchError {
        let message = (error["message"] as? String ?? "").prefixing(300)
        let code = error["code"] as? Int
        if code == -32029 || Self.looksRateLimited(message) { return .rateLimited(message) }
        return .rpc(code.map { "\($0): \(message)" } ?? message)
    }

    private func retryAfter(_ reply: ParallelHTTPReply) -> TimeInterval? {
        guard let raw = reply.headers["retry-after"] else { return nil }
        return Self.parseRetryAfter(raw, now: Date())
    }

    /// RFC 9110 §10.2.3: delay-seconds or an HTTP-date (IMF-fixdate, plus the
    /// obsolete RFC 850 and asctime forms). Never capped: a long wait fails
    /// the call rather than retrying early. A past date means "now" (0).
    static func parseRetryAfter(_ raw: String, now: Date) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(value) { return seconds.isFinite && seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'", "EEEE',' dd'-'MMM'-'yy HH':'mm':'ss 'GMT'", "EEE MMM d HH':'mm':'ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }

    private func classifyHTTP(_ reply: ParallelHTTPReply, carriedSession: Bool) -> CallFailure? {
        let status = reply.status
        if (200...299).contains(status) { return nil }
        let detail = reply.jsonBody.flatMap { String(data: $0.prefix(300), encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status == 404 && carriedSession { return .expired }
        if status == 429 { return .retryable(.rateLimited(detail.prefixing(200)), retryAfter: retryAfter(reply)) }
        if (500...599).contains(status) { return .retryable(.server(status, detail.prefixing(200)), retryAfter: retryAfter(reply)) }
        return .final(.http(status, detail.prefixing(200)))
    }

    private func responseMessage(_ reply: ParallelHTTPReply, id: Int) throws -> [String: Any] {
        if let body = reply.jsonBody {
            guard let object = try? JSONSerialization.jsonObject(with: body) else {
                throw CallFailure.final(.badPayload("not JSON"))
            }
            // A JSON body is one response (a batch array is tolerated).
            let candidates = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
            if let match = candidates.first(where: { Self.rpcID($0["id"]) == id }) { return match }
            throw CallFailure.final(.badPayload("no response for request \(id)"))
        }
        for event in reply.events {
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any] else { continue }
            if object["method"] != nil { continue }  // notification or server request
            if Self.rpcID(object["id"]) == id { return object }
        }
        throw CallFailure.final(.badPayload("the event stream ended without a response"))
    }

    /// The handler the transport calls for each server REQUEST on an open
    /// stream: one JSON-RPC "method not found" reply by POST, sent at once
    /// (not awaited by the stream), counted in the call's request budget and
    /// bounded by its deadline. Over budget: not answered.
    private nonisolated func rejectServerRequests(session: String?, protocolVersion: String?, deadline: TimeInterval,
                                                  budget: RequestBudget) -> ServerRequestHandler {
        { [weak self] requestID in
            guard let self, budget.take(1) else { return }
            Task {
                let answer: [String: Any] = ["jsonrpc": "2.0", "id": requestID.value, "error": ["code": -32601, "message": "Method not found"]]
                await self.noteErrorReply()
                _ = try? await self.send(answer, sessionID: session, protocolVersion: protocolVersion, stopAtID: nil, deadline: deadline)
            }
        }
    }

    private func noteErrorReply() { counters.errorReplies += 1 }

    /// A JSON-RPC id as received (number or string), for echoing back.
    struct RPCRequestID: @unchecked Sendable { let value: Any }
    typealias ServerRequestHandler = @Sendable (RPCRequestID) -> Void

    static func serverRequestID(_ event: String) -> RPCRequestID? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
              object["method"] != nil, let id = object["id"], !(id is NSNull) else { return nil }
        return RPCRequestID(value: id)
    }

    static func rpcID(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func takeRPCID() -> Int { defer { nextRPCID += 1 }; return nextRPCID }

    // MARK: HTTP

    private func send(_ body: [String: Any], sessionID: String?, protocolVersion: String?, stopAtID: Int?,
                      deadline: TimeInterval, serverRequests: ServerRequestHandler? = nil) async throws -> ParallelHTTPReply {
        let remaining = deadline - clock()
        guard remaining > 0 else { throw CallFailure.final(.deadline) }
        var request = URLRequest(url: Self.endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = min(limits.perRequestTimeout, remaining)
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SessionAffinity.userAgent, forHTTPHeaderField: "User-Agent")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        counters.httpRequests += 1
        let sender = sendOverride ?? ParallelHTTPTransport.send
        do {
            return try await sender(request, stopAtID, limits, serverRequests ?? { _ in })
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let urlError as URLError {
            if urlError.code == .timedOut && clock() >= deadline { throw CallFailure.final(.deadline) }
            throw CallFailure.retryable(.transport(urlError.localizedDescription), retryAfter: nil)
        } catch let error as ParallelSearchError {
            throw CallFailure.final(error)
        } catch {
            throw CallFailure.retryable(.transport(error.localizedDescription), retryAfter: nil)
        }
    }

    // MARK: Breaker

    /// Returns whether this call is the half-open probe; throws `.busy` when
    /// the breaker refuses it.
    private func admitThroughBreaker() throws -> Bool {
        switch breaker {
        case .closed: return false
        case .open(let until):
            guard clock() >= until else { throw ParallelSearchError.busy }
            breaker = .halfOpen(probeInFlight: true)
            return true
        case .halfOpen(let probeInFlight):
            if probeInFlight { throw ParallelSearchError.busy }
            breaker = .halfOpen(probeInFlight: true)
            return true
        }
    }

    private func releaseProbe() {
        if case .halfOpen = breaker { breaker = .halfOpen(probeInFlight: false) }
    }

    private func recordOutcome(success: Bool, error: ParallelSearchError?, probe: Bool) {
        if success {
            consecutiveFailures = 0
            breaker = .closed
            return
        }
        guard let error, error.opensBreaker else {
            if probe { releaseProbe() }
            return
        }
        consecutiveFailures += 1
        if probe || consecutiveFailures >= limits.breakerThreshold {
            breaker = .open(until: clock() + limits.breakerOpenFor)
        }
    }

    // MARK: Concurrency

    private func acquireSlot(deadline: TimeInterval) async throws {
        if inFlight < limits.maxConcurrent {
            inFlight += 1
            counters.maxObservedInFlight = max(counters.maxObservedInFlight, inFlight)
            return
        }
        let id = UUID()
        let remaining = deadline - clock()
        guard remaining > 0 else { throw ParallelSearchError.deadline }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            await self?.failWaiter(id, with: ParallelSearchError.deadline)
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.failWaiter(id, with: CancellationError()) }
        }
        counters.maxObservedInFlight = max(counters.maxObservedInFlight, inFlight)
    }

    private func failWaiter(_ id: UUID, with error: Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: error)
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            // The slot passes straight to the next waiter (inFlight unchanged).
            waiters.removeFirst().continuation.resume()
        } else {
            inFlight -= 1
        }
    }
}

// MARK: - Bounded streaming transport

/// URLSession delegate transport: a per-request timeout, a 2 MiB body cap
/// and, for `text/event-stream`, an incremental SSE reader that stops at the
/// response whose id it waits for (a 1 MiB cap per event). Linux uses the
/// one shared session (SharedDataTaskSession), macOS one session per request.
final class ParallelHTTPTransport: NSObject, URLSessionDataDelegate, RoutedDataTaskDelegate, @unchecked Sendable {
    let refusesRedirects = true
    private let stopAtID: Int?
    private let limits: ParallelSearchClient.Limits
    private let onServerRequest: ParallelSearchClient.ServerRequestHandler
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ParallelHTTPReply, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchWorkItem?
    private var completed = false
    private var response: HTTPURLResponse?
    private var body = Data()
    private var isEventStream = false
    private var parser = SSEParser()
    private var events: [String] = []

    init(stopAtID: Int?, limits: ParallelSearchClient.Limits, onServerRequest: @escaping ParallelSearchClient.ServerRequestHandler) {
        self.stopAtID = stopAtID; self.limits = limits; self.onServerRequest = onServerRequest; super.init()
    }

    static let send: ParallelSearchClient.Send = { request, stopAtID, limits, onServerRequest in
        try await ParallelHTTPTransport(stopAtID: stopAtID, limits: limits, onServerRequest: onServerRequest).run(request)
    }

    func run(_ request: URLRequest) async throws -> ParallelHTTPReply {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if completed { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let task: URLSessionDataTask
                if let shared = SharedDataTaskSession.active {
                    task = shared.dataTask(with: request, delegate: self)
                } else {
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = request.timeoutInterval
                    config.timeoutIntervalForResource = request.timeoutInterval + 5
                    config.httpCookieStorage = nil
                    config.urlCache = nil
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    self.session = session
                    task = session.dataTask(with: request)
                }
                self.task = task
                let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
                self.timer = timer
                DispatchQueue.global().asyncAfter(deadline: .now() + request.timeoutInterval, execute: timer)
                task.resume(); lock.unlock()
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }

    private func finish(_ result: Result<ParallelHTTPReply, Error>) {
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

    private func replyLocked() -> ParallelHTTPReply {
        var headers: [String: String] = [:]
        for (key, value) in response?.allHeaderFields ?? [:] {
            if let k = key as? String, let v = value as? String { headers[k.lowercased()] = v }
        }
        return ParallelHTTPReply(status: response?.statusCode ?? 0, headers: headers,
                                 jsonBody: isEventStream ? nil : body, events: events)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        let type = (self.response?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        isEventStream = type.contains("text/event-stream") && (200...299).contains(self.response?.statusCode ?? 0)
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if completed { lock.unlock(); return }
        if body.count + data.count > limits.bodyCap {
            lock.unlock()
            finish(.failure(ParallelSearchError.badPayload("response larger than \(limits.bodyCap / 1024 / 1024) MiB")))
            return
        }
        guard isEventStream else { body.append(data); lock.unlock(); return }
        body.append(data)
        let outcome = parser.feed(data, eventCap: limits.eventCap)
        events.append(contentsOf: outcome.events)
        let overflow = outcome.overflow
        let done = stopAtID.map { id in outcome.events.contains { SSEParser.isResponse($0, id: id) } } ?? false
        let reply = done ? replyLocked() : nil
        let requests = outcome.events.compactMap(ParallelSearchClient.serverRequestID)
        lock.unlock()
        // Answered while the stream is open, each exactly once.
        for request in requests { onServerRequest(request) }
        if overflow { finish(.failure(ParallelSearchError.badPayload("an event larger than \(limits.eventCap / 1024) KiB"))); return }
        if let reply { finish(.success(reply)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled { finish(.failure(CancellationError())); return }
            finish(.failure(error)); return
        }
        lock.lock()
        if isEventStream { events.append(contentsOf: parser.flush()) }
        let hasResponse = response != nil
        let reply = replyLocked()
        lock.unlock()
        guard hasResponse else { finish(.failure(URLError(.badServerResponse))); return }
        finish(.success(reply))
    }
}

/// Incremental Server-Sent Events reader: complete events only (multi-line
/// `data:` joined with "\n"; `event`/`id`/`retry` fields and comments
/// accepted and ignored). Bytes are buffered until a blank line ends the
/// event; a partial event never surfaces.
struct SSEParser {
    private var pending = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0

    struct Outcome { var events: [String]; var overflow: Bool }

    mutating func feed(_ chunk: Data, eventCap: Int) -> Outcome {
        pending.append(chunk)
        var out: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var lineData = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            if line.isEmpty {
                if !dataLines.isEmpty { out.append(dataLines.joined(separator: "\n")) }
                dataLines = []; eventBytes = 0
                continue
            }
            if line.hasPrefix(":") { continue }
            let field: Substring, value: Substring
            if let colon = line.firstIndex(of: ":") {
                field = line[..<colon]
                var rest = line[line.index(after: colon)...]
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                value = rest
            } else { field = Substring(line); value = "" }
            if field == "data" {
                eventBytes += value.utf8.count
                if eventBytes > eventCap { return Outcome(events: out, overflow: true) }
                dataLines.append(String(value))
            }
        }
        if pending.count > eventCap { return Outcome(events: out, overflow: true) }
        return Outcome(events: out, overflow: false)
    }

    /// End of stream: an event without its terminating blank line counts.
    mutating func flush() -> [String] {
        if !pending.isEmpty { _ = feed(Data([0x0A]), eventCap: .max) }
        defer { dataLines = [] }
        return dataLines.isEmpty ? [] : [dataLines.joined(separator: "\n")]
    }

    static func isResponse(_ event: String, id: Int) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
              object["method"] == nil else { return false }
        return ParallelSearchClient.rpcID(object["id"]) == id
    }
}
