import Foundation

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
            await service.stopBackgroundPoll()
            try KeychainHelper.delete(key: KeychainHelper.agentMailApiKeyKey)
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "none")
        } catch { check("email: fixture ran", false, error.localizedDescription) }
    }
}
