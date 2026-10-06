import Foundation

/// Plan §13 test 7 (automatic-context consistency) and the disclosure.
extension BackgroundArchiveHarness {

    func chatText(_ text: String, promptTokens: Int) -> String {
        let body: [String: Any] = ["id": "ba", "object": "chat.completion", "model": "glm-5.3",
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": promptTokens, "completion_tokens": 10, "total_tokens": promptTokens + 10]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    /// Runs a background job to completion (published, not committed), then
    /// "restarts": a new manager over the same disk. Returns the restarted
    /// manager and the batch ids.
    func publishedButUncommitted(channel: SVRecordingChannel, history: [Message],
                                 seed: (() async throws -> Void)? = nil) async -> (ConversationManager, [UUID])? {
        let first = await freshManager(channel: channel, history: history, seed: seed)
        guard await startBackgroundJob(first, hold: []) else { return nil }
        let batch = first._baJobBatchIds
        guard await waitForJob(first, "succeeded") else { return nil }
        let restarted = await makeManager(channel: channel)
        return (restarted, batch)
    }

    func viewSection() async {
        // V1: published A + live A while the writer is busy (startup recovery
        // holds it for its whole pass): A is hidden, disclosed, not re-archived.
        let channel = SVRecordingChannel(kind: .telegram)
        guard let (manager, batch) = await publishedButUncommitted(channel: channel, history: archiveSizedHistory(),
                                                                   seed: { try await self.seedTemporaryChunks(2) }) else {
            check("BV1 setup", false); return
        }
        let archive = manager._testArchiveService
        let publishedCount = await archive.getAllChunks().count
        check("BV1 setup: after the restart the batch is live and its chunk published",
              contains(manager, batch) && publishedCount == 3, "\(publishedCount)")
        await archive._testAcquireWriter()
        let summariesBefore = router.summaries
        server.clear()
        await turn(manager, "turn while the writer is busy", reply: "busy reply")
        let busy = mainRequests.last
        let section = busy.map(archiveSection) ?? ""
        check("BV1 the published chunk overlapping live messages is left out of the archive table",
              !section.contains("Fixture summary #3") && section.contains("Fixture summary #1") && section.contains("Fixture summary #2"), section)
        check("BV1 the disclosure line says why, with the chunk's id and dates",
              section.contains("1 archived chunk(s) are left out of this table for now because some of their source messages are still in the live conversation"), section)
        check("BV1 the header counts only the shown chunks (\"Showing all 2\")", section.contains("Showing all 2 archived chunk(s)"), section)
        check("BV1 the live messages are still sent", busy.map { conversation($0).contains("end of old-0.") } == true)
        check("BV1 no second archive while rows await their commit", router.summaries == summariesBefore, "\(router.summaries - summariesBefore)")
        check("BV1 writer busy is a quiet deferral: no alert", !channel.delivered.contains { $0.contains("removing archived messages") },
              "\(channel.delivered)")
        await archive._testReleaseWriter()
        server.clear()
        await turn(manager, "turn after the writer is free", reply: "free reply")
        let free = mainRequests.first
        check("BV2 the next turn commits: batch removed, the row is back, no disclosure",
              containsNone(manager, batch) && free.map { archiveSection($0).contains("Fixture summary #3") && !archiveSection($0).contains("left out of this table") } == true)
        check("BV2 still no second summary", router.summaries == summariesBefore)

        await allHiddenSection()
        await revalidationSection()
        await coverageSection()
        await failedHistoryWriteSection()
        await pruneRequestViewSection()
    }

    /// V3: every row hidden — the section still renders the disclosure.
    private func allHiddenSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        guard let (manager, _) = await publishedButUncommitted(channel: channel, history: archiveSizedHistory()) else {
            check("BV3 setup", false); return
        }
        await manager._testArchiveService._testAcquireWriter()
        server.clear()
        await turn(manager, "all rows hidden", reply: "ok")
        let section = mainRequests.last.map(archiveSection) ?? ""
        check("BV3 all rows hidden: the archive section still renders with the disclosure",
              section.hasPrefix("## ARCHIVED CONVERSATION HISTORY") && section.contains("1 archived chunk(s) are left out")
                && !section.contains("| # | Type |"), section)
        await manager._testArchiveService._testReleaseWriter()
        // No overlap: the formatter output is exactly today's.
        let plain = ArchivedSummaryItem(id: UUID(), kind: .temporaryChunk, startDate: Date(), endDate: Date(), tokenCount: 10,
                                        messageCount: 2, summary: "plain", sourceChunkCount: 1)
        let service = OpenRouterService()
        let withNothing = await service.formatChunkSummaries([plain], totalChunkCount: 1)
        check("BV3 no disclosure item: no disclosure text and no change", !withNothing.contains("left out of this table"))
    }

    /// V4: a publication between commit check and view capture — the view is
    /// adopted only if the live id set did not change across its await.
    private func revalidationSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory(count: 4))
        var captures = 0
        ConversationManager.viewCaptureHookForTesting = { manager in
            captures += 1
            if captures == 1 {
                manager._testReplaceMessages(manager._testMessages + [Message(role: .assistant, content: "arrived during capture")])
            }
        }
        await turn(manager, "revalidate", reply: "ok")
        ConversationManager.viewCaptureHookForTesting = nil
        check("BV4 a view whose live set changed during its await is released and captured again", captures == 2, "\(captures)")
        check("BV4 only the adopted view's lease remains", await manager._testArchiveService._testLeaseCount == 1,
              "\(await manager._testArchiveService._testLeaseCount)")
    }

    /// V5: consolidated and meta rows are judged by source coverage.
    private func coverageSection() async {
        await resetState()
        do { try await seedTemporaryChunks(30, label: "cov") } catch { check("BV5 seed", false, "\(error)"); return }
        let archive = ConversationArchiveService()
        await archive.configure(apiKey: apiKey)
        _ = await archive.getPromptSummaryItems()   // meta refresh
        let chunks = await archive.getAllChunks()
        let consolidated = chunks.filter { $0.type == .consolidated }
        let fullView = await archive.promptView(liveIDs: [])
        let meta = fullView.items.first { $0.kind == .rollingMetaSummary || $0.kind == .sealedMetaSummary }
        guard let recent = consolidated.last, let recentSource = recent.sourceMessageIDs?.first,
              let meta, let child = meta.childChunkIds.first,
              let childSource = chunks.first(where: { $0.id == child })?.sourceMessageIDs?.first else {
            check("BV5 setup: consolidated chunks and a meta row exist", false,
                  "consolidated \(consolidated.count), items \(fullView.items.map(\.kind))"); return
        }
        let consolidatedView = await archive.promptView(liveIDs: [recentSource])
        check("BV5 a consolidated row is hidden when one of its (child) source messages is live",
              consolidatedView.hiddenRowIds == [recent.id] && !consolidatedView.items.contains { $0.id == recent.id }
                && consolidatedView.totalChunkCount == fullView.totalChunkCount - 1,
              "hidden \(consolidatedView.hiddenRowIds), totals \(consolidatedView.totalChunkCount)/\(fullView.totalChunkCount)")
        let metaView = await archive.promptView(liveIDs: [childSource])
        check("BV5 a meta row is hidden by its children's source coverage",
              metaView.hiddenRowIds == [meta.id] && metaView.totalChunkCount == fullView.totalChunkCount - max(meta.sourceChunkCount, 1),
              "hidden \(metaView.hiddenRowIds)")
        check("BV5 no overlap → exactly today's items and count",
              fullView.items.map(\.id) == (await archive.getPromptSummaryItems()).map(\.id) && fullView.totalChunkCount == chunks.count)
        for view in [fullView, consolidatedView, metaView] { await archive.releaseLease(view.leaseId) }
    }

    /// V6: a failed history write at the commit keeps the rows out next
    /// turn (frozen view) and commits on a later turn.
    private func failedHistoryWriteSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        _ = await startBackgroundJob(manager, hold: [])
        _ = await waitForJob(manager, "succeeded")
        let batch = manager._baJobBatchIds
        final class Box: @unchecked Sendable { var armed = false }
        let box = Box()
        ConversationManager.historyWriteFaultForTesting = {
            if box.armed { box.armed = false; throw ArchiveCommitRefusal("injected history write failure") }
        }
        server.clear()
        server.script([MidturnHarness.chatText("ok")])
        // Armed after the user message is saved: the commit's own write fails.
        manager._baStartTurn(for: Message(role: .user, content: "commit fails"), afterSave: { box.armed = true })
        _ = await manager._testAwaitIdle(timeout: 40)
        ConversationManager.historyWriteFaultForTesting = nil
        let section = mainRequests.last.map(archiveSection) ?? ""
        check("BV6 failed history write: the batch stays, the job is kept for a local retry",
              contains(manager, batch) && manager._baJobOutcome == "succeeded")
        check("BV6 ...and the new chunk stays out of automatic context (frozen view)", !section.contains("Fixture summary #1"), section)
        let summaries = router.summaries
        await turn(manager, "commit retried", reply: "ok")
        check("BV6 the next turn commits without another summary", containsNone(manager, batch) && router.summaries == summaries)
    }

    /// V7: a prune-summary request inside a hidden-row turn carries the same
    /// archive section (with the disclosure) as the main request.
    private func pruneRequestViewSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        guard let (manager, batch) = await publishedButUncommitted(channel: channel, history: detailHistory()) else {
            check("BV7 setup", false); return
        }
        let archive = manager._testArchiveService
        await archive._testAcquireWriter()
        server.script([chatText("primed", promptTokens: 260_000)])
        manager._testStartTurn(for: Message(role: .user, content: "prime the prompt tokens"))
        _ = await manager._testAwaitIdle(timeout: 40)
        server.clear()
        server.script([MidturnHarness.chatText("Prune summary of the older tool rounds."), MidturnHarness.chatText("after prune")])
        manager._testStartTurn(for: Message(role: .user, content: "this turn prunes first"))
        _ = await manager._testAwaitIdle(timeout: 60)
        let withSection = server.completeRequests.filter { system($0).contains("## ARCHIVED CONVERSATION HISTORY") }
        let sections = Set(withSection.map(archiveSection))
        let pruned = manager._testMessages.contains { $0.prunedContextSummary != nil }
        check("BV7 a pre-request prune ran in the hidden-row turn", pruned && withSection.count >= 2, "requests \(withSection.count)")
        check("BV7 the prune-summary and main requests carry one identical archive section with the disclosure",
              sections.count == 1 && (sections.first ?? "").contains("left out of this table"), "\(sections.count) distinct")
        let batchDetail = manager._testMessages.filter { batch.contains($0.id) && PruneArchiveStore.needsSnapshot([$0]) }
        let summaryInBatch = batchDetail.contains { $0.prunedContextSummary != nil }
        await archive._testReleaseWriter()
        await turn(manager, "commit after a prune", reply: "ok")
        let evidence = await archive.lastReconcileEvidence
        check("BV7 after the writer frees: committed after the prune (baseline B, no model call)",
              containsNone(manager, batch) && evidence.count == 1, "\(evidence)")
        check("BV7 a prune summary left on the batch postdates the receipt → saved in a fresh snapshot; none left → none needed",
              summaryInBatch ? (evidence.first?.covering != nil && evidence.first?.fresh != nil)
                             : (batchDetail.isEmpty ? evidence.first?.fresh == nil : evidence.first?.covering != nil),
              "summary in batch \(summaryInBatch), detail msgs \(batchDetail.count), \(evidence)")
    }
}
