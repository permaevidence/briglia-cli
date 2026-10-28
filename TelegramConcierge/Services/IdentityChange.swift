import Foundation

/// Every change of an assistant's Telegram bot or AgentMail inbox goes
/// through here (MULTI_ASSISTANT_PLAN §5.6): `/switchbot`, setup-api (the
/// menu and the phone app), the terminal wizard and `profiles add`.
///
/// - Coordination inactive (no registry, no experimental switch): today's
///   behaviour — the caller's write runs directly.
/// - Default, never-multi (no registry yet): `machine/identity-tx.lock` is
///   held for the whole change, so a first `profiles add` cannot create the
///   registry (and hand this value to another assistant) halfway through.
/// - With a registry: a reservation transaction — `pending` published before
///   any network use, the secret written at commit, the old value kept
///   `releasing` until the old consumer is quiescent, then released.
/// - Offline setters (any process that is not this profile's running
///   assistant) refuse while that assistant runs: the probe of its leases and
///   the publication of `activeTx` happen in one registry critical section.
enum IdentityChange {
    enum Mode: Equatable {
        /// Not the running assistant of the profile (setup-api child,
        /// terminal setup, a standalone menu, `profiles add`).
        case offline
        /// This process IS the profile's running assistant (its own
        /// `/switchbot`, or the live menu it serves).
        case assistant
    }

    /// The mode implied by this process's member lease.
    static var processMode: Mode {
        MemberEntry.current?.sidecar.role == "assistant" ? .assistant : .offline
    }

    struct Refusal: Error, CustomStringConvertible, LocalizedError {
        let description: String
        init(_ d: String) { description = d }
        var errorDescription: String? { description }
    }

    static let runningMessage = "This assistant is running; change its bot from its own menu or stop it first. / Questo assistente è in funzione; cambia il bot dal suo menu o fermalo prima."
    static let identityBusyMessage = "Another change of an assistant's bot or email is in progress on this computer, or an assistant is being added — try again in a moment."

    /// A change in progress. `commit` writes the secret (inside the
    /// registry transaction when there is one); `finish` releases the old
    /// value once its consumer is quiescent; `abort` undoes a reservation.
    final class Ticket {
        let kind: AssistantRegistry.Kind
        private(set) var tx: AssistantRegistry.Transaction?
        private var identityLock: ProfileFileLock?
        private let ownsIdentityLock: Bool
        private(set) var committed = false
        private(set) var ended = false

        init(kind: AssistantRegistry.Kind, tx: AssistantRegistry.Transaction?, identityLock: ProfileFileLock?, ownsIdentityLock: Bool) {
            self.kind = kind; self.tx = tx; self.identityLock = identityLock; self.ownsIdentityLock = ownsIdentityLock
        }

        var reserved: Bool { tx != nil }

        func commit(_ write: () throws -> Void) throws {
            precondition(!ended, "identity ticket already ended")
            if let tx { try tx.commit(writeSecret: write) } else { try write() }
            committed = true
        }

        func finish() {
            guard !ended else { return }
            ended = true
            if let tx { try? tx.finish() }
            tx = nil
            if ownsIdentityLock { identityLock?.release() }
            identityLock = nil
        }

        func abort() {
            guard !ended else { return }
            ended = true
            tx?.abort()
            tx = nil
            if ownsIdentityLock { identityLock?.release() }
            identityLock = nil
        }

        deinit { abort() }
    }

    /// Start a change of `kind` to `rawValue` (nil/empty = removal) for the
    /// selected profile. `existingIdentityLock`: default's identity lock this
    /// process already holds (a `/switchbot` admitted by
    /// `BotSwitchDiscovery`), reused instead of a conflicting second flock.
    static func begin(kind: AssistantRegistry.Kind, rawValue: String?, mode: Mode = processMode,
                      profile: String = AssistantProfile.selectedName,
                      existingIdentityLock: ProfileFileLock? = nil,
                      paths: AssistantRegistry.Paths = .live,
                      identityLockURL: URL? = nil,
                      ownLease: String? = MemberEntry.current?.uuid,
                      leaseDirectory: ((AssistantRegistry.Record) -> URL?)? = nil) throws -> Ticket {
        guard CoordinationMode.active || AssistantRegistry.exists(paths) else {
            return Ticket(kind: kind, tx: nil, identityLock: nil, ownsIdentityLock: false)
        }
        var lock: ProfileFileLock?
        var owns = false
        if profile == AssistantProfile.defaultName {
            if let existingIdentityLock, existingIdentityLock.fd >= 0 {
                lock = existingIdentityLock
            } else {
                if identityLockURL == nil { try MachinePaths.ensureMachineDir() }
                switch ProfileFileLock.take(identityLockURL ?? MachinePaths.identityTxLock, waitSeconds: 2) {
                case .acquired(let l): lock = l; owns = true
                case .busy: throw Refusal(identityBusyMessage)
                case .failed(let why): throw Refusal(why)
                }
            }
        }
        func release() { if owns { lock?.release() } }
        // After taking the identity lock: no registry → today's behaviour.
        guard AssistantRegistry.exists(paths) else {
            return Ticket(kind: kind, tx: nil, identityLock: lock, ownsIdentityLock: owns)
        }
        let leases: (AssistantRegistry.Record) -> URL? = leaseDirectory ?? { record in
            MemberLeases.directory(profile: record.name, generation: record.generation)
        }
        let precheck: (AssistantRegistry.Record) -> String? = { record in
            guard mode == .offline else { return nil }
            guard let dir = leases(record) else { return nil }
            return MemberLeases.users(dir, assistantsOnly: true, except: ownLease).isEmpty ? nil : runningMessage
        }
        // Changes AND removals are registry transactions (Codex stage-2 R4):
        // published with the offline probe, old ownership kept until commit,
        // released after the consumer is quiescent.
        do {
            let tx = try AssistantRegistry.begin(profile: profile, kind: kind, rawValue: rawValue, paths: paths, precheck: precheck)
            return Ticket(kind: kind, tx: tx, identityLock: lock, ownsIdentityLock: owns)
        } catch {
            release()
            throw error
        }
    }

    /// A setter without a live consumer to cut over (offline, or a value no
    /// running poller uses yet): begin, commit, finish.
    static func apply(kind: AssistantRegistry.Kind, rawValue: String?, mode: Mode = processMode,
                      write: () throws -> Void) throws {
        let ticket = try begin(kind: kind, rawValue: rawValue, mode: mode)
        do { try ticket.commit(write) } catch { ticket.abort(); throw error }
        ticket.finish()
    }

    // MARK: Live hub: finish after the reload that cut the consumer over

    nonisolated(unsafe) private static var deferred: [Ticket] = []
    private static let deferredLock = NSLock()

    /// The live menu (running inside the assistant) commits, then the agent
    /// reloads its pollers; only after that reload is the old value released.
    static func deferFinish(_ ticket: Ticket) {
        deferredLock.lock(); deferred.append(ticket); deferredLock.unlock()
    }

    /// `quiescent: false` (the old poller did not confirm it stopped): the
    /// tickets stay open — their writer leases keep the old value reserved —
    /// until a later reload confirms, or this process exits (dead writer).
    static func finishDeferred(quiescent: Bool = true) {
        guard quiescent else { return }
        deferredLock.lock(); let tickets = deferred; deferred = []; deferredLock.unlock()
        for t in tickets { t.finish() }
    }
}
