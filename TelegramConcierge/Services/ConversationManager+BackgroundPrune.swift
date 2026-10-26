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

// BGPRUNE{ A-EXT
extension ConversationManager {
    // MARK: Background pruning (BACKGROUND_PRUNE_PLAN v4.1) — ON-only code.
    //
    // Everything below runs only behind `backgroundPruneEngaged` (switch ON
    // or a job in the slot). With the switch OFF and the slot empty no
    // function here is reached: every marked call site reduces to its
    // original statement (§15).

    /// Test seams (nil in production).
    nonisolated(unsafe) static var bgPruneHoldForTesting: (@Sendable (String) async -> Void)? = nil
    nonisolated(unsafe) static var bgPruneEventForTesting: (@Sendable (String) -> Void)? = nil
    nonisolated(unsafe) static var bgPruneDetailForTesting: (@Sendable (String, String) -> Void)? = nil
    nonisolated(unsafe) static var bgPruneDeadlineSecondsForTesting: Double? = nil
    nonisolated(unsafe) static var bgPruneDrainSecondsForTesting: Double? = nil
    nonisolated(unsafe) static var bgPruneWriteSetViolationForTesting: Bool? = nil

    var backgroundPruneEngaged: Bool {
        backgroundPruneJob != nil || switchDefaults.bool(forKey: Self.backgroundPruneDefaultsKey)
    }

    var backgroundPruneSwitchOn: Bool {
        switchDefaults.bool(forKey: Self.backgroundPruneDefaultsKey)
    }

    private func bgPruneLog(_ event: String, _ detail: String = "") {
        backgroundPruneCounters[event, default: 0] += 1
        print("[BackgroundPrune] \(event)\(detail.isEmpty ? "" : " — " + detail)")
        Self.bgPruneEventForTesting?(event)
    }

    private func bgPruneHold(_ point: String) async {
        if let hold = Self.bgPruneHoldForTesting { await hold(point) }
    }

    private func bgPrunePlan(_ job: BackgroundPruneJob) -> PrunePlan {
        PrunePlan(actions: job.planActions.map { $0.isTool
                    ? .toolInteractions(index: $0.index, savedTokens: $0.savedTokens)
                    : .media(index: $0.index, savedTokens: $0.savedTokens) },
                  pruningBoundary: job.planBoundary)
    }

    private func bgPrunePlanActions(_ plan: PrunePlan) -> [BackgroundPrunePlanAction] {
        plan.actions.map { action in
            switch action {
            case .toolInteractions(let index, let saved): return BackgroundPrunePlanAction(isTool: true, index: index, savedTokens: saved)
            case .media(let index, let saved): return BackgroundPrunePlanAction(isTool: false, index: index, savedTokens: saved)
            }
        }
    }

    // MARK: Ceiling (§9)

    private func bgPruneIdentity(_ execution: ProviderExecutionContext?) async -> (identity: String, model: String) {
        let context: ProviderExecutionContext
        if let execution { context = execution }
        else { context = await openRouterService.executionContext(modelOverride: nil, providerOverride: nil,
                reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main) }
        let pin = context.providerPreferences?.only?.joined(separator: ",") ?? ""
        let identity = BackgroundPruneContextWindow.identity(provider: context.provider.rawValue, profile: context.profileIdentity,
            wire: String(describing: context.wireProtocol), model: context.model, pin: pin)
        return (identity, context.model)
    }

    /// One consistent read of the live maximum and the ceiling derived from
    /// it for this identity (v4.1: never captured across a decision).
    private func bgPruneLimits(identity: String, model: String) -> (maximum: Int, ceiling: Int) {
        let maximum = configuredMaxContextTokens()
        let ceiling = BackgroundPruneCeiling.ceiling(maximum: maximum,
            window: BackgroundPruneContextWindow.window(identity: identity, model: model),
            observed: backgroundPruneObservedBounds[identity])
        return (maximum, ceiling)
    }

    // MARK: Estimates (today's arithmetic on live state, §7.7 table)

    /// Statement-for-statement the estimate half of
    /// `pruneToolInteractionsIfNeeded` (pre-request site), on live `messages`.
    private func bgPrunePreRequestEstimate(_ inputs: BackgroundPruneSummaryInputs) async throws -> (total: Int, prunable: Bool) {
        let mandatoryEstimate = try await openRouterService.activeTurnRequestEstimate(messages: [], rounds: [],
            images: imagesDirectory, documents: documentsDirectory, tools: inputs.tools,
            calendar: inputs.calendarContext, email: inputs.emailContext, summaries: inputs.chunkSummaries,
            totalChunks: inputs.totalChunkCount, date: inputs.turnStartDate, deferred: inputs.deferredMCPSummaries,
            persona: inputs.persona)
        let providerIsLMStudio = currentProviderIsLMStudio()
        var totalTokens: Int
        let decisionView = PruneSummaryRetention.compose(messages, limit: KeepSummariesSetting.current())
        if let real = promptMeasurement(for: decisionView) {
            totalTokens = real + estimatedTokensAddedSinceLastPrompt(currentUserMessageId: inputs.currentUserMessageId, isLMStudio: providerIsLMStudio, in: decisionView.messages)
        } else {
            totalTokens = mandatoryEstimate.tokens
            for message in decisionView.messages {
                totalTokens += estimatedPromptTokens(for: message, isLMStudio: providerIsLMStudio)
                totalTokens += toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)
            }
        }
        return (totalTokens, bgPruneHasPrunable(messages, providerIsLMStudio: providerIsLMStudio))
    }

    /// Statement-for-statement the estimate half of
    /// `pruneStoredToolInteractionsMidLoop`, on the live request view.
    private func bgPruneMidLoopEstimate(history: [Message], rounds: [ToolInteraction], inputs: BackgroundPruneSummaryInputs) async throws -> (total: Int, prunable: Bool) {
        let mandatoryEstimate = try await openRouterService.activeTurnRequestEstimate(messages: [], rounds: [],
            images: imagesDirectory, documents: documentsDirectory, tools: inputs.tools,
            calendar: inputs.calendarContext, email: inputs.emailContext, summaries: inputs.chunkSummaries,
            totalChunks: inputs.totalChunkCount, date: inputs.turnStartDate, deferred: inputs.deferredMCPSummaries,
            persona: inputs.persona)
        let providerIsLMStudio = currentProviderIsLMStudio()
        var totalTokens: Int
        let decisionView = PruneSummaryRetention.compose(history, limit: KeepSummariesSetting.current())
        if let real = promptMeasurement(for: decisionView) {
            totalTokens = real + (rounds.last.map { currentTurnInteractionTokens($0, isLMStudio: providerIsLMStudio) } ?? 0)
        } else {
            totalTokens = mandatoryEstimate.tokens
            for message in decisionView.messages {
                totalTokens += estimatedPromptTokens(for: message, isLMStudio: providerIsLMStudio)
                totalTokens += toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)
            }
            totalTokens += rounds.reduce(0) { $0 + currentTurnInteractionTokens($1, isLMStudio: providerIsLMStudio) }
        }
        return (totalTokens, bgPruneHasPrunable(history, providerIsLMStudio: providerIsLMStudio))
    }

    private func bgPruneHasPrunable(_ history: [Message], providerIsLMStudio: Bool) -> Bool {
        var prunableToolTokens = 0
        var prunableMediaTokens = 0
        for message in history {
            if message.role == .assistant
                && (!message.toolInteractions.isEmpty || message.hasFinalReasoningPayload || message.activeTurnCompaction != nil) {
                prunableToolTokens += toolTokensForMessage(message, isLMStudio: providerIsLMStudio)
                    + estimatedFinalReasoningTokens(message)
                    + (message.activeTurnCompaction.map { ActiveTurnBudget.text($0.promptText) } ?? 0)
            }
            if message.hasUnprunedMedia {
                prunableMediaTokens += mediaSavingsForMessage(message, isLMStudio: providerIsLMStudio)
            }
        }
        return prunableToolTokens > 0 || prunableMediaTokens > 0
            || !compressibleUserMessageIndices(upToIndex: max(0, history.count - 1), in: history).isEmpty
    }

    private func bgPruneCapture(runId: UUID, source: [Message]) -> BackgroundPruneCapture {
        BackgroundPruneCapture(runId: runId, generation: backgroundPruneGeneration, messagesCount: messages.count,
                               messagesLast: messages.last?.id, sourceCount: source.count, sourceLast: source.last?.id)
    }

    private func bgPruneCheckpointRounds() -> [ToolInteraction] {
        activeTurnCheckpoints.values.flatMap(\.retainedInteractions)
    }

    // MARK: Freeze (§5)

    /// Freezes a job when every admission and eligibility condition holds;
    /// false means "run today's inline statement at this boundary". A
    /// cancelled or superseded run throws (it creates nothing).
    private func bgPruneFreeze(site: BackgroundPruneSite, capture: BackgroundPruneCapture, totalTokens: Int,
                               liveSource: () -> [Message], currentRounds: [ToolInteraction],
                               inputs: BackgroundPruneSummaryInputs, execution: ProviderExecutionContext?) async throws -> Bool {
        // Step 1 (awaits first): the execution today's summary resolves.
        let selected: ProviderExecutionContext
        if let execution { selected = execution }
        else { selected = await openRouterService.executionContext(modelOverride: nil,
                providerOverride: nil, reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main) }
        let identity = await bgPruneIdentity(selected)
        await bgPruneHold("freeze.afterAwait")
        // Step 2: synchronous re-check after the last await; nothing below
        // suspends until the job is registered.
        try Task.checkCancellation()
        guard activeRunId == capture.runId else { throw CancellationError() }
        let source = liveSource()
        guard backgroundPruneGeneration == capture.generation, backgroundPruneSwitchOn, backgroundPruneJob == nil,
              !backgroundPruneFallbackDue, !archiveExitPending, !isRestoringMind,
              messages.count == capture.messagesCount, messages.last?.id == capture.messagesLast,
              source.count == capture.sourceCount, source.last?.id == capture.sourceLast else {
            bgPruneLog("bgprune.freeze.recheck-failed")
            return false
        }
        let limits = bgPruneLimits(identity: identity.identity, model: identity.model)
        // Step 3: today's plan on the same source.
        let providerIsLMStudio = currentProviderIsLMStudio()
        let targetTokens = configuredTargetContextTokens()
        let plan = buildPrunePlan(for: source, totalTokens: totalTokens, targetTokens: targetTokens,
                                  protectedIndex: nil, providerIsLMStudio: providerIsLMStudio)
        let safeBoundary = min(plan.pruningBoundary, max(messages.count - 1, 0))
        let compressedIndices = compressibleUserMessageIndices(upToIndex: safeBoundary, in: source)
        let manifestIndices = Array(Set(plan.affectedIndices + compressedIndices)).sorted()
        // Step 4: eligibility (any failure → today's inline statement).
        func ineligible(_ reason: String) -> Bool { bgPruneLog("bgprune.ineligible.\(reason)"); return false }
        guard !plan.isEmpty || !compressedIndices.isEmpty,
              let anchor = pruneSummaryAnchorIndex(plan: plan, compressedIndices: compressedIndices, messageCount: source.count) else {
            return ineligible("empty")
        }
        guard totalTokens < limits.ceiling else { return ineligible("at-ceiling") }
        guard BackgroundPruneCeiling.backgroundAllowed(maximum: limits.maximum, ceiling: limits.ceiling) else { return ineligible("headroom") }
        let projected = BackgroundPruneCeiling.saturatingAdd(
            BackgroundPruneCeiling.saturatingSubtract(totalTokens, plan.savedTokens), BackgroundPruneCeiling.metadataAllowance)
        guard projected <= limits.maximum else { return ineligible("insufficient") }
        let manifestIDs = manifestIndices.map { source[$0].id }
        if let trigger = inputs.currentUserMessageId, manifestIDs.contains(trigger) { return ineligible("trigger") }
        if let newest = source.lastIndex(where: { !$0.toolInteractions.isEmpty }),
           plan.affectedIndices.contains(newest),
           source[newest].toolInteractions.reduce(0, { $0 + ActiveTurnBudget.round($1) }) > ActiveTurnBudget(maximum: limits.maximum).inputCeiling {
            return ineligible("oversized")
        }
        do { try settleJobEvidenceBeforeRemoval(of: manifestIndices.map { source[$0] }) }
        catch { return ineligible("evidence") }
        // Step 5: the pinned snapshot, exactly today's call.
        let livePreimage = messages
        let reference: PruneArchiveReference
        do {
            reference = try PruneArchiveStore.write(messages: livePreimage, currentRounds: currentRounds, alternateMessages: source,
                trigger: site.rawValue, removedIDs: manifestIDs, pin: true)
        } catch { return ineligible("snapshot") }
        // Step 6: register; the worker, its monitor and the watchdog start.
        let seconds = Self.bgPruneDeadlineSecondsForTesting ?? 600
        let job = BackgroundPruneJob(historyGeneration: backgroundPruneGeneration, freezeRunId: capture.runId, site: site,
            frozenPreimage: livePreimage, source: source, summaryRounds: currentRounds,
            planActions: bgPrunePlanActions(plan), planBoundary: plan.pruningBoundary, compressedIndices: compressedIndices,
            safeBoundary: safeBoundary, anchor: anchor, manifestIDs: manifestIDs, triggerMessageID: inputs.currentUserMessageId,
            snapshotRef: reference, totalTokens: totalTokens, targetTokens: targetTokens,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000))))
        job.activityId = beginMaintenance(.pruning)
        backgroundPruneJob = job
        var frozenInputs = inputs
        frozenInputs.execution = selected
        bgPruneStartWorker(job, inputs: frozenInputs)
        bgPruneLog("bgprune.freeze.\(site == .preRequest ? "pre-request" : "mid-loop")",
                   "~\(totalTokens) tokens, ceiling \(limits.ceiling), \(manifestIDs.count) message(s)")
        return true
    }

    // MARK: Worker (§6), monitor, watchdog (§4)

    private func bgPruneStartWorker(_ job: BackgroundPruneJob, inputs: BackgroundPruneSummaryInputs) {
        let jobId = job.id
        let generation = job.historyGeneration
        let plan = bgPrunePlan(job)
        let compressed = job.compressedIndices
        let source = job.source
        let actions = job.planActions
        let worker = Task.detached { @MainActor [weak self] () -> BackgroundPruneWorkerResult in
            guard let self else { return BackgroundPruneWorkerResult(summary: .cancelled, descriptions: []) }
            await self.bgPruneHold("worker.summary")
            let summary = await self.backgroundPruneSummary(plan: plan, compressedIndices: compressed, sourceMessages: source, inputs: inputs)
            if case .cancelled = summary { return BackgroundPruneWorkerResult(summary: .cancelled, descriptions: []) }
            await self.bgPruneHold("worker.descriptions")
            let descriptions = await self.backgroundPruneDescriptions(actions: actions, source: source)
            if Task.isCancelled { return BackgroundPruneWorkerResult(summary: .cancelled, descriptions: []) }
            return BackgroundPruneWorkerResult(summary: summary, descriptions: descriptions)
        }
        job.worker = worker
        job.monitor = Task { @MainActor [weak self] in
            let result = await worker.value
            self?.bgPruneWorkerTerminated(jobId: jobId, generation: generation, result: result)
        }
        let deadline = job.deadline
        job.watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.bgPruneDeadlineFired(jobId: jobId)
        }
    }

    private func bgPruneWorkerTerminated(jobId: UUID, generation: UInt64, result: BackgroundPruneWorkerResult) {
        guard let job = backgroundPruneJob, job.id == jobId, job.historyGeneration == generation, !job.workerTerminated else {
            bgPruneLog("bgprune.termination.stale")
            return
        }
        job.workerTerminated = true
        if let activity = job.activityId { endMaintenance(activity); job.activityId = nil }
        job.watchdog?.cancel()
        if job.isRunning, !job.revoked, backgroundPruneGeneration == generation, result.summary != .cancelled {
            job.phase = .ready(result)
            bgPruneLog("bgprune.ready")
            bgPruneResumePhaseWaiters(job)
            return
        }
        var reason = BackgroundPruneReason.failure
        if case .retiring(let retired) = job.phase { reason = retired }
        else if backgroundPruneGeneration != generation { reason = .generation }
        if (reason == .deadline || reason == .failure), backgroundPruneSwitchOn, !job.inlineDebtConsumed {
            backgroundPruneFallbackDue = true
            bgPruneLog("bgprune.fallback-owed.\(reason.rawValue)")
        }
        bgPruneLog("bgprune.terminated.\(reason.rawValue)")
        bgPruneReleaseSlot(job)
    }

    private func bgPruneDeadlineFired(jobId: UUID) {
        guard let job = backgroundPruneJob, job.id == jobId, job.isRunning else { return }
        job.phase = .retiring(.deadline)
        job.worker?.cancel()
        bgPruneLog("bgprune.deadline")
        bgPruneResumePhaseWaiters(job)
    }

    /// Releases the slot exactly once, when the worker has terminated and
    /// no apply is in progress (N9). Completes a pending OFF transition.
    private func bgPruneReleaseSlot(_ job: BackgroundPruneJob) {
        guard !job.released, backgroundPruneJob === job, job.workerTerminated, !job.isApplying else { return }
        job.released = true
        PruneArchiveStore.release(job.snapshotRef)
        backgroundPruneJob = nil
        scheduleSummaryRetentionIdlePass()
        job.watchdog?.cancel()
        bgPruneResumePhaseWaiters(job)
        let drains = job.drainWaiters
        job.drainWaiters = [:]
        for (_, continuation) in drains { continuation.resume() }
        bgPruneLog("bgprune.released")
        if backgroundPrunePendingOff {
            backgroundPrunePendingOff = false
            if backgroundPruneSwitchOn {
                bgPruneLog("bgprune.off.superseded")
            } else {
                backgroundPruneFallbackDue = false
                bgPruneLog("bgprune.off.completed")
            }
        }
    }

    private func bgPruneResumePhaseWaiters(_ job: BackgroundPruneJob) {
        let waiters = job.phaseWaiters
        job.phaseWaiters = [:]
        for (_, continuation) in waiters { continuation.resume() }
    }

    private func bgPruneResumeWaiter(jobId: UUID, waiterId: UUID, drain: Bool) {
        guard let job = backgroundPruneJob, job.id == jobId else { return }
        if drain { job.drainWaiters.removeValue(forKey: waiterId)?.resume() }
        else { job.phaseWaiters.removeValue(forKey: waiterId)?.resume() }
    }

    // MARK: Waits (§7.3)

    /// The phase wait (R only, at most once per R, only on a running job).
    private func bgPruneAwaitPhaseSettled(_ job: BackgroundPruneJob, runId: UUID) async throws {
        guard job.isRunning else { return }
        let previousPhase = runPhases[runId]
        runPhases[runId] = .pruneWait(Date())
        let marker = StageMarkers.enter("prune.wait", call: nil)
        bgPruneLog("bgprune.wait.begin")
        defer {
            StageMarkers.exit(marker, Task.isCancelled ? .cancelled : .ok)
            if case .pruneWait = runPhases[runId] { runPhases[runId] = previousPhase ?? .model(Date()) }
            bgPruneLog("bgprune.wait.end")
        }
        let waiterId = UUID()
        let jobId = job.id
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || !job.isRunning || job.released { continuation.resume(); return }
                job.phaseWaiters[waiterId] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.bgPruneResumeWaiter(jobId: jobId, waiterId: waiterId, drain: false) }
        }
        try Task.checkCancellation()
    }

    /// The drain wait (OFF only): slot release, never a phase change.
    private func bgPruneAwaitSlotReleased(_ job: BackgroundPruneJob, timeout: Double) async -> Bool {
        if job.released { return true }
        let waiterId = UUID()
        let jobId = job.id
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            self?.bgPruneResumeWaiter(jobId: jobId, waiterId: waiterId, drain: true)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if job.released { continuation.resume(); return }
            job.drainWaiters[waiterId] = continuation
        }
        timer.cancel()
        return job.released
    }

    // MARK: Apply (§8)

    /// §8.2: the whole frozen preimage must be an ordered, byte-identical
    /// prefix of the live history (one allow-listed field), source ⊆ live.
    private func bgPruneGuardFailure(_ job: BackgroundPruneJob) -> String? {
        let frozen = job.frozenPreimage
        guard messages.count >= frozen.count else { return "shrunk" }
        let liveIDs = messages.map(\.id)
        guard Set(liveIDs).count == liveIDs.count else { return "duplicate" }
        guard Array(liveIDs.prefix(frozen.count)) == frozen.map(\.id) else { return "order" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for index in frozen.indices {
            var live = messages[index]
            if let trigger = job.triggerMessageID, live.id == trigger { live.measuredTokens = frozen[index].measuredTokens }
            guard let liveBytes = try? encoder.encode(live), let frozenBytes = try? encoder.encode(frozen[index]),
                  liveBytes == frozenBytes else { return "bytes" }
        }
        guard Set(job.source.map(\.id)).isSubset(of: Set(liveIDs)) else { return "source" }
        return nil
    }

    /// An owned operation of the job (§8.3). Returns the outcome and the
    /// replacements (by id) the caller applies to its request view.
    private func bgPruneApply(_ job: BackgroundPruneJob, runId: UUID, liveRounds: [ToolInteraction]) async -> (outcome: BackgroundPruneApplyOutcome, replacements: [UUID: Message]) {
        guard backgroundPruneJob === job, job.workerTerminated, case .ready(let result) = job.phase else {
            return (.abandoned("not-ready"), [:])
        }
        let token = BackgroundPruneApplyToken(id: UUID(), ownerRunId: runId, activityId: beginMaintenance(.pruning))
        job.phase = .applying(token)
        var outcome = BackgroundPruneApplyOutcome.abandoned("unknown")
        var replacements: [UUID: Message] = [:]
        defer {
            endMaintenance(token.activityId)
            bgPruneApplyReturned(job, outcome: outcome)
        }
        func stillAuthorized() -> Bool {
            guard backgroundPruneJob === job, job.historyGeneration == backgroundPruneGeneration,
                  case .applying(let current) = job.phase, current == token, !job.revoked,
                  activeRunId == token.ownerRunId, !Task.isCancelled, !isRestoringMind else { return false }
            return true
        }
        func refusal() -> BackgroundPruneApplyOutcome {
            if job.revoked || job.historyGeneration != backgroundPruneGeneration { return .revoked }
            if Task.isCancelled || activeRunId != token.ownerRunId { return .cancelled }
            return .abandoned("unauthorized")
        }
        guard stillAuthorized() else { outcome = refusal(); return (outcome, [:]) }
        // 1. Guard.
        if let failure = bgPruneGuardFailure(job) { outcome = .abandoned("guard-\(failure)"); return (outcome, [:]) }
        // 2. Evidence gate again (synchronous, idempotent).
        let manifest = Set(job.manifestIDs)
        do { try settleJobEvidenceBeforeRemoval(of: job.source.filter { manifest.contains($0.id) }) }
        catch { outcome = .abandoned("evidence"); return (outcome, [:]) }
        // 3. Descriptions, per action in order, fallback map then generated
        //    map, fill-only, re-authorized around every store await.
        for action in result.descriptions {
            for map in [action.fallback, action.generated] where !map.isEmpty {
                guard stillAuthorized() else { outcome = refusal(); return (outcome, [:]) }
                await bgPruneHold("apply.lookup")
                var fill: [String: String] = [:]
                for name in map.keys.sorted() where await FileDescriptionService.shared.get(filename: name) == nil {
                    fill[name] = map[name]
                }
                guard stillAuthorized() else { outcome = refusal(); return (outcome, [:]) }
                guard !fill.isEmpty else { continue }
                // Submitted from here: a held save completes; nothing rolls back.
                job.savedDescriptionCount += fill.count
                await bgPruneHold("apply.save")
                await FileDescriptionService.shared.saveMultiple(fill)
            }
        }
        // 4. After the saves: authorization and guard again.
        guard stillAuthorized() else { outcome = refusal(); return (outcome, [:]) }
        if let failure = bgPruneGuardFailure(job) { outcome = .abandoned("guard-\(failure)"); return (outcome, [:]) }
        // 5–8. No await from here to the end of the tail.
        guard stillAuthorized() else { outcome = refusal(); return (outcome, [:]) }
        let plan = bgPrunePlan(job)
        let source = job.source
        let anchor = job.anchor
        var text: String? = nil
        if case .text(let summary) = result.summary { text = summary }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var stubReference: PruneArchiveReference?
        defer { PruneArchiveStore.release(stubReference) }
        var candidateView = source
        applyPrunePlan(plan, to: &candidateView)
        _ = pruneCompressibleUserMessages(upToIndex: job.safeBoundary, in: &candidateView)
        if plan.toolActionCount > 0 { pruneOldCompactToolLogs(in: &candidateView) }
        let hadSummary = PruneSummaryRetention.isFullAnchor(candidateView[anchor])
        let summaryParts = [candidateView[anchor].prunedContextSummary, text].compactMap { $0 }.filter { !$0.isEmpty }
        candidateView[anchor].prunedContextSummary = summaryParts.isEmpty ? nil : summaryParts.joined(separator: "\n\n")
        if !(text ?? "").isEmpty {
            let fresh = Self.coverageRecordingDisabledForTesting ? nil
                : PruneSummaryRetention.coverage(of: source, manifest: plan.affectedIndices + job.compressedIndices)
            candidateView[anchor].prunedContextSummaryCoverage = PruneSummaryRetention.merged(
                hadSummary: hadSummary, previous: candidateView[anchor].prunedContextSummaryCoverage, fresh: fresh)
        }
        candidateView[anchor].pruneArchiveReferences.append(job.snapshotRef)
        if let measured = candidateView[anchor].measuredTokens {
            candidateView[anchor].measuredTokens = measured + job.snapshotRef.promptText.count / 4
        }
        stubReference = prepareSummaryStubs(in: &candidateView, trigger: job.site.rawValue)
        Self.beforePruneHistoryWriteForTesting?()
        for (old, updated) in zip(source, candidateView) {
            guard let oldBytes = try? encoder.encode(old), let newBytes = try? encoder.encode(updated) else {
                outcome = .abandoned("encode"); return (outcome, [:])
            }
            if oldBytes != newBytes { replacements[updated.id] = updated }
        }
        // 6. Actual write set ⊆ dependency set (the whole frozen preimage).
        let dependency = Set(job.frozenPreimage.map(\.id))
        if !Set(replacements.keys).isSubset(of: dependency) || Self.bgPruneWriteSetViolationForTesting == true {
            bgPruneLog("bgprune.assert.write-set")
            outcome = .abandoned("write-set")
            return (outcome, [:])
        }
        var candidateLive = messages
        for i in candidateLive.indices {
            if let replacement = replacements[candidateLive[i].id] { candidateLive[i] = replacement }
        }
        // 7. Checked write; failure keeps live memory, runs no cleanup.
        do {
            try writeHistoryFile(try encoder.encode(candidateLive))
        } catch {
            backgroundPruneFallbackDue = true
            let failure = "Could not commit pruned conversation: \(error.localizedDescription). Live details and the snapshot remain; the disk file may contain the complete old or new state. No cleanup ran."
            showMaintenanceNotice(failure)
            bgPruneLog("bgprune.apply.write-failed", failure)
            outcome = .writeFailed
            return (outcome, [:])
        }
        // 8. Tail, synchronous.
        messages = candidateLive
        committedMessages = candidateLive
        var trackerPreimage = source
        applyPrunePlan(plan, to: &trackerPreimage, clearTrackers: true)
        cleanupOrphanedToolAttachmentSnapshots(additionalLiveInteractions: liveRounds)
        TruncationService.cleanupOldFiles()
        do { try PruneArchiveStore.retainLatest(protecting: Set([job.snapshotRef.id, stubReference?.id].compactMap { $0 })) }
        catch { showMaintenanceNotice("Snapshot retention: \(error.localizedDescription)") }
        job.committed = true
        outcome = .applied
        // 9. Manager-level token resets (§8.5). No notice: the prune was
        //    prepared in the background and is already applied (quiet
        //    background notices, 0.2.63, supersedes Q3). /status shows the
        //    job while it exists; an inline fallback keeps today's notice.
        //    The seam is a no-op in production (no suspension).
        lastPromptTokens = nil
        lastCompletionTokens = nil
        bgPruneLog("bgprune.applied", "\(replacements.count) message(s) rewritten")
        await bgPruneHold("apply.committed")
        return (outcome, replacements)
    }

    private func bgPruneApplyReturned(_ job: BackgroundPruneJob, outcome: BackgroundPruneApplyOutcome) {
        backgroundPruneLastApply = BackgroundPruneApplyRecord(jobId: job.id, outcome: outcome,
            savedDescriptions: job.savedDescriptionCount, committed: job.committed)
        switch outcome {
        case .applied: break
        case .revoked: bgPruneLog("bgprune.apply.revoked")
        case .cancelled:
            if backgroundPruneSwitchOn { backgroundPruneFallbackDue = true }
            bgPruneLog("bgprune.abandon.stopped")
        case .abandoned(let reason):
            backgroundPruneFallbackDue = true
            bgPruneLog("bgprune.abandon.\(reason)")
        case .writeFailed: break
        }
        job.phase = .retiring(.abandon)
        bgPruneReleaseSlot(job)
    }

    // MARK: Reduction step R (§7.7)

    /// One apply attempt, at most one deadline-bounded phase wait, at most
    /// one inline block per logical request. Never loops, never throws an
    /// admission error of its own; inline-block errors and cancellation
    /// propagate.
    private func bgPruneReduce(runId: UUID, requestKey: String, appliedAlready: Bool, execution: ProviderExecutionContext?,
                               need: (Int, Int, Int) -> Bool,
                               admitted: () async throws -> Int,
                               liveRounds: () -> [ToolInteraction],
                               afterApply: ([UUID: Message]) async throws -> Void,
                               inline: () async throws -> Bool) async throws -> BackgroundPruneReduction {
        var applied = appliedAlready
        var waited = false
        if !appliedAlready {
            step: while true {
                guard let job = backgroundPruneJob else { break step }
                if job.isReady {
                    let result = await bgPruneApply(job, runId: runId, liveRounds: liveRounds())
                    try Task.checkCancellation()
                    guard result.outcome == .applied else { break step }
                    applied = true
                    try await afterApply(result.replacements)
                    let estimate = try await admitted()
                    let identity = await bgPruneIdentity(execution)
                    let limits = bgPruneLimits(identity: identity.identity, model: identity.model)
                    if !need(estimate, limits.maximum, limits.ceiling) { return .applied }
                    break step
                }
                if job.isRunning, !waited {
                    waited = true
                    try await bgPruneAwaitPhaseSettled(job, runId: runId)
                    try Task.checkCancellation()
                    guard activeRunId == runId else { throw CancellationError() }
                    continue step
                }
                break step
            }
        }
        // Step 3: the inline fallback, once per logical request (shared
        // with the direct T1/M inline paths, Codex impl R2).
        guard bgPruneClaimInline(runId: runId, key: requestKey) else {
            return applied ? .applied : .noChange
        }
        backgroundPruneFallbackDue = false
        if let job = backgroundPruneJob, job.isRetiring { job.inlineDebtConsumed = true }
        lastPromptTokens = nil
        bgPruneLog("bgprune.inline", requestKey)
        let changed = try await inline()
        return .inlineHandled(changed: changed || applied)
    }

    /// The one inline allowance of a logical request (§7.7 step 3). Every
    /// ON inline path claims it: R's step 3 and the direct T1/M paths.
    private func bgPruneClaimInline(runId: UUID, key: String) -> Bool {
        let ledgerKey = "\(runId.uuidString)|\(key)"
        let used = backgroundPruneRequestLedger[ledgerKey, default: 0]
        guard used & 1 == 0 else {
            bgPruneLog("bgprune.admit.overceiling", key)
            return false
        }
        backgroundPruneRequestLedger[ledgerKey] = used | 1
        return true
    }

    /// The logical request a forced final belongs to: the request M
    /// prepared (§7.4: M is the boundary for whatever comes next; all final
    /// attempts are one logical request).
    func backgroundPruneFinalRequestKey(runId: UUID?) -> String {
        guard let runId, let next = backgroundPruneNextRound[runId.uuidString] else { return "final" }
        return "round\(next)"
    }

    // MARK: Boundaries (§7.1–7.2)

    /// T0: apply a ready job only (never consumes an owed decision).
    func backgroundPruneTurnStart(runId: UUID?) async {
        guard let runId else { return }
        backgroundPruneRequestLedger = backgroundPruneRequestLedger.filter { $0.key.hasPrefix(runId.uuidString) }
        backgroundPruneNextRound = [:]
        backgroundPruneT0AppliedRun = nil
        guard let job = backgroundPruneJob, job.isReady else { return }
        let result = await bgPruneApply(job, runId: runId, liveRounds: bgPruneCheckpointRounds())
        if result.outcome == .applied {
            lastPromptTokens = nil
            lastCompletionTokens = nil
            backgroundPruneT0AppliedRun = runId
            bgPruneLog("bgprune.t0.applied")
        }
    }

    /// T1: the pre-request decision. Returns whether the history changed
    /// (applied here or by today's inline statement), i.e. `didPrune`.
    func backgroundPrunePreRequest(runId: UUID?, inputs: BackgroundPruneSummaryInputs, execution: ProviderExecutionContext?,
                                   inline: () async throws -> Bool) async throws -> Bool {
        guard let runId else { return try await inline() }
        await bgPruneHold("t1.entry")
        backgroundPruneNextRound[runId.uuidString] = 1
        var did = false
        func estimate() async throws -> Int { try await bgPrunePreRequestEstimate(inputs).total }
        /// Today's pre-request statement, entered once per logical request
        /// (round 1). The entry is counted at the helper call itself.
        func helper() async throws -> Bool {
            bgPruneLog("bgprune.helper.pre-request")
            return try await inline()
        }
        func directInline(_ reason: String) async throws -> Bool {
            guard bgPruneClaimInline(runId: runId, key: "round1") else { return false }
            bgPruneLog("bgprune.inline.direct", "round1: \(reason)")
            return try await helper()
        }
        // 1. A ready job (became ready between T0 and T1).
        if let job = backgroundPruneJob, job.isReady {
            let result = await bgPruneApply(job, runId: runId, liveRounds: bgPruneCheckpointRounds())
            try Task.checkCancellation()
            if result.outcome == .applied {
                did = true
                let fresh = try await estimate()
                let identity = await bgPruneIdentity(execution)
                let limits = bgPruneLimits(identity: identity.identity, model: identity.model)
                if fresh >= limits.ceiling {
                    let reduction = try await bgPruneReduce(runId: runId, requestKey: "round1", appliedAlready: true,
                        execution: execution, need: { $0 >= $2 }, admitted: estimate, liveRounds: bgPruneCheckpointRounds,
                        afterApply: { _ in }, inline: helper)
                    return did || reduction.changed
                }
            }
        }
        // 3. Today's estimate, after any apply.
        let capture = bgPruneCapture(runId: runId, source: messages)
        let current = try await bgPrunePreRequestEstimate(inputs)
        let maximum = configuredMaxContextTokens()
        // 4. Not over the maximum → done.
        guard current.total > maximum else { return did }
        // OFF completed during the awaits (Codex impl R1): today's
        // statement, which re-estimates itself, as the OFF branch would.
        guard backgroundPruneEngaged else { return try await helper() || did }
        // 5. Over the maximum.
        guard current.prunable else { return try await directInline("nothing prunable") || did }
        if backgroundPruneFallbackDue {
            backgroundPruneFallbackDue = false
            bgPruneLog("bgprune.owed-inline", "pre-request")
            return try await directInline("owed") || did
        }
        if let job = backgroundPruneJob {
            if job.isRunning {
                let identity = await bgPruneIdentity(execution)
                let limits = bgPruneLimits(identity: identity.identity, model: identity.model)
                guard current.total >= limits.ceiling else { return did }
                let reduction = try await bgPruneReduce(runId: runId, requestKey: "round1", appliedAlready: false,
                    execution: execution, need: { $0 >= $2 }, admitted: estimate, liveRounds: bgPruneCheckpointRounds,
                    afterApply: { _ in }, inline: helper)
                return did || reduction.changed
            }
            if job.isRetiring { job.inlineDebtConsumed = true }
            bgPruneLog("bgprune.inline.unusable", job.phase.name)
            return try await directInline("unusable job") || did
        }
        guard backgroundPruneSwitchOn else { return try await directInline("switch off") || did }
        if try await bgPruneFreeze(site: .preRequest, capture: capture, totalTokens: current.total, liveSource: { messages },
                                   currentRounds: [], inputs: inputs, execution: execution) {
            return did
        }
        return try await directInline("ineligible") || did
    }

    /// M: the mid-loop decision. `block(nil)` runs today's mid-loop block
    /// (prune call and its result handling, with compaction); `block(r)`
    /// runs only today's result handling for an applied prune (§7.2 step 6).
    func backgroundPruneMidLoop(runId: UUID?, nextRound: Int, inputs: BackgroundPruneSummaryInputs,
                                execution: ProviderExecutionContext?,
                                history: () -> [Message], rounds: [ToolInteraction],
                                replace: ([UUID: Message]) -> Void,
                                block: (MidLoopPruneResult?) async throws -> Bool) async throws {
        guard let runId else { _ = try await block(nil); return }
        backgroundPruneNextRound[runId.uuidString] = nextRound
        let nextRequestKey = "round\(nextRound)"
        func estimate() async throws -> (total: Int, prunable: Bool) {
            try await bgPruneMidLoopEstimate(history: history(), rounds: rounds, inputs: inputs)
        }
        func directInline(_ reason: String) async throws {
            guard bgPruneClaimInline(runId: runId, key: nextRequestKey) else { return }
            bgPruneLog("bgprune.inline.direct", "\(nextRequestKey): \(reason)")
            _ = try await block(nil)
        }
        func handleApplied() async throws {
            let fresh = try await estimate()
            _ = try await block(fresh.total > configuredMaxContextTokens() ? .exhausted : .pruned)
        }
        // 1. A ready job: applied regardless of the current estimate.
        if let job = backgroundPruneJob, job.isReady {
            let result = await bgPruneApply(job, runId: runId, liveRounds: rounds)
            try Task.checkCancellation()
            if result.outcome == .applied {
                replace(result.replacements)
                let fresh = try await estimate()
                let identity = await bgPruneIdentity(execution)
                let limits = bgPruneLimits(identity: identity.identity, model: identity.model)
                if fresh.total >= limits.ceiling {
                    let reduction = try await bgPruneReduce(runId: runId, requestKey: nextRequestKey, appliedAlready: true,
                        execution: execution, need: { $0 >= $2 }, admitted: { try await estimate().total },
                        liveRounds: { rounds }, afterApply: replace, inline: { try await block(nil) })
                    if case .inlineHandled = reduction { return }
                }
                try await handleApplied()
                return
            }
        }
        // 3. Today's estimate, after any apply.
        let capture = bgPruneCapture(runId: runId, source: history())
        let current = try await estimate()
        let maximum = configuredMaxContextTokens()
        guard current.total > maximum else { return }
        // OFF completed during the awaits (Codex impl R1): today's block.
        guard backgroundPruneEngaged else { _ = try await block(nil); return }
        guard current.prunable else { try await directInline("nothing prunable"); return }
        if backgroundPruneFallbackDue {
            backgroundPruneFallbackDue = false
            bgPruneLog("bgprune.owed-inline", "mid-loop")
            try await directInline("owed")
            return
        }
        if let job = backgroundPruneJob {
            if job.isRunning {
                let identity = await bgPruneIdentity(execution)
                let limits = bgPruneLimits(identity: identity.identity, model: identity.model)
                guard current.total >= limits.ceiling else { return }
                let reduction = try await bgPruneReduce(runId: runId, requestKey: nextRequestKey, appliedAlready: false,
                    execution: execution, need: { $0 >= $2 }, admitted: { try await estimate().total },
                    liveRounds: { rounds }, afterApply: replace, inline: { try await block(nil) })
                if case .applied = reduction { try await handleApplied() }
                return
            }
            if job.isRetiring { job.inlineDebtConsumed = true }
            bgPruneLog("bgprune.inline.unusable", job.phase.name)
            try await directInline("unusable job")
            return
        }
        guard backgroundPruneSwitchOn else { try await directInline("switch off"); return }
        if try await bgPruneFreeze(site: .midLoop, capture: capture, totalTokens: current.total, liveSource: history,
                                   currentRounds: rounds, inputs: inputs, execution: execution) {
            return
        }
        try await directInline("ineligible")
    }

    /// D: pre-dispatch admission (tool loop and every forced-final
    /// attempt). Does nothing without a job; never starts one.
    func backgroundPruneAdmit(runId: UUID?, requestKey: String, execution: ProviderExecutionContext?,
                              admitted: () async throws -> Int, liveRounds: () -> [ToolInteraction],
                              afterApply: ([UUID: Message]) async throws -> Void,
                              inline: () async throws -> Bool) async throws -> BackgroundPruneReduction {
        guard let runId, backgroundPruneJob != nil else { return .noChange }
        await bgPruneHold("admit.\(requestKey)")
        let estimate = try await admitted()
        let identity = await bgPruneIdentity(execution)
        // D never acts without a job; one may have been released (OFF,
        // termination) during the awaits (Codex impl R1).
        guard backgroundPruneJob != nil else { return .noChange }
        let limits = bgPruneLimits(identity: identity.identity, model: identity.model)
        Self.bgPruneDetailForTesting?("admit.estimate", "\(requestKey) \(estimate) \(limits.ceiling)")
        guard estimate >= limits.ceiling else { return .noChange }
        bgPruneLog("bgprune.admit.reduce", "\(requestKey): ~\(estimate) ≥ \(limits.ceiling)")
        return try await bgPruneReduce(runId: runId, requestKey: requestKey, appliedAlready: false, execution: execution,
            need: { $0 >= $2 }, admitted: admitted, liveRounds: liveRounds, afterApply: afterApply, inline: inline)
    }

    /// §10: one best-effort reduction and resend for a request admitted
    /// above the configured maximum that failed with an eligible error.
    func backgroundPruneConverge(runId: UUID?, requestKey: String, admittedEstimate: Int, admittedMaximum: Int,
                                 execution: ProviderExecutionContext?,
                                 send: () async throws -> LLMResponse,
                                 admitted: () async throws -> Int, liveRounds: () -> [ToolInteraction],
                                 afterApply: ([UUID: Message]) async throws -> Void,
                                 inline: () async throws -> Bool,
                                 resend: () async throws -> LLMResponse) async throws -> LLMResponse {
        do {
            return try await send()
        } catch {
            try Task.checkCancellation()
            guard let runId, admittedEstimate > admittedMaximum, !(error is CancellationError),
                  BackgroundPruneErrors.isEligibleInBand(error) else { throw error }
            // A completed OFF during the send await ends all ON work: the
            // original error surfaces exactly as OFF (Codex impl R1).
            guard backgroundPruneEngaged else {
                bgPruneLog("bgprune.converge.disengaged", requestKey)
                throw error
            }
            let ledgerKey = "\(runId.uuidString)|\(requestKey)"
            let used = backgroundPruneRequestLedger[ledgerKey, default: 0]
            guard used & 2 == 0 else { throw error }
            backgroundPruneRequestLedger[ledgerKey] = used | 2
            bgPruneLog("bgprune.converge.reduce", "\(requestKey): \(error.localizedDescription)")
            let reduction = try await bgPruneReduce(runId: runId, requestKey: requestKey, appliedAlready: false,
                execution: execution, need: { estimate, maximum, _ in estimate > maximum }, admitted: admitted,
                liveRounds: liveRounds, afterApply: afterApply, inline: inline)
            try Task.checkCancellation()
            guard reduction.changed else {
                bgPruneLog("bgprune.converge.no-change", requestKey)
                throw error
            }
            guard backgroundPruneEngaged else {
                bgPruneLog("bgprune.converge.disengaged", requestKey)
                throw error
            }
            print("[BackgroundPrune] resending after reduction; first error: \(error.localizedDescription)")
            let response = try await resend()
            // A successful resend is returned as is; a completed OFF during
            // the resend (or the identity lookup) skips the ON bookkeeping
            // (Codex impl round 2, R2-2).
            guard backgroundPruneEngaged else {
                bgPruneLog("bgprune.converge.resent-disengaged", requestKey)
                return response
            }
            let identity = await bgPruneIdentity(execution)
            guard backgroundPruneEngaged else {
                bgPruneLog("bgprune.converge.resent-disengaged", requestKey)
                return response
            }
            let bound = Int(Double(admittedEstimate) * 0.9)
            backgroundPruneObservedBounds[identity.identity] = min(backgroundPruneObservedBounds[identity.identity] ?? Int.max, bound)
            bgPruneLog("bgprune.converge.resent", requestKey)
            return response
        }
    }

    /// Today's mid-loop block (9033–9071) statement-for-statement, shared by
    /// the ON paths that must run it (M, D, §10). `precomputed` skips the
    /// prune call and runs only the result handling of an applied prune.
    /// Returns whether history or the active-turn checkpoint changed.
    func backgroundPruneMidLoopBlock(precomputed: MidLoopPruneResult?, compact: Bool,
                                     messagesForLLM: inout [Message], rounds: [ToolInteraction],
                                     calendarContext: inout String, emailContext: inout String,
                                     chunkSummaries: [ArchivedSummaryItem], totalChunkCount: Int,
                                     currentUserMessageId: UUID, systemPromptDate: Date,
                                     tools: [ToolDefinition], deferredSummaries: [(name: String, description: String, toolCount: Int)],
                                     execution: ProviderExecutionContext?, persona: PromptPersona, salvageRunId: UUID?,
                                     ledgerDiff: () async -> FilesLedgerDiff.Changed,
                                     prevRoundPromptTokens: inout Int?, previousPromptScope: inout String?,
                                     cumulativeToolSpendUSD: inout Double, todaySpentUSD: inout Double,
                                     monthSpentUSD: inout Double) async throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try? encoder.encode(messagesForLLM)
        let generationBefore = salvageRunId.flatMap { activeTurnCheckpoints[$0]?.generation }
        let midLoopResult: MidLoopPruneResult
        if let precomputed {
            bgPruneLog("bgprune.handling.applied")
            midLoopResult = precomputed
        } else {
            bgPruneLog("bgprune.helper.mid-loop")
            midLoopResult = try await pruneStoredToolInteractionsMidLoop(
                messagesForLLM: &messagesForLLM,
                currentTurnInteractions: rounds,
                calendarContext: calendarContext,
                emailContext: emailContext,
                chunkSummaries: chunkSummaries,
                totalChunkCount: totalChunkCount,
                currentUserMessageId: currentUserMessageId,
                turnStartDate: systemPromptDate,
                tools: tools,
                deferredMCPSummaries: deferredSummaries, execution: execution,
                persona: persona
            )
        }
        if midLoopResult != .underBudget {
            prevRoundPromptTokens = nil; lastPromptTokens = nil; previousPromptScope = nil
        }
        if midLoopResult == .pruned {
            CacheDiagnostics.noteTransition("prune", lane: .main)
            let refreshed = await getFrozenSystemContext(forceRefresh: true)
            calendarContext = refreshed.calendar
            emailContext = refreshed.email
        }
        if midLoopResult == .exhausted && compact && !rounds.isEmpty {
            guard let runID = salvageRunId else { throw PruneArchiveStore.Failure("No active-turn checkpoint owner") }
            let compactionFiles = await ledgerDiff()
            activeTurnCheckpoints[runID]?.editedFilePaths = compactionFiles.edited
            activeTurnCheckpoints[runID]?.generatedFilePaths = compactionFiles.generated
            let priorMaintenanceSpend = activeTurnCheckpoints[runID]?.maintenanceSpendUSD ?? 0
            try await compactActiveTurn(runID: runID, history: messagesForLLM,
                tools: tools, calendar: calendarContext, email: emailContext,
                summaries: chunkSummaries, totalChunks: totalChunkCount, date: systemPromptDate,
                deferred: deferredSummaries, execution: execution, persona: persona)
            CacheDiagnostics.noteTransition("compaction", lane: .main)
            let maintenanceSpend = max(0, (activeTurnCheckpoints[runID]?.maintenanceSpendUSD ?? 0) - priorMaintenanceSpend)
            cumulativeToolSpendUSD += maintenanceSpend; todaySpentUSD += maintenanceSpend; monthSpentUSD += maintenanceSpend
            prevRoundPromptTokens = nil; lastPromptTokens = nil; previousPromptScope = nil
        }
        let after = try? encoder.encode(messagesForLLM)
        let generationAfter = salvageRunId.flatMap { activeTurnCheckpoints[$0]?.generation }
        return precomputed != nil || before != after || generationBefore != generationAfter
    }

    /// Estimate of a forced-final attempt (§7.3): history, rounds plus the
    /// refusal suffix, tools, deferred summaries and this attempt's tail.
    func backgroundPruneFinalEstimate(history: [Message], rounds: [ToolInteraction], tools: [ToolDefinition],
                                      calendar: String, email: String, summaries: [ArchivedSummaryItem], totalChunks: Int,
                                      date: Date, deferred: [(name: String, description: String, toolCount: Int)],
                                      persona: PromptPersona, tail: String) async throws -> Int {
        let estimate = try await openRouterService.activeTurnRequestEstimate(messages: history, rounds: rounds,
            images: imagesDirectory, documents: documentsDirectory, tools: tools,
            calendar: calendar, email: email, summaries: summaries,
            totalChunks: totalChunks, date: date, deferred: deferred, persona: persona)
        return BackgroundPruneCeiling.saturatingAdd(estimate.tokens, ActiveTurnBudget.text(tail))
    }

    /// The live request projection of the active turn (the 8616 expression),
    /// composed with the request's /keepsummaries limit.
    func backgroundPruneProjection(_ history: [Message], runId: UUID?, limit: KeepSummariesLimit) throws -> ComposedHistory {
        try requestView(history, runId: runId, limit: limit)
    }

    /// One model request's view (KEEP_SUMMARIES_PLAN §4.2): the active-turn
    /// projection, then summary composition. Its estimate and its send use
    /// this same value; nothing ever writes it back.
    func requestView(_ history: [Message], runId: UUID?, limit: KeepSummariesLimit) throws -> ComposedHistory {
        let projected = try activeTurnCheckpoints[runId ?? UUID()]?.projectedHistory(history, canonical: messages) ?? history
        let view = PruneSummaryRetention.compose(projected, limit: limit)
        Self.requestViewObserverForTesting?(view)
        return view
    }

    /// §4.4: the cached measurement, only under the composition that produced it.
    func promptMeasurement(for view: ComposedHistory) -> Int? {
        guard let tokens = lastPromptTokens, lastPromptRenderKey == view.renderKey else { return nil }
        return tokens
    }

    func backgroundPruneRequestEstimate(projected: [Message], rounds: [ToolInteraction], tools: [ToolDefinition],
                                        calendar: String, email: String, summaries: [ArchivedSummaryItem], totalChunks: Int,
                                        date: Date, deferred: [(name: String, description: String, toolCount: Int)],
                                        persona: PromptPersona) async throws -> Int {
        try await openRouterService.activeTurnRequestEstimate(messages: projected, rounds: rounds,
            images: imagesDirectory, documents: documentsDirectory, tools: tools,
            calendar: calendar, email: email, summaries: summaries,
            totalChunks: totalChunks, date: date, deferred: deferred, persona: persona).tokens
    }

    func backgroundPruneMaximum() -> Int { configuredMaxContextTokens() }

    // MARK: Summary worker entry (§6.1)

    /// An ON-only copy of `generatePrunedContextSummary` with exactly three
    /// differences: the execution frozen at the freeze is passed to every
    /// attempt (Chat included), the tool list follows that execution's
    /// protocol (same values), and cancellation is `.cancelled`, never the
    /// fallback. The oversized-newest-turn branch is absent (excluded by
    /// eligibility).
    private func backgroundPruneSummary(plan: PrunePlan, compressedIndices: [Int], sourceMessages: [Message],
                                inputs: BackgroundPruneSummaryInputs) async -> BackgroundPruneSummaryOutcome {
        guard !plan.isEmpty || !compressedIndices.isEmpty else { return .text(nil) }
        guard let selected = inputs.execution else { return .cancelled }
        let currentTurnInteractions = inputs.currentTurnInteractions
        let tools = inputs.tools
        let calendarContext = inputs.calendarContext
        let emailContext = inputs.emailContext
        let chunkSummaries = inputs.chunkSummaries
        let totalChunkCount = inputs.totalChunkCount
        let currentUserMessageId = inputs.currentUserMessageId
        let turnStartDate = inputs.turnStartDate
        let deferredMCPSummaries = inputs.deferredMCPSummaries
        let persona = inputs.persona
        // /keepsummaries: one composition (read once here) for every attempt;
        // the canonical source still drives the manifest and the fallback.
        let requestMessages = PruneSummaryRetention.compose(sourceMessages, limit: KeepSummariesSetting.current()).messages

        let manifest = pruneSummaryManifest(plan: plan, compressedIndices: compressedIndices, sourceMessages: sourceMessages)
        guard !manifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .text(nil) }

        let tail = """
        [PRUNE SUMMARY REQUEST - system maintenance]
        Tool use is disabled for this maintenance pass. Do NOT call tools. Do not emit tool calls. Return plain text only.
        The manifest below identifies the exact earlier turn content that is about to be pruned. The actual content is already present in the conversation above; do not expect it to be repeated here.
        Summarize ONLY the identified soon-to-be-pruned parts of the conversation above:
        - tool calls, tool outputs, and assistant reasoning for listed tool-interaction turns
        - media/file relevance for listed media turns
        - useful facts from listed synthetic message bodies
        Do not summarize unlisted turns or stable visible chat text that is not being pruned.
        Keep durable details: user goals, decisions, findings, errors, commands, file paths, filenames, IDs, URLs, tool outcomes, and unresolved next steps. This summary's purpose is to let you continue to work without missing important information once this content is pruned. View it as a baton exchange to a future version of you that will not see this pruned content.
        For each file created or edited in the pruned turns: state what changed and the most recent verification outcome for that change (build/test for code; audit/preview for documents). If a change was never verified, say so explicitly.
        For research or web lookups in the pruned turns: keep each key finding paired with the source URL that supports it, so work can continue without re-fetching sources.
        Quote error messages, exact identifiers, commit SHAs, and other precise strings verbatim - do not paraphrase text you may need to match or reuse later.
        Omit routine noise, duplicated logs, and low-value progress chatter.
        Length: up to ~1000 words for small prunes, up to ~2000 words when many turns are being pruned. Allocate words by usefulness to your future self, NOT by chronology or turn count: unresolved and recent work deserves the most detail; early exploration that was later superseded gets one line or nothing; dead ends only their conclusion. Chronological order is a fine default for the narrative, but it must not imply equal coverage per turn.
        This is internal memory, not a user-facing reply.

        PRUNE MANIFEST:
        \(manifest)
        [END PRUNE SUMMARY REQUEST]
        """

        let isResponses = selected.wireProtocol == .responses
        let summaryExecution = isResponses ? selected.forOperation(.pruneSummary) : selected
        defer { if isResponses { summaryExecution.responsesTurn.close() } }
        let summaryStart = Date()
        DebugTelemetry.log(
            .info,
            summary: "prune summary started",
            detail: manifest
        )
        func isCancellation(_ error: Error) -> Bool {
            Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
        }

        func recordPruneSummarySpend(_ spend: Double?) {
            guard let spend, spend.isFinite, spend > 0 else { return }
            KeychainHelper.recordOpenRouterSpend(spend)
        }
        var rejection: CompactionSummaryPolicy.Rejection?
        var rejectedAttempts = 0
        func acceptPruneText(_ content: String, _ finish: String?, _ label: String) -> String? {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if CompactionSummaryPolicy.isCutOff(finish) {
                rejection = .truncated("finish_reason: \(finish!)")
            } else if trimmed.isEmpty {
                rejection = .empty
            } else {
                return String(trimmed.prefix(14000))
            }
            rejectedAttempts += 1
            print("[ConversationManager] Prune summary \(label) rejected (\(rejectedAttempts)/\(CompactionSummaryPolicy.attempts)): \(rejection!.reason)")
            return nil
        }
        func rejectThrownReply(_ error: Error, _ label: String) -> Bool {
            guard let reason = CompactionSummaryPolicy.rejection(for: error) else { return false }
            recordPruneSummarySpend(CompactionSummaryPolicy.spend(for: error))
            rejection = reason
            rejectedAttempts += 1
            print("[ConversationManager] Prune summary \(label) rejected (\(rejectedAttempts)/\(CompactionSummaryPolicy.attempts)): \(reason.reason)")
            return true
        }
        func rejectedFallback() -> BackgroundPruneSummaryOutcome {
            let reason = rejection?.reason ?? "no usable reply"
            print("[ConversationManager] Prune summary rejected after \(CompactionSummaryPolicy.attempts) attempts (\(reason)); falling back to compact log summary")
            DebugTelemetry.log(
                .info,
                summary: "prune summary fallback: reply rejected",
                detail: "Prune summary rejected after \(CompactionSummaryPolicy.attempts) attempts: \(reason)",
                durationMs: Int(Date().timeIntervalSince(summaryStart) * 1000),
                isError: true
            )
            return .text(fallbackPrunedContextSummary(plan: plan, compressedIndices: compressedIndices, sourceMessages: sourceMessages))
        }
        do {
            while rejectedAttempts < CompactionSummaryPolicy.attempts {
                let attempt = rejectedAttempts + 1
                let response: LLMResponse
                if Task.isCancelled { return .cancelled }
                do {
                    response = try await openRouterService.generateResponse(
                        messages: requestMessages,
                        imagesDirectory: imagesDirectory,
                        documentsDirectory: documentsDirectory,
                        tools: isResponses ? [] : tools,
                        toolResultMessages: currentTurnInteractions,
                        calendarContext: calendarContext,
                        emailContext: emailContext,
                        chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
                        totalChunkCount: totalChunkCount,
                        currentUserMessageId: currentUserMessageId,
                        turnStartDate: turnStartDate,
                        tailUserMessage: tail,
                        deferredMCPSummaries: deferredMCPSummaries.isEmpty ? nil : deferredMCPSummaries,
                        execution: summaryExecution, lane: .main, persona: persona
                    )
                } catch {
                    if isCancellation(error) { return .cancelled }
                    guard rejectThrownReply(error, "attempt \(attempt)") else { throw error }
                    continue
                }
                recordPruneSummarySpend(spendUSD(from: response))
                switch response {
                case .text(let content, _, _, _, _, _, _, let finish):
                    if let summary = acceptPruneText(content, finish, "attempt \(attempt)") {
                        DebugTelemetry.log(
                            .info,
                            summary: "prune summary completed",
                            detail: "chars: \(summary.count), attempt: \(attempt)",
                            durationMs: Int(Date().timeIntervalSince(summaryStart) * 1000)
                        )
                        return .text(summary)
                    }
                    continue
                case .toolCalls(let assistantMessage, let calls, _, _, _):
                    var retryInteractions = (currentTurnInteractions ?? []) + [
                        disabledMaintenanceToolInteraction(
                            assistantMessage: assistantMessage,
                            calls: calls,
                            reason: "Tool calls are disabled during the prune-summary maintenance pass. This tool was not executed. Return the requested prune summary as plain text only."
                        )
                    ]

                    for attempt in 1...4 {
                        guard rejectedAttempts < CompactionSummaryPolicy.attempts else { break }
                        let retryTail = """
                        [PRUNE SUMMARY RETRY \(attempt)/4 - system maintenance]
                        The tool call(s) you requested were not executed because this is an internal pruning summary pass.
                        Tool use remains disabled for this maintenance pass. Return plain text only.
                        Produce the requested prune summary now, using only the conversation context already present above and the prune manifest.
                        [END PRUNE SUMMARY RETRY]
                        """
                        if Task.isCancelled { return .cancelled }
                        do {
                            let retryResponse = try await openRouterService.generateResponse(
                                messages: requestMessages,
                                imagesDirectory: imagesDirectory,
                                documentsDirectory: documentsDirectory,
                                tools: isResponses ? [] : tools,
                                toolResultMessages: retryInteractions,
                                calendarContext: calendarContext,
                                emailContext: emailContext,
                                chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
                                totalChunkCount: totalChunkCount,
                                currentUserMessageId: currentUserMessageId,
                                turnStartDate: turnStartDate,
                                tailUserMessage: retryTail,
                                deferredMCPSummaries: deferredMCPSummaries.isEmpty ? nil : deferredMCPSummaries,
                                execution: summaryExecution, lane: .main, persona: persona
                            )
                            recordPruneSummarySpend(spendUSD(from: retryResponse))
                            switch retryResponse {
                            case .text(let content, _, _, _, _, _, _, let finish):
                                guard let summary = acceptPruneText(content, finish, "retry \(attempt) after tool refusal") else { continue }
                                DebugTelemetry.log(
                                    .info,
                                    summary: "prune summary completed after tool refusal",
                                    detail: "attempt: \(attempt), chars: \(summary.count)",
                                    durationMs: Int(Date().timeIntervalSince(summaryStart) * 1000)
                                )
                                return .text(summary)
                            case .toolCalls(let retryAssistant, let retryCalls, _, _, _):
                                retryInteractions.append(
                                    disabledMaintenanceToolInteraction(
                                        assistantMessage: retryAssistant,
                                        calls: retryCalls,
                                        reason: "Tool calls are disabled during the prune-summary maintenance pass. This tool was not executed. Return the requested prune summary as plain text only."
                                    )
                                )
                            }
                        } catch {
                            if isCancellation(error) { return .cancelled }
                            if !rejectThrownReply(error, "retry \(attempt) after tool refusal") {
                                print("[ConversationManager] Prune summary retry \(attempt) failed after refusing tool calls: \(error)")
                            }
                        }
                    }

                    if rejectedAttempts >= CompactionSummaryPolicy.attempts { return rejectedFallback() }
                    print("[ConversationManager] Prune summary request kept returning tool calls after retries; falling back to compact log summary")
                    DebugTelemetry.log(
                        .info,
                        summary: "prune summary fallback: model returned tool calls",
                        detail: manifest,
                        durationMs: Int(Date().timeIntervalSince(summaryStart) * 1000),
                        isError: true
                    )
                    return .text(fallbackPrunedContextSummary(plan: plan, compressedIndices: compressedIndices, sourceMessages: sourceMessages))
                }
            }
            return rejectedFallback()
        } catch {
            if isCancellation(error) { return .cancelled }
            print("[ConversationManager] Failed to generate prune summary: \(error)")
            DebugTelemetry.log(
                .info,
                summary: "prune summary fallback: request failed",
                detail: "\(error)",
                durationMs: Int(Date().timeIntervalSince(summaryStart) * 1000),
                isError: true
            )
            return .text(fallbackPrunedContextSummary(plan: plan, compressedIndices: compressedIndices, sourceMessages: sourceMessages))
        }
    }

    // MARK: Descriptions worker entry (§6.2, write-free with overlay)

    func backgroundPruneDescriptions(actions: [BackgroundPrunePlanAction], source: [Message]) async -> [BackgroundPruneActionDescriptions] {
        var overlay: [String: String] = [:]
        var results: [BackgroundPruneActionDescriptions] = []
        for action in actions {
            var record = BackgroundPruneActionDescriptions()
            defer { results.append(record) }
            if Task.isCancelled { break }
            guard source.indices.contains(action.index) else { continue }
            let message = source[action.index]
            var files: [(filename: String, data: Data, mimeType: String)] = []
            if !action.isTool { files.append(contentsOf: collectInlineMediaFilesForDescription(from: message)) }
            if action.isTool { files.append(contentsOf: collectToolAttachmentFilesForDescription(from: message)) }
            var seen = Set<String>()
            var filtered: [(filename: String, data: Data, mimeType: String)] = []
            for file in files {
                guard seen.insert(file.filename).inserted, overlay[file.filename] == nil else { continue }
                if await FileDescriptionService.shared.get(filename: file.filename) == nil { filtered.append(file) }
            }
            files = filtered
            guard !files.isEmpty else { continue }
            var cappedFiles: [(filename: String, data: Data, mimeType: String)] = []
            var fallbackDescriptions: [String: String] = [:]
            for file in files {
                if file.data.count > Self.descriptionMaxFileSizeBytes {
                    fallbackDescriptions[file.filename] = "Large file (\(file.data.count / 1024)KB)"
                    print("[ConversationManager] Skipping \(file.filename) for description: \(file.data.count) bytes exceeds \(Self.descriptionMaxFileSizeBytes) limit")
                    continue
                }
                if file.mimeType.lowercased() == "application/pdf",
                   let doc = AdaPDF(data: file.data),
                   doc.pageCount > Self.descriptionMaxPDFPages {
                    if let slicedData = doc.sliceData(pages: 1...Self.descriptionMaxPDFPages) {
                        cappedFiles.append((filename: file.filename, data: slicedData, mimeType: file.mimeType))
                        print("[ConversationManager] Capped \(file.filename) from \(doc.pageCount) to \(Self.descriptionMaxPDFPages) pages for description")
                    } else {
                        fallbackDescriptions[file.filename] = "PDF document (\(doc.pageCount) pages)"
                    }
                } else {
                    cappedFiles.append(file)
                }
            }
            if cappedFiles.count > Self.descriptionMaxFiles {
                for file in cappedFiles[Self.descriptionMaxFiles...] {
                    fallbackDescriptions[file.filename] = "File skipped (batch limit of \(Self.descriptionMaxFiles) reached)"
                }
                cappedFiles = Array(cappedFiles.prefix(Self.descriptionMaxFiles))
            }
            if !fallbackDescriptions.isEmpty {
                record.fallback = fallbackDescriptions
                overlay.merge(fallbackDescriptions) { current, _ in current }
            }
            guard !cappedFiles.isEmpty else { continue }
            let context = descriptionContextMessages(forMessageAt: action.index, in: source, previousLimit: 8)
            if Task.isCancelled { break }
            do {
                let descriptions = try await openRouterService.generateFileDescriptions(
                    files: cappedFiles,
                    conversationContext: context
                )
                record.generated = descriptions
                overlay.merge(descriptions) { current, _ in current }
            } catch {
                print("[ConversationManager] Failed to generate prune-time file descriptions: \(error)")
            }
        }
        return results
    }

    // MARK: Commands, status, lifecycle (§12–13)

    func backgroundPruneCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let enabled = backgroundPruneSwitchOn
        let normalized = argument.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            try? await sendText("""
                Background pruning: \(enabled ? "ON" : "OFF") (default: off).
                Off: when the context reaches its maximum, I stop, summarize and prune old tool output, then continue (today's behaviour).
                On: the summary is prepared in the background while I keep working with the unchanged conversation; it is applied at the next step. If the context reaches the ceiling (maximum + 100k tokens) before it is ready, I wait for it. Model context windows are not known yet, so the ceiling is not lowered for smaller models: if a request is rejected as too long, I prune at once and resend it once. Requests between the maximum and the ceiling carry more input and can cost more (some providers charge a long-context premium). Turning it off cancels a summary being prepared.
                Only enable with a model whose context window is at least threshold + 100k (350k by default).
                Switch with /prunebackground on or /prunebackground off.
                """)
            return
        }
        guard normalized == "on" || normalized == "off" else {
            try? await sendText("Usage: /prunebackground on|off (currently \(enabled ? "on" : "off")).")
            return
        }
        let target = normalized == "on"
        guard target != enabled else {
            try? await sendText("Background pruning is already \(target ? "ON" : "OFF").")
            return
        }
        switchDefaults.set(target, forKey: Self.backgroundPruneDefaultsKey)
        if target {
            bgPruneLog("bgprune.switch.on")
            let draining = backgroundPruneJob != nil ? " A prune from before is still being cancelled; the next one starts after it has stopped." : ""
            try? await sendText("✅ Background pruning: ON — from the next time the context reaches its maximum.\(draining)")
            return
        }
        bgPruneLog("bgprune.switch.off")
        backgroundPrunePendingOff = true
        guard let job = backgroundPruneJob else {
            backgroundPrunePendingOff = false
            backgroundPruneFallbackDue = false
            bgPruneLog("bgprune.off.completed")
            try? await sendText("Background pruning: OFF.")
            return
        }
        let phaseAtOff = job.phase.name
        if job.isReady {
            job.phase = .retiring(.off)
            bgPruneReleaseSlot(job)
            try? await sendText("Background pruning: OFF. The prepared prune was discarded; no prune was applied.")
            return
        }
        if job.isRunning {
            job.phase = .retiring(.off)
            job.worker?.cancel()
            bgPruneResumePhaseWaiters(job)
        } else if job.isApplying {
            job.revoked = true
        }
        let released = await bgPruneAwaitSlotReleased(job, timeout: Self.bgPruneDrainSecondsForTesting ?? 5)
        var reply = "Background pruning: OFF."
        if phaseAtOff == "applying" {
            if let record = backgroundPruneLastApply, record.jobId == job.id {
                if record.committed {
                    reply += " The prune that was being applied finished first."
                } else {
                    reply += " The prune being applied was stopped before it changed the conversation"
                    let n = record.savedDescriptions
                    reply += n > 0 ? ", \(n) file description\(n == 1 ? "" : "s") it had already saved \(n == 1 ? "is" : "are") kept." : "."
                }
            } else {
                reply += " Cancelling the prune being applied — it is still finishing; it will not change the conversation. Memory commands wait until it has stopped."
            }
        } else if released {
            reply += " The summary being prepared was cancelled; no prune was applied."
        } else {
            reply += " Cancelling the summary being prepared — it is still finishing; no prune from it will be applied. Memory commands wait until it has stopped."
        }
        try? await sendText(reply)
    }

    func backgroundPruneStatusLine(now: Date = Date()) -> String {
        var line = "✂️ Background pruning: " + (backgroundPruneSwitchOn ? "on" : "off")
        guard let job = backgroundPruneJob else { return line }
        switch job.phase {
        case .running:
            if !job.phaseWaiters.isEmpty {
                line += " (waiting for the prune to finish)"
            } else {
                let minutes = Int(now.timeIntervalSince(job.startedAtWall) / 60)
                line += " (preparing a prune, started \(minutes) min ago)"
            }
        case .ready: line += " (ready, applies at the next step)"
        case .retiring: line += " (cancelling a prune)"
        case .applying: line += " (applying a prune)"
        }
        return line
    }

    /// /stop (region A-STOP1): a running worker is cancelled (write-free,
    /// so "nothing changed" is exact); a ready job is kept for the next
    /// turn's T0; an apply is stopped by the run's own cancellation.
    func backgroundPruneStopPass() -> BackgroundPruneStopNote? {
        guard let job = backgroundPruneJob else { return nil }
        let phase = job.phase.name
        if job.isRunning {
            job.phase = .retiring(.stop)
            job.worker?.cancel()
            bgPruneResumePhaseWaiters(job)
            bgPruneLog("bgprune.stop.cancelled")
        }
        return BackgroundPruneStopNote(phase: phase, jobId: job.id)
    }

    /// /stop report text (region A-STOP2).
    func backgroundPruneStopLine(_ note: BackgroundPruneStopNote) -> String? {
        if note.phase == "running" { return "The background prune being prepared was cancelled (nothing changed)." }
        if note.phase.hasPrefix("retiring") { return "A background prune is still stopping." }
        if note.phase == "applying" {
            guard let record = backgroundPruneLastApply, record.jobId == note.jobId else {
                return "A background prune is still stopping."
            }
            if record.committed { return "The background prune had already been applied." }
            let n = record.savedDescriptions
            return n > 0
                ? "The background prune was not applied (\(n) file description\(n == 1 ? "" : "s") it had saved \(n == 1 ? "is" : "are") kept)."
                : "The background prune was not applied."
        }
        return nil
    }

    /// /restart and /upgrade (regions A-RST, A-UPG): refused only while a
    /// worker can still run code or an apply is in progress.
    var backgroundPruneBlocksExit: Bool {
        backgroundPruneJob?.isBusy == true
    }

    /// Wipe and Mind restore (regions A-GEN1, A-GEN2): the replaced
    /// history invalidates any job (§12.1).
    func backgroundPruneHistoryReplaced() {
        backgroundPruneGeneration &+= 1
        backgroundPruneFallbackDue = false
        backgroundPruneT0AppliedRun = nil
        guard let job = backgroundPruneJob else { return }
        if job.isReady {
            job.phase = .retiring(.generation)
            bgPruneReleaseSlot(job)
        } else if job.isRunning {
            job.phase = .retiring(.generation)
            job.worker?.cancel()
            bgPruneResumePhaseWaiters(job)
        } else if job.isApplying {
            job.revoked = true
        }
        bgPruneLog("bgprune.generation")
    }

    // MARK: Selftest seams (read state or call the ON paths above)

    var bgPruneTestPhase: String {
        backgroundPruneJob?.phase.name ?? "none"
    }
    var bgPruneTestCounters: [String: Int] {
        backgroundPruneCounters
    }
    var bgPruneTestFallbackDue: Bool {
        backgroundPruneFallbackDue
    }
    var bgPruneTestPendingOff: Bool {
        backgroundPrunePendingOff
    }
    var bgPruneTestGeneration: UInt64 {
        backgroundPruneGeneration
    }
    var bgPruneTestJobManifest: [UUID] {
        backgroundPruneJob?.manifestIDs ?? []
    }
    var bgPruneTestSnapshotId: UUID? {
        backgroundPruneJob?.snapshotRef.id
    }
    var bgPruneTestInlineDebtConsumed: Bool {
        backgroundPruneJob?.inlineDebtConsumed ?? false
    }
    var bgPruneTestLastApply: BackgroundPruneApplyRecord? {
        backgroundPruneLastApply
    }
    var bgPruneTestMaintenanceKinds: [MaintenanceActivity.Kind] {
        maintenanceActivities.map(\.kind)
    }
    var bgPruneTestObservedBounds: [String: Int] {
        backgroundPruneObservedBounds
    }
    var bgPruneTestLastPromptTokens: Int? {
        lastPromptTokens
    }
    func bgPruneTestSetLastPromptTokens(_ value: Int?) {
        // A measurement of the current view (/keepsummaries §4.4 key).
        lastPromptRenderKey = PruneSummaryRetention.compose(messages, limit: KeepSummariesSetting.current()).renderKey
        lastPromptTokens = value
    }
    func bgPruneTestSetFallbackDue(_ value: Bool) {
        backgroundPruneFallbackDue = value
    }
    func bgPruneTestResetCounters() {
        backgroundPruneCounters = [:]
    }
    func bgPruneTestCommand(_ text: String) async -> String {
        await handleTerminalCommand(text)?.joined(separator: "\n") ?? ""
    }
    func bgPruneTestStatus() -> String {
        backgroundPruneStatusLine()
    }
    func bgPruneTestRunPhase(_ run: UUID) -> String {
        guard let phase = runPhases[run] else { return "none" }
        if case .pruneWait = phase { return "pruneWait" }
        return "other"
    }
    func bgPruneTestDescribe(_ run: UUID) -> String {
        describeStillFinishing(runId: run)
    }
    var bgPruneTestActiveRunId: UUID? {
        activeRunId
    }
    func bgPruneTestAwaitRelease(timeout: Double) async -> Bool {
        guard let job = backgroundPruneJob else { return true }
        return await bgPruneAwaitSlotReleased(job, timeout: timeout)
    }
    func bgPruneTestCeiling(maximum: Int, window: Int?, observed: Int?) -> Int {
        BackgroundPruneCeiling.ceiling(maximum: maximum, window: window, observed: observed)
    }
    func bgPruneTestLiveLimits() async -> (maximum: Int, ceiling: Int) {
        let identity = await bgPruneIdentity(nil)
        return bgPruneLimits(identity: identity.identity, model: identity.model)
    }
    func bgPruneTestIdentity() async -> String {
        await bgPruneIdentity(nil).identity
    }
    func bgPruneTestSetObservedBound(_ identity: String, _ value: Int?) {
        backgroundPruneObservedBounds[identity] = value
    }
    func bgPruneTestGuardFailure() -> String? {
        guard let job = backgroundPruneJob else { return "no-job" }
        return bgPruneGuardFailure(job)
    }
    func bgPruneTestSummaryOutcome(affected: [Int], model: String?) async -> BackgroundPruneSummaryOutcome {
        let plan = PrunePlan(actions: affected.map { .toolInteractions(index: $0, savedTokens: 0) },
                             pruningBoundary: (affected.max() ?? -1) + 1)
        let execution = await openRouterService.executionContext(modelOverride: model, providerOverride: nil,
            reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main)
        let inputs = BackgroundPruneSummaryInputs(currentTurnInteractions: nil, tools: [], calendarContext: "", emailContext: "",
            chunkSummaries: [], totalChunkCount: 0, currentUserMessageId: nil, turnStartDate: Date(timeIntervalSince1970: 1_790_000_000),
            deferredMCPSummaries: [], persona: nil, execution: execution)
        return await backgroundPruneSummary(plan: plan, compressedIndices: [], sourceMessages: messages, inputs: inputs)
    }
    func bgPruneTestOffSummary(affected: [Int]) async -> String? {
        let plan = PrunePlan(actions: affected.map { .toolInteractions(index: $0, savedTokens: 0) },
                             pruningBoundary: (affected.max() ?? -1) + 1)
        return await generatePrunedContextSummary(plan: plan, compressedIndices: [], sourceMessages: messages, tools: [],
            calendarContext: "", emailContext: "", chunkSummaries: [], totalChunkCount: 0, currentUserMessageId: nil,
            turnStartDate: Date(timeIntervalSince1970: 1_790_000_000), deferredMCPSummaries: [], execution: nil, persona: nil,
            summaryLimit: KeepSummariesSetting.current())
    }
    func bgPruneTestDescriptions(actions: [BackgroundPrunePlanAction]) async -> [BackgroundPruneActionDescriptions] {
        await backgroundPruneDescriptions(actions: actions, source: messages)
    }
    func bgPruneTestInlineDescriptions(actions: [BackgroundPrunePlanAction]) async {
        for action in actions {
            await generateDescriptionsBeforePruning(messageIndex: action.index, includeInlineMedia: !action.isTool,
                includeToolAttachments: action.isTool, sourceMessages: messages)
        }
    }
    func bgPruneTestReplaceHistory() {
        backgroundPruneHistoryReplaced()
    }
    func bgPruneTestEligibleError(_ error: Error) -> Bool {
        BackgroundPruneErrors.isEligibleInBand(error)
    }
    var bgPruneTestBlocksExit: Bool {
        backgroundPruneBlocksExit
    }
    func bgPruneTestDescription(_ filename: String) async -> String? {
        await FileDescriptionService.shared.get(filename: filename)
    }
    func bgPruneTestSaveDescription(_ filename: String, _ text: String) async {
        await FileDescriptionService.shared.saveMultiple([filename: text])
    }
    func bgPruneTestCancelledSummary(affected: [Int]) async -> BackgroundPruneSummaryOutcome {
        let task = Task { @MainActor in
            await self.bgPruneTestSummaryOutcome(affected: affected, model: nil)
        }
        task.cancel()
        return await task.value
    }
    func bgPruneTestRawSendError() async -> Error? {
        do {
            _ = try await openRouterService.generateResponse(messages: messages, imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory, tools: [], lane: .main)
            return nil
        } catch {
            return error
        }
    }
}
// }BGPRUNE
