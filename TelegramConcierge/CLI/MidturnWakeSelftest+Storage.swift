import Foundation

/// Round-3 storage-recovery rows (release 1a review, rows CR*): unreadable
/// files are never evidence of absence.
///   CR1 — while crash records are unreadable, a completion notice (whose id
///         may be the only deduplication proof) never leaves history;
///   CR2 — an unreadable conversation.json is not an empty history: nothing
///         is published or retired against it, and nothing overwrites it
///         until a successful reread or an explicit reset.
/// Each finding has a healthy-storage control beside it (CR0, CR0b).
extension MidturnHarness {

    func storageSection() async throws {
        try await unreadableRecordRows()
        try await unreadableHistoryRows()
    }

    private var historyURL: URL { StoragePaths.dataRoot.appendingPathComponent("conversation.json") }

    /// A notice already durable in history while its record is still owed —
    /// the state a failed delivered-state write leaves behind.
    private func durableNotice(_ manager: ConversationManager) throws -> (DetachedJobRecord, Message) {
        let record = Self.record(instance: DetachedJobStore.instanceId)
        try DetachedJobStore.create(record)
        let notice = Message(id: record.completionMessageId, role: .user,
                             content: "already delivered completion", kind: .bashComplete)
        manager._testReplaceMessages([notice])
        _ = manager._testSave()
        return (record, notice)
    }

    // MARK: CR1 — unreadable records

    private func unreadableRecordRows() async throws {
        // CR0 control: readable records settle the notice before removal,
        // and a restart after archiving publishes nothing.
        do {
            let manager = await freshManager()
            let (record, notice) = try durableNotice(manager)
            try manager._testSettleBeforeRemoval([notice])
            manager._testReplaceMessages([])
            _ = manager._testSave()
            let recovered = await restart()
            check("CR0 control: readable records settle the notice before removal",
                  records().isEmpty && recovered._testMessages.allSatisfy { $0.id != record.completionMessageId })
        }
        // CR1/CR1b: the reproduction — records temporarily unreadable, the
        // archive is attempted, the file is repaired, Briglia restarts.
        do {
            let manager = await freshManager()
            let (record, notice) = try durableNotice(manager)
            let savedRecords = try Data(contentsOf: DetachedJobStore.fileURL)
            try Data("unreadable record file".utf8).write(to: DetachedJobStore.fileURL)
            var refused = false
            do { try manager._testSettleBeforeRemoval([notice]) } catch { refused = true }
            check("CR1 unreadable records prevent removing a durable completion notice", refused)
            if !refused {
                _ = try snapshot(durable: [notice], trigger: "chunk-archive")
                manager._testReplaceMessages([])
                _ = manager._testSave()
            }
            try savedRecords.write(to: DetachedJobStore.fileURL)
            let recovered = await restart()
            // Refused → the kept notice settles the record (one copy). Had
            // it been archived, any copy in live history would be a
            // redelivery — so the expected count follows the gate.
            let copies = recovered._testMessages.filter { $0.id == record.completionMessageId }.count
            check("CR1b repaired records + restart: the notice is never redelivered",
                  refused && copies == 1 && records().isEmpty,
                  "refused \(refused), copies \(copies), records \(records().count)")
        }
        // CR1c: the state produced by the production path — the save that
        // carried the notice succeeded, the delivered-state record write
        // failed — then records unreadable: the notice still stays.
        do {
            let manager = await freshManager()
            let record = Self.record(instance: DetachedJobStore.instanceId)
            try DetachedJobStore.create(record)
            let notice = Message(id: record.completionMessageId, role: .user, content: "notice", kind: .bashComplete)
            manager._testReplaceMessages([notice])
            manager._testExpectCompletionAck(messageId: notice.id, jobId: record.jobId)
            struct Injected: Error {}
            DetachedJobStore.faultForTesting = { if $0 == "delivered" { throw Injected() } }
            let saved = manager._testSave()
            DetachedJobStore.faultForTesting = nil
            let stillOwed = records().first?.completion == .owed
            try Data("unreadable".utf8).write(to: DetachedJobStore.fileURL)
            var refused = false
            do { try manager._testSettleBeforeRemoval([notice]) } catch { refused = true }
            check("CR1c history saved + delivered write failed + records unreadable → notice kept",
                  saved && stillOwed && refused, "saved \(saved), owed \(stillOwed), refused \(refused)")
            try? FileManager.default.removeItem(at: DetachedJobStore.fileURL)
        }
        // CR1d control: the conservative rule is scoped — with records
        // unreadable, a message that carries no binding, route or notice
        // may still leave.
        do {
            let manager = await freshManager()
            _ = try durableNotice(manager)
            try Data("unreadable".utf8).write(to: DetachedJobStore.fileURL)
            let plain = Self.assistant("plain reply", rounds: [Self.round(callId: "p1", binding: nil)])
            var refused = false
            do { try manager._testSettleBeforeRemoval([plain]) } catch { refused = true }
            check("CR1d control: unreadable records still allow removing a message without notice/binding/route", !refused)
            try? FileManager.default.removeItem(at: DetachedJobStore.fileURL)
        }
    }

    // MARK: CR2 — unreadable history

    /// A saved typed receipt whose certificate write failed: the record is
    /// still owed though history proves nothing is.
    private func observedReceiptWithFailedCertificate() async throws -> DetachedJobRecord {
        let manager = await freshManager()
        let record = Self.record(instance: DetachedJobStore.instanceId)
        try DetachedJobStore.create(record)
        let carrier = Self.assistant("saved receipt", rounds: [Self.round(callId: "observed",
            binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId))])
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { if $0 == "certify" { throw Injected() } }
        manager._testReplaceMessages([carrier])
        _ = manager._testSave()
        DetachedJobStore.faultForTesting = nil
        return record
    }

    private func unreadableHistoryRows() async throws {
        let broken = Data("unreadable history; preserve for repair".utf8)
        // CR0b control: readable history settles the observed receipt.
        do {
            let record = try await observedReceiptWithFailedCertificate()
            let owedBefore = records().first?.completion == .owed
            let recovered = await restart()
            check("CR0b control: readable history settles the observed receipt",
                  owedBefore && records().isEmpty && recovered._testMessages.allSatisfy { $0.id != record.completionMessageId }
                    && recovered._testHistoryLoadFailure == nil)
        }
        // CR2/CR2b/CR2c: the reproduction.
        let record = try await observedReceiptWithFailedCertificate()
        let good = try Data(contentsOf: historyURL)
        try broken.write(to: historyURL)
        let recovered = await restart()
        check("CR2 unreadable history does not publish an already observed result",
              recovered._testMessages.allSatisfy { $0.id != record.completionMessageId })
        check("CR2b unreadable history is preserved for repair", (try? Data(contentsOf: historyURL)) == broken)
        check("CR2c unreadable history retains the unresolved job record",
              records().contains { $0.jobId == record.jobId && $0.completion == .owed })
        // CR2d: no later write replaces it — an ordinary save is refused.
        recovered._testReplaceMessages([user("a new message while history is unreadable")])
        let saved = recovered._testSave()
        check("CR2d while unreadable, an ordinary save is refused and the file bytes are unchanged",
              !saved && (try? Data(contentsOf: historyURL)) == broken)
        // CR2e: removal gates refuse (archive/prune cannot rewrite it).
        var refused = false
        do { try recovered._testSettleBeforeRemoval([]) } catch { refused = true }
        check("CR2e while unreadable, the archive/prune removal gate refuses", refused)
        // CR2f: an explicit stale startup pass (queue file + turn marker)
        // keeps both files and starts nothing.
        // Rows below are independent of CR2d's outcome: re-seed the file.
        try broken.write(to: historyURL)
        let queued = user("queued before the crash")
        recovered._testPersistQueue([queued])
        recovered._testWriteActiveTurnMarker(for: queued)
        server.clear()
        let again = await restart()
        again._testStartupPasses()
        let queueKept = FileManager.default.fileExists(atPath: again._testPendingMidTurnURL.path)
        let markerKept = FileManager.default.fileExists(atPath: again._testActiveTurnMarkerURL.path)
        check("CR2f startup passes defer: queue file and turn marker kept, no turn started, record owed",
              queueKept && markerKept && server.completeRequests.isEmpty
                && records().contains { $0.jobId == record.jobId && $0.completion == .owed }
                && (try? Data(contentsOf: historyURL)) == broken,
              "queue \(queueKept), marker \(markerKept), requests \(server.completeRequests.count)")
        // CR2g: checkpoint recovery cannot clear the history-load failure —
        // a valid salvage file is present, recovery runs, the flag stays.
        try? FileManager.default.removeItem(at: again._testPendingMidTurnURL)
        try? FileManager.default.removeItem(at: again._testActiveTurnMarkerURL)
        let salvage = [Self.round(callId: "s1", content: "{\"status\":\"exited\"}", binding: nil)]
        try JSONEncoder().encode(salvage).write(to: again._testSalvageURL)
        let withSalvage = await restart()
        check("CR2g checkpoint recovery does not clear the history-load failure; salvage and history kept",
              withSalvage._testHistoryLoadFailure != nil && withSalvage._testRecoveryBlocked
                && FileManager.default.fileExists(atPath: withSalvage._testSalvageURL.path)
                && (try? Data(contentsOf: historyURL)) == broken)
        try? FileManager.default.removeItem(at: withSalvage._testSalvageURL)
        // CR2h: repair + restart (successful reread) → the receipt settles
        // normally: nothing published, record retired, flag cleared.
        try good.write(to: historyURL)
        let repaired = await restart()
        check("CR2h after repair + restart: receipt settles, nothing published, failure cleared",
              records().isEmpty && repaired._testMessages.allSatisfy { $0.id != record.completionMessageId }
                && repaired._testHistoryLoadFailure == nil)
        // CR2i: explicit reset — /deleteuserdata replaces an unreadable
        // history by request and clears the failure.
        do {
            _ = await freshManager()
            try broken.write(to: historyURL)
            let unreadable = await restart()
            let before = unreadable._testHistoryLoadFailure != nil
            let failures = await unreadable.deleteAllMemory()
            let bytes = (try? Data(contentsOf: historyURL)) ?? Data()
            let decoded = (try? JSONDecoder().decode([Message].self, from: bytes)) != nil
            check("CR2i /deleteuserdata is the explicit reset: failure cleared, empty history written",
                  before && unreadable._testHistoryLoadFailure == nil && decoded && bytes != broken,
                  "before \(before), failures \(failures)")
            try configureProvider()
        }
    }
}
