import Foundation

/// The persona inputs of the main system prompt: the assistant's name, the
/// user's name, the structured user profile and the prior (migrated) persona
/// name. One value is captured per main turn and per subagent run so a
/// profile written mid-turn (background archive fact extraction, profile
/// maintenance, a direct store write) cannot change the system prompt of a
/// running turn or run; it becomes visible at the next one.
///
/// Memory-only by design: deliberately not `Codable`, never written to
/// checkpoints, salvage records, subagent sessions, prune archives or Mind
/// exports. A restarted turn captures a fresh value.
struct PromptPersona: Equatable, Sendable {
    let assistantName: String?
    let userName: String?
    let structuredUserContext: String?
    let previousName: String?

    /// Exactly the four sources the prompt read per request before snapshots.
    static func live() -> PromptPersona {
        PromptPersona(
            assistantName: KeychainHelper.load(key: KeychainHelper.assistantNameKey),
            userName: KeychainHelper.load(key: KeychainHelper.userNameKey),
            structuredUserContext: KeychainHelper.load(key: KeychainHelper.structuredUserContextKey),
            previousName: IdentityMigration.priorPersonaName())
    }
}
