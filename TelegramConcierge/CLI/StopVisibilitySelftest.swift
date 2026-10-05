import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden battery for /stop visibility (STOP_VISIBILITY_PLAN v3, Codex
/// round-3 acceptance): honest stop replies, run-scoped attribution, one
/// ordered completion notice per announced run, the per-series sender
/// (retries, give-up, invalidation, transport-boundary generation check),
/// local notice delivery, status surfaces and the archive stage markers.
///
/// Isolation: re-executes itself in a private scratch home (HOME,
/// XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, XDG_CACHE_HOME,
/// CFFIXED_USER_HOME, TMPDIR) under a hard link with a reserved test prefix
/// (its own preference domain), with inherited BRIGLIA_*/ADA_*/SM_*
/// variables stripped. The Telegram API base points at a closed local port.
/// Real-manager scenarios drive the production turn loop against the
/// scripted loopback Chat Completions server and recording fake channels.
struct StopVisibilitySelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__stop-visibility-selftest",
        abstract: "Internal: verify /stop visibility.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-sv-selftest"
    static let rootPrefix = "briglia-stop-vis-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = try StopVisibilityHarness(only: only)
        await h.runAll()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) stop visibility check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) stop visibility checks passed")
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
        // Any stray Telegram request fails fast on a closed local port.
        env["BRIGLIA_TELEGRAM_API_BASE"] = "http://127.0.0.1:9/bot"
        // `UserDefaults.standard` follows the executable name: a differently
        // named hard link (copy as fallback) gets a private domain.
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__stop-visibility-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

// MARK: - Fakes

/// A ChatChannel that records every send and can hold or fail individual
/// calls (1-based call index) or texts.
final class SVRecordingChannel: ChatChannel, @unchecked Sendable {
    let kind: ChannelKind
    private let lock = NSLock()
    private var calls = 0
    private var _events: [String] = []
    private var _delivered: [String] = []
    private var held: Set<Int> = []
    private var started: Set<Int> = []
    private var failingCalls: Set<Int> = []
    private var _failAll = false
    private var failPrefix: String?

    init(kind: ChannelKind) { self.kind = kind }

    var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    var delivered: [String] { lock.lock(); defer { lock.unlock() }; return _delivered }
    /// Delivered stop-visibility texts only (⛔ / ✅).
    var stopTexts: [String] { delivered.filter { $0.hasPrefix("⛔") || $0.hasPrefix("✅") } }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func hold(call n: Int) { lock.lock(); held.insert(n); lock.unlock() }
    func release(call n: Int) { lock.lock(); held.remove(n); lock.unlock() }
    func hasStarted(call n: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return started.contains(n) }
    func fail(calls ns: Set<Int>) { lock.lock(); failingCalls.formUnion(ns); lock.unlock() }
    func failAll(_ on: Bool) { lock.lock(); _failAll = on; lock.unlock() }
    func failTexts(withPrefix prefix: String?) { lock.lock(); failPrefix = prefix; lock.unlock() }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func sendText(chatId: String, text: String) async throws {
        let n: Int = locked {
            calls += 1
            started.insert(calls)
            _events.append("start\(calls):\(text)")
            return calls
        }
        while locked({ held.contains(n) }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let shouldFail: Bool = locked {
            let fail = _failAll || failingCalls.contains(n) || (failPrefix.map { text.hasPrefix($0) } ?? false)
            if fail { _events.append("fail\(n)") } else { _events.append("end\(n):\(text)"); _delivered.append(text) }
            return fail
        }
        if shouldFail { throw URLError(.notConnectedToInternet) }
    }

    func sendPhoto(chatId: String, imageData: Data, caption: String?, mimeType: String) async throws {}
    func sendDocument(chatId: String, documentData: Data, filename: String, caption: String?, mimeType: String) async throws {}
}

/// Blocks the tool executor's thread inside the tool body of a named tool
/// (production seam `ToolExecutor.toolBodyHoldForTesting`).
final class SVToolHold: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var arrivals = 0
    private var released = false
    let tool: String

    init(tool: String) {
        self.tool = tool
        ToolExecutor.toolBodyHoldForTesting = { [self] name in
            guard name == self.tool else { return }
            self.lock.lock()
            if self.released { self.lock.unlock(); return }
            self.arrivals += 1
            self.lock.unlock()
            self.semaphore.wait()
        }
    }

    var arrived: Int { lock.lock(); defer { lock.unlock() }; return arrivals }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        let n = arrivals
        lock.unlock()
        for _ in 0..<n { semaphore.signal() }
        ToolExecutor.toolBodyHoldForTesting = nil
    }
}

/// An async gate (polling, so the awaiting actor stays reentrant).
final class SVGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters = 0
    var arrived: Int { lock.lock(); defer { lock.unlock() }; return waiters }
    private func arrive() { lock.lock(); waiters += 1; lock.unlock() }
    private var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func wait() async {
        arrive()
        while !isOpen && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    func release() { lock.lock(); open = true; lock.unlock() }
}

/// A fake monotonic clock for notice series: each sleep advances time;
/// while `holding`, a sleep waits for `release()` (cancellable).
@MainActor
final class SVFakeClock {
    var now: UInt64 = 1_000_000_000_000
    var sleeps: [UInt64] = []
    var holding = false
    private var released = false
    func release() { released = true }
    var clock: NoticeSeries.Clock {
        // Strong captures: a series that outlives its scenario (only under a
        // deliberate break) must not read a freed clock.
        NoticeSeries.Clock(nowNanos: { [self] in self.now },
                           sleep: { [self] nanos in
                               self.sleeps.append(nanos)
                               self.now &+= nanos
                               if self.holding {
                                   while !self.released && !Task.isCancelled {
                                       try? await Task.sleep(nanoseconds: 5_000_000)
                                   }
                               } else {
                                   await Task.yield()
                               }
                           })
    }
}

// MARK: - Harness

@MainActor
final class StopVisibilityHarness {
    let only: String?
    var failures = 0
    var total = 0
    let server: CaptureServer
    let apiKey = "synthetic-stopvis-key"
    let telegramAddress = ChannelAddress(kind: .telegram, chatId: "424242")
    var cancellables: Set<AnyCancellable> = []
    /// Large source file read by the envelope-owner fixture (SR3/SR4).
    var envelopeSourcePath: String?

    init(only: String?) throws {
        self.only = only
        self.server = try CaptureServer()
    }

    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(String(detail.prefix(600)))")")
        if !ok { failures += 1 }
    }

    func section(_ name: String) -> Bool {
        guard only == nil || only == name else { return false }
        print("\n── \(name)")
        return true
    }

    func runAll() async {
        let data = StoragePaths.dataRoot.path
        guard data.contains(StopVisibilitySelftest.rootPrefix),
              ProcessInfo.processInfo.processName == StopVisibilitySelftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        defer { server.stop() }
        do { try configureProvider() } catch { check("configure scratch provider", false, "\(error)"); return }
        if section("units") { await unitSection() }
        if section("turns") { await turnSection() }
        if section("archive") { await archiveSection() }
        if section("overlap") { await overlapSection() }
        if section("overlap") { await twoStoppedSection() }
        if section("delivery") { await deliverySection() }
        if section("clearing") { await clearingSection() }
        if section("transport") { await transportSection() }
        if section("local") { await localSection() }
        if section("restart") { await restartSection() }
        if section("repeat") { await repeatSection() }
        if section("a3") { await a3Section() }
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

    /// A fresh manager over clean state, with an optional fake channel that
    /// is also the reply destination.
    func freshManager(channel: SVRecordingChannel? = nil, history: [Message] = []) async -> ConversationManager {
        await resetState()
        let manager = ConversationManager()
        await manager._testPrepareScriptedProvider(apiKey: apiKey)
        if !history.isEmpty { manager._testSeedHistory(history) }
        if let channel {
            manager._svRegisterChannel(channel)
            manager._svSetLastUserAddress(channel.kind == .telegram ? telegramAddress
                : ChannelAddress(kind: channel.kind, chatId: "393330000000@s.whatsapp.net"))
        } else {
            manager._svSetLastUserAddress(nil)
        }
        return manager
    }

    func resetState() async {
        _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        await TurnWakeCenter.shared.disarm()
        ToolExecutor.toolBodyHoldForTesting = nil
        ConversationManager.openStagesProviderForTesting = nil
        ConversationManager.afterStopDecisionForTesting = nil
        ConversationManager.stopCutoffInterleaveForTesting = nil
        ConversationManager.historyWriteFaultForTesting = nil
        NoticeSeries.clockOverrideForTesting = nil
        TelegramBotService.noticePreCaptureHookForTesting = nil
        TelegramBotService.noticeRequestInterceptForTesting = nil
        await SubagentBackgroundRegistry.shared._testReset()
        server.router = nil
        server.concurrent = false
        server.requestObserver = nil
        let root = StoragePaths.dataRoot
        for name in ["conversation.json", "detached-jobs.json", "stop-marker.json", "pending_midturn.json",
                     "active_turn.json", "turn_salvage.json", "context_usage.json", "prune-archives",
                     "prune-archive-settlements", "subagent_sessions", "archive"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        server.clear()
        server.script([])
    }

    func waitUntil(timeout: TimeInterval = 15, _ condition: () async -> Bool) async -> Bool {
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

    func user(_ text: String) -> Message { Message(role: .user, content: text) }

    /// Starts a turn whose first tool call (`tool`) is held inside the tool
    /// body; returns the run id once the hold is reached.
    func startHeldTurn(_ manager: ConversationManager, hold: SVToolHold, callId: String,
                       tool: String = "bash", args: [String: Any] = ["command": "true"],
                       label: String = "do the held work") async -> UUID? {
        server.script([
            MidturnHarness.chatTools([(id: callId, name: tool, args: args)]),
            MidturnHarness.chatText("finished after the hold"),
        ])
        let before = hold.arrived
        manager._testStartTurn(for: user(label))
        let run = manager._svActiveRunId
        _ = await waitUntil { hold.arrived > before }
        return run
    }

    final class StopBox { var finished: Date? }

    /// Runs /stop on its own task; returns the elapsed seconds, or nil when
    /// it did not return within `timeout` (it keeps running).
    func timedStop(_ manager: ConversationManager, notify: ChannelAddress? = nil, timeout: TimeInterval = 15) async -> TimeInterval? {
        let box = StopBox()
        let start = Date()
        Task { @MainActor in
            await manager._svStop(notify: notify)
            box.finished = Date()
        }
        _ = await waitUntil(timeout: timeout) { box.finished != nil }
        return box.finished.map { $0.timeIntervalSince(start) }
    }

    /// Releases a hold and waits for the manager to become idle and for the
    /// stopped-run map to drain.
    func finish(_ manager: ConversationManager, _ hold: SVToolHold?, timeout: TimeInterval = 20) async {
        hold?.release()
        _ = await manager._testAwaitIdle(timeout: timeout)
        _ = await waitUntil(timeout: timeout) { manager.stoppedRunsFinishing.isEmpty }
    }

    /// Subscribes to the undeduplicated local notice stream.
    func collectLocalNotices(_ manager: ConversationManager) -> SVNoticeLog {
        let log = SVNoticeLog()
        manager.stopNoticeEvents.sink { log.items.append($0) }.store(in: &cancellables)
        return log
    }
}

@MainActor
final class SVNoticeLog {
    var items: [String] = []
}
