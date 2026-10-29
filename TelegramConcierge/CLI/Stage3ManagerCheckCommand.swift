import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden child of `__multi-assistant-selftest` (an assistant member in the
/// harness's scratch roots, with at least one extra registered): the
/// default's coordinated `/upgrade` beside the poll loop (S2-12) and the
/// multi-assistant `/status` and `/board` surfaces of a REAL manager.
struct Stage3ManagerCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__stage3-manager-check",
        abstract: "Internal: stage-3 checks of a real manager.",
        shouldDisplay: false
    )

    @Flag(name: .customLong("wipe")) var wipeOnly = false

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev"), let lease = MemberEntry.current else {
            print("CHECK 0 needs a development build and a member lease"); return
        }
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("CHECK \(ok ? 1 : 0) \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        }
        let m = ConversationManager()
        if wipeOnly {
            await wipeKeepsProtectedClaims(m, check: check)
            print("STAGE3_WIPE_DONE")
            return
        }
        let paths = UpgradeBarrier.Paths.live
        let held: ProfileFileLock? = { if case .acquired(let l) = ProfileFileLock.take(paths.lock) { return l }; return nil }()
        let other = UpgradeBarrier.Participant(profile: "work", generation: "g", lease: "0ther-1ease", incarnation: "inc-1", coordinator: false)
        let me = UpgradeBarrier.Participant(profile: "default", generation: nil, lease: lease.uuid, incarnation: lease.sidecar.incarnation, coordinator: true)
        let barrier = UpgradeBarrier.Record(id: "s3-1", state: .open, targetVersion: "9.9.9", targetSequence: 999, openedAt: Date(),
                                            coordinator: .init(lease: lease.uuid, pid: getpid(), processStartTime: ProcessIdentity.selfStartTime),
                                            participants: [me, other], committedBinarySHA256: nil, reason: nil)
        try? UpgradeBarrier.writeBarrier(barrier, paths)
        MemberEntry.isCoordinator = true
        m.upgradeCoordinatorTask = Task { try? await Task.sleep(nanoseconds: 120_000_000_000) }
        m.upgradeWaitingFor = ["‘Work’ (a job to finish)"]

        await m.upgradeMonitorTick(lease: lease)
        check("S2-12: the coordinating assistant does not park while another participant is still busy",
              !m.admissionPaused && UpgradeBarrier.readAck(lease.uuid, paths) == nil)
        let status = (await m.handleTerminalCommand("/status") ?? []).joined(separator: "\n")
        check("S2-12: /status answers during the wait and names who is still busy",
              status.contains("waiting for ‘Work’") && status.contains("Assistant: ") && status.contains("others: Work"), status)
        let again = (await m.handleTerminalCommand("/upgrade") ?? []).joined()
        check("S2-12: a second /upgrade answers at once (already in progress)", again.contains("already in progress"), again)
        let stop = (await m.handleTerminalCommand("/stop") ?? []).joined()
        check("S2-12: /stop is read during the wait and cancels the waiting update", m.upgradeCancelFlag.value
              && stop.contains("cancelled"), stop)
        m.upgradeCancelFlag.reset()
        _ = await m.handleTerminalCommand("/upgrade cancel")
        check("S2-12: /upgrade cancel raises the coordinator's cancel flag", m.upgradeCancelFlag.value)
        m.upgradeCancelFlag.reset()

        UpgradeBarrier.writeAck(.init(barrierId: barrier.id, incarnation: "inc-1", state: .parked, reason: nil,
                                      releaseSequence: ReleaseSequence.compiled), lease: other.lease, paths)
        await m.upgradeMonitorTick(lease: lease)
        check("S2-12: once every other participant parked, the coordinator parks itself (admission paused, acked parked)",
              m.admissionPaused && UpgradeBarrier.readAck(lease.uuid, paths)?.state == .parked)
        let parkedUpgrade = (await m.handleTerminalCommand("/upgrade cancel") ?? []).joined()
        check("S2-12: while parked, /upgrade cancel is still accepted (not the generic 'updating' refusal)",
              m.upgradeCancelFlag.value && !parkedUpgrade.contains("try again in a minute"), parkedUpgrade)
        m.upgradeCancelFlag.reset()
        m.browserSettingsCommandIngress += 1
        let busy = await m.upgradeBusyReason(initiating: true)
        m.browserSettingsCommandIngress -= 1
        check("S2-12: with the coordinator running as a task, a command in its handler counts as busy (no allowance)",
              busy == "a command", busy ?? "nil")

        var cancelled = barrier; cancelled.state = .cancelled
        try? UpgradeBarrier.writeBarrier(cancelled, paths)
        await m.upgradeMonitorTick(lease: lease)
        check("S2-12: cancelled → the coordinator resumes", !m.admissionPaused)
        m.upgradeCoordinatorTask?.cancel()
        m.upgradeCoordinatorTask = nil
        MemberEntry.isCoordinator = false
        try? FileManager.default.removeItem(at: paths.barrier)
        held?.release()

        let board = (await m.handleTerminalCommand("/board") ?? []).joined(separator: "\n")
        check("/board answers with the full board while several assistants exist", board.contains("Assistant board"), board)
        // S3-7: a terminal/app /upgrade receives the delayed result.
        UpgradeService.checkOverrideForTesting = {
            try? await Task.sleep(nanoseconds: 800_000_000)
            return .upToDate("9.9.9-test")
        }
        let local = (await m.handleTerminalCommand("/upgrade") ?? []).joined(separator: "\n")
        UpgradeService.checkOverrideForTesting = nil
        check("S3-7: a terminal/app /upgrade gets the acknowledgement and the delayed result in its reply",
              local.contains("Checking for an update") && local.contains("Already up to date (9.9.9-test)") && m.upgradeCoordinatorTask == nil, local)
        await successfulUpgradeDeliversBeforeRestart(m, lease: lease, check: check)
        print("STAGE3_DONE")
    }

    /// Holds the FIRST liveness sample open (on a continuation) until
    /// `release()`; it then returns the actual sample. Later samples pass
    /// straight through.
    final class FirstSampleGate: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false, entered = false, released = false
        private var cont: CheckedContinuation<Void, Never>?
        func sample() async -> Set<String> {
            lock.lock()
            if used { lock.unlock(); return await ClaimScopes.actualLiveJobs() }
            used = true; entered = true; lock.unlock()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released { lock.unlock(); c.resume() } else { cont = c; lock.unlock() }
            }
            return await ClaimScopes.actualLiveJobs()
        }
        var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func release() { lock.lock(); released = true; let c = cont; cont = nil; lock.unlock(); c?.resume() }
    }

    /// Owner decision 2026-10-29 (replacing the per-path claim guards of
    /// Codex stage-3 S3-R7-1…S3-R9-1): with several assistants the real
    /// `/deleteuserdata` wipe — and a Mind import — REFUSES while background
    /// work is running or being stopped, or a claim scope is still open.
    /// Codex's round 6–9 sequences (a queued `/stop` batch with the scope
    /// pending, the turn-end sample in progress, the context lost through a
    /// peer's `removing` record) now get that refusal with nothing deleted;
    /// the scope-only, subagent and second-check variants cover each term.
    @MainActor private func wipeKeepsProtectedClaims(_ m: ConversationManager,
                                                     check: @escaping (String, Bool, String) -> Void) async {
        guard let ctx = MultiAssistant.context() else { check("wipe refusal: multi-assistant context", false, "nil"); return }
        guard let peer = ctx.peers.first, let doc = (try? AssistantRegistry.read(.live)) ?? nil,
              let peerCtx = MultiAssistant.context(doc: doc, profile: peer.profile, lease: UUID().uuidString.lowercased(),
                                                   incarnation: "s3r81", paths: ctx.paths) else {
            check("wipe refusal: a peer context", false, "peers \(ctx.peers.count)"); return
        }
        ClaimScopes.tickSeconds = 3600   // only explicit ticks in this check
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        await wipeRefusalCase(m, ctx: ctx, peerCtx: peerCtx, mode: .pending, check: check)
        await wipeRefusalCase(m, ctx: ctx, peerCtx: peerCtx, mode: .ending, check: check)
        await wipeRefusalCase(m, ctx: ctx, peerCtx: peerCtx, mode: .contextLoss, check: check)
        await wipeRefusalCase(m, ctx: ctx, peerCtx: peerCtx, mode: .endingNoJobs, check: check)
        await wipeRefusalCase(m, ctx: ctx, peerCtx: peerCtx, mode: .contextLossNoJobs, check: check)
        await wipeRefusesForSubagent(m, check: check)
        await wipeSecondCheckRefuses(m, check: check)
        await admittedInputRefuses(m, importPath: false, check: check)
        await admittedInputRefuses(m, importPath: true, check: check)
        await admittedTurnRefuses(m, check: check)
        await stuckIngressRefuses(m, check: check)
        check("wipe refusal: every refused wipe deleted nothing (the stored name survives)",
              KeychainHelper.load(key: KeychainHelper.userNameKey) == "Sentinel", KeychainHelper.load(key: KeychainHelper.userNameKey) ?? "nil")
        // The ordinary case: nothing live, the wipe runs and removes this
        // assistant's claims file.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s3r71-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = MultiAssistant.canonical(dir.appendingPathComponent("claimed.txt").path)
        try? FileClaims.reserve(ctx, paths: [file], opId: "wipe2")
        try? FileClaims.settle(ctx, opId: "wipe2", changed: true, scopes: ["op:wipe2-gone"])
        // The Telegram command running the wipe is its own poll tick (no
        // command capture): that one ingress is not waited for.
        m._testSetBrowserSettingsPollIngress(1)
        let waitsBefore = ConversationManager.admissionWaitsForTesting
        let second = await m.deleteAllMemory()
        m._testSetBrowserSettingsPollIngress(0)
        check("S3-R10-1: the wipe's own poll tick (a Telegram command) is not counted as admitted input",
              ConversationManager.admissionWaitsForTesting == waitsBefore, "waits \(ConversationManager.admissionWaitsForTesting - waitsBefore)")
        check("wipe refusal: with nothing live, the wipe runs and removes this assistant's claims file",
              !FileManager.default.fileExists(atPath: ctx.paths.claimsFile(ctx.me.profile).path)
              && !second.contains { $0.hasPrefix("ABORTED") } && KeychainHelper.load(key: KeychainHelper.userNameKey) == nil, "\(second)")
        ClaimScopes.tickSeconds = 2
    }

    enum WipeMode { case pending, ending, contextLoss, endingNoJobs, contextLossNoJobs }

    static func isWorkRefusal(_ failures: [String]) -> Bool {
        guard let f = failures.first else { return false }
        return f.hasPrefix("ABORTED: Background jobs are still running") && f.contains("fermali prima (o usa /stop)")
            && f.contains("Nothing was deleted.") && failures.count == 1
    }

    @MainActor private func wipeRefusalCase(_ m: ConversationManager, ctx: MultiAssistant.Context, peerCtx: MultiAssistant.Context,
                                            mode: WipeMode, check: @escaping (String, Bool, String) -> Void) async {
        let tag: String
        switch mode {
        case .pending: tag = "S3-R6/R7 (queued /stop batch, scope pending)"
        case .ending: tag = "S3-R8 (turn-end sample in progress)"
        case .contextLoss: tag = "S3-R9 (context lost through a peer's `removing`)"
        case .endingNoJobs: tag = "wipe refusal (open `ending` scope, no job)"
        case .contextLossNoJobs: tag = "wipe refusal (pending scope that cannot close, context lost, no job)"
        }
        let withJobs = mode == .pending || mode == .ending || mode == .contextLoss
        let gated = mode == .ending || mode == .endingNoJobs
        let lose = mode == .contextLoss || mode == .contextLossNoJobs
        let reg = BackgroundProcessRegistry.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s3r10-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = MultiAssistant.canonical(dir.appendingPathComponent("claimed.txt").path)
        let trigger = dir.appendingPathComponent("TRIGGER").path
        FileManager.default.createFile(atPath: file, contents: Data("OWNER\n".utf8))
        let turn = UUID(), scope = "turn:" + turn.uuidString.lowercased()
        let op = "wipe1-\(mode)"
        ClaimScopes.shared.turnStarted(turn)
        try? FileClaims.reserve(ctx, paths: [file], opId: op)
        try? FileClaims.settle(ctx, opId: op, changed: true, scopes: [scope])
        let body = "open(P,\">\",$ARGV[0]); print P $$; close P; while(1){ if(-e $ARGV[1]){ open(F,\">>\",$ARGV[2]); print F \"JOB\\n\"; close F; exit 0 } sleep 0.001 }"
        var jobs: [String] = [], pidFiles: [String] = []
        for i in 0..<(withJobs ? 6 : 0) {
            let pidFile = dir.appendingPathComponent("pid-\(i)").path
            let cmd = "exec /usr/bin/perl -MTime::HiRes=sleep -e '\(body)' \"\(pidFile)\" \"\(trigger)\" \"\(file)\""
            guard let j = try? await reg.start(command: cmd, workdir: dir.path, description: "s3r10-\(i)") else {
                check("\(tag): start job \(i)", false, ""); return
            }
            jobs.append(j.id); pidFiles.append(pidFile)
        }
        let readyBy = Date().addingTimeInterval(15)
        while !pidFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) && Date() < readyBy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // A peer's `removing` record (what a profile removal publishes before
        // it checks the leases): the context resolves to nil. Every other
        // ACTIVE record flips; exactly those are restored.
        var flipped: [String] = []
        func setPeerState(_ state: String) {
            try? AssistantRegistry.withLock(.live) { doc in
                guard var d = doc else { return }
                if state == "removing" {
                    flipped = d.records.filter { $0.name != ctx.me.profile && $0.state == "active" }.map(\.name)
                }
                for name in flipped {
                    guard let i = d.index(name) else { continue }
                    d.records[i].state = state
                    d.records[i].removingOp = state == "removing" ? "s3r10-paused-removal" : nil
                }
                doc = d
            }
            MultiAssistant.invalidate()
        }
        if lose && !withJobs { setPeerState("removing") }   // the turn ends while the context is unavailable
        let gate = FirstSampleGate()
        if gated { ClaimScopes.liveJobsOverrideForTesting = { await gate.sample() } }
        ClaimScopes.shared.turnEnded(turn)
        if gated {
            let enteredBy = Date().addingTimeInterval(5)
            while !gate.hasEntered && Date() < enteredBy { try? await Task.sleep(nanoseconds: 5_000_000) }
            check("\(tag): the fixture holds the turn's scope in `ending` (open, not yet pending)",
                  gate.hasEntered && ClaimScopes.shared.openScopes().contains(scope)
                  && ClaimScopes.shared.pendingScopesForTesting[scope] == nil, "entered \(gate.hasEntered)")
        } else {
            let handedBy = Date().addingTimeInterval(5)
            while ClaimScopes.shared.pendingScopesForTesting[scope] == nil && Date() < handedBy { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        if lose && withJobs { setPeerState("removing") }
        if lose {
            check("\(tag): the fixture loses the context while the scope stays open",
                  MultiAssistant.context() == nil && ClaimScopes.shared.openScopes().contains(scope),
                  "context \(MultiAssistant.context() != nil) open \(ClaimScopes.shared.openScopes().contains(scope)) flipped \(flipped)")
        }
        // Codex's R6–R9 ordering: a queued /stop batch is still terminating
        // when the wipe arrives.
        let stop = Task.detached { _ = await reg.stopAllMainOwned() }
        if withJobs {
            let stampedBy = Date().addingTimeInterval(5)
            while await reg.runningBackgroundJobCount() != 0 && Date() < stampedBy {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        await reg._testSetWipeJoinLimit(0.2)
        let failures = await m.deleteAllMemory()
        await reg._testSetWipeJoinLimit(nil)
        var stillListed = 0
        for j in jobs where await reg.hasEntryForTesting(handleId: j) { stillListed += 1 }
        check("\(tag): /deleteuserdata refuses (EN + IT) and deletes nothing",
              Self.isWorkRefusal(failures) && FileManager.default.fileExists(atPath: ctx.paths.claimsFile(ctx.me.profile).path)
              && stillListed == jobs.count
              && (withJobs ? failures[0].contains("background command(s)") : failures[0].contains("file claims still in use")),
              "listed \(stillListed)/\(jobs.count) failures \(failures)")
        if lose {
            setPeerState("active")   // the removal refused and restored the record
            check("\(tag): the context recovers", MultiAssistant.context() != nil, "")
        }
        let held = FileClaims.claims(ofSelf: ctx).contains { $0.path == file }
        var peerRefused = false
        do { try FileClaims.reserve(peerCtx, paths: [file], opId: "peer-\(mode)") } catch { peerRefused = true }
        if !peerRefused { _ = try? FileClaims.settle(peerCtx, opId: "peer-\(mode)", changed: false, scopes: []) }
        check("\(tag): after the refusal the claim is still held and a peer's edit is refused",
              held && peerRefused && ClaimScopes.shared.openScopes().contains(scope), "held \(held) peerRefused \(peerRefused)")
        FileManager.default.createFile(atPath: trigger, contents: Data())
        gate.release()
        await stop.value
        ClaimScopes.liveJobsOverrideForTesting = nil
        let settledBy = Date().addingTimeInterval(10)
        while !(await reg.unsettledEntryIds().isDisjoint(with: jobs)) && Date() < settledBy {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let handedBy = Date().addingTimeInterval(5)
        while ClaimScopes.shared.pendingScopesForTesting[scope] == nil && ClaimScopes.shared.openScopes().contains(scope) && Date() < handedBy {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await ClaimScopes.shared.tick()
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        check("\(tag): once the work ended, ordinary scope settlement releases the claim; the file was never overwritten by the peer",
              !FileClaims.claims(ofSelf: ctx).contains { $0.path == file } && !ClaimScopes.shared.openScopes().contains(scope)
              && text.hasPrefix("OWNER\n"), "text \(text.debugDescription)")
        _ = await reg.purgeAllForWipeReporting()
    }

    /// A live subagent run alone refuses the wipe and the Mind-import
    /// quiescence BEFORE either cancels it.
    @MainActor private func wipeRefusesForSubagent(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        await SubagentBackgroundRegistry.shared._testRegister(id: "s3r10-agent", task: task)
        let failures = await m.deleteAllMemory()
        check("wipe refusal (live subagent): /deleteuserdata refuses without cancelling it",
              Self.isWorkRefusal(failures) && failures[0].contains("1 subagent(s)") && !task.isCancelled, "\(failures)")
        let busy = await m.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 1)
        check("wipe refusal (live subagent): a Mind import refuses the same way without cancelling it",
              (busy ?? "").hasPrefix("Background jobs are still running") && (busy ?? "").contains("riprova") && !task.isCancelled, busy ?? "nil")
        await SubagentBackgroundRegistry.shared._testUnregister(id: "s3r10-agent")
        task.cancel()
    }

    /// Work started while the wipe was suspended (between its two checks)
    /// refuses at the destructive step; the job is left alone.
    @MainActor private func wipeSecondCheckRefuses(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        let reg = BackgroundProcessRegistry.shared
        final class Box { var id: String? }
        let box = Box()
        ConversationManager.wipeBeforeSecondBackgroundCheckForTesting = {
            box.id = try? await reg.start(command: "exec sleep 30", workdir: FileManager.default.temporaryDirectory.path, description: "s3r10-late").id
        }
        let failures = await m.deleteAllMemory()
        ConversationManager.wipeBeforeSecondBackgroundCheckForTesting = nil
        var listed = false
        if let id = box.id { listed = await reg.hasEntryForTesting(handleId: id) }
        check("wipe refusal (job started during the wipe): the second check refuses and the job is left running",
              box.id != nil && Self.isWorkRefusal(failures) && listed, "\(failures)")
        if let id = box.id { _ = await reg.kill(handleId: id) }
        let settledBy = Date().addingTimeInterval(5)
        while !(await reg.unsettledEntryIds().isEmpty) && Date() < settledBy { try? await Task.sleep(nanoseconds: 20_000_000) }
        _ = await reg.purgeAllForWipeReporting()
    }

    /// Holds an awaited step until `release()`.
    final class StepGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false, released = false
        private var cont: CheckedContinuation<Void, Never>?
        func wait() async {
            lock.lock(); entered = true
            if released { lock.unlock(); return }
            lock.unlock()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released { lock.unlock(); c.resume() } else { cont = c; lock.unlock() }
            }
        }
        var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func release() { lock.lock(); released = true; let c = cont; cont = nil; lock.unlock(); c?.resume() }
    }

    final class DoneMark: @unchecked Sendable { var value = false }

    /// Codex stage-3 S3-R10-1: a REAL app submission admitted before the
    /// wipe's (or import's) gate went up — suspended in its attachment copy —
    /// must be waited out; work it launches meanwhile then refuses. The job
    /// started while the copy is held stands in for the work its turn would
    /// launch (the copy then fails, so no model call is made).
    @MainActor private func admittedInputRefuses(_ m: ConversationManager, importPath: Bool,
                                                 check: @escaping (String, Bool, String) -> Void) async {
        let tag = importPath ? "S3-R10-1 (app input admitted before a Mind import)" : "S3-R10-1 (app input admitted before the wipe)"
        let reg = BackgroundProcessRegistry.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s3r101-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.txt")
        FileManager.default.createFile(atPath: src.path, contents: Data("attachment\n".utf8))
        let copy = StepGate()
        ConversationManager.copyRegularFileGateForTesting = { await copy.wait() }
        defer { ConversationManager.copyRegularFileGateForTesting = nil }
        m._testSetPolling(true)
        defer { m._testSetPolling(false) }
        let submit = Task { @MainActor in await m.sendFromApp(text: "hello", attachments: [src]) }
        let enteredBy = Date().addingTimeInterval(5)
        while !copy.hasEntered && Date() < enteredBy { try? await Task.sleep(nanoseconds: 5_000_000) }
        check("\(tag): the submission is admitted and held in its copy", copy.hasEntered && m.browserSettingsAppIngress == 1,
              "entered \(copy.hasEntered) ingress \(m.browserSettingsAppIngress)")
        let waits0 = ConversationManager.admissionWaitsForTesting
        let finished = DoneMark()
        let gateUp = importPath ? m.beginMindRestore() : true
        let op = Task { @MainActor () -> [String] in
            defer { finished.value = true }
            if importPath {
                let busy = await m.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 2)
                return busy.map { [$0] } ?? []
            }
            return await m.deleteAllMemory()
        }
        let waitBy = Date().addingTimeInterval(10)
        while !finished.value && ConversationManager.admissionWaitsForTesting == waits0 && Date() < waitBy {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let waited = !finished.value
        let job = try? await reg.start(command: "exec sleep 30", workdir: dir.path, description: "s3r101-late")
        try? FileManager.default.removeItem(at: src)   // the copy then fails: no turn, no model call
        copy.release()
        let outcome = await submit.value
        let result = await op.value
        if importPath && gateUp { m.endMindRestore() }
        var listed = false
        if let id = job?.id { listed = await reg.hasEntryForTesting(handleId: id) }
        let refused = importPath
            ? (result.first ?? "").hasPrefix("Background jobs are still running (1 background command(s))") && result.count == 1
            : Self.isWorkRefusal(result) && result[0].contains("1 background command(s)")
        check("\(tag): it waits for the admitted input, then refuses because of the work it launched (job left running)",
              gateUp && waited && job != nil && refused && listed, "gate \(gateUp) waited \(waited) result \(result) outcome \(outcome)")
        if let id = job?.id { _ = await reg.kill(handleId: id) }
        let settledBy = Date().addingTimeInterval(5)
        while !(await reg.unsettledEntryIds().isEmpty) && Date() < settledBy { try? await Task.sleep(nanoseconds: 20_000_000) }
        _ = await reg.purgeAllForWipeReporting()
    }

    /// S3-R10-1: admitted input that started a turn while the wipe waited
    /// for it — refused before any work check.
    @MainActor private func admittedTurnRefuses(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        m.browserSettingsAppIngress += 1
        let waits0 = ConversationManager.admissionWaitsForTesting
        let finished = DoneMark()
        let op = Task { @MainActor () -> [String] in
            defer { finished.value = true }
            return await m.deleteAllMemory()
        }
        let waitBy = Date().addingTimeInterval(10)
        while !finished.value && ConversationManager.admissionWaitsForTesting == waits0 && Date() < waitBy {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let turn = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        m.activeProcessingTask = turn
        m.browserSettingsAppIngress -= 1
        let result = await op.value
        m.activeProcessingTask = nil
        turn.cancel()
        check("S3-R10-1 (admitted input started a turn): the wipe refuses",
              Self.isWorkRefusal(result) && result[0].contains("a turn that just started"), "\(result)")
    }

    /// S3-R10-1: input that stays admitted past the drain limit (a terminal
    /// wipe while a poll tick hangs in its fetch) refuses, nothing deleted.
    @MainActor private func stuckIngressRefuses(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        ConversationManager.admissionDrainSecondsForTesting = 0.3
        m._testSetBrowserSettingsPollIngress(1)
        let result = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        m._testSetBrowserSettingsPollIngress(0)
        ConversationManager.admissionDrainSecondsForTesting = nil
        check("S3-R10-1 (a poll tick still in flight under a terminal wipe): the wipe refuses after the drain limit",
              Self.isWorkRefusal(result) && result[0].contains("a message still being received"), "\(result)")
    }

    /// Codex stage-3 S3-R2-4: a terminal/app /upgrade whose coordinated
    /// update commits must hand its captured reply to the client BEFORE the
    /// non-returning restart. Synthetic check/staging/barrier; the restart
    /// is intercepted (the process then exits 0, so this runs last and
    /// prints STAGE3_DONE from inside the intercept).
    @MainActor private func successfulUpgradeDeliversBeforeRestart(_ m: ConversationManager, lease: MemberLease,
                                                                  check: @escaping (String, Bool, String) -> Void) async {
        var fds: [Int32] = [0, 0]
        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        guard socketpair(AF_UNIX, streamType, 0, &fds) == 0 else { check("S3-R2-4: socket pair", false, "\(errno)"); return }
        let client = ClientHandle(id: 9_001, fd: fds[0])
        final class Seen { var lines: [String]? }
        let seen = Seen()
        UpgradeService.checkOverrideForTesting = {
            .available(UpgradeService.Update(version: "9.9.10", sequence: 999, url: "https://invalid.example/briglia.tar.gz", sha256: "00", size: 1))
        }
        UpgradeService.stageOverrideForTesting = { u in
            StagedUpgrade(version: u.version, sequence: u.sequence, binary: URL(fileURLWithPath: "/nonexistent/briglia"),
                          bundle: URL(fileURLWithPath: "/nonexistent/bundle"), tempDirectory: nil)
        }
        UpgradeCoordinator.runOverrideForTesting = { staged, afterCommit in
            let record = UpgradeBarrier.Record(id: "s3r24", state: .committed, targetVersion: staged.version, targetSequence: staged.sequence,
                                               openedAt: Date(), coordinator: .init(lease: lease.uuid, pid: getpid(), processStartTime: ProcessIdentity.selfStartTime),
                                               participants: nil, committedBinarySHA256: nil, reason: nil)
            await afterCommit(record)
            return .committed(version: staged.version, barrierId: record.id)
        }
        UpgradeService.restartInterceptForTesting = {
            let terminal = (seen.lines ?? []).joined(separator: "\n")
            check("S3-R2-4: a terminal /upgrade whose update commits gets its whole reply (acknowledgement through \"installed — restarting now\") before the restart",
                  seen.lines != nil && terminal.contains("Checking for an update") && terminal.contains("9.9.10 installed — restarting now"), terminal)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
            let n = read(fds[1], &buffer, buffer.count)
            let wire = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
            check("S3-R2-4: the app socket's command_result is written before the restart",
                  wire.contains("\"command_result\"") && wire.contains("restarting now"), wire.isEmpty ? "nothing on the socket" : String(wire.prefix(300)))
            print("STAGE3_DONE")
        }
        await m.handleTerminalCommand("/upgrade", deliver: { lines in
            seen.lines = lines
            client.send(["type": "command_result", "handled": lines != nil, "lines": lines ?? []])
        }, drainBeforeExit: { client.waitForPendingWrites(timeout: 2) })
        // Only reached when the restart did not happen.
        UpgradeService.restartInterceptForTesting = nil
        check("S3-R2-4: the committed update reached the restart", false, (seen.lines ?? []).joined(separator: " | "))
    }
}
