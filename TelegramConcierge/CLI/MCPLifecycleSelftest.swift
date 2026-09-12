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
///   §3 the same shutdown while a bootstrap is blocked in initialize, on the
///      pre-exec, forced-exit and a tight budget: every owned server gone
///      and collected at return, within the budget (Codex R3, round 2 R-C).
///   §4 overlapping shutdown callers: a second caller — at the client and at
///      the registry layer — returns only when the cleanup the FIRST caller
///      started is complete; a late `start()` is refused (round 2 R-A).
///   §5 a reload that began before the exit shutdown and resumes after it
///      spawns nothing; a reload after the exit shutdown spawns nothing
///      (round 2 R-B).
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
        let fm = FileManager.default
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/bin/python3"]
            .first { fm.isExecutableFile(atPath: $0) } ?? "python3"

        // MARK: 1. Startup sweep

        print("— §1 LeftoverChildSweep")
        // 1a. a clean table: nothing of ours → empty report, no log line
        var logged: [String] = []
        let empty = LeftoverChildSweep.run(graceNanos: 100_000_000) { logged.append($0) }
        check("1.1 nothing to sweep → empty report", empty.isEmpty, "\(empty)")
        check("1.2 nothing to sweep → no log line", logged.isEmpty, "\(logged)")

        // 1b. plant, sweep A — every DIRECT child obeys SIGTERM: one zombie,
        //     one shim+server tree in a private session, and (Codex R2) an
        //     obedient parent whose descendant sits in its own session and
        //     ignores SIGTERM. No SIGTERM-resistant direct child here, so the
        //     escalation can only be triggered by the descendant tracking.
        let zombie = try Self.rawSpawn(["/bin/sh", "-c", ":"], newGroup: false)
        let shim = try Self.rawSpawn([selfPath, "__setsid-exec", "--", "/bin/sleep", "300"], newGroup: true)
        let detachedIgnoringTerm = "import os,signal,time; os.setsid(); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"
        let obedient = try Self.rawSpawn(["/bin/sh", "-c", "\(python) -c '\(detachedIgnoringTerm)' & exec /bin/sleep 300"], newGroup: false)
        usleep(400_000)
        let server = Self.waitForChild(of: shim, seconds: 3)
        let detached = Self.waitForChild(of: obedient, seconds: 3)
        check("1.3 planted shim took the posix_spawn fallback (server is the shim's child)", server != nil,
              "shim=\(shim) table=\(Self.describeTree(shim))")
        check("1.4 planted server sits in its own session/group", server.map { getpgid($0) == $0 } ?? false)
        check("1.5 planted zombie is a zombie", Self.isZombie(zombie), "pid \(zombie)")
        check("1.5b planted obedient parent has its detached descendant (own session, ignores SIGTERM)",
              detached.map { getpgid($0) == $0 } ?? false, "parent=\(obedient) \(Self.describeTree(obedient))")

        logged = []
        if skipStartupSweep {
            print("· negative control: startup sweep skipped")
        } else {
            let report = LeftoverChildSweep.run(graceNanos: 1_000_000_000) { logged.append($0) }
            check("1.6 sweep A report: 1 zombie reaped", report.reaped == 1, "\(report)")
            check("1.7 sweep A report: 2 live children ended, none needed SIGKILL", report.terminated == 2 && report.killed == 0, "\(report)")
            check("1.8 sweep A report: the detached descendant of the obedient parent needed SIGKILL", report.descendantsKilled == 1, "\(report)")
            check("1.9 sweep A report: nothing left uncollected, no descendant surviving",
                  report.unreaped.isEmpty && report.survivingDescendants.isEmpty, "\(report)")
            check("1.10 one startup log line", logged.count == 1 && logged[0].hasPrefix("startup: "), "\(logged)")
        }
        check("1.11 zombie collected (waitpid → ECHILD)", Self.reapedByUs(zombie), "pid \(zombie)")
        check("1.12 shim gone and collected", Self.reapedByUs(shim) && !Self.exists(shim), "pid \(shim) \(Self.describeTree(shim))")
        check("1.13 server in the private session gone", server.map { !Self.waitGone($0, seconds: 3) } ?? false,
              "pid \(server.map(String.init) ?? "?")")
        check("1.14 obedient parent gone and collected", Self.reapedByUs(obedient) && !Self.exists(obedient), "pid \(obedient)")
        check("1.15 its detached SIGTERM-ignoring descendant gone (escalated although its parent was collected)",
              detached.map { !Self.waitGone($0, seconds: 3) } ?? false, "pid \(detached.map(String.init) ?? "?")")
        for pid in [zombie, shim, obedient] + (server.map { [$0] } ?? []) + (detached.map { [$0] } ?? []) {
            _ = Darwin.kill(pid, SIGKILL); var st: Int32 = 0; _ = waitpid(pid, &st, WNOHANG)
        }

        // 1c. sweep B — a SIGTERM-ignoring DIRECT child alone.
        let stubborn = try Self.rawSpawn(["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 300"], newGroup: false)
        usleep(200_000)
        logged = []
        if !skipStartupSweep {
            let report = LeftoverChildSweep.run(graceNanos: 1_000_000_000) { logged.append($0) }
            check("1.16 sweep B report: 1 child ended, it needed SIGKILL, nothing else", report.terminated == 1 && report.killed == 1
                  && report.reaped == 0 && report.descendantsKilled == 0 && report.unreaped.isEmpty && report.survivingDescendants.isEmpty, "\(report)")
        }
        check("1.17 SIGTERM-ignoring child gone and collected", Self.reapedByUs(stubborn) && !Self.exists(stubborn), "pid \(stubborn)")
        _ = Darwin.kill(stubborn, SIGKILL); do { var st: Int32 = 0; _ = waitpid(stubborn, &st, WNOHANG) }

        // MARK: 2. Pre-exec shutdown reaches MCP servers

        print("— §2 shutdownChildProcesses vs live MCP servers")
        let script = tempRoot.appendingPathComponent("fake_mcp.py")
        try Self.fakeServerSource.write(to: script, atomically: true, encoding: .utf8)
        let forkedPidFile = tempRoot.appendingPathComponent("forked.pid")
        let servers: [String: Any] = [
            "plain": ["command": python, "args": [script.path, "plain"]],
            "stubborn": ["command": python, "args": [script.path, "stubborn", "ignore-term"]],
            // Codex R1: forks a detached SIGTERM-ignoring child at start, then
            // exits the instant stdin closes — the tree must be captured
            // before EOF or the child is orphaned under pid 1 unseen.
            "forker": ["command": python, "args": [script.path, "forker", "fork-detached", forkedPidFile.path]],
        ]
        try fm.createDirectory(at: StoragePaths.configRoot, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.prettyPrinted])
            .write(to: StoragePaths.configRoot.appendingPathComponent("mcp.json"))

        let registry = MCPRegistry.shared
        await registry.reloadFromDisk()
        let status = await registry.status()
        let connected = Set(status.filter { $0.connected && !$0.failed }.map(\.name))
        check("2.1 all three fake servers connected", connected == ["plain", "stubborn", "forker"],
              "connected=\(connected.sorted()) failures=\(status.filter { $0.failed }.map { "\($0.name): \($0.reason ?? "?")" })")
        let shims = await registry.spawnedProcessIdentifiers()
        check("2.2 every server has a tracked child", shims.count == 3, "\(shims)")
        let forkedPid = Self.waitForPidFile(forkedPidFile, seconds: 3)
        check("2.2b the forker's detached descendant is alive in its own session",
              forkedPid.map { Self.exists($0) && getpgid($0) == $0 } ?? false, "pid \(forkedPid.map(String.init) ?? "?")")
        var serverPids: [String: Int32] = [:]
        for (name, pid) in shims {
            if let child = Self.waitForChild(of: pid, seconds: 3) { serverPids[name] = child }
        }
        check("2.3 each tracked child is a shim with the server in a private session (production topology)",
              serverPids.count == 3 && serverPids.values.allSatisfy { getpgid($0) == $0 },
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
        // Collection is asserted AT RETURN (a snapshot taken now), not after
        // a polling grace: "exited" is not "reaped" (Codex R5).
        let atReturn = LeftoverChildSweep.snapshot() ?? []
        for (name, pid) in shims.sorted(by: { $0.key < $1.key }) {
            check("2.5 \(name): tracked shim gone at shutdown return", !atReturn.contains { $0.pid == pid && !$0.zombie },
                  "pid \(pid) \(Self.describeTree(pid))")
            check("2.6 \(name): tracked shim collected at shutdown return (no zombie under us)",
                  !atReturn.contains { $0.pid == pid && $0.zombie }, "pid \(pid)")
        }
        check("2.7b forker's detached descendant gone (tree captured before EOF)",
              forkedPid.map { !Self.waitGone($0, seconds: 3) } ?? false, "pid \(forkedPid.map(String.init) ?? "?")")
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

        // MARK: 3. Terminal shutdown while a bootstrap is in flight (Codex R3)

        print("— §3 shutdownChildProcesses vs a bootstrap blocked in initialize")
        let blockedServers: [String: Any] = [
            "plain": ["command": python, "args": [script.path, "plain"]],
            "stubborn": ["command": python, "args": [script.path, "stubborn", "ignore-term"]],
            // never answers initialize: bootstrap stays in flight up to the
            // 30 s initialize timeout, its clients unpublished.
            "blocked": ["command": python, "args": [script.path, "blocked", "blocked"]],
        ]
        try JSONSerialization.data(withJSONObject: ["mcpServers": blockedServers], options: [.prettyPrinted])
            .write(to: StoragePaths.configRoot.appendingPathComponent("mcp.json"))
        // The tight budget is below the SIGTERM grace: the plan must SIGKILL
        // at once (`deadline − collectionReserve` is already now) and still
        // return with everything collected. The pre-round-2 code, which
        // waited out its nominal grace before escalating, cannot pass it.
        for (variant, budget) in [("pre-exec budget", TerminalSession.childShutdownBudgetSeconds), ("forced-exit budget", 3.0), ("tight budget", 1.0)] {
            // The exit shutdown of the previous section/variant closed the
            // registry for good (round 2 R-B); a selftest is the one place
            // that re-arms it.
            await registry.reopenAfterExitShutdownForSelftest()
            // Kick a reload WITHOUT awaiting it: it re-arms the registry and
            // starts a bootstrap that the blocked server keeps in flight.
            let reload = Task { await registry.reloadFromDisk() }
            var owned: [Int32] = []
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                owned = await registry.ownedProcessIdentifiers()
                if owned.count == 3 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            check("3.1 [\(variant)] three servers spawned and owned while bootstrap is in flight", owned.count == 3, "\(owned)")
            let published = await registry.spawnedProcessIdentifiers()
            check("3.2 [\(variant)] nothing published yet (bootstrap blocked)", published.isEmpty, "\(published)")
            var blockedServerPids: [Int32] = []
            for pid in owned { if let c = Self.waitForChild(of: pid, seconds: 3) { blockedServerPids.append(c) } }
            check("3.2b [\(variant)] every owned shim has its server in a private session", blockedServerPids.count == 3, "\(blockedServerPids)")
            let t0 = Date()
            if skipMcpShutdown {
                await MainActor.run { TerminalSession.shutdownChildProcesses(includeMCP: false, budgetSeconds: budget) }
            } else {
                await MainActor.run { TerminalSession.shutdownChildProcesses(budgetSeconds: budget) }
            }
            let took = Date().timeIntervalSince(t0)
            check("3.3 [\(variant)] returned within the budget (\(Int(budget)) s)", took < budget, "\(took) s")
            let table = LeftoverChildSweep.snapshot() ?? []
            for pid in owned {
                check("3.4 [\(variant)] owned shim \(pid) gone and collected at return",
                      !table.contains { $0.pid == pid }, Self.describeTree(pid))
            }
            for pid in blockedServerPids {
                check("3.5 [\(variant)] server \(pid) in its private session gone", !Self.waitGone(pid, seconds: 3))
            }
            _ = await reload.value
            let stillOwned = await registry.ownedProcessIdentifiers()
            check("3.6 [\(variant)] registry owns nothing after the in-flight bootstrap settles", stillOwned.isEmpty, "\(stillOwned)")
            let defsAfter = await registry.allToolDefinitions()
            let ownedAfter = await registry.ownedProcessIdentifiers()
            let kidsAfter = (LeftoverChildSweep.snapshot() ?? []).filter { $0.ppid == getpid() }
            check("3.7 [\(variant)] a tool-list request after the terminal shutdown spawns nothing",
                  defsAfter.isEmpty && ownedAfter.isEmpty && kidsAfter.isEmpty,
                  "defs=\(defsAfter.count) owned=\(ownedAfter) kids=\(kidsAfter.map { "\($0.pid)\($0.zombie ? "Z" : "")" })")
            if skipMcpShutdown { await registry.shutdownAll() }
            for pid in kidsAfter.map(\.pid) + blockedServerPids { _ = Darwin.kill(pid, SIGKILL) }
        }
        // MARK: 4. Overlapping shutdown callers (Codex round 2 R-A)

        print("— §4 overlapping shutdown callers")
        func liveChildren() -> [Int32] {
            (LeftoverChildSweep.snapshot() ?? []).filter { $0.ppid == getpid() && !$0.zombie }.map(\.pid).sorted()
        }
        // 4a — client layer. A shutdown is already running (a bootstrap-failure
        // cleanup, a registry reset); the terminal caller arrives while it is
        // still waiting on the EOF-forker's detached descendant. Its return
        // must mean the shim is collected and the descendant is gone.
        do {
            let forked4 = tempRoot.appendingPathComponent("forked4.pid")
            let client = MCPClient(
                config: MCPServerConfig(name: "forker4", command: python,
                                        arguments: [script.path, "forker", "fork-detached", forked4.path]),
                resolvedEnvironment: ProcessInfo.processInfo.environment)
            try await client.start()
            try await client.initialize()
            let shim4 = await client.processIdentifier ?? -1
            let forked4Pid = Self.waitForPidFile(forked4, seconds: 3) ?? -1
            check("4.1 direct client up: shim alive, detached descendant alive",
                  shim4 > 0 && Self.exists(shim4) && forked4Pid > 0 && Self.exists(forked4Pid), "shim \(shim4) forked \(forked4Pid)")
            let first = Task { await client.shutdown() }
            let begunBy = Date().addingTimeInterval(2)
            var begun = false
            while Date() < begunBy {
                if await client.shutdownBegun { begun = true; break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            check("4.2 first caller's cleanup has begun", begun)
            let t0 = Date()
            await client.shutdown(deadline: .after(seconds: 3))
            let took = Date().timeIntervalSince(t0)
            let atReturn = LeftoverChildSweep.snapshot() ?? []
            check("4.3 second caller returned within its 3 s deadline", took < 3, "\(took) s")
            check("4.4 shim gone and collected at the second caller's return", !atReturn.contains { $0.pid == shim4 },
                  Self.describeTree(shim4))
            check("4.5 detached descendant gone at the second caller's return",
                  LeftoverChildSweep.isGone(forked4Pid, table: atReturn), "pid \(forked4Pid)")
            await first.value
            var refused = false
            do { try await client.start() } catch { refused = true }
            let kids = liveChildren()
            check("4.6 a late start() on a client whose cleanup began is refused", refused)
            check("4.7 …and spawned nothing", kids.isEmpty, "\(kids)")
            _ = Darwin.kill(forked4Pid, SIGKILL)
        }
        // 4b — registry layer. An ordinary reset (`shutdownAll`) has already
        // cleared the ownership maps and is ending its servers; the exit
        // shutdown then finds nothing to own. Its return must still cover
        // the reset's servers (the registry joins its in-flight shutdown).
        do {
            let forked4b = tempRoot.appendingPathComponent("forked4b.pid")
            let overlapServers: [String: Any] = [
                "forker": ["command": python, "args": [script.path, "forker", "fork-detached", forked4b.path]],
                "stubborn": ["command": python, "args": [script.path, "stubborn", "ignore-term"]],
            ]
            try JSONSerialization.data(withJSONObject: ["mcpServers": overlapServers], options: [.prettyPrinted])
                .write(to: StoragePaths.configRoot.appendingPathComponent("mcp.json"))
            await registry.reopenAfterExitShutdownForSelftest()
            await registry.reloadFromDisk()
            let shims4b = await registry.spawnedProcessIdentifiers()
            var servers4b: [Int32] = []
            for pid in shims4b.values { if let c = Self.waitForChild(of: pid, seconds: 3) { servers4b.append(c) } }
            let forked4bPid = Self.waitForPidFile(forked4b, seconds: 3) ?? -1
            check("4.8 two servers published, detached descendant alive",
                  shims4b.count == 2 && servers4b.count == 2 && forked4bPid > 0 && Self.exists(forked4bPid),
                  "shims \(shims4b) servers \(servers4b) forked \(forked4bPid)")
            let reset = Task { await registry.shutdownAll() }
            let clearedBy = Date().addingTimeInterval(2)
            var cleared = false
            while Date() < clearedBy {
                if await registry.ownedProcessIdentifiers().isEmpty { cleared = true; break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            check("4.9 the reset has taken the servers out of the ownership maps", cleared)
            let t0 = Date()
            await MainActor.run { TerminalSession.shutdownChildProcesses(budgetSeconds: 3) }
            let took = Date().timeIntervalSince(t0)
            let atReturn = LeftoverChildSweep.snapshot() ?? []
            check("4.10 exit shutdown returned within its 3 s budget", took < 3, "\(took) s")
            for (name, pid) in shims4b.sorted(by: { $0.key < $1.key }) {
                check("4.11 \(name): shim of the reset's server gone and collected at the exit shutdown's return",
                      !atReturn.contains { $0.pid == pid }, Self.describeTree(pid))
            }
            for pid in servers4b {
                check("4.12 server \(pid) of the reset gone at the exit shutdown's return",
                      LeftoverChildSweep.isGone(pid, table: atReturn))
            }
            check("4.13 the reset's detached descendant gone at the exit shutdown's return",
                  LeftoverChildSweep.isGone(forked4bPid, table: atReturn), "pid \(forked4bPid)")
            await reset.value
            _ = Darwin.kill(forked4bPid, SIGKILL)
        }
        // 4c — registry layer, SHORT remaining budget (Codex round 3). The
        // reset is draining its servers on their own 1 s grace; the exit
        // arrives with 0.5 s left. Joining the reset's task is not enough:
        // the reset's clients must be addressed again with the exit's
        // deadline so their plans tighten (kill instant = now) and everything
        // is collected before the semaphore expires.
        do {
            let forked4c = tempRoot.appendingPathComponent("forked4c.pid")
            let shortServers: [String: Any] = [
                "forker": ["command": python, "args": [script.path, "forker", "fork-detached", forked4c.path]],
                "stubborn": ["command": python, "args": [script.path, "stubborn", "ignore-term"]],
            ]
            try JSONSerialization.data(withJSONObject: ["mcpServers": shortServers], options: [.prettyPrinted])
                .write(to: StoragePaths.configRoot.appendingPathComponent("mcp.json"))
            await registry.reopenAfterExitShutdownForSelftest()
            await registry.reloadFromDisk()
            let shims4c = await registry.spawnedProcessIdentifiers()
            var servers4c: [Int32] = []
            for pid in shims4c.values { if let c = Self.waitForChild(of: pid, seconds: 3) { servers4c.append(c) } }
            let forked4cPid = Self.waitForPidFile(forked4c, seconds: 3) ?? -1
            check("4.14 two servers published, detached descendant alive",
                  shims4c.count == 2 && servers4c.count == 2 && forked4cPid > 0 && Self.exists(forked4cPid),
                  "shims \(shims4c) servers \(servers4c) forked \(forked4cPid)")
            let reset = Task { await registry.shutdownAll() }
            let clearedBy = Date().addingTimeInterval(2)
            var cleared = false
            while Date() < clearedBy {
                if await registry.ownedProcessIdentifiers().isEmpty { cleared = true; break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            let drainingCount = await registry.drainingCount()
            check("4.15 the reset is draining both servers, maps empty", cleared && drainingCount == 2, "draining \(drainingCount)")
            let t0 = Date()
            await MainActor.run { TerminalSession.shutdownChildProcesses(budgetSeconds: 0.5) }
            let took = Date().timeIntervalSince(t0)
            let atReturn = LeftoverChildSweep.snapshot() ?? []
            check("4.16 exit shutdown with 0.5 s left returned within that budget", took < 0.5, "\(took) s")
            for (name, pid) in shims4c.sorted(by: { $0.key < $1.key }) {
                check("4.17 \(name): shim of the draining server gone and collected at the exit shutdown's return",
                      !atReturn.contains { $0.pid == pid }, Self.describeTree(pid))
            }
            for pid in servers4c {
                check("4.18 server \(pid) of the reset gone at the exit shutdown's return",
                      LeftoverChildSweep.isGone(pid, table: atReturn))
            }
            check("4.19 the reset's detached descendant gone at the exit shutdown's return",
                  LeftoverChildSweep.isGone(forked4cPid, table: atReturn), "pid \(forked4cPid)")
            await reset.value
            let drainingAfter = await registry.drainingCount()
            check("4.20 nothing left draining once the reset settles", drainingAfter == 0, "draining \(drainingAfter)")
            _ = Darwin.kill(forked4cPid, SIGKILL)
        }

        // MARK: 5. A reload in flight across the exit shutdown (Codex round 2 R-B)

        print("— §5 reload across the exit shutdown")
        do {
            let reloadServers: [String: Any] = [
                "plain": ["command": python, "args": [script.path, "plain"]],
                "blocked": ["command": python, "args": [script.path, "blocked", "blocked"]],
            ]
            try JSONSerialization.data(withJSONObject: ["mcpServers": reloadServers], options: [.prettyPrinted])
                .write(to: StoragePaths.configRoot.appendingPathComponent("mcp.json"))
            await registry.reopenAfterExitShutdownForSelftest()
            let first = Task { await registry.reloadFromDisk() }
            var owned: [Int32] = []
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                owned = await registry.ownedProcessIdentifiers()
                if owned.count == 2 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            check("5.1 first reload's bootstrap is in flight with two owned servers", owned.count == 2, "\(owned)")
            // The second reload parks in teardown(), awaiting the blocked
            // bootstrap — the shape of BrowserAutomationBootstrap's
            // background configure resuming during the exit.
            let second = Task { await registry.reloadFromDisk() }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let ownedWhileParked = await registry.ownedProcessIdentifiers()
            check("5.2 second reload is parked behind the blocked bootstrap (same two servers, nothing published)",
                  ownedWhileParked == owned, "\(ownedWhileParked)")
            await MainActor.run { TerminalSession.shutdownChildProcesses() }
            let atReturn = LeftoverChildSweep.snapshot() ?? []
            for pid in owned {
                check("5.3 owned shim \(pid) gone and collected at the exit shutdown's return",
                      !atReturn.contains { $0.pid == pid }, Self.describeTree(pid))
            }
            _ = await first.value
            _ = await second.value
            let ownedAfter = await registry.ownedProcessIdentifiers()
            let kidsAfter = liveChildren()
            check("5.4 registry owns nothing after both reloads settle", ownedAfter.isEmpty, "\(ownedAfter)")
            check("5.5 the reload that resumed after the exit shutdown spawned nothing", kidsAfter.isEmpty, "\(kidsAfter)")
            let defs = await registry.allToolDefinitions()
            await registry.reloadFromDisk()
            let ownedAfterReload = await registry.ownedProcessIdentifiers()
            let kidsAfterReload = liveChildren()
            check("5.6 tool list after the exit shutdown is empty and spawns nothing", defs.isEmpty && ownedAfterReload.isEmpty,
                  "defs=\(defs.count) owned=\(ownedAfterReload)")
            check("5.7 a reload issued after the exit shutdown spawns nothing", kidsAfterReload.isEmpty, "\(kidsAfterReload)")
            for pid in kidsAfterReload { _ = Darwin.kill(pid, SIGKILL) }
        }

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
        // Clean signal state, as Foundation's Process gives real children: a
        // raw posix_spawn inherits this process's signal mask and ignored
        // dispositions, and an "obedient" plant that silently inherited an
        // ignored SIGTERM would test the wrong thing (seen: the obedient
        // parent needed SIGKILL until this reset was added).
        var defaultSigs = sigset_t()
        sigfillset(&defaultSigs)
        posix_spawnattr_setsigdefault(&attr, &defaultSigs)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        var flags = Int16(POSIX_SPAWN_SETSIGDEF) | Int16(POSIX_SPAWN_SETSIGMASK)
        if newGroup {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attr, 0)
        }
        posix_spawnattr_setflags(&attr, flags)
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], nil, &attr, cargs, environ)
        guard rc == 0 else { throw ExitCode(1) }
        return pid
    }

    private static func waitForPidFile(_ url: URL, seconds: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            usleep(50_000)
        }
        return nil
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
    /// keeps reading and exits on stdin EOF. Modes: `ignore-term` ignores
    /// SIGTERM AND keeps running on EOF, like a wedged real server;
    /// `fork-detached` forks a SIGTERM-ignoring child in its own session
    /// (pid written to argv[3]) and exits on EOF like a well-behaved server;
    /// `blocked` reads requests but never answers, so initialize hangs.
    private static var fakeServerSource: String {
        """
        import sys, json, signal, time, os
        label = sys.argv[1]
        mode = sys.argv[2] if len(sys.argv) > 2 else "plain"
        stubborn = mode == "ignore-term"
        if stubborn:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if mode == "fork-detached":
            if os.fork() == 0:
                os.setsid()
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                with open(sys.argv[3], "w") as f:
                    f.write(str(os.getpid()))
                while True:
                    time.sleep(3600)
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
            if mode == "blocked":
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
