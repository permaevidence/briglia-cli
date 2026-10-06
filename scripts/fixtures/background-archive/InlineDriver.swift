import ArgumentParser
import Foundation

// Copied into DISPOSABLE builds only (scripts/background_archive_inline_test.py),
// identically for the v0.2.49 base and the candidate. One archive turn plus
// one ordinary turn against a loopback server, fixed inputs; writes every
// request body, every channel text and the final history.
final class InlineDriverChannel: ChatChannel, @unchecked Sendable {
    let kind: ChannelKind = .telegram
    private let lock = NSLock()
    private var _texts: [(Date, String)] = []
    var texts: [(Date, String)] { lock.lock(); defer { lock.unlock() }; return _texts }
    func sendText(chatId: String, text: String) async throws { lock.lock(); _texts.append((Date(), text)); lock.unlock() }
    func sendPhoto(chatId: String, imageData: Data, caption: String?, mimeType: String) async throws {}
    func sendDocument(chatId: String, documentData: Data, filename: String, caption: String?, mimeType: String) async throws {}
}

struct BackgroundArchiveInlineDriver: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__background-archive-inline-driver", shouldDisplay: false)
    @Option var out: String
    @Option var mode: String = "inline"
    @Option var delay: Double = 0
    @Flag var serial = false

    @MainActor func run() async throws {
        let server = try CaptureServer()
        defer { server.stop() }
        let summary = (["Fixture summary of the archived segment."] + Array(repeating: "detail", count: 140)).joined(separator: " ")
        let delay = self.delay
        func chat(_ text: String) -> String {
            let body: [String: Any] = ["id": "inline", "object": "chat.completion", "model": "glm-5.3",
                "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
                "usage": ["prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110]]
            return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
        }
        let summaryBody = chat(summary), noChanges = chat("NO_CHANGES")
        server.concurrent = !serial
        server.router = { request in
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any], object["tools"] == nil else { return nil }
            let system = ArchiveFullChunkSelftest.systemContent(request.body)
            if system.contains(ArchiveFullChunkSelftest.extractionMarker) { return (noChanges, 0) }
            return (summaryBody, system.contains(ArchiveFullChunkSelftest.summaryMarker) ? delay : 0)
        }
        let settings = [
            KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
            KeychainHelper.openAICompatibleBaseURLKey: "http://127.0.0.1:\(server.port)/v1",
            KeychainHelper.openAICompatibleApiKeyKey: "synthetic-inline-key",
            KeychainHelper.openAICompatibleModelKey: "glm-5.3",
            KeychainHelper.assistantNameKey: "Fixture Assistant",
            KeychainHelper.emailCalendarProviderKey: EmailCalendarProvider.none.rawValue,
            KeychainHelper.textOnlyModelEnabledKey: "false",
        ]
        for (key, value) in settings { try KeychainHelper.save(key: key, value: value) }
        UserDefaults.standard.set(mode == "inline", forKey: "ada.archiveInline")
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
        let history = (0..<24).map { i in
            Message(id: id(i), role: i % 2 == 0 ? .user : .assistant,
                    content: ArchiveFullChunkSelftest.filler("old-\(i)", size: 4_000, sentinel: "end of old-\(i)."),
                    timestamp: base.addingTimeInterval(TimeInterval(i * 60)))
        }
        let manager = ConversationManager()
        await manager._testPrepareScriptedProvider(apiKey: "synthetic-inline-key")
        manager._testSeedHistory(history)
        let channel = InlineDriverChannel()
        manager._inlineAttach(channel, address: ChannelAddress(kind: .telegram, chatId: "777"))
        var turns: [[String: Any]] = []
        for (n, text) in ["the archive turn", "the following turn"].enumerated() {
            server.script([chat("reply \(n)")])
            let started = Date()
            manager._testStartTurn(for: Message(id: id(100 + n), role: .user, content: text, timestamp: base.addingTimeInterval(TimeInterval(3_600 + n * 60))))
            var firstReply: TimeInterval = -1
            while firstReply < 0 && Date().timeIntervalSince(started) < 120 {
                if let hit = channel.texts.first(where: { $0.1 == "reply \(n)" }) { firstReply = hit.0.timeIntervalSince(started) }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            _ = await manager._testAwaitIdle(timeout: 180)
            turns.append(["first_reply_seconds": firstReply, "idle_seconds": Date().timeIntervalSince(started)])
            // Let a background job finish before the next turn (inline: no-op).
            let settle = Date()
            while !manager.maintenanceActivities.isEmpty && Date().timeIntervalSince(settle) < 120 {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let requests: [[String: Any]] = server.completeRequests.map {
            ["target": $0.target, "body_base64": $0.body.base64EncodedString(),
             "main": ((try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["tools"] != nil)]
        }
        let historyData = (try? Data(contentsOf: StoragePaths.dataRoot.appendingPathComponent("conversation.json"))) ?? Data()
        let chunks = await manager._testArchiveService.getAllChunks().map { ["summary": $0.summary, "messages": $0.messageCount] as [String: Any] }
        let output: [String: Any] = ["requests": requests, "notices": channel.texts.map(\.1),
                                     "history_base64": historyData.base64EncodedString(), "chunks": chunks, "turns": turns]
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: out))
    }
}
