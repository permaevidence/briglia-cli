import Foundation

/// The ONLY place Linux package names live (plan §4.7): the quick setup's
/// toolchain row and the regular wizard's Linux step both read it. Pure so
/// the selftest pins every cell on macOS too.
enum LinuxPackageMap {
    static let managers = ["apt-get", "dnf", "pacman"]

    /// Argument shape per manager, before the package names.
    static func installArgs(for manager: String) -> [String] {
        switch manager {
        case "apt-get": return ["install", "-y"]
        case "dnf": return ["install", "-y"]
        case "pacman": return ["-S", "--noconfirm", "--needed"]
        default: return ["install", "-y"]
        }
    }

    /// Logical name → distribution package.
    static func package(_ logical: String, manager: String) -> String {
        switch (logical, manager) {
        case ("poppler", "pacman"): return "poppler"
        case ("poppler", _): return "poppler-utils"
        case ("imagemagick", "dnf"): return "ImageMagick"
        case ("imagemagick", _): return "imagemagick"
        case ("ffmpeg", "dnf"): return "ffmpeg-free"
        case ("ffmpeg", _): return "ffmpeg"
        case ("pandoc", _): return "pandoc"
        case ("libreoffice", "pacman"): return "libreoffice-fresh"
        case ("libreoffice", _): return "libreoffice"
        case ("pip", "pacman"): return "python-pip"
        case ("pip", _): return "python3-pip"
        default: return logical
        }
    }

    /// The quick setup's full mandatory install for one manager, in order.
    static let mandatoryLogical = ["poppler", "imagemagick", "ffmpeg", "pandoc", "libreoffice"]

    static func mandatoryPackages(manager: String) -> [String] {
        mandatoryLogical.map { package($0, manager: manager) }
    }

    /// `sudo <manager> <args> <packages>` argument vector (after `sudo`).
    static func installCommand(manager: String, managerPath: String, packages: [String]) -> [String] {
        [managerPath] + installArgs(for: manager) + packages
    }

    /// The package-list refresh to run (after `sudo`) once before an
    /// installer run's first install, or nil for managers that need none.
    /// apt-get only (field report 2026-11-18): with stale lists, a package
    /// whose Debian security update replaced the old .deb fails with
    /// "404 Not Found". `apt-get update` only refreshes the lists; it never
    /// upgrades an installed package. dnf refreshes its metadata itself;
    /// pacman is left alone on purpose (`-Sy` without `-u` is a partial
    /// upgrade, unsupported on Arch).
    static func refreshCommand(manager: String, managerPath: String) -> [String]? {
        manager == "apt-get" ? [managerPath, "update"] : nil
    }

    /// "signal 2, SIGINT" for the interrupt messages (number alone for others).
    static func signalLabel(_ signal: Int32) -> String {
        let names: [Int32: String] = [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 9: "SIGKILL", 15: "SIGTERM"]
        return names[signal].map { "\(signal), \($0)" } ?? "\(signal)"
    }
}

/// One installer run's system-package installs, one package at a time (the
/// setup wizard, python3.X-venv): the package lists are refreshed once,
/// before the first install of the run, never again. A failed refresh does
/// not stop the install (offline, or one broken third-party repository);
/// its reason is added to the install's failure text if the install fails
/// too. Each install is attempted exactly once. A command killed by a
/// signal (Ctrl-C in the terminal, SIGTERM, SIGKILL) is an interrupt: it
/// ends the run, and no later install of this session runs (Codex round 1,
/// P2). Pure: the commands run through `run`, so the selftest drives it
/// with a fake on any platform.
final class LinuxInstallSession: @unchecked Sendable {
    enum Outcome: Equatable {
        case exited(Int32)
        /// Killed by this signal (Foundation: `terminationReason == .uncaughtSignal`).
        case signaled(Int32)
        case launchFailed(String)
    }

    /// Runs one argument vector (after `sudo`).
    private let run: ([String]) -> Outcome
    /// Told right before the refresh starts.
    private let announce: (String) -> Void
    private let lock = NSLock()
    private var refreshAttempted = false
    private var refreshFailure: String?
    /// Set by the first interrupted command; the run is over.
    private var interruption: String?

    init(run: @escaping ([String]) -> Outcome, announce: @escaping (String) -> Void = { _ in }) {
        self.run = run
        self.announce = announce
    }

    /// nil = installed, else a one-line failure.
    func install(_ package: String, manager: String, managerPath: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let interruption {
            return "not installed: the installation was interrupted (\(interruption)). Run it again to retry."
        }
        if !refreshAttempted, let refresh = LinuxPackageMap.refreshCommand(manager: manager, managerPath: managerPath) {
            refreshAttempted = true
            announce("Refreshing package lists (\(manager) update)\u{2026}")
            switch run(refresh) {
            case .exited(0): break
            case .exited(let code): refreshFailure = "\(manager) update exited with status \(code)"
            case .signaled(let sig):
                let why = "\(manager) update was interrupted (signal \(LinuxPackageMap.signalLabel(sig)))"
                interruption = why
                return "Installation interrupted: \(why), so \(package) was not installed. Run it again to retry."
            case .launchFailed(let why): refreshFailure = "failed to launch \(manager) update: \(why)"
            }
        }
        let failure: String
        switch run(LinuxPackageMap.installCommand(manager: manager, managerPath: managerPath, packages: [package])) {
        case .exited(0): return nil
        case .exited(let code): failure = "\(manager) exited with status \(code)"
        case .signaled(let sig):
            let why = "\(manager) was interrupted (signal \(LinuxPackageMap.signalLabel(sig)))"
            interruption = why
            failure = "Installation interrupted: \(why)"
        case .launchFailed(let why): failure = "failed to launch \(manager): \(why)"
        }
        guard let refreshFailure else { return failure }
        return failure + " (refreshing the package lists before it also failed: \(refreshFailure))"
    }
}
