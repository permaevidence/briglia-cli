import Foundation
import ArgumentParser

enum SnapshotOwnerInputs {
    struct Failure: Error { let text: String; init(_ text: String) { self.text = text } }
    static let defaults = UserDefaults(suiteName: "dev.briglia.snapshot-owner-selftest")!
    static var count = 0
    static var faultSuffix: String?
    static var faultSkip = 0
    static var faultRemaining = 0
    /// Injected by the runner into PrivateStorage before the rename: fails the
    /// (skip+1)-th write to the matching file, `faultRemaining` times.
    static func storageFault(_ target: String) throws {
        guard let faultSuffix, target.hasSuffix(faultSuffix), faultRemaining > 0 else { return }
        if faultSkip > 0 { faultSkip -= 1; return }
        faultRemaining -= 1
        throw PruneArchiveStore.Failure("injected write failure: " + faultSuffix)
    }
    static var postRenameSuffix: String?
    static var postRenameSkip = 0
    static var postRenameRemaining = 0
    /// Injected by the runner AFTER the rename and directory flush: the new
    /// file is in place, the write still throws — the directory-fsync
    /// failure shape of `PrivateStorage.replaceContents`.
    static func postRenameFault(_ target: String) throws {
        guard let postRenameSuffix, target.hasSuffix(postRenameSuffix), postRenameRemaining > 0 else { return }
        if postRenameSkip > 0 { postRenameSkip -= 1; return }
        postRenameRemaining -= 1
        throw PruneArchiveStore.Failure("injected post-rename failure: " + postRenameSuffix)
    }
    static func check(_ okay: Bool, _ label: String) throws {
        guard okay else { throw Failure(label) }; count += 1; print("PASS: " + label)
    }
    static func history() -> [Message] {
        var old = Message(role: .assistant, content: "old visible answer")
        old.toolInteractions = [ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "tools", toolCalls: [
            ToolCall(id: "old-call", type: "function", function: FunctionCall(name: "bash", arguments: "{\"command\":\"echo old\"}"))
        ]), results: [ToolResultMessage(toolCallId: "old-call", content: "EXACT_OLD_RESULT" + String(repeating: "x", count: 400) + "ARCHIVE_ONLY_TAIL")])]
        return [Message(role: .user, content: "original request"), old, Message(role: .user, content: "surrounding latest message")]
    }
    static func response(_ text: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text], "finish_reason": "stop"]], "usage": ["prompt_tokens": 200, "completion_tokens": 10]]), as: UTF8.self)
    }
}
struct SnapshotOwnerSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__snapshot-owner-selftest", shouldDisplay: false)
    @Option(name: .long) var output: String?
    @Option(name: .long) var importArchive: String?
    @Option(name: .long) var expectedCount: Int?
    @MainActor func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-snapshot-owner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("XDG_DATA_HOME", root.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", root.appendingPathComponent("config").path, 1)
        FileDescriptionsStore._testStoreURL = root.appendingPathComponent("descriptions.json")
        defer {
            PruneArchiveStore.faultForTesting = nil
            try? FileManager.default.removeItem(at: root)
            SnapshotOwnerInputs.defaults.removePersistentDomain(forName: "dev.briglia.snapshot-owner-selftest")
        }
        let server = try CaptureServer(port: 49181); defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)/v1"
        let values = [KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
                      KeychainHelper.openAICompatibleBaseURLKey: base,
                      KeychainHelper.openAICompatibleApiKeyKey: "fixture-key",
                      KeychainHelper.openAICompatibleModelKey: "fixture-model",
                      KeychainHelper.archiveChunkSizeKey: "1000000"]
        for (key, value) in values { try KeychainHelper.save(key: key, value: value) }
        if let importArchive {
            // New process, new XDG/home root: references must resolve here.
            _ = try PruneArchiveStore.write(messages: SnapshotOwnerInputs.history(), trigger: "manual", removedIDs: [])
            let staged = try await MindExportService.shared.stageMind(from: URL(fileURLWithPath: importArchive))
            try await MindExportService.shared.applyStagedMind(staged)
            let entries = try PruneArchiveStore.entries(validateComplete: true)
            try SnapshotOwnerInputs.check(entries.count == expectedCount, "Mind import replaces destination snapshot collection")
            let history = try JSONDecoder().decode([Message].self, from: Data(contentsOf: StoragePaths.dataRoot.appendingPathComponent("conversation.json")))
            let references = history.flatMap(\.pruneArchiveReferences)
            try SnapshotOwnerInputs.check(!references.isEmpty && references.allSatisfy { $0.promptText.contains(StoragePaths.dataRoot.path) }, "typed links resolve against new process data root")
            try SnapshotOwnerInputs.check(references.allSatisfy { ref in entries.contains { $0.reference == ref } }, "imported links retrieve original snapshot IDs")
            // Model an old valid backup with the optional folder absent.
            let oldStaged = try await MindExportService.shared.stageMind(from: URL(fileURLWithPath: importArchive))
            try FileManager.default.removeItem(at: oldStaged.tempDir.appendingPathComponent("prune-archives"))
            try await MindExportService.shared.applyStagedMind(oldStaged)
            try SnapshotOwnerInputs.check(try PruneArchiveStore.entries().isEmpty, "old Mind without snapshots clears destination history")
            await MindExportService.shared.discardStagedMind(staged)
            print("Snapshot import integration passed")
            return
        }
        let manager = ConversationManager()
        let pruned = try await manager.snapshotOwnerChecks()
        let service = OpenRouterService(); await service.configure(apiKey: "fixture-key")
        server.script([try SnapshotOwnerInputs.response("next answer")])
        _ = try await service.generateResponse(messages: pruned, imagesDirectory: StoragePaths.dataRoot.appendingPathComponent("images"), documentsDirectory: StoragePaths.dataRoot.appendingPathComponent("documents"), tools: [], lane: .main)
        let request = String(decoding: server.completeRequests.last!.body, as: UTF8.self)
        try SnapshotOwnerInputs.check(request.contains(pruned[1].pruneArchiveReferences[0].basename) && !request.contains("ARCHIVE_ONLY_TAIL"), "next real request includes link without archive body")
        server.clear()
        let archive = ConversationArchiveService(); await archive.configure(apiKey: "fixture-key")
        try await archive.snapshotArchiveChecks(SnapshotOwnerInputs.history(), server: server)
        try await archive.staleReceiptChecks(server: server)
        try await archive.injectedPendingWriteChecks(server: server)
        try await archive.recoveryWriteFaultChecks(server: server)
        try await archive.postRenameFaultChecks(server: server)
        let bytes = try PruneArchiveStore.entries(validateComplete: true).map { $0.reference.basename }
        for scope in [MindExportService.ExportScope.full, .lite] {
            let destination = output.map { URL(fileURLWithPath: $0) } ?? root
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let file = destination.appendingPathComponent("\(scope).mind")
            try await MindExportService.shared.exportMind(to: file, scope: scope)
            let staged = try await MindExportService.shared.stageMind(from: file)
            let imported = try PruneArchiveStore.entries(directory: staged.tempDir.appendingPathComponent("prune-archives"), validateComplete: true)
            try SnapshotOwnerInputs.check(imported.map { $0.reference.basename }.sorted() == bytes.sorted(), "\(scope) Mind includes complete snapshot collection")
            await MindExportService.shared.discardStagedMind(staged)
        }
        if let output { try Data(String(bytes.count).utf8).write(to: URL(fileURLWithPath: output).appendingPathComponent("count.txt")) }
        print("Snapshot owner integration: \(SnapshotOwnerInputs.count) passed")
    }
}
