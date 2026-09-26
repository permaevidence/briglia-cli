import Foundation

/// Round-4 rows: while conversation history is unreadable, no inbound path
/// may start model/tool work or replace recovery state. Messages are held
/// durably in the mid-turn queue file and answered — once, after the
/// earlier interrupted request in history order — when history loads again.
extension MidturnHarness {

    var holdHistoryURL: URL { StoragePaths.dataRoot.appendingPathComponent("conversation.json") }
    static let unreadable = Data("unreadable history; preserve for repair".utf8)

    /// A saved interrupted request with its marker, then history made
    /// undecodable and a new manager constructed over it.
    func unreadableWithInterruptedTurn() async throws
        -> (manager: ConversationManager, prior: Message, marker: Data, good: Data) {
        let manager = await freshManager()
        let prior = user("previous interrupted request")
        manager._testSeedHistory([prior])
        manager._testWriteActiveTurnMarker(for: prior)
        let marker = try Data(contentsOf: manager._testActiveTurnMarkerURL)
        let good = try Data(contentsOf: holdHistoryURL)
        try Self.unreadable.write(to: holdHistoryURL)
        let recovered = await restart()
        return (recovered, prior, marker, good)
    }

    func queuedIds(_ manager: ConversationManager) -> [UUID] {
        guard let data = try? Data(contentsOf: manager._testPendingMidTurnURL),
              let queue = try? JSONDecoder().decode([Message].self, from: data) else { return [] }
        return queue.map(\.id)
    }

    func markerBytes(_ manager: ConversationManager) -> Data? {
        try? Data(contentsOf: manager._testActiveTurnMarkerURL)
    }

    func historyHoldSection() async throws {
        check("HH-pre the harness runs over chat completions", !ProviderProfiles.usesResponses)
        // HH1 — the reproduction (Telegram dispatch path).
        do {
            let (manager, prior, marker, good) = try await unreadableWithInterruptedTurn()
            check("HH1a unreadable startup preserves the prior turn marker", markerBytes(manager) == marker)
            server.clear()
            server.script([Self.chatText("reply without loaded history")])
            let incoming = user("new message while history cannot load")
            await manager._testDispatchUser(incoming)
            _ = await manager._testAwaitIdle(timeout: 5)
            check("HH1b dispatch while unreadable starts no model request",
                  server.completeRequests.isEmpty, "requests: \(server.completeRequests.count)")
            check("HH1c dispatch while unreadable keeps the prior marker byte-for-byte", markerBytes(manager) == marker)
            check("HH1d the new message is held durably in the queue file, not in history",
                  queuedIds(manager) == [incoming.id] && !manager._testMessages.contains { $0.id == incoming.id })
            check("HH1e the unreadable history file is unchanged", (try? Data(contentsOf: holdHistoryURL)) == Self.unreadable)
            check("HH1f the user is told once (notice flag set)", manager._testHoldNoticeSent)

            // Repair + restart: one turn answers both, earlier request first.
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("answering both requests")])
            let repaired = await restart()
            repaired._testStartupPasses()
            let resumedMarker = markerBytes(repaired)
            let markerTrigger = resumedMarker.flatMap { try? JSONDecoder().decode(ActiveTurnMarkerProbe.self, from: $0) }?.triggerMessageId
            check("HH1g the recovered turn keeps its own marker (crash-resumable)",
                  markerTrigger == incoming.id, "marker trigger \(String(describing: markerTrigger))")
            _ = await repaired._testAwaitIdle()
            let bodies = requestBodies()
            let first = bodies.first ?? ""
            let priorAt = first.range(of: "previous interrupted request")?.lowerBound
            let newAt = first.range(of: "new message while history cannot load")?.lowerBound
            check("HH1h after repair + restart: exactly one request, earlier request before the held message",
                  bodies.count == 1 && priorAt != nil && newAt != nil && priorAt! < newAt!,
                  "requests \(bodies.count)")
            let ids = repaired._testMessages.map(\.id)
            check("HH1i history holds both once, in order, answered; queue file and marker gone",
                  ids.filter { $0 == prior.id }.count == 1 && ids.filter { $0 == incoming.id }.count == 1
                    && (ids.firstIndex(of: prior.id) ?? .max) < (ids.firstIndex(of: incoming.id) ?? .min)
                    && !FileManager.default.fileExists(atPath: repaired._testPendingMidTurnURL.path)
                    && markerBytes(repaired) == nil
                    && repaired._testMessages.last?.content.contains("answering both requests") == true)
            server.clear()
            let again = await restart()
            again._testStartupPasses()
            _ = await again._testAwaitIdle(timeout: 5)
            check("HH1j a further restart runs nothing (exactly once)", server.completeRequests.isEmpty)
        }
        // HH1k control: without a held message, repair + restart resumes the
        // interrupted request (Codex C3E shape).
        do {
            let (_, _, _, good) = try await unreadableWithInterruptedTurn()
            try good.write(to: holdHistoryURL)
            server.clear()
            server.script([Self.chatText("resumed earlier request")])
            let repaired = await restart()
            repaired._testStartupPasses()
            _ = await repaired._testAwaitIdle()
            check("HH1k control: repair + restart resumes the interrupted request",
                  server.completeRequests.count == 1 && (requestBodies().first ?? "").contains("previous interrupted request")
                    && repaired._testMessages.last?.content.contains("resumed earlier request") == true)
        }
        // HH0 control: healthy dispatch starts exactly one turn and saves.
        do {
            let healthy = await freshManager()
            server.script([Self.chatText("healthy reply")])
            await healthy._testDispatchUser(user("healthy new request"))
            _ = await healthy._testAwaitIdle()
            check("HH0 control: healthy dispatch starts one request and saves its reply",
                  server.completeRequests.count == 1
                    && (try? Data(contentsOf: holdHistoryURL)).map { String(decoding: $0, as: UTF8.self).contains("healthy reply") } == true,
                  "requests \(server.completeRequests.count), active \(healthy._testIsActive), error \(healthy._testLastError ?? "-")")
        }
        // HH2/HH3 — app socket and terminal (sendFromApp, both policies).
        for (label, policy) in [("HH2 app socket", ConversationManager.AttachmentPolicy.appSocket),
                                ("HH3 terminal", ConversationManager.AttachmentPolicy.terminal)] {
            let (manager, _, marker, _) = try await unreadableWithInterruptedTurn()
            server.clear()
            let outcome = await manager.sendFromApp(text: "\(label) message", attachments: [], policy: policy)
            _ = await manager._testAwaitIdle(timeout: 5)
            var held = false
            if case .heldForRecovery = outcome { held = true }
            check("\(label): held with a notice, queued durably, no request, marker kept",
                  held && queuedIds(manager).count == 1 && server.completeRequests.isEmpty
                    && markerBytes(manager) == marker && (try? Data(contentsOf: holdHistoryURL)) == Self.unreadable,
                  "outcome \(outcome)")
        }
        // HH4 — ambient paths.
        do {
            let (manager, _, marker, _) = try await unreadableWithInterruptedTurn()
            server.clear()
            // Email: not durable → the poller keeps its checkpoint.
            let email = GoogleWorkspaceService.UnreadEmail(id: "m1", threadId: nil, from: "a@example.com",
                                                           subject: "s", date: "d", snippet: "")
            let durable = await manager._testProcessEmails([email])
            check("HH4a email while unreadable: reported not durable, nothing appended",
                  !durable && !manager._testMessages.contains { $0.content.contains("NEW EMAILS") })
            // Deferred ambient queue: stays queued (file kept), no turn.
            let ambient = Message(role: .user, content: "deferred ambient trigger", kind: .reminderFired)
            manager._testQueueAmbient(ambient)
            manager._testDrainAmbient()
            check("HH4b ambient drain while unreadable: queue file kept, no turn",
                  FileManager.default.fileExists(atPath: manager._testPendingAmbientURL.path)
                    && !manager._testMessages.contains { $0.id == ambient.id } && !manager._testIsActive)
            try? FileManager.default.removeItem(at: manager._testPendingAmbientURL)
            // Reminders: a due plain reminder stays due.
            let reminder = await ReminderService.shared.addReminder(triggerDate: Date().addingTimeInterval(-60),
                                                                   prompt: "held reminder")
            await manager._testCheckDueReminders()
            let stillDue = await ReminderService.shared.getDueReminders().contains { $0.id == reminder.id }
            check("HH4c due reminder while unreadable: stays due, no turn", stillDue && !manager._testIsActive)
            _ = await ReminderService.shared.deleteReminder(id: reminder.id)
            // Completion drains: a finished background subagent stays queued.
            await SubagentBackgroundRegistry.shared._testEnqueueCompletion(Self.subagentCompletion("hh_sub"))
            await manager._testIdleDrains()
            await manager._testSubagentDrainOnly()
            let subagentQueued = await SubagentBackgroundRegistry.shared._testPendingCompletionsCount()
            check("HH4e background completion while unreadable: stays queued, not appended, no turn",
                  subagentQueued == 1 && !manager._testMessages.contains { $0.kind == .subagentComplete }
                    && !manager._testIsActive)
            _ = await SubagentBackgroundRegistry.shared.drainCompletions()
            // Central backstop: a direct start is refused, marker untouched.
            manager._testStartTurnOnly(for: user("direct start attempt"))
            check("HH4d central admission refuses a direct start; marker kept, no request",
                  !manager._testIsActive && markerBytes(manager) == marker && server.completeRequests.isEmpty)
        }
        await resetState()
    }
}

/// Decodes only the trigger id of the active-turn marker.
private struct ActiveTurnMarkerProbe: Decodable { let triggerMessageId: UUID }
