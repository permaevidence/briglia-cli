import Foundation

// Sign in with ChatGPT through the single settings writer (SIWC plan §3.9).
//
// - Save a login: route-neutral; the token-carrying request lives in memory
//   only and is never a `PreparedChange` (so it can never be staged,
//   journaled or replied with). Journaled with per-record evidence.
// - Activate: a token-free `PreparedChange.siwc` (D): pointer, binding,
//   promotion of a staged replacement, the selection keys. Applied at the D
//   barrier or staged until idle.
// - Cancel a pending sign-in: S.
// - Sign out: its own admitted operation that never waits for idle: fence
//   this process's sends, cancel and drain that login's in-flight requests,
//   then the durable tombstone, then the remote revoke outside every lock.

/// The token-free activation operation (§3.9 "Type boundary"): this type has
/// no credential field. Everything that identifies the exact record state the
/// activation was prepared from is here.
struct SIWCSettingsOp: Codable, Equatable {
    enum Kind: String, Codable { case activate }
    var kind: Kind = .activate
    /// The exact SIWC store directory, resolved at preparation.
    var store: String
    var clientId: String
    var registrationFingerprint: String
    var identityFingerprint: String
    /// The record generation it was prepared from (no promotion), or nil.
    var expectGeneration: String?
    /// The staged replacement it promotes, or nil.
    var replacementId: String?
    /// The generation in use after activation (the binding written).
    var projectedGeneration: String
}

/// The writer refuses to stage, journal or reply with any change that could
/// carry an SIWC credential (§3.9 "Type boundary").
enum SIWCTypeBoundary {
    static let message = "This ChatGPT change would carry a sign-in credential into saved settings; nothing was saved."

    /// Every token string held in `directories`' SIWC stores (current,
    /// staged, checkpoint, cleanup).
    static func tokens(in directories: [URL]) -> [String] {
        Array(CredentialCatalog.siwcRedactionValues(directories).values).filter { $0.utf8.count >= 16 }
    }

    static func violation(_ change: PreparedChange) -> String? {
        guard let op = change.siwc else { return nil }
        if change.subscription != nil { return "one settings change cannot combine a Sign in with ChatGPT activation with another ChatGPT login operation" }
        for key in change.writes.keys where SettingsKeyRoles.role(key) == .credential { return message }
        var directories = SubscriptionSharing.protectedStoreDirectories()
        directories.append(URL(fileURLWithPath: op.store, isDirectory: true))
        guard let encoded = try? change.encoded(), let text = String(data: encoded, encoding: .utf8) else { return message }
        for token in tokens(in: directories) where text.contains(token) { return message }
        return nil
    }
}

/// The write-free decision and the durable step of one activation, taken
/// inside the writer's locks (SIWC lock held, secrets lock held).
struct SIWCActivationPlan {
    let store: SIWCStore
    let op: SIWCSettingsOp
    let attempt: String
    let factsOld: SIWCRouteFacts
    let factsNew: SIWCRouteFacts
    let effects: [SIWCJournalEffect]
    let promote: SIWCJournalEffect?
    let pointer: SIWCJournalEffect

    static func decide(_ op: SIWCSettingsOp, attempt: String) throws -> SIWCActivationPlan {
        let store = SIWCStore(directory: URL(fileURLWithPath: op.store, isDirectory: true))
        let tokens = try store.readTokens(), registrations = try store.readRegistrations()
        guard let registration = registrations?.registration(op.clientId), let record = tokens?.record(op.clientId),
              SIWCEndpoint.registrationFingerprint(clientId: op.clientId) == op.registrationFingerprint,
              SIWCEndpoint.identityFingerprint(clientId: op.clientId, sub: registration.sub) == op.identityFingerprint else {
            throw SIWCError(.local, "That ChatGPT sign-in no longer exists; nothing was activated.")
        }
        let key = try store.integrityKey(create: false)
        if let replacement = op.replacementId {
            guard let staged = record.staged, staged.replacementId == replacement, staged.generationToBe == op.projectedGeneration,
                  SIWCStore.bindingProblem(record, registration: registration, key: key) == nil, staged.tokens.planUsage else {
                throw SIWCError(.local, "The ChatGPT sign-in changed after you saved it; not applied.")
            }
        } else {
            guard record.generation == op.expectGeneration, op.projectedGeneration == record.generation,
                  store.usability(record, registration: registration, key: key) == .usable else {
                throw SIWCError(.local, "The ChatGPT sign-in changed after you saved it; not applied.")
            }
        }
        let fp = op.registrationFingerprint
        let factsOld = SIWCRouteFacts(tokens: tokens, registrations: registrations, clientId: op.clientId, store: store)
        let factsNew = SIWCRouteFacts(present: true, usable: true, planUsage: true, registrationFingerprint: fp,
                                      identityFingerprint: op.identityFingerprint, generation: op.projectedGeneration,
                                      activeRegistration: fp)
        let promote = op.replacementId.map { _ in
            SIWCJournalEffect(effectId: UUID().uuidString, kind: .promote, storePath: op.store, file: "tokens",
                              targets: [fp], oldEvidence: [fp: .record(record)])
        }
        let pointer = SIWCJournalEffect(effectId: UUID().uuidString, kind: .pointer, storePath: op.store, file: "registrations",
                                        targets: ["store"], oldEvidence: ["store": .pointer(registrations)])
        return SIWCActivationPlan(store: store, op: op, attempt: attempt, factsOld: factsOld, factsNew: factsNew,
                                  effects: [promote, pointer].compactMap { $0 }, promote: promote, pointer: pointer)
    }

    /// The durable SIWC step (after the journal intent, before secrets).
    func apply() throws {
        _ = try store.activateLocked(SIWCStore.ActivationExpectation(clientId: op.clientId, generation: op.expectGeneration,
                                                                      replacementId: op.replacementId),
                                     effect: promote?.mark(attempt: attempt) ?? pointer.mark(attempt: attempt),
                                     pointerEffect: pointer.mark(attempt: attempt))
    }
}

enum SIWCSettings {
    static let label = "ChatGPT (Sign in with ChatGPT)"

    /// Prepare the token-free activation of a saved login (§3.9 "Activate"):
    /// from the POST-publication state, with expectations on that exact
    /// record (its generation, or its staged replacement). `clientId` nil =
    /// the store's active registration.
    static func prepareActivation(store: SIWCStore, clientId: String? = nil, model: String, effort: String?,
                                  textOnly: Bool, origin: String, acceptPending: Bool) throws -> PreparedChange {
        let epoch = try ReplacementEpoch.read()
        let base = try KeychainHelper.strictSnapshot()
        let tokens = try store.readTokens(), registrations = try store.readRegistrations()
        guard let clientId = clientId ?? registrations?.active, let registration = registrations?.registration(clientId),
              let record = tokens?.record(clientId) else {
            throw SIWCError(.signInRequired, SIWCError.signInMessage)
        }
        var op = SIWCSettingsOp(store: store.directory.standardizedFileURL.path, clientId: clientId,
                                registrationFingerprint: SIWCEndpoint.registrationFingerprint(clientId: clientId),
                                identityFingerprint: SIWCEndpoint.identityFingerprint(clientId: clientId, sub: registration.sub),
                                expectGeneration: nil, replacementId: nil, projectedGeneration: record.generation)
        if let staged = record.staged {
            op.replacementId = staged.replacementId
            op.projectedGeneration = staged.generationToBe
        } else {
            guard store.usability(record, registration: registration, key: try store.integrityKey(create: false)) == .usable else {
                throw SIWCError(.signInRequired, SIWCError.signInMessage)
            }
            op.expectGeneration = record.generation
        }
        let delta = SIWCSelection.activationDelta(SIWCSelection.Choice(clientId: clientId, sub: registration.sub,
            generation: op.projectedGeneration, model: model, effort: effort, textOnly: textOnly))
        var change = PreparedChange(origin: origin, label: label, epoch: epoch)
        for (key, value) in delta {
            change.expected[key] = SettingsDigest.of(base[key])
            if let value { if base[key] != value { change.writes[key] = value } }
            else if base[key] != nil { change.deletes.append(key) }
        }
        change.deletes.sort()
        if change.writes.isEmpty && change.deletes.isEmpty { change.validateOnly = true }
        change.siwc = op
        change.category = "ai"
        change.acceptPending = acceptPending
        change.reply = PreparedChange.jsonText(["schema": SetupAPICore.schemaVersion, "ok": true])
        return change
    }
}

// MARK: - Writer entry points

/// The in-memory save request (never encoded, never staged).
struct SIWCSaveRequest {
    let result: SIWCSignInResult
    let attempt: SIWCAttempt
    let signIn: SIWCSignIn
    /// `ReplacementEpoch` read when the attempt started (a wipe or import
    /// since then refuses the publication).
    let epoch: Int
}

enum SIWCSaveCommit: Equatable {
    case saved(SIWCSaveOutcome)
    case refused(String)
    case failed(String)
}

enum SIWCLogoutOutcome: Equatable {
    /// Durable tombstone; `remoteConfirmed` = the server revoke answered.
    case signedOut(remoteConfirmed: Bool)
    /// Validation refused: nothing changed, nothing was interrupted.
    case refused(String)
    /// The fence and drain ran but the tombstone is not durable.
    case partial(String)

    static let unconfirmedMessage = "Signed out on this computer; remote sign-out not confirmed. Disconnect Briglia in ChatGPT Settings → Usage (chatgpt.com/settings/usage)."
    static let partialMessage = "Running ChatGPT work was stopped, but the sign-out was not saved. Try again. Until then this assistant sends nothing with that login; after a restart the saved login would be usable again, and other assistants were not stopped by this."
    static let othersMessage = "Signed out. Other assistants stop before their next ChatGPT request; one already under way may finish."

    var message: String {
        switch self {
        case .signedOut(let confirmed): return confirmed ? "Signed out of ChatGPT (Sign in with ChatGPT)." : Self.unconfirmedMessage
        case .refused(let why): return why
        case .partial(let why): return why
        }
    }
}

extension SettingsWriter {
    /// Selftest seams.
    nonisolated(unsafe) static var siwcAfterFenceForTesting: (() async -> Void)?
    nonisolated(unsafe) static var siwcBeforeTombstoneForTesting: (() throws -> Void)?

    private func siwcJournal(_ attempt: String, label: String, kind: String, effects: [SIWCJournalEffect]) throws {
        let record = SettingsPendingStore.Attempt(attempt: attempt, operation: "commit", category: "ai", ticket: nil,
            clientRequestId: attempt, label: label, authEffect: false, authKind: kind, storePath: nil,
            oldEvidence: nil, projectedEvidence: nil, secretsKeys: [], steps: ["intent"], direction: nil,
            retirement: nil, startedAt: Date(), siwcEffects: effects)
        try SettingsPendingStore.update { $0.attempts[attempt] = record }
    }

    /// Save a verified login (route-neutral). `inUseByCaller` is decided
    /// here from this assistant's own binding, never by the caller.
    func commitSIWCSave(_ request: SIWCSaveRequest) async -> SIWCSaveCommit {
        func refuse(_ why: String) async -> SIWCSaveCommit {
            await request.signIn.cancel(request.attempt)
            if let refresh = request.result.tokens?.refresh {
                await request.signIn.revokeBestEffort(refresh, clientId: request.result.clientId)
            }
            return .refused(why)
        }
        guard let token = await gate.acquire() else {
            return await refuse(gate.admissionClosedReason ?? "Briglia is busy; try again in a moment.")
        }
        defer { gate.release(token); kickAfterSIWC() }
        if let why = host?.admissionRefusal() { return await refuse(why) }
        guard (try? ReplacementEpoch.read()) == request.epoch else { return await refuse(Self.epochMessage) }
        let store = request.signIn.store
        let fp = SIWCEndpoint.registrationFingerprint(clientId: request.result.clientId)
        let stored = (try? KeychainHelper.strictSnapshot()) ?? [:]
        let inUse = stored[ChatGPTRoute.routeKey] == "siwc" && stored[ChatGPTRoute.siwcRegistrationKey] == fp
        let old: SIWCTokenRecord?
        do { old = try store.readTokens()?.record(request.result.clientId) } catch {
            return await refuse((error as? SIWCError)?.message ?? error.localizedDescription)
        }
        let attempt = UUID().uuidString
        let effect = SIWCJournalEffect(effectId: UUID().uuidString, kind: .save, storePath: store.directory.standardizedFileURL.path,
                                       file: "tokens", targets: [fp], oldEvidence: [fp: .record(old)])
        do { try siwcJournal(attempt, label: "ChatGPT sign-in", kind: "siwc-save", effects: [effect]) } catch {
            return await refuse("The ChatGPT sign-in couldn't be recorded (\(error)); nothing was saved.")
        }
        gate.enterDurablePhase(token)
        do {
            let outcome = try await request.signIn.save(request.result, attempt: request.attempt, inUseByCaller: inUse,
                                                        effect: effect.mark(attempt: attempt))
            SettingsSupersede.subscriptionChanged(store: store.directory.path)
            Self.finishAttempt(attempt, change: PreparedChange(id: attempt, origin: "siwc", label: "ChatGPT sign-in", epoch: request.epoch),
                               pending: nil, state: "applied", message: nil)
            return .saved(outcome)
        } catch {
            let why = (error as? SIWCError)?.message ?? error.localizedDescription
            Self.finishAttempt(attempt, change: PreparedChange(id: attempt, origin: "siwc", label: "ChatGPT sign-in", epoch: request.epoch),
                               pending: nil, state: "failed", message: why)
            return .failed(why)
        }
    }

    /// Cancel this profile's pending SIWC sign-in in `store` (S).
    func commitSIWCCancel(store: SIWCStore, profile: String = AssistantProfile.selectedName) async -> SettingsCommitResult {
        guard let token = await gate.acquire() else { return .refused(gate.admissionClosedReason ?? "Briglia is busy; try again in a moment.") }
        defer { gate.release(token); kickAfterSIWC() }
        if let why = host?.admissionRefusal() { return .refused(why) }
        let file: SIWCTokenFile?
        do { file = try store.readTokens() } catch { return .refused((error as? SIWCError)?.message ?? error.localizedDescription) }
        guard file?.pendingLogin != nil else { return SettingsCommitResult(state: .applied, message: "No pending ChatGPT sign-in.") }
        let attempt = UUID().uuidString
        let effect = SIWCJournalEffect(effectId: UUID().uuidString, kind: .cancel, storePath: store.directory.standardizedFileURL.path,
                                       file: "tokens", targets: ["store"], oldEvidence: ["store": .pendingMarker(file)])
        do { try siwcJournal(attempt, label: "ChatGPT sign-in", kind: "siwc-cancel", effects: [effect]) } catch {
            return .refused("The cancellation couldn't be recorded (\(error)); nothing changed.")
        }
        gate.enterDurablePhase(token)
        let change = PreparedChange(id: attempt, origin: "siwc", label: "ChatGPT sign-in", epoch: 0)
        do {
            let outcome = try await store.locked { try store.cancelOwnedPendingLocked(profile: profile) }
            Self.finishAttempt(attempt, change: change, pending: nil, state: outcome == .foreign ? "failed" : "applied",
                               message: outcome == .foreign ? SIWCStore.foreignPendingMessage : nil)
            if outcome == .foreign { return .refused(SIWCStore.foreignPendingMessage) }
            await SIWCActivity.shared.cancelOwned(store: store.directory)
            SettingsSupersede.subscriptionChanged(store: store.directory.path)
            return SettingsCommitResult(state: .applied, message: outcome == .cancelled ? "ChatGPT sign-in cancelled." : "No pending ChatGPT sign-in.")
        } catch {
            let why = (error as? SIWCError)?.message ?? error.localizedDescription
            Self.finishAttempt(attempt, change: change, pending: nil, state: "failed", message: why)
            return SettingsCommitResult(state: .error, message: why)
        }
    }

    /// The interrupting SIWC sign-out (§3.9 R2, steps 1–6). The handling
    /// follows from this entry point (its validated kind), never from a
    /// caller flag. `clientId` nil = the store's active registration.
    func commitSIWCLogout(store: SIWCStore, clientId: String? = nil, expectedGeneration: String? = nil,
                          revoke: @escaping (SIWCStore.Tombstone) async -> Bool,
                          drainTimeout: TimeInterval = 10) async -> SIWCLogoutOutcome {
        guard let token = await gate.acquire() else {
            return .refused(gate.admissionClosedReason ?? "Briglia is busy; try again in a moment. Nothing changed.")
        }
        var released = false
        func release() { if !released { released = true; gate.release(token); kickAfterSIWC() } }
        defer { release() }
        // 1. Validate, write-free.
        if let why = host?.admissionRefusal() { return .refused(why) }
        let target: (clientId: String, generation: String)
        do {
            target = try await store.locked { () throws -> (String, String) in
                guard let registrations = try store.readRegistrations(), let id = clientId ?? registrations.active,
                      registrations.registration(id) != nil, let record = try store.readTokens()?.record(id) else {
                    throw SIWCError(.local, "No ChatGPT sign-in to sign out. Nothing changed.")
                }
                if let expectedGeneration, record.generation != expectedGeneration {
                    throw SIWCError(.local, "The ChatGPT sign-in changed meanwhile; nothing was signed out. Try again.")
                }
                return (id, record.generation)
            }
        } catch {
            return .refused((error as? SIWCError)?.message ?? "\(error.localizedDescription) Nothing changed.")
        }
        // 2. Fence this process's sends, in the same step as the gate phase.
        let key = SIWCFence.key(store: store.directory, clientId: target.clientId)
        gate.enterInterruptingPhase(token)
        SIWCFence.shared.fenceAndBump(key)
        await Self.siwcAfterFenceForTesting?()
        // 3. Cancel and drain that login's in-flight requests, outside every lock.
        SIWCFence.shared.cancelAll(key)
        let deadline = ProcessInfo.processInfo.systemUptime + drainTimeout
        while SIWCFence.shared.inflightCount(key) > 0, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // 4. Durable step: revalidate, journal, tombstone. A refusal now is partial.
        if let why = host?.admissionRefusal() ?? gate.admissionClosedReason {
            return .partial(SIWCLogoutOutcome.partialMessage + " (\(why))")
        }
        let attempt = UUID().uuidString
        let fp = SIWCEndpoint.registrationFingerprint(clientId: target.clientId)
        let oldRecord = (try? store.readTokens())?.record(target.clientId)
        let effect = SIWCJournalEffect(effectId: UUID().uuidString, kind: .tombstone, storePath: store.directory.standardizedFileURL.path,
                                       file: "tokens", targets: [fp], oldEvidence: [fp: .record(oldRecord)])
        let change = PreparedChange(id: attempt, origin: "siwc", label: "ChatGPT sign-out", epoch: 0)
        do { try siwcJournal(attempt, label: "ChatGPT sign-out", kind: "siwc-logout", effects: [effect]) } catch {
            return .partial(SIWCLogoutOutcome.partialMessage)
        }
        gate.enterDurablePhase(token)
        let tombstone: SIWCStore.Tombstone
        do {
            try Self.siwcBeforeTombstoneForTesting?()
            tombstone = try await store.locked {
                try store.tombstoneLocked(target.clientId, expectedGeneration: target.generation, effect: effect.mark(attempt: attempt))
            }
        } catch {
            Self.finishAttempt(attempt, change: change, pending: nil, state: "partial", message: SIWCLogoutOutcome.partialMessage)
            return .partial(SIWCLogoutOutcome.partialMessage)
        }
        SettingsSupersede.subscriptionChanged(store: store.directory.path)
        Self.finishAttempt(attempt, change: change, pending: nil, state: "applied", message: nil)
        SIWCFence.shared.unfence(key)
        // 5–6. Remote revoke outside every lock, after the token is released.
        release()
        SIWCActivity.shared.beginRevoke()
        let confirmed = await revoke(tombstone)
        SIWCActivity.shared.endRevoke()
        return .signedOut(remoteConfirmed: confirmed)
    }

    private func kickAfterSIWC() {
        if let host = host as? SettingsApplyKicking { host.kickSettingsApply() }
    }
}
