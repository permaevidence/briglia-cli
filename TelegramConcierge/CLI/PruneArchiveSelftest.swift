import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct PruneArchiveSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__prune-archive-selftest", shouldDisplay: false)
    func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-snapshots-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            PruneArchiveStore.faultForTesting = nil
            PruneArchiveStore.identityForTesting = nil
            try? FileManager.default.removeItem(at: root)
        }
        FileDescriptionsStore._testStoreURL = root.appendingPathComponent(".test-descriptions.json")
        var checks = 0
        func check(_ name: String, _ condition: Bool) throws {
            checks += 1
            guard condition else { throw PruneArchiveStore.Failure("FAIL: " + name) }
            print("PASS: " + name)
        }
        func refuses(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        let absent = root.appendingPathComponent("absent")
        try check("diagnostics do not create storage", PruneArchiveStore.statusLine(directory: absent) == "0 snapshots, 0.0 MB" && !FileManager.default.fileExists(atPath: absent.path))
        var message = Message(role: .assistant, content: "visible surrounding reply")
        message.prunedContextSummary = "PRIOR_SUMMARY_PROSE"
        message.finalReasoning = .string("readable final thought")
        message.finalReasoningDetails = .array([.object(["text": .string("readable detail"), "signature": .string("DO_NOT_EXPORT_SIGNATURE")])])
        message.toolInteractions = [ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "tool round", toolCalls: [
            ToolCall(id: "call-one", type: "function", function: FunctionCall(name: "bash", arguments: "{\"command\":\"echo kept\"}"))
        ], reasoning: .string("readable tool thought"), producedByModel: "model#gateway"), results: [ToolResultMessage(toolCallId: "call-one", content: "FULL_RESULT\nSECOND_RESULT_LINE")])]
        let user = Message(role: .user, content: "surrounding user request")
        try check("detail-bearing and pure text detection", PruneArchiveStore.needsSnapshot([message]) && !PruneArchiveStore.needsSnapshot([user]))
        let first = try PruneArchiveStore.write(messages: [user, message], trigger: "manual", removedIDs: [message.id], directory: root)
        let file = root.appendingPathComponent(first.basename)
        let text = try String(contentsOf: file, encoding: .utf8)
        for value in [user.content, message.content, "FULL_RESULT\nSECOND_RESULT_LINE", "PRIOR_SUMMARY_PROSE", "readable final thought", "readable detail", "readable tool thought", "model#gateway", "call-one"] {
            try check("transcript preserves " + value.prefix(35), text.contains(value))
        }
        try check("reasoning signatures excluded", !text.contains("DO_NOT_EXPORT_SIGNATURE"))
        try check("complete header/footer validates", try PruneArchiveStore.entries(directory: root, validateComplete: true).count == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        try check("file is 0600", mode.intValue == 0o600)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as! NSNumber
        try check("directory is 0700", directoryMode.intValue == 0o700)
        try check("safe reference round trip", try JSONDecoder().decode(PruneArchiveReference.self, from: JSONEncoder().encode(first)) == first)
        for name in ["../escape.txt", "/tmp/file.txt", first.basename + "\n", "x.txt"] {
            try check("unsafe name rejected", refuses { _ = try PruneArchiveReference(id: UUID(), basename: name) })
        }
        message.pruneArchiveReferences = [first]
        let restored = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        try check("typed message reference round trip", restored.pruneArchiveReferences == [first])
        let linked = try PruneArchiveStore.write(messages: [message], trigger: "chunk-archive", removedIDs: [], directory: root)
        try check("snapshot uses portable relative link", try String(contentsOf: root.appendingPathComponent(linked.basename)).contains("Prior snapshot: " + first.relativePath))
        // Large single-line tool output: the writer must not truncate or split content.
        var large = message
        large.toolInteractions[0].results[0].content = "START_LARGE" + String(repeating: "abcd", count: 1_000_000) + "END_LARGE"
        let largeRef = try PruneArchiveStore.write(messages: [large], trigger: "automatic", removedIDs: [large.id], directory: root)
        let largeText = try String(contentsOf: root.appendingPathComponent(largeRef.basename))
        try check("4 MB single-line result remains complete", largeText.contains(large.toolInteractions[0].results[0].content))
        for stage in ["write", "fsync", "publish", "directory-fsync"] {
            let directory = root.appendingPathComponent(stage)
            PruneArchiveStore.faultForTesting = { if $0 == stage { throw PruneArchiveStore.Failure("injected " + stage) } }
            try check("\(stage) failure reported", refuses { _ = try PruneArchiveStore.write(messages: [message], trigger: "manual", removedIDs: [], directory: directory) })
            PruneArchiveStore.faultForTesting = nil
            let entries = try PruneArchiveStore.entries(directory: directory, validateComplete: true)
            try check("\(stage) leaves only complete old-or-new state", entries.count == (stage == "directory-fsync" ? 1 : 0))
            try FileManager.default.removeItem(at: directory)
        }
        let retention = root.appendingPathComponent("retention")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var retained: [PruneArchiveReference] = []
        for index in 0..<301 {
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
            PruneArchiveStore.identityForTesting = { (date, id) }
            retained.append(try PruneArchiveStore.write(messages: [user], trigger: "automatic", removedIDs: [], directory: retention))
        }
        PruneArchiveStore.identityForTesting = nil
        try check("same-second names never overwrite", try PruneArchiveStore.entries(directory: retention).count == 301)
        try PruneArchiveStore.retainLatest(directory: retention)
        try check("retention keeps 300", try PruneArchiveStore.entries(directory: retention).count == 300)
        try check("retention uses stable ID ordering", !FileManager.default.fileExists(atPath: retention.appendingPathComponent(retained[0].basename).path))
        PruneArchiveStore.identityForTesting = { (date.addingTimeInterval(-3600), UUID()) }
        let backward = try PruneArchiveStore.write(messages: [user], trigger: "manual", removedIDs: [], directory: retention, pin: true)
        defer { PruneArchiveStore.release(backward) }
        try PruneArchiveStore.retainLatest(directory: retention)
        try check("clock reversal cannot evict pending snapshot", FileManager.default.fileExists(atPath: retention.appendingPathComponent(backward.basename).path))
        PruneArchiveStore.identityForTesting = nil
        let before = try Data(contentsOf: file)
        let header = try PruneArchiveStore.entries(directory: root).first { $0.reference.id == first.id }!
        PruneArchiveStore.identityForTesting = { (header.created, first.id) }
        try check("collision refuses overwrite", refuses { _ = try PruneArchiveStore.write(messages: [], trigger: "manual", removedIDs: [], directory: root) })
        try check("collision preserves bytes", try Data(contentsOf: file) == before)
        PruneArchiveStore.identityForTesting = nil
        let badDir = root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        let bad = badDir.appendingPathComponent(first.basename)
        try Data(before.dropLast(10)).write(to: bad)
        try check("partial import rejected", refuses { _ = try PruneArchiveStore.entries(directory: badDir, validateComplete: true) })
        try FileManager.default.removeItem(at: bad)
        try FileManager.default.createSymbolicLink(atPath: bad.path, withDestinationPath: file.path)
        try check("symlink import rejected", refuses { _ = try PruneArchiveStore.entries(directory: badDir, validateComplete: true) })
        try FileManager.default.removeItem(at: bad)
        mkfifo(bad.path, 0o600)
        try check("FIFO import rejected without blocking", refuses { _ = try PruneArchiveStore.entries(directory: badDir, validateComplete: true) })
        print("Prune archive selftest: \(checks) passed")
    }
}
