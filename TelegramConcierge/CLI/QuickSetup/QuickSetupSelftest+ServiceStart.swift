import Foundation

/// Section 17 (2026-10-29): the Linux service start evidence waits for the
/// app socket instead of checking it once. `systemctl --user enable --now`
/// returns as soon as the unit is active; the daemon creates app-chat.sock a
/// few seconds later, so one immediate hello failed and the menu rolled back
/// a healthy start ("stop job in the same second" on Ubuntu 24.04).
extension SelftestContext {
    /// A virtual clock + scripted systemd/socket, so no row really waits.
    final class FakeService: @unchecked Sendable {
        var t: TimeInterval = 0
        var socketAt: TimeInterval?          // hello answers from this time on
        var socketGoneAt: TimeInterval?      // …and stops answering from here
        var stateAt: [(TimeInterval, String)] = []   // is-active changes
        var restartAt: TimeInterval?         // NRestarts bumps here
        var linger = true
        var handshakes = 0
        var sleeps: [TimeInterval] = []

        func state() -> String { stateAt.filter { $0.0 <= t }.last?.1 ?? "active" }
        var probes: QuickSetupEvidence.ServiceProbes {
            QuickSetupEvidence.ServiceProbes(
                isActive: { self.state() },
                linger: { self.linger },
                restartMarker: { "NRestarts=\((self.restartAt.map { self.t >= $0 } ?? false) ? 1 : 0)\nActiveEnterTimestamp=x" },
                handshake: {
                    self.handshakes += 1
                    guard let at = self.socketAt, self.t >= at else { return false }
                    if let gone = self.socketGoneAt, self.t >= gone { return false }
                    return true
                },
                sleep: { self.sleeps.append($0); self.t += $0 },
                now: { Date(timeIntervalSinceReferenceDate: self.t) })
        }
    }

    func serviceStart() async throws {
        let E = QuickSetupEvidence.self
        let saved = (E.handshakeTimeout, E.handshakePollInterval, E.stabilityWindow)
        defer { (E.handshakeTimeout, E.handshakePollInterval, E.stabilityWindow) = saved }
        check("defaults: hello polled every 0.5 s for up to 60 s, then the 20 s stability window",
              E.handshakeTimeout == 60 && E.handshakePollInterval == 0.5 && E.stabilityWindow == 20,
              "\(E.handshakeTimeout) \(E.handshakePollInterval) \(E.stabilityWindow)")

        // The field case: socket appears 3 s after enable --now.
        let late = FakeService(); late.socketAt = 3
        let e1 = await E.evaluateService(late.probes)
        check("socket created 3 s after start → waited for, start accepted (old: one check → rolled back)",
              e1.ok && e1.handshake && late.handshakes >= 7, "\(e1) handshakes=\(late.handshakes)")
        check("…the stability window still runs after the hello (20 s, then a re-check)",
              late.sleeps.last == 20 && late.t >= 23 && late.t < 24, "\(late.sleeps.suffix(3)) t=\(late.t)")

        let slow = FakeService(); slow.socketAt = 55
        let e2 = await E.evaluateService(slow.probes)
        check("slow first start (socket at 55 s) still accepted", e2.ok, "\(e2)")

        let never = FakeService()
        let e3 = await E.evaluateService(never.probes)
        check("socket never appears → fails after ~60 s with a clear reason",
              !e3.ok && !e3.handshake && e3.detail.contains("within 60 s") && never.t >= 60 && never.t < 61, "\(e3) t=\(never.t)")

        let crashed = FakeService(); crashed.stateAt = [(2, "failed")]
        let e4 = await E.evaluateService(crashed.probes)
        check("unit goes failed at 2 s → fails early (no 60 s wait), names the state",
              !e4.ok && !e4.active && e4.detail.contains("stopped while starting (failed)") && crashed.t < 3, "\(e4) t=\(crashed.t)")

        let stopped = FakeService(); stopped.stateAt = [(1, "inactive")]
        let e5 = await E.evaluateService(stopped.probes)
        check("unit goes inactive → fails early", !e5.ok && e5.detail.contains("(inactive)") && stopped.t < 2, "\(e5)")

        let restarted = FakeService(); restarted.restartAt = 2; restarted.socketAt = 10
        let e6 = await E.evaluateService(restarted.probes)
        check("unit restarts (NRestarts changes) before the hello → fails early, no waiting on a crash loop",
              !e6.ok && e6.detail.contains("restarted while starting") && restarted.t < 3, "\(e6) t=\(restarted.t)")

        let flappy = FakeService(); flappy.socketAt = 1; flappy.restartAt = 10
        let e7 = await E.evaluateService(flappy.probes)
        check("restart inside the stability window still fails (unchanged)", !e7.ok && e7.handshake && e7.detail.contains("stability window"), "\(e7)")

        let lost = FakeService(); lost.socketAt = 0; lost.socketGoneAt = 5
        let e8 = await E.evaluateService(lost.probes)
        check("socket stops answering during the window still fails (unchanged)", !e8.ok && e8.detail.contains("stopped answering"), "\(e8)")

        let instant = FakeService(); instant.socketAt = 0
        let e9 = await E.evaluateService(instant.probes)
        check("already answering → no polling delay (one hello before the window)", e9.ok && instant.sleeps == [20], "\(instant.sleeps)")

        let inactive = FakeService(); inactive.stateAt = [(0, "inactive")]
        let e10 = await E.evaluateService(inactive.probes)
        check("not active at all → 'service is not active' (unchanged)", !e10.ok && e10.detail == "service is not active" && inactive.handshakes == 0, "\(e10)")

        let noLinger = FakeService(); noLinger.linger = false
        let e11 = await E.evaluateService(noLinger.probes)
        check("no linger → refused before any wait (unchanged)", !e11.ok && e11.detail.contains("linger") && noLinger.t == 0, "\(e11)")

        #if os(Linux)
        // The real Linux wiring (systemctl seams), with real (short) sleeps.
        E.handshakeTimeout = 3; E.handshakePollInterval = 0.05; E.stabilityWindow = 0.1
        var calls = 0
        E.isActiveOverride = { "active" }
        E.lingerOverride = { true }
        E.systemctlShowOverride = { "NRestarts=0\nActiveEnterTimestamp=x" }
        E.socketHandshakeOverride = { calls += 1; return calls >= 4 }
        defer { E.isActiveOverride = nil; E.lingerOverride = nil; E.systemctlShowOverride = nil; E.socketHandshakeOverride = nil }
        let real = await E.serviceEvidence()
        check("Linux serviceEvidence(): socket answering on the 4th try → accepted", real.ok && calls >= 4, "\(real) calls=\(calls)")
        calls = 0
        E.isActiveOverride = { calls >= 2 ? "failed" : "active" }
        E.socketHandshakeOverride = { calls += 1; return false }
        let failed = await E.serviceEvidence()
        check("Linux serviceEvidence(): unit fails while waiting → refused early", !failed.ok && failed.detail.contains("failed"), "\(failed)")
        #endif
    }
}

/// Section 18 (2026-10-29): on Debian/Ubuntu, when the only supported python
/// lacks python3.X-venv, the menu's terminal apt job installs it before the
/// detached `briglia python-env install` job needs it.
extension SelftestContext {
    func venvAptJob() async throws {
        #if os(Linux)
        guard let manager = ToolchainService.linuxPackageManager(), manager.name == "apt-get",
              PlatformBinary.find("sudo") != nil else {
            check("apt-get + sudo on this runner (rows skipped otherwise)", true); return
        }
        let saved = QuickSetupEnvironment.venvPackageNeeded
        defer { QuickSetupEnvironment.venvPackageNeeded = saved }
        var asked = 0
        QuickSetupEnvironment.venvPackageNeeded = { asked += 1; return "python3.12-venv" }
        func status(_ missing: [String], libre: Bool = true) -> ToolchainService.DesktopStatus {
            .init(doctorRan: true, missing: missing, libreOffice: libre, mandatoryMissing: missing)
        }
        let onlyPy = QuickSetupEnvironment.defaultToolchainJobs(status(["python-docx"]))
        let apt = onlyPy.first { $0.mode == .terminalHandoff }
        check("python packages missing + no venv → a terminal apt job installs python3.12-venv",
              apt?.command.suffix(1) == ["python3.12-venv"] && apt?.command.contains("install") == true, "\(onlyPy.map(\.command))")
        check("…and it runs before the detached python-env job",
              (onlyPy.firstIndex { $0.mode == .terminalHandoff } ?? 99) < (onlyPy.firstIndex { $0.command.contains("python-env") } ?? -1), "\(onlyPy.map(\.label))")
        let mixed = QuickSetupEnvironment.defaultToolchainJobs(status(["python-docx", "ffmpeg"], libre: false))
        let mixedApt = mixed.filter { $0.mode == .terminalHandoff }
        check("with other system packages → one apt job carrying them and the venv package",
              mixedApt.count == 1 && mixedApt[0].command.suffix(3) == ["ffmpeg", "libreoffice", "python3.12-venv"], "\(mixedApt.map(\.command))")
        asked = 0
        let noPy = QuickSetupEnvironment.defaultToolchainJobs(status(["ffmpeg"]))
        check("no python packages missing → the venv probe is not even run, no venv package",
              asked == 0 && !noPy.contains { $0.command.contains("python3.12-venv") }, "asked=\(asked)")
        QuickSetupEnvironment.venvPackageNeeded = { nil }
        let fine = QuickSetupEnvironment.defaultToolchainJobs(status(["python-docx"]))
        check("venv present → no apt job at all, only python-env", !fine.contains { $0.mode == .terminalHandoff } && fine.contains { $0.command.contains("python-env") }, "\(fine.map(\.label))")
        #else
        check("Linux only (macOS: nothing to plan)", true)
        #endif
    }
}
