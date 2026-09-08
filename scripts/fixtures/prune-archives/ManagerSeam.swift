
// Appended only to a disposable test build, to invoke the actual private transaction.
extension ConversationManager {
    func snapshotOwnerChecks() async throws -> [Message] {
        let original = SnapshotOwnerInputs.history()
        let plan = PrunePlan(actions: [.toolInteractions(index: 1, savedTokens: 200)], pruningBoundary: 2)
        func seed() throws {
            messages = original
            try PrivateStorage.writeAtomically(JSONEncoder().encode(messages), to: conversationFileURL)
        }
        try seed()
        let untouched = try Data(contentsOf: conversationFileURL)
        PruneArchiveStore.faultForTesting = { if $0 == "write" { throw PruneArchiveStore.Failure("disk full fixture") } }
        do {
            _ = try await commitPrune(plan: plan, compressedIndices: [], safeBoundary: 2, source: messages, trigger: "manual") { _ in "summary" }
            throw SnapshotOwnerInputs.Failure("snapshot failure did not stop prune")
        } catch let error as PruneArchiveStore.Failure {
            try SnapshotOwnerInputs.check(error.localizedDescription.contains("/prune nosnapshot"), "snapshot error offers explicit local recovery")
        }
        PruneArchiveStore.faultForTesting = nil
        try SnapshotOwnerInputs.check(try Data(contentsOf: conversationFileURL) == untouched && !messages[1].toolInteractions.isEmpty, "snapshot failure keeps disk and live details")
        let after = try await commitPrune(plan: plan, compressedIndices: [], safeBoundary: 2, source: messages, trigger: "manual") { _ in nil }
        try SnapshotOwnerInputs.check(after[1].toolInteractions.isEmpty && after[1].pruneArchiveReferences.count == 1, "summary failure still commits typed reference")
        let reference = after[1].pruneArchiveReferences[0]
        let body = try String(contentsOf: PruneArchiveStore.root.appendingPathComponent(reference.basename))
        try SnapshotOwnerInputs.check(body.contains("EXACT_OLD_RESULT") && body.contains("surrounding latest message"), "snapshot includes discarded result and protected context")
        try seed()
        let arrival = Message(role: .user, content: "arrived during summary")
        _ = try await commitPrune(plan: plan, compressedIndices: [], safeBoundary: 2, source: messages, trigger: "automatic") { _ in
            self.messages.append(arrival)
            return "summary"
        }
        try SnapshotOwnerInputs.check(messages.last?.id == arrival.id && messages[1].toolInteractions.isEmpty, "new arrival survives checked commit")
        try seed()
        do {
            _ = try await commitPrune(plan: plan, compressedIndices: [], safeBoundary: 2, source: messages, trigger: "automatic") { _ in
                self.messages[0].content = "changed existing message"
                return "summary"
            }
            throw SnapshotOwnerInputs.Failure("changed preimage accepted")
        } catch is PruneArchiveStore.Failure { }
        try SnapshotOwnerInputs.check(messages[0].content == "changed existing message" && !messages[1].toolInteractions.isEmpty, "changed source safely abandons prune")
        try seed()
        let parked = conversationFileURL.appendingPathExtension("parked")
        try FileManager.default.moveItem(at: conversationFileURL, to: parked)
        try FileManager.default.createDirectory(at: conversationFileURL, withIntermediateDirectories: false)
        do {
            _ = try await commitPrune(plan: plan, compressedIndices: [], safeBoundary: 2, source: messages, trigger: "manual") { _ in "summary" }
            throw SnapshotOwnerInputs.Failure("conversation save failure accepted")
        } catch is PruneArchiveStore.Failure { }
        try SnapshotOwnerInputs.check(!messages[1].toolInteractions.isEmpty, "conversation save failure retains live preimage")
        try FileManager.default.removeItem(at: conversationFileURL)
        try FileManager.default.moveItem(at: parked, to: conversationFileURL)
        let count = try PruneArchiveStore.entries().count
        PruneArchiveStore.faultForTesting = { if $0 == "write" { throw PruneArchiveStore.Failure("disk full fixture") } }
        let loss = try await commitPrune(plan: plan, compressedIndices: [], safeBoundary: 2, source: messages,
            trigger: "manual", noSnapshot: true) { _ in nil }
        try SnapshotOwnerInputs.check(loss[1].pruneArchiveReferences.isEmpty && loss[1].prunedContextSummary?.contains("no new snapshot") == true, "one-prune override records loss without fake link")
        try SnapshotOwnerInputs.check(try PruneArchiveStore.entries().count == count, "override does not write a snapshot")
        try seed()
        do {
            _ = try await commitPrune(plan: plan, compressedIndices: [], safeBoundary: 2, source: messages, trigger: "automatic") { _ in nil }
            throw SnapshotOwnerInputs.Failure("override persisted into next prune")
        } catch is PruneArchiveStore.Failure { }
        PruneArchiveStore.faultForTesting = nil
        try SnapshotOwnerInputs.check(!messages[1].toolInteractions.isEmpty, "next automatic prune still requires snapshot")
        let final = try await commitPrune(plan: plan, compressedIndices: [], safeBoundary: 2, source: messages, currentRounds: [], trigger: "mid-turn") { _ in "condensed context" }
        return final
    }
}
