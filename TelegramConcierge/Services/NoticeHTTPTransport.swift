import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The wire for one-attempt update notices (security plan v8 §5.5, round-1
/// R3): exactly ONE HTTP request per call. Redirects are refused — the 3xx
/// itself is the outcome (ambiguous: the server received the request) — so
/// no second hop can be sent and a connect/TLS failure always belongs to the
/// only request there was. Linux uses the process-long shared session (the
/// corelibs teardown crash); macOS a per-request ephemeral session, as
/// `BoundedHTTP` does. The body is capped (Telegram answers are small).
final class NoticeHTTPTransport: NSObject, URLSessionDataDelegate, RoutedDataTaskDelegate, @unchecked Sendable {
    static let maxBodyBytes = 64 * 1024
    /// Ordinary replies (`sendCancellable`): a sendMessage answer is a few
    /// KiB; 4 MiB is a backstop, and going past it fails explicitly
    /// (`bodyTooLarge`) instead of handing a truncated answer to the JSON
    /// decoder (Codex round-2 note).
    static let ordinaryMaxBodyBytes = 4 * 1024 * 1024

    /// Thrown by `sendCancellable` when an answer exceeds its limit.
    struct BodyTooLarge: Error {}

    private let bodyLimit: Int
    private let failOnOverflow: Bool
    private var overflowed = false

    init(bodyLimit: Int = NoticeHTTPTransport.maxBodyBytes, failOnOverflow: Bool = false) {
        self.bodyLimit = bodyLimit
        self.failOnOverflow = failOnOverflow
        super.init()
    }
    let refusesRedirects = true

    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var body = Data()
    private var task: URLSessionTask?
    private var cancelled = false

    /// Test seam: the number of requests this transport has started.
    nonisolated(unsafe) static var requestsStartedForTesting = 0

    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await NoticeHTTPTransport().run(request)
    }

    /// The same one-request, no-redirect wire for ORDINARY replies (0.2.68,
    /// Codex round-1 finding 2): with redirects followed, a connect/DNS/TLS
    /// failure could belong to a later hop after the first POST had reached
    /// Telegram, and the in-line retry for "proven not sent" failures would
    /// then deliver a duplicate. Unlike `send`, this one honours task
    /// cancellation (/stop) by cancelling the data task.
    static func sendCancellable(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let transport = NoticeHTTPTransport(bodyLimit: ordinaryMaxBodyBytes, failOnOverflow: true)
        return try await withTaskCancellationHandler {
            try await transport.run(request)
        } onCancel: {
            transport.cancel()
        }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let t = task; lock.unlock()
        t?.cancel()
    }

    /// Registers the started task; cancels it at once when cancellation came first.
    private func adopt(_ t: URLSessionTask) {
        lock.lock(); task = t; let wasCancelled = cancelled; lock.unlock()
        t.resume()
        if wasCancelled { t.cancel() }
    }

    private func run(_ request: URLRequest) async throws -> (Data, URLResponse) {
        Self.requestsStartedForTesting += 1
        if let shared = SharedDataTaskSession.active {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, URLResponse), Error>) in
                lock.lock(); continuation = c; lock.unlock()
                adopt(shared.dataTask(with: request, delegate: self))
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, URLResponse), Error>) in
            lock.lock(); continuation = c; lock.unlock()
            adopt(session.dataTask(with: request))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); self.response = response; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if body.count + data.count > bodyLimit { overflowed = true }
        if body.count < bodyLimit { body.append(data.prefix(bodyLimit - body.count)) }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = continuation; continuation = nil
        let response = self.response, body = self.body
        let wasCancelled = cancelled, overflowed = self.overflowed
        lock.unlock()
        guard let c else { return }
        // Explicit task cancellation (/stop on `sendCancellable`) stays a
        // cancellation even after the response started (Codex round-2 P2):
        // callers route URLError.cancelled to their stop path. Every other
        // post-response failure stays ambiguous (connection lost) below.
        if wasCancelled, error != nil {
            c.resume(throwing: URLError(.cancelled))
            return
        }
        if failOnOverflow, overflowed, response != nil {
            c.resume(throwing: BodyTooLarge())
            return
        }
        if let response, error == nil {
            c.resume(returning: (body, response))
        } else if response != nil {
            // A response had started: the request was certainly sent.
            c.resume(throwing: URLError(.networkConnectionLost))
        } else {
            c.resume(throwing: error ?? URLError(.unknown))
        }
    }
}
