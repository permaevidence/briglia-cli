import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The journaled, revalidating writer the GPT engine uses (plan §6.5,
/// review F2/R3-2). Opt-in and used only by `CodexPatch`: the standard
/// tools keep `PrivateStorage.writeAtomically`/`fileToolWrite` unchanged.
///
/// Every step reports a receipt to the journal AT THE MOMENT it mutates
/// anything, including on partial failure (a throw after a directory was
/// created or a rename happened still leaves its receipt). Each receipt holds
/// the full expected post-state; rollback compares the path with that stored
/// expectation, never with whatever is present when rollback starts.
///
/// Honest limit: against non-cooperating writers, check-then-rename/unlink is
/// not atomic (forward and rollback). Every conflict that is observed is
/// preserved and reported; a change landing inside the window cannot be
/// excluded.
enum CodexPatchTransaction {

    // MARK: Journal

    enum Receipt {
        /// A temp file this transaction created (cleaned on any failure).
        case temp(path: String, device: UInt64, inode: UInt64)
        case createdDirectory(path: String, device: UInt64, inode: UInt64, mode: mode_t)
        case tightenedDirectory(path: String, device: UInt64, inode: UInt64, oldMode: mode_t, newMode: mode_t)
        /// An existing file replaced: `pre` to restore, `post` the expected
        /// state now (nil when the post-state could not be bound to the
        /// staged inode — rollback then treats the path as a conflict).
        case replaced(path: String, display: String, pre: PreImage, post: PostState?)
        /// A new file created at an absent path.
        case created(path: String, display: String, post: PostState?)
        /// A file removed (Delete, Move source); restored only while absent.
        case removed(path: String, display: String, pre: PreImage)
        /// The secret store, committed through the settings writer (D9).
        case secretStore(display: String, preText: String, postText: String)
    }

    struct PreImage {
        let data: Data
        let identity: FileIdentity
        let hash: String
    }

    struct PostState {
        let identity: FileIdentity
        let hash: String
    }

    /// Reference type so receipts recorded before a throw survive it.
    final class Journal {
        private(set) var receipts: [Receipt] = []
        func record(_ r: Receipt) { receipts.append(r) }
        /// Temps are dropped from the journal once consumed by a rename/link.
        func consumeTemp(_ path: String) {
            receipts.removeAll { if case .temp(let p, _, _) = $0 { return p == path }; return false }
        }
    }

    // MARK: Errors

    struct StepError: Error, CustomStringConvertible {
        enum Kind { case conflict, io }
        let kind: Kind
        let message: String
        var description: String { message }
        static func conflict(_ m: String) -> StepError { StepError(kind: .conflict, message: m) }
        static func io(_ m: String) -> StepError { StepError(kind: .io, message: m) }
    }

    // MARK: Test seams (selftests only)

    enum FaultPoint: String, CaseIterable {
        case createDirectory, tightenDirectory, stageCreate, stageWrite, stageChmod, stageFsync
        case beforeRevalidate, rename, directoryFsync, remove, link
    }

    /// Returning true makes the step fail as an I/O error at that point. The
    /// second argument is the path concerned.
    nonisolated(unsafe) static var faultInjector: ((FaultPoint, String) -> Bool)?
    /// Runs before each step's final revalidation (lets a test change the
    /// file system "concurrently" at the exact window).
    nonisolated(unsafe) static var beforeRevalidateHook: ((String) -> Void)?
    /// Runs right before rollback starts.
    nonisolated(unsafe) static var beforeRollbackHook: (() -> Void)?
    /// Deliberate-break seams are source mutations, not flags.

    static func injected(_ point: FaultPoint, _ path: String) -> Bool { faultInjector?(point, path) ?? false }

    static let hashLimit = 16 * 1024 * 1024

    // MARK: ensureParent

    /// Creates the missing directories above `path` one by one (a receipt per
    /// directory as soon as it exists), then — inside the private-storage
    /// scope — tightens a wider existing parent, as `PrivateStorage
    /// .ensureDirectory` does for the standard tools.
    static func ensureParent(of path: String, inScope: Bool, journal: Journal) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var missing: [String] = []
        var probe = parent
        while true {
            let id = try FileIdentity.lstatPath(probe)
            guard let id else {
                missing.insert(probe, at: 0)
                let up = URL(fileURLWithPath: probe).deletingLastPathComponent().path
                if up == probe { break }
                probe = up
                continue
            }
            if id.kind == .directory { break }
            if id.kind == .symlink, let resolved = try? PrivateStorage.resolveChain(probe),
               (try? FileIdentity.lstatPath(resolved))??.kind == .directory { break }
            throw StepError.io("cannot create directory \(parent): \(probe) exists and is not a directory")
        }
        for dir in missing {
            if injected(.createDirectory, dir) { throw StepError.io("could not create \(dir): injected failure (test seam)") }
            let mode: mode_t = inScope ? 0o700 : 0o777
            if mkdir(dir, mode) != 0 {
                let code = errno
                if code == EEXIST { throw StepError.conflict("\(dir) appeared during the patch") }
                throw StepError.io("could not create \(dir): \(String(cString: strerror(code)))")
            }
            if inScope { _ = chmod(dir, 0o700) }
            guard let id = try FileIdentity.lstatPath(dir), id.kind == .directory else {
                throw StepError.conflict("\(dir) changed right after it was created")
            }
            journal.record(.createdDirectory(path: dir, device: id.device, inode: id.inode, mode: id.mode))
        }
        guard inScope, missing.isEmpty else { return }
        var leaf = parent
        guard var id = try FileIdentity.lstatPath(leaf) else { return }
        if id.kind == .symlink {
            leaf = try PrivateStorage.resolveChain(leaf)
            guard let resolved = try FileIdentity.lstatPath(leaf), resolved.kind == .directory else {
                throw StepError.io("\(parent) is a symlink that does not resolve to a directory")
            }
            id = resolved
        }
        guard id.kind == .directory, id.mode & PrivateStorage.groupOtherBits != 0 else { return }
        if injected(.tightenDirectory, leaf) { throw StepError.io("could not tighten \(leaf): injected failure (test seam)") }
        let newMode = id.mode & ~PrivateStorage.groupOtherBits
        guard chmod(leaf, newMode) == 0 else { throw StepError.io("could not set mode of \(leaf): \(String(cString: strerror(errno)))") }
        journal.record(.tightenedDirectory(path: leaf, device: id.device, inode: id.inode, oldMode: id.mode, newMode: newMode))
    }

    // MARK: stage

    struct StagedFile {
        let tempPath: String
        let identity: FileIdentity
        let hash: String
    }

    /// Temp file in the target's directory, registered in the journal at
    /// creation (before write, chmod or fsync can fail), data written, final
    /// mode set before exposure (`nil` = keep the umask-applied creation
    /// mode of a new file outside the policy's scope), fsync.
    static func stage(_ data: Data, forTarget target: String, finalMode: mode_t?, journal: Journal) throws -> StagedFile {
        let url = URL(fileURLWithPath: target)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)").path
        if injected(.stageCreate, target) { throw StepError.io("could not create a temporary file next to \(target): injected failure (test seam)") }
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, finalMode == nil ? 0o666 : 0o600)
        guard fd >= 0 else { throw StepError.io("could not create a temporary file next to \(target): \(String(cString: strerror(errno)))") }
        var closed = false
        defer { if !closed { close(fd) } }
        let created = try FileIdentity.fstatFD(fd)
        journal.record(.temp(path: temp, device: created.device, inode: created.inode))
        var failure: String? = injected(.stageWrite, target) ? "write failed: injected failure (test seam)" : nil
        if failure == nil {
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
        }
        if failure == nil, let finalMode {
            if injected(.stageChmod, target) { failure = "could not set the mode: injected failure (test seam)" }
            else if fchmod(fd, finalMode) != 0 { failure = "could not set mode \(String(finalMode, radix: 8)): \(String(cString: strerror(errno)))" }
        }
        if failure == nil {
            if injected(.stageFsync, target) { failure = "fsync failed: injected failure (test seam)" }
            else if fsync(fd) != 0 { failure = "fsync failed: \(String(cString: strerror(errno)))" }
        }
        if let failure { throw StepError.io("could not write \(target): \(failure)") }
        let identity = try FileIdentity.fstatFD(fd)
        close(fd)
        closed = true
        return StagedFile(tempPath: temp, identity: identity, hash: CodexPatchFS.sha256(data))
    }

    /// Removes a staged temp that was not consumed (its own failure, or a
    /// revalidation mismatch).
    /// The receipt is consumed only once the temp is known to be gone, or the
    /// name no longer holds our inode (never removing another object's file);
    /// a failed unlink keeps it so rollback retries and reports it (Codex S1
    /// round 2).
    static func discard(_ staged: StagedFile, journal: Journal) {
        if let id = try? FileIdentity.lstatPath(staged.tempPath), id.inode == staged.identity.inode {
            guard unlink(staged.tempPath) == 0 else { return }
        }
        journal.consumeTemp(staged.tempPath)
    }

    /// Consumes a temp receipt only when the name is verifiably absent.
    static func consumeIfGone(_ temp: String, journal: Journal) {
        if case .some(.none) = try? FileIdentity.lstatPath(temp) { journal.consumeTemp(temp) }
    }

    // MARK: revalidate + replace / remove

    enum Expected {
        case absent
        case state(FileIdentity, hash: String)
    }

    static func matches(_ path: String, _ expected: Expected) throws -> Bool {
        let current = try CodexPatchFS.stateAndHash(path, limit: hashLimit)
        switch (expected, current) {
        case (.absent, nil): return true
        case (.absent, .some): return false
        case (.state, nil): return false
        case (.state(let id, let hash), .some(let (cur, curHash))): return id.sameState(as: cur) && hash == curHash
        }
    }

    /// Under the cooperating config-file lock: re-read the target identity
    /// (or absence) right before `rename(2)`; on a mismatch remove the temp
    /// and fail with a conflict (nothing replaced). A new path is created with
    /// `link(2)` (fails if the name appeared), falling back to `rename` where
    /// hard links are unsupported. The receipt is recorded the moment the
    /// name points at the new inode, before the directory `fsync`.
    /// The link an Update wrote through, as it was at preflight.
    struct LinkGuard {
        let path: String
        let identity: FileIdentity
    }

    static func revalidateAndReplace(_ staged: StagedFile, target: String, display: String,
                                     expected: Expected, pre: PreImage?, linkGuard: LinkGuard? = nil, journal: Journal) throws {
        beforeRevalidateHook?(target)
        try EditProtections.withConfigFileLock(target) {
            if injected(.beforeRevalidate, target) {
                discard(staged, journal: journal)
                throw StepError.io("could not check \(display): injected failure (test seam)")
            }
            if let linkGuard {
                guard let now = try FileIdentity.lstatPath(linkGuard.path), now.sameState(as: linkGuard.identity) else {
                    discard(staged, journal: journal)
                    throw StepError.conflict("\(display) (a symbolic link) was changed or retargeted during the patch")
                }
            }
            guard try matches(target, expected) else {
                discard(staged, journal: journal)
                throw StepError.conflict("\(display) changed during the patch")
            }
            var linked = false
            if case .absent = expected {
                if injected(.link, target) {
                    discard(staged, journal: journal)
                    throw StepError.io("could not create \(display): injected failure (test seam)")
                }
                if link(staged.tempPath, target) == 0 {
                    linked = true
                    unlink(staged.tempPath)
                } else {
                    let code = errno
                    if code == EEXIST {
                        discard(staged, journal: journal)
                        throw StepError.conflict("\(display) appeared during the patch")
                    }
                    if code != EPERM && code != ENOTSUP && code != EXDEV && code != EOPNOTSUPP && code != EMLINK {
                        discard(staged, journal: journal)
                        throw StepError.io("could not create \(display): \(String(cString: strerror(code)))")
                    }
                }
            }
            if !linked {
                if injected(.rename, target) {
                    discard(staged, journal: journal)
                    throw StepError.io("could not move the new contents into place at \(display): injected failure (test seam)")
                }
                guard rename(staged.tempPath, target) == 0 else {
                    let why = String(cString: strerror(errno))
                    discard(staged, journal: journal)
                    throw StepError.io("could not move the new contents into place at \(display): \(why)")
                }
            }
            // After a hard link the temp name is a second link to the new
            // file; if its unlink failed the receipt stays (cleaned later).
            consumeIfGone(staged.tempPath, journal: journal)
            // Bind the post-state to the staged inode (ctime moves on rename).
            var post: PostState? = nil
            if let now = try? FileIdentity.lstatPath(target), now.sameObjectIgnoringCtime(as: staged.identity) {
                post = PostState(identity: now, hash: staged.hash)
            }
            if let pre {
                journal.record(.replaced(path: target, display: display, pre: pre, post: post))
            } else {
                journal.record(.created(path: target, display: display, post: post))
            }
        }
        try fsyncParent(of: target, display: display)
    }

    static func remove(_ target: String, display: String, pre: PreImage, journal: Journal) throws {
        beforeRevalidateHook?(target)
        try EditProtections.withConfigFileLock(target) {
            if injected(.beforeRevalidate, target) { throw StepError.io("could not check \(display): injected failure (test seam)") }
            guard try matches(target, .state(pre.identity, hash: pre.hash)) else {
                throw StepError.conflict("\(display) changed during the patch")
            }
            if injected(.remove, target) { throw StepError.io("could not remove \(display): injected failure (test seam)") }
            guard unlink(target) == 0 else { throw StepError.io("could not remove \(display): \(String(cString: strerror(errno)))") }
            journal.record(.removed(path: target, display: display, pre: pre))
        }
        try fsyncParent(of: target, display: display)
    }

    static func fsyncParent(of path: String, display: String) throws {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if injected(.directoryFsync, path) {
            throw StepError.io("\(display) was written but its directory entry could not be made durable: injected failure (test seam)")
        }
        do { try PrivateStorage.fsyncDirectory(dir) } catch {
            throw StepError.io("\(display) was written but its directory entry could not be made durable: \(error)")
        }
    }

    // MARK: Rollback

    struct RollbackReport {
        var restored: [String] = []
        var conflicts: [String] = []
        /// Paths still carrying this patch's change (the undo itself failed).
        var stillChanged: [String] = []
        /// Temporary files this transaction created that could not be removed.
        var leftoverTemps: [String] = []
    }

    /// Removes the outstanding temps of a journal (identity-checked); a temp
    /// that cannot be removed is reported, never silently left behind.
    static func cleanTemps(_ journal: Journal, _ report: inout RollbackReport) {
        for case .temp(let p, _, let ino) in journal.receipts {
            guard let id = try? FileIdentity.lstatPath(p), id.inode == ino else { continue }
            if unlink(p) != 0 { report.leftoverTemps.append(p) }
        }
    }

    /// Reverse journal order, under the same cooperating locks; each path is
    /// compared with the receipt's stored expectation. Any mismatch —
    /// metadata-only included — leaves the path untouched and is reported.
    static func rollback(_ journal: Journal) async -> RollbackReport {
        beforeRollbackHook?()
        var report = RollbackReport()
        for receipt in journal.receipts.reversed() {
            switch receipt {
            case .temp(let path, _, let inode):
                if let id = try? FileIdentity.lstatPath(path), id.inode == inode, unlink(path) != 0 {
                    report.leftoverTemps.append(path)
                }

            case .createdDirectory(let path, let device, let inode, let mode):
                guard let id = try? FileIdentity.lstatPath(path), id.kind == .directory,
                      id.device == device, id.inode == inode, id.mode == mode,
                      CodexPatchFS.isEmptyDirectory(path) else {
                    if (try? FileIdentity.lstatPath(path)) != nil { report.conflicts.append(path) }
                    continue
                }
                if rmdir(path) != 0 { report.conflicts.append(path) }

            case .tightenedDirectory(let path, let device, let inode, let oldMode, let newMode):
                guard let id = try? FileIdentity.lstatPath(path), id.kind == .directory,
                      id.device == device, id.inode == inode, id.mode == newMode else {
                    report.conflicts.append(path)
                    continue
                }
                if chmod(path, oldMode) != 0 { report.conflicts.append(path) }

            case .replaced(let path, let display, let pre, let post):
                guard let post else { report.conflicts.append(display); continue }
                // The restoration's own temps are cleaned whatever happens,
                // including a failed stage (Codex S1 R1).
                let tmp = Journal()
                defer { cleanTemps(tmp, &report) }
                do {
                    let staged = try stage(pre.data, forTarget: path, finalMode: pre.identity.mode, journal: tmp)
                    do {
                        try revalidateAndReplace(staged, target: path, display: display,
                                                 expected: .state(post.identity, hash: post.hash), pre: nil, journal: tmp)
                        report.restored.append(display)
                    } catch let e as StepError where e.kind == .conflict {
                        report.conflicts.append(display)
                    } catch {
                        // The rename may have happened before a failed fsync.
                        if (try? matches(path, .state(pre.identity, hash: pre.hash))) == true || tmp.receipts.contains(where: { if case .created = $0 { return true }; return false }) {
                            report.restored.append(display)
                        } else {
                            report.stillChanged.append(display)
                        }
                    }
                } catch {
                    report.stillChanged.append(display)
                }

            case .created(let path, let display, let post):
                guard let post else { report.conflicts.append(display); continue }
                do {
                    try EditProtections.withConfigFileLock(path) {
                        // Already absent: the pre-state (no file) holds.
                        if try FileIdentity.lstatPath(path) == nil { return }
                        guard try matches(path, .state(post.identity, hash: post.hash)) else { throw StepError.conflict(display) }
                        guard unlink(path) == 0 else { throw StepError.io(display) }
                    }
                    report.restored.append(display)
                } catch let e as StepError where e.kind == .conflict {
                    report.conflicts.append(display)
                } catch {
                    report.stillChanged.append(display)
                }

            case .removed(let path, let display, let pre):
                // Restore only while the name is still absent: stage, then
                // link (fails if the name was recreated).
                // The restoration's own temps are cleaned whatever happens,
                // including a failed stage (Codex S1 R1).
                let tmp = Journal()
                defer { cleanTemps(tmp, &report) }
                do {
                    let staged = try stage(pre.data, forTarget: path, finalMode: pre.identity.mode, journal: tmp)
                    do {
                        try revalidateAndReplace(staged, target: path, display: display, expected: .absent, pre: nil, journal: tmp)
                        report.restored.append(display)
                    } catch let e as StepError where e.kind == .conflict {
                        report.conflicts.append(display)
                    } catch {
                        if tmp.receipts.contains(where: { if case .created = $0 { return true }; return false }) {
                            report.restored.append(display)
                        } else {
                            report.stillChanged.append(display)
                        }
                    }
                } catch {
                    report.stillChanged.append(display)
                }

            case .secretStore(let display, let preText, let postText):
                // Inverse conditional delta (D9): restores the edited keys only
                // while they still hold the patch's values.
                let outcome = await SettingsAgentEdit.commit(originalText: postText, updatedText: preText, label: "secrets.json patch rollback")
                switch outcome {
                case .applied, .unchanged: report.restored.append(display)
                case .refused: report.conflicts.append(display)
                }
            }
        }
        return report
    }
}
