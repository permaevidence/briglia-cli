import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Typed settlement evidence outside conversation.json (mid-turn early wake
// plan v7 §3.12.3–§3.12.5, Codex V7 acceptance gates 1–2).
//
// Snapshots stay exactly as they were (prose, header v1 — an older binary's
// retention reads only the first 4 KB of a snapshot and rejects any other
// header version). What a snapshot can PROVE about a job lives in a typed
// sidecar written and fsynced BEFORE the snapshot is published. Prose is
// never parsed: "Call ID:", "Result call ID:" or "Prior snapshot:" lines can
// occur inside ordinary tool output.
//
//   prune-archive-settlements/<snapshot-uuid>.json   one sidecar per snapshot
//   prune-archive-settlements/legacy.json            snapshots that predate
//                                                    this binary (no sidecar
//                                                    by design); written once
//   prune-archive-settlements/expired.json           snapshots removed by
//                                                    retention (held no open
//                                                    proof when removed)

struct SettlementSidecar: Codable, Equatable {
    enum View: String, Codable {
        /// The round belonged to a message in the durable (saved) view.
        case durable
        /// A current in-flight round the snapshot removed.
        case carried
    }
    struct Entry: Codable, Equatable {
        let toolCallId: String
        let binding: OutcomeBinding
        let view: View
    }
    /// Mid-turn round delivery (plan MIDTURN_ROUND_DELIVERY v3 §2.6): the
    /// completion message ids a snapshotted tool result carried as appended
    /// background results. A SIBLING array (not an `Entry`), so an older
    /// binary's `Entry` shape — which requires a binding — never sees it,
    /// and the key is simply ignored by older readers.
    struct Delivery: Codable, Equatable {
        let toolCallId: String
        let completionIds: [UUID]
        let view: View
    }
    var version = 1
    let snapshotId: UUID
    let created: Date
    /// True for active-turn compaction / overflow snapshots: such a snapshot
    /// is referenced only by the outcome message of the turn whose rounds it
    /// carried, so a `carried` entry settles only when reached from a durable
    /// root through a chain of turn-outcome snapshots (the owning context).
    let turnOutcome: Bool
    /// Typed links used for traversal (never recovered from prose): the
    /// prior active-turn summary's snapshot within the same turn chain.
    let predecessors: [PruneArchiveReference]
    let entries: [Entry]
    /// Delivery bookkeeping; empty (and omitted on disk) for every snapshot
    /// that carried no mid-turn background result.
    var deliveries: [Delivery] = []
    /// Set when a present `deliveries` value could not be decoded: delivery
    /// lookups through this sidecar are unverifiable (never absent, never
    /// found); the binding entries stay usable. Never encoded.
    var deliveriesMalformed = false

    enum CodingKeys: String, CodingKey {
        case version, snapshotId, created, turnOutcome, predecessors, entries, deliveries
    }

    init(version: Int = 1, snapshotId: UUID, created: Date, turnOutcome: Bool,
         predecessors: [PruneArchiveReference], entries: [Entry], deliveries: [Delivery] = []) {
        self.version = version; self.snapshotId = snapshotId; self.created = created
        self.turnOutcome = turnOutcome; self.predecessors = predecessors; self.entries = entries
        self.deliveries = deliveries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        snapshotId = try c.decode(UUID.self, forKey: .snapshotId)
        created = try c.decode(Date.self, forKey: .created)
        turnOutcome = try c.decode(Bool.self, forKey: .turnOutcome)
        predecessors = try c.decode([PruneArchiveReference].self, forKey: .predecessors)
        entries = try c.decode([Entry].self, forKey: .entries)
        if c.contains(.deliveries) {
            if let decoded = try? c.decode([Delivery].self, forKey: .deliveries) { deliveries = decoded }
            else { deliveriesMalformed = true }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(snapshotId, forKey: .snapshotId)
        try c.encode(created, forKey: .created)
        try c.encode(turnOutcome, forKey: .turnOutcome)
        try c.encode(predecessors, forKey: .predecessors)
        try c.encode(entries, forKey: .entries)
        if !deliveries.isEmpty { try c.encode(deliveries, forKey: .deliveries) }
    }
}

enum SettlementEvidence {
    struct Failure: Error, LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { detail }
    }

    private struct IdList: Codable {
        var version = 1
        var snapshotIds: [UUID]
    }

    /// Directory beside `prune-archives/` (a separate directory keeps the
    /// snapshot directory byte- and entry-compatible with older binaries).
    static func directory(forSnapshots snapshots: URL = PruneArchiveStore.root) -> URL {
        snapshots.deletingLastPathComponent().appendingPathComponent("prune-archive-settlements", isDirectory: true)
    }
    static func sidecarURL(_ id: UUID, snapshots: URL = PruneArchiveStore.root) -> URL {
        directory(forSnapshots: snapshots).appendingPathComponent(id.uuidString.lowercased() + ".json")
    }
    private static func legacyURL(_ snapshots: URL) -> URL {
        directory(forSnapshots: snapshots).appendingPathComponent("legacy.json")
    }
    private static func expiredURL(_ snapshots: URL) -> URL {
        directory(forSnapshots: snapshots).appendingPathComponent("expired.json")
    }

    nonisolated(unsafe) static var faultForTesting: ((String) throws -> Void)?
    private static let lock = NSRecursiveLock()

    // MARK: Legacy list (§3.12.3; Codex V7 gate 2)

    /// Create the settlements directory together with `legacy.json` — the ids
    /// of every snapshot present at that moment — exactly once: staged in a
    /// sibling directory, fsynced, then renamed into place, so the directory
    /// never exists without its list. Called before any new job record or
    /// sidecar'd snapshot is created. If the directory already exists the
    /// list is NEVER recreated (a lost or unreadable list is not rebuilt by
    /// reclassifying current snapshots as legacy): sidecar-less snapshots then
    /// read as unverifiable, never as absent.
    static func ensureLegacyListInitialized(snapshots: URL = PruneArchiveStore.root) throws {
        lock.lock(); defer { lock.unlock() }
        let dir = directory(forSnapshots: snapshots)
        var st = stat()
        if lstat(dir.path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFDIR else { throw Failure("settlement evidence path is not a directory: \(dir.path)") }
            return
        }
        guard errno == ENOENT else { throw Failure("inspect \(dir.path): \(String(cString: strerror(errno)))") }
        try faultForTesting?("legacy-init")
        let parent = dir.deletingLastPathComponent()
        try PrivateStorage.ensureDirectory(parent)
        let ids = try PruneArchiveStore.entries(directory: snapshots).map(\.reference.id)
        let staging = parent.appendingPathComponent(".prune-archive-settlements.staging-\(UUID().uuidString)", isDirectory: true)
        try PrivateStorage.ensureDirectory(staging)
        do {
            try PrivateStorage.writeAtomically(try JSONEncoder().encode(IdList(snapshotIds: ids)),
                                               to: staging.appendingPathComponent("legacy.json"))
            guard rename(staging.path, dir.path) == 0 else {
                throw Failure("publish \(dir.path): \(String(cString: strerror(errno)))")
            }
            try PrivateStorage.fsyncDirectory(parent.path)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    enum ListState: Equatable { case ids(Set<UUID>), missing, unreadable }

    private static func readList(_ url: URL) -> ListState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(IdList.self, from: data), list.version == 1 else { return .unreadable }
        return .ids(Set(list.snapshotIds))
    }

    static func legacyIds(snapshots: URL = PruneArchiveStore.root) -> ListState { readList(legacyURL(snapshots)) }
    static func expiredIds(snapshots: URL = PruneArchiveStore.root) -> ListState { readList(expiredURL(snapshots)) }

    /// Mind import (stage B): the imported snapshots join the legacy list
    /// (import discards every job record of the replaced conversation, so no
    /// live record can predate an imported snapshot). Replaces the evidence
    /// directory wholesale: old sidecars described the replaced history.
    static func resetForReplacedHistory(snapshots: URL = PruneArchiveStore.root) throws {
        lock.lock(); defer { lock.unlock() }
        let dir = directory(forSnapshots: snapshots)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
            try PrivateStorage.fsyncDirectory(dir.deletingLastPathComponent().path)
        }
        try ensureLegacyListInitialized(snapshots: snapshots)
    }

    // MARK: Sidecar writing (called by PruneArchiveStore.write before `link`)

    static func writeSidecar(_ sidecar: SettlementSidecar, snapshots: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureLegacyListInitialized(snapshots: snapshots)
        try faultForTesting?("sidecar")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try PrivateStorage.writeAtomically(try encoder.encode(sidecar), to: sidecarURL(sidecar.snapshotId, snapshots: snapshots))
    }

    /// Build the typed sidecar for a snapshot being written.
    static func sidecar(snapshotId: UUID, created: Date, trigger: String,
                        durable messages: [Message], carried rounds: [ToolInteraction],
                        priorActiveSummary: ActiveTurnCompaction?) -> SettlementSidecar {
        var entries: [SettlementSidecar.Entry] = []
        for message in messages {
            for round in message.toolInteractions {
                for result in round.results {
                    if let binding = result.outcomeBinding, binding.kind.carriesJob {
                        entries.append(.init(toolCallId: result.toolCallId, binding: binding, view: .durable))
                    }
                }
            }
        }
        for round in rounds {
            for result in round.results {
                if let binding = result.outcomeBinding, binding.kind.carriesJob {
                    entries.append(.init(toolCallId: result.toolCallId, binding: binding, view: .carried))
                }
            }
        }
        // Mid-turn round delivery: the typed delivery ids ride beside the
        // bindings, with the same durable/carried views.
        var deliveries: [SettlementSidecar.Delivery] = []
        for message in messages {
            for round in message.toolInteractions {
                for result in round.results where !result.deliveredCompletions.isEmpty {
                    deliveries.append(.init(toolCallId: result.toolCallId, completionIds: result.deliveredCompletions, view: .durable))
                }
            }
        }
        for round in rounds {
            for result in round.results where !result.deliveredCompletions.isEmpty {
                deliveries.append(.init(toolCallId: result.toolCallId, completionIds: result.deliveredCompletions, view: .carried))
            }
        }
        return SettlementSidecar(snapshotId: snapshotId, created: created,
                                 turnOutcome: trigger == "active-turn-compaction",
                                 predecessors: [priorActiveSummary?.latestSnapshotReference].compactMap { $0 },
                                 entries: entries, deliveries: deliveries)
    }

    enum SidecarState: Equatable { case present(SettlementSidecar), missing, unreadable }

    static func loadSidecar(_ id: UUID, snapshots: URL = PruneArchiveStore.root) -> SidecarState {
        let url = sidecarURL(id, snapshots: snapshots)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(SettlementSidecar.self, from: data),
              sidecar.version == 1, sidecar.snapshotId == id else { return .unreadable }
        return .present(sidecar)
    }

    // MARK: locateSettlement (§3.12.2; Codex V7 gate 1)

    enum Outcome: Equatable {
        /// The strongest durable binding for the job (receiptObserved beats
        /// real beats moved — successive facts, never conflicting ones).
        case bound(OutcomeBinding.Kind)
        /// Every reached evidence source was verified; no binding names it.
        case absent
        /// Some reached evidence could not be verified. Never treated as
        /// found or absent: the obligation is retained.
        case unverifiable(String)
    }

    private static func rank(_ kind: OutcomeBinding.Kind) -> Int {
        switch kind {
        case .receiptObserved: return 3
        case .real: return 2
        case .moved: return 1
        default: return 0
        }
    }

    /// Search DURABLE history for the job's typed binding. `history` must be
    /// durable (as loaded from disk, or the messages covered by the last
    /// successful save). Roots are the messages appended after the record's
    /// anchor (all messages when the anchor is gone): evidence for a job can
    /// only be carried by history created after it. Placeholder, cancelled,
    /// not-executed and unbound results never count; neither does text.
    ///
    /// Monotonic reduction (Codex V7 gate 1): a durable receiptObserved
    /// settles the job even when a moved result is also present — whatever
    /// the enumeration order, and whatever a cached certificate says. A
    /// receipt found anywhere wins; otherwise any unverifiable source makes
    /// the outcome unverifiable (a receipt could hide there); otherwise the
    /// strongest remaining binding, or absent.
    static func locate(_ record: DetachedJobRecord, history: [Message],
                       snapshots: URL = PruneArchiveStore.root) -> Outcome {
        var roots = history
        if let anchor = record.historyAnchorMessageId, let index = history.firstIndex(where: { $0.id == anchor }) {
            roots = Array(history[(index + 1)...])
        }
        var best: OutcomeBinding.Kind?
        var problem: String?
        func consider(_ binding: OutcomeBinding) {
            guard binding.kind.carriesJob, binding.jobId == record.jobId else { return }
            if let fp = binding.fingerprint, let expected = record.callFingerprint, binding.kind != .receiptObserved, fp != expected {
                problem = problem ?? "fingerprint mismatch on a bound result"
                return
            }
            if best.map({ rank($0) < rank(binding.kind) }) ?? true { best = binding.kind }
        }
        let legacy = legacyIds(snapshots: snapshots)
        let expired = expiredIds(snapshots: snapshots)
        // Visitation is keyed by snapshot AND effective ownership (Codex 1a
        // R2, CX2a): reaching a snapshot first through a non-owning path must
        // not suppress a later owning visit, which may accept its carried
        // entries. An owning visit subsumes a non-owning one.
        var visited: [UUID: Bool] = [:]
        func traverse(_ ref: PruneArchiveReference, owning: Bool) {
            if let seenOwning = visited[ref.id], seenOwning || !owning { return }
            visited[ref.id] = owning
            let snapshotPath = snapshots.appendingPathComponent(ref.basename).path
            let exists = FileManager.default.fileExists(atPath: snapshotPath)
            if !exists {
                if case .ids(let set) = expired, set.contains(ref.id) { return }
                problem = problem ?? "snapshot \(ref.basename) missing"
                return
            }
            switch loadSidecar(ref.id, snapshots: snapshots) {
            case .missing:
                if case .ids(let set) = legacy, set.contains(ref.id) { return }
                problem = problem ?? "snapshot \(ref.basename) has no settlement sidecar and is not listed as legacy"
            case .unreadable:
                problem = problem ?? "settlement sidecar of \(ref.basename) unreadable"
            case .present(let sidecar):
                guard PruneArchiveStore.isCompleteSnapshot(ref, directory: snapshots) else {
                    problem = problem ?? "snapshot \(ref.basename) incomplete"
                    return
                }
                // Owning context propagates only through turn-outcome links.
                let owningHere = owning && sidecar.turnOutcome
                for entry in sidecar.entries {
                    switch entry.view {
                    case .durable: consider(entry.binding)
                    case .carried: if owningHere { consider(entry.binding) }
                    }
                }
                for predecessor in sidecar.predecessors { traverse(predecessor, owning: owningHere) }
            }
        }
        for message in roots {
            for round in message.toolInteractions {
                for result in round.results { if let binding = result.outcomeBinding { consider(binding) } }
            }
            var refs = message.pruneArchiveReferences
            if let active = message.activeTurnCompaction?.latestSnapshotReference { refs.append(active) }
            for ref in refs { traverse(ref, owning: true) }
        }
        if best == .receiptObserved { return .bound(.receiptObserved) }
        // A subagent job has no receipts: a durable real result for its own
        // job id is terminal (release 1b) — nothing stronger could hide in an
        // unverifiable source.
        if best == .real && record.isSubagent { return .bound(.real) }
        if let problem { return .unverifiable(problem) }
        if let best { return .bound(best) }
        return .absent
    }

    // MARK: Delivery evidence (mid-turn round delivery v3 §2.6–§2.7)

    enum DeliveryOutcome: Equatable {
        /// A durable tool result (inline or in a reachable snapshot) carried
        /// the completion as appended background results.
        case delivered
        case absent
        case unverifiable(String)
    }

    /// The completion ids among `wanted` that durable history carries as
    /// mid-turn background results: typed `deliveredCompletions` on inline
    /// results, and sidecar `deliveries` reached through the same snapshot
    /// traversal and owning rule as bindings. Prose (`completion_id:` lines)
    /// is never read. `problem` is set when some reached source could not be
    /// verified (a missing, unreadable, incomplete or malformed route).
    static func deliveredIds(_ wanted: Set<UUID>, roots: [Message],
                             snapshots: URL = PruneArchiveStore.root) -> (found: Set<UUID>, problem: String?) {
        guard !wanted.isEmpty else { return ([], nil) }
        var found = Set<UUID>()
        var problem: String?
        let legacy = legacyIds(snapshots: snapshots)
        let expired = expiredIds(snapshots: snapshots)
        var visited: [UUID: Bool] = [:]
        func traverse(_ ref: PruneArchiveReference, owning: Bool) {
            if let seenOwning = visited[ref.id], seenOwning || !owning { return }
            visited[ref.id] = owning
            let exists = FileManager.default.fileExists(atPath: snapshots.appendingPathComponent(ref.basename).path)
            if !exists {
                if case .ids(let set) = expired, set.contains(ref.id) { return }
                problem = problem ?? "snapshot \(ref.basename) missing"
                return
            }
            switch loadSidecar(ref.id, snapshots: snapshots) {
            case .missing:
                if case .ids(let set) = legacy, set.contains(ref.id) { return }
                problem = problem ?? "snapshot \(ref.basename) has no settlement sidecar and is not listed as legacy"
            case .unreadable:
                problem = problem ?? "settlement sidecar of \(ref.basename) unreadable"
            case .present(let sidecar):
                guard PruneArchiveStore.isCompleteSnapshot(ref, directory: snapshots) else {
                    problem = problem ?? "snapshot \(ref.basename) incomplete"
                    return
                }
                if sidecar.deliveriesMalformed { problem = problem ?? "delivery data of \(ref.basename) malformed" }
                let owningHere = owning && sidecar.turnOutcome
                for item in sidecar.deliveries where item.view == .durable || owningHere {
                    found.formUnion(wanted.intersection(item.completionIds))
                }
                for predecessor in sidecar.predecessors { traverse(predecessor, owning: owningHere) }
            }
        }
        for message in roots {
            for round in message.toolInteractions {
                for result in round.results where !result.deliveredCompletions.isEmpty {
                    found.formUnion(wanted.intersection(result.deliveredCompletions))
                }
            }
            var refs = message.pruneArchiveReferences
            if let active = message.activeTurnCompaction?.latestSnapshotReference { refs.append(active) }
            for ref in refs { traverse(ref, owning: true) }
        }
        return (found, problem)
    }

    /// Whether durable `history` proves the record's completion was carried
    /// into a turn as tool output. Roots start after the record's anchor, as
    /// for bindings. Found anywhere wins over an unverifiable route.
    static func locateDelivery(_ record: DetachedJobRecord, history: [Message],
                               snapshots: URL = PruneArchiveStore.root) -> DeliveryOutcome {
        var roots = history
        if let anchor = record.historyAnchorMessageId, let index = history.firstIndex(where: { $0.id == anchor }) {
            roots = Array(history[(index + 1)...])
        }
        let (found, problem) = deliveredIds([record.completionMessageId], roots: roots, snapshots: snapshots)
        if !found.isEmpty { return .delivered }
        if let problem { return .unverifiable(problem) }
        return .absent
    }

    // MARK: Proof-pinned retention (§3.12.4; Codex V7 gate 2)

    /// Snapshots retention must keep: every snapshot whose sidecar is proof
    /// for an open (unsettled) record, PLUS every snapshot whose typed
    /// predecessor chain reaches one — so the whole discovery path from a
    /// durable root survives, not just the proof file. Unreadable sidecars
    /// pin themselves and their successors; an unreadable records file pins
    /// every snapshot holding any binding (never "nothing to protect").
    static func pinnedSnapshotIds(snapshots: URL, entries: [PruneArchiveStore.Entry]) -> Set<UUID> {
        let openJobs: Set<UUID>?
        let openCompletions: Set<UUID>?
        do {
            let open = try DetachedJobStore.load().filter { !$0.isSettled }
            openJobs = Set(open.map(\.jobId)); openCompletions = Set(open.map(\.completionMessageId))
        } catch { openJobs = nil; openCompletions = nil }
        var seeds = Set<UUID>()
        var predecessors: [UUID: [UUID]] = [:]
        for entry in entries {
            switch loadSidecar(entry.reference.id, snapshots: snapshots) {
            case .missing: continue
            case .unreadable: seeds.insert(entry.reference.id)
            case .present(let sidecar):
                predecessors[entry.reference.id] = sidecar.predecessors.map(\.id)
                let holds = sidecar.entries.contains { item in
                    guard let job = item.binding.jobId else { return false }
                    return openJobs.map { $0.contains(job) } ?? true
                }
                // A delivery naming an open record's completion is proof too
                // (round delivery §2.7); malformed delivery data pins itself.
                let delivers = sidecar.deliveriesMalformed || sidecar.deliveries.contains { item in
                    openCompletions.map { !$0.isDisjoint(with: item.completionIds) } ?? true
                }
                if holds || delivers { seeds.insert(entry.reference.id) }
            }
        }
        guard !seeds.isEmpty else { return [] }
        // Reverse reachability: any snapshot whose chain leads to a seed.
        var pinned = seeds
        var changed = true
        while changed {
            changed = false
            for (id, preds) in predecessors where !pinned.contains(id) {
                if preds.contains(where: { pinned.contains($0) }) { pinned.insert(id); changed = true }
            }
        }
        return pinned
    }

    /// Record a snapshot as expired by retention BEFORE it is unlinked (a
    /// crash in between leaves the file and the entry; traversal finds the
    /// file). Checked; a failure keeps the snapshot.
    static func noteExpired(_ ids: [UUID], snapshots: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard !ids.isEmpty else { return }
        var current: [UUID] = []
        switch expiredIds(snapshots: snapshots) {
        case .ids(let set): current = Array(set)
        case .missing: break
        case .unreadable: throw Failure("expired-snapshot list unreadable; retention kept every snapshot")
        }
        try ensureLegacyListInitialized(snapshots: snapshots)
        try faultForTesting?("expired")
        let merged = Array(Set(current).union(ids)).sorted { $0.uuidString < $1.uuidString }
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(IdList(snapshotIds: merged)), to: expiredURL(snapshots))
    }

    static func removeSidecar(_ id: UUID, snapshots: URL) {
        let url = sidecarURL(id, snapshots: snapshots)
        if FileManager.default.fileExists(atPath: url.path) { unlink(url.path) }
    }

    /// Orphan sidecars (their snapshot is gone) are swept at start.
    static func sweepOrphanSidecars(snapshots: URL = PruneArchiveStore.root) {
        let dir = directory(forSnapshots: snapshots)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let live = try? Set(PruneArchiveStore.entries(directory: snapshots).map(\.reference.id)) else { return }
        for name in names where name.hasSuffix(".json") && name != "legacy.json" && name != "expired.json" {
            guard let id = UUID(uuidString: String(name.dropLast(5))), !live.contains(id) else { continue }
            unlink(dir.appendingPathComponent(name).path)
        }
    }
}
