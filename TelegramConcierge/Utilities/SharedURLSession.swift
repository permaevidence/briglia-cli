import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The delegate callbacks a per-request transport needs. The signatures are
/// exactly URLSessionDataDelegate's, so a transport that already implements
/// them for its own session conforms without new code.
protocol RoutedDataTaskDelegate: AnyObject {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    /// True: redirects are refused (the 3xx itself is delivered). False:
    /// redirects are followed, the URLSession default.
    var refusesRedirects: Bool { get }
}

/// ONE URLSession for the whole process, shared by the delegate-based
/// transports (page reading under the extractor deadline, Responses, ChatGPT
/// sign-in, release downloads), with each task's callbacks routed to the
/// object that started it.
///
/// Why: on Linux, swift-corelibs-foundation crashes the process (SIGABRT,
/// "_MultiHandle deallocated with non-zero retain count 2") when a URLSession
/// is deallocated after it used an HTTPS keep-alive connection, with libcurl
/// 8.14 (Debian 13 / Raspberry Pi OS 13; 8.5 and 7.81 are not affected).
/// The session's deinit runs curl_multi_cleanup, curl closes the pooled TLS
/// connection and calls the socket callback, and corelibs' tear-down closure
/// captures the dying multi handle. A session that is never deallocated never
/// runs that path, which is why URLSession.shared was always safe.
///
/// This session is therefore created once and never invalidated. Ending a
/// request means cancelling its task, never touching the session.
///
/// Isolation matches the old one-session-per-request setup: no cookies, no
/// cache, no credential store, so nothing one request receives is sent on
/// another. Connections are reused. The per-host connection limit is raised
/// so concurrent page reads to one host never queue behind each other (each
/// old session had its own limit of 6). Idle timeouts come from each
/// request's timeoutInterval (every production caller sets it), and the
/// resource clock is only a far backstop behind each transport's own timer.
final class SharedDataTaskSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = SharedDataTaskSession()

    /// Production: Linux only. macOS keeps one session per request, its
    /// shipped behaviour; Foundation on Darwin has no such teardown bug.
    /// Selftests can force the shared path on macOS too.
    static var forceForTesting = false
    /// Selftest only: take the old one-session-per-request path everywhere
    /// (the crash reproduction's "before" run).
    static var disableForTesting = false
    static var active: SharedDataTaskSession? {
        if disableForTesting { return nil }
        #if canImport(FoundationNetworking)
        return shared
        #else
        return forceForTesting ? shared : nil
        #endif
    }

    private(set) var session: URLSession!
    private let lock = NSLock()
    private var routes: [Int: RoutedDataTaskDelegate] = [:]

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpMaximumConnectionsPerHost = 64
        config.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// A task routed to `delegate`, not yet resumed. Its route ends when the
    /// task completes (cancelled tasks complete too).
    func dataTask(with request: URLRequest, delegate: RoutedDataTaskDelegate) -> URLSessionDataTask {
        lock.lock(); defer { lock.unlock() }
        let task = session.dataTask(with: request)
        routes[task.taskIdentifier] = delegate
        return task
    }

    /// Tasks whose completion has not been delivered yet (selftests).
    var routedTaskCount: Int { lock.lock(); defer { lock.unlock() }; return routes.count }

    private func route(_ task: URLSessionTask) -> RoutedDataTaskDelegate? {
        lock.lock(); defer { lock.unlock() }
        return routes[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let target = route(dataTask) else { completionHandler(.cancel); return }
        target.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        route(dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let target = routes.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        target?.urlSession(session, task: task, didCompleteWithError: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(route(task)?.refusesRedirects == true ? nil : request)
    }
}
