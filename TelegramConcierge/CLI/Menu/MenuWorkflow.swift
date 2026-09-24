import Foundation

/// One row of the menu. Order = the guided first-run order. `.ai` is the
/// main AI provider, whichever lane the user picked (its title follows the
/// lane: `MenuWorkflow.stepTitle`).
enum MenuItem: String, CaseIterable {
    case name, ai, telegram, serper, jina, openai, email, computer, tools

    var title: String {
        switch self {
        case .name: return "Your name"
        case .ai: return "AI model"
        case .telegram: return "Telegram"
        case .serper: return "Web search"
        case .jina: return "Reading web pages"
        case .openai: return "Voice & images"
        case .email: return "Email"
        case .computer: return "This computer"
        case .tools: return "Document & media tools"
        }
    }

    func title(_ lang: String) -> String {
        guard lang == "it" else { return title }
        switch self {
        case .name: return "Il tuo nome"
        case .ai: return "Modello AI"
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

/// The four ways to power Briglia the menu offers. ChatGPT is the default
/// and the easiest; the other three need an OpenAI API key too, because web
/// research runs on OpenAI there (owner, 2026-09-24: only OpenAI models are
/// fast enough for page extraction).
enum MenuLane: String, CaseIterable {
    case chatgpt, opencode, openrouter, local

    var profile: ProviderProfiles.Profile {
        switch self {
        case .chatgpt: return .chatgpt
        case .opencode: return .opencode
        case .openrouter: return .openrouter
        case .local: return .local
        }
    }

    /// Web research needs the OpenAI key on this lane (it is optional only
    /// with the subscription, which powers research itself).
    var needsOpenAI: Bool { self != .chatgpt }

    func title(_ lang: String) -> String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .opencode: return "OpenCode Go"
        case .openrouter: return "OpenRouter"
        case .local: return lang == "it" ? "Modello locale" : "Local model"
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

/// The saved AI settings a menu write is based on (`MenuWorkflow.aiState`).
struct MenuAIState: Equatable {
    var active: String?
    var chatgpt: String
    var providers: [String: String]
    var openAIKey: Bool
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

    /// The lane being set up when it isn't the running provider: the first
    /// run before any provider is saved, or "Switch or add a provider" on a
    /// lane that isn't configured yet. Cleared once a provider is saved or
    /// switched to.
    private(set) var plannedLane: MenuLane?
    /// A local server's model list (the page's "Find models").
    struct LocalListing { var base: String; var state: String; var models: [String] = []; var message: String? }
    private(set) var localListing: LocalListing?

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
        snapshotEpoch &+= 1
        snapshot = await env.snapshot()
        markCompleteIfReady()
    }
    /// Bumped by every reload: a background refresh that started before a
    /// newer reload doesn't overwrite it with older settings.
    private var snapshotEpoch = 0
    private var liveRefreshInFlight = false
    private var lastLiveRefresh = Date.distantPast
    /// Seconds between re-reads of the settings while Briglia runs, so a
    /// /model, /provider or /effort sent on Telegram shows on the open page.
    static let liveRefreshInterval: TimeInterval = 3

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

    // MARK: Lanes

    /// Whether a lane is set up and usable as the main provider.
    func laneReady(_ lane: MenuLane) -> Bool {
        lane == .chatgpt ? snapshot.chatgptReady : (snapshot.providers[lane.rawValue]?.configured ?? false)
    }

    /// The running provider as a lane. Nil when nothing is set up, or when
    /// the active profile is one the menu shows but doesn't edit (a custom
    /// endpoint or the OpenAI API, set up with briglia setup).
    var activeLane: MenuLane? {
        if snapshot.chatgptReady { return .chatgpt }
        guard let raw = snapshot.activeProfile, let lane = MenuLane(rawValue: raw), lane != .chatgpt, laneReady(lane) else { return nil }
        return lane
    }

    /// The lane the AI screen shows.
    var lane: MenuLane { plannedLane ?? activeLane ?? .chatgpt }

    /// Whether the OpenAI key is required: always once a non-ChatGPT
    /// provider runs; before that, when the lane being set up needs it.
    var openAIRequired: Bool {
        if let active = activeLane { return active.needsOpenAI }
        if snapshot.otherProvider != nil { return true }
        return plannedLane?.needsOpenAI ?? false
    }

    func isRequired(_ item: MenuItem) -> Bool {
        switch item {
        case .email: return false
        case .openai: return openAIRequired
        default: return true
        }
    }

    /// Step titles: the AI row is named after its lane ("ChatGPT",
    /// "OpenCode Go"…), the rest are fixed.
    func stepTitle(_ item: MenuItem) -> String {
        if item == .openai && openAIRequired { return L("OpenAI key", "Chiave OpenAI") }
        guard item == .ai else { return item.title(lang) }
        if let active = activeLane { return active.title(lang) }
        if let other = snapshot.otherProvider { return other }
        return lane.title(lang)
    }

    /// The reasoning levels the menu offers for one model: Light, Balanced,
    /// Deep, plus Deepest where the model takes xhigh. Local servers take
    /// none (Briglia sends no effort to them).
    func effortChoices(_ lane: MenuLane, model: String) -> [String] {
        let base = ["low", "medium", "high"]
        switch lane {
        case .local: return []
        case .openrouter: return base
        case .chatgpt:
            let allowed = ResponsesAdapter.allowedEfforts(model: model)
            return (base + ["xhigh"]).filter(allowed.contains)
        case .opencode:
            guard OpenCodeGo.usesResponses(model) else { return base }
            let allowed = ResponsesAdapter.allowedEfforts(model: model)
            return (base + ["xhigh"]).filter(allowed.contains)
        }
    }

    static let openRouterDefaultModel = "google/gemini-3-flash-preview"

    static func modelLabel(_ lane: MenuLane, _ id: String) -> String {
        switch lane {
        case .chatgpt: return modelLabel(id)
        case .opencode: return OpenCodeGo.catalogEntry(for: id)?.label ?? id
        case .openrouter, .local: return id
        }
    }

    func isDone(_ item: MenuItem) -> Bool {
        let s = snapshot
        switch item {
        case .name: return !s.userName.isEmpty
        case .ai: return activeLane != nil || s.otherProvider != nil
        case .telegram: return s.telegramConfigured
        case .serper: return s.serperMasked != nil
        case .jina: return s.jinaMasked != nil
        case .openai: return s.openAIMasked != nil
        case .email: return s.emailProvider == "agentmail" && s.agentMailMasked != nil
        case .computer: return (env.isLinux || s.fdaGranted) && s.keepAwakeOK
        case .tools: return toolchain?.complete == true
        }
    }

    var missingRequired: [MenuItem] { MenuItem.allCases.filter { isRequired($0) && !isDone($0) } }

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
        case .ai:
            if let active = activeLane {
                let model = active == .chatgpt ? (currentModel ?? "") : (s.providers[active.rawValue]?.model ?? "")
                return Self.modelLabel(active, model)
            }
            if let other = s.otherProvider { return other }
            guard lane == .chatgpt else { return L("Not set up", "Da configurare") }
            switch s.chatgpt {
            case .signedIn: return L("Signed in, not in use", "Accesso fatto, non in uso")
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
            ["id": $0.rawValue, "title": stepTitle($0), "required": isRequired($0), "done": isDone($0), "summary": summary($0)]
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
            "steps": steps, "name": s.userName, "chatgpt": chatgpt, "ai": aiStatus(), "telegram": tg, "keys": keys,
            "email": ["on": isDone(.email), "inbox": s.agentMailInbox, "tool_installed": s.agentMailCLIInstalled] as [String: Any],
            "computer": ["fda": s.fdaGranted, "terminal_app": s.terminalApp, "keep_awake_ok": s.keepAwakeOK,
                         "keep_awake_summary": env.isLinux ? s.keepAwakeSummary : L("Briglia keeps this Mac awake while it runs (a closed lid or a manual sleep still stops it).", "Briglia tiene sveglio questo Mac mentre è in funzione (chiudere il coperchio o mettere in stop lo ferma comunque)."), "can_fix_gnome": s.keepAwakeGnomeFixable,
                         "can_mask": s.keepAwakeMaskable] as [String: Any],
            "tools": tools,
            "service_was_running": serviceWasRunning,
            "running": env.live != nil,
            "run_mode": env.live?.mode ?? NSNull(),
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

    /// The AI provider part of the page state: the lane shown, what runs,
    /// every lane's saved setup, and the choices the page offers.
    private func aiStatus() -> [String: Any] {
        var providers: [String: Any] = [:]
        var chat: [String: Any] = ["configured": laneReady(.chatgpt) || { if case .signedIn = snapshot.chatgpt { return true }; return false }(),
                                   "active": activeLane == .chatgpt]
        if let m = currentModel { chat["model"] = m; chat["model_label"] = Self.modelLabel(m); chat["effort"] = currentEffort ?? "high"
            chat["efforts"] = effortChoices(.chatgpt, model: m) }
        providers["chatgpt"] = chat
        for lane in [MenuLane.opencode, .openrouter, .local] {
            let p = snapshot.providers[lane.rawValue] ?? MenuSnapshot.Provider()
            var d: [String: Any] = ["configured": p.configured, "active": activeLane == lane, "model": p.model,
                                    "model_label": p.model.isEmpty ? "" : Self.modelLabel(lane, p.model),
                                    "effort": p.effort.isEmpty ? "high" : p.effort, "text_only": p.textOnly,
                                    "efforts": effortChoices(lane, model: p.model)]
            if let k = p.keyMasked { d["key"] = k }
            if !p.endpoint.isEmpty { d["endpoint"] = p.endpoint }
            providers[lane.rawValue] = d
        }
        var out: [String: Any] = [
            "lane": lane.rawValue, "active": activeLane?.rawValue ?? NSNull(), "planned": plannedLane?.rawValue ?? NSNull(),
            "ready": isDone(.ai), "openai_required": openAIRequired, "providers": providers,
            "opencode_models": OpenCodeGo.choices.map { ["id": $0.id, "label": $0.label, "recommended": $0.id == OpenCodeGo.defaultModel] as [String: Any] },
            "openrouter_default": Self.openRouterDefaultModel,
        ]
        if activeLane == nil, let other = snapshot.otherProvider { out["other"] = other }
        if let l = localListing {
            var d: [String: Any] = ["base": l.base, "state": l.state, "models": l.models]
            if let m = l.message { d["message"] = m }
            out["local"] = d
        }
        return out
    }

    private var lastFDACheck = Date.distantPast
    private func pollOutsideWorld(_ g: Int) {
        if env.live != nil, !liveRefreshInFlight, now().timeIntervalSince(lastLiveRefresh) >= Self.liveRefreshInterval {
            lastLiveRefresh = now()
            liveRefreshInFlight = true
            let epoch = snapshotEpoch
            let t = Task { @MainActor [weak self] in
                guard let self else { return }
                let fresh = await self.env.snapshot()
                self.liveRefreshInFlight = false
                guard self.snapshotEpoch == epoch, self.closing == nil else { return }
                self.snapshotEpoch &+= 1
                self.snapshot = fresh
                self.markCompleteIfReady()
            }
            pending.append(t)
        }
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
        // One slot for everything that changes which AI runs or how: a newer
        // choice (another lane, a sign-out, a new key) voids an older one
        // still checking, so a late check can't switch the provider back.
        case "chatgpt_browser", "chatgpt_code", "chatgpt_cancel", "chatgpt_logout", "chatgpt_model", "chatgpt_use",
             "lane", "provider_key", "provider_model", "provider_use", "effort": return "ai"
        case "telegram_token", "telegram_wait", "telegram_manual", "telegram_reset", "telegram_confirm": return "telegram"
        default: return nil
        }
    }

    private func perform(_ action: String, _ body: [String: Any], _ g: Int) async throws -> (Bool, String?) {
        guard closing == nil else { return (false, L("This page is closing.", "Questa pagina si sta chiudendo.")) }
        if startup?.state == "running", action != "lang" {
            return (false, L("Briglia is starting \u{2014} one moment.", "Briglia si sta avviando: un momento."))
        }
        if env.live != nil, let refusal = liveRefusal(action, body) { return (false, refusal) }
        let ticket = validity.ticket(generation: g, slot: Self.slot(action, body), claim: true)
        let validity = self.validity
        /// Checked before every write; handed to setup-api / the subscription
        /// store, which call it again right before their own writes.
        let checkpoint: @Sendable () throws -> Void = { try validity.check(ticket) }
        /// The AI settings this action was chosen against: its write is
        /// refused if they changed before it (see `guardedAIWrite`).
        let basis = Self.aiState(snapshot)
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
            guard !openAIRequired else {
                return (false, L("With \(stepTitle(.ai)), Briglia\u{2019}s web research runs on this key, so it can\u{2019}t be removed. Paste a new key instead.",
                                 "Con \(stepTitle(.ai)) le ricerche web di Briglia usano questa chiave, quindi non si può rimuovere. Incollane una nuova."))
            }
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
            let effort = compatibleEffort(currentEffort ?? "high", model: model)
            guard let result = try await guardedAIWrite(basis, { await self.env.subscription(["action": "select", "model": model, "effort": effort], checkpoint) }) else {
                return (false, staleMessage)
            }
            try checkpoint()
            await reload()
            return result["ok"] as? Bool == true ? (true, L("Briglia now thinks with \(Self.modelLabel(model)).", "Ora Briglia ragiona con \(Self.modelLabel(model)).")) : (false, applyError(result))

        case "chatgpt_use":
            return try await selectAndProbe(basis: basis, checkpoint)

        case "lane":
            let raw = str(body, "lane")
            if raw.isEmpty { plannedLane = nil; return (true, nil) }
            guard let chosen = MenuLane(rawValue: raw) else { return (false, L("Unknown choice.", "Scelta sconosciuta.")) }
            plannedLane = chosen == activeLane ? nil : chosen
            return (true, nil)

        case "provider_key":
            return try await saveProviderKey(profile: str(body, "profile"), key: str(body, "key"), model: str(body, "model"), basis: basis, checkpoint: checkpoint)

        case "provider_model":
            return try await changeProviderModel(body, basis: basis, checkpoint: checkpoint)

        case "provider_use":
            guard let chosen = MenuLane(rawValue: str(body, "profile")) else { return (false, L("Unknown provider.", "Fornitore sconosciuto.")) }
            if chosen == .chatgpt {
                guard case .signedIn = snapshot.chatgpt else { return (false, L("Sign in to ChatGPT first.", "Prima accedi a ChatGPT.")) }
                return try await selectAndProbe(basis: basis, checkpoint)
            }
            guard let p = snapshot.providers[chosen.rawValue], p.configured else {
                return (false, L("Set up \(chosen.title(lang)) first.", "Prima configura \(chosen.title(lang))."))
            }
            return try await saveProvider(chosen, apiKey: nil, model: p.model, baseURL: nil, textOnly: p.textOnly,
                                          effort: p.effort.isEmpty ? nil : p.effort, basis: basis, checkpoint: checkpoint)

        case "local_models":
            return await listLocalModels(str(body, "base_url"), generation: g)

        case "effort":
            return try await changeEffort(str(body, "effort"), basis: basis, checkpoint: checkpoint)

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
            // start: run Briglia; stop: close and keep it off (Linux: also
            // off at boot); quit: close, leaving things as they were.
            guard ["start", "stop", "quit"].contains(what) else { return (false, L("Unknown choice.", "Scelta sconosciuta.")) }
            if env.live != nil {
                // The live hub: Briglia already runs. Stop ends it once the
                // page has its answer; Close only closes the page.
                guard what != "start" else { return (false, L("Briglia is already running.", "Briglia è già in funzione.")) }
                closing = what
                validity.revokeAll()
                loginTask?.cancel()
                if what == "stop" { stopRequested = true }
                return (true, nil)
            }
            if what == "start" {
                let missing = missingRequired
                if toolchain == nil && missing == [.tools] { return (false, L("Still checking the document tools \u{2014} try again in a moment.", "Sto ancora controllando gli strumenti per i documenti: riprova tra un attimo.")) }
                guard missing.isEmpty else { return (false, L("Finish these first: ", "Prima completa: ") + missing.map { stepTitle($0) }.joined(separator: ", ") + ".") }
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

    // MARK: Live hub

    /// Stop was chosen on the live hub: the host stops Briglia after the
    /// page received its answer.
    private(set) var stopRequested = false

    /// Actions the live hub can't do while Briglia runs, with why. The bot
    /// Briglia is polling can't be swapped under it (and scanning it would
    /// collide with Briglia's own polling); jobs that ask for a password
    /// need the terminal, which a running Briglia doesn't have.
    private func liveRefusal(_ action: String, _ body: [String: Any]) -> String? {
        switch action {
        case "telegram_token", "telegram_wait", "telegram_manual", "telegram_confirm":
            return L("Briglia is using this Telegram bot right now. To connect a different one, press Stop, then open briglia menu again \u{2014} or send /switchbot to Briglia on Telegram.",
                     "Briglia sta usando questo bot Telegram. Per collegarne un altro premi Ferma, poi riapri briglia menu, oppure invia /switchbot a Briglia su Telegram.")
        case "keepawake" where str(body, "how") == "mask":
            return L("This asks for your password in the terminal. Press Stop, then open briglia menu again to do it.",
                     "Questo chiede la password nel terminale. Premi Ferma, poi riapri briglia menu per farlo.")
        case "tools_install":
            if let status = toolchain, env.quick.toolchainJobs(status).contains(where: { $0.mode == .terminalHandoff }) {
                return L("Installing these asks for your password in the terminal. Press Stop, then open briglia menu again to install them.",
                         "L\u{2019}installazione chiede la password nel terminale. Premi Ferma, poi riapri briglia menu per installarli.")
            }
            return nil
        default:
            return nil
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
        // The server enforces what the signed-in page only offers: a working
        // active login is signed out before another account signs in.
        if let block = await env.loginBlock() { return (false, loginBlockMessage(block)) }
        loginTask?.cancel()
        let attempt = UUID()
        loginAttempt = attempt
        login = Login(kind: browser ? "browser" : "code", state: "starting")
        let openURL = env.openURL
        let loginEnv = env
        let commit: SubscriptionLogin.CommitHook = { [weak self] write in
            guard let self else { throw CancellationError() }
            return try await self.commitSignIn(write, attempt: attempt, browser: browser, checkpoint: checkpoint)
        }
        loginTask = Task { @MainActor [weak self] in
            do {
                if browser {
                    try await loginEnv.browserLogin({ url in
                        openURL(url)
                        Task { @MainActor [weak self] in
                            guard let self, self.loginAttempt == attempt else { return }
                            self.login = Login(kind: "browser", state: "waiting", url: url)
                        }
                    }, commit)
                } else {
                    try await loginEnv.deviceLogin({ url, code in
                        Task { @MainActor [weak self] in
                            guard let self, self.loginAttempt == attempt else { return }
                            self.login = Login(kind: "code", state: "waiting", url: url, code: code)
                        }
                    }, commit)
                }
                guard let self, self.loginAttempt == attempt, !Task.isCancelled else { return }
                let selection = self.signInSelection ?? (false, nil)
                self.signInSelection = nil
                var (ok, message) = selection
                if ok { (ok, message) = try await self.probeChatGPT(checkpoint) }
                guard self.loginAttempt == attempt else { return }
                self.loginAttempt = nil
                self.login = ok ? nil : Login(kind: browser ? "browser" : "code", state: "error", message: message)
            } catch is MenuValidity.Voided {
                // A newer ChatGPT action or the end of the session replaced
                // this sign-in: nothing more is written; clear its spinner.
                guard let self, self.loginAttempt == attempt else { return }
                self.loginAttempt = nil
                self.login = nil
            } catch let refused as MenuSignInRefused {
                guard let self, self.loginAttempt == attempt else { return }
                self.loginAttempt = nil
                self.login = Login(kind: browser ? "browser" : "code", state: "error", message: self.signInRefusedMessage(refused))
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

    /// Why the final step of a sign-in wrote nothing.
    enum MenuSignInRefused: Error { case busy, activeLogin }
    /// How long the final sign-in step waits for the running Briglia to be
    /// idle (it holds the new login only in memory meanwhile).
    static var signInCommitWait: Double = 120
    /// The switch made together with a sign-in's commit, read by the sign-in
    /// task once the login returns.
    private var signInSelection: (Bool, String?)?

    /// The last step of a sign-in: the human wait is over and the new login
    /// is only in memory. Under the live barrier (the agent idle, up to
    /// `signInCommitWait` for a turn to finish), re-check that the action is
    /// still current and that no working active login would be replaced,
    /// write the credential, and switch Briglia to it. Nothing is written
    /// when the barrier isn't reached, so the running agent keeps a
    /// coherent login either way.
    private func commitSignIn(_ write: () async throws -> String, attempt: UUID, browser: Bool,
                              checkpoint: @escaping @Sendable () throws -> Void) async throws -> String {
        if loginAttempt == attempt { login = Login(kind: browser ? "browser" : "code", state: "finishing") }
        var generation = ""
        var selection: (Bool, String?) = (false, nil)
        let entered = try await env.barrier(Self.signInCommitWait) {
            try checkpoint()
            if await self.env.loginBlock() == .activeLogin { throw MenuSignInRefused.activeLogin }
            generation = try await write()
            await self.reload()
            selection = try await self.selectChatGPT(checkpoint)
        }
        guard entered else { throw MenuSignInRefused.busy }
        signInSelection = selection
        return generation
    }

    /// After a successful login, or "use ChatGPT": save + activate the
    /// profile (keeping a previously chosen model), then one real request to
    /// prove it answers.
    private func selectAndProbe(basis: MenuAIState, _ checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        var selection: (Bool, String?) = (false, nil)
        let entered = try await env.barrier(0) {
            guard Self.aiState(await self.env.snapshot()) == basis else { selection = (false, nil); return }
            selection = try await self.selectChatGPT(checkpoint)
            if selection == (false, nil) { selection = (false, self.applyError(MenuHost.busyAnswer)) }
        }
        guard entered else { return (false, applyError(MenuHost.busyAnswer)) }
        if selection == (false, nil) { await reload(); return (false, staleMessage) }
        guard selection.0 else { return selection }
        return try await probeChatGPT(checkpoint)
    }

    /// Saves and activates the ChatGPT profile from the current snapshot.
    private func selectChatGPT(_ checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        let model = currentModel ?? ProviderProfiles.configuredModel(.chatgpt) ?? ResponsesAdapter.subscriptionDefaultModel
        let effort = compatibleEffort(currentEffort ?? ProviderProfiles.configuredEffort(.chatgpt) ?? "high", model: model)
        try checkpoint()
        let selected = await env.subscription(["action": "select", "model": model, "effort": effort], checkpoint)
        try checkpoint()
        await reload()
        guard selected["ok"] as? Bool == true else {
            return (false, L("Signed in, but Briglia couldn\u{2019}t switch to ChatGPT: ", "Accesso fatto, ma Briglia non è riuscita a passare a ChatGPT: ") + applyError(selected))
        }
        return (true, nil)
    }

    /// One real request with the selected model (a read: no barrier).
    private func probeChatGPT(_ checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        let model = currentModel ?? ProviderProfiles.configuredModel(.chatgpt) ?? ResponsesAdapter.subscriptionDefaultModel
        let effort = compatibleEffort(currentEffort ?? ProviderProfiles.configuredEffort(.chatgpt) ?? "high", model: model)
        let probe = await env.subscription(["action": "probe", "model": model, "effort": effort], checkpoint)
        try checkpoint()
        guard probe["ok"] as? Bool == true else {
            return (false, L("Signed in, but ChatGPT didn\u{2019}t answer with \(Self.modelLabel(model)): \(applyError(probe)). Your plan may not include this model \u{2014} pick another one below.", "Accesso fatto, ma ChatGPT non ha risposto con \(Self.modelLabel(model)): \(applyError(probe)). Il tuo piano potrebbe non includere questo modello: scegline un altro qui sotto."))
        }
        plannedLane = nil
        return (true, L("Signed in! Briglia now thinks with \(Self.modelLabel(model)).", "Accesso fatto! Ora Briglia ragiona con \(Self.modelLabel(model))."))
    }

    // MARK: Stale settings

    /// The saved AI settings a write depends on: which provider runs, and
    /// each profile's model, thinking level and image mode.
    static func aiState(_ s: MenuSnapshot) -> MenuAIState {
        var chatgpt = "signed_out"
        switch s.chatgpt {
        case .signedIn(let active, let model, let effort, _): chatgpt = "signed_in|\(active)|\(model)|\(effort)"
        case .loginRequired: chatgpt = "login_required"
        case .signedOut: break
        }
        var providers: [String: String] = [:]
        for (id, p) in s.providers {
            providers[id] = "\(p.configured)|\(p.model)|\(p.effort)|\(p.textOnly)|\(p.endpoint)"
        }
        return MenuAIState(active: s.activeProfile, chatgpt: chatgpt, providers: providers, openAIKey: s.openAIMasked != nil)
    }

    /// Runs an AI-settings write only while the saved settings are still the
    /// ones the action was chosen against (`basis`), compared inside the
    /// running agent's settings barrier (Telegram commands are refused
    /// there) and after any probe the action awaited. nil = they changed
    /// (a /model, /provider or /effort from Telegram, the settings page…):
    /// nothing is written and the page is refreshed.
    private func guardedAIWrite(_ basis: MenuAIState, _ write: @escaping () async -> [String: Any]) async throws -> [String: Any]? {
        var result = MenuHost.busyAnswer
        var stale = false
        let entered = try await env.barrier(0) {
            guard Self.aiState(await self.env.snapshot()) == basis else { stale = true; return }
            result = await write()
        }
        guard entered else { return MenuHost.busyAnswer }
        if stale { await reload(); return nil }
        return result
    }

    var staleMessage: String {
        L("Your settings were changed elsewhere (for example from Telegram) while this page was open, so nothing was saved. The page now shows the current settings \u{2014} check them and try again.",
          "Le impostazioni sono state cambiate altrove (per esempio da Telegram) mentre questa pagina era aperta, quindi non ho salvato nulla. Ora la pagina mostra quelle attuali: controllale e riprova.")
    }

    func loginBlockMessage(_ block: MenuLoginBlock) -> String {
        switch block {
        case .activeLogin:
            return L("Briglia is using this ChatGPT login right now. To sign in with another account, sign out first.",
                     "Briglia sta usando questo accesso ChatGPT. Per entrare con un altro account, prima esci.")
        case .telegramLogin:
            return L("A ChatGPT sign-in started from Telegram is still waiting. Finish it there, or send /subscription cancel, then try again.",
                     "C\u{2019}è ancora un accesso a ChatGPT avviato da Telegram in attesa. Completalo lì, oppure invia /subscription cancel, poi riprova.")
        }
    }

    func signInRefusedMessage(_ refused: MenuSignInRefused) -> String {
        switch refused {
        case .activeLogin: return loginBlockMessage(.activeLogin)
        case .busy:
            return L("Briglia stayed busy answering, so the new sign-in wasn\u{2019}t saved. Sign in again when it has answered.",
                     "Briglia è rimasta occupata a rispondere, quindi il nuovo accesso non è stato salvato. Accedi di nuovo quando ha risposto.")
        }
    }

    // MARK: OpenCode Go, OpenRouter, local

    /// A new OpenCode Go or OpenRouter key: checked against the service,
    /// then saved with the lane's current (or default) model and switched
    /// to. The key never goes back to the page.
    private func saveProviderKey(profile: String, key: String, model requested: String, basis: MenuAIState, checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        guard let lane = MenuLane(rawValue: profile), lane == .opencode || lane == .openrouter else { return (false, L("Unknown provider.", "Fornitore sconosciuto.")) }
        guard !key.isEmpty, key.count <= 4096, !key.contains(where: { $0.isNewline }) else { return (false, L("Paste your key first.", "Incolla prima la chiave.")) }
        let stored = snapshot.providers[lane.rawValue] ?? MenuSnapshot.Provider()
        let model = !requested.isEmpty ? requested
            : !stored.model.isEmpty ? stored.model
            : (lane == .opencode ? OpenCodeGo.defaultModel : Self.openRouterDefaultModel)
        let probe = await env.probe(lane == .opencode ? ["kind": "opencode", "api_key": key]
                                                      : ["kind": "openrouter", "api_key": key, "model": model])
        try checkpoint()
        guard probe["ok"] as? Bool == true else { return (false, keyError(service: lane.title(lang), Self.probeReason(probe))) }
        return try await saveProvider(lane, apiKey: key, model: model, baseURL: nil,
                                      textOnly: model == stored.model && stored.configured ? stored.textOnly : nil,
                                      effort: stored.effort.isEmpty ? nil : stored.effort, basis: basis, checkpoint: checkpoint)
    }

    /// A different model (OpenCode Go catalog, an OpenRouter id, or a local
    /// server's model with its address): one real request with the saved key
    /// first, so a model the account can't use is refused before it's saved.
    private func changeProviderModel(_ body: [String: Any], basis: MenuAIState, checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        guard let lane = MenuLane(rawValue: str(body, "profile")), lane != .chatgpt else { return (false, L("Unknown provider.", "Fornitore sconosciuto.")) }
        let model = str(body, "model")
        guard !model.isEmpty, model.count <= 300, !model.contains(where: { $0.isWhitespace }) else {
            return (false, L("Type the model name first.", "Scrivi prima il nome del modello."))
        }
        if let raw = body["text_only"], !(raw is Bool) || !BashTools.isJSONBoolean(raw) { return (false, L("Unknown option.", "Opzione sconosciuta.")) }
        let textOnly = body["text_only"] as? Bool
        let stored = snapshot.providers[lane.rawValue] ?? MenuSnapshot.Provider()
        var baseURL: String?
        let probe: [String: Any]
        switch lane {
        case .opencode:
            guard OpenCodeGo.choices.contains(where: { $0.id == model }) else { return (false, L("Unknown model.", "Modello sconosciuto.")) }
            guard let key = env.providerKey(.opencode) else { return (false, L("Paste your OpenCode key first.", "Incolla prima la chiave OpenCode.")) }
            probe = await env.probe(["kind": OpenCodeGo.usesResponses(model) ? "responses" : "custom", "base_url": OpenCodeGo.baseURL, "api_key": key, "model": model])
        case .openrouter:
            guard let key = env.providerKey(.openrouter) else { return (false, L("Paste your OpenRouter key first.", "Incolla prima la chiave OpenRouter.")) }
            probe = await env.probe(["kind": "openrouter", "api_key": key, "model": model])
        case .local:
            guard let base = MenuEnvironment.localBase(str(body, "base_url")) else {
                return (false, L("That address doesn\u{2019}t look right. It looks like http://localhost:1234/v1.", "Questo indirizzo non sembra giusto. Somiglia a http://localhost:1234/v1."))
            }
            baseURL = base
            probe = await env.probe(["kind": "local", "base_url": base, "model": model])
        case .chatgpt:
            return (false, nil)
        }
        try checkpoint()
        guard probe["ok"] as? Bool == true else {
            let reason = Self.probeReason(probe)
            if lane == .local {
                return (false, L("The server at \(baseURL ?? "") didn\u{2019}t answer with \(model): \(reason). Check that the model is loaded, then try again.",
                                 "Il server \(baseURL ?? "") non ha risposto con \(model): \(reason). Controlla che il modello sia caricato, poi riprova."))
            }
            return (false, L("\(lane.title(lang)) didn\u{2019}t answer with \(model): \(reason).", "\(lane.title(lang)) non ha risposto con \(model): \(reason)."))
        }
        // OpenCode takes the vision state from its catalog; the others keep
        // theirs unless the page says otherwise (a new id defaults to vision).
        let vision: Bool? = lane == .opencode ? nil : (textOnly ?? (model == stored.model ? stored.textOnly : false))
        return try await saveProvider(lane, apiKey: nil, model: model, baseURL: baseURL, textOnly: vision,
                                      effort: stored.effort.isEmpty ? nil : stored.effort, basis: basis, checkpoint: checkpoint)
    }

    /// Saves one provider profile through setup-api and makes it the one
    /// Briglia uses. Web research then runs on the OpenAI key (the owner's
    /// rule for every lane but ChatGPT), so the stored research backend is
    /// set to OpenAI whenever that key is there.
    private func saveProvider(_ lane: MenuLane, apiKey: String?, model: String, baseURL: String?, textOnly: Bool?, effort: String?,
                              basis: MenuAIState, checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        var section: [String: Any] = ["profile": lane.profile.rawValue, "model": model, "activate": true]
        if let apiKey { section["api_key"] = apiKey }
        if let baseURL { section["base_url"] = baseURL }
        if let textOnly { section["text_only"] = textOnly }
        if lane != .local { section["effort"] = effort ?? "high" }
        var payload: [String: Any] = ["provider": section]
        if snapshot.openAIMasked != nil { payload["web_search_backend"] = WebSearchBackend.openai.rawValue }
        try checkpoint()
        let apply = env.apply
        guard let result = try await guardedAIWrite(basis, { await apply(payload, checkpoint) }) else { return (false, staleMessage) }
        try checkpoint()
        await reload()
        guard result["ok"] as? Bool == true else { return (false, applyError(result)) }
        plannedLane = nil
        let label = Self.modelLabel(lane, model)
        return (true, L("Briglia now thinks with \(label) on \(lane.title(lang)).", "Ora Briglia ragiona con \(label) su \(lane.title(lang))."))
    }

    /// The reasoning level of the running provider.
    private func changeEffort(_ effort: String, basis: MenuAIState, checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        guard let active = activeLane else { return (false, L("Set up an AI provider first.", "Prima configura un fornitore AI.")) }
        let model = active == .chatgpt ? (currentModel ?? "") : (snapshot.providers[active.rawValue]?.model ?? "")
        guard effortChoices(active, model: model).contains(effort) else { return (false, L("Unknown thinking level.", "Livello di ragionamento sconosciuto.")) }
        try checkpoint()
        let request: [String: Any]
        let viaSubscription = active == .chatgpt
        if viaSubscription {
            request = ["action": "select", "model": model, "effort": effort]
        } else {
            let p = snapshot.providers[active.rawValue] ?? MenuSnapshot.Provider()
            request = ["provider": ["profile": active.profile.rawValue, "model": p.model, "effort": effort,
                                    "text_only": p.textOnly, "activate": true] as [String: Any]]
        }
        // Rebuilt from the snapshot above, so only written while the saved
        // model/provider are still the ones the page showed: an effort
        // change never restores a model or provider switched elsewhere.
        let env = self.env
        guard let result = try await guardedAIWrite(basis, {
            viaSubscription ? await env.subscription(request, checkpoint) : await env.apply(request, checkpoint)
        }) else { return (false, staleMessage) }
        try checkpoint()
        await reload()
        guard result["ok"] as? Bool == true else { return (false, applyError(result)) }
        return (true, L("Saved. It applies from the next message.", "Salvato. Vale dal prossimo messaggio."))
    }

    /// Asks a local server for its models. Read-only; the answer shows on
    /// the page only while no newer AI choice replaced this one.
    private func listLocalModels(_ raw: String, generation g: Int) async -> (Bool, String?) {
        guard let base = MenuEnvironment.localBase(raw) else {
            return (false, L("That address doesn\u{2019}t look right. It looks like http://localhost:1234/v1.", "Questo indirizzo non sembra giusto. Somiglia a http://localhost:1234/v1."))
        }
        let ticket = validity.ticket(generation: g, slot: "ai", claim: false)
        localListing = LocalListing(base: base, state: "checking")
        let result = await env.localModels(base)
        guard validity.isValid(ticket), localListing?.base == base else { return (true, nil) }
        switch result {
        case .success(let models):
            localListing = LocalListing(base: base, state: "ok", models: models)
            return (true, nil)
        case .failure(let why):
            let message: String
            switch why {
            case .badAddress: message = L("That address doesn\u{2019}t look right.", "Questo indirizzo non sembra giusto.")
            case .unreachable: message = L("Nothing answered at \(base). Is the model server running (LM Studio: Developer → Start server; Ollama: ollama serve)?", "Nessuna risposta da \(base). Il server del modello è acceso (LM Studio: Developer → Start server; Ollama: ollama serve)?")
            case .http(let code): message = L("The server answered with an error (HTTP \(code)). Check the address — it usually ends in /v1.", "Il server ha risposto con un errore (HTTP \(code)). Controlla l\u{2019}indirizzo: di solito finisce con /v1.")
            case .noModels: message = L("The server is running but has no model loaded. Load one, then try again.", "Il server è acceso ma non ha nessun modello caricato. Caricane uno, poi riprova.")
            }
            localListing = LocalListing(base: base, state: "error", message: message)
            return (false, message)
        }
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
        if (payload["error"] as? [String: Any])?["code"] as? String == "agent_busy" {
            return L("Briglia is busy with a message right now. Try again when it has answered.", "Briglia sta rispondendo a un messaggio. Riprova quando ha finito.")
        }
        return ((payload["error"] as? [String: Any])?["message"] as? String) ?? L("something went wrong while saving", "qualcosa è andato storto durante il salvataggio")
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
        return keyError(service: service, reason)
    }

    func keyError(service: String, _ reason: String) -> String {
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
        case .openai: return openAIRequired
            ? L("Web research, voice messages and image creation are on.", "Ricerche web, messaggi vocali e creazione di immagini attivi.")
            : L("Voice messages and image creation are on.", "Messaggi vocali e creazione di immagini attivi.")
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
