import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// What one SIWC refresh returned (verified by the caller's refresh closure:
/// token shape and, when present, the ID token's signature and audience).
struct SIWCRefreshed {
    let tokens: SIWCTokens
    let claims: SIWCJWT.Claims?
}

extension SIWCStore {
    static let refreshExhaustedMessage = "ChatGPT sign-in may need to be repeated: the login refresh did not complete and its one recovery attempt is used up. Sign in again. No API fallback was attempted."
    static let accountChangedMessage = "A ChatGPT refresh returned another account; sign in again explicitly."
    static let refreshNotSavedMessage = "ChatGPT sign-in may need to be repeated: the refreshed login could not be saved. Briglia will try to recover it on the next request."

    enum RefreshDisposition { case terminal, invalidClient, notSent, ambiguous }

    static func disposition(_ error: Error) -> RefreshDisposition {
        if let failure = error as? SIWCError {
            if failure.kind == .signInRequired { return .terminal }
            if failure.kind == .invalidClient { return .invalidClient }
        }
        if error is AuthBudgetExhausted || error is SendBudgetExhausted { return .notSent }
        return .ambiguous
    }

    /// Refresh-and-settle for one SIWC record (§3.5, §7, §7.1), the legacy
    /// operation re-applied: a detached settle owns the store's SIWC lock from
    /// send to durable write; a cancelled caller stops waiting and never uses
    /// the result. An unusable record (binding, identity, sign-out, plan
    /// usage) is refused BEFORE any token-endpoint call.
    func credential(clientId: String, generation: String, rejectedAccess: String? = nil,
                    refresh: @escaping (String) async throws -> SIWCRefreshed) async throws -> SIWCTokens {
        try Task.checkCancellation()
        let caller = SubscriptionRefreshCaller.SIWC()
        let store = self
        Task.detached {
            do { caller.finish(.success(try await store.settle(clientId: clientId, generation: generation,
                rejectedAccess: rejectedAccess, caller: caller, refresh: refresh))) }
            catch { caller.finish(.failure(error)) }
        }
        let outcome = await withTaskCancellationHandler { await caller.wait() } onCancel: { caller.cancel() }
        try Task.checkCancellation()
        return try outcome.get()
    }

    /// The canonical bound state of a record (binding included): what was
    /// sent must still be exactly what is on disk before any settlement
    /// write (Codex round 1 R1).
    static func boundState(_ record: SIWCTokenRecord) -> Data? {
        var bound = record.unboundCleared
        bound.binding = record.binding
        return try? encode(bound)
    }

    private func settle(clientId: String, generation: String, rejectedAccess: String?,
                        caller: SubscriptionRefreshCaller.SIWC,
                        refresh: (String) async throws -> SIWCRefreshed) async throws -> SIWCTokens {
        try await locked {
            guard var file = try readTokens(), var record = file.record(clientId), record.generation == generation,
                  let registration = try readRegistrations()?.registration(clientId) else {
                throw SIWCError(.signInRequired, "ChatGPT login changed or ended. Sign in again.")
            }
            let key = try integrityKey(create: false)
            // §3.5 (v2.9): never refresh a record that fails its check.
            switch usability(record, registration: registration, key: key) {
            case .usable: break
            case .planUsageOff: throw SIWCError(.planUsageOff, SIWCError.planUsageOffMessage)
            case .invalidClient: throw SIWCError(.invalidClient, SIWCError.invalidClientMessage)
            case .signInRequired: throw SIWCError(.signInRequired, SIWCError.signInMessage)
            }
            guard let key, var old = record.tokens, let oldIdentity = record.identity else {
                throw SIWCError(.signInRequired, SIWCError.signInMessage)
            }
            let registrationSubKey = Self.mac(key, "siwc-sub", Data(registration.sub.utf8))
            // The record was verified bound above, so every write below may
            // rebind it (the refresh records are bound fields, R7).
            func save() throws { try Self.bind(&record, key: key); file.update(clientId) { $0 = record }; try writeTokens(file) }
            func trySave() { try? save() }
            /// The acceptance checks of a token set for this record (R2): its own
            /// verified identity is the registration's subject, the set is
            /// valid, and plan usage was not lost.
            func acceptable(_ tokens: SIWCTokens, _ identity: SIWCIdentity) -> Bool {
                identity.subKey == registrationSubKey && identity.subKey == oldIdentity.subKey
                    && tokens.valid && (tokens.planUsage || !old.planUsage)
            }
            // Disk first (§7 step 4 / §7.1 step 3): promote a checkpoint bound
            // to this client, generation and refresh token, re-applying every
            // acceptance check. Wrong MAC or unrelated → discarded (its refresh
            // token kept for revocation only). Proven for this token but not
            // acceptable → the rotation happened for the wrong account or lost
            // plan usage: blocked until an explicit sign-in.
            if let pending = record.pendingRotation {
                record.pendingRotation = nil
                let macOK = (try? Self.rotationMAC(key: key, clientId: clientId, pending)).map { SIWCJWT.constantTimeEqual($0, pending.mac) } ?? false
                if macOK, pending.generation == generation, pending.replaces == SubscriptionRefreshFingerprint.of(old.refresh) {
                    guard acceptable(pending.tokens, pending.identity) else {
                        record.cleanup = Array(((record.cleanup ?? []) + [pending.tokens.refresh]).suffix(64))
                        record.refreshOp = nil
                        record.requiresLogin = true
                        trySave()
                        throw SIWCError(.signInRequired, Self.accountChangedMessage)
                    }
                    record.tokens = pending.tokens
                    record.identity = pending.identity
                    record.refreshOp = nil; record.refreshRecovery = nil
                    old = pending.tokens
                } else {
                    record.cleanup = Array(((record.cleanup ?? []) + [pending.tokens.refresh]).suffix(64))
                }
                try save()
            }
            let now = nowSeconds
            let due = old.expiresAt - Int(SIWCEndpoint.refreshMargin) <= now
            let earliestOK = (old.earliestRefreshAt ?? 0) <= now
            let rejected = rejectedAccess != nil && rejectedAccess == old.access
            // Never before earliest_refresh_at; the one documented exception is
            // an access token the server just rejected (401).
            if !rejected && (!due || !earliestOK) { return old }
            let fingerprint = SubscriptionRefreshFingerprint.of(old.refresh)
            if let recovery = record.refreshRecovery, recovery.generation == generation, recovery.tokenFingerprint == fingerprint {
                throw SIWCError(.signInRequired, Self.refreshExhaustedMessage)
            }
            let recovering = record.refreshOp.map { $0.generation == generation && $0.tokenFingerprint == fingerprint } ?? false
            if caller.cancelled { throw CancellationError() }
            let priorOp = record.refreshOp, priorRecovery = record.refreshRecovery
            if recovering { record.refreshRecovery = SubscriptionRefreshRecovery(tokenFingerprint: fingerprint, generation: generation, state: "reserved") }
            record.refreshOp = SIWCRefreshOp(opId: UUID().uuidString, tokenFingerprint: fingerprint, generation: generation,
                                             startedAt: nowSeconds, state: "sending")
            try save()
            if caller.cancelled {
                record.refreshOp = priorOp; record.refreshRecovery = priorRecovery
                trySave()
                throw CancellationError()
            }
            // What was sent: the exact bound state now on disk.
            guard let sent = Self.boundState(record) else { throw SIWCError(.local, "ChatGPT sign-in state could not be encoded") }
            /// Re-read the record before ANY settlement write (R1): it must
            /// still be bound and byte-identical (bound fields and binding) to
            /// what was sent. A read failure or a mismatch is never equality.
            func reloadUnchanged() -> Bool {
                guard let diskFile = try? readTokens(), let disk = diskFile.record(clientId),
                      let diskRegistration = (try? readRegistrations())??.registration(clientId),
                      Self.bindingProblem(disk, registration: diskRegistration, key: key) == nil,
                      Self.boundState(disk) == sent else { return false }
                // Continue from the current file (keeps unrelated records and
                // unbound fields written meanwhile), never a stale snapshot.
                file = diskFile; record = disk
                return true
            }
            /// A changed record keeps received tokens for revocation only,
            /// written into the CURRENT file without touching anything else.
            func quarantine(_ refreshToken: String?) {
                guard let refreshToken, var current = try? readTokens(), current.record(clientId) != nil else { return }
                current.update(clientId) { $0.cleanup = Array((($0.cleanup ?? []) + [refreshToken]).suffix(64)) }
                try? writeTokens(current)
            }
            let updated: SIWCRefreshed
            do { updated = try await refresh(old.refresh) }
            catch {
                guard reloadUnchanged() else { throw SIWCError(.signInRequired, SIWCError.signInMessage) }
                switch Self.disposition(error) {
                case .terminal, .invalidClient:
                    if Self.disposition(error) == .invalidClient { record.invalidClient = true }
                    else {
                        record.requiresLogin = true
                        record.cleanup = Array(((record.cleanup ?? []) + [old.refresh]).suffix(64))
                        record.tokens = nil
                    }
                    record.refreshOp = nil
                    trySave()
                    throw error
                case .notSent:
                    record.refreshOp = priorOp; record.refreshRecovery = priorRecovery
                    trySave()
                    throw error
                case .ambiguous:
                    record.refreshOp?.state = "ambiguous"
                    if recovering { record.refreshRecovery?.state = "exhausted" }
                    trySave()
                    if recovering { throw SIWCError(.signInRequired, Self.refreshExhaustedMessage) }
                    throw error
                }
            }
            // HTTP 200. Verify the record first (R1), then checkpoint with the
            // identity verified for THESE tokens (R2), then accept or block.
            guard reloadUnchanged() else {
                quarantine(updated.tokens.refresh)
                throw SIWCError(.signInRequired, SIWCError.signInMessage)
            }
            let newIdentity = updated.claims.map { Self.identity(key: key, sub: $0.sub, accountId: $0.accountId) } ?? oldIdentity
            var rotation = SIWCPendingRotation(generation: generation, replaces: fingerprint, tokens: updated.tokens,
                                               identity: newIdentity, mac: String(repeating: "0", count: 64))
            rotation.mac = try Self.rotationMAC(key: key, clientId: clientId, rotation)
            record.pendingRotation = rotation
            trySave()
            guard acceptable(updated.tokens, newIdentity) else {
                record.pendingRotation = nil
                record.refreshOp = nil
                record.requiresLogin = true
                record.cleanup = Array(((record.cleanup ?? []) + [updated.tokens.refresh]).suffix(64))
                trySave()
                throw SIWCError(.signInRequired, Self.accountChangedMessage)
            }
            record.tokens = updated.tokens
            record.identity = newIdentity
            record.pendingRotation = nil; record.refreshOp = nil; record.refreshRecovery = nil
            do { try save() } catch { throw SIWCError(.transient, Self.refreshNotSavedMessage) }
            return updated.tokens
        }
    }
}

extension SubscriptionRefreshCaller {
    /// The same cancel-aware waiter for SIWC token sets.
    final class SIWC: @unchecked Sendable {
        typealias Outcome = Result<SIWCTokens, Error>
        private let lock = NSLock()
        private var isCancelled = false
        private var outcome: Outcome?
        private var continuation: CheckedContinuation<Outcome, Never>?
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }
        func cancel() {
            lock.lock(); isCancelled = true
            if outcome == nil { outcome = .failure(CancellationError()) }
            let waiting = continuation; continuation = nil; let result = outcome!
            lock.unlock()
            waiting?.resume(returning: result)
        }
        func finish(_ result: Outcome) {
            lock.lock()
            if outcome == nil { outcome = result }
            let waiting = continuation; continuation = nil; let delivered = outcome!
            lock.unlock()
            waiting?.resume(returning: delivered)
        }
        func wait() async -> Outcome {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let outcome { lock.unlock(); continuation.resume(returning: outcome); return }
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
