import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Low-level identity of a path, from `lstat`/`fstat` (GPT_APPLY_PATCH_PLAN
/// §6.5 step 4, §7). Nanosecond timestamps: a same-size rewrite inside the
/// same second must still differ.
struct FileIdentity: Equatable, CustomStringConvertible {
    enum Kind: String, Equatable { case regular, symlink, directory, other }
    var kind: Kind
    var device: UInt64
    var inode: UInt64
    var mode: mode_t          // permission bits only
    var uid: UInt32
    var size: Int64
    var mtimeNs: Int64
    var ctimeNs: Int64
    var linkTarget: String?

    var description: String {
        "\(kind.rawValue) dev=\(device) ino=\(inode) mode=\(String(mode, radix: 8)) size=\(size) mtime=\(mtimeNs) ctime=\(ctimeNs)" + (linkTarget.map { " → \($0)" } ?? "")
    }

    init(stat st: stat, linkTarget: String? = nil) {
        let fmt = st.st_mode & S_IFMT
        kind = fmt == S_IFREG ? .regular : fmt == S_IFLNK ? .symlink : fmt == S_IFDIR ? .directory : .other
        device = UInt64(truncatingIfNeeded: st.st_dev)
        inode = UInt64(truncatingIfNeeded: st.st_ino)
        mode = st.st_mode & 0o7777
        uid = UInt32(st.st_uid)
        size = Int64(st.st_size)
        #if canImport(Darwin)
        mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        ctimeNs = Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec)
        #else
        mtimeNs = Int64(st.st_mtim.tv_sec) * 1_000_000_000 + Int64(st.st_mtim.tv_nsec)
        ctimeNs = Int64(st.st_ctim.tv_sec) * 1_000_000_000 + Int64(st.st_ctim.tv_nsec)
        #endif
        self.linkTarget = linkTarget
    }

    /// `lstat` (the leaf as named). nil when absent; throws on other errors.
    static func lstatPath(_ path: String) throws -> FileIdentity? {
        var st = stat()
        if lstat(path, &st) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw CodexPatchFS.posix("lstat \(path)")
        }
        var id = FileIdentity(stat: st)
        if id.kind == .symlink { id.linkTarget = CodexPatchFS.readLink(path) }
        return id
    }

    static func fstatFD(_ fd: Int32) throws -> FileIdentity {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw CodexPatchFS.posix("fstat") }
        return FileIdentity(stat: st)
    }

    /// Same file object, same metadata (everything §6.5 step 4 lists except
    /// the content hash, which callers compare separately).
    func sameState(as other: FileIdentity) -> Bool {
        kind == other.kind && device == other.device && inode == other.inode && mode == other.mode
            && uid == other.uid && size == other.size && mtimeNs == other.mtimeNs && ctimeNs == other.ctimeNs
            && linkTarget == other.linkTarget
    }

    /// Same object and content-relevant metadata, ignoring ctime (used only to
    /// bind a just-renamed inode to its staged identity, §6.5).
    func sameObjectIgnoringCtime(as other: FileIdentity) -> Bool {
        kind == other.kind && device == other.device && inode == other.inode && mode == other.mode
            && size == other.size && mtimeNs == other.mtimeNs
    }
}

enum CodexPatchFS {
    struct POSIXError: Error, CustomStringConvertible {
        let operation: String
        let code: Int32
        var description: String { "\(operation): \(String(cString: strerror(code)))" }
    }

    static func posix(_ operation: String, _ code: Int32 = errno) -> POSIXError { POSIXError(operation: operation, code: code) }

    /// Rust `io::Error` Display for an OS error: `"{strerror} (os error {n})"`.
    static func rustOSError(_ code: Int32) -> String { "\(String(cString: strerror(code))) (os error \(code))" }

    static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buffer, buffer.count - 1)
        guard n >= 0 else { return nil }
        buffer[n] = 0
        return String(cString: buffer)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a regular file through ONE descriptor, with its identity taken
    /// from that descriptor before and after the read (plan §21 note 1: a
    /// post-read-only stat could credit an in-place change made after the
    /// bytes were read). Returns nil identity agreement as a thrown error.
    struct ObservedFile {
        let data: Data
        let identity: FileIdentity
    }

    struct ChangedWhileReading: Error, CustomStringConvertible {
        let path: String
        var description: String { "\(path) changed while it was being read" }
    }

    /// Selftests only: runs between the descriptor's first identity and the
    /// read (lets a test write in place exactly there).
    nonisolated(unsafe) static var readObservedHook: ((String) -> Void)?

    static func readObserved(_ path: String, limit: Int) throws -> ObservedFile {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posix("open \(path)") }
        defer { close(fd) }
        let before = try FileIdentity.fstatFD(fd)
        guard before.kind == .regular else { throw posix("open \(path)", EISDIR) }
        readObservedHook?(path)
        if before.size > Int64(limit) { throw SizeLimit(path: path, size: before.size, limit: limit) }
        var data = Data()
        data.reserveCapacity(Int(before.size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw posix("read \(path)") }
            if n == 0 { break }
            data.append(buffer, count: n)
            if data.count > limit { throw SizeLimit(path: path, size: Int64(data.count), limit: limit) }
        }
        let after = try FileIdentity.fstatFD(fd)
        guard before.sameState(as: after), Int64(data.count) == after.size else { throw ChangedWhileReading(path: path) }
        return ObservedFile(data: data, identity: before)
    }

    struct SizeLimit: Error, CustomStringConvertible {
        let path: String
        let size: Int64
        let limit: Int
        var description: String { "\(path) is \(size) bytes; apply_patch handles files up to \(limit / (1024 * 1024)) MiB" }
    }

    /// Current state + content hash of a regular file (nil when absent).
    static func stateAndHash(_ path: String, limit: Int) throws -> (FileIdentity, String)? {
        guard let id = try FileIdentity.lstatPath(path) else { return nil }
        guard id.kind == .regular else { return (id, "") }
        let observed = try readObserved(path, limit: limit)
        return (observed.identity, sha256(observed.data))
    }

    static func isEmptyDirectory(_ path: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return entries.isEmpty
    }

    static func currentUmask() -> mode_t {
        // Read without changing it for longer than the two calls; no other
        // thread in this process changes the umask.
        let old = umask(0o022)
        umask(old)
        return old
    }
}

/// GPT-only read-before-write evidence (plan §7).
enum GPTEvidence {
    enum Source: String { case shellRead, gptPatch, gptReadFile }

    struct Record {
        let identity: FileIdentity
        let recordedAt: Date
        let source: Source
    }

    /// A version actually observed (a read delivered to the model, or the
    /// transaction's own committed post-image). Published only after
    /// delivery; `key` is the canonical resolved path.
    struct Receipt {
        let key: String
        let identity: FileIdentity
        let source: Source
    }

    enum Freshness {
        case fresh
        case stale(recordedAt: Date)
        case none
    }

    /// Fresh iff device, inode, type, link target, size, mtime and ctime all
    /// equal the current values. Legacy standard records never qualify.
    static func freshness(key: String, current: FileIdentity) async -> Freshness {
        guard let record = await FileTimeTracker.shared.gptRecord(forKey: key) else { return .none }
        let r = record.identity
        let same = r.kind == current.kind && r.device == current.device && r.inode == current.inode
            && r.linkTarget == current.linkTarget && r.size == current.size
            && r.mtimeNs == current.mtimeNs && r.ctimeNs == current.ctimeNs
        return same ? .fresh : .stale(recordedAt: record.recordedAt)
    }
}
