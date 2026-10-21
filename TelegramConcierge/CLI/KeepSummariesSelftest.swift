import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden battery for `/keepsummaries` (KEEP_SUMMARIES_PLAN v5, §10 K1–K16):
/// render-time composition, the per-request view, measurement validity, the
/// commit-time pointers, the one-time restore and the idle pass.
///
/// Isolation: re-executes itself in a private scratch home (HOME, XDG_*,
/// CFFIXED_USER_HOME, TMPDIR) through a differently named `briglia-mw-*`
/// link, so its preference domain is private too; it never touches a real
/// install. Sections live in `KeepSummariesSelftest+*` files so no single
/// function grows past the Linux frontend's budget.
struct KeepSummariesSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__keep-summaries-selftest",
        abstract: "Internal: verify /keepsummaries (render-time summary retention).",
        shouldDisplay: false
    )
    static let childName = "briglia-mw-keepsummaries-selftest"
    static let rootPrefix = "briglia-keep-summaries-"

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?
    /// K3 cross-process probe: print the stored setting (`read`) or store one.
    @Option(name: .long, help: .hidden) var probe: String?

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        if let probe {
            // Only ever inside the isolated child environment.
            guard ProcessInfo.processInfo.processName == Self.childName,
                  StoragePaths.dataRoot.path.contains(Self.rootPrefix) else { print("✖ probe outside isolation"); throw ExitCode(1) }
            if probe == "read" { print("VALUE=" + KeepSummariesSetting.current().description) }
            else if let value = KeepSummariesSetting.parseArgument(probe) { KeepSummariesSetting.store(value); print("STORED") }
            return
        }
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = RetentionHarness(only: only, fuzzCases: 0)
        h.rootMarker = Self.rootPrefix
        h.childName = Self.childName
        try await h.runKeepSummariesAll()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) keep-summaries check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) keep-summaries checks passed")
    }

    /// The isolated environment (shared with the K3 cross-process probe).
    static func isolatedEnvironment(root: URL) -> [String: String] {
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
        env["BRIGLIA_KEEPSUMMARIES_SELFTEST_ROOT"] = root.path
        return env
    }

    static func reexecIsolated(only: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "home/.local/state", "home/.cache", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        // The preference domain follows the executable name: run through a
        // differently named link (checked before any defaults write).
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(childName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__keep-summaries-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = isolatedEnvironment(root: root)
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(childName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

extension RetentionHarness {
    func runKeepSummariesAll() async throws {
        // Checked before any defaults write: scratch roots and private domain.
        guard isolated() else { return }
        PruneSummaryRetention.timeZoneForTesting = zone
        ConversationManager.summaryRetentionIdlePassEnabled = false
        server = try CaptureServer()
        defer { server.stop() }
        try configureProvider()
        if section("compose") { composeTableSection(); composeEdgeSection() }
        if section("command") { parsingSection(); try storageSection(); await repliesSection() }
        if section("requests") { try await requestSection(); try await requestViewSection() }
        if section("measure") {
            try await measureBetweenTurnsSection(); try await measureEstimateSection()
            try await measureMidTurnSection(); try await measureRestartSection()
        }
        if section("invalidate") { try await invalidationSection(); try await invalidationFaultSection() }
        if section("restore") { try await restoreAcceptSection(); try await restoreRefusalSection(); try await restoreInjectionSection() }
        if section("idle") { try await idleBlockerSection(); try await idleBudgetSection(); try await idleTriggerSection()
            try await idleBudgetAccountingSection(); try await idleRetrySection(); try await idleHistoryRetrySection() }
        if section("downgrade") { try await downgradeSection() }
        if only == "downgrade-export" || only == "downgrade-import" { try await downgradeRealPhases() }
        if section("archive") { try await archiveSection() }
        if section("commits") { try await commitSection() }
        UserDefaults.standard.removeObject(forKey: KeepSummariesSetting.defaultsKey)
        ConversationManager.summaryRetentionIdlePassEnabled = true
    }

    // MARK: Shared fixtures

    /// `count` anchors with full summaries, recorded complete coverage and
    /// usable pointers sharing one stub snapshot (as a commit leaves them),
    /// then a user message.
    func stubbedHistory(_ count: Int, label: String = "K") throws -> [Message] {
        var history: [Message] = []
        for i in 0..<count {
            history.append(user("U_\(label)\(i)", at: at(2026, 9, 1 + i % 28, 9, 0)))
            history.append(anchor("\(label)\(i)", at: at(2026, 9, 1 + i % 28, 10, 0)))
        }
        let anchors = history.indices.filter { PruneSummaryRetention.isFullAnchor(history[$0]) }
        if !anchors.isEmpty {
            let ref = try PruneArchiveStore.write(messages: anchors.map { history[$0] }, trigger: "manual",
                removedIDs: anchors.map { history[$0].id }, leadNote: PruneSummaryRetention.snapshotLeadNote)
            for index in anchors { history[index].prunedContextSummaryStub = PruneSummaryRetention.makeStub(for: history, anchor: index, snapshot: ref) }
        }
        history.append(user("U_\(label)_LAST", at: at(2026, 9, 29, 9, 0)))
        return history
    }

    /// A fresh manager (state reset FIRST, so the stub snapshot survives)
    /// seeded with `stubbedHistory(count)`, optionally edited.
    func freshStubbed(_ count: Int, edit: ((inout [Message]) -> Void)? = nil) async throws -> ConversationManager {
        let manager = await freshManager()
        var history = try stubbedHistory(count)
        edit?(&history)
        manager._testSeedHistory(history)
        return manager
    }

    /// Chat Completions reply with a chosen prompt-token measurement.
    nonisolated static func chat(_ text: String, prompt: Int) -> String {
        body(["role": "assistant", "content": text], finish: "stop", prompt: prompt)
    }

    nonisolated static func tools(_ id: String, prompt: Int) -> String {
        let calls: [[String: Any]] = [["id": id, "type": "function", "function": ["name": "todo_write", "arguments": "{\"todos\":[]}"]]]
        return body(["role": "assistant", "content": NSNull(), "tool_calls": calls], finish: "tool_calls", prompt: prompt)
    }

    nonisolated private static func body(_ message: [String: Any], finish: String, prompt: Int) -> String {
        let body: [String: Any] = ["id": "ks", "object": "chat.completion", "model": "glm-5.3",
            "choices": [["index": 0, "message": message, "finish_reason": finish]],
            "usage": ["prompt_tokens": prompt, "completion_tokens": 10, "total_tokens": prompt + 10]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    func isMainRequest(_ request: CapturedHTTPRequest) -> Bool {
        let body = String(decoding: request.body, as: UTF8.self)
        return !body.contains("[PRUNE SUMMARY") && !body.contains("ACTIVE TURN COMPACTION")
    }

    func fullCount(_ text: String, labels: [String]) -> Int { labels.filter { text.contains("FULL_SUMMARY_" + $0) }.count }

    func encodedSorted<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    func usageFile() -> [String: Any]? {
        guard let data = try? Data(contentsOf: StoragePaths.dataRoot.appendingPathComponent("context_usage.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func writeUsage(_ object: [String: Any]) throws {
        try PrivateStorage.writeAtomically(try JSONSerialization.data(withJSONObject: object),
                                           to: StoragePaths.dataRoot.appendingPathComponent("context_usage.json"))
    }
}

/// The frozen 0.2.57 destructive demotion, kept as the test oracle for the
/// pointer shape and to build legacy (already demoted) histories. Snapshot
/// writing is the caller's; this is the per-anchor field rewrite exactly as
/// `demoteOlderSummaryAnchors` performed it.
enum LegacyDemotionOracle {
    static func demote(_ view: inout [Message], selected: [Int], snapshot: PruneArchiveReference) {
        for index in selected {
            let message = view[index]
            guard let summary = message.prunedContextSummary else { continue }
            let recorded = message.prunedContextSummaryCoverage.flatMap { $0.isValid ? $0 : nil }
            guard let coverage = recorded ?? PruneSummaryRetention.legacyCoverage(in: view, anchor: index),
                  let line = PruneSummaryRetention.line(for: coverage, snapshot: snapshot),
                  let record = try? DemotedPruneSummary(line: line, snapshot: snapshot, coverage: coverage) else { continue }
            view[index].demotedPruneSummaries.append(record)
            view[index].prunedContextSummary = nil
            view[index].prunedContextSummaryCoverage = nil
            if !view[index].pruneArchiveReferences.contains(snapshot) { view[index].pruneArchiveReferences.append(snapshot) }
            if let measured = view[index].measuredTokens {
                let delta = PruneSummaryRetention.wrapper(line).count / 4 - summary.count / 4
                let (sum, overflow) = measured.addingReportingOverflow(delta)
                view[index].measuredTokens = max(1, overflow ? (delta < 0 ? 1 : Int.max) : sum)
            }
        }
    }

    /// A 0.2.57 history: the selected anchors written to ONE demotion
    /// snapshot (the 0.2.57 writer call), then demoted.
    static func legacyHistory(_ history: [Message], demote selected: [Int], trigger: String = "manual") throws -> (history: [Message], snapshot: PruneArchiveReference) {
        let ref = try PruneArchiveStore.write(messages: selected.map { history[$0] }, trigger: trigger,
            removedIDs: selected.map { history[$0].id }, leadNote: PruneSummaryRetention.snapshotLeadNote)
        var view = history
        demote(&view, selected: selected, snapshot: ref)
        return (view, ref)
    }
}
