import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Startup sweep for children inherited across an in-place exec.
///
/// `/restart` and `/upgrade` replace the daemon with `execv`: same PID, new
/// image. Anything the old image spawned and did not fully tear down stays a
/// child of this PID, and the new image holds no `Process` object for it, so
/// nothing would ever signal or reap it. Observed on the owner's Mac after six
/// days of upgrades: eleven Playwright servers (each a `__setsid-exec` shim
/// plus its node process in a private session, one still holding a Chrome
/// tree), about 2.3 GB, plus zombies from an earlier manual cleanup. The old
/// image's pipe descriptors are not close-on-exec either, so those servers
/// never even saw EOF on stdin.
///
/// Contract: called ONCE, at the very top of `TerminalSession.start`, before
/// this image spawns its first child. At that point every live child of
/// getpid() is a leftover by construction and every zombie child is ours to
/// reap. Both invariants stop holding the moment a Foundation `Process`
/// exists (its reaper would race `waitpid(-1)`), hence the ordering — and
/// hence no `pgrep`: the process table is read through sysctl / procfs.
///
/// This is the backstop, not the fix. The fix is that the pre-exec shutdown
/// tears MCP servers down (`TerminalSession.shutdownChildProcesses`); the
/// sweep heals installations that already leaked and covers the one window
/// the shutdown cannot close (an MCP bootstrap still in flight at exec time
/// publishes nothing, but its half-started servers are children of ours).
enum LeftoverChildSweep {

    struct Report: Equatable {
        /// Zombie children collected with `waitpid`.
        var reaped = 0
        /// Live direct children ended (SIGTERM, escalated to SIGKILL as needed).
        var terminated = 0
        /// Of `terminated`, how many needed SIGKILL.
        var killed = 0
        /// Direct children that could not be collected within the budget.
        var unreaped: [Int32] = []
        var isEmpty: Bool { reaped == 0 && terminated == 0 && unreaped.isEmpty }

        var summary: String {
            var parts: [String] = []
            if terminated > 0 {
                parts.append("\(terminated) leftover child process\(terminated == 1 ? "" : "es") from the previous process image ended"
                             + (killed > 0 ? " (\(killed) needed SIGKILL)" : ""))
            }
            if reaped > 0 { parts.append("\(reaped) zombie\(reaped == 1 ? "" : "s") reaped") }
            if !unreaped.isEmpty { parts.append("\(unreaped.count) still not collectable: \(unreaped.map(String.init).joined(separator: ", "))") }
            return parts.joined(separator: "; ")
        }
    }

    struct Entry: Equatable {
        let pid: Int32
        let ppid: Int32
        let pgid: Int32
        let zombie: Bool
    }

    /// Snapshot of every process on the system (pid, parent, group, zombie
    /// state) without spawning anything: sysctl on macOS, /proc on Linux.
    /// nil when the table cannot be read (restricted procfs) — the sweep then
    /// only reaps zombies, which needs no table, and never guesses.
    static func snapshot() -> [Entry]? {
        #if os(Linux)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
        var out: [Entry] = []
        for name in names {
            guard let pid = Int32(name),
                  let stat = try? String(contentsOfFile: "/proc/\(name)/stat", encoding: .utf8),
                  let close = stat.range(of: ")", options: .backwards) else { continue }
            // After the parenthesised comm: state ppid pgrp session …
            let fields = stat[close.upperBound...].split(separator: " ")
            guard fields.count > 3, let ppid = Int32(fields[1]), let pgid = Int32(fields[2]) else { continue }
            out.append(Entry(pid: pid, ppid: ppid, pgid: pgid, zombie: fields[0] == "Z"))
        }
        return out
        #else
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        var actual = buffer.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &buffer, &actual, nil, 0) == 0 else { return nil }
        let count = actual / MemoryLayout<kinfo_proc>.stride
        return buffer.prefix(count).map { proc in
            Entry(pid: proc.kp_proc.p_pid, ppid: proc.kp_eproc.e_ppid, pgid: proc.kp_eproc.e_pgid,
                  zombie: Int32(proc.kp_proc.p_stat) == SZOMB)
        }
        #endif
    }

    /// Live (non-zombie) direct children of `parent` in `table`, plus for
    /// each the full descendant set and the process groups the tree spans
    /// (excluding this process's own group and the system groups).
    static func leftoverTrees(parent: Int32, table: [Entry]) -> [(child: Int32, descendants: [Int32], groups: [Int32])] {
        var byParent: [Int32: [Entry]] = [:]
        for entry in table { byParent[entry.ppid, default: []].append(entry) }
        let ownGroup = getpgid(0)
        return (byParent[parent] ?? []).filter { !$0.zombie }.sorted { $0.pid < $1.pid }.map { child in
            var descendants: [Int32] = []
            var queue = [child.pid]
            var seen: Set<Int32> = [child.pid]
            while !queue.isEmpty {
                let p = queue.removeFirst()
                for kid in byParent[p] ?? [] where !seen.contains(kid.pid) {
                    seen.insert(kid.pid)
                    descendants.append(kid.pid)
                    queue.append(kid.pid)
                }
            }
            var groups = Set<Int32>()
            for entry in [child] + descendants.compactMap({ pid in table.first { $0.pid == pid } }) {
                if entry.pgid > 1 && entry.pgid != ownGroup { groups.insert(entry.pgid) }
            }
            return (child.pid, descendants, Array(groups).sorted())
        }
    }

    /// Reap every zombie child, then end every live direct child (and its
    /// tree) with SIGTERM, a grace period, SIGKILL, and a final collection.
    /// Synchronous by design: it runs before the session has any concurrency
    /// to protect, and the budget is small (grace + one more second).
    @discardableResult
    static func run(graceNanos: UInt64 = 1_000_000_000, log: (String) -> Void = { print($0) }) -> Report {
        var report = Report()
        report.reaped = reapZombies()

        guard let table = snapshot() else {
            if report.reaped > 0 { log("startup: \(report.summary)") }
            return report
        }
        let trees = leftoverTrees(parent: getpid(), table: table)
        guard !trees.isEmpty else {
            if report.reaped > 0 { log("startup: \(report.summary)") }
            return report
        }

        // SIGTERM the groups first (reaches the detached sessions the shims
        // spawned), then every pid individually (reaches anything that moved
        // itself into a fresh group).
        for tree in trees {
            for g in tree.groups { _ = Darwin.kill(-g, SIGTERM) }
            _ = Darwin.kill(tree.child, SIGTERM)
            for pid in tree.descendants { _ = Darwin.kill(pid, SIGTERM) }
        }
        var pending = Set(trees.map(\.child))
        pending = collect(pending, budgetNanos: graceNanos)
        report.terminated = trees.count - pending.count

        if !pending.isEmpty {
            for tree in trees where pending.contains(tree.child) {
                for g in tree.groups where Darwin.kill(-g, 0) == 0 { _ = Darwin.kill(-g, SIGKILL) }
                _ = Darwin.kill(tree.child, SIGKILL)
                for pid in tree.descendants where Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
            }
            let before = pending.count
            pending = collect(pending, budgetNanos: 1_000_000_000)
            report.killed = before - pending.count
            report.terminated += report.killed
            report.unreaped = pending.sorted()
        }
        log("startup: \(report.summary)")
        return report
    }

    // MARK: - Private

    private static func reapZombies() -> Int {
        var reaped = 0
        var status: Int32 = 0
        while true {
            let r = waitpid(-1, &status, WNOHANG)
            if r > 0 { reaped += 1; continue }
            if r == -1 && errno == EINTR { continue }
            return reaped
        }
    }

    /// Poll `waitpid(pid, WNOHANG)` for each pending child until collected or
    /// the budget is spent. A pid that is not our child any more (ECHILD)
    /// counts as collected — it cannot be a zombie of ours.
    private static func collect(_ pending: Set<Int32>, budgetNanos: UInt64) -> Set<Int32> {
        var remaining = pending
        let step: UInt64 = 50_000_000
        var elapsed: UInt64 = 0
        while !remaining.isEmpty {
            for pid in remaining {
                var status: Int32 = 0
                let r = waitpid(pid, &status, WNOHANG)
                if r == pid || (r == -1 && errno == ECHILD) { remaining.remove(pid) }
            }
            if remaining.isEmpty || elapsed >= budgetNanos { break }
            usleep(UInt32(step / 1_000))
            elapsed += step
        }
        return remaining
    }
}
