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

/// Machine upgrade coordination records (MULTI_ASSISTANT_PLAN §6), all in
/// `<default data root>/machine/upgrade/`: `upgrade.lock` (the upgrader's
/// lease), `barrier.json`, `ack/<lease uuid>.json`, `journal.json`,
/// `installed.json` and the retained backups of the old binary and bundle.
enum UpgradeBarrier {
    // MARK: Paths

    struct Paths {
        var root: URL
        var lock: URL { root.appendingPathComponent("upgrade.lock") }
        var barrier: URL { root.appendingPathComponent("barrier.json") }
        var ackDir: URL { root.appendingPathComponent("ack", isDirectory: true) }
        func ack(_ leaseUUID: String) -> URL { ackDir.appendingPathComponent("\(leaseUUID).json") }
        var journal: URL { root.appendingPathComponent("journal.json") }
        var installed: URL { root.appendingPathComponent("installed.json") }

        static var live: Paths { Paths(root: MachinePaths.machineDir().appendingPathComponent("upgrade", isDirectory: true)) }
    }

    // MARK: Records

    enum State: String, Codable { case open, committed, cancelled, closed, stuck }

    struct Participant: Codable, Equatable {
        var profile: String
        var generation: String?
        var lease: String
        var incarnation: String
        var coordinator: Bool
    }

    struct Coordinator: Codable, Equatable {
        var lease: String
        var pid: Int32
        var processStartTime: String
    }

    struct Record: Codable, Equatable {
        var id: String
        var state: State
        var targetVersion: String
        var targetSequence: Int
        var openedAt: Date
        var coordinator: Coordinator
        var participants: [Participant]?
        /// Set at commit: the identity of the installed pair.
        var committedBinarySHA256: String?
        var reason: String?

        /// A barrier that still holds admission (or blocks sessions).
        var isActive: Bool { state == .open || state == .committed || state == .stuck }
    }

    enum AckState: String, Codable { case busy, parked, restarted }

    struct Ack: Codable, Equatable {
        var barrierId: String
        var incarnation: String
        var state: AckState
        var reason: String?
        var releaseSequence: Int?
    }

    struct Identity: Codable, Equatable {
        var binarySHA256: String
        var bundleHash: String
    }

    enum Phase: String, Codable { case prepared, moving, placed, verified, committed }

    struct Journal: Codable, Equatable {
        var barrierId: String
        var phase: Phase
        /// The step about to run while `moving` (for diagnostics).
        var nextStep: String?
        var old: Identity
        var new: Identity
        var newVersion: String
        var newSequence: Int
        var executable: String
        var bundle: String
        var backupBinary: String
        var backupBundle: String
        var stagedBinary: String
        var stagedBundle: String
        var bundleExisted: Bool
    }

    struct Installed: Codable, Equatable {
        var version: String
        var sequence: Int
        var executable: String
        var binarySHA256: String
        var bundleHash: String
    }

    // MARK: IO

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    enum ReadResult<T> { case absent, value(T), malformed(String) }

    static func readFile<T: Decodable>(_ url: URL, as type: T.Type) -> ReadResult<T> {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            return errno == ENOENT ? .absent : .malformed("cannot stat \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 1024 * 1024 else {
            return .malformed("\(url.lastPathComponent) is not a regular file or is too large")
        }
        guard let data = try? Data(contentsOf: url) else { return .malformed("cannot read \(url.lastPathComponent)") }
        guard let value = try? decoder().decode(T.self, from: data) else { return .malformed("\(url.lastPathComponent) is malformed") }
        return .value(value)
    }

    static func writeFile<T: Encodable>(_ value: T, to url: URL) throws {
        try PrivateStorage.ensureDirectory(url.deletingLastPathComponent(), mode: 0o700)
        _ = try PrivateStorage.writeAtomically(try encoder().encode(value), to: url, mode: 0o600)
    }

    /// The current barrier; a malformed file reads as a stuck barrier (fail
    /// closed: admission stays paused, sessions refuse).
    static func current(_ paths: Paths = .live) -> Record? {
        switch readFile(paths.barrier, as: Record.self) {
        case .absent: return nil
        case .value(let r): return r
        case .malformed(let why):
            return Record(id: "malformed", state: .stuck, targetVersion: "?", targetSequence: 0, openedAt: Date(),
                          coordinator: Coordinator(lease: "", pid: 0, processStartTime: ""), participants: nil,
                          committedBinarySHA256: nil, reason: why)
        }
    }

    static func writeBarrier(_ record: Record, _ paths: Paths = .live) throws { try writeFile(record, to: paths.barrier) }

    static func readAck(_ uuid: String, _ paths: Paths = .live) -> Ack? {
        if case .value(let a) = readFile(paths.ack(uuid), as: Ack.self) { return a }
        return nil
    }

    static func writeAck(_ ack: Ack, lease: String, _ paths: Paths = .live) {
        try? writeFile(ack, to: paths.ack(lease))
    }

    static func clearAcks(_ paths: Paths = .live) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.ackDir.path) else { return }
        for n in names { unlink(paths.ackDir.appendingPathComponent(n).path) }
    }

    static func journal(_ paths: Paths = .live) -> ReadResult<Journal> { readFile(paths.journal, as: Journal.self) }

    static func writeJournal(_ j: Journal, _ paths: Paths = .live) throws { try writeFile(j, to: paths.journal) }

    // MARK: Identities

    static func sha256(file url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A content hash of a bundle directory: sorted relative paths, each
    /// with its file's SHA-256 (symlinks by target). nil when unreadable.
    static func bundleHash(_ dir: URL) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
              let walker = fm.enumerator(atPath: dir.path) else { return nil }
        var lines: [String] = []
        while let rel = walker.nextObject() as? String {
            let url = dir.appendingPathComponent(rel)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                guard let h = sha256(file: url) else { return nil }
                lines.append("f \(rel) \(h)")
            case S_IFLNK:
                lines.append("l \(rel) \((try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "?")")
            case S_IFDIR:
                lines.append("d \(rel)")
            default:
                lines.append("o \(rel)")
            }
        }
        lines.sort()
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func identity(binary: URL, bundle: URL) -> Identity? {
        guard let b = sha256(file: binary) else { return nil }
        let h = bundleHash(bundle) ?? "absent"
        return Identity(binarySHA256: b, bundleHash: h)
    }

    // MARK: Installed release (§5.1)

    /// `installed.json` only when its recorded identities equal what is on
    /// disk now; otherwise nil (a stale record after an external install is
    /// never trusted).
    static func validatedInstalled(_ paths: Paths = .live, executable: URL = UpgradeService.executableURL) -> Installed? {
        guard case .value(let rec) = readFile(paths.installed, as: Installed.self) else { return nil }
        guard rec.executable == executable.path, sha256(file: executable) == rec.binarySHA256 else { return nil }
        let bundle = executable.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName)
        guard (bundleHash(bundle) ?? "absent") == rec.bundleHash else { return nil }
        return rec
    }

    /// The installed release sequence: from a validated `installed.json`,
    /// else from the disk binary itself (`__release-identity`), else this
    /// binary's own compiled sequence when the disk binary is this image.
    static func installedSequence(_ paths: Paths = .live, executable: URL = UpgradeService.executableURL) -> Int? {
        if let rec = validatedInstalled(paths, executable: executable) { return rec.sequence }
        return releaseIdentity(of: executable)?.sequence
    }

    struct ReleaseIdentity: Codable { var version: String; var sequence: Int }

    /// Run `<binary> __release-identity` (resource-free, exempt from gates).
    static func releaseIdentity(of binary: URL) -> ReleaseIdentity? {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["__release-identity"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: AssistantProfile.environmentKey)
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode(ReleaseIdentity.self, from: data)
    }

    /// §6.1: a member whose compiled sequence is older than the validated
    /// installed release re-execs the binary on disk (same argv). Returns
    /// only when no re-exec is needed.
    static let reexecGuardKey = "BRIGLIA_REEXEC_GUARD"

    static func reexecIfOlder(_ paths: Paths = .live) {
        // Cheap first: only a record claiming a newer sequence is worth
        // hashing the installed pair for.
        guard case .value(let raw) = readFile(paths.installed, as: Installed.self), raw.sequence > ReleaseSequence.compiled,
              let rec = validatedInstalled(paths), rec.sequence > ReleaseSequence.compiled else { return }
        // Never loop: not when this image already IS that binary, and not a
        // second time for the same installed identity.
        let own = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        if sha256(file: own) == rec.binarySHA256 { return }
        if ProcessInfo.processInfo.environment[reexecGuardKey] == rec.binarySHA256 { return }
        setenv(reexecGuardKey, rec.binarySHA256, 1)
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        fflush(stdout); fflush(stderr)
        execv(rec.executable, argv)
        // exec failed: keep running the old image (logged).
        FileHandle.standardError.write(Data("⚠ could not start the updated Briglia (\(String(cString: strerror(errno)))); continuing on \(adaCLIVersion)\n".utf8))
    }

    // MARK: Messages (EN/IT)

    static let updatingMessage = "Briglia is updating; try again in a minute. / Briglia si sta aggiornando; riprova tra un minuto."
    static let stuckMessage = "Briglia's update could not be completed or undone automatically; run `briglia upgrade --recover`. / L'aggiornamento di Briglia non si è potuto completare né annullare da solo; esegui `briglia upgrade --recover`."
}
