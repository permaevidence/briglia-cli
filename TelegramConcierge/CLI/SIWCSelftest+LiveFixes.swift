import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The three bugs the live gates found on 2026-11-07 (handoff "Live gates"),
/// each tested with real-shaped data instead of the small fakes that hid
/// them. Every value is synthetic; only lengths and shapes follow the live
/// evidence (callback line 2,092 bytes, code 1,893, scope 77, state and
/// client_id 32; encrypted reasoning 2,360 characters).
extension SIWCSelftest {
    /// The real requested scope, `+`-joined as the browser sends it (77 chars).
    static let liveScopeQuery = SIWCEndpoint.fullScopes.joined(separator: "+")

    /// A deterministic synthetic string of `count` characters drawn from
    /// `alphabet` (never a real code or token).
    static func synthetic(_ count: Int, seed: Int, alphabet: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.") -> String {
        let chars = Array(alphabet)
        var state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        return String((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return chars[Int((state >> 33) % UInt64(chars.count))]
        })
    }

    // MARK: BUG 1 — the callback listener

    static func liveListenerTests(_ root: URL, _ c: Checks) async throws {
        let listener = SIWCCallbackListener()
        let port = try await listener.start()
        defer { Task { await listener.stop() } }
        let state = synthetic(32, seed: 1, alphabet: "abcdefghijklmnopqrstuvwxyz0123456789")
        let clientId = "oaiapp" + synthetic(26, seed: 2, alphabet: "abcdefghijklmnopqrstuvwxyz0123456789")
        await listener.arm(SIWCCallbackExpectation(port: port, state: state, expectedClientId: nil))
        let code = synthetic(1893, seed: 3)
        let target = "/auth/callback?code=\(code)&scope=\(liveScopeQuery)&state=\(state)&client_id=\(clientId)"
        c.check("live1: the fixture has the live shape (line 2,092 bytes, scope 77)",
                ("GET " + target + " HTTP/1.1").utf8.count == 2092 && liveScopeQuery.count == 77)
        struct Reply { var status: Int; var type: String?; var body: String }
        func get(_ target: String, method: String = "GET") async -> Reply {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + target)!)
            request.httpMethod = method; request.timeoutInterval = 5
            guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse
            else { return Reply(status: -1, type: nil, body: "") }
            return Reply(status: http.statusCode, type: http.value(forHTTPHeaderField: "Content-Type"), body: String(decoding: data, as: UTF8.self))
        }
        // A refusal first (wrong state, same long shape): it must show a page.
        let wrong = await get(target.replacingOccurrences(of: "state=\(state)", with: "state=\(synthetic(32, seed: 9, alphabet: "abcdef0123456789"))"))
        c.check("live1: a refused long callback is a 400 with a text body and Content-Type (no empty download)",
                wrong.status == 400 && (wrong.type ?? "").hasPrefix("text/plain") && !wrong.body.isEmpty
                && !wrong.body.contains(code.prefix(16)))
        let ok = await get(target)
        c.check("live1: a real-length callback (2,092-byte line, +-joined scope) is accepted",
                ok.status == 200 && (ok.type ?? "").hasPrefix("text/plain") && ok.body.contains("You can close this tab"),
                "status \(ok.status)")
        if case .code(let got, let cid, let scope)? = await listener.take() {
            c.check("live1: the full code, client and scope reach the exchange", got == code && cid == clientId && scope == liveScopeQuery)
        } else { c.check("live1: the full code, client and scope reach the exchange", false) }
        // Bounded: a line over 8 KiB and a foreign method are refused, with a body.
        let huge = await get("/auth/callback?code=\(synthetic(9000, seed: 4))&state=\(state)")
        c.check("live1: a line over 8 KiB is still refused, with a text body", huge.status == 400
                && (huge.type ?? "").hasPrefix("text/plain") && !huge.body.isEmpty)
        let brew = await get("/auth/callback", method: "BREW")
        c.check("live1: every status-only refusal (405) carries a text body", brew.status == 405 && (brew.type ?? "").hasPrefix("text/plain") && !brew.body.isEmpty)
        // Escapes in the query are admitted on the wire and decoded once by
        // CallbackPaste; the path stays escape-free.
        let p = QuickSetupHTTPServer.Policy.oauthCallback
        if case .success(let r) = QuickSetupHTTPServer.parseHead(Array("GET /auth/callback?code=a%2Fb+c&state=s HTTP/1.1\r\nHost: 127.0.0.1:1\r\n".utf8), policy: p) {
            c.check("live1: percent escapes and + are admitted in the callback query", r.query == "code=a%2Fb+c&state=s")
        } else { c.check("live1: percent escapes and + are admitted in the callback query", false) }
        c.check("live1: an escaped path is still refused", { if case .failure = QuickSetupHTTPServer.parseHead(Array("GET /auth%2Fcallback?code=a HTTP/1.1\r\nHost: x\r\n".utf8), policy: p) { return true }; return false }())
        // Other servers (Quick Setup, menu, legacy login) keep today's contract.
        let line = Array(("GET " + target + " HTTP/1.1\r\nHost: 127.0.0.1:1\r\n").utf8)
        c.check("live1: the standard policy still refuses the same line (other servers unchanged)",
                { if case .failure = QuickSetupHTTPServer.parseHead(line) { return true }; return false }())
        c.check("live1: the standard policy still refuses + in a query",
                { if case .failure = QuickSetupHTTPServer.parseHead(Array("GET /x?a=b+c HTTP/1.1\r\nHost: x\r\n".utf8)) { return true }; return false }())
        let standard400 = String(decoding: QuickSetupHTTPServer.serialize(.status(400)), as: UTF8.self)
        c.check("live1: a standard 400 keeps its exact bytes (empty body, no Content-Type)",
                standard400.contains("Content-Length: 0\r\n") && !standard400.contains("\r\nContent-Type:"))
        _ = root
    }

    // MARK: BUG 2 — startup with only an SIWC login

    static let startupLinkName = "briglia-mw-siwcst"

    /// Runs the real `ConversationManager` startup checks in a child with its
    /// own HOME, XDG roots and preference domain (never the live Briglia's).
    static func liveStartupTests(_ root: URL, _ c: Checks) async throws {
        let fm = FileManager.default
        let base = root.appendingPathComponent("st-\(UUID().uuidString.prefix(6))")
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: base.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home; env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"; env["XDG_DATA_HOME"] = home + "/.local/share"
        env["TMPDIR"] = base.appendingPathComponent("tmp").path + "/"
        env["BRIGLIA_TELEGRAM_API_BASE"] = "http://127.0.0.1:9/bot"   // closed local port: no Bot API
        env.removeValue(forKey: "BRIGLIA_PROFILE"); env.removeValue(forKey: "BRIGLIA_CHATGPT_ROUTE")
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = base.appendingPathComponent(startupLinkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__siwc-selftest", "--startup-child"]
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        TestPrefsDomains.purge(startupLinkName)
        var rows = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) {
            if line.hasPrefix("✔ ") { c.check(String(line.dropFirst(2)), true); rows += 1 }
            else if line.hasPrefix("✖ ") { c.check(String(line.dropFirst(2)), false); rows += 1 }
        }
        c.check("live2: the startup child ran every row and exited cleanly", rows >= 6 && process.terminationStatus == 0,
                "rows \(rows) status \(process.terminationStatus)")
    }

    @MainActor
    static func startupChild() async throws {
        let c = Checks()
        let offline = SIWCError(.local, "selftest: network disabled")
        SIWCAuthClient.sendOverride = { _, _ in throw offline }
        SIWCModels.fetchOverride = { _ in throw offline }
        ResponsesAdapter.siwcSendOverride = { _ in throw offline }
        try StoragePaths.ensureRootsChecked()
        try resetLive()
        try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: "424243:AAsyntheticSIWCStartupTokenxxxxxx")
        try KeychainHelper.save(key: KeychainHelper.telegramChatIdKey, value: "424243")
        // Exactly what a finished `subscription login --official` leaves:
        // the SIWC store plus the selection keys, no runtime key slot.
        _ = try await liveSelection(clientId: "oaiappStartup", sub: "sub-startup")
        let stored = KeychainHelper.loadSnapshot()
        c.check("live2: fixture = SIWC selection with no runtime key (as after a live sign-in)",
                ChatGPTRoute.isSIWCSelected(stored: stored) && (stored[KeychainHelper.openAICompatibleApiKeyKey] ?? "").isEmpty
                && { if case .siwc = ChatGPTRoute.resolve(stored: stored) { return true }; return false }())
        let manager = ConversationManager()
        await manager.configure()
        c.check("live2: startup configure() accepts an SIWC-only login", manager.error == nil, manager.error ?? "")
        c.check("live2: the polling gate accepts an SIWC-only login", manager.hasRequiredPollingConfiguration())
        let provider = LLMProvider.fromStoredValue(stored[KeychainHelper.llmProviderKey])
        c.check("live2: doctor counts the SIWC route as a configured main endpoint",
                Doctor.mainEndpointConfigured(provider: provider, baseURL: stored[KeychainHelper.openAICompatibleBaseURLKey] ?? "",
                                                     model: stored[KeychainHelper.openAICompatibleModelKey] ?? "", mainKey: nil, stored: stored))
        c.check("live2: the request route still resolves to SIWC after startup",
                { if case .siwc = ChatGPTRoute.resolve(stored: KeychainHelper.loadSnapshot()) { return true }; return false }())
        // Negative control: the exemption is the SIWC route only. Today's
        // ChatGPT route (and every key-based provider) without a key still
        // refuses to start.
        try KeychainHelper.saveBatch([ChatGPTRoute.routeKey: String?.none])
        let legacy = ConversationManager()
        await legacy.configure()
        c.check("live2: the legacy ChatGPT route without a key still refuses to start",
                legacy.error == "Please configure your OpenAI-compatible API key")
        c.check("live2: doctor still flags a key-less non-SIWC endpoint",
                !Doctor.mainEndpointConfigured(provider: .openAICompatible, baseURL: "https://example.invalid/v1", model: "m",
                                                       mainKey: nil, stored: KeychainHelper.loadSnapshot()))
        print("startup child: \(c.total - c.failed)/\(c.total)")
        if c.failed > 0 { throw SIWCError(.local, "startup child failed") }
    }

    // MARK: BUG 3 — follow-up turns and replay after restart

    /// A terminal Responses object as the live route returns it (the SSE
    /// `response.completed` payload): object/created_at/model, reasoning
    /// items with encrypted content and an empty summary, output_text with
    /// annotations and logprobs, namespaced calls, detailed usage.
    static func liveTerminal(_ output: [[String: Any]], id: String) -> Data {
        let object: [String: Any] = [
            "id": id, "object": "response", "created_at": 1_794_000_000, "status": "completed", "model": "gpt-6.1-sol",
            "output": output, "parallel_tool_calls": true, "store": false, "tool_choice": "auto",
            "usage": ["input_tokens": 4210, "input_tokens_details": ["cached_tokens": 3968],
                      "output_tokens": 112, "output_tokens_details": ["reasoning_tokens": 63], "total_tokens": 4322],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
    static func liveReasoning(_ id: String, seed: Int) -> [String: Any] {
        ["id": id, "type": "reasoning", "summary": [], "encrypted_content": "gAAAAA" + synthetic(2354, seed: seed,
            alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")]
    }
    static func liveMessage(_ id: String, _ text: String) -> [String: Any] {
        ["id": id, "type": "message", "status": "completed", "role": "assistant",
         "content": [["type": "output_text", "annotations": [], "logprobs": [], "text": text]]]
    }
    static func liveCall(_ id: String, callId: String, path: String) -> [String: Any] {
        ["id": id, "type": "function_call", "status": "completed", "namespace": SIWCEndpoint.namespace,
         "call_id": callId, "name": "read_file", "arguments": "{\"path\":\"\(path)\"}"]
    }

    static func liveReplayTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        let (source, _) = try await liveSelection(clientId: "oaiappReplay", sub: "sub-replay")
        let wire = Wire(); wire.install()
        func context(_ source: SIWCCredentialSource) -> ProviderExecutionContext {
            .siwcContext(source: source, model: "gpt-6.1-sol", effort: "high", lane: .main, textOnly: false, nativeToolMedia: false)
        }
        let dir = root.appendingPathComponent("media"); try PrivateStorage.ensureDirectory(dir)
        func conversation(_ messages: [Message], rounds: [ToolInteraction]? = nil) -> PreparedConversation {
            PreparedConversation(systemPrompt: "You are Bree.", messages: messages, imagesDirectory: dir, documentsDirectory: dir,
                                 tools: [readTool], toolResultMessages: rounds, tailSystemMessage: nil, tailUserMessage: nil)
        }
        let r1 = liveReasoning("rs_live_1", seed: 11), r2 = liveReasoning("rs_live_2", seed: 12)
        let enc1 = r1["encrypted_content"] as! String, enc2 = r2["encrypted_content"] as! String
        // Turn 1, round 1: reasoning + a namespaced tool call.
        var service = OpenRouterService()
        let user1 = Message(role: .user, content: "What does notes.txt say?")
        wire.replies = [.success(liveTerminal([r1, liveCall("fc_live_1", callId: "call_live_1", path: "/tmp/notes.txt")], id: "resp_live_1"))]
        guard case .toolCalls(let assistant1, let calls1, _, _, _) = try await service.generateResponses(conversation([user1]), context: context(source)),
              calls1.count == 1 else { c.check("live3: turn 1 round 1 decodes a namespaced call", false); return }
        c.check("live3: turn 1 round 1 decodes a namespaced call with its reasoning", assistant1.responsesReplay != nil)
        let interaction = ToolInteraction(assistantMessage: assistant1,
            results: [ToolResultMessage(toolCallId: calls1[0].id, content: "The notes say: buy oat milk.")], measuredTokenCost: nil)
        // Turn 1, round 2 (same process): replay of round 1, final answer.
        wire.replies = [.success(liveTerminal([r2, liveMessage("msg_live_1", "The notes say to buy oat milk.")], id: "resp_live_2"))]
        let final1 = try await service.generateResponses(conversation([user1], rounds: [interaction]), context: context(source))
        guard case .text(let text1, _, _, _, _, _, let metadata1, _) = final1, let envelope1 = metadata1?.envelope else {
            c.check("live3: turn 1 ends with a text answer carrying its native replay", false); return
        }
        c.check("live3: turn 1 ends with a text answer carrying its native replay", text1 == "The notes say to buy oat milk.")
        var assistantMessage = Message(role: .assistant, content: text1)
        assistantMessage.toolInteractions = [interaction]
        assistantMessage.responsesReplay = envelope1
        // Turn 2 in the same process: the first follow-up after a final answer.
        let user2 = Message(role: .user, content: "And is there anything else?")
        wire.replies = [.success(liveTerminal([liveReasoning("rs_live_3", seed: 13), liveMessage("msg_live_2", "No, that's all.")], id: "resp_live_3"))]
        let before2 = wire.count
        let turn2 = await attempt { try await service.generateResponses(conversation([user1, assistantMessage, user2]), context: context(source)) }
        c.check("live3: a follow-up after a final answer is sent (no local typed-message refusal)",
                wire.count == before2 + 1 && { if case .success = turn2 { return true }; return false }(),
                { if case .failure(let e) = turn2 { return "\(e)" }; return "" }())
        // Restart: history through disk, a new process's fence and service.
        let path = root.appendingPathComponent("conversation.json")
        try JSONEncoder().encode([user1, assistantMessage, user2]).write(to: path)
        let restored = try JSONDecoder().decode([Message].self, from: Data(contentsOf: path))
        SIWCFence.shared.resetForTests()
        service = OpenRouterService()
        guard let fresh = try ChatGPTRoute.currentSource() else { c.check("live3: the source is captured again after restart", false); return }
        c.check("live3: the source is captured again after restart (same identity scope)",
                fresh.identityFingerprint == source.identityFingerprint)
        wire.replies = [.success(liveTerminal([liveMessage("msg_live_3", "Still nothing else.")], id: "resp_live_4"))]
        let before3 = wire.count
        let turn3 = await attempt { try await service.generateResponses(conversation(restored), context: context(fresh)) }
        c.check("live3: the follow-up after a restart is sent", wire.count == before3 + 1
                && { if case .success = turn3 { return true }; return false }(),
                { if case .failure(let e) = turn3 { return "\(e)" }; return "" }())
        guard wire.count == before3 + 1 else { return }
        let input = wire.body(wire.count - 1)["input"]?.responsesArray?.compactMap(\.responsesObject) ?? []
        func index(_ match: ([String: JSONValue]) -> Bool) -> Int? { input.firstIndex(where: match) }
        let iR1 = index { $0["type"]?.responsesString == "reasoning" && $0["encrypted_content"]?.responsesString == enc1 }
        let iCall = index { $0["type"]?.responsesString == "function_call" && $0["call_id"]?.responsesString == "call_live_1"
            && $0["namespace"]?.responsesString == SIWCEndpoint.namespace }
        let iOut = index { $0["type"]?.responsesString == "function_call_output" && $0["call_id"]?.responsesString == "call_live_1" }
        let iR2 = index { $0["type"]?.responsesString == "reasoning" && $0["encrypted_content"]?.responsesString == enc2 }
        let iMsg = index { $0["type"]?.responsesString == "message" && $0["role"]?.responsesString == "assistant"
            && $0["id"]?.responsesString == "msg_live_1" }
        c.check("live3: after restart the encrypted reasoning of both rounds is replayed byte-for-byte", iR1 != nil && iR2 != nil)
        c.check("live3: after restart the tool call (namespaced), its output and the typed assistant answer are replayed in order",
                [iR1, iCall, iOut, iR2, iMsg].allSatisfy { $0 != nil } && iR1! < iCall! && iCall! < iOut! && iOut! < iR2! && iR2! < iMsg!)
        c.check("live3: no typed system item is ever sent", !input.contains {
            $0["type"]?.responsesString == "message" && $0["role"]?.responsesString == "system" })
        // The check itself: exactly typed system items are refused.
        var body = wire.body(wire.count - 1)
        c.check("live3: the final body passes the SIWC invariants", (try? SIWCBody.check(body)) != nil)
        var items = body["input"]?.responsesArray ?? []
        items.append(.object(["type": .string("message"), "role": .string("system"), "content": .string("x")]))
        body["input"] = .array(items)
        c.check("live3: an explicitly typed system item is still refused", (try? SIWCBody.check(body)) == nil)
        items[items.count - 1] = .object(["role": .string("system"), "content": .string("x")])
        body["input"] = .array(items)
        c.check("live3: an untyped system note still passes (D16)", (try? SIWCBody.check(body)) != nil)
    }
}

extension SIWCSelftest {
    static func attempt<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
