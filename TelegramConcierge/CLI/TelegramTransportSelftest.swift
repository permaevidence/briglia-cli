import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Hidden regression test: a Bot API transport failure must never expose the
/// bot token. Before this guard a DNS outage printed the full
/// `https://api.telegram.org/bot<token>/getUpdates?...` URL to the terminal
/// through NSURLError's userInfo (`[ConversationManager] Poll tick failed:`).
/// Runs against an unresolvable `.invalid` host (RFC 2606) with an isolated
/// XDG root — no real Briglia state, no real network endpoint.
struct TelegramTransportSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__telegram-transport-selftest",
        abstract: "Internal: verify Telegram transport errors never carry the bot token.",
        shouldDisplay: false
    )

    /// The exact predicate a turn uses to choose its /stop path over the
    /// generic "Something went wrong" reply.
    static func turnSeesCancellation(_ error: Error?) async -> Bool {
        guard let error else { return false }
        return await MainActor.run { ConversationManager.isCancellation(error) }
    }

    func run() async throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("briglia-tg-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        setenv("BRIGLIA_TELEGRAM_API_BASE", "https://telegram-transport-selftest.invalid/bot", 1)

        // Synthetic fixture: Bot API token SHAPE only (`<bot id>:<35-char
        // secret>`), never a real credential. The secret is a repeated
        // placeholder so it cannot be mistaken for one.
        let secret = String(repeating: "S", count: 35)
        let token = "1234567890:\(secret)"

        // 1. Static scrubber: the exact NSURLError userInfo shape seen in the field.
        let fieldLine = "Error Domain=NSURLErrorDomain Code=-1003 \"A server with the specified hostname could not be found.\" " +
            "NSErrorFailingURLStringKey=https://api.telegram.org/bot\(token)/getUpdates?offset=100&timeout=0, " +
            "NSErrorFailingURLKey=https://api.telegram.org/file/bot\(token)/photos/file_1.jpg"
        let scrubbed = TelegramBotService.redactBotTokens(in: fieldLine)
        check("scrubber removes every token occurrence", !scrubbed.contains(secret) && !scrubbed.contains(token))
        check("scrubber keeps the surrounding diagnostics",
              scrubbed.contains("Code=-1003") && scrubbed.contains("getUpdates?offset=100") && scrubbed.contains("bot[REDACTED]/getUpdates"))
        check("scrubber leaves a chat id alone", TelegramBotService.redactBotTokens(in: "chat 123456789 update 100") == "chat 123456789 update 100")
        check("scrubber leaves a timestamp alone", TelegramBotService.redactBotTokens(in: "2026-09-10T05:58:00 12:34:56") == "2026-09-10T05:58:00 12:34:56")

        // 2. Live transport path: every Bot API call funnels URLSession errors
        //    through the same helper; getUpdates and a file download are the
        //    two URL shapes that embed the token.
        let service = TelegramBotService()
        await service.configure(token: token)
        var pollError: Error?
        do { _ = try await service.getUpdates() } catch { pollError = error }
        check("getUpdates against an unresolvable host fails", pollError != nil)
        if let error = pollError {
            let rendered = "\(error)"
            check("getUpdates error is TelegramError.transport",
                  { if case .transport = error as? TelegramError { return true } else { return false } }(),
                  String(describing: type(of: error)))
            check("rendered getUpdates error carries no token", !rendered.contains(secret), rendered)
            // Linux's FoundationNetworking (curl) names the HOST in its
            // description ("Could not resolve host: …"); that is not a
            // secret. The invariant is the token-bearing PATH never appears.
            check("rendered getUpdates error carries no token path", !rendered.contains("/bot") && !rendered.contains("getUpdates"), rendered)
            check("localizedDescription carries no token", !error.localizedDescription.contains(secret), error.localizedDescription)
            check("rendered error is readable", rendered.hasPrefix("Telegram network error ("), rendered)
        }

        var sendError: Error?
        do { try await service.sendMessage(chatId: 1, text: "probe") } catch { sendError = error }
        check("sendMessage against an unresolvable host fails", sendError != nil)
        if let error = sendError {
            check("rendered sendMessage error carries no token", !"\(error)".contains(secret), "\(error)")
        }

        // 3. Cancellation survives as a bare URLError(.cancelled) — the turn's
        //    cancellation predicate (ConversationManager.isCancellation)
        //    depends on it. 0.2.68 (Codex round 2): strict — a transport
        //    error no longer counts as a pass. Cancelled before the request
        //    starts, so it can never finish first.
        let cancelTask = Task { try await service.sendMessage(chatId: 1, text: "cancel-probe") }
        cancelTask.cancel()
        var cancelError: Error?
        do { try await cancelTask.value } catch { cancelError = error }
        let cancelRecognized = await Self.turnSeesCancellation(cancelError)
        check("cancelled send throws a cancellation the turn recognizes (not a transport error)",
              cancelRecognized && !"\(cancelError.map { "\($0)" } ?? "")".contains(secret),
              "\(cancelError.map { "\($0)" } ?? "no error")")

        // 4. Cancellation AFTER the response headers arrived (Codex round-2
        //    P2): a loopback server answers 200 headers and then holds the
        //    body; /stop cancels the send meanwhile. Must surface as
        //    cancellation on both wires: the per-request session (macOS
        //    production) and the routed shared session (Linux production).
        //    A connection that drops after the headers WITHOUT a cancel stays
        //    ambiguous (-1005), not cancellation.
        do {
            let server = try WebFixtureServer()
            defer { server.stop() }
            setenv("BRIGLIA_TELEGRAM_API_BASE", "http://127.0.0.1:\(server.port)/bot", 1)
            defer { setenv("BRIGLIA_TELEGRAM_API_BASE", "https://telegram-transport-selftest.invalid/bot", 1) }
            let okBody = #"{"ok":true,"result":{"message_id":1,"date":0,"chat":{"id":1,"type":"private"}}}"#
            for shared in [false, true] {
                SharedDataTaskSession.disableForTesting = !shared
                SharedDataTaskSession.forceForTesting = shared
                defer { SharedDataTaskSession.disableForTesting = false; SharedDataTaskSession.forceForTesting = false }
                let wire = shared ? "shared session" : "per-request session"
                let local = TelegramBotService()
                await local.configure(token: token)

                server.route = { _ in WebFixtureServer.Response(body: okBody, trickle: (interval: 0.2, duration: 20)) }
                let before = server.requests.count
                let started = Date()
                let task = Task { try await local.sendMessage(chatId: 1, text: "after-headers-\(wire)") }
                // Wait until the fixture has the request, then let the headers land.
                for _ in 0..<200 where server.requests.count == before { try? await Task.sleep(nanoseconds: 10_000_000) }
                try? await Task.sleep(nanoseconds: 600_000_000)
                task.cancel()
                var caught: Error?
                do { try await task.value } catch { caught = error }
                let elapsed = Date().timeIntervalSince(started)
                let seen = await Self.turnSeesCancellation(caught)
                check("cancel after headers (\(wire)): the turn sees a cancellation",
                      seen,
                      "\(caught.map { "\($0)" } ?? "no error")")
                check("cancel after headers (\(wire)): it stops promptly (< 5 s)", elapsed < 5, "\(elapsed)")

                // Same shape, no cancel: the connection drops after the headers.
                server.route = { _ in WebFixtureServer.Response(body: okBody, disconnectAfterHeaders: true) }
                var dropped: Error?
                do { try await local.sendMessage(chatId: 1, text: "drop-\(wire)") } catch { dropped = error }
                let droppedIsCancel = await Self.turnSeesCancellation(dropped)
                check("connection lost after headers without a cancel (\(wire)): ambiguous, not cancellation",
                      dropped != nil && !droppedIsCancel,
                      "\(dropped.map { "\($0)" } ?? "no error")")
            }

            // 5. Answer size (Codex round-2 note): a 100 KiB valid answer
            //    decodes (the notice wire's 64 KiB cap would have truncated
            //    it); an answer past the 4 MiB backstop fails explicitly.
            SharedDataTaskSession.disableForTesting = true
            defer { SharedDataTaskSession.disableForTesting = false }
            let big = TelegramBotService()
            await big.configure(token: token)
            let pad = String(repeating: "x", count: 100 * 1024)
            server.route = { _ in WebFixtureServer.Response(body: #"{"ok":true,"result":{"message_id":1,"date":0,"chat":{"id":1,"type":"private"},"text":"\#(pad)"}}"#) }
            var bigError: Error?
            do { try await big.sendMessage(chatId: 1, text: "big") } catch { bigError = error }
            check("a 100 KiB sendMessage answer decodes (no 64 KiB truncation)", bigError == nil, "\(bigError.map { "\($0)" } ?? "")")
            let huge = String(repeating: "y", count: NoticeHTTPTransport.ordinaryMaxBodyBytes + 1024)
            server.route = { _ in WebFixtureServer.Response(body: #"{"ok":true,"result":{"message_id":1,"date":0,"chat":{"id":1,"type":"private"},"text":"\#(huge)"}}"#) }
            var hugeError: Error?
            do { try await big.sendMessage(chatId: 1, text: "huge") } catch { hugeError = error }
            let hugeIsCancel = await Self.turnSeesCancellation(hugeError)
            check("an answer past the 4 MiB backstop fails explicitly (not a truncated decode)",
                  hugeError != nil && !(hugeError is DecodingError) && !hugeIsCancel,
                  "\(hugeError.map { "\($0)" } ?? "no error")")
        } catch {
            check("loopback fixture server started", false, "\(error)")
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        if failures > 0 { throw ExitCode.failure }
    }
}
