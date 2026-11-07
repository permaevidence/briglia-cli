import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension SIWCSelftest {
    /// §3.4.1 table, every row, plus the interceptor recognizer and the
    /// no-echo rule.
    static func pasteTests(_ root: URL, _ c: Checks) async throws {
        let S = "St4te-Value_x", C = "c0de-Value"
        let e = SIWCCallbackExpectation(port: 62602, state: S, expectedClientId: "oaiappClientA")
        let base = "127.0.0.1:62602/auth/callback"
        func accepted(_ text: String, code: String = C, exp: SIWCCallbackExpectation = e) -> Bool {
            if case .code(let got, let cid, _) = CallbackPaste.parse(text, expectation: exp) { return got == code && cid == exp.expectedClientId }
            return false
        }
        func rejected(_ text: String, _ reason: CallbackPaste.Rejection? = nil) -> Bool {
            if case .rejected(let r) = CallbackPaste.parse(text, expectation: e) { return reason == nil || r == reason }
            return false
        }
        let rows: [(String, Bool)] = [
            ("full http address", accepted("http://\(base)?code=\(C)&state=\(S)&scope=openid%20profile")),
            ("iPhone Safari (no scheme): http:// added once", accepted("\(base)?code=\(C)&state=\(S)")),
            ("https:// accepted as http", accepted("https://\(base)?code=\(C)&state=\(S)")),
            ("HTTP:// accepted", accepted("HTTP://\(base)?code=\(C)&state=\(S)")),
            ("surrounding whitespace trimmed", accepted("  http://\(base)?code=\(C)&state=\(S)\n")),
            ("<…> removed once", accepted("<http://\(base)?code=\(C)&state=\(S)>")),
            ("\"…\" removed once", accepted("\"http://\(base)?code=\(C)&state=\(S)\"")),
            ("“…” removed once", accepted("\u{201C}http://\(base)?code=\(C)&state=\(S)\u{201D}")),
            ("NBSP and zero-width trimmed", accepted("\u{00A0}\u{200B}\(base)?code=\(C)&state=\(S)\u{FEFF}")),
            ("repeated scheme collapsed", accepted("http://http://\(base)?code=\(C)&state=\(S)")),
            ("http://https:// collapsed", accepted("http://https://\(base)?code=\(C)&state=\(S)")),
            ("scheme-relative accepted", accepted("//\(base)?code=\(C)&state=\(S)")),
            ("localhost accepted", accepted("localhost:62602/auth/callback?code=\(C)&state=\(S)")),
            ("[::1] accepted", accepted("[::1]:62602/auth/callback?code=\(C)&state=\(S)")),
            ("query only with ?", accepted("?code=\(C)&state=\(S)")),
            ("query only without ?", accepted("code=\(C)&state=\(S)")),
            ("path-only", accepted("/auth/callback?code=\(C)&state=\(S)")),
            ("path-only, one trailing slash", accepted("/auth/callback/?code=\(C)&state=\(S)")),
            ("full, one trailing slash", accepted("\(base)/?code=\(C)&state=\(S)")),
            ("scheme and host case only", accepted("HTTP://LOCALHOST:62602/auth/callback?code=\(C)&state=\(S)")),
            ("wrong port rejected", rejected("127.0.0.1:62603/auth/callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("wrong path rejected", rejected("127.0.0.1:62602/callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("no port rejected", rejected("127.0.0.1/auth/callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("wrong state rejected (attempt stays pending)", rejected("\(base)?code=\(C)&state=WRONG", .notThisSignIn)),
            ("no code rejected", rejected("\(base)?state=\(S)", .incomplete)),
            ("empty code rejected", rejected("\(base)?code=&state=\(S)", .incomplete)),
            ("error with wrong state = not this sign-in", rejected("\(base)?error=access_denied&state=WRONG", .notThisSignIn)),
            ("duplicate code rejected", rejected("\(base)?code=\(C)&code=D&state=\(S)", .notThisSignIn)),
            ("not loopback rejected", rejected("http://example.com:62602/auth/callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("127.0.0.2 rejected", rejected("http://127.0.0.2:62602/auth/callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("0.0.0.0 rejected", rejected("http://0.0.0.0:62602/auth/callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("userinfo rejected", rejected("http://user@127.0.0.1:62602/auth/callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("ftp rejected", rejected("ftp://\(base)?code=\(C)&state=\(S)", .notSignInAddress)),
            ("javascript: rejected", rejected("javascript:alert(1)//code=\(C)&state=\(S)")),
            ("internal space rejected", rejected("http://\(base)?code=\(C) &state=\(S)", .oneLine)),
            ("over 8 KiB rejected", rejected("http://\(base)?code=\(String(repeating: "a", count: 9000))&state=\(S)", .oneLine)),
            ("path-only wrong path rejected (not replaced)", rejected("/callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("path case kept (/AUTH)", rejected("/AUTH/callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("path case kept (Auth/Callback)", rejected("127.0.0.1:62602/Auth/Callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("no // collapsing", rejected("127.0.0.1:62602//auth/callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("no double trailing slash", rejected("\(base)//?code=\(C)&state=\(S)", .notSignInAddress)),
            ("no dot segments", rejected("127.0.0.1:62602/auth/./callback?code=\(C)&state=\(S)", .notSignInAddress)),
            ("state never case-folded", rejected("\(base)?code=\(C)&state=\(S.uppercased())", .notThisSignIn)),
            ("duplicate after decoding (c%6Fde)", rejected("\(base)?code=\(C)&c%6Fde=D&state=\(S)", .notThisSignIn)),
            ("duplicate after decoding (st%61te)", rejected("\(base)?code=\(C)&state=\(S)&st%61te=\(S)", .notThisSignIn)),
            ("invalid escape %ZZ", rejected("\(base)?code=C%ZZ&state=\(S)")),
            ("lone %", rejected("\(base)?code=C%&state=\(S)")),
            ("invalid UTF-8", rejected("\(base)?code=C%FF%FE&state=\(S)")),
            ("encoded LF", rejected("\(base)?code=C%0A&state=\(S)")),
            ("encoded NUL", rejected("\(base)?code=C%00&state=\(S)")),
            ("encoded DEL in state", rejected("\(base)?state=\(S)%7F&code=\(C)")),
            ("backslash in path", rejected("127.0.0.1:62602\\auth\\callback?code=\(C)&state=\(S)", .oneLine)),
            ("backslash scheme", rejected("http:\\\\127.0.0.1:62602/auth/callback?code=\(C)&state=\(S)", .oneLine)),
            ("backslash in query", rejected("\(base)?code=\(C)\\&state=\(S)", .oneLine)),
            ("code and error together: ambiguous", rejected("\(base)?code=\(C)&error=access_denied&state=\(S)", .codeAndError)),
            ("+ stays +", accepted("\(base)?code=C+D&state=\(S)", code: "C+D")),
            ("%2B decodes to +", accepted("\(base)?code=C%2BD&state=\(S)", code: "C+D")),
            ("%20 decodes to space once", accepted("\(base)?code=C%20D&state=\(S)", code: "C D")),
            ("%252B decodes once to %2B", accepted("\(base)?code=C%252BD&state=\(S)", code: "C%2BD")),
            ("a different client_id is rejected", rejected("\(base)?code=\(C)&state=\(S)&client_id=oaiappOther", .differentClient)),
            ("the expected client_id is accepted", accepted("\(base)?code=\(C)&state=\(S)&client_id=oaiappClientA")),
        ]
        for (label, ok) in rows { c.check("paste: \(label)", ok) }
        if case .error(let recognized) = CallbackPaste.parse("\(base)?error=access_denied&state=\(S)", expectation: e) {
            c.check("paste: error=access_denied with the right state ends the attempt", recognized == "access_denied")
        } else { c.check("paste: error=access_denied with the right state ends the attempt", false) }
        let secretish = "sk_live_" + String(repeating: "Q", count: 24)
        if case .error(let recognized) = CallbackPaste.parse("\(base)?error=\(secretish)&error_description=leak\(secretish)&state=\(S)", expectation: e) {
            let message = CallbackPaste.errorMessage(recognized)
            c.check("paste: an unknown error code is dropped and never echoed", recognized == nil && !message.contains(secretish)
                    && message.contains("unrecognized reason"))
        } else { c.check("paste: an unknown error code is dropped and never echoed", false) }
        if case .error(let r) = CallbackPaste.parse("\(base)?error=3p_delegated_access_policy_denied&state=\(S)", expectation: e) {
            c.check("paste: the policy code maps to its predefined message", CallbackPaste.errorMessage(r).contains("3p_delegated_access_policy_denied"))
        } else { c.check("paste: the policy code maps to its predefined message", false) }
        // New registration: the callback must carry an issued client.
        var fresh = e; fresh.expectedClientId = nil
        c.check("paste: a new registration needs an issued client_id", {
            if case .rejected(.registrationIncomplete) = CallbackPaste.parse("\(base)?code=\(C)&state=\(S)", expectation: fresh) { return true }; return false }())
        c.check("paste: dynamic_agent_client is never accepted as the issued client", {
            if case .rejected = CallbackPaste.parse("\(base)?code=\(C)&state=\(S)&client_id=dynamic_agent_client", expectation: fresh) { return true }; return false }())
        c.check("paste: a new registration's issued client is taken from the callback", {
            if case .code(_, "oaiappIssued", _) = CallbackPaste.parse("\(base)?code=\(C)&state=\(S)&client_id=oaiappIssued", expectation: fresh) { return true }; return false }())
        // No attempt pending: caught, fixed reply.
        for form in ["http://\(base)?code=\(C)&state=\(S)", "\(base)?code=\(C)&state=\(S)", "?code=\(C)&state=\(S)",
                     "code=\(C)&state=\(S)", "/auth/callback?code=\(C)&state=\(S)", "<\(base)?code=\(C)&state=\(S)>",
                     "//\(base)?code=\(C)&state=\(S)"] {
            let caught = CallbackPaste.looksLikeCallback(form)
            var fixed = false
            if case .rejected(.noneWaiting) = CallbackPaste.parse(form, expectation: nil) { fixed = true }
            c.check("interceptor: recognized with no attempt pending — \(form.prefix(20))…", caught && fixed)
        }
        c.check("interceptor: ordinary chat text is not held back", !CallbackPaste.looksLikeCallback("Can you check my calendar for tomorrow?"))
        // No rejection message contains any part of the paste.
        let marker = "UNIQUEPASTEMARKER"
        var echoed = false
        for text in ["\(base)?code=\(marker)&state=WRONG", "http://example.com:1/\(marker)?code=\(marker)&state=\(S)",
                     "\(base)?code=\(marker)&error=\(marker)&state=\(S)", String(repeating: marker, count: 1000)] {
            switch CallbackPaste.parse(text, expectation: e) {
            case .rejected(let r): if r.rawValue.contains(marker) { echoed = true }
            case .error(let r): if CallbackPaste.errorMessage(r).contains(marker) { echoed = true }
            case .code: break
            }
        }
        c.check("paste: no reply text ever contains the pasted content", !echoed)
        c.check("paste: every rejection is one of the fixed messages", CallbackPaste.Rejection.allCases.count == 9)
        _ = root
    }

    /// The strict loopback listener (§3.2 step 2): OS-chosen port, exact
    /// Host and path, strict query decoding, one consumption.
    static func listenerTests(_ root: URL, _ c: Checks) async throws {
        let listener = SIWCCallbackListener()
        let port = try await listener.start()
        defer { Task { await listener.stop() } }
        c.check("listener: binds an OS-chosen port (not 1455)", port > 0 && port != 1455)
        let exp = SIWCCallbackExpectation(port: port, state: "S1", expectedClientId: "oaiappClientA")
        await listener.arm(exp)
        func req(_ host: String, _ path: String = "/auth/callback", _ query: String?) -> QuickSetupHTTPServer.Request {
            .init(method: "GET", path: path, query: query, headers: ["host": host], body: Data(), cookieBQS: nil, contentLength: 0)
        }
        c.check("listener: localhost Host header refused (127.0.0.1 only)", await listener.receive(req("localhost:\(port)", "/auth/callback", "code=C&state=S1")).status == 400)
        c.check("listener: wrong path refused", await listener.receive(req("127.0.0.1:\(port)", "/auth/callback/", "code=C&state=S1")).status == 400)
        c.check("listener: wrong state does not consume", await listener.receive(req("127.0.0.1:\(port)", "/auth/callback", "code=C&state=X")).status == 400)
        c.check("listener: scheme-less/lenient forms are never applied", await listener.receive(req("127.0.0.1:\(port)", "/auth/callback", "code=C%ZZ&state=S1")).status == 400)
        c.check("listener: a valid callback is accepted", await listener.receive(req("127.0.0.1:\(port)", "/auth/callback", "code=C&state=S1")).status == 200)
        c.check("listener: the callback is consumed once", await listener.receive(req("127.0.0.1:\(port)", "/auth/callback", "code=C&state=S1")).status == 400)
        if case .code("C", "oaiappClientA", _)? = await listener.take() { c.check("listener: outcome delivered once", await listener.take() == nil) }
        else { c.check("listener: outcome delivered once", false) }
        // A real loopback request reaches the handler (no network beyond 127.0.0.1).
        let second = SIWCCallbackListener()
        let p2 = try await second.start()
        await second.arm(SIWCCallbackExpectation(port: p2, state: "S2", expectedClientId: "oaiappClientA"))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(p2)/auth/callback?code=K&state=S2")!)
        request.timeoutInterval = 5
        let status = (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode ?? 0 } ?? -1
        c.check("listener: a real loopback callback is served and consumed", status == 200)
        await second.stop()
        _ = root
    }
}
