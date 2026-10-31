import Foundation

// MARK: 19. Terminal quick setup (OpenRouter only)

/// The terminal `briglia quicksetup` driven end to end on the real
/// `MenuWorkflow` with the menu selftest's fake world (no network, no
/// system changes): every screen of the owner spec, the non-interactive
/// mode, Linux, failures and resumes. Every write must reach the world
/// through the menu environment's `apply` seam (the one settings writer).
extension SelftestContext {
    func terminalQuickSetup() async throws {
        let (checks, failures) = await QuickSetupTerminalBattery.run(tempRoot: tempRoot)
        self.checks += checks
        self.failures += failures
    }
}

/// Scripted terminal for the flow.
@MainActor
final class QuickSetupScript {
    var answers: [String?]
    var secretAnswers: [String?]
    var out = ""
    var prompts: [String] = []
    var askedWhenForbidden = false
    let forbidQuestions: Bool

    init(answers: [String?] = [], secrets: [String?] = [], forbidQuestions: Bool = false) {
        self.answers = answers
        self.secretAnswers = secrets
        self.forbidQuestions = forbidQuestions
    }

    var io: QuickSetupIO {
        QuickSetupIO(
            say: { [unowned self] in self.out += $0 + "\n" },
            write: { [unowned self] in self.out += $0 },
            ask: { [unowned self] prompt in
                self.out += prompt; self.prompts.append(prompt)
                if self.forbidQuestions { self.askedWhenForbidden = true }
                guard !self.answers.isEmpty else { return nil }
                let a = self.answers.removeFirst()
                if let a { self.out += "\n" }   // the user's Enter
                return a
            },
            askSecret: { [unowned self] prompt in
                self.out += prompt + "\n"; self.prompts.append(prompt)
                if self.forbidQuestions { self.askedWhenForbidden = true }
                guard !self.secretAnswers.isEmpty else { return nil }
                return self.secretAnswers.removeFirst()
            })
    }

    func has(_ text: String) -> Bool { out.contains(text) }
}

@MainActor
enum QuickSetupTerminalBattery {
    final class Greetings: @unchecked Sendable { var sent: [(token: String, chatId: String, text: String)] = []; var fail: String?; var macStarts = 0; var macRefusal: String? }

    static func run(tempRoot: URL) async -> (Int, Int) {
        let t = MenuSelftestContext(tempRoot: tempRoot)
        await battery(t)
        return (t.checks, t.failures)
    }

    /// A fresh install as the real menu sees it: nothing saved, free search on.
    static func freshWorld(_ t: MenuSelftestContext) -> MenuFakeWorld {
        let w = t.world()
        w.snap.freeSearchOn = true
        return w
    }

    static func workflow(_ t: MenuSelftestContext, _ w: MenuFakeWorld, linux: Bool = false,
                         tweak: (inout MenuEnvironment) -> Void = { _ in }) async -> MenuWorkflow {
        var e = t.env(w, linux: linux)
        // FDA turns on when the user flips the switch in System Settings.
        e.quick.openSettingsPane = { w.settingsOpened += 1; w.fda = true; w.snap.fdaGranted = true }
        // Linux service seams: never the real systemd.
        e.systemdSessionAvailable = { true }
        e.quick.installUnit = {}
        e.quick.enableService = { _ in nil }
        e.quick.serviceEvidence = { (true, true, "active, stable") }
        e.quick.stopService = { true }
        e.quick.releaseLease = {}
        e.quick.reacquireLease = { true }
        tweak(&e)
        let wf = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
        wf.now = { w.clock }
        wf.optionalItems = [.computer, .tools]
        await wf.start()
        await wf.settle()
        return wf
    }

    static func system(_ w: MenuFakeWorld, _ g: Greetings, ssh: Bool = false, wait: TimeInterval = 120) -> QuickSetupFlow.System {
        var s = QuickSetupFlow.System(
            isSSH: ssh, computerName: "Test Mac",
            sendGreeting: { token, chatId, text in g.sent.append((token, chatId, text)); return g.fail },
            botToken: { w.snap.telegramConfigured ? w.good["telegram"] : nil },
            startMac: { g.macStarts += 1; return g.macRefusal },
            sleep: { seconds in w.clock = w.clock.addingTimeInterval(seconds); try? await Task.sleep(nanoseconds: 2_000_000) },
            now: { w.clock })
        s.telegramWait = wait
        return s
    }

    static func battery(_ t: MenuSelftestContext) async {
        let good = MenuFakeWorld(toolMarker: URL(fileURLWithPath: "/nonexistent")).good
        let chat = "5551234567"

        // ── A. Interactive Mac, every screen of the spec.
        do {
            let w = freshWorld(t)
            w.scan = .found(chatId: chat, name: "Sofia (@sofia)")
            let g = Greetings()
            let wf = await workflow(t, w)
            let script = QuickSetupScript(answers: ["Sofia", ""], secrets: ["sk-or-wrong-0123456789", good["openrouter"]!, good["telegram"]!, good["agentmail"]!])
            let flow = QuickSetupFlow(menu: wf, options: QuickSetupOptions(), secrets: QuickSetupSecrets(), io: script.io, system: system(w, g))
            let result = await flow.run()
            let o = script.out
            t.check("qs A: interactive Mac run ends ready to start the chat here", result == .macStarting, o)
            t.check("qs A: header (spec)", o.contains("""
                ── Briglia quick setup ──
                OpenRouter + Telegram + free web search. About 5 minutes (plus media tools).
                You need: an OpenRouter API key (https://openrouter.ai/keys) and a Telegram bot token from @BotFather.
                For ChatGPT, OpenCode Go or local servers, use instead: briglia setup
                """))
            t.check("qs A: [1/5] name asked as the spec says, typed by the user",
                    o.contains("[1/5] Your name\nWhat should Bree call you?\n> ") && o.contains("✔ Hi, Sofia. (Your name is also the confirm word for /deleteuserdata.)"))
            t.check("qs A: [2/5] wrong key → spec refusal, asked again", o.contains("[2/5] OpenRouter\nPaste your OpenRouter API key (hidden): ")
                    && o.contains("Checking… ✖ OpenRouter refused this key. Paste it again, or Ctrl-C to stop.") && o.contains("Checking… ✔ The key works."))
            t.check("qs A: main model = the shared 1017 default, hosted on Together",
                    o.contains("✔ Main model: \(MenuWorkflow.openRouterDefaultLabel), hosted on Together. Change it anytime with /model or briglia menu.")
                    && MenuWorkflow.openRouterDefaultModel == ProviderProfiles.openRouterSetupDefaultModel, o)
            t.check("qs A: free web lines (Parallel privacy, keyless Jina)",
                    o.contains("✔ Web search: free with Parallel, no account. Searches go to Parallel and may be used to train their models. For more privacy, add a Serper.dev key later in briglia menu.")
                    && o.contains("✔ Reading web pages: free with Jina, no key. Some sites (e.g. Reddit) block free reading. Add a Jina key later for more reliable reading."))
            t.check("qs A: the removed OpenAI sentence is not shown", !o.contains("No OpenAI key needed") && !o.contains("Voice, images and OCR"))
            t.check("qs A: [3/5] Telegram token, bot, /start wait, paired",
                    o.contains("[3/5] Telegram\nIn Telegram, message @BotFather, send /newbot, follow the steps, then paste the token here (hidden): ")
                    && o.contains("Checking… ✔ Bot: @sofia_test_bot") && o.contains("Now send /start to @sofia_test_bot in Telegram. Waiting…")
                    && o.contains("✔ Paired with Sofia (@sofia). Only this account can talk to Bree."), o)
            t.check("qs A: [4/5] AgentMail optional, inbox reported",
                    o.contains("[4/5] Email (optional)\nGive Bree its own email inbox with AgentMail? Paste an AgentMail API key, or press Enter to skip. You can add it later in briglia menu.\n> ")
                    && o.contains("✔ AgentMail works. Inbox: bree@agentmail.to") && w.agentMailInstalls == 1)
            t.check("qs A: [5/5] Full Disk Access: System Settings opened, Enter re-checks",
                    o.contains("[5/5] This computer") && o.contains("System Settings is opening at Privacy & Security › Full Disk Access: turn on \"Terminal\", then press Enter here. (Enter without enabling it = skip; Bree works with less access.)")
                    && w.settingsOpened == 1 && o.contains("✔ Full Disk Access granted"))
            t.check("qs A: keep-awake and media tools",
                    o.contains("✔ Keep awake: this Mac won't sleep while Briglia is running")
                    && o.contains("Installing media tools (ffmpeg, ImageMagick, poppler, LibreOffice, Python packages). This can take 5–15 minutes…")
                    && o.contains("✔ ffmpeg ✔ ImageMagick ✔ poppler ✔ LibreOffice ✔ Python") && FileManager.default.fileExists(atPath: w.toolMarker.path))
            t.check("qs A: setup marked complete through the menu, then the Mac chat lease taken once", w.markedComplete && g.macStarts == 1)
            t.check("qs A: Bree's first Telegram message (spec text) to the paired chat",
                    g.sent.count == 1 && g.sent.first?.chatId == chat && g.sent.first?.token == good["telegram"]
                    && g.sent.first?.text == "Hi Sofia, I'm Bree, your assistant on Test Mac. Ask me anything, by text or voice message.", "\(g.sent.map(\.text))")
            t.check("qs A: finish lines (spec, Mac)",
                    o.contains("Starting Briglia…\n✓ Done! Bree has just written to you on Telegram.\nBriglia is running in this window. Keep it open (you can minimize it). To change settings, open a new terminal window and type briglia menu."))
            t.check("qs A: summary block",
                    o.contains("Summary:\n  Name: Sofia\n  Model: \(MenuWorkflow.openRouterDefaultLabel) (OpenRouter, Together)\n  Search: free (Parallel) · Page reading: free (Jina)\n  Email: AgentMail (bree@agentmail.to)\n  Telegram: @sofia_test_bot\n  Full Disk Access ✔ · Keep awake ✔ · Media tools ✔\nTo change anything: briglia menu (browser) or briglia setup (terminal)."), o)
            let sections = w.applied.flatMap { Array($0.keys) }
            let provider = w.applied.compactMap { $0["provider"] as? [String: Any] }.first
            t.check("qs A: every save went through the settings writer seam (identity, provider, telegram, email)",
                    sections.contains("identity") && sections.contains("telegram") && sections.contains("email_calendar")
                    && provider?["profile"] as? String == "openrouter" && provider?["model"] as? String == MenuWorkflow.openRouterDefaultModel
                    && provider?["activate"] as? Bool == true && w.snap.activeProfile == "openrouter", "\(sections)")
            t.check("qs A: nothing written around the writer (the real store under the temp root is untouched)",
                    KeychainHelper.load(key: KeychainHelper.userNameKey) == nil && KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) == nil)
            t.check("qs A: no key ever printed", [good["openrouter"]!, good["telegram"]!, good["agentmail"]!, "sk-or-wrong-0123456789"].allSatisfy { !o.contains($0) })
            t.check("qs A: no spending cap anywhere", !o.lowercased().contains("spending") && !sections.contains("spend"))
            t.check("qs A: the Telegram pairing step released its hold", !wf.env.pairing.held)
            await wf.shutdown()
        }

        // ── B. Non-interactive (--yes), chat ID given, no tools, Enter-less.
        do {
            let w = freshWorld(t)
            let g = Greetings()
            let wf = await workflow(t, w)
            let script = QuickSetupScript(forbidQuestions: true)
            let options = QuickSetupOptions(name: "Dev", yes: true, telegramChatId: chat, noTools: true)
            let secrets = QuickSetupSecrets(openRouter: good["openrouter"], telegram: good["telegram"], agentMail: nil)
            let result = await QuickSetupFlow(menu: wf, options: options, secrets: secrets, io: script.io, system: system(w, g)).run()
            let o = script.out
            t.check("qs B: --yes completes with no question asked", result == .macStarting && !script.askedWhenForbidden && script.prompts.isEmpty, o)
            t.check("qs B: --telegram-chat-id skips the /start wait (no scan)", w.scanCount == 0 && !o.contains("Waiting…") && w.snap.telegramChatId == chat)
            t.check("qs B: email skipped, FDA skipped with a note, tools skipped",
                    o.contains("– Email skipped") && o.contains("– Full Disk Access skipped (--yes).") && o.contains("– Media tools skipped (--no-tools).")
                    && !FileManager.default.fileExists(atPath: w.toolMarker.path) && w.settingsOpened == 0)
            t.check("qs B: setup completes without Full Disk Access or tools (optional in quick setup)", w.markedComplete)
            t.check("qs B: summary marks the skipped rows", o.contains("Full Disk Access ✖ · Keep awake ✔ · Media tools skipped") && o.contains("Email: not set"))
            await wf.shutdown()
        }

        // ── C. --yes with a refused key: stops at once, nothing else touched.
        do {
            let w = freshWorld(t)
            let g = Greetings()
            let wf = await workflow(t, w)
            let script = QuickSetupScript(forbidQuestions: true)
            let result = await QuickSetupFlow(menu: wf, options: QuickSetupOptions(name: "Dev", yes: true, telegramChatId: chat),
                                              secrets: QuickSetupSecrets(openRouter: "sk-or-wrong-0123456789", telegram: good["telegram"]),
                                              io: script.io, system: system(w, g)).run()
            t.check("qs C: --yes with a refused OpenRouter key → exit 1 at step 2",
                    result == .failed(1) && script.has("✖ OpenRouter refused this key.") && !script.has("Paste it again") && !script.askedWhenForbidden)
            t.check("qs C: no provider, Telegram or completion written", !w.applied.contains { $0["provider"] != nil || $0["telegram"] != nil } && !w.markedComplete && g.sent.isEmpty)
            await wf.shutdown()
        }

        // ── D. --yes prerequisites (checked before anything runs).
        do {
            let none = QuickSetupSecrets()
            let yes = QuickSetupOptions(yes: true)
            let msg = QuickSetupFlow.missingForNonInteractive(yes, secrets: none, savedName: "", openRouterSaved: false, telegramSaved: false) ?? ""
            t.check("qs D: --yes without name/keys names exactly what is missing",
                    msg.contains("--name") && msg.contains("BRIGLIA_OPENROUTER_KEY") && msg.contains("BRIGLIA_TELEGRAM_TOKEN") && !msg.contains("BRIGLIA_AGENTMAIL_KEY"), msg)
            t.check("qs D: interactive mode needs nothing up front",
                    QuickSetupFlow.missingForNonInteractive(QuickSetupOptions(), secrets: none, savedName: "", openRouterSaved: false, telegramSaved: false) == nil)
            t.check("qs D: --yes on a resumed install may use the saved name and keys",
                    QuickSetupFlow.missingForNonInteractive(yes, secrets: none, savedName: "Sofia", openRouterSaved: true, telegramSaved: true) == nil)
            setenv(QuickSetupSecrets.openRouterVar, " sk-or-env-0123456789 ", 1)
            setenv(QuickSetupSecrets.telegramVar, "123:AAenvtoken", 1)
            unsetenv(QuickSetupSecrets.agentMailVar)
            let taken = QuickSetupSecrets.takeFromEnvironment()
            t.check("qs D: keys are read from the environment once and removed from it (children never inherit them)",
                    taken.openRouter == "sk-or-env-0123456789" && taken.telegram == "123:AAenvtoken" && taken.agentMail == nil
                    && getenv(QuickSetupSecrets.openRouterVar) == nil && getenv(QuickSetupSecrets.telegramVar) == nil)
            t.check("qs D: the installer runner redacts the keys", taken.redactions.values.sorted() == ["123:AAenvtoken", "sk-or-env-0123456789"])
        }

        // ── E. Linux: one sudo for tools + keep-awake, then the service.
        do {
            let w = freshWorld(t)
            w.snap.keepAwakeOK = false
            w.snap.keepAwakeMaskable = true
            w.snap.keepAwakeSummary = "systemd sleep targets are not masked"
            let masked = t.tempRoot.appendingPathComponent("masked-\(UUID().uuidString)")
            let g = Greetings()
            let wf = await workflow(t, w, linux: true) { e in
                e.quick.maskSleepTargetsJob = {
                    SetupJobRunner.Spec(row: "keepawake", command: ["/bin/sh", "-c", "touch '\(masked.path)'"], mode: .detached, timeout: 30, label: "sudo systemctl mask sleep targets")
                }
                let base = e.snapshot
                e.snapshot = { var s = await base(); if FileManager.default.fileExists(atPath: masked.path) { s.keepAwakeOK = true; w.snap.keepAwakeOK = true }; return s }
            }
            let script = QuickSetupScript(forbidQuestions: true)
            let result = await QuickSetupFlow(menu: wf, options: QuickSetupOptions(name: "Lin", yes: true, telegramChatId: chat),
                                              secrets: QuickSetupSecrets(openRouter: good["openrouter"], telegram: good["telegram"]),
                                              io: script.io, system: system(w, g)).run()
            let o = script.out
            t.check("qs E: Linux run ends with the background service running", result == .linuxRunning && wf.closing == "start", o)
            t.check("qs E: one sudo notice, tools, keep-awake (spec)",
                    o.contains("The media tools and keep-awake need your password once (sudo):") && o.contains("✔ media tools ✔ python3-venv")
                    && o.contains("✔ Keep awake: sleep is turned off on this computer"), o)
            t.check("qs E: background service line, Linux finish and summary",
                    o.contains("✔ Background service: Briglia starts at boot and stays on after you log out")
                    && o.contains("✓ Done! Bree has just written to you on Telegram.\nBriglia is running in the background.")
                    && o.contains("Keep awake ✔ · Media tools ✔ · Background service ✔") && !o.contains("Full Disk Access"), o)
            t.check("qs E: no Mac start on Linux", g.macStarts == 0 && g.sent.count == 1)
            await wf.shutdown()
        }

        // ── F. Telegram: the scan fails (another program), a new token is asked, then pairing works.
        do {
            let w = freshWorld(t)
            var scans = 0
            let g = Greetings()
            let wf = await workflow(t, w) { e in
                e.telegramScan = { _, _ in
                    scans += 1
                    return scans == 1 ? .failed("Another program is using this bot right now (maybe Briglia on another computer). Stop it, or create a new bot for this one.")
                                      : .found(chatId: chat, name: "Sofia (@sofia)")
                }
            }
            let script = QuickSetupScript(answers: ["Sofia", ""], secrets: [good["openrouter"]!, good["telegram"]!, good["telegram"]!, ""])
            let result = await QuickSetupFlow(menu: wf, options: QuickSetupOptions(noTools: true), secrets: QuickSetupSecrets(),
                                              io: script.io, system: system(w, g)).run()
            let o = script.out
            t.check("qs F: a failed scan is reported and the token asked again, then pairing completes",
                    result == .macStarting && o.contains("✖ Another program is using this bot") && o.components(separatedBy: "✔ Bot: @sofia_test_bot").count == 3
                    && o.contains("✔ Paired with Sofia (@sofia)."), o)
            t.check("qs F: Enter skips email", o.contains("– Email skipped") && w.agentMailInstalls == 0)
            await wf.shutdown()
        }

        // ── G. Telegram: nobody sends /start → bounded wait, pairing released, nothing saved.
        do {
            let w = freshWorld(t)
            w.scan = .waiting
            let g = Greetings()
            let wf = await workflow(t, w)
            let script = QuickSetupScript(forbidQuestions: true)
            let result = await QuickSetupFlow(menu: wf, options: QuickSetupOptions(name: "Dev", yes: true),
                                              secrets: QuickSetupSecrets(openRouter: good["openrouter"], telegram: good["telegram"]),
                                              io: script.io, system: system(w, g, wait: 10)).run()
            t.check("qs G: no /start within the wait → exit 1 with a clear message",
                    result == .failed(1) && script.has("✖ No /start reached @sofia_test_bot"), script.out)
            t.check("qs G: pairing released, Telegram not saved, setup not complete",
                    !wf.env.pairing.held && !w.snap.telegramConfigured && !w.markedComplete && w.scanCount > 0)
            await wf.shutdown()
        }

        // ── H. Input closed at the first question.
        do {
            let w = freshWorld(t)
            let g = Greetings()
            let wf = await workflow(t, w)
            let script = QuickSetupScript()
            let result = await QuickSetupFlow(menu: wf, options: QuickSetupOptions(), secrets: QuickSetupSecrets(), io: script.io, system: system(w, g)).run()
            t.check("qs H: closed input stops cleanly (exit 1), nothing saved",
                    result == .failed(1) && script.has("Input closed — stopping here.") && w.applied.isEmpty)
            await wf.shutdown()
        }

        // ── I. Together not available: the host line says OpenRouter chooses.
        do {
            let w = freshWorld(t)
            w.orHostsFail = true
            let g = Greetings()
            let wf = await workflow(t, w)
            let script = QuickSetupScript(forbidQuestions: true)
            _ = await QuickSetupFlow(menu: wf, options: QuickSetupOptions(name: "Dev", yes: true, telegramChatId: chat, noTools: true),
                                     secrets: QuickSetupSecrets(openRouter: good["openrouter"], telegram: good["telegram"]),
                                     io: script.io, system: system(w, g)).run()
            t.check("qs I: no host listing → no pin claimed, OpenRouter chooses the host",
                    script.has("✔ Main model: \(MenuWorkflow.openRouterDefaultLabel); OpenRouter chooses the host.") && !script.has("hosted on Together")
                    && script.has("  Model: \(MenuWorkflow.openRouterDefaultLabel) (OpenRouter)\n"), script.out)
            await wf.shutdown()
        }

        // ── J. Resumed install: saved key and bot kept; ChatGPT chosen earlier → switched to OpenRouter.
        do {
            let w = freshWorld(t)
            w.snap.userName = "Sofia"
            w.snap.chatgpt = .signedIn(active: true, model: "gpt-6.1-sol", effort: "high", generation: "g1")
            w.snap.activeProfile = "chatgpt"
            var p = MenuSnapshot.Provider(); p.configured = true; p.model = MenuWorkflow.openRouterDefaultModel; p.keyMasked = "sk-or…cdef"
            w.snap.providers["openrouter"] = p
            w.snap.telegramConfigured = true
            w.snap.telegramChatId = chat
            let g = Greetings()
            let wf = await workflow(t, w)
            let script = QuickSetupScript(forbidQuestions: true)
            let result = await QuickSetupFlow(menu: wf, options: QuickSetupOptions(yes: true, noTools: true), secrets: QuickSetupSecrets(),
                                              io: script.io, system: system(w, g)).run()
            t.check("qs J: --yes on a resumed install keeps the saved name, key and bot",
                    result == .macStarting && script.has("✔ Hi, Sofia.") && script.has("✔ Keeping the saved OpenRouter key.")
                    && script.has("✔ Keeping the Telegram bot that is already connected."), script.out)
            t.check("qs J: quick setup is OpenRouter-only: the earlier ChatGPT choice is switched to OpenRouter",
                    w.snap.activeProfile == "openrouter" && wf.activeLane == .openrouter)
            t.check("qs J: no key re-sent for the kept OpenRouter key", !w.applied.contains { ($0["provider"] as? [String: Any])?["api_key"] != nil })
            await wf.shutdown()
        }

        // ── K. The greeting can't be sent: setup still done, the user is told.
        do {
            let w = freshWorld(t)
            let g = Greetings(); g.fail = "Telegram answered HTTP 403"
            let wf = await workflow(t, w)
            let script = QuickSetupScript(forbidQuestions: true)
            let result = await QuickSetupFlow(menu: wf, options: QuickSetupOptions(name: "Dev", yes: true, telegramChatId: chat, noTools: true),
                                              secrets: QuickSetupSecrets(openRouter: good["openrouter"], telegram: good["telegram"]),
                                              io: script.io, system: system(w, g)).run()
            t.check("qs K: a failed greeting doesn't fail setup and says why",
                    result == .macStarting && script.has("first Telegram message couldn't be sent: Telegram answered HTTP 403") && !script.has("has just written to you"))
            await wf.shutdown()
        }

        // ── L. Over SSH a Mac skips Full Disk Access with a note (no System Settings).
        do {
            let w = freshWorld(t)
            let g = Greetings()
            let wf = await workflow(t, w)
            let script = QuickSetupScript(answers: ["Sofia"], secrets: [good["openrouter"]!, good["telegram"]!, ""])
            let result = await QuickSetupFlow(menu: wf, options: QuickSetupOptions(telegramChatId: chat, noTools: true), secrets: QuickSetupSecrets(),
                                              io: script.io, system: system(w, g, ssh: true)).run()
            t.check("qs L: SSH → Full Disk Access skipped with a note, System Settings not opened",
                    result == .macStarting && script.has("– Full Disk Access skipped: it can't be granted over SSH.") && w.settingsOpened == 0, script.out)
            await wf.shutdown()
        }

        // ── M. A Briglia started meanwhile holds the chat lease: setup saved, told where it runs.
        do {
            let w = freshWorld(t)
            let g = Greetings(); g.macRefusal = "Briglia is already running in another window."
            let wf = await workflow(t, w)
            let script = QuickSetupScript(forbidQuestions: true)
            let result = await QuickSetupFlow(menu: wf, options: QuickSetupOptions(name: "Dev", yes: true, telegramChatId: chat, noTools: true),
                                              secrets: QuickSetupSecrets(openRouter: good["openrouter"], telegram: good["telegram"]),
                                              io: script.io, system: system(w, g)).run()
            t.check("qs M: lease taken elsewhere → exit 1, no greeting, setup kept",
                    result == .failed(1) && g.sent.isEmpty && w.markedComplete && script.has("✖ Briglia is already running in another window."))
            await wf.shutdown()
        }
    }
}
