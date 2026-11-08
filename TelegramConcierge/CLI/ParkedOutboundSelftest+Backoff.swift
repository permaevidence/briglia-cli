import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 0.2.68 duplicate-send fix. When Telegram delivers a message but its
/// acknowledgement is lost, every retry delivers another copy (one incident:
/// 18 copies, because the parked queue was retried on every successful poll
/// tick). Pinned here: the backoff schedule (30 s, 1 min, 2 min, then every
/// 5 min), 429 retry_after, permanent HTTP 400 refusals, and a simulated
/// lost-acknowledgement outage through the real `ConversationManager.sendText`
/// + `flushParkedOutbound` path with a simulated clock: a bounded number of
/// copies, and the reply still goes through once acknowledgements return.
extension ParkedOutboundSelftest {

    @MainActor
    static func backoffRows(check: (String, Bool, String) -> Void) async {
        let tg = ChannelAddress(kind: .telegram, chatId: "1")
        struct Down: Error {}

        // B1. Schedule: parked → not due until 30 s; then 60, 120, 300, 300.
        do {
            let clk = SimClock()
            let queue = ParkedOutboundQueue(now: { clk.t })
            queue.park("r", address: tg)
            var attempts = 0
            var delays: [TimeInterval] = []
            clk.t += 29
            let early = await queue.flush(deliver: { _ in attempts += 1; throw Down() })
            check("B1 a freshly parked reply is not retried before 30 s", !early && attempts == 0 && !queue.isDue, "attempts=\(attempts)")
            clk.t += 1
            check("B1 due at 30 s", queue.isDue, "")
            for _ in 0..<5 {
                while !queue.isDue { clk.t += 1 }
                await queue.flush(deliver: { _ in attempts += 1; throw Down() },
                                  onFailed: { _, _, _, delay in delays.append(delay ?? -1) })
            }
            check("B1 backoff after failures: 1 min, 2 min, 5 min, 5 min, 5 min (capped)",
                  delays == [60, 120, 300, 300, 300] && attempts == 5, "\(delays) attempts=\(attempts)")
            check("B1 the reply is still queued after repeated failures (never abandoned)",
                  queue.items.map(\.text) == ["r"], "\(queue.items.map(\.text))")
            clk.t += 300
            var sent: [String] = []
            await queue.flush(deliver: { sent.append($0.text); return true })
            check("B1 recovery delivers and resets the backoff", sent == ["r"] && queue.isEmpty
                  && queue.consecutiveFailures == 0 && queue.nextAttemptAt == nil, "")
            queue.park("r2", address: tg)
            check("B1 after a recovery the next parked reply starts again at 30 s",
                  queue.nextAttemptAt == clk.t.addingTimeInterval(30), "")
        }

        // B2. 429 retry_after longer than the schedule step wins.
        do {
            let clk = SimClock()
            let queue = ParkedOutboundQueue(now: { clk.t })
            queue.park("r", address: tg)
            clk.t += 30
            var delay: TimeInterval?
            await queue.flush(deliver: { _ in throw Down() },
                              classify: { _ in .retryLater(retryAfter: 90) },
                              onFailed: { _, _, _, d in delay = d })
            check("B2 a 429 retry_after (90 s) beats the 60 s step", delay == 90 && !queue.isDue, "\(String(describing: delay))")
            let queue2 = ParkedOutboundQueue(now: { clk.t })
            queue2.park("q", address: tg, retryAfter: 120)
            check("B2 parking with retry_after waits at least that long", queue2.nextAttemptAt == clk.t.addingTimeInterval(120), "")
        }

        // B3. A permanent refusal (discard) is removed, logged, and the flush
        //     moves on to the next reply instead of blocking it forever.
        do {
            let clk = SimClock()
            let queue = ParkedOutboundQueue(now: { clk.t })
            queue.park("bad", address: tg); queue.park("good", address: tg)
            clk.t += 30
            var sent: [String] = [], discarded: [String] = []
            await queue.flush(deliver: { item in
                if item.text == "bad" { throw Down() }
                sent.append(item.text); return true
            }, classify: { _ in .discard }, onFailed: { item, _, _, delay in
                if delay == nil { discarded.append(item.text) }
            })
            check("B3 permanently refused reply removed and reported; the next one delivered",
                  discarded == ["bad"] && sent == ["good"] && queue.isEmpty, "\(discarded) \(sent)")
        }

        // B4. Classification of real Telegram errors.
        do {
            let timeout = TelegramError.transport(code: -1001, description: "timed out")
            let lost = TelegramError.transport(code: -1005, description: "connection lost")
            let refused = TelegramError.transport(code: -1004, description: "could not connect")
            let dns = TelegramError.transport(code: -1003, description: "no host")
            check("B4 timeout / connection lost are NOT proof of non-delivery (no in-line retry)",
                  !ConversationManager.sendFailureProvesNotSent(timeout) && !ConversationManager.sendFailureProvesNotSent(lost), "")
            check("B4 connection refused / DNS prove nothing was sent (in-line retry allowed)",
                  ConversationManager.sendFailureProvesNotSent(refused) && ConversationManager.sendFailureProvesNotSent(dns), "")
            check("B4 5xx is not proof of non-delivery",
                  !ConversationManager.sendFailureProvesNotSent(TelegramError.invalidResponse(statusCode: 502, body: nil)), "")
            func isDiscard(_ e: Error) -> Bool {
                if case .discard = ConversationManager.parkedDisposition(for: e) { return true }
                return false
            }
            func retryAfter(_ e: Error) -> TimeInterval?? {
                if case .retryLater(let r) = ConversationManager.parkedDisposition(for: e) { return .some(r) }
                return .none
            }
            check("B4 HTTP 400 is a permanent refusal",
                  isDiscard(TelegramError.invalidResponse(statusCode: 400, body: #"{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}"#)), "")
            check("B4 HTTP 403 / 401 / 5xx / timeouts keep the reply",
                  !isDiscard(TelegramError.invalidResponse(statusCode: 403, body: nil))
                  && !isDiscard(TelegramError.invalidResponse(statusCode: 401, body: nil))
                  && !isDiscard(TelegramError.invalidResponse(statusCode: 500, body: nil))
                  && !isDiscard(timeout) && !isDiscard(Down()), "")
            check("B4 a non-Telegram error is not proof of non-delivery", !ConversationManager.sendFailureProvesNotSent(Down()), "")
            check("B4 429 carries retry_after",
                  retryAfter(TelegramError.invalidResponse(statusCode: 429, body: #"{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 42","parameters":{"retry_after":42}}"#)) == .some(42), "")
        }
    }

    /// B5. An ordinary reply waits 60 s for Telegram's answer (was 15 s);
    /// visibility notices keep 15 s. Captured from the real request builder.
    static func timeoutRows(check: (String, Bool, String) -> Void) async {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var timeouts: [TimeInterval] = []
            func add(_ t: TimeInterval) { lock.lock(); timeouts.append(t); lock.unlock() }
            var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return timeouts }
        }
        let box = Box()
        TelegramBotService.transportOverrideForTesting = { request in
            box.add(request.timeoutInterval)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"ok":true,"result":{"message_id":1,"date":0,"chat":{"id":1,"type":"private"}}}"#.utf8), response)
        }
        TelegramBotService.noticeRequestInterceptForTesting = { request in box.add(request.timeoutInterval) }
        defer {
            TelegramBotService.transportOverrideForTesting = nil
            TelegramBotService.noticeRequestInterceptForTesting = nil
        }
        let service = TelegramBotService()
        await service.configure(token: "1234567890:" + String(repeating: "A", count: 35))
        do { try await service.sendText(chatId: "1", text: "hello") } catch {
            check("B5 synthetic send succeeded", false, "\(error)")
        }
        try? await service.sendNoticeText(chatId: "1", text: "notice",
                                          expectedGeneration: NoticeChannelGenerations.current(.telegram))
        check("B5 ordinary reply request waits 60 s; notice request keeps 15 s",
              box.all == [60, 15], "\(box.all)")
    }

    /// A Telegram stand-in whose every send DELIVERS (records a copy the user
    /// would see) and then, while `ackLost`, fails as a timeout — exactly the
    /// lost-acknowledgement shape. Each call advances the simulated clock by
    /// the 60 s the real request would have waited. Other failure modes
    /// (`refuse`) model proven non-delivery and HTTP refusals.
    final class LostAckChannel: ChatChannel, @unchecked Sendable {
        enum Mode { case ackLost, healthy, connectRefused, badRequest }
        let kind: ChannelKind = .telegram
        private let lock = NSLock()
        private var _mode: Mode = .ackLost
        private var _copies: [String] = []
        private var _calls = 0
        let clock: SimClock
        init(clock: SimClock) { self.clock = clock }
        var mode: Mode { get { lock.lock(); defer { lock.unlock() }; return _mode }
                         set { lock.lock(); _mode = newValue; lock.unlock() } }
        var copies: [String] { lock.lock(); defer { lock.unlock() }; return _copies }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func sendText(chatId: String, text: String) async throws {
            lock.lock(); _calls += 1; let mode = _mode; lock.unlock()
            switch mode {
            case .healthy:
                lock.lock(); _copies.append(text); lock.unlock()
            case .ackLost:
                lock.lock(); _copies.append(text); lock.unlock()
                await MainActor.run { clock.t += 60 }
                throw TelegramError.transport(code: -1001, description: "The request timed out.")
            case .connectRefused:
                throw TelegramError.transport(code: -1004, description: "Could not connect to the server.")
            case .badRequest:
                throw TelegramError.invalidResponse(statusCode: 400, body: #"{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}"#)
            }
        }
        func sendPhoto(chatId: String, imageData: Data, caption: String?, mimeType: String) async throws {}
        func sendDocument(chatId: String, documentData: Data, filename: String, caption: String?, mimeType: String) async throws {}
    }

    @MainActor
    static func managerSendRows(check: (String, Bool, String) -> Void) async {
        let clk = SimClock()
        ParkedOutboundQueue.clockOverrideForTesting = { clk.t }
        defer { ParkedOutboundQueue.clockOverrideForTesting = nil }
        let tg = ChannelAddress(kind: .telegram, chatId: "1")

        // M1. Lost acknowledgements for 10 simulated minutes. Poll ticks
        //     succeed every second (Telegram is reachable; only the send
        //     acknowledgements are lost), each one calling the flush exactly
        //     like the poll loop's success path.
        do {
            let manager = ConversationManager()
            let channel = LostAckChannel(clock: clk)
            manager._svRegisterChannel(channel)
            var threw = false
            do { try await manager.sendText("reply-A", to: tg) } catch { threw = true }
            check("M1 a timed-out send is tried once in-line (no immediate duplicate), then parked",
                  threw && channel.calls == 1 && manager._svParkedTexts == ["reply-A"], "calls=\(channel.calls)")
            let outageEnd = clk.t.addingTimeInterval(600)
            var ticks = 0
            while clk.t < outageEnd {
                clk.t += 1; ticks += 1
                await manager.flushParkedOutbound()
            }
            let copies = channel.copies.count
            // Schedule from the end of the in-line attempt (t=60): retries
            // at 90, 210, 390 (each taking 60 s), next would be 750.
            check("M1 10 min of lost acknowledgements: a bounded number of copies (≤ 5; was one per poll tick)",
                  copies >= 2 && copies <= 5, "copies=\(copies) ticks=\(ticks)")
            check("M1 the reply is still queued during the outage (never dropped)",
                  manager._svParkedTexts == ["reply-A"], "\(manager._svParkedTexts)")
            channel.mode = .healthy
            let before = channel.copies.count
            let recoverBy = clk.t.addingTimeInterval(400)
            while !manager._svParkedTexts.isEmpty && clk.t < recoverBy {
                clk.t += 1
                await manager.flushParkedOutbound()
            }
            check("M1 once acknowledgements return the reply is delivered within one backoff step, exactly once more",
                  manager._svParkedTexts.isEmpty && channel.copies.count == before + 1, "copies \(before)→\(channel.copies.count)")
        }

        // M2. A failure that proves nothing was sent keeps the quick in-line
        //     retries (3 attempts), then parks.
        do {
            let manager = ConversationManager()
            let channel = LostAckChannel(clock: clk)
            channel.mode = .connectRefused
            manager._svRegisterChannel(channel)
            try? await manager.sendText("reply-B", to: tg)
            check("M2 connection refused: 3 in-line attempts, then parked, no copy delivered",
                  channel.calls == 3 && channel.copies.isEmpty && manager._svParkedTexts == ["reply-B"], "calls=\(channel.calls)")
        }

        // M3. HTTP 400 (permanent): one attempt, not parked, so it cannot
        //     block later replies.
        do {
            let manager = ConversationManager()
            let channel = LostAckChannel(clock: clk)
            channel.mode = .badRequest
            manager._svRegisterChannel(channel)
            try? await manager.sendText("reply-C", to: tg)
            check("M3 HTTP 400: one attempt, not parked",
                  channel.calls == 1 && manager._svParkedTexts.isEmpty, "calls=\(channel.calls) \(manager._svParkedTexts)")
        }
    }
}
