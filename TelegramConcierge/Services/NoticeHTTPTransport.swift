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
    let refusesRedirects = true

    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var body = Data()

    /// Test seam: the number of requests this transport has started.
    nonisolated(unsafe) static var requestsStartedForTesting = 0

    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await NoticeHTTPTransport().run(request)
    }

    private func run(_ request: URLRequest) async throws -> (Data, URLResponse) {
        Self.requestsStartedForTesting += 1
        if let shared = SharedDataTaskSession.active {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, URLResponse), Error>) in
                lock.lock(); continuation = c; lock.unlock()
                shared.dataTask(with: request, delegate: self).resume()
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, URLResponse), Error>) in
            lock.lock(); continuation = c; lock.unlock()
            session.dataTask(with: request).resume()
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
        if body.count < Self.maxBodyBytes { body.append(data.prefix(Self.maxBodyBytes - body.count)) }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = continuation; continuation = nil
        let response = self.response, body = self.body
        lock.unlock()
        guard let c else { return }
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
