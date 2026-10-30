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
        stage3WipeDuringQueuedStop(timeoutBranch: false)
        stage3WipeDuringQueuedStop(timeoutBranch: true)
    }

    // MARK: S3-R6-1 — the wipe must not drop a /stop batch it has not joined

    /// Codex stage-3 round 6: /stop stamps every selected job and counts its
    /// termination, then terminates them one by one (300 ms each). A wipe
    /// arriving meanwhile must neither drop not-yet-signalled jobs nor, when
    /// its join limit expires, retire entries liveness still counts.
    private func stage3WipeDuringQueuedStop(timeoutBranch: Bool) {
        let variant = timeoutBranch ? "join limit expired" : "default join"
        let count = timeoutBranch ? 6 : 24
        guard let fx = makeS3("r6-wipe-" + (timeoutBranch ? "limit" : "join")) else { check("S3-R6-1 fixture", false); return }
        let reg = BackgroundProcessRegistry.shared
        defer {
            _ = wait { await reg._testSetWipeJoinLimit(nil) }
            fx.release(); resetStage3Seams()
        }
        let a = fx.ctx("default"), b = fx.ctx("work")
        MultiAssistant.contextOverrideForTesting = a
        ClaimScopes.tickSeconds = 3600
        ClaimScopes.liveJobsOverrideForTesting = nil
        let file = fx.root.appendingPathComponent("claimed.txt").path
        let watched = MultiAssistant.canonical(fx.root.appendingPathComponent("watched.txt").path)
        let trigger = fx.root.appendingPathComponent("TRIGGER").path
        FileManager.default.createFile(atPath: watched, contents: Data("WATCH\n".utf8))
        FileManager.default.createFile(atPath: file, contents: Data("OWNER\n".utf8))
        try? FileClaims.reserve(b, paths: [watched], opId: "w1")
        try? FileClaims.settle(b, opId: "w1", changed: true, scopes: ["x"], open: { Self.syntheticOpen })
        let turn = UUID(), scope = "turn:" + turn.uuidString.lowercased()
        ClaimScopes.shared.turnStarted(turn)
        try? FileClaims.reserve(a, paths: [file], opId: "q1")
        try? FileClaims.settle(a, opId: "q1", changed: true, scopes: [scope])
        guard let snap = wait({ await Tripwire.snapshot(a) }), snap.files.contains(where: { $0.owned.path == watched }) else {
            check("S3-R6-1 (\(variant)): tripwire snapshot of Work's claim", false); return
        }
        // TERM-sensitive jobs (default disposition, no fork): each writes its
        // pid, then appends to both files once TRIGGER exists.
        let body = "open(P,\">\",$ARGV[0]); print P $$; close P; while(1){ if(-e $ARGV[1]){ open(F,\">>\",$ARGV[2]); print F \"JOB\\n\"; close F; open(W,\">>\",$ARGV[3]); print W \"LATE\\n\"; close W; exit 0 } sleep 0.001 }"
        var jobs: [String] = [], pidFiles: [String] = []
        for i in 0..<count {
            let pidFile = fx.root.appendingPathComponent("pid-\(i)").path
            let cmd = "exec /usr/bin/perl -MTime::HiRes=sleep -e '\(body)' \"\(pidFile)\" \"\(trigger)\" \"\(file)\" \"\(watched)\""
            guard let j = wait({ try? await reg.start(command: cmd, workdir: fx.root.path, description: "s3r61-\(i)") }) else {
                check("S3-R6-1 (\(variant)): start job \(i)", false); return
            }
            jobs.append(j.id); pidFiles.append(pidFile)
        }
        _ = wait { await Tripwire.shared.afterCommand(a, snap) }
        ClaimScopes.shared.turnEnded(turn)
        guard until(15, { pidFiles.allSatisfy { FileManager.default.fileExists(atPath: $0) } }),
              until(5, { ClaimScopes.shared.pendingScopesForTesting[scope]?.isEmpty == false }), Tripwire.shared.hasWatches else {
            check("S3-R6-1 (\(variant)): jobs running, T pending on them, watch registered", false)
            _ = wait { await reg.purgeAllForWipe() }; return
        }
        final class Flag: @unchecked Sendable { var done = false }
        let stopFlag = Flag()
        let stopDone = DispatchSemaphore(value: 0)
        Task.detached { _ = await reg.stopAllMainOwned(); stopFlag.done = true; stopDone.signal() }
        // /stop has pre-stamped every selected entry.
        _ = until(5) { wait({ await reg.runningBackgroundJobCount() }) == 0 }
        let liveBefore = wait { await reg.unsettledEntryIds() }.intersection(jobs).count
        var retainedReported = -1
        if timeoutBranch {
            _ = wait { await reg._testSetWipeJoinLimit(0.2) }
            retainedReported = wait { await reg.purgeAllForWipeReporting() }.retained
        } else {
            _ = wait { await reg.purgeAllForWipe() }
        }
        let stopStillRunning = !stopFlag.done
        let liveAfter = wait { await reg.unsettledEntryIds() }.intersection(jobs).count
        _ = wait { await ClaimScopes.shared.tick() }
        let claimHeld = !FileClaims.claims(ofSelf: a).isEmpty && Tripwire.shared.hasWatches
        // Any job still alive now (e.g. not yet reached by the /stop batch)
        // would write as soon as TRIGGER exists: none may.
        FileManager.default.createFile(atPath: trigger, contents: Data())
        Thread.sleep(forTimeInterval: 0.3)
        let target = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let watchedText = (try? String(contentsOfFile: watched, encoding: .utf8)) ?? ""
        check("S3-R6-1 (\(variant)): no job survives the wipe's return (no late write to the claimed or the watched file)",
              !target.contains("JOB") && !watchedText.contains("LATE"),
              "claimed \(target.debugDescription) watched \(watchedText.debugDescription)")
        if timeoutBranch {
            check("S3-R6-1 (\(variant)): the fixture queues a /stop batch longer than the join limit",
                  liveBefore == count && stopStillRunning, "liveBefore \(liveBefore) stopStillRunning \(stopStillRunning)")
            check("S3-R6-1 (\(variant)): live entries are kept and reported, not retired; the claim and the watch stay",
                  liveAfter > 0 && retainedReported >= liveAfter && claimHeld,
                  "liveAfter \(liveAfter) reported \(retainedReported) claimHeld \(claimHeld)")
        } else {
            check("S3-R6-1 (\(variant)): the fixture queues a /stop batch longer than 5 s (old join bound)",
                  liveBefore == count, "liveBefore \(liveBefore)")
            check("S3-R6-1 (\(variant)): when the wipe returns, no bound entry is live and the /stop batch has finished",
                  liveAfter == 0 && !stopStillRunning, "liveAfter \(liveAfter) stopStillRunning \(stopStillRunning)")
        }
        _ = stopDone.wait(timeout: .now() + 30)
        if timeoutBranch {
            _ = wait { await reg._testSetWipeJoinLimit(nil) }
            let second = wait { await reg.purgeAllForWipeReporting() }
            check("S3-R6-1 (\(variant)): once the /stop batch ended, a second wipe retires everything",
                  second.retained == 0 && wait({ await reg.unsettledEntryIds() }).intersection(jobs).isEmpty,
                  "retained \(second.retained)")
            _ = wait { await ClaimScopes.shared.tick() }
        }
        check("S3-R6-1 (\(variant)): afterwards the claim and the watch are released",
              FileClaims.claims(ofSelf: a).isEmpty && !Tripwire.shared.hasWatches)
    }

    final class KillFlag: @unchecked Sendable { var done = false }

    /// Fixture for the S3-R5-1 removal paths: start a job whose child ignores
    /// SIGTERM, start `kill()` (300 ms grace) and observe the completion
    /// receipt while that grace still runs. The observation is a setup
    /// precondition, not a product assertion: on a loaded runner the poller
    /// can miss the whole grace (private CI, 0.2.65 candidate), so a missed
    /// ordering is retried with a fresh job (up to 5 attempts) and reported
    /// as a fixture failure only if it never happens.
    private func killDuringGrace(_ fx: S3, reg: BackgroundProcessRegistry, body: String, tag: String, label: String)
        -> (job: BackgroundProcessRegistry.Handle, flag: KillFlag, done: DispatchSemaphore, receipt: BashCompletionReceipt)? {
        for attempt in 1...5 {
            let ready = fx.root.appendingPathComponent("child-ready-\(tag)-\(attempt)").path
            let child = "perl -MTime::HiRes=sleep -e '\(body)' \"\(ready)\" </dev/null >/dev/null 2>&1"
            guard let job = wait({ try? await reg.start(command: child + " & while :; do sleep 0.02; done",
                                                         workdir: fx.root.path, description: "s3r51\(tag)") }),
                  until(10, { FileManager.default.fileExists(atPath: ready) }) else {
                check("\(label): start the job", false); return nil
            }
            let flag = KillFlag()
            let done = DispatchSemaphore(value: 0)
            Task.detached { _ = await reg.kill(handleId: job.id); flag.done = true; done.signal() }
            var receipt: BashCompletionReceipt?
            let deadline = Date().addingTimeInterval(5)
            while receipt == nil && !flag.done && Date() < deadline {
                receipt = wait { await reg.pendingReceipt(handleId: job.id) }
                if receipt == nil { Thread.sleep(forTimeInterval: 0.001) }
            }
            if let receipt, !flag.done {
                print("  (\(label): fixture ordering reached on attempt \(attempt) of 5)")
                return (job, flag, done, receipt)
            }
            // Ordering missed: let this termination finish, settle its notice, retry.
            _ = done.wait(timeout: .now() + 10)
            if let r = wait({ await reg.pendingReceipt(handleId: job.id) }) { _ = wait { await reg.acknowledgeCompletions([r]) } }
            print("  (\(label): receipt not observed inside the grace on attempt \(attempt); retrying)")
        }
        check("\(label): the receipt is published during the termination grace (fixture ordering, 5 attempts)", false)
        return nil
    }

    /// S3-R5-1, the other retirement path: `removeEntry` (the attached
    /// caller dropping its entry) must not retire an entry while another
    /// termination of it (/stop, kill) is still inside its grace.
    private func stage3RemoveEntryDuringTermination() {
        guard let fx = makeS3("r5-remove") else { check("S3-R5-1 removeEntry fixture", false); return }
        defer { fx.release(); resetStage3Seams() }
        let reg = BackgroundProcessRegistry.shared
        let body = "$SIG{TERM}=sub{}; open(R,\">\",$ARGV[0]); close R; while(1){ sleep 0.005 }"
        guard let first = killDuringGrace(fx, reg: reg, body: body, tag: "rm", label: "S3-R5-1 removeEntry") else { return }
        let (job, killFlag, killDone, receipt) = (first.job, first.flag, first.done, first.receipt)
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
        guard let second = killDuringGrace(fx, reg: reg, body: body, tag: "wipe", label: "S3-R5-1 wipe") else { return }
        let (job2, kill2Done) = (second.job, second.done)
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
        // The receipt-during-grace ordering is a setup precondition (see
        // killDuringGrace): a missed ordering reruns the whole scenario with
        // fresh fixtures, up to 5 attempts, and fails only if never reached.
        for attempt in 1...5 {
            if !retentionDuringTerminationAttempt(attempt) {
                print("  (S3-R5-1: fixture ordering reached on attempt \(attempt) of 5)")
                return
            }
            print("  (S3-R5-1: receipt not observed inside the grace on attempt \(attempt); retrying)")
        }
        check("S3-R5-1: the receipt is published during the termination grace (fixture ordering, 5 attempts)", false)
    }

    /// One attempt; returns true only when the fixture ordering was missed
    /// (nothing was asserted, the caller retries).
    private func retentionDuringTerminationAttempt(_ attempt: Int) -> Bool {
        guard let fx = makeS3(attempt == 1 ? "r5-retention" : "r5-retention-\(attempt)") else { check("S3-R5-1 fixture", false); return false }
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
                check("S3-R5-1: start pinned job \(i)", false); return false
            }
            pinned.append(j.id)
        }
        guard until(20, { pinned.allSatisfy { h in wait({ await reg.lifecycleSettledForTesting(handleId: h) }) } }),
              pinned.allSatisfy({ h in wait({ await reg.pendingReceipt(handleId: h) }) != nil }) else {
            check("S3-R5-1: fifty finished jobs with pending completions", false); return false
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
            check("S3-R5-1: tripwire snapshot of Work's claim", false); return false
        }
        let ready = fx.root.appendingPathComponent("child-ready").path
        let body = "$SIG{TERM}=sub{$t=time()+0.25 unless defined $t}; open(R,\">\",$ARGV[1]); close R; while(1){ if(defined $t && time()>=$t){ open(F,\">>\",$ARGV[0]); print F \"LATE\\n\"; close F; $t=1e18 } sleep 0.005 }"
        let child = "perl -MTime::HiRes=time,sleep -e '\(body)' \"\(watched)\" \"\(ready)\" </dev/null >/dev/null 2>&1"
        guard let job = wait({ try? await reg.start(command: child + " & while :; do sleep 0.02; done",
                                                     workdir: fx.root.path, description: "s3r51") }) else {
            check("S3-R5-1: start the job", false); return false
        }
        let jobKey = "bash:" + job.id
        _ = wait { await Tripwire.shared.afterCommand(a, snap) }
        ClaimScopes.shared.turnEnded(turn)
        guard until(5, { ClaimScopes.shared.pendingScopesForTesting[scope]?.contains(jobKey) == true }) && Tripwire.shared.hasWatches,
              until(10, { FileManager.default.fileExists(atPath: ready) }) else {
            check("S3-R5-1: T pending on the job, watch registered, child running", false)
            _ = wait { await reg.kill(handleId: job.id) }
            return false
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
            // Ordering missed: let the termination finish and release it all (defer), retry.
            _ = killDone.wait(timeout: .now() + 10)
            _ = until(10) { !wait({ await ClaimScopes.liveJobs() }).contains(jobKey) }
            _ = wait { await ClaimScopes.shared.tick() }
            if let r = wait({ await reg.pendingReceipt(handleId: job.id) }) { _ = wait { await reg.acknowledgeCompletions([r]) } }
            return true
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
        return false
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
