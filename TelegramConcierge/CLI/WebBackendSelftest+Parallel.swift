import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Parallel keyless client (KEYLESS_WEB plan A.4): transport, parsing,
// retries/budget, breaker, concurrency, cancellation. One function per group.
extension WebBackendSelftest {
    static let sessionA = "11111111-2222-4333-8444-555555555555"

    static func search(_ query: String, session: String = sessionA, depth: Int = 10) async -> Result<[ParallelSearchHit], Error> {
        do { return .success(try await ParallelSearchClient.shared.search(query: query, sessionID: session, depth: depth)) }
        catch { return .failure(error) }
    }

    static func fresh(_ fake: FakeParallel, limits: ParallelSearchClient.Limits = .init(), clock: (@Sendable () -> TimeInterval)? = nil) async {
        fake.reset()
        await ParallelSearchClient.shared.installForTesting(send: nil, limits: limits, clock: clock)
    }

    static func sse(_ objects: [[String: Any]], trailingNewline: Bool = true) -> [String] {
        objects.map { object in
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            return "data: \(text)\n\n"
        }
    }

    static func runParallelTransportGroup(_ c: Checker, fake: FakeParallel) async throws {
        print("P1. Parallel transport")
        await fresh(fake)
        let r1 = await search("alpha beta")
        let hits = (try? r1.get()) ?? []
        let reqs = fake.requests
        let methods = reqs.map(\.method)
        c.check("P1.1 cold call = initialize + notifications/initialized + tools/call (3 requests); 10 of 12 results kept (depth)",
                methods == ["initialize", "notifications/initialized", "tools/call"] && hits.count == 10, "\(methods) \(r1)")
        let initBody = reqs.first?.body ?? [:]
        let initParams = initBody["params"] as? [String: Any] ?? [:]
        c.check("P1.2 initialize sends exactly one protocolVersion (2025-06-18) and no Mcp-Session-Id/MCP-Protocol-Version header",
                initParams["protocolVersion"] as? String == "2025-06-18" && reqs.first?.headers["mcp-session-id"] == nil
                && reqs.first?.headers["mcp-protocol-version"] == nil, "\(initParams)")
        let call = reqs.last
        let args = ((call?.body["params"] as? [String: Any])?["arguments"] as? [String: Any]) ?? [:]
        c.check("P1.3 tools/call web_search {objective, search_queries:[q], session_id} — the conversation search ID, nothing else",
                (call?.body["params"] as? [String: Any])?["name"] as? String == "web_search"
                && args["objective"] as? String == "alpha beta" && (args["search_queries"] as? [String]) == ["alpha beta"]
                && args["session_id"] as? String == sessionA && args.count == 3, "\(args)")
        let headers = call?.headers ?? [:]
        c.check("P1.4 headers: Accept json+event-stream, JSON content type, Briglia User-Agent, Mcp-Session-Id echoed, MCP-Protocol-Version; no Authorization, no affinity header",
                headers["accept"] == "application/json, text/event-stream" && headers["content-type"] == "application/json"
                && headers["user-agent"] == SessionAffinity.userAgent && headers["mcp-session-id"] == "S1"
                && headers["mcp-protocol-version"] == "2025-06-18" && headers["authorization"] == nil
                && !headers.keys.contains { $0.contains("session-affinity") || $0.hasPrefix("x-opencode") || $0.hasPrefix("x-session") },
                "\(headers)")
        let first = hits.first
        c.check("P1.5 mapping: url→link, title, publish_date→date, excerpts joined with \" … \"",
                first?.link == "https://example.test/alpha-beta/0" && first?.title == "Result 0 for alpha beta"
                && first?.date == "2026-10-29" && first?.snippet == "first excerpt 0 … second excerpt 0" && hits[1].date == nil,
                "\(String(describing: first))")
        // Warm call: no re-initialize.
        _ = await search("gamma")
        c.check("P1.6 warm call reuses the transport session: one more tools/call only", fake.count("initialize") == 1 && fake.count("tools/call") == 2)

        // SSE with a preceding notification, a server request and a multi-line data field.
        await fresh(fake)
        let payload = FakeParallel.textResult(FakeParallel.defaultResults("sse", count: 2))
        let resultText = String(decoding: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 999999, "result": payload], options: [.sortedKeys]), as: UTF8.self)
            .replacingOccurrences(of: "999999", with: "$ID")
        // Split at a structural point: `{"id":$ID,` | the rest (a newline between JSON tokens is valid).
        let half = resultText.range(of: "\"jsonrpc\"")!.lowerBound
        let events = [": keepalive comment\n",
                      "event: message\nid: 1\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n",
                      "data: {\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"sampling/createMessage\",\"params\":{}}\n\n",
                      "data: " + String(resultText[..<half]) + "\ndata: " + String(resultText[half...]) + "\n\n"]
        // A JSON value split over two `data:` lines joins with "\n" — still valid JSON.
        fake.enqueue([.sse(events)])
        let r2 = await search("sse")
        let errorReplies = fake.requests.filter { $0.method == "<error-reply>" }
        c.check("P1.7 SSE: notification skipped, the response matched by id, multi-line data joined",
                ((try? r2.get()) ?? []).count == 2, "\(r2)")
        c.check("P1.8 a server request on the stream gets one JSON-RPC -32601 reply by POST (counted)",
                errorReplies.count == 1 && (errorReplies.first?.body["error"] as? [String: Any])?["code"] as? Int == -32601
                && ParallelSearchClient.rpcID(errorReplies.first?.body["id"]) == 77, "\(errorReplies.map(\.body))")

        // Multi-block content, structuredContent preferred.
        await fresh(fake)
        let decoyThenReal: [String: Any] = ["content": [["type": "text", "text": "Search complete."],
                                                        (FakeParallel.textResult(FakeParallel.defaultResults("blocks", count: 3))["content"] as! [[String: Any]])[0]]]
        fake.enqueue([.rawResult(decoyThenReal)])
        let r3 = await search("blocks")
        c.check("P1.9 multi-block content: a non-payload text block is ignored, the first payload block used", ((try? r3.get()) ?? []).count == 3, "\(r3)")
        let structured: [String: Any] = ["content": [["type": "text", "text": "{\"results\":[]}"]],
                                         "structuredContent": ["results": [["url": "https://example.test/s", "title": "Structured", "excerpts": ["x"]]]]]
        fake.enqueue([.rawResult(structured)])
        let r4 = await search("structured")
        c.check("P1.10 structuredContent preferred when present and decodable", ((try? r4.get()) ?? []).map(\.title) == ["Structured"], "\(r4)")
        fake.enqueue([.rawResult(["content": [["type": "text", "text": "no json here"]]])])
        let r5 = await search("garbage")
        if case .failure(let e as ParallelSearchError) = r5, case .badPayload = e { c.check("P1.11 undecodable payload → bad-payload error (no retry)", fake.count("tools/call") == 3) }
        else { c.check("P1.11 undecodable payload → bad-payload error (no retry)", false, "\(r5)") }

        // Stateless server: no Mcp-Session-Id at all.
        await fresh(fake)
        fake.stateful = false
        _ = await search("one"); _ = await search("two")
        let calls = fake.requests.filter { $0.method == "tools/call" }
        c.check("P1.12 stateless server: works, no Mcp-Session-Id sent, still one initialize",
                calls.count == 2 && calls.allSatisfy { $0.headers["mcp-session-id"] == nil } && fake.count("initialize") == 1)

        // Protocol version mismatch.
        await fresh(fake)
        fake.protocolVersion = "2099-01-01"
        let r6 = await search("version")
        if case .failure(let e as ParallelSearchError) = r6, case .protocolChanged = e {
            c.check("P1.13 an unsupported negotiated protocol version → \"free search protocol changed\", no tools/call", fake.count("tools/call") == 0 && (e.errorDescription ?? "").contains("protocol changed"))
        } else { c.check("P1.13 an unsupported negotiated protocol version → protocol-changed error", false, "\(r6)") }
        await fresh(fake)
        fake.protocolVersion = "2025-03-26"
        let r7 = await search("older")
        c.check("P1.14 2025-03-26 accepted; MCP-Protocol-Version carries the negotiated value", (try? r7.get()) != nil
                && fake.requests.last?.headers["mcp-protocol-version"] == "2025-03-26")

        // Body cap.
        await fresh(fake, limits: { var l = ParallelSearchClient.Limits(); l.bodyCap = 4096; return l }())
        fake.enqueue([.results(FakeParallel.defaultResults(String(repeating: "x", count: 400), count: 12))])
        let r8 = await search("big")
        if case .failure(let e as ParallelSearchError) = r8, case .badPayload(let d) = e { c.check("P1.15 a body over the cap is refused", d.contains("larger than")) }
        else { c.check("P1.15 a body over the cap is refused", false, "\(r8)") }
    }

    static func runParallelRetryGroup(_ c: Checker, fake: FakeParallel) async throws {
        print("P2. Parallel errors, retries and the request budget")
        // Expiry recovery: 404 on a request that carried Mcp-Session-Id.
        await fresh(fake)
        _ = await search("warm")
        fake.enqueue([.expire])
        let r1 = await search("after expiry")
        let methods = Array(fake.requests.map(\.method).dropFirst(3))
        c.check("P2.1 expiry (404 with Mcp-Session-Id) → one re-initialize, then the search succeeds on the new session",
                (try? r1.get()) != nil && methods == ["tools/call", "initialize", "notifications/initialized", "tools/call"]
                && fake.requests.last?.headers["mcp-session-id"] == "S2", "\(methods) \(r1)")
        // Recovery consumes the second attempt: expiry then 429 → fail, no third tools/call.
        await fresh(fake)
        _ = await search("warm")
        fake.enqueue([.expire, .status(429, headers: [:], body: "{}")])
        let before = fake.count("tools/call")
        let r2 = await search("expiry then limit")
        c.check("P2.2 a recovery consumes the second attempt: expiry + 429 → fails, exactly 2 tools/call (no third search)",
                (try? r2.get()) == nil && fake.count("tools/call") - before == 2, "\(r2)")
        // Generic 400 is not an expiry.
        await fresh(fake)
        fake.enqueue([.status(400, headers: [:], body: "{\"error\":\"bad\"}")])
        let r3 = await search("bad request")
        c.check("P2.3 a generic 400 is not treated as expiry: no re-initialize, no retry", (try? r3.get()) == nil && fake.count("initialize") == 1 && fake.count("tools/call") == 1)

        // JSON-RPC error: not retried.
        await fresh(fake)
        fake.enqueue([.rpcError(code: -32602, message: "Invalid params")])
        let r4 = await search("rpc")
        if case .failure(let e as ParallelSearchError) = r4, case .rpc = e { c.check("P2.4 JSON-RPC error → rpc error, not retried", fake.count("tools/call") == 1) }
        else { c.check("P2.4 JSON-RPC error → rpc error, not retried", false, "\(r4)") }
        // isError tool result.
        fake.enqueue([.rawResult(["isError": true, "content": [["type": "text", "text": "query rejected"]]])])
        let r5 = await search("tool error")
        if case .failure(let e as ParallelSearchError) = r5, case .tool(let d) = e { c.check("P2.5 result.isError → tool error with its text, not retried", d == "query rejected" && fake.count("tools/call") == 2) }
        else { c.check("P2.5 result.isError → tool error", false, "\(r5)") }
        // Rate limit under HTTP 200 (isError wording): retried once (backoff), then fails as rate limited.
        await fresh(fake, limits: { var l = ParallelSearchClient.Limits(); l.defaultBackoff = 0.05; return l }())
        fake.enqueue([.rawResult(["isError": true, "content": [["type": "text", "text": "Rate limit exceeded, slow down"]]]),
                      .rpcError(code: -32029, message: "quota")])
        let r6 = await search("limited 200")
        if case .failure(let e as ParallelSearchError) = r6, case .rateLimited = e {
            c.check("P2.6 rate limit inside HTTP 200 (isError wording, then code -32029) is classified as rate limit and retried once: 2 tools/call", fake.count("tools/call") == 2)
        } else { c.check("P2.6 rate limit inside HTTP 200 classified as rate limit", false, "\(r6)") }
        // 429 with a Retry-After longer than the deadline: fail at once, never early.
        await fresh(fake)
        fake.enqueue([.status(429, headers: ["Retry-After": "120"], body: "{}")])
        let t0 = Date()
        let r7 = await search("long retry-after")
        c.check("P2.7 429 with Retry-After 120 s (past the 45 s deadline) → fails immediately, one tools/call, no early retry",
                (try? r7.get()) == nil && fake.count("tools/call") == 1 && Date().timeIntervalSince(t0) < 5, "\(Date().timeIntervalSince(t0))s")
        // 429 with a short Retry-After: waits at least that long, then succeeds.
        await fresh(fake)
        fake.enqueue([.status(429, headers: ["Retry-After": "1"], body: "{}")])
        let t1 = Date()
        let r8 = await search("short retry-after")
        let waited = Date().timeIntervalSince(t1)
        c.check("P2.8 429 with Retry-After 1 s → retried no earlier than 1 s, then succeeds (2 tools/call)",
                (try? r8.get()) != nil && fake.count("tools/call") == 2 && waited >= 1.0, "\(waited)s \(r8)")
        // Total attempt cap: 500 twice → exactly 2.
        await fresh(fake, limits: { var l = ParallelSearchClient.Limits(); l.defaultBackoff = 0.05; return l }())
        fake.enqueue([.status(500, headers: [:], body: "{}"), .status(502, headers: [:], body: "{}"), .results(FakeParallel.defaultResults("never"))])
        let r9 = await search("server errors")
        c.check("P2.9 at most 2 search attempts: 500, 502 → fails; the third scripted reply is never requested",
                (try? r9.get()) == nil && fake.count("tools/call") == 2, "\(r9)")
        // Request budget: an initialize that fails consumes, the total HTTP count stays within 8.
        let counters = await ParallelSearchClient.shared.counters
        c.check("P2.10 request accounting: initialize + initialized + 2 searches = 4 HTTP requests (≤ 8)", counters.httpRequests == 4, "\(counters)")
        // Total deadline covers waiting.
        await fresh(fake, limits: { var l = ParallelSearchClient.Limits(); l.totalDeadline = 1.5; l.perRequestTimeout = 1; return l }())
        fake.enqueue([.delayed(3, .init(.results(FakeParallel.defaultResults("slow"))))])
        let t2 = Date()
        let r10 = await search("slow")
        c.check("P2.11 the total deadline bounds a slow call (1.5 s budget, server takes 3 s)", (try? r10.get()) == nil && Date().timeIntervalSince(t2) < 3, "\(Date().timeIntervalSince(t2))s")

        // Stale-generation failure never clobbers a newer session.
        await fresh(fake)
        _ = await search("warm")   // session S1
        // Both calls hit S1; A's expiry answers at once, B's 404 only after A re-initialized (S2).
        fake.setPerSession(["S1": [.expire, .delayed(1.0, .init(.status(404, headers: [:], body: "{}")))]])
        async let a = search("call A")
        try await Task.sleep(nanoseconds: 100_000_000)
        async let b = search("call B")
        let (ra, rb) = await (a, b)
        let session = await ParallelSearchClient.shared.sessionForTesting()
        c.check("P2.12 a late 404 from the OLD session (call B) does not drop the newer session call A established: 2 initializes in total, both calls succeed on S2",
                (try? ra.get()) != nil && (try? rb.get()) != nil && fake.count("initialize") == 2 && session?.mcpSessionID == "S2",
                "A \(ra) B \(rb) inits \(fake.count("initialize")) session \(String(describing: session?.mcpSessionID))")
    }

    static func runParallelBreakerGroup(_ c: Checker, fake: FakeParallel) async throws {
        print("P3. Parallel breaker, concurrency, cancellation")
        let clock = MutableClock()
        let limits: ParallelSearchClient.Limits = { var l = ParallelSearchClient.Limits(); l.defaultBackoff = 0.01; return l }()
        await fresh(fake, limits: limits, clock: { clock.now })
        HealthProbe.clear()
        for _ in 0..<3 { fake.enqueue([.status(503, headers: [:], body: "{}"), .status(503, headers: [:], body: "{}")]) }
        for index in 0..<3 { _ = await search("fail \(index)") }
        let state = await ParallelSearchClient.shared.breakerStateForTesting()
        if case .open = state { c.check("P3.1 3 consecutive server-failure calls open the breaker", true) } else { c.check("P3.1 breaker opens after 3", false, "\(state)") }
        let before = fake.requests.count
        let busy = await search("while open")
        if case .failure(let e as ParallelSearchError) = busy, e == .busy {
            c.check("P3.2 open breaker: the call fails at once with the busy text, zero HTTP requests",
                    fake.requests.count == before && (e.errorDescription ?? "").contains("Free search is busy right now (Parallel)"))
        } else { c.check("P3.2 open breaker fails fast", false, "\(busy)") }
        // Half-open after 5 minutes: exactly one probe; a concurrent call fails fast.
        clock.advance(301)
        fake.defaultDelay = 0.5
        async let probe = search("probe")
        try await Task.sleep(nanoseconds: 150_000_000)
        let concurrent = await search("during probe")
        let probeResult = await probe
        fake.defaultDelay = 0
        var concurrentBusy = false
        if case .failure(let e as ParallelSearchError) = concurrent, e == .busy { concurrentBusy = true }
        let closed = await ParallelSearchClient.shared.breakerStateForTesting()
        c.check("P3.3 half-open: exactly one probe goes out, a concurrent call fails fast; the probe's success closes the breaker",
                (try? probeResult.get()) != nil && concurrentBusy && closed == .closed, "\(probeResult) \(concurrent) \(closed)")
        // A failing probe re-opens.
        for _ in 0..<3 { fake.enqueue([.status(500, headers: [:], body: "{}"), .status(500, headers: [:], body: "{}")]) }
        for index in 0..<3 { _ = await search("fail again \(index)") }
        clock.advance(301)
        fake.enqueue([.status(429, headers: [:], body: "{}"), .status(429, headers: [:], body: "{}")])
        _ = await search("failing probe")
        let reopened = await ParallelSearchClient.shared.breakerStateForTesting()
        if case .open = reopened { c.check("P3.4 a failing half-open probe re-opens the breaker", true) } else { c.check("P3.4 failing probe re-opens", false, "\(reopened)") }
        // Non-counting failures (bad payload) never open it.
        await fresh(fake, limits: limits, clock: { clock.now })
        for _ in 0..<4 { fake.enqueue([.rawResult(["content": [["type": "text", "text": "junk"]]])]) }
        for index in 0..<4 { _ = await search("junk \(index)") }
        let junkState = await ParallelSearchClient.shared.breakerStateForTesting()
        c.check("P3.5 failures other than rate limit / server errors never open the breaker", junkState == .closed)

        // Concurrency cap: 4 in flight per process.
        await fresh(fake)
        _ = await search("warm")
        fake.defaultDelay = 0.4
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<9 { group.addTask { _ = await search("parallel \(index)") } }
        }
        fake.defaultDelay = 0
        let maxSeen = fake.observedMaxInFlight
        let clientMax = await ParallelSearchClient.shared.counters.maxObservedInFlight
        c.check("P3.6 at most 4 Parallel calls in flight at once (9 concurrent callers): server saw ≤ 4, client ≤ 4, all 10 searches sent",
                maxSeen <= 4 && maxSeen >= 2 && clientMax <= 4 && fake.count("tools/call") == 10, "server \(maxSeen) client \(clientMax) calls \(fake.count("tools/call"))")

        // Cancellation: never health, never breaker.
        await fresh(fake, limits: limits, clock: { clock.now })
        HealthProbe.clear()
        fake.enqueue([.delayed(2, .init(.results(FakeParallel.defaultResults("cancel"))))])
        let task = Task { await search("to cancel") }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let cancelled = await task.value
        var isCancel = false
        if case .failure(let e) = cancelled, e is CancellationError { isCancel = true }
        let afterCancel = await ParallelSearchClient.shared.breakerStateForTesting()
        c.check("P3.7 a cancelled call throws CancellationError, leaves the breaker closed and records no failure streak",
                isCancel && afterCancel == .closed, "\(cancelled)")
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}
