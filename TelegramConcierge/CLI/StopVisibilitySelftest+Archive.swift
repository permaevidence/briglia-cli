import Foundation

/// SV2 (slow archive), SV15 (archive.wait marker), SV6 (overlap and
/// attribution) and SV7 (two stopped runs) — the archive's summary request
/// is held at the loopback server, so the stopped run really waits in
/// `await archiveTask.value`.
extension StopVisibilityHarness {

    /// A thread-blocking gate for the loopback server's routing closure.
    final class ServerGate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var arrivals = 0
        private var released = false
        var arrived: Int { lock.lock(); defer { lock.unlock() }; return arrivals }
        func wait() {
            lock.lock()
            if released { lock.unlock(); return }
            arrivals += 1
            lock.unlock()
            semaphore.wait()
        }
        func release() {
            lock.lock()
            guard !released else { lock.unlock(); return }
            released = true
            let n = arrivals
            lock.unlock()
            for _ in 0..<n { semaphore.signal() }
        }
    }

    /// History large enough to trigger chunk archiving (~24k estimated
    /// tokens, threshold 20k at the default chunk size).
    func archiveSizedHistory() -> [Message] {
        let base = Date().addingTimeInterval(-86_400)
        return (0..<24).map { i in
            Message(role: i % 2 == 0 ? .user : .assistant,
                    content: ArchiveFullChunkSelftest.filler("old-\(i)", size: 4_000, sentinel: "end of old-\(i)."),
                    timestamp: base.addingTimeInterval(TimeInterval(i * 60)))
        }
    }

    /// Routes archive requests: the chunk summary waits on `gate`; fact
    /// extraction answers NO_CHANGES; everything else uses the script.
    func routeArchive(holdingSummaryOn gate: ServerGate) {
        let summary = (["Fixture summary of the archived segment."] + Array(repeating: "detail", count: 140)).joined(separator: " ")
        let summaryBody = MidturnHarness.chatText(summary)
        let noChanges = MidturnHarness.chatText("NO_CHANGES")
        let summaryMarker = ArchiveFullChunkSelftest.summaryMarker
        let extractionMarker = ArchiveFullChunkSelftest.extractionMarker
        server.concurrent = true
        server.router = { request in
            let system = ArchiveFullChunkSelftest.systemContent(request.body)
            if system.contains(summaryMarker) {
                gate.wait()
                return (summaryBody, 0)
            }
            if system.contains(extractionMarker) {
                return (noChanges, 0)
            }
            return nil
        }
    }

    func archiveSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let history = archiveSizedHistory()
        let manager = await freshManager(channel: channel, history: history)
        let gate = ServerGate()
        routeArchive(holdingSummaryOn: gate)
        server.script([MidturnHarness.chatText("answered after the archive")])
        manager._testStartTurn(for: user("a request that first archives"))
        guard let run = manager._svActiveRunId else { check("SV2 setup: turn started", false); gate.release(); return }
        let reached = await waitUntil(timeout: 20) { gate.arrived > 0 }
        check("SV2 setup: the stopped run waits in the archive (summary request held)",
              reached && { if case .archiveWait = manager._svRunPhase(run) { return true }; return false }())
        check("SV15 archive.wait marker is open during the wait",
              StageMarkers.openStages().contains { $0.stage == "archive.wait" && $0.callId == nil })
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { !channel.stopTexts.isEmpty }
        let reply = channel.stopTexts.first ?? ""
        check("SV2 reply: \"memory archiving continues (running …)\"",
              reply.hasPrefix("⛔ Stop requested. The request is still finishing: memory archiving continues (running ")
                && reply.hasSuffix("I'll notify you when it ends."), reply)
        let status = await manager.handleTerminalCommand("/status")?.joined(separator: "\n") ?? ""
        check("SV2 /status: the stopped request and, separately, \"Also running\" maintenance",
              status.contains("still finishing: memory archiving continues")
                && status.contains("Also running: memory archiving — summarizing older conversation"), status)
        await sleep(1)
        check("SV2 no completion while the archive still runs", channel.stopTexts.count == 1, "\(channel.stopTexts)")
        gate.release()
        _ = await manager._testAwaitIdle(timeout: 30)
        _ = await waitUntil(timeout: 15) { channel.stopTexts.count >= 2 }
        await sleep(0.5)
        let texts = channel.stopTexts
        check("SV2 release: exactly one completion, after the reply",
              texts.count == 2 && texts[1].hasPrefix("✅ The stopped request has ended."), "\(texts)")
        check("SV2 the archive was committed as today (archived messages left the live history)",
              !manager._testMessages.contains { $0.id == history[0].id }, "\(manager._testMessages.count) live messages")
        check("SV15 archive.wait marker closed after the wait",
              !StageMarkers.openStages().contains { $0.stage == "archive.wait" })
        server.router = nil
        server.concurrent = false
    }

    /// Run A stopped while waiting for the archive; a newer run B started,
    /// skipping the archive (cooldown) and held inside read_file.
    private func setUpOverlap(_ channel: SVRecordingChannel) async
        -> (manager: ConversationManager, gate: ServerGate, hold: SVToolHold, runA: UUID, runB: UUID)? {
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        let gate = ServerGate()
        routeArchive(holdingSummaryOn: gate)
        manager._testStartTurn(for: user("run A"))
        guard let runA = manager._svActiveRunId else { gate.release(); return nil }
        _ = await waitUntil(timeout: 20) { gate.arrived > 0 }
        _ = await timedStop(manager)
        manager._svSetArchiveBackoff(until: Date().addingTimeInterval(3_600))
        let hold = SVToolHold(tool: "read_file")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sv-newer.txt")
        try? "newer".write(to: scratch, atomically: true, encoding: .utf8)
        guard let runB = await startHeldTurn(manager, hold: hold, callId: "call-newer", tool: "read_file",
                                             args: ["file_path": scratch.path], label: "run B") else {
            hold.release(); gate.release(); return nil
        }
        return (manager, gate, hold, runA, runB)
    }

    /// SV6: A's text never names B's work; B's activity is never labelled
    /// as the stopped request; the socket activity shows both; B's own end
    /// sends no notice.
    func overlapSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        guard let (manager, gate, hold, runA, _) = await setUpOverlap(channel) else {
            check("SV6 setup", false); return
        }
        let describeA = manager.describeStillFinishing(runId: runA)
        check("SV6 the stopped run's text names only its own work (archive), never the newer run's tool",
              describeA.hasPrefix("memory archiving continues") && !describeA.contains("read_file"), describeA)
        let lines = manager.stoppedRunStatusLines()
        check("SV6 /status: one stopped request, plus a separate \"Also running\" line",
              lines.count == 2 && lines[0].contains("memory archiving continues") && !lines[0].contains("read_file")
                && lines[1].hasPrefix("Also running: memory archiving"), "\(lines)")
        let current = manager.turnActivity.map { AppChatSocketServer.activityDescription($0, privacy: false) }
        let suffix = manager.stoppedRunActivitySuffix(privacy: false)
        let composed = AppChatSocketServer.composedActivity(current: current, stopped: suffix) ?? ""
        check("SV6 socket activity carries both the newer turn and the stopped request",
              composed.contains("read_file") && composed.contains("stopped request still finishing: memory archiving"), composed)
        check("SV6 the newer turn's activity is never labelled as the stopped request", !(suffix ?? "").contains("read_file"),
              suffix ?? "nil")
        let privateSuffix = manager.stoppedRunActivitySuffix(privacy: true) ?? ""
        check("SV6 privacy mode: the stopped part shows no stage label",
              privateSuffix.hasPrefix("stopped request still finishing (") && !privateSuffix.contains("archiving"), privateSuffix)
        server.script([MidturnHarness.chatText("newer run finished")])
        hold.release()
        gate.release()
        _ = await manager._testAwaitIdle(timeout: 30)
        _ = await waitUntil(timeout: 20) { manager.stoppedRunsFinishing.isEmpty }
        await sleep(1.5)
        let texts = channel.stopTexts
        check("SV6 exactly one completion (the stopped run's); the newer turn's end sends none",
              texts.count == 2 && texts[1].hasPrefix("✅"), "\(texts)")
        server.router = nil
        server.concurrent = false
    }

    /// SV7: both A and B stopped while finishing: two entries, two stage
    /// texts, two series, two completions.
    func twoStoppedSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        guard let (manager, gate, hold, runA, runB) = await setUpOverlap(channel) else {
            check("SV7 setup", false); return
        }
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.stopTexts.count >= 2 }
        let replies = channel.stopTexts
        check("SV7 two stopped runs: two entries", manager.stoppedRunsFinishing.count == 2,
              "\(manager.stoppedRunsFinishing.count)")
        check("SV7 each reply has its own stage text",
              replies.count == 2 && replies[0].contains("memory archiving continues") && replies[1].contains("read_file")
                && !replies[1].contains("archiving"), "\(replies)")
        check("SV7 each run has its own series",
              Set(manager._svSeries(ofRun: runA).values).union(manager._svSeries(ofRun: runB).values).count == 2)
        hold.release()
        gate.release()
        _ = await manager._testAwaitIdle(timeout: 30)
        _ = await waitUntil(timeout: 20) { channel.stopTexts.count >= 4 }
        await sleep(1)
        let texts = channel.stopTexts
        check("SV7 two completions, after both replies",
              texts.count == 4 && texts.prefix(2).allSatisfy { $0.hasPrefix("⛔") } && texts.suffix(2).allSatisfy { $0.hasPrefix("✅") },
              "\(texts)")
        check("SV7 both entries cleared", manager.stoppedRunsFinishing.isEmpty)
        server.router = nil
        server.concurrent = false
    }
}
