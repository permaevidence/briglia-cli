import Foundation

/// The automatic same-registration rebind at the start of an operation
/// (SIWC plan §3.8 "One active registration per store", D21; the rule of
/// `SubscriptionSharing.resolveGeneration` for the legacy route).
///
/// Under the store's SIWC lock: the store's active registration must still
/// be the selected one with the same verified identity (else the D18
/// "different account" refusal), the record must be usable and no sign-in
/// may be pending; then this assistant's SIWC generation is rewritten in a
/// conditional secrets transaction (a maintenance write: it never supersedes
/// a staged settings change), still holding the auth lock. Anything else
/// returns the captured generation unchanged, and the ordinary validation
/// refuses it before any send.
enum SIWCRebind {
    /// Bounded lock wait on a request path (never the full 45 s).
    static let lockWait: TimeInterval = 5

    /// Selftest seam: runs between reading the store and the secrets commit.
    nonisolated(unsafe) static var beforeCommitForTesting: (() -> Void)?

    static func rebind(_ selection: ChatGPTRoute.Selection, clientId: String, store: SIWCStore) throws -> String {
        // Preparing or evaluating a settings change: no write may happen
        // here (the overlay or a pure resolver is reading).
        guard SettingsCapture.current == nil else { return selection.generation }
        return try store.lockedSync(wait: lockWait) { () throws -> String in
            guard let registrations = try store.readRegistrations(), registrations.active == clientId,
                  let registration = registrations.registration(clientId),
                  SIWCEndpoint.registrationFingerprint(clientId: clientId) == selection.registrationFingerprint,
                  SIWCEndpoint.identityFingerprint(clientId: clientId, sub: registration.sub) == selection.identityFingerprint else {
                throw SIWCError(.signInRequired, SubscriptionSharing.differentAccountMessage(changedBy: nil))
            }
            guard let file = try store.readTokens(), file.pendingLogin == nil, let record = file.record(clientId),
                  record.generation != selection.generation,
                  store.usability(record, registration: registration, key: try store.integrityKey(create: false)) == .usable else {
                return selection.generation
            }
            beforeCommitForTesting?()
            var rebound = false
            try SettingsSupersede.$maintenanceWrite.withValue(true) {
                try KeychainHelper.conditionalTransaction { s in
                    guard s[ChatGPTRoute.routeKey] == "siwc",
                          s[ChatGPTRoute.siwcRegistrationKey] == selection.registrationFingerprint,
                          s[ChatGPTRoute.siwcIdentityKey] == selection.identityFingerprint,
                          s[ChatGPTRoute.siwcGenerationKey] == selection.generation else { return }
                    s[ChatGPTRoute.siwcGenerationKey] = record.generation
                    rebound = true
                }
            }
            return rebound ? record.generation : selection.generation
        }
    }
}
