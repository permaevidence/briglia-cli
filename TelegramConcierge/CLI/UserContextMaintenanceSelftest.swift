import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// User-profile maintenance with edit operations (USER_CONTEXT_EDIT_OPS_PLAN
/// v6 + v6.1). Drives the REAL `ConversationArchiveService` maintenance path
/// (decision procedure, budgets at the transport, commit, retired file,
/// state file) against loopback Chat Completions and Responses fixtures.
///
/// Isolation: re-executes itself in a private scratch home (HOME,
/// XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, XDG_CACHE_HOME,
/// CFFIXED_USER_HOME, TMPDIR) under a hard link with a reserved test prefix
/// (its own preference domain), with inherited BRIGLIA_*/ADA_*/SM_*
/// variables stripped.
///
/// `--live-preview` (development builds only, refused by release builds
/// before any other work) runs one real maintenance pass on a COPY of a
/// profile and writes a readable report; see UserContextMaintenanceSelftest+Preview.swift.
struct UserContextMaintenanceSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__user-context-maintenance-selftest",
        abstract: "Internal: verify user-profile maintenance (edit operations).",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Flag(name: .customLong("live-preview"), help: .hidden) var livePreview = false
    @Option(name: .long, help: .hidden) var profile: String?
    @Option(name: .long, help: .hidden) var out: String?
    @Option(name: .customLong("credentials"), help: .hidden) var credentials: String?
    /// Deliberate-break hook for the mutation runs (see scripts); empty in CI.
    @Option(name: .long, help: .hidden) var only: String?
    /// The roots of the install the developer runs from (passed by the
    /// parent before it re-executes into scratch roots); the preview refuses
    /// to touch anything inside them.
    @Option(name: .customLong("real-root"), help: .hidden) var realRoots: [String] = []

    static let linkName = "briglia-mw-ucm-selftest"
    static let rootPrefix = "briglia-ucm-"
    static let refusalText = "--live-preview is a development-build command"

    /// The preview gate: the same predicate as `__migrate-run`, no override.
    static func previewAdmitted(version: String = adaCLIVersion) -> Bool {
        MigrationRunCommand.isDevelopmentBuild(version: version)
    }

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        // V1: a release build refuses the preview before touching anything.
        if livePreview {
            guard Self.previewAdmitted() else { print(Self.refusalText); throw ExitCode(2) }
            if child {
                try await Self.runPreviewChild(profile: profile, out: out, credentials: credentials, realRoots: realRoots)
            } else {
                var extra: [String] = ["--live-preview"]
                if let profile { extra += ["--profile", profile] }
                if let out { extra += ["--out", out] }
                if let credentials { extra += ["--credentials", credentials] }
                for root in [StoragePaths.configRoot.path, StoragePaths.dataRoot.path] { extra += ["--real-root", root] }
                try Self.reexecIsolated(extra: extra)
            }
            return
        }
        guard MigrationRunCommand.isDevelopmentBuild() else { print("✖ development build required"); throw ExitCode(1) }
        guard child else {
            var extra: [String] = []
            if let only { extra = ["--only", only] }
            try Self.reexecIsolated(extra: extra)
            return
        }
        let failures = try await Self.battery(only: only)
        if failures > 0 { throw ExitCode(1) }
    }

    static func reexecIsolated(extra: [String]) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "home/.local/state", "home/.cache", "tmp"] {
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
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__user-context-maintenance-selftest", "--child"] + extra
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }

    static func battery(only: String?) async throws -> Int {
        let data = StoragePaths.dataRoot.path
        guard data.contains(rootPrefix), ProcessInfo.processInfo.processName == linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            return 1
        }
        let h = try UCMHarness()
        defer { h.server.stop() }
        let groups: [(String, (UCMHarness) async throws -> Void)] = [
            ("document", documentRows),
            ("replies", replyRows),
            ("eligibility", eligibilityRows),
            ("failures", failureRows),
            ("budget", budgetRows),
            ("state", stateRows),
            ("commit", commitRows),
            ("interaction", interactionRows),
            ("lifecycle", lifecycleRows),
            ("existing", existingUserRows),
            ("wire", wireRows),
            ("preview", previewHarnessRows),
        ]
        for (name, group) in groups where only == nil || only == name {
            print("— \(name)")
            do { try await group(h) } catch { h.check("\(name) group threw", false, "\(error)") }
            h.resetHooks()
        }
        print("User-context maintenance selftest: \(h.total - h.failures)/\(h.total) passed")
        return h.failures
    }
}

// MARK: - Harness

/// A mutable clock the maintenance code reads through its hook.
final class UCMClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
    func set(_ date: Date) { lock.lock(); value = date; lock.unlock() }
}

final class UCMHarness: @unchecked Sendable {
    let server: WebFixtureServer
    let clock = UCMClock()
    var total = 0
    var failures = 0
    let maintenanceMarker = "You maintain the user profile"
    let extractionMarker = "extract NEW durable user-profile facts"
    let summaryMarker = "You are summarizing a specific segment"

    /// Scripted maintenance replies, popped in order. Directives:
    /// "@LENGTH:<text>" Chat finish_reason length (Responses: incomplete),
    /// "@TOOLS" a tool-call reply, "@HTTP:<code>" an HTTP error status,
    /// "@EMPTY" an empty reply. Anything else is the reply text.
    private let lock = NSLock()
    private var maintenanceScript: [String] = []
    var defaultMaintenanceReply = "{}"
    var extractionReply = "NO_CHANGES"

    init() throws {
        server = try WebFixtureServer()
        server.route = { [unowned self] request in self.respond(request) }
        try useChat()
    }

    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        if !ok { failures += 1 }
        print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(String(detail.prefix(600)))")")
    }

    func script(_ replies: [String]) { lock.lock(); maintenanceScript = replies; lock.unlock() }
    private func pop() -> String { lock.lock(); defer { lock.unlock() }; return maintenanceScript.isEmpty ? defaultMaintenanceReply : maintenanceScript.removeFirst() }

    static func systemText(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        if let messages = object["messages"] as? [[String: Any]] {
            return messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined(separator: "\n")
        }
        var out = object["instructions"] as? String ?? ""
        for item in object["input"] as? [[String: Any]] ?? [] where item["role"] as? String == "system" || item["role"] as? String == "developer" {
            for part in item["content"] as? [[String: Any]] ?? [] { out += "\n" + (part["text"] as? String ?? "") }
        }
        return out
    }

    func isMaintenance(_ request: WebFixtureServer.Request) -> Bool { Self.systemText(request.body).contains(maintenanceMarker) }
    var maintenanceRequests: [WebFixtureServer.Request] { server.requests.filter(isMaintenance) }
    var maintenanceSends: Int { maintenanceRequests.count }

    private func respond(_ request: WebFixtureServer.Request) -> WebFixtureServer.Response {
        let responses = request.path.hasSuffix("/responses")
        let system = Self.systemText(request.body)
        var text: String
        if system.contains(maintenanceMarker) { text = pop() }
        else if system.contains(extractionMarker) { text = extractionReply }
        else { text = (["Fixture summary of the archived segment."] + Array(repeating: "detail", count: 140)).joined(separator: " ") }
        if text.hasPrefix("@HTTP:") {
            return .init(status: Int(text.dropFirst(6)) ?? 500, body: "{\"error\":{\"message\":\"fixture\"}}")
        }
        if text == "@TOOLS" {
            return .init(body: responses
                ? WebFixtureServer.responsesBody("", id: UUID().uuidString, calls: [("bash", "{\"command\":\"ls\"}")])
                : WebFixtureServer.chatBody("", calls: [("bash", "{\"command\":\"ls\"}")]))
        }
        if text == "@EMPTY" { text = "" }
        if text.hasPrefix("@LENGTH:") {
            let content = String(text.dropFirst(8))
            if responses {
                let snapshot: [String: Any] = ["id": "resp_cut", "status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"],
                    "output": [["type": "message", "role": "assistant", "status": "incomplete", "id": "msg_cut",
                                "content": [["type": "output_text", "text": content, "annotations": []]]]],
                    "usage": ["input_tokens": 10, "output_tokens": 10]]
                return .init(body: String(data: try! JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys), encoding: .utf8)!)
            }
            let body: [String: Any] = ["id": "cut", "choices": [["message": ["role": "assistant", "content": content], "finish_reason": "length"]]]
            return .init(body: String(data: try! JSONSerialization.data(withJSONObject: body, options: .sortedKeys), encoding: .utf8)!)
        }
        return .init(body: responses ? WebFixtureServer.responsesBody(text, id: UUID().uuidString) : WebFixtureServer.chatBody(text))
    }

    // MARK: Provider setup

    func useChat() throws {
        try ProviderProfiles.saveProfile(.custom, apiKey: "sk-fixture-ucm-0000000000000000", baseURL: "http://127.0.0.1:\(server.port)/v1",
                                         model: "glm-5.3", effort: nil, textOnly: false, wireProtocol: .chatCompletions)
        try ProviderProfiles.activate(.custom)
        try KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: "Fixture Assistant")
        try KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Fixture User")
    }

    func useResponses() throws {
        try ProviderProfiles.saveProfile(.custom, apiKey: "sk-fixture-ucm-0000000000000000", baseURL: "http://127.0.0.1:\(server.port)/v1",
                                         model: "glm-5.3", effort: nil, textOnly: false, wireProtocol: .responses)
        try ProviderProfiles.activate(.custom)
    }

    // MARK: Files and state

    var archiveDir: URL { StoragePaths.dataRoot.appendingPathComponent("archive", isDirectory: true) }
    var stateURL: URL { UserContextMaintenance.stateURL }
    var retiredURL: URL { RetiredUserFacts.url }

    var profile: String { KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? "" }
    func setProfile(_ text: String?) throws {
        if let text { try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: text) }
        else { try KeychainHelper.delete(key: KeychainHelper.structuredUserContextKey) }
    }

    func state() -> UserContextStateLoad { UserContextMaintenance.loadState() }
    var validState: UserContextMaintenanceState? { if case .valid(let s) = state() { return s }; return nil }
    func writeState(_ state: UserContextMaintenanceState) throws { try PrivateStorage.writeAtomically(try state.encoded(), to: stateURL) }

    func retired() -> [RetiredUserFacts.Record] { (try? RetiredUserFacts.read().records) ?? [] }

    func resetHooks() {
        UserContextMaintenance.testHooks = UserContextMaintenanceHooks(now: { [clock] in clock.now })
        UserContextMaintenance.testPolicy = UserContextMaintenancePolicy(attemptDelays: [0, 0])
    }

    /// A clean slate for one row: profile, no state, no retired file, fresh
    /// hooks/policy, empty script, a fresh archive service (= fresh process
    /// memory).
    func fresh(profile text: String?, policy: UserContextMaintenancePolicy? = nil) throws -> ConversationArchiveService {
        for url in [stateURL, retiredURL] { try? FileManager.default.removeItem(at: url) }
        try setProfile(text)
        resetHooks()
        if let policy { UserContextMaintenance.testPolicy = policy }
        script([]); defaultMaintenanceReply = "{}"; extractionReply = "NO_CHANGES"
        server.clear()
        return ConversationArchiveService()
    }

    /// Run one maintenance event and return the maintenance sends it made.
    @discardableResult
    func event(_ archive: ConversationArchiveService, _ event: UserContextMaintenanceEvent = .archive) async -> Int {
        let before = maintenanceSends
        await archive.maintainUserContextIfNeeded(event: event)
        return maintenanceSends - before
    }

    // MARK: Profiles

    /// A synthetic profile of about `size` characters: sections of bullet
    /// facts, each fact distinct.
    static func profile(size: Int, label: String = "f", lineEnding: String = "\n", sections: Int = 5) -> String {
        var lines: [String] = []
        var index = 0
        var length = 0
        var section = 0
        let perSection = max(1, size / 90 / max(sections, 1) + 1)
        while length < size {
            if index % perSection == 0 && section < sections {
                section += 1
                if !lines.isEmpty { lines.append(""); length += lineEnding.count }
                let heading = "## \(section). Section \(section)"
                lines.append(heading); length += heading.count + lineEnding.count
            }
            index += 1
            let fact = "- Fact \(label)\(index): the user has a stable durable preference number \(index) about things."
            lines.append(fact); length += fact.count + lineEnding.count
        }
        return lines.joined(separator: lineEnding) + lineEnding
    }

    /// Ops that drop facts until the result is below `target`.
    static func dropOps(for text: String, toBelow target: Int) -> String {
        let document = UserProfileDocument(text)
        var size = document.characterCount
        var drops: [Int] = []
        let facts = document.factLineIndices
        for (offset, index) in facts.enumerated() where size > target {
            drops.append(offset + 1)
            size -= document.lines[index].raw.count + 1
        }
        return "{\"drop\":[\(drops.map(String.init).joined(separator: ","))]}"
    }
}
