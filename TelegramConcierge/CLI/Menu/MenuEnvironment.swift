import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - What the menu shows

/// A read of everything the overview displays. Cheap reads only; the
/// toolchain doctor (seconds) is loaded separately.
struct MenuSnapshot: Equatable {
    enum ChatGPT: Equatable {
        case signedOut
        case loginRequired
        case signedIn(active: Bool, model: String, effort: String, generation: String)
    }

    var userName = ""
    var chatgpt: ChatGPT = .signedOut
    /// Display name of the active main provider when it is NOT ChatGPT.
    var otherProvider: String?
    var telegramConfigured = false
    var telegramChatId = ""
    var serperMasked: String?
    var jinaMasked: String?
    var openAIMasked: String?
    var emailProvider = "none"
    var agentMailMasked: String?
    var agentMailInbox = ""
    var agentMailCLIInstalled = false
    // This computer
    var fdaGranted = true           // macOS only
    var terminalApp = "your terminal"
    var keepAwakeOK = true
    var keepAwakeSummary = ""
    var keepAwakeGnomeFixable = false
    var keepAwakeMaskable = false
    var ubuntuTouch = false
    var serviceActive = false       // Linux only
    var setupComplete = false

    var chatgptReady: Bool {
        if case .signedIn(let active, _, _, _) = chatgpt { return active }
        return false
    }
}

/// Outcome of looking for the user's first message to a fresh bot.
enum MenuTelegramScan: Equatable {
    case found(chatId: String, name: String)
    case waiting
    case failed(String)
}

// MARK: - Side effects (every one behind a closure, for the selftest)

struct MenuEnvironment {
    var isLinux: Bool = {
        #if os(Linux)
        return true
        #else
        return false
        #endif
    }()
    /// Whether a browser on THIS machine can complete the ChatGPT callback
    /// (a desktop session, not SSH). Decides which sign-in option is first.
    var browserLikely: Bool = MenuEnvironment.defaultBrowserLikely()
    /// First guess for the page language ("it" or "en"); the page's flag
    /// switch changes it.
    var language: String = MenuEnvironment.defaultLanguage()

    var snapshot: () async -> MenuSnapshot = { await MenuEnvironment.liveSnapshot() }
    var toolchainStatus: () async -> ToolchainService.DesktopStatus = {
        await Task.detached(priority: .userInitiated) { ToolchainService.desktopStatus() }.value
    }
    /// setup-api probe (same request/response shape).
    var probe: ([String: Any]) async -> [String: Any] = { await SetupAPICore.probe($0) }
    /// setup-api apply; the menu holds the instance lease for its lifetime.
    /// The checkpoint is the operation's ticket: setup-api calls it right
    /// before its writes, so a revoked or superseded action writes nothing.
    var apply: ([String: Any], @escaping () throws -> Void) async -> [String: Any] = {
        await SetupAPICore.apply($0, ownsLease: true, checkpoint: $1)
    }
    /// Subscription setup actions (status/select/probe/logout), same checkpoint.
    var subscription: ([String: Any], @escaping () throws -> Void) async -> [String: Any] = {
        await SubscriptionSetup().perform($0, ownsLease: true, checkpoint: $1)
    }
    var browserLogin: (_ show: @escaping @Sendable (String) -> Void) async throws -> Void = { show in
        _ = try await SubscriptionLogin().browser { show($0) }
    }
    var deviceLogin: (_ show: @escaping @Sendable (String, String) -> Void) async throws -> Void = { show in
        _ = try await SubscriptionLogin().device { show($0, $1) }
    }
    var telegramScan: (_ token: String, _ since: Date) async -> MenuTelegramScan = { await MenuEnvironment.scanTelegram(token: $0, since: $1) }
    var telegramChatProbe: (_ token: String, _ chatId: String) async -> SetupAPICore.TelegramChatProbe = {
        await SetupAPICore.telegramChatProbe(token: $0, chatId: $1)
    }
    var openURL: (String) -> Void = { QuickSetupSession.openBrowser($0) }
    var markComplete: () throws -> Void = {
        try KeychainHelper.saveBatch([SetupWizard.completeKey: "true", SetupWizard.progressKey: String?.none])
    }
    /// Linux: whether a systemd user session can run the background service
    /// (the quick setup's preflight check).
    var systemdSessionAvailable: () -> Bool = {
        #if os(Linux)
        return AgentServiceSupport.systemdUserSessionAvailable()
        #else
        return true
        #endif
    }
    /// The quick setup's system-step seams (Full Disk Access pane, keep-awake
    /// fixes, toolchain installers, AgentMail CLI) — reused as-is so both
    /// setups install exactly the same things.
    var quick = QuickSetupEnvironment()

    // MARK: Live implementations

    static func defaultLanguage() -> String {
        let env = ProcessInfo.processInfo.environment
        let candidates = Locale.preferredLanguages + [env["LC_ALL"] ?? "", env["LANG"] ?? ""]
        return candidates.contains { $0.lowercased().hasPrefix("it") } ? "it" : "en"
    }

    static func defaultBrowserLikely() -> Bool {
        #if os(macOS)
        return ProcessInfo.processInfo.environment["SSH_CONNECTION"] == nil
        #else
        let env = ProcessInfo.processInfo.environment
        if env["SSH_CONNECTION"] != nil { return false }
        return (env["DISPLAY"].map { !$0.isEmpty } ?? false) || (env["WAYLAND_DISPLAY"].map { !$0.isEmpty } ?? false)
        #endif
    }

    static func liveSnapshot() async -> MenuSnapshot {
        ProviderProfiles.ensureMigrated()
        var s = MenuSnapshot()
        s.userName = KeychainHelper.load(key: KeychainHelper.userNameKey) ?? ""
        let active = ProviderProfiles.activeProfile()
        let status = await SubscriptionSetup().perform(["action": "status"])
        switch status["state"] as? String {
        case "signed_in":
            s.chatgpt = .signedIn(active: active == .chatgpt,
                                  model: status["model"] as? String ?? ResponsesAdapter.subscriptionDefaultModel,
                                  effort: status["effort"] as? String ?? "high",
                                  generation: status["generation"] as? String ?? "")
        case "login_required": s.chatgpt = .loginRequired
        default: s.chatgpt = .signedOut
        }
        if let active, active != .chatgpt, ProviderProfiles.isConfigured(active) {
            s.otherProvider = active.displayName
        }
        s.telegramConfigured = TelegramConfig.isConfigured
        s.telegramChatId = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey) ?? ""
        func masked(_ key: String) -> String? {
            guard let v = KeychainHelper.load(key: key), !v.isEmpty else { return nil }
            return WizardIO.masked(v)
        }
        s.serperMasked = masked(KeychainHelper.serperApiKeyKey)
        s.jinaMasked = masked(KeychainHelper.jinaApiKeyKey)
        s.openAIMasked = masked(KeychainHelper.openAITranscriptionApiKeyKey)
        s.emailProvider = EmailCalendarProvider.current.rawValue
        s.agentMailMasked = masked(KeychainHelper.agentMailApiKeyKey)
        s.agentMailInbox = EmailCalendarProvider.agentMailInboxAddress
        s.agentMailCLIInstalled = AgentMailService.agentMailBrokerInstalled()
        s.setupComplete = SetupWizard.setupComplete()
        #if os(macOS)
        s.fdaGranted = PermissionsService.fullDiskAccessGranted()
        s.terminalApp = QuickSetupEvidence.terminalAppName()
        s.keepAwakeOK = true
        s.keepAwakeSummary = "Briglia keeps this Mac awake while it runs (a closed lid or a manual sleep still stops it)"
        #else
        s.ubuntuTouch = AgentServiceSupport.isUbuntuTouch()
        if s.ubuntuTouch {
            s.keepAwakeOK = true
            s.keepAwakeSummary = "handled when Briglia starts as a service (phone keep-awake)"
        } else {
            let verdict = PermissionsService.autoSuspendVerdict()
            s.keepAwakeOK = verdict.isOK
            s.keepAwakeSummary = verdict.summary
            if case .maySuspend(let reason) = verdict {
                s.keepAwakeGnomeFixable = reason.hasPrefix("GNOME auto-suspend is on")
                s.keepAwakeMaskable = PlatformBinary.find("sudo") != nil && PlatformBinary.find("systemctl") != nil
            }
        }
        s.serviceActive = AgentServiceSupport.run("systemctl", ["--user", "is-active", AgentServiceSupport.userUnitName])
            .output.trimmingCharacters(in: .whitespacesAndNewlines) == "active"
        #endif
        return s
    }

    /// Looks for the user's message to the bot, without consuming updates
    /// (no offset): the daemon still receives it later and answers — the
    /// user's first "hello" gets a reply instead of vanishing.
    static func scanTelegram(token: String, since: Date) async -> MenuTelegramScan {
        guard let url = URL(string: DevProbeOverride.url("https://api.telegram.org/bot\(token)/getUpdates?timeout=0&limit=100",
                                                         dev: "/telegram/bot\(token)/getUpdates")) else {
            return .failed("That token doesn't look right.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return interpretUpdates(data: data, status: status, since: since)
        } catch {
            return .failed("Can't reach Telegram right now (\(error.localizedDescription)). Check the internet connection.")
        }
    }

    /// Pure: the getUpdates reply → a verdict. Only a PRIVATE chat whose
    /// sender is the chat itself counts (the pairing rule), newest first,
    /// sent after the waiting screen opened (minus a little clock slack).
    static func interpretUpdates(data: Data, status: Int, since: Date) -> MenuTelegramScan {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, json?["ok"] as? Bool == true else {
            let description = (json?["description"] as? String ?? "").lowercased()
            if description.contains("webhook") {
                return .failed("This bot is connected to another service (a webhook), so Briglia can't read it. Create a new bot with @BotFather and use that one.")
            }
            if description.contains("terminated by other getupdates") || status == 409 {
                return .failed("Another program is using this bot right now (maybe Briglia on another computer). Stop it, or create a new bot for this one.")
            }
            if status == 401 || status == 404 {
                return .failed("Telegram doesn't accept this token any more. Check it with @BotFather.")
            }
            return .failed("Telegram answered with an error (HTTP \(status)). Try again in a moment.")
        }
        let updates = json?["result"] as? [[String: Any]] ?? []
        let cutoff = since.timeIntervalSince1970 - 30
        var best: (id: String, name: String, date: Double)?
        for update in updates {
            guard let message = update["message"] as? [String: Any],
                  let chat = message["chat"] as? [String: Any],
                  chat["type"] as? String == "private",
                  let chatNumber = (chat["id"] as? NSNumber)?.int64Value, chatNumber > 0,
                  let from = message["from"] as? [String: Any],
                  (from["id"] as? NSNumber)?.int64Value == chatNumber,
                  from["is_bot"] as? Bool != true,
                  let date = (message["date"] as? NSNumber)?.doubleValue, date >= cutoff else { continue }
            let first = from["first_name"] as? String ?? ""
            let last = from["last_name"] as? String ?? ""
            var name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            if let username = from["username"] as? String, !username.isEmpty {
                name += name.isEmpty ? "@\(username)" : " (@\(username))"
            }
            if best == nil || date >= best!.date {
                best = (String(chatNumber), name.isEmpty ? "you" : name, date)
            }
        }
        if let best { return .found(chatId: best.id, name: best.name) }
        return .waiting
    }
}
