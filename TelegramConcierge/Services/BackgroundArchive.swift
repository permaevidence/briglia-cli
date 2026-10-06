import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Background archiving (BACKGROUND_ARCHIVE_PLAN v3 + Codex round 3)
//
// Only scheduling, the automatic prompt view and chunk-file lifetime change.
// Summary generation, fact extraction, consolidation, meta-summaries, their
// prompts and retry policies are untouched; the archive job body is the same
// code in both modes.

/// The archive part of one turn's automatically assembled prompt context,
/// captured once per turn (§4). `items` may end with a
/// `.liveOverlapDisclosure` item when rows were left out.
struct ArchivePromptView {
    let items: [ArchivedSummaryItem]
    /// Total chunk count for `formatChunkSummaries`, excluding the chunks
    /// represented by hidden rows (so the "older chunks predate this table"
    /// arithmetic stays true).
    let totalChunkCount: Int
    /// Ids of the rows left out because their source messages are live.
    let hiddenRowIds: [UUID]
    /// Chunk ids shown as individual rows: the "already an individual row"
    /// note of read_chunk_summaries uses this set (§4.4).
    let visibleChunkIds: Set<UUID>
    /// Lease keeping every chunk the view names resolvable (§5).
    let leaseId: UUID

    var hasHiddenRows: Bool { !hiddenRowIds.isEmpty }
}

/// Why a commit could not remove archived messages (§6, §7). Every case is
/// fail-closed: the live messages stay.
struct ArchiveCommitRefusal: Error, LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}

/// Baselines for the commit comparison (§6.2).
enum ArchiveCommitBaseline {
    /// In process: the batch exactly as the job selected it.
    case batchStart([Message])
    /// After a restart: the chunk's archived raw copy.
    case archivedRaw
}

enum ArchiveReconcileResult: Equatable {
    case reconciled
    /// The chunk writer is busy (consolidation, startup recovery): a normal
    /// deferred state, never an alert (§6.3).
    case writerBusy
}

/// Pure comparisons for §6.2. No model, no disk writes.
enum ArchiveCommitCheck {
    static let compressibleKinds: Set<MessageKind> = [.emailArrived, .subagentComplete, .reminderFired, .bashComplete]

    static func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    /// Content rule shared by both baselines: equal, or a compressible
    /// synthetic message replaced by its deterministic stub.
    static func contentAllowed(source: String, live: String, kind: MessageKind, stub: (MessageKind, String) -> String?) -> Bool {
        if source == live { return true }
        guard compressibleKinds.contains(kind) else { return false }
        return stub(kind, source) == live
    }

    /// Sanitized fields other than content, references and the media flag.
    private static func stableSanitizedFieldsEqual(_ a: Message, _ b: Message) -> Bool {
        a.id == b.id && a.role == b.role && a.kind == b.kind && a.timestamp == b.timestamp
            && a.imageFileNames == b.imageFileNames && a.documentFileNames == b.documentFileNames
            && a.imageFileSizes == b.imageFileSizes && a.documentFileSizes == b.documentFileSizes
            && a.referencedImageFileNames == b.referencedImageFileNames
            && a.referencedDocumentFileNames == b.referencedDocumentFileNames
            && a.referencedDocumentFileSizes == b.referencedDocumentFileSizes
            && a.downloadedDocumentFileNames == b.downloadedDocumentFileNames
            && a.editedFilePaths == b.editedFilePaths && a.generatedFilePaths == b.generatedFilePaths
            && a.accessedProjectIds == b.accessedProjectIds && a.subagentSessionEvents == b.subagentSessionEvents
    }

    /// Baseline A (§6.2): `start` is the batch message as the job selected
    /// it, `live` the current live copy. Returns nil when every difference
    /// is one of pruning's own transformations, otherwise the reason.
    static func baselineADelta(start s: Message, live l: Message,
                               sanitize: (Message) -> Message,
                               stub: (MessageKind, String) -> String?) -> String? {
        let ss = sanitize(s), sl = sanitize(l)
        guard stableSanitizedFieldsEqual(ss, sl) else { return "a stored field changed" }
        guard contentAllowed(source: s.content, live: l.content, kind: s.kind, stub: stub) else { return "content changed" }
        guard ss.mediaPruned == sl.mediaPruned || (!s.mediaPruned && l.mediaPruned) else { return "media flag changed" }
        let startRefs = Set(s.pruneArchiveReferences.map(\.id))
        let liveRefs = Set(l.pruneArchiveReferences.map(\.id))
        guard startRefs.isSubset(of: liveRefs) else { return "a snapshot reference disappeared" }
        let addedRefs = liveRefs.subtracting(startRefs)
        guard l.originChannel == s.originChannel else { return "origin changed" }

        // Fields the sanitized copy drops — each unchanged or changed only
        // in a direction pruning itself takes.
        let toolsRemoved = !s.toolInteractions.isEmpty && l.toolInteractions.isEmpty
        if encoded(l.toolInteractions) != encoded(s.toolInteractions) && !l.toolInteractions.isEmpty {
            return "tool interactions changed"
        }
        if l.compactToolLog != s.compactToolLog && l.compactToolLog != nil && !toolsRemoved {
            // A compact log is only (re)built from interactions being removed.
            return "compact tool log changed"
        }
        if encoded(l.finalReasoning) != encoded(s.finalReasoning) && l.finalReasoning != nil { return "reasoning changed" }
        if encoded(l.finalReasoningDetails) != encoded(s.finalReasoningDetails) && l.finalReasoningDetails != nil { return "reasoning changed" }
        if l.finalReasoningModel != s.finalReasoningModel && l.finalReasoningModel != nil { return "reasoning provenance changed" }
        if encoded(l.responsesReplay) != encoded(s.responsesReplay) && l.responsesReplay != nil { return "replay changed" }
        if encoded(l.activeTurnCompaction) != encoded(s.activeTurnCompaction) {
            guard l.activeTurnCompaction == nil, let moved = s.activeTurnCompaction?.latestSnapshotReference,
                  liveRefs.contains(moved.id) else { return "active-turn summary changed" }
        }
        // Prune summaries: set/extend (with a new snapshot reference) or
        // demotion (summary cleared, record whose snapshot is referenced).
        let startDemoted = s.demotedPruneSummaries.map { encoded($0) }
        let liveDemoted = l.demotedPruneSummaries.map { encoded($0) }
        guard liveDemoted.count >= startDemoted.count, Array(liveDemoted.prefix(startDemoted.count)) == startDemoted else {
            return "demoted summary lines changed"
        }
        let newDemotions = Array(l.demotedPruneSummaries.dropFirst(s.demotedPruneSummaries.count))
        guard newDemotions.allSatisfy({ liveRefs.contains($0.snapshot.id) }) else { return "demoted line without its snapshot" }
        let summaryChanged = l.prunedContextSummary != s.prunedContextSummary
            || encoded(l.prunedContextSummaryCoverage) != encoded(s.prunedContextSummaryCoverage)
        if summaryChanged {
            let demoted = !newDemotions.isEmpty && l.prunedContextSummary == nil && l.prunedContextSummaryCoverage == nil
            let extended = !addedRefs.isEmpty && l.prunedContextSummary != nil
            guard demoted || extended else { return "prune summary changed without a new snapshot" }
        }
        // measuredTokens / measuredToolTokens are accounting only.
        return nil
    }

    /// Baseline B (§6.2, restart): `raw` is the archived copy, `live` the
    /// live message. References only on the archive side are allowed.
    static func baselineBDelta(raw r: Message, live l: Message,
                               sanitize: (Message) -> Message,
                               stub: (MessageKind, String) -> String?) -> String? {
        let sl = sanitize(l)
        guard stableSanitizedFieldsEqual(r, sl) else { return "a stored field differs from the archived copy" }
        let contentOK = r.content == sl.content || contentAllowed(source: r.content, live: sl.content, kind: r.kind, stub: stub)
        guard contentOK else { return "content differs from the archived copy" }
        guard r.mediaPruned == sl.mediaPruned else { return "media flag differs from the archived copy" }
        return nil
    }

    /// True when any detail-bearing field (what a chunk-archive receipt
    /// preserves) differs between the selected batch and the live copy:
    /// the commit then saves the live detail in a fresh snapshot first.
    static func detailDiffers(start: Message, live: Message) -> Bool {
        live.prunedContextSummary != start.prunedContextSummary
            || encoded(live.prunedContextSummaryCoverage) != encoded(start.prunedContextSummaryCoverage)
            || encoded(live.demotedPruneSummaries) != encoded(start.demotedPruneSummaries)
            || (live.compactToolLog != nil && live.compactToolLog != start.compactToolLog)
    }
}

// MARK: - Snapshot coverage (Codex round 3 correction)

extension PruneArchiveStore {
    /// What a published snapshot covers: its header trigger and its
    /// "Removed message IDs" list. nil when the snapshot is missing,
    /// incomplete or unreadable. Integrity first (`isCompleteSnapshot`),
    /// then coverage — completeness alone never proves coverage.
    static func coverage(of reference: PruneArchiveReference, directory: URL = root) -> (trigger: String, removedIDs: Set<UUID>)? {
        guard isCompleteSnapshot(reference, directory: directory) else { return nil }
        let path = directory.appendingPathComponent(reference.basename).path
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        var lines: [String] = []
        var done = false
        // Header and the id list sit at the top; stop at the next section.
        while !done {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { done = true }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                lines.append(line)
                if line == "Removed active-turn call IDs:" { done = true; break }
            }
            if lines.count > 1_000_000 { return nil }
        }
        guard let first = lines.first, first.hasPrefix("BRIGLIA SNAPSHOT 1 "),
              let header = try? JSONDecoder().decode(Header.self, from: Data(first.dropFirst("BRIGLIA SNAPSHOT 1 ".count).utf8)),
              header.id == reference.id,
              let start = lines.firstIndex(of: "Removed message IDs:"),
              let end = lines.firstIndex(of: "Removed active-turn call IDs:"), end > start else { return nil }
        var ids: Set<UUID> = []
        for line in lines[(start + 1)..<end] {
            guard let id = UUID(uuidString: line) else { return nil }
            ids.insert(id)
        }
        return (header.trigger, ids)
    }

    /// True when the (complete) snapshot's text contains every string — used
    /// to decide whether live summary detail postdates a covering receipt.
    static func snapshot(_ reference: PruneArchiveReference, containsAll texts: [String], directory: URL = root) -> Bool {
        let wanted = texts.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return true }
        guard isCompleteSnapshot(reference, directory: directory),
              let data = FileManager.default.contents(atPath: directory.appendingPathComponent(reference.basename).path) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return wanted.allSatisfy { text.contains($0) }
    }

    /// A complete chunk-archive snapshot whose removed-id list includes
    /// every id in `ids`.
    static func chunkArchiveSnapshotCovers(_ reference: PruneArchiveReference, ids: Set<UUID>, directory: URL = root) -> Bool {
        guard let coverage = coverage(of: reference, directory: directory) else { return false }
        return coverage.trigger == "chunk-archive" && ids.isSubset(of: coverage.removedIDs)
    }
}
