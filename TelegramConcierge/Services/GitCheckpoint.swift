import Foundation

/// Git safety net for code edits.
///
/// Before the first code edit (write_file / edit_file / apply_patch) lands in
/// a git repository within an executor's context, a snapshot of the working
/// tree is taken with `git stash create` — a dangling commit that captures all
/// tracked files without touching the index, the stash list, or the user's
/// history. The resulting SHA is appended to that edit's tool result with
/// ready-to-run review/rollback commands, and recorded in a disk ledger at
/// ~/.local/share/briglia/git_checkpoints.json so it
/// survives context pruning and app restarts.
///
/// Prunable by design, like project instructions and verification hints: when
/// the watermark pruner drops the carrying interaction, the tracker entry is
/// cleared and the NEXT edit in that repo creates a fresh checkpoint (which by
/// then also captures the agent's intermediate work — finer-grained rollback,
/// while the ledger keeps the original).
///
/// Limits: `git stash create` does not capture untracked files (brand-new
/// files need no rollback; deleting them reverts them), and repos with no
/// commits yet cannot be snapshotted.
final class GitCheckpointTracker: @unchecked Sendable {

    static let markerPrefix = "[GIT CHECKPOINT: "
    static let markerEnd = "[END GIT CHECKPOINT]"

    private static let editTools: Set<String> = ["write_file", "edit_file", "apply_patch"]

    private let lock = NSLock()
    /// Repo roots already checkpointed in this executor's context.
    private var checkpointedRoots = Set<String>()

    // MARK: - Checkpoint

    /// Called BEFORE an edit tool executes, so the snapshot captures the
    /// pre-edit state. Returns a block to append to the tool result, or nil
    /// when the repo is already checkpointed (or no repo is involved).
    func checkpointIfNeeded(toolName: String, argumentsJSON: String) -> String? {
        let touched: [String]
        if Self.editTools.contains(toolName) {
            touched = ProjectInstructionsTracker.touchedPaths(toolName: toolName, argumentsJSON: argumentsJSON)
        } else if toolName == "bash", let destructive = Self.destructiveBashPaths(argumentsJSON: argumentsJSON) {
            touched = destructive
        } else {
            return nil
        }
        guard !touched.isEmpty else { return nil }

        var blocks: [String] = []
        for path in touched {
            let rootToken = StageMarkers.enter("git.repo_root", detail: StageMarkers.basename(path))
            let foundRoot = Self.repoRoot(forTouchedPath: path)
            StageMarkers.exit(rootToken, .ok, detail: foundRoot == nil ? "no repo" : "repo")
            guard let root = foundRoot else { continue }
            let rootPath = root.path

            lock.lock()
            let inserted = checkpointedRoots.insert(rootPath).inserted
            lock.unlock()
            guard inserted else { continue }

            let snapToken = StageMarkers.enter("git.snapshot", detail: StageMarkers.basename(rootPath))
            let createdSnapshot = Self.createSnapshot(repoRoot: rootPath)
            StageMarkers.exit(snapToken, createdSnapshot == nil ? .error : .ok,
                              detail: createdSnapshot.map { $0.clean ? "clean" : "dirty" } ?? "skipped")
            guard let snapshot = createdSnapshot else { continue }
            StageMarkers.measure("git.ledger_append") {
                Self.appendToLedger(repo: rootPath, sha: snapshot.sha, clean: snapshot.clean)
            }

            let shortSha = String(snapshot.sha.prefix(12))
            let stateNote = snapshot.clean
                ? "The working tree was clean, so the checkpoint is HEAD itself."
                : "Snapshot of all tracked files (dangling commit via `git stash create`; untracked files are not included)."
            blocks.append(
                Self.markerPrefix + rootPath + " @ " + shortSha + "]\n"
                + "Pre-edit safety checkpoint for this repo. " + stateNote + "\n"
                + "- review everything you changed since: git -C \(rootPath) diff \(shortSha)\n"
                + "- restore a single file: git -C \(rootPath) checkout \(shortSha) -- <path>\n"
                + "- before reporting a multi-file change done, self-review with: git -C \(rootPath) diff --stat \(shortSha)\n"
                + "Full SHA and earlier checkpoints: ~/.local/share/briglia/git_checkpoints.json\n"
                + Self.markerEnd
            )
        }

        guard !blocks.isEmpty else { return nil }
        return "\n\n" + blocks.joined(separator: "\n\n")
    }

    /// Detects bash commands that delete or move files (rm/mv/rmdir/unlink,
    /// find -delete — incl. git rm / git mv) and returns the filesystem paths
    /// involved. With apply_patch gated off, bash is the default rename/delete
    /// path, so the pre-destruction snapshot must happen here; apply_patch's
    /// validated Delete/Move used to provide it. Biased toward over-triggering:
    /// a false positive (e.g. `docker run --rm`) just creates one harmless
    /// checkpoint, while a miss loses the rollback point.
    /// Returns nil when the command is not destructive.
    static func destructiveBashPaths(argumentsJSON: String) -> [String]? {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String else { return nil }
        let pattern = "\\b(rm|mv|rmdir|unlink)\\b|-delete\\b"
        guard command.range(of: pattern, options: .regularExpression) != nil else { return nil }

        // Candidate repo anchors: the workdir plus any absolute or ~-prefixed
        // tokens in the command (relative targets resolve via the workdir).
        var paths: [String] = []
        if let workdir = obj["workdir"] as? String { paths.append(workdir) }
        let tokens = command.components(separatedBy: CharacterSet(charactersIn: " \t\n\"'"))
        paths += tokens.filter { $0.hasPrefix("/") || $0.hasPrefix("~") }
        return paths
    }

    /// Pruner callback: the carrying interaction left the context. The next
    /// edit in this repo will create a fresh checkpoint.
    func clearCheckpoint(root: String) {
        lock.lock()
        checkpointedRoots.remove(root)
        lock.unlock()
    }

    /// Scans tool-result content for checkpoint markers, returning repo roots.
    static func markerRoots(in content: String) -> [String] {
        guard content.contains(markerPrefix) else { return [] }
        var roots: [String] = []
        var searchRange = content.startIndex..<content.endIndex
        while let prefixRange = content.range(of: markerPrefix, range: searchRange) {
            guard let closing = content.range(of: "]", range: prefixRange.upperBound..<content.endIndex) else { break }
            let inner = String(content[prefixRange.upperBound..<closing.lowerBound])
            let root = inner.components(separatedBy: " @ ").first ?? inner
            if root.hasPrefix("/") { roots.append(root) }
            searchRange = closing.upperBound..<content.endIndex
        }
        return roots
    }

    // MARK: - Git plumbing

    /// Walks up from a touched path to the directory containing `.git`
    /// (a directory for normal repos, a file for linked worktrees/submodules).
    static func repoRoot(forTouchedPath path: String) -> URL? {
        let fm = FileManager.default
        let standardized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL

        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: standardized.path, isDirectory: &isDir)
        var dir = (exists && isDir.boolValue) ? standardized : standardized.deletingLastPathComponent()

        for _ in 0..<64 {
            let dirPath = dir.path
            if dirPath == "/" { break }
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dirPath { break }
            dir = parent
        }
        return nil
    }

    struct Snapshot {
        let sha: String
        let clean: Bool
    }

    /// `git stash create` for a dirty tree; HEAD for a clean one. Returns nil
    /// when git is unavailable, the repo has no commits, or anything fails.
    static func createSnapshot(repoRoot: String) -> Snapshot? {
        // A repo with no commits can't be snapshotted (stash needs HEAD).
        guard runGit(["rev-parse", "--verify", "HEAD"], in: repoRoot) != nil else { return nil }

        if let stashSha = runGit(["stash", "create", "Briglia pre-edit checkpoint"], in: repoRoot),
           !stashSha.isEmpty {
            return Snapshot(sha: stashSha, clean: false)
        }
        // Empty output with success = clean working tree; HEAD is the checkpoint.
        if let headSha = runGit(["rev-parse", "HEAD"], in: repoRoot), !headSha.isEmpty {
            return Snapshot(sha: headSha, clean: true)
        }
        return nil
    }

    /// Minimal synchronous git runner (trusted, fixed argument set — not
    /// routed through BashTools to avoid shell/profile/secret machinery).
    /// Hard timeout so a hung git (network mount, lock contention) can never
    /// stall the executor: on expiry the process is terminated and the
    /// checkpoint is silently skipped. stdin is nulled so git can never sit
    /// waiting for input.
    static func runGit(_ args: [String], in workdir: String, timeoutSeconds: Double = 15,
                       executable: String = "/usr/bin/git") -> String? {
        // Diagnostics: the subcommand name only (never paths or messages).
        let label = args.first ?? "?"
        let runToken = StageMarkers.enter("git.run", detail: label)
        var runOutcome: StageMarkers.Outcome = .error
        var runDetail = "launch failed"
        defer { StageMarkers.exit(runToken, runOutcome, detail: runDetail) }
        let markerCall = StageMarkers.call
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workdir)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let launchToken = StageMarkers.enter("git.launch", detail: label)
        do {
            try process.run()
        } catch {
            StageMarkers.exit(launchToken, .error)
            return nil
        }
        StageMarkers.exit(launchToken, .ok)

        // Drain stdout on a background queue so a full pipe buffer can't
        // deadlock the child while we wait. The reader is BOUNDED: waiting
        // for EOF alone could last forever, because EOF needs every copy of
        // the pipe's write end closed, and a descendant of git (a hook, a
        // filter or fsmonitor helper, a daemon) can keep stdout open after
        // git itself exited (reproduced on macOS and Linux, 2026-09-28).
        let reader = BoundedPipeReader(pipe: out, label: label, call: markerCall)
        reader.start()

        let waitToken = StageMarkers.enter("git.wait_exit", detail: label)
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            StageMarkers.exit(waitToken, .error, detail: "timeout")
            let killToken = StageMarkers.enter("git.terminate_after_timeout", detail: label)
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            StageMarkers.exit(killToken, .ok)
            reader.stopNow()
            runDetail = "timeout"
            return nil
        }
        StageMarkers.exit(waitToken, .ok)
        // git has exited, so everything it wrote is already in the pipe:
        // drain what is there, then stop at EOF, at the first idle poll, or
        // at the grace deadline — whichever comes first.
        let drainToken = StageMarkers.enter("git.drain_stdout_barrier", detail: label)
        let drained = reader.finish(grace: Self.stdoutDrainGraceSeconds)
        StageMarkers.exit(drainToken, drained.reachedEOF ? .ok : .error,
                          detail: drained.reachedEOF ? "eof" : "stdout still held open by a descendant; stopped reading")
        guard process.terminationStatus == 0 else {
            runDetail = "exit \(process.terminationStatus)"
            return nil
        }
        runOutcome = .ok
        runDetail = label
        return String(data: drained.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// After git exits, the reader stops reading at EOF, at its first idle
    /// poll, or when this grace passes. It is the READER's deadline, not a
    /// strict return ceiling for `runGit`: `finish` then waits for the
    /// reader thread to acknowledge for at most `grace + 1` s (3 s) — the
    /// outer wait — so a pathological reader cannot hold the caller longer.
    static let stdoutDrainGraceSeconds: Double = 2

    /// poll(2)+read(2) reader for one pipe with a stop request and a hard
    /// deadline (the corelibs readabilityHandler/readDataToEndOfFile
    /// pitfalls do not apply). The pipe is retained until the reader thread
    /// has finished, so its descriptor can never be closed (and reused)
    /// under a read in progress.
    final class BoundedPipeReader: @unchecked Sendable {
        private let pipe: Pipe
        private let label: String
        private let call: StageMarkers.CallContext?
        private let lock = NSLock()
        private var data = Data()
        private var reachedEOF = false
        /// 0 = run until EOF; otherwise stop at the first idle poll or at
        /// this monotonic deadline.
        private var stopDeadlineNanos: UInt64 = 0
        private let done = DispatchSemaphore(value: 0)

        init(pipe: Pipe, label: String, call: StageMarkers.CallContext?) {
            self.pipe = pipe
            self.label = label
            self.call = call
        }

        func start() {
            DispatchQueue(label: "com.permaevidence.briglia.git-checkpoint.read").async { self.loop() }
        }

        private func stopDeadline() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return stopDeadlineNanos
        }

        private func loop() {
            let token = StageMarkers.enter("git.reader_read_to_eof", detail: label, call: call)
            let fd = pipe.fileHandleForReading.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var eof = false
            while true {
                let deadline = stopDeadline()
                if deadline != 0 && StageMarkers.monotonicNanos() >= deadline { break }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 {
                    // Idle: keep waiting while git runs; once a stop was
                    // requested, idle means everything git wrote is read.
                    if deadline != 0 { break }
                    continue
                }
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    lock.lock(); data.append(contentsOf: buffer[0..<n]); lock.unlock()
                } else if n == 0 {
                    eof = true
                    break
                } else if errno != EINTR && errno != EAGAIN {
                    break
                }
            }
            lock.lock(); reachedEOF = eof; lock.unlock()
            StageMarkers.exit(token, eof ? .ok : .error, detail: eof ? "eof" : "stopped before eof")
            done.signal()
        }

        /// Asks the reader to stop as soon as the pipe is idle, EOF is seen
        /// or `grace` passes (the reader grace), then waits for it at most
        /// `grace + 1` s (the outer wait) and returns what it read.
        func finish(grace: Double) -> (data: Data, reachedEOF: Bool) {
            lock.lock()
            stopDeadlineNanos = StageMarkers.monotonicNanos() + UInt64(grace * 1_000_000_000)
            lock.unlock()
            _ = done.wait(timeout: .now() + grace + 1)
            lock.lock(); defer { lock.unlock() }
            return (data, reachedEOF)
        }

        /// Timeout path: stop reading without waiting.
        func stopNow() {
            lock.lock()
            stopDeadlineNanos = StageMarkers.monotonicNanos()
            lock.unlock()
        }
    }

    // MARK: - Ledger

    struct LedgerEntry: Codable {
        let repo: String
        let sha: String
        let clean: Bool
        let timestamp: Date
    }

    private static let ledgerLock = NSLock()
    private static let maxLedgerEntries = 200

    static var ledgerURL: URL {
        let folder = StoragePaths.dataRoot
        try? PrivateStorage.ensureDirectory(folder)
        return folder.appendingPathComponent("git_checkpoints.json")
    }

    static func appendToLedger(repo: String, sha: String, clean: Bool) {
        ledgerLock.lock()
        defer { ledgerLock.unlock() }
        var entries: [LedgerEntry] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: ledgerURL),
           let decoded = try? decoder.decode([LedgerEntry].self, from: data) {
            entries = decoded
        }
        entries.append(LedgerEntry(repo: repo, sha: sha, clean: clean, timestamp: Date()))
        if entries.count > maxLedgerEntries {
            entries.removeFirst(entries.count - maxLedgerEntries)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? PrivateStorage.writeAtomically(data, to: ledgerURL)
        }
    }
}
