import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Telegram managed bots (MULTI_ASSISTANT_PLAN §27 amendment A3, §28.4): the
/// default assistant's bot is the "manager"; `/newassistant <Name>` asks the
/// owner to create a new bot with one tap, Telegram then lets the manager
/// fetch that bot's token. Field and method names are the Bot API's
/// (verified against core.telegram.org on 2026-10-29, plan §28.1):
/// `getMe.can_manage_bots`, `KeyboardButton.request_managed_bot`
/// (`KeyboardButtonRequestManagedBot {request_id, suggested_name,
/// suggested_username}`), `Update.managed_bot` (`ManagedBotUpdated {user,
/// bot}`), `Message.managed_bot_created` (`ManagedBotCreated {bot}`),
/// `getManagedBotToken`, `replaceManagedBotToken`,
/// `getManagedBotAccessSettings`, `setManagedBotAccessSettings`.
///
/// Tokens: every function here takes a token as an argument and never puts
/// one into an error, a log line or a return value other than the two
/// token methods' own result.
enum ManagedBotAPI {
    struct APIError: Error, CustomStringConvertible, Equatable {
        let method: String
        let status: Int
        let detail: String
        var description: String { "Telegram \(method) failed (HTTP \(status)): \(detail)" }
        /// The request never got an answer (network): worth a retry.
        var isTransport: Bool { status == 0 }
    }

    /// The bot's identity as `getMe` reports it (`can_manage_bots` is only
    /// returned by getMe).
    struct BotInfo: Equatable {
        let id: Int64
        let username: String?
        let firstName: String
        let canManageBots: Bool
    }

    struct AccessSettings: Equatable {
        let restricted: Bool
        let addedUserIds: [Int64]
    }

    static var base: String {
        ProcessInfo.processInfo.environment["BRIGLIA_TELEGRAM_API_BASE"] ?? "https://api.telegram.org/bot"
    }

    /// One Bot API call (POST JSON). Returns `result`. The token is never
    /// part of a thrown error (descriptions are scrubbed).
    static func call(token: String, method: String, params: [String: Any] = [:], timeout: TimeInterval = 20) async throws -> Any {
        guard let url = URL(string: "\(base)\(token)/\(method)") else {
            throw APIError(method: method, status: 0, detail: "malformed token")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        let data: Data
        let response: URLResponse
        do {
            if let override = TelegramBotService.transportOverrideForTesting {
                (data, response) = try await override(request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError(method: method, status: 0, detail: scrub(error.localizedDescription, token: token))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, json?["ok"] as? Bool == true, let result = json?["result"] else {
            let description = (json?["description"] as? String) ?? "no answer"
            throw APIError(method: method, status: status == 0 ? -1 : status, detail: scrub(description, token: token))
        }
        return result
    }

    static func scrub(_ text: String, token: String) -> String {
        var out = text
        if !token.isEmpty { out = out.replacingOccurrences(of: token, with: "[REDACTED]") }
        return String(TelegramBotService.redactBotTokens(in: out).prefix(300))
    }

    static func getMe(token: String) async throws -> BotInfo {
        let result = try await call(token: token, method: "getMe", timeout: 15)
        guard let user = result as? [String: Any], let id = (user["id"] as? NSNumber)?.int64Value else {
            throw APIError(method: "getMe", status: 200, detail: "malformed answer")
        }
        return BotInfo(id: id, username: user["username"] as? String, firstName: user["first_name"] as? String ?? "",
                       canManageBots: user["can_manage_bots"] as? Bool == true)
    }

    static func getManagedBotToken(manager: String, botId: Int64) async throws -> String {
        let result = try await call(token: manager, method: "getManagedBotToken", params: ["user_id": botId])
        guard let token = result as? String, ManagedBots.looksLikeToken(token, botId: botId) else {
            throw APIError(method: "getManagedBotToken", status: 200, detail: "the answer was not a token for that bot")
        }
        return token
    }

    static func replaceManagedBotToken(manager: String, botId: Int64) async throws -> String {
        let result = try await call(token: manager, method: "replaceManagedBotToken", params: ["user_id": botId])
        guard let token = result as? String, ManagedBots.looksLikeToken(token, botId: botId) else {
            throw APIError(method: "replaceManagedBotToken", status: 200, detail: "the answer was not a token for that bot")
        }
        return token
    }

    static func setAccess(manager: String, botId: Int64, restricted: Bool, addedUserIds: [Int64] = []) async throws {
        var params: [String: Any] = ["user_id": botId, "is_access_restricted": restricted]
        if restricted, !addedUserIds.isEmpty { params["added_user_ids"] = addedUserIds }
        _ = try await call(token: manager, method: "setManagedBotAccessSettings", params: params)
    }

    static func getAccess(manager: String, botId: Int64) async throws -> AccessSettings {
        let result = try await call(token: manager, method: "getManagedBotAccessSettings", params: ["user_id": botId])
        guard let object = result as? [String: Any] else {
            throw APIError(method: "getManagedBotAccessSettings", status: 200, detail: "malformed answer")
        }
        let added = (object["added_users"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? NSNumber)?.int64Value }
        return AccessSettings(restricted: object["is_access_restricted"] as? Bool == true, addedUserIds: added)
    }

    /// sendMessage with an arbitrary `reply_markup` (a reply keyboard or its
    /// removal); returns the message id.
    @discardableResult
    static func sendMessage(token: String, chatId: Int64, text: String, replyMarkup: [String: Any]? = nil) async throws -> Int {
        var params: [String: Any] = ["chat_id": chatId, "text": text]
        if let replyMarkup { params["reply_markup"] = replyMarkup }
        let result = try await call(token: token, method: "sendMessage", params: params)
        return ((result as? [String: Any])?["message_id"] as? NSNumber)?.intValue ?? 0
    }

    /// The one-time reply keyboard with a single "create a bot" button.
    static func requestButtonMarkup(requestId: Int32, buttonText: String, suggestedName: String, suggestedUsername: String) -> [String: Any] {
        let request: [String: Any] = ["request_id": Int(requestId), "suggested_name": suggestedName,
                                      "suggested_username": suggestedUsername]
        return ["keyboard": [[["text": buttonText, "request_managed_bot": request] as [String: Any]]],
                "one_time_keyboard": true, "resize_keyboard": true]
    }

    static let removeKeyboardMarkup: [String: Any] = ["remove_keyboard": true]

    /// The `t.me/newbot` deep link (an alternative to the button).
    static func newBotLink(manager: String, suggestedUsername: String, suggestedName: String) -> String {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "t.me"
        c.path = "/newbot/\(manager)/\(suggestedUsername)"
        c.queryItems = [URLQueryItem(name: "name", value: suggestedName)]
        return c.url?.absoluteString ?? "https://t.me/newbot/\(manager)"
    }
}

/// The pending `/newassistant` request, the bots this manager created, and
/// the pure rules around them (§28.4, §28.6 S4-P2/P3). Files live in the
/// DEFAULT assistant's data root, `managed-bots/` (0700; files 0600, atomic).
/// They are assistant-creation bookkeeping like the registry: not deleted by
/// `/deleteuserdata`, not part of a Mind export/import. No token is ever
/// stored here.
enum ManagedBots {
    static let pendingTTL: TimeInterval = 15 * 60
    /// A request whose bot was already claimed may be retried this long.
    static let claimedTTL: TimeInterval = 24 * 3600

    enum Phase: String, Codable {
        /// The button was sent; waiting for the owner to create the bot.
        case waiting
        /// An unknown bot of the owner arrived whose username differs from
        /// the suggestion: the owner is asked to confirm it (inline buttons).
        case confirm
        /// The bot is bound to this request; the assistant is (being) created.
        case claimed
    }

    struct Pending: Codable, Equatable {
        var requestId: Int32
        var managerBotId: Int64
        var ownerId: Int64
        var name: String
        var profileId: String
        var suggestedUsername: String
        var createdAt: Date
        var phase: Phase
        var botId: Int64?
        var botUsername: String?
        /// The token could not be fetched (or the setup failed); `/newassistant
        /// retry` resumes.
        var failed: Bool?
    }

    struct KnownBot: Codable, Equatable {
        var profile: String
        var generation: String
        var managerBotId: Int64
    }

    struct Known: Codable, Equatable {
        var bots: [String: KnownBot] = [:]   // bot id → the assistant made for it
    }

    // MARK: Paths

    static func directory(dataRoot: URL = StoragePaths.dataRoot) -> URL {
        dataRoot.appendingPathComponent("managed-bots", isDirectory: true)
    }
    static func pendingURL(dataRoot: URL = StoragePaths.dataRoot) -> URL { directory(dataRoot: dataRoot).appendingPathComponent("pending.json") }
    static func knownURL(dataRoot: URL = StoragePaths.dataRoot) -> URL { directory(dataRoot: dataRoot).appendingPathComponent("known.json") }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    static func loadPending(dataRoot: URL = StoragePaths.dataRoot) -> Pending? {
        guard let data = FileManager.default.contents(atPath: pendingURL(dataRoot: dataRoot).path) else { return nil }
        return try? decoder().decode(Pending.self, from: data)
    }

    static func savePending(_ pending: Pending?, dataRoot: URL = StoragePaths.dataRoot) throws {
        let url = pendingURL(dataRoot: dataRoot)
        guard let pending else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try PrivateStorage.ensureDirectory(directory(dataRoot: dataRoot), mode: 0o700)
        try PrivateStorage.writeAtomically(try encoder().encode(pending), to: url, mode: 0o600)
    }

    static func loadKnown(dataRoot: URL = StoragePaths.dataRoot) -> Known {
        guard let data = FileManager.default.contents(atPath: knownURL(dataRoot: dataRoot).path),
              let known = try? decoder().decode(Known.self, from: data) else { return Known() }
        return known
    }

    static func saveKnown(_ known: Known, dataRoot: URL = StoragePaths.dataRoot) throws {
        try PrivateStorage.ensureDirectory(directory(dataRoot: dataRoot), mode: 0o700)
        try PrivateStorage.writeAtomically(try encoder().encode(known), to: knownURL(dataRoot: dataRoot), mode: 0o600)
    }

    /// Compare-and-write by request id: `change` runs only when the stored
    /// request is still `requestId` (a cancel or a newer /newassistant is
    /// never overwritten by an older task). Returns whether it applied.
    @discardableResult
    static func updatePending(requestId: Int32, dataRoot: URL = StoragePaths.dataRoot,
                              _ change: (inout Pending?) -> Void) throws -> Bool {
        guard var current = loadPending(dataRoot: dataRoot), current.requestId == requestId else { return false }
        var next: Pending? = current
        change(&next)
        if next == current { return true }
        current = next ?? current
        try savePending(next, dataRoot: dataRoot)
        return true
    }

    // MARK: Rotation intent (the managed assistant's own data root, §28.6 S4-P4)

    struct RotationIntent: Codable, Equatable {
        var botId: Int64
        var startedAt: Date
    }

    static func rotationURL(dataRoot: URL = StoragePaths.dataRoot) -> URL {
        directory(dataRoot: dataRoot).appendingPathComponent("rotation.json")
    }

    static func loadRotation(dataRoot: URL = StoragePaths.dataRoot) -> RotationIntent? {
        guard let data = FileManager.default.contents(atPath: rotationURL(dataRoot: dataRoot).path) else { return nil }
        return try? decoder().decode(RotationIntent.self, from: data)
    }

    static func saveRotation(_ intent: RotationIntent?, dataRoot: URL = StoragePaths.dataRoot) throws {
        let url = rotationURL(dataRoot: dataRoot)
        guard let intent else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try PrivateStorage.ensureDirectory(directory(dataRoot: dataRoot), mode: 0o700)
        try PrivateStorage.writeAtomically(try encoder().encode(intent), to: url, mode: 0o600)
    }

    // MARK: Pure rules

    /// `<digits>:<secret>` whose digits are this bot's id.
    static func looksLikeToken(_ token: String, botId: Int64) -> Bool {
        let parts = token.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == Substring(String(botId)), parts[1].count >= 20,
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return false }
        return true
    }

    /// The ASCII letters and digits of a name, lower-cased (accents folded).
    static func asciiWords(_ name: String) -> [String] {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var words: [String] = []
        var current = ""
        for ch in folded.unicodeScalars {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") { current.unicodeScalars.append(ch) }
            else if !current.isEmpty { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// A profile id from the assistant's name (§3.1 rules), unique against
    /// `taken`: "Health" → "health", "Lavoro & Casa" → "lavoro-casa",
    /// "日本" → "assistant", a clash gets "-2", "-3", …
    static func profileId(fromName name: String, taken: Set<String>) -> String {
        var base = asciiWords(name).joined(separator: "-")
        if base.isEmpty || !(base.first!.isLetter || base.first!.isNumber) { base = "assistant" }
        base = String(base.prefix(20))
        while base.hasSuffix("-") { base.removeLast() }
        let reserved = Set(["default", "all", "shared", "profiles"])
        var candidate = base
        var n = 2
        while taken.contains(candidate) || reserved.contains(candidate) || !AssistantProfile.isUsableExtraName(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// A suggested username for the new bot: letters/digits/underscore,
    /// 5–32 characters, ending in "bot" (the owner may change it in the
    /// Telegram dialog). `suffix` is random hex for uniqueness.
    static func suggestedUsername(name: String, suffix: String) -> String {
        var base = asciiWords(name).joined(separator: "_")
        if base.isEmpty { base = "assistant" }
        if base.first!.isNumber { base = "a" + base }
        let tail = "_\(suffix)_bot"
        base = String(base.prefix(32 - tail.count))
        while base.hasSuffix("_") { base.removeLast() }
        let out = base + tail
        return out
    }

    static func randomRequestId() -> Int32 { Int32.random(in: 1...Int32.max) }
    static func randomSuffix() -> String { String(format: "%04x", Int.random(in: 0...0xffff)) }

    /// A `managed_bot_created` service message in the owner's chat.
    struct Event: Equatable {
        let senderId: Int64?
        let botId: Int64
        let botUsername: String?
    }

    enum Decision: Equatable {
        /// Bind the bot to the request and create the assistant.
        case claim
        /// Ask the owner to confirm this bot for the request (inline buttons).
        case askConfirmation
        /// The request is already bound to this very bot (a re-delivery or the
        /// resumption of an interrupted creation).
        case resume
        case ignore(String)
    }

    static func isLive(_ p: Pending, now: Date) -> Bool {
        let age = now.timeIntervalSince(p.createdAt)
        return p.phase == .claimed ? age < claimedTTL : age < pendingTTL
    }

    /// §28.6 S4-P2: only from the paired owner; a bot already made into an
    /// assistant is never taken again; an exact match of the request's
    /// random suggested username is claimed directly, any other unknown bot
    /// of the owner needs the owner's confirmation.
    static func decide(_ event: Event, pending: Pending?, known: Known, ownerId: Int64?, managerBotId: Int64?, now: Date) -> Decision {
        guard let ownerId, event.senderId == ownerId else { return .ignore("not sent by the paired owner") }
        if known.bots[String(event.botId)] != nil { return .ignore("this bot is already an assistant") }
        guard let pending, pending.ownerId == ownerId, isLive(pending, now: now) else {
            return .ignore("no /newassistant request is pending")
        }
        if let managerBotId, pending.managerBotId != managerBotId { return .ignore("the request was made by a different bot") }
        switch pending.phase {
        case .claimed:
            return pending.botId == event.botId ? .resume : .ignore("the request is already being set up with another bot")
        case .confirm:
            return pending.botId == event.botId ? .askConfirmation : .askConfirmation
        case .waiting:
            if let u = event.botUsername, u.lowercased() == pending.suggestedUsername.lowercased() { return .claim }
            return .askConfirmation
        }
    }

    /// Callback data of the confirmation buttons (≤ 64 bytes):
    /// `mb:y:<requestId>:<botId>` / `mb:n:<requestId>:<botId>`.
    static func confirmData(yes: Bool, requestId: Int32, botId: Int64) -> String { "mb:\(yes ? "y" : "n"):\(requestId):\(botId)" }

    static func parseConfirm(_ data: String) -> (yes: Bool, requestId: Int32, botId: Int64)? {
        let parts = data.split(separator: ":").map(String.init)
        guard parts.count == 4, parts[0] == "mb", parts[1] == "y" || parts[1] == "n",
              let r = Int32(parts[2]), let b = Int64(parts[3]) else { return nil }
        return (parts[1] == "y", r, b)
    }

    static let reservedNames: Set<String> = ["cancel", "annulla", "retry", "riprova", "confirm"]

    /// Pending text (`/status`) and the user-facing name of the bot.
    static func handle(_ username: String?) -> String { username.map { "@\($0)" } ?? "the new bot" }
}
