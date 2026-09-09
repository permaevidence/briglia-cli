import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Tool Executor

/// Central dispatcher that routes tool calls to their implementations
actor ToolExecutor {
    enum OutputMode {
        case mainAgent
        case subagent
    }

    private let outputMode: OutputMode

    /// Bash job owner token (BASH_V2_PLAN §10.5): "main" for the main
    /// agent's executor, a unique token per subagent executor. Background
    /// jobs are visible only to their owner; SubagentRunner terminates a
    /// subagent's surviving jobs when its run ends.
    nonisolated let bashOwner: String

    /// Whether this executor serves a subagent (drives bash_manage's watch
    /// refusal — watch matches inject into the MAIN conversation).
    var isSubagentExecutor: Bool { outputMode == .subagent }

    /// Per-executor tracker for auto-loaded project instruction files
    /// (AGENTS.md / CLAUDE.md). nonisolated so ConversationManager's pruner
    /// can clear entries synchronously; the tracker locks internally.
    nonisolated let projectInstructions = ProjectInstructionsTracker()

    /// Per-executor tracker for pre-edit git checkpoints (same pruning
    /// contract as projectInstructions).
    nonisolated let gitCheckpoints = GitCheckpointTracker()

    private let webOrchestrator = WebOrchestrator()
    private let archiveService = ConversationArchiveService()
    private var openRouterService: OpenRouterService?
    private var subagentImagesDirectory: URL?
    private var subagentDocumentsDirectory: URL?

    // Stored so child executors can be configured identically.
    private var configuredOpenRouterKey: String = ""
    private var configuredSerperKey: String = ""
    private var configuredJinaKey: String = ""

    private struct RunningProcessEntry {
        let owner: ObjectIdentifier
        let process: Process
    }

    private static let runningProcessLock = NSLock()
    private static var runningProcesses: [ObjectIdentifier: RunningProcessEntry] = [:]

    /// Whether the current turn was triggered by the user's own typed message
    /// (`Message.kind == .userText`). Set by ConversationManager at turn start.
    /// Child (subagent) executors never have it set, so it stays false there.
    /// Gates creation of script-backed reminders: a check script is persistent
    /// agent-authored code, and ambient turns (emails, bash completions,
    /// reminders) carry third-party content that could be steering the agent.
    private var turnTriggeredByUserText = false

    func setTurnTriggeredByUserText(_ value: Bool) {
        turnTriggeredByUserText = value
    }

    /// Delivery closure for the mid_turn_message_user tool, set by
    /// ConversationManager at each turn start with the turn's reply channel
    /// captured. Main agent only — child (subagent) executors never have it
    /// set, and the tool is also filtered out of subagent tool lists.
    private var midTurnMessageSender: (@Sendable (String) async throws -> Void)?

    func setMidTurnMessageSender(_ sender: (@Sendable (String) async throws -> Void)?) {
        midTurnMessageSender = sender
    }

    init(outputMode: OutputMode = .mainAgent) {
        self.outputMode = outputMode
        self.bashOwner = outputMode == .mainAgent
            ? BackgroundProcessRegistry.mainOwner
            : "sub-\(UUID().uuidString.prefix(8))"
    }

    private var allowsUserVisibleToolOutputs: Bool {
        outputMode == .mainAgent
    }

    /// What the bash surface of THIS executor can actually do. The schema a
    /// model received and the executor's behavior must agree exactly
    /// (BASH_V2_SCHEMA_CLEANUP_PLAN §3.3): a capability mismatch means
    /// either silently downgraded semantics (a wait_seconds build killed at
    /// 120s) or a hallucinated escape hatch (a foreground-only subagent
    /// detaching a job). Arguments outside the capability are REJECTED
    /// with an explicit error, never reinterpreted.
    enum BashCapability {
        /// Managed contract with the main conversation's notification lane:
        /// wait_seconds/kill_after_seconds on bash, bash_manage
        /// output/wait/input/watch/kill/list, automatic completion notices.
        case mainManaged
        /// Managed contract scoped to jobs OWNED by this subagent run: same
        /// lifecycle vocabulary, bash_manage output/wait/input/kill/list —
        /// no watch and no completion notices (both would inject into the
        /// MAIN conversation), and owned jobs die when the run ends.
        case subagentManaged
        /// Attached execution only: every command waits until settlement
        /// (bounded by its execution deadline) and every bash_manage mode
        /// is rejected — the subagent can never detach a job, strand a
        /// handle, or touch another agent's jobs.
        case foregroundOnly
    }

    /// Subagent capability, set by SubagentRunner to match the bash schema
    /// it serves. Defaults to the safest tier so an unconfigured child
    /// executor can never detach a process.
    private var subagentBashCapability: BashCapability = .foregroundOnly

    /// The main lane is structurally main-agent-only: a subagent executor
    /// granted .mainManaged is coerced to .subagentManaged (its completions
    /// would otherwise leak into the main conversation's injection stream).
    func setSubagentBashCapability(_ capability: BashCapability) {
        guard outputMode == .subagent else { return }
        subagentBashCapability = capability == .mainManaged ? .subagentManaged : capability
    }

    var bashCapability: BashCapability {
        if outputMode == .mainAgent { return .mainManaged }
        return subagentBashCapability
    }

    /// Managed bash jobs (wait_seconds, bash_manage wait/list) exist for
    /// every capability except attached-only execution.
    var supportsManagedBashJobs: Bool { bashCapability != .foregroundOnly }

    // MARK: - Bash wait policy (BASH_V2_PLAN §9)

    private var bashWaitLedger = BashWaitLedger()
    /// Admissions preflighted for the current tool round, keyed by call id.
    private var pendingWaitAdmissions: [String: BashWaitLedger.Admission] = [:]

    /// New run, fresh wait window and repeat-timeout guards.
    func resetBashWaitLedger() {
        bashWaitLedger = BashWaitLedger()
        pendingWaitAdmissions.removeAll()
    }

    /// Ledger admission for one wait: prefer the round preflight's decision
    /// (deterministic in assistant call order), fall back to inline
    /// admission for calls executed outside executeParallel.
    func consumeWaitAdmission(callId: String, handle: String, requestedSeconds: Double) -> BashWaitLedger.Admission {
        if let pre = pendingWaitAdmissions.removeValue(forKey: callId) { return pre }
        return bashWaitLedger.admit(handle: handle, requestedSeconds: requestedSeconds)
    }

    func recordBashWaitTimeout(handle: String) {
        bashWaitLedger.recordWaitTimeout(handle: handle)
    }

    /// Deterministic same-round wait admissions (BASH_V2_PLAN §9.3): decide
    /// in assistant tool-call order BEFORE the task group launches, so
    /// concurrent execution can't reorder ledger decisions. Waits on
    /// different handles may run concurrently (they share one turn window);
    /// only the FIRST wait per handle in a round is accepted.
    private func preflightBashWaits(_ calls: [ToolCall]) {
        // Admissions are keyed by call id and consumed at execution; a call
        // that errors out before consuming (e.g. rejected non-integer
        // wait_seconds) would otherwise leave its entry behind forever.
        pendingWaitAdmissions.removeAll()
        guard supportsManagedBashJobs else { return }
        var handlesThisRound = Set<String>()
        for call in calls {
            let name = call.function.name
            guard name == "bash" || name == "bash_manage" else { continue }
            guard let data = call.function.arguments.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            // Strict like the executor's own parsing: a fractional value is
            // rejected there, so it must not charge the ledger here.
            func intArg(_ key: String) -> Int? {
                // Mirrors ArgDict.strictInt: fractional values and genuine
                // booleans yield nil so a call the executor will reject
                // never charges the ledger.
                if BashTools.isJSONBoolean(obj[key] as Any) { return nil }
                if let i = obj[key] as? Int { return i }
                if let d = obj[key] as? Double { return d == d.rounded() ? Int(d) : nil }
                if let n = obj[key] as? NSNumber {
                    let d = n.doubleValue
                    return d == d.rounded() ? Int(d) : nil
                }
                if let s = obj[key] as? String { return Int(s) }
                return nil
            }
            if name == "bash" {
                guard let w = intArg("wait_seconds"), w > 0 else { continue }
                pendingWaitAdmissions[call.id] = bashWaitLedger.admit(
                    handle: "start:\(call.id)",
                    requestedSeconds: Double(min(w, BashTools.maxWaitSeconds)))
            } else {
                guard (obj["mode"] as? String) == "wait",
                      let handle = obj["handle"] as? String else { continue }
                // Present-but-invalid wait_seconds is rejected at execution —
                // don't charge the ledger for it.
                if obj["wait_seconds"] != nil, intArg("wait_seconds") == nil { continue }
                let w = Double(min(max(intArg("wait_seconds") ?? 1, 1), BashTools.maxWaitSeconds))
                if handlesThisRound.contains(handle) {
                    pendingWaitAdmissions[call.id] = .refused(
                        reason: "duplicate wait on \(handle) in this tool round — only the first wait per handle is accepted")
                } else {
                    handlesThisRound.insert(handle)
                    pendingWaitAdmissions[call.id] = bashWaitLedger.admit(handle: handle, requestedSeconds: w)
                }
            }
        }
    }

    // MARK: - Configuration

    func configure(openRouterKey: String, serperKey: String, jinaKey: String) async {
        self.configuredOpenRouterKey = openRouterKey
        self.configuredSerperKey = serperKey
        self.configuredJinaKey = jinaKey
        await webOrchestrator.configure(openRouterKey: openRouterKey, serperKey: serperKey, jinaKey: jinaKey)
        Task { await archiveService.configure(apiKey: openRouterKey) }
    }

    /// Inject the parent's OpenRouterService so the Agent tool can drive a subagent loop.
    func configureOpenRouter(_ service: OpenRouterService, imagesDirectory: URL, documentsDirectory: URL) {
        self.openRouterService = service
        self.subagentImagesDirectory = imagesDirectory
        self.subagentDocumentsDirectory = documentsDirectory
    }

    /// Creates an independent ToolExecutor for a subagent so its tool calls
    /// run on a separate actor queue, eliminating serialization contention
    /// with the parent agent's tool execution.
    func makeChildExecutor() async -> ToolExecutor {
        let child = ToolExecutor(outputMode: .subagent)
        await child.configure(
            openRouterKey: configuredOpenRouterKey,
            serperKey: configuredSerperKey,
            jinaKey: configuredJinaKey
        )
        if let ors = openRouterService,
           let imgDir = subagentImagesDirectory,
           let docDir = subagentDocumentsDirectory {
            await child.configureOpenRouter(ors, imagesDirectory: imgDir, documentsDirectory: docDir)
        }
        return child
    }
    
    nonisolated func cancelAllRunningProcesses() async {
        let processes = Self.snapshotRunningProcesses(owner: ObjectIdentifier(self))
        guard !processes.isEmpty else { return }

        print("[ToolExecutor] Cancelling \(processes.count) running subprocess(es)")
        // Collect descendants AND their process groups BEFORE signalling —
        // once a shell dies its children reparent and can no longer be found
        // via parent pids; group signalling additionally reaps double-forked
        // descendants that already reparented but kept the shell's group
        // (same two-sweep design as ProcessTree.terminate).
        let trees = processes.map { process -> (process: Process, descendants: [Int32], groups: [Int32]) in
            let kids = ProcessTree.descendants(of: process.processIdentifier)
            let groups = ProcessTree.processGroups(rootPid: process.processIdentifier, descendants: kids)
            return (process, kids, groups)
        }
        for tree in trees where tree.process.isRunning {
            tree.process.terminate()
            for g in tree.groups { _ = Darwin.kill(-g, SIGTERM) }
            for pid in tree.descendants { _ = Darwin.kill(pid, SIGTERM) }
        }

        try? await Task.sleep(nanoseconds: 300_000_000)

        for tree in trees where tree.process.isRunning {
            tree.process.interrupt()
        }

        try? await Task.sleep(nanoseconds: 300_000_000)

        for tree in trees {
            if tree.process.isRunning, tree.process.processIdentifier > 0 {
                _ = Darwin.kill(tree.process.processIdentifier, SIGKILL)
            }
            for g in tree.groups where Darwin.kill(-g, 0) == 0 {
                _ = Darwin.kill(-g, SIGKILL)
            }
            for pid in tree.descendants where Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }

    /// Kill every registered foreground subprocess regardless of owning executor,
    /// including descendants. App-shutdown path (applicationWillTerminate) —
    /// synchronous SIGTERM sweep, no grace period.
    nonisolated static func terminateAllRegisteredProcesses() {
        runningProcessLock.lock()
        let processes = runningProcesses.values.map { $0.process }
        runningProcessLock.unlock()
        ProcessTree.terminateSync(processes)
    }
    
    private nonisolated static func waitForProcessExit(_ process: Process, timeoutNanoseconds: UInt64) async {
        let pollInterval: UInt64 = 50_000_000
        var elapsed: UInt64 = 0
        
        while process.isRunning && elapsed < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: pollInterval)
            elapsed += pollInterval
        }
    }
    
    nonisolated func registerRunningProcess(_ process: Process) {
        Self.registerRunningProcess(process, owner: ObjectIdentifier(self))
    }

    private nonisolated static func registerRunningProcess(_ process: Process, owner: ObjectIdentifier) {
        runningProcessLock.lock()
        runningProcesses[ObjectIdentifier(process)] = RunningProcessEntry(owner: owner, process: process)
        runningProcessLock.unlock()
    }

    nonisolated static func unregisterRunningProcess(_ process: Process) {
        runningProcessLock.lock()
        runningProcesses.removeValue(forKey: ObjectIdentifier(process))
        runningProcessLock.unlock()
    }
    
    private nonisolated static func snapshotRunningProcesses(owner: ObjectIdentifier) -> [Process] {
        runningProcessLock.lock()
        let processes = runningProcesses.values.compactMap { entry in
            entry.owner == owner ? entry.process : nil
        }
        runningProcessLock.unlock()
        return processes
    }
    
    // MARK: - Execution
    
    /// Execute a single tool call and return the result
    func execute(_ call: ToolCall) async throws -> ToolResultMessage {
        try Task.checkCancellation()
        return try await withTelemetry(call) {
            // Git safety net: the first edit in a repo snapshots the working
            // tree BEFORE the edit lands (git stash create — a dangling
            // commit; no index/history side effects).
            let checkpoint = self.gitCheckpoints.checkpointIfNeeded(
                toolName: call.function.name,
                argumentsJSON: call.function.arguments
            )
            var result = try await self.executeBody(call)
            // First touch of a project in this context auto-loads its
            // AGENTS.md/CLAUDE.md into the tool result (rides along like LSP
            // diagnostics; deduped per instruction file until pruned). The
            // first successful code edit in a project additionally injects
            // its detected build/test checks. Both computed from the original
            // result content, before anything is appended.
            let instructions = self.projectInstructions.payload(
                toolName: call.function.name,
                argumentsJSON: call.function.arguments
            )
            let verification = self.projectInstructions.verificationPayload(
                toolName: call.function.name,
                argumentsJSON: call.function.arguments,
                resultContent: result.content
            )
            if let checkpoint { result.content += checkpoint }
            if let instructions { result.content += instructions }
            if let verification { result.content += verification }
            return result
        }
    }

    /// Wraps tool execution with telemetry (toolStart/toolEnd/toolError + timing).
    /// The telemetry stream is user-only and NEVER sent to the LLM.
    private func withTelemetry(
        _ call: ToolCall,
        _ body: () async throws -> ToolResultMessage
    ) async throws -> ToolResultMessage {
        let started = Date()
        let argSummary = Self.shortArgSummary(call.function.arguments)
        let startSummary = argSummary.isEmpty
            ? call.function.name
            : "\(call.function.name)  \(argSummary)"
        DebugTelemetry.log(
            .toolStart,
            summary: startSummary,
            detail: call.function.arguments
        )
        do {
            let result = try await body()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let isError = result.content.contains("\"error\"")
            DebugTelemetry.log(
                isError ? .toolError : .toolEnd,
                summary: "\(call.function.name) (\(ms)ms)",
                durationMs: ms,
                isError: isError
            )
            return result
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DebugTelemetry.log(
                .toolError,
                summary: "\(call.function.name) threw",
                detail: String(describing: error),
                durationMs: ms,
                isError: true
            )
            throw error
        }
    }

    /// Pulls 1–2 identifying fields from a tool's JSON argument string for a
    /// compact, single-line summary in the telemetry view. Falls back to the
    /// first 60 chars of the raw arg string when parsing fails.
    static func shortArgSummary(_ jsonArgs: String) -> String {
        let preferredKeys = ["path", "file_path", "filename", "handle", "query", "question", "command", "url", "pattern", "search_term", "target"]
        if let data = jsonArgs.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var parts: [String] = []
            for key in preferredKeys {
                if parts.count >= 2 { break }
                if let v = obj[key] {
                    let strVal: String
                    if let s = v as? String { strVal = s }
                    else { strVal = String(describing: v) }
                    parts.append("\(key)=\(strVal)")
                }
            }
            if !parts.isEmpty {
                let joined = parts.joined(separator: " ")
                if joined.count <= 60 { return joined }
                return String(joined.prefix(60)) + "…"
            }
        }
        let trimmed = jsonArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.count <= 60 { return trimmed }
        return String(trimmed.prefix(60)) + "…"
    }

    /// Internal dispatch body (formerly the body of `execute`). Kept separate so
    /// `withTelemetry` can wrap the whole thing uniformly.
    private func executeBody(_ call: ToolCall) async throws -> ToolResultMessage {
        // Special cases for tools that return ToolResultMessage with file attachment for multimodal injection
        switch call.function.name {
        case "read_file":
            return await executeReadFile(call)
        case "shortcuts":
            return await executeShortcuts(call)
        case "generate_image":
            return await executeGenerateImage(call)
        case "run_shortcut":
            return await executeRunShortcut(call)
        case "web_search":
            return try await executeWebSearch(call)
        case "web_research_sweep":
            return try await executeDeepResearch(call)
        case "Agent":
            return await executeAgentToolResult(call)
        case "inspect_media":
            return await executeInspectMedia(call)
        case "transcribe_media":
            return await executeTranscribeMedia(call)
        default:
            break
        }
        
        let content: String
        
        switch call.function.name {
        // Filesystem tool surface
        case "write_file":
            content = await executeWriteFile(call)
        case "edit_file":
            content = await executeEditFile(call)
        case "apply_patch":
            content = await executeApplyPatch(call)
        case "grep":
            content = await executeGrep(call)
        case "glob":
            content = await executeGlob(call)
        case "list_dir":
            content = await executeListDir(call)
        case "list_recent_files":
            content = await executeListRecentFiles(call)
        case "bash":
            return await executeBash(call)
        case "bash_manage":
            return await executeBashManage(call)
        case "todo_write":
            content = await executeTodoWrite(call)
        case "subagent_manage":
            content = await executeSubagentManage(call)
        case "lsp":
            content = await executeLSP(call)

        case "manage_reminders":
            content = try await executeManageReminders(call)

        case "manage_calendar":
            content = await executeManageCalendar(call)

        case "read_chunk_summaries", "list_conversation_chunks":  // legacy alias for transcripts recorded before the rename
            content = await executeReadChunkSummaries(call)

        case "skill":
            content = executeLoadSkill(call)

        case "tool_search":
            content = await executeToolSearch(call)
        case "mcp_call":
            return await executeMcpCall(call)

        // generate_image is handled in the special multimodal injection switch above

        case "web_fetch":
            content = await executeWebFetch(call)
            
        case "send_document_to_chat":
            content = await executeSendDocumentToChat(call)

        case "mid_turn_message_user":
            content = await executeMidTurnMessageUser(call)

        // Shortcuts Tools
        case "list_shortcuts":
            content = await executeListShortcuts(call)
        // run_shortcut is handled above with file attachment for media output

        default:
            if MCPRegistry.isMCPPrefixed(call.function.name) {
                // Resolution goes through the accepted-tool registry (alias,
                // or a legacy raw name via its validated reverse map); an
                // unregistered name is an error, never a passthrough.
                let mcpResult = await MCPRegistry.shared.callTool(
                    name: call.function.name,
                    argumentsJSON: call.function.arguments
                )
                return mcpToolResultMessage(call, mcpResult)
            } else {
                content = "{\"error\": \"Unknown tool: \(call.function.name)}\"}"
            }
        }
        
        return ToolResultMessage(toolCallId: call.id, content: content)
    }
    
    /// Execute multiple tool calls in parallel
    func executeParallel(_ calls: [ToolCall]) async throws -> [ToolResultMessage] {
        try Task.checkCancellation()
        preflightBashWaits(calls)
        return try await withThrowingTaskGroup(of: ToolResultMessage.self) { group in
            for call in calls {
                group.addTask {
                    try Task.checkCancellation()
                    return try await self.execute(call)
                }
            }
            
            var results: [ToolResultMessage] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    // MARK: - Tool Implementations
    
    private func executeWebSearch(_ call: ToolCall) async throws -> ToolResultMessage {
        // Parse arguments from JSON string
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebSearchArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse web_search arguments\"}")
        }
        
        do {
            let result = try await webOrchestrator.executeForTool(query: args.query)
            return ToolResultMessage(
                toolCallId: call.id,
                content: result.asJSON(),
                spendUSD: result.spendUSD
            )
        } catch {
            let spendUSD = (error as? ResearchExecutionError)?.spendUSD
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": webPipelineFailureText("Web search failed", error: error)]),
                spendUSD: spendUSD
            )
        }
    }

    private func executeDeepResearch(_ call: ToolCall) async throws -> ToolResultMessage {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebSearchArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse web_research_sweep arguments\"}")
        }

        do {
            let result = try await webOrchestrator.executeDeepResearchForTool(query: args.query)
            return ToolResultMessage(
                toolCallId: call.id,
                content: result.asJSON(),
                spendUSD: result.spendUSD
            )
        } catch {
            let spendUSD = (error as? ResearchExecutionError)?.spendUSD
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": webPipelineFailureText("Deep research failed", error: error)]),
                spendUSD: spendUSD
            )
        }
    }

    private func executeInspectMedia(_ call: ToolCall) async -> ToolResultMessage {
        guard KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "true" else {
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": "inspect_media is only available when Text-only model is enabled."])
            )
        }

        guard let args = parseJSONArguments(call.function.arguments) else {
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": "Failed to parse inspect_media arguments"])
            )
        }

        guard let target = firstString(in: args, keys: ["filename", "path", "file"]) else {
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": "inspect_media requires 'filename'"])
            )
        }
        // Bulk OCR-to-file mode: transcribe to a file on disk instead of
        // returning pages into the model context.
        if AvailableTools.bulkOCRSaveToEnabled,
           let saveTo = firstString(in: args, keys: ["save_to"]) {
            return await executeInspectMediaSaveTo(call, args: args, target: target, saveTo: saveTo)
        }

        guard let question = firstString(in: args, keys: ["question", "prompt"]) else {
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": "inspect_media requires 'question'"])
            )
        }

        let pages = firstString(in: args, keys: ["pages", "page"])
        let regionHint = firstString(in: args, keys: ["region_hint", "region", "area"])

        guard let service = openRouterService else {
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": "OpenRouter service is not configured for inspect_media."])
            )
        }

        guard let mediaURL = resolveInspectableMediaURL(target) else {
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": "Media file not found: \(target)"])
            )
        }

        let mimeType = FilesystemTools.mimeType(forPath: mediaURL.path)
        guard FilesystemTools.isMultimodalMime(mimeType) else {
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": "inspect_media supports images and PDFs only. \(mediaURL.path) has MIME type \(mimeType)."])
            )
        }

        let loaded: InspectableMediaData
        do {
            loaded = try loadInspectableMediaData(url: mediaURL, mimeType: mimeType, pages: pages)
        } catch {
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": error.localizedDescription])
            )
        }

        do {
            let inspection = try await service.inspectMedia(
                filename: mediaURL.lastPathComponent,
                data: loaded.data,
                mimeType: loaded.mimeType,
                question: question,
                pages: loaded.pageRange,
                regionHint: regionHint
            )

            var payload: [String: Any] = [
                "success": true,
                "filename": mediaURL.lastPathComponent,
                "path": mediaURL.path,
                "mime_type": loaded.mimeType,
                "question": question,
                "answer": inspection.answer
            ]
            if let pageRange = loaded.pageRange { payload["pages"] = pageRange }
            if let totalPages = loaded.totalPages { payload["total_pages"] = totalPages }
            if let regionHint { payload["region_hint"] = regionHint }
            if let spendUSD = inspection.spendUSD { payload["spend_usd"] = spendUSD }

            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(payload),
                spendUSD: inspection.spendUSD
            )
        } catch {
            return ToolResultMessage(
                toolCallId: call.id,
                content: jsonObjectString(["error": "inspect_media failed: \(error.localizedDescription)"])
            )
        }
    }

    /// Bulk OCR-to-file: transcribe a (possibly very long) scanned PDF to a
    /// text file in parallel 4-page batches. Only reachable while Legal
    /// Research (Italy) is enabled — see AvailableTools.inspectMedia. The
    /// written file (not the conversation) is the durable product: context
    /// receives a short completion summary regardless of document size.
    private func executeInspectMediaSaveTo(
        _ call: ToolCall,
        args: [String: Any],
        target: String,
        saveTo: String
    ) async -> ToolResultMessage {
        func fail(_ message: String) -> ToolResultMessage {
            ToolResultMessage(toolCallId: call.id, content: jsonObjectString(["error": message]))
        }

        guard let service = openRouterService else {
            return fail("OpenRouter service is not configured for inspect_media.")
        }
        guard let mediaURL = resolveInspectableMediaURL(target) else {
            return fail("Media file not found: \(target)")
        }
        let mimeType = FilesystemTools.mimeType(forPath: mediaURL.path)
        guard mimeType == "application/pdf" else {
            return fail("save_to supports PDFs only — \(mediaURL.path) is \(mimeType). A single image's transcription fits in a normal inspect_media call.")
        }
        let savePath = FilesystemTools.normalizePath(saveTo)
        guard FilesystemTools.isAbsolute(savePath) else {
            return fail("save_to must be an absolute path (got '\(saveTo)').")
        }
        guard let document = AdaPDF(url: mediaURL) else {
            return fail("failed to open PDF: \(mediaURL.path)")
        }
        let totalPages = document.pageCount
        guard totalPages > 0 else {
            return fail("PDF \(mediaURL.path) has zero pages.")
        }

        let range: ClosedRange<Int>
        if let rawPages = firstString(in: args, keys: ["pages", "page"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !rawPages.isEmpty {
            guard let parsed = FilesystemTools.parsePageRange(rawPages, totalPages: totalPages) else {
                return fail("invalid pages value '\(rawPages)'. Use formats like '3', '1-5', or '10-20'. PDF has \(totalPages) pages.")
            }
            range = parsed
        } else {
            range = 1...totalPages
        }

        // Born-digital guard: vision-OCR of a PDF that already carries a text
        // layer wastes spend and loses exactness — route those to pdftotext.
        // Density is measured over the REQUESTED range, so the scanned section
        // of a mixed document can still be OCR'd by narrowing the range.
        // force_ocr skips the guard for the one case it misjudges: a scan whose
        // scanner embedded its own garbage OCR layer, which only shows up after
        // the agent has read the pdftotext output the refusal points it to.
        let forceOCR: Bool = {
            if let flag = args["force_ocr"] as? Bool { return flag }
            if let text = args["force_ocr"] as? String { return text.lowercased() == "true" }
            return false
        }()
        if !forceOCR {
            var textLayerChars = 0
            for pageNumber in range {
                textLayerChars += document.pageText(at: pageNumber - 1)?.count ?? 0
            }
            let averageChars = textLayerChars / range.count
            if averageChars >= 100 {
                return fail(
                    "Pages \(range.lowerBound)-\(range.upperBound) of \(mediaURL.path) carry a real text layer (~\(averageChars) chars/page) — this looks born-digital, not scanned. Extract the exact text for free with bash: pdftotext -f \(range.lowerBound) -l \(range.upperBound) \"\(mediaURL.path)\" \"\(savePath)\". If only some pages are scanned images, call again with 'pages' narrowed to those. If the extracted text turns out to be unreadable garbage (broken words, character soup), this is a scanner-embedded OCR layer, not a born-digital document — re-run this call with force_ocr: true."
                )
            }
        }

        let focus = firstString(in: args, keys: ["question", "prompt"])

        // Slice the range into 4-page batches up front (cheap), so only Data
        // crosses into the concurrent tasks — the PDF document stays on the actor.
        struct OCRBatch {
            let pages: ClosedRange<Int>
            let data: Data
        }
        let batchSize = 4
        var batches: [OCRBatch] = []
        var start = range.lowerBound
        while start <= range.upperBound {
            let end = min(start + batchSize - 1, range.upperBound)
            guard let slicedData = document.sliceData(pages: start...end) else {
                return fail("failed to serialize PDF pages \(start)-\(end) of \(mediaURL.path).")
            }
            batches.append(OCRBatch(pages: start...end, data: slicedData))
            start = end + 1
        }

        let filename = mediaURL.lastPathComponent

        // Concurrency-capped fan-out (4 in flight), mirroring the grouped-
        // parallel vision preprocessing path. Only CancellationError escapes a
        // child task, so /stop aborts the whole group; every other failure is
        // carried as an outcome and becomes a placeholder in the file.
        enum BatchOutcome {
            case success(text: String, spendUSD: Double?)
            case failure(Error)
        }
        var outcomes = [Int: BatchOutcome]()
        do {
            try await withThrowingTaskGroup(of: (Int, BatchOutcome).self) { group in
                var nextBatch = 0
                func addNextCall() {
                    guard nextBatch < batches.count else { return }
                    let idx = nextBatch
                    let batch = batches[idx]
                    nextBatch += 1
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let (text, spendUSD) = try await service.transcribeDocumentPages(
                                filename: filename,
                                pdfSliceData: batch.data,
                                pageNumbers: Array(batch.pages),
                                focus: focus
                            )
                            return (idx, .success(text: text, spendUSD: spendUSD))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return (idx, .failure(error))
                        }
                    }
                }
                for _ in 0..<min(4, batches.count) { addNextCall() }
                while let (idx, outcome) = try await group.next() {
                    outcomes[idx] = outcome
                    addNextCall()
                }
            }
        } catch {
            return fail("inspect_media transcription cancelled — nothing was written to \(savePath).")
        }

        // Assemble in page order regardless of completion order.
        var sections: [String] = []
        var failures: [String] = []
        var failedPages = 0
        var totalSpendUSD: Double? = nil
        for (idx, batch) in batches.enumerated() {
            switch outcomes[idx] {
            case .success(let text, let spendUSD):
                sections.append(text)
                if let spendUSD { totalSpendUSD = (totalSpendUSD ?? 0) + spendUSD }
            case .failure(let error):
                let label = batch.pages.count == 1
                    ? "page \(batch.pages.lowerBound)"
                    : "pages \(batch.pages.lowerBound)-\(batch.pages.upperBound)"
                failures.append("\(label): \(error.localizedDescription)")
                failedPages += batch.pages.count
                sections.append("--- page \(batch.pages.lowerBound) ---\n[transcription FAILED for \(label): \(error.localizedDescription)]")
            case nil:
                let label = "pages \(batch.pages.lowerBound)-\(batch.pages.upperBound)"
                failures.append("\(label): no result")
                failedPages += batch.pages.count
                sections.append("--- page \(batch.pages.lowerBound) ---\n[transcription MISSING for \(label)]")
            }
        }

        let header = "# OCR transcription of \(mediaURL.path)\n# pages \(range.lowerBound)-\(range.upperBound) of \(totalPages) — generated by inspect_media\n\n"
        let output = header + sections.joined(separator: "\n\n") + "\n"

        let saveURL = URL(fileURLWithPath: savePath)
        do {
            try FileManager.default.createDirectory(
                at: saveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try output.write(to: saveURL, atomically: true, encoding: .utf8)
        } catch {
            return fail("transcription succeeded but writing \(savePath) failed: \(error.localizedDescription)")
        }

        if let totalSpendUSD {
            print("[ToolExecutor] inspect_media save_to spend: $\(String(format: "%.4f", totalSpendUSD)) across \(batches.count) batch(es)")
        }

        var payload: [String: Any] = [
            "success": failures.isEmpty,
            "filename": filename,
            "save_to": savePath,
            "pages": "\(range.lowerBound)-\(range.upperBound)",
            "total_pages": totalPages,
            "pages_transcribed": range.count - failedPages,
            "note": "Transcription written with '--- page N ---' markers. Use read_file (offset/limit or grep) on \(savePath) to consult it — do NOT read the whole file into context at once if it is large."
        ]
        if !failures.isEmpty {
            payload["failed_batches"] = failures
            payload["hint"] = "Failed ranges carry a placeholder in the file. Re-run inspect_media with 'pages' set to just those ranges and a fresh save_to file, then merge with edit_file."
        }
        if let totalSpendUSD { payload["spend_usd"] = totalSpendUSD }

        return ToolResultMessage(
            toolCallId: call.id,
            content: jsonObjectString(payload),
            spendUSD: totalSpendUSD
        )
    }

    private struct InspectableMediaData {
        let data: Data
        let mimeType: String
        let pageRange: String?
        let totalPages: Int?
    }

    // MARK: - Transcribe Media

    /// Extensions both WhisperKit (AVFoundation) and the OpenAI endpoint
    /// accept directly. Anything else (video containers, exotic codecs) is
    /// routed through an ffmpeg audio-extraction pass first.
    private static let directAudioExtensions: Set<String> = ["wav", "mp3", "m4a", "ogg", "oga", "flac", "aac", "aiff", "aif"]

    private func executeTranscribeMedia(_ call: ToolCall) async -> ToolResultMessage {
        func fail(_ message: String) -> ToolResultMessage {
            ToolResultMessage(toolCallId: call.id, content: jsonObjectString(["error": message]))
        }

        guard let args = parseJSONArguments(call.function.arguments) else {
            return fail("Failed to parse transcribe_media arguments")
        }
        guard let rawPath = firstString(in: args, keys: ["path", "file", "filename"]) else {
            return fail("transcribe_media requires 'path'")
        }
        let format = (firstString(in: args, keys: ["format"]) ?? "text").lowercased()
        guard format == "text" || format == "srt" else {
            return fail("Unsupported format '\(format)'. Use 'text' or 'srt'.")
        }
        let language = firstString(in: args, keys: ["language"])

        let inputURL = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardized
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            return fail("File not found: \(inputURL.path)")
        }

        let provider = VoiceTranscriptionProvider.fromStoredValue(
            KeychainHelper.load(key: KeychainHelper.voiceTranscriptionProviderKey)
        )

        // Prepare the audio: pass plain audio files through, extract the
        // audio track from everything else.
        var workURL = inputURL
        var tempAudioURL: URL?
        defer { if let tempAudioURL { try? FileManager.default.removeItem(at: tempAudioURL) } }

        if !Self.directAudioExtensions.contains(inputURL.pathExtension.lowercased()) {
            guard let ffmpeg = Self.locateTranscodeExecutable("ffmpeg") else {
                return fail("'\(inputURL.lastPathComponent)' is not a plain audio file and ffmpeg is not installed, so the audio track cannot be extracted. Install ffmpeg (brew install ffmpeg) or provide an audio file.")
            }
            // 16 kHz mono is what Whisper consumes; AAC/m4a keeps OpenAI uploads small.
            let ext = provider == .openAI ? "m4a" : "wav"
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcribe-\(UUID().uuidString).\(ext)")
            var extractArgs = ["-y", "-v", "error", "-i", inputURL.path, "-vn", "-ac", "1", "-ar", "16000"]
            if provider == .openAI {
                extractArgs += ["-c:a", "aac", "-b:a", "64k"]
            }
            extractArgs.append(temp.path)
            let extraction = await Self.runTranscodeProcess(executable: ffmpeg, args: extractArgs, timeoutSeconds: 600)
            guard extraction.status == 0, FileManager.default.fileExists(atPath: temp.path) else {
                let detail = extraction.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return fail("ffmpeg could not extract an audio track from \(inputURL.lastPathComponent)\(detail.isEmpty ? "" : ": \(detail.prefix(300))"). Does the file contain audio?")
            }
            workURL = temp
            tempAudioURL = temp
        }

        switch provider {
        case .openAI:
            let apiKey = (KeychainHelper.load(key: KeychainHelper.openAITranscriptionApiKeyKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                return fail("No OpenAI API key is configured for transcription. Run `briglia setup` (section 2) to add it.")
            }
            if let size = try? FileManager.default.attributesOfItem(atPath: workURL.path)[.size] as? Int,
               size > 25 * 1024 * 1024 {
                return fail("Audio is \(size / (1024 * 1024)) MB — above OpenAI's 25 MB upload limit. Trim or split the media first (see the video-edit skill).")
            }

            if format == "text" {
                do {
                    let text = try await OpenAITranscriptionService.shared.transcribeAudioFile(url: workURL, apiKey: apiKey, language: language)
                    return ToolResultMessage(toolCallId: call.id, content: jsonObjectString([
                        "provider": "openai/gpt-transcribe",
                        "source": inputURL.path,
                        "transcript": text
                    ]))
                } catch {
                    return fail("OpenAI transcription failed: \(error.localizedDescription)")
                }
            } else {
                do {
                    let srt = try await OpenAITranscriptionService.shared.transcribeAudioFileSRT(url: workURL, apiKey: apiKey, language: language)
                    return writeSRTResult(call: call, srt: srt, args: args, inputURL: inputURL, provider: "openai/whisper-1")
                } catch {
                    return fail("OpenAI SRT transcription failed: \(error.localizedDescription)")
                }
            }

        case .local:
            var ready = await MainActor.run { WhisperKitService.shared.isModelReady }
            if !ready {
                await WhisperKitService.shared.checkModelStatus()
                ready = await MainActor.run { WhisperKitService.shared.isModelReady }
            }
            guard ready else {
                let status = await MainActor.run { WhisperKitService.shared.statusMessage }
                // Unreachable in Briglia CLI (stored "local" normalizes to
                // OpenAI), kept for upstream-merge compatibility.
                return fail("Local transcription is not available in Briglia CLI (\(status)). OpenAI cloud transcription is used instead.")
            }

            guard let segments = await WhisperKitService.shared.transcribeAudioFileSegments(url: workURL, language: language),
                  !segments.isEmpty else {
                return fail("Local transcription produced no speech segments. Does the audio contain speech?")
            }

            if format == "text" {
                let text = segments.map(\.text).joined(separator: " ")
                return ToolResultMessage(toolCallId: call.id, content: jsonObjectString([
                    "provider": "local/whisperkit",
                    "source": inputURL.path,
                    "transcript": text
                ]))
            } else {
                let srt = Self.buildSRT(from: segments)
                return writeSRTResult(call: call, srt: srt, args: args, inputURL: inputURL, provider: "local/whisperkit")
            }
        }
    }

    /// Write SRT content to disk and build the tool result payload.
    private func writeSRTResult(call: ToolCall, srt: String, args: [String: Any], inputURL: URL, provider: String) -> ToolResultMessage {
        let outputURL: URL
        if let custom = firstString(in: args, keys: ["output_path"]) {
            outputURL = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).standardized
        } else {
            outputURL = inputURL.deletingPathExtension().appendingPathExtension("srt")
        }

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try srt.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            return ToolResultMessage(toolCallId: call.id, content: jsonObjectString([
                "error": "Transcription succeeded but writing the SRT failed: \(error.localizedDescription)",
                "srt_preview": String(srt.prefix(1000))
            ]))
        }

        let cueCount = srt.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return ToolResultMessage(toolCallId: call.id, content: jsonObjectString([
            "provider": provider,
            "source": inputURL.path,
            "srt_path": outputURL.path,
            "cues": cueCount,
            "preview": String(srt.prefix(800))
        ]))
    }

    private static func buildSRT(from segments: [WhisperKitService.TimedSegment]) -> String {
        func timestamp(_ seconds: Double) -> String {
            let clamped = max(seconds, 0)
            let h = Int(clamped) / 3600
            let m = (Int(clamped) % 3600) / 60
            let s = Int(clamped) % 60
            let ms = Int((clamped - clamped.rounded(.down)) * 1000)
            return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
        }
        var cues: [String] = []
        for (index, segment) in segments.enumerated() {
            // Guarantee a visible, non-zero-length cue even if timestamps degenerate.
            let end = segment.end > segment.start ? segment.end : segment.start + 0.5
            cues.append("\(index + 1)\n\(timestamp(segment.start)) --> \(timestamp(end))\n\(segment.text)")
        }
        return cues.joined(separator: "\n\n") + "\n"
    }

    private static func locateTranscodeExecutable(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func runTranscodeProcess(executable: String, args: [String], timeoutSeconds: Double) async -> (stdout: String, stderr: String, status: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ("", "failed to launch \(executable): \(error.localizedDescription)", -1))
                    return
                }

                let deadline = Date().addingTimeInterval(timeoutSeconds)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning {
                    process.terminate()
                    continuation.resume(returning: ("", "timed out after \(Int(timeoutSeconds))s", -1))
                    return
                }

                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (stdout, stderr, process.terminationStatus))
            }
        }
    }

    private func parseJSONArguments(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func firstString(in args: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = args[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = args[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private func resolveInspectableMediaURL(_ rawTarget: String) -> URL? {
        let normalized = FilesystemTools.normalizePath(rawTarget)
        let fm = FileManager.default
        if FilesystemTools.isAbsolute(normalized), fm.fileExists(atPath: normalized) {
            return URL(fileURLWithPath: normalized)
        }

        let basename = (normalized as NSString).lastPathComponent
        guard !basename.isEmpty else { return nil }

        let candidates = [
            imagesDirectory.appendingPathComponent(basename),
            documentsDirectory.appendingPathComponent(basename)
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private func loadInspectableMediaData(url: URL, mimeType: String, pages: String?) throws -> InspectableMediaData {
        if mimeType == "application/pdf" {
            return try loadInspectablePDFData(url: url, pages: pages)
        }

        let data = try Data(contentsOf: url)
        return InspectableMediaData(data: data, mimeType: mimeType, pageRange: nil, totalPages: nil)
    }

    private func loadInspectablePDFData(url: URL, pages: String?) throws -> InspectableMediaData {
        guard let document = AdaPDF(url: url) else {
            throw NSError(domain: "InspectMedia", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed to open PDF: \(url.path)"
            ])
        }
        let totalPages = document.pageCount
        guard totalPages > 0 else {
            throw NSError(domain: "InspectMedia", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "PDF \(url.path) has zero pages."
            ])
        }

        let requestedRange: ClosedRange<Int>
        if let rawPages = pages?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPages.isEmpty {
            guard let parsed = FilesystemTools.parsePageRange(rawPages, totalPages: totalPages) else {
                throw NSError(domain: "InspectMedia", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "invalid pages value '\(rawPages)'. Use formats like '3', '1-5', or '10-20'. PDF has \(totalPages) pages."
                ])
            }
            requestedRange = parsed
        } else if totalPages > FilesystemTools.pdfPagesRequiredThreshold {
            // With the legal toggle on, teach the archival path at the moment of
            // failure: paging a 200-page scan through context in 20-page answers
            // is exactly what save_to exists to avoid. Toggle off keeps the
            // original message — save_to does not exist there.
            let saveToHint = AvailableTools.bulkOCRSaveToEnabled
                ? " To transcribe the whole document, do NOT loop page ranges through context — use save_to to write the OCR to a file, then read or grep the file locally."
                : ""
            throw NSError(domain: "InspectMedia", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "PDF \(url.path) has \(totalPages) pages. Specify a page range via the 'pages' parameter, e.g. pages=\"1-5\". Max \(FilesystemTools.pdfMaxPagesPerCall) pages per call.\(saveToHint)"
            ])
        } else {
            requestedRange = 1...totalPages
        }

        let pageCount = requestedRange.upperBound - requestedRange.lowerBound + 1
        guard pageCount <= FilesystemTools.pdfMaxPagesPerCall else {
            let saveToHint = AvailableTools.bulkOCRSaveToEnabled
                ? " For a range this large, use save_to to write the transcription to a file instead of answering into context."
                : ""
            throw NSError(domain: "InspectMedia", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "page range spans \(pageCount) pages. Max \(FilesystemTools.pdfMaxPagesPerCall) pages per inspect_media call.\(saveToHint)"
            ])
        }

        let data: Data
        if requestedRange.lowerBound == 1 && requestedRange.upperBound == totalPages {
            data = try Data(contentsOf: url)
        } else {
            guard let slicedData = document.sliceData(pages: requestedRange) else {
                throw NSError(domain: "InspectMedia", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "failed to serialize PDF pages \(requestedRange.lowerBound)-\(requestedRange.upperBound)."
                ])
            }
            data = slicedData
        }

        let pageRange = "\(requestedRange.lowerBound)-\(requestedRange.upperBound)"
        return InspectableMediaData(data: data, mimeType: "application/pdf", pageRange: pageRange, totalPages: totalPages)
    }

    private func jsonObjectString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"error":"failed to encode tool result"}"#
        }
        return text
    }
    
    private enum TriageRoutingValidation {
        case failure(String)
        case success(mode: String?, instructions: String?, modelLane: String?)
    }

    /// Validate a triage_model value against the lane configuration for the
    /// active provider. Returns the normalized lane name to store (nil for
    /// "inherit"), or an error JSON string in `error`. Only configured lanes
    /// are accepted — same loud-failure contract as the Agent tool's model
    /// hint.
    private func validateTriageModelLane(_ raw: String?) -> (lane: String?, error: String?) {
        switch SubagentModelLanes.resolve(hint: raw) {
        case .inherit:
            return (nil, nil)
        case .lane(let lane, _):
            return (lane.rawValue, nil)
        case .unconfigured(let lane):
            return (nil, "{\"error\":\"The '\(lane.rawValue)' lane is not configured for the current provider — ask the user to set it with /subagentmodels, or use triage_model='inherit'.\"}")
        case .unknown(let hint):
            return (nil, "{\"error\":\"Invalid triage_model '\(hint)'. Use 'inherit', 'cheap-vision' or 'cheap-text' (configured lanes only).\"}")
        }
    }

    /// Validate the notify/triage_instructions/triage_model triple for
    /// watcher creation or routing updates. Returns the normalized mode to
    /// store (nil = main) plus trimmed instructions and lane, or an error
    /// JSON string.
    private func validateTriageRouting(notify: String?, triageInstructions: String?, triageModel: String? = nil) -> TriageRoutingValidation {
        let trimmedInstructions = triageInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTriageModel = !(triageModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard let raw = notify?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            if let instructions = trimmedInstructions, !instructions.isEmpty {
                return .failure(#"{"error":"triage_instructions requires notify='subagent' or notify='subagent:<name>'."}"#)
            }
            if hasTriageModel {
                return .failure(#"{"error":"triage_model requires notify='subagent' or notify='subagent:<name>' — it selects the model the triage subagent runs on."}"#)
            }
            return .success(mode: nil, instructions: nil, modelLane: nil)
        }
        if raw == "main" {
            if let instructions = trimmedInstructions, !instructions.isEmpty {
                return .failure(#"{"error":"triage_instructions has no effect with notify='main' — route the watcher to a subagent, or omit the instructions."}"#)
            }
            if hasTriageModel {
                return .failure(#"{"error":"triage_model has no effect with notify='main' — fires go straight to you, on your own model."}"#)
            }
            return .success(mode: nil, instructions: nil, modelLane: nil)
        }
        guard raw == "subagent" || raw.hasPrefix("subagent:") else {
            return .failure(#"{"error":"Invalid notify value. Use 'main', 'subagent', or 'subagent:<name>'."}"#)
        }
        var mode = "subagent"
        if raw.hasPrefix("subagent:") {
            let name = String(raw.dropFirst("subagent:".count))
            guard !name.isEmpty, name.count <= 32,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                return .failure(#"{"error":"Invalid triage group name — use 1-32 letters, digits, '-' or '_' after 'subagent:'."}"#)
            }
            mode = "subagent:\(name)"
        }
        guard let instructions = trimmedInstructions, !instructions.isEmpty else {
            return .failure(#"{"error":"notify='subagent' requires triage_instructions — the judgment bar the triage agent applies to every fire (include a catch-all clause: notify on anything genuinely unusual, not only listed conditions)."}"#)
        }
        let laneResult = validateTriageModelLane(triageModel)
        if let error = laneResult.error {
            return .failure(error)
        }
        return .success(mode: mode, instructions: instructions, modelLane: laneResult.lane)
    }

    /// A shared triage group runs ONE model per drain, so all members must
    /// carry the same lane. Given the validated mode and the caller's
    /// triage_model argument (nil = not specified), returns the lane to
    /// store — adopting the group's existing lane when unspecified — or an
    /// error JSON on an explicit mismatch. Non-group modes pass through.
    /// `excluding` skips the row being updated when it already belongs to
    /// the group (its own current lane must not veto its update).
    private func resolveGroupLane(
        mode: String?,
        specified: Bool,
        requestedLane: String?,
        excluding excludedId: UUID? = nil
    ) async -> (lane: String?, error: String?) {
        guard let mode, mode.hasPrefix("subagent:") else { return (requestedLane, nil) }
        let name = String(mode.dropFirst("subagent:".count))
        let members = await ReminderService.shared.getPendingReminders()
            .filter { $0.triageGroup == name && $0.id != excludedId }
        guard let first = members.first else { return (requestedLane, nil) }
        let groupLane = first.triageModelLane
        if !specified { return (groupLane, nil) }
        if requestedLane == groupLane { return (requestedLane, nil) }
        return (nil, "{\"error\":\"Group '\(name)' members run triage_model='\(groupLane ?? "inherit")' — a shared session runs one model per drain, so all members must match. Pass triage_model='\(groupLane ?? "inherit")', or change the whole group first via update_triage on one member (lane changes apply group-wide).\"}")
    }

    /// Enforce the pinned-session lane cap (§4) when a routing choice would
    /// add a NEW triage lane. Returns an error JSON string when full.
    private func checkTriageLaneCapacity(forNewMode mode: String?) async -> String? {
        guard let mode, mode.hasPrefix("subagent") else { return nil }
        if mode.hasPrefix("subagent:") {
            let name = String(mode.dropFirst("subagent:".count))
            let existing = await ReminderService.shared.getPendingReminders()
            if existing.contains(where: { $0.triageGroup == name }) {
                return nil // joins an existing lane
            }
        }
        let lanes = await ReminderService.shared.triageLaneCount()
        if lanes >= ReminderService.maxTriageLanes {
            return "{\"error\":\"Triage session cap reached (\(ReminderService.maxTriageLanes) lanes): pinned watcher sessions bypass normal eviction, so their number is bounded. Route this watcher to notify='main', reuse an existing subagent:<name> group, or delete unused triage-routed watchers first.\"}"
        }
        return nil
    }

    private func executeManageReminders(_ call: ToolCall) async throws -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ManageRemindersArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse manage_reminders arguments"}"#
        }

        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case "set":
            if args.externalTrigger == true {
                // External-trigger watcher: no schedule, no script. Same
                // creation gate as check scripts — registering a standing
                // event channel is a capability only the user should grant.
                guard turnTriggeredByUserText else {
                    return #"{"error":"External-trigger watchers can only be created in a turn the user started by typing a message (not from ambient triggers or subagents). Ask the user to request it directly, then create it in that turn."}"#
                }
                guard let prompt = args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
                    return #"{"error":"For an external-trigger watcher, prompt is required (the instructions your future self receives when events arrive)."}"#
                }
                if let script = args.script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return #"{"error":"external_trigger and script are mutually exclusive — an external watcher has no check script (events are pushed to it)."}"#
                }
                if args.recurrence != nil || args.daysOfWeek != nil {
                    return #"{"error":"external_trigger takes no recurrence — it has no schedule; it fires when events are posted."}"#
                }
                let routing: (mode: String?, instructions: String?, modelLane: String?)
                switch validateTriageRouting(notify: args.notify, triageInstructions: args.triageInstructions, triageModel: args.triageModel) {
                case .failure(let error): return error
                case .success(let mode, let instructions, let modelLane): routing = (mode, instructions, modelLane)
                }
                if let capError = await checkTriageLaneCapacity(forNewMode: routing.mode) {
                    return capError
                }
                let groupLane = await resolveGroupLane(mode: routing.mode, specified: args.triageModel != nil, requestedLane: routing.modelLane)
                if let groupError = groupLane.error { return groupError }
                let reminder = await ReminderService.shared.createExternalTriggerReminder(
                    prompt: prompt,
                    deleteAfterFire: args.deleteAfterFire == true,
                    notifyMode: routing.mode,
                    triageInstructions: routing.instructions,
                    triageModelLane: groupLane.lane
                )
                let cooldownMinutes = Int(ReminderService.externalTriggerCooldownSeconds / 60)
                let routingNote = routing.mode.map {
                    " Fires route to a triage subagent (\($0)) — only escalations reach the main conversation; the triage session id appears in list after the first fire."
                } ?? ""
                return jsonObjectString([
                    "success": true,
                    "reminder_id": reminder.id.uuidString,
                    "trigger_command": "briglia trigger \(reminder.id.uuidString) 'optional payload text'",
                    "message": "External-trigger watcher created. Wire the trigger command into the external system (script, cron job, camera hook — any local process). Delivery: an event after \(cooldownMinutes)+ quiet minutes fires immediately; events arriving within \(cooldownMinutes) minutes of the previous fire are queued and delivered together as one batched fire when the window closes. Events survive daemon restarts.\(routingNote)"
                ])
            }
            guard let triggerDatetime = args.triggerDatetime,
                  let prompt = args.prompt,
                  !triggerDatetime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"For action 'set', trigger_datetime and prompt are required"}"#
            }

            guard let date = parseISO8601Date(triggerDatetime) else {
                return #"{"error":"Invalid datetime format. Use local datetime (e.g., '2026-02-01T09:00:00') or ISO 8601 with offset."}"#
            }

            guard date > Date() else {
                return #"{"error":"Reminder datetime must be in the future"}"#
            }

            // days_of_week takes precedence over recurrence string
            let recurrence: RecurrenceType?
            if let daysArray = args.daysOfWeek, !daysArray.isEmpty {
                guard daysArray.allSatisfy({ $0 >= 1 && $0 <= 7 }) else {
                    return #"{"error":"days_of_week values must be 1-7 (1=Monday, 7=Sunday)"}"#
                }
                recurrence = .daysOfWeek(days: Set(daysArray))
            } else if let recurrenceRaw = args.recurrence?.trimmingCharacters(in: .whitespacesAndNewlines),
               !recurrenceRaw.isEmpty {
                guard let parsed = parseRecurrenceType(recurrenceRaw) else {
                    return #"{"error":"Invalid recurrence. Use daily, weekly, weekdays, weekends, monthly, every_X_minutes, or every_X_hours."}"#
                }
                recurrence = parsed
            } else {
                recurrence = nil
            }

            // For day-of-week recurrence, snap the first occurrence forward to a selected weekday
            let triggerDate = recurrence?.alignedInitialTriggerDate(from: date) ?? date

            let scriptSource = args.script?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reminder: Reminder
            var seedWarning: String? = nil
            if let scriptSource, !scriptSource.isEmpty {
                // Check scripts are persistent agent-authored code. Only turns
                // the human started by typing may create them: ambient turns
                // (emails, bash completions, fired reminders) and subagents
                // carry third-party content that could be steering the agent.
                guard turnTriggeredByUserText else {
                    return #"{"error":"Script-backed reminders can only be created in a turn the user started by typing a message (not from ambient triggers or subagents). Ask the user to request it directly, then create it in that turn."}"#
                }
                guard let scriptRecurrence = recurrence else {
                    return #"{"error":"Script-backed reminders require a recurrence (the polling interval, e.g. every_5_minutes) — without one the check would run once and vanish silently. For a one-time check at a specific time, use a plain reminder and run the check with bash inside that turn."}"#
                }
                if case .custom(let minutes) = scriptRecurrence,
                   minutes < ReminderService.minScriptedIntervalMinutes {
                    return #"{"error":"Script-backed reminders must not poll more often than every \#(ReminderService.minScriptedIntervalMinutes) minutes."}"#
                }
                let routing: (mode: String?, instructions: String?, modelLane: String?)
                switch validateTriageRouting(notify: args.notify, triageInstructions: args.triageInstructions, triageModel: args.triageModel) {
                case .failure(let error): return error
                case .success(let mode, let instructions, let modelLane): routing = (mode, instructions, modelLane)
                }
                if let capError = await checkTriageLaneCapacity(forNewMode: routing.mode) {
                    return capError
                }
                let groupLane = await resolveGroupLane(mode: routing.mode, specified: args.triageModel != nil, requestedLane: routing.modelLane)
                if let groupError = groupLane.error { return groupError }
                do {
                    let created = try await ReminderService.shared.createScriptedReminder(
                        triggerDate: triggerDate,
                        prompt: prompt,
                        recurrence: scriptRecurrence,
                        scriptSource: scriptSource,
                        deleteAfterFire: args.deleteAfterFire == true,
                        notifyMode: routing.mode,
                        triageInstructions: routing.instructions,
                        triageModelLane: groupLane.lane
                    )
                    reminder = created.reminder
                    seedWarning = created.seedOutputWarning
                } catch {
                    return jsonObjectString(["error": "Registration rejected. \(error.localizedDescription)"])
                }
            } else {
                if args.notify != nil || args.triageInstructions != nil || args.triageModel != nil {
                    return #"{"error":"notify/triage_instructions/triage_model apply to watchers only (script-backed or external-trigger) — plain reminders always notify you directly."}"#
                }
                reminder = await ReminderService.shared.addReminder(
                    triggerDate: triggerDate,
                    prompt: prompt,
                    recurrence: recurrence
                )
            }
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .full
            dateFormatter.timeStyle = .short
            var message = "Reminder successfully scheduled"
            if let rec = recurrence {
                message += " (recurring: \(rec.description))"
            }
            if reminder.isScripted {
                message += ". Check script validated (seed run + silent run) and attached: it fires only when it prints output."
                if let seedWarning {
                    message += " \(seedWarning)"
                }
            }
            if reminder.routesToTriage, let mode = reminder.notifyMode {
                message += " Fires route to a triage subagent (\(mode)) — only escalations reach the main conversation."
            }
            let result = SetReminderResult(
                success: true,
                reminderId: reminder.id.uuidString,
                scheduledFor: dateFormatter.string(from: triggerDate),
                message: message
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"message":"Reminder scheduled"}"#

        case "list":
            let reminders = await ReminderService.shared.getPendingReminders()
            if reminders.isEmpty {
                return #"{"success": true, "count": 0, "reminders": [], "message": "No pending reminders"}"#
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short

            let localISOFormatter = DateFormatter()
            localISOFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            localISOFormatter.timeZone = TimeZone.current

            var jsonEntries: [String] = []
            for reminder in reminders {
                let idStr = reminder.id.uuidString
                let triggerLocal = localISOFormatter.string(from: reminder.triggerDate)
                let triggerReadable = dateFormatter.string(from: reminder.triggerDate)
                let promptEscaped = reminder.prompt
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")

                var entryFields = ["\"id\": \"\(idStr)\""]
                if reminder.isExternal {
                    // No schedule: the row fires on posted events, not a clock.
                    entryFields.append("\"external_trigger\": true")
                    entryFields.append("\"trigger_command\": \"briglia trigger \(idStr)\"")
                } else {
                    entryFields.append("\"trigger_datetime\": \"\(triggerLocal)\"")
                    entryFields.append("\"trigger_readable\": \"\(triggerReadable)\"")
                }
                entryFields.append("\"prompt\": \"\(promptEscaped)\"")
                if reminder.isExternal {
                    if reminder.deleteAfterFire == true {
                        entryFields.append("\"delete_after_fire\": true")
                    }
                    if let lastFire = reminder.lastExternalFireDate {
                        entryFields.append("\"last_fire\": \"\(localISOFormatter.string(from: lastFire))\"")
                    }
                }

                if let mode = reminder.notifyMode {
                    entryFields.append("\"notify\": \"\(mode)\"")
                    if let sessionId = reminder.triageSessionId {
                        entryFields.append("\"triage_session_id\": \"\(sessionId)\"")
                    }
                    if let lane = reminder.triageModelLane {
                        entryFields.append("\"triage_model\": \"\(lane)\"")
                    }
                }
                if let telemetry = reminder.telemetry {
                    let stats = telemetry.summaryLine(isScripted: reminder.isScripted)
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    entryFields.append("\"telemetry\": \"\(stats)\"")
                }
                if let rec = reminder.recurrence {
                    entryFields.append("\"recurrence\": \"\(rec.description)\"")
                }
                if let scriptPath = reminder.scriptPath {
                    let pathEscaped = scriptPath
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    entryFields.append("\"script_path\": \"\(pathEscaped)\"")
                    if reminder.deleteAfterFire == true {
                        entryFields.append("\"delete_after_fire\": true")
                    }
                    if let failures = reminder.consecutiveFailures, failures > 0 {
                        entryFields.append("\"consecutive_script_failures\": \(failures)")
                    }
                    if reminder.isPaused {
                        entryFields.append("\"paused\": true")
                        if reminder.isImportQuarantined {
                            entryFields.append("\"import_quarantined\": true")
                            entryFields.append("\"paused_note\": \"Quarantined by a Mind import — this script was never approved on this installation, so action='resume' refuses. Only the user can re-arm it, by typing /resumewatcher \(reminder.id.uuidString) themselves.\"")
                        } else {
                            entryFields.append("\"paused_note\": \"Watcher paused after repeated script failures — not checking. Re-arm with action='resume' if the cause was transient, or delete it.\"")
                        }
                    }
                }
                jsonEntries.append("{\(entryFields.joined(separator: ", "))}")
            }

            let remindersJson = jsonEntries.joined(separator: ", ")
            return "{\"success\": true, \"count\": \(reminders.count), \"reminders\": [\(remindersJson)], \"message\": \"Found \(reminders.count) pending reminder(s)\"}"

        case "delete":
            let pendingReminders = await ReminderService.shared.getPendingReminders()
            var targetIDs: [String] = []
            var deleteMode = "single"

            if args.deleteAll == true {
                targetIDs = pendingReminders.map { $0.id.uuidString }
                deleteMode = "all"
            } else if args.deleteRecurring == true {
                if let recurrenceRaw = args.recurrence?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !recurrenceRaw.isEmpty,
                   parseRecurrenceType(recurrenceRaw) == nil {
                    return #"{"error":"Invalid recurrence filter for delete_recurring. Use daily, weekly, weekdays, weekends, monthly, every_X_minutes, or every_X_hours."}"#
                }

                let recurrenceFilter = parseRecurrenceType(args.recurrence)
                targetIDs = pendingReminders.filter { reminder in
                    guard let recurrence = reminder.recurrence else { return false }
                    if let recurrenceFilter {
                        return recurrence == recurrenceFilter
                    }
                    return true
                }.map { $0.id.uuidString }
                deleteMode = "recurring"
            } else if let reminderIds = args.reminderIds, !reminderIds.isEmpty {
                targetIDs = reminderIds
                deleteMode = "batch"
            } else if let reminderId = args.reminderId, !reminderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                targetIDs = [reminderId]
                deleteMode = "single"
            } else {
                return #"{"error":"For action 'delete', provide one of: reminder_id, reminder_ids, delete_all=true, or delete_recurring=true"}"#
            }

            let normalizedTargetIDs = Array(NSOrderedSet(array: targetIDs.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })) as? [String] ?? []

            if normalizedTargetIDs.isEmpty {
                return #"{"error":"No valid reminder IDs provided for deletion"}"#
            }

            var deletedCount = 0
            var notFoundCount = 0
            var invalidIDs: [String] = []

            for idString in normalizedTargetIDs {
                guard let uuid = UUID(uuidString: idString) else {
                    invalidIDs.append(idString)
                    continue
                }
                let success = await ReminderService.shared.deleteReminder(id: uuid)
                if success {
                    deletedCount += 1
                } else {
                    notFoundCount += 1
                }
            }

            if deleteMode == "single" && normalizedTargetIDs.count == 1 && invalidIDs.isEmpty {
                if deletedCount == 1 {
                    return #"{"success":true,"message":"Reminder deleted successfully","deleted_count":1}"#
                }
                return #"{"error":"Reminder not found with the specified ID"}"#
            }

            let invalidIDsJSON = invalidIDs
                .map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ", ")
            let message = "Deleted \(deletedCount) reminder(s). \(notFoundCount) not found. \(invalidIDs.count) invalid ID(s)."
            return """
            {"success": true, "mode": "\(deleteMode)", "deleted_count": \(deletedCount), "not_found_count": \(notFoundCount), "invalid_ids": [\(invalidIDsJSON)], "message": "\(message)"}
            """

        case "resume":
            // Re-arm a paused watcher. Deliberately NOT gated to user-typed
            // turns: resuming re-runs hash-verified code created in a turn the
            // user started — it cannot introduce or alter code, so it is safe
            // from the ambient failure turn (self-healing after transient
            // outages). The hash is re-verified inside the service.
            // EXCEPTION: watchers quarantined by a Mind import refuse inside
            // the service (importQuarantined provenance) — their scripts were
            // never approved on this installation, so only the user-typed
            // /resumewatcher command can re-arm them.
            guard let reminderId = args.reminderId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let uuid = UUID(uuidString: reminderId) else {
                return #"{"error":"For action 'resume', provide reminder_id (the paused watcher's UUID)."}"#
            }
            switch await ReminderService.shared.resumeScriptedReminder(id: uuid) {
            case .success(let nextCheck):
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .medium
                dateFormatter.timeStyle = .short
                return jsonObjectString([
                    "success": true,
                    "message": "Watcher resumed with its original script (failure streak reset). Next check: \(dateFormatter.string(from: nextCheck)). If it pauses again without a successful run in between, do not resume it again — involve the user."
                ])
            case .failure(let error):
                return jsonObjectString(["error": error.message])
            }

        case "update_triage":
            // Routing and triage instructions decide what silently disappears
            // — same gate as watcher creation: only turns the user started by
            // typing may change them (ambient content must never rewrite the
            // judgment bar).
            guard turnTriggeredByUserText else {
                return #"{"error":"Triage routing and instructions can only be changed in a turn the user started by typing a message (not from ambient triggers or subagents). Ask the user to request it directly, then update it in that turn."}"#
            }
            guard let reminderId = args.reminderId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let uuid = UUID(uuidString: reminderId) else {
                return #"{"error":"For action 'update_triage', provide reminder_id (the watcher's UUID)."}"#
            }
            guard args.notify != nil || args.triageInstructions != nil || args.triageModel != nil else {
                return #"{"error":"For action 'update_triage', provide notify, triage_instructions and/or triage_model."}"#
            }
            // Validate the triple. When only some fields are updated, borrow
            // the row's current values so validation sees the resulting state.
            let current = await ReminderService.shared.reminder(withId: uuid)
            let effectiveNotify = args.notify ?? current?.notifyMode ?? "main"
            let routing: (mode: String?, instructions: String?, modelLane: String?)
            switch validateTriageRouting(
                notify: effectiveNotify,
                triageInstructions: args.triageInstructions ?? current?.triageInstructions,
                triageModel: args.triageModel
            ) {
            case .failure(let error): return error
            case .success(let mode, let instructions, let modelLane): routing = (mode, instructions, modelLane)
            }
            // A move onto a subagent lane (or to a new group) may add a lane.
            if routing.mode != current?.notifyMode,
               let capError = await checkTriageLaneCapacity(forNewMode: routing.mode) {
                return capError
            }
            let newMode: String? = args.notify != nil ? (routing.mode ?? "main") : nil
            let newInstructions: String? = args.triageInstructions != nil ? routing.instructions : nil
            // "inherit" clears the stored lane; nil leaves it unchanged.
            var newLane: String? = args.triageModel != nil ? (routing.modelLane ?? "inherit") : nil
            // Group lane consistency on a JOIN (row moving into a group it
            // isn't in): unspecified lane adopts the group's, an explicit
            // mismatch errors. A lane change on a row ALREADY in the group
            // is the sanctioned way to retune the whole group — the service
            // applies it group-wide, so no consistency check applies.
            let targetGroup: String? = routing.mode.flatMap { m in
                m.hasPrefix("subagent:") ? String(m.dropFirst("subagent:".count)) : nil
            }
            if let g = targetGroup, current?.triageGroup != g {
                let members = await ReminderService.shared.getPendingReminders()
                    .filter { $0.triageGroup == g && $0.id != uuid }
                if let first = members.first {
                    if args.triageModel == nil {
                        newLane = first.triageModelLane ?? "inherit"
                    } else if routing.modelLane != first.triageModelLane {
                        return "{\"error\":\"Group '\(g)' members run triage_model='\(first.triageModelLane ?? "inherit")' — a shared session runs one model per drain, so a joining watcher must match. Omit triage_model to adopt the group's lane, or retune the whole group first (update_triage on an existing member applies group-wide).\"}"
                    }
                }
            }
            switch await ReminderService.shared.updateTriageRouting(id: uuid, notifyMode: newMode, triageInstructions: newInstructions, triageModelLane: newLane) {
            case .success(let updated):
                return jsonObjectString([
                    "success": true,
                    "reminder_id": updated.id.uuidString,
                    "notify": updated.notifyMode ?? "main",
                    "message": updated.routesToTriage
                        ? "Triage routing updated. Fires now go to \(updated.notifyMode!); the session re-binds on the next fire (the previous group's session keeps its own history)."
                        : "Watcher now notifies the main conversation directly; its triage session unpins and ages out normally."
                ])
            case .failure(let error):
                return jsonObjectString(["error": error.message])
            }

        default:
            return #"{"error":"Invalid action. Supported actions: set, list, delete, resume, update_triage"}"#
        }
    }
    // MARK: - Calendar Tool (agentmail provider)

    private func executeManageCalendar(_ call: ToolCall) async -> String {
        // The tool is only exposed for the agentmail provider, but a stale
        // call recorded before a provider switch could still reach here —
        // refuse instead of silently mutating a calendar nothing injects.
        guard EmailCalendarProvider.current == .agentmail else {
            return #"{"error":"manage_calendar is only available while the AgentMail email/calendar provider is active (rerun `briglia setup` to change providers)"}"#
        }
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ManageCalendarArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse manage_calendar arguments"}"#
        }

        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case "view":
            let includePast = args.includePast ?? false
            let events = await CalendarService.shared.getEvents(includePast: includePast)

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            let localISOFormatter = DateFormatter()
            localISOFormatter.locale = Locale(identifier: "en_US_POSIX")
            localISOFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            localISOFormatter.timeZone = TimeZone.current

            let eventList = events.map { event -> CalendarEventResponse in
                CalendarEventResponse(
                    id: event.id.uuidString,
                    title: event.title,
                    datetime: formatter.string(from: event.datetime),
                    datetimeISO: localISOFormatter.string(from: event.datetime),
                    notes: event.notes,
                    isPast: event.datetime < Date()
                )
            }

            let result = ViewCalendarResult(
                success: true,
                eventCount: eventList.count,
                events: eventList,
                message: eventList.isEmpty ? "No events found" : "Found \(eventList.count) event(s)"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"eventCount":0,"events":[]}"#

        case "add":
            guard let title = args.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let datetime = args.datetime, !datetime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"For action 'add', title and datetime are required"}"#
            }
            guard let eventDate = parseISO8601Date(datetime) else {
                return #"{"error":"Invalid datetime format. Use local datetime (e.g., '2026-09-12T15:00:00') or ISO 8601 with offset."}"#
            }

            let event: CalendarEvent
            do {
                event = try await CalendarService.shared.addEvent(
                    title: title,
                    datetime: eventDate,
                    notes: args.notes
                )
            } catch {
                return "{\"error\":\"Could not persist the event (\(error.localizedDescription)) — NOTHING was saved. Check disk space/permissions and retry.\"}"
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .short

            let result = AddCalendarEventResult(
                success: true,
                eventId: event.id.uuidString,
                scheduledFor: formatter.string(from: eventDate),
                message: "Event '\(title)' successfully added to calendar"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"message":"Event added"}"#

        case "edit":
            guard let eventIdRaw = args.eventId else {
                return #"{"error":"For action 'edit', event_id is required"}"#
            }
            let eventUUID: UUID
            switch await CalendarService.shared.resolveEventId(eventIdRaw) {
            case .success(let id): eventUUID = id
            case .failure(let message): return "{\"error\":\"\(message)\"}"
            }

            var newDatetime: Date? = nil
            if let datetimeString = args.datetime {
                guard let parsed = parseISO8601Date(datetimeString) else {
                    return #"{"error":"Invalid datetime format. Use local datetime (e.g., '2026-09-12T15:00:00') or ISO 8601 with offset."}"#
                }
                newDatetime = parsed
            }

            let success: Bool
            do {
                success = try await CalendarService.shared.updateEvent(
                    id: eventUUID,
                    title: args.title,
                    datetime: newDatetime,
                    notes: args.notes
                )
            } catch {
                return "{\"error\":\"Could not persist the change (\(error.localizedDescription)) — the event is UNCHANGED. Check disk space/permissions and retry.\"}"
            }
            if success {
                return #"{"success":true,"message":"Event updated successfully"}"#
            }
            return #"{"error":"Event not found with the specified ID"}"#

        case "delete":
            guard let eventIdRaw = args.eventId else {
                return #"{"error":"For action 'delete', event_id is required"}"#
            }
            let eventUUID: UUID
            switch await CalendarService.shared.resolveEventId(eventIdRaw) {
            case .success(let id): eventUUID = id
            case .failure(let message): return "{\"error\":\"\(message)\"}"
            }

            let success: Bool
            do {
                success = try await CalendarService.shared.deleteEvent(id: eventUUID)
            } catch {
                return "{\"error\":\"Could not persist the deletion (\(error.localizedDescription)) — the event is STILL on the calendar. Check disk space/permissions and retry.\"}"
            }
            if success {
                return #"{"success":true,"message":"Event deleted successfully"}"#
            }
            return #"{"error":"Event not found with the specified ID"}"#

        default:
            return #"{"error":"Invalid action. Supported actions: view, add, edit, delete"}"#
        }
    }

    // MARK: - Helpers

    private func parseISO8601Date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try full ISO 8601 with timezone offset first
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) { return date }

        // Fall back to local time (no offset) — parse in system timezone
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            localFormatter.dateFormat = format
            if let date = localFormatter.date(from: trimmed) { return date }
        }

        return nil
    }

    private func parseRecurrenceType(_ rawValue: String?) -> RecurrenceType? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty else {
            return nil
        }

        switch rawValue {
        case "daily":
            return .daily
        case "weekly":
            return .weekly
        case "monthly":
            return .monthly
        case "weekdays":
            return .daysOfWeek(days: [1, 2, 3, 4, 5])
        case "weekends":
            return .daysOfWeek(days: [6, 7])
        default:
            if rawValue.hasPrefix("every_") && rawValue.hasSuffix("_minutes") {
                let numberPart = rawValue
                    .replacingOccurrences(of: "every_", with: "")
                    .replacingOccurrences(of: "_minutes", with: "")
                if let minutes = Int(numberPart), minutes > 0 {
                    return .custom(minutes: minutes)
                }
            }
            if rawValue.hasPrefix("every_") && rawValue.hasSuffix("_hours") {
                let numberPart = rawValue
                    .replacingOccurrences(of: "every_", with: "")
                    .replacingOccurrences(of: "_hours", with: "")
                if let hours = Int(numberPart), hours > 0 {
                    return .custom(minutes: hours * 60)
                }
            }
            return nil
        }
    }
    
    // MARK: - Conversation History Summaries

    private func executeReadChunkSummaries(_ call: ToolCall) async -> String {
        let maxResults = 15

        var args = ReadChunkSummariesArguments(chunkIds: nil, from: nil, to: nil, before: nil)
        if let argsData = call.function.arguments.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ReadChunkSummariesArguments.self, from: argsData) {
            args = decoded
        }

        let requestedIds = (args.chunkIds ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasDateSelector = args.from != nil || args.to != nil

        guard !requestedIds.isEmpty || hasDateSelector else {
            return "{\"error\": \"Provide chunk_ids (e.g. from a meta-summary row's [Chunks: …] list in your ARCHIVED CONVERSATION HISTORY table) and/or a from/to date range.\"}"
        }

        // Accepts 'YYYY-MM-DD' (local calendar day) or full ISO 8601.
        func parseFlexibleDate(_ raw: String, endOfDay: Bool) -> Date? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let isoWithFraction = ISO8601DateFormatter()
            isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoWithFraction.date(from: trimmed) { return date }
            if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.timeZone = TimeZone.current
            guard let dayStart = dayFormatter.date(from: trimmed) else { return nil }
            return endOfDay ? dayStart.addingTimeInterval(86_399) : dayStart
        }

        var fromDate: Date? = nil
        var toDate: Date? = nil
        var beforeDate: Date? = nil
        for (field, raw, endOfDay) in [("from", args.from, false), ("to", args.to, true), ("before", args.before, false)] {
            guard let raw else { continue }
            guard let parsed = parseFlexibleDate(raw, endOfDay: endOfDay) else {
                return "{\"error\": \"Could not parse \(field) date '\(raw)'. Use 'YYYY-MM-DD' or ISO 8601.\"}"
            }
            switch field {
            case "from": fromDate = parsed
            case "to": toDate = parsed
            default: beforeDate = parsed
            }
        }

        let allChunks = await archiveService.getAllChunks()
        if allChunks.isEmpty {
            return "{\"success\": true, \"message\": \"No archived conversation chunks yet. Chunks are created as conversations grow.\"}"
        }

        let visibleIds = await archiveService.individuallyVisibleChunkIds()
        var notes: [String] = []

        var selectedById: [ConversationChunk] = []
        for rawId in requestedIds {
            let needle = rawId.uppercased()
            let matches = allChunks.filter { $0.id.uuidString.hasPrefix(needle) }
            if matches.isEmpty {
                notes.append("Id '\(rawId)': no archived chunk matches.")
            } else if matches.count > 1 {
                let ids = matches.map { String($0.id.uuidString.prefix(8)) }.joined(separator: ", ")
                notes.append("Id '\(rawId)': ambiguous prefix (matches \(ids)). Repeat with a longer prefix.")
            } else if visibleIds.contains(matches[0].id) {
                notes.append("Id '\(rawId)': its summary is already an individual row in your ARCHIVED CONVERSATION HISTORY table — read it there; for the original messages grep or read_file its transcript file directly.")
            } else {
                selectedById.append(matches[0])
            }
        }

        var selectedByDate: [ConversationChunk] = []
        var skippedInContextCount = 0
        if hasDateSelector {
            selectedByDate = allChunks.filter { chunk in
                if let fromDate, chunk.endDate < fromDate { return false }
                if let toDate, chunk.startDate > toDate { return false }
                return true
            }
            skippedInContextCount = selectedByDate.filter { visibleIds.contains($0.id) }.count
            selectedByDate.removeAll { visibleIds.contains($0.id) }
        }

        var seenIds = Set<UUID>()
        var selected: [ConversationChunk] = []
        for chunk in selectedById + selectedByDate where seenIds.insert(chunk.id).inserted {
            selected.append(chunk)
        }
        if let beforeDate {
            selected.removeAll { $0.endDate >= beforeDate }
        }
        selected.sort { lhs, rhs in
            if lhs.endDate != rhs.endDate {
                return lhs.endDate > rhs.endDate
            }
            return lhs.startDate > rhs.startDate
        }

        let totalMatched = selected.count
        let pageChunks = Array(selected.prefix(maxResults))

        if pageChunks.isEmpty {
            var message = "No chunk summaries to return for this selection."
            if skippedInContextCount > 0 {
                message += " \(skippedInContextCount) matched chunk(s) were skipped because their summaries are already individual rows in your ARCHIVED CONVERSATION HISTORY table."
            }
            if !notes.isEmpty {
                message += "\nNotes:\n- " + notes.joined(separator: "\n- ")
            }
            return message
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        var output = """
        === ARCHIVED CHUNK SUMMARIES ===
        Showing \(pageChunks.count) of \(totalMatched) matched chunk(s), newest first (max \(maxResults) per call)
        Plaintext archive folder: ~/.local/share/briglia/archive/

        Each Transcript below is the plaintext file with the chunk's original User/Assistant messages. Search all chunks with the grep tool on that folder, or pass an exact Transcript path to read_file.

        """

        if skippedInContextCount > 0 {
            output += "Skipped \(skippedInContextCount) matched chunk(s) whose summaries are already individual rows in your ARCHIVED CONVERSATION HISTORY table.\n"
        }
        if !notes.isEmpty {
            output += "Notes:\n- " + notes.joined(separator: "\n- ") + "\n"
        }

        var missingSidecarCount = 0
        for chunk in pageChunks {
            let shortId = String(chunk.id.uuidString.prefix(8))
            let dateRange = "\(dateFormatter.string(from: chunk.startDate)) - \(dateFormatter.string(from: chunk.endDate))"
            let typeLabel = chunk.type == .consolidated ? "CONSOLIDATED" : "TEMPORARY"
            let sidecarPath = "~/.local/share/briglia/archive/\(chunk.id.uuidString).txt"

            // The sidecar is the agent's only content path — if the file is
            // missing, say so explicitly. A silently absent sidecar makes
            // grep misses look like "this was never discussed".
            let sidecarLine: String
            if FileManager.default.fileExists(atPath: (sidecarPath as NSString).expandingTildeInPath) {
                sidecarLine = sidecarPath
            } else {
                missingSidecarCount += 1
                sidecarLine = "MISSING (regeneration triggered — retry shortly; grep will NOT see this chunk until then)"
            }

            output += """

            [\(shortId)] (\(typeLabel), \(chunk.sizeLabel))
            Period: \(dateRange)
            Messages: \(chunk.messageCount)
            Transcript: \(sidecarLine)
            Summary: \(chunk.summary)

            ---
            """
        }

        if missingSidecarCount > 0 {
            // Self-heal without blocking this reply.
            Task { await archiveService.backfillSidecars() }
            output += "\n\nWARNING: \(missingSidecarCount) chunk(s) above have no transcript file yet — cross-chunk grep sweeps are currently blind to them. Regeneration has been triggered; re-run this tool to confirm before trusting a negative search result."
        }

        output += "\n\nUse grep for content search: path = '~/.local/share/briglia/archive/', include = '*.txt', case_insensitive = true, context = 5. Use read_file with the exact Transcript path above to inspect one chunk."
        if totalMatched > pageChunks.count, let oldestShown = pageChunks.last {
            // Fractional seconds keep the cursor exact: a whole-second cursor
            // rounds down on the round-trip and the strict endDate < before
            // filter would then skip unshown chunks ending in the same second.
            let cursorFormatter = ISO8601DateFormatter()
            cursorFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cursor = cursorFormatter.string(from: oldestShown.endDate)
            output += "\nTo continue with the \(totalMatched - pageChunks.count) older matched chunk(s), repeat the call adding before: \"\(cursor)\"."
        }

        return output
    }

    // MARK: - Skills

    /// Load a curated skill from `~/.config/briglia/skills/` and return its body.
    /// Read-only by design: the agent cannot create or modify skills. If the
    /// skill is missing, return the current index so the agent can recover
    /// and pick a valid name.
    private nonisolated func executeLoadSkill(_ call: ToolCall) -> String {
        struct Args: Decodable { let skill_name: String? }
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              let name = args.skill_name?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            return "{\"error\": \"skill_name is required\"}"
        }

        guard let skill = SkillsRegistry.skill(named: name) else {
            let available = SkillsRegistry.allSkills().map { $0.name }
            let availableList = available.isEmpty
                ? "(no skills installed)"
                : available.joined(separator: ", ")
            return "{\"error\": \"Skill '\(name)' not found. Available: \(availableList)\"}"
        }

        // Match Claude Code's skill-loading contract so agentskills.io skills
        // imported from the wider ecosystem work unchanged:
        //   1. Substitute ${CLAUDE_SKILL_DIR} with the real absolute path.
        //   2. Prepend "Base directory for this skill: <path>" so bare
        //      filename references in the body (e.g. "see REFERENCE.md")
        //      have a resolution anchor.
        // Verified against cli.js 2.1.112 — exact same two operations.
        var body = skill.body
        if let dir = skill.directoryURL {
            body = body.replacingOccurrences(
                of: "${CLAUDE_SKILL_DIR}",
                with: dir.path
            )
        }

        var result: String
        if let dir = skill.directoryURL {
            result = "Base directory for this skill: \(dir.path)\n\n" + body
        } else {
            result = "Skill '\(skill.name)' loaded. Follow the procedure below — combine with your own judgment, don't recite verbatim.\n\n" + body
        }

        if !skill.assets.isEmpty {
            var lines: [String] = ["", "", "---", "", "**Assets bundled with this skill** (invoke via the bash tool using the absolute paths below):"]
            for asset in skill.assets {
                lines.append("- `\(asset.path)`")
            }
            result += lines.joined(separator: "\n")
        }
        return result
    }

    // MARK: - Deferred MCP Discovery

    private func executeToolSearch(_ call: ToolCall) async -> String {
        struct Args: Decodable { let server: String? }
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              let server = args.server?.trimmingCharacters(in: .whitespaces),
              !server.isEmpty else {
            return "{\"error\": \"'server' parameter is required.\"}"
        }
        // `server` must be a handle exactly as listed in the on-demand
        // section; raw server names that differ from their handle are not
        // accepted (the registry knows only handles).
        guard let result = await MCPRegistry.shared.toolSchemasForServer(server) else {
            return "{\"error\": \"MCP server '\(MarkerNeutralizer.escape(server))' is not available. Use the server handle exactly as shown in the on-demand MCPs list; the server may also not be installed, or it failed to start.\"}"
        }
        return result
    }

    private func executeMcpCall(_ call: ToolCall) async -> ToolResultMessage {
        guard let data = call.function.arguments.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse mcp_call arguments as JSON object.\"}")
        }
        guard let server = raw["server"] as? String, !server.isEmpty else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"'server' parameter is required.\"}")
        }
        guard let tool = raw["tool"] as? String, !tool.isEmpty else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"'tool' parameter is required.\"}")
        }
        let arguments = raw["arguments"] as? [String: Any] ?? [:]

        // Serialize arguments and resolve (handle, tool alias/segment) through
        // the accepted-tool registry — reuses all existing validation & dispatch.
        let argsJSON: String
        if arguments.isEmpty {
            argsJSON = "{}"
        } else if let argsData = try? JSONSerialization.data(withJSONObject: arguments),
                  let str = String(data: argsData, encoding: .utf8) {
            argsJSON = str
        } else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to serialize arguments to JSON.\"}")
        }
        let result = await MCPRegistry.shared.callTool(serverHandle: server, tool: tool, argumentsJSON: argsJSON)
        return mcpToolResultMessage(call, result)
    }

    /// Convert an MCP tool-call result into a ToolResultMessage, routing image
    /// content blocks (e.g. Playwright screenshots) into the standard attachment
    /// pipeline: saved to the images directory, injected as a user-role
    /// multimodal message after the tool results, and OCR-proxied for text-only
    /// models — instead of being dropped as textual stubs.
    private func mcpToolResultMessage(_ call: ToolCall, _ result: MCPToolCallResult) -> ToolResultMessage {
        // MCP text is a second entry path for tool output next to bash: scrub
        // the redaction set (service keys, Telegram bot token) here, before the
        // marker-neutralizing render, so a server echoing a secret cannot put
        // it in the transcript either.
        let text = Self.redactedMCPText(result.text)
        guard !result.images.isEmpty else {
            return ToolResultMessage(toolCallId: call.id, content: text)
        }

        let maxAttached = 5
        var attachments: [FileAttachment] = []
        var savedNames: [String] = []
        for (idx, image) in result.images.prefix(maxAttached).enumerated() {
            var data = image.data
            var mime = image.mimeType
            if let downscaled = FilesystemTools.downscaledForModelBudget(data) {
                data = downscaled.data
                mime = downscaled.mimeType
            }
            let fileName = "mcp_image_\(UUID().uuidString.prefix(8))_\(idx + 1).\(Self.fileExtension(forImageMime: mime))"
            let fileURL = imagesDirectory.appendingPathComponent(fileName)
            do {
                try PrivateStorage.writeAtomically(data, to: fileURL)
            } catch {
                print("[ToolExecutor] Failed to save MCP image \(fileName): \(error)")
                // Continue anyway — the in-memory attachment still reaches the model.
            }
            if allowsUserVisibleToolOutputs {
                ToolExecutor.queueFileForDescription(filename: fileName, data: data, mimeType: mime)
            }
            attachments.append(FileAttachment(data: data, mimeType: mime, filename: fileName, sourcePath: fileURL.path))
            savedNames.append(fileName)
        }

        var note = "[\(attachments.count) image(s) attached as \(savedNames.joined(separator: ", ")) — visible on the next turn as a user-role multimodal message]"
        if result.images.count > maxAttached {
            note += " [\(result.images.count - maxAttached) additional image(s) not attached to limit context size]"
        }
        return ToolResultMessage(
            toolCallId: call.id,
            content: text + "\n\n" + note,
            fileAttachments: attachments
        )
    }

    /// Redaction applied to every textual MCP tool result (same set as bash output).
    static func redactedMCPText(_ text: String) -> String {
        BashTools.SecretRedactor().redact(text)
    }

    /// File extension for an image MIME type (used when persisting MCP image blocks).
    private static func fileExtension(forImageMime mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "png"
        }
    }
}

// MARK: - Tool Argument Types

private func normalizeRecipientList(_ recipients: [String]) -> [String] {
    var seen: Set<String> = []
    var normalized: [String] = []
    
    for recipient in recipients {
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        guard seen.insert(key).inserted else { continue }
        normalized.append(trimmed)
    }
    
    return normalized
}

private func parseRecipientsFromString(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    
    if let data = trimmed.data(using: .utf8),
       let parsed = try? JSONDecoder().decode([String].self, from: data) {
        return normalizeRecipientList(parsed)
    }
    
    let split = trimmed.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)
    return normalizeRecipientList(split)
}

private func decodeRecipients<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> [String] {
    if let array = try? container.decodeIfPresent([String].self, forKey: key) {
        return normalizeRecipientList(array ?? [])
    }
    
    if let value = try? container.decode(String.self, forKey: key) {
        return parseRecipientsFromString(value)
    }
    
    return []
}

private func isLikelyValidEmailAddress(_ address: String) -> Bool {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.contains("@") && trimmed.contains(".")
}

private func allEmailAddressesAreValid(_ addresses: [String]) -> Bool {
    addresses.allSatisfy { isLikelyValidEmailAddress($0) }
}

struct WebSearchArguments: Codable {
    let query: String
}

struct BashWatchArguments: Codable {
    let handle: String
    let pattern: String
    let limit: Int?
}

struct ManageRemindersArguments: Codable {
    let action: String
    let triggerDatetime: String?
    let prompt: String?
    let recurrence: String?
    let daysOfWeek: [Int]?
    let reminderId: String?
    let reminderIds: [String]?
    let deleteAll: Bool?
    let deleteRecurring: Bool?
    let script: String?
    let deleteAfterFire: Bool?
    let externalTrigger: Bool?
    let notify: String?
    let triageInstructions: String?
    let triageModel: String?

    enum CodingKeys: String, CodingKey {
        case action
        case triggerDatetime = "trigger_datetime"
        case prompt
        case recurrence
        case daysOfWeek = "days_of_week"
        case reminderId = "reminder_id"
        case reminderIds = "reminder_ids"
        case deleteAll = "delete_all"
        case deleteRecurring = "delete_recurring"
        case script
        case deleteAfterFire = "delete_after_fire"
        case externalTrigger = "external_trigger"
        case notify
        case triageInstructions = "triage_instructions"
        case triageModel = "triage_model"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        triggerDatetime = try container.decodeIfPresent(String.self, forKey: .triggerDatetime)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        recurrence = try container.decodeIfPresent(String.self, forKey: .recurrence)
        reminderId = try container.decodeIfPresent(String.self, forKey: .reminderId)
        deleteAll = try container.decodeIfPresent(Bool.self, forKey: .deleteAll)
        deleteRecurring = try container.decodeIfPresent(Bool.self, forKey: .deleteRecurring)
        script = try container.decodeIfPresent(String.self, forKey: .script)
        deleteAfterFire = try container.decodeIfPresent(Bool.self, forKey: .deleteAfterFire)
        externalTrigger = try container.decodeIfPresent(Bool.self, forKey: .externalTrigger)
        notify = try container.decodeIfPresent(String.self, forKey: .notify)
        triageInstructions = try container.decodeIfPresent(String.self, forKey: .triageInstructions)
        triageModel = try container.decodeIfPresent(String.self, forKey: .triageModel)

        // Parse days_of_week — accept array of ints or JSON string
        if let array = try? container.decodeIfPresent([Int].self, forKey: .daysOfWeek) {
            daysOfWeek = array
        } else if let raw = (try? container.decodeIfPresent(String.self, forKey: .daysOfWeek))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([Int].self, from: data) {
            daysOfWeek = parsed
        } else {
            daysOfWeek = nil
        }

        if let array = try? container.decodeIfPresent([String].self, forKey: .reminderIds) {
            reminderIds = array
        } else if let raw = (try? container.decodeIfPresent(String.self, forKey: .reminderIds))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                reminderIds = parsed
            } else {
                let csv = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                reminderIds = csv.isEmpty ? nil : csv
            }
        } else {
            reminderIds = nil
        }
    }
}

struct SetReminderResult: Codable {
    let success: Bool
    let reminderId: String
    let scheduledFor: String
    let message: String
}



// MARK: - Calendar Tool Argument Types

struct ManageCalendarArguments: Codable {
    let action: String
    let includePast: Bool?
    let eventId: String?
    let title: String?
    let datetime: String?
    let notes: String?
    
    enum CodingKeys: String, CodingKey {
        case action
        case includePast = "include_past"
        case eventId = "event_id"
        case title
        case datetime
        case notes
    }
}

// MARK: - Calendar Tool Result Types

struct CalendarEventResponse: Codable {
    let id: String
    let title: String
    let datetime: String
    let datetimeISO: String
    let notes: String?
    let isPast: Bool
}

struct ViewCalendarResult: Codable {
    let success: Bool
    let eventCount: Int
    let events: [CalendarEventResponse]
    let message: String
}

struct AddCalendarEventResult: Codable {
    let success: Bool
    let eventId: String
    let scheduledFor: String
    let message: String
}

// MARK: - Conversation History Listing Types

struct ReadChunkSummariesArguments: Codable {
    let chunkIds: [String]?
    let from: String?
    let to: String?
    let before: String?

    enum CodingKeys: String, CodingKey {
        case chunkIds = "chunk_ids"
        case from, to, before
    }
}

// MARK: - Email Tool Types

// MARK: - Email Tool Execution Extension

struct ListDocumentsResult: Codable {
    let success: Bool
    let documentCount: Int
    let returnedCount: Int
    let hasMore: Bool
    let nextCursor: String?
    let order: String
    let cursorUsed: String?
    let documents: [DocumentInfo]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success
        case documentCount
        case returnedCount = "returned_count"
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
        case order
        case cursorUsed = "cursor_used"
        case documents
        case message
    }
}

struct DocumentInfo: Codable {
    let filename: String
    let sizeKB: Int
    let type: String
    let createdAt: String
    let lastOpenedAt: String?
    let createdAtSource: String
    
    enum CodingKeys: String, CodingKey {
        case filename
        case sizeKB
        case type
        case createdAt = "created_at"
        case lastOpenedAt = "last_opened_at"
        case createdAtSource = "created_at_source"
    }
}

struct ReadDocumentArguments: Decodable {
    let documentFilenames: [String]
    
    enum CodingKeys: String, CodingKey {
        case documentFilename = "document_filename"
        case documentFilenames = "document_filenames"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let parsedFilenames: [String]
        if let array = try? container.decode([String].self, forKey: .documentFilenames) {
            parsedFilenames = array
        } else if let raw = (try? container.decode(String.self, forKey: .documentFilenames))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                parsedFilenames = parsed
            } else {
                parsedFilenames = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        } else if let singleFilename = try? container.decode(String.self, forKey: .documentFilename) {
            parsedFilenames = [singleFilename]
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .documentFilenames,
                in: container,
                debugDescription: "Provide document_filenames (array/JSON array string/CSV) or legacy document_filename"
            )
        }
        
        let normalized = parsedFilenames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var seen: Set<String> = []
        let deduplicated = normalized.filter { seen.insert($0).inserted }
        
        guard !deduplicated.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .documentFilenames,
                in: container,
                debugDescription: "No document filenames provided"
            )
        }
        
        documentFilenames = deduplicated
    }
}

struct ReadDocumentItemResult: Codable {
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case filename
        case mimeType
        case sizeBytes
        case message
    }
}

struct ReadDocumentResult: Codable {
    let success: Bool
    let loadedCount: Int
    let maxDocumentsPerCall: Int
    let documents: [ReadDocumentItemResult]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success
        case loadedCount
        case maxDocumentsPerCall = "max_documents_per_call"
        case documents
        case message
    }
}

// MARK: - Document Tool Execution Extension

extension ToolExecutor {
    private var documentsDirectory: URL {
        let folder = StoragePaths.dataRoot.appendingPathComponent("documents", isDirectory: true)
        try? PrivateStorage.ensureDirectory(folder)
        return folder
    }

    private var documentsLastOpenedIndexURL: URL {
        let folder = StoragePaths.dataRoot
        try? PrivateStorage.ensureDirectory(folder)
        return folder.appendingPathComponent("documents_last_opened.json")
    }

    private func loadDocumentsLastOpenedIndex() -> [String: Int64] {
        guard let data = try? Data(contentsOf: documentsLastOpenedIndexURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
    }

    private func saveDocumentsLastOpenedIndex(_ index: [String: Int64]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? PrivateStorage.writeAtomically(data, to: documentsLastOpenedIndexURL)
    }

    private func recordDocumentOpened(filename: String, openedAt: Date = Date()) {
        var index = loadDocumentsLastOpenedIndex()
        index[filename] = Int64((openedAt.timeIntervalSince1970 * 1000.0).rounded())
        saveDocumentsLastOpenedIndex(index)
    }
    
    private func parseListDocumentsCursor(_ cursor: String) -> Int? {
        let trimmed = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        if let offset = Int(trimmed), offset >= 0 {
            return offset
        }
        
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("offset:") {
            let value = trimmed.dropFirst("offset:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if let offset = Int(value), offset >= 0 {
                return offset
            }
        }
        
        return nil
    }
    private func getMimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "xml": return "application/xml"
        case "csv": return "text/csv"
        case "zip": return "application/zip"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        default: return FilesystemTools.mimeType(forPath: filename)
        }
    }
    
    private func isInlineMimeTypeSupportedForLLM(_ mimeType: String) -> Bool {
        let normalized = mimeType
            .lowercased()
            .split(separator: ";")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? mimeType.lowercased()
        
        if normalized.hasPrefix("image/") {
            return true
        }

        if normalized == "application/pdf" {
            return true
        }

        if normalized.hasPrefix("text/") {
            return true
        }

        let textLikeApplicationTypes: Set<String> = [
            "application/json",
            "application/javascript",
            "application/x-javascript",
            "application/typescript",
            "application/xml",
            "application/yaml",
            "application/x-yaml",
            "application/toml",
            "application/x-toml",
            "application/x-sh",
            "application/x-shellscript",
            "application/sql",
            "application/graphql",
            "application/ld+json",
            "application/manifest+json"
        ]

        return textLikeApplicationTypes.contains(normalized)
            || normalized.hasSuffix("+json")
            || normalized.hasSuffix("+xml")
            || normalized.hasSuffix("+yaml")
    }
}

// MARK: - Download Email Attachment Types

// MARK: - Batch Download Types

// MARK: - Get Email Thread Types

// MARK: - Get Email Thread Execution

extension ToolExecutor {
    
}

// MARK: - Contact Tool Argument Types

// MARK: - Contact Tool Result Types

struct ContactResponse: Codable {
    let id: String
    let firstName: String
    let lastName: String?
    let fullName: String
    let email: String?
    let phone: String?
    let organization: String?
}

struct FindContactResult: Codable {
    let success: Bool
    let contactCount: Int
    let contacts: [ContactResponse]
    let message: String
}

struct AddContactResult: Codable {
    let success: Bool
    let contactId: String
    let fullName: String
    let message: String
}

struct ListContactsResult: Codable {
    let success: Bool
    let totalCount: Int
    let returnedCount: Int
    let limit: Int
    let nextCursor: String?
    let cursorUsed: String?
    let contacts: [ContactResponse]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success
        case totalCount = "total_count"
        case returnedCount = "returned_count"
        case limit
        case nextCursor = "next_cursor"
        case cursorUsed = "cursor_used"
        case contacts
        case message
    }
}

struct DeleteContactsResult: Codable {
    let success: Bool
    let deletedCount: Int
    let failedIds: [String]?
    let message: String
}

// MARK: - Image Generation Tool

extension ToolExecutor {
    private static let pendingToolOutputsLock = NSLock()

    /// Store for generated images to be sent after tool execution
    private static var pendingImages: [(data: Data, mimeType: String, prompt: String)] = []
    
    /// Store for documents to be sent after tool execution
    private static var pendingDocuments: [(data: Data, filename: String, mimeType: String, caption: String?)] = []
    
    /// Legacy transient store for downloaded attachment bytes. ConversationManager
    /// drains this after each turn; durable descriptions are generated at prune time.
    private static var pendingFilesForDescription: [(filename: String, data: Data, mimeType: String)] = []
    
    /// Store for downloaded filenames to add to Message history
    private static var pendingDownloadedFilenames: [String] = []
    
    /// Get and clear pending images
    static func getPendingImages() -> [(data: Data, mimeType: String, prompt: String)] {
        pendingToolOutputsLock.lock()
        defer { pendingToolOutputsLock.unlock() }
        let images = pendingImages
        pendingImages = []
        return images
    }
    
    /// Get and clear pending documents
    static func getPendingDocuments() -> [(data: Data, filename: String, mimeType: String, caption: String?)] {
        pendingToolOutputsLock.lock()
        defer { pendingToolOutputsLock.unlock() }
        let documents = pendingDocuments
        pendingDocuments = []
        return documents
    }
    
    /// Get and clear transient downloaded attachment bytes
    static func getPendingFilesForDescription() -> [(filename: String, data: Data, mimeType: String)] {
        pendingToolOutputsLock.lock()
        defer { pendingToolOutputsLock.unlock() }
        let files = pendingFilesForDescription
        pendingFilesForDescription = []
        return files
    }
    
    /// Get and clear downloaded filenames to store in Message history
    static func getPendingDownloadedFilenames() -> [String] {
        pendingToolOutputsLock.lock()
        defer { pendingToolOutputsLock.unlock() }
        let filenames = pendingDownloadedFilenames
        pendingDownloadedFilenames = []
        return filenames
    }
    
    /// Clear all pending tool outputs (used for cancellation / interruption)
    static func clearPendingToolOutputs() {
        pendingToolOutputsLock.lock()
        defer { pendingToolOutputsLock.unlock() }
        pendingImages = []
        pendingDocuments = []
        pendingFilesForDescription = []
        pendingDownloadedFilenames = []
    }

    private static func queuePendingImage(data: Data, mimeType: String, prompt: String) {
        pendingToolOutputsLock.lock()
        pendingImages.append((data, mimeType, prompt))
        pendingToolOutputsLock.unlock()
    }

    private static func queuePendingDocument(data: Data, filename: String, mimeType: String, caption: String?) {
        pendingToolOutputsLock.lock()
        pendingDocuments.append((data: data, filename: filename, mimeType: mimeType, caption: caption))
        pendingToolOutputsLock.unlock()
    }
    
    /// Queue a downloaded/generated filename for history and drainable transient bytes
    static func queueFileForDescription(filename: String, data: Data, mimeType: String) {
        pendingToolOutputsLock.lock()
        defer { pendingToolOutputsLock.unlock() }
        pendingFilesForDescription.append((filename: filename, data: data, mimeType: mimeType))
        // Also track filename for Message history
        pendingDownloadedFilenames.append(filename)
    }
    
    /// Images directory for loading source images
    private var imagesDirectory: URL {
        return StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
    }

    private func configuredGeminiImagePricing() -> GeminiImagePricing {
        func configuredRate(for key: String, defaultValue: Double) -> Double {
            guard let rawValue = KeychainHelper.load(key: key),
                  let parsedValue = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  parsedValue.isFinite,
                  parsedValue >= 0 else {
                return defaultValue
            }
            return parsedValue
        }

        return GeminiImagePricing(
            inputCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.inputCostPerMillionTokensUSD
            ),
            outputTextCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.outputTextCostPerMillionTokensUSD
            ),
            outputImageCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.outputImageCostPerMillionTokensUSD
            )
        )
    }

    private func promptWithSourceImageRole(_ role: String?, prompt: String) -> String {
        let normalizedRole = role?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedRole {
        case "reference":
            return "Use the input image as loose visual reference or inspiration, not as a strict edit target. \(prompt)"
        case "edit":
            return "Edit the input image directly while preserving relevant original content. \(prompt)"
        case "transform":
            return "Transform or reimagine the input image according to the request while preserving the important subject or concept. \(prompt)"
        default:
            return prompt
        }
    }
    
    func executeGenerateImage(_ call: ToolCall) async -> ToolResultMessage {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GenerateImageArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse generate_image arguments\"}")
        }
        
        // Load source image if provided
        var sourceImageData: Data? = nil
        var sourceMimeType: String? = nil
        
        if let sourceImage = args.sourceImage, !sourceImage.isEmpty {
            let imageURL = imagesDirectory.appendingPathComponent(sourceImage)
            
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Source image not found: \(sourceImage). Make sure the filename is correct.\"}")
            }
            
            do {
                sourceImageData = try Data(contentsOf: imageURL)
                // Determine MIME type from extension
                let ext = imageURL.pathExtension.lowercased()
                switch ext {
                case "jpg", "jpeg":
                    sourceMimeType = "image/jpeg"
                case "png":
                    sourceMimeType = "image/png"
                case "gif":
                    sourceMimeType = "image/gif"
                case "webp":
                    sourceMimeType = "image/webp"
                default:
                    sourceMimeType = "image/jpeg"
                }
            } catch {
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to load source image: \(error.localizedDescription)\"}")
            }
        }
        
        let provider = ImageGenerationProvider.fromStoredValue(
            KeychainHelper.load(key: KeychainHelper.imageGenerationProviderKey)
        )
        let requestedSize = args.size?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        do {
            let imageResult: (data: Data, mimeType: String, spendUSD: Double?)
            let resolvedImageSize: String
            var imageMetadata: [String: Any] = [:]

            switch provider {
            case .gemini:
                guard let geminiApiKey = KeychainHelper.load(key: KeychainHelper.geminiApiKeyKey),
                      !geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Gemini API key is not configured. Please add your Google API key in Settings.\"}")
                }

                let geminiImageSize = GeminiImageSize.parse(requestedSize)
                if let requestedSize, !requestedSize.isEmpty, geminiImageSize == nil {
                    let escapedSize = requestedSize
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    return ToolResultMessage(
                        toolCallId: call.id,
                        content: "{\"error\": \"Invalid Gemini size '\(escapedSize)'. Supported values: 1K, 2K, 4K.\"}"
                    )
                }

                let configuredModel = (KeychainHelper.load(key: KeychainHelper.geminiImageModelKey) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await GeminiImageService.shared.configure(
                    apiKey: geminiApiKey,
                    model: configuredModel.isEmpty ? GeminiImagePricing.defaultModel : configuredModel,
                    pricing: configuredGeminiImagePricing()
                )
                imageResult = try await GeminiImageService.shared.generateImage(
                    prompt: args.prompt,
                    sourceImageData: sourceImageData,
                    sourceMimeType: sourceMimeType,
                    imageSize: geminiImageSize?.rawValue
                )
                resolvedImageSize = geminiImageSize?.rawValue ?? "default"

            case .openAI:
                guard let openAIAPIKey = KeychainHelper.load(key: KeychainHelper.openAIImageApiKeyKey),
                      !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"OpenAI image API key is not configured. Please add your OpenAI API key in Settings.\"}")
                }

                let openAIImageSize = OpenAIImageSize.parse(requestedSize)
                if let requestedSize, !requestedSize.isEmpty, openAIImageSize == nil {
                    let escapedSize = requestedSize
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    return ToolResultMessage(
                        toolCallId: call.id,
                        content: "{\"error\": \"Invalid OpenAI image size '\(escapedSize)'. Use auto or WIDTHxHEIGHT with max edge <= 3840, both edges multiples of 16, aspect ratio <= 3:1, and total pixels between 655360 and 8294400.\"}"
                    )
                }

                let openAIPrompt = sourceImageData == nil
                    ? args.prompt
                    : promptWithSourceImageRole(args.sourceImageRole, prompt: args.prompt)
                await OpenAIImageService.shared.configure(
                    apiKey: openAIAPIKey,
                    model: KeychainHelper.load(key: KeychainHelper.openAIImageModelKey),
                    preciseModel: KeychainHelper.load(key: KeychainHelper.openAIImagePreciseModelKey),
                    quality: KeychainHelper.load(key: KeychainHelper.openAIImageQualityKey),
                    outputFormat: KeychainHelper.load(key: KeychainHelper.openAIImageOutputFormatKey),
                    moderation: KeychainHelper.load(key: KeychainHelper.openAIImageModerationKey)
                )
                let openAIResult = try await OpenAIImageService.shared.generateImage(
                    prompt: openAIPrompt,
                    sourceImageData: sourceImageData,
                    sourceMimeType: sourceMimeType,
                    imageSize: openAIImageSize?.rawValue,
                    engine: args.engine,
                    quality: args.quality,
                    outputFormat: args.outputFormat,
                    outputCompression: args.outputCompression,
                    background: args.background,
                    moderation: args.moderation
                )
                imageResult = (openAIResult.data, openAIResult.mimeType, openAIResult.spendUSD)
                imageMetadata = ["engine": openAIResult.options.engine, "model": openAIResult.options.model,
                                 "quality": openAIResult.options.quality, "background": openAIResult.options.background,
                                 "output_format": openAIResult.options.outputFormat, "notes": openAIResult.options.notes]
                resolvedImageSize = openAIImageSize?.rawValue ?? "default"
            }

            let imageData = imageResult.data
            let mimeType = imageResult.mimeType
            let spendUSD = imageResult.spendUSD
            
            // Save generated image to documents folder so Gemini can reference it later
            let fileExtension: String
            switch mimeType.lowercased() {
            case let type where type.contains("png"):
                fileExtension = "png"
            case let type where type.contains("webp"):
                fileExtension = "webp"
            default:
                fileExtension = "jpg"
            }
            let fileName = "generated_\(UUID().uuidString).\(fileExtension)"
            let documentsURL = documentsDirectory.appendingPathComponent(fileName)
            let imagesURL = imagesDirectory.appendingPathComponent(fileName)
            
            do {
                try PrivateStorage.writeAtomically(imageData, to: documentsURL)
                try PrivateStorage.writeAtomically(imageData, to: imagesURL)
                print("[ToolExecutor] Saved generated image: \(fileName) (\(imageData.count) bytes)")
            } catch {
                print("[ToolExecutor] Failed to save generated image: \(error)")
                // Continue anyway - we can still send to Telegram and inject multimodally
            }
            
            if allowsUserVisibleToolOutputs {
                // Main-agent generated images are sent after the turn and tracked in
                // conversation history. Subagents only return the file path/result.
                ToolExecutor.queuePendingImage(data: imageData, mimeType: mimeType, prompt: args.prompt)
                ToolExecutor.queueFileForDescription(filename: fileName, data: imageData, mimeType: mimeType)
            }
            
            let isEdit = sourceImageData != nil
            
            // Create file attachment for multimodal injection (LLM can see the generated image)
            let attachment = FileAttachment(data: imageData, mimeType: mimeType, filename: fileName, sourcePath: documentsURL.path)
            print("[ToolExecutor] Created FileAttachment for generated image: \(fileName) (\(mimeType), \(imageData.count) bytes)")
            
            // Result text (image will be injected as multimodal content)
            var result = """
            {"success": true, "provider": "\(provider.toolName)", "filename": "\(fileName)", "mimeType": "\(mimeType)", "sizeBytes": \(imageData.count), "resolution": "\(resolvedImageSize)", "message": "\(isEdit ? "Image transformed" : "Image generated") successfully. You can now see and analyze the result."}
            """
            
            if !imageMetadata.isEmpty, let data = result.data(using: .utf8),
               var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object.merge(imageMetadata) { _, new in new }
                result = jsonObjectString(object)
            }

            await ToolServiceHealth.shared.recordSuccess(.imageGeneration)
            return ToolResultMessage(
                toolCallId: call.id,
                content: result,
                fileAttachment: attachment,
                spendUSD: spendUSD
            )
        } catch OpenAIImageError.invalidOptions(let message) {
            return ToolResultMessage(toolCallId: call.id, content: jsonObjectString(["error": message]))
        } catch {
            await ToolServiceHealth.shared.recordFailure(.imageGeneration, error: error.localizedDescription)
            return ToolResultMessage(toolCallId: call.id, content: jsonObjectString(["error": "Image generation failed: \(error.localizedDescription)"]))
        }
    }
    
    // MARK: - macOS Shortcuts Tool Implementations

    private func compactJSONObject(_ dictionary: [String: Any?]) -> [String: Any] {
        dictionary.compactMapValues { value in
            switch value {
            case let string as String: return string
            case let int as Int: return int
            case let bool as Bool: return bool
            case let strings as [String]: return strings
            default: return nil
            }
        }
    }

    private func syntheticToolCall(from call: ToolCall, name: String, arguments: [String: Any]) -> ToolCall? {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return ToolCall(
            id: call.id,
            type: call.type,
            function: FunctionCall(name: name, arguments: json)
        )
    }

    private func executeShortcuts(_ call: ToolCall) async -> ToolResultMessage {
        #if !os(macOS)
        return ToolResultMessage(toolCallId: call.id, content: #"{"error": "The shortcuts tool is only available on macOS."}"#)
        #else
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ShortcutsArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: #"{"error": "Failed to parse shortcuts arguments"}"#)
        }

        switch args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "list":
            let content = await executeListShortcuts(call)
            return ToolResultMessage(toolCallId: call.id, content: content)

        case "run":
            guard let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return ToolResultMessage(toolCallId: call.id, content: #"{"error": "shortcuts action='run' requires a non-empty name"}"#)
            }

            guard let syntheticCall = syntheticToolCall(
                from: call,
                name: "run_shortcut",
                arguments: compactJSONObject([
                    "name": name,
                    "input": args.input?.trimmingCharacters(in: .whitespacesAndNewlines)
                ])
            ) else {
                return ToolResultMessage(toolCallId: call.id, content: #"{"error": "Failed to prepare shortcuts run arguments"}"#)
            }

            return await executeRunShortcut(syntheticCall)

        default:
            return ToolResultMessage(
                toolCallId: call.id,
                content: #"{"error": "Unknown shortcuts action. Use 'list' or 'run'."}"#
            )
        }
        #endif
    }

    private func executeListShortcuts(_ call: ToolCall) async -> String {
        if Task.isCancelled {
            return #"{"error": "Shortcut listing cancelled"}"#
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            registerRunningProcess(process)
            defer { ToolExecutor.unregisterRunningProcess(process) }
            
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if process.isRunning {
                        process.interrupt()
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            if process.isRunning {
                await Self.waitForProcessExit(process, timeoutNanoseconds: 500_000_000)
            }
            if process.isRunning {
                let pid = process.processIdentifier
                if pid > 0 {
                    _ = kill(pid, SIGKILL)
                }
                await Self.waitForProcessExit(process, timeoutNanoseconds: 500_000_000)
            }
            
            if Task.isCancelled {
                return #"{"error": "Shortcut listing cancelled"}"#
            }
            
            if process.isRunning {
                return #"{"error": "Shortcut listing did not terminate cleanly"}"#
            }
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            
            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                return "{\"error\": \"Failed to list shortcuts: \(errorOutput.isEmpty ? "Unknown error" : errorOutput)\"}"
            }
            
            // Parse the output - each line is a shortcut name
            let shortcuts = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            if shortcuts.isEmpty {
                return "{\"success\": true, \"count\": 0, \"shortcuts\": [], \"message\": \"No shortcuts found. Create shortcuts in the Shortcuts app.\"}"
            }
            
            let shortcutList = shortcuts.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
            return "{\"success\": true, \"count\": \(shortcuts.count), \"shortcuts\": [\(shortcutList)], \"message\": \"Found \(shortcuts.count) shortcut(s). Use shortcuts with action='run' and the exact name to execute.\"}"
        } catch {
            return "{\"error\": \"Failed to execute shortcuts command: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeRunShortcut(_ call: ToolCall) async -> ToolResultMessage {
        if Task.isCancelled {
            return ToolResultMessage(toolCallId: call.id, content: #"{"error":"Shortcut execution cancelled"}"#)
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(RunShortcutArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse run_shortcut arguments\"}")
        }
        
        let shortcutName = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortcutName.isEmpty else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Shortcut name cannot be empty\"}")
        }
        
        let sandboxedTempDir = FileManager.default.temporaryDirectory
        
        // If input is provided, write it to the sandboxed temp dir (app owns it, CLI can read it)
        var inputFile: URL? = nil
        if let input = args.input, !input.isEmpty {
            inputFile = sandboxedTempDir.appendingPathComponent("shortcut_input_\(UUID().uuidString).txt")
            do {
                try input.write(to: inputFile!, atomically: true, encoding: .utf8)
                print("[ToolExecutor] Input file written to: \(inputFile!.path)")
            } catch {
                print("[ToolExecutor] Failed to write input file: \(error)")
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to write input file: \(error.localizedDescription)\"}")
            }
        }
        
        let timeoutSeconds: Double = 120
        
        var finalOutputData = Data()
        var exitCode: Int32 = 0
        var appleEventsPermissionDenied = false
        var appleScriptErrorText = ""
        
        // PRIMARY: Use Shortcuts Events (AppleScript), which is working on this machine.
        print("[ToolExecutor] Starting shortcut '\(shortcutName)' via AppleScript Shortcuts Events")
        let appleScriptPrimary = await runShortcutViaAppleScript(name: shortcutName, input: args.input, timeoutSeconds: timeoutSeconds)
        exitCode = appleScriptPrimary.exitCode
        
        if appleScriptPrimary.exitCode == 0, !appleScriptPrimary.outputData.isEmpty {
            finalOutputData = appleScriptPrimary.outputData
            print("[ToolExecutor] AppleScript primary captured: \(finalOutputData.count) bytes")
        } else {
            appleScriptErrorText = appleScriptPrimary.errorText
            let normalizedAppleScriptError = appleScriptPrimary.errorText.lowercased()
            appleEventsPermissionDenied =
                normalizedAppleScriptError.contains("privilege violation") ||
                normalizedAppleScriptError.contains("(-10004)") ||
                normalizedAppleScriptError.contains("error -10004")
            
            if !appleScriptPrimary.errorText.isEmpty {
                print("[ToolExecutor] AppleScript primary error: \(appleScriptPrimary.errorText.prefix(500))")
                if appleEventsPermissionDenied {
                    print("[ToolExecutor] AppleScript indicates AppleEvents permission denial (-10004)")
                }
            } else {
                print("[ToolExecutor] AppleScript primary returned empty output; falling back to shortcuts CLI capture...")
            }
            
            // FALLBACK: CLI output capture paths (file, stdout, then pipe).
            let outputFilename = "shortcut_output_\(UUID().uuidString).txt"
            let outputFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(outputFilename)
            let didCreateOutputFile = FileManager.default.createFile(
                atPath: outputFileURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o666]
            )
            print("[ToolExecutor] Output file precreate at \(outputFileURL.path): \(didCreateOutputFile ? "ok" : "failed")")
            
            var processArguments = ["run", shortcutName]
            if let inputFile = inputFile {
                processArguments.append(contentsOf: ["--input-path", inputFile.path])
            }
            processArguments.append(contentsOf: ["--output-path", outputFileURL.path])
            
            print("[ToolExecutor] CLI fallback command: /usr/bin/shortcuts run '<shortcut name>' --output-path '<sandbox temp file>'")
            
            let primaryResult: (exitCode: Int32, stdoutData: Data, stderrData: Data) = await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = processArguments
                
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                
                process.terminationHandler = { proc in
                    ToolExecutor.unregisterRunningProcess(proc)
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: (proc.terminationStatus, outData, errData))
                }
                
                do {
                    try process.run()
                    self.registerRunningProcess(process)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                        if process.isRunning {
                            process.terminate()
                            print("[ToolExecutor] Shortcut '\(shortcutName)' TIMED OUT")
                        }
                    }
                } catch {
                    print("[ToolExecutor] Failed to launch: \(error)")
                    continuation.resume(returning: (-1, Data(), Data(error.localizedDescription.utf8)))
                }
            }
            
            exitCode = primaryResult.exitCode
            print("[ToolExecutor] CLI fallback exit code: \(primaryResult.exitCode)")
            print("[ToolExecutor] CLI fallback stdout bytes: \(primaryResult.stdoutData.count)")
            print("[ToolExecutor] CLI fallback stderr bytes: \(primaryResult.stderrData.count)")
            if let stderrText = String(data: primaryResult.stderrData, encoding: .utf8), !stderrText.isEmpty {
                print("[ToolExecutor] CLI fallback stderr: \(stderrText.prefix(500))")
            }
            
            var fileOutputData = Data()
            for _ in 0..<20 {
                if let data = try? Data(contentsOf: outputFileURL), !data.isEmpty {
                    fileOutputData = data
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
            
            if !fileOutputData.isEmpty {
                finalOutputData = fileOutputData
                print("[ToolExecutor] CLI fallback file captured: \(fileOutputData.count) bytes")
            } else if !primaryResult.stdoutData.isEmpty {
                finalOutputData = primaryResult.stdoutData
                print("[ToolExecutor] CLI fallback stdout captured: \(primaryResult.stdoutData.count) bytes")
            } else {
                print("[ToolExecutor] CLI fallback returned no output in file or stdout")
            }
            
            // Known CLI quirk fallback: omit --output-path and force a pipe (| cat).
            if finalOutputData.isEmpty && primaryResult.exitCode == 0 {
                let escapedName = shortcutName.replacingOccurrences(of: "'", with: "'\\''")
                var noOutputPathCommand = "/usr/bin/shortcuts run '\(escapedName)'"
                if let inputFile = inputFile {
                    let escapedPath = inputFile.path.replacingOccurrences(of: "'", with: "'\\''")
                    noOutputPathCommand += " --input-path '\(escapedPath)'"
                }
                noOutputPathCommand += " | /bin/cat"
                print("[ToolExecutor] Retrying CLI with no --output-path + pipe fallback...")
                
                let pipedFallback = await withCheckedContinuation { (continuation: CheckedContinuation<(exitCode: Int32, stdoutData: Data, stderrData: Data), Never>) in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", noOutputPathCommand]
                    
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    
                    process.terminationHandler = { proc in
                        ToolExecutor.unregisterRunningProcess(proc)
                        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: (proc.terminationStatus, outData, errData))
                    }
                    
                    do {
                        try process.run()
                        self.registerRunningProcess(process)
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                            if process.isRunning {
                                process.terminate()
                            }
                        }
                    } catch {
                        continuation.resume(returning: (-1, Data(), Data(error.localizedDescription.utf8)))
                    }
                }
                
                if !pipedFallback.stdoutData.isEmpty {
                    finalOutputData = pipedFallback.stdoutData
                    print("[ToolExecutor] Piped CLI fallback captured: \(finalOutputData.count) bytes")
                } else {
                    print("[ToolExecutor] Piped CLI fallback returned empty output")
                    if let fallbackErr = String(data: pipedFallback.stderrData, encoding: .utf8), !fallbackErr.isEmpty {
                        print("[ToolExecutor] Piped CLI fallback stderr: \(fallbackErr.prefix(500))")
                    }
                }
            }
            
            try? FileManager.default.removeItem(at: outputFileURL)
        }
        
        // Clean up input file
        if let inputFile = inputFile { try? FileManager.default.removeItem(at: inputFile) }
        
        print("[ToolExecutor] Shortcut '\(shortcutName)' finished with exit code: \(exitCode)")
        print("[ToolExecutor] Final output: \(finalOutputData.count) bytes")
        
        // Check if output contains binary media (image) by checking magic bytes
        var fileAttachment: FileAttachment? = nil
        var outputInfo = ""
        
        if finalOutputData.count > 0 {
            let mimeType = detectMimeType(from: finalOutputData)
            
            if mimeType.hasPrefix("image/") {
                // Binary image output — save and create attachment for multimodal injection
                let fileExtension: String
                switch mimeType {
                case "image/png": fileExtension = "png"
                case "image/gif": fileExtension = "gif"
                case "image/webp": fileExtension = "webp"
                default: fileExtension = "jpg"
                }
                
                let savedFilename = "shortcut_\(UUID().uuidString).\(fileExtension)"
                let savedPath = documentsDirectory.appendingPathComponent(savedFilename)
                let imagePath = imagesDirectory.appendingPathComponent(savedFilename)
                
                try? PrivateStorage.writeAtomically(finalOutputData, to: savedPath)
                try? PrivateStorage.writeAtomically(finalOutputData, to: imagePath)
                
                fileAttachment = FileAttachment(data: finalOutputData, mimeType: mimeType, filename: savedFilename, sourcePath: savedPath.path)
                outputInfo = ", \"output_file\": {\"filename\": \"\(savedFilename)\", \"mimeType\": \"\(mimeType)\", \"sizeBytes\": \(finalOutputData.count), \"message\": \"Image output saved and visible for analysis\"}"
                
                print("[ToolExecutor] Shortcut produced image output: \(savedFilename) (\(finalOutputData.count) bytes)")
            } else {
                // Text output from stdout
                let textOutput = String(data: finalOutputData, encoding: .utf8) ?? ""
                if !textOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let escapedOutput = textOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                        .replacingOccurrences(of: "\r", with: "")
                    outputInfo = ", \"output\": \"\(escapedOutput)\""
                    print("[ToolExecutor] Shortcut text output: \(textOutput.prefix(200))")
                }
            }
        }
        
        // Build result
        let permissionDeniedNoOutput = appleEventsPermissionDenied && finalOutputData.isEmpty
        let success = (exitCode == 0) && !permissionDeniedNoOutput
        
        var result = "{\"success\": \(success), \"exit_code\": \(exitCode), \"shortcut\": \"\(shortcutName.replacingOccurrences(of: "\"", with: "\\\""))\""
        
        result += outputInfo
        
        if permissionDeniedNoOutput {
            result += ", \"error_code\": \"apple_events_permission_denied\""
        } else if success && finalOutputData.isEmpty {
            result += ", \"warning\": \"Shortcut executed but returned no output\""
        }
        
        if permissionDeniedNoOutput {
            let errorMessage = "AppleEvents permission denied while running Shortcuts Events (-10004). In System Settings > Privacy & Security > Automation, allow this app to control Shortcuts Events, then retry."
            let escapedMessage = errorMessage
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            result += ", \"message\": \"\(escapedMessage)\""
            
            if !appleScriptErrorText.isEmpty {
                let escapedDetails = appleScriptErrorText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "")
                result += ", \"details\": \"\(escapedDetails)\""
            }
        } else if success {
            result += ", \"message\": \"Shortcut '\(shortcutName)' executed successfully\""
        } else {
            result += ", \"message\": \"Shortcut '\(shortcutName)' failed with exit code \(exitCode)\""
        }
        
        result += "}"
        
        return ToolResultMessage(toolCallId: call.id, content: result, fileAttachment: fileAttachment)
    }
    
    /// Detect MIME type from file data by checking magic bytes
    private func detectMimeType(from data: Data) -> String {
        guard data.count >= 12 else { return "application/octet-stream" }
        
        let bytes = [UInt8](data.prefix(12))
        
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        
        // JPEG: FF D8 FF
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        
        // GIF: 47 49 46 38
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        }
        
        // WebP: 52 49 46 46 ... 57 45 42 50
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.count >= 12 {
            let webpBytes = [UInt8](data[8..<12])
            if webpBytes == [0x57, 0x45, 0x42, 0x50] {
                return "image/webp"
            }
        }
        
        // PDF: 25 50 44 46 (%PDF)
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return "application/pdf"
        }
        
        // Check if it looks like text
        let textBytes = data.prefix(1024)
        if let _ = String(data: textBytes, encoding: .utf8) {
            // Appears to be valid UTF-8 text
            return "text/plain"
        }
        
        return "application/octet-stream"
    }
    
    private func runShortcutViaAppleScript(name: String, input: String?, timeoutSeconds: Double) async -> (exitCode: Int32, outputData: Data, errorText: String) {
        // Prefer in-process AppleScript so sandbox/TCC permissions apply to this app directly.
        let inProcessResult = await runShortcutViaInProcessAppleScript(name: name, input: input)
        if inProcessResult.exitCode == 0 || !inProcessResult.errorText.isEmpty {
            return inProcessResult
        }
        
        print("[ToolExecutor] In-process AppleScript returned empty output; trying osascript fallback...")
        let osascriptResult = await runShortcutViaOSAScript(name: name, input: input, timeoutSeconds: timeoutSeconds)
        if osascriptResult.exitCode == 0, !osascriptResult.outputData.isEmpty {
            return osascriptResult
        }
        if !osascriptResult.errorText.isEmpty {
            return osascriptResult
        }
        
        return inProcessResult
    }
    
    private func runShortcutViaInProcessAppleScript(name: String, input: String?) async -> (exitCode: Int32, outputData: Data, errorText: String) {
        #if !os(macOS)
        return (-1, Data(), "AppleScript is only available on macOS")
        #else
        await MainActor.run {
            let escapedName = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            
            let command: String
            if let input, !input.isEmpty {
                let escapedInput = input
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                command = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\" with input \"\(escapedInput)\""
            } else {
                command = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\""
            }
            
            guard let script = NSAppleScript(source: command) else {
                return (-1, Data(), "Failed to create AppleScript object")
            }
            
            var errorInfo: NSDictionary?
            let resultDescriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                    ?? (errorInfo["NSAppleScriptErrorMessage"] as? String)
                    ?? "Unknown AppleScript error"
                let number = (errorInfo[NSAppleScript.errorNumber] as? Int)
                    ?? (errorInfo["NSAppleScriptErrorNumber"] as? Int)
                    ?? -1
                return (Int32(number), Data(), "\(message) (\(number))")
            }
            
            if let text = resultDescriptor.stringValue, !text.isEmpty {
                return (0, Data(text.utf8), "")
            }
            
            let rawData = resultDescriptor.data
            if !rawData.isEmpty {
                return (0, rawData, "")
            }
            
            return (0, Data(), "")
        }
        #endif
    }
    
    private func runShortcutViaOSAScript(name: String, input: String?, timeoutSeconds: Double) async -> (exitCode: Int32, outputData: Data, errorText: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            
            let escapedName = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let scriptLine: String
            if let input, !input.isEmpty {
                let escapedInput = input
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                scriptLine = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\" with input \"\(escapedInput)\""
            } else {
                scriptLine = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\""
            }
            
            let arguments = ["-l", "AppleScript", "-e", scriptLine]
            process.arguments = arguments
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            process.terminationHandler = { proc in
                ToolExecutor.unregisterRunningProcess(proc)
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus, outData, errText))
            }
            
            do {
                try process.run()
                self.registerRunningProcess(process)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                    if process.isRunning {
                        process.terminate()
                    }
                }
            } catch {
                continuation.resume(returning: (-1, Data(), error.localizedDescription))
            }
        }
    }
}

// MARK: - Image Generation Argument Types

struct GenerateImageArguments: Codable {
    let engine: String?
    let prompt: String
    let sourceImage: String?
    let sourceImageRole: String?
    let size: String?
    let quality: String?
    let outputFormat: String?
    let outputCompression: Int?
    let background: String?
    let moderation: String?
    
    enum CodingKeys: String, CodingKey {
        case engine
        case prompt
        case sourceImage = "source_image"
        case sourceImageRole = "source_image_role"
        case size
        case quality
        case outputFormat = "output_format"
        case outputCompression = "output_compression"
        case background
        case moderation
    }
}

struct GenerateImageResult: Codable {
    let success: Bool
    let message: String
    let imageSize: Int
    let mimeType: String
    let generatedFilename: String
    
    enum CodingKeys: String, CodingKey {
        case success, message, mimeType
        case imageSize = "image_size"
        case generatedFilename = "generated_filename"
    }
}

// MARK: - Shortcuts Tool Argument Types

struct ShortcutsArguments: Codable {
    let action: String
    let name: String?
    let input: String?
}

struct RunShortcutArguments: Codable {
    let name: String
    let input: String?
}

// MARK: - URL Viewing and Download Tool Implementations

/// JSON-escape a string for safe inline interpolation into a JSON object literal.
/// Returns the value with surrounding quotes (e.g. `"hello\nworld"`).
fileprivate func jsonStringLit(_ s: String) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
       let str = String(data: data, encoding: .utf8),
       str.count >= 2 {
        return String(str.dropFirst().dropLast())
    }
    // Fallback: manual minimal escaping.
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}

extension ToolExecutor {
    func executeWebFetch(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebFetchArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse web_fetch arguments. Required: url (string), prompt (string).\"}"
        }

        // Validate URL format
        guard args.url.hasPrefix("http://") || args.url.hasPrefix("https://") else {
            return "{\"error\": \"Invalid URL format. URL must start with http:// or https://\"}"
        }

        // Validate prompt non-empty
        let promptTrim = args.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptTrim.isEmpty else {
            return "{\"error\": \"web_fetch requires a non-empty prompt describing what to extract from the page.\"}"
        }

        do {
            let result = try await webOrchestrator.readUrlContent(
                url: args.url,
                prompt: promptTrim,
                sectionOffset: args.section_offset ?? 0
            )
            // Returns a prompt-compressed excerpt plus image metadata (captions, URLs)
            // LLM can use bash curl + read_file to download and view specific images
            return result.asJSON()
        } catch {
            return jsonObjectString(["error": webPipelineFailureText("Failed to fetch URL", error: error)])
        }
    }

}

// MARK: - URL Tool Argument Types

struct WebFetchArguments: Codable {
    let url: String
    let prompt: String
    let section_offset: Int?
}

// MARK: - Send Document to Chat Tool

extension ToolExecutor {
    func executeSendDocumentToChat(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SendDocumentToChatArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse send_document_to_chat arguments\"}"
        }

        guard allowsUserVisibleToolOutputs else {
            return "{\"error\": \"send_document_to_chat is only available to the main agent. Subagents should return file paths in their final result instead.\"}"
        }

        // Resolve absolute path directly
        let documentURL = URL(fileURLWithPath: args.filePath)
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return "{\"error\": \"File not found: \(args.filePath). Use glob or list_dir to verify the path.\"}"
        }

        do {
            let documentData = try Data(contentsOf: documentURL)
            let filename = documentURL.lastPathComponent
            recordDocumentOpened(filename: filename)
            
            // Determine MIME type from extension
            let ext = documentURL.pathExtension.lowercased()
            let mimeType: String
            switch ext {
            case "pdf":
                mimeType = "application/pdf"
            case "jpg", "jpeg":
                mimeType = "image/jpeg"
            case "png":
                mimeType = "image/png"
            case "gif":
                mimeType = "image/gif"
            case "webp":
                mimeType = "image/webp"
            case "txt":
                mimeType = "text/plain"
            case "json":
                mimeType = "application/json"
            case "html":
                mimeType = "text/html"
            case "xml":
                mimeType = "application/xml"
            case "zip":
                mimeType = "application/zip"
            case "doc", "docx":
                mimeType = "application/msword"
            case "xls", "xlsx":
                mimeType = "application/vnd.ms-excel"
            default:
                mimeType = FilesystemTools.mimeType(forPath: documentURL.path)
            }
            
            // Store the document for sending after the main-agent tool response.
            ToolExecutor.queuePendingDocument(
                data: documentData,
                filename: filename,
                mimeType: mimeType,
                caption: args.caption
            )

            print("[ToolExecutor] Queued document for sending: \(args.filePath) (\(documentData.count) bytes)")

            let result = SendDocumentToChatResult(
                success: true,
                filePath: args.filePath,
                sizeBytes: documentData.count,
                message: "File '\(filename)' will be sent to the chat."
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"message\": \"Document queued for sending\"}"
        } catch {
            return "{\"error\": \"Failed to read document: \(error.localizedDescription)\"}"
        }
    }
}

// MARK: - Mid-Turn Message to the User

extension ToolExecutor {
    func executeMidTurnMessageUser(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(MidTurnMessageUserArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse mid_turn_message_user arguments\"}"
        }

        guard allowsUserVisibleToolOutputs else {
            return "{\"error\": \"mid_turn_message_user is only available to the main agent. Subagents should include anything user-relevant in their final result instead.\"}"
        }

        let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "{\"error\": \"text is empty — nothing to send.\"}"
        }

        guard let sender = midTurnMessageSender else {
            return "{\"error\": \"No active chat channel to deliver to. Continue working and put this in your final answer instead.\"}"
        }

        do {
            try await sender(text)
            return "{\"success\": true, \"message\": \"Delivered to the user. Do not repeat this content in your final answer.\"}"
        } catch {
            // The message was appended to conversation history before the wire
            // send, and failed channel sends park-and-retry automatically
            // (ConversationManager) — so the text is not lost either way.
            return "{\"error\": \"Delivery failed: \(error.localizedDescription). The message was saved to conversation history and queued for automatic retry — do not repeat it in your final answer.\"}"
        }
    }
}

struct MidTurnMessageUserArguments: Codable {
    let text: String
}

// MARK: - Send Document to Chat Types

struct SendDocumentToChatArguments: Codable {
    let filePath: String
    let caption: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case caption
    }
}

struct SendDocumentToChatResult: Codable {
    let success: Bool
    let filePath: String
    let sizeBytes: Int
    let message: String

    enum CodingKeys: String, CodingKey {
        case success, message
        case filePath = "file_path"
        case sizeBytes = "size_bytes"
    }
}


// MARK: - Gmail Tool Argument Types

struct GmailReaderArguments: Codable {
    let action: String
    let query: String?
    let limit: Int?
    let messageId: String?
    let threadId: String?
    let attachmentId: String?
    let filename: String?

    enum CodingKeys: String, CodingKey {
        case action, query, limit, filename
        case messageId = "message_id"
        case threadId = "thread_id"
        case attachmentId = "attachment_id"
    }
}

struct GmailComposerArguments: Codable {
    let action: String
    let to: String?
    let subject: String?
    let body: String?
    let threadId: String?
    let inReplyTo: String?
    let cc: [String]
    let bcc: [String]
    let attachmentFilenames: [String]?
    let messageId: String?
    let comment: String?

    enum CodingKeys: String, CodingKey {
        case action, to, subject, body, cc, bcc, comment
        case threadId = "thread_id"
        case inReplyTo = "in_reply_to"
        case attachmentFilenames = "attachment_filenames"
        case messageId = "message_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        to = try container.decodeIfPresent(String.self, forKey: .to)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        cc = decodeRecipients(from: container, forKey: .cc)
        bcc = decodeRecipients(from: container, forKey: .bcc)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)

        if let array = try? container.decodeIfPresent([String].self, forKey: .attachmentFilenames) {
            attachmentFilenames = array
        } else if let jsonString = try? container.decodeIfPresent(String.self, forKey: .attachmentFilenames),
                  let data = jsonString.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data) {
            attachmentFilenames = parsed
        } else {
            attachmentFilenames = nil
        }
    }
}

struct GmailQueryArguments: Codable {
    let query: String?
    let limit: Int?
}

struct GmailSendArguments: Codable {
    let to: String
    let subject: String
    let body: String
    let threadId: String?
    let inReplyTo: String?
    let cc: [String]
    let bcc: [String]
    let attachmentFilenames: [String]?
    
    enum CodingKeys: String, CodingKey {
        case to, subject, body, cc, bcc
        case threadId = "thread_id"
        case inReplyTo = "in_reply_to"
        case attachmentFilenames = "attachment_filenames"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to)
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        cc = decodeRecipients(from: container, forKey: .cc)
        bcc = decodeRecipients(from: container, forKey: .bcc)
        
        // Handle attachmentFilenames as either an array or a JSON string
        if let array = try? container.decodeIfPresent([String].self, forKey: .attachmentFilenames) {
            attachmentFilenames = array
        } else if let jsonString = try? container.decodeIfPresent(String.self, forKey: .attachmentFilenames),
                  let data = jsonString.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data) {
            attachmentFilenames = parsed
        } else {
            attachmentFilenames = nil
        }
    }
}

struct GmailThreadArguments: Codable {
    let threadId: String
    
    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
    }
}

struct GmailForwardArguments: Codable {
    let to: String
    let messageId: String
    let comment: String?
    
    enum CodingKeys: String, CodingKey {
        case to
        case messageId = "message_id"
        case comment
    }
}

struct GmailAttachmentArguments: Codable {
    let messageId: String
    let attachmentId: String
    let filename: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case attachmentId = "attachment_id"
        case filename
    }
}

// MARK: - Agent (subagent) Tool

struct SubagentInvocationArguments: Decodable {
    let subagent_type: String
    let description: String
    let prompt: String
    let session_id: String?
    let close_session: String?
    let run_in_background: Bool?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case subagent_type
        case description
        case prompt
        case session_id
        case close_session
        case run_in_background
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subagent_type = try container.decode(String.self, forKey: .subagent_type)
        description = try container.decode(String.self, forKey: .description)
        prompt = try container.decode(String.self, forKey: .prompt)
        session_id = try container.decodeIfPresent(String.self, forKey: .session_id)
        close_session = try container.decodeIfPresent(String.self, forKey: .close_session)
        model = try container.decodeIfPresent(String.self, forKey: .model)

        if let boolValue = try? container.decodeIfPresent(Bool.self, forKey: .run_in_background) {
            run_in_background = boolValue
        } else if let rawValue = try? container.decodeIfPresent(String.self, forKey: .run_in_background) {
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                run_in_background = true
            case "false", "no", "0":
                run_in_background = false
            default:
                run_in_background = nil
            }
        } else {
            run_in_background = nil
        }
    }
}

extension ToolExecutor {
    /// Validate the Agent tool's `model` hint against the lane configuration
    /// BEFORE any run starts. Unset/unknown lanes fail LOUDLY here — a silent
    /// fallback to inherit would bill the full main-model price while the
    /// main agent believes it delegated cheaply. (The runner's own fallback
    /// only serves paths that bypass this gate, e.g. a watcher lane cleared
    /// while a batch was pending.) Returns an error JSON string, or nil when
    /// the hint is valid.
    static func agentModelHintError(_ hint: String?) -> String? {
        switch SubagentModelLanes.resolve(hint: hint) {
        case .inherit, .lane:
            return nil
        case .unconfigured(let lane):
            return "{\"error\": \"The '\(lane.rawValue)' model lane is not configured for the current provider. Ask the user to set it with the /subagentmodels command, or use model='inherit'.\"}"
        case .unknown(let raw):
            let lanes = SubagentModelLanes.configuredLanes().map { "'\($0.lane.rawValue)'" }
            let valid = (["'inherit'"] + lanes).joined(separator: ", ")
            return "{\"error\": \"Unknown model hint '\(raw)'. Valid values: \(valid). Concrete model ids are not accepted — the user configures cheap lanes with /subagentmodels.\"}"
        }
    }

    /// Wraps executeAgent and surfaces subagent spend on the ToolResultMessage so
    /// ConversationManager's toolSpendUSD pass rolls it into the parent's cumulative
    /// daily/monthly counters and spend-limit enforcement. Background spawns still
    /// return spend = 0 here (the cost lands later via SubagentBackgroundRegistry →
    /// checkBackgroundSubagentCompletions).
    func executeAgentToolResult(_ call: ToolCall) async -> ToolResultMessage {
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SubagentInvocationArguments.self, from: data) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Invalid Agent tool arguments\"}")
        }

        if let laneError = Self.agentModelHintError(args.model) {
            return ToolResultMessage(toolCallId: call.id, content: laneError)
        }

        guard let openRouter = openRouterService else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Agent tool not configured: OpenRouterService missing. ConversationManager must call toolExecutor.configureOpenRouter(...).\"}")
        }

        let imagesDir = subagentImagesDirectory ?? StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
        let documentsDir = subagentDocumentsDirectory ?? StoragePaths.dataRoot.appendingPathComponent("documents", isDirectory: true)
        let parentTools = AvailableTools.all(includeWebSearch: true)
        let runInBg = args.run_in_background ?? false
        let invocation = SubagentRunner.Invocation(
            subagentType: args.subagent_type,
            description: args.description,
            taskPrompt: args.prompt,
            modelOverride: args.model,
            runInBackground: runInBg
        )

        let childExecutor = await makeChildExecutor()

        if runInBg {
            let handle = await SubagentBackgroundRegistry.shared.spawn(
                invocation: invocation,
                parentTools: parentTools,
                openRouterService: openRouter,
                toolExecutor: childExecutor,
                imagesDirectory: imagesDir,
                documentsDirectory: documentsDir
            )
            let payload: [String: Any] = [
                "background": true,
                "handle": handle.id,
                "subagent_type": handle.subagentType,
                "description": handle.description,
                "note": "Subagent is running in the background. You will receive a synthetic [SUBAGENT COMPLETE] user message when it finishes. Continue with other work or wait."
            ]
            let content = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? "{\"error\": \"Failed to encode background handle response\"}"
            return ToolResultMessage(toolCallId: call.id, content: content)
        }

        let runner = SubagentRunner()
        let result = await runner.run(
            invocation: invocation,
            sessionId: args.session_id,
            openRouterService: openRouter,
            toolExecutor: childExecutor,
            imagesDirectory: imagesDir,
            documentsDirectory: documentsDir,
            parentTools: parentTools
        )
        return ToolResultMessage(
            toolCallId: call.id,
            content: result.asJSON(),
            spendUSD: result.spendUSD > 0 ? result.spendUSD : nil
        )
    }

    func executeAgent(_ call: ToolCall) async -> String {
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SubagentInvocationArguments.self, from: data) else {
            return "{\"error\": \"Invalid Agent tool arguments\"}"
        }

        if let laneError = Self.agentModelHintError(args.model) {
            return laneError
        }

        guard let openRouter = openRouterService else {
            return "{\"error\": \"Agent tool not configured: OpenRouterService missing. ConversationManager must call toolExecutor.configureOpenRouter(...).\"}"
        }

        let imagesDir = subagentImagesDirectory ?? StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
        let documentsDir = subagentDocumentsDirectory ?? StoragePaths.dataRoot.appendingPathComponent("documents", isDirectory: true)

        // Same tool surface the parent sees this session — the subagent's type filter will narrow it.
        let parentTools = AvailableTools.all(includeWebSearch: true)

        let runInBg = args.run_in_background ?? false
        let invocation = SubagentRunner.Invocation(
            subagentType: args.subagent_type,
            description: args.description,
            taskPrompt: args.prompt,
            modelOverride: args.model,
            runInBackground: runInBg
        )

        let childExecutor = await makeChildExecutor()

        if runInBg {
            let handle = await SubagentBackgroundRegistry.shared.spawn(
                invocation: invocation,
                parentTools: parentTools,
                openRouterService: openRouter,
                toolExecutor: childExecutor,
                imagesDirectory: imagesDir,
                documentsDirectory: documentsDir
            )
            let payload: [String: Any] = [
                "background": true,
                "handle": handle.id,
                "subagent_type": handle.subagentType,
                "description": handle.description,
                "note": "Subagent is running in the background. You will receive a synthetic [SUBAGENT COMPLETE] user message when it finishes. Continue with other work or wait."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{\"error\": \"Failed to encode background handle response\"}"
        }

        let runner = SubagentRunner()
        let result = await runner.run(
            invocation: invocation,
            sessionId: args.session_id,
            openRouterService: openRouter,
            toolExecutor: childExecutor,
            imagesDirectory: imagesDir,
            documentsDirectory: documentsDir,
            parentTools: parentTools
        )
        return result.asJSON()
    }

    func executeSubagentManage(_ call: ToolCall) async -> String {
        struct Args: Decodable { let mode: String?; let handle: String?; let limit: Int?; let offset: Int? }
        let args: Args
        if let data = call.function.arguments.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Args.self, from: data) {
            args = decoded
        } else {
            args = Args(mode: nil, handle: nil, limit: nil, offset: nil)
        }
        guard let mode = args.mode else {
            return "{\"error\": \"subagent_manage requires 'mode' (list_running, list_sessions, or cancel)\"}"
        }

        switch mode {
        case "list_running":
            let handles = await SubagentBackgroundRegistry.shared.runningHandles()
            let now = Date()
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let rows: [[String: Any]] = handles.map { h in
                [
                    "handle": h.id,
                    "subagent_type": h.subagentType,
                    "description": h.description,
                    "started_at": iso.string(from: h.startedAt),
                    "running_seconds": Int(now.timeIntervalSince(h.startedAt))
                ]
            }
            let payload: [String: Any] = ["count": rows.count, "running": rows]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{\"error\": \"failed to encode subagent_manage list_running result\"}"

        case "cancel":
            guard let handle = args.handle, !handle.isEmpty else {
                return "{\"cancelled\": false, \"reason\": \"mode='cancel' requires 'handle'\"}"
            }
            let ok = await SubagentBackgroundRegistry.shared.cancel(id: handle)
            let payload: [String: Any] = ok
                ? ["cancelled": true, "handle": handle, "note": "Cancellation requested. Takes effect at the subagent's next turn boundary."]
                : ["cancelled": false, "handle": handle, "reason": "not found"]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{\"error\": \"failed to encode subagent_manage cancel result\"}"

        case "list_sessions":
            let limit = args.limit ?? 20
            let offset = args.offset ?? 0
            let (sessions, total) = await SubagentSessionRegistry.shared.list(limit: limit, offset: offset)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let rows: [[String: Any]] = sessions.map { s in
                [
                    "session_id": s.id,
                    "subagent_type": s.subagentType,
                    "description": s.description,
                    "created": iso.string(from: s.created),
                    "last_used": iso.string(from: s.lastUsed),
                    "total_turns": s.totalTurns,
                    "message_count": s.messages.count,
                    "spend_usd": s.totalSpendUSD
                ]
            }
            let payload: [String: Any] = ["sessions": rows, "total": total, "has_more": offset + limit < total]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{\"error\": \"failed to encode subagent_manage list_sessions result\"}"

        default:
            return "{\"error\": \"Unknown mode '\(mode)'. Use 'list_running', 'list_sessions', or 'cancel'.\"}"
        }
    }
}
