import Foundation

/// Daemon-startup convergence of Briglia's private runtimes (security plan
/// v24 §7.9.5). Runs once per process start, in the background, after polling
/// started. Node is selected by the Playwright bootstrap (which awaits it).
enum PrivateRuntimeStartup {
    @MainActor
    static func run(manager: ConversationManager) async {
        let log: @Sendable (String) -> Void = { print("[runtime] \($0)") }
        // The Briglia-only wrappers exist from the first start, so a skill
        // calling `briglia-python` gets a clear answer even before a venv.
        do { try PythonRuntime.ensureWrapper() } catch { log("python wrapper: \(error)") }
        let gate = idleGate(manager: manager)
        await AgentMailService.startupConvergence(idle: gate, log: log)
        let py = await PythonRuntime.converge(trigger: .auto)
        if py != .notSetUp { log("python environment: \(py)") }
    }

    /// AgentMail's commit waits for an idle Briglia and holds new turns off
    /// for its ≤ 15 s (§7.8.1 step 4), reusing the settings barrier.
    @MainActor
    static func idleGate(manager: ConversationManager) -> RuntimeIdleGate {
        RuntimeIdleGate(
            acquire: { @MainActor [weak manager] in
                let deadline = Date().addingTimeInterval(6 * 3600)
                while Date() < deadline {
                    guard let manager else { return false }
                    if await manager.beginBrowserSettingsMutation() { return true }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                return false
            },
            release: { @MainActor [weak manager] in manager?.endBrowserSettingsMutation() },
            stillWanted: { EmailCalendarProvider.current == .agentmail })
    }
}
