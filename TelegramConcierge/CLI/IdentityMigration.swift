import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Production wiring of the identity migration (RENAME_PLAN.md §4.2, §4.4,
/// §4.5, §4.6): the OLD product identity (`ada`) mapped onto THIS binary's
/// identity, read-only detection for diagnostics and startup gating, the
/// explicit `briglia migrate` command, the legacy environment-variable
/// warning, and the persona memory bridge.
///
/// The engine itself (MigrationEngine.swift) is identity-neutral and was
/// built and crash-tested under the previous identity (Stage 3); this file
/// only supplies its spec and the user-facing entry points.
enum IdentityMigration {
    // The retired identity — every literal that names the OLD product lives
    // here, on purpose, so the rest of the codebase never mentions it.
    static let oldProductDirName = "ada"
    static let oldBinaryName = "ada"
    static let oldLandingZoneDirName = "Documents/AdaCLI"
    static let oldUserUnitName = "ada.service"
    static let oldWakelockUnitName = "ada-keepawake.service"
    static let oldWakelockUnitPath = "/etc/systemd/system/ada-keepawake.service"
    static let oldPrefsDomain = "ada"
    static let newPrefsDomain = "briglia"
    static let oldPersonaName = "Ada"
    static let newPersonaName = "Bree"
    static let markerFileName = "migrated_from_ada.json"
    static let stateDirName = "briglia-migrate"
    static let recoveryCommand = "briglia migrate"
    /// Staged-file names an in-flight upgrade of the OLD binary leaves
    /// behind (UpgradeService of the previous identity).
    static let oldUpgradeMarkers = [".ada-upgrade-staged-bin", ".ada-upgrade-staged-bundle"]
    static let oldBundleName: String = {
        #if os(Linux)
        "ada-cli_ada.resources"
        #else
        "ada-cli_ada.bundle"
        #endif
    }()

    /// Every environment variable the previous identity read, by name.
    /// Startup warns when one is still set — by NAME ONLY, never echoing the
    /// value (several carry secrets or private URLs); plan §4.5.4. No
    /// aliasing, no auto-adoption.
    static let legacyEnvironmentVariables: [String] = [
        "ADA_DEBUG_PROCTREE", "ADA_ENVELOPE_URL", "ADA_IGNORE_LEGACY_SETUP_FLAG",
        "ADA_INSTALL_DIR", "ADA_MIDTURN_TYPED_ANNOTATIONS", "ADA_MIGRATE_CRASH_POINT",
        "ADA_MIGRATE_FAULT", "ADA_RELEASE_BASE", "ADA_RELEASE_PUBKEY_HEX",
        "ADA_RELEASE_TEST_KEY", "ADA_RELEASE_TRUST_FILE", "ADA_RELEASE_URL_PREFIX",
        "ADA_REPO_ROOT", "ADA_SETSID_PGID_FILE", "ADA_TELEGRAM_API_BASE",
        "ADA_TELEGRAM_RESET_WINDOW_SECONDS", "ADA_TEST_DURABILITY_FAULT_FLAG",
        "ADA_TEST_OPENROUTER_KEY", "ADA_TEST_SPILL_FAULT", "ADA_TOOLCHAIN_APT",
        "ADA_TOOLCHAIN_BIN", "ADA_TOOLCHAIN_DPKG", "ADA_TOOLCHAIN_DPKG_STATUS",
        "ADA_TOOLCHAIN_FAULT", "ADA_TOOLCHAIN_PATH", "ADA_TOOLCHAIN_ROOT",
        "ADA_TRIGGER_COOLDOWN_SECONDS", "ADA_TRIGGER_SPOOL_CAP", "ADA_UPGRADE_FAULT",
    ]

    /// Legacy variables present in `environment`, with the replacement name
    /// (the same name under the new prefix). Names only.
    static func legacyEnvironmentWarnings(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        legacyEnvironmentVariables.compactMap { name in
            guard environment[name] != nil else { return nil }
            let replacement = "BRIGLIA_" + name.dropFirst("ADA_".count)
            return "\(name) is set but no longer read; use \(replacement)."
        }
    }

    /// Print the legacy-variable warnings to stderr (interactive entry
    /// points and doctor).
    static func warnLegacyEnvironment() {
        for line in legacyEnvironmentWarnings() {
            FileHandle.standardError.write(Data("⚠ \(line)\n".utf8))
        }
    }

    // MARK: - Layout

    /// The home directory the migration works under. `$HOME` when set (the
    /// smoke/selftest fixtures redirect it), else the account's real home —
    /// the binary/wrapper directories and the landing zone hang off it.
    static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let value = environment["HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// This binary's real installed path (argv[0] may be a bare PATH name).
    static func ownExecutablePath() -> String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }

    /// Old and new roots, computed under the same XDG rules StoragePaths
    /// uses — purely, without creating anything.
    struct Roots {
        var oldConfig: String
        var newConfig: String
        var oldData: String
        var newData: String
        var oldLanding: String
        var newLanding: String
    }

    static func roots(environment: [String: String] = ProcessInfo.processInfo.environment) -> Roots {
        let home = home(environment: environment)
        return Roots(
            oldConfig: StoragePaths.resolveConfigRoot(productDirName: oldProductDirName,
                                                      environment: environment, home: home).path,
            newConfig: StoragePaths.resolveConfigRoot(environment: environment, home: home).path,
            oldData: StoragePaths.resolveDataRoot(productDirName: oldProductDirName,
                                                  environment: environment, home: home).path,
            newData: StoragePaths.resolveDataRoot(environment: environment, home: home).path,
            oldLanding: home.appendingPathComponent(oldLandingZoneDirName, isDirectory: true).path,
            newLanding: home.appendingPathComponent("Documents/Briglia", isDirectory: true).path)
    }

    static func stateDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        // XDG_STATE_HOME or ~/.local/state — under the SAME home rule as the
        // roots, so a redirected fixture never journals into the real home.
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent(stateDirName, isDirectory: true).path
        }
        return home(environment: environment)
            .appendingPathComponent(".local/state", isDirectory: true)
            .appendingPathComponent(stateDirName, isDirectory: true).path
    }

    /// Test seams honored ONLY by "-dev" source builds (the same gate the
    /// release-policy overrides use): a fake systemctl for the unit
    /// transaction where no real user bus exists, and throwaway
    /// preferences domains so a fixture migration never touches the
    /// machine's real `ada`/`briglia` domains.
    private static func devSeam(_ name: String,
                                environment: [String: String]) -> String? {
        guard adaCLIVersion.hasSuffix("-dev") else { return nil }
        guard let value = environment[name], !value.isEmpty else { return nil }
        return value
    }

    /// The standard systemctl locations, in order; nil when neither is an
    /// executable regular file.
    static let systemctlCandidates = ["/usr/bin/systemctl", "/bin/systemctl"]

    static func systemctlFixedPath() -> String? {
        for path in systemctlCandidates {
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  access(path, X_OK) == 0 else { continue }
            return path
        }
        return nil
    }

    /// The production spec: everything the engine needs to move an old
    /// install onto this binary's identity.
    static func productionSpec(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MigrationSpec {
        let roots = roots(environment: environment)
        let home = home(environment: environment)
        let newBinary = ownExecutablePath()
        let binDir = (newBinary as NSString).deletingLastPathComponent
        let wrapperBinDir = environment["BRIGLIA_TOOLCHAIN_BIN"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home.appendingPathComponent(".local/bin", isDirectory: true).path

        // systemd user units: managed only where a user bus is reachable
        // (or a dev fake is injected). A unit FILE without a bus is left in
        // place and reported — capture would otherwise refuse on the first
        // systemctl answer it cannot classify.
        var unitDir: String? = nil
        var systemctl: String? = nil
        var newUnitText: String? = nil
        if let fake = devSeam("BRIGLIA_MIGRATE_SYSTEMCTL", environment: environment) {
            systemctl = fake
        } else {
            #if os(Linux)
            // Fixed locations only — the engine never resolves systemctl
            // through PATH (a PATH entry the user or a script controls must
            // not choose the binary that stops and starts services during
            // the transaction). The -dev seam above is the only other way in.
            if AgentServiceSupport.systemdUserSessionAvailable(),
               let real = systemctlFixedPath() {
                systemctl = real
            }
            #endif
        }
        if systemctl != nil {
            unitDir = AgentServiceSupport.userUnitDirectory(home: home.path)
            newUnitText = AgentServiceSupport.userUnitText(adaPath: newBinary, home: home.path)
        }

        // Ubuntu Touch keep-awake system unit: captured always (when the
        // platform has it), recreated only with root privileges — phones
        // route that step through the companion app's sudo dialog.
        var wakelockOld: String? = nil
        var wakelockNew: String? = nil
        var wakelockOldName: String? = nil
        var wakelockNewName: String? = nil
        var wakelockText: String? = nil
        var wakelockSystemctl: String? = nil
        var wakelockManaged: Bool? = nil
        if let fakeSystemUnits = devSeam("BRIGLIA_MIGRATE_SYSTEM_UNIT_DIR", environment: environment),
           let fake = systemctl {
            wakelockOld = fakeSystemUnits + "/" + oldWakelockUnitName
            wakelockNew = fakeSystemUnits + "/" + AgentServiceSupport.wakelockUnitName
            wakelockOldName = oldWakelockUnitName
            wakelockNewName = AgentServiceSupport.wakelockUnitName
            wakelockText = AgentServiceSupport.wakelockUnitText()
            wakelockSystemctl = fake
            wakelockManaged = environment["BRIGLIA_MIGRATE_WAKELOCK_MANAGED"] == "1"
        } else if AgentServiceSupport.isUbuntuTouch(), let real = systemctl {
            wakelockOld = oldWakelockUnitPath
            wakelockNew = AgentServiceSupport.wakelockUnitPath
            wakelockOldName = oldWakelockUnitName
            wakelockNewName = AgentServiceSupport.wakelockUnitName
            wakelockText = AgentServiceSupport.wakelockUnitText()
            wakelockSystemctl = real
            wakelockManaged = geteuid() == 0
        }

        var oldPrefs: String? = oldPrefsDomain
        var newPrefs: String? = newPrefsDomain
        if let seam = devSeam("BRIGLIA_MIGRATE_PREFS_DOMAINS", environment: environment) {
            let parts = seam.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                oldPrefs = parts[0]
                newPrefs = parts[1]
            } else {
                oldPrefs = nil
                newPrefs = nil
            }
        }

        return MigrationSpec(
            oldConfigRoot: roots.oldConfig, newConfigRoot: roots.newConfig,
            oldDataRoot: roots.oldData, newDataRoot: roots.newData,
            oldLandingZone: roots.oldLanding, newLandingZone: roots.newLanding,
            oldBinary: binDir + "/" + oldBinaryName, newBinary: newBinary,
            oldBundle: binDir + "/" + oldBundleName,
            newBundle: binDir + "/" + BundleCheck.bundleName,
            wrapperBinDir: wrapperBinDir,
            unitDir: unitDir,
            oldUnitName: systemctl == nil ? nil : oldUserUnitName,
            newUnitName: systemctl == nil ? nil : AgentServiceSupport.userUnitName,
            newUnitText: newUnitText,
            systemctl: systemctl,
            oldWakelockUnitPath: wakelockOld, newWakelockUnitPath: wakelockNew,
            oldWakelockUnitName: wakelockOldName, newWakelockUnitName: wakelockNewName,
            newWakelockUnitText: wakelockText,
            wakelockSystemctl: wakelockSystemctl, wakelockManaged: wakelockManaged,
            healthProbe: [newBinary, MigrateProbe.configuration.commandName ?? "__migrate-probe"],
            healthProbeTimeout: 60,
            stateDir: stateDir(environment: environment),
            personaOldName: oldPersonaName, personaNewName: newPersonaName,
            personaMarkerName: markerFileName,
            oldPrefsDomain: oldPrefs, newPrefsDomain: newPrefs,
            toolchainWrapperMarker: UserdataToolchain.legacyWrapperMarker,
            agentmailWrapperName: "agentmail",
            upgradeMarkerNames: oldUpgradeMarkers,
            recoveryCommand: recoveryCommand)
    }

    // MARK: - Detection (read-only)

    struct Status {
        var oldConfigPresent: Bool
        var oldDataPresent: Bool
        var newConfigPresent: Bool
        var newDataPresent: Bool
        var journalState: String?
        /// The engine's transaction lock is held right now by ANOTHER
        /// process: a migration (or recovery) is live. flock dies with its
        /// holder, so a crashed migrator never leaves this true.
        var migrationLockHeld: Bool
        /// The live journal's durable "new install ready" flag: roots moved
        /// and every fixup applied — the migrator set it before starting
        /// the new service and probing it.
        var newInstallReady: Bool
        var roots: Roots

        var oldPresent: Bool { oldConfigPresent || oldDataPresent }
        /// A journal exists AND its owner is alive: mid-transaction, not
        /// interrupted.
        var migrationRunning: Bool { journalState != nil && migrationLockHeld }
        /// The one legitimate start against a live journal: the migrator has
        /// finished moving/fixing the roots and is now health-probing the
        /// new identity — which means STARTING its daemon (systemd) and
        /// running `__migrate-probe`. Both must be admitted, or the probe
        /// waits for a lock the refused daemon never takes and rolls back
        /// (the 0.2.0 Linux defect). No old root may remain, as everywhere.
        var servedByLiveMigration: Bool { migrationRunning && newInstallReady && !oldPresent }
        var newPresent: Bool { newConfigPresent || newDataPresent }
        /// Old AND new roots coexist with no journal explaining it: a
        /// CONFLICT the user must resolve by hand — never "harmless
        /// residue" (Codex Stage 4 round 1). The engine refuses to migrate
        /// onto a pre-existing destination, so the outward gate must not
        /// let anything write the new roots either.
        var conflict: Bool { journalState == nil && oldPresent && newPresent }
        /// The gate: ANY old root present (clean pending migration or
        /// conflict), or an interrupted migration's journal.
        var pending: Bool { !servedByLiveMigration && (journalState != nil || oldPresent) }
        var oldRootsPresent: [String] {
            [(oldConfigPresent, roots.oldConfig), (oldDataPresent, roots.oldData)]
                .compactMap { $0.0 ? $0.1 : nil }
        }
        var newRootsPresent: [String] {
            [(newConfigPresent, roots.newConfig), (newDataPresent, roots.newData)]
                .compactMap { $0.0 ? $0.1 : nil }
        }
        /// Exit status of `briglia migrate --status`, consumed by the
        /// installers: 0 nothing to do, 3 migration pending (run it),
        /// 4 conflict (resolve by hand first).
        var statusExitCode: Int32 { conflict ? 4 : (pending ? 3 : 0) }
    }

    /// Zero writes (the engine's detect is read-only; plan §4.2).
    static func status(environment: [String: String] = ProcessInfo.processInfo.environment) -> Status {
        let roots = roots(environment: environment)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        func present(_ path: String) -> Bool {
            fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        let journalPath = URL(fileURLWithPath: stateDir(environment: environment))
            .appendingPathComponent("journal.json")
        var state: String? = nil
        var ready = false
        if fm.fileExists(atPath: journalPath.path) {
            // The gate trusts `newInstallReady` only from a journal that
            // passes the engine's own load validation (schema, spec
            // equality with THIS binary's production spec, path
            // confinement, unit names). A journal that merely decodes is
            // not enough: an invalid one counts as unreadable and keeps
            // the gate closed — recovery, not the daemon, gets to look at
            // it.
            switch MigrationEngine.loadJournal(spec: productionSpec(environment: environment)) {
            case .success(let parsed):
                state = parsed.state
                ready = parsed.newInstallReady == true
            case .failure:
                state = "unreadable"
            }
        }
        // Same lock the engine holds for its whole transaction (a SIBLING
        // of the state dir; see MigrationEngine.run). Probed with LOCK_NB
        // and released at once — never kept. A probe that fails for any
        // reason other than "no lock file" is NOT a live holder: the
        // journal then reads as interrupted, which refuses.
        let lockHeld = state != nil
            && MigrationEngine.lockProbe(migrationLockPath(environment: environment)).isHeld
        return Status(oldConfigPresent: present(roots.oldConfig),
                      oldDataPresent: present(roots.oldData),
                      newConfigPresent: present(roots.newConfig),
                      newDataPresent: present(roots.newData),
                      journalState: state, migrationLockHeld: lockHeld,
                      newInstallReady: ready, roots: roots)
    }

    /// The engine's transaction lock path for this environment — MUST match
    /// what MigrationEngine derives from the production spec's `stateDir`
    /// (the migration selftest pins the equality).
    static func migrationLockPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let dir = stateDir(environment: environment)
        return (dir.hasSuffix("/") ? String(dir.dropLast()) : dir) + ".lock"
    }

    /// The refusal text for an interactive start against an unmigrated
    /// install (plan §4.2). Exact command included; nothing is done.
    static func pendingMessage(_ status: Status) -> String {
        if let state = status.journalState, status.migrationRunning {
            return "✖ An identity migration is running right now (journal state: \(state)).\n"
                + "  Wait for it to finish — it starts Briglia itself once the migrated install "
                + "passes its health probe. If it was interrupted, run `\(recoveryCommand)` to recover.\n"
                + "  Diagnostics (`briglia doctor`, `briglia setup-api status`) work meanwhile."
        }
        if let state = status.journalState {
            return "✖ An identity migration was interrupted (journal state: \(state)).\n"
                + "  Run `\(recoveryCommand)` to recover — nothing is changed until you do.\n"
                + "  Diagnostics (`briglia doctor`, `briglia setup-api status`) work meanwhile."
        }
        if status.conflict {
            return "✖ An Ada CLI installation (\(status.oldRootsPresent.joined(separator: ", "))) AND "
                + "Briglia directories (\(status.newRootsPresent.joined(separator: ", "))) both exist.\n"
                + "  Briglia will not silently ignore the Ada data, and `\(recoveryCommand)` refuses to "
                + "migrate onto pre-existing Briglia directories. Resolve by hand, then run "
                + "`\(recoveryCommand)`:\n"
                + "    · move the Briglia directories aside (e.g. `mv <dir> <dir>.bak`) if they are stray "
                + "or from a fresh setup you don't need — the Ada data then migrates; or\n"
                + "    · remove the old Ada directories if you no longer need that data.\n"
                + "  Diagnostics (`briglia doctor`, `briglia setup-api status`, `\(recoveryCommand) --status`) work meanwhile."
        }
        let found = status.oldRootsPresent
        return "✖ An existing Ada CLI installation was found (\(found.joined(separator: ", "))) "
            + "and has not been migrated to Briglia yet.\n"
            + "  Run `\(recoveryCommand)` to move your configuration, memory, watchers and "
            + "service to Briglia. Nothing is deleted; the migration journals every step and "
            + "restores the old install if it cannot complete.\n"
            + "  Diagnostics (`briglia doctor`, `briglia setup-api status`) work without migrating."
    }

    /// Startup gate for entry points that would CREATE or WRITE the new
    /// roots (chat, daemon, setup, service install, upgrade, toolchain,
    /// trigger). Prints the refusal and throws; otherwise materializes the
    /// roots for the caller.
    static func gateMutatingEntry() throws {
        let current = status()
        if current.pending {
            print(pendingMessage(current))
            throw ExitCode(2)
        }
        // A root that exists as something other than a directory (a regular
        // file, a FIFO, a link to nowhere) cannot be written: refuse here,
        // for every mutating entry point, instead of letting the command
        // proceed and fail somewhere inside.
        do {
            try StoragePaths.ensureRootsChecked()
        } catch {
            print("✖ Storage root cannot be used: \(error)\n"
                  + "  Both `\(StoragePaths.configRootDisplay)` and `\(StoragePaths.dataRootDisplay)` must be directories owned by you "
                  + "— move the offending object aside and retry. Diagnostics (`briglia doctor`) work meanwhile.")
            throw ExitCode(2)
        }
    }

    // MARK: - Persona bridge (plan §4.4)

    /// The prior assistant name recorded by the durable persona marker, or
    /// nil on installs that never migrated. Read-only.
    static func priorPersonaName(dataRoot: URL = StoragePaths.dataRoot) -> String? {
        let url = dataRoot.appendingPathComponent(markerFileName)
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let prior = object["priorName"] as? String,
              !prior.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return prior
    }

    // MARK: - Doctor lines (read-only; plan §4.3 "doctor only reports")

    /// One entry per finding: (isProblem, text, hint).
    static func doctorFindings() -> [(problem: Bool, text: String, hint: String?)] {
        var out: [(Bool, String, String?)] = []
        let current = status()
        if let state = current.journalState, current.migrationRunning {
            out.append((false, "an identity migration is running right now (journal state: \(state)"
                + (current.newInstallReady ? ", new install ready" : "") + ")",
                "wait for it to finish; `\(recoveryCommand)` recovers it only if it was interrupted"))
        } else if let state = current.journalState {
            out.append((true, "interrupted identity migration (journal state: \(state))",
                        "run `\(recoveryCommand)` to recover — nothing is changed until you do"))
        } else if current.conflict {
            out.append((true, "CONFLICT: Ada CLI roots (\(current.oldRootsPresent.joined(separator: ", "))) "
                + "and Briglia roots (\(current.newRootsPresent.joined(separator: ", "))) coexist — "
                + "Briglia refuses to run and `\(recoveryCommand)` refuses to migrate onto them",
                "move the Briglia directories aside (or remove the old Ada ones), then run `\(recoveryCommand)`"))
        } else if current.pending {
            out.append((true, "an Ada CLI installation is present and not migrated",
                        "run `\(recoveryCommand)`"))
        }
        let compat = home().appendingPathComponent(".local/bin/" + oldBinaryName).path
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: compat) {
            out.append((false, "compatibility symlink \(compat) → \(target) (old scripts keep working; "
                + "remove it by hand when no longer needed)", nil))
        }
        if let prior = priorPersonaName() {
            out.append((false, "migrated from \(prior)-era install (persona marker present)", nil))
        }
        if current.pending, current.journalState == nil,
           let existing = Prefs.domains.persistentDomain(forName: newPrefsDomain),
           !existing.isEmpty {
            out.append((false, "the `\(newPrefsDomain)` preferences domain already holds "
                + "\(existing.count) key(s) — the migration refuses to overwrite it; if only "
                + "test runs wrote it, clear it first (macOS: defaults delete \(newPrefsDomain))",
                nil))
        }
        for line in legacyEnvironmentWarnings() {
            out.append((false, line, nil))
        }
        return out
    }
}

// MARK: - `briglia migrate`

struct Migrate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Move an existing Ada CLI installation (config, memory, watchers, service) to Briglia."
    )

    @Flag(name: .long, help: "Roll back an interrupted migration instead of completing it (honored only before its commit point).")
    var rollback = false

    @Flag(name: .long, help: "Report the migration state and exit without changing anything (exit 0 = nothing to do, 3 = migration pending, 4 = conflict to resolve by hand).")
    var status = false

    @Flag(name: .long, help: .hidden)
    var dumpSpec = false

    func run() throws {
        try AssistantProfile.requireDefault(AssistantProfile.migrateMessage)
        AdaCLI.prepareIO()
        if dumpSpec {
            // Read-only: the exact spec this binary would hand the engine.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(IdentityMigration.productionSpec())
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        let current = IdentityMigration.status()
        if status {
            let r = current.roots
            print("old config: \(r.oldConfig) — \(current.oldConfigPresent ? "present" : "absent")")
            print("old data:   \(r.oldData) — \(current.oldDataPresent ? "present" : "absent")")
            print("new config: \(r.newConfig) — \(current.newConfigPresent ? "present" : "absent")")
            print("new data:   \(r.newData) — \(current.newDataPresent ? "present" : "absent")")
            print("journal:    \(current.journalState ?? "none")")
            let verdict: String
            if current.conflict {
                verdict = "CONFLICT — old and new roots coexist; resolve by hand, then run `\(IdentityMigration.recoveryCommand)`"
            } else if current.pending {
                verdict = "PENDING — run `\(IdentityMigration.recoveryCommand)`"
            } else {
                verdict = "not needed"
            }
            print("migration:  \(verdict)")
            if current.statusExitCode != 0 { throw ExitCode(current.statusExitCode) }
            return
        }
        if !current.pending {
            if !current.oldConfigPresent && !current.oldDataPresent
                && !current.newConfigPresent && !current.newDataPresent {
                print("Nothing to migrate — no Ada CLI installation found. Run `briglia setup`.")
            } else {
                print("Nothing to migrate — this install is already on Briglia.")
            }
            return
        }
        if rollback && current.journalState == nil {
            print("✖ nothing to roll back — no interrupted migration journal exists "
                + "(a completed migration is not reversible by this command)")
            throw ExitCode(2)
        }
        let spec = IdentityMigration.productionSpec()
        if current.conflict {
            // Straight to the engine: its pre-existing-destination refusal
            // is the fail-closed answer (nothing is changed, no journal).
            print("Old and new roots coexist — asking the migration engine, which refuses "
                + "to migrate onto pre-existing Briglia directories:")
        } else if current.journalState == nil {
            print("Migrating the Ada CLI installation to Briglia:")
            print("  \(spec.oldConfigRoot) → \(spec.newConfigRoot)")
            print("  \(spec.oldDataRoot) → \(spec.newDataRoot)")
            if FileManager.default.fileExists(atPath: spec.oldLandingZone ?? "") {
                print("  \(spec.oldLandingZone!) → \(spec.newLandingZone!)")
            }
            print("  assistant name \(spec.personaOldName) → \(spec.personaNewName) (only if still exactly \(spec.personaOldName))")
            if spec.systemctl == nil {
                #if os(Linux)
                print("  (no systemd user session reachable — service units are not managed by this run)")
                #endif
            }
        } else {
            print(rollback ? "Rolling back the interrupted migration…"
                           : "Recovering the interrupted migration…")
        }
        let outcome = MigrationEngine.run(spec: spec, mode: rollback ? .rollback : .auto) {
            print("· \($0)")
        }
        switch outcome {
        case .ok(let notes):
            for note in notes { print("✔ \(note)") }
            if rollback {
                print("Rolled back — the Ada CLI installation is back in place.")
            } else {
                print("Done. Start with `briglia` (or `briglia daemon`). Your assistant answers to "
                    + "\(spec.personaNewName) now unless you had given it a custom name.")
            }
        case .refused(let why):
            print("✖ refused: \(why)")
            if current.conflict {
                print("  Resolve by hand: move the Briglia directories aside (e.g. `mv <dir> <dir>.bak`) "
                    + "so the Ada data can migrate, or remove the old Ada directories if you no longer "
                    + "need that data — then rerun `\(IdentityMigration.recoveryCommand)`.")
            }
            throw ExitCode(2)
        case .corrupt(let why):
            print("✖ the migration journal failed validation: \(why)")
            throw ExitCode(3)
        case .failed(let why):
            print("✖ \(why)")
            throw ExitCode(1)
        }
    }
}

/// Hidden health probe the engine runs against the NEW identity before it
/// retires anything (plan §4.3.5b): the roots must exist and be readable
/// under this binary's own path rules, the secret store must decode, and
/// the setup API must be at the schema the companion app requires. Exit 0
/// only when all hold. Read-only.
struct MigrateProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__migrate-probe",
        abstract: "Internal: verify this identity serves the migrated roots.",
        shouldDisplay: false
    )

    func run() throws {
        try AssistantProfile.requireDefault(AssistantProfile.migrateMessage)
        AdaCLI.prepareIO()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        func dir(_ path: String) -> Bool {
            fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        // No old root may remain at all — whatever the new side holds. The
        // probe runs before retirement and again after commit: accepting
        // an old root next to a new one would retire Ada and leave Briglia
        // refusing to start on the very conflict it created (Codex Stage 4
        // round 2). The new identity must serve at least one root; a root
        // the old install never had (data-only installs) is not required —
        // the first mutating command creates it.
        let roots = IdentityMigration.roots()
        var served = 0
        for (old, new) in [(roots.oldConfig, roots.newConfig), (roots.oldData, roots.newData)] {
            if dir(old) {
                print("PROBE-FAIL: old root still present: \(old)"
                    + (dir(new) ? " (new root \(new) also exists — mixed roots)" : " (new root \(new) missing)"))
                throw ExitCode(1)
            }
            if dir(new) { served += 1 }
        }
        guard served > 0 else {
            print("PROBE-FAIL: neither \(roots.newConfig) nor \(roots.newData) exists")
            throw ExitCode(1)
        }
        if let problem = KeychainHelper.storeReadProblem() {
            print("PROBE-FAIL: secret store: \(problem)")
            throw ExitCode(1)
        }
        guard SetupAPICore.schemaVersion == 2 else {
            print("PROBE-FAIL: setup-api schema \(SetupAPICore.schemaVersion) (expected 2)")
            throw ExitCode(1)
        }
        // The daemon the migrator (re)starts runs the SAME startup gate as
        // every mutating command. If that gate would refuse right now, the
        // migrated install is not healthy whatever the roots look like —
        // fail here, in seconds, with the reason, instead of waiting for an
        // instance lock a refused daemon never takes (0.2.0 Linux defect).
        let gate = IdentityMigration.status()
        if gate.pending {
            print("PROBE-FAIL: the startup gate would refuse `briglia daemon` right now — "
                + IdentityMigration.pendingMessage(gate).split(separator: "\n").first.map(String.init).orEmpty)
            throw ExitCode(1)
        }
        print("PROBE-OK schema=\(SetupAPICore.schemaVersion) config=\(StoragePaths.configRoot.path) data=\(StoragePaths.dataRoot.path)")
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

/// Hidden: exactly the startup gate `briglia daemon`/`chat` run, and nothing
/// else — exit 0 (GATE-OK) when a mutating entry would be admitted right
/// now, the refusal text and exit 2 otherwise. The migration selftest's
/// fake systemd runs it in place of the real daemon so the "started daemon
/// takes the instance lock" check exercises the real gate rather than a
/// lock-holder that cannot refuse (how 0.2.0 shipped blind).
struct MigrateGate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__migrate-gate",
        abstract: "Internal: would a mutating command be admitted right now?",
        shouldDisplay: false
    )

    func run() throws {
        try AssistantProfile.requireDefault(AssistantProfile.migrateMessage)
        AdaCLI.prepareIO()
        try IdentityMigration.gateMutatingEntry()
        print("GATE-OK config=\(StoragePaths.configRoot.path) data=\(StoragePaths.dataRoot.path)")
    }
}
