import Foundation

/// Test infrastructure only. Retains the bytes received on the socket; JSON
/// decoding belongs to assertions, never to the golden-body capture boundary.
struct CapturedHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

/// Deliberately narrow Content-Length HTTP subset for synthetic loopback tests.
/// A truncated/ambiguous capture is a test failure, never a golden fixture.
struct CaptureRequestParser {
    struct Invalid: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 16 * 1024 * 1024
    private var buffer = Data()
    private var header: (method: String, target: String, fields: [String: String], end: Int, length: Int)?
    private var finished = false

    mutating func append(_ bytes: Data) throws -> CapturedHTTPRequest? {
        guard !finished else { throw Invalid("data after complete request") }
        guard bytes.count <= Self.maxHeaderBytes + Self.maxBodyBytes - buffer.count else {
            throw Invalid("capture size exceeded")
        }
        buffer.append(bytes)
        if header == nil {
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= Self.maxHeaderBytes else { throw Invalid("header size exceeded") }
                return nil
            }
            guard boundary.upperBound <= Self.maxHeaderBytes,
                  let text = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else {
                throw Invalid("invalid header")
            }
            let lines = text.components(separatedBy: "\r\n")
            let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard requestLine.count == 3, requestLine[2] == "HTTP/1.1",
                  requestLine[1].hasPrefix("/"), !requestLine[1].hasPrefix("//") else {
                throw Invalid("invalid request line")
            }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                      !line.hasPrefix(" "), !line.hasPrefix("\t"),
                      !line.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                    throw Invalid("invalid header field")
                }
                let name = String(line[..<colon]).lowercased()
                guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                      fields[name] == nil else { throw Invalid("invalid or duplicate header name") }
                fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard fields["transfer-encoding"] == nil,
                  let rawLength = fields["content-length"], !rawLength.isEmpty,
                  rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(rawLength), length <= Self.maxBodyBytes else {
                throw Invalid("missing, unsupported or invalid body framing")
            }
            header = (String(requestLine[0]), String(requestLine[1]), fields, boundary.upperBound, length)
        }
        guard let header else { throw Invalid("missing parsed header") }
        let received = buffer.count - header.end
        guard received <= header.length else { throw Invalid("bytes beyond Content-Length") }
        guard received == header.length else { return nil }
        finished = true
        return CapturedHTTPRequest(method: header.method, target: header.target,
                                   headers: header.fields, body: Data(buffer[header.end...]))
    }
}
