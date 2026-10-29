import Foundation

/// The side effects of the menu's Assistants page (MULTI_ASSISTANT_PLAN
/// §10.2, §28.3, §28.6), behind closures so the selftest drives the real
/// page flows with fakes. Live implementations use `AssistantControl`
/// (provisional create, lease-validated stop, supervisor/unit start) and, for
/// another assistant's settings, that profile's own `setup-api` child.
struct MenuAssistantsEnvironment {
    /// The page shows the Assistants section: default's menu, coordination
    /// active, not a settings page opened for another assistant.
    var enabled: () -> Bool = { AssistantProfile.isDefault && CoordinationMode.active && !MenuChild.active }
    /// Registry + lease probe (cheap); bot/model come from `details`.
    var cards: (_ details: (String) -> (botUsername: String?, model: String?)) -> [AssistantControl.Card] = { details in
        AssistantControl.cards(details: details)
    }
    /// `briglia --profile <n> setup-api status` for one extra (slow: run off
    /// the main actor, cached by the page).
    var readDetails: @Sendable (String) -> (botUsername: String?, model: String?) = { AssistantControl.readDetails(profile: $0) }
    var create: (AssistantControl.CreateRequest, _ validate: @escaping (String) async throws -> String?) async throws -> Void = { r, validate in
        try await AssistantControl.create(r, autostart: false, validate: validate)
    }
    var start: @Sendable (String) throws -> String = { try AssistantControl.start($0) }
    var stop: @Sendable (String) throws -> String = { try AssistantControl.stop($0) }
    /// Rename THIS (default) assistant; the live hub runs it in the barrier.
    var renameSelf: (String) throws -> String = { try AssistantName.set($0) }
    /// Rename another assistant through its own setup-api child (refused
    /// while it runs; holds its shared memory-replacement lock).
    var renameOther: @Sendable (_ profile: String, _ name: String) -> [String: Any] = { profile, name in
        MenuAssistantsEnvironment.setupAPIChild(profile: profile, verb: "apply", request: ["assistant": ["name": name]])
    }
    var openSettings: @Sendable (String) throws -> Void = { try AssistantControl.openSettings($0) }
    /// getMe for a pasted token (validation inside the bot's reservation).
    var botInfo: (String) async throws -> ManagedBotAPI.BotInfo = { try await ManagedBotAPI.getMe(token: $0) }
    /// The owner's private chat (default's pairing): a new bot is paired with it.
    var ownerChatId: () -> String? = {
        let v = (KeychainHelper.load(key: KeychainHelper.telegramChatIdKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
    var defaultName: () -> String = { AssistantName.current() }
    var defaultBotUsername: () -> String? = { KeychainHelper.load(key: KeychainHelper.telegramBotUsernameKey) }
    /// The live hub: a /deleteuserdata wipe or Mind import holds the restore
    /// gate (every Assistants action is refused meanwhile).
    var restoreGateUp: () -> Bool = { false }
    /// The live hub (Codex stage-4 S4-R1-6): an Assistants operation is
    /// admitted by the running assistant for its whole lifetime (refused
    /// while a wipe/import, a settings change or an update pause is on; those
    /// wait for it). Offline (no running Briglia) there is nothing to admit.
    var admit: () async -> Bool = { true }
    var release: () async -> Void = {}
    var existingProfiles: () -> Set<String> = {
        var names = Set(((try? AssistantRegistry.read(.live)) ?? nil)?.records.map(\.name) ?? [])
        names.formUnion(AssistantProfile.listExtras())
        return names
    }

    static func setupAPIChild(profile: String, verb: String, request: [String: Any]) -> [String: Any] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: AssistantControl.executable)
        p.arguments = ["--profile", profile, "setup-api", verb]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: AssistantProfile.environmentKey)
        env[AssistantProfile.experimentalKey] = "1"
        p.environment = env
        let input = Pipe(), out = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return SetupAPICore.errorResponse(code: "spawn", message: "\(error)") }
        input.fileHandleForWriting.write((try? JSONSerialization.data(withJSONObject: request)) ?? Data())
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            ?? SetupAPICore.errorResponse(code: "child", message: "no answer from that assistant's settings")
    }
}

extension MenuWorkflow {
    static let assistantTemplates: [(id: String, en: String, it: String)] = [
        ("health", "Health", "Salute"), ("work", "Work", "Lavoro"),
        ("personal", "Personal", "Personale"), ("coder", "Coder", "Programmatore"),
    ]

    var assistantsEnabled: Bool { env.assistants.enabled() }

    /// The `assistants` block of the page status (nil when hidden).
    func assistantsStatus() -> [String: Any]? {
        guard assistantsEnabled else { return nil }
        refreshAssistantDetails(force: false)
        let cards = env.assistants.cards { [weak self] profile in
            if profile == AssistantProfile.defaultName {
                return (self?.env.assistants.defaultBotUsername(), self?.defaultModelLabel())
            }
            let d = self?.assistantDetails[profile]
            return (d?.botUsername, d?.model)
        }
        var out: [String: Any] = [
            "cards": cards.map { c -> [String: Any] in
                var d: [String: Any] = ["profile": c.profile, "name": c.name, "state": c.state, "running": c.running,
                                        "autostart": c.autostart, "has_bot": c.hasBot, "is_default": c.isDefault]
                if let b = c.botUsername, !b.isEmpty { d["bot"] = "@" + b }
                if let m = c.model, !m.isEmpty { d["model"] = m }
                return d
            },
            "max": AssistantProfile.maxProfiles,
            "templates": Self.assistantTemplates.map { ["id": $0.id, "name": lang == "it" ? $0.it : $0.en] },
            "gate": env.assistants.restoreGateUp(),
            "owner_paired": env.assistants.ownerChatId() != nil,
        ]
        if let busy = assistantsBusy { out["busy"] = busy }
        return out
    }

    private func defaultModelLabel() -> String? {
        let ai = aiStatus()
        return (ai["model_label"] as? String) ?? (ai["model"] as? String)
    }

    /// Re-read every extra's bot/model in the background (at most every
    /// 60 s unless forced, e.g. after an action).
    func refreshAssistantDetails(force: Bool) {
        guard assistantsEnabled, assistantDetailsTask == nil else { return }
        if !force, let at = assistantDetailsAt, now().timeIntervalSince(at) < 60 { return }
        assistantDetailsAt = now()
        let names = env.assistants.cards { _ in (nil, nil) }.filter { !$0.isDefault && $0.state == "active" }.map(\.profile)
        let read = env.assistants.readDetails
        assistantDetailsTask = Task { @MainActor [weak self] in
            let results = await Task.detached { () -> [String: (botUsername: String?, model: String?)] in
                var out: [String: (botUsername: String?, model: String?)] = [:]
                for n in names { out[n] = read(n) }
                return out
            }.value
            guard let self else { return }
            for (k, v) in results { self.assistantDetails[k] = MenuWorkflow.AssistantDetail(botUsername: v.botUsername, model: v.model) }
            self.assistantDetailsTask = nil
        }
    }

    var assistantGateMessage: String {
        L("Briglia is replacing its memory, applying settings or updating right now. Try again in a moment.",
          "Briglia sta sostituendo la sua memoria, applicando impostazioni o aggiornandosi. Riprova tra un momento.")
    }

    /// The Assistants actions. Nil = not an Assistants action.
    func performAssistantAction(_ action: String, _ body: [String: Any], checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?)? {
        guard action.hasPrefix("assistant_") else { return nil }
        guard assistantsEnabled else { return (false, L("Several assistants aren't available here.", "Più assistenti non sono disponibili qui.")) }
        guard !env.assistants.restoreGateUp() else { return (false, assistantGateMessage) }
        // Default's own rename runs inside the settings barrier instead.
        let ownRename = action == "assistant_rename" && ((body["profile"] as? String) ?? "") == AssistantProfile.defaultName
        if !ownRename {
            guard await env.assistants.admit() else { return (false, assistantGateMessage) }
        }
        do {
            let result = try await assistantActionBody(action, body, checkpoint: checkpoint)
            if !ownRename { await env.assistants.release() }
            return result
        } catch {
            if !ownRename { await env.assistants.release() }
            throw error
        }
    }

    private func assistantActionBody(_ action: String, _ body: [String: Any], checkpoint: @escaping @Sendable () throws -> Void) async throws -> (Bool, String?) {
        func s(_ k: String) -> String { ((body[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let profile = s("profile")
        switch action {
        case "assistant_add":
            guard assistantsBusy == nil else { return (false, L("Another assistant is being set up \u{2014} one moment.", "Un altro assistente è in preparazione: un momento.")) }
            let name = s("name")
            guard case .valid(let display) = AssistantName.validate(name) else {
                return (false, L("Give the assistant a name (up to 40 characters).", "Dai un nome all\u{2019}assistente (fino a 40 caratteri)."))
            }
            let taken = env.assistants.existingProfiles()
            var id = s("profile").lowercased()
            if id.isEmpty { id = ManagedBots.profileId(fromName: display, taken: taken) }
            guard AssistantProfile.isUsableExtraName(id) else {
                return (false, L("The short id may use lower-case letters, digits and -, up to 24 (not default/all/shared/profiles).",
                                 "L\u{2019}id breve può usare lettere minuscole, cifre e -, fino a 24 (non default/all/shared/profiles)."))
            }
            guard !taken.contains(id) else { return (false, L("The short id ‘\(id)’ is already used; choose another.", "L\u{2019}id breve ‘\(id)’ è già usato; scegline un altro.")) }
            let token = s("token")
            guard token.isEmpty || AssistantRegistry.digest(.bot, token) != nil else {
                return (false, L("That doesn't look like a bot token (123456789:AA…, from @BotFather).", "Non sembra un token di bot (123456789:AA…, da @BotFather)."))
            }
            let template = s("template")
            let request = AssistantControl.CreateRequest(
                profile: id, displayName: display, botToken: token.isEmpty ? nil : token,
                copyKeys: body["copy_keys"] as? Bool ?? true, chatId: token.isEmpty ? nil : env.assistants.ownerChatId(),
                template: Self.assistantTemplates.contains { $0.id == template } ? template : nil)
            let info = env.assistants.botInfo
            try checkpoint()
            assistantsBusy = "adding"
            defer { assistantsBusy = nil }
            do {
                try await env.assistants.create(request) { token in
                    try checkpoint()
                    let me = try await info(token)
                    try checkpoint()
                    return me.username
                }
            } catch let voided as MenuValidity.Voided {
                throw voided
            } catch {
                return (false, ManagedBotAPI.scrub("\(error)", token: token))
            }
            refreshAssistantDetails(force: true)
            let pairing = token.isEmpty
                ? L(" Give it a Telegram bot from its Settings.", " Dagli un bot Telegram dalle sue Impostazioni.")
                : env.assistants.ownerChatId() == nil
                    ? L(" Connect its Telegram chat from its Settings.", " Collega la sua chat Telegram dalle sue Impostazioni.")
                    : L(" Open its bot in Telegram and press Start once.", " Apri il suo bot in Telegram e premi Avvia una volta.")
            return (true, L("Added ‘\(display)’. Press Start on its card to run it.", "Aggiunto ‘\(display)’. Premi Avvia sulla sua scheda per farlo funzionare.") + pairing)

        case "assistant_start", "assistant_stop":
            guard AssistantProfile.isUsableExtraName(profile) else {
                return (false, L("The first assistant is started and stopped with the button at the top right.", "Il primo assistente si avvia e si ferma con il pulsante in alto a destra."))
            }
            try checkpoint()
            let op = action == "assistant_start" ? env.assistants.start : env.assistants.stop
            do {
                let said = try await Task.detached { try op(profile) }.value
                refreshAssistantDetails(force: true)
                return (true, said)
            } catch {
                return (false, "\(error)")
            }

        case "assistant_rename":
            let name = s("name")
            guard case .valid = AssistantName.validate(name) else { return (false, AssistantName.invalidMessage(AssistantName.validate(name))) }
            try checkpoint()
            if profile == AssistantProfile.defaultName {
                var said = ""
                var failure: String?
                let rename = env.assistants.renameSelf
                let ran = try await env.barrier(5) {
                    try checkpoint()
                    do { said = try rename(name) } catch { failure = "\(error)" }
                }
                guard ran else { return (false, MenuHost.busyText(lang)) }
                if let failure { return (false, failure) }
                return (true, L("Renamed to ‘\(said)’.", "Rinominato in ‘\(said)’."))
            }
            guard AssistantProfile.isUsableExtraName(profile) else { return (false, nil) }
            let other = env.assistants.renameOther
            let result = await Task.detached { other(profile, name) }.value
            try checkpoint()
            guard result["ok"] as? Bool == true else { return (false, applyError(result)) }
            refreshAssistantDetails(force: true)
            return (true, L("Renamed to ‘\(name)’.", "Rinominato in ‘\(name)’."))

        case "assistant_settings":
            guard AssistantProfile.isUsableExtraName(profile) else { return (false, nil) }
            try checkpoint()
            let open = env.assistants.openSettings
            do {
                try await Task.detached { try open(profile) }.value
                return (true, L("Its settings open in a new browser tab.", "Le sue impostazioni si aprono in una nuova scheda del browser."))
            } catch { return (false, "\(error)") }

        default:
            return (false, L("Unknown action.", "Azione sconosciuta."))
        }
    }
}

extension MenuHost {
    static func busyText(_ lang: String) -> String {
        lang == "it" ? "Briglia sta rispondendo a un messaggio. Riprova quando ha finito."
                     : "Briglia is busy with a message right now. Try again when it has answered."
    }
}
