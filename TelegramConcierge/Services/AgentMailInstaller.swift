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

// MARK: - Transactional, cancellable AgentMail CLI installer (plan §6.6)
//
// The published pair is `~/.local/bin/agentmail` (the key-broker wrapper) and
// the immutable versioned binary it points at
// (`agentmail-bin-<version>-<sha256[0:12]>`). The wrapper replacement is the
// SINGLE commit point; the transaction metadata (`agentmail.tx.json`) is
// three-state — staged → committing → committed (or rolled_back) — with
// `committing` persisted BEFORE the swap so recovery inspects the live
// wrapper instead of trusting the state. One exclusive, symlink-safe flock
// (`.agentmail.lock`) serializes every install and repair path; doctor
// never takes it and only reports.

extension AgentMailService {
    static let wrapperName = "agentmail"
    static let legacyBinaryName = "agentmail-bin"
    static let transactionFileName = "agentmail.tx.json"
    static let installerLockName = ".agentmail.lock"
    static let stagingPrefix = ".agentmail-staging-"

    // MARK: Pinned upstream release
    //
    // The upstream CLI is pinned to ONE version whose per-target archive
    // SHA-256 is compiled in (same idea as the lockfile-pinned Playwright):
    // the installer never asks GitHub for "latest", so an upstream layout or
    // toolchain change cannot break installs silently — v1.0.0 (2026-08-26)
    // renamed every asset and nested the binary, and every install 404'd
    // until 2026-09-04 — and the archive is authenticated against Briglia's
    // own record instead of a sidecar served from the same origin.
    // Bumping = new version + hashes here, then the selftest battery.
    static let pinnedVersion = "1.3.0"
    /// Target triple → SHA-256 of `agentmail-cli-<triple>.tar.gz` for
    /// `pinnedVersion`. Linux uses the musl builds: statically linked, no
    /// libssl.so.3 requirement (the gnu builds need OpenSSL 3 on the host).
    static let pinnedArchiveSHA256: [String: String] = [
        "aarch64-apple-darwin":       "01177d7b2d020da2d00d1eeede4fcfec427c0eefaf15997a7c3aad2f6361a365",
        "x86_64-apple-darwin":        "6c143440548c1b0f61ca8976f68c0a4ff945af5c4531c3b87470abae82ba435c",
        "aarch64-unknown-linux-musl": "2bf5310c9ca534da7674f744001bbd5d65145f24ce79fdb19d0bfe495237364b",
        "x86_64-unknown-linux-musl":  "993d8ef53b1e46b229d58cb04bc37526f3055ba3907679b9004379d36ee31165",
    ]
    static var currentTargetTriple: String {
        #if os(Linux)
        #if arch(arm64)
        return "aarch64-unknown-linux-musl"
        #else
        return "x86_64-unknown-linux-musl"
        #endif
        #else
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #else
        return "x86_64-apple-darwin"
        #endif
        #endif
    }
    /// The pinned archive for a target: asset name, download URL and the
    /// expected SHA-256. Nil for a target without a pinned build.
    static func pinnedAsset(triple: String = currentTargetTriple) -> (asset: String, url: URL, sha256: String)? {
        guard let sha = pinnedArchiveSHA256[triple] else { return nil }
        let asset = "agentmail-cli-\(triple).tar.gz"
        guard let url = URL(string: "https://github.com/agentmail-to/agentmail-cli/releases/download/v\(pinnedVersion)/\(asset)") else { return nil }
        return (asset, url, sha)
    }

    /// Selftest seam: the install directory (production: ~/.local/bin).
    nonisolated(unsafe) static var installDirectoryOverride: URL?
    static var installDirectory: URL {
        installDirectoryOverride
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// Selftest seam: replaces the release lookup + downloads. Returns the
    /// archive bytes, the checksum file bytes, the version and asset name.
    typealias DownloadFixture = (version: String, asset: String, archive: Data, checksums: Data)
    nonisolated(unsafe) static var downloadOverride: ((_ progress: (@Sendable (String) -> Void)?) async throws -> DownloadFixture)?
    /// Selftest seam: crash injection points, by name (`SIGKILL`s self).
    nonisolated(unsafe) static var crashPoint: String?
    /// Selftest seam: the exact path of the `briglia` binary the wrapper calls.
    nonisolated(unsafe) static var brigliaPathOverride: String?

    /// How the installer runs its children (tar, xattr, smoke tests). The
    /// default is the plain process runner (wizard, setup-api, UT app);
    /// quick setup passes the journaled `SetupJobRunner`.
    struct ChildRunner {
        var run: (_ command: [String], _ timeoutSeconds: Int, _ label: String) async -> (ok: Bool, stdout: String?, detail: String?)

        static let plain = ChildRunner { command, timeout, _ in
            let r = await ProcessRunner.runProcessAsync(
                executable: command[0], args: Array(command.dropFirst()), timeoutSeconds: timeout)
            return (r.failureDetail == nil, r.stdout, r.failureDetail)
        }

        static func journaled(_ runner: SetupJobRunner, row: String) -> ChildRunner {
            ChildRunner { command, timeout, label in
                let result = await runner.run(.init(row: row, command: command, mode: .detached,
                                                    timeout: TimeInterval(timeout), label: label))
                return (result.ok, result.lastLines.joined(separator: "\n"), result.failureReason)
            }
        }
    }

    struct PreviousWrapper: Codable, Equatable {
        var bytesB64: String
        var sha256: String
        var mode: Int
    }

    struct Transaction: Codable, Equatable {
        var version = 1
        var state: String   // staged | committing | committed | rolled_back
        var newBinary: String
        var newSHA256: String
        var newWrapperSHA256: String
        var previousWrapper: PreviousWrapper?
        var previousBinary: String?
        var startedAt: Date
    }

    struct InstallerBusy: Error {}

    // MARK: Paths and validation

    static var transactionURL: URL { installDirectory.appendingPathComponent(transactionFileName) }
    static var wrapperURL: URL { installDirectory.appendingPathComponent(wrapperName) }
    static var lockURL: URL { installDirectory.appendingPathComponent(installerLockName) }

    static let versionedNameRegex = try! NSRegularExpression(pattern: "^agentmail-bin(-[A-Za-z0-9._]+-[0-9a-f]{12})?$")

    /// A plain basename owned by the transaction: no `/`, not `.`/`..`,
    /// matches the versioned pattern. Existence checks are the caller's.
    static func validBasename(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return false }
        return versionedNameRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func versionedName(version: String, sha256: String) -> String {
        let safe = version.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        return "agentmail-bin-\(safe.isEmpty ? "unknown" : safe)-\(sha256.prefix(12))"
    }

    /// `exec '<path>' "$@"` target of a wrapper script; nil when the bytes
    /// are not a wrapper of ours.
    static func wrapperTarget(_ bytes: Data) -> String? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("exec '") else { continue }
            let rest = t.dropFirst("exec '".count)
            guard let end = rest.firstIndex(of: "'") else { return nil }
            return String(rest[..<end])
        }
        return nil
    }

    /// Is Briglia's key-brokered install complete: the `agentmail` wrapper
    /// (verified by content), executable, and its target exists as a
    /// regular file. A bare `agentmail` binary from npm/brew does NOT count
    /// (no broker ⇒ cannot authenticate).
    static func agentMailBrokerInstalled() -> Bool {
        let wrapper = wrapperURL
        guard isBrokerWrapper(at: wrapper), let data = try? Data(contentsOf: wrapper),
              let target = wrapperTarget(data) else { return false }
        var st = stat()
        guard lstat(target, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return FileManager.default.isExecutableFile(atPath: target)
    }

    /// The upstream version baked into the installed key-brokered binary's
    /// name (`agentmail-bin-<version>-<sha12>`). "legacy" for the
    /// unversioned pre-transaction name (a 0.7.x install); nil when the
    /// broker isn't installed.
    static func installedCLIVersion() -> String? {
        guard agentMailBrokerInstalled(), let data = try? Data(contentsOf: wrapperURL),
              let target = wrapperTarget(data) else { return nil }
        return cliVersion(fromTargetBasename: URL(fileURLWithPath: target).lastPathComponent)
    }

    static func cliVersion(fromTargetBasename base: String) -> String? {
        if base == legacyBinaryName { return "legacy" }
        guard base.hasPrefix(legacyBinaryName + "-") else { return nil }
        let rest = base.dropFirst(legacyBinaryName.count + 1)          // "<version>-<sha12>"
        guard let dash = rest.lastIndex(of: "-"), dash > rest.startIndex else { return nil }
        return String(rest[..<dash])
    }

    /// Command syntax of the CLI the model will find on PATH. The Go CLI
    /// (0.x) used colon resources (`inboxes:messages list`); the Rust
    /// rewrite (1.x, pinned) uses nested subcommands (`inboxes messages
    /// list`) with the same flags. Prompt text follows the INSTALLED
    /// binary so a device still on 0.7.x is taught commands that work.
    enum CLISyntax: Equatable { case v0Colon, v1Nested }

    static func cliSyntax(forInstalledVersion version: String?) -> CLISyntax {
        guard let version else { return .v1Nested }          // not installed: a fresh install gets the pinned 1.x
        if version == "legacy" { return .v0Colon }
        let major = Int(version.split(separator: ".").first ?? "") ?? 1
        return major == 0 ? .v0Colon : .v1Nested
    }

    /// Selftest seam.
    nonisolated(unsafe) static var cliSyntaxOverrideForTesting: CLISyntax?
    static var cliSyntax: CLISyntax { cliSyntaxOverrideForTesting ?? cliSyntax(forInstalledVersion: installedCLIVersion()) }
    /// `inboxes:messages` or `inboxes messages`, for prompt examples.
    static var messagesResource: String { cliSyntax == .v0Colon ? "inboxes:messages" : "inboxes messages" }

    private static func brigliaPath() -> String {
        brigliaPathOverride ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }

    // MARK: Lock

    /// Exclusive, symlink-safe installer lock. `nil` = busy.
    private static func openInstallerLock() throws -> Int32? {
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: "briglia.agentmail", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "cannot open \(lockURL.path): \(String(cString: strerror(errno))) (a symlink or non-regular file at that path is refused)"])
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw NSError(domain: "briglia.agentmail", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "\(lockURL.path) is not a regular file — refusing"])
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    /// Read-only probe for doctor: is an installer or repair running now?
    static func installerLockBusy() -> Bool {
        let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    static func withInstallerLock<T>(_ body: () async throws -> T) async throws -> T {
        guard let fd = try openInstallerLock() else { throw InstallerBusy() }
        defer { close(fd) }   // releases the flock
        return try await body()
    }

    // MARK: Durable helpers

    private static func fsyncDir() throws { try PrivateStorage.fsyncDirectory(installDirectory.path) }

    private static func writeTransaction(_ tx: Transaction) throws {
        let data = try JSONEncoder.iso.encode(tx)
        try PrivateStorage.writeAtomically(data, to: transactionURL, mode: 0o600)
    }

    private static func readTransaction() throws -> Transaction? {
        var st = stat()
        guard lstat(transactionURL.path, &st) == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: "briglia.agentmail", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(transactionFileName) is not a regular file"])
        }
        let data = try Data(contentsOf: transactionURL)
        return try JSONDecoder.iso.decode(Transaction.self, from: data)
    }

    /// Validate every filename and hash in the metadata (plan §6.6 step 3):
    /// basenames only, versioned pattern, named files are regular when
    /// present. Returns the reason when invalid.
    static func validate(_ tx: Transaction) -> String? {
        guard ["staged", "committing", "committed", "rolled_back"].contains(tx.state) else { return "unknown state '\(tx.state)'" }
        guard validBasename(tx.newBinary) else { return "new_binary is not a plain versioned basename" }
        if let prev = tx.previousBinary, !validBasename(prev) { return "previous_binary is not a plain versioned basename" }
        guard tx.newSHA256.count == 64, tx.newWrapperSHA256.count == 64 else { return "hash fields malformed" }
        if let prev = tx.previousWrapper {
            guard prev.sha256.count == 64, let bytes = Data(base64Encoded: prev.bytesB64),
                  sha256Hex(bytes) == prev.sha256 else { return "previous_wrapper bytes do not match their hash" }
        }
        for name in [tx.newBinary, tx.previousBinary].compactMap({ $0 }) {
            let path = installDirectory.appendingPathComponent(name).path
            var st = stat()
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG { return "\(name) exists but is not a regular file (symlink?)" }
        }
        return nil
    }

    private static func atomicReplaceWrapper(bytes: Data, mode: mode_t) throws {
        try PrivateStorage.writeAtomically(bytes, to: wrapperURL, mode: mode)
    }

    /// The live `agentmail` path is absent, a readable regular file, or
    /// something else (symlink, directory, unreadable) — and the last is
    /// never treated as "absent": recovery fails closed on it and a new
    /// installation refuses to overwrite it.
    enum WrapperState: Equatable {
        case absent
        case valid(Data)
        case invalid(String)
    }

    static func liveWrapperState() -> WrapperState {
        var st = stat()
        guard lstat(wrapperURL.path, &st) == 0 else {
            return errno == ENOENT ? .absent : .invalid("lstat failed: \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .invalid("\(wrapperURL.path) exists but is not a regular file (symlink, directory or device)")
        }
        guard let data = try? Data(contentsOf: wrapperURL) else { return .invalid("\(wrapperURL.path) exists but cannot be read") }
        return .valid(data)
    }

    private static func liveWrapperBytes() -> Data? {
        if case .valid(let d) = liveWrapperState() { return d }
        return nil
    }

    struct CleanupFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Selftest seams: cleanup/barrier fault injection.
    nonisolated(unsafe) static var injectFsyncFailure = false
    nonisolated(unsafe) static var injectStagingRemovalFailure = false

    /// Post-verification cleanup, every step checked: an unlinked
    /// transaction file, removed staging and a directory barrier are part
    /// of "installed"; a failure here is reported as retryable, never as
    /// success with debris behind.
    private static func finishCleanup(deletePrevious previous: String?, liveTarget: String?) throws {
        // Order: everything that could fail runs BEFORE the transaction file
        // goes, so a failed step leaves the evidence doctor reports and
        // repair retries from; the metadata is the last thing removed.
        if let prev = previous {
            try deleteIfUnreferenced(prev, liveTarget: liveTarget)
        }
        try removeStagingChecked()
        func barrier() throws {
            if injectFsyncFailure { throw CleanupFailure(description: "injected directory fsync failure") }
            do { try fsyncDir() } catch { throw CleanupFailure(description: "directory barrier failed: \(error)") }
        }
        try barrier()
        if unlink(transactionURL.path) != 0, errno != ENOENT {
            throw CleanupFailure(description: "could not remove \(transactionFileName): \(String(cString: strerror(errno)))")
        }
        try barrier()
    }

    private static func removeStagingChecked() throws {
        let fm = FileManager.default
        for entry in try stagingEntries() {
            if injectStagingRemovalFailure { throw CleanupFailure(description: "injected staging removal failure (\(entry))") }
            do { try fm.removeItem(at: installDirectory.appendingPathComponent(entry)) } catch {
                throw CleanupFailure(description: "could not remove staging \(entry): \(error.localizedDescription)")
            }
        }
    }

    private static func crashIf(_ point: String) {
        // A process-directed SIGKILL may be delivered to another thread
        // first; never let this thread run past the crash point (it once
        // reached the wrapper swap and left a temp file the "crash" could
        // not have produced). A real crash executes nothing further either.
        if crashPoint == point { kill(getpid(), SIGKILL); while true { sleep(10) } }
    }

    /// Selftest seam: make unlink of this basename fail (EACCES-like).
    nonisolated(unsafe) static var injectUnlinkFailure: String?

    /// Checked unlink: ENOENT is fine, anything else is a failure that must
    /// preserve the transaction evidence.
    private static func unlinkChecked(_ path: String) throws {
        if let inject = injectUnlinkFailure, URL(fileURLWithPath: path).lastPathComponent == inject {
            throw CleanupFailure(description: "injected unlink failure for \(inject)")
        }
        if unlink(path) != 0, errno != ENOENT {
            throw CleanupFailure(description: "could not remove \(URL(fileURLWithPath: path).lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    private static func deleteIfUnreferenced(_ name: String, liveTarget: String?) throws {
        let path = installDirectory.appendingPathComponent(name).path
        if let liveTarget, liveTarget == path { return }
        try unlinkChecked(path)
    }

    /// Staging entries; an enumeration failure is an error, never "none".
    private static func stagingEntries() throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: installDirectory.path).filter { $0.hasPrefix(stagingPrefix) }
        } catch {
            throw CleanupFailure(description: "could not list \(installDirectory.path): \(error.localizedDescription)")
        }
    }

    // MARK: Install

    /// Returns nil on success or a human-readable failure. `checkpoint`
    /// throws to abort (quick setup's authorization generation); a
    /// `CancellationError` is treated the same way.
    static func installAgentMailBinary(
        progress: (@Sendable (String) -> Void)? = nil,
        checkpoint: () throws -> Void = {},
        runner: ChildRunner = .plain
    ) async -> String? {
        do {
            return try await withInstallerLock {
                try await installLocked(progress: progress, checkpoint: checkpoint, runner: runner)
            }
        } catch is InstallerBusy {
            return "another AgentMail installation or repair is in progress — retry in a moment"
        } catch {
            return "install failed: \(error.localizedDescription)"
        }
    }

    private static func installLocked(
        progress: (@Sendable (String) -> Void)?,
        checkpoint: () throws -> Void,
        runner: ChildRunner
    ) async throws -> String? {
        try sweepStaleWrapperTemps()
        // Settle any interrupted transaction first (repair is idempotent).
        if try readTransaction() != nil {
            let outcome = await repairLocked(runner: runner)
            if case .failedClosed(let why) = outcome { return why }
            if try readTransaction() != nil { return "an interrupted AgentMail transaction could not be settled — run `briglia agentmail repair`" }
        }
        try checkpoint()

        // 1. Download.
        let fixture: DownloadFixture
        if let downloadOverride {
            fixture = try await downloadOverride(progress)
        } else {
            fixture = try await downloadRelease(progress: progress)
        }
        try Task.checkCancellation()
        try checkpoint()
        guard let checksums = String(data: fixture.checksums, encoding: .utf8),
              let line = checksums.split(separator: "\n").first(where: { $0.contains(fixture.asset) }),
              let expected = line.split(separator: " ").first.map(String.init)?.lowercased(),
              expected.count == 64 else {
            return "checksum for \(fixture.asset) not found in checksums file"
        }
        guard sha256Hex(fixture.archive) == expected else {
            return "checksum mismatch — download corrupted or release changed mid-flight, retry"
        }

        // 2. Stage under the install directory (same filesystem).
        let fm = FileManager.default
        try fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let staging = installDirectory.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var stagingKept = false
        defer { if !stagingKept { try? fm.removeItem(at: staging) } }
        let archivePath = staging.appendingPathComponent(fixture.asset)
        try fixture.archive.write(to: archivePath)
        progress?("Extracting the agentmail CLI…")
        // Upstream archives (cargo-dist) nest everything under one
        // `agentmail-cli-<triple>/` directory; strip it so the binary lands
        // at `staging/agentmail`. A flat archive yields nothing here and
        // fails the "did not contain" check below.
        let untar = await runner.run(["/usr/bin/tar", "-xf", archivePath.path, "-C", staging.path, "--strip-components=1"], 60, "extract agentmail")
        guard untar.ok else { return "extraction failed: \(untar.detail ?? "tar failed")" }
        try checkpoint()
        let stagedBinary = staging.appendingPathComponent("agentmail")
        var st = stat()
        guard lstat(stagedBinary.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return "archive did not contain the agentmail binary"
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedBinary.path)
        #if os(macOS)
        // Unquarantine with the syscall the `xattr -d` tool wraps: no child
        // to journal or reap, and a missing attribute (ENOATTR) is success.
        if removexattr(stagedBinary.path, "com.apple.quarantine", 0) != 0, errno != ENOATTR {
            return "could not remove the quarantine attribute: \(String(cString: strerror(errno)))"
        }
        try checkpoint()
        #endif
        let binaryData = try Data(contentsOf: stagedBinary)
        let binarySHA = sha256Hex(binaryData)
        let versioned = versionedName(version: fixture.version, sha256: binarySHA)
        let versionedPath = installDirectory.appendingPathComponent(versioned).path
        let wrapperText = wrapperScript(adaPath: brigliaPath(), realBinaryPath: versionedPath)
        let wrapperBytes = Data(wrapperText.utf8)
        let stagedWrapper = staging.appendingPathComponent("agentmail-wrapper")
        // The staged wrapper points at the versioned path; for the staged
        // smoke test the binary itself is run directly.
        try wrapperBytes.write(to: stagedWrapper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedWrapper.path)
        progress?("Checking the downloaded binary…")
        let stagedSmoke = await runner.run([stagedBinary.path, "--version"], 10, "agentmail --version (staged)")
        guard stagedSmoke.ok else { return "downloaded binary failed to run: \(stagedSmoke.detail ?? "unknown error")" }
        try checkpoint()

        // Existing versioned file?
        var binaryAlreadyPublished = false
        if lstat(versionedPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG, let existing = try? Data(contentsOf: URL(fileURLWithPath: versionedPath)),
                  sha256Hex(existing) == binarySHA else {
                return "a file named \(versioned) exists with unexpected content; remove it by hand if it is not yours"
            }
            binaryAlreadyPublished = true
        }

        // 3. Transaction metadata, then publish the binary.
        try checkpoint()
        let liveWrapper: Data?
        switch liveWrapperState() {
        case .absent: liveWrapper = nil
        case .valid(let d): liveWrapper = d
        case .invalid(let why): return "refusing to replace the existing agentmail entry: \(why) — remove it by hand if it is not yours"
        }
        let liveTarget = liveWrapper.flatMap(wrapperTarget)
        var previousBinary: String?
        if let liveTarget {
            let base = URL(fileURLWithPath: liveTarget).lastPathComponent
            if URL(fileURLWithPath: liveTarget).deletingLastPathComponent().path == installDirectory.path, validBasename(base) {
                previousBinary = base
            }
        } else if lstat(installDirectory.appendingPathComponent(legacyBinaryName).path, &st) == 0 {
            previousBinary = legacyBinaryName
        }
        var previous: PreviousWrapper?
        if let liveWrapper {
            var wst = stat()
            lstat(wrapperURL.path, &wst)
            previous = PreviousWrapper(bytesB64: liveWrapper.base64EncodedString(), sha256: sha256Hex(liveWrapper),
                                       mode: Int(wst.st_mode & 0o777))
        }
        var tx = Transaction(state: "staged", newBinary: versioned, newSHA256: binarySHA,
                             newWrapperSHA256: sha256Hex(wrapperBytes), previousWrapper: previous,
                             previousBinary: previousBinary, startedAt: Date())
        try writeTransaction(tx)
        crashIf("after-metadata")
        try checkpoint()
        if !binaryAlreadyPublished {
            guard rename(stagedBinary.path, versionedPath) == 0 else {
                let why = String(cString: strerror(errno))
                unlink(transactionURL.path)
                return "could not publish the binary: \(why)"
            }
            try fsyncDir()
        }
        crashIf("after-binary")
        stagingKept = false

        // 4. Commit (three states).
        try checkpoint()
        tx.state = "committing"
        try writeTransaction(tx)
        crashIf("after-committing")
        try atomicReplaceWrapper(bytes: wrapperBytes, mode: 0o755)
        crashIf("after-swap")
        tx.state = "committed"
        try writeTransaction(tx)
        crashIf("after-committed")

        // 5. Verify through the published wrapper, else roll back.
        progress?("Verifying the installation…")
        return await verifyOrRollback(tx, runner: runner)
    }

    /// Step 5 and the `committed` repair branch.
    private static func verifyOrRollback(_ tx: Transaction, runner: ChildRunner) async -> String? {
        let smoke = await runner.run([wrapperURL.path, "--version"], 10, "agentmail --version")
        if smoke.ok {
            let liveTarget = liveWrapperBytes().flatMap(wrapperTarget)
            let previous = (tx.previousBinary != nil && tx.previousBinary != tx.newBinary) ? tx.previousBinary : nil
            do {
                try finishCleanup(deletePrevious: previous, liveTarget: liveTarget)
            } catch {
                // The new pair is live and verified, but the transaction is
                // not settled: retryable, and doctor keeps reporting it.
                return "installed and verified, but cleanup did not complete (\(error)) — retry, or run `briglia agentmail repair`"
            }
            return nil
        }
        let detail = smoke.detail ?? "unknown error"
        do {
            try rollbackLocked(tx)
        } catch {
            return "installed binary failed to run (\(detail)) and the rollback failed too: \(error.localizedDescription) — run `briglia agentmail repair`"
        }
        return "installed binary failed to run: \(detail) — the previous installation was restored"
    }

    /// One atomic wrapper operation, guarded by the wrapper inspection: the
    /// swap happens only if the live wrapper still hashes to the new one.
    private static func rollbackLocked(_ txIn: Transaction) throws {
        var tx = txIn
        let live: Data?
        switch liveWrapperState() {
        case .absent: live = nil
        case .valid(let d): live = d
        case .invalid(let why): throw CleanupFailure(description: "the live wrapper is invalid (\(why)); nothing rolled back — inspect it by hand")
        }
        let liveHash = live.map(sha256Hex)
        if liveHash == tx.newWrapperSHA256 {
            // The metadata sits at `committing` through the rollback swap, so
            // a crash right after it is classified by wrapper inspection.
            if tx.state != "committing" {
                tx.state = "committing"
                try writeTransaction(tx)
            }
            if let prev = tx.previousWrapper, let bytes = Data(base64Encoded: prev.bytesB64) {
                try atomicReplaceWrapper(bytes: bytes, mode: mode_t(prev.mode))
            } else {
                // A failed unlink leaves the failed wrapper live: the metadata
                // stays at `committing` so doctor reports it and repair
                // re-inspects; nothing claims "restored".
                try unlinkChecked(wrapperURL.path)
                try fsyncDir()
            }
            crashIf("after-rollback-swap")
        }
        tx.state = "rolled_back"
        try writeTransaction(tx)
        let liveTarget = liveWrapperBytes().flatMap(wrapperTarget)
        try finishCleanup(deletePrevious: tx.newBinary, liveTarget: liveTarget)
    }

    // MARK: Repair

    enum RepairOutcome: Equatable {
        case nothingToDo
        case settled(String)
        case failedClosed(String)
        case busy
    }

    /// `briglia agentmail repair` and quick setup's preflight: takes the
    /// lock, validates the metadata, then settles the transaction by
    /// inspecting the LIVE wrapper (never the state alone). Idempotent.
    static func repairTransaction(runner: ChildRunner = .plain) async -> RepairOutcome {
        do {
            return try await withInstallerLock { await repairLocked(runner: runner) }
        } catch is InstallerBusy {
            return .busy
        } catch {
            return .failedClosed("repair could not start: \(error.localizedDescription)")
        }
    }

    /// The atomic wrapper writer stages `.agentmail.tmp-<uuid>` next to the
    /// wrapper; a crash between its creation and the rename leaves it
    /// behind. Under the installer lock no writer is mid-write, so every
    /// such file is stale. Checked removal.
    static func sweepStaleWrapperTemps() throws {
        let prefix = ".\(wrapperName).tmp-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: installDirectory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            let path = installDirectory.appendingPathComponent(name).path
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            try unlinkChecked(path)
        }
    }

    private static func repairLocked(runner: ChildRunner) async -> RepairOutcome {
        do { try sweepStaleWrapperTemps() } catch { return .failedClosed("a stale wrapper temp file could not be removed: \(error)") }
        let tx: Transaction
        do {
            guard let read = try readTransaction() else {
                do { try removeStagingChecked() } catch { return .failedClosed("leftover staging could not be removed: \(error)") }
                return .nothingToDo
            }
            tx = read
        } catch {
            return .failedClosed("\(transactionFileName) cannot be read (\(error.localizedDescription)); inspect \(installDirectory.path), then delete the file to abandon the transaction")
        }
        if let why = validate(tx) {
            return .failedClosed("\(transactionFileName) is invalid (\(why)); nothing was changed — inspect \(installDirectory.path)/agentmail and \(transactionFileName), then delete the metadata to abandon the transaction")
        }
        let wrapperState = liveWrapperState()
        if case .invalid(let why) = wrapperState {
            return .failedClosed("the AgentMail wrapper path is invalid (\(why)); nothing was changed — inspect \(wrapperURL.path) and \(transactionURL.path), then delete \(transactionFileName) to abandon the transaction or restore the wrapper by hand")
        }
        let live: Data? = { if case .valid(let d) = wrapperState { return d }; return nil }()
        let liveHash = live.map(sha256Hex)
        let liveTarget = live.flatMap(wrapperTarget)
        let newBinaryPath = installDirectory.appendingPathComponent(tx.newBinary).path

        func cleanPreCommit() -> RepairOutcome {
            do {
                try finishCleanup(deletePrevious: tx.newBinary, liveTarget: liveTarget)
            } catch {
                return .failedClosed("cleanup did not complete: \(error) — retry `briglia agentmail repair`")
            }
            return .settled("the wrapper was never replaced; the previous installation is live and the new binary was removed")
        }
        func classifyCommitting() -> String {
            // previous wrapper live (or ABSENT — never invalid — on a fresh install) → pre-commit
            if let prev = tx.previousWrapper {
                if liveHash == prev.sha256 { return "pre" }
            } else if wrapperState == .absent {
                return "pre"
            }
            if liveHash == tx.newWrapperSHA256, liveTarget == newBinaryPath { return "post" }
            return "neither"
        }

        switch tx.state {
        case "staged":
            return cleanPreCommit()
        case "rolled_back":
            return cleanPreCommit()
        case "committing", "committed":
            // `committed` is inspected too: a rollback that crashed after
            // its swap leaves the previous wrapper live under either state.
            let cls = classifyCommitting()
            switch cls {
            case "pre":
                return cleanPreCommit()
            case "post":
                if tx.state == "committing" {
                    var updated = tx
                    updated.state = "committed"
                    do { try writeTransaction(updated) } catch { return .failedClosed("could not update the metadata: \(error.localizedDescription)") }
                }
                var verified = tx
                verified.state = "committed"
                let result = await verifyOrRollback(verified, runner: runner)
                if let result { return .settled("the new pair was live but failed verification: \(result)") }
                return .settled("the new pair was live; verification passed and the transaction was completed")
            default:
                return .failedClosed("the AgentMail wrapper does not match this transaction's previous or new wrapper; inspect \(wrapperURL.path) and \(transactionURL.path), then delete \(transactionFileName) to abandon the transaction or restore the wrapper by hand")
            }
        default:
            return .failedClosed("unknown transaction state '\(tx.state)'")
        }
    }

    /// Doctor's read-only view: nil when there is nothing to report.
    static func transactionReport() -> String? {
        // Hold the installer lock (non-blocking) through the inspection so a
        // live installer's half-written metadata is never read as a state
        // (Codex, round 1). Doctor still never mutates.
        // The lock file is created if absent (0600, empty — the only file
        // doctor ever creates) so a first installer racing with doctor is
        // serialized too; a symlink or unopenable lock path is reported.
        let fd: Int32
        do {
            guard let opened = try openInstallerLock() else {
                return "AgentMail installation in progress (another process holds the installer lock)"
            }
            fd = opened
        } catch {
            return "AgentMail installer lock cannot be taken (\(error.localizedDescription)); inspect \(lockURL.path)"
        }
        defer { close(fd) }
        var st = stat()
        guard lstat(transactionURL.path, &st) == 0 else {
            guard let staging = try? stagingEntries() else { return "AgentMail install directory cannot be listed (\(installDirectory.path))" }
            return staging.isEmpty ? nil : "AgentMail staging debris left behind (\(staging.joined(separator: ", "))); run `briglia agentmail repair`"
        }
        do {
            guard let tx = try readTransaction() else { return nil }
            if let why = validate(tx) {
                return "AgentMail install transaction metadata is invalid (\(why)); run `briglia agentmail repair` for instructions"
            }
            return "AgentMail install transaction interrupted at state \(tx.state); run `briglia agentmail repair`"
        } catch {
            return "AgentMail install transaction metadata cannot be read (\(error.localizedDescription)); run `briglia agentmail repair`"
        }
    }

    // MARK: Download

    private static func downloadRelease(progress: (@Sendable (String) -> Void)?) async throws -> DownloadFixture {
        guard let pin = pinnedAsset() else {
            throw NSError(domain: "briglia.agentmail", code: 10, userInfo: [NSLocalizedDescriptionKey:
                "no pinned AgentMail CLI build for this platform (\(currentTargetTriple))"])
        }
        let archive: Data
        do {
            archive = try await ProcessRunner.downloadReportingProgress(
                from: pin.url, label: "Downloading the agentmail CLI \(pinnedVersion)", progress: progress)
        } catch {
            throw NSError(domain: "briglia.agentmail", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "download of \(pin.asset) failed (\(error.localizedDescription)) — \(pin.url.absoluteString)"])
        }
        // The verification step reads a checksums text; synthesize it from
        // the compiled-in record so the rest of the pipeline is unchanged.
        return (pinnedVersion, pin.asset, archive, Data("\(pin.sha256)  \(pin.asset)\n".utf8))
    }
}
