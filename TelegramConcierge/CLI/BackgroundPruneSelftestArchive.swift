import Foundation

/// §11 archive interplay: with /archiveinline on, an archive due while a
/// background prune runs is not started (raw messages stay) and is retried
/// at the next turn after the prune is applied.
enum BackgroundPruneSelftestArchive {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        await inlineRefused(h)
        await backgroundDeferred(h)
    }

    @MainActor static func heavy() -> [Message] {
        (0..<4).map { Message(role: .user, content: "archive weight \($0) " + String(repeating: "text ", count: 2_600)) }
    }

    @MainActor static func inlineRefused(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager)
        UserDefaults.standard.set(true, forKey: ConversationManager.archiveInlineDefaultsKey)
        try? KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: "5000")
        manager._testReplaceMessages(manager._testMessages + heavy())
        _ = manager._testSave()
        manager.bgPruneTestSetLastPromptTokens(1_000)
        let before = h.router.other
        _ = await h.turn(manager, "archive due while a prune runs")
        h.check("§11 /archiveinline on: the inline archive is not started while a job exists", h.router.other == before
                && manager._testMessages.count >= 16 + 4, "other requests \(h.router.other - before)")
        h.router.gate.release()
        _ = await h.waitPhase(manager, "ready")
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "next turn: prune applied first, then the archive")
        h.check("§11 next turn: T0 applies the prune, then the archive is retried", h.eventCount("bgprune.t0.applied") == 1
                && h.router.other > before, "other \(h.router.other) events \(h.allEvents)")
        UserDefaults.standard.removeObject(forKey: ConversationManager.archiveInlineDefaultsKey)
        try? KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: "1000000")
    }

    /// §11 background mode: an archive may start and finish while a prune
    /// job runs, but its removal waits until the prune is applied (T0
    /// applies first, then the archive commits and reconciles).
    @MainActor static func backgroundDeferred(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager)
        try? KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: "5000")
        manager._testReplaceMessages(manager._testMessages + heavy())
        _ = manager._testSave()
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "archive starts in the background")
        let archived = await h.waitUntil(timeout: 30) { manager._baJobOutcome == "succeeded" }
        let batch = manager._baJobBatchIds
        h.check("§11 background archive starts and finishes while the prune job runs", archived && !batch.isEmpty
                && manager.bgPruneTestPhase == "running", "outcome \(String(describing: manager._baJobOutcome))")
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "boundary while the prune still runs")
        let live = Set(manager._testMessages.map(\.id))
        h.check("§11 the archive's removal is deferred while a prune job exists (no alert, raw messages kept)",
                manager._baJobOutcome == "succeeded" && batch.allSatisfy { live.contains($0) })
        h.router.gate.release()
        _ = await h.waitPhase(manager, "ready")
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "prune applied first, then the archive commits")
        let after = Set(manager._testMessages.map(\.id))
        h.check("§11 T0 applies the prune, then the archive commits and reconciles the pruned messages",
                h.eventCount("bgprune.t0.applied") == 1 && manager._baJobOutcome == nil
                && batch.allSatisfy { !after.contains($0) } && manager._testLastError == nil,
                "outcome \(String(describing: manager._baJobOutcome)) remaining \(batch.filter { after.contains($0) }.count) error \(String(describing: manager._testLastError))")
        try? KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: "1000000")
    }
}
