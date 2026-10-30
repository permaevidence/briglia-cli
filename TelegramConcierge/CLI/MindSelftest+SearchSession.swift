import Foundation

/// Mind export/import and /deleteuserdata against the free-search session
/// file (KEYLESS_WEB_AND_LIVE_MENU_PLAN A.5): never exported, discarded by
/// an import (failure aborts it honestly), deleted by the wipe (failure
/// reported). Runs in the selftest's isolated data root. Its own file
/// (feedback_linux_selftest_size_split).
extension MindSelftest {
    @MainActor
    func searchSessionChecks(check: (String, Bool, String) -> Void) async {
        func record(_ label: String, _ ok: Bool, _ detail: String = "") { check(label, ok, detail) }
        let url = ParallelSessionStore.fileURL
        let planted = "0f1e2d3c-4b5a-4968-8776-655443322110"
        func plant() {
            try? PrivateStorage.ensureDirectory(url.deletingLastPathComponent())
            try? Data("{\"version\":1,\"parallel_session_id\":\"\(planted)\",\"created\":\"x\"}".utf8).write(to: url)
        }
        defer { ParallelSessionStore.fsyncDirectoryForTesting = nil }

        // Export never carries it; import discards it.
        plant()
        let manager = ConversationManager()
        manager.messages = [Message(role: .user, content: "search-session import check"), Message(role: .assistant, content: "ok")]
        _ = manager.saveConversation()
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("search-session-\(UUID().uuidString.prefix(8)).mind")
        defer { try? FileManager.default.removeItem(at: backup) }
        var exported = true
        do { try await MindExportService.shared.exportMind(to: backup) } catch { exported = false }
        let archiveBytes = (try? Data(contentsOf: backup)) ?? Data()
        record("search session: the Mind export does not contain search-session.json",
               exported && !archiveBytes.isEmpty && archiveBytes.range(of: Data("search-session.json".utf8)) == nil)
        let outcome = await manager.performMindImport(from: backup)
        var imported = false
        if case .success = outcome { imported = true }
        record("search session: a Mind import discards the current file (the imported conversation mints a new ID)",
               imported && ParallelSessionStore.state() == .absent, "\(outcome)")

        // A failed (non-durable) discard aborts the import honestly.
        plant()
        ParallelSessionStore.fsyncDirectoryForTesting = { _ in throw PrivateStorage.StorageError(description: "injected directory fsync failure") }
        let failed = await manager.performMindImport(from: backup)
        ParallelSessionStore.fsyncDirectoryForTesting = nil
        var abortedHonestly = false
        if case .failedBeforeApply(let message, let advanced) = failed, advanced, message.contains("free-search session") { abortedHonestly = true }
        record("search session: a discard whose deletion is not durable aborts the import as failedBeforeApply(affinityAdvanced: true)",
               abortedHonestly, "\(failed)")

        // /deleteuserdata deletes it; a non-durable deletion is reported.
        plant()
        let wipe = await manager.deleteAllMemory()
        record("search session: /deleteuserdata deletes it, no failure reported",
               ParallelSessionStore.state() == .absent && !wipe.contains { $0.contains("free-search") }, wipe.joined(separator: "; "))
        plant()
        ParallelSessionStore.fsyncDirectoryForTesting = { _ in throw PrivateStorage.StorageError(description: "injected directory fsync failure") }
        let wipe2 = await manager.deleteAllMemory()
        ParallelSessionStore.fsyncDirectoryForTesting = nil
        record("search session: a wipe whose deletion is not durable reports it",
               wipe2.contains { $0.contains("free-search session") }, wipe2.joined(separator: "; "))
    }
}
