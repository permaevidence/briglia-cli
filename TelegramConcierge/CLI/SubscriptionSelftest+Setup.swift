import Foundation

extension SubscriptionSelftest {
    func setupTests(_ root: URL, _ c: Checks) async throws {
        let store = SubscriptionAuthStore(directory: root.appendingPathComponent("setup-auth"))
        var login = SubscriptionLogin(store: store)
        var calls = 0
        login.post = { path, _, _ in
            calls += 1
            if path.hasSuffix("usercode") { return (Data(#"{"device_auth_id":"fixture-device","user_code":"ABCD","interval":1}"#.utf8), 200) }
            if path.hasSuffix("deviceauth/token") { return (Data(#"{"authorization_code":"code","code_verifier":"verifier"}"#.utf8), 200) }
            return (try Self.tokenData(), 200)
        }
        let setup = SubscriptionSetup(login: login)
        let started = await setup.perform(["action": "start"])
        c.check("setup starts device login", started["ok"] as? Bool == true && started["code"] as? String == "ABCD")
        let publicBytes = String(data: try JSONSerialization.data(withJSONObject: started), encoding: .utf8)!
        c.check("setup exposes no device or credential tokens", !publicBytes.contains("fixture-device") && !publicBytes.contains("access_token"))
        let id = started["pending"] as! String
        let early = await setup.perform(["action": "poll", "pending": id])
        c.check("setup enforces poll interval across processes", early["state"] as? String == "pending" && calls == 1)
        try await store.locked { var state = try store.read()!; state.deviceChallenge!.nextPoll = .distantPast; try store.write(state) }
        let completed = await setup.perform(["action": "poll", "pending": id])
        c.check("setup completes and commits credentials", try completed["state"] as? String == "signed_in" && (try store.read()?.credential != nil))
        let duplicate = await setup.perform(["action": "poll", "pending": id])
        c.check("setup cannot replay a completed login", duplicate["ok"] as? Bool == false)
        let status = await setup.perform(["action": "status"])
        c.check("status exposes only non-secret scope", status["generation"] as? String == (try store.read()?.generation) && status["quota"] as? String == "unknown")
        let oldGeneration = try store.read()!.generation
        var logoutCheckpoints = 0
        let revokedLogout = await setup.perform(["action": "logout"]) {
            logoutCheckpoints += 1
            if logoutCheckpoints > 1 { throw SubscriptionError("revoked before logout write") }
        }
        c.check("logout rechecks authorization under lock before writing", try revokedLogout["ok"] as? Bool == false
                && logoutCheckpoints == 2 && (try store.read()?.generation == oldGeneration)
                && (try store.read()?.credential != nil))
        var revoked = false
        var delayed = login
        delayed.post = { path, fields, form in
            revoked = true
            return try await login.post(path, fields, form)
        }
        let superseded = await SubscriptionSetup(login: delayed).perform(["action": "start"]) {
            if revoked { throw SubscriptionError("revoked") }
        }
        c.check("revoked setup start cannot publish pending state", try superseded["ok"] as? Bool == false && (try store.read()?.pendingLogin == nil))
        c.check("revocation preserves established generation", try store.read()?.generation == oldGeneration)
        let again = await setup.perform(["action": "start"])
        let againID = again["pending"] as! String
        let cancelled = await setup.perform(["action": "cancel", "pending": againID])
        c.check("setup cancellation preserves established login", try cancelled["ok"] as? Bool == true && (try store.read()?.generation == oldGeneration))
        let late = await setup.perform(["action": "poll", "pending": againID])
        c.check("setup cancelled poll cannot commit", late["ok"] as? Bool == false)
        let expires = await setup.perform(["action": "start"])
        try await store.locked { var state = try store.read()!; state.deviceChallenge!.expires = .distantPast; try store.write(state) }
        let expired = await setup.perform(["action": "poll", "pending": expires["pending"]!])
        c.check("setup expired flow clears pending state", try expired["ok"] as? Bool == false && (try store.read()?.pendingLogin == nil))
        let wrong = await setup.perform(["action": "select", "generation": UUID().uuidString], ownsLease: true)
        c.check("selection rejects changed account generation", wrong["ok"] as? Bool == false)

        // Both serializations of refresh/logout, with a deterministic suspended refresh.
        let raceStore = SubscriptionAuthStore(directory: root.appendingPathComponent("race-auth"))
        let pending = try await raceStore.beginLogin()
        let generation = try await raceStore.commitLogin(Self.credential(expired: true), pending: pending)
        let gate = SubscriptionTestGate()
        let refresh = Task {
            try await raceStore.credential(generation: generation) { _ in
                await gate.markStarted(); await gate.wait(); return Self.credential("new-access")
            }
        }
        while !(await gate.started) { try await Task.sleep(nanoseconds: 1_000_000) }
        let logout = Task { try await raceStore.logout() }
        await gate.release()
        _ = try await refresh.value; try await logout.value
        c.check("refresh then logout leaves tombstone", try raceStore.read()?.credential == nil)
        await c.rejects("logout then stale refresh cannot resurrect credential") {
            _ = try await raceStore.credential(generation: generation) { _ in c.check("stale refresh never called", false); return Self.credential() }
        }
        // Exercise the long-running terminal/Telegram device polling owner.
        var deviceLogin = SubscriptionLogin(store: raceStore)
        deviceLogin.post = { _, _, _ in (Data(#"{"device_auth_id":"id","user_code":"CODE","interval":1}"#.utf8), 200) }
        let deviceTask = Task { try await deviceLogin.device { _, _ in } }
        while try raceStore.read()?.pendingLogin == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        try await raceStore.cancelLogin(try raceStore.read()!.pendingLogin!)
        await c.rejects("device owner observes cancellation during polling") { _ = try await deviceTask.value }
        deviceLogin.deviceTimeout = 0
        await c.rejects("device owner observes expiry") { _ = try await deviceLogin.device { _, _ in } }
        c.check("device expiry cannot commit", try raceStore.read()?.credential == nil)

        try await expiryTests(root, c)
        try await pollConcurrencyTests(root, c)

        // R1 active invalid login may recover; valid active login cannot be replaced.
        let defaultStore = SubscriptionAuthStore()
        let activePending = try await defaultStore.beginLogin()
        _ = try await defaultStore.commitLogin(Self.credential(), pending: activePending)
        try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: "gpt-5.6-luna", effort: "high", textOnly: false)
        try ProviderProfiles.activate(.chatgpt)
        await c.rejects("active usable login cannot be replaced") { try SubscriptionSetup.checkLoginReplacement() }
        try await defaultStore.logout()
        do { try SubscriptionSetup.checkLoginReplacement(); c.check("active logged-out profile can re-login", true) }
        catch { c.check("active logged-out profile can re-login", false) }
        let activeAgain = try await defaultStore.beginLogin()
        let activeGeneration = try await defaultStore.commitLogin(Self.credential(), pending: activeAgain)
        try await defaultStore.requireLogin(generation: activeGeneration, rejectedAccess: "synthetic-access")
        do { try SubscriptionSetup.checkLoginReplacement(); c.check("active revoked profile can re-login", true) }
        catch { c.check("active revoked profile can re-login", false) }
        try await defaultStore.logout()
        try await wizardRecoveryTests(c)
    }

    @MainActor
    func wizardRecoveryTests(_ c: Checks) async throws {
        let store = SubscriptionAuthStore()
        for mode in ["valid", "revoked", "logged-out"] {
            let pending = try await store.beginLogin()
            let oldGeneration = try await store.commitLogin(Self.credential(), pending: pending)
            try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil,
                model: "gpt-5.6-terra", effort: "medium", textOnly: false)
            try ProviderProfiles.activate(.chatgpt)
            if mode == "revoked" { try await store.requireLogin(generation: oldGeneration, rejectedAccess: "synthetic-access") }
            if mode == "logged-out" { try await store.logout() }
            var login = SubscriptionLogin(store: store)
            login.post = { path, _, _ in
                if path.hasSuffix("usercode") {
                    switch InstanceLease.acquire(label: "wizard regression contender") {
                    case .success(let lease): lease.release(); c.check("wizard owns instance lease during login", false)
                    case .failure: c.check("wizard owns instance lease during login", true)
                    }
                    return (Data(#"{"device_auth_id":"wizard","user_code":"TEST","interval":1}"#.utf8), 200)
                }
                if path.hasSuffix("deviceauth/token") { return (Data(#"{"authorization_code":"code","code_verifier":"verifier"}"#.utf8), 200) }
                return (try Self.tokenData(), 200)
            }
            var probes = 0
            let result = await SetupWizard().configureSubscription(login: login, ask: { prompt, fallback in
                prompt.hasPrefix("Account action") ? "login" : fallback ?? ""
            }, probeRequest: { request in
                probes += 1
                // The real device flow has committed the new generation. This
                // is exactly where the old wizard's early activate threw.
                do {
                    try ProviderProfiles.activate(.chatgpt)
                    c.check("old activation order rejects a newly committed login", false)
                } catch { c.check("old activation order rejects a newly committed login", true) }
                c.check("wizard retains chosen model and effort at probe", request["model"] as? String == "gpt-5.6-terra" && request["effort"] as? String == "medium")
                return ["ok": true, "generation": (try? store.read()?.generation) ?? ""]
            })
            let newGeneration = try store.read()!.generation
            c.check("wizard recovers active \(mode) login through probe/select/activate", result && probes == 1
                && newGeneration != oldGeneration && ProviderProfiles.activeProfile() == .chatgpt
                && KeychainHelper.load(key: KeychainHelper.openAICompatibleApiKeyKey) == newGeneration)
            c.check("wizard preserves non-default runtime model and effort", KeychainHelper.load(key: KeychainHelper.openAICompatibleModelKey) == "gpt-5.6-terra"
                && KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) == "medium")
        }
        try await store.logout()
    }

    func expiryTests(_ root: URL, _ c: Checks) async throws {
        let store = SubscriptionAuthStore(directory: root.appendingPathComponent("expiry-auth"))
        for (value, expected) in [("\"unparseable\"", 900.0), ("null", 900), ("30", 30), ("1800", 900), ("0", 0), ("-1", 0), ("\"nan\"", 0), ("\"inf\"", 0)] {
            var login = SubscriptionLogin(store: store)
            login.post = { _, _, _ in
                (Data((#"{"device_auth_id":"expiry","user_code":"TEST","interval":1,"expires_in":"# + value + "}").utf8), 200)
            }
            let result = await SubscriptionSetup(login: login).perform(["action": "start"])
            c.check("expiry parsing \(value)", expected == 0 ? result["ok"] as? Bool == false : result["expires_in"] as? Double == expected)
        }
    }

    func pollConcurrencyTests(_ root: URL, _ c: Checks) async throws {
        // A gate watchdog makes the old network-under-lock implementation fail
        // a bounded assertion instead of hanging the suite for 45 seconds.
        for stage in ["deviceauth/token", "oauth/token"] {
            for operation in ["refresh", "cancel", "logout", "replace", "reclaim", "expire"] {
                let store = SubscriptionAuthStore(directory: root.appendingPathComponent("poll-" + stage.replacingOccurrences(of: "/", with: "-") + operation))
                let oldPending = try await store.beginLogin()
                let generation = try await store.commitLogin(Self.credential(expired: true), pending: oldPending)
                let gate = SubscriptionTestGate()
                var login = SubscriptionLogin(store: store)
                login.post = { path, _, _ in
                    if path.hasSuffix("usercode") { return (Data(#"{"device_auth_id":"poll-device","user_code":"ABCD","interval":"1","expires_in":60}"#.utf8), 200) }
                    if path.hasSuffix(stage) { await gate.markStarted(); await gate.wait() }
                    if path.hasSuffix("deviceauth/token") { return (Data(#"{"authorization_code":"code","code_verifier":"verifier"}"#.utf8), 200) }
                    return (try Self.tokenData(), 200)
                }
                let setup = SubscriptionSetup(login: login)
                let started = await setup.perform(["action": "start"])
                let pending = started["pending"] as! String
                c.check("server expiry and string interval honored", started["expires_in"] as? Double == 60)
                try await store.locked { var state = try store.read()!; state.deviceChallenge!.nextPoll = .distantPast; try store.write(state) }
                let polling = Task { await setup.perform(["action": "poll", "pending": pending]) }
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while !(await gate.started), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
                guard await gate.started else {
                    polling.cancel(); await gate.release(); _ = await polling.value
                    c.check("poll reaches network gate", false); continue
                }
                let watchdog = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { await gate.release() } }
                c.check("poll reservation covers exchanges and lock waits", (try store.read()?.deviceChallenge?.nextPoll.timeIntervalSinceNow ?? 0) > 150)
                let duplicate = await setup.perform(["action": "poll", "pending": pending])
                c.check("in-flight poll returns pending without another exchange", duplicate["state"] as? String == "pending")
                switch operation {
                case "refresh":
                    _ = try await store.credential(generation: generation) { _ in Self.credential("refreshed-during-poll") }
                case "cancel": _ = await setup.perform(["action": "cancel", "pending": pending])
                case "logout": try await store.logout()
                case "reclaim":
                    try await store.locked {
                        var state = try store.read()!
                        state.deviceChallenge!.pollAttempt = UUID().uuidString
                        try store.write(state)
                    }
                case "expire":
                    try await store.locked {
                        var state = try store.read()!; state.deviceChallenge!.expires = .distantPast; try store.write(state)
                    }
                default: _ = try await store.beginLogin()
                }
                c.check("\(operation) completes while \(stage) is suspended", !(await gate.released))
                let beforeRelease = try store.read()?.deviceChallenge?.pollAttempt
                watchdog.cancel(); await gate.release()
                let result = await polling.value
                if operation == "refresh" {
                    c.check("poll merges fresh state and completes after refresh", result["state"] as? String == "signed_in")
                } else {
                    c.check("late \(stage) cannot commit after \(operation)", result["ok"] as? Bool == false)
                    c.check("late poll preserves generation/tombstone", try operation == "logout" ? store.read()?.credential == nil : store.read()?.generation == generation)
                    if operation == "reclaim" {
                        c.check("late owner preserves newer claim on the same handle", try store.read()?.deviceChallenge?.pollAttempt == beforeRelease)
                    }
                    if operation == "expire" {
                        c.check("expired completion clears pending and is not retryable", try store.read()?.pendingLogin == nil
                            && (result["error"] as? [String: Any])?["retryable"] as? Bool == false)
                    }
                }
            }
        }
    }

}

private actor SubscriptionTestGate {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func markStarted() { started = true }
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
