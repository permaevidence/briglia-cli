import Foundation

/// K13 round-2 rows (Codex implementation review R1/R2): every snapshot
/// byte the idle pass writes is charged to its 32 MiB budget, including
/// discarded staging output; broken pointers found by the completeness scan
/// stay pending until their replacement is durably committed.
extension RetentionHarness {

    /// Counts actual write-syscall output, independently of the pass's meter.
    func measuringSnapshotWrites(_ body: () -> ConversationManager.SummaryRetentionPassReport) -> (ConversationManager.SummaryRetentionPassReport, Int) {
        var bytes = 0
        PruneArchiveStore.bytesWrittenForTesting = { bytes += $0 }
        defer { PruneArchiveStore.bytesWrittenForTesting = nil }
        let report = body()
        return (report, bytes)
    }

    /// Unstubbed anchors whose snapshot output is `logBytes` each.
    func heavyUnstubbed(_ count: Int, logBytes: Int) async -> ConversationManager {
        let manager = await unstubbedManager(count)
        var h = manager._testMessages
        for i in h.indices where PruneSummaryRetention.isFullAnchor(h[i]) {
            h[i].compactToolLog = String(repeating: "L", count: logBytes)
        }
        manager._testSeedHistory(h)
        return manager
    }

    /// R1: aggregate output, oversized items, partial-write failure.
    func idleBudgetAccountingSection() async throws {
        let cap = PruneSummaryRestore.maxPassBytes
        // Codex's reproduction: two 33 MiB anchors in one pass.
        var manager = await heavyUnstubbed(2, logBytes: 33 * 1024 * 1024)
        var before = snapshotIDs()
        let (two, twoBytes) = measuringSnapshotWrites { manager.summaryRetentionIdlePass() }
        let (next, nextBytes) = measuringSnapshotWrites { manager.summaryRetentionIdlePass() }
        let (third, thirdBytes) = measuringSnapshotWrites { manager.summaryRetentionIdlePass() }
        check("K13i two anchors each over a fresh pass: actual snapshot output (discarded staging included) stays within 32 MiB per pass and is reported; each item is tried once with a fresh budget, then marked unsupported and never retried",
              twoBytes <= cap && two.bytes == twoBytes && two.deferred == 2 && two.stubsRepaired == 0
              && nextBytes <= cap && next.bytes == nextBytes && next.deferred == 1
              && thirdBytes == 0 && third.deferred == 0 && snapshotIDs() == before
              && manager._testMessages.allSatisfy { $0.prunedContextSummaryStub == nil },
              "pass1 \(two) actual \(twoBytes); pass2 \(next) actual \(nextBytes); pass3 \(third) actual \(thirdBytes)")

        // Several oversized anchors: one pass never writes more than the cap.
        manager = await heavyUnstubbed(4, logBytes: 20 * 1024 * 1024)
        before = snapshotIDs()
        var passes: [(ConversationManager.SummaryRetentionPassReport, Int)] = []
        for _ in 0..<6 { passes.append(measuringSnapshotWrites { manager.summaryRetentionIdlePass() }) }
        check("K13j four ~20 MiB anchors: every pass's actual snapshot output ≤ 32 MiB and equals its report; one repair per pass (the next one is cut off by the remainder and deferred, not marked unsupported); all four repaired within four passes",
              passes.allSatisfy { $0.1 <= cap && $0.0.bytes == $0.1 } && passes.prefix(4).allSatisfy { $0.0.stubsRepaired == 1 }
              && passes.dropFirst(4).allSatisfy { $0.1 == 0 } && stubbedCount(manager) == 4,
              passes.map { "\($0.0.stubsRepaired)/\($0.0.deferred)/\($0.1)" }.joined(separator: " "))

        // Partial write failure: the staging output already written counts,
        // the pass stops, and the work is retried later.
        manager = await heavyUnstubbed(3, logBytes: 4 * 1024 * 1024)
        var failedBytes = 0, attempts = 0
        PruneArchiveStore.bytesWrittenForTesting = { failedBytes += $0 }
        PruneArchiveStore.faultForTesting = { stage in
            if stage == "write" { attempts += 1 }
            if stage == "emit", failedBytes >= 1024 * 1024 + 512 * 1024 { throw PruneArchiveStore.Failure("injected mid-write failure") }
        }
        let failed = manager.summaryRetentionIdlePass()
        PruneArchiveStore.faultForTesting = nil
        PruneArchiveStore.bytesWrittenForTesting = nil
        let (retry, retryBytes) = measuringSnapshotWrites { manager.summaryRetentionIdlePass() }
        check("K13k a write that fails part-way: the bytes already written are charged and reported (≥ 1 MiB here), the pass stops (no other anchor attempted), nothing is published; the next idle point repairs all three",
              failedBytes >= 1024 * 1024 && failed.bytes == failedBytes && attempts == 1 && failed.stubsRepaired == 0 && failed.deferred == 3
              && retry.stubsRepaired == 3 && retry.bytes == retryBytes && retryBytes <= cap && stubbedCount(manager) == 3,
              "failed \(failed) actual \(failedBytes) attempts \(attempts); retry \(retry) actual \(retryBytes)")
    }

    /// A stubbed history whose shared stub snapshot was deleted, with the
    /// completeness scan armed (as after a restart or Mind import).
    func brokenStubbed(_ count: Int, logBytes: Int? = nil) async throws -> (ConversationManager, PruneArchiveReference) {
        let manager = try await freshStubbed(count)
        if let logBytes {
            var h = manager._testMessages
            for i in h.indices where PruneSummaryRetention.isFullAnchor(h[i]) { h[i].compactToolLog = String(repeating: "D", count: logBytes) }
            manager._testSeedHistory(h)
        }
        let ref = manager._testMessages[1].prunedContextSummaryStub!.record.snapshot
        try FileManager.default.removeItem(at: snapshotDir.appendingPathComponent(ref.basename))
        manager._testMarkScanPending()
        return (manager, ref)
    }

    func brokenCount(_ manager: ConversationManager) -> Int {
        manager._testMessages.filter {
            guard let stub = $0.prunedContextSummaryStub else { return false }
            return !PruneArchiveStore.isCompleteSnapshot(stub.record.snapshot)
        }.count
    }

    /// R2: snapshot failure and budget deferral keep the scan pending.
    func idleRetrySection() async throws {
        // Codex's transient-failure reproduction.
        var (manager, _) = try await brokenStubbed(4)
        PruneArchiveStore.faultForTesting = { stage in if stage == "write" { throw PruneArchiveStore.Failure("transient") } }
        let failed = manager.summaryRetentionIdlePass()
        PruneArchiveStore.faultForTesting = nil
        let retried = manager.summaryRetentionIdlePass()
        let settled = manager.summaryRetentionIdlePass()
        check("K13l startup scan + snapshot write failure: nothing repaired, the scan stays pending; the next idle point repairs all four, then the scan is done",
              failed.stubsRepaired == 0 && failed.deferred == 4 && retried.stubsRepaired == 4 && brokenCount(manager) == 0
              && settled == ConversationManager.SummaryRetentionPassReport(), "\(failed) \(retried) \(settled)")

        // Codex's budget reproduction: five 7 MiB anchors, four fit.
        (manager, _) = try await brokenStubbed(5, logBytes: 7 * 1024 * 1024)
        let first = manager.summaryRetentionIdlePass()
        let second = manager.summaryRetentionIdlePass()
        check("K13m startup scan + budget deferral: four repaired, the fifth deferred and repaired at the next idle point",
              first.stubsRepaired == 4 && first.deferred == 1 && second.stubsRepaired == 1 && brokenCount(manager) == 0,
              "\(first) \(second)")
    }

    /// R2: both history-write failure seams keep the scan pending.
    func idleHistoryRetrySection() async throws {
        for (name, pre) in [("before replacement", true), ("after replacement", false)] {
            let (manager, _) = try await brokenStubbed(3)
            if pre { ConversationManager.historyWriteFaultForTesting = { throw PruneArchiveStore.Failure("injected history fault") } }
            else { ConversationManager.historyPostWriteFaultForTesting = { throw PruneArchiveStore.Failure("injected post-write fault") } }
            let failed = manager.summaryRetentionIdlePass()
            ConversationManager.historyWriteFaultForTesting = nil
            ConversationManager.historyPostWriteFaultForTesting = nil
            let stillBroken = brokenCount(manager)
            let retried = manager.summaryRetentionIdlePass()
            let diskBroken = (diskHistory() ?? []).filter {
                guard let stub = $0.prunedContextSummaryStub else { return false }
                return !PruneArchiveStore.isCompleteSnapshot(stub.record.snapshot)
            }.count
            check("K13n startup scan + history write failure \(name): memory keeps the broken pointers and the scan stays pending; the next idle point repairs and commits all three",
                  failed.historyWriteFailed && stillBroken == 3 && retried.stubsRepaired == 3 && brokenCount(manager) == 0 && diskBroken == 0,
                  "\(failed) broken \(stillBroken) retry \(retried) disk \(diskBroken)")
        }
    }
}
