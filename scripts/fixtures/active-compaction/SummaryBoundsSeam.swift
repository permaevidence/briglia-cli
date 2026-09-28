
// Only present in the isolated owner-test build: compaction-summary bounds
// (one plain retry, specific failure reasons, spend for every attempt).
extension ConversationManager {
    func activeTestSummaryBounds(server: CaptureServer, wire: ProviderWireProtocol, file: URL) async throws {
        typealias T = CompactionTestInputs
        let tag = wire == .responses ? " (Responses)" : " (Chat Completions)"
        func resetScripts() { T.summaryScript = []; T.pruneScript = []; T.summaryRequests = 0; T.pruneRequests = 0 }
        func runTurn(_ script: [String]) async throws -> [Message] {
            try await activeTestSeed(); server.clear(); resetScripts()
            T.dynamicWire = wire; T.dynamicPath = file.path; T.compactions = 0; T.ordinaryCalls = 0
            T.summaryScript = script
            defer { T.dynamicWire = nil; T.summaryScript = [] }
            return try await activeTestTurn(Message(role: .user, content: "Complete all phases without ending the turn."), queued: nil)
        }
        let cleanRun = try await runTurn([])
        let baseline = T.summaryRequests
        try T.check(cleanRun.last?.content == "FINAL_COMPACTION_OK" && T.compactions == 3 && baseline >= 3,
            "SBL0 clean run baseline completes three compactions" + tag)

        // One bad reply, then a good one: the same compaction succeeds and the
        // turn goes on, with exactly one extra summary request.
        let exact = String(repeating: "S", count: CompactionSummaryPolicy.maxBytes)
        let cases: [(String, [String])] = [
            ("empty", [try T.summaryBody(protocol: wire, text: "")]),
            ("cut off", [try T.summaryBody(protocol: wire, text: "Goal: partial summ", cut: true)]),
            ("over the limit, then exactly 65,536 bytes", [try T.summaryBody(protocol: wire, text: exact + "S"),
                                                           try T.summaryBody(protocol: wire, text: exact)]),
        ]
        for (name, script) in cases {
            let history = try await runTurn(script)
            try T.check(history.last?.content == "FINAL_COMPACTION_OK" && T.compactions == 3,
                "SBL1 \(name) summary is retried and the turn completes" + tag)
            // A carried 65,536-byte prior summary shrinks later source fragments,
            // so that case may need more (smaller) requests afterwards.
            let extra = name.hasPrefix("over") ? T.summaryRequests >= baseline + 1 : T.summaryRequests == baseline + 1
            try T.check(extra, "SBL2 \(name) costs one extra summary request for the retry" + tag)
        }
        // The 65,536-byte summary was accepted as the first compaction's result:
        // it is carried as the prior summary into the next compaction.
        let carried = server.completeRequests.filter { String(decoding: $0.body, as: UTF8.self).contains("ACTIVE TURN COMPACTION") }
            .contains { String(decoding: $0.body, as: UTF8.self).contains(String(repeating: "S", count: 60_000)) }
        try T.check(carried, "SBL3 exactly 65,536-byte summary accepted and carried into the next compaction" + tag)
        // Every summary reply exactly at the limit: the persisted turn summary
        // itself is 65,536 bytes and the turn still completes (selection and
        // source fragments budget for the larger summary).
        let atLimit = try await runTurn(Array(repeating: try T.summaryBody(protocol: wire, text: exact), count: 60))
        try T.check(atLimit.last?.content == "FINAL_COMPACTION_OK" && T.compactions == 3
                    && atLimit.last?.activeTurnCompaction?.summaryText.utf8.count == CompactionSummaryPolicy.maxBytes,
            "SBL3b 65,536-byte summaries persist and the turn completes" + tag)

        // Two bad replies: today's stop, with the specific reason.
        let stops: [(String, String, String)] = [
            ("empty", try T.summaryBody(protocol: wire, text: " "), "the reply was empty"),
            ("cut off", try T.summaryBody(protocol: wire, text: "partial", cut: true),
             wire == .responses ? "the reply was cut off by the provider (incomplete: max_output_tokens)"
                                : "the reply was cut off by the provider (finish_reason: length)"),
            ("over the limit", try T.summaryBody(protocol: wire, text: exact + "SS"), "the summary was 65538 bytes, over the 65536-byte limit"),
        ]
        for (name, bad, reason) in stops {
            let history = try await runTurn([bad, bad])
            let last = history.last
            try T.check(last?.content.contains("Compaction summary rejected after 2 attempts: " + reason) == true
                        && last?.content.contains("Send another message to retry") == true,
                "SBL4 two \(name) replies stop the turn with the specific reason" + tag)
            try T.check(T.summaryRequests == 2 && T.compactions == 0, "SBL5 two \(name) replies make exactly two attempts, no compaction" + tag)
            try T.check(last?.activeTurnCompaction == nil && last?.toolInteractions.isEmpty == true
                        && last?.pruneArchiveReferences.isEmpty == false,
                "SBL6 two \(name) replies replace nothing; the work stays in its snapshot" + tag)
        }
        try await activeTestSummaryBoundsSpend(server: server, wire: wire, file: file, runTurn: runTurn)
        try await activeTestPruneRetry(server: server, wire: wire)
    }

    func activeTestSummaryBoundsSpend(server: CaptureServer, wire: ProviderWireProtocol, file: URL,
                                      runTurn: ([String]) async throws -> [Message]) async throws {
        guard wire == .chatCompletions else { return } // Responses reports no provider spend
        typealias T = CompactionTestInputs
        let before = KeychainHelper.openRouterSpendSnapshot().today
        let history = try await runTurn([try T.summaryBody(protocol: wire, text: "", cut: true, nullContent: true, cost: 0.3),
                                         try T.summaryBody(protocol: wire, text: "Goal kept. Verified.", cost: 0.2)])
        let delta = KeychainHelper.openRouterSpendSnapshot().today - before
        try T.check(history.last?.content == "FINAL_COMPACTION_OK" && abs(delta - 0.5) < 1e-9,
            "SBL7 rejected and retried summary attempts are both charged (delta \(delta))")
    }

    func activeTestPruneRetry(server: CaptureServer, wire: ProviderWireProtocol) async throws {
        typealias T = CompactionTestInputs
        let tag = wire == .responses ? " (Responses)" : " (Chat Completions)"
        func round(_ id: String, cost: Int) -> ToolInteraction {
            ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "done", toolCalls: [
                ToolCall(id: id, type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))
            ]), results: [ToolResultMessage(toolCallId: id, content: "evidence")], measuredTokenCost: cost)
        }
        func prune(_ script: [String]) async throws -> String? {
            try await activeTestSeed(); server.clear()
            T.summaryScript = []; T.pruneScript = script; T.pruneRequests = 0
            defer { T.pruneScript = [] }
            messages = [Message(role: .user, content: "Earlier request"),
                Message(role: .assistant, content: "Earlier answer", toolInteractions: [round("old", cost: 160000)]),
                Message(role: .assistant, content: "Recent answer", toolInteractions: [round("recent", cost: 100000)]),
                Message(role: .user, content: "Current task")]
            guard saveConversation() else { throw T.Failure("prune retry seed") }
            lastPromptTokens = 250001
            var history = messages
            _ = try await pruneStoredToolInteractionsMidLoop(messagesForLLM: &history,
                currentTurnInteractions: [], calendarContext: nil, emailContext: nil, chunkSummaries: [], totalChunkCount: 0,
                currentUserMessageId: messages.last!.id, turnStartDate: Date(), tools: [], deferredMCPSummaries: [])
            return history.compactMap(\.prunedContextSummary).joined(separator: "\n")
        }
        let good = try T.summaryBody(protocol: wire, text: "PRUNE_RETRY_OK evidence verified.", cost: 0.1)
        for (name, bad) in [("empty", try T.summaryBody(protocol: wire, text: "")),
                            ("cut off", try T.summaryBody(protocol: wire, text: "PRUNE_PARTIAL", cut: true))] {
            let kept = try await prune([bad, good])
            try T.check(kept?.contains("PRUNE_RETRY_OK") == true && kept?.contains("PRUNE_PARTIAL") == false && T.pruneRequests == 2,
                "SBL8 past-turn prune summary: \(name) reply retried once before any fallback" + tag)
            let fallback = try await prune([bad, bad])
            try T.check(fallback?.contains("[Fallback prune summary]") == true && fallback?.contains("PRUNE_PARTIAL") == false
                        && T.pruneRequests == 2,
                "SBL9 past-turn prune summary: two \(name) replies fall back to the programmatic summary" + tag)
        }
        if wire == .chatCompletions {
            let before = KeychainHelper.openRouterSpendSnapshot().today
            _ = try await prune([try T.summaryBody(protocol: wire, text: "x", cut: true, cost: 0.3), good])
            let delta = KeychainHelper.openRouterSpendSnapshot().today - before
            try T.check(abs(delta - 0.4) < 1e-9, "SBL10 past-turn prune summary attempts are charged (delta \(delta))")
        }
        // An oversized newest historical turn takes the bounded builder; its
        // rejected replies are retried once, then fall back as before.
        func oversized(_ script: [String]) async throws -> String? {
            try await activeTestSeed(); server.clear()
            T.pruneScript = []; T.summaryScript = script; T.summaryRequests = 0
            defer { T.summaryScript = [] }
            let giant = ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "legacy work", toolCalls: [
                ToolCall(id: "giant-legacy", type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))
            ]), results: [ToolResultMessage(toolCallId: "giant-legacy", content: "GIANT_EXACT")], measuredTokenCost: 300000)
            messages = [Message(role: .user, content: "Legacy task"), Message(role: .assistant, content: "Done", toolInteractions: [giant]),
                Message(role: .user, content: "Next task")]
            guard saveConversation() else { throw T.Failure("giant seed") }
            lastPromptTokens = 310000
            var history = messages
            _ = try await pruneStoredToolInteractionsMidLoop(messagesForLLM: &history, currentTurnInteractions: [],
                calendarContext: nil, emailContext: nil, chunkSummaries: [], totalChunkCount: 0,
                currentUserMessageId: messages.last!.id, turnStartDate: Date(), tools: [], deferredMCPSummaries: [])
            return history.compactMap(\.prunedContextSummary).joined(separator: "\n")
        }
        let bad = try T.summaryBody(protocol: wire, text: "GIANT_PARTIAL", cut: true)
        let retried = try await oversized([bad, try T.summaryBody(protocol: wire, text: "GIANT_EXACT retained after retry.")])
        try T.check(retried?.contains("GIANT_EXACT retained after retry.") == true && T.summaryRequests == 2,
            "SBL11 oversized historical summary retried once before any fallback" + tag)
        let fellBack = try await oversized([bad, bad])
        try T.check(fellBack?.contains("[Fallback prune summary]") == true && fellBack?.contains("GIANT_PARTIAL") == false
                    && T.summaryRequests == 2,
            "SBL12 oversized historical summary: two rejected replies fall back as before" + tag)
    }
}
