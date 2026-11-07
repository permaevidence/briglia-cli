import Foundation

/// The SIWC request format (§4.2). Applied as the LAST step to every
/// Responses body that will carry an SIWC token, and only then, so every
/// other route's bytes are untouched. Untyped system items are kept exactly
/// (D16); only destination, auth, headers, unsupported fields and the tool
/// namespace differ from the legacy subscription body.
enum SIWCBody {
    static let unsupportedFields = ["truncation", "max_output_tokens", "background", "max_tool_calls", "metadata",
        "moderation", "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier", "temperature",
        "top_logprobs", "top_p", "user", "service_tier"]
    static let contextReferenceFields = ["conversation", "previous_response_id"]
    static let defaultInstructions = "You are Briglia, the user's assistant."

    struct Failure: Error, LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { "Briglia refused to build this ChatGPT plan request (\(reason)). Nothing was sent." }
    }

    static func isSystemItem(_ item: JSONValue) -> Bool {
        guard let object = item.responsesObject else { return false }
        let type = object["type"]?.responsesString ?? "message"
        return type == "message" && object["role"]?.responsesString == "system"
    }

    /// The single text of a system item, or nil when it is multi-part.
    static func singleText(_ item: JSONValue) -> String? {
        guard let object = item.responsesObject else { return nil }
        if let text = object["content"]?.responsesString { return text }
        guard let parts = object["content"]?.responsesArray, parts.count == 1,
              let part = parts[0].responsesObject, part["type"]?.responsesString == "input_text" else { return nil }
        return part["text"]?.responsesString
    }

    /// One owner for the main prompt: `typedPrompt` becomes `instructions`
    /// byte-for-byte, extracted only from `input[0]` when that item is a
    /// single-text system item with exactly that text. A later (historical)
    /// system note is never promoted. Existing `instructions` must equal the
    /// typed prompt. Idempotent.
    static func normalize(_ body: [String: JSONValue], typedPrompt: String?) throws -> [String: JSONValue] {
        for field in contextReferenceFields where body[field] != nil {
            throw Failure(reason: "\(field) would drop referenced context")
        }
        var out = body
        for field in unsupportedFields { out.removeValue(forKey: field) }
        out["store"] = .bool(false)
        out["stream"] = .bool(true)
        var items = out["input"]?.responsesArray ?? []
        if let existing = out["instructions"] {
            guard let typedPrompt else {
                guard existing.responsesString != nil else { throw Failure(reason: "instructions is not text") }
                out["input"] = .array(try namespaced(items))
                return try wrapTools(out)
            }
            guard existing.responsesString == typedPrompt else { throw Failure(reason: "instructions differ from the typed prompt") }
        } else if let typedPrompt {
            if let first = items.first, isSystemItem(first) {
                guard let text = singleText(first) else { throw Failure(reason: "multi-part system prompt") }
                guard text == typedPrompt else { throw Failure(reason: "input[0] is a system item that is not the typed prompt") }
                items.removeFirst()
            }
            out["instructions"] = .string(typedPrompt)
        } else {
            out["instructions"] = .string(defaultInstructions)
        }
        out["input"] = .array(try namespaced(items))
        return try wrapTools(out)
    }

    /// Replayed `function_call` items carry the namespace (native and
    /// semantic replay); a different namespace is refused.
    static func namespaced(_ items: [JSONValue]) throws -> [JSONValue] {
        try items.map { item in
            guard var object = item.responsesObject, object["type"]?.responsesString == "function_call" else { return item }
            if let ns = object["namespace"] {
                guard ns.responsesString == SIWCEndpoint.namespace else { throw Failure(reason: "replayed call in another namespace") }
                return item
            }
            object["namespace"] = .string(SIWCEndpoint.namespace)
            return .object(object)
        }
    }

    /// All function tools in ONE `briglia` namespace (already wrapped: kept).
    static func wrapTools(_ body: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let tools = body["tools"]?.responsesArray, !tools.isEmpty else { return body }
        if tools.count == 1, let only = tools[0].responsesObject, only["type"]?.responsesString == "namespace" {
            guard only["name"]?.responsesString == SIWCEndpoint.namespace else { throw Failure(reason: "foreign tool namespace") }
            return body
        }
        for tool in tools {
            guard tool.responsesObject?["type"]?.responsesString == "function" else { throw Failure(reason: "only function tools are wrapped") }
        }
        var out = body
        out["tools"] = .array([.object(["type": .string("namespace"), "name": .string(SIWCEndpoint.namespace),
                                        "description": .string("Briglia tools"), "tools": .array(tools)])])
        return out
    }

    /// Invariants asserted on the final SIWC body (tests and a last check).
    static func check(_ body: [String: JSONValue]) throws {
        guard case .bool(false)? = body["store"], case .bool(true)? = body["stream"] else { throw Failure(reason: "store/stream") }
        for field in unsupportedFields + contextReferenceFields where body[field] != nil { throw Failure(reason: "field \(field)") }
        for tool in body["tools"]?.responsesArray ?? [] {
            guard let object = tool.responsesObject, object["type"]?.responsesString == "namespace",
                  object["name"]?.responsesString == SIWCEndpoint.namespace else { throw Failure(reason: "tool outside the namespace") }
        }
        for item in body["input"]?.responsesArray ?? [] {
            if let object = item.responsesObject {
                if object["role"] != nil && object["type"] != nil && object["type"]?.responsesString == "message" {
                    throw Failure(reason: "typed message item")
                }
                if object["type"]?.responsesString == "function_call", object["namespace"]?.responsesString != SIWCEndpoint.namespace {
                    throw Failure(reason: "call outside the namespace")
                }
            }
        }
    }

    /// The final pre-send destination check (§4.1): an SIWC token goes only to
    /// POST /v1/responses or GET /v1/models on api.openai.com (exact scheme,
    /// host, default port, path; no userinfo, query or fragment).
    static func checkDestination(_ request: URLRequest) throws {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == SIWCEndpoint.apiHost, parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw SIWCError(.local, "Briglia refused to send a ChatGPT plan token to an unreviewed address. Nothing was sent.")
        }
        let method = request.httpMethod ?? "GET"
        guard (method == "POST" && parts.path == "/v1/responses") || (method == "GET" && parts.path == "/v1/models") else {
            throw SIWCError(.local, "Briglia refused to send a ChatGPT plan token to an unreviewed address. Nothing was sent.")
        }
    }
}
