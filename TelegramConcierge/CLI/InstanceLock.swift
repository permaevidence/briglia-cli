import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Exclusive per-user lease for conversation-owning modes (`briglia` chat,
/// `briglia daemon`) and for `briglia quicksetup` while it writes
/// configuration. Two conversation owners would long-poll the same Telegram
/// bot (Telegram splits updates randomly between competing pollers) and race
/// on the same conversation, archive and reminder files — so the second one
/// must refuse to start instead of silently corrupting shared state.
///
/// Uses flock(2): advisory, and released automatically when the process dies
/// for any reason, so a crash can never leave a stale lock behind. `briglia
/// setup` / `briglia doctor` deliberately do NOT take the lease — they must
/// work while a daemon is running.
///
/// The lease is an OBJECT with explicit ownership (Codex, quick-setup plan
/// round 2): a second `flock` on a fresh descriptor blocks even inside the
/// same process, so "the chat re-acquires what quick setup already holds"
/// cannot work — quick setup hands its lease object to `TerminalSession`
/// instead (`adopting:`), and every owner releases explicitly. Dropping a
/// held lease is a bug; the `deinit` fallback releases FIRST (so a debug trap
/// can never strand the lock), then logs, then asserts.
final class InstanceLease {
    struct LeaseError: Error, CustomStringConvertible, LocalizedError {
        let description: String
        var errorDescription: String? { description }
        init(_ description: String) { self.description = description }
    }

    private static let lock = NSLock()
    /// Whether some lease object in this process currently holds the flock.
    /// A second `acquire()` while one is held fails without touching the
    /// file: relying on the kernel to serialize two descriptors of the same
    /// process is exactly the trap the object exists to avoid.
    private static var heldInProcess = false
    /// Read-only: does this process hold the instance lease (private-runtime
    /// staging cleanup, security plan §7.8.1 step 3)?
    static var isHeldInThisProcess: Bool { lock.lock(); defer { lock.unlock() }; return heldInProcess }

    /// Selftest seam: observe the unexpected-drop fallback without scraping
    /// stderr. Called after the release, in the order the plan pins.
    nonisolated(unsafe) static var onUnexpectedDrop: ((String) -> Void)?
    /// Selftest seam: the debug assertion would trap the test process.
    nonisolated(unsafe) static var assertOnUnexpectedDrop = true

    private var fd: Int32
    private(set) var held: Bool
    /// Where the lease came from, for the drop log line.
    let label: String

    static var lockURL: URL { StoragePaths.dataRoot.appendingPathComponent("instance.lock") }

    private init(fd: Int32, label: String) {
        self.fd = fd
        self.held = true
        self.label = label
    }

    /// Try to take the exclusive lease. `.failure` carries a human-readable
    /// reason when another instance (or another lease object in this
    /// process) already holds it.
    static func acquire(label: String = "instance") -> Result<InstanceLease, LeaseError> {
        lock.lock()
        defer { lock.unlock() }
        if heldInProcess {
            return .failure(LeaseError("this process already holds the Briglia instance lease (\(label)) — release it before acquiring again"))
        }
        let url = lockURL
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            return .failure(LeaseError("cannot open \(url.path): \(String(cString: strerror(errno)))"))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            // Best-effort: report the holder's pid recorded at acquire time.
            var holder = ""
            var buf = [UInt8](repeating: 0, count: 32)
            let n = pread(fd, &buf, buf.count, 0)
            if n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) {
                let pid = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pid.isEmpty { holder = " (pid \(pid))" }
            }
            close(fd)
            return .failure(LeaseError("another Briglia instance\(holder) is already running — `briglia` chat and "
                + "`briglia daemon` share one conversation and one Telegram poller, so only "
                + "one can be active. Quit the other instance first."))
        }
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        // Close-on-exec, for two reasons: child processes (background bash,
        // language servers) must not inherit the fd — a lingering child would
        // keep the lock held after we exit and block the next `briglia` — and the
        // /upgrade self-restart re-execs in place, where the inherited lock
        // would deadlock the new image against its own predecessor.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        heldInProcess = true
        return .success(InstanceLease(fd: fd, label: label))
    }

    /// Release the lease. Idempotent: a second call logs and does nothing.
    func release() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard held else {
            FileHandle.standardError.write(Data("[InstanceLease] release() called twice (\(label))\n".utf8))
            return
        }
        held = false
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
        Self.heldInProcess = false
    }

    deinit {
        // Order is the contract: release, THEN log, THEN assert. A debug
        // trap before the release would strand the lock until exit.
        if held {
            release()
            let line = "[InstanceLease] lease dropped without release (\(label)) — released by the fallback; this is a bug"
            FileHandle.standardError.write(Data((line + "\n").utf8))
            Self.onUnexpectedDrop?(label)
            if Self.assertOnUnexpectedDrop { assertionFailure(line) }
        }
    }
}
