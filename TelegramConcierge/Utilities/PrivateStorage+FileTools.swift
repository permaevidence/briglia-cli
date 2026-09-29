import Foundation

/// The model-facing file tools (`write_file`, `edit_file`, `apply_patch`)
/// write wherever the agent points them. Inside the two roots — and outside
/// the excluded `projects/` and `toolchain/` areas — the write follows the
/// private-storage policy (owner bits kept, group/other stripped, symlinks
/// classified by their resolved target). Everywhere else the file is the
/// user's, and the pre-H2 behaviour is kept exactly: resolve the symlink,
/// replace atomically, put the previous mode back.
extension PrivateStorage {

    /// How a path OUTSIDE the policy's scope is written — the three shapes
    /// the file tools used before the policy existed, kept byte-for-byte.
    enum OutsideRootsWrite {
        /// Resolve a symlink at the path, replace atomically, restore the
        /// exact previous mode (`write_file`, `edit_file`, `apply_patch`
        /// update).
        case resolveAndPreserveMode
        /// Resolve a symlink at the path, replace atomically (`apply_patch`
        /// rollback).
        case resolveOnly
        /// Replace atomically at the path as named (`apply_patch` add and
        /// move — the plan already refused an existing destination).
        case plain
    }

    /// True when a file-tool write to `path` is governed by the policy.
    static func fileToolPathIsInScope(_ path: String) -> Bool {
        classify(path) != .outside
    }

    /// Writes `data` for a file tool: policy write inside the scope,
    /// legacy write outside it. Callers keep their own locks (the routing
    /// sidecar lock) around this call.
    static func fileToolWrite(_ data: Data, toRequestedPath path: String,
                              outsideRoots: OutsideRootsWrite) throws {
        if fileToolPathIsInScope(path) {
            try StageMarkers.measure("fs.write.private_atomic") {
                _ = try writeAtomically(data, to: URL(fileURLWithPath: path))
            }
            return
        }
        let fm = FileManager.default
        switch outsideRoots {
        case .resolveAndPreserveMode:
            let targetURL = StageMarkers.measure("fs.write.resolve_symlinks") {
                URL(fileURLWithPath: path).resolvingSymlinksInPath()
            }
            let previousMode = StageMarkers.measure("fs.write.stat_previous_mode") {
                (try? fm.attributesOfItem(atPath: targetURL.path))?[.posixPermissions] as? NSNumber
            }
            // Foundation's atomic write: temp file in the same directory,
            // then rename (no explicit fsync).
            try StageMarkers.measure("fs.write.atomic_temp_and_rename") {
                try data.write(to: targetURL, options: .atomic)
            }
            if let previousMode {
                StageMarkers.measure("fs.write.restore_mode") {
                    try? fm.setAttributes([.posixPermissions: previousMode], ofItemAtPath: targetURL.path)
                }
            }
        case .resolveOnly:
            try data.write(to: URL(fileURLWithPath: path).resolvingSymlinksInPath(), options: .atomic)
        case .plain:
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Creates the parent directory of a file-tool target: `0700` (and a
    /// wider existing leaf tightened) inside the scope, plain
    /// `createDirectory` outside it. `outsideRoots` says whether the legacy
    /// path resolved the symlink first, as the write it precedes does.
    static func fileToolEnsureParentDirectory(ofRequestedPath path: String,
                                              outsideRoots: OutsideRootsWrite) throws {
        if fileToolPathIsInScope(path) {
            try ensureDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
            return
        }
        let base: URL
        switch outsideRoots {
        case .resolveAndPreserveMode, .resolveOnly:
            base = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        case .plain:
            base = URL(fileURLWithPath: path)
        }
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}

/// `localizedDescription` on a plain `Error` is the generic "operation
/// couldn't be completed" text; the tools report write failures through it,
/// so the storage errors must surface their own wording there.
extension PrivateStorage.StorageError: LocalizedError {
    var errorDescription: String? { description }
}
