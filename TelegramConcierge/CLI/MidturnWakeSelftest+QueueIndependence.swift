import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Round-6 rows. (1) The held-message queue file's validity is independent
/// of conversation-history validity: an unreadable file (decode or
/// permission failure) is never deleted or overwritten — at startup
/// recovery, by intake, or by an empty in-memory queue — whether or not
/// history loads; no new work starts until it reads again or the user runs
/// /deleteuserdata. (2) A /stop entry that depends on the turn marker stays
/// unsettled whenever the CURRENT marker state is unreadable.
extension MidturnHarness {

    private var queueFileURL: URL { StoragePaths.dataRoot.appendingPathComponent("pending_midturn.json") }

    private func chmod(_ mode: Int16, _ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    private func bytesAfterRestoringMode(_ url: URL) -> Data? {
        chmod(0o600, url)
        return try? Data(contentsOf: url)
    }

    /// Healthy history holding an interrupted request (with its marker) and
    /// an acknowledged held message in the queue file. Returns the queue
    /// file's valid bytes; the caller then damages it.
    private func healthyWithHeldQueue(_ label: String) async throws -> (prior: Message, held: Message, goodQueue: Data) {
        let prior = user("previous interrupted request")
        let manager = await freshManager(history: [prior])
        manager._testWriteActiveTurnMarker(for: prior)
        let held = user("\(label) held acknowledged request")
        manager._testPersistQueue([held])
        return (prior, held, try Data(contentsOf: queueFileURL))
    }

    private func ordered(_ body: String, _ parts: [String]) -> Bool {
        let positions = parts.map { body.range(of: $0)?.lowerBound }
        return !positions.contains(where: { $0 == nil }) && zip(positions, positions.dropFirst()).allSatisfy { $0! < $1! }
    }

    // MARK: Reported reproductions (kept permanently, unchanged)

    func heldQueueRound5ReproSection() async throws {
        // Only history is repaired; acknowledged held state is still undecodable.
        do {
            let (manager, _, _, good) = try await unreadableWithInterruptedTurn()
            let held = user("C5 held acknowledged request")
            await manager._testDispatchUser(held)
            let damaged = Data("{ held queue still awaiting repair".utf8)
            try damaged.write(to: manager._testPendingMidTurnURL)
            let broken = await restart()
            broken._testStartupPasses()
            check("C5A control both unreadable: queue kept", (try? Data(contentsOf: broken._testPendingMidTurnURL)) == damaged)
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("resumed prior")])
            let partial = await restart()
            partial._testStartupPasses()
            _ = await partial._testAwaitIdle()
            check("C5B history-only repair preserves undecodable held queue", (try? Data(contentsOf: partial._testPendingMidTurnURL)) == damaged,
                  "file exists: \(FileManager.default.fileExists(atPath: partial._testPendingMidTurnURL.path))")
        }
        // A stop names the marker while readable. It becomes unreadable on
        // the next restart, then is restored: the stop must remain authoritative.
        do {
            let (manager, prior, _, good) = try await unreadableWithInterruptedTurn()
            await manager._testStop()
            check("C5C control stop names preserved trigger", StopMarkerStore.load().stoppedTriggerIds.contains(prior.id))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: manager._testActiveTurnMarkerURL.path)
            try good.write(to: holdHistoryURL)
            server.clear()
            let partial = await restart()
            partial._testStartupPasses()
            _ = await partial._testAwaitIdle()
            // Permission-based: as root the marker stays readable (Linux CI container),
            // so only the resume check below applies there.
            if geteuid() != 0 {
                check("C5D stop survives an unreadable named marker", StopMarkerStore.load().stoppedTriggerIds.contains(prior.id),
                      "stop entries: \(StopMarkerStore.load().entries.count)")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial._testActiveTurnMarkerURL.path)
            server.clear()
            server.script([Self.chatText("must not resume stopped request")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("C5E repaired marker cannot resume stopped request", server.completeRequests.isEmpty,
                  "requests: \(server.completeRequests.count)")
        }
        // Control: the conservative disposition created WHEN the marker is
        // unreadable is retained across another unreadable restart.
        do {
            let (manager, _, _, good) = try await unreadableWithInterruptedTurn()
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: manager._testActiveTurnMarkerURL.path)
            await manager._testStop()
            try good.write(to: holdHistoryURL)
            let partial = await restart()
            partial._testStartupPasses()
            check("C5F control conservative unreadable stop retained", StopMarkerStore.load().entries.count == 1)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial._testActiveTurnMarkerURL.path)
            server.clear()
            server.script([Self.chatText("must not resume")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("C5G control conservative stop prevents resume", server.completeRequests.isEmpty)
        }
        await resetState()
    }

    // MARK: R1 — held-queue validity independent of history

    func heldQueueIndependenceSection() async throws {
        // QI0 control: healthy history, no queue file — intake runs normally.
        do {
            let prior = user("QI0 earlier answered request")
            _ = await freshManager(history: [prior])
            server.clear()
            server.script([Self.chatText("healthy reply")])
            let next = await restart()
            next._testStartupPasses()
            await next._testDispatchUser(user("QI0 new message on healthy storage"))
            _ = await next._testAwaitIdle()
            check("QI0 control: healthy storage — no held-file problem, the message is answered once",
                  next._testHeldQueueProblem == nil && server.completeRequests.count == 1 && !next._testInboundDurabilityFailure,
                  "requests \(server.completeRequests.count)")
        }
        // QI1: undecodable queue file, history readable.
        do {
            let (prior, held, goodQueue) = try await healthyWithHeldQueue("QI1")
            let garbage = Data("{ held queue undecodable, history fine".utf8)
            try garbage.write(to: queueFileURL)
            let markerBefore = try Data(contentsOf: StoragePaths.dataRoot.appendingPathComponent("active_turn.json"))
            server.clear()
            server.script([Self.chatText("must not run")])
            let next = await restart()
            next._testStartupPasses()
            _ = await next._testAwaitIdle(timeout: 3)
            check("QI1a readable history: startup keeps the undecodable queue byte for byte and records it",
                  (try? Data(contentsOf: queueFileURL)) == garbage && next._testHeldQueueProblem != nil)
            check("QI1b no work starts: the interrupted request is not resumed; its marker is kept",
                  server.completeRequests.isEmpty && markerBytes(next) == markerBefore, "requests \(server.completeRequests.count)")
            let incoming = user("QI1 arrives while the held file is undecodable")
            await next._testDispatchUser(incoming)
            _ = await next._testAwaitIdle(timeout: 3)
            check("QI1c Telegram intake refused: unconfirmed, not in history or queue, file unchanged, one notice, no request",
                  next._testInboundDurabilityFailure && !next._testMessages.contains { $0.id == incoming.id }
                    && !next._testQueue.contains { $0.id == incoming.id } && (try? Data(contentsOf: queueFileURL)) == garbage
                    && next._testHeldQueueRefusalNoticeSent && server.completeRequests.isEmpty)
            next._testClearInboundDurabilityFailure()
            let outcome = await next.sendFromApp(text: "QI1 app message", attachments: [], policy: .appSocket)
            var refused = false
            if case .refused = outcome { refused = true }
            check("QI1d app intake refused, file unchanged", refused && (try? Data(contentsOf: queueFileURL)) == garbage, "\(outcome)")
            let status = await next._testBackgroundStatus() ?? ""
            check("QI1e /status: held-message file can't be read, no new work starts",
                  status.contains("held-message file can't be read") && status.contains("no new work starts"), status)
            next._testPersistQueue([])
            check("QI1f an empty in-memory queue cannot erase it", (try? Data(contentsOf: queueFileURL)) == garbage)
            let again = await restart()
            again._testStartupPasses()
            check("QI1g a second restart keeps it and the problem", (try? Data(contentsOf: queueFileURL)) == garbage
                    && again._testHeldQueueProblem != nil)
            try goodQueue.write(to: queueFileURL)
            server.clear()
            server.script([Self.chatText("answering both")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            let body = requestBodies().first ?? ""
            let ids = repaired._testMessages.map(\.id)
            check("QI1h repair + restart: one request, earlier request then the held one; held once; file gone; problem cleared",
                  server.completeRequests.count == 1 && ordered(body, [prior.content, held.content])
                    && ids.filter { $0 == held.id }.count == 1 && !FileManager.default.fileExists(atPath: queueFileURL.path)
                    && repaired._testHeldQueueProblem == nil, "requests \(server.completeRequests.count)")
        }
        // QI2: permission-unreadable queue file, history readable.
        do {
            let (_, held, goodQueue) = try await healthyWithHeldQueue("QI2")
            chmod(0o000, queueFileURL)
            server.clear()
            server.script([Self.chatText("must not run")])
            let next = await restart()
            next._testStartupPasses()
            let incoming = user("QI2 arrives while the held file is unreadable")
            await next._testDispatchUser(incoming)
            _ = await next._testAwaitIdle(timeout: 3)
            let problem = next._testHeldQueueProblem
            let refusedIntake = next._testInboundDurabilityFailure
            check("QI2a permission-unreadable: kept byte for byte, recorded, intake refused, no request",
                  bytesAfterRestoringMode(queueFileURL) == goodQueue && problem != nil && refusedIntake
                    && server.completeRequests.isEmpty)
            server.clear()
            server.script([Self.chatText("answering after permissions fixed")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("QI2b readable again + restart: the held message is answered once, file gone",
                  server.completeRequests.count == 1 && repaired._testMessages.filter { $0.id == held.id }.count == 1
                    && !FileManager.default.fileExists(atPath: queueFileURL.path))
        }
        // QI3: the reported sequence with a permission failure instead of a
        // decode failure — held while history unreadable, queue made
        // unreadable, restart, repair only history, restart.
        do {
            let (manager, prior, _, good) = try await unreadableWithInterruptedTurn()
            let held = user("QI3 held acknowledged request")
            await manager._testDispatchUser(held)
            let queued = try Data(contentsOf: queueFileURL)
            chmod(0o000, queueFileURL)
            let broken = await restart()
            broken._testStartupPasses()
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("must not run")])
            let partial = await restart()
            partial._testStartupPasses()
            _ = await partial._testAwaitIdle(timeout: 3)
            let problem = partial._testHeldQueueProblem
            check("QI3a history-only repair keeps the permission-unreadable queue byte for byte; nothing runs",
                  bytesAfterRestoringMode(queueFileURL) == queued && problem != nil && server.completeRequests.isEmpty,
                  "requests \(server.completeRequests.count)")
            server.clear()
            server.script([Self.chatText("answering both")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("QI3b queue readable + restart: one request, earlier request then the held one",
                  server.completeRequests.count == 1 && ordered(requestBodies().first ?? "", [prior.content, held.content])
                    && repaired._testMessages.filter { $0.id == held.id }.count == 1)
        }
        // QI4: /stop with readable history and an unreadable queue file:
        // every message in it predates the stop → conservative hold.
        do {
            let (_, held, goodQueue) = try await healthyWithHeldQueue("QI4")
            try Data("{ undecodable".utf8).write(to: queueFileURL)
            let next = await restart()
            next._testStartupPasses()
            await next._testStop()
            let entries = StopMarkerStore.load().entries
            check("QI4a /stop records the conservative hold for the unreadable queue", entries.count == 1 && entries[0].heldUnreadableQueue == true)
            try goodQueue.write(to: queueFileURL)
            server.clear()
            server.script([Self.chatText("must not run")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("QI4b repair: the held message reaches history with its note, nothing runs",
                  server.completeRequests.isEmpty && repaired._testMessages.contains { $0.id == held.id }
                    && repaired._testMessages.contains { $0.content.contains("sent before /stop") },
                  "requests \(server.completeRequests.count)")
        }
        // QI5: background results are new work — owed, unpublished, while
        // the queue file is unreadable (from the very first job pass in
        // init); published once when it no longer is.
        do {
            _ = await freshManager(history: [user("QI5 earlier answered request")])
            let record = Self.record()
            try DetachedJobStore.create(record)
            try Data("{ undecodable".utf8).write(to: queueFileURL)
            server.clear()
            server.script([Self.chatText("must not run")])
            let next = await restart()
            next._testStartupPasses()
            _ = await next._testAwaitIdle(timeout: 3)
            check("QI5a unreadable queue: the background result stays owed and unpublished, no wake, no request",
                  records().contains { $0.jobId == record.jobId && $0.completion == .owed }
                    && !next._testMessages.contains { $0.id == record.completionMessageId }
                    && next._testRecoveredWakeTrigger == nil && server.completeRequests.isEmpty)
            try? FileManager.default.removeItem(at: queueFileURL)   // moved aside by the user
            server.clear()
            server.script([Self.chatText("reacting to the result")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("QI5b file moved aside + restart: problem cleared, the result is published once",
                  repaired._testHeldQueueProblem == nil
                    && repaired._testMessages.filter { $0.id == record.completionMessageId }.count == 1)
        }
        // QI6: /deleteuserdata is the explicit discard.
        do {
            _ = await freshManager(history: [user("QI6 history")])
            try Data("{ undecodable".utf8).write(to: queueFileURL)
            let next = await restart()
            next._testStartupPasses()
            let before = next._testHeldQueueProblem != nil
            _ = await next.deleteAllMemory()
            check("QI6 /deleteuserdata discards the unreadable queue file and clears the problem",
                  before && next._testHeldQueueProblem == nil && !FileManager.default.fileExists(atPath: queueFileURL.path))
            try configureProvider()
        }
        await resetState()
    }

    // MARK: R2 — stop entries settle only on the current marker state

    func stopMarkerSettlementSection() async throws {
        // SM1: decode variant of the reported sequence — the named marker is
        // undecodable at the next startup. The entry must survive that
        // startup's stop pass; the resume pass then removes the undecodable
        // marker (pre-existing poison rule — it can never resume), so at the
        // following startup the marker is KNOWN absent and the entry retires.
        do {
            let (manager, prior, _, good) = try await unreadableWithInterruptedTurn()
            await manager._testStop()
            try Data("{ marker undecodable".utf8).write(to: manager._testActiveTurnMarkerURL)
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("must not resume")])
            let partial = await restart()
            partial._testStopPassOnly()
            check("SM1a undecodable marker: the stop pass keeps the named entry",
                  StopMarkerStore.load().stoppedTriggerIds.contains(prior.id), "entries \(StopMarkerStore.load().entries.count)")
            partial._testStartupPasses()
            _ = await partial._testAwaitIdle(timeout: 3)
            let again = await restart()
            again._testStartupPasses()
            _ = await again._testAwaitIdle(timeout: 3)
            let retired = await waitUntil(timeout: 5) { StopMarkerStore.load() == .none }
            check("SM1b nothing resumes; once the marker is known absent the entry retires",
                  server.completeRequests.isEmpty && retired && markerBytes(again) == nil,
                  "requests \(server.completeRequests.count)")
        }
        // SM2: readable history throughout; /stop names the marker; the
        // marker is permission-unreadable at the next startup.
        do {
            let prior = user("SM2 interrupted request")
            let manager = await freshManager(history: [prior])
            manager._testWriteActiveTurnMarker(for: prior)
            await manager._testStop()
            check("SM2-pre /stop names the interrupted request", StopMarkerStore.load().stoppedTriggerIds.contains(prior.id))
            // Crash before the startup stop pass could clear the marker.
            chmod(0o000, manager._testActiveTurnMarkerURL)
            server.clear()
            let next = await restart()
            next._testStartupPasses()
            _ = await next._testAwaitIdle(timeout: 3)
            check("SM2a permission-unreadable marker: the entry stays", StopMarkerStore.load().stoppedTriggerIds.contains(prior.id))
            chmod(0o600, next._testActiveTurnMarkerURL)
            server.clear()
            server.script([Self.chatText("must not resume")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            let retired = await waitUntil(timeout: 5) { StopMarkerStore.load() == .none }
            check("SM2b readable again: not resumed; entry retires", server.completeRequests.isEmpty && retired,
                  "requests \(server.completeRequests.count)")
        }
        // SM0 control: healthy storage — the named entry retires at the next
        // startup, and a post-stop message is answered normally.
        do {
            let prior = user("SM0 interrupted request")
            let manager = await freshManager(history: [prior])
            manager._testWriteActiveTurnMarker(for: prior)
            await manager._testStop()
            server.clear()
            server.script([Self.chatText("post-stop reply")])
            let next = await restart()
            next._testStartupPasses()
            let retired = await waitUntil(timeout: 5) { StopMarkerStore.load() == .none }
            check("SM0a control: healthy restart clears the marker and retires the entry, nothing resumed",
                  retired && markerBytes(next) == nil && server.completeRequests.isEmpty)
            await next._testDispatchUser(user("SM0 sent after stop"))
            _ = await next._testAwaitIdle()
            check("SM0b control: a post-stop message is answered once", server.completeRequests.count == 1,
                  "requests \(server.completeRequests.count)")
        }
        await resetState()
    }
}
