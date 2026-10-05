import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SV10b intentional clearing (/switchbot, /deleteuserdata) and generation
/// checks, SV10e the one-hour give-up, and the Codex round-3 transport
/// boundary: a notice paused BEFORE credential capture in the Telegram
/// actor never builds its request with a replacement bot's token.
extension StopVisibilityHarness {

    func clearingSection() async {
        await clearDuringFlight(.switchbot)
        await clearDuringFlight(.deletion)
        await clearDuringRetryWait(.switchbot)
        await clearDuringRetryWait(.deletion)
        await clearWithCompletionQueued(.switchbot)
        await clearWithCompletionQueued(.deletion)
        await generationOnlyBumpRows()
        await giveUpRows()
    }

    enum Clearing: String { case switchbot = "/switchbot", deletion = "/deleteuserdata" }

    private func clear(_ manager: ConversationManager, _ how: Clearing) async {
        switch how {
        case .switchbot:
            // The production cut-over step (parked removal, generation bump,
            // series invalidation, adopt + re-register). No Telegram is
            // configured here, so re-registration drops the fake channel;
            // callers register it again afterwards.
            await manager._svCutOverTelegramBot(to: "")
        case .deletion:
            manager._svRetireForWipe()
        }
    }

    /// (a) the reply is on the wire when the clearing happens: it cannot be
    /// recalled, but nothing after it is sent and its late success never
    /// restarts the series.
    private func clearDuringFlight(_ how: Clearing) async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-cf") != nil else { check("SV10b setup", false); hold.release(); return }
        channel.hold(call: 1)
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.hasStarted(call: 1) }
        await clear(manager, how)
        manager._svRegisterChannel(channel)   // a channel is available again afterwards
        channel.release(call: 1)
        await finish(manager, hold)
        await sleep(1.5)
        check("SV10b \(how.rawValue) while the reply is in flight: nothing further sent from that series, no re-send",
              channel.callCount == 1 && !channel.stopTexts.contains { $0.hasPrefix("✅") }, "\(channel.events)")
        check("SV10b \(how.rawValue): status still clears at completion", manager.stoppedRunsFinishing.isEmpty)
    }

    /// (b) the reply failed and its retry is waiting: the clearing cancels
    /// the waiting retry; nothing is ever sent again.
    private func clearDuringRetryWait(_ how: Clearing) async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let clock = SVFakeClock()
        clock.holding = true
        NoticeSeries.clockOverrideForTesting = clock.clock
        defer { NoticeSeries.clockOverrideForTesting = nil }
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-cw") != nil else { check("SV10b setup", false); hold.release(); return }
        channel.fail(calls: [1])
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { clock.sleeps.count >= 1 }
        await clear(manager, how)
        manager._svRegisterChannel(channel)
        clock.release()
        await finish(manager, hold)
        await sleep(1)
        check("SV10b \(how.rawValue) while a retry waits: the scheduled retry never runs, nothing re-sent",
              channel.callCount == 1 && channel.stopTexts.isEmpty, "\(channel.events)")
    }

    /// (c) the completion is queued behind an in-flight reply when the
    /// clearing happens: the completion is never sent.
    private func clearWithCompletionQueued(_ how: Clearing) async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-cq") != nil else { check("SV10b setup", false); hold.release(); return }
        channel.hold(call: 1)
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.hasStarted(call: 1) }
        await finish(manager, hold)           // completion queued behind call 1
        await clear(manager, how)
        manager._svRegisterChannel(channel)
        channel.release(call: 1)
        await sleep(1.5)
        check("SV10b \(how.rawValue) with the completion queued: the completion is never sent",
              channel.callCount == 1 && !channel.stopTexts.contains { $0.hasPrefix("✅") }, "\(channel.events)")
    }

    /// The generation check alone (no explicit invalidation) stops a retry
    /// that was already scheduled.
    private func generationOnlyBumpRows() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let clock = SVFakeClock()
        clock.holding = true
        NoticeSeries.clockOverrideForTesting = clock.clock
        defer { NoticeSeries.clockOverrideForTesting = nil }
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-gb") != nil else { check("SV10b setup", false); hold.release(); return }
        channel.fail(calls: [1])
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { clock.sleeps.count >= 1 }
        NoticeChannelGenerations.bump(.telegram)
        clock.release()
        await finish(manager, hold)
        await sleep(1)
        let series = manager._svLiveSeries
        check("SV10b a generation change alone stops the scheduled retry before it is sent",
              channel.callCount == 1 && channel.stopTexts.isEmpty && series.isEmpty, "\(channel.events), live \(series.count)")
    }

    /// SV10e: a head failing for an hour (fake clock) gives up: it and every
    /// later item are dropped, never out of order; the completion append is
    /// refused; status still clears; a later /stop of the same run never
    /// opens a new retry lifetime for that destination.
    private func giveUpRows() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let clock = SVFakeClock()
        NoticeSeries.clockOverrideForTesting = clock.clock
        defer { NoticeSeries.clockOverrideForTesting = nil }
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-gu") != nil else {
            check("SV10e setup", false); hold.release(); return
        }
        channel.failAll(true)
        _ = await timedStop(manager)
        let gaveUp = await waitUntil(timeout: 20) { manager._svLiveSeries.isEmpty && channel.callCount > 0 }
        let attempts = channel.callCount
        let elapsed = clock.sleeps.reduce(0, +) / 1_000_000_000
        check("SV10e the head gives up after 1 h of failures (fake clock)", gaveUp && elapsed >= 3_600 && attempts >= 9,
              "attempts \(attempts), elapsed \(elapsed) s")
        _ = await timedStop(manager)          // repeated /stop after the give-up
        await sleep(0.5)
        check("SV10e a repeated /stop opens no new retry lifetime for the failed series", channel.callCount == attempts,
              "\(channel.callCount) vs \(attempts)")
        channel.failAll(false)
        await finish(manager, hold)
        await sleep(1)
        check("SV10e the completion is never sent after the give-up", channel.stopTexts.isEmpty && channel.callCount == attempts,
              "\(channel.events.suffix(3))")
        check("SV10e status still clears at completion", manager.stoppedRunsFinishing.isEmpty)
    }

    // MARK: Transport boundary (Codex round 3, mandatory)

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func add(_ request: URLRequest) { lock.lock(); urls.append(request.url?.absoluteString ?? ""); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    static let oldToken = "111111:AAold-synthetic-token-for-tests"
    static let newToken = "222222:BBnew-synthetic-token-for-tests"

    /// A manager whose Telegram channel is the REAL TelegramBotService
    /// (requests intercepted before the network).
    private func telegramManager() async -> ConversationManager {
        // No token while the manager is created: it must not start polling.
        try? KeychainHelper.delete(key: KeychainHelper.telegramBotTokenKey)
        try? KeychainHelper.delete(key: KeychainHelper.telegramChatIdKey)
        let manager = await freshManager()
        try? KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: Self.oldToken)
        try? KeychainHelper.save(key: KeychainHelper.telegramChatIdKey, value: telegramAddress.chatId)
        await manager._svRegisterTelegram()
        manager._svSetLastUserAddress(telegramAddress)
        return manager
    }

    func transportSection() async {
        // Control: no replacement → the notice is built with the old token.
        do {
            let log = RequestLog()
            let manager = await telegramManager()
            TelegramBotService.noticeRequestInterceptForTesting = { log.add($0) }
            let hold = SVToolHold(tool: "bash")
            if await startHeldTurn(manager, hold: hold, callId: "call-t0") != nil {
                _ = await timedStop(manager)
                _ = await waitUntil(timeout: 5) { !log.all.isEmpty }
                await finish(manager, hold)
                _ = await waitUntil(timeout: 5) { log.all.count >= 2 }
                check("SV10b-T control: reply and completion are built with the current bot's token",
                      log.all.count == 2 && log.all.allSatisfy { $0.contains(Self.oldToken) }, "\(log.all.count) request(s)")
            } else { check("SV10b-T control setup", false); hold.release() }
            TelegramBotService.noticeRequestInterceptForTesting = nil
        }
        // The race: the attempt is paused INSIDE the actor before credential
        // capture; the bot is replaced; the call is released.
        do {
            let log = RequestLog()
            let gate = SVGate()
            let manager = await telegramManager()
            TelegramBotService.noticeRequestInterceptForTesting = { log.add($0) }
            TelegramBotService.noticePreCaptureHookForTesting = { await gate.wait() }
            let hold = SVToolHold(tool: "bash")
            if await startHeldTurn(manager, hold: hold, callId: "call-t1") != nil {
                _ = await timedStop(manager)
                let paused = await waitUntil(timeout: 5) { gate.arrived > 0 }
                check("SV10b-T setup: the notice attempt is paused inside the actor, before credential capture",
                      paused && log.all.isEmpty)
                try? KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: Self.newToken)
                await manager._svCutOverTelegramBot(to: Self.newToken)
                gate.release()
                await sleep(0.5)
                await finish(manager, hold)
                await sleep(1)
                check("SV10b-T a notice paused before credential capture is NOT built after the bot was replaced",
                      log.all.isEmpty, "\(log.all.map { $0.contains(Self.newToken) ? "NEW-TOKEN" : "old" })")
                check("SV10b-T nothing was ever built with the replacement token", !log.all.contains { $0.contains(Self.newToken) })
                check("SV10b-T the series is closed (no completion afterwards)", manager._svLiveSeries.isEmpty)
            } else { check("SV10b-T race setup", false); hold.release() }
            TelegramBotService.noticePreCaptureHookForTesting = nil
            TelegramBotService.noticeRequestInterceptForTesting = nil
        }
        // A request already built and sent cannot be recalled; nothing after
        // it goes out once the bot was replaced.
        do {
            let log = RequestLog()
            let manager = await telegramManager()
            TelegramBotService.noticeRequestInterceptForTesting = { log.add($0) }
            let hold = SVToolHold(tool: "bash")
            if await startHeldTurn(manager, hold: hold, callId: "call-t2") != nil {
                _ = await timedStop(manager)
                _ = await waitUntil(timeout: 5) { !log.all.isEmpty }
                try? KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: Self.newToken)
                await manager._svCutOverTelegramBot(to: Self.newToken)
                await finish(manager, hold)
                await sleep(1)
                check("SV10b-T a reply already sent stays sent (old token); the completion is never built",
                      log.all.count == 1 && log.all[0].contains(Self.oldToken), "\(log.all.count) request(s)")
            } else { check("SV10b-T sent setup", false); hold.release() }
            TelegramBotService.noticeRequestInterceptForTesting = nil
        }
        try? KeychainHelper.delete(key: KeychainHelper.telegramBotTokenKey)
        try? KeychainHelper.delete(key: KeychainHelper.telegramChatIdKey)
    }
}
