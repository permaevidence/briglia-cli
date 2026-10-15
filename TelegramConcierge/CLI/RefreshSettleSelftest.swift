import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Refresh-and-settle (SIWC plan §7, §7.1; Briglia 0.2.54): `/stop` during a
/// ChatGPT-subscription token refresh, crashes between exchange and save,
/// concurrent processes, logout races and the once-only recovery retry.
///
/// Everything runs against the real legacy `SubscriptionAuthStore` and the
/// real `SubscriptionLogin.refresh`, with only the token endpoint replaced by
/// a file-backed fake shared across processes. The suite deliberately uses
/// only the store's public surface plus the raw JSON on disk, so the same
/// source also builds against the 0.2.53 store as the baseline control.
struct RefreshSettleSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__refresh-settle-selftest", abstract: "Internal refresh-settlement tests", shouldDisplay: false)
    @Option var worker: String?
    @Option var server: String?
    @Option var mode: String = "refresh"

    typealias Checks = SubscriptionSelftest.Checks

    func run() async throws {
        AdaCLI.prepareIO()
        guard adaCLIVersion.hasSuffix("-dev") else { throw ValidationError("Development build required") }
        if let worker, let server {
            try await Self.workerMain(store: URL(fileURLWithPath: worker), server: URL(fileURLWithPath: server), mode: mode)
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-refresh-settle-\(UUID())")
        for (key, directory) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(directory).path, 1)
        }
        try PrivateStorage.ensureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = Checks()
        let h = Harness(root: root)
        try await cancelTests(h, c)
        try await crashTests(h, c)
        try await retryTests(h, c)
        try await processTests(h, c)
        try await writeFailureTests(h, c)
        try await logoutTests(h, c)
        try await checkpointTests(h, c)
        print("Refresh-settle selftest: \(c.total - c.failed)/\(c.total)")
        if c.failed > 0 { throw ExitCode.failure }
    }
}

// MARK: - Harness

extension RefreshSettleSelftest {
    /// One isolated (store, fake token endpoint) pair per scenario.
    struct Scenario {
        let store: SubscriptionAuthStore
        let server: FakeTokenServer
        let generation: String
    }

    final class Harness {
        let root: URL
        init(root: URL) { self.root = root }
        func scenario(_ name: String, script: [String] = [], lenient: Bool = false) async throws -> Scenario {
            let base = root.appendingPathComponent(name)
            let store = SubscriptionAuthStore(directory: base.appendingPathComponent("auth"))
            let server = FakeTokenServer(directory: base.appendingPathComponent("server"))
            try server.reset(current: "r0", script: script, lenient: lenient)
            let pending = try await store.beginLogin()
            var expired = SubscriptionSelftest.credential(expired: true); expired.refresh = "r0"
            let generation = try await store.commitLogin(expired, pending: pending)
            return Scenario(store: store, server: server, generation: generation)
        }
    }

    /// The real refresh function with the token endpoint replaced.
    static func login(_ s: Scenario, store: SubscriptionAuthStore? = nil, fault: WriteFault? = nil) -> SubscriptionLogin {
        var login = SubscriptionLogin(store: store ?? s.store)
        let server = s.server
        login.post = { path, fields, _ in
            guard path == "/oauth/token", fields["grant_type"] == "refresh_token", let token = fields["refresh_token"] else {
                throw SubscriptionError("unexpected auth request in refresh test")
            }
            let reply = try await server.handle(token)
            if reply.1 == 200 { fault?.markExchanged() }
            return reply
        }
        return login
    }

    @discardableResult
    static func refresh(_ s: Scenario, store: SubscriptionAuthStore? = nil, fault: WriteFault? = nil, rejected: String? = nil) async throws -> SubscriptionCredential {
        let login = login(s, store: store, fault: fault)
        return try await login.store.credential(generation: s.generation, rejectedAccess: rejected, refresh: login.refresh)
    }

    static func outcome(_ s: Scenario, store: SubscriptionAuthStore? = nil, fault: WriteFault? = nil) async -> String {
        do { return "ok:" + (try await refresh(s, store: store, fault: fault)).refresh } catch { return "error:" + error.localizedDescription }
    }

    /// The raw on-disk record (new keys included), read without the store's
    /// typed model so the suite builds against any store version.
    static func disk(_ store: SubscriptionAuthStore) -> [String: Any] {
        guard let data = try? Data(contentsOf: store.file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    static func diskRefresh(_ store: SubscriptionAuthStore) -> String? { (disk(store)["credential"] as? [String: Any])?["refresh"] as? String }
    static func diskBlocked(_ store: SubscriptionAuthStore) -> Bool { disk(store)["requiresLogin"] as? Bool == true }

    /// Waits until any in-flight (detached) settle has released the lock.
    static func settled(_ store: SubscriptionAuthStore) async throws { try await store.locked {} }

    static func tokenData(refresh: String, account: String = "account-A") throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": account]]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["access_token": "header." + claims + ".sig-" + refresh,
                                                           "refresh_token": refresh, "expires_in": 3600])
    }

    static func spawn(_ s: Scenario, mode: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["__refresh-settle-selftest", "--worker", s.store.directory.path, "--server", s.server.directory.path, "--mode", mode]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
    static func join(_ processes: [Process]) async throws {
        while processes.contains(where: { $0.isRunning }) { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// Worker process: one refresh against the shared store and fake server.
    /// `exit-after-exchange-N` dies (no cleanup) at the N-th store write
    /// after the 200 arrived, as a crash between exchange and save would.
    static func workerMain(store directory: URL, server: URL, mode: String) async throws {
        var store = SubscriptionAuthStore(directory: directory)
        let generation = try store.read()!.generation
        let s = Scenario(store: store, server: FakeTokenServer(directory: server), generation: generation)
        let fault = WriteFault()
        if mode.hasPrefix("exit-after-exchange-"), let n = Int(mode.dropFirst("exit-after-exchange-".count)) {
            fault.actions[n] = .exit
        }
        store.beforeWrite = { try fault.before() }
        _ = await outcome(s, store: store, fault: fault)
    }
}

/// Fault injection on the store's write hooks, counted only after the token
/// endpoint returned 200 (writes 1, 2, … after the exchange).
final class WriteFault: @unchecked Sendable {
    enum Action { case exit, throwBefore, throwAfter }
    private let lock = NSLock()
    private var exchanged = false
    private var index = 0
    var actions: [Int: Action] = [:]
    func markExchanged() { lock.lock(); exchanged = true; lock.unlock() }
    func before() throws {
        lock.lock(); guard exchanged else { lock.unlock(); return }
        index += 1; let action = actions[index]; lock.unlock()
        if action == .exit { _exit(0) }
        if action == .throwBefore { throw SubscriptionError("injected write failure") }
    }
    func after() throws {
        lock.lock(); let action = exchanged ? actions[index] : nil; lock.unlock()
        if action == .throwAfter { throw SubscriptionError("injected parent fsync failure") }
    }
}

/// A token endpoint shared by every process of a scenario (JSON file under
/// flock). It rotates on receipt, like the real server: the old refresh
/// token is dead once the request reached it, whatever happens to the reply.
/// `strict` (default) answers a rotated-away token with invalid_grant;
/// `lenient` accepts one once, as P10 observed on the live route.
struct FakeTokenServer {
    let directory: URL
    var stateFile: URL { directory.appendingPathComponent("server.json") }
    var lockFile: URL { directory.appendingPathComponent("server.lock") }

    struct State: Codable {
        var current: String
        var script: [String]
        var lenient: Bool
        var retired: [String] = []
        var reused: [String] = []
        var sent: [String] = []
        var serial = 0
    }

    func reset(current: String, script: [String], lenient: Bool) throws {
        try PrivateStorage.ensureDirectory(directory)
        try save(State(current: current, script: script, lenient: lenient))
    }
    func load() throws -> State { try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile)) }
    private func save(_ state: State) throws { _ = try PrivateStorage.writeAtomically(try JSONEncoder().encode(state), to: stateFile) }
    func sends() -> Int { (try? load().sent.count) ?? -1 }
    func current() -> String { (try? load().current) ?? "" }

    private func exclusive<T>(_ body: (inout State) throws -> T) throws -> T {
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SubscriptionError("fake server lock") }
        defer { close(fd) }
        flock(fd, LOCK_EX); defer { flock(fd, LOCK_UN) }
        var state = try load()
        let result = try body(&state)
        try save(state)
        return result
    }

    /// Behaviours (consumed per send, default `rotate`):
    /// rotate · slow (rotate, then 400 ms ignoring cancellation) ·
    /// slow-cancellable (rotate, then a cancellable 400 ms) · lost (rotate,
    /// then the reply is lost: network error) · timeout (never reached the
    /// server: network error) · lost-slow (rotate, 300 ms, then lost) ·
    /// http503 · rotated-504 (rotate, then a gateway 504) · other-account
    /// (rotate, reply names another account) · invalid (explicit invalid_grant) · exit-sent (rotate, then the process dies) · exit-early (the
    /// process dies before the request reaches the server).
    func handle(_ token: String) async throws -> (Data, Int) {
        let (behaviour, reply): (String, (Data, Int)) = try exclusive { state in
            let behaviour = state.script.isEmpty ? "rotate" : state.script.removeFirst()
            state.sent.append(token)
            if ["exit-early", "timeout", "http503", "invalid"].contains(behaviour) { return (behaviour, (Data(), 0)) }
            let accepted: Bool
            if token == state.current { accepted = true }
            else if state.lenient, state.retired.contains(token), !state.reused.contains(token) { state.reused.append(token); accepted = true }
            else { accepted = false }
            guard accepted else { return (behaviour, (Data(#"{"error":"invalid_grant"}"#.utf8), 400)) }
            state.serial += 1
            let next = "r\(state.serial)-\(UUID().uuidString.prefix(8))"
            state.retired.append(state.current)
            state.current = next
            return (behaviour, (try RefreshSettleSelftest.tokenData(refresh: next, account: behaviour == "other-account" ? "account-B" : "account-A"), 200))
        }
        switch behaviour {
        case "exit-early", "exit-sent": _exit(0)
        case "timeout": throw SubscriptionError("Authentication network request failed; retry login")
        case "invalid": return (Data(#"{"error":"invalid_grant"}"#.utf8), 400)
        case "http503": return (Data(#"{"error":"temporarily_unavailable"}"#.utf8), 503)
        case "rotated-504": return (Data("gateway timeout".utf8), 504)
        case "lost": throw SubscriptionError("Authentication network request failed; retry login")
        case "lost-slow":
            usleep(300_000)
            throw SubscriptionError("Authentication network request failed; retry login")
        case "slow": usleep(400_000)
        case "slow-cancellable": try await Task.sleep(nanoseconds: 400_000_000)
        default: break
        }
        return reply
    }
}

actor RefreshTestGate {
    private(set) var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func markStarted() { started = true }
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters = [] }
}
