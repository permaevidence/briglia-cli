import Foundation

extension MidturnHarness {
    func repro1b2Section() async throws {
        // Same supported conflict state as KC3, reverse the amounts and settle.
        _ = await freshManager()
        let job = UUID(), at = Date()
        try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: job, amountUSD: 0.2, providerReturnedAt: at, kind: "subagent"))
        try DetachedJobStore.create(chargeRecord(jobId: job, charge: JobCharge(chargeId: job, amountUSD: 0.7, providerReturnedAt: at, state: .recorded), completion: .delivered))
        let before = ToolChargeLedger.snapshot().today
        check("NX0 conflict lower bound control", abs(before - 0.7) < 1e-9)
        try DetachedJobStore.retireSettled()
        let after = ToolChargeLedger.snapshot().today
        check("NX1 retirement preserves the larger known charge", abs(after - 0.7) < 1e-9,
              "before=\(before), after=\(after), records=\(records().count)")

        // Even equal amounts must preserve all represented billing periods.
        _ = await freshManager()
        let periodJob = UUID()
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year,.month], from: at))!
        let lastMonth = monthStart.addingTimeInterval(-60)
        try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: periodJob, amountUSD: 0.7, providerReturnedAt: lastMonth, kind: "subagent"))
        try DetachedJobStore.create(chargeRecord(jobId: periodJob, charge: JobCharge(chargeId: periodJob, amountUSD: 0.7, providerReturnedAt: at, state: .recorded), completion: .delivered))
        let periodBefore = ToolChargeLedger.snapshot().month
        try DetachedJobStore.retireSettled()
        let periodAfter = ToolChargeLedger.snapshot().month
        check("NX2 retirement preserves the current billing period", abs(periodAfter - 0.7) < 1e-9,
              "before=\(periodBefore), after=\(periodAfter), records=\(records().count)")

        let manager = await freshManager()
        let importJob = UUID()
        try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: importJob, amountUSD: 0.2, providerReturnedAt: at, kind: "subagent"))
        try DetachedJobStore.create(chargeRecord(jobId: importJob, charge: JobCharge(chargeId: importJob, amountUSD: 0.7, providerReturnedAt: at, state: .recorded), completion: .delivered))
        let refusal = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 2)
        if refusal == nil { try manager._testResetEarlyWakeState() }
        check("NX3 import either refuses or durably preserves the larger charge", abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "refusal=\(refusal ?? "nil"), after=\(ToolChargeLedger.snapshot().today)")
        // Acceptance must preserve every known conflicting copy, including memory-held.
        _ = await freshManager()
        let heldJob = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: heldJob, completion: .delivered))
        ToolChargeLedger.capture(jobId: heldJob, amountUSD: 0.2, at: at, kind: "subagent")
        try Data("{corrupt".utf8).write(to: ToolChargeLedger.ledgerURL)
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { if $0 == "charge-pending" { throw Injected() } }
        ToolChargeLedger.capture(jobId: heldJob, amountUSD: 0.7, at: at, kind: "subagent")
        DetachedJobStore.faultForTesting = nil
        let heldBefore = ToolChargeLedger.snapshot().today
        let acceptance = ToolChargeLedger.acceptOpenIncidents(channel: "test")
        ToolChargeLedger.settlePending()
        try DetachedJobStore.retireSettled()
        let heldAfter = ToolChargeLedger.snapshot().today
        check("NX6 acceptance and settlement preserve the larger memory-held conflict",
              acceptance.failure == nil && abs(heldAfter - 0.7) < 1e-9,
              "before=\(heldBefore), after=\(heldAfter), failure=\(acceptance.failure ?? "nil"), held=\(ToolChargeLedger.isHeldInMemory(heldJob))")
        try await repro1b2BackgroundCancelCase(cancel: false)
        try await repro1b2BackgroundCancelCase(cancel: true)
    }
    func repro1b2BackgroundCancelCase(cancel: Bool) async throws {
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
        let args = String(data: try JSONSerialization.data(withJSONObject: Self.agentArgs(description: "cancellation", prompt: "run", background: true)), encoding: .utf8)!
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
        let moved = parse(result.content)["background"] as? Bool == true
        check(cancel ? "NX5 cancelled call cannot launch an explicit background run" : "NX4 healthy explicit background control",
              cancel ? (!moved && handles.isEmpty) : (moved && handles.count == 1),
              "moved=\(moved), running=\(handles.count), task cancelled=\(task.isCancelled)")
        _ = await SubagentBackgroundRegistry.shared.cancelAllAndQuiesce(timeoutSeconds: 8)
    }

}
