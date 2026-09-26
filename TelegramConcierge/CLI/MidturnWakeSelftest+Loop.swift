import Foundation

/// Real-manager bash wake rows (§3.4, §3.10, §3.11): the production tool
/// loop, a scripted loopback provider, real bash jobs.
extension MidturnHarness {

    func loopSection() async throws {
        try await loopMovedDetach()
        try await loopShortCallReturnsReal()
        try await loopNoLedgerStrikeAndReceipt()
        try await loopRecordFailureKeepsWaiting()
        try await loopDefaultPolicyDeadline()
        try await loopAppEnqueueSite()
    }

    /// L1: a user message during a long bash wait moves the job to the
    /// background after the grace; the model reads the message now; the
    /// completion is delivered later exactly once, under the record's id.
    private func loopMovedDetach() async throws {
        let manager = await freshManager()
        server.script([
            Self.chatTools([(id: "call-l1", name: "bash", args: ["command": "sleep 4; echo long-done", "wait_seconds": 60])]),
            Self.chatText("answered your question; the build continues"),
            Self.chatText("the build finished"),
        ])
        let t0 = Date()
        manager._testStartTurn(for: user("run the long build"))
        guard let job = await waitForRunningJob() else { check("L1 long job started", false); return }
        await manager._testDispatchUser(user("quick question while you work"))
        let idle = await manager._testAwaitIdle(timeout: 30)
        let turnSeconds = Date().timeIntervalSince(t0)
        let result = results(manager).first { $0.toolCallId == "call-l1" }
        let payload = parse(result?.content ?? "")
        check("L1a turn ended before the job (early wake, not the 4 s wait)", idle && turnSeconds < 3.5, "\(turnSeconds)s")
        check("L1b moved result: moved_to_background + wake_reason user_message + running",
              payload["moved_to_background"] as? Bool == true && payload["wake_reason"] as? String == "user_message"
                && payload["status"] as? String == "running", "\(payload)")
        check("L1c moved message states the continuation and idle-only delivery",
              (payload["message"] as? String ?? "").contains("because a user message arrived")
                && (payload["message"] as? String ?? "").contains("once you are idle after this turn"))
        check("L1d result bound moved to the job with the launch fingerprint",
              result?.outcomeBinding?.kind == .moved && result?.outcomeBinding?.jobId == job.jobUUID
                && result?.outcomeBinding?.fingerprint != nil)
        let record = records().first { $0.jobId == job.jobUUID }
        check("L1e crash record written before return (wakeDetached, owed, call id, anchor)",
              record?.launch == .wakeDetached && record?.completion == .owed && record?.toolCallId == "call-l1"
                && record?.historyAnchorMessageId != nil)
        let second = requestBodies().dropFirst().first ?? ""
        check("L1f next request carries the user's message in the direct-user block",
              second.contains("[Direct user message 1 of 1]") && second.contains("quick question while you work"))
        check("L1g wake note lists the moved job as harness status",
              second.contains("[Harness status — not from the user. Still running: • bash \(job.handle)")
                && second.contains("moved to the background"))
        let stillRunning = await BackgroundProcessRegistry.shared.runningMainOwnedJobs().contains { $0.jobUUID == job.jobUUID }
        check("L1h the job kept running after the turn ended", stillRunning)
        // Completion: delivered once, under the record's pre-minted id.
        _ = await waitUntil(timeout: 10) { await BackgroundProcessRegistry.shared.settlementInfo(uuid: job.jobUUID).settled }
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 30)
        let notices = manager._testMessages.filter { $0.id == record?.completionMessageId }
        check("L1i completion delivered once under the record's completion id, wakes a turn",
              notices.count == 1 && (notices.first?.content.contains("[BACKGROUND BASH COMPLETE]") ?? false)
                && notices.first?.content.contains("long-done") == true && server.completeRequests.count == 3)
        await manager._testIdleDrains()
        let again = manager._testMessages.filter { $0.id == record?.completionMessageId }.count
        check("L1j a second drain adds nothing; the record retired after the durable save",
              again == 1 && !records().contains { $0.jobId == job.jobUUID })
    }

    /// L2: a call shorter than the grace returns its real result.
    private func loopShortCallReturnsReal() async throws {
        let manager = await freshManager()
        server.script([
            Self.chatTools([(id: "call-l2", name: "bash", args: ["command": "sleep 0.3; echo quick-done"])]),
            Self.chatText("done"),
        ])
        manager._testStartTurn(for: user("quick one"))
        _ = await waitForRunningJob(timeout: 5)
        await manager._testDispatchUser(user("and another thing"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let result = results(manager).first { $0.toolCallId == "call-l2" }
        let payload = parse(result?.content ?? "")
        check("L2 a call shorter than the grace returns its real result (no wake fields, no record)",
              payload["wake_reason"] == nil && (result?.content.contains("quick-done") ?? false)
                && result?.outcomeBinding == nil && records().isEmpty, "\(payload)")
    }

    /// L3: no ledger strike on a woken wait; a later wait in the same turn
    /// is admitted, observes the settlement (receipt) and the notice is
    /// never delivered — the record settles as receiptObserved.
    private func loopNoLedgerStrikeAndReceipt() async throws {
        let manager = await freshManager()
        server.script([
            Self.chatTools([(id: "call-l3", name: "bash", args: ["command": "sleep 3; echo l3-done", "wait_seconds": 60])]),
        ])
        manager._testStartTurn(for: user("start it"))
        guard let job = await waitForRunningJob() else { check("L3 job started", false); return }
        server.script([
            Self.chatTools([(id: "call-l3w", name: "bash_manage", args: ["mode": "wait", "handle": job.handle, "wait_seconds": 20])]),
            Self.chatText("it finished"),
        ])
        await manager._testDispatchUser(user("status?"))
        _ = await manager._testAwaitIdle(timeout: 40)
        let wait = results(manager).first { $0.toolCallId == "call-l3w" }
        let payload = parse(wait?.content ?? "")
        check("L3a no ledger strike: the later wait on the woken handle was admitted and settled",
              payload["wait_refused"] == nil && payload["status"] as? String == "exited", "\(payload)")
        check("L3b the settled wait is bound receiptObserved for the job (no fingerprint)",
              wait?.outcomeBinding?.kind == .receiptObserved && wait?.outcomeBinding?.jobId == job.jobUUID
                && wait?.outcomeBinding?.fingerprint == nil)
        await manager._testIdleDrains()
        let notices = manager._testMessages.filter { $0.content.contains("[BACKGROUND BASH COMPLETE]") }
        check("L3c the observed completion is never delivered; its record retired",
              notices.isEmpty && !records().contains { $0.jobId == job.jobUUID })
    }

    /// L4: if the crash record cannot be written, the woken wait is NOT
    /// ended — the call keeps waiting and returns the real result.
    private func loopRecordFailureKeepsWaiting() async throws {
        let manager = await freshManager()
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { label in if label == "create" { throw Injected() } }
        server.script([
            Self.chatTools([(id: "call-l4", name: "bash", args: ["command": "sleep 2; echo l4-done", "wait_seconds": 60])]),
            Self.chatText("ok"),
        ])
        manager._testStartTurn(for: user("go"))
        _ = await waitForRunningJob()
        await manager._testDispatchUser(user("hello?"))
        _ = await manager._testAwaitIdle(timeout: 30)
        DetachedJobStore.faultForTesting = nil
        let result = results(manager).first { $0.toolCallId == "call-l4" }
        let payload = parse(result?.content ?? "")
        check("L4 record-write failure → no detach: the call kept waiting and returned the real result",
              payload["moved_to_background"] == nil && payload["status"] as? String == "exited"
                && result?.outcomeBinding == nil && BashTools.lastRecordFailure != nil && records().isEmpty, "\(payload)")
        let second = requestBodies().dropFirst().first ?? ""
        check("L4b the message still reached the model after the batch", second.contains("hello?"))
    }

    /// L5: a woken default quick command still dies at its execution
    /// deadline, and the moved result says so.
    private func loopDefaultPolicyDeadline() async throws {
        let manager = await freshManager()
        BashTools.quickDefaultSeconds = 3
        server.script([
            Self.chatTools([(id: "call-l5", name: "bash", args: ["command": "sleep 30"])]),
            Self.chatText("ok"),
            Self.chatText("noted"),
        ])
        manager._testStartTurn(for: user("default command"))
        guard let job = await waitForRunningJob() else { check("L5 job started", false); return }
        await manager._testDispatchUser(user("ping"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let payload = parse(results(manager).first { $0.toolCallId == "call-l5" }?.content ?? "")
        check("L5a woken default command: moved, and still killed at its 3-second deadline",
              payload["moved_to_background"] as? Bool == true
                && (payload["message"] as? String ?? "").contains("killed at its 3-second execution deadline"), "\(payload)")
        _ = await waitUntil(timeout: 10) { await BackgroundProcessRegistry.shared.settlementInfo(uuid: job.jobUUID).settled }
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 20)
        let notice = manager._testMessages.first { $0.content.contains("[BACKGROUND BASH COMPLETE]") && $0.content.contains(job.handle) }
        check("L5b its later completion reports the execution deadline", notice?.content.contains("execution deadline") == true)
        BashTools.quickDefaultSeconds = 120
    }

    /// L6: the app/terminal enqueue site mints and fires too, and reports
    /// `.queuedMidTurn` (the socket's `queued_mid_turn` ack).
    private func loopAppEnqueueSite() async throws {
        let manager = await freshManager()
        manager._testSetPolling(true)
        defer { manager._testSetPolling(false) }
        server.script([
            Self.chatTools([(id: "call-l6", name: "bash", args: ["command": "sleep 3", "wait_seconds": 60])]),
            Self.chatText("ok from app"),
            Self.chatText("finished"),
        ])
        manager._testStartTurn(for: user("app turn"))
        guard await waitForRunningJob() != nil else { check("L6 job started", false); return }
        let outcome = await manager.sendFromApp(text: "from the app composer", attachments: [], policy: .terminal)
        var queued = false
        if case .queuedMidTurn = outcome { queued = true }
        _ = await manager._testAwaitIdle(timeout: 20)
        let payload = parse(results(manager).first { $0.toolCallId == "call-l6" }?.content ?? "")
        check("L6 app enqueue → .queuedMidTurn, and it wakes the wait like a Telegram message",
              queued && payload["wake_reason"] as? String == "user_message", "outcome \(outcome), \(payload)")
        _ = await waitUntil(timeout: 10) { await BackgroundProcessRegistry.shared.runningMainOwnedJobs().isEmpty }
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 20)
    }
}
