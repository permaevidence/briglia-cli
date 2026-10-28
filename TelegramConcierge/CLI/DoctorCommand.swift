import ArgumentParser
import Foundation

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check Briglia's configuration, permissions and toolchain."
    )

    @Flag(name: .long, help: "Also probe the configured services over the network.")
    var online = false

    @Flag(name: .customLong("read-only"), help: .hidden)
    var readOnly = false

    /// `briglia doctor --read-only` (MULTI_ASSISTANT_PLAN §6.1): exempt from
    /// every gate and lease; reads only machine records (barrier, journal,
    /// registry, member leases) and no bundle resource, so it can always
    /// report a stuck update.
    static func readOnlyReport(paths: UpgradeBarrier.Paths = .live, registryPaths: AssistantRegistry.Paths = .live) -> [String] {
        var lines = ["Assistants and updates (read-only)"]
        if let b = UpgradeBarrier.current(paths) {
            lines.append("  · update barrier: \(b.state.rawValue) (target \(b.targetVersion), id \(b.id.prefix(8)))\(b.reason.map { " — \($0)" } ?? "")")
            if b.state == .stuck { lines.append("  ✖ " + UpgradeBarrier.stuckMessage) }
        } else {
            lines.append("  ✔ no update in progress")
        }
        switch UpgradeBarrier.journal(paths) {
        case .absent: break
        case .value(let j): lines.append("  · update journal: \(j.phase.rawValue) (backups \(j.backupBinary), \(j.backupBundle))")
        case .malformed(let why): lines.append("  ✖ update journal unreadable: \(why)")
        }
        switch AssistantRegistry.presence(registryPaths) {
        case .absent: lines.append("  · one assistant (no registry)")
        case .unreadable(let why): lines.append("  ✖ assistants registry unreadable: \(why)")
        case .present:
            if let doc = (try? AssistantRegistry.read(registryPaths)) ?? nil {
                for r in doc.records {
                    let dir = r.name == AssistantProfile.defaultName ? paths.root.deletingLastPathComponent().appendingPathComponent("members")
                        : registryPaths.root.appendingPathComponent("members/\(r.name)/\(r.generation)")
                    let running = MemberLeases.users(dir, assistantsOnly: true).count
                    lines.append("  · \(r.name) (\(r.displayName)): \(r.state)\(running > 0 ? ", running" : "")\(r.activeTx.isEmpty ? "" : ", a settings change is in progress")")
                }
            } else { lines.append("  ✖ assistants registry damaged") }
        }
        let findings = UnleasedInstances.findings(registryPaths: registryPaths, defaultData: paths.root.deletingLastPathComponent().deletingLastPathComponent(),
                                                  defaultLeases: paths.root.deletingLastPathComponent().appendingPathComponent("members"))
        for f in findings {
            switch f.kind {
            case .unleased: lines.append("  ✖ running without coordination: \(f.profile) — " + UnleasedInstances.message)
            case .uncheckable(let why): lines.append("  ✖ instance lock of \(f.profile) cannot be checked: \(why) — make it readable and writable by you (chmod 600)")
            }
        }
        return lines
    }

    func run() async throws {
        if readOnly {
            for line in Self.readOnlyReport() { print(line) }
            return
        }
        var problems = 0
        func check(_ label: String, ok: Bool, hint: String? = nil) {
            print("  \(ok ? "✔" : "✖") \(label)")
            if !ok {
                problems += 1
                if let hint { print("      → \(hint)") }
            }
        }
        func note(_ label: String) { print("  · \(label)") }

        // Identity migration (read-only: doctor reports and points at the
        // recovery command, never mutates — rename plan §4.3).
        let migrationFindings = IdentityMigration.doctorFindings()
        if !migrationFindings.isEmpty {
            print("\nMigration")
            for finding in migrationFindings {
                if finding.problem {
                    check(finding.text, ok: false, hint: finding.hint)
                } else {
                    note(finding.text)
                }
            }
        }

        print("\nConfiguration")
        let provider = LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey))
        let baseURL: String
        let model: String
        let mainKey: String?
        switch provider {
        case .lmStudio:
            baseURL = KeychainHelper.load(key: KeychainHelper.lmStudioBaseURLKey) ?? ""
            model = KeychainHelper.load(key: KeychainHelper.lmStudioModelKey) ?? ""
            mainKey = nil
        default:
            baseURL = KeychainHelper.load(key: KeychainHelper.openAICompatibleBaseURLKey) ?? ""
            model = KeychainHelper.load(key: KeychainHelper.openAICompatibleModelKey) ?? ""
            mainKey = KeychainHelper.load(key: KeychainHelper.openAICompatibleApiKeyKey)
        }
        check("main agent endpoint configured (\(model.isEmpty ? "—" : model))",
              ok: !baseURL.isEmpty && !model.isEmpty && (provider == .lmStudio || !(mainKey ?? "").isEmpty),
              hint: "run `briglia setup`, section 1")
        if let advisory = Self.legacyOpenCodeAliasAdvisory(model: model, baseURL: baseURL,
                                                            activeProfile: ProviderProfiles.activeProfile()) {
            note(advisory)
        }
        if let advisory = Self.openCodeStaleTextOnlyAdvisory(model: model,
                textOnly: KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "true",
                activeProfile: ProviderProfiles.activeProfile()) {
            note(advisory)
        }
        // Mid-turn early wake (§3.13, §3.12.5): a test install must never
        // stay in force-detach mode silently, and crash-record obligations
        // that could not be verified after a restart are listed.
        check("force-detach test setting is off", ok: !ForceDetach.isEnabled,
              hint: "\(ForceDetach.environmentKey) is set: every long bash wait and eligible subagent call (not Browse) moves to the background after \(Int(TurnWakeCenter.defaultGraceSeconds)) s — unset it outside field trials")
        do {
            let records = try DetachedJobStore.load()
            for record in records where record.unverifiableReason != nil {
                note("background job \(record.handle) (\(record.command.prefix(40))): result could not be verified after a restart (\(record.unverifiableReason ?? "")) — kept for inspection")
            }
        } catch {
            check("background-job crash records readable", ok: false,
                  hint: "\(DetachedJobStore.fileURL.path): \(error.localizedDescription) — it is never overwritten; move it aside to reset")
        }
        // Tool-charge accounting (§3.6.3): read-only here — the daemon owns
        // every write (episodes, acceptance, roll-forward).
        if case .unreadable(let reason) = ToolChargeLedger.loadLedger() {
            check("tool-charge ledger readable", ok: false,
                  hint: "\(ToolChargeLedger.ledgerURL.path): \(reason) — never overwritten; spend totals are incomplete. Repair or restore the file, or send /spend accept-unknown (the file is preserved)")
        }
        switch ToolChargeLedger.loadIncidents() {
        case .unreadable(let reason):
            check("spend incident registry readable", ok: false,
                  hint: "\(ToolChargeLedger.incidentsURL.path): \(reason) — never overwritten; paid work stays paused under a configured daily/monthly cap until it reads")
        case .readable(let incidents):
            for incident in incidents where incident.state == .open {
                note("spend totals incomplete: \(ToolChargeLedger.describe(incident))")
            }
        }
        let serverStore = KeychainHelper.loadSnapshot()
        if let servers = ProviderServers.list(serverStore) {
            if !servers.isEmpty {
                let active = ProviderServers.activeServer(serverStore)
                note("named servers: \(servers.count) (\(servers.map(\.name).joined(separator: ", ")))\(active.map { "; in use: \($0.name)" } ?? "")")
            }
        } else {
            check("named server list readable", ok: false, hint: "\(ProviderServers.listKey) in secrets.json doesn't decode — fix or remove that entry")
        }
        if provider == .openRouter, let pin = OpenRouterProviderPin.statusLine() {
            note(pin)
        }
        // Per-model OpenRouter hosts (v0.2.56): unreadable map, unresolved
        // legacy pin, a kept corrupt backup.
        let pinStore = KeychainHelper.loadSnapshot()
        switch OpenRouterPinMap.state(pinStore) {
        case .corrupt, .unsupported:
            check("OpenRouter per-model hosts readable", ok: false,
                  hint: "\(OpenRouterPinMap.storageKey) doesn't decode — routing is automatic for every model; choose a host with /orprovider <slug>|off|default to recover (the old value is backed up)")
        case .absent, .valid: break
        }
        if let pending = OpenRouterPinMap.pendingLegacy(pinStore) {
            note("OpenRouter legacy host pin \(pending.value) can't be migrated (\(pending.reason)) — it stays on \(pending.model); replace it with /orprovider <slug>, off or default before switching model")
        } else if pinStore[OpenRouterPinMap.legacyKey] != nil, OpenRouterPinMap.effectiveORModel(pinStore) != nil {
            note("OpenRouter host pin migration pending (applied on the next settings change or start)")
        }
        if let backup = pinStore[OpenRouterPinMap.corruptBackupKey] {
            note("an unreadable earlier OpenRouter host map is backed up (\(backup.utf8.count) bytes, \(OpenRouterPinMap.corruptBackupKey))")
        }
        let openAIKey = KeychainHelper.load(key: KeychainHelper.openAITranscriptionApiKeyKey) ?? ""
        let mediaSnapshot = KeychainHelper.loadSnapshot()
        let mediaFollowsOpenRouter = MediaRouting.followsOpenRouter(stored: mediaSnapshot)
        if openAIKey.isEmpty && mediaFollowsOpenRouter {
            note("OpenAI key: not set (optional with OpenRouter: voice, images and OCR go through the OpenRouter key)")
        } else {
            check("OpenAI key present", ok: !openAIKey.isEmpty, hint: "run `briglia setup`, section 2")
        }
        switch MediaRouting.voiceAndImagesVia(stored: mediaSnapshot) {
        case "openrouter":
            note("voice & images: via OpenRouter (\(OpenAITranscriptionService.Endpoint.openRouter.textModel); images \(OpenRouterImageService.bestModel), fast \(OpenRouterImageService.fastModel))")
        case "openai":
            note("voice & images: via OpenAI (image backend: \(MediaRouting.imageBackend(stored: mediaSnapshot).rawValue))")
        default:
            note("voice & images: not configured (add an OpenAI key, or use OpenRouter as the main provider)")
        }
        let serperKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        check("Serper key present", ok: !serperKey.isEmpty, hint: "run `briglia setup`, section 3")
        let jinaKey = KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) ?? ""
        check("Jina key present", ok: !jinaKey.isEmpty, hint: "run `briglia setup`, section 4")
        note("Telegram: \(TelegramConfig.isConfigured ? "configured" : "not configured (optional)")")
        let backendSource = WebSearchBackend.explicitlyStored != nil
            ? "explicit" : "inferred from keys — set with /websearch"
        if WebSearchBackend.activeSelection.followsMainOpenRouter {
            note("web page-reading backend (extraction, web_fetch; research runs on the main model): openrouter (follows the OpenRouter provider: \(WebSearchBackend.openRouterFollowSummary); \(WebSearchBackend.configured.rawValue) on other providers, \(backendSource))")
        } else if WebSearchBackend.active == .chatgpt {
            note("web page-reading backend (extraction, web_fetch; research runs on the main model): chatgpt (follows the ChatGPT subscription provider; \(WebSearchBackend.configured.rawValue) on other providers, \(backendSource))")
        } else {
            note("web page-reading backend (extraction, web_fetch; research runs on the main model): \(WebSearchBackend.active.rawValue) — \(WebSearchBackend.active.modelSummary) (\(backendSource))")
        }
        note("web page-reading time limit: \(Int(WebSearchBackend.extractorDeadline)) s per request on every backend, up to 3 attempts (a cut request on OpenRouter or the OpenAI API key counts as an unknown charge in /spend)")
        note("web subagent: \(AvailableTools.webSubagentEnabled ? "on" : "off"); Web preset available: \(serperKey.isEmpty ? "no (Serper key missing)" : (AvailableTools.webSubagentActive ? "yes" : "no (switch off)"))")
        var ocrBackend = KeychainHelper.load(key: KeychainHelper.visionPreprocessorBackendKey)
            ?? (openAIKey.isEmpty ? "openrouter (no OpenAI key)" : "openai")
        if ocrBackend == "openai", MediaRouting.ocrFollowsOpenRouter(stored: mediaSnapshot, openAIKey: OpenRouterService.resolvedOpenAIKey()) {
            ocrBackend = "openrouter (no OpenAI key; follows the OpenRouter provider)"
        }
        note("OCR backend: \(ocrBackend)")
        note("data: \(StoragePaths.dataRoot.path)")
        let snapshotStatus = PruneArchiveStore.statusLine()
        check(snapshotStatus, ok: !snapshotStatus.hasPrefix("Snapshot storage error:"))
        note("config: \(StoragePaths.configRoot.path)")

        if ProviderProfiles.activeProfile() == .chatgpt {
            do {
                let state = try SubscriptionAuthStore().read()
                check("ChatGPT subscription login", ok: state?.credential != nil && state?.requiresLogin != true && state?.generation == mainKey,
                      hint: "run briglia subscription login, then select the profile")
                note("Subscription billing; quota unknown. Image, transcription and web services may use separate API billing.")
                let subModel = ProviderProfiles.configuredModel(.chatgpt) ?? ResponsesAdapter.subscriptionDefaultModel
                let subEffort = (ProviderProfiles.configuredEffort(.chatgpt) ?? "").lowercased()
                let efforts = ResponsesAdapter.allowedEfforts(model: subModel)
                note("subscription model: \(subModel)\(subModel == ResponsesAdapter.subscriptionDefaultModel ? " (the default for new setups)" : "; new setups default to \(ResponsesAdapter.subscriptionDefaultModel)") — efforts \(efforts.joined(separator: ", "))")
                if !subEffort.isEmpty {
                    check("subscription reasoning effort '\(subEffort)' accepted by \(subModel)", ok: efforts.contains(subEffort),
                          hint: "use /effort \(efforts.contains("high") ? "high" : efforts.first ?? "off") (or /effort off)")
                }
            } catch { check("ChatGPT subscription credential storage", ok: false, hint: error.localizedDescription) }
        }

        // MCP routing references (mcp-routing.json routes, agents' mcp_tools
        // patterns): unresolved or malformed entries are kept verbatim by the
        // daemon and only reported here.
        let routingFindings = MCPAgentRouting.doctorFindings()
        if !routingFindings.isEmpty {
            print("\nMCP routing")
            for finding in routingFindings {
                if finding.problem {
                    check(finding.text, ok: false, hint: "edit \(MCPAgentRouting.routingURL().path)")
                } else {
                    note(finding.text)
                }
            }
        }

        // Session affinity (x-opencode-session / x-session-id): state file
        // validity, what the active provider receives, quarantined copies.
        print("\nSession affinity")
        for finding in SessionAffinity.doctorFindings(activeBaseURL: provider == .openRouter ? "https://openrouter.ai/api/v1" : baseURL) {
            if finding.problem { check(finding.text, ok: false, hint: finding.hint) } else { note(finding.text) }
        }

        print("\nUser profile maintenance")
        for finding in UserContextMaintenance.doctorFindings(
            profileSize: (KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? "").count) {
            if finding.problem { check(finding.text, ok: false, hint: finding.hint) } else { note(finding.text) }
        }

        print("\nCache diagnostics")
        do { note(try ResponsesUsageStore().diagnostic()) }
        catch { check("cache statistics unreadable", ok: false, hint: "Check responses_usage.json ownership, permissions and format; model requests can continue without statistics.") }

        print("\nStall diagnostics")
        note(StageMarkersReader.doctorLine())

        // Managed Playwright (Release C): the entry's shape, the referenced
        // install's marker, unreferenced/leftover directories, last bootstrap.
        let playwrightFindings = ManagedPlaywright.doctorFindings(
            configs: MCPRegistry.loadConfigsFromDisk(), layout: ManagedPlaywright.Layout(),
            bundledHash: (try? ManagedPlaywright.Manifests.bundled())?.lockfileHash)
        print("\nBrowser automation (Playwright)")
        for finding in playwrightFindings {
            if finding.problem {
                check(finding.text, ok: false, hint: finding.hint)
            } else {
                note(finding.text)
            }
        }

        // Storage permissions: everything under the roots (projects/ and
        // toolchain/ excluded) is expected owner-only; the daemon's startup
        // sweep tightens stragglers, doctor only reports them.
        let storage = PrivateStorage.sweep(apply: false)
        print("\nStorage permissions")
        check("entries under the roots are owner-only (\(storage.scanned) scanned; projects/ and toolchain/ excluded)",
              ok: storage.tightened == 0 && storage.errors.isEmpty,
              hint: storage.tightened > 0
                ? "\(storage.tightened) with group/other bits, e.g. \(storage.samples.prefix(3).joined(separator: ", ")) — start briglia once, the startup sweep fixes them"
                : "unreadable: \(storage.errors.prefix(3).joined(separator: "; "))")
        if storage.truncated { note("storage scan stopped at its entry budget") }

        print("\nPermissions")
        #if os(macOS)
        check("Full Disk Access", ok: PermissionsService.fullDiskAccessGranted(),
              hint: "grant it to your terminal app: System Settings → Privacy & Security → Full Disk Access")
        note("keep-awake: assertion held while Briglia runs (idle system sleep prevented) — a closed lid or a manual sleep still stops it")
        let sleep = PermissionsService.displaySleepMinutes()
        if let ac = sleep.ac {
            note("display sleep on power: \(ac == 0 ? "never" : "\(ac) min (harmless — only system sleep stops Briglia)")")
        }
        #else
        note("Full Disk Access: not applicable on Linux (ordinary file permissions)")
        if AgentServiceSupport.isUbuntuTouch() {
            // repowerd suspends the phone on screen-off; desktop sleep
            // settings are irrelevant — the keep-awake unit is what counts.
            note("Ubuntu Touch detected — suspend is governed by the keep-awake unit (below)")
        } else {
            let verdict = PermissionsService.autoSuspendVerdict()
            check(verdict.summary, ok: verdict.isOK,
                  hint: "\(AutoSuspendCensus.Verdict.maskCommand) — or run `briglia setup`, section 6; a suspended machine stops Briglia completely")
        }

        // Background service (briglia service): optional, but when installed it
        // should be healthy — and on Ubuntu Touch the wakelock is essential.
        let unitPath = AgentServiceSupport.userUnitDirectory(
            home: FileManager.default.homeDirectoryForCurrentUser.path)
            + "/" + AgentServiceSupport.userUnitName
        if FileManager.default.fileExists(atPath: unitPath) {
            let active = AgentServiceSupport.run(
                "systemctl", ["--user", "is-active", AgentServiceSupport.userUnitName]).output
            check("background service active", ok: active == "active",
                  hint: "briglia service status — journalctl --user -u briglia.service -n 50")
            check("linger enabled (service survives logout/boot)",
                  ok: AgentServiceSupport.lingerEnabled(),
                  hint: "loginctl enable-linger \(NSUserName()) (sudo may be needed)")
        } else {
            note("background service: not installed (optional — briglia service install)")
        }
        if AgentServiceSupport.isUbuntuTouch() {
            if AgentServiceSupport.wakelockUnitInstalled() {
                let wl = AgentServiceSupport.run(
                    "systemctl", ["is-active", AgentServiceSupport.wakelockUnitName]).output
                check("keep-awake wakelock unit active", ok: wl == "active",
                      hint: "sudo systemctl restart \(AgentServiceSupport.wakelockUnitName)")
            } else {
                check("keep-awake unit installed (phone must not suspend)", ok: false,
                      hint: "briglia service install — an OTA update may also have removed it")
            }
        }
        #endif

        print("\nToolchain")
        if let report = ToolchainService.runDoctor() {
            for entry in report.present { print("  ✔ \(ToolchainService.displayName(for: entry))") }
            for entry in report.missing {
                note("missing: \(ToolchainService.displayName(for: entry)) — \(entry.impact)")
            }
            note("LibreOffice: \(ToolchainService.libreOfficePresent() ? "present" : "not installed (optional)")")
            if let tree = PythonRuntime.doctorTreeLine() {
                check(tree.text, ok: tree.ok, hint: "briglia python-env install")
            }
        } else {
            #if os(macOS)
            check("python3", ok: false, hint: "install Xcode Command Line Tools or Homebrew python")
            #else
            check("python3", ok: false, hint: "install it with your package manager, e.g. sudo apt install python3")
            #endif
        }
        #if os(Linux)
        // On Linux the media pipeline (PDF page counts, slicing, OCR
        // rasterization, image downscaling) runs on these two suites.
        let mediaHint = AgentServiceSupport.isUbuntuTouch()
            ? "briglia toolchain install — installs to userdata, no sudo, survives OS updates"
            : "sudo apt install poppler-utils — without it Briglia cannot read or OCR PDFs"
        check("poppler-utils (pdfinfo/pdftotext/pdftoppm/pdfseparate/pdfunite)",
              ok: ["pdfinfo", "pdftotext", "pdftoppm", "pdfseparate", "pdfunite"]
                  .allSatisfy { PlatformBinary.find($0) != nil },
              hint: mediaHint)
        check("ImageMagick (identify/convert)",
              ok: PlatformBinary.find("magick") != nil
                  || (PlatformBinary.find("identify") != nil && PlatformBinary.find("convert") != nil),
              hint: AgentServiceSupport.isUbuntuTouch()
                  ? "briglia toolchain install — installs to userdata, no sudo, survives OS updates"
                  : "sudo apt install imagemagick — without it Briglia cannot inspect or resize images")
        // Attribute prefix-sourced tools so it's visible which survive OTA.
        let prefixTools = UserdataToolchain.status().filter { $0.source == "prefix" }
        if !prefixTools.isEmpty {
            note("userdata toolchain: \(prefixTools.map { $0.name }.joined(separator: ", ")) (OTA-safe prefix)")
        }
        // Dangling system apt-state symlinks (seen on a UT device
        // 2026-08-28: /var/cache/apt → deleted /userdata/apt/…): every
        // rootfs apt run fails with confusing errors. Briglia's own installer
        // is unaffected (fully redirected) — just surface the repair.
        let fmDoctor = FileManager.default
        for path in ["/var/cache/apt", "/var/lib/apt/lists"] {
            guard let target = try? fmDoctor.destinationOfSymbolicLink(atPath: path),
                  !fmDoctor.fileExists(atPath: path) else { continue }
            note("system apt state is a dangling symlink: \(path) → \(target) — "
                 + "system apt/apt-get commands will fail until the target is "
                 + "recreated (sudo mkdir -p \(target)/partial \(target)/archives/partial). Briglia's userdata "
                 + "toolchain installer is unaffected")
        }
        #endif
        switch EmailCalendarProvider.current {
        case .none:
            note("email/calendar: none (default) — enable AgentMail via `briglia menu` or `briglia setup`, toolchain step")
        case .agentmail:
            if AgentMailService.isConfigured() {
                let inbox = EmailCalendarProvider.agentMailInboxAddress
                note("email/calendar: AgentMail\(inbox.isEmpty ? "" : " (\(inbox))") + local calendar — key configured")
            } else {
                note("email/calendar: AgentMail selected but NO API key stored — rerun `briglia setup`, toolchain step")
            }
            // Briglia's private copy (security plan v24 §7.8.1): doctor only
            // reports; `briglia agentmail repair|upgrade` act.
            for line in AgentMailService.statusLines() { note(line) }
        }
        for line in RetiredIntegrations.doctorLines() { note(line) }

        // Security (auto-update plan, Phase 0): read-only, never a failing
        // check — Briglia's own pins and the host's pending OS updates.
        print("\nSecurity")
        for line in SecurityStatus.doctorLines(components: SecurityStatus.components(probeVersions: true),
                                               host: SecurityStatus.hostReport(.live), now: Date(),
                                               binary: SecurityStatus.liveBinaryInfo(),
                                               update: UpdateNoticeService.liveStatus(),
                                               tools: LocalToolsText.liveStatus()) {
            note(line)
        }

        // Several assistants (§10.4): nothing printed with one.
        let multiLines = MultiAssistantDoctor.lines()
        if !multiLines.isEmpty {
            print("\nAssistants")
            for line in multiLines {
                if line.problem { check(line.text, ok: false, hint: line.hint) } else { note(line.text) }
            }
        }

        if online {
            print("\nOnline probes")
            if !baseURL.isEmpty && !model.isEmpty {
                let failure: String?
                if let context = ResponsesAuxiliary.inheritedSnapshot(lane: .probe(UUID()), effortOverride: ResponsesAdapter.probeEffort(model: model)) {
                    do { _ = try await ResponsesAuxiliary.text(context: context, messages: [("user", "Reply OK.")]); failure = nil }
                    catch { failure = error.localizedDescription }
                } else { failure = await Probes.chatCompletion(baseURL: baseURL, apiKey: mainKey, model: model) }
                check("main agent responds", ok: failure == nil, hint: failure)
            }
            if !openAIKey.isEmpty {
                let failure = await Probes.openAI(apiKey: openAIKey)
                check("OpenAI key valid", ok: failure == nil, hint: failure)
            }
            if !serperKey.isEmpty {
                let failure = await Probes.serper(apiKey: serperKey)
                check("Serper key valid", ok: failure == nil, hint: failure)
            }
            if !jinaKey.isEmpty {
                let failure = await Probes.jina(apiKey: jinaKey)
                check("Jina key valid", ok: failure == nil, hint: failure)
            }
            if TelegramConfig.isConfigured {
                let token = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? ""
                let failure = await Probes.telegram(token: token)
                check("Telegram bot reachable", ok: failure == nil, hint: failure)
            }
            switch EmailCalendarProvider.current {
            case .agentmail where AgentMailService.isConfigured():
                let reachable = await AgentMailService.shared.verifyAccess()
                check("AgentMail key valid", ok: reachable,
                      hint: "check the key at agentmail.to (rerun `briglia setup`, toolchain step) — until then email context is empty")
            default:
                break
            }
        }

        print(problems == 0 ? "\nAll good." : "\n\(problems) problem(s) found.")
        if problems > 0 { throw ExitCode(1) }
    }
}

extension Doctor {
    /// OpenCode-only advisory (Codex S1, 2026-09-10): a custom or local
    /// endpoint may legitimately serve a model called "deepseek-flash", so the
    /// legacy-alias nudge fires only when the main agent is positively on
    /// OpenCode — the active profile is OpenCode, or the configured base URL
    /// is an OpenCode endpoint. Never a failing check.
    /// v0.2.31 upgrade nudge: the pre-0.2.31 catalog stored Luna as
    /// text-only, and a catalog change does not rewrite a persisted profile
    /// flag (a deliberate OCR preference cannot be told apart from the old
    /// default, so nothing is migrated silently — Codex, 2026-09-21). Fires
    /// only on the named OpenCode profile, for a model that now runs over
    /// the Responses API, while the runtime is still in text-only mode.
    static func openCodeStaleTextOnlyAdvisory(model: String, textOnly: Bool,
                                              activeProfile: ProviderProfiles.Profile?) -> String? {
        guard activeProfile == .opencode, textOnly, OpenCodeGo.usesResponses(model),
              let entry = OpenCodeGo.catalogEntry(for: model), !entry.textOnly else { return nil }
        return "\(entry.label) is stored as text-only from the pre-0.2.31 catalog; since 0.2.31 it sees images natively over the Responses API — re-select it with /model \(entry.id) (or `briglia setup`) to turn OCR preprocessing off"
    }

    static func legacyOpenCodeAliasAdvisory(model: String, baseURL: String,
                                            activeProfile: ProviderProfiles.Profile?) -> String? {
        let onOpenCode = activeProfile == .opencode || SessionAffinity.isOpenCodeBaseURL(baseURL)
        guard onOpenCode,
              let canonical = OpenCodeGo.legacyAliases[model.lowercased()],
              let entry = OpenCodeGo.catalogEntry(for: model) else { return nil }
        // Not a failure: OpenCode still serves the alias. Nudge only.
        return "model id \"\(model)\" is OpenCode's legacy alias for \(entry.label) (canonical id \"\(canonical)\"); pick the model again with /model or `briglia setup` before the alias is retired"
    }
}

/// `briglia doctor` with several assistants (MULTI_ASSISTANT_PLAN §10.4,
/// §25.7): registry and leases (the read-only report), shared-folder
/// permissions, board and claims files, stale reservations, ChatGPT scope.
enum MultiAssistantDoctor {
    struct Line: Equatable { var problem: Bool; var text: String; var hint: String? }

    static func lines(paths: MultiAssistant.Paths = .live, registryPaths: AssistantRegistry.Paths = .live,
                      barrierPaths: UpgradeBarrier.Paths = .live, now: Date = Date()) -> [Line] {
        // Same predicate as the model-facing gate: at least two ACTIVE assistants.
        guard AssistantRegistry.presence(registryPaths) != .absent,
              let doc = (try? AssistantRegistry.read(registryPaths)) ?? nil,
              doc.records.filter({ $0.state == "active" }).count >= 2 else {
            // An unreadable registry is still reported (fail visible).
            if case .unreadable(let why) = AssistantRegistry.presence(registryPaths) { return [Line(problem: true, text: "assistants registry unreadable: \(why)", hint: nil)] }
            return []
        }
        var out: [Line] = []
        for raw in Doctor.readOnlyReport(paths: barrierPaths, registryPaths: registryPaths).dropFirst() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            out.append(Line(problem: t.hasPrefix("✖"), text: String(t.dropFirst(2)), hint: nil))
        }
        func privateDir(_ url: URL, _ label: String) {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return }
            let ok = (st.st_mode & S_IFMT) == S_IFDIR && (st.st_mode & 0o077) == 0 && st.st_uid == getuid()
            out.append(Line(problem: !ok, text: "\(label) is private to you", hint: ok ? nil : "chmod 700 \(url.path)"))
        }
        privateDir(paths.shared, "the shared assistants folder")
        privateDir(paths.boardDir, "the board folder")
        privateDir(paths.claimsDir, "the file-claims folder")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: paths.claimsDir.path) {
            for name in names.sorted() where name.hasSuffix(".json") {
                guard let doc = FileClaims.read(paths.claimsDir.appendingPathComponent(name)) else {
                    out.append(Line(problem: true, text: "file claims \(name) unreadable", hint: "it is ignored; remove it when that assistant is stopped"))
                    continue
                }
                let old = doc.claims.filter { $0.state == FileClaims.reserved && now.timeIntervalSince($0.reservedAt) > 600 }
                if !old.isEmpty {
                    out.append(Line(problem: true, text: "\(doc.profile): \(old.count) file edit\(old.count == 1 ? "" : "s") reserved for more than 10 minutes (\(old.prefix(3).map { MultiAssistant.display($0.path) }.joined(separator: ", ")))",
                                    hint: "an edit may be stuck; stopping that assistant frees its files"))
                } else {
                    out.append(Line(problem: false, text: "\(doc.profile): \(doc.claims.count) claimed file\(doc.claims.count == 1 ? "" : "s")", hint: nil))
                }
            }
        }
        if let scope = SubscriptionSharing.scopeStatus() {
            out.append(Line(problem: false, text: "ChatGPT: \(scope) (store \(SubscriptionSharing.storeDirectory().path))", hint: nil))
            if AssistantProfile.isExtra, SubscriptionSharing.scope() == .own,
               (try? SubscriptionAuthStore().read())?.credential == nil {
                out.append(Line(problem: true, text: "this assistant uses its own ChatGPT login, but it is not signed in",
                                hint: "\(AssistantProfile.commandPrefix) subscription login, or `subscription scope shared`"))
            }
        }
        return out
    }
}
