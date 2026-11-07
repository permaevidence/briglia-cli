import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The SIWC branch of the Responses adapter (§4.1, §4.2, §3.7). Reached only
/// for contexts whose credential source is SIWC (`context.siwc`) or whose
/// SIWC capture failed (`siwcFailure`); every other context keeps the legacy
/// code path byte for byte.
extension ResponsesAdapter {
    var isSIWC: Bool { context.siwc != nil || context.siwcFailure != nil }

    /// The SIWC cache key / `session_id` (§4.2 Headers, D18): the operation's
    /// existing affinity lane, scoped to the registration's identity; stable
    /// through rounds, retries, forced finals and compaction of the operation.
    static func siwcSessionId(_ source: SIWCCredentialSource, lane: AffinityLane) throws -> String {
        SessionAffinity.wireId(state: try SessionAffinity.loadState(), apiKey: source.affinityKey, lane: lane)
    }

    func siwcRequest(input: [JSONValue], tools: [ToolDefinition]?) throws -> URLRequest {
        if let failure = context.siwcFailure { throw SIWCError(.signInRequired, failure) }
        guard let source = context.siwc else { throw SIWCError(.signInRequired, SIWCError.signInMessage) }
        if let error = context.configurationError { throw ResponsesFailure.malformed(error) }
        var body: [String: JSONValue] = [
            "model": .string(context.model), "input": .array(input), "store": .bool(false), "stream": .bool(true),
            "include": .array([.string("reasoning.encrypted_content")])
        ]
        if let effort = context.reasoningEffort ?? context.reasoning?.effort {
            guard Self.allowedEfforts(model: context.model).contains(effort) else {
                throw ResponsesFailure.unsupported("reasoning effort \(effort) for \(context.model); use /effort off or a supported value")
            }
            body["reasoning"] = .object(["effort": .string(effort)])
        }
        if let tools {
            guard Set(tools.map { $0.function.name }).count == tools.count else {
                throw ResponsesFailure.malformed("duplicate exposed tool name")
            }
            body["tools"] = .array(try tools.map { tool in
                let parameters = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tool.function.parameters))
                return .object(["type": .string("function"), "name": .string(tool.function.name),
                    "description": .string(MarkerNeutralizer.escape(tool.function.description)),
                    "parameters": Self.siwcFilterSchema(parameters), "strict": .bool(false)])
            })
        }
        let sessionId = try Self.siwcSessionId(source, lane: context.lane)
        body["prompt_cache_key"] = .string(sessionId)
        body = try SIWCBody.normalize(body, typedPrompt: typedPrompt)
        try SIWCBody.check(body)
        var request = URLRequest(url: URL(string: SIWCEndpoint.responsesURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionId, forHTTPHeaderField: "session_id")
        try SessionAffinity.decorate(&request, apiKey: source.affinityKey, lane: context.lane)
        request.timeoutInterval = ModelSilenceTimeout.requestTimeout(customEndpoint: context.usingCustomEndpoint)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(JSONValue.object(body))
        guard request.httpBody!.count <= ResponsesLimits.roundBytes else { throw ResponsesFailure.overflow }
        try SIWCBody.checkDestination(request)
        return request
    }

    static func siwcFilterSchema(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return .string(MarkerNeutralizer.escape(s))
        case .object(let o): return .object(o.mapValues(siwcFilterSchema))
        case .array(let a): return .array(a.map(siwcFilterSchema))
        default: return value
        }
    }

    /// Selftest seam: replaces the network send for SIWC (request in, SSE
    /// assembled terminal bytes out). Development builds only.
    nonisolated(unsafe) static var siwcSendOverride: ((URLRequest) async throws -> Data)?

    /// The pre-send gate, before EVERY send and retry: this process's fence and
    /// epoch, the durable generation and usability, the exact destination.
    static func siwcPreSend(_ source: SIWCCredentialSource, request: URLRequest) throws {
        try SIWCFence.shared.check(source.fenceKey, capturedEpoch: source.epoch)
        try source.store.validate(clientId: source.clientId, generation: source.generation)
        try SIWCBody.checkDestination(request)
    }

    /// One fenced, registered transport send. A sign-out cancels it; its
    /// partial output is never delivered.
    static func siwcTransportSend(_ source: SIWCCredentialSource, request: URLRequest, context: ProviderExecutionContext?,
                                  overallTimeout: TimeInterval, connectTimeout: TimeInterval?, idleTimeout: TimeInterval?,
                                  transport: ResponsesHTTPTransport) async throws -> Data {
        let task = Task<Data, Error> {
            if adaCLIVersion.hasSuffix("-dev"), let override = siwcSendOverride { return try await override(request) }
            return try await transport.send(request, overallTimeout: overallTimeout, connectTimeout: connectTimeout,
                                            idleTimeout: idleTimeout, subscription: false, siwc: true)
        }
        let token = try SIWCFence.shared.register(source.fenceKey, epoch: source.epoch) { task.cancel() }
        defer { SIWCFence.shared.unregister(source.fenceKey, token) }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            // Cancelled by a sign-out (not by the caller): typed outcome.
            if !Task.isCancelled, (try? SIWCFence.shared.check(source.fenceKey, capturedEpoch: source.epoch)) == nil {
                throw SIWCError(.signedOut, SIWCError.signedOutMessage)
            }
            throw error
        }
    }

    static func siwcRefresher(_ source: SIWCCredentialSource, budget: SendBudget?) -> (String) async throws -> SIWCRefreshed {
        let scopes = (try? source.store.readTokens()?.record(source.clientId)?.tokens?.scopes) ?? nil
        let refresh = SIWCSignIn.refresher(auth: SIWCAuthClient(), clientId: source.clientId,
                                           previousScopes: scopes ?? SIWCEndpoint.fullScopes)
        guard let budget else { return refresh }
        return { token in try budget.consume(); return try await refresh(token) }
    }

    func siwcSend(input: [JSONValue], tools: [ToolDefinition]?, receipt: PreparedRequestReceipt) async throws -> LLMResponse {
        defer { if Task.isCancelled { context.responsesTurn.close() } }
        var request = try siwcRequest(input: input, tools: tools)
        guard let source = context.siwc else { throw SIWCError(.signInRequired, SIWCError.signInMessage) }
        CacheDiagnostics.observe(context: context, protocolName: "responses", body: request.httpBody, tailCount: diagnosticsTailCount,
                                 ambientRole: diagnosticsAmbientRole)
        try WireInterceptForTesting.check("responses", request.httpBody)
        let allowed = Set((tools ?? []).map { $0.function.name })
        var usedAccess: String?
        var didRefreshAfter401 = false
        var attempt = 0, dispatch = 0, silenceTimeouts = 0
        while attempt < 4 {
            try Task.checkCancellation()
            do {
                try context.sendBudget?.requireCapacity()
                try Self.siwcPreSend(source, request: request)
                let tokens = try await source.store.credential(clientId: source.clientId, generation: source.generation,
                                                              refresh: Self.siwcRefresher(source, budget: context.authBudget))
                try Task.checkCancellation()
                try Self.siwcPreSend(source, request: request)
                request.setValue("Bearer " + tokens.access, forHTTPHeaderField: "Authorization")
                usedAccess = tokens.access
                try context.sendBudget?.consume()
                dispatch += 1
                let transport = ResponsesHTTPTransport(routingContext: context)
                let usage = ResponsesUsageStore()
                let started = ProcessInfo.processInfo.systemUptime
                let ticket: ResponsesUsageStore.Ticket?
                do { ticket = try usage.begin(context: context, requestID: receipt.requestID, attempt: dispatch, sentRoutingState: false) }
                catch { ticket = nil; ResponsesUsageStore.warn() }
                var counts = ResponsesUsageCounts()
                var completed = false
                defer {
                    if let ticket {
                        do { try usage.finish(ticket, outcome: completed ? .completed : (Task.isCancelled ? .cancelled : .failed),
                            status: transport.usageStatus, durationMs: Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                            counts: counts, receivedRoutingState: false) }
                        catch { ResponsesUsageStore.warn() }
                    }
                }
                let bytes = try await Self.siwcTransportSend(source, request: request, context: context,
                    overallTimeout: request.timeoutInterval, connectTimeout: Self.hostedIdleTimeout(request),
                    idleTimeout: Self.hostedIdleTimeout(request), transport: transport)
                counts = ResponsesUsageCounts.parse(bytes)
                try Task.checkCancellation()
                // A sign-out that landed while the stream ran: nothing delivered.
                try SIWCFence.shared.check(source.fenceKey, capturedEpoch: source.epoch)
                let round = try ResponsesRoundDecoder.decode(bytes, scope: context.responsesScope, receipt: receipt,
                                                             allowedTools: allowed, requiredNamespace: SIWCEndpoint.namespace)
                completed = true
                if !round.calls.isEmpty {
                    var assistant = AssistantToolCallMessage(content: round.text, toolCalls: round.calls, producedByModel: context.provenance)
                    assistant.responsesReplay = round.metadata.envelope
                    assistant.responsesReceipt = receipt
                    return .toolCalls(assistantMessage: assistant, calls: round.calls,
                        promptTokens: round.inputTokens, completionTokens: round.outputTokens, spendUSD: nil)
                }
                return .text(round.text ?? "", reasoning: nil, reasoningDetails: nil,
                    promptTokens: round.inputTokens, completionTokens: round.outputTokens, spendUSD: nil, responses: round.metadata)
            } catch {
                try Task.checkCancellation()
                if case ResponsesFailure.http(401, _) = error {
                    guard !didRefreshAfter401 else {
                        try await source.store.requireLogin(source.clientId, generation: source.generation, rejectedAccess: usedAccess)
                        throw SIWCError(.signInRequired, SubscriptionSharing.decorateRevocation(SIWCError.signInMessage))
                    }
                    try context.sendBudget?.requireCapacity()
                    didRefreshAfter401 = true
                    _ = try await source.store.credential(clientId: source.clientId, generation: source.generation,
                        rejectedAccess: usedAccess, refresh: Self.siwcRefresher(source, budget: context.authBudget))
                    continue
                }
                var delay = Double(1 << attempt)
                let retry: Bool
                if let failure = error as? SIWCError {
                    retry = failure.kind == .transient
                } else if case ResponsesFailure.http(let code, let after) = error {
                    retry = [408, 409, 429, 500, 502, 503, 504].contains(code)
                    if let after { delay = after }
                } else if let e = error as? URLError {
                    retry = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(e.code)
                } else { retry = false }
                if let limit = context.silenceTimeoutRetryLimit, ModelSilenceTimeout.isSilence(error) {
                    silenceTimeouts += 1
                    if silenceTimeouts > limit || !(attempt < 3 && context.adapterRetries == .standard) {
                        throw ModelSilenceTimeout.exhausted(error, attempts: silenceTimeouts, timeout: Self.hostedIdleTimeout(request) ?? request.timeoutInterval)
                    }
                }
                guard retry, attempt < 3, context.adapterRetries == .standard else { throw error }
                try await Task.sleep(nanoseconds: UInt64(min(30, max(0, delay)) * 1_000_000_000))
                attempt += 1
            }
        }
        throw ResponsesFailure.disconnected
    }
}

/// `GET /v1/models` with the SIWC token (§5 Models): the live list, by
/// `display_name`, server order, `visibility: "list"` only; cached per
/// registration for an hour and refreshed on demand.
enum SIWCModels {
    struct Model: Equatable { let slug: String; let displayName: String }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (at: Date, models: [Model])] = [:]
    nonisolated(unsafe) static var fetchOverride: ((URLRequest) async throws -> (Data, Int))?

    static func resetForTests() { lock.lock(); cache = [:]; lock.unlock(); fetchOverride = nil }

    static func parse(_ data: Data) throws -> [Model] {
        guard data.count <= 1 << 20, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SIWCError(.local, "ChatGPT's model list was malformed.")
        }
        let entries = (object["models"] as? [Any]) ?? (object["data"] as? [Any]) ?? []
        return entries.compactMap { $0 as? [String: Any] }.compactMap { entry in
            guard let slug = (entry["slug"] as? String) ?? (entry["id"] as? String), !slug.isEmpty, slug.utf8.count < 128 else { return nil }
            if let visibility = entry["visibility"] as? String, visibility != "list" { return nil }
            return Model(slug: slug, displayName: (entry["display_name"] as? String) ?? slug)
        }
    }

    static func cached(_ source: SIWCCredentialSource, maxAge: TimeInterval = 3600) -> [Model]? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = cache[source.fenceKey], Date().timeIntervalSince(entry.at) < maxAge else { return nil }
        return entry.models
    }

    static func fetch(_ source: SIWCCredentialSource) async throws -> [Model] {
        var request = URLRequest(url: URL(string: SIWCEndpoint.modelsURL)!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try SessionAffinity.decorate(&request, apiKey: source.affinityKey, lane: .probe(UUID()))
        request.timeoutInterval = 30
        try ResponsesAdapter.siwcPreSend(source, request: request)
        let tokens = try await source.store.credential(clientId: source.clientId, generation: source.generation,
                                                       refresh: ResponsesAdapter.siwcRefresher(source, budget: nil))
        try ResponsesAdapter.siwcPreSend(source, request: request)
        request.setValue("Bearer " + tokens.access, forHTTPHeaderField: "Authorization")
        let (data, status): (Data, Int)
        if adaCLIVersion.hasSuffix("-dev"), let fetchOverride { (data, status) = try await fetchOverride(request) }
        else {
            let reply = try await SubscriptionAuthHTTP(deadline: 30).perform(request)
            (data, status) = (reply.0, reply.1)
        }
        guard status == 200 else {
            throw SIWCErrors.classify(status: status, body: data) ?? SIWCError(.transient, "ChatGPT's model list is unavailable (HTTP \(status)).")
        }
        let models = try parse(data)
        lock.lock(); cache[source.fenceKey] = (Date(), models); lock.unlock()
        return models
    }

    /// Lanes that follow the ChatGPT provider (extractor, `web_fetch`, OCR):
    /// a model the plan does not list stops the lane (no fallback, §4.4).
    /// Unknown (list unavailable) lets the request decide.
    static func requireListed(_ model: String, source: SIWCCredentialSource) async throws {
        let models: [Model]
        if let cached = cached(source) { models = cached }
        else if let fetched = try? await fetch(source) { models = fetched }
        else { return }
        guard models.contains(where: { $0.slug == model }) else {
            throw SIWCError(.unsupported, "Model \(model) is not available on your ChatGPT plan. Nothing was retried and no paid path was used.")
        }
    }
}
