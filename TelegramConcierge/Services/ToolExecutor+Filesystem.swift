import Foundation

/// Handlers for the filesystem tool surface: read_file, write_file, edit_file,
/// apply_patch, grep, glob, list_dir, list_recent_files, bash, bash_manage.
///
/// Parsing pattern: decode arguments from JSONValue (since the tool schema uses
/// string-typed parameters that may arrive as numbers/bools/objects), delegate to the
/// underlying implementation in FilesystemTools / ApplyPatch / DiscoveryTools / BashTools,
/// wrap the result as a ToolResultMessage.
extension ToolExecutor {

    // MARK: - read_file (returns multimodal attachments for images/PDFs)

    func executeReadFile(_ call: ToolCall) async -> ToolResultMessage {
        let args = parseArgs(call.function.arguments)
        guard let path = args.string("path") else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"read_file requires 'path' (absolute)\"}")
        }
        let offset = args.int("offset")
        let limit = args.int("limit")
        let pages = args.string("pages")
        let token = StageMarkers.enter("fs.read_file", detail: StageMarkers.basename(path))
        let result = await FilesystemTools.shared.readFile(path: path, offset: offset, limit: limit, pages: pages)
        StageMarkers.exit(token, result.content.contains("\"error\"") ? .error : .ok)
        return ToolResultMessage(toolCallId: call.id, content: result.content, fileAttachments: result.attachments)
    }

    // MARK: - write_file

    func executeWriteFile(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let path = args.string("path") else {
            return "{\"error\": \"write_file requires 'path'\"}"
        }
        guard let content = args.string("content") else {
            return "{\"error\": \"write_file requires 'content'\"}"
        }
        let description = args.string("description")
        // Diagnostics: includes waiting for the FilesystemTools actor.
        let token = StageMarkers.enter("fs.write_file", detail: StageMarkers.basename(path))
        let result = await FilesystemTools.shared.writeFile(path: path, content: content, description: description)
        StageMarkers.exit(token, result.content.contains("\"error\"") ? .error : .ok)
        return result.content
    }

    // MARK: - edit_file

    func executeEditFile(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let path = args.string("path") else {
            return "{\"error\": \"edit_file requires 'path'\"}"
        }
        let replaceAll = args.bool("replace_all") ?? false

        // Support two input formats:
        // 1. Batched: { path, edits: [{old_string, new_string}, ...] }
        // 2. Single (backward compat): { path, old_string, new_string }
        var editPairs: [FilesystemTools.EditPair] = []

        if let editsArray = args.objectArray("edits") {
            for (i, editDict) in editsArray.enumerated() {
                guard let old = editDict["old_string"] as? String, !old.isEmpty else {
                    return "{\"error\": \"edits[\(i)] requires 'old_string'\"}"
                }
                guard let new = editDict["new_string"] as? String else {
                    return "{\"error\": \"edits[\(i)] requires 'new_string'\"}"
                }
                editPairs.append(FilesystemTools.EditPair(oldString: old, newString: new))
            }
        } else if let oldString = args.string("old_string"),
                  let newString = args.stringAllowingEmpty("new_string") {
            editPairs.append(FilesystemTools.EditPair(oldString: oldString, newString: newString))
        } else {
            return "{\"error\": \"edit_file requires either 'edits' array or 'old_string'+'new_string'\"}"
        }

        let token = StageMarkers.enter("fs.edit_file", detail: StageMarkers.basename(path))
        let result = await FilesystemTools.shared.editFile(path: path, edits: editPairs, replaceAll: replaceAll)
        StageMarkers.exit(token, result.content.contains("\"error\"") ? .error : .ok)
        EditToolStats.log(tool: "edit_file", success: result.content.contains("\"success\":true"))
        return result.content
    }

    // MARK: - apply_patch

    func executeApplyPatch(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let patchText = args.string("patch_text") else {
            return "{\"error\": \"apply_patch requires 'patch_text'\"}"
        }
        let token = StageMarkers.enter("fs.apply_patch")
        let result = await ApplyPatch.run(patchText: patchText)
        StageMarkers.exit(token, result.content.contains("\"error\"") ? .error : .ok)
        EditToolStats.log(tool: "apply_patch", success: result.content.contains("\"success\":true"))
        return result.content
    }

    // MARK: - grep

    func executeGrep(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let pattern = args.string("pattern"),
              let path = args.string("path") else {
            return "{\"error\": \"grep requires 'pattern' and 'path'\"}"
        }
        let include = args.string("include")
        let type = args.string("type")
        let outputModeRaw = args.string("output_mode") ?? "content"
        guard let outputMode = DiscoveryTools.GrepOutputMode(rawValue: outputModeRaw) else {
            return "{\"error\": \"grep output_mode must be one of: content, files_with_matches, count\"}"
        }
        let caseInsensitive = args.bool("case_insensitive") ?? args.bool("-i") ?? false
        let multiline = args.bool("multiline") ?? false
        let contextC = args.int("context") ?? args.int("-C")
        let contextBefore = args.int("context_before") ?? args.int("-B") ?? contextC ?? 0
        let contextAfter = args.int("context_after") ?? args.int("-A") ?? contextC ?? 0
        let maxResults = min(max(args.int("max_results") ?? DiscoveryTools.maxResults, 1), DiscoveryTools.maxResultsHardCap)
        let result = await DiscoveryTools.grep(
            pattern: pattern,
            searchPath: path,
            include: include,
            type: type,
            outputMode: outputMode,
            caseInsensitive: caseInsensitive,
            multiline: multiline,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            maxResults: maxResults,
            registerProcess: { [weak self] process in self?.registerRunningProcess(process) },
            unregisterProcess: { process in ToolExecutor.unregisterRunningProcess(process) }
        )
        return result.content
    }

    // MARK: - glob

    func executeGlob(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let pattern = args.string("pattern") else {
            return "{\"error\": \"glob requires 'pattern'\"}"
        }
        let path = args.string("path")
        let maxResults = min(max(args.int("max_results") ?? DiscoveryTools.maxResults, 1), DiscoveryTools.maxResultsHardCap)
        let result = await DiscoveryTools.glob(
            pattern: pattern,
            searchPath: path,
            maxResults: maxResults,
            registerProcess: { [weak self] process in self?.registerRunningProcess(process) },
            unregisterProcess: { process in ToolExecutor.unregisterRunningProcess(process) }
        )
        return result.content
    }

    // MARK: - list_dir

    func executeListDir(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let path = args.string("path") else {
            return "{\"error\": \"list_dir requires 'path'\"}"
        }
        let extraIgnores = args.stringArray("ignore")
        let includeHidden = args.bool("include_hidden") ?? false
        let includeIgnored = args.bool("include_ignored") ?? false
        let maxResults = min(max(args.int("max_results") ?? DiscoveryTools.maxResults, 1), DiscoveryTools.maxResultsHardCap)
        let offset = max(args.int("offset") ?? 0, 0)
        let result = await DiscoveryTools.listDir(
            path: path,
            ignore: extraIgnores,
            includeHidden: includeHidden,
            includeIgnored: includeIgnored,
            maxResults: maxResults,
            offset: offset
        )
        return result.content
    }

    // MARK: - list_recent_files

    func executeListRecentFiles(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        let limit = args.int("limit") ?? 20
        let offset = args.int("offset") ?? 0
        let filter = args.string("filter_origin")
        let result = await DiscoveryTools.listRecentFiles(limit: limit, offset: offset, filterOrigin: filter)
        return result.content
    }

    // MARK: - bash (quick / managed / background dispatch)

    func executeBash(_ call: ToolCall) async -> ToolResultMessage {
        func msg(_ content: String) -> ToolResultMessage {
            ToolResultMessage(toolCallId: call.id, content: content)
        }
        let args = parseArgs(call.function.arguments)
        let capability = bashCapability

        // Strict allowed-key validation (BASH_V2_SCHEMA_CLEANUP_PLAN §3.1):
        // unknown arguments are rejected with the allowed set spelled out —
        // never silently ignored, and never decoded through a second legacy
        // vocabulary. The two removed v1 names get exact replacements.
        let allowedKeys: Set<String> = capability == .foregroundOnly
            ? ["command", "kill_after_seconds", "workdir", "description", "service_key_env"]
            : ["command", "wait_seconds", "kill_after_seconds", "workdir", "description", "service_key_env"]
        let unknownKeys = args.raw.keys.filter { !allowedKeys.contains($0) }.sorted()
        if !unknownKeys.isEmpty {
            var hints: [String] = []
            if unknownKeys.contains("run_in_background") {
                hints.append(capability == .foregroundOnly
                    ? "run_in_background was removed, and background execution is not available in this context — commands run in the foreground until settlement"
                    : "run_in_background was removed — use wait_seconds=0 for immediate background execution")
            }
            if unknownKeys.contains("timeout_ms") {
                hints.append(capability == .foregroundOnly
                    ? "timeout_ms was removed — use kill_after_seconds (in seconds) for the execution deadline"
                    : "timeout_ms was removed — use equal wait_seconds and kill_after_seconds (in seconds) for the old bounded-timeout behavior")
            }
            if capability == .foregroundOnly, unknownKeys.contains("wait_seconds") {
                hints.append("wait_seconds is not available in this context — commands run in the foreground until settlement")
            }
            let hintText = hints.isEmpty ? "" : " (" + hints.joined(separator: "; ") + ")"
            return msg("{\"error\": \"bash: unknown argument\(unknownKeys.count == 1 ? "" : "s") '\(escapeJSON(unknownKeys.joined(separator: "', '")))' — allowed: \(allowedKeys.sorted().joined(separator: ", ")).\(escapeJSON(hintText))\"}")
        }

        guard let command = args.string("command") else {
            return msg("{\"error\": \"bash requires 'command'\"}")
        }
        let workdir = args.string("workdir")
        let description = args.string("description")
        let serviceKeyEnv = args.stringDict("service_key_env")
        // Lifecycle values are strict integers (§3.1): a truncated 0.5 would
        // silently become wait_seconds=0 and DETACH the process the model
        // expected to wait for; a boolean must not become a 1s deadline.
        let killAfterArg: Int?
        switch args.strictInt("kill_after_seconds") {
        case .absent:            killAfterArg = nil
        case .value(let v):      killAfterArg = v
        case .invalid(let raw):
            return msg("{\"error\": \"bash: kill_after_seconds must be an integer number of seconds (got '\(escapeJSON(raw))')\"}")
        }

        // Attached execution for foreground-only subagents: wait until
        // settlement, bounded by the execution deadline (§3.3).
        if capability == .foregroundOnly {
            if let k = killAfterArg, !(1...BashTools.attachedMaxKillAfterSeconds).contains(k) {
                return msg("{\"error\": \"bash: kill_after_seconds must be 1-\(BashTools.attachedMaxKillAfterSeconds) in this context\"}")
            }
            // Register with the executor's running-process registry so
            // subagent cancellation (cancelAllRunningProcesses) can kill the child.
            let result = await BashTools.runAttached(
                command: command,
                killAfterSeconds: killAfterArg ?? BashTools.attachedDefaultKillAfterSeconds,
                workdir: workdir,
                description: description,
                serviceKeyEnv: serviceKeyEnv,
                register: { [weak self] process in self?.registerRunningProcess(process) },
                unregister: { process in ToolExecutor.unregisterRunningProcess(process) }
            )
            return msg(result.content)
        }

        // Managed path — the ONE launch lifecycle for every main-agent and
        // background-capable-subagent command (§4.3).
        let waitSecondsArg: Int?
        switch args.strictInt("wait_seconds") {
        case .absent:            waitSecondsArg = nil
        case .value(let v):      waitSecondsArg = v
        case .invalid(let raw):
            return msg("{\"error\": \"bash: wait_seconds must be an integer number of seconds (got '\(escapeJSON(raw))')\"}")
        }
        if let w = waitSecondsArg, w < 0 {
            return msg("{\"error\": \"bash: wait_seconds must be >= 0\"}")
        }
        if let k = killAfterArg, !(1...BashTools.maxKillAfterSeconds).contains(k) {
            return msg("{\"error\": \"bash: kill_after_seconds must be 1-\(BashTools.maxKillAfterSeconds) (omit it for no deadline)\"}")
        }

        // Default policy (§3.1): no lifecycle args = safe bounded quick
        // command, expressed as wait=120/kill=120 on the managed path —
        // policy, not a second engine. An explicit kill without a wait uses
        // the default 120s wait with the explicit deadline. Only EXPLICIT
        // wait_seconds charges the turn's wait ledger: the implicit default
        // wait is the quick-command idiom, like legacy foreground was.
        let isDefaultPolicy = waitSecondsArg == nil && killAfterArg == nil
        let requested = min(waitSecondsArg ?? BashTools.quickDefaultSeconds, BashTools.maxWaitSeconds)
        let effectiveKill = isDefaultPolicy ? BashTools.quickDefaultSeconds : killAfterArg
        var effective = Double(requested)
        var refusal: String? = nil
        if let w = waitSecondsArg, w > 0 {
            switch consumeWaitAdmission(callId: call.id, handle: "start:\(call.id)",
                                        requestedSeconds: Double(min(w, BashTools.maxWaitSeconds))) {
            case .granted(let seconds): effective = seconds
            case .refused(let reason):  refusal = reason; effective = 0
            }
        }
        let result = await BashTools.runManaged(
            command: command,
            requestedWaitSeconds: requested,
            effectiveWaitSeconds: effective,
            waitRefusalReason: refusal,
            killAfterSeconds: effectiveKill,
            workdir: workdir, description: description, serviceKeyEnv: serviceKeyEnv,
            owner: bashOwner)
        // Only explicit waits participate in the repeat-timeout guard — an
        // implicit default wait can't expire with the job still running
        // (its equal execution deadline settles it first).
        if result.waitExpired, let jobHandle = result.jobHandle, waitSecondsArg != nil {
            recordBashWaitTimeout(handle: jobHandle)
        }
        var message = ToolResultMessage(toolCallId: call.id, content: result.content,
                                        bashReceipt: result.receipt)
        message.outcomeBinding = Self.bashOutcomeBinding(result, launchCall: true)
        return message
    }

    /// Typed settlement evidence for a bash-family result (mid-turn early
    /// wake §3.12.1), set only here, from harness state — never from text:
    /// `moved` when the call returned while its recorded job keeps running;
    /// `receiptObserved` when the result carries the completion receipt of
    /// a recorded job. Jobs without a crash record stay unbound (their
    /// receipts keep the in-memory contract). The launch fingerprint rides
    /// only on the launching call's own binding (Codex V7 gate 1: a
    /// `bash_manage wait` is a different call from the launch).
    static func bashOutcomeBinding(_ result: BashTools.OpResult, launchCall: Bool) -> OutcomeBinding? {
        let wake = WakeContext.current
        if let receipt = result.receipt,
           (try? DetachedJobStore.load())?.contains(where: { $0.jobId == receipt.jobUUID }) == true {
            return OutcomeBinding(kind: .receiptObserved, jobId: receipt.jobUUID)
        }
        if let moved = result.movedJobUUID {
            return OutcomeBinding(kind: .moved, jobId: moved, fingerprint: launchCall ? wake?.fingerprint : nil)
        }
        return nil
    }

    // MARK: - bash_manage (unified output/wait/input/watch/kill/list)

    func executeBashManage(_ call: ToolCall) async -> ToolResultMessage {
        func msg(_ content: String) -> ToolResultMessage {
            ToolResultMessage(toolCallId: call.id, content: content)
        }
        // A foreground-only agent has no job handles of its own and must not
        // touch anyone else's — the tool is absent from its schema, so a
        // call can only be a hallucination (§3.3).
        if bashCapability == .foregroundOnly {
            return msg("{\"error\": \"bash_manage is not available for this agent — commands run in the foreground and return their result directly\"}")
        }
        let args = parseArgs(call.function.arguments)
        guard let mode = args.string("mode") else {
            return msg(isSubagentExecutor
                ? "{\"error\": \"bash_manage requires 'mode' (output, wait, input, kill, or list)\"}"
                : "{\"error\": \"bash_manage requires 'mode' (output, wait, input, watch, kill, or list)\"}")
        }

        // Validate the mode BEFORE demanding a handle. Subagents have no
        // 'watch': matches inject into the MAIN conversation, which must
        // never carry another agent's events.
        let validModes: [String] = isSubagentExecutor
            ? ["output", "wait", "input", "kill", "list"]
            : ["output", "wait", "input", "watch", "kill", "list"]
        guard validModes.contains(mode) else {
            if isSubagentExecutor, mode == "watch" {
                return msg("{\"error\": \"mode='watch' is not available for subagents (matches would be delivered outside your run) — poll with mode='output' or block with mode='wait' instead\"}")
            }
            let quoted = validModes.dropLast().map { "'\($0)'" }.joined(separator: ", ")
                + ", or '\(validModes.last ?? "")'"
            return msg("{\"error\": \"Unknown mode '\(escapeJSON(mode))'. Use \(quoted).\"}")
        }

        if mode == "list" {
            let includeSettled = args.bool("include_settled") ?? false
            return msg(await BashTools.list(includeSettled: includeSettled, owner: bashOwner).content)
        }

        guard let handle = args.string("handle") else {
            return msg("{\"error\": \"bash_manage requires 'handle'\"}")
        }

        switch mode {
        case "output":
            let since = args.int("since") ?? 0
            let sinceStderr = args.int("since_stderr") ?? 0
            let result = await BashTools.output(handle: handle, since: since, sinceStderr: sinceStderr, owner: bashOwner)
            // A settled snapshot carries an acknowledgement receipt (§8) —
            // forward it so the completion notice observed here is withdrawn
            // after the turn durably saves, instead of arriving as a duplicate.
            var message = ToolResultMessage(toolCallId: call.id, content: result.content,
                                            bashReceipt: result.receipt)
            message.outcomeBinding = Self.bashOutcomeBinding(result, launchCall: false)
            return message

        case "wait":
            let requested: Int
            switch args.strictInt("wait_seconds") {
            case .value(let v):
                requested = v
            case .absent:
                return msg("{\"error\": \"mode='wait' requires 'wait_seconds' (1-120)\"}")
            case .invalid(let raw):
                return msg("{\"error\": \"mode='wait' requires an integer wait_seconds (1-120) — got '\(escapeJSON(raw))'\"}")
            }
            guard requested >= 1 else {
                return msg("{\"error\": \"mode='wait' requires wait_seconds >= 1 — use mode='output' for a non-blocking snapshot\"}")
            }
            let since = args.int("since") ?? 0
            let sinceStderr = args.int("since_stderr") ?? 0
            let clamped = Double(min(requested, BashTools.maxWaitSeconds))
            let admission = consumeWaitAdmission(callId: call.id, handle: handle,
                                                requestedSeconds: clamped)
            let result: BashTools.OpResult
            switch admission {
            case .granted(let seconds):
                result = await BashTools.waitManage(
                    handle: handle, effectiveWaitSeconds: seconds, refusalReason: nil,
                    since: since, sinceStderr: sinceStderr, owner: bashOwner)
            case .refused(let reason):
                result = await BashTools.waitManage(
                    handle: handle, effectiveWaitSeconds: nil, refusalReason: reason,
                    since: since, sinceStderr: sinceStderr, owner: bashOwner)
            }
            if result.waitExpired { recordBashWaitTimeout(handle: handle) }
            var message = ToolResultMessage(toolCallId: call.id, content: result.content,
                                            bashReceipt: result.receipt)
            message.outcomeBinding = Self.bashOutcomeBinding(result, launchCall: false)
            return message

        case "input":
            guard let text = args.stringAllowingEmpty("text") else {
                return msg("{\"error\": \"mode='input' requires 'text'\"}")
            }
            let appendNewline = args.bool("append_newline") ?? false
            let result = await BashTools.input(handle: handle, text: text, appendNewline: appendNewline, owner: bashOwner)
            return msg(result.content)

        case "kill":
            let result = await BashTools.kill(handle: handle, owner: bashOwner)
            return msg(result.content)

        case "watch":
            guard let data = call.function.arguments.data(using: .utf8),
                  let watchArgs = try? JSONDecoder().decode(BashWatchArguments.self, from: data) else {
                return msg("{\"error\": \"mode='watch' requires 'pattern' (regex string)\"}")
            }
            let limit = max(1, min(watchArgs.limit ?? 10, 50))
            let result = await BackgroundProcessRegistry.shared.registerWatch(
                handle: handle,
                pattern: watchArgs.pattern,
                limit: limit,
                owner: bashOwner
            )
            switch result {
            case .success(let watchId):
                let payload: [String: Any] = [
                    "success": true,
                    "watch_id": watchId,
                    "handle": handle,
                    "pattern": watchArgs.pattern,
                    "limit": limit,
                    "note": "Output buffered before registration was scanned; new matches arrive as synthetic [BASH WATCH MATCH] user messages. Watch auto-unsubscribes after \(limit) matches or on process exit."
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
                   let str = String(data: data, encoding: .utf8) {
                    return msg(str)
                }
                return msg("{\"error\": \"failed to encode bash_manage watch response\"}")
            case .failure(let err):
                if case .handleNotFound = err {
                    return msg("{\"error\": \"\(escapeJSON(await BashTools.unknownHandleMessage(handle)))\"}")
                }
                return msg("{\"error\": \"\(escapeJSON(err.description))\"}")
            }

        default:
            // Unreachable: validModes is checked above. Kept for exhaustiveness.
            return msg("{\"error\": \"Unknown mode '\(mode)'. Use 'output', 'wait', 'input', 'watch', 'kill', or 'list'.\"}")
        }
    }

    // MARK: - todo_write

    func executeTodoWrite(_ call: ToolCall) async -> String {
        guard let data = call.function.arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTodos = obj["todos"] as? [[String: Any]]
        else {
            return "{\"error\": \"todo_write requires 'todos' as an array of {content, activeForm, status}\"}"
        }
        var parsed: [Todo] = []
        parsed.reserveCapacity(rawTodos.count)
        for (i, t) in rawTodos.enumerated() {
            guard let content = t["content"] as? String,
                  let activeForm = t["activeForm"] as? String,
                  let status = t["status"] as? String else {
                return "{\"error\": \"todos[\(i)] must have content, activeForm, status\"}"
            }
            parsed.append(Todo(content: content, activeForm: activeForm, status: status))
        }
        do {
            let updated = try await TodoStore.shared.replace(with: parsed)
            return serializeTodos(updated, message: "todo list updated (\(updated.count) item\(updated.count == 1 ? "" : "s"))")
        } catch {
            return "{\"error\": \"\(escapeJSON(String(describing: error)))\"}"
        }
    }

    private func serializeTodos(_ todos: [Todo], message: String) -> String {
        let payload: [String: Any] = [
            "success": true,
            "message": message,
            "todos": todos.map { [
                "content": $0.content,
                "activeForm": $0.activeForm,
                "status": $0.status
            ] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode todo result\"}"
    }

    // MARK: - lsp (unified hover/definition/references)

    func executeLSP(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let mode = args.string("mode") else {
            return "{\"error\": \"lsp requires 'mode' (hover, definition, references, document_symbols, workspace_symbols, or diagnostics)\"}"
        }
        guard let path = args.string("path") else {
            return "{\"error\": \"lsp requires 'path' (absolute)\"}"
        }

        switch mode {
        case "hover", "definition", "references":
            guard let line = args.int("line"), let column = args.int("column") else {
                return "{\"error\": \"mode='\(mode)' requires 'line' and 'column' (1-indexed like read_file output)\"}"
            }
            if mode == "hover" {
                return await LSPRegistry.shared.hover(path: path, line: line, column: column)
            }
            if mode == "definition" {
                return await LSPRegistry.shared.definition(path: path, line: line, column: column)
            }
            let includeDeclaration = args.bool("include_declaration") ?? true
            return await LSPRegistry.shared.references(path: path, line: line, column: column, includeDeclaration: includeDeclaration)
        case "document_symbols":
            return await LSPRegistry.shared.documentSymbols(path: path)
        case "workspace_symbols":
            guard let query = args.string("query") else {
                return "{\"error\": \"mode='workspace_symbols' requires 'query' (the symbol name or prefix to search for)\"}"
            }
            return await LSPRegistry.shared.workspaceSymbols(query: query, path: path)
        case "diagnostics":
            let normalized = FilesystemTools.normalizePath(path)
            guard FilesystemTools.isAbsolute(normalized) else {
                return "{\"error\": \"lsp requires an absolute 'path'\"}"
            }
            return await LSPRegistry.shared.diagnosticsPayload(path: normalized)
        default:
            return "{\"error\": \"Unknown mode '\(mode)'. Use 'hover', 'definition', 'references', 'document_symbols', 'workspace_symbols', or 'diagnostics'.\"}"
        }
    }

    private func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Argument parsing helper

    private func parseArgs(_ jsonString: String) -> ArgDict {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ArgDict(raw: [:])
        }
        return ArgDict(raw: obj)
    }

    fileprivate struct ArgDict {
        let raw: [String: Any]

        func string(_ key: String) -> String? {
            if let s = raw[key] as? String { return s.isEmpty ? nil : s }
            // Be permissive: models sometimes emit numbers/bools where strings are expected.
            if let n = raw[key] as? NSNumber { return n.stringValue }
            return nil
        }

        func stringAllowingEmpty(_ key: String) -> String? {
            if let s = raw[key] as? String { return s }
            // Be permissive: models sometimes emit numbers/bools where strings are expected.
            if let n = raw[key] as? NSNumber { return n.stringValue }
            return nil
        }

        func int(_ key: String) -> Int? {
            if let i = raw[key] as? Int { return i }
            if let d = raw[key] as? Double { return Int(d) }
            if let s = raw[key] as? String { return Int(s) }
            return nil
        }

        /// Strict integer parse for values where truncation changes meaning
        /// (bash lifecycle args: 0.5 truncated to 0 silently detaches the
        /// process). Fractional or non-numeric values are `.invalid`, never
        /// rounded.
        enum StrictIntResult {
            case absent
            case value(Int)
            case invalid(String)
        }

        func strictInt(_ key: String) -> StrictIntResult {
            guard let rawValue = raw[key] else { return .absent }
            // Genuine booleans are invalid (kill_after_seconds:true must not
            // become a 1s deadline). The check distinguishes CFBoolean from
            // numeric NSNumber, because SE-0170 bridging makes legitimate
            // JSON 0/1 pass a naive `is Bool` on Darwin. Then Int/Double
            // casts first (Linux corelibs yields native types), NSNumber as
            // the Darwin catch-all.
            if BashTools.isJSONBoolean(rawValue) {
                return .invalid((rawValue as? Bool).map { $0 ? "true" : "false" }
                                ?? ((rawValue as? NSNumber)?.boolValue == true ? "true" : "false"))
            }
            if let i = rawValue as? Int { return .value(i) }
            if let d = rawValue as? Double {
                guard d == d.rounded(), abs(d) < 9e15 else { return .invalid(String(d)) }
                return .value(Int(d))
            }
            if let n = rawValue as? NSNumber {
                let d = n.doubleValue
                guard d == d.rounded(), abs(d) < 9e15 else { return .invalid(n.stringValue) }
                return .value(Int(d))
            }
            if let s = rawValue as? String {
                if let i = Int(s) { return .value(i) }
                return .invalid(s)
            }
            return .invalid(String(describing: rawValue))
        }

        func bool(_ key: String) -> Bool? {
            if let b = raw[key] as? Bool { return b }
            if let s = raw[key] as? String {
                switch s.lowercased() {
                case "true", "yes", "1": return true
                case "false", "no", "0": return false
                default: return nil
                }
            }
            return nil
        }

        func stringDict(_ key: String) -> [String: String]? {
            if let dict = raw[key] as? [String: String], !dict.isEmpty { return dict }
            // Models sometimes emit the object as a JSON string.
            if let s = raw[key] as? String,
               let data = s.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               !dict.isEmpty { return dict }
            return nil
        }

        /// Extract an array of dictionaries (for nested object arrays like `edits`).
        /// Handles both native arrays and JSON-string-encoded arrays (some models emit strings).
        func objectArray(_ key: String) -> [[String: Any]]? {
            if let arr = raw[key] as? [[String: Any]], !arr.isEmpty { return arr }
            // Models sometimes emit the array as a JSON string.
            if let s = raw[key] as? String,
               let data = s.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               !arr.isEmpty { return arr }
            return nil
        }

        func stringArray(_ key: String) -> [String]? {
            if let values = raw[key] as? [String] {
                let normalized = values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return normalized.isEmpty ? nil : normalized
            }

            if let ignoreStr = string(key),
               let data = ignoreStr.data(using: .utf8),
               let values = try? JSONDecoder().decode([String].self, from: data) {
                let normalized = values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return normalized.isEmpty ? nil : normalized
            }

            return nil
        }
    }
}
