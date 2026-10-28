import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The member entry protocol (MULTI_ASSISTANT_PLAN §4.4), run from
/// `AdaCLI.main()` right after the profile bootstrap and before
/// ArgumentParser, so no command touches profile state or a bundle resource
/// before it holds its lease:
///
/// 1. extras read their registry record (unlocked) for the generation;
/// 2. create and lock the lease, write its sidecar;
/// 3. THEN re-read the barrier and (extras) the record — removed/regenerated
///    → exit; a barrier → sessions exit, assistants park at startup;
/// 4. assistants run the settings admission check (§5.6);
/// 5. return: the command takes its instance lock and starts.
///
/// "Publish, then look" (the ordering rule): an upgrader publishes the
/// barrier then probes leases; a remover publishes `removing` then probes.
/// Inactive (no registry and no experimental switch) → nothing happens.
enum MemberEntry {
    enum Role: Equatable {
        case assistant(kind: String)
        case session(kind: String)
        /// `briglia upgrade --recover`: a session that may enter during a
        /// barrier because it takes `upgrade.lock` itself (§6.5).
        case recovery
    }

    /// This process's lease (nil when exempt or coordination is inactive).
    nonisolated(unsafe) private(set) static var current: MemberLease?
    /// This profile's registry generation (extras).
    nonisolated(unsafe) private(set) static var generation: String?
    /// Writer leases this process created (its own registry transactions).
    nonisolated(unsafe) static var ownTxIds = Set<String>()
    private static let txLock = NSLock()

    static func noteOwnTx(_ id: String) { txLock.lock(); ownTxIds.insert(id); txLock.unlock() }
    static func forgetOwnTx(_ id: String) { txLock.lock(); ownTxIds.remove(id); txLock.unlock() }
    static func isOwnTx(_ id: String) -> Bool { txLock.lock(); defer { txLock.unlock() }; return ownTxIds.contains(id) }

    // MARK: Classification

    /// Commands that never take a lease (§6.1 exempt list): version/help,
    /// the resource-free release identity, the exec trampolines, installer
    /// probes carrying the coordinator's barrier token, read-only doctor,
    /// the supervisor (it holds no profile state) and dev selftests (which
    /// run against temporary roots).
    static func classify(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Role? {
        let words = arguments
        if words.contains("--version") || words.contains("--help") || words.contains("-h") { return nil }
        if let token = environment["BRIGLIA_UPGRADE_PROBE"], !token.isEmpty, UpgradeProbe.valid(token) { return nil }
        // No subcommand = chat (the default command).
        guard let first = words.first(where: { !$0.hasPrefix("-") }) else { return .assistant(kind: "chat") }
        switch first {
        case "help", "__release-identity", "__setsid-exec", "__gate-exec":
            return nil
        case "chat":
            return .assistant(kind: "chat")
        case "daemon":
            return words.contains("--all") ? nil : .assistant(kind: "daemon")
        case "doctor":
            return words.contains("--read-only") ? nil : .session(kind: "doctor")
        case "upgrade", "update":
            return words.contains("--recover") ? .recovery : .session(kind: "upgrade")
        case "__member-probe":
            // Selftest probe: an assistant only in development builds.
            return words.contains("--assistant") && adaCLIVersion.hasSuffix("-dev")
                ? .assistant(kind: "probe") : .session(kind: "probe")
        default:
            if first.hasSuffix("selftest") || first.hasSuffix("-selftest") { return nil }
            return .session(kind: first)
        }
    }

    // MARK: Entry

    static func fail(_ message: String, code: Int32 = 2) -> Never {
        FileHandle.standardError.write(Data(("✖ " + message + "\n").utf8))
        current?.release()
        exit(code)
    }

    static func leaseDirectory(profile: String, generation: String?) -> URL? {
        MemberLeases.directory(profile: profile, generation: generation)
    }

    static func enter(arguments: [String]) {
        guard CoordinationMode.active, let role = classify(arguments) else { return }
        let profile = AssistantProfile.selectedName
        // 1. Generation (extras), unlocked.
        if AssistantProfile.isExtra {
            guard let record = registryRecord(profile) else {
                fail("This assistant is not registered on this computer (it may have been removed). Run `briglia profiles list`.")
            }
            guard record.state == "active" else { fail("This assistant is being removed.") }
            generation = record.generation
        }
        guard let directory = leaseDirectory(profile: profile, generation: generation) else {
            fail("This assistant is not registered on this computer.")
        }
        // 2. Lease.
        let (roleName, kind): (String, String) = {
            switch role {
            case .assistant(let k): return ("assistant", k)
            case .session(let k): return ("session", k)
            case .recovery: return ("session", "upgrade-recover")
            }
        }()
        MemberLeases.sweep(directory)
        do {
            current = try MemberLease.create(in: directory, role: roleName, sessionKind: kind, profile: profile)
            if role == .recovery { try current?.update { $0.recovery = true } }
        } catch {
            fail("\(error)", code: 1)
        }
        // Released at every normal exit (a crash leaves a free lock that the
        // next sweep removes).
        atexit { MemberEntry.releaseAtExit() }
        // Dev-only seam: widen the window between publishing the lease and
        // looking at the barrier/registry (race tests, §16 6a/6d).
        if adaCLIVersion.hasSuffix("-dev"), let ms = Double(ProcessInfo.processInfo.environment["BRIGLIA_TEST_ENTRY_PAUSE_MS"] ?? ""), ms > 0 {
            Thread.sleep(forTimeInterval: ms / 1000)
        }
        // 3. Look.
        recheckRecord(profile)
        if role != .recovery {
            switch role {
            case .session:
                if let barrier = UpgradeBarrier.current(), barrier.isActive { fail(UpgradeBarrier.updatingMessage, code: 75) }
                UpgradeBarrier.reexecIfOlder()
            case .assistant:
                parkAtStartupIfNeeded()
                UpgradeBarrier.reexecIfOlder()
                // 4. Settings admission.
                settingsAdmission(profile: profile)
            case .recovery:
                break
            }
        }
        if case .session(let kind) = role, longLivedSessionKinds.contains(kind) {
            startSessionBarrierWatch()
        }
    }

    static func releaseAtExit() { current?.release() }

    /// Status lines printed before the command set up its own buffering.
    static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    static func registryRecord(_ profile: String) -> AssistantRegistry.Record? {
        (try? AssistantRegistry.read(.live))??.record(profile)
    }

    /// Step 3 for extras: the record is still there, active, same generation.
    static func recheckRecord(_ profile: String) {
        guard AssistantProfile.isExtra else { return }
        guard let record = registryRecord(profile), record.state == "active", record.generation == generation else {
            fail("This assistant was removed. / Questo assistente è stato rimosso.")
        }
    }

    // MARK: Startup parking (§6.3 step 11)

    /// An assistant that finds an open barrier parks before touching state,
    /// acking `parked` so the coordinator adds it to the snapshot; on
    /// `committed` it re-execs if its image is older; on `cancelled` it
    /// continues. A stuck barrier keeps it parked.
    static func parkAtStartupIfNeeded(poll: TimeInterval = 2) {
        var told = false
        while let barrier = UpgradeBarrier.current(), barrier.isActive {
            switch barrier.state {
            case .open, .stuck:
                if !told {
                    say(barrier.state == .stuck ? "· \(UpgradeBarrier.stuckMessage)"
                        : "· Briglia is updating; this assistant starts when the update finishes.")
                    told = true
                }
                if barrier.state == .open, let lease = current {
                    UpgradeBarrier.writeAck(UpgradeBarrier.Ack(barrierId: barrier.id, incarnation: lease.sidecar.incarnation,
                                                               state: .parked, reason: "starting"), lease: lease.uuid)
                }
                Thread.sleep(forTimeInterval: poll)
            case .committed:
                UpgradeBarrier.reexecIfOlder()
                return
            default:
                return
            }
        }
    }

    // MARK: Settings admission (§4.4 step 4, §5.6)

    /// A starting assistant waits while an offline setter's transaction of
    /// this profile is live. Never-multi default briefly takes
    /// `machine/identity-tx.lock`. When another assistant of this profile is
    /// already running, the writer may be that assistant: entry continues and
    /// the instance lock reports "already running" as today.
    static func settingsAdmission(profile: String, poll: TimeInterval = 1, maxWait: TimeInterval = .infinity) {
        let started = Date()
        var told = false
        while true {
            switch admissionBlocker(profile: profile) {
            case .none:
                return
            case .some(let why):
                if otherAssistantRunning(profile) { return }
                if !told { say("· \(why)"); told = true }
                if Date().timeIntervalSince(started) > maxWait { return }
                Thread.sleep(forTimeInterval: poll)
            }
        }
    }

    static let settingsFinishingMessage = "a settings change for this assistant is finishing; starting in a moment"

    /// nil = admitted.
    static func admissionBlocker(profile: String, paths: AssistantRegistry.Paths = .live) -> String? {
        switch AssistantRegistry.presence(paths) {
        case .absent:
            guard profile == AssistantProfile.defaultName else { return "this assistant's registry is missing" }
            try? MachinePaths.ensureMachineDir()
            switch ProfileFileLock.take(MachinePaths.identityTxLock) {
            case .acquired(let lock): lock.release(); return nil
            case .busy: return settingsFinishingMessage
            case .failed: return nil    // the setter path fails closed on its own
            }
        case .unreadable(let why):
            return "the assistants registry cannot be read (\(why))"
        case .present:
            do {
                return try AssistantRegistry.withLock(paths) { doc -> String? in
                    guard let record = doc?.record(profile) else { return nil }
                    for (_, active) in record.activeTx where !isOwnTx(active.txId) {
                        if ProfileFileLock.probe(paths.txLease(active.txId)) != .dead { return settingsFinishingMessage }
                    }
                    return nil
                }
            } catch {
                return "\(error)"
            }
        }
    }

    static func otherAssistantRunning(_ profile: String) -> Bool {
        guard let dir = leaseDirectory(profile: profile, generation: generation) else { return false }
        return !MemberLeases.users(dir, assistantsOnly: true, except: current?.uuid).isEmpty
    }

    // MARK: Promotion (menu → terminal chat, quick setup → chat)

    /// Role session → assistant without releasing the lease, then steps
    /// (3)–(4) again (§4.4). Returns a refusal text when the switch must not
    /// happen (a barrier opened meanwhile).
    static func promoteToAssistant(kind: String = "chat") -> String? {
        guard let lease = current else { return nil }
        do { try lease.update { $0.role = "assistant"; $0.sessionKind = kind } } catch { return "\(error)" }
        stopSessionBarrierWatch()
        recheckRecord(AssistantProfile.selectedName)
        parkAtStartupIfNeeded()
        settingsAdmission(profile: AssistantProfile.selectedName)
        return nil
    }

    // MARK: Long-lived sessions close themselves when a barrier opens

    static let longLivedSessionKinds: Set<String> = ["menu", "setup", "quicksetup", "setup-api"]
    nonisolated(unsafe) private static var watchThread: Thread?
    nonisolated(unsafe) private static var watchStopped = false
    /// Set by the coordinator path: this process opened the barrier.
    nonisolated(unsafe) static var isCoordinator = false

    static func startSessionBarrierWatch(poll: TimeInterval = 2) {
        let thread = Thread {
            while !watchStopped {
                Thread.sleep(forTimeInterval: poll)
                if watchStopped || isCoordinator { continue }
                if let b = UpgradeBarrier.current(), b.state == .open || b.state == .stuck {
                    // Never cut a settings write in half: wait for the
                    // secrets lock (every secrets write holds it), then go.
                    KeychainHelper.withSecretsLockForExit {
                        print("\n· \(UpgradeBarrier.updatingMessage)")
                        fflush(stdout)
                        current?.release()
                        exit(75)
                    }
                }
            }
        }
        thread.name = "briglia.session-barrier-watch"
        watchThread = thread
        thread.start()
    }

    static func stopSessionBarrierWatch() { watchStopped = true }
}

/// Installer and recovery verification probes (§6.1 exempt): the
/// coordinator runs the staged/installed binary with
/// `BRIGLIA_UPGRADE_PROBE=<barrier id>`; it is valid only while that barrier
/// is open or committed and `upgrade.lock` is held (a probe never takes it).
enum UpgradeProbe {
    static func valid(_ token: String) -> Bool {
        guard let barrier = UpgradeBarrier.current(), barrier.id == token, barrier.isActive else { return false }
        return ProfileFileLock.probe(UpgradeBarrier.Paths.live.lock) == .live
    }
}
