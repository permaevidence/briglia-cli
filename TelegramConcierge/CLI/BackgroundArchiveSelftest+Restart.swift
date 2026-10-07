import Foundation

/// Plan §13 tests 11–13 (restart, baseline B), the Codex round-3 receipt
/// coverage tests (a)–(d), and the `.archiveCommit` alert episode.
extension BackgroundArchiveHarness {

    struct Published {
        let manager: ConversationManager
        let batch: [UUID]
        let receipt: PruneArchiveReference?
    }

    /// A detail-bearing batch archived by a real background job (real
    /// receipt), published, NOT committed; then a restart.
    func restartAfterPublish(_ channel: SVRecordingChannel, seed: (() async throws -> Void)? = nil,
                             beforeRestart: ((ConversationManager, [UUID], PruneArchiveReference?) async -> Void)? = nil) async -> Published? {
        let first = await freshManager(channel: channel, history: detailHistory(), seed: seed)
        guard await startBackgroundJob(first, hold: []), await waitForJob(first, "succeeded") else { return nil }
        let batch = first._baJobBatchIds
        let receipt = first._baJobReceipt
        await beforeRestart?(first, batch, receipt)
        let restarted = await makeManager(channel: channel)
        return Published(manager: restarted, batch: batch, receipt: receipt)
    }

    /// A small detail-bearing chunk with its OWN chunk-archive receipt,
    /// archived by a standalone service.
    func seedDetailChunk(label: String, base: Date) async throws -> PruneArchiveReference {
        var messages = ArchiveFullChunkSelftest.chunk(label, start: base, count: 2, messageSize: 400, sentinel: "end of \(label).")
        messages[1].toolInteractions = [toolRound(id: "\(label)-call", result: "SEED-DETAIL-\(label)")]
        let receipt = try PruneArchiveStore.write(messages: messages, trigger: "chunk-archive", removedIDs: messages.map(\.id), pin: true)
        defer { PruneArchiveStore.release(receipt) }
        let archive = ConversationArchiveService()
        await archive.configure(apiKey: apiKey)
        _ = try await archive.archiveMessages(messages, snapshot: receipt)
        return receipt
    }

    func snapshotText(_ id: UUID?) -> String {
        guard let id, let ref = ((try? PruneArchiveStore.entries()) ?? []).first(where: { $0.reference.id == id })?.reference else { return "" }
        return (try? String(contentsOf: PruneArchiveStore.root.appendingPathComponent(ref.basename), encoding: .utf8)) ?? ""
    }

    func restartSection() async {
        // R1: plain restart before removal → committed by coverage, no model.
        let channel = SVRecordingChannel(kind: .telegram)
        guard let p = await restartAfterPublish(channel) else { check("BR1 setup", false); return }
        let summaries = router.summaries
        check("BR1 setup: after the restart the archived batch is still live", contains(p.manager, p.batch))
        let status = await p.manager._baCommand("/status")
        check("BR1 /status after the restart: archived messages waiting to be removed",
              status.contains("(archived messages waiting to be removed)"), status)
        await turn(p.manager, "first turn after restart", reply: "ok")
        let evidence = await p.manager._testArchiveService.lastReconcileEvidence
        check("BR1 the covered oldest prefix was committed at the first turn, without a model call",
              containsNone(p.manager, p.batch) && router.summaries == summaries, "summaries +\(router.summaries - summaries)")
        check("BR1 baseline B accepted the archive-only receipt link; the receipt covers the batch",
              evidence.first?.covering == p.receipt?.id, "\(evidence)")
        let refs = await rawAnchorRefs(p.manager._testArchiveService, batch: p.batch)
        check("BR1 baseline B always saves the live detail in a fresh snapshot before removal (Codex impl review), linked from the archived copy",
              evidence.first?.fresh != nil && snapshotText(evidence.first?.fresh).contains("TOOL-RESULT-tool-1")
                && evidence.first?.fresh.map { refs.contains($0) } == true, "\(evidence)")
        check("BR1 the receipt stays reachable from the archived copy and is complete",
              p.receipt.map { refs.contains($0.id) && PruneArchiveStore.isCompleteSnapshot($0) } == true
                && snapshotText(p.receipt?.id).contains("TOOL-RESULT-tool-1"))

        // R2 = Codex (a): the receipt sits on a LATER child of a consolidated chunk.
        let ca = SVRecordingChannel(kind: .telegram)
        guard let pa = await restartAfterPublish(ca, seed: {
            try await self.seedTemporaryChunks(3, label: "older", base: Date().addingTimeInterval(-40 * 86_400))
            try await self.seedTemporaryChunks(2, label: "newer", base: Date().addingTimeInterval(-3_600))
        }) else { check("BR2 setup", false); return }
        let owners = await pa.manager._testArchiveService.coveringChunkIds(for: pa.batch)
        let chunk = (await pa.manager._testArchiveService.getAllChunks()).first { $0.id == owners[pa.batch[0]] }
        let raw = await pa.manager._testArchiveService._testRawMessages(chunkId: chunk?.id ?? UUID()) ?? []
        check("BR2 setup: the batch was consolidated as a later child (its receipt is not on the raw file's first message)",
              chunk?.type == .consolidated && raw.first.map { !pa.batch.contains($0.id) } == true
                && pa.receipt.map { r in !(raw.first?.pruneArchiveReferences.contains(r) ?? true) && raw.contains { $0.pruneArchiveReferences.contains(r) } } == true)
        await turn(pa.manager, "commit after consolidation", reply: "ok")
        let ea = await pa.manager._testArchiveService.lastReconcileEvidence
        check("BR2 (a) the covering receipt is found on the later child and accepted; the live detail is saved fresh",
              containsNone(pa.manager, pa.batch) && ea.first?.covering == pa.receipt?.id && ea.first?.fresh != nil, "\(ea)")

        // R9: a prune AFTER job start leaves a summary on the batch; after a
        // restart the covering receipt cannot hold it → fresh snapshot.
        let cp = SVRecordingChannel(kind: .telegram)
        guard let pp = await restartAfterPublish(cp, beforeRestart: { manager, _, _ in
            _ = try? await manager._testRetentionPrune(affected: [1], trigger: "automatic", summary: "LATE-PRUNE-SUMMARY")
        }) else { check("BR9 setup", false); return }
        check("BR9 setup: the batch carries a prune summary written after the job's receipt",
              pp.manager._testMessages.contains { pp.batch.contains($0.id) && $0.prunedContextSummary == "LATE-PRUNE-SUMMARY" })
        await turn(pp.manager, "commit after a late prune", reply: "ok")
        let e9 = await pp.manager._testArchiveService.lastReconcileEvidence
        check("BR9 restart: covering receipt found, the newer summary saved in a fresh snapshot before removal",
              containsNone(pp.manager, pp.batch) && e9.first?.covering == pp.receipt?.id && e9.first?.fresh != nil
                && snapshotText(e9.first?.fresh).contains("LATE-PRUNE-SUMMARY"), "\(e9)")

        await unrelatedReceiptSection()
        await missingReceiptSection(expired: false)
        await missingReceiptSection(expired: true)
        await failedWriteThenRestartSection()
        await contentChangeAfterRestartSection()
        await partialPrefixSection()
        await liveDetailChangedAfterRestartSection()
    }

    /// Codex impl review: after a restart the live messages hold tool-result
    /// text or readable reasoning that differs from the older covering
    /// receipt (saved history changed between publication and restart). The
    /// sanitized raw comparison cannot see those fields, so recovery must
    /// keep the batch or save the exact live detail before removing it.
    private func liveDetailChangedAfterRestartSection() async {
        for mode in ["tool", "reasoning", "reasoning-details"] {
            let label = "BR10 (\(mode))"
            let sentinel = "CODEX-LIVE-DETAIL-AFTER-ARCHIVE-" + mode
            let channel = SVRecordingChannel(kind: .telegram)
            guard let p = await restartAfterPublish(channel, beforeRestart: { _, batch, _ in
                let url = StoragePaths.dataRoot.appendingPathComponent("conversation.json")
                guard var history = try? JSONDecoder().decode([Message].self, from: Data(contentsOf: url)),
                      let i = history.firstIndex(where: { batch.contains($0.id) && !$0.toolInteractions.isEmpty }) else { return }
                switch mode {
                case "tool": history[i].toolInteractions = [self.toolRound(id: "tool-call-1", result: sentinel)]
                case "reasoning": history[i].finalReasoning = .string(sentinel)
                default: history[i].finalReasoningDetails = .string(sentinel)
                }
                try? JSONEncoder().encode(history).write(to: url)
            }) else { check("\(label) setup", false); return }
            check("\(label) setup: the changed detail is live after the restart and absent from the covering receipt",
                  String(data: ArchiveCommitCheck.encoded(p.manager._testMessages), encoding: .utf8)?.contains(sentinel) == true
                    && !snapshotText(p.receipt?.id).contains(sentinel))
            let summaries = router.summaries
            await turn(p.manager, "commit changed \(mode)", reply: "ok")
            let evidence = await p.manager._testArchiveService.lastReconcileEvidence
            let preserved = ((try? PruneArchiveStore.entries()) ?? []).contains { snapshotText($0.reference.id).contains(sentinel) }
            check("\(label) restart retains or snapshots the changed detail (Codex reproduction)",
                  contains(p.manager, p.batch) || preserved,
                  "live batch retained=\(contains(p.manager, p.batch)), fresh=\(String(describing: evidence.first?.fresh)), preserved=\(preserved)")
            let refs = await rawAnchorRefs(p.manager._testArchiveService, batch: p.batch)
            check("\(label) removed after a fresh snapshot holding the changed detail, linked from the archived copy, no model call",
                  containsNone(p.manager, p.batch) && evidence.first?.covering == p.receipt?.id
                    && snapshotText(evidence.first?.fresh).contains(sentinel)
                    && evidence.first?.fresh.map { refs.contains($0) } == true && router.summaries == summaries, "\(evidence)")
        }
    }

    /// Codex (b): an unrelated complete receipt on the first child does not
    /// establish coverage of the batch.
    private func unrelatedReceiptSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        final class Box: @unchecked Sendable { var seedReceipt: PruneArchiveReference? }
        let box = Box()
        guard let p = await restartAfterPublish(channel, seed: {
            box.seedReceipt = try await self.seedDetailChunk(label: "first", base: Date().addingTimeInterval(-41 * 86_400))
            try await self.seedTemporaryChunks(2, label: "older", base: Date().addingTimeInterval(-40 * 86_400))
            try await self.seedTemporaryChunks(2, label: "newer", base: Date().addingTimeInterval(-3_600))
        }, beforeRestart: { manager, batch, receipt in
            // Remove the batch's own receipt link (archived copy + record).
            guard let receipt else { return }
            await self.dropReference(receipt, chunkOf: batch, archive: manager._testArchiveService)
        }) else { check("BR3 setup", false); return }
        let owners = await p.manager._testArchiveService.coveringChunkIds(for: p.batch)
        let raw = await p.manager._testArchiveService._testRawMessages(chunkId: owners[p.batch[0]] ?? UUID()) ?? []
        check("BR3 setup: the first child carries its own complete receipt; the batch's link is gone",
              box.seedReceipt.map { r in raw.first?.pruneArchiveReferences.contains(r) == true && PruneArchiveStore.isCompleteSnapshot(r) } == true
                && p.receipt.map { r in !raw.contains { $0.pruneArchiveReferences.contains(r) } } == true)
        let summaries = router.summaries
        await turn(p.manager, "commit with only an unrelated receipt", reply: "ok")
        let evidence = await p.manager._testArchiveService.lastReconcileEvidence
        check("BR3 (b) the unrelated receipt is NOT accepted as coverage; the live detail is preserved in a fresh snapshot first",
              evidence.first?.covering == nil && evidence.first?.covering != box.seedReceipt?.id && evidence.first?.fresh != nil,
              "\(evidence)")
        check("BR3 the fresh snapshot carries the batch's tool detail; removal then proceeds with no model call",
              snapshotText(evidence.first?.fresh).contains("TOOL-RESULT-tool-1") && containsNone(p.manager, p.batch)
                && router.summaries == summaries)
    }

    func dropReference(_ ref: PruneArchiveReference, chunkOf batch: [UUID], archive: ConversationArchiveService) async {
        let owners = await archive.coveringChunkIds(for: batch)
        guard let chunkId = owners[batch[0]], let chunk = (await archive.getAllChunks()).first(where: { $0.id == chunkId }) else { return }
        let folder = StoragePaths.dataRoot.appendingPathComponent("archive")
        let rawURL = folder.appendingPathComponent(chunk.rawContentFileName)
        if var raw = try? JSONDecoder().decode([Message].self, from: Data(contentsOf: rawURL)) {
            for i in raw.indices { raw[i].pruneArchiveReferences.removeAll { $0.id == ref.id } }
            try? JSONEncoder().encode(raw).write(to: rawURL)
        }
        let indexURL = folder.appendingPathComponent("chunk_index.json")
        if var index = try? JSONDecoder().decode(ChunkIndex.self, from: Data(contentsOf: indexURL)) {
            for i in index.chunks.indices { index.chunks[i].pruneArchiveReferences?.removeAll { $0.id == ref.id } }
            try? JSONEncoder().encode(index).write(to: indexURL)
        }
    }

    /// Codex (c): the actual covering receipt missing (unexplained → refuse)
    /// or expired by retention (→ preserve the live detail first).
    private func missingReceiptSection(expired: Bool) async {
        let label = expired ? "BR5 (c) expired" : "BR4 (c) missing"
        let channel = SVRecordingChannel(kind: .telegram)
        guard let p = await restartAfterPublish(channel, beforeRestart: { _, _, receipt in
            guard let receipt else { return }
            if expired { try? SettlementEvidence.noteExpired([receipt.id], snapshots: PruneArchiveStore.root) }
            try? FileManager.default.removeItem(at: PruneArchiveStore.root.appendingPathComponent(receipt.basename))
        }) else { check("\(label) setup", false); return }
        let summaries = router.summaries
        await turn(p.manager, "commit without the receipt", reply: "ok")
        let evidence = await p.manager._testArchiveService.lastReconcileEvidence
        if expired {
            check("\(label): the live tool detail is preserved in a fresh snapshot before removal",
                  containsNone(p.manager, p.batch) && evidence.first?.fresh != nil
                    && snapshotText(evidence.first?.fresh).contains("TOOL-RESULT-tool-1"), "\(evidence)")
            let refs = await rawAnchorRefs(p.manager._testArchiveService, batch: p.batch)
            check("\(label): the fresh snapshot is linked from the archived copy", evidence.first?.fresh.map { refs.contains($0) } == true)
        } else {
            check("\(label): removal refused; the live messages keep their tool detail",
                  contains(p.manager, p.batch) && p.manager._testMessages.contains { $0.toolInteractions.first?.results.first?.content.hasPrefix("TOOL-RESULT-tool-1") == true })
            check("\(label): reported once on .archiveCommit", entryAlerts(channel).count == 1, "\(channel.delivered)")
        }
        check("\(label): no model request", router.summaries == summaries)
    }

    /// Codex (d): successful reconciliation, failed history write, restart.
    private func failedWriteThenRestartSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let first = await freshManager(channel: channel, history: detailHistory())
        _ = await startBackgroundJob(first, hold: [])
        _ = await waitForJob(first, "succeeded")
        let batch = first._baJobBatchIds
        final class Box: @unchecked Sendable { var armed = false }
        let box = Box()
        ConversationManager.historyWriteFaultForTesting = {
            if box.armed { box.armed = false; throw ArchiveCommitRefusal("injected history write failure") }
        }
        server.script([MidturnHarness.chatText("ok")])
        first._baStartTurn(for: Message(role: .user, content: "commit with a failing history write"), afterSave: { box.armed = true })
        _ = await first._testAwaitIdle(timeout: 30)
        ConversationManager.historyWriteFaultForTesting = nil
        check("BR6 (d) setup: the reconciliation saved, the history write failed, the batch is still on disk",
              batch.allSatisfy(diskIds().contains) && entryAlerts(channel).count == 1)
        let summaries = router.summaries
        let restarted = await makeManager(channel: channel)
        await turn(restarted, "after restart", reply: "ok")
        check("BR6 (d) after the restart baseline B accepts the merged archived copy: removed, no model call",
              containsNone(restarted, batch) && router.summaries == summaries)
        check("BR6 the alert closes once, on the successful commit", recoveryAlerts(channel).count == 1, "\(channel.delivered)")
    }

    /// An unrelated content change still refuses after a restart.
    private func contentChangeAfterRestartSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        guard let p = await restartAfterPublish(channel, beforeRestart: { _, batch, _ in
            let url = StoragePaths.dataRoot.appendingPathComponent("conversation.json")
            if var history = try? JSONDecoder().decode([Message].self, from: Data(contentsOf: url)),
               let i = history.firstIndex(where: { $0.id == batch[0] }) {
                history[i].content += " — edited after archiving"
                try? JSONEncoder().encode(history).write(to: url)
            }
        }) else { check("BR7 setup", false); return }
        await turn(p.manager, "commit with a changed message", reply: "ok")
        check("BR7 restart: a content change refuses removal and alerts", contains(p.manager, p.batch) && entryAlerts(channel).count == 1,
              "\(channel.delivered)")
    }

    /// Two covering parts. Turn 1: the first part is refused (alert opens).
    /// Turn 2: the first part commits, the second is refused — the alert
    /// must stay open. Turn 3: the remainder commits; only then it closes.
    private func partialPrefixSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let history = archiveSizedHistory(count: 6)
        await resetState()
        let archive = ConversationArchiveService()
        await archive.configure(apiKey: apiKey)
        do {
            _ = try await archive.archiveMessages(Array(history[0..<2]))
            _ = try await archive.archiveMessages(Array(history[2..<4]))
        } catch { check("BR8 setup", false, "\(error)"); return }
        var live = history
        live[1].content += " (changed)"
        live[3].content += " (changed)"
        let manager = await makeManager(channel: channel, history: live)
        await turn(manager, "both parts changed", reply: "ok")
        check("BR8 turn 1: the first part is refused, nothing removed, one alert",
              contains(manager, history.prefix(4).map(\.id)) && entryAlerts(channel).count == 1, "\(channel.delivered)")
        func repair(_ index: Int) {
            var repaired = manager._testMessages
            if let i = repaired.firstIndex(where: { $0.id == history[index].id }) { repaired[i].content = history[index].content }
            manager._testReplaceMessages(repaired)
            _ = manager._testSave()
        }
        repair(1)
        await turn(manager, "first part repaired", reply: "ok")
        check("BR8 turn 2: the first covered part commits; the refused second part stays live",
              containsNone(manager, [history[0].id, history[1].id]) && contains(manager, [history[2].id, history[3].id]))
        check("BR8 turn 2: the unresolved remainder keeps the alert open (no recovery after the first part)",
              entryAlerts(channel).count == 1 && recoveryAlerts(channel).isEmpty, "\(channel.delivered)")
        await MaintenanceAlertCenter.shared.reportSuccess(.conversationSummary)
        check("BR8 startup-recovery-style .conversationSummary success does not close it", recoveryAlerts(channel).isEmpty)
        repair(3)
        await turn(manager, "remainder repaired", reply: "ok")
        check("BR8 turn 3: the remainder commits and only then the alert closes, once",
              containsNone(manager, [history[2].id, history[3].id]) && recoveryAlerts(channel).count == 1, "\(channel.delivered)")
    }

    /// `.archiveCommit` episode: opens once, closes only on a successful
    /// commit — job success and startup recovery never close it.
    func alertSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        guard let p = await restartAfterPublish(channel, beforeRestart: { _, _, receipt in
            guard let receipt else { return }
            try? FileManager.default.removeItem(at: PruneArchiveStore.root.appendingPathComponent(receipt.basename))
        }) else { check("BL setup", false); return }
        await turn(p.manager, "refused 1", reply: "ok")
        await turn(p.manager, "refused 2", reply: "ok")
        check("BL1 two refusals: exactly one entry alert", entryAlerts(channel).count == 1, "\(channel.delivered)")
        await MaintenanceAlertCenter.shared.reportSuccess(.conversationSummary)
        check("BL2 a .conversationSummary success (job or startup recovery) does not close it", recoveryAlerts(channel).isEmpty)
        if let receipt = p.receipt { try? SettlementEvidence.noteExpired([receipt.id], snapshots: PruneArchiveStore.root) }
        await turn(p.manager, "committed", reply: "ok")
        check("BL3 a successful commit closes it, once", containsNone(p.manager, p.batch) && recoveryAlerts(channel).count == 1,
              "\(channel.delivered)")
        await turn(p.manager, "after", reply: "ok")
        check("BL3 no second recovery message", recoveryAlerts(channel).count == 1)
    }

    func receiptSection() async {
        // The (a)–(d) rows run inside restartSection; this section checks the
        // coverage reader on its own (integrity first, then coverage).
        await resetState()
        let ids = [UUID(), UUID()]
        let messages = ids.map { Message(id: $0, role: .user, content: "x") }
        guard let ref = try? PruneArchiveStore.write(messages: messages, trigger: "chunk-archive", removedIDs: ids) else {
            check("BS setup", false); return
        }
        check("BS1 a complete chunk-archive snapshot covers its removed ids", PruneArchiveStore.chunkArchiveSnapshotCovers(ref, ids: Set(ids)))
        check("BS1 ...but not other ids", !PruneArchiveStore.chunkArchiveSnapshotCovers(ref, ids: [UUID()]))
        guard let prune = try? PruneArchiveStore.write(messages: messages, trigger: "automatic", removedIDs: ids) else { return }
        check("BS2 a prune snapshot is not a chunk-archive receipt", !PruneArchiveStore.chunkArchiveSnapshotCovers(prune, ids: Set(ids)))
        let path = PruneArchiveStore.root.appendingPathComponent(ref.basename)
        if var data = try? Data(contentsOf: path) { data.removeLast(5); try? data.write(to: path) }
        check("BS3 an incomplete snapshot never counts as coverage", !PruneArchiveStore.chunkArchiveSnapshotCovers(ref, ids: Set(ids)))
    }
}
