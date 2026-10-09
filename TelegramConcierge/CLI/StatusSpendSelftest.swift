import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden battery for the /status spend line (private-docs plan
/// CACHE_KEY_AND_IMAGE_REJECTION_PLAN v2 §4, owner decision): /status never
/// lists unknown-charge incidents; it shows exactly one line, "⏸ Paid work
/// paused — see /spend", only while a spending limit is set and unknown
/// charges pause paid work. /spend (and `briglia doctor`) keep the detail.
/// `--spend-trace` prints the /spend reply normalized, so the same command
/// built from v0.2.51 can be diffed against this build.
/// Re-executes itself in a private scratch home and preference domain.
struct StatusSpendSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__status-spend-selftest",
        abstract: "Internal: verify the /status spend line.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Flag(name: .long, help: .hidden) var spendTrace = false

    static let linkName = "briglia-mw-statusspend"
    static let rootPrefix = "briglia-status-spend-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(spendTrace: spendTrace); return }
        let h = MidturnHarness(only: nil)
        try await h.runStatusSpend(traceOnly: spendTrace)
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) status spend check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) status spend checks passed")
    }

    static func reexecIsolated(spendTrace: Bool) throws {
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
        process.arguments = ["__status-spend-selftest", "--child"] + (spendTrace ? ["--spend-trace"] : [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

extension MidturnHarness {

    func runStatusSpend(traceOnly: Bool) async throws {
        let data = StoragePaths.dataRoot.path
        guard data.contains(StatusSpendSelftest.rootPrefix),
              ProcessInfo.processInfo.processName == StatusSpendSelftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        server = try CaptureServer()
        defer { server.stop() }
        try configureProvider()
        let manager = await freshManager()
        func caps(daily: String?, monthly: String?) {
            for (key, value) in [(KeychainHelper.openRouterToolSpendLimitDailyUSDKey, daily),
                                 (KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey, monthly)] {
                if let value { try? KeychainHelper.save(key: key, value: value) } else { try? KeychainHelper.delete(key: key) }
            }
        }
        func command(_ text: String) async -> String { (await manager.handleTerminalCommand(text) ?? []).joined(separator: "\n") }
        func openIncidents(_ n: Int) {
            for i in 0..<n {
                try? ToolChargeLedger.openUnknownAmount(jobId: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i + 1))!,
                                                        day: Date(), detail: "status-spend \(i + 1)")
            }
        }
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9:]+)?", with: "<date>", options: .regularExpression)
        }
        let pausedLine = "⏸ Paid work paused — see /spend"

        if traceOnly {
            caps(daily: "10", monthly: nil)
            openIncidents(2)
            print("SPEND-TRACE " + normalized(await command("/spend")).replacingOccurrences(of: "\n", with: "\\n"))
            caps(daily: nil, monthly: nil)
            print("SPEND-TRACE " + normalized(await command("/spend")).replacingOccurrences(of: "\n", with: "\\n"))
            return
        }

        caps(daily: nil, monthly: nil)
        for n in [0, 1, 12] {
            if n > 0 { openIncidents(n) }
            let status = await command("/status")
            check("S1 no spending limit, \(n) open incident(s): /status says nothing about unknown charges",
                  !status.isEmpty && !status.contains("Spend totals") && !status.contains("Paid work paused")
                    && !status.contains("unknown amount") && !status.contains("accept-unknown"), status)
        }
        caps(daily: "10", monthly: nil)
        let paused = await command("/status")
        check("S2 daily limit + unknown charges: exactly one paused line, shown while idle, no incident text",
              paused.components(separatedBy: pausedLine).count - 1 == 1 && paused.contains("Idle")
                && !paused.contains("Spend totals") && !paused.contains("unknown amount"), paused)
        caps(daily: nil, monthly: "100")
        let monthly = await command("/status")
        check("S2b monthly limit only: the paused line too", monthly.contains(pausedLine), monthly)
        let spend = await command("/spend")
        check("S4 /spend keeps the full list and the pause sentence", spend.contains("Spend totals incomplete")
              && spend.contains("unknown amount for background job") && spend.contains("Paid work is paused"), spend)
        _ = await command("/spend accept-unknown")
        let complete = await command("/status")
        check("S3 limit set, accounting complete: no paused line", !complete.contains(pausedLine) && !complete.contains("Spend totals"), complete)
        caps(daily: nil, monthly: nil)
    }
}
