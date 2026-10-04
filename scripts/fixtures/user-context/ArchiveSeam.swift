
// Appended to ConversationArchiveService.swift in DISPOSABLE builds only
// (scripts/user_context_wire_test.py), identically for the v0.2.48 base and
// the candidate. Invokes the real private archive owners.
extension ConversationArchiveService {
    func wireMeta() async throws -> String {
        let chunk = ConversationChunk(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, type: .consolidated,
            startDate: Date(timeIntervalSince1970: 1_790_000_000), endDate: Date(timeIntervalSince1970: 1_790_086_400),
            tokenCount: 1000, messageCount: 2, summary: "Historical fixture summary", rawContentFileName: "fixture.json")
        return try await generateHistoricalMetaSummary(for: [chunk], kind: .sealedBatch, context: .empty)
    }
    func wireCall(system: String, user: String) async throws -> String {
        try await callLLM(systemPrompt: system, userPrompt: user)
    }
}
