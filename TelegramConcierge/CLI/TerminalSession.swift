import ArgumentParser
#if canImport(Combine)
import Combine
#else
import OpenCombine
import OpenCombineDispatch
#endif
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Terminal front-end for ConversationManager: the CLI equivalent of the app's
/// chat window. Registers no transport of its own — it IS the `.app` channel:
/// user input goes in via `sendFromApp`, and output is rendered by observing
/// the published conversation history (text replies over the app channel are
/// deliberately no-ops; history is the UI).
@MainActor
final class TerminalSession {
    private let manager: ConversationManager

    /// `sweepLeftoversAtEntry: true` for the entry commands (`chat`,
    /// `daemon`): this image may be the product of an in-place `execv`
    /// (`/restart`, `/upgrade`), so `LeftoverChildSweep.run()` runs HERE,
    /// before the manager exists — its initializer already schedules polling,
    /// channel bridges and other background work when configured, and the
    /// sweep's "every child is a leftover" invariant holds only before any of
    /// that can spawn. `false` for a same-image handoff (`briglia quicksetup`
    /// → chat): no exec happened, so there is nothing to inherit, and the
    /// setup's own journaled children must not be treated as leftovers.
    init(sweepLeftoversAtEntry: Bool) {
        if sweepLeftoversAtEntry { LeftoverChildSweep.run() }
        manager = ConversationManager()
    }
    private var cancellables = Set<AnyCancellable>()
    private var printedMessageIds = Set<UUID>()
    private var lastActivityDescription: String?
    private var signalSources: [DispatchSourceSignal] = []
    /// The exclusive instance lease: acquired at start, or ADOPTED from
    /// `briglia quicksetup` (which holds it through its run and hands it
    /// over instead of releasing — a second flock in the same process would
    /// block). Released explicitly on every shutdown path.
    private var lease: InstanceLease?
    private static let leaseReleaseLock = NSLock()
    nonisolated(unsafe) private static var leaseForSignalHandler: InstanceLease?

    /// Messages suppressed while privacy mode (/hide) was active, replayed
    /// in order when the user sends /show. Mirrors the app, where the
    /// conversation view reappears with full history on /show.
    private var hiddenWhilePrivate: [Message] = []

    /// Combine on Apple platforms schedules straight on DispatchQueue;
    /// OpenCombine (Linux) needs the `.ocombine` scheduler wrapper.
    #if canImport(Combine)
    private var mainScheduler: DispatchQueue { DispatchQueue.main }
    #else
    private var mainScheduler: DispatchQueue.OCombine { DispatchQueue.main.ocombine }
    #endif

    // MARK: - Entry points

    func runChat(adopting lease: InstanceLease? = nil) async throws {
        try await start(headless: false, adopting: lease)
        printWelcome()
        await inputLoop()
        Self.shutdownChildProcesses()
        await releaseLease()
    }

    func runDaemon() async throws {
        // Telegram used to be a hard requirement here. With the companion-app
        // socket the daemon is reachable without it (app-only setups), so a
        // missing pairing is a loud warning instead of a refusal.
        let telegramConfigured = TelegramConfig.isConfigured
        if !telegramConfigured {
            print("⚠ Telegram is not configured — the daemon will listen only on the companion-app socket. Run `briglia setup` to add Telegram.")
        }
        try await start(headless: true, adopting: nil)
        print("Briglia daemon running — listening on \(telegramConfigured ? "Telegram and the app socket" : "the app socket"). Ctrl-C to stop.")
        while true {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    // MARK: - Startup

    private func start(headless: Bool, adopting adopted: InstanceLease?) async throws {
        if let adopted {
            precondition(adopted.held, "adopted lease must be held")
            lease = adopted
        } else {
            switch InstanceLease.acquire(label: headless ? "daemon" : "chat") {
            case .success(let acquired): lease = acquired
            case .failure(let conflict):
                print("✖ \(conflict)")
                throw ExitCode(1)
            }
        }
        Self.leaseForSignalHandler = lease
        installSignalHandlers()
        KeepAwake.holdForProcessLifetime(reason: "Briglia is running")
        // Both roots must be usable directories before anything writes;
        // a root that exists as something else is a hard startup error.
        do {
            try StoragePaths.ensureRootsChecked()
        } catch {
            print("✖ storage roots: \(error)")
            throw ExitCode(1)
        }
        // Private-by-default storage: every start strips group/other bits
        // from everything under the roots (projects/ and toolchain/
        // excluded), so files created by older versions or by hand end up
        // owner-only without a migration step.
        let sweep = PrivateStorage.sweep()
        if sweep.tightened > 0 || !sweep.errors.isEmpty || sweep.truncated {
            var line = "storage: \(sweep.tightened) entr\(sweep.tightened == 1 ? "y" : "ies") tightened to owner-only (\(sweep.scanned) scanned)"
            if sweep.truncated { line += " — scan budget hit, rerun at next start" }
            if !sweep.errors.isEmpty { line += " — \(sweep.errors.count) could not be changed: \(sweep.errors.prefix(3).joined(separator: "; "))" }
            print(line)
        }
        LandingZone.bootstrap()
        ProjectsZipAutoExtractor.shared.start()

        // Mark existing history as already seen so a restart doesn't replay
        // the whole conversation into the terminal.
        printedMessageIds = Set(manager.messages.map(\.id))

        await manager.startPolling()
        if let error = manager.error {
            print("✖ \(error)")
            print("  Run `briglia setup` to configure Briglia, then try again.")
            throw ExitCode(1)
        }

        subscribe(headless: headless)

        // Companion-app chat: a JSON-lines front-end on a local Unix socket,
        // live in both interactive and daemon modes. Same-user only (peer-UID
        // checked); bind failure is loud but never blocks startup.
        AppChatSocketServer.shared.start(manager: manager)

        Task { await BrowserAutomationBootstrap.ensureConfigured() }

        // Post-exec restart (/upgrade or /restart re-execs in place): close
        // the loop the old process opened with "I'll confirm when I'm back."
        if let marker = UpgradeService.consumeRestartMarker() {
            switch marker.kind {
            case .upgrade:
                print("✔ Update \(marker.version) installed — Briglia restarted.")
                await manager.announceUpgradeCompletion(version: marker.version)
            case .restart:
                print("✔ Briglia restarted.")
                await manager.announceRestartCompletion()
            }
        }
    }

    private func printWelcome() {
        let name = KeychainHelper.load(key: KeychainHelper.userNameKey)
        let greeting = name.flatMap { $0.isEmpty ? nil : "Hi \($0)! " } ?? ""
        print("Briglia CLI \(adaCLIVersion)")
        print("\(greeting)Type a message and press Enter. Commands: /stop /status /prune /attach <path> [text] /help /quit")
        prompt()
    }

    private func prompt() {
        print("› ", terminator: "")
        fflush(stdout)
    }

    // MARK: - Output rendering

    private func subscribe(headless: Bool) {
        manager.$messages
            .receive(on: mainScheduler)
            .sink { [weak self] messages in
                self?.renderNewMessages(messages, headless: headless)
            }
            .store(in: &cancellables)

        guard !headless else {
            // Daemon: status only; message traffic is on Telegram.
            manager.$statusMessage
                .removeDuplicates()
                .receive(on: mainScheduler)
                .sink { print("· \($0)") }
                .store(in: &cancellables)
            return
        }

        manager.$turnActivity
            .receive(on: mainScheduler)
            .sink { [weak self] activity in
                self?.renderActivity(activity)
            }
            .store(in: &cancellables)

        // /show after /hide: replay the messages suppressed while private.
        manager.$isPrivacyModeEnabled
            .removeDuplicates()
            .receive(on: mainScheduler)
            .sink { [weak self] enabled in
                guard let self, !enabled, !self.hiddenWhilePrivate.isEmpty else { return }
                print("\n— revealing \(self.hiddenWhilePrivate.count) message(s) hidden by privacy mode —")
                for message in self.hiddenWhilePrivate {
                    self.render(message)
                }
                self.hiddenWhilePrivate.removeAll()
            }
            .store(in: &cancellables)

        manager.$isTurnActive
            .removeDuplicates()
            .receive(on: mainScheduler)
            .sink { [weak self] active in
                if !active {
                    self?.lastActivityDescription = nil
                    self?.prompt()
                }
            }
            .store(in: &cancellables)

        manager.$error
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: mainScheduler)
            .sink { print("\n✖ \($0)") }
            .store(in: &cancellables)

        manager.$maintenanceNotice
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: mainScheduler)
            .sink { print("\n· \($0)") }
            .store(in: &cancellables)

        // Agent-initiated mid-turn messages (mid_turn_message_user tool) need
        // no dedicated pipe: delivery appends a durable assistant message to
        // history, which renderNewMessages prints live — and privacy mode's
        // hidden-queue / /show replay applies automatically.
    }

    private func renderNewMessages(_ messages: [Message], headless: Bool) {
        for message in messages where !printedMessageIds.contains(message.id) {
            printedMessageIds.insert(message.id)
            guard !headless else { continue }

            // Privacy mode (/hide): the on-screen conversation must stay
            // hidden — queue the message and print only a content-free notice.
            if manager.isPrivacyModeEnabled {
                if isRenderable(message) {
                    hiddenWhilePrivate.append(message)
                    print("\n· message hidden (privacy mode — /show to reveal)")
                }
                continue
            }
            render(message)
        }
    }

    private func isRenderable(_ message: Message) -> Bool {
        switch message.role {
        case .assistant:
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty || !(message.imageFileNames + message.documentFileNames
                + message.generatedFilePaths).isEmpty
        case .user:
            return message.originChannel.map { $0.kind != .app } ?? false
                && message.kind == .userText
        }
    }

    private func render(_ message: Message) {
        switch message.role {
        case .assistant:
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                print("\nBriglia ▸ \(text)")
            }
            renderAttachments(of: message)
        case .user:
            // Echo traffic that did NOT originate from this terminal so a
            // shared session (Telegram + terminal open at once) stays
            // readable. Terminal-typed messages are already on screen.
            if let origin = message.originChannel, origin.kind != .app, message.kind == .userText {
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                print("\n[\(origin.kind.displayName)] \(text)")
            }
        }
    }

    private func renderAttachments(of message: Message) {
        let names = message.imageFileNames + message.documentFileNames
            + message.generatedFilePaths
        for name in names {
            print("  📎 \(name)")
        }
    }

    private func renderActivity(_ activity: ConversationManager.TurnActivity?) {
        guard let activity else { return }
        let description: String
        switch activity.kind {
        case .thinking:
            description = "thinking…"
        case .tools(let names):
            // Tool names can leak what the conversation is about (file paths,
            // search queries) — keep them generic while privacy mode is on.
            description = manager.isPrivacyModeEnabled ? "working…" : names.joined(separator: ", ")
        }
        guard description != lastActivityDescription else { return }
        lastActivityDescription = description
        print("  ⚙ \(description)")
    }

    // MARK: - Input loop

    private func inputLoop() async {
        for await line in Self.stdinLines() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { prompt(); continue }
            if await handleCommand(trimmed) { break }
        }
    }

    /// Returns true when the loop should end (user quit / stdin closed).
    private func handleCommand(_ line: String) async -> Bool {
        switch true {
        case line == "/quit" || line == "/exit":
            return true

        case line == "/help":
            // Shared block derives from ChatCommandRegistry — the same table
            // that builds the Telegram menu and /commands — so the surfaces
            // can't drift. Terminal-only and power commands are appended here.
            for helpLine in ChatCommandRegistry.terminalHelpLines() {
                print(helpLine)
            }
            print("""
              /attach <path> [message]   send a file (with optional text)
              /quit             exit (also Ctrl-C)
            Power commands: /spend [turn|daily|monthly <usd|off>] (limits are off by default;
              /more1 /more5 /more10 raise a reached daily/monthly limit), /hide, /show,
              /transcribe_local, /transcribe_openai
            All Telegram commands work here too — the two surfaces share one command set.
            """)
            prompt()

        case line == "/stop":
            await manager.stopFromApp()

        case line == "/status":
            let state = manager.isTurnActive ? "working" : (manager.isPolling ? "idle, listening" : "stopped")
            print("  status: \(state) — \(manager.statusMessage)")
            if let activity = manager.turnActivity, case .tools(let names) = activity.kind {
                let seconds = Int(Date().timeIntervalSince(activity.startedAt))
                print("  running: \(names.joined(separator: ", ")) (\(seconds)s)")
            }
            if let tokens = manager.lastPromptTokens {
                print("  context: ~\(tokens) tokens")
            }
            prompt()

        case line == "/prune":
            await manager.manualPruneFromApp()

        case line.hasPrefix("/attach "):
            let rest = String(line.dropFirst("/attach ".count))
                .trimmingCharacters(in: .whitespaces)
            let parts = Self.splitAttachArgument(rest)
            guard let first = parts.first, !first.isEmpty else {
                print("  usage: /attach <path> [message]   (quote paths containing spaces)")
                prompt()
                break
            }
            let url = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("  ✖ no such file: \(url.path)")
                prompt()
                break
            }
            let text = parts.count > 1 ? parts[1] : ""
            submit(text: text, attachments: [url])

        case line.hasPrefix("/"):
            // Everything else routes through the SAME command set Telegram
            // uses (/model, /effort, /spend, /hide, /llm…), so the surfaces
            // can't drift apart.
            if let responses = await manager.handleTerminalCommand(line) {
                if responses.isEmpty {
                    print("  done")
                } else {
                    for response in responses {
                        print("  " + response.replacingOccurrences(of: "\n", with: "\n  "))
                    }
                }
            } else {
                print("  unknown command \(line) — try /help")
            }
            prompt()

        default:
            submit(text: line, attachments: [])
        }
        return false
    }

    /// Fire-and-forget so the input loop stays responsive during a turn:
    /// /stop must work while the agent is working, and messages typed
    /// mid-turn flow into the existing mid-turn steering queue. A refusal
    /// (restore gate, disk write failure, bad attachment) prints instead of
    /// vanishing — the terminal's equivalent of the app socket's nack.
    private func submit(text: String, attachments: [URL]) {
        Task {
            if case .refused(let reason) = await manager.sendFromApp(
                text: text, attachments: attachments, policy: .terminal) {
                print("\n  ✖ not accepted: \(reason)")
                prompt()
            }
        }
    }

    /// Split "/attach"'s argument into [path, message?]. The path may be
    /// wrapped in single or double quotes (spaces inside are preserved) or
    /// use backslash-escaped spaces; otherwise it ends at the first space.
    static func splitAttachArgument(_ rest: String) -> [String] {
        guard let quote = rest.first, quote == "\"" || quote == "'" else {
            // Unquoted: honor backslash-escaped spaces, else split at first space.
            var path = ""
            var index = rest.startIndex
            while index < rest.endIndex {
                let ch = rest[index]
                if ch == "\\", rest.index(after: index) < rest.endIndex,
                   rest[rest.index(after: index)] == " " {
                    path.append(" ")
                    index = rest.index(index, offsetBy: 2)
                    continue
                }
                if ch == " " { break }
                path.append(ch)
                index = rest.index(after: index)
            }
            let message = String(rest[index...]).trimmingCharacters(in: .whitespaces)
            return message.isEmpty ? [path] : [path, message]
        }
        let body = rest.dropFirst()
        guard let closing = body.firstIndex(of: quote) else {
            // Unterminated quote: treat the remainder as the whole path.
            return [String(body)]
        }
        let path = String(body[..<closing])
        let message = String(body[body.index(after: closing)...])
            .trimmingCharacters(in: .whitespaces)
        return message.isEmpty ? [path] : [path, message]
    }

    private static func stdinLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Shutdown

    private func installSignalHandlers() {
        let shutdown = ShutdownSignalCoordinator(settle: {
            print("\nShutting down… (press Ctrl-C again to force exit)")
            await BrowserSettingsHost.stopShared()
        }, gracefulExit: {
            AppChatSocketServer.shared.stop()
            TerminalSession.shutdownChildProcesses()
            TerminalSession.releaseLeaseForShutdown()
            exit(0)
        }, forceExit: {
            // Keep the lease until process teardown kills every in-process
            // callback. Never unlock while an unsettled save can still write.
            // Second Ctrl-C: the user wants out now — signals go out
            // immediately either way, only the wait is shortened.
            TerminalSession.shutdownChildProcesses(budgetSeconds: 3)
            exit(130)
        })
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Task { @MainActor in shutdown.request() }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Release the instance lease after the poller stopped and the socket
    /// closed. Explicit on every normal path, so the `deinit` fallback of
    /// `InstanceLease` never fires for a session that ended cleanly.
    private func releaseLease() async {
        await BrowserSettingsHost.stopShared()
        AppChatSocketServer.shared.stop()
        Self.releaseLeaseForShutdown()
        lease = nil
    }

    /// Signal-handler-safe variant (runs on the main queue): releases the
    /// lease registered at start, once.
    static func releaseLeaseForShutdown() {
        leaseReleaseLock.lock()
        defer { leaseReleaseLock.unlock() }
        if let lease = leaseForSignalHandler, lease.held { lease.release() }
        leaseForSignalHandler = nil
    }

    /// Kill every child the agent spawned (background bash, foreground
    /// subprocesses, language servers, MCP servers) so nothing outlives the
    /// CLI as an orphan. Runs on every exit path AND immediately before the
    /// in-place `execv` of `/restart` and `/upgrade` — where an orphan is not
    /// merely untidy: it stays a child of this pid forever, in its own
    /// session, with no `Process` object left to signal or reap it.
    ///
    /// MCP servers were missing from this list until v0.2.21; every restart
    /// leaked the previous Playwright server (shim + node, sometimes a
    /// browser tree). `includeMCP` exists only for the lifecycle selftest's
    /// negative control.
    ///
    /// The MCP shutdown is terminal and concurrent: it owns servers still
    /// bootstrapping, refuses new spawns, and ends every server in parallel,
    /// so its cost is one client's grace + collection budget
    /// (`MCPClient.shutdownGraceNanos` + `shutdownReapBudgetNanos`), not the
    /// server count or a stuck initialize. The wait budget here leaves room
    /// above that; an overrun is reported, not silent. After an exec the next
    /// image's LeftoverChildSweep collects what was still dying; after a real
    /// exit nothing can, which is why termination is INITIATED for every
    /// owned server before any waiting happens.
    static let childShutdownBudgetSeconds: Double = 15

    static func shutdownChildProcesses(includeMCP: Bool = true,
                                       budgetSeconds: Double = childShutdownBudgetSeconds) {
        ToolExecutor.terminateAllRegisteredProcesses()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await BackgroundProcessRegistry.shared.terminateAll()
            await LSPRegistry.shared.shutdownAll()
            if includeMCP { await MCPRegistry.shared.shutdownForExit() }
            sem.signal()
        }
        if sem.wait(timeout: .now() + budgetSeconds) == .timedOut {
            FileHandle.standardError.write(Data(
                "⚠ child shutdown did not finish within \(Int(budgetSeconds)) s — a server may outlive this process; the next start sweeps leftovers\n".utf8))
        }
    }
}

/// Minimal read-side helper for daemon-mode gating (the full validation lives
/// in the wizard/doctor).
enum TelegramConfig {
    static var isConfigured: Bool {
        let token = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? ""
        let chatId = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey) ?? ""
        return !token.isEmpty && !chatId.isEmpty
    }
}


/// Only for whole-process signal exits. A normal host close still settles all
/// callbacks before releasing its lease. Forced exit leaves unlocking to the OS.
@MainActor
final class ShutdownSignalCoordinator {
    private let settle: () async -> Void
    private let gracefulExit: () -> Void
    private let forceExit: () -> Void
    private let graceNanoseconds: UInt64
    private var requested = false
    private var finished = false
    private var deadline: Task<Void, Never>?

    init(graceNanoseconds: UInt64 = 5_000_000_000,
         settle: @escaping () async -> Void,
         gracefulExit: @escaping () -> Void, forceExit: @escaping () -> Void) {
        self.graceNanoseconds = graceNanoseconds
        self.settle = settle; self.gracefulExit = gracefulExit; self.forceExit = forceExit
    }
    func request() {
        guard !finished else { return }
        if requested { force(); return }
        requested = true
        deadline = Task {
            do { try await Task.sleep(nanoseconds: graceNanoseconds) } catch { return }
            force()
        }
        Task {
            await settle()
            guard !finished else { return }
            finished = true; deadline?.cancel(); deadline = nil
            gracefulExit()
        }
    }
    private func force() {
        guard !finished else { return }
        finished = true; deadline?.cancel(); deadline = nil
        forceExit()
    }
}
