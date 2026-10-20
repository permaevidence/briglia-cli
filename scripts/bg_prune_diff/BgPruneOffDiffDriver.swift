import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

// O1/O9/F1 differential driver (BACKGROUND_PRUNE_PLAN v4.1 §16.1–16.2).
// NOT part of the product: scripts/bg_prune_off_differential_test.py copies
// this one file, unchanged, into a scratch 0.2.56 tree and a scratch
// candidate tree, registers it there, builds both and compares what each
// build does. It uses only APIs present in 0.2.56.

/// Ordered receipt calls (O9). The differential script inserts one
/// `BgPruneDiffRecorder.record(...)` line at the entry of each of the four
/// receipt functions in both scratch trees.
final class BgPruneDiffRecorder: @unchecked Sendable {
    static let shared = BgPruneDiffRecorder()
    private let lock = NSLock()
    private var items: [String] = []
    static func record(_ name: String) {
        shared.lock.lock(); shared.items.append(name); shared.lock.unlock()
        // The render-error scenario fails exactly one render.
        if name == "restore" { HarnessAnnotationRenderer.simulateRenderFailureForTesting = false }
    }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

struct BgPruneOffDiffDriver: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__bgprune-off-diff",
        abstract: "Internal: background-prune OFF differential driver (scratch builds only).",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var scenario: String
    @Option(name: .long, help: .hidden) var out: String
    @Option(name: .long, help: .hidden) var mode: String = "off"

    static let linkName = "briglia-mw-bgprune-offdiff"

    @MainActor func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexec(scenario: scenario, out: out, mode: mode); return }
        let data = StoragePaths.dataRoot.path
        guard data.contains("bgprune-offdiff-"), ProcessInfo.processInfo.processName == Self.linkName else {
            print("refusing to run outside the scratch home (\(data))"); throw ExitCode(2)
        }
        // Hermetic description store inside the scratch data root (both trees
        // support the seam), so saved descriptions are compared as a file.
        FileDescriptionsStore._testStoreURL = StoragePaths.dataRoot.appendingPathComponent("offdiff-descriptions.json")
        let driver = try BgPruneOffDiffRun(mode: mode)
        let result = await driver.run(scenario)
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        try json.write(to: URL(fileURLWithPath: out))
    }

    static func reexec(scenario: String, out: String, mode: String) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bgprune-offdiff-" + UUID().uuidString)
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
        let bundleName = "briglia-cli_briglia.bundle"
        let bundle = source.deletingLastPathComponent().appendingPathComponent(bundleName)
        if fm.fileExists(atPath: bundle.path) {
            try? fm.createSymbolicLink(at: root.appendingPathComponent(bundleName), withDestinationURL: bundle)
        }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__bgprune-off-diff", "--child", "--scenario", scenario, "--out", out, "--mode", mode]
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// Answers prune-summary, description and other maintenance requests per
/// the scenario's summary mode; main-agent requests use the scripted queue.
final class BgPruneDiffRouter: @unchecked Sendable {
    static let summaryMarker = "PRUNE SUMMARY REQUEST"
    static let summaryRetryMarker = "PRUNE SUMMARY RETRY"
    static let descriptionMarker = "provides brief, accurate file descriptions"
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    var summaryMode = "success"
    var responses = false
    let gate = BgPruneDiffGate()
    var holdSummary = false
    var failFirstDescription = false

    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; counts[key, default: 0] += 1; return counts[key]! }

    static func kind(_ request: CapturedHTTPRequest) -> String {
        let text = String(data: request.body, encoding: .utf8) ?? ""
        if text.contains(summaryMarker) || text.contains(summaryRetryMarker) { return "summary" }
        if text.contains(descriptionMarker) { return "description" }
        // Main-agent requests carry tools; maintenance requests (compaction
        // included) carry none or an empty list.
        if let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let tools = object["tools"] as? [Any], !tools.isEmpty {
            return "main"
        }
        return "other"
    }

    func route(_ request: CapturedHTTPRequest) -> (body: String, delay: TimeInterval)? {
        switch Self.kind(request) {
        case "summary":
            let n = count("summary")
            if holdSummary, n == 1 { gate.wait() }
            switch summaryMode {
            case "rejected": return (BgPruneOffDiffRun.chat("", prompt: 100, finish: "length"), 0)
            case "tools": return (BgPruneOffDiffRun.tools([(id: "sum-\(n)", name: "list_dir", args: ["path": "/"])], prompt: 100), 0)
            case "error": return ("{\"error\":{\"message\":\"upstream failure\"}}", 0)
            default: return (BgPruneOffDiffRun.chat("Fixture prune summary \(n): kept facts alpha, beta, gamma.", prompt: 100), 0)
            }
        case "description":
            let n = count("description")
            let text = String(data: request.body, encoding: .utf8) ?? ""
            var files: [String] = []
            if let range = text.range(of: "Files: ") {
                let line = text[range.upperBound...].prefix { $0 != "\\" && $0 != "\n" }
                files = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let reply = files.map { "\($0): description-\(n) of \($0)." }.joined(separator: "\n")
            return (BgPruneOffDiffRun.chat(reply, prompt: 100), 0)
        case "other":
            let n = count("other")
            return (BgPruneOffDiffRun.chat("Fixture maintenance reply \(n): earlier conversation condensed.", prompt: 100), 0)
        default:
            return nil
        }
    }

    func status(_ request: CapturedHTTPRequest) -> Int? {
        if Self.kind(request) == "summary", summaryMode == "error" { return 500 }
        if Self.kind(request) == "description", failFirstDescription {
            lock.lock(); let first = (counts["description-status"] ?? 0) == 0; counts["description-status"] = 1; lock.unlock()
            if first { return 500 }
        }
        return nil
    }
}

final class BgPruneDiffGate: @unchecked Sendable {
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

@MainActor
final class BgPruneOffDiffRun {
    let server: CaptureServer
    let apiKey = "synthetic-offdiff-key"
    let model = "glm-5.3"
    let mode: String
    let router = BgPruneDiffRouter()
    let channel = SVRecordingChannel(kind: .telegram)
    let address = ChannelAddress(kind: .telegram, chatId: "727272")
    var activities: [String] = []
    var replies: [String] = []
    var notes: [String] = []
    var identityCounter = 0
    let startedAt = Date()

    init(mode: String) throws {
        self.mode = mode
        server = try CaptureServer()
        server.concurrent = true
        let router = self.router
        server.router = { router.route($0) }
        server.routedStatus = { router.status($0) }
    }

    // MARK: Fixtures

    nonisolated static func chat(_ text: String, prompt: Int, finish: String = "stop") -> String {
        body(["role": "assistant", "content": text], finish: finish, prompt: prompt)
    }

    nonisolated static func tools(_ calls: [(id: String, name: String, args: [String: Any])], prompt: Int) -> String {
        let toolCalls: [[String: Any]] = calls.map { call in
            let args = String(data: try! JSONSerialization.data(withJSONObject: call.args, options: [.sortedKeys]), encoding: .utf8)!
            return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": args]]
        }
        return body(["role": "assistant", "content": NSNull(), "tool_calls": toolCalls], finish: "tool_calls", prompt: prompt)
    }

    nonisolated private static func body(_ message: [String: Any], finish: String, prompt: Int) -> String {
        let body: [String: Any] = ["id": "od", "object": "chat.completion", "model": "glm-5.3",
            "choices": [["index": 0, "message": message, "finish_reason": finish]],
            "usage": ["prompt_tokens": prompt, "completion_tokens": 10, "total_tokens": prompt + 10]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    nonisolated static func rText(_ text: String, id: String, input: Int = 100) -> String {
        rBody([["type": "message", "role": "assistant", "status": "completed", "id": "msg_" + id,
                "content": [["type": "output_text", "text": text, "annotations": []]]]], id: id, input: input)
    }

    nonisolated static func rTools(_ calls: [(id: String, name: String, args: [String: Any])], id: String, input: Int = 100) -> String {
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

    static let chatRejection = #"{"error":{"message":"Invalid image data. The image could not be decoded.","type":"invalid_request_error","param":null,"code":"invalid_image"}}"#
    static let responsesRejection = #"{"error":{"message":"The image data you provided does not represent a valid image. Please check your input and try again with one of the supported image formats: ['image/jpeg', 'image/png', 'image/gif', 'image/webp'].","type":"invalid_request_error","param":"input","code":"invalid_value"}}"#

    func reply(_ text: String, prompt: Int = 100, responses: Bool, id: String) -> String {
        responses ? Self.rText(text, id: id, input: prompt) : Self.chat(text, prompt: prompt)
    }

    func toolsReply(_ calls: [(id: String, name: String, args: [String: Any])], prompt: Int = 100, responses: Bool, id: String) -> String {
        responses ? Self.rTools(calls, id: id, input: prompt) : Self.tools(calls, prompt: prompt)
    }

    func file(_ name: String, _ text: String) -> String {
        let dir = StoragePaths.dataRoot.appendingPathComponent("offdiff-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func toolRound(id: String, size: Int, name: String = "read_file", args: String? = nil) -> ToolInteraction {
        let call = ToolCall(id: id, type: "function",
                            function: FunctionCall(name: name, arguments: args ?? "{\"path\":\"/tmp/\(id).txt\"}"))
        let result = "RESULT-\(id) " + String(repeating: "lorem ipsum dolor ", count: max(1, size / 18))
        return ToolInteraction(assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: [call]),
                               results: [ToolResultMessage(toolCallId: id, content: result)])
    }

    /// Fixed-time history (identical in both trees).
    func prunableHistory(pairs: Int = 8, size: Int = 16_000) -> [Message] {
        var history: [Message] = []
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<pairs {
            history.append(Message(role: .user, content: "h question \(i)", timestamp: base.addingTimeInterval(TimeInterval(i * 120))))
            var assistant = Message(role: .assistant, content: "h answer \(i)", timestamp: base.addingTimeInterval(TimeInterval(i * 120 + 60)))
            assistant.toolInteractions = [toolRound(id: "h-call-\(i)", size: size)]
            history.append(assistant)
        }
        return history
    }

    /// Three earlier full summary anchors, compact logs and measured tokens
    /// (F1 rich case: fourth-anchor demotion, references, coverage).
    func richHistory() -> [Message] {
        var history = prunableHistory()
        let base = Date(timeIntervalSince1970: 1_789_990_000)
        var older: [Message] = []
        for i in 0..<3 {
            var anchor = Message(role: .assistant, content: "older answer \(i)", timestamp: base.addingTimeInterval(TimeInterval(i * 300)))
            anchor.prunedContextSummary = "Older fixture summary \(i): decisions delta and epsilon."
            older.append(Message(role: .user, content: "older question \(i)", timestamp: base.addingTimeInterval(TimeInterval(i * 300 - 60))))
            older.append(anchor)
        }
        for i in history.indices where history[i].role == .assistant {
            history[i].measuredTokens = 4_000 + i
            history[i].measuredToolTokens = 3_900 + i
        }
        for i in 0..<8 { older[1].compactToolLog = (older[1].compactToolLog ?? "") + "• log line \(i): read_file /tmp/older-\(i).txt\n" }
        history.insert(contentsOf: older, at: 0)
        return history
    }

    /// F1 media: two pruned actions send the same document (one description
    /// request, first kept), a pruned assistant message references an image,
    /// and an older user message carries an image (media pruning).
    func mediaHistory() -> [Message] {
        var history = prunableHistory()
        let doc = file("shared-report.txt", "Shared report body for the F1 media fixture.\n")
        let args = "{\"file_path\":\"\(doc)\"}"
        history[1].toolInteractions = [toolRound(id: "send-1", size: 16_000, name: "send_document_to_chat", args: args)]
        history[3].toolInteractions = [toolRound(id: "send-2", size: 16_000, name: "send_document_to_chat", args: args)]
        let images = StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try? IRFixtures.png.write(to: images.appendingPathComponent("f1-ref.png"))
        try? IRFixtures.png.write(to: images.appendingPathComponent("f1-user.png"))
        history[5] = Message(id: history[5].id, role: .assistant, content: history[5].content, timestamp: history[5].timestamp,
                             referencedImageFileNames: ["f1-ref.png"], toolInteractions: history[5].toolInteractions)
        history[0] = Message(id: history[0].id, role: .user, content: history[0].content, timestamp: history[0].timestamp,
                             imageFileNames: ["f1-user.png"])
        return history
    }

    /// F1 reasoning removal: pruned assistant messages carry final reasoning.
    func reasoningHistory() -> [Message] {
        var history = prunableHistory()
        for i in history.indices where history[i].role == .assistant {
            history[i].finalReasoning = .string("fixture reasoning \(i) " + String(repeating: "think ", count: 400))
            history[i].finalReasoningModel = "glm-5.3"
        }
        return history
    }

    /// F1 six compact logs (index 0 cleared outside the manifest).
    func compactLogHistory() -> [Message] {
        var history = prunableHistory(pairs: 10)
        var logged = 0
        for i in history.indices where history[i].role == .assistant && logged < 6 {
            history[i].compactToolLog = "• compact log \(logged): read_file /tmp/log-\(logged).txt (\(logged * 10) lines)"
            logged += 1
        }
        return history
    }

    // MARK: Provider

    func configure(responses: Bool) throws {
        let settings = [
            KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
            KeychainHelper.openAICompatibleBaseURLKey: "http://127.0.0.1:\(server.port)/v1",
            KeychainHelper.openAICompatibleApiKeyKey: apiKey,
            KeychainHelper.openAICompatibleModelKey: model,
            KeychainHelper.assistantNameKey: "Fixture Assistant",
            KeychainHelper.emailCalendarProviderKey: EmailCalendarProvider.none.rawValue,
            KeychainHelper.textOnlyModelEnabledKey: "false",
            KeychainHelper.maxContextTokensKey: "40000",
            KeychainHelper.targetContextTokensKey: "10000",
            KeychainHelper.archiveChunkSizeKey: "1000000",
        ]
        for (key, value) in settings { try KeychainHelper.save(key: key, value: value) }
        if responses {
            try ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                             model: model, effort: nil, textOnly: false, wireProtocol: .responses)
            try ProviderProfiles.activate(.custom)
        }
    }

    func manager(history: [Message]) async -> ConversationManager {
        let manager = ConversationManager()
        await manager._testPrepareScriptedProvider(apiKey: apiKey)
        manager._testSeedHistory(history)
        manager._svRegisterChannel(channel)
        manager._svSetLastUserAddress(address)
        try? await Task.sleep(nanoseconds: 100_000_000)
        return manager
    }

    var activitySubscription: AnyCancellable?

    /// Every change of the maintenance-activity list, in order (the
    /// @Published publisher fires synchronously on each mutation).
    func sampleActivities(_ manager: ConversationManager) -> Task<Void, Never> {
        activitySubscription = manager.$maintenanceActivities.sink { [weak self] list in
            let now = list.map { "\($0.kind)" }.sorted().joined(separator: "+")
            MainActor.assumeIsolated { self?.activities.append(now.isEmpty ? "-" : now) }
        }
        return Task {}
    }

    func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func turn(_ manager: ConversationManager, _ text: String, at offset: TimeInterval) async {
        manager._testStartTurn(for: Message(role: .user, content: text,
                                            timestamp: Date(timeIntervalSince1970: 1_790_100_000 + offset)))
        _ = await manager._testAwaitIdle(timeout: 60)
    }

    // MARK: Scenarios

    func run(_ scenario: String) async -> [String: Any] {
        PruneArchiveStore.identityForTesting = { [weak self] in
            let n = MainActor.assumeIsolated { () -> Int in
                guard let self else { return 0 }
                self.identityCounter += 1
                return self.identityCounter
            }
            return (Date(timeIntervalSince1970: 1_790_200_000 + Double(n)),
                    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
        }
        let parts = scenario.split(separator: ":").map(String.init)
        let family = parts[0]
        var manager: ConversationManager?
        do {
            switch family {
            case "o1": manager = try await o1(site: parts[1], variant: parts[2])
            case "o9": manager = try await o9(path: parts[1], proto: parts[2], variant: parts[3])
            case "f1": manager = try await f1(variant: parts[1])
            default: notes.append("unknown scenario \(scenario)")
            }
        } catch {
            notes.append("driver error: \(error)")
        }
        return await collect(manager)
    }

    /// O1: the prune helpers OFF at both sites.
    func o1(site: String, variant: String) async throws -> ConversationManager {
        try configure(responses: false)
        if ["success", "rejected", "tools", "error"].contains(variant) { router.summaryMode = variant }
        let history: [Message]
        if variant == "exhausted", site == "mid" {
            // Nothing older to prune: the mid-loop prune is exhausted and
            // today's active-turn compaction runs.
            history = [Message(role: .user, content: "short question", timestamp: Date(timeIntervalSince1970: 1_790_000_000)),
                       Message(role: .assistant, content: "short answer", timestamp: Date(timeIntervalSince1970: 1_790_000_060))]
        } else if variant == "exhausted" {
            // Pre site: content above the maximum. Mid site: under it, the
            // tool round's measured usage crosses it.
            let words = site == "pre" ? 9_000 : 4_000
            var plain = (0..<6).map { i in
                Message(role: i % 2 == 0 ? .user : .assistant, content: "plain-\(i) " + String(repeating: "word ", count: words),
                        timestamp: Date(timeIntervalSince1970: 1_790_000_000 + Double(i * 60)))
            }
            plain.append(Message(role: .user, content: "tail", timestamp: Date(timeIntervalSince1970: 1_790_000_500)))
            history = plain
        } else {
            // Pre site: request bytes above the maximum. Mid site: under it.
            history = site == "pre" ? prunableHistory() : prunableHistory(size: 8_000)
        }
        let manager = await manager(history: history)
        let sampler = sampleActivities(manager)
        defer { sampler.cancel() }
        switch variant {
        case "snapshot-fault":
            var armed = true
            PruneArchiveStore.faultForTesting = { stage in
                if armed { armed = false; throw NSError(domain: "offdiff", code: 1, userInfo: [NSLocalizedDescriptionKey: "injected snapshot fault at \(stage)"]) }
            }
        case "history-fault":
            var armed = false
            ConversationManager.beforePruneHistoryWriteForTesting = { armed = true }
            ConversationManager.historyWriteFaultForTesting = {
                if armed { armed = false; throw NSError(domain: "offdiff", code: 2, userInfo: [NSLocalizedDescriptionKey: "injected history fault"]) }
            }
        case "stop":
            router.holdSummary = true
        default: break
        }
        if site == "pre" {
            server.script([Self.chat("answered after the prune", prompt: 100)])
            manager._testStartTurn(for: Message(role: .user, content: "over the maximum, pre-request site",
                                                timestamp: Date(timeIntervalSince1970: 1_790_100_100)))
        } else {
            let path = file("mid.txt", "mid-loop fixture file\n" + String(repeating: "current-turn line\n", count: variant == "exhausted" ? 2_000 : 1))
            if variant == "exhausted" {
                server.script([Self.tools([(id: "mid-call-1", name: "read_file", args: ["path": path])], prompt: 1_000),
                               Self.tools([(id: "mid-call-2", name: "read_file", args: ["path": path])], prompt: 1_000),
                               Self.tools([(id: "mid-call-3", name: "read_file", args: ["path": path])], prompt: 60_000),
                               Self.chat("answered after the compaction", prompt: 100),
                               Self.chat("spare", prompt: 100)])
            } else {
                server.script([Self.tools([(id: "mid-call-1", name: "read_file", args: ["path": path])], prompt: 60_000),
                               Self.chat("answered after the mid-loop prune", prompt: 100)])
            }
            // A fresh measurement under the maximum so only the mid-loop site acts.
            manager._testStartTurn(for: Message(role: .user, content: "mid-loop site",
                                                timestamp: Date(timeIntervalSince1970: 1_790_100_100)))
        }
        if variant == "stop" {
            if await waitUntil(20, { self.router.gate.arrived == 1 }) {
                replies.append(await manager.handleTerminalCommand("/stop")?.joined(separator: "\n") ?? "<nil>")
            } else {
                notes.append("summary never held")
            }
            router.gate.release()
        }
        _ = await manager._testAwaitIdle(timeout: 60)
        PruneArchiveStore.faultForTesting = nil
        ConversationManager.historyWriteFaultForTesting = nil
        ConversationManager.beforePruneHistoryWriteForTesting = nil
        return manager
    }

    /// O9: receipt calls OFF.
    func o9(path: String, proto: String, variant: String) async throws -> ConversationManager {
        let responses = proto == "responses"
        try configure(responses: responses)
        if path == "final" { try AgentTurnOverrides.setOverride(1, forAgent: "main") }
        var history: [Message] = []
        if variant == "image" {
            let dir = StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? IRFixtures.png.write(to: dir.appendingPathComponent("o9-old.png"))
            history = [Message(role: .user, content: "look at this", timestamp: Date(timeIntervalSince1970: 1_790_000_000), imageFileNames: ["o9-old.png"]),
                       Message(role: .assistant, content: "seen", timestamp: Date(timeIntervalSince1970: 1_790_000_060))]
        }
        let manager = await manager(history: history)
        let sampler = sampleActivities(manager)
        defer { sampler.cancel() }
        let rejection = responses ? Self.responsesRejection : Self.chatRejection
        switch variant {
        case "render":
            HarnessAnnotationRenderer.simulateRenderFailureForTesting = true
            server.script([toolsReply([(id: "o9-bash", name: "bash", args: ["command": "sleep 1.5; echo o9"])], responses: responses, id: "1"),
                           reply("after the render failure", responses: responses, id: "2"),
                           reply("later turn", responses: responses, id: "3"),
                           reply("spare", responses: responses, id: "4")])
            manager._testStartTurn(for: Message(role: .user, content: "o9 render", timestamp: Date(timeIntervalSince1970: 1_790_100_000)))
            try? await Task.sleep(nanoseconds: 300_000_000)
            await manager._testDispatchUser(Message(role: .user, content: "o9 mid-turn note", timestamp: Date(timeIntervalSince1970: 1_790_100_001)))
            _ = await manager._testAwaitIdle(timeout: 60)
            try? await Task.sleep(nanoseconds: 500_000_000)
            _ = await manager._testAwaitIdle(timeout: 60)
            HarnessAnnotationRenderer.simulateRenderFailureForTesting = false
        case "image":
            let target = "/etc/hosts"   // identical in both runs (replay fingerprints hash call arguments)
            server.script([toolsReply([(id: "o9-read", name: "read_file", args: ["path": target])], responses: responses, id: "1"),
                           rejection, reply("done after rejection", responses: responses, id: "2")],
                          statuses: [200, 400, 200])
            manager._testStartTurn(for: Message(role: .user, content: "o9 image", timestamp: Date(timeIntervalSince1970: 1_790_100_000)))
            _ = await manager._testAwaitIdle(timeout: 60)
        default:
            let target = "/etc/hosts"   // identical in both runs (replay fingerprints hash call arguments)
            server.script([toolsReply([(id: "o9-read", name: "read_file", args: ["path": target])], responses: responses, id: "1"),
                           reply("done", responses: responses, id: "2")])
            manager._testStartTurn(for: Message(role: .user, content: "o9 success", timestamp: Date(timeIntervalSince1970: 1_790_100_000)))
            _ = await manager._testAwaitIdle(timeout: 60)
        }
        if path == "final" { try? AgentTurnOverrides.setOverride(nil, forAgent: "main") }
        return manager
    }

    /// F1: on the candidate (mode "on"), freeze + apply with nothing
    /// appended; on 0.2.56 (mode "off"), today's inline prune on the same
    /// inputs. The script compares the frozen prefix and every snapshot file.
    func f1(variant: String) async throws -> ConversationManager {
        try configure(responses: false)
        if mode == "on" { UserDefaults.standard.set(true, forKey: "ada.pruneBackground") }
        if ["error", "rejected", "tools"].contains(variant) { router.summaryMode = variant }
        if variant == "descfail" { router.failFirstDescription = true }
        let history: [Message]
        switch variant {
        case "rich": history = richHistory()
        case "media", "descfail": history = mediaHistory()
        case "reasoning": history = reasoningHistory()
        case "compactlogs": history = compactLogHistory()
        default: history = prunableHistory()
        }
        notes.append("seeded \(history.count)")
        let manager = await manager(history: history)
        server.script([Self.chat("answered", prompt: 100), Self.chat("answered again", prompt: 100)])
        await turn(manager, "over the maximum", at: 100)
        if mode == "on" {
            // Nothing appended to the frozen range; the ready job is applied
            // at the next boundary (T0 of the next turn).
            // The worker may still be retrying (transport backoff): wait until
            // the loopback has been quiet for 8 s (at most 90 s) before the
            // next turn. The base build has no job accessor to poll.
            var last = server.completeRequests.count
            var quietSince = Date()
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let now = server.completeRequests.count
                if now != last { last = now; quietSince = Date() }
                if Date().timeIntervalSince(quietSince) >= 8 { break }
            }
            await turn(manager, "next turn applies the ready job", at: 200)
        }
        return manager
    }

    // MARK: Collection

    func collect(_ manager: ConversationManager?) async -> [String: Any] {
        _ = StageMarkers.flush(timeout: 5)
        var result: [String: Any] = [:]
        let requests = server.completeRequests.map { request -> [String: Any] in
            ["target": request.target, "kind": BgPruneDiffRouter.kind(request),
             "body": String(data: request.body, encoding: .utf8) ?? "<binary>"]
        }
        result["requests"] = requests
        if let manager {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            result["history"] = String(data: (try? encoder.encode(manager._testMessages)) ?? Data(), encoding: .utf8) ?? ""
            result["error"] = manager._testLastError ?? NSNull()
        }
        result["notices"] = channel.delivered
        result["replies"] = replies
        result["activities"] = activities
        result["receipts"] = BgPruneDiffRecorder.shared.all
        result["notes"] = notes
        result["files"] = tree(StoragePaths.dataRoot, skip: ["logs"])
        result["config"] = tree(StoragePaths.configRoot, skip: [])
        result["stages"] = (try? String(contentsOf: StageMarkers.logURL, encoding: .utf8)) ?? ""
        let defaults = UserDefaults.standard.dictionaryRepresentation().filter { key, _ in
            key.hasPrefix("briglia.") || key.hasPrefix("ada.") || key.hasPrefix("sm.")
        }
        result["defaults"] = defaults.mapValues { "\($0)" }
        result["port"] = server.port
        result["startedAt"] = startedAt.timeIntervalSince1970
        result["endedAt"] = Date().timeIntervalSince1970
        result["dataRoot"] = StoragePaths.dataRoot.path
        result["configRoot"] = StoragePaths.configRoot.path
        return result
    }

    func tree(_ root: URL, skip: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        let resolved = root.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in walker {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(resolved.path + "/") else { continue }
            let rel = String(path.dropFirst(resolved.path.count + 1))
            if skip.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else { continue }
            out[rel] = String(data: data, encoding: .utf8) ?? ("b64:" + data.base64EncodedString())
        }
        return out
    }
}
