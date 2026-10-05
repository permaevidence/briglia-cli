import Foundation

/// Local surfaces (§4.2): SV10d captured socket command ordering, SV11
/// undeduplicated local notices (F1 + F7), SV12 local status; SV13 restart.
extension StopVisibilityHarness {

    func localSection() async {
        await capturedCommandRows()
        await localRepeatsRows()
        await localOverlapRows()
    }

    /// SV10d: a captured `/stop` (socket "command") whose run completes
    /// immediately after the decision: the completion is held until the
    /// command's own result was handed to the client.
    private func capturedCommandRows() async {
        let manager = await freshManager()
        let notices = collectLocalNotices(manager)
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-cap") != nil else { check("SV10d setup", false); hold.release(); return }
        // The run "ends" synchronously right after the decision (the
        // watcher's own handler), before the caller delivered the result.
        ConversationManager.afterStopDecisionForTesting = { manager, run in manager._svRunEnded(run) }
        let order = SVNoticeLog()
        let done = SVNoticeLog()
        Task { @MainActor in
            await manager.handleTerminalCommand("/stop") { lines in
                order.items.append("command_result:" + (lines ?? []).joined(separator: "|"))
                order.items.append("notices-before-result:\(notices.items.count)")
            }
            done.items.append("done")
        }
        let returned = await waitUntil(timeout: 15) { !done.items.isEmpty }
        check("SV10d the captured /stop returns (bounded)", returned)
        ConversationManager.afterStopDecisionForTesting = nil
        let orderItems = order.items
        await sleep(0.3)
        let result = orderItems.first ?? ""
        check("SV10d the captured command's result carries the still-finishing reply",
              result.contains("⛔ Stop requested. The request is still finishing: bash"), result)
        check("SV10d no follow-up was emitted before the command's result was delivered",
              orderItems.count == 2 && orderItems[1] == "notices-before-result:0", "\(orderItems)")
        check("SV10d the completion follows once the result was delivered",
              notices.items.count == 1 && notices.items[0].hasPrefix("✅"), "\(notices.items)")
        await finish(manager, hold)
        // Plain overload (selftests, other callers): released when it returns.
        let plain = await freshManager()
        let plainNotices = collectLocalNotices(plain)
        let plainHold = SVToolHold(tool: "bash")
        guard await startHeldTurn(plain, hold: plainHold, callId: "call-cap2") != nil else { check("SV10d setup 2", false); plainHold.release(); return }
        ConversationManager.afterStopDecisionForTesting = { manager, run in manager._svRunEnded(run) }
        let plainResult = SVNoticeLog()
        var emittedAtReturn = -1
        Task { @MainActor in
            let lines = await plain.handleTerminalCommand("/stop") ?? []
            emittedAtReturn = plainNotices.items.count
            plainResult.items = lines.isEmpty ? ["<none>"] : lines
        }
        _ = await waitUntil(timeout: 15) { !plainResult.items.isEmpty }
        let lines = plainResult.items
        ConversationManager.afterStopDecisionForTesting = nil
        check("SV10d plain overload: reply captured, follow-up released when it returns",
              lines.first?.hasPrefix("⛔ Stop requested.") == true && emittedAtReturn == 1, "\(lines) \(plainNotices.items)")
        await finish(plain, plainHold)
    }

    /// SV11 (F1, F7): the terminal/app Stop button now shows the ordinary
    /// reply, and identical repeated notices are all delivered.
    private func localRepeatsRows() async {
        let manager = await freshManager()
        let notices = collectLocalNotices(manager)
        await manager.stopFromApp()
        await manager.stopFromApp()
        await sleep(0.2)
        check("SV11 two ordinary local stops: both identical replies appear (no dedup)",
              notices.items == ["I'm not doing anything at the moment.", "I'm not doing anything at the moment."], "\(notices.items)")
        // A fast local stop shows today's text.
        let fast = await freshManager()
        let fastNotices = collectLocalNotices(fast)
        server.script([
            MidturnHarness.chatTools([(id: "call-lf", name: "bash", args: ["command": "sleep 30", "wait_seconds": 60])]),
            MidturnHarness.chatText("never"),
        ])
        fast._testStartTurn(for: user("long local command"))
        _ = await waitUntil { await !BackgroundProcessRegistry.shared.runningMainOwnedJobs().isEmpty }
        await fast.stopFromApp()
        _ = await fast._testAwaitIdle(timeout: 15)
        check("SV12 terminal/app Stop: today's ordinary reply is visible locally",
              fastNotices.items.first?.hasPrefix("⛔ I stopped the current work.") == true, "\(fastNotices.items)")
    }

    /// SV11 + SV12: two overlapping local stops of still-finishing runs; both
    /// completions appear; local status surfaces show the stopped requests.
    private func localOverlapRows() async {
        let manager = await freshManager(history: archiveSizedHistory())
        let notices = collectLocalNotices(manager)
        let gate = ServerGate()
        routeArchive(holdingSummaryOn: gate)
        manager._testStartTurn(for: user("local run A"))
        _ = await waitUntil(timeout: 20) { gate.arrived > 0 }
        await boundedStopFromApp(manager)
        manager._svSetArchiveBackoff(until: Date().addingTimeInterval(3_600))
        let hold = SVToolHold(tool: "read_file")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sv-local.txt")
        try? "local".write(to: scratch, atomically: true, encoding: .utf8)
        guard await startHeldTurn(manager, hold: hold, callId: "call-lb", tool: "read_file",
                                  args: ["file_path": scratch.path], label: "local run B") != nil else {
            check("SV11 setup", false); hold.release(); gate.release(); return
        }
        await boundedStopFromApp(manager)
        check("SV11 both local replies say still finishing",
              notices.items.count == 2 && notices.items.allSatisfy { $0.hasPrefix("⛔ Stop requested.") }, "\(notices.items)")
        let status = await manager.handleTerminalCommand("/status")?.joined(separator: "\n") ?? ""
        check("SV12 captured /status (socket command / Telegram form) lists both stopped requests",
              status.components(separatedBy: "⛔ Stopped").count == 3, status)
        let local = manager.stoppedRunStatusLines()
        check("SV12 terminal /status lines list both", local.filter { $0.hasPrefix("⛔ Stopped") }.count == 2, "\(local)")
        hold.release()
        gate.release()
        _ = await manager._testAwaitIdle(timeout: 30)
        _ = await waitUntil(timeout: 20) { notices.items.count >= 4 }
        await sleep(0.5)
        check("SV11 both completions appear on the local stream",
              notices.items.count == 4 && notices.items.suffix(2).allSatisfy { $0.hasPrefix("✅") }, "\(notices.items)")
        server.router = nil
        server.concurrent = false
    }

    /// stopFromApp on its own task, bounded (a broken build must fail the
    /// rows, not hang the battery).
    func boundedStopFromApp(_ manager: ConversationManager, timeout: TimeInterval = 15) async {
        let done = SVNoticeLog()
        Task { @MainActor in await manager.stopFromApp(); done.items.append("done") }
        _ = await waitUntil(timeout: timeout) { !done.items.isEmpty }
    }

    /// SV13: after a restart nothing is announced and the stopped request is
    /// not resumed (the stop marker), no new file involved.
    func restartSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-rs") != nil else { check("SV13 setup", false); hold.release(); return }
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.stopTexts.count == 1 }
        let requests = server.completeRequests.count
        // "Restart": a new manager over the same storage.
        let restarted = ConversationManager()
        await restarted._testPrepareScriptedProvider(apiKey: apiKey)
        let restartedChannel = SVRecordingChannel(kind: .telegram)
        restarted._svRegisterChannel(restartedChannel)
        restarted._svSetLastUserAddress(telegramAddress)
        restarted._testStartupPasses()
        await sleep(1)
        check("SV13 after a restart: no stopped-request state and no notice",
              restarted.stoppedRunsFinishing.isEmpty && restartedChannel.stopTexts.isEmpty)
        check("SV13 the stopped request is not resumed after a restart",
              !restarted._testIsActive && server.completeRequests.count == requests,
              "active \(restarted._testIsActive), requests \(server.completeRequests.count) vs \(requests)")
        await finish(manager, hold)
    }
}
