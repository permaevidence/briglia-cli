import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Round-5 rows: the durable held queue survives restarts while history is
/// still unreadable (hydrated into memory, merged, never replaced when it
/// can't be read), and /stop covers every held message plus the preserved
/// interrupted request — with conservative dispositions when the queue
/// file or the active-turn marker can't be read.
extension MidturnHarness {

    private var heldQueueNoFileURL: URL { StoragePaths.dataRoot.appendingPathComponent("pending_midturn.json") }

    private func memoryIds(_ manager: ConversationManager) -> [UUID] { manager._testQueue.map(\.id) }

    private func setMode(_ mode: Int16, _ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    // MARK: Reproductions of the reported sequences (kept permanently)

    func heldQueueReproSection() async throws {
        // Control: two submissions without restarting preserve order.
        do {
            let (manager, _, _, _) = try await unreadableWithInterruptedTurn()
            let a = user("C4 first held request")
            let b = user("C4 second held request")
            await manager._testDispatchUser(a)
            await manager._testDispatchUser(b)
            check("C4-control same-process queue retains both", queuedIds(manager) == [a.id, b.id])
        }
        // A restart with history still unreadable must not let the next
        // held message replace the acknowledged queue of the earlier process.
        do {
            let (manager, _, marker, good) = try await unreadableWithInterruptedTurn()
            let a = user("C4 first acknowledged held request")
            await manager._testDispatchUser(a)
            let next = await restart()
            next._testStartupPasses()
            check("C4A unreadable restart keeps the original queue file", queuedIds(next) == [a.id])
            let b = user("C4 second acknowledged held request")
            await next._testDispatchUser(b)
            check("C4B new hold after unreadable restart preserves BOTH acknowledged messages", queuedIds(next) == [a.id, b.id], "queue count: \(queuedIds(next).count)")
            check("C4C marker and corrupt history remain intact", markerBytes(next) == marker && (try? Data(contentsOf: holdHistoryURL)) == Self.unreadable)
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("repaired")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("C4D repair answers both acknowledged held messages", repaired._testMessages.contains { $0.id == a.id } && repaired._testMessages.contains { $0.id == b.id })
        }
        // A stop issued in the unreadable restarted process covers messages
        // acknowledged before that restart.
        do {
            let (manager, _, _, good) = try await unreadableWithInterruptedTurn()
            let a = user("C4 held request stopped after restart")
            await manager._testDispatchUser(a)
            let next = await restart()
            next._testStartupPasses()
            await next._testStop()
            check("C4E stop records the held message from the previous process", StopMarkerStore.load().heldMessageIds.contains(a.id))
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("must not run")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("C4F repair after stop does not run held work", server.completeRequests.isEmpty, "requests: \(server.completeRequests.count)")
        }
        // No intermediate restart: /stop covers the queued message AND the
        // earlier interrupted trigger it is preserving.
        do {
            let (manager, prior, _, good) = try await unreadableWithInterruptedTurn()
            let a = user("C4 same-process held request before stop")
            await manager._testDispatchUser(a)
            await manager._testStop()
            check("C4G control same-process stop records held message", StopMarkerStore.load().heldMessageIds.contains(a.id))
            check("C4H stop also covers the preserved interrupted-turn marker", StopMarkerStore.load().stoppedTriggerIds.contains(prior.id))
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("must not resume prior stopped work")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("C4I repair after same-process stop must not resume interrupted work", server.completeRequests.isEmpty, "requests: \(server.completeRequests.count)")
        }
        await resetState()
    }

    // MARK: Held-queue durability across restarts

    func heldQueueDurabilitySection() async throws {
        // HQ1: two unreadable restarts, order and stable-id dedup kept;
        // memory mirrors the file; /status counts all; repair answers all
        // three in one request, in order, after the earlier request.
        do {
            let (manager, _, _, good) = try await unreadableWithInterruptedTurn()
            let a = user("HQ1 held A"), b = user("HQ1 held B"), c = user("HQ1 held C")
            await manager._testDispatchUser(a)
            let second = await restart()
            second._testStartupPasses()
            check("HQ1a restart hydrates the held queue into memory (not history)",
                  memoryIds(second) == [a.id] && !second._testMessages.contains { $0.id == a.id })
            await second._testDispatchUser(b)
            let third = await restart()
            third._testStartupPasses()
            await third._testDispatchUser(c)
            await third._testDispatchUser(b)   // re-delivery of an already held message
            check("HQ1b two unreadable restarts: file keeps A, B, C in order, B once",
                  queuedIds(third) == [a.id, b.id, c.id], "\(queuedIds(third).count) queued")
            check("HQ1c memory mirrors the file", memoryIds(third) == queuedIds(third))
            let status = await third._testBackgroundStatus() ?? ""
            check("HQ1d /status counts every held message, including earlier processes'",
                  status.contains("3 messages held"), status)
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("answering the held requests")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            let body = requestBodies().first ?? ""
            let order = ["previous interrupted request", "HQ1 held A", "HQ1 held B", "HQ1 held C"].map { body.range(of: $0)?.lowerBound }
            let ordered = !order.contains(where: { $0 == nil }) && zip(order, order.dropFirst()).allSatisfy { $0! < $1! }
            check("HQ1e repair: exactly one request, earlier request then A, B, C",
                  server.completeRequests.count == 1 && ordered, "requests \(server.completeRequests.count)")
            let ids = repaired._testMessages.map(\.id)
            check("HQ1f each held message in history exactly once; queue file gone",
                  [a.id, b.id, c.id].allSatisfy { id in ids.filter { $0 == id }.count == 1 }
                    && !FileManager.default.fileExists(atPath: heldQueueNoFileURL.path))
        }
        // HQ2: an undecodable queue file is never replaced; intake refused
        // (Telegram: unconfirmed stall; app: refused); /status says so.
        do {
            let (manager, _, _, _) = try await unreadableWithInterruptedTurn()
            await manager._testDispatchUser(user("HQ2 acknowledged before corruption"))
            let garbage = Data("{ not a queue".utf8)
            try garbage.write(to: heldQueueNoFileURL)
            let next = await restart()
            next._testStartupPasses()
            check("HQ2a startup records the unreadable queue file", next._testHeldQueueProblem != nil)
            let incoming = user("HQ2 arrives while the queue file is undecodable")
            await next._testDispatchUser(incoming)
            check("HQ2b Telegram intake refused: update left unconfirmed, file bytes unchanged, not queued",
                  next._testInboundDurabilityFailure && (try? Data(contentsOf: heldQueueNoFileURL)) == garbage
                    && !next._testQueue.contains { $0.id == incoming.id })
            let outcome = await next.sendFromApp(text: "HQ2 app message", attachments: [], policy: .appSocket)
            var refused = false
            if case .refused = outcome { refused = true }
            check("HQ2c app intake refused, file bytes unchanged", refused && (try? Data(contentsOf: heldQueueNoFileURL)) == garbage, "\(outcome)")
            let status = await next._testBackgroundStatus() ?? ""
            check("HQ2d /status reports the unreadable held-message file", status.contains("held-message file can't be read"), status)
            try? FileManager.default.removeItem(at: heldQueueNoFileURL)
        }
        // HQ3: a queue file that exists but can't be read (permissions) is
        // likewise kept and intake refused; once readable again, holds merge.
        // Root reads a mode-000 file, so this row needs an unprivileged user
        // (the Linux CI container runs as root; the decode variant HQ2 covers it there).
        if geteuid() == 0 {
            print("  (HQ3 skipped: running as root, file permissions do not deny reads)")
        } else {
            let (manager, _, _, _) = try await unreadableWithInterruptedTurn()
            let a = user("HQ3 held before the file became unreadable")
            await manager._testDispatchUser(a)
            let before = try Data(contentsOf: heldQueueNoFileURL)
            setMode(0o000, heldQueueNoFileURL)
            let next = await restart()
            next._testStartupPasses()
            let b = user("HQ3 arrives while unreadable")
            await next._testDispatchUser(b)
            setMode(0o600, heldQueueNoFileURL)
            check("HQ3a unreadable (permissions) queue file kept byte-for-byte; intake refused",
                  (try? Data(contentsOf: heldQueueNoFileURL)) == before && next._testInboundDurabilityFailure
                    && !next._testQueue.contains { $0.id == b.id })
            next._testClearInboundDurabilityFailure()
            let c = user("HQ3 after the file reads again")
            await next._testDispatchUser(c)
            check("HQ3b once readable, a new hold merges: A then C", queuedIds(next) == [a.id, c.id] && next._testHeldQueueProblem == nil)
        }
        // HQ4: a failed queue write preserves every earlier entry on disk
        // and in memory; the next successful hold appends.
        do {
            let (manager, _, _, _) = try await unreadableWithInterruptedTurn()
            let a = user("HQ4 held A")
            await manager._testDispatchUser(a)
            let next = await restart()
            next._testStartupPasses()
            ConversationManager.heldQueueWriteFaultForTesting = true
            let b = user("HQ4 write fails")
            await next._testDispatchUser(b)
            ConversationManager.heldQueueWriteFaultForTesting = false
            check("HQ4a failed write: update unconfirmed, file and memory still exactly [A]",
                  next._testInboundDurabilityFailure && queuedIds(next) == [a.id] && memoryIds(next) == [a.id])
            next._testClearInboundDurabilityFailure()
            let c = user("HQ4 next hold")
            await next._testDispatchUser(c)
            check("HQ4b the next hold appends: [A, C]", queuedIds(next) == [a.id, c.id])
        }
        // HQ0 control: healthy storage — a queued mid-turn file is still
        // consumed normally at startup (one request, file removed).
        do {
            let healthy = await freshManager()
            let queued = user("HQ0 queued before a healthy restart")
            healthy._testPersistQueue([queued])
            server.clear()
            server.script([Self.chatText("healthy recovery reply")])
            let next = await restart()
            next._testStartupPasses()
            _ = await next._testAwaitIdle()
            check("HQ0 control: healthy restart consumes the queue file and answers it once",
                  server.completeRequests.count == 1 && next._testMessages.contains { $0.id == queued.id }
                    && !FileManager.default.fileExists(atPath: heldQueueNoFileURL.path))
        }
        await resetState()
    }

    // MARK: /stop over recovery-held work

    func heldQueueStopSection() async throws {
        // HS1: /stop after an unreadable restart covers earlier-process
        // held messages and the preserved trigger; a post-stop message is
        // still answered after repair; the entries retire once settled.
        do {
            let (manager, prior, _, good) = try await unreadableWithInterruptedTurn()
            let a = user("HS1 held before restart")
            await manager._testDispatchUser(a)
            let next = await restart()
            next._testStartupPasses()
            await next._testStop()
            let intent = StopMarkerStore.load()
            check("HS1a stop names the earlier-process held message and the preserved trigger",
                  intent.heldMessageIds.contains(a.id) && intent.stoppedTriggerIds.contains(prior.id))
            let d = user("HS1 sent after stop")
            await next._testDispatchUser(d)
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("answering the post-stop message")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            let body = requestBodies().first ?? ""
            check("HS1b repair: exactly one request, for the post-stop message; prior not resumed",
                  server.completeRequests.count == 1 && body.contains("HS1 sent after stop")
                    && repaired._testMessages.last?.content.contains("answering the post-stop message") == true,
                  "requests \(server.completeRequests.count)")
            check("HS1c the held message is in history with its pre-stop note",
                  repaired._testMessages.contains { $0.id == a.id }
                    && repaired._testMessages.contains { $0.content.contains("sent before /stop") })
            let retired = await waitUntil(timeout: 5) { StopMarkerStore.load() == .none }
            check("HS1d the stop entry retires once everything it names is settled", retired)
        }
        // HS2: the active-turn marker can't be read at /stop → conservative
        // disposition recorded; when it reads again after repair, the
        // interrupted turn is not resumed. Permission-based: needs a non-root user.
        if geteuid() == 0 {
            print("  (HS2 skipped: running as root, file permissions do not deny reads)")
        } else {
            let (manager, _, _, good) = try await unreadableWithInterruptedTurn()
            setMode(0o000, manager._testActiveTurnMarkerURL)
            await manager._testStop()
            setMode(0o600, manager._testActiveTurnMarkerURL)
            let entries = StopMarkerStore.load().entries
            check("HS2a unreadable marker at /stop: the entry carries the conservative turn disposition",
                  entries.count == 1 && entries[0].stoppedUnreadableTurnMarker == true && entries[0].stoppedTurnTriggerId == nil)
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("must not resume")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("HS2b repair: the interrupted turn is not resumed; marker cleared",
                  server.completeRequests.isEmpty && markerBytes(repaired) == nil, "requests \(server.completeRequests.count)")
            let retired = await waitUntil(timeout: 5) { StopMarkerStore.load() == .none }
            check("HS2c the conservative entry retires once the marker is gone", retired)
        }
        // HS3: the held-queue file can't be read at /stop → every queued
        // message up to the stop is held; after repair nothing runs.
        // Permission-based: needs a non-root user.
        if geteuid() == 0 {
            print("  (HS3 skipped: running as root, file permissions do not deny reads)")
        } else {
            let (manager, _, _, good) = try await unreadableWithInterruptedTurn()
            let a = user("HS3 held, file later unreadable")
            await manager._testDispatchUser(a)
            setMode(0o000, heldQueueNoFileURL)
            let next = await restart()
            next._testStartupPasses()
            await next._testStop()
            setMode(0o600, heldQueueNoFileURL)
            let entries = StopMarkerStore.load().entries
            check("HS3a unreadable queue at /stop: the entry carries the conservative hold disposition",
                  entries.count == 1 && entries[0].heldUnreadableQueue == true)
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("must not run")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("HS3b repair: the held message reaches history with its note, nothing runs",
                  server.completeRequests.isEmpty && repaired._testMessages.contains { $0.id == a.id }
                    && repaired._testMessages.contains { $0.content.contains("sent before /stop") },
                  "requests \(server.completeRequests.count)")
        }
        // HS0 controls: a healthy idle /stop with nothing preserved records
        // nothing; without /stop the preserved request still resumes (HH1k).
        do {
            let healthy = await freshManager()
            await healthy._testStop()
            check("HS0 control: healthy idle /stop records no entry", StopMarkerStore.load() == .none)
        }
        await resetState()
    }
}
