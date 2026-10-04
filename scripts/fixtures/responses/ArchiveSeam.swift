
// Appended to the disposable build only; invokes the real archive owners.
extension ConversationArchiveService {
    func p2Summary() async throws -> String {
        try await generateSummary(for: [Message(role: .user, content: "Archive this fixture")],
            startDate: Date(), endDate: Date(), context: .empty)
    }
    func p2Meta() async throws -> String {
        let chunk = ConversationChunk(id: UUID(), type: .consolidated, startDate: Date(), endDate: Date(),
            tokenCount: 1000, messageCount: 2, summary: "Historical fixture", rawContentFileName: "fixture.json")
        return try await generateHistoricalMetaSummary(for: [chunk], kind: .sealedBatch, context: .empty)
    }
    /// User-profile maintenance (edit operations) through its real entry,
    /// with a tiny threshold so a one-line profile qualifies: one pass,
    /// true when the run committed a changed profile.
    func p2Maintain() async -> Bool {
        try? FileManager.default.removeItem(at: UserContextMaintenance.stateURL)
        let before = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey)
        UserContextMaintenance.testPolicy = UserContextMaintenancePolicy(thresholdChars: 10, targetChars: 100, attemptDelays: [0, 0])
        defer { UserContextMaintenance.testPolicy = nil }
        await maintainUserContextIfNeeded(event: .archive)
        return KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) != before
    }
}
