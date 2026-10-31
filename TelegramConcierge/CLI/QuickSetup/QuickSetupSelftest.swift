import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `briglia __quicksetup-selftest` — the offline battery of plan §8 (no
/// browser, no network). Isolation: XDG roots and TMPDIR point at a temp
/// directory before anything touches KeychainHelper/StoragePaths, and every
/// side effect of the workflow goes through `QuickSetupEnvironment` stubs.
///
/// Hidden subprocess modes (used by the crash and lock tests):
///   --agentmail-crash <point> --dir <install dir> --fixture <archive> --sums <checksums>
///   --agentmail-install --dir … --fixture … --sums … [--hold-seconds N]
///   --job-then-die   (runs one job and SIGKILLs itself once the journal is durable)
struct QuickSetupSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__quicksetup-selftest",
        abstract: "Internal: verify the terminal quick setup and the local pages\u{2019} server, authorization, runner and lease.",
        shouldDisplay: false
    )

    @Option(name: .customLong("agentmail-crash")) var agentmailCrash: String?
    @Flag(name: .customLong("agentmail-install")) var agentmailInstall = false
    @Option(name: .customLong("dir")) var dir: String?
    @Option(name: .customLong("fixture")) var fixture: String?
    @Option(name: .customLong("sums")) var sums: String?
    @Option(name: .customLong("hold-seconds")) var holdSeconds: Double = 0
    @Flag(name: .customLong("job-then-die")) var jobThenDie = false
    @Option(name: .customLong("only")) var only: String?

    func run() async throws {
        if jobThenDie { try await SelftestSubprocess.jobThenDie(); return }
        if agentmailCrash != nil || agentmailInstall {
            print("the AgentMail installer battery moved to `briglia __private-runtime-selftest`")
            throw ExitCode(64)
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("briglia-qs-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_CONFIG_HOME", tempRoot.path, 1)
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path + "/", 1)
        setenv("BRIGLIA_IGNORE_LEGACY_SETUP_FLAG", "1", 1)
        StoragePaths.ensureRoots()
        InstanceLease.assertOnUnexpectedDrop = false

        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 420_000_000_000)
            if !Task.isCancelled {
                print("WATCHDOG: quicksetup selftest exceeded 420s — hung; aborting")
                Foundation.exit(3)
            }
        }
        defer { watchdog.cancel() }

        let t = SelftestContext(tempRoot: tempRoot, only: only)
        await t.section("1. parser") { try await t.parser() }
        await t.section("2. server, authorization, generations") { try await t.serverAndGenerations() }
        await t.section("3c. browser settings") { try await t.browserSettings(); try await t.browserSettingsShutdown(); try await t.browserSettingsSignals() }
        await t.section("8. job runner") { try await t.runner() }
        await t.section("9. static pages") { try await t.staticPage() }
        await t.section("13/15. lease, completion delivery") { try await t.finishAndLease() }
        await t.section("14. keep-awake census") { try await t.census() }
        await t.section("16. package maps + disk floors") { try await t.packagesAndDisk() }
        await t.section("2c. AgentMail pinned release") { try await t.agentMailPinning() }
        await t.section("17. service start (socket wait)") { try await t.serviceStart() }
        await t.section("18. python venv package in the menu's apt job") { try await t.venvAptJob() }
        await t.section("19. terminal quick setup") { try await t.terminalQuickSetup() }

        print(t.failures == 0 ? "\nquicksetup selftest: all \(t.checks) checks passed"
                              : "\nquicksetup selftest: \(t.failures) of \(t.checks) FAILED")
        if t.failures > 0 { throw ExitCode(1) }
    }
}

// MARK: - Harness

final class SelftestContext: @unchecked Sendable {
    let tempRoot: URL
    let only: String?
    var checks = 0
    var failures = 0

    init(tempRoot: URL, only: String?) {
        self.tempRoot = tempRoot
        self.only = only
    }

    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        checks += 1
        print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    func section(_ title: String, _ body: () async throws -> Void) async {
        if let only, !title.contains(only) { return }
        print("\n── \(title)")
        do { try await body() } catch {
            checks += 1
            failures += 1
            print("✖ section threw: \(error)")
        }
    }

    var selfPath: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    }

    func tempDir(_ name: String) -> URL {
        let url = tempRoot.appendingPathComponent(name + "-" + UUID().uuidString.prefix(8))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stubbed environment: no network, no system mutation.
    // MARK: 1. Parser

    func parser() async throws {
        typealias S = QuickSetupHTTPServer
        func parse(_ text: String) -> Result<S.Request, S.ParseFailure> { S.parseHead(Array(text.utf8)) }
        func status(_ text: String) -> Int {
            switch parse(text) { case .success: return 200; case .failure(let f): return f.status }
        }
        let good = "GET /api/status HTTP/1.1\r\nHost: 127.0.0.1:1\r\nCookie: bqs=abc"
        check("valid GET parses", status(good) == 200)
        if case .success(let r) = parse(good) { check("cookie bqs extracted", r.cookieBQS == "abc") }
        check("duplicate Host → 400", status("GET / HTTP/1.1\r\nHost: a\r\nHost: b") == 400)
        check("missing Host → 400", status("GET / HTTP/1.1\r\nX: y") == 400)
        check("duplicate Content-Length → 400", status("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 1") == 400)
        check("signed Content-Length → 400", status("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: +5") == 400)
        check("list Content-Length → 400", status("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5, 5") == 400)
        check("non-digit Content-Length → 400", status("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5x") == 400)
        check("Transfer-Encoding chunked → 400", status("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked") == 400)
        check("Transfer-Encoding identity → 400", status("POST / HTTP/1.1\r\nHost: a\r\ntransfer-encoding: identity") == 400)
        check("Transfer-Encoding mixed case → 400", status("POST / HTTP/1.1\r\nHost: a\r\nTrAnSfEr-EnCoDiNg: gzip") == 400)
        check("obs-fold → 400", status("GET / HTTP/1.1\r\nHost: a\r\nX-A: 1\r\n continued") == 400)
        check("CR in header value → 400", status("GET / HTTP/1.1\r\nHost: a\r\nX-A: 1\rbad") == 400)
        check("NUL in header value → 400", status("GET / HTTP/1.1\r\nHost: a\r\nX-A: 1\u{0}bad") == 400)
        check("control byte in header value → 400", status("GET / HTTP/1.1\r\nHost: a\r\nX-A: 1\u{1}bad") == 400)
        check("absolute-form target → 400", status("GET http://127.0.0.1:1/ HTTP/1.1\r\nHost: 127.0.0.1:1") == 400)
        check("authority-form target → 400", status("GET 127.0.0.1:1 HTTP/1.1\r\nHost: a") == 400)
        check("asterisk-form target → 400", status("OPTIONS * HTTP/1.1\r\nHost: a") == 400)
        check(".. in path → 400", status("GET /api/../x HTTP/1.1\r\nHost: a") == 400)
        check("%-encoded path → 400", status("GET /api/%61 HTTP/1.1\r\nHost: a") == 400)
        check("HTTP/1.0 → 400", status("GET / HTTP/1.0\r\nHost: a") == 400)
        check("HTTP/2 preface → 400", status("PRI * HTTP/2.0\r\n") == 400)
        check("PUT → 405", status("PUT / HTTP/1.1\r\nHost: a") == 405)
        check("GET with Content-Length: 5 → 400", status("GET / HTTP/1.1\r\nHost: a\r\nContent-Length: 5") == 400)
        check("body over 64 KiB → 413", status("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 65537") == 413)
        check("request line over 2 KiB → 400", status("GET /" + String(repeating: "a", count: 2100) + " HTTP/1.1\r\nHost: a") == 400)
        let manyHeaders = (0..<65).map { "X-\($0): 1" }.joined(separator: "\r\n")
        check("65 header lines → 400", status("GET / HTTP/1.1\r\nHost: a\r\n" + manyHeaders) == 400)
        check("duplicate bqs cookie treated as absent", { if case .success(let r) = parse("GET / HTTP/1.1\r\nHost: a\r\nCookie: bqs=a; bqs=b") { return r.cookieBQS == nil }; return false }())
        let tok = String(repeating: "ab", count: 16)
        check("start token: valid", S.startToken(fromQuery: "t=\(tok)") == tok)
        check("start token: two t → nil", S.startToken(fromQuery: "t=\(tok)&t=\(tok)") == nil)
        check("start token: empty → nil", S.startToken(fromQuery: "t=") == nil)
        check("start token: 31 hex → nil", S.startToken(fromQuery: "t=\(tok.dropLast())") == nil)
        check("start token: uppercase → nil", S.startToken(fromQuery: "t=\(tok.uppercased())") == nil)
        check("start token: extra parameter → nil", S.startToken(fromQuery: "t=\(tok)&x=1") == nil)
        check("start token: absent → nil", S.startToken(fromQuery: nil) == nil)
    }

    // MARK: 2. Server, authorization, generations

    /// Raw HTTP client on a fresh socket per request.
    func rawRequest(port: UInt16, _ text: String, body: Data = Data(), readTimeout: Int32 = 5000) -> (status: Int, headers: [String: String], body: Data)? {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { return nil }
        var payload = Data(text.utf8)
        payload.append(body)
        QuickSetupHTTPServer.writeAll(fd, payload)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(TimeInterval(readTimeout) / 1000)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 200)
            if r <= 0 { continue }
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        guard let sep = out.range(of: Data("\r\n\r\n".utf8)), let head = String(data: out[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "0") ?? 0
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { if let c = l.firstIndex(of: ":") { headers[String(l[..<c]).lowercased()] = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces) } }
        return (status, headers, Data(out[sep.upperBound...]))
    }

    func request(port: UInt16, method: String, path: String, cookie: String? = nil, json: [String: Any]? = nil,
                 host: String? = nil, origin: String? = nil, extra: [String: String] = [:], customHeader: Bool = true) -> (status: Int, headers: [String: String], json: [String: Any]) {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port)")"]
        var body = Data()
        if method == "POST" {
            body = (try? JSONSerialization.data(withJSONObject: json ?? [:])) ?? Data()
            lines.append("Origin: \(origin ?? "http://127.0.0.1:\(port)")")
            lines.append("Content-Type: application/json")
            if customHeader { lines.append("X-Briglia-Quick-Setup: 1") }
            lines.append("Content-Length: \(body.count)")
        }
        if let cookie { lines.append("Cookie: bqs=\(cookie)") }
        for (k, v) in extra { lines.append("\(k): \(v)") }
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n"
        guard let r = rawRequest(port: port, text, body: body) else { return (0, [:], [:]) }
        let js = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        return (r.status, r.headers, js)
    }

    /// The page server with browser settings attached (the router serves a
    /// page only with the menu or settings attached since 0.2.67).
    func startServer(_ wf: PageAuthorizer) async throws -> (QuickSetupHTTPServer, QuickSetupRouter) {
        let pageDir = QuickSetupPreflight.pageDirectory() ?? tempDir("page")
        let portBox = QuickSetupSession.PortBox()
        let router = QuickSetupRouter(workflow: wf, pageDirectory: pageDir) { portBox.port }
        router.settings = await MainActor.run { BrowserSettingsWorkflow(auth: wf) }
        let server = QuickSetupHTTPServer { await router.handle($0) }
        try server.start()
        portBox.port = server.port
        return (server, router)
    }

    func exchange(port: UInt16, token: String) -> (status: Int, cookie: String?, setCookie: String) {
        let r = request(port: port, method: "GET", path: "/start?t=\(token)")
        let sc = r.headers["set-cookie"] ?? ""
        var cookie: String?
        if let range = sc.range(of: "bqs=") { cookie = String(sc[range.upperBound...].prefix(32)) }
        return (r.status, cookie, sc)
    }

    func serverAndGenerations() async throws {
        let wf = try PageAuthorizer(runner: SetupJobRunner())
        let (server, _) = try await startServer(wf)
        defer { server.stop() }
        let port = server.port
        check("bound to an ephemeral port", port > 0)
        let token = await wf.launchToken
        var ex = exchange(port: port, token: "0000000000000000000000000000000f")
        check("wrong token → 404, empty body", ex.status == 404)
        ex = exchange(port: port, token: token)
        check("token exchange → 303 + HttpOnly SameSite=Strict cookie", ex.status == 303 && ex.cookie != nil && ex.setCookie.contains("HttpOnly") && ex.setCookie.contains("SameSite=Strict"))
        let cookie = ex.cookie ?? ""
        check("second exchange → 404", exchange(port: port, token: token).status == 404)
        check("consumed-by-other flagged when the used token is replayed", await wf.consumedByOther)
        var r = request(port: port, method: "GET", path: "/api/status")
        check("no cookie → 404", r.status == 404)
        r = request(port: port, method: "GET", path: "/api/status", cookie: cookie)
        check("status with cookie → 200 (the attached settings page answers)", r.status == 200)
        check("ordinary/unauthorized responses do not signal completion", !server.hasDeliveredCompletion)
        check("§5.7 headers on every response", (r.headers["content-security-policy"] ?? "").hasPrefix("default-src 'none'") && r.headers["x-content-type-options"] == "nosniff" && r.headers["cache-control"] == "no-store" && r.headers["x-frame-options"] == "DENY" && r.headers["referrer-policy"] == "no-referrer" && r.headers["connection"] == "close")
        r = request(port: port, method: "GET", path: "/api/status", cookie: cookie, host: "localhost:\(port)")
        check("wrong Host → 400", r.status == 400)
        r = request(port: port, method: "POST", path: "/api/verify", cookie: cookie, json: [:], origin: "http://evil.example")
        check("foreign Origin → 403", r.status == 403)
        r = request(port: port, method: "POST", path: "/api/verify", cookie: cookie, json: [:], customHeader: false)
        check("missing X-Briglia-Quick-Setup → 403", r.status == 403)
        r = request(port: port, method: "GET", path: "/api/status", cookie: cookie, extra: ["Sec-Fetch-Site": "cross-site"])
        check("Sec-Fetch-Site cross-site → 403", r.status == 403)
        let opt = rawRequest(port: port, "OPTIONS /api/verify HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        check("OPTIONS → 403 without CORS headers", opt?.status == 403 && opt?.headers["access-control-allow-origin"] == nil)
        let big = rawRequest(port: port, "POST /api/verify HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 70000\r\n\r\n")
        check("oversized body → 413", big?.status == 413)
        r = request(port: port, method: "GET", path: "/api/status?x=1", cookie: cookie)
        check("query on a non-start route → 400", r.status == 400)
        r = request(port: port, method: "GET", path: "/", cookie: cookie)
        check("page served with the cookie", r.status == 200)
        check("page needs the cookie too", request(port: port, method: "GET", path: "/").status == 404)

        // Header deadline closes the socket.
        QuickSetupHTTPServer.headerDeadline = 0.5
        let slow = rawRequest(port: port, "GET /api/status HTTP/1.1\r\nHost: x", readTimeout: 2500)
        QuickSetupHTTPServer.headerDeadline = 10
        check("header deadline closes an incomplete request", slow == nil)

        // 17th connection → 503.
        var held: [Int32] = []
        for _ in 0..<16 {
            #if canImport(Glibc)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            #endif
            var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            held.append(fd)
        }
        for _ in 0..<30 { if server.activeConnections >= 16 { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        let activeHeld = server.activeConnections
        let seventeenth = rawRequest(port: port, "GET /api/status HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        check("17th concurrent connection → 503", seventeenth?.status == 503, "\(String(describing: seventeenth?.status)) active=\(activeHeld)")
        for fd in held { close(fd) }
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Expired token (clock seam).
        _ = await wf.rotate()
        let t2 = await wf.launchToken
        PageAuthorizer.clock = { Date().addingTimeInterval(400) }
        check("expired token → 404", exchange(port: port, token: t2).status == 404)
        PageAuthorizer.clock = { Date() }
        _ = await wf.rotate()
        let t3 = await wf.launchToken
        let ex3 = exchange(port: port, token: t3)
        check("fresh token after rotation exchanges", ex3.status == 303)
        check("old cookie → 404 after rotation", request(port: port, method: "GET", path: "/api/status", cookie: cookie).status == 404)
        let c3 = ex3.cookie ?? ""
        check("only the newest cookie works", request(port: port, method: "GET", path: "/api/status", cookie: c3).status == 200)

        // Rotation during a running installer job cancels and reaps it before
        // the new link (the menu shares this runner with its installers).
        do {
            let runner4 = SetupJobRunner()
            let wf4 = try PageAuthorizer(runner: runner4)
            let job4 = Task { await runner4.run(SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "sleep 30"], mode: .detached, timeout: 60, label: "slow")) }
            for _ in 0..<50 { if runner4.currentJob != nil { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
            check("job running", runner4.currentJob != nil)
            let before = Date()
            let rotation = await wf4.rotate()
            let result4 = await job4.value
            check("rotation cancelled and reaped the job before returning (no poison)",
                  rotation.poison == nil && !rotation.randomnessFailed && runner4.currentJob == nil && !result4.ok && Date().timeIntervalSince(before) < 10)
            check("no journal left after the cancelled job", !FileManager.default.fileExists(atPath: SetupJobRunner.journalURL.path))
        }

        // Atomic authorization: the cookie check and the generation it
        // authorizes are one call; after a rotation the old cookie yields
        // nothing, and the new cookie yields the new generation.
        let wf5 = try PageAuthorizer(runner: SetupJobRunner())
        let c5 = await wf5.exchange(token: await wf5.launchToken)
        let g5 = await wf5.authorizedGeneration(cookie: c5)
        _ = await wf5.rotate()
        let stale5 = await wf5.authorizedGeneration(cookie: c5)
        let c5b = await wf5.exchange(token: await wf5.launchToken)
        let g5b = await wf5.authorizedGeneration(cookie: c5b)
        check("authorizedGeneration: old cookie → nil after rotation; new cookie → new generation", g5 == 1 && stale5 == nil && g5b == 2, "\(String(describing: g5)) \(String(describing: stale5)) \(String(describing: g5b))")
        // RNG failure during rotation: revoked, nothing issued, nothing reused.
        PageAuthorizer.randomHexFails = true
        let failed = await wf5.rotate()
        PageAuthorizer.randomHexFails = false
        let tokenAfter = await wf5.launchToken
        let deadCookie = await wf5.authorizedGeneration(cookie: c5b)
        let deadExchange = await wf5.exchange(token: "0123456789abcdef0123456789abcdef")
        check("rotation with failing randomness → revoked, no token issued, old cookie dead", failed.randomnessFailed && tokenAfter.isEmpty && deadCookie == nil && deadExchange == nil)
        let recovered = await wf5.rotate()
        let tokenRecovered = await wf5.launchToken
        check("next rotation issues a fresh link", !recovered.randomnessFailed && !tokenRecovered.isEmpty)
        // In-flight settling: an operation of the old generation unwinds
        // before rotate() mints the new link.
        do {
            let wf7 = try PageAuthorizer(runner: SetupJobRunner())
            let g7 = await wf7.generation
            try await wf7.beginSettingsOperation(g7)
            let inFlightBefore = await wf7.inFlightOperations
            Task { try? await Task.sleep(nanoseconds: 300_000_000); await wf7.endSettingsOperation() }
            let started = Date()
            _ = await wf7.rotate()
            let inFlightAfter = await wf7.inFlightOperations
            check("rotate() waits for the in-flight operation to unwind (in-flight 1 → 0)",
                  inFlightBefore == 1 && inFlightAfter == 0 && Date().timeIntervalSince(started) >= 0.25, "\(inFlightBefore) \(inFlightAfter)")
            var stale = false
            do { try await wf7.beginSettingsOperation(g7) } catch is PageAuthorizer.Superseded { stale = true }
            check("an operation of the old generation can't begin after the rotation", stale)
            check("the synchronous checkpoint refuses the old generation too", (try? wf7.checkpointSync(g7)) == nil)
        }

        // Revocation is immediate: while a rotation is blocked on a job that
        // ignores SIGTERM, the old cookie and token are already dead, and
        // a concurrent second rotation is serialized behind the first.
        let runner8 = SetupJobRunner()
        let wf8 = try PageAuthorizer(runner: runner8)
        let c8 = await wf8.exchange(token: await wf8.launchToken)
        let g8 = await wf8.authorizedGeneration(cookie: c8)!
        SetupJobRunner.termGrace = 3
        let job8 = Task { await runner8.run(SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "trap '' TERM; sleep 30"], mode: .detached, timeout: 60, label: "stubborn")) }
        for _ in 0..<50 { if runner8.currentJob != nil { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        check("stubborn job running", runner8.currentJob != nil)
        let oldToken8 = await wf8.launchToken
        let rot1 = Task { await wf8.rotate() }
        try? await Task.sleep(nanoseconds: 300_000_000)   // rotation is now blocked in the SIGTERM grace
        let duringCookie = await wf8.authorizedGeneration(cookie: c8)
        let duringExchange = await wf8.exchange(token: oldToken8)
        let duringToken = await wf8.launchToken
        let rot2 = Task { await wf8.rotate() }
        let r1 = await rot1.value
        let r2 = await rot2.value
        _ = await job8.value
        SetupJobRunner.termGrace = 5
        let finalToken = await wf8.launchToken
        check("during a blocked rotation: old cookie → nil, old token → no exchange, no token issued yet", duringCookie == nil && duringExchange == nil && duringToken.isEmpty)
        check("concurrent rotations are serialized: both return, one live link, job reaped", !r1.randomnessFailed && !r2.randomnessFailed && !finalToken.isEmpty && runner8.currentJob == nil && r1.poison == nil)
        let c8b = await wf8.exchange(token: finalToken)
        let g8b = await wf8.authorizedGeneration(cookie: c8b)
        check("the new link authorizes the new generation only", g8b == g8 + 2, "\(String(describing: g8b))")
    }

    // MARK: 9. Static pages

    func staticPage() async throws {
        guard let dir = QuickSetupPreflight.pageDirectory() else { check("page directory in the bundle", false); return }
        let fm = FileManager.default
        check("the retired browser Quick Setup page is gone (no index.html / app.js in the bundle)",
              !fm.fileExists(atPath: dir.appendingPathComponent("index.html").path) && !fm.fileExists(atPath: dir.appendingPathComponent("app.js").path))
        for page in ["menu.html", "settings.html"] {
            let html = (try? String(contentsOf: dir.appendingPathComponent(page), encoding: .utf8)) ?? ""
            check("\(page) present", !html.isEmpty)
            check("\(page): no inline script", !html.contains("<script>") && html.range(of: "<script(?![^>]*src=)", options: .regularExpression) == nil)
            check("\(page): no inline style / on* handlers", !html.contains("<style") && html.range(of: " on[a-z]+=", options: .regularExpression) == nil && !html.contains("style=\""))
        }
        check("app.css (the settings page's stylesheet) is still shipped", fm.fileExists(atPath: dir.appendingPathComponent("app.css").path))
    }


    // MARK: 13/15. Lease, completion delivery

    func finishAndLease() async throws {
        // Lease semantics.
        let l1 = InstanceLease.acquire(label: "t1")
        check("first acquire succeeds", { if case .success = l1 { return true }; return false }())
        let l2 = InstanceLease.acquire(label: "t2")
        check("second acquire in the same process fails while held", { if case .failure = l2 { return true }; return false }())
        if case .success(let lease) = l1 {
            lease.release()
            lease.release()
            check("release is idempotent", !lease.held)
        }
        let l3 = InstanceLease.acquire(label: "t3")
        check("acquire succeeds after release", { if case .success = l3 { return true }; return false }())
        if case .success(let lease) = l3 { lease.release() }
        var dropObserved = false
        var releasedBeforeLog = false
        InstanceLease.onUnexpectedDrop = { _ in
            dropObserved = true
            if case .success(let probe) = InstanceLease.acquire(label: "probe") { releasedBeforeLog = true; probe.release() }
        }
        func dropInScope() { _ = InstanceLease.acquire(label: "dropped") }
        dropInScope()
        check("a lease dropped without release() is released in deinit, then logged (release before log)", dropObserved && releasedBeforeLog)
        InstanceLease.onUnexpectedDrop = nil

        // Completion delivery (the menu's closing reply): the command may tear
        // down only after an authorized completing response was fully written.
        let doneAuth = try PageAuthorizer(runner: SetupJobRunner())
        let completionServer = QuickSetupHTTPServer { req in
            guard await doneAuth.authorizedGeneration(cookie: req.cookieBQS) != nil else {
                if req.path == "/start", let t = QuickSetupHTTPServer.startToken(fromQuery: req.query), let c = await doneAuth.exchange(token: t) {
                    return QuickSetupHTTPServer.Response(status: 303, headers: [("Location", "/"), ("Set-Cookie", "bqs=\(c); HttpOnly; SameSite=Strict; Path=/")])
                }
                return .status(404)
            }
            var r = QuickSetupHTTPServer.Response(status: 200, headers: [("Content-Type", "application/json")], body: Data("{\"closing\":\"start\"}".utf8))
            r.completesSetup = true
            return r
        }
        try completionServer.start()
        defer { completionServer.stop() }
        let waitStart = ProcessInfo.processInfo.systemUptime
        let unseen = await completionServer.waitForCompletionDelivery(timeout: 0.08)
        check("closed-tab completion wait is bounded", !unseen && ProcessInfo.processInfo.systemUptime - waitStart < 1)
        let rejected = request(port: completionServer.port, method: "GET", path: "/api/menu/status")
        check("unauthorized poll cannot release completion wait", rejected.status == 404 && !completionServer.hasDeliveredCompletion)
        let failedWrite = completionServer.writeResponse(.init(status: 200, completesSetup: true), to: -1)
        check("failed response write cannot release completion wait", !failedWrite && !completionServer.hasDeliveredCompletion)
        let completionCookie = exchange(port: completionServer.port, token: await doneAuth.launchToken).cookie
        let delivered = request(port: completionServer.port, method: "GET", path: "/api/menu/status", cookie: completionCookie)
        let observed = await completionServer.waitForCompletionDelivery(timeout: 0.08)
        check("authorized completing reply reaches the client before completion release", delivered.status == 200 && delivered.json["closing"] as? String == "start" && observed)
    }


    // MARK: 14. Census

    func census() async throws {
        typealias F = AutoSuspendCensus.Facts
        func facts(masked: Bool? = false, desktop: String? = nil, display: Bool = false, pms: [String]? = [], tlp: Bool? = false, idle: String? = "ignore",
                   lid: Bool? = false, battery: Bool? = false, ac: String? = nil, bat: String? = nil, gsFail: Bool = false) -> F {
            F(allSleepTargetsMasked: masked, desktopSession: desktop, displayPresent: display, powerManagerProcesses: pms, tlpActive: tlp,
              logindIdleAction: idle, lidPresent: lid, internalBatteryPresent: battery, gnomeSleepInactiveAC: ac, gnomeSleepInactiveBattery: bat, gsettingsFailed: gsFail)
        }
        let v = AutoSuspendCensus.verdict
        check("masked targets → sleep impossible", v(facts(masked: true, desktop: "KDE")) == .sleepImpossible)
        check("headless clean → no detected idle auto-suspend", v(facts()) == .noDetectedIdleAutoSuspend(.headless(details: "no power manager, IdleAction ignore, no lid, no battery")))
        check("headless but IdleAction=suspend → may suspend", { if case .maySuspend = v(facts(idle: "suspend")) { return true }; return false }())
        check("headless but IdleAction unreadable → may suspend", { if case .maySuspend = v(facts(idle: nil)) { return true }; return false }())
        check("headless but lid present → may suspend", { if case .maySuspend(let r) = v(facts(lid: true)) { return r.contains("lid") }; return false }())
        check("headless but internal battery → may suspend", { if case .maySuspend(let r) = v(facts(battery: true)) { return r.contains("battery") }; return false }())
        check("headless with a power manager running → may suspend", { if case .maySuspend(let r) = v(facts(pms: ["gsd-power"])) { return r.contains("gsd-power") }; return false }())
        check("headless with an unreadable process table → may suspend", { if case .maySuspend = v(facts(pms: nil)) { return true }; return false }())
        check("KDE → may suspend", { if case .maySuspend(let r) = v(facts(desktop: "KDE", display: true)) { return r.contains("KDE") }; return false }())
        check("GNOME both nothing → no detected idle auto-suspend (gnome)", v(facts(desktop: "GNOME", display: true, ac: "'nothing'", bat: "'nothing'")) == .noDetectedIdleAutoSuspend(.gnomeNothing(lidPresent: false)))
        check("GNOME nothing + lid → evidence carries the lid and the caveat mentions it", { let r = v(facts(desktop: "ubuntu:GNOME", display: true, lid: true, ac: "'nothing'", bat: "'nothing'")); return r == .noDetectedIdleAutoSuspend(.gnomeNothing(lidPresent: true)) && r.summary.contains("closing the lid") }())
        check("GNOME one key unreadable → may suspend", { if case .maySuspend = v(facts(desktop: "GNOME", display: true, ac: "'nothing'", bat: nil)) { return true }; return false }())
        check("GNOME gsettings failing → may suspend", { if case .maySuspend(let r) = v(facts(desktop: "GNOME", display: true, gsFail: true)) { return r.contains("gsettings") }; return false }())
        check("GNOME suspend on → reason names the keys", { if case .maySuspend(let r) = v(facts(desktop: "GNOME", display: true, ac: "'suspend'", bat: "'suspend'")) { return r.contains("GNOME auto-suspend is on") }; return false }())
        check("summary text: headless carries the caveat", v(facts()).summary.contains("manual sleep"))
        #if os(macOS)
        KeepAwake.holdForProcessLifetime(reason: "Briglia selftest keep-awake")
        check("macOS assertion listed by pmset while held", KeepAwake.assertionListedBySystem(reason: "Briglia selftest keep-awake") == true)
        check("the keep-awake row's real check rejects an assertion under another reason", !QuickSetupEnvironment().keepAwakeHeld())
        KeepAwake.release()
        check("macOS assertion gone after release", KeepAwake.assertionListedBySystem(reason: "Briglia selftest keep-awake") == false)
        KeepAwake.holdForProcessLifetime()   // what `briglia quicksetup`, chat and daemon call
        check("the keep-awake row's real check passes under the shared default reason", QuickSetupEnvironment().keepAwakeHeld())
        KeepAwake.release()
        #endif
        // Python packages (security plan v24 §7.9.4): ONE job building Briglia's
        // private venv from the reviewed lock — never a shared `pip install`,
        // never --break-system-packages (the old real-pip check is retired).
        do {
            let status = ToolchainService.DesktopStatus(doctorRan: true, missing: ["openpyxl", "pillow"], libreOffice: true, mandatoryMissing: ["openpyxl", "pillow"])
            let jobs = QuickSetupEnvironment.defaultToolchainJobs(status)
            let py = jobs.filter { $0.label == "briglia python-env install" }
            check("missing Python packages → one private-venv job, no shared pip job",
                  py.count == 1 && py[0].command.suffix(2) == ["python-env", "install"]
                  && !jobs.contains { $0.command.contains("pip") || $0.command.joined(separator: " ").contains("break-system-packages") },
                  "\(jobs.map(\.command))")
        }
    }

    // MARK: 16. Package maps + disk floors

    func packagesAndDisk() async throws {
        let M = LinuxPackageMap.self
        check("apt: poppler-utils imagemagick ffmpeg pandoc libreoffice", M.mandatoryPackages(manager: "apt-get") == ["poppler-utils", "imagemagick", "ffmpeg", "pandoc", "libreoffice"])
        check("dnf: poppler-utils ImageMagick ffmpeg-free pandoc libreoffice", M.mandatoryPackages(manager: "dnf") == ["poppler-utils", "ImageMagick", "ffmpeg-free", "pandoc", "libreoffice"])
        check("pacman: poppler imagemagick ffmpeg pandoc libreoffice-fresh", M.mandatoryPackages(manager: "pacman") == ["poppler", "imagemagick", "ffmpeg", "pandoc", "libreoffice-fresh"])
        check("pip hint per manager", M.package("pip", manager: "apt-get") == "python3-pip" && M.package("pip", manager: "dnf") == "python3-pip" && M.package("pip", manager: "pacman") == "python-pip")
        check("apt argument shape", M.installCommand(manager: "apt-get", managerPath: "/usr/bin/apt-get", packages: ["x"]) == ["/usr/bin/apt-get", "install", "-y", "x"])
        check("dnf argument shape", M.installArgs(for: "dnf") == ["install", "-y"])
        check("pacman argument shape", M.installCommand(manager: "pacman", managerPath: "/usr/bin/pacman", packages: M.mandatoryPackages(manager: "pacman")) == ["/usr/bin/pacman", "-S", "--noconfirm", "--needed", "poppler", "imagemagick", "ffmpeg", "pandoc", "libreoffice-fresh"])
        // Disk floors: same device counted once with summed floors.
        QuickSetupEvidence.statvfsOverride = { path in
            if path.hasPrefix("/opt/small") { return (2, "/opt/small", 1 * QuickSetupEvidence.gb) }
            return (1, "/", 50 * QuickSetupEvidence.gb)
        }
        defer { QuickSetupEvidence.statvfsOverride = nil }
        let shared = QuickSetupEvidence.diskChecks(targets: [("/home/u", 1 * QuickSetupEvidence.gb), ("/var/cache/apt/archives", Int64(1.5 * Double(QuickSetupEvidence.gb)))])
        check("home + package cache on one device → one entry with summed floors", shared.count == 1 && shared[0].floorBytes == Int64(2.5 * Double(QuickSetupEvidence.gb)) && shared[0].mount == "/")
        let separate = QuickSetupEvidence.diskChecks(targets: [("/home/u", 1 * QuickSetupEvidence.gb), ("/opt/small/homebrew", 3 * QuickSetupEvidence.gb)])
        check("brew prefix on a small separate volume fails naming that mount", separate.count == 2 && separate[1].mount == "/opt/small" && !separate[1].ok && separate[0].ok)
    }
}

// MARK: - Helpers

final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        lock.lock(); opened = true; let w = waiters; waiters = []; lock.unlock()
        for c in w { c.resume() }
    }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

