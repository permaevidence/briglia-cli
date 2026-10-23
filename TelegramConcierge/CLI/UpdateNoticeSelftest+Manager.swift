import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// Round-1 deviation 14: the ConversationManager glue — destination choice
/// and the per-channel one-attempt send — on a real manager (private scratch
/// roots), not injected closures. The notice never enters history.
extension UpdateNoticeSelftest {
    final class FakeChannel: ChatChannel, @unchecked Sendable {
        let kind: ChannelKind
        var sent: [(String, String)] = []
        var fail = false
        init(_ kind: ChannelKind) { self.kind = kind }
        func sendText(chatId: String, text: String) async throws {
            sent.append((chatId, text))
            if fail { throw URLError(.timedOut) }
        }
        func sendPhoto(chatId: String, imageData: Data, caption: String?, mimeType: String) async throws {}
        func sendDocument(chatId: String, documentData: Data, filename: String, caption: String?, mimeType: String) async throws {}
    }

    static func record(_ d: UpdateNotice.Destination, text: String = "Briglia 0.3.131 is available. Send /upgrade to install.") -> AttemptRecord {
        AttemptRecord(kind: .release, sequence: 131, classIds: [], domain: dom, observedContentId: "c", installedBaseline: 130,
                      noticeGeneration: 0, channelKind: d.channelKind, chatId: d.chatId, channelGeneration: d.channelGeneration,
                      text: text, attempt: 1, firstAttemptAt: t0, deadline: t0.addingTimeInterval(hour), state: .inFlight, retryAfter: nil)
    }

    @MainActor
    static func managerGroup(_ t: Tally) async {
        let manager = ConversationManager()
        let historyBefore = manager.messages.count
        await managerTelegram(t, manager)
        await managerWhatsApp(t, manager)
        await managerLocal(t, manager)
        t.check("manager: no notice text ever entered conversation history",
                manager.messages.count == historyBefore && !manager.messages.contains { $0.content.contains("is available. Send /upgrade") })
        manager._svUnregisterChannel(.telegram)
        manager._svUnregisterChannel(.whatsapp)
        manager._svSetLastUserAddress(nil)
        TelegramBotService.transportOverrideForTesting = nil
    }

    @MainActor
    static func managerTelegram(_ t: Tally, _ manager: ConversationManager) async {
        let counter = Counter()
        final class Body: @unchecked Sendable { var text = "" }
        let body = Body()
        TelegramBotService.transportOverrideForTesting = { request in
            counter.n += 1
            body.text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return http(200, "{\"ok\":true,\"result\":{}}")
        }
        await manager.telegramService.configure(token: "123456:TEST_TOKEN_SHAPE_ONLY_abcdefghijklmnop")
        manager._svRegisterChannel(manager.telegramService)
        manager.pairedChatId = 4242
        manager._svSetLastUserAddress(nil)
        let d = manager.updateNoticeDestination()
        t.check("manager: no recent channel → the paired Telegram chat", d.channelKind == "telegram" && d.chatId == "4242")
        let outcome = await manager.sendUpdateNoticeOnce(record(d))
        t.check("manager: Telegram send = one request to the paired chat, accepted",
                outcome == .accepted && counter.n == 1 && body.text.contains("4242") && body.text.contains("0.3.131"))
        let stale = record(d)
        NoticeChannelGenerations.bump(.telegram)   // /switchbot between consume and send
        let dropped = await manager.sendUpdateNoticeOnce(stale)
        t.check("manager: channel generation changed after consume → dropped, nothing sent", dropped == .dropped && counter.n == 1)
        TelegramBotService.transportOverrideForTesting = { _ in counter.n += 1; return http(502, "{\"ok\":false}") }
        let five = await manager.sendUpdateNoticeOnce(record(manager.updateNoticeDestination()))
        t.check("manager: Telegram 5xx → ambiguous after exactly one request", five == .ambiguous && counter.n == 2)
        manager.pairedChatId = nil
    }

    @MainActor
    static func managerWhatsApp(_ t: Tally, _ manager: ConversationManager) async {
        let wa = FakeChannel(.whatsapp)
        manager._svRegisterChannel(wa)
        manager._svSetLastUserAddress(ChannelAddress(kind: .whatsapp, chatId: "393330000000@s.whatsapp.net"))
        let d = manager.updateNoticeDestination()
        t.check("manager: the user's last channel (WhatsApp) is the destination", d.channelKind == "whatsapp")
        let ok = await manager.sendUpdateNoticeOnce(record(d))
        t.check("manager: WhatsApp = one bridge call, accepted", ok == .accepted && wa.sent.count == 1)
        wa.fail = true
        let failed = await manager.sendUpdateNoticeOnce(record(d))
        t.check("manager: WhatsApp error → ambiguous, one call, no retry", failed == .ambiguous && wa.sent.count == 2)
    }

    @MainActor
    static func managerLocal(_ t: Tally, _ manager: ConversationManager) async {
        var emitted: [String] = []
        let sink = manager.stopNoticeEvents.sink { emitted.append($0) }
        manager._svSetLastUserAddress(ChannelAddress(kind: .app, chatId: "local"))
        let d = manager.updateNoticeDestination()
        let app = await manager.sendUpdateNoticeOnce(record(d, text: "app notice"))
        t.check("manager: app channel → a local emit (no wire), accepted", d.channelKind == "app" && app == .accepted && emitted == ["app notice"])
        manager._svUnregisterChannel(.whatsapp)
        manager._svUnregisterChannel(.telegram)
        manager._svSetLastUserAddress(nil)
        let none = manager.updateNoticeDestination()
        let local = await manager.sendUpdateNoticeOnce(record(none, text: "terminal notice"))
        t.check("manager: no messaging channel → terminal line printed once (local emit)",
                none.channelKind == nil && local == .accepted && emitted == ["app notice", "terminal notice"])
        sink.cancel()
    }
}
