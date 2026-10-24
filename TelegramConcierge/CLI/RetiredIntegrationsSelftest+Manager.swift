import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

extension MidturnHarness {

    /// Either language (the notice follows the machine's language).
    static func isGwsNotice(_ text: String) -> Bool {
        text.contains("Google email via gws has been removed from Briglia")
            || text.contains("L'email Google tramite gws è stata rimossa da Briglia")
    }

    /// Manager-level checks: in-memory ambient fallback normalisation, kept
    /// WhatsApp origins, and the notice loop (readiness, polling lifetime,
    /// at-most-once). Uses the live Env (private preference domain + scratch
    /// XDG roots of this child process).
    @MainActor
    func riManagerSection(_ scratch: URL) async throws {
        server = try CaptureServer()
        defer { server.stop() }
        try configureProvider()
        let env = RetiredIntegrations.env
        let defaults = UserDefaults.standard
        let lastKey = RetiredIntegrations.lastUserChannelDefaultsKey
        let wa = ChannelAddress(kind: .whatsapp, chatId: "393330000000@s.whatsapp.net")
        let tg = ChannelAddress(kind: .telegram, chatId: "42")
        // No automatic startPolling from the initializer: these checks drive
        // the startup steps by hand.
        defaults.set(false, forKey: "should_resume_polling_on_launch")
        func clear() {
            try? FileManager.default.removeItem(at: env.stateURL)
            defaults.removeObject(forKey: lastKey)
            try? KeychainHelper.delete(key: KeychainHelper.telegramBotTokenKey)
            try? KeychainHelper.delete(key: KeychainHelper.telegramChatIdKey)
            RetiredNoticeSinks.terminalAttached = false
        }

        // M1/M2: the already-loaded WhatsApp fallback is corrected before configure().
        for paired in [true, false] {
            clear()
            if paired {
                try? KeychainHelper.saveBatch([KeychainHelper.telegramBotTokenKey: "123:synthetic-token",
                                               KeychainHelper.telegramChatIdKey: "42"])
            }
            defaults.set(try JSONEncoder().encode(wa), forKey: lastKey)
            let manager = await freshManager()
            let loaded = manager.lastUserChannelAddress
            manager.applyRetiredIntegrationsMigration()
            check("M\(paired ? 1 : 2) init loaded the WhatsApp fallback; migration makes it \(paired ? "the paired Telegram address" : "nil")",
                  loaded == wa && manager.lastUserChannelAddress == (paired ? tg : nil),
                  "loaded \(String(describing: loaded)) now \(String(describing: manager.lastUserChannelAddress))")
        }

        // M3: routing hygiene even when the durable steps stay inert.
        clear()
        try? KeychainHelper.saveBatch([KeychainHelper.telegramBotTokenKey: "123:synthetic-token", KeychainHelper.telegramChatIdKey: "42"])
        defaults.set(try JSONEncoder().encode(wa), forKey: lastKey)
        try PrivateStorage.writeAtomically(Data("{corrupt".utf8), to: env.stateURL)
        var manager = await freshManager()
        manager.applyRetiredIntegrationsMigration()
        check("M3 unreadable state: durable steps inert, but the in-memory fallback still moves to Telegram",
              manager.lastUserChannelAddress == tg && defaults.data(forKey: lastKey) != nil)

        // M4: historical WhatsApp origins decode, are kept, and stay unroutable.
        clear()
        let old = Message(role: .user, content: "from whatsapp")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["originChannel"] = ["kind": "whatsapp", "chatId": wa.chatId]
        let decoded = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
        check("M4 a saved message with a WhatsApp origin decodes and keeps it", decoded.originChannel == wa)
        manager = await freshManager(history: [decoded])
        let telegram = SVRecordingChannel(kind: .telegram)
        manager._svRegisterChannel(telegram)
        manager._svSetLastUserAddress(tg)
        await manager._svSendOrdinary("reply to the old whatsapp turn", to: decoded.originChannel!)
        check("M4b a reply addressed to a WhatsApp origin is a no-op, never rerouted to Telegram",
              telegram.delivered.isEmpty && manager._svParkedTexts.isEmpty)
        check("M4c a recovered WhatsApp-origin history still loads", manager._testMessages.contains { $0.originChannel == wa })

        // M5–M8: the notice loop.
        func seedOwed() throws {
            try RetiredIntegrations.save(RetiredIntegrations.State(version: 1, evaluated: true,
                gws: .init(legacyUnset: false, conversion: .done, notice: .pending), whatsapp: nil), to: env.stateURL)
        }
        var emitted: [String] = []
        var bag = Set<AnyCancellable>()
        clear(); try seedOwed()
        manager = await freshManager()
        manager.stopNoticeEvents.sink { emitted.append($0) }.store(in: &bag)
        manager.isPolling = true
        var owed = await manager.retiredNoticeTick()
        check("M5 no Telegram and no attached local sink → nothing sent, still owed",
              owed && emitted.isEmpty && RIUnits.state(env)?.gws?.notice == .pending)
        RetiredNoticeSinks.terminalAttached = true
        manager.isPolling = false
        owed = await manager.retiredNoticeTick()
        check("M6 polling stopped → nothing sent", emitted.isEmpty && RIUnits.state(env)?.gws?.notice == .pending)
        manager.isPolling = true
        owed = await manager.retiredNoticeTick()
        _ = await manager.retiredNoticeTick()
        check("M7 interactive terminal attached → exactly one local notice, then done and silent",
              !owed && emitted.count == 1 && emitted.first.map(Self.isGwsNotice) == true
                && RIUnits.state(env)?.gws?.notice == .done,
              "owed \(owed) emitted \(emitted) state \(String(describing: RIUnits.state(env)?.gws))")

        clear(); try seedOwed(); emitted = []
        let tgChannel = SVRecordingChannel(kind: .telegram)
        manager._svRegisterChannel(tgChannel)
        manager._svSetLastUserAddress(tg)
        tgChannel.failAll(true)
        owed = await manager.retiredNoticeTick()
        check("M8 a send that fails (ambiguous) is never repeated: done after one attempt",
              !owed && tgChannel.callCount == 1 && RIUnits.state(env)?.gws?.notice == .done)
        tgChannel.failAll(false)
        clear(); try seedOwed()
        manager._svSetLastUserAddress(tg)
        owed = await manager.retiredNoticeTick()
        check("M9 Telegram registered → sent there once (not locally)",
              !owed && tgChannel.delivered.filter(Self.isGwsNotice).count == 1 && emitted.isEmpty,
              "owed \(owed) delivered \(tgChannel.delivered) emitted \(emitted)")
        manager.isPolling = false
        manager._svUnregisterChannel(.telegram)
        bag.removeAll()
        clear()
    }
}
