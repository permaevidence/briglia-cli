import Foundation

extension SelftestContext {
    @MainActor
    func browserSettings() async throws {
        // This suite shares the isolated selftest process with other sections.
        // Restore its fixture credentials, never the real user's store.
        let storeURL = StoragePaths.configRoot.appendingPathComponent("secrets.json")
        func diskStore() -> [String: String] {
            guard let data = try? Data(contentsOf: storeURL) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        let original = diskStore()
        defer {
            var restore = Dictionary(uniqueKeysWithValues: diskStore().keys.map { ($0, String?.none) })
            for (key, value) in original { restore[key] = value }
            do { try KeychainHelper.saveBatch(restore) }
            catch { check("settings: restore isolated fixtures", false) }
        }
        let auth = try QuickSetupWorkflow(env: QuickSetupEnvironment(), runner: SetupJobRunner(secrets: [:]), resume: .fresh)
        let g = await auth.generation
        var env = BrowserSettingsWorkflow.Environment()
        var probes: [[String: Any]] = []
        env.probe = { probes.append($0); return ["ok": true] }
        var available = true, gates = 0, reloads = 0
        env.beginMutation = { if available { gates += 1 }; return available }
        env.endMutation = { gates -= 1 }
        env.reload = { reloads += 1 }
        let settings = BrowserSettingsWorkflow(auth: auth, env: env)
        // The real persistence and activation path runs under the real lease.
        let lease: InstanceLease
        switch InstanceLease.acquire(label: "settings selftest") {
        case .success(let l): lease = l
        case .failure(let e): throw e
        }
        defer { lease.release() }
        try KeychainHelper.save(key: SetupWizard.completeKey, value: "true")
        try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: "kept-bot")
        func req(_ model: String = "gpt-5.6-luna", key: String? = "test-api-key") -> [String: Any] {
            var v: [String: Any] = ["profile": "openai", "model": model, "effort": "high", "text_only": false, "activate": true]
            if let key { v["api_key"] = key }
            return ["section": "provider", "values": v]
        }
        let unverified = await settings.handle("save", body: req(), generation: g)
        check("settings: direct save without probe refused", unverified.0 == 409 && ProviderProfiles.activeProfile() == nil)
        let verified = await settings.handle("verify", body: req(), generation: g)
        check("settings: exact selected Responses model probed", verified.0 == 200 && probes.last?["kind"] as? String == "responses" && probes.last?["model"] as? String == "gpt-5.6-luna")
        let tampered = await settings.handle("save", body: req("gpt-5.6-sol"), generation: g)
        check("settings: edited model cannot reuse probe", tampered.0 == 409)
        available = false
        let busy = await settings.handle("save", body: req(), generation: g)
        check("settings: running work blocks save, keeps receipt", busy.0 == 409 && busy.1["error"] as? String == "agent_busy")
        let busyPoll = await settings.handle("subscription", body: ["action": "poll", "pending": "fixture"], generation: g)
        check("settings: real account poll reports agent_busy before auth transport", busyPoll.0 == 409 && busyPoll.1["error"] as? String == "agent_busy")
        available = true
        let saved = await settings.handle("save", body: req(), generation: g)
        check("settings: Responses save and activation work under owned lease", saved.0 == 200 && ProviderProfiles.activeProfile() == .openai && ProviderProfiles.configuredModel(.openai) == "gpt-5.6-luna")
        check("settings: live reload completes and gate released", reloads == 1 && gates == 0)
        check("settings: setup flag and Telegram pairing untouched", KeychainHelper.load(key: SetupWizard.completeKey) == "true" && KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) == "kept-bot")
        check("settings: single-use verification receipt", (await settings.handle("save", body: req(), generation: g)).0 == 409)
        _ = await settings.handle("verify", body: req("gpt-5.6-sol", key: nil), generation: g)
        try KeychainHelper.save(key: ProviderProfiles.openaiApiKeyKey, value: "externally-replaced-key")
        check("settings: kept key changed by another writer invalidates proof", (await settings.handle("save", body: req("gpt-5.6-sol", key: nil), generation: g)).0 == 409)
        _ = await settings.handle("verify", body: req("gpt-5.6-sol", key: nil), generation: g)
        let keptSaved = await settings.handle("save", body: req("gpt-5.6-sol", key: nil), generation: g)
        check("settings: model-only edit retains existing key", keptSaved.0 == 200 && BrowserSettingsWorkflow.key(.openai) == "externally-replaced-key")
        let status = settings.status()
        let text = String(data: try JSONSerialization.data(withJSONObject: status), encoding: .utf8)!
        check("settings: status includes all six providers but no keys", (status["profiles"] as? [[String: Any]])?.count == 6 && !text.contains("externally-replaced-key") && !text.contains("kept-bot"))
        let missingKey: [String: Any] = ["section": "provider", "values": ["profile": "custom", "model": "fixture", "base_url": "http://127.0.0.1:1234", "effort": "high"]]
        let missing = await settings.handle("verify", body: missingKey, generation: g)
        check("settings: missing key gives an actionable error", missing.0 == 400 && missing.1["message"] as? String == "Enter an API key.")
        var invalidEffort = missingKey["values"] as! [String: Any]
        invalidEffort["effort"] = "ultra"; invalidEffort["api_key"] = "fixture"
        check("settings: unsupported chat effort rejected", (await settings.handle("verify", body: ["section": "provider", "values": invalidEffort], generation: g)).0 == 400)
        // Fresh Quick Setup already holds its lease. Selecting a Responses
        // provider earlier in that session must not make a later apply reacquire it.
        check("settings: Responses runtime active for fresh-setup lease regression", ProviderProfiles.usesResponses)
        let priorComplete = KeychainHelper.load(key: SetupWizard.completeKey)
        try KeychainHelper.delete(key: SetupWizard.completeKey)
        let freshEnvironment = QuickSetupEnvironment()
        let freshRequest: [String: Any] = ["provider": ["profile": "opencode", "api_key": "fresh-fixture", "model": OpenCodeGo.defaultModel, "effort": "high", "activate": false]]
        let notOwner = await SetupAPICore.apply(freshRequest)
        check("settings: ordinary setup-api still refuses another owner's lease", notOwner["ok"] as? Bool == false)
        let freshApply = await freshEnvironment.apply(freshRequest, {})
        check("settings: fresh Quick Setup applies with Responses active and its own lease", freshApply["ok"] as? Bool == true && ProviderProfiles.configuredModel(.opencode) == OpenCodeGo.defaultModel && ProviderProfiles.activeProfile() == .openai && KeychainHelper.load(key: SetupWizard.completeKey) == nil)
        if let priorComplete { try KeychainHelper.save(key: SetupWizard.completeKey, value: priorComplete) }
        let tool: [String: Any] = ["section": "jina", "values": ["api_key": "new-jina"]]
        _ = await settings.handle("verify", body: tool, generation: g)
        check("settings: independent tool-key save", (await settings.handle("save", body: tool, generation: g)).0 == 200 && KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) == "new-jina" && ProviderProfiles.activeProfile() == .openai)
        var unknown = req(); unknown["mark_complete"] = true
        check("settings: arbitrary Setup API fields rejected", (await settings.handle("verify", body: unknown, generation: g)).0 == 400)
        var values = req()["values"] as! [String: Any]; values["activate"] = 1
        check("settings: numeric Boolean rejected", (await settings.handle("verify", body: ["section": "provider", "values": values], generation: g)).0 == 400)
        // Revocation while the real workflow awaits a probe must not produce
        // a usable receipt, and rotation must await the operation's unwind.
        var release: CheckedContinuation<Void, Never>?
        var entered = false
        settings.env.probe = { _ in entered = true; await withCheckedContinuation { release = $0 }; return ["ok": true] }
        let task = Task { await settings.handle("verify", body: req(), generation: g) }
        while !entered { await Task.yield() }
        let rotation = Task { await auth.rotate() }
        while await auth.generation == g { await Task.yield() }
        release?.resume()
        check("settings: revoked in-flight probe returns unauthorized", (await task.value).0 == 404)
        _ = await rotation.value
        let next = await auth.generation
        check("settings: new session cannot inherit old receipt", (await settings.handle("save", body: req(), generation: next)).0 == 409)
        try KeychainHelper.delete(key: KeychainHelper.jinaApiKeyKey)
        let manager = ConversationManager()
        manager._testSetTriageLane("test", inFlight: true)
        check("settings: real manager refuses active watcher triage", !(await manager.beginBrowserSettingsMutation()))
        manager._testSetTriageLane("test", inFlight: false)
        manager._testSetBrowserSettingsPollIngress(1)
        var gateGranted = false
        let pendingGate = Task { let ok = await manager.beginBrowserSettingsMutation(); gateGranted = ok; return ok }
        while !manager.isRestoringMind { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)
        check("settings: in-flight channel tick must exit before mutation", !gateGranted)
        manager._testSetBrowserSettingsPollIngress(0)
        check("settings: real idle manager grants gate after ingress drains", await pendingGate.value)
        check("settings: nested memory restore refused while saving", !manager.beginMindRestore())
        let commands = await manager.handleTerminalCommand("/model changed-mid-save")
        check("settings: commands cannot race live reload", commands?.joined().contains("Browser settings") == true)
        manager.endBrowserSettingsMutation()
        check("settings: gate released after save", !manager.isRestoringMind)
    }
}


extension SelftestContext {
    @MainActor
    func browserSettingsShutdown() async throws {
        let lease: InstanceLease
        switch InstanceLease.acquire(label: "settings shutdown fixture") {
        case .success(let value): lease = value
        case .failure(let error): throw error
        }
        let host: BrowserSettingsHost
        do { host = try BrowserSettingsHost(manager: nil, lease: lease) }
        catch { lease.release(); throw error }
        var entered = false, wrote = false
        var release: CheckedContinuation<Void, Never>?
        host.settings.env.probe = { _ in ["ok": true] }
        host.settings.env.apply = { _, checkpoint in
            entered = true
            await withCheckedContinuation { release = $0 }
            do { try checkpoint(); wrote = true; return ["ok": true] }
            catch { return ["ok": false] }
        }
        let request: [String: Any] = ["section": "jina", "values": ["api_key": "shutdown-fixture"]]
        let g = await host.auth.generation
        _ = await host.settings.handle("verify", body: request, generation: g)
        let saving = Task { await host.settings.handle("save", body: request, generation: g) }
        while !entered { await Task.yield() }
        let stopping = Task { await host.stop() }
        while await host.auth.generation == g { await Task.yield() }
        check("settings: shutdown waits for the old callback", !host.stopped)
        var secondStopped = false
        let secondStop = Task { await host.stop(); secondStopped = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        check("settings: overlapping shutdown callers both await settlement", !secondStopped)
        switch InstanceLease.acquire(label: "competing daemon fixture") {
        case .success(let other): check("settings: shutdown retains lease until callback exits", false); other.release()
        case .failure: check("settings: shutdown retains lease until callback exits", true)
        }
        release?.resume()
        check("settings: revoked callback cannot write during shutdown", (await saving.value).0 == 404 && !wrote)
        await stopping.value
        await secondStop.value
        check("settings: server closes after settlement", host.stopped)
        switch InstanceLease.acquire(label: "next daemon fixture") {
        case .success(let other): check("settings: next daemon can acquire lease after settlement", true); other.release()
        case .failure: check("settings: next daemon can acquire lease after settlement", false)
        }
    }
}


extension SelftestContext {
    @MainActor
    func browserSettingsSignals() async throws {
        for secondSignal in [true, false] {
            var release: CheckedContinuation<Void, Never>?
            var entered = false, graceful = 0, forced = 0
            let coordinator = ShutdownSignalCoordinator(graceNanoseconds: secondSignal ? 5_000_000_000 : 30_000_000,
                settle: { entered = true; await withCheckedContinuation { release = $0 } },
                gracefulExit: { graceful += 1 }, forceExit: { forced += 1 })
            coordinator.request()
            while !entered { await Task.yield() }
            check("settings: first signal waits for callback", forced == 0 && graceful == 0)
            if secondSignal { coordinator.request() }
            else {
                // The forced-exit deadline (30 ms here) fires from a background task; a loaded
                // CI runner can schedule it late. Wait for it with a bound instead of a fixed sleep.
                let waitUntil = ProcessInfo.processInfo.systemUptime + 3
                while forced == 0 && ProcessInfo.processInfo.systemUptime < waitUntil { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            check(secondSignal ? "settings: second signal forces exit immediately" : "settings: signal settlement has a bounded deadline", forced == 1 && graceful == 0)
            release?.resume()
            for _ in 0..<20 { await Task.yield() }
            coordinator.request()
            check("settings: late callback and later signals cannot exit twice", forced == 1 && graceful == 0)
        }
        var graceful = 0, forced = 0
        let coordinator = ShutdownSignalCoordinator(graceNanoseconds: 30_000_000,
            settle: {}, gracefulExit: { graceful += 1 }, forceExit: { forced += 1 })
        coordinator.request()
        try await Task.sleep(nanoseconds: 100_000_000)
        check("settings: graceful signal cancels forced-exit deadline", graceful == 1 && forced == 0)
    }
}
