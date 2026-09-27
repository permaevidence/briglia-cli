import Foundation

/// Owns all currently-running subagents launched via `Agent(run_in_background: "true")`,
/// and — mid-turn early wake release 1b (plan v7 §3.5) — every DETACHABLE
/// foreground run of the main agent (general-purpose, custom and Web; never
/// Browse or anything that can operate the browser).
///
/// Mirrors `BackgroundProcessRegistry` (bash) but is Task-backed rather than Process-backed:
/// there are no pipes, no PIDs — just a detached `Task` that runs `SubagentRunner.run(...)`
/// to completion and stores its structured `RunResult`.
///
/// A detachable foreground run executes in its own detached Task owned here
/// (so it can outlive the tool call), and the call awaits it through one
/// actor-serialized slot: whichever of finish / wake / cancellation reaches
/// the actor first decides, exactly once. A woken run is `detaching` until
/// the caller has made its crash record durable; only then does
/// `commitDetach` flip it to a background run (or report that it finished
/// meanwhile — then the caller returns the real result).
///
/// ConversationManager reads queued completions NON-destructively
/// (`pendingCompletionsForDelivery`), appends each under its pre-minted
/// message id, saves, and acknowledges them only after the save succeeded.
actor SubagentBackgroundRegistry {
    static let shared = SubagentBackgroundRegistry()

    struct Handle {
        let id: String              // e.g. "subagent_1"
        let subagentType: String
        let description: String
        let startedAt: Date
        /// The session being resumed, when the spawn resumed one
        /// (WEB_SUBAGENT_PLAN §4.7: background AND resumable).
        var sessionId: String? = nil
        /// Crash-record identity (1b): set for main-agent runs whose record
        /// is durable (explicit background launch, or a committed detach).
        var jobId: UUID? = nil
        /// Moved to the background by a user message (or the test setting).
        var detached: Bool = false
    }

    struct Completion {
        let handle: Handle
        let result: SubagentRunner.RunResult
        let completedAt: Date
        /// Stable id of the `[SUBAGENT COMPLETE]` message: every delivery
        /// attempt reuses it, appends are id-deduplicated (§3.10.3). For a
        /// recorded job it is the record's pre-minted `completionMessageId`.
        var messageId: UUID = UUID()
        /// The run's charge was captured by the charge ledger (§3.6.3): the
        /// drain must not charge it again. False only for unrecorded runs
        /// (tests, contexts without a depth-0 call scope).
        var chargeCaptured: Bool = false
    }

    /// How a detachable foreground await ended.
    enum ForegroundOutcome {
        /// The run finished first (or the call was cancelled and the run
        /// then finished with its cancelled result): the real result.
        case completed(SubagentRunner.RunResult)
        /// The wake won: the run keeps going and is now `detaching`.
        case woken(MidturnWakeReason)
    }

    /// Result of `commitDetach` once the crash record is durable.
    enum DetachCommit {
        case detached(Handle)
        /// The run finished while the record was being written.
        case completed(SubagentRunner.RunResult)
        /// /stop closed admission for the run's turn meanwhile: it stays
        /// foreground (and is being cancelled with the turn).
        case refused
        /// The awaiting call was cancelled before the handoff committed
        /// (turn cancellation that is not /stop, e.g. polling stopped): the
        /// run is cancelled with its call and stays foreground, so the call
        /// awaits and returns its (cancelled) result — never a moved result.
        case cancelled
    }

    /// Selftests: runs on the actor inside `commitDetach`, right before the
    /// cancellation decision (to cancel the calling task AT commit).
    nonisolated(unsafe) static var atCommitDetachForTesting: (() -> Void)?

    private enum ForegroundMode { case foreground, detaching }
    private struct ForegroundEntry {
        var handle: Handle
        var mode: ForegroundMode
        let turnRunId: UUID?
        var result: SubagentRunner.RunResult?
        var waiter: (id: UUID, continuation: CheckedContinuation<ForegroundOutcome, Never>)?
        var wakeTask: Task<Void, Never>?
    }

    private var nextId: Int = 1
    private var running: [String: Handle] = [:]
    private var foreground: [String: ForegroundEntry] = [:]
    private var pendingCompletions: [Completion] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var executors: [String: ToolExecutor] = [:]  // for force-killing subprocesses
    /// Sessions resolved by runs still going, by handle (fresh sessions are
    /// only known once the runner created them).
    private var liveSessions: [String: String] = [:]
    /// Turns whose launches are refused (a /stop cut them off). Bounded.
    private var closedTurnRunIds: [UUID] = []

    private init() {}

    /// Mint the next display handle (an explicit background launch writes
    /// its crash record under it BEFORE the run starts).
    func reserveHandleId() -> String {
        let id = "subagent_\(nextId)"
        nextId += 1
        return id
    }

    struct AdmissionRefused: Error, LocalizedError {
        var errorDescription: String? { "not started: the user stopped this turn with /stop" }
    }

    /// Spawns a detached Task that runs the invocation to completion and stores its result.
    /// Returns the Handle immediately. With `jobId` (main-agent launch whose
    /// crash record is durable), the run's charge is captured and its
    /// completion delivered under `completionMessageId`.
    func spawnRecorded(
        invocation: SubagentRunner.Invocation,
        sessionId: String?,
        parentTools: [ToolDefinition],
        openRouterService: OpenRouterService,
        toolExecutor: ToolExecutor,
        imagesDirectory: URL,
        documentsDirectory: URL,
        reservedId: String?,
        jobId: UUID?,
        completionMessageId: UUID?,
        turnRunId: UUID?
    ) throws -> Handle {
        if let turnRunId, closedTurnRunIds.contains(turnRunId) { throw AdmissionRefused() }
        let id = reservedId ?? reserveHandleId()
        let handle = Handle(
            id: id,
            subagentType: invocation.subagentType,
            description: invocation.description,
            startedAt: Date(),
            sessionId: sessionId,
            jobId: jobId
        )
        running[id] = handle
        if let completionMessageId { completionMessageIds[id] = completionMessageId }

        DebugTelemetry.log(
            .subagentSpawn,
            summary: "spawn subagent \(id) (\(invocation.subagentType))",
            detail: invocation.description
        )

        executors[id] = toolExecutor
        tasks[id] = makeRunTask(id: id, invocation: invocation, sessionId: sessionId,
                                parentTools: parentTools, openRouterService: openRouterService,
                                toolExecutor: toolExecutor, imagesDirectory: imagesDirectory,
                                documentsDirectory: documentsDirectory)
        return handle
    }

    /// Pre-minted completion ids of recorded runs, by handle.
    private var completionMessageIds: [String: UUID] = [:]

    /// A non-throwing wrapper for callers that never pass a turn (tests and
    /// legacy call sites): identical to `spawn` without admission control.
    func spawn(
        invocation: SubagentRunner.Invocation,
        sessionId: String? = nil,
        parentTools: [ToolDefinition],
        openRouterService: OpenRouterService,
        toolExecutor: ToolExecutor,
        imagesDirectory: URL,
        documentsDirectory: URL
    ) -> Handle {
        // No turn → no admission check → cannot throw.
        (try? spawnRecorded(invocation: invocation, sessionId: sessionId, parentTools: parentTools,
                    openRouterService: openRouterService, toolExecutor: toolExecutor,
                    imagesDirectory: imagesDirectory, documentsDirectory: documentsDirectory,
                    reservedId: nil, jobId: nil, completionMessageId: nil, turnRunId: nil))!
    }

    private func makeRunTask(id: String, invocation: SubagentRunner.Invocation, sessionId: String?,
                             parentTools: [ToolDefinition], openRouterService: OpenRouterService,
                             toolExecutor: ToolExecutor, imagesDirectory: URL,
                             documentsDirectory: URL) -> Task<Void, Never> {
        var invocation = invocation
        invocation.onSessionResolved = { [weak self] sid in
            Task { await self?.noteSession(id: id, sessionId: sid) }
        }
        let run = invocation
        return Task.detached { [weak self] in
            let runner = SubagentRunner()
            // A resumed session is serialized by the runner's FIFO session
            // lock against a concurrent foreground resume.
            let result = await runner.run(
                invocation: run,
                sessionId: sessionId,
                openRouterService: openRouterService,
                toolExecutor: toolExecutor,
                imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory,
                parentTools: parentTools
            )
            await self?.markCompleted(id: id, result: result)
        }
    }

    private func noteSession(id: String, sessionId: String) {
        guard running[id] != nil || foreground[id] != nil else { return }
        liveSessions[id] = sessionId
    }

    // MARK: Detachable foreground runs (§3.5)

    /// Start a detachable foreground run of the main agent. The run lives in
    /// a registry-owned Task; the caller awaits it with `awaitForeground`.
    /// Refused when /stop closed admission for `turnRunId`.
    func launchForeground(
        invocation: SubagentRunner.Invocation,
        sessionId: String?,
        parentTools: [ToolDefinition],
        openRouterService: OpenRouterService,
        toolExecutor: ToolExecutor,
        imagesDirectory: URL,
        documentsDirectory: URL,
        turnRunId: UUID?
    ) throws -> Handle {
        if let turnRunId, closedTurnRunIds.contains(turnRunId) { throw AdmissionRefused() }
        let id = reserveHandleId()
        let handle = Handle(id: id, subagentType: invocation.subagentType, description: invocation.description,
                            startedAt: Date(), sessionId: sessionId)
        foreground[id] = ForegroundEntry(handle: handle, mode: .foreground, turnRunId: turnRunId)
        executors[id] = toolExecutor
        tasks[id] = makeRunTask(id: id, invocation: invocation, sessionId: sessionId,
                                parentTools: parentTools, openRouterService: openRouterService,
                                toolExecutor: toolExecutor, imagesDirectory: imagesDirectory,
                                documentsDirectory: documentsDirectory)
        return handle
    }

    /// Await a foreground run: its result, or — only when `wake` is given — a
    /// wake after the grace window (the run keeps going, now `detaching`).
    /// Cancelling the awaiting task cancels the RUN (structured semantics,
    /// as when the run was inline) and still returns its final result.
    func awaitForeground(id: String, wake: WakeContext?) async -> ForegroundOutcome {
        if let result = foreground[id]?.result {
            foreground.removeValue(forKey: id)
            return .completed(result)
        }
        guard foreground[id] != nil else {
            return .completed(SubagentRunner.cancelledResult(sessionId: ""))
        }
        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ForegroundOutcome, Never>) in
                guard var entry = foreground[id] else {
                    continuation.resume(returning: .completed(SubagentRunner.cancelledResult(sessionId: "")))
                    return
                }
                if let result = entry.result {
                    foreground.removeValue(forKey: id)
                    continuation.resume(returning: .completed(result))
                    return
                }
                entry.mode = .foreground
                entry.waiter = (waiterId, continuation)
                if let wake {
                    entry.wakeTask = Task {
                        guard let reason = await MidturnWakeSignal.next(wake) else { return }
                        if Task.isCancelled { return }
                        await SubagentBackgroundRegistry.shared.foregroundWakeFired(id: id, waiterId: waiterId, reason: reason)
                    }
                }
                foreground[id] = entry
            }
        } onCancel: {
            Task { await SubagentBackgroundRegistry.shared.cancelForegroundRun(id: id) }
        }
    }

    /// Wake branch: decided on the actor, exactly once. A run that already
    /// finished is never "woken".
    private func foregroundWakeFired(id: String, waiterId: UUID, reason: MidturnWakeReason) {
        guard var entry = foreground[id], let waiter = entry.waiter, waiter.id == waiterId,
              entry.mode == .foreground, entry.result == nil else { return }
        entry.waiter = nil
        entry.wakeTask = nil
        entry.mode = .detaching
        foreground[id] = entry
        waiter.continuation.resume(returning: .woken(reason))
    }

    /// The call was cancelled (turn /stop, wipe): cancel the run itself; the
    /// waiter resolves with the run's (cancelled) result when it ends.
    private func cancelForegroundRun(id: String) {
        guard foreground[id] != nil else { return }
        foreground[id]?.wakeTask?.cancel()
        foreground[id]?.wakeTask = nil
        tasks[id]?.cancel()
        if let executor = executors[id] {
            Task.detached { await executor.cancelAllRunningProcesses() }
        }
    }

    /// The crash record could not be written: the wake is declined for this
    /// call and the run stays foreground (the caller awaits it again).
    func abortDetach(id: String) {
        guard foreground[id]?.mode == .detaching else { return }
        foreground[id]?.mode = .foreground
    }

    /// The crash record is durable: move the run to the background — unless
    /// it finished meanwhile (real result) or /stop closed its turn.
    func commitDetach(id: String, jobId: UUID, completionMessageId: UUID) -> DetachCommit {
        guard let entry = foreground[id], entry.mode == .detaching else {
            return .refused
        }
        if let result = entry.result {
            foreground.removeValue(forKey: id)
            return .completed(result)
        }
        Self.atCommitDetachForTesting?()
        // Cancellation ownership until the handoff commits: this actor method
        // runs in the CALLING task, so `Task.isCancelled` is that call's flag,
        // read in the same actor step that would commit. A cancellation set
        // before this point wins (whenever its handler is delivered); one set
        // after it is a post-commit cancel of an already-moved job.
        if Task.isCancelled {
            foreground[id]?.mode = .foreground
            cancelForegroundRun(id: id)
            return .cancelled
        }
        if let turn = entry.turnRunId, closedTurnRunIds.contains(turn) {
            foreground[id]?.mode = .foreground
            return .refused
        }
        foreground.removeValue(forKey: id)
        var handle = entry.handle
        handle.jobId = jobId
        handle.detached = true
        if handle.sessionId == nil { handle.sessionId = liveSessions[id] }
        running[id] = handle
        completionMessageIds[id] = completionMessageId
        return .detached(handle)
    }

    /// The session a run is working in, once known (fresh sessions are
    /// created by the runner shortly after launch).
    func sessionOfRun(id: String) -> String? {
        foreground[id]?.handle.sessionId ?? running[id]?.sessionId ?? liveSessions[id]
    }

    /// A wake-detached run still working in `sessionId`: a resume must fail
    /// fast (it would otherwise mutate the session under the running run).
    func detachedRunHolding(sessionId: String) -> Handle? {
        running.values.first { $0.detached && ($0.sessionId == sessionId || liveSessions[$0.id] == sessionId) }
    }

    // MARK: Completion delivery (§3.10.3)

    /// Returns and clears all completions. Used only where queued outputs
    /// are DISCARDED (wipe, Mind import); delivery is non-destructive.
    func drainCompletions() -> [Completion] {
        let out = pendingCompletions
        pendingCompletions.removeAll(keepingCapacity: true)
        return out
    }

    /// Non-destructive read of the queued completions: the caller appends
    /// each under `messageId` (skipped when already in history), saves, and
    /// only after a successful save acknowledges them.
    func pendingCompletionsForDelivery() -> [Completion] { pendingCompletions }

    /// Withdraw delivered completions — called only after the history save
    /// that carries their messages succeeded.
    func acknowledgeDelivered(messageIds: Set<UUID>) {
        guard !messageIds.isEmpty else { return }
        pendingCompletions.removeAll { messageIds.contains($0.messageId) }
    }

    /// /stop cutoff (mid-turn early wake §3.9.1, Codex 1a R3; 1b): close
    /// launch admission for the stopped turn and return every run the stop
    /// affects, in ONE actor step — running (background and detached) runs,
    /// run tasks not yet committed (foreground included), and finished runs
    /// whose completion is still queued. Job ids are the durable identities
    /// of recorded runs (the marker's `affectedJobIds`).
    func stopCutoff(turnRunId: UUID?) -> (handles: Set<String>, jobIds: Set<UUID>) {
        if let turnRunId, !closedTurnRunIds.contains(turnRunId) {
            closedTurnRunIds.append(turnRunId)
            if closedTurnRunIds.count > 64 { closedTurnRunIds.removeFirst() }
        }
        let handles = stopCutoffHandleIds()
        var jobs = Set(running.values.compactMap(\.jobId))
        jobs.formUnion(pendingCompletions.compactMap(\.handle.jobId))
        return (handles, jobs)
    }

    /// Every background run the stop affects (see `stopCutoff`).
    /// A run is always in at least one of these sets until its completion
    /// is drained, so no completion can slip between two snapshots.
    func stopCutoffHandleIds() -> Set<String> {
        Set(running.keys).union(tasks.keys).union(foreground.keys).union(pendingCompletions.map(\.handle.id))
    }

    /// Snapshot of background (and wake-detached) handles, used for
    /// diagnostics / system-prompt hints. Foreground runs are excluded.
    func runningHandles() -> [Handle] {
        running.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Compact one-line-per-agent summary of running subagents, used by the
    /// system prompt so the parent knows what's in flight this turn. Returns
    /// `nil` when there are none (skip the section entirely). Foreground
    /// runs are excluded (byte stability).
    func liveSummary() -> String? {
        let handles = running.values.sorted { $0.startedAt < $1.startedAt }
        guard !handles.isEmpty else { return nil }
        let now = Date()
        var lines: [String] = ["Running subagents:"]
        for h in handles {
            let secs = Int(now.timeIntervalSince(h.startedAt))
            let dur: String
            if secs < 60 {
                dur = "\(secs)s"
            } else {
                let m = secs / 60
                let s = secs % 60
                dur = "\(m)m \(s)s"
            }
            // Trim description to keep the line tight.
            let desc = h.description.count > 60
                ? String(h.description.prefix(60)) + "…"
                : h.description
            lines.append("- \(h.id) [\(h.subagentType), \"\(desc)\", running \(dur)]")
        }
        return lines.joined(separator: "\n")
    }

    /// Cancels a running subagent. Sets the cooperative cancellation flag AND
    /// terminates any running subprocesses owned by the subagent's executor,
    /// ensuring it exits even if stuck on blocking I/O.
    func cancel(id: String) -> Bool {
        guard running[id] != nil, let task = tasks[id] else { return false }
        task.cancel()
        // Force-kill any subprocesses (bash, MCP) the subagent's executor owns.
        if let executor = executors[id] {
            Task.detached {
                await executor.cancelAllRunningProcesses()
            }
        }
        return true
    }

    /// Cancel every running background subagent. Invoked by `/stop` so one
    /// command stops the main turn AND any parallel background work the
    /// user no longer wants to pay for.
    @discardableResult
    func cancelAll() -> Int { cancelAllReturningIds().count }

    /// `cancelAll`, returning the ids of the runs it cancelled (union'd into
    /// the /stop disposition: a run spawned after the cutoff snapshot but
    /// before this call is stopped work too). Foreground runs are cancelled
    /// too (they belong to the turn being stopped).
    func cancelAllReturningIds() -> Set<String> {
        // Foreground runs are cancelled too (their turn is being stopped)
        // but are not reported as background work.
        let ids = Set(tasks.keys).subtracting(foreground.keys).union(running.keys)
        for (_, task) in tasks {
            task.cancel()
        }
        // Force-kill all subprocesses owned by subagent executors.
        let execs = Array(executors.values)
        Task.detached {
            for executor in execs {
                await executor.cancelAllRunningProcesses()
            }
        }
        return ids
    }

    /// Background (non-foreground) job ids cancelled by `cancelAllReturningIds`.
    func runningJobIds() -> Set<UUID> { Set(running.values.compactMap(\.jobId)) }

    /// `/deleteuserdata` support: cancel everything and WAIT until every
    /// task has actually finished, so a cancelled subagent cannot commit
    /// its session, queue a late completion, or trigger a turn after the
    /// wipe proceeds. Unlike `/stop`'s `cancelAll` (which optimizes for
    /// returning fast), subprocess kills are awaited. A task body's last
    /// act is `markCompleted`, so an empty `tasks` map means every run has
    /// fully committed — the caller then discards `drainCompletions()`.
    /// Returns the ids still running at the deadline, for the honest wipe
    /// report.
    func cancelAllAndQuiesce(timeoutSeconds: Double) async -> [String] {
        for (_, task) in tasks { task.cancel() }
        for executor in Array(executors.values) {
            await executor.cancelAllRunningProcesses()
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        // Actor reentrancy: each sleep is a suspension point, so
        // markCompleted from finishing tasks interleaves and empties the map.
        while !tasks.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return tasks.keys.sorted()
    }

    /// Selftest-only: exercise the quiesce barrier without spawning a real
    /// subagent stack. Real entries leave `tasks` via `markCompleted`; a
    /// test entry leaves via `_testUnregister` from its own task body.
    /// Ids of run tasks that have not yet reached their commit point — the
    /// same population cancelAllAndQuiesce() cancels and awaits. Used by
    /// /exportmind's NON-destructive barrier, which refuses instead of
    /// cancelling (the `running` handle map is UI/lookup state and can lag
    /// the task's actual lifetime; the task map is what writes files).
    func activeRunIds() -> [String] { Array(tasks.keys) }

    func _testRegister(id: String, task: Task<Void, Never>) { tasks[id] = task }
    func _testUnregister(id: String) { tasks.removeValue(forKey: id) }
    func _testEnqueueCompletion(_ completion: Completion) { pendingCompletions.append(completion) }
    func _testPendingCompletionsCount() -> Int { pendingCompletions.count }
    /// Selftest-only: a running handle without a runner task (races /stop).
    func _testRegisterRunning(_ handle: Handle) { running[handle.id] = handle }
    /// Selftest-only: the production completion path for such a handle.
    func _testMarkCompleted(id: String, result: SubagentRunner.RunResult) { markCompleted(id: id, result: result) }
    /// Selftest-only: forget every run and completion (a simulated restart).
    func _testReset() {
        for (_, task) in tasks { task.cancel() }
        running.removeAll(); foreground.removeAll(); pendingCompletions.removeAll()
        tasks.removeAll(); executors.removeAll(); liveSessions.removeAll()
        completionMessageIds.removeAll(); closedTurnRunIds.removeAll()
    }
    func _testForegroundCount() -> Int { foreground.count }

    // MARK: - Internal

    private func markCompleted(id: String, result: SubagentRunner.RunResult) {
        tasks.removeValue(forKey: id)
        executors.removeValue(forKey: id)
        liveSessions.removeValue(forKey: id)
        // A foreground run: hand the real result to its awaiting call (or
        // keep it for commitDetach / a later await). Its spend travels on the
        // tool result, never through the charge ledger.
        if var entry = foreground[id] {
            entry.wakeTask?.cancel()
            entry.wakeTask = nil
            if let waiter = entry.waiter, entry.mode == .foreground {
                foreground.removeValue(forKey: id)
                waiter.continuation.resume(returning: .completed(result))
            } else {
                entry.result = result
                foreground[id] = entry
            }
            return
        }
        guard let handle = running.removeValue(forKey: id) else { return }
        let completedAt = Date()
        var completion = Completion(handle: handle, result: result, completedAt: completedAt)
        if let jobId = handle.jobId {
            // §3.6.3: the whole run total is recorded once, keyed by the job
            // id, BEFORE the completion is queued; the drain never charges.
            ToolChargeLedger.capture(jobId: jobId, amountUSD: result.spendUSD, at: completedAt, kind: "subagent")
            completion.chargeCaptured = true
            if let messageId = completionMessageIds.removeValue(forKey: id) { completion.messageId = messageId }
            // Persist the rendered notice so a restart before delivery still
            // delivers the real report (bounded by the runner's 32 KB cap).
            let duration = String(format: "%.1fs", completedAt.timeIntervalSince(handle.startedAt))
            let body = ConversationManager.backgroundSubagentCompletionBody(completion, durationStr: duration)
            let sessionId = result.sessionId.isEmpty ? nil : result.sessionId
            do {
                try DetachedJobStore.update(jobId, "settle") { record in
                    record.completionBody = body
                    record.settledAt = completedAt
                    if let sessionId { record.sessionId = sessionId }
                }
            } catch {
                print("[SubagentBackgroundRegistry] could not persist settlement of \(jobId): \(error.localizedDescription)")
            }
        }
        pendingCompletions.append(completion)
    }
}
