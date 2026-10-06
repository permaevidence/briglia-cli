import Foundation

/// Plan §13 tests 8 (explicit reads, tool contract) and 9 (file lifetime).
extension BackgroundArchiveHarness {

    func archiveFile(_ id: UUID, _ ext: String) -> URL {
        StoragePaths.dataRoot.appendingPathComponent("archive/\(id.uuidString).\(ext)")
    }

    /// Five published temporaries (A..E), then a background job whose chunk
    /// F triggers consolidation of A..D into G, paused right after the
    /// consolidation's index publication.
    final class ConsolidationPause: @unchecked Sendable {
        let gate = SVGate()
    }

    func fileLifetimeSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory(), seed: { try await self.seedTemporaryChunks(5) })
        let archive = manager._testArchiveService
        let seeded = await archive.getAllChunks()
        guard seeded.count == 5 else { check("BF setup: five seeded chunks", false, "\(seeded.count)"); return }
        let a = seeded[0]
        let pause = ConsolidationPause()
        ConversationArchiveService.afterConsolidationPublishForTesting = { await pause.gate.wait() }
        _ = await startBackgroundJob(manager, hold: [])
        let paused = await waitUntil(timeout: 30) { pause.gate.arrived > 0 }
        let indexed = await archive.getAllChunks()
        check("BF1 consolidation published (A..D replaced by one consolidated chunk) and paused",
              paused && !indexed.contains { $0.id == a.id } && indexed.contains { $0.type == .consolidated }, "\(indexed.count) chunks")
        let retainedWhilePaused = await archive._testRetainedChildIds
        check("BF1 A is named by a live view, so its raw file and transcript are retained",
              FileManager.default.fileExists(atPath: archiveFile(a.id, "json").path)
                && FileManager.default.fileExists(atPath: archiveFile(a.id, "txt").path)
                && retainedWhilePaused.contains(a.id))
        let byId = await manager._baExecuteMainTool("read_chunk_summaries", "{\"chunk_ids\":[\"\(a.id.uuidString.prefix(8))\"]}")
        check("BF2 a main-agent read by A's id resolves (A is a row of the turn's view: the existing 'already a row' note)",
              byId.contains("already an individual row"), byId)
        let read = await manager._baExecuteMainTool("read_file", "{\"path\":\"\(archiveFile(a.id, "txt").path)\"}")
        check("BF2 A's advertised transcript path is readable while paused", read.contains("end of seed0."), String(read.prefix(300)))
        let sub = ToolExecutor(outputMode: .subagent)
        await sub.setArchiveService(archive)
        let subRead = (try? await sub.execute(ToolCall(id: "ba-sub", type: "function",
            function: FunctionCall(name: "read_chunk_summaries", arguments: "{\"chunk_ids\":[\"\(a.id.uuidString.prefix(8))\"]}"))))?.content ?? ""
        check("BF2 a subagent (no archive table in its prompt) gets A's summary, never the 'already a row' note",
              subRead.contains("Fixture summary #1") && !subRead.contains("already an individual row"), subRead)
        let byDate = await manager._baExecuteMainTool("read_chunk_summaries", "{\"from\":\"2000-01-01\"}")
        check("BT1 explicit reads are not filtered by the view: the new chunk and the consolidated replacement come back by date",
              byDate.contains("Fixture summary #6") && byDate.contains("Fixture summary #7"), byDate)
        check("BT1 ...and the 'already a row' skip follows the turn's view (E is a row there, so it is skipped)",
              byDate.contains("Skipped 1 matched chunk(s)"), byDate)
        pause.gate.release()
        ConversationArchiveService.afterConsolidationPublishForTesting = nil
        _ = await waitForJob(manager, "succeeded")
        let frozenLease = manager._baJobFrozenLease
        await turn(manager, "turn while A is retained", reply: "ok")
        // Now a commit already happened at that turn's start; check retention
        // during the turn that reused the frozen view instead:
        let frozenRefs = await archive._testLeaseReferences(frozenLease ?? UUID())
        let retainedAfter = await archive._testRetainedChildIds
        check("BF3 the job finished mid-way; the next turn committed and released the frozen lease",
              manager._baJobOutcome == nil && frozenLease != nil && frozenRefs == 0)
        check("BF3 after the last view naming A retired, A's files were deleted with today's code",
              !FileManager.default.fileExists(atPath: archiveFile(a.id, "json").path)
                && !FileManager.default.fileExists(atPath: archiveFile(a.id, "txt").path)
                && retainedAfter.isEmpty)
        check("BF3 one lease left: the current turn's", await archive._testLeaseCount == 1, "\(await archive._testLeaseCount)")

        await frozenReuseSection()
        await crashWithRetainedFilesSection()
        await hiddenConsolidatedReadSection()
    }

    /// A turn reusing the frozen view takes and drops its own reference;
    /// the job's reference survives every such turn.
    private func frozenReuseSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        _ = await startBackgroundJob(manager)
        guard let lease = manager._baJobFrozenLease else { check("BF4 setup", false); return }
        let archive = manager._testArchiveService
        let afterStart = await archive._testLeaseReferences(lease)
        await turn(manager, "reuse 1", reply: "ok")
        await turn(manager, "reuse 2", reply: "ok")
        let afterReuse = await archive._testLeaseReferences(lease)
        check("BF4 frozen-view reuse: job + current turn hold the lease (never released by a reusing turn)",
              afterStart == 2 && afterReuse == 2 && manager._baTurnLeaseId == lease, "start \(afterStart), after \(afterReuse)")
        router.gate.release()
        _ = await waitForJob(manager, "succeeded")
        // Failed-job disposal also releases: covered by BA7 (lease count).
        await turn(manager, "commit", reply: "ok")
        let refsAfter = await archive._testLeaseReferences(lease)
        let countAfter = await archive._testLeaseCount
        check("BF4 commit disposes the job's reference and the next view replaces the turn's",
              refsAfter == 0 && countAfter == 1, "refs \(refsAfter), leases \(countAfter)")
        // Teardown releases every lease.
        await archive.releaseAllLeases()
        check("BF5 teardown releases every lease", await archive._testLeaseCount == 0)
    }

    /// A crash while children are retained: the files are untracked raw
    /// files, removed by the next recovery's reconciliation after its grace.
    private func crashWithRetainedFilesSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory(), seed: { try await self.seedTemporaryChunks(5) })
        let a = (await manager._testArchiveService.getAllChunks())[0]
        _ = await startBackgroundJob(manager, hold: [])
        _ = await waitForJob(manager, "succeeded")
        check("BF6 setup: A retained after consolidation", FileManager.default.fileExists(atPath: archiveFile(a.id, "json").path))
        // "Crash": a new service has no retained map; age A past the grace.
        let old = Date().addingTimeInterval(-7_200)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: archiveFile(a.id, "json").path)
        let restarted = ConversationArchiveService()
        await restarted.configure(apiKey: apiKey)
        await restarted.recoverPendingChunks()
        check("BF6 after a crash, retained files are reconciled away after the grace period",
              !FileManager.default.fileExists(atPath: archiveFile(a.id, "json").path))
    }

    /// After a restart with a hidden consolidated chunk, its older portion
    /// stays reachable by id, by date and through its transcript.
    private func hiddenConsolidatedReadSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        // Seeds dated AFTER the batch: the batch's chunk is the oldest
        // temporary, so consolidation absorbs it with three seeds.
        guard let (manager, batch) = await publishedButUncommitted(channel: channel, history: archiveSizedHistory(),
                                                                   seed: { try await self.seedTemporaryChunks(5, base: Date().addingTimeInterval(-3_600)) }) else {
            check("BT2 setup", false); return
        }
        let archive = manager._testArchiveService
        let chunks = await archive.getAllChunks()
        guard let fresh = chunks.first(where: { Set($0.sourceMessageIDs ?? []).isSuperset(of: batch) }), fresh.type == .consolidated else {
            check("BT2 setup: the batch sits in a consolidated chunk", false, chunks.map(\.type.rawValue).joined(separator: ",")); return
        }
        let consolidated = fresh
        await archive._testAcquireWriter()
        server.clear()
        await turn(manager, "hidden rows after restart", reply: "ok")
        let section = mainRequests.last.map(archiveSection) ?? ""
        check("BT2 the chunk overlapping live messages is hidden after the restart",
              !section.contains("| \(fresh.id.uuidString.prefix(8)) |") && section.contains("left out of this table"), section)
        let byId = await manager._baExecuteMainTool("read_chunk_summaries", "{\"chunk_ids\":[\"\(fresh.id.uuidString.prefix(8))\"]}")
        check("BT2 the hidden consolidated chunk's summary is returned by id", byId.contains("Fixture summary #7"), byId)
        let byDate = await manager._baExecuteMainTool("read_chunk_summaries", "{\"from\":\"2000-01-01\"}")
        check("BT2 ...and by date", byDate.contains("Fixture summary #7"), byDate)
        let consolidatedRead = await manager._baExecuteMainTool("read_file", "{\"path\":\"\(archiveFile(consolidated.id, "txt").path)\"}")
        check("BT2 the consolidated transcript (history that is no longer live) stays readable", consolidatedRead.contains("end of seed0."),
              String(consolidatedRead.prefix(300)))
        await archive._testReleaseWriter()
    }

    func toolContractSection() async {
        // Covered inside fileLifetimeSection (BT1, BF2) and BT2; this
        // section checks the injected service sees chunks published after
        // the executor was configured (the old per-executor index never did).
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        _ = await startBackgroundJob(manager, hold: [])
        _ = await waitForJob(manager, "succeeded")
        let chunk = (await manager._testArchiveService.getAllChunks()).first
        let read = await manager._baExecuteMainTool("read_chunk_summaries", "{\"chunk_ids\":[\"\(chunk?.id.uuidString.prefix(8) ?? "x")\"]}")
        check("BT3 a chunk published after startup is readable by id through the main agent's tools",
              read.contains("Fixture summary #1"), read)
    }
}
