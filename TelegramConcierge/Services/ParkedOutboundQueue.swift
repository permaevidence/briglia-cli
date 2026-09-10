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

    /// Oldest entries are dropped past this many; their text is in history.
    static let capacity = 20

    private(set) var items: [Item] = []
    private var flushInProgress = false

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var isFlushing: Bool { flushInProgress }

    /// Append and trim to capacity. Returns the queue length afterwards.
    @discardableResult
    func park(_ text: String, address: ChannelAddress, at date: Date = Date()) -> Int {
        items.append(Item(id: UUID(), text: text, address: address, parkedAt: date))
        if items.count > Self.capacity {
            items.removeFirst(items.count - Self.capacity)
        }
        return items.count
    }

    func removeAll(where predicate: (Item) -> Bool) {
        items.removeAll(where: predicate)
    }

    func removeAll() {
        items.removeAll()
    }

    /// Re-attempt parked replies in order; stops at the first failure so a
    /// still-broken channel isn't hammered. Items parked while a flush is in
    /// flight are picked up by the same flush. A concurrent caller returns
    /// immediately (`false`) rather than racing the loop.
    ///
    /// - Parameter deliver: sends one item; return `false` to drop it without
    ///   sending (no channel registered for its kind), throw to stop.
    /// - Returns: whether this call ran the flush (false when one was already
    ///   in progress).
    @discardableResult
    func flush(deliver: (Item) async throws -> Bool,
               onDelivered: (Item, Int) -> Void = { _, _ in }) async -> Bool {
        guard !flushInProgress else { return false }
        guard !items.isEmpty else { return true }
        flushInProgress = true
        defer { flushInProgress = false }
        while let item = items.first {
            do {
                let sent = try await deliver(item)
                // The array may have changed during the await (a park can
                // append and trim), so remove THIS item, not "the first".
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items.remove(at: index)
                }
                if sent { onDelivered(item, items.count) }
            } catch {
                return true
            }
        }
        return true
    }
}
