import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Release 1b rows: typed unknown-spend incidents with stable identities
/// (plan v7 §3.6.3; Codex V7 acceptance gate 4) and the incident-scoped
/// `/spend accept-unknown`, including the journaled unreadable-ledger
/// replacement and its roll-forward.
extension MidturnHarness {

    private func setDailyCap(_ value: String?) throws {
        if let value { try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey, value: value) }
        else { try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey) }
    }

    private func accept(_ manager: ConversationManager) async -> String {
        (await manager.handleTerminalCommand("/spend accept-unknown") ?? []).joined(separator: "\n")
    }

    private func journalState() -> String? {
        guard let data = try? Data(contentsOf: ToolChargeLedger.journalURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["state"] as? String
    }

    private func preservedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: ToolChargeLedger.directory.path)) ?? [])
            .filter { $0.hasPrefix("tool-charges.unreadable-") }.sorted()
    }

    func spendIncidentSection() async throws {
        try await incidentAcceptanceKeepsKnownCharges()
        try await incidentUnreadableLedgerByPermission()
        try await incidentRepairThenSameBytes()
        try await incidentRecordsUnreadable()
        try await incidentRegistryUnreadable()
    }

    /// I1–I3 (Codex example): $8 recorded + one unknown-amount job under a
    /// $10 daily cap → paused; acceptance keeps the $8 ($2 left), survives a
    /// restart, and does not cover a later incident.
    private func incidentAcceptanceKeepsKnownCharges() async throws {
        let manager = await freshManager()
        clearModelSpend()
        try setDailyCap("10")
        defer { try? setDailyCap(nil) }
        try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: UUID(), amountUSD: 8, providerReturnedAt: Date(), kind: "subagent"))
        let job = UUID()
        try ToolChargeLedger.openUnknownAmount(jobId: job, day: Date(), detail: "i1")
        let paused = SpendGate.pauseReason() ?? ""
        check("I1a $8 known + one unknown-amount incident under a $10 cap: paid work paused (can't verify), incident named",
              paused.contains("can't verify") && paused.contains(String(job.uuidString.lowercased().prefix(8))), paused)
        let reply = await accept(manager)
        let status = SpendGate.status()
        check("I1b /spend accept-unknown accepts exactly that incident: today stays $8, $2 of allowance left, reply lists it",
              reply.contains("Accepted as $0") && reply.contains(String(job.uuidString.lowercased().prefix(8)))
                && abs(status.todaySpentUSD - 8) < 1e-9 && !status.dailyExceeded && SpendGate.pauseReason() == nil, reply)
        // Restart: memory gone, files only.
        ToolChargeLedger.forgetHeldForTesting()
        let restarted = await restartKillingSubagents()
        _ = restarted
        check("I2 after a restart the same incident stays accepted; today still $8, not paused",
              abs(SpendGate.status().todaySpentUSD - 8) < 1e-9 && SpendGate.pauseReason() == nil)
        let later = UUID()
        try ToolChargeLedger.openUnknownAmount(jobId: later, day: Date(), detail: "i3")
        let pausedAgain = SpendGate.pauseReason() ?? ""
        check("I3 a later unknown-amount incident is NOT covered: paused again, only the new incident listed",
              pausedAgain.contains(String(later.uuidString.lowercased().prefix(8)))
                && !pausedAgain.contains(String(job.uuidString.lowercased().prefix(8))), pausedAgain)
        // I8/I9: repeated acceptance only accepts what is open now.
        _ = await accept(manager)
        let ledgerBytes = try? Data(contentsOf: ToolChargeLedger.ledgerURL)
        let incidentBytes = try? Data(contentsOf: ToolChargeLedger.incidentsURL)
        let again = await accept(manager)
        check("I4 a repeated acceptance with nothing open says so and writes nothing",
              again.contains("Nothing to accept") && ledgerBytes == (try? Data(contentsOf: ToolChargeLedger.ledgerURL))
                && incidentBytes == (try? Data(contentsOf: ToolChargeLedger.incidentsURL)), again)
    }

    /// I5: a permission failure — no bytes obtainable — still gets a stable
    /// incident id; acceptance preserves the file under its episode name and
    /// starts a new generation holding every pending captured charge.
    private func incidentUnreadableLedgerByPermission() async throws {
        // Root reads a mode-000 file (Linux CI container); the decode variants cover this path there.
        guard geteuid() != 0 else { print("  (I5 skipped: running as root, file permissions do not deny reads)"); return }
        let manager = await freshManager()
        clearModelSpend()
        try setDailyCap("10")
        defer { try? setDailyCap(nil) }
        try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: UUID(), amountUSD: 3, providerReturnedAt: Date(), kind: "subagent"))
        let original = try Data(contentsOf: ToolChargeLedger.ledgerURL)
        let pending = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: pending, charge: JobCharge(chargeId: pending, amountUSD: 0.5,
                                                                                  providerReturnedAt: Date(), state: .pending)))
        chmod(ToolChargeLedger.ledgerURL.path, 0o000)
        let first = ToolChargeLedger.snapshot().incidents.first { $0.kind == .ledgerUnreadable }
        let second = ToolChargeLedger.snapshot().incidents.first { $0.kind == .ledgerUnreadable }
        check("I5a unreadable by permission: an incident id minted without reading bytes, stable across snapshots, pauses under a cap",
              first != nil && first?.id == second?.id && (first?.id.hasPrefix("ledger-unreadable:") ?? false)
                && SpendGate.pauseReason()?.contains("tool-charges.json unreadable") == true)
        let reply = await accept(manager)
        let preserved = ToolChargeLedger.preservedURL(episode: String(first?.id.split(separator: ":").last ?? ""))
        chmod(preserved.path, 0o600)
        let preservedBytes = try? Data(contentsOf: preserved)
        let generation: Int? = { if case .readable(let g, _, _) = ToolChargeLedger.loadLedger() { return g }; return nil }()
        check("I5b acceptance: old file preserved byte for byte under its episode name; new generation holds the pending charge; total = that charge",
              reply.contains("Accepted as $0") && preservedBytes == original && generation == 2
                && ledgerEntries().map(\.chargeId) == [pending] && abs(ToolChargeLedger.snapshot().today - 0.5) < 1e-9
                && journalState() == "committed" && SpendGate.pauseReason() == nil,
              "reply \(reply.prefix(80)), gen \(String(describing: generation)), entries \(ledgerEntries().count), journal \(journalState() ?? "nil")")
    }

    /// I6: repair, then the SAME corrupt bytes again → a new episode that no
    /// earlier acceptance covers; accepting it never overwrites the earlier
    /// preserved file.
    private func incidentRepairThenSameBytes() async throws {
        let manager = await freshManager()
        try setDailyCap("10")
        defer { try? setDailyCap(nil) }
        let bad = Data("{\"version\": oops".utf8)
        try bad.write(to: ToolChargeLedger.ledgerURL)
        let e1 = ToolChargeLedger.snapshot().incidents.first { $0.kind == .ledgerUnreadable }?.id
        // Repair (valid ledger) → the episode closes.
        try? FileManager.default.removeItem(at: ToolChargeLedger.ledgerURL)
        try ToolChargeLedger.recordInLedger(ToolChargeEntry(chargeId: UUID(), amountUSD: 1, providerReturnedAt: Date(), kind: "subagent"))
        let closed = ToolChargeLedger.snapshot().incidents.isEmpty
        try bad.write(to: ToolChargeLedger.ledgerURL)
        let e2 = ToolChargeLedger.snapshot().incidents.first { $0.kind == .ledgerUnreadable }?.id
        check("I6a repair closes the episode; identical bytes later are a NEW episode (not covered), paused again",
              e1 != nil && closed && e2 != nil && e1 != e2 && SpendGate.pauseReason() != nil,
              "e1 \(e1 ?? "nil"), e2 \(e2 ?? "nil"), closed \(closed)")
        _ = await accept(manager)
        let firstPreserved = preservedFiles()
        let firstBytes = firstPreserved.first.flatMap { try? Data(contentsOf: ToolChargeLedger.directory.appendingPathComponent($0)) }
        try bad.write(to: ToolChargeLedger.ledgerURL)
        let e3 = ToolChargeLedger.snapshot().incidents.first { $0.kind == .ledgerUnreadable }?.id
        _ = await accept(manager)
        let secondPreserved = preservedFiles()
        let stillFirst = firstPreserved.first.flatMap { try? Data(contentsOf: ToolChargeLedger.directory.appendingPathComponent($0)) }
        check("I6b the same bytes after an accepted generation: a new episode again, preserved separately; the earlier preserved file untouched",
              e3 != nil && e3 != e2 && secondPreserved.count == 2 && firstBytes != nil && stillFirst == firstBytes,
              "preserved \(secondPreserved)")
    }

    /// I7: job records unreadable (pending charges unknown) → a stable
    /// records-unreadable incident; readable again → it closes.
    private func incidentRecordsUnreadable() async throws {
        _ = await freshManager()
        try Data("{broken".utf8).write(to: DetachedJobStore.fileURL)
        let a = ToolChargeLedger.snapshot().incidents.first { $0.kind == .recordsUnreadable }?.id
        let b = ToolChargeLedger.snapshot().incidents.first { $0.kind == .recordsUnreadable }?.id
        try FileManager.default.removeItem(at: DetachedJobStore.fileURL)
        let cleared = ToolChargeLedger.snapshot().incidents.isEmpty
        check("I7 unreadable job records: a stable records-unreadable incident while it lasts; closes when readable",
              a != nil && a == b && cleared, "a \(a ?? "nil"), b \(b ?? "nil")")
    }

    /// I8: the incident registry itself is unreadable: the gap has no stable
    /// identity, so it cannot be accepted (and is never overwritten).
    private func incidentRegistryUnreadable() async throws {
        let manager = await freshManager()
        try setDailyCap("10")
        defer { try? setDailyCap(nil) }
        let junk = Data("{junk".utf8)
        try junk.write(to: ToolChargeLedger.incidentsURL)
        let snapshot = ToolChargeLedger.snapshot()
        let reply = await accept(manager)
        check("I8 unreadable incident registry: incomplete, cannot be accepted, file never overwritten",
              !snapshot.isComplete && reply.contains("no stable identity") && (try? Data(contentsOf: ToolChargeLedger.incidentsURL)) == junk,
              reply)
    }

    // MARK: Journaled acceptance and roll-forward

    func spendAcceptanceSection() async throws {
        for step in ["journal-rename", "journal-new-ledger", "journal-commit"] {
            try await acceptanceCrashAt(step)
        }
        try await rollForwardKeepsNewerLedger()
        try await chargeArrivesDuringAcceptance()
        try await moreDoesNotUnpause()
        try await nothingOpenNothingWritten()
    }

    /// I9: a crash injected at each step of the replacement transaction:
    /// every restart rolls forward to one consistent result; an absent
    /// ledger while the journal is `begun` is never read as empty/complete.
    private func acceptanceCrashAt(_ step: String) async throws {
        let manager = await freshManager()
        try setDailyCap("10")
        defer { try? setDailyCap(nil) }
        try Data("{nope".utf8).write(to: ToolChargeLedger.ledgerURL)
        let pending = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: pending, charge: JobCharge(chargeId: pending, amountUSD: 0.4,
                                                                                  providerReturnedAt: Date(), state: .pending)))
        let episode = ToolChargeLedger.snapshot().incidents.first { $0.kind == .ledgerUnreadable }?.id
        struct Injected: Error {}
        ToolChargeLedger.faultForTesting = { if $0 == step { throw Injected() } }
        let reply = await accept(manager)
        let midJournal = journalState()
        let midComplete = ToolChargeLedger.snapshot().isComplete
        ToolChargeLedger.faultForTesting = nil
        // "Restart": nothing in memory, roll-forward from the files.
        ToolChargeLedger.forgetHeldForTesting()
        let after = ToolChargeLedger.snapshot()
        let generation: Int? = { if case .readable(let g, _, _) = ToolChargeLedger.loadLedger() { return g }; return nil }()
        let accepted: Bool = {
            if case .readable(let list) = ToolChargeLedger.loadIncidents() { return list.contains { $0.id == episode && $0.state == .accepted } }
            return false
        }()
        check("I9 crash at \(step): the begun acceptance is durable and never read as complete; the next check rolls forward to one consistent result",
              midJournal == "begun" && !midComplete && reply.contains("completes automatically")
                && journalState() == "committed" && generation == 2 && ledgerEntries().map(\.chargeId) == [pending]
                && preservedFiles().count == 1 && accepted && after.isComplete && abs(after.today - 0.4) < 1e-9,
              "journal \(midJournal ?? "nil")→\(journalState() ?? "nil"), gen \(String(describing: generation)), entries \(ledgerEntries().count), preserved \(preservedFiles().count), accepted \(accepted), reply \(reply.prefix(100))")
    }

    /// I9b: the new generation already holds a charge that exists nowhere
    /// else (it was only in memory; the process then died before the journal
    /// committed): the roll-forward commits without rewriting that ledger.
    private func rollForwardKeepsNewerLedger() async throws {
        let manager = await freshManager()
        try Data("{nope".utf8).write(to: ToolChargeLedger.ledgerURL)
        let memoryOnly = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: memoryOnly))
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { if $0 == "charge-pending" { throw Injected() } }
        ToolChargeLedger.faultForTesting = { if $0 == "ledger-write" { throw Injected() } }
        _ = ToolChargeLedger.capture(jobId: memoryOnly, amountUSD: 0.7, kind: "subagent")   // held in memory
        DetachedJobStore.faultForTesting = nil
        _ = ToolChargeLedger.snapshot()
        ToolChargeLedger.faultForTesting = { if $0 == "journal-commit" { throw Injected() } }
        _ = await accept(manager)
        let inNewGeneration = ledgerEntries().contains { $0.chargeId == memoryOnly }
        ToolChargeLedger.faultForTesting = nil
        ToolChargeLedger.forgetHeldForTesting()   // crash: memory lost
        _ = ToolChargeLedger.snapshot()
        check("I9b roll-forward after a crash keeps the newer generation (a charge only it holds survives); journal commits",
              inNewGeneration && ledgerEntries().contains { $0.chargeId == memoryOnly } && journalState() == "committed"
                && abs(ToolChargeLedger.snapshot().today - 0.7) < 1e-9,
              "in new gen \(inNewGeneration), entries \(ledgerEntries().count), journal \(journalState() ?? "nil")")
    }

    /// I10: a charge captured between the acceptance start and the journal
    /// completion is kept exactly once (never overwritten, never doubled).
    private func chargeArrivesDuringAcceptance() async throws {
        let manager = await freshManager()
        try Data("{nope".utf8).write(to: ToolChargeLedger.ledgerURL)
        let early = UUID(), late = UUID()
        try DetachedJobStore.create(chargeRecord(jobId: early, charge: JobCharge(chargeId: early, amountUSD: 0.1,
                                                                                providerReturnedAt: Date(), state: .pending)))
        try DetachedJobStore.create(chargeRecord(jobId: late))
        _ = ToolChargeLedger.snapshot()
        struct Injected: Error {}
        ToolChargeLedger.faultForTesting = { if $0 == "journal-new-ledger" { throw Injected() } }
        _ = await accept(manager)
        // The late job finishes while the ledger is absent and the journal begun.
        let durable = ToolChargeLedger.capture(jobId: late, amountUSD: 0.2, kind: "subagent")
        let latePendingMeanwhile = records().first { $0.jobId == late }?.charge?.state == .pending
        ToolChargeLedger.faultForTesting = nil
        ToolChargeLedger.settlePending()
        let entries = ledgerEntries()
        check("I10 a charge arriving mid-acceptance is kept exactly once in the new generation; journal completes",
              durable && latePendingMeanwhile && entries.filter { $0.chargeId == late }.count == 1
                && entries.filter { $0.chargeId == early }.count == 1 && entries.count == 2 && journalState() == "committed"
                && abs(ToolChargeLedger.snapshot().today - 0.3) < 1e-9,
              "entries \(entries.map { ($0.chargeId == late ? "late" : "early", $0.amountUSD) })")
    }

    /// I11: /more cannot make an unknown total known.
    private func moreDoesNotUnpause() async throws {
        let manager = await freshManager()
        try setDailyCap("10")
        defer { try? setDailyCap(nil) }
        try ToolChargeLedger.openUnknownAmount(jobId: UUID(), day: Date(), detail: "i11")
        let reply = (await manager.handleTerminalCommand("/more5") ?? []).joined(separator: "\n")
        check("I11 /more5 while spend can't be verified: explains it can't fix that; still paused",
              reply.contains("can't be verified") && reply.contains("/spend accept-unknown") && SpendGate.pauseReason() != nil, reply)
        let status = (await manager.handleTerminalCommand("/spend") ?? []).joined(separator: "\n")
        check("I12 /spend lists the open incident and the pause", status.contains("Spend totals incomplete") && status.contains("paused"), status)
    }

    /// I13: nothing open → "nothing to accept"; no accounting file created.
    private func nothingOpenNothingWritten() async throws {
        let manager = await freshManager()
        let reply = await accept(manager)
        let created = [ToolChargeLedger.ledgerURL, ToolChargeLedger.incidentsURL, ToolChargeLedger.journalURL]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        check("I13 nothing open: 'nothing to accept', no accounting file written", reply.contains("Nothing to accept") && created.isEmpty,
              "\(reply) \(created.map(\.lastPathComponent))")
    }
}
