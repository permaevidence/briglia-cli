import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// 0.2.70: Telegram `/subscription login|use|cancel|logout official` ran as a
/// settings command holding the commit token, then committed its own change
/// through the writer, which waited for that same token forever (the gate is
/// not reentrant): no sign-in link, no reply, and every later settings
/// command, menu save and forwarded terminal save hung until a restart.
///
/// `cmd-token` (in process): the gate refuses a same-task reentry at once,
/// the writer reuses the calling task's own token (commit and the SIWC entry
/// points), never a token another task holds, and never while admission is
/// closed. `cmd-token-child` (isolated child, real `ConversationManager`
/// with the daemon's settings-owner wiring, the Bot API answered in
/// process): the Telegram commands end to end.
extension SIWCSelftest {
    static let commandTokenLinkName = "briglia-mw-siwct"

    final class Outcome<T>: @unchecked Sendable { var value: T?; var done = false }

    /// Runs `op` in a NEW task and waits up to `seconds` for it. nil = it did
    /// not finish (a hang; the task is left suspended).
    @MainActor
    static func finishes<T>(within seconds: Double, _ op: @escaping @MainActor () async -> T) async -> T? {
        let box = Outcome<T>()
        Task { @MainActor in box.value = await op(); box.done = true }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !box.done, ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return box.done ? box.value : nil
    }

    // MARK: In process

    @MainActor
    static func commandTokenTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        let gate = writer.gate
        let savedOwner = SettingsClient.inProcessOwner, savedWriter = SettingsClient.inProcessWriter
        // The daemon's wiring (startSettingsOwner).
        SettingsClient.inProcessOwner = { change, stillValid in await writer.commit(change, stillValid: stillValid) }
        SettingsClient.inProcessWriter = writer
        defer { SettingsClient.inProcessOwner = savedOwner; SettingsClient.inProcessWriter = savedWriter }

        // T1. Same-task reentry is refused at once (no hang); the outer token stays held.
        let t1 = await finishes(within: 5) { () -> (Bool, Bool, Bool) in
            guard let outer = await gate.acquire() else { return (false, false, false) }
            let inner = await gate.acquire()
            let stillHeld = gate.tokenHeldByCurrentTask == outer
            gate.release(outer)
            return (true, inner == nil, stillHeld)
        }
        c.check("cmd-token T1: a task asking again for the token it holds is refused at once, never waits on itself",
                t1?.0 == true && t1?.1 == true && t1?.2 == true && gate.reentryRefusals == 1 && !gate.isHeld, "\(String(describing: t1))")

        // T2. A task SPAWNED by the holder (inherits task-locals, not the
        // token) waits its turn: not refused, not reused, gets the token after release.
        let t2 = await finishes(within: 5) { () -> (Bool, Bool, Bool) in
            guard let outer = await gate.acquire() else { return (false, false, false) }
            let child = Task { @MainActor () -> Bool in
                guard let t = await gate.acquire() else { return false }
                gate.release(t); return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            let queued = gate.queued == 1
            gate.release(outer)
            return (queued, await child.value, true)
        }
        c.check("cmd-token T2: a task spawned while the token is held queues behind it (not refused, not reused)",
                t2?.0 == true && t2?.1 == true && gate.reentryRefusals == 1 && !gate.isHeld, "\(String(describing: t2))")

        // T3. The real chain the Telegram command uses (SIWCSurface.setOptIn →
        // SettingsClient.commit → in-process owner → writer.commit) inside the
        // holding task: applied under that token, which stays held.
        let t3 = await finishes(within: 5) { () -> (SettingsCommitResult.State, Bool, Bool) in
            guard let outer = await gate.acquire() else { return (.error, false, false) }
            gate.enterDurablePhase(outer)
            let r = await SIWCSurface.setOptIn(true, origin: "selftest")
            let held = gate.tokenHeldByCurrentTask == outer
            let saved = SIWCSurface.optedIn(KeychainHelper.loadSnapshot())
            gate.release(outer)
            return (r.state, held, saved)
        }
        c.check("cmd-token T3: a commit from the task holding the token runs under it (applied, token still held, no hang)",
                t3?.0 == .applied && t3?.1 == true && t3?.2 == true && !gate.isHeld, "\(String(describing: t3))")

        // T4. The same commit from ANOTHER task while the token is held waits
        // for the release (the writer reuses only the caller's own token).
        let holder = Outcome<SettingsCommitGate.Token>()
        let release = Outcome<Bool>()
        Task { @MainActor in
            holder.value = await gate.acquire(); holder.done = true
            while release.value != true { try? await Task.sleep(nanoseconds: 10_000_000) }
            if let t = holder.value { gate.release(t) }
        }
        while !holder.done { try? await Task.sleep(nanoseconds: 5_000_000) }
        let other = Outcome<SettingsCommitResult>()
        Task { @MainActor in other.value = await SIWCSurface.setOptIn(false, origin: "selftest"); other.done = true }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let waitedWhileHeld = !other.done && gate.queued == 1
        release.value = true
        let deadline4 = ProcessInfo.processInfo.systemUptime + 5
        while !other.done, ProcessInfo.processInfo.systemUptime < deadline4 { try? await Task.sleep(nanoseconds: 10_000_000) }
        c.check("cmd-token T4: a commit from another task waits for the holder, then applies",
                waitedWhileHeld && other.done && other.value?.state == .applied && !gate.isHeld,
                "waited \(waitedWhileHeld) done \(other.done) \(String(describing: other.value?.state))")

        // T5. The SIWC writer entry points (cancel, sign-out) inside the
        // holding task answer at once and leave the token to its owner.
        let store = SIWCStore.resolved()
        let t5 = await finishes(within: 5) { () -> (SettingsCommitResult.State, Bool, Bool) in
            guard let outer = await gate.acquire() else { return (.error, false, false) }
            gate.enterDurablePhase(outer)
            let cancel = await writer.commitSIWCCancel(store: store)
            let afterCancel = gate.tokenHeldByCurrentTask == outer
            let logout = await writer.commitSIWCLogout(store: store, revoke: { _ in true })
            let afterLogout = gate.tokenHeldByCurrentTask == outer
            gate.release(outer)
            if case .refused = logout { return (cancel.state, afterCancel, afterLogout) }
            return (cancel.state, afterCancel, false)
        }
        c.check("cmd-token T5: SIWC cancel and sign-out from the holding task answer at once (nothing to cancel / not signed in), token kept",
                t5?.0 == .applied && t5?.1 == true && t5?.2 == true && !gate.isHeld, "\(String(describing: t5))")

        // T6. Admission closed (a lifecycle operation): no reuse; the nested
        // commit is refused exactly as before, nothing written.
        try KeychainHelper.save(key: SIWCSurface.optInKey, value: "1")
        let t6 = await finishes(within: 5) { () -> (SettingsCommitResult.State, Bool) in
            guard let outer = await gate.acquire() else { return (.error, false) }
            gate.closeAdmission(reason: "selftest lifecycle")
            let r = await SIWCSurface.setOptIn(false, origin: "selftest")
            let unchanged = SIWCSurface.optedIn(KeychainHelper.loadSnapshot())
            gate.release(outer)
            gate.reopenAdmission()
            return (r.state, unchanged)
        }
        c.check("cmd-token T6: with admission closed the holder's nested commit is refused (no reuse), nothing written",
                t6?.0 == .refused && t6?.1 == true && !gate.isHeld, "\(String(describing: t6))")
        try? KeychainHelper.delete(key: SIWCSurface.optInKey)

        // T7. A command that had to WAIT for the token (handed over by the
        // previous holder) owns it too: its nested commit runs under it.
        let first = Outcome<Bool>()
        Task { @MainActor in
            guard let t = await gate.acquire() else { first.done = true; return }
            first.value = true
            try? await Task.sleep(nanoseconds: 150_000_000)
            gate.release(t); first.done = true
        }
        while first.value == nil, !first.done { try? await Task.sleep(nanoseconds: 5_000_000) }
        let t7 = await finishes(within: 5) { () -> (Bool, SettingsCommitResult.State, Bool) in
            guard let mine = await gate.acquire() else { return (false, .error, false) }   // queued behind `first`
            let r = await SIWCSurface.setOptIn(true, origin: "selftest")
            let held = gate.tokenHeldByCurrentTask == mine
            gate.release(mine)
            return (true, r.state, held)
        }
        c.check("cmd-token T7: a writer handed the token after waiting owns it (its nested commit runs under it)",
                first.value == true && t7?.0 == true && t7?.1 == .applied && t7?.2 == true && !gate.isHeld, "\(String(describing: t7))")
        try? KeychainHelper.delete(key: SIWCSurface.optInKey)

        // T8. The command child: the Telegram commands end to end.
        try await commandTokenChildRun(root, c)
    }

    // MARK: The isolated child (Telegram end to end)

    static func commandTokenChildRun(_ root: URL, _ c: Checks) async throws {
        let fm = FileManager.default
        let base = root.appendingPathComponent("ct-\(UUID().uuidString.prefix(6))")
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
        env.removeValue(forKey: "BRIGLIA_CHATGPT_ROUTE")
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = base.appendingPathComponent(commandTokenLinkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__siwc-selftest", "--command-token-child"]
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        TestPrefsDomains.purge(commandTokenLinkName)
        var rows = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) {
            if line.hasPrefix("✔ ") { c.check(String(line.dropFirst(2)), true); rows += 1 }
            else if line.hasPrefix("✖ ") { c.check(String(line.dropFirst(2)), false); rows += 1 }
        }
        c.check("cmd-token child: ran every row and exited cleanly", rows >= 10 && process.terminationStatus == 0,
                "rows \(rows) status \(process.terminationStatus)")
    }

    /// Inside the isolated roots. Ends with `exit` so a hung command task
    /// (the old deadlock) can never keep the child alive.
    @MainActor
    static func commandTokenChild() async throws {
        let c = Checks()
        let offline = SIWCError(.local, "selftest: network disabled")
        SIWCAuthClient.sendOverride = { _, _ in throw offline }
        SIWCModels.fetchOverride = { _ in throw offline }
        ResponsesAdapter.siwcSendOverride = { _ in throw offline }
        try StoragePaths.ensureRootsChecked()
        try resetLive()
        let token = "424244:AAsyntheticSIWCCommandTokenxxxxxx", chat = 424244
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
        // The daemon's settings owner: the in-process owner and writer are
        // THIS manager's writer (what 0.2.69 deadlocked on).
        manager.startSettingsOwner()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let gate = manager.settingsWriter.gate
        c.check("child: the in-process owner is this manager's writer (daemon wiring)",
                SettingsClient.inProcessWriter === manager.settingsWriter && SettingsClient.inProcessOwner != nil)
        // The flow keeps its LIVE writer access and activation commit; only
        // the OpenAI exchange is answered in process.
        let fake = FakeAuth()
        SIWCFlow.shared.resetForTests()
        SIWCFlow.shared.startListener = false; SIWCFlow.shared.pollNanos = 20_000_000
        SIWCFlow.shared.makeSignIn = { SIWCSignIn(store: SIWCStore.resolved(), auth: fake.client, hostPaths: .live, ownerLease: { nil }) }
        SIWCFlow.shared.exchange = { _, attempt, _, clientId in
            SIWCSignInResult(clientId: clientId, newRegistration: attempt.newRegistration, tokens: tokens("cmdtoken"), claims: claims(sub: "sub-cmdtoken"))
        }
        func sent() -> [String] { log.all.filter { $0.0 == "sendMessage" }.compactMap { $0.1["text"] as? String } }
        func update(_ id: Int, _ text: String) -> TelegramUpdate {
            let message: [String: Any] = ["message_id": id, "date": 1_790_000_000, "text": text,
                                          "chat": ["id": chat, "type": "private", "first_name": "Owner"],
                                          "from": ["id": chat, "is_bot": false, "first_name": "Owner"]]
            return try! JSONDecoder().decode(TelegramUpdate.self, from: JSONSerialization.data(withJSONObject: ["update_id": id, "message": message]))
        }
        func waitFor(_ seconds: Double = 6, _ condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            return condition()
        }
        /// Send a command; wait for a NEW message matching `reply` and for the gate to be free.
        func command(_ id: Int, _ text: String, seconds: Double = 6, _ reply: @escaping (String) -> Bool) async -> (replied: Bool, released: Bool, text: String) {
            let before = sent().count
            await manager._testProcessUpdate(update(id, text))
            let replied = await waitFor(seconds) { sent().dropFirst(before).contains(where: reply) }
            let released = await waitFor(2) { !gate.isHeld }
            return (replied, released, sent().dropFirst(before).joined(separator: " | "))
        }

        // 1. /subscription login official: the link goes out, the opt-in is saved, the token comes back.
        let login = await command(201, "/subscription login official") { $0.contains(SIWCEndpoint.authorizeURL) }
        c.check("telegram: /subscription login official sends the sign-in link (0.2.69 waited on its own token forever)",
                login.replied && SIWCFlow.shared.isWaiting, login.text)
        c.check("telegram: after the login command the settings token is free and the preview opt-in is saved",
                login.released && SIWCSurface.optedIn(KeychainHelper.loadSnapshot()))

        // 2. The paste signs in through the live writer (save + activation).
        let pasted = await command(202, callbackURL(SIWCFlow.shared.status, code: "CT-GOOD-CODE")) { $0.hasPrefix("Signed in.") }
        c.check("telegram: the pasted address signs in through the daemon's own writer; the token is free afterwards",
                pasted.replied && pasted.released && KeychainHelper.loadSnapshot()[ChatGPTRoute.routeKey] == "siwc", pasted.text)

        // 3. /subscription use official: the activation commit runs under the command's token.
        let use = await command(203, "/subscription use official") { $0.hasPrefix("Briglia now uses") || $0.hasPrefix("Saved.") || $0.hasPrefix("Not switched") }
        c.check("telegram: /subscription use official answers (activation under the command's token, no hang)",
                use.replied && use.released && use.text.contains("Briglia now uses"), use.text)

        // 4. /subscription logout official: the sign-out runs under the command's token.
        let logout = await command(204, "/subscription logout official", seconds: 15) { $0.hasPrefix("Signed out") || $0.contains("Nothing changed") || $0.contains("not saved") }
        c.check("telegram: /subscription logout official signs out (no hang), the token is free afterwards",
                logout.replied && logout.released && logout.text.hasPrefix("Signed out"), logout.text)

        // 5. /subscription cancel official on a new waiting sign-in.
        let relogin = await command(205, "/subscription login official") { $0.contains(SIWCEndpoint.authorizeURL) }
        let cancel = await command(206, "/subscription cancel official") { $0.contains("cancelled") }
        c.check("telegram: a new login, then /subscription cancel official answers (cancel under the command's token)",
                relogin.replied && cancel.replied && cancel.released && !SIWCFlow.shared.isWaiting, relogin.text + " || " + cancel.text)

        // 6. /subscription failed on a waiting sign-in.
        let third = await command(207, "/subscription login official") { $0.contains(SIWCEndpoint.authorizeURL) }
        let failed = await command(208, "/subscription failed") { $0 == SIWCFlow.browserFailedHelp }
        c.check("telegram: /subscription failed answers with the generic help (no hang)",
                third.replied && failed.replied && failed.released && !SIWCFlow.shared.isWaiting, failed.text)

        // 7. The terminal chat (captured command, token acquired inline): the same commands.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let termLogin = await finishes(within: 6) { await manager.handleTerminalCommand("/subscription login official") }
        let termCancel = await finishes(within: 6) { await manager.handleTerminalCommand("/subscription cancel official") }
        c.check("terminal: /subscription login official and cancel official answer (inline token path)",
                (termLogin??.joined() ?? "").contains("http") && (termCancel??.joined() ?? "").contains("cancelled") && !gate.isHeld,
                "\(String(describing: termLogin)) \(String(describing: termCancel))")

        // 8. Nothing stayed stuck: another settings command still answers,
        // and the safety net never had to refuse a reentry.
        let method = await command(209, "/subscription method") { $0.hasPrefix("ChatGPT sign-in methods") }
        c.check("telegram: a later settings command still answers (nothing left holding the token)", method.replied && method.released, method.text)
        c.check("gate: the fix path ran (writes reused the command's token); no reentrant acquire had to be refused",
                gate.reentryRefusals == 0, "refusals \(gate.reentryRefusals)")

        TelegramBotService.transportOverrideForTesting = nil
        print("SIWC command-token child: \(c.total - c.failed)/\(c.total)")
        fflush(stdout)
        #if canImport(Glibc)
        Glibc.exit(c.failed > 0 ? 1 : 0)
        #else
        Darwin.exit(c.failed > 0 ? 1 : 0)
        #endif
    }
}
