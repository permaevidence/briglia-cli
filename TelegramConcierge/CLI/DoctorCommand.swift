import ArgumentParser
import Foundation

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check Briglia's configuration, permissions and toolchain."
    )

    @Flag(name: .long, help: "Also probe the configured services over the network.")
    var online = false

    func run() async throws {
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
        let openAIKey = KeychainHelper.load(key: KeychainHelper.openAITranscriptionApiKeyKey) ?? ""
        check("OpenAI key present", ok: !openAIKey.isEmpty, hint: "run `briglia setup`, section 2")
        let serperKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        check("Serper key present", ok: !serperKey.isEmpty, hint: "run `briglia setup`, section 3")
        let jinaKey = KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) ?? ""
        check("Jina key present", ok: !jinaKey.isEmpty, hint: "run `briglia setup`, section 4")
        note("Telegram: \(TelegramConfig.isConfigured ? "configured" : "not configured (optional)")")
        let backendSource = WebSearchBackend.explicitlyStored != nil
            ? "explicit" : "inferred from keys — set with /websearch"
        note("web search backend: \(WebSearchBackend.active.rawValue) (\(backendSource))")
        let ocrBackend = KeychainHelper.load(key: KeychainHelper.visionPreprocessorBackendKey)
            ?? (openAIKey.isEmpty ? "openrouter (no OpenAI key)" : "openai")
        note("OCR backend: \(ocrBackend)")
        note("data: \(StoragePaths.dataRoot.path)")
        note("config: \(StoragePaths.configRoot.path)")

        if ProviderProfiles.activeProfile() == .chatgpt {
            do {
                let state = try SubscriptionAuthStore().read()
                check("ChatGPT subscription login", ok: state?.credential != nil && state?.requiresLogin != true && state?.generation == mainKey,
                      hint: "run briglia subscription login, then select the profile")
                note("Subscription billing; quota unknown. Image, transcription and web services may use separate API billing.")
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

        print("\nCache diagnostics")
        do { note(try ResponsesUsageStore().diagnostic()) }
        catch { check("cache statistics unreadable", ok: false, hint: "Check responses_usage.json ownership, permissions and format; model requests can continue without statistics.") }

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
            note("email/calendar: none (default) — enable AgentMail or gws via `briglia setup`, toolchain step")
        case .agentmail:
            if AgentMailService.isConfigured() {
                let inbox = EmailCalendarProvider.agentMailInboxAddress
                note("email/calendar: AgentMail\(inbox.isEmpty ? "" : " (\(inbox))") + local calendar — key configured")
            } else {
                note("email/calendar: AgentMail selected but NO API key stored — rerun `briglia setup`, toolchain step")
            }
            if let tx = AgentMailService.transactionReport() {
                check(tx, ok: false, hint: "doctor never repairs; the command above settles it safely")
            }
            if !AgentMailService.agentMailBrokerInstalled() {
                note("agentmail CLI (key broker) not installed — inbox context/alerts still work; email ACTIONS need it (`briglia setup`, toolchain step). A bare agentmail binary from npm/brew cannot authenticate: Briglia never puts the key in bash environments")
            } else if let installed = AgentMailService.installedCLIVersion(), installed != AgentMailService.pinnedVersion {
                note("agentmail CLI \(installed) installed (key broker); Briglia pins \(AgentMailService.pinnedVersion) — `briglia agentmail upgrade` moves it (prompt examples follow the installed version either way)")
            } else {
                note("agentmail CLI \(AgentMailService.pinnedVersion) installed (key broker, pinned version)")
            }
            let foreign = AgentMailService.foreignAgentMailInstalls()
            if !foreign.isEmpty {
                note("foreign agentmail install at \(foreign.joined(separator: ", ")) — no access to Briglia's key; may shadow Briglia's wrapper depending on PATH order")
            }
        case .gws:
            if !GoogleWorkspaceService.gwsInstalled() {
                note("email/calendar: gws selected but the binary is not installed — `briglia setup`, toolchain step")
            } else if await GoogleWorkspaceService.shared.gwsUsable() {
                note("gws (Google Workspace) installed and authorized — email/calendar context enabled")
            } else {
                note("gws (Google Workspace) installed but NOT authorized — email/calendar context stays disabled until `gws auth login` + Briglia restart")
            }
        }

        if online {
            print("\nOnline probes")
            if !baseURL.isEmpty && !model.isEmpty {
                let failure: String?
                if let context = ResponsesAuxiliary.inheritedSnapshot(lane: .probe(UUID()), effortOverride: ResponsesAdapter.probeEffort(model: model)) {
                    do { _ = try await ResponsesAuxiliary.text(context: context, messages: [("user", "Reply OK.")], maxOutputTokens: 2048); failure = nil }
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
            case .gws where GoogleWorkspaceService.gwsInstalled():
                let authorized = await GoogleWorkspaceService.shared.verifyGwsAccess()
                check("gws authorized", ok: authorized,
                      hint: "run `gws auth login` — until then email/calendar context is empty")
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
