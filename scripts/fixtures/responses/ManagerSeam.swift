
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
    func p2Recover() { recoverInterruptedTurnSalvageIfNeeded() }
    func p2RecoveryBlocked() -> Bool { recoveryBlocked }
    func p2Effort(_ value: String) async { await handleEffortCommand(argument: value) }
    func p2ReadOnlyCommands() async {
        await handleModelCommand(argument: "")
        await handleEffortCommand(argument: "")
    }
}

// Real manager barrier, with a cancellable pending device owner.
extension ConversationManager {
    func p3PendingLoginBarrier() async throws {
        let store = SubscriptionAuthStore()
        let pending = try await store.beginLogin()
        let before = try store.read()!.generation
        subscriptionLoginRunID = UUID()
        subscriptionLoginTask = Task { [weak self] in
            defer { self?.subscriptionLoginTask = nil; self?.subscriptionLoginRunID = nil }
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                _ = try await store.commitLogin(SubscriptionSelftest.credential(), pending: pending)
            } catch {}
        }
        let result = await quiesceBackgroundWorkForMindRestore(timeoutSeconds: 2)
        try P2Life.require(result == nil && subscriptionLoginTask == nil, "Mind barrier awaits subscription owner exit")
        try P2Life.require(try store.read()?.pendingLogin == nil, "Mind barrier durably cancels pending login")
        try P2Life.require(try store.read()?.generation == before, "Mind barrier preserves established account")
        let failures = await deleteAllMemory()
        try P2Life.require(failures.isEmpty, "wipe completes with subscription account")
        try P2Life.require(try store.read()?.credential == nil, "wipe signs out subscription locally")
    }
}
