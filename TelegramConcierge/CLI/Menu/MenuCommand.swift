import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `briglia menu` — setup and settings for people who use their ChatGPT
/// subscription, in a page in the browser: sign in, Telegram, the web keys,
/// optional voice/images and email, and this computer's permissions and
/// tools. The page is served by this process on 127.0.0.1 with quick setup's
/// server and authorization (single-use link → HttpOnly cookie, exact host
/// and origin, custom header, strict CSP). Saves go through setup-api and
/// SubscriptionSetup, installers through the quick setup's own seams.
/// Reopen it any time to change something.
struct MenuCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menu",
        abstract: "Easy setup and settings in your browser, for ChatGPT subscribers."
    )

    func run() async throws {
        AdaCLI.prepareIO()
        try IdentityMigration.gateMutatingEntry()
        IdentityMigration.warnLegacyEnvironment()
        QuickSetupSession.applyPreflightDevStubsIfRequested()
        if QuickSetupPreflight.isUbuntuTouchOverride ?? AgentServiceSupport.isUbuntuTouch() {
            print("On a phone, use the Briglia app instead.")
            throw ExitCode(2)
        }
        guard let pageDir = QuickSetupPreflight.pageDirectory() else {
            print("✖ The menu page is missing from this installation — reinstall Briglia.")
            throw ExitCode(2)
        }

        // One instance at a time: the menu writes the settings the agent
        // reads, and signing in switches the provider — both need the lease.
        var serviceWasRunning = false
        let lease: InstanceLease
        switch InstanceLease.acquire(label: "menu") {
        case .success(let held):
            lease = held
        case .failure:
            #if os(Linux)
            guard Self.serviceActive() else {
                print("""
                Briglia is already running (in another terminal window or as `briglia daemon`).
                Stop it first — press Ctrl-C in its window — then type: briglia menu
                """)
                throw ExitCode(1)
            }
            print("Briglia is running in the background.")
            guard WizardIO.askYesNo("Pause it while you change settings? It starts again when you close the menu.", default: true) else {
                print("Nothing changed.")
                return
            }
            _ = AgentServiceSupport.run("systemctl", ["--user", "stop", AgentServiceSupport.userUnitName])
            serviceWasRunning = true
            var acquired: InstanceLease?
            for _ in 0..<40 {
                if case .success(let held) = InstanceLease.acquire(label: "menu") { acquired = held; break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard let acquired else {
                print("Briglia didn't stop in time. Starting it again; try `briglia menu` in a minute.")
                _ = AgentServiceSupport.run("systemctl", ["--user", "start", AgentServiceSupport.userUnitName])
                throw ExitCode(1)
            }
            lease = acquired
            #else
            print("""
            Briglia is already running in another window. Close it first (press Ctrl-C in
            that window), then type: briglia menu
            """)
            throw ExitCode(1)
            #endif
        }
        let leaseBox = QuickSetupSession.LeaseBox(lease)
        func restartServiceIfPaused() {
            #if os(Linux)
            if serviceWasRunning {
                let result = AgentServiceSupport.run("systemctl", ["--user", "start", AgentServiceSupport.userUnitName])
                print(result.status == 0 ? "✓ Briglia is running in the background again." : "✖ Couldn't start Briglia again: \(result.output)\n  Try: briglia service install")
            }
            #endif
        }

        KeepAwake.holdForProcessLifetime()
        let runner = SetupJobRunner(secrets: [:])
        if let poison = SetupJobRunner.inheritLeftoverJournal(into: runner) {
            QuickSetupSession.printPoison(poison)
        }
        var env = MenuEnvironment()
        QuickSetupEnvironment.applyDevStubsIfRequested(&env.quick)
        env.openURL = { QuickSetupSession.openBrowser($0) }

        // Authorization (link, cookie, generations) is the quick setup's.
        let auth: QuickSetupWorkflow
        do { auth = try QuickSetupWorkflow(env: env.quick, runner: runner, resume: .fresh) } catch {
            print("✖ \(error.localizedDescription)")
            leaseBox.release(); restartServiceIfPaused()
            throw ExitCode(2)
        }
        let menu = await MenuWorkflow(env: env, runner: runner, serviceWasRunning: serviceWasRunning)
        await menu.start()

        let portBox = QuickSetupSession.PortBox()
        let router = QuickSetupRouter(workflow: auth, pageDirectory: pageDir) { portBox.port }
        router.menu = menu
        let server = QuickSetupHTTPServer { await router.handle($0) }
        do { try server.start() } catch {
            print("✖ Could not start the local page: \(error)")
            leaseBox.release(); restartServiceIfPaused()
            throw ExitCode(2)
        }
        portBox.port = server.port

        let listener = EnterListener {
            Task {
                _ = await auth.rotate()
                await Self.printLink(auth: auth, port: server.port, open: true, again: true)
            }
        }
        runner.listener = listener
        await Self.printLink(auth: auth, port: server.port, open: true, again: false)
        listener.start()

        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigSource.setEventHandler {
            print("\nClosing the menu… (everything you saved is kept)")
            Task {
                _ = await auth.rotate()
                await menu.shutdown()
                server.stop()
                listener.stop()
                leaseBox.release()
                restartServiceIfPaused()
                Foundation.exit(130)
            }
        }
        sigSource.resume()

        var closing: String?
        while true {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let c = await menu.closing {
                closing = c
                _ = await server.waitForCompletionDelivery()
                try? await Task.sleep(nanoseconds: 300_000_000)
                break
            }
            if Date().timeIntervalSince(server.lastActivity) > 3600, await menu.busy == nil {
                print("\nNo activity for an hour — closing the menu. Type `briglia menu` to open it again.")
                break
            }
        }
        await menu.shutdown()
        server.stop()
        listener.stop()
        sigSource.cancel()
        signal(SIGINT, SIG_DFL)

        if closing == "start" {
            #if os(macOS)
            print("\nStarting Briglia. Keep this window open (you can minimize it) and talk to it on Telegram.")
            print("To change settings later, quit Briglia (Ctrl-C) and type: briglia menu\n")
            if let held = leaseBox.take() {
                let session = await TerminalSession(sweepLeftoversAtEntry: false)
                try await session.runChat(adopting: held)
            }
            #else
            leaseBox.release()
            print("\nStarting Briglia in the background…")
            _ = AgentServiceSupport.installUserService()
            AgentServiceSupport.offerUbuntuTouchKeepAwake()
            print("\nDone. Talk to Briglia on Telegram. To change settings later, type: briglia menu")
            #endif
            return
        }
        leaseBox.release()
        restartServiceIfPaused()
        print("Your settings are saved. To change them later, type: briglia menu")
    }

    #if os(Linux)
    static func serviceActive() -> Bool {
        AgentServiceSupport.run("systemctl", ["--user", "is-active", AgentServiceSupport.userUnitName])
            .output.trimmingCharacters(in: .whitespacesAndNewlines) == "active"
    }
    #endif

    static func printLink(auth: QuickSetupWorkflow, port: UInt16, open: Bool, again: Bool) async {
        let token = await auth.launchToken
        guard !token.isEmpty else {
            print("✖ Cannot create a secure link on this system. Press Ctrl-C and type `briglia menu` again.")
            return
        }
        let url = "http://127.0.0.1:\(port)/start?t=\(token)"
        if again {
            print("\nNew link (the old one no longer works):\n  \(url)")
        } else {
            print("""

            ── Briglia menu ────────────────────────────────────────────
            Your browser is opening the Briglia menu. If it doesn't, open
            this link in a browser on THIS computer (it works once, for 5 minutes):
              \(url)

            Keep this window open while you use the menu.
            Press Enter here for a new link · Ctrl-C closes the menu (what you saved is kept).
            """)
        }
        if open { QuickSetupSession.openBrowser(url) }
    }
}
