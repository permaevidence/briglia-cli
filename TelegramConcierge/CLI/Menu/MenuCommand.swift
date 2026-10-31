import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `briglia menu` — the way in for everyone: setup and settings in a page
/// in the browser. Pick how Briglia thinks (the ChatGPT subscription — the
/// default and the easiest — OpenCode Go, OpenRouter or a local model), then
/// Telegram, the web keys, the OpenAI key (optional only with ChatGPT),
/// email, and this computer's permissions and tools; start or stop Briglia. The page is served by this process on 127.0.0.1 with quick setup's
/// server and authorization (single-use link → HttpOnly cookie, exact host
/// and origin, custom header, strict CSP). Saves go through setup-api and
/// SubscriptionSetup, installers through the quick setup's own seams.
/// Reopen it any time to change something.
struct MenuCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menu",
        abstract: "Set up Briglia, change its settings, start or stop it — in your browser."
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

        // The menu never interrupts Briglia (KEYLESS_WEB_AND_LIVE_MENU plan
        // Part B): it does NOT hold the instance lease for its lifetime. When
        // Briglia runs, Briglia serves the menu itself (the live hub); when it
        // doesn't, every save takes the lease for the commit only, and a
        // Briglia that starts meanwhile takes this page over (handover).
        var serviceWasRunning = false
        // Only the legacy path below (an old Briglia that can't serve the
        // menu, Linux service paused on request) holds a lease for life.
        var legacyLease: InstanceLease?
        // A short settings commit of another process holds the lease for a
        // moment: that is not a running Briglia.
        var brigliaRunning = true
        for _ in 0..<30 {
            if case .success(let probe) = InstanceLease.acquire(label: "menu-probe") { probe.release(); brigliaRunning = false; break }
            guard InstanceLease.holderLabel() == "settings-commit" else { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if brigliaRunning {
            // Briglia is running: it serves the menu itself (the live hub),
            // so nothing has to stop. Older versions can't; fall back below.
            if let link = try? await Task.detached(operation: { try BrowserSettingsHost.requestRunningOwner(type: "menu") }).value {
                print("""

                ── Briglia menu ────────────────────────────────────────────
                Briglia is running, so it opens the menu itself. Your browser is
                opening it; if it doesn't, open this link on THIS computer:
                  \(link)

                Changes apply while Briglia keeps running. You can close this window.
                """)
                QuickSetupSession.openBrowser(link)
                return
            }
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
            legacyLease = acquired
            #else
            print("""
            Briglia is already running in another window. Close it first (press Ctrl-C in
            that window), then type: briglia menu
            """)
            throw ExitCode(1)
            #endif
        }
        // One offline menu per profile (D16).
        let menuLock: ProfileFileLock
        switch ProfileFileLock.take(StoragePaths.dataRoot.appendingPathComponent("menu.lock")) {
        case .acquired(let l): menuLock = l
        case .busy:
            legacyLease?.release()
            print("The menu is already open in another window. Use that one, or close it (Ctrl-C in its window) and type: briglia menu")
            throw ExitCode(1)
        case .failed(let why):
            legacyLease?.release()
            print("✖ \(why)")
            throw ExitCode(1)
        }
        defer { withExtendedLifetime(menuLock) {} }
        let leaseBox = QuickSetupSession.LeaseBox(legacyLease)
        func restartServiceIfPaused() {
            #if os(Linux)
            if serviceWasRunning {
                // Same health rule as `setup-api service restart`: only a
                // settled "active" a moment after the start counts.
                let result = AgentServiceSupport.run("systemctl", ["--user", "start", AgentServiceSupport.userUnitName])
                Thread.sleep(forTimeInterval: 2.0)
                let state = AgentServiceSupport.run("systemctl", ["--user", "is-active", AgentServiceSupport.userUnitName]).output
                if result.status == 0 && SetupAPICore.restartLeftUnitHealthy(isActiveOutput: state) {
                    print("✓ Briglia is running in the background again.")
                } else {
                    print("✖ Briglia didn't start again (\(result.status == 0 ? state.trimmingCharacters(in: .whitespacesAndNewlines) : result.output)).")
                    print("  See what went wrong: journalctl --user -u \(AgentServiceSupport.userUnitName) -n 40")
                    print("  Then try: briglia service install")
                }
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
        // Linux "Start Briglia": the service needs the instance lease. The
        // menu holds none (only a legacy pause, or an open pairing step,
        // which Start can't overlap), so there is nothing to take back.
        let pairing = env.pairing
        env.quick.releaseLease = { leaseBox.release(); pairing.end() }
        env.quick.reacquireLease = { legacyLease == nil ? true : leaseBox.reacquire() }

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
        var lastLeaseProbe = Date.distantPast
        var handoverStarted: Date?
        while true {
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Handover (plan B.10): a Briglia started while this page was
            // open (a terminal, the service): its own menu takes over.
            if legacyLease == nil, handoverStarted == nil, Date().timeIntervalSince(lastLeaseProbe) >= 2,
               await menu.closing == nil, !pairing.held, SettingsClient.shortCommitsInProgress == 0 {
                lastLeaseProbe = Date()
                if UnleasedInstances.probe(StoragePaths.dataRoot) == .held, !InstanceLease.isHeldInThisProcess,
                   ["daemon", "chat"].contains(InstanceLease.holderLabel() ?? "") {
                    if let link = await Self.liveHubLink() {
                        await menu.beginHandover(link: link)
                        handoverStarted = Date()
                        print("\nBriglia started, so it now serves the menu itself. The page moves there; if it doesn't, open:\n  \(link)")
                    }
                }
            }
            if let started = handoverStarted {
                if await menu.handoverDone || Date().timeIntervalSince(started) > 30 {
                    _ = await server.waitForCompletionDelivery()
                    break
                }
                continue
            }
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

        if handoverStarted != nil {
            leaseBox.release()
            print("This window can be closed.")
            return
        }
        if closing == "start" {
            #if os(macOS)
            // Start takes the lease now (the menu held none); losing the race
            // to a Briglia that started meanwhile → that Briglia runs.
            var held = leaseBox.take() ?? pairing.take()
            if held == nil {
                switch await InstanceLease.acquire(label: "chat", waitSeconds: 2) {
                case .success(let l): held = l
                case .failure:
                    if let link = await Self.liveHubLink() {
                        print("\nBriglia is already running. Its menu: \(link)")
                        QuickSetupSession.openBrowser(link)
                    } else {
                        print("\nBriglia is already running in another window.")
                    }
                    return
                }
            }
            print("\nStarting Briglia. Keep this window open (you can minimize it) and talk to it on Telegram.")
            print("To change settings later, open a new terminal window and type: briglia menu — Briglia keeps running while you do.\n")
            if let held {
                // The menu becomes the running assistant: its member lease
                // changes role without being released, then re-checks the
                // barrier and the settings admission (MULTI_ASSISTANT_PLAN §4.4).
                if let refusal = MemberEntry.promoteToAssistant(kind: "chat") {
                    held.release(); print("✖ \(refusal)"); throw ExitCode(1)
                }
                let session = await TerminalSession(sweepLeftoversAtEntry: false)
                try await session.runChat(adopting: held)
            }
            #else
            // Only reached after the page's startup passed the service health
            // check (active, starts at boot, socket answers, stable).
            print("\n✓ Briglia is running in the background and starts by itself when this computer turns on.")
            print("Talk to Briglia on Telegram. To change settings later, type: briglia menu (Briglia keeps running while you do).")
            #endif
            return
        }
        if closing == "stop" {
            // "Stop Briglia": it stays off — a paused service is not started
            // again, and on Linux it no longer starts at boot either.
            leaseBox.release()
            pairing.end()
            #if os(Linux)
            _ = AgentServiceSupport.run("systemctl", ["--user", "disable", "--now", AgentServiceSupport.userUnitName])
            print("■ Briglia is stopped and won't start by itself when this computer turns on.")
            #else
            print("■ Briglia is stopped.")
            #endif
            print("To start it again, type: briglia menu")
            return
        }
        if await menu.leaseHandedOff {
            // A failed start whose lease couldn't be taken back: the service
            // was stopped; say so instead of touching a lease we don't hold.
            print("✖ Briglia isn't running. Type briglia menu to try again.")
            return
        }
        leaseBox.release()
        pairing.end()
        restartServiceIfPaused()
        print("Your settings are saved. To change them later, type: briglia menu")
    }

    /// The running Briglia's own menu link (plan B.10): its socket is
    /// awaited up to 20 s (the lease precedes the socket); only an
    /// `http://127.0.0.1:<port>/start` link is accepted.
    static func liveHubLink() async -> String? {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let link = try? await Task.detached(operation: { try BrowserSettingsHost.requestRunningOwner(type: "menu") }).value {
                return link
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
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
