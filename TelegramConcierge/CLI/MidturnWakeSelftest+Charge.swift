import Foundation

/// Release 1b rows: the idempotent charge ledger (plan v7 §3.6.3) — detached
/// and background subagent spend counted exactly once across completion
/// retries, storage failures and restarts; union totals and the single
/// conflict rule; fresh-snapshot enforcement; the Mind import / wipe
/// prerequisite (§3.6.4).
extension MidturnHarness {

    /// A foreign (previous-process) subagent record for charge rows.
    func chargeRecord(jobId: UUID = UUID(), charge: JobCharge? = nil, completion: DetachedJobRecord.CompletionState = .owed,
                      instance: UUID = UUID(), body: String? = nil) -> DetachedJobRecord {
        var record = DetachedJobRecord(jobId: jobId, instanceId: instance, turnRunId: nil, toolCallId: nil,
                                       callFingerprint: nil, handle: "subagent_c", command: "charge row", description: nil,
                                       workdir: nil, startedAt: Date(), launch: .background, completionMessageId: UUID())
        record.kind = DetachedJobRecord.subagentKind
        record.providerCalled = true
        record.charge = charge
        record.completion = completion
        record.completionBody = body
        return record
    }

    func chargeSection() async throws {
        clearModelSpend()
        try await chargeCompletionSaveRetries()
        try await chargeLedgerWriteFails()
        try await chargeRecordWriteFailsHeldInMemory()
        try await chargeRecordOnlyFails()
        try await chargeHeldBlocksRetirement()
        await chargeUnionAndConflictRows()
        try await chargeCrossesCapDuringTurn()
        try await chargeUnverifiablePausesTurn()
    }

    /// C1: repeated history-save failures while delivering a subagent
    /// completion: retried, never re-charged; delivered once after recovery.
    private func chargeCompletionSaveRetries() async throws {
        let manager = await freshManager()
        clearModelSpend()
        let sub = SubagentScript()
        sub.general(Self.costedText("report C1", cost: 0.05), delay: 0.3, cost: 0.05)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-c1", name: "Agent", args: Self.agentArgs(description: "bg", prompt: "Bg C1", background: true))]),
            Self.chatText("launched"),
            Self.chatText("handled C1"),
        ])
        manager._testStartTurn(for: user("c1"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let jobId = results(manager).first { $0.toolCallId == "call-c1" }?.outcomeBinding?.jobId
        _ = await waitForCompletionQueued()
        let url = StoragePaths.dataRoot.appendingPathComponent("conversation.json")
        let saved = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        for _ in 0..<3 { await manager._testSubagentDrainOnly() }
        let queuedDuringFailure = await SubagentBackgroundRegistry.shared._testPendingCompletionsCount()
        let inMemory = manager._testMessages.filter { $0.kind == .subagentComplete }.count
        try FileManager.default.removeItem(at: url)
        try saved.write(to: url)
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 20)
        await manager._testSubagentDrainOnly()
        let delivered = manager._testMessages.filter { $0.kind == .subagentComplete && $0.content.contains("report C1") }
        check("C1a three failed completion saves: completion kept queued, one in-memory copy (never a second)",
              queuedDuringFailure == 1 && inMemory == 1, "queued \(queuedDuringFailure), copies \(inMemory)")
        check("C1b after recovery: delivered once; exactly one charge (ledger) and none in the model ledger",
              delivered.count == 1 && ledgerEntries().filter { $0.chargeId == jobId }.count == 1 && modelSpendToday() == 0
                && abs(SpendGate.status().todaySpentUSD - 0.05) < 1e-9 && !records().contains { $0.jobId == jobId },
              "delivered \(delivered.count), ledger \(ledgerEntries().count), model \(modelSpendToday()), total \(SpendGate.status().todaySpentUSD)")
    }

    /// C2: the ledger write fails when the run finishes: the charge stays
    /// pending in the record (counted once by the union), is retried, and
    /// the record retires only once recorded.
    private func chargeLedgerWriteFails() async throws {
        let manager = await freshManager()
        struct Injected: Error {}
        ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw Injected() } }
        let sub = SubagentScript()
        sub.general(Self.costedText("report C2", cost: 0.07), delay: 0.3, cost: 0.07)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-c2", name: "Agent", args: Self.agentArgs(description: "bg", prompt: "Bg C2", background: true))]),
            Self.chatText("launched"),
            Self.chatText("handled C2"),
        ])
        manager._testStartTurn(for: user("c2"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let jobId = results(manager).first { $0.toolCallId == "call-c2" }?.outcomeBinding?.jobId
        _ = await waitForCompletionQueued()
        let pending = records().first { $0.jobId == jobId }?.charge
        let unionTotal = SpendGate.status().todaySpentUSD
        let ledgerEmptyWhileFailing = ledgerEntries().isEmpty
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 20)
        let keptWhilePending = records().contains { $0.jobId == jobId }
        ToolChargeLedger.settlePending()   // still failing
        let stillPending = records().first { $0.jobId == jobId }?.charge?.state == .pending
        ToolChargeLedger.faultForTesting = nil
        ToolChargeLedger.settlePending()
        check("C2a ledger write fails: charge pending in the record, counted once by the union",
              pending?.state == .pending && abs(unionTotal - 0.07) < 1e-9 && ledgerEmptyWhileFailing,
              "pending \(String(describing: pending)), union \(unionTotal)")
        check("C2b the delivered record is kept while its charge is pending; retry records it once and retires it",
              keptWhilePending && stillPending && ledgerEntries().filter { $0.chargeId == jobId }.count == 1
                && !records().contains { $0.jobId == jobId } && abs(SpendGate.status().todaySpentUSD - 0.07) < 1e-9)
    }

    /// C3: both stores fail when the run finishes: the charge is held in
    /// memory and counted; the record never retires meanwhile; after a crash
    /// the loss is a memory-only incident.
    private func chargeRecordWriteFailsHeldInMemory() async throws {
        let manager = await freshManager()
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { if $0 == "charge-pending" { throw Injected() } }
        ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw Injected() } }
        defer { ToolChargeLedger.faultForTesting = nil }
        let sub = SubagentScript()
        sub.general(Self.costedText("report C3", cost: 0.09), delay: 0.3, cost: 0.09)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-c3", name: "Agent", args: Self.agentArgs(description: "bg", prompt: "Bg C3", background: true))]),
            Self.chatText("launched"),
            Self.chatText("handled C3"),
        ])
        manager._testStartTurn(for: user("c3"))
        _ = await manager._testAwaitIdle(timeout: 20)
        guard let jobId = results(manager).first(where: { $0.toolCallId == "call-c3" })?.outcomeBinding?.jobId else {
            DetachedJobStore.faultForTesting = nil
            check("C3 background launched", false); return
        }
        _ = await waitForCompletionQueued()
        let held = ToolChargeLedger.isHeldInMemory(jobId)
        let counted = abs(SpendGate.status().todaySpentUSD - 0.09) < 1e-9
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 20)
        check("C3a record write fails: charge held in memory, counted, and the delivered record does not retire",
              held && counted && records().first { $0.jobId == jobId }?.completion == .delivered,
              "held \(held), counted \(counted) (\(SpendGate.status().todaySpentUSD)), record \(String(describing: records().first { $0.jobId == jobId }?.completion))")
        DetachedJobStore.faultForTesting = nil
        ToolChargeLedger.faultForTesting = nil
        // Crash before the idle retry: the memory copy is lost.
        let restarted = await restartKillingSubagents()
        restarted._testStartupPasses()
        let incident = openIncidents().first { $0.id == "memory-only:\(jobId.uuidString.lowercased())" }
        check("C3b after a crash the lost charge is a memory-only spend incident; the record then retires",
              incident != nil && !records().contains { $0.jobId == jobId },
              "incidents \(openIncidents().map(\.id)), records \(records().map(\.jobId))")
    }

    /// C3c: only the record write fails: the ledger takes the charge; the
    /// idle retry writes it into the record; a crash before that still
    /// yields the known amount (from the ledger), never an incident.
    private func chargeRecordOnlyFails() async throws {
        let manager = await freshManager()
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { if $0 == "charge-pending" { throw Injected() } }
        let sub = SubagentScript()
        sub.general(Self.costedText("report C3c", cost: 0.06), delay: 0.3, cost: 0.06)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-c3c", name: "Agent", args: Self.agentArgs(description: "bg", prompt: "Bg C3c", background: true))]),
            Self.chatText("launched"),
            Self.chatText("handled C3c"),
        ])
        manager._testStartTurn(for: user("c3c"))
        _ = await manager._testAwaitIdle(timeout: 20)
        guard let jobId = results(manager).first(where: { $0.toolCallId == "call-c3c" })?.outcomeBinding?.jobId else {
            DetachedJobStore.faultForTesting = nil
            check("C3c background launched", false); return
        }
        _ = await waitForCompletionQueued()
        DetachedJobStore.faultForTesting = nil
        let inLedger = ledgerEntries().filter { $0.chargeId == jobId }.count == 1
        server.clear(); server.script([Self.chatText("handled the recovered report")])
        let restarted = await restartKillingSubagents()
        restarted._testStartupPasses()
        _ = await restarted._testAwaitIdle(timeout: 20)
        restarted._testSettleToolCharges()
        // The recovered report is delivered; the record learns its charge
        // from the ledger and then retires (no incident).
        check("C3c record write fails, ledger takes it: after a crash the known amount is kept (no incident), counted once",
              inLedger && openIncidents().isEmpty && abs(ToolChargeLedger.snapshot().today - 0.06) < 1e-9
                && !records().contains { $0.jobId == jobId },
              "inLedger \(inLedger), incidents \(openIncidents().map(\.id)), total \(ToolChargeLedger.snapshot().today)")
    }

    /// C3d: a charge held only in memory keeps its record from retiring even
    /// for a job kind with no provider marker (the guard for future kinds;
    /// subagent records are also kept by the unknown-spend rule).
    private func chargeHeldBlocksRetirement() async throws {
        _ = await freshManager()
        let job = UUID()
        var record = chargeRecord(jobId: job, completion: .delivered)
        record.providerCalled = nil
        record.kind = "image"
        try DetachedJobStore.create(record)
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { if $0 == "charge-pending" { throw Injected() } }
        ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw Injected() } }
        let durable = ToolChargeLedger.capture(jobId: job, amountUSD: 0.08, kind: "image")
        DetachedJobStore.faultForTesting = nil
        ToolChargeLedger.faultForTesting = nil
        try DetachedJobStore.retireSettled()
        let kept = records().contains { $0.jobId == job }
        ToolChargeLedger.settlePending()
        ToolChargeLedger.settlePending()
        check("C3d a memory-held charge blocks retirement; the idle retry records it, then the record retires",
              !durable && kept && ledgerEntries().contains { $0.chargeId == job } && !records().contains { $0.jobId == job },
              "durable \(durable), kept \(kept), ledger \(ledgerEntries().count), records \(records().count)")
    }

    /// C4/C5: union by chargeId and the single conservative conflict rule.
    private func chargeUnionAndConflictRows() async {
        await resetState()
        let day = 86_400.0
        let now = Date()
        let yesterday = now.addingTimeInterval(-day)
        // C5: crash after the ledger write, before the record flip — the
        // same charge in the ledger AND pending in the record counts once.
        let j1 = UUID()
        try? DetachedJobStore.create(chargeRecord(jobId: j1, charge: JobCharge(chargeId: j1, amountUSD: 0.04, providerReturnedAt: now, state: .pending),
                                                  completion: .delivered))
        try? ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: j1, amountUSD: 0.04, providerReturnedAt: now, kind: "subagent"))
        let once = ToolChargeLedger.snapshot(referenceDate: now).today
        ToolChargeLedger.settlePending()
        check("C5 crash after ledger write before record flip: counted once; the retry flips and retires the record",
              abs(once - 0.04) < 1e-9 && !records().contains { $0.jobId == j1 } && ledgerEntries().count == 1)
        // C4: two copies disagree in amount AND day → the larger amount is
        // counted in BOTH days (can only raise a period's total).
        let j2 = UUID()
        try? ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: j2, amountUSD: 0.01, providerReturnedAt: now, kind: "subagent"))
        try? DetachedJobStore.create(chargeRecord(jobId: j2, charge: JobCharge(chargeId: j2, amountUSD: 0.03, providerReturnedAt: yesterday, state: .pending)))
        let today = ToolChargeLedger.snapshot(referenceDate: now).today
        let dayBefore = ToolChargeLedger.snapshot(referenceDate: yesterday).today
        check("C4 conflicting copies: the larger amount counted in every day either timestamp falls in",
              abs(today - (0.04 + 0.03)) < 1e-9 && abs(dayBefore - 0.03) < 1e-9, "today \(today), yesterday \(dayBefore)")
        ToolChargeLedger.settlePending()
        if case .readable(_, _, let conflicts) = ToolChargeLedger.loadLedger() {
            check("C4b the disagreeing copy is kept as a conflict (entry never rewritten)",
                  conflicts.contains { $0.chargeId == j2 && $0.amountUSD == 0.03 }
                    && ledgerEntries().first { $0.chargeId == j2 }?.amountUSD == 0.01)
        } else { check("C4b ledger readable", false) }
        // Idempotent record: an identical second write is a no-op.
        let before = try? Data(contentsOf: ToolChargeLedger.ledgerURL)
        try? ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: j1, amountUSD: 0.04, providerReturnedAt: now, kind: "subagent"))
        check("C6 an identical charge written again changes nothing (idempotent by chargeId)",
              before == (try? Data(contentsOf: ToolChargeLedger.ledgerURL)))
    }

    /// C7: a charge recorded by a background job DURING a turn is seen by the
    /// next enforcement point (fresh snapshot, not turn-start locals).
    private func chargeCrossesCapDuringTurn() async throws {
        let manager = await freshManager()
        clearModelSpend()
        try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey, value: "0.05")
        defer { try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey) }
        server.script([
            Self.chatTools([(id: "call-c7", name: "bash", args: ["command": "sleep 0.8; echo c7", "wait_seconds": 10])]),
            Self.chatText("must not be requested"),
        ])
        manager._testStartTurn(for: user("c7"))
        guard await waitForRunningJob(timeout: 5) != nil else { check("C7 job started", false); return }
        try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: UUID(), amountUSD: 0.10, providerReturnedAt: Date(), kind: "subagent"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let final = manager._testMessages.last { $0.role == .assistant }?.content ?? ""
        check("C7 a background charge crossing the daily cap mid-turn pauses at the next enforcement point",
              final.contains("daily spend limit was reached") && mainRequestBodies().count == 1,
              "final \(final.prefix(120)), requests \(mainRequestBodies().count)")
    }

    /// C8: a configured cap plus an open unknown-spend incident: the turn
    /// pauses before any paid request, with the "can't verify" text.
    private func chargeUnverifiablePausesTurn() async throws {
        let manager = await freshManager()
        clearModelSpend()
        try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey, value: "10")
        defer { try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey) }
        try ToolChargeLedger.openUnknownAmount(jobId: UUID(), day: Date(), detail: "c8")
        server.script([Self.chatText("must not be requested")])
        manager._testStartTurn(for: user("c8"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let final = manager._testMessages.last { $0.role == .assistant }?.content ?? ""
        check("C8 cap + open incident: paid work paused with the can't-verify text, no provider request",
              final.contains("can't verify today's spend") && final.contains("/spend accept-unknown") && mainRequestBodies().isEmpty,
              "final \(final.prefix(160)), requests \(mainRequestBodies().count)")
        try KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey)
        let noCap = SpendGate.pauseReason()
        check("C8b without a configured cap an open incident only reports (never pauses)", noCap == nil)
    }

    // MARK: Barriers (§3.6.4)

    func chargeBarrierSection() async throws {
        try await importPrerequisiteAborts()
        try await replacementKeepsChargeEvidence()
        try await wipePrerequisiteAborts()
    }

    /// B1: Mind import Stage A settles every pending charge; a failure
    /// aborts before anything is replaced, keeping the charge pending.
    private func importPrerequisiteAborts() async throws {
        let manager = await freshManager()
        let job = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: job, charge: JobCharge(chargeId: job, amountUSD: 0.2, providerReturnedAt: Date(), state: .pending),
                                                 completion: .delivered))
        struct Injected: Error {}
        ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw Injected() } }
        let refused = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 2)
        let stillPending = records().first { $0.jobId == job }?.charge?.state == .pending
        ToolChargeLedger.faultForTesting = nil
        check("B1a import Stage A: a pending charge that cannot be recorded aborts the import; the charge stays pending",
              refused?.contains("pending spend") == true && stillPending, "refused: \(refused ?? "nil")")
        let accepted = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 2)
        check("B1b healthy ledger: Stage A records the charge and lets the import proceed",
              accepted == nil && ledgerEntries().contains { $0.chargeId == job } && !records().contains { $0.jobId == job })
    }

    /// B2: Stage B never discards the only evidence of a charge (belt and
    /// braces): records still carrying a pending charge survive the reset
    /// with nothing owed; others are discarded.
    private func replacementKeepsChargeEvidence() async throws {
        let manager = await freshManager()
        let pending = UUID(), settled = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: pending, charge: JobCharge(chargeId: pending, amountUSD: 0.3, providerReturnedAt: Date(), state: .pending)))
        let settledAt = Date()
        // Genuinely settled: the readable ledger holds the recorded charge
        // (a recorded copy the ledger lacks is still known evidence).
        try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: settled, amountUSD: 0.1, providerReturnedAt: settledAt, kind: "subagent"))
        try DetachedJobStore.create(chargeRecord(jobId: settled, charge: JobCharge(chargeId: settled, amountUSD: 0.1, providerReturnedAt: settledAt, state: .recorded)))
        try manager._testResetEarlyWakeState()
        let left = records()
        check("B2 history replacement keeps a record whose charge is pending (nothing owed), discards the rest",
              left.count == 1 && left.first?.jobId == pending && left.first?.completion == .notOwed
                && abs(ToolChargeLedger.snapshot().today - 0.4) < 1e-9)
    }

    /// B3: /deleteuserdata keeps spend totals, so it settles pending charges
    /// before deleting the records — or aborts with nothing deleted.
    private func wipePrerequisiteAborts() async throws {
        let manager = await freshManager(history: [user("keep me")])
        let job = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: job, charge: JobCharge(chargeId: job, amountUSD: 0.25, providerReturnedAt: Date(), state: .pending),
                                                 completion: .delivered))
        struct Injected: Error {}
        ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw Injected() } }
        let report = await manager.deleteAllMemory()
        ToolChargeLedger.faultForTesting = nil
        check("B3 /deleteuserdata with an unrecordable pending charge aborts before deleting anything",
              report.first?.contains("ABORTED: pending spend") == true && records().contains { $0.jobId == job }
                && manager._testMessages.contains { $0.content == "keep me" },
              "\(report.prefix(2))")
    }
}
