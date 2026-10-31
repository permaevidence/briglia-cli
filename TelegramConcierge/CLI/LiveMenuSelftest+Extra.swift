import Foundation

// Further B.11 rows: presence as a route input at the decision point, no
// replay of an uncertain logout, the live configuration stamp, the menu's
// pairing lease, a daemon kept off by the pairing step (exit 75), the
// startup grace against a short commit.
extension LiveMenuHarness {
    func extraSection() async {
        // Presence: removing the image key while busy is staged (the image
        // route changes), decided at the decision point from the projection.
        let owner = FakeSettingsOwner(); owner.busy = true
        let writer = SettingsWriter(host: owner)
        reset(Self.routeBase.merging([KeychainHelper.openAIImageApiKeyKey: "sk-synthetic-image-1"]) { $1 })
        if let removal = await prepare(label: "OpenAI key removal", { try KeychainHelper.delete(key: KeychainHelper.openAIImageApiKeyKey) }) {
            let r = await writer.commit(removal)
            check("decision: removing a key while busy is staged (its presence is a route input)", r.state == .pending && store()[KeychainHelper.openAIImageApiKeyKey] != nil, "\(r.state)")
        }
        // An uncertain logout is never replayed by recovery.
        reset(Self.routeBase)
        let attemptId = UUID().uuidString
        let old = SubscriptionAuthState(generation: UUID().uuidString)
        var other = SubscriptionAuthState(generation: UUID().uuidString)
        other.credential = credential("acct-9", "9")
        writeAuth(other)
        _ = try? SettingsPendingStore.update { doc in
            doc.attempts[attemptId] = self.attempt(attemptId, auth: true, kind: "logout", old: old)
        }
        _ = try? SettingsRecovery.run()
        let after = try? authStore.read()
        check("recovery: an uncertain logout is reported, never replayed",
              after?.credential?.account == "acct-9" && after?.generation == other.generation
              && pendingDoc().lastResults.last?.state == "uncertain")
    }

    func daemonStampSection(_ manager: ConversationManager) async {
        // B.7: a key another process saved reaches the executor at the next
        // service-call boundary (a model round), not only at a restart.
        await manager.refreshServiceCredentials(force: true)
        try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-from-another-process")
        await manager.refreshServiceCredentialsIfChanged()
        check("stamp: a key saved elsewhere reaches the executor at the next round",
              manager.toolExecutor.webConfig.current.serperKey == "serper-from-another-process")
    }

    func pairingSection() async {
        // The offline menu's Telegram step holds the lease while open.
        var env = MenuEnvironment()
        env.snapshot = { MenuSnapshot() }
        env.toolchainStatus = { ToolchainService.DesktopStatus(doctorRan: true, missing: [], libreOffice: true, mandatoryMissing: []) }
        env.probe = { _ in ["ok": true, "bot_username": "pairing_test_bot"] }
        env.telegramScan = { _, _ in .waiting }
        let m = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
        await m.start()
        _ = await m.handle(["action": "telegram_token", "token": "123456789:AAsyntheticPairingToken000000"])
        check("pairing: the open Telegram step holds the instance lease (Briglia stays off)", InstanceLease.isHeldInThisProcess && InstanceLease.holderLabel() == "menu-pairing")
        check("pairing: the page says Briglia stays off meanwhile", m.status()["pairing_holds_off"] as? Bool == true)
        _ = await m.handle(["action": "telegram_reset"])
        check("pairing: leaving the step releases the lease", !InstanceLease.isHeldInThisProcess)
        _ = await m.handle(["action": "telegram_token", "token": "123456789:AAsyntheticPairingToken000000"])
        await m.shutdown()
        check("pairing: closing the page releases the lease", !InstanceLease.isHeldInThisProcess)
    }

    func childDaemon(grace: String, timeout: TimeInterval) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        p.arguments = ["daemon"]
        var env = ProcessInfo.processInfo.environment
        env["BRIGLIA_TEST_LEASE_GRACE"] = grace
        env["BRIGLIA_TEST_NO_BROWSER_BOOTSTRAP"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); p.waitUntilExit() }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }

    func startupSection() async {
        reset([:])
        // The pairing step keeps a starting daemon off with exit 75.
        guard case .success(let pairing) = InstanceLease.acquire(label: "menu-pairing") else { check("startup: lease", false); return }
        let kept = childDaemon(grace: "0.3", timeout: 20)
        pairing.release()
        check("startup: a daemon starting while the menu pairs Telegram exits 75 (kept off, not a failure)",
              kept.status == 75 && kept.output.contains("stays off while the menu connects Telegram"), "\(kept.status) \(kept.output.suffix(300))")
        // A short commit that ends within the grace: the daemon gets the lease.
        guard case .success(let commit) = InstanceLease.acquire(label: "settings-commit") else { check("startup: lease", false); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { commit.release() }
        let started = childDaemon(grace: "5", timeout: 8)
        check("startup: a short commit within the 10 s grace delays startup instead of failing it",
              !started.output.contains("already running") && !started.output.contains("is already running"), started.output.suffix(300).description)
        // A commit that outlasts the grace still makes startup fail (exit 1).
        guard case .success(let long) = InstanceLease.acquire(label: "settings-commit") else { check("startup: lease", false); return }
        let failed = childDaemon(grace: "0.3", timeout: 15)
        long.release()
        check("startup: a commit that outlasts the grace fails startup with exit 1 (contention, not I/O)",
              failed.status == 1 && failed.output.contains("already running"), "\(failed.status) \(failed.output.suffix(200))")
    }
}
