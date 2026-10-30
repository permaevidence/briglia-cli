import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keyless web backends (KEYLESS_WEB_AND_LIVE_MENU_PLAN A.10): the Parallel
/// keyless search client, the conversation search ID, keyless Jina, the
/// search-service resolution matrix and the shared executor configuration.
/// Hermetic: loopback fakes (Parallel MCP at /mcp, Jina reader, Serper),
/// isolated XDG roots, injected clocks. `--live` instead sends ONE real
/// keyless Parallel search and ONE keyless Jina read (free services, no key;
/// a gentle manual check, never in smoke).
///
/// Split over several files and functions (one group each) so no single
/// function grows past what the Linux CI frontend compiles in 7 GiB.
struct WebBackendSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__web-backend-selftest",
        abstract: "Internal: verify keyless web search (Parallel), the search session ID, keyless Jina and the search-service switch.",
        shouldDisplay: false
    )

    @Flag(name: .customLong("live"), help: "Send one real keyless Parallel search and one keyless Jina read instead (no key, free).")
    var live = false

    @Option(name: .customLong("mint-session-at"), help: .hidden)
    var mintSessionAt: String?

    struct Failure: Error, CustomStringConvertible { let description: String }

    final class Checker: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var total = 0
        private(set) var failures = 0
        func check(_ name: String, _ value: Bool, _ detail: @autoclosure () -> String = "") {
            lock.lock(); total += 1; if !value { failures += 1 }; lock.unlock()
            let extra = value ? "" : detail()
            print("\(value ? "✔" : "✖") \(name)\(extra.isEmpty ? "" : " — \(String(extra.prefix(700)))")")
        }
    }

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else { throw ValidationError("Needs a development build") }
        if let path = mintSessionAt {
            // Child of the cross-process mint race (S.17): one idForSearch on
            // the given file, the ID on stdout.
            ParallelSessionStore.fileURLOverrideForTesting = URL(fileURLWithPath: path)
            print((try? ParallelSessionStore.idForSearch()) ?? "ERROR")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-webbackend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, child) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(name, root.appendingPathComponent(child).path, 1)
        }
        unsetenv(KeylessSearchSwitch.environmentKey)
        UserDefaults.standard.setVolatileDomain([KeychainHelper.serviceKeysMetadataDefaultsKey: Data("[]".utf8)],
                                                forName: UserDefaults.argumentDomain)
        ParallelSessionStore.fileURLOverrideForTesting = root.appendingPathComponent("search-session.json")
        defer { ParallelSessionStore.fileURLOverrideForTesting = nil }

        if live { try await Self.runLive(); return }

        let c = Checker()
        let parallel = try WebFixtureServer()
        let reader = try WebFixtureServer()
        defer { parallel.stop(); reader.stop() }
        setenv("BRIGLIA_DEV_PARALLEL_BASE", "http://127.0.0.1:\(parallel.port)", 1)
        setenv("BRIGLIA_DEV_SERPER_BASE", "http://127.0.0.1:\(reader.port)", 1)
        setenv("BRIGLIA_DEV_JINA_READER_BASE", "http://127.0.0.1:\(reader.port)/reader/", 1)
        let fake = FakeParallel()
        parallel.route = { fake.handle($0) }
        HealthProbe.install()
        defer { ToolServiceHealth.reportHookForTesting = nil }

        try await Self.runParallelTransportGroup(c, fake: fake)
        try await Self.runParallelRetryGroup(c, fake: fake)
        try await Self.runParallelBreakerGroup(c, fake: fake)
        try await Self.runInitializeCancellationGroup(c, fake: fake)
        try await Self.runSessionGroup(c, fake: fake, root: root)
        try await Self.runSessionDurabilityGroup(c, root: root)
        try await Self.runJinaGroup(c, reader: reader)
        try await Self.runResolutionGroup(c, fake: fake, reader: reader)
        try await Self.runExecutorGroup(c, fake: fake, reader: reader)

        await ParallelSearchClient.shared.installForTesting(send: nil)
        print("Web backend selftest: \(c.total - c.failures)/\(c.total) passed")
        if c.failures > 0 { throw ExitCode.failure }
    }

    /// One real keyless search and one keyless page read. Small and gentle:
    /// two HTTP exchanges with Parallel (plus initialize) and one with Jina.
    static func runLive() async throws {
        let session = try ParallelSessionStore.idForSearch()
        let started = Date()
        let hits = try await ParallelSearchClient.shared.search(query: "Briglia keyless search check: Rome weather today", sessionID: session, depth: 5)
        print("parallel live: \(hits.count) results in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        for hit in hits.prefix(3) { print("  · \(hit.title.prefix(70)) — \(hit.link) \(hit.date ?? "")") }
        let counters = await ParallelSearchClient.shared.counters
        print("  http requests: \(counters.httpRequests), initializes: \(counters.initializes), searches: \(counters.searchCalls)")
        let orchestrator = WebOrchestrator()
        await orchestrator.configure(openRouterKey: "", serperKey: "", jinaKey: "")
        let readStarted = Date()
        // The reader fetch only (no model call): free.
        let page = try await orchestrator.fetchWithJinaReader(originalURL: "https://en.wikipedia.org/wiki/Rome", includeImageCaptions: true)
        print("jina keyless live: \(page.content.count) chars, title \(page.title ?? "-") in \(String(format: "%.1f", Date().timeIntervalSince(readStarted))) s")
        guard !hits.isEmpty else { throw Failure(description: "no Parallel results") }
    }
}

// MARK: - Health observation seam

enum HealthProbe {
    struct Event: Equatable { let subsystem: String; let success: Bool; let deterministic: Bool }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _events: [Event] = []
    static var events: [Event] { lock.lock(); defer { lock.unlock() }; return _events }
    static func clear() { lock.lock(); _events = []; lock.unlock() }
    static func install() {
        ToolServiceHealth.reportHookForTesting = { subsystem, success, deterministic in
            lock.lock(); _events.append(Event(subsystem: subsystem.rawValue, success: success, deterministic: deterministic)); lock.unlock()
        }
    }
    static func events(_ subsystem: MaintenanceAlertCenter.Subsystem) -> [Event] { events.filter { $0.subsystem == subsystem.rawValue } }
}

// MARK: - Fake Parallel MCP server

/// Speaks just enough MCP Streamable HTTP for the client: initialize (with
/// or without `Mcp-Session-Id`), notifications/initialized (202), tools/call
/// `web_search` answered from a script (JSON or SSE), expiry by 404.
final class FakeParallel: @unchecked Sendable {
    enum Reply {
        case results([(url: String, title: String, date: String?, excerpts: [String])])
        case rawResult([String: Any])
        case rpcError(code: Int, message: String)
        case status(Int, headers: [String: String], body: String)
        /// The current session is forgotten and this call gets 404.
        case expire
        case sse([String])
        case delayed(TimeInterval, Box)
        /// An SSE stream that first sends a server REQUEST (id), and sends the
        /// search result only after the client's error reply to it arrived.
        case sseAwaitingReply(requestID: Int)
        /// Holds the answer until `count` tools/call requests carrying
        /// `session` have arrived (an interleaving barrier).
        case afterSeen(session: String, count: Int, Box)
    }
    final class Box { let reply: Reply; init(_ r: Reply) { reply = r } }

    struct Seen { let method: String; let headers: [String: String]; let body: [String: Any] }

    private let lock = NSLock()
    var stateful = true
    var protocolVersion = "2025-06-18"
    var initStatus: Int? = nil
    /// initialize answers over SSE with a server request first and waits
    /// for the client's error reply before the initialize result.
    var initServerRequest: Int? = nil
    private var sessionCounter = 0
    private var validSessions: Set<String> = []
    private var acceptedReplies: [Int] = []
    private var script: [Reply] = []
    private var seen: [Seen] = []
    private var inFlight = 0
    private var maxInFlight = 0
    var defaultDelay: TimeInterval = 0
    /// Route tools/call by the session header (stale-generation test).
    var perSession: [String: [Reply]] = [:]

    func reset() {
        lock.lock(); defer { lock.unlock() }
        stateful = true; protocolVersion = "2025-06-18"; initStatus = nil; initServerRequest = nil
        sessionCounter = 0; validSessions = []; acceptedReplies = []; script = []; seen = []; inFlight = 0; maxInFlight = 0; defaultDelay = 0; perSession = [:]
    }
    func enqueue(_ replies: [Reply]) { lock.lock(); script.append(contentsOf: replies); lock.unlock() }
    func setPerSession(_ map: [String: [Reply]]) { lock.lock(); perSession = map; lock.unlock() }
    var requests: [Seen] { lock.lock(); defer { lock.unlock() }; return seen }
    var observedMaxInFlight: Int { lock.lock(); defer { lock.unlock() }; return maxInFlight }
    func count(_ method: String) -> Int { requests.filter { $0.method == method }.count }

    static func defaultResults(_ query: String, count: Int = 12) -> [(url: String, title: String, date: String?, excerpts: [String])] {
        (0..<count).map { ("https://example.test/\(query.replacingOccurrences(of: " ", with: "-"))/\($0)", "Result \($0) for \(query)", $0 == 0 ? "2026-10-29" : nil, ["first excerpt \($0)", "second excerpt \($0)"]) }
    }

    static func textResult(_ results: [(url: String, title: String, date: String?, excerpts: [String])]) -> [String: Any] {
        let items: [[String: Any]] = results.map {
            var d: [String: Any] = ["url": $0.url, "title": $0.title, "excerpts": $0.excerpts]
            if let date = $0.date { d["publish_date"] = date }
            return d
        }
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["search_id": "s1", "results": items], options: [.sortedKeys]), as: UTF8.self)
        return ["content": [["type": "text", "text": text]]]
    }

    private func json(_ object: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }

    func handle(_ request: WebFixtureServer.Request) -> WebFixtureServer.Response {
        let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
        let method = body["method"] as? String ?? (body["error"] != nil ? "<error-reply>" : "<other>")
        lock.lock()
        seen.append(Seen(method: method, headers: request.headers, body: body))
        lock.unlock()
        let id = body["id"]
        switch method {
        case "initialize":
            if let status = initStatus { return .init(status: status, body: "{\"error\":\"injected\"}") }
            lock.lock()
            var headers: [String: String] = [:]
            if stateful {
                sessionCounter += 1
                let sid = "S\(sessionCounter)"
                validSessions.insert(sid)
                headers["Mcp-Session-Id"] = sid
            }
            let version = protocolVersion
            let initRequest = initServerRequest
            lock.unlock()
            let result = json(["jsonrpc": "2.0", "id": id ?? 0, "result": ["protocolVersion": version, "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "fake-parallel", "version": "1"]]])
            if let rid = initRequest {
                var response = WebFixtureServer.Response(contentType: "text/event-stream", body: "", headers: headers)
                response.chunks = [("data: {\"id\":\(rid),\"jsonrpc\":\"2.0\",\"method\":\"roots/list\"}\n\n", nil),
                                   ("data: " + result + "\n\n", { [weak self] in self?.sawErrorReply(rid) ?? true })]
                return response
            }
            return .init(body: result, headers: headers)
        case "notifications/initialized":
            return .init(status: 202, contentType: "application/json", body: "")
        case "<error-reply>":
            // A stateful server enforces the session it assigned on EVERY
            // later request, replies included (also during initialize).
            lock.lock()
            let sid = request.headers["mcp-session-id"]
            let accepted = !stateful || (sid != nil && validSessions.contains(sid!))
            if accepted, let rid = ParallelSearchClient.rpcID(body["id"]) { acceptedReplies.append(rid) }
            lock.unlock()
            return accepted ? .init(status: 202, contentType: "application/json", body: "") : .init(status: 400, body: "{\"error\":\"missing session\"}")
        case "tools/call":
            let sid = request.headers["mcp-session-id"]
            lock.lock()
            if stateful, sid == nil || !validSessions.contains(sid!) {
                lock.unlock()
                return .init(status: 404, body: "{\"error\":\"unknown session\"}")
            }
            var reply: Reply? = nil
            if let sid, var queue = perSession[sid], !queue.isEmpty {
                reply = queue.removeFirst(); perSession[sid] = queue
            } else if !script.isEmpty { reply = script.removeFirst() }
            inFlight += 1; maxInFlight = max(maxInFlight, inFlight)
            let delay = defaultDelay
            lock.unlock()
            defer { lock.lock(); inFlight -= 1; lock.unlock() }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let query = ((body["params"] as? [String: Any])?["arguments"] as? [String: Any])?["objective"] as? String ?? "q"
            return respond(reply ?? .results(Self.defaultResults(query)), id: id, sid: sid)
        default:
            return .init(status: 400, body: "{\"error\":\"unexpected \(method)\"}")
        }
    }

    /// An error reply for `rid` that the server ACCEPTED (session enforced).
    func sawErrorReply(_ rid: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return acceptedReplies.contains(rid)
    }

    func toolCallCount(session: String) -> Int {
        requests.filter { $0.method == "tools/call" && $0.headers["mcp-session-id"] == session }.count
    }

    private func respond(_ reply: Reply, id: Any?, sid: String?) -> WebFixtureServer.Response {
        switch reply {
        case .sseAwaitingReply(let rid):
            let query = "awaited"
            let result = json(["jsonrpc": "2.0", "id": id ?? 0, "result": Self.textResult(Self.defaultResults(query, count: 2))])
            var response = WebFixtureServer.Response(contentType: "text/event-stream", body: "")
            response.chunks = [("data: {\"id\":\(rid),\"jsonrpc\":\"2.0\",\"method\":\"sampling/createMessage\",\"params\":{}}\n\n", nil),
                               ("data: " + result + "\n\n", { [weak self] in self?.sawErrorReply(rid) ?? true })]
            return response
        case .afterSeen(let session, let count, let box):
            let end = Date().addingTimeInterval(10)
            while toolCallCount(session: session) < count && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            return respond(box.reply, id: id, sid: sid)
        case .results(let results): return .init(body: json(["jsonrpc": "2.0", "id": id ?? 0, "result": Self.textResult(results)]))
        case .rawResult(let result): return .init(body: json(["jsonrpc": "2.0", "id": id ?? 0, "result": result]))
        case .rpcError(let code, let message): return .init(body: json(["jsonrpc": "2.0", "id": id ?? 0, "error": ["code": code, "message": message]]))
        case .status(let code, let headers, let body): return .init(status: code, body: body, headers: headers)
        case .expire:
            lock.lock(); if let sid { validSessions.remove(sid) }; lock.unlock()
            return .init(status: 404, body: "{\"error\":\"session expired\"}")
        case .sse(let events):
            let idText = (id as? Int).map(String.init) ?? "0"
            let text = events.map { $0.replacingOccurrences(of: "$ID", with: idText) }.joined()
            return .init(contentType: "text/event-stream", body: text)
        case .delayed(let seconds, let box):
            Thread.sleep(forTimeInterval: seconds)
            return respond(box.reply, id: id, sid: sid)
        }
    }
}
