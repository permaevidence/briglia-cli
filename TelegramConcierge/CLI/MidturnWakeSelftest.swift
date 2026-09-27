import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden battery for mid-turn early wake release 1a (plan v7 §5, Codex V7
/// acceptance gates 1–2): wake center and generations, stale-batch
/// suppression, receipt signal, bash wake/detach, the forced-detach test
/// setting, /stop dispositions and the persisted stop marker, crash records
/// and startup reconciliation, typed outcome bindings, snapshot settlement
/// sidecars and proof-pinned retention.
///
/// Isolation: the command always re-executes itself in a private scratch
/// home (HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, CFFIXED_USER_HOME, TMPDIR), so
/// it can never touch a real install's state or preferences, whoever runs it.
/// Real-manager scenarios drive the production tool loop against a scripted
/// loopback Chat Completions server.
struct MidturnWakeSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__midturn-wake-selftest",
        abstract: "Internal: verify mid-turn early wake (release 1a).",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered: progress survives a watchdog kill
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = MidturnHarness(only: only)
        try await h.runAll()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) midturn wake check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) midturn wake checks passed")
    }

    static func reexecIsolated(only: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("briglia-midturn-wake-\(UUID().uuidString)")
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
        env.removeValue(forKey: ForceDetach.environmentKey)
        // The preference domain of `UserDefaults.standard` follows the
        // EXECUTABLE NAME, and cfprefsd serves a binary named `briglia` the
        // real install's domain even with CFFIXED_USER_HOME set (verified on
        // macOS 26). The child therefore runs through a differently named
        // hard link (copy as fallback) inside the scratch root: its domain is
        // private and lands in the scratch home.
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent("briglia-mw-selftest")
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__midturn-wake-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        // The child's private domain still lands in the user's preferences
        // directory (cfprefsd ignores CFFIXED_USER_HOME for the file); remove
        // it and its later empty shell like every other throwaway domain.
        TestPrefsDomains.purge("briglia-mw-selftest")
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// Shared state and helpers for every section (split across files so no
/// single function grows past the Linux CI frontend's memory budget).
@MainActor
final class MidturnHarness {
    let only: String?
    var failures = 0
    var total = 0
    var server: CaptureServer!
    let apiKey = "synthetic-midturn-key"

    init(only: String?) { self.only = only }

    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    func section(_ name: String) -> Bool {
        guard only == nil || only == name else { return false }
        print("\n── \(name)")
        return true
    }

    func runAll() async throws {
        // Guard: the child must be running in its private scratch home.
        let data = StoragePaths.dataRoot.path
        guard data.contains("briglia-midturn-wake-"), ProcessInfo.processInfo.processName == "briglia-mw-selftest" else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        TurnWakeCenter.graceSecondsForTesting = 0.6
        MidturnWakeSignal.forcedDelaySecondsForTesting = 0.8
        server = try CaptureServer()
        defer { server.stop() }
        try configureProvider()
        if section("repro1b") { try await repro1bSection() }
        if section("wake") { await wakeCenterSection() }
        if section("binding") { bindingModelSection() }
        if section("registry") { await registryWakeSection() }
        if section("loop") { try await loopSection() }
        if section("suppress") { try await suppressionSection() }
        if section("forced") { try await forcedSection() }
        if section("stop") { try await stopSection() }
        if section("restart") { try await restartSection() }
        if section("evidence") { try await evidenceSection() }
        if section("gate1") { try await gateOneSection() }
        if section("gate2") { try await gateTwoSection() }
        if section("race") { await raceSection() }
        if section("durability") { try await durabilitySection() }
        if section("responses") { try await responsesSection() }
        if section("storage") { try await storageSection() }
        if section("storage") { try await historyHoldSection() }
        if section("storage") { try await heldQueueReproSection() }
        if section("storage") { try await heldQueueDurabilitySection() }
        if section("storage") { try await heldQueueStopSection() }
        if section("storage") { try await heldQueueRound5ReproSection() }
        if section("storage") { try await heldQueueIndependenceSection() }
        if section("storage") { try await stopMarkerSettlementSection() }
        // Release 1b: subagent detachment, charges, spend incidents.
        if section("subagent") { try await subagentSection() }
        if section("subagent") { try await subagentStopSection() }
        if section("subagent") { try await subagentRestartSection() }
        if section("subagent") { try await subagentResponsesSection() }
        if section("charge") { try await chargeSection() }
        if section("charge") { try await chargeBarrierSection() }
        if section("incident") { try await spendIncidentSection() }
        if section("incident") { try await spendAcceptanceSection() }
        // 1b round 2: known charges survive acceptance, cancellation owns the
        // detach handoff, lost-run incidents span periods, acceptance
        // finalization is part of the journaled transaction.
        if section("subagent") { try await detachCancellationSection() }
        if section("charge") { try await knownChargeSurvivalSection() }
        if section("incident") { try await incidentSpanSection() }
        if section("incident") { try await acceptanceFinalizationSection() }
    }

    // MARK: Provider and scripting

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

    static func chatText(_ text: String) -> String {
        body(["role": "assistant", "content": text], finish: "stop")
    }

    static func chatTools(_ calls: [(id: String, name: String, args: [String: Any])]) -> String {
        let toolCalls: [[String: Any]] = calls.map { call in
            let args = String(data: try! JSONSerialization.data(withJSONObject: call.args, options: [.sortedKeys]), encoding: .utf8)!
            return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": args]]
        }
        return body(["role": "assistant", "content": NSNull(), "tool_calls": toolCalls], finish: "tool_calls")
    }

    private static func body(_ message: [String: Any], finish: String) -> String {
        let body: [String: Any] = ["id": "mw", "object": "chat.completion", "model": "glm-5.3",
            "choices": [["index": 0, "message": message, "finish_reason": finish]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    /// A fresh manager over clean state (previous files and jobs removed).
    func freshManager(history: [Message] = []) async -> ConversationManager {
        await resetState()
        let manager = ConversationManager()
        await manager._testPrepareScriptedProvider(apiKey: apiKey)
        if !history.isEmpty { manager._testSeedHistory(history) }
        return manager
    }

    func resetState() async {
        _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        await TurnWakeCenter.shared.disarm()
        DetachedJobStore.faultForTesting = nil
        StopMarkerStore.faultForTesting = nil
        SettlementEvidence.faultForTesting = nil
        ForceDetach.overrideForTesting = nil
        BashTools.lastRecordFailure = nil
        BashTools.quickDefaultSeconds = 120
        DetachedJobStore.instanceId = UUID()
        DetachedJobStore.forgetCreatedForTesting()
        ConversationManager.stopCutoffInterleaveForTesting = nil
        ToolExecutor.detachEligibilityOverrideForTesting = nil
        ToolExecutor.beforeSubagentRecordForTesting = nil
        SubagentBackgroundRegistry.atCommitDetachForTesting = nil
        await SubagentBackgroundRegistry.shared._testReset()
        ToolChargeLedger.resetForTesting()
        server.router = nil
        server.concurrent = false
        let root = StoragePaths.dataRoot
        for name in ["conversation.json", "detached-jobs.json", "stop-marker.json", "pending_midturn.json",
                     "active_turn.json", "turn_salvage.json", "context_usage.json", "prune-archives",
                     "prune-archive-settlements", "subagent_sessions"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        server.clear()
        server.script([])
    }

    /// Wait (bounded) until a main-owned bash job is running.
    func waitForRunningJob(timeout: TimeInterval = 15) async -> BackgroundProcessRegistry.RunningJob? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = await BackgroundProcessRegistry.shared.runningMainOwnedJobs().first { return job }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    func waitUntil(timeout: TimeInterval = 15, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    func records() -> [DetachedJobRecord] { (try? DetachedJobStore.load()) ?? [] }

    func requestBodies() -> [String] {
        server.completeRequests.map { String(decoding: $0.body, as: UTF8.self) }
    }

    func user(_ text: String) -> Message { Message(role: .user, content: text) }

    /// All tool results in history, flattened.
    func results(_ manager: ConversationManager) -> [ToolResultMessage] {
        manager._testMessages.flatMap { $0.toolInteractions.flatMap(\.results) }
    }

    func parse(_ content: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any] ?? [:]
    }

    /// A tool round carrying one result with the given binding.
    static func round(callId: String, content: String = "{}", binding: OutcomeBinding?, name: String = "bash",
                      arguments: String = "{}") -> ToolInteraction {
        var result = ToolResultMessage(toolCallId: callId, content: content)
        result.outcomeBinding = binding
        return ToolInteraction(assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: [
            ToolCall(id: callId, type: "function", function: FunctionCall(name: name, arguments: arguments))]),
            results: [result])
    }

    static func assistant(_ text: String, rounds: [ToolInteraction]) -> Message {
        Message(role: .assistant, content: text, toolInteractions: rounds)
    }

    /// A crash record for tests (owed, from a previous process).
    static func record(jobId: UUID = UUID(), handle: String = "bash_9", body: String? = "[BACKGROUND BASH COMPLETE]\n\nhandle: bash_9",
                       anchor: UUID? = nil, fingerprint: String? = nil, callId: String = "call-x",
                       instance: UUID = UUID()) -> DetachedJobRecord {
        var record = DetachedJobRecord(jobId: jobId, instanceId: instance, turnRunId: UUID(), toolCallId: callId,
                                       callFingerprint: fingerprint, handle: handle, command: "sleep 1",
                                       description: nil, workdir: nil, startedAt: Date(), launch: .wakeDetached,
                                       completionMessageId: UUID(), historyAnchorMessageId: anchor)
        record.completionBody = body
        return record
    }
}
