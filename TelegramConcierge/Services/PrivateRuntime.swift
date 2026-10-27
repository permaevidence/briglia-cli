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

// MARK: - Briglia-private runtimes (security plan v23 §7.8.1 template, §7.9)
//
// One template for every Briglia-owned pinned component (AgentMail, Node,
// the Python venv), all under ~/.local/share/briglia/runtime/<component>/:
//
//   v/<name>/          immutable version directories (never rewritten)
//   current            symlink to v/<name> — THE single authority for what runs,
//                      switched by one rename(2) + parent fsync
//   receipt.json       permanent: one record per installed version and
//                      `verified` (the record whose post-commit probe passed)
//   tx.json            the private journal: committing → probed
//   .staging-<attempt> owned by an attempt record in selected.json
//
// runtime/selected.json (under runtime/selection.lock, always taken FIRST,
// then the component lock) carries the mirrors, attempt records, the
// AgentMail hold and the Node/Python selection. Nothing here ever writes
// ~/.local/bin or any shared path (D16, §7.2).

enum RuntimeComponent: String, Codable, CaseIterable, Sendable {
    case agentmail, node, python
}

enum RuntimePaths {
    /// Selftest seam: replaces the data root (production: StoragePaths.dataRoot).
    nonisolated(unsafe) static var dataRootOverride: URL?
    static var dataRoot: URL { dataRootOverride ?? StoragePaths.dataRoot }
    static var runtimeRoot: URL { dataRoot.appendingPathComponent("runtime", isDirectory: true) }
    /// Briglia-only command names, FIRST on the agent's PATH (§7.9.1).
    static var binDir: URL { dataRoot.appendingPathComponent("bin", isDirectory: true) }
    /// Node fallback shims, LAST on PATH, present only while the private Node is selected.
    static var fallbackBinDir: URL { dataRoot.appendingPathComponent("fallback-bin", isDirectory: true) }
    static var selectionFile: URL { runtimeRoot.appendingPathComponent("selected.json") }
    static var selectionLock: URL { runtimeRoot.appendingPathComponent("selection.lock") }
    static func dir(_ c: RuntimeComponent) -> URL { runtimeRoot.appendingPathComponent(c.rawValue, isDirectory: true) }
    static func versions(_ c: RuntimeComponent) -> URL { dir(c).appendingPathComponent("v", isDirectory: true) }
    static func current(_ c: RuntimeComponent) -> URL { dir(c).appendingPathComponent("current") }
    static func receipt(_ c: RuntimeComponent) -> URL { dir(c).appendingPathComponent("receipt.json") }
    static func journal(_ c: RuntimeComponent) -> URL { dir(c).appendingPathComponent("tx.json") }
    static func retired(_ c: RuntimeComponent) -> URL { dir(c).appendingPathComponent("retired", isDirectory: true) }
    static func componentLock(_ c: RuntimeComponent) -> URL { dir(c).appendingPathComponent(".\(c.rawValue).lock") }
    static func staging(_ c: RuntimeComponent, attempt: String) -> URL { dir(c).appendingPathComponent(".staging-\(attempt)", isDirectory: true) }
}

// MARK: - Records

struct RuntimePin: Codable, Equatable, Sendable {
    var triple: String
    var version: String
    var archiveSHA256: String
}

struct RuntimeRecord: Codable, Equatable, Sendable {
    var triple: String
    var version: String
    var archiveSHA256: String
    /// SHA-256 of the component's identity file (`RuntimeSpec.binaryRelPath`).
    var binarySHA256: String
    /// `v/<name>`, relative to the component directory.
    var directory: String
    var installedAt: Date
    var extra: [String: String]? = nil

    var pin: RuntimePin { RuntimePin(triple: triple, version: version, archiveSHA256: archiveSHA256) }
}

struct RuntimeReceipt: Codable, Equatable {
    var schema = 1
    var records: [RuntimeRecord] = []
    /// `directory` of the verified record.
    var verified: String?

    func record(directory: String) -> RuntimeRecord? { records.first { $0.directory == directory } }
    var verifiedRecord: RuntimeRecord? { verified.flatMap(record(directory:)) }
}

struct RuntimeJournal: Codable, Equatable {
    var schema = 2
    var layout = "private"
    var attemptId: String
    /// `v/<name>` of the previous `current`, nil on a first private install.
    var oldTarget: String?
    var newTarget: String
    var newRecord: RuntimeRecord
    /// committing | probed
    var state: String
    /// nil = ordinary update; "repair" = AgentMail repair transaction (§7.8.1 v13/v14).
    var mode: String? = nil
    var priorCurrent: String? = nil
    var retired: String? = nil
}

struct RuntimeAttempt: Codable, Equatable, Sendable {
    var attemptId: String
    /// auto | explicit | install | repair | repair-auto
    var kind: String
    var pin: RuntimePin
    var pid: Int32
    var processStart: UInt64?
    var bootId: String?
    var startedAt: Date
    var generation: Int
    /// converged | waiting-for-idle | failed: <reason> | abandoned | nil (in flight)
    var result: String?
    var finishedAt: Date?
    /// Python: the final build directory the attempt owns (built in place, §7.9.4).
    var buildDirectory: String?
}

/// The AgentMail hold (§7.8.1 v14).
struct RuntimeHold: Codable, Equatable, Sendable {
    var pin: RuntimePin
    /// repair-in-progress | repair-failed | repair-interrupted | unknown
    var reason: String
    var since: Date
    var attemptId: String?
}

/// Node/Python: what Briglia selected for its managed consumers (§7.1).
struct RuntimeSelection: Codable, Equatable, Sendable {
    /// private-exact | shared-accepted | unavailable | unknown
    var providerClass: String
    var path: String?
    var version: String?
    var probedAt: Date
    var reason: String?
}

struct RuntimeRunning: Codable, Equatable, Sendable {
    var resolvedDirectory: String
    var pid: Int32
    var startedAt: Date
}

struct RuntimeComponentState: Codable, Equatable {
    var mirror: RuntimeRecord?
    var attempts: [RuntimeAttempt] = []
    var hold: RuntimeHold?
    var selection: RuntimeSelection?
    var running: RuntimeRunning?
    var lastStatus: String?
    /// Transient, never encoded: recovery sets it when the journal may be
    /// deleted once this state is durable on disk.
    var pendingJournalDelete = false

    enum CodingKeys: String, CodingKey { case mirror, attempts, hold, selection, running, lastStatus }

    static let maxAttempts = 8
    var latestAutoAttempt: RuntimeAttempt? {
        attempts.filter { ["auto", "repair-auto"].contains($0.kind) }.max { $0.startedAt < $1.startedAt }
    }
}

struct RuntimeSelectionFile: Codable, Equatable {
    var schema = 1
    /// Lifecycle generation: bumped by /deleteuserdata, Mind import and an
    /// email-provider change (§7.8.1 step 4/10).
    var generation = 0
    var components: [String: RuntimeComponentState] = [:]

    subscript(_ c: RuntimeComponent) -> RuntimeComponentState {
        get { components[c.rawValue] ?? RuntimeComponentState() }
        set { components[c.rawValue] = newValue }
    }
}

struct RuntimeError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }
    init(_ d: String) { description = d }
}

// MARK: - Locks

/// Exclusive flock on a regular, non-symlink file inside the runtime root.
/// Blocking with a bound: the critical sections are short (metadata writes,
/// at most one probe).
final class RuntimeLock {
    private var fd: Int32
    private init(fd: Int32) { self.fd = fd }

    static func acquire(_ url: URL, timeout: TimeInterval = 30) throws -> RuntimeLock {
        try RuntimeFS.ensureDir(url.deletingLastPathComponent())
        try RuntimeFS.contain(url)
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw RuntimeError("cannot open \(url.path): \(String(cString: strerror(errno))) (a symlink or non-regular file is refused)")
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd); throw RuntimeError("\(url.path) is not a regular file — refusing")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline { close(fd); throw RuntimeError("timed out waiting for \(url.lastPathComponent)") }
            usleep(20_000)
        }
        return RuntimeLock(fd: fd)
    }

    static func tryAcquire(_ url: URL) throws -> RuntimeLock? {
        do { return try acquire(url, timeout: 0) } catch let e as RuntimeError where e.description.hasPrefix("timed out") { return nil }
    }

    func release() { if fd >= 0 { close(fd); fd = -1 } }
    deinit { release() }
}

/// The fixed lock order: selection lock, then the component lock (§7.8.1).
struct RuntimeLocks {
    let selection: RuntimeLock
    let component: RuntimeLock
    static func take(_ c: RuntimeComponent, timeout: TimeInterval = 30) throws -> RuntimeLocks {
        let s = try RuntimeLock.acquire(RuntimePaths.selectionLock, timeout: timeout)
        let k = try RuntimeLock.acquire(RuntimePaths.componentLock(c), timeout: timeout)
        return RuntimeLocks(selection: s, component: k)
    }
    func release() { component.release(); selection.release() }
}

// MARK: - Process identity (attempt ownership, §7.8.1 step 3)

enum RuntimeProcessIdentity {
    static func startTime(pid: Int32) -> UInt64? {
        #if os(Linux)
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.range(of: ")", options: .backwards) else { return nil }
        let fields = stat[close.upperBound...].split(separator: " ")
        guard fields.count > 19 else { return nil }
        return UInt64(fields[19])
        #else
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return UInt64(tv.tv_sec) &* 1_000_000 &+ UInt64(tv.tv_usec)
        #endif
    }

    static func bootId() -> String? {
        #if os(Linux)
        return (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return "\(tv.tv_sec).\(tv.tv_usec)"
        #endif
    }

    /// Positively gone: another boot, no such pid, or the pid was reused
    /// (different start time). Unknown is NOT gone.
    static func ownerGone(_ a: RuntimeAttempt) -> Bool {
        if let boot = a.bootId, let now = bootId(), boot != now { return true }
        if kill(a.pid, 0) != 0 && errno == ESRCH { return true }
        if let recorded = a.processStart, let live = startTime(pid: a.pid), live != recorded { return true }
        return false
    }
}

// MARK: - Durable file helpers

enum RuntimeFS {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    enum Kind: Equatable { case absent, regular, directory, symlink, other }

    static func kind(_ path: String) -> Kind {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .absent }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .regular
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    /// Reads a JSON file that must be a regular file. nil when absent;
    /// throws when present but unreadable/malformed (never "absent").
    static func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T? {
        switch kind(url.path) {
        case .absent: return nil
        case .regular: break
        default: throw RuntimeError("\(url.lastPathComponent) is not a regular file")
        }
        let data = try Data(contentsOf: url)
        do { return try decoder.decode(T.self, from: data) } catch {
            throw RuntimeError("\(url.lastPathComponent) is unreadable: \(error)")
        }
    }

    static func writeJSON<T: Encodable>(_ value: T, _ url: URL) throws {
        try write(try encoder.encode(value), to: url, mode: 0o600)
    }

    /// Resolved containment (plan §7.1, review R1): `url` must lie lexically
    /// under the data root, and every existing entry between the data root
    /// and `url` must be a real directory (never a symlink or other type),
    /// so no write or execution is redirected out of Briglia's root. The data
    /// root itself may be a symlink (a deliberately relocated root). The
    /// final entry may be a symlink only where Briglia manages one (`current`,
    /// shims), and is otherwise a directory, a regular file or absent.
    static func contain(_ url: URL, finalMayBeSymlink: Bool = false) throws {
        // Lexical comparison of the spellings as built (both from dataRoot):
        // standardizing resolves /private aliases for existing paths only,
        // which made a legitimate descendant look outside (round-2 note).
        var root = RuntimePaths.dataRoot.path
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        let path = url.path
        guard path.hasPrefix(root + "/") else { throw RuntimeError("\(path) is outside Briglia's data root") }
        let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { throw RuntimeError("\(path): unexpected path form") }
        var cur = root
        for (i, part) in parts.enumerated() {
            cur += "/" + part
            let k = kind(cur)
            if k == .absent { return }   // nothing below exists yet
            let last = i == parts.count - 1
            if last {
                switch k {
                case .directory, .regular: return
                case .symlink where finalMayBeSymlink: return
                default: throw RuntimeError("\(cur) is a \(k) where Briglia expects its own file (refusing to follow it)")
                }
            }
            guard k == .directory else { throw RuntimeError("\(cur) is a \(k), not a directory: refusing a redirect out of Briglia's data root") }
        }
    }

    /// PrivateStorage.ensureDirectory with containment before and after.
    static func ensureDir(_ url: URL) throws {
        try contain(url)
        try PrivateStorage.ensureDirectory(url)
        try contain(url)
    }

    /// Contained atomic write (parent created owner-only).
    static func write(_ data: Data, to url: URL, mode: mode_t) throws {
        try ensureDir(url.deletingLastPathComponent())
        try contain(url)
        try PrivateStorage.writeAtomically(data, to: url, mode: mode)
    }

    /// Checked unlink + parent fsync; ENOENT is fine.
    static func remove(_ url: URL) throws {
        try contain(url, finalMayBeSymlink: true)
        if unlink(url.path) != 0, errno != ENOENT {
            throw RuntimeError("could not remove \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        try PrivateStorage.fsyncDirectory(url.deletingLastPathComponent().path)
    }

    /// The single switch: a fresh relative link renamed over `link`, then the
    /// parent directory fsynced (§7.8.1 "the single authority").
    static func switchLink(_ link: URL, to relativeTarget: String) throws {
        try contain(link, finalMayBeSymlink: true)
        let dir = link.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(link.lastPathComponent).tmp-\(UUID().uuidString)")
        guard symlink(relativeTarget, tmp.path) == 0 else {
            throw RuntimeError("could not create a link at \(tmp.path): \(String(cString: strerror(errno)))")
        }
        guard rename(tmp.path, link.path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(tmp.path)
            throw RuntimeError("could not switch \(link.lastPathComponent): \(why)")
        }
        try PrivateStorage.fsyncDirectory(dir.path)
    }

    /// POSIX single-quoted word (an apostrophe in a path becomes '\'').
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// ` --profile '<name>'` for an extra assistant's wrapper scripts (they
    /// live in that assistant's own `bin/` and must reach its own state even
    /// when run outside Briglia); empty for default, so default's wrappers
    /// keep their exact bytes (MULTI_ASSISTANT_PLAN §3.2).
    static func profileWords() -> String {
        AssistantProfile.selectionArguments.map { " " + shellQuote($0) }.joined()
    }

    static func readLink(_ url: URL) -> String? {
        guard kind(url.path) == .symlink else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = readlink(url.path, &buf, buf.count - 1)
        guard n > 0 else { return nil }
        buf[n] = 0
        return String(cString: buf)
    }

    static func sha256(file url: URL) -> String? {
        guard kind(url.path) == .regular, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = fh.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A `v/<name>` reference that stays inside the component's version directory.
    static func validVersionRef(_ ref: String) -> Bool {
        guard ref.hasPrefix("v/") else { return false }
        let name = String(ref.dropFirst(2))
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..",
              name.allSatisfy({ $0.isLetter || $0.isNumber || ".-_+".contains($0) }) else { return false }
        return true
    }

    static func randomHex(_ bytes: Int = 16) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Recursive size-bounded removal of a directory we own (never follows links).
    /// Owner-only staged payloads (private storage, Release B): tools such as
    /// `python -m venv`, pip and tar create 0755/0644 entries; strip group and
    /// other bits from every non-symlink entry (symlinks carry no mode).
    static func restrictTree(_ url: URL) throws {
        func fix(_ path: String) throws {
            var st = stat()
            guard lstat(path, &st) == 0 else { throw RuntimeError("could not inspect \(path): \(String(cString: strerror(errno)))") }
            guard (st.st_mode & S_IFMT) != S_IFLNK, st.st_mode & 0o077 != 0 else { return }
            guard chmod(path, st.st_mode & 0o7700) == 0 else { throw RuntimeError("could not restrict \(path): \(String(cString: strerror(errno)))") }
        }
        try fix(url.path)
        guard let e = FileManager.default.enumerator(atPath: url.path) else { return }
        for case let rel as String in e { try fix(url.path + "/" + rel) }
    }

    static func removeTree(_ url: URL) throws {
        guard kind(url.path) != .absent else { return }
        try contain(url)
        try FileManager.default.removeItem(at: url)
        try PrivateStorage.fsyncDirectory(url.deletingLastPathComponent().path)
    }
}

// MARK: - The selection store

enum RuntimeSelectionStore {
    /// Read under the selection lock. A corrupt file is quarantined (kept as
    /// selected.json.corrupt-<time>) and replaced by an empty state; the
    /// caller learns about it through `corrupted` so AgentMail can be held
    /// (its hold may have been in the lost file).
    static func load() throws -> (file: RuntimeSelectionFile, corrupted: Bool) {
        do {
            return (try RuntimeFS.readJSON(RuntimeSelectionFile.self, RuntimePaths.selectionFile) ?? RuntimeSelectionFile(), false)
        } catch {
            // Review R2: the lost file may have held AgentMail's hold, and the
            // component that reads first may not be AgentMail. So the
            // replacement written here, in place, already carries the hold:
            // whichever component saves next keeps it. Order: copy the bad
            // bytes aside, then atomically replace the file (a crash between
            // leaves the corrupt file in place → quarantined again).
            let stamp = Int(Date().timeIntervalSince1970)
            let q = RuntimePaths.runtimeRoot.appendingPathComponent("selected.json.corrupt-\(stamp)")
            // Bytes that cannot even be read (or a non-regular entry) stay in
            // place and every reader refuses: removing the only evidence before
            // a hold is durable would let a restart see "no state" (round 2).
            guard RuntimeFS.kind(RuntimePaths.selectionFile.path) == .regular,
                  let bad = try? Data(contentsOf: RuntimePaths.selectionFile) else {
                throw RuntimeError("selected.json is unreadable and is left in place (\(error)); fix or remove it by hand, then run `briglia agentmail repair`")
            }
            try RuntimeFS.write(bad, to: q, mode: 0o600)
            try PrivateStorage.fsyncDirectory(RuntimePaths.runtimeRoot.path)
            RuntimeSeams.crash(.agentmail, "after-selection-copy")
            var fresh = RuntimeSelectionFile()
            // Any in-flight transaction's generation snapshot no longer matches.
            fresh.generation = stamp
            if let pin = AgentMailService.runtimePin, agentMailHasPrivateTrace() {
                fresh[.agentmail].hold = RuntimeHold(pin: pin, reason: "unknown", since: Date(), attemptId: nil)
            }
            try save(fresh)
            RuntimeSeams.crash(.agentmail, "after-selection-quarantine")
            return (fresh, true)
        }
    }

    /// Anything of Briglia's private AgentMail on disk (a hold only matters then).
    private static func agentMailHasPrivateTrace() -> Bool {
        [RuntimePaths.receipt(.agentmail), RuntimePaths.current(.agentmail), RuntimePaths.versions(.agentmail), RuntimePaths.journal(.agentmail)]
            .contains { RuntimeFS.kind($0.path) != .absent }
    }

    static func save(_ file: RuntimeSelectionFile) throws {
        try RuntimeFS.writeJSON(file, RuntimePaths.selectionFile)
    }

    /// Read-modify-write under the selection lock (taken here unless held).
    @discardableResult
    static func update(holding: Bool = false, _ body: (inout RuntimeSelectionFile) throws -> Void) throws -> RuntimeSelectionFile {
        let lock = holding ? nil : try RuntimeLock.acquire(RuntimePaths.selectionLock)
        defer { lock?.release() }
        var (file, _) = try load()
        try body(&file)
        try save(file)
        return file
    }

    /// Lock-free read for status (never mutates; corrupt → nil).
    static func peek() -> RuntimeSelectionFile? {
        try? RuntimeFS.readJSON(RuntimeSelectionFile.self, RuntimePaths.selectionFile) ?? RuntimeSelectionFile()
    }

    /// /deleteuserdata, Mind import and a provider change bump it (§7.8.1 step 10).
    static func bumpGeneration() {
        // No runtime state yet → nothing in flight to invalidate (and no
        // files created just for a counter).
        guard RuntimeFS.kind(RuntimePaths.runtimeRoot.path) == .directory else { return }
        _ = try? update { $0.generation += 1 }
    }
}

// MARK: - Test seams (development builds only)

enum RuntimeSeams {
    static var isDev: Bool { adaCLIVersion.hasSuffix("-dev") }
    /// `BRIGLIA_RUNTIME_CRASH=<component>:<point>` SIGKILLs this process at
    /// the named point (crash-recovery selftests).
    static func crash(_ c: RuntimeComponent, _ point: String) {
        guard isDev, let spec = ProcessInfo.processInfo.environment["BRIGLIA_RUNTIME_CRASH"],
              spec == "\(c.rawValue):\(point)" else { return }
        kill(getpid(), SIGKILL)
        while true { sleep(10) }
    }
    static func env(_ key: String) -> String? {
        guard isDev else { return nil }
        let v = ProcessInfo.processInfo.environment[key]
        return (v?.isEmpty == false) ? v : nil
    }
}
