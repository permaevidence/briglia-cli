import Foundation

extension MidturnHarness {
    func repro1bSection() async throws {
        try await reproCancelCase(cancel: false)
        try await reproCancelCase(cancel: true)
        let pattern = "mcp__*__browser_evaluate"
        let type = SubagentType(name: "cx-browser", description: "test", systemPromptSuffix: "x",
                                allowedToolNames: nil, defaultMaxTurns: 10, preferredModel: .inherit,
                                mcpToolPatterns: [pattern])
        check("CX6 unsupported internal wildcard does not grant browser access",
              !MCPAgentRouting.matches(pattern: pattern, name: "mcp__playwright__browser_evaluate"),
              "matches real tool=\(MCPAgentRouting.matches(pattern: pattern, name: "mcp__playwright__browser_evaluate")), eligible=\(ToolExecutor.subagentDetachEligible(type: type))")
        _ = await freshManager()
        let id = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: id))
        ToolChargeLedger.capture(jobId: id, amountUSD: 0.7, kind: "subagent")
        check("CX1 control recorded charge counted", abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9)
        try Data("{corrupt".utf8).write(to: ToolChargeLedger.ledgerURL)
        let before = ToolChargeLedger.snapshot()
        check("CX2 known charge remains counted when ledger unreadable", abs(before.today - 0.7) < 1e-9,
              "total=\(before.today), record charge=\(String(describing: records().first?.charge))")
        let accepted = ToolChargeLedger.acceptOpenIncidents(channel: "test")
        let after = ToolChargeLedger.snapshot()
        check("CX3 accepting unknown preserves recorded known charge", accepted.failure == nil && abs(after.today - 0.7) < 1e-9,
              "total=\(after.today), complete=\(after.isComplete), accepted=\(accepted.accepted.count)")

        _ = await freshManager()
        let unknown = UUID()
        try ToolChargeLedger.openUnknownAmount(jobId: unknown, day: Date(), detail: "test")
        try Data("{corrupt".utf8).write(to: ToolChargeLedger.ledgerURL)
        _ = ToolChargeLedger.snapshot()
        struct Injected: Error {}
        ToolChargeLedger.faultForTesting = { if $0 == "incident-accept" { throw Injected() } }
        let result = ToolChargeLedger.acceptOpenIncidents(channel: "test")
        ToolChargeLedger.faultForTesting = nil
        ToolChargeLedger.forgetHeldForTesting()
        let restarted = ToolChargeLedger.snapshot()
        let incidentID = "unknown-amount:" + unknown.uuidString.lowercased()
        check("CX4 durable replacement acceptance completes after incident-save failure", restarted.isComplete,
              "reply=\(String(describing: result.failure)), incidents=\(restarted.incidents.map(\.id)), target=\(incidentID)")

        _ = await freshManager()
        var old = chargeRecord()
        let comps = Calendar.current.dateComponents([.year,.month], from: Date())
        let monthStart = Calendar.current.date(from: comps)!
        old.startedAt = monthStart.addingTimeInterval(-30)
        try DetachedJobStore.create(old)
        try ToolChargeLedger.registerUnknownSpend(old)
        let crossing = ToolChargeLedger.snapshot(referenceDate: monthStart.addingTimeInterval(30))
        check("CX5 lost run crossing month keeps current accounting incomplete", !crossing.isComplete,
              "complete=\(crossing.isComplete), stored=\(openIncidents().map { $0.periods })")
    }
    func reproCancelCase(cancel: Bool) async throws {
        _ = await freshManager()
        ForceDetach.overrideForTesting = true
        MidturnWakeSignal.forcedDelaySecondsForTesting = 0.2
        defer {
            ForceDetach.overrideForTesting = nil
            MidturnWakeSignal.forcedDelaySecondsForTesting = 0.8
            ToolExecutor.beforeSubagentRecordForTesting = nil
        }
        let script = SubagentScript()
        script.general(Self.costedText("late subagent reply", cost: 0.01), delay: 3, cost: 0.01)
        installSubagentRouter(script)
        let service = OpenRouterService()
        await service.configure(apiKey: apiKey)
        let executor = ToolExecutor()
        await executor.configure(openRouterKey: apiKey, serperKey: "", jinaKey: "")
        await executor.configureOpenRouter(service, imagesDirectory: StoragePaths.dataRoot.appendingPathComponent("images"),
                                          documentsDirectory: StoragePaths.dataRoot.appendingPathComponent("documents"))
        ToolExecutor.beforeSubagentRecordForTesting = {
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let args = String(data: try JSONSerialization.data(withJSONObject: Self.agentArgs(description: "cancellation", prompt: "run")), encoding: .utf8)!
        let call = ToolCall(id: "cx-cancel", type: "function", function: FunctionCall(name: "Agent", arguments: args))
        let wake = WakeContext(turnRunId: UUID(), callId: call.id, toolName: "Agent", fingerprint: "test",
                               callStartedAt: .now, historyAnchorMessageId: nil)
        let task = Task.detached {
            await WakeContext.$current.withValue(wake) {
                await executor.executeAgentToolResult(call)
            }
        }
        let result = await task.value
        let handles = await SubagentBackgroundRegistry.shared.runningHandles()
        let moved = parse(result.content)["status"] as? String == "moved_to_background"
        check(cancel ? "CX8 cancelled call cannot commit a detach" : "CX7 healthy forced detach control",
              cancel ? (!moved && handles.isEmpty) : (moved && handles.count == 1),
              "moved=\(moved), running=\(handles.count), task cancelled=\(task.isCancelled)")
        _ = await SubagentBackgroundRegistry.shared.cancelAllAndQuiesce(timeoutSeconds: 8)
    }

}
