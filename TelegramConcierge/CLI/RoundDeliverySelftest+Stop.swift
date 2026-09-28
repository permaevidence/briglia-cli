import Foundation

/// Force-final rule (T5), /stop (T6), held states (T17), idle-only sources
/// (T16).
extension MidturnHarness {

    func roundForceFinalSection() async throws {
        try await roundCapReached()
        try await roundPauseActive()
        try await roundLastSafetyRound()
        try await roundLateEndAfterAppend()
    }

    /// T5a: the round's tool spend reaches the per-turn cap: a forced final
    /// answer follows, so nothing is appended; the result goes to idle.
    private func roundCapReached() async throws {
        let manager = await roundFresh()
        let script = SubagentScript()
        script.general(Self.costedText("T5A_SUB", cost: 0.5), delay: 1.2, cost: 0.5)
        installSubagentRouter(script)
        try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey, value: "0.4")
        server.script([
            Self.chatTools([Self.bgCall("t5a-bg", "sleep 0.1; echo T5A_BG"),
                            (id: "t5a-agent", name: "Agent", args: Self.agentArgs(description: "t5a costly", prompt: "x"))]),
            Self.chatText("t5a forced final"),
            Self.chatText("t5a saw the idle notice"),
        ])
        manager._testStartTurn(for: user("T5a cap"))
        _ = await manager._testAwaitIdle(timeout: 40)
        let final = mainRequestBodies().dropFirst().first ?? ""
        check("T5a cap reached with this round's tool spend: forced final, nothing appended",
              final.contains("[SPEND LIMIT]") && !final.contains(Self.frameProbe) && carriers(manager).isEmpty)
        try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey)
        server.router = nil; server.concurrent = false
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 20)
        check("T5a' delivered at idle instead", manager._testMessages.filter { $0.kind == .bashComplete && $0.content.contains("T5A_BG") }.count == 1)
    }

    /// T5b: a daily pause active at the boundary (this round's tool spend
    /// crossed the daily limit): the turn pauses, nothing appended.
    private func roundPauseActive() async throws {
        let manager = await roundFresh()
        clearModelSpend()
        let script = SubagentScript()
        script.general(Self.costedText("T5B_SUB", cost: 0.5), delay: 1.2, cost: 0.5)
        installSubagentRouter(script)
        try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey, value: "0.3")
        server.script([
            Self.chatTools([Self.bgCall("t5b-bg", "sleep 0.1; echo T5B_BG"),
                            (id: "t5b-agent", name: "Agent", args: Self.agentArgs(description: "t5b costly", prompt: "x"))]),
        ])
        manager._testStartTurn(for: user("T5b pause"))
        _ = await manager._testAwaitIdle(timeout: 40)
        check("T5b daily pause at the boundary: nothing appended, one request only",
              carriers(manager).isEmpty && mainRequestBodies().count == 1)
        try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey)
        clearModelSpend()
        server.router = nil; server.concurrent = false
        _ = await waitUntil(timeout: 5) { !(await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery().isEmpty) }
        let queued = !(await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery().isEmpty)
        check("T5b' the result stays queued for idle delivery", manager._testRoundReservations.isEmpty && queued)
    }

    /// T5c: the last safety round ends in a forced final: nothing appended.
    private func roundLastSafetyRound() async throws {
        let manager = await roundFresh()
        try AgentTurnOverrides.save(["main": 1])
        server.script([
            Self.chatTools([Self.bgCall("t5c-bg", "sleep 0.1; echo T5C_BG"), Self.fgCall("t5c-fg", "sleep 1.2")]),
            Self.chatText("t5c forced final"),
        ])
        manager._testStartTurn(for: user("T5c last round"))
        _ = await manager._testAwaitIdle(timeout: 30)
        try? AgentTurnOverrides.save([:])
        check("T5c last safety round: forced final without the section",
              (requestBodies().dropFirst().first ?? "").contains("[ROUND LIMIT]") && carriers(manager).isEmpty)
    }

    /// T5d: a pause that flips AFTER the append: the section stays in the
    /// saved round (ordinary tool output) and is acknowledged.
    private func roundLateEndAfterAppend() async throws {
        let manager = await roundFresh()
        clearModelSpend()
        onceAt("after-append") {
            try? KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey, value: "0.01")
            KeychainHelper.recordOpenRouterSpend(0.05)
        }
        server.script([Self.chatTools([Self.bgCall("t5d-bg", "sleep 0.1; echo T5D_BG"), Self.fgCall("t5d-fg", "sleep 1.2")])])
        manager._testStartTurn(for: user("T5d late pause"))
        _ = await manager._testAwaitIdle(timeout: 30)
        try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey)
        clearModelSpend()
        let settled = await roundSettled(manager)
        check("T5d late end after the append: the saved round keeps the section; acknowledged, no idle copy",
              carriers(manager).count == 1 && carriers(manager).first?.content.contains("T5D_BG") == true && settled)
    }

    // MARK: /stop

    func roundStopSection() async throws {
        try await roundStoppedJobNeverMidTurn()
        for stage in ["bash-read", "subagent-read", "after-reads"] { try await roundStopDuringRead(stage) }
        try await roundStopAfterAppend()
        try await roundHeldStates()
    }

    /// T6a: a job stopped by /stop never arrives mid-turn in a later turn.
    private func roundStoppedJobNeverMidTurn() async throws {
        let manager = await roundFresh()
        server.script([Self.chatTools([Self.bgCall("t6a-bg", "sleep 30")]), Self.chatText("launched")])
        manager._testStartTurn(for: user("T6a launch"))
        _ = await manager._testAwaitIdle(timeout: 20)
        await manager._testStop()
        _ = await waitUntil(timeout: 10) { !(await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery().isEmpty) }
        server.script([Self.chatTools([Self.fgCall("t6a-next", "sleep 0.2")]), Self.chatText("t6a next turn")])
        manager._testStartTurn(for: user("T6a new turn"))
        _ = await manager._testAwaitIdle(timeout: 20)
        check("T6a the stopped job's completion was not appended in the next turn", carriers(manager).isEmpty)
    }

    /// T6b: /stop interleaving at a drain await prevents the append — also
    /// of a result that finished after the stop's cutoff (so no stop filter
    /// names it; only the post-await recheck of the run can refuse it).
    private func roundStopDuringRead(_ stage: String) async throws {
        let manager = await roundFresh()
        server.script([Self.chatTools([Self.bgCall("t6b-bg", "sleep 0.1; echo T6B_BG"), Self.fgCall("t6b-fg", "sleep 1.2")])])
        onceAt(stage) {
            await manager._testStop()
            await SubagentBackgroundRegistry.shared._testEnqueueCompletion(Self.injectedCompletion("t6b_late", final: "T6B_LATE"))
        }
        manager._testStartTurn(for: user("T6b stop at \(stage)"))
        _ = await manager._testAwaitIdle(timeout: 30)
        _ = await waitUntil(timeout: 20) { manager._testMessages.contains { $0.content.hasPrefix("⛔ Work interrupted") } }
        check("T6b /stop during the drain (\(stage)) prevents the append",
              carriers(manager).isEmpty && manager._testRoundReservations.isEmpty)
    }

    /// T6c: a result appended before /stop is tool output of a saved round:
    /// the interrupted outcome carries it, it is acknowledged, and the idle
    /// drain appends no copy.
    private func roundStopAfterAppend() async throws {
        let manager = await roundFresh()
        server.script([
            Self.chatTools([Self.bgCall("t6c-bg", "sleep 0.1; echo T6C_BG"), Self.fgCall("t6c-fg", "sleep 1.2")]),
            Self.chatTools([Self.fgCall("t6c-long", "sleep 20")]),
        ])
        manager._testStartTurn(for: user("T6c stop after append"))
        _ = await waitUntil(timeout: 20) { !manager._testRoundReservations.isEmpty }
        _ = await waitUntil(timeout: 20) { await BackgroundProcessRegistry.shared.runningMainOwnedJobs().contains { $0.command.contains("sleep 20") } }
        await manager._testStop()
        _ = await manager._testAwaitIdle(timeout: 20)
        // /stop clears the active run at once; the cancelled task saves its
        // interrupted outcome while it unwinds.
        _ = await waitUntil(timeout: 20) { manager._testMessages.contains { $0.content.hasPrefix("⛔ Work interrupted") } }
        check("T6c the interrupted outcome keeps the round with its section", carriers(manager).first?.content.contains("T6C_BG") == true,
              "carriers \(carriers(manager).map { String($0.content.suffix(160)) }) last \(manager._testMessages.last?.content.prefix(80) ?? "")")
        check("T6c' acknowledged after the interrupted-outcome save", await roundSettled(manager))
        await manager._testIdleDrains()
        check("T6c'' no idle copy", !manager._testMessages.contains { $0.kind == .bashComplete && $0.content.contains("T6C_BG") })
    }

    /// T17: a hold that appears at the drain's await blocks the append.
    private func roundHeldStates() async throws {
        for (label, apply, clear) in [
            ("recovery blocked", { (m: ConversationManager) in m._testSetRecoveryBlocked(true) }, { (m: ConversationManager) in m._testSetRecoveryBlocked(false) }),
            ("held-message file unreadable", { (m: ConversationManager) in m._testSetHeldQueueProblem("injected") }, { (m: ConversationManager) in m._testSetHeldQueueProblem(nil) }),
        ] {
            let manager = await roundFresh()
            server.script([Self.chatTools([Self.bgCall("t17-bg", "sleep 0.1; echo T17_BG"), Self.fgCall("t17-fg", "sleep 1.2")]),
                           Self.chatText("t17 final")])
            onceAt("after-reads") { apply(manager) }
            manager._testStartTurn(for: user("T17 \(label)"))
            _ = await manager._testAwaitIdle(timeout: 30)
            clear(manager)
            check("T17 \(label) at the boundary: drain skipped", carriers(manager).isEmpty)
        }
    }

    // MARK: Idle-only sources (T16)

    func roundAmbientSection() async throws {
        let manager = await roundFresh()
        let email = Message(role: .user, content: "T16_EMAIL_BODY", kind: .emailArrived)
        onceAt("bash-read") {
            manager._testQueueAmbient(email)
            manager._testSeedPendingWatcherFire()
        }
        server.script([Self.chatTools([Self.fgCall("t16-a", "echo a")]), Self.chatTools([Self.fgCall("t16-b", "echo b")]),
                       Self.chatText("t16 final")])
        manager._testStartTurn(for: user("T16 ambient during a turn"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let all = results(manager).map(\.content).joined()
        check("T16a an email and a watcher fire arriving mid-turn are never appended to a round",
              !all.contains("T16_EMAIL_BODY") && !all.contains("[test fire]") && carriers(manager).isEmpty)
        check("T16b they stay queued for idle handling",
              manager._testPendingWatcherFireCount() == 1 || manager._testMessages.contains { $0.content == "T16_EMAIL_BODY" }
                || FileManager.default.fileExists(atPath: manager._testPendingAmbientURL.path))
    }
}
