import Foundation

/// Pure decision + parsing logic for the two-step `/switchbot` command, kept
/// separate from ConversationManager so the selftest can pin the whole matrix
/// without a manager or a network.
///
/// Contract (settled with the owner 2026-08-22, for handing a machine's Briglia to a
/// new owner or replacing a broken bot): the user supplies ONLY the new bot's
/// token — never a chat id, the error-prone half. Briglia answers with a one-time
/// code; whoever will own the new bot sends that code TO the new bot, and Briglia
/// discovers the chat id from that message. This proves in one step that the
/// token works, the chat id is real, and the person controlling the new chat
/// is the person the current owner intends. Nothing is written until
/// `/switchbot confirm`; the old bot keeps working up to that moment, so a
/// crash mid-flow always leaves a reachable Briglia.
enum BotSwitchFlow {
    /// How long discovery waits for the code before auto-cancelling.
    static let discoveryTimeoutSeconds: TimeInterval = 600
    /// A discovered but unconfirmed switch expires after this (it holds the
    /// new bot's reservation; MULTI_ASSISTANT_PLAN §5.6).
    static let confirmTimeoutSeconds: TimeInterval = 1800

    enum Action: Equatable {
        /// Bare command, nothing pending: explain the flow.
        case instructions
        /// Bare command with a switch in progress: show where it stands.
        case status
        /// "cancel": abort any pending switch.
        case cancel
        /// "confirm" before the code arrived: nothing to cut over yet.
        case confirmNotReady
        /// "confirm" with a discovered chat: perform the cutover.
        case cutover
        /// A well-formed token: (re)start the flow with it. `discardBacklog`
        /// is the explicit "<token> discard" go-ahead for a bot that already
        /// has queued updates (discovery consumes them permanently).
        case beginSwitch(token: String, discardBacklog: Bool)
        /// An argument that is neither a keyword nor a plausible token.
        case invalidToken
        /// The committed cutover is executing (credentials written or being
        /// written): EVERY command variant is refused until it finishes.
        case finalizing
    }

    /// `cutoverInProgress` wins over everything: ConversationManager is a
    /// reentrant @MainActor, so a terminal/app or other-channel command can
    /// interleave with the cutover's post-commit awaits (farewell send,
    /// channel re-registration). A cancel accepted in that window would
    /// report "current bot is unchanged" while the resumed cutover switches
    /// anyway, and a new token would be silently erased when it completes
    /// (Codex, 2026-08-22).
    static func decide(argument: String, hasPending: Bool, hasDiscovered: Bool,
                       cutoverInProgress: Bool) -> Action {
        if cutoverInProgress { return .finalizing }
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return hasPending ? .status : .instructions }
        switch trimmed.lowercased() {
        case "cancel": return .cancel
        case "confirm": return hasDiscovered ? .cutover : .confirmNotReady
        default:
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let first = parts.first, let token = validTokenFormat(first) else {
                return .invalidToken
            }
            if parts.count == 1 { return .beginSwitch(token: token, discardBacklog: false) }
            if parts.count == 2, parts[1].lowercased() == "discard" {
                return .beginSwitch(token: token, discardBacklog: true)
            }
            return .invalidToken
        }
    }

    /// A Telegram bot token is `<bot id>:<secret>` — digits, a colon, then a
    /// 30+ char base64url-ish secret. Deliberately loose on lengths (Telegram
    /// doesn't document them) but strict on shape, so "confirm" typos and
    /// pasted chat ids can never be mistaken for a token.
    static func validTokenFormat(_ raw: String) -> String? {
        let pattern = #"^[0-9]{5,15}:[A-Za-z0-9_-]{30,80}$"#
        guard raw.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return raw
    }

    /// One-time confirmation code: 6 digits, phone-keyboard friendly. The RNG
    /// is injected so the selftest can pin determinism and format. Plain
    /// modulo on the raw draw — the ~5e-14 modulo bias is irrelevant for a
    /// one-shot code, and unlike Int.random(in:using:) it cannot spin on a
    /// degenerate test RNG (Lemire rejection loops on a constant generator).
    static func generateCode<R: RandomNumberGenerator>(using rng: inout R) -> String {
        String(format: "%06d", Int(rng.next() % 1_000_000))
    }

    static func generateCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return generateCode(using: &rng)
    }

    // MARK: - getUpdates parsing (discovery poll)

    /// One inbound message seen while polling the NEW bot for the code.
    struct SeenMessage: Equatable {
        let updateId: Int
        let chatId: Int
        let isPrivateChat: Bool
        let fromIsBot: Bool
        let text: String
        let senderDisplay: String
    }

    struct ParsedUpdates: Equatable {
        let messages: [SeenMessage]
        /// Highest update_id in the batch (messages or not) — the next poll's
        /// offset is this + 1, which also confirms the batch server-side.
        let maxUpdateId: Int?
    }

    /// Tolerant JSONSerialization-based parse of a raw getUpdates response.
    /// Deliberately NOT the Codable models: a single unexpected update shape
    /// must never wedge discovery, and only four fields matter here.
    static func parseGetUpdates(_ data: Data) -> ParsedUpdates {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["ok"] as? Bool == true,
              let updates = root["result"] as? [[String: Any]] else {
            return ParsedUpdates(messages: [], maxUpdateId: nil)
        }
        var messages: [SeenMessage] = []
        var maxId: Int? = nil
        for update in updates {
            guard let updateId = update["update_id"] as? Int else { continue }
            maxId = max(maxId ?? updateId, updateId)
            guard let message = update["message"] as? [String: Any],
                  let chat = message["chat"] as? [String: Any],
                  let chatId = anyToInt(chat["id"]) else { continue }
            let from = message["from"] as? [String: Any]
            let firstName = from?["first_name"] as? String ?? ""
            let lastName = from?["last_name"] as? String ?? ""
            let username = from?["username"] as? String
            var display = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
            if let username, !username.isEmpty {
                display = display.isEmpty ? "@\(username)" : "\(display) (@\(username))"
            }
            if display.isEmpty { display = "chat \(chatId)" }
            messages.append(SeenMessage(
                updateId: updateId,
                chatId: chatId,
                isPrivateChat: (chat["type"] as? String) == "private",
                fromIsBot: from?["is_bot"] as? Bool ?? false,
                text: message["text"] as? String ?? "",
                senderDisplay: display
            ))
        }
        return ParsedUpdates(messages: messages, maxUpdateId: maxId)
    }

    /// Discovery-poll outcome for one getUpdates round.
    enum PollOutcome: Equatable {
        case updates(ParsedUpdates)
        /// The flow cannot proceed with this token (revoked token, bot
        /// blocked, another consumer owns getUpdates): stop and report.
        case permanentError(String)
        /// Worth retrying after a pause (rate limit, 5xx, undecodable body).
        case transientError(String)
    }

    /// Telegram signals errors both via HTTP status AND ok:false bodies; the
    /// discovery loop must distinguish "empty batch" from "error", or a
    /// webhook conflict / revoked token turns into a ten-minute tight loop
    /// of instant-returning failed requests (Codex, 2026-08-22).
    static func classifyGetUpdates(httpStatus: Int, data: Data) -> PollOutcome {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ok = root["ok"] as? Bool else {
            return .transientError("HTTP \(httpStatus)")
        }
        if ok { return .updates(parseGetUpdates(data)) }
        let code = anyToInt(root["error_code"]) ?? httpStatus
        let description = root["description"] as? String ?? "error \(code)"
        // 401/404 revoked or mistyped token, 403 bot deactivated/blocked,
        // 409 another consumer (webhook or second poller) owns this bot —
        // none of these heal within the discovery window.
        if [401, 403, 404, 409].contains(code) {
            return .permanentError(description)
        }
        return .transientError(description)
    }

    struct WebhookInfo: Equatable {
        let url: String
        let pendingUpdateCount: Int
    }

    /// Parse getWebhookInfo. Nil when the response is not a well-formed
    /// success — callers treat that as "could not check" and rely on the
    /// discovery loop's error classification instead.
    static func parseWebhookInfo(_ data: Data) -> WebhookInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["ok"] as? Bool == true,
              let result = root["result"] as? [String: Any] else { return nil }
        return WebhookInfo(
            url: result["url"] as? String ?? "",
            pendingUpdateCount: anyToInt(result["pending_update_count"]) ?? 0
        )
    }

    /// The chat that proved the code. Only a human in a PRIVATE chat counts:
    /// a group would hand Briglia's replies to everyone in it, and a bot sender
    /// can't be the new owner.
    struct DiscoveredChat: Equatable {
        let chatId: Int
        let senderDisplay: String
    }

    /// First private-chat human message whose text contains the code (exact
    /// digit run — whitespace around it tolerated, `123456!` also matches so
    /// an enthusiastic sender isn't refused).
    static func findCode(_ code: String, in messages: [SeenMessage]) -> DiscoveredChat? {
        for message in messages
        where message.isPrivateChat && !message.fromIsBot && message.text.contains(code) {
            return DiscoveredChat(chatId: message.chatId, senderDisplay: message.senderDisplay)
        }
        return nil
    }

    private static func anyToInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let numberValue = value as? NSNumber { return numberValue.intValue }
        return nil
    }
}
