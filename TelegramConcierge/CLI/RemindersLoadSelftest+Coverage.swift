import Foundation

/// L18–L22, H6: coverage notes from the plan review (round 4).
extension RemLoadHarness {
    /// A pre-rename failure is a failure even when disk already holds the
    /// attempted bytes (classification never reads the file back).
    func rowL18() async {
        await reset()
        _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "A")
        await svc._testInjectPreRenameFailure(true)
        var threw = false
        do { try await svc._testSaveChecked() } catch { threw = true }
        await svc._testInjectPreRenameFailure(false)
        check("L18 pre-rename failure with already-equal disk bytes still reports failure", threw)
    }

    /// An existing recovery file with the chosen name is never overwritten.
    func rowL19() async {
        await reset()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let now = Date()
        var squatters: [URL: Data] = [:]
        for offset in 0...2 {
            let name = "reminders.recovered-\(formatter.string(from: now.addingTimeInterval(TimeInterval(offset))))-deadbeef.json"
            let url = dataRoot.appendingPathComponent(name)
            let bytes = Data("earlier copy \(offset)".utf8)
            try? bytes.write(to: url)
            squatters[url] = bytes
        }
        await svc._testForceRecoverySuffix("deadbeef")
        let original = json([row("A"), "junk"])
        put(original)
        await svc.reloadFromDisk()
        await svc._testForceRecoverySuffix(nil)
        let intact = squatters.allSatisfy { (try? Data(contentsOf: $0.key)) == $0.value }
        let fresh = recovered().filter { squatters[$0] == nil }
        check("L19 name collision: earlier file untouched, a new exact copy made",
              intact && fresh.count == 1 && (try? Data(contentsOf: fresh[0])) == original)
    }

    /// The rejected-entries list is optional: its failure does not block and
    /// the notice does not mention it.
    func rowL20() async {
        await reset()
        await svc._testInjectRejectedListFailure(true)
        put(json([row("A"), "junk"]))
        await svc.reloadFromDisk()
        await svc._testInjectRejectedListFailure(false)
        let n = await notices()
        let blocked = await svc._testStoreBlockReason()
        check("L20 rejected-list failure: original preserved, not blocked",
              recovered().count == 1 && rejectedLists().isEmpty && blocked == nil)
        check("L20 …notice does not advertise a missing list", n.count == 1 && !n[0].contains("also listed"))
    }

    /// A notice whose persistence fails stays queued in memory; a later
    /// blocked episode gets its own notice.
    func rowL21() async {
        await reset()
        let noticesFile = dataRoot.appendingPathComponent("reminder-notices.json")
        try? FileManager.default.removeItem(at: noticesFile)
        try? FileManager.default.createDirectory(at: noticesFile, withIntermediateDirectories: false)
        put(json([row("A"), "junk"]))
        await svc._testInjectPreservationFailure(true)
        await svc.reloadFromDisk()
        let first = await notices().filter { $0.contains("kept in memory only") }.count
        try? FileManager.default.removeItem(at: noticesFile)
        await svc._testInjectPreservationFailure(false)
        _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "clears")
        put(json([row("B"), "junk2"]))
        await svc._testInjectPreservationFailure(true)
        await svc.reloadFromDisk()
        await svc._testInjectPreservationFailure(false)
        let second = await notices().filter { $0.contains("kept in memory only") }.count
        check("L21 notice kept in memory when its file cannot be written", first == 1)
        check("L21 a later blocked episode gets its own notice", second == 2)
    }

    /// A concurrent side reader always sees a complete list during saves.
    func rowL22() async {
        await reset()
        _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "seed")
        let url = file
        let state = ReaderState()
        let reader = Thread {
            while !state.stop {
                state.record(ReminderStoreFile.readValidEntries(at: url) != nil)
            }
        }
        reader.start()
        for i in 0..<40 { _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "r\(i)") }
        state.stop = true
        while !reader.isFinished { usleep(1_000) }
        check("L22 side reader never saw a torn or missing file (\(state.reads) reads)", state.reads > 0 && state.bad == 0)
    }

    /// Each call keeps its own setup, even identical calls from different
    /// requests executed in one batch.
    func rowH6() async {
        let executor = ToolExecutor()
        let function = FunctionCall(name: "manage_reminders", arguments: #"{"action":"set"}"#)
        var a = ToolCall(id: "same", type: "function", function: function)
        a.routing = .openRouterPinned(["host-a"])
        var b = ToolCall(id: "same", type: "function", function: function)
        b.routing = .openRouterPinned(["host-b"])
        let results = (try? await executor.executeParallel([a, b])) ?? []
        check("H6 identical calls keep their own request's host",
              results.count == 2 && results[0].content.contains("host-a") && results[1].content.contains("host-b"))
    }
}

final class ReaderState: @unchecked Sendable {
    private let lock = NSLock()
    private var _stop = false
    private(set) var reads = 0
    private(set) var bad = 0
    var stop: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stop }
        set { lock.lock(); _stop = newValue; lock.unlock() }
    }
    func record(_ ok: Bool) { lock.lock(); reads += 1; if !ok { bad += 1 }; lock.unlock() }
}
