import Foundation

// MARK: - Subagent Runner

/// Runs a single subagent task to completion with an isolated message history
/// and a filtered tool list. Mirrors Claude Code's Agent/Task tool behavior.
actor SubagentRunner {
    /// If no progress (LLM response or tool completion) occurs within this
    /// interval, the subagent is considered stuck and is force-killed.
    private static let stalenessTimeout: TimeInterval = 20 * 60  // 20 minutes

    /// Tracks the last time a meaningful operation completed. Reset after each
    /// LLM response or tool execution batch.
    private var lastProgressDate = Date()
    struct Invocation {
        let subagentType: String
        let description: String
        let taskPrompt: String
        let modelOverride: String?        // "cheap-vision"/"cheap-text"/"inherit"/nil (lane names, see SubagentModelLanes)
        let runInBackground: Bool         // Informational; actual routing happens in ToolExecutor.executeAgent
    }

    struct RunResult {
        let sessionId: String             // persistent session handle
        let isNewSession: Bool            // true if freshly created, false if resumed
        let finalMessage: String          // capped at 32 KB
        let turnsUsed: Int
        let toolsCalled: [String]         // unique tool names in call order
        let filesTouched: [String]        // paths that appeared/advanced in FilesLedger during the run
        let spendUSD: Double
        let error: String?                // nil on success
        /// Whether the post-run session state (including the final assistant
        /// text) reached disk. Triage SKIP acks are gated on this — the SKIP
        /// record persisted in the session IS the delivery (§3b).
        var sessionPersisted: Bool = false
        /// The model that actually served this run: a concrete cheap-lane
        /// slug or "inherit" for the parent model. Surfaced in the result
        /// JSON so the parent can SEE what ran — in particular, an agent
        /// whose frontmatter lane is unconfigured degrades to inherit (full
        /// parent-model price), and this field is where that shows up.
        var modelUsed: String? = nil

        func asJSON() -> String {
            var obj: [String: Any] = [
                "session_id": sessionId,
                "is_new_session": isNewSession,
                "final_message": finalMessage,
                "turns_used": turnsUsed,
                "tools_called": toolsCalled,
                "files_touched": filesTouched,
                "spend_usd": spendUSD
            ]
            if let error { obj["error"] = error }
            if let modelUsed { obj["model_used"] = modelUsed }
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{\"error\": \"Failed to serialize subagent result\"}"
        }
    }

    /// Hard cap on the subagent's final message returned to the parent. Claude Code
    /// has no documented cap; 32 KB covers its typical envelope (long Plans,
    /// comprehensive general-purpose analyses) while retaining a runaway-protection
    /// backstop. Truncation adds a `[...truncated]` marker on a UTF-8 boundary.
    private static let finalMessageByteCap = 32 * 1024

    /// Entry point. Owns the per-session FIFO lock's whole lifecycle so the
    /// acquire/release pairing is structural, not documentary: resumed sessions
    /// are serialized here (a fire-triggered triage run, a second fire on a
    /// shared session, and a main-agent resume otherwise race — each Agent call
    /// constructs its own SubagentRunner, so actor isolation alone doesn't
    /// serialize them). runBody is non-throwing, so every return path passes
    /// back through the release — a future early return inside the body cannot
    /// wedge the lane. Fresh sessions can't race: their id is unknown to anyone
    /// else until created. (defer can't await, hence wrapper instead of defer.)
    func run(
        invocation: Invocation,
        sessionId: String?,
        openRouterService: OpenRouterService,
        toolExecutor: ToolExecutor,
        imagesDirectory: URL,
        documentsDirectory: URL,
        parentTools: [ToolDefinition]
    ) async -> RunResult {
        guard let sid = sessionId else {
            let result = await runBody(
                invocation: invocation,
                sessionId: nil,
                openRouterService: openRouterService,
                toolExecutor: toolExecutor,
                imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory,
                parentTools: parentTools
            )
            await BackgroundProcessRegistry.shared.terminateOwned(owner: toolExecutor.bashOwner)
            return result
        }
        await SubagentSessionLocks.shared.acquire(sid)
        let result = await runBody(
            invocation: invocation,
            sessionId: sid,
            openRouterService: openRouterService,
            toolExecutor: toolExecutor,
            imagesDirectory: imagesDirectory,
            documentsDirectory: documentsDirectory,
            parentTools: parentTools
        )
        // Owned background jobs never outlive the run (§10.5): after this
        // point nobody could see, manage, or be notified about them — a
        // resumed session gets a fresh executor with a fresh owner token.
        await BackgroundProcessRegistry.shared.terminateOwned(owner: toolExecutor.bashOwner)
        await SubagentSessionLocks.shared.release(sid)
        return result
    }

    private func runBody(
        invocation: Invocation,
        sessionId: String?,
        openRouterService: OpenRouterService,
        toolExecutor: ToolExecutor,
        imagesDirectory: URL,
        documentsDirectory: URL,
        parentTools: [ToolDefinition]
    ) async -> RunResult {
        // 1. Resolve subagent type
        guard let subagentType = SubagentTypes.find(name: invocation.subagentType) else {
            return RunResult(
                sessionId: sessionId ?? "",
                isNewSession: false,
                finalMessage: "",
                turnsUsed: 0,
                toolsCalled: [],
                filesTouched: [],
                spendUSD: 0,
                error: "Unknown subagent_type '\(invocation.subagentType)'. Valid values: \(SubagentTypes.allNames().joined(separator: ", "))."
            )
        }

        // 2. Build filtered tool list (rebuilt fresh each run so new MCPs are picked up).
        // mid_turn_message_user is main-agent-only: subagents have no channel to
        // the user — anything user-relevant belongs in their final result.
        var filteredTools = parentTools.filter { $0.function.name != "Agent" && $0.function.name != "mid_turn_message_user" }
        if let whitelist = subagentType.allowedToolNames {
            filteredTools = filteredTools.filter { whitelist.contains($0.function.name) }
        }
        // Bash schema and executor capability must agree
        // (BASH_V2_SCHEMA_CLEANUP_PLAN §3.3). Subagents share the managed
        // lifecycle vocabulary but never the main conversation's lanes:
        //  - with bash_manage: the subagent managed pair — same
        //    wait_seconds/kill_after_seconds contract scoped to jobs OWNED
        //    by this run (no watch, no completion notices, jobs terminated
        //    when the run ends), executor capability .subagentManaged;
        //  - bash without bash_manage: the foreground-only schema (it could
        //    never inspect or kill a detached process), executor capability
        //    .foregroundOnly — detaching is rejected, not honored.
        let filteredNames = Set(filteredTools.map { $0.function.name })
        if filteredNames.contains("bash") {
            if filteredNames.contains("bash_manage") {
                filteredTools = filteredTools.map {
                    switch $0.function.name {
                    case "bash":        return AvailableTools.bashSubagentManaged
                    case "bash_manage": return AvailableTools.bashManageSubagentManaged
                    default:            return $0
                    }
                }
                await toolExecutor.setSubagentBashCapability(.subagentManaged)
            } else {
                filteredTools = filteredTools.map {
                    $0.function.name == "bash" ? AvailableTools.bashForegroundOnly : $0
                }
                await toolExecutor.setSubagentBashCapability(.foregroundOnly)
            }
        }
        // Subagents get all routed tools directly (always + deferred combined)
        // since they have their own context window and don't benefit from deferral.
        // forbidMCP types (watcher-triage) skip MCP entirely — not even the
        // routing file can opt them in.
        if !subagentType.forbidMCP {
            let allMcpTools = await MCPRegistry.shared.allToolDefinitions()
            let subagentMcpTools = MCPAgentRouting.allToolsForAgent(
                agent: subagentType.name,
                allTools: allMcpTools,
                fallbackPatterns: subagentType.mcpToolPatterns
            )
            filteredTools += subagentMcpTools
        }
        let allowedToolNames = Set(filteredTools.map { $0.function.name })

        // 3. Session: create or resume. Serialization of resumed sessions is
        // handled by run() above — by the time runBody executes, this runner
        // holds the session's FIFO lock (when sessionId is non-nil).
        let registry = SubagentSessionRegistry.shared
        let resolvedSessionId: String
        let isNew: Bool
        var messagesForLLM: [Message]
        var priorToolInteractions: [ToolInteraction]

        if let sid = sessionId, let session = await registry.prepareResume(sessionId: sid, continuationPrompt: invocation.taskPrompt) {
            resolvedSessionId = sid
            isNew = false
            messagesForLLM = session.messages
            priorToolInteractions = session.toolInteractions
        } else {
            let (newId, session) = await registry.create(
                subagentType: invocation.subagentType,
                description: invocation.description,
                initialPrompt: invocation.taskPrompt
            )
            resolvedSessionId = newId
            isNew = true
            messagesForLLM = session.messages
            priorToolInteractions = session.toolInteractions
        }
        let syntheticUser = messagesForLLM.last ?? Message(role: .user, content: invocation.taskPrompt, timestamp: Date())

        // 4. Pick the model. Resolution order (highest precedence first):
        //    a. Per-call Agent-tool LANE hint ("cheap-vision"/"cheap-text").
        //       'inherit' is the schema's habitual default token, NOT a lane:
        //       it means "no per-call preference" and falls through to (b) —
        //       a custom agent's frontmatter lane is user configuration and
        //       must survive routine inherit-passing calls.
        //    b. SubagentType.preferredModel (.cheapVision/.cheapText → configured lane, .inherit → nil).
        //    c. Fall through to parent's configured model (handled by OpenRouterService).
        // The legacy per-agent pin (agent-models.json) is RETIRED: a subagent
        // runs either the parent's model or a user-configured lane, nothing
        // else. Reasoning effort always inherits.

        // Type-level lane default (user-agent frontmatter `model:` field).
        // An unconfigured lane degrades to inherit with a log line: type
        // defaults must never hard-fail a run — only per-call hints do, and
        // those are validated loudly in ToolExecutor before the run starts.
        let typeLevelOverride: (model: String, textOnly: Bool)?
        if let lane = subagentType.preferredModel.lane {
            if let model = SubagentModelLanes.configuredModel(lane) {
                typeLevelOverride = (model, lane.isTextOnly)
            } else {
                print("[SubagentRunner] Lane '\(lane.rawValue)' (type default of '\(subagentType.name)') is not configured for the current provider; inheriting the parent model.")
                typeLevelOverride = nil
            }
        } else {
            typeLevelOverride = nil
        }

        // Per-call Agent-tool lane hint. ToolExecutor already rejected
        // unconfigured/unknown hints loudly for main-agent calls; anything
        // that still arrives here unresolved (e.g. a watcher lane the user
        // cleared while a batch was pending) degrades to the next precedence
        // level with a log line rather than dropping the run.
        let perCallLane: (model: String, textOnly: Bool)?
        switch SubagentModelLanes.resolve(hint: invocation.modelOverride) {
        case .lane(let lane, let model):
            perCallLane = (model, lane.isTextOnly)
        case .inherit:
            perCallLane = nil
        case .unconfigured(let lane):
            print("[SubagentRunner] Lane '\(lane.rawValue)' is not configured for the current provider; falling back to type default.")
            perCallLane = nil
        case .unknown(let hint):
            print("[SubagentRunner] Ignoring unknown model hint '\(hint)'; falling back to type default.")
            perCallLane = nil
        }

        // Provider routing preferences had a single source (the retired
        // Gemini cheapFast profile); lanes stay on the parent's gateway by
        // construction and need none.
        let effectiveProviderOverride: [String]? = nil
        let effectiveReasoningOverride: String? = nil
        let effectiveModelOverride: String?
        /// Non-nil when a lane picked the model — the lane's text-only
        /// semantics then govern multimodal preprocessing for this run,
        /// overriding the global (main-model) text-only flag.
        let effectiveTextOnlyOverride: Bool?
        if let perCallLane {
            // Per-call hint wins over the type default.
            effectiveModelOverride = perCallLane.model
            effectiveTextOnlyOverride = perCallLane.textOnly
        } else if let typeLevelOverride {
            effectiveModelOverride = typeLevelOverride.model
            effectiveTextOnlyOverride = typeLevelOverride.textOnly
        } else {
            effectiveModelOverride = nil
            effectiveTextOnlyOverride = nil
        }

        // 5. Context budget + compaction parameters. Mid-run compaction fires
        // when the real prompt token count crosses the threshold: everything
        // except the newest ~compactionKeepTokens is summarized and replaced
        // by a [SESSION HISTORY SUMMARY] message, and the run continues. On
        // summarization failure the run falls back to force-finish, so the
        // worst case is identical to the pre-compaction behavior.
        let turnTokenBudget = Self.turnTokenBudget()
        let compactionThreshold = max(1, (turnTokenBudget * Self.compactionThresholdPercent) / 100)
        let compactionKeepTokens = min(Self.compactionKeepTokensCap, max(1, turnTokenBudget / 4))
        var compactionsUsed = 0

        // Eager compaction on resume. Sessions normally stay under the budget
        let snapshot = await openRouterService.executionContext(modelOverride: effectiveModelOverride,
            providerOverride: effectiveProviderOverride, reasoningEffortOverride: effectiveReasoningOverride,
            textOnlyOverride: effectiveTextOnlyOverride, lane: .subagent(resolvedSessionId))
        let responsesExecution: ProviderExecutionContext? = snapshot.wireProtocol == .responses ? snapshot : nil
        if responsesExecution != nil,
           !(await registry.checkpointResponses(sessionId: resolvedSessionId, interactions: priorToolInteractions)) {
            return RunResult(sessionId: resolvedSessionId, isNewSession: isNew, finalMessage: "",
                turnsUsed: 0, toolsCalled: [], filesTouched: [], spendUSD: 0,
                error: "Cannot persist subagent history before Responses dispatch.", sessionPersisted: false)
        }
        // (mid-run compaction bounds them before they are persisted), but a
        // lowered budget, a smaller-window model, or a legacy session from
        // before mid-run compaction existed can still arrive oversized.
        if !isNew,
           Self.estimatedContextTokens(messages: messagesForLLM, interactions: priorToolInteractions) >= compactionThreshold,
           let compacted = await compactContext(
               messages: messagesForLLM,
               interactions: priorToolInteractions,
               keepTokens: compactionKeepTokens,
               openRouterService: openRouterService,
               imagesDirectory: imagesDirectory,
               documentsDirectory: documentsDirectory,
               modelOverride: effectiveModelOverride,
               providerOverride: effectiveProviderOverride,
               reasoningEffortOverride: effectiveReasoningOverride,
               textOnlyOverride: effectiveTextOnlyOverride,
           execution: responsesExecution, lane: .subagent(resolvedSessionId)
) {
            messagesForLLM = compacted.messages
            priorToolInteractions = compacted.interactions
            compactionsUsed += 1
            await registry.applyCompaction(
                sessionId: resolvedSessionId,
                messages: compacted.messages,
                toolInteractions: compacted.interactions
            )
            print("[SubagentRunner] Compacted oversized session \(resolvedSessionId) at resume → ~\(compacted.estimatedTokens) tokens")
        }

        // 6. Capture a pre-run snapshot of the FilesLedger to diff after the run.
        let preSnapshot = await FilesLedgerDiff.snapshot()

        // 7. Tool loop
        var toolInteractions: [ToolInteraction] = priorToolInteractions
        var toolsCalledOrdered: [String] = []
        var seenToolNames = Set<String>()
        var totalSpendUSD: Double = 0
        var turnsUsed = 0
        var runError: String? = nil
        var finalText: String = ""
        var finalReplay: ResponsesReplayEnvelope? = nil

        let maxTurns = AgentTurnOverrides.override(forAgent: subagentType.name)
            ?? subagentType.defaultMaxTurns
        let turnStartDate = Date()
        var lastPromptTokens: Int? = nil

        loop: for round in 1...maxTurns {
            turnsUsed = round
            do {
                try Task.checkCancellation()
                try checkStaleness()

                // Mid-run compaction: when the real context size crosses the
                // threshold, summarize the oldest history and keep working.
                if let pt = lastPromptTokens,
                   pt >= compactionThreshold,
                   compactionsUsed < Self.maxCompactionsPerRun,
                   let compacted = await compactContext(
                       messages: messagesForLLM,
                       interactions: toolInteractions,
                       keepTokens: compactionKeepTokens,
                       openRouterService: openRouterService,
                       imagesDirectory: imagesDirectory,
                       documentsDirectory: documentsDirectory,
                       modelOverride: effectiveModelOverride,
                       providerOverride: effectiveProviderOverride,
                       reasoningEffortOverride: effectiveReasoningOverride,
                       textOnlyOverride: effectiveTextOnlyOverride,
                   execution: responsesExecution, lane: .subagent(resolvedSessionId)
) {
                    messagesForLLM = compacted.messages
                    toolInteractions = compacted.interactions
                    priorToolInteractions = compacted.interactions  // commitRun appends relative to this baseline
                    lastPromptTokens = compacted.estimatedTokens
                    compactionsUsed += 1
                    await registry.applyCompaction(
                        sessionId: resolvedSessionId,
                        messages: compacted.messages,
                        toolInteractions: compacted.interactions
                    )
                    print("[SubagentRunner] Compacted context mid-run (\(compactionsUsed)/\(Self.maxCompactionsPerRun)): ~\(pt) → ~\(compacted.estimatedTokens) tokens")
                }

                // If context still exceeds the turn budget (compaction failed,
                // exhausted, or unavailable), force a final response. Tools and
                // system prompt stay identical to preserve prompt cache; the
                // stop instruction goes in a tail system message instead.
                let forceFinish = lastPromptTokens.map { $0 >= turnTokenBudget } ?? false
                let response = try await openRouterService.generateResponse(
                    messages: messagesForLLM,
                    imagesDirectory: imagesDirectory,
                    documentsDirectory: documentsDirectory,
                    tools: filteredTools,
                    toolResultMessages: toolInteractions.isEmpty ? nil : toolInteractions,
                    calendarContext: nil,
                    emailContext: nil,
                    chunkSummaries: nil,
                    totalChunkCount: 0,
                    currentUserMessageId: syntheticUser.id,
                    turnStartDate: turnStartDate,
                    finalResponseInstruction: subagentType.systemPromptSuffix,
                    tailSystemMessage: forceFinish
                        ? "[CONTEXT LIMIT] This turn has reached the maximum allowed context window and automatic history compaction is unavailable or exhausted. Do NOT call any more tools. Provide your final answer NOW — summarize everything you accomplished, what files were touched, what you discovered, and what remains to be done."
                        : nil,
                    modelOverride: effectiveModelOverride,
                    providerOverride: effectiveProviderOverride,
                    reasoningEffortOverride: effectiveReasoningOverride,
                    textOnlyOverride: effectiveTextOnlyOverride,
                    execution: responsesExecution, lane: .subagent(resolvedSessionId)
                )
                markProgress()  // LLM responded — subagent is alive

                switch response {
                case .text(let content, _, _, let promptTk, _, let spend, let native):
                    if let spend { totalSpendUSD += spend }
                    if let pt = promptTk { lastPromptTokens = pt }
                    finalText = content
                    finalReplay = native?.envelope
                    break loop

                case .toolCalls(let assistantMessage, let calls, let promptTk, _, let spend):
                    if let spend { totalSpendUSD += spend }
                    if let pt = promptTk { lastPromptTokens = pt }

                    if forceFinish {
                        var forceInteractions = toolInteractions + [
                            disabledToolInteraction(
                                assistantMessage: assistantMessage,
                                calls: calls,
                                reason: "Tool calls are disabled during the subagent context-limit summary. Return the final summary as plain text only."
                            )
                        ]
                        for attempt in 1...4 {
                            let retryResponse = try await openRouterService.generateResponse(
                                messages: messagesForLLM,
                                imagesDirectory: imagesDirectory,
                                documentsDirectory: documentsDirectory,
                                tools: filteredTools,
                                toolResultMessages: forceInteractions.isEmpty ? nil : forceInteractions,
                                calendarContext: nil,
                                emailContext: nil,
                                chunkSummaries: nil,
                                totalChunkCount: 0,
                                currentUserMessageId: syntheticUser.id,
                                turnStartDate: turnStartDate,
                                finalResponseInstruction: subagentType.systemPromptSuffix,
                                tailSystemMessage: """
                                    [CONTEXT LIMIT SUMMARY RETRY \(attempt)/4] This turn has reached the maximum allowed context window. \
                                    The tool call(s) you requested were not executed. Do NOT call any more tools. \
                                    Provide your final answer NOW — summarize everything you accomplished, what files were touched, \
                                    what you discovered, and what remains to be done.
                                    """,
                                modelOverride: effectiveModelOverride,
                                providerOverride: effectiveProviderOverride,
                                reasoningEffortOverride: effectiveReasoningOverride,
                                textOnlyOverride: effectiveTextOnlyOverride,
                                execution: responsesExecution, lane: .subagent(resolvedSessionId)
                            )
                            markProgress()

                            switch retryResponse {
                            case .text(let content, _, _, let retryPromptTk, _, let retrySpend, let native):
                                if let retrySpend { totalSpendUSD += retrySpend }
                                if let pt = retryPromptTk { lastPromptTokens = pt }
                                finalText = content
                                finalReplay = native?.envelope
                                break loop
                            case .toolCalls(let retryAssistantMessage, let retryCalls, let retryPromptTk, _, let retrySpend):
                                if let retrySpend { totalSpendUSD += retrySpend }
                                if let pt = retryPromptTk { lastPromptTokens = pt }
                                forceInteractions.append(disabledToolInteraction(
                                    assistantMessage: retryAssistantMessage,
                                    calls: retryCalls,
                                    reason: "Tool calls are disabled during the subagent context-limit summary. Return the final summary as plain text only."
                                ))
                                if attempt == 4 {
                                    let refusedTools = retryCalls.map { $0.function.name }.joined(separator: ", ")
                                    print("[SubagentRunner] Refused repeated tool call(s) during context-limit force-finish: \(refusedTools)")
                                    runError = "Subagent reached the context limit and the model kept attempting to call tools instead of returning a final summary. No tools were executed."
                                    finalText = "Subagent stopped at the context limit before it could produce a final summary. It attempted to call additional tools (\(refusedTools)), but those calls were refused to avoid extra side effects or spend."
                                    break loop
                                }
                            }
                        }
                    }

                    // Filter out any tool calls the subagent is not allowed to make.
                    var executableCalls: [ToolCall] = []
                    var blockedResults: [ToolResultMessage] = []
                    for call in calls {
                        if allowedToolNames.contains(call.function.name) {
                            executableCalls.append(call)
                            if !seenToolNames.contains(call.function.name) {
                                seenToolNames.insert(call.function.name)
                                toolsCalledOrdered.append(call.function.name)
                            }
                        } else {
                            let blocked = ToolResultMessage(
                                toolCallId: call.id,
                                content: "{\"error\": \"Tool '\(call.function.name)' is not available to this subagent.\"}"
                            )
                            blockedResults.append(blocked)
                        }
                    }

                    if responsesExecution != nil {
                        let pending = toolInteractions + [ToolInteraction(assistantMessage: assistantMessage,
                            results: calls.map { ToolResultMessage(toolCallId: $0.id,
                                content: "[Interrupted tool intent: outcome unknown. Inspect external state before repeating this call.]") })]
                        guard await registry.checkpointResponses(sessionId: resolvedSessionId, interactions: pending) else {
                            throw ResponsesFailure.failed("cannot persist subagent tool intent")
                        }
                        toolInteractions = pending
                    }
                    var toolResults: [ToolResultMessage] = []
                    if !executableCalls.isEmpty {
                        let executed = try await executeWithTimeout(executableCalls, using: toolExecutor)
                        toolResults.append(contentsOf: executed)
                    }
                    toolResults.append(contentsOf: blockedResults)
                    markProgress()  // Tools completed — subagent is alive

                    // Accumulate any tool-internal spend (e.g. web_search nested API calls).
                    for r in toolResults { if let s = r.spendUSD { totalSpendUSD += s } }

                    // Reorder to match the assistant's tool_call order.
                    var ordered: [ToolResultMessage] = []
                    var remaining = toolResults
                    for call in assistantMessage.toolCalls {
                        if let idx = remaining.firstIndex(where: { $0.toolCallId == call.id }) {
                            ordered.append(remaining.remove(at: idx))
                        }
                    }
                    if !remaining.isEmpty { ordered.append(contentsOf: remaining) }

                    let completed = ToolInteraction(assistantMessage: assistantMessage, results: ordered)
                    if responsesExecution != nil {
                        toolInteractions[toolInteractions.count - 1] = completed
                        guard await registry.checkpointResponses(sessionId: resolvedSessionId, interactions: toolInteractions) else {
                            throw ResponsesFailure.failed("cannot persist subagent tool results")
                        }
                    } else { toolInteractions.append(completed) }

                    // Pre-flight budget check: if the new interaction pushed the
                    // context over the threshold, compact FIRST — the result the
                    // model just paid for is the newest item and survives into
                    // the compacted context. Only when compaction is impossible
                    // AND the hard budget would be crossed is the interaction
                    // dropped and the run force-finished (the old behavior).
                    if let pt = lastPromptTokens {
                        let lastInteraction = toolInteractions[toolInteractions.count - 1]
                        let interactionTokens = Self.estimatedInteractionTokens(lastInteraction)
                        let projected = pt + interactionTokens
                        if projected >= compactionThreshold {
                            var compactedNow = false
                            if compactionsUsed < Self.maxCompactionsPerRun,
                               let compacted = await compactContext(
                                   messages: messagesForLLM,
                                   interactions: toolInteractions,
                                   keepTokens: compactionKeepTokens,
                                   openRouterService: openRouterService,
                                   imagesDirectory: imagesDirectory,
                                   documentsDirectory: documentsDirectory,
                                   modelOverride: effectiveModelOverride,
                                   providerOverride: effectiveProviderOverride,
                                   reasoningEffortOverride: effectiveReasoningOverride,
                                   textOnlyOverride: effectiveTextOnlyOverride,
                               execution: responsesExecution, lane: .subagent(resolvedSessionId)
),
                               compacted.estimatedTokens < turnTokenBudget {
                                messagesForLLM = compacted.messages
                                toolInteractions = compacted.interactions
                                priorToolInteractions = compacted.interactions
                                lastPromptTokens = compacted.estimatedTokens
                                compactionsUsed += 1
                                await registry.applyCompaction(
                                    sessionId: resolvedSessionId,
                                    messages: compacted.messages,
                                    toolInteractions: compacted.interactions
                                )
                                print("[SubagentRunner] Compacted context after tool batch (\(compactionsUsed)/\(Self.maxCompactionsPerRun)): ~\(projected) → ~\(compacted.estimatedTokens) tokens")
                                compactedNow = true
                            }
                            if !compactedNow && projected >= turnTokenBudget {
                                let dropped = toolInteractions.removeLast()
                                let droppedTools = dropped.assistantMessage.toolCalls.map { $0.function.name }.joined(separator: ", ")
                                print("[SubagentRunner] Dropped overflowing tool interaction (\(droppedTools)) — context (~\(pt) + ~\(interactionTokens)) exceeds turn budget (\(turnTokenBudget)) and compaction was unavailable")
                                break loop
                            }
                        }
                    }
                }
            } catch is CancellationError {
                runError = "Subagent cancelled"
                break loop
            } catch let e as SubagentStalenessError {
                runError = e.localizedDescription
                break loop
            } catch {
                runError = "Subagent error: \(error.localizedDescription)"
                break loop
            }
        }

        // If the loop exhausted maxTurns without a final text and no hard error,
        // force one more call to let the subagent summarize its work. Tools and
        // system prompt stay identical to preserve prompt cache; the stop instruction
        // goes in a tail system message.
        if runError == nil && finalText.isEmpty {
            do {
                try Task.checkCancellation()
                var forceInteractions = toolInteractions
                for attempt in 0...4 {
                    let forceResponse = try await openRouterService.generateResponse(
                        messages: messagesForLLM,
                        imagesDirectory: imagesDirectory,
                        documentsDirectory: documentsDirectory,
                        tools: filteredTools,
                        toolResultMessages: forceInteractions.isEmpty ? nil : forceInteractions,
                        calendarContext: nil,
                        emailContext: nil,
                        chunkSummaries: nil,
                        totalChunkCount: 0,
                        currentUserMessageId: syntheticUser.id,
                        turnStartDate: turnStartDate,
                        finalResponseInstruction: subagentType.systemPromptSuffix,
                        tailSystemMessage: """
                            [ROUND LIMIT SUMMARY REQUEST \(attempt + 1)/5] You have reached the maximum number of tool rounds for this run. \
                            Do NOT call any more tools. Provide your final answer NOW — summarize everything \
                            you accomplished, what files were touched, and what remains to be done.
                            """,
                        modelOverride: effectiveModelOverride,
                        providerOverride: effectiveProviderOverride,
                        reasoningEffortOverride: effectiveReasoningOverride,
                        textOnlyOverride: effectiveTextOnlyOverride,
                        execution: responsesExecution, lane: .subagent(resolvedSessionId)
                    )
                    markProgress()

                    switch forceResponse {
                    case .text(let content, _, _, let promptTk, _, let spend, let native):
                        if let spend { totalSpendUSD += spend }
                        if let pt = promptTk { lastPromptTokens = pt }
                        finalText = content
                        finalReplay = native?.envelope
                        break
                    case .toolCalls(let assistantMessage, let calls, let promptTk, _, let spend):
                        // Tools remain available for prompt-cache stability, so a model
                        // can still request them here. Never execute tools from a
                        // force-finish response; feed back no-op tool results and retry.
                        if let spend { totalSpendUSD += spend }
                        if let pt = promptTk { lastPromptTokens = pt }
                        forceInteractions.append(disabledToolInteraction(
                            assistantMessage: assistantMessage,
                            calls: calls,
                            reason: "Tool calls are disabled during the subagent force-finish summary. Return the final summary as plain text only."
                        ))
                        if attempt == 4 {
                            runError = "Subagent exhausted maxTurns (\(maxTurns)) without returning a final text message"
                        }
                    }
                    if !finalText.isEmpty || runError != nil { break }
                }
            } catch {
                runError = "Subagent exhausted maxTurns (\(maxTurns)) and failed to produce final summary: \(error.localizedDescription)"
            }
        }

        // 8. Diff FilesLedger for files touched during the run.
        let postSnapshot = await FilesLedgerDiff.snapshot()
        let filesTouched = FilesLedgerDiff.diff(pre: preSnapshot, post: postSnapshot).allTouched

        // 9. Cap the final message at 32 KB (runaway-protection backstop).
        let cappedFinal = Self.capToBytes(finalText, limit: Self.finalMessageByteCap)

        // 10. Commit run state to the session registry so the session is resumable.
        let newInteractions = Array(toolInteractions.dropFirst(priorToolInteractions.count))
        var canCommit = true
        if responsesExecution != nil {
            canCommit = await registry.checkpointResponses(sessionId: resolvedSessionId, interactions: toolInteractions)
            if !canCommit { runError = "Cannot persist completed Responses subagent state; prior recovery checkpoint retained." }
        }
        let sessionPersisted: Bool
        if canCommit { sessionPersisted = await registry.commitRun(
            sessionId: resolvedSessionId,
            additionalTurns: turnsUsed,
            additionalSpend: totalSpendUSD,
            newToolsCalled: toolsCalledOrdered,
            newToolInteractions: responsesExecution == nil ? newInteractions : [],
            finalAssistantText: finalText.isEmpty ? nil : finalText,
            responsesReplay: finalReplay, responsesMode: responsesExecution != nil
        ) } else { sessionPersisted = false }

        // Report the CONCRETE model for inherit-routed runs, not just the
        // route name — this is where an unconfigured frontmatter lane that
        // degraded to inherit becomes visible to the parent.
        let modelUsedLabel: String
        if let effectiveModelOverride {
            modelUsedLabel = effectiveModelOverride
        } else {
            let concrete: String
            if let responsesExecution { concrete = responsesExecution.model }
            else { concrete = await openRouterService.activeModelId }
            modelUsedLabel = concrete.isEmpty ? "inherit" : "\(concrete) (inherited)"
        }

        return RunResult(
            sessionId: resolvedSessionId,
            isNewSession: isNew,
            finalMessage: cappedFinal,
            turnsUsed: turnsUsed,
            toolsCalled: toolsCalledOrdered,
            filesTouched: filesTouched,
            spendUSD: totalSpendUSD,
            error: runError,
            sessionPersisted: sessionPersisted,
            modelUsed: modelUsedLabel
        )
    }

    // MARK: - Context Compaction

    /// Mid-run compaction threshold as a percentage of the turn token budget.
    /// Firing before the hard wall leaves room for the run to keep working
    /// after the summary replaces the evicted history.
    private static let compactionThresholdPercent = 85

    /// Upper bound on the verbatim tail kept through a compaction. Also capped
    /// at a quarter of the turn budget so small custom budgets still compact.
    private static let compactionKeepTokensCap = 50_000

    /// Thrash guard: after this many compactions in a single run, fall back to
    /// force-finish instead of compacting again.
    private static let maxCompactionsPerRun = 3

    /// Result of a successful compaction: the summary is already inserted as
    /// the first message and the evicted items are gone.
    private struct CompactionOutcome {
        let messages: [Message]
        let interactions: [ToolInteraction]
        let estimatedTokens: Int
    }

    /// Compact a working context: evict the oldest tool interactions (then the
    /// oldest messages) until the kept tail fits under `keepTokens`, summarize
    /// the evicted content, and prepend the summary as the first message.
    /// A previous compaction summary sitting at the front gets evicted into the
    /// new summarizer input, so summaries are anchored rather than lost.
    /// Returns nil when nothing could be evicted or summarization failed — the
    /// caller then falls back to force-finish, never worse than the old behavior.
    private func compactContext(
        messages: [Message],
        interactions: [ToolInteraction],
        keepTokens: Int,
        openRouterService: OpenRouterService,
        imagesDirectory: URL,
        documentsDirectory: URL,
        modelOverride: String?,
        providerOverride: [String]?,
        reasoningEffortOverride: String?,
        textOnlyOverride: Bool?,
        execution: ProviderExecutionContext? = nil,
        lane: AffinityLane
    ) async -> CompactionOutcome? {
        var keptMessages = messages
        var keptInteractions = interactions
        var evictedMessages: [Message] = []
        var evictedInteractions: [ToolInteraction] = []

        let minKeepInteractions = 3
        let minKeepMessages = 2

        // Evict tool interactions from the front first (the biggest), then
        // older messages, until the kept tail fits.
        while Self.estimatedContextTokens(messages: keptMessages, interactions: keptInteractions) > keepTokens,
              keptInteractions.count > minKeepInteractions {
            evictedInteractions.append(keptInteractions.removeFirst())
        }
        while Self.estimatedContextTokens(messages: keptMessages, interactions: keptInteractions) > keepTokens,
              keptMessages.count > minKeepMessages {
            evictedMessages.append(keptMessages.removeFirst())
        }

        guard !evictedMessages.isEmpty || !evictedInteractions.isEmpty else { return nil }

        guard let summary = await summarizeEvicted(
            messages: evictedMessages,
            interactions: evictedInteractions,
            openRouterService: openRouterService,
            imagesDirectory: imagesDirectory,
            documentsDirectory: documentsDirectory,
            modelOverride: modelOverride,
            providerOverride: providerOverride,
            reasoningEffortOverride: reasoningEffortOverride,
            textOnlyOverride: textOnlyOverride,
            execution: execution, lane: lane
        ) else { return nil }

        let summaryMsg = Message(role: .user, content: summary, timestamp: Date(timeIntervalSince1970: 0))
        keptMessages.insert(summaryMsg, at: 0)
        return CompactionOutcome(
            messages: keptMessages,
            interactions: keptInteractions,
            estimatedTokens: Self.estimatedContextTokens(messages: keptMessages, interactions: keptInteractions)
        )
    }

    /// Rough token estimate (~4 chars/token) for a message + interaction set.
    /// Used for compaction decisions and the post-compaction counter reset;
    /// the next real API response replaces it with the exact prompt count.
    private static func estimatedContextTokens(messages: [Message], interactions: [ToolInteraction]) -> Int {
        var chars = 0
        for msg in messages { chars += msg.content.count }
        var tokens = chars / 4
        for interaction in interactions {
            tokens += estimatedInteractionTokens(interaction)
        }
        return tokens
    }

    /// Summarize content evicted from a subagent context (mid-run compaction
    /// or eager compaction of an oversized session at resume).
    /// Returns a structured summary string, or nil if summarization fails.
    private func summarizeEvicted(
        messages: [Message],
        interactions: [ToolInteraction],
        openRouterService: OpenRouterService,
        imagesDirectory: URL,
        documentsDirectory: URL,
        modelOverride: String?,
        providerOverride: [String]?,
        reasoningEffortOverride: String?,
        textOnlyOverride: Bool?,
        execution: ProviderExecutionContext? = nil,
        lane: AffinityLane
    ) async -> String? {
        // Build a text representation of the evicted content.
        var transcript = ""

        for msg in messages {
            let role = msg.role == .user ? "USER" : "ASSISTANT"
            transcript += "[\(role)] \(msg.content)\n\n"
        }

        for interaction in interactions {
            if let reasoning = interaction.assistantMessage.reasoning {
                transcript += "[THINKING] \(reasoning)\n"
            }
            for tc in interaction.assistantMessage.toolCalls {
                transcript += "[TOOL CALL] \(tc.function.name)(\(tc.function.arguments))\n"
            }
            for result in interaction.results {
                transcript += "[TOOL RESULT] \(result.content)\n"
            }
            transcript += "\n"
        }

        guard !transcript.isEmpty else { return nil }

        let summaryPrompt = """
        You are summarizing the earlier portion of a coding agent's work session that is being \
        evicted from context to free up space. The agent will continue working with only this \
        summary as reference for what happened before.

        Produce a detailed, structured summary that preserves:
        1. WHAT was accomplished — every significant action, decision, and outcome
        2. FILES touched — exact file paths and what was done to each (created, edited, read, deleted)
        3. KEY findings — errors encountered, solutions applied, important values/configs discovered
        4. CURRENT STATE — where the work left off, what was in progress, any pending items
        5. CONTEXT — any user requirements, constraints, or preferences that were established

        Be thorough — information not in this summary is permanently lost. Use exact file paths, \
        function names, and error messages. Do not generalize when specifics are available.

        Format the summary as a clear, scannable document with headers and bullet points.

        === TRANSCRIPT TO SUMMARIZE ===
        \(MarkerNeutralizer.escape(transcript))
        """

        let summaryMessages = [Message(role: .user, content: summaryPrompt, timestamp: Date())]

        do {
            var refusalInteractions: [ToolInteraction] = []
            for attempt in 0...4 {
                let response = try await openRouterService.generateResponse(
                    messages: summaryMessages,
                    imagesDirectory: imagesDirectory,
                    documentsDirectory: documentsDirectory,
                    tools: [],
                    toolResultMessages: refusalInteractions.isEmpty ? nil : refusalInteractions,
                    tailSystemMessage: attempt == 0 ? nil : """
                    [SUMMARY RETRY \(attempt)/4]
                    The previous response attempted to call tools. Tool use is disabled for this summarization pass.
                    Return the session history summary as plain text only.
                    """,
                    modelOverride: modelOverride,
                    providerOverride: providerOverride,
                    reasoningEffortOverride: reasoningEffortOverride,
                    textOnlyOverride: textOnlyOverride,
                    execution: execution, lane: lane
                )

                switch response {
                case .text(let content, _, _, _, _, _, _):
                    return "[SESSION HISTORY SUMMARY — Earlier work in this session was summarized to free context space. Details below are from the evicted portion.]\n\n\(content)"
                case .toolCalls(let assistantMessage, let calls, _, _, _):
                    refusalInteractions.append(disabledToolInteraction(
                        assistantMessage: assistantMessage,
                        calls: calls,
                        reason: "Tool calls are disabled during context compaction. Return the summary as plain text only."
                    ))
                }
            }
            return nil
        } catch {
            print("[SubagentRunner] Failed to summarize evicted context: \(error.localizedDescription)")
            return nil
        }
    }

    private func disabledToolInteraction(
        assistantMessage: AssistantToolCallMessage,
        calls: [ToolCall],
        reason: String
    ) -> ToolInteraction {
        let escaped = reason
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let results = calls.map { call in
            ToolResultMessage(
                toolCallId: call.id,
                content: "{\"error\":\"\(escaped)\"}"
            )
        }
        return ToolInteraction(assistantMessage: assistantMessage, results: results)
    }

    // MARK: - Turn Token Budget

    private static func turnTokenBudget() -> Int {
        if let raw = KeychainHelper.load(key: KeychainHelper.subagentTurnTokenBudgetKey),
           let parsed = Int(raw), parsed > 0 {
            return parsed
        }
        return KeychainHelper.defaultSubagentTurnTokenBudget
    }

    // MARK: - Progress Watchdog

    private func markProgress() {
        lastProgressDate = Date()
    }

    private func checkStaleness() throws {
        let elapsed = Date().timeIntervalSince(lastProgressDate)
        if elapsed > Self.stalenessTimeout {
            throw SubagentStalenessError(staleDuration: elapsed)
        }
    }

    /// Races a tool execution batch against the staleness timeout.
    /// Uses unstructured tasks so timeout can return even when tool execution is
    /// blocked in non-cooperative I/O and would prevent a task group from exiting.
    private func executeWithTimeout(
        _ calls: [ToolCall],
        using executor: ToolExecutor
    ) async throws -> [ToolResultMessage] {
        let raceSlot = ToolExecutionTimeoutRaceSlot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    Task {
                        await executor.cancelAllRunningProcesses()
                    }
                    return
                }

                let race = ToolExecutionTimeoutRace(continuation: continuation)
                raceSlot.set(race)

                let executionTask = Task {
                    do {
                        let results = try await executor.executeParallel(calls)
                        race.resolve(.success(results))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                race.setExecutionTask(executionTask)

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(Self.stalenessTimeout * 1_000_000_000))
                    } catch {
                        return
                    }
                    race.cancelExecution()
                    Task {
                        await executor.cancelAllRunningProcesses()
                    }
                    race.resolve(.failure(SubagentStalenessError(staleDuration: Self.stalenessTimeout)))
                }
                race.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            raceSlot.cancelExecution()
            raceSlot.resolve(.failure(CancellationError()))
            Task {
                await executor.cancelAllRunningProcesses()
            }
        }
    }

    // MARK: - Helpers

    /// Rough token estimate for a single tool interaction (~4 chars/token).
    /// Used by the pre-flight budget check to decide if the interaction fits.
    private static func estimatedInteractionTokens(_ interaction: ToolInteraction) -> Int {
        var tokens = (interaction.assistantMessage.content?.count ?? 0) / 4
        for call in interaction.assistantMessage.toolCalls {
            tokens += call.function.arguments.count / 4
            tokens += call.function.name.count / 4 + 20
        }
        for result in interaction.results {
            tokens += result.content.count / 4 + 20
        }
        return max(tokens, 1)
    }

    private static func capToBytes(_ s: String, limit: Int) -> String {
        let data = Data(s.utf8)
        if data.count <= limit { return s }
        let marker = "\n[...truncated]"
        let markerBytes = Data(marker.utf8).count
        let head = max(0, limit - markerBytes)
        let prefix = data.prefix(head)
        // Truncate to a valid UTF-8 boundary by trimming trailing bytes until decode succeeds.
        var truncated = Data(prefix)
        while !truncated.isEmpty {
            if let str = String(data: truncated, encoding: .utf8) {
                return str + marker
            }
            truncated.removeLast()
        }
        return marker
    }

}

// MARK: - Staleness Error

struct SubagentStalenessError: Error, LocalizedError {
    let staleDuration: TimeInterval
    var errorDescription: String? {
        "Subagent killed: no progress for \(Int(staleDuration / 60)) minutes (stuck operation)"
    }
}

private final class ToolExecutionTimeoutRace {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[ToolResultMessage], Error>?
    private var executionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resolved = false

    init(continuation: CheckedContinuation<[ToolResultMessage], Error>) {
        self.continuation = continuation
    }

    func setExecutionTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = resolved
        if !resolved {
            executionTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = resolved
        if !resolved {
            timeoutTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func cancelExecution() {
        lock.lock()
        let task = executionTask
        lock.unlock()
        task?.cancel()
    }

    func resolve(_ result: Result<[ToolResultMessage], Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let continuation = continuation
        self.continuation = nil
        let timeoutTask = timeoutTask
        let executionTask = executionTask
        lock.unlock()

        timeoutTask?.cancel()
        if case .failure(let error) = result, error is SubagentStalenessError {
            executionTask?.cancel()
        }

        switch result {
        case .success(let results):
            continuation?.resume(returning: results)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private final class ToolExecutionTimeoutRaceSlot {
    private let lock = NSLock()
    private var race: ToolExecutionTimeoutRace?
    private var cancellationRequested = false

    func set(_ race: ToolExecutionTimeoutRace) {
        lock.lock()
        let shouldCancel = cancellationRequested
        if !shouldCancel {
            self.race = race
        }
        lock.unlock()

        if shouldCancel {
            race.cancelExecution()
            race.resolve(.failure(CancellationError()))
        }
    }

    func cancelExecution() {
        lock.lock()
        cancellationRequested = true
        let race = race
        lock.unlock()
        race?.cancelExecution()
    }

    func resolve(_ result: Result<[ToolResultMessage], Error>) {
        lock.lock()
        let race = race
        lock.unlock()
        race?.resolve(result)
    }
}
