
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
        let items = await getPromptSummaryItems()
        let renderer = OpenRouterService()
        for total in [items.count, items.count + 10] {
            let table = await renderer.formatChunkSummaries(items, totalChunkCount: total)
            try SnapshotOwnerInputs.check(table.components(separatedBy: PruneArchiveStore.root.path).count == 2
                && table.components(separatedBy: "latest 300").count == 2
                && table.contains("Snapshots: " + ref.basename) && !table.contains("Full context snapshot:"),
                "archive table declares folder/retention once (total \(total))")
        }
        var repeated = items[0]
        // Identical links in many rows must still share a single header.
        let manyTable = await renderer.formatChunkSummaries(Array(repeating: repeated, count: 20), totalChunkCount: 20)
        try SnapshotOwnerInputs.check(manyTable.components(separatedBy: PruneArchiveStore.root.path).count == 2
            && manyTable.components(separatedBy: "latest 300").count == 2,
            "twenty snapshot rows still share one folder/retention header")
        repeated.hasSnapshotReferences = false
        repeated.summary = "plain summary"
        let plainTable = await renderer.formatChunkSummaries([repeated], totalChunkCount: 1)
        try SnapshotOwnerInputs.check(!plainTable.contains(PruneArchiveStore.root.path) && !plainTable.contains("latest 300"),
            "snapshot-free table has no extra header")
        let before = server.completeRequests.count
        let retry = try await archiveMessages(detailBatch, snapshot: ref)
        try SnapshotOwnerInputs.check(chunk.id == retry.id && server.completeRequests.count == before, "archive retry reuses committed batch without another model call")
        try SnapshotOwnerInputs.check(chunk.summaryWithSnapshotReferences.contains(ref.basename), "chunk summary receives mechanical snapshot link")
        await writeSidecar(forRawFileName: chunk.rawContentFileName, messages: saved)
        let sidecar = archiveFolder.appendingPathComponent((chunk.rawContentFileName as NSString).deletingPathExtension + ".txt")
        try SnapshotOwnerInputs.check(try String(contentsOf: sidecar).contains(ref.relativePath), "regenerated sidecar retains portable snapshot reference")
        let newer = try PruneArchiveStore.write(messages: source, trigger: "chunk-archive", removedIDs: detailBatch.map(\.id))
        let refreshed = try await archiveMessages(detailBatch, snapshot: newer)
        let refreshedRaw = try JSONDecoder().decode([Message].self, from: Data(contentsOf: archiveFolder.appendingPathComponent(refreshed.rawContentFileName)))
        try SnapshotOwnerInputs.check(refreshed.id == chunk.id && refreshed.pruneArchiveReferences?.contains(newer) == true
            && refreshedRaw.flatMap(\.pruneArchiveReferences).contains(newer), "committed retry preserves newer snapshot reference without a duplicate chunk")
        server.clear()
        var racing = source
        racing[0] = Message(role: .user, content: "concurrent archive source")
        racing[1] = Message(role: .assistant, content: "concurrent reply", toolInteractions: source[1].toolInteractions)
        server.script([try SnapshotOwnerInputs.response(summary), try SnapshotOwnerInputs.response("NO_CHANGES")])
        async let first = archiveMessages(racing, snapshot: ref)
        async let second = archiveMessages(racing, snapshot: ref)
        let (one, two) = try await (first, second)
        try SnapshotOwnerInputs.check(one.id == two.id && server.completeRequests.count == 2,
            "overlapping archive calls share one committed chunk and one summary/extraction")
        server.clear()
        let pure = [Message(role: .user, content: "pure-text chunk"), Message(role: .assistant, content: "plain answer")]
        server.script([try SnapshotOwnerInputs.response(summary), try SnapshotOwnerInputs.response("NO_CHANGES")])
        let pureChunk = try await archiveMessages(pure)
        try SnapshotOwnerInputs.check(pureChunk.pruneArchiveReferences == nil, "pure-text chunk adds no redundant snapshot")
        let countBeforeMedia = try PruneArchiveStore.entries().count
        let media = [Message(role: .user, content: "photo", imageFileNames: ["photo.jpg"], documentFileNames: ["note.pdf"]),
                     Message(role: .assistant, content: "visible media reply")]
        server.script([try SnapshotOwnerInputs.response(summary), try SnapshotOwnerInputs.response("NO_CHANGES")])
        let mediaChunk = try await archiveMessages(media)
        let storedMedia = try JSONDecoder().decode([Message].self, from: Data(contentsOf: archiveFolder.appendingPathComponent(mediaChunk.rawContentFileName)))
        try SnapshotOwnerInputs.check(mediaChunk.pruneArchiveReferences == nil
            && (try PruneArchiveStore.entries().count) == countBeforeMedia
            && storedMedia[0].imageFileNames == ["photo.jpg"] && storedMedia[0].documentFileNames == ["note.pdf"],
            "media-only archive keeps attachment names without new snapshot")
    }
}
