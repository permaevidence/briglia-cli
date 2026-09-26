import Foundation

/// Restart rows: startup stop pass (§3.9.3) and job reconciliation
/// (§3.10.4). A "crash" is simulated by dropping the live registry, minting
/// a new process instance id and constructing a new manager over the same
/// files — the new instance sees only what was durable.
extension MidturnHarness {

    func restart() async -> ConversationManager {
        _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        await TurnWakeCenter.shared.disarm()
        DetachedJobStore.instanceId = UUID()
        DetachedJobStore.forgetCreatedForTesting()
        let manager = ConversationManager()
        await manager._testPrepareScriptedProvider(apiKey: apiKey)
        return manager
    }

    func restartSection() async throws {
        let trigger = user("trigger that was stopped")
        let held = user("held message")
        let fresh = user("fresh message")

        // V5-R4 / S11: marker saved, crash before per-job writes and before
        // the queue/defer settled; two entries (repeated /stop), both
        // trigger ids honored.
        do {
            let manager = await freshManager(history: [trigger])
            let job = UUID()
            var record = Self.record(jobId: job, body: nil)
            record.stopId = nil
            try DetachedJobStore.create(record)
            let entry1 = StopEntry(stopId: UUID(), at: Date(), stoppedTurnTriggerId: trigger.id,
                                   heldQueueMessageIds: [held.id], heldNoteMessageId: UUID(),
                                   affectedJobIds: [job], affectedWatchMatchIds: [])
            let entry2 = StopEntry(stopId: UUID(), at: Date(), stoppedTurnTriggerId: UUID(),
                                   heldQueueMessageIds: [], heldNoteMessageId: UUID(), affectedJobIds: [], affectedWatchMatchIds: [])
            try StopMarkerStore.append(entry1)
            try StopMarkerStore.append(entry2)
            manager._testPersistQueue([held])
            manager._testWriteActiveTurnMarker(for: trigger)
            server.script([])
            let restarted = await restart()
            restarted._testStartupPasses()
            _ = await restarted._testAwaitIdle(timeout: 10)
            let history = restarted._testMessages
            let heldIndex = history.firstIndex { $0.id == held.id }
            let noteIndex = history.firstIndex { $0.id == entry1.heldNoteMessageId }
            check("R1a restart: held message in history with its note, not answered",
                  heldIndex != nil && noteIndex != nil && noteIndex! > heldIndex! && server.completeRequests.isEmpty)
            check("R1b restart: the stopped turn is not resumed (marker cleared)",
                  !FileManager.default.fileExists(atPath: restarted._testActiveTurnMarkerURL.path) && server.completeRequests.isEmpty)
            let lost = history.first { $0.id == record.completionMessageId }
            check("R1c restart: the stopped job's lost note is appended without waking",
                  lost?.content.contains("[BACKGROUND BASH LOST]") == true && lost?.content.contains("[Stopped by /stop") == true
                    && restarted._testRecoveredWakeTrigger == nil)
            // S13: a second restart (queue file removed only after the
            // save) never adds a second note or message.
            restarted._testPersistQueue([held])
            let again = await restart()
            again._testStartupPasses()
            let history2 = again._testMessages
            check("R2 no second note or duplicate message after a crash before queue removal",
                  history2.filter { $0.id == held.id }.count == 1
                    && history2.filter { $0.id == entry1.heldNoteMessageId }.count == 1)
            check("R3 entry 1 retired after re-read settlement; entry 2 (no items) retired too", StopMarkerStore.load() == .none)
        }

        // V5-R4: an unreadable marker → nothing resumed or answered.
        do {
            let manager = await freshManager(history: [trigger])
            try Data("{not json".utf8).write(to: StopMarkerStore.fileURL)
            manager._testPersistQueue([fresh])
            manager._testWriteActiveTurnMarker(for: trigger)
            let restarted = await restart()
            restarted._testStartupPasses()
            _ = await restarted._testAwaitIdle(timeout: 5)
            check("R4 unreadable marker: queued message appended but not answered, nothing resumed",
                  restarted._testMessages.contains { $0.id == fresh.id } && server.completeRequests.isEmpty)
            if case .unknown = StopMarkerStore.load() {
                check("R4b the unreadable marker is never overwritten", true)
            } else { check("R4b the unreadable marker is never overwritten", false) }
            try? FileManager.default.removeItem(at: StopMarkerStore.fileURL)
        }

        // C1/C4: a notice already durable under the record's id settles the
        // record with no second copy; repeated recovery is idempotent.
        do {
            var record = Self.record()
            let notice = Message(id: record.completionMessageId, role: .user, content: "[BACKGROUND BASH COMPLETE] earlier", kind: .bashComplete)
            _ = await freshManager(history: [trigger, notice])
            record.completionBody = "[BACKGROUND BASH COMPLETE]\n\nhandle: bash_9"
            try DetachedJobStore.create(record)
            let r1 = await restart()
            r1._testStartupPasses()
            let r2 = await restart()
            r2._testStartupPasses()
            check("C1 crash after history save before record flip → one copy, record settled",
                  r2._testMessages.filter { $0.id == record.completionMessageId }.count == 1 && records().isEmpty)
        }

        // Recovered real result: a job that settled before the crash is
        // delivered with its persisted notice, once, and wakes a turn.
        do {
            _ = await freshManager(history: [trigger])
            let record = Self.record(body: "[BACKGROUND BASH COMPLETE]\n\nhandle: bash_9\ncommand: make\nstatus: exited cleanly")
            try DetachedJobStore.create(record)
            server.script([Self.chatText("noted the recovered result")])
            let restarted = await restart()
            restarted._testStartupPasses()
            _ = await restarted._testAwaitIdle(timeout: 10)
            let delivered = restarted._testMessages.filter { $0.id == record.completionMessageId }
            check("C2 settled-before-crash job: persisted real notice delivered once and wakes a turn",
                  delivered.count == 1 && delivered.first?.content.contains("status: exited cleanly") == true
                    && delivered.first?.content.contains("Recovered after a restart") == true
                    && server.completeRequests.count == 1 && records().isEmpty)
        }

        // Publication gate: unresolved canonical recovery (an invalid
        // salvage file preserved) defers the job pass; once resolved, the
        // pass runs.
        do {
            _ = await freshManager(history: [trigger])
            let record = Self.record()
            try DetachedJobStore.create(record)
            try Data("[not a salvage".utf8).write(to: StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json"))
            let blocked = await restart()
            blocked._testStartupPasses()
            check("C3a publication gate: unresolved recovery → job pass deferred, record untouched",
                  blocked._testRecoveryBlocked && !blocked._testMessages.contains { $0.id == record.completionMessageId }
                    && records().count == 1)
            try? FileManager.default.removeItem(at: StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json"))
            server.script([Self.chatText("ok")])
            let resolved = await restart()
            resolved._testStartupPasses()
            _ = await resolved._testAwaitIdle(timeout: 10)
            check("C3b once recovery resolves, the deferred job pass publishes exactly once",
                  resolved._testMessages.filter { $0.id == record.completionMessageId }.count == 1 && records().isEmpty)
        }

        // V5-R1 (a) / V6-R1 (c): a receipt-bearing result that reached only
        // turn_salvage.json (crash before the final message) is saved by
        // canonical recovery under a fresh carrier id; the job pass finds its
        // typed binding → zero completions, zero lost notes.
        do {
            _ = await freshManager(history: [trigger])
            let record = Self.record()
            try DetachedJobStore.create(record)
            let salvage = [Self.round(callId: "call-w", content: "{\"status\":\"exited\"}",
                                      binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId))]
            try JSONEncoder().encode(salvage).write(to: StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json"))
            let restarted = await restart()
            restarted._testStartupPasses()
            check("C5 receipt only in salvage → canonical recovery + job pass: zero notices, record settled",
                  !restarted._testMessages.contains { $0.id == record.completionMessageId } && records().isEmpty
                    && restarted._testMessages.contains { $0.toolInteractions.contains { $0.results.contains { $0.outcomeBinding?.jobId == record.jobId } } })
        }

        // C16: an unreadable records file is never overwritten; creating a
        // record fails closed.
        do {
            _ = await freshManager()
            try Data("garbage".utf8).write(to: DetachedJobStore.fileURL)
            var created = false
            do { try DetachedJobStore.create(Self.record()); created = true } catch {}
            let bytes = try? Data(contentsOf: DetachedJobStore.fileURL)
            check("C4 unreadable crash records: never overwritten, create fails closed",
                  !created && bytes == Data("garbage".utf8))
            try? FileManager.default.removeItem(at: DetachedJobStore.fileURL)
        }
    }
}
