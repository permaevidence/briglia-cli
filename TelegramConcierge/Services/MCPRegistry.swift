import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Singleton actor: owns every connected MCP client, reads `~/.config/briglia/mcp.json`,
/// resolves Keychain-backed secrets into the spawn environment, bootstraps
/// servers on first use, caches the merged tool list as native
/// `ToolDefinition`s for the LLM tool block, and dispatches `tools/call`
/// requests from `ToolExecutor`.
///
/// Phase 1 behavior: lazy-but-eager. The first call to `allToolDefinitions()`
/// in a session triggers `bootstrap()` which spawns every configured server
/// in parallel, waits for each handshake to complete (or fail), and caches
/// the result for the lifetime of the session. Subsequent calls are O(1).
///
/// Tool-list stability is preserved by:
///   - alphabetical sort inside each client's refreshTools()
///   - alphabetical sort of server names when merging
///   - never re-spawning mid-session unless a client actually crashed
actor MCPRegistry {

    public static let shared = MCPRegistry()

    private struct Entry {
        let client: MCPClient
        let config: MCPServerConfig
        var failed: Bool
        var failureReason: String?
    }

    private var entries: [String: Entry] = [:]   // key = server name
    private var bootstrapTask: Task<Void, Never>?
    private var didBootstrap: Bool = false
    /// Clients a bootstrap has spawned but not yet published (or shut down).
    /// Owned by the registry from the moment they are created, so a terminal
    /// shutdown reaches a server whose initialize is still pending (Codex R3:
    /// a non-answering server blocks bootstrap for up to 30 s; the old
    /// teardown awaited that before it could touch anything).
    private var inFlight: [ObjectIdentifier: MCPClient] = [:]
    /// Set by `shutdownAll()`: no bootstrap or spawn starts after it. Re-armed
    /// only by an explicit `reloadFromDisk()` (a deliberate new generation).
    private var isShuttingDown = false
    /// Bumped by every teardown (`reloadFromDisk`, `shutdownAll`). A
    /// bootstrap publishes its clients only if the generation it started in
    /// is still current; otherwise it shuts them down (Codex, Release C
    /// round 1 #1: a reload during an in-flight bootstrap must not let the
    /// stale bootstrap repopulate `entries` or leak a client process).
    private var generation = 0

    /// Canonical accepted-tool registry (`MCPToolSurface`), rebuilt from the
    /// connected clients' tool lists on every `allToolDefinitions()` call
    /// (once per turn) and after every reload. Every dispatch and every
    /// prompt-visible string derives from it.
    private var surface = MCPToolSurface.empty
    private var surfaceBuilt = false
    private var loggedRefusalServers: Set<String> = []

    private init() {}

    // MARK: - Public API

    /// Returns every accepted MCP tool as a native `ToolDefinition`, ready to
    /// append to the LLM tool block. Sorted deterministically by alias so the
    /// output is byte-stable across turns — critical for prompt-cache hits.
    ///
    /// Triggers bootstrap on first call and rebuilds the tool surface. Per-agent
    /// filtering (including always vs deferred) is handled by `MCPAgentRouting`.
    func allToolDefinitions() async -> [ToolDefinition] {
        await ensureBootstrapped()
        await rebuildSurface()
        return surface.sortedDefinitions
    }

    /// The current accepted-tool registry (built if needed). `MCPAgentRouting`
    /// snapshots it once per turn for its sync consumers.
    func currentSurface() async -> MCPToolSurface {
        await ensureBootstrapped()
        if !surfaceBuilt { await rebuildSurface() }
        return surface
    }

    private func rebuildSurface() async {
        var servers: [(config: MCPServerConfig, tools: [MCPTool])] = []
        for (_, entry) in entries.sorted(by: { $0.key < $1.key }) where !entry.failed {
            servers.append((entry.config, await entry.client.listedTools))
        }
        let built = MCPToolSurface.build(servers: servers)
        // Log refusals once per server (a hostile server would otherwise spam
        // the log every turn).
        var byServer: [String: [MCPToolSurface.Refusal]] = [:]
        for refusal in built.refusals { byServer[refusal.serverName, default: []].append(refusal) }
        for (serverName, refusals) in byServer.sorted(by: { $0.key < $1.key })
        where !loggedRefusalServers.contains(serverName) {
            loggedRefusalServers.insert(serverName)
            let detail = refusals.map { "\($0.toolName): \($0.reason)" }.joined(separator: "; ")
            DebugTelemetry.log(
                .toolError,
                summary: "mcp tools refused on \(serverName) (\(refusals.count))",
                detail: detail,
                isError: true
            )
        }
        surface = built
        surfaceBuilt = true
    }

    /// Compact summaries for the given server **handles**. Each entry carries
    /// the handle, an escaped description (user-provided or auto-generated
    /// from tool aliases), and the accepted-tool count. Used for the
    /// on-demand MCP section of the system prompt. Which servers are
    /// deferred is decided by MCPAgentRouting, not here.
    func serverSummaries(for handles: Set<String>) async -> [(name: String, description: String, toolCount: Int)] {
        let current = await currentSurface()
        var out: [(String, String, Int)] = []
        for handle in handles {
            guard let server = current.server(handle: handle), !server.aliases.isEmpty else { continue }
            out.append((handle, current.promptDescription(handle: handle), server.aliases.count))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Formatted text block describing every accepted tool on the server with
    /// this **handle** (raw server names are not accepted). Intended as the
    /// result of `tool_search`.
    func toolSchemasForServer(_ handle: String) async -> String? {
        let current = await currentSurface()
        return current.schemaListing(handle: handle)
    }

    /// Dispatch a tool call from `ToolExecutor` by the wire name the model
    /// used: a canonical alias, or — during the grace release — a legacy raw
    /// name that resolves through the validated reverse map to exactly one
    /// accepted tool. Unknown names never reach a server.
    func callTool(name: String, argumentsJSON: String) async -> MCPToolCallResult {
        let current = await currentSurface()
        return await dispatch(current.resolve(name: name), requested: name, argumentsJSON: argumentsJSON)
    }

    /// `mcp_call` dispatch: `serverHandle` must be a handle from the on-demand
    /// list; `tool` is the alias or its tool segment (legacy raw pairs resolve
    /// only through the reverse map while the grace flag is on).
    func callTool(serverHandle: String, tool: String, argumentsJSON: String) async -> MCPToolCallResult {
        let current = await currentSurface()
        let requested = "\(serverHandle)/\(tool)"
        return await dispatch(current.resolve(serverHandle: serverHandle, tool: tool),
                              requested: requested, argumentsJSON: argumentsJSON)
    }

    private func dispatch(_ resolution: MCPToolSurface.Resolution, requested: String, argumentsJSON: String) async -> MCPToolCallResult {
        let accepted: MCPToolSurface.AcceptedTool
        // The requested name is model-supplied text; neutralize before it is
        // echoed back into a tool result.
        let requested = MarkerNeutralizer.escape(requested)
        switch resolution {
        case .tool(let tool):
            accepted = tool
        case .unknown:
            return MCPToolCallResult(text: jsonError("Unknown MCP tool '\(requested)' — use tool_search(server: <handle>) to list the canonical tool names"), images: [])
        case .ambiguous(let owners):
            return MCPToolCallResult(text: jsonError("Legacy MCP tool name '\(requested)' is ambiguous (\(owners.joined(separator: ", "))) — use the canonical alias"), images: [])
        case .legacyRefused(let alias):
            let hint = alias.map { "use \($0)" } ?? "use the canonical alias from tool_search"
            return MCPToolCallResult(text: jsonError("Legacy MCP tool name '\(requested)' is no longer accepted — \(hint)"), images: [])
        }
        guard let entry = entries[accepted.serverName], !entry.failed else {
            let reason = entries[accepted.serverName]?.failureReason ?? "not installed or not configured"
            return MCPToolCallResult(text: jsonError("MCP server '\(accepted.serverHandle)' unavailable (\(reason))"), images: [])
        }

        // Parse arguments. Empty string → empty dict. Anything else must be a
        // JSON object.
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let args: [String: Any]
        if trimmed.isEmpty {
            args = [:]
        } else if let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        } else {
            return MCPToolCallResult(text: jsonError("MCP tool '\(accepted.alias)' expected a JSON object for arguments"), images: [])
        }

        do {
            return try await entry.client.callTool(name: accepted.toolName, arguments: args)
        } catch {
            return MCPToolCallResult(text: jsonError("MCP tool '\(accepted.alias)' failed: \(error)"), images: [])
        }
    }

    /// Status snapshot for settings UI / telemetry. Reports every configured
    /// server — connected, disabled, or failed.
    func status() async -> [(name: String, connected: Bool, failed: Bool, reason: String?, toolCount: Int)] {
        await ensureBootstrapped()
        var out: [(String, Bool, Bool, String?, Int)] = []
        for (name, entry) in entries {
            let alive = await entry.client.isAlive
            let tools = await entry.client.listedTools
            out.append((name, alive, entry.failed, entry.failureReason, tools.count))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Terminal shutdown: end every server this registry owns — published
    /// AND still bootstrapping — and wait until each is gone and reaped.
    /// Called from the CLI's pre-exec / exit shutdown
    /// (`TerminalSession.shutdownChildProcesses`).
    ///
    /// Unlike `reloadFromDisk`, this does not wait for an in-flight bootstrap
    /// to finish: it refuses further bootstrap/spawn work, takes ownership of
    /// the in-flight clients, and shuts every client down CONCURRENTLY, so
    /// the total is bounded by one client's grace + collection budget rather
    /// than the server count or a stuck initialize.
    func shutdownAll() async {
        isShuttingDown = true
        generation += 1
        let owned = entries.values.map(\.client) + Array(inFlight.values)
        entries.removeAll()
        inFlight.removeAll()
        didBootstrap = false
        bootstrapTask = nil
        surface = .empty
        surfaceBuilt = false
        await withTaskGroup(of: Void.self) { group in
            for client in owned {
                group.addTask { await client.shutdown() }
            }
        }
    }

    /// The tracked child pid of every connected server (selftests and
    /// diagnostics; nil for servers that never spawned).
    func spawnedProcessIdentifiers() async -> [String: Int32] {
        var out: [String: Int32] = [:]
        for (name, entry) in entries {
            if let pid = await entry.client.processIdentifier { out[name] = pid }
        }
        return out
    }

    /// Every tracked child pid the registry owns right now: published
    /// servers and clients still bootstrapping (selftests).
    func ownedProcessIdentifiers() async -> [Int32] {
        var out: [Int32] = []
        for entry in entries.values {
            if let pid = await entry.client.processIdentifier { out.append(pid) }
        }
        for client in inFlight.values {
            if let pid = await client.processIdentifier { out.append(pid) }
        }
        return out.sorted()
    }

    /// Tear down every running client and re-bootstrap from the current
    /// on-disk config. Called after mcp.json is rewritten (managed Playwright
    /// switch, profile import) so changes take effect without a restart.
    func reloadFromDisk() async {
        await teardown()
        isShuttingDown = false
        loggedRefusalServers.removeAll()
        await ensureBootstrapped()
        await rebuildSurface()
    }

    /// Invalidate the current generation, let an in-flight bootstrap finish
    /// (it will shut its clients down instead of publishing them), then
    /// shut down and forget every published client.
    private func teardown() async {
        generation += 1
        if let inFlight = bootstrapTask {
            await inFlight.value
        }
        for entry in entries.values {
            await entry.client.shutdown()
        }
        entries.removeAll()
        didBootstrap = false
        bootstrapTask = nil
        surface = .empty
        surfaceBuilt = false
    }

    // MARK: - Config persistence (for Settings UI)

    /// Public wrapper around the private on-disk loader. Used by the MCPs
    /// settings panel to render the current configuration.
    nonisolated static func loadConfigsFromDisk() -> [MCPServerConfig] {
        loadConfigs()
    }

    /// Write the full mcp.json atomically. Sorted by server name for
    /// reviewable diffs. Does NOT restart running clients — call
    /// `await MCPRegistry.shared.reloadFromDisk()` afterwards if the changes
    /// need to take effect immediately.
    nonisolated static func saveConfigsToDisk(_ configs: [MCPServerConfig]) throws {
        var servers: [String: Any] = [:]
        for cfg in configs.sorted(by: { $0.name < $1.name }) {
            var dict: [String: Any] = [
                "command": cfg.command,
                "args": cfg.arguments
            ]
            if !cfg.environment.isEmpty { dict["env"] = cfg.environment }
            if cfg.disabled { dict["disabled"] = true }
            if !cfg.secretRefs.isEmpty { dict["secretRefs"] = cfg.secretRefs }
            if let desc = cfg.description, !desc.isEmpty { dict["description"] = desc }
            if let managed = cfg.managed, !managed.isEmpty { dict["managed"] = managed }
            servers[cfg.name] = dict
        }
        let root: [String: Any] = ["mcpServers": servers]
        let url = mcpConfigURL()
        try PrivateStorage.ensureDirectory(url.deletingLastPathComponent())
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        // Owner-only (plan H2.4): `env` may carry plaintext secrets.
        try PrivateStorage.writeAtomically(data, to: url, mode: 0o600)
    }

    public static func mcpConfigPath() -> String {
        mcpConfigURL().path
    }

    /// Selftest seam: runs inside the config lock during `mergeServers`,
    /// after the read and before the write.
    nonisolated(unsafe) static var testHookInsideMerge: (() -> Void)?

    /// Actor-serialized read-modify-write of mcp.json under the config lock
    /// (profile import): `transform` sees the servers as loaded and returns
    /// the full list to save. The official writers of mcp.json are this
    /// actor's methods; the file tools share the same sidecar lock.
    func mergeServers(_ transform: ([MCPServerConfig]) throws -> [MCPServerConfig]) throws {
        try MCPAgentRouting.withConfigLock {
            let existing = Self.loadConfigs()
            let merged = try transform(existing)
            Self.testHookInsideMerge?()
            try Self.saveConfigsToDisk(merged)
        }
    }

    enum ManagedEntryUpdate: Equatable {
        /// The playwright entry now references `playwright-<token>`.
        case switched(from: ManagedPlaywright.EntryShape)
        /// It already did.
        case alreadyCurrent
        /// User-authored / edited / disabled: not touched.
        case leftAlone(ManagedPlaywright.EntryShape)
        /// No entry existed and `addIfAbsent` was false.
        case absent
        case failed(String)
    }

    /// Selftest seam: runs inside the config lock, after the decision and
    /// before the write.
    nonisolated(unsafe) static var testHookBeforeManagedConfigWrite: (() -> Void)?

    /// The switch (plan §H4.4 item 5), under the `mcp-config.lock` sidecar
    /// shared with the file tools: ONE raw-JSON snapshot of `mcp.json` is
    /// read, the playwright entry's shape is decided from that same
    /// snapshot, and only its `command`/`args`/`managed` change — every other
    /// key of that entry and every other server survive exactly as parsed
    /// (including keys this build does not know). Refuses to reference a
    /// directory without its completion marker (managed-entry verification).
    /// Does not restart clients — the caller reloads.
    func updateManagedPlaywrightEntry(token: String, layout: ManagedPlaywright.Layout,
                                      addIfAbsent: Bool,
                                      crashAfterWrite: Bool = false) -> ManagedEntryUpdate {
        let marker = layout.versionDirectory(token: token).appendingPathComponent(ManagedPlaywright.completionMarkerName)
        guard (try? String(contentsOf: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == ManagedPlaywright.Layout.lockfileHash(ofToken: token) else {
            return .failed("playwright-\(token) has no valid completion marker — not referencing it")
        }
        let url = Self.mcpConfigURL()
        do {
            return try MCPAgentRouting.withConfigLock {
                var root: [String: Any] = [:]
                if let data = FileManager.default.contents(atPath: url.path) {
                    guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return .failed("mcp.json is not a JSON object — left untouched")
                    }
                    root = parsed
                }
                var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
                let rawEntry = servers[ManagedPlaywright.serverName] as? [String: Any]
                let current = rawEntry.flatMap { Self.parseConfig(name: ManagedPlaywright.serverName, dict: $0) }
                let shape = ManagedPlaywright.shape(of: current, layout: layout)
                switch shape {
                case .managed(let existing) where existing == token:
                    return .alreadyCurrent
                case .managed, .legacyAuto:
                    break
                case .absent:
                    guard addIfAbsent else { return .absent }
                case .managedEdited, .userAuthored, .disabled:
                    return .leftAlone(shape)
                }
                let invocation = ManagedPlaywright.managedInvocation(token: token, layout: layout)
                var entry = rawEntry ?? ["description": ManagedPlaywright.defaultDescription]
                entry["command"] = invocation.command
                entry["args"] = invocation.arguments
                entry["managed"] = ManagedPlaywright.managedMarker(token: token)
                servers[ManagedPlaywright.serverName] = entry
                root["mcpServers"] = servers
                Self.testHookBeforeManagedConfigWrite?()
                do {
                    try PrivateStorage.ensureDirectory(url.deletingLastPathComponent())
                    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
                    try PrivateStorage.writeAtomically(data, to: url, mode: 0o600)
                } catch {
                    return .failed("could not write mcp.json: \(error)")
                }
                if crashAfterWrite { _exit(137) }
                return .switched(from: shape)
            }
        } catch {
            return .failed("config lock: \(error)")
        }
    }

    // MARK: - Bootstrap

    private func ensureBootstrapped() async {
        if isShuttingDown || didBootstrap { return }
        if let existing = bootstrapTask {
            await existing.value
            return
        }
        let task = Task { await self.bootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func bootstrap() async {
        let startedIn = generation
        defer {
            if startedIn == generation {
                didBootstrap = true
                bootstrapTask = nil
            }
        }
        let configs = Self.loadConfigs()
        guard !configs.isEmpty else { return }

        // Spawn in parallel so one slow server (npx cold start) doesn't block
        // the others. Each task yields a local entry on success or a
        // failure marker on error; nothing is published until every spawn
        // has settled, and only if no teardown happened meanwhile.
        var spawned: [String: Entry] = [:]
        await withTaskGroup(of: (String, Entry).self) { group in
            for cfg in configs {
                group.addTask {
                    await self.spawnOne(config: cfg)
                }
            }
            for await (name, entry) in group {
                spawned[name] = entry
            }
        }
        // The clients leave `inFlight` only here: published, or shut down
        // because a teardown/shutdown happened meanwhile (in which case
        // shutdownAll already ended them; shutdown() is idempotent).
        for entry in spawned.values { inFlight.removeValue(forKey: ObjectIdentifier(entry.client)) }
        if startedIn == generation && !isShuttingDown {
            entries = spawned
        } else {
            for entry in spawned.values { await entry.client.shutdown() }
        }
    }

    private func spawnOne(config: MCPServerConfig) async -> (String, Entry) {
        if config.disabled {
            let client = MCPClient(config: config, resolvedEnvironment: [:])
            return (config.name, Entry(client: client, config: config, failed: true, failureReason: "disabled in mcp.json"))
        }

        let env = Self.resolveEnvironment(for: config)
        let resolved = Self.resolveExecutable(config: config)
        let client = MCPClient(config: resolved, resolvedEnvironment: env)
        // Owned before it is started: a terminal shutdown that lands while
        // start()/initialize() is pending finds it in `inFlight`.
        guard !isShuttingDown else {
            return (config.name, Entry(client: client, config: config, failed: true, failureReason: "shutting down"))
        }
        inFlight[ObjectIdentifier(client)] = client

        do {
            try await client.start()
            try await client.initialize()
            DebugTelemetry.log(
                .toolStart,
                summary: "mcp spawn ok: \(config.name)",
                detail: "\(resolved.command) \(resolved.arguments.joined(separator: " "))"
            )
            return (config.name, Entry(client: client, config: config, failed: false, failureReason: nil))
        } catch {
            await client.shutdown()
            DebugTelemetry.log(
                .toolError,
                summary: "mcp spawn failed: \(config.name)",
                detail: String(describing: error),
                isError: true
            )
            return (config.name, Entry(
                client: client,
                config: config,
                failed: true,
                failureReason: String(describing: error)
            ))
        }
    }

    // MARK: - Config loading

    private static func loadConfigs() -> [MCPServerConfig] {
        let url = mcpConfigURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let servers = root["mcpServers"] as? [String: Any] else { return [] }

        var out: [MCPServerConfig] = []
        for (name, raw) in servers {
            guard let dict = raw as? [String: Any], let cfg = parseConfig(name: name, dict: dict) else { continue }
            out.append(cfg)
        }
        return out.sorted { $0.name < $1.name }
    }

    /// One server entry of `mcpServers` → config (nil without a command).
    /// Shared by the loader and the managed switch so both decide from the
    /// same parse.
    nonisolated static func parseConfig(name: String, dict: [String: Any]) -> MCPServerConfig? {
        guard let command = dict["command"] as? String else { return nil }
        return MCPServerConfig(
            name: name,
            command: command,
            arguments: (dict["args"] as? [String]) ?? [],
            environment: (dict["env"] as? [String: String]) ?? [:],
            disabled: (dict["disabled"] as? Bool) ?? false,
            secretRefs: (dict["secretRefs"] as? [String]) ?? [],
            description: dict["description"] as? String,
            managed: dict["managed"] as? String
        )
    }

    private static func mcpConfigURL() -> URL {
        return StoragePaths.configRoot.appendingPathComponent("mcp.json")
    }

    /// Public path to mcp.json (bootstrap freshness check, prompts).
    nonisolated static var configFileURL: URL { mcpConfigURL() }

    // MARK: - Environment & executable resolution

    /// Merge: inherited PATH/HOME/etc. + config.env + Keychain-backed secrets.
    /// Keychain keys are `mcp_env_<server>_<VAR>` (populated via Settings in
    /// a later phase). Plaintext values in mcp.json's `env` block take
    /// precedence for explicit overrides, but users are expected to put
    /// secrets in the Keychain.
    private static func resolveEnvironment(for config: MCPServerConfig) -> [String: String] {
        var env = baseEnvironment()
        for (k, v) in config.environment { env[k] = v }
        for ref in config.secretRefs {
            let key = "mcp_env_\(config.name)_\(ref)"
            if let value = KeychainHelper.load(key: key), !value.isEmpty {
                env[ref] = value
            }
        }
        return env
    }

    /// Internal: `ManagedPlaywright` runs npm and its verification handshake
    /// in the same environment the server will later be spawned with.
    nonisolated static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Augment PATH with common install locations so `npx`, `uvx`,
        // `bun`, `python3`, etc. resolve reliably from a GUI-launched
        // subprocess environment.
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(env["HOME"] ?? "")/.local/bin",
            "\(env["HOME"] ?? "")/.bun/bin",
            "\(env["HOME"] ?? "")/.cargo/bin"
        ]
        let existing = env["PATH"] ?? ""
        var parts = existing.split(separator: ":").map(String.init)
        for extra in extras where !parts.contains(extra) {
            parts.insert(extra, at: 0)
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    /// If `command` is bare (no slash), try to resolve via the augmented
    /// PATH. Returns the config with the absolute path filled in so MCPClient
    /// doesn't need to do its own lookup. Falls through untouched on miss.
    private static func resolveExecutable(config: MCPServerConfig) -> MCPServerConfig {
        if config.command.contains("/") { return config }
        let env = baseEnvironment()
        let path = env["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(config.command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return MCPServerConfig(
                    name: config.name,
                    command: candidate,
                    arguments: config.arguments,
                    environment: config.environment,
                    disabled: config.disabled,
                    secretRefs: config.secretRefs,
                    description: config.description,
                    managed: config.managed
                )
            }
        }
        return config
    }

    // MARK: - Name routing

    /// Tool conversion, aliasing and name resolution live in
    /// `MCPToolSurface` (Services/MCPToolSurface.swift). The registry only
    /// answers "does this wire name belong to the MCP namespace?" — every
    /// actual lookup goes through the accepted-tool registry.
    public static func isMCPPrefixed(_ name: String) -> Bool {
        name.hasPrefix("mcp__")
    }

    // MARK: - Helpers

    private func jsonError(_ msg: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: ["error": msg], options: [.withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"MCP error\"}"
    }
}

// MARK: - Node.js direct installer

/// Downloads the official Node.js LTS tarball from nodejs.org (verified
/// against the release's SHASUMS256.txt), extracts it to ~/.local/node and
/// links node/npm/npx into ~/.local/bin — a directory every Briglia subprocess
/// PATH already covers (MCPRegistry.baseEnvironment, BashTools.augmentedPath).
/// No Homebrew, no admin password. Mirrors
/// GoogleWorkspaceService.installGwsBinary().
enum NodeInstaller {
    static var installRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/node", isDirectory: true)
    }
    static var binDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// Latest LTS version string (e.g. "v22.17.0") from the nodejs.org release
    /// index. Entries are newest-first; `lts` is `false` or the codename string.
    private static func latestLTSVersion() async throws -> String {
        guard let url = URL(string: "https://nodejs.org/dist/index.json") else {
            throw installError("internal error: malformed index URL")
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
            throw installError("release index HTTP \(code)")
        }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw installError("unreadable release index")
        }
        for entry in list {
            if entry["lts"] is String, let version = entry["version"] as? String {
                return version
            }
        }
        throw installError("no LTS release in index")
    }

    private static func installError(_ message: String) -> NSError {
        NSError(domain: "NodeInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Returns nil on success, or a human-readable failure detail. `progress`
    /// receives user-facing status lines (download percentage, install phase).
    static func installNode(progress: (@Sendable (String) -> Void)? = nil) async -> String? {
        // nodejs.org/dist asset names, verified against the published file
        // list: darwin-{arm64,x64} and linux-{arm64,x64}.
        #if os(Linux)
        #if arch(arm64)
        let arch = "linux-arm64"
        #else
        let arch = "linux-x64"
        #endif
        #else
        #if arch(arm64)
        let arch = "darwin-arm64"
        #else
        let arch = "darwin-x64"
        #endif
        #endif
        do {
            progress?("Finding the latest Node.js version…")
            let version = try await latestLTSVersion()
            let file = "node-\(version)-\(arch).tar.gz"
            let base = "https://nodejs.org/dist/\(version)/"
            guard let tarURL = URL(string: base + file),
                  let shaURL = URL(string: base + "SHASUMS256.txt") else {
                return "internal error: malformed download URL"
            }

            let tarData = try await GoogleWorkspaceService.downloadReportingProgress(
                from: tarURL, label: "Downloading Node.js \(version)", progress: progress)
            let (shaData, shaResp) = try await URLSession.shared.data(from: shaURL)
            if let code = (shaResp as? HTTPURLResponse)?.statusCode, code != 200 {
                return "checksum download failed (HTTP \(code))"
            }
            progress?("Installing Node.js…")
            // SHASUMS256.txt format: one "<hex>  <filename>" line per asset.
            guard let shaText = String(data: shaData, encoding: .utf8),
                  let line = shaText.split(separator: "\n").map(String.init)
                      .first(where: { $0.hasSuffix(" \(file)") }),
                  let expected = line.split(separator: " ").first.map(String.init)?.lowercased(),
                  expected.count == 64 else {
                return "checksum for \(file) not found in SHASUMS256.txt"
            }
            let actual = SHA256.hash(data: tarData).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                return "checksum mismatch — download corrupted, retry"
            }

            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory.appendingPathComponent("node-install-\(UUID().uuidString)")
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmpDir) }
            let tarPath = tmpDir.appendingPathComponent(file)
            try tarData.write(to: tarPath)

            let untar = await GoogleWorkspaceService.runProcessAsync(
                executable: "/usr/bin/tar",
                args: ["-xzf", tarPath.path, "-C", tmpDir.path],
                timeoutSeconds: 120
            )
            if let detail = untar.failureDetail {
                return "extraction failed: \(detail)"
            }
            let extractedRoot = tmpDir.appendingPathComponent("node-\(version)-\(arch)", isDirectory: true)
            guard fm.fileExists(atPath: extractedRoot.appendingPathComponent("bin/node").path) else {
                return "archive did not contain bin/node"
            }

            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installRoot.path) {
                try fm.removeItem(at: installRoot)
            }
            try fm.moveItem(at: extractedRoot, to: installRoot)

            #if os(macOS)
            // Belt-and-braces: quarantined unnotarized binaries won't exec.
            _ = await GoogleWorkspaceService.runProcessAsync(
                executable: "/usr/bin/xattr",
                args: ["-dr", "com.apple.quarantine", installRoot.path],
                timeoutSeconds: 60
            )
            #endif

            for tool in ["node", "npm", "npx"] {
                let link = binDir.appendingPathComponent(tool)
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: installRoot.appendingPathComponent("bin/\(tool)"))
            }

            // Smoke tests through the symlinks. npx runs via `#!/usr/bin/env node`,
            // so this also proves ~/.local/bin is on the subprocess PATH.
            let nodeProbe = await GoogleWorkspaceService.runProcessAsync(
                executable: binDir.appendingPathComponent("node").path,
                args: ["--version"], timeoutSeconds: 15
            )
            guard nodeProbe.stdout != nil else {
                return "installed node failed to run: \(nodeProbe.failureDetail ?? "unknown error")"
            }
            let npxProbe = await GoogleWorkspaceService.runProcessAsync(
                executable: binDir.appendingPathComponent("npx").path,
                args: ["--version"], timeoutSeconds: 30
            )
            guard npxProbe.stdout != nil else {
                return "installed npx failed to run: \(npxProbe.failureDetail ?? "unknown error")"
            }
            return nil
        } catch {
            return "install failed: \(error.localizedDescription)"
        }
    }

    /// Absolute path of an installed node binary, or nil. Checks the same
    /// locations the subprocess PATH covers.
    static func detectNode() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(NSHomeDirectory())/.local/bin/node",
            "/usr/bin/node",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

// MARK: - Automatic browser-automation setup

/// Turns on autonomous web browsing without an onboarding step: keeps the
/// `playwright` MCP server registered as the lockfile-managed install
/// (`ManagedPlaywright`), installing Node.js in the background if it is
/// missing or too old. Runs on every daemon start; every half is a no-op when
/// already done. The Playwright browser itself downloads on first use.
///
/// Decision table on the current `mcp.json` entry (`ManagedPlaywright.shape`):
///   absent            fresh install (flag not set): install, then ADD the entry
///                     only once a verified install exists — a fresh install
///                     never runs `@latest`; on failure nothing is written and
///                     the next start retries
///   legacy auto       (`npx @playwright/mcp@latest`): install, then switch
///   managed           verify/reuse (or rebuild), re-point when this build
///                     pins another lockfile
///   edited/user/disabled  left alone, reported by doctor
enum BrowserAutomationBootstrap {
    private static let autoConfiguredKey = "playwright_auto_configured"

    /// "Auto-added once; never re-add after a deliberate removal." Lives in
    /// UserDefaults in production; the selftest substitutes a file.
    struct FlagStore: Sendable {
        var isSet: @Sendable () -> Bool
        var set: @Sendable () -> Void
        var clear: @Sendable () -> Void

        static let userDefaults = FlagStore(
            isSet: { UserDefaults.standard.bool(forKey: autoConfiguredKey) },
            set: { UserDefaults.standard.set(true, forKey: autoConfiguredKey) },
            clear: { UserDefaults.standard.removeObject(forKey: autoConfiguredKey) })

        static func file(_ url: URL) -> FlagStore {
            FlagStore(
                isSet: { FileManager.default.fileExists(atPath: url.path) },
                set: { try? PrivateStorage.writeAtomically(Data("1".utf8), to: url) },
                clear: { try? FileManager.default.removeItem(at: url) })
        }
    }

    struct Dependencies: Sendable {
        var layout = ManagedPlaywright.Layout()
        var manifests: @Sendable () throws -> ManagedPlaywright.Manifests = { try ManagedPlaywright.Manifests.bundled() }
        var flag: FlagStore = .userDefaults
        /// Directory holding a usable node + npm, installing Node if needed;
        /// `(nil, reason)` when none can be had.
        var nodeDirectory: @Sendable () async -> (String?, String?) = { await ensureNodeDirectory() }
        var baseEnvironment: [String: String] = MCPRegistry.baseEnvironment()
        var npmTimeout: TimeInterval = ManagedPlaywright.npmTimeout
        /// Verification handshake bound. Background work with nobody waiting,
        /// so generous: a Raspberry Pi under load takes a while to start
        /// node + playwright-core, and a timeout is treated as "could not
        /// verify now", never as a broken install.
        var handshakeTimeout: TimeInterval = 90
        /// Steady state (the entry already references this build's lockfile
        /// and the tree carries its marker): the verification handshake is
        /// deferred this long so a turn arriving right after a restart gets
        /// the CPU for its own server spawn first — the two would otherwise
        /// start node + playwright-core at the same moment on a small
        /// machine. Nothing is written before or during the wait.
        var steadyStateHandshakeDelay: TimeInterval = 30
        var crashPoint: ManagedPlaywright.CrashPoint? = nil
        /// Restart the registry after a switch (production: yes; the selftest
        /// inspects the file instead).
        var reloadRegistry = true
        var log: @Sendable (String) -> Void = { NSLog("BrowserAutomationBootstrap: %@", $0) }
    }

    enum Outcome: Equatable {
        /// The entry references the verified `playwright-<token>`; `changed`
        /// says whether this run wrote it.
        case configured(token: String, changed: Bool)
        case leftAlone(ManagedPlaywright.EntryShape)
        /// Deliberately removed earlier: nothing to do.
        case notWanted
        case skipped(String)
        case failed(String)
    }

    static func ensureConfigured() async {
        _ = await ensureConfigured(dependencies: Dependencies())
    }

    @discardableResult
    static func ensureConfigured(dependencies deps: Dependencies) async -> Outcome {
        let layout = deps.layout
        func record(_ outcome: String, token: String? = nil, reason: String? = nil) {
            ManagedPlaywright.recordStatus(
                ManagedPlaywright.BootstrapStatus(at: Date(), outcome: outcome, token: token, reason: reason),
                layout: layout)
        }
        let entry = MCPRegistry.loadConfigsFromDisk().first { $0.name == ManagedPlaywright.serverName }

        // The "don't re-add after deliberate removal" flag lives in
        // UserDefaults (~/Library/Preferences), which survives a full wipe of
        // ~/.config/briglia. Distinguish the two cases by the config file itself:
        // a user who removed just the playwright entry leaves mcp.json on
        // disk, while a wiped/fresh machine has no file at all — treat that
        // as a fresh install and bootstrap again. (Observed live: a full
        // uninstall + reinstall came up without the Browse subagent because
        // the stale flag suppressed re-registration.)
        if !FileManager.default.fileExists(atPath: MCPRegistry.configFileURL.path) {
            deps.flag.clear()
        }
        if entry != nil { deps.flag.set() }

        let shape = ManagedPlaywright.shape(of: entry, layout: layout)
        var referencedToken: String? = nil
        switch shape {
        case .absent:
            guard !deps.flag.isSet() else { return .notWanted }
        case .legacyAuto:
            break
        case .managed(let token):
            referencedToken = token
        case .managedEdited, .userAuthored, .disabled:
            record("left-alone", reason: "\(shape)")
            return .leftAlone(shape)
        }

        let manifests: ManagedPlaywright.Manifests
        do {
            manifests = try deps.manifests()
        } catch {
            let reason = "bundled Playwright manifests unavailable: \(error)"
            deps.log(reason)
            record("failed", reason: reason)
            return .failed(reason)
        }
        if case .managed(let token) = shape,
           ManagedPlaywright.Layout.lockfileHash(ofToken: token) == manifests.lockfileHash,
           (try? String(contentsOf: layout.versionDirectory(token: token).appendingPathComponent(ManagedPlaywright.completionMarkerName), encoding: .utf8))?
               .trimmingCharacters(in: .whitespacesAndNewlines) == manifests.lockfileHash,
           deps.steadyStateHandshakeDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(deps.steadyStateHandshakeDelay * 1_000_000_000))
        }
        let (nodeDirectory, nodeReason) = await deps.nodeDirectory()
        guard let nodeDirectory else {
            let reason = "Node.js unavailable: \(nodeReason ?? "unknown")"
            deps.log(reason)
            record("failed", reason: reason)
            return .failed(reason)
        }
        let context = ManagedPlaywright.Context(
            layout: layout, manifests: manifests, nodeDirectory: nodeDirectory,
            environment: ManagedPlaywright.Context.environment(nodeDirectory: nodeDirectory, base: deps.baseEnvironment),
            npmTimeout: deps.npmTimeout, handshakeTimeout: deps.handshakeTimeout,
            crashPoint: deps.crashPoint, referencedToken: referencedToken, log: deps.log)
        let (installed, installLock) = await ManagedPlaywright.ensureInstalled(context: context)
        defer { installLock?.release() }
        switch installed {
        case .skipped(let reason):
            deps.log("skipped: \(reason)")
            record("skipped", reason: reason)
            return .skipped(reason)
        case .failed(let reason):
            deps.log("install failed: \(reason)")
            record("failed", reason: reason)
            return .failed(reason)
        case .ready(let token, let reused, let quarantineAfterSwitch):
            // Still under the installation lock (returned held): the switch
            // takes the configuration lock inside it, and so does the
            // post-switch quarantine — installation → configuration, always.
            let update = await MCPRegistry.shared.updateManagedPlaywrightEntry(
                token: token, layout: layout, addIfAbsent: shape == .absent,
                crashAfterWrite: deps.crashPoint == .afterConfigWrite)
            // A referenced tree that failed verification is quarantined only
            // now that the configuration no longer points at it — re-checked
            // under the configuration lock, so an edit that pointed back at
            // it meanwhile keeps it.
            func quarantineOldIfSafe() {
                guard let old = quarantineAfterSwitch, old != token else { return }
                switch ManagedPlaywright.quarantineIfUnreferenced(token: old, layout: layout) {
                case .quarantined: deps.log("quarantined playwright-\(old) (failed verification; no longer referenced)")
                case .referenced: deps.log("playwright-\(old) is referenced again — left in place")
                case .failed(let failure): deps.log("could not quarantine playwright-\(old): \(failure)")
                }
            }
            switch update {
            case .switched(let from):
                deps.flag.set()
                deps.log("playwright entry now references playwright-\(token) (was \(from); install \(reused ? "reused" : "fresh"))")
                quarantineOldIfSafe()
                record("ready", token: token)
                if deps.reloadRegistry {
                    await MCPRegistry.shared.reloadFromDisk()
                    await MCPAgentRouting.refreshFromRegistry()
                }
                return .configured(token: token, changed: true)
            case .alreadyCurrent:
                quarantineOldIfSafe()
                record("ready", token: token)
                // The entry already named this token but the directory was
                // (re)built this start: a registry that bootstrapped the
                // server as failed meanwhile must see the repaired install.
                if !reused && deps.reloadRegistry {
                    await MCPRegistry.shared.reloadFromDisk()
                    await MCPAgentRouting.refreshFromRegistry()
                }
                return .configured(token: token, changed: !reused)
            case .leftAlone(let current):
                record("left-alone", token: token, reason: "\(current)")
                return .leftAlone(current)
            case .absent:
                return .notWanted
            case .failed(let reason):
                deps.log("switch failed: \(reason)")
                record("failed", token: token, reason: reason)
                return .failed(reason)
            }
        }
    }

    /// A usable Node (≥ 20, npm beside it), installing the LTS into
    /// ~/.local/node when none is found — quietly, as before; the next start
    /// retries after a failure.
    static func ensureNodeDirectory() async -> (String?, String?) {
        let first = ManagedPlaywright.resolveNodeDirectory()
        if let dir = first.directory { return (dir, nil) }
        if let failure = await NodeInstaller.installNode() {
            return (nil, "\(first.reason ?? "node not found"); background Node.js install failed: \(failure)")
        }
        let second = ManagedPlaywright.resolveNodeDirectory(
            preferred: NodeInstaller.binDir.appendingPathComponent("node").path)
        return (second.directory, second.reason)
    }
}
