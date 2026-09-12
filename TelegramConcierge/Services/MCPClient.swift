import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// One decoded image content block from an MCP tool-call result.
struct MCPImageContent: Sendable {
    let data: Data
    let mimeType: String
}

/// Result of an MCP tool call: the concatenated text of all text/resource
/// blocks, plus any decoded image blocks. The ToolExecutor routes images into
/// the standard attachment pipeline (user-role multimodal injection; vision
/// OCR proxy for text-only models) instead of dropping them.
struct MCPToolCallResult: Sendable {
    let text: String
    let images: [MCPImageContent]
}

/// Owns one MCP-server subprocess. Serializes writes to stdin, decodes
/// newline-delimited JSON-RPC from stdout, correlates request IDs to async
/// continuations, and caches the discovered tool list from `tools/list`.
///
/// Lifecycle:
///   let c = MCPClient(config: cfg)
///   try await c.start()
///   try await c.initialize()
///   let tools = await c.listedTools
///   let result = try await c.callTool(name: "...", arguments: [:])
///   await c.shutdown()
actor MCPClient {

    // Configuration
    let serverName: String
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]

    // Subprocess
    private var process: Process?
    private var stdinHandle: FileHandle?

    // Read state. Chunks from the stdout pipe are queued in arrival order and
    // consumed by ONE task: a reply larger than a pipe read (playwright's
    // tools/list is ~30 KB) spans several chunks, and handing each chunk to
    // its own unordered Task let two of them land in the buffer swapped —
    // the frame then failed to decode, the buffer was reset, and the reply
    // was lost until the request timed out (seen as intermittent
    // "tools/list timed out … server unresponsive").
    private var readBuffer = Data()
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readerTask: Task<Void, Never>?
    private var chunkContinuation: AsyncStream<Data>.Continuation?

    // Request correlation
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    // Shutdown ownership. The first `shutdown()` caller creates the task
    // that performs the cleanup; every later caller joins THAT task (and may
    // tighten its plan), so "shutdown returned" means the same thing for all
    // of them: the shim is collected and the captured tree is gone, or the
    // caller's deadline passed. Codex round 2 R-A: the previous code cleared
    // `process` first, so a second caller saw nil, skipped the wait and
    // returned in ~0.1 ms while the first was still escalating descendants —
    // reachable whenever a bootstrap-failure cleanup or a registry reset
    // begins before the terminal shutdown arrives.
    private var shutdownTask: Task<Void, Never>?
    private var shutdownPlan: ShutdownPlan?

    // Status
    private(set) var isAlive: Bool = false
    /// The tracked child's pid (the `__setsid-exec` shim on the spawn path
    /// Foundation takes; the real server is its child in a private session).
    var processIdentifier: Int32? { process.map(\.processIdentifier) }
    private(set) var isInitialized: Bool = false

    // Cached tool list from `tools/list`. Populated during initialize().
    private(set) var listedTools: [MCPTool] = []

    // Capped ring of log lines from window/logMessage-equivalent notifications.
    private var logMessages: [String] = []
    private let logMessageCap = 200

    init(config: MCPServerConfig, resolvedEnvironment: [String: String]) {
        self.serverName = config.name
        self.executable = config.command
        self.arguments = config.arguments
        self.environment = resolvedEnvironment
    }

    // MARK: - Lifecycle

    func start() throws {
        // A client whose cleanup has begun stays down: a queued/late start
        // (a bootstrap racing a terminal shutdown) must not spawn a server
        // that the shutdown no longer knows about (Codex round 2 R-A).
        guard shutdownTask == nil else { throw MCPClientError.terminated }
        guard process == nil else { return }
        let proc = Process()

        // MCP servers are usually run via `npx` or `uvx`, so we need to locate
        // the executable through PATH. MCPRegistry resolves this up-front and
        // passes the absolute path; if it's still bare, let the shell do the
        // lookup via /usr/bin/env. Either way the server runs detached from
        // the controlling terminal (setsid trampoline): a startup command
        // that hits a /dev/tty prompt (sudo) fails fast instead of writing
        // `Password:` into Briglia's terminal.
        let resolved: (executable: String, arguments: [String]) =
            executable.hasPrefix("/")
                ? (executable, arguments)
                : ("/usr/bin/env", [executable] + arguments)
        let invocation = BashTools.detachedInvocation(
            executable: resolved.executable, arguments: resolved.arguments)
        proc.executableURL = URL(fileURLWithPath: invocation.executable)
        proc.arguments = invocation.arguments
        proc.environment = environment

        // macOS GUI apps launch with cwd=/. MCP servers that create files
        // relative to cwd (e.g. Playwright creating .playwright-mcp/) would
        // fail with ENOENT trying to write to /. Set a sane working directory.
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        proc.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            Task { await self.handleTermination() }
        }

        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        chunkContinuation = continuation
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            continuation.yield(data)
        }
        readerTask = Task { [weak self] in
            for await chunk in chunks {
                guard let self else { break }
                await self.ingest(chunk)
            }
        }

        // MCP servers sometimes emit diagnostic chatter on stderr; drain
        // without surfacing so it doesn't fill the pipe buffer.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try proc.run()
        } catch {
            throw MCPClientError.spawnFailed(error.localizedDescription)
        }

        self.process = proc
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.isAlive = true
    }

    func initialize(timeout: TimeInterval = 30) async throws {
        let params: [String: Any] = [
            "protocolVersion": MCPProtocol.version,
            "capabilities": [
                "roots": ["listChanged": false],
                "sampling": [String: Any]()
            ],
            "clientInfo": [
                "name": MCPProtocol.clientName,
                "version": MCPProtocol.clientVersion
            ]
        ]
        // Short timeout: initialize is awaited during turn-start bootstrap, so a
        // server that launches but never answers must not hang the agent.
        _ = try await sendRequest(method: "initialize", params: params, timeout: timeout)
        try sendNotification(method: "notifications/initialized", params: [String: Any]())
        isInitialized = true

        // Discover tools immediately so first-turn tool-list assembly is sync.
        try await refreshTools(timeout: timeout)
    }

    /// Grace between SIGTERM and SIGKILL. A Playwright server closes its
    /// browser on SIGTERM; give it a second before the whole tree is killed.
    static let shutdownGraceNanos: UInt64 = 1_000_000_000
    /// How long to wait for Foundation to collect the child after it died.
    static let shutdownReapBudgetNanos: UInt64 = 2_000_000_000

    /// True once a shutdown has begun (selftests: the overlap scenarios wait
    /// for this before the second caller arrives).
    var shutdownBegun: Bool { shutdownTask != nil }

    /// End the server and every process it spawned, and wait until the
    /// tracked child is actually gone and reaped — or until `deadline`.
    ///
    /// "terminate() returned" is not "the process is gone": the tracked pid
    /// is the `__setsid-exec` shim, the server lives in the private session
    /// the shim spawned, and a Playwright server may hold a browser tree. So
    /// this SIGTERMs the shim, the tree's process groups and every
    /// descendant pid, waits up to the grace period for the shim to be
    /// collected and the descendants to be gone, SIGKILLs survivors, then
    /// waits for the exit to be collected. Before this, the pre-exec restart
    /// path (`/upgrade`, `/restart`) never reached MCP servers at all, and
    /// one server tree per restart leaked in its own session (see
    /// LeftoverChildSweep).
    ///
    /// Every wait is bounded by the monotonic `deadline` when one is given
    /// (the exit path's): SIGKILL is sent no later than
    /// `deadline − ShutdownPlan.collectionReserveNanos`, so termination is
    /// initiated with time left for collection, however slow the polls run
    /// (Codex round 2 R-C: nominal sleep counting overran a 3 s budget under
    /// load). Overlapping callers all await the same cleanup; a later caller
    /// with an earlier deadline tightens it (R-A).
    func shutdown(deadline: ShutdownDeadline? = nil) async {
        if let running = shutdownTask {
            shutdownPlan?.tighten(to: deadline)
            await running.value
            return
        }
        let plan = ShutdownPlan(graceNanos: Self.shutdownGraceNanos,
                                reapNanos: Self.shutdownReapBudgetNanos,
                                deadline: deadline)
        shutdownPlan = plan
        let task = Task { await self.performShutdown(plan: plan) }
        shutdownTask = task
        await task.value
    }

    private func performShutdown(plan: ShutdownPlan) async {
        // Fail anything parked on the server first: a bootstrap suspended in
        // initialize() must not wait out its 30 s timeout once we're leaving.
        for (_, cont) in pendingRequests { cont.resume(throwing: MCPClientError.terminated) }
        pendingRequests.removeAll()
        if let proc = process {
            process = nil
            let pid = proc.processIdentifier
            // Capture the tree BEFORE anything that can end the server. Closing
            // stdin is itself a termination request (MCP has no shutdown
            // method; servers exit on EOF): a well-behaved server exits at
            // once, its shim follows, and a detached descendant reparents to
            // init before we could learn its pid (Codex R1). The table is read
            // through sysctl/procfs — no spawn, no delay.
            let tree = Self.captureTree(pid)
            try? stdinHandle?.close()
            stdinHandle = nil
            if proc.isRunning { proc.terminate() }
            for g in tree.groups { _ = Darwin.kill(-g, SIGTERM) }
            for kid in tree.descendants { _ = Darwin.kill(kid, SIGTERM) }
            // Grace: the shim collected AND every captured descendant gone —
            // a poll against the plan's kill instant (re-read every step, a
            // joiner may have tightened it), so a server that dies on
            // SIGTERM costs milliseconds and a stubborn one is SIGKILLed on
            // time whatever the machine load.
            var state = await Self.settle(proc, descendants: tree.descendants, until: { plan.killAt })
            if !state.collected || !state.survivors.isEmpty {
                if proc.isRunning { _ = Darwin.kill(pid, SIGKILL) }
                for g in tree.groups where Darwin.kill(-g, 0) == 0 { _ = Darwin.kill(-g, SIGKILL) }
                for kid in state.survivors { _ = Darwin.kill(kid, SIGKILL) }
                state = await Self.settle(proc, descendants: state.survivors, until: { plan.giveUpAt })
            }
            if !state.collected || !state.survivors.isEmpty {
                FileHandle.standardError.write(Data(
                    "[MCP] \(serverName): shutdown budget exhausted — shim \(pid) \(state.collected ? "collected" : "NOT collected"), descendants still alive: \(state.survivors)\n".utf8))
            }
        } else {
            try? stdinHandle?.close()
            stdinHandle = nil
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        readerTask = nil
        stdoutPipe = nil
        stderrPipe = nil
        isAlive = false
        isInitialized = false
    }

    /// Descendants and process groups of the tracked child, from a
    /// spawn-free table snapshot; `pgrep`-based fallback when the table
    /// cannot be read.
    private static func captureTree(_ pid: Int32) -> (descendants: [Int32], groups: [Int32]) {
        if let table = LeftoverChildSweep.snapshot() {
            return LeftoverChildSweep.tree(rootPid: pid, table: table)
        }
        let kids = ProcessTree.descendants(of: pid)
        return (kids, ProcessTree.processGroups(rootPid: pid, descendants: kids))
    }

    /// Poll until the child is COLLECTED and every descendant is gone, or
    /// the instant `until()` returns has passed on the monotonic clock (not
    /// a count of nominal sleeps). Collected means Foundation's reaper ran
    /// (`isRunning` false) — on Linux corelibs that happens only once the
    /// exit-detection socket the child inherited to its descendants is
    /// closed, which is exactly why the descendants are ended here rather
    /// than assumed dead: a `/proc` zombie is exited, not reaped (Codex R5).
    /// Never `waitpid`s the Foundation-managed pid itself.
    private static func settle(_ proc: Process, descendants: [Int32],
                               until deadline: () -> ShutdownDeadline) async -> (collected: Bool, survivors: [Int32]) {
        var survivors = descendants
        let step: UInt64 = 50_000_000
        while true {
            let collected = !proc.isRunning
            if !survivors.isEmpty {
                let table = LeftoverChildSweep.snapshot()
                survivors = survivors.filter { !LeftoverChildSweep.isGone($0, table: table) }
            }
            let limit = deadline()
            if (collected && survivors.isEmpty) || limit.hasPassed { return (collected, survivors) }
            await limit.sleepStep(step)
        }
    }

    // MARK: - Tools

    func refreshTools(timeout: TimeInterval = 30) async throws {
        let result = try await sendRequest(method: "tools/list", params: [String: Any](), timeout: timeout)
        let raw: [Any]
        if let arr = result["tools"] as? [Any] {
            raw = arr
        } else if let wrapped = result["__value__"] as? [Any] {
            raw = wrapped
        } else {
            raw = []
        }
        var parsed: [MCPTool] = []
        for item in raw {
            guard let dict = item as? [String: Any],
                  let name = dict["name"] as? String else { continue }
            let description = dict["description"] as? String ?? ""
            let schema = (dict["inputSchema"] as? [String: Any]) ?? [:]
            parsed.append(MCPTool(
                serverName: serverName,
                toolName: name,
                description: description,
                inputSchema: schema
            ))
        }
        // Alphabetical sort for prompt-cache stability: the ToolDefinition
        // array emitted to the LLM must be byte-identical turn over turn.
        parsed.sort { $0.toolName < $1.toolName }
        listedTools = parsed
    }

    /// Call a tool by its ORIGINAL name (without the `mcp__<server>__` prefix).
    /// Returns the concatenated text of all `content` blocks (or a JSON error
    /// string if the server flagged `isError`), plus any decoded image blocks.
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolCallResult {
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments
        ]
        let result = try await sendRequest(method: "tools/call", params: params)

        // MCP tool-call result shape:
        //   { content: [{ type: "text"|"image"|..., text?: string, ... }], isError?: bool }
        let isError = (result["isError"] as? Bool) ?? false
        let contentBlocks = (result["content"] as? [[String: Any]]) ?? []

        var pieces: [String] = []
        var images: [MCPImageContent] = []
        for block in contentBlocks {
            let type = (block["type"] as? String) ?? ""
            switch type {
            case "text":
                if let text = block["text"] as? String {
                    pieces.append(text)
                }
            case "image":
                // Decode image blocks so the executor can hand them to the
                // attachment pipeline. Undecodable blocks degrade to a stub.
                let mime = (block["mimeType"] as? String) ?? "image/png"
                if let b64 = block["data"] as? String,
                   let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                   !data.isEmpty {
                    images.append(MCPImageContent(data: data, mimeType: mime))
                    pieces.append("[image \(images.count): \(mime) — attached]")
                } else {
                    pieces.append("[image: \(mime) — could not decode base64 data]")
                }
            case "resource":
                if let resource = block["resource"] as? [String: Any] {
                    let uri = resource["uri"] as? String ?? "?"
                    let text = resource["text"] as? String ?? ""
                    pieces.append("[resource \(uri)]\n\(text)")
                }
            default:
                // Unknown content type — serialize the raw block for debugging.
                if let data = try? JSONSerialization.data(withJSONObject: block, options: [.withoutEscapingSlashes]),
                   let str = String(data: data, encoding: .utf8) {
                    pieces.append(str)
                }
            }
        }

        let joined = pieces.joined(separator: "\n\n")
        if isError {
            return MCPToolCallResult(
                text: "{\"error\": \"MCP tool '\(name)' on server '\(serverName)' returned isError\", \"content\": \(jsonEscape(joined))}",
                images: images
            )
        }
        return MCPToolCallResult(text: joined.isEmpty ? "{\"success\": true}" : joined, images: images)
    }

    // MARK: - Private: IO

    /// Send a JSON-RPC request with a hard timeout. Without one, a continuation
    /// parked in `pendingRequests` resumes only on a server reply or process
    /// death — a live-but-unresponsive server (stuck on stdin, corrupt framing)
    /// would hang the caller forever. Since `initialize` is awaited during
    /// turn-start bootstrap and `tools/call` inside turns, that meant one bad
    /// MCP server could silently freeze the whole agent.
    private func sendRequest(method: String, params: Any?, timeout: TimeInterval = 120) async throws -> [String: Any] {
        guard isAlive, let stdin = stdinHandle else { throw MCPClientError.notStarted }
        let id = nextRequestId
        nextRequestId += 1
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params = params { msg["params"] = params }
        let data = try MCPFraming.encode(msg)

        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.timeoutRequest(id: id, method: method, seconds: Int(timeout))
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            pendingRequests[id] = cont
            do {
                try stdin.write(contentsOf: data)
            } catch {
                pendingRequests.removeValue(forKey: id)
                cont.resume(throwing: MCPClientError.writeFailed(error.localizedDescription))
            }
        }
    }

    /// Resume a parked request with a timeout error. A reply that arrives later
    /// finds no pending continuation and is ignored by `dispatch`.
    private func timeoutRequest(id: Int, method: String, seconds: Int) {
        guard let cont = pendingRequests.removeValue(forKey: id) else { return }
        appendLog("[\(serverName)] request '\(method)' timed out after \(seconds)s")
        cont.resume(throwing: MCPClientError.timedOut(method: method, seconds: seconds))
    }

    private func sendNotification(method: String, params: Any?) throws {
        guard isAlive, let stdin = stdinHandle else { throw MCPClientError.notStarted }
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params = params { msg["params"] = params }
        let data = try MCPFraming.encode(msg)
        do {
            try stdin.write(contentsOf: data)
        } catch {
            throw MCPClientError.writeFailed(error.localizedDescription)
        }
    }

    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while true {
            do {
                guard let message = try MCPFraming.decodeNext(buffer: &readBuffer) else {
                    break
                }
                dispatch(message)
            } catch {
                // Unrecoverable decoder state — reset buffer and bail.
                readBuffer.removeAll()
                break
            }
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["method"] == nil {
            if let cont = pendingRequests.removeValue(forKey: id) {
                if let err = message["error"] as? [String: Any] {
                    let msg = err["message"] as? String ?? "MCP error"
                    cont.resume(throwing: MCPClientError.responseError(msg))
                } else if let resultDict = message["result"] as? [String: Any] {
                    cont.resume(returning: resultDict)
                } else if let resultArray = message["result"] as? [Any] {
                    cont.resume(returning: ["__value__": resultArray])
                } else {
                    cont.resume(returning: [:])
                }
            }
            return
        }

        if let method = message["method"] as? String {
            handleServerMessage(method: method, params: message["params"], id: message["id"])
        }
    }

    private func handleServerMessage(method: String, params: Any?, id: Any?) {
        switch method {
        case "notifications/message":
            if let dict = params as? [String: Any],
               let data = dict["data"] as? String {
                appendLog("[\(serverName)] \(data)")
            }
        case "notifications/tools/list_changed":
            // Server signals tool list changed. Refresh asynchronously so we
            // don't block the decoder actor. The cached ToolDefinitions will
            // be stale for one turn — acceptable for Phase 1.
            Task { try? await self.refreshTools() }
        default:
            // $/progress, server→client sampling requests, etc. Accept-and-ignore.
            _ = id
            break
        }
    }

    private func handleTermination() {
        isAlive = false
        isInitialized = false
        for (_, cont) in pendingRequests {
            cont.resume(throwing: MCPClientError.terminated)
        }
        pendingRequests.removeAll()
    }

    private func appendLog(_ line: String) {
        logMessages.append(line)
        if logMessages.count > logMessageCap {
            logMessages.removeFirst(logMessages.count - logMessageCap)
        }
    }

    private func jsonEscape(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8),
           str.count >= 2 {
            return String(str.dropFirst().dropLast())
        }
        return "\"\""
    }

    // MARK: - Introspection

    func currentLogMessages() -> [String] { logMessages }
}
