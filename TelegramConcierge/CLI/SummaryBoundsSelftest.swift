import ArgumentParser
import Foundation

/// Compaction-summary bounds (0.2.40, minimal scope): the 65,536-byte limit on
/// both enforcement sites, cut-off replies rejected where the response is
/// decoded (Chat Completions and Responses), the specific failure reasons, the
/// summary allowance used for prefix selection, and older-binary tolerance of
/// a persisted summary above its own bound. Pure, hermetic: no network, no
/// settings, no storage roots. The retry and stop/fallback behaviour of the
/// real loop is covered by the active-compaction owner test.
struct SummaryBoundsSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__summary-bounds-selftest",
        abstract: "Internal: verify compaction-summary size, truncation and failure-reason rules.",
        shouldDisplay: false
    )

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else { throw ValidationError("Needs a development build") }
        var total = 0, failures = 0
        func check(_ name: String, _ value: Bool, _ detail: String = "") {
            total += 1
            if !value { failures += 1 }
            print("\(value ? "✔" : "✖") \(name)\(value || detail.isEmpty ? "" : " — \(String(detail.prefix(400)))")")
        }
        try Self.limits(check)
        try Self.decoding(check)
        try Self.budget(check)
        try Self.legacyTolerance(check)
        print("Summary bounds selftest: \(total - failures)/\(total) passed")
        if failures > 0 { throw ExitCode.failure }
    }

    typealias Check = (String, Bool, String) -> Void

    static func reference() throws -> PruneArchiveReference {
        try PruneArchiveReference(id: UUID(), basename: "2026-09-28_120000Z_" + String(repeating: "a", count: 32) + ".txt")
    }

    static func text(_ body: String, finish: String? = nil) -> LLMResponse {
        .text(body, reasoning: nil, reasoningDetails: nil, promptTokens: 10, completionTokens: 10, spendUSD: nil, finishReason: finish)
    }

    /// SB1: the byte limit, identical on the validator and the persisted type.
    static func limits(_ check: Check) throws {
        let atLimit = String(repeating: "x", count: CompactionSummaryPolicy.maxBytes)
        let overLimit = atLimit + "x"
        let accented = String(repeating: "é", count: CompactionSummaryPolicy.maxBytes / 2) // 2 bytes each
        check("SB1a 65,536-byte summary accepted by the reply validator",
              (try? CompactionSummaryPolicy.validate(text(atLimit)).get()) == atLimit, "")
        check("SB1b 65,537-byte summary rejected as oversized with its size",
              CompactionSummaryPolicy.validate(text(overLimit)) == .failure(.oversized(65_537)), "")
        check("SB1c limit counts UTF-8 bytes (32,768 × 'é' accepted, one more rejected)",
              (try? CompactionSummaryPolicy.validate(text(accented)).get()) != nil
              && CompactionSummaryPolicy.validate(text(accented + "é")) == .failure(.oversized(65_538)), "")
        let ref = try reference()
        check("SB1d persisted active-turn summary accepts 65,536 bytes",
              (try? ActiveTurnCompaction(summaryText: atLimit, reference: ref, through: 1)) != nil, "")
        check("SB1e persisted active-turn summary rejects 65,537 bytes",
              (try? ActiveTurnCompaction(summaryText: overLimit, reference: ref, through: 1)) == nil, "")
        check("SB1f 36,001..65,536 bytes (rejected before) now accepted end to end",
              (try? ActiveTurnCompaction(summaryText: String(repeating: "y", count: 36_001), reference: ref, through: 1)) != nil
              && (try? CompactionSummaryPolicy.validate(text(String(repeating: "y", count: 36_001))).get()) != nil, "")
        check("SB1g empty and whitespace-only replies rejected as empty",
              CompactionSummaryPolicy.validate(text("")) == .failure(.empty)
              && CompactionSummaryPolicy.validate(text(" \n\t ")) == .failure(.empty), "")
        let calls = LLMResponse.toolCalls(assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: []),
                                          calls: [], promptTokens: nil, completionTokens: nil, spendUSD: nil)
        check("SB1h tool-call reply rejected as not plain text",
              CompactionSummaryPolicy.validate(calls) == .failure(.notText), "")
        let rejected = CompactionSummaryPolicy.Rejected(rejection: .oversized(70_123), attempts: 2).localizedDescription
        check("SB1i final error names the attempts and the size",
              rejected == "Compaction summary rejected after 2 attempts: the summary was 70123 bytes, over the 65536-byte limit", rejected)
        let reasons = [CompactionSummaryPolicy.Rejection.empty, .notText, .truncated("finish_reason: length"), .oversized(70_000)]
            .map { CompactionSummaryPolicy.Rejected(rejection: $0, attempts: 2).localizedDescription.lowercased() }
        check("SB1j reasons never contain the provider-overflow words that halve the source",
              reasons.allSatisfy { !$0.contains("context") && !$0.contains("too large") && !$0.contains("413") }, reasons.joined(separator: " | "))
    }

    /// SB2: cut-off replies are rejected where the response is decoded.
    static func decoding(_ check: Check) throws {
        check("SB2a short reply cut off at the output limit is rejected (finish_reason length)",
              CompactionSummaryPolicy.validate(text("A complete-looking summary", finish: "length")) == .failure(.truncated("finish_reason: length")), "")
        check("SB2b normal stop reasons are complete",
              ["stop", "STOP", "end_turn", nil].allSatisfy { (try? CompactionSummaryPolicy.validate(text("ok", finish: $0)).get()) == "ok" }, "")
        check("SB2c other provider stops (max_tokens, content_filter) are cut off",
              CompactionSummaryPolicy.isCutOff("max_tokens") && CompactionSummaryPolicy.isCutOff("content_filter"), "")

        let context = ProviderExecutionContext(provider: .openAICompatible, model: "fixture-model",
            endpoint: "http://127.0.0.1:9/v1/chat/completions", authorization: "Bearer synthetic", affinityKey: "synthetic",
            lane: .main, provenance: "fixture-model#fixture", providerPreferences: nil, reasoning: nil, reasoningEffort: nil,
            thinkingType: nil, useReasoningContent: false, textOnly: false, anthropicCacheControl: false, renderPDFAsImages: false)
        let adapter = ChatCompletionsAdapter(context: context)
        let cut = try adapter.decodeResponse(Data(#"{"choices":[{"message":{"role":"assistant","content":"partial summ"},"finish_reason":"length"}],"usage":{"prompt_tokens":5,"completion_tokens":16384,"cost":0.25}}"#.utf8))
        if case .text(let body, _, _, _, _, let spend, _, let finish) = cut {
            check("SB2d Chat Completions decode keeps text, spend and finish_reason", body == "partial summ" && spend == 0.25 && finish == "length", "")
        } else { check("SB2d Chat Completions decode keeps text, spend and finish_reason", false, "not text") }
        check("SB2e decoded cut-off Chat Completions reply is rejected",
              CompactionSummaryPolicy.validate(cut) == .failure(.truncated("finish_reason: length")), "")
        do {
            _ = try adapter.decodeResponse(Data(#"{"choices":[{"message":{"role":"assistant","content":null},"finish_reason":"length"}],"usage":{"cost":0.4}}"#.utf8))
            check("SB2f reply without text is an error", false, "decoded")
        } catch {
            check("SB2f reply without text keeps the old user-visible message",
                  error.localizedDescription == OpenRouterError.noContent.localizedDescription, error.localizedDescription)
            check("SB2g reply without text (length) is a cut-off rejection with its spend",
                  CompactionSummaryPolicy.rejection(for: error) == .truncated("finish_reason: length")
                  && CompactionSummaryPolicy.spend(for: error) == 0.4, "\(error)")
        }
        do {
            _ = try adapter.decodeResponse(Data(#"{"choices":[{"message":{"role":"assistant","content":null},"finish_reason":"stop"}]}"#.utf8))
            check("SB2h reply without text (stop) is an error", false, "decoded")
        } catch {
            check("SB2h reply without text (stop) is an empty rejection", CompactionSummaryPolicy.rejection(for: error) == .empty, "\(error)")
        }
        check("SB2i unrelated failures are not rejections (no retry, unchanged path)",
              CompactionSummaryPolicy.rejection(for: OpenRouterError.httpError(500)) == nil
              && CompactionSummaryPolicy.rejection(for: ResponsesFailure.failed("server_error")) == nil, "")

        let scope = ResponsesScope(endpoint: "http://127.0.0.1:9/v1/responses", profile: "fixture", model: "fixture-model",
                                   credentialFingerprint: "fixture")
        let receipt = PreparedRequestReceipt(requestID: UUID(), historyFingerprint: "fixture", deliveryNonces: [])
        let incomplete: [String: Any] = ["id": "resp_fixture", "status": "incomplete",
            "incomplete_details": ["reason": "max_output_tokens"],
            "output": [["type": "message", "role": "assistant", "status": "incomplete", "id": "msg_fixture",
                        "content": [["type": "output_text", "text": "partial summ", "annotations": []]]]],
            "usage": ["input_tokens": 5, "output_tokens": 16384]]
        do {
            _ = try ResponsesRoundDecoder.decode(JSONSerialization.data(withJSONObject: incomplete), scope: scope,
                                                 receipt: receipt, allowedTools: [])
            check("SB2j Responses incomplete round never decodes as text", false, "decoded")
        } catch {
            check("SB2j Responses incomplete (max_output_tokens) is a cut-off rejection",
                  CompactionSummaryPolicy.rejection(for: error) == .truncated("incomplete: max_output_tokens"), "\(error)")
        }
        var empty = incomplete
        empty["status"] = "completed"; empty["incomplete_details"] = nil
        empty["output"] = [["type": "message", "role": "assistant", "status": "completed", "id": "msg_fixture",
                            "content": [["type": "output_text", "text": "", "annotations": []]]]]
        do {
            _ = try ResponsesRoundDecoder.decode(JSONSerialization.data(withJSONObject: empty), scope: scope,
                                                 receipt: receipt, allowedTools: [])
            check("SB2k Responses round without text never decodes", false, "decoded")
        } catch {
            check("SB2k Responses round without text is an empty rejection",
                  CompactionSummaryPolicy.rejection(for: error) == .empty, "\(error)")
        }
        check("SB2l other malformed Responses payloads are not rejections",
              CompactionSummaryPolicy.rejection(for: ResponsesFailure.malformed("assistant message")) == nil, "")
    }

    /// SB3: prefix selection reserves room for the largest accepted summary.
    static func budget(_ check: Check) throws {
        guard let largest = try? ActiveTurnCompaction(summaryText: String(repeating: "z", count: CompactionSummaryPolicy.maxBytes),
                                                      reference: reference(), through: 1) else {
            check("SB3a summary allowance covers the largest accepted summary", false, "largest summary not constructible")
            return
        }
        let cost = ActiveTurnBudget.text(largest.promptText)
        check("SB3a summary allowance covers the largest accepted summary",
              ActiveTurnBudget.summaryAllowance >= cost && cost > 16_000, "allowance \(ActiveTurnBudget.summaryAllowance), largest \(cost)")
        // Rounds cheaper in total than the largest summary: selection must keep
        // taking rounds until it removes at least the allowance.
        func round(_ id: String, cost: Int) -> ToolInteraction {
            ToolInteraction(assistantMessage: AssistantToolCallMessage(content: "done", toolCalls: [
                ToolCall(id: id, type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))
            ]), results: [ToolResultMessage(toolCallId: id, content: "evidence")], measuredTokenCost: cost)
        }
        let rounds = (0..<10).map { round("r\($0)", cost: 3_000) }
        let budget = ActiveTurnBudget(maximum: 250_000)
        let count = budget.prefixCount(rounds: rounds, fixed: 1_000, target: 1, pendingNonce: nil)
        let removed = rounds.prefix(count).reduce(0) { $0 + ActiveTurnBudget.round($1) }
        check("SB3b selection removes at least the largest summary before stopping",
              removed >= cost, "removed \(removed) in \(count) rounds, largest summary \(cost)")
        let capacity = ActiveTurnBudget.summarySourceCapacity
        check("SB3c source fragment unchanged (112,000 bytes) while the prior summary is within 36,000 bytes",
              capacity(0) == 112_000 && capacity(CompactionSummaryPolicy.legacyMaxBytes) == 112_000, "")
        check("SB3d prior summary plus source keep the old 148,000-byte bound at the new limit",
              capacity(CompactionSummaryPolicy.maxBytes) + CompactionSummaryPolicy.maxBytes == 148_000
              && capacity(50_000) + 50_000 == 148_000, "\(capacity(CompactionSummaryPolicy.maxBytes))")
    }

    /// SB4: a summary above a binary's own bound never costs the conversation.
    /// Every version since 0.2.14 decodes `activeTurnCompaction` through this
    /// same tolerant path (bound 36,000 before 0.2.40): the summary is dropped,
    /// the message and its snapshot link are kept.
    static func legacyTolerance(_ check: Check) throws {
        let ref = try reference()
        var message = Message(role: .assistant, content: "Turn outcome text")
        message.activeTurnCompaction = try ActiveTurnCompaction(summaryText: "short", reference: ref, through: 3)
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as! [String: Any]
        var summary = encoded["activeTurnCompaction"] as! [String: Any]
        summary["summaryText"] = String(repeating: "q", count: CompactionSummaryPolicy.maxBytes + 1)
        encoded["activeTurnCompaction"] = summary
        let decoded = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: encoded))
        check("SB4a over-bound persisted summary keeps the message and drops only the summary",
              decoded.id == message.id && decoded.content == message.content && decoded.activeTurnCompaction == nil, "")
        check("SB4b over-bound persisted summary keeps its snapshot link",
              decoded.pruneArchiveReferences == [ref], "\(decoded.pruneArchiveReferences)")
        summary["summaryText"] = String(repeating: "q", count: CompactionSummaryPolicy.maxBytes)
        encoded["activeTurnCompaction"] = summary
        let kept = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: encoded))
        check("SB4c a 65,536-byte persisted summary round-trips",
              kept.activeTurnCompaction?.summaryText.utf8.count == CompactionSummaryPolicy.maxBytes, "")
    }
}
