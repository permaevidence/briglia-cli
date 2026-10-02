import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden battery for past-turn summary retention, Part B (plan v5): the
/// newest three prune-summary anchors stay in full, older ones become a
/// deterministic one-line snapshot pointer; coverage recorded at prune time;
/// snapshot protection in the shared retention function.
///
/// Isolation: the command re-executes itself in a private scratch home
/// (HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, XDG_CACHE_HOME,
/// CFFIXED_USER_HOME, TMPDIR) through a differently named link, so its
/// preference domain is private too. It never touches a real install.
struct PruneRetentionSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__prune-retention-selftest",
        abstract: "Internal: verify past-turn summary retention (Part B).",
        shouldDisplay: false
    )
    static let childName = "briglia-mw-retention-selftest"

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?
    @Option(name: .long, help: .hidden) var fuzzCases: Int = 10_000

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only, fuzzCases: fuzzCases); return }
        let h = RetentionHarness(only: only, fuzzCases: fuzzCases)
        try await h.runAll()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) prune retention check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) prune retention checks passed")
    }

    static func reexecIsolated(only: String?, fuzzCases: Int) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("briglia-prune-retention-\(UUID().uuidString)")
        for sub in ["home", "home/.config", "home/.local/share", "home/.local/state", "home/.cache", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("BRIGLIA_") || key.hasPrefix("ADA_") { env.removeValue(forKey: key) }
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["XDG_STATE_HOME"] = home + "/.local/state"
        env["XDG_CACHE_HOME"] = home + "/.cache"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        // The preference domain follows the executable name: run through a
        // differently named link so the domain is private (see the mid-turn
        // wake selftest for the cfprefsd details).
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(childName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__prune-retention-selftest", "--child", "--fuzz-cases", String(fuzzCases)]
            + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(childName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// Shared state and fixtures; the sections live in `PruneRetentionSelftest+*`
/// files so no single function grows past the Linux frontend's budget.
@MainActor
final class RetentionHarness {
    let only: String?
    let fuzzCases: Int
    var failures = 0
    var total = 0
    var server: CaptureServer!
    let apiKey = "synthetic-retention-key"
    /// A fixed device zone so recorded offsets are deterministic.
    let zone = TimeZone(secondsFromGMT: 7200)!

    init(only: String?, fuzzCases: Int) { self.only = only; self.fuzzCases = fuzzCases }

    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        let extra = ok ? "" : detail()
        print("\(ok ? "✔" : "✖") \(label)\(extra.isEmpty ? "" : " — \(String(extra.prefix(600)))")")
        if !ok { failures += 1 }
    }

    func section(_ name: String) -> Bool {
        guard only == nil || only == name else { return false }
        print("\n── \(name)")
        return true
    }

    func runAll() async throws {
        let data = StoragePaths.dataRoot.path
        guard data.contains("briglia-prune-retention-"),
              ProcessInfo.processInfo.processName == PruneRetentionSelftest.childName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        PruneSummaryRetention.timeZoneForTesting = zone
        server = try CaptureServer()
        defer { server.stop() }
        try configureProvider()
        if section("line") { lineGoldenSection(); lineOrderSection(); lineBoundarySection(); lineFuzzSection() }
        if section("coverage") { try await coverageRecordSection(); try await coverageCarriedSection() }
        if section("rule") { try await ruleSection(); try await ruleFailureSection() }
        if section("protection") { try await protectionEntrySection(); try await protectionFailureSection() }
        if section("fields") { try await fieldsSection() }
        if section("wire") { try await wireSection() }
    }

    // MARK: Provider and state

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

    func resetState() {
        PruneArchiveStore.faultForTesting = nil
        PruneArchiveStore.identityForTesting = nil
        ConversationManager.historyWriteFaultForTesting = nil
        ConversationManager.historyPostWriteFaultForTesting = nil
        ConversationManager.beforePruneHistoryWriteForTesting = nil
        ConversationManager.afterDemotionSnapshotForTesting = nil
        ConversationManager.coverageRecordingDisabledForTesting = false
        PruneSummaryRetention.timeZoneForTesting = zone
        server.router = nil
        server.clear()
        server.script([])
        let root = StoragePaths.dataRoot
        for name in ["conversation.json", "prune-archives", "prune-archive-settlements", "archive", "context_usage.json",
                     "detached-jobs.json", "stop-marker.json", "pending_midturn.json", "active_turn.json", "turn_salvage.json"] {
            let url = root.appendingPathComponent(name)
            chmod(url.path, 0o700)
            try? FileManager.default.removeItem(at: url)
        }
    }

    func freshManager(history: [Message] = []) async -> ConversationManager {
        resetState()
        let manager = ConversationManager()
        await manager._testPrepareScriptedProvider(apiKey: apiKey)
        if !history.isEmpty { manager._testSeedHistory(history) }
        return manager
    }

    /// A new manager over what is on disk (a restart).
    func restart() async -> ConversationManager {
        let manager = ConversationManager()
        await manager._testPrepareScriptedProvider(apiKey: apiKey)
        return manager
    }

    var historyURL: URL { StoragePaths.dataRoot.appendingPathComponent("conversation.json") }
    var snapshotDir: URL { PruneArchiveStore.root }

    func diskHistory() -> [Message]? {
        guard let data = try? Data(contentsOf: historyURL) else { return nil }
        return try? JSONDecoder().decode([Message].self, from: data)
    }

    func snapshotIDs() -> Set<UUID> { Set(((try? PruneArchiveStore.entries()) ?? []).map(\.reference.id)) }
    func snapshotText(_ ref: PruneArchiveReference) -> String {
        (try? String(contentsOf: snapshotDir.appendingPathComponent(ref.basename), encoding: .utf8)) ?? ""
    }
    func snapshotHeaderTrigger(_ ref: PruneArchiveReference) -> String? {
        let first = snapshotText(ref).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let prefix = "BRIGLIA SNAPSHOT 1 "
        guard first.hasPrefix(prefix),
              let header = try? JSONDecoder().decode(PruneArchiveStore.Header.self, from: Data(first.dropFirst(prefix.count).utf8)) else { return nil }
        return header.trigger
    }

    // MARK: Fixtures

    /// A wall-clock time in a fixed UTC offset (seconds).
    func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, offset: Int = 7200) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset)!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static let fixedBasename = "2026-09-29_134012Z_0123456789abcdef0123456789abcdef.txt"
    func ref(_ basename: String = RetentionHarness.fixedBasename) -> PruneArchiveReference {
        try! PruneArchiveReference(id: UUID(), basename: basename)
    }
    func randomRef() -> PruneArchiveReference {
        let id = UUID()
        return try! PruneArchiveReference(id: id, basename: "2026-09-29_134012Z_" + id.uuidString.lowercased().replacingOccurrences(of: "-", with: "") + ".txt")
    }

    func coverage(_ start: Date, _ end: Date, so: Int = 7200, eo: Int = 7200, complete: Bool = true, files: [String] = []) -> PruneSummaryCoverage {
        try! PruneSummaryCoverage(start: start, startOffsetSeconds: so, end: end, endOffsetSeconds: eo, complete: complete, files: files)
    }

    func round(_ id: String, issued: Date?) -> ToolInteraction {
        var assistant = AssistantToolCallMessage(content: nil, toolCalls: [
            ToolCall(id: id, type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))])
        assistant.issuedAt = issued
        return ToolInteraction(assistantMessage: assistant, results: [ToolResultMessage(toolCallId: id, content: "ok " + id)])
    }

    func user(_ text: String, at date: Date) -> Message { Message(role: .user, content: text, timestamp: date) }

    /// A finished tool turn: rounds issued at `issued`, reply at `at`.
    func toolTurn(_ label: String, at date: Date, issued: [Date?], edited: [String] = [], generated: [String] = []) -> Message {
        Message(role: .assistant, content: "REPLY_" + label, timestamp: date, editedFilePaths: edited, generatedFilePaths: generated,
                toolInteractions: issued.enumerated().map { round("\(label)_\($0.offset)", issued: $0.element) })
    }

    /// An older anchor already holding a full summary (with recorded
    /// coverage unless `recorded` is false).
    func anchor(_ label: String, at date: Date, files: [String] = [], recorded: Bool = true) -> Message {
        var message = Message(role: .assistant, content: "REPLY_" + label, timestamp: date, editedFilePaths: files)
        message.prunedContextSummary = "FULL_SUMMARY_" + label
        if recorded {
            message.prunedContextSummaryCoverage = coverage(date.addingTimeInterval(-600), date, files: files.isEmpty ? ["src/\(label).swift"] : files)
        }
        return message
    }

    /// `count` older anchors on consecutive days from 1 Sep 2026, then one
    /// prunable tool turn (the last message).
    func anchoredHistory(_ count: Int, labels: String = "A") -> [Message] {
        var history: [Message] = []
        for i in 0..<count {
            history.append(user("U_\(labels)\(i)", at: at(2026, 9, 1 + i, 9, 0)))
            history.append(anchor("\(labels)\(i)", at: at(2026, 9, 1 + i, 10, 0)))
        }
        history.append(user("U_TAIL", at: at(2026, 9, 20, 9, 0)))
        history.append(toolTurn("TAIL", at: at(2026, 9, 20, 10, 0), issued: [at(2026, 9, 20, 9, 30)], edited: ["src/tail.swift"]))
        return history
    }

    /// Prune the last message (a tool turn) with a scripted summary.
    @discardableResult
    func pruneLast(_ manager: ConversationManager, trigger: String = "manual", noSnapshot: Bool = false,
                   summary: String = "NEW_SUMMARY") async throws -> [Message] {
        try await manager._testRetentionPrune(affected: [manager._testMessages.count - 1], trigger: trigger,
                                              noSnapshot: noSnapshot, summary: summary)
    }

    func records(_ history: [Message]) -> [DemotedPruneSummary] { history.flatMap(\.demotedPruneSummaries) }
    func message(_ history: [Message], _ content: String) -> Message? { history.first { $0.content == content } }

    /// Fill the snapshot store with `count` old snapshots (oldest first).
    /// `future`: dated 2030 onward, so snapshots written now are the OLDEST
    /// retention candidates (what protection must spare).
    func fillSnapshots(_ count: Int, future: Bool = false) throws -> [PruneArchiveReference] {
        var refs: [PruneArchiveReference] = []
        let base = Date(timeIntervalSince1970: future ? 1_893_456_000 : 1_577_836_800) // 2030-01-01 / 2020-01-01
        for i in 0..<count {
            PruneArchiveStore.identityForTesting = { (base.addingTimeInterval(Double(i) * 60), UUID()) }
            refs.append(try PruneArchiveStore.write(messages: [], trigger: "automatic", removedIDs: []))
        }
        PruneArchiveStore.identityForTesting = nil
        return refs
    }

    /// A demoted record pointing at an existing snapshot.
    func record(_ ref: PruneArchiveReference, label: String) -> DemotedPruneSummary {
        try! DemotedPruneSummary(line: "Earlier work, approx. 1 Sep 2026 10:00–10:00 (UTC+02:00) · \(label) · full summary: snapshot " + ref.basename,
                                 snapshot: ref, coverage: nil)
    }

    /// Scripted Chat Completions / Responses replies (shared with the
    /// mid-turn wake harness).
    func text(_ value: String, responses: Bool) -> String {
        responses ? MidturnHarness.responsesText(value) : MidturnHarness.chatText(value)
    }

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

    func requestBodies() -> [String] { server.completeRequests.map { String(decoding: $0.body, as: UTF8.self) } }

    /// JSON text of a request body decoded the way the provider reads it
    /// (escapes resolved), so text assertions see the rendered strings.
    func decodedText(_ body: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { return body }
        var out: [String] = []
        func walk(_ value: Any) {
            if let s = value as? String { out.append(s) }
            else if let a = value as? [Any] { a.forEach(walk) }
            else if let d = value as? [String: Any] { for key in d.keys.sorted() { out.append(key); walk(d[key]!) } }
        }
        walk(object)
        return out.joined(separator: "\n")
    }

    static func occurrences(_ needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }
}
