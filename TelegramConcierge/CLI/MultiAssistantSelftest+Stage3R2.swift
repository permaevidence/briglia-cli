import Foundation

/// Codex stage-3 round 2 (S3-R2-1…3): claim-lifetime orderings that released
/// protection too early. Each row drives the unchanged production
/// `ClaimScopes` / `FileClaims` / `MultiAssistantHooks` code in the exact
/// order Codex reported, with the existing `liveJobsOverrideForTesting`
/// seam (an actor-style gate where a liveness sample must be held open).
extension ProfileHarness {
    /// The first `snapshot()` suspends until `release()` and then returns
    /// `first`; every later call returns `later` at once.
    final class LiveJobsGate: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        private var entered = false
        private var released = false
        private var cont: CheckedContinuation<Void, Never>?
        let first: Set<String>
        let later: Set<String>
        init(first: Set<String>, later: Set<String>) { self.first = first; self.later = later }

        func snapshot() async -> Set<String> {
            lock.lock()
            if used { lock.unlock(); return later }
            used = true; entered = true
            lock.unlock()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released { lock.unlock(); c.resume() } else { cont = c; lock.unlock() }
            }
            return first
        }

        var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }

        func release() {
            lock.lock(); released = true; let c = cont; cont = nil; lock.unlock()
            c?.resume()
        }
    }

    func until(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return cond()
    }

    func stage3Round2() {
        stage3StaleSample()
        stage3UnsettledReservation()
        stage3OutOfTurnScope()
        stage3TerminatingJob()
        stage3RootExitsFirst(redirected: true)
        stage3RootExitsFirst(redirected: false)
        stage3RetentionDuringTermination()
        stage3RemoveEntryDuringTermination()
    }

    /// S3-R5-1, the other retirement path: `removeEntry` (the attached
    /// caller dropping its entry) must not retire an entry while another
    /// termination of it (/stop, kill) is still inside its grace.
    private func stage3RemoveEntryDuringTermination() {
        guard let fx = makeS3("r5-remove") else { check("S3-R5-1 removeEntry fixture", false); return }
        defer { fx.release(); resetStage3Seams() }
        let reg = BackgroundProcessRegistry.shared
        let ready = fx.root.appendingPathComponent("child-ready").path
        let body = "$SIG{TERM}=sub{}; open(R,\">\",$ARGV[0]); close R; while(1){ sleep 0.005 }"
        let child = "perl -MTime::HiRes=sleep -e '\(body)' \"\(ready)\" </dev/null >/dev/null 2>&1"
        guard let job = wait({ try? await reg.start(command: child + " & while :; do sleep 0.02; done",
                                                     workdir: fx.root.path, description: "s3r51rm") }),
              until(10, { FileManager.default.fileExists(atPath: ready) }) else {
            check("S3-R5-1 removeEntry: start the job", false); return
        }
        final class Flag: @unchecked Sendable { var done = false }
        let killFlag = Flag()
        let killDone = DispatchSemaphore(value: 0)
        Task.detached { _ = await reg.kill(handleId: job.id); killFlag.done = true; killDone.signal() }
        var receipt: BashCompletionReceipt?
        let deadline = Date().addingTimeInterval(5)
        while receipt == nil && !killFlag.done && Date() < deadline {
            receipt = wait { await reg.pendingReceipt(handleId: job.id) }
            if receipt == nil { Thread.sleep(forTimeInterval: 0.001) }
        }
        guard let receipt, !killFlag.done else {
            check("S3-R5-1 removeEntry: the receipt is published during the termination grace (fixture ordering)", false)
            _ = killDone.wait(timeout: .now() + 10); return
        }
        _ = wait { await reg.removeEntry(uuid: receipt.jobUUID) }
        let retained = wait { await reg.hasEntryForTesting(handleId: job.id) }
        let live = wait { await reg.unsettledEntryIds() }.contains(job.id)
        check("S3-R5-1 removeEntry: an entry still being terminated is not retired; it stays live",
              retained && live && !killFlag.done, "retained \(retained) live \(live) killDone \(killFlag.done)")
        _ = killDone.wait(timeout: .now() + 10)
        let gone = until(2) { !wait({ await reg.hasEntryForTesting(handleId: job.id) }) }
        check("S3-R5-1 removeEntry: the deferred removal happens once the termination ended", gone)
        _ = wait { await reg.acknowledgeCompletions([receipt]) }

        // purgeAllForWipe (/deleteuserdata) drops every entry: it first joins
        // a termination already in flight elsewhere instead of dropping it.
        let ready2 = fx.root.appendingPathComponent("child-ready-2").path
        let child2 = "perl -MTime::HiRes=sleep -e '\(body)' \"\(ready2)\" </dev/null >/dev/null 2>&1"
        guard let job2 = wait({ try? await reg.start(command: child2 + " & while :; do sleep 0.02; done",
                                                      workdir: fx.root.path, description: "s3r51wipe") }),
              until(10, { FileManager.default.fileExists(atPath: ready2) }) else {
            check("S3-R5-1 wipe: start the job", false); return
        }
        let kill2 = Flag()
        let kill2Done = DispatchSemaphore(value: 0)
        Task.detached { _ = await reg.kill(handleId: job2.id); kill2.done = true; kill2Done.signal() }
        var r2: BashCompletionReceipt?
        let d2 = Date().addingTimeInterval(5)
        while r2 == nil && !kill2.done && Date() < d2 {
            r2 = wait { await reg.pendingReceipt(handleId: job2.id) }
            if r2 == nil { Thread.sleep(forTimeInterval: 0.001) }
        }
        guard r2 != nil, !kill2.done else {
            check("S3-R5-1 wipe: the receipt is published during the termination grace (fixture ordering)", false)
            _ = kill2Done.wait(timeout: .now() + 10); return
        }
        _ = wait { await reg.purgeAllForWipe() }
        // Joined: the kill's own task finishes right after the purge returned
        // (without the join the purge returns ~250 ms into the grace).
        let joined = kill2Done.wait(timeout: .now() + 0.1) == .success
        if !joined { _ = kill2Done.wait(timeout: .now() + 10) }
        check("S3-R5-1 wipe: purgeAllForWipe joins a termination still in flight before dropping the entries",
              joined && !wait({ await reg.hasEntryForTesting(handleId: job2.id) }))
    }

    // MARK: S3-R5-1 — retention must not retire an entry mid-termination

    /// Codex stage-3 round 5: with the production count cap (50) full of
    /// finished jobs whose completion notices are still pending, acknowledging
    /// a job's receipt during its SIGTERM grace pruned the entry, so liveness
    /// (which scans only retained entries) dropped it and the claim and the
    /// watch were released before the child's late write.
    private func stage3RetentionDuringTermination() {
        guard let fx = makeS3("r5-retention") else { check("S3-R5-1 fixture", false); return }
        let reg = BackgroundProcessRegistry.shared
        var pinned: [String] = []
        defer {
            // Release the pinned completions so later sections see a normal registry.
            let receipts = pinned.compactMap { h in wait({ await reg.pendingReceipt(handleId: h) }) }
            _ = wait { await reg.acknowledgeCompletions(receipts) }
            _ = wait { await reg._testSetPruneOverrides(retentionSeconds: nil, countCap: nil) }
            fx.release(); resetStage3Seams()
        }
        let a = fx.ctx("default"), b = fx.ctx("work")
        MultiAssistant.contextOverrideForTesting = a
        ClaimScopes.tickSeconds = 3600
        ClaimScopes.liveJobsOverrideForTesting = nil
        _ = wait { await reg._testSetPruneOverrides(retentionSeconds: nil, countCap: nil) }   // production cap 50
        // Fifty finished jobs whose completion notices stay pending (pinned).
        for i in 0..<50 {
            guard let j = wait({ try? await reg.start(command: "true", workdir: fx.root.path, description: "pin\(i)") }) else {
                check("S3-R5-1: start pinned job \(i)", false); return
            }
            pinned.append(j.id)
        }
        guard until(20, { pinned.allSatisfy { h in wait({ await reg.lifecycleSettledForTesting(handleId: h) }) } }),
              pinned.allSatisfy({ h in wait({ await reg.pendingReceipt(handleId: h) }) != nil }) else {
            check("S3-R5-1: fifty finished jobs with pending completions", false); return
        }
        let file = fx.root.appendingPathComponent("retained.txt").path
        let watched = MultiAssistant.canonical(fx.root.appendingPathComponent("watched.txt").path)
        FileManager.default.createFile(atPath: watched, contents: Data("WATCH\n".utf8))
        try? FileClaims.reserve(b, paths: [watched], opId: "w1")
        try? FileClaims.settle(b, opId: "w1", changed: true, scopes: ["x"], open: { Self.syntheticOpen })
        let turn = UUID(), scope = "turn:" + turn.uuidString.lowercased()
        ClaimScopes.shared.turnStarted(turn)
        try? FileClaims.reserve(a, paths: [file], opId: "rr1")
        try? FileClaims.settle(a, opId: "rr1", changed: true, scopes: [scope])
        guard let snap = wait({ await Tripwire.snapshot(a) }), snap.files.contains(where: { $0.owned.path == watched }) else {
            check("S3-R5-1: tripwire snapshot of Work's claim", false); return
        }
        let ready = fx.root.appendingPathComponent("child-ready").path
        let body = "$SIG{TERM}=sub{$t=time()+0.25 unless defined $t}; open(R,\">\",$ARGV[1]); close R; while(1){ if(defined $t && time()>=$t){ open(F,\">>\",$ARGV[0]); print F \"LATE\\n\"; close F; $t=1e18 } sleep 0.005 }"
        let child = "perl -MTime::HiRes=time,sleep -e '\(body)' \"\(watched)\" \"\(ready)\" </dev/null >/dev/null 2>&1"
        guard let job = wait({ try? await reg.start(command: child + " & while :; do sleep 0.02; done",
                                                     workdir: fx.root.path, description: "s3r51") }) else {
            check("S3-R5-1: start the job", false); return
        }
        let jobKey = "bash:" + job.id
        _ = wait { await Tripwire.shared.afterCommand(a, snap) }
        ClaimScopes.shared.turnEnded(turn)
        guard until(5, { ClaimScopes.shared.pendingScopesForTesting[scope]?.contains(jobKey) == true }) && Tripwire.shared.hasWatches,
              until(10, { FileManager.default.fileExists(atPath: ready) }) else {
            check("S3-R5-1: T pending on the job, watch registered, child running", false)
            _ = wait { await reg.kill(handleId: job.id) }
            return
        }
        final class Flag: @unchecked Sendable { var done = false }
        let killFlag = Flag()
        let killDone = DispatchSemaphore(value: 0)
        Task.detached { _ = await reg.kill(handleId: job.id); killFlag.done = true; killDone.signal() }
        // markTerminated publishes the receipt once the root exited and the
        // readers drained — while the process-tree termination still runs.
        var receipt: BashCompletionReceipt?
        let deadline = Date().addingTimeInterval(5)
        while receipt == nil && !killFlag.done && Date() < deadline {
            receipt = wait { await reg.pendingReceipt(handleId: job.id) }
            if receipt == nil { Thread.sleep(forTimeInterval: 0.001) }
        }
        guard let receipt, !killFlag.done else {
            check("S3-R5-1: the receipt is published during the termination grace (fixture ordering)", false,
                  "receipt \(receipt != nil) killDone \(killFlag.done)")
            _ = killDone.wait(timeout: .now() + 10); return
        }
        let liveBefore = wait { await reg.unsettledEntryIds() }.contains(job.id)
        _ = wait { await reg.acknowledgeCompletions([receipt]) }          // count-cap pass
        _ = wait { await reg._testSetPruneOverrides(retentionSeconds: 0, countCap: 0) }
        _ = wait { await reg._testPruneNow() }                            // age pass too
        _ = wait { await reg._testSetPruneOverrides(retentionSeconds: nil, countCap: nil) }
        let liveAfter = wait { await reg.unsettledEntryIds() }.contains(job.id)
        let expired = wait { await reg.isExpiredHandle(job.id) }
        _ = wait { await ClaimScopes.shared.tick() }
        let stillTerminating = !killFlag.done
        let held = !FileClaims.claims(ofSelf: a).isEmpty && Tripwire.shared.hasWatches
            && ClaimScopes.shared.pendingScopesForTesting[scope]?.contains(jobKey) == true
        check("S3-R5-1: acknowledging the receipt during the termination grace does not retire the entry (count cap and age pass)",
              liveBefore && liveAfter && !expired, "before \(liveBefore) after \(liveAfter) expired \(expired)")
        check("S3-R5-1: after the acknowledgement and a ticker pass, the claim, pending scope and watch stay while the termination runs",
              held && stillTerminating, "held \(held) stillTerminating \(stillTerminating)")
        _ = killDone.wait(timeout: .now() + 10)
        _ = until(10) { !wait({ await ClaimScopes.liveJobs() }).contains(jobKey) }
        _ = wait { await ClaimScopes.shared.tick() }
        let late = (try? String(contentsOfFile: watched, encoding: .utf8)) ?? ""
        let notices = BoardNotices.pending(b, now: MultiAssistant.now)
        check("S3-R5-1: the child's late write reaches Work's notices before the watch is torn down",
              late.contains("LATE") && notices.contains { $0.path == watched }, "file \(late.debugDescription) notices \(notices.count)")
        check("S3-R5-1: after the termination finished, the claim and the watch are released and the entry retires",
              FileClaims.claims(ofSelf: a).isEmpty && !Tripwire.shared.hasWatches && ClaimScopes.shared.pendingScopesForTesting[scope] == nil)
        _ = wait { await reg._testSetPruneOverrides(retentionSeconds: 0, countCap: 0) }
        _ = wait { await reg._testPruneNow() }
        check("S3-R5-1: once the termination ended, retention may retire the entry again",
              wait { await reg.isExpiredHandle(job.id) })
    }

    // MARK: S3-R4-1 — the root exits on SIGTERM, a same-group child writes late

    private func stage3RootExitsFirst(redirected: Bool) {
        let variant = redirected ? "redirected child" : "child on the inherited pipe"
        guard let fx = makeS3("r4-root-" + (redirected ? "redir" : "pipe")) else { check("S3-R4-1 fixture", false); return }
        defer { fx.release(); resetStage3Seams() }
        let a = fx.ctx("default"), b = fx.ctx("work")
        MultiAssistant.contextOverrideForTesting = a
        ClaimScopes.tickSeconds = 3600
        ClaimScopes.liveJobsOverrideForTesting = nil
        let file = fx.root.appendingPathComponent("rootfirst.txt").path
        let watched = MultiAssistant.canonical(fx.root.appendingPathComponent("watched.txt").path)
        FileManager.default.createFile(atPath: watched, contents: Data("WATCH\n".utf8))
        // Work holds a claim on `watched` (tripwire target).
        try? FileClaims.reserve(b, paths: [watched], opId: "w1")
        try? FileClaims.settle(b, opId: "w1", changed: true, scopes: ["x"], open: { Self.syntheticOpen })
        let turn = UUID(), scope = "turn:" + turn.uuidString.lowercased()
        ClaimScopes.shared.turnStarted(turn)
        try? FileClaims.reserve(a, paths: [file], opId: "rf1")
        try? FileClaims.settle(a, opId: "rf1", changed: true, scopes: [scope])
        guard let snap = wait({ await Tripwire.snapshot(a) }), snap.files.contains(where: { $0.owned.path == watched }) else {
            check("S3-R4-1 (\(variant)): tripwire snapshot of Work's claim", false); return
        }
        // Root: default TERM disposition (exits at once). Child: same process
        // group, traps TERM and appends to the watched file 120 ms later.
        let ready = fx.root.appendingPathComponent("child-ready").path
        let body = "$SIG{TERM}=sub{$t=time()+0.12 unless defined $t}; open(R,\">\",$ARGV[1]); close R; while(1){ if(defined $t && time()>=$t){ open(F,\">>\",$ARGV[0]); print F \"LATE\\n\"; close F; $t=1e18 } sleep 0.005 }"
        let child = "perl -MTime::HiRes=time,sleep -e '\(body)' \"\(watched)\" \"\(ready)\"" + (redirected ? " </dev/null >/dev/null 2>&1" : "")
        guard let job = wait({ try? await BackgroundProcessRegistry.shared.start(command: child + " & while :; do sleep 0.02; done",
                                                                                  workdir: fx.root.path, description: "s3r41") }) else {
            check("S3-R4-1 (\(variant)): start the job", false); return
        }
        let jobKey = "bash:" + job.id
        _ = wait { await Tripwire.shared.afterCommand(a, snap) }
        ClaimScopes.shared.turnEnded(turn)
        guard until(5, { ClaimScopes.shared.pendingScopesForTesting[scope]?.contains(jobKey) == true }) && Tripwire.shared.hasWatches,
              until(10, { FileManager.default.fileExists(atPath: ready) }) else {
            check("S3-R4-1 (\(variant)): T pending on the job, watch registered, child running", false)
            _ = wait { await BackgroundProcessRegistry.shared.kill(handleId: job.id) }
            return
        }
        final class Flag: @unchecked Sendable { var done = false }
        let killFlag = Flag()
        let killDone = DispatchSemaphore(value: 0)
        Task.detached { _ = await BackgroundProcessRegistry.shared.kill(handleId: job.id); killFlag.done = true; killDone.signal() }
        var sawSettledDuringKill = false, droppedDuringKill = false, samples = 0
        while !killFlag.done {
            let live = wait { await ClaimScopes.liveJobs() }
            let settled = wait { await BackgroundProcessRegistry.shared.lifecycleSettledForTesting(handleId: job.id) }
            _ = wait { await ClaimScopes.shared.tick() }
            if killFlag.done { break }
            samples += 1
            if settled { sawSettledDuringKill = true }
            if !live.contains(jobKey) || FileClaims.claims(ofSelf: a).isEmpty || !Tripwire.shared.hasWatches { droppedDuringKill = true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        _ = killDone.wait(timeout: .now() + 10)
        check("S3-R4-1 (\(variant)): throughout the process-tree termination the job counts as alive; the claim, pending scope and watch stay",
              samples > 0 && !droppedDuringKill, "samples \(samples) settledEarly \(sawSettledDuringKill)")
        if redirected {
            check("S3-R4-1: the fixture exercises the root-exits-first ordering (lifecycle settled while the termination was still running)",
                  sawSettledDuringKill, "samples \(samples)")
        }
        _ = until(10) { !wait({ await ClaimScopes.liveJobs() }).contains(jobKey) }
        _ = wait { await ClaimScopes.shared.tick() }
        let late = (try? String(contentsOfFile: watched, encoding: .utf8)) ?? ""
        let notices = BoardNotices.pending(b, now: MultiAssistant.now)
        check("S3-R4-1 (\(variant)): the child's late write reaches the tripwire (Work is told) before the watch is torn down",
              late.contains("LATE") && notices.contains { $0.path == watched }, "file \(late.debugDescription) notices \(notices.count)")
        check("S3-R4-1 (\(variant)): after the termination finished, the claim and the watch are released",
              FileClaims.claims(ofSelf: a).isEmpty && !Tripwire.shared.hasWatches && ClaimScopes.shared.pendingScopesForTesting[scope] == nil)
    }

    // MARK: S3-R3-1 — a job being terminated is still alive

    private func stage3TerminatingJob() {
        guard let fx = makeS3("r3-terminating") else { check("S3-R3-1 fixture", false); return }
        defer { fx.release(); resetStage3Seams() }
        let a = fx.ctx("default")
        MultiAssistant.contextOverrideForTesting = a
        ClaimScopes.tickSeconds = 3600
        ClaimScopes.liveJobsOverrideForTesting = nil   // the real registries
        let file = fx.root.appendingPathComponent("terminating.txt").path
        let turn = UUID(), scope = "turn:" + turn.uuidString.lowercased()
        ClaimScopes.shared.turnStarted(turn)
        try? FileClaims.reserve(a, paths: [file], opId: "tj1")
        try? FileClaims.settle(a, opId: "tj1", changed: true, scopes: [scope])
        // A job that ignores SIGTERM: alive until the SIGKILL escalation.
        let ready = fx.root.appendingPathComponent("job-ready").path
        guard let job = wait({ try? await BackgroundProcessRegistry.shared.start(command: "trap '' TERM; : > \"\(ready)\"; while :; do sleep 0.05; done",
                                                                                  workdir: fx.root.path, description: "s3r31") }) else {
            check("S3-R3-1: start the job", false); return
        }
        let jobKey = "bash:" + job.id
        ClaimScopes.shared.turnEnded(turn)
        guard until(5, { ClaimScopes.shared.pendingScopesForTesting[scope]?.contains(jobKey) == true }),
              until(10, { FileManager.default.fileExists(atPath: ready) }) else {
            check("S3-R3-1: T pending on the job (job running)", false, "\(ClaimScopes.shared.pendingScopesForTesting)")
            _ = wait { await BackgroundProcessRegistry.shared.kill(handleId: job.id) }
            return
        }
        _ = wait { await Tripwire.shared.afterCommand(a, Tripwire.Snapshot(files: [], jobsBefore: [])) }
        let killDone = DispatchSemaphore(value: 0)
        Task.detached { _ = await BackgroundProcessRegistry.shared.kill(handleId: job.id); killDone.signal() }
        Thread.sleep(forTimeInterval: 0.1)   // inside the 300 ms SIGTERM grace
        let sampled = wait { await ClaimScopes.liveJobs() }
        _ = wait { await ClaimScopes.shared.tick() }
        check("S3-R3-1: a job whose kill was requested but whose process tree has not finished still counts as alive",
              sampled.contains(jobKey), "\(sampled)")
        check("S3-R3-1: … so a tick during its termination keeps the claim, the pending scope and the tripwire watch",
              !FileClaims.claims(ofSelf: a).isEmpty && ClaimScopes.shared.pendingScopesForTesting[scope] != nil && Tripwire.shared.hasWatches)
        _ = killDone.wait(timeout: .now() + 10)
        let settled = until(10) { !wait({ await ClaimScopes.liveJobs() }).contains(jobKey) }
        _ = wait { await ClaimScopes.shared.tick() }
        check("S3-R3-1: once the job's lifecycle settled, the next tick releases the claim and the watch",
              settled && FileClaims.claims(ofSelf: a).isEmpty && ClaimScopes.shared.pendingScopesForTesting[scope] == nil && !Tripwire.shared.hasWatches)
    }

    // MARK: S3-R2-1 — a liveness sample older than a pending scope never closes it

    private func stage3StaleSample() {
        guard let fx = makeS3("r2-stale") else { check("S3-R2-1 fixture", false); return }
        defer { fx.release(); resetStage3Seams() }
        let a = fx.ctx("default")
        MultiAssistant.contextOverrideForTesting = a
        ClaimScopes.tickSeconds = 3600   // only the tick this row drives runs
        let file = fx.root.appendingPathComponent("stale.txt").path
        let turn = UUID(), scope = "turn:" + turn.uuidString.lowercased()
        ClaimScopes.shared.turnStarted(turn)
        try? FileClaims.reserve(a, paths: [file], opId: "st1")
        try? FileClaims.settle(a, opId: "st1", changed: true, scopes: [scope])
        // 1. A ticker pass samples while T is still current: no job yet.
        let gate = LiveJobsGate(first: [], later: ["bash:new"])
        ClaimScopes.liveJobsOverrideForTesting = { await gate.snapshot() }
        let tickDone = DispatchSemaphore(value: 0)
        Task.detached { await ClaimScopes.shared.tick(); tickDone.signal() }
        guard until(5, { gate.hasEntered }) else { check("S3-R2-1: the ticker's sample was held open", false); gate.release(); return }
        // 2. Job J starts; T ends; its own sample sees {J} → pending[T] = {J}.
        ClaimScopes.shared.turnEnded(turn)
        let published = until(5) { ClaimScopes.shared.pendingScopesForTesting[scope] == ["bash:new"] }
        // A tripwire watch registered after the old sample (detached Bash job).
        let watchSnap = Tripwire.Snapshot(files: [], jobsBefore: [])
        _ = wait { await Tripwire.shared.afterCommand(a, watchSnap) }
        let watching = Tripwire.shared.hasWatches
        // 3. The old sample finishes.
        gate.release()
        _ = tickDone.wait(timeout: .now() + 10)
        check("S3-R2-1: a scope published after the ticker's liveness sample is not closed by it (its job still runs)",
              published && !FileClaims.claims(ofSelf: a).isEmpty && ClaimScopes.shared.pendingScopesForTesting[scope] != nil,
              "published \(published) claims \(FileClaims.claims(ofSelf: a).count) pending \(ClaimScopes.shared.pendingScopesForTesting)")
        check("S3-R2-1: a tripwire watch added after the sample is not settled by it", watching && Tripwire.shared.hasWatches)
        // The next pass (fresh sample, J ended) closes both normally.
        ClaimScopes.liveJobsOverrideForTesting = { [] }
        _ = wait { await ClaimScopes.shared.tick() }
        check("S3-R2-1: … and a later sample after the job ended closes the scope and the watch",
              FileClaims.claims(ofSelf: a).isEmpty && ClaimScopes.shared.pendingScopesForTesting[scope] == nil && !Tripwire.shared.hasWatches)
    }

    // MARK: S3-R2-2 — an unsettled successful edit keeps its identity

    private func stage3UnsettledReservation() {
        guard let fx = makeS3("r2-unsettled") else { check("S3-R2-2 fixture", false); return }
        defer { fx.release(); resetStage3Seams() }
        let a = fx.ctx("default")
        MultiAssistant.contextOverrideForTesting = a
        ClaimScopes.tickSeconds = 3600
        ClaimScopes.liveJobsOverrideForTesting = { [] }
        let turn = UUID(), scope = "turn:" + turn.uuidString.lowercased()
        ClaimScopes.shared.turnStarted(turn)
        // (a) Store level: a second reservation never takes over a reserved
        // entry of another live operation of the same assistant.
        let file = MultiAssistant.canonical(fx.root.path) + "/u1.txt"
        try? FileClaims.reserve(a, paths: [file], opId: "A")
        var refusedB: String?
        do { try FileClaims.reserve(a, paths: [file], opId: "B") } catch let r as FileClaims.Refusal { refusedB = r.message } catch { refusedB = "\(error)" }
        try? FileClaims.settle(a, opId: "B", changed: false, scopes: [scope])
        try? FileClaims.settle(a, opId: "A", changed: true, scopes: [scope])
        check("S3-R2-2: reserving a path whose earlier edit is still unsettled is refused (\"still being recorded\")",
              refusedB?.contains("still being recorded") == true, refusedB ?? "nil")
        check("S3-R2-2: successful A then failed B then late A settlement → the claim is held",
              FileClaims.claims(ofSelf: a).first { $0.path == file }?.state == FileClaims.held)
        // (b) Hook level (production order): A's settlement times out on
        // claims.lock and is retried; B (same assistant, same file) must wait
        // for A's settlement instead of replacing it.
        let file2 = MultiAssistant.canonical(fx.root.path) + "/u2.txt"
        FileManager.default.createFile(atPath: file2, contents: Data("old".utf8))
        let args = "{\"path\":\"\(file2)\",\"content\":\"new\"}"
        guard case .proceed(let pa)? = wait({ await MultiAssistantHooks.before(toolName: "write_file", argumentsJSON: args) }) else {
            check("S3-R2-2: A's edit proceeds", false); return
        }
        try? "new".write(toFile: file2, atomically: true, encoding: .utf8)
        guard case .acquired(let busy) = ProfileFileLock.take(fx.paths.claimsLock) else { check("S3-R2-2: lock the claims store", false); return }
        _ = wait { await MultiAssistantHooks.after(toolName: "write_file", argumentsJSON: args, resultContent: "{\"success\":true}", pending: pa) }
        let stillReserved = FileClaims.claims(ofSelf: a).first { $0.path == file2 }?.state == FileClaims.reserved
        busy.release()
        let rb = wait { await MultiAssistantHooks.before(toolName: "write_file", argumentsJSON: args) }
        var bProceeded = false
        if case .proceed(let pb)? = rb {
            bProceeded = true
            _ = wait { await MultiAssistantHooks.after(toolName: "write_file", argumentsJSON: args, resultContent: "{\"error\":\"no\"}", pending: pb) }
        }
        Thread.sleep(forTimeInterval: 1.0)
        check("S3-R2-2: A's delayed settlement keeps the in-process path lock (B waits for it, then proceeds)",
              stillReserved && bProceeded, "reserved \(stillReserved) b \(String(describing: rb))")
        check("S3-R2-2: after A's retried settlement and B's failed edit the file stays claimed (A's successful edit is not lost)",
              FileClaims.claims(ofSelf: a).first { $0.path == file2 }?.state == FileClaims.held)
        ClaimScopes.shared.turnEnded(turn)
        _ = until(5) { FileClaims.claims(ofSelf: a).isEmpty }
    }

    // MARK: S3-R2-3 — an out-of-turn edit is bound to the jobs alive now

    private func stage3OutOfTurnScope() {
        guard let fx = makeS3("r2-outside") else { check("S3-R2-3 fixture", false); return }
        defer { fx.release(); resetStage3Seams() }
        let a = fx.ctx("default")
        MultiAssistant.contextOverrideForTesting = a
        ClaimScopes.tickSeconds = 3600
        let jobs = JobsBox()
        ClaimScopes.liveJobsOverrideForTesting = { jobs.value }
        let file = fx.root.appendingPathComponent("outside.txt").path
        let turn = UUID(), scope = "turn:" + turn.uuidString.lowercased()
        ClaimScopes.shared.turnStarted(turn)
        jobs.value = ["agent:old"]
        ClaimScopes.shared.turnEnded(turn)
        guard until(5, { ClaimScopes.shared.pendingScopesForTesting[scope] == ["agent:old"] }) else { check("S3-R2-3: T pending on A", false); return }
        // Job B starts after T's snapshot and edits with no turn running.
        jobs.value = ["agent:old", "agent:new"]
        let scopes = wait { await ClaimScopes.shared.scopesForEdit(opId: "out1") }
        try? FileClaims.reserve(a, paths: [file], opId: "out1")
        try? FileClaims.settle(a, opId: "out1", changed: true, scopes: scopes)
        check("S3-R2-3: an out-of-turn edit gets its own scope bound to the jobs alive now, besides the open ones",
              scopes.contains("op:out1") && scopes.contains(scope) && ClaimScopes.shared.pendingScopesForTesting["op:out1"] == ["agent:old", "agent:new"], "\(scopes)")
        jobs.value = ["agent:new"]
        _ = wait { await ClaimScopes.shared.tick() }
        check("S3-R2-3: when the old job ends but the editing job still runs, the claim stays",
              !FileClaims.claims(ofSelf: a).isEmpty && ClaimScopes.shared.pendingScopesForTesting[scope] == nil)
        jobs.value = []
        _ = wait { await ClaimScopes.shared.tick() }
        check("S3-R2-3: … and goes when the editing job ends", FileClaims.claims(ofSelf: a).isEmpty)
    }
}
