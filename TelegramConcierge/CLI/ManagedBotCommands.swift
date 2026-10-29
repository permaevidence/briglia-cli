import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden: the default assistant's side of a managed-bot token rotation
/// (MULTI_ASSISTANT_PLAN §28.6 S4-P4). Run by the assistant whose bot it is
/// as `briglia --profile default __managed-bot replace-token|current-token
/// --bot <id> --for <profile>`. Default's own process reads its own manager
/// token and refuses a bot it did not create for that assistant (same
/// profile, same registry generation, same bot reserved, same manager bot).
/// stdout carries exactly one JSON line: `{"token": …}` or `{"code": …}`.
struct ManagedBotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__managed-bot",
        abstract: "Internal: managed-bot token for an assistant made with /newassistant.",
        shouldDisplay: false
    )

    @Argument var action: String
    @Option(name: .customLong("bot")) var bot: Int64
    @Option(name: .customLong("for")) var profile: String

    func run() async throws {
        // Nothing but the JSON line on stdout.
        fflush(stdout)
        let realStdout = dup(1)
        dup2(2, 1)
        func respond(_ object: [String: Any], _ code: Int32) -> Never {
            var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            data.append(0x0a)
            _ = data.withUnsafeBytes { write(realStdout, $0.baseAddress, $0.count) }
            Foundation.exit(code)
        }
        guard AssistantProfile.isDefault, ["replace-token", "current-token"].contains(action),
              AssistantProfile.isUsableExtraName(profile) else { respond(["code": "usage"], 2) }
        let manager = (KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let managerId = AssistantRegistry.normalize(.bot, manager).flatMap(Int64.init) else { respond(["code": "no_manager"], 1) }
        switch ManagedBotGrant.check(botId: bot, profile: profile, managerBotId: managerId) {
        case .refused(let code): respond(["code": code], 1)
        case .allowed: break
        }
        do {
            let token = action == "replace-token"
                ? try await ManagedBotAPI.replaceManagedBotToken(manager: manager, botId: bot)
                : try await ManagedBotAPI.getManagedBotToken(manager: manager, botId: bot)
            respond(["token": token], 0)
        } catch {
            respond(["code": "telegram"], 1)
        }
    }
}

/// Which assistant may ask default for a managed bot's token.
enum ManagedBotGrant {
    enum Result: Equatable { case allowed, refused(String) }

    static func check(botId: Int64, profile: String, managerBotId: Int64,
                      known: ManagedBots.Known = ManagedBots.loadKnown(),
                      registryPaths: AssistantRegistry.Paths = .live) -> Result {
        guard let entry = known.bots[String(botId)], entry.profile == profile else { return .refused("not_known") }
        guard entry.managerBotId == managerBotId else { return .refused("manager_changed") }
        guard let record = (try? AssistantRegistry.read(registryPaths))??.record(profile), record.state == "active",
              record.generation == entry.generation,
              record.bot.current == AssistantRegistry.digest(.bot, "\(botId):x") else { return .refused("not_known") }
        return .allowed
    }
}

/// Hidden step-0 probe (MULTI_ASSISTANT_PLAN §27, §28.4): drives the managed
/// bot handoff end to end against a THROWAWAY manager bot whose token is read
/// from stdin. It touches no Briglia state (no roots, no secrets, no
/// registry): only Telegram, with that token. Prints a JSON report without
/// any token. Never use it with a bot a running Briglia polls.
struct ManagedBotProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__managed-bot-probe",
        abstract: "Internal: live check of Telegram managed bots with a throwaway manager bot.",
        shouldDisplay: false
    )

    @Option(name: .customLong("wait-minutes")) var waitMinutes: Double = 10

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let manager = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard AssistantRegistry.normalize(.bot, manager) != nil else {
            print("✖ give the throwaway manager bot's token on stdin"); throw ExitCode(2)
        }
        var report: [String: Any] = [:]
        func say(_ s: String) { print("· \(s)") }
        func finish() -> Never {
            let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])) ?? Data()
            print(String(decoding: data, as: UTF8.self))
            Foundation.exit(0)
        }
        func scrub(_ e: Error, _ tokens: [String]) -> String {
            var t = "\(e)"
            for k in tokens where !k.isEmpty { t = t.replacingOccurrences(of: k, with: "[REDACTED]") }
            return TelegramBotService.redactBotTokens(in: t)
        }
        // 1. The manager.
        let me: ManagedBotAPI.BotInfo
        do { me = try await ManagedBotAPI.getMe(token: manager) } catch {
            report["manager_getMe"] = scrub(error, [manager]); finish()
        }
        report["manager_username"] = me.username ?? ""
        report["can_manage_bots"] = me.canManageBots
        guard me.canManageBots else { say("bot management is OFF for @\(me.username ?? "?")"); finish() }
        // 2. The owner: the first private message to the manager.
        say("open @\(me.username ?? "?") in Telegram and send it any message (e.g. /start)")
        var offset = 0
        func poll(_ allowed: [String]) async throws -> [[String: Any]] {
            let result = try await ManagedBotAPI.call(token: manager, method: "getUpdates",
                                                      params: ["offset": offset, "timeout": 20, "allowed_updates": allowed], timeout: 30)
            let updates = result as? [[String: Any]] ?? []
            for u in updates { if let id = (u["update_id"] as? NSNumber)?.intValue { offset = max(offset, id + 1) } }
            return updates
        }
        let deadline = Date().addingTimeInterval(waitMinutes * 60)
        var owner: Int64?
        while owner == nil, Date() < deadline {
            for u in (try? await poll(["message"])) ?? [] {
                if let m = u["message"] as? [String: Any], let chat = m["chat"] as? [String: Any], chat["type"] as? String == "private",
                   let id = (chat["id"] as? NSNumber)?.int64Value { owner = id }
            }
        }
        guard let owner else { report["owner"] = "no message arrived"; finish() }
        // 3. The button.
        let suffix = ManagedBots.randomSuffix()
        let suggested = ManagedBots.suggestedUsername(name: "Briglia probe", suffix: suffix)
        do {
            try await ManagedBotAPI.sendMessage(token: manager, chatId: owner,
                text: "Briglia step 0: tap the button and confirm to create a throwaway bot (delete it in @BotFather afterwards).",
                replyMarkup: ManagedBotAPI.requestButtonMarkup(requestId: ManagedBots.randomRequestId(), buttonText: "➕ Create probe bot",
                                                                suggestedName: "Briglia probe", suggestedUsername: suggested))
            report["button_sent"] = true
        } catch { report["button_sent"] = scrub(error, [manager]); finish() }
        report["suggested_username"] = suggested
        say("tap the button in that chat and confirm")
        // 4. The event, polled with EXACTLY the production subscription
        // (["message", "callback_query"]; Codex stage-4 round 4): Briglia relies
        // on the managed_bot_created service message, never on the separate
        // managed_bot update, so this proves what production will receive.
        var botId: Int64?
        var botUsername: String?
        var sawMessage = false
        var sawUpdate = false
        var messageSender: Int64?
        let updateCreator: Int64? = nil
        while Date() < deadline, !sawMessage {
            for u in (try? await poll(["message", "callback_query"])) ?? [] {
                if let m = u["message"] as? [String: Any], let created = m["managed_bot_created"] as? [String: Any],
                   let bot = created["bot"] as? [String: Any] {
                    sawMessage = true
                    botId = (bot["id"] as? NSNumber)?.int64Value
                    botUsername = bot["username"] as? String
                    messageSender = ((m["from"] as? [String: Any])?["id"] as? NSNumber)?.int64Value
                }
                if u["managed_bot"] != nil { sawUpdate = true }   // must not arrive with this subscription
            }
        }
        report["event_message_managed_bot_created"] = sawMessage
        report["managed_bot_update_leaked_through_production_filter"] = sawUpdate
        report["message_sender_is_owner"] = messageSender == owner
        report["update_creator_is_owner"] = updateCreator.map { $0 == owner } ?? false
        report["created_username_equals_suggestion"] = botUsername?.lowercased() == suggested.lowercased()
        guard let botId else { report["created"] = "no event arrived"; finish() }
        report["created_username"] = botUsername ?? ""
        // 5. Token, access, first message, rotation.
        var token1 = "", token2 = ""
        do { token1 = try await ManagedBotAPI.getManagedBotToken(manager: manager, botId: botId); report["getManagedBotToken"] = true }
        catch { report["getManagedBotToken"] = scrub(error, [manager]); finish() }
        report["new_bot_getMe"] = (try? await ManagedBotAPI.getMe(token: token1)) != nil
        do {
            try await ManagedBotAPI.setAccess(manager: manager, botId: botId, restricted: true)
            let access = try await ManagedBotAPI.getAccess(manager: manager, botId: botId)
            report["access_restricted"] = access.restricted
        } catch { report["access_restricted"] = scrub(error, [manager, token1]) }
        do {
            try await ManagedBotAPI.sendMessage(token: token1, chatId: owner, text: "Hi — I'm the probe bot (step 0). The new bot CAN message you first.")
            report["new_bot_can_message_owner_first"] = true
        } catch { report["new_bot_can_message_owner_first"] = scrub(error, [manager, token1]) }
        do { token2 = try await ManagedBotAPI.replaceManagedBotToken(manager: manager, botId: botId); report["replaceManagedBotToken"] = token2 != token1 }
        catch { report["replaceManagedBotToken"] = scrub(error, [manager, token1]) }
        if !token2.isEmpty {
            report["old_token_rejected"] = (try? await ManagedBotAPI.getMe(token: token1)) == nil
            report["new_token_works"] = (try? await ManagedBotAPI.getMe(token: token2)) != nil
            report["getManagedBotToken_after_replace_is_new"] = (try? await ManagedBotAPI.getManagedBotToken(manager: manager, botId: botId)) == token2
        }
        _ = try? await ManagedBotAPI.sendMessage(token: manager, chatId: owner,
            text: "Step 0 finished. You can delete @\(botUsername ?? "the probe bot") and this manager bot in @BotFather.",
            replyMarkup: ManagedBotAPI.removeKeyboardMarkup)
        finish()
    }
}
