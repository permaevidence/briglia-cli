import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Incremental byte framing: UTF-8 is decoded only after a complete SSE record.
/// A bounded final snapshot is authoritative; deltas are checked against it and
/// are never appended a second time or exposed for execution.
struct ResponsesStreamAssembler {
    var subscription = false
    private var line = Data(), record = Data()
    private var total = 0
    private var responseID: String?
    private var terminal: Data?
    private var items: [Int: String] = [:]
    private var arguments: [String: String] = [:]
    private var texts: [String: [Int: String]] = [:]
    private var sequences: [Int: String] = [:]
    private var records = 0

    mutating func append(_ bytes: Data) throws {
        total += bytes.count
        guard total <= ResponsesLimits.roundBytes else { throw ResponsesFailure.overflow }
        for byte in bytes {
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                try consumeLine(); line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                guard line.count + record.count <= ResponsesLimits.recordBytes else { throw ResponsesFailure.overflow }
            }
        }
    }

    mutating func finish() throws -> Data {
        // An unterminated SSE record is a truncated stream, including a partial
        // record after a terminal event. HTTP EOF is never a terminal event.
        guard line.isEmpty, record.isEmpty, let terminal else { throw ResponsesFailure.disconnected }
        return terminal
    }

    private mutating func consumeLine() throws {
        if line.isEmpty {
            if !record.isEmpty { try consumeRecord(); record.removeAll(keepingCapacity: true) }
            return
        }
        if line.starts(with: Data("data:".utf8)) {
            var value = line.dropFirst(5)
            if value.first == 32 { value = value.dropFirst() }
            if !record.isEmpty { record.append(10) }
            record.append(contentsOf: value)
        }
    }

    private mutating func consumeRecord() throws {
        records += 1
        guard records <= 100_000 else { throw ResponsesFailure.overflow }
        if record == Data("[DONE]".utf8) {
            guard terminal != nil else { throw ResponsesFailure.disconnected }; return
        }
        guard let event = try JSONDecoder().decode(JSONValue.self, from: record).responsesObject,
              let rawType = event["type"]?.responsesString else { throw ResponsesFailure.malformed("SSE event") }
        if let sequence = event["sequence_number"]?.responsesInt {
            let fingerprint = ResponsesReplayEnvelope.hash(record)
            if let seen = sequences[sequence] {
                guard seen == fingerprint else { throw ResponsesFailure.malformed("conflicting duplicate SSE event") }
                return
            }
            sequences[sequence] = fingerprint
        }
        let type = subscription && rawType == "response.done" ? "response.completed" : rawType
        // Informational events may evolve independently of output item types.
        // Only the validated terminal snapshot supplies executable work.
        if type == "ping" || type == "keepalive" { return }
        let semanticEvents: Set<String> = [
            "response.created", "response.in_progress", "response.output_item.added", "response.output_item.done",
            "response.function_call_arguments.delta", "response.output_text.delta", "response.refusal.delta",
            "response.completed", "response.failed", "response.incomplete", "error"
        ]
        guard semanticEvents.contains(type) else { return }
        if type == "error" { throw ResponsesFailure.failed(event["code"]?.responsesString ?? "stream error") }
        guard terminal == nil else { throw ResponsesFailure.malformed("semantic event after terminal response") }
        switch type {
        case "response.created", "response.in_progress":
            guard let id = event["response"]?.responsesObject?["id"]?.responsesString else {
                throw ResponsesFailure.malformed("stream response identity")
            }
            try identify(id)
        case "response.output_item.added", "response.output_item.done":
            guard let index = event["output_index"]?.responsesInt, index < ResponsesLimits.items,
                  let id = event["item"]?.responsesObject?["id"]?.responsesString else {
                throw ResponsesFailure.malformed("stream item identity")
            }
            if let old = items[index], old != id { throw ResponsesFailure.malformed("changed stream item identity") }
            if items.contains(where: { $0.key != index && $0.value == id }) { throw ResponsesFailure.malformed("duplicate stream item") }
            items[index] = id
        case "response.function_call_arguments.delta":
            let (id, delta) = try deltaFields(event)
            arguments[id, default: ""] += delta
            guard arguments[id]!.utf8.count <= ResponsesLimits.argumentBytes else { throw ResponsesFailure.overflow }
        case "response.output_text.delta", "response.refusal.delta":
            let (id, delta) = try deltaFields(event)
            guard let index = event["content_index"]?.responsesInt, index < ResponsesLimits.items else {
                throw ResponsesFailure.malformed("stream content index")
            }
            texts[id, default: [:]][index, default: ""] += delta
        case "response.completed", "response.failed", "response.incomplete":
            guard let response = event["response"]?.responsesObject,
                  let id = response["id"]?.responsesString,
                  response["status"]?.responsesString == String(type.dropFirst("response.".count)) else {
                throw ResponsesFailure.malformed("terminal event/status mismatch")
            }
            try identify(id)
            if type == "response.completed" { try reconcile(response) }
            terminal = try JSONEncoder().encode(JSONValue.object(response))
        case "error": throw ResponsesFailure.failed(event["code"]?.responsesString ?? "stream error")
        case "response.content_part.added", "response.content_part.done",
             "response.output_text.done", "response.refusal.done",
             "response.function_call_arguments.done", "response.reasoning_summary_part.added",
             "response.reasoning_summary_part.done", "response.reasoning_summary_text.delta",
             "response.reasoning_summary_text.done", "response.reasoning_text.delta", "response.reasoning_text.done":
            break // The terminal snapshot supplies the complete, validated item.
        default:
            break // Informational events never provide executable output.
        }
    }

    private mutating func identify(_ id: String) throws {
        guard !id.isEmpty, responseID == nil || responseID == id else { throw ResponsesFailure.malformed("mixed response identities") }
        responseID = id
    }

    private func deltaFields(_ event: [String: JSONValue]) throws -> (String, String) {
        guard let id = event["item_id"]?.responsesString, !id.isEmpty,
              let delta = event["delta"]?.responsesString else { throw ResponsesFailure.malformed("stream delta") }
        return (id, delta)
    }

    private func reconcile(_ response: [String: JSONValue]) throws {
        guard let output = response["output"]?.responsesArray, output.count <= ResponsesLimits.items else {
            throw ResponsesFailure.malformed("terminal output")
        }
        var found = Set<String>()
        for (index, value) in output.enumerated() {
            guard let item = value.responsesObject, let id = item["id"]?.responsesString else {
                throw ResponsesFailure.malformed("terminal item identity")
            }
            found.insert(id)
            if let expected = items[index], expected != id { throw ResponsesFailure.malformed("terminal item ordering") }
            if let delta = arguments[id], item["arguments"]?.responsesString != delta {
                throw ResponsesFailure.malformed("terminal arguments disagree with deltas")
            }
            if let deltas = texts[id] {
                guard let content = item["content"]?.responsesArray else { throw ResponsesFailure.malformed("terminal text missing") }
                for (position, delta) in deltas {
                    guard position < content.count, let part = content[position].responsesObject,
                          (part["text"]?.responsesString ?? part["refusal"]?.responsesString) == delta else {
                        throw ResponsesFailure.malformed("terminal text disagrees with deltas")
                    }
                }
            }
        }
        guard Set(items.values).isSubset(of: found), Set(arguments.keys).isSubset(of: found),
              Set(texts.keys).isSubset(of: found) else { throw ResponsesFailure.malformed("terminal snapshot omitted streamed items") }
    }
}

/// URLSessionDataDelegate works on both Foundation and FoundationNetworking.
/// All parser/task/continuation state is serialized under the lock, including
/// cancellation before start and late callbacks. Credentials never follow redirects.
final class ResponsesHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completed = false
    private var response: HTTPURLResponse?
    private var streamed = false
    private var data = Data()
    private var assembler = ResponsesStreamAssembler()
    private var overallTimer: DispatchWorkItem?
    private var phaseTimer: DispatchWorkItem?
    private var phaseGeneration: UInt64 = 0
    private var idleTimeout: TimeInterval = 360

    // These are independent clocks even where provider defaults coincide. The
    // connect clock bounds request start through response headers; idle starts
    // at headers and resets on bytes (including SSE comments/heartbeats).
    // Only the immutable overall clock bounds a perpetually active stream.
    private func armPhaseTimerLocked(_ seconds: TimeInterval, phase: String) {
        phaseTimer?.cancel()
        phaseGeneration &+= 1
        let generation = phaseGeneration
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(.failure(URLError(.timedOut, userInfo: ["BrigliaResponsesDeadline": phase])),
                        ifLocked: { self.phaseGeneration == generation })
        }
        phaseTimer = timer
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    func send(_ request: URLRequest, overallTimeout: TimeInterval = 360,
              connectTimeout: TimeInterval? = nil, idleTimeout: TimeInterval? = nil, subscription: Bool = false) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if completed { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.assembler.subscription = subscription
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                // Own the idle clock so its behavior matches FoundationNetworking
                // and Darwin. URLSession's resource clock remains a second bound.
                config.timeoutIntervalForRequest = overallTimeout
                config.timeoutIntervalForResource = overallTimeout
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                self.idleTimeout = idleTimeout ?? request.timeoutInterval
                armPhaseTimerLocked(connectTimeout ?? request.timeoutInterval, phase: "connect")
                let timer = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(URLError(.timedOut, userInfo: ["BrigliaResponsesDeadline": "overall"])))
                }
                overallTimer = timer
                DispatchQueue.global().asyncAfter(deadline: .now() + overallTimeout, execute: timer)
                task.resume(); lock.unlock()
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }

    private func finish(_ result: Result<Data, Error>, ifLocked predicate: () -> Bool = { true }) {
        lock.lock()
        guard !completed, predicate() else { lock.unlock(); return }
        completed = true
        let callback = continuation; continuation = nil
        let task = task; self.task = nil
        let session = session; self.session = nil
        overallTimer?.cancel(); overallTimer = nil
        phaseTimer?.cancel(); phaseTimer = nil
        phaseGeneration &+= 1
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
        callback?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard !completed, let http = response as? HTTPURLResponse else {
            lock.unlock(); completionHandler(.cancel); return
        }
        self.response = http
        armPhaseTimerLocked(idleTimeout, phase: "idle")
        streamed = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
        lock.unlock(); completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        do {
            if !bytes.isEmpty { armPhaseTimerLocked(idleTimeout, phase: "idle") }
            if streamed && response?.statusCode == 200 { try assembler.append(bytes) }
            else {
                let cap = response?.statusCode == 200 ? ResponsesLimits.roundBytes : 64 * 1024
                guard data.count + bytes.count <= cap else { throw ResponsesFailure.overflow }
                data.append(bytes)
            }
            lock.unlock()
        } catch { lock.unlock(); finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        let result: Result<Data, Error>
        do {
            if let error { throw error }
            guard let response else { throw ResponsesFailure.disconnected }
            guard response.statusCode == 200 else {
                if assembler.subscription, let failure = SubscriptionEndpoint.providerError(status: response.statusCode, body: data) {
                    throw failure
                }
                let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                throw ResponsesFailure.http(response.statusCode, seconds.map { $0.isFinite ? min(30, max(0, $0)) : 1 })
            }
            result = .success(streamed ? try assembler.finish() : data)
        } catch { result = .failure(error) }
        lock.unlock(); finish(result)
    }
}
