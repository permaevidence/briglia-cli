import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Core of the self-update flow, shared by the `briglia upgrade` terminal command
/// and the `/upgrade` chat command: manifest check against the release CDN,
/// checksum-verified download, in-place binary + resource-bundle swap, and —
/// for the chat path — self-restart via execv with a marker file so the
/// restarted process can announce the completed update.
enum UpgradeService {
    /// Signed release channel (docs/RELEASE_SIGNING_PLAN.md §8.1): the update
    /// check trusts ONLY the Ed25519-signed envelope published as a GitHub
    /// Release asset. There is no unsigned metadata path in this binary —
    /// the pre-signature Vercel Blob feed was retired when the transition
    /// window closed (§6.3), and the anti-rollback floor below prevents any
    /// signed release older than the last accepted one.
    static let defaultEnvelopeURL =
        "https://github.com/\(adaCLIReleaseRepository)/releases/latest/download/manifest.sig.json"

    /// Discovery URL only — everything fetched from it is verified against
    /// the pinned key, so an override can at worst deny availability (which
    /// any env-controlling attacker already can). Needed by the staging
    /// pipeline and the publisher tests.
    static var envelopeURL: String {
        ProcessInfo.processInfo.environment["BRIGLIA_ENVELOPE_URL"] ?? defaultEnvelopeURL
    }


    static let platformKey: String? = {
        #if os(macOS) && arch(arm64)
        return "macos-arm64"
        #elseif os(Linux) && arch(x86_64)
        return "linux-x64"
        #elseif os(Linux) && arch(arm64)
        return "linux-arm64"
        #else
        return nil
        #endif
    }()

    struct Update {
        let version: String
        let url: String
        let sha256: String
        /// Authenticated exact artifact size from the signed manifest —
        /// the download is bounded by it, never by Content-Length.
        let size: Int64
    }

    enum CheckResult {
        case upToDate(String)
        case available(Update)
        case unsupportedPlatform
        case noBuildForPlatform(version: String, platform: String)
        /// The live manifest is OLDER than the installed version — a release
        /// still publishing (or a publish race). Never "upgrade" onto it.
        case manifestOlder(current: String, manifest: String)
        /// Signed metadata below this install's anti-rollback floor (the
        /// binary's embedded sequence or the persisted highest verified
        /// sequence). Distinct from manifestOlder: this is the signature-era
        /// refusal and may indicate a rollback/freeze attack on the channel.
        case rollbackRefused(liveSequence: Int, floor: Int)
        case failed(String)
    }

    /// Numeric core of a version string: "0.1.4" → [0,1,4], "0.1.0-dev" →
    /// [0,1,0]. Returns nil when the core isn't dotted integers.
    static func versionComponents(_ version: String) -> [Int]? {
        let core = version.split(separator: "-")[0]
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// True when `candidate` is numerically lower than `installed`. Unparseable
    /// versions compare as not-lower — the check must fail open to "offer it"
    /// rather than silently strand an install on a weird version string.
    static func isDowngrade(candidate: String, installed: String) -> Bool {
        guard let c = versionComponents(candidate), let i = versionComponents(installed) else {
            return false
        }
        let count = max(c.count, i.count)
        let cPadded = c + Array(repeating: 0, count: count - c.count)
        let iPadded = i + Array(repeating: 0, count: count - i.count)
        for (a, b) in zip(cPadded, iPadded) where a != b { return a < b }
        return false
    }

    struct UpgradeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The installed executable, symlinks resolved — the thing an upgrade
    /// replaces and a restart re-executes.
    static var executableURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
    }

    static var installDir: URL { executableURL.deletingLastPathComponent() }

    static func installDirWritable() -> Bool {
        FileManager.default.isWritableFile(atPath: installDir.path)
    }

    /// `warn` surfaces non-fatal trust-state problems (corrupt or unwritable
    /// anti-rollback file) without failing the check — per the plan they are
    /// reported, never silently swallowed.
    static func check(warn: (String) -> Void = { _ in }) async -> CheckResult {
        guard let platform = platformKey else { return .unsupportedPlatform }
        let policy = ReleasePolicy.effective
        let manifest: ReleaseSigning.Manifest
        do {
            let raw = try await BoundedHTTP.fetchData(
                url: URL(string: envelopeURL)!, maxBytes: ReleaseSigning.maxEnvelopeBytes)
            manifest = try ReleaseSigning.verifyEnvelope(raw, policy: policy)
        } catch {
            return .failed(error.localizedDescription)
        }
        // Anti-rollback floor for THIS trust domain only (channel + pinned
        // artifact location): a staging or mock channel's sequence is never
        // production's floor, and vice versa.
        let trust = ReleaseTrustStore.load(domain: policy.trustDomain)
        if trust.corrupt {
            warn("⚠ the local release-trust state file is corrupt or in an unrecognized format — rebuilt from this binary's embedded sequence floor (\(adaCLIReleaseSequence))")
        }
        let decision = decide(
            manifest: manifest, installedVersion: adaCLIVersion,
            ownSequence: adaCLIReleaseSequence, persistedSequence: trust.sequence,
            platform: platform)
        // Persist the highest verified sequence only for metadata that passed
        // every check and moved anti-rollback state forward. The store is a
        // locked monotonic merge, so a concurrent check that verified a
        // newer sequence can never be overwritten by this one. A persist
        // failure is reported, never treated as silent success.
        switch decision {
        case .upToDate, .available:
            if manifest.sequence > (trust.sequence ?? 0) {
                do {
                    try ReleaseTrustStore.store(manifest.sequence, domain: policy.trustDomain)
                } catch {
                    warn("⚠ could not persist the anti-rollback sequence (\(error.localizedDescription)) — the embedded floor still applies")
                }
            }
        default:
            break
        }
        return decision
    }

    /// Pure decision core over an already-AUTHENTICATED manifest — separated
    /// so the selftest can exercise every sequence/version combination.
    static func decide(
        manifest: ReleaseSigning.Manifest, installedVersion: String,
        ownSequence: Int, persistedSequence: Int?, platform: String
    ) -> CheckResult {
        let floor = max(ownSequence, persistedSequence ?? 0)
        if manifest.sequence < floor {
            return .rollbackRefused(liveSequence: manifest.sequence, floor: floor)
        }
        if manifest.sequence == ownSequence {
            if manifest.version == installedVersion {
                return .upToDate(installedVersion)
            }
            if isDowngrade(candidate: manifest.version, installed: installedVersion) {
                return .manifestOlder(current: installedVersion, manifest: manifest.version)
            }
            return .failed("live release repeats this install's sequence \(ownSequence) with a different version (\(manifest.version) vs \(installedVersion)) — refusing inconsistent metadata")
        }
        // manifest.sequence > ownSequence (and >= persisted floor)
        if manifest.version == installedVersion {
            return .failed("live release repeats the installed version \(installedVersion) under a newer sequence \(manifest.sequence) — refusing inconsistent metadata")
        }
        // Release publishing can race; a newer sequence must also carry a
        // strictly newer version. Applies to source builds too: "0.1.4-dev"
        // must not be "upgraded" to 0.1.2.
        if isDowngrade(candidate: manifest.version, installed: installedVersion) {
            return .manifestOlder(current: installedVersion, manifest: manifest.version)
        }
        guard let entry = manifest.platforms[platform] else {
            return .noBuildForPlatform(version: manifest.version, platform: platform)
        }
        return .available(Update(
            version: manifest.version, url: entry.url, sha256: entry.sha256, size: entry.size))
    }

    /// Download, verify, unpack, and swap the installed binary + bundle.
    /// `allowSudo: false` (the chat path) requires a writable install dir —
    /// callers check `installDirWritable()` first for a friendlier message.
    static func downloadAndInstall(
        _ update: Update,
        allowSudo: Bool,
        progress: (String) -> Void
    ) async throws {
        try TurnCheckpointStore.refuseReplacementWithUnfinishedEnvelope()
        progress("Downloading…")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("briglia-upgrade-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let tarball = tmp.appendingPathComponent("briglia.tar.gz")

        guard update.size > 0 else {
            throw UpgradeError(message: "release entry carries no authenticated size — refusing an unbounded download")
        }
        // Stream to disk enforcing the AUTHENTICATED exact size while
        // receiving, hashing incrementally — no unbounded in-memory
        // buffering of attacker-reachable bytes.
        let digest = try await BoundedHTTP.downloadFile(
            url: URL(string: update.url)!, to: tarball, expectedBytes: update.size)
        guard digest == update.sha256.lowercased() else {
            throw UpgradeError(message: "checksum mismatch — download corrupted or tampered with; nothing was changed")
        }
        try runOrThrow("/usr/bin/tar", ["-xzf", tarball.path, "-C", tmp.path])

        let bundleName = BundleCheck.bundleName
        let newBinary = tmp.appendingPathComponent("briglia")
        let newBundle = tmp.appendingPathComponent(bundleName)
        guard fm.fileExists(atPath: newBinary.path), fm.fileExists(atPath: newBundle.path) else {
            throw UpgradeError(message: "unexpected tarball layout — expected briglia + \(bundleName)")
        }

        // Validate the unpacked build BEFORE touching the installation:
        // bundle-check proves the binary starts and finds its resources.
        // A corrupted release therefore fails while the current install is
        // still fully intact.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        do {
            try runOrThrow(newBinary.path, ["bundle-check"], currentDirectory: "/")
        } catch {
            throw UpgradeError(message: "the downloaded build failed verification (\(error.localizedDescription)) — nothing was changed, still on \(adaCLIVersion)")
        }

        let executable = executableURL
        let installedBundle = installDir.appendingPathComponent(bundleName)
        progress("Installing to \(installDir.path)…")
        if fm.isWritableFile(atPath: installDir.path) {
            try atomicSwap(newBinary: newBinary, newBundle: newBundle,
                           executable: executable, installedBundle: installedBundle)
        } else if allowSudo {
            progress("(\(installDir.path) is not writable — sudo may ask for your password)")
            try sudoSwap(newBinary: newBinary, newBundle: newBundle,
                         executable: executable, installedBundle: installedBundle)
        } else {
            throw UpgradeError(message: "\(installDir.path) is not writable and sudo is not available here — nothing was changed")
        }
    }

    /// Deterministic fault injection for the smoke tests — throws at a named
    /// point when BRIGLIA_UPGRADE_FAULT matches it. Inert in normal operation.
    private static func injectedFault(_ point: String) throws {
        if ProcessInfo.processInfo.environment["BRIGLIA_UPGRADE_FAULT"] == point {
            throw UpgradeError(message: "injected test fault: \(point)")
        }
    }

    /// Replace the installed binary + bundle with validated files using
    /// same-directory renames (atomic on one volume): move the old files
    /// aside, move the new ones in, and restore the originals if anything
    /// fails. Delete-then-copy was the old approach — a failure mid-way left
    /// no working install at all.
    private static func atomicSwap(
        newBinary: URL, newBundle: URL, executable: URL, installedBundle: URL
    ) throws {
        let fm = FileManager.default
        let dir = executable.deletingLastPathComponent()
        // Stage inside the install dir so every move below is a same-volume
        // rename, not a cross-device copy.
        let stagedBinary = dir.appendingPathComponent(".briglia-upgrade-staged-bin")
        let stagedBundle = dir.appendingPathComponent(".briglia-upgrade-staged-bundle")
        let oldBinary = dir.appendingPathComponent(".briglia-upgrade-old-bin")
        let oldBundle = dir.appendingPathComponent(".briglia-upgrade-old-bundle")
        for leftover in [stagedBinary, stagedBundle, oldBinary, oldBundle] {
            try? fm.removeItem(at: leftover)
        }
        try fm.copyItem(at: newBinary, to: stagedBinary)
        try fm.copyItem(at: newBundle, to: stagedBundle)
        defer {
            try? fm.removeItem(at: stagedBinary)
            try? fm.removeItem(at: stagedBundle)
        }

        // Track every mutation individually: rollback must first REMOVE any
        // newly placed component (an exists-check can't tell "old still
        // there" from "new moved in" — the bug Codex caught in the first
        // version, which left a new binary paired with the old bundle), then
        // restore both backups unconditionally.
        var movedBinaryAside = false
        var movedBundleAside = false
        var newBinaryPlaced = false
        var newBundlePlaced = false
        do {
            try fm.moveItem(at: executable, to: oldBinary)
            movedBinaryAside = true
            if fm.fileExists(atPath: installedBundle.path) {
                try fm.moveItem(at: installedBundle, to: oldBundle)
                movedBundleAside = true
            }
            try fm.moveItem(at: stagedBinary, to: executable)
            newBinaryPlaced = true
            try injectedFault("bundle-move")
            try fm.moveItem(at: stagedBundle, to: installedBundle)
            newBundlePlaced = true
            // Final verification while the backups still exist — a failure
            // here rolls back instead of stranding an install that can't
            // start.
            try runOrThrow(executable.path, ["bundle-check"], currentDirectory: "/")
        } catch {
            if newBinaryPlaced { try? fm.removeItem(at: executable) }
            if newBundlePlaced { try? fm.removeItem(at: installedBundle) }
            if movedBinaryAside { try? fm.moveItem(at: oldBinary, to: executable) }
            if movedBundleAside { try? fm.moveItem(at: oldBundle, to: installedBundle) }
            let restored = (!movedBinaryAside || !fm.fileExists(atPath: oldBinary.path))
                && fm.fileExists(atPath: executable.path)
                && (!movedBundleAside || fm.fileExists(atPath: installedBundle.path))
            throw UpgradeError(message: restored
                ? "install failed mid-swap (\(error.localizedDescription)) — previous version restored, still on \(adaCLIVersion)"
                : "install failed mid-swap (\(error.localizedDescription)) AND restoring the previous version failed — reinstall with the curl installer")
        }
        try? fm.removeItem(at: oldBinary)
        try? fm.removeItem(at: oldBundle)
    }

    /// The sudo mirror of atomicSwap for root-owned install dirs (interactive
    /// only): same stage → backup → place → verify → rollback contract, each
    /// step a sudo subprocess. The non-atomic copies (`install`, `cp -R`)
    /// target STAGING paths inside the install dir first — a partial copy
    /// leaves the installation untouched — and every mutation of the live
    /// paths is a same-volume `mv` (atomic rename). The old `cp -R` straight
    /// onto the live bundle path could die half-copied with its tracking flag
    /// still false, and the rollback's `mv` would then nest the backup INSIDE
    /// the partial directory instead of replacing it. A mid-sequence sudo
    /// credential expiry re-prompts — acceptable, since a human is present on
    /// this path by definition.
    private static func sudoSwap(
        newBinary: URL, newBundle: URL, executable: URL, installedBundle: URL
    ) throws {
        // interactive: sudo may prompt at any step (initial password, or a
        // mid-sequence credential expiry) and must own the terminal to do it.
        func sudo(_ args: [String]) throws {
            try runOrThrow("/usr/bin/sudo", args, interactive: true)
        }
        let fm = FileManager.default
        let dir = executable.deletingLastPathComponent()
        let stagedBinary = dir.appendingPathComponent(".briglia-upgrade-staged-bin")
        let stagedBundle = dir.appendingPathComponent(".briglia-upgrade-staged-bundle")
        let oldBinary = dir.appendingPathComponent(".briglia-upgrade-old-bin")
        let oldBundle = dir.appendingPathComponent(".briglia-upgrade-old-bundle")
        try sudo(["rm", "-rf", stagedBinary.path, stagedBundle.path,
                                         oldBinary.path, oldBundle.path])

        // Stage first: failures here leave the installation fully intact.
        do {
            try sudo(["install", "-m", "755", newBinary.path, stagedBinary.path])
            try sudo(["cp", "-R", newBundle.path, stagedBundle.path])
        } catch {
            try? sudo(["rm", "-rf", stagedBinary.path, stagedBundle.path])
            throw UpgradeError(message: "staging the new files failed (\(error.localizedDescription)) — nothing was changed, still on \(adaCLIVersion)")
        }

        var movedBinaryAside = false
        var movedBundleAside = false
        var newBinaryPlaced = false
        var newBundlePlaced = false
        do {
            try sudo(["mv", executable.path, oldBinary.path])
            movedBinaryAside = true
            if fm.fileExists(atPath: installedBundle.path) {
                try sudo(["mv", installedBundle.path, oldBundle.path])
                movedBundleAside = true
            }
            try sudo(["mv", stagedBinary.path, executable.path])
            newBinaryPlaced = true
            try sudo(["mv", stagedBundle.path, installedBundle.path])
            newBundlePlaced = true
            try runOrThrow(executable.path, ["bundle-check"], currentDirectory: "/")
        } catch {
            // Remove whatever new component was placed, then restore both
            // backups. The rm before each restore is defensive: mv into an
            // existing directory nests instead of replacing.
            if newBinaryPlaced { try? sudo(["rm", "-f", executable.path]) }
            if newBundlePlaced { try? sudo(["rm", "-rf", installedBundle.path]) }
            if movedBinaryAside { try? sudo(["mv", oldBinary.path, executable.path]) }
            if movedBundleAside {
                if fm.fileExists(atPath: installedBundle.path) {
                    try? sudo(["rm", "-rf", installedBundle.path])
                }
                try? sudo(["mv", oldBundle.path, installedBundle.path])
            }
            try? sudo(["rm", "-rf", stagedBinary.path, stagedBundle.path])
            let restored = fm.fileExists(atPath: executable.path)
                && !fm.fileExists(atPath: oldBinary.path)
                && (!movedBundleAside || fm.fileExists(atPath: installedBundle.path))
            throw UpgradeError(message: restored
                ? "install failed mid-swap (\(error.localizedDescription)) — previous version restored, still on \(adaCLIVersion)"
                : "install failed mid-swap (\(error.localizedDescription)) AND restoring the previous version failed — reinstall with the curl installer")
        }
        try? sudo(["rm", "-rf", oldBinary.path, oldBundle.path,
                                          stagedBinary.path, stagedBundle.path])
    }

    // MARK: - Self-restart (chat-path upgrades)

    private static var restartMarkerURL: URL {
        StoragePaths.dataRoot.appendingPathComponent("upgrade_restart.json")
    }

    /// Why the in-place exec happened — decides the "back online" wording.
    enum RestartKind: String, Codable {
        case upgrade    // /upgrade: a new version was just installed
        case restart    // /restart: same version, reload config at startup
    }

    private struct RestartMarker: Codable {
        let version: String
        let at: Date
        // Absent in markers written by pre-/restart versions → upgrade.
        let kind: RestartKind?
    }

    static func writeRestartMarker(version: String, kind: RestartKind = .upgrade) {
        let marker = RestartMarker(version: version, at: Date(), kind: kind)
        if let data = try? JSONEncoder().encode(marker) {
            try? PrivateStorage.writeAtomically(data, to: restartMarkerURL)
        }
    }

    /// Returns the marker when this process is a post-exec restart, deleting
    /// it. Stale markers (an exec that never happened, a manual restart days
    /// later) are discarded silently.
    static func consumeRestartMarker() -> (version: String, kind: RestartKind)? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: restartMarkerURL) else { return nil }
        try? fm.removeItem(at: restartMarkerURL)
        guard let marker = try? JSONDecoder().decode(RestartMarker.self, from: data),
              Date().timeIntervalSince(marker.at) < 15 * 60 else { return nil }
        return (marker.version, marker.kind ?? .upgrade)
    }

    /// Replace this process with the (just-swapped) installed binary, keeping
    /// PID, terminal, and stdio. Children are shut down first so nothing the
    /// old image spawned outlives its registries; the instance lock's fd is
    /// FD_CLOEXEC, so the lock releases exactly at exec and the new image
    /// reacquires it during normal startup.
    @MainActor
    static func restartNow() -> Never {
        TerminalSession.shutdownChildProcesses()
        fflush(stdout)
        fflush(stderr)
        let originalArguments = CommandLine.arguments
        var argv: [UnsafeMutablePointer<CChar>?] = originalArguments.map { strdup($0) }
        argv.append(nil)
        execv(executableURL.path, argv)
        // Only reached when exec itself failed — the swapped binary exists
        // (bundle-check passed), so this is exotic. Exit loudly; the marker
        // stays for the user's manual relaunch to announce.
        perror("execv")
        exit(1)
    }

    /// `interactive: true` lends the child the terminal's foreground slot
    /// (TerminalHandoff) so it can prompt — required for every sudo call:
    /// Foundation spawns children into a background process group, and a
    /// background sudo reading the tty for a password is SIGTTIN-stopped
    /// forever. Only the standalone `briglia upgrade` command reaches the sudo
    /// path, so no REPL thread is reading stdin concurrently. Non-prompting
    /// children (tar, bundle-check) stay on the plain spawn: the in-chat
    /// upgrade path runs those while the REPL reader owns stdin.
    private static func runOrThrow(
        _ launchPath: String, _ arguments: [String], currentDirectory: String? = nil,
        interactive: Bool = false
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        if interactive {
            try TerminalHandoff.runLendingForeground(process)
        } else {
            try process.run()
            process.waitUntilExit()
        }
        guard process.terminationStatus == 0 else {
            throw UpgradeError(message: "`\(launchPath) \(arguments.joined(separator: " "))` failed (exit \(process.terminationStatus))")
        }
    }
}
