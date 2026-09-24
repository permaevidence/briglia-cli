import Foundation

/// One row of the menu. Order = the guided first-run order.
enum MenuItem: String, CaseIterable {
    case name, chatgpt, telegram, serper, jina, openai, email, computer, tools

    var title: String {
        switch self {
        case .name: return "Your name"
        case .chatgpt: return "ChatGPT"
        case .telegram: return "Telegram"
        case .serper: return "Web search"
        case .jina: return "Reading web pages"
        case .openai: return "Voice & images"
        case .email: return "Email"
        case .computer: return "This computer"
        case .tools: return "Document & media tools"
        }
    }

    var required: Bool { self != .openai && self != .email }

    func title(_ lang: String) -> String {
        guard lang == "it" else { return title }
        switch self {
        case .name: return "Il tuo nome"
        case .chatgpt: return "ChatGPT"
        case .telegram: return "Telegram"
        case .serper: return "Ricerca web"
        case .jina: return "Lettura pagine web"
        case .openai: return "Voce e immagini"
        case .email: return "Email"
        case .computer: return "Questo computer"
        case .tools: return "Strumenti documenti e media"
        }
    }
}

/// The server side of the `briglia menu` page (menu.html/menu.js): every
/// page action is one call that checks AND saves (no separate verify step),
/// and `status()` is the whole page state. Side effects go through
/// `MenuEnvironment`, so the selftest drives the real flows with fakes.
@MainActor
final class MenuWorkflow {
    let env: MenuEnvironment
    let runner: SetupJobRunner
    /// Linux: the background service was running when the menu opened (it
    /// was paused and comes back when the menu closes).
    let serviceWasRunning: Bool
    /// Clock seam for the selftest's polling rows.
    var now: () -> Date = { Date() }
    /// Page language, "en" or "it" (the page's flag switch; first guess from
    /// the system language).
    private(set) var lang: String

    /// Localized text: English or Italian.
    func L(_ en: String, _ it: String) -> String { lang == "it" ? it : en }

    private(set) var snapshot = MenuSnapshot()
    private(set) var toolchain: ToolchainService.DesktopStatus?
    private var toolchainTask: Task<Void, Never>?
    private(set) var closing: String?

    // ChatGPT sign-in in progress.
    struct Login { var kind: String; var state: String; var url: String?; var code: String?; var message: String? }
    private(set) var login: Login?
    private var loginTask: Task<Void, Never>?
    private var loginAttempt: UUID?

    // Telegram pairing in progress (the token never leaves the server).
    struct TelegramPending { var token: String; var bot: String; var state: String; var name: String?; var chatId: String?; var since: Date; var lastScan: Date; var rejected: Set<String> = [] }
    private(set) var telegram: TelegramPending?
    private var scanInFlight = false

    // Background work (tools install, email tool, never-sleep).
    private(set) var busy: String?
    private(set) var jobLines: [String] = []
    private(set) var jobLabel = ""
    private(set) var toolsError: String?
    private var pending: [Task<Void, Never>] = []

    init(env: MenuEnvironment, runner: SetupJobRunner, serviceWasRunning: Bool = false) {
        self.env = env
        self.runner = runner
        self.serviceWasRunning = serviceWasRunning
        self.lang = env.language
        runner.onLine = { [weak self] line in Task { @MainActor [weak self] in self?.appendJobLine(line) } }
    }

    func start() async {
        await reload()
        refreshToolchain()
    }

    func reload() async {
        snapshot = await env.snapshot()
        markCompleteIfReady()
    }

    func refreshToolchain() {
        toolchain = nil
        toolchainTask?.cancel()
        toolchainTask = Task { [weak self] in
            guard let self else { return }
            let status = await self.env.toolchainStatus()
            guard !Task.isCancelled else { return }
            self.toolchain = status
            self.markCompleteIfReady()
        }
    }

    /// Waits for every background operation (selftest).
    func settle() async {
        await toolchainTask?.value
        await loginTask?.value
        while !pending.isEmpty { let p = pending; pending = []; for t in p { await t.value } }
    }

    func shutdown() {
        loginTask?.cancel()
        toolchainTask?.cancel()
    }

    // MARK: Status

    func isDone(_ item: MenuItem) -> Bool {
        let s = snapshot
        switch item {
        case .name: return !s.userName.isEmpty
        case .chatgpt: return s.chatgptReady
        case .telegram: return s.telegramConfigured
        case .serper: return s.serperMasked != nil
        case .jina: return s.jinaMasked != nil
        case .openai: return s.openAIMasked != nil
        case .email: return s.emailProvider == "agentmail" && s.agentMailMasked != nil
        case .computer: return (env.isLinux || s.fdaGranted) && s.keepAwakeOK
        case .tools: return toolchain?.complete == true
        }
    }

    var missingRequired: [MenuItem] { MenuItem.allCases.filter { $0.required && !isDone($0) } }

    private func markCompleteIfReady() {
        guard !snapshot.setupComplete, toolchain != nil, missingRequired.isEmpty else { return }
        if (try? env.markComplete()) != nil { snapshot.setupComplete = true }
    }

    static func modelLabel(_ id: String) -> String {
        ResponsesAdapter.subscriptionModelChoices.first { $0.id == id }?.label ?? id
    }

    func summary(_ item: MenuItem) -> String {
        let s = snapshot
        switch item {
        case .name: return s.userName.isEmpty ? L("Not set", "Da impostare") : s.userName
        case .chatgpt:
            switch s.chatgpt {
            case .signedIn(let active, let model, _, _): return active ? Self.modelLabel(model) : L("Signed in, not in use", "Accesso fatto, non in uso")
            case .loginRequired: return L("Sign in again", "Accedi di nuovo")
            case .signedOut: return L("Not signed in", "Accesso non fatto")
            }
        case .telegram: return s.telegramConfigured ? L("Connected", "Collegato") : L("Not connected", "Non collegato")
        case .serper: return s.serperMasked.map { L("Key", "Chiave") + " \($0)" } ?? L("Not set", "Da impostare")
        case .jina: return s.jinaMasked.map { L("Key", "Chiave") + " \($0)" } ?? L("Not set", "Da impostare")
        case .openai: return s.openAIMasked.map { L("Key", "Chiave") + " \($0)" } ?? L("Not set", "Non impostata")
        case .email:
            if isDone(.email) { return s.agentMailInbox.isEmpty ? L("On", "Attiva") : s.agentMailInbox }
            return L("Off", "Disattivata")
        case .computer:
            if !env.isLinux && !s.fdaGranted { return L("Needs Full Disk Access", "Serve l\u{2019}Accesso completo al disco") }
            return s.keepAwakeOK ? L("Ready", "Pronto") : L("May go to sleep", "Potrebbe andare in sospensione")
        case .tools:
            guard let t = toolchain else { return L("Checking…", "Controllo…") }
            if t.complete { return L("Installed", "Installati") }
            return L("\(missingTools(t).count) missing", "\(missingTools(t).count) mancanti")
        }
    }

    private func missingTools(_ t: ToolchainService.DesktopStatus) -> [String] {
        t.mandatoryMissing + (t.libreOffice ? [] : ["LibreOffice"])
    }

    /// The whole page state. Polling side effects live here: re-checking Full
    /// Disk Access and scanning Telegram for the user's first message.
    func status() -> [String: Any] {
        pollOutsideWorld()
        let s = snapshot
        let steps: [[String: Any]] = MenuItem.allCases.map {
            ["id": $0.rawValue, "title": $0.title(lang), "required": $0.required, "done": isDone($0), "summary": summary($0)]
        }
        var chatgpt: [String: Any] = ["models": ResponsesAdapter.subscriptionModelChoices.map {
            ["id": $0.id, "label": $0.label, "recommended": $0.id == ResponsesAdapter.subscriptionDefaultModel] as [String: Any]
        }]
        switch s.chatgpt {
        case .signedIn(let active, let model, let effort, _):
            chatgpt["state"] = "signed_in"; chatgpt["active"] = active; chatgpt["model"] = model
            chatgpt["model_label"] = Self.modelLabel(model); chatgpt["effort"] = effort
        case .loginRequired: chatgpt["state"] = "login_required"
        case .signedOut: chatgpt["state"] = "signed_out"
        }
        if let other = s.otherProvider { chatgpt["other_provider"] = other }
        if let login {
            var l: [String: Any] = ["kind": login.kind, "state": login.state]
            if let u = login.url { l["url"] = u }
            if let c = login.code { l["code"] = c }
            if let m = login.message { l["message"] = m }
            chatgpt["login"] = l
        }
        var tg: [String: Any] = ["configured": s.telegramConfigured, "chat_id": s.telegramChatId]
        if let b = telegramBot { tg["bot"] = b }
        if let e = lastTelegramError { tg["error"] = e }
        if let p = telegram {
            var d: [String: Any] = ["bot": p.bot, "state": p.state]
            if let n = p.name { d["name"] = n }
            if let c = p.chatId { d["chat_id"] = c }
            tg["pending"] = d
        }
        var keys: [String: Any] = [:]
        for (k, v) in [("serper", s.serperMasked), ("jina", s.jinaMasked), ("openai", s.openAIMasked), ("agentmail", s.agentMailMasked)] {
            keys[k] = v ?? NSNull()
        }
        var tools: [String: Any] = ["checking": toolchain == nil, "installing": busy == "tools", "label": jobLabel, "lines": Array(jobLines.suffix(60))]
        if let t = toolchain { tools["complete"] = t.complete; tools["missing"] = missingTools(t) }
        if let e = toolsError { tools["error"] = e }
        var out: [String: Any] = [
            "platform": env.isLinux ? "linux" : "macos",
            "lang": lang,
            "complete": snapshot.setupComplete || (toolchain != nil && missingRequired.isEmpty),
            "steps": steps, "name": s.userName, "chatgpt": chatgpt, "telegram": tg, "keys": keys,
            "email": ["on": isDone(.email), "inbox": s.agentMailInbox, "tool_installed": s.agentMailCLIInstalled] as [String: Any],
            "computer": ["fda": s.fdaGranted, "terminal_app": s.terminalApp, "keep_awake_ok": s.keepAwakeOK,
                         "keep_awake_summary": env.isLinux ? s.keepAwakeSummary : L("Briglia keeps this Mac awake while it runs (a closed lid or a manual sleep still stops it).", "Briglia tiene sveglio questo Mac mentre è in funzione (chiudere il coperchio o mettere in stop lo ferma comunque)."), "can_fix_gnome": s.keepAwakeGnomeFixable,
                         "can_mask": s.keepAwakeMaskable] as [String: Any],
            "tools": tools,
            "service_was_running": serviceWasRunning,
            "browser_likely": env.browserLikely,
        ]
        out["busy"] = busy ?? NSNull()
        out["closing"] = closing ?? NSNull()
        return out
    }

    private var lastFDACheck = Date.distantPast
    private func pollOutsideWorld() {
        if !env.isLinux, !snapshot.fdaGranted, now().timeIntervalSince(lastFDACheck) >= 1.5 {
            lastFDACheck = now()
            if env.quick.fullDiskAccessGranted() { snapshot.fdaGranted = true; markCompleteIfReady() }
        }
        guard var p = telegram, p.state == "waiting", !scanInFlight, now().timeIntervalSince(p.lastScan) >= 2 else { return }
        p.lastScan = now()
        telegram = p
        scanInFlight = true
        let token = p.token, since = p.since
        let t = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.env.telegramScan(token, since)
            self.scanInFlight = false
            guard var current = self.telegram, current.token == token, current.state == "waiting" else { return }
            switch result {
            case .waiting: break
            case .found(let chatId, _) where current.rejected.contains(chatId):
                break   // the person said "not me": keep waiting for someone else
            case .found(let chatId, let name):
                current.state = "found"; current.chatId = chatId; current.name = name
                self.telegram = current
            case .failed(let why):
                self.telegram = nil
                self.lastTelegramError = self.telegramScanFailure(why)
            }
        }
        pending.append(t)
    }
    /// A scan failure surfaces on the next action's reply (and in status).
    private(set) var lastTelegramError: String?

    // MARK: Actions

    /// One page action → `{ok, message?, status}`.
    func handle(_ body: [String: Any]) async -> [String: Any] {
        let action = body["action"] as? String ?? ""
        let (ok, message) = await perform(action, body)
        var out: [String: Any] = ["ok": ok, "status": status()]
        if let message { out["message"] = message }
        return out
    }

    private func str(_ body: [String: Any], _ key: String) -> String {
        ((body[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func perform(_ action: String, _ body: [String: Any]) async -> (Bool, String?) {
        guard closing == nil else { return (false, L("This page is closing.", "Questa pagina si sta chiudendo.")) }
        switch action {
        case "lang":
            let value = str(body, "lang")
            guard value == "en" || value == "it" else { return (false, nil) }
            lang = value
            return (true, nil)

        case "name":
            let name = str(body, "name")
            guard !name.isEmpty, name.count <= 100 else { return (false, L("Type your name first.", "Scrivi prima il tuo nome.")) }
            let result = await env.apply(["identity": ["user_name": name]])
            await reload()
            return result["ok"] as? Bool == true ? (true, L("Nice to meet you, \(name)!", "Piacere di conoscerti, \(name)!")) : (false, applyError(result))

        case "key":
            return await saveKey(kind: str(body, "kind"), key: str(body, "key"))

        case "key_remove":
            guard str(body, "kind") == "openai" else { return (false, L("Only the optional OpenAI key can be removed.", "Si può rimuovere solo la chiave OpenAI, che è facoltativa.")) }
            let result = await env.apply(["openai": ["remove": true]])
            await reload()
            return result["ok"] as? Bool == true ? (true, L("Key removed. Voice messages and image creation are off.", "Chiave rimossa. Messaggi vocali e creazione di immagini sono disattivati.")) : (false, applyError(result))

        case "email_off":
            let result = await env.apply(["email_calendar": ["provider": "none"]])
            await reload()
            return result["ok"] as? Bool == true ? (true, L("Email is off. Your key is kept, so you can turn it back on any time.", "Email disattivata. La chiave resta salvata, così puoi riattivarla quando vuoi.")) : (false, applyError(result))

        case "email_tool":
            guard busy == nil else { return (false, L("Please wait for the current installation to finish.", "Aspetta che finisca l\u{2019}installazione in corso.")) }
            startEmailToolInstall()
            return (true, nil)

        case "chatgpt_browser", "chatgpt_code":
            return await startSignIn(browser: action == "chatgpt_browser")

        case "chatgpt_cancel":
            loginTask?.cancel(); loginTask = nil; loginAttempt = nil; login = nil
            return (true, L("Sign-in cancelled.", "Accesso annullato."))

        case "chatgpt_logout":
            let again = body["again"] as? Bool == true
            let result = await env.subscription(["action": "logout"])
            await reload()
            guard result["ok"] as? Bool == true else { return (false, applyError(result)) }
            return (true, again ? L("Signed out. Now sign in with the account you want.", "Disconnesso. Ora accedi con l\u{2019}account che vuoi usare.") : L("Signed out. Briglia can\u{2019}t answer until you sign in again.", "Disconnesso. Briglia non può rispondere finché non accedi di nuovo."))

        case "chatgpt_model":
            let model = str(body, "model")
            guard ResponsesAdapter.subscriptionModelChoices.contains(where: { $0.id == model }) else { return (false, L("Unknown model.", "Modello sconosciuto.")) }
            let result = await env.subscription(["action": "select", "model": model, "effort": compatibleEffort(currentEffort ?? "high", model: model)])
            await reload()
            return result["ok"] as? Bool == true ? (true, L("Briglia now thinks with \(Self.modelLabel(model)).", "Ora Briglia ragiona con \(Self.modelLabel(model)).")) : (false, applyError(result))

        case "chatgpt_use":
            return await selectAndProbe()

        case "telegram_token":
            let token = str(body, "token")
            guard !token.isEmpty else { return (false, L("Paste the token from @BotFather first.", "Incolla prima il token di @BotFather.")) }
            guard token.contains(":"), token.count <= 200 else {
                return (false, L("That doesn\u{2019}t look like a bot token. It looks like 123456789:AAE\u{2026} \u{2014} copy the whole line from BotFather.", "Questo non sembra il token di un bot. Somiglia a 123456789:AAE\u{2026}: copia l\u{2019}intera riga da BotFather."))
            }
            let probe = await env.probe(["kind": "telegram", "token": token])
            guard probe["ok"] as? Bool == true else {
                return (false, L("Telegram didn\u{2019}t accept this token. Copy it again from @BotFather (the whole line, like 123456789:AAE\u{2026}).", "Telegram non ha accettato questo token. Copialo di nuovo da @BotFather (l\u{2019}intera riga, tipo 123456789:AAE\u{2026})."))
            }
            lastTelegramError = nil
            telegram = TelegramPending(token: token, bot: probe["bot_username"] as? String ?? "your_bot", state: "waiting",
                                       since: now(), lastScan: .distantPast)
            return (true, nil)

        case "telegram_wait":
            guard var p = telegram else { return (false, L("Paste your bot token first.", "Incolla prima il token del bot.")) }
            if p.state == "found", let rejected = p.chatId { p.rejected.insert(rejected) }
            p.state = "waiting"; p.name = nil; p.chatId = nil; p.since = now(); p.lastScan = .distantPast
            telegram = p
            return (true, nil)

        case "telegram_manual":
            guard var p = telegram else { return (false, L("Paste your bot token first.", "Incolla prima il token del bot.")) }
            p.state = "manual"; telegram = p
            return (true, nil)

        case "telegram_reset":
            telegram = nil
            return (true, nil)

        case "telegram_confirm":
            return await confirmTelegram(chatId: str(body, "chat_id"))

        case "fda_open":
            env.quick.openSettingsPane()
            return (true, L("System Settings is open. Turn on \(snapshot.terminalApp) in the list \u{2014} this page notices by itself.", "Impostazioni di Sistema è aperto. Attiva \(snapshot.terminalApp) nell\u{2019}elenco: questa pagina se ne accorge da sola."))

        case "keepawake":
            return await fixKeepAwake(how: str(body, "how"))

        case "recheck":
            await reload()
            refreshToolchain()
            return (true, nil)

        case "tools_install":
            return installTools()

        case "finish":
            let what = str(body, "what")
            guard what == "start" || what == "quit" else { return (false, L("Unknown choice.", "Scelta sconosciuta.")) }
            if what == "start" {
                let missing = missingRequired
                if toolchain == nil && missing == [.tools] { return (false, L("Still checking the document tools \u{2014} try again in a moment.", "Sto ancora controllando gli strumenti per i documenti: riprova tra un attimo.")) }
                guard missing.isEmpty else { return (false, L("Finish these first: ", "Prima completa: ") + missing.map { $0.title(lang) }.joined(separator: ", ") + ".") }
            }
            guard busy == nil else { return (false, L("Please wait for the current installation to finish.", "Aspetta che finisca l\u{2019}installazione in corso.")) }
            loginTask?.cancel()
            closing = what
            return (true, nil)

        default:
            return (false, L("Unknown action.", "Azione sconosciuta."))
        }
    }

    // MARK: Keys

    private func saveKey(kind: String, key: String) async -> (Bool, String?) {
        guard ["serper", "jina", "openai", "agentmail"].contains(kind) else { return (false, L("Unknown key.", "Chiave sconosciuta.")) }
        guard !key.isEmpty, key.count <= 4096, !key.contains(where: { $0.isNewline }) else { return (false, L("Paste your key first.", "Incolla prima la chiave.")) }
        let item: MenuItem = kind == "agentmail" ? .email : MenuItem(rawValue: kind)!
        let probe = await env.probe(["kind": kind, "api_key": key])
        guard probe["ok"] as? Bool == true else { return (false, keyError(item, Self.probeReason(probe))) }
        let payload: [String: Any] = kind == "agentmail"
            ? ["email_calendar": ["provider": "agentmail", "api_key": key, "install_cli": false] as [String: Any]]
            : [kind: ["api_key": key]]
        let result = await env.apply(payload)
        await reload()
        guard result["ok"] as? Bool == true else { return (false, applyError(result)) }
        if kind == "agentmail" {
            let inbox = (probe["inboxes"] as? [String])?.first.map { self.L(" Briglia\u{2019}s address: \($0).", " Indirizzo di Briglia: \($0).") } ?? ""
            if !snapshot.agentMailCLIInstalled && busy == nil { startEmailToolInstall() }
            return (true, L("Email connected.\(inbox)", "Email collegata.\(inbox)"))
        }
        return (true, keySavedMessage(item))
    }

    private func startEmailToolInstall() {
        busy = "email_tool"
        jobLines = []
        let t = Task { @MainActor [weak self] in
            guard let self else { return }
            let failure = await self.env.quick.installAgentMail({ line in
                Task { @MainActor [weak self] in self?.appendJobLine(line) }
            }, {}, self.runner)
            await self.reload()
            self.busy = nil
            if let failure { self.toolsError = self.L("The email tool didn\u{2019}t install: \(failure)", "Lo strumento email non si è installato: \(failure)") }
        }
        pending.append(t)
    }

    // MARK: ChatGPT

    private var currentModel: String? {
        if case .signedIn(_, let m, _, _) = snapshot.chatgpt { return m }
        return nil
    }
    private var currentEffort: String? {
        if case .signedIn(_, _, let e, _) = snapshot.chatgpt { return e }
        return nil
    }
    private func compatibleEffort(_ effort: String, model: String) -> String {
        ResponsesAdapter.allowedEfforts(model: model).contains(effort) ? effort : "high"
    }

    private func startSignIn(browser: Bool) async -> (Bool, String?) {
        loginTask?.cancel()
        let attempt = UUID()
        loginAttempt = attempt
        login = Login(kind: browser ? "browser" : "code", state: "starting")
        let openURL = env.openURL
        let loginEnv = env
        loginTask = Task { @MainActor [weak self] in
            do {
                if browser {
                    try await loginEnv.browserLogin { url in
                        openURL(url)
                        Task { @MainActor [weak self] in
                            guard let self, self.loginAttempt == attempt else { return }
                            self.login = Login(kind: "browser", state: "waiting", url: url)
                        }
                    }
                } else {
                    try await loginEnv.deviceLogin { url, code in
                        Task { @MainActor [weak self] in
                            guard let self, self.loginAttempt == attempt else { return }
                            self.login = Login(kind: "code", state: "waiting", url: url, code: code)
                        }
                    }
                }
                guard let self, self.loginAttempt == attempt, !Task.isCancelled else { return }
                self.login = Login(kind: browser ? "browser" : "code", state: "finishing")
                let (ok, message) = await self.selectAndProbe()
                guard self.loginAttempt == attempt else { return }
                self.loginAttempt = nil
                self.login = ok ? nil : Login(kind: browser ? "browser" : "code", state: "error", message: message)
            } catch {
                guard let self, self.loginAttempt == attempt, !Task.isCancelled else { return }
                self.loginAttempt = nil
                self.login = Login(kind: browser ? "browser" : "code", state: "error", message: loginError(error.localizedDescription, browser: browser))
            }
        }
        // Give the flow a moment to produce the link or code, so the page can
        // show it in the same reply.
        for _ in 0..<100 {
            if let l = login, l.state != "starting" { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let l = login, l.state == "error" { return (false, l.message) }
        return (true, nil)
    }

    /// After a successful login: save + activate the profile (keeping a
    /// previously chosen model), then one real request to prove it answers.
    private func selectAndProbe() async -> (Bool, String?) {
        let model = currentModel ?? ProviderProfiles.configuredModel(.chatgpt) ?? ResponsesAdapter.subscriptionDefaultModel
        let effort = compatibleEffort(currentEffort ?? ProviderProfiles.configuredEffort(.chatgpt) ?? "high", model: model)
        let selected = await env.subscription(["action": "select", "model": model, "effort": effort])
        await reload()
        guard selected["ok"] as? Bool == true else {
            return (false, L("Signed in, but Briglia couldn\u{2019}t switch to ChatGPT: ", "Accesso fatto, ma Briglia non è riuscita a passare a ChatGPT: ") + applyError(selected))
        }
        let probe = await env.subscription(["action": "probe", "model": model, "effort": effort])
        guard probe["ok"] as? Bool == true else {
            return (false, L("Signed in, but ChatGPT didn\u{2019}t answer with \(Self.modelLabel(model)): \(applyError(probe)). Your plan may not include this model \u{2014} pick another one below.", "Accesso fatto, ma ChatGPT non ha risposto con \(Self.modelLabel(model)): \(applyError(probe)). Il tuo piano potrebbe non includere questo modello: scegline un altro qui sotto."))
        }
        return (true, L("Signed in! Briglia now thinks with \(Self.modelLabel(model)).", "Accesso fatto! Ora Briglia ragiona con \(Self.modelLabel(model))."))
    }

    // MARK: Telegram

    private func confirmTelegram(chatId: String) async -> (Bool, String?) {
        guard let p = telegram else { return (false, L("Paste your bot token first.", "Incolla prima il token del bot.")) }
        switch TelegramPairing.parseChatId(chatId) {
        case .success: break
        case .failure(.notNumeric): return (false, L("Your Telegram ID is a number, like 123456789. Get it from @userinfobot.", "Il tuo ID Telegram è un numero, tipo 123456789. Lo trovi con @userinfobot."))
        case .failure(.notPrivate): return (false, L(TelegramPairing.privateChatExplanation, "Briglia risponde solo a una chat privata con te: usa il tuo ID personale, non quello di un gruppo o di un canale."))
        }
        let check = await env.telegramChatProbe(p.token, chatId)
        if let failure = check.failure {
            if var again = telegram, again.state == "found" { again.state = "waiting"; again.since = now(); again.lastScan = .distantPast; telegram = again }
            return (false, telegramChatFailure(failure, bot: p.bot))
        }
        let result = await env.apply(["telegram": ["token": p.token, "chat_id": chatId]])
        await reload()
        guard result["ok"] as? Bool == true else { return (false, applyError(result)) }
        telegram = nil
        telegramBot = p.bot
        return (true, L("Telegram connected! Your messages to @\(p.bot) reach Briglia while it\u{2019}s running.", "Telegram collegato! I tuoi messaggi a @\(p.bot) arrivano a Briglia mentre è in funzione."))
    }
    /// The last connected bot's name, for the page's "Connected" line.
    private(set) var telegramBot: String?

    // MARK: This computer + tools

    private func fixKeepAwake(how: String) async -> (Bool, String?) {
        switch how {
        case "gnome":
            let ok = env.quick.disableGnomeAutoSuspend()
            await reload()
            return ok && snapshot.keepAwakeOK ? (true, L("Done \u{2014} this computer won\u{2019}t suspend by itself.", "Fatto: questo computer non andrà più in sospensione da solo."))
                : (false, L("That didn\u{2019}t work. Turn off automatic suspend in your system\u{2019}s power settings, then choose Check again.", "Non ha funzionato. Disattiva la sospensione automatica nelle impostazioni di alimentazione, poi scegli Ricontrolla."))
        case "mask":
            guard let spec = env.quick.maskSleepTargetsJob() else { return (false, L("sudo or systemctl is missing on this system.", "Su questo sistema mancano sudo o systemctl.")) }
            guard busy == nil else { return (false, L("Please wait for the current installation to finish.", "Aspetta che finisca l\u{2019}installazione in corso.")) }
            busy = "keepawake"
            let r = await runner.run(spec)
            busy = nil
            await reload()
            return r.ok && snapshot.keepAwakeOK ? (true, L("Done \u{2014} this computer will never go to sleep by itself.", "Fatto: questo computer non andrà mai in sospensione da solo."))
                : (false, L("That didn\u{2019}t work (\(r.failureReason ?? "password not accepted in the terminal?")).", "Non ha funzionato (\(r.failureReason ?? "password non accettata nel terminale?"))."))
        default:
            return (false, L("Unknown fix.", "Correzione sconosciuta."))
        }
    }

    private func installTools() -> (Bool, String?) {
        guard busy == nil else { return (false, L("Please wait for the current installation to finish.", "Aspetta che finisca l\u{2019}installazione in corso.")) }
        guard let status = toolchain else { return (false, L("Still checking what\u{2019}s installed \u{2014} try again in a moment.", "Sto ancora controllando cosa è installato: riprova tra un attimo.")) }
        let jobs = env.quick.toolchainJobs(status)
        if jobs.isEmpty {
            if !status.doctorRan { return (false, L("Python 3 is needed first. On a Mac, run xcode-select --install in the terminal, then choose Check again.", "Serve prima Python 3. Su un Mac esegui xcode-select --install nel terminale, poi scegli Ricontrolla.")) }
            if !env.isLinux { return (false, L("Homebrew is needed to install these tools. Install it from https://brew.sh, then choose Check again.", "Per installare questi strumenti serve Homebrew. Installalo da https://brew.sh, poi scegli Ricontrolla.")) }
            return (false, L("No package installer was found on this system for: ", "Su questo sistema non c\u{2019}è un gestore di pacchetti per: ") + status.mandatoryMissing.joined(separator: ", ") + ".")
        }
        busy = "tools"
        jobLines = []
        toolsError = nil
        let t = Task { @MainActor [weak self] in
            guard let self else { return }
            var failure: String?
            for (index, job) in jobs.enumerated() {
                self.jobLabel = self.L("Step \(index + 1) of \(jobs.count): \(job.label)", "Passo \(index + 1) di \(jobs.count): \(job.label)")
                self.appendJobLine("\u{25B6} \(job.label)")
                let r = await self.runner.run(job)
                if !r.ok {
                    failure = "\(job.label): \(r.failureReason ?? "failed")"
                    for line in r.excerpt { self.appendJobLine(line) }
                    break
                }
            }
            self.jobLabel = ""
            let after = await self.env.toolchainStatus()
            self.toolchain = after
            self.busy = nil
            if let failure { self.toolsError = self.L("Installation stopped \u{2014} \(failure).", "Installazione interrotta: \(failure).") }
            else if !after.complete { self.toolsError = self.L("Still missing: ", "Mancano ancora: ") + self.missingTools(after).joined(separator: ", ") + "." }
            self.markCompleteIfReady()
        }
        pending.append(t)
        return (true, nil)
    }

    func appendJobLine(_ line: String) {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        jobLines.append(String(clean.prefix(400)))
        if jobLines.count > 300 { jobLines.removeFirst(jobLines.count - 300) }
    }

    // MARK: Messages

    static func probeReason(_ payload: [String: Any]) -> String {
        (payload["reason"] as? String) ?? ((payload["error"] as? [String: Any])?["message"] as? String) ?? "the check failed"
    }

    func applyError(_ payload: [String: Any]) -> String {
        ((payload["error"] as? [String: Any])?["message"] as? String) ?? L("something went wrong while saving", "qualcosa è andato storto durante il salvataggio")
    }

    /// Telegram getChat failures from setup-api (English) in page language.
    func telegramChatFailure(_ failure: String, bot: String) -> String {
        if failure.lowercased().contains("chat not found") {
            return L("Your bot can\u{2019}t see this chat yet: open @\(bot) in Telegram, send /start, then try again.",
                     "Il bot non vede ancora questa chat: apri @\(bot) su Telegram, invia /start e riprova.")
        }
        return failure
    }

    /// Telegram scan failures (MenuEnvironment, English) in page language.
    func telegramScanFailure(_ why: String) -> String {
        guard lang == "it" else { return why }
        if why.contains("webhook") { return "Questo bot è collegato a un altro servizio (un webhook), quindi Briglia non può leggerlo. Crea un nuovo bot con @BotFather e usa quello." }
        if why.contains("Another program") { return "Un altro programma sta usando questo bot (forse Briglia su un altro computer). Fermalo, oppure crea un nuovo bot." }
        if why.contains("BotFather") { return "Telegram non accetta più questo token. Controllalo con @BotFather." }
        if why.contains("reach Telegram") { return "Impossibile contattare Telegram. Controlla la connessione a internet." }
        return "Telegram ha risposto con un errore. Riprova tra poco."
    }

    func keyError(_ item: MenuItem, _ reason: String) -> String {
        let service: String
        switch item {
        case .serper: service = "Serper"
        case .jina: service = "Jina"
        case .openai: service = "OpenAI"
        case .email: service = "AgentMail"
        default: service = "The service"
        }
        let lower = reason.lowercased()
        if reason.contains("HTTP 401") || reason.contains("HTTP 403") || lower.contains("unauthorized") || lower.contains("invalid") {
            return L("\(service) refused this key. Make sure you copied the whole key, then paste it again.", "\(service) ha rifiutato questa chiave. Controlla di averla copiata tutta, poi incollala di nuovo.")
        }
        if reason.contains("HTTP 429") || lower.contains("quota") || lower.contains("insufficient") {
            return L("\(service) accepted the key but says the account is out of credit or over its limit. Check your \(service) account.", "\(service) ha accettato la chiave, ma l\u{2019}account ha finito il credito o superato il limite. Controlla il tuo account \(service).")
        }
        if lower.contains("unreachable") { return L("Couldn\u{2019}t reach \(service). Check the internet connection and try again.", "Impossibile contattare \(service). Controlla la connessione a internet e riprova.") }
        return L("\(service) didn\u{2019}t accept this key: \(reason)", "\(service) non ha accettato questa chiave: \(reason)")
    }

    func keySavedMessage(_ item: MenuItem) -> String {
        switch item {
        case .serper: return L("Web search is on.", "Ricerca web attiva.")
        case .jina: return L("Briglia can now read web pages.", "Ora Briglia può leggere le pagine web.")
        case .openai: return L("Voice messages and image creation are on.", "Messaggi vocali e creazione di immagini attivi.")
        default: return L("Saved.", "Salvato.")
        }
    }

    func loginError(_ message: String, browser: Bool) -> String {
        let lower = message.lowercased()
        if !browser && lower.contains("device login") {
            return L("ChatGPT refused sign-in with a code. In ChatGPT (in the browser) open Settings \u{2192} Security and Login and turn on \u{201C}Enable device code authorization for Codex\u{201D}, then try again \u{2014} or use Sign in with ChatGPT, which doesn\u{2019}t need it.", "ChatGPT ha rifiutato l\u{2019}accesso con codice. In ChatGPT (nel browser) apri Impostazioni \u{2192} Sicurezza e accesso e attiva \u{201C}Enable device code authorization for Codex\u{201D}, poi riprova, oppure usa Accedi con ChatGPT, che non lo richiede.")
        }
        if browser && (lower.contains("address already in use") || lower.contains("bind")) {
            return L("Another sign-in is already waiting on this computer (maybe Codex). Close it, or use a code instead.", "C\u{2019}è già un altro accesso in attesa su questo computer (forse Codex). Chiudilo, oppure usa un codice.")
        }
        if lower.contains("expired") { return L("The sign-in took too long and expired. Try again.", "L\u{2019}accesso ha impiegato troppo ed è scaduto. Riprova.") }
        if lower.contains("declined") || lower.contains("denied") { return L("Sign-in was declined. Try again when you\u{2019}re ready.", "L\u{2019}accesso è stato rifiutato. Riprova quando sei pronto.") }
        return L("Sign-in didn\u{2019}t finish: \(message)", "L\u{2019}accesso non è andato a buon fine: \(message)")
    }
}
