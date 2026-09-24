import Foundation

/// A thread-safe counter for callbacks off the main actor.
final class MenuCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ k: Int) { lock.lock(); n += k; lock.unlock() }
    func reset() { lock.lock(); n = 0; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Live-hub integration rows (Codex round 2 on 61db419): stale settings,
/// ChatGPT sign-in against the real auth store and the real manager's
/// settings barrier, and email pollers following a live settings change.
@MainActor
extension MenuSelftestContext {

    // MARK: Stale settings (fake persistence)

    func staleSettings() async {
        func liveWorkflow(_ w: MenuFakeWorld) async -> MenuWorkflow {
            var e = env(w)
            e.live = MenuLive(mode: "terminal", stop: {})
            let m = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
            m.now = { w.clock }
            await m.start(); await m.settle()
            return m
        }
        func opencodeWorld() -> MenuFakeWorld {
            let w = world()
            w.snap.activeProfile = "opencode"
            w.snap.otherProvider = "OpenCode Go"
            w.snap.providers["opencode"] = MenuSnapshot.Provider(configured: true, model: "glm-5.3-flash", effort: "high", keyMasked: "oc-g…cdef")
            w.snap.providers["openrouter"] = MenuSnapshot.Provider(configured: true, model: "z-ai/glm-5.3-flash", effort: "high", keyMasked: "sk-o…cdef")
            return w
        }
        func aiModel(_ m: MenuWorkflow, _ profile: String) -> String? {
            ((m.status()["ai"] as? [String: Any])?["providers"] as? [String: [String: Any]])?[profile]?["model"] as? String
        }

        do {
            // Codex's reproduction: an idle /model while the page is open.
            let w = opencodeWorld()
            let m = await liveWorkflow(w)
            w.snap.providers["opencode"]?.model = "kimi-k3"
            _ = m.status()           // the poll starts a re-read…
            await m.settle()
            check("live: the open page picks up a /model sent on Telegram", aiModel(m, "opencode") == "kimi-k3", "shown \(aiModel(m, "opencode") ?? "nil")")
            let r = await act(m, ["action": "effort", "effort": "low"])
            let p = w.snap.providers["opencode"]
            check("live: effort after the refresh keeps the model chosen on Telegram", ok(r) && p?.model == "kimi-k3" && p?.effort == "low",
                  "model \(p?.model ?? "nil") effort \(p?.effort ?? "nil")")
            await m.shutdown()
        }
        do {
            // The same change landing between two polls: the write is refused.
            let w = opencodeWorld()
            let m = await liveWorkflow(w)
            let writes = w.applied.count
            w.snap.providers["opencode"]?.model = "kimi-k3"
            let r = await act(m, ["action": "effort", "effort": "low"])
            check("live: effort based on a stale page writes nothing and says why",
                  !ok(r) && msg(r) == m.staleMessage && w.applied.count == writes && w.snap.providers["opencode"]?.model == "kimi-k3"
                  && w.snap.providers["opencode"]?.effort == "high", msg(r))
            check("live: the refused page now shows the current model", aiModel(m, "opencode") == "kimi-k3")
            let again = await act(m, ["action": "effort", "effort": "low"])
            check("live: the retried effort goes through on the current model", ok(again) && w.snap.providers["opencode"]?.model == "kimi-k3" && w.snap.providers["opencode"]?.effort == "low")
            await m.shutdown()
        }
        do {
            // /provider on Telegram while the page's model check is waiting.
            let w = opencodeWorld()
            let m = await liveWorkflow(w)
            let gate = MenuGate(); w.holds[w.good["opencode"]!] = gate
            let writes = w.applied.count
            let t = Task { await m.handle(["action": "provider_model", "profile": "opencode", "model": "kimi-k3"]) }
            while !gate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
            w.snap.activeProfile = "openrouter"; w.snap.otherProvider = "OpenRouter"
            gate.open()
            let r = await t.value ?? [:]
            await m.settle()
            check("live: a provider switched on Telegram during a model check isn't switched back",
                  !ok(r) && msg(r) == m.staleMessage && w.applied.count == writes && w.snap.activeProfile == "openrouter"
                  && w.snap.providers["opencode"]?.model == "glm-5.3-flash", msg(r))
            await m.shutdown()
        }
        do {
            // ChatGPT lane: /model changed the subscription model.
            let w = world()
            w.snap.chatgpt = .signedIn(active: true, model: "gpt-6-sol", effort: "high", generation: "g0")
            w.snap.activeProfile = "chatgpt"
            let m = await liveWorkflow(w)
            w.snap.chatgpt = .signedIn(active: true, model: "gpt-6-luna", effort: "high", generation: "g0")
            let r = await act(m, ["action": "effort", "effort": "medium"])
            check("live: ChatGPT effort on a stale page keeps the model chosen on Telegram",
                  !ok(r) && msg(r) == m.staleMessage && w.snap.chatgpt == .signedIn(active: true, model: "gpt-6-luna", effort: "high", generation: "g0"), msg(r))
            let use = await act(m, ["action": "provider_use", "profile": "opencode"])
            check("live: nothing else is refused once the page is current", !ok(use) && !msg(use).contains("changed elsewhere"), msg(use))
            await m.shutdown()
        }
        do {
            // A save racing a refresh: the late, older read doesn't win.
            let w = opencodeWorld()
            let m = await liveWorkflow(w)
            check("live: the settings re-read is throttled", MenuWorkflow.liveRefreshInterval >= 1)
            await m.shutdown()
        }
    }

    // MARK: ChatGPT sign-in against the real auth store and barrier

    func liveSignIn() async {
        let store = SubscriptionAuthStore()
        let savedWait = MenuWorkflow.signInCommitWait
        MenuWorkflow.signInCommitWait = 1.5
        defer { MenuWorkflow.signInCommitWait = savedWait }
        let manager = ConversationManager()
        // No email provider: a fresh manager would otherwise start the
        // machine's own one on its first reload.
        try? KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "none")

        /// Resets the store, then seeds an old ChatGPT login (active or not,
        /// usable or needing a new sign-in). Returns its generation.
        func seed(active: Bool, usable: Bool) async throws -> String {
            try? await store.logout()
            let pending = try await store.beginLogin()
            let old = try await store.commitLogin(SubscriptionSelftest.credential(), pending: pending)
            try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: "gpt-6-sol", effort: "high", textOnly: false)
            if active {
                try ProviderProfiles.activate(.chatgpt)
            } else {
                try ProviderProfiles.saveProfile(.local, apiKey: nil, baseURL: "http://127.0.0.1:1/v1", model: "local-model", effort: nil, textOnly: false)
                try ProviderProfiles.activate(.local)
            }
            if !usable { try await store.requireLogin(generation: old, rejectedAccess: SubscriptionSelftest.credential().access) }
            return old
        }
        var tokenCalls = 0
        func liveWorkflow(_ gate: MenuGate) -> MenuWorkflow {
            let w = world()
            var e = env(w)
            e.live = MenuLive(mode: "terminal", stop: {})
            MenuHost.wireLive(&e, manager: manager)
            e.snapshot = { await MenuEnvironment.liveSnapshot() }
            // The one-request check would reach ChatGPT: answered here.
            let real = e.subscription
            e.subscription = { req, cp in
                req["action"] as? String == "probe" ? ["ok": true, "state": "verified"] : await real(req, cp)
            }
            e.deviceLogin = { show, commit in
                var login = SubscriptionLogin(store: store)
                login.commitHook = commit
                login.post = { path, _, _ in
                    if path.hasSuffix("usercode") { return (Data(#"{"device_auth_id":"fixture","user_code":"CODE","interval":1}"#.utf8), 200) }
                    if path.hasSuffix("deviceauth/token") { return (Data(#"{"authorization_code":"code","code_verifier":"verifier"}"#.utf8), 200) }
                    tokenCalls += 1
                    await gate.wait()
                    return (try SubscriptionSelftest.tokenData(), 200)
                }
                _ = try await login.device { show($0, $1) }
            }
            return MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
        }
        func runtimeGeneration() -> String? { KeychainHelper.load(key: KeychainHelper.openAICompatibleApiKeyKey) }
        func loginState(_ m: MenuWorkflow) -> [String: Any]? { (m.status()["chatgpt"] as? [String: Any])?["login"] as? [String: Any] }
        func waitArrived(_ gate: MenuGate) async -> Bool {
            for _ in 0..<600 { if gate.hasArrived { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
            return false
        }

        do {
            do {
                // 1. Working active login: refused before anything is written.
                let old = try await seed(active: true, usable: true)
                let gate = MenuGate(); gate.open()
                let m = liveWorkflow(gate)
                await m.start(); await m.settle()
                let calls = tokenCalls
                let r = await act(m, ["action": "chatgpt_code"])
                let state = try store.read()
                check("sign-in: a working active ChatGPT login can't be replaced from the menu",
                      !ok(r) && msg(r) == m.loginBlockMessage(.activeLogin) && state?.generation == old && state?.pendingLogin == nil
                      && tokenCalls == calls && runtimeGeneration() == old, msg(r))
                await m.shutdown()
            }
            do {
                // 2. A turn runs across the whole commit wait: nothing written.
                let old = try await seed(active: true, usable: false)
                let gate = MenuGate()
                let m = liveWorkflow(gate)
                await m.start(); await m.settle()
                let r = await act(m, ["action": "chatgpt_code"], settle: false)
                _ = await waitArrived(gate)
                manager._testSetTriageLane("menu-round2-busy", inFlight: true)
                gate.open(); await m.settle()
                manager._testSetTriageLane("menu-round2-busy", inFlight: false)
                let state = try store.read()
                check("sign-in: an agent busy for the whole wait keeps the old login and runtime",
                      ok(r) && state?.generation == old && state?.pendingLogin == nil && state?.requiresLogin == true && runtimeGeneration() == old,
                      "store \(state?.generation ?? "nil") runtime \(runtimeGeneration() ?? "nil")")
                check("sign-in: the page says the new sign-in wasn't saved because Briglia was busy",
                      loginState(m)?["state"] as? String == "error" && (loginState(m)?["message"] as? String) == m.signInRefusedMessage(.busy))
                await m.shutdown()
            }
            do {
                // 3. A turn that ends during the wait: committed and switched together.
                let old = try await seed(active: true, usable: false)
                let gate = MenuGate()
                let m = liveWorkflow(gate)
                await m.start(); await m.settle()
                _ = await act(m, ["action": "chatgpt_code"], settle: false)
                _ = await waitArrived(gate)
                manager._testSetTriageLane("menu-round2-turn", inFlight: true)
                gate.open()
                try? await Task.sleep(nanoseconds: 600_000_000)
                let midway = try store.read()?.generation
                manager._testSetTriageLane("menu-round2-turn", inFlight: false)
                await m.settle()
                let state = try store.read()
                check("sign-in: nothing is written while the turn still runs", midway == old)
                check("sign-in: once idle, the new login and Briglia's switch to it land together",
                      state?.generation != old && state?.credential != nil && runtimeGeneration() == state?.generation
                      && ProviderProfiles.activeProfile() == .chatgpt && loginState(m) == nil,
                      "store \(state?.generation ?? "nil") runtime \(runtimeGeneration() ?? "nil")")
                await m.shutdown()
            }
            do {
                // 4. A newer AI choice while ChatGPT is still waiting.
                let old = try await seed(active: false, usable: true)
                let gate = MenuGate()
                let m = liveWorkflow(gate)
                await m.start(); await m.settle()
                _ = await act(m, ["action": "chatgpt_code"], settle: false)
                _ = await waitArrived(gate)
                _ = await act(m, ["action": "lane", "lane": "openrouter"], settle: false)
                gate.open(); await m.settle()
                let state = try store.read()
                check("sign-in: a newer AI choice voids the sign-in, no credential written",
                      state?.generation == old && state?.pendingLogin == nil && ProviderProfiles.activeProfile() == .local && loginState(m) == nil)
                await m.shutdown()
            }
            do {
                // 5. Link rotation / Close while waiting.
                let old = try await seed(active: false, usable: true)
                let gate = MenuGate()
                let m = liveWorkflow(gate)
                await m.start(); await m.settle()
                _ = await act(m, ["action": "chatgpt_code"], settle: false)
                _ = await waitArrived(gate)
                let revoking = Task { await m.revoke() }
                try? await Task.sleep(nanoseconds: 50_000_000)
                gate.open()
                await revoking.value
                let state = try store.read()
                check("sign-in: a revoked link writes no credential", state?.generation == old && state?.pendingLogin == nil && ProviderProfiles.activeProfile() == .local, "gen \(state?.generation == old) pending \(state?.pendingLogin ?? "nil") active \(ProviderProfiles.activeProfile()?.rawValue ?? "nil")")
                await m.shutdown()
            }
            do {
                // 6. /provider chatgpt with a working login lands during the wait.
                try? await store.logout()
                try ProviderProfiles.saveProfile(.local, apiKey: nil, baseURL: "http://127.0.0.1:1/v1", model: "local-model", effort: nil, textOnly: false)
                try ProviderProfiles.activate(.local)
                let gate = MenuGate()
                let m = liveWorkflow(gate)
                await m.start(); await m.settle()
                _ = await act(m, ["action": "chatgpt_code"], settle: false)
                _ = await waitArrived(gate)
                // Another surface signs in and activates while the menu waits;
                // the menu's pending sign-in id is put back, as a racing writer
                // that doesn't know about it would leave it.
                let menuPending = try store.read()?.pendingLogin
                let other = try await store.locked { () throws -> String in
                    var s = try store.read()!
                    s.credential = SubscriptionSelftest.credential("other-access")
                    s.generation = UUID().uuidString
                    s.pendingLogin = nil; s.deviceChallenge = nil
                    try store.write(s)
                    return s.generation
                }
                try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: "gpt-6-sol", effort: "high", textOnly: false)
                _ = await SubscriptionSetup().perform(["action": "select", "model": "gpt-6-sol", "effort": "high"], ownsLease: true)
                let runtime = runtimeGeneration()
                try await store.locked { var s = try store.read()!; s.pendingLogin = menuPending; try store.write(s) }
                gate.open(); await m.settle()
                let state = try store.read()
                check("sign-in: a working login activated elsewhere during the wait isn't replaced",
                      state?.generation == other && state?.credential?.access == "other-access" && runtimeGeneration() == runtime && runtime == other,
                      "store \(state?.generation ?? "nil") runtime \(runtimeGeneration() ?? "nil")")
                await m.shutdown()
            }
            do {
                // 7. Control: idle agent, nothing to replace.
                try? await store.logout()
                try ProviderProfiles.saveProfile(.local, apiKey: nil, baseURL: "http://127.0.0.1:1/v1", model: "local-model", effort: nil, textOnly: false)
                try ProviderProfiles.activate(.local)
                let gate = MenuGate(); gate.open()
                let m = liveWorkflow(gate)
                await m.start(); await m.settle()
                let r = await act(m, ["action": "chatgpt_code"])
                let state = try store.read()
                check("sign-in: an idle sign-in saves, switches and verifies",
                      ok(r) && state?.credential != nil && state?.pendingLogin == nil && runtimeGeneration() == state?.generation
                      && ProviderProfiles.activeProfile() == .chatgpt && loginState(m) == nil)
                let blocked = await act(m, ["action": "chatgpt_code"])
                check("sign-in: signing in again now asks to sign out first", !ok(blocked) && msg(blocked) == m.loginBlockMessage(.activeLogin))
                await m.shutdown()
            }
            do {
                // Codex round 3: the commit passed the menu check but waits
                // for the auth-store lock (a token refresh elsewhere); a newer
                // choice lands meanwhile. The store re-checks the ticket under
                // its lock, so the saved login stays the old one.
                let old = try await seed(active: false, usable: true)
                let tokenGate = MenuGate()
                let m = liveWorkflow(tokenGate)
                await m.start(); await m.settle()
                _ = await act(m, ["action": "chatgpt_code"], settle: false)
                _ = await waitArrived(tokenGate)
                let lockGate = MenuGate()
                let holder = Task { try await store.locked { await lockGate.wait() } }
                while !lockGate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
                tokenGate.open()
                for _ in 0..<400 {
                    if manager.isRestoringMind { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                check("sign-in: the commit reached the live barrier while the auth lock was held", manager.isRestoringMind)
                try? await Task.sleep(nanoseconds: 100_000_000)
                _ = await act(m, ["action": "lane", "lane": "openrouter"], settle: false)
                lockGate.open(); try await holder.value
                await m.settle()
                let state = try store.read()
                check("sign-in: a sign-in superseded while waiting for the auth lock saves no credential", state?.generation == old,
                      "generation changed=\(state?.generation != old), provider=\(ProviderProfiles.activeProfile()?.rawValue ?? "nil")")
                check("sign-in: …and leaves no pending login behind", state?.pendingLogin == nil)
                check("sign-in: …and Briglia isn't switched to ChatGPT", ProviderProfiles.activeProfile() != .chatgpt)
                await m.shutdown()
            }
            do {
                // Positive control for the same path: the lock is held, then
                // released with nothing newer chosen — the login is saved.
                let old = try await seed(active: false, usable: true)
                let tokenGate = MenuGate()
                let m = liveWorkflow(tokenGate)
                await m.start(); await m.settle()
                _ = await act(m, ["action": "chatgpt_code"], settle: false)
                _ = await waitArrived(tokenGate)
                let lockGate = MenuGate()
                let holder = Task { try await store.locked { await lockGate.wait() } }
                while !lockGate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
                tokenGate.open()
                try? await Task.sleep(nanoseconds: 150_000_000)
                lockGate.open(); try await holder.value
                await m.settle()
                let state = try store.read()
                check("sign-in: after waiting for the auth lock, a still-current sign-in is saved", state?.generation != nil && state?.generation != old)
                await m.shutdown()
            }
        } catch {
            check("sign-in: real auth fixture ran", false, error.localizedDescription)
        }
        try? await store.logout()
    }

    // MARK: Email pollers follow a live change

    func liveEmail() async {
        do {
            let service = AgentMailService.shared
            _ = await service.resetForWipe()
            let manager = ConversationManager()
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "none")
            await manager.reloadBrowserSettings()     // the state this process runs with
            try KeychainHelper.save(key: KeychainHelper.agentMailApiKeyKey, value: "synthetic-menu-review-key")
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "agentmail")
            var before = await service.currentGenerationForTesting()
            await manager.reloadBrowserSettings()
            check("email: turning AgentMail on starts its checker", await service.currentGenerationForTesting() > before)
            before = await service.currentGenerationForTesting()
            await manager.reloadBrowserSettings()
            check("email: a save that didn't touch email leaves the checker alone", await service.currentGenerationForTesting() == before)
            // Account replacement: the old account's checkpoint (an hour-old
            // position, still fresh enough to be restored) must not carry over.
            let checkpoint = AgentMailService.pollStateURLForTesting
            check("email: the running checker has a saved position", FileManager.default.fileExists(atPath: checkpoint.path))
            func writeOldPosition() throws {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let hourAgo = Date().addingTimeInterval(-3600)
                try PrivateStorage.writeAtomically(try encoder.encode(AgentMailService.PollState(watermark: hourAgo, drains: [:], savedAt: hourAgo)), to: checkpoint)
            }
            func savedWatermark() -> Date? {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                return (try? Data(contentsOf: checkpoint)).flatMap { try? decoder.decode(AgentMailService.PollState.self, from: $0) }?.watermark
            }
            try writeOldPosition()
            try KeychainHelper.save(key: KeychainHelper.agentMailApiKeyKey, value: "synthetic-menu-review-key-2")
            before = await service.currentGenerationForTesting()
            await manager.reloadBrowserSettings()
            let restarted = await service.currentGenerationForTesting() > before
            check("email: a new AgentMail key restarts the checker without the old account's position",
                  restarted && (savedWatermark().map { $0 > Date().addingTimeInterval(-60) } ?? false))
            before = await service.currentGenerationForTesting()
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "none")
            await manager.reloadBrowserSettings()
            let stoppedAt = await service.currentGenerationForTesting()
            check("email: turning email off stops the checker", stoppedAt > before)
            // gws before (as on an existing install), then AgentMail.
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "gws")
            await manager.reloadBrowserSettings()
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "agentmail")
            before = await service.currentGenerationForTesting()
            await manager.reloadBrowserSettings()
            check("email: switching from Google Workspace to AgentMail starts AgentMail", await service.currentGenerationForTesting() > before)

            // Codex round 3, R2: a Google check still running when the
            // provider changes. The transition doesn't wait it out; the
            // reset voids it, so its late result is dropped: nothing reaches
            // the agent, no watermark or cache is written, no retry starts.
            let gws = GoogleWorkspaceService.shared
            let delivered = MenuCount(), fetches = MenuCount()
            let sample = GoogleWorkspaceService.UnreadEmail(id: "m-late", threadId: nil, from: "a@example.com", subject: "late", date: "", snippet: "")
            func gwsSelected() async throws {
                try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "gws")
                await manager.reloadBrowserSettings()
                await gws.setNewEmailHandler { emails in delivered.add(emails.count); return true }
            }
            try await gwsSelected()
            await gws.setArrivalFetchForTesting { _ in fetches.add(1); return [sample] }
            await gws.pollOnceForTesting()
            check("email: control — a Google check that finishes normally is delivered", delivered.value == 1 && fetches.value == 1)
            for target in ["agentmail", "none"] {
                try await gwsSelected()
                delivered.reset(); fetches.reset()
                let gate = MenuGate()
                // "agentmail": the late fetch returns mail; "none": it fails,
                // which would normally start the retry ladder.
                let late = target == "agentmail"
                let fresh = GoogleWorkspaceService.UnreadEmail(id: "m-late-\(target)", threadId: nil, from: "a@example.com", subject: "late", date: "", snippet: "")
                await gws.setArrivalFetchForTesting { _ in fetches.add(1); await gate.wait(); return late ? [fresh] : nil }
                let tick = Task { await gws.pollOnceForTesting() }
                while !gate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
                let epoch = await gws.stateEpochForTesting()
                try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: target)
                let started = Date()
                let switching = Task { await manager.reloadBrowserSettings() }
                // Let the switch reach its wait for the old check (bounded:
                // without the epoch bump this would otherwise never change).
                for _ in 0..<200 where await gws.stateEpochForTesting() == epoch { try? await Task.sleep(nanoseconds: 5_000_000) }
                let voided = await gws.stateEpochForTesting() != epoch
                gate.open()
                await switching.value; await tick.value
                try? await Task.sleep(nanoseconds: 1_300_000_000)   // past the first retry delay
                check("email: Google → \(target) with a check still running: its result never reaches the agent",
                      voided && delivered.value == 0, "voided \(voided) delivered \(delivered.value)")
                let wm = await gws.arrivalWatermarkForTesting()
                check("email: Google → \(target): the late check writes no watermark and starts no retry",
                      wm == nil && fetches.value == 1, "fetches \(fetches.value)")
                let elapsed = Date().timeIntervalSince(started)
                let inFlight = await gws.opsInFlightForTesting()
                check("email: Google → \(target): the switch finishes once the old check returns (no 10 s stall)",
                      elapsed < 5 && inFlight == 0, "elapsed \(elapsed) in flight \(inFlight)")
                check("email: Google → \(target): the selected provider is applied", EmailCalendarProvider.current.rawValue == target)
            }
            await gws.setArrivalFetchForTesting(nil)
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "agentmail")
            await manager.reloadBrowserSettings()

            // Codex round 3, R3: the old account's checkpoint can't be
            // removed. It is account-stamped, so the new account never
            // adopts it — in this process or after a restart.
            func writePosition(account: String?) throws {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let hourAgo = Date().addingTimeInterval(-3600)
                try PrivateStorage.writeAtomically(try encoder.encode(AgentMailService.PollState(watermark: hourAgo, drains: [:], savedAt: hourAgo, account: account)), to: checkpoint)
            }
            func adoptedOld() async -> Bool { await service.watermarkForTesting().map { $0 < Date().addingTimeInterval(-1800) } ?? false }
            #if os(macOS)
            for (label, stamped) in [("an unstamped (pre-upgrade)", false), ("the old account's stamped", true)] {
                try writePosition(account: stamped ? AgentMailService.currentAccountFingerprint() : nil)
                let originalBytes = try Data(contentsOf: checkpoint)
                try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: checkpoint.path)
                do {
                    try KeychainHelper.save(key: KeychainHelper.agentMailApiKeyKey, value: "synthetic-menu-review-key-\(stamped ? 4 : 3)")
                    await manager.reloadBrowserSettings()
                    let adopted = await adoptedOld()
                    check("email: a new account never adopts \(label) checkpoint that couldn't be removed", !adopted,
                          "adopted \(adopted), file kept \((try? Data(contentsOf: checkpoint)) == originalBytes)")
                    // Restart: a fresh start of the poller, same stuck file.
                    await service.stopBackgroundPoll()
                    await service.startBackgroundPoll()
                    let adoptedAfterRestart = await adoptedOld()
                    check("email: …nor after a restart (\(label))", !adoptedAfterRestart)
                } catch {
                    try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: checkpoint.path)
                    throw error
                }
                try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: checkpoint.path)
            }
            #endif
            // Restart path on every platform: another account's stamped
            // checkpoint is ignored and replaced by this account's baseline;
            // this account's own checkpoint is still restored (control).
            await service.stopBackgroundPoll()
            try writePosition(account: AgentMailService.accountFingerprint(key: "another-account", inbox: ""))
            await service.startBackgroundPoll()
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let rewritten = (try? Data(contentsOf: checkpoint)).flatMap { try? decoder.decode(AgentMailService.PollState.self, from: $0) }
            let adoptedOther = await adoptedOld()
            check("email: at start, another account's checkpoint is ignored and replaced by this account's",
                  !adoptedOther && rewritten?.account == AgentMailService.currentAccountFingerprint())
            // An unstamped checkpoint that appears after an account change
            // in this process (writable, so the stamp would succeed) is
            // still never adopted: it can't be attributed to either account.
            await service.stopBackgroundPoll()
            try writePosition(account: nil)
            await service.startBackgroundPoll()
            let adoptedUnstamped = await adoptedOld()
            check("email: after an account change, an unstamped checkpoint is never adopted", !adoptedUnstamped)
            await service.stopBackgroundPoll()
            try writePosition(account: AgentMailService.currentAccountFingerprint())
            await service.startBackgroundPoll()
            let adoptedOwn = await adoptedOld()
            check("email: control — the same account's checkpoint is restored at start", adoptedOwn)
            await service.stopBackgroundPoll()
            try KeychainHelper.delete(key: KeychainHelper.agentMailApiKeyKey)
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "none")
        } catch { check("email: fixture ran", false, error.localizedDescription) }
    }
}
