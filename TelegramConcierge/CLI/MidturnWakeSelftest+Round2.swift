import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Release 1b, round 2 rows: known charges survive an unreadable ledger and
/// its accepted replacement (KC), cancellation owns the foreground-to-
/// background handoff until it commits (CC), a lost run's unknown amount
/// covers every period it could have used (IP), and the accepted incidents
/// of a journaled replacement are finalized inside the transaction (JR).
extension MidturnHarness {

    private func dailyCap(_ value: String?) {
        if let value { try? KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey, value: value) }
        else { try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey) }
    }

    private func journalStateR2() -> String? {
        guard let data = try? Data(contentsOf: ToolChargeLedger.journalURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["state"] as? String
    }

    private func allIncidents() -> [SpendIncident] {
        if case .readable(let list) = ToolChargeLedger.loadIncidents() { return list }
        return []
    }

    private func incidentState(_ id: String) -> SpendIncident.State? {
        allIncidents().first { $0.id == id }?.state
    }

    // MARK: KC — known charges survive (Codex 1b R1)

    func knownChargeSurvivalSection() async throws {
        clearModelSpend()
        // KC0 healthy control: capture → ledger + recorded record; the record
        // retires once its completion is settled; counted exactly once.
        _ = await freshManager()
        let healthy = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: healthy, completion: .delivered))
        ToolChargeLedger.capture(jobId: healthy, amountUSD: 0.7, kind: "subagent")
        let counted = ToolChargeLedger.snapshot().today
        try DetachedJobStore.retireSettled()
        check("KC0 healthy control: a recorded charge is counted once and its settled record retires",
              abs(counted - 0.7) < 1e-9 && records().isEmpty && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "counted=\(counted), records=\(records().count)")

        // KC1: undecodable ledger after the record flipped to recorded.
        _ = await freshManager()
        let job = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: job, completion: .delivered))
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, kind: "subagent")
        try Data("{corrupt".utf8).write(to: ToolChargeLedger.ledgerURL)
        let snap = ToolChargeLedger.snapshot()
        check("KC1a undecodable ledger: the recorded record copy still counts ($0.70) and accounting is incomplete",
              abs(snap.today - 0.7) < 1e-9 && !snap.isComplete, "today=\(snap.today), complete=\(snap.isComplete)")
        try DetachedJobStore.retireSettled()
        _ = ToolChargeLedger.settlePending()
        check("KC1b retirement (idle retire and the pending-settlement pass) keeps that record: it is the only known copy",
              records().contains { $0.jobId == job }, "records=\(records().map(\.jobId))")
        let accepted = ToolChargeLedger.acceptOpenIncidents(channel: "test")
        let after = ToolChargeLedger.snapshot()
        check("KC1c accepting the unknown ledger seeds the new generation with the recorded charge: $0.70 kept, complete",
              accepted.failure == nil && ledgerEntries().contains { $0.chargeId == job && abs($0.amountUSD - 0.7) < 1e-9 }
                && abs(after.today - 0.7) < 1e-9 && after.isComplete,
              "failure=\(accepted.failure ?? "nil"), entries=\(ledgerEntries().map(\.chargeId)), today=\(after.today)")
        ToolChargeLedger.forgetHeldForTesting()
        try DetachedJobStore.retireSettled()
        check("KC1d after a restart the charge is still $0.70, and the record retires now that the readable ledger holds it",
              abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9 && !records().contains { $0.jobId == job })

        // Permission-based: root reads a mode-000 file (Linux CI container), so KC2 needs a non-root user.
        if geteuid() != 0 {
            // KC2: permission-unreadable ledger (0000) — same guarantees.
            _ = await freshManager()
            let perm = UUID()
            try DetachedJobStore.create(chargeRecord(jobId: perm, completion: .delivered))
            ToolChargeLedger.capture(jobId: perm, amountUSD: 0.4, kind: "subagent")
            chmod(ToolChargeLedger.ledgerURL.path, 0o000)
            let permSnap = ToolChargeLedger.snapshot()
            try DetachedJobStore.retireSettled()
            check("KC2a permission-unreadable ledger: recorded copy counts ($0.40), record kept",
                  abs(permSnap.today - 0.4) < 1e-9 && records().contains { $0.jobId == perm }, "today=\(permSnap.today)")
            let permAccept = ToolChargeLedger.acceptOpenIncidents(channel: "test")
            chmod(ToolChargeLedger.ledgerURL.path, 0o600)
            let preserved = ((try? FileManager.default.contentsOfDirectory(atPath: ToolChargeLedger.directory.path)) ?? [])
                .filter { $0.hasPrefix("tool-charges.unreadable-") }
            for name in preserved { chmod(ToolChargeLedger.directory.appendingPathComponent(name).path, 0o600) }
            check("KC2b acceptance keeps the known $0.40 in the new generation",
                  permAccept.failure == nil && abs(ToolChargeLedger.snapshot().today - 0.4) < 1e-9
                    && ledgerEntries().contains { $0.chargeId == perm }, "failure=\(permAccept.failure ?? "nil")")
        }

        // KC3: the conflict rule still applies across a recorded record copy
        // and a readable ledger copy (largest amount, counted once).
        _ = await freshManager()
        let conflict = UUID()
        let at = Date()
        try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: conflict, amountUSD: 0.9, providerReturnedAt: at, kind: "subagent"))
        try DetachedJobStore.create(chargeRecord(jobId: conflict, charge: JobCharge(chargeId: conflict, amountUSD: 0.5, providerReturnedAt: at, state: .recorded)))
        check("KC3 a recorded record copy and a disagreeing ledger copy count once, at the larger amount",
              abs(ToolChargeLedger.snapshot().today - 0.9) < 1e-9, "today=\(ToolChargeLedger.snapshot().today)")

        // KC4: Mind import / wipe Stage B with an unreadable ledger keeps the
        // record carrying the recorded charge (nothing owed); with a readable
        // ledger holding it, it is discarded.
        let manager = await freshManager()
        let kept = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: kept, completion: .owed))
        ToolChargeLedger.capture(jobId: kept, amountUSD: 0.25, kind: "subagent")
        try Data("{corrupt".utf8).write(to: ToolChargeLedger.ledgerURL)
        try manager._testResetEarlyWakeState()
        let keptRecord = records().first { $0.jobId == kept }
        check("KC4a history replacement with an unreadable ledger keeps the recorded-charge record (nothing owed)",
              keptRecord?.completion == .notOwed && abs(ToolChargeLedger.snapshot().today - 0.25) < 1e-9,
              "record=\(String(describing: keptRecord?.completion))")
        let manager2 = await freshManager()
        let gone = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: gone, completion: .owed))
        ToolChargeLedger.capture(jobId: gone, amountUSD: 0.25, kind: "subagent")
        try manager2._testResetEarlyWakeState()
        check("KC4b control: with the readable ledger holding the charge, history replacement discards the record",
              !records().contains { $0.jobId == gone } && abs(ToolChargeLedger.snapshot().today - 0.25) < 1e-9)
        try await knownChargeImportWipeRows()
    }

    /// KC5: Mind import Stage A and /deleteuserdata never delete the only
    /// copy of a known charge: with the ledger unreadable they abort; after
    /// the acceptance carries the charge into the new generation they
    /// proceed and the charge stays counted.
    private func knownChargeImportWipeRows() async throws {
        let manager = await freshManager(history: [user("keep me")])
        let job = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: job, completion: .delivered))
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.35, kind: "subagent")
        try Data("{corrupt".utf8).write(to: ToolChargeLedger.ledgerURL)
        let importRefused = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 2)
        check("KC5a Mind import Stage A with an unreadable ledger and a recorded charge only in its record: aborts, record kept",
              importRefused != nil && records().contains { $0.jobId == job }, "refused=\(importRefused ?? "nil")")
        let wipe = await manager.deleteAllMemory()
        check("KC5b /deleteuserdata in the same state aborts before deleting anything (record and history kept)",
              wipe.first?.contains("ABORTED") == true && records().contains { $0.jobId == job }
                && manager._testMessages.contains { $0.content == "keep me" }, "\(wipe.prefix(2))")
        _ = ToolChargeLedger.acceptOpenIncidents(channel: "test")
        let proceeds = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 2)
        check("KC5c control: once the accepted generation holds the charge, Stage A proceeds and $0.35 stays counted",
              proceeds == nil && abs(ToolChargeLedger.snapshot().today - 0.35) < 1e-9, "refused=\(proceeds ?? "nil")")
    }

    // MARK: CC — cancellation owns the detach handoff (Codex 1b R2)

    private enum CancelPoint { case none, beforeRecord, duringRecordWrite, atCommit }

    private struct CancelOutcome {
        var moved = false
        var running = 0
        var liveRuns = 0
        var cancelled = false
        var recordLeft = false
        var createWrites = 0
        var binding: OutcomeBinding?
        var content = ""
    }

    private func runCancelCase(_ point: CancelPoint, dropFails: Bool = false) async throws -> CancelOutcome {
        _ = await freshManager()
        ForceDetach.overrideForTesting = true
        MidturnWakeSignal.forcedDelaySecondsForTesting = 0.2
        defer {
            ForceDetach.overrideForTesting = nil
            MidturnWakeSignal.forcedDelaySecondsForTesting = 0.8
            ToolExecutor.beforeSubagentRecordForTesting = nil
            SubagentBackgroundRegistry.atCommitDetachForTesting = nil
            DetachedJobStore.faultForTesting = nil
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
        let cancelNow: () -> Void = { withUnsafeCurrentTask { $0?.cancel() } }
        final class Counter: @unchecked Sendable { var creates = 0 }
        let counter = Counter()
        switch point {
        case .none: break
        case .beforeRecord: ToolExecutor.beforeSubagentRecordForTesting = cancelNow
        case .duringRecordWrite: break
        case .atCommit: SubagentBackgroundRegistry.atCommitDetachForTesting = cancelNow
        }
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { label in
            if label == "create" {
                counter.creates += 1
                // Cancelled while the durable record is being written (the
                // write itself succeeds).
                if point == .duringRecordWrite { cancelNow() }
            }
            if dropFails && label == "drop-unlaunched" { throw Injected() }
        }
        let args = String(data: try JSONSerialization.data(withJSONObject: Self.agentArgs(description: "cancellation", prompt: "run")), encoding: .utf8)!
        let call = ToolCall(id: "cc-cancel", type: "function", function: FunctionCall(name: "Agent", arguments: args))
        let wake = WakeContext(turnRunId: UUID(), callId: call.id, toolName: "Agent", fingerprint: "test",
                               callStartedAt: .now, historyAnchorMessageId: nil)
        let task = Task.detached {
            await WakeContext.$current.withValue(wake) { await executor.executeAgentToolResult(call) }
        }
        let result = await task.value
        DetachedJobStore.faultForTesting = nil
        var outcome = CancelOutcome()
        outcome.moved = parse(result.content)["status"] as? String == "moved_to_background"
        outcome.running = await SubagentBackgroundRegistry.shared.runningHandles().count
        outcome.liveRuns = await SubagentBackgroundRegistry.shared.stopCutoffHandleIds().count
        outcome.cancelled = task.isCancelled
        outcome.recordLeft = !records().isEmpty
        outcome.createWrites = counter.creates
        outcome.binding = result.outcomeBinding
        outcome.content = result.content
        _ = await SubagentBackgroundRegistry.shared.cancelAllAndQuiesce(timeoutSeconds: 8)
        return outcome
    }

    func detachCancellationSection() async throws {
        let healthy = try await runCancelCase(.none)
        check("CC0 healthy control: a forced wake with no cancellation moves the run (one record, one running run)",
              healthy.moved && healthy.running == 1 && healthy.recordLeft && healthy.createWrites == 1,
              "moved=\(healthy.moved), running=\(healthy.running), writes=\(healthy.createWrites)")

        let before = try await runCancelCase(.beforeRecord)
        check("CC1a cancelled before the record: the call returns the run's own result, not a moved one; nothing keeps running",
              before.cancelled && !before.moved && before.running == 0 && before.liveRuns == 0,
              "moved=\(before.moved), running=\(before.running), live=\(before.liveRuns)")
        check("CC1b cancelled before the record: no crash record is written or left behind",
              before.createWrites == 0 && !before.recordLeft, "writes=\(before.createWrites), left=\(before.recordLeft)")

        let during = try await runCancelCase(.duringRecordWrite)
        check("CC2a cancelled while the record is written: the handoff does not commit; the run is cancelled and awaited",
              during.cancelled && !during.moved && during.running == 0 && during.liveRuns == 0,
              "moved=\(during.moved), running=\(during.running), live=\(during.liveRuns)")
        check("CC2b the record written for the uncommitted handoff is dropped",
              during.createWrites == 1 && !during.recordLeft, "writes=\(during.createWrites), left=\(during.recordLeft)")

        let commit = try await runCancelCase(.atCommit)
        check("CC3a cancelled AT commit (inside the actor step, its handler not yet delivered): not moved, run cancelled and awaited",
              commit.cancelled && !commit.moved && commit.running == 0 && commit.liveRuns == 0,
              "moved=\(commit.moved), running=\(commit.running), live=\(commit.liveRuns)")
        check("CC3b the record of the refused handoff is dropped", !commit.recordLeft)

        let stranded = try await runCancelCase(.atCommit, dropFails: true)
        check("CC4a cancelled at commit with a failing record drop: not moved, nothing running, the record stays",
              !stranded.moved && stranded.running == 0 && stranded.recordLeft,
              "moved=\(stranded.moved), running=\(stranded.running), left=\(stranded.recordLeft)")
        let jobId = records().first?.jobId
        check("CC4b the call's real result is bound to that stranded record (a real outcome settles it after a restart)",
              stranded.binding?.kind == .real && stranded.binding?.jobId == jobId && jobId != nil,
              "binding=\(String(describing: stranded.binding)), record=\(String(describing: jobId))")
    }

    // MARK: IP — lost-run incidents span every period (Codex 1b R3)

    private func dayStart(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func incidentSpanSection() async throws {
        let year = Calendar.current.component(.year, from: Date())
        // IP0 control: launched and recovered the same day → that day only.
        _ = await freshManager()
        var same = chargeRecord()
        let sameStart = dayStart(year, 3, 10).addingTimeInterval(3600)
        same.startedAt = sameStart
        try DetachedJobStore.create(same)
        try ToolChargeLedger.registerUnknownSpend(same, recoveredAt: sameStart.addingTimeInterval(1800))
        let stored0 = allIncidents().first
        check("IP0 control: launch and recovery on the same day → one day, no span; the next month is complete",
              stored0?.periods == [ToolChargeLedger.dayKey(sameStart)] && stored0?.throughDay == nil
                && ToolChargeLedger.snapshot(referenceDate: dayStart(year, 4, 2)).isComplete
                && !ToolChargeLedger.snapshot(referenceDate: sameStart).isComplete,
              "stored=\(String(describing: stored0))")

        // IP1: month boundary, recovered 30 s after it.
        _ = await freshManager()
        var month = chargeRecord()
        let boundary = dayStart(year, 6, 1)
        month.startedAt = boundary.addingTimeInterval(-30)
        try DetachedJobStore.create(month)
        try ToolChargeLedger.registerUnknownSpend(month, recoveredAt: boundary.addingTimeInterval(30))
        let stored1 = allIncidents().first
        check("IP1a a lost run crossing a month boundary is stored from its launch day through its recovery day",
              stored1?.periods == [ToolChargeLedger.dayKey(month.startedAt)]
                && stored1?.throughDay == ToolChargeLedger.dayKey(boundary.addingTimeInterval(30)),
              "stored=\(String(describing: stored1))")
        check("IP1b it keeps BOTH months incomplete (the new month's first day and a later day of it), not a later month",
              !ToolChargeLedger.snapshot(referenceDate: boundary.addingTimeInterval(30)).isComplete
                && !ToolChargeLedger.snapshot(referenceDate: dayStart(year, 6, 20)).isComplete
                && !ToolChargeLedger.snapshot(referenceDate: dayStart(year, 5, 12)).isComplete
                && ToolChargeLedger.snapshot(referenceDate: dayStart(year, 7, 3)).isComplete)

        // IP2: year boundary.
        _ = await freshManager()
        var newYear = chargeRecord()
        let yearStart = dayStart(year + 1, 1, 1)
        newYear.startedAt = yearStart.addingTimeInterval(-30)
        try DetachedJobStore.create(newYear)
        try ToolChargeLedger.registerUnknownSpend(newYear, recoveredAt: yearStart.addingTimeInterval(30))
        check("IP2 a lost run crossing a year boundary keeps the new year's January incomplete (and December), not February",
              !ToolChargeLedger.snapshot(referenceDate: dayStart(year + 1, 1, 15)).isComplete
                && !ToolChargeLedger.snapshot(referenceDate: dayStart(year, 12, 5)).isComplete
                && ToolChargeLedger.snapshot(referenceDate: dayStart(year + 1, 2, 1)).isComplete,
              "stored=\(String(describing: allIncidents().first))")

        // IP3: a multi-day unknown end (recovered days later) covers every day.
        _ = await freshManager()
        var long = chargeRecord()
        long.startedAt = dayStart(year, 8, 3).addingTimeInterval(7200)
        try DetachedJobStore.create(long)
        try ToolChargeLedger.registerUnknownSpend(long, recoveredAt: dayStart(year, 8, 6).addingTimeInterval(60))
        check("IP3 recovery days later: every day between launch and recovery is covered, the day after is not",
              !ToolChargeLedger.snapshot(referenceDate: dayStart(year, 8, 5).addingTimeInterval(3600)).isComplete
                && !ToolChargeLedger.snapshot(referenceDate: dayStart(year, 8, 6).addingTimeInterval(3600)).isComplete
                && ToolChargeLedger.snapshot(referenceDate: dayStart(year, 9, 7)).isComplete)

        // IP4: memory-only (finished; charge only in memory) spans launch →
        // settlement, not launch alone.
        _ = await freshManager()
        var memory = chargeRecord(body: "done")
        memory.startedAt = dayStart(year, 10, 1).addingTimeInterval(-60)
        memory.settledAt = dayStart(year, 10, 1).addingTimeInterval(120)
        try DetachedJobStore.create(memory)
        try ToolChargeLedger.registerUnknownSpend(memory, recoveredAt: dayStart(year, 11, 20))
        let stored4 = allIncidents().first
        check("IP4 a finished run whose charge was only in memory spans launch → its settlement (month boundary), not recovery",
              stored4?.kind == .memoryOnly && stored4?.throughDay == ToolChargeLedger.dayKey(memory.settledAt!)
                && !ToolChargeLedger.snapshot(referenceDate: dayStart(year, 10, 9)).isComplete
                && ToolChargeLedger.snapshot(referenceDate: dayStart(year, 11, 20)).isComplete,
              "stored=\(String(describing: stored4))")

        // IP5: a configured cap stays unverifiable in the new month until
        // that specific incident is accepted.
        let manager = await freshManager()
        clearModelSpend()
        dailyCap("10")
        defer { dailyCap(nil) }
        var capped = chargeRecord()
        let now = Date()
        let thisMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now))!
        capped.startedAt = thisMonth.addingTimeInterval(-30)
        try DetachedJobStore.create(capped)
        try ToolChargeLedger.registerUnknownSpend(capped, recoveredAt: now)
        let paused = SpendGate.pauseReason() ?? ""
        check("IP5a with a daily cap, a lost run launched last month keeps today's cap unverifiable (paused, incident named)",
              paused.contains("can't verify") && paused.contains(String(capped.jobId.uuidString.lowercased().prefix(8))), paused)
        let reply = (await manager.handleTerminalCommand("/spend accept-unknown") ?? []).joined(separator: "\n")
        check("IP5b accepting that incident unpauses", SpendGate.pauseReason() == nil && reply.contains("Accepted"), reply)
    }

    // MARK: JR — acceptance finalization inside the transaction (Codex 1b R4)

    /// A current unknown-amount incident plus an unreadable-ledger episode.
    private func openJobAndLedgerIncidents() async throws -> (job: String, ledger: String) {
        _ = await freshManager()
        let job = UUID()
        try ToolChargeLedger.openUnknownAmount(jobId: job, day: Date(), detail: "jr")
        try Data("{corrupt".utf8).write(to: ToolChargeLedger.ledgerURL)
        _ = ToolChargeLedger.snapshot()
        let ledger = allIncidents().first { $0.kind == .ledgerUnreadable && $0.state == .open }?.id ?? ""
        return ("unknown-amount:" + job.uuidString.lowercased(), ledger)
    }

    func acceptanceFinalizationSection() async throws {
        struct Injected: Error {}
        // JR0 healthy control.
        let healthy = try await openJobAndLedgerIncidents()
        let ok = ToolChargeLedger.acceptOpenIncidents(channel: "test")
        check("JR0 healthy control: both the job and the ledger incident are accepted, the journal commits, complete",
              ok.failure == nil && incidentState(healthy.job) == .accepted && incidentState(healthy.ledger) == .accepted
                && journalStateR2() == "committed" && ToolChargeLedger.snapshot().isComplete)

        // JR1: failure DURING the incident finalization.
        let during = try await openJobAndLedgerIncidents()
        ToolChargeLedger.faultForTesting = { if $0 == "incident-accept" { throw Injected() } }
        let failed = ToolChargeLedger.acceptOpenIncidents(channel: "test")
        ToolChargeLedger.faultForTesting = nil
        check("JR1a the reply says the acceptance is saved and completes automatically",
              failed.failure?.contains("completes automatically") == true, failed.failure ?? "nil")
        check("JR1b the journal is not committed while its acceptances are not durable",
              journalStateR2() == "begun", "journal=\(journalStateR2() ?? "nil")")
        ToolChargeLedger.forgetHeldForTesting()
        let restarted = ToolChargeLedger.snapshot()
        check("JR1c after a restart the roll-forward accepts exactly the captured job AND ledger incidents, then commits",
              restarted.isComplete && incidentState(during.job) == .accepted && incidentState(during.ledger) == .accepted
                && journalStateR2() == "committed",
              "job=\(String(describing: incidentState(during.job))), ledger=\(String(describing: incidentState(during.ledger))), journal=\(journalStateR2() ?? "nil")")

        // JR2: crash after finalization, before the commit.
        let crash = try await openJobAndLedgerIncidents()
        ToolChargeLedger.faultForTesting = { if $0 == "journal-commit" { throw Injected() } }
        _ = ToolChargeLedger.acceptOpenIncidents(channel: "test")
        ToolChargeLedger.faultForTesting = nil
        let midState = journalStateR2()
        let later = UUID()
        try ToolChargeLedger.openUnknownAmount(jobId: later, day: Date(), detail: "later")
        ToolChargeLedger.forgetHeldForTesting()
        let rolled = ToolChargeLedger.snapshot()
        let laterId = "unknown-amount:" + later.uuidString.lowercased()
        check("JR2a a crash between finalization and commit: the next roll-forward commits; the captured ids stay accepted",
              midState == "begun" && journalStateR2() == "committed" && incidentState(crash.job) == .accepted
                && incidentState(crash.ledger) == .accepted, "mid=\(midState ?? "nil")")
        check("JR2b a later incident is not in the journal and stays open (accounting incomplete)",
              incidentState(laterId) == .open && !rolled.isComplete && rolled.incidents.map(\.id) == [laterId],
              "incidents=\(rolled.incidents.map(\.id))")

        // JR3: a journal already COMMITTED with its acceptances not applied
        // (the old commit-then-best-effort order): replayed exactly.
        _ = await freshManager()
        let owed = UUID(), outside = UUID()
        try ToolChargeLedger.openUnknownAmount(jobId: owed, day: Date(), detail: "owed")
        try ToolChargeLedger.openUnknownAmount(jobId: outside, day: Date(), detail: "outside")
        let owedId = "unknown-amount:" + owed.uuidString.lowercased()
        let outsideId = "unknown-amount:" + outside.uuidString.lowercased()
        let journal: [String: Any] = ["version": 1, "state": "committed", "episodeIncidentId": "ledger-unreadable:x",
                                      "preservedName": "tool-charges.unreadable-x.json", "newGeneration": 2,
                                      "acceptedIncidentIds": [owedId], "at": Date().timeIntervalSince1970]
        try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: UUID(), amountUSD: 0.2, providerReturnedAt: Date(), kind: "subagent"))
        try PrivateStorage.writeAtomically(try JSONSerialization.data(withJSONObject: journal), to: ToolChargeLedger.journalURL)
        let replay = ToolChargeLedger.snapshot()
        check("JR3 a committed journal with unapplied acceptances is replayed: its id accepted, an id outside it stays open",
              incidentState(owedId) == .accepted && incidentState(outsideId) == .open && replay.incidents.map(\.id) == [outsideId],
              "owed=\(String(describing: incidentState(owedId))), outside=\(String(describing: incidentState(outsideId)))")

        // Permission-based: needs a non-root user (see KC2).
        if geteuid() != 0 {
            // JR4: the incident registry unreadable at finalization → the
            // snapshot is incomplete and nothing is lost; repair → completes.
            let unreadable = try await openJobAndLedgerIncidents()
            ToolChargeLedger.faultForTesting = { if $0 == "incident-accept" { throw Injected() } }
            _ = ToolChargeLedger.acceptOpenIncidents(channel: "test")
            ToolChargeLedger.faultForTesting = nil
            let saved = try Data(contentsOf: ToolChargeLedger.incidentsURL)
            chmod(ToolChargeLedger.incidentsURL.path, 0o000)
            let blocked = ToolChargeLedger.snapshot()
            let blockedJournal = journalStateR2()
            chmod(ToolChargeLedger.incidentsURL.path, 0o600)
            let bytesKept = (try? Data(contentsOf: ToolChargeLedger.incidentsURL)) == saved
            let repaired = ToolChargeLedger.snapshot()
            check("JR4 registry unreadable while finalizing: incomplete, journal still begun, registry untouched; repaired → accepted",
                  !blocked.isComplete && blockedJournal == "begun" && bytesKept && repaired.isComplete && incidentState(unreadable.job) == .accepted
                    && journalStateR2() == "committed", "blocked=\(blocked.unidentified)")
        }
    }
}
