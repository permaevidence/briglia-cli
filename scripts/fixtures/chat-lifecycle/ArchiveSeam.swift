
// Appended only to instrumented release/candidate sources.
extension ConversationArchiveService {
    func p0Summary(_ messages: [Message]) async throws -> String {
        try await generateSummary(for: messages, startDate: P0Life.instant, endDate: P0Life.instant, context: .empty)
    }
}
