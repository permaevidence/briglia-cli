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

/// Which menu operations may still write. Every action takes a ticket:
/// the link generation that authorized it, the menu epoch (bumped by Close,
/// link rotation and shutdown), and — for actions that change one setting —
/// that setting's revision (bumped by every later action on the same
/// setting: a newer key, Remove, Telegram reset, sign-out…). A ticket is
/// checked right before every write, including inside setup-api's and the
/// subscription store's own checkpoints, so a late probe or sign-in whose
/// ticket was voided writes nothing. Lock-based: those checkpoints run off
/// the main actor.
final class MenuValidity: @unchecked Sendable {
    struct Ticket: Sendable {
        let generation: Int
        let epoch: Int
        let slot: String?
        let revision: Int
    }
    /// Why a ticket stopped being valid.
    enum Voided: Error, Equatable {
        /// The link was replaced, the page closed or the menu is shutting
        /// down: the request gets no answer (HTTP 404, like the quick setup).
        case revoked
        /// A newer action on the same setting replaced this one.
        case superseded
    }

    private let lock = NSLock()
    private var epoch = 0
    private var revisions: [String: Int] = [:]
    /// The authorizer's generation check (the quick setup's checkpointSync).
    var authCheck: @Sendable (Int) throws -> Void = { _ in }

    /// A ticket for a new action; `claim` makes it the newest on `slot`,
    /// voiding every earlier ticket on that slot.
    func ticket(generation: Int, slot: String?, claim: Bool) -> Ticket {
        lock.lock(); defer { lock.unlock() }
        var rev = 0
        if let slot {
            rev = revisions[slot, default: 0] + (claim ? 1 : 0)
            revisions[slot] = rev
        }
        return Ticket(generation: generation, epoch: epoch, slot: slot, revision: rev)
    }

    /// Voids every outstanding ticket (Close, link rotation, shutdown).
    func revokeAll() {
        lock.lock(); epoch += 1; lock.unlock()
    }

    func check(_ t: Ticket) throws {
        do { try authCheck(t.generation) } catch { throw Voided.revoked }
        lock.lock(); defer { lock.unlock() }
        guard t.epoch == epoch else { throw Voided.revoked }
        if let slot = t.slot, revisions[slot, default: 0] != t.revision { throw Voided.superseded }
    }

    func isValid(_ t: Ticket) -> Bool { (try? check(t)) != nil }
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
    /// Linux "Start Briglia": the service is installed and started while the
    /// page is still open, and the page only says it runs once the service
    /// passed the quick setup's health check (active, starts at boot, its
    /// socket answers, stable). A failure stays on the page with Retry.
    struct Startup { var state: String; var step: String; var message: String? }
    private(set) var startup: Startup?
    private var startupTask: Task<Void, Never>?
    /// The instance lease was handed to the running service: the command must
    /// neither release it again nor restart a paused service.
    private(set) var leaseHandedOff = false

    /// Page requests still executing; `revoke()` cancels them (so a probe
    /// waiting on the network returns at once) and waits for them.
    private var inFlight = 0
    private var requestTasks: [UUID: Task<(Bool, String?), Error>] = [:]
    let validity = MenuValidity()

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

    /// Link rotation, Close and shutdown: void every ticket, cancel sign-in
    /// and background work, and wait (bounded) until requests and tasks have
    /// unwound, so nothing of the old session writes after this returns.
    /// Idempotent. `cancelJob` also stops a running installer (shutdown; a
    /// rotation's authorizer already cancels the shared job runner).
    func revoke(cancelJob: Bool = false) async {
        validity.revokeAll()
        loginTask?.cancel()
        loginAttempt = nil
        login = nil
        telegram = nil
        for t in pending { t.cancel() }
        for t in requestTasks.values { t.cancel() }
        if cancelJob { _ = await runner.cancelRunning() }
        if let t = loginTask { await t.value }
        loginTask = nil
        if let t = startupTask { await t.value }
        while !pending.isEmpty { let p = pending; pending = []; for t in p { await t.value } }
        var waited = 0
        while inFlight > 0, waited < 600 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
    }

    func shutdown() async {
        toolchainTask?.cancel()
        await revoke(cancelJob: true)
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
    func status(generation g: Int = 0) -> [String: Any] {
        pollOutsideWorld(g)
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
        if let startup {
            var d: [String: Any] = ["state": startup.state, "step": startup.step]
            if let m = startup.message { d["message"] = m }
            out["startup"] = d
        } else { out["startup"] = NSNull() }
        out["busy"] = busy ?? NSNull()
        out["closing"] = closing ?? NSNull()
        return out
    }

    private var lastFDACheck = Date.distantPast
    private func pollOutsideWorld(_ g: Int) {
        if !env.isLinux, !snapshot.fdaGranted, now().timeIntervalSince(lastFDACheck) >= 1.5 {
            lastFDACheck = now()
            if env.quick.fullDiskAccessGranted() { snapshot.fdaGranted = true; markCompleteIfReady() }
        }
        guard var p = telegram, p.state == "waiting", !scanInFlight, now().timeIntervalSince(p.lastScan) >= 2 else { return }
        p.lastScan = now()
        telegram = p
        scanInFlight = true
        let token = p.token, since = p.since
        let ticket = validity.ticket(generation: g, slot: "telegram", claim: false)
        let t = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.env.telegramScan(token, since)
            self.scanInFlight = false
            guard self.validity.isValid(ticket), var current = self.telegram, current.token == token, current.state == "waiting" else { return }
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

    /// One page action → `{ok, message?, status}`, or nil when the action's
    /// link was revoked (the router answers 404). An action replaced by a
    /// newer one on the same setting answers `{ok: false, superseded: true}`
    /// with nothing written.
    func handle(_ body: [String: Any], generation g: Int = 0) async -> [String: Any]? {
        guard validity.isValid(validity.ticket(generation: g, slot: nil, claim: false)) else { return nil }
        inFlight += 1
        defer { inFlight -= 1 }
        let action = body["action"] as? String ?? ""
        let id = UUID()
        let work = Task { @MainActor in try await self.perform(action, body, g) }
        requestTasks[id] = work
        defer { requestTasks[id] = nil }
        let result: (Bool, String?)
        do { result = try await work.value }
        catch MenuValidity.Voided.superseded {
            return ["ok": false, "superseded": true, "status": status(generation: g)]
        } catch {
            return nil
        }
        var out: [String: Any] = ["ok": result.0, "status": status(generation: g)]
        if let message = result.1 { out["message"] = message }
        return out
    }

    private func str(_ body: [String: Any], _ key: String) -> String {
        ((body[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The setting an action changes: a newer action on it voids older ones.
    static func slot(_ action: String, _ body: [String: Any]) -> String? {
        switch action {
        case "name": return "name"
        case "key", "key_remove":
            let kind = (body["kind"] as? String) ?? ""
            return kind == "agentmail" ? "email" : "key:\(kind)"
        case "email_off": return "email"
        case "chatgpt_browser", "chatgpt_code", "chatgpt_cancel", "chatgpt_logout", "chatgpt_model", "chatgpt_use": return "chatgpt"
        case "telegram_token", "telegram_wait", "telegram_manual", "telegram_reset", "telegram_confirm": return "telegram"
        default: return nil
        }
    }

    private func perform(_ action: String, _ body: [String: Any], _ g: Int) async throws -> (Bool, String?) {
        guard closing == nil else { return (false, L("This page is closing.", "Questa pagina si sta chiudendo.")) }
        if startup?.state == "running", action != "lang" {
            return (false, L("Briglia is starting \u{2014} one moment.", "Briglia si sta avviando: un momento."))
        }
        let ticket = validity.ticket(generation: g, slot: Self.slot(action, body), claim: true)
        let validity = self.validity
        /// Checked before every write; handed to setup-api / the subscription
        /// store, which call it again right before their own writes.
        let checkpoint: @Sendable () throws -> Void = { try validity.check(ticket) }
        switch action {
        case "lang":
            let value = str(body, "lang")
            guard value == "en" || value == "it" else { return (false, nil) }
            lang = value
            return (true, nil)

        case "name":
            let name = str(body, "name")
            guard !name.isEmpty, name.count <= 100 else { return (false, L("Type your name first.", "Scrivi prima il tuo nome.")) }
            try checkpoint()
            let result = await env.apply(["identity": ["user_name": name]], checkpoint)
            try checkpoint()
            await reload()
            return result["ok"] as? Bool == true ? (true, L("Nice to meet you, \(name)!", "Piacere di conoscerti, \(name)!")) : (false, applyError(result))

        case "key":
            return try await saveKey(kind: str(body, "kind"), key: str(body, "key"), checkpoint: checkpoint)

        case "key_remove":
            guard str(body, "kind") == "openai" else { return (false, L("Only the optional OpenAI key can be removed.", "Si può rimuovere solo la chiave OpenAI, che è facoltativa.")) }
            try checkpoint()
            let result = await env.apply(["openai": ["remove": true]], checkpoint)
            try checkpoint()
            await reload()
            return result["ok"] as? Bool == true ? (true, L("Key removed. Voice messages and image creation are off.", "Chiave rimossa. Messaggi vocali e creazione di immagini sono disattivati.")) : (false, applyError(result))

        case "email_off":
            try checkpoint()
            let result = await env.apply(["email_calendar": ["provider": "none"]], checkpoint)
            try checkpoint()
            await reload()
            return result["ok"] as? Bool == true ? (true, L("Email is off. Your key is kept, so you can turn it back on any time.", "Email disattivata. La chiave resta salvata, così puoi riattivarla quando vuoi.")) : (false, applyError(result))

        case "email_tool":
            guard busy == nil else { return (false, L("Please wait for the current installation to finish.", "Aspetta che finisca l\u{2019}installazione in corso.")) }
            startEmailToolInstall(checkpoint)
            return (true, nil)

        case "chatgpt_browser", "chatgpt_code":
            return await startSignIn(browser: action == "chatgpt_browser", checkpoint: checkpoint)

        case "chatgpt_cancel":
            loginTask?.cancel(); loginTask = nil; loginAttempt = nil; login = nil
            return (true, L("Sign-in cancelled.", "Accesso annullato."))

        case "chatgpt_logout":
            let again = body["again"] as? Bool == true
            // Sign-out supersedes a sign-in still in progress.
            loginTask?.cancel(); loginTask = nil; loginAttempt = nil; login = nil
            try checkpoint()
            let result = await env.subscription(["action": "logout"], checkpoint)
            try checkpoint()
            await reload()
            guard result["ok"] as? Bool == true else { return (false, applyError(result)) }
            return (true, again ? L("Signed out. Now sign in with the account you want.", "Disconnesso. Ora accedi con l\u{2019}account che vuoi usare.") : L("Signed out. Briglia can\u{2019}t answer until you sign in again.", "Disconnesso. Briglia non può rispondere finché non accedi di nuovo."))

        case "chatgpt_model":
            let model = str(body, "model")
            guard ResponsesAdapter.subscriptionModelChoices.contains(where: { $0.id == model }) else { return (false, L("Unknown model.", "Modello sconosciuto.")) }
            try checkpoint()
            let result = await env.subscription(["action": "select", "model": model, "effort": compatibleEffort(currentEffort ?? "high", model: model)], checkpoint)
            try checkpoint()
            await reload()
            return result["ok"] as? Bool == true ? (true, L("Briglia now thinks with \(Self.modelLabel(model)).", "Ora Briglia ragiona con \(Self.modelLabel(model)).")) : (false, applyError(result))

        case "chatgpt_use":
            return try await selectAndProbe(checkpoint)

        case "telegram_token":
            let token = str(body, "token")
            guard !token.isEmpty else { return (false, L("Paste the token from @BotFather first.", "Incolla prima il token di @BotFather.")) }
            guard token.contains(":"), token.count <= 200 else {
                return (false, L("That doesn\u{2019}t look like a bot token. It looks like 123456789:AAE\u{2026} \u{2014} copy the whole line from BotFather.", "Questo non sembra il token di un bot. Somiglia a 123456789:AAE\u{2026}: copia l\u{2019}intera riga da BotFather."))
            }
            let probe = await env.probe(["kind": "telegram", "token": token])
            try checkpoint()
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
            return try await confirmTelegram(chatId: str(body, "chat_id"), checkpoint: checkpoint)

        case "fda_open":
            env.quick.openSettingsPane()
            return (true, L("System Settings is open. Turn on \(snapshot.terminalApp) in the list \u{2014} this page notices by itself.", "Impostazioni di Sistema è aperto. Attiva \(snapshot.terminalApp) nell\u{2019}elenco: questa pagina se ne accorge da sola."))

        case "keepawake":
            return try await fixKeepAwake(how: str(body, "how"), checkpoint: checkpoint)

        case "recheck":
            await reload()
            refreshToolchain()
            return (true, nil)

        case "tools_install":
            return installTools(checkpoint)

        case "finish":
            let what = str(body, "what")
            guard what == "start" || what == "quit" else { return (false, L("Unknown choice.", "Scelta sconosciuta.")) }
            if what == "start" {
                let missing = missingRequired
                if toolchain == nil && missing == [.tools] { return (false, L("Still checking the document tools \u{2014} try again in a moment.", "Sto ancora controllando gli strumenti per i documenti: riprova tra un attimo.")) }
                guard missing.isEmpty else { return (false, L("Finish these first: ", "Prima completa: ") + missing.map { $0.title(lang) }.joined(separator: ", ") + ".") }
            }
            guard busy == nil else { return (false, L("Please wait for the current installation to finish.", "Aspetta che finisca l\u{2019}installazione in corso.")) }
            if what == "start" && env.isLinux {
                // Close only once the service really runs (see Startup).
                beginStartup(checkpoint)
                return (true, nil)
            }
            startup = nil
            closing = what
            // Close voids every other ticket at once: a check still running
            // cannot save after the page said goodbye. `revoke()` (at
            // shutdown) cancels and waits for the rest.
            validity.revokeAll()
            loginTask?.cancel()
            return (true, nil)

        default:
            return (false, L("Unknown action.", "Azione sconosciuta."))
        }
    }

    // MARK: Linux start

    private func beginStartup(_ checkpoint: @escaping @Sendable () throws -> Void) {
        startup = Startup(state: "running", step: L("Checking this computer\u{2026}", "Controllo questo computer\u{2026}"), message: nil)
        busy = "starting"
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runStartup(checkpoint)
            self.startupTask = nil
        }
    }

    private func runStartup(_ checkpoint: @escaping @Sendable () throws -> Void) async {
        func step(_ en: String, _ it: String) { startup?.step = L(en, it) }
        func fail(_ message: String) {
            busy = nil
            startup = Startup(state: "failed", step: "", message: message)
        }
        guard env.systemdSessionAvailable() else {
            fail(L("This computer can\u{2019}t run Briglia as a background service (there is no systemd user session). Close this page and type briglia setup in the terminal, or run briglia daemon in a terminal window.",
                   "Questo computer non può far funzionare Briglia in background (manca la sessione utente di systemd). Chiudi questa pagina e scrivi briglia setup nel terminale, oppure avvia briglia daemon in una finestra del terminale."))
            return
        }
        step("Installing the background service\u{2026}", "Installo il servizio in background\u{2026}")
        do { try env.quick.installUnit() } catch {
            fail(L("The background service couldn\u{2019}t be installed: \(error.localizedDescription)", "Non è stato possibile installare il servizio in background: \(error.localizedDescription)"))
            return
        }
        guard (try? checkpoint()) != nil else { fail(L("Cancelled.", "Annullato.")); return }
        // The service's daemon needs the instance lease the menu holds.
        env.quick.releaseLease()
        leaseHandedOff = true
        step("Starting Briglia\u{2026}", "Avvio Briglia\u{2026}")
        var failure = await env.quick.enableService(runner)
        if failure == nil {
            step("Checking that Briglia is running (about 30 seconds)\u{2026}", "Controllo che Briglia sia in funzione (circa 30 secondi)\u{2026}")
            let evidence = await env.quick.serviceEvidence()
            if !evidence.ok { failure = evidence.detail }
        }
        if let failure {
            // Take the settings back so Retry (or closing) works from a clean state.
            _ = env.quick.stopService()
            let back = env.quick.reacquireLease()
            if back { leaseHandedOff = false }
            fail(L("Briglia didn\u{2019}t start: \(failure).", "Briglia non si è avviato: \(failure).")
                 + (back ? "" : L(" Close this page and type briglia menu again.", " Chiudi questa pagina e scrivi di nuovo briglia menu.")))
            return
        }
        busy = nil
        startup = nil
        closing = "start"
        validity.revokeAll()
    }

    // MARK: Keys

    private func saveKey(kind: String, key: String, checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        guard ["serper", "jina", "openai", "agentmail"].contains(kind) else { return (false, L("Unknown key.", "Chiave sconosciuta.")) }
        guard !key.isEmpty, key.count <= 4096, !key.contains(where: { $0.isNewline }) else { return (false, L("Paste your key first.", "Incolla prima la chiave.")) }
        let item: MenuItem = kind == "agentmail" ? .email : MenuItem(rawValue: kind)!
        let probe = await env.probe(["kind": kind, "api_key": key])
        try checkpoint()
        guard probe["ok"] as? Bool == true else { return (false, keyError(item, Self.probeReason(probe))) }
        let payload: [String: Any] = kind == "agentmail"
            ? ["email_calendar": ["provider": "agentmail", "api_key": key, "install_cli": false] as [String: Any]]
            : [kind: ["api_key": key]]
        let result = await env.apply(payload, checkpoint)
        try checkpoint()
        await reload()
        guard result["ok"] as? Bool == true else { return (false, applyError(result)) }
        if kind == "agentmail" {
            let inbox = (probe["inboxes"] as? [String])?.first.map { self.L(" Briglia\u{2019}s address: \($0).", " Indirizzo di Briglia: \($0).") } ?? ""
            if !snapshot.agentMailCLIInstalled && busy == nil { startEmailToolInstall(checkpoint) }
            return (true, L("Email connected.\(inbox)", "Email collegata.\(inbox)"))
        }
        return (true, keySavedMessage(item))
    }

    private func startEmailToolInstall(_ checkpoint: @escaping @Sendable () throws -> Void) {
        busy = "email_tool"
        jobLines = []
        let t = Task { @MainActor [weak self] in
            guard let self else { return }
            let failure = await self.env.quick.installAgentMail({ line in
                Task { @MainActor [weak self] in self?.appendJobLine(line) }
            }, { try checkpoint(); try Task.checkCancellation() }, self.runner)
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

    private func startSignIn(browser: Bool, checkpoint: @escaping @Sendable () throws -> Void) async -> (Bool, String?) {
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
                let (ok, message) = try await self.selectAndProbe(checkpoint)
                guard self.loginAttempt == attempt else { return }
                self.loginAttempt = nil
                self.login = ok ? nil : Login(kind: browser ? "browser" : "code", state: "error", message: message)
            } catch is MenuValidity.Voided {
                // A newer ChatGPT action or the end of the session replaced
                // this sign-in: nothing more is written; clear its spinner.
                guard let self, self.loginAttempt == attempt else { return }
                self.loginAttempt = nil
                self.login = nil
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
    private func selectAndProbe(_ checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        let model = currentModel ?? ProviderProfiles.configuredModel(.chatgpt) ?? ResponsesAdapter.subscriptionDefaultModel
        let effort = compatibleEffort(currentEffort ?? ProviderProfiles.configuredEffort(.chatgpt) ?? "high", model: model)
        try checkpoint()
        let selected = await env.subscription(["action": "select", "model": model, "effort": effort], checkpoint)
        try checkpoint()
        await reload()
        guard selected["ok"] as? Bool == true else {
            return (false, L("Signed in, but Briglia couldn\u{2019}t switch to ChatGPT: ", "Accesso fatto, ma Briglia non è riuscita a passare a ChatGPT: ") + applyError(selected))
        }
        let probe = await env.subscription(["action": "probe", "model": model, "effort": effort], checkpoint)
        try checkpoint()
        guard probe["ok"] as? Bool == true else {
            return (false, L("Signed in, but ChatGPT didn\u{2019}t answer with \(Self.modelLabel(model)): \(applyError(probe)). Your plan may not include this model \u{2014} pick another one below.", "Accesso fatto, ma ChatGPT non ha risposto con \(Self.modelLabel(model)): \(applyError(probe)). Il tuo piano potrebbe non includere questo modello: scegline un altro qui sotto."))
        }
        return (true, L("Signed in! Briglia now thinks with \(Self.modelLabel(model)).", "Accesso fatto! Ora Briglia ragiona con \(Self.modelLabel(model))."))
    }

    // MARK: Telegram

    private func confirmTelegram(chatId: String, checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        guard let p = telegram else { return (false, L("Paste your bot token first.", "Incolla prima il token del bot.")) }
        switch TelegramPairing.parseChatId(chatId) {
        case .success: break
        case .failure(.notNumeric): return (false, L("Your Telegram ID is a number, like 123456789. Get it from @userinfobot.", "Il tuo ID Telegram è un numero, tipo 123456789. Lo trovi con @userinfobot."))
        case .failure(.notPrivate): return (false, L(TelegramPairing.privateChatExplanation, "Briglia risponde solo a una chat privata con te: usa il tuo ID personale, non quello di un gruppo o di un canale."))
        }
        let check = await env.telegramChatProbe(p.token, chatId)
        try checkpoint()
        if let failure = check.failure {
            if var again = telegram, again.state == "found" { again.state = "waiting"; again.since = now(); again.lastScan = .distantPast; telegram = again }
            return (false, telegramChatFailure(failure, bot: p.bot))
        }
        let result = await env.apply(["telegram": ["token": p.token, "chat_id": chatId]], checkpoint)
        try checkpoint()
        await reload()
        guard result["ok"] as? Bool == true else { return (false, applyError(result)) }
        telegram = nil
        telegramBot = p.bot
        return (true, L("Telegram connected! Your messages to @\(p.bot) reach Briglia while it\u{2019}s running.", "Telegram collegato! I tuoi messaggi a @\(p.bot) arrivano a Briglia mentre è in funzione."))
    }
    /// The last connected bot's name, for the page's "Connected" line.
    private(set) var telegramBot: String?

    // MARK: This computer + tools

    private func fixKeepAwake(how: String, checkpoint: @Sendable () throws -> Void) async throws -> (Bool, String?) {
        switch how {
        case "gnome":
            try checkpoint()
            let ok = env.quick.disableGnomeAutoSuspend()
            await reload()
            return ok && snapshot.keepAwakeOK ? (true, L("Done \u{2014} this computer won\u{2019}t suspend by itself.", "Fatto: questo computer non andrà più in sospensione da solo."))
                : (false, L("That didn\u{2019}t work. Turn off automatic suspend in your system\u{2019}s power settings, then choose Check again.", "Non ha funzionato. Disattiva la sospensione automatica nelle impostazioni di alimentazione, poi scegli Ricontrolla."))
        case "mask":
            guard let spec = env.quick.maskSleepTargetsJob() else { return (false, L("sudo or systemctl is missing on this system.", "Su questo sistema mancano sudo o systemctl.")) }
            guard busy == nil else { return (false, L("Please wait for the current installation to finish.", "Aspetta che finisca l\u{2019}installazione in corso.")) }
            try checkpoint()
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

    private func installTools(_ checkpoint: @escaping @Sendable () throws -> Void) -> (Bool, String?) {
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
                // A revoked session (new link, Close, shutdown) starts no further step.
                if (try? checkpoint()) == nil || Task.isCancelled { failure = self.L("stopped", "interrotta"); break }
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
