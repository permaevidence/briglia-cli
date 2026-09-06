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
        abstract: "Internal: verify the desktop quick setup (server, workflow, runner, installer, lease).",
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
            try await SelftestSubprocess.agentMail(crash: agentmailCrash, dir: dir!, fixture: fixture!, sums: sums!, hold: holdSeconds)
            return
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
        await t.section("3c. browser settings") { try await t.browserSettings() }
        await t.section("3b. subscription workflow") { try await t.subscriptionWorkflow() }
        await t.section("3. workflow enforcement") { try await t.workflowEnforcement() }
        await t.section("7. mandatory rows fail closed") { try await t.mandatoryRows() }
        await t.section("8. job runner") { try await t.runner() }
        await t.section("9. static page") { try await t.staticPage() }
        await t.section("11. refusals") { try await t.refusals() }
        await t.section("13/15. finish, completion order, lease") { try await t.finishAndLease() }
        await t.section("14. keep-awake census") { try await t.census() }
        await t.section("16. package maps + disk floors") { try await t.packagesAndDisk() }
        await t.section("2b. AgentMail installer") { try await t.agentMailInstaller() }
        await t.section("2c. AgentMail pinned release") { try await t.agentMailPinning() }

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
    func stubEnv(linux: Bool = false) -> (env: QuickSetupEnvironment, store: StoreBox) {
        let store = StoreBox()
        var env = QuickSetupEnvironment()
        env.isLinux = linux
        env.probe = { req in
            let kind = req["kind"] as? String ?? ""
            let key = (req["api_key"] as? String) ?? (req["token"] as? String) ?? ""
            if kind == "telegram_chat" {
                if key != "tg-good" { return ["ok": false, "reason": "bad token"] }
                if (req["chat_id"] as? String) != "5551234567" { return ["ok": false, "reason": "chat not found — open @bot, send /start, then Retry", "reason_code": "chat_not_found"] }
                return ["ok": true, "bot_username": "test_bot", "chat_title": "Sofia", "chat_username": "sofia"]
            }
            if key.hasSuffix("-good") { return ["ok": true] }
            return ["ok": false, "reason": "\(kind): rejected"]
        }
        env.apply = { req, checkpoint in
            do { try checkpoint() } catch { return ["ok": false, "error": ["code": "superseded", "message": "superseded"]] }
            for (k, v) in req {
                guard let section = v as? [String: Any] else { continue }
                store.applied.append(k == "provider" ? (section["profile"] as? String ?? "provider") : k)
                if k == "provider", section["profile"] as? String == "opencode" { store.values[ProviderProfiles.opencodeApiKeyKey] = section["api_key"] as? String }
                if k == "provider", section["profile"] as? String == "openrouter" { store.values[KeychainHelper.openRouterApiKeyKey] = section["api_key"] as? String; store.activations.append(section["activate"] as? Bool ?? true) }
                if k == "provider", section["profile"] as? String == "custom" { store.values[ProviderProfiles.customApiKeyKey] = section["api_key"] as? String; store.values[ProviderProfiles.customBaseURLKey] = section["base_url"] as? String; store.values[ProviderProfiles.customModelKey] = section["model"] as? String; store.activations.append(section["activate"] as? Bool ?? true) }
                if k == "openai" { store.values[KeychainHelper.openAITranscriptionApiKeyKey] = section["api_key"] as? String }
                if k == "serper" { store.values[KeychainHelper.serperApiKeyKey] = section["api_key"] as? String }
                if k == "jina" { store.values[KeychainHelper.jinaApiKeyKey] = section["api_key"] as? String }
                if k == "identity" { store.values[KeychainHelper.userNameKey] = section["user_name"] as? String }
                if k == "telegram" { store.values[KeychainHelper.telegramBotTokenKey] = section["token"] as? String; store.values[KeychainHelper.telegramChatIdKey] = section["chat_id"] as? String }
                if k == "email_calendar" { store.values[KeychainHelper.agentMailApiKeyKey] = section["api_key"] as? String; store.values[KeychainHelper.emailCalendarProviderKey] = "agentmail"; store.installCLI = section["install_cli"] as? Bool }
            }
            return ["ok": true, "applied": Array(req.keys)]
        }
        env.storedValue = { store.values[$0] ?? nil }
        env.saveBatch = { changes in
            if let f = store.saveFailure { try f(changes, store) }
            for (k, v) in changes {
                if let v { store.values[k] = v } else { store.values.removeValue(forKey: k) }
            }
        }
        env.fsyncConfigDirectory = { store.fsyncCalls += 1; if store.fsyncFails > 0 { store.fsyncFails -= 1; throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "injected fsync failure"]) } }
        env.fullDiskAccessGranted = { store.fda }
        env.terminalAppName = { "Terminal" }
        env.openSettingsPane = { store.settingsOpened += 1 }
        env.keepAwakeHeld = { store.keepAwake }
        env.autoSuspendVerdict = { store.verdict }
        env.disableGnomeAutoSuspend = { store.gnomeDisabled = true; store.verdict = .noDetectedIdleAutoSuspend(.gnomeNothing(lidPresent: false)); return true }
        env.toolchainStatus = { store.toolchain }
        env.toolchainJobs = { _ in store.toolchainJobs }
        env.maskSleepTargetsJob = { store.maskJob }
        env.installAgentMail = { _, _, _ in store.agentMailInstalled = true; return nil }
        env.agentMailInstalled = { store.agentMailInstalled }
        env.installUnit = { store.unitInstalled = true; if let e = store.unitFailure { throw e } }
        env.enableService = { _ in store.serviceStarted = true; return store.enableFailure }
        env.serviceEvidence = { store.serviceEvidence }
        env.stopService = { store.stopCalls += 1; return store.stopOK }
        env.releaseLease = { store.releaseCalls += 1; store.progressAtRelease = store.values[SetupWizard.progressKey] ?? nil; store.unitInstalledAtRelease = store.unitInstalled }
        env.reacquireLease = { store.reacquireCalls += 1; return true }
        env.log = { _ in }
        return (env, store)
    }

    final class StoreBox: @unchecked Sendable {
        var values: [String: String?] = [:]
        /// A saved configuration, as the recheck step expects it.
        func seedConfigured() {
            for key in [ProviderProfiles.opencodeApiKeyKey, KeychainHelper.openAITranscriptionApiKeyKey, KeychainHelper.serperApiKeyKey,
                        KeychainHelper.jinaApiKeyKey, KeychainHelper.telegramBotTokenKey, KeychainHelper.telegramChatIdKey, KeychainHelper.userNameKey] {
                values[key] = "configured"
            }
        }
        var applied: [String] = []
        var activations: [Bool] = []
        var installCLI: Bool?
        var saveFailure: (([String: String?], StoreBox) throws -> Void)?
        var fsyncCalls = 0
        var fsyncFails = 0
        var fda = true
        var keepAwake = true
        var verdict: AutoSuspendCensus.Verdict = .sleepImpossible
        var gnomeDisabled = false
        var toolchain = ToolchainService.DesktopStatus(doctorRan: true, missing: [], libreOffice: true, mandatoryMissing: [])
        var toolchainJobs: [SetupJobRunner.Spec] = []
        var maskJob: SetupJobRunner.Spec?
        var agentMailInstalled = true
        var unitInstalled = false
        var unitFailure: Error?
        var serviceStarted = false
        var enableFailure: String?
        var serviceEvidence: (ok: Bool, linger: Bool, detail: String) = (true, true, "stub ok")
        var stopCalls = 0
        var stopOK = true
        var releaseCalls = 0
        var progressAtRelease: String?
        var unitInstalledAtRelease = false
        var reacquireCalls = 0
        var settingsOpened = 0
    }

    func goodRequest(opencode: String = "oc-good", chat: String = "5551234567", agentmail: Bool = true) -> QuickSetupRequest {
        var values: [QuickSetupField: QuickSetupRequest.Value] = [
            .opencode: .key(opencode), .openai: .key("oa-good"), .serper: .key("sp-good"), .jina: .key("ji-good"),
            .telegram: .telegram(token: "tg-good", chatId: chat),
        ]
        if agentmail { values[.agentmail] = .key("am-good") }
        return QuickSetupRequest(name: "Sofia Bruni", values: values)
    }

    func makeWorkflow(_ env: QuickSetupEnvironment, resume: QuickSetupWorkflow.ResumeMode = .fresh) throws -> (QuickSetupWorkflow, SetupJobRunner) {
        let runner = SetupJobRunner()
        let wf = try QuickSetupWorkflow(env: env, runner: runner, resume: resume)
        return (wf, runner)
    }

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

    func startServer(_ wf: QuickSetupWorkflow) throws -> (QuickSetupHTTPServer, QuickSetupRouter) {
        let pageDir = QuickSetupPreflight.pageDirectory() ?? tempDir("page")
        let portBox = QuickSetupSession.PortBox()
        let router = QuickSetupRouter(workflow: wf, pageDirectory: pageDir) { portBox.port }
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
        let (env, store) = stubEnv()
        let (wf, _) = try makeWorkflow(env)
        let (server, _) = try startServer(wf)
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
        check("status with cookie → 200 phase intro", r.status == 200 && r.json["phase"] as? String == "intro")
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
        QuickSetupWorkflow.clock = { Date().addingTimeInterval(400) }
        check("expired token → 404", exchange(port: port, token: t2).status == 404)
        QuickSetupWorkflow.clock = { Date() }
        _ = await wf.rotate()
        let t3 = await wf.launchToken
        let ex3 = exchange(port: port, token: t3)
        check("fresh token after rotation exchanges", ex3.status == 303)
        check("old cookie → 404 after rotation", request(port: port, method: "GET", path: "/api/status", cookie: cookie).status == 404)
        let c3 = ex3.cookie ?? ""
        check("only the newest cookie works", request(port: port, method: "GET", path: "/api/status", cookie: c3).status == 200)

        // Async revocation: verify aborted by a rotation between two awaits.
        let gate = AsyncGate()
        var slowEnv = env
        let originalProbe = env.probe
        slowEnv.probe = { req in
            if (req["kind"] as? String) == "opencode" { await gate.wait() }
            return await originalProbe(req)
        }
        let (wf2, _) = try makeWorkflow(slowEnv)
        let g = await wf2.generation
        let req = goodRequest()
        let verifyTask = Task { try await wf2.verify(req, generation: g) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await wf2.rotate()
        gate.open()
        var superseded = false
        do { _ = try await verifyTask.value } catch is QuickSetupWorkflow.Superseded { superseded = true } catch {}
        check("verify: rotation between awaits → Superseded", superseded)
        let st = await wf2.status()
        let rows = (st["rows"] as? [[String: Any]]) ?? []
        check("verify rows not marked ok after the abort", !rows.contains { $0["state"] as? String == "ok" }, "\(rows)")
        // Save: rotation injected between two sections leaves exactly the earlier ones saved.
        let (wf3, _) = try makeWorkflow(env)
        let g3 = await wf3.generation
        _ = try await wf3.verify(req, generation: g3)
        let phase3 = await wf3.phase
        check("stub verify → verified", phase3 == .verified)
        var rotEnv = env
        let rotatingApply = env.apply
        rotEnv.apply = { r, cp in
            if r["serper"] != nil { Task { _ = await wf3Box.value?.rotate() }; try? await Task.sleep(nanoseconds: 150_000_000) }
            return await rotatingApply(r, cp)
        }
        let (wf3b, _) = try makeWorkflow(rotEnv)
        wf3Box.value = wf3b
        let g3b = await wf3b.generation
        _ = try await wf3b.verify(req, generation: g3b)
        var superseded3 = false
        do { _ = try await wf3b.save(req, generation: g3b) } catch is QuickSetupWorkflow.Superseded { superseded3 = true } catch {}
        let saved = (await wf3b.status())["saved_sections"] as? [String] ?? []
        check("save: rotation while serper applies → superseded at serper's checkpoint; exactly provider + openai saved",
              superseded3 && saved == ["openai", "provider"] && !store.applied.contains("serper") && !store.applied.contains("jina"), "\(saved) \(store.applied)")
        // Rotation during a running job cancels and reaps before the new link.
        let (wf4, runner4) = try makeWorkflow(env)
        let (server4, _) = try startServer(wf4)
        defer { server4.stop() }
        store.toolchain = ToolchainService.DesktopStatus(doctorRan: true, missing: ["pandoc"], libreOffice: true, mandatoryMissing: ["pandoc"])
        store.toolchainJobs = [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "sleep 30"], mode: .detached, timeout: 60, label: "slow")]
        let g4 = await wf4.generation
        _ = try await wf4.verify(req, generation: g4)
        _ = try await wf4.save(req, generation: g4)
        let phase4s = await wf4.phase
        check("phase system after save", phase4s == .system)
        for row in ["agentmail_cli", "fda", "keepawake"] {
            _ = try await wf4.systemRun(row: row, option: nil, generation: g4)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        _ = try await wf4.systemRun(row: "toolchain", option: nil, generation: g4)
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("job running", runner4.currentJob != nil)
        let before = Date()
        let rotation = await wf4.rotate()
        check("rotation cancelled and reaped the job before returning (no poison)", rotation.poison == nil && !rotation.randomnessFailed && runner4.currentJob == nil && Date().timeIntervalSince(before) < 20)
        let rowsAfter = (await wf4.status())["system_rows"] as? [[String: Any]] ?? []
        check("toolchain row failed under the old generation", rowsAfter.first { $0["id"] as? String == "toolchain" }?["state"] as? String == "failed", "\(rowsAfter)")
        check("no journal left after the cancelled job", !FileManager.default.fileExists(atPath: SetupJobRunner.journalURL.path))

        // Atomic authorization: the cookie check and the generation it
        // authorizes are one call; after a rotation the old cookie yields
        // nothing, and the new cookie yields the new generation.
        let (wf5, _) = try makeWorkflow(env)
        let c5 = await wf5.exchange(token: await wf5.launchToken)
        let g5 = await wf5.authorizedGeneration(cookie: c5)
        _ = await wf5.rotate()
        let stale5 = await wf5.authorizedGeneration(cookie: c5)
        let c5b = await wf5.exchange(token: await wf5.launchToken)
        let g5b = await wf5.authorizedGeneration(cookie: c5b)
        check("authorizedGeneration: old cookie → nil after rotation; new cookie → new generation", g5 == 1 && stale5 == nil && g5b == 2, "\(String(describing: g5)) \(String(describing: stale5)) \(String(describing: g5b))")
        // RNG failure during rotation: revoked, nothing issued, nothing reused.
        QuickSetupWorkflow.randomHexFails = true
        let failed = await wf5.rotate()
        QuickSetupWorkflow.randomHexFails = false
        let tokenAfter = await wf5.launchToken
        let deadCookie = await wf5.authorizedGeneration(cookie: c5b)
        let deadExchange = await wf5.exchange(token: "0123456789abcdef0123456789abcdef")
        check("rotation with failing randomness → revoked, no token issued, old cookie dead", failed.randomnessFailed && tokenAfter.isEmpty && deadCookie == nil && deadExchange == nil)
        let recovered = await wf5.rotate()
        let tokenRecovered = await wf5.launchToken
        check("next rotation issues a fresh link", !recovered.randomnessFailed && !tokenRecovered.isEmpty)
        // Step-by-step handoff revokes the page's authorization.
        let (wf6, _) = try makeWorkflow(env)
        let c6 = await wf6.exchange(token: await wf6.launchToken)
        let g6 = await wf6.authorizedGeneration(cookie: c6)!
        let (st6, _) = try await wf6.stepByStep(generation: g6)
        let wizard6 = await wf6.wizardRequested
        let revoked6 = await wf6.authorizedGeneration(cookie: c6)
        check("step-by-step: 200, wizard requested, cookie revoked", st6 == 200 && wizard6 && revoked6 == nil)
        // In-flight settling: a verify suspended in a probe unwinds before rotate() returns.
        let gate7 = AsyncGate()
        var env7 = env
        let base7 = env.probe
        env7.probe = { r in if (r["kind"] as? String) == "serper" { await gate7.wait() }; return await base7(r) }
        let (wf7, _) = try makeWorkflow(env7)
        let g7 = await wf7.generation
        let t7 = Task { try await wf7.verify(self.goodRequest(), generation: g7) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let inFlightBefore = await wf7.inFlightOperations
        Task { try? await Task.sleep(nanoseconds: 300_000_000); gate7.open() }
        _ = await wf7.rotate()
        let inFlightAfter = await wf7.inFlightOperations
        _ = try? await t7.value
        check("rotate() waits for the in-flight verify to unwind (in-flight 1 → 0)", inFlightBefore == 1 && inFlightAfter == 0, "\(inFlightBefore) \(inFlightAfter)")

        // Revocation is immediate: while a rotation is blocked on a job that
        // ignores SIGTERM, the old cookie and token are already dead, and
        // a concurrent second rotation is serialized behind the first.
        let (wf8, runner8) = try makeWorkflow(env, resume: .system)
        let c8 = await wf8.exchange(token: await wf8.launchToken)
        let g8 = await wf8.authorizedGeneration(cookie: c8)!
        store.toolchain = ToolchainService.DesktopStatus(doctorRan: true, missing: ["pandoc"], libreOffice: true, mandatoryMissing: ["pandoc"])
        store.toolchainJobs = [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "trap '' TERM; sleep 30"], mode: .detached, timeout: 60, label: "stubborn")]
        SetupJobRunner.termGrace = 3
        for row in ["agentmail_cli", "fda", "keepawake"] { _ = try await wf8.systemRun(row: row, option: nil, generation: g8); try? await Task.sleep(nanoseconds: 200_000_000) }
        let (stRun8, jsRun8) = try await wf8.systemRun(row: "toolchain", option: nil, generation: g8)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let rows8 = (await wf8.status())["system_rows"] as? [[String: Any]] ?? []
        check("stubborn job running", runner8.currentJob != nil, "run=\(stRun8) \(jsRun8) rows=\(rows8)")
        let oldToken8 = await wf8.launchToken
        let rot1 = Task { await wf8.rotate() }
        try? await Task.sleep(nanoseconds: 300_000_000)   // rotation is now blocked in the SIGTERM grace
        let duringCookie = await wf8.authorizedGeneration(cookie: c8)
        let duringExchange = await wf8.exchange(token: oldToken8)
        let duringToken = await wf8.launchToken
        let rot2 = Task { await wf8.rotate() }
        let r1 = await rot1.value
        let r2 = await rot2.value
        SetupJobRunner.termGrace = 5
        let finalToken = await wf8.launchToken
        check("during a blocked rotation: old cookie → nil, old token → no exchange, no token issued yet", duringCookie == nil && duringExchange == nil && duringToken.isEmpty)
        check("concurrent rotations are serialized: both return, one live link, job reaped", !r1.randomnessFailed && !r2.randomnessFailed && !finalToken.isEmpty && runner8.currentJob == nil && r1.poison == nil)
        let c8b = await wf8.exchange(token: finalToken)
        let g8b = await wf8.authorizedGeneration(cookie: c8b)
        check("the new link authorizes the new generation only", g8b == g8 + 2, "\(String(describing: g8b))")
    }

    // MARK: 3. Workflow enforcement

    func workflowEnforcement() async throws {
        let (env, store) = stubEnv()
        let (wf, _) = try makeWorkflow(env)
        let g = await wf.generation
        let req = goodRequest()
        var (st, js) = try await wf.save(req, generation: g)
        check("save before verify → 409", st == 409)
        (st, js) = try await wf.finish(generation: g)
        check("finish before system-complete → 409", st == 409)
        (st, js) = try await wf.systemRun(row: "toolchain", option: nil, generation: g)
        check("system/run before system phase → 409", st == 409)
        (st, js) = try await wf.verify(goodRequest(opencode: "oc-bad"), generation: g)
        let rows = (js["rows"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) { $0[$1["id"] as? String ?? ""] = $1["state"] as? String }
        let phaseAfterBad = await wf.phase
        check("failed probe blocks save: only opencode failed", rows["opencode"] == "failed" && rows["openai"] == "ok" && rows["telegram"] == "ok" && phaseAfterBad == .intro)
        (st, js) = try await wf.save(goodRequest(opencode: "oc-bad"), generation: g)
        check("save with a failed row → 409", st == 409, "\(js)")
        (st, js) = try await wf.verify(req, generation: g)
        let phaseAll = await wf.phase
        check("all verified", phaseAll == .verified)
        (st, js) = try await wf.save(goodRequest(opencode: "oc-good2"), generation: g)
        check("save with a value that differs from the verified one → 409 naming it", st == 409 && (js["fields"] as? [String]) == ["opencode"])
        let phaseBack = await wf.phase
        check("…and the phase drops back to intro", phaseBack == .intro)
        (st, js) = try await wf.verify(req, generation: g)
        var keptReq = req
        keptReq.values[.serper] = .kept
        (st, js) = try await wf.save(keptReq, generation: g)
        check("client-declared kept for a field the server did not mark kept → 409", st == 409 && js["error"] as? String == "kept")
        // Telegram token verified with chat A cannot be saved with chat B.
        (st, js) = try await wf.verify(req, generation: g)
        (st, js) = try await wf.save(goodRequest(chat: "5551234568"), generation: g)
        check("telegram verified with chat A cannot be saved with chat B", st == 409 && (js["fields"] as? [String]) == ["telegram"])
        (st, js) = try await wf.verify(req, generation: g)
        do {
            let edited = goodRequest(opencode: "oc-bad")
            let (_, j) = try await wf.verify(edited, generation: g)
            let r = (j["rows"] as? [[String: Any]] ?? []).first { $0["id"] as? String == "opencode" }
            let phaseEdited = await wf.phase
            check("editing a verified row re-probes it and un-verifies on failure", r?["state"] as? String == "failed" && phaseEdited == .intro)
            _ = try await wf.verify(req, generation: g)
        }
        // Unknown JSON field, custom requires all three.
        var threw = false
        do { _ = try QuickSetupRequest.parse(["name": "x", "bogus": 1, "opencode": ["value": "a"], "openai": ["value": "a"], "serper": ["value": "a"], "jina": ["value": "a"], "telegram": ["token": "t", "chat_id": "1"]]) } catch { threw = true }
        check("unknown JSON field → parse error (400)", threw)
        threw = false
        do { _ = try QuickSetupRequest.parse(["name": "x", "opencode": ["value": "a"], "openai": ["value": "a"], "serper": ["value": "a"], "jina": ["value": "a"], "telegram": ["token": "t", "chat_id": "1"], "custom": ["api_key": "k", "base_url": "u"]]) } catch { threw = true }
        check("custom endpoint requires key + base URL + model", threw)
        threw = false
        do { _ = try QuickSetupRequest.parse(["name": "x", "opencode": ["kept": true, "value": "a"], "openai": ["value": "a"], "serper": ["value": "a"], "jina": ["value": "a"], "telegram": ["token": "t", "chat_id": "1"]]) } catch { threw = true }
        check("kept must be alone in its object", threw)
        let parsedCustom = try QuickSetupRequest.parse(["name": "x", "opencode": ["value": "a"], "openai": ["value": "a"], "serper": ["value": "a"], "jina": ["value": "a"], "telegram": ["token": "t", "chat_id": "1"], "custom": ["api_key": "k", "base_url": "u", "model": "m"]])
        let customPayload = QuickSetupWorkflow.applyPayload(section: "custom", request: parsedCustom)?["provider"] as? [String: Any]
        check("custom endpoint without the vision checkbox → text_only true (conservative, like the wizard)", customPayload?["text_only"] as? Bool == true)
        // Payload shapes.
        var full = goodRequest()
        full.values[.openrouter] = .key("or-good")
        full.values[.custom] = .custom(key: "c-good", baseURL: "http://x/v1", model: "m", vision: true)
        let (wfP, _) = try makeWorkflow(env)
        let gP = await wfP.generation
        _ = try await wfP.verify(full, generation: gP)
        (st, js) = try await wfP.save(full, generation: gP)
        let phaseP = await wfP.phase
        check("full save → system phase", st == 200 && phaseP == .system, "\(js)")
        check("AgentMail present ⇒ email_calendar section with install_cli false", store.applied.contains("email_calendar") && store.installCLI == false)
        check("OpenRouter and custom saved activate: false", store.activations == [false, false], "\(store.activations)")
        check("section order: provider first, identity/telegram before email, alternatives last",
              store.applied.suffix(3) == ["email_calendar", "openrouter", "custom"] && store.applied.first == "opencode", "\(store.applied)")
        check("progress marker quick:system written", store.values[SetupWizard.progressKey] == "quick:system")
        let sys = (await wfP.status())["system_rows"] as? [[String: Any]] ?? []
        check("system rows: agentmail_cli, fda, keepawake, toolchain (macOS shape)", sys.map { $0["id"] as? String ?? "" } == ["agentmail_cli", "fda", "keepawake", "toolchain"], "\(sys)")
        // Kept values: stored value not re-sent; replaced value re-probed.
        store.values[KeychainHelper.serperApiKeyKey] = "stored-serper"
        let (wfK, _) = try makeWorkflow(env)
        let keptK = await wfK.kept
        check("stored serper key is marked kept at start", keptK.contains(.serper))
        var kreq = goodRequest()
        kreq.values[.serper] = .kept
        let gK = await wfK.generation
        store.applied = []
        _ = try await wfK.verify(kreq, generation: gK)
        _ = try await wfK.save(kreq, generation: gK)
        check("kept serper: no serper section sent", !store.applied.contains("serper") && store.values[KeychainHelper.serperApiKeyKey] == "stored-serper")
        // Stale probe: a slow probe for r=1 answers after the field was edited.
        let gate = AsyncGate()
        var slowEnv = env
        let base = env.probe
        let counter = Counter()
        slowEnv.probe = { r in
            if (r["kind"] as? String) == "serper", counter.next() == 1 { await gate.wait() }
            return await base(r)
        }
        let (wfS, _) = try makeWorkflow(slowEnv)
        let gS = await wfS.generation
        let first = Task { try await wfS.verify(self.goodRequest(), generation: gS) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        var edited = goodRequest()
        edited.values[.serper] = .key("sp-bad")
        let second = try await wfS.verify(edited, generation: gS)
        gate.open()
        _ = try? await first.value
        let serperRow = (second.1["rows"] as? [[String: Any]] ?? []).first { $0["id"] as? String == "serper" }
        let latest = ((await wfS.status())["rows"] as? [[String: Any]] ?? []).first { $0["id"] as? String == "serper" }
        check("stale probe result (r=1, ok) does not mark the edited field (r=2, bad) verified",
              serperRow?["state"] as? String == "failed" && latest?["state"] as? String == "failed", "\(String(describing: latest))")
        let (stS, _) = try await wfS.save(goodRequest(), generation: gS)
        check("save after a stale-probe race is refused", stS == 409)
    }

    // MARK: 7. Mandatory rows

    func mandatoryRows() async throws {
        // macOS shape.
        do {
            let (env, store) = stubEnv()
            store.fda = false
            let (wf, _) = try makeWorkflow(env, resume: .system)
            let g = await wf.generation
            _ = try await wf.systemRun(row: "fda", option: nil, generation: g)
            try? await Task.sleep(nanoseconds: 300_000_000)
            var rows = (await wf.status())["system_rows"] as? [[String: Any]] ?? []
            check("FDA not granted → row failed with the open-settings offer", rows.first?["state"] as? String == "failed" && rows.first?["offer"] as? String == "open_settings")
            _ = try await wf.openSettings(generation: g)
            check("open-settings runs the pane URL only while fda is the current row", store.settingsOpened == 1)
            let (stNext, _) = try await wf.systemRun(row: "toolchain", option: nil, generation: g)
            check("a row that is not next → 409", stNext == 409)
            store.fda = true
            _ = try await wf.systemRun(row: "fda", option: nil, generation: g)
            try? await Task.sleep(nanoseconds: 300_000_000)
            store.keepAwake = false
            _ = try await wf.systemRun(row: "keepawake", option: nil, generation: g)
            try? await Task.sleep(nanoseconds: 300_000_000)
            rows = (await wf.status())["system_rows"] as? [[String: Any]] ?? []
            check("macOS keep-awake without the assertion → failed", rows[1]["state"] as? String == "failed")
            store.keepAwake = true
            _ = try await wf.systemRun(row: "keepawake", option: nil, generation: g)
            try? await Task.sleep(nanoseconds: 300_000_000)
            store.toolchain = ToolchainService.DesktopStatus(doctorRan: false, missing: [], libreOffice: true, mandatoryMissing: [])
            _ = try await wf.systemRun(row: "toolchain", option: nil, generation: g)
            try? await Task.sleep(nanoseconds: 300_000_000)
            rows = (await wf.status())["system_rows"] as? [[String: Any]] ?? []
            check("doctor cannot run → toolchain row failed", rows[2]["state"] as? String == "failed", "\(rows[2])")
            store.toolchain = ToolchainService.DesktopStatus(doctorRan: true, missing: ["html-to-pdf engine"], libreOffice: true, mandatoryMissing: [])
            _ = try await wf.systemRun(row: "toolchain", option: nil, generation: g)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let phaseTC = await wf.phase
            check("html-to-pdf engine missing alone → ok, phase systemComplete", phaseTC == .systemComplete)
        }
        // Linux shape: keep-awake verdicts and the mask offer.
        do {
            let (env, store) = stubEnv(linux: true)
            let (wf, _) = try makeWorkflow(env, resume: .system)
            let g = await wf.generation
            let ids = (await wf.systemRows).map(\.id)
            check("Linux rows: keepawake, toolchain (agentmail only when chosen)", ids == ["keepawake", "toolchain"], "\(ids)")
            store.verdict = .maySuspend(reason: "desktop session KDE with a power manager Briglia cannot read")
            _ = try await wf.systemRun(row: "keepawake", option: nil, generation: g)
            try? await Task.sleep(nanoseconds: 300_000_000)
            var rows = (await wf.status())["system_rows"] as? [[String: Any]] ?? []
            check("KDE → not ok, mask offered", rows[0]["state"] as? String == "failed" && rows[0]["offer"] as? String == "mask")
            store.verdict = .maySuspend(reason: "GNOME auto-suspend is on (sleep-inactive-ac-type=suspend, sleep-inactive-battery-type=suspend)")
            _ = try await wf.systemRun(row: "keepawake", option: nil, generation: g)
            try? await Task.sleep(nanoseconds: 300_000_000)
            rows = (await wf.status())["system_rows"] as? [[String: Any]] ?? []
            check("GNOME auto-suspend → no-sudo fix applied first, then ok", store.gnomeDisabled && rows[0]["state"] as? String == "ok")
            // Mask path through a (stub) handoff job would need a tty; the job itself is exercised in the runner section.
            store.toolchain = ToolchainService.DesktopStatus(doctorRan: true, missing: ["pandoc"], libreOffice: false, mandatoryMissing: ["pandoc"])
            store.toolchainJobs = [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "exit 3"], mode: .detached, timeout: 30, label: "failing install")]
            _ = try await wf.systemRun(row: "toolchain", option: nil, generation: g)
            for _ in 0..<50 { try? await Task.sleep(nanoseconds: 100_000_000); let rs = await wf.systemRows; if rs[1].state != "running" { break } }
            rows = (await wf.status())["system_rows"] as? [[String: Any]] ?? []
            check("failing installer → toolchain row failed with the exit status", rows[1]["state"] as? String == "failed" && (rows[1]["reason"] as? String ?? "").contains("status 3"), "\(rows[1])")
            store.toolchainJobs = [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "echo ok"], mode: .detached, timeout: 30, label: "install")]
            _ = try await wf.systemRun(row: "toolchain", option: nil, generation: g)
            for _ in 0..<50 { try? await Task.sleep(nanoseconds: 100_000_000); let rs = await wf.systemRows; if rs[1].state != "running" { break } }
            rows = (await wf.status())["system_rows"] as? [[String: Any]] ?? []
            check("installer ok but doctor still missing → row failed (evidence-based)", rows[1]["state"] as? String == "failed" && (rows[1]["reason"] as? String ?? "").contains("still missing"), "\(rows[1])")
        }
    }

    // MARK: 9. Static page

    func staticPage() async throws {
        guard let dir = QuickSetupPreflight.pageDirectory() else { check("page directory in the bundle", false); return }
        let html = (try? String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8)) ?? ""
        let js = (try? String(contentsOf: dir.appendingPathComponent("app.js"), encoding: .utf8)) ?? ""
        let css = (try? String(contentsOf: dir.appendingPathComponent("app.css"), encoding: .utf8)) ?? ""
        check("page files present", !html.isEmpty && !js.isEmpty && !css.isEmpty)
        check("no inline script", !html.contains("<script>") && html.range(of: "<script(?![^>]*src=)", options: .regularExpression) == nil)
        check("no inline style / on* handlers", !html.contains("<style") && html.range(of: " on[a-z]+=", options: .regularExpression) == nil && !html.contains("style=\""))
        for banned in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "localStorage", "sessionStorage", "eval("] {
            check("app.js does not use \(banned)", !js.contains(banned))
        }
        check("secret inputs set autocomplete off", js.contains("autocomplete = 'off'") || js.contains("autocomplete=\"off\""))
        let allowed = ["https://opencode.ai/zen", "https://platform.openai.com/api-keys", "https://serper.dev", "https://jina.ai", "https://t.me/BotFather", "https://t.me/userinfobot", "https://agentmail.to", "https://openrouter.ai/keys", "https://auth.openai.com/codex/device"]
        let urlRegex = try NSRegularExpression(pattern: "https?://[A-Za-z0-9./_-]+")
        let urls = urlRegex.matches(in: js, range: NSRange(js.startIndex..., in: js)).map { String(js[Range($0.range, in: js)!]) }
        let foreign = urls.filter { u in !allowed.contains(u) && !u.hasPrefix("https://my-server.example") && u != "http://127.0.0.1" }
        check("app.js external URLs are only the documented anchors", foreign.isEmpty, "\(foreign)")
        check("index.html has no external URLs", html.range(of: "https?://", options: .regularExpression) == nil)
        check("anchors open with noopener noreferrer", js.contains("rel = 'noopener noreferrer'"))
    }

    // MARK: 11. Refusals

    func refusals() async throws {
        func refusal(_ configure: () -> Void, isLinux: Bool) -> String {
            QuickSetupPreflight.isUbuntuTouchOverride = false
            QuickSetupPreflight.setupCompleteOverride = false
            QuickSetupPreflight.brewPresentOverride = true
            QuickSetupPreflight.pythonOverride = .init(present: true, pipOK: true)
            QuickSetupPreflight.packageManagerOverride = ("apt-get", true)
            QuickSetupPreflight.sudoPresentOverride = true
            QuickSetupPreflight.systemdSessionOverride = true
            QuickSetupEvidence.statvfsOverride = { _ in (1, "/", 100 * QuickSetupEvidence.gb) }
            QuickSetupPreflight.pageDirectoryOverride = tempRoot
            configure()
            defer {
                QuickSetupPreflight.isUbuntuTouchOverride = nil; QuickSetupPreflight.setupCompleteOverride = nil
                QuickSetupPreflight.brewPresentOverride = nil; QuickSetupPreflight.pythonOverride = nil
                QuickSetupPreflight.packageManagerOverride = nil; QuickSetupPreflight.sudoPresentOverride = nil
                QuickSetupPreflight.systemdSessionOverride = nil; QuickSetupEvidence.statvfsOverride = nil
                QuickSetupPreflight.pageDirectoryOverride = nil
            }
            do { try QuickSetupPreflight.check(isLinux: isLinux); return "" } catch { return "\(error)" }
        }
        check("Ubuntu Touch → app message", refusal({ QuickSetupPreflight.isUbuntuTouchOverride = true }, isLinux: true).contains("Briglia app"))
        check("setup complete → use briglia setup", refusal({ QuickSetupPreflight.setupCompleteOverride = true }, isLinux: false).contains("already set up"))
        check("macOS without Homebrew → brew.sh", refusal({ QuickSetupPreflight.brewPresentOverride = false }, isLinux: false).contains("brew.sh"))
        check("macOS with broken pip → CLT hint", refusal({ QuickSetupPreflight.pythonOverride = .init(present: true, pipOK: false) }, isLinux: false).contains("xcode-select"))
        check("Linux without a package manager → sudo/pm message", refusal({ QuickSetupPreflight.packageManagerOverride = ("", false) }, isLinux: true).contains("package manager"))
        check("Linux without pip → distribution hint", refusal({ QuickSetupPreflight.pythonOverride = .init(present: true, pipOK: false) }, isLinux: true).contains("python3-pip"))
        check("Linux without a systemd user session → use briglia setup", refusal({ QuickSetupPreflight.systemdSessionOverride = false }, isLinux: true).contains("systemd user service"))
        check("disk below floor → names the mount and the numbers", refusal({ QuickSetupEvidence.statvfsOverride = { _ in (1, "/", 1 * QuickSetupEvidence.gb) } }, isLinux: false).contains("free on /"))
        let home = NSHomeDirectory()
        check("disk information unreadable for a destination → refusal naming it (never silently omitted)",
              refusal({ QuickSetupEvidence.statvfsOverride = { path in path == home ? nil : (1, "/", 100 * QuickSetupEvidence.gb) } }, isLinux: false).contains("cannot read the free space on \(home)"))
        check("all clear → no refusal", refusal({}, isLinux: false).isEmpty)
        check("all clear (Linux) → no refusal", refusal({}, isLinux: true).isEmpty)
        // Second instance: the session lock.
        let fd = QuickSetupSession.takeSessionLock()
        check("session lock taken", fd != nil)
        if let fd {
            QuickSetupSession.writeSessionLock(fd: fd, port: 4242)
            let content = (try? String(contentsOf: QuickSetupSession.lockFileURL, encoding: .utf8)) ?? ""
            check("quicksetup.lock holds pid, port and a token-free hint", content.contains("pid ") && content.contains("port 4242") && !content.contains("t="))
            let second = QuickSetupSession.takeSessionLock()
            check("second instance refused by the session lock", second == nil)
            close(fd)
        }
    }

    // MARK: 13/15. Finish, completion order, lease

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

        // Linux completion order.
        let (env, store) = stubEnv(linux: true)
        store.seedConfigured()
        store.agentMailInstalled = true
        let (wf, _) = try makeWorkflow(env, resume: .system)
        let g = await wf.generation
        for row in ["keepawake", "toolchain"] {
            _ = try await wf.systemRun(row: row, option: nil, generation: g)
            for _ in 0..<50 { try? await Task.sleep(nanoseconds: 50_000_000); if (await wf.systemRows).first(where: { $0.id == row })?.state != "running" { break } }
        }
        let phaseSC = await wf.phase
        check("system complete", phaseSC == .systemComplete)
        let (st, _) = try await wf.finish(generation: g)
        check("finish accepted", st == 202)
        for _ in 0..<100 { try? await Task.sleep(nanoseconds: 50_000_000); if await wf.isDone { break } }
        let doneL = await wf.isDone
        check("finish reached done", doneL)
        // The CLI may tear down only after an authorized DONE status was
        // fully written. No observer still has a bounded grace period.
        let (completionServer, _) = try startServer(wf)
        defer { completionServer.stop() }
        let waitStart = ProcessInfo.processInfo.systemUptime
        let unseen = await completionServer.waitForCompletionDelivery(timeout: 0.08)
        check("closed-tab completion wait is bounded", !unseen && ProcessInfo.processInfo.systemUptime - waitStart < 1)
        let rejected = request(port: completionServer.port, method: "GET", path: "/api/status")
        check("unauthorized DONE poll cannot release completion wait", rejected.status == 404 && !completionServer.hasDeliveredCompletion)
        let failedWrite = completionServer.writeResponse(.init(status: 200, completesSetup: true), to: -1)
        check("failed response write cannot release completion wait", !failedWrite && !completionServer.hasDeliveredCompletion)
        let completionToken = await wf.launchToken
        let completionCookie = exchange(port: completionServer.port, token: completionToken).cookie
        let delivered = request(port: completionServer.port, method: "GET", path: "/api/status", cookie: completionCookie)
        let observed = await completionServer.waitForCompletionDelivery(timeout: 0.08)
        check("authorized DONE reaches client before completion release", delivered.status == 200 && delivered.json["phase"] as? String == "done" && observed)

        check("lease released exactly once, after the unit was installed and quick:handoff was on disk",
              store.releaseCalls == 1 && store.unitInstalledAtRelease && store.progressAtRelease == "quick:handoff")
        check("service started after the release, evidence checked", store.serviceStarted)
        check("complete written together with progress deletion", store.values[SetupWizard.completeKey] == "true" && store.values[SetupWizard.progressKey] == nil)
        // Old-or-new: post-rename fsync failure at step 9 → barrier retried; three failures → failed, not done.
        do {
            let (env2, store2) = stubEnv(linux: false)
            store2.seedConfigured()
            let (wf2, _) = try makeWorkflow(env2, resume: .system)
            let g2 = await wf2.generation
            for row in ["fda", "keepawake", "toolchain"] {
                _ = try await wf2.systemRun(row: row, option: nil, generation: g2)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            store2.saveFailure = { changes, s in
                if changes[SetupWizard.completeKey] != nil {
                    for (k, v) in changes { if let v { s.values[k] = v } else { s.values.removeValue(forKey: k) } }   // new state present (rename happened)
                    throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "injected post-rename fsync failure"])
                }
            }
            store2.fsyncFails = 3
            _ = try await wf2.finish(generation: g2)
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                let failed = (await wf2.finishSteps).contains(where: { $0.state == "failed" })
                let done = await wf2.isDone
                if failed || done { break }
            }
            let steps = await wf2.finishSteps
            let done2 = await wf2.isDone
            check("barrier failing three times → complete step failed, Done not shown", steps.last?.state == "failed" && !done2 && store2.fsyncCalls == 3, "\(steps.last?.reason ?? "") calls=\(store2.fsyncCalls)")
            store2.saveFailure = nil
            store2.fsyncFails = 0
            _ = try await wf2.finish(generation: g2)
            for _ in 0..<100 { try? await Task.sleep(nanoseconds: 50_000_000); if await wf2.isDone { break } }
            let doneRetry = await wf2.isDone
            check("Retry after the barrier succeeds → done", doneRetry)
        }
        // Pre-rename failure → old state, three retries, save_failed naming the old state.
        do {
            let (env3, store3) = stubEnv(linux: false)
            store3.seedConfigured()
            let (wf3, _) = try makeWorkflow(env3, resume: .system)
            let g3 = await wf3.generation
            for row in ["fda", "keepawake", "toolchain"] {
                _ = try await wf3.systemRun(row: row, option: nil, generation: g3)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            var attempts = 0
            store3.saveFailure = { changes, _ in
                if changes[SetupWizard.completeKey] != nil { attempts += 1; throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"]) }
            }
            _ = try await wf3.finish(generation: g3)
            for _ in 0..<100 { try? await Task.sleep(nanoseconds: 50_000_000); let fs = await wf3.finishSteps; if fs.contains(where: { $0.state == "failed" }) { break } }
            let last = (await wf3.finishSteps).last
            check("pre-rename failure → 1+3 attempts, save_failed naming the old state", attempts == 4 && last?.state == "failed" && (last?.reason ?? "").contains("old state"), "\(attempts) \(last?.reason ?? "")")
        }
        // Constrained resume: regressed evidence → stop service, reacquire, back to quick:system.
        do {
            let (env4, store4) = stubEnv(linux: true)
            store4.seedConfigured()
            store4.values[SetupWizard.progressKey] = "quick:handoff"
            store4.toolchain = ToolchainService.DesktopStatus(doctorRan: true, missing: ["pandoc"], libreOffice: true, mandatoryMissing: ["pandoc"])
            let (wf4, _) = try makeWorkflow(env4, resume: .handoff)
            let phaseH = await wf4.phase
            check("handoff resume starts in finishing", phaseH == .finishing)
            let g4 = await wf4.generation
            _ = try await wf4.finish(generation: g4)
            for _ in 0..<100 { try? await Task.sleep(nanoseconds: 50_000_000); let ph = await wf4.phase; if ph == .system { break } }
            let phase4 = await wf4.phase
            check("regressed toolchain → service stopped, lease reacquired, progress reverted to quick:system, no steps 7–10 run",
                  store4.stopCalls == 1 && store4.reacquireCalls == 1 && store4.values[SetupWizard.progressKey] == "quick:system" && phase4 == .system && store4.values[SetupWizard.completeKey] == nil)
            let (env5, store5) = stubEnv(linux: true)
            store5.seedConfigured()
            store5.values[SetupWizard.progressKey] = "quick:handoff"
            store5.toolchain = ToolchainService.DesktopStatus(doctorRan: true, missing: ["pandoc"], libreOffice: true, mandatoryMissing: ["pandoc"])
            store5.stopOK = false
            let (wf5, _) = try makeWorkflow(env5, resume: .handoff)
            _ = try await wf5.finish(generation: await wf5.generation)
            for _ in 0..<100 { try? await Task.sleep(nanoseconds: 50_000_000); let fs = await wf5.finishSteps; if fs.contains(where: { $0.state == "failed" }) { break } }
            let first5 = (await wf5.finishSteps).first
            check("service that refuses to stop → resume fails naming it", first5?.state == "failed" && (first5?.reason ?? "").contains("could not be stopped"))
            // Healthy handoff resume runs only steps 7–10.
            let (env6, store6) = stubEnv(linux: true)
            store6.seedConfigured()
            store6.values[SetupWizard.progressKey] = "quick:handoff"
            let (wf6, _) = try makeWorkflow(env6, resume: .handoff)
            _ = try await wf6.finish(generation: await wf6.generation)
            for _ in 0..<100 { try? await Task.sleep(nanoseconds: 50_000_000); if await wf6.isDone { break } }
            let done6 = await wf6.isDone
            check("healthy handoff resume → done without reinstalling the unit or releasing a lease", done6 && !store6.unitInstalled && store6.releaseCalls == 0 && store6.values[SetupWizard.completeKey] == "true")
            // Service evidence failures.
            let (env7, store7) = stubEnv(linux: true)
            store7.seedConfigured()
            store7.values[SetupWizard.progressKey] = "quick:handoff"
            store7.serviceEvidence = (false, false, "start at boot not confirmed enabled (linger)")
            let (wf7, _) = try makeWorkflow(env7, resume: .handoff)
            _ = try await wf7.finish(generation: await wf7.generation)
            for _ in 0..<100 { try? await Task.sleep(nanoseconds: 50_000_000); let fs = await wf7.finishSteps; if fs.contains(where: { $0.state == "failed" }) { break } }
            let failedStep = (await wf7.finishSteps).first { $0.state == "failed" }
            check("service active but linger absent → service step failed", failedStep?.id == "service" && (failedStep?.reason ?? "").contains("linger"))
        }
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
        // Real pip on the CI distribution (Jammy): feature-detected flag, real install of a missing package.
        if ProcessInfo.processInfo.environment["BRIGLIA_SELFTEST_REAL_PIP"] == "1", let python = ToolchainService.python3Path() {
            let helpOut = QuickSetupEvidence.quietRun(python, ["-m", "pip", "install", "--help"], timeoutSeconds: 30)?.stdout ?? ""
            let supported = ToolchainService.pipBreakSystemPackagesSupported(python: python)
            check("pip --break-system-packages feature detection matches `pip install --help`", supported == helpOut.contains("--break-system-packages"))
            let status = ToolchainService.DesktopStatus(doctorRan: true, missing: ["openpyxl"], libreOffice: true, mandatoryMissing: ["openpyxl"])
            let jobs = QuickSetupEnvironment.defaultToolchainJobs(status).filter { $0.label.hasPrefix("pip install") }
            check("real pip job built for the missing package", jobs.count == 1 && jobs[0].command.contains("openpyxl") && (jobs[0].command.contains("--break-system-packages") == supported), "\(jobs.map(\.command))")
            if let job = jobs.first {
                let r = SetupJobRunner()
                let result = await r.run(job)
                let imported = QuickSetupEvidence.quietRun(python, ["-c", "import openpyxl; print(openpyxl.__version__)"], timeoutSeconds: 30)
                check("real `pip install openpyxl` through the runner succeeds and the package imports", result.ok && imported?.status == 0, "\(result.outcome) \(result.lastLines.suffix(3))")
            }
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

final class WorkflowBox: @unchecked Sendable {
    var value: QuickSetupWorkflow?
}
nonisolated(unsafe) let wf3Box = WorkflowBox()
