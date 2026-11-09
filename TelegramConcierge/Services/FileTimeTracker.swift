import Foundation

/// Tracks (mtime, size, readAt) snapshots per absolute path for the lifetime of the process.
/// Write/edit tools assert the snapshot still matches the on-disk state before modifying a file,
/// catching cases where the file changed externally since the agent last read it.
///
/// Snapshots are in-memory only. They reset on app restart, which is correct — the invariant
/// is "don't modify a file you haven't read this session."
actor FileTimeTracker {
    static let shared = FileTimeTracker()

    struct Snapshot {
        let mtime: Date
        let size: Int64
        let readAt: Date
    }

    private var snapshots: [String: Snapshot] = [:]

    /// GPT-only evidence (GPT_APPLY_PATCH_PLAN §7), keyed by canonical
    /// resolved path. A separate store: standard tools never read it, and
    /// nothing here ever touches `snapshots` (standard evidence).
    private var gptSnapshots: [String: GPTEvidence.Record] = [:]

    private init() {}

    // MARK: - GPT-only evidence (never consulted by standard tools)

    /// Publishes a receipt. Callers publish only after the result that earned
    /// it was delivered to the model (§7 observation receipts).
    func publishGPT(_ receipt: GPTEvidence.Receipt) {
        gptSnapshots[receipt.key] = GPTEvidence.Record(identity: receipt.identity, recordedAt: Date(), source: receipt.source)
    }

    /// Selftest seam: runs inside the tracker before an admitted mutation's
    /// cancellation check (a queued operation held behind tracker work).
    nonisolated(unsafe) static var beforeGPTMutationHookForTesting: (@Sendable () async -> Void)?

    /// Delivery-admitted publication (Codex S2 round 2): the calling task's
    /// cancellation is checked in the same actor step as the write, so a
    /// round cancelled while its publication waits for the tracker earns
    /// nothing. Returns whether the receipt was published.
    @discardableResult
    func publishGPTIfAdmitted(_ receipt: GPTEvidence.Receipt) async -> Bool {
        if let hook = Self.beforeGPTMutationHookForTesting { await hook() }
        guard !Task.isCancelled else { return false }
        publishGPT(receipt)
        return true
    }

    /// Same admission for forgetting a key (a delivered Delete or Move source).
    @discardableResult
    func forgetGPTIfAdmitted(key: String) async -> Bool {
        if let hook = Self.beforeGPTMutationHookForTesting { await hook() }
        guard !Task.isCancelled else { return false }
        forgetGPT(key: key)
        return true
    }

    func gptRecord(forKey key: String) -> GPTEvidence.Record? { gptSnapshots[key] }

    /// A GPT delete forgets only the GPT record of that path.
    func forgetGPT(key: String) { gptSnapshots.removeValue(forKey: key) }

    /// Selftests only.
    func resetGPTForTesting() { gptSnapshots.removeAll() }

    /// Selftests only: the standard record, to prove GPT paths never touch it.
    func standardSnapshotForTesting(path: String) -> Snapshot? { snapshots[path] }

    /// Record that the agent just read `path`, stamping the current on-disk (mtime, size).
    func recordRead(path: String) {
        guard let (mtime, size) = Self.currentStat(path: path) else { return }
        snapshots[path] = Snapshot(mtime: mtime, size: size, readAt: Date())
    }

    /// Verify the file has not changed since the agent last read it.
    /// Throws if the file was never read in this session, or if mtime/size drifted.
    func assertFresh(path: String) throws {
        guard let snap = snapshots[path] else {
            throw FileTimeError.notRead(path: path)
        }
        guard let (mtime, size) = Self.currentStat(path: path) else {
            // File was read before but is now missing/unstatable. Callers check existence
            // immediately before asserting, so this only fires when the file vanished in
            // that window (deleted or replaced externally) — treat it as stale, not fresh.
            throw FileTimeError.vanished(path: path)
        }
        if size != snap.size || !mtime.isApproximatelyEqual(to: snap.mtime) {
            throw FileTimeError.stale(
                path: path,
                snapshotMtime: snap.mtime,
                currentMtime: mtime,
                snapshotSize: snap.size,
                currentSize: size
            )
        }
    }

    /// Clear the snapshot for a path (used after a successful write so the next read can re-snapshot).
    func forget(path: String) {
        snapshots.removeValue(forKey: path)
    }

    /// Returns `(mtime, size)` if the file exists and is readable, otherwise nil.
    /// Symlinks are resolved before statting: `attributesOfItem` does not traverse the final
    /// symlink, and the link inode's mtime/size never change when the *target* is modified —
    /// statting the link would make the stale-write check silently always pass on symlinked
    /// paths. Snapshots stay keyed by the path the caller used; only the stat resolves.
    private static func currentStat(path: String) -> (Date, Int64)? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
        guard let attrs,
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        return (mtime, size)
    }
}

enum FileTimeError: LocalizedError {
    case notRead(path: String)
    case stale(path: String, snapshotMtime: Date, currentMtime: Date, snapshotSize: Int64, currentSize: Int64)
    case vanished(path: String)

    var errorDescription: String? {
        switch self {
        case .notRead(let path):
            return "You must read \(path) with read_file before overwriting or editing it. Use read_file first. (Read history resets when Briglia restarts — a file read before a restart must be re-read, since it may have changed while Briglia was down.)"
        case .vanished(let path):
            return "\(path) was read this session but no longer exists on disk (deleted or replaced externally). Re-read it or list the directory before modifying it."
        case .stale(let path, let snapMtime, let curMtime, let snapSize, let curSize):
            let fmt = ISO8601DateFormatter()
            return """
            \(path) changed since last read.
            Last read: mtime=\(fmt.string(from: snapMtime)) size=\(snapSize)
            Current:   mtime=\(fmt.string(from: curMtime)) size=\(curSize)
            Re-read the file before modifying it.
            """
        }
    }
}

private extension Date {
    /// Filesystem mtime resolution varies; treat dates within 1ms as equal.
    func isApproximatelyEqual(to other: Date) -> Bool {
        abs(timeIntervalSince(other)) < 0.001
    }
}
