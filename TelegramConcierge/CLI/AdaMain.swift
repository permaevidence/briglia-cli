import ArgumentParser
import Foundation

let adaCLIVersion = "0.1.0-dev"

@main
struct AdaCLI: AsyncParsableCommand {
    /// Line-buffer stdout even when piped, so progress is visible in real
    /// time under `tee`, log redirection, and scripted runs.
    ///
    /// Also ignores SIGPIPE, like every long-running network process must:
    /// a write to a stale keep-alive connection (Telegram, OpenAI, a local
    /// mock) otherwise KILLS the process silently — observed live as CI's
    /// "process died early (poll=-13)" and as poll loops going dead on
    /// Linux, where the networking stack doesn't always suppress it the way
    /// Darwin's SO_NOSIGPIPE does. Ignored, broken pipes surface as ordinary
    /// EPIPE errors through the normal throwing paths.
    static func prepareIO() {
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
    }

    static let configuration = CommandConfiguration(
        commandName: "briglia",
        abstract: "Briglia — your personal AI agent, in the terminal.",
        version: adaCLIVersion,
        subcommands: [CacheStatsCommand.self, SubscriptionCommand.self, Chat.self, Setup.self, QuickSetup.self, SetupAPI.self, Daemon.self, Doctor.self, Upgrade.self,
                      AdaService.self, Trigger.self, MediaSelftest.self, BundleCheck.self,
                      ToolchainCommand.self, ToolchainPrefixSelftest.self,
                      SetsidExec.self, GateExec.self, TTYHandoffSelftest.self, GateTTYSelftest.self, BashPipelineSelftest.self,
                      BashGoldenSelftest.self, BashJobsSelftest.self,
                      TriggerSelftest.self, WatcherTriageSelftest.self, LaneSelftest.self,
                      AffinitySelftest.self, ChatWireSelftest.self, ChatAdapterSelftest.self, ChatRetrySelftest.self, ResponsesSelftest.self, ResponsesCacheSelftest.self, SubscriptionSelftest.self,
                      WebAgentSelftest.self, ProviderSelftest.self, ServiceSelftest.self,
                      FsToolsSelftest.self, DeleteUserDataSelftest.self,
                      MidturnAnnotationSelftest.self, MCPSurfaceSelftest.self, StorageSelftest.self,
                      PlaywrightSelftest.self,
                      SecretStoreSelftest.self, ReleaseSigningSelftest.self,
                      VerifyEnvelopeCommand.self, TestSignEnvelopeCommand.self,
                      MindSelftest.self, SetupAPISelftest.self,
                      MigrationRunCommand.self, MigrationSelftest.self,
                      Migrate.self, MigrateProbe.self, MigrateGate.self,
                      AppChatSocketSelftest.self,
                      CommandMenuSelftest.self, BotSwitchSelftest.self,
                      EmailCalendarSelftest.self, AgentMailKeyCommand.self, AgentMailCommand.self,
                      WebLiveTest.self, QuickSetupSelftest.self],
        defaultSubcommand: Chat.self
    )
}

/// Child pid of the __setsid-exec posix_spawn fallback, for signal
/// forwarding (a C signal handler cannot capture context).
private nonisolated(unsafe) var setsidExecChildPid: pid_t = 0
private func forwardSignalToSetsidChild(_ signum: Int32) {
    // Async-signal-safe only: kill(2). The child is a session+group leader
    // (POSIX_SPAWN_SETSID), so signal its whole GROUP — forwarding to the
    // bare pid would reach the shell but miss grandchildren it spawned.
    // Fall back to the pid if the group signal fails.
    if setsidExecChildPid > 0 {
        if kill(-setsidExecChildPid, signum) != 0 {
            kill(setsidExecChildPid, signum)
        }
    }
}

/// Hidden internal trampoline: detach from the controlling terminal, then
/// exec the given program in place (same PID — Process bookkeeping, timeouts,
/// and pgrep-based tree kills in the parent keep working).
///
/// BashTools routes every model-driven shell command through this. Without
/// it, a child that prompts on /dev/tty (sudo — observed live when the Browse
/// subagent ran Playwright's Chrome installer — ssh, security(1)) writes
/// `Password:` into Briglia's own terminal and blocks the turn forever, invisible
/// to a Telegram-driven session. Worse, typed input then races byte-by-byte
/// between the prompting child and Briglia's REPL reader. Detached, such tools
/// fail fast with "no tty" and the failure surfaces to the model as ordinary
/// command output.
struct SetsidExec: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__setsid-exec",
        abstract: "Internal: exec a program detached from the controlling terminal.",
        shouldDisplay: false
    )

    /// Quick-setup start gate (SetupJobRunner): with both fds given, the
    /// FINAL session leader reports `READY <pid> <pgid> <sid>` on
    /// `readyFd`, then blocks until one RELEASE byte arrives on
    /// `releaseFd`; EOF or any other byte exits 125 without executing.
    @Option(name: .customLong("ready-fd")) var readyFd: Int32?
    @Option(name: .customLong("release-fd")) var releaseFd: Int32?

    @Argument(parsing: .remaining)
    var argv: [String] = []

    /// Optional side channel for the parent: the pid of the DETACHED session
    /// leader, i.e. the group to kill to reach the real process tree. In the
    /// exec-in-place path that is this process; in the posix_spawn fallback
    /// it is the spawned child — whose own-session group the parent could
    /// otherwise never learn (killing the tracked pid's group only reaches
    /// this shim). Used by UserdataToolchain's timeout enforcement.
    private func reportDetachedLeader(_ pid: pid_t) {
        guard let path = ProcessInfo.processInfo.environment["BRIGLIA_SETSID_PGID_FILE"],
              !path.isEmpty else { return }
        try? "\(pid)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    func run() throws {
        guard let exe = argv.first, exe.hasPrefix("/") else {
            FileHandle.standardError.write(Data(
                "briglia __setsid-exec: usage: briglia __setsid-exec -- /abs/path arg...\n".utf8))
            throw ExitCode(64)
        }
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)

        // Optional file-creation mask for the target (and everything it
        // spawns): children that write under Briglia's storage roots — the
        // WhatsApp bridge and its npm install — run with 077 so their files
        // are owner-only from creation. The variable is consumed here and
        // not passed on. Malformed values are ignored (umask unchanged).
        if let raw = ProcessInfo.processInfo.environment["BRIGLIA_CHILD_UMASK"] {
            if let value = mode_t(raw, radix: 8), value <= 0o777 { umask(value) }
            unsetenv("BRIGLIA_CHILD_UMASK")
        }

        // Start a new session, dropping the controlling terminal. The happy
        // path execs in place, so the PID the parent tracks IS the target.
        if setsid() != -1 {
            reportDetachedLeader(getpid())
            if let readyFd, let releaseFd {
                StartGate.awaitRelease(readyFd: readyFd, releaseFd: releaseFd)
            }
            execv(exe, cargs)
            FileHandle.standardError.write(Data(
                "briglia __setsid-exec: exec \(exe) failed: \(String(cString: strerror(errno)))\n".utf8))
            Foundation.exit(127)
        }

        // setsid() fails (EPERM) when this process is already a process-group
        // leader — some spawn paths make it one. Re-spawn the target with
        // POSIX_SPAWN_SETSID (detaches in the child, where it can't fail for
        // that reason) and mirror its exit status. Tree kills in Briglia walk
        // pgrep -P descendants, so the extra hop stays killable.
        //
        // Gate mode: the re-spawned process must be the one doing the
        // READY/RELEASE handshake, so the identity the parent journals is
        // the FINAL leader's, not this shim's — re-spawn ourselves as
        // `__gate-exec` (same handshake, no setsid of its own; the SETSID
        // spawn flag makes it the leader) with the gate fds inherited.
        var spawnArgv = argv
        if let readyFd, let releaseFd {
            let selfPath = (Bundle.main.executableURL
                ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
            spawnArgv = [selfPath, "__gate-exec", "--ready-fd", "\(readyFd)",
                         "--release-fd", "\(releaseFd)", "--"] + argv
            for ptr in cargs { free(ptr) }
            cargs = spawnArgv.map { strdup($0) }
            cargs.append(nil)
        }
        let spawnExe = spawnArgv[0]
        #if os(Linux)
        let setsidFlag: Int16 = 0x80          // glibc spawn.h, glibc >= 2.26
        var attr = posix_spawnattr_t()
        #else
        let setsidFlag: Int16 = 0x0400        // sys/spawn.h POSIX_SPAWN_SETSID
        var attr: posix_spawnattr_t? = nil
        #endif
        posix_spawnattr_init(&attr)
        // SETSIGDEF + empty SETSIGMASK: give the child clean signal state.
        // Raw posix_spawn otherwise inherits ignored dispositions — a child
        // that inherits SIGTERM=SIG_IGN can never be terminated by the
        // registry shutdowns that this shim forwards signals for. (Foundation
        // Process resets dispositions the same way when it spawns.)
        var defaultSigs = sigset_t()
        sigfillset(&defaultSigs)
        posix_spawnattr_setsigdefault(&attr, &defaultSigs)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        posix_spawnattr_setflags(
            &attr, setsidFlag | Int16(POSIX_SPAWN_SETSIGDEF) | Int16(POSIX_SPAWN_SETSIGMASK))
        let envStrings = ProcessInfo.processInfo.environment
            .filter { $0.key != "BRIGLIA_CHILD_UMASK" }
            .map { "\($0.key)=\($0.value)" }
        var cenv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        cenv.append(nil)
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, spawnExe, nil, &attr, cargs, cenv)
        posix_spawnattr_destroy(&attr)
        guard rc == 0 else {
            FileHandle.standardError.write(Data(
                "briglia __setsid-exec: spawn \(spawnExe) failed: \(String(cString: strerror(rc)))\n".utf8))
            Foundation.exit(127)
        }
        // The gate fds now belong to the re-spawned leader; drop our copies
        // so the parent's EOF-on-release semantics see one reader only.
        if let readyFd, let releaseFd {
            close(readyFd)
            close(releaseFd)
        }
        // Forward termination signals to the detached child: a parent that
        // kills this shim (MCP/LSP registry shutdown, Process.terminate)
        // must reach the real server, or it would leak as an orphan in its
        // own session. kill(2) is async-signal-safe.
        setsidExecChildPid = pid
        reportDetachedLeader(pid)
        signal(SIGTERM, forwardSignalToSetsidChild)
        signal(SIGINT, forwardSignalToSetsidChild)
        signal(SIGHUP, forwardSignalToSetsidChild)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signum = status & 0x7f
        if signum != 0 {
            signal(signum, SIG_DFL)
            raise(signum)
            Foundation.exit(128 + signum)
        }
        Foundation.exit((status >> 8) & 0xff)
    }
}

/// The child side of the quick-setup start gate (SetupJobRunner, plan §5.6).
/// Shared by `__setsid-exec` (detached jobs) and `__gate-exec` (terminal
/// handoff jobs). Contract:
///   child:  "READY <pid> <pgid> <sid>\n" on readyFd, then close it;
///           block on exactly one byte from releaseFd;
///           0x01 → return (caller execs); EOF, any other byte, read error
///           → exit 125 WITHOUT executing.
/// The parent holds the only write end of the release pipe, close-on-exec,
/// so parent death before RELEASE is EOF here.
enum StartGate {
    static let releaseByte: UInt8 = 0x01
    static let refusedExitCode: Int32 = 125

    static func awaitRelease(readyFd: Int32, releaseFd: Int32) {
        let line = "READY \(getpid()) \(getpgrp()) \(getsid(0))\n"
        var ok = line.withCString { ptr -> Bool in
            var offset = 0
            let total = strlen(ptr)
            while offset < total {
                let n = write(readyFd, ptr + offset, total - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        close(readyFd)
        guard ok else { Foundation.exit(refusedExitCode) }
        var byte: UInt8 = 0
        while true {
            let n = read(releaseFd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            ok = n == 1 && byte == releaseByte
            break
        }
        close(releaseFd)
        guard ok else { Foundation.exit(refusedExitCode) }
    }
}

/// Hidden trampoline for quick-setup TERMINAL jobs (sudo): the same
/// READY/RELEASE handshake as `__setsid-exec` in gate mode, but WITHOUT a
/// new session — the parent spawns it as its own process-group leader
/// (pgid == pid) inside the terminal's session, journals its identity,
/// lends it the terminal foreground (tcsetpgrp) and only then releases it,
/// so a `sudo` that execs never reads the tty as a background job (the
/// SIGTTIN freeze TerminalHandoff exists for).
struct GateExec: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__gate-exec",
        abstract: "Internal: exec a program after the quick-setup start gate (no setsid).",
        shouldDisplay: false
    )

    @Option(name: .customLong("ready-fd")) var readyFd: Int32
    @Option(name: .customLong("release-fd")) var releaseFd: Int32

    @Argument(parsing: .remaining)
    var argv: [String] = []

    func run() throws {
        guard let exe = argv.first, exe.hasPrefix("/") else {
            FileHandle.standardError.write(Data(
                "briglia __gate-exec: usage: briglia __gate-exec --ready-fd N --release-fd M -- /abs/path arg...\n".utf8))
            throw ExitCode(64)
        }
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        StartGate.awaitRelease(readyFd: readyFd, releaseFd: releaseFd)
        execv(exe, cargs)
        FileHandle.standardError.write(Data(
            "briglia __gate-exec: exec \(exe) failed: \(String(cString: strerror(errno)))\n".utf8))
        Foundation.exit(127)
    }
}

/// Hidden regression probe for TerminalHandoff (driven by the smoke suite
/// under a real pty): spawns a child that must READ the controlling
/// terminal. Foundation puts the child in a background process group, so
/// without the foreground handoff its read is SIGTTIN-stopped forever —
/// the frozen `sudo apt-get` setup bug (2026-08-06). With the handoff the
/// read succeeds, the child echoes the line back, and this exits 0.
struct TTYHandoffSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__tty-handoff-selftest",
        abstract: "Internal: verify TerminalHandoff lends the terminal to a prompting child.",
        shouldDisplay: false
    )

    func run() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "read line && printf 'HANDOFF_GOT:%s\\n' \"$line\""]
        try TerminalHandoff.runLendingForeground(child)
        Foundation.exit(child.terminationStatus)
    }
}

/// Hidden regression probe for the quick-setup terminal lend (driven by the
/// smoke suite under a real pty): runs a HANDOFF job through SetupJobRunner
/// whose command reads stdin immediately on exec. With the lend the child
/// owns the foreground before RELEASE, reads the line the harness writes,
/// and this exits 0; with `--skip-lend` the child is SIGTTIN-stopped (the
/// harness observes the timeout); with `--fail-lend` an injected tcsetpgrp
/// failure must close the release pipe unwritten (child exits 125) and
/// restore the foreground group.
struct GateTTYSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__gate-tty-selftest",
        abstract: "Internal: verify the quick-setup terminal lend under a pty.",
        shouldDisplay: false
    )

    @Flag(name: .customLong("skip-lend")) var skipLend = false
    @Flag(name: .customLong("fail-lend")) var failLend = false

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("briglia-gate-tty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        SetupJobRunner.journalURLOverride = tempRoot.appendingPathComponent("journal.json")
        SetupJobRunner.skipLendForTest = skipLend
        if failLend {
            TerminalHandoff.ForegroundLend.tcsetpgrpImpl = { _, _ in errno = EPERM; return -1 }
        }
        let runner = SetupJobRunner()
        runner.onLine = { print("JOB: \($0)") }
        let listener = CountingListener()
        runner.listener = listener
        let result = await runner.run(.init(row: "tty", command: ["/bin/sh", "-c", "read line && printf 'GATE_GOT:%s\\n' \"$line\""],
                                            mode: .terminalHandoff, timeout: 20, label: "read stdin"))
        let foregroundRestored = tcgetpgrp(STDIN_FILENO) == getpgrp()
        print("RESULT: \(result.outcome) listener=\(listener.suspends)/\(listener.resumes) fg_restored=\(foregroundRestored)")
        if failLend {
            guard case .failedToStart(let why) = result.outcome, why.contains("terminal handoff failed"), foregroundRestored,
                  listener.suspends == 1, listener.resumes == 1 else { throw ExitCode(2) }
            return
        }
        guard result.ok, foregroundRestored, listener.suspends == 1, listener.resumes == 1 else { throw ExitCode(1) }
    }

    final class CountingListener: StdinListenerControl, @unchecked Sendable {
        var suspends = 0
        var resumes = 0
        func suspend() { suspends += 1 }
        func resume() { resumes += 1 }
    }
}

/// Hidden credential broker for the `agentmail` wrapper script: prints Briglia's
/// stored AgentMail API key so the wrapper can hand it ONLY to the real
/// AgentMail binary at exec time — no ambient env injection into other bash
/// subprocesses (Codex, 2026-08-22: a shell-string heuristic is not a
/// credential boundary). Any same-user process could equally read
/// ~/.config/briglia/secrets.json (0600), so this exposes nothing new. The
/// AgentMail key is deliberately visible to the agent (CredentialCatalog:
/// only the Telegram bot token and the service keys are redacted from tool
/// output — owner decision, 2026-09-02).
struct AgentMailKeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__agentmail-key",
        abstract: "Internal: print the stored AgentMail API key (used by the agentmail wrapper).",
        shouldDisplay: false
    )

    func run() throws {
        guard let key = KeychainHelper.load(key: KeychainHelper.agentMailApiKeyKey), !key.isEmpty else {
            FileHandle.standardError.write(Data("no AgentMail API key stored — run `briglia setup` (email step)\n".utf8))
            throw ExitCode(1)
        }
        print(key)
    }
}

/// Hidden: settle an interrupted AgentMail install transaction
/// (`briglia agentmail repair`). Takes the installer lock, validates the
/// metadata, inspects the live wrapper, and either completes, rolls back,
/// or refuses with instructions. Doctor only reports; this is the one
/// explicit mutation path besides quick setup's preflight.
struct AgentMailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentmail",
        abstract: "AgentMail CLI maintenance (repair an interrupted install, upgrade to the pinned version).",
        shouldDisplay: false
    )

    @Argument var action: String

    func run() async throws {
        AdaCLI.prepareIO()
        switch action {
        case "repair":
            switch await AgentMailService.repairTransaction() {
            case .nothingToDo: print("✔ no interrupted AgentMail transaction")
            case .settled(let how): print("✔ settled: \(how)")
            case .busy: print("✖ an AgentMail installation or repair is in progress — retry later"); throw ExitCode(1)
            case .failedClosed(let why): print("✖ \(why)"); throw ExitCode(1)
            }
        case "upgrade", "install":
            // Setup paths skip an already-installed broker; this is the one
            // explicit way to move a device to the pinned upstream version
            // (e.g. 0.7.x → 1.x). Same transactional installer, same lock.
            let installed = AgentMailService.installedCLIVersion()
            print("installed: \(installed.map { "agentmail CLI \($0)" } ?? "none")")
            print("pinned:    agentmail CLI \(AgentMailService.pinnedVersion)")
            if installed == AgentMailService.pinnedVersion {
                print("✔ already at the pinned version")
                return
            }
            if let failure = await AgentMailService.installAgentMailBinary(progress: { print("  \($0)") }) {
                print("✖ \(failure)")
                throw ExitCode(1)
            }
            print("✔ agentmail CLI \(AgentMailService.pinnedVersion) installed — wrapper at \(AgentMailService.wrapperURL.path)")
        default:
            print("usage: briglia agentmail repair | upgrade")
            throw ExitCode(64)
        }
    }
}

/// Hidden installer smoke test: verify the SwiftPM resource bundle
/// (briglia-cli_briglia.bundle — bundled skills, WhatsApp bridge, toolchain scripts)
/// is deployed next to this executable. `--version` alone cannot catch a
/// missing bundle, and Bundle.module TRAPS (SIGTRAP, exit 133) on first
/// resource access — so this probes for the bundle manually before touching
/// Bundle.module, and exits with a readable error instead of a crash.
struct BundleCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-check",
        abstract: "Verify the resource bundle is installed next to the briglia binary.",
        shouldDisplay: false
    )

    /// SwiftPM's resource artifact is named per platform: a `.bundle` on
    /// Darwin, a `.resources` directory on Linux.
    static let bundleName: String = {
        #if os(Linux)
        "briglia-cli_briglia.resources"
        #else
        "briglia-cli_briglia.bundle"
        #endif
    }()

    func run() throws {
        // argv[0] can be a bare "briglia" resolved via PATH; Bundle.main knows the
        // real executable path on both macOS and Linux (/proc/self/exe).
        let executable = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let bundleURL = executable.deletingLastPathComponent()
            .appendingPathComponent(Self.bundleName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            print("""
            ✖ resource bundle missing: \(bundleURL.path)
              The installer must copy \(Self.bundleName) next to the briglia binary
              (scripts/install.sh does this). Without it, skills and the
              WhatsApp bridge are unavailable and Briglia crashes on first use.
            """)
            throw ExitCode(1)
        }
        // Safe now — the bundle exists, so Bundle.module resolves.
        guard let resourceURL = Bundle.module.resourceURL,
              FileManager.default.fileExists(
                  atPath: resourceURL.appendingPathComponent("BundledSkills").path) else {
            print("✖ resource bundle found but BundledSkills is missing — corrupted install?")
            throw ExitCode(1)
        }
        // Release C: the pinned Playwright manifests ship in the bundle; a
        // bundle without them (or with a lockfile that fails the sanity
        // rules) would make every start fall back to "install failed".
        let manifests: ManagedPlaywright.Manifests
        do {
            manifests = try ManagedPlaywright.Manifests.bundled()
        } catch {
            print("✖ resource bundle found but MCPBundles/playwright manifests are missing — corrupted install? (\(error))")
            throw ExitCode(1)
        }
        let lockProblems = manifests.lockfileProblems()
        guard lockProblems.isEmpty else {
            print("✖ bundled Playwright lockfile fails its sanity rules: \(lockProblems.joined(separator: "; "))")
            throw ExitCode(1)
        }
        print("✔ resource bundle OK: \(bundleURL.path)")
        print("✔ managed Playwright manifests: @playwright/mcp \(manifests.pinnedVersion ?? "?") (lockfile \(manifests.lockfileHash))")
    }
}

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Interactive chat with Briglia (default command)."
    )

    func run() async throws {
        AdaCLI.prepareIO()
        try IdentityMigration.gateMutatingEntry()
        IdentityMigration.warnLegacyEnvironment()
        let session = await TerminalSession()
        try await session.runChat()
    }
}

struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run Briglia headless: no local chat, messaging channels (Telegram) only."
    )

    func run() async throws {
        AdaCLI.prepareIO()
        try IdentityMigration.gateMutatingEntry()
        IdentityMigration.warnLegacyEnvironment()
        let session = await TerminalSession()
        try await session.runDaemon()
    }
}
