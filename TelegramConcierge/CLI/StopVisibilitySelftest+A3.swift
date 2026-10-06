import Foundation

/// Disk-saving pause/recovery notices (plan §9, A3): SA1 one entry per
/// episode, SA2 recovery after the entry, SA3 recovery before any entry
/// send began → neither, SA4 recovery behind a failing/retrying entry, SA5
/// /switchbot and /deleteuserdata during an episode; SA7–SA9 consecutive
/// episodes (Codex impl review R2): backoff overlap, in-flight overlap,
/// sequential episodes. The stall branch is
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
        await stallEpisodesOverlapBackoffRows()
        await stallEpisodesOverlapInFlightRows()
        await stallEpisodesSequentialRows()
    }

    /// SA7 (Codex impl review R2, reproduction): episode A's entry fails and
    /// waits in retry backoff; writes recover (A's recovery queues behind
    /// it); writes fail again and episode B starts; then A's backoff ends.
    /// Never "B pause → A pause → A recovery": while B's update is still
    /// unconfirmed, the last notice delivered must be a pause. B's own
    /// recovery then arrives last.
    private func stallEpisodesOverlapBackoffRows() async {
        let telegram = SVRecordingChannel(kind: .telegram)
        let manager = await stallManager(telegram)
        let clock = SVFakeClock()
        clock.holding = true
        NoticeSeries.clockOverrideForTesting = clock.clock
        defer { failWrites(false); NoticeSeries.clockOverrideForTesting = nil; clock.release() }
        telegram.fail(calls: [1])
        failWrites(true)
        manager._svSetStalledConfirm(801)
        await manager._svDurabilityTick()
        _ = await waitUntil(timeout: 5) { !clock.sleeps.isEmpty }
        failWrites(false)
        await manager._svDurabilityTick()
        failWrites(true)
        manager._svSetStalledConfirm(802)
        await manager._svDurabilityTick()
        await sleep(0.5)
        check("SA7 while A's entry waits in backoff, B's entry does not overtake it",
              telegram.delivered.isEmpty, "\(telegram.events)")
        clock.holding = false
        clock.release()
        _ = await waitUntil(timeout: 5) { !telegram.delivered.isEmpty }
        await sleep(0.5)
        check("SA7 B still stalled: the last notice delivered is a pause, never A's stale recovery",
              manager._svStalledConfirm == 802 && telegram.delivered.last == ConversationManager.durabilityStallEntryText
                && !telegram.delivered.contains(ConversationManager.durabilityStallRecoveryText), "\(telegram.delivered)")
        failWrites(false)
        await manager._svDurabilityTick()
        _ = await waitUntil(timeout: 5) { telegram.delivered.last == ConversationManager.durabilityStallRecoveryText }
        await sleep(0.3)
        check("SA7 after B recovers: pause then recovery, nothing contradictory",
              manager._svStalledConfirm == nil
                && telegram.delivered == [ConversationManager.durabilityStallEntryText, ConversationManager.durabilityStallRecoveryText],
              "\(telegram.delivered)")
        check("SA7 confirmations unchanged by notice delivery (B's update confirmed on recovery)", manager._svStalledConfirm == nil)
    }

    /// SA8 (in-flight variant): A's recovery is ON THE WIRE when B starts:
    /// it is not recalled; B's entry follows it, so the last notice still
    /// matches the paused state.
    private func stallEpisodesOverlapInFlightRows() async {
        let telegram = SVRecordingChannel(kind: .telegram)
        let manager = await stallManager(telegram)
        defer { failWrites(false); telegram.release(call: 2) }
        failWrites(true)
        manager._svSetStalledConfirm(811)
        await manager._svDurabilityTick()
        _ = await waitUntil(timeout: 5) { telegram.delivered.count == 1 }
        telegram.hold(call: 2)
        failWrites(false)
        await manager._svDurabilityTick()
        _ = await waitUntil(timeout: 5) { telegram.hasStarted(call: 2) }
        failWrites(true)
        manager._svSetStalledConfirm(812)
        await manager._svDurabilityTick()
        await sleep(0.3)
        check("SA8 B's entry waits behind A's in-flight recovery", !telegram.hasStarted(call: 3), "\(telegram.events)")
        telegram.release(call: 2)
        _ = await waitUntil(timeout: 5) { telegram.delivered.count >= 3 }
        await sleep(0.3)
        check("SA8 order: A pause, A recovery (sent, not recalled), B pause — last matches the stall",
              manager._svStalledConfirm == 812 && telegram.delivered == [ConversationManager.durabilityStallEntryText,
                ConversationManager.durabilityStallRecoveryText, ConversationManager.durabilityStallEntryText],
              "\(telegram.delivered)")
        failWrites(false)
        await manager._svDurabilityTick()
        _ = await waitUntil(timeout: 5) { telegram.delivered.count >= 4 }
        check("SA8 B's recovery last", telegram.delivered.last == ConversationManager.durabilityStallRecoveryText
              && telegram.delivered.count == 4, "\(telegram.delivered)")
    }

    /// SA9: two episodes that do not overlap each produce pause + recovery,
    /// and the series does not linger once drained.
    private func stallEpisodesSequentialRows() async {
        let telegram = SVRecordingChannel(kind: .telegram)
        let manager = await stallManager(telegram)
        defer { failWrites(false) }
        for (i, update) in [821, 822].enumerated() {
            failWrites(true)
            manager._svSetStalledConfirm(update)
            await manager._svDurabilityTick()
            _ = await waitUntil(timeout: 5) { telegram.delivered.count == 2 * i + 1 }
            failWrites(false)
            await manager._svDurabilityTick()
            _ = await waitUntil(timeout: 5) { telegram.delivered.count == 2 * i + 2 }
        }
        await sleep(0.3)
        let e = ConversationManager.durabilityStallEntryText, r = ConversationManager.durabilityStallRecoveryText
        check("SA9 two separate episodes: pause, recovery, pause, recovery", telegram.delivered == [e, r, e, r], "\(telegram.delivered)")
        check("SA9 a drained disk-saving series is released", manager._svLiveSeries.isEmpty, "\(manager._svLiveSeries.count)")
        // A stall that clears on its very first retry (no pause was ever
        // queued) owes no recovery, even after earlier episodes.
        manager._svSetStalledConfirm(823)
        await manager._svDurabilityTick()
        await sleep(0.5)
        check("SA9 a stall cleared before any pause was queued sends no recovery",
              manager._svStalledConfirm == nil && telegram.delivered == [e, r, e, r], "\(telegram.delivered)")
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
