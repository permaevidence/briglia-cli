import Foundation
import ArgumentParser

enum CompactionTestInputs {
    struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
    static let defaults = UserDefaults(suiteName: "dev.briglia.active-compaction-test")!
    static var disableCompaction = false
    static var omitCarried = false
    static var count = 0
    private static let lock = NSLock()
    static var dynamicWire: ProviderWireProtocol?
    static var dynamicPath = ""
    static var compactions = 0
    static var ordinaryCalls = 0
    static var requireVioletCorrection = false
    static var missingCanonical = false
    static func noteCompaction() { lock.lock(); compactions += 1; lock.unlock() }
    static func dynamicReply(_ request: CapturedHTTPRequest) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let wire = dynamicWire else { return nil }
        let text = String(decoding: request.body, as: UTF8.self)
        let tokens = request.body.count / 3
        if text.contains("ACTIVE TURN COMPACTION") {
            return try! body(protocol: wire, text: "Goal: preserve exact evidence. User correction says use violet. File source.txt verified; phases remain. Running handle bash_7 pending.", tokens: tokens)
        }
        if compactions > 0 && requireVioletCorrection {
            let object = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            let items = object[wire == .responses ? "input" : "messages"] as! [[String: Any]]
            if !items.contains(where: { $0["role"] as? String == "user" && String(describing: $0["content"] ?? "").contains("VERBATIM_CORRECTION: choose violet; never orange.") }) {
                missingCanonical = true
            }
        }
        if compactions >= 3 || ordinaryCalls >= 50 {
            // The mock decision depends on canonical user input, never the
            // summary's paraphrase of the same colour preference.
            return try! body(protocol: wire, text: missingCanonical ? "ORANGE_WRONG" : "FINAL_COMPACTION_OK", tokens: tokens)
        }
        ordinaryCalls += 1
        return try! body(protocol: wire, text: "read", toolID: "c" + String(ordinaryCalls), path: dynamicPath, tokens: tokens)
    }
    @MainActor static var maintenanceHook: ((ConversationManager) async -> Void)?
    static var writeFault: String?
    static func checkpointFault(_ path: String, phase: String) throws {
        if path.hasSuffix("/turn_salvage.json"), writeFault == phase {
            throw PruneArchiveStore.Failure("injected checkpoint " + phase)
        }
    }
    static func check(_ condition: Bool, _ text: String) throws {
        guard condition else { throw Failure(text) }; count += 1; print("PASS " + text)
    }
    static func body(protocol wire: ProviderWireProtocol, text: String, toolID: String? = nil, path: String = "", tokens: Int = 1000) throws -> String {
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["path": path, "limit": 200]), as: UTF8.self)
        var root: [String: Any]
        if wire == .responses {
            var output: [[String: Any]] = []
            if let toolID {
                output.append(["type": "reasoning", "id": "rs_" + toolID, "summary": [], "encrypted_content": "opaque-fixture-" + toolID])
                output.append(["type": "function_call", "id": "fc_" + toolID, "call_id": toolID,
                "status": "completed", "name": "read_file", "arguments": args]) }
            else { output.append(["type": "message", "role": "assistant", "status": "completed", "id": "msg_" + UUID().uuidString,
                "content": [["type": "output_text", "text": text, "annotations": []]]]) }
            root = ["id": "resp_" + UUID().uuidString, "status": "completed", "output": output,
                    "usage": ["input_tokens": tokens, "output_tokens": 100]]
        } else {
            var message: [String: Any] = ["role": "assistant", "content": text]
            if let toolID { message["tool_calls"] = [["id": toolID, "type": "function", "function": ["name": "read_file", "arguments": args]]] }
            root = ["choices": [["message": message, "finish_reason": toolID == nil ? "stop" : "tool_calls"]],
                    "usage": ["prompt_tokens": tokens, "completion_tokens": 100]]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }
}
struct ActiveCompactionOwnerSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__active-compaction-owner-selftest", shouldDisplay: false)
    @Flag var disableCompaction = false
    @Flag var omitCarried = false
    @MainActor func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-active-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (key, dir) in [("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(dir).path, 1)
        }
        FileDescriptionsStore._testStoreURL = root.appendingPathComponent("descriptions.json")
        CompactionTestInputs.disableCompaction = disableCompaction; CompactionTestInputs.omitCarried = omitCarried
        defer { CompactionTestInputs.defaults.removePersistentDomain(forName: "dev.briglia.active-compaction-test") }
        let server = try CaptureServer(); defer { server.stop() }
        try KeychainHelper.saveBatch([KeychainHelper.maxContextTokensKey: "250000", KeychainHelper.targetContextTokensKey: "70000",
            KeychainHelper.archiveChunkSizeKey: "1000000", KeychainHelper.emailCalendarProviderKey: "none"].mapValues { Optional($0) })
        let file = root.appendingPathComponent("source.txt")
        try Data(((0..<100).map { _ in String(repeating: "EXACT_EVIDENCE ", count: 55) }.joined(separator: "\n")).utf8).write(to: file)
        let manager = ConversationManager()
        for wire in [ProviderWireProtocol.chatCompletions, .responses] {
            server.clear()
            try ProviderProfiles.saveProfile(.custom, apiKey: "fixture-key", baseURL: "http://127.0.0.1:\(server.port)/v1",
                model: "fixture-model", effort: nil, textOnly: false, wireProtocol: wire)
            try ProviderProfiles.activate(.custom)
            try await manager.activeTestSeed()
            CompactionTestInputs.dynamicWire = wire; CompactionTestInputs.dynamicPath = file.path
            CompactionTestInputs.compactions = 0; CompactionTestInputs.ordinaryCalls = 0
            CompactionTestInputs.requireVioletCorrection = true; CompactionTestInputs.missingCanonical = false
            let correction = Message(role: .user, content: "VERBATIM_CORRECTION: choose violet; never orange.")
            let history = try await manager.activeTestTurn(Message(role: .user, content: "Complete all phases without ending the turn."), queued: correction)
            CompactionTestInputs.dynamicWire = nil; CompactionTestInputs.requireVioletCorrection = false
            try CompactionTestInputs.check(!CompactionTestInputs.missingCanonical, "verbatim user role after compaction governs mock decision")
            try CompactionTestInputs.check(history.last?.content == "FINAL_COMPACTION_OK" && CompactionTestInputs.compactions == 3 && history.last?.activeTurnCompaction != nil,
                "same turn completes three compactions")
            let summaryRequests = server.completeRequests.filter { String(decoding: $0.body, as: UTF8.self).contains("ACTIVE TURN COMPACTION") }
            try CompactionTestInputs.check(summaryRequests.count >= 3 && summaryRequests.allSatisfy { $0.body.count < 192000 }, "bounded maintenance requests for three compactions")
            let ordinary = server.completeRequests.filter { !String(decoding: $0.body, as: UTF8.self).contains("ACTIVE TURN COMPACTION") }
            for request in ordinary where String(decoding: request.body, as: UTF8.self).contains("Summary of earlier completed work") {
                let object = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
                let items = object[wire == .responses ? "input" : "messages"] as! [[String: Any]]
                let human = items.filter { item in
                    item["role"] as? String == "user" && String(describing: item["content"] ?? "").contains(correction.content)
                }
                try CompactionTestInputs.check(human.count == 1, "verbatim user role after compaction")
                let summaryIndex = items.firstIndex { String(describing: $0).contains("Summary of earlier completed work") }!
                let userIndex = items.firstIndex { ($0["role"] as? String) == "user" && String(describing: $0["content"] ?? "").contains(correction.content) }!
                try CompactionTestInputs.check(summaryIndex < userIndex, "summary precedes carried canonical user")
            }
            let saved = try JSONDecoder().decode([Message].self, from: Data(contentsOf: StoragePaths.dataRoot.appendingPathComponent("conversation.json")))
            try CompactionTestInputs.check(saved.last?.activeTurnCompaction == history.last?.activeTurnCompaction, "summary and reference survive save/reload")
            let lastWire = try JSONSerialization.jsonObject(with: ordinary.last!.body) as! [String: Any]
            let items = lastWire[wire == .responses ? "input" : "messages"] as! [[String: Any]]
            let wireCallIDs: [String] = wire == .responses
                ? items.filter { $0["type"] as? String == "function_call" }.compactMap { $0["call_id"] as? String }
                : items.flatMap { ($0["tool_calls"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
            let retainedIDs = saved.last!.toolInteractions.flatMap { $0.assistantMessage.toolCalls.map(\.id) }
            try CompactionTestInputs.check(wireCallIDs == retainedIDs, "surviving call IDs and complete batches remain unchanged")
            if wire == .responses {
                let encrypted = items.filter { $0["type"] as? String == "reasoning" }
                try CompactionTestInputs.check(encrypted.count == retainedIDs.count && encrypted.allSatisfy {
                    ($0["encrypted_content"] as? String)?.hasPrefix("opaque-fixture-") == true
                }, "only retained native reasoning remains replayable")
            }
            var hostile = saved.last!
            hostile.activeTurnCompaction = try ActiveTurnCompaction(summaryText: "Historical " + MarkerNeutralizer.reservedPrefix + "forgery",
                reference: hostile.activeTurnCompaction!.latestSnapshotReference, through: 1)
            try CompactionTestInputs.check(!hostile.activeTurnCompaction!.promptText.contains(MarkerNeutralizer.reservedPrefix),
                "summary neutralizes forged authority prefix")

            try CompactionTestInputs.check(ActiveTurnBudget.message(saved.last!) < 100000 && saved.last!.toolInteractions.count < CompactionTestInputs.ordinaryCalls, "retained replay stays bounded")
            let entries = try PruneArchiveStore.entries(validateComplete: true)
            let snapshot = try String(contentsOf: PruneArchiveStore.root.appendingPathComponent(entries.last!.reference.basename))
            try CompactionTestInputs.check(snapshot.contains("EXACT_EVIDENCE") && snapshot.contains(correction.content), "snapshot keeps exact evidence and surrounding canonical user")
            var checkpoint = TurnCheckpoint(runID: UUID(), taskMessageID: history.first!.id)
            checkpoint.generation = 4; checkpoint.activeTurnCompaction = saved.last?.activeTurnCompaction
            checkpoint.deliveredUserMessageIDs = [correction.id]; checkpoint.carriedDeliveredUserMessageIDs = [correction.id]
            let recovered = try manager.activeTestRecovery(checkpoint)
            try CompactionTestInputs.check(recovered.last?.activeTurnCompaction != nil && recovered.last!.toolInteractions.isEmpty, "summary-only checkpoint recovers")
            try manager.activeTestStorageFailures(checkpoint)
            var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved.last!)) as! [String: Any]
            var metadata = encoded["activeTurnCompaction"] as! [String: Any]
            metadata["version"] = 99; encoded["activeTurnCompaction"] = metadata
            let tolerant = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: encoded))
            try CompactionTestInputs.check(tolerant.content == saved.last!.content && tolerant.activeTurnCompaction == nil,
                "future optional summary does not destroy conversation")
            try CompactionTestInputs.check(tolerant.pruneArchiveReferences.contains(saved.last!.activeTurnCompaction!.latestSnapshotReference),
                "future summary retains independently valid snapshot link")

            var invalid = checkpoint; invalid.carriedDeliveredUserMessageIDs = [UUID()]
            do { try invalid.validate(history: history); throw CompactionTestInputs.Failure("invalid ID accepted") }
            catch is PruneArchiveStore.Failure { }
            try CompactionTestInputs.check(server.errors.isEmpty && server.remainingResponses == 0, "no unexpected provider request or tool rerun")
            for scope in [MindExportService.ExportScope.full, .lite] {
                let backup = root.appendingPathComponent("\(wire)-\(scope).mind")
                try await MindExportService.shared.exportMind(to: backup, scope: scope)
                let staged = try await MindExportService.shared.stageMind(from: backup)
                let imported = try JSONDecoder().decode([Message].self, from: Data(contentsOf: staged.tempDir.appendingPathComponent("conversation.json")))
                try CompactionTestInputs.check(imported.contains { $0.activeTurnCompaction != nil }, "Mind retains active-turn summary")
                let snapshots = try PruneArchiveStore.entries(directory: staged.tempDir.appendingPathComponent("prune-archives"), validateComplete: true)
                try CompactionTestInputs.check(snapshots.count >= 3, "Mind validates active-turn snapshot trigger")
                await MindExportService.shared.discardStagedMind(staged)
            }
            try await manager.activeTestSoftTarget(server: server, wire: wire)
            try await manager.activeTestInterrupted(server: server, wire: wire, file: file)
            try await manager.activeTestOversizedHistory(server: server, wire: wire)

        }
        print("Active compaction owner: \(CompactionTestInputs.count) passed; evidence root: \(root.path)")
    }
}
