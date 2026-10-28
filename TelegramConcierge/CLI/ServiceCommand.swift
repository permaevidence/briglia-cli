import ArgumentParser
import Foundation

// MARK: - `briglia service` — always-on Briglia as a systemd user service (Linux)
//
// Replaces the hand-written unit files from the Raspberry Pi and Pixel 3a
// (Ubuntu Touch) setups: `briglia service install` writes the user unit, enables
// linger so it survives logout/boot, starts it, and — on Ubuntu Touch — also
// offers the kernel-wakelock system unit that keeps the phone from suspending
// when the screen turns off (repowerd's session inhibitor fails there with
// NoSessionForPID, observed on the Pixel 3a install of 2026-08-14).
//
// The text/detection helpers are platform-independent and pure so the
// selftest exercises them on macOS too; everything that talks to systemd is
// Linux-only.

enum AgentServiceSupport {
    static let userUnitName = "briglia.service"
    static let wakelockUnitName = "briglia-keepawake.service"
    static let wakelockName = "briglia-keepawake"
    static let wakelockUnitPath = "/etc/systemd/system/briglia-keepawake.service"

    static func userUnitDirectory(home: String) -> String {
        home + "/.config/systemd/user"
    }

    /// The systemd user unit running `briglia daemon`. Mirrors the field set
    /// proven on the Pixel 3a / Raspberry Pi manual installs: restart on
    /// crash, SIGINT for Briglia's own graceful shutdown path, and a PATH that
    /// resolves the ada binary's own directory first (self-upgrade swaps the
    /// binary in place there).
    static func userUnitText(adaPath: String, home: String) -> String {
        let binDir = (adaPath as NSString).deletingLastPathComponent
        return """
        [Unit]
        Description=Briglia CLI Telegram daemon

        [Service]
        Type=simple
        ExecStart="\(adaPath)" daemon
        WorkingDirectory=\(home)
        Environment="HOME=\(home)"
        Environment="PATH=\(binDir):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        Restart=always
        RestartSec=5
        KillSignal=SIGINT
        TimeoutStopSec=30

        [Install]
        WantedBy=default.target

        """
    }

    // MARK: Extra assistants (MULTI_ASSISTANT_PLAN §4.2)

    /// One systemd template for every extra assistant; the instance name is
    /// the profile id. Default keeps `briglia.service` exactly.
    static let templateUnitName = "briglia@.service"
    static func extraUnitName(_ profile: String) -> String { "briglia@\(profile).service" }

    /// The template passes `--profile %i` in argv (never only in the
    /// environment: an older binary then fails to parse instead of acting on
    /// default's data, §13). While assistants are experimental the unit also
    /// carries the experimental switch.
    static func templateUnitText(adaPath: String, home: String) -> String {
        let binDir = (adaPath as NSString).deletingLastPathComponent
        return """
        [Unit]
        Description=Briglia CLI assistant %i

        [Service]
        Type=simple
        ExecStart="\(adaPath)" --profile %i daemon
        WorkingDirectory=\(home)
        Environment="HOME=\(home)"
        Environment="PATH=\(binDir):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        Environment="\(AssistantProfile.experimentalKey)=1"
        Restart=always
        RestartSec=5
        KillSignal=SIGINT
        TimeoutStopSec=30

        [Install]
        WantedBy=default.target

        """
    }

    static func templateUnitPath(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        userUnitDirectory(home: home) + "/" + templateUnitName
    }

    #if os(Linux)
    /// Install (or refresh) the template and enable `briglia@<profile>`.
    static func installExtraService(_ profile: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let unitDir = userUnitDirectory(home: home)
        guard PlatformBinary.find("systemctl") != nil else {
            print("  ✖ systemctl not found — this system doesn't run systemd.")
            return false
        }
        do {
            try FileManager.default.createDirectory(atPath: unitDir, withIntermediateDirectories: true)
            try templateUnitText(adaPath: adaExecutablePath(), home: home)
                .write(toFile: templateUnitPath(home: home), atomically: true, encoding: .utf8)
            print("  ✔ wrote \(templateUnitPath(home: home))")
        } catch {
            print("  ✖ could not write the unit template: \(error.localizedDescription)")
            return false
        }
        var step = run("systemctl", ["--user", "daemon-reload"])
        guard step.status == 0 else { print("  ✖ systemctl --user daemon-reload failed: \(step.output)"); return false }
        step = run("systemctl", ["--user", "enable", "--now", extraUnitName(profile)])
        guard step.status == 0 else { print("  ✖ enable --now failed: \(step.output)"); return false }
        print("  ✔ \(extraUnitName(profile)) enabled and started")
        if !lingerEnabled() {
            print("  ⚠ linger is off — enable it once from the default assistant (`briglia service install`) or: sudo loginctl enable-linger \(NSUserName())")
        }
        return true
    }

    /// Disable `briglia@<profile>`; the template (machine-wide) is removed
    /// only when no other extra's unit is still enabled.
    static func uninstallExtraService(_ profile: String, others: [String]) {
        _ = run("systemctl", ["--user", "disable", "--now", extraUnitName(profile)])
        let stillUsed = others.contains { run("systemctl", ["--user", "is-enabled", extraUnitName($0)]).output == "enabled" }
        if !stillUsed { try? FileManager.default.removeItem(atPath: templateUnitPath()) }
        _ = run("systemctl", ["--user", "daemon-reload"])
    }
    #endif

    /// `profiles remove`: disable the extra's unit when one exists (Linux);
    /// nothing on macOS (the supervisor reads the registry).
    static func disableExtraUnitIfPresent(_ profile: String) {
        #if os(Linux)
        guard FileManager.default.fileExists(atPath: templateUnitPath()) else { return }
        let others = AssistantProfile.listExtras().filter { $0 != profile }
        uninstallExtraService(profile, others: others)
        #endif
    }

    /// The Ubuntu Touch keep-awake unit: holds a kernel wakelock so the
    /// phone never fully suspends while Briglia should stay reachable. Gated on
    /// the Android wakelock sysfs interface actually existing.
    static func wakelockUnitText() -> String {
        """
        [Unit]
        Description=Keep the phone awake for Briglia CLI
        After=local-fs.target
        ConditionPathExists=/sys/power/wake_lock
        ConditionPathExists=/sys/power/wake_unlock

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/bin/sh -c 'printf "%s\\n" \(wakelockName) > /sys/power/wake_lock'
        ExecStop=/bin/sh -c 'printf "%s\\n" \(wakelockName) > /sys/power/wake_unlock'

        [Install]
        WantedBy=multi-user.target

        """
    }

    /// Ubuntu Touch detection. os-release reports plain "Ubuntu 24.04", so
    /// probe UT-specific filesystem markers instead: the system-image OTA
    /// machinery, the Lomiri session, or the Halium /android tree combined
    /// with UT's fixed `phablet` user. Parameterized for tests.
    static func isUbuntuTouch(rootPrefix: String = "", userName: String = NSUserName()) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: rootPrefix + "/etc/system-image") { return true }
        if fm.fileExists(atPath: rootPrefix + "/usr/bin/system-image-cli") { return true }
        if fm.fileExists(atPath: rootPrefix + "/etc/ubuntu-touch-session.d") { return true }
        if fm.fileExists(atPath: rootPrefix + "/usr/bin/lomiri-session") { return true }
        if userName == "phablet" && fm.fileExists(atPath: rootPrefix + "/android") { return true }
        return false
    }

    /// Whether the kernel exposes the Android wakelock interface the
    /// keep-awake unit writes to.
    static func wakeLockSupported(rootPrefix: String = "") -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: rootPrefix + "/sys/power/wake_lock")
            && fm.fileExists(atPath: rootPrefix + "/sys/power/wake_unlock")
    }

    #if os(Linux)
    /// Resolve the real installed ada executable (argv[0] may be a bare
    /// PATH-resolved name; /proc/self/exe via Bundle.main is authoritative).
    static func adaExecutablePath() -> String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }

    /// Run a non-interactive command, capturing merged output. Never
    /// prompts; systemctl/loginctl/journalctl calls all return promptly
    /// (journalctl only with --no-pager) and produce small output, so a
    /// plain read-then-wait is safe here.
    @discardableResult
    static func run(_ executable: String, _ args: [String])
        -> (status: Int32, output: String) {
        guard let path = PlatformBinary.find(executable) else { return (127, "\(executable): not found") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return (127, "\(executable): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, out)
    }

    /// Run `sudo <args…>` interactively — the terminal is lent to the child
    /// so the password/PIN prompt works (TerminalHandoff; a plain spawn
    /// leaves sudo in a background process group and SIGTTIN-freezes it).
    static func runInteractiveSudo(_ args: [String]) -> Bool {
        guard let sudo = PlatformBinary.find("sudo") else {
            print("  ✖ sudo not found")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sudo)
        process.arguments = args
        do { try TerminalHandoff.runLendingForeground(process) } catch {
            print("  ✖ failed to launch sudo: \(error.localizedDescription)")
            return false
        }
        return process.terminationStatus == 0
    }

    static func systemdUserSessionAvailable() -> Bool {
        run("systemctl", ["--user", "is-system-running"]).status != 127
            && !run("systemctl", ["--user", "show-environment"]).output
                .contains("Failed to connect to bus")
    }

    static func lingerEnabled() -> Bool {
        run("loginctl", ["show-user", NSUserName(), "-p", "Linger"])
            .output.contains("Linger=yes")
    }

    /// Install (or refresh) the user unit and start it. Returns true when
    /// the service ends up enabled; prints its own progress.
    ///
    /// `interactiveSudoFallback: false` (the setup-api path) skips the
    /// terminal-lending sudo fallback for linger — a GUI caller has no
    /// terminal to lend, so it gets the exact command to run under its own
    /// sudo instead (setup-api reports it as `linger_command`).
    static func installUserService(interactiveSudoFallback: Bool = true) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let adaPath = adaExecutablePath()
        let unitDir = userUnitDirectory(home: home)
        let unitPath = unitDir + "/" + userUnitName

        guard PlatformBinary.find("systemctl") != nil else {
            print("  ✖ systemctl not found — this system doesn't run systemd.")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                atPath: unitDir, withIntermediateDirectories: true)
            try userUnitText(adaPath: adaPath, home: home)
                .write(toFile: unitPath, atomically: true, encoding: .utf8)
            print("  ✔ wrote \(unitPath)")
        } catch {
            print("  ✖ could not write \(unitPath): \(error.localizedDescription)")
            return false
        }

        var step = run("systemctl", ["--user", "daemon-reload"])
        if step.status != 0 {
            print("  ✖ systemctl --user daemon-reload failed: \(step.output)")
            print("    (no systemd user session? On a headless box, log in once or reboot.)")
            return false
        }
        step = run("systemctl", ["--user", "enable", "--now", userUnitName])
        guard step.status == 0 else {
            print("  ✖ enable --now failed: \(step.output)")
            return false
        }
        print("  ✔ service enabled and started")

        // Linger: without it, the user's systemd session — and Briglia with it —
        // only exists while logged in, and nothing starts at boot.
        if lingerEnabled() {
            print("  ✔ linger already enabled (starts at boot, survives logout)")
        } else {
            _ = run("loginctl", ["enable-linger", NSUserName()])
            if lingerEnabled() {
                print("  ✔ linger enabled (starts at boot, survives logout)")
            } else if interactiveSudoFallback {
                print("  linger needs root on this system — asking sudo…")
                if runInteractiveSudo(["loginctl", "enable-linger", NSUserName()]), lingerEnabled() {
                    print("  ✔ linger enabled (starts at boot, survives logout)")
                } else {
                    print("  ⚠ could not enable linger — Briglia will stop at logout/reboot.")
                    print("    Enable it manually: sudo loginctl enable-linger \(NSUserName())")
                }
            } else {
                print("  ⚠ linger needs root — run: sudo loginctl enable-linger \(NSUserName())")
            }
        }

        // Give the daemon a moment, then report what actually happened —
        // Restart=always would otherwise hide a crash-loop behind "active".
        Thread.sleep(forTimeInterval: 2.0)
        let active = run("systemctl", ["--user", "is-active", userUnitName]).output
        if active == "active" {
            print("  ✔ briglia daemon is running")
        } else {
            print("  ⚠ service state: \(active) — inspect with:")
            print("    journalctl --user -u \(userUnitName) -n 50 --no-pager")
            print("    (an `briglia` chat session in another terminal blocks the daemon: same instance lock)")
        }
        return true
    }

    /// Ubuntu Touch only: install the keep-awake system unit. Interactive
    /// (sudo PIN, read-write remount of the normally read-only root fs).
    static func installWakelockService() -> Bool {
        // The sysfs nodes are root-owned on some Halium kernels; re-check
        // through sudo before declaring the interface absent.
        if !wakeLockSupported() {
            let visible = runInteractiveSudo(["test", "-e", "/sys/power/wake_lock"])
                && runInteractiveSudo(["test", "-e", "/sys/power/wake_unlock"])
            guard visible else {
                print("  ✖ this kernel has no /sys/power/wake_lock interface — keep-awake unit not applicable.")
                return false
            }
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("briglia-keepawake-\(UUID().uuidString).service")
        do {
            try wakelockUnitText().write(to: temp, atomically: true, encoding: .utf8)
        } catch {
            print("  ✖ could not stage unit file: \(error.localizedDescription)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        print("  Remounting / read-write (Ubuntu Touch keeps it read-only; an OTA may later remove this unit)…")
        guard runInteractiveSudo(["mount", "-o", "remount,rw", "/"]) else {
            print("  ✖ remount failed — keep-awake unit not installed.")
            return false
        }
        var ok = runInteractiveSudo(["cp", temp.path, wakelockUnitPath])
            && runInteractiveSudo(["chmod", "644", wakelockUnitPath])
            && runInteractiveSudo(["systemctl", "daemon-reload"])
            && runInteractiveSudo(["systemctl", "enable", "--now", wakelockUnitName])
        if ok {
            print("  ✔ keep-awake unit installed and active (kernel wakelock '\(wakelockName)')")
        } else {
            print("  ✖ keep-awake unit installation failed — the phone will suspend on screen-off.")
        }
        if !runInteractiveSudo(["mount", "-o", "remount,ro", "/"]) {
            print("  ⚠ could not remount / read-only (busy) — a reboot restores it automatically.")
        }
        return ok
    }

    static func wakelockUnitInstalled() -> Bool {
        FileManager.default.fileExists(atPath: wakelockUnitPath)
    }

    /// Shared Ubuntu Touch keep-awake offer (used by `briglia service install`
    /// and the setup wizard's service step). No-op off Ubuntu Touch.
    static func offerUbuntuTouchKeepAwake() {
        guard isUbuntuTouch(), !wakelockUnitInstalled() else { return }
        print("""

        Ubuntu Touch detected. The phone suspends completely when the
        screen turns off, which stops Briglia — a kernel wakelock keeps it
        reachable (higher idle battery use; check drain the first day).
        """)
        if WizardIO.askYesNo("Install the keep-awake unit now (asks for the phone's PIN)?",
                             default: true) {
            _ = installWakelockService()
        } else {
            print("  Skipped — Briglia will stop whenever the screen turns off.")
            print("  Install later with: briglia service install")
        }
    }
    #endif
}

// MARK: - Subcommands

struct AdaService: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Run Briglia as an always-on background service (Linux/systemd).",
        subcommands: [ServiceInstall.self, ServiceStatus.self, ServiceUninstall.self],
        defaultSubcommand: ServiceStatus.self
    )
}

private func serviceUnsupportedOnThisPlatform() -> Never {
    print("""
    `briglia service` manages a systemd service — Linux only (Raspberry Pi,
    servers, Ubuntu Touch phones). On macOS run `briglia daemon` in a terminal,
    or ask Briglia to set up a LaunchAgent for you.
    """)
    Foundation.exit(1)
}

struct ServiceInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install + start the systemd user service (and keep-awake on Ubuntu Touch)."
    )

    @Flag(name: .long, help: "Skip the Ubuntu Touch keep-awake unit even if applicable.")
    var noKeepawake = false

    func run() async throws {
        AdaCLI.prepareIO()
        try IdentityMigration.gateMutatingEntry()
        #if os(Linux)
        if AssistantProfile.isExtra {
            guard TelegramConfig.isConfigured else {
                print("✖ This assistant has no Telegram bot yet; set one up first.")
                throw ExitCode(1)
            }
            print("Installing the background service for this assistant…")
            guard AgentServiceSupport.installExtraService(AssistantProfile.selectedName) else { throw ExitCode(1) }
            print("\nDone. Logs: journalctl --user -u \(AgentServiceSupport.extraUnitName(AssistantProfile.selectedName)) -f")
            return
        }
        guard TelegramConfig.isConfigured else {
            print("""
            ✖ The service runs `briglia daemon`, which needs the Telegram channel.
              Run `briglia setup` and complete the Telegram step first.
            """)
            throw ExitCode(1)
        }
        print("Installing the Briglia background service…")
        guard AgentServiceSupport.installUserService() else { throw ExitCode(1) }

        if !noKeepawake {
            AgentServiceSupport.offerUbuntuTouchKeepAwake()
        }
        print("""

        Done. Useful commands:
          briglia service status
          journalctl --user -u briglia.service -f
        """)
        #else
        serviceUnsupportedOnThisPlatform()
        #endif
    }
}

struct ServiceStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether the Briglia service (and keep-awake unit) is installed and running."
    )

    func run() async throws {
        AdaCLI.prepareIO()
        #if os(Linux)
        if AssistantProfile.isExtra {
            let unit = AgentServiceSupport.extraUnitName(AssistantProfile.selectedName)
            let enabled = AgentServiceSupport.run("systemctl", ["--user", "is-enabled", unit]).output
            let active = AgentServiceSupport.run("systemctl", ["--user", "is-active", unit]).output
            print("Service \(unit): enabled \(enabled), active \(active)")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let unitPath = AgentServiceSupport.userUnitDirectory(home: home)
            + "/" + AgentServiceSupport.userUnitName
        guard FileManager.default.fileExists(atPath: unitPath) else {
            print("Briglia service: not installed (set it up with `briglia service install`)")
            return
        }
        print("Briglia service: installed (\(unitPath))")
        guard AgentServiceSupport.systemdUserSessionAvailable() else {
            print("  ⚠ no systemd user session reachable from here — try from a normal login shell.")
            return
        }
        let enabled = AgentServiceSupport.run(
            "systemctl", ["--user", "is-enabled", AgentServiceSupport.userUnitName]).output
        let active = AgentServiceSupport.run(
            "systemctl", ["--user", "is-active", AgentServiceSupport.userUnitName]).output
        print("  \(enabled == "enabled" ? "✔" : "⚠") enabled: \(enabled)")
        print("  \(active == "active" ? "✔" : "⚠") active: \(active)")
        print("  \(AgentServiceSupport.lingerEnabled() ? "✔" : "⚠") linger: \(AgentServiceSupport.lingerEnabled() ? "yes (starts at boot)" : "no — enable with: loginctl enable-linger \(NSUserName())")")

        if AgentServiceSupport.isUbuntuTouch() {
            if AgentServiceSupport.wakelockUnitInstalled() {
                let wlActive = AgentServiceSupport.run(
                    "systemctl", ["is-active", AgentServiceSupport.wakelockUnitName]).output
                print("  \(wlActive == "active" ? "✔" : "⚠") keep-awake unit: \(wlActive)")
                if wlActive != "active" {
                    print("    → sudo systemctl restart \(AgentServiceSupport.wakelockUnitName)")
                    print("    (gone after an OTA update? Reinstall with: briglia service install)")
                }
            } else {
                print("  ⚠ keep-awake unit: not installed — the phone suspends on screen-off.")
                print("    → briglia service install")
            }
        }
        if active != "active" {
            print("  Recent log:")
            let log = AgentServiceSupport.run(
                "journalctl", ["--user", "-u", AgentServiceSupport.userUnitName,
                               "-n", "5", "--no-pager"]).output
            for line in log.split(separator: "\n") { print("    \(line)") }
        }
        #else
        serviceUnsupportedOnThisPlatform()
        #endif
    }
}

struct ServiceUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Stop and remove the Briglia service (keeps Briglia itself and its data)."
    )

    func run() async throws {
        AdaCLI.prepareIO()
        #if os(Linux)
        if AssistantProfile.isExtra {
            let me = AssistantProfile.selectedName
            AgentServiceSupport.uninstallExtraService(me, others: AssistantProfile.listExtras().filter { $0 != me })
            print("✔ \(AgentServiceSupport.extraUnitName(me)) removed")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let unitPath = AgentServiceSupport.userUnitDirectory(home: home)
            + "/" + AgentServiceSupport.userUnitName
        if FileManager.default.fileExists(atPath: unitPath) {
            _ = AgentServiceSupport.run(
                "systemctl", ["--user", "disable", "--now", AgentServiceSupport.userUnitName])
            try? FileManager.default.removeItem(atPath: unitPath)
            _ = AgentServiceSupport.run("systemctl", ["--user", "daemon-reload"])
            print("✔ Briglia service removed (linger left as-is; disable with: loginctl disable-linger \(NSUserName()))")
        } else {
            print("Briglia service: not installed — nothing to remove.")
        }
        if AgentServiceSupport.wakelockUnitInstalled(),
           WizardIO.askYesNo("Also remove the keep-awake unit (asks for sudo, remounts / briefly)?",
                             default: true) {
            let ok = AgentServiceSupport.runInteractiveSudo(["mount", "-o", "remount,rw", "/"])
                && AgentServiceSupport.runInteractiveSudo(
                    ["systemctl", "disable", "--now", AgentServiceSupport.wakelockUnitName])
                && AgentServiceSupport.runInteractiveSudo(["rm", "-f", AgentServiceSupport.wakelockUnitPath])
                && AgentServiceSupport.runInteractiveSudo(["systemctl", "daemon-reload"])
            if !AgentServiceSupport.runInteractiveSudo(["mount", "-o", "remount,ro", "/"]) {
                print("⚠ could not remount / read-only (busy) — a reboot restores it.")
            }
            print(ok ? "✔ keep-awake unit removed" : "✖ keep-awake removal failed — see messages above.")
        }
        #else
        serviceUnsupportedOnThisPlatform()
        #endif
    }
}

// MARK: - Hidden selftest (pure parts — runs on macOS and Linux)

struct ServiceSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__service-selftest",
        abstract: "Internal: verify service unit generation and Ubuntu Touch detection.",
        shouldDisplay: false
    )

    func run() async throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            print("\(ok ? "✔" : "✖") \(label)")
            if !ok { failures += 1 }
        }

        // 1. User unit text.
        let unit = AgentServiceSupport.userUnitText(
            adaPath: "/home/phablet/.local/bin/ada", home: "/home/phablet")
        check("user unit: ExecStart quotes the binary and runs daemon",
              unit.contains("ExecStart=\"/home/phablet/.local/bin/ada\" daemon"))
        check("user unit: restart/killing semantics",
              unit.contains("Restart=always") && unit.contains("RestartSec=5")
              && unit.contains("KillSignal=SIGINT") && unit.contains("TimeoutStopSec=30"))
        check("user unit: PATH resolves the ada bin dir first",
              unit.contains("Environment=\"PATH=/home/phablet/.local/bin:"))
        check("user unit: HOME + WorkingDirectory set",
              unit.contains("Environment=\"HOME=/home/phablet\"")
              && unit.contains("WorkingDirectory=/home/phablet"))
        check("user unit: installs into default.target",
              unit.contains("WantedBy=default.target"))
        let spaced = AgentServiceSupport.userUnitText(
            adaPath: "/opt/my tools/ada", home: "/home/u")
        check("user unit: path with spaces stays quoted",
              spaced.contains("ExecStart=\"/opt/my tools/ada\" daemon"))

        // 2. Wakelock unit text.
        let wl = AgentServiceSupport.wakelockUnitText()
        check("wakelock unit: gated on the sysfs interface",
              wl.contains("ConditionPathExists=/sys/power/wake_lock")
              && wl.contains("ConditionPathExists=/sys/power/wake_unlock"))
        check("wakelock unit: acquires on start, releases on stop",
              wl.contains("ExecStart=/bin/sh -c 'printf \"%s\\n\" briglia-keepawake > /sys/power/wake_lock'")
              && wl.contains("ExecStop=/bin/sh -c 'printf \"%s\\n\" briglia-keepawake > /sys/power/wake_unlock'"))
        check("wakelock unit: oneshot + RemainAfterExit + multi-user.target",
              wl.contains("Type=oneshot") && wl.contains("RemainAfterExit=yes")
              && wl.contains("WantedBy=multi-user.target"))

        // 3. Ubuntu Touch detection against fabricated roots.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-service-selftest-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/etc", withIntermediateDirectories: true)
        check("plain root is not Ubuntu Touch",
              !AgentServiceSupport.isUbuntuTouch(rootPrefix: root, userName: "alice"))
        try fm.createDirectory(atPath: root + "/etc/system-image", withIntermediateDirectories: true)
        check("system-image marker ⇒ Ubuntu Touch",
              AgentServiceSupport.isUbuntuTouch(rootPrefix: root, userName: "alice"))
        try fm.removeItem(atPath: root + "/etc/system-image")
        check("marker removed ⇒ not Ubuntu Touch again",
              !AgentServiceSupport.isUbuntuTouch(rootPrefix: root, userName: "alice"))
        try fm.createDirectory(atPath: root + "/android", withIntermediateDirectories: true)
        check("Halium /android alone (non-phablet user) is NOT enough",
              !AgentServiceSupport.isUbuntuTouch(rootPrefix: root, userName: "alice"))
        check("/android + phablet user ⇒ Ubuntu Touch",
              AgentServiceSupport.isUbuntuTouch(rootPrefix: root, userName: "phablet"))

        // 4. Wakelock interface probe.
        check("no sysfs nodes ⇒ wakelock unsupported",
              !AgentServiceSupport.wakeLockSupported(rootPrefix: root))
        try fm.createDirectory(atPath: root + "/sys/power", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/sys/power/wake_lock", contents: Data())
        check("wake_lock alone is not enough",
              !AgentServiceSupport.wakeLockSupported(rootPrefix: root))
        fm.createFile(atPath: root + "/sys/power/wake_unlock", contents: Data())
        check("both nodes ⇒ wakelock supported",
              AgentServiceSupport.wakeLockSupported(rootPrefix: root))

        print(failures == 0 ? "\nservice selftest: all checks passed"
                            : "\nservice selftest: \(failures) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}
