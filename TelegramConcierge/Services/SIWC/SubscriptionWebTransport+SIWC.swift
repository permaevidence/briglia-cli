import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The web pipeline over Sign in with ChatGPT (SIWC plan §4.2, §4.4): the
/// legacy agent loop, excerpt extraction and `web_fetch` compression while
/// the main provider is ChatGPT on the SIWC route. Same contract as the
/// adapter's SIWC branch: normalized body, `briglia` namespace, fenced and
/// generation-checked sends, the exact destination, SSE from the request.
extension SubscriptionWebTransport {
    static func buildSIWCRequest(body: [String: JSONValue], source: SIWCCredentialSource, lane: AffinityLane,
                                 timeout: TimeInterval) throws -> URLRequest {
        let sessionId = try ResponsesAdapter.siwcSessionId(source, lane: lane)
        var body = body
        body["prompt_cache_key"] = .string(sessionId)
        if body["instructions"] == nil { body["instructions"] = .string("You are Briglia's web research assistant.") }
        body = try SIWCBody.normalize(body, typedPrompt: nil)
        try SIWCBody.check(body)
        var request = URLRequest(url: URL(string: SIWCEndpoint.responsesURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionId, forHTTPHeaderField: "session_id")
        try SessionAffinity.decorate(&request, apiKey: source.affinityKey, lane: lane)
        request.timeoutInterval = timeout
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(JSONValue.object(body))
        guard request.httpBody!.count <= ResponsesLimits.roundBytes else { throw ResponsesFailure.overflow }
        try SIWCBody.checkDestination(request)
        return request
    }

    /// Terminal check plus the namespace/name rule for every output call.
    static func siwcValidatedTerminal(_ data: Data, advertised: Set<String>) throws -> Data {
        if let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.responsesObject,
           object["status"]?.responsesString == "failed",
           let failure = SIWCErrors.streamed(["response": .object(object)]) { throw failure }
        let valid = try validatedTerminal(data)
        let output = (try? JSONDecoder().decode(JSONValue.self, from: valid))?.responsesObject?["output"]?.responsesArray ?? []
        for item in output {
            guard let object = item.responsesObject, object["type"]?.responsesString == "function_call" else { continue }
            guard object["namespace"]?.responsesString == SIWCEndpoint.namespace,
                  let name = object["name"]?.responsesString, advertised.contains(name) else {
                throw ResponsesFailure.malformed("tool call outside the advertised namespace")
            }
        }
        return valid
    }

    static func postSIWC(body: [String: JSONValue], lane: AffinityLane, timeout: TimeInterval,
                         deadline: ExtractorDeadline?) async throws -> Data {
        guard let source = try ChatGPTRoute.currentSource() else {
            throw SubscriptionError("The ChatGPT subscription is no longer the active provider")
        }
        if let model = body["model"]?.responsesString { try await SIWCModels.requireListed(model, source: source) }
        var request = try buildSIWCRequest(body: body, source: source, lane: lane, timeout: timeout)
        let advertised = Set((body["tools"]?.responsesArray ?? []).compactMap { $0.responsesObject?["name"]?.responsesString })
        var usedAccess: String?
        var didRefreshAfter401 = false
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                if let deadline, deadline.remaining <= 0 { throw deadline.exceeded(requestInFlight: false) }
                try ResponsesAdapter.siwcPreSend(source, request: request)
                let tokens = try await source.store.credential(clientId: source.clientId, generation: source.generation,
                                                              refresh: ResponsesAdapter.siwcRefresher(source, budget: nil))
                try Task.checkCancellation()
                try ResponsesAdapter.siwcPreSend(source, request: request)
                request.setValue("Bearer " + tokens.access, forHTTPHeaderField: "Authorization")
                usedAccess = tokens.access
                let pending = request
                let send: () async throws -> Data = {
                    try await ResponsesAdapter.siwcTransportSend(source, request: pending, context: nil, overallTimeout: timeout,
                        connectTimeout: nil, idleTimeout: nil, transport: ResponsesHTTPTransport())
                }
                let bytes: Data
                if let deadline { bytes = try await deadline.race(send) } else { bytes = try await send() }
                try SIWCFence.shared.check(source.fenceKey, capturedEpoch: source.epoch)
                return try siwcValidatedTerminal(bytes, advertised: advertised)
            } catch {
                try Task.checkCancellation()
                if error is ExtractorDeadlineExceeded { throw error }
                if let failure = error as? SIWCError, failure.kind != .transient { throw failure }
                if case ResponsesFailure.http(401, _) = error {
                    guard !didRefreshAfter401 else {
                        try await source.store.requireLogin(source.clientId, generation: source.generation, rejectedAccess: usedAccess)
                        throw SIWCError(.signInRequired, SubscriptionSharing.decorateRevocation(SIWCError.signInMessage))
                    }
                    didRefreshAfter401 = true
                    _ = try await source.store.credential(clientId: source.clientId, generation: source.generation,
                        rejectedAccess: usedAccess, refresh: ResponsesAdapter.siwcRefresher(source, budget: nil))
                    continue
                }
                var delay = Double(1 << attempt)
                let retry: Bool
                if let failure = error as? SIWCError { retry = failure.kind == .transient }
                else if case ResponsesFailure.http(let code, let after) = error {
                    retry = [408, 409, 429, 500, 502, 503, 504].contains(code)
                    if let after { delay = after }
                } else if let e = error as? URLError {
                    retry = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(e.code)
                } else if case ResponsesFailure.disconnected = error {
                    retry = true
                } else { retry = false }
                guard retry, attempt < 3 else { throw error }
                if let deadline, min(30, max(0, delay)) >= deadline.remaining { throw deadline.exceeded(requestInFlight: false) }
                try await Task.sleep(nanoseconds: UInt64(min(30, max(0, delay)) * 1_000_000_000))
                attempt += 1
            }
        }
    }
}
