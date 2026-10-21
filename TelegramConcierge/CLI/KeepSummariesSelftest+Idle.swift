import Foundation

/// K13 idle pass (preconditions, retriggers, attempt cache, budgets),
/// K11 archive interplay, K9 commits.
extension RetentionHarness {

    /// Anchors without stubs (as 0.2.57 left them): the idle pass's repair work.
    func unstubbedManager(_ count: Int = 3) async -> ConversationManager {
        let manager = await freshManager()
        var h: [Message] = []
        for i in 0..<count {
            h.append(user("U_R\(i)", at: at(2026, 9, 1 + i, 9, 0)))
            h.append(anchor("R\(i)", at: at(2026, 9, 1 + i, 10, 0)))
        }
        manager._testSeedHistory(h)
        return manager
    }

    func stubbedCount(_ manager: ConversationManager) -> Int {
        manager._testMessages.filter { $0.prunedContextSummaryStub?.isUsable(for: $0.prunedContextSummary) == true }.count
    }

    /// K13 preconditions.
    func idleBlockerSection() async throws {
        var blocked: [String] = []
        let blockers: [(String, (ConversationManager) -> () -> Void)] = [
            ("maintenance", { m in let id = m._testBeginMaintenance(); return { m._testEndMaintenance(id) } }),
            ("active turn", { m in m._testSetActiveRunPlaceholder(true); return { m._testSetActiveRunPlaceholder(false) } }),
            ("archive recovery", { m in m._testSetArchiveRecoveryPlaceholder(true); return { m._testSetArchiveRecoveryPlaceholder(false) } }),
            ("Mind restore", { m in _ = m.beginMindRestore(); return { m.endMindRestore() } }),
            ("persistence stall", { m in m._testSetRecoveryBlocked(true); return { m._testSetRecoveryBlocked(false) } }),
        ]
        for (name, apply) in blockers {
            let manager = await unstubbedManager()
            let undo = apply(manager)
            let before = encodedSorted(manager._testMessages)
            let report = manager.summaryRetentionIdlePass()
            if report.blocked == nil || encodedSorted(manager._testMessages) != before { blocked.append(name) }
            undo()
            let after = manager.summaryRetentionIdlePass()
            if after.stubsRepaired != 3 { blocked.append(name + " (after release: \(after))") }
        }
        check("K13a the idle pass never runs during maintenance, an active turn, archive recovery, a Mind restore or a persistence stall; it runs once released",
              blocked.isEmpty, blocked.joined(separator: ", "))

        // Retriggers: the pass is scheduled when a blocking owner releases its slot.
        ConversationManager.summaryRetentionIdlePassEnabled = true
        defer { ConversationManager.summaryRetentionIdlePassEnabled = false }
        var retriggered: [String] = []
        for (name, apply) in blockers where name != "active turn" && name != "persistence stall" {
            let manager = await unstubbedManager()
            let undo = apply(manager)
            manager._testScheduleIdlePass()
            for _ in 0..<5 { await Task.yield() }
            let whileBlocked = stubbedCount(manager)
            undo()
            if name == "archive recovery" { manager._testScheduleIdlePass() } // the task's own completion schedules it in production
            var ran = false
            for _ in 0..<50 { await Task.yield(); if stubbedCount(manager) == 3 { ran = true; break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            if whileBlocked != 0 || !ran { retriggered.append("\(name): blocked \(whileBlocked) ran \(ran)") }
        }
        check("K13b retrigger: maintenance ending and a Mind restore ending schedule the pass, which then repairs the stubs",
              retriggered.isEmpty, retriggered.joined(separator: "; "))
        // Turn end retriggers it too (a real turn).
        let manager = await unstubbedManager()
        server.router = { _ in (RetentionHarness.chat("ok", prompt: 100), 0) }
        await runTurn(manager, "turn end trigger")
        server.router = nil
        var turnRan = false
        for _ in 0..<50 { await Task.yield(); if stubbedCount(manager) == 3 { turnRan = true; break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        check("K13c the end of a turn schedules the idle pass", turnRan)
    }

    /// K13 attempt cache and budgets (8 MiB per file, 32 MiB per pass).
    func idleBudgetSection() async throws {
        // Attempt cache: a refused restore is not re-read until the history
        // is replaced.
        _ = await freshManager()
        let (legacy, _) = try legacySetup(edit: { h in h[1].prunedContextSummary = "alpha\nPrior pruning summary:\nbeta" })
        var manager = try await legacyManager(legacy)
        PruneSummaryRestore.indexCountForTesting = 0
        _ = manager.summaryRetentionIdlePass()
        let firstReads = PruneSummaryRestore.indexCountForTesting
        _ = manager.summaryRetentionIdlePass()
        let secondReads = PruneSummaryRestore.indexCountForTesting
        manager = await restart()
        _ = manager.summaryRetentionIdlePass()
        check("K13d attempt cache: a refused file is read once; not again until the history is replaced (restart re-reads it)",
              firstReads == 1 && secondReads == 1 && PruneSummaryRestore.indexCountForTesting == 2,
              "\(firstReads) \(secondReads) \(PruneSummaryRestore.indexCountForTesting)")

        // A 9 MiB snapshot is never read; its pointer stays and is cached.
        _ = await freshManager()
        let big = String(repeating: "B", count: 9 * 1024 * 1024)
        let (huge, _) = try legacySetup(edit: { h in h[1].compactToolLog = big })
        manager = try await legacyManager(huge, usage: nil)
        PruneSummaryRestore.indexCountForTesting = 0
        let hugeReport = manager.summaryRetentionIdlePass()
        check("K13e a snapshot over 8 MiB is skipped unread; the pointer stays",
              hugeReport.restored == 0 && hugeReport.refused == 2 && PruneSummaryRestore.indexCountForTesting == 0
              && records(manager._testMessages).count == 2, "\(hugeReport)")

        // Five ~7 MiB snapshots: four fit the 32 MiB pass, the fifth is
        // deferred untouched and restored at the next idle point.
        _ = await freshManager()
        var h: [Message] = []
        var snapshots: [PruneArchiveReference] = []
        let filler = String(repeating: "F", count: 7 * 1024 * 1024)
        for i in 0..<5 {
            var u = user("U_BIG\(i)", at: at(2026, 9, 1 + i, 9, 0)); u.content += filler
            let a = anchor("BIG\(i)", at: at(2026, 9, 1 + i, 10, 0))
            h.append(u); h.append(a)
        }
        for i in 0..<5 {
            var withFiller = h[2 * i + 1]; withFiller.compactToolLog = filler
            let ref = try PruneArchiveStore.write(messages: [withFiller], trigger: "manual", removedIDs: [withFiller.id],
                                                  leadNote: PruneSummaryRetention.snapshotLeadNote)
            snapshots.append(ref)
            LegacyDemotionOracle.demote(&h, selected: [2 * i + 1], snapshot: ref)
        }
        for i in 0..<5 { h[2 * i].content = "U_BIG\(i)" }
        manager = try await legacyManager(h, usage: nil)
        let pass1 = manager.summaryRetentionIdlePass()
        let pass2 = manager.summaryRetentionIdlePass()
        check("K13f budgets: four 7 MiB files fit the 32 MiB pass and are committed; the fifth is deferred untouched and restored at the next idle point",
              pass1.restored == 4 && pass1.deferred == 1 && pass1.bytes <= PruneSummaryRestore.maxPassBytes && pass2.restored == 1
              && records(manager._testMessages).isEmpty, "pass1 \(pass1) pass2 \(pass2)")

        // Stub repair output is capped while it is written.
        _ = await freshManager()
        var oversized: [Message] = [user("U_HUGE", at: at(2026, 9, 1, 9, 0)), anchor("HUGE", at: at(2026, 9, 1, 10, 0))]
        oversized[1].compactToolLog = String(repeating: "L", count: 33 * 1024 * 1024)
        manager = await freshManager()
        manager._testSeedHistory(oversized)
        let before = snapshotIDs()
        let capped = manager.summaryRetentionIdlePass()
        let again = manager.summaryRetentionIdlePass()
        check("K13g a stub snapshot that would exceed the pass budget is discarded while written (no file published), the anchor stays in full and is not retried in this history",
              capped.stubsRepaired == 0 && capped.deferred == 1 && snapshotIDs() == before
              && manager._testMessages[1].prunedContextSummaryStub == nil && again.deferred == 0 && again.stubsRepaired == 0,
              "\(capped) \(again)")
    }

    /// K13 startup scan: a stub whose snapshot is gone is repaired after a
    /// history replacement (restart), not only on digest mismatch.
    func idleTriggerSection() async throws {
        let manager = try await freshStubbed(4)
        _ = manager.summaryRetentionIdlePass() // consumes the load-time scan
        let stub = manager._testMessages[1].prunedContextSummaryStub!
        try FileManager.default.removeItem(at: snapshotDir.appendingPathComponent(stub.record.snapshot.basename))
        let digestOnly = manager.summaryRetentionIdlePass()
        let restarted = await restart()
        let scan = restarted.summaryRetentionIdlePass()
        let repaired = restarted._testMessages[1].prunedContextSummaryStub
        check("K13h a broken stub snapshot is found by the startup scan (not by digest) and repaired",
              digestOnly.stubsRepaired == 0 && scan.stubsRepaired == 4 && repaired != nil && repaired?.record.snapshot != stub.record.snapshot
              && PruneArchiveStore.isCompleteSnapshot(repaired!.record.snapshot), "\(digestOnly) \(scan)")
    }

    /// K11 archive interplay: reconciliation accepts stub changes; chunks
    /// never carry the field; protected stub snapshots can exceed 300.
    func archiveSection() async throws {
        let manager = try await freshStubbed(2)
        let start = manager._testMessages[1]
        var added = start; added.prunedContextSummaryStub = nil
        var replaced = start
        replaced.prunedContextSummaryStub = PruneSummaryRetention.makeStub(for: manager._testMessages, anchor: 1, snapshot: randomRef())
        var stale = start; stale.prunedContextSummaryStub = PruneSummaryStub(summary: "OLDER TEXT", record: start.prunedContextSummaryStub!.record)
        func delta(_ s: Message, _ l: Message) -> String? {
            ArchiveCommitCheck.baselineADelta(start: s, live: l, sanitize: ConversationArchiveService.sanitizedForArchive,
                                              stub: { ConversationManager.archivedStub(kind: $0, content: $1) })
        }
        check("K11a reconciliation (baseline A) accepts a stub set, replaced, or left stale between start and commit; detailDiffers ignores it",
              delta(added, start) == nil && delta(start, replaced) == nil && delta(start, stale) == nil
              && !ArchiveCommitCheck.detailDiffers(start: start, live: replaced))
        let sanitized = await manager._testArchiveService._testSanitizeForArchive(start)
        let needs = await manager._testArchiveService._testNeedsArchiveSanitization({ var m = Message(role: .assistant, content: "x"); m.prunedContextSummaryStub = start.prunedContextSummaryStub; return m }())
        check("K11b chunks exclude the stub (sanitized away; a message carrying only a stub still needs sanitizing)",
              sanitized.prunedContextSummaryStub == nil && needs)
        // More than 300 protected stub snapshots: none deleted, the
        // directory sits above 300 (documented soft limit).
        _ = await freshManager()
        var many: [Message] = []
        for i in 0..<305 {
            var a = anchor("P\(i)", at: at(2026, 1, 1, 0, 0).addingTimeInterval(Double(i) * 600))
            let ref = try PruneArchiveStore.write(messages: [a], trigger: "manual", removedIDs: [a.id], leadNote: PruneSummaryRetention.snapshotLeadNote)
            a.prunedContextSummaryStub = PruneSummaryRetention.makeStub(for: [a], anchor: 0, snapshot: ref)
            many.append(a)
        }
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(many), to: historyURL)
        _ = await restart()
        _ = try fillSnapshots(10)
        try PruneArchiveStore.retainLatest()
        let ids = snapshotIDs()
        check("K11c more than 300 protected stub snapshots: every one survives retention; only unprotected ones are deleted",
              many.allSatisfy { ids.contains($0.prunedContextSummaryStub!.record.snapshot.id) } && ids.count == 305, "\(ids.count)")
    }

    /// K9 commits (inline): stubs attached at commit, nosnapshot writes none,
    /// failure leaves none (also covered by retention R1/R4/R5).
    func commitSection() async throws {
        var manager = await freshManager(history: anchoredHistory(3))
        try await pruneLast(manager)
        let anchors = manager._testMessages.filter(PruneSummaryRetention.isFullAnchor)
        check("K9a inline commit: every source anchor has a usable stub after the prune, in one stub snapshot",
              anchors.count == 4 && anchors.allSatisfy { $0.prunedContextSummaryStub?.isUsable(for: $0.prunedContextSummary) == true }
              && Set(anchors.map { $0.prunedContextSummaryStub!.record.snapshot.id }).count == 1
              // The stub snapshot is never added to the references (default
              // request bytes unchanged).
              && anchors.allSatisfy { !$0.pruneArchiveReferences.contains($0.prunedContextSummaryStub!.record.snapshot) })
        manager = await freshManager(history: anchoredHistory(3))
        try await pruneLast(manager, noSnapshot: true)
        check("K9b /prune nosnapshot: no stub snapshot, so no stub", manager._testMessages.allSatisfy { $0.prunedContextSummaryStub == nil }
              && snapshotIDs().isEmpty)
        manager = await freshManager(history: anchoredHistory(3))
        var writes = 0
        PruneArchiveStore.faultForTesting = { stage in if stage == "write" { writes += 1; if writes == 2 { throw PruneArchiveStore.Failure("injected") } } }
        _ = try? await pruneLast(manager)
        PruneArchiveStore.faultForTesting = nil
        let noStub = manager._testMessages.allSatisfy { $0.prunedContextSummaryStub == nil }
        let shownFull = composed(manager._testMessages).filter(PruneSummaryRetention.isFullAnchor).count == 4
        let retried = manager.summaryRetentionIdlePass()
        check("K9c stub snapshot failure: no stub, every anchor shown in full, the prune committed; the idle pass retries",
              noStub && shownFull && retried.stubsRepaired == 4, "\(retried)")
    }
}
