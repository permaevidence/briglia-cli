import ArgumentParser
import Foundation

/// `briglia __menu-selftest` — offline battery for `briglia menu`: the
/// Telegram chat detection, every page action of the real `MenuWorkflow`
/// driven with fake services (no network, no real sign-in), and the router's
/// authorization in front of the menu routes. Isolation: XDG roots and TMPDIR point at a temp directory
/// before anything touches storage; the one real process step (a toolchain
/// job through SetupJobRunner) runs `/bin/sh` inside that directory.
struct MenuSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__menu-selftest",
        abstract: "Internal: verify the briglia menu (flows, page state, router).",
        shouldDisplay: false
    )

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("briglia-menu-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_CONFIG_HOME", tempRoot.path, 1)
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path + "/", 1)
        StoragePaths.ensureRoots()

        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            if !Task.isCancelled { print("WATCHDOG: menu selftest exceeded 180s — hung; aborting"); Foundation.exit(3) }
        }
        defer { watchdog.cancel() }

        let failures = await Self.battery(tempRoot: tempRoot)
        if failures > 0 { throw ExitCode(1) }
    }

    @MainActor
    static func battery(tempRoot: URL) async -> Int {
        let t = MenuSelftestContext(tempRoot: tempRoot)
        t.telegramDetection()
        await t.guidedFirstRun()
        await t.chatgptVariants()
        await t.telegramVariants()
        await t.keysAndEmail()
        await t.providerLanes()
        await t.openRouterLaneWithoutOpenAI()
        t.localServerParsing()
        await t.liveHub()
        await t.staleSettings()
        await t.liveSignIn()
        await t.liveEmail()
        await t.lateEmailEffects()
        await t.linuxComputer()
        await t.finishGuards()
        await t.staleOperations()
        await t.routerRotation()
        await t.linuxStartup()
        await t.router()
        print(t.failures == 0 ? "\nmenu selftest: all \(t.checks) checks passed"
                              : "\nmenu selftest: \(t.failures) of \(t.checks) FAILED")
        return t.failures
    }
}

// MARK: - Fake world

/// Everything the fake services know. Touched from the app (main actor) and
/// from the env closures the app awaits one at a time.
final class MenuFakeWorld: @unchecked Sendable {
    var snap = MenuSnapshot()
    let good = ["serper": "srp-good-0123456789abcdef", "jina": "jina_good_0123456789abcdef",
                "openai": "sk-good-0123456789abcdefghij", "agentmail": "am_good_0123456789abcdef",
                "telegram": "123456789:AAgoodtoken0123456789",
                "opencode": "oc-good-0123456789abcdef", "openrouter": "sk-or-good-0123456789abcdef",
                "custom": "sk-custom-good-0123456789abcdef"]
    var localModels: Result<[String], MenuLocalModelsError> = .success(["qwen3.8-27b", "gemma-4-12b"])
    var localModelAsks: [String] = []
    /// The key each model listing was sent with (nil = none).
    var localModelKeys: [String?] = []
    /// When set, listings refuse (HTTP 401) unless sent this key.
    var localNeedsKey: String?
    var applied: [[String: Any]] = []
    var probes: [String] = []
    var scan: MenuTelegramScan = .waiting
    var scanCount = 0
    var loginFailure: String?
    var loginBlocks = false
    var loginShown: [String] = []
    var subscriptionProbeFails = false
    var selectFails = false
    var markedComplete = false
    var fda = false
    var settingsOpened = 0
    var urlsOpened: [String] = []
    var toolMarker: URL
    var toolchainChecks = 0
    var agentMailInstalls = 0
    var gnomeFixed = false
    var clock = Date(timeIntervalSince1970: 2_000_000_000)
    /// Probes (by key/token, or "chat:<id>" for the Telegram chat check)
    /// held until the row opens the gate.
    var holds: [String: MenuGate] = [:]
    /// Writes refused by the operation's checkpoint.
    var voidedWrites = 0
    /// ChatGPT credentials written by a sign-in's commit.
    var loginCommits = 0
    var loginBlock: MenuLoginBlock?

    init(toolMarker: URL) { self.toolMarker = toolMarker }

    func toolchain() -> ToolchainService.DesktopStatus {
        toolchainChecks += 1
        let installed = FileManager.default.fileExists(atPath: toolMarker.path)
        return ToolchainService.DesktopStatus(doctorRan: true, missing: installed ? [] : ["pandoc"],
                                              libreOffice: true, mandatoryMissing: installed ? [] : ["pandoc"])
    }

    func apply(_ req: [String: Any]) -> [String: Any] {
        applied.append(req)
        if let id = req["identity"] as? [String: Any] { snap.userName = id["user_name"] as? String ?? "" }
        for (section, path) in [("serper", \MenuSnapshot.serperMasked), ("jina", \MenuSnapshot.jinaMasked), ("openai", \MenuSnapshot.openAIMasked)] {
            guard let body = req[section] as? [String: Any] else { continue }
            if body["remove"] as? Bool == true { snap[keyPath: path] = nil }
            else if let k = body["api_key"] as? String { snap[keyPath: path] = WizardIO.masked(k) }
        }
        if let tg = req["telegram"] as? [String: Any] {
            snap.telegramConfigured = true
            snap.telegramChatId = tg["chat_id"] as? String ?? ""
        }
        if let pr = req["provider"] as? [String: Any], let profile = pr["profile"] as? String {
            var p = snap.providers[profile] ?? MenuSnapshot.Provider()
            p.configured = true
            p.model = pr["model"] as? String ?? p.model
            p.effort = pr["effort"] as? String ?? (profile == "local" ? "" : p.effort)
            if let t = pr["text_only"] as? Bool { p.textOnly = t }
            else if profile == "opencode" { p.textOnly = OpenCodeGo.catalogEntry(for: p.model)?.textOnly ?? false }
            if let b = pr["base_url"] as? String { p.endpoint = b }
            if let k = pr["api_key"] as? String { p.keyMasked = WizardIO.masked(k) }
            snap.providers[profile] = p
            if pr["activate"] as? Bool == true {
                snap.activeProfile = profile
                snap.otherProvider = ProviderProfiles.Profile(rawValue: profile)?.displayName
                if case .signedIn(_, let m, let e, let g) = snap.chatgpt { snap.chatgpt = .signedIn(active: false, model: m, effort: e, generation: g) }
            }
        }
        if let em = req["email_calendar"] as? [String: Any] {
            snap.emailProvider = em["provider"] as? String ?? "none"
            if let k = em["api_key"] as? String { snap.agentMailMasked = WizardIO.masked(k); snap.agentMailInbox = "bree@agentmail.to" }
        }
        return ["ok": true]
    }

    func probe(_ req: [String: Any]) -> [String: Any] {
        let kind = req["kind"] as? String ?? ""
        probes.append(kind)
        if kind == "custom" || kind == "responses" {
            return req["model"] as? String == "deepseek-v4.1-flash" ? ["ok": false, "reason": "HTTP 403 RegionError"] : ["ok": true]
        }
        if kind == "local" {
            return req["base_url"] as? String == "http://localhost:1234/v1" ? ["ok": true] : ["ok": false, "reason": "connection refused"]
        }
        if kind == "openrouter", req["model"] as? String == "nobody/nothing" { return ["ok": false, "reason": "HTTP 400 — not a valid model ID"] }
        if kind == "telegram" {
            return req["token"] as? String == good["telegram"] ? ["ok": true, "bot_username": "sofia_test_bot"] : ["ok": false, "reason": "Telegram returned HTTP 401"]
        }
        if let k = req["api_key"] as? String, let g = good[kind], k == g || k.hasPrefix(g + "-alt") {
            return kind == "agentmail" ? ["ok": true, "inboxes": ["bree@agentmail.to"]] : ["ok": true]
        }
        return ["ok": false, "reason": "\(kind) returned HTTP 401 — unauthorized"]
    }

    func subscription(_ req: [String: Any]) -> [String: Any] {
        switch req["action"] as? String {
        case "select":
            if selectFails { return ["ok": false, "error": ["message": "Stop Briglia first"]] }
            snap.chatgpt = .signedIn(active: true, model: req["model"] as? String ?? "", effort: req["effort"] as? String ?? "", generation: "g1")
            snap.otherProvider = nil
            snap.activeProfile = "chatgpt"
            return ["ok": true, "state": "signed_in"]
        case "probe":
            return subscriptionProbeFails ? ["ok": false, "error": ["message": "model not available on this plan"]] : ["ok": true, "state": "verified"]
        case "logout":
            snap.chatgpt = .signedOut
            return ["ok": true, "state": "signed_out"]
        default:
            return ["ok": true]
        }
    }
}


final class MenuGenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 1
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// A one-shot gate: probes wait on it until the row opens it.
final class MenuGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrived = 0
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrived += 1
            if isOpen { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
        }
    }
    func open() {
        lock.lock(); isOpen = true; let w = waiters; waiters = []; lock.unlock()
        for c in w { c.resume() }
    }
    var hasArrived: Bool { lock.lock(); defer { lock.unlock() }; return arrived > 0 }
}

@MainActor
final class MenuSelftestContext {
    let tempRoot: URL
    var checks = 0
    var failures = 0
    init(tempRoot: URL) { self.tempRoot = tempRoot }

    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if ok { print("✔ \(label)") } else { failures += 1; print("✖ \(label)\(detail().isEmpty ? "" : " — \(detail())")") }
    }

    func env(_ world: MenuFakeWorld, linux: Bool = false, browserLikely: Bool = true) -> MenuEnvironment {
        var env = MenuEnvironment()
        env.isLinux = linux
        env.browserLikely = browserLikely
        env.language = "en"
        env.snapshot = { world.snap }
        env.toolchainStatus = { world.toolchain() }
        env.probe = { req in
            if let gate = world.holds[(req["api_key"] as? String) ?? (req["token"] as? String) ?? ""] { await gate.wait() }
            return world.probe(req)
        }
        // Like setup-api / SubscriptionSetup: the checkpoint runs right
        // before the write and a throw means nothing is written.
        env.apply = { req, checkpoint in
            do { try checkpoint() } catch { world.voidedWrites += 1; return ["ok": false, "error": ["code": "superseded", "message": "superseded"]] }
            return world.apply(req)
        }
        env.subscription = { req, checkpoint in
            do { try checkpoint() } catch { world.voidedWrites += 1; return ["ok": false, "error": ["code": "subscription", "message": "superseded"]] }
            return world.subscription(req)
        }
        // Like SubscriptionLogin: the credential is written through the
        // commit hook once the human part is done.
        env.browserLogin = { show, commit in
            show("https://auth.example/oauth/authorize?state=x")
            world.loginShown.append("browser")
            if world.loginBlocks { try await Task.sleep(nanoseconds: 60_000_000_000) }
            if let f = world.loginFailure { throw SubscriptionError(f) }
            _ = try await commit { pre in try pre?(); world.loginCommits += 1; return "gen-fake" }
        }
        env.deviceLogin = { show, commit in
            show("https://auth.example/codex/device", "ABCD-1234")
            world.loginShown.append("device")
            if world.loginBlocks { try await Task.sleep(nanoseconds: 60_000_000_000) }
            if let f = world.loginFailure { throw SubscriptionError(f) }
            _ = try await commit { pre in try pre?(); world.loginCommits += 1; return "gen-fake" }
        }
        env.loginBlock = { world.loginBlock }
        env.telegramScan = { _, _ in world.scanCount += 1; return world.scan }
        env.localModels = { base, key in
            world.localModelAsks.append(base); world.localModelKeys.append(key)
            if let need = world.localNeedsKey, key != need { return .failure(.http(401)) }
            return world.localModels
        }
        env.providerKey = { profile in world.snap.providers[profile.rawValue]?.configured == true ? world.good[profile.rawValue] : nil }
        env.telegramChatProbe = { _, chatId in
            if let gate = world.holds["chat:" + chatId] { await gate.wait() }
            var p = SetupAPICore.TelegramChatProbe()
            if chatId != "5551234567" { p.failure = "chat not found — open @sofia_test_bot in Telegram, send /start, then tap Retry" }
            return p
        }
        env.openURL = { world.urlsOpened.append($0) }
        env.markComplete = { world.markedComplete = true }
        env.quick.fullDiskAccessGranted = { world.fda }
        env.quick.openSettingsPane = { world.settingsOpened += 1 }
        env.quick.disableGnomeAutoSuspend = { world.gnomeFixed = true; world.snap.keepAwakeOK = true; return true }
        env.quick.maskSleepTargetsJob = { nil }
        let marker = world.toolMarker.path
        env.quick.toolchainJobs = { _ in
            [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "echo installing pandoc; touch '\(marker)'; echo done"],
                                 mode: .detached, timeout: 30, label: "brew install pandoc")]
        }
        env.quick.installAgentMail = { progress, _, _ in
            progress("downloading agentmail")
            world.agentMailInstalls += 1
            world.snap.agentMailCLIInstalled = true
            return nil
        }
        return env
    }

    func make(_ world: MenuFakeWorld, linux: Bool = false, browserLikely: Bool = true) async -> MenuWorkflow {
        let wf = MenuWorkflow(env: env(world, linux: linux, browserLikely: browserLikely), runner: SetupJobRunner(secrets: [:]))
        wf.now = { world.clock }
        await wf.start()
        await wf.settle()
        return wf
    }

    func world() -> MenuFakeWorld {
        let w = MenuFakeWorld(toolMarker: tempRoot.appendingPathComponent("tools-\(UUID().uuidString)"))
        w.snap.fdaGranted = false
        w.snap.terminalApp = "Terminal"
        w.snap.keepAwakeOK = true
        w.snap.keepAwakeSummary = "Briglia keeps this Mac awake while it runs"
        return w
    }

    /// One page action, then wait for the background work it started.
    @discardableResult
    func act(_ wf: MenuWorkflow, _ body: [String: Any], settle: Bool = true) async -> [String: Any] {
        let r = await wf.handle(body) ?? ["ok": false, "revoked": true]
        if settle { await wf.settle() }
        return r
    }

    func ok(_ r: [String: Any]) -> Bool { r["ok"] as? Bool == true }
    func msg(_ r: [String: Any]) -> String { r["message"] as? String ?? "" }
    func json(_ any: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
    func step(_ wf: MenuWorkflow, _ id: String) -> [String: Any] {
        ((wf.status()["steps"] as? [[String: Any]]) ?? []).first { $0["id"] as? String == id } ?? [:]
    }
    func done(_ wf: MenuWorkflow, _ id: String) -> Bool { step(wf, id)["done"] as? Bool == true }

    // MARK: 1. Telegram detection

    func telegramDetection() {
        let since = Date(timeIntervalSince1970: 2_000_000_000)
        func upd(_ chat: Int64, type: String = "private", from: Int64? = nil, date: Double = 2_000_000_010, name: String = "Sofia", bot: Bool = false) -> [String: Any] {
            ["update_id": 1, "message": ["date": date, "chat": ["id": chat, "type": type],
                                          "from": ["id": from ?? chat, "first_name": name, "username": name.lowercased(), "is_bot": bot]]]
        }
        func verdict(_ updates: [[String: Any]]) -> MenuTelegramScan {
            let body = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": updates])
            return MenuEnvironment.interpretUpdates(data: body, status: 200, since: since)
        }
        check("a private message from the chat owner is found", verdict([upd(5551234567)]) == .found(chatId: "5551234567", name: "Sofia (@sofia)"))
        check("group messages are ignored", verdict([upd(-100123, type: "group", from: 42)]) == .waiting)
        check("a chat whose sender differs is ignored", verdict([upd(777, from: 888)]) == .waiting)
        check("messages from bots are ignored", verdict([upd(777, bot: true)]) == .waiting)
        check("messages from before the waiting screen are ignored", verdict([upd(777, date: 1_999_999_000)]) == .waiting)
        check("the newest private message wins", verdict([upd(111, date: 2_000_000_005, name: "Old"), upd(222, date: 2_000_000_020, name: "New")]) == .found(chatId: "222", name: "New (@new)"))
        func error(_ status: Int, _ description: String) -> MenuTelegramScan {
            MenuEnvironment.interpretUpdates(data: try! JSONSerialization.data(withJSONObject: ["ok": false, "description": description]), status: status, since: since)
        }
        if case .failed(let why) = error(409, "Conflict: can't use getUpdates method while webhook is active") { check("webhook conflict is explained", why.contains("webhook")) } else { check("webhook conflict is explained", false) }
        if case .failed(let why) = error(409, "Conflict: terminated by other getUpdates request") { check("a competing poller is explained", why.contains("Another program")) } else { check("a competing poller is explained", false) }
        if case .failed(let why) = error(401, "Unauthorized") { check("a revoked token is explained", why.contains("BotFather")) } else { check("a revoked token is explained", false) }
    }

    // MARK: 2. Guided first run

    func guidedFirstRun() async {
        let w = world()
        let wf = await make(w)
        var st = wf.status()
        check("a fresh install is not complete and every required step is open", st["complete"] as? Bool == false && wf.missingRequired.count == 7)
        check("the page learns the platform and that a desktop browser is likely", st["platform"] as? String == "macos" && st["browser_likely"] as? Bool == true)

        var r = await act(wf, ["action": "name", "name": "  "])
        check("an empty name is refused", !ok(r))
        r = await act(wf, ["action": "name", "name": "Sofia"])
        check("the name is saved through setup-api identity", ok(r) && (w.applied.last?["identity"] as? [String: Any])?["user_name"] as? String == "Sofia" && done(wf, "name"))

        r = await act(wf, ["action": "chatgpt_browser"])
        check("browser sign-in opens the ChatGPT link", ok(r) && w.urlsOpened.first?.hasPrefix("https://auth.example/") == true)
        check("after sign-in ChatGPT is selected with GPT-6 Sol + high and checked", w.snap.chatgpt == .signedIn(active: true, model: "gpt-6-sol", effort: "high", generation: "g1") && done(wf, "ai"))
        st = wf.status()
        check("a finished sign-in leaves no login state behind", (st["chatgpt"] as? [String: Any])?["login"] == nil)

        r = await act(wf, ["action": "telegram_token", "token": "not-a-token"])
        check("a token without a colon is refused before any network call", !ok(r) && msg(r).contains("doesn\u{2019}t look like a bot token") && !w.probes.contains("telegram"))
        r = await act(wf, ["action": "telegram_token", "token": "123456789:AAwrong"])
        check("a wrong token is refused by the probe", !ok(r) && msg(r).contains("didn\u{2019}t accept this token"))
        r = await act(wf, ["action": "telegram_token", "token": w.good["telegram"]!])
        let pending = ((r["status"] as? [String: Any])?["telegram"] as? [String: Any])?["pending"] as? [String: Any]
        check("a good token waits for a message to the bot", ok(r) && pending?["state"] as? String == "waiting" && pending?["bot"] as? String == "sofia_test_bot")
        check("the bot token never appears in the page state", !json(r).contains(w.good["telegram"]!))
        _ = wf.status(); await wf.settle()
        check("polling the status scans Telegram", w.scanCount == 1)
        _ = wf.status(); await wf.settle()
        check("scans are throttled to every 2 seconds", w.scanCount == 1)
        w.scan = .found(chatId: "5551234567", name: "Sofia (@sofia)")
        w.clock = w.clock.addingTimeInterval(3)
        _ = wf.status(); await wf.settle()
        let found = ((wf.status()["telegram"] as? [String: Any])?["pending"] as? [String: Any])
        check("the detected chat is offered for confirmation", found?["state"] as? String == "found" && found?["name"] as? String == "Sofia (@sofia)")
        r = await act(wf, ["action": "telegram_confirm", "chat_id": "5551234567"])
        let tg = w.applied.last?["telegram"] as? [String: Any]
        check("confirming saves token + chat id", ok(r) && tg?["chat_id"] as? String == "5551234567" && tg?["token"] as? String == w.good["telegram"] && done(wf, "telegram"))
        check("the connected bot is shown by name", (wf.status()["telegram"] as? [String: Any])?["bot"] as? String == "sofia_test_bot")

        r = await act(wf, ["action": "key", "kind": "serper", "key": "srp-wrong-0123456789"])
        check("a refused key is explained in plain words", !ok(r) && msg(r).contains("Serper refused this key"))
        r = await act(wf, ["action": "key", "kind": "serper", "key": w.good["serper"]!])
        check("a good key is checked and saved in one action (no verify step)", ok(r) && msg(r) == "Web search is on." && done(wf, "serper") && w.probes.filter { $0 == "serper" }.count == 2)
        r = await act(wf, ["action": "key", "kind": "jina", "key": w.good["jina"]!])
        check("Jina saved", ok(r) && done(wf, "jina"))
        check("no full key appears in the page state", !w.good.values.contains { json(wf.status()).contains($0) })

        check("Full Disk Access is still missing", !done(wf, "computer") && step(wf, "computer")["summary"] as? String == "Needs Full Disk Access")
        r = await act(wf, ["action": "fda_open"])
        check("“Open System Settings” opens the pane", ok(r) && w.settingsOpened == 1)
        w.fda = true
        w.clock = w.clock.addingTimeInterval(2)
        check("granting Full Disk Access is noticed on the next status", done(wf, "computer"))

        check("the tools step shows what's missing", ((wf.status()["tools"] as? [String: Any])?["missing"] as? [String]) == ["pandoc"])
        check("setup is not marked complete before the tools", !w.markedComplete)
        r = await act(wf, ["action": "tools_install"])
        check("installing runs the toolchain job for real", ok(r) && FileManager.default.fileExists(atPath: w.toolMarker.path))
        check("the installer output is kept for the page", wf.jobLines.contains("installing pandoc"))
        check("after a complete install setup is marked complete", w.markedComplete && wf.status()["complete"] as? Bool == true)
        r = await act(wf, ["action": "finish", "what": "start"])
        check("“Start Briglia” closes the page with start", ok(r) && (r["status"] as? [String: Any])?["closing"] as? String == "start" && wf.closing == "start")
        r = await act(wf, ["action": "name", "name": "Other"])
        check("nothing changes once the page is closing", !ok(r) && w.snap.userName == "Sofia")
    }

    // MARK: 3. ChatGPT variants

    func chatgptVariants() async {
        var w = world()
        w.loginBlocks = true
        var wf = await make(w, browserLikely: false)
        check("without a desktop browser the page is told to put the code first", wf.status()["browser_likely"] as? Bool == false)
        var r = await act(wf, ["action": "chatgpt_code"], settle: false)
        let login = ((r["status"] as? [String: Any])?["chatgpt"] as? [String: Any])?["login"] as? [String: Any]
        check("code sign-in answers with the URL and the code", ok(r) && login?["code"] as? String == "ABCD-1234" && login?["url"] as? String == "https://auth.example/codex/device")
        r = await act(wf, ["action": "chatgpt_cancel"])
        check("cancel ends a waiting sign-in", ok(r) && (wf.status()["chatgpt"] as? [String: Any])?["login"] == nil && msg(r) == "Sign-in cancelled.")
        w.loginBlocks = false
        w.loginFailure = "Device login unavailable (HTTP 403); enable device login in ChatGPT security settings or use browser login"
        r = await act(wf, ["action": "chatgpt_code"])
        let failed = ((wf.status()["chatgpt"] as? [String: Any])?["login"] as? [String: Any])
        check("a disabled device login gets the settings hint", (failed?["message"] as? String ?? msg(r)).contains("Enable device code authorization for Codex"))

        w = world(); w.subscriptionProbeFails = true
        wf = await make(w)
        r = await act(wf, ["action": "chatgpt_browser"])
        let err = ((wf.status()["chatgpt"] as? [String: Any])?["login"] as? [String: Any])
        check("a model the plan lacks is explained and another model suggested", err?["state"] as? String == "error" && (err?["message"] as? String ?? "").contains("pick another one"))

        w = world()
        w.snap.chatgpt = .signedIn(active: true, model: "gpt-6-sol", effort: "max", generation: "g0")
        wf = await make(w)
        r = await act(wf, ["action": "chatgpt_model", "model": "gpt-6-astra"])
        check("a new model keeps a compatible thinking level", ok(r) && w.snap.chatgpt == .signedIn(active: true, model: "gpt-6-astra", effort: "max", generation: "g1"))
        r = await act(wf, ["action": "chatgpt_model", "model": "gpt-9-imaginary"])
        check("an unknown model is refused", !ok(r))
        r = await act(wf, ["action": "chatgpt_logout"])
        check("sign out works and says Briglia can't answer", ok(r) && w.snap.chatgpt == .signedOut && msg(r).contains("can\u{2019}t answer"))

        w = world()
        w.snap.otherProvider = "OpenCode Go"
        w.snap.chatgpt = .signedIn(active: false, model: "gpt-6-sol", effort: "high", generation: "g")
        wf = await make(w)
        let c = wf.status()["chatgpt"] as? [String: Any]
        check("a signed-in but unused login reports the other provider", c?["active"] as? Bool == false && c?["other_provider"] as? String == "OpenCode Go")
        r = await act(wf, ["action": "chatgpt_use"])
        check("“Use ChatGPT for Briglia” selects it", ok(r) && done(wf, "ai"))
    }

    // MARK: 4. Telegram variants

    func telegramVariants() async {
        let w = world()
        let wf = await make(w)
        var r = await act(wf, ["action": "telegram_confirm", "chat_id": "5551234567"])
        check("confirming before a token is refused", !ok(r))
        await act(wf, ["action": "telegram_token", "token": w.good["telegram"]!])
        r = await act(wf, ["action": "telegram_manual"])
        check("the ID can be typed by hand", ok(r) && ((wf.status()["telegram"] as? [String: Any])?["pending"] as? [String: Any])?["state"] as? String == "manual")
        r = await act(wf, ["action": "telegram_confirm", "chat_id": "sofia"])
        check("a username instead of an ID is refused", !ok(r) && msg(r).contains("is a number"))
        r = await act(wf, ["action": "telegram_confirm", "chat_id": "42"])
        check("an ID the bot can't see yet explains /start", !ok(r) && msg(r).contains("send /start"))
        r = await act(wf, ["action": "telegram_confirm", "chat_id": "5551234567"])
        check("a typed ID is verified and saved", ok(r) && w.snap.telegramChatId == "5551234567")

        let w2 = world()
        let wf2 = await make(w2)
        await act(wf2, ["action": "telegram_token", "token": w2.good["telegram"]!])
        w2.scan = .failed("This bot is connected to another service (a webhook)")
        w2.clock = w2.clock.addingTimeInterval(3)
        _ = wf2.status(); await wf2.settle()
        let t = wf2.status()["telegram"] as? [String: Any]
        check("a scan failure clears the pending bot and explains why", t?["pending"] == nil && (t?["error"] as? String ?? "").contains("webhook"))
        w2.scan = .waiting
        await act(wf2, ["action": "telegram_token", "token": w2.good["telegram"]!])
        check("a new token clears the old error", (wf2.status()["telegram"] as? [String: Any])?["error"] == nil)
        w2.scan = .found(chatId: "999", name: "Someone")
        w2.clock = w2.clock.addingTimeInterval(3)
        _ = wf2.status(); await wf2.settle()
        r = await act(wf2, ["action": "telegram_wait"])
        check("“No” (not me) keeps waiting", ok(r) && ((wf2.status()["telegram"] as? [String: Any])?["pending"] as? [String: Any])?["state"] as? String == "waiting")
        r = await act(wf2, ["action": "telegram_reset"])
        check("“Use another bot” starts over", ok(r) && (wf2.status()["telegram"] as? [String: Any])?["pending"] == nil)
    }

    // MARK: 5. Keys and email

    func keysAndEmail() async {
        let w = world()
        let wf = await make(w)
        var r = await act(wf, ["action": "key", "kind": "openai", "key": w.good["openai"]!])
        check("the optional OpenAI key is saved", ok(r) && done(wf, "openai") && msg(r).contains("Voice messages"))
        r = await act(wf, ["action": "key_remove", "kind": "openai"])
        check("the OpenAI key can be removed", ok(r) && !done(wf, "openai") && (w.applied.last?["openai"] as? [String: Any])?["remove"] as? Bool == true)
        r = await act(wf, ["action": "key_remove", "kind": "serper"])
        check("a required key can't be removed", !ok(r))
        r = await act(wf, ["action": "key", "kind": "rogue", "key": "x"])
        check("an unknown key kind is refused", !ok(r))
        r = await act(wf, ["action": "key", "kind": "serper", "key": "srp-good\nsecond-line"])
        check("a multi-line paste is refused", !ok(r))
        r = await act(wf, ["action": "key", "kind": "agentmail", "key": "am_wrong_000000000000"])
        check("a refused AgentMail key is explained", !ok(r) && msg(r).contains("AgentMail refused this key"))
        r = await act(wf, ["action": "key", "kind": "agentmail", "key": w.good["agentmail"]!])
        let em = w.applied.last?["email_calendar"] as? [String: Any]
        check("a good AgentMail key turns email on and names the address", ok(r) && em?["provider"] as? String == "agentmail" && msg(r).contains("bree@agentmail.to"))
        check("the email tool is installed right after", w.agentMailInstalls == 1 && (wf.status()["email"] as? [String: Any])?["tool_installed"] as? Bool == true)
        r = await act(wf, ["action": "email_off"])
        check("email can be turned off (key kept)", ok(r) && w.snap.emailProvider == "none" && w.snap.agentMailMasked != nil && !done(wf, "email"))
    }

    // MARK: 5b. Provider lanes (OpenCode Go, OpenRouter, local), switching,
    // thinking level, the OpenAI-key rule and Stop.

    func lastProvider(_ w: MenuFakeWorld) -> [String: Any]? { w.applied.last?["provider"] as? [String: Any] }
    func ai(_ wf: MenuWorkflow) -> [String: Any] { wf.status()["ai"] as? [String: Any] ?? [:] }
    func aiProvider(_ wf: MenuWorkflow, _ id: String) -> [String: Any] { (ai(wf)["providers"] as? [String: Any])?[id] as? [String: Any] ?? [:] }

    func providerLanes() async {
        // First run: ChatGPT is the default lane and the OpenAI key optional.
        var w = world()
        var wf = await make(w)
        check("a fresh install shows the ChatGPT lane with the OpenAI key optional",
              ai(wf)["lane"] as? String == "chatgpt" && ai(wf)["openai_required"] as? Bool == false && step(wf, "openai")["required"] as? Bool == false && step(wf, "ai")["title"] as? String == "ChatGPT")
        var r = await act(wf, ["action": "lane", "lane": "opencode"])
        check("choosing OpenCode makes the OpenAI key required and renames the steps",
              ok(r) && ai(wf)["planned"] as? String == "opencode" && wf.missingRequired.contains(.openai)
              && step(wf, "ai")["title"] as? String == "OpenCode Go" && step(wf, "openai")["title"] as? String == "OpenAI key")
        r = await act(wf, ["action": "lane", "lane": "gemini"])
        check("an unknown lane is refused", !ok(r) && ai(wf)["planned"] as? String == "opencode")

        let appliedBefore = w.applied.count
        r = await act(wf, ["action": "provider_key", "profile": "opencode", "key": "oc-wrong-000000000000"])
        check("a refused OpenCode key is explained and nothing is saved", !ok(r) && msg(r).contains("OpenCode Go refused this key") && w.applied.count == appliedBefore)
        r = await act(wf, ["action": "provider_key", "profile": "opencode", "key": w.good["opencode"]!])
        var pr = lastProvider(w)
        check("a good OpenCode key saves GLM 5.3 Flash at high and switches to it",
              ok(r) && pr?["profile"] as? String == "opencode" && pr?["model"] as? String == OpenCodeGo.defaultModel && pr?["effort"] as? String == "high"
              && pr?["activate"] as? Bool == true && pr?["api_key"] as? String == w.good["opencode"] && done(wf, "ai") && ai(wf)["active"] as? String == "opencode" && ai(wf)["planned"] is NSNull)
        check("without an OpenAI key the research backend is left alone", w.applied.last?["web_search_backend"] == nil)
        check("the page never gets the provider key back, only its masked form",
              !json(wf.status()).contains(w.good["opencode"]!) && (aiProvider(wf, "opencode")["key"] as? String)?.isEmpty == false)
        check("the OpenAI key is still required after the switch", step(wf, "openai")["required"] as? Bool == true && !done(wf, "openai"))
        r = await act(wf, ["action": "key", "kind": "openai", "key": w.good["openai"]!])
        check("with OpenCode the OpenAI key turns on web research too", ok(r) && msg(r).contains("Web research") && done(wf, "openai"))
        r = await act(wf, ["action": "key_remove", "kind": "openai"])
        check("the required OpenAI key can't be removed", !ok(r) && msg(r).contains("can\u{2019}t be removed") && done(wf, "openai"))

        let probesBefore = w.probes.count
        r = await act(wf, ["action": "provider_model", "profile": "opencode", "model": "kimi-k3"])
        pr = lastProvider(w)
        check("a new OpenCode model is checked with the saved key, then saved; research set to OpenAI",
              ok(r) && w.probes.count == probesBefore + 1 && w.probes.last == "custom" && pr?["model"] as? String == "kimi-k3" && pr?["api_key"] == nil
              && w.applied.last?["web_search_backend"] as? String == "openai")
        r = await act(wf, ["action": "provider_model", "profile": "opencode", "model": "deepseek-v4.1-flash"])
        check("a model the account can't use is refused, the old one stays", !ok(r) && msg(r).contains("RegionError") && aiProvider(wf, "opencode")["model"] as? String == "kimi-k3")
        r = await act(wf, ["action": "provider_model", "profile": "opencode", "model": "glm-5.3"])
        check("a model outside the OpenCode picker is refused", !ok(r))
        r = await act(wf, ["action": "provider_model", "profile": "opencode", "model": "gpt-5.6-luna"])
        check("a Responses model on OpenCode is checked over Responses", ok(r) && w.probes.last == "responses")
        check("GPT on OpenCode offers the Responses thinking levels incl. Deepest", (aiProvider(wf, "opencode")["efforts"] as? [String]) == ["low", "medium", "high", "xhigh"])
        await act(wf, ["action": "provider_model", "profile": "opencode", "model": "glm-5.3-flash"])
        check("GLM on OpenCode offers Light/Balanced/Deep", (aiProvider(wf, "opencode")["efforts"] as? [String]) == ["low", "medium", "high"])
        r = await act(wf, ["action": "effort", "effort": "xhigh"])
        check("a thinking level the model doesn't take is refused", !ok(r))
        r = await act(wf, ["action": "effort", "effort": "medium"])
        pr = lastProvider(w)
        check("the thinking level is saved on the running provider", ok(r) && pr?["effort"] as? String == "medium" && pr?["model"] as? String == "glm-5.3-flash" && aiProvider(wf, "opencode")["effort"] as? String == "medium")

        // OpenRouter, added from "Switch or add a provider" while OpenCode runs.
        r = await act(wf, ["action": "lane", "lane": "openrouter"])
        check("setting up OpenRouter keeps OpenCode running meanwhile", ok(r) && ai(wf)["lane"] as? String == "openrouter" && ai(wf)["active"] as? String == "opencode" && done(wf, "ai"))
        r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
        pr = lastProvider(w)
        check("an OpenRouter key is checked with the default model and switched to",
              ok(r) && pr?["profile"] as? String == "openrouter" && pr?["model"] as? String == MenuWorkflow.openRouterDefaultModel && ai(wf)["active"] as? String == "openrouter")
        r = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "nobody/nothing"])
        check("an OpenRouter model id OpenRouter doesn't know is refused", !ok(r) && msg(r).contains("not a valid model"))
        r = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "moonshotai/kimi-k3", "text_only": true])
        check("an OpenRouter model can be saved as text-only", ok(r) && lastProvider(w)?["text_only"] as? Bool == true && aiProvider(wf, "openrouter")["text_only"] as? Bool == true)
        r = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "moonshotai/kimi-k3", "text_only": "yes"])
        check("a non-boolean text-only value is refused", !ok(r))
        r = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "two words"])
        check("a model id with spaces is refused", !ok(r))

        // Switching back keeps each provider's own setup.
        r = await act(wf, ["action": "provider_use", "profile": "opencode"])
        pr = lastProvider(w)
        check("switching back to OpenCode reuses its saved model, level and key",
              ok(r) && pr?["model"] as? String == "glm-5.3-flash" && pr?["effort"] as? String == "medium" && pr?["api_key"] == nil && ai(wf)["active"] as? String == "opencode")
        r = await act(wf, ["action": "provider_use", "profile": "local"])
        check("a lane that isn't set up can't be switched to", !ok(r) && msg(r).contains("Set up"))
        r = await act(wf, ["action": "provider_use", "profile": "chatgpt"])
        check("ChatGPT can't be switched to before signing in", !ok(r) && msg(r).contains("Sign in"))
        check("the dashboard names the running provider and model", step(wf, "ai")["title"] as? String == "OpenCode Go" && step(wf, "ai")["summary"] as? String == "GLM 5.3 Flash")

        // Local model: find the server's models, pick one.
        await act(wf, ["action": "lane", "lane": "local"])
        r = await act(wf, ["action": "local_models", "base_url": "ftp://nas.local/models"])
        check("a non-HTTP server address is refused", !ok(r) && w.localModelAsks.isEmpty)
        r = await act(wf, ["action": "local_models", "base_url": "localhost:1234/v1/"])
        let listing = ai(wf)["local"] as? [String: Any]
        check("the local server's models are listed (address normalized)",
              ok(r) && w.localModelAsks.last == "http://localhost:1234/v1" && listing?["state"] as? String == "ok" && (listing?["models"] as? [String]) == ["qwen3.8-27b", "gemma-4-12b"])
        w.localModels = .failure(.unreachable)
        r = await act(wf, ["action": "local_models", "base_url": "http://localhost:11434/v1"])
        check("a server that doesn't answer is explained", !ok(r) && msg(r).contains("Nothing answered") && (ai(wf)["local"] as? [String: Any])?["state"] as? String == "error")
        r = await act(wf, ["action": "provider_model", "profile": "local", "model": "qwen3.8-27b", "base_url": "http://localhost:11434/v1"])
        check("a local model the server doesn't answer with is refused", !ok(r) && msg(r).contains("didn\u{2019}t answer"))
        r = await act(wf, ["action": "provider_model", "profile": "local", "model": "qwen3.8-27b", "base_url": "http://localhost:1234/v1"])
        pr = lastProvider(w)
        check("a local model is saved with its address, no thinking level, and switched to",
              ok(r) && pr?["profile"] as? String == "local" && pr?["base_url"] as? String == "http://localhost:1234/v1" && pr?["effort"] == nil && ai(wf)["active"] as? String == "local")
        check("a local model offers no thinking level", (aiProvider(wf, "local")["efforts"] as? [String]) == [])

        // Local lane with an API key: a server that needs one is saved as the
        // custom endpoint; the key never reaches the page.
        do {
            let key = w.good["custom"]!
            check("key: https anywhere, plain http only to this computer or a private network",
                  MenuEnvironment.keySafe("https://api.example.com/v1") && MenuEnvironment.keySafe("http://localhost:8000/v1")
                  && MenuEnvironment.keySafe("http://127.0.0.1:8000/v1") && MenuEnvironment.keySafe("http://192.168.1.20:8000/v1")
                  && MenuEnvironment.keySafe("http://10.0.0.5/v1") && MenuEnvironment.keySafe("http://172.20.1.1/v1") && MenuEnvironment.keySafe("http://box.local/v1")
                  && !MenuEnvironment.keySafe("http://api.example.com/v1") && !MenuEnvironment.keySafe("http://172.32.0.1/v1") && !MenuEnvironment.keySafe("http://8.8.8.8/v1"))
            w.localModels = .success(["acme-large", "acme-small"])
            w.localNeedsKey = key
            let asks = w.localModelAsks.count
            r = await act(wf, ["action": "local_models", "base_url": "http://api.example.com/v1", "api_key": key])
            check("key: never sent over plain http to the internet", !ok(r) && msg(r).contains("https://") && w.localModelAsks.count == asks)
            r = await act(wf, ["action": "local_models", "base_url": "https://api.example.com/v1"])
            check("key: a server that wants a key says so", !ok(r) && msg(r).contains("needs an API key") && w.localModelKeys.last! == nil)
            r = await act(wf, ["action": "local_models", "base_url": "https://api.example.com/v1", "api_key": "wrong-key"])
            check("key: a refused key is explained", !ok(r) && msg(r).contains("refused this API key"))
            r = await act(wf, ["action": "local_models", "base_url": "https://api.example.com/v1/", "api_key": key])
            let listing = ai(wf)["local"] as? [String: Any]
            check("key: models are listed with the key", ok(r) && w.localModelKeys.last! == key && (listing?["models"] as? [String]) == ["acme-large", "acme-small"])
            let page = String(data: (try? JSONSerialization.data(withJSONObject: ai(wf))) ?? Data(), encoding: .utf8) ?? ""
            check("key: the listing never shows the key", !page.isEmpty && !page.contains(key))
            let probes = w.probes.count
            r = await act(wf, ["action": "provider_model", "profile": "local", "model": "acme-large", "base_url": "https://api.example.com/v1"])
            pr = lastProvider(w)
            check("key: saved as the custom endpoint with its key, address and default thinking level, and switched to",
                  ok(r) && pr?["profile"] as? String == "custom" && pr?["api_key"] as? String == key && pr?["base_url"] as? String == "https://api.example.com/v1"
                  && pr?["effort"] as? String == "high" && pr?["activate"] as? Bool == true && w.probes.count == probes + 1 && w.probes.last == "custom")
            let lp = aiProvider(wf, "local")
            check("key: the Local lane shows the keyed server in use, masked key only",
                  ai(wf)["active"] as? String == "local" && lp["keyed"] as? Bool == true && lp["model"] as? String == "acme-large"
                  && lp["endpoint"] as? String == "https://api.example.com/v1" && (lp["key"] as? String).map { !$0.contains(key) && !$0.isEmpty } == true)
            let dash = String(data: (try? JSONSerialization.data(withJSONObject: ai(wf))) ?? Data(), encoding: .utf8) ?? ""
            check("key: the dashboard never shows the key", !dash.contains(key))
            check("key: the dashboard names the lane", step(wf, "ai")["title"] as? String == "Local or other server")
            r = await act(wf, ["action": "local_models", "base_url": "https://api.example.com/v1"])
            check("key: re-listing the saved server reuses its saved key", ok(r) && w.localModelKeys.last! == key)
            r = await act(wf, ["action": "provider_model", "profile": "local", "model": "acme-small", "base_url": "https://api.example.com/v1"])
            pr = lastProvider(w)
            check("key: changing its model keeps it the custom endpoint", ok(r) && pr?["profile"] as? String == "custom" && pr?["model"] as? String == "acme-small")
            // A keyless server listed after it is the local server again.
            w.localNeedsKey = nil
            w.localModels = .success(["qwen3.8-27b"])
            r = await act(wf, ["action": "local_models", "base_url": "http://localhost:1234/v1"])
            check("key: a keyless listing sends no key", ok(r) && w.localModelKeys.last! == nil)
            r = await act(wf, ["action": "provider_model", "profile": "local", "model": "qwen3.8-27b", "base_url": "http://localhost:1234/v1"])
            pr = lastProvider(w)
            check("key: a keyless server is saved as the local server, without a key",
                  ok(r) && pr?["profile"] as? String == "local" && pr?["api_key"] == nil && ai(wf)["active"] as? String == "local" && aiProvider(wf, "local")["keyed"] as? Bool == false)
        }

        // Superseded: a key still checking when the user picks another lane writes nothing.
        do {
            let w2 = world(); let wf2 = await make(w2)
            await act(wf2, ["action": "lane", "lane": "openrouter"])
            let gate = MenuGate(); w2.holds[w2.good["openrouter"]!] = gate
            let held = await parked(wf2, gate, ["action": "provider_key", "profile": "openrouter", "key": w2.good["openrouter"]!])
            await act(wf2, ["action": "lane", "lane": "opencode"])
            gate.open()
            let late = await held.value ?? [:]
            check("a key still checking when another lane is picked saves nothing",
                  late["superseded"] as? Bool == true && lastProvider(w2) == nil && ai(wf2)["active"] is NSNull)
        }

        // ChatGPT effort + Stop.
        w = world()
        w.snap.chatgpt = .signedIn(active: true, model: "gpt-6-sol", effort: "high", generation: "g0")
        wf = await make(w)
        check("ChatGPT offers Light to Deepest", (aiProvider(wf, "chatgpt")["efforts"] as? [String]) == ["low", "medium", "high", "xhigh"] && ai(wf)["openai_required"] as? Bool == false)
        r = await act(wf, ["action": "effort", "effort": "xhigh"])
        check("the ChatGPT thinking level goes through the subscription", ok(r) && w.snap.chatgpt == .signedIn(active: true, model: "gpt-6-sol", effort: "xhigh", generation: "g1"))
        r = await act(wf, ["action": "finish", "what": "stop"])
        check("Stop is allowed with steps still missing and closes as stop", ok(r) && wf.closing == "stop")
    }

    // MARK: 5c. Live hub: the page served by a running Briglia.

    func liveHub() async {
        let w = world()
        w.snap.userName = "Sofia"
        w.snap.chatgpt = .signedIn(active: true, model: "gpt-6-sol", effort: "high", generation: "g0")
        w.snap.telegramConfigured = true; w.snap.telegramChatId = "5551234567"
        var stops = 0
        var busy = false
        var e = env(w)
        let stopBox = MenuGenerationBox(); stopBox.value = 0
        e.live = MenuLive(mode: "service", stop: { stopBox.value += 1 })
        // The host's idle gate: a busy agent answers agent_busy, nothing written.
        let inner = e.apply
        e.apply = { req, cp in busy ? MenuHost.busyAnswer : await inner(req, cp) }
        let wf = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
        wf.now = { w.clock }
        await wf.start(); await wf.settle()
        let st = wf.status()
        check("the live page knows Briglia runs, and how", st["running"] as? Bool == true && st["run_mode"] as? String == "service")
        busy = true
        let before = w.applied.count
        var r = await act(wf, ["action": "name", "name": "Giulia"])
        check("a save while Briglia is answering is refused as busy, nothing written", !ok(r) && msg(r).contains("busy") && w.applied.count == before && w.snap.userName == "Sofia")
        busy = false
        r = await act(wf, ["action": "name", "name": "Giulia"])
        check("the same save goes through once Briglia is idle", ok(r) && w.snap.userName == "Giulia")
        r = await act(wf, ["action": "lang", "lang": "it"])
        busy = true
        r = await act(wf, ["action": "key", "kind": "serper", "key": w.good["serper"]!])
        check("the busy answer follows the page language", !ok(r) && msg(r).hasPrefix("Briglia sta rispondendo"))
        busy = false
        await act(wf, ["action": "lang", "lang": "en"])
        r = await act(wf, ["action": "telegram_token", "token": w.good["telegram"]!])
        check("the bot Briglia is polling can't be swapped live (points to Stop or /switchbot)", !ok(r) && msg(r).contains("/switchbot") && w.probes.filter { $0 == "telegram" }.isEmpty)
        r = await act(wf, ["action": "keepawake", "how": "mask"])
        check("a password-asking fix is refused live", !ok(r) && msg(r).contains("password"))
        r = await act(wf, ["action": "finish", "what": "start"])
        check("Start is refused: Briglia already runs", !ok(r) && msg(r).contains("already running") && wf.closing == nil)
        r = await act(wf, ["action": "finish", "what": "stop"])
        check("Stop closes the page and asks the host to stop Briglia", ok(r) && wf.closing == "stop" && wf.stopRequested && stopBox.value == 0)
        _ = stops
        check("run mode: a systemd unit is the service, anything else a terminal",
              MenuHost.runMode(environment: ["INVOCATION_ID": "abc"]) == (MenuEnvironment().isLinux ? "service" : "terminal") && MenuHost.runMode(environment: [:]) == "terminal")
    }

    func localServerParsing() {
        func models(_ obj: [String: Any], _ status: Int = 200) -> Result<[String], MenuLocalModelsError> {
            MenuEnvironment.interpretModels(data: try! JSONSerialization.data(withJSONObject: obj), status: status)
        }
        check("an OpenAI-style model list is read, sorted", models(["data": [["id": "b"], ["id": "a"], ["id": "a"]]]) == .success(["a", "b"]))
        check("an Ollama-style list is read", models(["models": [["name": "llama4:8b"]]]) == .success(["llama4:8b"]))
        check("an empty list says no model is loaded", models(["data": []]) == .failure(.noModels))
        check("an HTTP error is reported", models([:], 404) == .failure(.http(404)))
        check("addresses: scheme added, trailing slash dropped", MenuEnvironment.localBase("192.168.1.9:8000/v1/") == "http://192.168.1.9:8000/v1")
        check("addresses with credentials or queries are refused",
              MenuEnvironment.localBase("http://u:p@host/v1") == nil && MenuEnvironment.localBase("http://host/v1?x=1") == nil && MenuEnvironment.localBase("file:///etc") == nil)
    }

    // MARK: 6. Linux computer step

    func linuxComputer() async {
        let w = world()
        w.snap.keepAwakeOK = false
        w.snap.keepAwakeSummary = "may suspend — GNOME auto-suspend is on"
        w.snap.keepAwakeGnomeFixable = true
        let wf = await make(w, linux: true)
        let c = wf.status()["computer"] as? [String: Any]
        check("Linux reports the suspend risk with the GNOME fix", wf.status()["platform"] as? String == "linux" && c?["can_fix_gnome"] as? Bool == true && !done(wf, "computer"))
        let r = await act(wf, ["action": "keepawake", "how": "gnome"])
        check("turning off auto-suspend fixes the row", ok(r) && w.gnomeFixed && done(wf, "computer"))
        let r2 = await act(wf, ["action": "keepawake", "how": "mask"])
        check("never-sleep without sudo/systemctl explains itself", !ok(r2))
    }

    // MARK: 7. Finish guards

    func finishGuards() async {
        let w = world()
        let wf = await make(w)
        var r = await act(wf, ["action": "finish", "what": "start"])
        check("Start is refused while required steps are missing, naming them", !ok(r) && msg(r).contains("Finish these first: Your name, ChatGPT, Telegram") && wf.closing == nil)
        r = await act(wf, ["action": "finish", "what": "maybe"])
        check("an unknown finish choice is refused", !ok(r))
        r = await act(wf, ["action": "nonsense"])
        check("an unknown action is refused", !ok(r))
        r = await act(wf, ["action": "lang", "lang": "it"])
        check("the page can switch to Italian", ok(r) && (r["status"] as? [String: Any])?["lang"] as? String == "it" && step(wf, "serper")["title"] as? String == "Ricerca web")
        r = await act(wf, ["action": "key", "kind": "serper", "key": "srp-wrong-0123456789"])
        check("server messages follow the language", msg(r) == "Serper ha rifiutato questa chiave. Controlla di averla copiata tutta, poi incollala di nuovo.")
        r = await act(wf, ["action": "finish", "what": "start"])
        check("“finish these first” in Italian names the steps in Italian", msg(r).hasPrefix("Prima completa: Il tuo nome, ChatGPT"))
        r = await act(wf, ["action": "lang", "lang": "fr"])
        check("an unsupported language is refused, Italian stays", !ok(r) && wf.lang == "it")
        r = await act(wf, ["action": "finish", "what": "quit"])
        check("Close is always allowed", ok(r) && wf.closing == "quit")
    }

    // MARK: 7b. Stale operations (Codex R1): a check still running when the
    // user replaces the link, closes the page, removes the key or resets
    // Telegram writes nothing; an untouched one still saves.

    /// Starts a page action that will park on `gate`, and returns once it has.
    func parked(_ wf: MenuWorkflow, _ gate: MenuGate, _ body: [String: Any], generation g: Int = 0) async -> Task<[String: Any]?, Never> {
        let task = Task { @MainActor in await wf.handle(body, generation: g) }
        for _ in 0..<400 where !gate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
        return task
    }

    func staleOperations() async {
        // Control: nothing interferes → the held check saves when released.
        do {
            let w = world(); let wf = await make(w)
            let gate = MenuGate(); w.holds[w.good["serper"]!] = gate
            let t = await parked(wf, gate, ["action": "key", "kind": "serper", "key": w.good["serper"]!])
            gate.open()
            let r = await t.value ?? [:]
            check("stale control: an unsuperseded slow check still saves", ok(r) && w.snap.serperMasked != nil && w.voidedWrites == 0)
        }
        // Remove while the OpenAI check runs → the late check doesn't restore it.
        do {
            let w = world(); let wf = await make(w)
            let gate = MenuGate(); w.holds[w.good["openai"]!] = gate
            let t = await parked(wf, gate, ["action": "key", "kind": "openai", "key": w.good["openai"]!])
            let removed = await act(wf, ["action": "key_remove", "kind": "openai"])
            gate.open()
            let r = await t.value ?? [:]
            check("stale: Remove during a pending OpenAI check wins (no key restored)",
                  ok(removed) && r["superseded"] as? Bool == true && w.snap.openAIMasked == nil
                  && !w.applied.contains { ($0["openai"] as? [String: Any])?["api_key"] != nil })
        }
        // A newer key for the same service replaces an older pending one.
        do {
            let w = world(); let wf = await make(w)
            let first = w.good["jina"]! + "-alt-FIRST"
            let gate = MenuGate(); w.holds[first] = gate
            let t = await parked(wf, gate, ["action": "key", "kind": "jina", "key": first])
            let second = await act(wf, ["action": "key", "kind": "jina", "key": w.good["jina"]!])
            gate.open()
            let r = await t.value ?? [:]
            let saved = w.applied.compactMap { ($0["jina"] as? [String: Any])?["api_key"] as? String }
            check("stale: a newer key beats an older check that finishes later", ok(second) && r["superseded"] as? Bool == true && saved == [w.good["jina"]!])
        }
        // Close while a check runs → nothing saved after the page closed.
        do {
            let w = world(); let wf = await make(w)
            let gate = MenuGate(); w.holds[w.good["serper"]!] = gate
            let t = await parked(wf, gate, ["action": "key", "kind": "serper", "key": w.good["serper"]!])
            let closed = await act(wf, ["action": "finish", "what": "quit"], settle: false)
            gate.open()
            let r = await t.value
            check("stale: a check finishing after Close saves nothing", ok(closed) && r == nil && w.snap.serperMasked == nil && w.applied.isEmpty)
        }
        // Telegram reset while the chat check runs → no pairing.
        do {
            let w = world(); let wf = await make(w)
            _ = await act(wf, ["action": "telegram_token", "token": w.good["telegram"]!])
            let gate = MenuGate(); w.holds["chat:5551234567"] = gate
            let t = await parked(wf, gate, ["action": "telegram_confirm", "chat_id": "5551234567"])
            _ = await act(wf, ["action": "telegram_reset"])
            gate.open()
            let r = await t.value ?? [:]
            check("stale: Telegram reset during the chat check pairs nothing", r["superseded"] as? Bool == true && !w.snap.telegramConfigured && !w.applied.contains { $0["telegram"] != nil })
        }
        // Link rotation: the old generation is revoked, revoke() waits for
        // the admitted request, and the late check writes nothing.
        do {
            let w = world(); let wf = await make(w)
            let current = MenuGenerationBox()
            wf.validity.authCheck = { g in if g != current.value { throw QuickSetupWorkflow.Superseded() } }
            let gate = MenuGate(); w.holds[w.good["serper"]!] = gate
            let t = await parked(wf, gate, ["action": "key", "kind": "serper", "key": w.good["serper"]!], generation: 1)
            current.value = 2
            let revoking = Task { @MainActor in await wf.revoke() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            gate.open()
            await revoking.value
            let r = await t.value
            check("stale: a request admitted before a new link saves nothing after it", r == nil && w.snap.serperMasked == nil && w.applied.isEmpty)
            let fresh = await wf.handle(["action": "key", "kind": "serper", "key": w.good["serper"]!], generation: 2)
            check("stale: the new link's requests still save", fresh.map(ok) == true && w.snap.serperMasked != nil)
        }
        // A check stuck on the network is cancelled by a new link, so the new
        // link doesn't wait for it (and it writes nothing).
        do {
            let w = world()
            var e = env(w)
            e.probe = { request in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return ["ok": false, "reason": "cancelled"] }
                return w.probe(request)
            }
            let wf = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
            await wf.start(); await wf.settle()
            let t = Task { @MainActor in await wf.handle(["action": "key", "kind": "serper", "key": w.good["serper"]!]) }
            try? await Task.sleep(nanoseconds: 100_000_000)
            let started = Date()
            await wf.revoke()
            let r = await t.value
            check("stale: a new link cancels a check waiting on the network, at once",
                  Date().timeIntervalSince(started) < 5 && r == nil && w.applied.isEmpty)
        }
        // A ChatGPT sign-in waiting in the browser is cancelled by a new link
        // and never switches the provider afterwards.
        do {
            let w = world(); let wf = await make(w)
            w.loginBlocks = true
            let r = await act(wf, ["action": "chatgpt_browser"], settle: false)
            let started = Date()
            await wf.revoke()
            let st = wf.status()
            check("stale: a new link cancels a pending ChatGPT sign-in promptly",
                  ok(r) && Date().timeIntervalSince(started) < 5 && (st["chatgpt"] as? [String: Any])?["login"] == nil && w.snap.chatgpt == .signedOut)
        }
        // Sign-out while a sign-in is finishing → the sign-in doesn't re-select.
        do {
            let w = world(); let wf = await make(w)
            w.loginBlocks = true
            _ = await act(wf, ["action": "chatgpt_code"], settle: false)
            let out = await act(wf, ["action": "chatgpt_logout"], settle: false)
            let loginGone = (wf.status()["chatgpt"] as? [String: Any])?["login"] == nil
            let started = Date()
            await wf.settle()   // the 60 s fake sign-in must already be cancelled
            check("stale: sign-out cancels a sign-in in progress at once",
                  ok(out) && loginGone && w.snap.chatgpt == .signedOut && Date().timeIntervalSince(started) < 5)
        }
    }

    // Codex's reproduction through the real router + authorizer: a request
    // admitted before Enter's rotation writes nothing after it; rotation
    // waits for it (it is released while the rotation is settling).
    func routerRotation() async {
        let w = world()
        let gate = MenuGate()
        var e = env(w)
        e.probe = { request in await gate.wait(); return w.probe(request) }
        let runner = SetupJobRunner(secrets: [:])
        let wf = MenuWorkflow(env: e, runner: runner)
        await wf.start(); await wf.settle()
        var qe = QuickSetupEnvironment(); qe.storedValue = { _ in nil }
        guard let auth = try? QuickSetupWorkflow(env: qe, runner: runner, resume: .fresh) else { check("rotation: authorizer", false); return }
        let token = await auth.launchToken
        guard let cookie = await auth.exchange(token: token) else { check("rotation: exchange", false); return }
        let router = QuickSetupRouter(workflow: auth, pageDirectory: tempRoot) { 4242 }
        router.menu = wf
        func post(_ body: [String: Any], _ cookie: String) async -> QuickSetupHTTPServer.Response {
            let data = try! JSONSerialization.data(withJSONObject: body)
            return await router.handle(.init(method: "POST", path: "/api/menu", query: nil,
                headers: ["host": "127.0.0.1:4242", "origin": "http://127.0.0.1:4242", "content-type": "application/json", "x-briglia-quick-setup": "1"],
                body: data, cookieBQS: cookie, contentLength: data.count))
        }
        let save = Task { await post(["action": "key", "kind": "serper", "key": w.good["serper"]!], cookie) }
        for _ in 0..<400 where !gate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
        let rotation = Task { await auth.rotate() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        gate.open()
        _ = await rotation.value
        let response = await save.value
        check("rotation: a request admitted before a new link answers 404 and saves nothing",
              response.status == 404 && w.snap.serperMasked == nil && w.applied.isEmpty, "status \(response.status)")
        // The new link works for new requests.
        let token2 = await auth.launchToken
        if let cookie2 = await auth.exchange(token: token2) {
            let fresh = await post(["action": "key", "kind": "serper", "key": w.good["serper"]!], cookie2)
            check("rotation: the new link's cookie saves", fresh.status == 200 && w.snap.serperMasked != nil)
        } else { check("rotation: the new link's cookie saves", false) }
    }

    // MARK: 7c. Linux start (Codex R3): the page says "running" only after
    // the service passed its health check; every failure stays on the page
    // with Retry, and the lease comes back.

    final class ServiceFake: @unchecked Sendable {
        var systemd = true
        var unitFails: String?
        var enableFails: String?
        var evidenceFails: String?
        var log: [String] = []
        var leaseHeld = true
        var reacquireWorks = true
    }

    func linuxReady(_ w: MenuFakeWorld) {
        w.snap.userName = "Sofia"
        w.snap.chatgpt = .signedIn(active: true, model: "gpt-6-sol", effort: "high", generation: "g1")
        w.snap.telegramConfigured = true
        w.snap.serperMasked = "srp-…cdef"
        w.snap.jinaMasked = "jina…cdef"
        try? FileManager.default.createDirectory(at: w.toolMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: w.toolMarker.path, contents: Data())
    }

    func linuxStartupWorkflow(_ w: MenuFakeWorld, _ sf: ServiceFake) async -> MenuWorkflow {
        var e = env(w, linux: true)
        e.systemdSessionAvailable = { sf.systemd }
        e.quick.installUnit = {
            sf.log.append("unit")
            if let f = sf.unitFails { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: f]) }
        }
        e.quick.releaseLease = { sf.log.append("release"); sf.leaseHeld = false }
        e.quick.reacquireLease = { sf.log.append("reacquire"); if sf.reacquireWorks { sf.leaseHeld = true }; return sf.reacquireWorks }
        e.quick.enableService = { _ in sf.log.append("enable"); return sf.enableFails }
        e.quick.serviceEvidence = { sf.log.append("evidence"); return (sf.evidenceFails == nil, true, sf.evidenceFails ?? "active, stable") }
        e.quick.stopService = { sf.log.append("stop"); return true }
        let wf = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
        wf.now = { w.clock }
        await wf.start()
        await wf.settle()
        return wf
    }

    func startupState(_ wf: MenuWorkflow) -> [String: Any]? { wf.status()["startup"] as? [String: Any] }

    func runStart(_ wf: MenuWorkflow) async -> [String: Any] {
        let r = await act(wf, ["action": "finish", "what": "start"], settle: false)
        for _ in 0..<400 where wf.startup?.state == "running" { try? await Task.sleep(nanoseconds: 5_000_000) }
        return r
    }

    func linuxStartup() async {
        // Success: install → hand over the lease → start → health check → close.
        do {
            let w = world(); linuxReady(w); let sf = ServiceFake()
            let wf = await linuxStartupWorkflow(w, sf)
            let r = await runStart(wf)
            check("Linux start: a healthy service closes the page as running",
                  ok(r) && wf.closing == "start" && startupState(wf) == nil && sf.log == ["unit", "release", "enable", "evidence"] && wf.leaseHandedOff)
        }
        // No systemd user session: refused before anything is installed.
        do {
            let w = world(); linuxReady(w); let sf = ServiceFake(); sf.systemd = false
            let wf = await linuxStartupWorkflow(w, sf)
            _ = await runStart(wf)
            let u = startupState(wf)
            check("Linux start: no systemd user session is reported on the page, nothing installed",
                  wf.closing == nil && u?["state"] as? String == "failed" && (u?["message"] as? String ?? "").contains("systemd") && sf.log.isEmpty && sf.leaseHeld)
        }
        // The unit can't be written/reloaded: lease never handed over.
        do {
            let w = world(); linuxReady(w); let sf = ServiceFake(); sf.unitFails = "systemctl --user daemon-reload failed"
            let wf = await linuxStartupWorkflow(w, sf)
            _ = await runStart(wf)
            let u = startupState(wf)
            check("Linux start: an install/daemon-reload failure stays on the page, lease kept",
                  wf.closing == nil && u?["state"] as? String == "failed" && (u?["message"] as? String ?? "").contains("daemon-reload") && sf.log == ["unit"] && sf.leaseHeld && !wf.leaseHandedOff)
        }
        // enable --now fails: service stopped, lease taken back.
        do {
            let w = world(); linuxReady(w); let sf = ServiceFake(); sf.enableFails = "enable --now failed: unit masked"
            let wf = await linuxStartupWorkflow(w, sf)
            _ = await runStart(wf)
            let u = startupState(wf)
            check("Linux start: an enable failure stops the service and takes the lease back",
                  wf.closing == nil && u?["state"] as? String == "failed" && (u?["message"] as? String ?? "").contains("unit masked")
                  && sf.log == ["unit", "release", "enable", "stop", "reacquire"] && sf.leaseHeld && !wf.leaseHandedOff)
        }
        // Started but unhealthy (crash loop / socket silent): same recovery;
        // Retry then succeeds once the cause is gone.
        do {
            let w = world(); linuxReady(w); let sf = ServiceFake(); sf.evidenceFails = "the service restarted within the stability window"
            let wf = await linuxStartupWorkflow(w, sf)
            _ = await runStart(wf)
            let u = startupState(wf)
            check("Linux start: an unhealthy service is never reported as running",
                  wf.closing == nil && u?["state"] as? String == "failed" && (u?["message"] as? String ?? "").contains("stability window") && sf.log.suffix(3) == ["evidence", "stop", "reacquire"] && sf.leaseHeld)
            let blocked = await act(wf, ["action": "name", "name": "Other"])
            check("Linux start: settings still work after a failed start", ok(blocked))
            sf.evidenceFails = nil
            sf.log = []
            _ = await runStart(wf)
            check("Linux start: Retry after the fix starts and closes", wf.closing == "start" && startupState(wf) == nil && sf.log == ["unit", "release", "enable", "evidence"])
        }
        // Lease can't be taken back: the page says to reopen, the command
        // knows not to touch a lease it no longer holds.
        do {
            let w = world(); linuxReady(w); let sf = ServiceFake(); sf.enableFails = "boom"; sf.reacquireWorks = false
            let wf = await linuxStartupWorkflow(w, sf)
            _ = await runStart(wf)
            let u = startupState(wf)
            check("Linux start: a lost lease is reported and remembered", (u?["message"] as? String ?? "").contains("briglia menu again") && wf.leaseHandedOff)
            let closed = await act(wf, ["action": "finish", "what": "quit"])
            check("Linux start: Close without starting still closes", ok(closed) && wf.closing == "quit" && startupState(wf) == nil)
        }
        // While starting, other actions wait.
        do {
            let w = world(); linuxReady(w); let sf = ServiceFake()
            let gate = MenuGate()
            var e = await linuxStartupWorkflow(w, sf).env
            e.quick.serviceEvidence = { await gate.wait(); return (true, true, "ok") }
            let wf = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
            await wf.start(); await wf.settle()
            _ = await act(wf, ["action": "finish", "what": "start"], settle: false)
            for _ in 0..<400 where !gate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
            let during = await act(wf, ["action": "key", "kind": "serper", "key": w.good["serper"]!], settle: false)
            let running = startupState(wf)?["state"] as? String == "running" && wf.closing == nil
            gate.open()
            for _ in 0..<400 where wf.startup != nil { try? await Task.sleep(nanoseconds: 5_000_000) }
            check("Linux start: the page shows 'starting' until the check passes, and changes wait", running && !ok(during) && wf.closing == "start")
        }
    }

    // MARK: 8. Router in front of the menu

    func router() async {
        let w = world()
        let wf = await make(w)
        var qenv = QuickSetupEnvironment()
        qenv.storedValue = { _ in nil }
        guard let auth = try? QuickSetupWorkflow(env: qenv, runner: SetupJobRunner(secrets: [:]), resume: .fresh) else {
            check("quick-setup authorization builds", false); return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("menu-page-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ["menu.html", "menu.js", "menu.css"] { try? Data("x".utf8).write(to: dir.appendingPathComponent(f)) }
        let router = QuickSetupRouter(workflow: auth, pageDirectory: dir) { 4242 }
        router.menu = wf
        let host = "127.0.0.1:4242"
        func req(_ method: String, _ path: String, query: String? = nil, cookie: String? = nil, headers extra: [String: String] = [:], body: [String: Any]? = nil) async -> QuickSetupHTTPServer.Response {
            var headers = ["host": host]
            for (k, v) in extra { headers[k] = v }
            let data = body.map { (try? JSONSerialization.data(withJSONObject: $0)) ?? Data() } ?? Data()
            return await router.handle(.init(method: method, path: path, query: query, headers: headers, body: data, cookieBQS: cookie, contentLength: data.count))
        }
        var resp = await req("GET", "/")
        check("the menu page needs the link first (no cookie → 404)", resp.status == 404)
        let token = await auth.launchToken
        resp = await req("GET", "/start", query: "t=\(token)")
        let setCookie = resp.headers.first { $0.0 == "Set-Cookie" }?.1 ?? ""
        let cookie = setCookie.split(separator: ";").first.map { String($0.dropFirst(4)) } ?? ""
        check("the single-use link sets the session cookie", resp.status == 303 && !cookie.isEmpty)
        resp = await req("GET", "/start", query: "t=\(token)")
        check("the link works only once", resp.status == 404)
        resp = await req("GET", "/", cookie: cookie)
        check("with the cookie the menu page is served (not the quick-setup page)", resp.status == 200 && String(decoding: resp.body, as: UTF8.self) == "x")
        resp = await req("GET", "/api/menu/status", cookie: cookie)
        let status = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
        check("the page state is served", resp.status == 200 && (status?["steps"] as? [Any])?.count == 9)
        resp = await req("POST", "/api/menu", cookie: cookie, body: ["action": "name", "name": "Evil"])
        check("a POST without origin/header is refused", resp.status == 403 && w.snap.userName.isEmpty)
        resp = await req("POST", "/api/menu", cookie: cookie, headers: ["origin": "http://evil.example", "content-type": "application/json", "x-briglia-quick-setup": "1"], body: ["action": "name", "name": "Evil"])
        check("a cross-origin POST is refused", resp.status == 403 && w.snap.userName.isEmpty)
        resp = await req("POST", "/api/menu", cookie: cookie, headers: ["origin": "http://\(host)", "content-type": "application/json", "x-briglia-quick-setup": "1"], body: ["action": "name", "name": "Sofia"])
        check("a same-origin POST with the header works", resp.status == 200 && w.snap.userName == "Sofia")
        resp = await req("GET", "/index.html", cookie: cookie)
        check("quick-setup routes are not reachable from the menu session", resp.status == 404)
        _ = await auth.rotate()
        resp = await req("GET", "/api/menu/status", cookie: cookie)
        check("after Enter (new link) the old cookie stops working", resp.status == 404)
        try? FileManager.default.removeItem(at: dir)
    }
}
