import Foundation

/// Stage 4 chat surfaces (MULTI_ASSISTANT_PLAN §28.2, §28.4, §28.6): the
/// assistant's own name (`/assistantname`), creating an assistant from the
/// phone with a Telegram managed bot (`/newassistant`), rotating a managed
/// bot's token (`/switchbot newtoken`), the new assistant's first hello, and
/// the cached bot identity used by `/status` and the menu. Visible only while
/// coordination is active (the dispatcher returns false otherwise).
extension ConversationManager {

    // MARK: - /assistantname (§28.2, §28.6 S4-P6)

    func handleAssistantNameCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let current = AssistantName.current()
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            var lines = ["My name: «\(current)»."]
            if let proposal = pendingAssistantNameProposal {
                lines.append("Pending change to «\(proposal)» — send /assistantname confirm to apply, or /assistantname <other name> to replace the proposal.")
            } else {
                lines.append("To change it: /assistantname <new name>, then /assistantname confirm.")
            }
            try? await sendText(lines.joined(separator: "\n"))
            return
        }
        if trimmed.lowercased() == AssistantName.confirmToken {
            guard let proposal = pendingAssistantNameProposal else {
                try? await sendText("Nothing to confirm — propose a name first with /assistantname <new name>.")
                return
            }
            // Idle guard (as /setname): the name is in the system prompt.
            guard activeRunId == nil, activeProcessingTask == nil else {
                try? await sendText("⏳ A turn is running — send /assistantname confirm again when I'm idle (or /stop first).")
                return
            }
            do {
                let stored = try AssistantName.set(proposal, mode: .assistant)
                pendingAssistantNameProposal = nil
                try? await sendText("✔ My name is now «\(stored)». It's used in my instructions from the next message, and in the menu.")
            } catch {
                try? await sendText("✖ \(error)")
            }
            return
        }
        switch AssistantName.validate(argument) {
        case .valid(let name):
            pendingAssistantNameProposal = name
            try? await sendText("Change my name from «\(current)» to «\(name)»? Send /assistantname confirm to apply — anything else leaves it unchanged.")
        case let invalid:
            try? await sendText("✖ \(AssistantName.invalidMessage(invalid))")
        }
    }

    // MARK: - /newassistant (§28.4, §28.6)

    /// Test seam: delays between token fetch attempts (seconds).
    nonisolated(unsafe) static var managedBotTokenRetryDelays: [Double] = [0, 1, 5, 15, 30, 60]

    /// This assistant's own bot token.
    var ownBotToken: String {
        (KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var managedBotsActiveHere: Bool { AssistantProfile.isDefault && CoordinationMode.active }

    func handleNewAssistantCommand(argument: String) async {
        guard replyAddress != nil else { return }
        guard AssistantProfile.isDefault else {
            try? await sendText("✖ New assistants are created from your first assistant: send /newassistant <Name> in its chat.")
            return
        }
        guard replyAddress?.kind == .telegram, isTelegramConfigured, let owner = pairedChatId else {
            try? await sendText("✖ Send /newassistant from Telegram: the button that creates the bot only exists there. (Or add one in `briglia menu` → Add assistant.)")
            return
        }
        let arg = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = ManagedBots.loadPending()
        switch arg.lowercased() {
        case "":
            if let pending, ManagedBots.isLive(pending, now: Date()) {
                let what: String
                switch pending.phase {
                case .waiting: what = "waiting for you to tap the button"
                case .confirm: what = "waiting for you to confirm \(ManagedBots.handle(pending.botUsername))"
                case .claimed: what = pending.failed == true ? "the bot \(ManagedBots.handle(pending.botUsername)) exists but setting it up failed — /newassistant retry"
                                                          : "setting up \(ManagedBots.handle(pending.botUsername))"
                }
                try? await sendText("A new assistant «\(pending.name)» is pending: \(what). /newassistant cancel drops it.")
                if pending.phase == .confirm { await sendManagedConfirmation(pending) }
            } else {
                try? await sendText("""
                /newassistant <Name> creates another assistant with its own Telegram bot, from here:
                1. Send /newassistant Health (any name).
                2. Tap the button I send and confirm in Telegram — that creates the bot.
                3. I set up “Health”, keep its bot private to you, start it, and it says hi in its own chat.
                Needs “Bot Management” turned on for this bot in @BotFather once.
                """)
            }
            return
        case "cancel", "annulla":
            guard let pending else {
                try? await sendText("Nothing to cancel — no new assistant is pending.")
                return
            }
            if managedBotCreationTask != nil {
                try? await sendText("⏳ The assistant is being set up right now; it can't be cancelled at this step.")
                return
            }
            do { try ManagedBots.updatePending(requestId: pending.requestId) { $0 = nil } } catch {
                try? await sendText("✖ Couldn't drop the request (\(error.localizedDescription)).")
                return
            }
            let leftover = pending.botId != nil ? " The bot \(ManagedBots.handle(pending.botUsername)) still exists in Telegram; delete it in @BotFather if you don't need it." : ""
            await sendManagedBotReply("✔ Cancelled — no new assistant will be created.\(leftover)", owner: owner)
            return
        case "retry", "riprova":
            if let pending, pending.phase == .confirm, ManagedBots.isLive(pending, now: Date()) {
                await sendManagedConfirmation(pending)
                return
            }
            guard let pending, pending.phase == .claimed, pending.botId != nil else {
                try? await sendText("Nothing to retry — send /newassistant <Name> to start.")
                return
            }
            if pending.failed == true {
                _ = try? ManagedBots.updatePending(requestId: pending.requestId) { $0?.failed = nil }
            }
            if !startManagedBotCreationIfPossible() {
                try? await sendText("⏳ I can't start it right now (another setup, an update or a memory operation is running); I'll do it as soon as possible.")
            }
            return
        default:
            break
        }
        if managedBotCreationTask != nil || pending?.phase == .claimed && pending.map({ ManagedBots.isLive($0, now: Date()) }) == true {
            try? await sendText("⏳ Another new assistant is still being set up (/newassistant shows it); finish or cancel it first.")
            return
        }
        // Name, registry and capability checks before any button is shown.
        guard case .valid(let name) = AssistantName.validate(arg), !ManagedBots.reservedNames.contains(name.lowercased()) else {
            let v = AssistantName.validate(arg)
            try? await sendText("✖ \(v == .valid(arg.trimmingCharacters(in: .whitespacesAndNewlines)) ? "That word is one of this command's own options; choose another name." : AssistantName.invalidMessage(v))")
            return
        }
        let doc = (try? AssistantRegistry.read(.live)) ?? nil
        if let doc {
            if AssistantRegistry.displayNameTaken(name, in: doc) {
                try? await sendText("✖ \(AssistantName.takenMessage(name))")
                return
            }
            if doc.records.count >= AssistantProfile.maxProfiles {
                try? await sendText("✖ This computer already has \(AssistantProfile.maxProfiles) assistants, the maximum.")
                return
            }
        }
        if let barrier = UpgradeBarrier.current(), barrier.isActive {
            try? await sendText("✖ Briglia is updating; try again in a minute.")
            return
        }
        let token = ownBotToken
        let me: ManagedBotAPI.BotInfo
        do { me = try await ManagedBotAPI.getMe(token: token) } catch {
            try? await sendText("✖ Couldn't ask Telegram about this bot (\(error)). Try again in a moment.")
            return
        }
        managedBotCapability = me.canManageBots
        guard me.canManageBots else {
            try? await sendText("""
            ✖ This bot can't create other bots yet. Turn it on once:
            1. Open @BotFather → Bot Settings for \(ManagedBots.handle(me.username)) (in the Mini App).
            2. Turn on “Bot Management”.
            3. Send /newassistant \(name) again.
            (Or add an assistant with a token you paste: `briglia menu` → Add assistant.)
            """)
            return
        }
        // Re-checked after the await (a memory operation may have started).
        guard !isRestoringMind else {
            try? await sendText(Self.memoryReplacementRefusal)
            return
        }
        var taken = Set(doc?.records.map(\.name) ?? [])
        taken.formUnion(AssistantProfile.listExtras())
        let request = ManagedBots.Pending(
            requestId: ManagedBots.randomRequestId(), managerBotId: me.id, ownerId: Int64(owner), name: name,
            profileId: ManagedBots.profileId(fromName: name, taken: taken),
            suggestedUsername: ManagedBots.suggestedUsername(name: name, suffix: ManagedBots.randomSuffix()),
            createdAt: Date(), phase: .waiting)
        do { try ManagedBots.savePending(request) } catch {
            try? await sendText("✖ Couldn't save the request (\(error.localizedDescription)).")
            return
        }
        let text = """
        Tap the button below to create the bot for «\(name)», then confirm in Telegram (you can change its username there). I'll do the rest. The request expires in 15 minutes; /newassistant cancel drops it.
        """
        let markup = ManagedBotAPI.requestButtonMarkup(requestId: request.requestId, buttonText: "➕ Create «\(name)»",
                                                       suggestedName: name, suggestedUsername: request.suggestedUsername)
        do {
            try await ManagedBotAPI.sendMessage(token: token, chatId: Int64(owner), text: text, replyMarkup: markup)
        } catch {
            _ = try? ManagedBots.updatePending(requestId: request.requestId) { $0 = nil }
            try? await sendText("✖ Telegram refused the create-bot button (\(error)).")
        }
    }

    // MARK: Events (§28.6 S4-P2/P3, Codex stage-4 S4-R1-1/R1-4)

    /// What to do after a managed-bot write was saved.
    enum ManagedFollowUp {
        case none
        case start(name: String, username: String?)
        case ask(ManagedBots.Pending)
        case tell(String)
    }

    /// The durable part of a `managed_bot_created` event: decide and write,
    /// synchronously (no await). Throws when the write fails; the caller then
    /// keeps the event for the durability stall to retry.
    func applyManagedBotCreated(_ event: ManagedBots.Event) throws -> ManagedFollowUp {
        let pending = ManagedBots.loadPending()
        let managerId = AssistantRegistry.normalize(.bot, ownBotToken).flatMap(Int64.init)
        let decision = ManagedBots.decide(event, pending: pending, known: ManagedBots.loadKnown(),
                                          ownerId: pairedChatId.map(Int64.init), managerBotId: managerId, now: Date())
        switch decision {
        case .ignore(let why):
            print("[ManagedBots] ignored a created bot (id \(event.botId)): \(why)")
            if why.contains("no /newassistant") {
                return .tell("I saw that you created \(ManagedBots.handle(event.botUsername)), but there's no current /newassistant request for it. Send /newassistant <Name> to make an assistant — or delete that bot in @BotFather if you don't need it.")
            }
            if why.contains("already an assistant") || why.contains("another bot") {
                return .tell("\(ManagedBots.handle(event.botUsername)) wasn't used: \(why).")
            }
            return .none
        case .resume:
            return .start(name: pending?.name ?? "", username: event.botUsername)
        case .claim:
            guard let pending else { return .none }
            try ManagedBots.updatePending(requestId: pending.requestId) {
                $0?.phase = .claimed; $0?.botId = event.botId; $0?.botUsername = event.botUsername; $0?.failed = nil
            }
            return .start(name: pending.name, username: event.botUsername)
        case .askConfirmation:
            guard var pending else { return .none }
            try ManagedBots.updatePending(requestId: pending.requestId) {
                $0?.phase = .confirm; $0?.botId = event.botId; $0?.botUsername = event.botUsername
            }
            pending.phase = .confirm; pending.botId = event.botId; pending.botUsername = event.botUsername
            return .ask(pending)
        }
    }

    /// The `managed_bot_created` service message, already past the pairing
    /// gate (the paired owner's private chat). A failed write is a durability
    /// failure AND the event is kept: the stall retries this write before the
    /// update is acknowledged (S4-R1-1).
    func handleManagedBotCreatedMessage(_ created: TelegramManagedBotCreated, sender: TelegramUser?) async {
        let event = ManagedBots.Event(senderId: sender.map { Int64($0.id) }, botId: Int64(created.bot.id),
                                      botUsername: created.bot.username)
        do {
            await performManagedFollowUp(try applyManagedBotCreated(event))
        } catch {
            managedBotRetries.append(.created(event))
            inboundDurabilityFailure = true
        }
    }

    func performManagedFollowUp(_ followUp: ManagedFollowUp) async {
        switch followUp {
        case .none: return
        case .tell(let text): try? await sendText(text)
        case .start(let name, let username):
            if !startManagedBotCreationIfPossible(), !name.isEmpty {
                try? await sendText("Your new bot \(ManagedBots.handle(username)) exists. I'll set up «\(name)» as soon as the memory operation or update that is running now has finished.")
            }
        case .ask(let pending):
            await sendManagedConfirmation(pending)
        }
    }

    /// The Yes/No question for a candidate bot. Re-sent by `/newassistant`
    /// and `/newassistant retry` while the request waits for it (S4-R1-4).
    func sendManagedConfirmation(_ pending: ManagedBots.Pending) async {
        guard let botId = pending.botId, let chat = pairedChatId else { return }
        let keyboard = TelegramInlineKeyboardMarkup(inlineKeyboard: [[
            TelegramInlineKeyboardButton(text: "Yes, use it", callbackData: ManagedBots.confirmData(yes: true, requestId: pending.requestId, botId: botId)),
            TelegramInlineKeyboardButton(text: "No", callbackData: ManagedBots.confirmData(yes: false, requestId: pending.requestId, botId: botId)),
        ]])
        do {
            try await telegramService.sendMessage(chatId: chat, text: "Use \(ManagedBots.handle(pending.botUsername)) for the new assistant «\(pending.name)»?", keyboard: keyboard)
        } catch {
            try? await sendText("I couldn't show the question about \(ManagedBots.handle(pending.botUsername)) (\(error.localizedDescription)). Send /newassistant to see it again.")
        }
    }

    /// The durable part of a confirmation tap. Nil = the button is stale.
    func applyManagedConfirm(yes: Bool, requestId: Int32, botId: Int64) throws -> ManagedBots.Pending? {
        guard let pending = ManagedBots.loadPending(), pending.requestId == requestId, pending.phase == .confirm,
              pending.botId == botId, ManagedBots.isLive(pending, now: Date()) else { return nil }
        try ManagedBots.updatePending(requestId: pending.requestId) {
            if yes { $0?.phase = .claimed; $0?.failed = nil } else { $0?.phase = .waiting; $0?.botId = nil; $0?.botUsername = nil }
        }
        return pending
    }

    /// The confirmation buttons. Bound to (request id, bot id): a stale or
    /// another request's button is refused in place.
    func handleManagedBotConfirmCallback(_ query: TelegramCallbackQuery, menuMessage: TelegramMessage) async {
        guard managedBotsActiveHere, let parsed = ManagedBots.parseConfirm(query.data ?? "") else { return }
        let pending: ManagedBots.Pending?
        do { pending = try applyManagedConfirm(yes: parsed.yes, requestId: parsed.requestId, botId: parsed.botId) } catch {
            managedBotRetries.append(.confirm(yes: parsed.yes, requestId: parsed.requestId, botId: parsed.botId))
            inboundDurabilityFailure = true
            try? await telegramService.answerCallbackQuery(id: query.id, text: "Saving that is delayed (storage problem); it is applied as soon as storage works.", showAlert: false)
            return
        }
        guard let pending else {
            try? await telegramService.answerCallbackQuery(id: query.id, text: "This question is no longer current.", showAlert: false)
            return
        }
        try? await telegramService.answerCallbackQuery(id: query.id)
        try? await telegramService.editMessageText(chatId: menuMessage.chat.id, messageId: menuMessage.messageId,
            text: parsed.yes ? "✔ Using \(ManagedBots.handle(pending.botUsername)) for «\(pending.name)»."
                             : "✖ Not using \(ManagedBots.handle(pending.botUsername)). Tap the create button again, or /newassistant cancel.")
        if parsed.yes { await performManagedFollowUp(.start(name: pending.name, username: pending.botUsername)) }
    }

    /// The durability stall (S4-R1-1): managed-bot writes that failed are
    /// retried with the other durable writes; the stalled update is confirmed
    /// only when they all landed. Follow-ups run after the stall clears.
    func retryManagedBotWrites() -> Bool {
        while let first = managedBotRetries.first {
            let followUp: ManagedFollowUp
            do {
                switch first {
                case .created(let event): followUp = try applyManagedBotCreated(event)
                case .confirm(let yes, let requestId, let botId):
                    let p = try applyManagedConfirm(yes: yes, requestId: requestId, botId: botId)
                    followUp = (yes && p != nil) ? .start(name: p!.name, username: p!.botUsername) : .none
                }
            } catch {
                return false
            }
            managedBotRetries.removeFirst()
            Task { @MainActor [weak self] in await self?.performManagedFollowUp(followUp) }
        }
        return true
    }

    // MARK: Creation (one producer; gated; resumable)

    /// A claimed, not-failed request whose creation can run now. Counted as
    /// busy by the wipe/import, settings and upgrade checks (§28.6 S4-P7).
    var managedBotCreationOwed: Bool {
        guard managedBotsActiveHere, let p = ManagedBots.loadPending() else { return false }
        return p.phase == .claimed && p.failed != true
    }

    /// Start the creation task for the claimed request, unless one runs or a
    /// gate is up (restore gate, upgrade admission pause, settings barrier).
    /// Returns whether the work is running.
    @discardableResult
    func startManagedBotCreationIfPossible() -> Bool {
        guard managedBotsActiveHere else { return false }
        if managedBotCreationTask != nil { return true }
        guard !isRestoringMind, !admissionPaused, !browserSettingsMutation else { return false }
        guard let pending = ManagedBots.loadPending(), pending.phase == .claimed, let botId = pending.botId,
              pending.failed != true else { return false }
        let manager = ownBotToken
        let owner = pending.ownerId
        managedBotCreationBotId = botId
        managedBotCreationTask = Task { @MainActor [weak self] in
            await self?.runManagedBotCreation(requestId: pending.requestId, manager: manager, owner: owner)
            self?.managedBotCreationTask = nil
            self?.managedBotCreationBotId = nil
        }
        return true
    }

    private func runManagedBotCreation(requestId: Int32, manager: String, owner: Int64) async {
        if let hook = Self.managedBotCreationHookForTesting { await hook() }
        guard let pending = ManagedBots.loadPending(), pending.requestId == requestId, let botId = pending.botId else { return }
        let handle = ManagedBots.handle(pending.botUsername)
        func fail(_ text: String) async {
            _ = try? ManagedBots.updatePending(requestId: requestId) { $0?.failed = true }
            await sendManagedBotReply(text, owner: owner)
        }
        // 0. Reconcile with what a previous (interrupted) attempt left.
        let botDigest = AssistantRegistry.digest(.bot, "\(botId):x")
        if let record = (try? AssistantRegistry.read(.live))??.record(pending.profileId) {
            if record.state == "active", record.bot.current == botDigest {
                await completeManagedBotCreation(pending: pending, generation: record.generation, manager: manager, owner: owner)
                return
            }
            if record.state == "adding", let op = record.addingOp,
               ProfileFileLock.probe(AssistantRegistry.Paths.live.txLease(op)) == .dead {
                // A crashed provisional attempt: removed, then made again.
                _ = try? await Task.detached { try ProfileLifecycle.remove(name: pending.profileId, confirmedGeneration: record.generation) }.value
            } else {
                await fail("✖ \(handle) exists, but the assistant id ‘\(pending.profileId)’ is already used on this computer. Remove that assistant or cancel with /newassistant cancel.")
                return
            }
        }
        // 1. The token (Telegram may need a moment after creation).
        var token: String?
        var lastError = ""
        for delay in Self.managedBotTokenRetryDelays {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            do { token = try await ManagedBotAPI.getManagedBotToken(manager: manager, botId: botId); break }
            catch { lastError = "\(error)" }
        }
        guard let token else {
            await fail("✖ \(handle) was created, but Telegram didn't give me its token (\(lastError)). Send /newassistant retry in a minute.")
            return
        }
        // 2. The assistant: provisional until its bot is reserved and its
        //    settings written; default's API keys copied; paired with the
        //    owner's chat; hello at its first start. No token in any message.
        let request = AssistantControl.CreateRequest(profile: pending.profileId, displayName: pending.name,
                                                     botToken: token, botUsername: pending.botUsername,
                                                     copyKeys: true, chatId: String(owner), greet: true)
        do {
            try await AssistantControl.create(request, autostart: false)
        } catch {
            await fail("✖ \(handle) exists, but setting up «\(pending.name)» failed: \(ManagedBotAPI.scrub("\(error)", token: token)). Send /newassistant retry to try again.")
            return
        }
        let generation = (try? AssistantRegistry.read(.live))??.record(pending.profileId)?.generation ?? ""
        await completeManagedBotCreation(pending: pending, generation: generation, manager: manager, owner: owner)
    }

    /// The bot is remembered FIRST (the rotation grant); the claim is retired
    /// only at the very end, after access and Start, so every interruption
    /// before that resumes here (S4-R1-3).
    private func completeManagedBotCreation(pending: ManagedBots.Pending, generation: String, manager: String, owner: Int64) async {
        guard let botId = pending.botId else { return }
        var known = ManagedBots.loadKnown()
        known.bots[String(botId)] = ManagedBots.KnownBot(profile: pending.profileId, generation: generation, managerBotId: pending.managerBotId)
        do { try ManagedBots.saveKnown(known) } catch {
            _ = try? ManagedBots.updatePending(requestId: pending.requestId) { $0?.failed = true }
            await sendManagedBotReply("⚠️ «\(pending.name)» was created, but I couldn't save its record (\(error.localizedDescription)). Fix storage, then send /newassistant retry to finish.", owner: owner)
            return
        }
        // Owner-only access (the owner can always use it); Briglia's own
        // pairing answers only the owner either way.
        var notes: [String] = []
        do { try await ManagedBotAPI.setAccess(manager: manager, botId: botId, restricted: true) } catch {
            notes.append("I couldn't make the bot private in Telegram (\(error)); it still answers only you.")
        }
        let profile = pending.profileId
        let started: String
        do { started = try await Task.detached { try AssistantControl.start(profile) }.value } catch {
            started = "not started (\(error)) — start it from `briglia menu`"
        }
        _ = try? ManagedBots.updatePending(requestId: pending.requestId) { $0 = nil }
        let handle = ManagedBots.handle(pending.botUsername)
        let link = pending.botUsername.map { " Open it: https://t.me/\($0)" } ?? ""
        var text = "✔ «\(pending.name)» is ready — \(handle), \(started). Only you can use it.\(link)"
        if !notes.isEmpty { text += "\n" + notes.joined(separator: "\n") }
        await sendManagedBotReply(text, owner: owner)
    }

    /// A reply that also removes the create-button keyboard (falls back to the
    /// ordinary reply path).
    func sendManagedBotReply(_ text: String, owner: Int) async {
        await sendManagedBotReply(text, owner: Int64(owner))
    }

    func sendManagedBotReply(_ text: String, owner: Int64) async {
        if (try? await ManagedBotAPI.sendMessage(token: ownBotToken, chatId: owner, text: text,
                                                 replyMarkup: ManagedBotAPI.removeKeyboardMarkup)) != nil {
            return
        }
        try? await sendText(text)
    }

    // MARK: - Assistants page operations (Codex stage-4 S4-R1-6)

    /// Admit one Assistants-page operation of the live menu (Add, Start,
    /// Stop, Rename of another assistant, Settings) for its whole lifetime:
    /// refused while a wipe/import, a settings change or an update pause is
    /// on; while it runs, those wait (they count it as busy).
    func admitAssistantsMenuOperation() -> Bool {
        guard !isRestoringMind, !browserSettingsMutation, !admissionPaused else { return false }
        assistantsMenuOperations += 1
        return true
    }

    func endAssistantsMenuOperation() {
        assistantsMenuOperations = max(0, assistantsMenuOperations - 1)
    }

    // MARK: - /switchbot newtoken (§28.6 S4-P4)

    static let managedRotationWords: Set<String> = ["newtoken", "nuovotoken"]

    /// Records the request; the poll loop runs it at its clean boundary.
    func handleManagedBotRotationRequest() async {
        guard CoordinationMode.active, !AssistantProfile.isDefault else {
            try? await sendText("✖ The first assistant's bot is made in @BotFather; give it a new token there (/revoke), then /switchbot <token>.")
            return
        }
        guard AssistantRegistry.normalize(.bot, ownBotToken) != nil else {
            try? await sendText("✖ This assistant has no Telegram bot to give a new token.")
            return
        }
        guard activeRunId == nil, activeProcessingTask == nil, pendingBotSwitch == nil, !botSwitchCutoverInProgress else {
            try? await sendText("⏳ Send /switchbot newtoken again when I'm idle and no other bot switch is pending.")
            return
        }
        pendingManagedRotation = true
        try? await sendText("🔁 Getting a new token for this bot from your first assistant — a moment.")
    }

    /// Clean poll boundary: no getUpdates batch in flight.
    func performPendingManagedRotationIfReady() async {
        guard pendingManagedRotation, !managedRotationInProgress else { return }
        guard activeRunId == nil, activeProcessingTask == nil, !isRestoringMind, !admissionPaused else { return }
        pendingManagedRotation = false
        managedRotationInProgress = true
        defer { managedRotationInProgress = false }
        let outcome = await rotateManagedToken(recovering: false)
        await notifyBotSwitchProgress(outcome)
    }

    /// Poll boundary: while intake is held for a rotation that couldn't be
    /// saved, retry the recovery every 30 s.
    func retryManagedRotationHoldIfDue(now: Date = Date()) async {
        guard managedRotationHold, !managedRotationInProgress, !isRestoringMind, !admissionPaused else { return }
        if let last = managedRotationLastRetry, now.timeIntervalSince(last) < 30 { return }
        managedRotationLastRetry = now
        managedRotationInProgress = true
        defer { managedRotationInProgress = false }
        let outcome = await rotateManagedToken(recovering: true)
        if !managedRotationHold { await notifyBotSwitchProgress(outcome) }
    }

    /// Startup: an intent left by an interrupted rotation is completed before
    /// polling (the stored token may already be revoked).
    func recoverManagedRotationIfNeeded() async {
        guard CoordinationMode.active, !AssistantProfile.isDefault, ManagedBots.loadRotation() != nil else { return }
        managedRotationInProgress = true
        defer { managedRotationInProgress = false }
        let outcome = await rotateManagedToken(recovering: true)
        print("[ManagedBots] rotation recovery: \(outcome)")
    }

    /// The transaction (§28.6 S4-P4, Codex stage-4 S4-R1-2): same-bot
    /// reservation; a durable intent carrying the confirmed cursor BEFORE the
    /// remote call; replace (or recover the live token); the cursor written
    /// under the new token (checked) BEFORE the secret; the secret; the
    /// in-memory token switched with the cursor kept; the intent cleared
    /// last. Recovery (at startup, before Telegram is registered) repeats the
    /// cursor write from the intent, so neither a restart nor a crash between
    /// the writes resumes from 0.
    func rotateManagedToken(recovering: Bool) async -> String {
        let current = ownBotToken
        guard let idText = AssistantRegistry.normalize(.bot, current), let botId = Int64(idText) else {
            return "✖ This assistant has no Telegram bot to give a new token."
        }
        let ticket: IdentityChange.Ticket
        do { ticket = try IdentityChange.begin(kind: .bot, rawValue: current, mode: .assistant) } catch {
            return "✖ \(error)"
        }
        let profile = AssistantProfile.selectedName
        var intent: ManagedBots.RotationIntent
        if recovering, let saved = ManagedBots.loadRotation(), saved.botId == botId {
            intent = saved
        } else if recovering {
            ticket.abort()
            try? ManagedBots.saveRotation(nil)   // not this bot's intent any more
            return "token unchanged"
        } else {
            let cursor = await telegramService.confirmedCursor()
            intent = ManagedBots.RotationIntent(botId: botId, startedAt: Date(), lastUpdateId: cursor.lastUpdateId, lastUpdateAt: cursor.lastUpdateAt)
            do { try ManagedBots.saveRotation(intent) } catch {
                ticket.abort()
                return "✖ Couldn't record the token change (\(error.localizedDescription)); nothing was changed."
            }
        }
        var newToken: String?
        var failure = ""
        if !recovering {
            do { newToken = try await Task.detached { try ManagedBotRotation.run(.replace, botId: botId, profile: profile) }.value }
            catch { failure = "\(error)" }
        }
        if newToken == nil {
            // Lost answer, crash or recovery: ask for the CURRENT token (no
            // second revocation), a few times.
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                if let t = try? await Task.detached(operation: { try ManagedBotRotation.run(.current, botId: botId, profile: profile) }).value {
                    newToken = t
                    break
                }
            }
        }
        guard let newToken else {
            ticket.abort()
            if recovering {
                // The stored token may be revoked: hold intake and retry.
                managedRotationHold = true
                return "✖ Couldn't recover this bot's token from the first assistant (is Telegram reachable?). Telegram is paused for this assistant; I retry every 30 s."
            }
            // Nothing is known to have changed remotely: keep the intent so a
            // restart re-checks (harmless when the token is still valid).
            return "✖ The first assistant couldn't give a new token (\(failure)). If this assistant stops answering, restart it — it re-checks the token at startup."
        }
        if newToken == current {
            ticket.abort()
            try? ManagedBots.saveRotation(nil)
            let wasHeld = managedRotationHold
            managedRotationHold = false
            if wasHeld { await updateTelegramChannelRegistration() }
            return recovering ? "token unchanged" : "✖ Telegram didn't issue a new token (\(failure)); the current one still works."
        }
        // A storage failure from here on (S4-R2-1/R2-2): the new token is NOT
        // used in memory. Telegram intake is held (nothing processed with
        // either token, so the intent's cursor stays the latest progress) and
        // the recovery is retried at the poll boundary; the owner hears it
        // from the new bot directly.
        func hold(_ what: String) async -> String {
            ticket.abort()
            let wasConfigured = isTelegramConfigured
            managedRotationHold = true
            if wasConfigured { await updateTelegramChannelRegistration() }
            if let owner = pairedChatId {
                _ = try? await ManagedBotAPI.sendMessage(token: newToken, chatId: Int64(owner),
                    text: "⚠️ I got a new token for this bot but couldn't save \(what) (storage problem). Telegram is paused for me until it can be saved; I retry every 30 s.")
            }
            return "⚠️ Telegram issued a new token but I couldn't save \(what); Telegram is paused for this assistant and the change is retried every 30 s."
        }
        // Cursor first (same bot, same update ids), checked; then the secret.
        do {
            if let fault = Self.rotationCursorFaultForTesting { try fault() }
            try TelegramBotService.writeOffsetState(forToken: newToken, lastUpdateId: intent.lastUpdateId, lastUpdateAt: intent.lastUpdateAt)
        } catch {
            return await hold("the update position")
        }
        do {
            try ticket.commit {
                if let fault = Self.rotationSecretFaultForTesting { try fault() }
                try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: newToken)
            }
        } catch {
            return await hold("the token")
        }
        ticket.finish()
        managedRotationHold = false
        await telegramService.rebindSameBot(token: newToken)
        await updateTelegramChannelRegistration()
        try? ManagedBots.saveRotation(nil)
        return "✔ New token for this bot: the old one no longer works. Nothing else changed."
    }

    // MARK: - Bot identity cache and the first hello

    /// Several assistants: remember the bot's @handle (menu cards, `/status`)
    /// and, in default, whether it can manage bots; then resume a claimed
    /// creation and send a pending first hello. Never with one assistant and
    /// the switch off (no extra getMe).
    func refreshTelegramIdentityCache() {
        guard CoordinationMode.active, isTelegramConfigured else { return }
        let token = ownBotToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let me = try? await ManagedBotAPI.getMe(token: token), !self.isRestoringMind {
                if AssistantProfile.isDefault { self.managedBotCapability = me.canManageBots }
                if let username = me.username, KeychainHelper.load(key: KeychainHelper.telegramBotUsernameKey) != username {
                    try? KeychainHelper.save(key: KeychainHelper.telegramBotUsernameKey, value: username)
                }
            }
            self.startManagedBotCreationIfPossible()
            await self.sendAssistantGreetingIfPending()
        }
    }

    /// An assistant made by /newassistant says hello once in its own chat.
    func sendAssistantGreetingIfPending() async {
        guard KeychainHelper.load(key: KeychainHelper.assistantGreetingPendingKey) == "true",
              isTelegramConfigured, let chat = pairedChatId, !isRestoringMind else { return }
        let name = AssistantName.current()
        do {
            try await telegramService.sendMessage(chatId: chat, text: "Hi, I'm \(name) 👋 — your new assistant. I have my own memory, reminders and settings; tell me what I'm for and we can start. (/commands lists what I can do.)")
            try? KeychainHelper.delete(key: KeychainHelper.assistantGreetingPendingKey)
        } catch {
            print("[ManagedBots] first hello not sent yet: \(TelegramBotService.redactBotTokens(in: error.localizedDescription))")
        }
    }

    /// `/status` line for the default assistant (several assistants).
    func managedBotStatusLine() -> String? {
        guard managedBotsActiveHere else { return nil }
        var line = "Telegram bot management: "
        switch managedBotCapability {
        case true?: line += "on (/newassistant creates assistants from here)"
        case false?: line += "off — turn on “Bot Management” for this bot in @BotFather to use /newassistant"
        case nil: line += "unknown (checked when Telegram connects)"
        }
        if let pending = ManagedBots.loadPending(), ManagedBots.isLive(pending, now: Date()) {
            line += " · pending: «\(pending.name)»" + (pending.failed == true ? " (send /newassistant retry)" : "")
        }
        return line
    }
}

/// The default assistant's side of a managed-bot token rotation: the
/// assistant whose bot it is runs `briglia --profile default __managed-bot
/// replace-token|current-token --bot <id> --for <profile>`. Default's own
/// process reads its own (manager) token, refuses a bot it did not create
/// for that assistant (profile, generation, manager bot), and prints one
/// bounded JSON line on stdout (`{"token": …}` or `{"code": …}`); stderr is
/// separate and never echoed.
enum ManagedBotRotation {
    enum Action: String { case replace = "replace-token", current = "current-token" }
    struct Failure: Error, CustomStringConvertible { let description: String }

    nonisolated(unsafe) static var executableOverride: String?
    static let maxOutputBytes = 4096

    static let messages: [String: String] = [
        "not_known": "this bot wasn't created with /newassistant for this assistant; use /switchbot <token> with a new bot from @BotFather",
        "manager_changed": "this bot was created by your first assistant's previous bot, which can't manage it any more; make a new bot in @BotFather and use /switchbot <token>",
        "no_manager": "your first assistant has no Telegram bot",
        "telegram": "Telegram refused the request",
        "usage": "internal error (bad request)",
    ]

    /// Selftests: answer in process instead of the default-side child.
    nonisolated(unsafe) static var runOverrideForTesting: ((Action, Int64, String) throws -> String)?

    static func run(_ action: Action, botId: Int64, profile: String) throws -> String {
        if let override = runOverrideForTesting { return try override(action, botId, profile) }
        let exe = executableOverride ?? AgentMailService.brigliaPath()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--profile", AssistantProfile.defaultName, "__managed-bot", action.rawValue,
                       "--bot", String(botId), "--for", profile]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: AssistantProfile.environmentKey)
        env[AssistantProfile.experimentalKey] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure(description: "couldn't ask the first assistant") }
        let data = (try? out.fileHandleForReading.read(upToCount: maxOutputBytes)) ?? Data()
        try? out.fileHandleForReading.close()
        p.waitUntilExit()
        let line = data.split(separator: 0x0a).first.map { Data($0) } ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        if p.terminationStatus == 0, let token = json?["token"] as? String, ManagedBots.looksLikeToken(token, botId: botId) {
            return token
        }
        let code = json?["code"] as? String ?? ""
        throw Failure(description: messages[code] ?? "the first assistant couldn't change the token")
    }
}
