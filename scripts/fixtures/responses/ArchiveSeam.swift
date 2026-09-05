
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
    func p2Restructure() async -> Bool { await restructureUserContext() }
}
