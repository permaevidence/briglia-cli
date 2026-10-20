import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Crash/kill reconstruction (§16.5, Codex implementation review answer 4;
/// the retiring phase added for round 3):
/// a child process (same scratch home) reaches a job phase and is killed
/// with SIGKILL; a fresh manager over the same disk must carry no job, load
/// the last saved history (nothing half-applied, no description saved by
/// the worker), keep the freeze snapshot as an ordinary snapshot, and
/// freeze again normally at the next over-maximum boundary.
enum BackgroundPruneSelftestCrash {
    static let readyMarker = "BGPRUNE-CRASH-READY"

    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        for phase in ["running", "ready", "applying", "retiring"] {
            await crash(h, phase: phase)
        }
    }

    /// Child side: reach `phase`, announce it, then wait to be killed.
    @MainActor static func child(_ h: BackgroundPruneSelftestHarness, phase: String) async {
        // Share the parent's description store so the parent can check it.
        if let store = ProcessInfo.processInfo.environment["BGPRUNE_CRASH_STORE"] {
            FileDescriptionsStore._testStoreURL = URL(fileURLWithPath: store)
        }
        try? h.configureProvider()
        let manager = await h.freshManager(history: BackgroundPruneSelftestLifecycle.describableHistory(h, file: "crash.txt"))
        switch phase {
        case "running":
            _ = await h.frozenRunningJob(manager)
        case "ready":
            _ = await h.frozenRunningJob(manager, holdSummary: false)
            _ = await h.waitPhase(manager, "ready")
        case "retiring":
            // The deadline fires while the worker ignores cancellation: the
            // job is retiring (slot still occupied) when the process dies.
            let worker = BackgroundPruneSelftestGate()
            ConversationManager.bgPruneHoldForTesting = { point in if point == "worker.summary" { await worker.awaitRelease() } }
            ConversationManager.bgPruneDeadlineSecondsForTesting = 0.5
            _ = await h.frozenRunningJob(manager)
            _ = await h.waitUntil(timeout: 30) { manager.bgPruneTestPhase.hasPrefix("retiring") }
        default:
            _ = await h.frozenRunningJob(manager, holdSummary: false)
            _ = await h.waitPhase(manager, "ready")
            let applyGate = BackgroundPruneSelftestGate()
            ConversationManager.bgPruneHoldForTesting = { point in if point == "apply.save" { await applyGate.awaitRelease() } }
            manager.bgPruneTestSetLastPromptTokens(1_000)
            h.startTurn(manager, "apply, killed during the description save", replies: [BackgroundPruneSelftestHarness.chat("never", prompt: 100)])
            _ = await h.waitUntil(timeout: 30) { applyGate.arrived == 1 }
        }
        print("\(readyMarker) \(manager.bgPruneTestPhase)")
        fflush(stdout)
        while true { try? await Task.sleep(nanoseconds: 1_000_000_000) }
    }

    @MainActor static func crash(_ h: BackgroundPruneSelftestHarness, phase: String) async {
        await h.resetState(switchOn: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["__background-prune-selftest", "--child", "--crash", phase]
        var env = ProcessInfo.processInfo.environment
        env["BGPRUNE_CRASH_STORE"] = h.filesRoot.appendingPathComponent("descriptions.json").path
        env["BGPRUNE_FILES_ROOT"] = h.filesRoot.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let output = BackgroundPruneSelftestLog()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(String(decoding: data, as: UTF8.self)) }
        }
        do { try process.run() } catch {
            h.check("crash [\(phase)] child started", false, "\(error)")
            return
        }
        let reached = await h.waitUntil(timeout: 60) { output.all.joined().contains(readyMarker) }
        let reportedPhase = output.all.joined().components(separatedBy: readyMarker + " ").last?.split(separator: "\n").first.map(String.init) ?? "?"
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        h.check("crash [\(phase)] child reached the phase and was killed (SIGKILL)",
                reached && process.terminationReason == .uncaughtSignal && reportedPhase.hasPrefix(phase), "reported \(reportedPhase)")
        // The child pointed the provider at its own (now dead) server.
        try? h.configureProvider()
        let disk = h.diskHistory()
        let snapshotsBefore = (try? FileManager.default.contentsOfDirectory(atPath: PruneArchiveStore.root.path)) ?? []
        let restarted = ConversationManager()
        await restarted._testPrepareScriptedProvider(apiKey: h.apiKey)
        restarted._svRegisterChannel(h.channel)
        restarted._svSetLastUserAddress(h.telegramAddress)
        let description = await restarted.bgPruneTestDescription("crash.txt")
        h.check("crash [\(phase)] reconstruction: no job, history as last saved, nothing half-applied",
                restarted.bgPruneTestPhase == "none" && !disk.isEmpty && h.encoded(restarted._testMessages) == h.encoded(disk)
                && h.prunedIds(restarted).isEmpty && !restarted.bgPruneTestFallbackDue,
                "phase \(restarted.bgPruneTestPhase) disk \(disk.count) pruned \(h.prunedIds(restarted).count)")
        h.check("crash [\(phase)] no description was saved by the killed job", description == nil, String(describing: description))
        h.check("crash [\(phase)] the freeze snapshot stays on disk as an ordinary snapshot", !snapshotsBefore.isEmpty)
        h.clearEvents()
        restarted.bgPruneTestSetLastPromptTokens(60_000)
        h.server.script([BackgroundPruneSelftestHarness.chat("after the crash", prompt: 100)])
        restarted._testStartTurn(for: Message(role: .user, content: "over the maximum after the crash"))
        _ = await restarted._testAwaitIdle(timeout: 40)
        h.check("crash [\(phase)] the next over-maximum boundary freezes normally", h.eventCount("bgprune.freeze.pre-request") == 1
                && restarted._testLastError == nil, "\(h.allEvents)")
        h.router.gate.release()
        _ = await h.waitUntil { restarted.bgPruneTestPhase != "running" }
    }
}
