import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Process-tree signalling. `/bin/zsh -lc` children routinely spawn grandchildren
/// (dev servers, watchers, build daemons); signalling only the shell pid leaves
/// them running. Descendants must be collected BEFORE the root is signalled —
/// once the shell dies its children reparent to launchd and can no longer be
/// discovered by walking parent pids.
enum ProcessTree {

    /// All live descendant pids of `rootPid`, found by BFS over `pgrep -P`.
    static func descendants(of rootPid: Int32) -> [Int32] {
        guard rootPid > 0 else { return [] }
        var found: [Int32] = []
        var queue: [Int32] = [rootPid]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-P", String(parent)]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let children = (String(data: data, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 > 0 }
            found.append(contentsOf: children)
            queue.append(contentsOf: children)
        }
        return found
    }

    /// Process groups covering the tree: the root's own group plus every
    /// descendant's, minus Briglia's. Group signalling is what catches processes
    /// the BFS structurally cannot see: a `(daemon &)` double fork reparents
    /// to init before we walk parent pids, but it KEEPS the shell's process
    /// group. Conversely the BFS catches a descendant that moved itself into
    /// a fresh group; the two sweeps are complementary. The trampoline's
    /// fallback path (see SetsidExec: Foundation makes the shim a group
    /// leader, so in-place setsid() fails and the real command is
    /// posix_spawn'd into a NEW session) is why the root's group alone is
    /// never enough — the real command's group is only discovered through
    /// its pid in the descendants walk.
    static func processGroups(rootPid: Int32, descendants: [Int32]) -> [Int32] {
        let ownGroup = getpgid(0)
        var groups = Set<Int32>()
        for pid in [rootPid] + descendants {
            let pgid = getpgid(pid)
            // Guard against ever group-signalling ourselves (or init): no
            // legitimate child group can be Briglia's, but pid reuse races are
            // cheap to exclude.
            if pgid > 1 && pgid != ownGroup { groups.insert(pgid) }
        }
        return Array(groups)
    }

    /// SIGTERM the whole tree rooted at `process` — its process groups AND
    /// each individually-known pid — wait `graceNanos`, SIGKILL survivors.
    static func terminate(_ process: Process, graceNanos: UInt64 = 300_000_000) async {
        let rootPid = process.processIdentifier
        let kids = descendants(of: rootPid)
        let groups = processGroups(rootPid: rootPid, descendants: kids)
        if ProcessInfo.processInfo.environment["BRIGLIA_DEBUG_PROCTREE"] != nil {
            FileHandle.standardError.write(Data("[proctree] root=\(rootPid) rootPgid=\(getpgid(rootPid)) kids=\(kids.map { "\($0)/pg\(getpgid($0))" }) groups=\(groups)\n".utf8))
        }
        if process.isRunning { process.terminate() }
        for g in groups { _ = Darwin.kill(-g, SIGTERM) }
        for pid in kids { _ = Darwin.kill(pid, SIGTERM) }
        try? await Task.sleep(nanoseconds: graceNanos)
        if process.isRunning { _ = Darwin.kill(rootPid, SIGKILL) }
        for g in groups {
            let probe = Darwin.kill(-g, 0)
            if ProcessInfo.processInfo.environment["BRIGLIA_DEBUG_PROCTREE"] != nil {
                FileHandle.standardError.write(Data("[proctree] probe -\(g) => \(probe) errno=\(errno)\n".utf8))
            }
            if probe == 0 { _ = Darwin.kill(-g, SIGKILL) }
        }
        for pid in kids where Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
    }

    /// Synchronous SIGTERM sweep of the tree rooted at each process — no grace
    /// period, no SIGKILL escalation. App-shutdown path where async isn't available.
    static func terminateSync(_ processes: [Process]) {
        let trees = processes
            .filter { $0.isRunning }
            .map { (process: $0, descendants: descendants(of: $0.processIdentifier)) }
        for tree in trees {
            let groups = processGroups(rootPid: tree.process.processIdentifier,
                                       descendants: tree.descendants)
            tree.process.terminate()
            for g in groups { _ = Darwin.kill(-g, SIGTERM) }
            for pid in tree.descendants { _ = Darwin.kill(pid, SIGTERM) }
        }
    }
}

/// Internal acknowledgement token for one job's pending completion notice
/// (BASH_V2_PLAN §8). Carried invisibly on the tool result that observed a
/// settlement; redeemed by ConversationManager only AFTER the turn's history
/// save succeeds, at which point the automatic completion notice is
/// withdrawn. The jobUUID — never the public handle — is what acknowledges,
/// so a stale receipt can't affect a same-named handle after registry
/// recreation. Excluded from provider requests and persisted JSON.
struct BashCompletionReceipt: Sendable, Equatable {
    let jobUUID: UUID
    let publicHandle: String
}

/// The `bash` tool family.
///
/// - `runManaged` starts a job through the shared lifecycle, waits
///   boundedly, and returns the result or a running handle.
/// - `runAttached` waits until settlement (foreground-only subagents,
///   internal scripts), bounded by an execution deadline.
/// - `runBackground` spawns detached, returns a handle immediately
///   (internal/test helper; the model detaches via wait_seconds=0).
/// - `output(handle:)` reads accumulated output for a background handle.
/// - `input(handle:text:)` writes text to a running background handle's stdin.
/// - `kill(handle:)` terminates a background handle (SIGTERM then SIGKILL).
///
/// When a background process exits, ConversationManager polls
/// `BackgroundProcessRegistry.shared.drainCompletions()` and injects a synthetic user
/// message so the agent can react to the completion.
enum BashTools {

    /// PATH for agent-spawned shells. The GUI app inherits launchd's minimal
    /// PATH, and `zsh -l` only restores Homebrew/user dirs if the user's
    /// dotfiles do — so prepend the places Briglia actually installs and expects
    /// tools (notably ~/.local/bin, where the onboarding installs `gws` and
    /// the `agentmail` key-broker wrapper). ~/.local/bin comes FIRST —
    /// standard XDG/systemd user-session order — so Briglia-installed wrappers
    /// win over a same-named Homebrew/system binary (a foreign `agentmail`
    /// has no key broker and can only fail auth). path_helper in
    /// /etc/zprofile reorders but preserves these entries.
    static func augmentedPath(_ existing: String?) -> String {
        let home = NSHomeDirectory()
        let localBin = "\(home)/.local/bin"
        let prepend = ["/opt/homebrew/bin", "/usr/local/bin"]
        let current = (existing?.isEmpty == false) ? existing! : "/usr/bin:/bin:/usr/sbin:/sbin"
        var parts = current.split(separator: ":").map(String.init)
        // ~/.local/bin is unconditionally MOVED to the front (not just
        // prepended when missing): an inherited PATH with Homebrew ahead of
        // it would let a foreign same-named binary shadow Briglia's wrappers —
        // the exact agentmail-broker bypass Codex flagged (round 5).
        parts.removeAll { $0 == localBin }
        let missing = prepend.filter { !parts.contains($0) }
        return ([localBin] + missing + parts).joined(separator: ":")
    }

    /// Attached execution (foreground-only subagents and internal script
    /// runs): the command waits until settlement, bounded by this execution
    /// deadline in seconds.
    static let attachedDefaultKillAfterSeconds: Int = 120
    static let attachedMaxKillAfterSeconds: Int = 600

    #if os(Linux)
    /// corelibs-foundation detects child termination via an inherited
    /// socketpair — which an orphan grandchild (`server &`) also inherits
    /// and keeps open, so `Process.isRunning` can stay true long after the
    /// child died (verified against corelibs Process.swift; bit us on CI as
    /// a 15s orphan-lifetime stall). Peek at the truth in /proc: a zombie
    /// ("Z" state — exited, unreaped because Foundation is still waiting on
    /// its socket) or a vanished pid means the child is done. Field 52 of
    /// /proc/<pid>/stat carries the raw wait status for the exit code.
    static func linuxPeekExited(pid: Int32) -> (exited: Bool, code: Int32?) {
        guard pid > 0 else { return (false, nil) }
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else {
            // Unreadable /proc is NOT proof of exit (restricted procfs,
            // transient failure). kill(pid, 0) distinguishes: ESRCH means
            // the pid is truly gone (a zombie still answers); anything else
            // means we can't prove exit — defer to Process.isRunning.
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return (true, nil) }
            return (false, nil)
        }
        let z = parseProcStatZombie(stat)
        return z.isZombie ? (true, z.code) : (false, nil)
    }
    #endif

    /// Parse a /proc/<pid>/stat line: is the process a zombie, and if so
    /// what exit code will its parent reap (wait status decoded; 128+sig
    /// for signal deaths, shell convention)? Pure string logic, compiled on
    /// both platforms so the selftest can exercise it: field 52 is the LAST
    /// field and carries the file's trailing newline — Int32("0\n") is nil,
    /// which silently degraded every zombie exit code to -1 until `success`
    /// started asserting exit_code == 0.
    static func parseProcStatZombie(_ stat: String) -> (isZombie: Bool, code: Int32?) {
        // Fields after the ")" (comm can contain spaces/parens; use the LAST ")").
        guard let r = stat.range(of: ") ", options: .backwards) else { return (false, nil) }
        let rest = stat[r.upperBound...].split(separator: " ", omittingEmptySubsequences: false)
        guard let state = rest.first, state == "Z" else { return (false, nil) }
        // rest[0] is field 3 (state) → field 52 (exit_code, Linux ≥3.5) is rest[49].
        if rest.count > 49,
           let raw = Int32(rest[49].trimmingCharacters(in: .whitespacesAndNewlines)) {
            let sig = raw & 0x7f
            return (true, sig != 0 ? 128 + sig : (raw >> 8) & 0xff)
        }
        return (true, nil)
    }
    static let outputCapBytes = 30_000  // Legacy cap — now used as a pre-check before TruncationService kicks in

    /// Absolute path of the running ada executable, used to re-invoke it as
    /// the `__setsid-exec` trampoline. argv[0] can be a bare PATH-resolved
    /// "ada"; Bundle.main knows the real path on both platforms.
    static let selfExecutablePath: String? = {
        let url = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let path = url.resolvingSymlinksInPath().path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    /// Wrap an absolute-path invocation in `briglia __setsid-exec` so the child
    /// runs detached from any controlling terminal (the trampoline execs the
    /// target in place, so the PID the parent tracks IS the target).
    /// Detachment makes tty-prompting tools (sudo, ssh) fail fast instead of
    /// writing `Password:` into Briglia's own terminal and hanging the turn.
    /// Passes through unchanged for relative paths or if the ada binary
    /// can't be resolved (never expected in a real install).
    static func detachedInvocation(executable: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        guard executable.hasPrefix("/"), let ada = selfExecutablePath else {
            return (executable, arguments)
        }
        return (ada, ["__setsid-exec", "--", executable] + arguments)
    }

    /// Detached invocation of `command` through the login shell.
    static func shellInvocation(for command: String) -> (executable: String, arguments: [String]) {
        detachedInvocation(executable: PlatformShell.path, arguments: ["-lc", command])
    }

    /// Non-interactive hints for agent-spawned shells: with no tty to prompt
    /// on, tools that would otherwise try should fail fast with a readable
    /// error the model can react to.
    static func applyNonInteractiveEnv(_ env: inout [String: String]) {
        env["GIT_TERMINAL_PROMPT"] = "0"
        #if os(Linux)
        if env["DEBIAN_FRONTEND"] == nil { env["DEBIAN_FRONTEND"] = "noninteractive" }
        #endif
    }

    struct OpResult {
        let content: String
        /// Set when this result observed a job's settlement (Phase 3 waits):
        /// the completion-acknowledgement token ConversationManager redeems
        /// after the turn persists. Never rendered to the model.
        var receipt: BashCompletionReceipt? = nil
        /// True when this result was a bounded wait that genuinely expired
        /// with the job still running — ToolExecutor records it in the
        /// turn's wait ledger (repeat-timeout guard). Never rendered.
        var waitExpired: Bool = false
        /// The job handle this result concerns (managed/wait paths only),
        /// for ledger bookkeeping. Never rendered separately.
        var jobHandle: String? = nil
        /// Set when this call returned while its job keeps running AND the
        /// job's crash record is durable (mid-turn early wake §3.10.1): the
        /// executor binds the result as `moved` for this job id.
        var movedJobUUID: UUID? = nil
    }

    // MARK: - Mid-turn early wake (§3.4, §3.10.1)

    /// Surfaced once by the manager as a maintenance notice (§3.4: a woken
    /// wait whose crash record cannot be written keeps waiting).
    nonisolated(unsafe) static var lastRecordFailure: String?

    /// Write the crash record of a main-owned job that is about to outlive
    /// its launching call. Returns the job's internal id once the record is
    /// durable; nil when there is no depth-0 wake scope (tests, subagents)
    /// or the write failed (the caller then does not detach).
    static func recordDetachedJob(handle: String, launch: DetachedJobRecord.Launch,
                                  owner: String) async -> UUID? {
        guard owner == BackgroundProcessRegistry.mainOwner, let wake = WakeContext.current else { return nil }
        guard let facts = await BackgroundProcessRegistry.shared.jobFacts(handleId: handle, owner: owner) else { return nil }
        do {
            if try DetachedJobStore.load().contains(where: { $0.jobId == facts.jobUUID }) { return facts.jobUUID }
            try DetachedJobStore.create(DetachedJobRecord(
                jobId: facts.jobUUID, instanceId: DetachedJobStore.instanceId,
                turnRunId: wake.turnRunId, toolCallId: wake.callId, callFingerprint: wake.fingerprint,
                handle: facts.handle, command: facts.command, description: facts.description,
                workdir: facts.workdir, startedAt: facts.startedAt, launch: launch,
                completionMessageId: facts.completionMessageId,
                historyAnchorMessageId: wake.historyAnchorMessageId))
        } catch {
            lastRecordFailure = error.localizedDescription
            DebugTelemetry.log(.info, summary: "could not record background job \(handle)",
                               detail: error.localizedDescription, isError: true)
            return nil
        }
        // Settled between the facts read and the create: persist its notice
        // now (the settlement hook found no record to update).
        if let body = await BackgroundProcessRegistry.shared.pendingCompletionBody(jobUUID: facts.jobUUID) {
            DetachedJobStore.recordSettlement(jobId: facts.jobUUID, body: body, at: Date())
        }
        return facts.jobUUID
    }

    /// The moved-result message (§3.4, §3.13): identical for a user-message
    /// wake and a forced test detach except for the reason clause.
    static func movedMessage(handle: String, reason: MidturnWakeReason, killAfterSeconds: Int?) -> String {
        let clause = reason == .testForced
            ? "because background-detach test mode is on"
            : "because a user message arrived"
        var text = "Moved to the background \(clause) — the command CONTINUES. Its result is delivered automatically when it exits, once you are idle after this turn (you cannot wait for it inside this turn); manage it with bash_manage(handle: '\(handle)')."
        if let killAfterSeconds {
            text += " It is still killed at its \(killAfterSeconds)-second execution deadline."
        }
        return text
    }

    /// True when a JSON-decoded value is a genuine boolean. `is Bool` alone
    /// is wrong on BOTH platforms: SE-0170 bridging makes NSNumber 0/1 pass
    /// it (verified against swift:6.1-jammy corelibs too, where JSON 1
    /// decodes as an "i"-typed NSNumber with `is Bool == true`). So the
    /// NSNumber's concrete type is authoritative: CFBoolean's CFTypeID on
    /// Darwin, objCType "c" (__NSCFBoolean) on Linux — JSONSerialization
    /// stores integers as "i"/"q" and doubles as "d" there, never "c".
    /// The trailing `is Bool` only catches a native Swift Bool that failed
    /// the NSNumber cast (hand-built dictionaries in tests).
    static func isJSONBoolean(_ value: Any) -> Bool {
        if let n = value as? NSNumber {
            #if canImport(Darwin)
            return CFGetTypeID(n) == CFBooleanGetTypeID()
            #else
            return String(cString: n.objCType) == "c"
            #endif
        }
        return value is Bool
    }

    /// Bounds for the lifecycle arguments.
    static let maxWaitSeconds = 120
    static let maxKillAfterSeconds = 604_800  // 7 days — integer-safety bound, nil means no deadline

    /// The quick-command default policy (§3.1): a bash call with no
    /// lifecycle arguments waits this long AND kills the process tree at
    /// the same deadline. Var (not let) solely so boundary selftests can
    /// shrink it — 120s defaults are untestable at wall-clock speed.
    nonisolated(unsafe) static var quickDefaultSeconds = 120

    // MARK: - Attached execution (foreground-only subagents, internal scripts)

    static func runAttached(
        command: String,
        killAfterSeconds: Int? = nil,
        workdir: String? = nil,
        description: String? = nil,
        serviceKeyEnv: [String: String]? = nil,
        register: ((Process) -> Void)? = nil,
        unregister: ((Process) -> Void)? = nil
    ) async -> OpResult {
        let deadlineSeconds = min(max(killAfterSeconds ?? attachedDefaultKillAfterSeconds, 1), attachedMaxKillAfterSeconds)
        let timeout = deadlineSeconds * 1000

        // Resolve per-command service key mapping.
        let (perCommandEnv, missingKeys) = resolvePerCommandKeys(serviceKeyEnv)
        if !missingKeys.isEmpty {
            return OpResult(content: jsonError("service_key_env: unknown keys: \(missingKeys.joined(separator: ", "))"))
        }

        let allSecrets = KeychainHelper.redactionEnvironment().merging(perCommandEnv) { _, new in new }
        let redactor = SecretRedactor(environment: allSecrets)

        // The command's output projection: full-stream collectors with
        // stateful decode/redaction and spill files. These stay caller-owned
        // — the attached payload is their finalize() view, not the
        // registry's rolling-buffer snapshot.
        let outCollector = ForegroundStreamCollector(streamLabel: "stdout", secrets: allSecrets)
        let errCollector = ForegroundStreamCollector(streamLabel: "stderr", secrets: allSecrets)

        // Execution itself runs through the shared managed-job lifecycle
        // (BASH_V2_PLAN §15 Phase 1): one process builder, one exit monitor,
        // one settle sequence for foreground and background alike. This call
        // only decides POLICY: how long to wait, when to kill, and how to
        // render the result.
        let job: (uuid: UUID, process: Process)
        do {
            job = try await BackgroundProcessRegistry.shared.startAttached(
                command: command, workdir: workdir, description: description,
                perCommandEnv: perCommandEnv,
                outSink: outCollector, errSink: errCollector
            )
        } catch let failure as BackgroundProcessRegistry.SpawnFailure {
            switch failure {
            case .workdirMissing(let path):
                return OpResult(content: jsonError("workdir does not exist: \(path)"))
            case .runFailed(let message):
                return OpResult(content: jsonError("failed to spawn subprocess: \(message)"))
            }
        } catch {
            return OpResult(content: jsonError("failed to spawn subprocess: \(error.localizedDescription)"))
        }
        register?(job.process)
        defer { unregister?(job.process) }
        let uuid = job.uuid

        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        var timedOut = false
        var cancelled = false
        // Check Task.isCancelled explicitly: once the surrounding task is cancelled,
        // Task.sleep throws immediately and the loop would otherwise busy-spin
        // until the deadline with the child still running.
        while true {
            if await BackgroundProcessRegistry.shared.settlementInfo(uuid: uuid).settled { break }
            if Date() >= deadline { timedOut = true; break }
            if Task.isCancelled { cancelled = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if timedOut || cancelled {
            await BackgroundProcessRegistry.shared.stopJob(
                uuid: uuid, cause: timedOut ? .foregroundTimeout : .turnCancelled)
            // Bounded settlement wait, detached so a cancelled caller task
            // doesn't turn the sleeps into a busy spin. The monitor's own
            // grace bounds (5s hard cap per stream) keep this short; the
            // 12s ceiling only guards a pathologically wedged monitor.
            let reap = Task.detached {
                let reapDeadline = Date().addingTimeInterval(12)
                while Date() < reapDeadline {
                    if await BackgroundProcessRegistry.shared.settlementInfo(uuid: uuid).settled { return }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            await reap.value
        }

        let exitCode = await BackgroundProcessRegistry.shared.settlementInfo(uuid: uuid).exitCode ?? -1
        await BackgroundProcessRegistry.shared.removeEntry(uuid: uuid)

        let stdoutFinal = outCollector.finalize()
        let stderrFinal = errCollector.finalize()
        var payload: [String: Any] = [
            // A nonzero exit is not a success: Pi throws a tool error on it,
            // Claude Code marks it failed — a misleading true teaches the
            // model to skip checking exit_code.
            "success": exitCode == 0 && !timedOut && !cancelled,
            "command": redactor.redact(command),
            "exit_code": Int(exitCode),
            "execution_timed_out": timedOut,
            "cancelled_by_user": cancelled,
            "stdout": stdoutFinal.text,
            "stderr": stderrFinal.text,
            "stdout_truncated": stdoutFinal.truncated,
            "stderr_truncated": stderrFinal.truncated,
            "kill_after_seconds": deadlineSeconds,
            "description": redactor.redact(description ?? "")
        ]
        if let path = stdoutFinal.spillPath { payload["stdout_full_output_path"] = path }
        if let path = stderrFinal.spillPath { payload["stderr_full_output_path"] = path }
        return OpResult(content: jsonString(payload))
    }

    // MARK: - Background

    static func runBackground(
        command: String,
        workdir: String? = nil,
        description: String? = nil,
        serviceKeyEnv: [String: String]? = nil,
        owner: String = BackgroundProcessRegistry.mainOwner
    ) async -> OpResult {
        let (perCommandEnv, missingKeys) = resolvePerCommandKeys(serviceKeyEnv)
        if !missingKeys.isEmpty {
            return OpResult(content: jsonError("service_key_env: unknown keys: \(missingKeys.joined(separator: ", "))"))
        }
        let redactor = SecretRedactor()
        do {
            let handle = try await BackgroundProcessRegistry.shared.start(
                command: command,
                workdir: workdir,
                description: description,
                perCommandEnv: perCommandEnv,
                owner: owner
            )
            // Subagent-owned jobs get no completion notice and die with the
            // run — the start message must not promise otherwise.
            let message = owner == BackgroundProcessRegistry.mainOwner
                ? "Process started in background. Use bash_manage(mode='output', handle='\(handle.id)') to peek at output, bash_manage(mode='input', handle='\(handle.id)', text='...') to send stdin, bash_manage(mode='kill', handle='\(handle.id)') to stop. You will be notified automatically when it exits."
                : "Process started in background (private to this run). Poll bash_manage(mode='output', handle='\(handle.id)') for progress — there is NO automatic exit notification — and collect what you need before returning your final result: jobs still running when you finish are terminated."
            return OpResult(content: jsonString([
                "success": true,
                "handle": handle.id,
                "pid": handle.pid,
                "status": "running",
                "command": redactor.redact(command),
                "description": redactor.redact(description ?? ""),
                "message": message
            ]))
        } catch {
            return OpResult(content: jsonError("failed to spawn background process: \(error.localizedDescription)"))
        }
    }

    /// Terminal-snapshot render normalization (schema-cleanup review): a
    /// job can settle between a wait outcome (or a wait=0 start) and the
    /// response snapshot. A snapshot that turns out terminal must render
    /// as a plain terminal result — never `wait_timed_out` or a message
    /// promising a future notification the minted receipt will withdraw —
    /// and must not arm the repeat-timeout guard. Pure so the selftest can
    /// pin it directly; cancelled branches never call it (their extras are
    /// truthful regardless of settlement).
    static func normalizeTerminalRender(
        settled: Bool, extra: [String: Any], waitExpired: Bool
    ) -> (extra: [String: Any], waitExpired: Bool) {
        guard settled else { return (extra, waitExpired) }
        var e = extra
        e.removeValue(forKey: "wait_timed_out")
        e.removeValue(forKey: "message")
        e.removeValue(forKey: "wake_reason")
        e.removeValue(forKey: "moved_to_background")
        return (e, false)
    }

    /// The ONE snapshot payload builder for output/wait/managed responses
    /// (BASH_V2_PLAN §6) — the shared encoder that keeps them from
    /// drifting. `output` renders it verbatim (that exact shape is frozen
    /// by the golden selftest); wait/managed responses add their fields on
    /// top of the same base.
    private static func snapshotPayload(
        _ snapshot: BackgroundProcessRegistry.Snapshot,
        handle: String, since: Int, sinceStderr: Int
    ) -> [String: Any] {
        let redactor = SecretRedactor()
        // `since`/`since_stderr` are CUMULATIVE stream offsets (the model
        // passes back the previous read's *_total_bytes). The rolling buffer
        // only holds the last ~120KB, so translate cumulative offsets into
        // buffer offsets via the evicted count. A request reaching into
        // evicted territory can only return what the buffer still holds —
        // flag the gap instead of silently serving the wrong bytes.
        let newStdout = snapshot.stdout.suffixFromByte(max(0, since - snapshot.stdoutEvicted))
        let newStderr = snapshot.stderr.suffixFromByte(max(0, sinceStderr - snapshot.stderrEvicted))
        let (outText, outTrunc, _) = TruncationService.truncate(newStdout, direction: .tail)
        let (errText, errTrunc, _) = TruncationService.truncate(newStderr, direction: .tail)
        var payload: [String: Any] = [
            "success": true,
            "handle": handle,
            "status": snapshot.status.rawValue,
            "stdout": outText,
            "stderr": errText,
            "stdout_truncated": outTrunc,
            "stderr_truncated": errTrunc,
            "stdout_total_bytes": snapshot.stdoutEvicted + snapshot.stdout.utf8.count,
            "stderr_total_bytes": snapshot.stderrEvicted + snapshot.stderr.utf8.count,
            "running_for_seconds": Int(snapshot.runningFor),
            "command": redactor.redact(snapshot.command)
        ]
        if since < snapshot.stdoutEvicted {
            payload["stdout_gap"] = true
            payload["stdout_evicted_bytes"] = snapshot.stdoutEvicted
        }
        if sinceStderr < snapshot.stderrEvicted {
            payload["stderr_gap"] = true
            payload["stderr_evicted_bytes"] = snapshot.stderrEvicted
        }
        if let p = snapshot.stdoutSpillPath { payload["stdout_full_output_path"] = p }
        if let p = snapshot.stderrSpillPath { payload["stderr_full_output_path"] = p }
        if let code = snapshot.exitCode { payload["exit_code"] = code }
        return payload
    }

    // MARK: - Managed jobs (v2 contract, BASH_V2_PLAN §5)

    /// `bash` with `wait_seconds`: start through the shared lifecycle, wait
    /// boundedly for settlement, and either return the final result in this
    /// same call or a running handle while the command CONTINUES. Waiting
    /// and process lifetime are independent: wait expiry never kills the
    /// job; only `kill_after_seconds` (an execution deadline on the whole
    /// process tree) does.
    static func runManaged(
        command: String,
        requestedWaitSeconds: Int,
        effectiveWaitSeconds: Double,
        waitRefusalReason: String?,
        killAfterSeconds: Int?,
        workdir: String? = nil,
        description: String? = nil,
        serviceKeyEnv: [String: String]? = nil,
        owner: String = BackgroundProcessRegistry.mainOwner
    ) async -> OpResult {
        let (perCommandEnv, missingKeys) = resolvePerCommandKeys(serviceKeyEnv)
        if !missingKeys.isEmpty {
            return OpResult(content: jsonError("service_key_env: unknown keys: \(missingKeys.joined(separator: ", "))"))
        }
        let isMain = owner == BackgroundProcessRegistry.mainOwner
        let effectiveWait = waitRefusalReason == nil
            ? min(max(effectiveWaitSeconds, 0), Double(maxWaitSeconds))
            : 0
        let handle: BackgroundProcessRegistry.Handle
        do {
            handle = try await BackgroundProcessRegistry.shared.start(
                command: command, workdir: workdir, description: description,
                perCommandEnv: perCommandEnv, owner: owner,
                turnRunId: isMain ? WakeContext.current?.turnRunId : nil)
        } catch {
            return OpResult(content: jsonError("failed to spawn background process: \(error.localizedDescription)"))
        }
        if let killAfter = killAfterSeconds {
            let clamped = min(max(killAfter, 1), maxKillAfterSeconds)
            await BackgroundProcessRegistry.shared.armExecutionDeadline(
                handleId: handle.id, afterNanos: UInt64(clamped) * 1_000_000_000)
        }
        BashJobsStats.log("managed.starts")
        if waitRefusalReason != nil { BashJobsStats.log("managed.initial_wait_refused") }

        // Non-cancelled branches may render a snapshot that is already
        // terminal — most commonly a ledger-refused initial wait on a fast
        // command that settled in milliseconds. That snapshot delivers the
        // final result into the turn, so it mints the acknowledgement
        // receipt (§8) like a settle-in-wait does, suppressing the duplicate
        // completion notice once the turn durably saves. The cancelled
        // branch opts out: a /stop'd turn may never save.
        func render(extra: [String: Any], receipt: BashCompletionReceipt? = nil,
                    waitExpired: Bool = false, mintIfSettled: Bool = true,
                    moved: UUID? = nil) async -> OpResult {
            guard let (snapshot, minted) = await BackgroundProcessRegistry.shared
                .snapshotWithReceipt(handleId: handle.id, owner: owner) else {
                return OpResult(content: jsonError("job vanished during start: \(handle.id)"))
            }
            // Settlement between the wait outcome and this snapshot must
            // not produce a contradictory payload ("exited" + wait_timed_out
            // + a promised notification the receipt then withdraws).
            let (extra, waitExpired) = mintIfSettled
                ? normalizeTerminalRender(settled: snapshot.exitCode != nil,
                                          extra: extra, waitExpired: waitExpired)
                : (extra, waitExpired)
            var payload = snapshotPayload(snapshot, handle: handle.id, since: 0, sinceStderr: 0)
            payload["pid"] = Int(handle.pid)
            payload["description"] = SecretRedactor().redact(snapshot.description ?? "")
            payload["effective_wait_seconds"] = Int(effectiveWait.rounded())
            if let refusal = waitRefusalReason { payload["wait_refused"] = refusal }
            if let killAfter = killAfterSeconds {
                payload["kill_after_seconds"] = min(max(killAfter, 1), maxKillAfterSeconds)
            }
            if snapshot.status == .timedOut { payload["execution_timed_out"] = true }
            for (k, v) in extra { payload[k] = v }
            // A settled snapshot is a real result: no moved binding.
            return OpResult(content: jsonString(payload),
                            receipt: receipt ?? (mintIfSettled ? minted : nil),
                            waitExpired: waitExpired, jobHandle: handle.id,
                            movedJobUUID: snapshot.exitCode == nil ? moved : nil)
        }

        if effectiveWait <= 0 {
            // Crash record BEFORE the handle result is returned (§3.10.1):
            // an explicit background launch whose record cannot be written
            // is stopped and reported honestly instead of running untracked.
            var recorded: UUID? = nil
            if isMain, WakeContext.current != nil {
                recorded = await recordDetachedJob(handle: handle.id, launch: .background, owner: owner)
                if recorded == nil {
                    await BackgroundProcessRegistry.shared.stopJob(handleId: handle.id, cause: .turnCancelled)
                    return OpResult(content: jsonError("could not record the background job (storage problem: \(lastRecordFailure ?? "unknown")) — it was stopped so it cannot run untracked; retry, or run it with a wait"))
                }
            }
            let startMessage = isMain
                ? "Process started. Use bash_manage (mode 'output'/'input'/'watch'/'wait'/'kill') with this handle. You will be notified automatically when it exits."
                : "Process started (private to this run). Use bash_manage (mode 'output'/'wait'/'input'/'kill') with this handle — there is NO automatic exit notification, and jobs still running when you finish are terminated, so collect what you need before returning your final result."
            return await render(extra: [
                "waited_seconds": 0,
                "message": startMessage
            ], moved: recorded)
        }

        let t0 = ContinuousClock.now
        var outcome = await BackgroundProcessRegistry.shared.awaitSettlement(
            handleId: handle.id, timeoutNanos: UInt64(effectiveWait * 1_000_000_000),
            owner: owner, wake: isMain ? WakeContext.current : nil)
        // Mid-turn early wake (§3.4): a woken wait detaches only once the
        // job's crash record is durable. If it cannot be written, the call
        // keeps waiting as before (the rest of its window, no wake).
        var movedJob: UUID? = nil
        var wakeReason: MidturnWakeReason? = nil
        if case .woken(let reason) = outcome {
            movedJob = await recordDetachedJob(handle: handle.id,
                                               launch: reason == .testForced ? .forcedDetach : .wakeDetached,
                                               owner: owner)
            if movedJob != nil {
                wakeReason = reason
                if reason == .testForced {
                    DebugTelemetry.log(.info, summary: "midturnForcedDetach bash \(handle.id)",
                                       detail: "elapsed \(Int(BashWaitLedger.seconds(t0.duration(to: .now))))s")
                }
            } else {
                let remaining = max(0, effectiveWait - BashWaitLedger.seconds(t0.duration(to: .now)))
                outcome = await BackgroundProcessRegistry.shared.awaitSettlement(
                    handleId: handle.id, timeoutNanos: UInt64(remaining * 1_000_000_000), owner: owner)
            }
        }
        let waited = (BashWaitLedger.seconds(t0.duration(to: .now)) * 10).rounded() / 10

        switch outcome {
        case .woken:
            guard let wakeReason else { return await render(extra: ["waited_seconds": waited]) }
            BashJobsStats.log("managed.woken")
            // No ledger strike (waitExpired false): the job did not time out.
            let defaultDeadline = killAfterSeconds.map { min(max($0, 1), maxKillAfterSeconds) }
            return await render(extra: [
                "waited_seconds": waited,
                "moved_to_background": true,
                "wake_reason": wakeReason.rawValue,
                "message": movedMessage(handle: handle.id, reason: wakeReason, killAfterSeconds: defaultDeadline)
            ], moved: movedJob)
        case .settled(_, let receipt):
            BashJobsStats.log("managed.settled_in_initial_wait")
            BashJobsStats.logWait(ms: Int(waited * 1000))
            return await render(extra: ["waited_seconds": waited], receipt: receipt)
        case .waitTimedOut:
            // An execution deadline due at or before wait expiry means the
            // job is being killed RIGHT NOW (§6.2.5) — the default quick
            // command (wait=120, kill=120) hits this every time it runs
            // long. Wait boundedly for the kill to settle and return the
            // terminal execution_timed_out snapshot instead of a misleading
            // "still running" handle followed by a completion notice.
            if let killAfter = killAfterSeconds, Double(killAfter) <= effectiveWait + 0.5 {
                // Wait for full settlement (exit code recorded, completion
                // enqueued), not just the pre-kill status stamp — the
                // rendered snapshot must be terminal AND mint its receipt.
                let reapDeadline = Date().addingTimeInterval(15)
                while Date() < reapDeadline {
                    if let s = await BackgroundProcessRegistry.shared.snapshot(handleId: handle.id, owner: owner),
                       s.status != .running, s.exitCode != nil { break }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                BashJobsStats.log("managed.settled_at_deadline")
                BashJobsStats.logWait(ms: Int(waited * 1000))
                return await render(extra: ["waited_seconds": waited])
            }
            BashJobsStats.log("managed.initial_wait_expired")
            BashJobsStats.logWait(ms: Int(waited * 1000))
            // The job continues past its launching call: crash record
            // (best effort — the wait already ended, so a failure only means
            // no restart protection for this job).
            let expiredRecord = isMain ? await recordDetachedJob(handle: handle.id, launch: .waitExpired, owner: owner) : nil
            let continueMessage = isMain
                ? "Still running after the initial wait — the command CONTINUES. You will be notified automatically when it exits; manage it with bash_manage(handle: '\(handle.id)')."
                : "Still running after the initial wait — the command CONTINUES (private to this run, no automatic exit notification). Collect its result with bash_manage(mode 'wait'/'output', handle: '\(handle.id)') before returning your final result; jobs still running when you finish are terminated."
            return await render(extra: [
                "waited_seconds": waited,
                "wait_timed_out": true,
                "message": continueMessage
            ], waitExpired: true, moved: expiredRecord)
        case .cancelled:
            BashJobsStats.log("wait.cancelled")
            // Attached semantics (§10.1): during the initial bash wait the
            // job belongs to this tool call — /stop kills the process tree,
            // matching attached-execution behavior.
            await BackgroundProcessRegistry.shared.stopJob(handleId: handle.id, cause: .turnCancelled)
            let jobOwner = owner
            let reap = Task.detached {
                let deadline = Date().addingTimeInterval(12)
                while Date() < deadline {
                    if let s = await BackgroundProcessRegistry.shared.snapshot(handleId: handle.id, owner: jobOwner),
                       s.status != .running { return }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            await reap.value
            return await render(extra: ["waited_seconds": waited, "cancelled_by_user": true],
                                mintIfSettled: false)
        case .refusedDuplicate, .unknownHandle:
            // Impossible for a freshly minted handle; render defensively.
            return await render(extra: ["waited_seconds": waited])
        }
    }

    /// `bash_manage(mode="wait")`: bounded wait for an existing job's
    /// settlement, returning the same snapshot shape as `output` plus the
    /// wait fields. `effectiveWaitSeconds` comes from the turn ledger's
    /// admission; a refusal renders an immediate snapshot with
    /// `wait_refused` instead of blocking (§6). Cancelling this wait never
    /// touches the job (§10.2).
    static func waitManage(
        handle: String,
        effectiveWaitSeconds: Double?,
        refusalReason: String?,
        since: Int = 0, sinceStderr: Int = 0,
        owner: String = BackgroundProcessRegistry.mainOwner
    ) async -> OpResult {
        // Every non-cancelled branch may serve a snapshot that turns out to
        // be terminal — a refused wait on an already-settled job, or a job
        // settling between the wait outcome and the snapshot. Such a snapshot
        // delivers the final result into the turn, so it mints the
        // acknowledgement receipt (§8) exactly like a settled wait; the
        // notice is withdrawn only after the turn durably saves, so the
        // change can only remove duplicates, never cause loss. The cancelled
        // branch opts out (`mintIfSettled: false`): a /stop'd turn may never
        // save, and its result may never reach the model.
        func snapshotOrError(extra: [String: Any], receipt: BashCompletionReceipt? = nil,
                             waitExpired: Bool = false, mintIfSettled: Bool = true,
                             moved: UUID? = nil) async -> OpResult {
            guard let (snapshot, minted) = await BackgroundProcessRegistry.shared
                .snapshotWithReceipt(handleId: handle, owner: owner) else {
                return OpResult(content: jsonError(await unknownHandleMessage(handle, owner: owner)))
            }
            // Same render-race normalization as runManaged: a job settling
            // between the wait outcome and this snapshot renders as a plain
            // terminal result, never wait_timed_out + a promised notice.
            let (extra, waitExpired) = mintIfSettled
                ? normalizeTerminalRender(settled: snapshot.exitCode != nil,
                                          extra: extra, waitExpired: waitExpired)
                : (extra, waitExpired)
            var payload = snapshotPayload(snapshot, handle: handle, since: since, sinceStderr: sinceStderr)
            for (k, v) in extra { payload[k] = v }
            return OpResult(content: jsonString(payload),
                            receipt: receipt ?? (mintIfSettled ? minted : nil),
                            waitExpired: waitExpired, jobHandle: handle,
                            movedJobUUID: snapshot.exitCode == nil ? moved : nil)
        }

        BashJobsStats.log("manage_wait.calls")
        if let refusalReason {
            BashJobsStats.log("manage_wait.refused")
            return await snapshotOrError(extra: ["waited_seconds": 0, "wait_refused": refusalReason])
        }
        let waitSecs = min(max(effectiveWaitSeconds ?? 1, 1), Double(maxWaitSeconds))
        let t0 = ContinuousClock.now
        let isMain = owner == BackgroundProcessRegistry.mainOwner
        var outcome = await BackgroundProcessRegistry.shared.awaitSettlement(
            handleId: handle, timeoutNanos: UInt64(waitSecs * 1_000_000_000), owner: owner,
            wake: isMain ? WakeContext.current : nil)
        // Same rule as the launch wait (§3.4): detach only with a durable
        // crash record, otherwise keep waiting out the admitted window.
        var movedJob: UUID? = nil
        var wakeReason: MidturnWakeReason? = nil
        if case .woken(let reason) = outcome {
            movedJob = await recordDetachedJob(handle: handle,
                                               launch: reason == .testForced ? .forcedDetach : .wakeDetached,
                                               owner: owner)
            if movedJob != nil {
                wakeReason = reason
                if reason == .testForced {
                    DebugTelemetry.log(.info, summary: "midturnForcedDetach bash_manage wait \(handle)",
                                       detail: "elapsed \(Int(BashWaitLedger.seconds(t0.duration(to: .now))))s")
                }
            } else {
                let remaining = max(0, waitSecs - BashWaitLedger.seconds(t0.duration(to: .now)))
                outcome = await BackgroundProcessRegistry.shared.awaitSettlement(
                    handleId: handle, timeoutNanos: UInt64(remaining * 1_000_000_000), owner: owner)
            }
        }
        let waited = (BashWaitLedger.seconds(t0.duration(to: .now)) * 10).rounded() / 10

        switch outcome {
        case .woken:
            guard let wakeReason else { return await snapshotOrError(extra: ["waited_seconds": waited]) }
            BashJobsStats.log("manage_wait.woken")
            return await snapshotOrError(extra: [
                "waited_seconds": waited,
                "effective_wait_seconds": Int(waitSecs),
                "moved_to_background": true,
                "wake_reason": wakeReason.rawValue,
                "message": movedMessage(handle: handle, reason: wakeReason, killAfterSeconds: nil)
            ], moved: movedJob)
        case .unknownHandle:
            return OpResult(content: jsonError(await unknownHandleMessage(handle, owner: owner)))
        case .refusedDuplicate:
            BashJobsStats.log("manage_wait.refused")
            return await snapshotOrError(extra: [
                "waited_seconds": 0,
                "wait_refused": "another wait is already active on \(handle)"
            ])
        case .settled(_, let receipt):
            BashJobsStats.log("manage_wait.settled")
            BashJobsStats.logWait(ms: Int(waited * 1000))
            return await snapshotOrError(
                extra: ["waited_seconds": waited, "effective_wait_seconds": Int(waitSecs)],
                receipt: receipt)
        case .waitTimedOut:
            BashJobsStats.log("manage_wait.expired")
            BashJobsStats.logWait(ms: Int(waited * 1000))
            let expiredMessage = owner == BackgroundProcessRegistry.mainOwner
                ? "Still running — this handle now refuses further waits this turn. End your turn; the result will be delivered automatically."
                : "Still running — this handle now refuses further waits this turn. Poll mode='output' later or kill the job; there is no automatic exit notification in this context."
            let expiredRecord = isMain ? await recordDetachedJob(handle: handle, launch: .waitExpired, owner: owner) : nil
            return await snapshotOrError(extra: [
                "waited_seconds": waited,
                "effective_wait_seconds": Int(waitSecs),
                "wait_timed_out": true,
                "message": expiredMessage
            ], waitExpired: true, moved: expiredRecord)
        case .cancelled:
            BashJobsStats.log("wait.cancelled")
            return await snapshotOrError(extra: ["waited_seconds": waited, "wait_cancelled": true],
                                         mintIfSettled: false)
        }
    }

    /// `bash_manage(mode="list")`: cheap summaries, never stream content.
    static func list(includeSettled: Bool, owner: String = BackgroundProcessRegistry.mainOwner) async -> OpResult {
        let jobs = await BackgroundProcessRegistry.shared.listJobs(includeSettled: includeSettled, owner: owner)
        let redactor = SecretRedactor()
        let rows: [[String: Any]] = jobs.map { j in
            var row: [String: Any] = [
                "handle": j.handle,
                "command": redactor.redact(j.command),
                "description": redactor.redact(j.description ?? ""),
                "status": j.status.rawValue,
                "running_for_seconds": j.runningForSeconds,
                "stdout_total_bytes": j.stdoutTotalBytes,
                "stderr_total_bytes": j.stderrTotalBytes,
                // Rows are already scoped to the caller — this labels whose
                // scope the listing is (main agent vs a subagent's own run).
                "owner": owner == BackgroundProcessRegistry.mainOwner ? "main" : "this_subagent_run"
            ]
            if let code = j.exitCode { row["exit_code"] = code }
            return row
        }
        return OpResult(content: jsonString([
            "success": true,
            "jobs": rows,
            "count": rows.count,
            "include_settled": includeSettled
        ]))
    }

    /// "unknown" vs "expired": a recently pruned handle (§13 tombstones)
    /// gets a specific error so the model learns the job finished and was
    /// retired rather than concluding it hallucinated the handle.
    static func unknownHandleMessage(_ handle: String, owner: String = BackgroundProcessRegistry.mainOwner) async -> String {
        // Tombstones are main-handle artifacts: another owner asking about
        // one gets plain "unknown" (its own jobs are simply not that handle).
        if owner == BackgroundProcessRegistry.mainOwner,
           await BackgroundProcessRegistry.shared.isExpiredHandle(handle) {
            return "expired background handle: \(handle) — the job settled and its record was retired (settled jobs are kept for about an hour, newest \(BackgroundProcessRegistry.terminalCountCap) under load). Full-output file paths from earlier results remain readable."
        }
        return "unknown background handle: \(handle)"
    }

    static func output(handle: String, since: Int = 0, sinceStderr: Int = 0, owner: String = BackgroundProcessRegistry.mainOwner) async -> OpResult {
        // A settled snapshot delivers the terminal result (final status, exit
        // code, full output) into this turn, so it mints the acknowledgement
        // receipt like a settled wait does (§8): once the turn is durably
        // saved the automatic completion notice is withdrawn instead of
        // arriving as a duplicate. Running jobs mint nothing, and a crashed
        // turn never acks — the notice still delivers (at-least-once).
        guard let (snapshot, receipt) = await BackgroundProcessRegistry.shared
            .snapshotWithReceipt(handleId: handle, owner: owner) else {
            return OpResult(content: jsonError(await unknownHandleMessage(handle, owner: owner)))
        }
        return OpResult(content: jsonString(
            snapshotPayload(snapshot, handle: handle, since: since, sinceStderr: sinceStderr)),
            receipt: receipt, jobHandle: handle)
    }

    static func input(handle: String, text: String, appendNewline: Bool = false, owner: String = BackgroundProcessRegistry.mainOwner) async -> OpResult {
        do {
            let bytesWritten = try await BackgroundProcessRegistry.shared.writeInput(
                handleId: handle,
                text: text,
                appendNewline: appendNewline,
                owner: owner
            )
            return OpResult(content: jsonString([
                "success": true,
                "handle": handle,
                "bytes_written": bytesWritten,
                "append_newline": appendNewline,
                "message": "Input written to background process stdin. Use bash_manage(mode='output') to inspect the response."
            ]))
        } catch BackgroundProcessRegistry.InputError.handleNotFound(let h) {
            return OpResult(content: jsonError(await unknownHandleMessage(h, owner: owner)))
        } catch {
            return OpResult(content: jsonError(error.localizedDescription))
        }
    }

    static func kill(handle: String, owner: String = BackgroundProcessRegistry.mainOwner) async -> OpResult {
        let ok = await BackgroundProcessRegistry.shared.kill(handleId: handle, owner: owner)
        if ok {
            return OpResult(content: jsonString([
                "success": true,
                "handle": handle,
                "message": "Sent SIGTERM (then SIGKILL if still running)."
            ]))
        }
        if owner == BackgroundProcessRegistry.mainOwner,
           await BackgroundProcessRegistry.shared.isExpiredHandle(handle) {
            return OpResult(content: jsonError(await unknownHandleMessage(handle)))
        }
        return OpResult(content: jsonError("unknown or already-stopped handle: \(handle)"))
    }

    // MARK: - Helpers

    /// Internal (not fileprivate) so read-only search tools (grep content mode)
    /// can redact service-key secrets from matched lines the same way bash
    /// output is redacted.
    struct SecretRedactor {
        private let replacements: [(secret: String, placeholder: String)]

        init(environment: [String: String] = KeychainHelper.redactionEnvironment()) {
            self.replacements = environment
                .filter { !$0.value.isEmpty }
                .sorted { $0.value.count > $1.value.count }
                .map { (secret: $0.value, placeholder: "[REDACTED:\($0.key)]") }
        }

        func redact(_ text: String) -> String {
            guard !replacements.isEmpty, !text.isEmpty else { return text }
            var redacted = text
            for replacement in replacements {
                redacted = redacted.replacingOccurrences(
                    of: replacement.secret,
                    with: replacement.placeholder
                )
            }
            return redacted
        }
    }

    fileprivate static func redactServiceKeys(in text: String) -> String {
        SecretRedactor().redact(text)
    }

    /// Resolve the agent's `service_key_env` mapping to real secrets.
    private static func resolvePerCommandKeys(_ mapping: [String: String]?) -> (resolved: [String: String], missing: [String]) {
        guard let mapping, !mapping.isEmpty else { return ([:], []) }
        return KeychainHelper.resolveServiceKeyEnv(mapping)
    }

    private static func jsonError(_ message: String) -> String {
        jsonString(["error": message])
    }

    private static func jsonString(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode response\"}"
    }
}

// MARK: - Background process registry

/// Owns all currently-running bash jobs (managed, detached, and attached).
/// ConversationManager calls `drainCompletions()` once per poll cycle to pull exit events and
/// inject them as synthetic user messages, triggering a new agent turn.
actor BackgroundProcessRegistry {
    static let shared = BackgroundProcessRegistry()

    /// Owner token of the main agent's executor. Subagent executors mint
    /// unique tokens; ownership scoping (§10.5) keys off exact equality.
    static let mainOwner = "main"

    struct Handle {
        let id: String
        let pid: Int32
    }

    enum Status: String {
        case running
        case exited
        case killed
        case crashed
        /// Killed by an execution deadline (kill_after_seconds) — never used
        /// for a wait expiring, which doesn't kill anything (BASH_V2_PLAN §6).
        case timedOut = "timed_out"
    }

    /// What kind of job an entry represents. Attached commands are
    /// routed through the same registry lifecycle (BASH_V2_PLAN §15 Phase 1)
    /// but stay invisible to the model-facing management surface: their
    /// handles are internal, they never produce completion notices, and
    /// snapshot/input/kill/watch refuse them.
    enum JobKind {
        case background
        case attached
    }

    /// Why a job stopped — recorded BEFORE signalling so the terminal status
    /// can never be mislabeled by the exit-detection race (BASH_V2_PLAN §10.4).
    /// `.executionDeadline` arrives with Phase 3's kill_after_seconds.
    enum TerminationCause {
        case naturalExit
        case userKill
        case foregroundTimeout
        case turnCancelled
        case appShutdown
        case executionDeadline
        /// The subagent that owned this job finished its run — owned jobs
        /// never outlive their owner (nobody could see them afterwards).
        case ownerFinished
    }

    /// How a bounded wait on a job resolved (BASH_V2_PLAN §11). Each waiter
    /// is resumed exactly once with its definitive outcome by whichever
    /// actor-serialized path removes it from the entry's waiter slot.
    enum WaitOutcome: Sendable {
        /// The job settled (readers drained, exit code final). Carries the
        /// completion-acknowledgement receipt when the automatic notice is
        /// still pending.
        case settled(exitCode: Int32?, receipt: BashCompletionReceipt?)
        /// The wait expired; the job keeps running and its completion will
        /// be delivered automatically. Never kills anything.
        case waitTimedOut
        /// The waiting turn was cancelled (/stop); the job keeps running.
        case cancelled
        /// Another wait is already active on this handle.
        case refusedDuplicate
        /// No such background handle.
        case unknownHandle
        /// A user message arrived during the wait and its grace window
        /// passed (or the hidden force-detach test setting fired): the wait
        /// ends early, the job KEEPS RUNNING in the background and its
        /// completion is delivered later (mid-turn early wake §3.4). Only a
        /// depth-0 main-agent wait inside a bound `WakeContext` can get this.
        case woken(MidturnWakeReason)
    }

    struct Snapshot {
        let id: String
        let command: String
        let description: String?
        let stdout: String
        let stderr: String
        /// Bytes evicted from the front of each rolling buffer; cumulative
        /// stream offset = evicted + buffer bytes.
        let stdoutEvicted: Int
        let stderrEvicted: Int
        /// Complete redacted stream files (nil below the spill threshold).
        let stdoutSpillPath: String?
        let stderrSpillPath: String?
        let status: Status
        let exitCode: Int?
        let runningFor: TimeInterval
        let workdir: String?
    }

    struct Completion {
        let handleId: String
        let command: String
        let description: String?
        let exitCode: Int32
        let status: Status
        let stdoutTail: String
        let stderrTail: String
        /// Complete redacted stream files (nil when the output fit inline).
        let stdoutFullPath: String?
        let stderrFullPath: String?
        let durationSeconds: Int
    }

    // MARK: - Watch

    /// A live regex subscription on a running background process. Fires synthetic
    /// `[BASH WATCH MATCH]` user messages into the conversation when matching lines
    /// appear on stdout/stderr. See `registerWatch(handle:pattern:limit:)`.
    struct Watch {
        let id: String
        let regex: NSRegularExpression
        let patternSource: String
        let limit: Int
        var matchesSoFar: Int
    }

    struct WatchMatch {
        let watchId: String
        let handle: String
        let pattern: String
        let line: String
        let stream: String           // "stdout" or "stderr"
        let matchedAt: Date
        let autoUnsubscribed: Bool   // true on limit reached, process exit, or ReDoS timeout
        let unsubscribeReason: String?
        let matchesSoFar: Int        // count including this match
        let limit: Int
        /// Stable identity of this queued match (mid-turn early wake §3.9:
        /// a /stop records the pending matches it holds).
        let matchId = UUID()
        /// Internal identity of the job the watched handle belongs to — a
        /// match of a job stopped by /stop is appended without waking.
        var ownerJobUUID: UUID? = nil
    }

    enum WatchError: Error, CustomStringConvertible {
        case handleNotFound
        case processAlreadyExited
        case invalidRegex(String)

        var description: String {
            switch self {
            case .handleNotFound:       return "unknown background handle"
            case .processAlreadyExited: return "process has already exited; cannot attach a watch"
            case .invalidRegex(let m):  return "invalid regex: \(m)"
            }
        }
    }

    fileprivate final class Entry: @unchecked Sendable {
        /// Stable internal identity, distinct from the public handle: a
        /// receipt or acknowledgement keyed on the UUID can never affect a
        /// same-named handle after the registry is recreated (tests) or the
        /// counter wraps around a restart.
        let jobUUID = UUID()
        let kind: JobKind
        /// Owning executor (BASH_V2_PLAN §10.5): "main" for the main agent,
        /// a unique per-run token for subagent executors. Background jobs
        /// are visible ONLY to their owner; only main-owned jobs produce
        /// completion notices (a subagent's would inject into the main
        /// conversation after the subagent is gone).
        let owner: String
        /// Set before signalling by whichever path stops the job; natural
        /// exits get `.naturalExit` at termination-marking time.
        var terminationCause: TerminationCause?
        let id: String
        let command: String
        let description: String?
        let workdir: String?
        let process: Process
        let stdin: FileHandle
        var stdout: String = ""
        var stderr: String = ""
        /// Trailing partial line not yet terminated by \n — held until a newline arrives
        /// so we only run watches against complete lines. Kept per-stream.
        var stdoutLineBuf: String = ""
        var stderrLineBuf: String = ""
        /// Stateful decoders: a multibyte character split across two pipe
        /// chunks must not discard the chunk (the old per-chunk
        /// String(data:encoding:) did exactly that). Touched only on ioQueue.
        var stdoutDecoder = IncrementalUTF8Decoder()
        var stderrDecoder = IncrementalUTF8Decoder()
        /// Bytes trimmed off the FRONT of the rolling buffers by the cap.
        /// `evicted + buffer.utf8.count` is the cumulative stream offset the
        /// `since` contract of bash_manage(output) is defined against —
        /// without it, offsets silently pointed into whatever the buffer
        /// happened to hold after eviction. Touched only on ioQueue.
        var stdoutEvicted = 0
        var stderrEvicted = 0
        /// Complete redacted stream on disk (mode 600, cleanup-swept), fed
        /// by each sink's embedded collector. nil until the stream crosses
        /// the inline threshold. Touched only on ioQueue.
        var stdoutSpillPath: String?
        var stderrSpillPath: String?
        var status: Status = .running
        var exitCode: Int?
        let startedAt: Date
        var completionDelivered = false
        /// True only once the exit monitor finished the full settle sequence
        /// (readers drained through grace, pipes closed, exit code recorded).
        /// Distinct from `status != .running`, which kill() flips BEFORE the
        /// process actually dies — callers awaiting final output must gate
        /// on THIS flag, never on status.
        var lifecycleSettled = false
        /// When the settle sequence finished — the clock the retention
        /// policy (BASH_V2_PLAN §13) prunes against. nil while running.
        var settledAt: Date?
        /// At most one active waiter per handle (BASH_V2_PLAN §11). All
        /// waiter-slot mutation happens on the registry actor; whoever
        /// removes the waiter owns its single resumption.
        var waiter: (id: UUID, continuation: CheckedContinuation<WaitOutcome, Never>)?
        /// Cancels the pending wait-timeout when another outcome wins.
        var waiterTimeoutTask: Task<Void, Never>?
        /// Listens for the mid-turn wake of the waiting call; cancelled when
        /// another outcome wins. Whichever of finish/timeout/cancel/wake
        /// reaches the actor first removes the waiter and resumes it once.
        var waiterWakeTask: Task<Void, Never>?
        /// Stable id of the job's completion message, minted with the job so
        /// every delivery attempt (and a crash record) reuses it — appends
        /// are id-deduplicated (mid-turn early wake §3.10).
        let completionMessageId = UUID()
        /// kill_after_seconds enforcement; cancelled at settlement.
        var executionDeadlineTask: Task<Void, Never>?

        init(id: String, command: String, description: String?, workdir: String?, process: Process, stdin: FileHandle, kind: JobKind = .background, owner: String = BackgroundProcessRegistry.mainOwner) {
            self.id = id
            self.command = command
            self.description = description
            self.workdir = workdir
            self.process = process
            self.stdin = stdin
            self.kind = kind
            self.owner = owner
            self.startedAt = Date()
        }
    }

    /// `PipeByteSink` adapter for one background stream: stateful decode,
    /// wholesale re-redaction of the rolling buffer (catches secrets split
    /// across chunk boundaries — this buffer is rewritable, unlike an
    /// append-only spill), tail cap, and complete-line feed into watches.
    /// All Entry mutation happens on ioQueue.
    ///
    /// An embedded ForegroundStreamCollector additionally preserves the
    /// COMPLETE stream on disk: it runs its own stateful decoder plus the
    /// carry-window StreamingRedactor (an append-only file can't be
    /// re-redacted wholesale), activating its mode-600 spill file once the
    /// stream crosses the inline threshold. Without it, everything past the
    /// 120KB rolling cap was simply gone.
    fileprivate final class BackgroundStreamSink: PipeByteSink, @unchecked Sendable {
        private let entry: Entry
        private let streamName: String
        private let buf: ReferenceWritableKeyPath<Entry, String>
        private let lineBuf: ReferenceWritableKeyPath<Entry, String>
        private let decoder: ReferenceWritableKeyPath<Entry, IncrementalUTF8Decoder>
        private let evicted: ReferenceWritableKeyPath<Entry, Int>
        private let spillPath: ReferenceWritableKeyPath<Entry, String?>
        private let redactor: BashTools.SecretRedactor
        private let ioQueue: DispatchQueue
        private let collector: ForegroundStreamCollector

        init(entry: Entry, stderr: Bool, redactor: BashTools.SecretRedactor,
             secrets: [String: String], ioQueue: DispatchQueue) {
            self.entry = entry
            self.streamName = stderr ? "stderr" : "stdout"
            self.buf = stderr ? \Entry.stderr : \Entry.stdout
            self.lineBuf = stderr ? \Entry.stderrLineBuf : \Entry.stdoutLineBuf
            self.decoder = stderr ? \Entry.stderrDecoder : \Entry.stdoutDecoder
            self.evicted = stderr ? \Entry.stderrEvicted : \Entry.stdoutEvicted
            self.spillPath = stderr ? \Entry.stderrSpillPath : \Entry.stdoutSpillPath
            self.redactor = redactor
            self.ioQueue = ioQueue
            self.collector = ForegroundStreamCollector(streamLabel: streamName, secrets: secrets)
        }

        /// Drain the collector's carries and close its spill file; returns
        /// the path of the complete redacted stream (nil if it fit inline).
        /// Call once, after the pipe readers have finished.
        func finalizeSpill() -> String? {
            collector.finalize().spillPath
        }

        func ingest(_ data: Data) {
            collector.ingest(data)
            ioQueue.async { [self] in
                // An empty Data is the reader's EOF marker — flush any
                // pending partial character. Idempotent with the monitor's
                // final flush.
                let s = data.isEmpty
                    ? entry[keyPath: decoder].flush()
                    : entry[keyPath: decoder].decode(data)
                guard !s.isEmpty else { return }
                entry[keyPath: buf].append(redactor.redact(s))
                entry[keyPath: buf] = redactor.redact(entry[keyPath: buf])
                let cap = BashTools.outputCapBytes * 4
                if entry[keyPath: buf].utf8.count > cap {
                    let before = entry[keyPath: buf].utf8.count
                    entry[keyPath: buf] = String(entry[keyPath: buf].suffix(cap))
                    entry[keyPath: evicted] += before - entry[keyPath: buf].utf8.count
                }
                // Surface the spill path as soon as spilling starts so
                // output() can point at it while the process still runs.
                if entry[keyPath: spillPath] == nil {
                    entry[keyPath: spillPath] = collector.spillPathSnapshot
                }
                let lines = BackgroundProcessRegistry.extractCompleteLines(
                    newChunk: s, buffer: &entry[keyPath: lineBuf])
                if !lines.isEmpty {
                    Task {
                        await BackgroundProcessRegistry.shared.evaluateWatches(
                            handleId: self.entry.id, stream: self.streamName,
                            lines: lines.map { self.redactor.redact($0) })
                    }
                }
            }
        }
    }

    /// Spawn-time failures shared by the attached and managed paths.
    /// The localized descriptions are part of the frozen payload contract:
    /// runAttached renders workdirMissing as its own error payload, and
    /// runManaged's catch prepends "failed to spawn background process:".
    enum SpawnFailure: Error, LocalizedError {
        case workdirMissing(String)
        case runFailed(String)

        var errorDescription: String? {
            switch self {
            case .workdirMissing(let path): return "workdir does not exist: \(path)"
            case .runFailed(let message):   return message
            }
        }
    }

    private var entries: [String: Entry] = [:]
    private var nextCounter: Int = 1
    /// Separate namespace for internal legacy-foreground entries so they
    /// never consume (or collide with) the model-visible bash_N numbering.
    private var fgCounter: Int = 1
    /// Pending completion notices keyed by the owning job's UUID — the key
    /// is what Phase 2's acknowledgement receipts will match against.
    /// `drainCompletions()` still returns bare Completions.
    private var pendingCompletions: [(jobUUID: UUID, messageId: UUID, completion: Completion)] = []
    private var watches: [String: [Watch]] = [:]
    private var nextWatchId: Int = 1
    private var pendingMatchEvents: [WatchMatch] = []

    // MARK: Retention (BASH_V2_PLAN §13)

    /// Exposed terminal handles stay inspectable for at least an hour, and
    /// the newest `terminalCountCap` survive regardless of load. Running
    /// entries, active waiters/watches, pending watch events, and pending
    /// (unacknowledged) completions are NEVER pruned.
    static let terminalRetentionSeconds: TimeInterval = 3600
    static let terminalCountCap = 50
    /// Attached-run internals are removed by their caller right after
    /// rendering; this shorter net only catches callers that died first.
    static let attachedRetentionSeconds: TimeInterval = 600
    private static let tombstoneCap = 200

    /// Recently pruned model-visible handles → prune time, so a stale
    /// handle earns a specific "expired" error instead of "unknown".
    private var tombstones: [String: Date] = [:]
    /// Test seams — nil means the production constants apply.
    private var retentionOverride: TimeInterval?
    private var countCapOverride: Int?

    func isExpiredHandle(_ handleId: String) -> Bool {
        tombstones[handleId] != nil
    }

    /// Selftest-only: tighten retention/cap so pruning is observable without
    /// hour-long waits, and reset tombstones between test groups.
    func _testSetPruneOverrides(retentionSeconds: TimeInterval?, countCap: Int?) {
        retentionOverride = retentionSeconds
        countCapOverride = countCap
    }

    func _testPruneNow() {
        pruneSettledEntries()
    }

    func _testClearTombstones() {
        tombstones.removeAll()
    }

    /// Sweep settled entries per §13. Runs opportunistically on registry
    /// traffic (start, completion drain, acknowledgement, list) — the
    /// completion drain alone gives it the poll-cycle cadence a time-based
    /// policy needs. Spill files are deliberately left alone: paths already
    /// returned to the model stay valid under the existing cleanup sweep.
    private func pruneSettledEntries(now: Date = Date()) {
        let retention = retentionOverride ?? Self.terminalRetentionSeconds
        let cap = countCapOverride ?? Self.terminalCountCap

        func prunable(_ e: Entry) -> Bool {
            guard e.lifecycleSettled, e.status != .running else { return false }
            guard e.waiter == nil else { return false }
            if let ws = watches[e.id], !ws.isEmpty { return false }
            if pendingMatchEvents.contains(where: { $0.handle == e.id }) { return false }
            if pendingCompletions.contains(where: { $0.jobUUID == e.jobUUID }) { return false }
            return true
        }

        // Age-based pass.
        for (key, e) in entries {
            guard prunable(e), let settledAt = e.settledAt else { continue }
            let limit = e.kind == .background ? retention : Self.attachedRetentionSeconds
            if now.timeIntervalSince(settledAt) > limit {
                entries.removeValue(forKey: key)
                if e.kind == .background { addTombstone(e.id, now: now) }
            }
        }

        // Count cap on exposed terminal handles, oldest-settled first.
        var terminal = entries.values.filter { $0.kind == .background && $0.lifecycleSettled }
        guard terminal.count > cap else { return }
        terminal.sort { ($0.settledAt ?? .distantPast) < ($1.settledAt ?? .distantPast) }
        var excess = terminal.count - cap
        for e in terminal {
            guard excess > 0 else { break }
            guard prunable(e) else { continue }
            entries.removeValue(forKey: e.id)
            addTombstone(e.id, now: now)
            excess -= 1
        }
    }

    private func addTombstone(_ handleId: String, now: Date) {
        tombstones[handleId] = now
        if tombstones.count > Self.tombstoneCap {
            let oldest = tombstones.sorted { $0.value < $1.value }
                .prefix(tombstones.count - Self.tombstoneCap)
            for (k, _) in oldest { tombstones.removeValue(forKey: k) }
        }
    }

    /// Serial queue coordinating writes to Entry buffers from pipe readability handlers.
    private let ioQueue = DispatchQueue(label: "com.permaevidence.briglia.background-process-io")

    private init() {}

    // MARK: Start

    /// Shared process construction for every bash job: invocation through
    /// the setsid trampoline, workdir validation, PATH augmentation,
    /// non-interactive env hints, and per-command secret injection. The
    /// process is NOT yet started.
    private static func buildProcess(
        command: String, workdir: String?, perCommandEnv: [String: String]
    ) throws -> Process {
        let process = Process()
        let invocation = BashTools.shellInvocation(for: command)
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        if let workdir {
            let expanded = FilesystemTools.normalizePath(workdir)
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw SpawnFailure.workdirMissing(expanded)
            }
            process.currentDirectoryURL = URL(fileURLWithPath: expanded)
        }
        // Only per-command secrets are injected into this process. The
        // AgentMail key deliberately does NOT ride in these environments at
        // all: the installed `agentmail` command is a broker wrapper that
        // fetches the key itself (via `briglia __agentmail-key`) and execs the
        // real binary, so the key exists only in the actual AgentMail
        // process — no shell-string heuristic decides credential scope
        // (Codex, 2026-08-22: substring matching is not a boundary). The
        // redactor is seeded from CredentialCatalog (service keys + the
        // Telegram bot token); the AgentMail key is deliberately visible
        // (owner decision, 2026-09-02).
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BashTools.augmentedPath(env["PATH"])
        BashTools.applyNonInteractiveEnv(&env)
        for (k, v) in perCommandEnv { env[k] = v }
        process.environment = env
        return process
    }

    /// The ONE exit-detection + stream-settlement sequence for every bash
    /// job, foreground or background: poll for exit (with the Linux /proc
    /// zombie peek that sees through corelibs' orphan-held socketpair),
    /// start BOTH reader grace clocks in parallel, release our pipe ends so
    /// orphan writers get EPIPE, then hand the definitive exit code to
    /// `onSettled`. Fixes to exit detection, grace, or pipe release land
    /// here exactly once for both paths.
    fileprivate static func startExitMonitor(
        process: Process,
        outReader: PipeStreamReader, errReader: PipeStreamReader,
        outPipe: Pipe, errPipe: Pipe, stdinWriteEnd: FileHandle?,
        pollNanos: UInt64,
        onSettled: @escaping @Sendable (Int32, Process.TerminationReason) -> Void
    ) {
        Task.detached(priority: .utility) {
            var linuxPeekCode: Int32?
            while process.isRunning {
                #if os(Linux)
                let peek = BashTools.linuxPeekExited(pid: process.processIdentifier)
                if peek.exited { linuxPeekCode = peek.code; break }
                #endif
                try? await Task.sleep(nanoseconds: pollNanos)
            }
            // Both grace clocks in parallel, then release our pipe ends so
            // an orphan writer sees EPIPE instead of a dead reader.
            outReader.noteProcessExited()
            errReader.noteProcessExited()
            await outReader.finish()
            await errReader.finish()
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            try? stdinWriteEnd?.close()

            // terminationStatus/terminationReason trap while Foundation
            // still believes the child runs — which on Linux it can, per
            // the socketpair caveat above.
            let exitCode: Int32
            let reason: Process.TerminationReason
            if process.isRunning {
                exitCode = linuxPeekCode ?? -1
                reason = .exit
            } else {
                exitCode = process.terminationStatus
                reason = process.terminationReason
            }
            onSettled(exitCode, reason)
        }
    }

    func start(command: String, workdir: String?, description: String?, perCommandEnv: [String: String] = [:], owner: String = BackgroundProcessRegistry.mainOwner,
               turnRunId: UUID? = nil) throws -> Handle {
        // /stop closed admission for this run (mid-turn early wake §3.9.1):
        // decided on the actor, atomically with the stop's snapshot, so a
        // racing launch is either stopped with the rest or refused.
        if let turnRunId, closedTurnRunIds.contains(turnRunId) {
            throw SpawnFailure.runFailed("not started: the user stopped this turn with /stop")
        }
        pruneSettledEntries()
        let id = "bash_\(nextCounter)"
        nextCounter += 1

        DebugTelemetry.log(
            .bashSpawn,
            summary: "spawn \(id): \(command.prefix(60))",
            detail: [
                "command: \(command)",
                workdir.map { "workdir: \($0)" } ?? nil,
                description.map { "description: \($0)" } ?? nil
            ].compactMap { $0 }.joined(separator: "\n")
        )

        let process = try Self.buildProcess(command: command, workdir: workdir, perCommandEnv: perCommandEnv)

        // Redactor still knows ALL secrets for comprehensive output scrubbing.
        let allSecrets = KeychainHelper.redactionEnvironment().merging(perCommandEnv) { _, new in new }
        let redactor = BashTools.SecretRedactor(environment: allSecrets)

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let entry = Entry(
            id: id,
            command: command,
            description: description,
            workdir: workdir,
            process: process,
            stdin: inPipe.fileHandleForWriting,
            owner: owner
        )

        let ioQ = self.ioQueue
        // Strong capture of `entry` is fine: the entry is retained by the
        // registry dictionary; the sinks and monitor task keep it alive
        // through termination.
        // Same poll-reader machinery as the foreground path — the old
        // readabilityHandler + availableData wiring had the identical
        // failure modes the foreground was hardened against: on Linux,
        // corelibs drops the final pipe-buffered chunks after child exit,
        // and the residual availableData drain in the termination handler
        // is a BLOCKING read on both platforms, so an orphan grandchild
        // holding the write end stalled the completion notice for its
        // whole lifetime.
        let outSink = BackgroundStreamSink(entry: entry, stderr: false, redactor: redactor,
                                           secrets: allSecrets, ioQueue: ioQ)
        let errSink = BackgroundStreamSink(entry: entry, stderr: true, redactor: redactor,
                                           secrets: allSecrets, ioQueue: ioQ)
        let outReader = PipeStreamReader(fd: outPipe.fileHandleForReading.fileDescriptor, collector: outSink)
        let errReader = PipeStreamReader(fd: errPipe.fileHandleForReading.fileDescriptor, collector: errSink)

        try process.run()
        outReader.start()
        errReader.start()
        entries[id] = entry

        // Completion detection through the shared exit monitor. The ≤200ms
        // detection latency is absorbed by ConversationManager's own
        // completion polling cadence.
        Self.startExitMonitor(
            process: process,
            outReader: outReader, errReader: errReader,
            outPipe: outPipe, errPipe: errPipe,
            stdinWriteEnd: inPipe.fileHandleForWriting,
            pollNanos: 200_000_000
        ) { exitCode, reason in
            ioQ.async {
                // Flush decoders in case the readers gave up before EOF
                // (orphan holding the pipe) — a trailing split character
                // still yields its replacement marker. Idempotent after a
                // sink-side EOF flush.
                let s = entry.stdoutDecoder.flush()
                if !s.isEmpty {
                    entry.stdout.append(redactor.redact(s))
                    entry.stdout = redactor.redact(entry.stdout)
                }
                let e2 = entry.stderrDecoder.flush()
                if !e2.isEmpty {
                    entry.stderr.append(redactor.redact(e2))
                    entry.stderr = redactor.redact(entry.stderr)
                }
                // Close the complete-stream spill files and record their
                // final paths (finalize may mint one for a stream that
                // crossed the threshold only in its last carry flush).
                entry.stdoutSpillPath = outSink.finalizeSpill() ?? entry.stdoutSpillPath
                entry.stderrSpillPath = errSink.finalizeSpill() ?? entry.stderrSpillPath
                Task {
                    await BackgroundProcessRegistry.shared.markTerminated(id: entry.id, exitCode: exitCode, reason: reason)
                }
            }
        }

        return Handle(id: id, pid: process.processIdentifier)
    }

    // MARK: Attached jobs (internal — model-invisible)

    /// Start an attached command through the SAME registry lifecycle
    /// as background jobs (BASH_V2_PLAN §15 Phase 1): shared process
    /// construction, shared exit monitor, internal job identity. The caller
    /// keeps its own ForegroundStreamCollectors (the legacy payload is their
    /// projection, not the rolling-buffer snapshot), awaits settlement via
    /// `settlementInfo`, and removes the entry when done. Foreground stdin
    /// stays the null device; the 20ms monitor cadence preserves the old
    /// inline loop's latency for quick commands.
    func startAttached(
        command: String, workdir: String?, description: String?,
        perCommandEnv: [String: String],
        outSink: ForegroundStreamCollector, errSink: ForegroundStreamCollector
    ) throws -> (uuid: UUID, process: Process) {
        pruneSettledEntries()
        let id = "fg_\(fgCounter)"
        fgCounter += 1

        let process = try Self.buildProcess(command: command, workdir: workdir, perCommandEnv: perCommandEnv)
        let outPipe = Pipe()
        let errPipe = Pipe()
        // Never share the CLI's stdin with a child: a reading child would
        // steal keystrokes meant for the REPL (and vice versa).
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let entry = Entry(
            id: id, command: command, description: description, workdir: workdir,
            process: process, stdin: FileHandle.nullDevice, kind: .attached
        )
        let outReader = PipeStreamReader(fd: outPipe.fileHandleForReading.fileDescriptor, collector: outSink)
        let errReader = PipeStreamReader(fd: errPipe.fileHandleForReading.fileDescriptor, collector: errSink)

        do {
            try process.run()
        } catch {
            throw SpawnFailure.runFailed(error.localizedDescription)
        }
        outReader.start()
        errReader.start()
        entries[id] = entry

        let entryId = entry.id
        Self.startExitMonitor(
            process: process,
            outReader: outReader, errReader: errReader,
            outPipe: outPipe, errPipe: errPipe, stdinWriteEnd: nil,
            pollNanos: 20_000_000
        ) { exitCode, reason in
            Task {
                await BackgroundProcessRegistry.shared.markTerminated(id: entryId, exitCode: exitCode, reason: reason)
            }
        }

        return (entry.jobUUID, process)
    }

    /// Settlement state for a job by internal identity. `settled` means the
    /// full settle sequence finished (readers drained, exit code recorded) —
    /// NOT merely that a kill was requested. Unknown UUIDs report settled so
    /// a caller can never wait forever on a removed entry.
    func settlementInfo(uuid: UUID) -> (settled: Bool, exitCode: Int32?) {
        guard let e = entries.values.first(where: { $0.jobUUID == uuid }) else { return (true, nil) }
        return (e.lifecycleSettled, e.exitCode.map(Int32.init))
    }

    /// Stop a job with an explicit cause (foreground timeout, turn
    /// cancellation). Cause and killed-status are recorded BEFORE signalling
    /// so the exit monitor can never mislabel the death. The 200ms grace
    /// matches the attached terminate path.
    func stopJob(uuid: UUID, cause: TerminationCause) async {
        guard let e = entries.values.first(where: { $0.jobUUID == uuid }) else { return }
        guard e.status == .running else { return }
        e.status = .killed
        e.terminationCause = cause
        await ProcessTree.terminate(e.process, graceNanos: 200_000_000)
    }

    /// Handle-based stop for the attached initial-wait cancellation path.
    func stopJob(handleId: String, cause: TerminationCause) async {
        guard let e = entries[handleId] else { return }
        await stopJob(uuid: e.jobUUID, cause: cause)
    }

    /// Remove an internal entry once its caller has rendered the result.
    /// Attached entries produce no completion notice, so nothing
    /// else can still need them; a late markTerminated for a removed id is
    /// a harmless no-op.
    func removeEntry(uuid: UUID) {
        if let key = entries.first(where: { $0.value.jobUUID == uuid })?.key {
            entries.removeValue(forKey: key)
        }
    }

    // MARK: Inspect / mutate

    /// Count of managed background jobs still running, any owner. Used by
    /// /exportmind's non-destructive consistency barrier (Codex,
    /// 2026-08-27): a running job can write spill/attachment files while
    /// the export copies them, so the export refuses rather than kills.
    func runningBackgroundJobCount() -> Int {
        entries.values.filter { $0.kind == .background && $0.status == .running }.count
    }

    func snapshot(handleId: String, owner: String = BackgroundProcessRegistry.mainOwner) -> Snapshot? {
        guard let e = entries[handleId], e.kind == .background, e.owner == owner else { return nil }
        var out = ""
        var err = ""
        var outEvicted = 0
        var errEvicted = 0
        var outSpill: String?
        var errSpill: String?
        let sema = DispatchSemaphore(value: 0)
        ioQueue.async {
            out = e.stdout
            err = e.stderr
            outEvicted = e.stdoutEvicted
            errEvicted = e.stderrEvicted
            outSpill = e.stdoutSpillPath
            errSpill = e.stderrSpillPath
            sema.signal()
        }
        sema.wait()
        return Snapshot(
            id: e.id,
            command: e.command,
            description: e.description,
            stdout: out,
            stderr: err,
            stdoutEvicted: outEvicted,
            stderrEvicted: errEvicted,
            stdoutSpillPath: outSpill,
            stderrSpillPath: errSpill,
            status: e.status,
            exitCode: e.exitCode,
            runningFor: Date().timeIntervalSince(e.startedAt),
            workdir: e.workdir
        )
    }

    /// Atomic snapshot + acknowledgement receipt (BASH_V2_PLAN §8): both are
    /// read in one actor-isolated stretch, so the receipt can never name a
    /// settlement the snapshot payload doesn't show. A caller that fetched
    /// them separately could snapshot a still-running job, lose the actor to
    /// the settlement path, then mint a receipt for a result the model never
    /// saw — suppressing the completion notice without delivering the output.
    /// The receipt is non-nil only when the entry has fully settled AND its
    /// completion notice is still pending; running jobs, subagent-owned jobs
    /// (which never enqueue notices), and already-delivered/acknowledged
    /// completions all yield nil, exactly like `pendingReceipt`.
    func snapshotWithReceipt(
        handleId: String, owner: String = BackgroundProcessRegistry.mainOwner
    ) -> (snapshot: Snapshot, receipt: BashCompletionReceipt?)? {
        guard let snap = snapshot(handleId: handleId, owner: owner) else { return nil }
        let receipt = (entries[handleId]?.lifecycleSettled ?? false)
            ? pendingReceipt(handleId: handleId) : nil
        return (snap, receipt)
    }

    enum InputError: Error, LocalizedError {
        case handleNotFound(String)
        case processNotRunning(String)
        case invalidEncoding

        var errorDescription: String? {
            switch self {
            case .handleNotFound(let handle):
                return "unknown background handle: \(handle)"
            case .processNotRunning(let handle):
                return "background process is not running: \(handle)"
            case .invalidEncoding:
                return "failed to encode input as UTF-8"
            }
        }
    }

    func writeInput(handleId: String, text: String, appendNewline: Bool, owner: String = BackgroundProcessRegistry.mainOwner) throws -> Int {
        guard let e = entries[handleId], e.kind == .background, e.owner == owner else {
            throw InputError.handleNotFound(handleId)
        }
        guard e.status == .running, e.process.isRunning else {
            throw InputError.processNotRunning(handleId)
        }
        let payload = appendNewline ? text + "\n" : text
        guard let data = payload.data(using: .utf8) else {
            throw InputError.invalidEncoding
        }
        try e.stdin.write(contentsOf: data)
        return data.count
    }

    /// Summary projection for bash_manage(list) — BASH_V2_PLAN §5.2. One
    /// cheap row per background job: NEVER stdout/stderr content, so the
    /// response stays small even with many chatty jobs. Running entries are
    /// never pruned, so anything alive is always enumerable (the rediscovery
    /// path for a forgotten handle). Legacy-foreground internals are
    /// excluded by kind.
    struct JobSummary {
        let handle: String
        let command: String
        let description: String?
        let status: Status
        let exitCode: Int?
        let runningForSeconds: Int
        let stdoutTotalBytes: Int
        let stderrTotalBytes: Int
    }

    func listJobs(includeSettled: Bool, owner: String = BackgroundProcessRegistry.mainOwner) -> [JobSummary] {
        pruneSettledEntries()
        return entries.values
            .filter { $0.kind == .background && $0.owner == owner && (includeSettled || $0.status == .running) }
            .sorted { $0.startedAt < $1.startedAt }
            .map { e in
                var outBytes = 0
                var errBytes = 0
                let sema = DispatchSemaphore(value: 0)
                ioQueue.async {
                    outBytes = e.stdoutEvicted + e.stdout.utf8.count
                    errBytes = e.stderrEvicted + e.stderr.utf8.count
                    sema.signal()
                }
                sema.wait()
                return JobSummary(
                    handle: e.id,
                    command: e.command,
                    description: e.description,
                    status: e.status,
                    exitCode: e.exitCode,
                    runningForSeconds: Int(Date().timeIntervalSince(e.startedAt)),
                    stdoutTotalBytes: outBytes,
                    stderrTotalBytes: errBytes
                )
            }
    }

    /// Compact summary of running processes, used by the system prompt.
    func liveSummary() -> [(id: String, command: String, description: String?, runningFor: Int)] {
        entries.values
            .filter { $0.status == .running && $0.kind == .background && $0.owner == Self.mainOwner }
            .sorted { $0.startedAt < $1.startedAt }
            .map { e in
                (id: e.id,
                 command: e.command,
                 description: e.description,
                 runningFor: Int(Date().timeIntervalSince(e.startedAt)))
            }
    }

    /// Pre-formatted multi-line string summary suitable for direct injection
    /// into the system prompt. Returns `nil` when there are no running bash
    /// processes so the section can be skipped entirely.
    func liveSummaryText() -> String? {
        let rows = liveSummary()
        guard !rows.isEmpty else { return nil }
        let redactor = BashTools.SecretRedactor()
        var lines: [String] = ["Running background bash:"]
        for r in rows {
            let secs = r.runningFor
            let dur: String
            if secs < 60 {
                dur = "\(secs)s"
            } else {
                let m = secs / 60
                let s = secs % 60
                dur = "\(m)m \(s)s"
            }
            let safeCommand = redactor.redact(r.command)
            let cmd = safeCommand.count > 60
                ? String(safeCommand.prefix(60)) + "…"
                : safeCommand
            if let desc = r.description, !desc.isEmpty {
                lines.append("- \(r.id) [\"\(cmd)\", \(redactor.redact(desc)), running \(dur)]")
            } else {
                lines.append("- \(r.id) [\"\(cmd)\", running \(dur)]")
            }
        }
        return lines.joined(separator: "\n")
    }

    func kill(handleId: String, owner: String = BackgroundProcessRegistry.mainOwner) async -> Bool {
        guard let e = entries[handleId], e.kind == .background, e.owner == owner else { return false }
        guard e.status == .running else { return false }
        try? e.stdin.close()
        // Mark before signalling so the termination handler labels this .killed
        // rather than .exited/.crashed.
        e.status = .killed
        e.terminationCause = .userKill
        await ProcessTree.terminate(e.process, graceNanos: 300_000_000)
        return true
    }

    private func markTerminated(id: String, exitCode: Int32, reason: Process.TerminationReason) {
        guard let e = entries[id] else { return }
        // Don't double-deliver if already processed.
        if e.completionDelivered { return }

        // A status stamped before the kill signal (killed by user/turn,
        // timed_out by an execution deadline) is authoritative — the
        // exit-detection race must never relabel it.
        let preStamped: Status? = (e.status == .killed || e.status == .timedOut) ? e.status : nil
        let statusAfter: Status
        switch reason {
        case .exit:
            statusAfter = preStamped ?? .exited
        case .uncaughtSignal:
            statusAfter = preStamped ?? .crashed
        @unknown default:
            statusAfter = preStamped ?? .exited
        }
        e.status = statusAfter
        e.exitCode = Int(exitCode)
        e.completionDelivered = true
        e.lifecycleSettled = true
        e.settledAt = Date()
        if e.terminationCause == nil { e.terminationCause = .naturalExit }
        e.executionDeadlineTask?.cancel()
        e.executionDeadlineTask = nil

        // Attached jobs settle through the same lifecycle but are
        // model-invisible: no completion notice, no watch teardown events
        // (watches can't attach to them). Subagent-OWNED background jobs
        // likewise produce no completion notice (§10.5): their notification
        // path would be the main conversation's injection stream, which
        // must never carry another agent's events — the owning subagent
        // polls instead, and the job dies with its owner's run.
        if e.kind == .attached || e.owner != Self.mainOwner {
            resumeWaiterOnSettlement(e)
            return
        }

        let duration = Int(Date().timeIntervalSince(e.startedAt))
        let tailBytes = 4000
        let outTail: String = e.stdout.utf8.count <= tailBytes
            ? e.stdout
            : "…[earlier output truncated]\n" + String(e.stdout.suffix(tailBytes))
        let errTail: String = e.stderr.utf8.count <= tailBytes
            ? e.stderr
            : "…[earlier output truncated]\n" + String(e.stderr.suffix(tailBytes))
        let redactor = BashTools.SecretRedactor()

        pendingCompletions.append((jobUUID: e.jobUUID, messageId: e.completionMessageId, completion: Completion(
            handleId: e.id,
            command: redactor.redact(e.command),
            description: e.description.map { redactor.redact($0) },
            exitCode: exitCode,
            status: statusAfter,
            stdoutTail: redactor.redact(outTail),
            stderrTail: redactor.redact(errTail),
            stdoutFullPath: e.stdoutSpillPath,
            stderrFullPath: e.stderrSpillPath,
            durationSeconds: duration
        )))

        // Persist the settled notice into the job's crash record (if it has
        // one), so a restart before delivery still delivers the real result
        // (mid-turn early wake §3.10). Off-actor, best effort.
        if let settled = pendingCompletions.last, settled.jobUUID == e.jobUUID {
            let body = BashCompletionNotice.body(for: settled.completion)
            let jobUUID = e.jobUUID
            Task.detached { DetachedJobStore.recordSettlement(jobId: jobUUID, body: body, at: Date()) }
        }

        // Tear down any still-active watches for this handle, emitting one
        // synthetic terminal match per watch so the agent knows they were
        // auto-unsubscribed because the process exited.
        if let activeWatches = watches[id], !activeWatches.isEmpty {
            for w in activeWatches {
                appendMatchEvent(WatchMatch(
                    watchId: w.id,
                    handle: id,
                    pattern: redactor.redact(w.patternSource),
                    line: "[watch auto-unsubscribed — process exited]",
                    stream: "system",
                    matchedAt: Date(),
                    autoUnsubscribed: true,
                    unsubscribeReason: "process_exited",
                    matchesSoFar: w.matchesSoFar,
                    limit: w.limit
                ))
            }
            watches[id] = nil
        }

        // Resume a pending waiter LAST, after the completion notice exists,
        // so the settled outcome can carry its acknowledgement receipt.
        resumeWaiterOnSettlement(e)
    }

    /// Resume the entry's waiter (if any) with the definitive settled
    /// outcome, and retire its timeout task. Called only from actor-isolated
    /// settlement paths; removal-then-resume makes double resumption
    /// structurally impossible.
    private func resumeWaiterOnSettlement(_ e: Entry) {
        guard let w = e.waiter else { return }
        e.waiter = nil
        e.waiterTimeoutTask?.cancel()
        e.waiterTimeoutTask = nil
        e.waiterWakeTask?.cancel()
        e.waiterWakeTask = nil
        w.continuation.resume(returning: .settled(
            exitCode: e.exitCode.map(Int32.init),
            receipt: pendingReceipt(handleId: e.id)
        ))
    }

    // MARK: Watch API

    func registerWatch(handle: String, pattern: String, limit: Int, owner: String = BackgroundProcessRegistry.mainOwner) -> Result<String, WatchError> {
        guard let e = entries[handle], e.kind == .background, e.owner == owner else { return .failure(.handleNotFound) }
        if e.status != .running { return .failure(.processAlreadyExited) }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            return .failure(.invalidRegex(error.localizedDescription))
        }
        let clamped = max(1, min(limit, 50))
        let watchId = "watch_\(nextWatchId)"
        nextWatchId += 1
        let watch = Watch(
            id: watchId,
            regex: regex,
            patternSource: pattern,
            limit: clamped,
            matchesSoFar: 0
        )
        var arr = watches[handle] ?? []
        arr.append(watch)
        watches[handle] = arr

        // Replay output buffered before the watch existed, so lines emitted
        // between spawn and registration aren't silently missed. Buffers are
        // already redacted on ingest. Only this watch sees the replay —
        // pre-existing watches already evaluated these lines live.
        let (bufferedOut, bufferedErr) = bufferedCompleteLines(entry: e)
        if !bufferedOut.isEmpty { evaluateWatches(handleId: handle, stream: "stdout", lines: bufferedOut, only: watchId) }
        if !bufferedErr.isEmpty { evaluateWatches(handleId: handle, stream: "stderr", lines: bufferedErr, only: watchId) }
        return .success(watchId)
    }

    /// Complete (newline-terminated) lines currently sitting in a process's
    /// output buffers. Trailing partial lines are excluded — they'll be matched
    /// live once their newline arrives.
    private func bufferedCompleteLines(entry: Entry) -> (stdout: [String], stderr: [String]) {
        var out = ""
        var err = ""
        let sema = DispatchSemaphore(value: 0)
        ioQueue.async {
            out = entry.stdout
            err = entry.stderr
            sema.signal()
        }
        sema.wait()
        func completeLines(_ s: String) -> [String] {
            guard s.contains("\n") else { return [] }
            let parts = s.split(separator: "\n", omittingEmptySubsequences: false)
            return parts.dropLast().map { part in
                var line = String(part)
                if line.hasSuffix("\r") { line.removeLast() }
                return line
            }
        }
        return (completeLines(out), completeLines(err))
    }

    /// Drain buffered watch match events. Called from the ConversationManager poll loop.
    func drainWatchMatches() -> [WatchMatch] {
        let out = pendingMatchEvents
        pendingMatchEvents.removeAll(keepingCapacity: true)
        return out
    }

    /// Called from pipe-reader callbacks via `Task { await ... }` after a batch of
    /// fully-terminated lines has been extracted. Iterates every watch registered on
    /// `handleId` and regex-matches each line, capped at a 10ms per-match deadline
    /// (catastrophic-backtracking protection). Mutates watch state, appends
    /// `WatchMatch` events, and auto-unsubscribes when limits are reached or a match
    /// times out.
    func evaluateWatches(handleId: String, stream: String, lines: [String], only onlyWatchId: String? = nil) {
        guard var current = watches[handleId], !current.isEmpty else { return }
        let redactor = BashTools.SecretRedactor()
        var changed = false
        for (wIdx, w) in current.enumerated() where current.indices.contains(wIdx) {
            if let onlyWatchId, w.id != onlyWatchId { continue }
            // Snapshot for closure capture inside the timed match.
            var watchRef = w
            for line in lines {
                let matchResult = BackgroundProcessRegistry.timedRegexMatch(
                    regex: watchRef.regex, line: line, timeoutMs: 10
                )
                switch matchResult {
                case .matched:
                    watchRef.matchesSoFar += 1
                    let reachedLimit = watchRef.matchesSoFar >= watchRef.limit
                    appendMatchEvent(WatchMatch(
                        watchId: watchRef.id,
                        handle: handleId,
                        pattern: redactor.redact(watchRef.patternSource),
                        line: redactor.redact(line),
                        stream: stream,
                        matchedAt: Date(),
                        autoUnsubscribed: reachedLimit,
                        unsubscribeReason: reachedLimit ? "limit_reached" : nil,
                        matchesSoFar: watchRef.matchesSoFar,
                        limit: watchRef.limit
                    ))
                    if reachedLimit {
                        watchRef.matchesSoFar = -1  // sentinel: mark for removal
                    }
                    changed = true
                case .noMatch:
                    break
                case .timedOut:
                    print("[BackgroundProcessRegistry] watch \(watchRef.id) on \(handleId): regex timeout (>10ms) — auto-unsubscribing (ReDoS protection). pattern: \(watchRef.patternSource)")
                    appendMatchEvent(WatchMatch(
                        watchId: watchRef.id,
                        handle: handleId,
                        pattern: redactor.redact(watchRef.patternSource),
                        line: "[watch auto-unsubscribed — regex match exceeded 10ms timeout (possible catastrophic backtracking)]",
                        stream: "system",
                        matchedAt: Date(),
                        autoUnsubscribed: true,
                        unsubscribeReason: "regex_timeout",
                        matchesSoFar: watchRef.matchesSoFar,
                        limit: watchRef.limit
                    ))
                    watchRef.matchesSoFar = -1  // mark for removal
                    changed = true
                }
                if watchRef.matchesSoFar < 0 { break }  // unsubscribed — stop feeding lines
            }
            current[wIdx] = watchRef
        }
        if changed {
            // Remove watches sentineled (matchesSoFar == -1).
            current.removeAll { $0.matchesSoFar < 0 }
            if current.isEmpty {
                watches[handleId] = nil
            } else {
                watches[handleId] = current
            }
        }
    }

    // MARK: Static helpers

    /// Split the incoming chunk across any pending partial line and return all newly-complete
    /// lines (without the trailing \n). Updates `buffer` with the new trailing partial.
    static func extractCompleteLines(newChunk: String, buffer: inout String) -> [String] {
        buffer.append(newChunk)
        guard buffer.contains("\n") else { return [] }
        var out: [String] = []
        // Normalize CR-LF to LF for matching purposes without losing content.
        let parts = buffer.split(separator: "\n", omittingEmptySubsequences: false)
        // All but the last are complete lines; the last is either "" (trailing \n) or a partial.
        for i in 0..<(parts.count - 1) {
            var line = String(parts[i])
            if line.hasSuffix("\r") { line.removeLast() }
            out.append(line)
        }
        buffer = String(parts[parts.count - 1])
        return out
    }

    enum RegexMatchOutcome {
        case matched
        case noMatch
        case timedOut
    }

    /// Runs an NSRegularExpression match against `line` with a hard wall-clock budget.
    /// NSRegularExpression has no native timeout, so we run the match on a detached
    /// task and race it against a sleep. On timeout we return `.timedOut`; the match
    /// task keeps running in the background but its result is discarded.
    ///
    /// This is belt-and-braces: for the overwhelming majority of patterns match
    /// returns in microseconds; the timeout exists purely to bound a pathologically
    /// catastrophic-backtracking pattern so it can't jam the stdout reader loop.
    static func timedRegexMatch(regex: NSRegularExpression, line: String, timeoutMs: Int) -> RegexMatchOutcome {
        // Short-circuit for the common case: Swift cannot cancel an in-flight
        // NSRegularExpression call, but we can cap wall time by racing tasks.
        let sem = DispatchSemaphore(value: 0)
        var outcome: RegexMatchOutcome = .timedOut
        let work = DispatchWorkItem {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let m = regex.firstMatch(in: line, options: [], range: range)
            outcome = (m == nil) ? .noMatch : .matched
            sem.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        if sem.wait(timeout: deadline) == .timedOut {
            // Leave outcome as .timedOut. The work item keeps running; we can't
            // forcibly abort NSRegularExpression, so we just let it finish and
            // let the result signal into the (now-unread) semaphore.
            return .timedOut
        }
        return outcome
    }

    private func appendMatchEvent(_ match: WatchMatch) {
        var match = match
        match.ownerJobUUID = entries[match.handle]?.jobUUID
        pendingMatchEvents.append(match)
    }

    // MARK: Mid-turn early wake support (§3.9, §3.10)

    /// A completion awaiting durable delivery, with the stable ids that make
    /// every append id-deduplicated.
    struct PendingDelivery {
        let jobUUID: UUID
        let messageId: UUID
        let completion: Completion
    }

    /// Non-destructive read of the queued completion notices (§3.10.3): the
    /// caller appends each (id-deduplicated), saves, and only after a
    /// successful save acknowledges them with `acknowledgeDelivered`. A
    /// failed save therefore leaves every notice queued for the next idle
    /// poll instead of losing it. Also the retention heartbeat.
    func pendingCompletionsForDelivery() -> [PendingDelivery] {
        pruneSettledEntries()
        return pendingCompletions.map {
            PendingDelivery(jobUUID: $0.jobUUID, messageId: $0.messageId, completion: $0.completion)
        }
    }

    /// The rendered notice of a settled job whose completion is still queued.
    func pendingCompletionBody(jobUUID: UUID) -> String? {
        pendingCompletions.first(where: { $0.jobUUID == jobUUID }).map { BashCompletionNotice.body(for: $0.completion) }
    }

    /// Withdraw delivered notices by job identity — called only after the
    /// history save that carries their messages succeeded.
    func acknowledgeDelivered(jobUUIDs: Set<UUID>) {
        guard !jobUUIDs.isEmpty else { return }
        pendingCompletions.removeAll { jobUUIDs.contains($0.jobUUID) }
        pruneSettledEntries()
    }

    /// Identity and display facts for one main-owned job, for its crash
    /// record (§3.10.1).
    struct JobFacts {
        let jobUUID: UUID
        let handle: String
        let command: String
        let description: String?
        let workdir: String?
        let startedAt: Date
        let completionMessageId: UUID
        let settled: Bool
    }

    func jobFacts(handleId: String, owner: String = BackgroundProcessRegistry.mainOwner) -> JobFacts? {
        guard let e = entries[handleId], e.kind == .background, e.owner == owner else { return nil }
        let redactor = BashTools.SecretRedactor()
        return JobFacts(jobUUID: e.jobUUID, handle: e.id, command: redactor.redact(e.command),
                        description: e.description.map { redactor.redact($0) }, workdir: e.workdir,
                        startedAt: e.startedAt, completionMessageId: e.completionMessageId,
                        settled: e.lifecycleSettled)
    }

    /// Runs whose launches are refused (a /stop cut them off). Bounded.
    private var closedTurnRunIds: [UUID] = []

    /// /stop cutoff (§3.9.1): close launch admission for the stopped run and
    /// snapshot every unsettled main-owned item in the same actor step.
    func stopCutoff(turnRunId: UUID?) -> (jobUUIDs: Set<UUID>, watchMatchIds: [UUID]) {
        if let turnRunId, !closedTurnRunIds.contains(turnRunId) {
            closedTurnRunIds.append(turnRunId)
            if closedTurnRunIds.count > 64 { closedTurnRunIds.removeFirst() }
        }
        return unsettledMainOwnedItems()
    }

    /// Every main-owned item a /stop affects (§3.9.1): running jobs, jobs
    /// whose completion is still queued, and owner jobs of pending watch
    /// matches — plus the ids of those pending matches.
    func unsettledMainOwnedItems() -> (jobUUIDs: Set<UUID>, watchMatchIds: [UUID]) {
        var jobs = Set(entries.values.filter {
            $0.kind == .background && $0.owner == Self.mainOwner && $0.status == .running
        }.map(\.jobUUID))
        jobs.formUnion(pendingCompletions.map(\.jobUUID))
        for match in pendingMatchEvents { if let owner = match.ownerJobUUID { jobs.insert(owner) } }
        return (jobs, pendingMatchEvents.map(\.matchId))
    }

    struct StoppedJob {
        let jobUUID: UUID
        let handle: String
        let command: String
        let runningForSeconds: Int
    }

    /// /stop (owner decision B/B1): terminate EVERY running main-owned
    /// background job, including long-lived ones started turns ago with
    /// wait_seconds=0, and tear down their watches (the exit path emits the
    /// terminal watch events, which the manager appends without waking).
    /// Cause and killed status are stamped BEFORE signalling.
    func stopAllMainOwned() async -> [StoppedJob] {
        let running = entries.values.filter {
            $0.kind == .background && $0.owner == Self.mainOwner && $0.status == .running
        }
        let redactor = BashTools.SecretRedactor()
        var stopped: [StoppedJob] = []
        for e in running {
            e.status = .killed
            e.terminationCause = .userKill
            try? e.stdin.close()
            stopped.append(StoppedJob(jobUUID: e.jobUUID, handle: e.id, command: redactor.redact(e.command),
                                      runningForSeconds: Int(Date().timeIntervalSince(e.startedAt))))
        }
        for e in running { await ProcessTree.terminate(e.process, graceNanos: 300_000_000) }
        return stopped
    }

    /// Main-owned running jobs, for /status and the wake note.
    struct RunningJob {
        let jobUUID: UUID
        let handle: String
        let command: String
        let description: String?
        let workdir: String?
        let runningForSeconds: Int
    }

    func runningMainOwnedJobs() -> [RunningJob] {
        let redactor = BashTools.SecretRedactor()
        return entries.values
            .filter { $0.kind == .background && $0.owner == Self.mainOwner && $0.status == .running }
            .sorted { $0.startedAt < $1.startedAt }
            .map { RunningJob(jobUUID: $0.jobUUID, handle: $0.id, command: redactor.redact($0.command),
                              description: $0.description.map { redactor.redact($0) }, workdir: $0.workdir,
                              runningForSeconds: Int(Date().timeIntervalSince($0.startedAt))) }
    }

    /// Called by the ConversationManager poll loop. Returns and clears pending completions.
    func drainCompletions() -> [Completion] {
        // Called every poll cycle — the periodic heartbeat that lets the
        // hour-based retention (§13) fire even on an otherwise idle registry.
        pruneSettledEntries()
        let out = pendingCompletions.map(\.completion)
        pendingCompletions.removeAll(keepingCapacity: true)
        return out
    }

    // MARK: Completion acknowledgement (BASH_V2_PLAN §8)

    /// The acknowledgement token for a settled job whose completion notice
    /// is still pending, or nil when there is nothing to acknowledge (job
    /// running, unknown, internal, or already delivered/acknowledged).
    /// Phase 3's wait mode attaches this to the tool result that observed
    /// the settlement.
    func pendingReceipt(handleId: String) -> BashCompletionReceipt? {
        guard let e = entries[handleId], e.kind == .background else { return nil }
        guard pendingCompletions.contains(where: { $0.jobUUID == e.jobUUID }) else { return nil }
        return BashCompletionReceipt(jobUUID: e.jobUUID, publicHandle: e.id)
    }

    // MARK: Bounded waits (BASH_V2_PLAN §11)

    /// Wait until `handleId` settles or `timeoutNanos` elapses, without
    /// busy polling: the waiter is a continuation resumed exactly once by
    /// an actor-serialized state transition (settlement, timeout, or
    /// cancellation). Wait expiry NEVER kills the job. At most one waiter
    /// per handle; a duplicate is refused immediately. An already-settled
    /// handle returns at once, carrying the acknowledgement receipt if its
    /// completion notice is still pending.
    func awaitSettlement(handleId: String, timeoutNanos: UInt64, owner: String = BackgroundProcessRegistry.mainOwner,
                         wake: WakeContext? = nil) async -> WaitOutcome {
        // Fast-path guards only. `await withTaskCancellationHandler` is a
        // suspension point, so another caller CAN interleave between these
        // checks and the registration closure — every guard is re-checked
        // there, atomically with assigning the waiter slot. Without the
        // re-check, two concurrent callers could both pass `waiter == nil`
        // and the second registration would overwrite (and leak) the first
        // continuation.
        guard let quick = entries[handleId], quick.kind == .background, quick.owner == owner else { return .unknownHandle }
        if quick.lifecycleSettled {
            return .settled(exitCode: quick.exitCode.map(Int32.init),
                            receipt: pendingReceipt(handleId: handleId))
        }
        if Task.isCancelled { return .cancelled }
        if quick.waiter != nil { return .refusedDuplicate }

        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<WaitOutcome, Never>) in
                // Runs synchronously in the actor's isolation: this is the
                // authoritative, race-free evaluation of every guard. The
                // slot is assigned in the same synchronous stretch, so a
                // concurrent caller re-entering here observes it and takes
                // the refusedDuplicate branch instead of overwriting.
                guard let e = self.entries[handleId], e.kind == .background, e.owner == owner else {
                    cont.resume(returning: .unknownHandle)
                    return
                }
                if e.lifecycleSettled {
                    cont.resume(returning: .settled(
                        exitCode: e.exitCode.map(Int32.init),
                        receipt: self.pendingReceipt(handleId: handleId)))
                    return
                }
                if Task.isCancelled {
                    cont.resume(returning: .cancelled)
                    return
                }
                if e.waiter != nil {
                    cont.resume(returning: .refusedDuplicate)
                    return
                }
                e.waiter = (id: waiterId, continuation: cont)
                e.waiterTimeoutTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutNanos)
                    if Task.isCancelled { return }
                    await BackgroundProcessRegistry.shared.waiterTimeoutFired(handleId: handleId, waiterId: waiterId)
                }
                // Mid-turn early wake (§3.4): only a main-owned wait inside a
                // depth-0 call scope listens. The wake resolves through the
                // same actor-serialized waiter slot as every other outcome.
                if let wake, owner == Self.mainOwner {
                    e.waiterWakeTask = Task {
                        guard let reason = await MidturnWakeSignal.next(wake) else { return }
                        if Task.isCancelled { return }
                        await BackgroundProcessRegistry.shared.wakeFired(handleId: handleId, waiterId: waiterId, reason: reason)
                    }
                }
            }
        } onCancel: {
            Task { await BackgroundProcessRegistry.shared.cancelWaiter(handleId: handleId, waiterId: waiterId) }
        }
    }

    /// Wake branch (mid-turn early wake §3.4). Rechecks settlement inside the
    /// actor exactly like the timeout branch: at the settlement boundary the
    /// only valid outcomes are a terminal result (with receipt) or a woken
    /// running job — never "woken" after settlement was recorded.
    private func wakeFired(handleId: String, waiterId: UUID, reason: MidturnWakeReason) {
        guard let e = entries[handleId], let w = e.waiter, w.id == waiterId else { return }
        e.waiter = nil
        e.waiterTimeoutTask?.cancel()
        e.waiterTimeoutTask = nil
        e.waiterWakeTask = nil
        if e.lifecycleSettled {
            w.continuation.resume(returning: .settled(
                exitCode: e.exitCode.map(Int32.init),
                receipt: pendingReceipt(handleId: handleId)))
        } else {
            BashJobsStats.log("wait.woken")
            w.continuation.resume(returning: .woken(reason))
        }
    }

    /// Timeout branch. Rechecks settlement inside the actor: at the exact
    /// settlement boundary the only valid outcomes are a terminal result
    /// (with receipt) or a running timeout with no receipt — never a
    /// running timeout after settlement was recorded (BASH_V2_PLAN §11).
    private func waiterTimeoutFired(handleId: String, waiterId: UUID) {
        guard let e = entries[handleId], let w = e.waiter, w.id == waiterId else { return }
        e.waiter = nil
        e.waiterTimeoutTask = nil
        e.waiterWakeTask?.cancel()
        e.waiterWakeTask = nil
        if e.lifecycleSettled {
            w.continuation.resume(returning: .settled(
                exitCode: e.exitCode.map(Int32.init),
                receipt: pendingReceipt(handleId: handleId)))
        } else {
            w.continuation.resume(returning: .waitTimedOut)
        }
    }

    /// Cancellation branch: stop waiting, keep the job running, leave its
    /// eventual completion notice pending (BASH_V2_PLAN §10.2).
    private func cancelWaiter(handleId: String, waiterId: UUID) {
        guard let e = entries[handleId], let w = e.waiter, w.id == waiterId else { return }
        e.waiter = nil
        e.waiterTimeoutTask?.cancel()
        e.waiterTimeoutTask = nil
        e.waiterWakeTask?.cancel()
        e.waiterWakeTask = nil
        w.continuation.resume(returning: .cancelled)
    }

    // MARK: Execution deadlines (BASH_V2_PLAN §10.4)

    /// Arm a kill_after_seconds deadline on a running job. Belongs to the
    /// registry entry — it stays active after the launching turn ends and
    /// terminates the COMPLETE process tree when reached. Cancelled
    /// automatically at settlement.
    func armExecutionDeadline(handleId: String, afterNanos: UInt64) {
        guard let e = entries[handleId], e.kind == .background, e.status == .running else { return }
        e.executionDeadlineTask?.cancel()
        e.executionDeadlineTask = Task {
            try? await Task.sleep(nanoseconds: afterNanos)
            if Task.isCancelled { return }
            await BackgroundProcessRegistry.shared.executionDeadlineFired(handleId: handleId)
        }
    }

    /// Deadline reached: record cause and timed_out status BEFORE signalling
    /// so the exit monitor can never mislabel the death as a crash or user
    /// kill, then terminate the process tree.
    private func executionDeadlineFired(handleId: String) async {
        guard let e = entries[handleId], e.status == .running else { return }
        e.status = .timedOut
        e.terminationCause = .executionDeadline
        try? e.stdin.close()
        await ProcessTree.terminate(e.process, graceNanos: 300_000_000)
    }

    /// Withdraw the pending completion notices named by `receipts`. Called
    /// by ConversationManager ONLY after the turn that observed those
    /// settlements was durably saved — never at observation time, so a
    /// cancelled or failed turn leaves the notice pending and the normal
    /// injection recovers it (at-least-once delivery; a rare duplicate is
    /// safer than a silent loss). Idempotent; keyed strictly by jobUUID, so
    /// stale receipts for a recreated handle are no-ops.
    func acknowledgeCompletions(_ receipts: [BashCompletionReceipt]) {
        guard !receipts.isEmpty else { return }
        let uuids = Set(receipts.map(\.jobUUID))
        let before = pendingCompletions.count
        pendingCompletions.removeAll { uuids.contains($0.jobUUID) }
        let removed = before - pendingCompletions.count
        if removed > 0 { BashJobsStats.log("completions.acknowledged", by: removed) }
        // The acknowledged jobs just lost their never-prune completion hold.
        pruneSettledEntries()
    }

    /// Terminate a finished subagent's still-running background jobs
    /// (§10.5): owned jobs never outlive their owner — after the run ends
    /// nobody could see, manage, or be notified about them. Settled entries
    /// are left for the retention sweep (they hold no completion notices).
    func terminateOwned(owner: String) async {
        guard owner != Self.mainOwner else { return }
        let running = entries.values.filter {
            $0.kind == .background && $0.owner == owner && $0.status == .running
        }
        for e in running {
            e.status = .killed
            e.terminationCause = .ownerFinished
            try? e.stdin.close()
            await ProcessTree.terminate(e.process, graceNanos: 300_000_000)
        }
    }

    /// Terminate all background processes and their descendants. Called from
    /// applicationWillTerminate so background zsh children don't outlive the app.
    func terminateAll() async {
        let running = entries.values.filter { $0.status == .running }
        guard !running.isEmpty else { return }
        // Collect descendants before signalling — orphans reparent to launchd.
        let trees = running.map { entry -> (entry: Entry, descendants: [Int32], groups: [Int32]) in
            let kids = ProcessTree.descendants(of: entry.process.processIdentifier)
            let groups = ProcessTree.processGroups(rootPid: entry.process.processIdentifier, descendants: kids)
            return (entry, kids, groups)
        }
        for t in trees {
            t.entry.status = .killed
            t.entry.terminationCause = .appShutdown
            if t.entry.process.isRunning { t.entry.process.terminate() }
            for g in t.groups { _ = Darwin.kill(-g, SIGTERM) }
            for pid in t.descendants { _ = Darwin.kill(pid, SIGTERM) }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        for t in trees {
            if t.entry.process.isRunning { _ = Darwin.kill(t.entry.process.processIdentifier, SIGKILL) }
            for g in t.groups where Darwin.kill(-g, 0) == 0 { _ = Darwin.kill(-g, SIGKILL) }
            for pid in t.descendants where Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    /// `/deleteuserdata` support: terminate every process, then drop ALL
    /// registry state so nothing can repopulate a wiped conversation
    /// afterward — entries (their spill files deleted from disk), queued
    /// completion notices, watches and match events, tombstones. Any
    /// still-registered waiter is resumed before its entry is dropped so a
    /// caller can't hang (in practice the wipe's idle guard means none
    /// exist). Late exit monitors of killed processes no-op through the
    /// `markTerminated` entries[id] guard. Returns the number of jobs that
    /// were still running, for the honest wipe report.
    func purgeAllForWipe() async -> Int {
        let runningCount = entries.values.filter { $0.status == .running }.count
        await terminateAll()
        for e in entries.values {
            e.executionDeadlineTask?.cancel()
            e.executionDeadlineTask = nil
            try? e.stdin.close()
            resumeWaiterOnSettlement(e)
            for path in [e.stdoutSpillPath, e.stderrSpillPath] {
                if let path { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        entries.removeAll()
        pendingCompletions.removeAll()
        watches.removeAll()
        pendingMatchEvents.removeAll()
        tombstones.removeAll()
        return runningCount
    }
}

// MARK: - String utility

private extension String {
    /// Return a suffix starting at the given UTF-8 byte offset. Returns "" if offset is beyond end.
    func suffixFromByte(_ offset: Int) -> String {
        let bytes = Array(self.utf8)
        guard offset >= 0, offset < bytes.count else { return "" }
        return String(bytes: bytes[offset..<bytes.count], encoding: .utf8) ?? ""
    }
}
