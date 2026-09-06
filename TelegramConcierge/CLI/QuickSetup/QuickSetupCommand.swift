import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - `briglia quicksetup` (plan §3)

struct QuickSetup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quicksetup",
        abstract: "Fast setup: verify and save every key from a page in your browser, then install what Briglia needs."
    )

    func run() async throws {
        AdaCLI.prepareIO()
        try IdentityMigration.gateMutatingEntry()
        IdentityMigration.warnLegacyEnvironment()
        try await QuickSetupSession.runInteractive()
    }
}

/// Preflight refusals (§3.1): exit 2, nothing opened, nothing written.
enum QuickSetupPreflight {
    struct Refusal: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// Selftest seams.
    nonisolated(unsafe) static var isUbuntuTouchOverride: Bool?
    nonisolated(unsafe) static var brewPresentOverride: Bool?
    nonisolated(unsafe) static var pythonOverride: QuickSetupEvidence.PythonStatus?
    nonisolated(unsafe) static var packageManagerOverride: (name: String, present: Bool)?
    nonisolated(unsafe) static var sudoPresentOverride: Bool?
    nonisolated(unsafe) static var systemdSessionOverride: Bool?
    nonisolated(unsafe) static var setupCompleteOverride: Bool?

    /// Runs every refusal check in order; the first failure is thrown.
    static func check(isLinux: Bool = {
        #if os(Linux)
        return true
        #else
        return false
        #endif
    }()) throws {
        if isUbuntuTouchOverride ?? AgentServiceSupport.isUbuntuTouch() {
            throw Refusal("Use the Briglia app's quick setup on this phone.")
        }
        if setupCompleteOverride ?? SetupWizard.setupComplete() {
            throw Refusal("This install is already set up. Use `briglia setup` to change it.")
        }
        // The lease itself is taken by the session (a momentary probe is not
        // exclusion); a held lease surfaces as the §3.1 message there.
        let py = pythonOverride ?? QuickSetupEvidence.pythonStatus()
        if !isLinux {
            if !(brewPresentOverride ?? (ToolchainService.brewPath() != nil)) {
                throw Refusal("Quick setup needs Homebrew: https://brew.sh — then run `briglia quicksetup` again.")
            }
            if !py.present || !py.pipOK {
                throw Refusal("Install the Xcode Command Line Tools (`xcode-select --install`) or `brew install python`.")
            }
        } else {
            let pm: (name: String, present: Bool)
            if let packageManagerOverride { pm = packageManagerOverride } else {
                #if os(Linux)
                pm = ToolchainService.linuxPackageManager().map { ($0.name, true) } ?? ("", false)
                #else
                pm = ("apt-get", true)
                #endif
            }
            let sudo = sudoPresentOverride ?? (PlatformBinary.find("sudo") != nil)
            if !pm.present || !sudo {
                throw Refusal("Quick setup installs the media tools with your package manager and needs sudo.")
            }
            if !py.present || !py.pipOK {
                let pip = LinuxPackageMap.package("pip", manager: pm.name)
                throw Refusal("Install pip first: `sudo \(pm.name == "pacman" ? "pacman -S" : (pm.name == "dnf" ? "dnf install" : "apt install")) \(pip)` (or the equivalent for your distribution).")
            }
            let systemd: Bool
            if let systemdSessionOverride { systemd = systemdSessionOverride } else {
                #if os(Linux)
                systemd = AgentServiceSupport.systemdUserSessionAvailable()
                #else
                systemd = true
                #endif
            }
            if !systemd {
                throw Refusal("Quick setup installs Briglia as a systemd user service, which this system cannot run — use `briglia setup`.")
            }
        }
        // Disk floors on every destination filesystem.
        let checks = diskChecks(isLinux: isLinux)
        if let unreadable = checks.first(where: { $0.unreadable }) {
            throw Refusal("Quick setup cannot read the free space on \(unreadable.path) — a destination it must install into; check that the path exists and is readable, then run `briglia quicksetup` again.")
        }
        if let bad = checks.first(where: { !$0.ok }) {
            throw Refusal("Quick setup needs \(QuickSetupEvidence.formatGB(bad.floorBytes)) free on \(bad.mount); \(QuickSetupEvidence.formatGB(bad.freeBytes)) available.")
        }
        if QuickSetupWorkflow.randomHex() == nil {
            throw Refusal("Cannot generate a secure link on this system.")
        }
        guard Self.pageDirectory() != nil else {
            throw Refusal("resource bundle missing the quick-setup page — reinstall Briglia (scripts/install.sh copies the bundle next to the binary)")
        }
    }

    static func diskChecks(isLinux: Bool) -> [QuickSetupEvidence.DiskCheck] {
        #if os(macOS)
        let brew = ToolchainService.brewPath()
        let prefix = brew.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path }
        return QuickSetupEvidence.diskChecks(targets: QuickSetupEvidence.diskFloorTargets(brewPrefix: prefix, packageCache: nil))
        #else
        let cache = ToolchainService.linuxPackageManager().map { QuickSetupEvidence.packageCacheDirectory(manager: $0.name) }
        return QuickSetupEvidence.diskChecks(targets: QuickSetupEvidence.diskFloorTargets(brewPrefix: nil, packageCache: cache))
        #endif
    }

    nonisolated(unsafe) static var pageDirectoryOverride: URL?
    static func pageDirectory() -> URL? {
        if let pageDirectoryOverride { return pageDirectoryOverride }
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("QuickSetup", isDirectory: true) else { return nil }
        for file in ["index.html", "app.js", "app.css"] where !FileManager.default.fileExists(atPath: url.appendingPathComponent(file).path) {
            return nil
        }
        return url
    }
}

// MARK: - Router (§5.3, §5.4): authorization, same-origin, dispatch

final class QuickSetupRouter: @unchecked Sendable {
    let workflow: QuickSetupWorkflow
    let port: () -> UInt16
    let pageDirectory: URL

    init(workflow: QuickSetupWorkflow, pageDirectory: URL, port: @escaping () -> UInt16) {
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

        switch (request.method, request.path) {
        case ("GET", "/"): return staticFile("index.html", type: "text/html; charset=utf-8")
        case ("GET", "/app.js"): return staticFile("app.js", type: "text/javascript; charset=utf-8")
        case ("GET", "/app.css"): return staticFile("app.css", type: "text/css; charset=utf-8")
        case ("GET", "/api/status"):
            let status = await workflow.status()
            let completed = status["phase"] as? String == "done"
            // Dev-only server-side latency seam: a completed status must survive
            // well past the old 500 ms shutdown window, before any bytes are sent.
            if completed, adaCLIVersion.hasSuffix("-dev"),
               ProcessInfo.processInfo.environment["BRIGLIA_DEV_QUICKSETUP_STUBS"] == "1",
               let raw = ProcessInfo.processInfo.environment["BRIGLIA_DEV_DONE_STATUS_DELAY_MS"],
               let delay = Int(raw), delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(delay, 5000)) * 1_000_000)
            }
            var response = Self.json(200, status)
            response.completesSetup = completed
            return response
        case ("GET", "/api/job"):
            return Self.json(200, await workflow.jobLines(since: 0))
        case ("POST", "/api/job"):
            let offset = (parseBody(request)?["offset"] as? Int) ?? 0
            return Self.json(200, await workflow.jobLines(since: offset))
        case ("POST", "/api/verify"), ("POST", "/api/save"):
            guard let body = parseBody(request) else { return Self.json(400, ["error": "bad_json"]) }
            let typed: QuickSetupRequest
            do { typed = try QuickSetupRequest.parse(body) } catch { return Self.json(400, ["error": "bad_request", "message": "\(error)"]) }
            do {
                let (status, payload) = request.path == "/api/verify"
                    ? try await workflow.verify(typed, generation: g)
                    : try await workflow.save(typed, generation: g)
                return Self.json(status, payload)
            } catch is QuickSetupWorkflow.Superseded {
                return .status(404)
            } catch {
                return Self.json(500, ["error": "internal", "message": "\(error)"])
            }
        case ("POST", "/api/system/run"):
            guard let body = parseBody(request), let row = body["row"] as? String else { return Self.json(400, ["error": "bad_request"]) }
            let option = body["option"] as? String
            do {
                let (status, payload) = try await workflow.systemRun(row: row, option: option, generation: g)
                return Self.json(status, payload)
            } catch { return .status(404) }
        case ("POST", "/api/system/open-settings"):
            do {
                let (status, payload) = try await workflow.openSettings(generation: g)
                return Self.json(status, payload)
            } catch { return .status(404) }
        case ("POST", "/api/finish"):
            do {
                let (status, payload) = try await workflow.finish(generation: g)
                return Self.json(status, payload)
            } catch { return .status(404) }
        case ("POST", "/api/recover/recheck"):
            let (status, payload) = await workflow.recoverRecheck()
            return Self.json(status, payload)
        case ("POST", "/api/stepbystep"):
            do {
                let (status, payload) = try await workflow.stepByStep(generation: g)
                return Self.json(status, payload)
            } catch { return .status(404) }
        default:
            return .status(404)
        }
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

// MARK: - The interactive session

enum QuickSetupSession {
    static var lockFileURL: URL { StoragePaths.dataRoot.appendingPathComponent("quicksetup.lock") }

    /// `quicksetup.lock`: pid, port and a token-free hint. Never a URL.
    static func takeSessionLock() -> Int32? {
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = pread(fd, &buf, buf.count, 0)
            let text = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
            close(fd)
            print("✖ quick setup is already running in another terminal\(text.isEmpty ? "" : " (\(text.trimmingCharacters(in: .whitespacesAndNewlines)))") — press Enter there for a new link.")
            return nil
        }
        return fd
    }

    static func writeSessionLock(fd: Int32, port: UInt16) {
        let text = "pid \(getpid())\nport \(port)\nquick setup is running in another terminal on port \(port); press Enter there for a new link\n"
        _ = ftruncate(fd, 0)
        _ = text.withCString { pwrite(fd, $0, strlen($0), 0) }
    }

    /// Dev builds only (`BRIGLIA_DEV_QUICKSETUP_STUBS=1`): the environment
    /// refusals are stubbed as satisfied so the headless and browser drivers
    /// run on any machine (CI containers have no sudo, no systemd session,
    /// runners no Homebrew). Release builds ignore the variable.
    static func applyPreflightDevStubsIfRequested() {
        guard adaCLIVersion.hasSuffix("-dev"),
              ProcessInfo.processInfo.environment["BRIGLIA_DEV_QUICKSETUP_STUBS"] == "1" else { return }
        QuickSetupPreflight.brewPresentOverride = true
        QuickSetupPreflight.pythonOverride = .init(present: true, pipOK: true)
        QuickSetupPreflight.packageManagerOverride = ("apt-get", true)
        QuickSetupPreflight.sudoPresentOverride = true
        QuickSetupPreflight.systemdSessionOverride = true
        QuickSetupEvidence.statvfsOverride = { _ in (1, "/", 100 * QuickSetupEvidence.gb) }
    }

    static func runInteractive() async throws {
        applyPreflightDevStubsIfRequested()
        do { try QuickSetupPreflight.check() } catch {
            print("✖ \(error)")
            throw ExitCode(2)
        }
        // Progress markers: attempt the directory barrier BEFORE interpreting.
        let progress = KeychainHelper.load(key: SetupWizard.progressKey) ?? ""
        var resume: QuickSetupWorkflow.ResumeMode = .fresh
        if progress.hasPrefix("quick:") {
            var barrierError: String?
            for _ in 0..<3 {
                do { try PrivateStorage.fsyncDirectory(StoragePaths.configRoot.path); barrierError = nil; break } catch { barrierError = "\(error)" }
                Thread.sleep(forTimeInterval: 0.2)
            }
            if let barrierError {
                print("✖ storage barrier failed on \(StoragePaths.configRootDisplay): \(barrierError) — cannot trust the saved progress marker; fix the disk and rerun")
                throw ExitCode(2)
            }
            resume = progress == QuickSetupWorkflow.progressHandoff ? .handoff : .system
        }

        // Lease (§3.2): held for the whole run, except in the constrained
        // handoff resume where the service may hold it.
        var lease: InstanceLease?
        if resume != .handoff {
            switch InstanceLease.acquire(label: "quicksetup") {
            case .success(let l): lease = l
            case .failure:
                print("✖ Stop the running Briglia first: Ctrl-C in its terminal, or `systemctl --user stop briglia`.")
                throw ExitCode(2)
            }
        }
        guard let sessionLockFD = takeSessionLock() else {
            lease?.release()
            throw ExitCode(2)
        }
        defer { close(sessionLockFD) }
        KeepAwake.holdForProcessLifetime()   // the shared reason the keep-awake row verifies

        let runner = SetupJobRunner(secrets: [:])
        runner.onLine = { print("  │ \($0)") }
        if let poison = SetupJobRunner.inheritLeftoverJournal(into: runner) {
            printPoison(poison)
        }
        var env = QuickSetupEnvironment()
        QuickSetupEnvironment.applyDevStubsIfRequested(&env)
        let leaseBox = LeaseBox(lease)
        env.releaseLease = { leaseBox.release() }
        env.reacquireLease = { leaseBox.reacquire() }
        let workflow: QuickSetupWorkflow
        do { workflow = try QuickSetupWorkflow(env: env, runner: runner, resume: resume) } catch {
            print("✖ \(error.localizedDescription)")
            leaseBox.release()
            throw ExitCode(2)
        }
        guard let pageDir = QuickSetupPreflight.pageDirectory() else { throw ExitCode(2) }
        let portBox = PortBox()
        let router = QuickSetupRouter(workflow: workflow, pageDirectory: pageDir) { portBox.port }
        let server = QuickSetupHTTPServer { await router.handle($0) }
        do { try server.start() } catch {
            print("✖ could not start the local page: \(error)")
            leaseBox.release()
            throw ExitCode(2)
        }
        portBox.port = server.port
        writeSessionLock(fd: sessionLockFD, port: server.port)

        let listener = EnterListener {
            Task { await rotateAndPrint(workflow: workflow, port: server.port) }
        }
        runner.listener = listener
        await printLink(workflow: workflow, port: server.port, open: true)
        listener.start()

        // Ctrl-C: cancel the job, stop the server, release, exit.
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigSource.setEventHandler {
            print("\nStopping quick setup… (what was verified and saved is kept)")
            Task {
                _ = await workflow.rotate()   // revoke + cancel + reap before teardown
                server.stop()
                listener.stop()
                leaseBox.release()
                exit(130)
            }
        }
        sigSource.resume()

        // Main loop: wait for done / wizard fallback / idle timeout.
        while true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await workflow.isDone {
                listener.stop()
                _ = await server.waitForCompletionDelivery()
                break
            }
            if await workflow.wizardRequested {
                server.stop(); listener.stop()
                leaseBox.release()
                print("\nContinuing in the terminal with the step-by-step wizard.")
                try await SetupWizard().run()
                return
            }
            if Date().timeIntervalSince(server.lastActivity) > 1800 {
                print("\nNo activity for 30 minutes — stopping quick setup. Run `briglia quicksetup` again to continue.")
                server.stop(); listener.stop(); leaseBox.release()
                throw ExitCode(1)
            }
        }
        server.stop()
        listener.stop()
        sigSource.cancel()
        signal(SIGINT, SIG_DFL)
        unlink(lockFileURL.path)
        printSummaryAndFinish(leaseBox: leaseBox)
        #if os(macOS)
        if let held = leaseBox.take() {
            if WizardIO.askYesNo("Start Briglia now?", default: true) {
                let session = await TerminalSession()
                try await session.runChat(adopting: held)
            } else {
                held.release()
                print("Run `briglia` whenever you want to chat, or `briglia daemon` for Telegram only.")
            }
        }
        #else
        print("Briglia is running as a service. Talk to it on Telegram, or run `briglia` here for a local chat.")
        #endif
    }

    final class LeaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lease: InstanceLease?
        init(_ l: InstanceLease?) { lease = l }
        func release() { lock.lock(); let l = lease; lease = nil; lock.unlock(); l?.release() }
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

    static func printLink(workflow: QuickSetupWorkflow, port: UInt16, open: Bool) async {
        let token = await workflow.launchToken
        guard !token.isEmpty else {
            print("✖ Cannot generate a secure link on this system — the previous link is revoked and no new one can be issued. Stop with Ctrl-C and run `briglia quicksetup` again.")
            return
        }
        let url = "http://127.0.0.1:\(port)/start?t=\(token)"
        print("""

        ── Briglia quick setup ───────────────────────────────────────
        Open this link in a browser ON THIS MACHINE (valid 5 minutes, single use):
          \(url)
        Press Enter here at any time for a new link. Ctrl-C stops (saved values are kept).
        """)
        if open { openBrowser(url) }
    }

    static func rotateAndPrint(workflow: QuickSetupWorkflow, port: UInt16) async {
        if await workflow.consumedByOther {
            print("⚠ that link was already used by something else on this machine — the old session is revoked now.")
        }
        let result = await workflow.rotate()
        if let poison = result.poison { printPoison(poison) }
        await printLink(workflow: workflow, port: port, open: true)
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
        _ = GoogleWorkspaceService.runBlockingProcess(executable: "/usr/bin/open", args: [url], timeoutSeconds: 10)
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

    static func printSummaryAndFinish(leaseBox: LeaseBox) {
        print("\n✔ Quick setup complete.")
        SetupWizard.printSummaryStatic()
    }
}
