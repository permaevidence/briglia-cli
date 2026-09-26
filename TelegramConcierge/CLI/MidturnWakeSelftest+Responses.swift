import Foundation

/// The real manager over the Responses transport (rows RX*): the wake,
/// the typed placeholder written before a batch runs and its replacement,
/// a failed salvage write, a crash that leaves only the placeholder, and
/// /stop after the batch finished. Chat Completions rows cover the same
/// paths elsewhere; these prove the Responses-specific commit sequence.
extension MidturnHarness {

    static func responsesText(_ text: String, id: String = UUID().uuidString) -> String {
        responsesBody([["type": "message", "role": "assistant", "status": "completed", "id": "msg_" + id,
                        "content": [["type": "output_text", "text": text, "annotations": []]]]], id: id)
    }

    static func responsesTools(_ calls: [(id: String, name: String, args: [String: Any])], id: String = UUID().uuidString) -> String {
        let items: [[String: Any]] = calls.map { call in
            let args = String(data: try! JSONSerialization.data(withJSONObject: call.args, options: [.sortedKeys]), encoding: .utf8)!
            return ["type": "function_call", "id": "fc_" + call.id, "call_id": call.id, "status": "completed",
                    "name": call.name, "arguments": args]
        }
        return responsesBody(items, id: id)
    }

    private static func responsesBody(_ output: [[String: Any]], id: String) -> String {
        let body: [String: Any] = ["id": "resp_" + id, "status": "completed", "output": output,
            "usage": ["input_tokens": 100, "input_tokens_details": ["cached_tokens": 0],
                      "output_tokens": 10, "output_tokens_details": ["reasoning_tokens": 0]]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    func responsesSection() async throws {
        try ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                         model: "fixture-model", effort: nil, textOnly: false, wireProtocol: .responses)
        try ProviderProfiles.activate(.custom)
        defer {
            ConversationManager.responsesSalvageFaultForTesting = nil
            try? ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                              model: "glm-5.3", effort: nil, textOnly: false, wireProtocol: .chatCompletions)
            try? configureProvider()
        }
        check("RX0 the manager runs over Responses", ProviderProfiles.usesResponses)
        try await responsesMovedDetach()
        try await responsesFailedSalvage()
        try await responsesPlaceholderAfterCrash()
        try await responsesStopAfterBatch()
    }

    private func onlyResponsesTargets() -> Bool {
        !server.completeRequests.isEmpty && server.completeRequests.allSatisfy { $0.target.hasSuffix("/responses") }
    }

    /// RX1: wake + moved detach; the pre-execution placeholder is replaced
    /// by the moved result in the saved round; completion delivered once.
    private func responsesMovedDetach() async throws {
        let manager = await freshManager()
        server.script([
            Self.responsesTools([(id: "rx1", name: "bash", args: ["command": "sleep 3; echo rx1-done", "wait_seconds": 60])]),
            Self.responsesText("answered while it runs"),
            Self.responsesText("it finished"),
        ])
        manager._testStartTurn(for: user("long job over responses"))
        guard let job = await waitForRunningJob() else { check("RX1 job started", false); return }
        await manager._testDispatchUser(user("question during the job"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let rx = results(manager).filter { $0.toolCallId == "rx1" }
        check("RX1a Responses: woken wait saved as ONE moved result for the job (placeholder replaced)",
              rx.count == 1 && rx.first?.outcomeBinding?.kind == .moved && rx.first?.outcomeBinding?.jobId == job.jobUUID
                && records().first { $0.jobId == job.jobUUID }?.completion == .owed && onlyResponsesTargets(),
              "\(rx.map { $0.outcomeBinding?.kind.rawValue ?? "nil" })")
        _ = await waitUntil(timeout: 10) { await BackgroundProcessRegistry.shared.settlementInfo(uuid: job.jobUUID).settled }
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 20)
        let record = manager._testMessages.filter { $0.kind == .bashComplete && $0.content.contains("rx1-done") }
        check("RX1b Responses: completion delivered exactly once, record retired",
              record.count == 1 && !records().contains { $0.jobId == job.jobUUID })
    }

    /// RX2: the salvage write AFTER the batch fails (the woken job has
    /// already moved): the turn aborts, yet the job's result is delivered
    /// exactly once and nothing is left untracked or duplicated.
    private func responsesFailedSalvage() async throws {
        let manager = await freshManager()
        struct Injected: Error {}
        ConversationManager.responsesSalvageFaultForTesting = { if $0 == "completed" { throw Injected() } }
        server.script([
            Self.responsesTools([(id: "rx2", name: "bash", args: ["command": "sleep 2; echo rx2-done", "wait_seconds": 60])]),
            Self.responsesText("never requested"),
            Self.responsesText("noted the completion"),
        ])
        manager._testStartTurn(for: user("salvage will fail"))
        guard let job = await waitForRunningJob() else { check("RX2 job started", false); return }
        await manager._testDispatchUser(user("message that wakes it"))
        _ = await manager._testAwaitIdle(timeout: 20)
        ConversationManager.responsesSalvageFaultForTesting = nil
        let saved = results(manager).filter { $0.toolCallId == "rx2" }
        check("RX2a failed post-batch salvage: no moved result was committed; the typed placeholder (no job) is what history holds",
              saved.allSatisfy { $0.outcomeBinding?.jobId == nil } && records().first { $0.jobId == job.jobUUID }?.completion == .owed,
              "\(saved.map { $0.outcomeBinding?.kind.rawValue ?? "nil" }), records \(records().map(\.completion))")
        _ = await waitUntil(timeout: 10) { await BackgroundProcessRegistry.shared.settlementInfo(uuid: job.jobUUID).settled }
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 20)
        await manager._testIdleDrains()
        let notices = manager._testMessages.filter { $0.kind == .bashComplete && $0.content.contains("rx2-done") }
        let running = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
        check("RX2b the owed result is delivered exactly once, record retired, nothing running",
              notices.count == 1 && !records().contains { $0.jobId == job.jobUUID } && running.isEmpty,
              "notices \(notices.count), records \(records().count), running \(running.count)")
    }

    /// RX3: a crash right after the batch (files exactly as the failed
    /// write leaves them: placeholder in the salvage, record owed). After
    /// restart the placeholder survives in history, the job result stays
    /// owed, and one lost-job note is published — never zero, never two.
    private func responsesPlaceholderAfterCrash() async throws {
        let manager = await freshManager()
        struct Injected: Error {}
        let salvage = StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json")
        let checkpointDir = StoragePaths.dataRoot
        final class Captured: @unchecked Sendable { var files: [String: Data] = [:] }
        let captured = Captured()
        ConversationManager.responsesSalvageFaultForTesting = { stage in
            guard stage == "completed" else { return }
            // The durable state at the instant of the crash.
            for name in ["turn_salvage.json", "conversation.json", "detached-jobs.json", "active_turn.json"] {
                if let data = try? Data(contentsOf: checkpointDir.appendingPathComponent(name)) { captured.files[name] = data }
            }
            throw Injected()
        }
        server.script([
            Self.responsesTools([(id: "rx3", name: "bash", args: ["command": "sleep 30", "wait_seconds": 60])]),
            Self.responsesText("never requested"),
        ])
        manager._testStartTurn(for: user("crash after the batch"))
        guard await waitForRunningJob() != nil else { check("RX3 job started", false); return }
        await manager._testDispatchUser(user("wake it"))
        _ = await manager._testAwaitIdle(timeout: 20)
        ConversationManager.responsesSalvageFaultForTesting = nil
        guard let recordsData = captured.files["detached-jobs.json"],
              let record = records().first ?? (try? JSONDecoder().decode([String: [DetachedJobRecord]].self, from: recordsData))?["records"]?.first else {
            check("RX3 crash state captured with an owed record", false, "\(captured.files.keys.sorted())"); return
        }
        // Simulate the crash: the process dies (its jobs die with it and
        // record nothing more), then exactly the captured files remain.
        _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        try? await Task.sleep(nanoseconds: 300_000_000)
        for name in ["turn_salvage.json", "conversation.json", "detached-jobs.json", "active_turn.json"] {
            let url = checkpointDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            if let data = captured.files[name] { try data.write(to: url) }
        }
        _ = salvage
        server.clear(); server.script([Self.responsesText("noted after restart"), Self.responsesText("spare")])
        let restarted = await restart()
        restarted._testStartupPasses()
        _ = await restarted._testAwaitIdle(timeout: 20)
        let placeholders = results(restarted).filter { $0.toolCallId == "rx3" && $0.outcomeBinding?.kind == .interruptedIntent }
        let notes = restarted._testMessages.filter { $0.id == record.completionMessageId }
        check("RX3 crash with only the placeholder durable: placeholder recovered, exactly one lost-job note, record retired",
              !placeholders.isEmpty && notes.count == 1 && notes.first?.content.contains("[BACKGROUND BASH LOST]") == true
                && !records().contains { $0.jobId == record.jobId },
              "placeholders \(placeholders.count), notes \(notes.count), records \(records().count), note: \(notes.first?.content.prefix(160) ?? "")")
        let again = await restart()
        again._testStartupPasses()
        check("RX3b another restart publishes nothing more",
              again._testMessages.filter { $0.id == record.completionMessageId }.count == 1)
    }

    /// RX4: /stop after the batch finished (the next request is in flight):
    /// the cancel salvage keeps the real results; a job observed in the
    /// round (receipt) is never re-announced; a moved job is killed (B1)
    /// and its notice is appended once without waking.
    private func responsesStopAfterBatch() async throws {
        let manager = await freshManager()
        manager._testSetPolling(true)
        defer { manager._testSetPolling(false) }
        let hold = RequestHold(held: [2])
        server.requestObserver = { _ in hold.observe() }
        server.script([
            Self.responsesTools([(id: "rx4a", name: "bash", args: ["command": "echo rx4-quick", "wait_seconds": 10]),
                                 (id: "rx4b", name: "bash", args: ["command": "sleep 30", "wait_seconds": 0])]),
            Self.responsesText("never delivered"),
        ])
        manager._testStartTurn(for: user("two commands then stop"))
        _ = await waitUntil { hold.arrived(2) }
        let requestsBeforeStop = server.completeRequests.count
        await manager._testStop()
        hold.release(2)
        server.requestObserver = nil
        _ = await manager._testAwaitIdle(timeout: 20)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await manager._testIdleDrains()
        _ = await manager._testAwaitIdle(timeout: 10)
        await manager._testIdleDrains()
        let quick = results(manager).filter { $0.toolCallId == "rx4a" }
        let quickNotices = manager._testMessages.filter { $0.kind == .bashComplete && $0.content.contains("rx4-quick") }
        let longNotices = manager._testMessages.filter { $0.kind == .bashComplete && $0.content.contains("sleep 30") }
        check("RX4a cancel salvage keeps the real result of the finished call — its notice never re-announced",
              quick.count == 1 && quick.first?.content.contains("rx4-quick") == true
                && quick.first?.outcomeBinding?.kind != .interruptedIntent && quickNotices.isEmpty,
              "quick \(quick.map { $0.outcomeBinding?.kind.rawValue ?? "nil" }), notices \(quickNotices.count)")
        check("RX4b the moved job is killed by /stop and its notice appended once without waking",
              longNotices.count == 1 && longNotices.first?.content.contains("[Stopped by /stop") == true
                // Only the request already in flight at /stop completes;
                // its answer is discarded and nothing new is requested.
                && server.completeRequests.count <= requestsBeforeStop + 1 && records().isEmpty
                && !manager._testMessages.contains { $0.role == .assistant && $0.content == "never delivered" },
              "notices \(longNotices.count), requests \(server.completeRequests.count) vs \(requestsBeforeStop), records \(records().count)")
    }
}
