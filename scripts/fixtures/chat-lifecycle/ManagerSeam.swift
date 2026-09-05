
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
            let decision = await pruneStoredToolInteractionsMidLoop(messagesForLLM: &snapshot,
                currentTurnInteractions: current, calendarContext: nil, emailContext: nil, chunkSummaries: [],
                totalChunkCount: 0, currentUserMessageId: history.last?.id, turnStartDate: P0Life.instant,
                tools: [], deferredMCPSummaries: [])
            result["decision"] = String(describing: decision)
        } else if mode == "manual" {
            await manualPruneToolInteractions()
            snapshot = messages
            result["decision"] = "manual"
        } else {
            let changed = await pruneToolInteractionsIfNeeded(currentUserMessageId: history.last?.id,
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
        P0Life.require(messages == saved, "manager save/reload differs")
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
