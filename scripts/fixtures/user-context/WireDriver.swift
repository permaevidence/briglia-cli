import ArgumentParser
import Foundation

/// Disposable-build driver for scripts/user_context_wire_test.py. Compiled
/// identically into the v0.2.48 base and the candidate, so it may only use
/// APIs both have. The runner provides the isolated scratch home (HOME,
/// XDG_*, CFFIXED_USER_HOME) and a reserved link name; this driver refuses
/// to run anywhere else.
struct UserContextWireDriver: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__user-context-wire-driver", shouldDisplay: false)

    @Option(name: .long) var mode: String
    @Option(name: .long) var wireProtocol: String = "chat"
    @Option(name: .long) var out: String?
    @Option(name: .long) var file: String?

    static let maintenanceMarker = "You maintain the user profile"
    static let rewriteMarker = "reorganizing an AI assistant's persistent memory"
    static let extractionMarker = "extract NEW durable user-profile facts"

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var extractionReply = "NO_CHANGES"
        var scripted: [String] = []
        var maintenanceReply = "{}"
        func pop() -> String? { lock.lock(); defer { lock.unlock() }; return scripted.isEmpty ? nil : scripted.removeFirst() }
    }

    static func systemText(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        if let messages = object["messages"] as? [[String: Any]] {
            return messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined(separator: "\n")
        }
        var out = object["instructions"] as? String ?? ""
        for item in object["input"] as? [[String: Any]] ?? [] where item["role"] as? String == "system" {
            for part in item["content"] as? [[String: Any]] ?? [] { out += "\n" + (part["text"] as? String ?? "") }
        }
        return out
    }

    static func kind(_ body: Data) -> String {
        let system = systemText(body)
        if system.contains(maintenanceMarker) { return "maintenance" }
        if system.contains(rewriteMarker) { return "rewrite" }
        if system.contains(extractionMarker) { return "extraction" }
        if system.contains("historical") || system.contains("meta-summary") || system.contains("META") { return "meta" }
        return "summary"
    }

    static func canonical(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "RAW:" + body.base64EncodedString()
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func messages(_ label: String, start: TimeInterval) -> [Message] {
        var out: [Message] = []
        for index in 0..<4 {
            let number: Int = Int(start) % 100_000_000 + index
            let id: UUID = UUID(uuidString: String(format: "AAAAAAAA-0000-0000-0000-%012d", number))!
            let role: Message.Role = index % 2 == 0 ? .user : .assistant
            let content: String = label + "-" + String(index) + ": the user mentioned plans, places and preferences in this exchange."
            let when: Date = Date(timeIntervalSince1970: start + TimeInterval(index * 60))
            out.append(Message(id: id, role: role, content: content, timestamp: when))
        }
        return out
    }

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard StoragePaths.dataRoot.path.contains("briglia-ucwire-"),
              ProcessInfo.processInfo.processName.hasPrefix("briglia-mw-ucwire") else {
            print("refusing to run outside the runner's scratch home"); throw ExitCode(2)
        }
        let state = State()
        let server = try WebFixtureServer()
        defer { server.stop() }
        let summaryText = (["Fixture summary of the archived segment."] + Array(repeating: "detail", count: 140)).joined(separator: " ")
        let responses = wireProtocol == "responses"
        server.route = { request in
            let kind = Self.kind(request.body)
            var text: String
            switch kind {
            case "maintenance": text = state.pop() ?? state.maintenanceReply
            case "rewrite":
                // v0.2.48's rewrite: echo the profile unchanged so both
                // builds keep identical profiles for the requests that follow.
                let system = Self.systemText(request.body)
                let open = "(your ONLY source — do not invent anything):\n---\n"
                if let a = system.range(of: open), let b = system.range(of: "\n---\n\nYOUR TASK", range: a.upperBound..<system.endIndex) {
                    text = String(system[a.upperBound..<b.lowerBound])
                } else { text = "" }
            case "extraction": text = state.pop() ?? state.extractionReply
            default: text = state.pop() ?? summaryText
            }
            if text.hasPrefix("@HTTP:") { return .init(status: Int(text.dropFirst(6)) ?? 500, body: "{\"error\":{\"message\":\"fixture\"}}") }
            if text == "@TOOLS" {
                return .init(body: responses ? WebFixtureServer.responsesBody("", id: "w", calls: [("bash", "{}")])
                                             : WebFixtureServer.chatBody("", calls: [("bash", "{}")]))
            }
            return .init(body: responses ? WebFixtureServer.responsesBody(text, id: "w") : WebFixtureServer.chatBody(text))
        }
        try ProviderProfiles.saveProfile(.custom, apiKey: "sk-fixture-ucwire-000000000000000", baseURL: "http://127.0.0.1:\(server.port)/v1",
                                         model: "glm-5.3", effort: nil, textOnly: false, wireProtocol: responses ? .responses : .chatCompletions)
        try ProviderProfiles.activate(.custom)
        try KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: "Fixture Assistant")
        try KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Fixture User")

        func record() -> [[String: Any]] {
            server.requests.map { ["path": $0.path, "kind": Self.kind($0.body), "body": Self.canonical($0.body)] }
        }
        func status(_ extra: [String: Any] = [:]) throws {
            let archive = StoragePaths.dataRoot.appendingPathComponent("archive")
            func digest(_ name: String) -> Any {
                guard let data = try? Data(contentsOf: archive.appendingPathComponent(name)) else { return NSNull() }
                return ["size": data.count, "base64": data.base64EncodedString()]
            }
            var object: [String: Any] = [
                "state": digest("user_context_state.json"), "retired": digest("retired_user_facts.jsonl"),
                "flag": UserDefaults.standard.object(forKey: "ada.archive.restructureRetryPending").map { "\($0)" } ?? NSNull(),
                "profile": KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? NSNull(),
                "requests": record(),
            ]
            for (k, v) in extra { object[k] = v }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: out!))
        }
        // ~56k: maintenance (two passes of 150 drops) leaves ~35k, still over
        // v0.2.48's 20k rewrite threshold for the downgrade rows.
        let big = (1...800).map { "- Wire fact \($0): a stable durable preference about the user number \($0)." }.joined(separator: "\n")

        switch mode {
        case "capture":
            try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: "- small fact one\n- small fact two")
            let archive = ConversationArchiveService()
            state.extractionReply = "Fact one learned"
            _ = try await archive.archiveMessages(Self.messages("c1", start: 1_790_000_000))
            state.extractionReply = "@HTTP:500"
            _ = try await archive.archiveMessages(Self.messages("c2", start: 1_790_010_000))
            state.extractionReply = "NO_CHANGES"
            for (index, start) in [1_790_020_000, 1_790_030_000, 1_790_040_000, 1_790_050_000].enumerated() {
                _ = try await archive.archiveMessages(Self.messages("c\(index + 3)", start: TimeInterval(start)))
            }
            _ = try await archive.wireMeta()
            let archiveRequests = record()
            // Default-path retry behaviour (no budget): tool-call re-asks / adapter retries.
            server.clear()
            state.scripted = responses ? ["@HTTP:503", "@HTTP:503", "ok"] : ["@TOOLS", "@TOOLS", "ok"]
            _ = try await archive.wireCall(system: "Probe system", user: "probe")
            let retryCount = server.requests.count
            server.clear()
            try status(["retryProbeSends": retryCount, "requests": archiveRequests])
        case "upgrade-step", "reupgrade-step", "downgrade-step":
            if mode == "upgrade-step" { try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: big) }
            let archive = ConversationArchiveService()
            await archive.recoverPendingChunks(defaultContext: .empty)
            state.extractionReply = "Learned in \(mode)"
            state.maintenanceReply = "{\"drop\":[" + (1...150).map(String.init).joined(separator: ",") + "]}"
            let start: TimeInterval = mode == "upgrade-step" ? 1_791_000_000 : mode == "downgrade-step" ? 1_792_000_000 : 1_793_000_000
            _ = try await archive.archiveMessages(Self.messages(mode, start: start))
            try status()
        case "mind-export":
            try await MindExportService.shared.exportMind(to: URL(fileURLWithPath: file!))
            try status()
        case "mind-import":
            let staged = try await MindExportService.shared.stageMind(from: URL(fileURLWithPath: file!))
            try await MindExportService.shared.applyStagedMind(staged)
            await ConversationArchiveService().recoverPendingChunks(defaultContext: .empty)
            try status()
        default:
            throw ValidationError("unknown mode")
        }
    }
}
