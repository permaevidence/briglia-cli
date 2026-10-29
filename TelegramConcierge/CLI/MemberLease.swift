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
    /// Evaluated on every use (an lstat): a registry created while this
    /// process runs switches coordination on for it too (Codex stage-2 R1).
    static var active: Bool { AssistantProfile.experimentalEnabled || AssistantRegistry.presence() != .absent }

    /// The registry exists (an unreadable one counts as existing: fail closed).
    static var multi: Bool { AssistantRegistry.presence() != .absent }
}

/// Exclusion against a Briglia that runs WITHOUT a member lease (Codex
/// stage-2 R1): one started before the first registry existed, with the
/// experimental switch off. Its instance lock is held but no assistant lease
/// of its profile is live. First `profiles add` and the upgrade barrier
/// refuse while one exists; the user stops (or restarts) it first.
enum UnleasedInstances {
    enum LockProbe: Equatable {
        /// No lock file, or our non-blocking exclusive probe succeeded.
        case free
        /// Another process holds it.
        case held
        /// It exists but cannot be examined (open or flock error): never
        /// treated as "nobody runs" (Codex stage-2 G1).
        case unknown(String)
    }

    /// Probe `instance.lock` in `dataRoot` without creating it. Opened
    /// read-only (flock does not need write access); only ENOENT means absent.
    static func probe(_ dataRoot: URL) -> LockProbe {
        let path = dataRoot.appendingPathComponent("instance.lock").path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            return err == ENOENT ? .free : .unknown("\(path): \(String(cString: strerror(err)))")
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return .free }
        let err = errno
        return err == EWOULDBLOCK ? .held : .unknown("\(path): \(String(cString: strerror(err)))")
    }

    /// Held by another process, or impossible to examine (fail closed).
    static func instanceHeld(_ dataRoot: URL) -> Bool { probe(dataRoot) != .free }

    /// The pid the current holder wrote into `instance.lock` (InstanceLease
    /// writes it right after taking the flock). nil when unreadable.
    static func holderPid(_ dataRoot: URL) -> pid_t? {
        let path = dataRoot.appendingPathComponent("instance.lock").path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 32)
        let n = pread(fd, &buf, buf.count, 0)
        guard n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    /// Codex stage-2 F1: a held instance lock is coordinated only when ITS
    /// holder (the pid in the lock file, same process start time) holds a live
    /// assistant lease of that profile. Another process's lease (a second
    /// starter still before its instance lock) never certifies the owner.
    /// An unreadable holder pid or a lease without a sidecar fails closed.
    static func unleased(dataRoot: URL, leases: URL) -> Bool {
        switch probe(dataRoot) {
        case .free: return false
        case .unknown: return true
        case .held: break
        }
        guard let pid = holderPid(dataRoot), let start = ProcessIdentity.startTime(pid) else { return true }
        let owned = MemberLeases.users(leases, assistantsOnly: true).contains { e in
            guard e.probe == .live, let s = e.sidecar, s.role == "assistant" else { return false }
            return s.pid == pid && s.processStartTime == start
        }
        // Stage 4 (§28.3): the holder is THIS process — the standalone menu,
        // which took the instance lock and entered the protocol with its own
        // member lease of this profile (a session that refuses and closes on
        // a barrier). It is coordinated; only another process can be stray.
        if !owned, pid == getpid(), let mine = MemberEntry.current,
           mine.directory.standardizedFileURL.path == leases.standardizedFileURL.path {
            return false
        }
        return !owned
    }

    /// One profile that blocks coordination: a Briglia runs without a lease,
    /// or its instance lock cannot be examined (Codex stage-2 round-4 note:
    /// the second case names the path and the error instead of claiming
    /// that something runs).
    struct Finding: Equatable {
        enum Kind: Equatable { case unleased; case uncheckable(String) }
        var profile: String
        var kind: Kind
    }

    static func finding(profile: String, dataRoot: URL, leases: URL) -> Finding? {
        if case .unknown(let why) = probe(dataRoot) { return Finding(profile: profile, kind: .uncheckable(why)) }
        return unleased(dataRoot: dataRoot, leases: leases) ? Finding(profile: profile, kind: .unleased) : nil
    }

    /// The profiles (default + registered extras) that block coordination.
    /// A non-empty answer is re-checked once after a short pause: a holder
    /// that has just taken the flock may not have written its pid yet.
    static func findings(registryPaths: AssistantRegistry.Paths = .live,
                         defaultData: URL = MachinePaths.defaultDataRoot(),
                         defaultLeases: URL = MemberLeases.defaultDirectory(),
                         extraData: (String) -> URL = { AssistantProfile.extraDataRoot($0) }) -> [Finding] {
        func scan() -> [Finding] {
            var out: [Finding] = []
            if let f = finding(profile: AssistantProfile.defaultName, dataRoot: defaultData, leases: defaultLeases) { out.append(f) }
            if let doc = (try? AssistantRegistry.read(registryPaths)) ?? nil {
                for r in doc.records where r.name != AssistantProfile.defaultName {
                    let dir = registryPaths.root.appendingPathComponent("members/\(r.name)/\(r.generation)", isDirectory: true)
                    if let f = finding(profile: r.name, dataRoot: extraData(r.name), leases: dir) { out.append(f) }
                }
            }
            return out
        }
        let first = scan()
        if first.isEmpty { return first }
        Thread.sleep(forTimeInterval: 0.3)
        return scan()
    }

    static func find(registryPaths: AssistantRegistry.Paths = .live,
                     defaultData: URL = MachinePaths.defaultDataRoot(),
                     defaultLeases: URL = MemberLeases.defaultDirectory(),
                     extraData: (String) -> URL = { AssistantProfile.extraDataRoot($0) }) -> [String] {
        findings(registryPaths: registryPaths, defaultData: defaultData, defaultLeases: defaultLeases, extraData: extraData).map(\.profile)
    }

    /// The refusal text for a non-empty `findings` answer.
    static func describe(_ findings: [Finding]) -> String {
        let running = findings.filter { $0.kind == .unleased }.map(\.profile)
        var parts: [String] = []
        if !running.isEmpty { parts.append(message + " (" + running.joined(separator: ", ") + ")") }
        for f in findings {
            if case .uncheckable(let why) = f.kind {
                parts.append("The instance lock of ‘\(f.profile)’ could not be checked (\(why)), so Briglia cannot tell whether that assistant is running. Make the file readable and writable by you (chmod 600 on it), then try again.")
            }
        }
        return parts.joined(separator: " ")
    }

    static let message = "A Briglia started before assistants were set up is still running without coordination. Stop it (Ctrl-C, or `briglia service uninstall` on Linux), or restart it with BRIGLIA_EXPERIMENTAL_PROFILES=1, then try again. (If no Briglia is running, its instance.lock could not be checked: make it readable by you, e.g. `chmod 600 <data folder>/instance.lock`.)"
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
                                  releaseSequence: ReleaseSequence.compiled, sessionKind: sessionKind,
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
