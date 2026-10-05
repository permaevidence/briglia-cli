import Foundation

/// Disk-saving pause/recovery notices (plan §9, A3): SA1 one entry per
/// episode, SA2 recovery after the entry, SA3 recovery before any entry
/// send began → neither, SA4 recovery behind a failing/retrying entry, SA5
/// /switchbot and /deleteuserdata during an episode. The stall branch is
/// the poll loop's own `retryDurabilityStall` (writes failed by the
/// history-write fault seam); confirmations are unchanged (SA6: the
/// existing durability selftests and smoke's poller phase 7).
extension StopVisibilityHarness {

    struct InjectedWriteFailure: Error {}

    func a3Section() async {
        await stallEntryAndRecoveryRows()
        await stallCoalesceRows()
        await stallRetryRows()
        await stallClearingRows(.switchbot)
        await stallClearingRows(.deletion)
    }

    private func stallManager(_ channel: SVRecordingChannel) async -> ConversationManager {
        let manager = await freshManager(channel: channel)
        manager._svSetPairedChatId(Int(telegramAddress.chatId))
        return manager
    }

    private func failWrites(_ on: Bool) {
        ConversationManager.historyWriteFaultForTesting = on ? { throw InjectedWriteFailure() } : nil
    }

    /// SA1 + SA2 (+ destination): one entry notice per episode, no repeat
    /// per tick; on recovery the update is confirmed as before and the
    /// recovery notice follows the entry. The destination is the Telegram
    /// chat even when the last user channel was WhatsApp.
    private func stallEntryAndRecoveryRows() async {
        let telegram = SVRecordingChannel(kind: .telegram)
        let whatsapp = SVRecordingChannel(kind: .whatsapp)
        let manager = await stallManager(telegram)
        manager._svRegisterChannel(whatsapp)
        manager._svSetLastUserAddress(ChannelAddress(kind: .whatsapp, chatId: "393330000000@s.whatsapp.net"))
        failWrites(true)
        defer { failWrites(false) }
        manager._svSetStalledConfirm(700)
        for _ in 0..<3 { await manager._svDurabilityTick(); await sleep(0.2) }
        _ = await waitUntil(timeout: 5) { !telegram.delivered.isEmpty }
        await sleep(0.3)
        check("SA1 a stall episode sends exactly one entry notice (no repeat per tick)",
              telegram.delivered == [ConversationManager.durabilityStallEntryText], "\(telegram.delivered)")
        check("SA1 the notice goes to the Telegram chat captured at episode start, not the last (WhatsApp) channel",
              whatsapp.delivered.isEmpty)
        check("SA6 still stalled while writes fail (no confirm)", manager._svStalledConfirm == 700)
        failWrites(false)
        await manager._svDurabilityTick()
        _ = await waitUntil(timeout: 5) { telegram.delivered.count >= 2 }
        check("SA6 recovery confirms and clears the stall exactly as before", manager._svStalledConfirm == nil)
        check("SA2 the recovery notice follows the entry",
              telegram.delivered == [ConversationManager.durabilityStallEntryText, ConversationManager.durabilityStallRecoveryText],
              "\(telegram.delivered)")
    }

    /// SA3: saving recovers before the entry's send began → neither notice.
    private func stallCoalesceRows() async {
        let telegram = SVRecordingChannel(kind: .telegram)
        let manager = await stallManager(telegram)
        manager._svStallBeganThenRecoveredSynchronously()
        await sleep(1)
        check("SA3 recovery before any entry send began: neither notice is sent",
              telegram.callCount == 0 && manager._svLiveSeries.isEmpty, "\(telegram.events)")
    }

    /// SA4: the entry's send fails and waits to retry when saving recovers:
    /// the recovery is sent only after the entry settled.
    private func stallRetryRows() async {
        let telegram = SVRecordingChannel(kind: .telegram)
        let manager = await stallManager(telegram)
        let clock = SVFakeClock()
        clock.holding = true
        NoticeSeries.clockOverrideForTesting = clock.clock
        defer { NoticeSeries.clockOverrideForTesting = nil }
        telegram.fail(calls: [1])
        failWrites(true)
        manager._svSetStalledConfirm(701)
        await manager._svDurabilityTick()
        _ = await waitUntil(timeout: 5) { clock.sleeps.count >= 1 }
        failWrites(false)
        await manager._svDurabilityTick()
        await sleep(0.3)
        check("SA4 recovery waits behind the failing entry", telegram.delivered.isEmpty, "\(telegram.events)")
        clock.holding = false
        clock.release()
        _ = await waitUntil(timeout: 5) { telegram.delivered.count >= 2 }
        check("SA4 after the entry's retry settles: entry, then recovery",
              telegram.delivered == [ConversationManager.durabilityStallEntryText, ConversationManager.durabilityStallRecoveryText],
              "\(telegram.events)")
    }

    /// SA5: /switchbot or /deleteuserdata during an episode: nothing
    /// further from that episode, nothing through the replacement.
    private func stallClearingRows(_ how: Clearing) async {
        let telegram = SVRecordingChannel(kind: .telegram)
        let manager = await stallManager(telegram)
        failWrites(true)
        manager._svSetStalledConfirm(702)
        await manager._svDurabilityTick()
        _ = await waitUntil(timeout: 5) { telegram.delivered.count == 1 }
        switch how {
        case .switchbot: await manager._svCutOverTelegramBot(to: "")
        case .deletion: manager._svRetireForWipe()
        }
        manager._svRegisterChannel(telegram)
        manager._svSetPairedChatId(Int(telegramAddress.chatId))
        failWrites(false)
        await manager._svDurabilityTick()
        await sleep(1)
        check("SA5 \(how.rawValue) during an episode: no recovery notice, nothing re-sent",
              telegram.callCount == 1 && telegram.delivered == [ConversationManager.durabilityStallEntryText],
              "\(telegram.events)")
    }
}
