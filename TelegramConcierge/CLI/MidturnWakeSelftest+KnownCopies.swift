import Foundation

/// Release 1b, round 3 rows. KP: every known copy of a charge (amount AND
/// date) survives retirement, capture retries, memory-held settlement, the
/// accepted replacement generation and Mind import — the ledger keeps a
/// differing copy as a conflict before any record or held copy carrying it
/// is released. BL: an explicit background launch whose calling task is
/// cancelled before the launch commits starts no run and leaves no record.
extension MidturnHarness {

    private struct KPInjected: Error {}

    private func ledgerCopies() -> (entries: [ToolChargeEntry], conflicts: [ToolChargeEntry])? {
        if case .readable(_, let entries, let conflicts) = ToolChargeLedger.loadLedger() { return (entries, conflicts) }
        return nil
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    // MARK: KP — known copies

    func knownCopySection() async throws {
        clearModelSpend()
        let at = Date()
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: at))!
        let lastMonth = monthStart.addingTimeInterval(-60)

        // KP0 control: identical copies deduplicate and retire normally.
        do {
            _ = await freshManager()
            let job = UUID()
            try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: job, amountUSD: 0.5, providerReturnedAt: at, kind: "subagent"))
            try DetachedJobStore.create(chargeRecord(jobId: job, charge: JobCharge(chargeId: job, amountUSD: 0.5, providerReturnedAt: at, state: .recorded), completion: .delivered))
            try DetachedJobStore.retireSettled()
            let copies = ledgerCopies()
            check("KP0 identical copies: record retires, no conflict copy, counted once",
                  records().isEmpty && copies?.entries.count == 1 && copies?.conflicts.isEmpty == true
                    && near(ToolChargeLedger.snapshot().today, 0.5),
                  "records=\(records().count), conflicts=\(copies?.conflicts.count ?? -1), today=\(ToolChargeLedger.snapshot().today)")
        }

        // KP1 a recorded record copy larger than the ledger's: retirement
        // first merges it into the ledger as a conflict copy.
        do {
            _ = await freshManager()
            let job = UUID()
            try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: job, amountUSD: 0.2, providerReturnedAt: at, kind: "subagent"))
            try DetachedJobStore.create(chargeRecord(jobId: job, charge: JobCharge(chargeId: job, amountUSD: 0.7, providerReturnedAt: at, state: .recorded), completion: .delivered))
            try DetachedJobStore.retireSettled()
            let copies = ledgerCopies()
            check("KP1a conflicting record retires after the merge", records().isEmpty, "records=\(records().count)")
            check("KP1b the ledger keeps the record's copy as a conflict",
                  copies?.conflicts.contains { $0.chargeId == job && near($0.amountUSD, 0.7) } == true,
                  "conflicts=\(copies?.conflicts.map(\.amountUSD) ?? [])")
            check("KP1c the larger known amount still counts", near(ToolChargeLedger.snapshot().today, 0.7),
                  "today=\(ToolChargeLedger.snapshot().today)")
        }

        // KP2 the merge write fails: the record stays (it is the only copy
        // of the larger amount); after repair it merges and retires.
        do {
            _ = await freshManager()
            let job = UUID()
            try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: job, amountUSD: 0.2, providerReturnedAt: at, kind: "subagent"))
            try DetachedJobStore.create(chargeRecord(jobId: job, charge: JobCharge(chargeId: job, amountUSD: 0.7, providerReturnedAt: at, state: .recorded), completion: .delivered))
            ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw KPInjected() } }
            try DetachedJobStore.retireSettled()
            ToolChargeLedger.settlePending()
            check("KP2a failed merge: record kept, larger amount counted",
                  records().count == 1 && near(ToolChargeLedger.snapshot().today, 0.7),
                  "records=\(records().count), today=\(ToolChargeLedger.snapshot().today)")
            ToolChargeLedger.faultForTesting = nil
            try DetachedJobStore.retireSettled()
            check("KP2b repaired: merged, retired, still counted",
                  records().isEmpty && near(ToolChargeLedger.snapshot().today, 0.7),
                  "records=\(records().count), today=\(ToolChargeLedger.snapshot().today)")
        }

        // KP3 same amount, different billing period: both periods keep it.
        do {
            _ = await freshManager()
            let job = UUID()
            try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: job, amountUSD: 0.7, providerReturnedAt: lastMonth, kind: "subagent"))
            try DetachedJobStore.create(chargeRecord(jobId: job, charge: JobCharge(chargeId: job, amountUSD: 0.7, providerReturnedAt: at, state: .recorded), completion: .delivered))
            try DetachedJobStore.retireSettled()
            let snap = ToolChargeLedger.snapshot()
            let last = ToolChargeLedger.snapshot(referenceDate: lastMonth)
            check("KP3 date conflict: retired, current day and month and the earlier month all keep it",
                  records().isEmpty && near(snap.today, 0.7) && near(snap.month, 0.7) && near(last.month, 0.7),
                  "records=\(records().count), today=\(snap.today), month=\(snap.month), last=\(last.month)")
        }

        // KP4 a second capture disagreeing with the record's recorded copy,
        // both stores failing for it: held in memory; not released while
        // the ledger cannot take it; released once the ledger holds it.
        do {
            _ = await freshManager()
            let job = UUID()
            try DetachedJobStore.create(chargeRecord(jobId: job, completion: .delivered))
            ToolChargeLedger.capture(jobId: job, amountUSD: 0.2, at: at, kind: "subagent")
            ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw KPInjected() } }
            ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, at: at, kind: "subagent")
            ToolChargeLedger.settlePending()
            check("KP4a differing held copy kept while the ledger can't take it",
                  ToolChargeLedger.isHeldInMemory(job) && near(ToolChargeLedger.snapshot().today, 0.7)
                    && records().first?.charge.map { near($0.amountUSD, 0.2) } == true,
                  "held=\(ToolChargeLedger.isHeldInMemory(job)), today=\(ToolChargeLedger.snapshot().today), record=\(records().first?.charge?.amountUSD ?? -1)")
            ToolChargeLedger.faultForTesting = nil
            ToolChargeLedger.settlePending()
            try DetachedJobStore.retireSettled()
            check("KP4b repaired: ledger keeps it, held copy released, record retired, still counted",
                  !ToolChargeLedger.isHeldInMemory(job) && records().isEmpty && near(ToolChargeLedger.snapshot().today, 0.7),
                  "held=\(ToolChargeLedger.isHeldInMemory(job)), records=\(records().count), today=\(ToolChargeLedger.snapshot().today)")
        }

        // KP5 a capture never overwrites a differing pending copy.
        do {
            _ = await freshManager()
            let job = UUID()
            try DetachedJobStore.create(chargeRecord(jobId: job, charge: JobCharge(chargeId: job, amountUSD: 0.7, providerReturnedAt: at, state: .pending), completion: .delivered))
            ToolChargeLedger.capture(jobId: job, amountUSD: 0.2, at: at, kind: "subagent")
            check("KP5a the record keeps its pending copy", records().first?.charge.map { near($0.amountUSD, 0.7) } == true,
                  "record=\(records().first?.charge?.amountUSD ?? -1)")
            ToolChargeLedger.settlePending()
            try DetachedJobStore.retireSettled()
            check("KP5b both copies reach the ledger; the larger counts after retirement",
                  records().isEmpty && !ToolChargeLedger.isHeldInMemory(job) && near(ToolChargeLedger.snapshot().today, 0.7),
                  "records=\(records().count), today=\(ToolChargeLedger.snapshot().today)")
        }

        // KP6 the accepted replacement generation keeps every differing copy.
        do {
            _ = await freshManager()
            let job = UUID()
            try DetachedJobStore.create(chargeRecord(jobId: job, completion: .delivered))
            ToolChargeLedger.capture(jobId: job, amountUSD: 0.2, at: at, kind: "subagent")
            try Data("{corrupt".utf8).write(to: ToolChargeLedger.ledgerURL)
            DetachedJobStore.faultForTesting = { if $0 == "charge-pending" { throw KPInjected() } }
            ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, at: at, kind: "subagent")
            DetachedJobStore.faultForTesting = nil
            let acceptance = ToolChargeLedger.acceptOpenIncidents(channel: "test")
            let copies = ledgerCopies()
            check("KP6a new generation: record copy as entry, differing held copy as conflict",
                  acceptance.failure == nil && copies?.entries.contains { $0.chargeId == job && near($0.amountUSD, 0.2) } == true
                    && copies?.conflicts.contains { $0.chargeId == job && near($0.amountUSD, 0.7) } == true,
                  "failure=\(acceptance.failure ?? "nil"), entries=\(copies?.entries.map(\.amountUSD) ?? []), conflicts=\(copies?.conflicts.map(\.amountUSD) ?? [])")
            // Control: identical copies seed one entry and no conflict.
            _ = await freshManager()
            let same = UUID()
            try DetachedJobStore.create(chargeRecord(jobId: same, charge: JobCharge(chargeId: same, amountUSD: 0.3, providerReturnedAt: at, state: .recorded), completion: .delivered))
            try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: same, amountUSD: 0.3, providerReturnedAt: at, kind: "subagent"))
            try Data("{corrupt".utf8).write(to: ToolChargeLedger.ledgerURL)
            _ = ToolChargeLedger.acceptOpenIncidents(channel: "test")
            let seeded = ledgerCopies()
            check("KP6b control: identical copies seed one entry, no conflict",
                  seeded?.entries.filter { $0.chargeId == same }.count == 1 && seeded?.conflicts.isEmpty == true,
                  "entries=\(seeded?.entries.count ?? -1), conflicts=\(seeded?.conflicts.count ?? -1)")
        }

        // KP7 Mind import Stage A: a conflicting recorded copy is merged, so
        // the import proceeds and Stage B's reset keeps the amount; when the
        // merge can't be written the import refuses.
        do {
            let manager = await freshManager()
            let job = UUID()
            try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: job, amountUSD: 0.2, providerReturnedAt: at, kind: "subagent"))
            try DetachedJobStore.create(chargeRecord(jobId: job, charge: JobCharge(chargeId: job, amountUSD: 0.7, providerReturnedAt: at, state: .recorded), completion: .delivered))
            let refusal = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 2)
            let merged = ledgerCopies()?.conflicts.contains { $0.chargeId == job && near($0.amountUSD, 0.7) } == true
            check("KP7a Stage A merges the conflicting copy and proceeds", refusal == nil && merged,
                  "refusal=\(refusal ?? "nil"), merged=\(merged)")
            if refusal == nil { try manager._testResetEarlyWakeState() }
            check("KP7b Stage B reset: record gone, larger amount kept",
                  records().isEmpty && near(ToolChargeLedger.snapshot().today, 0.7),
                  "records=\(records().count), today=\(ToolChargeLedger.snapshot().today)")

            let failing = await freshManager()
            let other = UUID()
            try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: other, amountUSD: 0.2, providerReturnedAt: at, kind: "subagent"))
            try DetachedJobStore.create(chargeRecord(jobId: other, charge: JobCharge(chargeId: other, amountUSD: 0.7, providerReturnedAt: at, state: .recorded), completion: .delivered))
            ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw KPInjected() } }
            let refused = await failing.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 2)
            ToolChargeLedger.faultForTesting = nil
            check("KP7c merge can't be written: import refuses, record and amount kept",
                  refused != nil && records().count == 1 && near(ToolChargeLedger.snapshot().today, 0.7),
                  "refusal=\(refused ?? "nil"), records=\(records().count), today=\(ToolChargeLedger.snapshot().today)")
        }
    }

    // MARK: BL — explicit background launch vs caller cancellation

    private enum LaunchCancelPoint { case none, beforeRecord, atAdmission, duringRecordWrite, afterLaunch }

    func launchCancellationSection() async throws {
        try await launchCancelCase(.none, label: "BL0 healthy explicit background launch: moved, running, one record")
        try await launchCancelCase(.beforeRecord, label: "BL1 cancelled before the record: nothing started")
        try await launchCancelCase(.atAdmission, label: "BL2 cancelled at the launch admission: nothing started")
        try await launchCancelCase(.duringRecordWrite, label: "BL3 cancelled while the record was written: nothing started")
        try await launchCancelCase(.afterLaunch, label: "BL4 cancelled after the launch committed: the background job keeps running")
    }

    private func launchCancelCase(_ point: LaunchCancelPoint, label: String) async throws {
        _ = await freshManager()
        ForceDetach.overrideForTesting = true
        MidturnWakeSignal.forcedDelaySecondsForTesting = 0.2
        defer {
            ForceDetach.overrideForTesting = nil
            MidturnWakeSignal.forcedDelaySecondsForTesting = 0.8
            ToolExecutor.beforeSubagentRecordForTesting = nil
            ToolExecutor.afterSubagentRecordWriteForTesting = nil
            ToolExecutor.afterBackgroundLaunchForTesting = nil
            SubagentBackgroundRegistry.atSpawnAdmissionForTesting = nil
            DetachedJobStore.faultForTesting = nil
        }
        let script = SubagentScript()
        script.general(Self.costedText("launch cancellation reply", cost: 0.01), delay: 3, cost: 0.01)
        installSubagentRouter(script)
        let service = OpenRouterService()
        await service.configure(apiKey: apiKey)
        let executor = ToolExecutor()
        await executor.configure(openRouterKey: apiKey, serperKey: "", jinaKey: "")
        await executor.configureOpenRouter(service, imagesDirectory: StoragePaths.dataRoot.appendingPathComponent("images"),
                                           documentsDirectory: StoragePaths.dataRoot.appendingPathComponent("documents"))
        let cancelSelf: () -> Void = { withUnsafeCurrentTask { $0?.cancel() } }
        switch point {
        case .none: break
        case .beforeRecord: ToolExecutor.beforeSubagentRecordForTesting = cancelSelf
        case .atAdmission: SubagentBackgroundRegistry.atSpawnAdmissionForTesting = cancelSelf
        case .duringRecordWrite: ToolExecutor.afterSubagentRecordWriteForTesting = cancelSelf
        case .afterLaunch: ToolExecutor.afterBackgroundLaunchForTesting = cancelSelf
        }
        let writes = LockedCounter()
        DetachedJobStore.faultForTesting = { if $0 == "create" { writes.increment() } }
        let args = String(data: try JSONSerialization.data(withJSONObject: Self.agentArgs(description: "launch cancel", prompt: "run", background: true)), encoding: .utf8)!
        let call = ToolCall(id: "bl-\(UUID().uuidString.prefix(6))", type: "function", function: FunctionCall(name: "Agent", arguments: args))
        let wake = WakeContext(turnRunId: UUID(), callId: call.id, toolName: "Agent", fingerprint: "test",
                               callStartedAt: .now, historyAnchorMessageId: nil)
        let task = Task.detached {
            await WakeContext.$current.withValue(wake) { await executor.executeAgentToolResult(call) }
        }
        let result = await task.value
        let running = await SubagentBackgroundRegistry.shared.runningHandles().count
        let moved = parse(result.content)["background"] as? Bool == true
        let recordCount = records().count
        let ok: Bool
        switch point {
        case .none, .afterLaunch:
            ok = moved && running == 1 && recordCount == 1
        case .beforeRecord, .atAdmission:
            // No crash-record write is even attempted.
            ok = !moved && running == 0 && recordCount == 0 && writes.value == 0
                && result.content.contains("cancelled before the background agent started")
        case .duringRecordWrite:
            ok = !moved && running == 0 && recordCount == 0 && writes.value == 1
                && result.content.contains("cancelled before the background agent started")
        }
        check(label, ok, "moved=\(moved), running=\(running), records=\(recordCount), writes=\(writes.value), cancelled=\(task.isCancelled), result=\(result.content.prefix(120))")
        _ = await SubagentBackgroundRegistry.shared.cancelAllAndQuiesce(timeoutSeconds: 8)
    }
}

/// A thread-safe counter for fault-hook observations.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
