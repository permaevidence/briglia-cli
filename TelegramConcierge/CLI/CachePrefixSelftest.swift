import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Step 0 of the cache diagnosis (private-docs plan
/// CACHE_KEY_AND_IMAGE_REJECTION_PLAN v2 §1.4, Codex round 2 answer 5): the
/// real main-agent request bodies of long scripted sessions (both
/// protocols) are captured and checked with `CacheDiagnostics.check`.
/// Class A: between two requests with no recorded transition, the system
/// text, the tools (in order), the settings and every input item before the
/// previous request's documented tail are identical by position. Class B:
/// archive commit, prune, active-turn compaction, a tool-exposure change and
/// the next turn change the prefix only within their own scope; native
/// replay eviction at the replay-byte bound is a recorded transition.
/// Also the opt-in request log (BRIGLIA_CACHE_DIAGNOSTICS=1).
/// Re-executes itself in a private scratch home and preference domain.
struct CachePrefixSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__cache-prefix-selftest",
        abstract: "Internal: verify request-prefix stability (cache Step 0) and the diagnostics log.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-cacheprefix"
    static let rootPrefix = "briglia-cache-prefix-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = MidturnHarness(only: only)
        try await h.runCachePrefix()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) cache prefix check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) cache prefix checks passed")
    }

    static func reexecIsolated(only: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        env.removeValue(forKey: CacheDiagnostics.environmentKey)
        env.removeValue(forKey: ForceDetach.environmentKey)
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__cache-prefix-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// Scripted provider for long sessions: maintenance requests (no tools:
/// archive, user context) go to the archive router; active-turn compaction
/// and prune-summary requests get a summary; every main request takes the
/// next queued step (tool calls or a final text), or, in "read until
/// compaction" mode, reads a large file until a compaction ran.
final class CPScript: @unchecked Sendable {
    typealias Call = (id: String, name: String, args: [String: Any])
    private let lock = NSLock()
    let responses: Bool
    let archive = BAArchiveRouter()
    private var steps: [(calls: [Call], text: String?)] = []
    private var _main = 0
    private var _compactions = 0
    private var _maintenance = 0
    var readUntilCompaction: String?
    var onMainRequest: ((Int) -> Void)?

    init(responses: Bool) { self.responses = responses }

    var mainRequests: Int { lock.lock(); defer { lock.unlock() }; return _main }
    var compactions: Int { lock.lock(); defer { lock.unlock() }; return _compactions }
    var remaining: Int { lock.lock(); defer { lock.unlock() }; return steps.count }

    func push(_ calls: [Call]) { lock.lock(); steps.append((calls, nil)); lock.unlock() }
    func pushText(_ text: String) { lock.lock(); steps.append(([], text)); lock.unlock() }

    func route(_ request: CapturedHTTPRequest) -> (body: String, delay: TimeInterval)? {
        let text = String(decoding: request.body, as: UTF8.self)
        let tokens = max(100, request.body.count / 3)
        func reply(_ t: String?, _ calls: [Call]) -> (body: String, delay: TimeInterval) {
            (MidturnHarness.CompactionScript.reply(responses: responses, text: t, calls: calls, tokens: tokens), 0.01)
        }
        if text.contains("ACTIVE TURN COMPACTION") {
            lock.lock(); _compactions += 1; lock.unlock()
            return reply("Goal: keep working. Progress summarized.", [])
        }
        if text.contains("[PRUNE SUMMARY") { return reply("Earlier work summarized.", []) }
        if let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any], object["tools"] == nil {
            guard responses else { return archive.route(request) }
            // Responses-shaped maintenance replies (archive summaries, fact
            // extraction with nothing new).
            lock.lock(); _maintenance += 1; let n = _maintenance; lock.unlock()
            return reply(text.contains(ArchiveFullChunkSelftest.extractionMarker) ? "NO_CHANGES" : BAArchiveRouter.summaryText(n), [])
        }
        lock.lock()
        _main += 1
        let n = _main
        let callback = onMainRequest
        let large = readUntilCompaction
        let compacted = _compactions > 0
        var step: (calls: [Call], text: String?)? = nil
        if let large, !compacted, n < 400 {
            step = ([(id: "rc\(n)", name: "read_file", args: ["path": large, "limit": 200])], nil)
        } else if !steps.isEmpty {
            step = steps.removeFirst()
        }
        lock.unlock()
        callback?(n)
        guard let step else { return reply("CP_UNSCRIPTED", []) }
        return reply(step.text, step.calls)
    }
}

extension MidturnHarness {

    func runCachePrefix() async throws {
        let data = StoragePaths.dataRoot.path
        guard data.contains(CachePrefixSelftest.rootPrefix),
              ProcessInfo.processInfo.processName == CachePrefixSelftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        TurnWakeCenter.graceSecondsForTesting = 0.6
        MidturnWakeSignal.forcedDelaySecondsForTesting = 0.8
        server = try CaptureServer()
        defer { server.stop() }
        try configureProvider()
        if section("unit") { cpUnitSection() }
        if section("steady") { try await cpSteadySection() }
        if section("transitions") { try await cpTransitionSection() }
        if section("log") { try await cpLogSection() }
        if section("tail") { cpTailSection() }
    }

    /// Captured main-lane requests while `body` runs.
    final class CPCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [CacheDiagnostics.Request] = []
        var all: [CacheDiagnostics.Request] { lock.lock(); defer { lock.unlock() }; return _all }
        var main: [CacheDiagnostics.Request] { all.filter { $0.lane == "main" } }
        func add(_ r: CacheDiagnostics.Request) { lock.lock(); _all.append(r); lock.unlock() }
    }

    func cpStart(responses: Bool) async throws -> (ConversationManager, CPScript, CPCapture, () -> Void) {
        let restore: () -> Void = responses ? try useResponses() : {}
        CacheDiagnostics.reset()
        let manager = await freshManager()
        let script = CPScript(responses: responses)
        server.concurrent = false
        server.router = { script.route($0) }
        let capture = CPCapture()
        CacheDiagnostics.captureForTesting = { capture.add($0) }
        return (manager, script, capture, {
            CacheDiagnostics.captureForTesting = nil
            self.server.router = nil
            restore()
        })
    }

    func cpTurn(_ manager: ConversationManager, _ text: String, timeout: TimeInterval = 120) async {
        manager._testStartTurn(for: user(text))
        _ = await manager._testAwaitIdle(timeout: timeout)
    }

    func cpReport(_ label: String, _ result: CacheDiagnostics.CheckResult) {
        for finding in result.findings.prefix(6) { print("    finding: \(finding)") }
        for t in result.classBTransitions { print("    transition at request \(t.request): \(t.reasons.joined(separator: "+")) — first change: \(t.first)") }
    }
}
