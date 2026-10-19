import Foundation

/// Group O: switch OFF behaves exactly as 0.2.56 — no ON work, the
/// ordinary inline prune, unchanged replies, original errors.
enum BackgroundPruneSelftestOff {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        for (label, setting) in [("key absent", nil), ("key false", false)] as [(String, Bool?)] {
            let manager = await h.freshManager(history: h.prunableHistory(), switchOn: setting)
            manager.bgPruneTestSetLastPromptTokens(60_000)
            let before = h.prunedIds(manager).count
            let idle = await h.turn(manager, "over the maximum with background pruning OFF")
            h.check("O2 [\(label)] turn completes", idle)
            h.check("O2 [\(label)] today's inline prune ran before the request (summary request, pruned history, notice)",
                    h.router.summaries == 1 && h.prunedIds(manager).count > before && h.noticeTexts.count == 1,
                    "summaries \(h.router.summaries), pruned \(h.prunedIds(manager).count), notices \(h.noticeTexts)")
            h.check("O2 [\(label)] no ON work: no job, no event, no counter", manager.bgPruneTestPhase == "none"
                    && h.allEvents.isEmpty && manager.bgPruneTestCounters.isEmpty, "\(h.allEvents)")
            h.check("O2 [\(label)] no settings write", setting == nil
                    ? UserDefaults.standard.object(forKey: ConversationManager.backgroundPruneDefaultsKey) == nil
                    : UserDefaults.standard.object(forKey: ConversationManager.backgroundPruneDefaultsKey) as? Bool == false)
            let status = await manager.bgPruneTestCommand("/status")
            h.check("O3 [\(label)] /status has no background-pruning line", !status.contains("Background pruning"), status)
            let stop = await manager.bgPruneTestCommand("/stop")
            h.check("O3 [\(label)] idle /stop reply is today's", stop == "I'm not doing anything at the moment.", stop)
        }

        let manager = await h.freshManager(history: h.prunableHistory(pairs: 2, size: 200), switchOn: nil)
        let commands = await manager.bgPruneTestCommand("/commands")
        let lines = commands.split(separator: "\n").filter { $0.contains("/prunebackground") }
        h.check("O3 /commands gains exactly one /prunebackground line", lines.count == 1, commands)
        let help = ChatCommandRegistry.terminalHelpLines().filter { $0.contains("/prunebackground") }
        h.check("O3 terminal /help gains exactly one line", help.count == 1, "\(help)")
        h.check("O3 the command is not in the Telegram menu", ChatCommandRegistry.commands.first { $0.name == "prunebackground" }?.inMenu == false)

        // O4: an in-band-looking 400 while OFF keeps the original error and retries.
        let off = await h.freshManager(history: h.prunableHistory(), switchOn: nil)
        off.bgPruneTestSetLastPromptTokens(1_000)
        h.server.script(["{\"error\":{\"message\":\"context too long\"}}"], statuses: [400])
        off._testStartTurn(for: Message(role: .user, content: "a request admitted above the maximum, OFF"))
        _ = await off._testAwaitIdle(timeout: 40)
        h.check("O4 OFF: original error, no reduction, no resend",
                (off._testLastError ?? "").contains("400") && h.router.summaries == 0 && h.mainRequests.count == 1
                && h.allEvents.isEmpty, "error \(String(describing: off._testLastError)), summaries \(h.router.summaries), main \(h.mainRequests.count), events \(h.allEvents)")
    }
}
