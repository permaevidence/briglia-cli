import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The machine upgrade barrier (MULTI_ASSISTANT_PLAN §6.3): every running
/// assistant reaches a restart-ready point and parks, then the binary and
/// bundle are swapped under a crash-safe journal, then every one restarts.
/// A busy assistant delays the upgrade (up to 10 minutes, D17); nobody's
/// work is killed. Used by `briglia upgrade` (a session coordinator) and by
/// the default assistant's `/upgrade` (an assistant coordinator).
enum UpgradeCoordinator {
    struct Settings {
        var paths: UpgradeBarrier.Paths = .live
        var registryPaths: AssistantRegistry.Paths = .live
        var executable: URL = UpgradeService.executableURL
        var waitSeconds: TimeInterval = UpgradeCoordinator.defaultWaitSeconds
        var poll: TimeInterval = 1
        var ownLease: MemberLease? = MemberEntry.current
        /// One progress line at most per waiting episode, plus results.
        var progress: (String) -> Void = { print($0) }
        /// The data roots whose unfinished-turn checkpoint must not exist.
        var checkpointRoots: () -> [URL] = UpgradeCoordinator.registeredDataRoots
        /// The anti-rollback floor of the candidate's trust domain (re-read
        /// under the upgrade lock).
        var trustFloor: () -> Int? = { ReleaseTrustStore.load(domain: ReleasePolicy.effective.trustDomain).sequence }
        var installedSequence: (URL) -> Int? = { UpgradeBarrier.installedSequence(.live, executable: $0) }
    }

    enum Outcome: Equatable {
        case committed(version: String, barrierId: String)
        case cancelled(String)
        case refused(String)
        case stuck(String)
    }

    struct MemberDir: Equatable { var profile: String; var generation: String?; var directory: URL }

    /// 10 minutes (D17); development builds may shorten it for tests.
    static var defaultWaitSeconds: TimeInterval {
        if adaCLIVersion.hasSuffix("-dev"), let v = Double(ProcessInfo.processInfo.environment["BRIGLIA_TEST_UPGRADE_WAIT_SECONDS"] ?? ""), v > 0 { return v }
        return 600
    }

    /// The trust rule at publication (§5.1): candidate ≥ the persisted floor
    /// of its trust domain (equality is normal), and > the installed
    /// sequence. nil = accepted.
    static func trustRefusal(candidate: Int, floor: Int?, installed: Int?) -> String? {
        if let floor, candidate < floor {
            return "the release (sequence \(candidate)) is older than this computer's trusted floor \(floor); refusing"
        }
        if let installed, candidate <= installed {
            return "the release (sequence \(candidate)) is not newer than what is installed (\(installed)); nothing to do"
        }
        return nil
    }

    static let alreadyRunning = "An update or a recovery is already running on this computer. / Un aggiornamento o un ripristino è già in corso su questo computer."

    // MARK: Lock and the previous barrier

    static func acquire(_ paths: UpgradeBarrier.Paths = .live) -> Result<ProfileFileLock, UpgradeJournal.Failure> {
        do { try PrivateStorage.ensureDirectory(paths.root.deletingLastPathComponent(), mode: 0o700)
             try PrivateStorage.ensureDirectory(paths.root, mode: 0o700) } catch { return .failure(.init("\(error)")) }
        switch ProfileFileLock.take(paths.lock) {
        case .acquired(let l): return .success(l)
        case .busy: return .failure(.init(alreadyRunning))
        case .failed(let why): return .failure(.init(why))
        }
    }

    /// With `upgrade.lock` held: an earlier barrier must be finished before a
    /// new one opens. nil = clear to proceed.
    static func settlePrevious(_ settings: Settings) -> String? {
        guard let barrier = UpgradeBarrier.current(settings.paths) else { return nil }
        switch barrier.state {
        case .cancelled: return nil
        case .closed:
            UpgradeJournal.cleanup(settings.paths)
            return nil
        case .stuck:
            return UpgradeBarrier.stuckMessage
        case .open:
            // Its coordinator died (we hold the lock): the recovery table.
            switch UpgradeJournal.recover(barrier, allowStuck: false, paths: settings.paths) {
            case .cancelled, .nothing, .closedCleanup: return nil
            case .committed: return closeIfPossible(settings) ? nil : "The previous update is still finishing (assistants are restarting); try again in a minute."
            case .stuck(let why), .malformed(let why): return why
            }
        case .committed:
            return closeIfPossible(settings) ? nil : "The previous update is still finishing (assistants are restarting); try again in a minute."
        }
    }

    // MARK: Participants

    static func memberDirectories(_ registryPaths: AssistantRegistry.Paths = .live,
                                  defaultDirectory: URL = MemberLeases.defaultDirectory()) -> [MemberDir] {
        var dirs = [MemberDir(profile: AssistantProfile.defaultName, generation: nil, directory: defaultDirectory)]
        if let doc = (try? AssistantRegistry.read(registryPaths)) ?? nil {
            for r in doc.records where r.name != AssistantProfile.defaultName {
                let dir = registryPaths.root.appendingPathComponent("members", isDirectory: true)
                    .appendingPathComponent(r.name, isDirectory: true).appendingPathComponent(r.generation, isDirectory: true)
                dirs.append(MemberDir(profile: r.name, generation: r.generation, directory: dir))
            }
        }
        return dirs
    }

    static func registeredDataRoots() -> [URL] {
        var roots = [MachinePaths.defaultDataRoot()]
        if let doc = (try? AssistantRegistry.read(.live)) ?? nil {
            roots += doc.records.filter { $0.name != AssistantProfile.defaultName }.map { AssistantProfile.extraDataRoot($0.name) }
        }
        return roots
    }

    static func displayName(_ profile: String, _ registryPaths: AssistantRegistry.Paths) -> String {
        if let r = ((try? AssistantRegistry.read(registryPaths)) ?? nil)?.record(profile) { return r.displayName }
        return profile == AssistantProfile.defaultName ? (KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? "Bree") : profile
    }

    // MARK: Run (steps 3–10)

    static func run(staged: StagedUpgrade, settings: Settings, holding lock: ProfileFileLock,
                    afterCommit: (UpgradeBarrier.Record) async -> Void = { _ in }) async -> Outcome {
        withExtendedLifetime(lock) {}
        let paths = settings.paths
        let own = settings.ownLease
        // 3. Publish the barrier (under registry.lock when there is one).
        var barrier = UpgradeBarrier.Record(
            id: UUID().uuidString.lowercased(), state: .open, targetVersion: staged.version, targetSequence: staged.sequence,
            openedAt: Date(),
            coordinator: .init(lease: own?.uuid ?? "", pid: getpid(), processStartTime: ProcessIdentity.selfStartTime),
            participants: nil, committedBinarySHA256: nil, reason: nil)
        do {
            if AssistantRegistry.exists(settings.registryPaths) {
                try AssistantRegistry.withLock(settings.registryPaths) { doc in
                    for r in doc?.records ?? [] {
                        if r.state != "active" { throw UpgradeJournal.Failure("‘\(r.displayName)’ is being removed; try again in a minute") }
                        for (_, a) in r.activeTx where ProfileFileLock.probe(settings.registryPaths.txLease(a.txId)) != .dead {
                            throw UpgradeJournal.Failure("a settings change of ‘\(r.displayName)’ is finishing; try again in a minute")
                        }
                    }
                    UpgradeBarrier.clearAcks(paths)
                    try UpgradeBarrier.writeBarrier(barrier, paths)
                }
            } else {
                UpgradeBarrier.clearAcks(paths)
                try UpgradeBarrier.writeBarrier(barrier, paths)
            }
        } catch {
            return .refused("\(error)")
        }
        MemberEntry.isCoordinator = true
        try? own?.update { $0.coordinator = true }
        func cancel(_ why: String) -> Outcome {
            barrier.state = .cancelled
            barrier.reason = why
            try? UpgradeBarrier.writeBarrier(barrier, paths)
            try? own?.update { $0.coordinator = false }
            MemberEntry.isCoordinator = false
            return .cancelled(why)
        }
        // Then probe every lease (the ordering rule). Snapshot assistants.
        let dirs = memberDirectories(settings.registryPaths, defaultDirectory: paths.root.deletingLastPathComponent().appendingPathComponent("members", isDirectory: true))
        var participants: [UpgradeBarrier.Participant] = []
        for d in dirs {
            for e in MemberLeases.list(d.directory) where e.probe != .dead {
                if e.probe == .unknown { return cancel("a Briglia process of ‘\(displayName(d.profile, settings.registryPaths))’ cannot be identified") }
                if e.isAssistant, let side = e.sidecar {
                    participants.append(.init(profile: d.profile, generation: d.generation, lease: e.uuid,
                                              incarnation: side.incarnation, coordinator: e.uuid == own?.uuid))
                }
            }
        }
        barrier.participants = participants
        do { try UpgradeBarrier.writeBarrier(barrier, paths) } catch { return cancel("cannot record the update: \(error)") }

        // 4–5. Wait for every participant to park and every session to end.
        let deadline = Date().addingTimeInterval(settings.waitSeconds)
        var toldWaiting = false
        let started = Date()
        while true {
            var busy: [String] = []
            for d in dirs {
                for e in MemberLeases.list(d.directory) where e.probe != .dead {
                    if e.probe == .unknown { return cancel("a Briglia process of ‘\(displayName(d.profile, settings.registryPaths))’ cannot be identified") }
                    if e.uuid == own?.uuid, !e.isAssistant { continue }      // a session coordinator
                    if e.isAssistant {
                        if !participants.contains(where: { $0.lease == e.uuid }) {
                            // A late starter: it parks at startup and acks;
                            // add it to the snapshot before publication.
                            if let ack = UpgradeBarrier.readAck(e.uuid, paths), ack.barrierId == barrier.id, ack.state == .parked,
                               let side = e.sidecar {
                                participants.append(.init(profile: d.profile, generation: d.generation, lease: e.uuid,
                                                          incarnation: side.incarnation, coordinator: false))
                                barrier.participants = participants
                                try? UpgradeBarrier.writeBarrier(barrier, paths)
                            } else {
                                busy.append("‘\(displayName(d.profile, settings.registryPaths))’ is starting")
                            }
                        }
                    } else {
                        busy.append("‘\(displayName(d.profile, settings.registryPaths))’ has \(e.sidecar?.sessionKind ?? "a window") open")
                    }
                }
            }
            for p in participants {
                let dir = dirs.first { $0.profile == p.profile }?.directory
                let lease = dir?.appendingPathComponent("\(p.lease).lock")
                if lease.map({ ProfileFileLock.probe($0) }) != .live {
                    return cancel("‘\(displayName(p.profile, settings.registryPaths))’ stopped during the update")
                }
                let ack = UpgradeBarrier.readAck(p.lease, paths)
                if ack?.barrierId == barrier.id, ack?.incarnation == p.incarnation, ack?.state == .parked { continue }
                let reason = (ack?.barrierId == barrier.id ? ack?.reason : nil) ?? "a job to finish"
                busy.append("‘\(displayName(p.profile, settings.registryPaths))’ (\(reason))")
            }
            if busy.isEmpty { break }
            if Date() >= deadline {
                return cancel("waited \(Int(settings.waitSeconds / 60)) minutes; still busy: \(busy.joined(separator: ", ")). Nothing was changed.")
            }
            if !toldWaiting, Date().timeIntervalSince(started) > 5 {
                toldWaiting = true
                settings.progress("Waiting for \(busy.joined(separator: ", "))… / In attesa di \(busy.joined(separator: ", "))…")
            }
            try? await Task.sleep(nanoseconds: UInt64(settings.poll * 1_000_000_000))
        }

        // 6. Pre-publication checks with everyone parked.
        for root in settings.checkpointRoots() {
            do { try TurnCheckpointStore.refuseReplacementWithUnfinishedEnvelope(dataRoot: root) } catch {
                return cancel("\(error)")
            }
        }
        if let refusal = trustRefusal(candidate: staged.sequence, floor: settings.trustFloor(),
                                      installed: settings.installedSequence(settings.executable)) {
            return cancel(refusal)
        }

        // 7–8. Journal, swap, verify, commit.
        do {
            let journal = try UpgradeJournal.swap(staged, barrierId: barrier.id, executable: settings.executable, paths: paths)
            try UpgradeJournal.commit(journal, barrier: &barrier, paths: paths)
        } catch {
            // The same table recovery uses (rollback or stuck).
            let current = UpgradeBarrier.current(paths) ?? barrier
            switch UpgradeJournal.recover(current, allowStuck: true, paths: paths) {
            case .cancelled(let why): _ = cancel("\(error); \(why)"); return .cancelled("install failed (\(error)); the previous version is still installed")
            case .committed: barrier = UpgradeBarrier.current(paths) ?? barrier
            case .stuck(let why), .malformed(let why): return .stuck(why)
            case .nothing, .closedCleanup: return .stuck("unexpected state after a failed install: \(error)")
            }
        }
        settings.progress("✔ Installed \(staged.version).")
        // 9. Assistants restart (the initiating one through afterCommit).
        await afterCommit(barrier)
        // 10. A session coordinator closes the barrier itself (R5-1).
        let closeDeadline = Date().addingTimeInterval(max(settings.waitSeconds, 60))
        while Date() < closeDeadline {
            if closeIfPossible(settings, holdingLock: true) { break }
            try? await Task.sleep(nanoseconds: UInt64(settings.poll * 1_000_000_000))
        }
        try? own?.update { $0.coordinator = false }
        MemberEntry.isCoordinator = false
        return .committed(version: staged.version, barrierId: barrier.id)
    }

    // MARK: Closure (§6.3 step 10)

    /// Computed from disk only. With `holdingLock: false` the caller tries
    /// `upgrade.lock` non-blocking first (assistants' monitor and startup).
    @discardableResult
    static func closeIfPossible(_ settings: Settings, holdingLock: Bool = true) -> Bool {
        var held: ProfileFileLock?
        if !holdingLock {
            guard case .acquired(let l) = ProfileFileLock.take(settings.paths.lock) else { return false }
            held = l
        }
        defer { held?.release() }
        guard var barrier = UpgradeBarrier.current(settings.paths), barrier.state == .committed else { return false }
        let dirs = memberDirectories(settings.registryPaths, defaultDirectory: settings.paths.root.deletingLastPathComponent().appendingPathComponent("members", isDirectory: true))
        for p in barrier.participants ?? [] {
            if let ack = UpgradeBarrier.readAck(p.lease, settings.paths), ack.barrierId == barrier.id, ack.state == .restarted,
               (ack.releaseSequence ?? 0) >= barrier.targetSequence { continue }
            let dir = dirs.first { $0.profile == p.profile }?.directory
            guard let dir, ProfileFileLock.probe(dir.appendingPathComponent("\(p.lease).lock")) == .dead else { return false }
            // Dead: closable only when no assistant of that profile still runs an older image.
            let stale = MemberLeases.users(dir, assistantsOnly: true).contains { ($0.sidecar?.releaseSequence ?? 0) < barrier.targetSequence }
            if stale { return false }
        }
        barrier.state = .closed
        guard (try? UpgradeBarrier.writeBarrier(barrier, settings.paths)) != nil else { return false }
        UpgradeJournal.cleanup(settings.paths)
        UpgradeBarrier.clearAcks(settings.paths)
        return true
    }

    // MARK: Recovery command (§6.5)

    /// `briglia upgrade --recover`: holds `upgrade.lock` (taken before any
    /// session check), validates the records and runs the table, including
    /// a stuck barrier. Returns the text for the user and a success flag.
    static func recoverCommand(_ settings: Settings = Settings()) -> (ok: Bool, text: String) {
        let lock: ProfileFileLock
        switch acquire(settings.paths) {
        case .success(let l): lock = l
        case .failure(let why): return (false, why.description)
        }
        defer { lock.release() }
        guard let barrier = UpgradeBarrier.current(settings.paths) else { return (true, "No update is in progress; nothing to recover.") }
        if barrier.id == "malformed" {
            return (false, "The update record is damaged (\(barrier.reason ?? "?")); nothing was changed. Files: \(settings.paths.barrier.path), \(settings.paths.journal.path)")
        }
        switch UpgradeJournal.recover(barrier, allowStuck: true, paths: settings.paths) {
        case .nothing(let t):
            if closeIfPossible(settings) { return (true, "✔ The update was already finished; closed it.") }
            return (true, t)
        case .cancelled(let t): return (true, "✔ " + t)
        case .committed(let t):
            closeIfPossible(settings)
            return (true, "✔ " + t)
        case .closedCleanup: return (true, "✔ The previous update was already finished; leftovers removed.")
        case .stuck(let t): return (false, "✖ " + t)
        case .malformed(let t): return (false, "✖ " + t)
        }
    }
}
