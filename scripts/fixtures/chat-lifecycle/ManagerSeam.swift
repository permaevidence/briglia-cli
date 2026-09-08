
// Appended ONLY in disposable P0 builds. Calls private production methods;
// no replacement implementations, branches, budgets or accounting formulas.
extension ConversationManager {
    func p0Save() throws { guard saveConversation() else { throw P0Life.Failure("save failed") } }

    func p0Seed(_ history: [Message], prompt: Int?, completion: Int?) async {
        messages = history
        lastPromptTokens = prompt
        lastCompletionTokens = completion
        frozenCalendarContext = ""
        frozenEmailContext = ""
        frozenContextDay = Calendar.current.startOfDay(for: Date())
        await openRouterService.configure(apiKey: "synthetic-lifecycle-key")
    }

    func p0Prune(_ mode: String, history: [Message], prompt: Int?, current: [ToolInteraction]) async throws -> [String: Any] {
        await p0Seed(history, prompt: prompt, completion: 100)
        var snapshot = history
        let protected = lastAssistantIndexWithTools(in: history)
        let initial = prompt ?? 20_000
        let plan = buildPrunePlan(for: history, totalTokens: initial, targetTokens: configuredTargetContextTokens(),
                                  protectedIndex: protected, providerIsLMStudio: false)
        var result: [String: Any] = [
            "protected": protected as Any? ?? NSNull(),
            "actions": plan.actions.map { action -> [String: Any] in
                switch action {
                case .toolInteractions(let index, let savings): return ["kind": "tools", "index": index, "savings": savings]
                case .media(let index, let savings): return ["kind": "media", "index": index, "savings": savings]
                }
            },
            "boundary": plan.pruningBoundary, "saved": plan.savedTokens,
            "estimates": history.map { [estimatedPromptTokens(for: $0, isLMStudio: false),
                                        toolTokensForMessage($0, isLMStudio: false), estimatedFinalReasoningTokens($0)] },
            "added": estimatedTokensAddedSinceLastPrompt(currentUserMessageId: history.last?.id, isLMStudio: false)
        ]
        if mode == "midloop" {
            let decision = try await pruneStoredToolInteractionsMidLoop(messagesForLLM: &snapshot,
                currentTurnInteractions: current, calendarContext: nil, emailContext: nil, chunkSummaries: [],
                totalChunkCount: 0, currentUserMessageId: history.last?.id, turnStartDate: P0Life.instant,
                tools: [], deferredMCPSummaries: [])
            result["decision"] = String(describing: decision)
        } else if mode == "manual" {
            await manualPruneToolInteractions()
            snapshot = messages
            result["decision"] = "manual"
        } else {
            let changed = try await pruneToolInteractionsIfNeeded(currentUserMessageId: history.last?.id,
                calendarContext: nil, emailContext: nil, chunkSummaries: [], totalChunkCount: 0,
                turnStartDate: P0Life.instant, tools: [], deferredMCPSummaries: [])
            snapshot = messages
            result["decision"] = changed ? "pruned" : "unchanged"
        }
        result["snapshot"] = try P0Life.json(snapshot)
        result["durable"] = try P0Life.json(messages)
        result["watermark"] = lastPromptTokens as Any? ?? NSNull()
        result["completion"] = lastCompletionTokens as Any? ?? NSNull()
        let expectedPrompt = lastPromptTokens
        let expectedCompletion = lastCompletionTokens
        // Reset only in-memory counters without invoking their write observers,
        // then exercise the actual persisted-watermark reader.
        isRestoringContextUsageSnapshot = true
        lastPromptTokens = nil
        lastCompletionTokens = nil
        isRestoringContextUsageSnapshot = false
        loadContextUsageSnapshot(clearWhenMissing: true)
        P0Life.require(lastPromptTokens == expectedPrompt && lastCompletionTokens == expectedCompletion,
                       "persisted usage watermark differs after reload")
        // The public save/reload path must preserve reasoning, tools, summaries,
        // measured costs, origin kinds and attachment references.
        guard saveConversation() else { throw P0Life.Failure("saveConversation failed") }
        let saved = messages
        messages = []
        loadConversation(clearWhenMissing: true)
        P0Life.require(try P0Life.bytes(messages) == P0Life.bytes(saved), "manager save/reload differs")
        result["rawConversation"] = try P0Life.rawFile(conversationFileURL)
        result["rawUsage"] = try P0Life.rawFile(contextUsageFileURL)
        return result
    }

    func p0Loop(history: [Message], prompt: Int?) async throws -> [String: Any] {
        await p0Seed(history, prompt: prompt, completion: 100)
        let reply = try await generateResponseWithTools(currentUserMessageId: history.last!.id, turnStartDate: P0Life.instant)
        return ["text": reply.finalText, "interactions": try P0Life.json(reply.toolInteractions),
                "measuredTools": reply.measuredToolTokens as Any? ?? NSNull(),
                "measuredUser": reply.measuredUserTokens as Any? ?? NSNull(),
                "measuredAssistant": reply.measuredAssistantTokens as Any? ?? NSNull(),
                "completion": reply.measuredAssistantCompletionTokens as Any? ?? NSNull(),
                "prompt": lastPromptTokens as Any? ?? NSNull()]
    }

    func p0Delivery(history: [Message]) throws -> [String: Any] {
        let human = history.last!
        messages = history
        pendingMidTurnMessages = []
        let nonce = "0123456789abcdef0123456789abcdef"
        let annotation = try HarnessAnnotation.makeDirectUserBatch(deliveryNonce: nonce, messages: [
            DirectUserMessageAnnotation(sourceMessageId: human.id, content: human.content, attachmentPaths: [])])
        var carriedResult = ToolResultMessage(toolCallId: "call-p0", content: "observation")
        carriedResult.harnessAnnotations = [annotation]
        let carrying = ToolInteraction(assistantMessage: P0Life.interaction().assistantMessage,
            results: [carriedResult])
        inFlightMidTurnBatch = InFlightMidTurnBatch(nonce: nonce, messages: [human])
        clearInFlightMidTurnBatchIfCarried(by: nil)
        P0Life.require(inFlightMidTurnBatch != nil, "empty interactions must not acknowledge")
        clearInFlightMidTurnBatchIfCarried(by: [P0Life.interaction()])
        P0Life.require(inFlightMidTurnBatch != nil, "plain tool output must not acknowledge")
        var retry = [carrying]
        restoreInFlightMidTurnBatch(in: &retry)
        P0Life.require(inFlightMidTurnBatch == nil && pendingMidTurnMessages.map(\.id) == [human.id], "abort must requeue once")
        P0Life.require(retry[0].results[0].harnessAnnotations.isEmpty, "abort must strip annotations")
        // Exercise the actual drain (fresh random nonce), duplicate-history
        // prevention and legacy nonce-carry acknowledgement without changing it.
        var results = [ToolResultMessage(toolCallId: "call-p0", content: "retry")]
        deliverMidTurnMessages(into: &results)
        P0Life.require(pendingMidTurnMessages.isEmpty && inFlightMidTurnBatch != nil, "redelivery armed")
        P0Life.require(messages.filter { $0.id == human.id }.count == 1, "redelivery duplicates human")
        let redelivered = ToolInteraction(assistantMessage: carrying.assistantMessage, results: results)
        clearInFlightMidTurnBatchIfCarried(by: [redelivered])
        P0Life.require(inFlightMidTurnBatch == nil, "carried nonce clears guard")
        var noFlight = [redelivered]
        restoreInFlightMidTurnBatch(in: &noFlight)
        P0Life.require(pendingMidTurnMessages.isEmpty, "successful delivery must not requeue")
        return ["canonicalIDs": messages.map { $0.id.uuidString }, "queue": pendingMidTurnMessages.count,
                "guardCleared": inFlightMidTurnBatch == nil]
    }
}

// Full active-processing lifecycle: real loop, save, error salvage, teardown,
// and (no-tools) actual automatic follow-up. No guard/drain invoked by the seam.
extension ConversationManager {
    func p0Midturn(_ mode: String, human: Message, queued: Message) async throws -> [String: Any] {
        await p0Seed([human], prompt: 1000, completion: 100)
        P0Life.require(activeProcessingTask == nil && activeRunId == nil, "prior task still active")
        pendingMidTurnMessages = [queued]
        inFlightMidTurnBatch = nil
        error = nil
        P0Life.require(persistPendingMidTurnQueue(), "queue persistence failed")
        let queuedBytes = try P0Life.rawFile(pendingMidTurnFileURL)
        HarnessNonce.overrideForTesting = { P0Life.nonce }
        isPolling = mode == "no-tools" // enables real follow-up drain, no poller is started
        defer { isPolling = false; HarnessNonce.overrideForTesting = nil }
        startActiveProcessing(for: human)
        while let task = activeProcessingTask { await task.value }
        P0Life.require(inFlightMidTurnBatch == nil, "active-processing teardown left batch armed")
        P0Life.require(messages.filter { $0.id == queued.id }.count == 1, "queued user duplicated or lost")
        P0Life.require(messages.first?.id == human.id, "human order changed")
        if mode == "abort" {
            P0Life.require(error != nil, "503 retries did not fail")
            P0Life.require(pendingMidTurnMessages.map(\.id) == [queued.id], "failed delivery must requeue once")
            // Transport failure retains history AND salvaged annotations in
            // v0.2.9; render-invariant failure strips them (separate unit gate).
            P0Life.require(messages[1].id == queued.id, "legacy abort history retained")
        } else {
            P0Life.require(error == nil && pendingMidTurnMessages.isEmpty, "successful delivery not acknowledged")
            P0Life.require(!FileManager.default.fileExists(atPath: pendingMidTurnFileURL.path), "empty queue file remains")
            P0Life.require(messages.last?.content == (mode == "no-tools" ? "follow-up final" : "midturn final"), "wrong final reply")
            if mode == "no-tools" {
                P0Life.require(messages.count == 4 && messages[1].role == .assistant && messages[2].id == queued.id, "follow-up order changed")
            } else { P0Life.require(messages[1].id == queued.id, "carried user order changed") }
        }
        let output: [String: Any] = ["history": try P0Life.json(messages), "queue": try P0Life.json(pendingMidTurnMessages),
            "guardCleared": inFlightMidTurnBatch == nil, "queuedRaw": queuedBytes,
            "rawPending": try P0Life.rawFile(pendingMidTurnFileURL, allowMissing: true), "rawConversation": try P0Life.rawFile(conversationFileURL)]
        // Leave subsequent independent scenarios clean only after observing state.
        pendingMidTurnMessages = []; P0Life.require(persistPendingMidTurnQueue(), "cleanup queue")
        return output
    }

    func p0LocalEstimates(_ history: [Message]) async throws -> [String: Any] {
        await p0Seed(history, prompt: nil, completion: nil)
        let plan = buildPrunePlan(for: history, totalTokens: 20000, targetTokens: configuredTargetContextTokens(),
            protectedIndex: lastAssistantIndexWithTools(in: history), providerIsLMStudio: true)
        return ["boundary": plan.pruningBoundary, "saved": plan.savedTokens,
            "estimates": history.map { [estimatedPromptTokens(for: $0, isLMStudio: true), toolTokensForMessage($0, isLMStudio: true)] }]
    }
}
