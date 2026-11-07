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
            func save() throws { file.update(clientId) { $0 = record }; try writeTokens(file) }
            // Disk first (§7 step 4 / §7.1 step 3): promote a checkpoint bound
            // to this generation and this refresh token. A checkpoint whose
            // MAC fails, or that is unrelated, is discarded (never promoted).
            if let pending = record.pendingRotation {
                record.pendingRotation = nil
                let macOK = (try? Self.rotationMAC(key: key, pending)).map { SIWCJWT.constantTimeEqual($0, pending.mac) } ?? false
                if macOK, pending.generation == generation, pending.replaces == SubscriptionRefreshFingerprint.of(old.refresh) {
                    guard pending.identity.subKey == oldIdentity.subKey else {
                        record.refreshOp = nil
                        record.requiresLogin = true
                        try Self.bind(&record, key: key)
                        try? save()
                        throw SIWCError(.signInRequired, Self.accountChangedMessage)
                    }
                    record.tokens = pending.tokens
                    record.identity = pending.identity
                    record.refreshOp = nil; record.refreshRecovery = nil
                    old = pending.tokens
                    try Self.bind(&record, key: key)
                }
                try save()
            }
            let now = nowSeconds
            let due = old.expiresAt - Int(SIWCEndpoint.refreshMargin) <= now
            let earliestOK = (old.earliestRefreshAt ?? 0) <= now
            let rejected = rejectedAccess != nil && rejectedAccess == old.access
            // Fresh, or due but not yet allowed while still valid: use it.
            if !rejected && (!due || (!earliestOK && old.expiresAt > now)) { return old }
            let fingerprint = SubscriptionRefreshFingerprint.of(old.refresh)
            if let recovery = record.refreshRecovery, recovery.generation == generation, recovery.tokenFingerprint == fingerprint {
                throw SIWCError(.signInRequired, Self.refreshExhaustedMessage)
            }
            let recovering = record.refreshOp.map { $0.generation == generation && $0.tokenFingerprint == fingerprint } ?? false
            if caller.cancelled { throw CancellationError() }
            let priorOp = record.refreshOp, priorRecovery = record.refreshRecovery
            if recovering { record.refreshRecovery = SubscriptionRefreshRecovery(tokenFingerprint: fingerprint, generation: generation, state: "reserved") }
            record.refreshOp = SubscriptionRefreshOp(opId: UUID().uuidString, tokenFingerprint: fingerprint, generation: generation,
                                                     startedAt: clock(), state: "sending")
            try save()
            if caller.cancelled {
                record.refreshOp = priorOp; record.refreshRecovery = priorRecovery
                try? save()
                throw CancellationError()
            }
            let sentBinding = record.binding
            let updated: SIWCRefreshed
            do { updated = try await refresh(old.refresh) }
            catch {
                switch Self.disposition(error) {
                case .terminal, .invalidClient:
                    if Self.disposition(error) == .invalidClient { record.invalidClient = true }
                    else {
                        record.requiresLogin = true
                        record.cleanup = Array(((record.cleanup ?? []) + [old.refresh]).suffix(64))
                        record.tokens = nil
                    }
                    record.refreshOp = nil
                    try Self.bind(&record, key: key)
                    try? save()
                    throw error
                case .notSent:
                    record.refreshOp = priorOp; record.refreshRecovery = priorRecovery
                    try? save()
                    throw error
                case .ambiguous:
                    record.refreshOp?.state = "ambiguous"
                    if recovering { record.refreshRecovery?.state = "exhausted" }
                    try? save()
                    if recovering { throw SIWCError(.signInRequired, Self.refreshExhaustedMessage) }
                    throw error
                }
            }
            // HTTP 200 (§7 step 3): checkpoint first (unusable, MAC-bound).
            let sameAccount = updated.claims.map { Self.mac(key, "siwc-sub", Data($0.sub.utf8)) == oldIdentity.subKey } ?? true
            let newIdentity = updated.claims.map { Self.identity(key: key, sub: registration.sub, accountId: $0.accountId) } ?? oldIdentity
            var rotation = SIWCPendingRotation(generation: generation, replaces: fingerprint, tokens: updated.tokens,
                                               identity: newIdentity, mac: String(repeating: "0", count: 64))
            rotation.mac = try Self.rotationMAC(key: key, rotation)
            record.pendingRotation = rotation
            try? save()
            // The record must still be the one whose refresh token was sent:
            // a record changed meanwhile (outside the lock) keeps the received
            // tokens for revocation only (§3.5 v2.9).
            if let disk = try? readTokens()?.record(clientId), disk.binding != sentBinding || disk.generation != generation {
                var current = disk
                current.pendingRotation = nil
                current.cleanup = Array(((current.cleanup ?? []) + [updated.tokens.refresh]).suffix(64))
                file.update(clientId) { $0 = current }
                try? writeTokens(file)
                throw SIWCError(.signInRequired, SIWCError.signInMessage)
            }
            guard sameAccount, updated.tokens.valid, updated.tokens.planUsage || !old.planUsage else {
                record.pendingRotation = nil
                record.refreshOp = nil
                record.requiresLogin = true
                record.cleanup = Array(((record.cleanup ?? []) + [updated.tokens.refresh]).suffix(64))
                try Self.bind(&record, key: key)
                try? save()
                throw SIWCError(.signInRequired, Self.accountChangedMessage)
            }
            record.tokens = updated.tokens
            record.identity = newIdentity
            record.pendingRotation = nil; record.refreshOp = nil; record.refreshRecovery = nil
            try Self.bind(&record, key: key)
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
