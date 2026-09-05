import Foundation
import ArgumentParser

// UserDefaults reads AND writes are redirected here only in disposable builds.
enum P2Life {
    static let defaults = UserDefaults(suiteName: "dev.briglia.p2.lifecycle")!
    static var liveMode = false
    static var failFinalSave = false
    static var finalFaults = 0
    static var captureDelivery = false
    static var deliveries: [String] = []
    static var contexts: [ProviderExecutionContext] = []
    static func recordContext(_ context: ProviderExecutionContext) {
        budgetLock.lock(); defer { budgetLock.unlock() }
        contexts.append(context)
    }
    static func beforeConversationSave(_ url: URL, messages: [Message]) {
        guard failFinalSave, messages.last?.responsesReplay != nil else { return }
        failFinalSave = false
        do {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("before-final"))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("block final replacement".utf8).write(to: url.appendingPathComponent("sentinel"))
            finalFaults += 1
        } catch { preconditionFailure("could not inject final-save fault") }
    }
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
            try await runFinalSave(manager, server: server, file: file)
            try await runAuxiliary(server: server, root: root)
            try await runSwitching(manager, server: server, file: file)
            await manager.p2ReadOnlyCommands()
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

    @MainActor private func runFinalSave(_ manager: ConversationManager, server: CaptureServer, file: URL) async throws {
        try await manager.p2Seed([])
        server.clear()
        server.script([try P2Life.body("Read before final failure", tool: "read_file", path: file.path), try P2Life.body("FINAL_ANSWER_DELIVERED")])
        P2Life.failFinalSave = true; P2Life.captureDelivery = true; P2Life.deliveries = []
        var human = Message(role: .user, content: "Read the fixture, then answer")
        human.originChannel = ChannelAddress(kind: .app, chatId: "fixture")
        let history = try await manager.p2Turn(human: human)
        P2Life.captureDelivery = false
        try P2Life.require(P2Life.finalFaults == 1, "final save hits real filesystem write failure")
        try P2Life.require(await manager.p2Error() == nil && history.last?.content == "FINAL_ANSWER_DELIVERED", "failed final save keeps completed answer without error append")
        try P2Life.require(P2Life.deliveries.filter { $0 == "FINAL_ANSWER_DELIVERED" }.count == 1, "failed final save delivers answer exactly once")
        let ids = history.flatMap(\.toolInteractions).flatMap { $0.assistantMessage.toolCalls.map(\.id) }
        try P2Life.require(ids.count == 1 && Set(ids).count == ids.count, "failed final save never duplicates call ids")
        let salvage = StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json")
        try P2Life.require(FileManager.default.fileExists(atPath: salvage.path), "failed final save retains salvage")
        let disk = StoragePaths.dataRoot.appendingPathComponent("conversation.json")
        try FileManager.default.removeItem(at: disk)
        try FileManager.default.moveItem(at: disk.appendingPathExtension("before-final"), to: disk)
        _ = try manager.p2Reload(); manager.p2Recover()
        let recovered = try manager.p2Reload()
        try P2Life.require(recovered.flatMap(\.toolInteractions).count == 1 && !FileManager.default.fileExists(atPath: salvage.path), "restart recovers completed rounds once after final-save failure")
        for corrupt in [Data("not json".utf8), Data("[]".utf8)] {
            try corrupt.write(to: salvage); manager.p2Recover()
            try P2Life.require(!FileManager.default.fileExists(atPath: salvage.path), "invalid or empty salvage removed on startup")
        }
    }

    @MainActor private func runAuxiliary(server: CaptureServer, root: URL) async throws {
        server.clear(); P2Life.contexts = []
        let archive = ConversationArchiveService()
        await archive.configure(apiKey: "synthetic-unused-key")
        let summary = String(repeating: "Detailed fixture facts retained for the future. ", count: 100)
        server.script([try P2Life.body(summary), try P2Life.body(summary), try P2Life.body("You prefer concise replies and durable local memory.")])
        try P2Life.require(try await archive.p2Summary() == summary.trimmingCharacters(in: .whitespacesAndNewlines), "Responses archive summary decoded")
        try P2Life.require(try await archive.p2Meta() == summary.trimmingCharacters(in: .whitespacesAndNewlines), "Responses archive meta-summary decoded")
        try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: "You prefer concise replies.")
        try P2Life.require(await archive.p2Restructure(), "Responses archive restructure saved")
        try P2Life.require(KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) == "You prefer concise replies and durable local memory.", "restructured facts persist")
        server.script([try P2Life.body("Structured user fixture"), try P2Life.body("Structured second fixture"), try P2Life.body("fixture.png: A small red square.")])
        for index in 0..<2 {
            let structured = try await UserContextStructurer.structure(assistantName: "Fixture", userName: "User",
                rawContext: "Keep concise replies", existingContext: "", config: .fromKeychain())
            try P2Life.require(structured == (index == 0 ? "Structured user fixture" : "Structured second fixture"), "Responses standalone structurer decodes operation \(index)")
        }
        let service = OpenRouterService(); await service.configure(apiKey: "synthetic-unused-key")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKElEQVR4nO3NsQ0AAAzCMP5/un0CNkuZ41wybXsHAAAAAAAAAAAAxR4yw/wuPL6QkAAAAABJRU5ErkJggg==")!
        let descriptions = try await service.generateFileDescriptions(files: [("fixture.png", png, "image/png")])
        try P2Life.require(descriptions["fixture.png"] == "A small red square.", "Responses file description decoded")
        try P2Life.require(P2Life.contexts.count == 6 && P2Life.contexts.prefix(3).allSatisfy { $0.lane == .archive }, "archive operations use archive affinity lane")
        let ephemeral = P2Life.contexts.suffix(3).map { $0.lane.laneId }
        try P2Life.require(ephemeral.allSatisfy { $0.hasPrefix("ephemeral:") } && Set(ephemeral).count == 3, "structuring and descriptions get independent operation lanes")
        try P2Life.require(server.completeRequests.count == 6 && server.completeRequests.allSatisfy { $0.target == "/v1/responses" }, "all inherited auxiliaries target Responses")
        for request in server.completeRequests {
            let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            try P2Life.require(body["tools"] == nil && body["messages"] == nil, "auxiliary request has no tools or chat payload")
        }
        server.script([try P2Life.body("OK")])
        let probe = await Probes.responses(baseURL: "http://127.0.0.1:\(server.port)/v1", apiKey: "synthetic-p2-key", model: "gpt-5.6-luna")
        let probeBody = try JSONSerialization.jsonObject(with: server.completeRequests.last!.body) as! [String: Any]
        try P2Life.require(probe == nil && probeBody["max_output_tokens"] as? Int == 2048 && (probeBody["reasoning"] as? [String: String])?["effort"] == "low", "reasoning probe uses low effort and adequate cap")
        try P2Life.require(server.remainingResponses == 0 && server.errors.isEmpty, "auxiliary capture script exhausted")
    }

    @MainActor private func runSwitching(_ manager: ConversationManager, server: CaptureServer, file: URL) async throws {
        func select(_ wire: ProviderWireProtocol, key: String = "synthetic-p2-key") throws {
            try ProviderProfiles.saveProfile(.custom, apiKey: key, baseURL: "http://127.0.0.1:\(server.port)/v1",
                model: "kimi-k2.5", effort: nil, textOnly: false, wireProtocol: wire)
            try ProviderProfiles.activate(.custom)
        }
        func chat(_ text: String, tool: Bool = false) throws -> String {
            var message: [String: Any] = ["role": "assistant", "content": text,
                "reasoning_details": [["type": "reasoning.text", "text": "chat-only-reasoning", "format": "unknown"]]]
            if tool {
                let args = String(data: try JSONSerialization.data(withJSONObject: ["path": file.path]), encoding: .utf8)!
                message["tool_calls"] = [["id": "functions.read_file:0", "type": "function", "function": ["name": "read_file", "arguments": args]]]
            }
            return String(data: try JSONSerialization.data(withJSONObject: ["choices": [["message": message,
                "finish_reason": tool ? "tool_calls" : "stop"]], "usage": ["prompt_tokens": 100, "completion_tokens": 20]]), encoding: .utf8)!
        }
        try select(.chatCompletions); try await manager.p2Seed([]); server.clear()
        server.script([try chat("Chat tool round", tool: true), try chat("Chat final")])
        let chatHistory = try await manager.p2Turn(human: Message(role: .user, content: "Use the chat tool"))
        guard let chatFinal = chatHistory.last, let chatRound = chatFinal.toolInteractions.first else { throw P2Life.Failure("chat seed missing real round") }
        try P2Life.require(await manager.p2Error() == nil && chatRound.assistantMessage.toolCalls.first?.id == "functions.read_file:0"
            && chatRound.assistantMessage.reasoningDetails != nil && chatRound.assistantMessage.producedByModel != nil, "real chat history has foreign call id, reasoning details and provenance")
        let mappedID = "call_" + String(ResponsesReplayEnvelope.hash(Data("\(chatFinal.id):0:0:functions.read_file:0".utf8)).prefix(40))
        try select(.responses); server.clear()
        server.script([try P2Life.body("Native tool", tool: "read_file", path: file.path, id: "scopeA"), try P2Life.body("Native final", id: "scopeAfinal")])
        let native = try await manager.p2Turn(human: Message(role: .user, content: "Continue with native protocol and read again"))
        let first = try P2Life.input(server.completeRequests.first!)
        try P2Life.require(await manager.p2Error() == nil && first.allSatisfy { $0["encrypted_content"] == nil && $0["id"] == nil }, "chat to Responses excludes foreign provider identities and ciphertext")
        try P2Life.require(first.filter { $0["call_id"] as? String == mappedID }.count == 2,
            "chat call and result map to one deterministic Responses id")
        try P2Life.require(!String(decoding: server.completeRequests.first!.body, as: UTF8.self).contains("chat-only-reasoning"), "foreign reasoning details stay off Responses wire")
        try P2Life.require(native.last?.responsesReplay != nil, "native era retained after real manager switch")
        _ = try manager.p2Reload()
        try select(.chatCompletions); server.clear(); server.script([try chat("Back on chat")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Continue on chat"))
        let chatBytes = String(decoding: server.completeRequests.last!.body, as: UTF8.self)
        let chatBody = try JSONSerialization.jsonObject(with: server.completeRequests.last!.body) as! [String: Any]
        let messages = chatBody["messages"] as! [[String: Any]]
        let calls = messages.flatMap { ($0["tool_calls"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
        let results = messages.compactMap { $0["tool_call_id"] as? String }
        try P2Life.require(await manager.p2Error() == nil && server.completeRequests.last!.target == "/v1/chat/completions"
            && !chatBytes.contains("encrypted_content") && !chatBytes.contains("responsesReplay") && !chatBytes.contains("opaque_scopeA"), "native history passes frozen chat serializer without metadata leak")
        try P2Life.require(calls == results && calls.contains("functions.read_file:0") && calls.contains("call_scopeA"), "chat preserves canonical call ids and result pairing across protocols")
        try select(.responses, key: "synthetic-account-B"); server.clear(); server.script([try P2Life.body("Account B answer", id: "scopeB")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Use account B"))
        let accountB = try P2Life.input(server.completeRequests.last!)
        try P2Life.require(accountB.allSatisfy { $0["encrypted_content"] == nil }, "account switch omits A ciphertext")
        try select(.responses); server.clear(); server.script([try P2Life.body("Back to A", id: "scopeAreturn")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Restore account A"))
        let accountA = try P2Life.input(server.completeRequests.last!)
        let encrypted = accountA.compactMap { $0["encrypted_content"] as? String }
        try P2Life.require(encrypted.contains("opaque_scopeA") && encrypted.contains("opaque_scopeAfinal") && !encrypted.contains("opaque_scopeB"), "return restores only matching A native replay after chat and account switches")
        try P2Life.require(accountA.filter { $0["call_id"] as? String == mappedID }.count == 2, "semantic chat id remains stable after restart and switches")
        P2Life.captureDelivery = true; defer { P2Life.captureDelivery = false }
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleReasoningEffortKey, value: "low")
        await manager.p2Effort("ultra")
        try P2Life.require(KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) == "low", "Responses effort command refuses ultra without persisting it")
        try P2Life.require(server.remainingResponses == 0 && server.errors.isEmpty, "switch capture script exhausted")
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
        try P2Life.require(final.toolInteractions.contains { round in
            round.assistantMessage.responsesReplay?.entries.contains { ($0.encryptedContent?.isEmpty == false) } == true
        }, "live tool round persists encrypted reasoning")
        let results = final.toolInteractions.flatMap(\.results)
        try P2Life.require(results.contains { $0.content.contains("P2_TOOL_READ_OK") }, "live text tool succeeds")
        try P2Life.require(results.contains { !$0.fileAttachmentReferences.isEmpty }, "live image tool returned media")
        print("Live first phase passed; invoke --live --resume-live on this same isolated root for process-restart verification.")
    }
}
