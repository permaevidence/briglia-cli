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

/// Hidden battery for background archiving (BACKGROUND_ARCHIVE_PLAN v3 and
/// the Codex round-3 receipt-coverage correction): a background job that
/// the turn does not await, the turn-boundary commit, the frozen and fresh
/// prompt views with the live-overlap disclosure, explicit archive reads,
/// chunk-file leases, both commit baselines with real archive writes and
/// real snapshots, restart recovery by coverage, the `.archiveCommit`
/// alert, retries/cooldown, lifecycle commands and `/archiveinline`.
///
/// Isolation: re-executes itself in a private scratch home (HOME,
/// XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, XDG_CACHE_HOME,
/// CFFIXED_USER_HOME, TMPDIR) under a hard link with its own preference
/// domain, with inherited BRIGLIA_*/ADA_*/SM_* variables stripped. Every
/// model request goes to a loopback server; the Telegram API base and the
/// release envelope point at a closed local port.
struct BackgroundArchiveSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__background-archive-selftest",
        abstract: "Internal: verify background archiving.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-bg-archive-selftest"
    static let rootPrefix = "briglia-bg-archive-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = try BackgroundArchiveHarness(only: only)
        await h.runAll()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) background archive check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) background archive checks passed")
    }

    static func reexecIsolated(only: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "home/.local/state", "home/.cache", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key.hasPrefix("BRIGLIA_") || key.hasPrefix("ADA_") || key.hasPrefix("SM_"))
        }
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["XDG_STATE_HOME"] = home + "/.local/state"
        env["XDG_CACHE_HOME"] = home + "/.cache"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        env["BRIGLIA_TELEGRAM_API_BASE"] = "http://127.0.0.1:9/bot"
        // /upgrade's discovery URL: a closed local port, so its check fails
        // fast and offline (exitPending reset rows).
        env["BRIGLIA_ENVELOPE_URL"] = "http://127.0.0.1:9/manifest.sig.json"
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__background-archive-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// A thread-blocking gate for the loopback server's routing closure.
final class BAGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var arrivals = 0
    private var released = false
    var arrived: Int { lock.lock(); defer { lock.unlock() }; return arrivals }
    func wait() {
        lock.lock()
        if released { lock.unlock(); return }
        arrivals += 1
        lock.unlock()
        semaphore.wait()
    }
    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        let n = arrivals
        lock.unlock()
        for _ in 0..<n { semaphore.signal() }
    }
}

/// Archive-lane routing: every tool-less request (chunk summary,
/// consolidation, meta summary, extraction) is answered here; main-agent
/// requests (which carry tools) use the scripted queue.
final class BAArchiveRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _summaries = 0
    private var _extractions = 0
    private var _other = 0
    /// 1-based summary-request numbers to hold on `gate`.
    var holdSummaries: Set<Int> = []
    var gate = BAGate()
    /// "transient" (malformed body: retried) or "deterministic" (a summary
    /// too short: never retried) for every summary request while set.
    var failSummaries: String?
    var summaries: Int { lock.lock(); defer { lock.unlock() }; return _summaries }
    var extractions: Int { lock.lock(); defer { lock.unlock() }; return _extractions }
    var otherArchiveRequests: Int { lock.lock(); defer { lock.unlock() }; return _other }

    static func chat(_ text: String) -> String {
        let body: [String: Any] = ["id": "ba-archive", "object": "chat.completion", "model": "glm-5.3",
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    static func summaryText(_ n: Int) -> String {
        (["Fixture summary #\(n) of the archived segment."] + Array(repeating: "detail", count: 140)).joined(separator: " ")
    }

    func route(_ request: CapturedHTTPRequest) -> (body: String, delay: TimeInterval)? {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              object["tools"] == nil else { return nil }
        let system = ArchiveFullChunkSelftest.systemContent(request.body)
        if system.contains(ArchiveFullChunkSelftest.extractionMarker) {
            lock.lock(); _extractions += 1; lock.unlock()
            return (Self.chat("NO_CHANGES"), 0)
        }
        if system.contains(ArchiveFullChunkSelftest.summaryMarker) {
            lock.lock(); _summaries += 1; let n = _summaries; let hold = holdSummaries.contains(n); let fail = failSummaries; lock.unlock()
            if hold { gate.wait() }
            switch fail {
            case "transient": return ("{not json", 0)
            case "deterministic": return (Self.chat("short"), 0)
            default: return (Self.chat(Self.summaryText(n)), 0)
            }
        }
        lock.lock(); _other += 1; let n = 1000 + _other; lock.unlock()
        return (Self.chat(Self.summaryText(n)), 0)
    }
}

@MainActor
final class BackgroundArchiveHarness {
    let only: String?
    var failures = 0
    var total = 0
    let server: CaptureServer
    let apiKey = "synthetic-bgarchive-key"
    let telegramAddress = ChannelAddress(kind: .telegram, chatId: "515151")
    var router = BAArchiveRouter()

    init(only: String?) throws {
        self.only = only
        self.server = try CaptureServer()
    }

    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(String(detail.prefix(700)))")")
        if !ok { failures += 1 }
    }

    func section(_ name: String) -> Bool {
        guard only == nil || only == name else { return false }
        print("\n── \(name)")
        return true
    }

    func runAll() async {
        let data = StoragePaths.dataRoot.path
        guard data.contains(BackgroundArchiveSelftest.rootPrefix),
              ProcessInfo.processInfo.processName == BackgroundArchiveSelftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        defer { server.stop() }
        do { try configureProvider() } catch { check("configure scratch provider", false, "\(error)"); return }
        if section("units") { await unitSection() }
        if section("lifecycle") { await lifecycleSection() }
        if section("failure") { await failureSection() }
        if section("view") { await viewSection() }
        if section("files") { await fileLifetimeSection() }
        if section("tools") { await toolContractSection() }
        if section("commit") { await commitSection() }
        if section("deltas") { await deltaSection() }
        if section("restart") { await restartSection() }
        if section("receipts") { await receiptSection() }
        if section("alerts") { await alertSection() }
        if section("commands") { await commandSection() }
        if section("modes") { await modeSection() }
    }

    func configureProvider() throws {
        let settings = [
            KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
            KeychainHelper.openAICompatibleBaseURLKey: "http://127.0.0.1:\(server.port)/v1",
            KeychainHelper.openAICompatibleApiKeyKey: apiKey,
            KeychainHelper.openAICompatibleModelKey: "glm-5.3",
            KeychainHelper.assistantNameKey: "Fixture Assistant",
            KeychainHelper.emailCalendarProviderKey: EmailCalendarProvider.none.rawValue,
            KeychainHelper.textOnlyModelEnabledKey: "false",
        ]
        for (key, value) in settings { try KeychainHelper.save(key: key, value: value) }
    }

    // MARK: State

    func resetState(inline: Bool = false) async {
        _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        await TurnWakeCenter.shared.disarm()
        ToolExecutor.toolBodyHoldForTesting = nil
        ConversationManager.historyWriteFaultForTesting = nil
        ConversationManager.viewCaptureHookForTesting = nil
        ConversationManager.backgroundArchiveHoldForTesting = nil
        ConversationArchiveService.afterConsolidationPublishForTesting = nil
        ConversationArchiveService.reconcileWriteFaultForTesting = nil
        ConversationArchiveService.beforeFreshSnapshotForTesting = nil
        await SubagentBackgroundRegistry.shared._testReset()
        if inline { UserDefaults.standard.set(true, forKey: ConversationManager.archiveInlineDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: ConversationManager.archiveInlineDefaultsKey) }
        router.gate.release()
        router = BAArchiveRouter()
        let current = router
        server.router = { current.route($0) }
        server.concurrent = true
        server.requestObserver = nil
        // Forget episodes and undelivered alerts of earlier scenarios.
        await MaintenanceAlertCenter.shared._testReset()
        let root = StoragePaths.dataRoot
        for name in ["conversation.json", "detached-jobs.json", "stop-marker.json", "pending_midturn.json",
                     "active_turn.json", "turn_salvage.json", "context_usage.json", "prune-archives",
                     "prune-archive-settlements", "subagent_sessions", "archive", "maintenance_alerts.json"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        server.clear()
        server.script([])
    }

    /// A fresh manager over clean state. `seed` runs before the manager
    /// exists (pre-published chunks are loaded by its archive service).
    func freshManager(channel: SVRecordingChannel? = nil, history: [Message] = [], inline: Bool = false,
                      seed: (() async throws -> Void)? = nil) async -> ConversationManager {
        await resetState(inline: inline)
        if let seed {
            do { try await seed() } catch { check("seed archive", false, "\(error)") }
        }
        return await makeManager(channel: channel, history: history)
    }

    /// A manager over the CURRENT disk state (a restart).
    func makeManager(channel: SVRecordingChannel? = nil, history: [Message] = []) async -> ConversationManager {
        let manager = ConversationManager()
        await manager._testPrepareScriptedProvider(apiKey: apiKey)
        if !history.isEmpty { manager._testSeedHistory(history) }
        if let channel {
            manager._svRegisterChannel(channel)
            manager._svSetLastUserAddress(telegramAddress)
        } else {
            manager._svSetLastUserAddress(nil)
        }
        // Let the manager's init-time wiring (alert delivery) settle.
        await sleep(0.1)
        return manager
    }

    // MARK: Fixtures

    /// ~24k estimated tokens: over the 20k archive threshold.
    func archiveSizedHistory(label: String = "old", count: Int = 24, base: Date = Date().addingTimeInterval(-86_400)) -> [Message] {
        (0..<count).map { i in
            Message(role: i % 2 == 0 ? .user : .assistant,
                    content: ArchiveFullChunkSelftest.filler("\(label)-\(i)", size: 4_000, sentinel: "end of \(label)-\(i)."),
                    timestamp: base.addingTimeInterval(TimeInterval(i * 60)))
        }
    }

    /// Like `archiveSizedHistory`, with tool detail on the assistant
    /// messages (each carries one read_file round), so the archive needs a
    /// chunk-archive snapshot.
    func detailHistory(label: String = "tool", count: Int = 24, base: Date = Date().addingTimeInterval(-86_400)) -> [Message] {
        (0..<count).map { i in
            var message = Message(role: i % 2 == 0 ? .user : .assistant,
                                  content: ArchiveFullChunkSelftest.filler("\(label)-\(i)", size: 3_600, sentinel: "end of \(label)-\(i)."),
                                  timestamp: base.addingTimeInterval(TimeInterval(i * 60)))
            if i % 2 == 1 { message.toolInteractions = [toolRound(id: "\(label)-call-\(i)", result: "TOOL-RESULT-\(label)-\(i) " + String(repeating: "r", count: 300))] }
            return message
        }
    }

    func toolRound(id: String, result: String) -> ToolInteraction {
        let call = ToolCall(id: id, type: "function", function: FunctionCall(name: "read_file", arguments: "{\"file_path\":\"/tmp/\(id).txt\"}"))
        return ToolInteraction(assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: [call]),
                               results: [ToolResultMessage(toolCallId: id, content: result)])
    }

    /// Publishes `count` small temporary chunks with a standalone archive
    /// service (real archiveMessages against the loopback router).
    func seedTemporaryChunks(_ count: Int, label: String = "seed", base: Date = Date().addingTimeInterval(-40 * 86_400)) async throws {
        let archive = ConversationArchiveService()
        await archive.configure(apiKey: apiKey)
        for index in 0..<count {
            let start = base.addingTimeInterval(TimeInterval(index * 3_600))
            _ = try await archive.archiveMessages(ArchiveFullChunkSelftest.chunk("\(label)\(index)", start: start, count: 2,
                                                                                  messageSize: 400, sentinel: "end of \(label)\(index)."))
        }
    }

    // MARK: Requests

    func isMain(_ request: CapturedHTTPRequest) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return false }
        return object["tools"] != nil
    }
    var mainRequests: [CapturedHTTPRequest] { server.completeRequests.filter(isMain) }
    func system(_ request: CapturedHTTPRequest) -> String { ArchiveFullChunkSelftest.systemContent(request.body) }
    func conversation(_ request: CapturedHTTPRequest) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return "" }
        return messages.filter { $0["role"] as? String != "system" }.compactMap { message -> String? in
            if let text = message["content"] as? String { return text }
            if let parts = message["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
            return nil
        }.joined(separator: "\n")
    }
    /// The archive section of a main request's system prompt ("" if none).
    func archiveSection(_ request: CapturedHTTPRequest) -> String {
        let text = system(request)
        guard let start = text.range(of: "## ARCHIVED CONVERSATION HISTORY") else { return "" }
        let rest = text[start.lowerBound...]
        if let end = rest.range(of: "\n\n", range: rest.index(rest.startIndex, offsetBy: 40)..<rest.endIndex),
           let tableEnd = rest[end.upperBound...].range(of: "\n\n") {
            return String(rest[..<tableEnd.lowerBound])
        }
        return String(rest)
    }

    // MARK: Turns

    /// Runs one complete turn with a scripted final reply; true when idle.
    @discardableResult
    func turn(_ manager: ConversationManager, _ text: String, reply: String, timeout: TimeInterval = 40) async -> Bool {
        server.script([MidturnHarness.chatText(reply)])
        manager._testStartTurn(for: Message(role: .user, content: text))
        return await manager._testAwaitIdle(timeout: timeout)
    }

    func waitUntil(timeout: TimeInterval = 20, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func contains(_ manager: ConversationManager, _ ids: [UUID]) -> Bool {
        let live = Set(manager._testMessages.map(\.id))
        return ids.allSatisfy { live.contains($0) }
    }
    func containsNone(_ manager: ConversationManager, _ ids: [UUID]) -> Bool {
        let live = Set(manager._testMessages.map(\.id))
        return ids.allSatisfy { !live.contains($0) }
    }
    /// The conversation as saved on disk.
    func diskIds() -> Set<UUID> {
        let url = StoragePaths.dataRoot.appendingPathComponent("conversation.json")
        guard let data = try? Data(contentsOf: url), let history = try? JSONDecoder().decode([Message].self, from: data) else { return [] }
        return Set(history.map(\.id))
    }

    /// Starts an archive turn in background mode and waits until its job
    /// is registered and the turn is idle. Summary requests numbered in
    /// `hold` wait on the router's gate.
    func startBackgroundJob(_ manager: ConversationManager, hold: Set<Int> = [1], reply: String = "reply while archiving") async -> Bool {
        router.holdSummaries = hold
        let idle = await turn(manager, "a request that triggers archiving", reply: reply)
        return idle && manager._baJobOutcome != nil
    }

    func waitForJob(_ manager: ConversationManager, _ outcome: String, timeout: TimeInterval = 40) async -> Bool {
        await waitUntil(timeout: timeout) { manager._baJobOutcome == outcome && !manager._baMaintenanceKinds.contains(.summarizingHistory) }
    }
}
