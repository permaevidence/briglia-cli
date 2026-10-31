import Foundation

// Agent field edits (B.5), forwarding (B.6), the lock-file label (B.9), the
// /websearch move (B.4), the setup provider order, and the daemon-level idle
// triggers with a real ConversationManager.
extension LiveMenuHarness {
    func json(_ s: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func agentEditSection() async {
        reset(Self.routeBase)
        let original = json(store())
        var edited = store(); edited[KeychainHelper.jinaApiKeyKey] = "jina-agent-1"
        // An unrelated change lands meanwhile: it survives.
        try? KeychainHelper.save(key: KeychainHelper.userContextKey, value: "maintenance wrote this")
        let r = await SettingsAgentEdit.commit(originalText: original, updatedText: json(edited))
        check("agent edit: the changed key is merged", r == .applied(changed: [KeychainHelper.jinaApiKeyKey]) && store()[KeychainHelper.jinaApiKeyKey] == "jina-agent-1", "\(r)")
        check("agent edit: an unrelated concurrent change survives (no whole-file replacement)", store()[KeychainHelper.userContextKey] == "maintenance wrote this")
        // An overlapping change → conflict, nothing written.
        let original2 = json(store())
        var edited2 = store(); edited2[KeychainHelper.serperApiKeyKey] = "serper-agent"
        try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-menu")
        let r2 = await SettingsAgentEdit.commit(originalText: original2, updatedText: json(edited2))
        if case .refused(let why) = r2 {
            check("agent edit: an overlapping change refuses with the conflict message", why.contains("changed since you read it") && why.contains(KeychainHelper.serperApiKeyKey))
        } else { check("agent edit: an overlapping change refuses", false, "\(r2)") }
        check("agent edit: nothing was written on conflict", store()[KeychainHelper.serperApiKeyKey] == "serper-menu")
        // The token invariant.
        var edited3 = store(); edited3[KeychainHelper.telegramBotTokenKey] = "1:changed"
        if case .refused = await SettingsAgentEdit.commit(originalText: json(store()), updatedText: json(edited3)) {
            check("agent edit: a change of the Telegram token is refused", store()[KeychainHelper.telegramBotTokenKey] == nil)
        } else { check("agent edit: token refused", false) }
        // A route key edit applies immediately (D21), even mid-task.
        var edited4 = store(); edited4[KeychainHelper.openRouterModelKey] = "agent/model"
        let r4 = await SettingsAgentEdit.commit(originalText: json(store()), updatedText: json(edited4))
        check("agent edit: a route key applies at once (D21)", r4 == .applied(changed: [KeychainHelper.openRouterModelKey]))
        // Inverse delta (ApplyPatch rollback): refused when the post-image changed.
        let pre = json(store())
        var post = store(); post[KeychainHelper.jinaApiKeyKey] = "jina-patched"
        _ = await SettingsAgentEdit.commit(originalText: pre, updatedText: json(post))
        try? KeychainHelper.save(key: KeychainHelper.jinaApiKeyKey, value: "jina-later-save")
        let rollback = await SettingsAgentEdit.commit(originalText: json(post), updatedText: pre)
        if case .refused = rollback {
            check("rollback: an inverse delta is refused when the keys changed after the patch", store()[KeychainHelper.jinaApiKeyKey] == "jina-later-save")
        } else { check("rollback: refused", false, "\(rollback)") }
        check("rollback: the report names secrets.json as not restored",
              ApplyPatch.rollbackReport(["secrets.json was not restored: it changed after the patch (keys: jina_api_key)"]).contains("not restored"))
        // A non-object result is refused.
        if case .refused = await SettingsAgentEdit.commit(originalText: json(store()), updatedText: "[1,2]") {
            check("agent edit: an edit that breaks the JSON object is refused", true)
        } else { check("agent edit: broken JSON refused", false) }
        // The observer sees agent edits (they supersede staged menu changes).
        let owner = FakeSettingsOwner(); owner.busy = true
        let writer = SettingsWriter(host: owner)
        SettingsSupersede.install()
        if let d = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "menu/model") }) {
            _ = await writer.commit(d)
            var edited5 = store(); edited5[KeychainHelper.openRouterModelKey] = "agent/again"
            _ = await SettingsAgentEdit.commit(originalText: json(store()), updatedText: json(edited5))
            check("agent edit: supersedes an overlapping staged menu change", pendingDoc().slots["ai"] == nil)
        }
        SettingsSupersede.uninstall()
    }

    func forwardSection() async {
        // An old daemon without the handler: setup-api/wizard/subscription
        // refuse; never a local write.
        let change = PreparedChange(origin: "x", label: "x", epoch: 0)
        OwnerSocket.transportForTesting = { _ in throw OwnerSocket.Failure.nack("unknown request type \"settings_commit\"") }
        let r = await SettingsClient.forward(change)
        check("forward: an older daemon answers owner_protocol_unsupported", r.state == .refused && r.code == "owner_protocol_unsupported" && r.message == SettingsClient.unsupportedMessage)
        // Lost after send: never resubmitted; one lookup by id.
        var sent: [String] = []
        OwnerSocket.transportForTesting = { object in
            sent.append(object["type"] as? String ?? "")
            if object["type"] as? String == "settings_commit" { throw OwnerSocket.Failure.lost }
            return ["type": "settings_result", "state": "uncertain", "message": "no record of this request; the result is unknown"]
        }
        let r2 = await SettingsClient.forward(change)
        check("forward: a lost answer is looked up once, never resubmitted", sent == ["settings_commit", "settings_result"] && r2.state == .uncertain, "\(sent)")
        // The owner's answer is passed through.
        OwnerSocket.transportForTesting = { _ in ["type": "settings_result", "state": "pending", "ticket": "T1", "message": "m"] }
        let r3 = await SettingsClient.forward(change)
        check("forward: the owner's pending answer reaches the client with its ticket", r3.state == .pending && r3.ticket == "T1")
        // Unavailable: retried, then refused (never a local write).
        SettingsClient.socketRetrySecondsForTesting = 0.6
        OwnerSocket.transportForTesting = { _ in throw OwnerSocket.Failure.unavailable }
        let r4 = await SettingsClient.forward(change)
        check("forward: an owner that never answers is refused after the retry window", r4.state == .refused)
        SettingsClient.socketRetrySecondsForTesting = nil
        OwnerSocket.transportForTesting = nil
        // setup-api reply shapes.
        let prepared: [String: Any] = ["schema": 2, "ok": true, "applied": ["provider"]]
        let pending = SettingsClient.reply(SettingsCommitResult(state: .pending, message: "later", ticket: "T"), prepared: prepared)
        check("setup-api: accept_pending → ok with state pending and a ticket", pending["ok"] as? Bool == true && pending["state"] as? String == "pending" && pending["ticket"] as? String == "T")
        let busy = SettingsClient.reply(SettingsCommitResult(state: .busy, message: "busy"), prepared: prepared)
        check("setup-api: busy → agent_busy with nothing applied", ((busy["error"] as? [String: Any])?["code"] as? String) == "agent_busy" && (busy["applied"] as? [String])?.isEmpty == true)
        // Offline commit: the short lease is taken for the commit only.
        reset(Self.routeBase)
        if let s = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-offline") }) {
            SettingsClient.leaseWaitSecondsForTesting = 0.5
            let r5 = await SettingsClient.commit(s)
            check("offline: with no Briglia running, the commit takes the lease and applies", r5.state == .applied && store()[KeychainHelper.serperApiKeyKey] == "serper-offline")
            check("offline: the lease is released after the commit", !InstanceLease.isHeldInThisProcess)
            SettingsClient.leaseWaitSecondsForTesting = nil
        }
    }

    func leaseLabelSection() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lease-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")
        try? Data("4242 menu-pairing\n".utf8).write(to: url)
        check("lease file: the new `<pid> <label>` format parses", InstanceLease.holderLabel(url) == "menu-pairing" && UnleasedInstances.holderPid(dir) == 4242)
        try? Data("4243\n".utf8).write(to: url)
        check("lease file: an old pid-only file still parses (no label)", InstanceLease.holderLabel(url) == nil && UnleasedInstances.holderPid(dir) == 4243)
        if case .success(let lease) = InstanceLease.acquire(label: "menu-pairing") {
            check("lease file: an acquired lease writes its label", InstanceLease.holderLabel() == "menu-pairing")
            lease.release()
        } else { check("lease file: acquire", false) }
    }

    func websearchSection() {
        reset(Self.routeBase)
        Prefs.store.set("opencode", forKey: WebSearchBackend.selectionKey)
        WebSearchBackend.migrateSelectionToSecrets()
        check("websearch: the startup migration copies the preference into secrets.json", store()[WebSearchBackend.secretsSelectionKey] == "opencode")
        Prefs.store.set("openai", forKey: WebSearchBackend.selectionKey)
        WebSearchBackend.migrateSelectionToSecrets()
        check("websearch: an existing secrets value is never overwritten by the migration", store()[WebSearchBackend.secretsSelectionKey] == "opencode")
        check("websearch: reads prefer secrets.json", WebSearchBackend.explicitlyStored == .opencode)
        try? WebSearchBackend.saveSelection(.openrouter)
        check("websearch: a save writes secrets.json and mirrors the preference for a downgrade",
              store()[WebSearchBackend.secretsSelectionKey] == "openrouter" && Prefs.store.string(forKey: WebSearchBackend.selectionKey) == "openrouter")
        Prefs.store.removeObject(forKey: WebSearchBackend.selectionKey)
    }

    func orderSection() {
        let order = SetupWizard.providerMenuOrder
        check("setup: the main-provider list starts with OpenRouter (1) then ChatGPT (2)", order.first == .openrouter && order.dropFirst().first == .chatgpt)
        check("setup: every profile is listed exactly once", Set(order) == Set(ProviderProfiles.Profile.allCases) && order.count == ProviderProfiles.Profile.allCases.count)
    }

    // MARK: Daemon level (a real ConversationManager)

    func daemonSection() async {
        reset(Self.routeBase)
        let manager = ConversationManager()
        manager.startSettingsOwner()
        defer {
            SettingsClient.inProcessOwner = nil
            SettingsAgentEdit.immediateOwner = nil
            SettingsSupersede.uninstall()
            ProcessKind.isDaemon = false
        }
        check("daemon: the owner registers its writer for in-process commits", SettingsClient.inProcessOwner != nil)
        // A turn is "running": a route change is staged.
        manager._testSetActiveProcessing(true)
        guard let d = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "daemon/model") }) else { return }
        let r = await SettingsClient.commit(d)
        check("daemon: a route change mid-turn is staged", r.state == .pending, "\(r.state) \(r.message ?? "")")
        check("daemon: /status lists the waiting change", manager.settingsPendingStatusLines().contains { $0.contains("waiting") })
        // A key replacement mid-turn applies now.
        if let s = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-daemon") }) {
            let rs = await SettingsClient.commit(s)
            check("daemon: a key replacement mid-turn applies now", rs.state == .applied && store()[KeychainHelper.serperApiKeyKey] == "serper-daemon")
        }
        // The turn ends with no new message: the last blocker clearing kicks
        // the scheduler and the staged change applies.
        manager._testSetActiveProcessing(false)
        manager.scheduleSummaryRetentionIdlePass()
        var waited = 0
        while manager.settingsChangesStaged() && waited < 200 { try? await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        check("daemon: the idle trigger applies the staged change (no new message needed)",
              !manager.settingsChangesStaged() && store()[KeychainHelper.openRouterModelKey] == "daemon/model")
        // Telegram settings commands run as writer tasks: not inside ingress.
        let gate = manager.settingsWriter.gate
        guard let held = await gate.acquire() else { check("daemon: token", false); return }
        Prefs.store.removeObject(forKey: "ada.subagentsEnabled")
        manager.noteUserActivity(on: ConversationManager.appChannelAddress)
        let handled = await manager.handleControlCommandIfNeeded("/subagents off")
        check("daemon: a Telegram settings command returns at once (handed to a writer task)", handled && manager.browserSettingsCommandIngress == 0)
        check("daemon: the command waits for the token instead of writing", Prefs.store.object(forKey: "ada.subagentsEnabled") == nil)
        gate.release(held)
        waited = 0
        while Prefs.store.object(forKey: "ada.subagentsEnabled") == nil && waited < 200 { try? await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        check("daemon: the writer task runs the command once the token is free", Prefs.store.object(forKey: "ada.subagentsEnabled") as? Bool == false)
        Prefs.store.removeObject(forKey: "ada.subagentsEnabled")
        // A lifecycle operation refuses a queued Telegram command with its text.
        let token = await manager.beginSettingsLifecycle(reason: "lifecycle test")
        let refusedQueued = await gate.acquire()
        check("daemon: during a lifecycle operation a settings writer is refused", refusedQueued == nil)
        manager.endSettingsLifecycle(token, reopen: true)
        check("daemon: admission reopens after the operation", gate.admissionClosedReason == nil)
    }
}
