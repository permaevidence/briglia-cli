import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The live hub: `briglia menu` while Briglia is running. The running agent
/// serves the same page (menu.html) itself, like the browser settings host:
/// no second process, no lease hand-off. Every save goes through the agent's
/// single settings writer (plan Part B): applied now, or staged until the
/// agent is idle when it changes a route; the agent reloads its settings
/// itself. Stop ends the running Briglia after the page received its answer.
@MainActor
final class MenuHost {
    private static var shared: MenuHost?
    let auth: QuickSetupWorkflow
    let menu: MenuWorkflow
    let server: QuickSetupHTTPServer
    private var watcher: Task<Void, Never>?
    private var stopping = false
    private(set) var stopped = false

    /// Answer of a save refused because Briglia is busy (a turn, subagent,
    /// watcher or memory work in flight). `MenuWorkflow.applyError` shows it
    /// in the page language.
    static let busyAnswer: [String: Any] = ["ok": false, "error": ["code": "agent_busy",
        "message": "Briglia is busy with a message right now. Try again when it has answered."] as [String: Any]]

    private init(manager: ConversationManager) async throws {
        guard let directory = QuickSetupPreflight.pageDirectory(),
              ["menu.html", "menu.js", "menu.css"].allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
            throw BrowserSettingsWorkflow.Invalid(text: "The menu page is missing from this installation. Reinstall Briglia.")
        }
        var env = MenuEnvironment()
        let runner = SetupJobRunner(secrets: [:])
        auth = try QuickSetupWorkflow(env: env.quick, runner: runner, resume: .fresh)
        let mode = Self.runMode()
        env.live = MenuLive(mode: mode, stop: { MenuHost.stopRunningBriglia(mode: mode) })
        Self.wireLive(&env, manager: manager)
        menu = MenuWorkflow(env: env, runner: runner)
        let box = QuickSetupSession.PortBox()
        let router = QuickSetupRouter(workflow: auth, pageDirectory: directory) { box.port }
        router.menu = menu
        server = QuickSetupHTTPServer { await router.handle($0) }
        try server.start()
        box.port = server.port
        await menu.start()
    }

    /// The live seams (KEYLESS_WEB_AND_LIVE_MENU plan Part B): the menu's
    /// default writes are prepared in this process and committed by the
    /// agent's own settings writer (`SettingsClient.inProcessOwner`) —
    /// a key replacement applies at once, even mid-task; a change of what
    /// the model, its tools or the media and email paths use waits for an
    /// idle point (staged, shown as waiting). No save waits for an idle agent.
    static func wireLive(_ env: inout MenuEnvironment, manager: ConversationManager) {
        // Assistants page (§28.3): every action is refused while a wipe or a
        // Mind import holds the restore gate.
        env.assistants.restoreGateUp = { [weak manager] in manager?.isRestoringMind ?? false }
        env.assistants.admit = { [weak manager] in await manager?.admitAssistantsMenuOperation() ?? false }
        env.assistants.release = { [weak manager] in await manager?.endAssistantsMenuOperation() }
        env.loginBlock = { [weak manager] in
            if manager?.subscriptionLoginInProgress == true { return .telegramLogin }
            return (try? SubscriptionSetup.checkLoginReplacement()) == nil ? .activeLogin : nil
        }
    }

    /// A link to the live menu, opening it when it isn't open (a second
    /// `briglia menu` gets a fresh link; the old one stops working).
    static func open(manager: ConversationManager) async throws -> String {
        if let host = shared, !host.stopped, !host.stopping {
            _ = await host.auth.rotate()
            return await host.link()
        }
        let host = try await MenuHost(manager: manager)
        shared = host
        host.watch()
        return await host.link()
    }

    private func link() async -> String {
        "http://127.0.0.1:\(server.port)/start?t=\(await auth.launchToken)"
    }

    /// Closes the page when it said goodbye (Close or Stop) or after 30
    /// idle minutes; Stop then ends Briglia.
    private func watch() {
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                if self.menu.closing != nil {
                    _ = await self.server.waitForCompletionDelivery()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let stopBriglia = self.menu.stopRequested
                    await self.stop()
                    if stopBriglia { self.menu.env.live?.stop() }
                    return
                }
                if Date().timeIntervalSince(self.server.lastActivity) > 1800, self.menu.busy == nil {
                    await self.stop()
                    return
                }
            }
        }
    }

    func stop() async {
        if stopped { return }
        if stopping {
            while !stopped { try? await Task.sleep(nanoseconds: 50_000_000) }
            return
        }
        stopping = true
        server.stop()
        _ = await auth.rotate()
        await menu.shutdown()
        while await auth.inFlightOperations > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
        watcher?.cancel(); watcher = nil
        stopped = true
        if Self.shared === self { Self.shared = nil }
    }

    static func stopShared() async { await shared?.stop() }

    /// "service" when this Briglia is the Linux background service (systemd
    /// sets INVOCATION_ID for its units), else "terminal".
    nonisolated static func runMode(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        #if os(Linux)
        return environment["INVOCATION_ID"].map { !$0.isEmpty } == true ? "service" : "terminal"
        #else
        return "terminal"
        #endif
    }

    /// Stop from the live hub. The service is stopped and taken off boot
    /// (systemd ends this process); a terminal Briglia shuts down gracefully
    /// through its own SIGTERM path.
    nonisolated static func stopRunningBriglia(mode: String) {
        #if os(Linux)
        if mode == "service" {
            Thread.detachNewThread {
                _ = AgentServiceSupport.run("systemctl", ["--user", "disable", "--now", AgentServiceSupport.userUnitName])
            }
            return
        }
        #endif
        kill(getpid(), SIGTERM)
    }
}
