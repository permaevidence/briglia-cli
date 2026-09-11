import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Historical assistant context, separate from historical-prune system notes.
struct ActiveTurnCompaction: Codable, Equatable {
    let version: Int
    let summaryText: String
    let latestSnapshotReference: PruneArchiveReference
    enum CodingKeys: String, CodingKey { case version, summaryText, latestSnapshotReference, throughRoundSequence }
    let throughRoundSequence: Int
    init(summaryText: String, reference: PruneArchiveReference, through: Int) throws {
        guard !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summaryText.utf8.count <= 36_000, through > 0 else {
            throw PruneArchiveStore.Failure("Invalid active-turn summary")
        }
        version = 1; self.summaryText = summaryText
        latestSnapshotReference = reference; throughRoundSequence = through
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else {
            throw PruneArchiveStore.Failure("Unsupported active-turn summary version")
        }
        try self.init(summaryText: c.decode(String.self, forKey: .summaryText),
                      reference: c.decode(PruneArchiveReference.self, forKey: .latestSnapshotReference),
                      through: c.decode(Int.self, forKey: .throughRoundSequence))
    }
    var promptText: String {
        "[Summary of earlier completed work in this turn — historical assistant context]\n"
            + MarkerNeutralizer.escape(summaryText) + "\n" + MarkerNeutralizer.escape(latestSnapshotReference.promptText)
    }
}

/// The only replay owner after compaction; no independent raw-round mirror.
struct TurnCheckpoint: Codable {
    enum CodingKeys: String, CodingKey {
        case version, runID, outcomeMessageID, taskMessageID, generation, activeTurnCompaction
        case carriedDeliveredUserMessageIDs, deliveredUserMessageIDs, retainedInteractions, nextRoundSequence
        case accessedProjects, editedFilePaths, generatedFilePaths, subagentSessionEvents
        case overflowReference, overflowLog, pendingRecovery, maintenanceSpendUSD
    }
    // Process-local settlement receipts keep their existing nonpersistent
    // contract. They survive prefix removal until the final checked save.
    var completionReceipts: [BashCompletionReceipt] = []
    var version = 1
    let runID: UUID
    let outcomeMessageID: UUID
    let taskMessageID: UUID
    var generation = 0
    var activeTurnCompaction: ActiveTurnCompaction?
    var carriedDeliveredUserMessageIDs: [UUID] = []
    /// Typed provenance, never reconstructed from strings in tool output.
    var deliveredUserMessageIDs: [UUID] = []
    var retainedInteractions: [ToolInteraction] = []
    var nextRoundSequence = 1
    var accessedProjects: [String] = []
    var editedFilePaths: [String] = []
    var generatedFilePaths: [String] = []
    var subagentSessionEvents: [SubagentSessionEvent] = []
    var overflowReference: PruneArchiveReference?
    var overflowLog: String?
    var pendingRecovery = false
    var maintenanceSpendUSD: Double = 0
    init(runID: UUID, taskMessageID: UUID) {
        self.runID = runID; self.taskMessageID = taskMessageID; outcomeMessageID = UUID()
    }
    var isEnvelope: Bool { generation > 0 || pendingRecovery || overflowReference != nil }
    func validate(history: [Message]) throws {
        guard version == 1, generation >= 0, nextRoundSequence > 0,
              maintenanceSpendUSD.isFinite, maintenanceSpendUSD >= 0,
              Set(carriedDeliveredUserMessageIDs).count == carriedDeliveredUserMessageIDs.count,
              Set(carriedDeliveredUserMessageIDs).isSubset(of: Set(deliveredUserMessageIDs)) else {
            throw PruneArchiveStore.Failure("Invalid or unsupported turn checkpoint; recovery file preserved")
        }
        for id in carriedDeliveredUserMessageIDs {
            guard let message = history.first(where: { $0.id == id }),
                  message.role == .user, message.kind == .userText else {
                throw PruneArchiveStore.Failure("Checkpoint refers to missing/nonhuman canonical message; recovery file preserved")
            }
        }
        for round in retainedInteractions {
            let ids = round.assistantMessage.toolCalls.map(\.id)
            guard Set(ids).count == ids.count, round.results.count == ids.count,
                  Set(round.results.map(\.toolCallId)) == Set(ids) else {
                throw PruneArchiveStore.Failure("Checkpoint has incomplete tool batch")
            }
        }
    }
    func projectedHistory(_ history: [Message], canonical: [Message]) throws -> [Message] {
        try validate(history: canonical)
        guard let activeTurnCompaction else { return history }
        var result = history
        var note = Message(id: outcomeMessageID, role: .assistant, content: "")
        note.activeTurnCompaction = activeTurnCompaction
        result.append(note)
        let existing = Set(history.map(\.id))
        for id in carriedDeliveredUserMessageIDs where !existing.contains(id) {
            guard var human = canonical.first(where: { $0.id == id }) else {
                throw PruneArchiveStore.Failure("Missing carried human message")
            }
            human.mediaPruned = true
            result.append(human)
        }
        return result
    }
    func outcome(text: String) -> Message {
        var result = Message(id: pendingRecovery ? UUID() : outcomeMessageID, role: .assistant, content: text,
                             editedFilePaths: editedFilePaths, generatedFilePaths: generatedFilePaths,
                             accessedProjectIds: accessedProjects,
                             subagentSessionEvents: subagentSessionEvents,
                             toolInteractions: pendingRecovery ? [] : retainedInteractions,
                             compactToolLog: overflowLog)
        result.activeTurnCompaction = activeTurnCompaction
        if let overflowReference { result.pruneArchiveReferences = [overflowReference] }
        return result
    }
}

/// Conservative local policy, not a catalog of provider context windows.
struct ActiveTurnBudget {
    let maximum: Int
    var reserve: Int { min(16_384, max(1024, maximum / 10)) }
    var inputCeiling: Int { max(1, (maximum - reserve) * 9 / 10) }
    static func text(_ value: String) -> Int { max(1, (value.utf8.count + 2) / 3) }
    static func readable(_ value: JSONValue?) -> Int {
        guard let value else { return 0 }
        switch value {
        case .string(let s): return text(s)
        case .array(let a): return a.reduce(0) { $0 + readable($1) }
        case .object(let o): return ["text", "summary", "content", "reasoning"].reduce(0) { $0 + readable(o[$1]) }
        default: return 0
        }
    }
    static func round(_ round: ToolInteraction) -> Int {
        let assistant = round.assistantMessage
        var n = text(assistant.content ?? "") + readable(assistant.reasoning) + readable(assistant.reasoningDetails) + 100
        n += assistant.toolCalls.reduce(0) { $0 + text($1.function.name) + text($1.function.arguments) + 32 }
        for result in round.results {
            n += text((try? ProviderToolResultRenderer.wireText(for: result)) ?? result.content) + 32
            if !result.fileAttachmentReferences.isEmpty {
                n += result.fileAttachmentReferences.reduce(0) { total, ref in
                    total + (ref.mimeType == "application/pdf" ? min(20, max(1, ref.pdfPageCount ?? 20)) * 8192 : 8192)
                }
            } else {
                n += result.fileAttachments.reduce(0) { $0 + ($1.mimeType == "application/pdf" ? 20 * 8192 : 8192) }
            }
        }
        // Opaque reasoning has an explicit allowance, never ciphertext/4.
        if assistant.responsesReplay != nil { n += 8192 }
        return max(n, round.measuredTokenCost ?? 0)
    }
    static func message(_ message: Message) -> Int {
        var n = text(message.content) + 64 + message.toolInteractions.reduce(0) { $0 + round($1) }
        n += message.mediaFileCount * (message.mediaPruned ? 256 : 8192)
        n += readable(message.finalReasoning) + readable(message.finalReasoningDetails)
        if message.responsesReplay != nil { n += 8192 }
        if let summary = message.activeTurnCompaction { n += text(summary.promptText) }
        if let summary = message.prunedContextSummary { n += text(summary) }
        if let log = message.compactToolLog { n += text(log) }
        n += message.pruneArchiveReferences.reduce(0) { $0 + text($1.promptText) }
        return n
    }
    /// Allowance for the summary that replaces a compacted prefix (bounded at
    /// 36,000 bytes by the maintenance policy); `fixed` includes it.
    static let summaryAllowance = 16_000
    func prefixCount(rounds: [ToolInteraction], fixed: Int, target: Int, pendingNonce: String?) -> Int {
        guard !rounds.isEmpty else { return 0 }
        let costs = rounds.map(Self.round)
        let desired = min(inputCeiling, max(target, fixed + min(20_000, inputCeiling / 3)))
        var total = fixed + costs.reduce(0, +)
        var count = 0, removed = 0
        for index in rounds.indices {
            if index == rounds.count - 1 && costs[index] + fixed < inputCeiling { break }
            if let nonce = pendingNonce, rounds[index].results.contains(where: {
                $0.harnessAnnotations.contains { $0.deliveryNonce == nonce }
            }) { break }
            count += 1; total -= costs[index]; removed += costs[index]
            // Reaching the target with a prefix cheaper than its own summary
            // would grow the context; keep taking completed rounds.
            if total <= desired && removed >= Self.summaryAllowance { break }
        }
        return count
    }
}

extension OpenRouterService {
    /// Uses the actual prepared instructions and schemas. Media and opaque
    /// reasoning use conservative allowances; no network token-count request.
    func activeTurnRequestEstimate(messages: [Message], rounds: [ToolInteraction],
        images: URL, documents: URL, tools: [ToolDefinition], calendar: String?, email: String?,
        summaries: [ArchivedSummaryItem], totalChunks: Int, date: Date,
        deferred: [(name: String, description: String, toolCount: Int)]) throws -> (tokens: Int, fixedTextTokens: Int, scope: String) {
        let prepared = prepareConversation(messages: messages, imagesDirectory: images,
            documentsDirectory: documents, tools: tools, toolResultMessages: rounds,
            calendarContext: calendar, emailContext: email, chunkSummaries: summaries,
            totalChunkCount: totalChunks, turnStartDate: date, finalResponseInstruction: nil,
            tailSystemMessage: nil, tailUserMessage: nil, deferredMCPSummaries: deferred)
        let schemas = try JSONEncoder().encode(tools)
        let fixed = ActiveTurnBudget.text(prepared.systemPrompt) + (schemas.count + 2) / 3 + 2048
        let scope = ResponsesReplayEnvelope.hash(Data(((activeModelIdentifier() ?? "") + prepared.systemPrompt).utf8) + schemas)
        // Only irreducible input may refuse a first request locally. Media,
        // replay and tool history remain conservative selection allowances;
        // without a provider measurement they cannot establish an overflow.
        let fixedText = fixed + messages.reduce(0) { $0 + ActiveTurnBudget.text($1.content) + 64 }
        return (fixed + messages.reduce(0) { $0 + ActiveTurnBudget.message($1) }
                + rounds.reduce(0) { $0 + ActiveTurnBudget.round($1) }, fixedText, scope)
    }
}

/// Checked local reads shared by recovery and binary-replacement guarding.
/// Unknown data is preserved, never converted to an empty checkpoint.
enum TurnCheckpointStore {
    static let maxBytes = 128 * 1024 * 1024
    static func read(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw PruneArchiveStore.Failure("Cannot open turn checkpoint")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size <= maxBytes else { throw PruneArchiveStore.Failure("Invalid turn checkpoint file type, owner, or size") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while let piece = try handle.read(upToCount: min(64 * 1024, maxBytes + 1 - data.count)), !piece.isEmpty {
            data.append(piece)
            guard data.count <= maxBytes else { throw PruneArchiveStore.Failure("Turn checkpoint exceeds recovery read bound") }
        }
        return data
    }
    static func refuseReplacementWithUnfinishedEnvelope() throws {
        let url = StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json")
        guard let data = try read(url) else { return }
        guard (try? JSONDecoder().decode([ToolInteraction].self, from: data)) != nil else {
            throw PruneArchiveStore.Failure("An unfinished versioned turn checkpoint is present. Start the current Briglia version to recover it before replacing or rolling back the binary. Recovery data was preserved.")
        }
    }
}
