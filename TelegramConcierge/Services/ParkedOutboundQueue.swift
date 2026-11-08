import Foundation

/// Replies whose wire delivery failed after retries, awaiting redelivery once
/// the channel recovers. In-memory only by design: the text also survives in
/// conversation history, so a restart loses nothing the user can't ask for
/// again.
///
/// `flush` is called from two places that can overlap on the main actor —
/// the poll loop's "tick succeeded" path and the success path of any send —
/// and each `await` inside it is a suspension point where the other caller
/// runs. Before this type existed the manager's inline loop was re-entered:
/// both callers took the same first item, both awaited the send, the first
/// removed it, and the second called `removeFirst()` on an empty array — a
/// fatal Swift trap that took the whole process down right after
/// "Delivered parked reply (0 left)" (mac2 crash report, 2026-09-10), with
/// the reply delivered twice. Hence the in-progress guard and removal by
/// identity rather than by position.
@MainActor
final class ParkedOutboundQueue {
    struct Item {
        let id: UUID
        let text: String
        let address: ChannelAddress
        let parkedAt: Date
    }

    /// Memory backstop only (0.2.68: replies are never abandoned). Past this
    /// many the oldest entry is dropped with a log line; its text is in
    /// history. Realistically unreachable: a reply is parked only after its
    /// send failed, and the queue is retried until it drains.
    static let capacity = 1000

    /// Retry delays between parked-queue attempts (0.2.68 duplicate-send
    /// fix): after a failed attempt the next flush waits 30 s, then 1 min,
    /// 2 min, then every 5 min for as long as it takes. Before 0.2.68 a
    /// failed queue was retried on every successful poll tick (about once a
    /// second), and when Telegram delivered a message but its
    /// acknowledgement was lost each retry delivered another copy — one
    /// incident produced 18. The delay bounds that to a handful of copies
    /// while keeping at-least-once delivery.
    static let backoffSchedule: [TimeInterval] = [30, 60, 120, 300]

    nonisolated static func backoffDelay(afterFailures failures: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let index = min(max(failures, 1), backoffSchedule.count) - 1
        return max(backoffSchedule[index], retryAfter ?? 0)
    }

    private(set) var items: [Item] = []
    private var flushInProgress = false
    /// Failed attempts since the last successful delivery.
    private(set) var consecutiveFailures = 0
    /// Earliest time the next flush may send under the ordinary backoff;
    /// nil = due now.
    private(set) var nextAttemptAt: Date?
    /// Telegram's own minimum wait (429 `retry_after`), kept apart from the
    /// ordinary backoff (Codex round-1 finding 1): a delivery that completes
    /// meanwhile resets the backoff but never this, and a different
    /// attempt's failure cannot shorten it. Cleared once it has passed.
    private(set) var cooldownUntil: Date?
    private let now: () -> Date

    /// Selftests: a simulated clock for queues built with the default clock
    /// (the manager's), so backoff can be exercised without real waiting.
    nonisolated(unsafe) static var clockOverrideForTesting: (() -> Date)?

    init(now: @escaping () -> Date = { ParkedOutboundQueue.clockOverrideForTesting?() ?? Date() }) {
        self.now = now
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var isFlushing: Bool { flushInProgress }
    /// Whether a flush started now would send (not waiting out a backoff).
    var isDue: Bool {
        let t = now()
        if let c = cooldownUntil, t < c { return false }
        return nextAttemptAt.map { t >= $0 } ?? true
    }

    /// Records a server cooldown, never moving an existing one earlier.
    private func extendCooldown(_ retryAfter: TimeInterval?) {
        guard let retryAfter, retryAfter > 0 else { return }
        let until = now().addingTimeInterval(retryAfter)
        if let existing = cooldownUntil, existing >= until { return }
        cooldownUntil = until
    }

    /// Append (trimming only past the memory backstop) and start the backoff
    /// clock when none is running: a reply is parked because its send just
    /// failed, so the first retry waits `backoffSchedule[0]` rather than
    /// going out on the next poll tick. Returns the queue length afterwards.
    @discardableResult
    func park(_ text: String, address: ChannelAddress, at date: Date? = nil, retryAfter: TimeInterval? = nil) -> Int {
        items.append(Item(id: UUID(), text: text, address: address, parkedAt: date ?? now()))
        if items.count > Self.capacity {
            let dropped = items.count - Self.capacity
            items.removeFirst(dropped)
            print("[ConversationManager] Send queue over \(Self.capacity): dropped the \(dropped) oldest waiting repl\(dropped == 1 ? "y" : "ies") (still in conversation history)")
        }
        extendCooldown(retryAfter)
        if nextAttemptAt == nil {
            consecutiveFailures = max(consecutiveFailures, 1)
            nextAttemptAt = now().addingTimeInterval(Self.backoffDelay(afterFailures: consecutiveFailures))
        }
        return items.count
    }

    func removeAll(where predicate: (Item) -> Bool) {
        items.removeAll(where: predicate)
        if items.isEmpty { resetBackoff(); cooldownUntil = nil }
    }

    func removeAll() {
        items.removeAll()
        resetBackoff()
        cooldownUntil = nil
    }

    /// When the next flush may send (the later of backoff and cooldown).
    var nextSendAt: Date? {
        switch (nextAttemptAt, cooldownUntil) {
        case let (a?, c?): return max(a, c)
        case let (a?, nil): return a
        case let (nil, c?): return c
        default: return nil
        }
    }

    /// Ordinary backoff only; a server cooldown stays until it has passed.
    private func resetBackoff() {
        consecutiveFailures = 0
        nextAttemptAt = nil
        if let c = cooldownUntil, now() >= c { cooldownUntil = nil }
    }

    /// What a failed delivery attempt means for the queue.
    enum FailureDisposition {
        /// Keep the item and wait out the backoff (optionally at least
        /// `retryAfter` seconds, from Telegram's 429).
        case retryLater(retryAfter: TimeInterval?)
        /// Telegram refused this item permanently (HTTP 400): remove it so it
        /// cannot block every later reply forever. Its text stays in history.
        case discard
    }

    /// Re-attempt parked replies in order; stops at the first failure so a
    /// still-broken channel isn't hammered, and does nothing until the
    /// backoff after the last failure has elapsed. Items parked while a
    /// flush is in flight are picked up by the same flush. A concurrent
    /// caller returns immediately (`false`) rather than racing the loop.
    ///
    /// - Parameter deliver: sends one item; return `false` to drop it without
    ///   sending (no channel registered for its kind), throw to stop.
    /// - Parameter classify: maps a delivery error to keep-and-back-off or
    ///   discard (default: keep).
    /// - Parameter onFailed: called for every failed attempt with the error,
    ///   the failure count and the delay before the next attempt (nil when
    ///   the item was discarded) so the caller can log it.
    /// - Returns: whether this call ran the flush (false when one was already
    ///   in progress or the backoff has not elapsed).
    @discardableResult
    func flush(deliver: (Item) async throws -> Bool,
               classify: (Error) -> FailureDisposition = { _ in .retryLater(retryAfter: nil) },
               onDelivered: (Item, Int) -> Void = { _, _ in },
               onFailed: (Item, Error, Int, TimeInterval?) -> Void = { _, _, _, _ in }) async -> Bool {
        guard !flushInProgress else { return false }
        guard !items.isEmpty else { resetBackoff(); return true }
        guard isDue else { return false }
        flushInProgress = true
        defer { flushInProgress = false }
        var first = true
        while let item = items.first {
            // A cooldown recorded while an earlier send was in flight (a 429
            // on another send) holds the rest of the queue (Codex R1-1).
            if !first, let c = cooldownUntil, now() < c { return true }
            first = false
            do {
                let sent = try await deliver(item)
                // The array may have changed during the await (a park can
                // append and trim), so remove THIS item, not "the first".
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items.remove(at: index)
                }
                // A completed send proves the channel works again.
                if sent { resetBackoff(); onDelivered(item, items.count) }
            } catch {
                switch classify(error) {
                case .discard:
                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                        items.remove(at: index)
                    }
                    onFailed(item, error, consecutiveFailures + 1, nil)
                    continue
                case .retryLater(let retryAfter):
                    consecutiveFailures += 1
                    extendCooldown(retryAfter)
                    nextAttemptAt = now().addingTimeInterval(Self.backoffDelay(afterFailures: consecutiveFailures))
                    // Reported delay = the real wait, including any cooldown.
                    let wait = max(nextAttemptAt!, cooldownUntil ?? .distantPast).timeIntervalSince(now())
                    onFailed(item, error, consecutiveFailures, wait)
                    return true
                }
            }
        }
        resetBackoff()
        return true
    }
}
