import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - The convergence engine (security plan v24 §7.8.1, §7.9)
//
// Startup recovery table first (never throttled), then at most one download
// per process start (1 h throttle for automatic attempts), staging owned by an
// attempt record, revalidation under the fixed lock order, the commit
// sequence (a) receipt record → (b) journal `committing` → (c) the `current`
// switch → (d) probe → (d') `probed` → (e1) verified → (e2) mirror + result →
// (f) journal deleted, and the AgentMail-only hold + repair transaction.

/// What a component needs from the engine.
struct RuntimeSpec: Sendable {
    let component: RuntimeComponent
    /// The compiled pin for this machine.
    let pin: RuntimePin
    /// File inside `v/<name>/` whose SHA-256 is the record's `binarySHA256`.
    let binaryRelPath: String
    /// AgentMail only: the v14 hold + repair transaction.
    let usesHold: Bool
    /// Base name of a new `v/` directory for the pin.
    let directoryName: @Sendable (RuntimePin) -> String
    /// Download + verify + extract (or build) into `payload`, run the staged
    /// probe; returns record extras. Throws a RuntimeError with the reason.
    let stage: @Sendable (_ payload: URL, _ progress: (@Sendable (String) -> Void)?) async throws -> [String: String]?
    /// Post-publication probe through `current` (nil = passed).
    let postProbe: @Sendable (_ journal: RuntimeJournal) async -> String?
    /// Extra per-use validation of a record's directory (nil = fine).
    let validateExtra: (@Sendable (_ record: RuntimeRecord, _ dir: URL) -> String?)?
    /// Python: build directly at the final path (venvs are not relocatable, §7.9.4).
    let stagesInPlace: Bool
}

enum RuntimeHealth: Equatable, Sendable {
    /// `current` = `verified` = a validated record.
    case ready(RuntimeRecord)
    case notInstalled
    /// AgentMail is off (hold present).
    case held(RuntimeHold)
    /// Does not match its receipt / inconsistent / unreadable.
    case unknown(String)
    /// First install rolled back, or a live attempt in another process.
    case unavailable(String)
}

enum RuntimeOutcome: Equatable, Sendable {
    case upToDate(RuntimeRecord)
    case converged(RuntimeRecord)
    case failed(String)
    case abandoned(String)
    case throttled(String)
    case held(RuntimeHold)
    case busy(String)
    case notApplicable(String)
}

enum RuntimeTrigger: String, Sendable {
    /// Startup convergence (throttled).
    case auto
    /// `briglia agentmail upgrade`, the menu's repair/upgrade buttons.
    case explicit
    /// Setup paths (first install chosen by the user).
    case install
}

/// Waits until Briglia is idle and holds new turns off for the commit
/// (≤ 15 s, §7.8.1 step 4). nil = no idle requirement (Node/Python).
struct RuntimeIdleGate: Sendable {
    let acquire: @Sendable () async -> Bool
    let release: @Sendable () async -> Void
    /// Is the commit still allowed (provider still selected, …)?
    let stillWanted: @Sendable () async -> Bool
}

enum PrivateRuntimeEngine {
    static let probeTimeout = 15
    static let throttle: TimeInterval = 3600
    static let retiredKept = 16

    // MARK: Validation

    /// nil when `record` (at `v/<directory>`) is intact.
    static func validate(_ spec: RuntimeSpec, _ record: RuntimeRecord) -> String? {
        guard RuntimeFS.validVersionRef(record.directory) else { return "receipt record names a path outside v/" }
        let dir = RuntimePaths.dir(spec.component).appendingPathComponent(record.directory, isDirectory: true)
        do { try RuntimeFS.contain(dir.appendingPathComponent(spec.binaryRelPath)) } catch { return "\(error)" }
        guard RuntimeFS.kind(dir.path) == .directory else { return "\(record.directory) is missing or not a directory" }
        guard let hash = RuntimeFS.sha256(file: dir.appendingPathComponent(spec.binaryRelPath)) else {
            return "\(record.directory)/\(spec.binaryRelPath) is missing"
        }
        guard hash == record.binarySHA256 else { return "\(record.directory)/\(spec.binaryRelPath) does not match its receipt" }
        if let extra = spec.validateExtra?(record, dir) { return extra }
        return nil
    }

    /// What `current` points at: absent, a valid `v/<name>` ref, or something else.
    enum CurrentState: Equatable { case absent, ref(String), other(String) }

    static func currentState(_ c: RuntimeComponent) -> CurrentState {
        let link = RuntimePaths.current(c)
        switch RuntimeFS.kind(link.path) {
        case .absent: return .absent
        case .symlink:
            guard let target = RuntimeFS.readLink(link) else { return .other("unreadable link") }
            return RuntimeFS.validVersionRef(target) ? .ref(target) : .other(target)
        default: return .other("not a symlink")
        }
    }

    static func rawCurrent(_ c: RuntimeComponent) -> String? {
        RuntimeFS.readLink(RuntimePaths.current(c))
    }

    // MARK: Recovery (always first, under both locks)

    /// The startup recovery table (§7.8.1 v11-v14). Writes only what the
    /// table prescribes. Caller holds both locks and saves `sel` afterwards.
    static func recoverLocked(_ spec: RuntimeSpec, _ sel: inout RuntimeSelectionFile, selectionCorrupted: Bool = false) async -> RuntimeHealth {
        let c = spec.component
        var st = sel[c]
        defer { sel[c] = st }
        settleDeadAttempts(&st)

        func holdUnknown(_ why: String) -> RuntimeHealth { Self.holdUnknown(spec, &st, why) }
        if selectionCorrupted && spec.usesHold && st.hold == nil {
            // The lost file may have held a hold: fail safe (off until repair).
            return holdUnknown("selected.json was unreadable and has been set aside")
        }

        let receipt: RuntimeReceipt
        do { receipt = try RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c)) ?? RuntimeReceipt() } catch {
            return holdUnknown("the install receipt is unreadable (\(error))")
        }
        let journal: RuntimeJournal?
        do { journal = try RuntimeFS.readJSON(RuntimeJournal.self, RuntimePaths.journal(c)) } catch {
            return holdUnknown("the install journal is unreadable; run the repair")
        }
        let cur = currentState(c)

        if let j = journal {
            if j.mode == "repair" {
                return await recoverRepairJournal(spec, j, receipt, cur, &st)
            }
            guard j.mode == nil, ["committing", "probed"].contains(j.state),
                  RuntimeFS.validVersionRef(j.newTarget), j.newRecord.directory == j.newTarget,
                  j.oldTarget.map(RuntimeFS.validVersionRef) ?? true else {
                return holdUnknown("the install journal is inconsistent; run the repair")
            }
            let atOld: Bool = { if let o = j.oldTarget { return cur == .ref(o) } else { return cur == .absent } }()
            if j.state == "committing" && atOld {
                // Switch never happened, or a rollback switched back (metadata never advanced).
                finishAttempt(&st, j.attemptId, result: "failed: interrupted", onlyIfUnset: true)
                do { try RuntimeFS.remove(RuntimePaths.journal(c)) } catch { return .unknown("\(error)") }
                return await noJournalRows(spec, receipt, cur, &st)
            }
            if cur == .ref(j.newTarget) {
                if j.state == "committing" {
                    // Switched; no probe passed durably: probe now (ordinary journals only).
                    if let why = await spec.postProbe(j) {
                        do {
                            if let o = j.oldTarget { try RuntimeFS.switchLink(RuntimePaths.current(c), to: o) }
                            else { try RuntimeFS.remove(RuntimePaths.current(c)) }
                            finishAttempt(&st, j.attemptId, result: "failed: probe (\(why))", onlyIfUnset: false)
                            try RuntimeFS.remove(RuntimePaths.journal(c))
                        } catch { return .unknown("rollback during recovery failed: \(error)") }
                        return j.oldTarget == nil ? .unavailable("install failed: \(why)")
                            : await noJournalRows(spec, receipt, currentState(c), &st)
                    }
                    var probed = j; probed.state = "probed"
                    do { try RuntimeFS.writeJSON(probed, RuntimePaths.journal(c)) } catch { return .unknown("\(error)") }
                    return finishProbed(spec, probed, &st)
                }
                return finishProbed(spec, j, &st)
            }
            return holdUnknown("the install journal does not match the current link; run the repair")
        }
        return await noJournalRows(spec, receipt, cur, &st)
    }

    /// `unknown` rows: AgentMail writes the hold for the compiled pin if none
    /// exists (v14); Node/Python report unknown (a fresh copy is staged).
    static func holdUnknown(_ spec: RuntimeSpec, _ st: inout RuntimeComponentState, _ why: String) -> RuntimeHealth {
        st.mirror = nil
        guard spec.usesHold else { return .unknown(why) }
        if st.hold == nil { st.hold = RuntimeHold(pin: spec.pin, reason: "unknown", since: Date(), attemptId: nil) }
        return .held(st.hold!)
    }

    private static func noJournalRows(_ spec: RuntimeSpec, _ receipt: RuntimeReceipt, _ cur: CurrentState,
                                      _ st: inout RuntimeComponentState) async -> RuntimeHealth {
        let c = spec.component
        func holdUnknown(_ why: String) -> RuntimeHealth { Self.holdUnknown(spec, &st, why) }
        if spec.usesHold, let hold = st.hold {
            st.mirror = nil
            return .held(hold)
        }
        let verified = receipt.verifiedRecord
        switch cur {
        case .ref(let target):
            if let v = verified, v.directory == target {
                if let why = validate(spec, v) { return holdUnknown("the installed copy does not match its receipt (\(why))") }
                if st.mirror != v { st.mirror = v }
                return .ready(v)
            }
            if receipt.record(directory: target) != nil {
                return holdUnknown("the current link names a recorded copy that is not the verified one (outside interference)")
            }
            return holdUnknown("the current link names an unrecorded copy (\(target))")
        case .absent:
            guard let v = verified else {
                st.mirror = nil
                return .notInstalled
            }
            if let why = validate(spec, v) { return holdUnknown("the last verified copy is damaged (\(why))") }
            do { try RuntimeFS.switchLink(RuntimePaths.current(c), to: v.directory) } catch { return .unknown("\(error)") }
            if st.mirror != v { st.mirror = v }
            return .ready(v)
        case .other(let what):
            return holdUnknown("the current link is not a version link (\(what))")
        }
    }

    private static func finishProbed(_ spec: RuntimeSpec, _ j: RuntimeJournal, _ st: inout RuntimeComponentState) -> RuntimeHealth {
        let c = spec.component
        do {
            var receipt = try RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c)) ?? RuntimeReceipt()
            if receipt.record(directory: j.newTarget) == nil { receipt.records.append(j.newRecord) }
            if receipt.verified != j.newTarget {
                receipt.verified = j.newTarget
                try RuntimeFS.writeJSON(receipt, RuntimePaths.receipt(c))
            }
            st.mirror = j.newRecord
            finishAttempt(&st, j.attemptId, result: "converged", onlyIfUnset: false)
            if j.mode == "repair" { st.hold = nil }
            // (e) is persisted by the caller's selected.json save BEFORE (f):
            // the caller deletes the journal only after that save succeeds.
            return .ready(j.newRecord)
        } catch {
            return .unknown("finishing the probed install failed: \(error)")
        }
    }

    private static func recoverRepairJournal(_ spec: RuntimeSpec, _ j: RuntimeJournal, _ receipt: RuntimeReceipt,
                                             _ cur: CurrentState, _ st: inout RuntimeComponentState) async -> RuntimeHealth {
        let c = spec.component
        switch j.state {
        case "committing":
            // v14: never re-probed, no fallback: remove the link, keep the hold.
            do {
                if RuntimeFS.kind(RuntimePaths.current(c).path) != .absent { try RuntimeFS.remove(RuntimePaths.current(c)) }
            } catch { return .unknown("\(error)") }
            finishAttempt(&st, j.attemptId, result: "failed: interrupted", onlyIfUnset: true)
            if var hold = st.hold {
                if hold.reason != "repair-failed" { hold.reason = "repair-interrupted" }
                st.hold = hold
            } else {
                st.hold = RuntimeHold(pin: j.newRecord.pin, reason: "repair-interrupted", since: Date(), attemptId: j.attemptId)
            }
            st.mirror = nil
            st.pendingJournalDelete = true
            return .held(st.hold!)
        case "probed" where cur == .ref(j.newTarget):
            return finishProbed(spec, j, &st)
        default:
            if st.hold == nil { st.hold = RuntimeHold(pin: spec.pin, reason: "unknown", since: Date(), attemptId: nil) }
            st.mirror = nil
            return .held(st.hold!)
        }
    }

    // MARK: Attempts

    static func settleDeadAttempts(_ st: inout RuntimeComponentState) {
        for i in st.attempts.indices where st.attempts[i].result == nil && RuntimeProcessIdentity.ownerGone(st.attempts[i]) {
            st.attempts[i].result = "failed: interrupted"
            st.attempts[i].finishedAt = Date()
        }
    }

    static func finishAttempt(_ st: inout RuntimeComponentState, _ id: String, result: String, onlyIfUnset: Bool) {
        guard let i = st.attempts.firstIndex(where: { $0.attemptId == id }) else { return }
        if onlyIfUnset && st.attempts[i].result != nil { return }
        st.attempts[i].result = result
        st.attempts[i].finishedAt = Date()
    }

    static func newAttempt(_ spec: RuntimeSpec, kind: String, generation: Int, buildDirectory: String? = nil) -> RuntimeAttempt {
        let id = RuntimeFS.randomHex(16)
        return RuntimeAttempt(attemptId: id, kind: kind, pin: spec.pin, pid: getpid(),
                              processStart: RuntimeProcessIdentity.startTime(pid: getpid()),
                              bootId: RuntimeProcessIdentity.bootId(), startedAt: Date(), generation: generation,
                              result: nil, finishedAt: nil, buildDirectory: buildDirectory)
    }

    static func liveForeignAttempt(_ st: RuntimeComponentState) -> RuntimeAttempt? {
        st.attempts.first { $0.result == nil && $0.pid != getpid() && !RuntimeProcessIdentity.ownerGone($0) }
    }

    // MARK: Recovery entry point

    /// Takes both locks, runs recovery, saves, applies the deferred journal
    /// deletion (only after the selected.json write succeeded).
    static func recover(_ spec: RuntimeSpec) async -> RuntimeHealth {
        do {
            let locks = try RuntimeLocks.take(spec.component)
            defer { locks.release() }
            let (loaded, corrupted) = try RuntimeSelectionStore.load()
            var sel = loaded
            let health = await recoverLocked(spec, &sel, selectionCorrupted: corrupted)
            try commitRecovered(spec, &sel)
            return health
        } catch {
            return .unknown("recovery could not run: \(error)")
        }
    }

    /// Saves `sel`, then (f) deletes a journal whose outcome is now durable.
    static func commitRecovered(_ spec: RuntimeSpec, _ sel: inout RuntimeSelectionFile) throws {
        let c = spec.component
        var st = sel[c]
        let pendingDelete = st.pendingJournalDelete
        st.pendingJournalDelete = false
        st.attempts = Array(st.attempts.sorted { $0.startedAt < $1.startedAt }.suffix(RuntimeComponentState.maxAttempts))
        sel[c] = st
        try RuntimeSelectionStore.save(sel)
        // A journal that finished (probed → verified/mirror durable) or a
        // repair `committing` journal whose hold is durable can go now.
        if let j = try? RuntimeFS.readJSON(RuntimeJournal.self, RuntimePaths.journal(c)) {
            let receipt = (try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c))) ?? nil
            let done = j.state == "probed" && receipt?.verified == j.newTarget && st.mirror == j.newRecord
                && (j.mode != "repair" || st.hold == nil)
            if done || pendingDelete {
                RuntimeSeams.crash(c, "before-journal-delete")
                try RuntimeFS.remove(RuntimePaths.journal(c))
            }
        }
    }

    // MARK: Convergence (ordinary update / first install)

    static func converge(_ spec: RuntimeSpec, trigger: RuntimeTrigger, idle: RuntimeIdleGate? = nil,
                         progress: (@Sendable (String) -> Void)? = nil) async -> RuntimeOutcome {
        let c = spec.component
        // 1. Recovery + detection; the attempt record is durable before staging.
        let attempt: RuntimeAttempt
        let snapshotVerified: String?
        let snapshotCurrent: String?
        let generation: Int
        do {
            let locks = try RuntimeLocks.take(c)
            defer { locks.release() }
            let (loaded, corrupted) = try RuntimeSelectionStore.load()
            var sel = loaded
            let health = await recoverLocked(spec, &sel, selectionCorrupted: corrupted)
            var early: RuntimeOutcome?
            switch health {
            case .ready(let r) where r.pin == spec.pin: early = .upToDate(r)
            case .held(let h): early = .held(h)
            case .unknown(let why) where spec.usesHold: early = .failed(why)
            default: break
            }
            var st = sel[c]
            if early == nil, let live = liveForeignAttempt(st) {
                early = .busy("another Briglia process is installing it (attempt \(live.attemptId.prefix(8)))")
            }
            if early == nil, trigger == .auto, let last = st.latestAutoAttempt, last.result != "converged",
               Date().timeIntervalSince(last.startedAt) < throttle {
                early = .throttled("last automatic attempt \(Int(Date().timeIntervalSince(last.startedAt) / 60)) min ago (\(last.result ?? "in flight")); retried after an hour")
            }
            if let early {
                try commitRecovered(spec, &sel)
                return early
            }
            generation = sel.generation
            let receipt = (try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c))) ?? nil
            snapshotVerified = receipt?.verified
            snapshotCurrent = rawCurrent(c)
            var buildDir: String?
            if spec.stagesInPlace {
                guard let name = freshDirectoryName(spec) else { try commitRecovered(spec, &sel); return .failed("no free version directory name") }
                buildDir = name
            }
            attempt = newAttempt(spec, kind: trigger == .auto ? "auto" : (trigger == .install ? "install" : "explicit"),
                                 generation: generation, buildDirectory: buildDir)
            st.attempts.append(attempt)
            sel[c] = st
            try commitRecovered(spec, &sel)
        } catch {
            return .failed("could not start: \(error)")
        }

        // 3. Stage outside the locks.
        let staging = RuntimePaths.staging(c, attempt: attempt.attemptId)
        let payload: URL
        let scratch: URL
        do {
            if spec.stagesInPlace, let bd = attempt.buildDirectory {
                try RuntimeFS.ensureDir(RuntimePaths.versions(c))
                payload = RuntimePaths.dir(c).appendingPathComponent(bd, isDirectory: true)
                scratch = payload
            } else {
                try RuntimeFS.ensureDir(staging)
                payload = staging.appendingPathComponent("payload", isDirectory: true)
                scratch = staging
            }
        } catch {
            settle(spec, attempt.attemptId, "failed: \(error)")
            return .failed("\(error)")
        }
        do {
            let extras = try await spec.stage(payload, progress)
            try RuntimeFS.restrictTree(payload)
            RuntimeSeams.crash(c, "after-stage")
            guard let identity = RuntimeFS.sha256(file: payload.appendingPathComponent(spec.binaryRelPath)) else {
                throw RuntimeError("the staged copy lacks \(spec.binaryRelPath)")
            }
            // 4. Idle (AgentMail), then revalidate and commit under both locks.
            if let idle {
                guard await idle.acquire() else {
                    try? RuntimeFS.removeTree(scratch)
                    settle(spec, attempt.attemptId, "waiting-for-idle")
                    return .abandoned("Briglia did not become idle; retried at the next start")
                }
                let wanted = await idle.stillWanted()
                let outcome = wanted
                    ? await commit(spec, attempt, generation, snapshotVerified, snapshotCurrent, payload, scratch, identity, extras)
                    : abandon(spec, attempt, scratch, "no longer wanted (provider changed)")
                await idle.release()
                return outcome
            }
            return await commit(spec, attempt, generation, snapshotVerified, snapshotCurrent, payload, scratch, identity, extras)
        } catch {
            let why = (error as? RuntimeError)?.description ?? error.localizedDescription
            try? RuntimeFS.removeTree(scratch)
            settle(spec, attempt.attemptId, "failed: \(why)")
            return .failed(why)
        }
    }

    private static func abandon(_ spec: RuntimeSpec, _ attempt: RuntimeAttempt, _ scratch: URL, _ why: String) -> RuntimeOutcome {
        try? RuntimeFS.removeTree(scratch)
        settle(spec, attempt.attemptId, "abandoned")
        return .abandoned(why)
    }

    /// Steps (a)-(f) under both locks. A crash between any two writes is
    /// settled by the recovery table at the next start.
    private static func commit(_ spec: RuntimeSpec, _ attempt: RuntimeAttempt, _ generation: Int,
                               _ snapshotVerified: String?, _ snapshotCurrent: String?,
                               _ payload: URL, _ scratch: URL, _ identity: String,
                               _ extras: [String: String]?) async -> RuntimeOutcome {
        let c = spec.component
        do {
            let locks = try RuntimeLocks.take(c)
            defer { locks.release() }
            var (sel, _) = try RuntimeSelectionStore.load()
            var receipt = try RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c)) ?? RuntimeReceipt()
            let journalPresent = RuntimeFS.kind(RuntimePaths.journal(c).path) != .absent
            if sel.generation != generation || receipt.verified != snapshotVerified || rawCurrent(c) != snapshotCurrent
                || journalPresent || (spec.usesHold && sel[c].hold != nil) {
                // Settle with the selection state already held: re-entering
                // the selection lock here would wait on this transaction's own
                // descriptor (review R5).
                try? RuntimeFS.removeTree(scratch)
                var st = sel[c]; finishAttempt(&st, attempt.attemptId, result: "abandoned", onlyIfUnset: true); sel[c] = st
                try RuntimeSelectionStore.save(sel)
                return .abandoned("the installation changed meanwhile (wipe, import, provider change or another install)")
            }
            // (a) publish the immutable directory + its record.
            let dest: String
            if spec.stagesInPlace, let bd = attempt.buildDirectory {
                dest = bd
            } else {
                guard let name = freshDirectoryName(spec) else { throw RuntimeError("no free version directory name") }
                dest = name
                try RuntimeFS.ensureDir(RuntimePaths.versions(c))
                let target = RuntimePaths.dir(c).appendingPathComponent(dest, isDirectory: true)
                guard rename(payload.path, target.path) == 0 else {
                    throw RuntimeError("could not publish \(dest): \(String(cString: strerror(errno)))")
                }
                try PrivateStorage.fsyncDirectory(RuntimePaths.versions(c).path)
                try? RuntimeFS.removeTree(scratch)
            }
            let record = RuntimeRecord(triple: spec.pin.triple, version: spec.pin.version, archiveSHA256: spec.pin.archiveSHA256,
                                       binarySHA256: identity, directory: dest, installedAt: Date(), extra: extras)
            receipt.records.removeAll { $0.directory == dest }
            receipt.records.append(record)
            try RuntimeFS.writeJSON(receipt, RuntimePaths.receipt(c))
            RuntimeSeams.crash(c, "after-receipt")
            // (b) journal committing.
            let old: String? = { if case .ref(let o) = currentState(c) { return o } else { return nil } }()
            var j = RuntimeJournal(attemptId: attempt.attemptId, oldTarget: old, newTarget: dest, newRecord: record, state: "committing")
            try RuntimeFS.writeJSON(j, RuntimePaths.journal(c))
            RuntimeSeams.crash(c, "after-committing")
            // (c) the switch.
            try RuntimeFS.switchLink(RuntimePaths.current(c), to: dest)
            RuntimeSeams.crash(c, "after-switch")
            // (d) probe through current.
            if let why = await spec.postProbe(j) {
                if let o = old { try RuntimeFS.switchLink(RuntimePaths.current(c), to: o) }
                else { try RuntimeFS.remove(RuntimePaths.current(c)) }
                RuntimeSeams.crash(c, "after-rollback-switch")
                var st = sel[c]; finishAttempt(&st, attempt.attemptId, result: "failed: probe (\(why))", onlyIfUnset: false); sel[c] = st
                try RuntimeSelectionStore.save(sel)
                try RuntimeFS.remove(RuntimePaths.journal(c))
                return .failed("the new copy failed its check (\(why))" + (old == nil ? "" : "; the previous copy stays in use"))
            }
            // (d') probed.
            j.state = "probed"
            try RuntimeFS.writeJSON(j, RuntimePaths.journal(c))
            RuntimeSeams.crash(c, "after-probed")
            // (e1) verified.
            receipt.verified = dest
            try RuntimeFS.writeJSON(receipt, RuntimePaths.receipt(c))
            RuntimeSeams.crash(c, "after-verified")
            // (e2) mirror + result.
            var st = sel[c]
            st.mirror = record
            finishAttempt(&st, attempt.attemptId, result: "converged", onlyIfUnset: false)
            sel[c] = st
            try RuntimeSelectionStore.save(sel)
            RuntimeSeams.crash(c, "after-mirror")
            // (f)
            try RuntimeFS.remove(RuntimePaths.journal(c))
            return .converged(record)
        } catch {
            settle(spec, attempt.attemptId, "failed: \(error)")
            return .failed("\(error)")
        }
    }

    /// Records an attempt result under the selection lock (best effort).
    static func settle(_ spec: RuntimeSpec, _ id: String, _ result: String) {
        _ = try? RuntimeSelectionStore.update { sel in
            var st = sel[spec.component]
            finishAttempt(&st, id, result: result, onlyIfUnset: true)
            sel[spec.component] = st
        }
    }

    /// `v/<name>` if that path does not exist, else `v/<name>.r<attempt12>`;
    /// nil if both exist (nothing is ever overwritten).
    static func freshDirectoryName(_ spec: RuntimeSpec) -> String? {
        let base = "v/" + spec.directoryName(spec.pin)
        let dir = RuntimePaths.dir(spec.component)
        if RuntimeFS.kind(dir.appendingPathComponent(base).path) == .absent { return base }
        let alt = base + ".r" + RuntimeFS.randomHex(6)
        return RuntimeFS.kind(dir.appendingPathComponent(alt).path) == .absent ? alt : nil
    }

    // MARK: Garbage collection (startup, after recovery)

    /// Removes `v/` directories that nothing references and that still match
    /// a receipt record; unrecorded or damaged ones are kept and reported.
    /// Staging is removed only when its attempt record's owner is gone.
    static func collectGarbage(_ spec: RuntimeSpec, keepRunning: Set<String> = [], extraKeep: (() -> Set<String>)? = nil) -> [String] {
        let c = spec.component
        var report: [String] = []
        guard let locks = try? RuntimeLocks.take(c, timeout: 5) else { return ["garbage collection skipped (locks busy)"] }
        defer { locks.release() }
        guard let loaded = try? RuntimeSelectionStore.load(),
              let readReceipt = try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c)),
              RuntimeFS.kind(RuntimePaths.journal(c).path) == .absent else { return report }
        let sel = loaded.file
        var receipt = readReceipt
        let st = sel[c]
        var keep: Set<String> = keepRunning.union(extraKeep?() ?? [])
        if case .ref(let r) = currentState(c) { keep.insert(r) }
        if let v = receipt.verified { keep.insert(v) }
        for a in st.attempts where a.result == nil { if let b = a.buildDirectory { keep.insert(b) } }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: RuntimePaths.versions(c).path)) ?? []
        var changed = false
        for name in names.sorted() {
            let ref = "v/\(name)"
            guard !keep.contains(ref) else { continue }
            guard let rec = receipt.record(directory: ref) else {
                // An interrupted in-place build owned by a dead attempt can go.
                if let a = st.attempts.first(where: { $0.buildDirectory == ref }), a.result != nil {
                    try? RuntimeFS.removeTree(RuntimePaths.dir(c).appendingPathComponent(ref))
                    report.append("removed the interrupted build \(ref)")
                } else {
                    report.append("kept unrecorded \(ref) (remove it by hand if you do not need it)")
                }
                continue
            }
            if validate(spec, rec) != nil {
                report.append("kept \(ref): it does not match its receipt")
                continue
            }
            do {
                try RuntimeFS.removeTree(RuntimePaths.dir(c).appendingPathComponent(ref))
                receipt.records.removeAll { $0.directory == ref }
                changed = true
                report.append("removed the unused \(ref)")
            } catch {
                report.append("could not remove \(ref): \(error)")
            }
        }
        if changed { try? RuntimeFS.writeJSON(receipt, RuntimePaths.receipt(c)) }
        // Staging.
        let entries = (try? fm.contentsOfDirectory(atPath: RuntimePaths.dir(c).path)) ?? []
        for e in entries where e.hasPrefix(".staging-") {
            let id = String(e.dropFirst(".staging-".count))
            let url = RuntimePaths.dir(c).appendingPathComponent(e)
            if let a = st.attempts.first(where: { $0.attemptId == id }) {
                if a.result != nil || RuntimeProcessIdentity.ownerGone(a) { try? RuntimeFS.removeTree(url) }
                continue
            }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let old = (attrs?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) > 3600 } ?? false
            if InstanceLease.isHeldInThisProcess && old { try? RuntimeFS.removeTree(url) }
            else { report.append("kept staging \(e) (no attempt record names it)") }
        }
        return report
    }
}

// MARK: - Child processes with an explicit environment

enum RuntimeProcess {
    struct Result: Sendable { let status: Int32; let stdout: String; let stderr: String; let timedOut: Bool }

    static func run(_ executable: String, _ args: [String], env: [String: String]? = nil, cwd: URL? = nil,
                    timeout: Int = 60) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runBlocking(executable, args, env: env, cwd: cwd, timeout: timeout))
            }
        }
    }

    static func runBlocking(_ executable: String, _ args: [String], env: [String: String]?, cwd: URL?, timeout: Int) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let env { p.environment = env }
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: "failed to launch \(executable): \(error.localizedDescription)", timedOut: false)
        }
        let capture = ProcessOutputCapture(stdout: out, stderr: err)
        capture.start()
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        var timedOut = false
        if p.isRunning {
            timedOut = true
            p.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        let o = capture.finish(within: 2)
        return Result(status: timedOut ? -1 : p.terminationStatus,
                      stdout: String(data: o.stdout, encoding: .utf8) ?? "",
                      stderr: ProcessOutputCapture.text(o.stderr), timedOut: timedOut)
    }

    static func detail(_ r: Result) -> String {
        if r.timedOut { return "timed out" }
        let e = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        return "exit \(r.status)\(e.isEmpty ? "" : ": \(e)")"
    }
}
