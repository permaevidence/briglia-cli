import Foundation

/// §11 archive interplay: with /archiveinline on, an archive due while a
/// background prune runs is not started (raw messages stay) and is retried
/// at the next turn after the prune is applied.
enum BackgroundPruneSelftestArchive {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        _ = await h.frozenRunningJob(manager)
        UserDefaults.standard.set(true, forKey: ConversationManager.archiveInlineDefaultsKey)
        try? KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: "5000")
        let heavy = (0..<4).map { Message(role: .user, content: "archive weight \($0) " + String(repeating: "text ", count: 2_600)) }
        manager._testReplaceMessages(manager._testMessages + heavy)
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
}
