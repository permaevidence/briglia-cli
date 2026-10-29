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
        await startupRefuses(m, check: check)
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
        // The intake stop (owner decision 2026-10-29; Codex stage-3 S3-R12-1).
        await archiveClearWaitsForRecovery(m, check: check)
        await lateStartupDoesNotRecoverUnderWipe(m, check: check)
        await startupHeldBetweenChecksDoesNotRefuse(m, check: check)
        await maintenanceUnderGateRefuses(m, check: check)
        await archiveRecoveryDeferredUnderGate(m, check: check)
        // Codex stage-3 S3-R13-1: commands under the gate.
        await continueRefusedDuringImport(m, check: check)
        await setnameRefusedDuringWipe(m, check: check)
        await admittedCommandIsDrained(m, check: check)
        // Codex stage-3 S3-R14-1/R14-2: other processes and admitted Stops.
        await standaloneSetupDuringWipe(m, check: check)
        await standaloneWriterMakesWipeWait(m, check: check)
        await admittedStopIsDrained(m, check: check)
        // Codex stage-3 S3-R15-1: the ordinary setup wizard.
        await openWizardMakesWipeRefuse(m, check: check)
        await wizardStartedDuringWipeRefuses(m, check: check)
        // Codex stage-3 S3-R16-1: a writer that starts before the data root exists.
        await absentRootWriterHoldsTheLock(check: check)
        ClaimScopes.tickSeconds = 2
    }

    /// The intake stop: memory maintenance that began after the gate rose
    /// (here between the two checks) refuses the wipe, nothing deleted.
    @MainActor private func maintenanceUnderGateRefuses(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        var activity: UUID?
        ConversationManager.wipeBeforeSecondBackgroundCheckForTesting = { @MainActor in
            activity = m.beginMaintenance(.consolidating)
        }
        let wipe = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        ConversationManager.wipeBeforeSecondBackgroundCheckForTesting = nil
        if let activity { m.endMaintenance(activity) }
        check("intake stop: memory maintenance running at the final check refuses the wipe, nothing deleted",
              Self.isWorkRefusal(wipe) && wipe[0].contains("memory maintenance")
              && KeychainHelper.load(key: KeychainHelper.userNameKey) == "Sentinel", "\(wipe)")
    }

    /// The intake stop: archive recovery requested while the gate is up does
    /// not start; it is scheduled (with a fresh context) when the gate drops.
    @MainActor private func archiveRecoveryDeferredUnderGate(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        let scheduled0 = ConversationManager.archiveRecoveriesScheduledForTesting
        let gate = m.beginMindRestore()
        m.scheduleArchiveRecovery(defaultContext: .empty)
        let notStarted = m.archiveRecoveryTask == nil && m.archiveRecoveryDeferredByRestoreGate
            && ConversationManager.archiveRecoveriesScheduledForTesting == scheduled0
        if gate { m.endMindRestore() }
        let by = Date().addingTimeInterval(10)
        var startedLater = false
        while Date() < by {
            // A recovery task was actually created (Codex round-13 note).
            if ConversationManager.archiveRecoveriesScheduledForTesting > scheduled0 { startedLater = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await awaitArchiveIdle(m)
        check("intake stop: archive recovery requested under the restore gate starts only after the gate drops",
              gate && notStarted && startedLater && !m.archiveRecoveryDeferredByRestoreGate, "gate \(gate) deferred \(notStarted) later \(startedLater)")
    }

    @MainActor private func conversationOnDisk(_ m: ConversationManager) -> String {
        (try? String(contentsOf: m.conversationFileURL, encoding: .utf8)) ?? ""
    }

    /// Codex stage-3 S3-R13-1, Codex's import sequence: a real Mind import;
    /// in the window where the imported files are on disk but not yet
    /// reloaded, a terminal/app `/continue` (which writes the conversation
    /// directly, with no turn) is refused — the imported history survives.
    @MainActor private func continueRefusedDuringImport(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        let imported = "R13_IMPORTED_MEMORY_\(UUID().uuidString.prefix(6))", old = "R13_OLD_MEMORY_\(UUID().uuidString.prefix(6))"
        let tail = "R13_OLD_REPLY_TAIL_\(UUID().uuidString.prefix(6))"
        m.messages = [Message(role: .user, content: "Remember \(imported)."), Message(role: .assistant, content: "Noted.")]
        _ = m.saveConversation()
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("r13-\(UUID().uuidString.prefix(8)).mind")
        defer { try? FileManager.default.removeItem(at: backup) }
        var exported = true
        do { try await MindExportService.shared.exportMind(to: backup) } catch { exported = false }
        m.messages = [Message(role: .user, content: "Remember \(old)."), Message(role: .assistant, content: "Noted.")]
        _ = m.saveConversation()
        m.pendingContinuationText = tail
        final class Seen { var window = false, reply: [String] = [] }
        let seen = Seen()
        ConversationManager.reloadBeforeLoadConversationForTesting = { @MainActor in
            let disk = self.conversationOnDisk(m)
            seen.window = m.isRestoringMind && disk.contains(imported) && !disk.contains(old)
            seen.reply = await m.handleTerminalCommand("/continue") ?? []
        }
        let outcome = await m.performMindImport(from: backup)
        ConversationManager.reloadBeforeLoadConversationForTesting = nil
        let disk = conversationOnDisk(m)
        var ok = false
        if case .success = outcome { ok = true }
        check("S3-R13-1: during a real Mind import, a terminal/app /continue is refused (EN + IT) and the imported history survives",
              exported && ok && seen.window && seen.reply.joined().contains("memory operation") && seen.reply.joined().contains("operazione sulla memoria")
              && disk.contains(imported) && !disk.contains(old) && !disk.contains(tail),
              "exported \(exported) outcome \(outcome) window \(seen.window) reply \(seen.reply) imported \(disk.contains(imported)) old \(disk.contains(old))")
        m.pendingContinuationText = nil
    }

    /// Codex stage-3 S3-R13-1, Codex's wipe sequence: in the wipe's final
    /// reload (after the name was deleted), `/setname` + `/setname confirm`
    /// are refused — the wiped name stays wiped.
    @MainActor private func setnameRefusedDuringWipe(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        final class Seen { var window = false, replies: [String] = [] }
        let seen = Seen()
        ConversationManager.reloadBeforeLoadConversationForTesting = { @MainActor in
            seen.window = m.isRestoringMind && KeychainHelper.load(key: KeychainHelper.userNameKey) == nil
            seen.replies += await m.handleTerminalCommand("/setname R13_NAME_DURING_WIPE") ?? []
            seen.replies += await m.handleTerminalCommand("/setname confirm") ?? []
        }
        let wipe = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        ConversationManager.reloadBeforeLoadConversationForTesting = nil
        let name = KeychainHelper.load(key: KeychainHelper.userNameKey)
        check("S3-R13-1: during a real wipe's final reload, /setname and /setname confirm are refused and the wiped name stays wiped",
              seen.window && !wipe.contains { $0.hasPrefix("ABORTED") } && name == nil
              && seen.replies.count == 2 && seen.replies.allSatisfy { $0.contains("memory operation") },
              "window \(seen.window) \(wipe) name \(name ?? "nil") replies \(seen.replies)")
    }

    /// S3-R13-1: a command admitted before the gate (still in its handler)
    /// makes the wipe wait, then refuse after the drain limit; the handler
    /// running the wipe itself is not counted.
    @MainActor private func admittedCommandIsDrained(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        ConversationManager.admissionDrainSecondsForTesting = 0.5
        m.browserSettingsCommandIngress += 1
        let refused = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        check("S3-R13-1: a command still in its handler when the gate rises makes the wipe refuse after the drain limit, nothing deleted",
              Self.isWorkRefusal(refused) && refused[0].contains("a command still running")
              && KeychainHelper.load(key: KeychainHelper.userNameKey) == "Sentinel", "\(refused)")
        // The /deleteuserdata handler's own ingress is the wipe itself.
        m.memoryReplacementOwnsCommand = true
        let waits0 = ConversationManager.admissionWaitsForTesting
        let own = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        m.memoryReplacementOwnsCommand = false
        m.browserSettingsCommandIngress -= 1
        ConversationManager.admissionDrainSecondsForTesting = nil
        check("S3-R13-1: the command handler running the wipe is not counted (no wait, the wipe runs)",
              ConversationManager.admissionWaitsForTesting == waits0 && !own.contains { $0.hasPrefix("ABORTED") }
              && KeychainHelper.load(key: KeychainHelper.userNameKey) == nil, "\(own)")
    }

    /// Runs this executable as a separate process with the same (scratch)
    /// environment: `args`, `stdin`, extra environment. Returns exit status
    /// and stdout.
    static func runChild(_ args: [String], stdin: String, env extra: [String: String]) async -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "spawn failed: \(error)") }
        input.fileHandleForWriting.write(Data(stdin.utf8)); try? input.fileHandleForWriting.close()
        let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let data = await reader.value
        while p.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Codex stage-3 S3-R14-1, Codex's sequence: a REAL `setup-api apply`
    /// child process writing the user name, started inside a real wipe after
    /// the name was deleted, is refused (the wipe holds the replacement lock
    /// exclusively); the name stays wiped. Once the wipe ended, the same
    /// child request succeeds.
    @MainActor private func standaloneSetupDuringWipe(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        let request = #"{"identity":{"user_name":"R14_NAME_DURING_WIPE"}}"#
        final class Seen { var window = false, status: Int32 = 0, out = "" }
        let seen = Seen()
        ConversationManager.reloadBeforeLoadConversationForTesting = { @MainActor in
            seen.window = m.isRestoringMind && m.memoryReplacementLock != nil && KeychainHelper.load(key: KeychainHelper.userNameKey) == nil
            (seen.status, seen.out) = await Self.runChild(["setup-api", "apply"], stdin: request, env: ["BRIGLIA_REPLACEMENT_WAIT_SECONDS": "1"])
        }
        let wipe = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        ConversationManager.reloadBeforeLoadConversationForTesting = nil
        let nameAfterWipe = KeychainHelper.load(key: KeychainHelper.userNameKey)
        check("S3-R14-1: a real setup-api apply child started during a real wipe is refused (memory_operation_in_progress) and the wiped name stays wiped",
              seen.window && seen.out.contains("memory_operation_in_progress") && !wipe.contains { $0.hasPrefix("ABORTED") }
              && nameAfterWipe == nil && m.memoryReplacementLock == nil,
              "window \(seen.window) child \(seen.status) \(seen.out.prefix(200)) name \(nameAfterWipe ?? "nil") \(wipe)")
        let (status2, out2) = await Self.runChild(["setup-api", "apply"], stdin: request, env: ["BRIGLIA_REPLACEMENT_WAIT_SECONDS": "1"])
        check("S3-R14-1: after the wipe the same setup-api request succeeds (the lock was released)",
              status2 == 0 && out2.contains("\"ok\":true") && KeychainHelper.load(key: KeychainHelper.userNameKey) == "R14_NAME_DURING_WIPE",
              "\(status2) \(out2.prefix(200))")
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
    }

    /// S3-R14-1, the other order: a standalone writer already holding the
    /// lock (shared) makes the wipe wait, then refuse with nothing deleted.
    @MainActor private func standaloneWriterMakesWipeWait(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        guard case .admitted(let writer) = MemoryReplacementLock.shared(waitSeconds: 0) else {
            check("S3-R14-1: a standalone writer's shared lock", false, "not acquired"); return
        }
        ConversationManager.admissionDrainSecondsForTesting = 0.5
        let refused = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        ConversationManager.admissionDrainSecondsForTesting = nil
        writer.release()
        check("S3-R14-1: a standalone writer holding the replacement lock makes the wipe refuse after the drain limit, nothing deleted",
              Self.isWorkRefusal(refused) && refused[0].contains("another Briglia command")
              && KeychainHelper.load(key: KeychainHelper.userNameKey) == "Sentinel" && m.memoryReplacementLock == nil, "\(refused)")
    }

    /// Codex stage-3 S3-R14-2: an app/terminal Stop that began before the
    /// gate and is suspended in its registry cutoffs is counted: the wipe
    /// waits, then refuses with nothing deleted (the queued completion
    /// survives). A Stop under the gate is refused with a visible text.
    @MainActor private func admittedStopIsDrained(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        let completion = SubagentBackgroundRegistry.Completion(
            handle: .init(id: "subagent_r14_stop", subagentType: "general-purpose", description: "r14 finished", startedAt: Date()),
            result: SubagentRunner.RunResult(sessionId: "r14-session", isNewSession: true, finalMessage: "r14 result", turnsUsed: 1,
                                             toolsCalled: [], filesTouched: [], spendUSD: 0, error: nil),
            completedAt: Date())
        await SubagentBackgroundRegistry.shared._testEnqueueCompletion(completion)
        let queued0 = await SubagentBackgroundRegistry.shared._testPendingCompletionsCount()
        let hold = StepGate()
        ConversationManager.stopCutoffInterleaveForTesting = { await hold.wait() }
        let stop = Task { @MainActor in await m.stopFromApp() }
        let by = Date().addingTimeInterval(10)
        while !hold.hasEntered && Date() < by { try? await Task.sleep(nanoseconds: 10_000_000) }
        ConversationManager.admissionDrainSecondsForTesting = 0.25
        let refused = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        ConversationManager.admissionDrainSecondsForTesting = nil
        let queuedAfter = await SubagentBackgroundRegistry.shared._testPendingCompletionsCount()
        hold.release()
        _ = await stop.value
        ConversationManager.stopCutoffInterleaveForTesting = nil
        check("S3-R14-2: a Stop suspended in its cutoffs when the wipe starts is counted: the wipe refuses, nothing deleted (queued result kept)",
              hold.hasEntered && Self.isWorkRefusal(refused) && refused[0].contains("a command still running")
              && KeychainHelper.load(key: KeychainHelper.userNameKey) == "Sentinel" && queuedAfter == queued0 && queued0 >= 1,
              "held \(hold.hasEntered) \(refused) queued \(queued0)→\(queuedAfter)")
        let gate = m.beginMindRestore()
        let refusal = await m.stopFromApp()
        if gate { m.endMindRestore() }
        check("S3-R14-2: a Stop under the restore gate is refused and returns its EN + IT text for the caller to show",
              gate && (refusal ?? "").contains("memory operation") && (refusal ?? "").contains("operazione sulla memoria"), refusal ?? "nil")
        // Settled: the wipe now runs (and clears the queued result).
        let after = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        check("S3-R14-2: once the Stop finished, the wipe runs",
              !after.contains { $0.hasPrefix("ABORTED") } && KeychainHelper.load(key: KeychainHelper.userNameKey) == nil, "\(after)")
    }

    /// A REAL `setup` wizard child with an open stdin (its own scratch
    /// environment), for the S3-R15-1 rows.
    final class WizardChild {
        let process = Process()
        let input = Pipe()
        init?(env extra: [String: String]) {
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["setup"]
            process.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
        }
        func send(_ text: String) { input.fileHandleForWriting.write(Data(text.utf8)) }
        func finish() async -> Int32 {
            try? input.fileHandleForWriting.close()
            let by = Date().addingTimeInterval(30)
            while process.isRunning && Date() < by { try? await Task.sleep(nanoseconds: 20_000_000) }
            if process.isRunning { process.terminate() }
            while process.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
            return process.terminationStatus
        }
    }

    /// Codex stage-3 S3-R15-1, first ordering: a real `briglia setup` wizard
    /// already open at its name prompt (the old name cached as the default)
    /// makes the wipe wait, then refuse with nothing deleted; Enter then
    /// keeps the (still present) name.
    @MainActor private func openWizardMakesWipeRefuse(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        try? KeychainHelper.save(key: SetupWizard.completeKey, value: "true")
        guard let wizard = WizardChild(env: [:]) else { check("S3-R15-1: wizard child", false, "spawn failed"); return }
        wizard.send("5\n")
        // The wizard holds the shared lock for its whole run: an exclusive
        // attempt is busy once it is up.
        let by = Date().addingTimeInterval(20)
        var holding = false
        while Date() < by && wizard.process.isRunning {
            if case .busy = MemoryReplacementLock.tryExclusive() { holding = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)   // let it reach the name prompt
        ConversationManager.admissionDrainSecondsForTesting = 1
        let refused = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        ConversationManager.admissionDrainSecondsForTesting = nil
        let nameDuring = KeychainHelper.load(key: KeychainHelper.userNameKey)
        wizard.send("\n\n")   // keep the cached name, leave the section menu
        let status = await wizard.finish()
        check("S3-R15-1: a real setup wizard open at its (cached) name prompt makes the wipe refuse after the drain limit, nothing deleted; Enter keeps the name",
              holding && Self.isWorkRefusal(refused) && refused[0].contains("another Briglia command") && nameDuring == "Sentinel"
              && KeychainHelper.load(key: KeychainHelper.userNameKey) == "Sentinel" && m.memoryReplacementLock == nil,
              "holding \(holding) \(refused) during \(nameDuring ?? "nil") exit \(status)")
    }

    /// Codex stage-3 S3-R15-1, second ordering: a real wizard started during
    /// a real wipe (name already deleted) refuses before reading or saving
    /// anything; the wiped name stays wiped.
    @MainActor private func wizardStartedDuringWipeRefuses(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        try? KeychainHelper.save(key: SetupWizard.completeKey, value: "true")
        final class Seen { var window = false, status: Int32 = 0 }
        let seen = Seen()
        ConversationManager.reloadBeforeLoadConversationForTesting = { @MainActor in
            seen.window = m.memoryReplacementLock != nil && KeychainHelper.load(key: KeychainHelper.userNameKey) == nil
            guard let wizard = WizardChild(env: ["BRIGLIA_REPLACEMENT_WAIT_SECONDS": "0.5"]) else { return }
            wizard.send("5\nR15_WIZARD_DURING_WIPE\n\n")
            seen.status = await wizard.finish()
        }
        let wipe = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        ConversationManager.reloadBeforeLoadConversationForTesting = nil
        let name = KeychainHelper.load(key: KeychainHelper.userNameKey)
        check("S3-R15-1: a real setup wizard started during a real wipe refuses (exit 75) and the wiped name stays wiped",
              seen.window && seen.status == 75 && !wipe.contains { $0.hasPrefix("ABORTED") } && name == nil,
              "window \(seen.window) exit \(seen.status) name \(name ?? "nil") \(wipe)")
    }

    /// Codex stage-3 S3-R16-1, Codex's ordering, in a separate fresh
    /// installation (its own scratch XDG roots, no data root yet): a REAL
    /// `setup-api apply` child held at the config store's own lock must
    /// already hold the replacement lock (it established the data root
    /// after its migration gate), so an exclusive replacement attempt is
    /// busy while it is pending; it then completes. Before the fix it was
    /// admitted without any lock while the root was absent.
    @MainActor private func absentRootWriterHoldsTheLock(check: @escaping (String, Bool, String) -> Void) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r16-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let cfg = root.appendingPathComponent("cfg/briglia"), data = root.appendingPathComponent("data/briglia")
        try? PrivateStorage.ensureDirectory(cfg)
        try? PrivateStorage.writeAtomically(Data(#"{"user_name":"OLD"}"#.utf8), to: cfg.appendingPathComponent("secrets.json"))
        let rootAbsentAtStart = !FileManager.default.fileExists(atPath: data.path)
        guard case .acquired(let storeLock) = ProfileFileLock.take(cfg.appendingPathComponent("secrets.lock")) else {
            check("S3-R16-1: the child's config-store lock", false, "not acquired"); return
        }
        var env = ProcessInfo.processInfo.environment
        env["XDG_CONFIG_HOME"] = root.appendingPathComponent("cfg").path
        env["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
        env["BRIGLIA_REPLACEMENT_WAIT_SECONDS"] = "1"
        env.removeValue(forKey: "BRIGLIA_PROFILE")
        // A plain single-assistant installation (Codex's fixture): no
        // experimental switch, so entry creates no member lease or root.
        env[AssistantProfile.experimentalKey] = ""
        let child = Task.detached { () -> (Int32, String) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            p.arguments = ["setup-api", "apply"]
            p.environment = env
            let input = Pipe(), output = Pipe()
            p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return (-1, "\(error)") }
            input.fileHandleForWriting.write(Data(#"{"identity":{"user_name":"R16_NO_ROOT"}}"#.utf8))
            try? input.fileHandleForWriting.close()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: out, as: UTF8.self))
        }
        let lockURL = data.appendingPathComponent("memory-replacement.lock")
        let by = Date().addingTimeInterval(15)
        var excluded = false
        while Date() < by {
            if FileManager.default.fileExists(atPath: lockURL.path), case .busy = ProfileFileLock.take(lockURL) { excluded = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        storeLock.release()
        let (status, out) = await child.value
        let saved = (try? String(contentsOf: cfg.appendingPathComponent("secrets.json"), encoding: .utf8)) ?? ""
        check("S3-R16-1: a setup-api writer started before the data root existed holds the replacement lock while pending (an exclusive attempt is busy), then completes",
              rootAbsentAtStart && excluded && status == 0 && out.contains("\"ok\":true") && saved.contains("R16_NO_ROOT"),
              "absent \(rootAbsentAtStart) excluded \(excluded) exit \(status) \(out.prefix(160))")
    }

    /// One pending chunk on disk whose raw message carries `marker`; the
    /// manager's archive service reloads it (as at startup).
    @MainActor private func seedPendingChunk(_ m: ConversationManager, marker: String) async {
        let folder = m.archiveService.archiveFolderURLForTesting
        try? PrivateStorage.ensureDirectory(folder)
        let msg = Message(role: .user, content: "Please remember \(marker) for later.")
        let raw = "pending_\(UUID().uuidString).json"
        try? PrivateStorage.writeAtomically(try JSONEncoder().encode([msg]), to: folder.appendingPathComponent(raw))
        let pending = PendingChunk(id: UUID(), startDate: msg.timestamp.addingTimeInterval(-60), endDate: msg.timestamp,
                                   tokenCount: 20, messageCount: 1, rawContentFileName: raw, createdAt: Date(),
                                   sourceMessageIDs: [msg.id])
        try? PrivateStorage.writeAtomically(try JSONEncoder().encode(PendingChunkIndex(pendingChunks: [pending])),
                                            to: folder.appendingPathComponent("pending_chunks.json"))
        await m.archiveService.reloadFromDisk()
    }

    @MainActor private func archiveIndexContains(_ m: ConversationManager, _ marker: String) -> Bool {
        let url = m.archiveService.archiveFolderURLForTesting.appendingPathComponent("chunk_index.json")
        guard let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data, as: UTF8.self).contains(marker)
    }

    /// A synthetic archive model (no request is built or sent): the summary
    /// of the chunk carrying `marker` waits on `gate`, then returns a valid
    /// summary that repeats the marker; every other maintenance call answers
    /// NO_CHANGES.
    static func installArchiveModel(marker: String, gate: StepGate, seen: DoneMark) {
        ConversationArchiveService.callLLMOverrideForTesting = { _, user in
            guard user.contains(marker) else { return "NO_CHANGES" }
            seen.value = true
            await gate.wait()
            return "Summary: the user asked to remember \(marker). " + Array(repeating: "The conversation covered that request in detail.", count: 30).joined(separator: " ")
        }
    }

    @MainActor private func awaitArchiveIdle(_ m: ConversationManager) async {
        let by = Date().addingTimeInterval(30)
        while (m.archiveRecoveryTask != nil || !m.maintenanceActivities.isEmpty || m.archiveRecoveryDeferredByRestoreGate) && Date() < by {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Codex stage-3 S3-R12-1, storage level: a pending-chunk recovery that
    /// read pre-wipe memory and is waiting for its summary must not publish
    /// it into an archive cleared meanwhile. The clear waits for the chunk
    /// writer (the recovery holds it), so the recovered chunk lands first
    /// and is then removed.
    @MainActor private func archiveClearWaitsForRecovery(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        let marker = "R12_STORE_\(UUID().uuidString.prefix(6))"
        await seedPendingChunk(m, marker: marker)
        let gate = StepGate(), seen = DoneMark(), cleared = DoneMark()
        Self.installArchiveModel(marker: marker, gate: gate, seen: seen)
        defer { ConversationArchiveService.callLLMOverrideForTesting = nil }
        let archive = m.archiveService
        let recovery = Task { await archive.recoverPendingChunks() }
        let by = Date().addingTimeInterval(20)
        while !gate.hasEntered && Date() < by { try? await Task.sleep(nanoseconds: 10_000_000) }
        let clear = Task { _ = await archive.clearAllArchives(); cleared.value = true }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let clearWaited = !cleared.value
        gate.release()
        await recovery.value
        await clear.value
        check("S3-R12-1 (storage): clearing the archive waits for a recovery that holds the chunk writer, and the recovered pre-wipe chunk does not survive the clear",
              seen.value && clearWaited && !archiveIndexContains(m, marker), "summary \(seen.value) clearWaited \(clearWaited) inIndex \(archiveIndexContains(m, marker))")
    }

    /// Codex stage-3 S3-R12-1, Codex's sequence: a REAL startup begun after
    /// the wipe's final busy check (gate up). Before the fix configure()
    /// scheduled archive recovery under the gate, which read a pre-wipe
    /// pending chunk and published it after the wipe. Now the startup does
    /// nothing until the gate drops: no archive recovery, no summary request.
    @MainActor private func lateStartupDoesNotRecoverUnderWipe(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        let marker = "R12_OLD_MEMORY_\(UUID().uuidString.prefix(6))"
        await seedPendingChunk(m, marker: marker)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        let gate = StepGate(), seen = DoneMark()
        Self.installArchiveModel(marker: marker, gate: gate, seen: seen)
        defer { ConversationArchiveService.callLLMOverrideForTesting = nil }
        final class Observed { var held = false, recovery = false, summary = false, configured = false, started = false }
        let obs = Observed()
        var startup: Task<Void, Never>?
        let held0 = ConversationManager.startupHeldBeforeConfigureForTesting
        ConversationManager.startupAfterConfigureForTesting = { obs.configured = true }
        ConversationManager.wipeAfterFinalCheckForTesting = { @MainActor in
            startup = Task { @MainActor in await m.startPolling() }
            obs.started = true
            let by = Date().addingTimeInterval(3)
            while ConversationManager.startupHeldBeforeConfigureForTesting < held0 + 3 && !gate.hasEntered && Date() < by {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            obs.held = m.startupHeldByRestoreGate && m.isStartingPolling
            obs.recovery = m.archiveRecoveryTask != nil
            obs.summary = gate.hasEntered
        }
        // Codex's ordering: a held summary is released only after the wipe
        // returns. A watchdog lets it go after 8 s so a build where the
        // archive clear waits for the recovery's chunk writer cannot hang.
        let wipeDone = DoneMark()
        let watchdog = Task { try? await Task.sleep(nanoseconds: 8_000_000_000); if !wipeDone.value { gate.release() } }
        let wipe = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        wipeDone.value = true
        watchdog.cancel()
        ConversationManager.wipeAfterFinalCheckForTesting = nil
        let oldInIndexAfterWipe = archiveIndexContains(m, marker)
        gate.release()
        await startup?.value
        ConversationManager.startupAfterConfigureForTesting = nil
        await awaitArchiveIdle(m)
        m.stopPolling()
        await awaitArchiveIdle(m)
        let oldInIndexLater = archiveIndexContains(m, marker)
        check("S3-R12-1: a real startup begun after the wipe's final check waits before configure(): no archive recovery, no summary request under the gate",
              obs.started && obs.held && !obs.recovery && !obs.summary && !seen.value,
              "held \(obs.held) recovery \(obs.recovery) summary \(obs.summary)")
        check("S3-R12-1: the wipe succeeds and the pre-wipe pending memory never reaches the wiped archive index (also after startup completes)",
              !wipe.contains { $0.hasPrefix("ABORTED") } && KeychainHelper.load(key: KeychainHelper.userNameKey) == nil
              && !oldInIndexAfterWipe && !oldInIndexLater && obs.configured,
              "\(wipe) afterWipe \(oldInIndexAfterWipe) later \(oldInIndexLater) configured \(obs.configured)")
    }

    /// The intake stop: a startup that begins between the wipe's two busy
    /// checks waits at the top and is NOT counted as "starting up" (it has
    /// done nothing); the wipe proceeds, then the startup runs.
    @MainActor private func startupHeldBetweenChecksDoesNotRefuse(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        await awaitArchiveIdle(m)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sentinel")
        var startup: Task<Void, Never>?
        let held0 = ConversationManager.startupHeldBeforeConfigureForTesting
        ConversationManager.wipeBeforeSecondBackgroundCheckForTesting = { @MainActor in
            startup = Task { @MainActor in await m.startPolling() }
            let by = Date().addingTimeInterval(3)
            while ConversationManager.startupHeldBeforeConfigureForTesting == held0 && Date() < by {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let wipe = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        ConversationManager.wipeBeforeSecondBackgroundCheckForTesting = nil
        await startup?.value
        let started = m.pollingTask != nil
        m.stopPolling()
        await awaitArchiveIdle(m)
        check("intake stop: a startup held at the gate (begun between the wipe's checks) does not refuse the wipe, and starts once the gate drops",
              ConversationManager.startupHeldBeforeConfigureForTesting > held0 && !wipe.contains { $0.hasPrefix("ABORTED") }
              && KeychainHelper.load(key: KeychainHelper.userNameKey) == nil && started, "\(wipe) started \(started)")
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

    /// Codex stage-3 S3-R11-1: a REAL startup suspended after configure()
    /// (before any poll tick, zero poll/app ingress) refuses a terminal/app
    /// wipe and a Mind import; a startup that begins while the gate is up
    /// holds its crash recovery until the gate drops. Synthetic, unreachable
    /// OpenAI-compatible endpoint: nothing is sent anywhere.
    @MainActor private func startupRefuses(_ m: ConversationManager, check: @escaping (String, Bool, String) -> Void) async {
        try? KeychainHelper.saveBatch([
            KeychainHelper.llmProviderKey: "openai_compatible",
            KeychainHelper.openAICompatibleBaseURLKey: "http://127.0.0.1:9/v1",
            KeychainHelper.openAICompatibleModelKey: "synthetic-model",
            KeychainHelper.openAICompatibleApiKeyKey: "synthetic-key",
        ])
        let hold = StepGate()
        ConversationManager.startupAfterConfigureForTesting = { await hold.wait() }
        let start = Task { @MainActor in await m.startPolling() }
        let heldBy = Date().addingTimeInterval(20)
        while !hold.hasEntered && Date() < heldBy { try? await Task.sleep(nanoseconds: 10_000_000) }
        await m.startPolling()   // the second caller (terminal session) returns at once
        check("S3-R11-1: a real startup is held after configure() with no poll/app ingress; a second start returns",
              hold.hasEntered && m.isStartingPolling && m.browserSettingsPollIngress == 0 && m.browserSettingsAppIngress == 0,
              "held \(hold.hasEntered) starting \(m.isStartingPolling) error \(m.error ?? "nil")")
        let wipe = await ConversationManager.$commandCapture.withValue(ConversationManager.CommandResponseCapture()) {
            await m.deleteAllMemory()
        }
        check("S3-R11-1 (startup in progress): a terminal/app wipe refuses, nothing deleted",
              Self.isWorkRefusal(wipe) && wipe[0].contains("Briglia still starting up")
              && KeychainHelper.load(key: KeychainHelper.userNameKey) == "Sentinel", "\(wipe)")
        let gateUp = m.beginMindRestore()
        let busy = await m.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 1)
        if gateUp { m.endMindRestore() }
        check("S3-R11-1 (startup in progress): a Mind import refuses",
              gateUp && (busy ?? "").contains("Briglia still starting up"), busy ?? "nil")
        hold.release()
        await start.value
        ConversationManager.startupAfterConfigureForTesting = nil
        m.stopPolling()
        check("S3-R11-1: the held startup then completes normally", !m.isStartingPolling && m.error == nil, m.error ?? "")

        // A startup that begins while the gate is up waits before configure()
        // (the intake stop, S3-R12-1) — so before any recovery.
        await awaitArchiveIdle(m)
        let top0 = ConversationManager.startupHeldBeforeConfigureForTesting
        let configured = DoneMark()
        ConversationManager.startupAfterConfigureForTesting = { configured.value = true }
        let gate2 = m.beginMindRestore()
        let finished = DoneMark()
        let late = Task { @MainActor in await m.startPolling(); finished.value = true }
        let waitBy = Date().addingTimeInterval(20)
        while ConversationManager.startupHeldBeforeConfigureForTesting == top0 && !finished.value && Date() < waitBy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let heldWhileGated = !finished.value && !configured.value && m.pollingTask == nil && m.archiveRecoveryTask == nil
            && m.startupHeldByRestoreGate && ConversationManager.startupHeldBeforeConfigureForTesting > top0
        if gate2 { m.endMindRestore() }
        await late.value
        ConversationManager.startupAfterConfigureForTesting = nil
        check("S3-R11-1/R12-1: a startup begun under the restore gate does nothing (no configure, no recovery) until the gate drops",
              gate2 && heldWhileGated && finished.value && configured.value && m.pollingTask != nil, "gate \(gate2) held \(heldWhileGated)")
        m.stopPolling()
        await awaitArchiveIdle(m)

        // A startup already in configure() when the gate rises (the wipe
        // refuses it as "starting up") still holds its crash recovery.
        let waits0 = ConversationManager.startupRecoveryWaitsForTesting
        let hold3 = StepGate()
        ConversationManager.startupAfterConfigureForTesting = { await hold3.wait() }
        let finished3 = DoneMark()
        let mid = Task { @MainActor in await m.startPolling(); finished3.value = true }
        let enteredBy = Date().addingTimeInterval(20)
        while !hold3.hasEntered && Date() < enteredBy { try? await Task.sleep(nanoseconds: 10_000_000) }
        let gate4 = m.beginMindRestore()
        hold3.release()
        let recBy = Date().addingTimeInterval(20)
        while ConversationManager.startupRecoveryWaitsForTesting == waits0 && !finished3.value && Date() < recBy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let recoveryHeld = !finished3.value && m.pollingTask == nil && ConversationManager.startupRecoveryWaitsForTesting > waits0
        if gate4 { m.endMindRestore() }
        await mid.value
        ConversationManager.startupAfterConfigureForTesting = nil
        check("S3-R11-1: a startup already in configure() when the gate rises holds crash recovery until the gate drops",
              gate4 && recoveryHeld && finished3.value && m.pollingTask != nil, "gate \(gate4) held \(recoveryHeld)")
        m.stopPolling()
        await awaitArchiveIdle(m)

        // The turn choke point: a turn started (by any producer) while the
        // gate is up runs no body until it drops. Cancelled before release,
        // so no model request is made.
        let held0 = ConversationManager.turnsHeldByRestoreGateForTesting
        let gate3 = m.beginMindRestore()
        m.startActiveProcessing(for: Message(role: .user, content: "s3r11 choke point"))
        let turnHeldBy = Date().addingTimeInterval(5)
        while ConversationManager.turnsHeldByRestoreGateForTesting == held0 && Date() < turnHeldBy { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let heldTurn = ConversationManager.turnsHeldByRestoreGateForTesting > held0 + 1 && m.activeProcessingTask != nil
        let task = m.activeProcessingTask
        task?.cancel()
        if gate3 { m.endMindRestore() }
        await task?.value
        check("S3-R11-1 audit: a turn started under the restore gate runs nothing until the gate drops (or /stop)",
              gate3 && heldTurn && m.activeProcessingTask == nil, "gate \(gate3) held \(heldTurn)")

        // The intake stop: a turn held at the choke point while the history
        // is replaced (the wipe's / import's generation bump) is dropped when
        // the gate drops — it never runs on the new state.
        let dropped0 = ConversationManager.turnsDroppedAfterReplacementForTesting
        let held5 = ConversationManager.turnsHeldByRestoreGateForTesting
        let gate5 = m.beginMindRestore()
        let messages5 = m.messages.map(\.id)
        m.startActiveProcessing(for: Message(role: .user, content: "s3 intake: pre-wipe input"))
        let held5By = Date().addingTimeInterval(5)
        while ConversationManager.turnsHeldByRestoreGateForTesting == held5 && Date() < held5By { try? await Task.sleep(nanoseconds: 10_000_000) }
        await m.invalidateArchiveJobForReplacedHistory()   // what the wipe / import do
        let task5 = m.activeProcessingTask
        if gate5 { m.endMindRestore() }
        await task5?.value
        check("intake stop: a turn held while a wipe/import replaced the history is dropped (no model or tool work) and torn down",
              gate5 && ConversationManager.turnsDroppedAfterReplacementForTesting == dropped0 + 1
              && m.activeProcessingTask == nil && m.activeRunId == nil && m.messages.map(\.id) == messages5,
              "gate \(gate5) dropped \(ConversationManager.turnsDroppedAfterReplacementForTesting - dropped0) messages \(messages5.count)→\(m.messages.count)")
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
