import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// File claims (MULTI_ASSISTANT_PLAN §7.3 as amended by A2).
///
/// - Made only by Briglia's edit tools (`write_file`, `edit_file`,
///   `apply_patch`), for every affected path. They block only those tools in
///   other assistants; Bash and reads are never refused.
/// - Store: `briglia-shared/claims/<profile>.json`, one file per assistant,
///   decisions and writes under `briglia-shared/claims.lock` (2 s).
/// - Lifetime (A2): a `held` claim belongs to the scopes that were open when
///   the edit settled: the running turn, or (after it ended) the set of jobs
///   still running when it ended. It is released as soon as all of them
///   end; nothing ages by the clock. A crash or stop frees everything at
///   once: entries of a dead member lease are ignored by every reader and
///   dropped by the owner's next write.
enum FileClaims {
    static let reserved = "reserved"
    static let held = "held"
    static let lockWaitSeconds: Double = 2
    nonisolated(unsafe) static var maxEntries = 2000

    struct Claim: Codable, Equatable {
        var path: String
        var state: String
        var opId: String
        var lease: String
        var incarnation: String
        var scopes: [String]
        var wasHeld: Bool?
        var reservedAt: Date
        var lastEditAt: Date?
    }

    struct Document: Codable, Equatable {
        var version: Int = 1
        var profile: String
        var claims: [Claim]
    }

    struct Refusal: Error, Equatable { let message: String }

    // MARK: Reading

    static func read(_ url: URL) -> Document? {
        guard let data = MultiAssistant.readSmall(url, max: 4 * 1024 * 1024),
              let doc = try? MultiAssistant.decoder.decode(Document.self, from: data), doc.version == 1 else { return nil }
        return doc
    }

    /// A peer's claims that still protect a file: its lease is not dead.
    static func claims(of peer: MultiAssistant.Peer, _ ctx: MultiAssistant.Context) -> [Claim] {
        guard let doc = read(ctx.paths.claimsFile(peer.profile)), doc.profile == peer.profile else { return [] }
        return doc.claims.filter { peer.probe(lease: $0.lease) != .dead }
    }

    /// This process's own live claims.
    static func claims(ofSelf ctx: MultiAssistant.Context) -> [Claim] {
        (read(ctx.paths.claimsFile(ctx.me.profile))?.claims ?? []).filter { $0.lease == ctx.me.lease }
    }

    struct Owned: Equatable { var path: String; var peer: MultiAssistant.Peer; var claim: Claim }

    /// Every file another assistant claims right now (tripwire, heads-ups).
    static func othersClaimed(_ ctx: MultiAssistant.Context) -> [Owned] {
        var out: [Owned] = []
        for peer in ctx.peers {
            for c in claims(of: peer, ctx) { out.append(Owned(path: c.path, peer: peer, claim: c)) }
        }
        return out
    }

    // MARK: Locked mutation

    static func withLock<T>(_ ctx: MultiAssistant.Context, _ body: () throws -> T) throws -> T {
        try MultiAssistant.ensure(ctx.paths.claimsDir)
        switch ProfileFileLock.take(ctx.paths.claimsLock, waitSeconds: lockWaitSeconds) {
        case .acquired(let lock):
            defer { lock.release() }
            return try body()
        case .busy:
            throw Refusal(message: "edit refused: another assistant's file bookkeeping is busy; nothing was changed — try again in a moment.")
        case .failed(let why):
            throw Refusal(message: "edit refused: the shared file-claims lock cannot be used (\(why)); nothing was changed.")
        }
    }

    /// Own document with stale entries (an earlier lease of this profile)
    /// removed.
    static func loadOwn(_ ctx: MultiAssistant.Context) -> Document {
        var doc = read(ctx.paths.claimsFile(ctx.me.profile)) ?? Document(profile: ctx.me.profile, claims: [])
        doc.profile = ctx.me.profile
        doc.claims.removeAll { $0.lease != ctx.me.lease }
        return doc
    }

    static func saveOwn(_ doc: Document, _ ctx: MultiAssistant.Context) throws {
        let url = ctx.paths.claimsFile(ctx.me.profile)
        if doc.claims.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        _ = try PrivateStorage.writeAtomically(try MultiAssistant.encoder.encode(doc), to: url, mode: 0o600)
    }

    // MARK: §7.3 steps 2 and 4

    /// Reserve `paths` (canonical) for operation `opId`, or refuse without
    /// changing anything.
    static func reserve(_ ctx: MultiAssistant.Context, paths: [String], opId: String, now: Date = MultiAssistant.now) throws {
        try withLock(ctx) {
            for path in paths {
                // §7.4: another assistant's own state and the shared folder.
                if MultiAssistant.isInside(path, MultiAssistant.canonical(ctx.paths.shared.path)) {
                    throw Refusal(message: "edit refused: \(MultiAssistant.q(MultiAssistant.display(path), 120)) is inside Briglia's shared coordination folder; Briglia does not edit it with file tools.")
                }
                for peer in ctx.peers where peer.stateRoots.contains(where: { MultiAssistant.isInside(path, $0) }) {
                    throw Refusal(message: "edit refused: \(MultiAssistant.q(MultiAssistant.display(path), 120)) belongs to the assistant \(MultiAssistant.q(peer.displayName, 40)); Briglia does not edit another assistant's memory or settings.")
                }
            }
            for peer in ctx.peers {
                for c in claims(of: peer, ctx) where paths.contains(c.path) {
                    throw Refusal(message: refusalText(path: c.path, owner: peer.displayName, claim: c, now: now))
                }
            }
            var doc = loadOwn(ctx)
            // Codex stage-3 S3-R2-2: an entry still reserved by ANOTHER live
            // operation of this assistant belongs to an edit whose settlement
            // is not recorded yet; taking it over would lose that edit's
            // identity (and with it a successful change). Refuse instead.
            for path in paths {
                if let c = doc.claims.first(where: { $0.path == path }), c.state == reserved, c.opId != opId {
                    throw Refusal(message: "edit refused: another of your edits on \(MultiAssistant.q(MultiAssistant.display(path), 120)) is still being recorded; try again in a moment. Nothing was changed.")
                }
            }
            var additions = 0
            for path in paths {
                if let i = doc.claims.firstIndex(where: { $0.path == path }) {
                    var c = doc.claims[i]
                    if c.state == held { c.wasHeld = true }
                    c.state = reserved; c.opId = opId; c.reservedAt = now
                    doc.claims[i] = c
                } else {
                    additions += 1
                    doc.claims.append(Claim(path: path, state: reserved, opId: opId, lease: ctx.me.lease,
                                            incarnation: ctx.me.incarnation, scopes: [], wasHeld: nil,
                                            reservedAt: now, lastEditAt: nil))
                }
            }
            if doc.claims.count > maxEntries, additions > 0 {
                throw Refusal(message: "edit refused: too many files claimed by this assistant (\(maxEntries)); finish the current work or release claims with the board tool (action=release).")
            }
            try saveOwn(doc, ctx)
        }
    }

    static func refusalText(path: String, owner: String, claim: Claim, now: Date) -> String {
        let name = MultiAssistant.q(owner, 40)
        if claim.state == reserved {
            return "edit refused: \(MultiAssistant.q(MultiAssistant.display(path), 120)) is being changed by the assistant \(name) right now; try again in a moment. Nothing was changed."
        }
        let when = claim.lastEditAt.map { " (last change \(MultiAssistant.clock($0)), \(MultiAssistant.minutesAgo($0, now: now)))" } ?? ""
        return "edit refused: \(MultiAssistant.q(MultiAssistant.display(path), 120)) is being edited by the assistant \(name)\(when). It frees up as soon as \(name)'s current turn and the jobs it started end. Work on a copy, choose another file, or tell the user. Nothing was changed."
    }

    /// Settle operation `opId`: `changed` → held under `scopes`; otherwise
    /// the new reservations go and previously held paths stay held. Matches
    /// by `opId` only.
    ///
    /// Codex stage-3 S3-2: only scopes that are STILL open (read under the
    /// claims lock, where every closure also runs) are kept, for the new
    /// scopes and for the ones the entry already had; an entry left with no
    /// open scope is released at once. A late settlement can therefore never
    /// resurrect a closed turn.
    static func settle(_ ctx: MultiAssistant.Context, opId: String, changed: Bool, scopes: [String], now: Date = MultiAssistant.now,
                       open: () -> Set<String> = { ClaimScopes.shared.openScopes() }) throws {
        try withLock(ctx) {
            let openNow = open()
            var doc = loadOwn(ctx)
            var out: [Claim] = []
            for var c in doc.claims {
                guard c.opId == opId, c.state == reserved else { out.append(c); continue }
                let kept = Set(c.scopes).intersection(openNow)
                if changed {
                    c.state = held; c.lastEditAt = now
                    c.scopes = Array(kept.union(Set(scopes).intersection(openNow))).sorted()
                    c.wasHeld = nil
                    if !c.scopes.isEmpty { out.append(c) }
                } else if c.wasHeld == true, !kept.isEmpty {
                    c.state = held; c.wasHeld = nil; c.scopes = Array(kept).sorted()
                    out.append(c)
                }
            }
            doc.claims = out
            try saveOwn(doc, ctx)
        }
    }

    /// A scope closed: held claims lose it; claims with no scope left go.
    static func releaseScope(_ ctx: MultiAssistant.Context, _ scope: String) throws {
        try withLock(ctx) {
            var doc = loadOwn(ctx)
            var out: [Claim] = []
            for var c in doc.claims {
                if c.scopes.contains(scope) {
                    c.scopes.removeAll { $0 == scope }
                    // A reservation stays (still protective) until its
                    // operation settles; it just no longer carries the scope.
                    if c.state == held, c.scopes.isEmpty { continue }
                }
                out.append(c)
            }
            guard out != doc.claims else { return }
            doc.claims = out
            try saveOwn(doc, ctx)
        }
    }

    /// Drop every held claim whose scopes are all closed (startup after a
    /// crash of the bookkeeping, and the periodic sweep).
    static func pruneClosed(_ ctx: MultiAssistant.Context, open: () -> Set<String>) throws {
        try withLock(ctx) {
            let openNow = open()
            var doc = loadOwn(ctx)
            let before = doc.claims
            doc.claims.removeAll { $0.state == held && Set($0.scopes).isDisjoint(with: openNow) }
            guard doc.claims != before else { return }
            try saveOwn(doc, ctx)
        }
    }

    /// The board tool's `release`: held claims only. Returns (released, still reserved).
    static func releaseHeld(_ ctx: MultiAssistant.Context) throws -> (Int, Int) {
        try withLock(ctx) {
            var doc = loadOwn(ctx)
            let released = doc.claims.filter { $0.state == held }.count
            doc.claims.removeAll { $0.state == held }
            try saveOwn(doc, ctx)
            return (released, doc.claims.count)
        }
    }
}

// MARK: - Claim scopes (A2: the turn plus the jobs it left running)

final class ClaimScopes: @unchecked Sendable {
    static let shared = ClaimScopes()

    private let lock = NSLock()
    private var currentTurn: String?
    /// Ended turns (and out-of-turn edits) waiting for these jobs.
    private var pending: [String: Set<String>] = [:]
    /// Ended turns whose live-job snapshot is still being taken: open.
    private var ending: Set<String> = []
    private var ticker: Task<Void, Never>?
    /// Areas already announced in the current turn (heads-up dedup).
    private var announced: Set<String> = []

    /// Selftests: the jobs alive right now (bash entry ids + subagent run ids).
    nonisolated(unsafe) static var liveJobsOverrideForTesting: (() async -> Set<String>)?
    nonisolated(unsafe) static var tickSeconds: Double = 2

    static func liveJobs() async -> Set<String> {
        if let o = liveJobsOverrideForTesting { return await o() }
        let bash = await BackgroundProcessRegistry.shared.unsettledEntryIds()
        let agents = await SubagentBackgroundRegistry.shared.liveRunIds()
        return Set(bash.map { "bash:" + $0 }).union(agents.map { "agent:" + $0 })
    }

    func openScopes() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var s = Set(pending.keys).union(ending)
        if let t = currentTurn { s.insert(t) }
        return s
    }

    /// Scopes for an edit that settles now. Inside a turn: every open scope
    /// (the turn and the ended turns still waiting for their jobs). Outside
    /// any turn: ALWAYS its own scope bound to the jobs alive at that moment,
    /// besides every open one — Codex stage-3 S3-R2-3: an older pending
    /// scope does not necessarily cover the job making this edit.
    func scopesForEdit(opId: String) async -> [String] {
        lock.lock(); let inTurn = currentTurn != nil; lock.unlock()
        if inTurn { return openScopes().sorted() }
        let scope = "op:" + opId
        let jobs = await Self.liveJobs()
        lock.lock(); pending[scope] = jobs; lock.unlock()
        startTicker()
        return openScopes().union([scope]).sorted()
    }

    func turnStarted(_ id: UUID) {
        lock.lock(); currentTurn = "turn:" + id.uuidString.lowercased(); announced.removeAll(); lock.unlock()
    }

    func turnEnded(_ id: UUID) {
        let scope = "turn:" + id.uuidString.lowercased()
        lock.lock()
        let wasCurrent = currentTurn == scope
        if wasCurrent { currentTurn = nil; ending.insert(scope) }
        lock.unlock()
        // One assistant (no registry): nothing was ever claimed.
        guard wasCurrent, MultiAssistant.contextOverrideForTesting != nil || AssistantRegistry.presence() != .absent else {
            lock.lock(); ending.remove(scope); lock.unlock()
            return
        }
        if let ctx = MultiAssistant.context() { BoardNotices.consumeShown(ctx) }
        Task.detached { [self] in
            let jobs = await Self.liveJobs()
            // Hand over from `ending` to `pending` atomically (never closed in
            // between), then close at once when no job runs.
            self.lock.lock(); self.pending[scope] = jobs; self.ending.remove(scope); self.lock.unlock()
            if jobs.isEmpty, let ctx = MultiAssistant.context() {
                self.close(scope, ctx)
            } else {
                // Jobs still run, or the context is momentarily unavailable
                // (registry being rewritten): the ticker closes it later.
                self.startTicker()
            }
        }
    }

    /// Dedup of heads-ups: true the first time `key` is seen this turn.
    func firstAnnouncement(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return announced.insert(key).inserted
    }

    /// The scope stops counting as open BEFORE its claims are released, so
    /// a settlement racing the closure drops it (S3-2); if the release
    /// cannot run, the claims are swept by `pruneClosed` on the next tick.
    private func close(_ scope: String, _ ctx: MultiAssistant.Context) {
        lock.lock(); pending.removeValue(forKey: scope); lock.unlock()
        do { try FileClaims.releaseScope(ctx, scope) } catch {
            lock.lock(); sweepOwed = true; lock.unlock()
            startTicker()
        }
    }

    private var sweepOwed = false

    private func startTicker() {
        lock.lock()
        guard ticker == nil else { lock.unlock(); return }
        ticker = Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickSeconds * 1_000_000_000))
                await self.tick()
                self.lock.lock()
                let idle = self.pending.isEmpty && self.ending.isEmpty && !self.sweepOwed && !Tripwire.shared.hasWatches
                if idle { self.ticker = nil }
                self.lock.unlock()
                if idle { return }
            }
        }
        lock.unlock()
    }

    func ensureTicker() { startTicker() }

    /// One pass: close every pending scope whose jobs all ended; settle
    /// detached-command tripwires.
    ///
    /// Codex stage-3 S3-R2-1: only scopes and watches that were already
    /// registered BEFORE the liveness sample are judged by it (and a scope
    /// only if its job set is unchanged since): a scope published while the
    /// sample was being taken may name a job the sample never saw.
    func tick() async {
        lock.lock(); let known = pending; lock.unlock()
        let knownWatches = Tripwire.shared.watchIds
        let alive = await Self.liveJobs()
        lock.lock()
        let ready = known.filter { pending[$0.key] == $0.value && $0.value.isDisjoint(with: alive) }.map(\.key)
        lock.unlock()
        if let ctx = MultiAssistant.context() {
            for scope in ready { close(scope, ctx) }
            Tripwire.shared.settleFinished(ctx, alive: alive, known: knownWatches)
            // Safety sweep under the claims lock: a held claim none of whose
            // scopes is open any more goes (S3-2).
            if (try? FileClaims.pruneClosed(ctx, open: { self.openScopes() })) != nil {
                lock.lock(); sweepOwed = false; lock.unlock()
            }
        } else if AssistantRegistry.presence() == .absent && MultiAssistant.contextOverrideForTesting == nil {
            // The registry is gone (last extra removed): nothing to release.
            lock.lock(); for scope in ready { pending.removeValue(forKey: scope) }; lock.unlock()
        }
        // Otherwise keep them pending until the context is readable again.
    }

    func resetForTesting() {
        lock.lock(); currentTurn = nil; pending.removeAll(); ending.removeAll(); sweepOwed = false; announced.removeAll(); ticker?.cancel(); ticker = nil; lock.unlock()
    }

    var pendingScopesForTesting: [String: Set<String>] { lock.lock(); defer { lock.unlock() }; return pending }
}

// MARK: - In-process per-path serialisation (§7.3)

final class ClaimPathLocks: @unchecked Sendable {
    static let shared = ClaimPathLocks()
    private let lock = NSLock()
    private var held: Set<String> = []

    /// Take every path (sorted) within 2 s, or none.
    func acquire(_ paths: [String], wait: Double = 2) async -> Bool {
        let sorted = Array(Set(paths)).sorted()
        let deadline = ProcessInfo.processInfo.systemUptime + wait
        while true {
            lock.lock()
            if held.isDisjoint(with: sorted) {
                held.formUnion(sorted)
                lock.unlock()
                return true
            }
            lock.unlock()
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func release(_ paths: [String]) { lock.lock(); held.subtract(paths); lock.unlock() }
}

// MARK: - Bash tripwire (A2: detection only)

final class Tripwire: @unchecked Sendable {
    static let shared = Tripwire()

    struct Stamp: Equatable {
        var exists: Bool
        var size: Int64
        var mtimeNanos: Int64
        var inode: UInt64
    }

    static func stamp(_ path: String) -> Stamp {
        var st = stat()
        guard lstat(path, &st) == 0 else { return Stamp(exists: false, size: 0, mtimeNanos: 0, inode: 0) }
        #if os(Linux)
        let ns = Int64(st.st_mtim.tv_sec) * 1_000_000_000 + Int64(st.st_mtim.tv_nsec)
        #else
        let ns = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        #endif
        return Stamp(exists: true, size: Int64(st.st_size), mtimeNanos: ns, inode: UInt64(st.st_ino))
    }

    struct Snapshot {
        var files: [(owned: FileClaims.Owned, stamp: Stamp)]
        var jobsBefore: Set<String>
    }

    /// Before a Bash command: every file another assistant claims.
    static func snapshot(_ ctx: MultiAssistant.Context) async -> Snapshot? {
        let owned = FileClaims.othersClaimed(ctx)
        let jobs = await ClaimScopes.liveJobs()
        // Every claim of every peer (≤2,000 each, ≤7 peers): no silent cap (S3-5).
        return Snapshot(files: owned.map { ($0, stamp($0.path)) }, jobsBefore: jobs)
    }

    /// Changed files since `snapshot` (each reported once per snapshot).
    static func changes(_ snapshot: Snapshot, excluding: Set<String> = []) -> [FileClaims.Owned] {
        snapshot.files.filter { !excluding.contains($0.owned.path) && stamp($0.owned.path) != $0.stamp }.map(\.owned)
    }

    /// After the command returned: one contained line per changed file, a
    /// notice queued for each owner; detached jobs it left running are
    /// watched until they end.
    func afterCommand(_ ctx: MultiAssistant.Context, _ snapshot: Snapshot) async -> String {
        let changed = Self.changes(snapshot)
        for c in changed { Self.notifyOwner(ctx, c) }
        let jobsAfter = await ClaimScopes.liveJobs()
        let started = jobsAfter.subtracting(snapshot.jobsBefore).filter { $0.hasPrefix("bash:") }
        if !started.isEmpty {
            lock.lock()
            watches.append(Watch(jobs: started, snapshot: snapshot, reported: Set(changed.map(\.path))))
            lock.unlock()
            ClaimScopes.shared.ensureTicker()
        }
        guard !changed.isEmpty else { return "" }
        let list = changed.prefix(5).map { "\(MultiAssistant.q(MultiAssistant.display($0.path), 120)), which \(MultiAssistant.q($0.peer.displayName, 40)) is editing" }
        var line = "\n\n[Board] ⚠ Changed during this command: " + list.joined(separator: "; ")
        if changed.count > 5 { line += "; and \(changed.count - 5) more" }
        line += ". Other changes may have happened at the same time; check before continuing. The other assistant was told. Nothing was blocked."
        return line
    }

    static func notifyOwner(_ ctx: MultiAssistant.Context, _ owned: FileClaims.Owned) {
        let n = BoardNotices.Notice(id: UUID().uuidString.lowercased(), path: owned.path, byDisplayName: ctx.me.displayName,
                                    at: MultiAssistant.now, kind: "peer", ownerDisplayName: owned.peer.displayName)
        BoardNotices.post(n, to: owned.peer.profile, paths: ctx.paths)
    }

    struct Watch {
        var id = UUID()
        var jobs: Set<String>
        var snapshot: Snapshot
        var reported: Set<String>
    }

    private let lock = NSLock()
    private var watches: [Watch] = []

    var hasWatches: Bool { lock.lock(); defer { lock.unlock() }; return !watches.isEmpty }
    var watchIds: Set<UUID> { lock.lock(); defer { lock.unlock() }; return Set(watches.map(\.id)) }

    /// A detached command settled: compare and tell both sides (this
    /// assistant through its own notices, since its Bash result is gone).
    /// Only watches in `known` (registered before `alive` was sampled) are
    /// judged (S3-R2-1).
    func settleFinished(_ ctx: MultiAssistant.Context, alive: Set<String>, known: Set<UUID>) {
        lock.lock()
        func finished(_ w: Watch) -> Bool { known.contains(w.id) && w.jobs.isDisjoint(with: alive) }
        let done = watches.filter(finished)
        watches.removeAll(where: finished)
        lock.unlock()
        for w in done {
            for c in Self.changes(w.snapshot, excluding: w.reported) {
                Self.notifyOwner(ctx, c)
                let n = BoardNotices.Notice(id: UUID().uuidString.lowercased(), path: c.path, byDisplayName: ctx.me.displayName,
                                            at: MultiAssistant.now, kind: "self", ownerDisplayName: c.peer.displayName)
                BoardNotices.post(n, to: ctx.me.profile, paths: ctx.paths)
            }
        }
    }

    func resetForTesting() { lock.lock(); watches.removeAll(); lock.unlock() }
}
