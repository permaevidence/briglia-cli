import Foundation

/// Group O: switch OFF behaves exactly as 0.2.56 — no ON work, the
/// ordinary inline prune, unchanged replies, original errors. Since 0.2.66
/// OFF is an explicitly stored false; an absent key means the default (ON),
/// covered by group DF below.
enum BackgroundPruneSelftestOff {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        await defaultOn(h)
        for (label, setting) in [("key false", false)] as [(String, Bool?)] {
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
        let off = await h.freshManager(history: h.prunableHistory(), switchOn: false)
        off.bgPruneTestSetLastPromptTokens(1_000)
        h.server.script(["{\"error\":{\"message\":\"context too long\"}}"], statuses: [400])
        off._testStartTurn(for: Message(role: .user, content: "a request admitted above the maximum, OFF"))
        _ = await off._testAwaitIdle(timeout: 40)
        h.check("O4 OFF: original error, no reduction, no resend",
                (off._testLastError ?? "").contains("400") && h.router.summaries == 0 && h.mainRequests.count == 1
                && h.allEvents.isEmpty, "error \(String(describing: off._testLastError)), summaries \(h.router.summaries), main \(h.mainRequests.count), events \(h.allEvents)")
    }

    /// Group DF (0.2.66): the default is ON for installs that never set the
    /// switch; an explicitly stored value (on or off) is read as before.
    @MainActor static func defaultOn(_ h: BackgroundPruneSelftestHarness) async {
        let key = ConversationManager.backgroundPruneDefaultsKey
        // Pure resolution on a scratch suite (never the shared domain).
        let suiteName = "briglia-mw-bgprune-default-\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            h.check("DF1 resolution: key absent → ON", ConversationManager.backgroundPruneSetting(in: suite))
            suite.set(false, forKey: key)
            h.check("DF1 resolution: stored false → OFF", !ConversationManager.backgroundPruneSetting(in: suite))
            suite.set(true, forKey: key)
            h.check("DF1 resolution: stored true → ON", ConversationManager.backgroundPruneSetting(in: suite))
            suite.removePersistentDomain(forName: suiteName)
        } else {
            h.check("DF1 scratch suite opens", false)
        }
        h.check("DF1 the build default is ON", ConversationManager.backgroundPruneDefaultOn)

        // Behaviour: an install with the key absent does ON work over the maximum.
        let manager = await h.freshManager(history: h.prunableHistory(), switchOn: nil)
        h.check("DF2 key absent: switch reads ON, engaged", manager.bgPruneTestSwitchOn && manager.bgPruneTestEngaged)
        manager.bgPruneTestSetLastPromptTokens(60_000)
        _ = await h.turn(manager, "over the maximum, switch never set")
        h.check("DF2 key absent: background-pruning work happened (events logged)", !h.allEvents.isEmpty, "\(h.allEvents)")
        h.check("DF2 key absent: reading the default writes nothing", UserDefaults.standard.object(forKey: key) == nil)
        // Let any job started by that turn settle before the next fixture
        // (freshManager resets the shared state; the gate must not hold it).
        h.router.gate.release()
        _ = await manager.bgPruneTestAwaitRelease(timeout: 2)

        let fresh = await h.freshManager(history: h.prunableHistory(pairs: 2, size: 200), switchOn: nil)
        let help = await fresh.bgPruneTestCommand("/prunebackground")
        h.check("DF3 /prunebackground shows ON and the new default", help.contains("Background pruning: ON (default: on)"), help)
        let status = await fresh.bgPruneTestCommand("/status")
        h.check("DF3 /status shows the line for a default-ON install", status.contains("✂️ Background pruning: on"), status)
        let on = await fresh.bgPruneTestCommand("/prunebackground on")
        h.check("DF4 on while default-ON is a no-op and writes nothing",
                on.contains("already ON") && UserDefaults.standard.object(forKey: key) == nil, on)
        let off = await fresh.bgPruneTestCommand("/prunebackground off")
        h.check("DF5 off stores an explicit false", off == "Background pruning: OFF."
                && UserDefaults.standard.object(forKey: key) as? Bool == false, off)
        // A new manager (as after a restart) keeps the explicit OFF.
        let restarted = await h.freshManager(history: h.prunableHistory(pairs: 2, size: 200), switchOn: false)
        h.check("DF5 explicit OFF survives a restart: switch off, not engaged",
                !restarted.bgPruneTestSwitchOn && !restarted.bgPruneTestEngaged)
        let offHelp = await restarted.bgPruneTestCommand("/prunebackground")
        h.check("DF5 /prunebackground shows OFF with the default named", offHelp.contains("Background pruning: OFF (default: on)"), offHelp)
    }
}
