import Foundation
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

/// Multiple assistants on one computer (MULTI_ASSISTANT_PLAN v5 §3): every
/// assistant is a PROFILE — its own storage roots, preferences suite, landing
/// zone and spill directory. The existing install is the profile `default`
/// and keeps every path, string and request byte it had; extras live in
/// sibling directories (`briglia-profiles/<name>`).
///
/// The selection is made ONCE, by `ProfileBootstrap`, before ArgumentParser
/// and before any storage/preferences/migration/logging static is touched
/// (all of them are lazy). Stage 1 ships hidden: a non-default profile is
/// accepted only while `BRIGLIA_EXPERIMENTAL_PROFILES=1` (plan D1).
enum AssistantProfile {
    static let defaultName = "default"
    /// Names that can never be an extra (plan §3.1).
    static let reservedNames: Set<String> = ["default", "all", "shared", "profiles"]
    /// The environment variable children inherit (§3.2).
    static let environmentKey = "BRIGLIA_PROFILE"
    /// Stage-1 switch: without it every extra is refused (D1, hidden).
    static let experimentalKey = "BRIGLIA_EXPERIMENTAL_PROFILES"
    /// At most 8 assistants including default (D7).
    static let maxProfiles = 8
    /// Directory names under the XDG bases.
    static let extrasDirName = "briglia-profiles"
    static let sharedDirName = "briglia-shared"
    static let metadataFileName = "profile.json"

    /// The selected profile. Written only by `ProfileBootstrap.apply` (and by
    /// in-process unit tests through `withSelectionForTesting`).
    nonisolated(unsafe) private(set) static var selectedName: String = defaultName

    static var isDefault: Bool { selectedName == defaultName }
    static var isExtra: Bool { !isDefault }

    static var experimentalEnabled: Bool {
        ProcessInfo.processInfo.environment[experimentalKey] == "1"
    }

    /// `[a-z0-9][a-z0-9-]{0,23}` (plan §3.1).
    static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 24 else { return false }
        func lowerAlnum(_ b: UInt8) -> Bool { (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) }
        guard lowerAlnum(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { lowerAlnum($0) || $0 == 0x2d }
    }

    static func isUsableExtraName(_ name: String) -> Bool {
        isValidName(name) && !reservedNames.contains(name)
    }

    // MARK: - Roots (pure; never create anything)

    static func xdgBase(_ key: String, fallback: String,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let value = environment[key], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return home.appendingPathComponent(fallback, isDirectory: true)
    }

    static func dataBase(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        xdgBase("XDG_DATA_HOME", fallback: ".local/share", environment: environment)
    }

    static func configBase(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        xdgBase("XDG_CONFIG_HOME", fallback: ".config", environment: environment)
    }

    static func extraDataRoot(_ name: String,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        dataBase(environment).appendingPathComponent(extrasDirName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func extraConfigRoot(_ name: String,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configBase(environment).appendingPathComponent(extrasDirName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func metadataURL(_ name: String,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        extraConfigRoot(name, environment: environment).appendingPathComponent(metadataFileName)
    }

    /// First 8 hex of SHA-256 of the extra's absolute data-root path: two XDG
    /// installations of one OS user never share a preferences suite or a
    /// spill directory (plan §3.6, §3.7).
    static func installationHash(_ name: String,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let path = extraDataRoot(name, environment: environment).standardizedFileURL.path
        return String(SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    // MARK: - Selected-profile values

    /// The selected data root (`StoragePaths.dataRoot` reads this once).
    static func selectedDataRoot() -> URL {
        isDefault ? StoragePaths.resolveDataRoot() : extraDataRoot(selectedName)
    }

    static func selectedConfigRoot() -> URL {
        isDefault ? StoragePaths.resolveConfigRoot() : extraConfigRoot(selectedName)
    }

    /// Display forms used in prompts, tool descriptions and messages. For
    /// default these are today's literals byte for byte (§3.4).
    static var dataRootDisplay: String {
        isDefault ? "~/.local/share/briglia" : "~/.local/share/\(extrasDirName)/\(selectedName)"
    }

    static var configRootDisplay: String {
        isDefault ? "~/.config/briglia" : "~/.config/\(extrasDirName)/\(selectedName)"
    }

    /// The command prefix an outside caller must use to reach THIS assistant
    /// (`briglia trigger …` from cron/launchd has no BRIGLIA_PROFILE, §3.3).
    static var commandPrefix: String {
        isDefault ? "briglia" : "briglia --profile \(selectedName)"
    }

    /// The argv words that select this profile in a child or a generated
    /// wrapper script (empty for default, so default's wrappers keep their
    /// bytes).
    static var selectionArguments: [String] {
        isDefault ? [] : ["--profile", selectedName]
    }

    // MARK: - Metadata (`profile.json`, §3.5)

    struct Metadata: Codable, Equatable {
        var version: Int
        var name: String
        var displayName: String
        var createdAt: Date
        var homeFolder: String
        var template: String?
    }

    static func readMetadata(_ name: String,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> Metadata? {
        let url = metadataURL(name, environment: environment)
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 64 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let meta = try? decoder.decode(Metadata.self, from: data),
              meta.version == 1, meta.name == name else { return nil }
        return meta
    }

    static func encodeMetadata(_ meta: Metadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(meta)
    }

    /// The selected extra's metadata, read once.
    static let selectedMetadata: Metadata? = isExtra ? readMetadata(selectedName) : nil

    /// Every extra with a readable `profile.json` (sorted). Raw directory
    /// resolution; never through the selected-root statics.
    static func listExtras(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let dir = configBase(environment).appendingPathComponent(extrasDirName, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { isUsableExtraName($0) && readMetadata($0, environment: environment) != nil }.sorted()
    }

    // MARK: - Bootstrap state

    /// Set the selection. Only `ProfileBootstrap.apply` calls this in a real
    /// process; it must run before any root static is evaluated.
    static func select(_ name: String) {
        selectedName = name
    }
}

extension UpdateNoticeService {
    /// Only the default assistant checks and sends the computer-wide notices
    /// (update available, local-tools advisories, macOS updates; plan §5.5).
    nonisolated static var sendsMachineNotices: Bool { AssistantProfile.isDefault }
}

/// Machine-level locations (plan §3.1): state that exists before any extra
/// lives in DEFAULT's data root, addressed by absolute path from every
/// profile; coordination between assistants lives in `briglia-shared/`.
enum MachinePaths {
    /// Default's data root. In the default profile this IS the process's
    /// own (once-resolved) root, so nothing changes for it; an extra resolves
    /// default's root from the same XDG rules.
    static func defaultDataRoot() -> URL {
        AssistantProfile.isDefault ? StoragePaths.dataRoot : StoragePaths.resolveDataRoot()
    }

    static func defaultConfigRoot() -> URL {
        AssistantProfile.isDefault ? StoragePaths.configRoot : StoragePaths.resolveConfigRoot()
    }

    /// `<default data root>/machine/` — the one new directory a never-multi
    /// install gains (created only when something there is first used).
    static func machineDir() -> URL {
        defaultDataRoot().appendingPathComponent("machine", isDirectory: true)
    }

    static var signInLock: URL { machineDir().appendingPathComponent("signin.lock") }
    static var identityTxLock: URL { machineDir().appendingPathComponent("identity-tx.lock") }

    static func sharedRoot(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        AssistantProfile.dataBase(environment).appendingPathComponent(AssistantProfile.sharedDirName, isDirectory: true)
    }

    /// Create `machine/` (0700) inside default's data root. Default's data
    /// root itself is created 0700 like every root.
    static func ensureMachineDir() throws {
        try PrivateStorage.ensureDirectory(defaultDataRoot(), mode: 0o700)
        try PrivateStorage.ensureDirectory(machineDir(), mode: 0o700)
    }
}

/// A held, non-blocking or bounded-wait `flock` on a file (FD_CLOEXEC, never
/// unlinked while held). Released on `release()` or deinit.
final class ProfileFileLock {
    private(set) var fd: Int32
    let path: String

    private init(fd: Int32, path: String) { self.fd = fd; self.path = path }
    deinit { release() }

    func release() {
        if fd >= 0 { flock(fd, LOCK_UN); close(fd); fd = -1 }
    }

    enum Outcome { case acquired(ProfileFileLock), busy, failed(String) }

    /// Try to take the lock; when `waitSeconds` > 0 retry every 50 ms until
    /// the deadline.
    static func take(_ url: URL, waitSeconds: Double = 0) -> Outcome {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failed("cannot open \(url.path): \(String(cString: strerror(errno)))") }
        let deadline = Date().addingTimeInterval(waitSeconds)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return .acquired(ProfileFileLock(fd: fd, path: url.path)) }
            let err = errno
            guard err == EWOULDBLOCK || err == EINTR else {
                close(fd)
                return .failed("cannot lock \(url.path): \(String(cString: strerror(err)))")
            }
            if Date() >= deadline { close(fd); return .busy }
            usleep(50_000)
        }
    }

    enum Probe: Equatable { case dead, live, unknown }

    /// Probe someone else's lease: acquired → dead (released at once);
    /// EWOULDBLOCK → live; anything else → unknown (fail closed). A missing
    /// file is dead.
    static func probe(_ url: URL) -> Probe {
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        if fd < 0 { return errno == ENOENT ? .dead : .unknown }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return .dead }
        return errno == EWOULDBLOCK ? .live : .unknown
    }
}
