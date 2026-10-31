import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - `briglia quicksetup` (terminal, OpenRouter only)

/// The quick setup (owner spec `QUICKSETUP_OPENROUTER_SPEC.md`, 2026-10-30):
/// OpenRouter + Telegram + free web search, in the terminal, so it works
/// over SSH and from scripts. Every step is an action of the `briglia menu`
/// workflow (`MenuWorkflow`), driven headlessly: the same checks, the same
/// one settings writer, the same installers — nothing is saved any other
/// way. Other providers: `briglia setup` or `briglia menu`.
struct QuickSetup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quicksetup",
        abstract: "Quick setup in the terminal: OpenRouter, Telegram and free web search (works over SSH).",
        discussion: """
        Interactive: briglia quicksetup
        No questions (scripts, developers): briglia quicksetup --name <name> --yes
          with the keys in the environment, never on the command line:
          BRIGLIA_OPENROUTER_KEY, BRIGLIA_TELEGRAM_TOKEN, optional BRIGLIA_AGENTMAIL_KEY.
        For ChatGPT, OpenCode Go or local servers use briglia setup (terminal) or briglia menu (browser).
        """
    )

    @Option(name: .customLong("name"), help: "Your name (what Briglia calls you; also the /deleteuserdata confirm word).")
    var name: String?

    @Flag(name: .customLong("yes"), help: "Ask nothing: keys come from BRIGLIA_OPENROUTER_KEY, BRIGLIA_TELEGRAM_TOKEN and (optional) BRIGLIA_AGENTMAIL_KEY.")
    var yes = false

    @Option(name: .customLong("telegram-chat-id"), help: "Your Telegram chat ID: skips waiting for /start.")
    var telegramChatId: String?

    @Flag(name: .customLong("no-tools"), help: "Skip installing the media tools (add them later in briglia menu).")
    var noTools = false

    func run() async throws {
        AdaCLI.prepareIO()
        try IdentityMigration.gateMutatingEntry()
        IdentityMigration.warnLegacyEnvironment()
        try await Self.runTerminal(QuickSetupOptions(name: name, yes: yes, telegramChatId: telegramChatId, noTools: noTools))
    }

    /// The command (also `briglia setup --quick`).
    @MainActor
    static func runTerminal(_ options: QuickSetupOptions) async throws {
        // Keys come only from the environment; they are read once and removed
        // from it, so no installer, sudo or chat child inherits them.
        let secrets = QuickSetupSecrets.takeFromEnvironment()

        if QuickSetupPreflight.isUbuntuTouchOverride ?? AgentServiceSupport.isUbuntuTouch() {
            print("Use the Briglia app's quick setup on this phone.")
            throw ExitCode(2)
        }
        if let problem = QuickSetupFlow.missingForNonInteractive(options, secrets: secrets,
                                                                 savedName: KeychainHelper.load(key: KeychainHelper.userNameKey) ?? "",
                                                                 openRouterSaved: ProviderProfiles.isConfigured(.openrouter),
                                                                 telegramSaved: TelegramConfig.isConfigured) {
            print("✖ \(problem)")
            throw ExitCode(2)
        }
        if SetupWizard.setupComplete() {
            print("Briglia is already set up. To change settings, type: briglia menu (browser) or briglia setup (terminal).")
            return
        }
        // Quick setup is for a Briglia that isn't running (a running one
        // would already be set up); a settings commit of another process
        // holds the lease only for a moment.
        var brigliaRunning = true
        for _ in 0..<30 {
            if case .success(let probe) = InstanceLease.acquire(label: "quicksetup-probe") { probe.release(); brigliaRunning = false; break }
            guard InstanceLease.holderLabel() == "settings-commit" else { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if brigliaRunning {
            print("Briglia is already running. To change its settings, type: briglia menu")
            throw ExitCode(1)
        }
        let devStubs = QuickSetupFlow.devStubsRequested
        #if os(Linux)
        if !devStubs, !AgentServiceSupport.systemdUserSessionAvailable() {
            print("✖ Quick setup runs Briglia as a background service (systemd user session), which this system can't do. Use: briglia setup")
            throw ExitCode(2)
        }
        #endif
        // One settings window per profile: the offline menu and quick setup
        // share the lock, so they never pair a bot or install at once.
        let menuLock: ProfileFileLock
        switch ProfileFileLock.take(StoragePaths.dataRoot.appendingPathComponent("menu.lock")) {
        case .acquired(let l): menuLock = l
        case .busy:
            print("The menu or quick setup is already open in another window. Use that one, or close it (Ctrl-C in its window) and try again.")
            throw ExitCode(1)
        case .failed(let why):
            print("✖ \(why)")
            throw ExitCode(1)
        }
        defer { withExtendedLifetime(menuLock) {} }

        KeepAwake.holdForProcessLifetime()   // the Mac's keep-awake row (as the menu)
        let runner = SetupJobRunner(secrets: secrets.redactions)
        if let poison = SetupJobRunner.inheritLeftoverJournal(into: runner) {
            QuickSetupSession.printPoison(poison)
        }
        var env = MenuEnvironment()
        env.language = "en"
        QuickSetupEnvironment.applyDevStubsIfRequested(&env.quick)
        env.openURL = { _ in }
        if devStubs {
            // Dev builds only (the end-to-end test): no systemd session or
            // sleep settings are touched (CI containers have neither).
            env.systemdSessionAvailable = { true }
            let snapshot = env.snapshot
            env.snapshot = { var s = await snapshot(); s.keepAwakeOK = true; return s }
            let stubTools = env.quick.toolchainStatus   // the stubs' marker-file status
            env.toolchainStatus = { stubTools() }
        }
        let pairing = env.pairing
        env.quick.releaseLease = { pairing.end() }
        env.quick.reacquireLease = { true }
        let menu = MenuWorkflow(env: env, runner: runner)
        menu.optionalItems = [.computer, .tools]
        await menu.start()

        let started = QuickSetupMacStart()
        var system = QuickSetupFlow.System.live
        system.startMac = { await started.acquire() }
        let flow = QuickSetupFlow(menu: menu, options: options, secrets: secrets, io: .terminal, system: system)

        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
        signal(SIGINT, SIG_IGN)
        interrupt.setEventHandler {
            QuickSetupIO.restoreEcho()
            print("\nStopping quick setup… (what was saved is kept; run briglia quicksetup again to continue)")
            fflush(stdout)
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { Foundation.exit(130) }
            Task { @MainActor in
                await menu.shutdown()
                pairing.end()
                Foundation.exit(130)
            }
        }
        interrupt.resume()

        let result = await flow.run()
        await menu.shutdown()
        pairing.end()
        interrupt.cancel()
        signal(SIGINT, SIG_DFL)
        switch result {
        case .failed(let code):
            throw ExitCode(code)
        case .linuxRunning:
            return
        case .macStarting:
            #if os(macOS)
            guard let held = started.take() else { throw ExitCode(1) }
            if QuickSetupFlow.devNoStart {
                held.release()
                print("(dev build: BRIGLIA_DEV_QUICKSETUP_NO_START=1, the chat is not started)")
                return
            }
            // The settings window is closed: `briglia menu` now reaches the
            // running Briglia's own menu.
            menuLock.release()
            // The quick setup becomes the running assistant (as the menu's
            // Start): its member lease changes role, and from here every
            // self-restart (/upgrade, /restart) re-executes `briglia chat`
            // once the wip/restart-argv fix is merged (it hooks promoteToAssistant).
            if let refusal = MemberEntry.promoteToAssistant(kind: "chat") {
                held.release(); print("✖ \(refusal)"); throw ExitCode(1)
            }
            let session = await TerminalSession(sweepLeftoversAtEntry: false)
            try await session.runChat(adopting: held)
            #else
            throw ExitCode(1)
            #endif
        }
    }
}

struct QuickSetupOptions {
    var name: String?
    var yes = false
    var telegramChatId: String?
    var noTools = false
}

/// The keys of a quick setup, from the environment only (never argv).
struct QuickSetupSecrets {
    static let openRouterVar = "BRIGLIA_OPENROUTER_KEY"
    static let telegramVar = "BRIGLIA_TELEGRAM_TOKEN"
    static let agentMailVar = "BRIGLIA_AGENTMAIL_KEY"

    var openRouter: String?
    var telegram: String?
    var agentMail: String?

    /// Reads the three variables and unsets them, so no child process (an
    /// installer, sudo, the chat) inherits a key.
    static func takeFromEnvironment() -> QuickSetupSecrets {
        func take(_ name: String) -> String? {
            let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            unsetenv(name)
            return (value?.isEmpty ?? true) ? nil : value
        }
        return QuickSetupSecrets(openRouter: take(openRouterVar), telegram: take(telegramVar), agentMail: take(agentMailVar))
    }

    /// Values the job runner redacts from installer output.
    var redactions: [String: String] {
        var out: [String: String] = [:]
        if let openRouter { out["openrouter"] = openRouter }
        if let telegram { out["telegram"] = telegram }
        if let agentMail { out["agentmail"] = agentMail }
        return out
    }
}

/// The instance lease the Mac chat runs under, taken when setup finishes.
final class QuickSetupMacStart: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: InstanceLease?

    func acquire() async -> String? {
        switch await InstanceLease.acquire(label: "chat", waitSeconds: 2) {
        case .success(let l):
            lock.lock(); lease = l; lock.unlock()
            return nil
        case .failure:
            return "Briglia is already running in another window."
        }
    }

    func take() -> InstanceLease? { lock.lock(); defer { lock.unlock() }; let l = lease; lease = nil; return l }
}

// MARK: - Terminal input/output

/// The flow's terminal. Reads happen off the main actor, so Ctrl-C (and
/// the menu workflow's own tasks) keep running while a prompt waits.
struct QuickSetupIO {
    /// Prints a line.
    var say: (String) -> Void
    /// Prints text without a newline ("Checking… ").
    var write: (String) -> Void
    /// Shows `prompt` and reads a visible line; nil = input closed.
    var ask: (String) async -> String?
    /// Shows `prompt` and reads a line without echo; nil = input closed.
    var askSecret: (String) async -> String?

    static let terminal = QuickSetupIO(
        say: { print($0); fflush(stdout) },
        write: { print($0, terminator: ""); fflush(stdout) },
        ask: { prompt in
            print(prompt, terminator: ""); fflush(stdout)
            return await Task.detached { readLine(strippingNewline: true) }.value
        },
        askSecret: { prompt in
            print(prompt, terminator: ""); fflush(stdout)
            return await Task.detached { QuickSetupIO.readHiddenLine() }.value
        })

    private static let echoLock = NSLock()
    nonisolated(unsafe) private static var savedTermios: termios?

    /// A line with terminal echo off (plain readLine when stdin isn't a TTY).
    static func readHiddenLine() -> String? {
        guard isatty(STDIN_FILENO) == 1 else { return readLine(strippingNewline: true) }
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var noEcho = original
        noEcho.c_lflag &= ~tcflag_t(ECHO)
        echoLock.lock(); savedTermios = original; echoLock.unlock()
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &noEcho)
        let line = readLine(strippingNewline: true)
        restoreEcho()
        print("")   // the newline the user typed wasn't echoed
        return line
    }

    /// Puts echo back (also from the Ctrl-C handler, mid-read).
    static func restoreEcho() {
        echoLock.lock(); defer { echoLock.unlock() }
        guard var original = savedTermios else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        savedTermios = nil
    }
}

// MARK: - The flow

/// The five steps and the finish, as `MenuWorkflow` actions. Every side
/// effect is the menu's (and its environment's) or one of `System`'s seams.
@MainActor
final class QuickSetupFlow {
    enum Result: Equatable {
        /// macOS: setup is complete and the chat lease is held; the caller
        /// runs Briglia in this terminal.
        case macStarting
        /// Linux: the background service runs.
        case linuxRunning
        case failed(Int32)
    }

    struct System {
        /// Over SSH a Mac can't grant Full Disk Access to the session.
        var isSSH: Bool
        var computerName: String
        /// Sends Bree's first Telegram message; nil = sent, else why not.
        var sendGreeting: (_ token: String, _ chatId: String, _ text: String) async -> String?
        /// The saved bot token (for the greeting).
        var botToken: () -> String?
        /// macOS: takes the instance lease the chat runs under; nil = held,
        /// else why not.
        var startMac: () async -> String?
        var sleep: (Double) async -> Void
        var now: () -> Date
        /// How long the Telegram step waits for /start.
        var telegramWait: TimeInterval = 15 * 60
        /// Polling interval while waiting (Telegram, installers).
        var poll: Double = 1

        static var live: System {
            System(isSSH: ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil || ProcessInfo.processInfo.environment["SSH_TTY"] != nil,
                   computerName: QuickSetupFlow.liveComputerName(),
                   sendGreeting: { await QuickSetupFlow.sendTelegram(token: $0, chatId: $1, text: $2) },
                   botToken: { KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) },
                   startMac: { "not available" },
                   sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                   now: { Date() })
        }
    }

    let menu: MenuWorkflow
    let options: QuickSetupOptions
    let secrets: QuickSetupSecrets
    let io: QuickSetupIO
    let system: System

    // What the summary reports.
    private(set) var userName = ""
    private(set) var botUsername = ""
    private(set) var emailInbox: String?
    private(set) var fda = false
    private(set) var keepAwake = false
    private(set) var toolsInstalled = false
    private(set) var serviceRunning = false

    init(menu: MenuWorkflow, options: QuickSetupOptions, secrets: QuickSetupSecrets, io: QuickSetupIO, system: System) {
        self.menu = menu
        self.options = options
        self.secrets = secrets
        self.io = io
        self.system = system
    }

    /// Dev builds only: `BRIGLIA_DEV_QUICKSETUP_STUBS=1` (the system seams'
    /// stubs, see QuickSetupEnvironment) and `BRIGLIA_DEV_QUICKSETUP_NO_START=1`
    /// (a Mac run ends instead of starting the chat). Release builds ignore both.
    nonisolated static var devStubsRequested: Bool {
        adaCLIVersion.hasSuffix("-dev") && ProcessInfo.processInfo.environment["BRIGLIA_DEV_QUICKSETUP_STUBS"] == "1"
    }
    nonisolated static var devNoStart: Bool {
        adaCLIVersion.hasSuffix("-dev") && ProcessInfo.processInfo.environment["BRIGLIA_DEV_QUICKSETUP_NO_START"] == "1"
    }

    var assistant: String { AssistantName.current() }
    var interactive: Bool { !options.yes }
    var isLinux: Bool { menu.env.isLinux }

    /// `--yes` needs everything up front: a name, and the two keys unless
    /// already saved. nil = fine.
    static func missingForNonInteractive(_ options: QuickSetupOptions, secrets: QuickSetupSecrets,
                                         savedName: String, openRouterSaved: Bool, telegramSaved: Bool) -> String? {
        guard options.yes else { return nil }
        var missing: [String] = []
        if (options.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && savedName.isEmpty { missing.append("--name <your name>") }
        if secrets.openRouter == nil && !openRouterSaved { missing.append(QuickSetupSecrets.openRouterVar) }
        if secrets.telegram == nil && !telegramSaved { missing.append(QuickSetupSecrets.telegramVar) }
        guard !missing.isEmpty else { return nil }
        return "With --yes, quick setup needs: " + missing.joined(separator: ", ")
            + ". Keys go in environment variables, never on the command line."
    }

    func run() async -> Result {
        header()
        guard await stepName() else { return .failed(1) }
        guard await stepOpenRouter() else { return .failed(1) }
        guard await stepTelegram() else { return .failed(1) }
        guard await stepEmail() else { return .failed(1) }
        guard await stepComputer() else { return .failed(1) }
        return await finish()
    }

    // MARK: Header

    func header() {
        io.say("""

        ── Briglia quick setup ──
        OpenRouter + Telegram + free web search. About 5 minutes (plus media tools).
        You need: an OpenRouter API key (https://openrouter.ai/keys) and a Telegram bot token from @BotFather.
        For ChatGPT, OpenCode Go or local servers, use instead: briglia setup
        """)
    }

    /// Input closed (EOF): stop, what was saved is kept.
    private func inputClosed() -> Bool {
        io.say("\nInput closed — stopping here. What was saved is kept; run briglia quicksetup again to continue.")
        return false
    }

    private func act(_ body: [String: Any]) async -> (ok: Bool, message: String) {
        guard let r = await menu.handle(body) else { return (false, "The quick setup was stopped.") }
        return (r["ok"] as? Bool == true, r["message"] as? String ?? "")
    }

    private var status: [String: Any] { menu.status() }

    // MARK: [1/5] Name

    func stepName() async -> Bool {
        io.say("\n[1/5] Your name")
        let saved = menu.snapshot.userName
        var name = (options.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty, !interactive { name = saved }
        while true {
            if name.isEmpty {
                guard let typed = await io.ask("What should \(assistant) call you?\(saved.isEmpty ? "" : " [\(saved)]")\n> ") else { return inputClosed() }
                name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty { name = saved }
                if name.isEmpty { io.say("  Type your name."); continue }
            }
            if name.count > 100 { io.say("✖ That name is too long (at most 100 characters)."); if interactive { name = ""; continue }; return false }
            let r = await act(["action": "name", "name": name])
            if r.ok {
                userName = name
                io.say("✔ Hi, \(name). (Your name is also the confirm word for /deleteuserdata.)")
                return true
            }
            io.say("✖ \(r.message)")
            if !interactive { return false }
            name = ""
        }
    }

    // MARK: [2/5] OpenRouter

    func stepOpenRouter() async -> Bool {
        io.say("\n[2/5] OpenRouter")
        var fromEnvironment = secrets.openRouter
        let saved = menu.stored(.openrouter)
        while true {
            var key = fromEnvironment ?? ""
            fromEnvironment = nil
            if key.isEmpty {
                if !interactive {
                    // --yes with no variable: the saved key (validated when saved).
                    guard saved.configured else { io.say("✖ \(QuickSetupSecrets.openRouterVar) is not set."); return false }
                    return await useSavedOpenRouter()
                }
                if saved.configured, let masked = saved.keyMasked { io.say("A saved key \(masked) was found — press Enter to keep it.") }
                guard let typed = await io.askSecret("Paste your OpenRouter API key (hidden): ") else { return inputClosed() }
                key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty {
                    if saved.configured { return await useSavedOpenRouter() }
                    io.say("  A key is needed here (https://openrouter.ai/keys).")
                    continue
                }
            }
            io.write("Checking… ")
            let r = await act(["action": "provider_key", "profile": "openrouter", "key": key,
                               "model": MenuWorkflow.openRouterDefaultModel])
            if r.ok {
                io.say("✔ The key works.")
                guard await ensureOpenRouterInUse() else { return false }
                reportOpenRouter()
                return true
            }
            io.say(r.message.contains("refused this key")
                   ? "✖ OpenRouter refused this key." + (interactive ? " Paste it again, or Ctrl-C to stop." : "")
                   : "✖ \(r.message)" + (interactive ? " Paste it again, or Ctrl-C to stop." : ""))
            if !interactive { return false }
        }
    }

    /// The saved OpenRouter key stays; OpenRouter becomes the provider in use.
    private func useSavedOpenRouter() async -> Bool {
        io.say("✔ Keeping the saved OpenRouter key.")
        guard await ensureOpenRouterInUse() else { return false }
        reportOpenRouter()
        return true
    }

    /// Quick setup is OpenRouter-only: on an install where another provider
    /// was chosen before (an interrupted `briglia setup`), switch to it.
    private func ensureOpenRouterInUse() async -> Bool {
        guard menu.activeLane != .openrouter else { return true }
        let r = await act(["action": "provider_use", "profile": "openrouter"])
        if r.ok, menu.activeLane == .openrouter { return true }
        io.say("✖ Couldn't switch Briglia to OpenRouter: \(r.message)")
        return false
    }

    private func reportOpenRouter() {
        let host = menu.currentORHost()
        let label = host["label"] as? String ?? MenuWorkflow.openRouterDefaultLabel
        if let pinned = pinnedHost {
            io.say("✔ Main model: \(label), hosted on \(pinned). Change it anytime with /model or briglia menu.")
        } else {
            io.say("✔ Main model: \(label); OpenRouter chooses the host. Change it anytime with /model or briglia menu.")
        }
        let web = status["web"] as? [String: Any] ?? [:]
        if menu.snapshot.serperMasked != nil {
            io.say("✔ Web search: your Serper.dev key.")
        } else if web["free_search"] as? Bool == true {
            io.say("✔ Web search: free with Parallel, no account. Searches go to Parallel and may be used to train their models. For more privacy, add a Serper.dev key later in briglia menu.")
        } else {
            io.say("– Web search is off (free search is switched off). Add a Serper.dev key, or turn free search on, in briglia menu.")
        }
        if menu.snapshot.jinaMasked != nil {
            io.say("✔ Reading web pages: your Jina key.")
        } else {
            io.say("✔ Reading web pages: free with Jina, no key. Some sites (e.g. Reddit) block free reading. Add a Jina key later for more reliable reading.")
        }
    }

    /// The host the OpenRouter model is pinned to, by name, or nil.
    var pinnedHost: String? {
        let host = menu.currentORHost()
        guard ["auto_pinned", "user_host"].contains(host["host_state"] as? String ?? ""),
              let hosts = host["hosts"] as? [String], !hosts.isEmpty else { return nil }
        return hosts.joined(separator: ", ")
    }

    // MARK: [3/5] Telegram

    func stepTelegram() async -> Bool {
        io.say("\n[3/5] Telegram")
        var fromEnvironment = secrets.telegram
        if fromEnvironment == nil, menu.snapshot.telegramConfigured {
            // A bot already paired (an earlier run): keep it unless a new
            // token is given.
            if !interactive { io.say("✔ Keeping the Telegram bot that is already connected."); return true }
            guard let answer = await io.ask("Telegram is already connected. Press Enter to keep it, or type new to connect another bot: ") else { return inputClosed() }
            if answer.trimmingCharacters(in: .whitespaces).lowercased() != "new" { io.say("✔ Keeping the connected bot."); return true }
        }
        while true {
            var token = fromEnvironment ?? ""
            fromEnvironment = nil
            if token.isEmpty {
                if !interactive { io.say("✖ \(QuickSetupSecrets.telegramVar) is not set."); return false }
                guard let typed = await io.askSecret("In Telegram, message @BotFather, send /newbot, follow the steps, then paste the token here (hidden): ") else { return inputClosed() }
                token = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                if token.isEmpty { io.say("  The bot token is needed here."); continue }
            }
            io.write("Checking… ")
            var tokenAction: [String: Any] = ["action": "telegram_token", "token": token]
            if knownChatId != nil { tokenAction["manual"] = true }
            let r = await act(tokenAction)
            guard r.ok else {
                io.say("✖ \(r.message)")
                if !interactive { return false }
                continue
            }
            let pending = (status["telegram"] as? [String: Any])?["pending"] as? [String: Any]
            let bot = pending?["bot"] as? String ?? "your_bot"
            io.say("✔ Bot: @\(bot)")
            switch await pair(bot: bot) {
            case .paired: return true
            case .retryToken where interactive: continue
            default: return false
            }
        }
    }

    private enum Pairing { case paired, retryToken, stop }

    /// `--telegram-chat-id`: no /start wait, no scan of the bot.
    private var knownChatId: String? {
        let id = options.telegramChatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }

    private func pair(bot: String) async -> Pairing {
        if let chatId = knownChatId {
            let r = await act(["action": "telegram_confirm", "chat_id": chatId])
            if r.ok { return paired(bot: bot, who: nil) }
            io.say("✖ \(r.message)")
            _ = await act(["action": "telegram_reset"])
            return .stop
        }
        io.say("Now send /start to @\(bot) in Telegram. Waiting…")
        let deadline = system.now().addingTimeInterval(system.telegramWait)
        while system.now() < deadline {
            await system.sleep(system.poll)
            let tg = status["telegram"] as? [String: Any] ?? [:]
            guard let pending = tg["pending"] as? [String: Any] else {
                // The scan failed (webhook, another program, revoked token).
                io.say("✖ \(tg["error"] as? String ?? "The Telegram step stopped.")")
                return .retryToken
            }
            guard pending["state"] as? String == "found", let chatId = pending["chat_id"] as? String else { continue }
            let who = pending["name"] as? String
            let r = await act(["action": "telegram_confirm", "chat_id": chatId])
            if r.ok { return paired(bot: bot, who: who) }
            // Not confirmed (e.g. the bot can't see the chat yet): keep waiting.
            io.say("✖ \(r.message)")
            if (status["telegram"] as? [String: Any])?["pending"] == nil { return .retryToken }
            _ = await act(["action": "telegram_wait"])
        }
        io.say("✖ No /start reached @\(bot) within \(Int(system.telegramWait / 60)) minutes. Run briglia quicksetup again when you're ready.")
        _ = await act(["action": "telegram_reset"])
        return .stop
    }

    private func paired(bot: String, who: String?) -> Pairing {
        botUsername = bot
        io.say("✔ Paired with \(who ?? "your Telegram account"). Only this account can talk to \(assistant).")
        return .paired
    }

    // MARK: [4/5] Email

    func stepEmail() async -> Bool {
        io.say("\n[4/5] Email (optional)")
        var key = secrets.agentMail ?? ""
        if key.isEmpty, menu.snapshot.emailProvider == "agentmail", menu.snapshot.agentMailMasked != nil {
            emailInbox = menu.snapshot.agentMailInbox
            io.say("✔ AgentMail is already connected." + (menu.snapshot.agentMailInbox.isEmpty ? "" : " Inbox: \(menu.snapshot.agentMailInbox)"))
            return true
        }
        while true {
            if key.isEmpty {
                if !interactive { io.say("– Email skipped"); return true }
                guard let typed = await io.askSecret("Give \(assistant) its own email inbox with AgentMail? Paste an AgentMail API key, or press Enter to skip. You can add it later in briglia menu.\n> ") else { return inputClosed() }
                key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty { io.say("– Email skipped"); return true }
            }
            io.write("Checking… ")
            let r = await act(["action": "key", "kind": "agentmail", "key": key])
            key = ""
            if r.ok {
                let inbox = (status["email"] as? [String: Any])?["inbox"] as? String ?? ""
                emailInbox = inbox
                io.say("✔ AgentMail works." + (inbox.isEmpty ? "" : " Inbox: \(inbox)"))
                await waitForBackgroundWork()
                if let error = (status["tools"] as? [String: Any])?["error"] as? String { io.say("⚠ \(error) Retry later in briglia menu.") }
                return true
            }
            io.say("✖ \(r.message)" + (interactive ? " Paste it again, or press Enter to skip." : ""))
            if !interactive { return false }
        }
    }

    /// Waits for the menu's background job (email tool, installers) to end,
    /// printing its output lines.
    private func waitForBackgroundWork() async {
        var printed = 0
        while true {
            let s = status
            let lines = (s["tools"] as? [String: Any])?["lines"] as? [String] ?? []
            if lines.count < printed { printed = 0 }
            for line in lines.dropFirst(printed) { io.say("  │ \(line)") }
            printed = lines.count
            if s["busy"] is NSNull || s["busy"] == nil { return }
            await system.sleep(system.poll)
        }
    }

    // MARK: [5/5] This computer

    func stepComputer() async -> Bool {
        io.say("\n[5/5] This computer")
        if isLinux { return await computerLinux() }
        return await computerMac()
    }

    private func computer() -> [String: Any] { status["computer"] as? [String: Any] ?? [:] }

    private func computerMac() async -> Bool {
        let terminal = computer()["terminal_app"] as? String ?? "Terminal"
        if computer()["fda"] as? Bool == true {
            fda = true
            io.say("✔ Full Disk Access granted")
        } else if system.isSSH {
            io.say("– Full Disk Access skipped: it can't be granted over SSH. On this Mac, open System Settings › Privacy & Security › Full Disk Access and turn on \(terminal); \(assistant) works with less access until then.")
        } else if !interactive {
            io.say("– Full Disk Access skipped (--yes). Grant it later: System Settings › Privacy & Security › Full Disk Access, turn on \(terminal).")
        } else {
            _ = await act(["action": "fda_open"])
            guard await io.ask("Full Disk Access lets \(assistant) read your files, Mail and Messages. System Settings is opening at Privacy & Security › Full Disk Access: turn on \"\(terminal)\", then press Enter here. (Enter without enabling it = skip; \(assistant) works with less access.)\n") != nil else { return inputClosed() }
            _ = await act(["action": "recheck"])
            if computer()["fda"] as? Bool == true {
                fda = true
                io.say("✔ Full Disk Access granted")
            } else {
                io.say("– Full Disk Access skipped")
            }
        }
        keepAwake = computer()["keep_awake_ok"] as? Bool == true
        io.say(keepAwake ? "✔ Keep awake: this Mac won't sleep while Briglia is running"
                         : "⚠ Keep awake: this Mac may go to sleep while Briglia runs.")
        await installTools(intro: "Installing media tools (ffmpeg, ImageMagick, poppler, LibreOffice, Python packages). This can take 5–15 minutes…")
        return true
    }

    private func computerLinux() async -> Bool {
        let tools = await toolsStatus()
        let keepAwakeOK = computer()["keep_awake_ok"] as? Bool == true
        let needsSudoTools = !options.noTools && tools["complete"] as? Bool != true
        let needsSudoSleep = !keepAwakeOK && computer()["can_fix_gnome"] as? Bool != true && computer()["can_mask"] as? Bool == true
        if needsSudoTools || needsSudoSleep {
            io.say("The media tools and keep-awake need your password once (sudo):")
        }
        await installTools(intro: nil)
        if computer()["keep_awake_ok"] as? Bool == true {
            keepAwake = true
            io.say("✔ Keep awake: sleep is turned off on this computer")
        } else {
            let how = computer()["can_fix_gnome"] as? Bool == true ? "gnome" : (computer()["can_mask"] as? Bool == true ? "mask" : "")
            if how.isEmpty {
                io.say("⚠ Keep awake: this computer may go to sleep (\(computer()["keep_awake_summary"] as? String ?? "unknown")). Turn off automatic suspend in its power settings.")
            } else {
                let r = await act(["action": "keepawake", "how": how])
                keepAwake = r.ok
                io.say(r.ok ? "✔ Keep awake: sleep is turned off on this computer" : "⚠ Keep awake: \(r.message)")
            }
        }
        return true
    }

    /// The toolchain status, once the menu finished checking it.
    private func toolsStatus() async -> [String: Any] {
        while true {
            let tools = status["tools"] as? [String: Any] ?? [:]
            if tools["checking"] as? Bool != true { return tools }
            await system.sleep(system.poll)
        }
    }

    private func installTools(intro: String?) async {
        if options.noTools {
            io.say("– Media tools skipped (--no-tools). Install them later in briglia menu (Document & media tools).")
            return
        }
        let before = await toolsStatus()
        if before["complete"] as? Bool == true {
            toolsInstalled = true
            io.say(isLinux ? "✔ media tools ✔ python3-venv" : "✔ Media tools are already installed")
            return
        }
        if let intro { io.say(intro) }
        let r = await act(["action": "tools_install"])
        guard r.ok else {
            if !isLinux, r.message.contains("Homebrew") {
                io.say("✖ Media tools need Homebrew: install it from https://brew.sh, then install them in briglia menu (Document & media tools). Continuing without them.")
            } else {
                io.say("✖ \(r.message) Continuing without the media tools; install them later in briglia menu.")
            }
            return
        }
        await waitForBackgroundWork()
        let after = await toolsStatus()
        if after["complete"] as? Bool == true {
            toolsInstalled = true
            io.say(isLinux ? "✔ media tools ✔ python3-venv" : "✔ ffmpeg ✔ ImageMagick ✔ poppler ✔ LibreOffice ✔ Python")
        } else {
            let why = after["error"] as? String ?? ("Still missing: " + ((after["missing"] as? [String]) ?? []).joined(separator: ", ") + ".")
            io.say("✖ \(why) Continuing; install them later in briglia menu (Document & media tools).")
        }
    }

    // MARK: Finish

    func finish() async -> Result {
        // Setup is complete once the required rows are done: mark it now,
        // through the menu's own completion write.
        _ = await toolsStatus()
        _ = await act(["action": "recheck"])
        await menu.settle()
        guard menu.snapshot.setupComplete else {
            let missing = menu.missingRequired.map { menu.stepTitle($0) }.joined(separator: ", ")
            io.say("✖ Setup couldn't be completed" + (missing.isEmpty ? " (the completion couldn't be saved)." : ": \(missing) still missing.") + " Run briglia quicksetup again.")
            return .failed(1)
        }
        io.say("\nStarting Briglia…")
        if isLinux {
            let r = await act(["action": "finish", "what": "start"])
            guard r.ok else { io.say("✖ \(r.message)"); return .failed(1) }
            var lastStep = ""
            while menu.closing != "start" {
                if let startup = status["startup"] as? [String: Any] {
                    if startup["state"] as? String == "failed" {
                        io.say("✖ \(startup["message"] as? String ?? "Briglia didn't start.")")
                        return .failed(1)
                    }
                    if let step = startup["step"] as? String, !step.isEmpty, step != lastStep { io.say("  \(step)"); lastStep = step }
                }
                await system.sleep(system.poll)
            }
            serviceRunning = true
            io.say("✔ Background service: Briglia starts at boot and stays on after you log out")
        } else {
            let r = await act(["action": "finish", "what": "start"])
            guard r.ok else { io.say("✖ \(r.message)"); return .failed(1) }
            await menu.shutdown()
            if let refusal = await system.startMac() {
                io.say("✖ \(refusal) Setup is saved; talk to Briglia there.")
                return .failed(1)
            }
        }
        await greet()
        io.say(isLinux ? "Briglia is running in the background."
                       : "Briglia is running in this window. Keep it open (you can minimize it). To change settings, open a new terminal window and type briglia menu.")
        printSummary()
        return isLinux ? .linuxRunning : .macStarting
    }

    func greetingText() -> String {
        "Hi \(userName.isEmpty ? menu.snapshot.userName : userName), I'm \(assistant), your assistant on \(system.computerName). Ask me anything, by text or voice message."
    }

    private func greet() async {
        let chatId = menu.snapshot.telegramChatId
        guard let token = system.botToken(), !token.isEmpty, !chatId.isEmpty else {
            io.say("✓ Done! Send a message to your bot on Telegram to talk to \(assistant).")
            return
        }
        if let failure = await system.sendGreeting(token, chatId, greetingText()) {
            io.say("✓ Done! (\(assistant)'s first Telegram message couldn't be sent: \(failure).) Send a message to @\(botUsername.isEmpty ? "your bot" : botUsername) on Telegram to start.")
        } else {
            io.say("✓ Done! \(assistant) has just written to you on Telegram.")
        }
    }

    func printSummary() {
        let s = menu.snapshot
        let model = MenuWorkflow.modelLabel(.openrouter, menu.stored(.openrouter).model)
        let search = s.serperMasked != nil ? "Serper key" : (s.freeSearchOn ? "free (Parallel)" : "off")
        let reading = s.jinaMasked != nil ? "Jina key" : "free (Jina)"
        let email = s.emailProvider == "agentmail" && s.agentMailMasked != nil
            ? "AgentMail" + (s.agentMailInbox.isEmpty ? "" : " (\(s.agentMailInbox))") : "not set"
        let bot = botUsername.isEmpty ? "connected" : "@\(botUsername)"
        func mark(_ b: Bool) -> String { b ? "✔" : "✖" }
        let machine = isLinux
            ? "Keep awake \(mark(keepAwake)) · Media tools \(options.noTools ? "skipped" : mark(toolsInstalled)) · Background service \(mark(serviceRunning))"
            : "Full Disk Access \(mark(fda)) · Keep awake \(mark(keepAwake)) · Media tools \(options.noTools ? "skipped" : mark(toolsInstalled))"
        io.say("""

        Summary:
          Name: \(s.userName)
          Model: \(model) (OpenRouter\(pinnedHost.map { ", \($0)" } ?? ""))
          Search: \(search) · Page reading: \(reading)
          Email: \(email)
          Telegram: \(bot)
          \(machine)
        To change anything: briglia menu (browser) or briglia setup (terminal).
        """)
    }

    // MARK: Live seams

    nonisolated static func liveComputerName() -> String {
        #if os(macOS)
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        #endif
        let host = ProcessInfo.processInfo.hostName
        return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    }

    /// Telegram sendMessage (the greeting). nil = sent.
    nonisolated static func sendTelegram(token: String, chatId: String, text: String) async -> String? {
        guard let url = URL(string: DevProbeOverride.url("https://api.telegram.org/bot\(token)/sendMessage",
                                                         dev: "/telegram/bot\(token)/sendMessage")) else { return "bad token" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": chatId, "text": text])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["ok"] as? Bool == true
            return code == 200 && ok ? nil : "Telegram answered HTTP \(code)"
        } catch {
            return "Telegram couldn't be reached"
        }
    }
}
