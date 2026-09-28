import Foundation

/// Subagent rows: explicit background general (T2) and Web (T2w) runs, a
/// wake-moved run (T2m), and spend (T15, owner decision D6).
extension MidturnHarness {

    func roundSubagentSection() async throws {
        clearModelSpend()
        try await roundBackgroundSubagent(web: false)
        try await roundBackgroundSubagent(web: true)
        try await roundMovedSubagent()
        try await roundSubagentSpend()
    }

    /// T2 / T2w: an explicit background run that finishes during the next
    /// command is appended with the body idle delivery would have used.
    private func roundBackgroundSubagent(web: Bool) async throws {
        let tag = web ? "T2w" : "T2"
        let manager = await roundFresh()
        let script = SubagentScript()
        if web { script.web(Self.costedText("T2W_WEB_FINAL", cost: 0.01), delay: 0.3, cost: 0.01) }
        else { script.general(Self.costedText("T2_SUB_FINAL", cost: 0.01), delay: 0.3, cost: 0.01) }
        installSubagentRouter(script)
        let args = Self.agentArgs(web ? "Web" : "general-purpose", description: "\(tag) background", prompt: "research", background: true)
        server.script([
            Self.chatTools([(id: "\(tag)-agent", name: "Agent", args: args), Self.fgCall("\(tag)-fg", "sleep 2.5")]),
            Self.chatText("\(tag) final"),
        ])
        manager._testStartTurn(for: user("\(tag) background subagent"))
        _ = await manager._testAwaitIdle(timeout: 40)
        let carrier = carriers(manager).first
        let content = carrier?.content ?? ""
        check("\(tag)a the finished run is appended to the round's last result as [SUBAGENT COMPLETE]",
              carrier?.toolCallId == "\(tag)-fg" && content.contains("[SUBAGENT COMPLETE]")
                && content.contains(web ? "subagent_type: Web" : "T2_SUB_FINAL") && content.contains("final_message:"),
              String(content.suffix(300)))
        if web {
            check("T2wb the Web researcher's contract lines ride along (evidence provenance)", content.contains("evidence_provenance:"))
        }
        check("\(tag)c acknowledged (registry, record), no idle copy, no follow-up",
              await roundSettled(manager) && !manager._testMessages.contains { $0.kind == .subagentComplete }
                && mainRequestBodies().count == 2)
        server.router = nil; server.concurrent = false
    }

    /// T2m: a foreground run moved to the background by a user message
    /// finishes during a later round of the SAME turn and arrives there.
    private func roundMovedSubagent() async throws {
        let manager = await roundFresh()
        let script = SubagentScript()
        script.general(Self.costedText("T2M_MOVED_FINAL", cost: 0), delay: 2.0, cost: 0)
        installSubagentRouter(script)
        server.script([
            Self.chatTools([(id: "t2m-agent", name: "Agent", args: Self.agentArgs(description: "t2m foreground", prompt: "slow"))]),
            Self.chatTools([Self.fgCall("t2m-fg", "sleep 3")]),
            Self.chatText("t2m final"),
        ])
        manager._testStartTurn(for: user("T2m foreground subagent"))
        _ = await waitUntil(timeout: 10) { await SubagentBackgroundRegistry.shared._testForegroundCount() > 0 }
        await manager._testDispatchUser(user("T2m quick question"))
        _ = await manager._testAwaitIdle(timeout: 40)
        let moved = results(manager).first { $0.toolCallId == "t2m-agent" }
        let carrier = carriers(manager).first
        check("T2ma the call was moved to the background by the user message", moved?.outcomeBinding?.kind == .moved,
              moved?.content.prefix(160).description ?? "no result")
        check("T2mb its report arrived in a later round of the same turn",
              carrier?.toolCallId == "t2m-fg" && carrier?.content.contains("T2M_MOVED_FINAL") == true)
        check("T2mc acknowledged, no idle copy, no follow-up",
              await roundSettled(manager) && !manager._testMessages.contains { $0.kind == .subagentComplete }
                && mainRequestBodies().count == 3)
        server.router = nil; server.concurrent = false
    }

    /// T15: an unrecorded run is charged exactly once, at acknowledgement,
    /// to the day/month totals; a recorded run never; the turn cap is
    /// unaffected; a later save does not charge again.
    private func roundSubagentSpend() async throws {
        let manager = await roundFresh()
        clearModelSpend()
        try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey, value: "0.1")
        let unrecorded = Self.injectedCompletion("t15_unrecorded", final: "T15_U", spend: 0.25)
        let recorded = Self.injectedCompletion("t15_recorded", final: "T15_R", spend: 0.3, chargeCaptured: true)
        onceAt("bash-read") {
            await SubagentBackgroundRegistry.shared._testEnqueueCompletion(unrecorded)
            await SubagentBackgroundRegistry.shared._testEnqueueCompletion(recorded)
        }
        server.script([
            Self.chatTools([Self.fgCall("t15-a", "echo a")]),
            Self.chatTools([Self.fgCall("t15-b", "echo b")]),
            Self.chatText("t15 final"),
        ])
        manager._testStartTurn(for: user("T15 spend"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let first = modelSpendToday()
        check("T15a both appended mid-turn", carriers(manager).first?.deliveredCompletions.count == 2)
        check("T15b the per-turn cap is not charged by the delivery (the turn ran its three requests)",
              server.completeRequests.count == 3 && !(requestBodies().last ?? "").contains("[SPEND LIMIT]"))
        check("T15c unrecorded run charged exactly once at acknowledgement; recorded run never",
              abs(first - 0.25) < 0.0001, "today \(first)")
        _ = manager._testSave(); _ = manager._testSave()
        check("T15d later saves do not charge again", abs(modelSpendToday() - 0.25) < 0.0001, "today \(modelSpendToday())")
        try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey)
        clearModelSpend()
    }
}
