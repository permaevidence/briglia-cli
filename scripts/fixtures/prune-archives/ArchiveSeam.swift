
extension ConversationArchiveService {
    func snapshotArchiveChecks(_ source: [Message], server: CaptureServer) async throws {
        let ref = try PruneArchiveStore.write(messages: source, trigger: "chunk-archive", removedIDs: [source[0].id, source[1].id])
        var detailBatch = Array(source.prefix(2))
        detailBatch[1].prunedContextSummary = "SUMMARY_PROSE_MUST_NOT_ENTER_CHUNK"
        let summary = String(repeating: "visible message summary ", count: 110)
        server.script([try SnapshotOwnerInputs.response(summary), try SnapshotOwnerInputs.response("NO_CHANGES")])
        let chunk = try await archiveMessages(detailBatch, snapshot: ref)
        let saved = try JSONDecoder().decode([Message].self, from: Data(contentsOf: archiveFolder.appendingPathComponent(chunk.rawContentFileName)))
        try SnapshotOwnerInputs.check(saved.count == detailBatch.count && saved.allSatisfy { $0.prunedContextSummary == nil && $0.toolInteractions.isEmpty }, "chunks keep messages and no pruning-summary prose")
        try SnapshotOwnerInputs.check(saved[0].pruneArchiveReferences.contains(ref), "canonical chunk keeps typed reference")
        try SnapshotOwnerInputs.check(!(String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)).contains("SUMMARY_PROSE_MUST_NOT_ENTER_CHUNK"), "summary prose is absent from raw chunk JSON")
        let before = server.completeRequests.count
        let retry = try await archiveMessages(detailBatch, snapshot: ref)
        try SnapshotOwnerInputs.check(chunk.id == retry.id && server.completeRequests.count == before, "archive retry reuses committed batch without another model call")
        try SnapshotOwnerInputs.check(chunk.summaryWithSnapshotReferences.contains(ref.basename), "chunk summary receives mechanical snapshot link")
        await writeSidecar(forRawFileName: chunk.rawContentFileName, messages: saved)
        let sidecar = archiveFolder.appendingPathComponent((chunk.rawContentFileName as NSString).deletingPathExtension + ".txt")
        try SnapshotOwnerInputs.check(try String(contentsOf: sidecar).contains(ref.relativePath), "regenerated sidecar retains portable snapshot reference")
        server.clear()
        let pure = [Message(role: .user, content: "pure-text chunk"), Message(role: .assistant, content: "plain answer")]
        server.script([try SnapshotOwnerInputs.response(summary), try SnapshotOwnerInputs.response("NO_CHANGES")])
        let pureChunk = try await archiveMessages(pure)
        try SnapshotOwnerInputs.check(pureChunk.pruneArchiveReferences == nil, "pure-text chunk adds no redundant snapshot")
    }
}
