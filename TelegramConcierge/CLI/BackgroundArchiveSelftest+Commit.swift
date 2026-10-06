import Foundation

/// Plan §13 test 10 (baseline A in process) with real prunes, real
/// snapshots and real archive writes.
extension BackgroundArchiveHarness {

    func entryAlerts(_ channel: SVRecordingChannel) -> [String] {
        channel.delivered.filter { $0.hasPrefix("⚠️ Maintenance issue: removing archived messages") }
    }
    func recoveryAlerts(_ channel: SVRecordingChannel) -> [String] {
        channel.delivered.filter { $0.hasPrefix("✅ Recovered: removing archived messages") }
    }

    func rawAnchorRefs(_ archive: ConversationArchiveService, batch: [UUID]) async -> Set<UUID> {
        let owners = await archive.coveringChunkIds(for: batch)
        guard let chunk = owners[batch[0]], let raw = await archive._testRawMessages(chunkId: chunk) else { return [] }
        return Set(raw.filter { batch.contains($0.id) }.flatMap(\.pruneArchiveReferences).map(\.id))
    }

    func commitSection() async {
        // C1: real prunes during the job (anchors inside and outside the
        // batch, four summaries → Part B demotion), a synthetic stub, a media
        // prune and compact-log clearing → allowed, merged, removed.
        let channel = SVRecordingChannel(kind: .telegram)
        var history = detailHistory()
        history[2] = Message(id: history[2].id, role: .user,
                             content: "[EMAIL ARRIVED]\nfrom: someone@example.com\nsubject: Quarterly figures\n\n" + String(repeating: "body ", count: 300),
                             timestamp: history[2].timestamp, kind: .emailArrived)
        history[4] = Message(id: history[4].id, role: .user, content: history[4].content, timestamp: history[4].timestamp,
                             imageFileNames: ["photo.jpg"], imageFileSizes: [1234])
        history[11].toolInteractions = []
        history[11].compactToolLog = "COMPACT LOG 11"
        let manager = await freshManager(channel: channel, history: history)
        guard await startBackgroundJob(manager) else { check("BC1 setup", false); return }
        let batch = manager._baJobBatchIds
        let outside = history.indices.last { !batch.contains(history[$0].id) && !history[$0].toolInteractions.isEmpty }
        var pruneRefs: [UUID] = []
        do {
            for (n, index) in [1, 3, 5, 7].enumerated() {
                let view = try await manager._testRetentionPrune(affected: [index], trigger: "automatic", summary: "PRUNE-SUMMARY-\(n)")
                pruneRefs += view[index].pruneArchiveReferences.map(\.id)
            }
            if let outside { _ = try await manager._testRetentionPrune(affected: [outside], trigger: "automatic", summary: "PRUNE-OUTSIDE") }
        } catch { check("BC1 real prunes during the job", false, "\(error)") }
        var live = manager._testMessages
        if let i = live.firstIndex(where: { $0.id == history[2].id }),
           let stub = ConversationManager.archivedStub(kind: .emailArrived, content: live[i].content) { live[i].content = stub }
        if let i = live.firstIndex(where: { $0.id == history[4].id }) { live[i].mediaPruned = true }
        if let i = live.firstIndex(where: { $0.id == history[11].id }) { live[i].compactToolLog = nil }
        manager._testReplaceMessages(live)
        _ = manager._testSave()
        let demoted = manager._testMessages.contains { !$0.demotedPruneSummaries.isEmpty && batch.contains($0.id) }
        check("BC1 setup: four prunes inside the batch demoted the oldest summary (Part B)", demoted)
        let summaries = router.summaries
        router.gate.release()
        _ = await waitForJob(manager, "succeeded")
        let receipt = manager._baJobReceipt
        await turn(manager, "commit after prunes", reply: "ok")
        let archive = manager._testArchiveService
        let evidence = await archive.lastReconcileEvidence
        check("BC1 allowed pruning transformations: the batch was removed at the next turn without a model call",
              containsNone(manager, batch) && router.summaries == summaries && entryAlerts(channel).isEmpty,
              "summaries +\(router.summaries - summaries), alerts \(entryAlerts(channel))")
        check("BC1 the job's receipt covered the batch and the changed live detail was saved in a fresh snapshot",
              evidence.first?.covering == receipt?.id && evidence.first?.fresh != nil, "\(evidence)")
        let anchorRefs = await rawAnchorRefs(archive, batch: batch)
        check("BC1 the prune and demotion snapshot links were merged into the archived copy",
              Set(pruneRefs).isSubset(of: anchorRefs) && receipt.map { anchorRefs.contains($0.id) } == true,
              "missing \(Set(pruneRefs).subtracting(anchorRefs).count)")
        let fresh = evidence.first?.fresh.flatMap { id in ((try? PruneArchiveStore.entries()) ?? []).first { $0.reference.id == id }?.reference }
        let freshText = fresh.flatMap { try? String(contentsOf: PruneArchiveStore.root.appendingPathComponent($0.basename), encoding: .utf8) } ?? ""
        check("BC1 the fresh snapshot holds the live prune summaries", freshText.contains("PRUNE-SUMMARY-3"), String(freshText.prefix(200)))
        let entries = Set(((try? PruneArchiveStore.entries(validateComplete: true)) ?? []).map(\.reference.id))
        check("BC1 every referenced snapshot is complete and still present after retainLatest",
              anchorRefs.isSubset(of: entries), "missing \(anchorRefs.subtracting(entries).count)")
        check("BC1 the anchor outside the batch stayed live with its summary",
              outside.map { i in manager._testMessages.contains { $0.id == history[i].id && $0.prunedContextSummary == "PRUNE-OUTSIDE" } } ?? false)

        await settledSection()
        await writerBusySection()
        await equalBytesSection()
    }

    /// Empty remaining set (the batch already left) → settled.
    private func settledSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        _ = await startBackgroundJob(manager, hold: [])
        _ = await waitForJob(manager, "succeeded")
        let batch = Set(manager._baJobBatchIds)
        manager._testReplaceMessages(manager._testMessages.filter { !batch.contains($0.id) })
        _ = manager._testSave()
        await turn(manager, "after the batch left", reply: "ok")
        check("BC2 empty remaining set: settled, the job cleared, no alert",
              manager._baJobOutcome == nil && entryAlerts(channel).isEmpty)
    }

    private func writerBusySection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        _ = await startBackgroundJob(manager, hold: [])
        _ = await waitForJob(manager, "succeeded")
        let batch = manager._baJobBatchIds
        await manager._testArchiveService._testAcquireWriter()
        await turn(manager, "writer busy", reply: "ok")
        check("BC3 writer busy: commit deferred quietly, job kept, batch live",
              manager._baJobOutcome == "succeeded" && contains(manager, batch) && entryAlerts(channel).isEmpty)
        await manager._testArchiveService._testReleaseWriter()
        await turn(manager, "writer free", reply: "ok")
        check("BC3 the next turn with a free writer commits", containsNone(manager, batch) && manager._baJobOutcome == nil)
    }

    /// Equal sanitized bytes still go through checked reconciliation: a
    /// failing reconciliation write fails the commit even with no change.
    private func equalBytesSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        _ = await startBackgroundJob(manager, hold: [])
        _ = await waitForJob(manager, "succeeded")
        let batch = manager._baJobBatchIds
        ConversationArchiveService.reconcileWriteFaultForTesting = { throw ArchiveCommitRefusal("injected reconciliation write failure") }
        await turn(manager, "reconcile fails", reply: "ok")
        ConversationArchiveService.reconcileWriteFaultForTesting = nil
        check("BC4 unchanged batch: reconciliation still runs (its injected write failure refuses the removal)",
              contains(manager, batch) && entryAlerts(channel).count == 1, "\(channel.delivered)")
        await turn(manager, "reconcile ok", reply: "ok")
        check("BC4 ...and the next turn commits, closing the alert once",
              containsNone(manager, batch) && recoveryAlerts(channel).count == 1, "\(channel.delivered)")
    }

    /// Unexplained deltas refuse removal (fail closed), keep the rows out of
    /// automatic context and alert on `.archiveCommit`.
    func deltaSection() async {
        for variant in ["content", "tool-result", "new-tool"] {
            let channel = SVRecordingChannel(kind: .telegram)
            let manager = await freshManager(channel: channel, history: detailHistory())
            _ = await startBackgroundJob(manager)
            let batch = manager._baJobBatchIds
            var live = manager._testMessages
            switch variant {
            case "content":
                if let i = live.firstIndex(where: { $0.id == batch[0] }) { live[i].content += " (edited)" }
            case "tool-result":
                if let i = live.firstIndex(where: { $0.id == batch[1] }) { live[i].toolInteractions[0].results[0].content = "CHANGED RESULT" }
            default:
                if let i = live.firstIndex(where: { $0.id == batch[0] }) { live[i].toolInteractions = [toolRound(id: "added-call", result: "NEW DETAIL")] }
            }
            manager._testReplaceMessages(live)
            _ = manager._testSave()
            router.gate.release()
            _ = await waitForJob(manager, "succeeded")
            let summaries = router.summaries
            server.clear()
            await turn(manager, "commit with \(variant)", reply: "ok")
            await turn(manager, "again with \(variant)", reply: "ok")
            let section = mainRequests.last.map(archiveSection) ?? ""
            check("BD \(variant): unexplained change → removal refused, messages kept, no model call",
                  contains(manager, batch) && router.summaries == summaries && manager._baJobOutcome == "succeeded")
            check("BD \(variant): one .archiveCommit entry alert across repeated refusals", entryAlerts(channel).count == 1,
                  "\(channel.delivered)")
            check("BD \(variant): the new chunk stays out of automatic context", !section.contains("Fixture summary #1"), section)
        }
    }
}
