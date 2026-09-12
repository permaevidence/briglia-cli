import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Startup sweep for children inherited across an in-place exec, plus the
/// spawn-free process-table helpers the MCP shutdown shares with it.
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
/// Contract: `run()` is called ONCE per process image, from
/// `TerminalSession.init(sweepLeftoversAtEntry: true)` BEFORE the
/// conversation manager (and with it any polling, channel or background task)
/// is constructed — i.e. before this image spawns its first child. At that
/// point every live child of getpid() is a leftover by construction and every
/// zombie child is ours to reap. Both invariants stop holding the moment a
/// Foundation `Process` exists (its reaper would race `waitpid(-1)`), hence
/// the ordering — and hence no `pgrep`: the process table is read through
/// sysctl / procfs.
///
/// This is the backstop, not the fix. The fix is that the pre-exec shutdown
/// tears MCP servers down (`TerminalSession.shutdownChildProcesses`); the
/// sweep heals installations that already leaked.
enum LeftoverChildSweep {

    struct Report: Equatable {
        /// Zombie children collected with `waitpid`.
        var reaped = 0
        /// Live direct children ended (SIGTERM, escalated to SIGKILL as needed).
        var terminated = 0
        /// Of `terminated`, how many needed SIGKILL.
        var killed = 0
        /// Descendants (not direct children) that survived SIGTERM and were
        /// ended by SIGKILL — a detached process whose parent obeyed the
        /// first signal (Codex R2).
        var descendantsKilled = 0
        /// Direct children that could not be collected within the budget.
        var unreaped: [Int32] = []
        /// Descendants still alive after SIGKILL and the budget.
        var survivingDescendants: [Int32] = []
        var isEmpty: Bool {
            reaped == 0 && terminated == 0 && descendantsKilled == 0
                && unreaped.isEmpty && survivingDescendants.isEmpty
        }

        var summary: String {
            var parts: [String] = []
            if terminated > 0 {
                parts.append("\(terminated) leftover child process\(terminated == 1 ? "" : "es") from the previous process image ended"
                             + (killed > 0 ? " (\(killed) needed SIGKILL)" : ""))
            }
            if descendantsKilled > 0 {
                parts.append("\(descendantsKilled) detached descendant\(descendantsKilled == 1 ? "" : "s") needed SIGKILL")
            }
            if reaped > 0 { parts.append("\(reaped) zombie\(reaped == 1 ? "" : "s") reaped") }
            if !unreaped.isEmpty { parts.append("\(unreaped.count) still not collectable: \(unreaped.map(String.init).joined(separator: ", "))") }
            if !survivingDescendants.isEmpty {
                parts.append("\(survivingDescendants.count) descendant\(survivingDescendants.count == 1 ? "" : "s") still alive: \(survivingDescendants.map(String.init).joined(separator: ", "))")
            }
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
    /// nil when the table cannot be read (restricted procfs) — callers then
    /// fall back or do nothing, never guess.
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

    /// The live tree under `rootPid` in `table`: every descendant (BFS,
    /// zombies excluded — they are already dead) and the process groups the
    /// root and its descendants span, excluding this process's own group and
    /// the system groups (same guard as `ProcessTree.processGroups`).
    static func tree(rootPid: Int32, table: [Entry]) -> (descendants: [Int32], groups: [Int32]) {
        var byParent: [Int32: [Entry]] = [:]
        var byPid: [Int32: Entry] = [:]
        for entry in table {
            byParent[entry.ppid, default: []].append(entry)
            byPid[entry.pid] = entry
        }
        var descendants: [Int32] = []
        var queue = [rootPid]
        var seen: Set<Int32> = [rootPid]
        while !queue.isEmpty {
            let p = queue.removeFirst()
            for kid in byParent[p] ?? [] where !seen.contains(kid.pid) && !kid.zombie {
                seen.insert(kid.pid)
                descendants.append(kid.pid)
                queue.append(kid.pid)
            }
        }
        let ownGroup = getpgid(0)
        var groups = Set<Int32>()
        for pid in [rootPid] + descendants {
            if let entry = byPid[pid], entry.pgid > 1, entry.pgid != ownGroup { groups.insert(entry.pgid) }
        }
        return (descendants, Array(groups).sorted())
    }

    /// Live (non-zombie) direct children of `parent` in `table`, each with
    /// its tree.
    static func leftoverTrees(parent: Int32, table: [Entry]) -> [(child: Int32, descendants: [Int32], groups: [Int32])] {
        table.filter { $0.ppid == parent && !$0.zombie }.sorted { $0.pid < $1.pid }.map { child in
            let t = tree(rootPid: child.pid, table: table)
            return (child.pid, t.descendants, t.groups)
        }
    }

    /// A pid is gone once it is absent from the table or a zombie (exited;
    /// whoever its parent is collects it — init/launchd promptly, a dying
    /// parent of ours as soon as that parent is killed). With no table,
    /// `kill(pid, 0)` → ESRCH is the only proof.
    static func isGone(_ pid: Int32, table: [Entry]?) -> Bool {
        if let table {
            guard let entry = table.first(where: { $0.pid == pid }) else { return true }
            return entry.zombie
        }
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }

    /// Reap every zombie child, then end every live direct child AND its
    /// whole tree: SIGTERM (groups, children, descendants), a grace period
    /// that requires the children to be collected and the descendants to be
    /// gone, SIGKILL for whatever remains — children and descendants are
    /// tracked independently, so a detached descendant whose parent obeyed
    /// SIGTERM is still escalated — and a final collection.
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
        var pendingChildren = Set(trees.map(\.child))
        var liveDescendants = Set(trees.flatMap(\.descendants))
        (pendingChildren, liveDescendants) = settle(children: pendingChildren, descendants: liveDescendants,
                                                    budgetNanos: graceNanos)
        report.terminated = trees.count - pendingChildren.count

        if !pendingChildren.isEmpty || !liveDescendants.isEmpty {
            for tree in trees {
                for g in tree.groups where Darwin.kill(-g, 0) == 0 { _ = Darwin.kill(-g, SIGKILL) }
            }
            for pid in pendingChildren { _ = Darwin.kill(pid, SIGKILL) }
            for pid in liveDescendants { _ = Darwin.kill(pid, SIGKILL) }
            let childrenBefore = pendingChildren.count
            let descendantsBefore = liveDescendants.count
            (pendingChildren, liveDescendants) = settle(children: pendingChildren, descendants: liveDescendants,
                                                        budgetNanos: 1_000_000_000)
            report.killed = childrenBefore - pendingChildren.count
            report.terminated += report.killed
            report.descendantsKilled = descendantsBefore - liveDescendants.count
            report.unreaped = pendingChildren.sorted()
            report.survivingDescendants = liveDescendants.sorted()
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

    /// Poll until every pending child is collected (`waitpid(pid, WNOHANG)`
    /// returns it, or ECHILD: not our child any more, so not a zombie of
    /// ours) AND every descendant is gone, or the budget is spent. Returns
    /// what is still pending / alive.
    private static func settle(children: Set<Int32>, descendants: Set<Int32>,
                               budgetNanos: UInt64) -> (Set<Int32>, Set<Int32>) {
        var pending = children
        var live = descendants
        let step: UInt64 = 50_000_000
        // Wall-clock budget (monotonic), not a count of nominal sleeps: a
        // table snapshot per poll costs real time on a loaded machine.
        let deadline = ShutdownDeadline.after(nanos: budgetNanos)
        while true {
            for pid in pending {
                var status: Int32 = 0
                let r = waitpid(pid, &status, WNOHANG)
                if r == pid || (r == -1 && errno == ECHILD) { pending.remove(pid) }
            }
            if !live.isEmpty {
                let table = snapshot()
                live = live.filter { !isGone($0, table: table) }
            }
            if (pending.isEmpty && live.isEmpty) || deadline.hasPassed { break }
            let remaining = deadline.remainingNanos
            usleep(UInt32(min(step, remaining) / 1_000))
        }
        return (pending, live)
    }
}
