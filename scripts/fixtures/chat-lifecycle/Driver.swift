import ArgumentParser
import Foundation

// Compiled and registered ONLY by chat_lifecycle_baseline.py in disposable trees.
enum P0Life {
    static let pdfBase64 = "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUiA0IDAgUl0gL0NvdW50IDIgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyMDAgMTAwXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA3IDAgUiA+PiA+PiAvQ29udGVudHMgNSAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyMDAgMTAwXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA3IDAgUiA+PiA+PiAvQ29udGVudHMgNiAwIFIgPj4KZW5kb2JqCjUgMCBvYmoKPDwgL0xlbmd0aCA0MiA+PgpzdHJlYW0KQlQgL0YxIDEyIFRmIDIwIDUwIFRkIChBZGEgcGFnZSBvbmUpIFRqIEVUCmVuZHN0cmVhbQplbmRvYmoKNiAwIG9iago8PCAvTGVuZ3RoIDQyID4+CnN0cmVhbQpCVCAvRjEgMTIgVGYgMjAgNTAgVGQgKEFkYSBwYWdlIHR3bykgVGogRVQKZW5kc3RyZWFtCmVuZG9iago3IDAgb2JqCjw8IC9UeXBlIC9Gb250IC9TdWJ0eXBlIC9UeXBlMSAvQmFzZUZvbnQgL0hlbHZldGljYSA+PgplbmRvYmoKeHJlZgowIDgKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMDA5IDAwMDAwIG4gCjAwMDAwMDAwNTggMDAwMDAgbiAKMDAwMDAwMDEyMSAwMDAwMCBuIAowMDAwMDAwMjQ3IDAwMDAwIG4gCjAwMDAwMDAzNzMgMDAwMDAgbiAKMDAwMDAwMDQ2NSAwMDAwMCBuIAowMDAwMDAwNTU3IDAwMDAwIG4gCnRyYWlsZXIKPDwgL1NpemUgOCAvUm9vdCAxIDAgUiA+PgpzdGFydHhyZWYKNjI3CiUlRU9GCg=="
    static let instant = Date(timeIntervalSince1970: 1_700_000_000)
    static let root = URL(fileURLWithPath: "/tmp/briglia-chat-lifecycle-v1")
    static let defaults = UserDefaults(suiteName: "dev.briglia.p0.lifecycle")!
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    static func require(_ ok: Bool, _ message: String) { if !ok { fatalError("P0 assertion: " + message) } }
    static func json<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }
    static func message(_ n: Int, _ role: Message.Role, _ text: String, kind: MessageKind = .userText) -> Message {
        Message(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!,
                role: role, content: text, timestamp: instant, kind: kind)
    }
    static func interaction(_ cost: Int? = nil) -> ToolInteraction {
        var result = ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "read fixture", toolCalls: [
            ToolCall(id: "call-p0", type: "function", function: FunctionCall(name: "read_file", arguments: "{\"path\":\"/fixture.txt\"}"))],
            reasoning: .string("private tool reasoning")), results: [ToolResultMessage(toolCallId: "call-p0", content: "fixture observation")])
        result.measuredTokenCost = cost; result.measuredReplayTokenCost = cost
        return result
    }
    static func response(_ text: String = "summary", prompt: Int = 1, completion: Int = 1, cost: Double = 0,
                         tool: Bool = false) throws -> String {
        var message: [String: Any] = ["role": "assistant", "content": text, "reasoning_content": "fixture reasoning"]
        if tool { message["tool_calls"] = [["id": "call-p0", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"/tmp/briglia-chat-lifecycle-v1/read.txt\"}"]]] }
        let body: [String: Any] = ["id": "p0", "choices": [["message": message, "finish_reason": tool ? "tool_calls" : "stop"]],
            "usage": ["prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion,
                      "prompt_tokens_details": ["cached_tokens": max(prompt - 10, 0)],
                      "completion_tokens_details": ["reasoning_tokens": 5], "cost": cost]]
        return String(data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }
}

struct ChatLifecycleSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__chat-lifecycle-selftest", shouldDisplay: false)
    @Option(name: .long) var output: String
    @Option(name: .long) var importMind: String?
    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else { throw P0Life.Failure("development build required") }
        let fm = FileManager.default
        try fm.createDirectory(at: P0Life.root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: P0Life.root); P0Life.defaults.removePersistentDomain(forName: "dev.briglia.p0.lifecycle") }
        P0Life.defaults.removePersistentDomain(forName: "dev.briglia.p0.lifecycle")
        setenv("XDG_CONFIG_HOME", P0Life.root.appendingPathComponent("config").path, 1)
        setenv("XDG_DATA_HOME", P0Life.root.appendingPathComponent("data").path, 1)
        setenv("TMPDIR", P0Life.root.appendingPathComponent("tmp").path + "/", 1)
        setenv("TZ", "UTC", 1)
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        SetupAPICore.defaults = P0Life.defaults
        FileDescriptionsStore._testStoreURL = P0Life.root.appendingPathComponent("descriptions.json")
        try fm.createDirectory(at: P0Life.root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try Data("synthetic file content".utf8).write(to: P0Life.root.appendingPathComponent("read.txt"))
        let server = try CaptureServer(port: 49179); defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        setenv("BRIGLIA_DEV_AFFINITY_OPENCODE_BASE", base, 1)
        let settings = [
            KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
            KeychainHelper.openAICompatibleBaseURLKey: base + "/v1",
            KeychainHelper.openAICompatibleApiKeyKey: "synthetic-lifecycle-key",
            KeychainHelper.openAICompatibleModelKey: "glm-5.3",
            KeychainHelper.openAICompatibleReasoningEffortKey: "high",
            KeychainHelper.assistantNameKey: "Fixture Assistant", KeychainHelper.userNameKey: "Fixture User",
            KeychainHelper.emailCalendarProviderKey: EmailCalendarProvider.gws.rawValue,
            KeychainHelper.maxContextTokensKey: "10000", KeychainHelper.targetContextTokensKey: "5000",
            KeychainHelper.archiveChunkSizeKey: "1000000", KeychainHelper.textOnlyModelEnabledKey: "false"
        ]
        for (key, value) in settings { try KeychainHelper.save(key: key, value: value) }
        P0Life.defaults.set(P0Life.instant, forKey: "system_prompt_cache_epoch")
        let salt = SessionAffinity.State(version: 1, installSalt: Data((0..<32).map(UInt8.init)).base64EncodedString(), mainConversationId: "33333333-3333-4333-8333-333333333333")
        try PrivateStorage.ensureDirectory(StoragePaths.dataRoot)
        try PrivateStorage.writeAtomically(JSONEncoder().encode(salt), to: SessionAffinity.fileURL)
        SessionAffinity.resetCache()
        let destination = URL(fileURLWithPath: output)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        if let importMind {
            let importer = MindExportService.shared
            let staged = try await importer.stageMind(from: URL(fileURLWithPath: importMind))
            defer { Task { await importer.discardStagedMind(staged) } }
            try await importer.applyStagedMind(staged)
            let bytes = try Data(contentsOf: StoragePaths.dataRoot.appendingPathComponent("conversation.json"))
            let decoded = try JSONDecoder().decode([Message].self, from: bytes)
            let report: [String: Any] = ["conversation": try P0Life.json(decoded),
                "document": try String(contentsOf: StoragePaths.dataRoot.appendingPathComponent("documents/mind.txt"), encoding: .utf8)]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: destination.appendingPathComponent("import.json"))
            print("Pinned Mind import PASS")
            return
        }
        let metadata: [String: Any] = ["scratch_path": LandingZone.scratchReposRoot.path,
            "expected_scratch_path": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Briglia/scratch/repos").path]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: destination.appendingPathComponent("metadata.json"))
        var observations: [String: Any] = [:]
        var captures: [[String: Any]] = []
        func capture(_ name: String) throws {
            P0Life.require(server.errors.isEmpty, "capture errors")
            for (i, req) in server.completeRequests.enumerated() {
                captures.append(["fixture": "\(name)-\(i)", "body": req.body.base64EncodedString(), "headers": req.headers, "target": req.target, "method": req.method])
            }
            P0Life.require(server.remainingResponses == 0, "unconsumed scripted response: " + name)
            server.clear()
        }
        let manager = ConversationManager()
        let user = P0Life.message(1, .user, "Keep my exact words ☕️")
        var old = P0Life.message(2, .assistant, "Earlier answer")
        old.toolInteractions = [P0Life.interaction(9000)]; old.measuredToolTokens = 9000; old.measuredTokens = 9500
        old.finalReasoning = .string(String(repeating: "r", count: 400)); old.finalReasoningModel = nil
        var recent = P0Life.message(3, .assistant, "Latest tools are protected")
        recent.toolInteractions = [P0Life.interaction(2000)]
        let trigger = P0Life.message(4, .user, "Continue")
        let history = [user, old, recent, trigger]
        var reasoningOnly = old
        reasoningOnly.toolInteractions = []
        reasoningOnly.measuredToolTokens = nil
        reasoningOnly.finalReasoning = .string(String(repeating: "r", count: 32000))
        var mediaOnly = Message(id: P0Life.message(5, .user, "").id, role: .user, content: "Image caption", timestamp: P0Life.instant,
                                imageFileNames: ["missing-fixture.png"], documentFileNames: ["never-auto-inline.pdf"])
        mediaOnly.measuredTokens = 8000
        let largeHistory = (100..<116).map { n -> Message in
            var msg = P0Life.message(n, .assistant, "Large historical reasoning")
            msg.finalReasoning = .string(String(repeating: "R", count: 16384))
            return msg
        } + [recent, trigger]
        let synthetic = P0Life.message(6, .user, "[Email] synthetic event details", kind: .emailArrived)
        // Real automatic and mid-loop budget branches, including exact high boundary,
        // measured current-turn deltas, no measured prompt, and insufficient savings.
        let cases: [(String, String, [Message], Int?, [ToolInteraction])] = [
            ("under", "midloop", history, 9900, []), ("boundary", "midloop", history, 10000, []),
            ("over-prunable", "midloop", history, 12000, []),
            ("exhausted-protected", "midloop", [user, recent, trigger], 12000, []),
            ("exhausted-after-prune", "midloop", history, 24000, []),
            ("unsent-delta", "midloop", history, 9900, [P0Life.interaction(1500)]),
            ("estimated", "midloop", history, nil, []),
            ("automatic-under", "automatic", history, 9000, []),
            ("automatic-prune", "automatic", history, 12000, []),
            ("automatic-protected", "automatic", [user, recent, trigger], 12000, []),
            ("manual", "manual", history, 12000, []),
            ("reasoning-only", "midloop", [user, reasoningOnly, recent, trigger], 12000, []),
            ("media-prune", "midloop", [user, mediaOnly, old, recent, trigger], 12000, []),
            ("synthetic-prune", "midloop", [user, synthetic, old, recent, trigger], 12000, []),
            ("large-reasoning", "midloop", largeHistory, nil, []),
            ("summary-tools-refused", "midloop", history, 12000, [])
        ]
        for (name, mode, input, prompt, current) in cases {
            server.contentOverride = "summary"
            if name == "summary-tools-refused" {
                server.script(try (0..<5).map { _ in try P0Life.response("forbidden summary tool", tool: true) })
            }
            observations[name] = try await manager.p0Prune(mode, history: input, prompt: prompt, current: current)
            try capture(name)
        }
        P0Life.require((observations["boundary"] as? [String: Any])?["decision"] as? String == "underBudget", "high watermark equality")
        P0Life.require((observations["over-prunable"] as? [String: Any])?["decision"] as? String == "pruned", "old tool prune")
        P0Life.require((observations["exhausted-after-prune"] as? [String: Any])?["decision"] as? String == "exhausted", "insufficient savings")
        let usageInputs = [
            "{\"prompt_tokens\":1200,\"completion_tokens\":80,\"total_tokens\":1280,\"prompt_tokens_details\":{\"cached_tokens\":1100},\"cost\":\"0.25\",\"cost_details\":{\"upstream_inference_cost\":0.4}}",
            "{\"prompt_tokens\":0,\"completion_tokens\":0,\"prompt_tokens_details\":{\"cached_tokens\":0}}", "{}"
        ]
        observations["usage-decoder"] = try usageInputs.map { raw in
            try P0Life.json(JSONDecoder().decode(OpenRouterUsage.self, from: Data(raw.utf8)))
        }
        observations["delivery"] = try manager.p0Delivery(history: [user, trigger])
        // Real main agent loops; only the provider's responses are scripted. The
        // read_file call executes against a synthetic path, never an owner's file.
        for name in ["loop-final", "loop-tools", "loop-exhausted", "loop-spend"] {
            try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey, value: name == "loop-spend" ? "0.5" : "0")
            let first = try P0Life.response("tool request", prompt: name == "loop-exhausted" ? 20000 : 1200, completion: 80,
                cost: name == "loop-spend" ? 1 : 0, tool: true)
            let final = try P0Life.response("final answer", prompt: 1600, completion: 120)
            server.script(name == "loop-final" ? [final] : [first, final])
            observations[name] = try await manager.p0Loop(history: [user, trigger], prompt: 1000)
            try capture(name)
        }
        let toolLoop = observations["loop-tools"] as! [String: Any]
        P0Life.require(toolLoop["measuredTools"] as? Int == 400 && toolLoop["measuredAssistant"] as? Int == 520, "legacy usage delta attribution")
        P0Life.require((observations["loop-exhausted"] as! [String: Any])["measuredUser"] as? Int == 18900, "legacy exhaustion watermark arithmetic")
        observations["subagents"] = try await P0Life.subagents(server: server, capture: capture)
        observations["media"] = try await P0Life.media(server: server, capture: capture)
        observations["archive"] = try await P0Life.archive(server: server)
        try capture("archive")
        observations["user-context"] = try await UserContextStructurer.structure(assistantName: "Fixture Assistant", userName: "Fixture User",
            rawContext: "I prefer concise answers", existingContext: "", config: .fromKeychain())
        try capture("user-context")
        let failure = await Probes.chatCompletion(baseURL: base + "/v1", apiKey: "synthetic-lifecycle-key", model: "glm-5.3", lane: .probe(user.id))
        P0Life.require(failure == nil, "probe failed")
        try capture("probe")
        // Save real status for the shipped UT bridge gate; this is observation,
        // never a provider probe or account login.
        let status = await SetupAPICore.status()
        try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]).write(to: destination.appendingPathComponent("status.json"))
        await manager.p0Seed(history, prompt: 1600, completion: 120)
        try manager.p0Save()
        let docs = StoragePaths.dataRoot.appendingPathComponent("documents")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("Mind compatibility payload".utf8).write(to: docs.appendingPathComponent("mind.txt"))
        try await MindExportService.shared.exportMind(to: destination.appendingPathComponent("compat.mind"))
        let expectedImport: [String: Any] = ["conversation": try P0Life.json(history), "document": "Mind compatibility payload"]
        try JSONSerialization.data(withJSONObject: expectedImport, options: [.sortedKeys]).write(to: destination.appendingPathComponent("expected-import.json"))
        let encoderOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        try JSONSerialization.data(withJSONObject: observations, options: encoderOptions).write(to: destination.appendingPathComponent("observations.json"))
        try JSONSerialization.data(withJSONObject: captures, options: encoderOptions).write(to: destination.appendingPathComponent("captures.json"))
        print("Lifecycle: \(observations.count) scenarios, \(captures.count) captured requests")
    }
}

extension P0Life {
    @MainActor static func subagents(server: CaptureServer, capture: (String) throws -> Void) async throws -> [String: Any] {
        let runner = SubagentRunner()
        let service = OpenRouterService(); await service.configure(apiKey: "synthetic-lifecycle-key")
        let executor = ToolExecutor(outputMode: .subagent)
        let images = StoragePaths.dataRoot.appendingPathComponent("images")
        let documents = StoragePaths.dataRoot.appendingPathComponent("documents")
        let invocation = SubagentRunner.Invocation(subagentType: "general-purpose", description: "Fixture worker",
            taskPrompt: "Read the synthetic fixture", modelOverride: nil, runInBackground: false)
        var results: [String: Any] = [:]
        func record(_ name: String, _ result: SubagentRunner.RunResult) throws {
            require(result.error == nil && result.sessionPersisted, "subagent failed: \(result.error ?? "not persisted")")
            results[name] = ["id": result.sessionId, "new": result.isNewSession, "turns": result.turnsUsed,
                             "text": result.finalMessage, "tools": result.toolsCalled, "spend": result.spendUSD]
            try capture("subagent-" + name)
        }
        server.script([try response("new session answer", prompt: 300, completion: 20)])
        let first = await runner.run(invocation: invocation, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                     imagesDirectory: images, documentsDirectory: documents, parentTools: [])
        try record("new", first)
        // A disk reload, not just a second read of the actor's cached session.
        await SubagentSessionRegistry.shared.reloadFromDisk()
        server.script([try response("resumed answer", prompt: 400, completion: 30)])
        let resumed = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                       imagesDirectory: images, documentsDirectory: documents, parentTools: [])
        try record("resume", resumed)
        try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "1000")
        let large = (10..<16).map { message($0, $0 % 2 == 0 ? .user : .assistant, String(repeating: "older content ", count: 100)) }
        await SubagentSessionRegistry.shared.applyCompaction(sessionId: first.sessionId, messages: large, toolInteractions: [])
        server.script([try response("forbidden summary tool", tool: true), try response("evicted history summary"), try response("eager compaction answer", prompt: 400)])
        let eager = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                     imagesDirectory: images, documentsDirectory: documents, parentTools: [])
        try record("eager", eager)
        let small = (20..<26).map { message($0, $0 % 2 == 0 ? .user : .assistant, String(repeating: "history ", count: 30)) }
        await SubagentSessionRegistry.shared.applyCompaction(sessionId: first.sessionId, messages: small, toolInteractions: [])
        server.script([try response("use read", prompt: 900, tool: true), try response("midrun summary"), try response("midrun answer", prompt: 400)])
        let midrun = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                      imagesDirectory: images, documentsDirectory: documents, parentTools: [AvailableTools.readFile])
        try record("midrun", midrun)
        try AgentTurnOverrides.setOverride(1, forAgent: "general-purpose")
        await SubagentSessionRegistry.shared.applyCompaction(sessionId: first.sessionId,
            messages: [message(30, .user, "Finish fixture")], toolInteractions: [])
        server.script([try response("last allowed tool", prompt: 400, tool: true),
                       try response("forbidden forced tool", prompt: 500, tool: true), try response("forced answer", prompt: 600)])
        let forced = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                      imagesDirectory: images, documentsDirectory: documents, parentTools: [AvailableTools.readFile])
        try record("forced-retry", forced)
        try AgentTurnOverrides.setOverride(nil, forAgent: "general-purpose")
        return results
    }
    static func archive(server: CaptureServer) async throws -> String {
        let archive = ConversationArchiveService()
        await archive.configure(apiKey: "synthetic-lifecycle-key")
        let summary = String(repeating: "deterministic summary content ", count: 110)
        server.script([try response(summary)])
        return try await archive.p0Summary([message(40, .user, "Archive this synthetic conversation"), message(41, .assistant, "Done")])
    }
}

extension P0Life {
    @MainActor static func media(server: CaptureServer, capture: (String) throws -> Void) async throws -> [String: Any] {
        let service = OpenRouterService(); await service.configure(apiKey: "synthetic-lifecycle-key")
        let fm = FileManager.default
        let images = StoragePaths.dataRoot.appendingPathComponent("images")
        let documents = StoragePaths.dataRoot.appendingPathComponent("documents")
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        let pdf = documents.appendingPathComponent("fixture.pdf")
        let png = images.appendingPathComponent("fixture.png")
        try Data(base64Encoded: pdfBase64)!.write(to: pdf)
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6z8AAAAASUVORK5CYII=")!.write(to: png)
        let ref = FileAttachmentReference(filename: "fixture.pdf", mimeType: "application/pdf", sourcePath: pdf.path, pageRange: "2-2")
        let slice = try await service.p0PDFSlice(ref, url: pdf)
        require(slice["pages"] as? Int == 1 && (slice["text"] as? String)?.contains("two") == true, "source PDF bounds not preserved")
        let inlineRefs = [FileAttachmentReference(filename: "fixture.png", mimeType: "image/png", snapshotPath: png.path), ref]
        var history = [message(50, .user, "Inspect the persisted files"), message(51, .assistant, "Earlier file read")]
        var mediaResult = ToolResultMessage(toolCallId: "call-p0", content: "File output")
        mediaResult.fileAttachmentReferences = inlineRefs
        history[1].toolInteractions = [ToolInteraction(assistantMessage: interaction().assistantMessage, results: [mediaResult])]
        let persisted = try JSONEncoder().encode(history)
        let path = root.appendingPathComponent("media-conversation.json")
        try persisted.write(to: path)
        let reloaded = try JSONDecoder().decode([Message].self, from: Data(contentsOf: path))
        require(history == reloaded, "persisted media references changed")
        _ = try await service.generateResponse(messages: reloaded, imagesDirectory: images, documentsDirectory: documents,
            tools: [], currentUserMessageId: history[0].id, turnStartDate: instant, lane: .main)
        try capture("media-rehydrated")
        try fm.removeItem(at: png)
        _ = try await service.generateResponse(messages: reloaded, imagesDirectory: images, documentsDirectory: documents,
            tools: [], currentUserMessageId: history[0].id, turnStartDate: instant, lane: .main)
        try capture("media-missing")
        // An inbound raw document remains a hint until read_file explicitly opens
        // it. It must not become auto-inlined during a protocol extraction.
        let raw = Message(id: message(52, .user, "").id, role: .user, content: "Read page 2", timestamp: instant,
                          documentFileNames: ["fixture.pdf"])
        _ = try await service.generateResponse(messages: [raw], imagesDirectory: images, documentsDirectory: documents,
            tools: [], currentUserMessageId: raw.id, turnStartDate: instant, lane: .main)
        try capture("media-raw-document")
        return ["slice": slice, "persisted": try json(reloaded)]
    }
}
