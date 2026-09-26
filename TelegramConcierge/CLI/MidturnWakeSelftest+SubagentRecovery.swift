import Foundation

/// Release 1b rows: /stop over detached subagents, crash/restart recovery
/// (lost, finished-undelivered, delivered-unflipped, real-settled),
/// unreadable storage holds, the removal gate for subagent notices, and the
/// Responses transport through the real manager.
extension MidturnHarness {

    /// Detach one general subagent (slow reply) and return its job id and
    /// record, with the manager idle after the woken turn.
    func detachOneSubagent(_ manager: ConversationManager, sub: SubagentScript, callId: String,
                           reply: String, delay: TimeInterval, cost: Double = 0,
                           responses: Bool = false) async -> (jobId: UUID, record: DetachedJobRecord)? {
        sub.general(Self.costedText(reply, cost: cost, responses: responses), delay: delay, cost: cost)
        installSubagentRouter(sub)
        let agentCall = responses
            ? Self.responsesTools([(id: callId, name: "Agent", args: Self.agentArgs(description: "detach me", prompt: "Long task \(callId)"))])
            : Self.chatTools([(id: callId, name: "Agent", args: Self.agentArgs(description: "detach me", prompt: "Long task \(callId)"))])
        let answer = responses ? Self.responsesText("answered while it runs") : Self.chatText("answered while it runs")
        let after = responses ? Self.responsesText("report handled") : Self.chatText("report handled")
        server.script([agentCall, answer, after])
        manager._testStartTurn(for: user("start \(callId)"))
        _ = await waitUntil(timeout: 10) { sub.generalRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("message during \(callId)"))
        _ = await manager._testAwaitIdle(timeout: 20)
        guard let jobId = results(manager).first(where: { $0.toolCallId == callId })?.outcomeBinding?.jobId,
              let record = records().first(where: { $0.jobId == jobId }) else { return nil }
        return (jobId, record)
    }

    // MARK: /stop

    func subagentStopSection() async throws {
        try await stopKillsDetachedRun()
        try await stopHoldsQueuedDetachedCompletion()
        try await stopRefusesDetachCommit()
        try await stopRefusesBackgroundLaunch()
    }

    /// ST1: /stop cancels a running detached subagent; the marker names its
    /// job; its (cancelled) report is appended once WITHOUT waking a turn.
    private func stopKillsDetachedRun() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        guard let (jobId, record) = await detachOneSubagent(manager, sub: sub, callId: "call-st1", reply: "never finishes", delay: 6) else {
            check("ST1 detached run set up", false); return
        }
        let before = mainRequestBodies().count
        await manager._testStop()
        let marked = StopMarkerStore.load().stoppedJobIds.contains(jobId)
        _ = await waitForCompletionQueued(timeout: 10)
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 10)
        let notices = manager._testMessages.filter { $0.id == record.completionMessageId }
        check("ST1 /stop: the marker names the detached job; its report is appended once, marked stopped, no new turn",
              marked && notices.count == 1 && notices.first?.content.contains("[Stopped by /stop") == true
                && mainRequestBodies().count == before,
              "marked \(marked), notices \(notices.count), main requests \(mainRequestBodies().count) vs \(before)")
    }

    /// ST2: a detached run that already finished (completion queued, not yet
    /// drained) is covered by the cutoff: appended without waking.
    private func stopHoldsQueuedDetachedCompletion() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        guard let (jobId, record) = await detachOneSubagent(manager, sub: sub, callId: "call-st2", reply: "finished before stop", delay: 1.0) else {
            check("ST2 detached run set up", false); return
        }
        _ = await waitForCompletionQueued()
        let before = mainRequestBodies().count
        await manager._testStop()
        let marked = StopMarkerStore.load().stoppedJobIds.contains(jobId)
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 10)
        let notice = manager._testMessages.first { $0.id == record.completionMessageId }
        check("ST2 queued detached completion at /stop: marked, appended with the stop note, no turn",
              marked && notice?.content.contains("finished before stop") == true
                && notice?.content.contains("[Stopped by /stop") == true && mainRequestBodies().count == before)
    }

    /// ST3: /stop's cutoff lands while a woken run's crash record is being
    /// written (the run itself still going): the detach commit is refused
    /// (admission closed for the turn), the record is dropped, and nothing
    /// keeps running or is delivered later.
    private func stopRefusesDetachCommit() async throws {
        let manager = await freshManager()
        let gate = DispatchSemaphore(value: 0)
        final class Flag: @unchecked Sendable { var entered = false }
        let flag = Flag()
        ToolExecutor.beforeSubagentRecordForTesting = {
            flag.entered = true; _ = gate.wait(timeout: .now() + 10)
        }
        // After the cutoff, before any cancellation: let the executor write
        // the record and try to commit the detach.
        ConversationManager.stopCutoffInterleaveForTesting = {
            gate.signal()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        defer {
            ToolExecutor.beforeSubagentRecordForTesting = nil
            ConversationManager.stopCutoffInterleaveForTesting = nil
        }
        let sub = SubagentScript()
        sub.general(Self.costedText("stopped mid-detach", cost: 0), delay: 3.0, cost: 0)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-st3", name: "Agent", args: Self.agentArgs(description: "mid-detach", prompt: "Task"))]),
            Self.chatText("never requested"),
        ])
        manager._testStartTurn(for: user("stop during detach"))
        _ = await waitUntil(timeout: 10) { sub.generalRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("wake"))
        _ = await waitUntil(timeout: 10) { flag.entered }
        let before = mainRequestBodies().count
        await manager._testStop()
        _ = await manager._testAwaitIdle(timeout: 15)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let running = await SubagentBackgroundRegistry.shared.runningHandles()
        let queued = await SubagentBackgroundRegistry.shared._testPendingCompletionsCount()
        let moved = results(manager).contains { $0.toolCallId == "call-st3" && parse($0.content)["status"] as? String == "moved_to_background" }
        check("ST3 /stop cutoff during the detach commit: refused — no moved result, record dropped, nothing running or queued",
              !moved && records().isEmpty && running.isEmpty && queued == 0 && mainRequestBodies().count == before,
              "moved \(moved), records \(records().count), running \(running.count), queued \(queued)")
    }

    /// ST4: an explicit background launch whose record is written after the
    /// /stop cutoff is refused by the closed admission (record dropped,
    /// never started).
    private func stopRefusesBackgroundLaunch() async throws {
        let manager = await freshManager()
        let gate = DispatchSemaphore(value: 0)
        final class Flag: @unchecked Sendable { var entered = false }
        let flag = Flag()
        ToolExecutor.beforeSubagentRecordForTesting = {
            flag.entered = true; _ = gate.wait(timeout: .now() + 10)
        }
        ConversationManager.stopCutoffInterleaveForTesting = {
            gate.signal()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        defer {
            ToolExecutor.beforeSubagentRecordForTesting = nil
            ConversationManager.stopCutoffInterleaveForTesting = nil
        }
        let sub = SubagentScript()
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-st4", name: "Agent", args: Self.agentArgs(description: "bg", prompt: "Bg task", background: true))]),
            Self.chatText("never requested"),
        ])
        manager._testStartTurn(for: user("launch then stop"))
        _ = await waitUntil(timeout: 10) { flag.entered }
        await manager._testStop()
        _ = await manager._testAwaitIdle(timeout: 15)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let running = await SubagentBackgroundRegistry.shared.runningHandles()
        let queued = await SubagentBackgroundRegistry.shared._testPendingCompletionsCount()
        check("ST4 background launch after the /stop cutoff: refused, record dropped, never started",
              running.isEmpty && queued == 0 && records().isEmpty && sub.generalRequestTimes.isEmpty,
              "running \(running.count), queued \(queued), records \(records().count), sub requests \(sub.generalRequestTimes.count)")
    }

    // MARK: Restart / crash

    func subagentRestartSection() async throws {
        try await restartLostRun()
        try await restartFinishedUndelivered()
        try await restartDeliveredUnflipped()
        try await restartRealSettled()
        try await restartHistoryUnreadable()
        try await heldQueueFileHoldsCompletion()
        await removalGateRows()
    }

    /// RS1: crash while a detached run is still going: after restart exactly
    /// one [SUBAGENT LOST] note (under the record's id, waking a turn), an
    /// unknown-amount spend incident, the record retired only after it.
    private func restartLostRun() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        guard let (jobId, record) = await detachOneSubagent(manager, sub: sub, callId: "call-rs1", reply: "too late", delay: 6) else {
            check("RS1 detached run set up", false); return
        }
        _ = manager
        server.clear(); server.script([Self.chatText("noted the lost run"), Self.chatText("spare")])
        let restarted = await restartKillingSubagents()
        restarted._testStartupPasses()
        _ = await restarted._testAwaitIdle(timeout: 20)
        let notes = restarted._testMessages.filter { $0.id == record.completionMessageId }
        let incident = openIncidents().first { $0.id == "unknown-amount:\(jobId.uuidString.lowercased())" }
        check("RS1a lost detached run: one [SUBAGENT LOST] note under the record's id; it wakes a turn",
              notes.count == 1 && notes.first?.kind == .subagentComplete && notes.first?.content.contains("[SUBAGENT LOST]") == true
                && mainRequestBodies().count >= 1, "notes \(notes.count)")
        check("RS1b its unknown amount is an open spend incident, and the record retired only after it",
              incident != nil && !records().contains { $0.jobId == jobId })
        let again = await restart()
        again._testStartupPasses()
        check("RS1c another restart adds nothing (one note, one incident)",
              again._testMessages.filter { $0.id == record.completionMessageId }.count == 1
                && openIncidents().filter { $0.id == incident?.id }.count == 1)
    }

    /// RS2: the run finished (charge recorded, report persisted) but the
    /// process died before delivery: the persisted real report is delivered
    /// once after restart, never charged again, no incident.
    private func restartFinishedUndelivered() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        guard let (jobId, record) = await detachOneSubagent(manager, sub: sub, callId: "call-rs2", reply: "finished report RS2",
                                                            delay: 1.0, cost: 0.04) else {
            check("RS2 detached run set up", false); return
        }
        _ = manager
        _ = await waitForCompletionQueued()
        server.clear(); server.script([Self.chatText("handled the recovered report")])
        let restarted = await restartKillingSubagents()
        restarted._testStartupPasses()
        _ = await restarted._testAwaitIdle(timeout: 20)
        let notes = restarted._testMessages.filter { $0.id == record.completionMessageId }
        check("RS2 finished-undelivered: the real report is delivered once after restart; charged once; no incident",
              notes.count == 1 && notes.first?.content.contains("finished report RS2") == true
                && notes.first?.content.contains("[Recovered after a restart") == true
                && ledgerEntries().filter { $0.chargeId == jobId }.count == 1 && openIncidents().isEmpty
                && !records().contains { $0.jobId == jobId },
              "notes \(notes.count), ledger \(ledgerEntries().count), incidents \(openIncidents().map(\.id))")
    }

    /// RS3: the notice reached durable history but the record's delivered
    /// flip failed, then a crash: restart publishes no second copy.
    private func restartDeliveredUnflipped() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        guard let (jobId, record) = await detachOneSubagent(manager, sub: sub, callId: "call-rs3", reply: "delivered once RS3", delay: 1.0) else {
            check("RS3 detached run set up", false); return
        }
        _ = await waitForCompletionQueued()
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { if $0 == "delivered" { throw Injected() } }
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 20)
        DetachedJobStore.faultForTesting = nil
        let owedAfterFlipFailure = records().first { $0.jobId == jobId }?.completion == .owed
        server.clear(); server.script([Self.chatText("spare")])
        let restarted = await restartKillingSubagents()
        restarted._testStartupPasses()
        _ = await restarted._testAwaitIdle(timeout: 10)
        check("RS3 delivered-but-unflipped record + crash: no second copy after restart; record settles",
              owedAfterFlipFailure && restarted._testMessages.filter { $0.id == record.completionMessageId }.count == 1
                && !records().contains { $0.jobId == jobId })
    }

    /// RS4: a record whose run finished while its detach was being committed
    /// (the durable result is bound `real`): restart owes nothing — no note,
    /// no incident.
    private func restartRealSettled() async throws {
        let jobId = UUID()
        var record = Self.record(jobId: jobId, handle: "subagent_7", body: nil, callId: "call-rs4")
        record.kind = DetachedJobRecord.subagentKind
        record.providerCalled = true
        record.subagentType = "general-purpose"
        let history = [user("rs4"), Self.assistant("done", rounds: [
            Self.round(callId: "call-rs4", content: "{\"final_message\":\"real result\"}",
                       binding: OutcomeBinding(kind: .real, jobId: jobId), name: "Agent")])]
        let manager = await freshManager(history: history)
        _ = manager._testSave()
        try DetachedJobStore.create(record)
        let restarted = await restartKillingSubagents()
        restarted._testStartupPasses()
        check("RS4 durable real result settles the record: no note, no incident, record retired",
              !restarted._testMessages.contains { $0.id == record.completionMessageId } && openIncidents().isEmpty
                && records().isEmpty, "records \(records().map(\.completion)), incidents \(openIncidents().map(\.id))")
    }

    /// RS5: history unreadable at restart: the persisted report stays owed
    /// (nothing published, no incident); after repair + restart it is
    /// delivered exactly once.
    private func restartHistoryUnreadable() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        guard let (jobId, record) = await detachOneSubagent(manager, sub: sub, callId: "call-rs5", reply: "report RS5", delay: 1.0) else {
            check("RS5 detached run set up", false); return
        }
        _ = await waitForCompletionQueued()
        let url = StoragePaths.dataRoot.appendingPathComponent("conversation.json")
        guard let good = try? Data(contentsOf: url) else { check("RS5 history saved", false); return }
        try Data("{not json".utf8).write(to: url)
        server.clear(); server.script([Self.chatText("handled after repair")])
        let broken = await restartKillingSubagents()
        broken._testStartupPasses()
        let heldOwed = records().first { $0.jobId == jobId }?.completion == .owed
        check("RS5a unreadable history: nothing published, record owed, no incident, file unchanged",
              heldOwed && !broken._testMessages.contains { $0.id == record.completionMessageId } && openIncidents().isEmpty
                && (try? Data(contentsOf: url)) == Data("{not json".utf8))
        try good.write(to: url)
        let repaired = await restart()
        repaired._testStartupPasses()
        _ = await repaired._testAwaitIdle(timeout: 20)
        check("RS5b after repair + restart: delivered exactly once; record retired",
              repaired._testMessages.filter { $0.id == record.completionMessageId }.count == 1 && !records().contains { $0.jobId == jobId })
    }

    /// RS6: the held-message file cannot be read (no new work starts): a
    /// finished detached subagent's report stays queued and owed; once the
    /// file is readable again it is delivered once.
    private func heldQueueFileHoldsCompletion() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        guard let (jobId, record) = await detachOneSubagent(manager, sub: sub, callId: "call-rs6", reply: "report RS6", delay: 1.0) else {
            check("RS6 detached run set up", false); return
        }
        _ = await waitForCompletionQueued()
        let queueURL = StoragePaths.dataRoot.appendingPathComponent("pending_midturn.json")
        try Data("[garbage".utf8).write(to: queueURL)
        server.clear(); server.script([Self.chatText("delivered after the file was repaired")])
        let restarted = await restartKillingSubagents()
        restarted._testStartupPasses()
        let held = restarted._testHeldQueueProblem != nil && records().first { $0.jobId == jobId }?.completion == .owed
            && !restarted._testMessages.contains { $0.id == record.completionMessageId }
        try FileManager.default.removeItem(at: queueURL)
        let repaired = await restart()
        repaired._testStartupPasses()
        _ = await repaired._testAwaitIdle(timeout: 20)
        check("RS6 unreadable held-message file: the report stays owed (nothing published); after repair delivered once",
              held && repaired._testMessages.filter { $0.id == record.completionMessageId }.count == 1)
    }

    /// RG: with unreadable records, a subagent notice may be the only
    /// deduplication proof — it never leaves history; with readable records
    /// the notice leaving settles its record.
    private func removalGateRows() async {
        let notice = Message(role: .user, content: "[SUBAGENT COMPLETE]\nhandle: subagent_9", kind: .subagentComplete)
        let manager = await freshManager(history: [user("rg"), notice])
        _ = manager._testSave()
        try? Data("{garbage".utf8).write(to: DetachedJobStore.fileURL)
        var refused = false
        do { try manager._testSettleBeforeRemoval([notice]) } catch { refused = true }
        check("RG1 unreadable records: a subagent notice cannot leave history (removal refused)", refused)
        try? FileManager.default.removeItem(at: DetachedJobStore.fileURL)
        var record = DetachedJobRecord(jobId: UUID(), instanceId: UUID(), turnRunId: nil, toolCallId: nil,
                                       callFingerprint: nil, handle: "subagent_9", command: "d", description: nil, workdir: nil,
                                       startedAt: Date(), launch: .background, completionMessageId: notice.id)
        record.kind = DetachedJobRecord.subagentKind
        record.charge = JobCharge(chargeId: record.jobId, amountUSD: 0, providerReturnedAt: Date(), state: .recorded)
        try? DetachedJobStore.create(record)
        var threw = false
        do { try manager._testSettleBeforeRemoval([notice]) } catch { threw = true }
        check("RG2 control: readable records — the leaving notice settles its record (delivered), removal allowed",
              !threw && !records().contains { $0.jobId == record.jobId })
        // RG3: pruning the round that carries a detached subagent's MOVED
        // result certifies the record as moved first; its report stays owed.
        let job = UUID()
        var moved = DetachedJobRecord(jobId: job, instanceId: DetachedJobStore.instanceId, turnRunId: nil, toolCallId: "call-rg3",
                                      callFingerprint: nil, handle: "subagent_3", command: "d", description: nil, workdir: nil,
                                      startedAt: Date(), launch: .wakeDetached, completionMessageId: UUID())
        moved.kind = DetachedJobRecord.subagentKind
        moved.providerCalled = true
        let carrier = Self.assistant("moved", rounds: [Self.round(callId: "call-rg3", content: "{\"status\":\"moved_to_background\"}",
                                                                   binding: OutcomeBinding(kind: .moved, jobId: job), name: "Agent")])
        let manager3 = await freshManager(history: [user("rg3"), carrier])
        _ = manager3._testSave()
        try? DetachedJobStore.create(moved)
        var refused3 = false
        do { try manager3._testSettleBeforeRemoval([carrier]) } catch { refused3 = true }
        let after = records().first { $0.jobId == job }
        check("RG3 pruning a detached subagent's moved result: certified moved first, report still owed",
              !refused3 && after?.certifiedKind == .moved && after?.completion == .owed)
    }

    // MARK: Responses transport

    func subagentResponsesSection() async throws {
        try ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                         model: "fixture-model", effort: nil, textOnly: false, wireProtocol: .responses)
        try ProviderProfiles.activate(.custom)
        defer {
            ConversationManager.responsesSalvageFaultForTesting = nil
            try? ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                              model: "glm-5.3", effort: nil, textOnly: false, wireProtocol: .chatCompletions)
            try? ProviderProfiles.activate(.custom)
            try? configureProvider()
        }
        check("SR0 the manager runs over Responses", ProviderProfiles.usesResponses)
        try await responsesSubagentDetach()
        try await responsesSubagentPlaceholderCrash()
    }

    /// SR1: over Responses the woken Agent call is saved as ONE moved result
    /// (the pre-execution placeholder replaced); the report arrives once.
    private func responsesSubagentDetach() async throws {
        let manager = await freshManager()
        let sub = SubagentScript(); sub.responses = true
        guard let (jobId, record) = await detachOneSubagent(manager, sub: sub, callId: "sr1", reply: "responses report",
                                                            delay: 1.5, responses: true) else {
            check("SR1 detached over Responses", false); return
        }
        let saved = results(manager).filter { $0.toolCallId == "sr1" }
        check("SR1a Responses: one moved result for the call (placeholder replaced), record owed",
              saved.count == 1 && saved.first?.outcomeBinding?.kind == .moved && saved.first?.outcomeBinding?.jobId == jobId
                && record.completion == .owed, "\(saved.map { $0.outcomeBinding?.kind.rawValue ?? "nil" })")
        _ = await waitForCompletionQueued()
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 20)
        check("SR1b Responses: report delivered once; record retired",
              manager._testMessages.filter { $0.id == record.completionMessageId }.count == 1 && records().isEmpty)
    }

    /// SR2: over Responses, a crash right after the batch (only the typed
    /// placeholder durable): restart publishes exactly one lost note for
    /// the subagent job and registers its unknown amount.
    private func responsesSubagentPlaceholderCrash() async throws {
        let manager = await freshManager()
        struct Injected: Error {}
        let dir = StoragePaths.dataRoot
        final class Captured: @unchecked Sendable { var files: [String: Data] = [:] }
        let captured = Captured()
        ConversationManager.responsesSalvageFaultForTesting = { stage in
            guard stage == "completed" else { return }
            for name in ["turn_salvage.json", "conversation.json", "detached-jobs.json", "active_turn.json"] {
                if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) { captured.files[name] = data }
            }
            throw Injected()
        }
        let sub = SubagentScript(); sub.responses = true
        sub.general(Self.costedText("never lands", cost: 0, responses: true), delay: 6, cost: 0)
        installSubagentRouter(sub)
        server.script([
            Self.responsesTools([(id: "sr2", name: "Agent", args: Self.agentArgs(description: "crash", prompt: "Crash task"))]),
            Self.responsesText("never requested"),
        ])
        manager._testStartTurn(for: user("crash after the batch"))
        _ = await waitUntil(timeout: 10) { sub.generalRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("wake it"))
        _ = await manager._testAwaitIdle(timeout: 20)
        ConversationManager.responsesSalvageFaultForTesting = nil
        struct RecordFile: Decodable { let records: [DetachedJobRecord] }
        guard let recordsData = captured.files["detached-jobs.json"],
              let record = (try? JSONDecoder().decode(RecordFile.self, from: recordsData))?.records.first else {
            check("SR2 crash state captured with an owed subagent record", false, "\(captured.files.keys.sorted())"); return
        }
        await SubagentBackgroundRegistry.shared._testReset()
        try? await Task.sleep(nanoseconds: 300_000_000)
        for name in ["turn_salvage.json", "conversation.json", "detached-jobs.json", "active_turn.json"] {
            let url = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            if let data = captured.files[name] { try data.write(to: url) }
        }
        server.clear(); server.script([Self.responsesText("noted after restart"), Self.responsesText("spare")])
        let restarted = await restartKillingSubagents()
        restarted._testStartupPasses()
        _ = await restarted._testAwaitIdle(timeout: 20)
        let placeholders = results(restarted).filter { $0.toolCallId == "sr2" && $0.outcomeBinding?.kind == .interruptedIntent }
        let notes = restarted._testMessages.filter { $0.id == record.completionMessageId }
        check("SR2 Responses crash with only the placeholder: one [SUBAGENT LOST] note, unknown amount registered, record retired",
              !placeholders.isEmpty && notes.count == 1 && notes.first?.content.contains("[SUBAGENT LOST]") == true
                && openIncidents().contains { $0.id == "unknown-amount:\(record.jobId.uuidString.lowercased())" }
                && records().isEmpty,
              "placeholders \(placeholders.count), notes \(notes.count), incidents \(openIncidents().map(\.id)), records \(records().count)")
    }
}
