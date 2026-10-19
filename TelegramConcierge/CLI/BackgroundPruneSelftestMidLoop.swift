import Foundation

/// The mid-loop site (§7.2 at M): a mid-loop freeze applied at the next
/// turn's T0, and a pre-request job applied at M of the same turn.
enum BackgroundPruneSelftestMidLoop {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        await freezeAtM(h)
        await applyAtM(h)
    }

    @MainActor static func readCall(_ h: BackgroundPruneSelftestHarness, _ id: String) -> (id: String, name: String, args: [String: Any]) {
        let path = h.filesRoot.appendingPathComponent("midloop.txt")
        try? "mid-loop fixture file\n".write(to: path, atomically: true, encoding: .utf8)
        return (id: id, name: "read_file", args: ["file_path": path.path])
    }

    @MainActor static func freezeAtM(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        h.router.holdSummaries = [1]
        manager.bgPruneTestSetLastPromptTokens(1_000)
        h.startTurn(manager, "work that fills the context", replies: [
            BackgroundPruneSelftestHarness.tools([readCall(h, "m-call-1")], prompt: 60_000),
            BackgroundPruneSelftestHarness.chat("finished", prompt: 1_000),
        ])
        let idle = await manager._testAwaitIdle(timeout: 40)
        h.check("M freeze after a completed round; the turn continues without waiting", idle
                && h.eventCount("bgprune.freeze.mid-loop") == 1 && manager.bgPruneTestPhase == "running"
                && h.mainRequests.count == 2, "\(h.allEvents) main \(h.mainRequests.count)")
        h.check("M the round after the freeze carried the unchanged history",
                h.mainRequests.count == 2 && h.bodyText(h.mainRequests[1]).contains("RESULT-h-call-0"))
        h.router.gate.release()
        _ = await h.waitPhase(manager, "ready")
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "next message")
        h.check("M a mid-loop job is applied at the next turn's T0, with the mid-loop notice",
                h.eventCount("bgprune.t0.applied") == 1 && h.prunedIds(manager).count >= 6
                && h.channel.delivered.contains { $0.hasPrefix("Context filled up while I was working.") },
                "\(h.allEvents) \(h.channel.delivered)")
    }

    @MainActor static func applyAtM(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        let toolGate = BackgroundPruneSelftestGate()
        ToolExecutor.toolBodyHoldForTesting = { name in if name == "read_file" { toolGate.wait() } }
        manager.bgPruneTestSetLastPromptTokens(60_000)
        h.startTurn(manager, "pre-request freeze, mid-loop apply", replies: [
            BackgroundPruneSelftestHarness.tools([readCall(h, "m-call-2")], prompt: 1_000),
            BackgroundPruneSelftestHarness.chat("finished", prompt: 1_000),
        ])
        let ready = await h.waitUntil { manager.bgPruneTestPhase == "ready" && toolGate.arrived == 1 }
        h.check("M precondition: the T1 job is ready while round 1's tool runs", ready)
        toolGate.release()
        let idle = await manager._testAwaitIdle(timeout: 40)
        ToolExecutor.toolBodyHoldForTesting = nil
        h.check("M a ready job is applied at the mid-loop boundary", idle && h.eventCount("bgprune.applied") == 1
                && h.eventCount("bgprune.t0.applied") == 0 && h.prunedIds(manager).count >= 6, "\(h.allEvents)")
        h.check("§8.5 at M the next request is built from the applied history (ids replaced in the request view)",
                h.mainRequests.count == 2 && h.bodyText(h.mainRequests[0]).contains("RESULT-h-call-0 ")
                && !h.bodyText(h.mainRequests[1]).contains("RESULT-h-call-0 "))
        h.check("§8.4 the current round survived the apply (live rounds kept in the next request)",
                h.mainRequests.count == 2 && h.bodyText(h.mainRequests[1]).contains("m-call-2"))
    }
}
