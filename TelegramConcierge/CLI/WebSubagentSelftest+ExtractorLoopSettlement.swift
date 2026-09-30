import Foundation

// Group 22, settlement rows (2026-09-29, owner decision): an OpenRouter
// generation record that says the cut request was CANCELLED and reports
// total_cost exactly 0 settles its unknown-amount incident at $0, recorded
// once under the incident's own id (hold → incident → ledger → close). A
// missing record, or a 0 without cancelled:true, leaves it unknown; a
// positive cost settles as before.
extension WebSubagentSelftest {
    static func runExtractorLoopSettlementRows(_ h: Harness) async throws {
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        let ledgerDir = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-websub-zero-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        let previousLedgerDir = ToolChargeLedger.directoryForTesting
        ToolChargeLedger.directoryForTesting = ledgerDir
        ToolChargeLedger.resetForTesting()
        defer {
            ToolChargeLedger.faultForTesting = nil
            ToolChargeLedger.resetForTesting()
            ToolChargeLedger.directoryForTesting = previousLedgerDir
            try? FileManager.default.removeItem(at: ledgerDir)
        }
        func incidents() -> [SpendIncident] {
            if case .readable(let list) = ToolChargeLedger.loadIncidents() { return list }
            return []
        }
        func incident(_ gen: String) -> SpendIncident? { incidents().first { $0.generationId == gen } }
        func ledgerCut() -> [ToolChargeEntry] {
            if case .readable(_, let e, _) = ToolChargeLedger.loadLedger() { return e.filter { $0.kind == ToolChargeLedger.cutRequestChargeKind } }
            return []
        }
        func faults(_ labels: Set<String>) {
            ToolChargeLedger.faultForTesting = labels.isEmpty ? nil : { label in
                if labels.contains(label) { throw ToolChargeLedger.Failure("injected \(label) failure") }
            }
        }

        // 22.12 The real field record parses into the settlement rule.
        let field = """
        {"data":{"streamed":true,"cancelled":true,"generation_time":300743,"tokens_prompt":17920,"tokens_completion":31540,
        "native_tokens_prompt":17920,"native_tokens_completion":31540,"native_tokens_reasoning":31540,"finish_reason":null,
        "native_finish_reason":null,"usage":0,"id":"gen-1790715102-UkhWxq9E52mtfY78GNrH",
        "provider_responses":[{"provider_name":"Reka","status":499}],"total_cost":0,"upstream_inference_cost":0,"provider_name":"Reka"}}
        """
        let record = CutRequestCostLookup.parseRecord(Data(field.utf8))
        let parse = { (s: String) in CutRequestCostLookup.parseRecord(Data(s.utf8)) }
        check("22.12 generation record parser: the field cut's record (499, cancelled, 31,540 reasoning tokens, cost 0) → settles at exactly $0; 0 without cancelled, a missing cost, a 404 body → no settlement; a positive cost settles at that cost",
              record?.provider == "Reka" && record?.upstreamStatus == 499 && record?.cancelled == true && record?.reasoningTokens == 31540
              && record?.promptTokens == 17920 && record?.settlementCost == 0 && record.map { abs(($0.generationTimeMs ?? 0) - 300743) < 1 } == true
              && parse("{\"data\":{\"total_cost\":0,\"cancelled\":false}}")?.settlementCost == nil
              && parse("{\"data\":{\"total_cost\":0}}")?.settlementCost == nil
              && parse("{\"data\":{\"cancelled\":true}}")?.settlementCost == nil
              && parse("{\"error\":{\"code\":404}}") == nil
              && parse("{\"data\":{\"total_cost\":0.0042,\"cancelled\":true}}")?.settlementCost == 0.0042
              && parse("{\"data\":{\"total_cost\":0.0042}}")?.settlementCost == 0.0042,
              "\(String(describing: record))")

        // 22.13 $0 settlement, recorded once under the incident's own id.
        ToolChargeLedger.resetForTesting()
        let zeroID = UUID(), keepID = UUID(), plainZeroID = UUID(), paidID = UUID()
        try ToolChargeLedger.openCutRequestUnknown(chargeId: zeroID, generationId: "gen-zero-cancelled", provider: nil, stage: "extract.assets")
        try ToolChargeLedger.openCutRequestUnknown(chargeId: keepID, generationId: "gen-zero-missing", provider: nil, stage: "extract.assets")
        try ToolChargeLedger.openCutRequestUnknown(chargeId: plainZeroID, generationId: "gen-zero-plain", provider: nil, stage: "extract.assets")
        try ToolChargeLedger.openCutRequestUnknown(chargeId: paidID, generationId: "gen-zero-paid", provider: nil, stage: "extract.assets")
        let records: [String: OpenRouterGenerationRecord] = [
            "gen-zero-cancelled": .init(totalCost: 0, cancelled: true, provider: "OpenAI"),
            "gen-zero-plain": .init(totalCost: 0, cancelled: nil, provider: "OpenAI"),
            "gen-zero-paid": .init(totalCost: 0.0021, cancelled: true, provider: "OpenAI"),
        ]
        let settled = await ToolChargeLedger.reconcileCutRequestRecords { records[$0] }
        let zero = incident("gen-zero-cancelled")
        let zeroEntry = ledgerCut().first { $0.chargeId == zeroID }
        let snap = ToolChargeLedger.snapshot()
        check("22.13 a cancelled record with cost exactly 0 settles its incident at $0: ledger entry (kind web-cut, $0) under the incident's own id, incident closed with known amount 0; the missing record and the plain 0 stay OPEN (unknown); a positive cost settles as before",
              settled == 2 && zero?.state == .closed && zero?.knownAmountUSD == 0 && zeroEntry?.amountUSD == 0
              && zero?.id == "unknown-amount:\(zeroID.uuidString.lowercased())"
              && incident("gen-zero-missing")?.state == .open && incident("gen-zero-plain")?.state == .open
              && incident("gen-zero-paid")?.state == .closed && ledgerCut().count == 2
              && abs(snap.today - 0.0021) < 1e-12 && !snap.isComplete,
              "settled \(settled) zero \(String(describing: zero?.state)) entries \(ledgerCut().map(\.amountUSD)) today \(snap.today)")
        ToolChargeLedger.forgetHeldForTesting()
        let again = await ToolChargeLedger.reconcileCutRequestRecords { records[$0] }
        check("22.14 count-once: a second lookup run (after a simulated restart) settles nothing new; one $0 entry stays",
              again == 0 && ledgerCut().filter { $0.chargeId == zeroID }.count == 1 && ledgerCut().count == 2, "again \(again)")
        // Accept-unknown still takes only the open ones; the $0 is untouched.
        let accepted = ToolChargeLedger.acceptOpenIncidents(channel: "selftest")
        check("22.15 /spend accept-unknown afterwards accepts only the two still-open incidents; the $0-settled and paid ones are not re-opened or changed, totals unchanged",
              accepted.failure == nil && Set(accepted.accepted.compactMap(\.generationId)) == ["gen-zero-missing", "gen-zero-plain"]
              && incident("gen-zero-cancelled")?.state == .closed && abs(ToolChargeLedger.snapshot().today - 0.0021) < 1e-12,
              "\(accepted.accepted.compactMap(\.generationId)) \(accepted.failure ?? "ok")")

        // 22.16 Write-before-close with a $0 amount: the ledger write fails,
        // the incident keeps the known 0 (no longer unknown) and a later
        // retry writes it once without a new lookup.
        ToolChargeLedger.resetForTesting()
        let heldID = UUID()
        try ToolChargeLedger.openCutRequestUnknown(chargeId: heldID, generationId: "gen-zero-held", provider: nil, stage: "extract.assets")
        faults(["ledger-write"])
        _ = await ToolChargeLedger.reconcileCutRequestRecords { _ in .init(totalCost: 0, cancelled: true) }
        faults([])
        let heldIncident = incident("gen-zero-held")
        let heldSnap = ToolChargeLedger.snapshot()
        let lookups = LookupCounter()
        _ = await ToolChargeLedger.reconcileCutRequestRecords { _ in lookups.bump(); return nil }
        check("22.16 write-before-close at $0: a failed ledger write leaves the incident open but carrying known amount 0 (not unknown any more, totals complete); the next run writes the $0 entry once and closes it with no new lookup",
              heldIncident?.state == .open && heldIncident?.knownAmountUSD == 0 && heldSnap.isComplete
              && lookups.value == 0 && ledgerCut().filter { $0.chargeId == heldID }.count == 1 && incident("gen-zero-held")?.state == .closed,
              "state \(String(describing: heldIncident?.state)) known \(String(describing: heldIncident?.knownAmountUSD)) complete \(heldSnap.isComplete) lookups \(lookups.value)")

        // 22.21 BYOK (GPT-6 Luna on an OpenRouter account with its own OpenAI
        // key): total_cost is only OpenRouter's fee, the user's key is billed
        // upstream_inference_cost — a $0 total is not evidence of $0 spent.
        let byok = { (s: String) in CutRequestCostLookup.parseRecord(Data("{\"data\":{\(s)}}".utf8))?.settlementCost }
        let byokRecord = CutRequestCostLookup.parseRecord(Data("{\"data\":{\"total_cost\":0,\"is_byok\":true,\"upstream_inference_cost\":0.0031,\"cancelled\":true,\"provider_name\":\"OpenAI\"}}".utf8))
        check("22.21 BYOK records: the upstream cost settles (0.0031, not the $0 total); fee 0.0002 + upstream 0.0050 settles at their sum 0.0052; a BYOK record without an upstream cost stays unknown even when cancelled at $0 or with a positive fee; $0 only when fee and upstream are both 0 on a cancelled request; the log names the upstream cost",
              byokRecord?.isByok == true && byokRecord?.settlementCost == 0.0031
              && byok("\"total_cost\":0,\"is_byok\":true,\"cancelled\":true") == nil
              && byok("\"total_cost\":0.0002,\"is_byok\":true") == nil
              && byok("\"total_cost\":0,\"is_byok\":true,\"upstream_inference_cost\":0,\"cancelled\":true") == 0
              && byok("\"total_cost\":0,\"is_byok\":true,\"upstream_inference_cost\":0") == nil
              && byok("\"total_cost\":0.0002,\"is_byok\":true,\"upstream_inference_cost\":0.0050").map { abs($0 - 0.0052) < 1e-12 } == true
              && byok("\"total_cost\":0,\"is_byok\":false,\"cancelled\":true") == 0
              && byokRecord?.logFields.contains("byok upstream_cost=") == true,
              "\(String(describing: byokRecord))")
        ToolChargeLedger.resetForTesting()
        let byokID = UUID(), byokOpenID = UUID()
        try ToolChargeLedger.openCutRequestUnknown(chargeId: byokID, generationId: "gen-byok-paid", provider: nil, stage: "extract.excerpts")
        try ToolChargeLedger.openCutRequestUnknown(chargeId: byokOpenID, generationId: "gen-byok-zero", provider: nil, stage: "extract.excerpts")
        let byokRecords: [String: OpenRouterGenerationRecord] = [
            "gen-byok-paid": .init(totalCost: 0, cancelled: true, provider: "OpenAI", isByok: true, upstreamInferenceCost: 0.0031),
            "gen-byok-zero": .init(totalCost: 0, cancelled: true, provider: "OpenAI", isByok: true),
        ]
        let byokSettled = await ToolChargeLedger.reconcileCutRequestRecords { byokRecords[$0] }
        check("22.22 reconcile with BYOK records: the incident with an upstream cost closes at that cost (ledger entry 0.0031 under its own id); the cancelled $0 BYOK record without an upstream cost stays OPEN (unknown), totals incomplete",
              byokSettled == 1 && incident("gen-byok-paid")?.state == .closed && ledgerCut().first { $0.chargeId == byokID }?.amountUSD == 0.0031
              && incident("gen-byok-zero")?.state == .open && !ToolChargeLedger.snapshot().isComplete,
              "settled \(byokSettled) entries \(ledgerCut().map(\.amountUSD))")

        // 22.23 BYOK fee and provider charge are two separate charges: summed,
        // as reported, never the larger one; non-BYOK upstream is a breakdown.
        let codexFixture = CutRequestCostLookup.parseRecord(Data("{\"data\":{\"is_byok\":true,\"total_cost\":0.05,\"upstream_inference_cost\":1.0,\"cancelled\":true}}".utf8))
        check("22.23 BYOK fee $0.05 + provider charge $1.00 settles at $1.05 (not $1.00), cancelled or not; a non-finite sum stays unknown; a non-BYOK record with an upstream breakdown settles at total_cost only",
              codexFixture?.settlementCost.map { abs($0 - 1.05) < 1e-12 } == true
              && byok("\"is_byok\":true,\"total_cost\":0.05,\"upstream_inference_cost\":1.0").map { abs($0 - 1.05) < 1e-12 } == true
              && byok("\"is_byok\":true,\"total_cost\":1e308,\"upstream_inference_cost\":1e308") == nil
              && byok("\"is_byok\":false,\"total_cost\":0.05,\"upstream_inference_cost\":0.04") == 0.05
              && byok("\"total_cost\":0.05,\"upstream_inference_cost\":0.04") == 0.05,
              "\(String(describing: codexFixture?.settlementCost))")

        // 22.24 The summed amount through the ledger: recorded once, a second
        // reconcile adds nothing, a failed ledger write keeps the incident open
        // with the known $1.05 and the next run writes it once, no new lookup.
        ToolChargeLedger.resetForTesting()
        let sumID = UUID()
        try ToolChargeLedger.openCutRequestUnknown(chargeId: sumID, generationId: "gen-byok-sum", provider: nil, stage: "extract.excerpts")
        let sumRecord = OpenRouterGenerationRecord(totalCost: 0.05, cancelled: true, provider: "OpenAI", isByok: true, upstreamInferenceCost: 1.0)
        let firstSum = await ToolChargeLedger.reconcileCutRequestRecords { $0 == "gen-byok-sum" ? sumRecord : nil }
        ToolChargeLedger.forgetHeldForTesting()
        let againSum = await ToolChargeLedger.reconcileCutRequestRecords { $0 == "gen-byok-sum" ? sumRecord : nil }
        let sumEntries = ledgerCut().filter { $0.chargeId == sumID }
        let sumToday = ToolChargeLedger.snapshot().today
        let sumState = incident("gen-byok-sum")?.state
        ToolChargeLedger.resetForTesting()
        let faultID = UUID()
        try ToolChargeLedger.openCutRequestUnknown(chargeId: faultID, generationId: "gen-byok-fault", provider: nil, stage: "extract.excerpts")
        faults(["ledger-write"])
        _ = await ToolChargeLedger.reconcileCutRequestRecords { _ in sumRecord }
        faults([])
        let faultHeld = incident("gen-byok-fault")
        let sumLookups = LookupCounter()
        _ = await ToolChargeLedger.reconcileCutRequestRecords { _ in sumLookups.bump(); return nil }
        let faultEntries = ledgerCut().filter { $0.chargeId == faultID }
        check("22.24 BYOK sum through the ledger: one entry of $1.05 under the incident id, a repeat reconcile (after a simulated restart) adds nothing, today's total $1.05; a failed ledger write keeps the incident open carrying the known $1.05 and the next run writes exactly one $1.05 entry with no new lookup",
              firstSum == 1 && againSum == 0 && sumEntries.count == 1 && sumEntries.first.map { abs($0.amountUSD - 1.05) < 1e-12 } == true
              && abs(sumToday - 1.05) < 1e-12 && sumState == .closed
              && faultHeld?.state == .open && faultHeld?.knownAmountUSD.map { abs($0 - 1.05) < 1e-12 } == true
              && sumLookups.value == 0 && faultEntries.count == 1 && faultEntries.first.map { abs($0.amountUSD - 1.05) < 1e-12 } == true
              && incident("gen-byok-fault")?.state == .closed,
              "first \(firstSum) again \(againSum) entries \(sumEntries.map(\.amountUSD)) today \(sumToday) held \(String(describing: faultHeld?.knownAmountUSD)) faultEntries \(faultEntries.map(\.amountUSD)) lookups \(sumLookups.value)")
    }
}
