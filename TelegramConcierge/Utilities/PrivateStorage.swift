import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Owner-only storage for everything Briglia keeps under its two roots
/// (`StoragePaths.configRoot`, `StoragePaths.dataRoot`).
///
/// What this protects against: OTHER UIDs on the same machine — service
/// accounts, other human accounts, confined apps and sync agents running as a
/// different user. Owner-only modes do nothing against a same-uid process (an
/// MCP server, a command the agent runs), so this is hygiene, not a boundary.
///
/// Policy, in one place:
/// - New files are `0600`, new directories `0700`, both roots `0700`.
/// - A replaced file keeps its OWNER bits and loses its group/other bits
///   (`0755 → 0700`, `0644 → 0600`, `0700` stays `0700`): an executable helper
///   rewritten by the agent stays executable, and a later rewrite can never
///   undo the startup sweep.
/// - Writes never replace a symlink with a regular file. The link is resolved
///   and the FINAL target is classified: a link that lands on harness-owned
///   state is refused (redirecting harness state is the anomaly the sweep's
///   no-follow rule exists for); a user-authored target inside the swept scope
///   is written through with the strip policy; a target outside the roots or
///   inside the excluded areas is written through with its EXACT prior mode
///   preserved, because those files are outside this policy's jurisdiction.
/// - Dangling links, cycles, directories, sockets, FIFOs and devices at the
///   target path are refused with a clear error.
/// - The startup sweep walks both roots minus `projects/` (the user's work
///   product) and `toolchain/` (extracted software, owned by its installer),
///   `lstat`s every entry, never follows symlinks, and strips group/other bits
///   from regular files and directories only.
///
/// Same-uid TOCTOU between the classification and the rename is out of scope
/// (documented, not defended): nothing with a different uid can race inside a
/// `0700` root, and a same-uid process already has every permission involved.
enum PrivateStorage {

    struct StorageError: Error, CustomStringConvertible {
        let description: String
    }

    /// Mode bits this policy removes from every entry in scope.
    static let groupOtherBits: mode_t = 0o077

    /// Children of the roots the sweep and the scope classification skip.
    static let excludedRootChildren: Set<String> = ["projects", "toolchain"]

    /// Directories directly under the DATA root whose contents are harness
    /// state (written only through this helper). Everything else inside the
    /// roots that is not a top-level file is user-authored in-scope content
    /// (`skills/`, `agents/`, `documents/`, `images/`, `tool_attachments/`,
    /// the reminder scripts themselves).
    static let harnessStateDirectories: Set<String> = [
        "archive", "prune-archives", "subagent_sessions", "fire-outbox", "trigger-events", "logs",
    ]
    /// Subpaths (relative to the data root) that are harness state even
    /// though their parent is user-authored.
    static let harnessStateSubpaths: [String] = ["reminder-scripts/state"]

    // MARK: - Scope classification

    enum Scope: Equatable {
        /// A harness-owned state path: top-level files of either root and the
        /// harness state directories. A symlink resolving here is refused.
        case harnessState
        /// Inside a root, outside the excluded areas, not harness state.
        case inScope
        /// Outside both roots, or inside `projects/` / `toolchain/`.
        case outside
    }

    /// Classifies an absolute path (symlinks in the path are resolved so a
    /// root reached through `/var → /private/var` still classifies).
    static func classify(_ path: String,
                         configRoot: URL = StoragePaths.configRoot,
                         dataRoot: URL = StoragePaths.dataRoot) -> Scope {
        let target = canonical(path)
        for (root, isData) in [(configRoot, false), (dataRoot, true)] {
            let rootPath = canonicalDirectory(root.path)
            guard let relative = relativePath(of: target, under: rootPath) else { continue }
            let components = relative.split(separator: "/").map(String.init)
            if components.isEmpty { return .harnessState }
            if excludedRootChildren.contains(components[0]) { return .outside }
            if components.count == 1 { return .harnessState }
            if isData {
                if harnessStateDirectories.contains(components[0]) { return .harnessState }
                for sub in harnessStateSubpaths where relative == sub || relative.hasPrefix(sub + "/") {
                    return .harnessState
                }
            }
            return .inScope
        }
        return .outside
    }

    /// True when `path` lies inside either root (excluded areas included).
    static func isUnderRoots(_ path: String,
                             configRoot: URL = StoragePaths.configRoot,
                             dataRoot: URL = StoragePaths.dataRoot) -> Bool {
        let target = canonical(path)
        return relativePath(of: target, under: canonicalDirectory(configRoot.path)) != nil
            || relativePath(of: target, under: canonicalDirectory(dataRoot.path)) != nil
    }

    /// Lexically normalised path with the symlinks of its DIRECTORY part
    /// resolved and the final component kept as named: a link AT the path is
    /// what the caller wants to classify, not where it points (that is
    /// classified separately after `resolveChain`). The final component may
    /// not exist yet; `realpath` refuses missing paths, so the deepest
    /// existing ancestor is resolved and the rest re-appended.
    static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if url.path == "/" { return "/" }
        return canonicalDirectory(url.deletingLastPathComponent().path) + "/" + url.lastPathComponent
    }

    /// Full resolution of a directory path (roots may themselves be symlinks
    /// — data moved to another disk — and must compare equal to the resolved
    /// targets of links underneath them).
    static func canonicalDirectory(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" {
            tail.insert(url.lastPathComponent, at: 0)
            url = url.deletingLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath()
        for component in tail { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    private static func relativePath(of path: String, under root: String) -> String? {
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    // MARK: - Symlink resolution

    private enum TargetKind {
        case absent, regular, symlink, directory, other
    }

    private static func lstatKind(_ path: String) -> (kind: TargetKind, mode: mode_t) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return (.absent, 0) }
        let fmt = st.st_mode & S_IFMT
        let perm = st.st_mode & 0o7777
        if fmt == S_IFREG { return (.regular, perm) }
        if fmt == S_IFLNK { return (.symlink, perm) }
        if fmt == S_IFDIR { return (.directory, perm) }
        return (.other, perm)
    }

    /// Follows a symlink chain (bounded), returning the final path and what it
    /// is. Cycles and chains longer than the bound are reported as such.
    static func resolveChain(_ path: String, maxHops: Int = 32) throws -> String {
        var current = path
        var seen: Set<String> = []
        for _ in 0..<maxHops {
            guard !seen.contains(current) else {
                throw StorageError(description: "symlink cycle at \(path)")
            }
            seen.insert(current)
            let (kind, _) = lstatKind(current)
            guard kind == .symlink else { return current }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(current, &buffer, buffer.count - 1)
            guard n > 0 else {
                throw StorageError(description: "cannot read symlink \(current): \(String(cString: strerror(errno)))")
            }
            buffer[n] = 0
            let linkTarget = String(cString: buffer)
            if linkTarget.hasPrefix("/") {
                current = URL(fileURLWithPath: linkTarget).standardizedFileURL.path
            } else {
                current = URL(fileURLWithPath: current).deletingLastPathComponent()
                    .appendingPathComponent(linkTarget).standardizedFileURL.path
            }
        }
        throw StorageError(description: "symlink chain too long at \(path)")
    }

    // MARK: - Atomic write

    /// Writes `data` to `url` privately and atomically: exclusive temp in the
    /// target's directory, written through its own descriptor, mode applied
    /// to the temp BEFORE the rename (the final path never exists with wrong
    /// permissions, even across a crash), fsync, rename, fsync of the parent
    /// directory. See the type comment for the mode and symlink policy;
    /// `mode` overrides the policy for callers with fixed needs (`0700`
    /// scripts). Returns the path that was actually replaced (the resolved
    /// target when writing through a symlink).
    @discardableResult
    static func writeAtomically(_ data: Data, to url: URL, mode explicitMode: mode_t? = nil) throws -> String {
        let requested = url.standardizedFileURL.path
        let (kind, currentMode) = lstatKind(requested)
        let target: String
        let finalMode: mode_t
        switch kind {
        case .absent:
            target = requested
            finalMode = explicitMode ?? 0o600
        case .regular:
            target = requested
            finalMode = explicitMode ?? (currentMode & ~groupOtherBits)
        case .symlink:
            if classify(requested) == .harnessState {
                throw StorageError(description: "refusing to write \(requested): a harness-owned state path must not be a symlink — remove the link, then run `briglia doctor`")
            }
            let resolved = try resolveChain(requested)
            let (resolvedKind, resolvedMode) = lstatKind(resolved)
            switch resolvedKind {
            case .absent:
                throw StorageError(description: "refusing to write through a dangling symlink: \(requested) → \(resolved) (create the target first, or remove the link)")
            case .regular:
                break
            case .directory, .other, .symlink:
                throw StorageError(description: "refusing to write \(requested): the symlink resolves to something that is not a regular file (\(resolved))")
            }
            switch classify(resolved) {
            case .harnessState:
                throw StorageError(description: "refusing to write \(requested): it is a symlink to harness-owned state (\(resolved)); a link at this path is not expected — run `briglia doctor`")
            case .inScope:
                finalMode = explicitMode ?? (resolvedMode & ~groupOtherBits)
            case .outside:
                // Not ours to tighten: keep the external target's exact mode.
                finalMode = explicitMode ?? resolvedMode
            }
            target = resolved
        case .directory:
            throw StorageError(description: "refusing to write \(requested): it is a directory")
        case .other:
            throw StorageError(description: "refusing to write \(requested): not a regular file (socket, FIFO or device)")
        }
        try replaceContents(of: target, with: data, mode: finalMode)
        return target
    }

    /// The write proper — `target` is already resolved and classified.
    private static func replaceContents(of target: String, with data: Data, mode: mode_t) throws {
        let targetURL = URL(fileURLWithPath: target)
        let dir = targetURL.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(targetURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw StorageError(description: "could not create \(tmp.path) exclusively: \(String(cString: strerror(errno)))")
        }
        var failure: String? = nil
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = "write failed: \(String(cString: strerror(errno)))"
                    return
                }
                offset += n
            }
        }
        if failure == nil, fchmod(fd, mode) != 0 {
            failure = "could not set mode \(String(mode, radix: 8)): \(String(cString: strerror(errno)))"
        }
        if failure == nil, fsync(fd) != 0 {
            failure = "fsync failed: \(String(cString: strerror(errno)))"
        }
        close(fd)
        if let failure {
            unlink(tmp.path)
            throw StorageError(description: "could not write \(target): \(failure)")
        }
        guard rename(tmp.path, target) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(tmp.path)
            throw StorageError(description: "could not move \(tmp.lastPathComponent) into place at \(target): \(why)")
        }
        try fsyncDirectory(dir.path)
    }

    /// Directory barrier: durability of the rename's entry. Part of the
    /// write's contract, so a failure is reported (the file is in place,
    /// but the caller was promised a durable entry and did not get one).
    static func fsyncDirectory(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw StorageError(description: "could not open \(path) for fsync: \(String(cString: strerror(errno)))")
        }
        let rc = fsync(fd)
        let code = errno
        close(fd)
        guard rc == 0 else {
            throw StorageError(description: "fsync of \(path) failed: \(String(cString: strerror(code)))")
        }
    }

    // MARK: - Directories and handle-based files

    /// Creates `url` (and missing ancestors) as `0700` directories, or strips
    /// group/other bits from an existing leaf that is wider. Only for
    /// directories inside the roots.
    static func ensureDirectory(_ url: URL, mode: mode_t = 0o700) throws {
        let path = url.standardizedFileURL.path
        var missing: [String] = []
        var probe = path
        while true {
            let (kind, _) = lstatKind(probe)
            if kind == .absent {
                missing.insert(probe, at: 0)
                let parent = URL(fileURLWithPath: probe).deletingLastPathComponent().path
                if parent == probe { break }
                probe = parent
                continue
            }
            if kind == .directory { break }
            // A symlink to a directory is acceptable as an ancestor (it is
            // resolved by the kernel); anything else in the way is an error.
            if kind == .symlink, let resolved = try? resolveChain(probe), lstatKind(resolved).kind == .directory { break }
            throw StorageError(description: "cannot create directory \(path): \(probe) exists and is not a directory")
        }
        for dir in missing {
            if mkdir(dir, mode) != 0 && errno != EEXIST {
                throw StorageError(description: "could not create \(dir): \(String(cString: strerror(errno)))")
            }
        }
        // mkdir applies the umask; enforce the exact mode on what we created
        // and strip a wider pre-existing leaf.
        for dir in missing {
            _ = chmod(dir, mode)
        }
        // Tighten a wider leaf. A leaf that is a symlink to a directory (a
        // root moved to another disk and linked back) is tightened at its
        // TARGET: the sweep, the roots and every child live there.
        var leafPath = path
        var (leafKind, leafMode) = lstatKind(path)
        if leafKind == .symlink {
            let resolved = try resolveChain(path)
            let target = lstatKind(resolved)
            guard target.kind == .directory else {
                throw StorageError(description: "\(path) is a symlink that does not resolve to a directory (\(resolved))")
            }
            leafPath = resolved
            (leafKind, leafMode) = target
        }
        if leafKind == .directory, leafMode & groupOtherBits != 0 {
            _ = chmod(leafPath, leafMode & ~groupOtherBits)
        }
    }

    /// Opens (creating if needed, `0600`) a file for appending — for logs and
    /// other handle-based writers. An existing wider file is tightened; a
    /// symlink at the path is refused (`O_NOFOLLOW`).
    static func openForAppend(_ url: URL, mode: mode_t = 0o600) throws -> FileHandle {
        let path = url.standardizedFileURL.path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, mode)
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP {
                throw StorageError(description: "refusing to append to \(path): it is a symlink")
            }
            throw StorageError(description: "could not open \(path): \(String(cString: strerror(code)))")
        }
        var st = stat()
        if fstat(fd, &st) == 0 {
            let perm = st.st_mode & 0o7777
            if perm & groupOtherBits != 0 { _ = fchmod(fd, perm & ~groupOtherBits) }
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // MARK: - Sweep and report

    struct SweepReport {
        var scanned = 0
        var tightened = 0
        var skipped = 0        // symlinks, sockets, FIFOs, devices
        var truncated = false  // the entry budget was hit
        var errors: [String] = []
        var samples: [String] = []   // first few tightened (or wide, for reports) paths
    }

    /// Every entry under both roots minus the excluded children: strip
    /// group/other bits from regular files and directories. Never follows
    /// symlinks. Bounded by `budget` entries so a runaway tree cannot stall
    /// startup. When `apply` is false, only counts (doctor).
    @discardableResult
    static func sweep(configRoot: URL = StoragePaths.configRoot,
                      dataRoot: URL = StoragePaths.dataRoot,
                      apply: Bool = true,
                      budget: Int = 250_000) -> SweepReport {
        var report = SweepReport()
        for root in [configRoot, dataRoot] {
            var rootPath = root.standardizedFileURL.path
            var (kind, mode) = lstatKind(rootPath)
            if kind == .symlink {
                // A root that is itself a symlink (data moved to another
                // disk) is swept at its target; the link is not a
                // directory to lstat, so without this the whole tree was
                // skipped (Codex, Release B round 1).
                guard let resolved = try? resolveChain(rootPath) else {
                    report.errors.append("\(rootPath): symlink cannot be resolved")
                    continue
                }
                rootPath = resolved
                (kind, mode) = lstatKind(rootPath)
                if kind != .directory {
                    report.errors.append("\(root.path): symlink resolves to a non-directory (\(resolved))")
                    continue
                }
            }
            if kind == .absent { continue }            // not created yet (diagnostics never create roots)
            guard kind == .directory else {
                report.errors.append("\(root.path): exists but is not a directory")
                continue
            }
            report.scanned += 1
            if mode & groupOtherBits != 0 {
                record(rootPath, mode: mode, apply: apply, into: &report)
            }
            walk(rootPath, depth: 0, apply: apply, budget: budget, into: &report)
        }
        return report
    }

    private static func record(_ path: String, mode: mode_t, apply: Bool, into report: inout SweepReport) {
        if apply {
            if chmod(path, mode & ~groupOtherBits) == 0 {
                report.tightened += 1
            } else {
                report.errors.append("\(path): \(String(cString: strerror(errno)))")
                return
            }
        } else {
            report.tightened += 1
        }
        if report.samples.count < 8 {
            report.samples.append("\(path) (\(String(mode, radix: 8)))")
        }
    }

    private static func walk(_ dir: String, depth: Int, apply: Bool, budget: Int, into report: inout SweepReport) {
        guard depth < 64, !report.truncated else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            report.errors.append("\(dir): unreadable")
            return
        }
        for name in names.sorted() {
            if report.scanned >= budget { report.truncated = true; return }
            if depth == 0, excludedRootChildren.contains(name) { continue }
            let path = dir + "/" + name
            let (kind, mode) = lstatKind(path)
            report.scanned += 1
            switch kind {
            case .regular, .directory:
                if mode & groupOtherBits != 0 {
                    record(path, mode: mode, apply: apply, into: &report)
                }
                if kind == .directory {
                    walk(path, depth: depth + 1, apply: apply, budget: budget, into: &report)
                }
            case .symlink, .other:
                report.skipped += 1
            case .absent:
                continue
            }
        }
    }
}
