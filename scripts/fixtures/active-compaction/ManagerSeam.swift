
// Only present in the isolated owner-test build.
extension ConversationManager {
    func activeTestSeed() async throws {
        messages = []; lastPromptTokens = nil; lastCompletionTokens = nil
        frozenCalendarContext = ""; frozenEmailContext = ""
        frozenContextDay = Calendar.current.startOfDay(for: Date())
        recoveryBlocked = false; activeTurnCheckpoints = [:]
        pendingMidTurnMessages = []; inFlightMidTurnBatch = nil; error = nil
        clearTurnSalvageFile()
        await openRouterService.configure(apiKey: "unused-fixture")
        guard saveConversation() else { throw CompactionTestInputs.Failure("seed save") }
    }
    func activeTestTurn(_ human: Message, queued: Message?) async throws -> [Message] {
        messages.append(human)
        if let queued { pendingMidTurnMessages = [queued]; _ = persistPendingMidTurnQueue() }
        guard saveConversation() else { throw CompactionTestInputs.Failure("human save") }
        startActiveProcessing(for: human)
        while let task = activeProcessingTask { await task.value }
        return messages
    }
    func activeTestRecovery(_ checkpoint: TurnCheckpoint) throws -> [Message] {
        let before = messages.count
        try PrivateStorage.writeAtomically(JSONEncoder().encode(checkpoint), to: turnSalvageFileURL)
        recoverInterruptedTurnSalvageIfNeeded()
        recoverInterruptedTurnSalvageIfNeeded()
        try CompactionTestInputs.check(messages.count == before + 1, "checkpoint recovery exactly once")
        try CompactionTestInputs.check(!FileManager.default.fileExists(atPath: turnSalvageFileURL.path), "checkpoint cleared after recovered save")
        return messages
    }
    func activeTestProtection(_ giant: Message, small: Message) throws {
        try CompactionTestInputs.check(lastAssistantIndexWithTools(in: [giant]) == nil, "oversized newest turn loses protection")
        try CompactionTestInputs.check(lastAssistantIndexWithTools(in: [small]) == 0, "normal newest turn stays protected")
    }
}

extension ConversationManager {
    func activeTestStorageFailures(_ sample: TurnCheckpoint) throws {
        for phase in ["write", "fsync", "rename", "directory-fsync"] {
            try PrivateStorage.writeAtomically(JSONEncoder().encode(sample), to: turnSalvageFileURL)
            var next = sample; next.generation += 1
            CompactionTestInputs.writeFault = phase
            do { try writeTurnCheckpoint(next); throw CompactionTestInputs.Failure("checkpoint fault not injected") }
            catch is PruneArchiveStore.Failure { }
            CompactionTestInputs.writeFault = nil
            let onDisk = try JSONDecoder().decode(TurnCheckpoint.self, from: Data(contentsOf: turnSalvageFileURL))
            try CompactionTestInputs.check(onDisk.generation == (phase == "directory-fsync" ? next.generation : sample.generation),
                "checkpoint old-or-new bytes at " + phase)
            activeTurnCheckpoints = [:]; clearTurnSalvageFile()
        }
        // Malformed/future files are never removed, including failed startup.
        for bytes in [Data("broken json".utf8), Data("{\"version\":99}".utf8)] {
            try PrivateStorage.writeAtomically(bytes, to: turnSalvageFileURL)
            recoverInterruptedTurnSalvageIfNeeded()
            try CompactionTestInputs.check(try Data(contentsOf: turnSalvageFileURL) == bytes && recoveryBlocked,
                "unknown recovery data preserved")
            clearTurnSalvageFile()
        }
        let legacy = [ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "old", toolCalls: [
            ToolCall(id: "legacy-recover", type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))
        ]), results: [ToolResultMessage(toolCallId: "legacy-recover", content: "LEGACY_EXACT")])]
        let raw = try JSONEncoder().encode(legacy)
        try PrivateStorage.writeAtomically(raw, to: turnSalvageFileURL)
        let parked = conversationFileURL.appendingPathExtension("parked")
        try FileManager.default.moveItem(at: conversationFileURL, to: parked)
        try FileManager.default.createDirectory(at: conversationFileURL, withIntermediateDirectories: false)
        recoverInterruptedTurnSalvageIfNeeded()
        try CompactionTestInputs.check(try Data(contentsOf: turnSalvageFileURL) == raw, "failed legacy recovery save preserves original salvage")
        try FileManager.default.removeItem(at: conversationFileURL)
        try FileManager.default.moveItem(at: parked, to: conversationFileURL)
        recoverInterruptedTurnSalvageIfNeeded()
        try CompactionTestInputs.check(messages.flatMap(\.toolInteractions).filter { $0.assistantMessage.toolCalls.first?.id == "legacy-recover" }.count == 1,
            "legacy recovery retry saves once")
        try CompactionTestInputs.check(!FileManager.default.fileExists(atPath: turnSalvageFileURL.path), "legacy recovery clears only after successful save")

        // A new checkpoint's summary-only outcome must also survive save failure.
        var checkpoint = TurnCheckpoint(runID: UUID(), taskMessageID: sample.taskMessageID)
        checkpoint.activeTurnCompaction = sample.activeTurnCompaction; checkpoint.generation = 1
        try PrivateStorage.writeAtomically(JSONEncoder().encode(checkpoint), to: turnSalvageFileURL)
        try FileManager.default.moveItem(at: conversationFileURL, to: parked)
        try FileManager.default.createDirectory(at: conversationFileURL, withIntermediateDirectories: false)
        recoverInterruptedTurnSalvageIfNeeded()
        try CompactionTestInputs.check(FileManager.default.fileExists(atPath: turnSalvageFileURL.path), "failed envelope recovery save preserves checkpoint")
        try FileManager.default.removeItem(at: conversationFileURL)
        try FileManager.default.moveItem(at: parked, to: conversationFileURL)
        recoverInterruptedTurnSalvageIfNeeded()
        try CompactionTestInputs.check(messages.filter { $0.id == checkpoint.outcomeMessageID }.count == 1,
            "envelope recovery deduplicates after failed save")
        try CompactionTestInputs.check(!FileManager.default.fileExists(atPath: turnSalvageFileURL.path), "envelope recovery commits before clearing")

        // Snapshot failure on overflow cannot publish the enormous replay.
        var huge = TurnCheckpoint(runID: UUID(), taskMessageID: sample.taskMessageID)
        huge.retainedInteractions = legacy
        huge.retainedInteractions[0].measuredTokenCost = 500000
        PruneArchiveStore.faultForTesting = { if $0 == "write" { throw PruneArchiveStore.Failure("disk full fixture") } }
        do { _ = try boundInterruptedCheckpoint(huge); throw CompactionTestInputs.Failure("snapshot write failure bypassed") }
        catch is PruneArchiveStore.Failure { }
        PruneArchiveStore.faultForTesting = nil
        let bounded = try boundInterruptedCheckpoint(huge)
        try CompactionTestInputs.check(bounded.retainedInteractions.isEmpty && bounded.overflowReference != nil && bounded.overflowLog != nil,
            "controlled stop preserves overflow through snapshot only")
        try activeTestProtection(Message(role: .assistant, content: "old", toolInteractions: huge.retainedInteractions),
            small: Message(role: .assistant, content: "small", toolInteractions: legacy))
    }
}

extension ConversationManager {
    func activeTestSoftTarget(server: CaptureServer, wire: ProviderWireProtocol) async throws {
        func round(_ id: String, cost: Int) -> ToolInteraction {
            ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "done", toolCalls: [
                ToolCall(id: id, type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))
            ]), results: [ToolResultMessage(toolCallId: id, content: "evidence")], measuredTokenCost: cost)
        }
        messages = [Message(role: .user, content: "Earlier request"),
            Message(role: .assistant, content: "Earlier answer", toolInteractions: [round("old", cost: 160000)]),
            Message(role: .assistant, content: "Recent answer", toolInteractions: [round("recent", cost: 100000)]),
            Message(role: .user, content: "Current task")]
        guard saveConversation() else { throw CompactionTestInputs.Failure("soft target seed") }
        lastPromptTokens = 250001
        server.clear(); server.script([try CompactionTestInputs.body(protocol: wire, text: "Historical evidence preserved.")])
        var history = messages
        let decision = try await pruneStoredToolInteractionsMidLoop(messagesForLLM: &history,
            currentTurnInteractions: [], calendarContext: nil, emailContext: nil, chunkSummaries: [], totalChunkCount: 0,
            currentUserMessageId: messages.last!.id, turnStartDate: Date(), tools: [], deferredMCPSummaries: [])
        try CompactionTestInputs.check(decision == .pruned && !history[2].toolInteractions.isEmpty,
            "100k recent work survives historical prune above soft target")
        try CompactionTestInputs.check(server.completeRequests.count == 1, "missing 70k target does not invoke active compaction")
    }
}

extension ConversationManager {
    func activeTestInterrupted(server: CaptureServer, wire: ProviderWireProtocol, file: URL) async throws {
        for mode in ["cancel", "late-human", "stale-generation"] {
            try await activeTestSeed(); server.clear()
            CompactionTestInputs.dynamicWire = wire; CompactionTestInputs.dynamicPath = file.path
            CompactionTestInputs.compactions = 0; CompactionTestInputs.ordinaryCalls = 0
            let late = Message(role: .user, content: "LATE_CANONICAL: preserve this new instruction")
            CompactionTestInputs.maintenanceHook = { manager in
                if mode == "cancel" { await manager.stopActiveExecution() }
                else if mode == "late-human" {
                    manager.pendingMidTurnMessages.append(late)
                    _ = manager.persistPendingMidTurnQueue()
                } else if let run = manager.activeRunId {
                    manager.activeTurnCheckpoints[run]?.nextRoundSequence += 1
                }
            }
            let history = try await activeTestTurn(Message(role: .user, content: "Exercise maintenance boundary"), queued: nil)
            CompactionTestInputs.dynamicWire = nil; CompactionTestInputs.maintenanceHook = nil
            if mode == "late-human" {
                try CompactionTestInputs.check(history.filter { $0.id == late.id }.count == 1, "user arriving during summary persists exactly once")
                try CompactionTestInputs.check(history.last?.content == "FINAL_COMPACTION_OK", "user arriving during summary does not strand the turn")
            } else {
                try CompactionTestInputs.check(CompactionTestInputs.compactions == 0, "no stale compaction after " + mode)
                try CompactionTestInputs.check(history.last?.toolInteractions.isEmpty == true && history.last?.pruneArchiveReferences.isEmpty == false,
                    "interrupted maintenance saves snapshot without oversized replay: " + mode)
                try CompactionTestInputs.check(!FileManager.default.fileExists(atPath: turnSalvageFileURL.path), "interrupted outcome saved before checkpoint clear")
                server.clear(); server.script([try CompactionTestInputs.body(protocol: wire, text: "NEXT_TURN_OK")])
                let next = try await activeTestTurn(Message(role: .user, content: "Continue with a small task"), queued: nil)
                try CompactionTestInputs.check(next.last?.content == "NEXT_TURN_OK", "next turn works after " + mode)
            }
        }
    }

    func activeTestOversizedHistory(server: CaptureServer, wire: ProviderWireProtocol) async throws {
        for mode in ["manual", "automatic", "midloop"] {
            try await activeTestSeed(); server.clear()
            let round = ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "legacy work", toolCalls: [
                ToolCall(id: "giant-legacy", type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))
            ]), results: [ToolResultMessage(toolCallId: "giant-legacy", content: "GIANT_EXACT")], measuredTokenCost: 300000)
            messages = [Message(role: .user, content: "Legacy task"), Message(role: .assistant, content: "Done", toolInteractions: [round]),
                Message(role: .user, content: "Next task")]
            if mode == "manual" { messages.removeLast() } // trailing affected assistant must remain in summary input
            guard saveConversation() else { throw CompactionTestInputs.Failure("giant seed") }
            lastPromptTokens = 310000
            server.script([try CompactionTestInputs.body(protocol: wire, text: "Legacy finding GIANT_EXACT retained.")])
            if mode == "manual" { await manualPruneToolInteractions() }
            else if mode == "automatic" {
                _ = try await pruneToolInteractionsIfNeeded(currentUserMessageId: messages.last!.id, calendarContext: nil,
                    emailContext: nil, chunkSummaries: [], totalChunkCount: 0, turnStartDate: Date(), tools: [], deferredMCPSummaries: [])
            } else {
                var history = messages
                _ = try await pruneStoredToolInteractionsMidLoop(messagesForLLM: &history, currentTurnInteractions: [],
                    calendarContext: nil, emailContext: nil, chunkSummaries: [], totalChunkCount: 0,
                    currentUserMessageId: messages.last!.id, turnStartDate: Date(), tools: [], deferredMCPSummaries: [])
            }
            try CompactionTestInputs.check(messages[1].toolInteractions.isEmpty, "oversized latest historical round pruned in " + mode)
            try CompactionTestInputs.check(server.completeRequests.count == 1 && String(decoding: server.completeRequests[0].body, as: UTF8.self).contains("ACTIVE TURN COMPACTION"),
                "oversized historical summary uses bounded builder in " + mode)
        }
    }
}
