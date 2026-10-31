import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Environment (every side effect behind a closure, for the selftest)

struct QuickSetupEnvironment {
    var isLinux: Bool = {
        #if os(Linux)
        return true
        #else
        return false
        #endif
    }()
    var subscription: ([String: Any], () throws -> Void) async -> [String: Any] = { await SubscriptionSetup().perform($0, ownsLease: true, checkpoint: $1) }
    var probe: ([String: Any]) async -> [String: Any] = {
        if $0["kind"] as? String == "chatgpt" {
            var request = $0; request.removeValue(forKey: "kind"); request["action"] = "probe"
            return await SubscriptionSetup().perform(request, ownsLease: true)
        }
        return await SetupAPICore.probe($0)
    }
    var apply: ([String: Any], () throws -> Void) async -> [String: Any] = { await SetupAPICore.apply($0, ownsLease: true, checkpoint: $1) }
    var storedValue: (String) -> String? = { KeychainHelper.load(key: $0) }
    var saveBatch: ([String: String?]) throws -> Void = { try KeychainHelper.saveBatch($0) }
    var fsyncConfigDirectory: () throws -> Void = { try PrivateStorage.fsyncDirectory(StoragePaths.configRoot.path) }
    var fullDiskAccessGranted: () -> Bool = { PermissionsService.fullDiskAccessGranted() }
    var terminalAppName: () -> String = {
        #if os(macOS)
        return QuickSetupEvidence.terminalAppName()
        #else
        return "your terminal"
        #endif
    }
    var openSettingsPane: () -> Void = {
        #if os(macOS)
        _ = ProcessRunner.runBlockingProcess(
            executable: "/usr/bin/open",
            args: ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"], timeoutSeconds: 10)
        #endif
    }
    var keepAwakeHeld: () -> Bool = { KeepAwake.isHeld && (KeepAwake.assertionListedBySystem(reason: KeepAwake.defaultReason) ?? true) }
    var autoSuspendVerdict: () -> AutoSuspendCensus.Verdict = {
        #if os(Linux)
        return PermissionsService.autoSuspendVerdict()
        #else
        return .sleepImpossible
        #endif
    }
    var disableGnomeAutoSuspend: () -> Bool = {
        #if os(Linux)
        return PermissionsService.disableGnomeAutoSuspend()
        #else
        return false
        #endif
    }
    var toolchainStatus: () -> ToolchainService.DesktopStatus = { ToolchainService.desktopStatus() }
    /// Jobs to run for the missing part of the toolchain, in order.
    var toolchainJobs: (ToolchainService.DesktopStatus) -> [SetupJobRunner.Spec] = QuickSetupEnvironment.defaultToolchainJobs
    var maskSleepTargetsJob: () -> SetupJobRunner.Spec? = {
        guard let sudo = PlatformBinary.find("sudo"), let systemctl = PlatformBinary.find("systemctl") else { return nil }
        return SetupJobRunner.Spec(row: "keepawake", command: [sudo, systemctl, "mask", "sleep.target", "suspend.target", "hibernate.target", "hybrid-sleep.target"],
                                   mode: .terminalHandoff, timeout: 300, label: "mask sleep targets")
    }
    var installAgentMail: (_ progress: @escaping @Sendable (String) -> Void, _ checkpoint: () throws -> Void, _ runner: SetupJobRunner) async -> String? = { progress, checkpoint, _ in
        do { try checkpoint() } catch { return "cancelled" }
        // Briglia's private copy (security plan v24 §7.8.1); never ~/.local/bin.
        return await AgentMailService.installAgentMailBinary(progress: progress)
    }
    var agentMailInstalled: () -> Bool = { AgentMailService.agentMailBrokerInstalled() }
    // Linux service
    var installUnit: () throws -> Void = QuickSetupEnvironment.defaultInstallUnit
    var enableService: (SetupJobRunner) async -> String? = QuickSetupEnvironment.defaultEnableService
    /// Async so the 20-second stability window never blocks the workflow
    /// actor (a blocked actor could not observe Enter's revocation).
    var serviceEvidence: () async -> (ok: Bool, linger: Bool, detail: String) = {
        #if os(Linux)
        let e = await QuickSetupEvidence.serviceEvidence()
        return (e.ok, e.linger, e.detail)
        #else
        return (false, false, "no service on macOS")
        #endif
    }
    var stopService: () -> Bool = {
        #if os(Linux)
        return AgentServiceSupport.run("systemctl", ["--user", "stop", AgentServiceSupport.userUnitName]).status == 0
        #else
        return false
        #endif
    }
    var releaseLease: () -> Void = {}
    var reacquireLease: () -> Bool = { true }
    var log: (String) -> Void = { print($0) }

    /// Dev builds only: `BRIGLIA_DEV_QUICKSETUP_STUBS=1` replaces the
    /// system-row evidence and installers with stubs (a marker file under the
    /// data root stands in for "toolchain installed"), so the headless smoke
    /// and the browser test can run the whole flow on any machine.
    static func applyDevStubsIfRequested(_ env: inout QuickSetupEnvironment) {
        guard adaCLIVersion.hasSuffix("-dev"),
              ProcessInfo.processInfo.environment["BRIGLIA_DEV_QUICKSETUP_STUBS"] == "1" else { return }
        let marker = StoragePaths.dataRoot.appendingPathComponent(".stub-toolchain-installed").path
        let serviceMarker = StoragePaths.dataRoot.appendingPathComponent(".stub-service-started").path
        let fm = FileManager.default
        env.fullDiskAccessGranted = { ProcessInfo.processInfo.environment["BRIGLIA_DEV_STUB_FDA"] != "0" }
        // keepAwakeHeld stays REAL: the headless/browser runs prove the
        // assertion quick setup holds is the one the row verifies (macOS).
        env.autoSuspendVerdict = { .sleepImpossible }
        env.agentMailInstalled = { true }
        env.toolchainStatus = {
            let installed = fm.fileExists(atPath: marker)
            return ToolchainService.DesktopStatus(doctorRan: true, missing: installed ? [] : ["pandoc"],
                                                  libreOffice: installed, mandatoryMissing: installed ? [] : ["pandoc"])
        }
        env.toolchainJobs = { _ in
            let slow = ProcessInfo.processInfo.environment["BRIGLIA_DEV_STUB_SLOW_TOOLCHAIN"] ?? "0"
            return [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "echo stub: installing toolchain; sleep \(slow); touch '\(marker)'; echo stub: done"],
                                        mode: .detached, timeout: 120, label: "stub toolchain install")]
        }
        env.installUnit = { }
        env.enableService = { _ in fm.createFile(atPath: serviceMarker, contents: Data()); return nil }
        env.serviceEvidence = { (fm.fileExists(atPath: serviceMarker), true, "stub service active") }
        env.stopService = { unlink(serviceMarker); return true }
        env.maskSleepTargetsJob = { nil }
    }

    /// Seam: the python3.X-venv package the menu must install (selftests).
    nonisolated(unsafe) static var venvPackageNeeded: () -> String? = { PythonRuntime.venvPackageNeededBlocking() }

    static func defaultToolchainJobs(_ status: ToolchainService.DesktopStatus) -> [SetupJobRunner.Spec] {
        var jobs: [SetupJobRunner.Spec] = []
        let missing = Set(status.mandatoryMissing)
        let pipPackages = ["python-docx", "python-pptx", "pillow", "pymupdf", "formulas", "openpyxl"].filter { missing.contains($0) }
        // Python packages: ONE job building Briglia's private venv from the
        // reviewed lock (security plan v24 §7.9.4); never the shared pip.
        let pythonEnvJob = SetupJobRunner.Spec(row: "toolchain", command: [AgentMailService.brigliaPath(), "python-env", "install"],
                                               mode: .detached, timeout: 3600, label: "briglia python-env install")
        #if os(macOS)
        guard let brew = ToolchainService.brewPath() else { return [] }
        var formulas: [String] = []
        if !missing.isDisjoint(with: ["pdfinfo", "pdftotext", "pdftoppm", "pdfseparate", "pdfunite"]) { formulas.append("poppler") }
        if !missing.isDisjoint(with: ["ffmpeg", "ffprobe"]) { formulas.append("ffmpeg") }
        if missing.contains("pandoc") { formulas.append("pandoc") }
        for f in formulas {
            jobs.append(.init(row: "toolchain", command: [brew, "install", f], mode: .detached, timeout: 900,
                              environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], label: "brew install \(f)"))
        }
        if !pipPackages.isEmpty { jobs.append(pythonEnvJob) }
        if !status.libreOffice {
            jobs.append(.init(row: "toolchain", command: [brew, "install", "--cask", "libreoffice"], mode: .detached, timeout: 2400,
                              environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], label: "brew install --cask libreoffice"))
        }
        #else
        guard let manager = ToolchainService.linuxPackageManager(), let sudo = PlatformBinary.find("sudo"),
              let managerPath = PlatformBinary.find(manager.name) else { return [] }
        var logical: [String] = []
        if !missing.isDisjoint(with: ["pdfinfo", "pdftotext", "pdftoppm", "pdfseparate", "pdfunite"]) { logical.append("poppler") }
        if !missing.isDisjoint(with: ["magick", "identify", "convert", "imagemagick"]) { logical.append("imagemagick") }
        if !missing.isDisjoint(with: ["ffmpeg", "ffprobe"]) { logical.append("ffmpeg") }
        if missing.contains("pandoc") { logical.append("pandoc") }
        if !status.libreOffice { logical.append("libreoffice") }
        // Debian/Ubuntu python without python3.X-venv: install it in this
        // terminal job, before the detached python-env job needs it.
        let venv = (!pipPackages.isEmpty && manager.name == "apt-get") ? venvPackageNeeded() : nil
        if !logical.isEmpty || venv != nil {
            let packages = logical.map { LinuxPackageMap.package($0, manager: manager.name) } + (venv.map { [$0] } ?? [])
            jobs.append(.init(row: "toolchain", command: [sudo] + LinuxPackageMap.installCommand(manager: manager.name, managerPath: managerPath, packages: packages),
                              mode: .terminalHandoff, timeout: 2400, environment: ["DEBIAN_FRONTEND": "noninteractive"],
                              label: "\(manager.name) install \(packages.joined(separator: " "))"))
        }
        if !pipPackages.isEmpty { jobs.append(pythonEnvJob) }
        #endif
        return jobs
    }

    static func defaultInstallUnit() throws {
        #if os(Linux)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let unitDir = AgentServiceSupport.userUnitDirectory(home: home)
        let unitPath = unitDir + "/" + AgentServiceSupport.userUnitName
        try FileManager.default.createDirectory(atPath: unitDir, withIntermediateDirectories: true)
        let text = AgentServiceSupport.userUnitText(adaPath: AgentServiceSupport.adaExecutablePath(), home: home)
        try PrivateStorage.writeAtomically(Data(text.utf8), to: URL(fileURLWithPath: unitPath), mode: 0o644)
        let reload = AgentServiceSupport.run("systemctl", ["--user", "daemon-reload"])
        guard reload.status == 0 else { throw NSError(domain: "briglia.quicksetup", code: 20, userInfo: [NSLocalizedDescriptionKey: "systemctl --user daemon-reload failed: \(reload.output)"]) }
        #endif
    }

    static func defaultEnableService(_ runner: SetupJobRunner) async -> String? {
        #if os(Linux)
        guard let systemctl = PlatformBinary.find("systemctl") else { return "systemctl not found" }
        let enable = await runner.run(.init(row: "service", command: [systemctl, "--user", "enable", "--now", AgentServiceSupport.userUnitName],
                                            mode: .detached, timeout: 120, label: "systemctl --user enable --now briglia"))
        guard enable.ok else { return "enable --now failed: \(enable.failureReason ?? "?")" }
        if !AgentServiceSupport.lingerEnabled() {
            if let loginctl = PlatformBinary.find("loginctl") {
                _ = await runner.run(.init(row: "service", command: [loginctl, "enable-linger", NSUserName()], mode: .detached, timeout: 60, label: "loginctl enable-linger"))
            }
            if !AgentServiceSupport.lingerEnabled(), let sudo = PlatformBinary.find("sudo"), let loginctl = PlatformBinary.find("loginctl") {
                let r = await runner.run(.init(row: "service", command: [sudo, loginctl, "enable-linger", NSUserName()], mode: .terminalHandoff, timeout: 300, label: "sudo loginctl enable-linger"))
                if !r.ok { return "linger could not be enabled (sudo declined?): run `sudo loginctl enable-linger \(NSUserName())`" }
            }
        }
        return nil
        #else
        return "no service on macOS"
        #endif
    }
}

