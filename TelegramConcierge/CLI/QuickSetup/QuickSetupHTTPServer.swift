import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The loopback HTTP/1.1 server behind `briglia quicksetup` (plan §5.1).
/// POSIX sockets (Network.framework is not available on Linux), bound to
/// 127.0.0.1 only, ephemeral port, one request per connection, strict
/// parser: every rule of §5.1 is a 400 (or the documented status) before any
/// route logic runs. Routing, authorization and same-origin checks live in
/// `QuickSetupRouter`; this type only speaks the wire.
final class QuickSetupHTTPServer: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        /// Raw query string (nil when absent). Only `/start` parses it.
        var query: String?
        /// Header names lowercased; duplicates are rejected by the parser
        /// for Host/Content-Length and kept as first-wins otherwise.
        var headers: [String: String]
        var body: Data
        /// `bqs` cookie value, nil when absent or duplicated.
        var cookieBQS: String?
        var contentLength: Int
    }

    struct Response {
        var status: Int
        var headers: [(String, String)] = []
        var body: Data = Data()
        // Set only by the authorized done-status route; never serialized.
        var completesSetup: Bool = false
        static func status(_ code: Int) -> Response { Response(status: code) }
    }

    enum ParseFailure: Error, Equatable {
        case badRequest(String)
        case methodNotAllowed
        case payloadTooLarge
        case incomplete
        var status: Int {
            switch self {
            case .badRequest: return 400
            case .methodNotAllowed: return 405
            case .payloadTooLarge: return 413
            case .incomplete: return 400
            }
        }
    }

    static let maxRequestLine = 2048
    static let maxHeaderBytes = 8192
    static let maxHeaderLines = 64
    static let maxBody = 65_536
    nonisolated(unsafe) static var headerDeadline: TimeInterval = 10
    nonisolated(unsafe) static var bodyDeadline: TimeInterval = 30
    static let maxConnections = 16

    private let requestedPort: UInt16
    private let reuseAddress: Bool
    private let handler: (Request) async -> Response
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var active = 0
    private(set) var lastActivity = Date()
    private var stopped = false
    private var completionDelivered = false
    var hasDeliveredCompletion: Bool { lock.lock(); defer { lock.unlock() }; return completionDelivered }

    /// Allow the final status to reach the browser before tearing down its server.
    /// A closed tab cannot keep setup alive; use a monotonic, capped deadline.
    func waitForCompletionDelivery(timeout: TimeInterval = 10) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + min(10, max(0, timeout))
        while !hasDeliveredCompletion && ProcessInfo.processInfo.systemUptime < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return hasDeliveredCompletion
    }

    @discardableResult
    func writeResponse(_ response: Response, to fd: Int32) -> Bool {
        let written = Self.writeAll(fd, Self.serialize(response))
        if written && response.completesSetup {
            lock.lock(); completionDelivered = true; lock.unlock()
        }
        return written
    }
    var activeConnections: Int { lock.lock(); defer { lock.unlock() }; return active }

    init(port: UInt16 = 0, reuseAddress: Bool = false, handler: @escaping (Request) async -> Response) {
        self.requestedPort = port
        self.reuseAddress = reuseAddress
        self.handler = handler
    }

    // MARK: Lifecycle

    func start() throws {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw ServerError("socket() failed: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Quick Setup keeps SO_REUSEADDR OFF (plan §5.1). OAuth opts in for
        // its fixed callback port so TIME_WAIT cannot block an immediate login.
        // SO_REUSEPORT is never enabled; an existing listener still wins.
        if reuseAddress {
            var enabled: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                close(fd); throw ServerError("Cannot configure callback address reuse")
            }
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requestedPort.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { close(fd); throw ServerError("bind(127.0.0.1) failed: \(String(cString: strerror(errno)))") }
        guard listen(fd, 16) == 0 else { close(fd); throw ServerError("listen() failed: \(String(cString: strerror(errno)))") }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = fd
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
    }

    struct ServerError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            lock.lock()
            let over = active >= Self.maxConnections || stopped
            if !over { active += 1 }
            lock.unlock()
            if over {
                Self.writeAll(fd, Self.serialize(Response(status: 503)))
                close(fd)
                continue
            }
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            #if !canImport(Glibc)
            var noSigpipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            #endif
            // One plain thread per connection: the socket reads block in
            // poll(2), and a stalled peer must never occupy a cooperative
            // thread (16 stalled connections would otherwise starve the
            // workflow actor and the handler itself).
            Thread.detachNewThread { [self] in
                serve(fd)
                lock.lock(); active -= 1; lock.unlock()
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        let headStart = Date()
        var headEnd: Range<Data.Index>?
        // Header phase: read until CRLFCRLF, bounded by size and time.
        while headEnd == nil {
            if Date().timeIntervalSince(headStart) > Self.headerDeadline { return }
            guard let chunk = Self.readSome(fd, timeoutMs: 200) else { return }
            if chunk.isEmpty { continue }
            buffer.append(chunk)
            headEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if headEnd == nil && buffer.count > Self.maxRequestLine + Self.maxHeaderBytes + 4 {
                Self.writeAll(fd, Self.serialize(Response(status: 400)))
                return
            }
        }
        let head = buffer[buffer.startIndex..<headEnd!.lowerBound]
        var request: Request
        switch Self.parseHead([UInt8](head)) {
        case .failure(let f):
            Self.writeAll(fd, Self.serialize(Response(status: f.status)))
            return
        case .success(let r):
            request = r
        }
        var body = Data(buffer[headEnd!.upperBound...])
        let bodyStart = Date()
        while body.count < request.contentLength {
            if Date().timeIntervalSince(bodyStart) > Self.bodyDeadline { return }  // short read: drop
            guard let chunk = Self.readSome(fd, timeoutMs: 200) else { return }
            body.append(chunk)
        }
        if body.count > request.contentLength { body = body.prefix(request.contentLength) }
        request.body = body
        lock.lock(); lastActivity = Date(); lock.unlock()
        // Bridge to the async handler (the workflow actor) from this thread.
        let done = DispatchSemaphore(value: 0)
        var response = Response(status: 500)
        let handler = self.handler
        Task.detached {
            response = await handler(request)
            done.signal()
        }
        done.wait()
        writeResponse(response, to: fd)
    }

    // MARK: Parser (pure, selftest-callable)

    static func parseHead(_ bytes: [UInt8]) -> Result<Request, ParseFailure> {
        // Split lines on CRLF exactly.
        var lines: [[UInt8]] = []
        var cur: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                lines.append(cur); cur = []; i += 2; continue
            }
            cur.append(bytes[i]); i += 1
        }
        lines.append(cur)
        guard let first = lines.first, first.count <= maxRequestLine else { return .failure(.badRequest("request line too long")) }
        guard first.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return .failure(.badRequest("control bytes in the request line")) }
        let requestLine = String(decoding: first, as: UTF8.self)
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .failure(.badRequest("malformed request line")) }
        let method = String(parts[0]), target = String(parts[1]), version = String(parts[2])
        guard version == "HTTP/1.1" else { return .failure(.badRequest("only HTTP/1.1")) }
        guard ["GET", "POST", "OPTIONS"].contains(method) else {
            guard method.allSatisfy({ $0.isLetter }) , !method.isEmpty else { return .failure(.badRequest("bad method")) }
            return .failure(.methodNotAllowed)
        }
        // origin-form only
        guard target.hasPrefix("/") else { return .failure(.badRequest("absolute-form/authority-form target")) }
        guard !target.contains("%") else { return .failure(.badRequest("percent-encoding refused")) }
        var path = target
        var query: String?
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            query = String(target[target.index(after: q)...])
        }
        guard path.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "#" }) else { return .failure(.badRequest("bad path bytes")) }
        if path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) { return .failure(.badRequest("dot segments")) }
        if let query, !query.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber || "=&-_.".contains($0) }) {
            return .failure(.badRequest("bad query bytes"))
        }

        let headerLines = lines.dropFirst()
        guard headerLines.count <= maxHeaderLines else { return .failure(.badRequest("too many header lines")) }
        let totalHeaderBytes = headerLines.reduce(0) { $0 + $1.count + 2 }
        guard totalHeaderBytes <= maxHeaderBytes else { return .failure(.badRequest("headers too large")) }
        var headers: [String: String] = [:]
        var hostCount = 0, clCount = 0
        var cookieValues: [String] = []
        for raw in headerLines {
            if raw.isEmpty { continue }
            if raw[0] == 0x20 || raw[0] == 0x09 { return .failure(.badRequest("obs-fold")) }
            guard let colon = raw.firstIndex(of: 0x3A) else { return .failure(.badRequest("header without colon")) }
            let nameBytes = raw[..<colon], valueBytes = raw[(colon + 1)...]
            guard !nameBytes.isEmpty, nameBytes.allSatisfy({ isTokenChar($0) }) else { return .failure(.badRequest("bad header name")) }
            guard valueBytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7F || $0 == 0x09 }) else { return .failure(.badRequest("control byte in header value")) }
            let name = String(decoding: nameBytes, as: UTF8.self).lowercased()
            let value = String(decoding: valueBytes, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            switch name {
            case "host": hostCount += 1
            case "content-length": clCount += 1
            case "transfer-encoding": return .failure(.badRequest("transfer-encoding refused"))
            case "cookie":
                for part in value.split(separator: ";") {
                    let kv = part.trimmingCharacters(in: .whitespaces)
                    if kv.hasPrefix("bqs=") { cookieValues.append(String(kv.dropFirst(4))) }
                }
            default: break
            }
            if headers[name] == nil { headers[name] = value }
        }
        guard hostCount == 1 else { return .failure(.badRequest("host count")) }
        guard clCount <= 1 else { return .failure(.badRequest("duplicate content-length")) }
        var contentLength = 0
        if let cl = headers["content-length"] {
            guard !cl.isEmpty, cl.allSatisfy({ $0.isNumber }), let n = Int(cl) else { return .failure(.badRequest("bad content-length")) }
            guard n <= maxBody else { return .failure(.payloadTooLarge) }
            contentLength = n
        }
        if method != "POST", contentLength != 0 { return .failure(.badRequest("body on GET/OPTIONS")) }
        let cookie = cookieValues.count == 1 ? cookieValues[0] : nil
        return .success(Request(method: method, path: path, query: query, headers: headers,
                                body: Data(), cookieBQS: cookie, contentLength: contentLength))
    }

    private static func isTokenChar(_ b: UInt8) -> Bool {
        if b >= 0x30 && b <= 0x39 { return true }
        if b >= 0x41 && b <= 0x5A { return true }
        if b >= 0x61 && b <= 0x7A { return true }
        return "!#$%&'*+-.^_`|~".utf8.contains(b)
    }

    /// Query parsing for `/start`: exactly one `t`, 32 lowercase hex.
    static func startToken(fromQuery query: String?) -> String? {
        guard let query else { return nil }
        var tokens: [String] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, kv[0] == "t" else { return nil }  // any other parameter → not a valid start
            tokens.append(String(kv[1]))
        }
        guard tokens.count == 1, tokens[0].count == 32,
              tokens[0].allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return tokens[0]
    }

    // MARK: I/O

    private static func readSome(_ fd: Int32, timeoutMs: Int32) -> Data? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let rc = poll(&pfd, 1, timeoutMs)
        if rc < 0 { return errno == EINTR ? Data() : nil }
        if rc == 0 { return Data() }
        var buf = [UInt8](repeating: 0, count: 16384)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 { return (errno == EINTR || errno == EAGAIN) ? Data() : nil }
        if n == 0 { return nil }
        return Data(buf[0..<n])
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count, let base = raw.baseAddress {
                #if canImport(Glibc)
                let n = send(fd, base + off, raw.count - off, Int32(MSG_NOSIGNAL))
                #else
                let n = write(fd, base + off, raw.count - off)
                #endif
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { return false }
                off += n
            }
            return true
        }
    }

    static let reasonPhrases: [Int: String] = [
        200: "OK", 202: "Accepted", 303: "See Other", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error", 503: "Service Unavailable",
    ]

    /// Every response carries the §5.7 headers and `Connection: close`.
    static func serialize(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrases[response.status] ?? "Status")\r\n"
        var headers = response.headers
        headers.append(("Content-Length", "\(response.body.count)"))
        headers.append(("Connection", "close"))
        headers.append(("Cache-Control", "no-store"))
        headers.append(("X-Content-Type-Options", "nosniff"))
        headers.append(("X-Frame-Options", "DENY"))
        headers.append(("Referrer-Policy", "no-referrer"))
        headers.append(("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"))
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }
}
