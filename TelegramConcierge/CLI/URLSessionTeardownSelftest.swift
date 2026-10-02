import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Linux crash (field report, v0.2.45 on Raspberry Pi OS 13 / libcurl 8.14):
/// SIGABRT "_MultiHandle deallocated with non-zero retain count 2" during web
/// research. Every page read (DeadlineHTTPTransport, v0.2.42+) and every
/// Responses request built its own URLSession and dropped it afterwards; on
/// libcurl 8.14 a URLSession deallocated after an HTTPS keep-alive connection
/// aborts the process inside swift-corelibs-foundation.
///
/// The fix routes those transports through one process-lifetime session
/// (`SharedDataTaskSession`) on Linux. This battery drives the real
/// transports against a loopback server: concurrent reads, deadline cuts,
/// outer cancellation (detach / stop), connect timeouts, redirects, byte
/// caps, a mixed storm, and checks every route is released.
///
/// `--tls-url https://host:port/path` (a TLS keep-alive server the system
/// trusts) adds the crash reproduction itself: rounds of real HTTPS reads,
/// cuts and cancellations whose sessions would be dropped. With
/// `--per-request-sessions` the transports take the old one-session-per-
/// request path (the shipped code, unchanged) — on libcurl 8.14 that run
/// aborts with the field signature; with the fix it completes.
///
/// Isolation: re-executes itself in a private scratch home under a hard link
/// with a reserved test prefix, like `__process-pipe-selftest`.
struct URLSessionTeardownSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__urlsession-teardown-selftest",
        abstract: "Internal: verify delegate transports never drop a URLSession (Linux libcurl 8.14 crash).",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var tlsUrl: String?
    @Option(name: .long, help: .hidden) var tlsRounds: Int = 6
    @Flag(name: .long, help: .hidden) var perRequestSessions = false

    static let linkName = "briglia-mw-urlsession-selftest"
    static let rootPrefix = "briglia-urlsession-"
    static let callBound: TimeInterval = 20

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try reexecIsolated(); return }
        if perRequestSessions { SharedDataTaskSession.disableForTesting = true }
        let failures = await Self.battery(tlsURL: tlsUrl.flatMap(URL.init(string:)), tlsRounds: tlsRounds,
                                          perRequest: perRequestSessions)
        if failures > 0 { throw ExitCode(1) }
    }

    func reexecIsolated() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(Self.rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("BRIGLIA_") || key.hasPrefix("ADA_") || key.hasPrefix("SM_") {
            env.removeValue(forKey: key)
        }
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["XDG_STATE_HOME"] = home + "/.local/state"
        env["XDG_CACHE_HOME"] = home + "/.cache"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(Self.linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        var arguments = ["__urlsession-teardown-selftest", "--child", "--tls-rounds", String(tlsRounds)]
        if let tlsUrl { arguments += ["--tls-url", tlsUrl] }
        if perRequestSessions { arguments.append("--per-request-sessions") }
        process.arguments = arguments
        process.environment = env
        try process.run()
        process.waitUntilExit()
        if TestPrefsDomains.candidatePaths(Self.linkName).contains(where: { fm.fileExists(atPath: $0) }) {
            TestPrefsDomains.purge(Self.linkName)
            TestPrefsDomains.finalSweep()
        }
        if process.terminationReason == .uncaughtSignal {
            print("✖ selftest child killed by signal \(process.terminationStatus)")
            throw ExitCode(128 + process.terminationStatus)
        }
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }

    typealias Check = DiffPipeSelftest.Check

    static func battery(tlsURL: URL?, tlsRounds: Int, perRequest: Bool) async -> Int {
        var total = 0, failures = 0
        let check: Check = { label, ok, detail in
            total += 1
            if !ok { failures += 1 }
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(String(detail.prefix(600)))")")
        }
        if perRequest {
            check("per-request sessions forced (old shipped path)", SharedDataTaskSession.active == nil, "")
        } else {
            pathSelection(check)
            SharedDataTaskSession.forceForTesting = true
        }
        let server: WebFixtureServer
        do { server = try WebFixtureServer() } catch {
            check("loopback server", false, "\(error)"); return failures
        }
        defer { server.stop() }
        server.route = route
        let base = "http://127.0.0.1:\(server.port)"
        let session = SharedDataTaskSession.active?.session
        await concurrentReads(check, base: base)
        await deadlineCuts(check, base: base)
        await outerCancellation(check, base: base)
        await responsesPaths(check, base: base)
        await redirectsAndCaps(check, base: base)
        await mixedStorm(check, base: base)
        if !perRequest {
            check("one session for the whole run", SharedDataTaskSession.active?.session === session && session != nil, "")
            await routesDrained(check)
        }
        if let tlsURL { await tlsTeardown(check, url: tlsURL, rounds: tlsRounds) }
        print("URLSession teardown selftest: \(total - failures)/\(total) passed")
        return failures
    }

    // MARK: - Fixture

    /// /ok/<tag> echoes the tag; /trickle never finishes inside a cut;
    /// /silent answers nothing for a while; /redirect → /ok/redirected;
    /// /big returns 64 KB.
    static let route: @Sendable (WebFixtureServer.Request) -> WebFixtureServer.Response = { request in
        let path = request.path
        if path.hasPrefix("/ok/") { return .init(contentType: "text/plain", body: "echo:" + path.dropFirst(4)) }
        if path.hasPrefix("/trickle") { return .init(contentType: "text/plain", body: "late", trickle: (interval: 0.1, duration: 4)) }
        if path.hasPrefix("/silent") { return .init(contentType: "text/plain", body: "late", silentFor: 4) }
        if path.hasPrefix("/redirect") {
            return .init(status: 302, contentType: "text/plain", body: "moved", headers: ["Location": "/ok/redirected"])
        }
        if path.hasPrefix("/big") { return .init(contentType: "text/plain", body: String(repeating: "b", count: 65536)) }
        return .init(status: 404, body: "{}")
    }

    static func get(_ url: String, timeout: TimeInterval = 10) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = timeout
        return request
    }

    static func bounded<T: Sendable>(_ op: @escaping @Sendable () async -> T) async -> (value: T?, elapsed: TimeInterval) {
        await DiffPipeSelftest.bounded(callBound, op)
    }

    enum Outcome: Sendable, Equatable { case body(String), cut, cancelled, timedOut, http(Int), other(String) }

    static func classify(_ error: Error) -> Outcome {
        if error is CancellationError { return .cancelled }
        if error is ExtractorDeadlineExceeded { return .cut }
        if let urlError = error as? URLError, urlError.code == .timedOut { return .timedOut }
        if case ResponsesFailure.http(let status, _) = error { return .http(status) }
        return .other("\(error)")
    }

    static func deadlineRead(_ url: String, seconds: TimeInterval = 10) async -> Outcome {
        let deadline = ExtractorDeadline(seconds: seconds, readsGenerationHeaders: false)
        do {
            let (data, response) = try await deadline.fetch(get(url))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200 ? .body(String(decoding: data, as: UTF8.self)) : .http(status)
        } catch { return classify(error) }
    }

    static func responsesRead(_ url: String, overall: TimeInterval = 10, connect: TimeInterval? = nil) async -> Outcome {
        do {
            let data = try await ResponsesHTTPTransport().send(get(url, timeout: overall), overallTimeout: overall,
                                                                connectTimeout: connect, idleTimeout: overall)
            return .body(String(decoding: data, as: UTF8.self))
        } catch { return classify(error) }
    }

    // MARK: - Rows

    static func pathSelection(_ check: Check) {
        #if canImport(FoundationNetworking)
        check("Linux: delegate transports use the shared session", SharedDataTaskSession.active != nil, "")
        #else
        check("macOS: per-request sessions unchanged by default", SharedDataTaskSession.active == nil, "")
        #endif
    }

    static func concurrentReads(_ check: Check, base: String) async {
        let result = await bounded {
            await withTaskGroup(of: (Int, Outcome).self) { group -> [Int: Outcome] in
                for i in 0..<32 { group.addTask { (i, await deadlineRead("\(base)/ok/r\(i)")) } }
                var all: [Int: Outcome] = [:]
                for await (i, outcome) in group { all[i] = outcome }
                return all
            }
        }
        let all = result.value ?? [:]
        let wrong = (0..<32).filter { all[$0] != .body("echo:r\($0)") }
        check("32 concurrent page reads complete with their own bodies", result.value != nil && wrong.isEmpty,
              "wrong=\(wrong.prefix(5)) sample=\(wrong.first.flatMap { all[$0] }.map { "\($0)" } ?? "-")")
    }

    static func deadlineCuts(_ check: Check, base: String) async {
        let result = await bounded {
            await withTaskGroup(of: Outcome.self) { group -> [Outcome] in
                for i in 0..<8 { group.addTask { await deadlineRead("\(base)/trickle/\(i)", seconds: 0.4) } }
                var all: [Outcome] = []
                for await outcome in group { all.append(outcome) }
                return all
            }
        }
        let all = result.value ?? []
        check("8 concurrent reads cut at a 0.4 s deadline", all.count == 8 && all.allSatisfy { $0 == .cut } && result.elapsed < 3,
              "outcomes=\(all) elapsed=\(result.elapsed)")
        let fresh = await bounded { await deadlineRead("\(base)/ok/after-cut") }
        check("a read after the cuts still succeeds", fresh.value == .body("echo:after-cut"), "\(String(describing: fresh.value))")
    }

    static func outerCancellation(_ check: Check, base: String) async {
        let result = await bounded { () -> [Outcome] in
            let tasks = (0..<6).map { i in
                Task { await (i % 2 == 0 ? deadlineRead("\(base)/silent/d\(i)") : responsesRead("\(base)/silent/r\(i)")) }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            tasks.forEach { $0.cancel() }
            var all: [Outcome] = []
            for task in tasks { all.append(await task.value) }
            return all
        }
        let all = result.value ?? []
        check("6 open requests cancelled mid-flight (detach / stop) end promptly",
              all.count == 6 && all.allSatisfy { $0 == .cancelled } && result.elapsed < 3,
              "outcomes=\(all) elapsed=\(result.elapsed)")
    }

    static func responsesPaths(_ check: Check, base: String) async {
        let ok = await bounded { await responsesRead("\(base)/ok/resp") }
        check("Responses transport returns the body", ok.value == .body("echo:resp"), "\(String(describing: ok.value))")
        let slow = await bounded { await responsesRead("\(base)/silent/connect", overall: 10, connect: 0.3) }
        check("Responses connect timeout still fires", slow.value == .timedOut && slow.elapsed < 3,
              "\(String(describing: slow.value)) elapsed=\(slow.elapsed)")
    }

    static func redirectsAndCaps(_ check: Check, base: String) async {
        let follow = await bounded { await deadlineRead("\(base)/redirect/d") }
        check("page reads follow redirects (session default)", follow.value == .body("echo:redirected"), "\(String(describing: follow.value))")
        let refuse = await bounded { await responsesRead("\(base)/redirect/r") }
        check("Responses refuses redirects", refuse.value == .http(302), "\(String(describing: refuse.value))")
        let fetched = await bounded { () -> String in
            do { return String(decoding: try await BoundedHTTP.fetchData(url: URL(string: "\(base)/ok/release")!, maxBytes: 1024), as: UTF8.self) }
            catch { return "error: \(error)" }
        }
        check("release fetch returns the body", fetched.value == "echo:release", "\(String(describing: fetched.value))")
        let capped = await bounded { () -> String in
            do { _ = try await BoundedHTTP.fetchData(url: URL(string: "\(base)/big")!, maxBytes: 1024); return "accepted" }
            catch { return "\(error.localizedDescription)" }
        }
        check("release fetch byte cap still refuses", capped.value?.contains("1024-byte limit") == true, "\(String(describing: capped.value))")
    }

    static func mixedStorm(_ check: Check, base: String) async {
        let result = await bounded { () -> [String] in
            var bad: [String] = []
            for round in 0..<5 {
                let outcomes = await withTaskGroup(of: (String, Outcome, Bool).self) { group -> [(String, Outcome, Bool)] in
                    for i in 0..<24 {
                        let tag = "s\(round)-\(i)"
                        switch i % 4 {
                        case 0: group.addTask { (tag, await deadlineRead("\(base)/ok/\(tag)"), true) }
                        case 1: group.addTask { (tag, await deadlineRead("\(base)/trickle/\(tag)", seconds: Double.random(in: 0.05...0.3)), true) }
                        case 2: group.addTask { (tag, await responsesRead("\(base)/ok/\(tag)"), true) }
                        default:
                            group.addTask {
                                let task = Task { await deadlineRead("\(base)/silent/\(tag)") }
                                try? await Task.sleep(nanoseconds: UInt64.random(in: 10_000_000...150_000_000))
                                task.cancel()
                                return (tag, await task.value, true)
                            }
                        }
                    }
                    var all: [(String, Outcome, Bool)] = []
                    for await item in group { all.append(item) }
                    return all
                }
                for (tag, outcome, _) in outcomes {
                    let index = Int(tag.split(separator: "-").last!)!
                    let expected: Outcome = [0, 2].contains(index % 4) ? .body("echo:\(tag)") : (index % 4 == 1 ? .cut : .cancelled)
                    if outcome != expected { bad.append("\(tag)=\(outcome)") }
                }
            }
            return bad
        }
        check("mixed storm: 5 rounds × 24 reads / cuts / Responses / cancels", result.value?.isEmpty == true,
              "bad=\(result.value.map { Array($0.prefix(6)) } ?? ["timed out"])")
    }

    static func routesDrained(_ check: Check) async {
        let shared = SharedDataTaskSession.shared
        var remaining = shared.routedTaskCount
        for _ in 0..<60 where remaining > 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            remaining = shared.routedTaskCount
        }
        check("every routed task released (no leaked delegates)", remaining == 0, "still routed: \(remaining)")
    }

    /// The crash reproduction: real HTTPS keep-alive connections, then the
    /// requests' sessions (old path) are dropped. Old path on libcurl 8.14:
    /// SIGABRT before the summary line.
    static func tlsTeardown(_ check: Check, url: URL, rounds: Int) async {
        let target = url.absoluteString
        var outcomes: [Outcome] = []
        for round in 0..<rounds {
            let batch = await withTaskGroup(of: Outcome.self) { group -> [Outcome] in
                for i in 0..<12 {
                    switch i % 4 {
                    case 0, 1: group.addTask { await deadlineRead(target) }
                    case 2: group.addTask { await responsesRead(target) }
                    default:
                        group.addTask {
                            do { _ = try await BoundedHTTP.fetchData(url: url, maxBytes: 1 << 20); return .body("bounded") }
                            catch { return classify(error) }
                        }
                    }
                }
                var all: [Outcome] = []
                for await outcome in group { all.append(outcome) }
                return all
            }
            outcomes += batch
            print("  tls round \(round + 1)/\(rounds): \(batch.filter { if case .body = $0 { return true }; return false }.count)/\(batch.count) answered")
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        // Give any dropped session time to be torn down.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let answered = outcomes.filter { if case .body = $0 { return true }; return false }.count
        check("TLS keep-alive rounds survive session teardown (\(answered)/\(outcomes.count) answered)",
              answered == outcomes.count, "outcomes=\(outcomes.filter { if case .body = $0 { return false }; return true }.prefix(4))")
    }
}
