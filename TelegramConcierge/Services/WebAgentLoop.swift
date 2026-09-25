import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Native tool-calling agent loop for the web pipeline
//
// Replaces the old JSON-in-content protocol ({thinking, tool_calls,
// ready_for_answer} parsed out of plain text) that produced ~10% hard
// failures from model-malformed JSON. The agent now drives real function
// calls — the gateway formats the arguments — and the final answer is simply
// the first assistant message without tool calls. The design follows the
// verified per-gateway capability matrix (native tool calls everywhere).
//
// Transports:
//   - openai backend  → Responses API (/v1/responses): Luna rejects function
//     tools + reasoning_effort on chat completions (probed 2026-08-16), and
//     Responses additionally returns encrypted reasoning items we replay for
//     true chain-of-thought continuity across rounds.
//   - openrouter / opencode backends → chat completions with `tools`
//     (mimo-v2.5 verified 2026-08; mimo-v2.6-flash, the pin since v0.2.32,
//     verified 2026-09-21: tool calls + reasoning_content round-trip).

// MARK: - Chat-completions tool types

struct ORToolDef: Encodable {
    struct FunctionDef: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
        var strict: Bool? = nil
    }
    var type: String = "function"
    let function: FunctionDef
}

struct ORToolCall: Codable {
    struct FunctionPayload: Codable {
        let name: String
        let arguments: String
    }
    let id: String
    var type: String? = "function"
    let function: FunctionPayload
}

struct ORResponseFormat: Encodable {
    struct Schema: Encodable {
        let name: String
        let strict: Bool
        let schema: JSONValue
    }
    var type: String = "json_schema"
    let json_schema: Schema
}

// MARK: - Responses API types (OpenAI backend agent rounds)

struct OAIResponsesReq: Encodable {
    struct Reasoning: Encodable { let effort: String }
    let model: String
    let instructions: String
    /// Message items plus verbatim replay of prior output items (reasoning,
    /// message, function_call) and our function_call_output items.
    let input: [JSONValue]
    let tools: [JSONValue]
    var tool_choice: String? = nil
    var reasoning: Reasoning? = nil
    let max_output_tokens: Int
    /// store:false + include reasoning.encrypted_content = stateless calls
    /// that still carry Luna's actual chain of thought between rounds.
    var store: Bool = false
    var include: [String] = ["reasoning.encrypted_content"]
}

struct OAIResponsesResp: Decodable {
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
    }
    struct APIError: Decodable {
        let message: String?
        let code: String?
    }
    let status: String?
    let output: [JSONValue]?
    let usage: Usage?
    let error: APIError?
}

// MARK: - JSONValue accessors

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Tool schemas
//
// All schema constants are `static let` so each process serializes them
// byte-stably (a given Dictionary instance iterates in a fixed order while
// unmutated) — OpenAI caches schema compilation on content, so a stable
// serialization keeps every call after the first on the warm path.

enum WebAgentTools {
    static let searchName = "search"
    static let fetchName = "fetch_and_extract"
    static let maxQueriesPerCall = 4
    static let maxFetchRequestsPerCall = 3

    static let searchDescription =
        "Execute web searches. Provide up to \(maxQueriesPerCall) queries per call; they run concurrently."
    static let searchParameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "queries": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Search query strings, at most \(maxQueriesPerCall). Vary phrasing and angle rather than repeating one query. Extra queries beyond the cap are dropped.")
            ])
        ]),
        "required": .array([.string("queries")]),
        "additionalProperties": .bool(false)
    ])

    static let fetchDescription =
        "Fetch web pages and extract the content relevant to a focus. Provide up to \(maxFetchRequestsPerCall) requests per call; they run concurrently."
    static let fetchParameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "requests": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object([
                            "type": .string("string"),
                            "description": .string("The page URL to fetch.")
                        ]),
                        "focus": .object([
                            "type": .string("string"),
                            "description": .string("What to look for on this page. The extractor reads the full page and returns only excerpts relevant to this instruction — make it specific ('exact pricing tiers and limits', not 'info about pricing').")
                        ])
                    ]),
                    "required": .array([.string("url"), .string("focus")]),
                    "additionalProperties": .bool(false)
                ]),
                "description": .string("Up to \(maxFetchRequestsPerCall) url+focus requests. Extra requests beyond the cap are dropped.")
            ])
        ]),
        "required": .array([.string("requests")]),
        "additionalProperties": .bool(false)
    ])

    /// Chat-completions `tools` array (openrouter / opencode backends).
    static let chatTools: [ORToolDef] = [
        ORToolDef(function: .init(name: searchName, description: searchDescription, parameters: searchParameters)),
        ORToolDef(function: .init(name: fetchName, description: fetchDescription, parameters: fetchParameters)),
    ]

    /// The same two tools as `ToolDefinition`s, for the legacy loop's agent
    /// rounds on the MAIN transport (owner decision 2026-09-25): the main
    /// serializers render them per protocol like any other tool.
    static let mainTransportTools: [ToolDefinition] = [
        ToolDefinition(function: FunctionDefinition(name: searchName, description: searchDescription,
            parameters: FunctionParameters(properties: [
                "queries": ParameterProperty(type: "array",
                    description: "Search query strings, at most \(maxQueriesPerCall). Vary phrasing and angle rather than repeating one query. Extra queries beyond the cap are dropped.",
                    items: ArrayItemsSchema(type: "string"))
            ], required: ["queries"]))),
        ToolDefinition(function: FunctionDefinition(name: fetchName, description: fetchDescription,
            parameters: FunctionParameters(properties: [
                "requests": ParameterProperty(type: "array",
                    description: "Up to \(maxFetchRequestsPerCall) url+focus requests. Extra requests beyond the cap are dropped.",
                    items: ArrayItemsSchema(type: "object", properties: [
                        "url": ParameterProperty(type: "string", description: "The page URL to fetch."),
                        "focus": ParameterProperty(type: "string", description: "What to look for on this page. The extractor reads the full page and returns only excerpts relevant to this instruction — make it specific ('exact pricing tiers and limits', not 'info about pricing').")
                    ], required: ["url", "focus"]))
            ], required: ["requests"]))),
    ]

    /// Responses API `tools` array (openai backend) — flat shape, strict on.
    static let responsesTools: [JSONValue] = [
        .object([
            "type": .string("function"),
            "name": .string(searchName),
            "description": .string(searchDescription),
            "parameters": searchParameters,
            "strict": .bool(true)
        ]),
        .object([
            "type": .string("function"),
            "name": .string(fetchName),
            "description": .string(fetchDescription),
            "parameters": fetchParameters,
            "strict": .bool(true)
        ]),
    ]
}

/// Strict json_schema response formats for the mechanical extraction stages.
/// Sent on openai (verified enforced) and openrouter (forwarded to providers
/// that support it); NOT on opencode (mimo ignores it — probed 2026-08-16).
/// The prompt-JSON + repair path stays as the universal fallback.
enum WebExtractionSchemas {
    static let excerpts = ORResponseFormat(json_schema: .init(
        name: "excerpts",
        strict: true,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "excerpts": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ])
            ]),
            "required": .array([.string("excerpts")]),
            "additionalProperties": .bool(false)
        ])))

    static let assets = ORResponseFormat(json_schema: .init(
        name: "page_assets",
        strict: true,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "links": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object(["type": .string("string")]),
                            "url": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("text"), .string("url")]),
                        "additionalProperties": .bool(false)
                    ])
                ]),
                "images": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "caption": .object(["type": .string("string")]),
                            "url": .object(["type": .array([.string("string"), .string("null")])])
                        ]),
                        "required": .array([.string("caption"), .string("url")]),
                        "additionalProperties": .bool(false)
                    ])
                ])
            ]),
            "required": .array([.string("links"), .string("images")]),
            "additionalProperties": .bool(false)
        ])))
}

// MARK: - Round result

/// The legacy loop's transcript on the MAIN transport (owner decision
/// 2026-09-25): one user message with the question, the completed tool
/// rounds as `ToolInteraction`s (so the main serializers apply their own
/// reasoning-replay, chronology and marker-neutralization rules), and the
/// loop's interjected notes ("no search yet", "budget exhausted") carried
/// as the tail of the next request only. The provider context is the main
/// snapshot taken once at the start of the loop run.
final class WebAgentMainTranscript {
    let context: ProviderExecutionContext
    let systemPrompt: String
    let messages: [Message]
    private(set) var interactions: [ToolInteraction] = []
    private var notes: [String] = []
    private var pendingAssistant: AssistantToolCallMessage?
    private var pendingResults: [String: String] = [:]

    init(context: ProviderExecutionContext, systemPrompt: String, user: String, at date: Date) {
        self.context = context
        self.systemPrompt = systemPrompt
        self.messages = [Message(role: .user, content: user, timestamp: date)]
    }

    func appendNote(_ text: String) { notes.append(text) }
    var pendingTail: String? { notes.isEmpty ? nil : notes.joined(separator: "\n\n") }
    func clearNotes() { notes = [] }

    func recordAssistant(_ message: AssistantToolCallMessage) {
        pendingAssistant = message
        pendingResults = [:]
    }

    func appendToolResult(callID: String, content: String) { pendingResults[callID] = content }

    /// Close the round: every call gets its result (a call with none gets an
    /// explicit error), in call order.
    func commitRound() {
        guard let assistant = pendingAssistant else { return }
        let results = assistant.toolCalls.map {
            ToolResultMessage(toolCallId: $0.id, content: pendingResults[$0.id] ?? "{\"error\": \"no result\"}")
        }
        interactions.append(ToolInteraction(assistantMessage: assistant, results: results))
        pendingAssistant = nil
        pendingResults = [:]
    }
}

struct WebAgentRound {
    let visibleText: String
    let toolCalls: [WebAgentToolCall]
}

struct WebAgentToolCall {
    let id: String
    let name: String
    let argumentsJSON: String
}

// MARK: - Tool argument / result payloads

struct SearchToolArgs: Decodable { let queries: [String] }
struct FetchToolArgs: Decodable { let requests: [ScrapeRequest] }

/// Rendered result of one `search` call, JSON-encoded into the tool message.
struct SearchToolPayload: Encodable {
    let results: [WebResult]
    var answer_box: WebAnswerBox? = nil
    var knowledge_graph: WebKG? = nil
    var people_also_ask: [WebPAA]? = nil
    var top_stories: [WebTop]? = nil
    var failed_queries: [String]? = nil
    var dropped_queries: Int? = nil
    var omitted_repeats: Int? = nil
}

/// Rendered result of one `fetch_and_extract` call.
struct FetchToolPayload: Encodable {
    struct Page: Encodable {
        let url: String
        let title: String?
        let excerpts: [String]
        var relevant_links: [ExtractedLink]? = nil
        var relevant_images: [ExtractedImage]? = nil
        var excerpts_truncated: Bool? = nil
    }
    let pages: [Page]
    var failed_urls: [String]? = nil
    var dropped_requests: Int? = nil
}

/// Pure helpers shared by the loop and the selftest.
enum WebAgentSupport {
    /// Agent-round variant of a reasoning config: same effort/budget, but
    /// the response must INCLUDE the reasoning so it can be replayed on the
    /// next round (the mechanical stages keep exclude:true — they never
    /// replay, and excluding saves bandwidth).
    static func includedInResponse(_ reasoning: ORChatReq.Reasoning?) -> ORChatReq.Reasoning? {
        reasoning.map { ORChatReq.Reasoning(effort: $0.effort, max_tokens: $0.max_tokens, exclude: false) }
    }

    /// Enforce a per-call cap; returns the kept slice and how many were
    /// dropped (surfaced in the tool result so the model learns the cap).
    static func capped<T>(_ items: [T], to cap: Int) -> (kept: [T], dropped: Int) {
        guard items.count > cap else { return (items, 0) }
        return (Array(items.prefix(cap)), items.count - cap)
    }

    /// Filter search results the agent has already seen in an earlier round.
    /// Returns the fresh results and the number omitted; `seen` is updated
    /// with the fresh links.
    static func dedupeAgainstSeen(_ results: [WebResult], seen: inout Set<String>) -> (fresh: [WebResult], omitted: Int) {
        var fresh: [WebResult] = []
        var omitted = 0
        for r in results {
            if seen.contains(r.link) { omitted += 1 } else {
                seen.insert(r.link)
                fresh.append(r)
            }
        }
        return (fresh, omitted)
    }

    /// Clamp a list of excerpt strings to a total character budget, keeping
    /// whole excerpts while they fit and truncating the first overflowing one.
    static func clampExcerpts(_ excerpts: [String], totalBudget: Int) -> (kept: [String], truncated: Bool) {
        var used = 0
        var out: [String] = []
        for e in excerpts {
            if used >= totalBudget { return (out, true) }
            if used + e.count <= totalBudget {
                out.append(e)
                used += e.count
            } else {
                let room = totalBudget - used
                out.append(String(e.prefix(room)) + " …[truncated]")
                return (out, true)
            }
        }
        return (out, false)
    }
}

// MARK: - Transcripts (one per transport)

/// Chat-completions transcript: system + user + assistant(tool_calls) +
/// tool-result messages, replayed in full each round. Reasoning fields that
/// the gateway returned are replayed verbatim (reasoning_content for
/// OpenCode-style gateways, reasoning for OpenRouter).
final class WebAgentChatTranscript {
    private(set) var messages: [ORChatReq.Msg]

    init(system: String, user: String) {
        messages = [
            ORChatReq.Msg(role: "system", content: system),
            ORChatReq.Msg(role: "user", content: user),
        ]
    }

    func appendAssistant(_ message: ORChatResp.Choice.Message) {
        messages.append(ORChatReq.Msg(
            role: "assistant",
            content: message.content,
            tool_calls: message.tool_calls,
            reasoning: message.reasoning,
            reasoning_details: message.reasoning_details,
            reasoning_content: message.reasoning_content
        ))
    }

    func appendToolResult(callID: String, content: String) {
        messages.append(ORChatReq.Msg(role: "tool", content: content, tool_call_id: callID))
    }

    func appendUser(_ text: String) {
        messages.append(ORChatReq.Msg(role: "user", content: text))
    }
}

/// Responses API transcript: user/nudge items plus verbatim replay of every
/// output item (reasoning with encrypted content, messages, function calls)
/// and our function_call_output items.
final class WebAgentResponsesTranscript {
    let instructions: String
    private(set) var input: [JSONValue]

    init(instructions: String, user: String) {
        self.instructions = instructions
        input = [.object(["role": .string("user"), "content": .string(user)])]
    }

    func appendOutputItems(_ items: [JSONValue]) {
        input.append(contentsOf: items)
    }

    func appendToolResult(callID: String, content: String) {
        input.append(.object([
            "type": .string("function_call_output"),
            "call_id": .string(callID),
            "output": .string(content),
        ]))
    }

    func appendUser(_ text: String) {
        input.append(.object(["role": .string("user"), "content": .string(text)]))
    }

    /// Parse one response's output items into the round shape. Every item is
    /// also replayed verbatim into `input` for the next round.
    static func parseRound(outputItems: [JSONValue]) -> WebAgentRound {
        var text = ""
        var calls: [WebAgentToolCall] = []
        for item in outputItems {
            guard let obj = item.objectValue, let type = obj["type"]?.stringValue else { continue }
            switch type {
            case "message":
                for part in obj["content"]?.arrayValue ?? [] {
                    if let p = part.objectValue, p["type"]?.stringValue == "output_text",
                       let t = p["text"]?.stringValue {
                        if !text.isEmpty { text += "\n" }
                        text += t
                    }
                }
            case "function_call":
                if let name = obj["name"]?.stringValue,
                   let callID = obj["call_id"]?.stringValue {
                    calls.append(WebAgentToolCall(
                        id: callID,
                        name: name,
                        argumentsJSON: obj["arguments"]?.stringValue ?? "{}"
                    ))
                }
            default:
                break // reasoning etc. — replayed, not parsed
            }
        }
        return WebAgentRound(visibleText: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls)
    }
}
