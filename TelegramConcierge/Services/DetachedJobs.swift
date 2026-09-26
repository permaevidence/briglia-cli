import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Crash records and the persisted /stop marker (mid-turn early wake plan v7,
// §3.9 and §3.10; release 1a covers bash).
//
// Both files live under the data root, are private (0600, atomic write,
// parent fsync, errors checked), are never part of a Mind export, and are
// deleted by /deleteuserdata. An unreadable file is never overwritten:
// callers get an error and keep failing closed.

// MARK: - Crash records

/// One record per registered main-agent bash job that outlived its launching
/// call: wake-detached (§3.4), forced by the test setting (§3.13), an
/// initial wait that expired, or an explicit background launch
/// (wait_seconds=0). Written BEFORE the call returns its moved/handle result;
/// if that write fails the job is not detached (a woken wait keeps waiting).
struct DetachedJobRecord: Codable, Equatable {
    enum Launch: String, Codable {
        case background        // wait_seconds=0
        case waitExpired       // initial wait expired, job continues
        case wakeDetached      // a user message woke the wait (§3.4)
        case forcedDetach      // BRIGLIA_MIDTURN_FORCE_DETACH (§3.13)
    }
    /// §3.10.1. For bash every launch result is a moved result (the job
    /// continues and its completion is owed), so the live states are
    /// `returnedMoved` and, after a restart without evidence, `orphanedMoved`
    /// or `lost`.
    enum Disposition: String, Codable {
        case returnedMoved, orphanedMoved, lost
    }
    enum CompletionState: String, Codable {
        /// The model saw the final result (a durable receiptObserved
        /// binding): no notice is owed.
        case notOwed
        /// The completion notice (or lost-job note) is still owed.
        case owed
        /// The notice with `completionMessageId` reached durable history.
        case delivered
    }

    var version = 1
    let jobId: UUID
    var kind = "bash"
    /// The daemon process that owns the live job; records of another
    /// instance are from before a restart (their registry state is gone).
    let instanceId: UUID
    var turnRunId: UUID?
    var toolCallId: String?
    var callFingerprint: String?
    var handle: String
    var command: String
    var description: String?
    var workdir: String?
    var startedAt: Date
    var launch: Launch
    var disposition: Disposition = .returnedMoved
    /// Commit certificate (§3.12): a cached search result, never the only
    /// evidence. `certifiedKind` is monotonic: moved < receiptObserved.
    var certifiedKind: OutcomeBinding.Kind?
    var certifiedAt: Date?
    /// A retained obligation (§3.12.5): evidence could not be verified.
    var unverifiableReason: String?
    var unverifiableSince: Date?
    /// Set (checked write) by the prune/archive gate when history holding
    /// an UNVERIFIABLE evidence route for this job is removed: a receipt
    /// could have hidden there, so the obligation stays retained and
    /// reported — never delivered as if the evidence were absent.
    var routeRemovedWhileUnverifiable: String?
    /// Search hint only (§3.10.1): the call that observed the receipt.
    var settlementObservedBy: String?
    let completionMessageId: UUID
    var completion: CompletionState = .owed
    var deliveredAt: Date?
    /// The rendered completion notice, persisted when the job settles so a
    /// settled-but-undelivered job survives a restart with its real result
    /// (bounded tails, same text as the live notice).
    var completionBody: String?
    var settledAt: Date?
    /// Per-item stop disposition (§3.9.2): set by /stop, cleared only by
    /// settlement (retirement), never by a new user turn.
    var stopId: UUID?
    /// Search boundary for settlement evidence: the last history message at
    /// record creation. Evidence for this job can only live in messages
    /// appended after it (or anywhere, when it is gone).
    var historyAnchorMessageId: UUID?

    var isSettled: Bool { completion == .notOwed || completion == .delivered }
}

enum DetachedJobStore {
    struct Failure: Error, LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { detail }
    }
    private struct File: Codable {
        var version = 1
        var records: [DetachedJobRecord]
    }

    /// This process's identity, stamped on every record it creates. A var
    /// only so selftests can simulate a restart within one process.
    nonisolated(unsafe) static var instanceId = UUID()

    nonisolated(unsafe) static var directoryForTesting: URL?
    /// Fault injection (tests only): called before every write with an
    /// operation label; throwing simulates a storage failure.
    nonisolated(unsafe) static var faultForTesting: ((String) throws -> Void)?

    static var fileURL: URL {
        (directoryForTesting ?? StoragePaths.dataRoot).appendingPathComponent("detached-jobs.json")
    }
    private static let lock = NSRecursiveLock()

    /// Absent file → []. Present but unreadable/undecodable → throws (never
    /// read as empty, never overwritten).
    static func load() throws -> [DetachedJobRecord] {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw Failure("crash records unreadable: \(error.localizedDescription)") }
        do {
            let decoded = try JSONDecoder().decode(File.self, from: data)
            guard decoded.version == 1 else { throw Failure("unsupported crash-record version \(decoded.version)") }
            return decoded.records
        } catch let failure as Failure { throw failure }
        catch { throw Failure("crash records undecodable: \(error.localizedDescription)") }
    }

    /// Read-modify-write under the process lock. A load failure aborts
    /// without writing; an empty result removes the file (checked).
    @discardableResult
    static func mutate(_ label: String, _ body: (inout [DetachedJobRecord]) throws -> Void) throws -> [DetachedJobRecord] {
        lock.lock(); defer { lock.unlock() }
        var records = try load()
        let before = records
        try body(&records)
        guard records != before else { return records }
        try faultForTesting?(label)
        let url = fileURL
        if records.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                guard unlink(url.path) == 0 else {
                    throw Failure("could not remove \(url.path): \(String(cString: strerror(errno)))")
                }
                try PrivateStorage.fsyncDirectory(url.deletingLastPathComponent().path)
            }
            return records
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try PrivateStorage.ensureDirectory(url.deletingLastPathComponent())
        try PrivateStorage.writeAtomically(try encoder.encode(File(records: records)), to: url)
        return records
    }

    static func record(_ jobId: UUID) -> DetachedJobRecord? {
        (try? load())?.first { $0.jobId == jobId }
    }

    /// Insert a new record (§3.10.1: before the moved result is returned).
    /// The legacy snapshot list must exist first (Codex V7 gate 2: it is
    /// initialized before any job or snapshot can be created).
    static func create(_ record: DetachedJobRecord) throws {
        try SettlementEvidence.ensureLegacyListInitialized()
        try mutate("create") { records in
            records.removeAll { $0.jobId == record.jobId }
            records.append(record)
        }
        lock.lock(); createdIds.insert(record.jobId); lock.unlock()
    }

    /// Jobs whose record THIS process created (a durable write succeeded).
    /// A later wait on the same job reuses it without another read.
    private nonisolated(unsafe) static var createdIds = Set<UUID>()
    static func createdThisProcess(_ jobId: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return createdIds.contains(jobId)
    }
    /// Selftests simulate a new process within one binary.
    static func forgetCreatedForTesting() { lock.lock(); createdIds.removeAll(); lock.unlock() }

    static func update(_ jobId: UUID, _ label: String, _ body: (inout DetachedJobRecord) -> Void) throws {
        try mutate(label) { records in
            guard let index = records.firstIndex(where: { $0.jobId == jobId }) else { return }
            body(&records[index])
        }
    }

    /// Persist the rendered notice of a settled job (best effort: a failed
    /// write only means a crash before delivery yields a lost-job note).
    static func recordSettlement(jobId: UUID, body: String, at date: Date) {
        do {
            try update(jobId, "settle") { record in
                record.completionBody = body
                record.settledAt = date
            }
        } catch {
            print("[DetachedJobStore] could not persist settlement of \(jobId): \(error.localizedDescription)")
        }
    }

    /// Retire settled records (§3.10.1): completion not owed or delivered,
    /// and — for a stopped job — the stop disposition settles with it.
    static func retireSettled() throws {
        try mutate("retire") { records in
            records.removeAll { $0.isSettled }
        }
    }
}

// MARK: - Completion notice text

enum BashCompletionNotice {
    /// The `[BACKGROUND BASH COMPLETE]` body (moved verbatim from the
    /// manager's drain so the live notice and a persisted crash-record copy
    /// are byte-identical).
    static func body(for completion: BackgroundProcessRegistry.Completion) -> String {
        let statusLabel = Self.statusLabel(completion)
        let durationStr: String = {
            let secs = completion.durationSeconds
            if secs < 60 { return "\(secs)s" }
            if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
            return "\(secs / 3600)h \((secs % 3600) / 60)m"
        }()
        var body = """
        [BACKGROUND BASH COMPLETE]

        handle: \(completion.handleId)
        command: \(completion.command)
        status: \(statusLabel)
        duration: \(durationStr)
        """
        if let desc = completion.description, !desc.isEmpty {
            body += "\ndescription: \(desc)"
        }
        body += "\n\n--- stdout (tail) ---\n\(completion.stdoutTail)"
        if !completion.stderrTail.isEmpty {
            body += "\n\n--- stderr (tail) ---\n\(completion.stderrTail)"
        }
        if let p = completion.stdoutFullPath {
            body += "\n\nComplete stdout saved to: \(p) (read with read_file or grep)"
        }
        if let p = completion.stderrFullPath {
            body += "\nComplete stderr saved to: \(p)"
        }
        body += "\n\n[END OF BACKGROUND TASK - If the user asked you to notify them when this finished, do so now.]"
        return body
    }

    static func statusLabel(_ completion: BackgroundProcessRegistry.Completion) -> String {
        switch completion.status {
        case .exited:  return completion.exitCode == 0 ? "exited cleanly" : "exited with code \(completion.exitCode)"
        case .killed:  return "killed"
        case .crashed: return "crashed with signal"
        case .running: return "unexpectedly still running"
        case .timedOut: return "killed at its execution deadline (kill_after_seconds)"
        }
    }

    /// Suffix appended to a notice of a job stopped by /stop (§3.9.2 —
    /// harness-authored bodies carry the note inline).
    static let stoppedNote = "\n\n[Stopped by /stop — the user asked to stop this work. Do not restart it unless they ask again.]"

    /// A job whose registry state died with a previous process (§3.10.4).
    static func lostNote(for record: DetachedJobRecord) -> String {
        var body = """
        [BACKGROUND BASH LOST]

        handle: \(record.handle)
        command: \(record.command)
        status: lost in a restart — Briglia stopped before this job's result was recorded; its output is unknown
        """
        if let desc = record.description, !desc.isEmpty { body += "\ndescription: \(desc)" }
        body += "\n\n[END OF BACKGROUND TASK - Check external state before repeating it. If the user asked you to notify them when this finished, tell them it was lost in a restart.]"
        return body
    }
}

// MARK: - /stop marker (§3.9)

/// One unsettled /stop. Repeated /stop APPENDS an entry; an entry retires
/// only once every item it lists is durably settled.
struct StopEntry: Codable, Equatable {
    let stopId: UUID
    let at: Date
    /// The active-turn marker's trigger when /stop ran (never resumed).
    var stoppedTurnTriggerId: UUID?
    /// Canonical ids of every `.userText` queued when /stop ran (O-S1:
    /// held — kept in history, not answered until the user writes again).
    var heldQueueMessageIds: [UUID]
    /// Pre-minted id of the "sent before /stop" harness note, so every
    /// append of it is id-deduplicated across crashes.
    let heldNoteMessageId: UUID
    /// Every unsettled agent-started item: running jobs, finished jobs whose
    /// notice is still queued, owner jobs of pending watch matches.
    var affectedJobIds: [UUID]
    var affectedWatchMatchIds: [UUID]
    /// Conservative dispositions for recovery state that could not be read
    /// when /stop ran (absent from older markers and omitted when nil, so
    /// existing marker bytes are unchanged):
    /// - an active-turn marker existed but could not be read: no
    ///   interrupted turn that started at or before `at` is ever resumed;
    /// - the held-message queue file existed but could not be read: every
    ///   queued user message timestamped at or before `at` is held.
    var stoppedUnreadableTurnMarker: Bool? = nil
    var heldUnreadableQueue: Bool? = nil

    /// Whether this stop covers an interrupted turn described by a marker.
    func coversInterruptedTurn(triggerId: UUID, startedAt: Date) -> Bool {
        stoppedTurnTriggerId == triggerId || (stoppedUnreadableTurnMarker == true && startedAt <= at)
    }

    /// Whether this stop holds a queued user message.
    func holds(_ message: Message) -> Bool {
        heldQueueMessageIds.contains(message.id)
            || (heldUnreadableQueue == true && message.kind == .userText && message.timestamp <= at)
    }
}

/// What startup knows about earlier /stops before anything is recovered.
enum StopIntent: Equatable {
    case none
    case known(entries: [StopEntry])
    /// The marker exists but cannot be read: nothing recovered may start
    /// work (fail closed) until the owner checks it.
    case unknown(reason: String)

    var stoppedJobIds: Set<UUID> {
        if case .known(let entries) = self { return Set(entries.flatMap(\.affectedJobIds)) }
        return []
    }
    var heldMessageIds: Set<UUID> {
        if case .known(let entries) = self { return Set(entries.flatMap(\.heldQueueMessageIds)) }
        return []
    }
    var stoppedTriggerIds: Set<UUID> {
        if case .known(let entries) = self { return Set(entries.compactMap(\.stoppedTurnTriggerId)) }
        return []
    }
    var isUnknown: Bool { if case .unknown = self { return true }; return false }
    var entries: [StopEntry] {
        if case .known(let entries) = self { return entries }
        return []
    }
}

enum StopMarkerStore {
    private struct File: Codable {
        var version = 2
        var entries: [StopEntry]
    }
    nonisolated(unsafe) static var directoryForTesting: URL?
    nonisolated(unsafe) static var faultForTesting: ((String) throws -> Void)?
    static var fileURL: URL {
        (directoryForTesting ?? StoragePaths.dataRoot).appendingPathComponent("stop-marker.json")
    }
    private static let lock = NSRecursiveLock()

    static func load() -> StopIntent {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url) else { return .unknown(reason: "stop marker unreadable") }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == 2 else {
            return .unknown(reason: "stop marker undecodable")
        }
        return file.entries.isEmpty ? .none : .known(entries: file.entries)
    }

    /// Append one entry (checked). Throws on any failure, including an
    /// unreadable existing marker (never overwritten).
    static func append(_ entry: StopEntry) throws {
        lock.lock(); defer { lock.unlock() }
        var entries: [StopEntry] = []
        switch load() {
        case .none: break
        case .known(let existing): entries = existing
        case .unknown(let reason): throw DetachedJobStore.Failure(reason + " — not overwritten")
        }
        entries.append(entry)
        try write(entries, label: "append")
    }

    /// Replace the entry list (retirement). Empty removes the file.
    static func replace(_ entries: [StopEntry]) throws {
        lock.lock(); defer { lock.unlock() }
        try write(entries, label: "retire")
    }

    private static func write(_ entries: [StopEntry], label: String) throws {
        try faultForTesting?(label)
        let url = fileURL
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                guard unlink(url.path) == 0 else {
                    throw DetachedJobStore.Failure("could not remove stop marker: \(String(cString: strerror(errno)))")
                }
                try PrivateStorage.fsyncDirectory(url.deletingLastPathComponent().path)
            }
            return
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try PrivateStorage.ensureDirectory(url.deletingLastPathComponent())
        try PrivateStorage.writeAtomically(try encoder.encode(File(entries: entries)), to: url)
    }
}
