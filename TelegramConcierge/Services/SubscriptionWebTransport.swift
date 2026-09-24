import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Raw Responses POSTs to the ChatGPT subscription for the web pipeline
/// (legacy agent rounds, excerpt extraction, web_fetch compression) while
/// the main provider is the subscription (`WebSearchBackend.chatgpt`).
///
/// Same wire contract as `ResponsesAdapter` for subscription contexts:
/// pinned endpoint, always streamed, `store:false`, no `max_output_tokens`
/// or `truncation`, `originator`/`session_id`/`ChatGPT-Account-Id`, the
/// credential read per attempt from the subscription store, one refresh on
/// 401. Returns the terminal response object only after checking it
/// (`validatedTerminal`): `completed`, or `incomplete` for callers that
/// handle a truncated text answer themselves; a `failed` response or an error
/// envelope never becomes output or tool calls. The stream assembler commits
/// `output_item.done` items when the backend's `response.completed` carries
/// an empty output, so the result decodes as `OAIResponsesResp`.
///
/// Usage exhaustion (`usage_limit_reached` & co., as an HTTP error body, an
/// SSE `error` or a `response.failed`) is never retried and never moved to
/// API billing: it throws `SubscriptionError` with `usageExhausted`, the
/// same message the main agent gets on the same allowance (owner decision
/// 2026-09-23: a web fallback is useless while the main agent is out too).
enum SubscriptionWebTransport {
    /// Selftest only.
    static func resetForTests() {
        sendOverride = nil
    }

    /// Selftest seam: replaces the network send (request in, terminal
    /// response bytes out). Development builds only.
    nonisolated(unsafe) static var sendOverride: ((URLRequest) async throws -> Data)?

    /// The login generation of the active subscription profile, or nil.
    static func activeGeneration() -> String? {
        let stored = KeychainHelper.loadSnapshot()
        guard WebSearchBackend.followsSubscription(stored: stored) else { return nil }
        let generation = (stored[KeychainHelper.openAICompatibleApiKeyKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return generation.isEmpty ? nil : generation
    }

    /// Pure request construction (no credential): the body normalized to the
    /// subscription contract plus the non-secret headers.
    static func buildRequest(body: [String: JSONValue], generation: String, lane: AffinityLane,
                             timeout: TimeInterval) throws -> URLRequest {
        var body = body
        body["stream"] = .bool(true)
        body["store"] = .bool(false)
        body.removeValue(forKey: "max_output_tokens")
        body.removeValue(forKey: "truncation")
        if body["instructions"] == nil { body["instructions"] = .string("You are Briglia's web research assistant.") }
        let affinity = SessionAffinity.wireId(state: try SessionAffinity.loadState(),
            apiKey: "briglia-subscription-v1:" + generation, lane: lane)
        body["prompt_cache_key"] = .string(affinity)
        var request = URLRequest(url: URL(string: SubscriptionEndpoint.inference)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("briglia", forHTTPHeaderField: "originator")
        request.setValue(affinity, forHTTPHeaderField: "session_id")
        try SessionAffinity.decorate(&request, apiKey: generation, lane: lane)
        request.timeoutInterval = timeout
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(JSONValue.object(body))
        guard request.httpBody!.count <= ResponsesLimits.roundBytes else { throw ResponsesFailure.overflow }
        return request
    }

    /// POST one web request through the subscription and return the terminal
    /// response JSON. Retries transient failures (408/409/429/5xx, dropped
    /// connections) up to three times; never retries usage exhaustion.
    static func post(body: [String: JSONValue], lane: AffinityLane, timeout: TimeInterval) async throws -> Data {
        guard let generation = activeGeneration() else {
            throw SubscriptionError("The ChatGPT subscription is no longer the active provider")
        }
        var request = try buildRequest(body: body, generation: generation, lane: lane, timeout: timeout)
        var usedAccess: String?
        var didRefreshAfter401 = false
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                if adaCLIVersion.hasSuffix("-dev"), let sendOverride {
                    return try validatedTerminal(try await sendOverride(request))
                }
                let login = SubscriptionLogin()
                let credential = try await login.store.credential(generation: generation, refresh: login.refresh)
                try Task.checkCancellation()
                try login.store.validate(generation: generation)
                request.setValue("Bearer " + credential.access, forHTTPHeaderField: "Authorization")
                request.setValue(credential.account, forHTTPHeaderField: "ChatGPT-Account-Id")
                usedAccess = credential.access
                return try validatedTerminal(try await ResponsesHTTPTransport().send(request, overallTimeout: timeout, subscription: true))
            } catch {
                try Task.checkCancellation()
                if let failure = error as? SubscriptionError, failure.usageExhausted { throw failure }
                if case ResponsesFailure.http(401, _) = error {
                    guard !didRefreshAfter401 else {
                        try await SubscriptionAuthStore().requireLogin(generation: generation, rejectedAccess: usedAccess)
                        throw SubscriptionError("ChatGPT rejected the refreshed login; sign in again")
                    }
                    didRefreshAfter401 = true
                    let login = SubscriptionLogin()
                    _ = try await login.store.credential(generation: generation, rejectedAccess: usedAccess, refresh: login.refresh)
                    continue
                }
                var delay = Double(1 << attempt)
                let retry: Bool
                if case ResponsesFailure.http(let code, let after) = error {
                    retry = [408, 409, 429, 500, 502, 503, 504].contains(code)
                    if let after { delay = after }
                } else if let e = error as? URLError {
                    retry = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(e.code)
                } else if case ResponsesFailure.disconnected = error {
                    retry = true
                } else { retry = false }
                guard retry, attempt < 3 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(min(30, max(0, delay)) * 1_000_000_000))
                attempt += 1
            }
        }
    }

    /// Terminal-envelope check shared by every raw web request (the adapter
    /// path has the same gate in `ResponsesRoundDecoder`). `completed` passes;
    /// `incomplete` passes so extraction can keep its truncated-text handling,
    /// and agent rounds refuse to execute tool calls from it; `failed`, an
    /// error object, or any other status throws. Quota codes in the failed
    /// envelope become the typed usage error.
    static func validatedTerminal(_ data: Data) throws -> Data {
        guard let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.responsesObject,
              let status = object["status"]?.responsesString else {
            throw ResponsesFailure.malformed("subscription response has no status")
        }
        let error = object["error"].flatMap { value -> JSONValue? in
            if case .null = value { return nil }; return value
        }
        if status == "failed" || error != nil {
            if let usage = SubscriptionEndpoint.streamedUsageError(["response": .object(object)]) { throw usage }
            throw ResponsesFailure.failed(error?.responsesObject?["code"]?.responsesString ?? "provider failure")
        }
        guard status == "completed" || status == "incomplete" else {
            throw ResponsesFailure.malformed("subscription response status \(status)")
        }
        return data
    }

    /// Plain (non-agent) web stage over the subscription: chat-style
    /// messages become Responses input (system → instructions), with an
    /// optional strict JSON schema as `text.format`. Returns the output text
    /// and token usage.
    static func stageBody(model: String, messages: [(role: String, text: String)], effort: String?,
                          jsonSchema: (name: String, schema: JSONValue)?) -> [String: JSONValue] {
        let instructions = messages.filter { $0.role == "system" }.map(\.text).joined(separator: "\n\n")
        let input: [JSONValue] = messages.filter { $0.role != "system" }.map {
            ResponsesAdapter.message(role: $0.role == "assistant" ? "assistant" : "user", text: $0.text)
        }
        var body: [String: JSONValue] = ["model": .string(model), "input": .array(input)]
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }
        if let effort, !effort.isEmpty { body["reasoning"] = .object(["effort": .string(effort)]) }
        if let jsonSchema {
            body["text"] = .object(["format": .object([
                "type": .string("json_schema"), "name": .string(jsonSchema.name),
                "strict": .bool(true), "schema": jsonSchema.schema])])
        }
        return body
    }

    /// Visible output text of a terminal response (message items only).
    static func outputText(_ response: OAIResponsesResp) -> String {
        WebAgentResponsesTranscript.parseRound(outputItems: response.output ?? []).visibleText
    }
}
