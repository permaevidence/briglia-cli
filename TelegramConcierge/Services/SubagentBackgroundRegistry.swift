import Foundation

/// Owns all currently-running subagents launched via `Agent(run_in_background: "true")`.
///
/// Mirrors `BackgroundProcessRegistry` (bash) but is Task-backed rather than Process-backed:
/// there are no pipes, no PIDs — just a detached `Task` that runs `SubagentRunner.run(...)`
/// to completion and stores its structured `RunResult`.
///
/// ConversationManager calls `drainCompletions()` once per poll cycle to pull completions
/// and inject them as synthetic `[SUBAGENT COMPLETE]` user messages, triggering a new
/// agent turn so the parent can react.
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
    }

    struct Completion {
        let handle: Handle
        let result: SubagentRunner.RunResult
        let completedAt: Date
    }

    private var nextId: Int = 1
    private var running: [String: Handle] = [:]
    private var pendingCompletions: [Completion] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var executors: [String: ToolExecutor] = [:]  // for force-killing subprocesses

    private init() {}

    /// Spawns a detached Task that runs the invocation to completion and stores its result.
    /// Returns the Handle immediately.
    func spawn(
        invocation: SubagentRunner.Invocation,
        sessionId: String? = nil,
        parentTools: [ToolDefinition],
        openRouterService: OpenRouterService,
        toolExecutor: ToolExecutor,
        imagesDirectory: URL,
        documentsDirectory: URL
    ) -> Handle {
        let id = "subagent_\(nextId)"
        nextId += 1

        let handle = Handle(
            id: id,
            subagentType: invocation.subagentType,
            description: invocation.description,
            startedAt: Date(),
            sessionId: sessionId
        )
        running[id] = handle

        DebugTelemetry.log(
            .subagentSpawn,
            summary: "spawn subagent \(id) (\(invocation.subagentType))",
            detail: invocation.description
        )

        executors[id] = toolExecutor

        let task = Task.detached { [weak self] in
            let runner = SubagentRunner()
            // A resumed session is serialized by the runner's FIFO session
            // lock against a concurrent foreground resume.
            let result = await runner.run(
                invocation: invocation,
                sessionId: sessionId,
                openRouterService: openRouterService,
                toolExecutor: toolExecutor,
                imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory,
                parentTools: parentTools
            )
            await self?.markCompleted(id: id, result: result)
        }
        tasks[id] = task

        return handle
    }

    /// Returns and clears all completions.
    func drainCompletions() -> [Completion] {
        let out = pendingCompletions
        pendingCompletions.removeAll(keepingCapacity: true)
        return out
    }

    /// Snapshot of currently-running handles, used for diagnostics / system-prompt hints.
    func runningHandles() -> [Handle] {
        running.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Compact one-line-per-agent summary of running subagents, used by the
    /// system prompt so the parent knows what's in flight this turn. Returns
    /// `nil` when there are none (skip the section entirely).
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
        guard let task = tasks[id] else { return false }
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
    func cancelAll() -> Int {
        let count = tasks.count
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
        return count
    }

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

    // MARK: - Internal

    private func markCompleted(id: String, result: SubagentRunner.RunResult) {
        guard let handle = running.removeValue(forKey: id) else { return }
        tasks.removeValue(forKey: id)
        executors.removeValue(forKey: id)
        pendingCompletions.append(Completion(
            handle: handle,
            result: result,
            completedAt: Date()
        ))
    }
}
