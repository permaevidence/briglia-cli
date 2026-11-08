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
/// 0.2.68 (duplicate sends): backoff schedule, permanent refusals, and a
/// lost-acknowledgement simulation through the real manager send path
/// (`ParkedOutboundSelftest+Backoff.swift`).
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

    final class SimClock { var t = Date(timeIntervalSince1970: 1_000_000) }

    /// The manager-level rows (0.2.68) build real ConversationManagers, so
    /// they run in a child re-executed in a scratch home and a throwaway
    /// preferences domain (same isolation as __stop-visibility-selftest);
    /// the queue rows stay pure and in-process.
    @Flag(name: .long, help: .hidden) var managerChild = false
    static let linkName = "briglia-mw-parked-selftest"

    func run() async throws {
        try await MainActor.run { () -> Void in }
        if managerChild {
            try await Self.managerBody()
            return
        }
        var failed = false
        do { try await Self.body() } catch { failed = true }
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required for the manager rows"); throw ExitCode(1)
        }
        let status = try Self.reexecManagerRowsIsolated()
        if failed || status != 0 { throw ExitCode.failure }
    }

    @MainActor
    static func managerBody() async throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        await managerSendRows(check: check)
        print(failures == 0 ? "ALL MANAGER ROWS PASSED" : "\(failures) MANAGER ROWS FAILED")
        if failures > 0 { throw ExitCode.failure }
    }

    static func reexecManagerRowsIsolated() throws -> Int32 {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("briglia-parked-selftest-" + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "home/.local/state", "home/.cache", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key.hasPrefix("BRIGLIA_") || key.hasPrefix("ADA_") || key.hasPrefix("SM_"))
        }
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["XDG_STATE_HOME"] = home + "/.local/state"
        env["XDG_CACHE_HOME"] = home + "/.cache"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        env["BRIGLIA_TELEGRAM_API_BASE"] = "http://127.0.0.1:9/bot"
        // `UserDefaults.standard` follows the executable name: a differently
        // named hard link (copy as fallback) gets a private domain.
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__parked-outbound-selftest", "--manager-child"]
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        _ = TestPrefsDomains.finalSweep()
        return process.terminationStatus
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
            let clk = SimClock(); let queue = ParkedOutboundQueue(now: { clk.t })
            queue.park("reply-1", address: tg)
            clk.t += 3600   // past the backoff: these cases pin reentrancy, not timing
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
            let clk = SimClock(); let queue = ParkedOutboundQueue(now: { clk.t })
            queue.park("a", address: tg)
            clk.t += 3600
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
            var clock = Date(timeIntervalSince1970: 1_000_000)
            let queue = ParkedOutboundQueue(now: { clock })
            queue.park("x", address: tg); queue.park("y", address: tg)
            struct Down: Error {}
            var attempts = 0
            clock += 30   // the first retry is due 30 s after parking
            let ran = await queue.flush(deliver: { _ in attempts += 1; throw Down() })
            check("failing send stops after one attempt", ran && attempts == 1 && queue.count == 2)
            check("order preserved after a failed flush", queue.items.map(\.text) == ["x", "y"])
            var sends: [String] = []
            clock += 60
            await queue.flush(deliver: { sends.append($0.text); return true })
            check("recovery delivers in order", sends == ["x", "y"] && queue.isEmpty)
        }

        // 4. Capacity trim during a suspended send removes the in-flight item
        //    from the queue; delivery still completes and nothing traps.
        do {
            let clk = SimClock(); let queue = ParkedOutboundQueue(now: { clk.t })
            queue.park("old", address: tg)
            clk.t += 3600
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
            let clk = SimClock(); let queue = ParkedOutboundQueue(now: { clk.t })
            queue.park("t", address: tg)
            queue.park("w", address: ChannelAddress(kind: .whatsapp, chatId: "2"))
            clk.t += 3600
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

        await backoffRows(check: check)
        await timeoutRows(check: check)

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        if failures > 0 { throw ExitCode.failure }
    }
}
