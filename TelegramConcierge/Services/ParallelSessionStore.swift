import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The conversation search ID (KEYLESS_WEB_AND_LIVE_MENU_PLAN A.5): ONE
/// random v4 UUID per Briglia conversation (= per assistant profile), sent
/// as Parallel's `session_id` on every keyless search of that profile and
/// NEVER rotated — Parallel's AUP forbids splitting free-tier accounting.
///
/// `dataRoot/search-session.json`, 0600:
///   {"version":1,"parallel_session_id":"<uuid>","created":"<ISO-8601>"}
///
/// - Minted only when the file is ABSENT, as a complete temp file linked into
///   place without replacing (two processes can never mint two IDs).
/// - Present but unreadable/malformed: no new ID; keyless search fails with
///   a doctor fix until the user runs `/freesearch reset`.
/// - `/deleteuserdata` deletes it; a Mind import discards it (the imported
///   conversation is another conversation). Never exported, never derived
///   from identity, never touched on errors or limits.
enum ParallelSessionStore {
    static let fileName = "search-session.json"
    nonisolated(unsafe) static var fileURLOverrideForTesting: URL?
    static var fileURL: URL { fileURLOverrideForTesting ?? StoragePaths.dataRoot.appendingPathComponent(fileName) }

    private static let lock = NSLock()
    private static let maxBytes = 4096

    enum State: Equatable {
        case absent
        case valid(String)
        case damaged(String)
    }

    /// The file's directory entry could not be confirmed durable (a failed
    /// directory fsync). The ID is NOT used until a later call confirms it;
    /// the visible file is kept and never re-minted for this reason.
    struct NotDurable: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Free search is unavailable right now: its session file could not be saved durably (\(reason)). Try again; if it persists, check the disk and run `briglia doctor`."
        }
    }

    /// Test seam: replaces the directory barrier (fault injection).
    nonisolated(unsafe) static var fsyncDirectoryForTesting: ((String) throws -> Void)?
    private static func barrier(_ dir: URL) throws {
        if let hook = fsyncDirectoryForTesting { try hook(dir.path) } else { try PrivateStorage.fsyncDirectory(dir.path) }
    }
    /// The ID whose directory entry this process has confirmed durable.
    nonisolated(unsafe) private static var confirmedID: String?

    struct Damaged: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Free search is unavailable: its session file is damaged. Run `briglia doctor` for the fix."
        }
    }

    /// Read-only inspection (doctor, /status, the mint path).
    static func state() -> State {
        lock.lock(); defer { lock.unlock() }
        return stateLocked()
    }

    private static func stateLocked() -> State {
        let path = fileURL.path
        var st = stat()
        if lstat(path, &st) != 0 {
            return errno == ENOENT ? .absent : .damaged("cannot inspect \(fileName): \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .damaged("\(fileName) is not a regular file") }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return .damaged("cannot open \(fileName): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return .damaged("cannot read \(fileName)") }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.count > maxBytes { return .damaged("\(fileName) is too large") }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? Int) == 1,
              let id = object["parallel_session_id"] as? String,
              let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id.lowercased()
        else { return .damaged("\(fileName) is malformed") }
        return .valid(id)
    }

    /// The ID for a keyless search: the existing one, or a newly minted one
    /// when (and only when) the file is absent. Throws `Damaged` otherwise.
    static func idForSearch() throws -> String {
        lock.lock(); defer { lock.unlock() }
        switch stateLocked() {
        case .valid(let id): return try confirmedLocked(id)
        case .damaged(let reason): throw Damaged(reason: reason)
        case .absent: return try mintLocked()
        }
    }

    /// An ID is used only once its directory entry is confirmed durable in
    /// this process (it may have been published by another process, or an
    /// earlier barrier may have failed): one checked directory fsync.
    private static func confirmedLocked(_ id: String) throws -> String {
        if confirmedID == id { return id }
        do { try barrier(fileURL.deletingLastPathComponent()) }
        catch { throw NotDurable(reason: "\(error)") }
        confirmedID = id
        return id
    }

    /// Test seam: a mint attempt (deliberate-break M2 checks the damaged
    /// path never reaches it).
    nonisolated(unsafe) static var mintCountForTesting = 0
    /// Test seam: replaces the exclusive temp-file write of a mint (fault
    /// injection that works as root too, where a read-only directory would
    /// not stop the write). nil = the real `PrivateStorage.writeExclusive`.
    nonisolated(unsafe) static var writeTempForTesting: ((Data, URL) throws -> Void)?

    private static func mintLocked() throws -> String {
        mintCountForTesting += 1
        let id = UUID().uuidString.lowercased()
        let created = ISO8601DateFormatter().string(from: Date())
        let body = "{\"version\":1,\"parallel_session_id\":\"\(id)\",\"created\":\"\(created)\"}\n"
        let dir = fileURL.deletingLastPathComponent()
        try PrivateStorage.ensureDirectory(dir)
        let tmp = dir.appendingPathComponent(".\(fileName).mint-\(UUID().uuidString)")
        if let hook = writeTempForTesting { try hook(Data(body.utf8), tmp) }
        else { try PrivateStorage.writeExclusive(Data(body.utf8), to: tmp) }
        defer { unlink(tmp.path) }
        // link(2) never replaces: if another process minted first, use ITS id.
        if link(tmp.path, fileURL.path) != 0 {
            let code = errno
            if code == EEXIST {
                switch stateLocked() {
                case .valid(let other): return try confirmedLocked(other)
                case .damaged(let reason): throw Damaged(reason: reason)
                case .absent: throw Damaged(reason: "\(fileName) vanished while minting")
                }
            }
            throw PrivateStorage.StorageError(description: "could not create \(fileURL.path): \(String(cString: strerror(code)))")
        }
        // Published: the visible file is kept whatever happens next; it is
        // used only after its entry is confirmed durable (a failure here
        // fails this search and a later call confirms the SAME id).
        return try confirmedLocked(id)
    }

    /// `/freesearch reset`, an explicit user action: a DAMAGED file is moved
    /// aside (kept for inspection) and a new ID minted. A valid ID is kept —
    /// reset never rotates a working ID.
    enum ResetOutcome: Equatable { case kept(String), replaced(String), minted(String) }
    static func reset() throws -> ResetOutcome {
        lock.lock(); defer { lock.unlock() }
        switch stateLocked() {
        case .valid(let id): return .kept(try confirmedLocked(id))
        case .absent: return .minted(try mintLocked())
        case .damaged:
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("\(fileName).damaged-\(stamp)-\(UUID().uuidString.prefix(8))")
            guard rename(fileURL.path, aside.path) == 0 else {
                throw PrivateStorage.StorageError(description: "could not move the damaged \(fileName) aside: \(String(cString: strerror(errno)))")
            }
            try barrier(fileURL.deletingLastPathComponent())
            return .replaced(try mintLocked())
        }
    }

    /// `/deleteuserdata` and Mind import: the conversation ends, so does its ID.
    /// The deletion is reported only once its directory entry is durable
    /// (checked fsync), so a wipe or import never claims a removal a crash
    /// could undo.
    static func discard() throws {
        lock.lock(); defer { lock.unlock() }
        confirmedID = nil
        if unlink(fileURL.path) != 0 {
            guard errno == ENOENT else {
                throw PrivateStorage.StorageError(description: "could not delete \(fileURL.path): \(String(cString: strerror(errno)))")
            }
        }
        let dir = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dir.path) { try barrier(dir) }
    }
}
