
// Test-only access compiled into disposable builds, never the production binary.
extension ConversationManager {
    func p2Seed(_ history: [Message]) async throws {
        messages = history
        lastPromptTokens = 1000
        lastCompletionTokens = 20
        frozenCalendarContext = ""
        frozenEmailContext = ""
        frozenContextDay = Calendar.current.startOfDay(for: Date())
        await openRouterService.configure(apiKey: "synthetic-unused-router-key")
        pendingMidTurnMessages = []
        inFlightMidTurnBatch = nil
        error = nil
        guard saveConversation() else { throw P2Life.Failure("seed persistence") }
    }

    func p2Turn(human: Message, queued: Message? = nil) async throws -> [Message] {
        messages.append(human)
        if let queued { pendingMidTurnMessages = [queued]; _ = persistPendingMidTurnQueue() }
        guard saveConversation() else { throw P2Life.Failure("user persistence") }
        startActiveProcessing(for: human)
        while let task = activeProcessingTask { await task.value }
        return messages
    }

    func p2Queue() -> [Message] { pendingMidTurnMessages }
    func p2Error() -> String? { error }
    func p2Reload() throws -> [Message] {
        messages = []
        loadConversation(clearWhenMissing: true)
        return messages
    }
    func p2Prune(_ history: [Message]) async throws -> [Message] {
        try await p2Seed(history)
        lastPromptTokens = 20000
        await manualPruneToolInteractions()
        return messages
    }
    func p2ReadOnlyCommands() async {
        await handleModelCommand(argument: "")
        await handleEffortCommand(argument: "")
    }
}
