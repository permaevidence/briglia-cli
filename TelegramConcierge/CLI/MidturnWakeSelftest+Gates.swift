import Foundation

/// Codex V7 acceptance gates 1 and 2 as permanent rows.
extension MidturnHarness {

    // MARK: Gate 1 — settlement progresses monotonically moved → observed

    func gateOneSection() async throws {
        let trigger = user("trigger")
        let body = "[BACKGROUND BASH COMPLETE]\n\nhandle: bash_9\nstatus: exited cleanly"
        let launchFP = OutcomeBinding.fingerprint(toolName: "bash", arguments: "{\"command\":\"make\",\"wait_seconds\":60}")

        // G1a: moved certified; later a wait result observing J is saved;
        // the certificate upgrade write fails; crash before the registry
        // acknowledgement → restart delivers nothing.
        do {
            let manager = await freshManager(history: [trigger])
            var record = Self.record(body: body, fingerprint: launchFP, callId: "call-launch", instance: DetachedJobStore.instanceId)
            record.certifiedKind = .moved
            try DetachedJobStore.create(record)
            let launch = Self.assistant("launched", rounds: [Self.round(callId: "call-launch",
                binding: OutcomeBinding(kind: .moved, jobId: record.jobId, fingerprint: launchFP),
                arguments: "{\"command\":\"make\",\"wait_seconds\":60}")])
            let wait = Self.assistant("observed", rounds: [Self.round(callId: "call-wait",
                binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId), name: "bash_manage",
                arguments: "{\"mode\":\"wait\",\"handle\":\"bash_9\",\"wait_seconds\":30}")])
            struct Injected: Error {}
            DetachedJobStore.faultForTesting = { if $0 == "certify" { throw Injected() } }
            manager._testReplaceMessages([trigger, launch, wait])
            let saved = manager._testSave()
            DetachedJobStore.faultForTesting = nil
            let stillMoved = records().first?.certifiedKind == .moved
            let restarted = await restart()
            restarted._testStartupPasses()
            _ = await restarted._testAwaitIdle(timeout: 5)
            check("G1a moved certified + saved receipt + failed upgrade + crash → zero notices on restart",
                  saved && stillMoved && delivered(restarted, record) == 0 && records().isEmpty
                    && !restarted._testMessages.contains { $0.content.contains("[BACKGROUND BASH LOST]") })
        }
        // G1b: the receipt evidence was compacted into the turn's snapshot
        // chain (carried, owning context) — same outcome.
        do {
            await resetState()
            var record = Self.record(body: body, fingerprint: launchFP, callId: "call-launch")
            record.certifiedKind = .moved
            let first = try snapshot(carried: [Self.round(callId: "call-wait",
                binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId), name: "bash_manage")])
            let second = try snapshot(carried: [Self.round(callId: "call-other", binding: nil)], prior: compaction(first))
            var outcome = Self.assistant("outcome", rounds: [Self.round(callId: "call-launch",
                binding: OutcomeBinding(kind: .moved, jobId: record.jobId, fingerprint: launchFP))])
            outcome.activeTurnCompaction = compaction(second, through: 2)
            let manager = try await reconcileKeepingSnapshots(history: [trigger, outcome], records: [record])
            check("G1b receipt compacted two snapshots deep (owning chain) still settles", delivered(manager, record) == 0 && records().isEmpty)
        }
        // G1c: reverse evidence order — the receipt appears BEFORE the moved
        // result in enumeration; the strongest binding still wins.
        do {
            let record = Self.record(body: body, callId: "call-launch")
            let receiptFirst = Self.assistant("r", rounds: [Self.round(callId: "call-wait",
                binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId), name: "bash_manage")])
            let movedLater = Self.assistant("m", rounds: [Self.round(callId: "call-launch",
                binding: OutcomeBinding(kind: .moved, jobId: record.jobId))])
            let m1 = try await reconcile(history: [trigger, receiptFirst, movedLater], records: [record])
            let record2 = Self.record(body: body, callId: "call-launch")
            let moved2 = Self.assistant("m", rounds: [Self.round(callId: "call-launch", binding: OutcomeBinding(kind: .moved, jobId: record2.jobId))])
            let receipt2 = Self.assistant("r", rounds: [Self.round(callId: "call-wait",
                binding: OutcomeBinding(kind: .receiptObserved, jobId: record2.jobId), name: "bash_manage")])
            let m2 = try await reconcile(history: [trigger, moved2, receipt2], records: [record2])
            check("G1c evidence order does not matter: receipt settles in both enumerations",
                  delivered(m1, record) == 0 && delivered(m2, record2) == 0)
        }
        // G1g: a durable receipt settles the job even when another source
        // on the path is unverifiable (a snapshot whose sidecar was deleted):
        // the receipt is the final fact, so nothing is owed or reported.
        do {
            await resetState()
            let record = Self.record(body: body, callId: "call-launch")
            let broken = try snapshot(carried: [Self.round(callId: "call-launch",
                binding: OutcomeBinding(kind: .moved, jobId: record.jobId))])
            try FileManager.default.removeItem(at: SettlementEvidence.sidecarURL(broken.id))
            var outcome = Self.assistant("outcome", rounds: [])
            outcome.activeTurnCompaction = compaction(broken)
            let receipt = Self.assistant("r", rounds: [Self.round(callId: "call-wait",
                binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId), name: "bash_manage")])
            let manager = try await reconcileKeepingSnapshots(history: [trigger, outcome, receipt], records: [record])
            check("G1g receipt + an unverifiable source elsewhere → settled (zero notices, record retired)",
                  delivered(manager, record) == 0 && records().isEmpty)
        }
        // G1d: fingerprint scope — the wait call's receipt is never checked
        // against the launch fingerprint.
        do {
            let record = Self.record(body: body, fingerprint: launchFP, callId: "call-launch")
            let wait = Self.assistant("w", rounds: [Self.round(callId: "call-wait",
                binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId), name: "bash_manage",
                arguments: "{\"mode\":\"wait\"}")])
            let manager = try await reconcile(history: [trigger, wait], records: [record])
            check("G1d a receipt observed by a different call settles despite the launch fingerprint", delivered(manager, record) == 0)
        }
        // G1e: both provider transports' saved shapes — Responses keeps the
        // placeholder of the round alongside the real receipt result.
        do {
            let record = Self.record(body: body)
            let placeholder = Self.round(callId: "call-wait", content: "[Interrupted tool intent: outcome unknown.]",
                                         binding: OutcomeBinding(kind: .interruptedIntent))
            let real = Self.round(callId: "call-wait", binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId), name: "bash_manage")
            let responses = try await reconcile(history: [trigger, Self.assistant("salvage", rounds: [placeholder]),
                                                          Self.assistant("final", rounds: [real])], records: [record])
            check("G1e Responses shape (placeholder + real receipt) settles; placeholder never reverses it",
                  delivered(responses, record) == 0)
        }
        // G1f: runtime — a later save certifies the upgrade and withdraws
        // the live notice (no in-memory receipt needed).
        do {
            let manager = await freshManager(history: [trigger])
            var record = Self.record(body: body, instance: DetachedJobStore.instanceId)
            record.certifiedKind = .moved
            try DetachedJobStore.create(record)
            manager._testReplaceMessages([trigger, Self.assistant("w", rounds: [Self.round(callId: "call-wait",
                binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId), name: "bash_manage")])])
            _ = manager._testSave()
            check("G1f runtime save upgrades moved → receiptObserved and retires the record", records().isEmpty)
        }
    }

    // MARK: Gate 2 — retention preserves the whole discovery path

    func gateTwoSection() async throws {
        let trigger = user("trigger")
        let body = "[BACKGROUND BASH COMPLETE]\n\nhandle: bash_9"

        // G2a: C → B → A (A holds J's receipt, carried); retention pressure
        // keeps all three; unrelated old snapshots are removed.
        await resetState()
        var old: [PruneArchiveReference] = []
        for _ in 0..<4 { old.append(try snapshot(durable: [trigger], trigger: "automatic")) }
        let record = Self.record(body: body)
        try DetachedJobStore.create(record)
        let a = try snapshot(carried: [Self.round(callId: "call-w", binding: OutcomeBinding(kind: .receiptObserved, jobId: record.jobId), name: "bash_manage")])
        let b = try snapshot(carried: [Self.round(callId: "call-1", binding: nil)], prior: compaction(a))
        let c = try snapshot(carried: [Self.round(callId: "call-2", binding: nil)], prior: compaction(b, through: 2))
        try PruneArchiveStore.retainLatest(limit: 2)
        let live = Set((try? PruneArchiveStore.entries().map(\.reference.id)) ?? [])
        check("G2a retention keeps the proof AND every intermediate link (C→B→A)",
              live.isSuperset(of: [a.id, b.id, c.id]))
        check("G2b unrelated older snapshots are still expired", old.allSatisfy { !live.contains($0.id) })
        // Discovery still works after repeated restarts.
        var outcome = Self.assistant("outcome", rounds: [])
        outcome.activeTurnCompaction = compaction(c, through: 3)
        let m1 = try await reconcileKeepingSnapshots(history: [trigger, outcome], records: [])
        let located = SettlementEvidence.locate(record, history: m1._testMessages)
        check("G2c the proof stays discoverable from the durable root after retention and restart",
              located == .bound(.receiptObserved))
        // G2d: removal of a non-entry intermediate (B) by hand → the job is
        // unverifiable, never absent.
        try FileManager.default.removeItem(at: PruneArchiveStore.root.appendingPathComponent(b.basename))
        let broken = SettlementEvidence.locate(record, history: [trigger, outcome])
        var unverifiable = false
        if case .unverifiable = broken { unverifiable = true }
        check("G2d intermediate removed by hand → unverifiable (obligation retained), never absent", unverifiable, "\(broken)")
        // G2e: normal expiry is a defined boundary — an expired snapshot
        // reached from history is skipped, not unverifiable.
        await resetState()
        let expiredRef = try snapshot(durable: [trigger], trigger: "automatic")
        _ = try snapshot(durable: [trigger], trigger: "automatic")
        try PruneArchiveStore.retainLatest(limit: 1)
        var holder = Self.assistant("old", rounds: [])
        holder.pruneArchiveReferences = [expiredRef]
        let fresh = Self.record(body: body)
        check("G2e an expired snapshot is skipped (normal expiry never blocks new jobs)",
              SettlementEvidence.locate(fresh, history: [trigger, holder]) == .absent)
        // G2f: unreadable records file → retention deletes no snapshot
        // holding any binding, nor its successors.
        await resetState()
        for _ in 0..<3 { _ = try snapshot(durable: [trigger], trigger: "automatic") }
        let pa = try snapshot(carried: [Self.round(callId: "call-w", binding: OutcomeBinding(kind: .moved, jobId: UUID()))])
        let pb = try snapshot(carried: [Self.round(callId: "call-x", binding: nil)], prior: compaction(pa))
        try Data("garbage".utf8).write(to: DetachedJobStore.fileURL)
        try PruneArchiveStore.retainLatest(limit: 1)
        let kept = Set((try? PruneArchiveStore.entries().map(\.reference.id)) ?? [])
        check("G2f unreadable records → bound snapshots and their successors kept", kept.isSuperset(of: [pa.id, pb.id]))
        try? FileManager.default.removeItem(at: DetachedJobStore.fileURL)
        // G2g: a lost legacy list is never rebuilt by reclassifying current
        // snapshots; sidecar-less snapshots then read unverifiable.
        await resetState()
        let pre = try snapshot(durable: [trigger], trigger: "automatic")
        try FileManager.default.removeItem(at: SettlementEvidence.sidecarURL(pre.id))
        try FileManager.default.removeItem(at: SettlementEvidence.directory().appendingPathComponent("legacy.json"))
        try SettlementEvidence.ensureLegacyListInitialized()
        var legacyGone = false
        if case .missing = SettlementEvidence.legacyIds() { legacyGone = true }
        var h2 = Self.assistant("x", rounds: [])
        h2.pruneArchiveReferences = [pre]
        var unv = false
        if case .unverifiable = SettlementEvidence.locate(Self.record(), history: [trigger, h2]) { unv = true }
        check("G2g lost legacy list not recreated; sidecar-less snapshot → unverifiable", legacyGone && unv)
        // G2h: legacy-list initialization failure before the first admission
        // → no crash record can be created (the job is not detached).
        await resetState()
        struct Injected: Error {}
        SettlementEvidence.faultForTesting = { if $0 == "legacy-init" { throw Injected() } }
        var created = false
        do { try DetachedJobStore.create(Self.record()); created = true } catch {}
        SettlementEvidence.faultForTesting = nil
        check("G2h legacy-list write failure before first admission → record not created (fail closed)", !created && records().isEmpty)
        // G2i: end to end — with the legacy list failing, a woken wait keeps
        // waiting instead of detaching.
        let manager = await freshManager()
        try? FileManager.default.removeItem(at: SettlementEvidence.directory())
        SettlementEvidence.faultForTesting = { if $0 == "legacy-init" { throw Injected() } }
        server.script([Self.chatTools([(id: "call-li", name: "bash", args: ["command": "sleep 1.5; echo li", "wait_seconds": 30])]),
                       Self.chatText("ok")])
        manager._testStartTurn(for: user("go"))
        _ = await waitForRunningJob()
        await manager._testDispatchUser(user("hey"))
        _ = await manager._testAwaitIdle(timeout: 20)
        SettlementEvidence.faultForTesting = nil
        let payload = parse(results(manager).first { $0.toolCallId == "call-li" }?.content ?? "")
        check("G2i with no legacy list, a woken wait keeps waiting (no detach)",
              payload["moved_to_background"] == nil && payload["status"] as? String == "exited", "\(payload)")
    }
}
