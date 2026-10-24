import Foundation

/// Which backend supplies ambient email + calendar context (system-prompt
/// blocks, the 5-minute unread poller, and the calendar surface).
///
/// - `none`      — no email/calendar at all: no prompt sections, no polling,
///                 no calendar tool. The default for fresh installs.
/// - `agentmail` — a dedicated agent inbox on AgentMail (api.agentmail.to,
///                 key in secrets.json) plus Briglia's local calendar store with
///                 the `manage_calendar` tool. The recommended easy path.
///
/// The former `gws` provider (the user's Gmail through Google's `gws` CLI) was
/// removed on 2026-10-24 (owner decision, attack surface). A stored "gws" —
/// or any value this build does not know — reads as `none` everywhere;
/// `RetiredIntegrations` rewrites it durably and tells the user once.
enum EmailCalendarProvider: String, CaseIterable {
    case none
    case agentmail

    /// Test seam: when set, `current` uses the returned raw value (nil =
    /// simulate "no stored choice") instead of reading secrets.json. Selftests
    /// set and clear this; production never does.
    nonisolated(unsafe) static var storedOverrideForTesting: (() -> String?)?

    /// Single source of truth for the active provider. Every reader — the
    /// startup poller wiring, the frozen-context builders, the calendar tool
    /// gate, the system-prompt guidance bullet, the email-arrival envelope,
    /// the wizard, and doctor — must go through this so they can never
    /// disagree.
    ///
    /// Resolution: a valid stored choice wins; anything else (unset, the
    /// retired "gws", garbage) is `none`.
    static var current: EmailCalendarProvider {
        let stored: String?
        if let override = storedOverrideForTesting {
            stored = override()
        } else {
            stored = KeychainHelper.load(key: KeychainHelper.emailCalendarProviderKey)
        }
        return stored.flatMap(EmailCalendarProvider.init(rawValue:)) ?? .none
    }

    var displayName: String {
        switch self {
        case .none: return "none"
        case .agentmail: return "AgentMail + local calendar"
        }
    }

    /// The agent's dedicated inbox address (stored at wizard time from the
    /// live key probe). Empty when unknown — prompt text degrades gracefully.
    static var agentMailInboxAddress: String {
        KeychainHelper.load(key: KeychainHelper.agentMailInboxAddressKey) ?? ""
    }

    /// The "Tool-use guidance" bullet for the system prompt. Nil = omit the
    /// line entirely (provider none — never tell the model to use a CLI that
    /// isn't configured).
    var toolGuidanceBullet: String? {
        switch self {
        case .none:
            return nil
        case .agentmail:
            let inbox = Self.agentMailInboxAddress
            let inboxNote = inbox.isEmpty ? "" : " (\(inbox))"
            let msgs = AgentMailService.messagesResource
            return "- You have a dedicated email inbox\(inboxNote) on AgentMail. Use the `agentmail` CLI via `bash` for email actions — it authenticates itself automatically (e.g. `agentmail \(msgs) list --inbox-id \(inbox.isEmpty ? "<inbox>" : inbox) --limit 10`, `… get --message-id '<id>'`, `… reply`, `… send`; `agentmail --help` lists the rest). For raw API calls, `briglia __agentmail-key` prints the key. Use `manage_calendar` for the calendar."
        }
    }

    /// Follow-up hint inside the [SYSTEM: NEW EMAILS ARRIVED] envelope.
    /// Rendered at message-creation time by the provider that produced the
    /// poll, so it always names a CLI the model actually has.
    var emailFollowUpHint: String {
        switch self {
        case .none:
            return ""  // provider none never polls, so this never renders
        case .agentmail:
            let inbox = Self.agentMailInboxAddress
            let inboxArg = inbox.isEmpty ? "<inbox>" : inbox
            let msgs = AgentMailService.messagesResource
            return "Use the `agentmail` CLI via `bash` for follow-up actions when needed (e.g. `agentmail \(msgs) get --inbox-id \(inboxArg) --message-id '<id>'`, `… reply --inbox-id \(inboxArg) --message-id '<id>' --text \"…\"`)."
        }
    }
}

/// Email-credential wipe for /deleteuserdata (user decision, 2026-08-22): a
/// handoff wipe must sever email ACCESS, not just local memory. Deletes the
/// AgentMail key + inbox address and any leftover copy of the retired gws
/// OAuth client id/secret in secrets.json, then resets the provider to an
/// explicit "none". Since gws was removed (2026-10-24) Briglia never runs gws
/// and never touches ~/.config/gws or the gws binary — they may be the
/// user's own; the /deleteuserdata warning tells the user how to sign gws out
/// when that directory exists. Server-side mailboxes are deliberately
/// untouched: deleting the key severs Briglia's access, and remote mail
/// belongs to the account owner.
enum EmailCredentialWipe {
    /// Returns wipe failures in the same format deleteAllMemory reports.
    static func execute() -> [String] {
        var failures: [String] = []
        func deleteSecret(_ key: String, _ label: String) {
            do { try KeychainHelper.delete(key: key) }
            catch { failures.append("\(label): \(error.localizedDescription)") }
        }
        deleteSecret(KeychainHelper.agentMailApiKeyKey, "AgentMail API key")
        deleteSecret(KeychainHelper.agentMailInboxAddressKey, "AgentMail inbox address")
        deleteSecret(KeychainHelper.retiredGwsOAuthClientIDKey, "retired gws OAuth client id")
        deleteSecret(KeychainHelper.retiredGwsOAuthClientSecretKey, "retired gws OAuth client secret")
        do {
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey,
                                    value: EmailCalendarProvider.none.rawValue)
        } catch {
            failures.append("email provider reset: \(error.localizedDescription)")
        }
        return failures
    }
}
