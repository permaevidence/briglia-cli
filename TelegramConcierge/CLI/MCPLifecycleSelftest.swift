import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden battery for the child-process lifecycle across restart/exit:
///
///   §1 `LeftoverChildSweep` — zombies reaped, live leftover trees (a
///      `__setsid-exec` shim with its server in a private session, a
///      SIGTERM-ignoring child) ended and collected, a clean process left
///      alone.
///   §2 the real pre-exec shutdown (`TerminalSession.shutdownChildProcesses`)
///      against real `MCPClient`-spawned servers: the tracked shim is gone
///      AND reaped, the server in its private session is gone, including a
///      server that ignores SIGTERM; the registry publishes nothing after.
///
/// Negative controls (each must FAIL): `--skip-startup-sweep` skips the
/// sweep in §1, `--skip-mcp-shutdown` runs §2 with the pre-v0.2.21
/// shutdown body (no MCP teardown). `--exec-into-chat` is the driver for the
/// smoke test's wiring check: it plants leftovers, prints their pids, and
/// `execv`s into `briglia chat` the way `/restart` does, so the real
/// startup path has to clean them.
///
/// Spawns only under an isolated XDG root; the real config is never touched.
struct MCPLifecycleSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__mcp-lifecycle-selftest",
        abstract: "Internal: verify MCP servers die with the process (restart, exit) and leftovers are swept.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: "Negative control: do not run the startup sweep in §1 (must fail).")
    var skipStartupSweep = false

    @Flag(name: .long, help: "Negative control: run §2 with the old shutdown body, no MCP teardown (must fail).")
    var skipMcpShutdown = false

    @Flag(name: .long, help: "Driver: plant leftovers, print their pids, execv into `briglia chat`.")
    var execIntoChat = false

    func run() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("briglia-mcp-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("XDG_CONFIG_HOME", tempRoot.path, 1)
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path + "/", 1)

        if execIntoChat {
            try execIntoChatDriver()
        }
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        guard let selfPath = BashTools.selfExecutablePath else {
            print("✖ cannot resolve own executable path"); throw ExitCode(1)
        }

        // MARK: 1. Startup sweep

        print("— §1 LeftoverChildSweep")
        // 1a. a clean table: nothing of ours → empty report, no log line
        var logged: [String] = []
        let empty = LeftoverChildSweep.run(graceNanos: 100_000_000) { logged.append($0) }
        check("1.1 nothing to sweep → empty report", empty.isEmpty, "\(empty)")
        check("1.2 nothing to sweep → no log line", logged.isEmpty, "\(logged)")

        // 1b. plant: one zombie, one shim+server tree in a private session,
        //     one SIGTERM-ignoring child.
        let zombie = try Self.rawSpawn(["/bin/sh", "-c", ":"], newGroup: false)
        let shim = try Self.rawSpawn([selfPath, "__setsid-exec", "--", "/bin/sleep", "300"], newGroup: true)
        let stubborn = try Self.rawSpawn(["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 300"], newGroup: false)
        usleep(400_000)
        let server = Self.waitForChild(of: shim, seconds: 3)
        check("1.3 planted shim took the posix_spawn fallback (server is the shim's child)", server != nil,
              "shim=\(shim) table=\(Self.describeTree(shim))")
        check("1.4 planted server sits in its own session/group", server.map { getpgid($0) == $0 } ?? false)
        check("1.5 planted zombie is a zombie", Self.isZombie(zombie), "pid \(zombie)")

        logged = []
        if skipStartupSweep {
            print("· negative control: startup sweep skipped")
        } else {
            let report = LeftoverChildSweep.run(graceNanos: 1_000_000_000) { logged.append($0) }
            check("1.6 report: 1 zombie reaped", report.reaped == 1, "\(report)")
            check("1.7 report: 2 live children ended", report.terminated == 2, "\(report)")
            check("1.8 report: the SIGTERM-ignoring child needed SIGKILL, the shim did not", report.killed == 1, "\(report)")
            check("1.9 report: nothing left uncollected", report.unreaped.isEmpty, "\(report)")
            check("1.10 one startup log line", logged.count == 1 && logged[0].hasPrefix("startup: "), "\(logged)")
        }
        check("1.11 zombie collected (waitpid → ECHILD)", Self.reapedByUs(zombie), "pid \(zombie)")
        check("1.12 shim gone and collected", Self.reapedByUs(shim) && !Self.exists(shim), "pid \(shim) \(Self.describeTree(shim))")
        check("1.13 server in the private session gone", server.map { !Self.waitGone($0, seconds: 3) } ?? false,
              "pid \(server.map(String.init) ?? "?")")
        check("1.14 SIGTERM-ignoring child gone and collected", Self.reapedByUs(stubborn) && !Self.exists(stubborn), "pid \(stubborn)")
        // Whatever the verdict, leave nothing behind.
        for pid in [zombie, shim, stubborn] + (server.map { [$0] } ?? []) {
            _ = Darwin.kill(pid, SIGKILL); var st: Int32 = 0; _ = waitpid(pid, &st, WNOHANG)
        }

        // MARK: 2. Pre-exec shutdown reaches MCP servers

        print("— §2 shutdownChildProcesses vs live MCP servers")
        let fm = FileManager.default
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/bin/python3"]
            .first { fm.isExecutableFile(atPath: $0) } ?? "python3"
        let script = tempRoot.appendingPathComponent("fake_mcp.py")
        try Self.fakeServerSource.write(to: script, atomically: true, encoding: .utf8)
        let servers: [String: Any] = [
            "plain": ["command": python, "args": [script.path, "plain"]],
            "stubborn": ["command": python, "args": [script.path, "stubborn", "ignore-term"]],
        ]
        try fm.createDirectory(at: StoragePaths.configRoot, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.prettyPrinted])
            .write(to: StoragePaths.configRoot.appendingPathComponent("mcp.json"))

        let registry = MCPRegistry.shared
        await registry.reloadFromDisk()
        let status = await registry.status()
        let connected = Set(status.filter { $0.connected && !$0.failed }.map(\.name))
        check("2.1 both fake servers connected", connected == ["plain", "stubborn"],
              "connected=\(connected.sorted()) failures=\(status.filter { $0.failed }.map { "\($0.name): \($0.reason ?? "?")" })")
        let shims = await registry.spawnedProcessIdentifiers()
        check("2.2 both servers have a tracked child", shims.count == 2, "\(shims)")
        var serverPids: [String: Int32] = [:]
        for (name, pid) in shims {
            if let child = Self.waitForChild(of: pid, seconds: 3) { serverPids[name] = child }
        }
        check("2.3 each tracked child is a shim with the server in a private session (production topology)",
              serverPids.count == 2 && serverPids.values.allSatisfy { getpgid($0) == $0 },
              "shims=\(shims) servers=\(serverPids)")

        if skipMcpShutdown {
            print("· negative control: old shutdown body (no MCP teardown)")
            await MainActor.run { TerminalSession.shutdownChildProcesses(includeMCP: false) }
        } else {
            let t0 = Date()
            await MainActor.run { TerminalSession.shutdownChildProcesses() }
            let took = Date().timeIntervalSince(t0)
            check("2.4 shutdown returned within the budget", took < TerminalSession.childShutdownBudgetSeconds, "\(took) s")
        }
        for (name, pid) in shims.sorted(by: { $0.key < $1.key }) {
            check("2.5 \(name): tracked shim gone", !Self.waitGone(pid, seconds: 3), "pid \(pid) \(Self.describeTree(pid))")
            check("2.6 \(name): tracked shim collected (no zombie under us)", !Self.isZombie(pid), "pid \(pid)")
        }
        for (name, pid) in serverPids.sorted(by: { $0.key < $1.key }) {
            check("2.7 \(name): server in its private session gone", !Self.waitGone(pid, seconds: 3), "pid \(pid)")
        }
        // (not status(): that re-bootstraps on demand, which would spawn a new pair)
        let after = await registry.spawnedProcessIdentifiers()
        check("2.8 registry tracks nothing after shutdown", after.isEmpty, "\(after)")
        let stragglers = (LeftoverChildSweep.snapshot() ?? []).filter { $0.ppid == getpid() }
        check("2.9 no child of this process left (live or zombie)", stragglers.isEmpty,
              "\(stragglers.map { "\($0.pid)\($0.zombie ? "Z" : "")" })")
        // Negative-control hygiene: end what the old body left.
        if skipMcpShutdown { await registry.shutdownAll() }
        let stragglersAfterCleanup = (LeftoverChildSweep.snapshot() ?? []).filter { $0.ppid == getpid() && !$0.zombie }
        for pid in stragglersAfterCleanup.map(\.pid) { _ = Darwin.kill(pid, SIGKILL) }

        print("\nMCP lifecycle selftest: \(failures == 0 ? "PASS" : "\(failures) FAILED")")
        if failures > 0 { throw ExitCode(1) }
    }

    // MARK: - exec driver

    /// Plant a zombie and a shim+server tree, print their pids, then replace
    /// this process with `briglia chat` (isolated roots, no config: it runs
    /// the startup sweep and then stops at "not configured"). The smoke test
    /// asserts the sweep line and that the pids are gone.
    private func execIntoChatDriver() throws -> Never {
        guard let selfPath = BashTools.selfExecutablePath else { throw ExitCode(1) }
        let zombie = try Self.rawSpawn(["/bin/sh", "-c", ":"], newGroup: false)
        let shim = try Self.rawSpawn([selfPath, "__setsid-exec", "--", "/bin/sleep", "300"], newGroup: true)
        usleep(400_000)
        let server = Self.waitForChild(of: shim, seconds: 3) ?? -1
        print("LEFTOVER zombie=\(zombie) shim=\(shim) server=\(server)")
        fflush(stdout)
        let chatArgs: [String] = [selfPath, "chat"]
        var argv: [UnsafeMutablePointer<CChar>?] = chatArgs.map { strdup($0) }
        argv.append(nil)
        execv(selfPath, argv)
        perror("execv")
        throw ExitCode(1)
    }

    // MARK: - Helpers

    /// Raw posix_spawn — no Foundation `Process`, so nothing in this image
    /// reaps the child: exactly the state a previous exec image leaves.
    /// `newGroup` makes the child a process-group leader, which is what
    /// Foundation does to the `__setsid-exec` shim and what forces its
    /// two-process fallback.
    private static func rawSpawn(_ argv: [String], newGroup: Bool) throws -> Int32 {
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        defer { for p in cargs { free(p) } }
        #if os(Linux)
        var attr = posix_spawnattr_t()
        #else
        var attr: posix_spawnattr_t? = nil
        #endif
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if newGroup {
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attr, 0)
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], nil, &attr, cargs, environ)
        guard rc == 0 else { throw ExitCode(1) }
        return pid
    }

    private static func children(of parent: Int32) -> [Int32] {
        (LeftoverChildSweep.snapshot() ?? []).filter { $0.ppid == parent && !$0.zombie }.map(\.pid)
    }

    private static func waitForChild(of parent: Int32, seconds: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let c = children(of: parent).first { return c }
            usleep(50_000)
        }
        return nil
    }

    private static func exists(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno != ESRCH
    }

    /// True while the pid exists (a zombie still "exists" for kill(2)); polls
    /// until gone or the deadline. Returns whether it is STILL there.
    private static func waitGone(_ pid: Int32, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !exists(pid) { return false }
            usleep(50_000)
        }
        return exists(pid)
    }

    private static func isZombie(_ pid: Int32) -> Bool {
        (LeftoverChildSweep.snapshot() ?? []).contains { $0.pid == pid && $0.zombie }
    }

    /// True when the pid is no longer collectable by us: either it was never
    /// ours or it was already reaped.
    private static func reapedByUs(_ pid: Int32) -> Bool {
        var st: Int32 = 0
        let r = waitpid(pid, &st, WNOHANG)
        return r == -1 && errno == ECHILD
    }

    private static func describeTree(_ root: Int32) -> String {
        let table = LeftoverChildSweep.snapshot() ?? []
        let me = table.first { $0.pid == root }
        let kids = table.filter { $0.ppid == root }
        return "root=\(me.map { "\($0.pid)/pg\($0.pgid)\($0.zombie ? "Z" : "")" } ?? "gone") kids=\(kids.map { "\($0.pid)/pg\($0.pgid)\($0.zombie ? "Z" : "")" })"
    }

    /// Minimal stdio MCP server: answers initialize and tools/list, then
    /// keeps reading. With `ignore-term` it ignores SIGTERM AND keeps
    /// running on stdin EOF, like a wedged real server would.
    private static var fakeServerSource: String {
        """
        import sys, json, signal, time
        label = sys.argv[1]
        stubborn = len(sys.argv) > 2 and sys.argv[2] == "ignore-term"
        if stubborn:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            if "id" not in msg:
                continue
            method = msg.get("method")
            if method == "initialize":
                res = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": label, "version": "0"}}
            elif method == "tools/list":
                res = {"tools": [{"name": "ping", "description": "ping", "inputSchema": {"type": "object", "properties": {}}}]}
            else:
                res = {}
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": res}) + "\\n")
            sys.stdout.flush()
        if stubborn:
            while True:
                time.sleep(3600)
        """
    }
}
