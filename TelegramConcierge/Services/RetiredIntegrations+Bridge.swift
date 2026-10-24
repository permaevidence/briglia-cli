import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Plan v2 §2.3 steps 2–3: stop any WhatsApp bridge that is still running,
/// then remove exactly `<dataRoot>/whatsapp-bridge` without following links.

enum BridgeOutcome: Equatable {
    case clear
    /// The table or a same-user process could not be read, or a bridge is
    /// still alive after SIGKILL: the folder step waits for a later start.
    case unknown(String)

    var detail: String {
        switch self {
        case .clear: return "none running"
        case .unknown(let why): return why
        }
    }
}

enum FolderOutcome: Equatable {
    case removed(linkOnly: Bool)
    case absent
    case deferred(String)
    case failed(String)
}

/// Spawn-free bridge finder (plan v3 §2.3 step 2). A candidate is a live,
/// non-zombie process of this uid, not this process, in one of the two
/// invocation shapes the old launch produced — `node <script>` (the
/// `__setsid-exec` trampoline execs in place) or the posix_spawn fallback
/// shim `<briglia> __setsid-exec -- <node> <script>` — whose script resolves
/// to THIS install's bridge `index.js`. A reader (`tail`, an editor) or any
/// other Node program carrying the path is never a candidate; Ada.app's and
/// LocalAgent's bridges resolve elsewhere. Accident safety, not an
/// authentication boundary.
struct BridgeScanner {
    struct Proc: Equatable {
        var pid: Int32
        var ppid: Int32
        var uid: uid_t
        var zombie: Bool
        /// nil = could not be read.
        var argv: [String]?
    }

    var table: () -> [Proc]?
    var signal: (Int32, Int32) -> Void
    var reap: (Int32) -> Void
    var sleep: (TimeInterval) -> Void
    /// realpath(3); nil when the path cannot be resolved.
    var resolve: (String) -> String?
    var uid: uid_t
    var selfPid: Int32
    var termWait: TimeInterval = 3
    var killWait: TimeInterval = 1

    static var live: BridgeScanner {
        BridgeScanner(table: { BridgeScanner.liveTable() },
                      signal: { pid, sig in _ = kill(pid, sig) },
                      reap: { pid in var status: Int32 = 0; _ = waitpid(pid, &status, WNOHANG) },
                      sleep: { Thread.sleep(forTimeInterval: $0) },
                      resolve: { path in
                          guard let p = realpath(path, nil) else { return nil }
                          defer { free(p) }
                          return String(cString: p)
                      },
                      uid: getuid(), selfPid: getpid())
    }

    /// The paths this install's bridge may have been launched with.
    struct Target {
        /// `<dataRoot>/whatsapp-bridge/index.js` as StoragePaths builds it.
        var configured: String
        /// The same with every symlink resolved (nil when unresolvable).
        var canonical: String?
    }

    static let nodeNames: Set<String> = ["node", "nodejs"]

    /// The script argument of a bridge-shaped invocation, or nil.
    static func scriptArgument(_ argv: [String]) -> String? {
        func isNode(_ s: String) -> Bool { nodeNames.contains((s as NSString).lastPathComponent) }
        if argv.count == 2, isNode(argv[0]) { return argv[1] }
        if argv.count == 5, argv[1] == "__setsid-exec", argv[2] == "--", isNode(argv[3]) { return argv[4] }
        return nil
    }

    enum Identity { case ours, notOurs, undetermined }

    func identity(of script: String, target: Target) -> Identity {
        if let real = resolve(script), let canonical = target.canonical {
            return real == canonical ? .ours : .notOurs
        }
        if script == target.configured || script == target.canonical { return .ours }
        return script.hasSuffix("/whatsapp-bridge/index.js") ? .undetermined : .notOurs
    }

    private enum Scan { case unreadable(String), found([Proc]) }

    private func scan(_ target: Target) -> Scan {
        guard let rows = table() else { return .unreadable("the process table could not be read") }
        var found: [Proc] = []
        for p in rows where p.uid == uid && p.pid != selfPid && !p.zombie {
            guard let argv = p.argv else {
                return .unreadable("the arguments of process \(p.pid) could not be read")
            }
            guard let script = Self.scriptArgument(argv) else { continue }
            switch identity(of: script, target: target) {
            case .ours: found.append(p)
            case .notOurs: continue
            case .undetermined: return .unreadable("process \(p.pid) runs a WhatsApp bridge whose path cannot be verified")
            }
        }
        return .found(found)
    }

    func stopBridges(target: Target) -> BridgeOutcome {
        let first = scan(target)
        guard case .found(let initial) = first else {
            if case .unreadable(let why) = first { return .unknown(why) }
            return .unknown("the process table could not be read")
        }
        if initial.isEmpty { return .clear }
        // Every single signal goes to a pid the table was JUST re-read for
        // and that is still a bridge invocation of this install (a shim's
        // exit can retire its child mid-batch; a pid can be reused).
        if let why = signalEach(initial, SIGTERM, target) { return .unknown(why) }
        if waitGone(target, within: termWait) { return finish(target, initial) }
        if let why = signalEach(initial, SIGKILL, target) { return .unknown(why) }
        _ = waitGone(target, within: killWait)
        return finish(target, initial)
    }

    /// Signals each pid of `candidates` after a fresh scan confirms it is
    /// still a bridge invocation of this install; returns a reason when the
    /// table or a same-user process cannot be read (nothing more is sent).
    private func signalEach(_ candidates: [Proc], _ sig: Int32, _ target: Target) -> String? {
        for p in candidates {
            switch scan(target) {
            case .unreadable(let why): return why
            case .found(let now):
                if now.contains(where: { $0.pid == p.pid }) { signal(p.pid, sig) }
            }
        }
        return nil
    }

    private func waitGone(_ target: Target, within seconds: TimeInterval) -> Bool {
        var waited: TimeInterval = 0
        while waited < seconds {
            if case .found(let left) = scan(target), left.isEmpty { return true }
            sleep(0.1); waited += 0.1
        }
        if case .found(let left) = scan(target), left.isEmpty { return true }
        return false
    }

    private func finish(_ target: Target, _ initial: [Proc]) -> BridgeOutcome {
        // Our own former children would stay zombies: collect them.
        for p in initial where p.ppid == selfPid { reap(p.pid) }
        switch scan(target) {
        case .unreadable(let why): return .unknown(why)
        case .found(let left):
            return left.isEmpty ? .clear
                : .unknown("WhatsApp bridge process \(left.map { String($0.pid) }.joined(separator: ", ")) is still running")
        }
    }

    // MARK: Live table

    static func liveTable() -> [Proc]? {
        #if os(Linux)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
        var out: [Proc] = []
        for name in names {
            guard let pid = Int32(name) else { continue }
            var st = stat()
            guard stat("/proc/\(name)", &st) == 0 else { continue }   // exited meanwhile
            guard let statLine = try? String(contentsOfFile: "/proc/\(name)/stat", encoding: .utf8),
                  let close = statLine.range(of: ")", options: .backwards) else { continue }
            let fields = statLine[close.upperBound...].split(separator: " ")
            guard fields.count > 2, let ppid = Int32(fields[1]) else { continue }
            let zombie = fields[0] == "Z" || fields[0] == "X"
            var argv: [String]? = nil
            if let data = FileManager.default.contents(atPath: "/proc/\(name)/cmdline") {
                argv = data.split(separator: 0, omittingEmptySubsequences: false)
                    .map { String(decoding: $0, as: UTF8.self) }
                if argv?.last == "" { argv?.removeLast() }
            } else if kill(pid, 0) != 0 && errno == ESRCH {
                continue
            }
            out.append(Proc(pid: pid, ppid: ppid, uid: st.st_uid, zombie: zombie, argv: argv))
        }
        return out
        #else
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        var actual = buffer.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &buffer, &actual, nil, 0) == 0 else { return nil }
        let count = actual / MemoryLayout<kinfo_proc>.stride
        var out: [Proc] = []
        for proc in buffer.prefix(count) {
            let pid = proc.kp_proc.p_pid
            let zombie = Int32(proc.kp_proc.p_stat) == SZOMB
            var argv: [String]? = zombie ? [] : darwinArgv(pid)
            if argv == nil && kill(pid, 0) != 0 && errno == ESRCH { continue }
            if zombie { argv = [] }
            out.append(Proc(pid: pid, ppid: proc.kp_eproc.e_ppid, uid: proc.kp_eproc.e_ucred.cr_uid,
                            zombie: zombie, argv: argv))
        }
        return out
        #endif
    }

    #if !os(Linux)
    /// KERN_PROCARGS2: int argc, the exec path, NUL padding, then argv.
    static func darwinArgv(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && data[i] != 0 { i += 1 }          // exec path
        while i < size && data[i] == 0 { i += 1 }          // padding
        var argv: [String] = []
        while argv.count < Int(argc) && i < size {
            var j = i
            while j < size && data[j] != 0 { j += 1 }
            argv.append(String(decoding: data[i..<j], as: UTF8.self))
            i = j + 1
        }
        return argv
    }
    #endif
}

/// Descriptor-based remover for one name under the checked data root
/// (plan v3 §2.3 step 3): never follows a symlink, never enters a mount
/// (different device, or a same-device mount found by the boundary check),
/// refuses special files, bounded; only ENOENT counts as absence.
enum BridgeFolderRemover {
    static let maxDepth = 64
    /// Mutable for the selftest's bound case only.
    nonisolated(unsafe) static var maxEntries = 200_000

    enum TopKind: String, Codable { case link, dir }

    struct Failure: Error { let message: String }

    /// Mount boundary for one canonical directory path.
    enum Boundary { case none, mounted(String), undetermined(String) }

    struct Seams {
        /// Linux: canonical mount points from /proc/self/mountinfo (nil =
        /// unreadable). Unused on macOS.
        var mountPoints: () -> [String]?
        /// macOS: (fsid, mount-on path) of an open directory (nil = failure).
        var fsIdentity: (Int32) -> String?
        /// Test seam: a different device for a relative path.
        var deviceOverride: (String) -> dev_t?
        /// Test seam: called after each directory is opened (swap tests).
        var afterOpen: (String) -> Void

        static var live: Seams {
            Seams(mountPoints: { BridgeFolderRemover.liveMountPoints() },
                  fsIdentity: { BridgeFolderRemover.liveFSIdentity($0) },
                  deviceOverride: { _ in nil },
                  afterOpen: { _ in })
        }
    }

    /// `willRemove` runs once, with the top-level kind, BEFORE the first
    /// destructive call; returning false (the state write failed) aborts
    /// with nothing removed.
    static func remove(name: String, under root: URL, seams: Seams = .live,
                       willRemove: (TopKind) -> Bool) -> FolderOutcome {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return .failed("cannot open the data root (\(String(cString: strerror(errno))))") }
        defer { close(rootFD) }
        var rootStat = stat()
        guard fstat(rootFD, &rootStat) == 0 else { return .failed("cannot stat the data root") }
        var st = stat()
        if fstatat(rootFD, name, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            return errno == ENOENT ? .absent : .failed("cannot inspect \(name) (\(String(cString: strerror(errno))))")
        }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            guard willRemove(.link) else { return .failed("could not record the removal first; nothing removed") }
            guard unlinkat(rootFD, name, 0) == 0 || errno == ENOENT else {
                return .failed("cannot remove the link \(name) (\(String(cString: strerror(errno))))")
            }
            _ = fsync(rootFD)
            return .removed(linkOnly: true)
        case S_IFDIR:
            // Same-device mounts (Linux bind mounts) are found by path before
            // anything is entered; macOS compares each directory's file system.
            #if os(Linux)
            guard let mounts = seams.mountPoints() else { return .failed("the mount table could not be read; nothing removed") }
            let canonicalRoot = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path
            let top = canonicalRoot + "/" + name
            if let hit = mounts.first(where: { $0 == top || $0.hasPrefix(top + "/") }) {
                return .failed("\(hit) is a mount point; nothing removed")
            }
            let rootFS: String? = nil
            #else
            guard let rootFS = seams.fsIdentity(rootFD) else { return .failed("cannot identify the data root's file system; nothing removed") }
            #endif
            guard willRemove(.dir) else { return .failed("could not record the removal first; nothing removed") }
            var budget = maxEntries
            do {
                try removeTree(parentFD: rootFD, name: name, rel: name, device: rootStat.st_dev, rootFS: rootFS,
                               seams: seams, depth: 0, budget: &budget)
            } catch let failure as Failure {
                return .failed(failure.message)
            } catch {
                return .failed(error.localizedDescription)
            }
            guard fsync(rootFD) == 0 else { return .failed("cannot sync the data root after removal") }
            return .removed(linkOnly: false)
        default:
            return .failed("\(name) is not a directory or a link; left in place")
        }
    }

    private static func removeTree(parentFD: Int32, name: String, rel: String, device: dev_t, rootFS: String?,
                                   seams: Seams, depth: Int, budget: inout Int) throws {
        guard depth < maxDepth else { throw Failure(message: "deeper than \(maxDepth) levels; stopped") }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return }
            throw Failure(message: "cannot open \(rel) without following links (\(String(cString: strerror(errno))))")
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd); throw Failure(message: "\(rel) is not a directory")
        }
        let dev = seams.deviceOverride(rel) ?? st.st_dev
        guard dev == device else { close(fd); throw Failure(message: "\(rel) is on another file system (mount); left in place") }
        if let rootFS {
            guard let fs = seams.fsIdentity(fd) else { close(fd); throw Failure(message: "cannot identify the file system of \(rel); stopped") }
            guard fs == rootFS else { close(fd); throw Failure(message: "\(rel) is a mount point; left in place") }
        }
        seams.afterOpen(rel)
        let dupFD = dup(fd)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else {
            if dupFD >= 0 { close(dupFD) }
            close(fd); throw Failure(message: "cannot list \(rel)")
        }
        var names: [String] = []
        while let entry = readdir(dir) {
            let child = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            if child == "." || child == ".." { continue }
            budget -= 1
            if budget < 0 { closedir(dir); close(fd); throw Failure(message: "more than \(maxEntries) entries; stopped (retried at the next start)") }
            names.append(child)
        }
        closedir(dir)
        defer { close(fd) }
        for child in names {
            var cst = stat()
            if fstatat(fd, child, &cst, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw Failure(message: "cannot inspect \(rel)/\(child)")
            }
            switch cst.st_mode & S_IFMT {
            case S_IFDIR:
                try removeTree(parentFD: fd, name: child, rel: rel + "/" + child, device: device, rootFS: rootFS,
                               seams: seams, depth: depth + 1, budget: &budget)
            case S_IFREG, S_IFLNK:
                guard unlinkat(fd, child, 0) == 0 || errno == ENOENT else {
                    throw Failure(message: "cannot remove \(rel)/\(child) (\(String(cString: strerror(errno))))")
                }
            default:
                throw Failure(message: "\(rel)/\(child) is a special file; left in place")
            }
        }
        guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw Failure(message: "cannot remove \(rel) (\(String(cString: strerror(errno))))")
        }
    }

    // MARK: Live mount information

    /// /proc/self/mountinfo field 5 (mount point), octal escapes decoded.
    /// nil (fail closed) when any line is malformed or no mount is listed.
    static func parseMountInfo(_ text: String) -> [String]? {
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count > 4, fields[4].hasPrefix("/") else { return nil }
            out.append(decodeOctalEscapes(String(fields[4])))
        }
        return out.isEmpty ? nil : out
    }

    static func decodeOctalEscapes(_ s: String) -> String {
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "\\"), i + 3 < u.count,
               let v = UInt8(String(decoding: u[(i + 1)...(i + 3)], as: UTF8.self), radix: 8) {
                bytes.append(v); i += 4
            } else {
                bytes.append(u[i]); i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func liveMountPoints() -> [String]? {
        guard let data = FileManager.default.contents(atPath: "/proc/self/mountinfo") else { return nil }
        return parseMountInfo(String(decoding: data, as: UTF8.self))
    }

    static func liveFSIdentity(_ fd: Int32) -> String? {
        #if os(Linux)
        return nil
        #else
        var s = statfs()
        guard fstatfs(fd, &s) == 0 else { return nil }
        guard s.f_mntonname.0 != 0 else { return nil }   // unusable identity: fail closed
        let mnt = withUnsafePointer(to: s.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: s.f_mntonname)) { String(cString: $0) }
        }
        return "\(s.f_fsid.val.0):\(s.f_fsid.val.1):\(mnt)"
        #endif
    }
}
