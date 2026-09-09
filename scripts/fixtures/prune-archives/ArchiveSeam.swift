
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
        let repeated = items[0]
        // Identical links in many rows must still share a single header.
        let manyTable = await renderer.formatChunkSummaries(Array(repeating: repeated, count: 20), totalChunkCount: 20)
        try SnapshotOwnerInputs.check(manyTable.components(separatedBy: PruneArchiveStore.root.path).count == 2
            && manyTable.components(separatedBy: "latest 300").count == 2,
            "twenty snapshot rows still share one folder/retention header")
        let plain = ArchivedSummaryItem(id: UUID(), kind: .temporaryChunk, startDate: chunk.startDate,
            endDate: chunk.endDate, tokenCount: 100, messageCount: 2, summary: "plain summary", sourceChunkCount: 1)
        let plainTable = await renderer.formatChunkSummaries([plain], totalChunkCount: 1)
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

extension ConversationArchiveService {
    /// Bree's 0.2.13/0.2.14 finding: a chunk committed to the index whose
    /// pending-index write then failed leaves a stale recovery record. The
    /// retry must settle it, and startup recovery must not wedge behind one
    /// whose raw file consolidation deleted on purpose.
    func staleReceiptChecks(server: CaptureServer) async throws {
        let summary = String(repeating: "visible message summary ", count: 110)
        func batch(_ tag: String, at date: Date) -> [Message] {
            [Message(role: .user, content: tag + " request", timestamp: date),
             Message(role: .assistant, content: tag + " answer", timestamp: date.addingTimeInterval(1))]
        }
        func diskPending() throws -> [UUID] {
            try JSONDecoder().decode(PendingChunkIndex.self, from: Data(contentsOf: pendingIndexFileURL)).pendingChunks.map(\.id)
        }
        let base = Date().addingTimeInterval(-3600)
        server.clear()
        let first = batch("stale-first", at: base)
        server.script([try SnapshotOwnerInputs.response(summary), try SnapshotOwnerInputs.response("NO_CHANGES")])
        let chunk = try await archiveMessages(first)
        // Exact on-disk state archiveMessages leaves when the chunk-index write
        // succeeds and the pending-index write right after it fails.
        let stale = PendingChunk(id: chunk.id, startDate: chunk.startDate, endDate: chunk.endDate, tokenCount: chunk.tokenCount,
            messageCount: chunk.messageCount, rawContentFileName: chunk.rawContentFileName, createdAt: chunk.startDate,
            sourceMessageIDs: first.map(\.id))
        pendingIndex.pendingChunks.append(stale)
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(pendingIndex), to: pendingIndexFileURL)
        let before = server.completeRequests.count
        let retry = try await archiveMessages(first)
        try SnapshotOwnerInputs.check(retry.id == chunk.id && server.completeRequests.count == before
            && !pendingIndex.pendingChunks.contains { $0.id == chunk.id } && !(try diskPending()).contains(chunk.id),
            "committed retry settles the stale pending record on disk")
        try SnapshotOwnerInputs.check(FileManager.default.fileExists(atPath: archiveFolder.appendingPathComponent(chunk.rawContentFileName).path),
            "settling the stale record keeps the committed raw file")

        // A record left by an earlier build, after consolidation absorbed the
        // chunk (new id, merged source IDs) and deleted its raw file.
        pendingIndex.pendingChunks.append(stale)
        var consolidated = ConversationChunk(id: UUID(), type: .consolidated, startDate: chunk.startDate, endDate: chunk.endDate,
            tokenCount: chunk.tokenCount, messageCount: chunk.messageCount, summary: summary, rawContentFileName: UUID().uuidString + ".json")
        consolidated.sourceMessageIDs = first.map(\.id) + [UUID()]
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(first), to: archiveFolder.appendingPathComponent(consolidated.rawContentFileName))
        chunkIndex.chunks.removeAll { $0.id == chunk.id }
        chunkIndex.chunks.append(consolidated)
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(chunkIndex), to: indexFileURL)
        try FileManager.default.removeItem(at: archiveFolder.appendingPathComponent(chunk.rawContentFileName))
        removeSidecar(forRawFileName: chunk.rawContentFileName)
        // An uncovered record whose raw file is gone: evidence must stay, but
        // nothing may wait behind it.
        let orphanID = UUID()
        pendingIndex.pendingChunks.append(PendingChunk(id: orphanID, startDate: base.addingTimeInterval(60), endDate: base.addingTimeInterval(61),
            tokenCount: 10, messageCount: 2, rawContentFileName: orphanID.uuidString + ".json", createdAt: base.addingTimeInterval(60),
            sourceMessageIDs: [UUID(), UUID()]))
        // A genuine later pending chunk, ordered after both.
        let later = batch("stale-later", at: base.addingTimeInterval(600))
        let laterID = UUID(); let laterFile = laterID.uuidString + ".json"
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(later), to: archiveFolder.appendingPathComponent(laterFile))
        pendingIndex.pendingChunks.append(PendingChunk(id: laterID, startDate: later[0].timestamp, endDate: later[1].timestamp,
            tokenCount: 10, messageCount: 2, rawContentFileName: laterFile, createdAt: later[0].timestamp, sourceMessageIDs: later.map(\.id)))
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(pendingIndex), to: pendingIndexFileURL)
        server.script([try SnapshotOwnerInputs.response(summary)])
        await recoverPendingChunks()
        try SnapshotOwnerInputs.check(pendingIndex.pendingChunks.map(\.id) == [orphanID] && (try diskPending()) == [orphanID],
            "recovery settles the absorbed record and keeps only the unreadable one")
        try SnapshotOwnerInputs.check(chunkIndex.chunks.contains { $0.id == laterID && $0.summary.hasPrefix("visible message summary") },
            "later pending chunk recovers behind a stale record")
        let reloaded = try JSONDecoder().decode(ChunkIndex.self, from: Data(contentsOf: indexFileURL))
        try SnapshotOwnerInputs.check(reloaded.chunks.contains { $0.id == laterID } && !reloaded.chunks.contains { $0.id == chunk.id },
            "recovered later chunk is published to the index")
        pendingIndex.pendingChunks.removeAll { $0.id == orphanID }
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(pendingIndex), to: pendingIndexFileURL)
        server.clear()
    }
}
