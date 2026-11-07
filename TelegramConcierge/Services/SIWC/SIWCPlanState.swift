import Foundation

// Plan state of each SIWC registration (SIWC plan §5.1, D23).
//
// One small file per SIWC store (`subscription-siwc-plan.json`), written
// under that store's SIWC lock as maintenance (never a settings change). It
// belongs to the registration, so with several assistants on one shared
// login every sharer reads the same state; only the assistant whose request
// OPENED an episode pushes its entry notice, and exactly one assistant
// claims the recovery notice (compare-and-set under the lock).
//
// - `admit` is the gate before EVERY SIWC send (adapter rounds and retries,
//   web stages, the model list): background lanes send nothing in a blocking
//   state; a user turn sends nothing in `sign_in_required` or
//   `not_available` (unless the user acted since) and makes one attempt in
//   `limit_reached`.
// - `observe` changes the state only with the episode AND credential
//   generation the request started under (a late answer never rolls a newer
//   state back and never sends a recovery notice).

struct SIWCPlanEntry: Codable, Equatable {
    enum State: String, Codable { case ok, limitReached = "limit_reached", signInRequired = "sign_in_required", notAvailable = "not_available" }
    var state: State = .ok
    /// Monotonic per registration: +1 each time a blocking state opens.
    var episode: Int = 0
    /// Profile whose classified answer opened the episode (the opener).
    var openedBy: String? = nil
    /// The opener's destination identity when it opened (bot fingerprint +
    /// paired chat), nil = no push channel (a terminal line only).
    var destination: String? = nil
    /// queued | delivered | dropped | local
    var entryNotice: String? = nil
    /// The assistant that claimed the recovery notice of `recoveryEpisode`.
    var recoveryClaimedBy: String? = nil
    var recoveryDestination: String? = nil
    var recoveryEpisode: Int? = nil
    /// queued | delivered | dropped | local
    var recoveryNotice: String? = nil
    /// `not_available`: a user action (sign-in, /provider, a settings change)
    /// allows the next user turn ONE attempt.
    var retryAllowed: Bool? = nil
    /// `not_available`: the recognized reason code, if any (never body text).
    var reason: String? = nil
    var changedAt: Int = 0

    var blocking: Bool { state != .ok }
}

struct SIWCPlanFile: Codable, Equatable {
    var version = 1
    /// Key: registration fingerprint.
    var entries: [String: SIWCPlanEntry] = [:]
}

enum SIWCPlanState {
    static let fileName = SIWCEndpoint.planFileName

    // MARK: Wording (§5.1 item 1, fixed strings)

    static let limitNotice = "ChatGPT usage limit reached for Briglia. Paused until your plan has room again. Manage usage: chatgpt.com/settings/usage"
    static let signInNotice = "ChatGPT sign-in for Briglia has expired or was revoked."
    static func notAvailableNotice(_ reason: String?) -> String {
        "ChatGPT says this account or workspace can't use its plan in Briglia" + (reason.map { " (\($0))" } ?? "") + ". Nothing will be retried."
    }
    static let recoveryNotice = "✅ ChatGPT plan working again."
    static let creditsNote = "If “use credits after reaching plan limits” is on for Briglia in ChatGPT Settings → Usage, ChatGPT may keep answering on credits and Briglia can't see it."
    static let signInOffer = "Sign in again with /subscription login, or in briglia menu on the computer."

    /// What a blocked request answers (no send happened).
    static let pausedLimitMessage = "ChatGPT usage limit reached for Briglia; background work is paused until your plan has room again (Manage usage: chatgpt.com/settings/usage). Nothing was sent."
    static let pausedSignInMessage = signInNotice + " " + signInOffer + " Nothing was sent."
    static let pausedNotAvailableMessage = "ChatGPT says this account or workspace can't use its plan in Briglia. Nothing was sent or retried; sign in again, change the provider or the model to try once more."

    /// Error texts that mean "the plan is paused, not a maintenance fault":
    /// archive and memory jobs keep their items, consume no retries and raise
    /// no maintenance alert for them (§5.1 item 2).
    static let pauseTexts: [String] = [pausedLimitMessage, pausedSignInMessage, pausedNotAvailableMessage,
        SIWCError.limitMessage, SIWCError.signInMessage, SIWCError.notEligibleMessage, SIWCError.notEnabledMessage,
        SIWCError.signedOutMessage, SIWCError.planUsageOffMessage, SIWCError.invalidClientMessage]

    static func isPause(_ text: String) -> Bool { pauseTexts.contains { text.contains($0) } }
    static func isPause(_ error: Error?) -> Bool {
        guard let error else { return false }
        if let e = error as? SIWCError {
            return [.limitReached, .signInRequired, .notAvailable, .signedOut, .planUsageOff, .invalidClient, .disabled].contains(e.kind)
        }
        return isPause(error.localizedDescription)
    }

    // MARK: Process seams (installed by the daemon)

    /// This process's destination identity for a push (nil = none).
    nonisolated(unsafe) static var destination: () -> String? = { nil }
    /// Called (any task) when this process opened an episode or claimed a
    /// recovery: the daemon delivers queued notices it owns.
    nonisolated(unsafe) static var onNotice: (() -> Void)?
    /// Selftest seam: the profile name of this process.
    nonisolated(unsafe) static var profileForTesting: String?
    static var me: String { profileForTesting ?? AssistantProfile.selectedName }

    static func url(_ store: SIWCStore) -> URL { store.directory.appendingPathComponent(fileName) }

    static func read(_ store: SIWCStore) throws -> SIWCPlanFile {
        guard let data = try SIWCStore.readOwnerOnly(url(store), cap: 65536) else { return SIWCPlanFile() }
        guard let file = try? JSONDecoder().decode(SIWCPlanFile.self, from: data), file.version == 1 else {
            throw SIWCError(.local, "The ChatGPT plan state is unreadable.")
        }
        return file
    }

    static func entry(_ store: SIWCStore, clientId: String) -> SIWCPlanEntry? {
        (try? read(store))?.entries[SIWCEndpoint.registrationFingerprint(clientId: clientId)]
    }

    /// Maintenance write under the store's SIWC lock (short wait: it runs on
    /// request paths). A failure is logged, never thrown into a request.
    @discardableResult
    static func mutate<T>(_ store: SIWCStore, _ body: (inout SIWCPlanFile) -> T) -> T? {
        do {
            return try store.lockedSync(wait: 5) {
                var file: SIWCPlanFile
                do { file = try read(store) } catch { file = SIWCPlanFile() }   // unreadable: start over (state only)
                let before = file
                let value = body(&file)
                if file != before { _ = try PrivateStorage.writeAtomically(try SIWCStore.encode(file), to: url(store)) }
                return value
            }
        } catch {
            print("[SIWC] plan state not saved: \((error as? SIWCError)?.message ?? "\(error)")")
            return nil
        }
    }

    // MARK: Gate

    struct Ticket: Equatable {
        let storeDirectory: URL
        let clientId: String
        let generation: String
        let episode: Int
        let userTurn: Bool
    }

    /// The gate before every SIWC send. Throws (nothing sent) in a blocking
    /// state per the rules above; otherwise returns the ticket `observe` needs.
    /// `claim` = this user turn's one recovery send is still unused (and is
    /// used now); it is asked only in a blocking state.
    static func admit(_ source: SIWCCredentialSource, userTurn: Bool, claim: () -> Bool = { true }) throws -> Ticket {
        let fp = SIWCEndpoint.registrationFingerprint(clientId: source.clientId)
        let entry = (try? read(source.store))?.entries[fp] ?? SIWCPlanEntry()
        switch entry.state {
        case .ok: break
        case .limitReached:
            guard userTurn, claim() else { throw SIWCError(.limitReached, pausedLimitMessage) }
        case .signInRequired:
            throw SIWCError(.signInRequired, SubscriptionSharing.decorateRevocation(pausedSignInMessage))
        case .notAvailable:
            guard userTurn, entry.retryAllowed == true, claim() else { throw SIWCError(.notAvailable, pausedNotAvailableMessage) }
            // The allowance is consumed atomically, under the store lock,
            // before the send: a second admission (another round, another
            // sharer) finds it used; an unclassified failure can't keep it.
            let consumed = mutate(source.store) { file -> Bool in
                guard var e = file.entries[fp], sameEpisode(e, Ticket(storeDirectory: source.storeDirectory, clientId: source.clientId,
                      generation: source.generation, episode: entry.episode, userTurn: true)), e.state == .notAvailable, e.retryAllowed == true else { return false }
                e.retryAllowed = nil
                file.entries[fp] = e
                return true
            } ?? false
            guard consumed else { throw SIWCError(.notAvailable, pausedNotAvailableMessage) }
        }
        return Ticket(storeDirectory: source.storeDirectory, clientId: source.clientId, generation: source.generation,
                      episode: entry.episode, userTurn: userTurn)
    }

    /// Whether the current task is a user turn (the main turn's registered
    /// job); subagents, web runs, archive and watcher jobs are background.
    /// A user turn gets ONE send in a blocking state (Codex D-R4).
    static func admitCurrent(_ source: SIWCCredentialSource) throws -> Ticket {
        let key = source.fenceKey
        return try admit(source, userTurn: SIWCFence.shared.currentTaskIsUserTurn(key),
                         claim: { SIWCFence.shared.claimRecoveryAttempt(key) })
    }

    // MARK: Observe

    enum Outcome: Equatable { case success, failure(SIWCError) }

    /// Late results: only the episode the request started under may change
    /// the state (§5.1 item 6).
    static func sameEpisode(_ entry: SIWCPlanEntry, _ ticket: Ticket) -> Bool { entry.episode == ticket.episode }

    enum Transition: Equatable {
        case none
        case opened(episode: Int, state: SIWCPlanEntry.State)
        case recovered(episode: Int, claimed: Bool)
    }

    /// Record a classified answer. Only with the episode and credential
    /// generation the request started under.
    @discardableResult
    static func observe(_ ticket: Ticket?, _ outcome: Outcome, now: Int = Int(Date().timeIntervalSince1970)) -> Transition {
        guard let ticket else { return .none }
        let store = SIWCStore(directory: ticket.storeDirectory)
        let fp = SIWCEndpoint.registrationFingerprint(clientId: ticket.clientId)
        // The target state, decided outside the lock.
        var target: SIWCPlanEntry.State? = nil
        var reason: String? = nil
        switch outcome {
        case .success: target = .ok
        case .failure(let error):
            switch error.kind {
            case .limitReached: target = .limitReached
            case .notAvailable:
                target = .notAvailable
                reason = error.message == SIWCError.notEnabledMessage ? "v2_client_not_enabled" : nil
            case .signInRequired, .invalidClient:
                // Only when the record the request used is really unusable
                // now (a changed login is "login changed", not a plan state).
                guard let tokens = try? store.readTokens(), let record = tokens.record(ticket.clientId),
                      record.generation == ticket.generation else { return .none }
                let key = try? store.integrityKey(create: false)
                let registration = (try? store.readRegistrations())?.registration(ticket.clientId)
                guard store.usability(record, registration: registration, key: key) != .usable else { return .none }
                target = .signInRequired
            default: break
            }
        }
        // Fast path (no lock): nothing to change for the common answer.
        if let current = try? read(store) {
            let entry = current.entries[fp] ?? SIWCPlanEntry()
            if !sameEpisode(entry, ticket) { return .none }
            if target == nil, !(ticket.userTurn && entry.retryAllowed == true) { return .none }
            if target == entry.state, !(ticket.userTurn && entry.retryAllowed == true) { return .none }
        }
        let destination = Self.destination()
        let result: Transition = mutate(store) { file in
            var entry = file.entries[fp] ?? SIWCPlanEntry()
            // Late results: the episode and the credential generation must
            // still be the ones the request started under.
            guard sameEpisode(entry, ticket) else { return Transition.none }
            if let current = try? store.readTokens()?.record(ticket.clientId), current.generation != ticket.generation {
                return .none
            }
            guard let target else {
                // A transient answer of the one allowed user attempt ends it.
                if ticket.userTurn, entry.state == .notAvailable, entry.retryAllowed == true {
                    entry.retryAllowed = nil; file.entries[fp] = entry
                }
                return .none
            }
            if target == entry.state {
                if target == .notAvailable, ticket.userTurn { entry.retryAllowed = nil; file.entries[fp] = entry }
                return .none
            }
            if target == .ok {
                let alerted = entry.entryNotice != nil && entry.entryNotice != "dropped"
                let closing = entry.episode
                entry.state = .ok; entry.retryAllowed = nil; entry.reason = nil; entry.changedAt = now
                var claimed = false
                if alerted, entry.recoveryEpisode != closing {
                    entry.recoveryEpisode = closing
                    entry.recoveryClaimedBy = me
                    entry.recoveryDestination = destination
                    entry.recoveryNotice = destination == nil ? "local" : "queued"
                    claimed = true
                }
                file.entries[fp] = entry
                return .recovered(episode: closing, claimed: claimed)
            }
            entry.episode += 1
            entry.state = target
            entry.reason = target == .notAvailable ? reason : nil
            entry.openedBy = me
            entry.destination = destination
            entry.entryNotice = destination == nil ? "local" : "queued"
            entry.recoveryClaimedBy = nil; entry.recoveryDestination = nil; entry.recoveryNotice = nil
            entry.retryAllowed = nil
            entry.changedAt = now
            file.entries[fp] = entry
            return .opened(episode: entry.episode, state: target)
        } ?? .none
        switch result {
        case .opened(_, let state):
            print("[ChatGPT] " + entryText(state, reason: reason))
            onNotice?()
        case .recovered(_, true):
            print("[ChatGPT] " + recoveryNotice)
            onNotice?()
        default: break
        }
        return result
    }

    static func entryText(_ state: SIWCPlanEntry.State, reason: String?) -> String {
        switch state {
        case .ok: return recoveryNotice
        case .limitReached: return limitNotice + " " + creditsNote
        case .signInRequired: return signInNotice + " " + signInOffer
        case .notAvailable: return notAvailableNotice(reason)
        }
    }

    // MARK: User actions and sign-in

    /// A successful sign-in to `clientId` clears `sign_in_required` directly
    /// (no recovery notice: the user just signed in) and allows one attempt
    /// in `not_available`.
    static func signedIn(_ store: SIWCStore, clientId: String, now: Int = Int(Date().timeIntervalSince1970)) {
        let fp = SIWCEndpoint.registrationFingerprint(clientId: clientId)
        mutate(store) { file in
            guard var entry = file.entries[fp] else { return }
            switch entry.state {
            case .signInRequired:
                entry.state = .ok; entry.reason = nil; entry.retryAllowed = nil; entry.changedAt = now
                if entry.entryNotice == "queued" { entry.entryNotice = "dropped" }
            case .notAvailable: entry.retryAllowed = true
            default: return
            }
            file.entries[fp] = entry
        }
    }

    /// A user action (/provider, a settings change): `not_available` allows
    /// the next user turn one attempt.
    static func userAction(_ store: SIWCStore, clientId: String) {
        let fp = SIWCEndpoint.registrationFingerprint(clientId: clientId)
        mutate(store) { file in
            guard var entry = file.entries[fp], entry.state == .notAvailable, entry.retryAllowed != true else { return }
            entry.retryAllowed = true
            file.entries[fp] = entry
        }
    }

    // MARK: Delivery bookkeeping (D23)

    struct PendingNotice: Equatable {
        let clientId: String
        let episode: Int
        let recovery: Bool
        let text: String
        let state: SIWCPlanEntry.State
    }

    /// Notices THIS assistant owns and has not delivered, for `destination`.
    /// A notice queued for another destination (a replaced bot, a wipe) is
    /// dropped here, never sent through the new one.
    static func pendingNotices(_ store: SIWCStore, destination: String?) -> [PendingNotice] {
        guard let registrations = try? store.readRegistrations() else { return [] }
        var out: [PendingNotice] = []
        var drop: [(String, Bool)] = []
        let file = (try? read(store)) ?? SIWCPlanFile()
        for registration in registrations.registrations {
            let fp = SIWCEndpoint.registrationFingerprint(clientId: registration.clientId)
            guard let entry = file.entries[fp] else { continue }
            if entry.entryNotice == "queued", entry.openedBy == me, entry.state != .ok {
                if entry.destination == destination, destination != nil {
                    out.append(PendingNotice(clientId: registration.clientId, episode: entry.episode, recovery: false,
                                             text: entryText(entry.state, reason: entry.reason), state: entry.state))
                } else { drop.append((fp, false)) }
            }
            if entry.recoveryNotice == "queued", entry.recoveryClaimedBy == me, entry.state == .ok,
               entry.recoveryEpisode == entry.episode {
                if entry.recoveryDestination == destination, destination != nil {
                    out.append(PendingNotice(clientId: registration.clientId, episode: entry.episode, recovery: true,
                                             text: recoveryNotice, state: .ok))
                } else { drop.append((fp, true)) }
            }
        }
        if !drop.isEmpty {
            mutate(store) { file in
                for (fp, recovery) in drop {
                    guard var entry = file.entries[fp] else { continue }
                    if recovery { entry.recoveryNotice = "dropped" } else { entry.entryNotice = "dropped" }
                    file.entries[fp] = entry
                }
            }
        }
        return out
    }

    /// Mark a notice delivered only if it is still the current one (same
    /// episode, same kind still due). Returns false when it went stale.
    @discardableResult
    static func markDelivered(_ store: SIWCStore, _ notice: PendingNotice) -> Bool {
        let fp = SIWCEndpoint.registrationFingerprint(clientId: notice.clientId)
        return mutate(store) { file -> Bool in
            guard var entry = file.entries[fp], entry.episode == notice.episode else { return false }
            if notice.recovery {
                guard entry.recoveryNotice == "queued", entry.recoveryEpisode == notice.episode else { return false }
                entry.recoveryNotice = "delivered"
            } else {
                guard entry.entryNotice == "queued", entry.state == notice.state else { return false }
                entry.entryNotice = "delivered"
            }
            file.entries[fp] = entry
            return true
        } ?? false
    }

    /// Whether a notice is still due right before its send (a newer episode
    /// or a recovery since it was read drops it).
    static func stillDue(_ store: SIWCStore, _ notice: PendingNotice) -> Bool {
        guard let entry = entry(store, clientId: notice.clientId), entry.episode == notice.episode else { return false }
        return notice.recovery ? (entry.recoveryNotice == "queued" && entry.state == .ok)
                               : (entry.entryNotice == "queued" && entry.state == notice.state)
    }

    // MARK: Display

    /// The state of this assistant's selected SIWC registration, or nil when
    /// the route is not SIWC / nothing is selected.
    static func current(stored: [String: String] = KeychainHelper.loadSnapshot(),
                        store: SIWCStore = SIWCStore.resolved()) -> SIWCPlanEntry? {
        guard stored[ChatGPTRoute.routeKey] == "siwc", let fp = stored[ChatGPTRoute.siwcRegistrationKey] else { return nil }
        return (try? read(store))?.entries[fp] ?? SIWCPlanEntry()
    }

    /// One status line ("Using ChatGPT plan · Manage usage" or the state).
    static func statusText(_ entry: SIWCPlanEntry) -> String {
        switch entry.state {
        case .ok: return "Using ChatGPT plan · Manage usage: chatgpt.com/settings/usage"
        case .limitReached: return "ChatGPT plan: usage limit reached · Manage usage: chatgpt.com/settings/usage"
        case .signInRequired: return "ChatGPT plan: sign in again (/subscription login)"
        case .notAvailable: return "ChatGPT plan: not available for this account or workspace" + (entry.reason.map { " (\($0))" } ?? "")
        }
    }
}
