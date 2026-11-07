import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Stage D: Telegram (SIWC plan §3.4, §5.1 items 1 and 4, D2, D23) with a
/// real `ConversationManager` and the Bot API answered in process. Runs in
/// a child process with its own HOME, XDG roots and preferences domain.
extension SIWCSelftest {
    static let telegramLinkName = "briglia-mw-siwcd"

    static func stageDTelegramTests(_ root: URL, _ c: Checks) async throws {
        let fm = FileManager.default
        let base = root.appendingPathComponent("tg-\(UUID().uuidString.prefix(6))")
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: base.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home; env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"; env["XDG_DATA_HOME"] = home + "/.local/share"
        env["TMPDIR"] = base.appendingPathComponent("tmp").path + "/"
        env.removeValue(forKey: "BRIGLIA_TELEGRAM_API_BASE"); env.removeValue(forKey: "BRIGLIA_PROFILE")
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = base.appendingPathComponent(telegramLinkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__siwc-selftest", "--telegram-child"]
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        TestPrefsDomains.purge(telegramLinkName)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        var rows = 0
        for line in lines {
            if line.hasPrefix("✔ ") { c.check(String(line.dropFirst(2)), true); rows += 1 }
            else if line.hasPrefix("✖ ") { c.check(String(line.dropFirst(2)), false); rows += 1 }
        }
        c.check("telegram: the child ran every row and exited cleanly", rows >= 10 && process.terminationStatus == 0,
                "rows \(rows) status \(process.terminationStatus)")
    }

    /// The child: everything below runs inside the isolated roots.
    @MainActor
    static func telegramChild() async throws {
        let c = Checks()
        let offline = SIWCError(.local, "selftest: network disabled")
        SIWCAuthClient.sendOverride = { _, _ in throw offline }
        SIWCModels.fetchOverride = { _ in throw offline }
        ResponsesAdapter.siwcSendOverride = { _ in throw offline }
        try resetLive()
        let token = "424242:AAsyntheticSIWCTelegramTokenxxxxx", chat = 424242
        try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: token)
        try KeychainHelper.save(key: KeychainHelper.telegramChatIdKey, value: String(chat))
        let api = TGFakeBotAPI()
        final class Log: @unchecked Sendable { let lock = NSLock(); var bodies: [(String, [String: Any])] = []
            func add(_ m: String, _ b: [String: Any]) { lock.lock(); bodies.append((m, b)); lock.unlock() }
            var all: [(String, [String: Any])] { lock.lock(); defer { lock.unlock() }; return bodies } }
        let log = Log()
        TelegramBotService.transportOverrideForTesting = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            log.add(request.url?.lastPathComponent ?? "", body)
            return api.handle(request)
        }
        let manager = ConversationManager()
        await manager._svRegisterTelegram()
        try? await Task.sleep(nanoseconds: 150_000_000)
        manager.startSIWCSurfaces()   // the daemon's wiring (destination, notice delivery)
        try? await Task.sleep(nanoseconds: 100_000_000)
        // The shared flow, with the in-process exchange and this manager's writer.
        let owner = FakeSettingsOwner()
        let fixture = flowFixture(owner, fake: FakeAuth(), sub: "sub-telegram")
        SIWCFlow.shared.resetForTests()
        SIWCFlow.shared.startListener = false; SIWCFlow.shared.pollNanos = 20_000_000
        SIWCFlow.shared.makeSignIn = fixture.makeSignIn; SIWCFlow.shared.writer = fixture.writer
        SIWCFlow.shared.commitActivation = fixture.commitActivation; SIWCFlow.shared.exchange = fixture.exchange
        func sent() -> [String] { log.all.filter { $0.0 == "sendMessage" }.compactMap { $0.1["text"] as? String } }
        func scanRoots(_ needle: String) -> Bool {
            let roots = [ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]!, ProcessInfo.processInfo.environment["XDG_DATA_HOME"]!]
            for r in roots {
                guard let e = FileManager.default.enumerator(atPath: r) else { continue }
                for case let p as String in e {
                    if let d = FileManager.default.contents(atPath: r + "/" + p), String(decoding: d, as: UTF8.self).contains(needle) { return true }
                }
            }
            return false
        }
        func update(_ id: Int, _ text: String) -> TelegramUpdate {
            let message: [String: Any] = ["message_id": id, "date": 1_790_000_000, "text": text,
                                          "chat": ["id": chat, "type": "private", "first_name": "Owner"],
                                          "from": ["id": chat, "is_bot": false, "first_name": "Owner"]]
            return try! JSONDecoder().decode(TelegramUpdate.self, from: JSONSerialization.data(withJSONObject: ["update_id": id, "message": message]))
        }

        // 1. A callback-shaped paste with no sign-in waiting.
        let stray = "127.0.0.1:5555/auth/callback?code=STRAY-SECRET&state=abc"
        await manager._testProcessUpdate(update(101, stray))
        c.check("interceptor: a callback paste with nothing waiting → fixed reply, never in history or the model's input",
                sent().last == CallbackPaste.Rejection.noneWaiting.rawValue && manager._testMessages.isEmpty
                && !sent().contains { $0.contains("STRAY-SECRET") })
        c.check("interceptor: the pasted message is deleted where Telegram allows",
                log.all.contains { $0.0 == "deleteMessage" && ($0.1["message_id"] as? Int) == 101 })
        let pendingInbound = manager.pendingMidTurnMessages.map(\.content).joined()
        c.check("interceptor: not queued mid-turn, not persisted anywhere under the roots", !pendingInbound.contains("STRAY-SECRET") && !scanRoots("STRAY-SECRET"))

        // A caption carrying the address: the whole message is held back.
        let captionUpdate: TelegramUpdate = {
            let message: [String: Any] = ["message_id": 109, "date": 1_790_000_000, "caption": "?code=CAPTION-SECRET&state=x",
                                          "document": ["file_id": "doc1", "file_unique_id": "u1", "file_name": "a.txt"],
                                          "chat": ["id": chat, "type": "private", "first_name": "Owner"],
                                          "from": ["id": chat, "is_bot": false, "first_name": "Owner"]]
            return try! JSONDecoder().decode(TelegramUpdate.self, from: JSONSerialization.data(withJSONObject: ["update_id": 109, "message": message]))
        }()
        await manager._testProcessUpdate(captionUpdate)
        c.check("interceptor: an address in a caption holds the whole message back (no download, not in history or files)",
                !log.all.contains { $0.0 == "getFile" } && manager._testMessages.isEmpty && !scanRoots("CAPTION-SECRET")
                && log.all.contains { $0.0 == "deleteMessage" && ($0.1["message_id"] as? Int) == 109 })

        // The same interceptor in front of the terminal and the phone app's chat.
        let termPaste = "?code=TERM-SECRET&state=zz"
        let termOutcome = await manager.sendFromApp(text: termPaste, attachments: [], policy: .terminal)
        let appOutcome = await manager.sendFromApp(text: "127.0.0.1:1/auth/callback?code=APP-SECRET&state=zz", attachments: [], policy: .appSocket)
        let interceptedBoth: Bool = {
            if case .intercepted(let a) = termOutcome, case .intercepted(let b) = appOutcome {
                return a == CallbackPaste.Rejection.noneWaiting.rawValue && b == a
            }
            return false
        }()
        c.check("interceptor: terminal and app chat inputs hold a callback back too (fixed answer, not in history or any file)",
                interceptedBoth && manager._testMessages.isEmpty && !scanRoots("TERM-SECRET") && !scanRoots("APP-SECRET"))

        // 2. /subscription login official: the paste-back link.
        await manager._testProcessUpdate(update(102, "/subscription login official"))
        func waitFor(_ condition: () -> Bool) async { for _ in 0..<150 where !condition() { try? await Task.sleep(nanoseconds: 20_000_000) } }
        await waitFor { SIWCFlow.shared.isWaiting && sent().contains { $0.contains(SIWCEndpoint.authorizeURL) } }
        let linkMessage = log.all.last { $0.0 == "sendMessage" && (($0.1["text"] as? String) ?? "").contains(SIWCEndpoint.authorizeURL) }
        let linkText = linkMessage?.1["text"] as? String ?? ""
        let urlQ = query(linkText.components(separatedBy: .whitespacesAndNewlines).first { $0.hasPrefix(SIWCEndpoint.authorizeURL) })
        c.check("telegram: the sign-in link goes out with link previews disabled",
                ((linkMessage?.1["link_preview_options"] as? [String: Any])?["is_disabled"] as? Bool) == true)
        c.check("telegram: the link has no id_token_hint, no login_hint, no token or email",
                urlQ["id_token_hint"] == nil && urlQ["login_hint"] == nil && !linkText.contains("synthetic") && !linkText.contains("@")
                && urlQ["ext_agent_host_id"] != nil)
        c.check("telegram: the text says to paste within about 5 minutes and prefers the menu", linkText.contains(SIWCFlow.pasteHint)
                && linkText.contains(SIWCFlow.telegramCaveat))

        // 3. A wrong paste keeps waiting; the right one signs in.
        let status = SIWCFlow.shared.status
        let sent103 = sent().count
        await manager._testProcessUpdate(update(103, callbackURL(status, code: "TG-WRONG").replacingOccurrences(of: "state=", with: "state=Q")))
        await waitFor { sent().count > sent103 }
        c.check("telegram: a paste for another sign-in → “not this sign-in”, still waiting",
                sent().last == CallbackPaste.Rejection.notThisSignIn.rawValue && SIWCFlow.shared.isWaiting)
        await manager._testProcessUpdate(update(104, callbackURL(status, code: "TG-GOOD-CODE")))
        await waitFor { sent().contains { $0.hasPrefix("Signed in.") } }
        try? await Task.sleep(nanoseconds: 200_000_000)
        c.check("telegram: the right paste signs in; one result message (no extra paste reply)",
                sent().last?.hasPrefix("Signed in.") == true && sent().filter { $0.hasPrefix("Signed in.") }.count == 1, "\(sent().suffix(3))")
        c.check("telegram: the first sign-in shows “You're using your ChatGPT plan”", sent().last?.contains("You're using your ChatGPT plan") == true)
        c.check("telegram: neither pasted address is in history, a sent message or any file",
                manager._testMessages.isEmpty && !sent().contains { $0.contains("TG-GOOD-CODE") || $0.contains("TG-WRONG") }
                && !scanRoots("TG-GOOD-CODE") && !scanRoots("TG-WRONG"))

        // 4. /status shows the route and the plan.
        let sent105 = sent().count
        await manager._testProcessUpdate(update(105, "/status"))
        await waitFor { sent().count > sent105 }
        c.check("status: /status shows the route and “Using ChatGPT plan · Manage usage”",
                sent().last?.contains("ChatGPT (Sign in with ChatGPT) — signed in") == true && sent().last?.contains("Using ChatGPT plan") == true)

        // 5. Plan notices: one push per state change, from the opener, at its destination.
        guard let source = try? ChatGPTRoute.currentSource() else {
            c.check("telegram: a usable selection after the sign-in", false)
            print("SIWC telegram child: \(c.total - c.failed)/\(c.total)"); throw ExitCode.failure
        }
        SIWCPlanState.profileForTesting = AssistantProfile.selectedName
        let before = sent().count
        let t = try SIWCPlanState.admit(source, userTurn: false)
        _ = SIWCPlanState.observe(t, .failure(SIWCError(.limitReached, SIWCError.limitMessage)))
        try? await Task.sleep(nanoseconds: 300_000_000)
        await manager.deliverSIWCNotices()
        await manager.deliverSIWCNotices()
        let limitNotices = sent().dropFirst(before).filter { $0.hasPrefix(SIWCPlanState.limitNotice) }
        c.check("notices: the usage-limit notice is pushed once by the opener (twice delivered → still one)", limitNotices.count == 1, "\(sent().suffix(3))")
        let t2 = try SIWCPlanState.admit(source, userTurn: true)
        _ = SIWCPlanState.observe(t2, .success)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await manager.deliverSIWCNotices()
        c.check("notices: the recovery notice is pushed once", sent().filter { $0 == SIWCPlanState.recoveryNotice }.count == 1)
        // sign_in_required: the notice carries its own paste-back link.
        try await source.store.requireLogin(source.clientId, generation: source.generation)
        let t3 = try SIWCPlanState.admit(source, userTurn: false)
        _ = SIWCPlanState.observe(t3, .failure(SIWCError(.signInRequired, SIWCError.signInMessage)))
        try? await Task.sleep(nanoseconds: 300_000_000)
        await manager.deliverSIWCNotices()
        let signInNotice = log.all.last { $0.0 == "sendMessage" && (($0.1["text"] as? String) ?? "").hasPrefix(SIWCPlanState.signInNotice) }
        let noticeText = signInNotice?.1["text"] as? String ?? ""
        let nq = query(noticeText.components(separatedBy: .whitespacesAndNewlines).first { $0.hasPrefix(SIWCEndpoint.authorizeURL) })
        c.check("notices: the sign-in notice carries a paste-back link: no hints, previews off",
                nq["state"] != nil && nq["id_token_hint"] == nil && nq["login_hint"] == nil
                && ((signInNotice?.1["link_preview_options"] as? [String: Any])?["is_disabled"] as? Bool) == true, noticeText)
        _ = await SIWCFlow.shared.cancel()
        // A notice queued before a bot replacement is dropped, not sent through the new bot.
        try await source.store.requireLogin(source.clientId, generation: source.generation)
        SIWCPlanState.signedIn(source.store, clientId: source.clientId)
        try rewriteBound(source.store, source.clientId) { $0.requiresLogin = nil }
        let t4 = try SIWCPlanState.admit(source, userTurn: false)
        SIWCPlanState.destination = { "another-bot:1" }
        _ = SIWCPlanState.observe(t4, .failure(SIWCError(.limitReached, SIWCError.limitMessage)))
        let count5 = sent().count
        await manager.deliverSIWCNotices()
        c.check("notices: queued for another bot → dropped, not sent through this one", sent().count == count5)
        SIWCPlanState.profileForTesting = nil

        // 6. Invitation (D2): once.
        try resetLive()
        try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: token)
        try KeychainHelper.save(key: KeychainHelper.telegramChatIdKey, value: String(chat))
        try KeychainHelper.saveBatch([ProviderProfiles.activeProfileKey: "chatgpt", SIWCSurface.optInKey: "1"])
        let inv0 = sent().count
        await manager.sendSIWCInvitationIfDue()
        await manager.sendSIWCInvitationIfDue()
        c.check("invitation: sent once in Telegram", sent().dropFirst(inv0).filter { $0.hasPrefix(SIWCSurface.invitationText) }.count == 1)

        TelegramBotService.transportOverrideForTesting = nil
        print("SIWC telegram child: \(c.total - c.failed)/\(c.total)")
        if c.failed > 0 { throw ExitCode.failure }
    }
}
