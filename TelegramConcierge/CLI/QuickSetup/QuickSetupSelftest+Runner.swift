import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - §8.8 job runner

extension SelftestContext {
    func runner() async throws {
        let sh = "/bin/sh"
        func job(_ script: String, mode: SetupJobRunner.Mode = .detached, timeout: TimeInterval = 30, label: String = "job") -> SetupJobRunner.Spec {
            .init(row: "test", command: [sh, "-c", script], mode: mode, timeout: timeout, label: label)
        }
        func fresh() -> SetupJobRunner { SetupJobRunner(secrets: ["testsecret": "hunter2-secret-value-xyz"]) }
        let journal = SetupJobRunner.journalURL

        // Plain success + ring + journal lifecycle.
        do {
            let r = fresh()
            let result = await r.run(job("echo hello; echo err 1>&2; exit 0"))
            check("detached job: exit 0 → ok", result.ok, result.failureReason ?? "")
            let (lines, _) = r.lines(since: 0)
            check("ring has stdout and stderr lines", lines.contains("hello") && lines.contains("err"), "\(lines)")
            check("journal deleted after conclusive reaping", !FileManager.default.fileExists(atPath: journal.path))
            let bad = await r.run(job("exit 7"))
            check("exit 7 → failed with the status", !bad.ok && bad.failureReason == "exited with status 7")
            // lastLines is scoped to the job: a step never reports its predecessor's output.
            r.appendLine("▶ marker written between jobs")
            let second = await r.run(job("echo second-only; echo 'Error: boom' 1>&2; exit 2"))
            check("lastLines holds only the job's own lines", second.lastLines == ["second-only", "Error: boom"] || second.lastLines == ["Error: boom", "second-only"], "\(second.lastLines)")
            check("lastLines excludes earlier jobs and inter-job markers", !second.lastLines.contains("hello") && !second.lastLines.contains { $0.hasPrefix("▶") }, "\(second.lastLines)")
            let silent = await r.run(job("exit 4"))
            check("a job that prints nothing has empty lastLines", silent.lastLines.isEmpty, "\(silent.lastLines)")
            let long = String(repeating: "x", count: 500)
            let excerpt = SetupJobRunner.Result.excerpt(of: ["", "  ", "a", "b", "c", "d", "e", "f", "g", "h", "i", long])
            check("excerpt drops blank lines and keeps the last \(SetupJobRunner.Result.excerptMaxLines)", excerpt.count == SetupJobRunner.Result.excerptMaxLines && excerpt.first == "c" && !excerpt.contains(""), "\(excerpt)")
            check("excerpt cuts over-long lines to \(SetupJobRunner.Result.excerptMaxChars) chars + ellipsis", excerpt.last?.count == SetupJobRunner.Result.excerptMaxChars + 1 && excerpt.last?.hasSuffix("…") == true)
        }
        // Start gate ordering: the child cannot execute before the journal is durable.
        do {
            let r = fresh()
            let marker = tempDir("gate").appendingPathComponent("marker").path
            var markerAtJournal = true
            var journalMtime: Date?
            SetupJobRunner.onJournalPersisted = { _ in
                markerAtJournal = FileManager.default.fileExists(atPath: marker)
                journalMtime = (try? FileManager.default.attributesOfItem(atPath: journal.path))?[.modificationDate] as? Date
            }
            let result = await r.run(job("touch '\(marker)'"))
            SetupJobRunner.onJournalPersisted = nil
            let markerMtime = (try? FileManager.default.attributesOfItem(atPath: marker))?[.modificationDate] as? Date
            check("child did not execute before the journal was on disk", result.ok && !markerAtJournal && journalMtime != nil && markerMtime != nil && journalMtime! <= markerMtime!)
        }
        // Injected journal write failure → the child never runs, exits 125, reaped.
        do {
            let r = fresh()
            let marker = tempDir("gate2").appendingPathComponent("marker").path
            SetupJobRunner.injectJournalWriteFailure = true
            let result = await r.run(job("touch '\(marker)'"))
            SetupJobRunner.injectJournalWriteFailure = false
            try? await Task.sleep(nanoseconds: 300_000_000)
            check("journal persist failure → failedToStart, marker never appears", { if case .failedToStart(let why) = result.outcome { return why.contains("journal") }; return false }() && !FileManager.default.fileExists(atPath: marker))
            check("no journal left behind", !FileManager.default.fileExists(atPath: journal.path))
        }
        // Wrong RELEASE byte → child exits 125 without executing.
        do {
            let r = fresh()
            let marker = tempDir("gate3").appendingPathComponent("marker").path
            SetupJobRunner.releaseByteOverride = 0x02
            let result = await r.run(job("touch '\(marker)'"))
            SetupJobRunner.releaseByteOverride = nil
            check("RELEASE byte other than 0x01 → exit 125, no exec", result.outcome == .exited(125) && !FileManager.default.fileExists(atPath: marker), "\(result.outcome)")
        }
        // Malformed READY (fake trampoline) and a silent child.
        do {
            let fake = tempDir("fake").appendingPathComponent("trampoline.sh")
            try "#!/bin/sh\nprintf 'READY x y\\n' >&3\nexec sleep 5\n".write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            SetupJobRunner.selfExecutableOverride = fake.path
            let r = fresh()
            let result = await r.run(job("true"))
            check("malformed READY line → refused, no RELEASE", { if case .failedToStart(let why) = result.outcome { return why.contains("malformed READY") }; return false }(), "\(result.outcome)")
            let silent = tempDir("fake2").appendingPathComponent("silent.sh")
            try "#!/bin/sh\nexec sleep 20\n".write(to: silent, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: silent.path)
            SetupJobRunner.selfExecutableOverride = silent.path
            SetupJobRunner.readyDeadline = 1
            let r2 = fresh()
            let silentResult = await r2.run(job("true"))
            SetupJobRunner.readyDeadline = 10
            SetupJobRunner.selfExecutableOverride = nil
            check("no READY within the deadline → refused", { if case .failedToStart(let why) = silentResult.outcome { return why.contains("READY") }; return false }(), "\(silentResult.outcome)")
            let wrongPid = tempDir("fake3").appendingPathComponent("wrongpid.sh")
            try "#!/bin/sh\nprintf 'READY 999999 999999 999999\\n' >&3\nexec sleep 5\n".write(to: wrongPid, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrongPid.path)
            SetupJobRunner.selfExecutableOverride = wrongPid.path
            let r3 = fresh()
            let wrong = await r3.run(job("true"))
            SetupJobRunner.selfExecutableOverride = nil
            check("READY naming a pid that is not alive → refused", { if case .failedToStart(let why) = wrong.outcome { return why.contains("not alive") || why.contains("process table") }; return false }(), "\(wrong.outcome)")
        }
        // posix_spawn fallback path: the trampoline is made a group leader so setsid() fails.
        do {
            SetupJobRunner.forceSetsidFallbackForTest = true
            var journaledPid: Int32 = 0
            SetupJobRunner.onJournalPersisted = { journaledPid = $0 }
            let r = fresh()
            let marker = tempDir("fallback").appendingPathComponent("marker").path
            let result = await r.run(job("echo SID $(ps -o sess= -p $$ 2>/dev/null || echo ?); touch '\(marker)'"))
            SetupJobRunner.forceSetsidFallbackForTest = false
            SetupJobRunner.onJournalPersisted = nil
            check("fallback path: job runs and the journaled pid is a session leader (re-spawned leader, not the shim)", result.ok && journaledPid > 0 && FileManager.default.fileExists(atPath: marker))
        }
        // Parent SIGKILLed after READY and before RELEASE (subprocess).
        do {
            let marker = tempDir("die").appendingPathComponent("marker").path
            let jpath = tempDir("die").appendingPathComponent("journal.json").path
            let status1 = spawnAndWait([selfPath, "__quicksetup-selftest", "--job-then-die"],
                                       env: ["BRIGLIA_SELFTEST_MARKER": marker, "BRIGLIA_SELFTEST_JOURNAL": jpath])
            try? await Task.sleep(nanoseconds: 800_000_000)
            check("parent died before RELEASE → child exits without executing (marker absent)", status1 != 0 && !FileManager.default.fileExists(atPath: marker), "status \(status1)")
            // The journal names a pid that is gone → preflight clears it.
            SetupJobRunner.journalURLOverride = URL(fileURLWithPath: jpath)
            let r = fresh()
            let poison = SetupJobRunner.inheritLeftoverJournal(into: r)
            SetupJobRunner.journalURLOverride = nil
            check("leftover journal for a gone pid → cleared, no poison", poison == nil && !FileManager.default.fileExists(atPath: jpath))
        }
        // Parent SIGKILLed mid-job (child alive) → next preflight poisoned; child killed → re-check clears.
        do {
            let jpath = tempDir("die2").appendingPathComponent("journal.json").path
            let status2 = spawnAndWait([selfPath, "__quicksetup-selftest", "--job-then-die"],
                                       env: ["BRIGLIA_SELFTEST_JOURNAL": jpath, "BRIGLIA_SELFTEST_DIE_AFTER_RELEASE": "1"])
            SetupJobRunner.journalURLOverride = URL(fileURLWithPath: jpath)
            let r = fresh()
            if ProcessInfo.processInfo.environment["BRIGLIA_SELFTEST_DEBUG"] == "1",
               let data = try? Data(contentsOf: URL(fileURLWithPath: jpath)),
               let j = try? JSONDecoder.iso.decode(SetupJobRunner.Journal.self, from: data) {
                print("DEBUG journal pid=\(j.pid) pgid=\(j.pgid) start=\(j.startTime) boot=\(j.bootID ?? "nil") now=\(ManagedPlaywright.ProcessGroups.bootID() ?? "nil")")
                print("DEBUG members=\(String(describing: ManagedPlaywright.ProcessGroups.members(of: j.pgid)))")
                print("DEBUG stillAlive=\(String(describing: ManagedPlaywright.ProcessGroups.stillAlive([.init(pid: j.pid, startTime: j.startTime)])))")
                print("DEBUG subprocess status=\(status2)")
            }
            let poison = SetupJobRunner.inheritLeftoverJournal(into: r)
            check("parent killed mid-job → journal survives, child alive → poisoned", poison != nil && !(poison?.survivors.isEmpty ?? true), "\(String(describing: poison))")
            if let poison {
                for s in poison.survivors { kill(-poison.pgid, SIGKILL); kill(s.pid, SIGKILL) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                let after = r.recheckPoison()
                check("child killed → re-check clears the poison and deletes the journal", after == nil && !FileManager.default.fileExists(atPath: jpath), "\(String(describing: after))")
            }
            // Leader exits, descendant survives (apt/dpkg after sudo): must fail closed.
            let jpath3 = tempDir("die3").appendingPathComponent("journal.json").path
            let status3 = spawnAndWait([selfPath, "__quicksetup-selftest", "--job-then-die"],
                                       env: ["BRIGLIA_SELFTEST_JOURNAL": jpath3, "BRIGLIA_SELFTEST_DIE_AFTER_RELEASE": "1",
                                             "BRIGLIA_SELFTEST_DIE_DELAY": "0.3", "BRIGLIA_SELFTEST_JOB_CMD": "sleep 60 & sleep 1; exit 0"])
            try? await Task.sleep(nanoseconds: 1_800_000_000)   // the leader has exited by now; the sleep lives on
            SetupJobRunner.journalURLOverride = URL(fileURLWithPath: jpath3)
            let r3 = fresh()
            let poison3 = SetupJobRunner.inheritLeftoverJournal(into: r3)
            check("journaled leader gone but a descendant survives in its group → poisoned (fail closed)", status3 != 0 && poison3 != nil && (poison3?.survivors.contains { $0.note == "group member" } ?? false), "\(String(describing: poison3))")
            if let poison3 {
                for s in poison3.survivors { kill(s.pid, SIGKILL) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                check("descendant killed → re-check clears", r3.recheckPoison() == nil)
            }
            // Unreadable journal → treated as alive.
            SetupJobRunner.journalURLOverride = URL(fileURLWithPath: jpath)
            try "not json".write(toFile: jpath, atomically: true, encoding: .utf8)
            let r2 = fresh()
            let unreadable = SetupJobRunner.inheritLeftoverJournal(into: r2)
            check("unreadable journal → poisoned (fail closed) with instructions", unreadable?.unreadableJournal != nil)
            unlink(jpath)
            check("deleting the unreadable journal by hand → re-check clears", r2.recheckPoison() == nil)
            SetupJobRunner.journalURLOverride = nil
        }
        // Poison via a survivor the enumeration keeps listing; identity-checked clearing.
        SetupJobRunner.reapScanWindow = 1
        defer { SetupJobRunner.reapScanWindow = 15 }
        do {
            let r = fresh()
            var fakePid: Int32 = 0
            SetupJobRunner.onJournalPersisted = { fakePid = $0 }
            var listing = true
            var startTimeShift: UInt64 = 0
            // Spawn-time verification asks for the real group (pgid > 0): answer
            // with the leader; later scans and `stillAlive` (pgid == -1) keep
            // listing the journaled pid until the test changes its start time.
            ManagedPlaywright.ProcessGroups.membersOverride = { pgid in
                guard listing else { return [] }
                let pid = pgid > 0 ? pgid : fakePid
                return [.init(identity: .init(pid: pid, startTime: 12345 + startTimeShift), zombie: false)]
            }
            let result = await r.run(job("true"))
            SetupJobRunner.onJournalPersisted = nil
            check("survivor the scan keeps listing → failed with the survivor named, runner poisoned", !result.ok && result.survivors?.first?.pid == fakePid && r.isPoisoned, "\(result.outcome) \(String(describing: result.survivors))")
            check("journal kept while poisoned", FileManager.default.fileExists(atPath: journal.path))
            let refused = await r.run(job("true"))
            check("no job starts while poisoned", { if case .failedToStart = refused.outcome { return true }; return false }())
            check("re-check with the survivor still listed → still poisoned", r.recheckPoison() != nil)
            startTimeShift = 1   // same pid, different start time = a different process
            check("re-check with a different start time for the same pid → cleared, journal deleted", r.recheckPoison() == nil && !FileManager.default.fileExists(atPath: journal.path))
            listing = false
            ManagedPlaywright.ProcessGroups.membersOverride = nil
            // Enumeration failure fallback: kill(-pgid, 0) ESRCH proves absence.
            let enumCalls = Counter()
            ManagedPlaywright.ProcessGroups.membersOverride = { pgid in
                // First call (spawn-time verification) succeeds; the reaping scan fails.
                enumCalls.next() == 1 ? [.init(identity: .init(pid: pgid, startTime: 1), zombie: false)] : nil
            }
            let r2 = fresh()
            let result2 = await r2.run(job("true"))
            ManagedPlaywright.ProcessGroups.membersOverride = nil
            check("enumeration failing but the group gone (ESRCH) → not poisoned", result2.ok && !r2.isPoisoned, "\(result2.outcome) \(result2.enumerationFailed)")
        }
        // Workflow-level poison: 409 on mutating routes, recheck route.
        do {
            let (env, store) = stubEnv()
            let (wf, r) = try makeWorkflow(env, resume: .system)
            var fakePid: Int32 = 0
            SetupJobRunner.onJournalPersisted = { fakePid = $0 }
            var shift: UInt64 = 0
            ManagedPlaywright.ProcessGroups.membersOverride = { pgid in [.init(identity: .init(pid: pgid > 0 ? pgid : fakePid, startTime: 777 + shift), zombie: false)] }
            store.toolchain = ToolchainService.DesktopStatus(doctorRan: true, missing: ["pandoc"], libreOffice: true, mandatoryMissing: ["pandoc"])
            store.toolchainJobs = [job("true", label: "x")]
            let g = await wf.generation
            for row in ["fda", "keepawake"] { _ = try await wf.systemRun(row: row, option: nil, generation: g); try? await Task.sleep(nanoseconds: 200_000_000) }
            _ = try await wf.systemRun(row: "toolchain", option: nil, generation: g)
            for _ in 0..<100 { try? await Task.sleep(nanoseconds: 50_000_000); if r.isPoisoned { break } }
            SetupJobRunner.onJournalPersisted = nil
            check("workflow poisoned after the unconfirmed survivor", r.isPoisoned)
            let (s1, _) = try await wf.systemRun(row: "toolchain", option: nil, generation: g)
            let (s2, _) = try await wf.finish(generation: g)
            let (s3, _) = try await wf.stepByStep(generation: g)
            check("system/run, finish, stepbystep → 409 while poisoned", s1 == 409 && s2 == 409 && s3 == 409, "\(s1) \(s2) \(s3)")
            let statusP = await wf.status()
            check("status still readable and reports the survivors", (statusP["poisoned"] as? [String: Any]) != nil)
            _ = await wf.rotate()
            let tokenP = await wf.launchToken
            check("a new link is still issued while poisoned", !tokenP.isEmpty)
            let (_, still) = await wf.recoverRecheck()
            check("recheck with the survivor still listed → still poisoned", !(still["poisoned"] is NSNull))
            shift = 5
            let (_, cleared) = await wf.recoverRecheck()
            ManagedPlaywright.ProcessGroups.membersOverride = nil
            check("recheck with a different start time → cleared", cleared["poisoned"] is NSNull)
            let poisonK = r.signalSurvivorsAndRecheck()
            check("terminal K after clearing is a no-op", poisonK == nil)
        }
        // Large output, ring bound, redaction, timeout with a TERM-ignoring child and grandchild.
        do {
            let r = fresh()
            let big = await r.run(job("i=0; while [ $i -lt 400000 ]; do echo 'line of output number' $i; i=$((i+1)); done"))
            let (lines, next) = r.lines(since: 0)
            check("child writing ~10 MB completes (no pipe hang)", big.ok, big.failureReason ?? "")
            check("ring holds only the last 200 lines", lines.count <= 200 && next >= 400000 - 1, "\(lines.count) \(next)")
            let r2 = fresh()
            _ = await r2.run(job("echo the secret is hunter2-secret-value-xyz here"))
            let (redacted, _) = r2.lines(since: 0)
            check("a secret in the output is redacted in the ring", redacted.contains { $0.contains("[REDACTED:quicksetup.testsecret]") } && !redacted.contains { $0.contains("hunter2-secret-value-xyz") }, "\(redacted)")
            SetupJobRunner.termGrace = 1
            let r3 = fresh()
            let t0 = Date()
            let timed = await r3.run(job("trap '' TERM; (sleep 30 &) ; sleep 30", timeout: 1))
            SetupJobRunner.termGrace = 5
            check("timeout kills a TERM-ignoring child and its grandchild, reaping confirmed", timed.outcome == .timedOut && timed.survivors == nil && !r3.isPoisoned && Date().timeIntervalSince(t0) < 25, "\(timed.outcome) \(String(describing: timed.survivors))")
            // Cancellation from another task.
            let r4 = fresh()
            let task = Task { await r4.run(job("sleep 30")) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            let poison = await r4.cancelRunning()
            let cancelled = await task.value
            check("cancelRunning() returns after confirmed reaping, outcome cancelled", poison == nil && cancelled.outcome == .cancelled && r4.currentJob == nil)
            // Handoff mode without a tty: refused before RELEASE, listener resumed.
            let r5 = fresh()
            let listener = FakeListener()
            r5.listener = listener
            let handoff = await r5.run(job("true", mode: .terminalHandoff))
            check("handoff job without a terminal → refused (stdin is not a terminal), child exits 125", { if case .failedToStart(let why) = handoff.outcome { return why.contains("terminal") }; return false }(), "\(handoff.outcome)")
            check("listener suspended then resumed around the failed lend", listener.suspends == 1 && listener.resumes == 1, "\(listener.suspends)/\(listener.resumes)")
            // With the lend skipped (test flag) the handoff trampoline keeps pgid == pid in our session.
            SetupJobRunner.skipLendForTest = true
            let r6 = fresh()
            let gate = await r6.run(job("echo pgid $(ps -o pgid= -p $$ | tr -d ' ') pid $$", mode: .terminalHandoff))
            SetupJobRunner.skipLendForTest = false
            let (gl, _) = r6.lines(since: 0)
            let sameGroup = gl.first.flatMap { line -> Bool? in
                let parts = line.split(separator: " ")
                guard parts.count == 4 else { return nil }
                return parts[1] == parts[3]
            } ?? false
            check("__gate-exec: pgid == pid (group leader in the terminal's session)", gate.ok && sameGroup, "\(gl)")
        }
    }
}

final class FakeListener: StdinListenerControl, @unchecked Sendable {
    var suspends = 0
    var resumes = 0
    func suspend() { suspends += 1 }
    func resume() { resumes += 1 }
}

// MARK: - Subprocess modes

enum SelftestSubprocess {
    /// Runs one job whose command touches a marker; dies with SIGKILL at the
    /// journal-persisted point (before RELEASE) — or, with
    /// BRIGLIA_SELFTEST_DIE_AFTER_RELEASE, once the child is running.
    static func jobThenDie() async throws {
        let env = ProcessInfo.processInfo.environment
        let marker = env["BRIGLIA_SELFTEST_MARKER"] ?? "/dev/null"
        if let j = env["BRIGLIA_SELFTEST_JOURNAL"] { SetupJobRunner.journalURLOverride = URL(fileURLWithPath: j) }
        let afterRelease = env["BRIGLIA_SELFTEST_DIE_AFTER_RELEASE"] == "1"
        let delay = Double(env["BRIGLIA_SELFTEST_DIE_DELAY"] ?? "") ?? 0.5
        let jobCommand = env["BRIGLIA_SELFTEST_JOB_CMD"] ?? (afterRelease ? "sleep 60" : "touch '\(marker)'")
        let runner = SetupJobRunner()
        if !afterRelease {
            // A process-directed SIGKILL may land on another thread first;
            // never let this thread reach the RELEASE write (a real crash
            // executes nothing further either).
            SetupJobRunner.onJournalPersisted = { _ in kill(getpid(), SIGKILL); while true { sleep(10) } }
        } else {
            SetupJobRunner.onJournalPersisted = { _ in
                Thread.detachNewThread { Thread.sleep(forTimeInterval: delay); kill(getpid(), SIGKILL) }
            }
        }
        _ = await runner.run(.init(row: "t", command: ["/bin/sh", "-c", jobCommand],
                                   mode: .detached, timeout: 120, label: "die"))
    }

    /// One AgentMail install against a fixture, optionally crashing at a
    /// named point, optionally holding the lock for a while before finishing.
    static func agentMail(crash: String?, dir: String, fixture: String, sums: String, hold: Double) async throws {
        AgentMailService.installDirectoryOverride = URL(fileURLWithPath: dir, isDirectory: true)
        AgentMailService.crashPoint = crash
        let archive = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let checksums = try Data(contentsOf: URL(fileURLWithPath: sums))
        let asset = URL(fileURLWithPath: fixture).lastPathComponent
        let version = ProcessInfo.processInfo.environment["BRIGLIA_SELFTEST_AM_VERSION"] ?? "1.0.0"
        AgentMailService.downloadOverride = { _ in
            if hold > 0 { try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)) }
            return (version, asset, archive, checksums)
        }
        let failure = await AgentMailService.installAgentMailBinary()
        if let failure {
            print("FAILURE: \(failure)")
            Foundation.exit(1)
        }
        print("OK")
    }
}

extension SelftestContext {
    /// Spawn `argv` with `env` through posix_spawn and wait for it. Returns
    /// the raw wait status. Foundation `Process` is avoided on purpose: on
    /// Linux (corelibs) a child that dies by signal did not leave its own
    /// detached descendants running the way a shell-launched one does,
    /// which is exactly the situation the crash tests must reproduce.
    func spawnAndWait(_ argv: [String], env extra: [String: String]) -> Int32 {
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }
        var cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)
        defer { for p in cargs { free(p) }; for p in cenv { free(p) } }
        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        #else
        var actions: posix_spawn_file_actions_t? = nil
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var pid: pid_t = 0
        guard posix_spawn(&pid, argv[0], &actions, nil, cargs, cenv) == 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        return status
    }
}
