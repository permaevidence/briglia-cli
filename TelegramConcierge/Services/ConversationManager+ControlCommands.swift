import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
import OpenCombineDispatch
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
extension ConversationManager {

    // MARK: - Telegram command menus (inline keyboards)

    /// Telegram-only: send a command menu with inline buttons. Every other
    /// channel — and the terminal/app command window, whose replies are
    /// captured rather than wired — gets the plain text, unchanged. A failed
    /// keyboard send falls back to the ordinary text path (retry + parking).
    func sendCommandMenu(_ menu: TelegramCommandMenu.Menu) async {
        if Self.commandCapture?.isOpen != true,
           let address = replyAddress, address.kind == .telegram,
           let chatId = Int(address.chatId),
           let keyboard = TelegramCommandMenu.keyboard(for: menu) {
            do {
                try await telegramService.sendMessage(chatId: chatId, text: menu.text, keyboard: keyboard)
                return
            } catch {
                print("[ConversationManager] Menu send failed (\(error)) — sending plain text")
            }
        }
        try? await sendText(menu.text)
    }

    /// Inline-keyboard tap (Telegram callback_query). Same fail-closed gate
    /// as messages — paired private chat AND paired sender, via the menu
    /// message the button hangs on — and an unpaired tap is dropped without
    /// even being answered, so a stranger learns nothing. A decoded action
    /// becomes the exact typed command and runs through
    /// handleControlCommandIfNeeded: a tap can never do anything typing
    /// couldn't. While a turn is running the tap is answered with an alert
    /// and the keyboard stays usable; otherwise the menu message is frozen
    /// (buttons removed, choice appended) before the handler's own reply.
    func processCallbackQuery(_ query: TelegramCallbackQuery) async {
        guard let menuMessage = query.message,
              TelegramPairing.acceptsPolledMessage(
                chatId: menuMessage.chat.id,
                chatType: menuMessage.chat.type,
                fromId: query.from.id,
                pairedChatId: pairedChatId
              ),
              !query.from.isBot else {
            return
        }
        if let address = telegramAddress {
            noteUserActivity(on: address)
        }
        guard let action = TelegramCommandMenu.decode(query.data ?? "") else {
            // A keyboard from another build or a corrupted payload: say so
            // in place, no chat message.
            try? await telegramService.answerCallbackQuery(
                id: query.id, text: "This menu is no longer valid — send the command again.", showAlert: false)
            return
        }
        guard let commandText = TelegramCommandMenu.commandText(for: action) else {
            try? await telegramService.answerCallbackQuery(id: query.id)
            await freezeMenu(menuMessage, note: "Send /model <model-id> to use a model that isn't listed.")
            return
        }
        // Context binding (Codex R1): a model/effort button is only valid for
        // the provider (+ model, for effort) it was built for. Checked here
        // so the common stale case gets an in-place alert and the keyboard
        // stays…
        if let stale = staleMenuReason(for: action) {
            try? await telegramService.answerCallbackQuery(id: query.id, text: stale, showAlert: true)
            return
        }
        if browserSettingsMutation {
            try? await telegramService.answerCallbackQuery(
                id: query.id, text: "Browser settings are being applied — tap again in a moment.", showAlert: true)
            return
        }
        if activeRunId != nil || activeProcessingTask != nil {
            try? await telegramService.answerCallbackQuery(
                id: query.id, text: "A turn is running — tap again when Briglia is idle, or /stop first.", showAlert: true)
            return
        }
        try? await telegramService.answerCallbackQuery(id: query.id)
        await freezeMenu(menuMessage, note: "▸ \(commandText)")
        // …and again right before applying: the two awaits above are real
        // suspension points during which a terminal / app-socket / browser
        // command may have switched provider or model.
        if let stale = staleMenuReason(for: action) {
            await freezeMenu(menuMessage, note: "▸ \(commandText) — not applied: \(stale)")
            try? await sendText("Not applied — \(stale)", to: telegramAddress)
            return
        }
        print("[ConversationManager] Menu tap → \(commandText)")
        _ = await handleControlCommandIfNeeded(commandText)
    }

    /// The runtime main-model slot of the active provider (the value /model
    /// shows and changes).
    func currentMainModel() -> String {
        let key: String
        switch LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey)) {
        case .openRouter: key = KeychainHelper.openRouterModelKey
        case .lmStudio: key = KeychainHelper.lmStudioModelKey
        case .openAICompatible: key = KeychainHelper.openAICompatibleModelKey
        }
        return KeychainHelper.load(key: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// nil when the tapped button still matches the active state; otherwise
    /// the user-facing reason. Provider buttons name a destination and are
    /// never stale.
    private func staleMenuReason(for action: TelegramCommandMenu.Action) -> String? {
        let active = ProviderProfiles.activeProfile()
        switch action {
        case .provider(let value):
            return ProviderServers.staleProviderTap(value)
        case .modelTyped:
            return nil
        case .model(let profile, _):
            guard active?.rawValue != profile else { return nil }
            let builtFor = ProviderProfiles.Profile(rawValue: profile)?.displayName ?? profile
            let now = active?.displayName ?? "not set"
            return "this menu is outdated: it was for \(builtFor) and the active provider is now \(now). Send /model again."
        case .effort(let context, _):
            guard let active, TelegramCommandMenu.effortContext(profile: ProviderProfiles.menuContextIdentity() ?? active.rawValue, model: currentMainModel()) != context else {
                return active == nil ? "this menu is outdated: no active provider profile. Send /effort again." : nil
            }
            return "this menu is outdated: the provider or model changed since it was sent. Send /effort again."
        case .openRouterPreset:
            // A model button names its destination; it only needs the
            // OpenRouter profile to still be the active one.
            return active == .openrouter ? nil : "this menu is outdated: OpenRouter is no longer the active provider. Send /model again."
        case .orProvider(let context, _):
            guard active == .openrouter,
                  TelegramCommandMenu.effortContext(profile: ProviderProfiles.Profile.openrouter.rawValue, model: currentMainModel()) == context else {
                return "this menu is outdated: the provider or model changed since it was sent. Send /orprovider again."
            }
            return nil
        }
    }

    private func freezeMenu(_ message: TelegramMessage, note: String) async {
        let text = TelegramCommandMenu.frozenText(original: message.text ?? "", note: note)
        do {
            try await telegramService.editMessageText(chatId: message.chat.id, messageId: message.messageId, text: text)
        } catch {
            print("[ConversationManager] Could not freeze menu message \(message.messageId): \(error)")
        }
    }

    func handleControlCommandIfNeeded(_ text: String) async -> Bool {
        let token = commandToken(from: text)
        // Parked for an update (§6.4, Codex stage-2 R2): terminal/app commands
        // reach this without the poll loop; only read-only /status runs.
        if admissionPaused, text.hasPrefix("/"), token != "/status", !(token == "/upgrade" && upgradeCoordinatorTask != nil) {
            try? await sendText(Self.updatingRefusal)
            return true
        }
        if browserSettingsMutation, text.hasPrefix("/") {
            try? await sendText("Browser settings are being applied. Please retry this command in a moment.")
            return true
        }
        
        browserSettingsCommandIngress += 1
        defer { browserSettingsCommandIngress -= 1 }
        switch token {
        case "/stop":
            await cancelWaitingUpgradeForStop()
            await stopActiveExecution()
            return true
        case "/cachestats":
            do { try await sendText(ResponsesUsageStore().summary()) }
            catch { try? await sendText("Cache statistics unavailable: cannot safely read the local usage ledger.") }
            return true
        case "/spend":
            await handleSpendCommand(argument: commandArgument(from: text))
            return true
        case "/more1":
            await increaseSpendLimitIfNeeded(by: 1)
            return true
        case "/more5":
            await increaseSpendLimitIfNeeded(by: 5)
            return true
        case "/more10":
            await increaseSpendLimitIfNeeded(by: 10)
            return true
        case "/hide":
            await setPrivacyMode(enabled: true)
            return true
        case "/show":
            await setPrivacyMode(enabled: false)
            return true
        case "/subscription":
            await handleSubscriptionCommand(argument: commandArgument(from: text))
            return true
        case "/provider":
            await handleProviderCommand(argument: commandArgument(from: text))
            return true
        case "/websearch":
            await handleWebSearchBackendCommand(argument: commandArgument(from: text))
            return true
        // The legacy /llm, /llm_openrouter, /llm_local, /llm_openai switches
        // were REMOVED with /provider's arrival (owner, 2026-08-16): they
        // blindly rewrote llm_provider without restoring the profile's
        // model/effort/vision state, and were never in any menu or help.
        case "/transcribe_local":
            await switchVoiceTranscriptionProvider(to: .local)
            return true
        case "/transcribe_openai":
            await switchVoiceTranscriptionProvider(to: .openAI)
            return true
        case "/pulisci", "/prune":
            let argument = commandArgument(from: text).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard argument.isEmpty || argument == "nosnapshot" else {
                try? await sendText("Usage: /prune [nosnapshot]")
                return true
            }
            await manualPruneToolInteractions(noSnapshot: argument == "nosnapshot")
            return true
        case "/status":
            await sendTurnStatus()
            return true
        case "/board", "/bacheca":
            await handleBoardCommand()
            return true
        case "/commands", "/comandi":
            try? await sendText(ChatCommandRegistry.commandsListText())
            return true
        case "/continua", "/continue":
            await sendPendingContinuationChunk()
            return true
        case "/model":
            await handleModelCommand(argument: commandArgument(from: text))
            return true
        case "/effort":
            await handleEffortCommand(argument: commandArgument(from: text))
            return true
        case "/subagentmodels":
            await handleSubagentModelsCommand(argument: commandArgument(from: text))
            return true
        case "/orprovider":
            await handleOrProviderCommand(argument: commandArgument(from: text))
            return true
        case "/subagents":
            await handleSubagentsCommand(argument: commandArgument(from: text))
            return true
        case "/websubagent":
            await handleWebSubagentCommand(argument: commandArgument(from: text))
            return true
        // BGPRUNE{ A-CMD
        case "/prunebackground":
            await backgroundPruneCommand(argument: commandArgument(from: text))
            return true
        // }BGPRUNE
        case "/archiveinline":
            await handleArchiveInlineCommand(argument: commandArgument(from: text))
            return true
        case "/keepsummaries":
            await handleKeepSummariesCommand(argument: commandArgument(from: text))
            return true
        case "/upgrade":
            if await handleUpgradeSubcommand(commandArgument(from: text)) { return true }
            await handleUpgradeCommand()
            return true
        case "/upgradecheck":
            await handleUpgradeCheckCommand(argument: commandArgument(from: text))
            return true
        case "/restart", "/riavvia":
            await handleRestartCommand()
            return true
        case "/deleteuserdata":
            await handleDeleteUserDataCommand(argument: commandArgument(from: text))
            return true
        case "/exportmind":
            await handleExportMindCommand(argument: commandArgument(from: text))
            return true
        case "/importmind":
            await handleImportMindCommand(argument: commandArgument(from: text))
            return true
        case "/resumewatcher":
            await handleResumeWatcherCommand(argument: commandArgument(from: text))
            return true
        case "/setname":
            await handleSetNameCommand(argument: commandArgument(from: text))
            return true
        case "/rotateaffinity":
            await handleRotateAffinityCommand()
            return true
        case "/switchbot":
            await handleSwitchBotCommand(argument: commandArgument(from: text))
            return true
        default:
            return false
        }
    }

    /// `/setname` — set or change the stored user name (the post-wipe
    /// counterpart to /deleteuserdata, which erases it). Same fat-thumb
    /// design: `/setname <name>` only PROPOSES and echoes the exact value;
    /// `/setname confirm` applies it. The name feeds the system prompt and
    /// serves as /deleteuserdata's confirmation token, so "confirm" itself
    /// is reserved.
    /// `/rotateaffinity` (plan §3.3): a single file write under
    /// `affinity.lock` that replaces the install salt. Every lane presents a
    /// new session value from its next request; requests in flight finish
    /// with the old one. Human-only: no tool, no scheduler, no watcher path
    /// reaches this handler.
    private func handleRotateAffinityCommand() async {
        guard replyAddress != nil else { return }
        do {
            try SessionAffinity.rotateSalt()
            try? await sendText("🔄 Session identity rotated. From the next request, every conversation, subagent session and background lane presents a new session value to OpenCode (and OpenRouter). Cost: one prompt-cache miss per lane. Nothing was deleted or changed in memory.")
        } catch let failure as SessionAffinity.WriteFailure {
            switch failure.phase {
            case .beforeRename:
                try? await sendText("✖ Rotation did not happen: \(failure.description). The previous session identity is unchanged.")
            case .afterRename:
                try? await sendText("⚠️ Rotation took effect (the new state is in place), but its directory entry could not be proven durable: \(failure.description). Run `briglia doctor` if this repeats.")
            }
        } catch {
            try? await sendText("✖ Rotation did not happen: \(error). The previous session identity is unchanged.")
        }
    }

    private func handleSetNameCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let current = (KeychainHelper.load(key: KeychainHelper.userNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentLabel = current.isEmpty ? "not set" : "«\(current)»"

        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            var lines = ["Your stored name: \(currentLabel)."]
            if let proposal = pendingUserNameProposal {
                lines.append("Pending change to «\(proposal)» — send /setname confirm to apply, or /setname <other name> to replace the proposal.")
            } else {
                lines.append("To change it: /setname <new name>, then /setname confirm.")
            }
            try? await sendText(lines.joined(separator: "\n"))
            return
        }

        if trimmed.lowercased() == UserNameChange.confirmToken {
            guard let proposal = pendingUserNameProposal else {
                try? await sendText("Nothing to confirm — propose a name first with /setname <new name>.")
                return
            }
            // Idle guard (same shape as /model): the name feeds the system
            // prompt, and changing it mid-turn would flip the prompt-cache
            // prefix between rounds of a running turn.
            guard activeRunId == nil, activeProcessingTask == nil else {
                try? await sendText("⏳ A turn is running — send /setname confirm again when Briglia is idle (or /stop first).")
                return
            }
            do {
                try KeychainHelper.save(key: KeychainHelper.userNameKey, value: proposal)
            } catch {
                try? await sendText("✖ Could not save the name: \(error.localizedDescription)")
                return
            }
            pendingUserNameProposal = nil
            try? await sendText("✔ Your name is now «\(proposal)». It's used in the system prompt and as the /deleteuserdata confirmation.")
            return
        }

        switch UserNameChange.validate(argument) {
        case .valid(let name):
            pendingUserNameProposal = name
            let changeLabel = current.isEmpty
                ? "Set your name to «\(name)»?"
                : "Change your name from «\(current)» to «\(name)»?"
            try? await sendText("\(changeLabel) Send /setname confirm to apply — anything else leaves it unchanged.")
        case .empty:
            // Unreachable (bare handled above), kept for exhaustiveness.
            try? await sendText("Usage: /setname <new name>, then /setname confirm.")
        case .tooLong:
            try? await sendText("✖ That name is longer than \(UserNameChange.maxLength) characters — use something shorter.")
        case .reserved:
            try? await sendText("✖ \"confirm\" is this command's own confirmation word and can't be a name.")
        }
    }

    /// `/deleteuserdata` — two-step remote wipe of everything Ada.app's
    /// "Delete All Data" button erases (conversation, archives, user context,
    /// reminders/watchers, documents, ledger, todos, subagent histories)
    /// plus the stored user name AND email access: the AgentMail key is
    /// deleted so a machine handoff can't read the old owner's inbox (user
    /// decision, 2026-08-22). Since gws was removed (2026-10-24) Briglia never
    /// runs or deletes gws; the warning tells the user how to sign it out
    /// when ~/.config/gws exists. The bare command
    /// deletes NOTHING — it replies with the exact confirmation form
    /// (`/deleteuserdata <stored name>`, or the literal CONFIRM when no name
    /// is stored), so a fat-fingered or half-remembered send can't erase
    /// months of memory. Non-email API keys, provider profiles, settings,
    /// skills, and channel pairing survive: Briglia stays reachable, just with
    /// total amnesia and no inbox.
    /// Pre-wipe warning shown by the bare command. Static + pure so the
    /// selftest can pin that it discloses EVERYTHING the confirmed wipe
    /// actually deletes — Codex (2026-08-22) caught it still promising
    /// "Kept: API keys" after the wipe started deleting email credentials;
    /// irreversible removals must be disclosed BEFORE the confirmation
    /// token, never discovered in the completion message.
    nonisolated static func deleteUserDataWarningText(token: String, gwsConfigPresent: Bool = false) -> String {
        """
        ⚠️ This permanently erases ALL of Briglia's memory:
        • conversation history, images and attachments
        • long-term memory archives and summaries
        • learned user context and your stored name
        • reminders and watchers (including pending triggers)
        • saved documents, files ledger and todo list
        • subagent session histories
        • ChatGPT subscription login (signed out locally; your subscription itself is unchanged)
        • the local calendar and EMAIL ACCESS: the AgentMail API key is deleted (server-side mailboxes are untouched; set up AgentMail again in `briglia menu` to reconnect email)\(gwsConfigPresent ? "\n• NOT touched: Google's gws program. Briglia no longer uses it; if Google email was connected through it earlier, run `gws auth logout` and delete ~/.config/gws yourself" : "")

        Also stopped and discarded: running background jobs and subagents, their pending notifications, buffered attachments, pending replies, calendar/contacts caches, logs, and temporary tool outputs.

        Kept: other API keys (LLM, web search, images), provider profiles, settings, skills, channel pairing, and the projects folder (your work product, not memory). Any .mind backups you exported stay wherever you saved them.

        This cannot be undone. To confirm, send:
        /deleteuserdata \(token)
        """
    }

    private func handleDeleteUserDataCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let decision = DeleteUserDataConfirmation.decide(
            argument: argument,
            storedName: KeychainHelper.load(key: KeychainHelper.userNameKey)
        )
        switch decision {
        case .instructions(let token):
            try? await sendText(Self.deleteUserDataWarningText(
                token: token, gwsConfigPresent: RetiredIntegrations.gwsConfigDirectoryExists()))
        case .mismatch:
            try? await sendText("✖ Confirmation doesn't match — nothing was deleted. Send /deleteuserdata (no argument) to see the exact confirmation command.")
        case .confirmed:
            // Idle guard (same shape as /restart): wiping under a running
            // turn would erase state the turn is about to write back, and
            // wiping during memory maintenance or a Mind restore would race
            // the archive writer mid-file.
            guard activeRunId == nil, activeProcessingTask == nil else {
                try? await sendText("⏳ A turn is running — send the command again when Briglia is idle (or /stop first).")
                return
            }
            guard maintenanceActivities.isEmpty, archiveRecoveryTask == nil, !isRestoringMind else {
                try? await sendText("⏳ Memory maintenance is in flight — try again in a minute.")
                return
            }
            guard stalledConfirmUpdateId == nil else {
                try? await sendText("✖ Briglia can't persist state to disk right now (writes failing — check disk space); /deleteuserdata is deferred until storage recovers.")
                return
            }
            lastWipeNotes = []
            let failures = await deleteAllMemory()
            // Several assistants (§25.6): a note that the shared ChatGPT login
            // stays for the others is sent after the result.
            defer { for note in lastWipeNotes { Task { [weak self] in try? await self?.sendText(note) } } }
            if let first = failures.first, first.hasPrefix("ABORTED: ") {
                try? await sendText("✖ " + first)
            } else if failures.isEmpty {
                try? await sendText("🗑️ All user data deleted: conversation, archives, user context, stored name, reminders and watchers, background jobs and their pending notifications, documents, files ledger, todos, subagent histories, logs, temporary tool outputs, the local calendar, and email access (AgentMail key — the email/calendar provider is reset to none; server-side mailboxes are untouched, set up AgentMail again in `briglia menu` to reconnect email). Other API keys, settings and pairing were kept. /restart is recommended for a completely fresh session, and /setname <name> re-stores your name whenever you like.")
            } else {
                let list = failures.map { "• \($0)" }.joined(separator: "\n")
                try? await sendText("""
                ⚠️ Wipe finished, but \(failures.count) step(s) could not be verified as deleted:
                \(list)

                Everything else was erased. Check disk space/permissions, then send /deleteuserdata again — it will show the current confirmation form.
                """)
            }
        }
    }

    // MARK: - /exportmind and /importmind (Mind backup and restore)

    /// Where /exportmind writes its backup: ~/Desktop when it exists (Macs,
    /// desktop Linux), the home directory otherwise (headless Linux,
    /// Ubuntu Touch — user decision, 2026-08-27).
    nonisolated static func mindExportDestinationDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: desktop.path, isDirectory: &isDir), isDir.boolValue {
            return desktop
        }
        return home
    }

    /// Non-destructive consistency barrier for /exportmind (Codex,
    /// 2026-08-27): the restore gate blocks NEW work, but producers already
    /// running — background subagents, managed bash jobs, watcher checks,
    /// triage runs — keep writing files the export is copying, yielding a
    /// mixed-time or torn backup. Nothing may be cancelled for a read-only
    /// backup, so the long-lived writer classes refuse the export outright
    /// and the transient classes (checks, triage) get a short bounded wait.
    /// Call inside the restore gate (so no new producer starts between this
    /// check and the copy); returns a user-facing reason to refuse, nil
    /// when the export may proceed.
    func exportBusyReason(timeoutSeconds: Double = 5) async -> String? {
        if recoveryBlocked || activeTurnCheckpoints.values.contains(where: { $0.pendingRecovery }) {
            return "unfinished turn recovery must be saved before a complete backup can be exported — free storage and retry the turn first"
        }
        let subagents = await SubagentBackgroundRegistry.shared.activeRunIds()
        guard subagents.isEmpty else {
            return "background subagent(s) still running (\(subagents.joined(separator: ", "))) — wait for them to finish"
        }
        let jobs = await BackgroundProcessRegistry.shared.runningBackgroundJobCount()
        guard jobs == 0 else {
            return "\(jobs) background job(s) still running — wait for them to finish (or kill them) first"
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while (!watcherChecksInFlight.isEmpty || !triageRunsInFlight.isEmpty) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard watcherChecksInFlight.isEmpty else {
            return "\(watcherChecksInFlight.count) watcher check(s) still running — try again in a minute"
        }
        guard triageRunsInFlight.isEmpty else {
            return "\(triageRunsInFlight.count) watcher triage run(s) still in flight — try again in a minute"
        }
        return nil
    }

    /// `/exportmind` — write a complete .mind backup (the same archive
    /// Ada.app's export produces, so backups move between the two products)
    /// to the Desktop/home directory. Read-only with respect to memory, but
    /// held under the restore gate for the copy window so no turn or
    /// maintenance writer tears files mid-zip, and refused while
    /// already-running background writers could mix into the copy.
    private func handleExportMindCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scope: MindExportService.ExportScope
        switch trimmed {
        case "": scope = .full
        case "lite", "text", "testo": scope = .lite
        default:
            try? await sendText("Usage: /exportmind — full backup, or /exportmind lite — memory only (no documents, images, attachment snapshots, or projects; much smaller).")
            return
        }
        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("⏳ A turn is running — send /exportmind again when Briglia is idle (or /stop first).")
            return
        }
        guard maintenanceActivities.isEmpty, archiveRecoveryTask == nil, !isRestoringMind else {
            try? await sendText("⏳ Memory maintenance is in flight — try again in a minute.")
            return
        }
        guard beginMindRestore() else {
            try? await sendText("⏳ Briglia became busy — try again in a moment.")
            return
        }
        defer { endMindRestore() }
        if let busy = await exportBusyReason() {
            try? await sendText("✖ Cannot export a consistent backup right now: \(busy). Nothing was written.")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let baseName = scope == .lite ? "briglia-mind-lite" : "briglia-mind"
        let destination = Self.mindExportDestinationDirectory()
            .appendingPathComponent("\(baseName)-\(formatter.string(from: Date())).\(MindExportService.fileExtension)")
        do {
            try await MindExportService.shared.exportMind(to: destination, scope: scope)
            var sizeNote = ""
            if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
               let bytes = (attrs[.size] as? NSNumber)?.int64Value {
                sizeNote = " (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
            }
            let contents = scope == .lite
                ? "It is a LITE backup: the memory only — conversation, long-term archives, user context, reminders and watchers, ledger, todos, and subagent sessions — with NO saved documents, images, attachment snapshots, or projects (their cached descriptions survive, the files themselves do not). Restoring it leaves those areas EMPTY on the target machine. No API keys or credentials."
                : "It contains the conversation, long-term archives, user context, reminders and watchers, documents, ledger, todos, and subagent sessions — no API keys or credentials."
            try? await sendText("""
            💾 Memory backup saved\(sizeNote):
            \(destination.path)

            \(contents) Restore it anytime (on this machine or another Briglia) with:
            /importmind \(destination.path)
            """)
        } catch {
            try? await sendText("✖ Export failed: \(error.localizedDescription)")
        }
    }

    /// Streaming SHA-256 + byte count of a file (1 MiB chunks — .mind
    /// archives can be hundreds of MB, never load them whole). nil when the
    /// file cannot be opened OR a read fails mid-file (Codex round 2: a
    /// read error must never be treated as EOF — a partial digest reported
    /// as the file's fingerprint would be a lie in both directions).
    nonisolated static func mindArchiveFingerprint(path: String) -> (sha256: String, bytes: Int64)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1_048_576) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, total)
    }

    /// Pre-import warning shown by the proposal step. Static + pure so the
    /// selftest can pin that it discloses the full replacement scope and
    /// the no-automatic-backup fact BEFORE the confirmation token (the
    /// /deleteuserdata disclosure contract).
    nonisolated static func importMindWarningText(path: String, exportDate: Date, absentPayloadFolders: [String] = []) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        // Human names for the payload folders a backup may lack (a lite
        // export, or an install that simply had none). Restore clears the
        // counterpart either way — that must be said BEFORE the token.
        let payloadNames = [
            "images": "images",
            "documents": "documents",
            "tool_attachments": "attachment snapshots",
            "projects": "projects",
            "research": "research reports"
        ]
        var emptyNote = ""
        if !absentPayloadFolders.isEmpty {
            let listed = absentPayloadFolders.map { payloadNames[$0] ?? $0 }.joined(separator: ", ")
            emptyNote = """


        This backup carries NO saved files for: \(listed) (a lite/memory-only backup, or the source had none). After import those areas are EMPTY on this machine — their current contents are deleted.
        """
        }
        return """
        ⚠️ This REPLACES all of Briglia's current memory with the backup:
        \(path)
        (exported \(formatter.string(from: exportDate)))

        Replaced: conversation history, long-term memory archives, learned user context and stored name, reminders and watchers, saved documents, files ledger, todos, and subagent session histories. Running background jobs and subagents are stopped and their pending results discarded.\(emptyNote)

        Kept: API keys, provider profiles, settings, skills, and channel pairing.

        Only import backups you trust: a backup can contain watcher check scripts — shell programs that would run automatically on schedule. As a safeguard, imported scripted watchers arrive PAUSED and quarantined: only you can re-arm them, by typing /resumewatcher — Briglia itself cannot resume them.

        The current memory is NOT saved automatically — run /exportmind first if you want a way back.

        To proceed, send:
        /importmind confirm
        (or /importmind cancel)
        """
    }

    /// `/importmind` — two-step restore of a .mind backup. The path step is
    /// read-only: it stages and validates the archive (junk rejects here,
    /// nothing touched) and shows the warning; only an explicit
    /// `/importmind confirm` runs the destructive performMindImport flow,
    /// which re-stages and re-validates from the path. Same fat-thumb
    /// design as /deleteuserdata.
    private func handleImportMindCommand(argument: String) async {
        guard replyAddress != nil else { return }
        var trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        // Users paste paths with surrounding quotes (Finder "Copy as
        // Pathname", shell completion) — strip one matched pair.
        for quote in ["\"", "'"] where trimmed.count >= 2
            && trimmed.hasPrefix(quote) && trimmed.hasSuffix(quote) {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        if trimmed.isEmpty {
            try? await sendText("""
            Restore a memory backup (.mind file):
            /importmind <path-to-file.mind>

            Briglia validates the file and asks for confirmation before replacing anything. Create backups with /exportmind.
            """)
            return
        }

        if trimmed.lowercased() == "cancel" {
            let hadPending = pendingMindImport != nil
            pendingMindImport = nil
            try? await sendText(hadPending
                ? "✔ Import cancelled — nothing was changed."
                : "Nothing to cancel — no import is pending.")
            return
        }

        if trimmed.lowercased() == "confirm" {
            guard let pending = pendingMindImport else {
                try? await sendText("✖ No import is pending. Send /importmind <path> first.")
                return
            }
            // Idle guards (same shape as /deleteuserdata): importing under a
            // running turn would erase state the turn is about to write
            // back; performMindImport's gate re-checks atomically.
            guard activeRunId == nil, activeProcessingTask == nil else {
                try? await sendText("⏳ A turn is running — send the command again when Briglia is idle (or /stop first).")
                return
            }
            guard maintenanceActivities.isEmpty, archiveRecoveryTask == nil, !isRestoringMind else {
                try? await sendText("⏳ Memory maintenance is in flight — try again in a minute.")
                return
            }
            guard stalledConfirmUpdateId == nil else {
                try? await sendText("✖ Briglia can't persist state to disk right now (writes failing — check disk space); /importmind is deferred until storage recovers.")
                return
            }
            let outcome = await performMindImport(
                from: URL(fileURLWithPath: pending.path),
                expectedSHA256: pending.sha256,
                expectedBytes: pending.bytes)
            switch outcome {
            case .success(let pausedWatchers):
                pendingMindImport = nil
                var message = "✅ Memory restored from \(pending.path). Briglia now carries that backup's conversation, archives, user context, reminders and watchers, documents, todos, and subagent sessions. The .mind file itself is no longer needed — you can delete it. /restart is recommended for a completely fresh session."
                if pausedWatchers > 0 {
                    message += "\n\n⚠️ \(pausedWatchers) scripted watcher(s) from the backup are PAUSED and quarantined for security review — a backup can carry check scripts (shell code that runs automatically when due). Type /resumewatcher to review them, and re-arm only the ones you recognize; Briglia itself cannot resume quarantined watchers."
                }
                try? await sendText(message)
            case .refusedGate:
                try? await sendText("⏳ A turn or memory maintenance became active — nothing was changed; try again when Briglia is idle. The pending import is still armed: /importmind confirm.")
            case .refusedBusy(let reason):
                try? await sendText("✖ ABORTED: \(reason) — nothing was changed; try again in a minute. The pending import is still armed: /importmind confirm.")
            case .rejectedArchive(let message):
                pendingMindImport = nil
                try? await sendText("✖ \(message)")
            case .failedApply(let message):
                pendingMindImport = nil
                try? await sendText("""
                ⚠️ Import failed while replacing data: \(message)
                The previous memory may be PARTIALLY replaced. Restore another backup with /importmind, or run /deleteuserdata for a clean state.
                """)
            case .failedBeforeApply(let message, let advanced):
                try? await sendText("""
                ✖ ABORTED before replacing anything: could not record the new session identity — \(message)
                Your current memory is intact and nothing was discarded.\(advanced ? " The session identity presented to OpenCode has already advanced (harmless: one cache miss)." : "") Fix the cause (see `briglia doctor`) and retry: /importmind confirm.
                """)
            }
            return
        }

        // A path: validate read-only, then propose.
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? await sendText("✖ File not found: \(expanded)\nNothing was changed.")
            return
        }
        guard let fingerprint = Self.mindArchiveFingerprint(path: expanded) else {
            try? await sendText("✖ Cannot read \(expanded) — check permissions. Nothing was changed.")
            return
        }
        do {
            let staged = try await MindExportService.shared.stageMind(from: url)
            let exportDate = staged.exportDate
            // Validate the watcher rows too (throwaway staged tree): an
            // archive whose reminders.json cannot be decoded — and thus
            // cannot be quarantined — should reject at the proposal step,
            // not surprise the user at confirm.
            do {
                _ = try ReminderService.prepareStagedReminders(stagedRoot: staged.tempDir)
            } catch {
                await MindExportService.shared.discardStagedMind(staged)
                try? await sendText("✖ \(error.localizedDescription) Nothing was changed.")
                return
            }
            // Which payload folders the backup lacks (lite export, or the
            // source had none): restore clears those areas, so the warning
            // must name them before the confirmation token.
            let absentPayload = MindExportService.ExportScope.payloadFolderNames.filter {
                !FileManager.default.fileExists(atPath: staged.tempDir.appendingPathComponent($0).path)
            }
            await MindExportService.shared.discardStagedMind(staged)
            pendingMindImport = PendingMindImport(
                path: expanded, exportDate: exportDate,
                sha256: fingerprint.sha256, bytes: fingerprint.bytes)
            try? await sendText(Self.importMindWarningText(path: expanded, exportDate: exportDate, absentPayloadFolders: absentPayload))
        } catch {
            try? await sendText("✖ \(error.localizedDescription)")
        }
    }

    /// `/resumewatcher` — the ONLY path that re-arms an import-quarantined
    /// watcher (Codex round 4, 2026-08-27). Quarantine provenance is durable
    /// (`importQuarantined` in reminders.json) and `manage_reminders`
    /// action='resume' refuses on it, so approval can only come from the
    /// user typing this command — a model turn, ambient trigger, or
    /// subagent cannot reach it. Bare command lists the quarantined
    /// watchers; `/resumewatcher <id>` (full UUID or a ≥8-char unique
    /// prefix) approves exactly one.
    private func handleResumeWatcherCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let quarantined = await ReminderService.shared.importQuarantinedWatchers()

        if trimmed.isEmpty {
            guard !quarantined.isEmpty else {
                try? await sendText("No quarantined watchers — nothing to review. (This command re-arms watchers quarantined by a Mind import; watchers paused after script failures are resumed by asking Briglia.)")
                return
            }
            var lines = ["\(quarantined.count) watcher(s) from the imported backup are quarantined. Their check scripts are shell programs that will run automatically on schedule once resumed — re-arm only the ones you recognize:"]
            for watcher in quarantined {
                lines.append("")
                lines.append("• \(watcher.id.uuidString)")
                lines.append("  \(String(watcher.prompt.prefix(140)))")
                if let recurrence = watcher.recurrence {
                    lines.append("  Schedule: \(recurrence.description)")
                }
                if let path = watcher.scriptPath {
                    lines.append("  Script: \(path)")
                }
            }
            lines.append("")
            lines.append("To re-arm one: /resumewatcher <id> (the first 8+ characters are enough). To inspect a script first, ask Briglia to show it; to get rid of one, ask Briglia to delete it.")
            try? await sendText(lines.joined(separator: "\n"))
            return
        }

        // Resolve a full UUID or a unique prefix (≥8 chars — phone-friendly,
        // but short enough prefixes would make fat-thumbed approvals easy).
        let needle = trimmed.lowercased()
        guard needle.count >= 8 else {
            try? await sendText("✖ Give at least the first 8 characters of the watcher id — /resumewatcher lists them.")
            return
        }
        let matches = quarantined.filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        guard matches.count == 1 else {
            try? await sendText(matches.isEmpty
                ? "✖ No quarantined watcher matches «\(trimmed)». /resumewatcher lists them."
                : "✖ Ambiguous — \(matches.count) quarantined watchers match «\(trimmed)». Use more characters of the id.")
            return
        }

        switch await ReminderService.shared.resumeImportedWatcher(id: matches[0].id) {
        case .success(let nextCheck):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            try? await sendText("✔ Watcher re-armed: \(String(matches[0].prompt.prefix(100))) — next check \(formatter.string(from: nextCheck)).")
        case .failure(let error):
            try? await sendText("✖ \(error.message)")
        }
    }

    /// `/switchbot` — replace the Telegram bot AND owner chat in one guided
    /// flow (built for handing a machine's Briglia to a new owner, or replacing a
    /// wedged bot). The user supplies ONLY the new token; the chat id is
    /// discovered by having the new owner send a one-time code TO the new
    /// bot, which proves token, chat id, and control of the chat in one step.
    /// Same fat-thumb design as /deleteuserdata: nothing changes until an
    /// explicit `/switchbot confirm`, and the cutover itself is a single
    /// atomic credential write at a poll-loop boundary.
    private func handleSwitchBotCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let action = BotSwitchFlow.decide(
            argument: argument,
            hasPending: pendingBotSwitch != nil,
            hasDiscovered: pendingBotSwitch?.discovered != nil,
            cutoverInProgress: botSwitchCutoverInProgress
        )
        switch action {
        case .finalizing:
            try? await sendText("⏳ The bot switch is being finalized right now — it can no longer be cancelled or changed. I'll announce completion in a moment.")

        case .instructions:
            try? await sendText("""
            /switchbot moves Briglia to a different Telegram bot — for handing this machine's Briglia to a new owner, or replacing a broken bot. The current bot keeps working until the very last step.

            1. Create the new bot: message @BotFather → /newbot → copy the token.
            2. Send: /switchbot <token>
            3. I reply with a code. The NEW owner opens the new bot, presses START, and sends it that code.
            4. Finish with /switchbot confirm — the old bot disconnects at that moment.

            A switch does NOT wipe memory — for a real owner change, also run /deleteuserdata.
            """)

        case .status:
            guard let pending = pendingBotSwitch else { return }
            if let discovered = pending.discovered {
                try? await sendText("Switch to \(pending.botDisplay) is ready — code received from \(discovered.senderDisplay). Send /switchbot confirm to complete it, or /switchbot cancel to abort.")
            } else {
                try? await sendText("Switch to \(pending.botDisplay) is waiting for the code \(pending.code) to arrive in that bot's chat. /switchbot cancel aborts.")
            }

        case .cancel:
            botSwitchDiscoveryTask?.cancel()
            botSwitchDiscoveryTask = nil
            let hadPending = pendingBotSwitch != nil
            pendingBotSwitch = nil
            try? await sendText(hadPending
                ? "✔ Bot switch cancelled — the current bot is unchanged."
                : "Nothing to cancel — no bot switch is in progress.")

        case .invalidToken:
            try? await sendText("✖ That doesn't look like a bot token (format 123456789:AA…, from @BotFather). Or did you mean /switchbot confirm or /switchbot cancel?")

        case .confirmNotReady:
            if let pending = pendingBotSwitch {
                try? await sendText("⏳ The code hasn't arrived yet — send \(pending.code) to \(pending.botDisplay) first; I'll tell you when it lands.")
            } else {
                try? await sendText("Nothing to confirm — start with /switchbot <new bot token>.")
            }

        case .beginSwitch(let token, let discardBacklog):
            // Several assistants (MULTI_ASSISTANT_PLAN §5.6): discovery polls
            // the new bot's getUpdates, which would compete with another
            // assistant's poller; refused in multi mode until the
            // reservation-wired switch lands. No registry → unchanged, except
            // that default holds machine/identity-tx.lock from here until the
            // switch ends, so no first `profiles add` can hand this bot to
            // another assistant meanwhile (Codex stage-1 R2).
            let admittedLock: ProfileFileLock?
            switch BotSwitchDiscovery.admit(token: token, existing: botSwitchIdentityLock) {
            case .refused(let refusal):
                try? await sendText("✖ \(refusal)")
                return
            case .admitted(let lock):
                admittedLock = lock
            }
            let currentToken = (KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if token == currentToken {
                try? await sendText("✖ That is the CURRENT bot's token — paste the NEW bot's token (from @BotFather).")
                return
            }
            // Several assistants (§5.6 step 2): reserve the new bot BEFORE any
            // network use of it (getMe, webhook info, discovery). A pending
            // earlier switch is replaced: its reservation ends first. Never-
            // multi installs get no reservation (the identity lock suffices).
            if botSwitchTicket != nil {
                botSwitchDiscoveryTask?.cancel()
                botSwitchDiscoveryTask = nil
                pendingBotSwitch = nil
            }
            let ticket: IdentityChange.Ticket
            do {
                ticket = try IdentityChange.begin(kind: .bot, rawValue: token, mode: .assistant,
                                                  existingIdentityLock: admittedLock)
            } catch {
                try? await sendText("✖ \(error)")
                return
            }
            var keepTicket = false
            defer { if !keepTicket { ticket.abort() } }
            if ticket.reserved, let refusal = AssistantRegistry.telegramDiscoveryRefusal(token: token) {
                try? await sendText("✖ \(refusal)")
                return
            }
            let botInfo: TelegramBotInfo
            do {
                botInfo = try await telegramService.getMe(token: token)
            } catch {
                try? await sendText("✖ Telegram rejected that token: \(error.localizedDescription)\nCheck it with @BotFather and try again.")
                return
            }
            let display = botInfo.username.map { "@\($0)" } ?? "the new bot"
            // Preflight for a bot that is not actually fresh: a configured
            // webhook means another service owns it (and getUpdates-based
            // discovery cannot coexist with a webhook), and a queued backlog
            // would be permanently consumed by discovery's offset advance —
            // that needs an explicit go-ahead, never a silent discard
            // (Codex, 2026-08-22). A failed check falls through: the
            // discovery loop's error classification reports 409s anyway.
            if let infoData = try? await Self.botSwitchGetWebhookInfo(token: token),
               let info = BotSwitchFlow.parseWebhookInfo(infoData) {
                if !info.url.isEmpty {
                    try? await sendText("✖ \(display) already has a webhook configured — it's wired to another service, and /switchbot can't take over a bot that something else is using. Create a fresh bot with @BotFather instead.")
                    return
                }
                if info.pendingUpdateCount > 0 && !discardBacklog {
                    try? await sendText("""
                    ⚠ \(display) has \(info.pendingUpdateCount) undelivered message(s) queued from before. A switch permanently discards them.

                    If this is really the bot you want, resend as:
                    /switchbot <token> discard

                    Otherwise create a fresh bot with @BotFather.
                    """)
                    return
                }
            }
            botSwitchDiscoveryTask?.cancel()
            let code = BotSwitchFlow.generateCode()
            pendingBotSwitch = PendingBotSwitch(newToken: token, botDisplay: display, code: code)
            botSwitchIdentityLock = admittedLock
            if ticket.reserved { botSwitchTicket = ticket }
            keepTicket = ticket.reserved
            startBotSwitchDiscovery(token: token, code: code, botDisplay: display, identityLock: admittedLock)
            try? await sendText("""
            ✔ Token valid — found \(display).

            Now, from the account that will own this Briglia: open \(display) in Telegram, press START, and send it this code:

            \(code)

            I'm watching that bot for 10 minutes. When the code arrives I'll ask you to finish with /switchbot confirm. Nothing changes until then — /switchbot cancel aborts.
            """)

        case .cutover:
            // Idle guard (same shape as /model): the cutover re-routes the
            // reply channel; doing it under a running turn would flip the
            // turn's destination between rounds.
            guard activeRunId == nil, activeProcessingTask == nil else {
                try? await sendText("⏳ A turn is running — send /switchbot confirm again when Briglia is idle (or /stop first).")
                return
            }
            guard stalledConfirmUpdateId == nil else {
                try? await sendText("✖ Briglia can't persist state to disk right now (writes failing — check disk space); /switchbot is deferred until storage recovers.")
                return
            }
            pendingBotSwitch?.readyForCutover = true
            try? await sendText("🔁 Confirmed — switching to \(pendingBotSwitch?.botDisplay ?? "the new bot") in a moment. I'll say hello from the new chat.")
        }
    }

    /// Base URL shared with TelegramBotService (overridable for tests).
    private nonisolated static var telegramAPIBase: String {
        ProcessInfo.processInfo.environment["BRIGLIA_TELEGRAM_API_BASE"] ?? "https://api.telegram.org/bot"
    }

    /// Poll the NEW bot's getUpdates until the one-time code appears in a
    /// private chat, then record the discovered chat. Long-polling (20 s) is
    /// the pacing; transient errors retry until the 10-minute deadline.
    /// Advancing the offset also consumes the new bot's pre-switch messages
    /// server-side, so none of them can re-deliver as user turns after the
    /// cutover starts the main poller at a fresh offset.
    private func startBotSwitchDiscovery(token: String, code: String, botDisplay: String,
                                         identityLock: ProfileFileLock?) {
        botSwitchDiscoveryTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(BotSwitchFlow.discoveryTimeoutSeconds)
            // Re-checked before every request, the acknowledgment included
            // (BotSwitchDiscovery.run); the identity lock is also kept alive
            // by this task until its last request has returned.
            let (discovered, permanentFailure) = await BotSwitchDiscovery.run(
                token: token, code: code, deadline: deadline,
                refusal: { AssistantRegistry.telegramDiscoveryRefusal(token: token) },
                getUpdates: { try await Self.botSwitchGetUpdates(token: $0, offset: $1, timeoutSeconds: $2) })
            withExtendedLifetime(identityLock) {}
            guard !Task.isCancelled, let self else { return }
            await self.finishBotSwitchDiscovery(discovered: discovered, permanentFailure: permanentFailure,
                                                token: token, botDisplay: botDisplay)
        }
    }

    private func finishBotSwitchDiscovery(discovered: BotSwitchFlow.DiscoveredChat?, permanentFailure: String?,
                                          token: String, botDisplay: String) async {
        // A newer /switchbot may have replaced this flow while we polled.
        guard var pending = pendingBotSwitch, pending.newToken == token else { return }
        if let permanentFailure {
            pendingBotSwitch = nil
            botSwitchDiscoveryTask = nil
            await notifyBotSwitchProgress("✖ Telegram refused \(botDisplay)'s getUpdates: \(permanentFailure)\nBot switch cancelled — the current bot is unchanged. Fix the new bot (or create a fresh one) and run /switchbot again.")
            return
        }
        guard let discovered else {
            pendingBotSwitch = nil
            botSwitchDiscoveryTask = nil
            await notifyBotSwitchProgress("⌛ No code arrived within 10 minutes — bot switch cancelled; the current bot is unchanged. /switchbot <token> starts over.")
            return
        }
        pending.discovered = discovered
        pending.discoveredAt = Date()
        pendingBotSwitch = pending
        // Acknowledge inside the NEW chat so its owner sees progress too.
        try? await Self.botSwitchSendMessage(token: token, chatId: discovered.chatId,
            text: "✔ Code received. This chat becomes Briglia's home as soon as the current owner sends /switchbot confirm.")
        await notifyBotSwitchProgress("✔ Code received from \(discovered.senderDisplay) in \(botDisplay)'s chat. Send /switchbot confirm to complete the switch — the current bot disconnects at that moment. /switchbot cancel aborts. (Without a confirm the switch is cancelled after \(Int(BotSwitchFlow.confirmTimeoutSeconds / 60)) minutes.)")
    }

    /// Discovery progress reaches the user outside any command window: chat
    /// surfaces via the normal reply path, the terminal via the maintenance
    /// notice line (sendText no-ops for the .app address).
    private func notifyBotSwitchProgress(_ text: String) async {
        showMaintenanceNotice(text)
        try? await sendText(text)
    }

    /// /switchbot steps 3–4: drop the old bot's parked replies, retire its
    /// visibility notices (§4.1: invalidated, never re-sent; the new
    /// Telegram generation makes a notice already queued toward the actor
    /// refuse to build its request with the new token — checked at
    /// credential capture), then adopt the new bot.
    func cutOverTelegramBot(to token: String) async {
        parkedOutbound.removeAll { $0.address.kind == .telegram }
        NoticeChannelGenerations.bump(.telegram)
        invalidateNoticeSeries(kind: .telegram)
        await telegramService.adoptNewBot(token: token)
        await updateTelegramChannelRegistration()
    }

    /// One durability-stall tick of the poll loop: retry the durable writes;
    /// confirm and resume when they land. Unchanged behaviour; the A3
    /// notices only observe the episode's start and end and are never
    /// awaited (no history write, no offset, no confirmation change).
    func retryDurabilityStall(_ stalledId: Int) async {
        if saveConversation(), persistPendingMidTurnQueue(),
           persistPendingInboundBuffers(), remarkActiveTurnIfNeeded() {
            await telegramService.confirmProcessed(updateId: stalledId)
            stalledConfirmUpdateId = nil
            durabilityStallAnnounced = false
            print("[ConversationManager] Durable writes recovered — confirmed update \(stalledId), polling resumes")
            noteDurabilityStallRecovered()
        } else if !durabilityStallAnnounced {
            durabilityStallAnnounced = true
            print("[ConversationManager] Telegram polling PAUSED — durable writes failing with unconfirmed updates outstanding; retrying every tick")
            noteDurabilityStallBegan()
        }
    }

    /// A3 entry: one notice per stall episode, on ONE ordered series per
    /// Telegram chat that spans consecutive episodes (Codex impl review R2):
    /// a newer pause is never sent ahead of an older episode's notices. If
    /// the previous episode's recovery is still queued and unsent, the two
    /// cancel out (the earlier pause stands); a recovery already on the wire
    /// or attempted is followed by this pause. The chat and channel
    /// generation are captured when the series is created (right even when
    /// the last user channel was not Telegram; never migrates to a replacement
    /// bot). Not awaited; polling, confirmations and write retries are
    /// unchanged.
    func noteDurabilityStallBegan() {
        guard let address = telegramAddress else { return }
        if let series = durabilityStallSeries, !series.isClosed, series.target == .wire(address) {
            if series.retractUnsentTail(Self.durabilityStallRecoveryText) {
                durabilityStallPauseOwed = true      // the earlier pause stands
                return
            }
            if series.append(Self.durabilityStallEntryText) {
                durabilityStallPauseOwed = true
                return
            }
            // Drained and released: nothing of it is queued or in flight.
        }
        guard let series = makeNoticeSeries(target: .wire(address), awaitingCapture: false) else { return }
        series.finishesWhenDrained = true
        durabilityStallSeries = series
        durabilityStallPauseOwed = series.append(Self.durabilityStallEntryText)
    }

    /// A3 recovery: if this episode's entry is still queued and no send of
    /// it has begun, the episode coalesces away and NEITHER notice is sent;
    /// otherwise the recovery is queued behind it (sent only after the entry
    /// settled). An invalidated or given-up series sends nothing more.
    func noteDurabilityStallRecovered() {
        guard durabilityStallPauseOwed, let series = durabilityStallSeries else { return }
        durabilityStallPauseOwed = false
        guard !series.isClosed else { return }
        if series.retractUnsentTail(Self.durabilityStallEntryText) { return }
        if series.append(Self.durabilityStallRecoveryText) { return }
        // The series drained after delivering the pause: the recovery starts
        // a new one (nothing earlier can still be queued or in flight) —
        // only on the same bot identity, never through a replacement.
        guard case .wire(let address) = series.target,
              NoticeChannelGenerations.current(address.kind) == series.generation,
              let next = makeNoticeSeries(target: .wire(address), awaitingCapture: false) else { return }
        next.finishesWhenDrained = true
        durabilityStallSeries = next
        next.append(Self.durabilityStallRecoveryText)
    }

    /// An unconfirmed discovered switch reminds once halfway and expires
    /// after `BotSwitchFlow.confirmTimeoutSeconds`: it holds the new bot's
    /// reservation (and, in default, the identity lock that `profiles add`
    /// needs), so it must not stay forever (Codex stage-1 note 3).
    func expireUnconfirmedBotSwitchIfDue(now: Date = Date()) async {
        guard var pending = pendingBotSwitch, !pending.readyForCutover, let found = pending.discoveredAt else { return }
        let age = now.timeIntervalSince(found)
        if age >= BotSwitchFlow.confirmTimeoutSeconds {
            botSwitchDiscoveryTask?.cancel()
            botSwitchDiscoveryTask = nil
            pendingBotSwitch = nil
            await notifyBotSwitchProgress("⌛ /switchbot was not confirmed within \(Int(BotSwitchFlow.confirmTimeoutSeconds / 60)) minutes — bot switch cancelled; the current bot is unchanged. /switchbot <token> starts over.")
        } else if !pending.reminded, age >= BotSwitchFlow.confirmTimeoutSeconds / 2 {
            pending.reminded = true
            pendingBotSwitch = pending
            await notifyBotSwitchProgress("⏳ Reminder: send /switchbot confirm to finish moving to \(pending.botDisplay), or /switchbot cancel. It is cancelled automatically in \(Int(BotSwitchFlow.confirmTimeoutSeconds / 120)) minutes.")
        }
    }

    /// Execute a confirmed /switchbot. Called ONLY from the poll loop's clean
    /// boundary: no getUpdates batch is in flight there, so every confirm for
    /// the OLD bot has already been persisted under its own token hash —
    /// swapping here can never write old update ids into the new bot's
    /// offset state (which would silently drop the new bot's messages).
    func performPendingBotSwitchIfReady() async {
        guard !botSwitchCutoverInProgress else { return }
        await expireUnconfirmedBotSwitchIfDue()
        guard let pending = pendingBotSwitch, pending.readyForCutover,
              let discovered = pending.discovered else { return }
        // The confirm was idle-guarded; if a turn slipped in since (app,
        // ambient), wait for a later tick instead of re-routing under it.
        guard activeRunId == nil, activeProcessingTask == nil else { return }
        if let refusal = AssistantRegistry.telegramDiscoveryRefusal(token: pending.newToken) {
            pendingBotSwitch = nil
            await notifyBotSwitchProgress("✖ \(refusal) The switch did NOT happen and the current bot is unchanged.")
            return
        }
        // Freeze the state machine for the whole cutover: from here to the
        // end (including the failure path's notify await), every /switchbot
        // command is answered with "finalizing" — see BotSwitchFlow.decide.
        botSwitchCutoverInProgress = true
        defer { botSwitchCutoverInProgress = false }

        // 1. Both credentials as ONE atomic write — a mid-swap crash must
        //    never leave one bot's token with another bot's chat id.
        do {
            let write = {
                try KeychainHelper.saveBatch([
                    KeychainHelper.telegramBotTokenKey: pending.newToken,
                    KeychainHelper.telegramChatIdKey: String(discovered.chatId),
                ])
            }
            // Multi mode: the reservation's commit (§5.6 step 4) writes the
            // secret and keeps the old bot `releasing` until step 6 below.
            if let ticket = botSwitchTicket { try ticket.commit(write) } else { try write() }
        } catch {
            pendingBotSwitch?.readyForCutover = false
            await notifyBotSwitchProgress("✖ Could not save the new bot's credentials (\(error.localizedDescription)) — the switch did NOT happen and the current bot is unchanged. Fix storage, then send /switchbot confirm again.")
            return
        }

        // 2. Farewell on the OLD bot — only AFTER the commit succeeded, so
        //    the old chat is never told Briglia moved while it actually didn't
        //    (Codex, 2026-08-22). The service still holds the old token
        //    until adoptNewBot below. Direct, single-shot, best-effort —
        //    NOT sendText: its park-and-retry path would re-attempt via the
        //    NEW bot, which cannot message the old owner's chat after an
        //    owner swap.
        if isTelegramConfigured, let oldChatId = pairedChatId {
            try? await telegramService.sendMessage(chatId: oldChatId,
                text: "🔁 Briglia has moved to \(pending.botDisplay). This bot is no longer connected.")
        }

        // 3. Drop parked Telegram replies: they belong to the OLD bot's
        //    chat, and flushParkedOutbound would retry them through the new
        //    token (which cannot reach the old owner's chat after a
        //    handoff). Their text survives in conversation history — the
        //    park queue's documented durability assumption.
        //
        // 4. Fresh offsets under the new token's hash, then rebuild the
        //    channel registration (pairedChatId, trimmed command menu).
        await cutOverTelegramBot(to: pending.newToken)
        // §5.6 step 6: the old bot's poller is gone (the swap happened at
        // this clean loop boundary) and its farewell was sent; release it.
        botSwitchTicket?.finish()

        // 5. Ambient output follows Briglia's new home.
        if lastUserChannelAddress?.kind == .telegram, let address = telegramAddress {
            noteUserActivity(on: address)
        }

        pendingBotSwitch = nil
        botSwitchDiscoveryTask = nil

        // 6. Hello from the new chat (normal reply path — parking now
        //    correctly retries via the new bot).
        try? await sendText("""
        ✅ Switch complete — this is Briglia's home now; the previous bot is disconnected.

        If this machine changed owners: /deleteuserdata erases the previous owner's memory, and /setname <name> introduces yourself. /commands lists everything else.
        """, to: telegramAddress)
        showMaintenanceNotice("Telegram bot switched to \(pending.botDisplay).")
        print("[ConversationManager] /switchbot cutover complete → \(pending.botDisplay), chat \(discovered.chatId)")
    }

    private nonisolated static func botSwitchGetUpdates(token: String, offset: Int, timeoutSeconds: Int) async throws -> (status: Int, data: Data) {
        var components = URLComponents(string: "\(telegramAPIBase)\(token)/getUpdates")!
        components.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "timeout", value: String(timeoutSeconds)),
            URLQueryItem(name: "allowed_updates", value: "[\"message\"]"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = TimeInterval(timeoutSeconds + 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private nonisolated static func botSwitchGetWebhookInfo(token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(telegramAPIBase)\(token)/getWebhookInfo")!)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private nonisolated static func botSwitchSendMessage(token: String, chatId: Int, text: String) async throws {
        let url = URL(string: "\(telegramAPIBase)\(token)/sendMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["chat_id": chatId, "text": text])
        _ = try await URLSession.shared.data(for: request)
    }

    /// `/restart` — re-exec the current binary in place without touching the
    /// install. Applies configuration that only loads at startup (mcp.json,
    /// skills) from chat, no keyboard needed. Same guard rails as /upgrade's
    /// restart: refused mid-turn (the restart would discard the run) and
    /// during a durability stall (confirming this update's id would
    /// implicitly confirm the stalled one — and the re-delivered /restart
    /// would exec again on every retry, looping while the disk is broken).
    private func handleRestartCommand() async {
        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("⏳ A turn is running — send /restart again when Briglia is idle (or /stop first).")
            return
        }
        guard stalledConfirmUpdateId == nil else {
            try? await sendText("✖ Briglia can't persist state to disk right now (writes failing — check disk space); /restart is deferred until storage recovers.")
            return
        }
        // Background archiving (§9): a restart would interrupt the archive
        // (crash recovery skips fact extraction). Refused, not waited for.
        guard !maintenanceActivities.contains(where: { $0.kind == .summarizingHistory }), archiveRecoveryTask == nil else {
            try? await sendText("⏳ Memory archiving is in flight — send /restart again in a minute.")
            return
        }
        // BGPRUNE{ A-RST
        if backgroundPruneEngaged {
            if backgroundPruneBlocksExit {
                try? await sendText("⏳ A background prune is finishing — send /restart again in a minute, or /stop first.")
                return
            }
        }
        // }BGPRUNE
        archiveExitPending = true
        defer { archiveExitPending = false }
        UpgradeService.writeRestartMarker(version: adaCLIVersion, kind: .restart)
        saveConversation()
        try? await sendText("🔄 Restarting now — I'll confirm when I'm back online.")
        if let capture = Self.commandCapture, !capture.lines.isEmpty {
            for line in capture.lines { print("  " + line.replacingOccurrences(of: "\n", with: "\n  ")) }
        }
        stopPolling()
        // Confirm ONLY this /restart's own update before the exec, exactly
        // like /upgrade: later same-batch updates stay unconfirmed and
        // re-deliver to the restarted process.
        if let ownUpdateId = processingTelegramUpdateId {
            await telegramService.confirmProcessed(updateId: ownUpdateId)
        } else {
            await telegramService.persistOffsetNow()
        }
        UpgradeService.restartNow()
    }

    /// Startup counterpart of /restart's "I'll confirm when I'm back online."
    func announceRestartCompletion() async {
        try? await sendText("✅ Briglia restarted and is back online.", to: telegramAddress)
    }

    /// `/upgrade` — remote self-update: check the release CDN, swap the
    /// installed binary + bundle, and re-exec in place. Refused mid-turn (the
    /// restart would discard the run) and on sudo-owned install dirs (no one
    /// is at the keyboard to answer a password prompt).
    private func handleUpgradeCommand() async {
        // Updates are computer-wide: only the default assistant installs
        // them in this version (MULTI_ASSISTANT_PLAN §6 comes later).
        guard AssistantProfile.isDefault else {
            try? await sendText("Updates are installed for the whole computer from your default assistant — send /upgrade there.")
            return
        }
        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("⏳ A turn is running — send /upgrade again when Briglia is idle (or /stop first).")
            return
        }
        if CoordinationMode.active {
            await handleUpgradeCoordinated()
            return
        }
        // During a durability stall an earlier update in this very batch is
        // processed but unconfirmed — the upgrade handler's own
        // confirmProcessed(higher id) would implicitly confirm it, bypassing
        // the stall, and the exec-restart's downloads need a working disk
        // anyway. Refuse until writes recover.
        guard stalledConfirmUpdateId == nil else {
            try? await sendText("✖ Briglia can't persist state to disk right now (writes failing — check disk space); /upgrade is deferred until storage recovers.")
            return
        }
        guard !maintenanceActivities.contains(where: { $0.kind == .summarizingHistory }), archiveRecoveryTask == nil else {
            try? await sendText("⏳ Memory archiving is in flight — send /upgrade again in a minute.")
            return
        }
        // Blocks a new archive across the check/download awaits; every path
        // that returns without exec (up to date, refused, failed, …) resets it.
        // BGPRUNE{ A-UPG
        if backgroundPruneEngaged {
            if backgroundPruneBlocksExit {
                try? await sendText("⏳ A background prune is finishing — send /upgrade again in a minute, or /stop first.")
                return
            }
        }
        // }BGPRUNE
        archiveExitPending = true
        defer { archiveExitPending = false }
        var trustWarnings: [String] = []
        var checkedManifest: ReleaseSigning.Manifest? = nil
        let checkResult = await UpgradeService.check(warn: { trustWarnings.append($0) },
                                                     onManifest: { checkedManifest = $0 })
        for warning in trustWarnings {
            try? await sendText(warning)
        }
        // Display only (security plan v8 §5.6): security wording for an
        // available release; the lagging-GitHub line when this manifest is
        // lower than one the update notice already saw.
        if let note = Self.upgradeDisplayNote(manifest: checkedManifest, installed: adaCLIReleaseSequence,
                                              observed: Self.observedForUpgradeDisplay()) {
            try? await sendText(note)
        }
        switch checkResult {
        case .rollbackRefused(let live, let floor):
            try? await sendText("✖ The release channel serves signed metadata with sequence \(live), BELOW this install's trusted floor \(floor). This can be a stale mirror — or a rollback attack. Refusing; if it persists, check https://github.com/permaevidence/briglia-cli/releases directly.")
        case .failed(let reason):
            try? await sendText("✖ Update check failed: \(reason)")
        case .unsupportedPlatform:
            try? await sendText("✖ No prebuilt releases exist for this platform — update from source with git pull + install.sh.")
        case .noBuildForPlatform(let version, let platform):
            try? await sendText("✖ Release \(version) has no \(platform) build yet — try again later (ARM builds trail by ~1 hour).")
        case .manifestOlder(let current, let manifest):
            try? await sendText("⚠ The release feed currently serves \(manifest), which is older than the installed \(current) — a release is probably still publishing. Not downgrading; try again in a few minutes.")
        case .upToDate(let version):
            try? await sendText("✔ Already up to date (\(version)).")
        case .available(let update):
            guard UpgradeService.installDirWritable() else {
                try? await sendText("""
                ✖ Briglia is installed in \(UpgradeService.installDir.path), which needs sudo to replace — \
                and a remote upgrade can't answer a password prompt. Run `briglia upgrade` in a terminal instead.
                """)
                return
            }
            try? await sendText("⬇ Updating \(adaCLIVersion) → \(update.version)…")
            do {
                try await UpgradeService.downloadAndInstall(update, allowSudo: false) { _ in }
                UpgradeService.writeRestartMarker(version: update.version)
                saveConversation()
                try? await sendText("✅ \(update.version) installed — restarting now. I'll confirm when I'm back online.")
                // Terminal-path /upgrade: the captured reply lines are normally
                // printed after the handler returns, but this handler never
                // returns — flush them to the screen before the exec.
                if let capture = Self.commandCapture, !capture.lines.isEmpty {
                    for line in capture.lines { print("  " + line.replacingOccurrences(of: "\n", with: "\n  ")) }
                }
                stopPolling()
                // Confirm ONLY this /upgrade's own update before the exec —
                // the poll loop's per-update confirm never runs because this
                // handler doesn't return. Later updates fetched in the same
                // batch stay unconfirmed, so Telegram re-serves them to the
                // restarted process instead of skipping them forever.
                // (Terminal-typed /upgrade has no update id; just persist the
                // current confirmed state.)
                if let ownUpdateId = processingTelegramUpdateId {
                    await telegramService.confirmProcessed(updateId: ownUpdateId)
                } else {
                    await telegramService.persistOffsetNow()
                }
                UpgradeService.restartNow()
            } catch {
                try? await sendText("✖ Update failed: \(error.localizedDescription)")
            }
        }
    }

    /// `/upgrade` with several assistants (MULTI_ASSISTANT_PLAN §6): this
    /// assistant is the coordinator AND a participant — its monitor parks it
    /// under the same readiness rules as everyone (only this handler is not
    /// a turn). After the commit it confirms only its own update and execs.
    private func handleUpgradeCoordinated() async {
        guard stalledConfirmUpdateId == nil else {
            try? await sendText("✖ Briglia can't persist state to disk right now; /upgrade is deferred until storage recovers.")
            return
        }
        // S2-12: the coordinator runs as its own task, so this handler (and
        // the poll loop that called it) returns at once; /status, /stop and
        // /upgrade cancel keep answering while the others are asked to pause.
        guard upgradeCoordinatorTask == nil else {
            _ = await handleUpgradeSubcommand("")
            return
        }
        let lock: ProfileFileLock
        switch UpgradeCoordinator.acquire() {
        case .success(let l): lock = l
        case .failure(let why): try? await sendText("✖ \(why)"); return
        }
        let address = replyAddress
        upgradeCancelFlag.reset()
        upgradeWaitingFor = []
        upgradeCoordinatorTask = Task { @MainActor [weak self] in
            guard let self else { lock.release(); return }
            await self.runCoordinatedUpgrade(holding: lock, address: address)
            lock.release()
            self.upgradeCoordinatorTask = nil
            self.upgradeWaitingFor = []
            self.upgradeCancelFlag.reset()
        }
    }

    private func runCoordinatedUpgrade(holding lock: ProfileFileLock, address: ChannelAddress?) async {
        func say(_ text: String) async { try? await sendText(text, to: address) }
        let settings = coordinatorSettings(address: address)
        if let why = UpgradeCoordinator.settlePrevious(settings) { await say("✖ \(why)"); return }
        var checkedManifest: ReleaseSigning.Manifest?
        var warnings: [String] = []
        let result = await UpgradeService.check(warn: { warnings.append($0) }, onManifest: { checkedManifest = $0 })
        for w in warnings { await say(w) }
        if let note = Self.upgradeDisplayNote(manifest: checkedManifest, installed: adaCLIReleaseSequence,
                                              observed: Self.observedForUpgradeDisplay()) {
            await say(note)
        }
        let update: UpgradeService.Update
        switch result {
        case .available(let available): update = available
        case .upToDate(let version): await say("✔ Already up to date (\(version))."); return
        case .rollbackRefused(let live, let floor):
            await say("✖ The release channel serves signed metadata with sequence \(live), BELOW this install's trusted floor \(floor). Refusing."); return
        case .manifestOlder(let current, let manifest):
            await say("⚠ The release feed serves \(manifest), older than the installed \(current). Not downgrading; try again in a few minutes."); return
        case .unsupportedPlatform: await say("✖ No prebuilt releases exist for this platform."); return
        case .noBuildForPlatform(let version, let platform): await say("✖ Release \(version) has no \(platform) build yet."); return
        case .failed(let reason): await say("✖ Update check failed: \(reason)"); return
        }
        guard UpgradeService.installDirWritable() else {
            await say("✖ Briglia is installed in \(UpgradeService.installDir.path), which needs sudo to replace. Run `briglia upgrade` in a terminal instead.")
            return
        }
        await say("⬇ Updating \(adaCLIVersion) → \(update.version)… every assistant on this computer pauses at a quiet moment first (up to 10 minutes). /status shows who is still busy; /upgrade cancel stops waiting.")
        let staged: StagedUpgrade
        do { staged = try await UpgradeService.downloadAndStage(update) { _ in } } catch {
            await say("✖ Update failed: \(error.localizedDescription)"); return
        }
        defer { if let tmp = staged.tempDirectory { try? FileManager.default.removeItem(at: tmp) } }
        guard !upgradeCancelFlag.value else { await say("✖ Update cancelled; nothing was installed."); return }
        MemberEntry.isCoordinator = true
        defer { MemberEntry.isCoordinator = false }
        archiveExitPending = true
        defer { archiveExitPending = false }
        let outcome = await UpgradeCoordinator.run(staged: staged, settings: settings, holding: lock) { [weak self] barrier in
            guard let self else { return }
            UpgradeService.writeRestartMarker(version: barrier.targetVersion, kind: .upgrade,
                                              barrierId: barrier.id, oldLease: MemberEntry.current?.uuid)
            self.saveConversation()
            try? await self.sendText("✅ \(barrier.targetVersion) installed — restarting now. I'll confirm when I'm back online.", to: address)
            self.stopPolling()
            // Parked before publication: the last batch was processed and
            // confirmed, so persisting the offset is all that is left.
            await self.telegramService.persistOffsetNow()
            UpgradeService.restartNow()
        }
        switch outcome {
        case .committed: break
        case .cancelled(let why): await say("✖ Update cancelled: \(why)")
        case .refused(let why): await say("✖ \(why)")
        case .stuck(let why): await say("✖ \(why)\n\(UpgradeBarrier.stuckMessage)")
        }
    }

    /// Called once at startup when this process is the post-upgrade restart:
    /// close the loop the /upgrade command opened ("I'll confirm when I'm
    /// back"). Sent to Telegram when configured; the terminal already printed
    /// its own confirmation line.
    func announceUpgradeCompletion(version: String) async {
        try? await sendText("✅ Update \(version) installed — Briglia restarted and is back online.", to: telegramAddress)
    }

    /// Everything after the command token, e.g. "/model kimi-k3" -> "kimi-k3".
    private func commandArgument(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\n" }) else { return "" }
        return String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
