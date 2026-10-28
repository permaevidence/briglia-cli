import ArgumentParser
import Foundation

/// Self-update from the public release CDN — the same artifacts the curl
/// installer uses. Downloads the tarball for this platform, verifies its
/// SHA-256 against the manifest, and swaps the installed binary + resource
/// bundle in place (with sudo when the install directory needs it).
/// The download/verify/swap core lives in UpgradeService, shared with the
/// `/upgrade` chat command.
struct Upgrade: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update Briglia CLI to the latest published release.",
        aliases: ["update"]
    )

    @Flag(name: [.customShort("y"), .long], help: "Do not ask for confirmation.")
    var yes = false

    @Flag(name: .long, help: "Finish or undo an interrupted update (when several assistants are set up).")
    var recover = false

    func run() async throws {
        try AssistantProfile.requireDefault(AssistantProfile.upgradeMessage)
        if recover {
            // §6.5: takes upgrade.lock before any session check; no profile
            // initialisation, no bundle access except its own probes.
            let result = UpgradeCoordinator.recoverCommand()
            print(result.text)
            if !result.ok { throw ExitCode(1) }
            return
        }
        try IdentityMigration.gateMutatingEntry()
        if CoordinationMode.active {
            try await runCoordinated()
            return
        }
        print("Checking for updates…")
        let update: UpgradeService.Update
        var checkedManifest: ReleaseSigning.Manifest? = nil
        let result = await UpgradeService.check(warn: { print($0) }, onManifest: { checkedManifest = $0 })
        // Display only (security plan v8 §5.6).
        if let note = ConversationManager.upgradeDisplayNote(manifest: checkedManifest, installed: adaCLIReleaseSequence,
                                                            observed: ConversationManager.observedForUpgradeDisplay()) {
            print(note)
        }
        switch result {
        case .rollbackRefused(let live, let floor):
            print("✖ The release channel serves signed metadata with sequence \(live), BELOW this install's trusted floor \(floor). This can be a stale mirror — or a rollback attack. Refusing; if it persists, check https://github.com/permaevidence/briglia-cli/releases directly.")
            throw ExitCode(1)
        case .unsupportedPlatform:
            print("✖ No prebuilt releases exist for this platform.")
            throw ExitCode(1)
        case .failed(let reason):
            print("✖ Could not fetch the release manifest: \(reason)")
            throw ExitCode(1)
        case .upToDate(let version):
            print("✔ Already up to date (\(version)).")
            return
        case .noBuildForPlatform(let version, let platform):
            print("✖ Release \(version) has no build for \(platform) (yet).")
            throw ExitCode(1)
        case .manifestOlder(let current, let manifest):
            print("⚠ The release feed serves \(manifest), older than the installed \(current) — a release is probably still publishing. Not downgrading; try again in a few minutes.")
            return
        case .available(let available):
            update = available
        }

        if adaCLIVersion.hasSuffix("-dev") {
            print("⚠ This is a source build (\(adaCLIVersion)) — upgrading replaces it with the prebuilt release \(update.version).")
        } else {
            print("Update available: \(adaCLIVersion) → \(update.version)")
        }
        if !yes {
            print("Install? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                return
            }
        }

        do {
            try await UpgradeService.downloadAndInstall(update, allowSudo: true) { print($0) }
        } catch {
            print("✖ \(error.localizedDescription)")
            throw ExitCode(1)
        }
        print("✔ Briglia CLI updated to \(update.version).")
    }

    /// The machine upgrade barrier (MULTI_ASSISTANT_PLAN §6): this process is
    /// a session coordinator. Every running assistant parks, the pair is
    /// swapped under the journal, every assistant restarts; this command
    /// closes the barrier when they are back.
    func runCoordinated() async throws {
        let lock: ProfileFileLock
        switch UpgradeCoordinator.acquire() {
        case .success(let l): lock = l
        case .failure(let why): print("✖ \(why)"); throw ExitCode(1)
        }
        defer { lock.release() }
        let settings = UpgradeCoordinator.Settings()
        if let why = UpgradeCoordinator.settlePrevious(settings) { print("✖ \(why)"); throw ExitCode(1) }
        let staged: StagedUpgrade
        if let testDir = Self.testStagedDirectory() {
            staged = testDir
        } else {
            print("Checking for updates…")
            let result = await UpgradeService.check(warn: { print($0) })
            let update: UpgradeService.Update
            switch result {
            case .available(let available): update = available
            case .upToDate(let version): print("✔ Already up to date (\(version))."); return
            case .rollbackRefused(let live, let floor):
                print("✖ The release channel serves signed metadata with sequence \(live), BELOW this install's trusted floor \(floor). Refusing.")
                throw ExitCode(1)
            case .manifestOlder(let current, let manifest):
                print("⚠ The release feed serves \(manifest), older than the installed \(current). Not downgrading."); return
            case .unsupportedPlatform: print("✖ No prebuilt releases exist for this platform."); throw ExitCode(1)
            case .noBuildForPlatform(let version, let platform): print("✖ Release \(version) has no build for \(platform) (yet)."); throw ExitCode(1)
            case .failed(let reason): print("✖ Could not fetch the release manifest: \(reason)"); throw ExitCode(1)
            }
            print("Update available: \(adaCLIVersion) → \(update.version)")
            if !yes {
                print("Install? Every running assistant pauses at a quiet moment and restarts. [y/N] ", terminator: "")
                guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else { print("Cancelled."); return }
            }
            guard UpgradeService.installDirWritable() else {
                print("✖ \(UpgradeService.installDir.path) is not writable; with several assistants the update cannot use sudo. Reinstall with the installer as the owner of that folder.")
                throw ExitCode(1)
            }
            do { staged = try await UpgradeService.downloadAndStage(update) { print($0) } } catch {
                print("✖ \(error.localizedDescription)"); throw ExitCode(1)
            }
        }
        defer { if let tmp = staged.tempDirectory { try? FileManager.default.removeItem(at: tmp) } }
        print("Waiting for every assistant to reach a quiet moment (up to 10 minutes)…")
        let outcome = await UpgradeCoordinator.run(staged: staged, settings: settings, holding: lock)
        switch outcome {
        case .committed(let version, _):
            print("✔ Briglia CLI updated to \(version); every assistant restarted.")
        case .cancelled(let why):
            print("✖ Update cancelled: \(why)"); throw ExitCode(1)
        case .refused(let why):
            print("✖ \(why)"); throw ExitCode(1)
        case .stuck(let why):
            print("✖ \(why)\n\(UpgradeBarrier.stuckMessage)"); throw ExitCode(1)
        }
    }

    /// Development builds only: install a local pair instead of downloading
    /// (`BRIGLIA_TEST_UPGRADE_STAGED=<dir>` with `briglia` and the bundle).
    static func testStagedDirectory() -> StagedUpgrade? {
        guard adaCLIVersion.hasSuffix("-dev"),
              let dir = ProcessInfo.processInfo.environment["BRIGLIA_TEST_UPGRADE_STAGED"], !dir.isEmpty else { return nil }
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let binary = base.appendingPathComponent("briglia")
        let version = (try? String(contentsOf: base.appendingPathComponent("version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "test"
        return StagedUpgrade(version: version, sequence: ReleaseSequence.of(executable: binary), binary: binary,
                             bundle: base.appendingPathComponent(BundleCheck.bundleName), tempDirectory: nil)
    }
}
