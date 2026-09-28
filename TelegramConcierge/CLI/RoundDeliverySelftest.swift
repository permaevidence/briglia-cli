import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden battery for mid-turn round delivery of background results (plan
/// MIDTURN_ROUND_DELIVERY_PLAN.md v3 §5, Codex round-3 acceptance checks):
/// a background bash job or background/moved subagent that finishes during
/// a turn is appended to that round's last tool result and is ordinary tool
/// output from then on; acknowledgement follows a saved history carrying
/// it; idle delivery is unchanged.
///
/// Isolation: like `__midturn-wake-selftest`, the command re-executes
/// itself in a private scratch home (HOME, XDG_CONFIG_HOME, XDG_DATA_HOME,
/// CFFIXED_USER_HOME, TMPDIR) under a differently named hard link, so it
/// never touches a real install's state or preference domain.
struct MidturnRoundDeliverySelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__midturn-roundresult-selftest",
        abstract: "Internal: verify mid-turn round delivery of background results.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-rd-selftest"
    static let rootPrefix = "briglia-midturn-round-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = MidturnHarness(only: only)
        try await h.runRoundDelivery()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) round delivery check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) round delivery checks passed")
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
        env.removeValue(forKey: ForceDetach.environmentKey)
        env.removeValue(forKey: RoundDelivery.environmentKey)
        // Differently named hard link: private preference domain (see the
        // wake selftest for why the executable name matters on macOS).
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__midturn-roundresult-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

extension MidturnHarness {

    func runRoundDelivery() async throws {
        let data = StoragePaths.dataRoot.path
        guard data.contains(MidturnRoundDeliverySelftest.rootPrefix),
              ProcessInfo.processInfo.processName == MidturnRoundDeliverySelftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        TurnWakeCenter.graceSecondsForTesting = 0.6
        MidturnWakeSignal.forcedDelaySecondsForTesting = 0.8
        server = try CaptureServer()
        defer { server.stop() }
        try configureProvider()
        if section("unit") { roundUnitSection() }
        if section("unit") { roundEvidenceUnitSection() }
        if section("loop") { try await roundLoopSection() }
        if section("loop") { try await roundLoopSemanticsSection() }
        if section("subagent") { try await roundSubagentSection() }
        if section("force") { try await roundForceFinalSection() }
        if section("stop") { try await roundStopSection() }
        if section("run") { try await roundRunOwnershipSection() }
        if section("ambient") { try await roundAmbientSection() }
        if section("durable") { try await roundDurabilitySection() }
        if section("crash") { try await roundCrashSection() }
        if section("compaction") { try await roundCompactionSection() }
        if section("stale") { try await roundStaleReaderSection() }
    }

    // MARK: Shared helpers

    /// A fresh manager, clean state, and every round-delivery seam off.
    func roundFresh(history: [Message] = []) async -> ConversationManager {
        roundResetSeams()
        return await freshManager(history: history)
    }

    func roundResetSeams() {
        RoundDelivery.overrideForTesting = nil
        ConversationManager.roundDeliveryInterleaveForTesting = nil
        ConversationManager.roundWithdrawalHoldForTesting = nil
        ConversationManager.idleDrainAfterReadForTesting = nil
        ConversationManager.plainSalvageFaultForTesting = nil
        ConversationManager.historyWriteFaultForTesting = nil
        ConversationManager.checkpointWriteFaultForTesting = nil
        ConversationManager.responsesSalvageFaultForTesting = nil
        PruneArchiveStore.faultForTesting = nil
        try? AgentTurnOverrides.save([:])
        for key in [KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey, KeychainHelper.openRouterToolSpendLimitDailyUSDKey] {
            try? KeychainHelper.delete(key: key)
        }
    }

    static let frameProbe = "[Background results — added by Briglia"

    /// An explicit background bash launch (a crash record is written).
    nonisolated static func bgCall(_ id: String, _ command: String) -> (id: String, name: String, args: [String: Any]) {
        (id: id, name: "bash", args: ["command": command, "wait_seconds": 0])
    }
    nonisolated static func fgCall(_ id: String, _ command: String) -> (id: String, name: String, args: [String: Any]) {
        (id: id, name: "bash", args: ["command": command])
    }

    /// Results in history that carry appended background results.
    func carriers(_ manager: ConversationManager) -> [ToolResultMessage] {
        results(manager).filter { !$0.deliveredCompletions.isEmpty }
    }

    func occurrences(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// No registry item, no reservation, no crash record left.
    func roundSettled(_ manager: ConversationManager) async -> Bool {
        await waitUntil(timeout: 5) {
            let bash = await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery()
            let sub = await SubagentBackgroundRegistry.shared.pendingCompletionsForDelivery()
            return bash.isEmpty && sub.isEmpty && manager._testRoundReservations.isEmpty
        } && records().isEmpty
    }

    /// One item settled: no reservation, not queued in either registry, no
    /// crash record naming its completion id (other jobs may still be open).
    func itemSettled(_ manager: ConversationManager, _ id: UUID?) async -> Bool {
        guard let id else { return false }
        return await waitUntil(timeout: 5) {
            let bash = await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery()
            let sub = await SubagentBackgroundRegistry.shared.pendingCompletionsForDelivery()
            return manager._testRoundReservations[id] == nil && !bash.contains { $0.messageId == id }
                && !sub.contains { $0.messageId == id }
        } && !records().contains { $0.completionMessageId == id && $0.completion == .owed }
    }

    func savedConversationText() -> String {
        (try? String(contentsOf: StoragePaths.dataRoot.appendingPathComponent("conversation.json"), encoding: .utf8)) ?? ""
    }

    /// Switch the scripted provider to the Responses transport; returns the
    /// restore action.
    func useResponses() throws -> () -> Void {
        try ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                         model: "fixture-model", effort: nil, textOnly: false, wireProtocol: .responses)
        try ProviderProfiles.activate(.custom)
        return { [self] in
            try? ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                              model: "glm-5.3", effort: nil, textOnly: false, wireProtocol: .chatCompletions)
            try? ProviderProfiles.activate(.custom)
            try? configureProvider()
        }
    }

    func tools(_ calls: [(id: String, name: String, args: [String: Any])], responses: Bool) -> String {
        responses ? Self.responsesTools(calls) : Self.chatTools(calls)
    }
    func text(_ value: String, responses: Bool) -> String {
        responses ? Self.responsesText(value) : Self.chatText(value)
    }

    /// An injected subagent completion (unrecorded unless `jobId` is set).
    static func injectedCompletion(_ handle: String, final: String, spend: Double = 0, chargeCaptured: Bool = false,
                                   jobId: UUID? = nil, messageId: UUID = UUID()) -> SubagentBackgroundRegistry.Completion {
        var handleValue = SubagentBackgroundRegistry.Handle(id: handle, subagentType: "general-purpose",
                                                           description: "injected \(handle)", startedAt: Date())
        handleValue.jobId = jobId
        var completion = SubagentBackgroundRegistry.Completion(
            handle: handleValue,
            result: SubagentRunner.RunResult(sessionId: "s-" + handle, isNewSession: true, finalMessage: final, turnsUsed: 1,
                                             toolsCalled: [], filesTouched: [], spendUSD: spend, error: nil),
            completedAt: Date())
        completion.messageId = messageId
        completion.chargeCaptured = chargeCaptured
        return completion
    }

    /// Run `body` once at the first drain stage named `stage`.
    func onceAt(_ stage: String, _ body: @escaping @MainActor () async -> Void) {
        var fired = false
        ConversationManager.roundDeliveryInterleaveForTesting = { name in
            guard name == stage else { return }
            await MainActor.run { }
            if fired { return }
            fired = true
            await body()
        }
    }
}
