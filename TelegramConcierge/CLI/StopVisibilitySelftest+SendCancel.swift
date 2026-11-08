import Foundation

/// SV13 (0.2.68, Codex release round-2 P2): /stop while the turn's FINAL
/// reply is on the wire, after Telegram's response headers arrived but
/// before the body. A real TelegramBotService (the redirect-refusing,
/// cancellable ordinary wire) talks to a loopback fixture that sends 200
/// headers and then holds the body. The cancellation must reach the turn
/// as a cancellation: no generic "Something went wrong" reply may be added
/// to history or sent. Both wires: the per-request session (macOS
/// production) and the routed shared session (Linux production).
extension StopVisibilityHarness {

    func finalReplyCancelAfterHeadersRows() async {
        let fixture: WebFixtureServer
        do { fixture = try WebFixtureServer() } catch { check("SV13 fixture server started", false, "\(error)"); return }
        defer { fixture.stop() }
        let okBody = #"{"ok":true,"result":{"message_id":1,"date":0,"chat":{"id":424242,"type":"private"}}}"#
        // Only the turn's final reply is held after its headers; /stop's own
        // notices are answered at once.
        fixture.route = { request in
            let text = String(data: request.body, encoding: .utf8) ?? ""
            return text.contains("the final reply")
                ? WebFixtureServer.Response(body: okBody, trickle: (interval: 0.2, duration: 30))
                : WebFixtureServer.Response(body: okBody)
        }
        let previousBase = ProcessInfo.processInfo.environment["BRIGLIA_TELEGRAM_API_BASE"]
        setenv("BRIGLIA_TELEGRAM_API_BASE", "http://127.0.0.1:\(fixture.port)/bot", 1)
        defer {
            if let previousBase { setenv("BRIGLIA_TELEGRAM_API_BASE", previousBase, 1) }
            else { unsetenv("BRIGLIA_TELEGRAM_API_BASE") }
        }
        func bodyText(_ r: WebFixtureServer.Request) -> String { String(data: r.body, encoding: .utf8) ?? "" }

        for shared in [false, true] {
            SharedDataTaskSession.disableForTesting = !shared
            SharedDataTaskSession.forceForTesting = shared
            defer { SharedDataTaskSession.disableForTesting = false; SharedDataTaskSession.forceForTesting = false }
            let wire = shared ? "shared session" : "per-request session"

            let manager = await freshManager()
            let service = TelegramBotService()
            await service.configure(token: "1234567890:" + String(repeating: "C", count: 35))
            manager._svRegisterChannel(service)
            manager._svSetLastUserAddress(telegramAddress)

            server.script([MidturnHarness.chatText("the final reply \(wire)")])
            let before = fixture.requests.count
            manager._testStartTurn(for: user("hello \(wire)"))
            let onWire = await waitUntil(timeout: 20) {
                fixture.requests.dropFirst(before).contains { bodyText($0).contains("the final reply \(wire)") }
            }
            check("SV13 (\(wire)) the final reply reached Telegram's wire", onWire)
            try? await Task.sleep(nanoseconds: 700_000_000)   // the 200 headers land; the body is held
            let stopAt = Date()
            let stopped = await timedStop(manager)
            check("SV13 (\(wire)) /stop returns", stopped != nil, "\(String(describing: stopped))")
            let ended = await waitUntil(timeout: 20) { manager._svActiveRunId == nil }
            let endedAfter = Date().timeIntervalSince(stopAt)
            // The held body would keep an uncancelled send open for 30 s.
            check("SV13 (\(wire)) the held send was cancelled: the turn ended within 10 s of /stop",
                  ended && endedAfter < 10, "ended=\(ended) after \(endedAfter)s")
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            let generic = manager._testMessages.filter { $0.content.contains("Something went wrong") }
            check("SV13 (\(wire)) no generic \"Something went wrong\" reply in history", generic.isEmpty,
                  generic.map(\.content).joined(separator: " | "))
            let sentGeneric = fixture.requests.dropFirst(before).filter { bodyText($0).contains("Something went wrong") }
            check("SV13 (\(wire)) no generic error reply sent to Telegram", sentGeneric.isEmpty, "\(sentGeneric.count)")
            check("SV13 (\(wire)) no generic error reply parked",
                  !manager._svParkedTexts.contains { $0.contains("Something went wrong") }, "\(manager._svParkedTexts)")
        }
    }
}
