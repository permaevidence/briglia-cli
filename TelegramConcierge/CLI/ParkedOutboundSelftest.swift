import ArgumentParser
import Foundation

/// Hidden regression test for the parked-reply queue's reentrancy contract.
/// Reproduces the 2026-09-10 mac2 crash shape: two flushes overlap on the
/// main actor while the first delivery is suspended. Required outcome: the
/// item is delivered exactly once, the second caller is a no-op, and the
/// queue ends empty without trapping. Plus: items parked mid-flush are
/// drained by the running flush, a failing send stops the flush and keeps
/// its items, the capacity trim cannot make a delivered item's removal
/// misfire, and the /switchbot drop-by-kind path works. Pure in-memory.
struct ParkedOutboundSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__parked-outbound-selftest",
        abstract: "Internal: verify the parked-reply queue survives overlapping flushes.",
        shouldDisplay: false
    )

    @MainActor
    final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var arrivals = 0
        func wait() async {
            arrivals += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            let w = waiters; waiters.removeAll()
            w.forEach { $0.resume() }
        }
    }

    func run() async throws {
        try await MainActor.run { () -> Void in }
        try await Self.body()
    }

    @MainActor
    static func body() async throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        let tg = ChannelAddress(kind: .telegram, chatId: "1")

        // 1. The crash shape: overlapping flushes while a send is suspended.
        do {
            let queue = ParkedOutboundQueue()
            queue.park("reply-1", address: tg)
            let gate = Gate()
            var sends: [String] = []
            let deliver: (ParkedOutboundQueue.Item) async throws -> Bool = { item in
                await gate.wait()
                sends.append(item.text)
                return true
            }
            let first = Task { @MainActor in await queue.flush(deliver: deliver) }
            // Let the first flush reach its suspension point.
            for _ in 0..<50 where gate.arrivals == 0 { await Task.yield() }
            check("first flush is suspended inside the send", gate.arrivals == 1 && queue.isFlushing)
            // The overlapping caller runs as its own task so a regressed
            // (unguarded) flush fails the checks below instead of deadlocking
            // this test behind the gate.
            var secondResult: Bool? = nil
            let second = Task { @MainActor in secondResult = await queue.flush(deliver: deliver) }
            for _ in 0..<50 where secondResult == nil { await Task.yield() }
            check("second (overlapping) flush returns immediately as a no-op", secondResult == false, "\(String(describing: secondResult))")
            check("overlapping flush did not enter the send", queue.count == 1 && gate.arrivals == 1, "arrivals=\(gate.arrivals)")
            gate.release()
            let firstRan = await first.value
            _ = await second.value
            check("first flush completed", firstRan == true)
            check("item delivered exactly once", sends == ["reply-1"], "\(sends)")
            check("queue empty, no trap", queue.isEmpty && !queue.isFlushing)
        }

        // 2. Items parked during a flush are drained by that flush.
        do {
            let queue = ParkedOutboundQueue()
            queue.park("a", address: tg)
            let gate = Gate()
            var sends: [String] = []
            let task = Task { @MainActor in
                await queue.flush(deliver: { item in
                    if item.text == "a" { await gate.wait() }
                    sends.append(item.text)
                    return true
                })
            }
            for _ in 0..<50 where gate.arrivals == 0 { await Task.yield() }
            queue.park("b", address: tg)
            gate.release()
            _ = await task.value
            check("item parked mid-flush is delivered by the running flush", sends == ["a", "b"], "\(sends)")
        }

        // 3. A failing send stops the flush and keeps its items, in order.
        do {
            let queue = ParkedOutboundQueue()
            queue.park("x", address: tg); queue.park("y", address: tg)
            struct Down: Error {}
            var attempts = 0
            let ran = await queue.flush(deliver: { _ in attempts += 1; throw Down() })
            check("failing send stops after one attempt", ran && attempts == 1 && queue.count == 2)
            check("order preserved after a failed flush", queue.items.map(\.text) == ["x", "y"])
            var sends: [String] = []
            await queue.flush(deliver: { sends.append($0.text); return true })
            check("recovery delivers in order", sends == ["x", "y"] && queue.isEmpty)
        }

        // 4. Capacity trim during a suspended send removes the in-flight item
        //    from the queue; delivery still completes and nothing traps.
        do {
            let queue = ParkedOutboundQueue()
            queue.park("old", address: tg)
            let gate = Gate()
            var sends: [String] = []
            let task = Task { @MainActor in
                await queue.flush(deliver: { item in
                    if item.text == "old" { await gate.wait() }
                    sends.append(item.text)
                    return true
                })
            }
            for _ in 0..<50 where gate.arrivals == 0 { await Task.yield() }
            for i in 0..<ParkedOutboundQueue.capacity { queue.park("n\(i)", address: tg) }
            check("capacity trim dropped the in-flight item", queue.count == ParkedOutboundQueue.capacity && !queue.items.contains { $0.text == "old" })
            gate.release()
            _ = await task.value
            check("trimmed in-flight item still delivered once, rest drained", sends.first == "old" && sends.count == ParkedOutboundQueue.capacity + 1 && queue.isEmpty, "\(sends.count)")
        }

        // 5. Unregistered channel → dropped without delivery; kind-scoped drop.
        do {
            let queue = ParkedOutboundQueue()
            queue.park("t", address: tg)
            queue.park("w", address: ChannelAddress(kind: .whatsapp, chatId: "2"))
            var delivered: [String] = []
            await queue.flush(deliver: { item in
                if item.address.kind == .whatsapp { return false }
                delivered.append(item.text); return true
            }, onDelivered: { item, _ in delivered.append("+\(item.text)") })
            check("unregistered channel item dropped, others delivered with callback", delivered == ["t", "+t"] && queue.isEmpty, "\(delivered)")
            queue.park("t2", address: tg)
            queue.park("w2", address: ChannelAddress(kind: .whatsapp, chatId: "2"))
            queue.removeAll { $0.address.kind == .telegram }
            check("removeAll(where:) drops only that kind", queue.items.map(\.text) == ["w2"])
            queue.removeAll()
            check("removeAll empties", queue.isEmpty)
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        if failures > 0 { throw ExitCode.failure }
    }
}
