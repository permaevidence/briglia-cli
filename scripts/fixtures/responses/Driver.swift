import Foundation
import ArgumentParser

// UserDefaults reads AND writes are redirected here only in disposable builds.
enum P2Life {
    static let defaults = UserDefaults(suiteName: "dev.briglia.p2.lifecycle")!
    static var liveMode = false
    static var failSalvageAt: Int?
    static var salvageWrites = 0
    static func beforeSalvage(_ url: URL) throws {
        salvageWrites += 1
        if salvageWrites == failSalvageAt {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("block replacement".utf8).write(to: url.appendingPathComponent("sentinel"))
        }
    }
    private static let budgetLock = NSLock()
    private static var requests = 0
    static func claimLiveRequest() throws {
        budgetLock.lock(); defer { budgetLock.unlock() }
        if liveMode {
            requests += 1
            guard requests <= 8 else { throw Failure("live eight-request cap reached") }
        }
    }
    struct Failure: Error { let description: String; init(_ s: String) { description = s } }
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(label) }
        print("PASS " + label)
    }
    static func body(_ text: String, tool: String? = nil, path: String = "", id: String = UUID().uuidString,
                     status: String = "completed", toolArgs: [String: Any]? = nil) throws -> String {
        var output: [[String: Any]] = [
            ["type": "reasoning", "id": "rs_" + id, "summary": [], "encrypted_content": "opaque_" + id],
            ["type": "message", "role": "assistant", "status": "completed", "id": "msg_" + id,
             "content": [["type": "output_text", "text": text, "annotations": []]]]
        ]
        if let tool {
            let arguments = String(data: try JSONSerialization.data(withJSONObject: toolArgs ?? ["path": path]), encoding: .utf8)!
            output.append(["type": "function_call", "id": "fc_" + id, "call_id": "call_" + id,
                           "status": "completed", "name": tool, "arguments": arguments])
        }
        return String(data: try JSONSerialization.data(withJSONObject: ["id": "resp_" + id,
            "status": status, "output": output, "usage": ["input_tokens": 100, "output_tokens": 30]],
            options: .sortedKeys), encoding: .utf8)!
    }
    static func input(_ request: CapturedHTTPRequest) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
        return root["input"] as! [[String: Any]]
    }
}

struct ResponsesLifecycleSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__responses-lifecycle-selftest", shouldDisplay: false)
    @Option var output: String
    @Flag var live = false
    @Flag var resumeLive = false
    @MainActor func run() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: output)
        if !resumeLive { try fm.createDirectory(at: root, withIntermediateDirectories: false) }
        for (key, child) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(child).path, 1)
        }
        P2Life.defaults.removePersistentDomain(forName: "dev.briglia.p2.lifecycle")
        defer { P2Life.defaults.removePersistentDomain(forName: "dev.briglia.p2.lifecycle") }
        SetupAPICore.defaults = P2Life.defaults
        FileDescriptionsStore._testStoreURL = root.appendingPathComponent("descriptions.json")
        let server = try CaptureServer(); defer { server.stop() }
        var key = "synthetic-p2-key", model = "fixture-model", base = "http://127.0.0.1:\(server.port)/v1"
        P2Life.liveMode = live
        if live {
            let bytes = FileHandle.standardInput.readDataToEndOfFile()
            let input = try JSONSerialization.jsonObject(with: bytes) as! [String: String]
            guard let liveKey = input["api_key"], !liveKey.isEmpty else { throw P2Life.Failure("live key missing") }
            key = liveKey; model = "gpt-5.6-luna"; base = "https://api.openai.com/v1"
        }
        try ProviderProfiles.saveProfile(.custom, apiKey: key, baseURL: base, model: model,
            effort: live ? "low" : nil, textOnly: false, wireProtocol: .responses)
        try ProviderProfiles.activate(.custom)
        let settings = [KeychainHelper.maxContextTokensKey: "10000", KeychainHelper.targetContextTokensKey: "5000",
            KeychainHelper.archiveChunkSizeKey: "1000000", KeychainHelper.assistantNameKey: "Fixture Assistant",
            KeychainHelper.userNameKey: "Fixture User", KeychainHelper.emailCalendarProviderKey: "none"]
        try KeychainHelper.saveBatch(settings.mapValues { Optional($0) })
        let file = root.appendingPathComponent("read.txt")
        try Data("P2_TOOL_READ_OK".utf8).write(to: file)
        let manager = ConversationManager()
        if resumeLive {
            _ = try manager.p2Reload()
            let next = try await manager.p2Turn(human: Message(role: .user, content: "Without tools, repeat only the exact marker you read in the text file."))
            try P2Life.require(await manager.p2Error() == nil && next.last?.content.contains("P2_TOOL_READ_OK") == true, "live new-process continuation succeeds")
            return
        }
        try await manager.p2Seed([])
        if live {
            try await runLive(manager, root: root, textFile: file)
        } else {
            try await runMain(manager, server: server, root: root, file: file)
            try await runSubagents(server: server, root: root, file: file)
        }
        print("Responses lifecycle PASS")
    }

    @MainActor private func runMain(_ manager: ConversationManager, server: CaptureServer, root: URL, file: URL) async throws {
        server.script([try P2Life.body("Reading", tool: "read_file", path: file.path), try P2Life.body("Completed")])
        let queued = Message(role: .user, content: "Also confirm the queued instruction.")
        let saved = try await manager.p2Turn(human: Message(role: .user, content: "Read the fixture"), queued: queued)
        try P2Life.require(await manager.p2Error() == nil, "main loop completes")
        try P2Life.require(saved.last?.responsesReplay != nil && saved.last?.toolInteractions.count == 1, "main final and tool replay saved")
        try P2Life.require(saved.last?.toolInteractions.first?.results.first?.content.contains("P2_TOOL_READ_OK") == true, "real tool executed")
        try P2Life.require(await manager.p2Queue().isEmpty, "carried midturn batch acknowledged")
        try P2Life.require(saved.filter { $0.id == queued.id }.count == 1, "one canonical midturn user")
        let reloaded = try manager.p2Reload()
        try P2Life.require(reloaded.last?.responsesReplay?.fingerprint == saved.last?.responsesReplay?.fingerprint, "main restart replay restored")
        server.script([try P2Life.body("After restart")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Continue after restart"))
        let replay = try P2Life.input(server.completeRequests.last!)
        try P2Life.require(replay.filter { $0["type"] as? String == "function_call_output" }.count == 1, "restart replays one result")
        try P2Life.require(replay.contains { $0["encrypted_content"] != nil }, "restart carries matching ciphertext")
        let old = saved.last!
        let protected = Message(role: .assistant, content: "Protected recent work", toolInteractions: old.toolInteractions)
        server.script([try P2Life.body("Useful details retained by summary")])
        let pruned = try await manager.p2Prune([Message(role: .user, content: "Earlier work"), old,
            Message(role: .user, content: "Recent work"), protected])
        try P2Life.require(pruned.first { $0.id == old.id }?.responsesReplay == nil
            && pruned.first { $0.id == old.id }?.toolInteractions.isEmpty == true, "manual pruning removes evicted native replay")
        try P2Life.require(pruned.first { $0.id == protected.id }?.toolInteractions.isEmpty == false, "manual pruning preserves newest tool turn")
        let summaryBody = try JSONSerialization.jsonObject(with: server.completeRequests.last!.body) as! [String: Any]
        try P2Life.require((summaryBody["tools"] as? [Any])?.isEmpty == true, "Responses prune summary mechanically disables tools")
        // Failed terminal result must preserve queued delivery and completed work.
        try await manager.p2Seed([])
        server.script([try P2Life.body("Reading", tool: "read_file", path: file.path), try P2Life.body("partial", status: "failed")])
        let retryUser = Message(role: .user, content: "Queued during failure")
        let failed = try await manager.p2Turn(human: Message(role: .user, content: "Read again"), queued: retryUser)
        try P2Life.require(await manager.p2Error() != nil, "failed terminal surfaces error")
        try P2Life.require(await manager.p2Queue().map(\.id) == [retryUser.id], "failed terminal requeues exactly once")
        try P2Life.require(failed.last?.toolInteractions.first?.results.first?.content.contains("P2_TOOL_READ_OK") == true, "failure retains completed tool work")
        try P2Life.require(server.remainingResponses == 0 && server.errors.isEmpty, "main capture script exhausted without errors")
        try await manager.p2Seed([])
        for failingWrite in [1, 2] {
            let target = root.appendingPathComponent("side-effect-\(failingWrite).txt")
            P2Life.salvageWrites = 0; P2Life.failSalvageAt = failingWrite
            server.clear()
            server.script([try P2Life.body("Writing", tool: "write_file", toolArgs: ["path": target.path, "content": "persisted intent first"])])
            _ = try await manager.p2Turn(human: Message(role: .user, content: "Write the disposable fixture"))
            P2Life.failSalvageAt = nil
            try P2Life.require(await manager.p2Error() != nil, "salvage write \(failingWrite) failure surfaces")
            try P2Life.require(FileManager.default.fileExists(atPath: target.path) == (failingWrite == 2),
                failingWrite == 1 ? "failed intent prevents side effect" : "failed result save preserves already executed side effect")
            try P2Life.require(server.completeRequests.count == 1, "save failure prevents continuation and automatic rerun")
            let salvage = StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json")
            if FileManager.default.fileExists(atPath: salvage.path) { try FileManager.default.removeItem(at: salvage) }
            try await manager.p2Seed([])
        }
    }

    @MainActor private func runSubagents(server: CaptureServer, root: URL, file: URL) async throws {
        let runner = SubagentRunner(), service = OpenRouterService(), executor = ToolExecutor(outputMode: .subagent)
        let invocation = SubagentRunner.Invocation(subagentType: "general-purpose", description: "Responses worker",
            taskPrompt: "Read fixture", modelOverride: nil, runInBackground: false)
        server.clear()
        server.script([try P2Life.body("Reading", tool: "read_file", path: file.path), try P2Life.body("Worker completed")])
        let first = await runner.run(invocation: invocation, sessionId: nil, openRouterService: service,
            toolExecutor: executor, imagesDirectory: root, documentsDirectory: root, parentTools: [AvailableTools.readFile])
        try P2Life.require(first.error == nil && first.sessionPersisted, "new subagent executes and persists")
        let path = StoragePaths.dataRoot.appendingPathComponent("subagent_sessions/\(first.sessionId).json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(SubagentSessionRegistry.Session.self, from: Data(contentsOf: path))
        try P2Life.require(session.messages.last?.responsesReplay != nil && session.messages.last?.toolInteractions.count == 1,
            "subagent final owns replay and calls chronologically")
        server.script([try P2Life.body("Resumed worker")])
        let resumed = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service,
            toolExecutor: executor, imagesDirectory: root, documentsDirectory: root, parentTools: [])
        try P2Life.require(resumed.error == nil && resumed.sessionPersisted, "resumed subagent completes")
        let input = try P2Life.input(server.completeRequests.last!)
        let resultIndex = input.firstIndex { $0["type"] as? String == "function_call_output" }
        let lastUser = input.lastIndex { $0["role"] as? String == "user" }
        try P2Life.require(resultIndex != nil && lastUser != nil && resultIndex! < lastUser!, "resumed user follows completed tool result")
        try P2Life.require(server.remainingResponses == 0 && server.errors.isEmpty, "subagent capture script exhausted")
    }

    @MainActor private func runLive(_ manager: ConversationManager, root: URL, textFile: URL) async throws {
        let image = root.appendingPathComponent("pixel.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKElEQVR4nO3NsQ0AAAzCMP5/un0CNkuZ41wybXsHAAAAAAAAAAAAxR4yw/wuPL6QkAAAAABJRU5ErkJggg==")!
        try png.write(to: image)
        let prompt = "This is a bounded harness test. Use read_file on \(textFile.path) and \(image.path), then reply with the text file contents and a brief image observation. Use no other tools."
        let saved = try await manager.p2Turn(human: Message(role: .user, content: prompt))
        try P2Life.require(await manager.p2Error() == nil, "live main request succeeds")
        guard let final = saved.last, final.responsesReplay != nil else { throw P2Life.Failure("live native replay missing") }
        let results = final.toolInteractions.flatMap(\.results)
        try P2Life.require(results.contains { $0.content.contains("P2_TOOL_READ_OK") }, "live text tool succeeds")
        try P2Life.require(results.contains { !$0.fileAttachmentReferences.isEmpty }, "live image tool returned media")
        print("Live first phase passed; invoke --live --resume-live on this same isolated root for process-restart verification.")
    }
}
