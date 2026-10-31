import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Local page resources

/// Shared by `briglia menu`, its live hub and browser settings. (The
/// browser Quick Setup that once lived here was retired in 0.2.67:
/// `briglia quicksetup` is now the terminal flow in QuickSetupTerminal.swift.)
enum QuickSetupPreflight {
    /// Selftest seam.
    nonisolated(unsafe) static var isUbuntuTouchOverride: Bool?

    nonisolated(unsafe) static var pageDirectoryOverride: URL?
    static func pageDirectory() -> URL? {
        if let pageDirectoryOverride { return pageDirectoryOverride }
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("QuickSetup", isDirectory: true) else { return nil }
        for file in ["app.css", "menu.html", "menu.js", "menu.css"] where !FileManager.default.fileExists(atPath: url.appendingPathComponent(file).path) {
            return nil
        }
        return url
    }
}

// MARK: - Router (§5.3, §5.4): authorization, same-origin, dispatch

final class QuickSetupRouter: @unchecked Sendable {
    let workflow: PageAuthorizer
    let port: () -> UInt16
    let pageDirectory: URL
    var settings: BrowserSettingsWorkflow?
    /// `briglia menu`: the ChatGPT-subscription page (menu.html) on the same
    /// authorization, same-origin and header rules as quick setup. Attaching
    /// it binds the menu to this authorizer: every menu write re-checks the
    /// link generation that admitted it, and a rotation cancels and settles
    /// the menu's own work before the new link is minted.
    var menu: MenuWorkflow? {
        didSet {
            guard let menu else { return }
            let auth = workflow
            menu.validity.authCheck = { try auth.checkpointSync($0) }
            auth.setRevocationHook { await menu.revoke() }
        }
    }

    init(workflow: PageAuthorizer, pageDirectory: URL, port: @escaping () -> UInt16) {
        self.workflow = workflow
        self.pageDirectory = pageDirectory
        self.port = port
    }

    typealias Request = QuickSetupHTTPServer.Request
    typealias Response = QuickSetupHTTPServer.Response

    static func json(_ status: Int, _ object: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Response(status: status, headers: [("Content-Type", "application/json")], body: data)
    }

    func handle(_ request: Request) async -> Response {
        let expectedHost = "127.0.0.1:\(port())"
        guard request.headers["host"] == expectedHost else { return .status(400) }
        if let site = request.headers["sec-fetch-site"], site != "same-origin", site != "none" { return .status(403) }
        if request.method == "OPTIONS" { return .status(403) }
        if request.method == "POST" {
            guard request.headers["origin"] == "http://\(expectedHost)",
                  request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
                  request.headers["x-briglia-quick-setup"] == "1" else { return .status(403) }
        }
        // Token exchange: the only route without a cookie.
        if request.path == "/start" {
            guard request.method == "GET", let token = QuickSetupHTTPServer.startToken(fromQuery: request.query),
                  let cookie = await workflow.exchange(token: token) else { return .status(404) }
            return Response(status: 303, headers: [
                ("Location", "/"),
                ("Set-Cookie", "bqs=\(cookie); HttpOnly; SameSite=Strict; Path=/"),
            ])
        }
        if request.query != nil { return .status(400) }
        // One actor call: the cookie check and the generation it authorizes.
        guard let g = await workflow.authorizedGeneration(cookie: request.cookieBQS) else { return .status(404) }

        if let menu {
            switch (request.method, request.path) {
            case ("GET", "/"): return staticFile("menu.html", type: "text/html; charset=utf-8")
            case ("GET", "/menu.js"): return staticFile("menu.js", type: "text/javascript; charset=utf-8")
            case ("GET", "/menu.css"): return staticFile("menu.css", type: "text/css; charset=utf-8")
            case ("GET", "/api/menu/status"):
                return Self.json(200, await menu.status(generation: g))
            case ("POST", "/api/menu"):
                guard let body = parseBody(request) else { return Self.json(400, ["error": "bad_json"]) }
                // nil: the link was replaced or the page closed while this
                // request ran — no answer, like every other revoked request.
                guard let result = await menu.handle(body, generation: g) else { return .status(404) }
                var response = Self.json(200, result)
                // The reply that closes the page is the one the session
                // waits to see delivered before it stops the server.
                response.completesSetup = (result["status"] as? [String: Any])?["closing"] is String
                return response
            default: return .status(404)
            }
        }
        if let settings {
            switch (request.method, request.path) {
            case ("GET", "/"): return staticFile("settings.html", type: "text/html; charset=utf-8")
            case ("GET", "/settings.js"): return staticFile("settings.js", type: "text/javascript; charset=utf-8")
            case ("GET", "/app.css"): return staticFile("app.css", type: "text/css; charset=utf-8")
            case ("GET", "/api/status"):
                let result = await settings.handle("status", body: [:], generation: g)
                return Self.json(result.0, result.1)
            case ("POST", "/api/verify"), ("POST", "/api/save"), ("POST", "/api/subscription"):
                guard let body = parseBody(request) else { return Self.json(400, ["error": "bad_json"]) }
                let result = await settings.handle(String(request.path.dropFirst(5)), body: body, generation: g)
                return Self.json(result.0, result.1)
            default: return .status(404)
            }
        }
        return .status(404)
    }

    private func parseBody(_ request: Request) -> [String: Any]? {
        guard !request.body.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
    }

    private func staticFile(_ name: String, type: String) -> Response {
        guard let data = try? Data(contentsOf: pageDirectory.appendingPathComponent(name)) else { return .status(404) }
        return Response(status: 200, headers: [("Content-Type", type)], body: data)
    }
}

// MARK: - Enter listener (§3.5)

/// Poll-based stdin listener: Enter mints a new link. Suspended by the job
/// runner before every terminal handoff (a suspended listener ignores
/// keystrokes; the sudo child owns the terminal meanwhile).
final class EnterListener: StdinListenerControl, @unchecked Sendable {
    private let lock = NSLock()
    private var suspended = false
    private var stopped = false
    private var wake: [Int32] = [-1, -1]
    private let onEnter: () -> Void
    private var thread: Thread?

    init(onEnter: @escaping () -> Void) {
        self.onEnter = onEnter
    }

    func start() {
        guard pipe(&wake) == 0 else { return }
        let t = Thread { [self] in loop() }
        t.name = "quicksetup-enter"
        thread = t
        t.start()
    }

    func suspend() { lock.lock(); suspended = true; lock.unlock(); poke() }
    func resume() { lock.lock(); suspended = false; lock.unlock(); poke() }
    func stop() { lock.lock(); stopped = true; lock.unlock(); poke() }

    private func poke() {
        var b: UInt8 = 1
        if wake[1] >= 0 { _ = write(wake[1], &b, 1) }
    }

    private func loop() {
        var byte: UInt8 = 0
        while true {
            lock.lock(); let s = stopped, sus = suspended; lock.unlock()
            if s { return }
            var fds = [pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0),
                       pollfd(fd: sus ? -1 : STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
            let rc = poll(&fds, 2, 500)
            if rc <= 0 { continue }
            if Int32(fds[0].revents) & Int32(POLLIN) != 0 {
                var drain: UInt8 = 0
                _ = read(wake[0], &drain, 1)
                continue
            }
            guard !sus, Int32(fds[1].revents) & (Int32(POLLIN) | Int32(POLLHUP)) != 0 else { continue }
            let n = read(STDIN_FILENO, &byte, 1)
            if n <= 0 { Thread.sleep(forTimeInterval: 0.5); continue }
            if byte == 0x0A { onEnter() }
        }
    }
}

// MARK: - Shared helpers of the local pages

enum QuickSetupSession {
    final class LeaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lease: InstanceLease?
        init(_ l: InstanceLease?) { lease = l }
        func release() {
            lock.lock(); let l = lease; lease = nil; lock.unlock()
            // A local settings commit borrowing this lease finishes first.
            if let l { SettingsClient.releaseAfterLocalCommits { l.release() } }
        }
        func reacquire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if lease != nil { return true }
            if case .success(let l) = InstanceLease.acquire(label: "quicksetup") { lease = l; return true }
            return false
        }
        func take() -> InstanceLease? { lock.lock(); defer { lock.unlock() }; let l = lease; lease = nil; return l }
    }

    final class PortBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt16 = 0
        var port: UInt16 {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    static func printPoison(_ p: SetupJobRunner.Poison) {
        print("⚠ a previous step's process could not be confirmed gone:")
        if let u = p.unreadableJournal { print("  \(u)") }
        for s in p.survivors { print("  pid \(s.pid) (start \(s.startTime))\(s.note.map { " — \($0)" } ?? "")") }
        if p.enumerationFailed { print("  (the process table could not be read)") }
        print("  No step can start until it is gone: use the page's Re-check, or `kill` the pid(s) above and re-check.")
    }

    static func openBrowser(_ url: String) {
        if ProcessInfo.processInfo.environment["BRIGLIA_QUICKSETUP_NO_BROWSER"] == "1" { return }
        #if os(macOS)
        _ = ProcessRunner.runBlockingProcess(executable: "/usr/bin/open", args: [url], timeoutSeconds: 10)
        #else
        if let xdg = PlatformBinary.find("xdg-open") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: xdg)
            p.arguments = [url]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        } else if let browser = ProcessInfo.processInfo.environment["BROWSER"], !browser.isEmpty,
                  let path = PlatformBinary.find(browser) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = [url]
            try? p.run()
        } else {
            print("(no browser found — open the link above in a browser on this same machine)")
        }
        #endif
    }
}
