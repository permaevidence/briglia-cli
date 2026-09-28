import Foundation

/// Acceptance rules for a model-written compaction summary (active-turn
/// compaction and the bounded builder that oversized historical pruning
/// shares). The instruction text asks for at most 6000 words / 12000 tokens and
/// the request allows 16,384 output tokens; the accepted size matches that
/// output allowance instead of the older 36,000-byte bound, which rejected
/// summaries that followed the instruction (multilingual text, code).
///
/// A summary is accepted only when it is non-empty plain text, complete (not
/// cut off by the provider) and at most `maxBytes` UTF-8 bytes. Anything else
/// gets exactly one plain retry of the same request; a second rejection keeps
/// the caller's existing failure behaviour, with the specific reason.
enum CompactionSummaryPolicy {
    static let maxBytes = 65_536
    /// The bound before 0.2.40. Older binaries drop a larger persisted summary
    /// (keeping its snapshot link) instead of failing the conversation load.
    static let legacyMaxBytes = 36_000
    /// The original request plus one plain retry.
    static let attempts = 2

    enum Rejection: Error, Equatable {
        case empty
        case notText
        case truncated(String)
        case oversized(Int)

        var reason: String {
            switch self {
            case .empty: return "the reply was empty"
            case .notText: return "the reply was not plain text"
            case .truncated(let why): return "the reply was cut off by the provider (\(why))"
            case .oversized(let bytes): return "the summary was \(bytes) bytes, over the \(CompactionSummaryPolicy.maxBytes)-byte limit"
            }
        }
    }

    /// Final failure after every attempt was rejected. The wording avoids the
    /// provider-overflow keywords that trigger source halving.
    struct Rejected: Error, LocalizedError {
        let rejection: Rejection
        let attempts: Int
        var errorDescription: String? {
            "Compaction summary rejected after \(attempts) attempt\(attempts == 1 ? "" : "s"): \(rejection.reason)"
        }
    }

    /// A Chat Completions stop reason that means the provider ended the reply
    /// before the model finished ("length", "max_tokens", "content_filter"...).
    /// Missing or "stop"/"end_turn" count as complete; a text reply that says
    /// "tool_calls" carried no calls and is still complete text.
    static func isCutOff(_ finishReason: String?) -> Bool {
        guard let reason = finishReason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !reason.isEmpty else { return false }
        return !["stop", "end_turn", "stop_sequence", "tool_calls", "eos"].contains(reason)
    }

    static func validate(_ response: LLMResponse) -> Result<String, Rejection> {
        guard case .text(let text, _, _, _, _, _, _, let finish) = response else { return .failure(.notText) }
        if isCutOff(finish) { return .failure(.truncated("finish_reason: \(finish!)")) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }
        guard text.utf8.count <= maxBytes else { return .failure(.oversized(text.utf8.count)) }
        return .success(text)
    }

    /// Decode-layer failures that are a bad reply rather than a failed request.
    /// Responses rejects an incomplete round, and a completed round with no
    /// text, while decoding; Chat Completions reports a choice without text
    /// through `ChatReplyWithoutText`.
    static func rejection(for error: Error) -> Rejection? {
        if case ResponsesFailure.incomplete(let detail) = error {
            let reason = detail.components(separatedBy: " — ").first ?? detail
            return .truncated("incomplete: " + String(reason.prefix(80)))
        }
        if case ResponsesFailure.malformed(let detail) = error, detail == ResponsesRoundDecoder.noVisibleAnswer {
            return .empty
        }
        if let empty = error as? ChatReplyWithoutText {
            if isCutOff(empty.finishReason) { return .truncated("finish_reason: \(empty.finishReason!)") }
            return .empty
        }
        return nil
    }

    /// Spend a rejected decode still reported (Chat Completions only; the
    /// Responses transport carries no provider spend).
    static func spend(for error: Error) -> Double? {
        (error as? ChatReplyWithoutText)?.spendUSD
    }
}
