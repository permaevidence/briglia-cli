import Foundation

/// Ordering through actual delivery (§4.1): SV8 suspended initial send,
/// SV9 failure + series retry, SV10 parked-queue churn, SV10c repeated
/// /stop held across completion, SV12 WhatsApp.
extension StopVisibilityHarness {

    func deliverySection() async {
        await suspendedInitialSendRows()
        await retryRows()
        await parkedChurnRows()
        await repeatHeldAcrossCompletionRows()
        await whatsappRows()
    }

    /// SV8: the completion becomes due while the reply's send is suspended
    /// on the wire; it is sent strictly after that send returned.
    private func suspendedInitialSendRows() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-s8") != nil else { check("SV8 setup", false); hold.release(); return }
        channel.hold(call: 1)
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.hasStarted(call: 1) }
        await finish(manager, hold)          // the run ends; completion is due now
        await sleep(1)
        check("SV8 completion not started while the reply's send is suspended", !channel.hasStarted(call: 2),
              "\(channel.events)")
        channel.release(call: 1)
        _ = await waitUntil(timeout: 5) { channel.stopTexts.count >= 2 }
        let events = channel.events
        let end1 = events.firstIndex { $0.hasPrefix("end1:") } ?? Int.max
        let start2 = events.firstIndex { $0.hasPrefix("start2:") } ?? -1
        check("SV8 completion sent strictly after the reply's send returned",
              end1 < start2 && channel.stopTexts.count == 2 && channel.stopTexts[1].hasPrefix("✅"), "\(events)")
    }

    /// SV9: the reply's send fails, the series retries on its own backoff
    /// (not the parked queue), the completion becomes due during the
    /// backoff and goes out only after the reply. Ordinary parked replies
    /// are untouched.
    private func retryRows() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let clock = SVFakeClock()
        NoticeSeries.clockOverrideForTesting = clock.clock
        defer { NoticeSeries.clockOverrideForTesting = nil }
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-s9") != nil else { check("SV9 setup", false); hold.release(); return }
        channel.fail(calls: [1, 2, 3])        // three quick attempts fail
        clock.holding = true                  // the series then waits in its backoff
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { clock.sleeps.count >= 1 }
        await finish(manager, hold)           // completion due during the backoff
        await sleep(0.5)
        check("SV9 the completion waits behind the failing reply", channel.stopTexts.isEmpty, "\(channel.events)")
        check("SV9 the failing reply is NOT parked in the ordinary queue", manager._svParkedTexts.isEmpty,
              "\(manager._svParkedTexts)")
        clock.holding = false
        clock.release()
        _ = await waitUntil(timeout: 10) { channel.stopTexts.count >= 2 }
        let texts = channel.stopTexts
        check("SV9 after recovery: reply, then completion",
              texts.count == 2 && texts[0].hasPrefix("⛔ Stop requested.") && texts[1].hasPrefix("✅"), "\(texts) \(channel.events)")
        check("SV9 backoff used the series schedule (2 s, 4 s, then 30 s)",
              Array(clock.sleeps.prefix(3)) == [2, 4, 30].map { UInt64($0) * 1_000_000_000 }, "\(clock.sleeps)")
        check("SV9 ordinary parked queue still empty", manager._svParkedTexts.isEmpty)
    }

    /// SV10: 25 ordinary replies fail and park (and trim) while the series
    /// reply is in flight: series order unaffected, trimming unchanged.
    private func parkedChurnRows() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-s10") != nil else { check("SV10 setup", false); hold.release(); return }
        channel.hold(call: 1)
        _ = await timedStop(manager)
        // Call 1 must be the series reply; otherwise an ordinary send would
        // take the held slot and the churn below could never finish.
        guard await waitUntil(timeout: 5, { channel.hasStarted(call: 1) }) else {
            check("SV10 setup: the still-finishing reply is on the wire", false)
            channel.release(call: 1); await finish(manager, hold); return
        }
        channel.failTexts(withPrefix: "ordinary-")
        let address = telegramAddress
        await withTaskGroup(of: Void.self) { group in
            for i in 1...25 {
                group.addTask { @MainActor in await manager._svSendOrdinary("ordinary-\(i)", to: address) }
            }
        }
        let parked = manager._svParkedTexts
        check("SV10 ordinary failures park and trim exactly as before (20 kept, all ordinary)",
              parked.count == ParkedOutboundQueue.capacity && parked.allSatisfy { $0.hasPrefix("ordinary-") }, "\(parked.count)")
        await finish(manager, hold)
        channel.release(call: 1)
        _ = await waitUntil(timeout: 10) { channel.stopTexts.count >= 2 }
        let texts = channel.stopTexts
        check("SV10 series order unaffected by parked-queue churn: reply, then completion",
              texts.count == 2 && texts[0].hasPrefix("⛔") && texts[1].hasPrefix("✅"), "\(texts)")
        check("SV10 no visibility notice ever entered the parked queue",
              !manager._svParkedTexts.contains { $0.hasPrefix("⛔") || $0.hasPrefix("✅") })
    }

    /// SV10c: a repeated /stop's reply is held on the wire across the run's
    /// completion; the completion follows it; one completion.
    private func repeatHeldAcrossCompletionRows() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-s10c") != nil else { check("SV10c setup", false); hold.release(); return }
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.stopTexts.count == 1 }
        channel.hold(call: 2)
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.hasStarted(call: 2) }
        await finish(manager, hold)
        await sleep(1)
        check("SV10c completion not started while the repeated reply is in flight", !channel.hasStarted(call: 3), "\(channel.events)")
        channel.release(call: 2)
        _ = await waitUntil(timeout: 5) { channel.stopTexts.count >= 3 }
        await sleep(0.5)
        let texts = channel.stopTexts
        check("SV10c order: reply, \"Already stopping\", completion — one completion",
              texts.count == 3 && texts[1].hasPrefix("⛔ Already stopping.") && texts[2].hasPrefix("✅"), "\(texts)")
    }

    /// SV12: a WhatsApp stop goes through the same ordered series.
    private func whatsappRows() async {
        let channel = SVRecordingChannel(kind: .whatsapp)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        guard await startHeldTurn(manager, hold: hold, callId: "call-wa") != nil else { check("SV12 setup", false); hold.release(); return }
        _ = await timedStop(manager)
        await finish(manager, hold)
        _ = await waitUntil(timeout: 10) { channel.stopTexts.count >= 2 }
        let texts = channel.stopTexts
        check("SV12 WhatsApp: still-finishing reply then one completion",
              texts.count == 2 && texts[0].hasPrefix("⛔ Stop requested.") && texts[1].hasPrefix("✅"), "\(texts)")
    }
}
