import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A verified sign-in, ready to be saved (§3.2 steps 5–8). Tokens are kept
/// in memory only until `SIWCStore.save`; nothing here is Codable.
struct SIWCSignInResult {
    let clientId: String
    let newRegistration: Bool
    /// nil for a verified identity-only grant (no plan-usage scope, no
    /// refresh token, §3.2 step 7 / P4a): saved with plan usage off.
    let tokens: SIWCTokens?
    let claims: SIWCJWT.Claims
}

enum SIWCSaveOutcome: Equatable {
    /// A new or inactive record was written (route-neutral; nothing moved).
    case saved(clientId: String, generation: String)
    /// The registration's record is in use: the new tokens wait as a staged
    /// replacement until activation (§3.9 R3).
    case staged(clientId: String, replacementId: String, generationToBe: String)
}

extension SIWCStore {
    /// Deviation 1 (Codex round 1): an explicit, workable recovery.
    static let missingKeyMessage = "Briglia can't verify its saved ChatGPT sign-ins (their integrity key is missing), so they stay unusable. Delete this store's chatgpt-siwc-registrations.json and subscription-siwc-auth.json, then sign in again. Nothing was changed."
    static let supersededMessage = "This ChatGPT sign-in was cancelled or superseded; start it again."
    static let differentAccountMessage = "This ChatGPT account is not the one saved for this sign-in. Nothing was changed; sign in with the same account or add a new sign-in."

    /// Token-free activation expectation (§3.9): the exact record state the
    /// activation was prepared from.
    struct ActivationExpectation: Equatable {
        var clientId: String
        var generation: String?
        var replacementId: String?
    }

    // MARK: Save (publication, route-neutral)

    /// Publication of a verified sign-in (§3.8 "Publication", §3.9 "Save a
    /// login"): under `chatgpt-share.lock` then this store's SIWC lock, the
    /// attempt's host reservation must still exist with the current host;
    /// the store's pending marker must still be this attempt. A new
    /// registration gets its entry and a record; a returning one must be the
    /// same verified `sub`. The active pointer is never moved here. A record
    /// in use (the store's active registration, or `inUseByCaller`) receives
    /// a staged replacement instead of new tokens.
    func save(_ result: SIWCSignInResult, pending: String, attemptId: String, hostFingerprint: String,
              hostPaths: SIWCHost.Paths, inUseByCaller: Bool = false, label: String? = nil,
              effect: SIWCEffectMark? = nil) async throws -> SIWCSaveOutcome {
        try await SIWCHost.withShareLockAsync(hostPaths) {
            try SIWCHost.validateReservationLocked(hostPaths, attemptId: attemptId, hostFingerprint: hostFingerprint, now: nowSeconds)
            let outcome: SIWCSaveOutcome = try await locked {
                var file = try readTokens() ?? SIWCTokenFile()
                guard pendingIsCurrent(file, pending) else { throw SIWCError(.local, Self.supersededMessage) }
                var registrations = try readRegistrations() ?? SIWCRegistrationsFile()
                let existing = registrations.registration(result.clientId)
                if result.newRegistration {
                    guard existing == nil else { throw SIWCError(.local, Self.supersededMessage) }
                } else {
                    guard let existing, existing.sub == result.claims.sub else {
                        throw SIWCError(.local, Self.differentAccountMessage)
                    }
                }
                if let tokens = result.tokens {
                    guard tokens.valid else { throw SIWCError(.local, "ChatGPT returned an invalid credential. Nothing was saved.") }
                }
                let planUsage = result.tokens?.planUsage ?? false
                let hasRecords = !(file.records.isEmpty)
                let key: SymmetricKeyBox
                if let k = try integrityKey(create: false) { key = SymmetricKeyBox(k) }
                else {
                    // A key missing while records exist is never re-created:
                    // those records would become "bound" under a new key.
                    guard !hasRecords else { throw SIWCError(.local, Self.missingKeyMessage) }
                    key = SymmetricKeyBox(try integrityKey(create: true)!)
                }
                let identity = Self.identity(key: key.key, sub: result.claims.sub, accountId: result.claims.accountId)
                if existing == nil {
                    registrations.registrations.append(SIWCRegistration(clientId: result.clientId, issuer: SIWCEndpoint.issuer,
                        sub: result.claims.sub, email: result.claims.email,
                        label: label ?? (result.claims.email ?? "ChatGPT"), planUsageEnabled: planUsage,
                        createdAt: nowSeconds, hostFingerprint: hostFingerprint))
                    // Harmless metadata first (an orphan entry after a crash
                    // has no tokens and changes no route).
                    try writeRegistrations(registrations)
                } else if let index = registrations.registrations.firstIndex(where: { $0.clientId == result.clientId }) {
                    // An identity-only grant never downgrades a record in use
                    // (refused below); otherwise the display flag follows.
                    if registrations.registrations[index].planUsageEnabled != planUsage,
                       result.tokens != nil || !(inUseByCaller || registrations.active == result.clientId) {
                        registrations.registrations[index].planUsageEnabled = planUsage
                        try writeRegistrations(registrations)
                    }
                }
                let inUse = inUseByCaller || registrations.active == result.clientId
                let outcome: SIWCSaveOutcome
                if var record = file.record(result.clientId) {
                    // An existing record must be intact to be extended: a
                    // tampered one is replaced only when it is not in use.
                    let intact = Self.bindingProblem(record, registration: registrations.registration(result.clientId), key: key.key) == nil
                    if inUse && result.tokens == nil {
                        throw SIWCError(.planUsageOff, "This sign-in didn't include plan usage, so the ChatGPT login in use was kept unchanged. Sign in again and allow plan usage.")
                    } else if inUse && intact, let newTokens = result.tokens {
                        if let older = record.staged { record.cleanup = (record.cleanup ?? []) + [older.tokens.refresh] }
                        let staged = SIWCStagedReplacement(replacementId: UUID().uuidString, tokens: newTokens, identity: identity,
                            hostFingerprint: hostFingerprint, generationToBe: UUID().uuidString)
                        record.staged = staged
                        outcome = .staged(clientId: result.clientId, replacementId: staged.replacementId, generationToBe: staged.generationToBe)
                    } else if inUse {
                        throw SIWCError(.local, "The ChatGPT sign-in record in use failed its integrity check; sign out first. Nothing was saved.")
                    } else {
                        var retired = record.cleanup ?? []
                        if let old = record.tokens?.refresh { retired.append(old) }
                        if let old = record.staged?.tokens.refresh { retired.append(old) }
                        if let old = record.pendingRotation?.tokens.refresh { retired.append(old) }
                        record = SIWCTokenRecord(clientId: result.clientId, generation: UUID().uuidString, tokens: result.tokens,
                                                 identity: identity, signedInBy: file.pendingLoginBy,
                                                 planUsageOff: result.tokens == nil ? true : nil)
                        record.cleanup = retired.isEmpty ? nil : Array(retired.suffix(64))
                        outcome = .saved(clientId: result.clientId, generation: record.generation)
                    }
                    record.lastEffect = effect
                    record.savedAt = nowSeconds
                    try Self.bind(&record, key: key.key)
                    file.update(result.clientId) { $0 = record }
                } else {
                    var record = SIWCTokenRecord(clientId: result.clientId, generation: UUID().uuidString, tokens: result.tokens,
                                                 identity: identity, signedInBy: file.pendingLoginBy,
                                                 planUsageOff: result.tokens == nil ? true : nil)
                    record.lastEffect = effect; record.savedAt = nowSeconds
                    try Self.bind(&record, key: key.key)
                    file.records.append(record)
                    outcome = .saved(clientId: result.clientId, generation: record.generation)
                }
                file.pendingLogin = nil; file.pendingLoginBy = nil; file.pendingExpiresAt = nil
                if let effect { file.lastAttempt = effect.attempt }
                try writeTokens(file)
                return outcome
            }
            try SIWCHost.releaseLocked(hostPaths, attemptId: attemptId)
            return outcome
        }
    }

    // MARK: Activation (token-free, D)

    /// Move the store's active pointer to a saved record and/or promote its
    /// staged replacement (new generation). Prepared from the post-publication
    /// state: `expect` must still describe the record exactly, or nothing
    /// changes ("changed after you saved it"). Returns the generation in use.
    func activate(_ expect: ActivationExpectation, effect: SIWCEffectMark? = nil) async throws -> String {
        try await locked { try activateLocked(expect, effect: effect) }
    }

    /// `activate` with this store's SIWC lock already held (the settings
    /// writer takes it in its lock order, §3.9 "Locks").
    func activateLocked(_ expect: ActivationExpectation, effect: SIWCEffectMark? = nil,
                        pointerEffect: SIWCEffectMark? = nil) throws -> String {
        let pointerMark = pointerEffect ?? effect
        do {
            guard var file = try readTokens(), var record = file.record(expect.clientId),
                  var registrations = try readRegistrations(), registrations.registration(expect.clientId) != nil else {
                throw SIWCError(.local, "That ChatGPT sign-in no longer exists; nothing was activated.")
            }
            guard let key = try integrityKey(create: false),
                  Self.bindingProblem(record, registration: registrations.registration(expect.clientId), key: key) == nil else {
                throw SIWCError(.signInRequired, SIWCError.signInMessage)
            }
            var promoted = false
            if let replacement = expect.replacementId {
                guard let staged = record.staged, staged.replacementId == replacement else {
                    throw SIWCError(.local, "The ChatGPT sign-in changed after you saved it; not applied.")
                }
                var cleanup = record.cleanup ?? []
                if let old = record.tokens?.refresh { cleanup.append(old) }
                if let old = record.pendingRotation?.tokens.refresh { cleanup.append(old) }
                record.tokens = staged.tokens
                record.identity = staged.identity
                record.generation = staged.generationToBe
                record.staged = nil
                record.requiresLogin = nil; record.invalidClient = nil
                record.pendingRotation = nil; record.refreshOp = nil; record.refreshRecovery = nil
                record.cleanup = cleanup.isEmpty ? nil : Array(cleanup.suffix(64))
                record.lastEffect = effect
                try Self.bind(&record, key: key)
                promoted = true
            } else {
                guard record.generation == expect.generation else {
                    throw SIWCError(.local, "The ChatGPT sign-in changed after you saved it; not applied.")
                }
            }
            guard usability(record, registration: registrations.registration(expect.clientId), key: key) == .usable else {
                throw SIWCError(.signInRequired, SIWCError.signInMessage)
            }
            if promoted {
                file.update(expect.clientId) { $0 = record }
                if let effect { file.lastAttempt = effect.attempt }
                try writeTokens(file)
            }
            if registrations.active != expect.clientId || pointerMark != nil {
                registrations.active = expect.clientId
                registrations.activeLastEffect = pointerMark
                if let pointerMark { registrations.lastAttempt = pointerMark.attempt }
                try writeRegistrations(registrations)
            }
            return record.generation
        }
    }

    // MARK: Sign-out (local tombstone; the caller fences and revokes)

    struct Tombstone: Equatable {
        let clientId: String
        let generation: String
        /// Every refresh token the record held (current, staged, checkpoint,
        /// cleanup) — to revoke outside every lock.
        let revoke: [String]
    }

    /// Write the tombstone generation for `clientId` durably (§3.6 / §3.9
    /// step 4). `expectedGeneration` (when given) must still be current:
    /// a newer sign-in wins and nothing is written. Registration entries are
    /// kept (D4).
    func tombstone(_ clientId: String, expectedGeneration: String? = nil, effect: SIWCEffectMark? = nil) async throws -> Tombstone {
        try await locked { try tombstoneLocked(clientId, expectedGeneration: expectedGeneration, effect: effect) }
    }

    func tombstoneLocked(_ clientId: String, expectedGeneration: String? = nil, effect: SIWCEffectMark? = nil) throws -> Tombstone {
        do {
            guard var file = try readTokens(), var record = file.record(clientId) else {
                throw SIWCError(.local, "No ChatGPT sign-in to sign out.")
            }
            if let expectedGeneration, record.generation != expectedGeneration {
                throw SIWCError(.local, "The ChatGPT sign-in changed meanwhile; nothing was signed out. Try again.")
            }
            let registrations = try readRegistrations()
            let key = try integrityKey(create: false)
            let wasBound = Self.bindingProblem(record, registration: registrations?.registration(clientId), key: key) == nil
            var revoke = record.cleanup ?? []
            if let t = record.tokens?.refresh { revoke.append(t) }
            if let t = record.staged?.tokens.refresh { revoke.append(t) }
            if let t = record.pendingRotation?.tokens.refresh { revoke.append(t) }
            record.tokens = nil; record.identity = nil; record.staged = nil
            record.requiresLogin = nil; record.pendingRotation = nil; record.refreshOp = nil; record.refreshRecovery = nil
            record.cleanup = nil
            record.generation = UUID().uuidString
            record.lastEffect = effect
            record.savedAt = nowSeconds
            if wasBound, let key { try Self.bind(&record, key: key) } else { record.binding = nil; record.bindingVersion = nil }
            file.update(clientId) { $0 = record }
            if let effect { file.lastAttempt = effect.attempt }
            try writeTokens(file)
            return Tombstone(clientId: clientId, generation: record.generation, revoke: revoke)
        }
    }

    /// Retire EVERY record of this store in one token-file replacement
    /// (own → shared, `/deleteuserdata` of an own store; §3.9 "Several
    /// registrations in one store change together"). Each record carries the
    /// same effect mark.
    func retireAll(effect: SIWCEffectMark? = nil) async throws -> [Tombstone] {
        try await locked { try retireAllLocked(effect: effect) }
    }

    func retireAllLocked(effect: SIWCEffectMark? = nil) throws -> [Tombstone] {
        do {
            guard var file = try readTokens() else { return [] }
            let registrations = try readRegistrations()
            let key = try integrityKey(create: false)
            var out: [Tombstone] = []
            for index in file.records.indices {
                var record = file.records[index]
                let wasBound = Self.bindingProblem(record, registration: registrations?.registration(record.clientId), key: key) == nil
                var revoke = record.cleanup ?? []
                if let t = record.tokens?.refresh { revoke.append(t) }
                if let t = record.staged?.tokens.refresh { revoke.append(t) }
                if let t = record.pendingRotation?.tokens.refresh { revoke.append(t) }
                record.tokens = nil; record.identity = nil; record.staged = nil; record.requiresLogin = nil
                record.pendingRotation = nil; record.refreshOp = nil; record.refreshRecovery = nil; record.cleanup = nil
                record.generation = UUID().uuidString
                record.lastEffect = effect
                record.savedAt = nowSeconds
                if wasBound, let key { try Self.bind(&record, key: key) } else { record.binding = nil; record.bindingVersion = nil }
                file.records[index] = record
                out.append(Tombstone(clientId: record.clientId, generation: record.generation, revoke: revoke))
            }
            file.pendingLogin = nil; file.pendingLoginBy = nil; file.pendingExpiresAt = nil
            if let effect { file.lastAttempt = effect.attempt }
            try writeTokens(file)
            return out
        }
    }

    /// Mark a record that the server proved unusable (terminal refresh error,
    /// second 401, revoked session): `requiresLogin`, tokens moved to the
    /// cleanup list. A bound record stays bound; an unbound one is not
    /// repaired. Only when `generation` (and `rejectedAccess`, when given)
    /// still match.
    func requireLogin(_ clientId: String, generation: String, rejectedAccess: String? = nil, invalidClient: Bool = false) async throws {
        try await locked {
            guard var file = try readTokens(), var record = file.record(clientId), record.generation == generation else { return }
            if let rejectedAccess, record.tokens?.access != rejectedAccess { return }
            let registrations = try readRegistrations()
            let key = try integrityKey(create: false)
            let wasBound = Self.bindingProblem(record, registration: registrations?.registration(clientId), key: key) == nil
            if invalidClient { record.invalidClient = true }
            else {
                record.requiresLogin = true
                if let refresh = record.tokens?.refresh { record.cleanup = Array(((record.cleanup ?? []) + [refresh]).suffix(64)) }
                record.tokens = nil
            }
            if wasBound, let key { try Self.bind(&record, key: key) }
            file.update(clientId) { $0 = record }
            try writeTokens(file)
        }
    }

    /// `/deleteuserdata` after every record was retired: remove this store's
    /// SIWC token, registrations and key files (checked). The lock sidecar
    /// stays (harmless, like the legacy one).
    func removeFiles() throws -> [String] {
        var failed: [String] = []
        for url in [tokenFile, registrationsFile, keyFile] {
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch { failed.append(url.lastPathComponent) }
        }
        try? PrivateStorage.fsyncDirectory(directory.path)
        return failed
    }
}

/// `SymmetricKey` in a value box (keeps the call sites readable).
struct SymmetricKeyBox {
    let key: SymmetricKey
    init(_ key: SymmetricKey) { self.key = key }
}
