import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Runner for every long-running quick-setup step (brew, pip, the package
/// manager, LibreOffice, the AgentMail installer's children, service start,
/// linger) — plan §5.6. One job at a time; each child is:
///
/// - spawned BLOCKED behind a start gate (READY/RELEASE handshake through
///   the `__setsid-exec` / `__gate-exec` trampolines), so its final
///   session/process-group identity is verified and journaled durably
///   BEFORE it executes; a journal that cannot be persisted means the child
///   never runs;
/// - drained continuously (stdout+stderr), decoded statefully, redacted, and
///   teed to the terminal and to a bounded ring the page polls;
/// - terminated as a process group on timeout or cancellation, with
///   confirmed reaping; an unconfirmed survivor POISONS the runner (no job
///   may start until absence is proven or the user recovers explicitly);
/// - for terminal-handoff jobs (sudo): lent the terminal foreground between
///   the journal write and RELEASE, never after (a sudo that execs before
///   its group is foreground SIGTTIN-freezes on its first tty read).
final class SetupJobRunner: @unchecked Sendable {
    enum Mode: String, Codable { case detached, terminalHandoff }

    struct Spec {
        var row: String
        var command: [String]          // absolute executable first
        var mode: Mode
        var timeout: TimeInterval
        var environment: [String: String] = [:]
        var label: String
    }

    struct Survivor: Codable, Equatable {
        var pid: Int32
        var startTime: UInt64
        var note: String?
    }

    /// The active-job journal (`quicksetup.job.json`): identity of the child
    /// so a later process can tell "still that job" from "pid reused".
    struct Journal: Codable, Equatable {
        var version = 1
        var pid: Int32
        var pgid: Int32
        var sid: Int32
        var startTime: UInt64
        var bootID: String?
        var mode: Mode
        var command: [String]
        var row: String
        var startedAt: Date
        /// Set when reaping could not be confirmed (poison state).
        var poisoned: Bool?
        var survivors: [Survivor]?
        var enumerationFailed: Bool?
        var poisonedAt: Date?
    }

    enum Outcome: Equatable {
        case exited(Int32)
        case signaled(Int32)
        case timedOut
        case cancelled
        case failedToStart(String)
    }

    struct Result {
        var outcome: Outcome
        /// Reaping could not be confirmed: the runner is now poisoned.
        var survivors: [Survivor]?
        var enumerationFailed = false
        /// The last lines this job wrote (redacted), never another job's.
        var lastLines: [String]
        var ok: Bool { outcome == .exited(0) && survivors == nil && !enumerationFailed }
        /// A short, page-sized excerpt of `lastLines` for a failed row: blank
        /// lines dropped, at most `excerptMaxLines`, each cut to `excerptMaxChars`.
        var excerpt: [String] { Result.excerpt(of: lastLines) }
        static let excerptMaxLines = 8
        static let excerptMaxChars = 240
        static func excerpt(of lines: [String]) -> [String] {
            let kept = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return kept.suffix(excerptMaxLines).map { $0.count > excerptMaxChars ? String($0.prefix(excerptMaxChars)) + "…" : $0 }
        }
        var failureReason: String? {
            if survivors != nil || enumerationFailed { return "the step's processes could not be confirmed gone — see the survivors" }
            switch outcome {
            case .exited(0): return nil
            case .exited(let code): return "exited with status \(code)"
            case .signaled(let sig): return "killed by signal \(sig)"
            case .timedOut: return "timed out"
            case .cancelled: return "cancelled"
            case .failedToStart(let why): return why
            }
        }
    }

    struct Poison: Equatable {
        var row: String
        var command: [String]
        var pgid: Int32
        var bootID: String?
        var survivors: [Survivor]
        var enumerationFailed: Bool
        var unreadableJournal: String?
    }

    struct RunningJob {
        var row: String
        var label: String
        var pid: Int32
        var startedAt: Date
    }

    // MARK: - Seams (selftest)

    nonisolated(unsafe) static var journalURLOverride: URL?
    /// Inject a journal persist failure: the blocked child must never run.
    nonisolated(unsafe) static var injectJournalWriteFailure = false
    /// Send this byte instead of the RELEASE byte (child must exit 125).
    nonisolated(unsafe) static var releaseByteOverride: UInt8?
    /// Skip the foreground lend for handoff jobs (proves the order matters).
    nonisolated(unsafe) static var skipLendForTest = false
    /// Force the trampoline into a process group of its own for DETACHED
    /// jobs too, so `setsid()` fails with EPERM and the posix_spawn fallback
    /// path (re-spawned `__gate-exec` leader) is exercised.
    nonisolated(unsafe) static var forceSetsidFallbackForTest = false
    /// Deadline for the READY line.
    nonisolated(unsafe) static var readyDeadline: TimeInterval = 10
    /// Post-kill scan window for surviving group members.
    nonisolated(unsafe) static var reapScanWindow: TimeInterval = 15
    nonisolated(unsafe) static var termGrace: TimeInterval = 5
    /// Observed by the selftest: called right after the journal is durable
    /// and before RELEASE (ordering proof), with the journal's pid.
    nonisolated(unsafe) static var onJournalPersisted: ((Int32) -> Void)?
    /// The trampoline host executable (defaults to this binary).
    nonisolated(unsafe) static var selfExecutableOverride: String?

    static var journalURL: URL {
        journalURLOverride ?? StoragePaths.dataRoot.appendingPathComponent("quicksetup.job.json")
    }

    // MARK: - State

    /// Enter-listener control for handoff jobs: suspended before the lend,
    /// resumed after the terminal is restored.
    var listener: StdinListenerControl?
    /// Terminal tee.
    var onLine: ((String) -> Void)?

    private let lock = NSLock()
    private var running: RunningJob?
    private var cancelRequested = false
    private var poison: Poison?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Bounded ring of redacted output lines (last 200 lines / 32 KiB).
    static let ringMaxLines = 200
    static let ringMaxBytes = 32 * 1024
    private var ring: [String] = []
    private var ringBytes = 0
    /// Absolute offset of ring[0].
    private var ringStart = 0
    /// Absolute offset of the first line written after the current job started;
    /// `lastLines` is scoped to it so a step never reports its predecessor's output.
    private var jobStartOffset = 0
    private let extraSecrets: [String: String]

    /// `secrets`: the keys of this run (label → value), redacted from every
    /// output line together with the stored redaction set.
    init(secrets: [String: String] = [:]) {
        self.extraSecrets = secrets
    }

    // MARK: - Public surface

    var currentJob: RunningJob? { lock.lock(); defer { lock.unlock() }; return running }
    var currentPoison: Poison? { lock.lock(); defer { lock.unlock() }; return poison }
    var isPoisoned: Bool { currentPoison != nil }

    /// Output lines since `offset` (absolute line index) and the next offset.
    func lines(since offset: Int) -> (lines: [String], next: Int) {
        lock.lock(); defer { lock.unlock() }
        let end = ringStart + ring.count
        if offset >= end { return ([], end) }
        let from = max(offset, ringStart) - ringStart
        return (Array(ring[from...]), end)
    }

    func appendLine(_ line: String) {
        lock.lock()
        ring.append(line)
        ringBytes += line.utf8.count
        while ring.count > Self.ringMaxLines || ringBytes > Self.ringMaxBytes, !ring.isEmpty {
            ringBytes -= ring.removeFirst().utf8.count
            ringStart += 1
        }
        lock.unlock()
        onLine?(line)
    }

    /// Ask the running job (if any) to stop, and wait until the runner has
    /// reaped it or given up. Returns the poison state, if reaping could not
    /// be confirmed.
    func cancelRunning() async -> Poison? {
        lock.lock()
        guard running != nil else {
            let p = poison
            lock.unlock()
            return p
        }
        cancelRequested = true
        lock.unlock()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if running == nil {
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
        return currentPoison
    }

    /// Run one job to completion. Refuses while another job runs or while
    /// poisoned. Honours `Task` cancellation (kills the group, reaps).
    func run(_ spec: Spec) async -> Result {
        lock.lock()
        if let poison {
            lock.unlock()
            return Result(outcome: .failedToStart("the previous step's processes are not confirmed gone (poisoned) — recover first"),
                          survivors: poison.survivors, enumerationFailed: poison.enumerationFailed, lastLines: [])
        }
        if running != nil {
            lock.unlock()
            return Result(outcome: .failedToStart("another step is still running"), lastLines: [])
        }
        cancelRequested = false
        running = RunningJob(row: spec.row, label: spec.label, pid: 0, startedAt: Date())
        jobStartOffset = ringStart + ring.count
        lock.unlock()

        let result: Result = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                Thread.detachNewThread { [self] in
                    let r = self.execute(spec)
                    cont.resume(returning: r)
                }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelRequested = true
            self.lock.unlock()
        }

        lock.lock()
        running = nil
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pending { w.resume() }
        return result
    }

    // MARK: - Poison management

    /// Preflight of a new `briglia quicksetup` (and the constrained resume):
    /// inherit the poison state of a leftover journal. Alive → poisoned;
    /// gone (identity mismatch, different boot, ESRCH on the group) → the
    /// journal is deleted; unreadable → poisoned, fail closed.
    @discardableResult
    static func inheritLeftoverJournal(into runner: SetupJobRunner) -> Poison? {
        let url = journalURL
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let journal: Journal
        do {
            let data = try Data(contentsOf: url)
            journal = try JSONDecoder.iso.decode(Journal.self, from: data)
        } catch {
            let p = Poison(row: "?", command: [], pgid: 0, bootID: nil, survivors: [],
                           enumerationFailed: true,
                           unreadableJournal: "\(url.path) cannot be read or parsed (\(error)) — a step of a previous run may still be running; inspect it, then delete the file to continue")
            runner.setPoison(p)
            return p
        }
        let identities = [Survivor(pid: journal.pid, startTime: journal.startTime, note: "job leader")]
            + (journal.survivors ?? []).filter { $0.pid != journal.pid }
        if let verdict = provenGone(pgid: journal.pgid, bootID: journal.bootID, identities: identities) {
            if verdict.gone {
                deleteJournal()
                return nil
            }
            let p = Poison(row: journal.row, command: journal.command, pgid: journal.pgid, bootID: journal.bootID,
                           survivors: verdict.alive, enumerationFailed: false, unreadableJournal: nil)
            runner.setPoison(p)
            persistPoison(journal: journal, survivors: verdict.alive, enumerationFailed: false)
            return p
        }
        let p = Poison(row: journal.row, command: journal.command, pgid: journal.pgid, bootID: journal.bootID,
                       survivors: identities, enumerationFailed: true, unreadableJournal: nil)
        runner.setPoison(p)
        persistPoison(journal: journal, survivors: identities, enumerationFailed: true)
        return p
    }

    /// Identity-checked re-probe. Returns the new state (nil = cleared).
    func recheckPoison() -> Poison? {
        lock.lock()
        guard var p = poison else { lock.unlock(); return nil }
        lock.unlock()
        if p.unreadableJournal != nil {
            // Only the user's manual deletion of the file clears this one.
            var st = stat()
            if lstat(Self.journalURL.path, &st) != 0 {
                setPoison(nil)
                return nil
            }
            return p
        }
        if let verdict = Self.provenGone(pgid: p.pgid, bootID: p.bootID, identities: p.survivors) {
            if verdict.gone {
                Self.deleteJournal()
                setPoison(nil)
                return nil
            }
            p.survivors = verdict.alive
            p.enumerationFailed = false
        } else {
            p.enumerationFailed = true
        }
        setPoison(p)
        return p
    }

    /// Terminal recovery "K": SIGKILL every recorded survivor whose identity
    /// still matches (never a reused pid), then re-check.
    func signalSurvivorsAndRecheck() -> Poison? {
        guard let p = currentPoison, p.unreadableJournal == nil else { return currentPoison }
        if let alive = ManagedPlaywright.ProcessGroups.stillAlive(
            p.survivors.map { .init(pid: $0.pid, startTime: $0.startTime) }) {
            for id in alive { kill(id.pid, SIGKILL) }
        }
        // Group signal as well: identity-matching members outside the record.
        if p.pgid > 0, let members = ManagedPlaywright.ProcessGroups.members(of: p.pgid) {
            for m in members where !m.zombie { kill(m.identity.pid, SIGKILL) }
        }
        Thread.sleep(forTimeInterval: 0.3)
        return recheckPoison()
    }

    private func setPoison(_ p: Poison?) {
        lock.lock(); poison = p; lock.unlock()
    }

    /// nil = enumeration failed AND the group signal could not prove absence.
    private static func provenGone(pgid: Int32, bootID: String?, identities: [Survivor])
        -> (gone: Bool, alive: [Survivor])? {
        if let bootID, let now = ManagedPlaywright.ProcessGroups.bootID(), bootID != now {
            return (true, [])
        }
        let ids = identities.map { ManagedPlaywright.ProcessGroups.Identity(pid: $0.pid, startTime: $0.startTime) }
        if let alive = ManagedPlaywright.ProcessGroups.stillAlive(ids) {
            var survivors = identities.filter { s in alive.contains { $0.pid == s.pid && $0.startTime == s.startTime } }
            // Descendants FAIL CLOSED (Codex, round 1): apt/dpkg/brew can
            // outlive the journaled leader (sudo, the shell). Every live
            // member of the recorded group that started no earlier than the
            // leader is a survivor, leader alive or not; an unrelated process
            // that reused the pgid after a reboot is excluded by the boot id,
            // and one that reused it within the boot is reported and needs
            // explicit recovery rather than being silently cleared.
            if pgid > 0, let members = ManagedPlaywright.ProcessGroups.members(of: pgid) {
                let leader = identities.first
                let leaderStart = leader?.startTime ?? 0
                for m in members where !m.zombie && m.identity.startTime >= leaderStart
                    && !survivors.contains(where: { $0.pid == m.identity.pid }) {
                    // The leader's own pid with a different start time is the
                    // leader SLOT reused by an unrelated process (only the
                    // leader can have pid == pgid): identity says gone.
                    // Any other member is a descendant that outlived it.
                    if m.identity.pid == pgid, let leader, m.identity.startTime != leader.startTime { continue }
                    survivors.append(Survivor(pid: m.identity.pid, startTime: m.identity.startTime, note: "group member"))
                }
            }
            return (survivors.isEmpty, survivors)
        }
        if pgid > 0, kill(-pgid, 0) == -1, errno == ESRCH { return (true, []) }
        return nil
    }

    private static func persistPoison(journal: Journal, survivors: [Survivor], enumerationFailed: Bool) {
        var j = journal
        j.poisoned = true
        j.survivors = survivors
        j.enumerationFailed = enumerationFailed
        j.poisonedAt = Date()
        if let data = try? JSONEncoder.iso.encode(j) {
            _ = try? PrivateStorage.writeAtomically(data, to: journalURL, mode: 0o600)
        }
    }

    private static func deleteJournal() {
        let url = journalURL
        unlink(url.path)
        try? PrivateStorage.fsyncDirectory(url.deletingLastPathComponent().path)
    }

    // MARK: - Execution (blocking, on its own thread)

    private func execute(_ spec: Spec) -> Result {
        // Pipes: ready (child→parent), release (parent→child), stdout, stderr.
        var ready: [Int32] = [-1, -1], release: [Int32] = [-1, -1]
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&ready) == 0, pipe(&release) == 0, pipe(&out) == 0, pipe(&err) == 0 else {
            return Result(outcome: .failedToStart("pipe() failed: \(String(cString: strerror(errno)))"), lastLines: [])
        }
        for fd in [ready[0], ready[1], release[0], release[1], out[0], out[1], err[0], err[1]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        // Stable child-side numbers (3/4) so the trampoline's arguments do not
        // depend on which fds the parent happened to get; dup2 in the child
        // clears close-on-exec on the target only.
        let childReadyFd: Int32 = 3, childReleaseFd: Int32 = 4
        // Parent-side copies above 10 so a dup2 target never equals its source.
        let readyW = fcntl(ready[1], F_DUPFD_CLOEXEC, 10)
        let releaseR = fcntl(release[0], F_DUPFD_CLOEXEC, 10)
        let outW = fcntl(out[1], F_DUPFD_CLOEXEC, 10)
        let errW = fcntl(err[1], F_DUPFD_CLOEXEC, 10)
        close(ready[1]); close(release[0]); close(out[1]); close(err[1])
        let readyR = ready[0], releaseW = release[1], outR = out[0], errR = err[0]
        var parentClosed = false
        func closeChildEnds() {
            guard !parentClosed else { return }
            parentClosed = true
            close(readyW); close(releaseR); close(outW); close(errW)
        }
        defer { close(readyR); close(outR); close(errR); closeChildEnds() }

        let selfPath = Self.selfExecutableOverride
            ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                .resolvingSymlinksInPath().path
        let trampoline = spec.mode == .detached ? "__setsid-exec" : "__gate-exec"
        let argv = [selfPath, trampoline, "--ready-fd", "\(childReadyFd)", "--release-fd", "\(childReleaseFd)", "--"]
            + spec.command
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        defer { for p in cargs { free(p) } }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BashTools.augmentedPath(env["PATH"])
        for (k, v) in spec.environment { env[k] = v }
        var cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)
        defer { for p in cenv { free(p) } }

        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #else
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        posix_spawn_file_actions_adddup2(&actions, readyW, childReadyFd)
        posix_spawn_file_actions_adddup2(&actions, releaseR, childReleaseFd)
        posix_spawn_file_actions_adddup2(&actions, outW, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errW, STDERR_FILENO)
        if spec.mode == .detached {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        var defaultSigs = sigset_t()
        sigfillset(&defaultSigs)
        posix_spawnattr_setsigdefault(&attr, &defaultSigs)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        var flags = Int16(POSIX_SPAWN_SETSIGDEF) | Int16(POSIX_SPAWN_SETSIGMASK)
        // Handoff jobs: own process group (pgid == pid) in OUR session, so
        // the terminal can be lent to it. Detached jobs: plain child; the
        // trampoline's setsid() makes it a session leader (or falls back).
        if spec.mode == .terminalHandoff || Self.forceSetsidFallbackForTest {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attr, 0)
        }
        posix_spawnattr_setflags(&attr, flags)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, selfPath, &actions, &attr, cargs, cenv)
        closeChildEnds()
        guard rc == 0 else {
            close(releaseW)
            return Result(outcome: .failedToStart("spawn failed: \(String(cString: strerror(rc)))"), lastLines: [])
        }
        lock.lock(); running?.pid = pid; lock.unlock()

        // READY line, strictly parsed and verified against the process table.
        var releaseClosed = false
        func refuse(_ why: String) -> Result {
            // Close the release pipe UNWRITTEN: the child exits 125 without
            // executing. Reap it (and, on the fallback path, its leader).
            if !releaseClosed { close(releaseW); releaseClosed = true }
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let r = waitpid(pid, &status, WNOHANG)
                if r == pid || (r == -1 && errno == ECHILD) { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return Result(outcome: .failedToStart(why), lastLines: snapshotLines())
        }
        guard let line = Self.readLine(fd: readyR, deadline: Self.readyDeadline) else {
            return refuse("the step's process did not report READY within \(Int(Self.readyDeadline)) s")
        }
        let parts = line.split(separator: " ")
        guard parts.count == 4, parts[0] == "READY",
              let rpid = Int32(parts[1]), let rpgid = Int32(parts[2]), let rsid = Int32(parts[3]) else {
            return refuse("malformed READY line from the step's process")
        }
        guard kill(rpid, 0) == 0 else { return refuse("READY names a pid that is not alive") }
        guard getpgid(rpid) == rpgid, getsid(rpid) == rsid else {
            return refuse("READY identity does not match the process table")
        }
        switch spec.mode {
        case .detached:
            guard rpgid == rpid, rsid == rpid else { return refuse("detached step is not a session leader") }
        case .terminalHandoff:
            guard rpgid == rpid, rsid == getsid(0) else { return refuse("terminal step is not a group leader in this session") }
        }
        guard let members = ManagedPlaywright.ProcessGroups.members(of: rpgid),
              let leader = members.first(where: { $0.identity.pid == rpid }) else {
            return refuse("cannot read the process table to journal the step")
        }
        let journal = Journal(pid: rpid, pgid: rpgid, sid: rsid, startTime: leader.identity.startTime,
                              bootID: ManagedPlaywright.ProcessGroups.bootID(), mode: spec.mode,
                              command: spec.command, row: spec.row, startedAt: Date())
        do {
            if Self.injectJournalWriteFailure { throw NSError(domain: "briglia.quicksetup", code: 1,
                                                                 userInfo: [NSLocalizedDescriptionKey: "injected journal write failure"]) }
            let data = try JSONEncoder.iso.encode(journal)
            try PrivateStorage.ensureDirectory(Self.journalURL.deletingLastPathComponent())
            _ = try PrivateStorage.writeAtomically(data, to: Self.journalURL, mode: 0o600)
        } catch {
            // Identity known, it never ran: kill it too, belt and braces.
            let r = refuse("could not persist the job journal: \(error.localizedDescription)")
            kill(-rpgid, SIGKILL)
            return r
        }
        Self.onJournalPersisted?(rpid)

        // Terminal handoff: lend the foreground BEFORE release.
        var lend: TerminalHandoff.ForegroundLend?
        var listenerSuspended = false
        if spec.mode == .terminalHandoff && !Self.skipLendForTest {
            listener?.suspend()
            listenerSuspended = true
            do {
                lend = try TerminalHandoff.lendForeground(toPGID: rpgid)
            } catch {
                let r = refuse("terminal handoff failed: \(error)")
                listener?.resume()
                return r
            }
        }
        defer {
            lend?.restore()
            if listenerSuspended { listener?.resume() }
        }

        // RELEASE.
        var byte = Self.releaseByteOverride ?? StartGate.releaseByte
        _ = write(releaseW, &byte, 1)
        close(releaseW); releaseClosed = true

        // Drain + wait.
        let outcome = drainAndWait(pid: rpid, pgid: rpgid, outR: outR, errR: errR, deadline: Date().addingTimeInterval(spec.timeout))

        // Conclusive reaping of the whole group.
        let (survivors, enumerationFailed) = confirmGroupGone(pgid: rpgid, leader: leader.identity)
        if survivors.isEmpty && !enumerationFailed {
            Self.deleteJournal()
            return Result(outcome: outcome, lastLines: snapshotLines())
        }
        let p = Poison(row: spec.row, command: spec.command, pgid: rpgid, bootID: journal.bootID,
                       survivors: survivors, enumerationFailed: enumerationFailed, unreadableJournal: nil)
        setPoison(p)
        Self.persistPoison(journal: journal, survivors: survivors, enumerationFailed: enumerationFailed)
        return Result(outcome: outcome, survivors: survivors, enumerationFailed: enumerationFailed, lastLines: snapshotLines())
    }

    private func snapshotLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let from = max(jobStartOffset, ringStart) - ringStart
        guard from < ring.count else { return [] }
        return Array(ring[from...].suffix(20))
    }

    private static func readLine(fd: Int32, deadline: TimeInterval) -> String? {
        var buf = [UInt8]()
        let end = Date().addingTimeInterval(deadline)
        var byte: UInt8 = 0
        while Date() < end, buf.count < 256 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, 50)
            if rc < 0 { if errno == EINTR { continue }; return nil }
            if rc == 0 { continue }
            let n = read(fd, &byte, 1)
            if n == 1 {
                if byte == 0x0A { return String(decoding: buf, as: UTF8.self) }
                buf.append(byte)
                continue
            }
            if n == 0 { return nil }  // EOF before a full line
            if errno == EINTR || errno == EAGAIN { continue }
            return nil
        }
        return nil
    }

    private func drainAndWait(pid: Int32, pgid: Int32, outR: Int32, errR: Int32, deadline: Date) -> Outcome {
        for fd in [outR, errR] {
            let fl = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        }
        let sinks = [LineSink(runner: self, secrets: extraSecrets), LineSink(runner: self, secrets: extraSecrets)]
        var open = [true, true]
        var exitStatus: Int32?
        var exitedAt: Date?
        var killed: Outcome?
        var buf = [UInt8](repeating: 0, count: 65_536)

        func pump() {
            var fds = [pollfd(fd: open[0] ? outR : -1, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: open[1] ? errR : -1, events: Int16(POLLIN), revents: 0)]
            let rc = poll(&fds, 2, 50)
            guard rc > 0 else { return }
            for i in 0..<2 where open[i] {
                let ev = Int32(fds[i].revents)
                guard ev & (Int32(POLLIN) | Int32(POLLHUP) | Int32(POLLERR)) != 0 else { continue }
                let n = buf.withUnsafeMutableBytes { read(fds[i].fd, $0.baseAddress, $0.count) }
                if n > 0 { sinks[i].ingest(Data(bytes: buf, count: n)) }
                else if n == 0 { sinks[i].finish(); open[i] = false }
                else if errno != EINTR && errno != EAGAIN { sinks[i].finish(); open[i] = false }
            }
        }
        func terminateGroup(reason: Outcome) {
            guard killed == nil else { return }
            killed = reason
            kill(-pgid, SIGTERM)
            let grace = Date().addingTimeInterval(Self.termGrace)
            var status: Int32 = 0
            while Date() < grace {
                let r = waitpid(pid, &status, WNOHANG)
                if r == pid { exitStatus = status; exitedAt = Date(); return }
                if r == -1 && errno == ECHILD { exitedAt = Date(); return }
                pump()
            }
            kill(-pgid, SIGKILL)
        }

        while exitStatus == nil {
            pump()
            var status: Int32 = 0
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { exitStatus = status; exitedAt = Date(); break }
            if r == -1 && errno == ECHILD { exitedAt = Date(); break }
            lock.lock(); let cancel = cancelRequested; lock.unlock()
            if killed == nil {
                if cancel { terminateGroup(reason: .cancelled) }
                else if Date() >= deadline { terminateGroup(reason: .timedOut) }
            }
        }
        // Post-exit drain: to EOF, or until the pipe is idle (an orphan
        // writer holding it open), bounded.
        let hardCap = (exitedAt ?? Date()).addingTimeInterval(5)
        var lastData = Date()
        while (open[0] || open[1]) && Date() < hardCap {
            let before = sinks[0].bytes + sinks[1].bytes
            pump()
            if sinks[0].bytes + sinks[1].bytes != before { lastData = Date() }
            else if Date().timeIntervalSince(lastData) > 0.2 { break }
        }
        for s in sinks { s.finish() }
        if let killed { return killed }
        guard let st = exitStatus else { return .exited(0) }
        let sig = st & 0x7f
        if sig != 0 { return .signaled(sig) }
        return .exited((st >> 8) & 0xff)
    }

    /// After the leader exited: prove the whole group is gone. Live members
    /// get SIGTERM/SIGKILL (they belong to this job) and the scan repeats
    /// within the window; anything left, or an enumeration failure that the
    /// group signal cannot settle, is a survivor list.
    private func confirmGroupGone(pgid: Int32, leader: ManagedPlaywright.ProcessGroups.Identity)
        -> (survivors: [Survivor], enumerationFailed: Bool) {
        let end = Date().addingTimeInterval(Self.reapScanWindow)
        var signaled = false
        while true {
            if let members = ManagedPlaywright.ProcessGroups.members(of: pgid) {
                let live = members.filter { !$0.zombie }
                if live.isEmpty { return ([], false) }
                if !signaled {
                    kill(-pgid, SIGTERM)
                    signaled = true
                } else {
                    kill(-pgid, SIGKILL)
                }
                if Date() >= end {
                    return (live.map { Survivor(pid: $0.identity.pid, startTime: $0.identity.startTime, note: nil) }, false)
                }
            } else {
                if kill(-pgid, 0) == -1 && errno == ESRCH { return ([], false) }
                if Date() >= end {
                    return ([Survivor(pid: leader.pid, startTime: leader.startTime, note: "enumeration failed")], true)
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - Line sink

    private final class LineSink {
        private var decoder = IncrementalUTF8Decoder()
        private let redactor: StreamingRedactor
        private var partial = ""
        private unowned let runner: SetupJobRunner
        private(set) var bytes = 0
        private var finished = false

        init(runner: SetupJobRunner, secrets: [String: String]) {
            self.runner = runner
            var env = KeychainHelper.redactionEnvironment()
            for (k, v) in secrets where !v.isEmpty { env["quicksetup." + k] = v }
            self.redactor = StreamingRedactor(environment: env)
        }

        func ingest(_ data: Data) {
            bytes += data.count
            emit(redactor.process(decoder.decode(data)))
        }

        func finish() {
            guard !finished else { return }
            finished = true
            emit(redactor.process(decoder.flush()) + redactor.flush())
            if !partial.isEmpty {
                runner.appendLine(partial)
                partial = ""
            }
        }

        private func emit(_ text: String) {
            guard !text.isEmpty else { return }
            partial += text
            while let nl = partial.firstIndex(of: "\n") {
                let line = String(partial[..<nl]).replacingOccurrences(of: "\r", with: "")
                partial = String(partial[partial.index(after: nl)...])
                runner.appendLine(line)
            }
            // Carriage-return progress lines (brew/pip/apt): keep only the tail.
            if partial.count > 4096 {
                runner.appendLine(String(partial.suffix(4096)))
                partial = ""
            }
        }
    }
}

/// Quick setup's "press Enter for a new link" listener; the runner suspends
/// it before lending the terminal to a sudo child (TerminalHandoff forbids
/// concurrent stdin readers) and resumes it afterwards.
protocol StdinListenerControl: AnyObject {
    func suspend()
    func resume()
}
