import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Sign in with ChatGPT in the running assistant (SIWC plan §3.4, §3.10,
// §5.1, D2, D23): the `/subscription` commands on the SIWC route, the paste
// interceptor (before any persistence), the plan-state notices this
// assistant owns, and the one-time invitation.

/// The destination identity of this process's pushes (bot fingerprint +
/// paired chat), read from any task by `SIWCPlanState.destination`.
enum SIWCNoticeDestination {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: String?
    static var current: String? { lock.lock(); defer { lock.unlock() }; return value }
    static func set(_ new: String?) { lock.lock(); value = new; lock.unlock() }

    static func identity(token: String?, chat: Int?) -> String? {
        guard let token, !token.isEmpty, let chat, chat > 0 else { return nil }
        let digest = SHA256.hash(data: Data(("briglia-siwc-destination:" + token).utf8)).map { String(format: "%02x", $0) }.joined()
        return String(digest.prefix(24)) + ":" + String(chat)
    }
}

extension ConversationManager {
    // MARK: /subscription on the SIWC route

    /// The SIWC part of `/subscription`. Returns the legacy action to run
    /// when the command is not for Sign in with ChatGPT (nil = handled).
    func handleSIWCSubscription(_ argument: String) async -> String? {
        let words = argument.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let verb = words.first ?? "status"
        let legacy = words.contains("legacy"), official = words.contains("official")
        let legacyAction = legacy ? verb : argument.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if legacy { return verb }
        let stored = KeychainHelper.loadSnapshot()
        let onRoute = SIWCSurface.route(stored) == "siwc"
        let optedIn = SIWCSurface.optedIn(stored)
        switch verb {
        case "method":
            try? await sendText("ChatGPT sign-in methods:\n• \(SIWCSurface.label): /subscription login official\n• \(SIWCSurface.legacyLabel): /subscription login legacy\nNeither changes anything until you sign in. After choosing Sign in with ChatGPT, don't install an older Briglia: an older version only knows the legacy sign-in and will switch to it if you change ChatGPT settings there.")
            return nil
        case "status" where optedIn || onRoute:
            var lines = SIWCSurface.statusLines(stored: stored, waiting: SIWCFlow.shared.isWaiting)
            let legacyState = (try? SubscriptionAuthStore().read()) ?? nil
            lines.append("\(SIWCSurface.legacyLabel): " + (legacyState?.requiresLogin == true ? "sign in again" : legacyState?.credential == nil ? "signed out" : "signed in"))
            lines.append("Use /subscription login|cancel|logout|use (add legacy for the legacy sign-in), /subscription method.")
            try? await sendText(lines.joined(separator: "\n"))
            return nil
        case "login" where official || optedIn:
            await startSIWCLogin()
            return nil
        case "cancel" where SIWCFlow.shared.isWaiting || official:
            let status = await SIWCFlow.shared.cancel()
            try? await sendText(status.message ?? "ChatGPT sign-in cancelled.")
            return nil
        case "failed" where SIWCFlow.shared.isWaiting:
            let status = await SIWCFlow.shared.cancel(browserFailed: true)
            try? await sendText(status.message ?? SIWCFlow.browserFailedHelp)
            return nil
        case "logout" where official || onRoute:
            guard idleForSIWCCommand(allowBusy: true) else { return nil }
            let r = await SIWCSurface.logout()
            try? await sendText(r.message)
            return nil
        case "use":
            switch await SIWCFlow.shared.activate(origin: "telegram") {
            case .success(let applied):
                try? await sendText(applied ? "Briglia now uses \(SIWCSurface.label)." : "Saved. Briglia is busy with a task, so it switches when the task finishes.")
            case .failure(let why): try? await sendText("Not switched: " + why)
            }
            return nil
        default:
            return legacyAction
        }
    }

    private func idleForSIWCCommand(allowBusy: Bool) -> Bool { allowBusy || (activeRunId == nil && activeProcessingTask == nil) }

    /// Telegram: paste-back link (no hints, previews off). The terminal chat
    /// on this computer: the browser link (the local listener catches it).
    func startSIWCLogin() async {
        guard let address = replyAddress else { return }
        guard !isRestoringMind else { try? await sendText("Wait until the memory operation finishes before signing in."); return }
        let telegram = address.kind == .telegram
        if telegram {
            guard let paired = pairedChatId, paired > 0, address.chatId == String(paired) else {
                try? await sendText("Use the paired private Telegram chat, or briglia menu on the computer."); return
            }
        }
        let status = await SIWCFlow.shared.start(mode: telegram ? .paste : .browser, onFinish: { [weak self] final in
            Task { @MainActor in await self?.reportSIWCFinish(final, to: address) }
        })
        guard status.state == "waiting", let url = status.url else {
            try? await sendText(status.message ?? "ChatGPT sign-in could not start."); return
        }
        _ = await SIWCSurface.setOptIn(true, origin: "telegram")
        if telegram, let chat = Int(address.chatId) {
            let text = "Sign in with ChatGPT here: \(url)\n\nAfter you approve, your browser shows a page that can't load. That's expected: copy that page's address and paste it here. \(SIWCFlow.pasteHint) The link expires in 10 minutes.\n\(SIWCFlow.telegramCaveat)\nIf ChatGPT shows an error instead, send /subscription failed."
            do { try await telegramService.sendMessageNoPreview(chatId: chat, text: text) } catch {
                _ = await SIWCFlow.shared.cancel()
                try? await sendText("The sign-in link couldn't be sent; nothing was started. Try again.")
            }
        } else {
            try? await sendText("Open this link in a browser on this computer to sign in with ChatGPT:\n\(url)\nIt expires in 10 minutes. /subscription cancel stops it; if ChatGPT shows an error, /subscription failed.")
        }
    }

    func reportSIWCFinish(_ final: SIWCFlow.Status, to address: ChannelAddress) async {
        var text = final.message ?? "ChatGPT sign-in finished."
        if final.firstUse, final.outcome == "signed_in" || final.outcome == "pending" { text += "\n\n" + SIWCFlow.firstUseNotice }
        if final.outcome == "plan_usage_off" { text += "\nTo allow it, send /subscription login official again and accept plan usage." }
        if final.legacyLoginKept, final.outcome == "signed_in" || final.outcome == "pending" {
            let others = SubscriptionSharing.sharingSentence(signOut: true).map { " " + $0 } ?? ""
            text += "\n\nYour legacy ChatGPT login is still saved on this computer. To remove it: /subscription logout legacy." + others
        }
        if final.outcome == "browser_error" || final.outcome == "browser_failed" || final.outcome == "expired" {
            text += "\nTo choose a different sign-in method: /subscription method."
        }
        try? await sendText(text, to: address)
    }

    // MARK: Paste interceptor (§3.4 inbound)

    /// Holds back anything that looks like a sign-in callback BEFORE it can
    /// reach history, memory, the mid-turn queue, logs or the model —
    /// whether or not a sign-in is waiting. Replies with a fixed text and
    /// deletes the pasted message where Telegram allows.
    func interceptSIWCPaste(_ text: String, chatId: Int, messageId: Int) async {
        let hadNotifier = SIWCFlow.shared.isWaiting
        let reply = await SIWCFlow.shared.paste(text)
        Task { [telegramService] in try? await telegramService.deleteMessage(chatId: chatId, messageId: messageId) }
        // A paste that finished a sign-in this chat started is reported by
        // that sign-in's own result message; anything else gets the reply.
        if hadNotifier, !SIWCFlow.shared.isWaiting, SIWCFlow.shared.lastFinishNotified { return }
        try? await telegramService.sendMessageNoPreview(chatId: chatId, text: reply)
    }

    // MARK: Plan-state notices (§5.1, D23) and the invitation (D2)

    func refreshSIWCDestination() {
        let token = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey)
        SIWCNoticeDestination.set(SIWCNoticeDestination.identity(token: token, chat: pairedChatId))
    }

    func startSIWCSurfaces() {
        refreshSIWCDestination()
        SIWCPlanState.destination = { SIWCNoticeDestination.current }
        SIWCPlanState.onNotice = { [weak self] in Task { @MainActor in await self?.deliverSIWCNotices() } }
        Task { @MainActor [weak self] in
            await self?.deliverSIWCNotices()
            await self?.sendSIWCInvitationIfDue()
        }
    }

    /// Deliver the notices THIS assistant owns (opener / recovery claimer),
    /// only to the destination they were queued for. At-least-once: marked
    /// delivered after the send.
    func deliverSIWCNotices() async {
        refreshSIWCDestination()
        guard !siwcNoticeDelivery else { return }
        siwcNoticeDelivery = true
        defer { siwcNoticeDelivery = false }
        let store = SIWCStore.resolved()
        let destination = SIWCNoticeDestination.current
        for notice in SIWCPlanState.pendingNotices(store, destination: destination) {
            guard SIWCPlanState.stillDue(store, notice), let chat = pairedChatId,
                  destination == SIWCNoticeDestination.current else { continue }
            var text = notice.text
            // The sign-in notice carries its own paste-back link (§5.1 item 4).
            if !notice.recovery, notice.state == .signInRequired, !SIWCFlow.shared.isWaiting {
                let status = await SIWCFlow.shared.start(mode: .paste, onFinish: { [weak self] final in
                    Task { @MainActor in
                        guard let self, let address = self.telegramAddress else { return }
                        await self.reportSIWCFinish(final, to: address)
                    }
                })
                if status.state == "waiting", let url = status.url {
                    text = SIWCPlanState.signInNotice + " Sign in again: \(url)\nPaste the address your browser ends on here. \(SIWCFlow.pasteHint)"
                }
            }
            do {
                try await telegramService.sendMessageNoPreview(chatId: chat, text: text)
                SIWCPlanState.markDelivered(store, notice)
            } catch {
                print("[SIWC] plan notice not delivered now; it stays queued")
            }
        }
    }

    func sendSIWCInvitationIfDue() async {
        let stored = KeychainHelper.loadSnapshot()
        guard let invite = SIWCSurface.invitation(stored), stored[SIWCSurface.invitedKey] != "1",
              let chat = pairedChatId, chat > 0 else { return }
        do {
            try await telegramService.sendMessage(chatId: chat, text: invite + " — send /subscription login to switch to \(SIWCSurface.label). Your current ChatGPT sign-in keeps working until you do.")
            await SIWCSurface.markInvited(origin: "telegram")
        } catch {}
    }
}
