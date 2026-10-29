import Foundation

/// Toolchain for the bundled document/media skills (docx, pdf, pptx, xlsx,
/// video-edit): small free programs and Python packages the skill scripts
/// rely on (poppler, python-docx, python-pptx, pillow, pymupdf, formulas,
/// openpyxl, ffmpeg, pandoc) plus the optional LibreOffice render backend.
///
/// The onboarding "Strumenti" step uses this service to make the machine
/// self-sufficient ONCE, so the agent can later install anything else by
/// itself instead of degrading or asking the user. Detection is delegated to
/// the skills' own `skills_doctor.py` (single source of truth for what the
/// skills need); this service only knows HOW to install each entry.
enum ToolchainService {

    // MARK: - Types

    /// Whether `python3 -m pip install …` works on this machine. The common
    /// failure is PEP 668: Homebrew/distribution Pythons mark the environment
    /// EXTERNALLY-MANAGED and pip refuses to install anything.
    enum PipStatus: Equatable {
        case ok
        case externallyManaged
        case pythonMissing
    }

    /// One entry of the doctor report, already flattened to what the UI needs.
    struct DoctorEntry: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let kind: String      // "binary" | "python" | "engine"
        let install: String   // human-readable install hint from the doctor
        let impact: String    // what degrades without it
    }

    /// How to install one doctor entry. Detection comes from skills_doctor.py;
    /// this table only maps its `name` values to concrete commands. Anything
    /// not listed here is guidance-only (see `isAutoInstallable`).
    private struct InstallSpec {
        /// "brewFormula" | "brewCask" | "pip"
        let manager: String
        /// Formula/cask name, or pip package name.
        let package: String
        let timeoutSeconds: Int
    }

    /// Curated install recipes keyed by the doctor entry `name`. Kept
    /// deliberately explicit (no parsing of the doctor's free-text hints).
    /// Deliberate exclusions:
    /// - "html-to-pdf engine": pip-installing weasyprint on macOS without the
    ///   native pango libs produces a BROKEN install; Chrome covers the
    ///   fallback well enough, so the UI shows guidance instead.
    /// - "libreoffice": ~600 MB — installed only from its own explicit card.
    private static let installSpecs: [String: InstallSpec] = [
        "ffmpeg":      InstallSpec(manager: "brewFormula", package: "ffmpeg", timeoutSeconds: 900),
        "ffprobe":     InstallSpec(manager: "brewFormula", package: "ffmpeg", timeoutSeconds: 900),
        "pdftoppm":    InstallSpec(manager: "brewFormula", package: "poppler", timeoutSeconds: 600),
        "pdftotext":   InstallSpec(manager: "brewFormula", package: "poppler", timeoutSeconds: 600),
        "pdfinfo":     InstallSpec(manager: "brewFormula", package: "poppler", timeoutSeconds: 600),
        "pandoc":      InstallSpec(manager: "brewFormula", package: "pandoc", timeoutSeconds: 600),
        "openpyxl":    InstallSpec(manager: "pip", package: "openpyxl", timeoutSeconds: 300),
        "python-docx": InstallSpec(manager: "pip", package: "python-docx", timeoutSeconds: 300),
        "python-pptx": InstallSpec(manager: "pip", package: "python-pptx", timeoutSeconds: 300),
        "pillow":      InstallSpec(manager: "pip", package: "pillow", timeoutSeconds: 300),
        "formulas":    InstallSpec(manager: "pip", package: "formulas", timeoutSeconds: 600),
        "pymupdf":     InstallSpec(manager: "pip", package: "pymupdf", timeoutSeconds: 300),
    ]

    /// Doctor entries the onboarding can install without asking (small, safe).
    /// LibreOffice is excluded on purpose (600 MB, explicit consent card).
    static func autoInstallable(_ entry: DoctorEntry) -> Bool {
        installSpecs[entry.name] != nil
    }

    /// Collapse entries that share one package — poppler covers pdftoppm,
    /// pdftotext and pdfinfo; ffmpeg covers ffprobe — so "Installa tutto"
    /// runs each real install once.
    static func uniqueInstallTargets(_ entries: [DoctorEntry]) -> [DoctorEntry] {
        var seen = Set<String>()
        var out: [DoctorEntry] = []
        for entry in entries {
            guard let spec = installSpecs[entry.name], seen.insert(spec.package).inserted else { continue }
            out.append(entry)
        }
        return out
    }

    /// The package the user sees installed for this entry (e.g. "poppler"
    /// rather than the three poppler binaries separately).
    static func displayName(for entry: DoctorEntry) -> String {
        installSpecs[entry.name]?.package ?? entry.name
    }

    // MARK: - Environment probes

    /// Absolute path to the brew binary, or nil when Homebrew is absent.
    static func brewPath() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    #if os(Linux)
    /// The distribution package manager, probed in order of market share.
    /// Installs run `sudo <manager> …` with inherited stdio so sudo can
    /// prompt on the wizard's terminal.
    struct LinuxPackageManager {
        let name: String          // "apt-get" | "dnf" | "pacman"
        let installArgs: [String] // arguments before the package name
    }

    static func linuxPackageManager() -> LinuxPackageManager? {
        for name in ["apt-get", "dnf", "pacman"] where PlatformBinary.find(name) != nil {
            return LinuxPackageManager(name: name, installArgs: LinuxPackageMap.installArgs(for: name))
        }
        return nil
    }

    /// Map the curated Homebrew package names to their distribution names.
    static func linuxPackageName(forBrewPackage package: String) -> String {
        let manager = linuxPackageManager()?.name ?? "apt-get"
        return LinuxPackageMap.package(package, manager: manager)
    }

    /// Public entry for the wizard's required-package installs (poppler,
    /// imagemagick). Returns nil on success, else a one-line failure.
    static func installLinuxPackage(_ package: String) async -> String? {
        guard let manager = linuxPackageManager() else {
            return "no supported package manager found (apt-get/dnf/pacman)"
        }
        return linuxInstall(package, manager: manager)
    }

    /// Synchronous apt-get install of one package through the terminal
    /// hand-off (PythonRuntime's missing python3.X-venv). nil = installed.
    static func installLinuxPackageSync(_ package: String) -> String? {
        guard PlatformBinary.find("apt-get") != nil else { return "apt-get not found" }
        return linuxInstall(package, manager: LinuxPackageManager(name: "apt-get", installArgs: LinuxPackageMap.installArgs(for: "apt-get")))
    }

    /// `sudo <manager> install -y <package>` with inherited stdio (interactive
    /// sudo). Returns nil on success, else a one-line failure. The child must
    /// own the terminal (sudo password, dpkg conffile/trigger prompts), so it
    /// runs through TerminalHandoff — a plain spawn leaves it in a background
    /// process group whose first tty read SIGTTIN-freezes the install.
    private static func linuxInstall(_ package: String, manager: LinuxPackageManager) -> String? {
        guard let sudo = PlatformBinary.find("sudo") else { return "sudo not found" }
        guard let managerPath = PlatformBinary.find(manager.name) else { return "\(manager.name) not found" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sudo)
        process.arguments = [managerPath] + manager.installArgs + [package]
        do { try TerminalHandoff.runLendingForeground(process) } catch {
            return "failed to launch \(manager.name): \(error.localizedDescription)"
        }
        return process.terminationStatus == 0 ? nil : "\(manager.name) exited with status \(process.terminationStatus)"
    }
    #endif

    /// Absolute path to the python3 the agent's bash tool would resolve.
    static func python3Path() -> String? {
        let result = ProcessRunner.runBlockingProcess(
            executable: "/usr/bin/which", args: ["python3"], timeoutSeconds: 5
        )
        guard let out = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) else {
            return nil
        }
        return out
    }

    /// Whether plain `pip install` works (PEP 668 check), probed the same way
    /// pip itself decides: the EXTERNALLY-MANAGED marker file next to stdlib.
    static func pipStatus() -> PipStatus {
        guard let python = python3Path() else { return .pythonMissing }
        let probe = ProcessRunner.runBlockingProcess(
            executable: python,
            args: ["-c", "import sysconfig, os; print(os.path.exists(os.path.join(sysconfig.get_paths()['stdlib'], 'EXTERNALLY-MANAGED')))"],
            timeoutSeconds: 10
        )
        guard let out = probe.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            // pip itself may be missing — treat as OK-ish: installs will fail
            // with a visible error the UI surfaces, and guidance is shown.
            return .ok
        }
        return out == "True" ? .externallyManaged : .ok
    }

    /// The exact mandatory set of the desktop quick setup (plan §4.7):
    /// every doctor entry except the html-to-pdf engine (weasyprint on
    /// macOS without pango is a broken install; Chrome covers it), plus
    /// LibreOffice. `nil` when the doctor could not run.
    static let doctorExclusions: Set<String> = ["html-to-pdf engine"]

    struct DesktopStatus: Equatable {
        var doctorRan: Bool
        var missing: [String]
        var libreOffice: Bool
        var mandatoryMissing: [String]
        var complete: Bool { doctorRan && mandatoryMissing.isEmpty && libreOffice }
    }

    static func desktopStatus() -> DesktopStatus {
        let libre = libreOfficePresent()
        guard let report = runDoctor() else {
            return DesktopStatus(doctorRan: false, missing: [], libreOffice: libre, mandatoryMissing: [])
        }
        let missing = report.missing.map(\.name)
        let mandatory = missing.filter { !doctorExclusions.contains($0) }
        return DesktopStatus(doctorRan: true, missing: missing, libreOffice: libre, mandatoryMissing: mandatory)
    }

    /// True when LibreOffice is installed (app bundle or PATH).
    static func libreOfficePresent() -> Bool {
        if FileManager.default.fileExists(atPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice") {
            return true
        }
        return PlatformBinary.find("soffice") != nil
    }

    // MARK: - Doctor report

    /// Run the bundled skills_doctor.py and split its report into
    /// present/missing entries. Returns nil when the report can't be produced
    /// (python3 missing, script failed to launch, malformed output).
    static func runDoctor() -> (present: [DoctorEntry], missing: [DoctorEntry])? {
        guard let python = python3Path() else { return nil }
        guard let script = Bundle.module.resourceURL?
            .appendingPathComponent("BundledSkills/pdf/skills_doctor.py").path,
              FileManager.default.fileExists(atPath: script) else { return nil }

        // The base python3 is only a stdlib launcher here; Python packages
        // are checked in Briglia's private environment (security plan v24
        // §7.9.4, R21-3): BRIGLIA_PYTHON_ENV names its interpreter, or is
        // empty when none is set up (never the shared site-packages).
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BashTools.augmentedPath(env["PATH"])
        if case .run(let venvPython) = PythonRuntime.execDecision() {
            env["BRIGLIA_PYTHON_ENV"] = venvPython
        } else {
            env["BRIGLIA_PYTHON_ENV"] = ""
        }
        let result = RuntimeProcess.runBlocking(python, [script], env: env, cwd: URL(fileURLWithPath: "/"), timeout: 120)
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func entries(_ key: String) -> [DoctorEntry] {
            guard let raw = root[key] as? [[String: Any]] else { return [] }
            return raw.compactMap { dict in
                guard let name = dict["name"] as? String else { return nil }
                return DoctorEntry(
                    name: name,
                    kind: dict["kind"] as? String ?? "",
                    install: dict["install"] as? String ?? "",
                    impact: dict["impact"] as? String ?? ""
                )
            }
        }
        return (entries("present"), entries("missing"))
    }

    // MARK: - Installs

    /// Install one auto-installable entry. Returns nil on success, otherwise a
    /// one-line human-readable failure (surfaced in the UI verbatim).
    ///
    /// `pipBreakSystemPackages`: on PEP 668 machines the only way to make the
    /// agent's `python3 -m pip install …` line work unattended is to relax the
    /// externally-managed guard. Briglia's onboarding already recommends a
    /// dedicated Mac, where that trade-off is acceptable and explicit.
    static func install(
        _ entry: DoctorEntry,
        pipBreakSystemPackages: Bool
    ) async -> String? {
        guard let spec = installSpecs[entry.name] else {
            return "nessuna installazione automatica prevista per \(entry.name)"
        }
        switch spec.manager {
        case "pip":
            // Every Python package goes into Briglia's private venv from the
            // reviewed lock (security plan v24 §7.9.4): never `pip install`
            // into the shared interpreter, never --break-system-packages.
            switch await PythonRuntime.converge(trigger: .install) {
            case .ready, .notSetUp: return nil
            case .unavailable(let w), .failed(let w): return w
            }
        case "brewFormula", "brewCask":
            #if os(Linux)
            guard let manager = linuxPackageManager() else {
                return "no supported package manager found (apt-get/dnf/pacman)"
            }
            return linuxInstall(LinuxPackageMap.package(spec.package, manager: manager.name), manager: manager)
            #else
            guard let brew = brewPath() else { return "Homebrew non trovato" }
            let args = spec.manager == "brewCask"
                ? ["install", "--cask", spec.package]
                : ["install", spec.package]
            let result = await ProcessRunner.runProcessAsync(
                executable: brew, args: args, timeoutSeconds: spec.timeoutSeconds
            )
            return result.failureDetail
            #endif
        default:
            return "gestore pacchetti sconosciuto"
        }
    }

    /// The 600 MB optional install, always behind its own explicit button.
    static func installLibreOffice() async -> String? {
        #if os(Linux)
        guard let manager = linuxPackageManager() else {
            return "no supported package manager found (apt-get/dnf/pacman)"
        }
        return linuxInstall(LinuxPackageMap.package("libreoffice", manager: manager.name), manager: manager)
        #else
        guard let brew = brewPath() else { return "Homebrew non trovato" }
        let result = await ProcessRunner.runProcessAsync(
            executable: brew, args: ["install", "--cask", "libreoffice"], timeoutSeconds: 2400
        )
        return result.failureDetail
        #endif
    }
}
