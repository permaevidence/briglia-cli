import Foundation

// MARK: - Conversation Chunk Model

/// Represents an archived segment of conversation history
struct ConversationChunk: Codable, Identifiable {
    let id: UUID
    let type: ChunkType
    let startDate: Date
    let endDate: Date
    let tokenCount: Int
    let messageCount: Int
    let summary: String
    let rawContentFileName: String
    var pruneArchiveReferences: [PruneArchiveReference]? = nil
    var sourceMessageIDs: [UUID]? = nil
    var summaryWithSnapshotReferences: String {
        let names = (pruneArchiveReferences ?? []).map(\.basename)
        return names.isEmpty ? summary : summary + "\nSnapshots: " + names.joined(separator: ", ")
    }

    
    enum ChunkType: String, Codable {
        case temporary    // Size based on user setting (default 25k)
        case consolidated // 4 temporary chunks merged
    }
    
    /// Display-friendly size label based on actual token count
    var sizeLabel: String {
        if tokenCount >= 1000 {
            return "\(tokenCount / 1000)k"
        } else {
            return "\(tokenCount)"
        }
    }
}

// Keep the synthesized memberwise initializer and encoder. Only the additive
// reference collection is lenient; required chunk metadata remains validated.
extension ConversationChunk {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(ChunkType.self, forKey: .type)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        tokenCount = try c.decode(Int.self, forKey: .tokenCount)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        summary = try c.decode(String.self, forKey: .summary)
        rawContentFileName = try c.decode(String.self, forKey: .rawContentFileName)
        let references = PruneArchiveReference.decodeLeniently(from: c, forKey: .pruneArchiveReferences)
        pruneArchiveReferences = references.isEmpty ? nil : references
        sourceMessageIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceMessageIDs)
    }
}

// MARK: - Historical Meta Summaries

/// Represents a prompt-only summary derived from older consolidated chunk summaries.
struct HistoricalMetaSummary: Codable, Identifiable {
    let id: UUID
    let kind: MetaSummaryKind
    let startDate: Date
    let endDate: Date
    let childChunkIds: [UUID]
    let summary: String
    let createdAt: Date
    let updatedAt: Date

    enum MetaSummaryKind: String, Codable {
        case sealedBatch
        case rolling
    }
}

/// Unified prompt-facing view over archived history.
struct ArchivedSummaryItem: Identifiable {
    let id: UUID
    let kind: Kind
    let startDate: Date
    let endDate: Date
    let tokenCount: Int
    let messageCount: Int
    let summary: String
    let sourceChunkCount: Int
    /// True when this item's chunk (or, for meta-summaries, any child chunk)
    /// has no plaintext sidecar on disk right now — grep-based recall is
    /// blind to it until backfill regenerates the file.
    var sidecarMissing: Bool = false
    /// For meta-summary rows: ids of the compressed child chunks, printed in
    /// the prompt table so the agent can expand the row into per-chunk
    /// summaries via read_chunk_summaries. Empty for individual chunk rows.
    var childChunkIds: [UUID] = []
    var hasSnapshotReferences: Bool = false

    enum Kind {
        case temporaryChunk
        case consolidatedChunk
        case rollingMetaSummary
        case sealedMetaSummary
    }

    var sizeLabel: String {
        switch kind {
        case .temporaryChunk, .consolidatedChunk:
            if tokenCount >= 1000 {
                return "\(tokenCount / 1000)k"
            } else {
                return "\(tokenCount)"
            }
        case .rollingMetaSummary:
            return "rolling-\(sourceChunkCount)"
        case .sealedMetaSummary:
            return "meta-\(sourceChunkCount)"
        }
    }

    var historyLabel: String {
        switch kind {
        case .temporaryChunk:
            return "Temporary chunk"
        case .consolidatedChunk:
            return "Consolidated chunk"
        case .rollingMetaSummary:
            return "Rolling history summary"
        case .sealedMetaSummary:
            return "Historical meta-summary"
        }
    }
}

// MARK: - Stable Archive Ordering

private func archiveDateKey(_ date: Date) -> Double {
    let value = date.timeIntervalSinceReferenceDate
    return value.isFinite ? value : .greatestFiniteMagnitude
}

private func archiveDateRangeIsOrderedBefore(
    lhsStart: Date,
    lhsEnd: Date,
    lhsId: UUID,
    rhsStart: Date,
    rhsEnd: Date,
    rhsId: UUID
) -> Bool {
    let lhsStartKey = archiveDateKey(lhsStart)
    let rhsStartKey = archiveDateKey(rhsStart)
    if lhsStartKey != rhsStartKey { return lhsStartKey < rhsStartKey }

    let lhsEndKey = archiveDateKey(lhsEnd)
    let rhsEndKey = archiveDateKey(rhsEnd)
    if lhsEndKey != rhsEndKey { return lhsEndKey < rhsEndKey }

    return lhsId.uuidString < rhsId.uuidString
}

func archiveChunkIsOrderedBefore(_ lhs: ConversationChunk, _ rhs: ConversationChunk) -> Bool {
    archiveDateRangeIsOrderedBefore(
        lhsStart: lhs.startDate,
        lhsEnd: lhs.endDate,
        lhsId: lhs.id,
        rhsStart: rhs.startDate,
        rhsEnd: rhs.endDate,
        rhsId: rhs.id
    )
}

func archiveMetaSummaryIsOrderedBefore(_ lhs: HistoricalMetaSummary, _ rhs: HistoricalMetaSummary) -> Bool {
    archiveDateRangeIsOrderedBefore(
        lhsStart: lhs.startDate,
        lhsEnd: lhs.endDate,
        lhsId: lhs.id,
        rhsStart: rhs.startDate,
        rhsEnd: rhs.endDate,
        rhsId: rhs.id
    )
}

func archiveSummaryItemIsOrderedBefore(_ lhs: ArchivedSummaryItem, _ rhs: ArchivedSummaryItem) -> Bool {
    archiveDateRangeIsOrderedBefore(
        lhsStart: lhs.startDate,
        lhsEnd: lhs.endDate,
        lhsId: lhs.id,
        rhsStart: rhs.startDate,
        rhsEnd: rhs.endDate,
        rhsId: rhs.id
    )
}

func pendingChunkIsOrderedBefore(_ lhs: PendingChunk, _ rhs: PendingChunk) -> Bool {
    archiveDateRangeIsOrderedBefore(
        lhsStart: lhs.startDate,
        lhsEnd: lhs.endDate,
        lhsId: lhs.id,
        rhsStart: rhs.startDate,
        rhsEnd: rhs.endDate,
        rhsId: rhs.id
    )
}

func pendingMetaSummaryIsOrderedBefore(_ lhs: PendingMetaSummary, _ rhs: PendingMetaSummary) -> Bool {
    archiveDateRangeIsOrderedBefore(
        lhsStart: lhs.startDate,
        lhsEnd: lhs.endDate,
        lhsId: lhs.id,
        rhsStart: rhs.startDate,
        rhsEnd: rhs.endDate,
        rhsId: rhs.id
    )
}

// MARK: - Chunk Index (persisted list of all chunks)

struct ChunkIndex: Codable {
    var chunks: [ConversationChunk]
    var historicalMetaSummaries: [HistoricalMetaSummary]

    enum CodingKeys: String, CodingKey {
        case chunks
        case historicalMetaSummaries
    }

    static func empty() -> ChunkIndex {
        ChunkIndex(chunks: [], historicalMetaSummaries: [])
    }

    init(chunks: [ConversationChunk], historicalMetaSummaries: [HistoricalMetaSummary]) {
        self.chunks = chunks
        self.historicalMetaSummaries = historicalMetaSummaries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chunks = try container.decodeIfPresent([ConversationChunk].self, forKey: .chunks) ?? []
        historicalMetaSummaries = try container.decodeIfPresent([HistoricalMetaSummary].self, forKey: .historicalMetaSummaries) ?? []
    }

    /// Get chunks ordered by date (oldest first)
    var orderedChunks: [ConversationChunk] {
        chunks.sorted(by: archiveChunkIsOrderedBefore)
    }
    
    /// Get the most recent N chunks (newest last)
    func recentChunks(count: Int) -> [ConversationChunk] {
        Array(orderedChunks.suffix(count))
    }
    
    /// Get temporary chunks that might be ready for consolidation
    var temporaryChunks: [ConversationChunk] {
        chunks.filter { $0.type == .temporary }.sorted(by: archiveChunkIsOrderedBefore)
    }
}

// MARK: - Chunk Search Result

struct ChunkSearchResult: Codable {
    let chunkId: UUID
    let excerpts: [String]
    let relevanceScore: Double?
}

// MARK: - Chunk Identifier (for summary-based search)

struct ChunkIdentification: Codable {
    let chunkId: String
    let relevance: String
}

struct ChunkIdentificationResult: Codable {
    let relevantChunks: [ChunkIdentification]
    
    enum CodingKeys: String, CodingKey {
        case relevantChunks = "relevant_chunks"
    }
}

// MARK: - Summary Extraction Result

struct SummaryExtractionResult: Codable {
    let summary: String
    let keyTopics: [String]
    
    enum CodingKeys: String, CodingKey {
        case summary
        case keyTopics = "key_topics"
    }
}

// MARK: - Pending Chunk (for crash recovery)

/// Represents a chunk that has been saved to disk but not yet summarized
/// Used to recover from crashes during summarization
struct PendingChunk: Codable, Identifiable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let tokenCount: Int
    let messageCount: Int
    let rawContentFileName: String
    let createdAt: Date
    var sourceMessageIDs: [UUID]? = nil
}

struct PendingChunkIndex: Codable {
    var pendingChunks: [PendingChunk]
    
    static func empty() -> PendingChunkIndex {
        PendingChunkIndex(pendingChunks: [])
    }
}

// MARK: - Pending Meta Summaries (for crash recovery)

/// Represents a meta-summary that should exist but has not been successfully generated yet.
struct PendingMetaSummary: Codable, Identifiable {
    let id: UUID
    let kind: HistoricalMetaSummary.MetaSummaryKind
    let startDate: Date
    let endDate: Date
    let childChunkIds: [UUID]
    let createdAt: Date
    let updatedAt: Date
}

struct PendingMetaSummaryIndex: Codable {
    var pendingMetaSummaries: [PendingMetaSummary]

    static func empty() -> PendingMetaSummaryIndex {
        PendingMetaSummaryIndex(pendingMetaSummaries: [])
    }
}
