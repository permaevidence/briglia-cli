import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
import OpenCombineDispatch
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
extension ConversationManager {
    
    // MARK: - Tool-Aware Response Generation
    
    func generateResponseWithTools(
        currentUserMessageId: UUID,
        turnStartDate: Date,
        salvageRunId: UUID? = nil
    ) async throws -> ToolAwareResponse {
        try Task.checkCancellation()
        // BGPRUNE{ A-T0
        if backgroundPruneEngaged {
            await backgroundPruneTurnStart(runId: salvageRunId)
        }
        // }BGPRUNE
        // Cache diagnosis (plan v2 §1.4, off unless enabled): the intended
        // prefix transitions of this turn are recorded for the main lane.
        CacheDiagnostics.noteTransition("turn-start", lane: .main)
        // Background archiving (§3): a finished archive's new summary and
        // the removal of its messages land here, at a turn boundary, before
        // anything of this turn's context is built. Never mid-turn.
        let messageCountBeforeArchiveCommit = messages.count
        await commitArchiveIfReady()
        if messages.count != messageCountBeforeArchiveCommit { CacheDiagnostics.noteTransition("archive-commit", lane: .main) }
        let snapshot = await openRouterService.executionContext(modelOverride: nil, providerOverride: nil,
            reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main)
        let responsesExecution: ProviderExecutionContext? = snapshot.wireProtocol == .responses ? snapshot : nil
        defer { responsesExecution?.responsesTurn.close() }
        if responsesExecution != nil && !saveConversation() {
            throw ResponsesFailure.failed("cannot persist canonical history before Responses dispatch")
        }
        defer {
            // File descriptions are now created at prune time from persisted
            // message/tool attachment state, not from this transient byte queue.
            _ = ToolExecutor.getPendingFilesForDescription()
        }

        // Snapshot FilesLedger up-front so we can report the set of files that were
        // edited/generated during the turn on the resulting assistant Message. This
        // is surfaced in the UI (MessageBubbleView) and in archived summaries.
        let ledgerPreSnapshot = await FilesLedgerDiff.snapshot()

        // Local helper: compute the diff now. Closure-captured so every return path
        // below produces the same `editedFilePaths` / `generatedFilePaths` pair.
        // NB: any ledger writes that happen AFTER this call (none are expected —
        // all tool writes are recorded synchronously via FilesLedger.shared.record)
        // will bleed into the next turn's snapshot rather than this one.
        @Sendable func computeLedgerDiff() async -> FilesLedgerDiff.Changed {
            let post = await FilesLedgerDiff.snapshot()
            return FilesLedgerDiff.diff(pre: ledgerPreSnapshot, post: post)
        }

        // Check if tools are available
        let serperKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""

        // Fetch all context data in PARALLEL for performance.
        // Calendar + email use the frozen session-level cache: populated on first turn,
        // refreshed only on prune events and local-day rollover. The helper returns
        // instantly on cache hits, so awaiting it in parallel with the others is free.
        let contextStartTime = Date()
        async let frozenContextTask = getFrozenSystemContext()
        // Background archiving (§4): the turn's archive view — the running
        // job's frozen view, or a fresh one captured once (rows whose
        // sources are still live left out). Items and count are today's
        // whenever nothing overlaps.
        async let archiveViewTask = adoptTurnArchiveView()
        async let contextResultTask = openRouterService.processContextWindow(messages)

        // Await all parallel operations.
        // calendarContext / emailContext remain `var` because prune events below
        // force a cache refresh and we want the new values to flow to the LLM call.
        let frozenContext = await frozenContextTask
        var calendarContext = frozenContext.calendar
        var emailContext = frozenContext.email
        let turnArchiveView = await archiveViewTask
        var chunkSummaries = turnArchiveView.items
        let totalChunkCount = turnArchiveView.totalChunkCount
        let contextResult = await contextResultTask
        try Task.checkCancellation()
        print("[TIMING] Context fetch took: \(String(format: "%.2f", Date().timeIntervalSince(contextStartTime)))s")

        // Re-attempt delivery of any maintenance alert whose original send failed.
        Task.detached { await MaintenanceAlertCenter.shared.flushUndelivered() }

        // Archive messages if threshold exceeded (based on conversation text weight only).
        //
        // The archive attempt runs on a DETACHED task so it's immune to /stop — the
        // user can abort the turn's LLM + tool work without losing the expensive
        // summary generation. It is BOUNDED, not infinite: durability never depends
        // on blocking here. On failure the raw messages simply STAY in the live
        // conversation (which is persisted), the turn proceeds with full visibility
        // of the un-archived content, and the next turn after the cooldown retries.
        // MaintenanceAlertCenter tells the user when this enters/leaves a degraded
        // state, so persistent failures surface instead of spinning silently.
        var archiveGateRefusal: String? = nil
        if contextResult.needsArchiving && !contextResult.messagesToArchive.isEmpty {
            do { try settleJobEvidenceBeforeRemoval(of: contextResult.messagesToArchive) }
            catch { archiveGateRefusal = error.localizedDescription }
        }
        if let archiveGateRefusal {
            print("[ConversationManager] Archive postponed — crash-record evidence not settled: \(archiveGateRefusal)")
        } else if contextResult.needsArchiving && !contextResult.messagesToArchive.isEmpty {
            if Date() < archiveRetryBackoffUntil {
                print("[ConversationManager] Archive needed but in failure cooldown until \(archiveRetryBackoffUntil) — keeping raw messages in context")
            } else if let refusal = archiveStartRefusal(view: turnArchiveView) {
                // One archive at a time (§3): a running or uncommitted job,
                // startup recovery, rows still awaiting their commit, or a
                // pending /restart or /upgrade. The raw messages stay.
                print("[ConversationManager] Archive needed but not started: \(refusal)")
            } else if !archiveInlineEnabled {
                // Background mode (owner default): the same job body, not
                // awaited. The conversation is sent unchanged; the new
                // summary and the removal land at the start of a later turn.
                await startBackgroundArchiveJob(
                    batch: contextResult.messagesToArchive,
                    summarizationContext: buildSummarizationContext(
                        chunkSummaries: chunkSummaries,
                        currentMessages: contextResult.messagesToSend
                    ),
                    snapshotSource: messages,
                    view: turnArchiveView
                )
            } else {
                let archiveStartTime = Date()
                let messagesToArchive = contextResult.messagesToArchive
                let summarizationContext = buildSummarizationContext(
                    chunkSummaries: chunkSummaries,
                    currentMessages: contextResult.messagesToSend
                )
                let archiveSvc = archiveService
                let snapshotSource = messages

                try? await sendText("🧠 Summarizing and archiving the oldest part of the conversation…")

                let summarizingActivityId = beginMaintenance(.summarizingHistory)
                defer { endMaintenance(summarizingActivityId) }

                let archiveTask = Task.detached { () async -> (Bool, PruneArchiveReference?) in
                    await Self.runArchiveJobBody(messagesToArchive: messagesToArchive, summarizationContext: summarizationContext,
                                                 snapshotSource: snapshotSource, archiveSvc: archiveSvc, notifyStatus: true)
                }
                // Wait for the archive task. For Task<Bool, Never>, the await doesn't
                // throw on parent cancellation — it just waits until the detached work
                // completes. /stop can't sabotage the archive mid-flight.
                // /stop visibility: this run is waiting for the archive
                // (phase record + diagnostics-only stage marker, closed on
                // the single path out of the await).
                if let salvageRunId { runPhases[salvageRunId] = .archiveWait(Date()) }
                let archiveWaitMarker = StageMarkers.enter("archive.wait", call: nil)
                let (archived, archiveReceipt) = await archiveTask.value
                StageMarkers.exit(archiveWaitMarker, archived ? .ok : .error)
                if let salvageRunId { runPhases[salvageRunId] = .model(Date()) }
                defer { PruneArchiveStore.release(archiveReceipt) }

                if archived {
                    await MaintenanceAlertCenter.shared.reportSuccess(.conversationSummary)

                    // Now back on the main actor — remove archived messages from the
                    // in-memory conversation. This is the ONLY place we mutate `messages`
                    // after archiving, and we're guaranteed the archive finished.
                    let archivedIDs = Set(messagesToArchive.map(\.id))
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let stillLive = messages.filter { archivedIDs.contains($0.id) }
                    guard try encoder.encode(stillLive) == encoder.encode(messagesToArchive) else {
                        throw PruneArchiveStore.Failure("Archived batch changed before removal; live messages retained")
                    }
                    let candidate = messages.filter { !archivedIDs.contains($0.id) }
                    try writeHistoryFile(try encoder.encode(candidate))
                    messages = candidate
                    committedMessages = candidate
                    CacheDiagnostics.noteTransition("archive-commit", lane: .main)
                    lastPromptTokens = nil
                    lastCompletionTokens = nil
                    cleanupOrphanedToolAttachmentSnapshots()
                    do { try PruneArchiveStore.retainLatest() }
                    catch { showMaintenanceNotice("Snapshot retention: \(error.localizedDescription)") }
                    // Refresh the prompt-facing summaries so THIS turn sees the new
                    // chunk summary (and any consolidation/meta-summary changes)
                    // instead of prompting with the pre-archive snapshot. The
                    // count stays the one captured at turn start, exactly as
                    // before (inline equivalence).
                    chunkSummaries = await refreshTurnArchiveViewAfterInlineArchive().items
                } else {
                    // Keep the raw messages in the live conversation — the agent
                    // retains full visibility of the un-archived content. Skip
                    // further attempts for a while so a broken API doesn't tax
                    // every turn with failed calls.
                    archiveRetryBackoffUntil = Date().addingTimeInterval(600)
                    print("[ConversationManager] Archive gave up — raw messages stay in context; next attempt after \(archiveRetryBackoffUntil)")
                }
                print("[TIMING] Archive took: \(String(format: "%.2f", Date().timeIntervalSince(archiveStartTime)))s")
            }
        }

        // Persona snapshot (one per turn): captured after the complete archive
        // branch, so an inline archive's profile write is visible this turn,
        // and before the initial prune. Every main-lane send and estimate of
        // this run uses it — the prune summary, the tool loop, mid-loop
        // pruning, active-turn compaction and the forced final — so a profile
        // written mid-turn by background archive work changes neither the
        // system prompt nor the active-turn scope until the next turn.
        // Memory-only; a restarted turn captures a fresh one.
        let turnPersona = PromptPersona.live()

        // Build the same tool schema that the next agent request would use so
        // the prune-summary request can reuse the intact pre-prune prompt prefix.
        await MCPAgentRouting.refreshFromRegistry()
        let initialMcpTools = await MCPRegistry.shared.allToolDefinitions()
        let initialMainMcpTools = MCPAgentRouting.filterMcpTools(
            forAgent: "main",
            allTools: initialMcpTools,
            fallbackPatterns: nil
        )
        let initialDeferredServerNames = MCPAgentRouting.deferredServers(
            forAgent: "main",
            allTools: initialMcpTools,
            fallbackPatterns: nil
        )
        let initialDeferredSummaries = await MCPRegistry.shared.serverSummaries(for: initialDeferredServerNames)
        let initialNativeTools = AvailableTools.all(
            includeWebSearch: !serperKey.isEmpty,
            hasDeferredMCPs: !initialDeferredSummaries.isEmpty
        )
        let initialToolsForRound = initialNativeTools + initialMainMcpTools
        let prePruneSystemPromptDate = currentSystemPromptTimestamp()

        // Prune stored tool interactions if full context exceeds budget
        // BGPRUNE{ A-T1/open
        if backgroundPruneEngaged {
            var bgPruneDidPrune = backgroundPruneT0AppliedRun != nil && backgroundPruneT0AppliedRun == salvageRunId
            backgroundPruneT0AppliedRun = nil
            let bgPruneInputs = BackgroundPruneSummaryInputs(
                currentTurnInteractions: nil, tools: initialToolsForRound, calendarContext: calendarContext,
                emailContext: emailContext, chunkSummaries: chunkSummaries, totalChunkCount: totalChunkCount,
                currentUserMessageId: currentUserMessageId, turnStartDate: prePruneSystemPromptDate,
                deferredMCPSummaries: initialDeferredSummaries, persona: turnPersona)
            if try await backgroundPrunePreRequest(runId: salvageRunId, inputs: bgPruneInputs, execution: responsesExecution, inline: {
                try await self.pruneToolInteractionsIfNeeded(
                    currentUserMessageId: currentUserMessageId,
                    calendarContext: calendarContext,
                    emailContext: emailContext,
                    chunkSummaries: chunkSummaries,
                    totalChunkCount: totalChunkCount,
                    turnStartDate: prePruneSystemPromptDate,
                    tools: initialToolsForRound,
                    deferredMCPSummaries: initialDeferredSummaries, execution: responsesExecution,
                    persona: turnPersona
                )
            }) {
                bgPruneDidPrune = true
            }
            if bgPruneDidPrune {
                CacheDiagnostics.noteTransition("prune", lane: .main)
                refreshSystemPromptTimestamp()
                let refreshed = await getFrozenSystemContext(forceRefresh: true)
                calendarContext = refreshed.calendar
                emailContext = refreshed.email
            }
        } else {
        // }BGPRUNE
        let didPrune = try await pruneToolInteractionsIfNeeded(
            currentUserMessageId: currentUserMessageId,
            calendarContext: calendarContext,
            emailContext: emailContext,
            chunkSummaries: chunkSummaries,
            totalChunkCount: totalChunkCount,
            turnStartDate: prePruneSystemPromptDate,
            tools: initialToolsForRound,
            deferredMCPSummaries: initialDeferredSummaries, execution: responsesExecution,
            persona: turnPersona
        )
        if didPrune {
            CacheDiagnostics.noteTransition("prune", lane: .main)
            refreshSystemPromptTimestamp()
            // Cache is already invalidated by the prune — take the opportunity to
            // refresh stale calendar/email context with current data for free.
            let refreshed = await getFrozenSystemContext(forceRefresh: true)
            calendarContext = refreshed.calendar
            emailContext = refreshed.email
        }
        // BGPRUNE{ A-T1/close
        }
        // }BGPRUNE

        // Use the frozen system prompt timestamp (only refreshes on prune events or day change)
        let systemPromptDate = currentSystemPromptTimestamp()

        // Capture messages after archival + pruning for the agentic loop (var for mid-loop pruning)
        var messagesForLLM = messages

        // Tool interaction loop with per-turn, daily, and monthly spend caps (USD).
        let toolSpendLimitPerTurnUSD = configuredToolSpendLimitPerTurnUSD()
        let spendLimitStatus = currentSpendLimitStatus(referenceDate: Date())
        let toolSpendLimitDailyUSD = spendLimitStatus.effectiveDailyLimitUSD
        let toolSpendLimitMonthlyUSD = spendLimitStatus.effectiveMonthlyLimitUSD
        var cumulativeToolSpendUSD: Double = 0
        var localToolInteractions: [ToolInteraction] = []
        // Fresh bash-wait window and repeat-timeout guards for this run
        // (BASH_V2_PLAN §9.2/§9.4 — the ledger is turn-scoped).
        await toolExecutor.resetBashWaitLedger()
        if let salvageRunId {
            if recoveryBlocked { recoverInterruptedTurnSalvageIfNeeded() }
            guard !recoveryBlocked else { throw PruneArchiveStore.Failure("Unresolved turn recovery file; free storage or repair it before starting more work") }
            activeTurnCheckpoints[salvageRunId] = TurnCheckpoint(runID: salvageRunId, taskMessageID: currentUserMessageId ?? UUID())
            checkpointWriteFailure = nil
            clearTurnSalvageFile()
        }
        // Local alias. User-triggered active runs mirror mutations into the
        // run-scoped salvage buffer (and its on-disk crash-proof copy);
        // ambient/background turns stay local.
        var toolInteractions: [ToolInteraction] {
            get {
                if let salvageRunId {
                    return activeTurnCheckpoints[salvageRunId]?.retainedInteractions ?? []
                }
                return localToolInteractions
            }
            set {
                if let salvageRunId {
                    activeTurnCheckpoints[salvageRunId]?.retainedInteractions = newValue
                    if responsesExecution == nil || activeTurnCheckpoints[salvageRunId]?.isEnvelope == true {
                        persistTurnSalvage(newValue, runId: salvageRunId)
                    }
                } else {
                    localToolInteractions = newValue
                }
            }
        }
        var didHitToolSpendLimit = false
        var didHitContextLimit = false
        var todaySpentUSD = spendLimitStatus.todaySpentUSD
        var monthSpentUSD = spendLimitStatus.monthSpentUSD

        if let exceededMessage = spendLimitExceededMessage(
            todaySpentUSD: todaySpentUSD,
            monthSpentUSD: monthSpentUSD,
            dailyLimitUSD: toolSpendLimitDailyUSD,
            monthlyLimitUSD: toolSpendLimitMonthlyUSD
        ) ?? (spendLimitStatus.unverifiable ? SpendGate.unverifiableMessage(spendLimitStatus.accounting) : nil) {
            print("[ConversationManager] Daily/monthly spend limit already reached before tool loop: \(exceededMessage)")
            let changed = await computeLedgerDiff()
            return ToolAwareResponse(
                finalText: exceededMessage,
                finalReasoning: nil,
                finalReasoningDetails: nil,
                compactToolLog: nil,
                toolInteractions: [],
                accessedProjects: [],
                measuredToolTokens: nil,
                measuredUserTokens: nil,
                measuredAssistantTokens: nil,
                measuredAssistantCompletionTokens: nil,
                editedFilePaths: changed.edited,
                generatedFilePaths: changed.generated,
                subagentSessionEvents: []
            )
        }

        var sessionEvents: [SubagentSessionEvent] = []

        // Capture the tools/deferred summaries from the last loop iteration so the
        // force-finish call can use the identical parameters — preserving prompt cache.
        var lastToolsForRound: [ToolDefinition] = []
        var lastDeferredSummaries: [(name: String, description: String, toolCount: Int)] = []

        // Track prompt_tokens across rounds to compute per-interaction deltas
        var previousPromptScope: String?
        var expectedPromptEstimate: Int?
        var prevRoundPromptTokens: Int? = lastPromptTokens
        let turnStartPromptTokens = lastPromptTokens
        let turnStartCompletionTokens = lastCompletionTokens
        var measuredUserTokens: Int?
        var finalCompletionTokens: Int?
        // §4.4 (/keepsummaries): every baseline carries the composition key
        // of the request that produced it; a response is attributed only
        // against a baseline with the same key as the request it answers.
        var prevRoundPromptKey = lastPromptRenderKey
        let turnStartPromptKey = lastPromptRenderKey
        var sentRenderKey = PruneSummaryRetention.emptyRenderKey
        var sentStubIDs: Set<UUID> = []
        // Closed once a mismatched first measurement was seen, so a later
        // round never becomes a "first user" delta.
        var userAttributionClosed = false
        func attributeUserTokens(_ tokens: Int) {
            guard measuredUserTokens == nil, !userAttributionClosed, let start = turnStartPromptTokens else { return }
            guard turnStartPromptKey == sentRenderKey, !sentStubIDs.contains(currentUserMessageId) else {
                userAttributionClosed = true; return
            }
            let totalDelta = tokens - start
            let prevAssistant = turnStartCompletionTokens ?? 0
            measuredUserTokens = max(totalDelta - prevAssistant, 0)
        }

        toolLoop: for round in 1...maxToolRoundsSafetyLimit {
            try Task.checkCancellation()
            // /keepsummaries: read once per round; this round's estimate and
            // send (and every resend inside it) compose with this value.
            let roundLimit = KeepSummariesSetting.current()
            print("[ConversationManager] Tool round \(round) (turn spend: $\(formatUSD(cumulativeToolSpendUSD)) / \(toolSpendLimitPerTurnUSD.map { "$" + formatUSD($0) } ?? "no cap"), today: $\(formatUSD(todaySpentUSD)), month: $\(formatUSD(monthSpentUSD)))")
            
            // Call LLM (with tools available for chaining)
            let llmStartTime = Date()
            // Sync MCPAgentRouting's cache so SubagentTypes.all() and the
            // per-agent filter below see up-to-date installed-server state.
            await MCPAgentRouting.refreshFromRegistry()

            let allMcpTools = await MCPRegistry.shared.allToolDefinitions()
            // Phase 2 default: main agent sees no MCP tools unless the user
            // opts them in via ~/.config/briglia/mcp-routing.json ("main": {...}).
            // "always" tools go in the tools array; "deferred" get a summary
            // in the system prompt for on-demand discovery.
            let mainMcpTools = MCPAgentRouting.filterMcpTools(
                forAgent: "main",
                allTools: allMcpTools,
                fallbackPatterns: nil
            )
            let deferredServerNames = MCPAgentRouting.deferredServers(
                forAgent: "main",
                allTools: allMcpTools,
                fallbackPatterns: nil
            )
            let deferredSummaries = await MCPRegistry.shared.serverSummaries(for: deferredServerNames)

            let nativeTools = AvailableTools.all(
                includeWebSearch: !serperKey.isEmpty,
                hasDeferredMCPs: !deferredSummaries.isEmpty
            )
            let toolsForRound = nativeTools + mainMcpTools
            lastToolsForRound = toolsForRound
            lastDeferredSummaries = deferredSummaries
            let allowedToolNames = Set(toolsForRound.map { $0.function.name })
            if CacheDiagnostics.active {
                // Tool exposure and the frozen system-prompt date are
                // intended prefix transitions when they change.
                // Order-insensitive: an exposure change is a different SET of
                // definitions; a mere reordering is not one (Class A catches it).
                let sortedEncoder = JSONEncoder(); sortedEncoder.outputFormatting = .sortedKeys
                let signature = toolsForRound.map { ((try? sortedEncoder.encode($0)).map(SHA256Hex.digest) ?? $0.function.name) }.sorted().joined(separator: ",")
                    + deferredSummaries.map { "\($0.name)|\($0.description)|\($0.toolCount)" }.joined(separator: "\n")
                if let previous = cacheDiagnosticsToolSignature, previous != signature {
                    CacheDiagnostics.noteTransition("tool-exposure", lane: .main)
                }
                cacheDiagnosticsToolSignature = signature
                if let previousDate = cacheDiagnosticsSystemDate, previousDate != systemPromptDate {
                    CacheDiagnostics.noteTransition("system-refresh", lane: .main)
                }
                cacheDiagnosticsSystemDate = systemPromptDate
            }
            if let failure = checkpointWriteFailure { throw PruneArchiveStore.Failure(failure) }
            // BGPRUNE{ A-D1
            if backgroundPruneEngaged {
                if backgroundPruneJob != nil {
                    _ = try await backgroundPruneAdmit(runId: salvageRunId, requestKey: "round\(round)", execution: responsesExecution,
                        admitted: {
                            try await self.backgroundPruneRequestEstimate(
                                projected: try self.backgroundPruneProjection(messagesForLLM, runId: salvageRunId, limit: roundLimit).messages, rounds: toolInteractions,
                                tools: toolsForRound, calendar: calendarContext, email: emailContext, summaries: chunkSummaries,
                                totalChunks: totalChunkCount, date: systemPromptDate, deferred: deferredSummaries, persona: turnPersona)
                        },
                        liveRounds: { toolInteractions },
                        afterApply: { bgPruneReplacements in
                            for bgPruneIndex in messagesForLLM.indices {
                                if let bgPruneNew = bgPruneReplacements[messagesForLLM[bgPruneIndex].id] { messagesForLLM[bgPruneIndex] = bgPruneNew }
                            }
                            prevRoundPromptTokens = nil; previousPromptScope = nil
                            CacheDiagnostics.noteTransition("prune", lane: .main)
                            let bgPruneRefreshed = await self.getFrozenSystemContext(forceRefresh: true)
                            calendarContext = bgPruneRefreshed.calendar
                            emailContext = bgPruneRefreshed.email
                        },
                        inline: {
                            prevRoundPromptTokens = nil; previousPromptScope = nil
                            return try await self.backgroundPruneMidLoopBlock(precomputed: nil, compact: true,
                                    messagesForLLM: &messagesForLLM, rounds: toolInteractions,
                                    calendarContext: &calendarContext, emailContext: &emailContext,
                                    chunkSummaries: chunkSummaries, totalChunkCount: totalChunkCount,
                                    currentUserMessageId: currentUserMessageId, systemPromptDate: systemPromptDate,
                                    tools: toolsForRound, deferredSummaries: deferredSummaries,
                                    execution: responsesExecution, persona: turnPersona, salvageRunId: salvageRunId,
                                    ledgerDiff: computeLedgerDiff,
                                    prevRoundPromptTokens: &prevRoundPromptTokens, previousPromptScope: &previousPromptScope,
                                    cumulativeToolSpendUSD: &cumulativeToolSpendUSD, todaySpentUSD: &todaySpentUSD, monthSpentUSD: &monthSpentUSD)
                        })
                }
            }
            // }BGPRUNE
            let projectedView = try requestView(messagesForLLM, runId: salvageRunId, limit: roundLimit)
            let projected = projectedView.messages
            let estimate = try await openRouterService.activeTurnRequestEstimate(messages: projected, rounds: toolInteractions,
                images: imagesDirectory, documents: documentsDirectory, tools: toolsForRound,
                calendar: calendarContext, email: emailContext, summaries: chunkSummaries,
                totalChunks: totalChunkCount, date: systemPromptDate, deferred: deferredSummaries,
                persona: turnPersona)
            let scope = estimate.scope + ":" + String(activeTurnCheckpoints[salvageRunId ?? UUID()]?.generation ?? 0)
                + ":" + String(messagesForLLM.count)
            if let previousPromptScope, previousPromptScope != scope {
                Self.promptScopeResetForTesting?()
                prevRoundPromptTokens = nil; lastPromptTokens = nil
            }
            previousPromptScope = scope
            expectedPromptEstimate = estimate.tokens
            if lastPromptTokens == nil, toolInteractions.isEmpty,
               estimate.fixedTextTokens > configuredMaxContextTokens() {
                throw PruneArchiveStore.Failure("The configured context budget cannot fit the remaining instructions and message text (estimated \(estimate.fixedTextTokens) tokens). Reduce fixed context or increase the configured budget; no tools ran.")
            }
            let response: LLMResponse
            // Highest wake generation already in history when this request
            // body is frozen (§3.1): becomes the transmitted value only once
            // the request succeeds.
            let requestGeneration = appendedMidTurnGeneration
            // BGPRUNE{ A-SEND/open
            if backgroundPruneEngaged {
                // §10: the same send (image recovery inside), wrapped in one
                // best-effort in-band reduction and resend.
                let bgPruneAdmittedMaximum = backgroundPruneMaximum()
                func bgPruneSend(_ bgPruneView: ComposedHistory) async throws -> LLMResponse {
                    var requestHistory = bgPruneView.messages
                    var requestComposition = bgPruneView
                    var requestRounds = toolInteractions
                    let recovered = try await ImageRejectionRecovery.run(
                        send: { log in
                            sentRenderKey = requestComposition.renderKey; sentStubIDs = requestComposition.stubIDs
                            return try await openRouterService.generateResponse(
                                messages: requestHistory,
                                imagesDirectory: imagesDirectory,
                                documentsDirectory: documentsDirectory,
                                tools: toolsForRound,  // Always pass tools so LLM can chain calls
                                toolResultMessages: requestRounds.isEmpty ? nil : requestRounds,
                                calendarContext: calendarContext,
                                emailContext: emailContext,
                                chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
                                totalChunkCount: totalChunkCount,
                                currentUserMessageId: currentUserMessageId,
                                turnStartDate: systemPromptDate,
                                deferredMCPSummaries: deferredSummaries.isEmpty ? nil : deferredSummaries,
                                execution: responsesExecution, lane: .main, imageLog: log,
                                persona: turnPersona
                            )
                        },
                        newestUnit: { transmitted in
                            ImageRejectionMarks.newestUnit(transmitted: transmitted, requestMessages: requestHistory, requestRounds: requestRounds)
                        },
                        commit: { scope in
                            var rounds = toolInteractions
                            let committed = try commitImageRejectionMarks(scope, runId: salvageRunId, responses: responsesExecution != nil,
                                                                          messagesForLLM: &messagesForLLM, rounds: &rounds)
                            toolInteractions = rounds
                            guard committed else { return false }
                            requestComposition = try requestView(messagesForLLM, runId: salvageRunId, limit: roundLimit)
                            requestHistory = requestComposition.messages
                            requestRounds = toolInteractions
                            return true
                        }
                    )
                    if !recovered.excluded.isEmpty {
                        try? await sendText(ImageRejectionRecovery.notice(recovered.excluded))
                    }
                    if responsesExecution != nil { clearResponsesMidTurnBatch(recovered.response) }
                    else { clearInFlightMidTurnBatchIfCarried(by: toolInteractions.isEmpty ? nil : toolInteractions) }
                    seenGenerationAtRequest = requestGeneration
                    return recovered.response
                }
                do {
                    response = try await backgroundPruneConverge(runId: salvageRunId, requestKey: "round\(round)",
                        admittedEstimate: estimate.tokens, admittedMaximum: bgPruneAdmittedMaximum, execution: responsesExecution,
                        send: { try await bgPruneSend(projectedView) },
                        admitted: {
                            try await self.backgroundPruneRequestEstimate(
                                projected: try self.backgroundPruneProjection(messagesForLLM, runId: salvageRunId, limit: roundLimit).messages, rounds: toolInteractions,
                                tools: toolsForRound, calendar: calendarContext, email: emailContext, summaries: chunkSummaries,
                                totalChunks: totalChunkCount, date: systemPromptDate, deferred: deferredSummaries, persona: turnPersona)
                        },
                        liveRounds: { toolInteractions },
                        afterApply: { bgPruneReplacements in
                            for bgPruneIndex in messagesForLLM.indices {
                                if let bgPruneNew = bgPruneReplacements[messagesForLLM[bgPruneIndex].id] { messagesForLLM[bgPruneIndex] = bgPruneNew }
                            }
                            prevRoundPromptTokens = nil; previousPromptScope = nil
                            CacheDiagnostics.noteTransition("prune", lane: .main)
                            let bgPruneRefreshed = await self.getFrozenSystemContext(forceRefresh: true)
                            calendarContext = bgPruneRefreshed.calendar
                            emailContext = bgPruneRefreshed.email
                        },
                        inline: {
                            prevRoundPromptTokens = nil; previousPromptScope = nil
                            return try await self.backgroundPruneMidLoopBlock(precomputed: nil, compact: false,
                                    messagesForLLM: &messagesForLLM, rounds: toolInteractions,
                                    calendarContext: &calendarContext, emailContext: &emailContext,
                                    chunkSummaries: chunkSummaries, totalChunkCount: totalChunkCount,
                                    currentUserMessageId: currentUserMessageId, systemPromptDate: systemPromptDate,
                                    tools: toolsForRound, deferredSummaries: deferredSummaries,
                                    execution: responsesExecution, persona: turnPersona, salvageRunId: salvageRunId,
                                    ledgerDiff: computeLedgerDiff,
                                    prevRoundPromptTokens: &prevRoundPromptTokens, previousPromptScope: &previousPromptScope,
                                    cumulativeToolSpendUSD: &cumulativeToolSpendUSD, todaySpentUSD: &todaySpentUSD, monthSpentUSD: &monthSpentUSD)
                        },
                        resend: {
                            prevRoundPromptTokens = nil; self.lastPromptTokens = nil; previousPromptScope = nil
                            let bgPruneProjected = try self.backgroundPruneProjection(messagesForLLM, runId: salvageRunId, limit: roundLimit)
                            expectedPromptEstimate = try await self.backgroundPruneRequestEstimate(
                                projected: bgPruneProjected.messages, rounds: toolInteractions,
                                tools: toolsForRound, calendar: calendarContext, email: emailContext, summaries: chunkSummaries,
                                totalChunks: totalChunkCount, date: systemPromptDate, deferred: deferredSummaries, persona: turnPersona)
                            return try await bgPruneSend(bgPruneProjected)
                        })
                } catch let renderError as HarnessAnnotationRenderError {
                    restoreInFlightMidTurnBatch(in: &toolInteractions)
                    throw renderError
                }
            } else {
            // }BGPRUNE
            do {
                // Image-rejection recovery (plan v2 §2.4): a recognised
                // invalid-image 400 marks the transmitted images of the
                // request's newest unit (then, once, all of them), persists
                // the marks and resends the request rebuilt from that state;
                // tools are not re-run. Any other outcome is exactly today's.
                var requestHistory = projected
                var requestComposition = projectedView
                var requestRounds = toolInteractions
                let recovered = try await ImageRejectionRecovery.run(
                    send: { log in
                        sentRenderKey = requestComposition.renderKey; sentStubIDs = requestComposition.stubIDs
                        return try await openRouterService.generateResponse(
                            messages: requestHistory,
                            imagesDirectory: imagesDirectory,
                            documentsDirectory: documentsDirectory,
                            tools: toolsForRound,  // Always pass tools so LLM can chain calls
                            toolResultMessages: requestRounds.isEmpty ? nil : requestRounds,
                            calendarContext: calendarContext,
                            emailContext: emailContext,
                            chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
                            totalChunkCount: totalChunkCount,
                            currentUserMessageId: currentUserMessageId,
                            turnStartDate: systemPromptDate,
                            deferredMCPSummaries: deferredSummaries.isEmpty ? nil : deferredSummaries,
                            execution: responsesExecution, lane: .main, imageLog: log,
                            persona: turnPersona
                        )
                    },
                    newestUnit: { transmitted in
                        ImageRejectionMarks.newestUnit(transmitted: transmitted, requestMessages: requestHistory, requestRounds: requestRounds)
                    },
                    commit: { scope in
                        var rounds = toolInteractions
                        let committed = try commitImageRejectionMarks(scope, runId: salvageRunId, responses: responsesExecution != nil,
                                                                      messagesForLLM: &messagesForLLM, rounds: &rounds)
                        toolInteractions = rounds
                        guard committed else { return false }
                        requestComposition = try requestView(messagesForLLM, runId: salvageRunId, limit: roundLimit)
                        requestHistory = requestComposition.messages
                        requestRounds = toolInteractions
                        return true
                    }
                )
                response = recovered.response
                if !recovered.excluded.isEmpty {
                    try? await sendText(ImageRejectionRecovery.notice(recovered.excluded))
                }
                // The request was sent — but the guard stands down only if it
                // actually carried the in-flight annotation (nonce-checked).
                if responsesExecution != nil { clearResponsesMidTurnBatch(response) }
                else { clearInFlightMidTurnBatchIfCarried(by: toolInteractions.isEmpty ? nil : toolInteractions) }
                seenGenerationAtRequest = requestGeneration
            } catch let renderError as HarnessAnnotationRenderError {
                // Request construction aborted BEFORE network transmission
                // (MIDTURN_NONCE_PLAN §8 step 13): fail closed — requeue the
                // batch, strip the undeliverable annotation, surface the error.
                restoreInFlightMidTurnBatch(in: &toolInteractions)
                throw renderError
            }
            // BGPRUNE{ A-SEND/close
            }
            // }BGPRUNE
            recordCompactionCalibration(response)
            print("[TIMING] LLM API call took: \(String(format: "%.2f", Date().timeIntervalSince(llmStartTime)))s")
            let roundSpendUSD = spendUSD(from: response)
            if let roundSpendUSD, roundSpendUSD > 0 {
                cumulativeToolSpendUSD += roundSpendUSD
                todaySpentUSD += roundSpendUSD
                monthSpentUSD += roundSpendUSD
                KeychainHelper.recordOpenRouterSpend(roundSpendUSD)
                print("[ConversationManager] Round \(round) spend: +$\(formatUSD(roundSpendUSD)) (total $\(formatUSD(cumulativeToolSpendUSD)))")
            } else {
                print("[ConversationManager] Round \(round) spend unavailable or zero")
            }
            
            switch response {
            case .text(let content, let reasoning, let reasoningDetails, let promptTokens, let completionTokens, _, let native, _):
                // LLM decided to respond with text - we're done
                if let tokens = promptTokens {
                    lastPromptRenderKey = sentRenderKey
                    lastPromptTokens = tokens
                    if let expectedPromptEstimate, activeTurnCheckpoints[salvageRunId ?? UUID()]?.generation ?? 0 > 0 {
                        print("[ActiveCompaction] estimated=\(expectedPromptEstimate) measured=\(tokens) difference=\(tokens - expectedPromptEstimate)")
                    }
                    // Attribute delta to the last tool interaction if one exists
                    if let prev = prevRoundPromptTokens, prevRoundPromptKey == sentRenderKey, !toolInteractions.isEmpty {
                        let delta = tokens - prev
                        applyMeasuredTokenDelta(delta, to: &toolInteractions[toolInteractions.count - 1])
                    }
                    // Compute user message tokens from first-round delta
                    attributeUserTokens(tokens)
                    print("[ConversationManager] LLM returned text response after \(round) round(s) (\(tokens) prompt tokens)")
                } else {
                    print("[ConversationManager] LLM returned text response after \(round) round(s)")
                }
                finalCompletionTokens = completionTokens
                // Sum measured costs across all tool interactions
                let totalMeasured = toolInteractionTokens(toolInteractions)
                let accessedProjects = extractAccessedProjects(from: toolInteractions)
                let changed = await computeLedgerDiff()
                let reasoningModel = (reasoning != nil || reasoningDetails != nil)
                    ? await openRouterService.activeModelIdentifier() : nil
                return ToolAwareResponse(
                    finalText: content,
                    finalReasoning: reasoning,
                    finalReasoningDetails: reasoningDetails,
                    finalReasoningModel: reasoningModel,
                    responsesReplay: native?.envelope,
                    compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                    toolInteractions: toolInteractions,
                    accessedProjects: accessedProjects,
                    measuredToolTokens: totalMeasured > 0 ? totalMeasured : nil,
                    measuredUserTokens: measuredUserTokens,
                    measuredAssistantTokens: {
                        let total = (finalCompletionTokens ?? 0) + totalMeasured
                        return total > 0 ? total : nil
                    }(),
                    measuredAssistantCompletionTokens: finalCompletionTokens,
                    editedFilePaths: changed.edited,
                    generatedFilePaths: changed.generated,
                    subagentSessionEvents: sessionEvents
                )

            case .toolCalls(let received, let calls, let roundPromptTokens, _, _):
                // Model wants to use more tools. Record the round's receipt
                // time once, before dispatch (rendered beside the round).
                var assistantMessage = received
                assistantMessage.issuedAt = HarnessClock.now()
                print("[ConversationManager] Round \(round): LLM requested \(calls.count) tool(s): \(calls.map { $0.function.name })")

                // Track prompt tokens and attribute delta to previous interaction
                if let tokens = roundPromptTokens {
                    lastPromptRenderKey = sentRenderKey
                    lastPromptTokens = tokens
                    if let expectedPromptEstimate, activeTurnCheckpoints[salvageRunId ?? UUID()]?.generation ?? 0 > 0 {
                        print("[ActiveCompaction] estimated=\(expectedPromptEstimate) measured=\(tokens) difference=\(tokens - expectedPromptEstimate)")
                    }
                    if let prev = prevRoundPromptTokens, prevRoundPromptKey == sentRenderKey, !toolInteractions.isEmpty {
                        let delta = tokens - prev
                        applyMeasuredTokenDelta(delta, to: &toolInteractions[toolInteractions.count - 1])
                    }
                    // Compute user message tokens from first-round delta
                    attributeUserTokens(tokens)
                    prevRoundPromptTokens = tokens
                    prevRoundPromptKey = sentRenderKey
                }
                
                if let perTurnCap = toolSpendLimitPerTurnUSD, cumulativeToolSpendUSD >= perTurnCap {
                    didHitToolSpendLimit = true
                    statusMessage = "Spend limit reached, preparing response..."
                    print("[ConversationManager] Tool spend limit reached ($\(formatUSD(cumulativeToolSpendUSD)) >= $\(formatUSD(perTurnCap))); forcing final response")
                    break toolLoop
                }

                if let exceededMessage = freshSpendPauseMessage() {
                    print("[ConversationManager] Daily/monthly spend limit reached during tool loop: \(exceededMessage) (turn-local today $\(formatUSD(todaySpentUSD)), month $\(formatUSD(monthSpentUSD)))")
                    let totalMeasuredSpend = toolInteractionTokens(toolInteractions)
                    let changed = await computeLedgerDiff()
                    return ToolAwareResponse(
                        finalText: exceededMessage,
                        finalReasoning: nil,
                        finalReasoningDetails: nil,
                        compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                        toolInteractions: toolInteractions,
                        accessedProjects: extractAccessedProjects(from: toolInteractions),
                        measuredToolTokens: totalMeasuredSpend > 0 ? totalMeasuredSpend : nil,
                        measuredUserTokens: measuredUserTokens,
                        measuredAssistantTokens: nil,
                        measuredAssistantCompletionTokens: nil,
                        editedFilePaths: changed.edited,
                        generatedFilePaths: changed.generated,
                        subagentSessionEvents: sessionEvents
                    )
                }

                let (executableCalls, blockedResults) = partitionToolCallsForExecution(
                    calls,
                    allowedToolNames: allowedToolNames,
                    priorInteractions: toolInteractions,
                    historicalMessages: messagesForLLM
                )
                if !blockedResults.isEmpty {
                    print("[ConversationManager] Round \(round): blocked \(blockedResults.count) tool call(s) due to turn policy or tool availability")
                }

                // Stale-batch suppression (mid-turn early wake §3.2): the
                // model chose these calls before it could see a queued user
                // message. None runs; each call gets a synthetic not_executed
                // result, the queue drains into the last one, and the model
                // decides again. A message suppresses at most one batch (it
                // is delivered here); after 3 consecutive suppressions the
                // next batch is admitted (flood cap).
                let suppressBatch = batchIsStale() && consecutiveSuppressions < Self.maxConsecutiveSuppressions
                consecutiveSuppressions = suppressBatch ? consecutiveSuppressions + 1 : 0
                if suppressBatch {
                    let now = Date()
                    for call in calls {
                        currentTurnToolLog.append((id: call.id, name: call.function.name, label: Self.toolLogLabel(name: call.function.name, arguments: call.function.arguments) + " (deferred)", startedAt: now, failed: false))
                    }
                    print("[ConversationManager] Round \(round): suppressed \(calls.count) stale tool call(s) — a user message arrived before the batch started")
                }

                // Record each tool use into the per-turn log so the user can
                // retrieve the chronology on demand via /status. We intentionally
                // do NOT push a Telegram progress message here — a single turn
                // can fire dozens of tools and spamming the user is worse than
                // letting them ask for status when they're curious.
                if !executableCalls.isEmpty && !suppressBatch {
                    let now = Date()
                    for call in executableCalls {
                        currentTurnToolLog.append((id: call.id, name: call.function.name, label: Self.toolLogLabel(name: call.function.name, arguments: call.function.arguments), startedAt: now, failed: false))
                    }
                    turnActivity = TurnActivity(
                        kind: .tools(currentTurnToolLog.suffix(executableCalls.count).map { $0.label }),
                        startedAt: now
                    )
                    if let salvageRunId {
                        runPhases[salvageRunId] = .tools(callIds: executableCalls.map(\.id),
                                                         labels: currentTurnToolLog.suffix(executableCalls.count).map { $0.label },
                                                         now)
                    }
                }
                statusMessage = "Executing tools (round \(round))..."
                
                // Execute available tools only. Return explicit errors for blocked/unavailable tool calls.
                // Then reorder results to match the assistant's tool call order for deterministic follow-up prompts.
                if responsesExecution != nil {
                    let uncertain = ToolInteraction(assistantMessage: assistantMessage, results: calls.map {
                        // Typed placeholder (§3.12.1): it names no job, so it
                        // can never settle one — the real outcome stays owed.
                        var placeholder = ToolResultMessage(toolCallId: $0.id, content: "[Interrupted tool intent: outcome unknown. This call was not automatically rerun; inspect external state before repeating it.]")
                        placeholder.outcomeBinding = OutcomeBinding(kind: .interruptedIntent)
                        return placeholder
                    })
                    let pending = toolInteractions + [uncertain]
                    try Self.responsesSalvageFaultForTesting?("placeholder")
                    try requireSalvageOwnership(salvageRunId)
                    try persistResponsesSalvage(pending)
                    toolInteractions = pending
                }
                var toolResults: [ToolResultMessage] = []
                if suppressBatch {
                    toolResults = calls.map(Self.notExecutedResult(for:))
                } else {
                    if !executableCalls.isEmpty {
                        // Diagnostics: the round number rides on every stage
                        // marker of this batch (a task-local; no behaviour
                        // change).
                        let executedResults = try await StageMarkers.$round.withValue(round) {
                            try await toolExecutor.executeParallel(executableCalls)
                        }
                        toolResults.append(contentsOf: executedResults)
                    }
                    if !blockedResults.isEmpty {
                        toolResults.append(contentsOf: blockedResults)
                    }
                }
                try Task.checkCancellation()
                if let failure = BashTools.lastRecordFailure, !detachRecordFailureShown {
                    detachRecordFailureShown = true
                    showMaintenanceNotice("A background job could not be recorded for crash recovery (\(failure)); affected commands kept waiting instead of moving to the background.")
                }
                
                var orderedToolResults: [ToolResultMessage] = []
                var remainingToolResults = toolResults
                for call in assistantMessage.toolCalls {
                    if let index = remainingToolResults.firstIndex(where: { $0.toolCallId == call.id }) {
                        orderedToolResults.append(remainingToolResults.remove(at: index))
                    }
                }
                if !remainingToolResults.isEmpty {
                    print("[ConversationManager] Round \(round): appending \(remainingToolResults.count) unmatched tool result(s) after ordered results")
                    orderedToolResults.append(contentsOf: remainingToolResults)
                }

                // Flag failed calls in the per-turn log (checked here, before
                // the system-note suffix below makes the content non-JSON).
                for result in orderedToolResults where Self.toolResultIndicatesError(result.content) {
                    if let idx = currentTurnToolLog.lastIndex(where: { $0.id == result.toolCallId }) {
                        currentTurnToolLog[idx].failed = true
                    }
                }

                // Tool batch done — the model is reading results and deciding
                // the next step. Reset the activity clock so the live
                // indicator shows this phase's own elapsed time.
                turnActivity = TurnActivity(kind: .thinking, startedAt: Date())
                if let salvageRunId { runPhases[salvageRunId] = .model(Date()) }

                // Extract subagent session events from Agent tool results.
                for (idx, call) in calls.enumerated() where call.function.name == "Agent" {
                    if let result = orderedToolResults.first(where: { $0.toolCallId == call.id }),
                       let data = result.content.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let sid = json["session_id"] as? String {
                        let isNew = (json["is_new_session"] as? Bool) ?? true
                        let desc = (json["final_message"] as? String).map { String($0.prefix(80)) } ?? ""
                        if let argData = call.function.arguments.data(using: .utf8),
                           let argJson = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                           let subType = argJson["subagent_type"] as? String {
                            sessionEvents.append(SubagentSessionEvent(
                                kind: isNew ? .opened : .continued,
                                sessionId: sid,
                                subagentType: subType,
                                description: (argJson["description"] as? String) ?? ""
                            ))
                        }
                    }
                }

                let toolInternalSpendUSD = toolSpendUSD(from: orderedToolResults)
                if toolInternalSpendUSD > 0 {
                    cumulativeToolSpendUSD += toolInternalSpendUSD
                    todaySpentUSD += toolInternalSpendUSD
                    monthSpentUSD += toolInternalSpendUSD
                    KeychainHelper.recordOpenRouterSpend(toolInternalSpendUSD)
                    print("[ConversationManager] Round \(round) research tool spend: +$\(formatUSD(toolInternalSpendUSD)) (total $\(formatUSD(cumulativeToolSpendUSD)))")
                }
                
                print("[ConversationManager] Round \(round) tool execution complete")
                StageMarkers.$round.withValue(round) {
                    StageMarkers.event("round.execution_complete", detail: "\(orderedToolResults.count) result(s)", call: nil)
                }
                
                // Record the batch delivery time on every result of this round
                // (typed `completedAt`, one clock read per batch). The provider
                // boundary renders it as the "[System Note: Current time is now
                // HH:mm:ss]" note after the content, so the model knows exactly
                // how much time passed without the prompt cache prefix changing
                // and without the note ever being baked into persisted content.
                let batchCompletedAt = HarnessClock.now()

                for i in 0..<orderedToolResults.count {
                    // Early neutralization pass (MIDTURN_NONCE_PLAN §8 step 3):
                    // escape the reserved harness-marker prefix in every
                    // finalized tool result BEFORE trusted harness suffixes are
                    // added, so persisted results are already safe and the
                    // final provider-boundary pass is pure defense in depth.
                    orderedToolResults[i].content = MarkerNeutralizer.escape(orderedToolResults[i].content)
                    orderedToolResults[i].completedAt = batchCompletedAt
                }

                // Background results that finished while this round ran are
                // ordinary tool output of this round (round delivery v3 §2.4):
                // appended after every parser above has read the foreground
                // content, before the round is stored, estimated, pruned or
                // compacted, and before the user drain (a mid-turn user block
                // still renders last). Only when a normal request follows.
                if let runID = salvageRunId, !suppressBatch {
                    let capReached = toolSpendLimitPerTurnUSD.map { cumulativeToolSpendUSD >= $0 } ?? false
                    let nextRequestFollows = !capReached && round < maxToolRoundsSafetyLimit
                        && freshSpendPauseMessage() == nil
                    await deliverBackgroundResultsIntoRound(runId: runID, into: &orderedToolResults,
                                                            currentRounds: toolInteractions,
                                                            nextRequestFollows: nextRequestFollows)
                }

                // Deliver any user messages that arrived while this round ran.
                // Tail-appending to the last tool result keeps the prompt
                // prefix stable (same mechanism as the timestamp note above),
                // so the cache is preserved and the model can steer mid-turn.
                // The wake note (§3.11) lists what is still running.
                let wakeStatus: HarnessBackgroundStatus? = pendingMidTurnMessages.isEmpty ? nil
                    : await wakeNoteStatus(movedThisRound: Set(orderedToolResults.compactMap {
                        $0.outcomeBinding?.kind == .moved ? $0.outcomeBinding?.jobId : nil }))
                if let consumed = deliverMidTurnMessages(into: &orderedToolResults, backgroundStatus: wakeStatus),
                   let runID = activeRunId {
                    await TurnWakeCenter.shared.consume(runId: runID, upTo: consumed)
                }

                // Add this interaction to the chain
                let interaction = ToolInteraction(
                    assistantMessage: assistantMessage,
                    results: orderedToolResults
                )
                if responsesExecution != nil {
                    var completed = toolInteractions
                    completed[completed.count - 1] = interaction
                    try Self.responsesSalvageFaultForTesting?("completed")
                    // A run stopped while a newer run owns the recovery file
                    // keeps its completed round in memory (its interrupted
                    // outcome saves it) but never replaces that file.
                    if ownsSalvageFile(salvageRunId) { try persistResponsesSalvage(completed) }
                    toolInteractions = completed
                } else { toolInteractions.append(interaction) }

                if let runID = salvageRunId {
                    activeTurnCheckpoints[runID]?.nextRoundSequence = round + 1
                    activeTurnCheckpoints[runID]?.subagentSessionEvents = sessionEvents
                    let known = activeTurnCheckpoints[runID]?.accessedProjects ?? []
                    let projects = Array(Set(known + (extractAccessedProjects(from: toolInteractions) ?? []))).sorted()
                    activeTurnCheckpoints[runID]?.accessedProjects = projects
                }
                // Mid-loop: prune stored tool interactions from older turns if context is growing too large
                // BGPRUNE{ A-M/open
                if backgroundPruneEngaged {
                    let bgPruneInputs = BackgroundPruneSummaryInputs(
                        currentTurnInteractions: toolInteractions, tools: toolsForRound, calendarContext: calendarContext,
                        emailContext: emailContext, chunkSummaries: chunkSummaries, totalChunkCount: totalChunkCount,
                        currentUserMessageId: currentUserMessageId, turnStartDate: systemPromptDate,
                        deferredMCPSummaries: deferredSummaries, persona: turnPersona)
                    try await backgroundPruneMidLoop(runId: salvageRunId, nextRound: round + 1, inputs: bgPruneInputs,
        execution: responsesExecution,
                        history: { messagesForLLM }, rounds: toolInteractions,
                        replace: { bgPruneReplacements in
                            for bgPruneIndex in messagesForLLM.indices {
                                if let bgPruneNew = bgPruneReplacements[messagesForLLM[bgPruneIndex].id] { messagesForLLM[bgPruneIndex] = bgPruneNew }
                            }
                        },
                        block: { bgPrunePrecomputed in
                            try await self.backgroundPruneMidLoopBlock(precomputed: bgPrunePrecomputed, compact: true,
                                    messagesForLLM: &messagesForLLM, rounds: toolInteractions,
                                    calendarContext: &calendarContext, emailContext: &emailContext,
                                    chunkSummaries: chunkSummaries, totalChunkCount: totalChunkCount,
                                    currentUserMessageId: currentUserMessageId, systemPromptDate: systemPromptDate,
                                    tools: toolsForRound, deferredSummaries: deferredSummaries,
                                    execution: responsesExecution, persona: turnPersona, salvageRunId: salvageRunId,
                                    ledgerDiff: computeLedgerDiff,
                                    prevRoundPromptTokens: &prevRoundPromptTokens, previousPromptScope: &previousPromptScope,
                                    cumulativeToolSpendUSD: &cumulativeToolSpendUSD, todaySpentUSD: &todaySpentUSD, monthSpentUSD: &monthSpentUSD)
                        })
                } else {
                // }BGPRUNE
                let midLoopResult = try await pruneStoredToolInteractionsMidLoop(
                    messagesForLLM: &messagesForLLM,
                    currentTurnInteractions: toolInteractions,
                    calendarContext: calendarContext,
                    emailContext: emailContext,
                    chunkSummaries: chunkSummaries,
                    totalChunkCount: totalChunkCount,
                    currentUserMessageId: currentUserMessageId,
                    turnStartDate: systemPromptDate,
                    tools: toolsForRound,
                    deferredMCPSummaries: deferredSummaries, execution: responsesExecution,
                    persona: turnPersona
                )
                if midLoopResult != .underBudget {
                    prevRoundPromptTokens = nil; lastPromptTokens = nil; previousPromptScope = nil
                }
                if midLoopResult == .pruned {
                    CacheDiagnostics.noteTransition("prune", lane: .main)
                    // Cache is already invalidated by the prune — take the opportunity
                    // to refresh stale calendar/email context with current data for free.
                    let refreshed = await getFrozenSystemContext(forceRefresh: true)
                    calendarContext = refreshed.calendar
                    emailContext = refreshed.email
                }
                if midLoopResult == .exhausted {
                    guard let runID = salvageRunId else { throw PruneArchiveStore.Failure("No active-turn checkpoint owner") }
                    let compactionFiles = await computeLedgerDiff()
                    activeTurnCheckpoints[runID]?.editedFilePaths = compactionFiles.edited
                    activeTurnCheckpoints[runID]?.generatedFilePaths = compactionFiles.generated
                    let priorMaintenanceSpend = activeTurnCheckpoints[runID]?.maintenanceSpendUSD ?? 0
                    try await compactActiveTurn(runID: runID, history: messagesForLLM,
                        tools: toolsForRound, calendar: calendarContext, email: emailContext,
                        summaries: chunkSummaries, totalChunks: totalChunkCount, date: systemPromptDate,
                        deferred: deferredSummaries, execution: responsesExecution, persona: turnPersona)
                    CacheDiagnostics.noteTransition("compaction", lane: .main)
                    let maintenanceSpend = max(0, (activeTurnCheckpoints[runID]?.maintenanceSpendUSD ?? 0) - priorMaintenanceSpend)
                    cumulativeToolSpendUSD += maintenanceSpend; todaySpentUSD += maintenanceSpend; monthSpentUSD += maintenanceSpend
                    prevRoundPromptTokens = nil; lastPromptTokens = nil; previousPromptScope = nil
                }
                // BGPRUNE{ A-M/close
                }
                // }BGPRUNE

                if let perTurnCap = toolSpendLimitPerTurnUSD, cumulativeToolSpendUSD >= perTurnCap {
                    didHitToolSpendLimit = true
                    statusMessage = "Spend limit reached, preparing response..."
                    print("[ConversationManager] Tool spend limit reached after tool execution ($\(formatUSD(cumulativeToolSpendUSD)) >= $\(formatUSD(perTurnCap))); forcing final response")
                    break toolLoop
                }

                if let exceededMessage = freshSpendPauseMessage() {
                    print("[ConversationManager] Daily/monthly spend limit reached after tool execution: \(exceededMessage)")
                    let totalMeasuredSpend = toolInteractionTokens(toolInteractions)
                    let changed = await computeLedgerDiff()
                    return ToolAwareResponse(
                        finalText: exceededMessage,
                        finalReasoning: nil,
                        finalReasoningDetails: nil,
                        compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                        toolInteractions: toolInteractions,
                        accessedProjects: extractAccessedProjects(from: toolInteractions),
                        measuredToolTokens: totalMeasuredSpend > 0 ? totalMeasuredSpend : nil,
                        measuredUserTokens: measuredUserTokens,
                        measuredAssistantTokens: nil,
                        measuredAssistantCompletionTokens: nil,
                        editedFilePaths: changed.edited,
                        generatedFilePaths: changed.generated,
                        subagentSessionEvents: sessionEvents
                    )
                }
                
                statusMessage = "Processing results..."
            }
        }
        
        let didHitSafetyLimit = !didHitToolSpendLimit && !didHitContextLimit
        if didHitSafetyLimit {
            print("[ConversationManager] Safety tool round limit (\(maxToolRoundsSafetyLimit)) reached, forcing final response")
        }

        // Force one final call to produce a user-facing response.
        // The stop instruction is injected as a tail system message AFTER the tool
        // interactions, preserving the prompt cache prefix (system prompt + messages
        // + tool interactions are identical to the previous request).
        let forceFinishTail: String
        if didHitContextLimit {
            forceFinishTail = """
            [CONTEXT LIMIT] This turn has reached the maximum allowed context window. \
            All prunable historical content has been removed and the last tool interaction \
            was discarded because it exceeded the remaining budget. \
            Do NOT call any more tools. Summarize your progress so far: what you accomplished, \
            what you found, and what remains incomplete. Provide the best possible response to the user.
            """
        } else if didHitToolSpendLimit {
            forceFinishTail = """
            [SPEND LIMIT] The tool spend limit for this turn has been reached \
            (spent approximately $\(formatUSD(cumulativeToolSpendUSD)), limit $\(formatUSD(toolSpendLimitPerTurnUSD ?? cumulativeToolSpendUSD))). \
            Do NOT call any more tools. Provide the best possible response to the user \
            using the information you already have.
            """
        } else {
            forceFinishTail = """
            [ROUND LIMIT] You have reached the maximum number of tool rounds for this turn. \
            Do NOT call any more tools. Provide the best possible response to the user \
            using the information you already have.
            """
        }

        try Task.checkCancellation()
        // The forced final pass must see exactly what the tool loop saw: after
        // an active-turn compaction the summary note and the carried verbatim
        // user messages live only in the checkpoint projection, not in
        // messagesForLLM. Computed once so every retry replays the same history.
        // /keepsummaries: one limit for the whole forced final (every retry).
        let finalLimit = KeepSummariesSetting.current()
        var finalComposition = try requestView(messagesForLLM, runId: salvageRunId, limit: finalLimit)
        var finalHistory = finalComposition.messages
        var finalResponse: LLMResponse?
        var finalForceInteractions = toolInteractions
        var finalForceSpendUSD: Double = 0
        // BGPRUNE{ A-FF1
        var bgPruneFinalBase: Int = 0
        // }BGPRUNE
        // BGPRUNE{ A-FF2
        if backgroundPruneEngaged {
            bgPruneFinalBase = finalForceInteractions.count
        }
        // }BGPRUNE
        for attempt in 0...4 {
            let tail = attempt == 0
                ? forceFinishTail
                : """
                \(forceFinishTail)

                [FORCE-FINISH RETRY \(attempt)/4]
                The tool call(s) you requested were not executed because this is a final-summary pass.
                Tool use remains disabled for this pass. Return plain text only.
                """
            // BGPRUNE{ A-FFD
            if backgroundPruneEngaged {
                if backgroundPruneJob != nil {
                    _ = try await backgroundPruneAdmit(runId: salvageRunId, requestKey: backgroundPruneFinalRequestKey(runId: salvageRunId), execution: responsesExecution,
                        admitted: {
                            try await self.backgroundPruneFinalEstimate(history: finalHistory, rounds: finalForceInteractions,
                                tools: lastToolsForRound, calendar: calendarContext, email: emailContext, summaries: chunkSummaries,
                                totalChunks: totalChunkCount, date: systemPromptDate, deferred: lastDeferredSummaries,
                                persona: turnPersona, tail: tail)
                        },
                        liveRounds: { toolInteractions },
                        afterApply: { bgPruneReplacements in
                            for bgPruneIndex in messagesForLLM.indices {
                                if let bgPruneNew = bgPruneReplacements[messagesForLLM[bgPruneIndex].id] { messagesForLLM[bgPruneIndex] = bgPruneNew }
                            }
                            prevRoundPromptTokens = nil; previousPromptScope = nil
                            CacheDiagnostics.noteTransition("prune", lane: .main)
                            let bgPruneRefreshed = await self.getFrozenSystemContext(forceRefresh: true)
                            calendarContext = bgPruneRefreshed.calendar
                            emailContext = bgPruneRefreshed.email
                            finalComposition = try self.backgroundPruneProjection(messagesForLLM, runId: salvageRunId, limit: finalLimit); finalHistory = finalComposition.messages
                            finalForceInteractions = toolInteractions + Array(finalForceInteractions.dropFirst(bgPruneFinalBase))
                            bgPruneFinalBase = toolInteractions.count
                        },
                        inline: {
                            prevRoundPromptTokens = nil; previousPromptScope = nil
                            let bgPruneChanged = try await self.backgroundPruneMidLoopBlock(precomputed: nil, compact: true,
                                    messagesForLLM: &messagesForLLM, rounds: toolInteractions,
                                    calendarContext: &calendarContext, emailContext: &emailContext,
                                    chunkSummaries: chunkSummaries, totalChunkCount: totalChunkCount,
                                    currentUserMessageId: currentUserMessageId, systemPromptDate: systemPromptDate,
                                    tools: lastToolsForRound, deferredSummaries: lastDeferredSummaries,
                                    execution: responsesExecution, persona: turnPersona, salvageRunId: salvageRunId,
                                    ledgerDiff: computeLedgerDiff,
                                    prevRoundPromptTokens: &prevRoundPromptTokens, previousPromptScope: &previousPromptScope,
                                    cumulativeToolSpendUSD: &cumulativeToolSpendUSD, todaySpentUSD: &todaySpentUSD, monthSpentUSD: &monthSpentUSD)
                            if bgPruneChanged {
                                finalComposition = try self.backgroundPruneProjection(messagesForLLM, runId: salvageRunId, limit: finalLimit); finalHistory = finalComposition.messages
                                finalForceInteractions = toolInteractions + Array(finalForceInteractions.dropFirst(bgPruneFinalBase))
                                bgPruneFinalBase = toolInteractions.count
                            }
                            return bgPruneChanged
                        })
                }
            }
            // }BGPRUNE
            let response: LLMResponse
            // BGPRUNE{ A-FFSEND/open
            if backgroundPruneEngaged {
                let bgPruneAdmittedMaximum = backgroundPruneMaximum()
                let bgPruneAdmittedEstimate = try await self.backgroundPruneFinalEstimate(history: finalHistory, rounds: finalForceInteractions,
                    tools: lastToolsForRound, calendar: calendarContext, email: emailContext, summaries: chunkSummaries,
                    totalChunks: totalChunkCount, date: systemPromptDate, deferred: lastDeferredSummaries,
                    persona: turnPersona, tail: tail)
                func bgPruneFinalSend() async throws -> LLMResponse {
                    let recovered = try await ImageRejectionRecovery.run(
                        send: { log in
                            // The attempt's projection, read at send time (same value as today's).
                            let bgPruneFinalHistory = finalHistory
                            sentRenderKey = finalComposition.renderKey; sentStubIDs = finalComposition.stubIDs
                            return try await openRouterService.generateResponse(
                                messages: bgPruneFinalHistory,
                                imagesDirectory: imagesDirectory,
                                documentsDirectory: documentsDirectory,
                                tools: lastToolsForRound,
                                toolResultMessages: finalForceInteractions,
                                calendarContext: calendarContext,
                                emailContext: emailContext,
                                chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
                                totalChunkCount: totalChunkCount,
                                currentUserMessageId: currentUserMessageId,
                                turnStartDate: systemPromptDate,
                                tailSystemMessage: tail,
                                deferredMCPSummaries: lastDeferredSummaries.isEmpty ? nil : lastDeferredSummaries,
                                execution: responsesExecution, lane: .main, imageLog: log,
                                persona: turnPersona
                            )
                        },
                        newestUnit: { transmitted in
                            ImageRejectionMarks.newestUnit(transmitted: transmitted, requestMessages: finalHistory, requestRounds: finalForceInteractions)
                        },
                        commit: { scope in
                            var rounds = toolInteractions
                            let committed = try commitImageRejectionMarks(scope, runId: salvageRunId, responses: responsesExecution != nil,
                                                                          messagesForLLM: &messagesForLLM, rounds: &rounds)
                            toolInteractions = rounds
                            _ = ImageRejectionMarks.apply(scope, toCurrent: &finalForceInteractions)
                            guard committed else { return false }
                            finalComposition = try requestView(messagesForLLM, runId: salvageRunId, limit: finalLimit); finalHistory = finalComposition.messages
                            return true
                        }
                    )
                    if !recovered.excluded.isEmpty {
                        try? await sendText(ImageRejectionRecovery.notice(recovered.excluded))
                    }
                    if responsesExecution != nil { clearResponsesMidTurnBatch(recovered.response) }
                    else { clearInFlightMidTurnBatchIfCarried(by: finalForceInteractions) }
                    return recovered.response
                }
                do {
                    response = try await backgroundPruneConverge(runId: salvageRunId, requestKey: backgroundPruneFinalRequestKey(runId: salvageRunId),
                        admittedEstimate: bgPruneAdmittedEstimate, admittedMaximum: bgPruneAdmittedMaximum, execution: responsesExecution,
                        send: { try await bgPruneFinalSend() },
                        admitted: {
                            try await self.backgroundPruneFinalEstimate(history: finalHistory, rounds: finalForceInteractions,
                                tools: lastToolsForRound, calendar: calendarContext, email: emailContext, summaries: chunkSummaries,
                                totalChunks: totalChunkCount, date: systemPromptDate, deferred: lastDeferredSummaries,
                                persona: turnPersona, tail: tail)
                        },
                        liveRounds: { toolInteractions },
                        afterApply: { bgPruneReplacements in
                            for bgPruneIndex in messagesForLLM.indices {
                                if let bgPruneNew = bgPruneReplacements[messagesForLLM[bgPruneIndex].id] { messagesForLLM[bgPruneIndex] = bgPruneNew }
                            }
                            prevRoundPromptTokens = nil; previousPromptScope = nil
                            CacheDiagnostics.noteTransition("prune", lane: .main)
                            let bgPruneRefreshed = await self.getFrozenSystemContext(forceRefresh: true)
                            calendarContext = bgPruneRefreshed.calendar
                            emailContext = bgPruneRefreshed.email
                            finalComposition = try self.backgroundPruneProjection(messagesForLLM, runId: salvageRunId, limit: finalLimit); finalHistory = finalComposition.messages
                            finalForceInteractions = toolInteractions + Array(finalForceInteractions.dropFirst(bgPruneFinalBase))
                            bgPruneFinalBase = toolInteractions.count
                        },
                        inline: {
                            prevRoundPromptTokens = nil; previousPromptScope = nil
                            let bgPruneChanged = try await self.backgroundPruneMidLoopBlock(precomputed: nil, compact: false,
                                    messagesForLLM: &messagesForLLM, rounds: toolInteractions,
                                    calendarContext: &calendarContext, emailContext: &emailContext,
                                    chunkSummaries: chunkSummaries, totalChunkCount: totalChunkCount,
                                    currentUserMessageId: currentUserMessageId, systemPromptDate: systemPromptDate,
                                    tools: lastToolsForRound, deferredSummaries: lastDeferredSummaries,
                                    execution: responsesExecution, persona: turnPersona, salvageRunId: salvageRunId,
                                    ledgerDiff: computeLedgerDiff,
                                    prevRoundPromptTokens: &prevRoundPromptTokens, previousPromptScope: &previousPromptScope,
                                    cumulativeToolSpendUSD: &cumulativeToolSpendUSD, todaySpentUSD: &todaySpentUSD, monthSpentUSD: &monthSpentUSD)
                            if bgPruneChanged {
                                finalComposition = try self.backgroundPruneProjection(messagesForLLM, runId: salvageRunId, limit: finalLimit); finalHistory = finalComposition.messages
                                finalForceInteractions = toolInteractions + Array(finalForceInteractions.dropFirst(bgPruneFinalBase))
                                bgPruneFinalBase = toolInteractions.count
                            }
                            return bgPruneChanged
                        },
                        resend: {
                            prevRoundPromptTokens = nil; self.lastPromptTokens = nil; previousPromptScope = nil
                            return try await bgPruneFinalSend()
                        })
                } catch let renderError as HarnessAnnotationRenderError {
                    stripCurrentTurnAnnotations(in: &finalForceInteractions)
                    restoreInFlightMidTurnBatch(in: &toolInteractions)
                    throw renderError
                }
            } else {
            // }BGPRUNE
            do {
                // Same image-rejection recovery as the tool loop (plan v2 §2.4).
                let recovered = try await ImageRejectionRecovery.run(
                    send: { log in
                        sentRenderKey = finalComposition.renderKey; sentStubIDs = finalComposition.stubIDs
                        return try await openRouterService.generateResponse(
                            messages: finalHistory,
                            imagesDirectory: imagesDirectory,
                            documentsDirectory: documentsDirectory,
                            tools: lastToolsForRound,
                            toolResultMessages: finalForceInteractions,
                            calendarContext: calendarContext,
                            emailContext: emailContext,
                            chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
                            totalChunkCount: totalChunkCount,
                            currentUserMessageId: currentUserMessageId,
                            turnStartDate: systemPromptDate,
                            tailSystemMessage: tail,
                            deferredMCPSummaries: lastDeferredSummaries.isEmpty ? nil : lastDeferredSummaries,
                            execution: responsesExecution, lane: .main, imageLog: log,
                            persona: turnPersona
                        )
                    },
                    newestUnit: { transmitted in
                        ImageRejectionMarks.newestUnit(transmitted: transmitted, requestMessages: finalHistory, requestRounds: finalForceInteractions)
                    },
                    commit: { scope in
                        var rounds = toolInteractions
                        let committed = try commitImageRejectionMarks(scope, runId: salvageRunId, responses: responsesExecution != nil,
                                                                      messagesForLLM: &messagesForLLM, rounds: &rounds)
                        toolInteractions = rounds
                        _ = ImageRejectionMarks.apply(scope, toCurrent: &finalForceInteractions)
                        guard committed else { return false }
                        finalComposition = try requestView(messagesForLLM, runId: salvageRunId, limit: finalLimit); finalHistory = finalComposition.messages
                        return true
                    }
                )
                response = recovered.response
                if !recovered.excluded.isEmpty {
                    try? await sendText(ImageRejectionRecovery.notice(recovered.excluded))
                }
                // Carried-check matters most here: an exhaustion path that
                // discarded the annotation's interaction reaches this
                // force-finish with finalForceInteractions lacking the
                // annotation — the guard must stay armed for teardown
                // recovery instead of being cleared by this success.
                if responsesExecution != nil { clearResponsesMidTurnBatch(response) }
                else { clearInFlightMidTurnBatchIfCarried(by: finalForceInteractions) }
            } catch let renderError as HarnessAnnotationRenderError {
                // Fail closed before network transmission: requeue the batch
                // and strip the undeliverable annotation from BOTH the retry
                // chain and the interactions that will be persisted.
                stripCurrentTurnAnnotations(in: &finalForceInteractions)
                restoreInFlightMidTurnBatch(in: &toolInteractions)
                throw renderError
            }
            // BGPRUNE{ A-FFSEND/close
            }
            // }BGPRUNE
            if let spend = spendUSD(from: response), spend > 0 {
                finalForceSpendUSD += spend
            }
            finalResponse = response
            switch response {
            case .text:
                break
            case .toolCalls(let assistantMessage, let calls, _, _, _):
                finalForceInteractions.append(disabledMaintenanceToolInteraction(
                    assistantMessage: assistantMessage,
                    calls: calls,
                    reason: "Tool calls are disabled during the final-summary pass. This tool was not executed. Return the final response as plain text only."
                ))
            }
            if case .text = response { break }
        }
        if finalForceSpendUSD > 0 {
            KeychainHelper.recordOpenRouterSpend(finalForceSpendUSD)
        }
        guard let finalResponse else {
            throw OpenRouterError.noContent
        }
        
        let finalPromptTokens: Int?
        let finalCompTokens: Int?
        switch finalResponse {
        case .text(_, _, _, let pt, let ct, _, _, _):
            finalPromptTokens = pt
            finalCompTokens = ct
        case .toolCalls(_, _, let pt, let ct, _):
            finalPromptTokens = pt
            finalCompTokens = ct
        }
        if let tokens = finalPromptTokens {
            lastPromptRenderKey = sentRenderKey
            lastPromptTokens = tokens
            if let prev = prevRoundPromptTokens, prevRoundPromptKey == sentRenderKey, !toolInteractions.isEmpty {
                applyMeasuredTokenDelta(tokens - prev, to: &toolInteractions[toolInteractions.count - 1])
            }
            attributeUserTokens(tokens)
        }

        let totalMeasuredSpend = toolInteractionTokens(toolInteractions)
        let accessedProjects = extractAccessedProjects(from: toolInteractions)
        let changed = await computeLedgerDiff()

        let assistantTokens: Int? = {
            let comp = finalCompTokens ?? 0
            let tools = totalMeasuredSpend
            let total = comp + tools
            return total > 0 ? total : nil
        }()

        switch finalResponse {
        case .text(let content, let reasoning, let reasoningDetails, _, _, _, let native, _):
            let reasoningModel = (reasoning != nil || reasoningDetails != nil)
                ? await openRouterService.activeModelIdentifier() : nil
            return ToolAwareResponse(
                finalText: content,
                finalReasoning: reasoning,
                finalReasoningDetails: reasoningDetails,
                finalReasoningModel: reasoningModel,
                    responsesReplay: native?.envelope,
                compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                toolInteractions: toolInteractions,
                accessedProjects: accessedProjects,
                measuredToolTokens: totalMeasuredSpend > 0 ? totalMeasuredSpend : nil,
                measuredUserTokens: measuredUserTokens,
                measuredAssistantTokens: assistantTokens,
                measuredAssistantCompletionTokens: finalCompTokens,
                editedFilePaths: changed.edited,
                generatedFilePaths: changed.generated,
                subagentSessionEvents: sessionEvents
            )
        case .toolCalls(_, _, _, _, _):
            return ToolAwareResponse(
                finalText: "I completed the requested operations, but had trouble summarizing the results.",
                finalReasoning: nil,
                finalReasoningDetails: nil,
                compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                toolInteractions: toolInteractions,
                accessedProjects: accessedProjects,
                measuredToolTokens: totalMeasuredSpend > 0 ? totalMeasuredSpend : nil,
                measuredUserTokens: measuredUserTokens,
                measuredAssistantTokens: assistantTokens,
                measuredAssistantCompletionTokens: finalCompTokens,
                editedFilePaths: changed.edited,
                generatedFilePaths: changed.generated,
                subagentSessionEvents: sessionEvents
            )
        }
    }
    
    /// nil = no per-turn cap (the default).
    func configuredToolSpendLimitPerTurnUSD() -> Double? {
        guard let rawValue = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let parsed = Double(rawValue),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return nil
        }
        return parsed
    }

    private func configuredDailyToolSpendLimitUSD() -> Double? {
        guard let rawValue = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let parsed = Double(rawValue),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return nil
        }
        return parsed
    }

    private func configuredMonthlyToolSpendLimitUSD() -> Double? {
        guard let rawValue = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let parsed = Double(rawValue),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return nil
        }
        return parsed
    }

    /// The AUTHORITATIVE snapshot (mid-turn early wake §3.6.3): model spend
    /// plus the tool-charge union (charges recorded by background/detached
    /// jobs, including during this turn), with its completeness.
    func currentSpendLimitStatus(referenceDate: Date = Date()) -> SpendLimitStatus {
        let gate = SpendGate.status(referenceDate: referenceDate)
        return SpendLimitStatus(
            todaySpentUSD: gate.todaySpentUSD,
            monthSpentUSD: gate.monthSpentUSD,
            dailyBaseLimitUSD: configuredDailyToolSpendLimitUSD(),
            monthlyBaseLimitUSD: configuredMonthlyToolSpendLimitUSD(),
            dailyExtraUSD: gate.dailyExtraUSD,
            monthlyExtraUSD: gate.monthlyExtraUSD,
            accounting: gate.accounting
        )
    }

    /// Daily/monthly enforcement point (§3.6.3): a FRESH authoritative
    /// snapshot, not turn-start locals (a detached job may have recorded a
    /// charge meanwhile). A reached cap, or a configured cap that cannot be
    /// verified (incomplete accounting), pauses paid work.
    private func freshSpendPauseMessage() -> String? {
        let fresh = currentSpendLimitStatus(referenceDate: Date())
        if let exceeded = spendLimitExceededMessage(todaySpentUSD: fresh.todaySpentUSD, monthSpentUSD: fresh.monthSpentUSD,
                                                    dailyLimitUSD: fresh.effectiveDailyLimitUSD,
                                                    monthlyLimitUSD: fresh.effectiveMonthlyLimitUSD) {
            return exceeded
        }
        return fresh.unverifiable ? SpendGate.unverifiableMessage(fresh.accounting) : nil
    }

    private func spendLimitExceededMessage(
        todaySpentUSD: Double,
        monthSpentUSD: Double,
        dailyLimitUSD: Double?,
        monthlyLimitUSD: Double?
    ) -> String? {
        let dailyExceeded = dailyLimitUSD.map { todaySpentUSD >= $0 } ?? false
        let monthlyExceeded = monthlyLimitUSD.map { monthSpentUSD >= $0 } ?? false
        guard dailyExceeded || monthlyExceeded else { return nil }

        if dailyExceeded, monthlyExceeded, let dailyLimitUSD, let monthlyLimitUSD {
            return "I paused tool usage because both spend limits were reached (today: $\(formatUSD(todaySpentUSD)) / $\(formatUSD(dailyLimitUSD)); this month: $\(formatUSD(monthSpentUSD)) / $\(formatUSD(monthlyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or change the limits for good with `/spend daily <usd|off>` and `/spend monthly <usd|off>`."
        }
        if dailyExceeded, let dailyLimitUSD {
            return "I paused tool usage because the daily spend limit was reached (today: $\(formatUSD(todaySpentUSD)) / $\(formatUSD(dailyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or change it for good with `/spend daily <usd|off>` / `/spend monthly <usd|off>`."
        }
        if monthlyExceeded, let monthlyLimitUSD {
            return "I paused tool usage because the monthly spend limit was reached (this month: $\(formatUSD(monthSpentUSD)) / $\(formatUSD(monthlyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or change it for good with `/spend daily <usd|off>` / `/spend monthly <usd|off>`."
        }
        return nil
    }
    
    func spendUSD(from response: LLMResponse) -> Double? {
        switch response {
        case .text(_, _, _, _, _, let spendUSD, _, _):
            return spendUSD
        case .toolCalls(_, _, _, _, let spendUSD):
            return spendUSD
        }
    }

    private func toolSpendUSD(from results: [ToolResultMessage]) -> Double {
        results
            .compactMap(\.spendUSD)
            .filter { $0.isFinite && $0 > 0 }
            .reduce(0, +)
    }
}
