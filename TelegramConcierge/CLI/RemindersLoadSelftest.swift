import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Hidden battery for 0.2.63 (REMINDERS_LOAD_AND_ARG_HINT_PLAN §3):
/// reminders.json loads per entry and is never overwritten before it was
/// loaded or preserved (L rows, +Rows / +Store files), and missing-argument
/// tool errors name the keys that arrived (H rows, +Hint file). Isolation:
/// re-executes itself in a private scratch home under a differently named
/// hard link, like the image-orientation battery; the live install is never
/// touched.
struct RemindersLoadSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__reminders-load-selftest",
        abstract: "Internal: verify per-entry reminders.json loading and the missing-argument hint.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false

    static let linkName = "briglia-mw-remload"
    static let rootPrefix = "briglia-reminders-load-"

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(); return }
        let data = StoragePaths.dataRoot.path
        guard data.contains(Self.rootPrefix), ProcessInfo.processInfo.processName == Self.linkName else {
            print("✖ refusing to run outside the isolated scratch home (data root \(data))")
            throw ExitCode(1)
        }
        let h = RemLoadHarness()
        await h.runAll()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) reminders-load check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) reminders-load checks passed")
    }

    static func reexecIsolated() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__reminders-load-selftest", "--child"]
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// Check bookkeeping, fixtures and per-row reset.
final class RemLoadHarness {
    var total = 0
    var failures = 0
    let svc = ReminderService.shared

    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok {
            print("  ✔ \(label)")
        } else {
            failures += 1
            let d = detail()
            print("  ✖ \(label)\(d.isEmpty ? "" : " — \(d)")")
        }
    }

    var dataRoot: URL { StoragePaths.dataRoot }
    var file: URL { dataRoot.appendingPathComponent("reminders.json") }

    /// A valid reminder row as the store encodes it.
    func row(_ prompt: String, id: UUID = UUID(), triggered: Bool = false) -> [String: Any] {
        var reminder = Reminder(id: id, triggerDate: Date().addingTimeInterval(3_600), prompt: prompt)
        reminder.triggered = triggered
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(reminder)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .fragmentsAllowed])
    }

    func put(_ data: Data) {
        try? FileManager.default.removeItem(at: file)
        try! data.write(to: file)
    }

    func diskBytes() -> Data? { try? Data(contentsOf: file) }

    /// Strict decode of the current file (what v0.2.62 readers do).
    func diskRows() -> [Reminder]? {
        guard let data = diskBytes() else { return nil }
        return try? ReminderStoreFile.makeDecoder().decode([Reminder].self, from: data)
    }

    func recovery() -> [URL] { ReminderService.recoveryFileURLs(in: dataRoot) ?? [] }
    func recovered() -> [URL] { recovery().filter { $0.lastPathComponent.hasPrefix("reminders.recovered-") } }
    func rejectedLists() -> [URL] { recovery().filter { $0.lastPathComponent.hasPrefix("reminders.rejected-") } }

    func mode(_ url: URL) -> mode_t {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        return st.st_mode & 0o777
    }

    func memoryIds() async -> Set<UUID> { Set(await svc._testAllReminders().map { $0.id }) }

    func notices() async -> [String] { await svc.pendingCreationNotices() }

    /// Clean slate for each row: no file, no recovery copies, no notices, no
    /// seams, store reloaded (resets every bit of reconciliation state).
    func reset() async {
        await svc._testInjectPreservationFailure(false)
        await svc._testInjectPostRenameFailure(false)
        await svc._testInjectPreRenameFailure(false)
        await svc._testInjectCheckedSaveFailure(false)
        let fm = FileManager.default
        for url in recovery() { try? fm.removeItem(at: url) }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: file.path, isDirectory: &isDir) {
            if isDir.boolValue { chmod(file.path, 0o700) }
            try? fm.removeItem(at: file)
        }
        let pending = await svc.pendingCreationNotices().count
        await svc.confirmCreationNoticesSent(count: pending)
        await svc.reloadFromDisk()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func runAll() async {
        print("L — reminders.json per-entry load")
        await rowL1()
        await rowL2to4()
        await rowL5()
        print("L6 — blocked store, removals, merges, write failures")
        await rowL6a()
        await rowL6b()
        await rowL6c()
        await rowL6d()
        print("L7–L17 — single write, resets, names, file types, purge, outside edits, wipe, readers")
        await rowL7()
        await rowL8()
        await rowL9()
        await rowL10()
        await rowL11()
        await rowL12()
        await rowL13()
        await rowL14()
        await rowL14b()
        await rowL15()
        await rowL16()
        await rowL17()
        await rowL18()
        await rowL19()
        await rowL20()
        await rowL21()
        await rowL22()
        print("H — missing-argument hint")
        rowH1()
        rowH2()
        await rowH3()
        rowH4()
        await rowH5()
        await rowH6()
        await reset()
    }
}
