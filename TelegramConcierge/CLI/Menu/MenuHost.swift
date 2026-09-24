import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The live hub: `briglia menu` while Briglia is running. The running agent
/// serves the same page (menu.html) itself, like the browser settings host:
/// no second process, no lease hand-off. Every save waits for the agent's
/// idle gate (the browser-settings mutation barrier: no turn, subagent,
/// watcher or maintenance in flight), writes through setup-api /
/// SubscriptionSetup, reloads the agent's settings and lifts the gate. Stop
/// ends the running Briglia after the page received its answer.
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
        // Saves pass the agent's idle gate and reload its settings; the
        // agent holds the instance lease, so setup-api writes as its owner.
        env.apply = { [weak manager] request, checkpoint in
            guard let manager, await manager.beginBrowserSettingsMutation() else { return MenuHost.busyAnswer }
            let result = await SetupAPICore.apply(request, ownsLease: true, checkpoint: checkpoint)
            await manager.reloadBrowserSettings()
            manager.endBrowserSettingsMutation()
            return result
        }
        env.subscription = { [weak manager] request, checkpoint in
            // Reads (status, the one-request probe) need no gate.
            guard ["select", "logout"].contains(request["action"] as? String ?? "") else {
                return await SubscriptionSetup().perform(request, ownsLease: true, checkpoint: checkpoint)
            }
            guard let manager, await manager.beginBrowserSettingsMutation() else { return MenuHost.busyAnswer }
            let result = await SubscriptionSetup().perform(request, ownsLease: true, checkpoint: checkpoint)
            await manager.reloadBrowserSettings()
            manager.endBrowserSettingsMutation()
            return result
        }
        menu = MenuWorkflow(env: env, runner: runner)
        let box = QuickSetupSession.PortBox()
        let router = QuickSetupRouter(workflow: auth, pageDirectory: directory) { box.port }
        router.menu = menu
        server = QuickSetupHTTPServer { await router.handle($0) }
        try server.start()
        box.port = server.port
        await menu.start()
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
