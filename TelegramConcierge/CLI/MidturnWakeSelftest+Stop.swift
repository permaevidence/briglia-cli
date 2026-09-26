import Foundation

/// /stop rows (§3.9, owner decisions B/B1, O-S1 default).
extension MidturnHarness {

    func stopSection() async throws {
        try await stopKillsAndHolds()
        try await stopRepeatedAppends()
        try await stopMarkerFailureStillStops()
    }

    /// S1–S6, S9: T-STOP-5 fixed; B1 long-lived job killed; completed-but-
    /// undrained and running jobs appended without waking; a pre-stop
    /// queued message kept (unchanged) with its note, not answered; a fresh
    /// post-stop message starts work; a new user turn does not clear the
    /// stopped disposition.
    private func stopKillsAndHolds() async throws {
        let manager = await freshManager()
        manager._testSetPolling(true)
        defer { manager._testSetPolling(false) }
        // Turn 1: a long-lived background job (wait_seconds=0) and a ticker
        // with a regex watch whose matches stay queued (drains run only
        // when idle, and none runs before the /stop below).
        let hold = RequestHold(held: [2])
        server.requestObserver = { _ in hold.observe() }
        server.script([
            Self.chatTools([(id: "call-s0", name: "bash", args: ["command": "sleep 60", "wait_seconds": 0, "description": "dev server"]),
                            (id: "call-s0t", name: "bash", args: ["command": "while true; do echo tick; sleep 0.1; done", "wait_seconds": 0])]),
        ])
        manager._testStartTurn(for: user("start the dev server"))
        _ = await waitUntil { hold.arrived(2) }
        let started = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
        guard let longLived = started.first(where: { $0.command == "sleep 60" }),
              let ticker = started.first(where: { $0.command.contains("tick") }) else {
            hold.release(2); server.requestObserver = nil
            check("S0 long-lived jobs running", false); return
        }
        server.script([
            Self.chatTools([(id: "call-s0w", name: "bash_manage", args: ["mode": "watch", "handle": ticker.handle, "pattern": "tick", "limit": 1000])]),
            Self.chatText("server started"),
        ])
        hold.release(2)
        _ = await manager._testAwaitIdle(timeout: 20)
        server.requestObserver = nil
        try? await Task.sleep(nanoseconds: 400_000_000)  // let matches queue
        check("S0 explicit background launch recorded (moved binding, background record)",
              records().first { $0.jobId == longLived.jobUUID }?.launch == .background
                && results(manager).first { $0.toolCallId == "call-s0" }?.outcomeBinding?.kind == .moved)
        // Turn 2: a finished-but-undrained job and a running wait; a user
        // message queued; then /stop before its grace passes.
        server.script([
            Self.chatTools([(id: "call-s1", name: "bash", args: ["command": "true", "wait_seconds": 0]),
                            (id: "call-s2", name: "bash", args: ["command": "sleep 30", "wait_seconds": 60])]),
            Self.chatText("should never be requested"),
        ])
        let trigger = user("do the work")
        manager._testStartTurn(for: trigger)
        _ = await waitUntil { await BackgroundProcessRegistry.shared.runningMainOwnedJobs().contains { $0.command == "sleep 30" } }
        let preStop = user("message sent before stop")
        await manager._testDispatchUser(preStop)
        let requestsBeforeStop = server.completeRequests.count
        await manager._testStop()
        _ = await manager._testAwaitIdle(timeout: 20)
        let running = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
        check("S6 B1: /stop killed every main-owned job, including the long-lived one", running.isEmpty,
              "\(running.map(\.handle))")
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 10)
        let stoppedNotices = manager._testMessages.filter { $0.kind == .bashComplete && $0.content.contains("[Stopped by /stop") }
        check("S1 T-STOP-5 fixed: completions of stopped jobs appended, no turn started",
              stoppedNotices.count >= 3 && server.completeRequests.count == requestsBeforeStop,
              "notices \(stoppedNotices.count), requests \(server.completeRequests.count) vs \(requestsBeforeStop)")
        check("S2 the completed-but-undrained job's notice is held too",
              stoppedNotices.contains { $0.content.contains("command: true") },
              manager._testMessages.map { "[\($0.kind.rawValue)] " + String($0.content.prefix(120)).replacingOccurrences(of: "\n", with: " | ") }.joined(separator: "\n   "))
        let history = manager._testMessages
        let heldIndex = history.firstIndex { $0.id == preStop.id }
        let marker = StopMarkerStore.load()
        var noteId: UUID?
        if case .known(let entries) = marker { noteId = entries.first?.heldNoteMessageId }
        else if let n = history.first(where: { $0.content.hasPrefix("[Harness note] The message(s) above were sent before /stop") }) { noteId = n.id }
        let noteIndex = history.firstIndex { $0.id == noteId }
        check("S4 pre-stop message kept unchanged, followed by its harness note, not answered",
              heldIndex != nil && noteIndex != nil && noteIndex! > heldIndex!
                && history[heldIndex!].content == "message sent before stop"
                && server.completeRequests.count == requestsBeforeStop)
        check("S3 pending watch matches of a stopped job appended without waking",
              manager._testMessages.contains { $0.content.hasPrefix("[BASH WATCH MATCH]") && $0.content.contains("[Stopped by /stop") })
        check("S3b stopped jobs stay tracked as stopped (not cleared by later turns)",
              manager._testStoppedJobIds.contains(longLived.jobUUID))
        // S5 + S9: a fresh post-stop message starts work; an old stopped
        // job's queued notice drained after it still does not wake.
        server.script([Self.chatText("hello again")])
        await manager._testDispatchUser(user("new request after stop"))
        _ = await manager._testAwaitIdle(timeout: 20)
        check("S5 a fresh post-stop message starts a turn", server.completeRequests.count == requestsBeforeStop + 1)
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 5)
        check("S9 after a new user turn, stopped items still never start work",
              server.completeRequests.count == requestsBeforeStop + 1 && manager._testStoppedJobIds.isSuperset(of: []))
        // S14: the entry retires once every item it lists is settled.
        _ = await waitUntil(timeout: 5) { StopMarkerStore.load() == .none }
        check("S14 stop entry retired after durable settlement of all its items", StopMarkerStore.load() == .none)
    }

    /// S7: repeated /stop appends an entry instead of overwriting.
    private func stopRepeatedAppends() async throws {
        let manager = await freshManager()
        StopMarkerStore.faultForTesting = nil
        for i in 1...2 {
            server.script([
                Self.chatTools([(id: "call-r\(i)", name: "bash", args: ["command": "sleep 20", "wait_seconds": 60])]),
                Self.chatText("never"),
            ])
            manager._testStartTurn(for: user("stop me \(i)"))
            _ = await waitForRunningJob()
            await manager._testStop()
            _ = await manager._testAwaitIdle(timeout: 20)
        }
        var count = 0
        if case .known(let entries) = StopMarkerStore.load() { count = entries.count }
        check("S7 repeated /stop appends a second entry (earlier trigger and held sets kept)", count == 2, "entries \(count)")
        await manager._testIdleDrains()
    }

    /// S8: a marker write failure never refuses the stop.
    private func stopMarkerFailureStillStops() async throws {
        let manager = await freshManager()
        struct Injected: Error {}
        StopMarkerStore.faultForTesting = { _ in throw Injected() }
        defer { StopMarkerStore.faultForTesting = nil }
        server.script([
            Self.chatTools([(id: "call-m1", name: "bash", args: ["command": "sleep 20", "wait_seconds": 60])]),
            Self.chatText("never"),
        ])
        manager._testStartTurn(for: user("stop despite storage"))
        _ = await waitForRunningJob()
        await manager._testStop()
        let idle = await manager._testAwaitIdle(timeout: 20)
        let running = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
        check("S8 marker write failure → still stops (turn cancelled, jobs killed, no marker)",
              idle && running.isEmpty && StopMarkerStore.load() == .none)
        await manager._testIdleDrains()
    }
}
