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

/// Hidden battery for opt-in background pruning (BACKGROUND_PRUNE_PLAN
/// v4.1 §16): OFF behaviour, the freeze, the write-free worker, the owned
/// apply with its guard, the boundaries and the reduction step R, the
/// threshold-relative ceiling, in-band convergence, /stop, OFF, /restart,
/// manual /prune, generation bumps and the archive interplay.
///
/// Isolation: re-executes itself in a private scratch home (HOME,
/// XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, XDG_CACHE_HOME,
/// CFFIXED_USER_HOME, TMPDIR) under a hard link with its own preference
/// domain, inherited BRIGLIA_*/ADA_*/SM_* variables stripped, and the file
/// description store redirected before first use. Every model request goes
/// to a loopback server.
struct BackgroundPruneSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__background-prune-selftest",
        abstract: "Internal: verify background pruning.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?
    @Option(name: .long, help: .hidden) var crash: String?

    static let linkName = "briglia-mw-bg-prune-selftest"
    static let rootPrefix = "briglia-bg-prune-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = try BackgroundPruneSelftestHarness(only: only)
        if let crash {
            // Crash/kill reconstruction (§16.5): the parent kills this process.
            await BackgroundPruneSelftestCrash.child(h, phase: crash)
            return
        }
        await h.runAll()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) background prune check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) background prune checks passed")
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
        env["BRIGLIA_ENVELOPE_URL"] = "http://127.0.0.1:9/manifest.sig.json"
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__background-prune-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// A thread-blocking gate (loopback routing) that can also be awaited
/// from async code (the manager's hold seam).
final class BackgroundPruneSelftestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var arrivals = 0
    private var released = false
    var arrived: Int { lock.lock(); defer { lock.unlock() }; return arrivals }
    var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }
    func wait() {
        lock.lock()
        if released { lock.unlock(); return }
        arrivals += 1
        lock.unlock()
        semaphore.wait()
    }
    /// Async hold that ignores task cancellation (an uncooperative worker).
    private func noteArrival() { lock.lock(); arrivals += 1; lock.unlock() }
    func awaitRelease() async {
        noteArrival()
        while !isReleased { try? await Task.sleep(nanoseconds: 10_000_000) }
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

/// Ordered, thread-safe record of manager events and observed requests.
final class BackgroundPruneSelftestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    func clear() { lock.lock(); items = []; lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Answers prune-summary and file-description requests (and any other
/// maintenance request); main-agent requests use the scripted queue.
final class BackgroundPruneSelftestRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _summaries = 0
    private var _descriptions = 0
    private var _descriptionFiles: [String] = []
    private var _other = 0
    var holdSummaries: Set<Int> = []
    var holdDescriptions: Set<Int> = []
    var gate = BackgroundPruneSelftestGate()
    var summaryText: (Int) -> String = { "Fixture prune summary number \($0): kept facts alpha, beta, gamma." }
    /// Optional full reply for summary request n (protocol-specific body).
    var summaryReply: ((Int, Bool) -> String?)? = nil
    var summaries: Int { lock.lock(); defer { lock.unlock() }; return _summaries }
    var descriptions: Int { lock.lock(); defer { lock.unlock() }; return _descriptions }
    var descriptionFiles: [String] { lock.lock(); defer { lock.unlock() }; return _descriptionFiles }
    var other: Int { lock.lock(); defer { lock.unlock() }; return _other }

    static let summaryMarker = "PRUNE SUMMARY REQUEST"
    static let summaryRetryMarker = "PRUNE SUMMARY RETRY"
    static let descriptionMarker = "provides brief, accurate file descriptions"

    static func isMain(_ request: CapturedHTTPRequest) -> Bool {
        let text = String(data: request.body, encoding: .utf8) ?? ""
        guard !text.contains(summaryMarker), !text.contains(summaryRetryMarker), !text.contains(descriptionMarker),
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return false }
        return object["tools"] != nil
    }

    func route(_ request: CapturedHTTPRequest) -> (body: String, delay: TimeInterval)? {
        let text = String(data: request.body, encoding: .utf8) ?? ""
        if text.contains(Self.summaryMarker) || text.contains(Self.summaryRetryMarker) {
            lock.lock(); _summaries += 1; let n = _summaries; let hold = holdSummaries.contains(n); let make = summaryText; let full = summaryReply; lock.unlock()
            if hold { gate.wait() }
            let responses = request.target.hasSuffix("/responses")
            if let body = full?(n, responses) { return (body, 0) }
            return (responses ? BackgroundPruneSelftestHarness.rText(make(n)) : BackgroundPruneSelftestHarness.chat(make(n), prompt: 100), 0)
        }
        if text.contains(Self.descriptionMarker) {
            lock.lock(); _descriptions += 1; let n = _descriptions; let hold = holdDescriptions.contains(n); lock.unlock()
            if hold { gate.wait() }
            var files: [String] = []
            if let range = text.range(of: "Files: ") {
                let rest = text[range.upperBound...]
                let line = rest.prefix { $0 != "\\" && $0 != "\n" }
                files = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            lock.lock(); _descriptionFiles.append(contentsOf: files); lock.unlock()
            let reply = files.map { "\($0): description-\(n) of \($0)." }.joined(separator: "\n")
            if request.target.hasSuffix("/responses") { return (BackgroundPruneSelftestHarness.rText(reply), 0) }
            return (BackgroundPruneSelftestHarness.chat(reply, prompt: 100), 0)
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              object["tools"] == nil else { return nil }
        lock.lock(); _other += 1; let n = _other; lock.unlock()
        if ArchiveFullChunkSelftest.systemContent(request.body).contains(ArchiveFullChunkSelftest.summaryMarker) {
            return (BAArchiveRouter.chat(BAArchiveRouter.summaryText(n)), 0)
        }
        if request.target.hasSuffix("/responses") { return (BackgroundPruneSelftestHarness.rText("NO_CHANGES"), 0) }
        return (BackgroundPruneSelftestHarness.chat("NO_CHANGES", prompt: 100), 0)
    }
}

@MainActor
final class BackgroundPruneSelftestHarness {
    let only: String?
    var failures = 0
    var total = 0
    let server: CaptureServer
    let apiKey = "synthetic-bgprune-key"
    let model = "glm-5.3"
    let telegramAddress = ChannelAddress(kind: .telegram, chatId: "626262")
    var router = BackgroundPruneSelftestRouter()
    var channel = SVRecordingChannel(kind: .telegram)
    let log = BackgroundPruneSelftestLog()
    let maximum = 40_000
    let target = 10_000
    /// Scratch directory for describable files.
    let filesRoot: URL

    init(only: String?) throws {
        self.only = only
        self.server = try CaptureServer()
        // A crash child shares its parent's directory (the parent removes it;
        // a killed child never runs its cleanup).
        if let shared = ProcessInfo.processInfo.environment["BGPRUNE_FILES_ROOT"] {
            self.filesRoot = URL(fileURLWithPath: shared)
        } else {
            self.filesRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bgprune-files-" + UUID().uuidString)
        }
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
    }

    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        let extra = ok ? "" : detail()
        print("\(ok ? "✔" : "✖") \(label)\(extra.isEmpty ? "" : " — \(String(extra.prefix(900)))")")
        if !ok { failures += 1 }
    }

    func section(_ name: String) -> Bool {
        guard only == nil || only == name else { return false }
        print("\n── \(name)")
        return true
    }

    func runAll() async {
        let data = StoragePaths.dataRoot.path
        guard data.contains(BackgroundPruneSelftest.rootPrefix),
              ProcessInfo.processInfo.processName == BackgroundPruneSelftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        // Description store isolation (§16): before any access to the shared service.
        FileDescriptionsStore._testStoreURL = filesRoot.appendingPathComponent("descriptions.json")
        guard FileDescriptionsStore.isHermetic else {
            print("✖ description store is not hermetic; aborting"); failures += 1; return
        }
        defer {
            server.stop()
            // The describable-files fixture directory is owned by this run.
            try? FileManager.default.removeItem(at: filesRoot)
        }
        do { try configureProvider() } catch { check("configure scratch provider", false, "\(error)"); return }
        let log = self.log
        ConversationManager.bgPruneEventForTesting = { event in log.append(event) }
        if section("units") { await BackgroundPruneSelftestUnits.run(self) }
        if section("off") { await BackgroundPruneSelftestOff.run(self) }
        if section("freeze") { await BackgroundPruneSelftestApply.run(self) }
        if section("ceiling") { await BackgroundPruneSelftestCeiling.run(self) }
        if section("midloop") { await BackgroundPruneSelftestMidLoop.run(self) }
        if section("lifecycle") { await BackgroundPruneSelftestLifecycle.run(self) }
        if section("converge") { await BackgroundPruneSelftestConverge.run(self) }
        if section("descriptions") { await BackgroundPruneSelftestDescriptions.run(self) }
        if section("archive") { await BackgroundPruneSelftestArchive.run(self) }
        if section("round2") { await BackgroundPruneSelftestRound2.run(self) }
        if section("release") { await BackgroundPruneSelftestRelease.run(self) }
        if section("release3") { await BackgroundPruneSelftestRelease3.run(self) }
        if section("crash") { await BackgroundPruneSelftestCrash.run(self) }
    }

    func configureProvider() throws {
        let settings = [
            KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
            KeychainHelper.openAICompatibleBaseURLKey: "http://127.0.0.1:\(server.port)/v1",
            KeychainHelper.openAICompatibleApiKeyKey: apiKey,
            KeychainHelper.openAICompatibleModelKey: model,
            KeychainHelper.assistantNameKey: "Fixture Assistant",
            KeychainHelper.emailCalendarProviderKey: EmailCalendarProvider.none.rawValue,
            KeychainHelper.textOnlyModelEnabledKey: "false",
            KeychainHelper.maxContextTokensKey: String(maximum),
            KeychainHelper.targetContextTokensKey: String(target),
            KeychainHelper.archiveChunkSizeKey: "1000000",
        ]
        for (key, value) in settings { try KeychainHelper.save(key: key, value: value) }
    }

    // MARK: Events

    func clearEvents() { log.clear() }
    func eventCount(_ name: String) -> Int { log.all.filter { $0 == name }.count }
    func eventCount(prefix: String) -> Int { log.all.filter { $0.hasPrefix(prefix) }.count }
    var allEvents: [String] { log.all.filter { !$0.hasPrefix("request.") } }
    /// Records main-agent requests into the ordered log (request.main).
    func observeMainRequests() {
        let log = self.log
        server.requestObserver = { request in
            if BackgroundPruneSelftestRouter.isMain(request) { log.append("request.main") }
        }
    }
    /// True when `event` was logged before the first main request.
    func logged(_ event: String, beforeFirstMainRequest: Bool = true) -> Bool {
        let items = log.all
        guard let e = items.firstIndex(of: event) else { return false }
        guard let r = items.firstIndex(of: "request.main") else { return true }
        return e < r
    }

    // MARK: State

    func resetState(switchOn: Bool?) async {
        _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        await TurnWakeCenter.shared.disarm()
        ConversationManager.historyWriteFaultForTesting = nil
        ConversationManager.bgPruneHoldForTesting = nil
        ConversationManager.bgPruneDeadlineSecondsForTesting = nil
        ConversationManager.bgPruneDrainSecondsForTesting = nil
        ConversationManager.bgPruneWriteSetViolationForTesting = nil
        BackgroundPruneContextWindow.overrides = [:]
        await SubagentBackgroundRegistry.shared._testReset()
        switch switchOn {
        case .some(let on): UserDefaults.standard.set(on, forKey: ConversationManager.backgroundPruneDefaultsKey)
        case .none: UserDefaults.standard.removeObject(forKey: ConversationManager.backgroundPruneDefaultsKey)
        }
        UserDefaults.standard.removeObject(forKey: ConversationManager.archiveInlineDefaultsKey)
        try? KeychainHelper.save(key: KeychainHelper.maxContextTokensKey, value: String(maximum))
        try? KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: "1000000")
        router.gate.release()
        router = BackgroundPruneSelftestRouter()
        let current = router
        server.router = { current.route($0) }
        server.concurrent = true
        server.requestObserver = nil
        await MaintenanceAlertCenter.shared._testReset()
        let root = StoragePaths.dataRoot
        for name in ["conversation.json", "detached-jobs.json", "stop-marker.json", "pending_midturn.json",
                     "active_turn.json", "turn_salvage.json", "context_usage.json", "prune-archives",
                     "prune-archive-settlements", "subagent_sessions", "archive", "maintenance_alerts.json"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: filesRoot.appendingPathComponent("descriptions.json"))
        server.clear()
        server.script([])
        clearEvents()
    }

    /// A fresh manager over clean state with `history` seeded.
    func freshManager(history: [Message], switchOn: Bool? = true) async -> ConversationManager {
        await resetState(switchOn: switchOn)
        channel = SVRecordingChannel(kind: .telegram)
        let manager = ConversationManager()
        await manager._testPrepareScriptedProvider(apiKey: apiKey)
        manager._testSeedHistory(history)
        manager._svRegisterChannel(channel)
        manager._svSetLastUserAddress(telegramAddress)
        await sleep(0.1)
        return manager
    }

    // MARK: Fixtures

    func toolRound(id: String, size: Int, name: String = "read_file", args: String? = nil) -> ToolInteraction {
        let call = ToolCall(id: id, type: "function",
                            function: FunctionCall(name: name, arguments: args ?? "{\"file_path\":\"/tmp/\(id).txt\"}"))
        let result = "RESULT-\(id) " + String(repeating: "lorem ipsum dolor ", count: max(1, size / 18))
        return ToolInteraction(assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: [call]),
                               results: [ToolResultMessage(toolCallId: id, content: result)])
    }

    /// `pairs` user/assistant pairs; each assistant message carries one
    /// read_file round of ~`size` characters (prunable tool output).
    func prunableHistory(pairs: Int = 8, size: Int = 16_000, label: String = "h") -> [Message] {
        var history: [Message] = []
        let base = Date().addingTimeInterval(-86_400)
        for i in 0..<pairs {
            history.append(Message(role: .user, content: "\(label) question \(i)", timestamp: base.addingTimeInterval(TimeInterval(i * 120))))
            var assistant = Message(role: .assistant, content: "\(label) answer \(i)", timestamp: base.addingTimeInterval(TimeInterval(i * 120 + 60)))
            assistant.toolInteractions = [toolRound(id: "\(label)-call-\(i)", size: size)]
            history.append(assistant)
        }
        return history
    }

    // MARK: Responses

    nonisolated static func chat(_ text: String, prompt: Int) -> String {
        body(["role": "assistant", "content": text], finish: "stop", prompt: prompt)
    }

    nonisolated static func tools(_ calls: [(id: String, name: String, args: [String: Any])], prompt: Int) -> String {
        let toolCalls: [[String: Any]] = calls.map { call in
            let args = String(data: try! JSONSerialization.data(withJSONObject: call.args, options: [.sortedKeys]), encoding: .utf8)!
            return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": args]]
        }
        return body(["role": "assistant", "content": NSNull(), "tool_calls": toolCalls], finish: "tool_calls", prompt: prompt)
    }

    nonisolated static func rText(_ text: String, input: Int = 100, id: String = UUID().uuidString) -> String {
        rBody([["type": "message", "role": "assistant", "status": "completed", "id": "msg_" + id,
                "content": [["type": "output_text", "text": text, "annotations": []]]]], id: id, input: input)
    }

    nonisolated static func rTools(_ calls: [(id: String, name: String, args: [String: Any])], input: Int = 100,
                                   id: String = UUID().uuidString) -> String {
        let items: [[String: Any]] = calls.map { call in
            let args = String(data: try! JSONSerialization.data(withJSONObject: call.args, options: [.sortedKeys]), encoding: .utf8)!
            return ["type": "function_call", "id": "fc_" + call.id, "call_id": call.id, "status": "completed",
                    "name": call.name, "arguments": args]
        }
        return rBody(items, id: id, input: input)
    }

    nonisolated private static func rBody(_ output: [[String: Any]], id: String, input: Int) -> String {
        let body: [String: Any] = ["id": "resp_" + id, "status": "completed", "output": output,
            "usage": ["input_tokens": input, "input_tokens_details": ["cached_tokens": 0],
                      "output_tokens": 10, "output_tokens_details": ["reasoning_tokens": 0]]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    nonisolated private static func body(_ message: [String: Any], finish: String, prompt: Int) -> String {
        let body: [String: Any] = ["id": "bp", "object": "chat.completion", "model": "glm-5.3",
            "choices": [["index": 0, "message": message, "finish_reason": finish]],
            "usage": ["prompt_tokens": prompt, "completion_tokens": 10, "total_tokens": prompt + 10]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    // MARK: Requests

    func isMain(_ request: CapturedHTTPRequest) -> Bool { BackgroundPruneSelftestRouter.isMain(request) }
    var mainRequests: [CapturedHTTPRequest] { server.completeRequests.filter(isMain) }
    func bodyText(_ request: CapturedHTTPRequest) -> String { String(data: request.body, encoding: .utf8) ?? "" }

    // MARK: Turns

    /// Starts a turn (the user message is appended and saved first).
    func startTurn(_ manager: ConversationManager, _ text: String, replies: [String]) {
        server.script(replies)
        manager._testStartTurn(for: Message(role: .user, content: text))
    }

    @discardableResult
    func turn(_ manager: ConversationManager, _ text: String, reply: String = "done", prompt: Int = 100,
              timeout: TimeInterval = 40) async -> Bool {
        startTurn(manager, text, replies: [Self.chat(reply, prompt: prompt)])
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

    func waitPhase(_ manager: ConversationManager, _ phase: String, timeout: TimeInterval = 20) async -> Bool {
        await waitUntil(timeout: timeout) { manager.bgPruneTestPhase == phase }
    }

    func encoded(_ messages: [Message]) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(messages)) ?? Data()
    }

    /// Ids of messages whose tool interactions are gone.
    func prunedIds(_ manager: ConversationManager) -> [UUID] {
        manager._testMessages.filter { $0.role == .assistant && $0.toolInteractions.isEmpty && $0.content.contains(" answer ") }.map(\.id)
    }

    func summaryAnchors(_ manager: ConversationManager) -> [Message] {
        manager._testMessages.filter { ($0.prunedContextSummary ?? "").contains("Fixture prune summary") }
    }

    func diskHistory() -> [Message] {
        let url = StoragePaths.dataRoot.appendingPathComponent("conversation.json")
        guard let data = try? Data(contentsOf: url), let history = try? JSONDecoder().decode([Message].self, from: data) else { return [] }
        return history
    }

    var noticeTexts: [String] { channel.delivered.filter { $0.contains("Summarizing and compacting") } }

    /// Freezes a pre-request job with the summary held at the loopback and
    /// waits until it is running; the turn completes meanwhile.
    func frozenRunningJob(_ manager: ConversationManager, estimate: Int = 60_000, holdSummary: Bool = true) async -> Bool {
        if holdSummary { router.holdSummaries = [1] }
        manager.bgPruneTestSetLastPromptTokens(estimate)
        let idle = await turn(manager, "trigger a background prune")
        let phase = manager.bgPruneTestPhase
        return idle && (holdSummary ? phase == "running" : phase != "none")
    }
}
