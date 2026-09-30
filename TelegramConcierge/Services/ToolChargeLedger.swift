import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Tool-charge accounting for work that outlives its launching call (mid-turn
// early wake plan v7 §3.6.3, release 1b; Codex V7 acceptance gate 4).
//
// Background and wake-detached subagents record their whole run total here,
// once, keyed by the job id (`chargeId`), BEFORE their completion is queued.
// The completion drain never charges, so a completion retried after a failed
// history save can never be charged twice. Images join the same ledger later
// (kind "image"); nothing in this file is subagent-specific.
//
// Durability chain per charge (each step checked, each retryable):
//   1. the job's crash record carries the charge as `pending`;
//   2. the charge is written to `tool-charges.json`;
//   3. the record flips to `recorded` (and may then retire).
// Totals are the UNION by chargeId of the ledger, record charges (pending or
// recorded — a recorded copy survives when the ledger cannot be read) and
// charges held only in memory (both stores failed; every distinct copy of a
// chargeId is kept) — one total per chargeId, with one conservative rule for
// conflicting copies.
//
// Completeness is a list of typed incidents with stable ids. A configured
// daily/monthly cap plus an open, unaccepted incident affecting the current
// day or month pauses paid work until repair or `/spend accept-unknown`,
// which accepts exactly the incidents open at that moment (their unknown
// amounts count as $0) and keeps every known charge.
//
// Files (data root, 0600, atomic writes, parent fsync, errors checked, never
// in a Mind export):
//   tool-charges.json              the ledger (never overwritten while unreadable)
//   spend-incidents.json           incident identities and acceptances
//   spend-acceptance-journal.json  the unreadable-ledger replacement journal
//   tool-charges.unreadable-<episode>.json  a preserved unreadable ledger

/// One ledger entry. `chargeId` is the job id.
struct ToolChargeEntry: Codable, Equatable {
    let chargeId: UUID
    let amountUSD: Double
    let providerReturnedAt: Date
    let kind: String

    func sameCharge(as other: ToolChargeEntry) -> Bool {
        chargeId == other.chargeId && abs(amountUSD - other.amountUSD) < 1e-12
            && abs(providerReturnedAt.timeIntervalSince(other.providerReturnedAt)) < 0.001
    }
}

/// A typed unknown-spend incident with a stable identity (§3.6.3).
struct SpendIncident: Codable, Equatable {
    enum Kind: String, Codable {
        /// A job ended (lost in a restart) after a provider may have been
        /// called, with no captured charge. Id `unknown-amount:<jobId>`.
        case unknownAmount
        /// A charge held only in memory (both stores failed) was lost at a
        /// restart. Id `memory-only:<chargeId>`.
        case memoryOnly
        /// `tool-charges.json` exists but cannot be read or decoded. One
        /// EPISODE per failure period, id `ledger-unreadable:<episode uuid>`:
        /// minted when the failure is first seen, WITHOUT reading the bytes,
        /// and closed when the file reads again or is replaced by an accepted
        /// generation — a later failure (even with identical bytes) is a new
        /// episode that no earlier acceptance covers.
        case ledgerUnreadable
        /// The crash records (which may hold pending charges) cannot be read.
        /// Same episode rule, id `records-unreadable:<episode uuid>`.
        case recordsUnreadable
    }
    enum State: String, Codable { case open, accepted, closed }
    let id: String
    let kind: Kind
    /// Day keys (`yyyy-MM-dd`) the unknown amount belongs to. Empty for the
    /// unreadable-file kinds: while open they affect whatever day and month
    /// is current (their prior totals are unknown).
    var periods: [String]
    /// When set, the unknown amount may belong to EVERY day from the earliest
    /// of `periods` through this day key (inclusive): a lost run may have
    /// spent on both sides of a day, month or year boundary, so its incident
    /// covers the whole interval its durable timing evidence allows (launch
    /// through the run's end, or through recovery when the end is unknown).
    /// Additive, omitted when nil.
    var throughDay: String? = nil
    let openedAt: Date
    var state: State
    var acceptedAt: Date? = nil
    var closedAt: Date? = nil
    var detail: String? = nil
    /// OpenRouter generation id of a web extraction request Briglia stopped
    /// waiting for (unknownAmount only): the key a later cost lookup uses.
    /// Additive, omitted when nil (older binaries ignore it).
    var generationId: String? = nil
    /// The actual cost of that request once a lookup found it: counted as a
    /// known charge (union by chargeId with the ledger) and the incident no
    /// longer counts as unknown. Additive, omitted when nil.
    var knownAmountUSD: Double? = nil

    var affectsCurrentPeriods: Bool { kind == .ledgerUnreadable || kind == .recordsUnreadable }
    func affects(dayKey: String, monthKey: String) -> Bool {
        if affectsCurrentPeriods || periods.contains(dayKey) || periods.contains(where: { $0.hasPrefix(monthKey + "-") }) {
            return true
        }
        // Day keys are zero-padded yyyy-MM-dd, so string order is date order.
        guard let through = throughDay, let from = periods.min(), from <= through else { return false }
        if dayKey >= from && dayKey <= through { return true }
        return monthKey >= String(from.prefix(7)) && monthKey <= String(through.prefix(7))
    }
}

enum ToolChargeLedger {
    struct Failure: Error, LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { detail }
    }

    // MARK: Files

    nonisolated(unsafe) static var directoryForTesting: URL?
    /// Fault injection (tests only): called before every write/rename with an
    /// operation label; throwing simulates a storage failure.
    nonisolated(unsafe) static var faultForTesting: ((String) throws -> Void)?

    static var directory: URL { directoryForTesting ?? StoragePaths.dataRoot }
    static var ledgerURL: URL { directory.appendingPathComponent("tool-charges.json") }
    static var incidentsURL: URL { directory.appendingPathComponent("spend-incidents.json") }
    static var journalURL: URL { directory.appendingPathComponent("spend-acceptance-journal.json") }
    static func preservedURL(episode: String) -> URL {
        directory.appendingPathComponent("tool-charges.unreadable-\(episode).json")
    }

    /// Serializes EVERY ledger operation — charge capture and settlement,
    /// acceptance and roll-forward, incident updates (Codex V7 gate 4: one
    /// serialized transaction domain). Lock order: this lock, then the
    /// crash-record lock, never the reverse.
    private static let lock = NSRecursiveLock()

    private struct LedgerFile: Codable {
        var version = 1
        var generation: Int
        var entries: [ToolChargeEntry]
        /// Second copies of a chargeId that disagreed with the entry
        /// (kept; the snapshot counts the conservative maximum).
        var conflicts: [ToolChargeEntry] = []
    }
    private struct IncidentFile: Codable {
        var version = 1
        var incidents: [SpendIncident]
    }
    private struct Journal: Codable {
        enum State: String, Codable { case begun, committed }
        var version = 1
        var state: State
        /// The ledger-unreadable episode this transaction accepts.
        let episodeIncidentId: String
        let preservedName: String
        let newGeneration: Int
        let acceptedIncidentIds: [String]
        let at: Date
    }

    enum LedgerState {
        case absent
        case readable(generation: Int, entries: [ToolChargeEntry], conflicts: [ToolChargeEntry])
        case unreadable(String)
    }

    // MARK: Memory-held charges (both stores failed)

    private static let heldLock = NSLock()
    /// Every DISTINCT copy (amount and date) held for a chargeId. A later
    /// copy never replaces an earlier one: known charges never shrink, and
    /// the snapshot counts the largest amount in every period any copy
    /// names, so keeping only the largest would still lose the periods of
    /// the smaller ones. Identical copies are deduplicated.
    private nonisolated(unsafe) static var held: [UUID: [JobCharge]] = [:]
    /// A job whose charge is held only in memory: its crash record must not
    /// retire (it may be the only trace of that spend after a restart).
    static func isHeldInMemory(_ jobId: UUID) -> Bool {
        heldLock.lock(); defer { heldLock.unlock() }
        return !(held[jobId] ?? []).isEmpty
    }
    /// Every held copy, all chargeIds (several copies per id possible).
    static func heldCharges() -> [JobCharge] {
        heldLock.lock(); defer { heldLock.unlock() }
        return held.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { held[$0] ?? [] }
    }
    /// Add a copy. An identical copy (same amount and date) is merged,
    /// keeping `recorded` over `pending`; a differing copy is appended.
    private static func hold(_ charge: JobCharge) {
        heldLock.lock(); defer { heldLock.unlock() }
        var copies = held[charge.chargeId] ?? []
        if let i = copies.firstIndex(where: { $0.sameValues(as: charge) }) {
            if charge.state == .recorded { copies[i].state = .recorded }
        } else {
            copies.append(charge)
        }
        held[charge.chargeId] = copies
    }
    /// Release exactly this copy, once a durable store holds it. Other
    /// copies of the same chargeId stay held.
    private static func release(_ charge: JobCharge) {
        heldLock.lock(); defer { heldLock.unlock() }
        guard var copies = held[charge.chargeId] else { return }
        copies.removeAll { $0.sameValues(as: charge) }
        held[charge.chargeId] = copies.isEmpty ? nil : copies
    }
    /// Selftests simulate a restart (memory is lost).
    static func forgetHeldForTesting() { heldLock.lock(); held.removeAll(); heldLock.unlock() }
    /// Selftests: a restart — every in-memory accounting state is lost and
    /// this process gets a new instance id.
    static func simulateRestartForTesting() {
        forgetHeldForTesting()
        lock.lock(); abandonedUnsaved = [:]; endedUnremoved = []; heldCutIds = []; lock.unlock()
        DetachedJobStore.instanceId = UUID()
    }

    /// Surfaced as a maintenance notice by the manager.
    nonisolated(unsafe) static var lastFailure: String?

    // MARK: Capture (§3.6.3 "pending charge details")

    /// Record a finished job's charge: record (pending) → ledger → record
    /// (recorded). Zero amounts are written straight as `recorded` (no ledger
    /// entry). Returns true when the charge is durable somewhere (record or
    /// ledger); false when it is held only in memory.
    @discardableResult
    static func capture(jobId: UUID, amountUSD rawAmount: Double, at date: Date = Date(), kind: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let amount = rawAmount.isFinite && rawAmount > 0 ? rawAmount : 0
        let charge = JobCharge(chargeId: jobId, amountUSD: amount, providerReturnedAt: date,
                               state: amount > 0 ? .pending : .recorded)
        let entry = ToolChargeEntry(chargeId: jobId, amountUSD: amount, providerReturnedAt: date, kind: kind)
        var found = false
        var recordWritten = false
        do {
            try DetachedJobStore.mutate("charge-pending") { records in
                guard let i = records.firstIndex(where: { $0.jobId == jobId }) else { return }
                // A record already carrying a DIFFERENT copy of this charge
                // keeps it (known charges never shrink): the new copy takes
                // the ledger/memory path below, where the ledger keeps both
                // (entry + conflict) and the snapshot counts the maximum in
                // every period either copy names.
                if let existing = records[i].charge, !existing.sameValues(as: charge) { return }
                found = true
                if records[i].charge?.state != .recorded { records[i].charge = charge }
            }
            recordWritten = found
        } catch {
            lastFailure = "could not save a charge to the job record: \(error.localizedDescription)"
        }
        guard recordWritten else {
            // Step 1 failed: try the ledger directly. The record must learn
            // the charge before it may retire, so a copy is held in memory
            // (recorded when the ledger took it, pending otherwise) and the
            // idle retry writes it into the record. Both stores failing
            // leaves the charge only in memory: counted in this process, an
            // unknown-amount incident after a crash.
            var inLedger = amount == 0
            if amount > 0 { inLedger = (try? recordInLedger(entry)) != nil }
            var heldCopy = charge
            if inLedger { heldCopy.state = .recorded }
            hold(heldCopy)
            DebugTelemetry.log(.info, summary: "tool charge held in memory", detail: "job \(jobId) $\(amount), in ledger: \(inLedger)", isError: true)
            return inLedger
        }
        guard amount > 0 else { return true }
        do {
            try recordInLedger(entry)
            try DetachedJobStore.mutate("charge-recorded") { records in
                guard let i = records.firstIndex(where: { $0.jobId == jobId }) else { return }
                records[i].charge?.state = .recorded
            }
        } catch {
            // Pending in the record: counted by the union, retried later.
            lastFailure = "charge pending (\(error.localizedDescription))"
        }
        return true
    }

    /// Retry every pending/held charge (idle poll; Mind import Stage A).
    /// Returns the reasons of whatever is still not recorded.
    @discardableResult
    static func settlePending() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var problems: [String] = []
        // Memory-held first, copy by copy (a chargeId may hold several
        // differing copies). A held copy is released only once a durable
        // store holds THAT copy: its record (when the record has none, or
        // the same values), or else the readable ledger (as its entry or a
        // conflict copy). A record carrying a different copy keeps its own;
        // neither copy is ever dropped for the other.
        problems += settleCutRequestCharges()
        for charge in heldCharges() where !heldCutIds.contains(charge.chargeId) {
            enum Outcome { case missing, adopted, differs(kind: String) }
            var outcome = Outcome.missing
            do {
                try DetachedJobStore.mutate("charge-pending") { records in
                    guard let i = records.firstIndex(where: { $0.jobId == charge.chargeId }) else { return }
                    guard let existing = records[i].charge else {
                        records[i].charge = charge
                        outcome = .adopted
                        return
                    }
                    if existing.sameValues(as: charge) {
                        if existing.state == .pending && charge.state == .recorded { records[i].charge = charge }
                        outcome = .adopted
                    } else {
                        outcome = .differs(kind: records[i].kind)
                    }
                }
            } catch {
                problems.append("charge of job \(charge.chargeId) held in memory: \(error.localizedDescription)")
                continue
            }
            switch outcome {
            case .adopted:
                release(charge)
            case .differs(let kind):
                guard charge.amountUSD > 0 else { release(charge); continue }
                do {
                    try recordInLedger(ToolChargeEntry(chargeId: charge.chargeId, amountUSD: charge.amountUSD,
                                                       providerReturnedAt: charge.providerReturnedAt, kind: kind))
                    release(charge)
                } catch {
                    problems.append("charge of job \(charge.chargeId) held in memory (a second, different copy): \(error.localizedDescription)")
                }
            case .missing:
                problems.append("charge of job \(charge.chargeId) held in memory: its record is gone")
            }
        }
        // Recorded record copies the readable ledger does not hold with the
        // same values (a conflicting copy) are merged into it first, so a
        // record retires only once the ledger keeps its exact amount/date.
        problems += mergeRecordedCopies()
        let records: [DetachedJobRecord]
        do { records = try DetachedJobStore.load() } catch {
            problems.append("job records unreadable: \(error.localizedDescription)")
            return problems
        }
        let pending = records.compactMap { record -> (UUID, JobCharge)? in
            guard let charge = record.charge, charge.state == .pending else { return nil }
            return (record.jobId, charge)
        }
        guard !pending.isEmpty else { return problems }
        var recorded: Set<UUID> = []
        for (jobId, charge) in pending {
            do {
                try recordInLedger(ToolChargeEntry(chargeId: charge.chargeId, amountUSD: charge.amountUSD,
                                                   providerReturnedAt: charge.providerReturnedAt,
                                                   kind: records.first { $0.jobId == jobId }?.kind ?? "subagent"))
                recorded.insert(jobId)
            } catch {
                problems.append("charge of job \(jobId) still pending: \(error.localizedDescription)")
            }
        }
        if !recorded.isEmpty {
            do {
                try DetachedJobStore.mutate("charge-recorded") { records in
                    for i in records.indices where recorded.contains(records[i].jobId) { records[i].charge?.state = .recorded }
                    records.removeAll { $0.isSettled }
                }
            } catch {
                problems.append("could not mark recorded charges: \(error.localizedDescription)")
            }
        }
        return problems
    }

    /// Mind import Stage A prerequisite (§3.6.4): every pending/held charge
    /// recorded, or the reason the import must abort before anything changes.
    static func settleAllBeforeReplacingHistory() -> String? {
        lock.lock(); defer { lock.unlock() }
        let problems = settlePending() + registerUnknownSpendForPreviousProcesses(includeOwed: true)
        if !heldCharges().isEmpty { return problems.first ?? "a charge is held only in memory" }
        _ = settleInFlight()
        if !abandonedUnsaved.isEmpty { return "the unknown cost of an abandoned web request could not be saved yet" }
        do {
            let records = try DetachedJobStore.load()
            if records.contains(where: { $0.charge?.state == .pending }) {
                return problems.first ?? "a charge is still pending"
            }
            // A recorded charge the readable ledger does not hold (it is
            // unreadable, absent or mid-replacement) survives only in its job
            // record: deleting or replacing the records would lose a KNOWN
            // charge. Repair the ledger or accept the unknown first (the
            // accepted generation carries the charge over).
            if records.contains(where: { ($0.charge?.amountUSD ?? 0) > 0 && !$0.chargeSettled }) {
                return problems.first ?? "the charge ledger can't be read and a known charge exists only in a job record (repair tool-charges.json or send /spend accept-unknown)"
            }
            if records.contains(where: { $0.instanceId != DetachedJobStore.instanceId && $0.needsUnknownSpendIncident }) {
                return problems.first ?? "an unknown spend amount could not be recorded"
            }
        } catch {
            return "job records unreadable: \(error.localizedDescription)"
        }
        return nil
    }

    /// Register the unknown amount of a job of a PREVIOUS process that ended
    /// without a captured charge (§3.6.3): an unknown-amount incident when it
    /// never reported (lost in a restart), a memory-only incident when it
    /// finished but its charge existed only in memory. The record is marked
    /// only after the incident is durable (so it retires only then).
    static func registerUnknownSpend(_ record: DetachedJobRecord, recoveredAt now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        // The ledger may already hold this job's charge (the record write
        // failed but the ledger took it): then the amount is known — the
        // record learns it instead of opening an incident.
        if case .readable(_, let entries, _) = loadLedger(), let entry = entries.first(where: { $0.chargeId == record.jobId }) {
            try DetachedJobStore.update(record.jobId, "charge-recovered") {
                $0.charge = JobCharge(chargeId: entry.chargeId, amountUSD: entry.amountUSD,
                                      providerReturnedAt: entry.providerReturnedAt, state: .recorded)
            }
            return
        }
        let id: String
        // Never assume the spend happened at launch: the incident covers
        // every day from the launch through the run's durable end (settled)
        // or, when the end is unknown (lost), through this recovery.
        if record.completionBody != nil || record.settledAt != nil {
            try openMemoryOnly(chargeId: record.jobId, day: record.startedAt, through: record.settledAt ?? now,
                               detail: "\(record.handle) finished but its charge was only in memory at a restart")
            id = "memory-only:\(record.jobId.uuidString.lowercased())"
        } else {
            try openUnknownAmount(jobId: record.jobId, day: record.startedAt, through: now,
                                  detail: "\(record.handle) was lost in a restart after a provider may have been called")
            id = "unknown-amount:\(record.jobId.uuidString.lowercased())"
        }
        try DetachedJobStore.update(record.jobId, "unknown-spend") { $0.unknownSpendIncidentId = id }
    }

    /// Every previous-process record still missing its unknown-spend
    /// incident; returns the failures (the records then stay). Owed records
    /// are left to the startup job pass (a durable `real` result may still
    /// settle them) unless `includeOwed` (Mind import discards them).
    @discardableResult
    static func registerUnknownSpendForPreviousProcesses(includeOwed: Bool = false) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let records = try? DetachedJobStore.load() else { return [] }
        var problems: [String] = []
        for record in records where record.instanceId != DetachedJobStore.instanceId && record.needsUnknownSpendIncident
            && (includeOwed || record.completion != .owed) {
            do { try registerUnknownSpend(record) }
            catch { problems.append("\(record.handle): \(error.localizedDescription)") }
        }
        return problems
    }

    // MARK: Ledger file

    static func loadLedger() -> LedgerState {
        let url = ledgerURL
        var st = stat()
        if lstat(url.path, &st) != 0 {
            return errno == ENOENT ? .absent : .unreadable("cannot stat: \(String(cString: strerror(errno)))")
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .unreadable("cannot read: \(error.localizedDescription)") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(LedgerFile.self, from: data), file.version == 1 else {
            return .unreadable("undecodable")
        }
        return .readable(generation: file.generation, entries: file.entries, conflicts: file.conflicts)
    }

    /// The readable ledger holds THIS copy of the charge — same id, amount
    /// and date — as its entry or a conflict copy. Holding the id alone is
    /// not enough: a record copy that disagrees with the ledger's is known
    /// charge evidence (the snapshot counts the maximum in every period any
    /// copy names) and must stay until the ledger keeps it too. False while
    /// the ledger is unreadable or absent: the record may be the only copy.
    static func ledgerHolds(_ charge: JobCharge) -> Bool {
        guard case .readable(_, let entries, let conflicts) = loadLedger() else { return false }
        let copy = ToolChargeEntry(chargeId: charge.chargeId, amountUSD: charge.amountUSD,
                                   providerReturnedAt: charge.providerReturnedAt, kind: "")
        return (entries + conflicts).contains { $0.sameCharge(as: copy) }
    }

    /// Merge every positive `recorded` record copy the readable ledger does
    /// not hold with the same values into it (a conflict copy when the
    /// ledger's entry differs; idempotent). Retirement of such a record
    /// becomes possible only after this durable merge. Nothing is written
    /// while the ledger is unreadable or absent. Returns the failures.
    @discardableResult
    static func mergeRecordedCopies() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard case .readable = loadLedger(), let records = try? DetachedJobStore.load() else { return [] }
        var problems: [String] = []
        for record in records {
            guard let charge = record.charge, charge.state == .recorded, charge.amountUSD > 0,
                  !ledgerHolds(charge) else { continue }
            do {
                try recordInLedger(ToolChargeEntry(chargeId: charge.chargeId, amountUSD: charge.amountUSD,
                                                   providerReturnedAt: charge.providerReturnedAt, kind: record.kind))
            } catch {
                problems.append("charge of job \(record.jobId) differs from the ledger's copy and could not be merged: \(error.localizedDescription)")
            }
        }
        return problems
    }

    private static func writeLedger(_ file: LedgerFile, label: String) throws {
        try faultForTesting?(label)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try PrivateStorage.ensureDirectory(directory)
        try PrivateStorage.writeAtomically(try encoder.encode(file), to: ledgerURL)
    }

    /// Idempotent: an identical copy is a no-op; a different copy is a
    /// conflict (kept, alerted, never rewrites the entry). Throws when the
    /// ledger cannot be read (never overwritten) or written.
    static func recordInLedger(_ entry: ToolChargeEntry) throws {
        lock.lock(); defer { lock.unlock() }
        try rollForwardIfNeeded()
        var file: LedgerFile
        switch loadLedger() {
        case .unreadable(let reason):
            throw Failure("tool-charges.json unreadable (\(reason)) — not overwritten")
        case .absent:
            // An absent ledger while an acceptance journal exists is never a
            // pristine empty ledger (§3.6.3).
            if FileManager.default.fileExists(atPath: journalURL.path) {
                throw Failure("tool-charges.json missing while an acceptance journal exists — not recreated")
            }
            file = LedgerFile(generation: 1, entries: [])
        case .readable(let generation, let entries, let conflicts):
            file = LedgerFile(generation: generation, entries: entries, conflicts: conflicts)
        }
        if let existing = file.entries.first(where: { $0.chargeId == entry.chargeId }) {
            // Same copy (dates compared at millisecond precision: the record
            // and the ledger round-trip them through different encodings).
            if existing.sameCharge(as: entry) { return }
            guard !file.conflicts.contains(where: { $0.sameCharge(as: entry) }) else { return }
            file.conflicts.append(entry)
            DebugTelemetry.log(.info, summary: "tool charge conflict", detail: "\(entry.chargeId): \(existing.amountUSD) vs \(entry.amountUSD)", isError: true)
        } else {
            file.entries.append(entry)
        }
        pruneOld(&file)
        try writeLedger(file, label: "ledger-write")
    }

    private static func pruneOld(_ file: inout LedgerFile) {
        let now = Date()
        file.entries.removeAll { now.timeIntervalSince($0.providerReturnedAt) > 400 * 86_400 }
        file.conflicts.removeAll { now.timeIntervalSince($0.providerReturnedAt) > 90 * 86_400 }
    }

    // MARK: Incident registry

    enum IncidentState {
        case readable([SpendIncident])
        case unreadable(String)
    }

    static func loadIncidents() -> IncidentState {
        let url = incidentsURL
        var st = stat()
        if lstat(url.path, &st) != 0 {
            return errno == ENOENT ? .readable([]) : .unreadable("cannot stat: \(String(cString: strerror(errno)))")
        }
        guard let data = try? Data(contentsOf: url) else { return .unreadable("cannot read") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(IncidentFile.self, from: data), file.version == 1 else {
            return .unreadable("undecodable")
        }
        return .readable(file.incidents)
    }

    private static func mutateIncidents(_ label: String, _ body: (inout [SpendIncident]) -> Void) throws {
        guard case .readable(var incidents) = loadIncidents() else {
            throw Failure("spend-incidents.json unreadable — not overwritten")
        }
        let before = incidents
        body(&incidents)
        guard incidents != before else { return }
        // Closed/accepted incidents are kept 90 days for audit.
        let now = Date()
        incidents.removeAll { $0.state != .open && now.timeIntervalSince($0.closedAt ?? $0.acceptedAt ?? $0.openedAt) > 90 * 86_400 }
        try faultForTesting?(label)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try PrivateStorage.ensureDirectory(directory)
        try PrivateStorage.writeAtomically(try encoder.encode(IncidentFile(incidents: incidents)), to: incidentsURL)
    }

    /// Open (idempotently) the unknown-amount incident of a job lost after a
    /// provider may have been called. Checked: the caller keeps the job's
    /// record until this succeeds.
    /// `through` (when later than `day`) extends the incident over every
    /// day in between.
    static func openUnknownAmount(jobId: UUID, day: Date, through: Date? = nil, detail: String) throws {
        try openIncident(id: "unknown-amount:\(jobId.uuidString.lowercased())", kind: .unknownAmount,
                         from: day, through: through, detail: detail)
    }

    // MARK: Web extraction requests (OpenRouter follow) — unknown cost
    //
    // A non-streaming OpenRouter request keeps running and billing after
    // the client leaves, and returns no usage when abandoned. Each extractor
    // request is therefore WRITTEN AHEAD to `web-requests-in-flight.json`
    // before it is sent (no durable record → the request is refused), and
    // the record is removed when the reply arrives. A request abandoned
    // mid-flight (deadline cut, cancellation) or left behind by a previous
    // process becomes an unknown-amount incident; until that incident is
    // saved, the in-flight record (disk) plus a memory entry keep the
    // obligation, and the snapshot reports it as an open unknown.
    // A cost found later is kept as a memory-held pending copy and on the
    // incident (`knownAmountUSD`) until the ledger durably holds it: known
    // amounts are never lost and survive /spend accept-unknown.

    static let cutRequestDetailPrefix = "web extraction request"
    /// Kind of a cut request's charge once its cost is known.
    static let cutRequestChargeKind = "web-cut"
    static var inFlightURL: URL { directory.appendingPathComponent("web-requests-in-flight.json") }

    struct InFlightRequest: Codable, Equatable {
        let chargeId: UUID
        let stage: String
        let startedAt: Date
        let instanceId: UUID
    }
    private struct InFlightFile: Codable {
        var version = 1
        var requests: [InFlightRequest]
    }
    enum InFlightState {
        case readable([InFlightRequest])
        case unreadable(String)
    }
    /// `startedAt`…`at`: the interval the request may have spent in (its
    /// send through its abandonment, or through a restart's recovery when
    /// its end is unknown). The incident covers every day of it.
    private struct Abandoned { let generationId: String?; let provider: String?; let stage: String; let reason: String; let startedAt: Date; let at: Date }
    /// Abandoned requests of THIS process whose incident is not saved yet.
    private nonisolated(unsafe) static var abandonedUnsaved: [UUID: Abandoned] = [:]
    /// Completed requests whose in-flight record could not be removed yet.
    private nonisolated(unsafe) static var endedUnremoved: Set<UUID> = []
    /// chargeIds of memory-held looked-up costs (settled here, not by the
    /// job-record path of settlePending).
    private nonisolated(unsafe) static var heldCutIds: Set<UUID> = []

    static func loadInFlight() -> InFlightState {
        let url = inFlightURL
        var st = stat()
        if lstat(url.path, &st) != 0 {
            return errno == ENOENT ? .readable([]) : .unreadable("cannot stat: \(String(cString: strerror(errno)))")
        }
        guard let data = try? Data(contentsOf: url) else { return .unreadable("cannot read") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(InFlightFile.self, from: data), file.version == 1 else { return .unreadable("undecodable") }
        return .readable(file.requests)
    }

    private static func mutateInFlight(_ label: String, _ body: (inout [InFlightRequest]) -> Void) throws {
        guard case .readable(var requests) = loadInFlight() else {
            throw Failure("web-requests-in-flight.json unreadable — not overwritten")
        }
        let before = requests
        body(&requests)
        guard requests != before else { return }
        try faultForTesting?(label)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try PrivateStorage.ensureDirectory(directory)
        try PrivateStorage.writeAtomically(try encoder.encode(InFlightFile(requests: requests)), to: inFlightURL)
    }

    /// Write-ahead before sending. Throws when the record cannot be made
    /// durable: the caller must not send.
    static func beginInFlight(chargeId: UUID, stage: String, at date: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        try mutateInFlight("inflight-begin") {
            $0.append(InFlightRequest(chargeId: chargeId, stage: stage, startedAt: date, instanceId: DetachedJobStore.instanceId))
        }
    }

    /// The reply arrived (its known cost, if any, is counted by the caller).
    static func endInFlight(chargeId: UUID) {
        lock.lock(); defer { lock.unlock() }
        do { try mutateInFlight("inflight-end") { $0.removeAll { $0.chargeId == chargeId } } }
        catch { endedUnremoved.insert(chargeId) }
    }

    /// The request was abandoned while open: its cost is unknown. Opens the
    /// incident, then drops the in-flight record. Returns false when the
    /// incident could not be saved yet (the record and a memory entry keep
    /// the obligation; the snapshot counts it as an open unknown and retries).
    @discardableResult
    static func abandonInFlight(chargeId: UUID, generationId: String?, provider: String?, stage: String,
                                reason: String, startedAt: Date? = nil, at date: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let entry = Abandoned(generationId: generationId, provider: provider, stage: stage, reason: reason,
                              startedAt: min(startedAt ?? date, date), at: date)
        do {
            try openCutIncident(chargeId: chargeId, entry)
        } catch {
            abandonedUnsaved[chargeId] = entry
            lastFailure = "could not save the unknown cost of an abandoned web request (\(error.localizedDescription)); kept and retried"
            return false
        }
        do { try mutateInFlight("inflight-end") { $0.removeAll { $0.chargeId == chargeId } } }
        catch { endedUnremoved.insert(chargeId) }
        return true
    }

    private static func incidentId(_ chargeId: UUID) -> String { "unknown-amount:\(chargeId.uuidString.lowercased())" }

    private static func openCutIncident(chargeId: UUID, _ entry: Abandoned) throws {
        let id = incidentId(chargeId)
        try mutateIncidents("incident-open") { incidents in
            guard !incidents.contains(where: { $0.id == id }) else { return }
            incidents.append(cutIncident(id: id, entry,
                                         detail: "\(cutRequestDetailPrefix) \(entry.reason) (stage \(entry.stage), host \(entry.provider ?? "unnamed"), generation \(entry.generationId ?? "unknown"))"))
        }
    }

    /// The unknown amount may belong to any day from the send through the
    /// abandonment/recovery (range-aware, like a lost background job): never
    /// only the launch day, so a day, month or year boundary crossed while
    /// the request was open keeps it in the new period's accounting.
    private static func cutIncident(id: String, _ entry: Abandoned, detail: String) -> SpendIncident {
        var incident = SpendIncident(id: id, kind: .unknownAmount, periods: [dayKey(entry.startedAt)], openedAt: entry.at, state: .open,
                                     detail: detail, generationId: entry.generationId)
        let first = dayKey(entry.startedAt), last = dayKey(entry.at)
        if last > first { incident.throughDay = last }
        return incident
    }

    /// Retry the in-flight obligations (snapshot, idle poll): save pending
    /// abandoned incidents, turn records left by a previous process into
    /// incidents (interrupted by a restart), remove records of completed
    /// requests. Returns open unknowns not saved yet (synthesized
    /// incidents) and problems without identity.
    private static func settleInFlight() -> (unsaved: [SpendIncident], problems: [String]) {
        var unsaved: [SpendIncident] = []
        var problems: [String] = []
        for (chargeId, entry) in abandonedUnsaved {
            if (try? openCutIncident(chargeId: chargeId, entry)) != nil {
                abandonedUnsaved[chargeId] = nil
                endedUnremoved.insert(chargeId)
            }
        }
        switch loadInFlight() {
        case .unreadable(let reason):
            problems.append("web-requests-in-flight.json \(reason)")
        case .readable(let requests):
            for request in requests where request.instanceId != DetachedJobStore.instanceId && !endedUnremoved.contains(request.chargeId) {
                // Its end is unknown: it may have spent through this recovery.
                let entry = Abandoned(generationId: nil, provider: nil, stage: request.stage, reason: "interrupted by a restart",
                                      startedAt: request.startedAt, at: max(Date(), request.startedAt))
                if (try? openCutIncident(chargeId: request.chargeId, entry)) != nil {
                    endedUnremoved.insert(request.chargeId)
                } else {
                    abandonedUnsaved[request.chargeId] = entry
                }
            }
            if !endedUnremoved.isEmpty {
                let ids = endedUnremoved
                if (try? mutateInFlight("inflight-end") { $0.removeAll { ids.contains($0.chargeId) } }) != nil { endedUnremoved = [] }
            }
        }
        for (chargeId, entry) in abandonedUnsaved {
            unsaved.append(cutIncident(id: incidentId(chargeId), entry,
                                       detail: "\(cutRequestDetailPrefix) \(entry.reason) — not saved yet (stage \(entry.stage))"))
        }
        return (unsaved, problems)
    }

    /// Kept for callers/tests that open a cut incident directly.
    static func openCutRequestUnknown(chargeId: UUID, generationId: String?, provider: String?, stage: String, at date: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        try openCutIncident(chargeId: chargeId, Abandoned(generationId: generationId, provider: provider, stage: stage,
                                                          reason: "cut at its deadline", startedAt: date, at: date))
    }

    /// Cut requests whose cost may still be looked up: an unknown-amount
    /// incident with a generation id and no known amount yet, open or
    /// accepted, younger than `maxAge`. Expiry never clears an incident.
    static func pendingCutRequests(now: Date = Date(), maxAge: TimeInterval = 7 * 86_400) -> [SpendIncident] {
        guard case .readable(let incidents) = loadIncidents() else { return [] }
        return incidents.filter { $0.kind == .unknownAmount && $0.generationId != nil && $0.state != .closed
            && $0.knownAmountUSD == nil && now.timeIntervalSince($0.openedAt) <= maxAge }
    }

    /// Settle cut requests whose actual cost `lookup` finds. The amount is
    /// first held in memory (pending), then written onto the incident
    /// (`knownAmountUSD`, durable across restarts), then into the ledger
    /// under the incident's own id (idempotent), and only then is the
    /// incident closed. Any failed step keeps what was saved; later steps
    /// are retried by `settleCutRequestCharges` without a new lookup.
    /// Not found, or a reported 0 without evidence of finality, leaves the
    /// incident unknown. Exactly 0 settles only when the record says the
    /// request was cancelled (`OpenRouterGenerationRecord.settlementCost`;
    /// owner decision 2026-09-29) — through the same hold → incident →
    /// ledger → close path, once, under the incident's own id. Returns the
    /// number settled.
    @discardableResult
    static func reconcileCutRequestRecords(now: Date = Date(), lookupRecord: (String) async -> OpenRouterGenerationRecord?) async -> Int {
        _ = settleCutRequestCharges(now: now)
        var settled = 0
        for incident in pendingCutRequests(now: now) {
            guard let generationId = incident.generationId,
                  let chargeId = UUID(uuidString: String(incident.id.dropFirst("unknown-amount:".count))),
                  let cost = await lookupRecord(generationId)?.settlementCost else { continue }
            if keepKnownCost(chargeId: chargeId, incidentId: incident.id, cost: cost, at: incident.openedAt, now: now) { settled += 1 }
        }
        return settled
    }

    /// Cost-only lookups (no cancellation evidence): a reported 0 never
    /// settles through this form.
    @discardableResult
    static func reconcileCutRequests(now: Date = Date(), lookup: (String) async -> Double?) async -> Int {
        await reconcileCutRequestRecords(now: now, lookupRecord: { id in await lookup(id).map { OpenRouterGenerationRecord(totalCost: $0) } })
    }

    /// Hold → incident amount → ledger → close. True when fully settled.
    private static func keepKnownCost(chargeId: UUID, incidentId id: String, cost: Double, at date: Date, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        hold(JobCharge(chargeId: chargeId, amountUSD: cost, providerReturnedAt: date, state: .pending))
        heldCutIds.insert(chargeId)
        do {
            try mutateIncidents("incident-known") { incidents in
                for i in incidents.indices where incidents[i].id == id && incidents[i].knownAmountUSD == nil {
                    incidents[i].knownAmountUSD = cost
                }
            }
        } catch {
            lastFailure = "could not save the looked-up cost of a web request on its incident: \(error.localizedDescription); kept in memory and retried"
        }
        return settleKnown(chargeId: chargeId, incidentId: id, cost: cost, at: date, now: now)
    }

    private static func settleKnown(chargeId: UUID, incidentId id: String, cost: Double, at date: Date, now: Date) -> Bool {
        do {
            try recordInLedger(ToolChargeEntry(chargeId: chargeId, amountUSD: cost, providerReturnedAt: date, kind: cutRequestChargeKind))
        } catch {
            lastFailure = "could not record the looked-up cost of a web request: \(error.localizedDescription); kept and retried"
            return false
        }
        release(JobCharge(chargeId: chargeId, amountUSD: cost, providerReturnedAt: date, state: .pending))
        if !isHeldInMemory(chargeId) { heldCutIds.remove(chargeId) }
        do {
            try mutateIncidents("incident-reconcile") { incidents in
                for i in incidents.indices where incidents[i].id == id && incidents[i].state != .closed {
                    incidents[i].knownAmountUSD = incidents[i].knownAmountUSD ?? cost
                    incidents[i].state = .closed
                    incidents[i].closedAt = now
                    incidents[i].detail = (incidents[i].detail ?? "") + " — actual cost $\(SpendGate.formatUSD(cost)) recorded"
                }
            }
        } catch {
            // The ledger holds the amount; the incident keeps its known
            // amount (or is retried) and no longer counts as unknown.
            return true
        }
        return true
    }

    /// Retry known looked-up costs not yet in the ledger (idle poll, before
    /// each lookup run): memory-held copies, and incidents carrying
    /// `knownAmountUSD` that are not closed (restart recovery). No remote
    /// lookup is needed. Returns problems.
    @discardableResult
    static func settleCutRequestCharges(now: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var problems: [String] = []
        let incidents: [SpendIncident] = { if case .readable(let list) = loadIncidents() { return list }; return [] }()
        for charge in heldCharges() where heldCutIds.contains(charge.chargeId) {
            let id = incidentId(charge.chargeId)
            if incidents.first(where: { $0.id == id })?.knownAmountUSD == nil {
                try? mutateIncidents("incident-known") { list in
                    for i in list.indices where list[i].id == id && list[i].knownAmountUSD == nil { list[i].knownAmountUSD = charge.amountUSD }
                }
            }
            if !settleKnown(chargeId: charge.chargeId, incidentId: id, cost: charge.amountUSD, at: charge.providerReturnedAt, now: now) {
                problems.append("looked-up cost of web request \(charge.chargeId) held in memory")
            }
        }
        for incident in incidents where incident.state != .closed {
            guard let cost = incident.knownAmountUSD,
                  let chargeId = UUID(uuidString: String(incident.id.dropFirst("unknown-amount:".count))) else { continue }
            if !settleKnown(chargeId: chargeId, incidentId: incident.id, cost: cost, at: incident.openedAt, now: now) {
                problems.append("looked-up cost of web request \(chargeId) not yet in the ledger (kept on its incident)")
            }
        }
        return problems
    }

    /// A charge that existed only in memory was lost at a restart.
    static func openMemoryOnly(chargeId: UUID, day: Date, through: Date? = nil, detail: String) throws {
        try openIncident(id: "memory-only:\(chargeId.uuidString.lowercased())", kind: .memoryOnly,
                         from: day, through: through, detail: detail)
    }

    private static func openIncident(id: String, kind: SpendIncident.Kind, from: Date, through: Date?, detail: String) throws {
        lock.lock(); defer { lock.unlock() }
        let first = dayKey(from)
        let last = through.map(dayKey)
        try mutateIncidents("incident-open") { incidents in
            guard !incidents.contains(where: { $0.id == id }) else { return }
            var incident = SpendIncident(id: id, kind: kind, periods: [first], openedAt: Date(), state: .open, detail: detail)
            if let last, last > first { incident.throughDay = last }
            incidents.append(incident)
        }
    }

    /// The open episode of an unreadable-file kind, minted without reading
    /// the failing file (Codex V7 gate 4). Returns nil (no stable identity)
    /// when the incident registry itself cannot be updated.
    private static func episode(_ kind: SpendIncident.Kind, detail: String) -> String? {
        if case .readable(let incidents) = loadIncidents(),
           let open = incidents.first(where: { $0.kind == kind && $0.state == .open }) { return open.id }
        let prefix = kind == .ledgerUnreadable ? "ledger-unreadable" : "records-unreadable"
        let id = "\(prefix):\(UUID().uuidString.lowercased())"
        do {
            try mutateIncidents("incident-open") { incidents in
                incidents.append(SpendIncident(id: id, kind: kind, periods: [], openedAt: Date(), state: .open, detail: detail))
            }
        } catch {
            return nil
        }
        DebugTelemetry.log(.info, summary: "spend incident opened", detail: "\(id): \(detail)", isError: true)
        return id
    }

    /// The file reads again: its open episode (if unaccepted) closes, so a
    /// later failure is a NEW episode.
    private static func closeEpisodes(_ kind: SpendIncident.Kind) {
        guard case .readable(let incidents) = loadIncidents(),
              incidents.contains(where: { $0.kind == kind && $0.state == .open }) else { return }
        try? mutateIncidents("incident-close") { incidents in
            for i in incidents.indices where incidents[i].kind == kind && incidents[i].state == .open {
                incidents[i].state = .closed
                incidents[i].closedAt = Date()
            }
        }
    }

    // MARK: Snapshot (§3.6.3 "authoritative snapshot = union by chargeId")

    struct Snapshot {
        var today: Double = 0
        var month: Double = 0
        /// Open, unaccepted incidents affecting the current day or month.
        var incidents: [SpendIncident] = []
        /// Problems with no stable incident identity (the incident registry
        /// itself cannot be updated): still incomplete, but cannot be accepted.
        var unidentified: [String] = []
        var isComplete: Bool { incidents.isEmpty && unidentified.isEmpty }
        /// Charges counted from job records/memory (not yet in the ledger).
        var pendingCount = 0
    }

    static func snapshot(referenceDate: Date = Date()) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var snap = Snapshot()
        var acceptanceInFlight = false
        do { try rollForwardIfNeeded() } catch {
            acceptanceInFlight = true
            snap.unidentified.append("acceptance roll-forward: \(error.localizedDescription)")
        }
        // Abandoned web requests: save pending incidents / restart leftovers
        // first; what is still unsaved counts as an open unknown below.
        let inFlight = settleInFlight()
        snap.unidentified += inFlight.problems
        var copies: [UUID: [(amount: Double, at: Date)]] = [:]
        switch loadLedger() {
        case .absent:
            if FileManager.default.fileExists(atPath: journalURL.path) {
                if let id = episode(.ledgerUnreadable, detail: "tool-charges.json missing after an accepted replacement") {
                    _ = id
                } else { snap.unidentified.append("tool-charges.json missing (incident registry unwritable)") }
            } else {
                closeEpisodes(.ledgerUnreadable)
            }
        case .readable(_, let entries, let conflicts):
            // While an acceptance is still being completed its episode stays
            // open (the roll-forward records it as accepted, not closed).
            if !acceptanceInFlight { closeEpisodes(.ledgerUnreadable) }
            for e in entries + conflicts { copies[e.chargeId, default: []].append((e.amountUSD, e.providerReturnedAt)) }
        case .unreadable(let reason):
            if episode(.ledgerUnreadable, detail: "tool-charges.json \(reason)") == nil {
                snap.unidentified.append("tool-charges.json \(reason) (incident registry unwritable)")
            }
        }
        do {
            let records = try DetachedJobStore.load()
            closeEpisodes(.recordsUnreadable)
            // Every known copy counts, pending or recorded: a `recorded`
            // record copy is the surviving lower bound when the ledger that
            // should also hold it cannot be read (the union dedups otherwise).
            for record in records {
                guard let charge = record.charge else { continue }
                copies[charge.chargeId, default: []].append((charge.amountUSD, charge.providerReturnedAt))
                if charge.state == .pending { snap.pendingCount += 1 }
            }
        } catch {
            if episode(.recordsUnreadable, detail: error.localizedDescription) == nil {
                snap.unidentified.append("job records unreadable (incident registry unwritable)")
            }
        }
        for charge in heldCharges() {
            copies[charge.chargeId, default: []].append((charge.amountUSD, charge.providerReturnedAt))
            snap.pendingCount += 1
        }
        let loadedIncidents = loadIncidents()
        // A looked-up cost kept on its incident is a known charge (same
        // chargeId as its ledger entry, so the union never doubles it).
        if case .readable(let incidents) = loadedIncidents {
            for incident in incidents {
                guard let amount = incident.knownAmountUSD,
                      let chargeId = UUID(uuidString: String(incident.id.dropFirst("unknown-amount:".count))) else { continue }
                copies[chargeId, default: []].append((amount, incident.openedAt))
            }
        }
        let today = dayKey(referenceDate)
        let month = monthKey(referenceDate)
        // One rule for conflicting copies (§3.6.3): the largest amount,
        // counted in EVERY day/month any copy's timestamp falls in.
        for (_, list) in copies {
            let amount = list.map(\.amount).filter { $0.isFinite && $0 > 0 }.max() ?? 0
            guard amount > 0 else { continue }
            let days = Set(list.map { dayKey($0.at) })
            if days.contains(today) { snap.today += amount }
            if days.contains(where: { $0.hasPrefix(month + "-") }) { snap.month += amount }
        }
        switch loadedIncidents {
        case .readable(let incidents):
            snap.incidents = incidents.filter { $0.state == .open && $0.knownAmountUSD == nil && $0.affects(dayKey: today, monthKey: month) }
        case .unreadable(let reason):
            snap.unidentified.append("spend-incidents.json \(reason)")
        }
        let listed = Set(snap.incidents.map(\.id))
        snap.incidents += inFlight.unsaved.filter { !listed.contains($0.id) && $0.affects(dayKey: today, monthKey: month) }
        return snap
    }

    // MARK: /spend accept-unknown (§3.6.3, v7; Codex gate 4)

    struct Acceptance {
        let accepted: [SpendIncident]
        let failure: String?
    }

    /// Accept exactly the incidents open NOW (their unknown amounts count as
    /// $0). Known charges are kept: readable-ledger incidents are accepted in
    /// the registry; an unreadable ledger goes through the journaled
    /// replacement (the old file is preserved under its episode's name, the
    /// new generation starts with every pending captured charge). Later
    /// incidents are never covered.
    static func acceptOpenIncidents(referenceDate: Date = Date(), channel: String) -> Acceptance {
        lock.lock(); defer { lock.unlock() }
        let snap = snapshot(referenceDate: referenceDate)
        if !snap.unidentified.isEmpty {
            return Acceptance(accepted: [], failure: "some spend problems have no stable identity yet (\(snap.unidentified.joined(separator: "; "))) — repair them first (see `briglia doctor`)")
        }
        let open = snap.incidents
        guard !open.isEmpty else { return Acceptance(accepted: [], failure: nil) }
        if !abandonedUnsaved.isEmpty {
            return Acceptance(accepted: [], failure: "the unknown cost of an abandoned web request could not be saved yet (spend-incidents.json not writable) — it is retried; accept again once it is saved")
        }
        let ids = open.map(\.id)
        // Unreadable ledger: the journaled replacement transaction first.
        if let ledgerIncident = open.first(where: { $0.kind == .ledgerUnreadable }) {
            if case .unreadable = loadLedger() {
                do { try beginReplacement(episode: ledgerIncident.id, acceptedIds: ids) }
                catch {
                    // Once the journal is `begun` the acceptance is durable
                    // and completes at the next roll-forward.
                    let started = ((try? loadJournal()) ?? nil).map { $0.state == .begun && $0.episodeIncidentId == ledgerIncident.id } ?? false
                    return Acceptance(accepted: [], failure: started
                        ? "the acceptance was saved but replacing the unreadable ledger could not finish (\(error.localizedDescription)); it completes automatically at the next check"
                        : "could not replace the unreadable ledger: \(error.localizedDescription)")
                }
            }
        }
        do {
            try mutateIncidents("incident-accept") { incidents in
                for i in incidents.indices where ids.contains(incidents[i].id) && incidents[i].state == .open {
                    incidents[i].state = .accepted
                    incidents[i].acceptedAt = Date()
                    if incidents[i].affectsCurrentPeriods { incidents[i].closedAt = Date() }
                }
            }
        } catch {
            return Acceptance(accepted: [], failure: "could not save the acceptance: \(error.localizedDescription)")
        }
        DebugTelemetry.log(.info, summary: "spend accept-unknown", detail: "channel \(channel): \(ids.joined(separator: ", "))")
        return Acceptance(accepted: open, failure: nil)
    }

    private static func loadJournal() throws -> Journal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? decoder.decode(Journal.self, from: data), journal.version == 1 else {
            throw Failure("spend-acceptance-journal.json unreadable")
        }
        return journal
    }

    private static func writeJournal(_ journal: Journal, label: String) throws {
        try faultForTesting?(label)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try PrivateStorage.writeAtomically(try encoder.encode(journal), to: journalURL)
    }

    /// Step 1 (journal `begun`), then the roll-forward performs steps 2–4.
    private static func beginReplacement(episode: String, acceptedIds: [String]) throws {
        if let existing = try loadJournal(), existing.state == .begun {
            throw Failure("an earlier acceptance is still being completed")
        }
        let previous = (try? loadJournal())??.newGeneration ?? 1
        let episodeTag = episode.split(separator: ":").last.map(String.init) ?? UUID().uuidString.lowercased()
        let journal = Journal(state: .begun, episodeIncidentId: episode,
                              preservedName: preservedURL(episode: episodeTag).lastPathComponent,
                              newGeneration: previous + 1, acceptedIncidentIds: acceptedIds, at: Date())
        try writeJournal(journal, label: "journal-begin")
        try rollForwardIfNeeded()
    }

    /// Complete an interrupted acceptance (every start, before every
    /// snapshot, before every ledger write). Never reads an absent ledger as
    /// empty while the journal is `begun`, never overwrites a newer ledger,
    /// never overwrites a preserved file.
    static func rollForwardIfNeeded() throws {
        lock.lock(); defer { lock.unlock() }
        guard let journal = try loadJournal() else { return }
        guard journal.state == .begun else {
            // A committed journal still owes its acceptances if an earlier
            // build (or a crash) committed it before they were durable:
            // replay exactly its captured ids (checked, idempotent).
            try finalizeAcceptedIncidents(journal)
            return
        }
        let preserved = directory.appendingPathComponent(journal.preservedName)
        let ledgerExists = FileManager.default.fileExists(atPath: ledgerURL.path)
        if ledgerExists {
            switch loadLedger() {
            case .readable(let generation, _, _) where generation >= journal.newGeneration:
                break  // step 3 already done
            default:
                // Step 2: preserve the unreadable (or older) ledger. Refuse to
                // overwrite an existing preserved file.
                guard !FileManager.default.fileExists(atPath: preserved.path) else {
                    throw Failure("both the ledger and its preserved copy exist — left untouched")
                }
                try faultForTesting?("journal-rename")
                guard rename(ledgerURL.path, preserved.path) == 0 else {
                    throw Failure("could not preserve the unreadable ledger: \(String(cString: strerror(errno)))")
                }
                try PrivateStorage.fsyncDirectory(directory.path)
            }
        }
        if !FileManager.default.fileExists(atPath: ledgerURL.path) {
            // Step 3: the new generation starts with every known charge copy
            // that survives outside the unreadable ledger — pending AND
            // recorded record charges, and memory-held ones (the union still
            // dedups by chargeId). Accepting the unknown never drops a known
            // charge.
            // A second copy of a chargeId that differs (amount or date) is
            // kept as a conflict copy, never dropped for the first one.
            var entries: [ToolChargeEntry] = []
            var conflicts: [ToolChargeEntry] = []
            func seed(_ entry: ToolChargeEntry) {
                guard entry.amountUSD > 0 else { return }
                guard let first = entries.first(where: { $0.chargeId == entry.chargeId }) else { entries.append(entry); return }
                if first.sameCharge(as: entry) || conflicts.contains(where: { $0.sameCharge(as: entry) }) { return }
                conflicts.append(entry)
            }
            let records = try DetachedJobStore.load()
            for record in records {
                if let charge = record.charge {
                    seed(ToolChargeEntry(chargeId: charge.chargeId, amountUSD: charge.amountUSD,
                                         providerReturnedAt: charge.providerReturnedAt, kind: record.kind))
                }
            }
            for charge in heldCharges() {
                seed(ToolChargeEntry(chargeId: charge.chargeId, amountUSD: charge.amountUSD,
                                     providerReturnedAt: charge.providerReturnedAt, kind: "subagent"))
            }
            try writeLedger(LedgerFile(generation: journal.newGeneration, entries: entries, conflicts: conflicts), label: "journal-new-ledger")
        }
        // Step 4: the acceptances captured in the journal become durable
        // (checked). A failure or crash here leaves the journal `begun`, so
        // the next roll-forward repeats this step before committing.
        try finalizeAcceptedIncidents(journal)
        // Step 5: committed (the journal is kept as the durable record).
        var committed = journal
        committed.state = .committed
        try writeJournal(committed, label: "journal-commit")
    }

    /// Mark exactly the journal's captured incident ids accepted. Throws when
    /// the registry cannot be read or written; writes nothing when every id
    /// is already accepted (or gone after the 90-day audit window). A later
    /// incident is never in the journal, so it stays open.
    private static func finalizeAcceptedIncidents(_ journal: Journal) throws {
        guard case .readable(let current) = loadIncidents() else {
            throw Failure("spend-incidents.json unreadable — the accepted incidents could not be recorded yet")
        }
        let ids = Set(journal.acceptedIncidentIds)
        guard current.contains(where: { ids.contains($0.id) && $0.state != .accepted }) else { return }
        try mutateIncidents("incident-accept") { incidents in
            for i in incidents.indices where ids.contains(incidents[i].id) && incidents[i].state != .accepted {
                incidents[i].state = .accepted
                incidents[i].acceptedAt = journal.at
                if incidents[i].affectsCurrentPeriods { incidents[i].closedAt = incidents[i].closedAt ?? Date() }
            }
        }
    }

    // MARK: Periods (same buckets as the model-spend ledger)

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
    static func monthKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 1970, c.month ?? 1)
    }

    /// Human text for one incident.
    static func describe(_ incident: SpendIncident) -> String {
        var when = incident.periods.isEmpty ? "current totals" : incident.periods.joined(separator: ", ")
        if let through = incident.throughDay, let from = incident.periods.min() { when = "\(from) to \(through)" }
        switch incident.kind {
        case .unknownAmount where incident.detail?.hasPrefix(cutRequestDetailPrefix) == true:
            return "unknown cost of a \(incident.detail ?? cutRequestDetailPrefix) (\(when))"
        case .unknownAmount: return "unknown amount for background job \(incident.id.dropFirst("unknown-amount:".count).prefix(8)) (\(when))"
        case .memoryOnly: return "charge lost in a restart for job \(incident.id.dropFirst("memory-only:".count).prefix(8)) (\(when))"
        case .ledgerUnreadable: return "tool-charges.json unreadable — earlier totals unknown (episode \(incident.id.dropFirst("ledger-unreadable:".count).prefix(8)))"
        case .recordsUnreadable: return "background-job records unreadable — pending charges unknown (episode \(incident.id.dropFirst("records-unreadable:".count).prefix(8)))"
        }
    }

    /// Selftests: forget process state and files (called on a scratch root).
    static func resetForTesting() {
        forgetHeldForTesting()
        lastFailure = nil
        faultForTesting = nil
        abandonedUnsaved = [:]; endedUnremoved = []; heldCutIds = []
        for url in [ledgerURL, incidentsURL, journalURL, inFlightURL] { try? FileManager.default.removeItem(at: url) }
        if let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in items where name.hasPrefix("tool-charges.unreadable-") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}

// MARK: - Spend gate (§3.6.3 "daily/monthly enforcement reads a fresh snapshot")

/// Daily/monthly limit status from the AUTHORITATIVE snapshot: the model-spend
/// ledger plus the tool-charge union (so a charge recorded by a detached job
/// during a turn is visible to the next enforcement point), with its
/// completeness. Usable from any isolation domain.
enum SpendGate {
    struct Status {
        let todaySpentUSD: Double
        let monthSpentUSD: Double
        let dailyBaseLimitUSD: Double?
        let monthlyBaseLimitUSD: Double?
        let dailyExtraUSD: Double
        let monthlyExtraUSD: Double
        let accounting: ToolChargeLedger.Snapshot

        var effectiveDailyLimitUSD: Double? { dailyBaseLimitUSD.map { $0 + dailyExtraUSD } }
        var effectiveMonthlyLimitUSD: Double? { monthlyBaseLimitUSD.map { $0 + monthlyExtraUSD } }
        var dailyExceeded: Bool { effectiveDailyLimitUSD.map { todaySpentUSD >= $0 } ?? false }
        var monthlyExceeded: Bool { effectiveMonthlyLimitUSD.map { monthSpentUSD >= $0 } ?? false }
        var capConfigured: Bool { dailyBaseLimitUSD != nil || monthlyBaseLimitUSD != nil }
        /// A configured cap cannot be verified while accounting is
        /// incomplete: treated like a reached cap for new paid work.
        var unverifiable: Bool { capConfigured && !accounting.isComplete }
    }

    static let minimumLimitUSD = 0.001

    static func configuredLimit(_ key: String) -> Double? {
        guard let raw = KeychainHelper.load(key: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let parsed = Double(raw), parsed.isFinite, parsed >= minimumLimitUSD else { return nil }
        return parsed
    }

    static func status(referenceDate: Date = Date()) -> Status {
        let model = KeychainHelper.openRouterSpendSnapshot(referenceDate: referenceDate)
        let extra = KeychainHelper.openRouterSpendLimitIncreaseSnapshot(referenceDate: referenceDate)
        let tools = ToolChargeLedger.snapshot(referenceDate: referenceDate)
        return Status(todaySpentUSD: model.today + tools.today, monthSpentUSD: model.month + tools.month,
                      dailyBaseLimitUSD: configuredLimit(KeychainHelper.openRouterToolSpendLimitDailyUSDKey),
                      monthlyBaseLimitUSD: configuredLimit(KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey),
                      dailyExtraUSD: extra.daily, monthlyExtraUSD: extra.monthly, accounting: tools)
    }

    /// Why new paid work must pause, or nil.
    static func pauseReason(referenceDate: Date = Date()) -> String? {
        let status = status(referenceDate: referenceDate)
        if let exceeded = exceededMessage(todaySpentUSD: status.todaySpentUSD, monthSpentUSD: status.monthSpentUSD,
                                          dailyLimitUSD: status.effectiveDailyLimitUSD,
                                          monthlyLimitUSD: status.effectiveMonthlyLimitUSD) {
            return exceeded
        }
        return status.unverifiable ? unverifiableMessage(status.accounting) : nil
    }

    static func unverifiableMessage(_ snapshot: ToolChargeLedger.Snapshot) -> String {
        let list = (snapshot.incidents.map(ToolChargeLedger.describe) + snapshot.unidentified).joined(separator: "; ")
        return "I paused paid work because I can't verify today's spend: \(list). Fix the file (see `briglia doctor`), or send `/spend accept-unknown` to accept that these specific amounts are unknown and continue. (`/more1`, `/more5` and `/more10` raise a limit but can't make an unknown total known.)"
    }

    static func exceededMessage(todaySpentUSD: Double, monthSpentUSD: Double,
                                dailyLimitUSD: Double?, monthlyLimitUSD: Double?) -> String? {
        let dailyExceeded = dailyLimitUSD.map { todaySpentUSD >= $0 } ?? false
        let monthlyExceeded = monthlyLimitUSD.map { monthSpentUSD >= $0 } ?? false
        guard dailyExceeded || monthlyExceeded else { return nil }

        if dailyExceeded, monthlyExceeded, let dailyLimitUSD, let monthlyLimitUSD {
            return "I paused tool usage because both spend limits were reached (today: $\(formatUSD(todaySpentUSD)) / $\(formatUSD(dailyLimitUSD)); this month: $\(formatUSD(monthSpentUSD)) / $\(formatUSD(monthlyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or change the limits for good with `/spend daily <usd|off>` and `/spend monthly <usd|off>`."
        }
        if dailyExceeded, let dailyLimitUSD {
            return "I paused tool usage because the daily spend limit was reached (today: $\(formatUSD(todaySpentUSD)) / $\(formatUSD(dailyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or change it for good with `/spend daily <usd|off>` / `/spend monthly <usd|off>`."
        }
        if monthlyExceeded, let monthlyLimitUSD {
            return "I paused tool usage because the monthly spend limit was reached (this month: $\(formatUSD(monthSpentUSD)) / $\(formatUSD(monthlyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or change it for good with `/spend daily <usd|off>` / `/spend monthly <usd|off>`."
        }
        return nil
    }

    static func formatUSD(_ value: Double) -> String {
        var formatted = String(format: "%.6f", value)
        while formatted.contains(".") && formatted.last == "0" { formatted.removeLast() }
        if formatted.last == "." { formatted.removeLast() }
        return formatted
    }
}
