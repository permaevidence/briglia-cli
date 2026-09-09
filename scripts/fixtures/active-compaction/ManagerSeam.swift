
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

extension ConversationManager {
    func activeTestCombinedFailure(_ sample: TurnCheckpoint, server: CaptureServer, wire: ProviderWireProtocol) async throws {
        var raw = TurnCheckpoint(runID: UUID(), taskMessageID: sample.taskMessageID)
        raw.retainedInteractions = [ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "latest irreversible result", toolCalls: [
            ToolCall(id: "unpublished-latest", type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))
        ]), results: [ToolResultMessage(toolCallId: "unpublished-latest", content: "LATEST_RAW_MUST_SURVIVE")], measuredTokenCost: 500000)]
        activeTurnCheckpoints[raw.runID] = raw
        PruneArchiveStore.faultForTesting = { if $0 == "write" { throw PruneArchiveStore.Failure("disk full fixture") } }
        CompactionTestInputs.writeFault = "write"
        let interrupted = preserveInterruptedCheckpoint(runID: raw.runID)
        try CompactionTestInputs.check(interrupted?.pendingRecovery == true && activeTurnCheckpoints[raw.runID]?.retainedInteractions.first?.results.first?.content == "LATEST_RAW_MUST_SURVIVE",
            "combined snapshot/checkpoint failure retains newest raw work in memory")
        recoverInterruptedTurnSalvageIfNeeded()
        try CompactionTestInputs.check(recoveryBlocked && activeTurnCheckpoints[raw.runID]?.pendingRecovery == true,
            "failed in-process recovery retry preserves raw owner")
        try CompactionTestInputs.check(await exportBusyReason() != nil, "export refuses unpublished recovery")
        CompactionTestInputs.writeFault = nil; PruneArchiveStore.faultForTesting = nil
        server.clear(); server.script([try CompactionTestInputs.body(protocol: wire, text: "STORAGE_RECOVERED_OK")])
        let result = try await activeTestTurn(Message(role: .user, content: "Storage is available; continue"), queued: nil)
        try CompactionTestInputs.check(result.last?.content == "STORAGE_RECOVERED_OK" && activeTurnCheckpoints[raw.runID] == nil,
            "next turn flushes unpublished recovery before starting new work")
        let outcome = result.first { $0.id == raw.outcomeMessageID }
        try CompactionTestInputs.check(outcome?.toolInteractions.isEmpty == true && outcome?.pruneArchiveReferences.isEmpty == false,
            "combined-failure recovery publishes bounded outcome exactly once")
        let path = PruneArchiveStore.root.appendingPathComponent(outcome!.pruneArchiveReferences[0].basename)
        try CompactionTestInputs.check(try String(contentsOf: path).contains("LATEST_RAW_MUST_SURVIVE"),
            "unpublished raw result reaches durable snapshot after storage recovers")
        var discarded = raw; discarded.pendingRecovery = true
        activeTurnCheckpoints[discarded.runID] = discarded
        try writeTurnCheckpoint(discarded)
        try discardTurnRecoveryForReplacement()
        recoverInterruptedTurnSalvageIfNeeded()
        try CompactionTestInputs.check(activeTurnCheckpoints.isEmpty && !FileManager.default.fileExists(atPath: turnSalvageFileURL.path),
            "accepted Mind replacement discards disk and in-memory old recovery")
    }
}

extension ConversationManager {
    func activeTestMediaStart(server: CaptureServer, wire: ProviderWireProtocol, root: URL) async throws {
        try await activeTestSeed(); server.clear()
        // Valid, portable fifteen-page PDFs: actual rehydration runs through
        // each serializer instead of substituting a text-only request.
        let pageIDs = (0..<15).map { 3 + $0 }
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 15 /Kids [" + pageIDs.map { "\($0) 0 R" }.joined(separator: " ") + "] >>"]
        objects += pageIDs.map { _ in "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] /Resources << >> >>" }
        var pdf = "%PDF-1.4\n"; var offsets = [0]
        for (i, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count); pdf += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(offsets.count)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        var references: [FileAttachmentReference] = []
        for name in ["first.pdf", "second.pdf"] {
            let url = root.appendingPathComponent(name)
            try Data(pdf.utf8).write(to: url)
            try CompactionTestInputs.check(AdaPDF(url: url)?.pageCount == 15, "media fixture contains fifteen real PDF pages")
            references.append(FileAttachmentReference(filename: name, mimeType: "application/pdf", snapshotPath: url.path,
                byteSize: pdf.utf8.count, pdfPageCount: 15))
        }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC")!
        for i in 0..<3 {
            let url = root.appendingPathComponent("image-\(i).png")
            try png.write(to: url)
            references.append(FileAttachmentReference(filename: url.lastPathComponent, mimeType: "image/png",
                snapshotPath: url.path, byteSize: png.count, imageWidth: 1, imageHeight: 1))
        }
        var result = ToolResultMessage(toolCallId: "media-read", content: "Two fifteen-page documents and three images were inspected.")
        result.fileAttachmentReferences = references
        let old = Message(role: .assistant, content: "Documents checked", toolInteractions: [ToolInteraction(
            assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: [ToolCall(id: "media-read", type: "function",
                function: FunctionCall(name: "read_file", arguments: "{}"))]), results: [result])])
        messages = [Message(role: .user, content: "Inspect these documents"), old]
        try CompactionTestInputs.check(ActiveTurnBudget.message(old) > 250000 && lastPromptTokens == nil,
            "media allowances exceed budget while ordinary measurement is unknown")
        server.script([try CompactionTestInputs.body(protocol: wire, text: "MEDIA_CONTEXT_OK", tokens: 60000)])
        let completed = try await activeTestTurn(Message(role: .user, content: "Continue with the findings"), queued: nil)
        try CompactionTestInputs.check(completed.last?.content == "MEDIA_CONTEXT_OK" && server.completeRequests.count == 1,
            "media-heavy history runs without a measurement")
        let object = try JSONSerialization.jsonObject(with: server.completeRequests[0].body)
        func strings(_ value: Any) -> [String] {
            if let s = value as? String { return [s] }
            if let a = value as? [Any] { return a.flatMap(strings) }
            if let d = value as? [String: Any] { return d.values.flatMap(strings) }
            return []
        }
        let values = strings(object)
        let pdfParts = values.filter { $0.hasPrefix("data:application/pdf;") }.count
        let imageParts = values.filter { $0.hasPrefix("data:image/") }.count
        try CompactionTestInputs.check(values.contains(result.content) && imageParts >= 3 && (pdfParts == 2 || imageParts >= 33),
            "media-bearing replay reaches provider without historical pruning")
        try CompactionTestInputs.check(lastPromptTokens == 60000 && completed[1].toolInteractions.count == 1,
            "provider measurement calibrates healthy media history")
        // Chunk archiving/pruning invalidates this measurement; another fresh
        // turn must still succeed instead of leaving a self-sustaining wedge.
        lastPromptTokens = nil; server.clear()
        server.script([try CompactionTestInputs.body(protocol: wire, text: "MEDIA_RETRY_OK", tokens: 61000)])
        let retried = try await activeTestTurn(Message(role: .user, content: "One more question"), queued: nil)
        try CompactionTestInputs.check(retried.last?.content == "MEDIA_RETRY_OK" && server.completeRequests.count == 1,
            "media history continues after measurement invalidation")
        try await activeTestSeed(); server.clear()
        _ = try await activeTestTurn(Message(role: .user, content: String(repeating: "oversized fixed input ", count: 60000)), queued: nil)
        try CompactionTestInputs.check(server.completeRequests.isEmpty && (error ?? "").contains("remaining instructions and message text"),
            "truly oversized fixed text refuses before provider request")
        try await activeTestSeed(); server.clear()
    }

    func activeTestPruneReport(server: CaptureServer, wire: ProviderWireProtocol) async throws {
        for noSnapshot in [false, true] {
            try await activeTestSeed(); server.clear()
            func round(_ id: String, cost: Int) -> ToolInteraction {
                ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "done", toolCalls: [
                    ToolCall(id: id, type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))
                ]), results: [ToolResultMessage(toolCallId: id, content: "Evidence")], measuredTokenCost: cost)
            }
            var old = Message(role: .assistant, content: "Earlier answer", toolInteractions: [round("report-old", cost: 140000)])
            old.prunedContextSummary = String(repeating: "existing summary ", count: 300)
            messages = [Message(role: .user, content: "Previous task"), old,
                Message(role: .assistant, content: "Recent answer", toolInteractions: [round("report-recent", cost: 10000)])]
            guard saveConversation() else { throw CompactionTestInputs.Failure("report seed") }
            lastPromptTokens = 180000; lastCompletionTokens = 0
            server.script([try CompactionTestInputs.body(protocol: wire, text: String(repeating: "New findings preserved. ", count: 500))])
            await manualPruneToolInteractions(noSnapshot: noSnapshot)
            let oldNotes = old.prunedContextSummary!.count / 4
            let newNotes = (messages[1].prunedContextSummary?.count ?? 0) / 4
                + messages[1].pruneArchiveReferences.reduce(0) { $0 + $1.promptText.count / 4 }
            let expected = 180000 - 140000 + newNotes - oldNotes
            try CompactionTestInputs.check(maintenanceNotice?.contains("down to ~\(expected / 1000)k") == true && expected / 1000 > 40,
                "manual prune report includes committed summary and reference delta")
            try CompactionTestInputs.check(messages[1].toolInteractions.isEmpty && messages[2].toolInteractions.count == 1
                && messages[1].pruneArchiveReferences.count == (noSnapshot ? 0 : 1) && server.completeRequests.count == 1,
                "report regression preserves pruning and explicit override behavior")
        }
    }
}

extension ConversationManager {
    /// Bree's 0.2.14 finding: the forced final pass (round backstop, spend
    /// cap, context fallback) must replay the checkpoint projection — the
    /// compaction summary and the carried verbatim user messages — exactly as
    /// the tool loop did, otherwise the wrap-up loses the compacted context.
    func activeTestForcedFinal(server: CaptureServer, wire: ProviderWireProtocol, file: URL) async throws {
        try await activeTestSeed(); server.clear()
        try AgentTurnOverrides.setOverride(30, forAgent: "main")
        defer { try? AgentTurnOverrides.setOverride(nil, forAgent: "main") }
        CompactionTestInputs.dynamicWire = wire; CompactionTestInputs.dynamicPath = file.path
        CompactionTestInputs.compactions = 0; CompactionTestInputs.ordinaryCalls = 0
        CompactionTestInputs.forcedFinalMode = true
        let correction = Message(role: .user, content: "VERBATIM_CORRECTION: choose violet; never orange.")
        let history = try await activeTestTurn(Message(role: .user, content: "Keep working until the harness stops you."), queued: correction)
        CompactionTestInputs.forcedFinalMode = false; CompactionTestInputs.dynamicWire = nil
        try CompactionTestInputs.check(CompactionTestInputs.compactions >= 1 && CompactionTestInputs.ordinaryCalls == 30,
            "round backstop reached after at least one compaction")
        let forced = server.completeRequests.filter { String(decoding: $0.body, as: UTF8.self).contains("[ROUND LIMIT]") }
        try CompactionTestInputs.check(forced.count == 1, "exactly one forced final request")
        let object = try JSONSerialization.jsonObject(with: forced[0].body) as! [String: Any]
        let items = object[wire == .responses ? "input" : "messages"] as! [[String: Any]]
        let summaryIndex = items.firstIndex { String(describing: $0).contains("Summary of earlier completed work") }
        let userIndex = items.firstIndex { ($0["role"] as? String) == "user" && String(describing: $0["content"] ?? "").contains(correction.content) }
        let ordered = summaryIndex != nil && userIndex != nil && summaryIndex! < userIndex!
        try CompactionTestInputs.check(ordered && history.last?.content == "FINAL_FORCED_OK",
            "forced final answer keeps compaction summary and verbatim correction")
        try CompactionTestInputs.check(history.last?.activeTurnCompaction != nil && history.filter { $0.id == correction.id }.count == 1,
            "forced final outcome persists summary and canonical correction once")
        try CompactionTestInputs.check(server.errors.isEmpty, "forced final pass leaves no provider errors")
    }
}
