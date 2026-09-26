import Foundation

/// Round-2 durability rows (release 1a review, rows CX*): each reproduces a
/// failure path found in review against the production entry points, with
/// a positive control beside it.
///   CX1 — failed history saves never turn in-memory content into proof
///         (job records, held pre-stop messages);
///   CX2 — snapshot-backed evidence is settled before its root leaves history,
///         and traversal order never hides an owning proof;
///   CX3 — finished-but-undrained background subagents are stopped work;
///   CX4 — no main-agent path returns a running job without its crash record.
extension MidturnHarness {

    func durabilitySection() async throws {
        try await failedSaveRows()
        try await heldMessageRows()
        try await traversalRows()
        try await removalGateRows()
        try await subagentStopRows()
        try await expiryRecordRows()
        try await productionGraceRows()
    }

    // MARK: GW — the production grace window (owner decision: 3 s)

    /// GW1: the shipped defaults (no test override): 3 s grace, and the
    /// forced-detach setting follows the same value. GW2: the real window,
    /// non-sliding — a second message 1.5 s later does not extend it.
    private func productionGraceRows() async throws {
        let savedGrace = TurnWakeCenter.graceSecondsForTesting
        let savedForced = MidturnWakeSignal.forcedDelaySecondsForTesting
        TurnWakeCenter.graceSecondsForTesting = nil
        MidturnWakeSignal.forcedDelaySecondsForTesting = nil
        defer {
            TurnWakeCenter.graceSecondsForTesting = savedGrace
            MidturnWakeSignal.forcedDelaySecondsForTesting = savedForced
        }
        check("GW1 shipped grace is 3 s and force-detach uses the same value",
              TurnWakeCenter.graceSeconds == 3 && MidturnWakeSignal.forcedDelaySeconds == 3,
              "grace \(TurnWakeCenter.graceSeconds), forced \(MidturnWakeSignal.forcedDelaySeconds)")
        let manager = await freshManager()
        server.script([
            Self.chatTools([(id: "gw2", name: "bash", args: ["command": "sleep 12", "wait_seconds": 60])]),
            Self.chatText("answered"),
        ])
        manager._testStartTurn(for: user("long job"))
        guard await waitForRunningJob() != nil else { check("GW2 job started", false); return }
        let t0 = Date()
        await manager._testDispatchUser(user("first message"))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await manager._testDispatchUser(user("second message 1.5 s later"))
        _ = await waitUntil(timeout: 20) { self.server.completeRequests.count >= 2 }
        let elapsed = Date().timeIntervalSince(t0)
        _ = await manager._testAwaitIdle(timeout: 10)
        let payload = parse(results(manager).first { $0.toolCallId == "gw2" }?.content ?? "")
        // Lower bound is the window itself; the upper bound allows load but
        // stays below 4.5 s, the value a window sliding to the second
        // message would produce.
        check("GW2 real 3 s window, non-sliding: moved ≈3 s after the FIRST message",
              payload["moved_to_background"] as? Bool == true && elapsed >= 2.9 && elapsed < 4.4,
              String(format: "%.2fs, %@", elapsed, "\(payload["wake_reason"] ?? "nil")"))
        _ = await manager._testAwaitIdle(timeout: 10)
        _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
    }

    private var historyURL: URL { StoragePaths.dataRoot.appendingPathComponent("conversation.json") }

    /// Replace conversation.json with a directory: every save fails.
    private func breakHistoryStorage() throws {
        try? FileManager.default.removeItem(at: historyURL)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: false)
    }

    private func repairHistoryStorage() {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: historyURL.path, isDirectory: &isDir), isDir.boolValue {
            try? FileManager.default.removeItem(at: historyURL)
        }
    }

    // MARK: CX1 — failed saves (job records)

    private func failedSaveRows() async throws {
        // CX1a/b + CX1d: same-process retry.
        do {
            let manager = await freshManager(history: [user("trigger")])
            let record = Self.record()
            try DetachedJobStore.create(record)
            try breakHistoryStorage()
            manager._testReconcileJobsOnly()
            check("CX1a failed recovery save preserves the record", records().count == 1)
            manager._testReconcileJobsOnly()
            check("CX1b repeated recovery after a failed save preserves the owed record",
                  records().count == 1 && records().first?.completion == .owed, "records \(records().count)")
            check("CX1b' no second in-memory copy of the notice",
                  manager._testMessages.filter { $0.id == record.completionMessageId }.count == 1)
            repairHistoryStorage()
            server.clear(); server.script([Self.chatText("noted")])
            manager._testReconcileJobsOnly()
            let onDisk = (try? JSONDecoder().decode([Message].self, from: Data(contentsOf: historyURL))) ?? []
            check("CX1d storage recovers → same-process retry saves exactly one notice and retires the record",
                  onDisk.filter { $0.id == record.completionMessageId }.count == 1 && records().isEmpty,
                  "on disk \(onDisk.filter { $0.id == record.completionMessageId }.count), records \(records().count)")
            check("CX1d' the recovered notice is still offered as the wake trigger",
                  manager._testRecoveredWakeTrigger?.id == record.completionMessageId)
        }
        // CX1e: real init + startPolling passes while storage fails, then
        // another restart after it recovers → exactly one notice.
        do {
            _ = await freshManager(history: [user("trigger")])
            let record = Self.record()
            try DetachedJobStore.create(record)
            try breakHistoryStorage()
            server.clear(); server.script([])
            let failing = await restart()          // init runs the job pass
            failing._testStartupPasses()           // startPolling runs it again
            _ = await failing._testAwaitIdle(timeout: 5)
            check("CX1e init + startPolling with failing storage keep the record owed",
                  records().count == 1 && records().first?.completion == .owed)
            repairHistoryStorage()
            server.clear(); server.script([Self.chatText("noted")])
            let recovered = await restart()
            recovered._testStartupPasses()
            _ = await recovered._testAwaitIdle(timeout: 10)
            check("CX1f another restart after storage recovery delivers exactly one notice",
                  delivered(recovered, record) == 1 && records().isEmpty,
                  "delivered \(delivered(recovered, record)), records \(records().count)")
        }
    }

    // MARK: CX1 — held pre-stop messages

    private func heldMessageRows() async throws {
        let held = user("held message must survive storage failure")
        let entry = StopEntry(stopId: UUID(), at: Date(), stoppedTurnTriggerId: nil,
                              heldQueueMessageIds: [held.id], heldNoteMessageId: UUID(),
                              affectedJobIds: [], affectedWatchMatchIds: [])
        do {
            let manager = await freshManager()
            manager._testPersistQueue([held])
            try StopMarkerStore.append(entry)
            try breakHistoryStorage()
            server.clear(); server.script([])
            let restarted = await restart()
            restarted._testStartupPasses()
            _ = await restarted._testAwaitIdle(timeout: 5)
            check("CX1c failed startup save keeps held user messages in their durable queue",
                  FileManager.default.fileExists(atPath: restarted._testPendingMidTurnURL.path))
            repairHistoryStorage()
            let again = await restart()
            again._testStartupPasses()
            _ = await again._testAwaitIdle(timeout: 5)
            let history = again._testMessages
            let heldIndex = history.firstIndex { $0.id == held.id }
            let noteIndex = history.firstIndex { $0.id == entry.heldNoteMessageId }
            check("CX1g after storage recovery the held message is durable once, with its note, and not answered",
                  history.filter { $0.id == held.id }.count == 1 && heldIndex != nil && noteIndex != nil
                    && noteIndex! > heldIndex! && history[heldIndex!].content == held.content
                    && server.completeRequests.isEmpty
                    && !FileManager.default.fileExists(atPath: again._testPendingMidTurnURL.path))
        }
        // Control: healthy storage → the queue leaves only after the save.
        do {
            let manager = await freshManager()
            manager._testPersistQueue([held])
            try StopMarkerStore.append(entry)
            server.clear(); server.script([])
            let restarted = await restart()
            restarted._testStartupPasses()
            let onDisk = (try? JSONDecoder().decode([Message].self, from: Data(contentsOf: historyURL))) ?? []
            check("CX1h control: healthy storage → held message saved, queue file removed",
                  onDisk.contains { $0.id == held.id }
                    && !FileManager.default.fileExists(atPath: restarted._testPendingMidTurnURL.path))
        }
    }

    // MARK: CX2 — traversal order

    private func traversalRows() async throws {
        await resetState()
        let record = Self.record()
        let proof = try snapshot(carried: [Self.round(callId: "observed", binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId))])
        let nonOwner = try snapshot(trigger: "mid-turn", prior: compaction(proof))
        var holder = Self.assistant("saved outcome", rounds: [])
        holder.pruneArchiveReferences = [nonOwner]
        holder.activeTurnCompaction = compaction(proof)
        let actual = SettlementEvidence.locate(record, history: [holder])
        check("CX2a a non-owning visit does not mask a later owning proof", actual == .bound(.receiptObserved), "\(actual)")
        let recovered = try await reconcileKeepingSnapshots(history: [holder], records: [record], script: [Self.chatText("duplicate result")])
        check("CX2c restart does not redeliver a result observed through that snapshot", delivered(recovered, record) == 0,
              "duplicate completion count: \(delivered(recovered, record))")
        holder.pruneArchiveReferences = []
        check("CX2b control: owning-only path settles", SettlementEvidence.locate(record, history: [holder]) == .bound(.receiptObserved))
        var nonOwningOnly = Self.assistant("saved outcome", rounds: [])
        nonOwningOnly.pruneArchiveReferences = [nonOwner]
        check("CX2b' control: a carried receipt reached ONLY without ownership still does not settle",
              SettlementEvidence.locate(record, history: [nonOwningOnly]) == .absent)
    }

    // MARK: CX2 — removal gate

    /// Build: an owed record whose receipt lives only in a snapshot reached
    /// from `outcome`; the runtime certificate write fails, so the record is
    /// still owed when removal is attempted.
    private func snapshotOnlyReceipt(_ manager: ConversationManager, kind: OutcomeBinding.Kind = .receiptObserved,
                                     via: String) throws -> (DetachedJobRecord, Message) {
        let record = Self.record(instance: DetachedJobStore.instanceId)
        try DetachedJobStore.create(record)
        var outcome: Message
        switch via {
        case "prune-reference":
            // Ordinary prune snapshot: the receipt round was a durable
            // message's round; the pruned message keeps only the reference.
            let carrier = Self.assistant("carrier", rounds: [Self.round(callId: "observed", binding: OutcomeBinding(kind: kind, jobId: record.jobId))])
            let ref = try snapshot(durable: [carrier], trigger: "prune")
            outcome = Self.assistant("pruned outcome", rounds: [])
            outcome.pruneArchiveReferences = [ref]
        case "interrupted":
            // Interrupted / pending-recovery outcome: compaction snapshot
            // carries the receipt; the saved outcome keeps a placeholder
            // for the same call (proves nothing) plus the compaction link.
            let proof = try snapshot(carried: [Self.round(callId: "observed", binding: OutcomeBinding(kind: kind, jobId: record.jobId))])
            outcome = Self.assistant("interrupted outcome", rounds: [
                Self.round(callId: "observed", binding: OutcomeBinding(kind: .interruptedIntent, jobId: nil))])
            outcome.activeTurnCompaction = compaction(proof)
        default:
            let proof = try snapshot(carried: [Self.round(callId: "observed", binding: OutcomeBinding(kind: kind, jobId: record.jobId))])
            outcome = Self.assistant("receipt compacted into snapshot", rounds: [])
            outcome.activeTurnCompaction = compaction(proof)
        }
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { if $0 == "certify" { throw Injected() } }
        manager._testReplaceMessages([outcome])
        _ = manager._testSave()
        DetachedJobStore.faultForTesting = nil
        return (record, outcome)
    }

    /// Remove `outcome` like an ordinary chunk archive (snapshot + checked
    /// rewrite), then restart and count completions of `record`.
    private func archiveAndRestart(_ manager: ConversationManager, _ outcome: Message, _ record: DetachedJobRecord) async throws -> Int {
        _ = try snapshot(durable: [outcome], trigger: "chunk-archive")
        manager._testReplaceMessages([])
        _ = manager._testSave()
        server.clear(); server.script([Self.chatText("duplicate archived result")])
        let restarted = await restart()
        restarted._testStartupPasses()
        _ = await restarted._testAwaitIdle(timeout: 10)
        return delivered(restarted, record)
    }

    private func removalGateRows() async throws {
        for (label, via) in [("CX2d", "compaction"), ("CX2g", "prune-reference"), ("CX2i", "interrupted")] {
            let manager = await freshManager()
            let (record, outcome) = try snapshotOnlyReceipt(manager, via: via)
            var refused = false
            do { try manager._testSettleBeforeRemoval([outcome]) } catch { refused = true }
            check("\(label) removal gate settles a snapshot-only receipt (\(via)) before its root leaves",
                  !refused && records().isEmpty, "refused \(refused), owed records \(records().count)")
            let count = try await archiveAndRestart(manager, outcome, record)
            check("\(label)' after archive + restart the observed result is not redelivered", count == 0, "completions \(count)")
        }
        // CX2f: the gate's own write fails → removal refused, still owed.
        do {
            let manager = await freshManager()
            let (_, outcome) = try snapshotOnlyReceipt(manager, via: "compaction")
            struct Injected: Error {}
            DetachedJobStore.faultForTesting = { if $0 == "settle-before-removal" { throw Injected() } }
            var refused = false
            do { try manager._testSettleBeforeRemoval([outcome]) } catch { refused = true }
            DetachedJobStore.faultForTesting = nil
            check("CX2f gate write fails → removal refused, record still owed",
                  refused && records().count == 1 && records().first?.completion == .owed)
        }
        // CX2j control: snapshot-only MOVED evidence → certificate upgraded,
        // completion still owed and delivered once after removal (no loss).
        do {
            let manager = await freshManager()
            let (record, outcome) = try snapshotOnlyReceipt(manager, kind: .moved, via: "compaction")
            try manager._testSettleBeforeRemoval([outcome])
            check("CX2j control: moved evidence certified, completion still owed",
                  records().first?.certifiedKind == .moved && records().first?.completion == .owed)
            let count = try await archiveAndRestart(manager, outcome, record)
            check("CX2j' control: the moved job's completion is delivered exactly once", count == 1, "completions \(count)")
        }
        // CX2h: an UNVERIFIABLE route whose root is removed → recorded on
        // the record; after restart the obligation is retained and
        // reported, never delivered as if absent.
        do {
            let manager = await freshManager()
            let record = Self.record(instance: DetachedJobStore.instanceId)
            try DetachedJobStore.create(record)
            let ref = try snapshot(durable: [Self.assistant("x", rounds: [])], trigger: "prune")
            SettlementEvidence.removeSidecar(ref.id, snapshots: PruneArchiveStore.root)
            var outcome = Self.assistant("unverifiable route", rounds: [])
            outcome.pruneArchiveReferences = [ref]
            manager._testReplaceMessages([outcome])
            _ = manager._testSave()
            try manager._testSettleBeforeRemoval([outcome])
            check("CX2h unverifiable route removed → recorded on the record (checked write)",
                  records().first?.routeRemovedWhileUnverifiable != nil)
            let count = try await archiveAndRestart(manager, outcome, record)
            check("CX2h' after restart: retained and reported, not delivered", count == 0
                    && records().first?.completion == .owed && records().first?.unverifiableReason != nil,
                  "completions \(count), records \(records().count)")
        }
    }

    // MARK: CX3 — /stop and queued subagent completions

    static func subagentCompletion(_ id: String) -> SubagentBackgroundRegistry.Completion {
        .init(handle: .init(id: id, subagentType: "general-purpose", description: "finished before stop", startedAt: Date()),
              result: subagentResult(), completedAt: Date())
    }
    private static func subagentResult() -> SubagentRunner.RunResult {
        SubagentRunner.RunResult(sessionId: "cx", isNewSession: true, finalMessage: "completed work", turnsUsed: 1,
                                 toolsCalled: [], filesTouched: [], spendUSD: 0, error: nil)
    }

    private func subagentStopRows() async throws {
        // CX3: finished before /stop, drained after.
        do {
            let manager = await freshManager()
            await SubagentBackgroundRegistry.shared._testEnqueueCompletion(Self.subagentCompletion("cx_finished"))
            await manager._testStop()
            server.clear(); server.script([Self.chatText("unwanted restart after stop")])
            await manager._testSubagentDrainOnly()
            _ = await manager._testAwaitIdle(timeout: 10)
            check("CX3 a queued subagent completion cannot restart work after /stop",
                  server.completeRequests.isEmpty
                    && manager._testMessages.contains { $0.kind == .subagentComplete && $0.content.contains("[Stopped by /stop") },
                  "requests after stop: \(server.completeRequests.count)")
        }
        // CX3b control: no /stop → the completion wakes one turn.
        do {
            let manager = await freshManager()
            await SubagentBackgroundRegistry.shared._testEnqueueCompletion(Self.subagentCompletion("cx_control"))
            server.clear(); server.script([Self.chatText("reacting to the result")])
            await manager._testSubagentDrainOnly()
            _ = await manager._testAwaitIdle(timeout: 10)
            check("CX3b control: without /stop the completion starts one turn", server.completeRequests.count == 1)
        }
        // CX3c: a run finishing concurrently with /stop (either side of the
        // cutoff snapshot) never wakes afterwards.
        do {
            let manager = await freshManager()
            server.clear(); server.script([])
            var stoppedNotes = 0
            for i in 0..<25 {
                let id = "cx_race_\(i)"
                await SubagentBackgroundRegistry.shared._testRegisterRunning(
                    .init(id: id, subagentType: "general-purpose", description: "racing", startedAt: Date()))
                async let finish: Void = SubagentBackgroundRegistry.shared._testMarkCompleted(id: id, result: Self.subagentResult())
                await manager._testStop()
                await finish
                await manager._testSubagentDrainOnly()
                _ = await manager._testAwaitIdle(timeout: 5)
                stoppedNotes += manager._testMessages.filter { $0.content.contains("handle: \(id)") && $0.content.contains("[Stopped by /stop") }.count
            }
            check("CX3c 25 completions racing /stop: none starts work, all recorded as stopped",
                  server.completeRequests.isEmpty && stoppedNotes == 25,
                  "requests \(server.completeRequests.count), stopped notes \(stoppedNotes)")
        }
        // CX3d: main-actor work interleaving at the cutoff awaits (an idle
        // drain starting a turn) — the marker names the run actually
        // cancelled, and that run is cancelled.
        do {
            let manager = await freshManager()
            let late = user("turn started during the cutoff")
            server.clear()
            server.script([Self.chatTools([(id: "cx-late", name: "bash", args: ["command": "sleep 20", "wait_seconds": 60])]),
                           Self.chatText("should never be requested")])
            ConversationManager.stopCutoffInterleaveForTesting = { manager._testStartTurn(for: late) }
            await manager._testStop()
            ConversationManager.stopCutoffInterleaveForTesting = nil
            let idle = await manager._testAwaitIdle(timeout: 20)
            var triggers: [UUID?] = []
            if case .known(let entries) = StopMarkerStore.load() { triggers = entries.map(\.stoppedTurnTriggerId) }
            let running = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
            check("CX3d a turn started at the cutoff awaits is the one recorded and cancelled",
                  idle && triggers.contains(late.id) && running.isEmpty
                    && !manager._testMessages.contains { $0.role == .assistant && $0.content == "should never be requested" },
                  "triggers \(triggers), idle \(idle), running \(running.count)")
            await manager._testIdleDrains()
        }
    }

    // MARK: CX4 — wait expiry needs the crash record

    private func expiryRecordRows() async throws {
        struct Injected: Error {}
        // CX4: initial wait expires, record write fails.
        do {
            let manager = await freshManager()
            DetachedJobStore.faultForTesting = { if $0 == "create" { throw Injected() } }
            server.script([
                Self.chatTools([(id: "cx4", name: "bash", args: ["command": "sleep 5", "wait_seconds": 1])]),
                Self.chatText("background accepted")
            ])
            manager._testStartTurn(for: user("run command"))
            _ = await manager._testAwaitIdle(timeout: 15)
            DetachedJobStore.faultForTesting = nil
            let running = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
            let result = results(manager).first { $0.toolCallId == "cx4" }
            let payload = parse(result?.content ?? "")
            check("CX4 initial wait expiry without a durable record: job stopped, nothing runs untracked",
                  running.isEmpty && records().isEmpty, "running jobs \(running.count), records \(records().count)")
            check("CX4b the model gets the terminal result and the reason, not a promise",
                  payload["stopped_untracked"] as? Bool == true && payload["status"] as? String != "running"
                    && payload["wait_timed_out"] == nil && result?.outcomeBinding?.kind != .moved, "\(payload)")
            _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        }
        // CX4c: bash_manage wait expiry on a job that has no record.
        do {
            let manager = await freshManager()
            let start = await BashTools.runManaged(command: "sleep 6", requestedWaitSeconds: 0, effectiveWaitSeconds: 0,
                                                   waitRefusalReason: nil, killAfterSeconds: nil)
            let handle = parse(start.content)["handle"] as? String ?? ""
            DetachedJobStore.faultForTesting = { if $0 == "create" { throw Injected() } }
            server.script([
                Self.chatTools([(id: "cx4c", name: "bash_manage", args: ["mode": "wait", "handle": handle, "wait_seconds": 1])]),
                Self.chatText("ok")
            ])
            manager._testStartTurn(for: user("wait on it"))
            _ = await manager._testAwaitIdle(timeout: 15)
            DetachedJobStore.faultForTesting = nil
            let running = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
            let payload = parse(results(manager).first { $0.toolCallId == "cx4c" }?.content ?? "")
            check("CX4c bash_manage wait expiry without a durable record: job stopped and reported",
                  !handle.isEmpty && running.isEmpty && records().isEmpty && payload["stopped_untracked"] as? Bool == true,
                  "handle \(handle), running \(running.count), \(payload)")
            _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        }
        // CX4d: wake → record write fails → keeps waiting → expiry.
        do {
            let manager = await freshManager()
            DetachedJobStore.faultForTesting = { if $0 == "create" { throw Injected() } }
            server.script([
                Self.chatTools([(id: "cx4d", name: "bash", args: ["command": "sleep 6", "wait_seconds": 2])]),
                Self.chatText("ok")
            ])
            manager._testStartTurn(for: user("long one"))
            _ = await waitForRunningJob()
            await manager._testDispatchUser(user("message during the wait"))
            _ = await manager._testAwaitIdle(timeout: 15)
            DetachedJobStore.faultForTesting = nil
            let running = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
            let payload = parse(results(manager).first { $0.toolCallId == "cx4d" }?.content ?? "")
            check("CX4d wake → record failure → expiry: stopped, never moved, nothing untracked",
                  running.isEmpty && records().isEmpty && payload["moved_to_background"] == nil
                    && payload["stopped_untracked"] as? Bool == true, "running \(running.count), \(payload)")
            _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        }
        // CX4e control: healthy storage → expiry detaches with its record.
        do {
            let manager = await freshManager()
            server.script([
                Self.chatTools([(id: "cx4e", name: "bash", args: ["command": "sleep 4", "wait_seconds": 1])]),
                Self.chatText("continues")
            ])
            manager._testStartTurn(for: user("run it"))
            _ = await manager._testAwaitIdle(timeout: 15)
            let running = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
            let result = results(manager).first { $0.toolCallId == "cx4e" }
            check("CX4e control: healthy storage → the expired job continues with a waitExpired record, bound moved",
                  running.count == 1 && records().first?.launch == .waitExpired && result?.outcomeBinding?.kind == .moved,
                  "running \(running.count), records \(records().map(\.launch))")
            _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        }
    }
}
