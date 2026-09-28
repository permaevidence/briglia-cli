import Foundation

/// The foreground tool keeps its own semantics (T4), a mid-turn user
/// message still renders last (T18), large and multibyte results are
/// appended in full (T19).
extension MidturnHarness {

    func roundLoopSemanticsSection() async throws {
        try await roundForegroundAgentLast()
        try await roundForegroundErrorFlag()
        roundCompactLogLabel()
        try await roundUserBlockLast()
        try await roundLargeMultibyte()
    }

    /// T4a: the last result is an `Agent` call: its session event is parsed
    /// from the foreground JSON before the section is appended.
    private func roundForegroundAgentLast() async throws {
        let manager = await roundFresh()
        let script = SubagentScript()
        script.general(Self.costedText("T4_SUB_FINAL", cost: 0), delay: 1.0, cost: 0)
        installSubagentRouter(script)
        server.script([
            Self.chatTools([Self.bgCall("t4-bg", "sleep 0.1; echo T4_BG"),
                            (id: "t4-agent", name: "Agent", args: Self.agentArgs(description: "t4 foreground", prompt: "do it"))]),
            Self.chatText("t4 final"),
        ])
        manager._testStartTurn(for: user("T4 agent last"))
        _ = await manager._testAwaitIdle(timeout: 40)
        let agent = results(manager).first { $0.toolCallId == "t4-agent" }
        let outcome = manager._testMessages.last { $0.role == .assistant }
        check("T4a the section rides the Agent result, whose own JSON still parses first",
              agent?.deliveredCompletions.count == 1 && agent?.content.contains("T4_BG") == true
                && (RoundDelivery.foregroundContent(of: agent!).data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil),
              agent?.content.prefix(200).description ?? "no result")
        check("T4b the Agent session event was recorded (parsed before the append)",
              outcome?.subagentSessionEvents.contains { $0.subagentType == "general-purpose" } == true,
              "\(outcome?.subagentSessionEvents ?? [])")
    }

    /// T4c: a failing foreground call keeps its error flag in the turn log;
    /// the other call stays unflagged.
    private func roundForegroundErrorFlag() async throws {
        let manager = await roundFresh()
        server.script([
            Self.chatTools([Self.bgCall("t4e-bg", "sleep 0.1; echo T4E_BG"), Self.fgCall("t4e-fg", "sleep 1.2"),
                            (id: "t4e-fail", name: "read_file", args: ["path": "/nonexistent/t4e-missing.txt"])]),
            Self.chatText("t4e final"),
        ])
        manager._testStartTurn(for: user("T4 error flag"))
        _ = await manager._testAwaitIdle(timeout: 30)
        let log = manager._testToolLog
        let failing = results(manager).first { $0.toolCallId == "t4e-fail" }
        check("T4c the failing foreground call carries the section AND keeps its error flag; the others stay unflagged",
              failing?.deliveredCompletions.count == 1 && log.count == 3 && !log[0].failed && !log[1].failed && log[2].failed,
              "\(log)")
    }

    /// T4d: the compact tool log labels a carrier from its foreground part.
    private func roundCompactLogLabel() {
        let manager = ConversationManager()
        let id = UUID()
        var result = ToolResultMessage(toolCallId: "t4d", content: "plain foreground output line")
        result.content = RoundDelivery.append([.init(messageId: id, body: "{\"message\":\"BG_JSON_MESSAGE\"}")], to: result.content)
        result.deliveredCompletions = [id]
        let label = manager._testCompactLogLabel(result)
        check("T4d compact log label comes from the foreground part, not the background body",
              label.contains("plain foreground output line") && !label.contains("BG_JSON_MESSAGE"), label)
    }

    /// T18: a round carrying background results AND a mid-turn user
    /// message: the direct-user block still renders last.
    private func roundUserBlockLast() async throws {
        let manager = await roundFresh()
        server.script([
            Self.chatTools([Self.bgCall("t18-bg", "sleep 0.1; echo T18_BG"), Self.fgCall("t18-fg", "sleep 1.2")]),
            Self.chatText("answered both"),
        ])
        onceAt("after-reads") { await manager._testDispatchUser(self.user("T18 USER MESSAGE mid-turn")) }
        manager._testStartTurn(for: user("T18 start"))
        _ = await manager._testAwaitIdle(timeout: 30)
        let second = requestBodies().dropFirst().first ?? ""
        let bg = second.range(of: "T18_BG")?.lowerBound
        let direct = second.range(of: "[Direct user message 1 of 1]")?.lowerBound
        check("T18 background section before the direct-user block in the same tool result",
              bg != nil && direct != nil && bg! < direct!, "bg \(bg != nil) direct \(direct != nil)")
    }

    /// T19: a large (≈30 KB) multibyte subagent report is appended in full.
    private func roundLargeMultibyte() async throws {
        let manager = await roundFresh()
        let big = String(repeating: "Città perché naïve — ✓ 🚀 日本語 ", count: 800) + "T19_END"
        let completion = Self.injectedCompletion("t19_sub", final: big)
        onceAt("bash-read") { await SubagentBackgroundRegistry.shared._testEnqueueCompletion(completion) }
        server.script([Self.chatTools([Self.fgCall("t19-fg", "echo t19")]), Self.chatText("t19 final")])
        manager._testStartTurn(for: user("T19 large report"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let carrier = carriers(manager).first
        check("T19a the whole report is appended byte-exact (no excerpt, no limit)",
              carrier?.content.contains(big) == true && carrier?.deliveredCompletions == [completion.messageId],
              "len \(carrier?.content.utf8.count ?? 0)")
        check("T19b the next request carries it in full", (requestBodies().dropFirst().first ?? "").contains("T19_END"))
        check("T19c acknowledged, no follow-up", await roundSettled(manager) && server.completeRequests.count == 2)
    }
}
