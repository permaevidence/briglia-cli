import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Whether multi-assistant coordination (member leases, the upgrade barrier,
/// registry transactions) runs in this process (MULTI_ASSISTANT_PLAN §4.4).
///
/// Stage 2 ships hidden like stage 1: coordination is active only while the
/// experimental switch is on, or once a registry exists (which only an
/// experimental `profiles add` can create). A never-multi install without the
/// switch therefore behaves exactly as today: no lease, no barrier, the old
/// `/upgrade` path.
enum CoordinationMode {
    /// Evaluated once, after the profile bootstrap (it reads only XDG paths).
    static let active: Bool = AssistantProfile.experimentalEnabled || AssistantRegistry.presence() != .absent

    /// The registry exists (an unreadable one counts as existing: fail closed).
    static var multi: Bool { AssistantRegistry.presence() != .absent }
}

/// Identity of a process, used to validate a recorded PID before signalling
/// it (plan §4.3 `profiles stop`) and to tell an old lease from a new one.
enum ProcessIdentity {
    /// An opaque start-time string for `pid` (nil when it cannot be read).
    static func startTime(_ pid: pid_t) -> String? {
        #if os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...].split(separator: " ")
        // Field 22 (starttime) is the 20th after the command's ")".
        guard fields.count > 19 else { return nil }
        return "lx:" + fields[19]
        #else
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_starttime
        return "mac:\(t.tv_sec).\(t.tv_usec)"
        #endif
    }

    /// The resolved executable path of `pid` (nil when unknown).
    static func executable(_ pid: pid_t) -> String? {
        #if os(Linux)
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe"))
        #else
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
        #endif
    }

    static var selfStartTime: String { startTime(getpid()) ?? "unknown" }
}

/// One member lease (plan §4.4): every `briglia` process that uses a profile
/// (except the exempt list of §6.1) holds one for its whole life.
///
/// - default → `<default data root>/machine/members/<uuid>.lock`;
///   extra `<n>` → `briglia-shared/members/<n>/<generation>/<uuid>.lock`.
/// - The lock file is opened once (O_CLOEXEC), held with a non-blocking
///   `flock`, and never unlinked while held. Creation re-checks after the
///   flock that the path still names the locked inode (a sweeper may have
///   unlinked it between open and flock), retrying with a new uuid.
/// - A sidecar `<uuid>.json` (atomic) says who holds it.
final class MemberLease: @unchecked Sendable {
    struct Sidecar: Codable, Equatable {
        var role: String          // "assistant" | "session"
        var coordinator: Bool
        var recovery: Bool
        var pid: Int32
        var processStartTime: String
        var incarnation: String
        var releaseSequence: Int
        var sessionKind: String
        var profile: String
        var executable: String
    }

    let uuid: String
    let directory: URL
    var lockURL: URL { directory.appendingPathComponent("\(uuid).lock") }
    var sidecarURL: URL { directory.appendingPathComponent("\(uuid).json") }
    private var fd: Int32
    private let mutex = NSLock()
    private(set) var sidecar: Sidecar

    private init(uuid: String, directory: URL, fd: Int32, sidecar: Sidecar) {
        self.uuid = uuid; self.directory = directory; self.fd = fd; self.sidecar = sidecar
    }

    var held: Bool { mutex.lock(); defer { mutex.unlock() }; return fd >= 0 }

    struct LeaseError: Error, CustomStringConvertible { let description: String }

    /// Create and lock a lease in `directory`, then write its sidecar.
    static func create(in directory: URL, role: String, sessionKind: String, profile: String) throws -> MemberLease {
        try PrivateStorage.ensureDirectory(directory, mode: 0o700)
        for _ in 0..<8 {
            let uuid = UUID().uuidString.lowercased()
            let url = directory.appendingPathComponent("\(uuid).lock")
            let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw LeaseError(description: "cannot create the member lease in \(directory.path): \(String(cString: strerror(errno)))")
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); continue }
            var held = stat(), named = stat()
            guard fstat(fd, &held) == 0, stat(url.path, &named) == 0,
                  held.st_ino == named.st_ino, held.st_dev == named.st_dev else {
                // Swept between open and flock: never publish it.
                close(fd); continue
            }
            let sidecar = Sidecar(role: role, coordinator: false, recovery: false, pid: getpid(),
                                  processStartTime: ProcessIdentity.selfStartTime,
                                  incarnation: UUID().uuidString.lowercased(),
                                  releaseSequence: adaCLIReleaseSequence, sessionKind: sessionKind,
                                  profile: profile,
                                  executable: (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path)
            let lease = MemberLease(uuid: uuid, directory: directory, fd: fd, sidecar: sidecar)
            do { try lease.writeSidecar() } catch {
                lease.release()
                throw LeaseError(description: "cannot write the member lease record: \(error)")
            }
            return lease
        }
        throw LeaseError(description: "cannot create the member lease in \(directory.path) (retries exhausted)")
    }

    func writeSidecar() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        _ = try PrivateStorage.writeAtomically(try encoder.encode(sidecar), to: sidecarURL, mode: 0o600)
    }

    /// Change attributes while the lease stays held (no admission gap).
    func update(_ change: (inout Sidecar) -> Void) throws {
        mutex.lock(); change(&sidecar); mutex.unlock()
        try writeSidecar()
    }

    /// Release at exit: unlock first, then remove the files (a held lease is
    /// never unlinked).
    func release() {
        mutex.lock()
        let had = fd >= 0
        if had { flock(fd, LOCK_UN); close(fd); fd = -1 }
        mutex.unlock()
        if had {
            unlink(lockURL.path)
            unlink(sidecarURL.path)
        }
    }

    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}

/// Reading and sweeping a directory of member leases (plan §4.4).
enum MemberLeases {
    struct Entry: Equatable {
        var uuid: String
        var probe: ProfileFileLock.Probe
        var sidecar: MemberLease.Sidecar?
        var isAssistant: Bool { sidecar?.role == "assistant" }
    }

    /// Default's leases.
    static func defaultDirectory() -> URL {
        MachinePaths.machineDir().appendingPathComponent("members", isDirectory: true)
    }

    /// An extra's leases for one generation (outside every removable root).
    static func extraDirectory(_ name: String, generation: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        MachinePaths.sharedRoot(environment).appendingPathComponent("members", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(generation, isDirectory: true)
    }

    static func directory(profile: String, generation: String?) -> URL? {
        if profile == AssistantProfile.defaultName { return defaultDirectory() }
        guard let generation else { return nil }
        return extraDirectory(profile, generation: generation)
    }

    static func readSidecar(_ url: URL) -> MemberLease.Sidecar? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 64 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MemberLease.Sidecar.self, from: data)
    }

    /// Every lease in `directory` with its probe. A live lease whose sidecar
    /// is missing or unreadable counts as `unknown`, never as absent.
    static func list(_ directory: URL) -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [Entry] = []
        for name in names where name.hasSuffix(".lock") {
            let uuid = String(name.dropLast(5))
            let url = directory.appendingPathComponent(name)
            var probe = ProfileFileLock.probe(url)
            let sidecar = readSidecar(directory.appendingPathComponent("\(uuid).json"))
            if probe == .live, sidecar == nil { probe = .unknown }
            out.append(Entry(uuid: uuid, probe: probe, sidecar: sidecar))
        }
        return out.sorted { $0.uuid < $1.uuid }
    }

    /// Live or unknown entries, optionally only assistants, excluding `except`.
    static func users(_ directory: URL, assistantsOnly: Bool = false, except: String? = nil) -> [Entry] {
        list(directory).filter { e in
            e.uuid != except && e.probe != .dead && (!assistantsOnly || e.probe == .unknown || e.isAssistant)
        }
    }

    /// Remove leftovers whose lock is free, only while holding their flock.
    @discardableResult
    static func sweep(_ directory: URL) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where name.hasSuffix(".lock") {
            let url = directory.appendingPathComponent(name)
            let fd = open(url.path, O_RDWR | O_CLOEXEC)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                unlink(directory.appendingPathComponent(String(name.dropLast(5)) + ".json").path)
                unlink(url.path)
                removed += 1
                flock(fd, LOCK_UN)
            }
            close(fd)
        }
        // Sidecars without a lock file belong to nobody.
        for name in names where name.hasSuffix(".json") {
            let lock = directory.appendingPathComponent(String(name.dropLast(5)) + ".lock")
            if !FileManager.default.fileExists(atPath: lock.path) {
                unlink(directory.appendingPathComponent(name).path)
            }
        }
        return removed
    }
}
