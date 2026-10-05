import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Real-turn rows: SV1 fast stop, SV3/SV4 hung helper and never-ending
/// stage, SV5 repeated /stop, SV4b limits, SV14 refinement, SV16 no channel.
extension StopVisibilityHarness {

    func turnSection() async {
        await fastStopRows()
        await hungHelperRows()
        await repeatedStopRows()
        await limitsRows()
        await refinementRows()
        await noDeliveryRows()
    }

    /// SV1: a turn that ends inside the grace keeps today's exact text and
    /// gets no follow-up.
    private func fastStopRows() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        server.script([
            MidturnHarness.chatTools([(id: "call-f1", name: "bash", args: ["command": "sleep 30", "wait_seconds": 60])]),
            MidturnHarness.chatText("never"),
        ])
        manager._testStartTurn(for: user("long command"))
        _ = await waitUntil { await !BackgroundProcessRegistry.shared.runningMainOwnedJobs().isEmpty }
        _ = await timedStop(manager)
        _ = await manager._testAwaitIdle(timeout: 15)
        await sleep(4)
        let texts = channel.stopTexts
        check("SV1 fast stop: today's text, unchanged", texts.count == 1 && texts[0].hasPrefix("⛔ I stopped the current work."),
              "\(texts)")
        check("SV1 fast stop: no follow-up notice and no series", !texts.contains { $0.hasPrefix("✅") } && manager._svLiveSeries.isEmpty,
              "series \(manager._svLiveSeries.count)")
        check("SV1 fast stop: nothing left in the stopped-request status", manager.stoppedRunsFinishing.isEmpty)
    }

    /// SV3 + SV4: the tool executor is blocked inside a tool (hung helper):
    /// the reply names the stopped request's tool, the added wait is bounded
    /// by 2.5 s, /status shows it, and exactly one completion follows the
    /// reply once the helper returns.
    private func hungHelperRows() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        guard let run = await startHeldTurn(manager, hold: hold, callId: "call-h1") else {
            check("SV3 setup: held turn started", false); hold.release(); return
        }
        let elapsed = await timedStop(manager)
        check("SV4 a never-ending stage adds at most 2.5 s (stop returned in \(String(format: "%.2f", elapsed ?? -1)) s)",
              elapsed.map { $0 >= 2.4 && $0 < 3.6 } == true)
        _ = await waitUntil(timeout: 5) { !channel.stopTexts.isEmpty }
        let reply = channel.stopTexts.first ?? ""
        check("SV3 the reply says the request is still finishing and names its tool",
              reply.hasPrefix("⛔ Stop requested. The request is still finishing: bash") && reply.contains("(running ")
                && reply.contains("I'll notify you when it ends."), reply)
        check("SV3 \"nothing new will start\" is gone", !reply.contains("Nothing new will start"))
        let status = await manager.handleTerminalCommand("/status")?.joined(separator: "\n") ?? ""
        check("SV4 /status shows the stopped request still finishing",
              status.contains("⛔ Stopped") && status.contains("still finishing: bash"), status)
        check("SV4 terminal /status lines come from the same source",
              manager.stoppedRunStatusLines().first?.contains("still finishing: bash") == true)
        await sleep(1)
        check("SV4 no completion while the stage never ends", channel.stopTexts.count == 1, "\(channel.stopTexts)")
        await finish(manager, hold)
        _ = await waitUntil(timeout: 10) { channel.stopTexts.count >= 2 }
        await sleep(0.5)
        let texts = channel.stopTexts
        check("SV3 exactly one completion, after the reply",
              texts.count == 2 && texts[1].hasPrefix("✅ The stopped request has ended.") && texts[1].contains("after /stop"),
              "\(texts)")
        check("SV3 the status entry is gone once the request ended", manager.stoppedRunsFinishing[run] == nil)
        check("SV3 the run's phase record is removed by its own teardown", manager._svRunPhase(run) == nil)
    }

    /// SV5: a second /stop while the first still finishes says "Already
    /// stopping" (not F2's "won't resume"), joins the same series, and no
    /// second completion is produced.
    private func repeatedStopRows() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        guard let run = await startHeldTurn(manager, hold: hold, callId: "call-r1") else {
            check("SV5 setup", false); hold.release(); return
        }
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.stopTexts.count >= 1 }
        let watchersAfterFirst = manager._svWatcherCount
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.stopTexts.count >= 2 }
        let second = channel.stopTexts.count >= 2 ? channel.stopTexts[1] : ""
        check("SV5 repeated /stop: \"Already stopping\" with the stage, not \"won't resume\"",
              second.hasPrefix("⛔ Already stopping. The request is still finishing: bash") && !second.contains("won't resume"),
              second)
        check("SV5 repeated /stop registers no second watcher", manager._svWatcherCount == watchersAfterFirst && watchersAfterFirst == 1,
              "watchers \(manager._svWatcherCount)")
        check("SV5 repeated /stop joins the same series", manager._svSeries(ofRun: run).count == 1)
        await finish(manager, hold)
        _ = await waitUntil(timeout: 10) { channel.stopTexts.count >= 3 }
        await sleep(1)
        let texts = channel.stopTexts
        check("SV5 one completion, after both replies",
              texts.count == 3 && texts[2].hasPrefix("✅") && texts.filter { $0.hasPrefix("✅") }.count == 1, "\(texts)")
    }

    /// SV4b: the 2.5 s bounds only the ADDED wait. Main-actor work blocked
    /// before the grace (a fixture at the cutoff interleave point) still
    /// delays the reply — documented as outside the guarantee.
    private func limitsRows() async {
        let manager = await freshManager()
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-l1") != nil else {
            check("SV4b setup", false); hold.release(); return
        }
        ConversationManager.stopCutoffInterleaveForTesting = { usleep(1_200_000) }   // blocks the main actor
        let elapsed = await timedStop(manager)
        ConversationManager.stopCutoffInterleaveForTesting = nil
        check("SV4b a blocked main actor before the grace delays the reply beyond 2.5 s (outside the guarantee)",
              elapsed.map { $0 >= 3.6 } == true, "elapsed \(elapsed ?? -1)")
        await finish(manager, hold)
    }

    /// SV14: stage refinement uses only open markers positively tied to
    /// the stopped batch; ambiguity or disabled markers → label only.
    private func refinementRows() async {
        let manager = await freshManager()
        let hold = SVToolHold(tool: "bash")
        guard let run = await startHeldTurn(manager, hold: hold, callId: "call-z1") else {
            check("SV14 setup", false); hold.release(); return
        }
        _ = await timedStop(manager)
        typealias Stage = (stage: String, callId: String?, tool: String?, elapsedMs: Int)
        func describe(_ stages: [Stage]) -> String {
            ConversationManager.openStagesProviderForTesting = { stages }
            defer { ConversationManager.openStagesProviderForTesting = nil }
            return manager.describeStillFinishing(runId: run)
        }
        let refined = describe([("tool.execute", "call-z1", "bash", 900), ("tool.body", "call-z1", "bash", 800),
                                ("fs.diff", "call-z1", "bash", 10)])
        check("SV14 a stage of the stopped batch's own call refines the label", refined.hasPrefix("bash — computing a file diff"), refined)
        let foreign = describe([("tool.execute", "call-other", "read_file", 50), ("git.checkpoint", "call-other", "read_file", 10)])
        check("SV14 a stage of another call (e.g. a newer run) is never used", foreign.hasPrefix("bash (running"), foreign)
        let ambiguous = describe([("tool.execute", "call-z1", "bash", 900), ("tool.execute", "call-z1", "bash", 20),
                                  ("fs.write", "call-z1", "bash", 10)])
        check("SV14 an ambiguous call id falls back to the label alone", ambiguous.hasPrefix("bash (running"), ambiguous)
        let disabled = describe([])
        check("SV14 markers disabled (no open stages): label only, same form", disabled.hasPrefix("bash (running"), disabled)
        let live = manager.describeStillFinishing(runId: run)
        check("SV14 with real markers the unknown tool.body stage gives the label only", live.hasPrefix("bash (running"), live)
        await finish(manager, hold)
    }

    /// SV16: no delivery available (no channel, no reply address): the
    /// decision and status still work and the entry clears at completion.
    private func noDeliveryRows() async {
        let manager = await freshManager()
        let hold = SVToolHold(tool: "bash")
        guard let run = await startHeldTurn(manager, hold: hold, callId: "call-n1") else {
            check("SV16 setup", false); hold.release(); return
        }
        _ = await timedStop(manager)
        check("SV16 no channel: the stopped request is tracked, no series is created",
              manager.stoppedRunsFinishing[run]?.announced == true && manager._svLiveSeries.isEmpty)
        await finish(manager, hold)
        check("SV16 the entry clears at completion without any delivery", manager.stoppedRunsFinishing.isEmpty)
    }
}
