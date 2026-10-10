import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden battery for the persona snapshot (v0.2.53 plan §2): one persona
/// (assistant name, user name, structured profile, prior name) per main turn
/// and per subagent run. A profile written while a turn or run is active —
/// background archive fact extraction, a profile-maintenance CAS commit, a
/// direct store write — changes neither the system prompt nor any local
/// estimate of that turn or run; the next one adopts it. Rows P1–P9 drive
/// the real manager and SubagentRunner against a scripted loopback provider.
///
/// Isolation: re-executes itself in a private scratch home (HOME,
/// XDG_CONFIG_HOME, XDG_DATA_HOME, CFFIXED_USER_HOME, TMPDIR) under a
/// differently named hard link, like the image-rejection battery. Every
/// profile string is a synthetic sentinel found only in the profile store.
struct PersonaSnapshotSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__persona-snapshot-selftest",
        abstract: "Internal: verify one persona snapshot per turn and per subagent run.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-persona"
    static let rootPrefix = "briglia-persona-snapshot-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = MidturnHarness(only: only)
        try await h.runPersonaSnapshot()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) persona snapshot check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) persona snapshot checks passed")
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
        env.removeValue(forKey: RoundDelivery.environmentKey)
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__persona-snapshot-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// Scripted provider for the persona rows. Maintenance requests (archive
/// summaries, fact extraction, profile maintenance) get configurable
/// replies; prune-summary and active-turn compaction requests get a summary
/// (optionally an empty, rejected first reply so the retry runs); every
/// main request takes the next queued step, or — in "read until compaction"
/// mode — reads a large file until a compaction ran, then `fallbackCall`.
final class PPRouter: @unchecked Sendable {
    typealias Call = (id: String, name: String, args: [String: Any])
    static let maintenanceMarker = "You maintain the user profile"
    private let lock = NSLock()
    let responses: Bool
    private var steps: [(calls: [Call], text: String?)] = []
    private var _main = 0, _compactions = 0, _prunes = 0, _extractions = 0, _maintenance = 0, _archive = 0
    private var _extractionReply = "NO_CHANGES"
    private var _maintenanceReply = "{}"
    private var _rejectFirstPrune = false
    private var _rejectFirstCompaction = false
    private var _readUntilCompaction: String?
    private var _fallbackCall: Call?
    private var _onMain: ((Int, String) -> Void)?

    init(responses: Bool) { self.responses = responses }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var mainRequests: Int { locked { _main } }
    var compactions: Int { locked { _compactions } }
    var prunes: Int { locked { _prunes } }
    var extractions: Int { locked { _extractions } }
    var maintenanceRequests: Int { locked { _maintenance } }
    var extractionReply: String { get { locked { _extractionReply } } set { locked { _extractionReply = newValue } } }
    var maintenanceReply: String { get { locked { _maintenanceReply } } set { locked { _maintenanceReply = newValue } } }
    var rejectFirstPrune: Bool { get { locked { _rejectFirstPrune } } set { locked { _rejectFirstPrune = newValue } } }
    var rejectFirstCompaction: Bool { get { locked { _rejectFirstCompaction } } set { locked { _rejectFirstCompaction = newValue } } }
    var readUntilCompaction: String? { get { locked { _readUntilCompaction } } set { locked { _readUntilCompaction = newValue } } }
    var fallbackCall: Call? { get { locked { _fallbackCall } } set { locked { _fallbackCall = newValue } } }
    var onMain: ((Int, String) -> Void)? { get { locked { _onMain } } set { locked { _onMain = newValue } } }

    func push(_ calls: [Call]) { locked { steps.append((calls, nil)) } }
    func pushText(_ text: String) { locked { steps.append(([], text)) } }

    func route(_ request: CapturedHTTPRequest) -> (body: String, delay: TimeInterval)? {
        let text = String(decoding: request.body, as: UTF8.self)
        let tokens = max(100, request.body.count / 3)
        func reply(_ t: String?, _ calls: [Call]) -> (body: String, delay: TimeInterval) {
            (MidturnHarness.CompactionScript.reply(responses: responses, text: t, calls: calls, tokens: tokens), 0.01)
        }
        if text.contains("ACTIVE TURN COMPACTION") {
            let (n, reject) = locked { _compactions += 1; return (_compactions, _rejectFirstCompaction) }
            return reply(reject && n == 1 ? "" : "Goal: keep reading the file. Progress summarized.", [])
        }
        if text.contains("[PRUNE SUMMARY") {
            let (n, reject) = locked { _prunes += 1; return (_prunes, _rejectFirstPrune) }
            return reply(reject && n == 1 ? "" : "Earlier work summarized.", [])
        }
        if text.contains(Self.maintenanceMarker) {
            let r = locked { _maintenance += 1; return _maintenanceReply }
            return reply(r, [])
        }
        if text.contains(ArchiveFullChunkSelftest.extractionMarker) {
            let r = locked { _extractions += 1; return _extractionReply }
            return reply(r, [])
        }
        if let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any], object["tools"] == nil {
            let n = locked { _archive += 1; return _archive }
            return reply(BAArchiveRouter.summaryText(n), [])
        }
        lock.lock()
        _main += 1
        let n = _main
        let callback = _onMain
        var step: (calls: [Call], text: String?)? = nil
        if let large = _readUntilCompaction, _compactions == 0, n < 300 {
            step = ([(id: "rc\(n)", name: "read_file", args: ["path": large, "limit": 200])], nil)
        } else if !steps.isEmpty {
            step = steps.removeFirst()
        } else if let fallback = _fallbackCall {
            step = ([(id: "\(fallback.id)\(n)", name: fallback.name, args: fallback.args)], nil)
        }
        lock.unlock()
        callback?(n, text)
        guard let step else { return reply("PP_UNSCRIPTED", []) }
        return reply(step.text, step.calls)
    }
}

/// Captured requests (with their diagnostics lane) and local estimates.
final class PPCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(lane: String, body: Data)] = []
    private var _estimates: [String] = []
    private var _scopeResets = 0
    var requests: [(lane: String, body: Data)] { lock.lock(); defer { lock.unlock() }; return _requests }
    var estimates: [String] { lock.lock(); defer { lock.unlock() }; return _estimates }
    var scopeResets: Int { lock.lock(); defer { lock.unlock() }; return _scopeResets }
    func add(_ r: CacheDiagnostics.Request) { lock.lock(); _requests.append((r.lane, r.body)); lock.unlock() }
    func estimate(_ s: String) { lock.lock(); _estimates.append(s); lock.unlock() }
    func reset() { lock.lock(); _scopeResets += 1; lock.unlock() }
    /// Marks the current counts so later reads can look at what follows.
    func mark() -> (requests: Int, estimates: Int) { lock.lock(); defer { lock.unlock() }; return (_requests.count, _estimates.count) }
    func main(since mark: Int = 0) -> [Data] {
        requests.dropFirst(mark).filter { $0.lane == "main" || $0.lane.hasPrefix("main#") }.map(\.body)
    }
    func lane(_ prefix: String, since mark: Int = 0) -> [Data] {
        requests.dropFirst(mark).filter { $0.lane.hasPrefix(prefix) }.map(\.body)
    }
}

extension MidturnHarness {

    func runPersonaSnapshot() async throws {
        let data = StoragePaths.dataRoot.path
        guard data.contains(PersonaSnapshotSelftest.rootPrefix),
              ProcessInfo.processInfo.processName == PersonaSnapshotSelftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        TurnWakeCenter.graceSecondsForTesting = 0.6
        MidturnWakeSignal.forcedDelaySecondsForTesting = 0.8
        server = try CaptureServer()
        defer { server.stop() }
        try configureProvider()
        if section("unit") { await ppUnitSection() }
        if section("background") { try await ppBackgroundSection() }
        if section("writers") { try await ppWritersSection() }
        if section("writers") { try await ppFirstRetirementSection() }
        if section("inline") { try await ppInlineSection() }
        if section("compaction") { try await ppCompactionSection() }
        if section("compaction") { try await ppInitialPruneSection() }
        if section("midloop") { try await ppMidLoopPruneSection() }
        if section("subagent") { try await ppSubagentSection() }
        if section("privacy") { try await ppPrivacySection() }
        if section("restart") { try await ppRestartSection() }
        if section("mind") { try await ppMindSection() }
    }

    // MARK: Shared helpers

    nonisolated static func ppSentinel(_ tag: String) -> String { "PERSONA-SENTINEL-\(tag)-\(UUID().uuidString)" }

    /// A profile made of `facts` synthetic lines, each carrying `sentinel`.
    nonisolated static func ppProfile(_ sentinel: String, facts: Int = 3) -> String {
        (["# Profile"] + (0..<facts).map { "- \(sentinel) fact \($0): prefers synthetic fixture number \($0)." }).joined(separator: "\n")
    }

    func ppSetProfile(_ text: String?) throws {
        if let text { try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: text) }
        else { try? KeychainHelper.delete(key: KeychainHelper.structuredUserContextKey) }
    }

    /// The FIRST system item of a captured body (the system prompt), in
    /// either protocol.
    nonisolated static func ppSystem(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        let items = (object["messages"] as? [[String: Any]]) ?? (object["input"] as? [[String: Any]]) ?? []
        guard let first = items.first, (first["role"] as? String) == "system" else { return "" }
        if let text = first["content"] as? String { return text }
        if let parts = first["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
        return ""
    }

    nonisolated static func ppText(_ body: Data) -> String {
        String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    /// Fresh manager + router + capture, with every seam installed; the
    /// returned closure removes them.
    func ppStart(responses: Bool = false, concurrent: Bool = true) async throws -> (ConversationManager, PPRouter, PPCapture, () -> Void) {
        let restore: () -> Void = responses ? try useResponses() : {}
        CacheDiagnostics.reset()
        let manager = await freshManager()
        let router = PPRouter(responses: responses)
        server.concurrent = concurrent
        server.router = { router.route($0) }
        let capture = PPCapture()
        CacheDiagnostics.captureForTesting = { capture.add($0) }
        OpenRouterService.estimateSystemPromptObserverForTesting = { capture.estimate($0) }
        ConversationManager.promptScopeResetForTesting = { capture.reset() }
        return (manager, router, capture, { [self] in
            CacheDiagnostics.captureForTesting = nil
            OpenRouterService.estimateSystemPromptObserverForTesting = nil
            ConversationManager.promptScopeResetForTesting = nil
            server.router = nil
            server.concurrent = false
            restore()
        })
    }

    func ppTurn(_ manager: ConversationManager, _ text: String, timeout: TimeInterval = 120) async {
        manager._testStartTurn(for: user(text))
        _ = await manager._testAwaitIdle(timeout: timeout)
    }

    /// Blocks the calling (server) thread until `condition` holds, bounded.
    nonisolated static func ppBlockUntil(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    nonisolated static func ppStoredProfile() -> String { KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? "" }

    /// An archive-sized history (over the archive threshold, no tool rounds).
    static func ppArchiveHistory() -> [Message] {
        let base = Date().addingTimeInterval(-86_400)
        return (0..<24).map { i in
            Message(role: i % 2 == 0 ? .user : .assistant,
                    content: ArchiveFullChunkSelftest.filler("pp-old-\(i)", size: 4_000, sentinel: "end of pp-old-\(i)."),
                    timestamp: base.addingTimeInterval(TimeInterval(i * 60)))
        }
    }

    /// The large file read until a compaction (≈ 41k estimated tokens per read).
    func ppLargeFile() throws -> String {
        try FileManager.default.createDirectory(at: StoragePaths.dataRoot, withIntermediateDirectories: true)
        let large = StoragePaths.dataRoot.appendingPathComponent("pp-large.txt")
        try Data(((0..<200).map { _ in String(repeating: "PP_EVIDENCE ", count: 68) }.joined(separator: "\n")).utf8).write(to: large)
        return large.path
    }

    /// The pure value: live() reads exactly today's four sources; nil keeps
    /// today's per-request read; research ignores everything but the name.
    func ppUnitSection() async {
        let sentinel = Self.ppSentinel("U")
        try? ppSetProfile(Self.ppProfile(sentinel))
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Unit User")
        let live = PromptPersona.live()
        check("U1 live() reads the assistant name, user name and profile stores",
              live.assistantName == "Fixture Assistant" && live.userName == "Unit User"
                && live.structuredUserContext?.contains(sentinel) == true && live.previousName == IdentityMigration.priorPersonaName())
        let service = OpenRouterService()
        let images = StoragePaths.dataRoot.appendingPathComponent("images")
        func system(_ persona: PromptPersona?, style: SubagentPromptStyle = .messaging, tools: [ToolDefinition]? = [AvailableTools.readFile]) async -> String {
            await service.prepareConversation(messages: [user("hi")], imagesDirectory: images, documentsDirectory: images,
                tools: tools, toolResultMessages: nil, calendarContext: nil, emailContext: nil, chunkSummaries: nil,
                totalChunkCount: 0, turnStartDate: Date(timeIntervalSince1970: 1_800_000_000), finalResponseInstruction: nil,
                tailSystemMessage: nil, tailUserMessage: nil, deferredMCPSummaries: nil, promptStyle: style, persona: persona).systemPrompt
        }
        let withTools = await system(live) == system(nil)
        let withoutTools = await system(live, tools: []) == system(nil, tools: [])
        check("U2 an explicit live() snapshot and nil (today's per-request read) build identical prompts",
              withTools && withoutTools)
        let other = PromptPersona(assistantName: "Snap Assistant", userName: "Snap User",
                                  structuredUserContext: "- snapshot-only profile line", previousName: nil)
        let snapped = await system(other)
        check("U3 a snapshot replaces the live stores in the prompt", snapped.contains("snapshot-only profile line")
              && !snapped.contains(sentinel) && snapped.contains("Snap Assistant"))
        let research = await system(other, style: .research)
        check("U4 research style: no profile or user name, the snapshot's assistant name only",
              !research.contains("snapshot-only profile line") && !research.contains("Snap User") && !research.contains(sentinel)
                && research.contains("Snap Assistant"), String(research.prefix(200)))
        try? KeychainHelper.delete(key: KeychainHelper.userNameKey)
        try? ppSetProfile(nil)
    }
}
