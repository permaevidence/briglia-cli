import Foundation

/// The running daemon as the settings owner (KEYLESS_WEB_AND_LIVE_MENU plan
/// B.3): every supported settings write of this profile goes through
/// `settingsWriter` — the live hub, forwarded commits from `briglia menu`,
/// `setup-api`, `briglia setup` and `briglia subscription`, Telegram settings
/// commands (under the commit token) and the idle apply of staged changes.
extension ConversationManager: SettingsOwnerHost, SettingsApplyKicking {
    var settingsWriter: SettingsWriter {
        if let w = settingsWriterStorage { return w }
        let w = SettingsWriter(host: self)
        settingsWriterStorage = w
        return w
    }

    var isDaemon: Bool { true }

    func beginRouteBarrier() async -> Bool {
        // A settings command body committing its own change (/subscription
        // logout) runs inside its own counted ingress.
        await beginBrowserSettingsMutation(ownCommandIngress: Self.settingsCommandToken != nil ? 1 : 0)
    }

    func endRouteBarrier() { endBrowserSettingsMutation() }

    func admissionRefusal() -> String? {
        if admissionPaused { return Self.updatingRefusal }
        if isRestoringMind && !browserSettingsMutation { return MemoryReplacementLock.busyMessage }
        return settingsWriter.gate.admissionClosedReason
    }

    func reconcile(after change: PreparedChange, routeChanged: Bool) async {
        if routeChanged {
            // A route change is applied with the D barrier held (idle): the
            // full reload of today's live hub.
            await reloadBrowserSettings()
            modelRoutingGeneration += 1
        } else {
            // A key replacement or another plain save, possibly mid-task:
            // only the credentials are reinstalled (the running turn's own
            // operations keep the values they captured), plus an email
            // poller transition when the AgentMail account changed.
            await refreshServiceCredentials(force: true)
            await applyEmailSettingsChange()
        }
        IdentityChange.finishDeferred(quiescent: lastEmailResetQuiescent)
        serviceConfigStamp = Self.serviceCredentialDigest(KeychainHelper.loadSnapshot())
    }

    var toolSwitches: SettingsToolSwitches { SettingsToolSwitches.current(switchDefaults) }

    // MARK: Startup (B.5 crash recovery, B.4 /websearch migration)

    /// Before ordinary work and before the first idle apply.
    func startSettingsOwner() {
        ProcessKind.isDaemon = true
        WebSearchBackend.migrateSelectionToSecrets()
        do {
            let report = try SettingsRecovery.run()
            for r in report.results {
                print("[SettingsWriter] recovered \(r.label): \(r.state)\(r.message.map { " — \($0)" } ?? "")")
            }
        } catch {
            print("[SettingsWriter] WARNING: settings recovery failed: \(error)")
        }
        SettingsSupersede.install()
        serviceConfigStamp = Self.serviceCredentialDigest(KeychainHelper.loadSnapshot())
        let writer = settingsWriter
        SettingsClient.inProcessOwner = { change, stillValid in await writer.commit(change, stillValid: stillValid) }
        SettingsClient.inProcessWriter = writer
        SettingsAgentEdit.immediateOwner = { change in await writer.commit(change, policy: .immediate) }
        startSIWCSurfaces()
        kickSettingsApply()
    }

    // MARK: Idle scheduler (B.5)

    func settingsChangesStaged() -> Bool {
        // Absent → nothing staged; unknown → its strict read fails below and
        // nothing is kicked (an apply would refuse anyway).
        guard (try? SettingsPendingStore.presence()) != false else { return false }
        return !((try? SettingsPendingStore.read())?.stagedCategories.isEmpty ?? true)
    }

    /// Coalesced: one run in flight; a kick during a run re-runs it once.
    /// Called when any barrier blocker clears (turn end, maintenance end,
    /// subagent / watcher / triage completion, archive recovery end, command
    /// ingress end, subscription login end, managed-bot work end, assistants
    /// menu end, upgrade resume, startup, the token's release).
    func kickSettingsApply() {
        guard settingsWriterStorage != nil else { return }
        if settingsApplyTask != nil { settingsApplyAgain = true; return }
        guard settingsChangesStaged() else { return }
        settingsApplyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.settingsApplyAgain = false
                await self.applyPendingSettingsIfAdmissible()
            } while self.settingsApplyAgain && self.settingsChangesStaged()
            self.settingsApplyTask = nil
            // Safety net for blockers without an explicit kick (a background
            // subagent finishing): retry every 10 s while something waits.
            if self.settingsChangesStaged(), !self.settingsRetryScheduled {
                self.settingsRetryScheduled = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.settingsRetrySecondsForTesting * 1_000_000_000))
                    self?.settingsRetryScheduled = false
                    self?.kickSettingsApply()
                }
            }
        }
    }

    /// One pass over the staged slots; a slot whose barrier is refused stays
    /// staged until the next kick.
    func applyPendingSettingsIfAdmissible() async {
        guard let doc = try? SettingsPendingStore.read() else { return }
        for category in doc.stagedCategories {
            guard activeRunId == nil, activeProcessingTask == nil, !isTurnActive else { return }
            _ = await settingsWriter.applyStaged(category: category)
        }
    }

    // MARK: Telegram settings commands (B.4b)

    /// Telegram settings commands and buttons never commit inside counted
    /// ingress: the handler returns at once and this writer task takes the
    /// commit token like any other writer, runs the command body (its own
    /// idle guards and replies unchanged) and releases. A lifecycle
    /// operation that closed admission refuses it with its busy text.
    func runSettingsCommand(_ body: @escaping @MainActor () async -> Void) {
        let writer = settingsWriter
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let token = await writer.gate.acquire() else {
                try? await self.sendText(writer.gate.admissionClosedReason ?? MemoryReplacementLock.busyMessage)
                return
            }
            // A started command body is never cancelled by a lifecycle
            // operation (Codex live-menu R1-5): it may already have written,
            // and its handler writes directly. The lifecycle waits for it
            // (bodies are bounded: a reply, a reload, at most a host listing).
            // A failed invalidation blocks direct command writes too (R2-2).
            do { try SettingsSupersede.flushUnflushedInvalidations() } catch {
                writer.gate.release(token)
                try? await self.sendText("⚠️ " + SettingsSupersede.unflushedMessage)
                return
            }
            writer.gate.enterDurablePhase(token)
            await Self.$settingsCommandToken.withValue(token) { await body() }
            writer.gate.release(token)
            // A command whose own write could not cancel a waiting change on
            // disk says so (the write itself is saved).
            if SettingsSupersede.hasUnflushedInvalidations {
                try? await self.sendText("⚠️ " + SettingsSupersede.unflushedMessage)
            }
            self.kickSettingsApply()
        }
    }

    /// Set while a settings command body runs under the commit token.
    @TaskLocal static var settingsCommandInline = false
    /// The token a settings command body runs under (its own transaction
    /// commits use `commitHolding` with it; the gate is not reentrant).
    @TaskLocal static var settingsCommandToken: SettingsCommitGate.Token?

    /// A settings command's prepared change through the transaction: under
    /// the command's token when it holds one, else a normal commit.
    func commitFromSettingsCommand(_ change: PreparedChange) async -> SettingsCommitResult {
        if let token = Self.settingsCommandToken {
            return await settingsWriter.commitHolding(token, change, policy: .classify)
        }
        return await settingsWriter.commit(change)
    }

    /// The reply for a settings command whose commit did not apply.
    static func settingsCommandRefusal(_ r: SettingsCommitResult) -> String {
        switch r.state {
        case .busy: return r.message ?? "Briglia is busy with a task; try again when it finishes."
        case .pending: return r.message ?? "Saved; it applies when the current task finishes."
        default: return r.message ?? "Not saved."
        }
    }

    /// The commands whose body writes route settings (they run as writer tasks).
    static let settingsCommandTokens: Set<String> = [
        "/provider", "/model", "/effort", "/orprovider", "/websearch", "/subagentmodels",
        "/subagents", "/websubagent", "/freesearch", "/subscription",
        "/transcribe_local", "/transcribe_openai",
    ]

    // MARK: Lifecycle operations (B.4b)

    /// Mind import, /deleteuserdata, shutdown and the upgrade barrier: close
    /// settings admission (new writers refused at once), settle the queued
    /// writers, cancel the holder's write-free wait (barrier, locks — never
    /// a durable phase, never the pending-apply task itself), then take the
    /// token.
    func beginSettingsLifecycle(reason: String) async -> SettingsCommitGate.Token {
        let gate = settingsWriter.gate
        gate.closeAdmission(reason: reason)
        return await gate.acquireForLifecycle()
    }

    /// Graceful shutdown: admission closes for good; a holder past its first
    /// durable write is waited for (bounded by the signal grace).
    func settleSettingsForShutdown(timeoutSeconds: Double = 8) async {
        guard let writer = settingsWriterStorage else { return }
        writer.gate.closeAdmission(reason: "Briglia is stopping; try again when it is back.")
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while writer.gate.isHeld && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func endSettingsLifecycle(_ token: SettingsCommitGate.Token, reopen: Bool) {
        let gate = settingsWriter.gate
        gate.release(token)
        if reopen { gate.reopenAdmission() }
        kickSettingsApply()
    }

    // MARK: Live configuration stamp (B.7)

    /// At each service-call boundary (a model round) and idle kick: a secret
    /// store changed by any process since the services were configured is
    /// re-read once and the credentials reinstalled (serialized; versions
    /// allocated at read time by `reloadBrowserSettings`).
    func refreshServiceCredentialsIfChanged() async {
        await refreshServiceCredentials(force: false)
    }

    /// The credential tuple the services cache (OpenRouter, Serper, Jina,
    /// the OpenAI image key and options). Other keys are read live per
    /// request already.
    static func serviceCredentialDigest(_ s: [String: String]) -> String {
        let keys = [KeychainHelper.openRouterApiKeyKey, KeychainHelper.serperApiKeyKey, KeychainHelper.jinaApiKeyKey,
                    KeychainHelper.openAIImageApiKeyKey, KeychainHelper.openAIImageModelKey, KeychainHelper.openAIImagePreciseModelKey,
                    KeychainHelper.openAIImageQualityKey, KeychainHelper.openAIImageOutputFormatKey, KeychainHelper.openAIImageModerationKey]
        var pairs: [String: String] = [:]
        for k in keys { pairs[k] = s[k] ?? "" }
        return SettingsDigest.of(pairs: pairs)
    }

    /// Serialized on the main actor; the web configuration's version is
    /// allocated at read time, so a slower earlier install never wins.
    func refreshServiceCredentials(force: Bool) async {
        let snapshot = KeychainHelper.loadSnapshot()
        let digest = Self.serviceCredentialDigest(snapshot)
        guard force || digest != serviceConfigStamp else { return }
        serviceConfigStamp = digest
        let key = snapshot[KeychainHelper.openRouterApiKeyKey] ?? ""
        let webConfig = WebServiceConfig.make(openRouterKey: key,
            serperKey: snapshot[KeychainHelper.serperApiKeyKey] ?? "",
            jinaKey: snapshot[KeychainHelper.jinaApiKeyKey] ?? "")
        await openRouterService.configure(apiKey: key)
        await archiveService.updateAPIKey(key)
        await toolExecutor.install(webConfig: webConfig)
        if let imageKey = snapshot[KeychainHelper.openAIImageApiKeyKey], !imageKey.isEmpty {
            await OpenAIImageService.shared.configure(apiKey: imageKey,
                model: snapshot[KeychainHelper.openAIImageModelKey],
                preciseModel: snapshot[KeychainHelper.openAIImagePreciseModelKey],
                quality: snapshot[KeychainHelper.openAIImageQualityKey],
                outputFormat: snapshot[KeychainHelper.openAIImageOutputFormatKey],
                moderation: snapshot[KeychainHelper.openAIImageModerationKey])
        }
    }

    /// The safety-net retry interval (selftest seam).
    nonisolated(unsafe) static var settingsRetrySecondsForTesting: Double = 10
    var settingsApplyInFlight: Bool { settingsApplyTask != nil }

    /// Selftest seam: a turn is (not) running.
    func _testSetActiveProcessing(_ on: Bool) { activeProcessingTask = on ? Task {} : nil }

    // MARK: /status

    /// Staged / last results, for /status and the menu page.
    func settingsPendingStatusLines() -> [String] {
        guard let doc = try? SettingsPendingStore.read() else {
            return FileManager.default.fileExists(atPath: SettingsPendingStore.url.path)
                ? ["Settings: the waiting-changes file is damaged (\(SettingsPendingStore.url.path)); move it aside to drop them."] : []
        }
        var lines: [String] = []
        for (category, slot) in doc.slots.sorted(by: { $0.key < $1.key }) {
            if let a = slot.active { lines.append("Settings: applying \(a.change.label) (\(category))") }
            if let s = slot.staged { lines.append("Settings: waiting — \(s.change.label) applies when Briglia is idle") }
        }
        if let last = doc.lastResults.last, Date().timeIntervalSince(last.at) < 3600, last.state != "applied" {
            lines.append("Settings: last change \(last.label) — \(last.state)\(last.message.map { ": \($0)" } ?? "")")
        }
        return lines
    }
}
