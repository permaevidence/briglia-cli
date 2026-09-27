import Foundation

/// Release 1b, round 4 rows. HC: every distinct memory-held copy of a
/// charge (amount AND date) is kept — a later capture never replaces an
/// earlier one — and each copy is released only once a durable store holds
/// that exact copy. Identical retries collapse to one copy.
extension MidturnHarness {

    private struct HCInjected: Error {}

    private func heldAmounts(_ job: UUID) -> [Double] {
        ToolChargeLedger.heldCharges().filter { $0.chargeId == job }.map(\.amountUSD).sorted()
    }

    private func ledgerAmounts(_ job: UUID) -> [Double]? {
        guard case .readable(_, let entries, let conflicts) = ToolChargeLedger.loadLedger() else { return nil }
        return (entries + conflicts).filter { $0.chargeId == job }.map(\.amountUSD).sorted()
    }

    private func same(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    /// A settled record carrying $0.20 (captured normally), then the ledger
    /// write fails: later captures take the memory path.
    private func heldCopySetup() async throws -> UUID {
        _ = await freshManager()
        clearModelSpend()
        let job = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: job, completion: .delivered))
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.2, kind: "subagent")
        ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw HCInjected() } }
        return job
    }

    func heldCopySection() async throws {
        defer { ToolChargeLedger.faultForTesting = nil }
        try await heldCopyIdenticalRetry()
        try await heldCopyConsecutiveConflicts()
        try await heldCopyRecoveredBetween()
        try await heldCopyMonths()
        try await heldCopyPartialRelease()
        try await heldCopyAcceptance()
        try await heldCopyImportBarrier()
    }

    // HC0 identical retry: one held copy, counted once; settles to one
    // conflict copy in the ledger.
    private func heldCopyIdenticalRetry() async throws {
        let job = try await heldCopySetup()
        let at = Date()
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, at: at, kind: "subagent")
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, at: at, kind: "subagent")
        check("HC0a identical retry collapses to one held copy", same(heldAmounts(job), [0.7]),
              "held=\(heldAmounts(job))")
        ToolChargeLedger.faultForTesting = nil
        ToolChargeLedger.settlePending()
        try DetachedJobStore.retireSettled()
        check("HC0b control: settled once, record retires, $0.70 counted",
              heldAmounts(job).isEmpty && records().isEmpty && same(ledgerAmounts(job) ?? [], [0.2, 0.7])
                && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "held=\(heldAmounts(job)), records=\(records().count), ledger=\(ledgerAmounts(job) ?? []), today=\(ToolChargeLedger.snapshot().today)")
    }

    // HC1 consecutive conflicting captures while writes fail.
    private func heldCopyConsecutiveConflicts() async throws {
        let job = try await heldCopySetup()
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, kind: "subagent")
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.4, kind: "subagent")
        check("HC1a both differing held copies kept, maximum counted",
              same(heldAmounts(job), [0.4, 0.7]) && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "held=\(heldAmounts(job)), today=\(ToolChargeLedger.snapshot().today)")
        ToolChargeLedger.faultForTesting = nil
        ToolChargeLedger.settlePending()
        try DetachedJobStore.retireSettled()
        check("HC1b after repair the ledger holds every copy; record retires; $0.70 counted",
              heldAmounts(job).isEmpty && records().isEmpty && same(ledgerAmounts(job) ?? [], [0.2, 0.4, 0.7])
                && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "held=\(heldAmounts(job)), records=\(records().count), ledger=\(ledgerAmounts(job) ?? []), today=\(ToolChargeLedger.snapshot().today)")
    }

    // HC2 the ledger recovers before the third capture: the new copy is
    // written, the earlier memory-only copy stays held until written too.
    private func heldCopyRecoveredBetween() async throws {
        let job = try await heldCopySetup()
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, kind: "subagent")
        ToolChargeLedger.faultForTesting = nil
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.4, kind: "subagent")
        check("HC2a the earlier $0.70 copy is still held after the new copy is written",
              heldAmounts(job).contains { abs($0 - 0.7) < 1e-9 } && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "held=\(heldAmounts(job)), ledger=\(ledgerAmounts(job) ?? []), today=\(ToolChargeLedger.snapshot().today)")
        ToolChargeLedger.settlePending()
        try DetachedJobStore.retireSettled()
        check("HC2b settlement writes it; nothing held; $0.70 counted",
              heldAmounts(job).isEmpty && records().isEmpty && same(ledgerAmounts(job) ?? [], [0.2, 0.4, 0.7])
                && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "held=\(heldAmounts(job)), records=\(records().count), ledger=\(ledgerAmounts(job) ?? [])")
    }

    // HC3 held copies in different billing months: the maximum counts in
    // every month any copy names, before and after settlement.
    private func heldCopyMonths() async throws {
        let at = Date()
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: at))!
        let lastMonth = monthStart.addingTimeInterval(-60)
        let job = try await heldCopySetup()
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, at: lastMonth, kind: "subagent")
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.4, at: at, kind: "subagent")
        let before = (ToolChargeLedger.snapshot(referenceDate: lastMonth).month, ToolChargeLedger.snapshot(referenceDate: at).month)
        check("HC3a last month and this month both count $0.70 while held",
              abs(before.0 - 0.7) < 1e-9 && abs(before.1 - 0.7) < 1e-9, "months=\(before)")
        ToolChargeLedger.faultForTesting = nil
        ToolChargeLedger.settlePending()
        try DetachedJobStore.retireSettled()
        let after = (ToolChargeLedger.snapshot(referenceDate: lastMonth).month, ToolChargeLedger.snapshot(referenceDate: at).month)
        check("HC3b both months keep $0.70 after settlement and retirement",
              records().isEmpty && abs(after.0 - 0.7) < 1e-9 && abs(after.1 - 0.7) < 1e-9,
              "months=\(after), records=\(records().count)")
    }

    // HC4 settlement writes one copy and fails on the next: only the written
    // copy is released; the other stays held and the record stays.
    private func heldCopyPartialRelease() async throws {
        let job = try await heldCopySetup()
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, kind: "subagent")
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.4, kind: "subagent")
        var writes = 0
        ToolChargeLedger.faultForTesting = { label in
            guard label == "ledger-write" else { return }
            writes += 1
            if writes > 1 { throw HCInjected() }
        }
        ToolChargeLedger.settlePending()
        try DetachedJobStore.retireSettled()
        let written = ledgerAmounts(job) ?? []
        let held = heldAmounts(job)
        let unwritten = [0.4, 0.7].filter { a in !written.contains { abs($0 - a) < 1e-9 } }
        check("HC4a the unwritten copy stays held and the record stays",
              unwritten.count == 1 && same(held, unwritten) && records().count == 1
                && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "ledger=\(written), held=\(held), records=\(records().count), today=\(ToolChargeLedger.snapshot().today)")
        ToolChargeLedger.faultForTesting = nil
        ToolChargeLedger.settlePending()
        try DetachedJobStore.retireSettled()
        check("HC4b repaired: written, released, record retires",
              heldAmounts(job).isEmpty && records().isEmpty && same(ledgerAmounts(job) ?? [], [0.2, 0.4, 0.7]),
              "held=\(heldAmounts(job)), records=\(records().count), ledger=\(ledgerAmounts(job) ?? [])")
    }

    // HC5 an unreadable ledger accepted with /spend accept-unknown: the new
    // generation is seeded with every held copy.
    private func heldCopyAcceptance() async throws {
        let job = try await heldCopySetup()
        ToolChargeLedger.faultForTesting = nil
        try Data("not json".utf8).write(to: ToolChargeLedger.ledgerURL)
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, kind: "subagent")
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.4, kind: "subagent")
        let acceptance = ToolChargeLedger.acceptOpenIncidents(channel: "selftest")
        check("HC5 the accepted generation holds every held copy; $0.70 counted",
              acceptance.failure == nil && same(ledgerAmounts(job) ?? [], [0.2, 0.4, 0.7])
                && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "failure=\(acceptance.failure ?? "nil"), ledger=\(ledgerAmounts(job) ?? []), today=\(ToolChargeLedger.snapshot().today)")
    }

    // HC6 Mind import / wipe barrier: refuses while copies are held, then
    // proceeds once every copy is in the ledger.
    private func heldCopyImportBarrier() async throws {
        let job = try await heldCopySetup()
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, kind: "subagent")
        ToolChargeLedger.capture(jobId: job, amountUSD: 0.4, kind: "subagent")
        let refused = ToolChargeLedger.settleAllBeforeReplacingHistory()
        check("HC6a the barrier refuses while copies are held", refused != nil && same(heldAmounts(job), [0.4, 0.7]),
              "refused=\(refused ?? "nil"), held=\(heldAmounts(job))")
        ToolChargeLedger.faultForTesting = nil
        let cleared = ToolChargeLedger.settleAllBeforeReplacingHistory()
        check("HC6b after repair it proceeds with every copy in the ledger",
              cleared == nil && heldAmounts(job).isEmpty && same(ledgerAmounts(job) ?? [], [0.2, 0.4, 0.7]),
              "result=\(cleared ?? "nil"), held=\(heldAmounts(job)), ledger=\(ledgerAmounts(job) ?? [])")
    }
}
