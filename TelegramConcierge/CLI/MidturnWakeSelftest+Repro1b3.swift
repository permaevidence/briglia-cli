import Foundation

extension MidturnHarness {
    func repro1b3Section() async throws {
        struct Injected: Error {}
        let at = Date()
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: at))!
        let lastMonth = monthStart.addingTimeInterval(-60)
        for mode in 0..<3 {
            _ = await freshManager()
            let job = UUID()
            try DetachedJobStore.create(chargeRecord(jobId: job, completion: .delivered))
            ToolChargeLedger.capture(jobId: job, amountUSD: 0.2, at: at, kind: "subagent")
            ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw Injected() } }
            ToolChargeLedger.capture(jobId: job, amountUSD: 0.7, at: mode == 2 ? lastMonth : at, kind: "subagent")
            let reference = mode == 2 ? lastMonth : at
            let before = ToolChargeLedger.snapshot(referenceDate: reference).month
            check("N3-\(mode)-control held larger copy counted", abs(before - 0.7) < 1e-9, "before=\(before)")
            if mode != 0 { ToolChargeLedger.faultForTesting = nil }
            ToolChargeLedger.capture(jobId: job, amountUSD: 0.4, at: at, kind: "subagent")
            let after = ToolChargeLedger.snapshot(referenceDate: reference).month
            check("N3-\(mode)-capture preserves earlier held copy", abs(after - 0.7) < 1e-9,
                  "before=\(before), after=\(after), held=\(ToolChargeLedger.heldCharges().map(\.amountUSD))")
            ToolChargeLedger.faultForTesting = nil
            ToolChargeLedger.settlePending()
            try DetachedJobStore.retireSettled()
            let settled = ToolChargeLedger.snapshot(referenceDate: reference).month
            check("N3-\(mode)-settlement preserves earlier held copy", abs(settled - 0.7) < 1e-9,
                  "after=\(settled), records=\(records().count)")
        }
    }
}
