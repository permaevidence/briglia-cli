import Foundation

/// Stable identity of one image a request carried (plan v2 §2.4, Codex
/// round 2 persistence requirement). Never an array index that compaction
/// can shift, never a "current:<n>" identity whose meaning changes when the
/// round becomes historical:
///
/// - a user image is its canonical message id plus its stored file name
///   (the name of a file in the images directory, so equal names are the
///   same bytes);
/// - a tool image is its owner (the canonical assistant message id for a
///   historical round, nil for the run's current rounds), the tool call id
///   and the attachment ordinal inside that result (duplicate file names in
///   one result stay distinct). A PDF is excluded as a whole attachment.
enum ImageSlot: Hashable {
    case user(message: UUID, file: String)
    case tool(owner: UUID?, callId: String, ordinal: Int)
}

/// What one serialized request actually transmitted as image parts
/// (including PDF-rendered pages), in order. Filled by the request builders
/// of both protocols; read by recovery to scope the exclusion to images that
/// were really sent, never to a message that arrived afterwards.
final class TransmittedImageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ordered: [ImageSlot] = []
    private var names: [ImageSlot: String] = [:]

    func record(_ slot: ImageSlot, label: String) {
        lock.lock(); defer { lock.unlock() }
        if names[slot] == nil { ordered.append(slot) }
        names[slot] = label
    }

    var slots: [ImageSlot] { lock.lock(); defer { lock.unlock() }; return ordered }
    func label(_ slot: ImageSlot) -> String { lock.lock(); defer { lock.unlock() }; return names[slot] ?? "image" }
    var isEmpty: Bool { slots.isEmpty }
}

/// The single place that applies rejection marks to every copy of the
/// conversation state (Codex round 1 finding 3). Marks live ON the data:
/// `FileAttachment.providerRejected` (in memory),
/// `FileAttachmentReference.providerRejected` (persisted with the result in
/// the history, the turn checkpoint, subagent sessions, prune snapshots and
/// Mind exports) and `Message.providerRejectedImageFileNames` (persisted
/// with the canonical user message). A mark means only "excluded during
/// image-rejection recovery"; original files and snapshots are untouched.
enum ImageRejectionMarks {

    /// Whether the attachment at `ordinal` of `result` is excluded, from
    /// either representation (in-memory bytes are preferred by Responses).
    static func isRejected(_ result: ToolResultMessage, ordinal: Int) -> Bool {
        if ordinal < result.fileAttachments.count, result.fileAttachments[ordinal].providerRejected { return true }
        if ordinal < result.fileAttachmentReferences.count, result.fileAttachmentReferences[ordinal].providerRejected == true { return true }
        return false
    }

    static func hasRejection(_ result: ToolResultMessage) -> Bool {
        result.fileAttachments.contains { $0.providerRejected }
            || result.fileAttachmentReferences.contains { $0.providerRejected == true }
    }

    /// Mark one tool result's attachment in both representations.
    static func mark(_ result: inout ToolResultMessage, ordinal: Int) -> Bool {
        var changed = false
        if ordinal < result.fileAttachments.count, !result.fileAttachments[ordinal].providerRejected {
            result.fileAttachments[ordinal].providerRejected = true; changed = true
        }
        if ordinal < result.fileAttachmentReferences.count, result.fileAttachmentReferences[ordinal].providerRejected != true {
            result.fileAttachmentReferences[ordinal].providerRejected = true; changed = true
        }
        return changed
    }

    private static func apply(_ slots: Set<ImageSlot>, owner: UUID?, to rounds: inout [ToolInteraction]) -> Int {
        var count = 0
        for r in rounds.indices {
            for i in rounds[r].results.indices {
                let callId = rounds[r].results[i].toolCallId
                for case .tool(let slotOwner, let slotCall, let ordinal) in slots where slotOwner == owner && slotCall == callId {
                    if mark(&rounds[r].results[i], ordinal: ordinal) { count += 1 }
                }
            }
        }
        return count
    }

    /// Apply to a message list (user images by message id; historical tool
    /// images by owner = message id).
    static func apply(_ slots: Set<ImageSlot>, to messages: inout [Message]) -> Int {
        var count = 0
        for m in messages.indices {
            let id = messages[m].id
            for case .user(let message, let file) in slots where message == id {
                if !messages[m].providerRejectedImageFileNames.contains(file) {
                    messages[m].providerRejectedImageFileNames.append(file); count += 1
                }
            }
            if !messages[m].toolInteractions.isEmpty {
                count += apply(slots, owner: id, to: &messages[m].toolInteractions)
            }
        }
        return count
    }

    /// Apply to the run's current rounds (owner nil).
    static func apply(_ slots: Set<ImageSlot>, toCurrent rounds: inout [ToolInteraction]) -> Int {
        apply(slots, owner: nil, to: &rounds)
    }

    /// First scope: transmitted images of the failed request's newest unit —
    /// its last current round when it had one, otherwise the trailing user
    /// message(s) it carried. Bound to what that request contained, so a
    /// message that arrived while it was in flight is never included.
    static func newestUnit(transmitted: [ImageSlot], requestMessages: [Message], requestRounds: [ToolInteraction]) -> Set<ImageSlot> {
        if let last = requestRounds.last {
            let calls = Set(last.results.map(\.toolCallId))
            return Set(transmitted.filter {
                if case .tool(nil, let call, _) = $0 { return calls.contains(call) }
                return false
            })
        }
        var trailing = Set<UUID>()
        for message in requestMessages.reversed() {
            if message.role == .assistant { break }
            trailing.insert(message.id)
        }
        return Set(transmitted.filter {
            if case .user(let message, _) = $0 { return trailing.contains(message) }
            return false
        })
    }
}

/// Bounded recovery driver shared by the main agent and subagents
/// (plan v2 §2.4 steps 1–8): at most two extra sends per request, first the
/// newest unit (skipped when it carried no image), then every transmitted
/// image; marks are committed (ownership checked, every live copy updated,
/// persisted) BEFORE each resend; no tool is re-executed; the caller sends
/// its notice only after a successful retry.
enum ImageRejectionRecovery {
    struct Outcome {
        let response: LLMResponse
        /// Display names of excluded images (empty when nothing was rejected).
        let excluded: [String]
    }

    /// `send` serializes the CURRENT state into a fresh log and sends it;
    /// `scope` returns the newest unit of what was just sent; `commit`
    /// applies the marks and persists them, returning false when a write
    /// failed (then the original failure stands) and throwing on a stop or
    /// a superseded run (nothing written, no resend).
    static func run(
        send: (TransmittedImageLog) async throws -> LLMResponse,
        newestUnit: (_ transmitted: [ImageSlot]) -> Set<ImageSlot>,
        commit: (Set<ImageSlot>) async throws -> Bool
    ) async throws -> Outcome {
        var widened = false
        var excluded: [String] = []
        var extraSends = 0
        while true {
            let log = TransmittedImageLog()
            do {
                let response = try await send(log)
                return Outcome(response: response, excluded: excluded)
            } catch let rejected as ProviderImageRejection.Rejected {
                let transmitted = log.slots
                guard !transmitted.isEmpty, extraSends < 2, !widened else { throw rejected.underlying }
                var scope = newestUnit(transmitted).intersection(transmitted)
                if scope.isEmpty || extraSends == 1 {
                    scope = Set(transmitted)
                    widened = true
                }
                await beforeCommitForTesting?()
                guard try await commit(scope) else { throw rejected.underlying }
                for slot in transmitted where scope.contains(slot) {
                    let name = log.label(slot)
                    if !excluded.contains(name) { excluded.append(name) }
                }
                extraSends += 1
                print("[ImageRejection] provider rejected an image; excluded \(scope.count) image(s) and resending (extra send \(extraSends)/2)")
            }
        }
    }

    /// Selftest seam: runs after a recognised rejection, before the commit
    /// (a /stop can be made to land exactly there).
    nonisolated(unsafe) static var beforeCommitForTesting: (() async -> Void)?

    static func notice(_ excluded: [String]) -> String {
        let names = excluded.map { URL(fileURLWithPath: $0).lastPathComponent }
        return "⚠️ The provider rejected an image (\(names.joined(separator: ", "))); I replaced it with a note and continued."
    }
}
