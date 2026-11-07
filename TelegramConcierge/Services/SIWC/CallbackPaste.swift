import Foundation

/// What a sign-in attempt expects from its callback (§3.2 step 1, §3.4.1).
/// Only the redirect pieces, `state` and the expected client — never the
/// PKCE verifier or nonce.
struct SIWCCallbackExpectation: Equatable {
    var port: Int
    var state: String
    /// nil for a new registration (the callback must then carry one).
    var expectedClientId: String?
    var redirectURI: String { "http://127.0.0.1:\(port)\(SIWCEndpoint.callbackPath)" }
}

/// The outcome of one callback (network listener or pasted address).
enum SIWCCallbackOutcome: Equatable {
    /// Accepted: exchange this code with `clientId` and the ISSUED redirect.
    case code(code: String, clientId: String, scope: String?)
    /// A valid-state callback carrying `error`: the attempt ends, no exchange.
    /// `recognized` is the code only when it is in the reviewed list; an
    /// unknown code and every `error_description` are never kept (§2.1 a).
    case error(recognized: String?)
    /// Rejected; the attempt stays pending. The reason is a fixed message.
    case rejected(CallbackPaste.Rejection)
}

/// One parser for pasted callback addresses (Telegram, terminal, setup-api),
/// plan §3.4.1 / D17. It never logs, echoes, persists or forwards the pasted
/// text: rejections are fixed strings. The real network listener does NOT
/// use the lenient steps (only `decodeQuery`/`evaluate`).
enum CallbackPaste {
    enum Rejection: String, Equatable, CaseIterable {
        case oneLine = "Copy the whole address on one line."
        case notSignInAddress = "This isn't the sign-in address."
        case notThisSignIn = "That address is not from this sign-in."
        case incomplete = "The address is incomplete; copy all of it."
        case codeAndError = "This address has both a code and an error; start the sign-in again."
        case expired = "This sign-in link has expired."
        case noneWaiting = "No sign-in is waiting; start one with /subscription login."
        case differentClient = "This address belongs to a different ChatGPT sign-in; nothing was changed."
        case registrationIncomplete = "ChatGPT didn't finish registering Briglia; start the sign-in again."
    }

    /// Error codes with a predefined message (§2.1 a). Anything else is
    /// "unrecognized reason" and never echoed.
    static let recognizedErrors: Set<String> = ["access_denied", "3p_delegated_access_policy_denied", "consent_required",
        "login_required", "interaction_required", "invalid_scope", "server_error", "temporarily_unavailable"]

    static let maxInput = 8192

    // MARK: Interceptor recognizer (§3.4 inbound, v3.1)

    /// Generous: anything that looks like a callback carrying `code`, `state`
    /// or `error` is held back before persistence, whether or not an attempt
    /// is pending. Only `parse` decides acceptance.
    static func looksLikeCallback(_ text: String) -> Bool {
        // A superset of what `parse` accepts (Codex stage-D R1): the parser
        // percent-decodes parameter names, so the recognizer also looks at a
        // leniently decoded copy (twice, so nothing decoded once can hide).
        let once = lenientlyDecoded(text), twice = lenientlyDecoded(once)
        return [text, once, twice].contains(where: recognizes)
    }

    /// Decode every valid `%HH` once; invalid escapes stay as they are.
    static func lenientlyDecoded(_ text: String) -> String {
        guard text.contains("%") else { return text }
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b { case 48...57: return b - 48; case 65...70: return b - 55; case 97...102: return b - 87; default: return nil }
        }
        while i < utf8.count {
            if utf8[i] == 37, i + 2 < utf8.count, let h = hex(utf8[i + 1]), let l = hex(utf8[i + 2]) {
                bytes.append(h << 4 | l); i += 3
            } else { bytes.append(utf8[i]); i += 1 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func recognizes(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("code=") || lower.contains("state=") || lower.contains("error=")
                || lower.contains("c%6fde") || lower.contains("st%61te") else { return false }
        return lower.contains("auth/callback") || lower.contains("127.0.0.1") || lower.contains("localhost")
            || lower.contains("[::1]") || lower.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("?")
            || lower.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("code=")
            || lower.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("state=")
            || lower.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("error=")
            || lower.contains("&state=") || lower.contains("&code=")
    }

    // MARK: Parse (§3.4.1 steps 1–8)

    static func parse(_ raw: String, expectation: SIWCCallbackExpectation?) -> SIWCCallbackOutcome {
        // 1. Bound and trim.
        guard raw.utf8.count <= maxInput else { return .rejected(.oneLine) }
        var text = trim(raw)
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("`", "`"), ("<", ">"), ("\u{201C}", "\u{201D}")]
        if let first = text.first, let last = text.last, text.count >= 2,
           pairs.contains(where: { $0.0 == first && $0.1 == last }) {
            text = trim(String(text.dropFirst().dropLast()))
        }
        guard !text.isEmpty else { return .rejected(.incomplete) }
        if text.unicodeScalars.contains(where: { $0.properties.isWhitespace }) { return .rejected(.oneLine) }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "\\" }) {
            return .rejected(.oneLine)
        }
        guard let expectation else { return .rejected(.noneWaiting) }
        // 2. Classify before any scheme is added.
        let path: String, query: String
        if text.hasPrefix("?") || text.hasPrefix("code=") || text.hasPrefix("state=") || text.hasPrefix("error=") {
            query = text.hasPrefix("?") ? String(text.dropFirst()) : text
            return evaluate(query: query, expectation: expectation)
        } else if text.hasPrefix("/") && !text.hasPrefix("//") {
            let (p, q) = splitPathQuery(text)
            path = p; query = q ?? ""
        } else {
            // 3. Scheme (full forms only).
            var rest = text
            func stripScheme(_ s: String) -> (scheme: String?, rest: String) {
                if let range = s.range(of: "://"), let scheme = Optional(String(s[s.startIndex..<range.lowerBound])),
                   !scheme.isEmpty, scheme.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
                    return (scheme.lowercased(), String(s[range.upperBound...]))
                }
                return (nil, s)
            }
            var (scheme, remainder) = stripScheme(rest)
            // Collapse a repeated leading scheme to the last one.
            while scheme != nil {
                let next = stripScheme(remainder)
                guard let inner = next.scheme, ["http", "https"].contains(inner), ["http", "https"].contains(scheme!) else { break }
                scheme = inner; remainder = next.rest
            }
            if let scheme {
                guard scheme == "http" || scheme == "https" else { return .rejected(.notSignInAddress) }
                rest = remainder
            } else if rest.hasPrefix("//") {
                rest = String(rest.dropFirst(2))
            } else if let colon = rest.firstIndex(of: ":"), rest[rest.startIndex..<colon].unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }),
                      !rest[rest.startIndex..<colon].isEmpty, !rest[rest.index(after: colon)...].hasPrefix("/"),
                      rest[rest.index(after: colon)...].first.map({ !$0.isNumber }) ?? true {
                // `javascript:…`, `mailto:…` and other scheme-like prefixes.
                return .rejected(.notSignInAddress)
            }
            // 4. Authority, path, query. Fragment ignored.
            if let hash = rest.firstIndex(of: "#") { rest = String(rest[rest.startIndex..<hash]) }
            let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
            let authority = String(rest[rest.startIndex..<authorityEnd])
            guard !authority.contains("@") else { return .rejected(.notSignInAddress) }
            // 5. Host: loopback literal only (case ignored).
            let host: String, portText: String?
            if authority.hasPrefix("[") {
                guard let close = authority.firstIndex(of: "]") else { return .rejected(.notSignInAddress) }
                host = String(authority[authority.startIndex...close]).lowercased()
                let after = authority[authority.index(after: close)...]
                portText = after.hasPrefix(":") ? String(after.dropFirst()) : (after.isEmpty ? nil : "x")
            } else if let colon = authority.lastIndex(of: ":") {
                host = String(authority[authority.startIndex..<colon]).lowercased()
                portText = String(authority[authority.index(after: colon)...])
            } else { host = authority.lowercased(); portText = nil }
            guard ["127.0.0.1", "localhost", "[::1]"].contains(host) else { return .rejected(.notSignInAddress) }
            // 6. Port: exactly the issued one.
            guard let portText, !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }), portText.utf8.count <= 5,
                  Int(portText) == expectation.port else { return .rejected(.notSignInAddress) }
            let (p, q) = splitPathQuery(String(rest[authorityEnd...]))
            path = p; query = q ?? ""
        }
        // 7. Path: one trailing slash removed, then byte-exact.
        var checked = path
        if checked.hasSuffix("/") && checked.count > 1 { checked.removeLast() }
        guard checked == SIWCEndpoint.callbackPath else { return .rejected(.notSignInAddress) }
        return evaluate(query: query, expectation: expectation)
    }

    static func trim(_ text: String) -> String {
        let extra: Set<Unicode.Scalar> = ["\u{00A0}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
        var scalars = Array(text.unicodeScalars)
        while let first = scalars.first, first.properties.isWhitespace || extra.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, last.properties.isWhitespace || extra.contains(last) { scalars.removeLast() }
        var out = String.UnicodeScalarView(); out.append(contentsOf: scalars)
        return String(out)
    }

    static func splitPathQuery(_ text: String) -> (String, String?) {
        guard let mark = text.firstIndex(of: "?") else { return (text, nil) }
        return (String(text[text.startIndex..<mark]), String(text[text.index(after: mark)...]))
    }

    // MARK: Query (step 8) — shared with the strict network listener

    /// Split on `&`, each pair on its first `=`, percent-decode names and
    /// values exactly once (`+` stays `+`), reject invalid escapes, invalid
    /// UTF-8 and decoded control characters. nil = reject.
    static func decodeQuery(_ query: String) -> [(String, String)]? {
        if query.isEmpty { return [] }
        var out: [(String, String)] = []
        for part in query.split(separator: "&", omittingEmptySubsequences: false) {
            let name: Substring, value: Substring
            if let eq = part.firstIndex(of: "=") { name = part[part.startIndex..<eq]; value = part[part.index(after: eq)...] }
            else { name = part; value = "" }
            guard let n = percentDecodeOnce(String(name)), let v = percentDecodeOnce(String(value)) else { return nil }
            out.append((n, v))
        }
        return out
    }

    static func percentDecodeOnce(_ text: String) -> String? {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8)[...]
        while let byte = iterator.popFirst() {
            if byte == 0x25 {
                guard iterator.count >= 2, let hi = hex(iterator.popFirst()!), let lo = hex(iterator.popFirst()!) else { return nil }
                bytes.append(hi << 4 | lo)
            } else { bytes.append(byte) }
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8), String(decoding: bytes, as: UTF8.self) == decoded else { return nil }
        guard !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return decoded
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    /// §3.4.1 step 8 and §3.2 step 4 on a decoded query.
    static func evaluate(query: String, expectation: SIWCCallbackExpectation) -> SIWCCallbackOutcome {
        guard let pairs = decodeQuery(query) else { return .rejected(.oneLine) }
        var seen = Set<String>()
        for (name, _) in pairs { guard seen.insert(name).inserted else { return .rejected(.notThisSignIn) } }
        let q = Dictionary(uniqueKeysWithValues: pairs)
        guard let state = q["state"], SIWCJWT.constantTimeEqual(state, expectation.state) else { return .rejected(.notThisSignIn) }
        if q["code"] != nil && q["error"] != nil { return .rejected(.codeAndError) }
        if let error = q["error"] {
            return .error(recognized: recognizedErrors.contains(error) ? error : nil)
        }
        guard let code = q["code"], !code.isEmpty, code.utf8.count <= 2048 else { return .rejected(.incomplete) }
        let cid = q["client_id"]
        if let expected = expectation.expectedClientId {
            if let cid, cid != expected { return .rejected(.differentClient) }
            return .code(code: code, clientId: expected, scope: q["scope"])
        }
        guard let cid, !cid.isEmpty, cid != SIWCEndpoint.dynamicClient, SIWCStore.wellFormedClientId(cid) else {
            return .rejected(.registrationIncomplete)
        }
        return .code(code: code, clientId: cid, scope: q["scope"])
    }

    // MARK: Messages (§2.1)

    static func errorMessage(_ recognized: String?) -> String {
        switch recognized {
        case "access_denied"?: return "Sign-in was cancelled in the browser."
        case "3p_delegated_access_policy_denied"?:
            return "ChatGPT refused this sign-in because of an account or workspace policy (3p_delegated_access_policy_denied). Briglia hasn't changed anything. You can try another ChatGPT account, ask your workspace admin, or choose a different route in settings."
        case let code?: return "ChatGPT refused this sign-in (\(code)). Briglia hasn't changed anything."
        case nil: return "ChatGPT refused this sign-in (unrecognized reason). Briglia hasn't changed anything."
        }
    }

    static let browserFailedHelp = "If ChatGPT showed an error page, the message there explains why (for example an account or workspace policy). Briglia didn't receive a reason. You can try again, use another account, or choose a different route in settings."
}
