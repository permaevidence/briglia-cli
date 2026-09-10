import ArgumentParser
import Foundation

// MARK: - `briglia setup`

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Interactive setup wizard: providers, keys, permissions, channels."
    )

    @Flag(name: .customLong("quick"), help: "Run the browser-based quick setup instead (same as `briglia quicksetup`).")
    var quick = false

    func run() async throws {
        AdaCLI.prepareIO()
        try IdentityMigration.gateMutatingEntry()
        IdentityMigration.warnLegacyEnvironment()
        if quick {
            try await QuickSetupSession.runInteractive()
            return
        }
        try await SetupWizard().run()
    }
}

/// The CLI setup wizard. Follows Ada.app's onboarding step order with the
/// CLI-specific changes agreed on 2026-08-03: OpenCode
/// Go or any OpenAI-compatible endpoint for the main agent; ONE OpenAI key
/// covering web research, transcription, image generation and OCR; Serper;
/// Jina; the user's name (assistant is always Briglia); keep-awake + Full Disk
/// Access; optional toolchain; optional Telegram. English throughout.
///
/// UX borrows from the proven claude-plugins wizard: numbered steps, inline
/// validation probes on entry, masked key previews, and a section-jump menu
/// on reruns. Values are saved as each step succeeds, and the step in
/// progress is tracked, so an interrupted first run (Ctrl-C, or the terminal
/// relaunch macOS forces after granting Full Disk Access) offers to resume
/// where it stopped instead of starting over.
@MainActor
struct SetupWizard {
    // Setup state lives in the same file-backed store as the values it gates
    // (secrets.json, XDG-aware), not UserDefaults: macOS UserDefaults ignores
    // a HOME override, so file storage is what keeps scripted test runs from
    // touching a real installation. Installs configured before this existed
    // only have the legacy UserDefaults flag, which is still honored.
    // Shared with `briglia setup-api` (SetupAPICommand.swift) — the GUI setup
    // surface reads and writes the same completion state. nonisolated: the
    // wizard type is @MainActor, but these touch only KeychainHelper (its
    // own lock) and UserDefaults.
    nonisolated static let completeKey = "cli_setup_complete"
    nonisolated static let progressKey = "cli_setup_step_in_progress"
    private nonisolated static let legacyCompleteFlag = "ada.cli.setupComplete"

    /// `legacyDefaults` is a seam for setup-api's selftest — production
    /// callers use the machine's real defaults for the legacy flag.
    nonisolated static func setupComplete(legacyDefaults: UserDefaults = .standard) -> Bool {
        if KeychainHelper.load(key: completeKey) == "true" { return true }
        if ProcessInfo.processInfo.environment["BRIGLIA_IGNORE_LEGACY_SETUP_FLAG"] != nil { return false }
        return legacyDefaults.bool(forKey: legacyCompleteFlag)
    }

    #if os(macOS)
    private static let permissionsStepTitle = "Permissions (keep-awake, Full Disk Access)"
    #else
    private static let permissionsStepTitle = "Permissions (keep-awake)"
    #endif

    private let steps: [(title: String, run: (SetupWizard) async -> Void)] = {
        var list: [(title: String, run: (SetupWizard) async -> Void)] = [
            ("Main agent model", { await $0.stepMainAgent() }),
            ("OpenAI key (research, voice, images, OCR)", { await $0.stepOpenAI() }),
            ("Serper key (web search)", { await $0.stepSerper() }),
            ("Jina key (page reading)", { await $0.stepJina() }),
            ("Your name", { await $0.stepName() }),
            (SetupWizard.permissionsStepTitle, { await $0.stepPermissions() }),
            ("Briglia's toolchain (optional)", { await $0.stepToolchain() }),
            ("Telegram (optional)", { await $0.stepTelegram() }),
        ]
        #if os(Linux)
        // Last on purpose: the service runs `briglia daemon`, which needs the
        // Telegram step already done.
        list.append(("Always-on background service (optional)", { await $0.stepService() }))
        #endif
        return list
    }()

    func run() async throws {
        if Self.setupComplete() {
            await rerunMenu()
            return
        }

        var startIndex = 0
        if let saved = KeychainHelper.load(key: Self.progressKey), saved.hasPrefix("quick:") {
            print("""

            A quick setup (`briglia quicksetup`) was interrupted; run it again to
            continue where it stopped — everything already verified is saved.
            """)
            if !WizardIO.askYesNo("Use this step-by-step wizard instead?", default: false) {
                print("Run: briglia quicksetup")
                return
            }
        } else if let saved = KeychainHelper.load(key: Self.progressKey),
           let interrupted = Int(saved), (1..<steps.count).contains(interrupted) {
            print("""

            A previous setup run stopped at step \(interrupted + 1) of \(steps.count)
            (\(steps[interrupted].title)) — everything before it is saved.
            """)
            if WizardIO.askYesNo("Resume from step \(interrupted + 1)?", default: true) {
                startIndex = interrupted
            }
        }

        if startIndex == 0 {
            print("""

            ── Briglia CLI setup ─────────────────────────────────────────
            \(steps.count) steps, about 5 minutes. Keys are validated as you paste
            them and stored in ~/.config/briglia/secrets.json (owner-only
            permissions). Press Ctrl-C to abort at any time; finished
            steps stay saved.
            """)
        }
        for index in startIndex..<steps.count {
            // Marked before the step runs, so dying mid-step re-offers
            // exactly this step on the next `briglia setup`.
            save(Self.progressKey, String(index))
            printHeader(index: index + 1, total: steps.count, title: steps[index].title)
            await steps[index].run(self)
        }
        try? KeychainHelper.delete(key: Self.progressKey)
        save(Self.completeKey, "true")
        printSummary()
        print("\nSetup complete. Start chatting with `briglia`, or run `briglia daemon` for Telegram-only mode.")
    }

    private func rerunMenu() async {
        print("\nBriglia is already configured. Pick a section to change (Enter to exit):\n")
        for (index, step) in steps.enumerated() {
            print("  \(index + 1). \(step.title)")
        }
        let summaryChoice = steps.count + 1
        print("  \(summaryChoice). Show current configuration")
        while true {
            let choice = WizardIO.ask("\nSection [1-\(summaryChoice)]")
            guard !choice.isEmpty else { return }
            if choice == String(summaryChoice) { printSummary(); continue }
            guard let number = Int(choice), (1...steps.count).contains(number) else {
                print("  Please enter a number from 1 to \(summaryChoice).")
                continue
            }
            let step = steps[number - 1]
            printHeader(index: number, total: steps.count, title: step.title)
            await step.run(self)
        }
    }

    private func printHeader(index: Int, total: Int, title: String) {
        print("\n[\(index)/\(total)] \(title)")
        print(String(repeating: "─", count: 58))
    }

    // MARK: Step 1 — main agent (provider profiles)

    private func stepMainAgent() async {
        ProviderProfiles.ensureMigrated()
        // A resumed or re-run setup with a working main agent shouldn't force
        // re-entering it — offer to keep what's saved.
        if Self.mainAgentConfigured(),
           WizardIO.askYesNo("Main agent already configured: \(currentMainAgentDescription()). Keep it?", default: true) {
            print("  ✔ keeping the current main agent")
            return
        }
        // Loop until a main agent is actually persisted: Briglia cannot run
        // without one, and a declined "Save anyway?" on the custom-endpoint
        // path must not let setup fall through to "Setup complete."
        while true {
            await runProviderMenu()
            if Self.mainAgentConfigured() { return }
            print("\n  Briglia cannot run without a main model — let's try again (Ctrl-C aborts setup).")
        }
    }

    private func currentMainAgentDescription() -> String {
        guard let active = ProviderProfiles.activeProfile() else { return "?" }
        let model = ProviderProfiles.configuredModel(active) ?? "?"
        return active == .opencode ? "\(model) on OpenCode Go"
            : "\(model) via \(active.displayName)"
    }

    /// True when a usable main-agent configuration is persisted.
    static func mainAgentConfigured() -> Bool {
        if let active = ProviderProfiles.activeProfile() {
            return ProviderProfiles.isConfigured(active)
        }
        // Pre-profile installs that somehow dodged migration: honor the
        // legacy runtime slots so an upgrade never claims "unconfigured".
        guard let provider = KeychainHelper.load(key: KeychainHelper.llmProviderKey),
              !provider.isEmpty else { return false }
        let modelKey = provider == LLMProvider.lmStudio.rawValue
            ? KeychainHelper.lmStudioModelKey
            : KeychainHelper.openAICompatibleModelKey
        return !(KeychainHelper.load(key: modelKey) ?? "").isEmpty
    }

    /// Multi-provider menu: configure any subset of the four providers, then
    /// pick which one is active. Hop later anytime with /provider.
    // Inject only terminal input and network work in the offline wizard test;
    // lease ownership, profile persistence and activation use the real path.
    func configureSubscription(login: SubscriptionLogin = SubscriptionLogin(),
        ask: (String, String?) -> String = { WizardIO.ask($0, default: $1) },
        probeRequest: (([String: Any]) async -> [String: Any])? = nil) async -> Bool {
        print("ChatGPT subscription runs the main agent. Web search, voice and image tools retain separate API billing.")
        let setup = SubscriptionSetup()
        let lease: InstanceLease
        switch InstanceLease.acquire(label: "ChatGPT setup") {
        case .success(let held): lease = held
        case .failure: print("Stop Briglia before configuring ChatGPT, then retry setup."); return false
        }
        defer { lease.release() }
        do {
            let state = try SubscriptionAuthStore().read()
            let signedIn = state?.credential != nil && state?.requiresLogin != true
            print(signedIn ? "ChatGPT: signed in (quota unknown)." : "ChatGPT: sign-in required.")
            let action = ask("Account action: keep, login, or logout", signedIn ? "keep" : "login").lowercased()
            if action == "logout" {
                try await SubscriptionAuthStore().logout()
                print("ChatGPT signed out locally. Your subscription is unchanged.")
                return false
            }
            guard action == "keep" || action == "login" else { print("Unknown account action."); return false }
            if !signedIn || action == "login" {
                _ = try await login.device { url, code in
                    print("Open \(url) and enter code: \(code). Enable device login in ChatGPT security settings if needed.")
                }
            }
            let model = ask("Model", ProviderProfiles.configuredModel(.chatgpt) ?? "gpt-5.6-luna")
            let effort = ask("Reasoning effort", ProviderProfiles.configuredEffort(.chatgpt) ?? "high")
            let request: [String: Any] = ["action": "probe", "model": model, "effort": effort]
            let probe: [String: Any]
            if let probeRequest { probe = await probeRequest(request) }
            else { probe = await setup.perform(request, ownsLease: true) }
            guard probe["ok"] as? Bool == true else { print("Connection check failed: \(probe["error"] ?? "unknown error")"); return false }
            let saved = await setup.perform(["action": "select", "model": model, "effort": effort,
                "generation": probe["generation"] ?? "", "activate": false], ownsLease: true)
            guard saved["ok"] as? Bool == true else { print("Could not save ChatGPT: \(saved["error"] ?? "unknown error")"); return false }
            activateAfterConfiguring(.chatgpt)
            return true
        } catch { print("ChatGPT login failed: \(error.localizedDescription)"); return false }
    }

    private func runProviderMenu() async {
        while true {
            print("""

            Briglia's main brain. You can configure SEVERAL providers and hop
            between them anytime with the /provider command. Recommended:
            OpenCode Go — one subscription key, generous limits.
            """)
            let profiles = ProviderProfiles.Profile.allCases
            for (index, profile) in profiles.enumerated() {
                let hint: String
                switch profile {
                case .opencode: hint = "OpenCode Go (recommended)"
                case .openrouter: hint = "OpenRouter (pay-per-token, any model)"
                case .custom: hint = "Custom OpenAI-compatible endpoint (with API key)"
                case .chatgpt: hint = "ChatGPT subscription — sign in with your account"
                case .openai: hint = "OpenAI Platform API — Responses (separate API billing)"
                case .local: hint = "Local server — vLLM, Ollama, LM Studio (no key)"
                }
                let status: String
                if ProviderProfiles.isConfigured(profile) {
                    let model = ProviderProfiles.configuredModel(profile) ?? "?"
                    let active = ProviderProfiles.activeProfile() == profile ? " [active]" : ""
                    status = " — configured: \(model)\(active)"
                } else {
                    status = ""
                }
                print("  \(index + 1). \(hint)\(status)")
            }
            let choice = WizardIO.ask("Configure which? [1]", default: "1")
            guard let number = Int(choice), profiles.indices.contains(number - 1) else {
                print("  Please enter a number from 1 to \(profiles.count).")
                continue
            }
            let profile = profiles[number - 1]
            let saved: Bool
            switch profile {
            case .opencode: saved = await configureOpenCode()
            case .openrouter: saved = await configureOpenRouter()
            case .custom: saved = await configureCustomEndpoint()
            case .chatgpt: saved = await configureSubscription()
            case .openai: saved = await configureOpenAIResponses()
            case .local: saved = await configureLocalEndpoint()
            }
            if saved && profile != .chatgpt { activateAfterConfiguring(profile) }

            let anotherDefault = !Self.mainAgentConfigured()
            if !WizardIO.askYesNo("Configure another provider?", default: anotherDefault) { break }
        }
        offerActiveProviderChoice()
    }

    /// A freshly configured profile becomes active automatically when nothing
    /// else is; otherwise the user chooses whether to switch to it now.
    private func activateAfterConfiguring(_ profile: ProviderProfiles.Profile) {
        let current = ProviderProfiles.activeProfile()
        let makeActive = current == nil || current == profile
            || WizardIO.askYesNo("Make \(profile.displayName) the ACTIVE provider now?", default: true)
        guard makeActive else { return }
        do {
            try ProviderProfiles.activate(profile)
            print("  ✔ Active provider: \(profile.displayName)")
        } catch {
            print("  ✖ Could not activate \(profile.displayName): \(ProviderProfiles.describeActivationError(error))")
        }
    }

    /// After the configure loop: if several profiles exist, confirm which one
    /// is active so the user leaves the step knowing exactly what runs.
    private func offerActiveProviderChoice() {
        let configured = ProviderProfiles.Profile.allCases.filter { ProviderProfiles.isConfigured($0) }
        guard configured.count > 1, let current = ProviderProfiles.activeProfile() else { return }
        print("\nConfigured providers:")
        for line in ProviderProfiles.statusLines() { print("  \(line)") }
        let names = configured.map(\.rawValue).joined(separator: "|")
        let answer = WizardIO.ask("Active provider (\(names)) [\(current.rawValue)]", default: current.rawValue)
        guard answer != current.rawValue,
              let chosen = ProviderProfiles.Profile(rawValue: answer.lowercased()) else { return }
        var lease: InstanceLease?
        if chosen == .chatgpt {
            switch InstanceLease.acquire(label: "ChatGPT setup selection") {
            case .success(let held): lease = held
            case .failure: print("Stop Briglia before selecting ChatGPT."); return
            }
        }
        defer { lease?.release() }
        do {
            try ProviderProfiles.activate(chosen)
            print("  ✔ Active provider: \(chosen.displayName)")
        } catch {
            print("  ✖ \(ProviderProfiles.describeActivationError(error))")
        }
    }

    /// Returns true when the profile was saved.
    private func configureOpenCode() async -> Bool {
        let key = await WizardIO.askSecretValidated(
            "OpenCode Go API key",
            current: KeychainHelper.load(key: ProviderProfiles.opencodeApiKeyKey),
            probe: { await Probes.chatCompletion(baseURL: OpenCodeGo.baseURL, apiKey: $0,
                                                 model: OpenCodeGo.defaultModel,
                                                 fallbackModels: OpenCodeGo.probeFallbacks) }
        )
        print("\nModel (all included in the subscription):")
        for (index, model) in OpenCodeGo.choices.enumerated() {
            let marks = [
                model.id == OpenCodeGo.defaultModel ? "default" : nil,
                model.textOnly ? "text-only" : "vision",
            ].compactMap { $0 }.joined(separator: ", ")
            print("  \(index + 1). \(model.label) (\(marks))")
        }
        let modelChoice = WizardIO.ask("Model [1]", default: "1")
        let selected = Int(modelChoice).flatMap { OpenCodeGo.choices.indices.contains($0 - 1) ? OpenCodeGo.choices[$0 - 1] : nil }
            ?? OpenCodeGo.choices[0]
        saveProfile(.opencode, apiKey: key, baseURL: nil, model: selected.id,
                    effort: "high", textOnly: selected.textOnly)
        print("  ✔ OpenCode Go: \(selected.label)")
        return true
    }

    /// Returns true when the profile was saved.
    private func configureOpenRouter() async -> Bool {
        print("""
        OpenRouter routes to any model on openrouter.ai, billed per token.
        Create a key at https://openrouter.ai/keys
        """)
        let currentModel = KeychainHelper.load(key: KeychainHelper.openRouterModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultModel = currentModel.isEmpty ? "google/gemini-3-flash-preview" : currentModel
        let model = WizardIO.ask("Model ID (e.g. moonshotai/kimi-k3) [\(defaultModel)]", default: defaultModel)
        let key = await WizardIO.askSecretValidated(
            "OpenRouter API key",
            current: KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey),
            probe: { await Probes.chatCompletion(baseURL: "https://openrouter.ai/api/v1", apiKey: $0, model: model) }
        )
        let textOnly = !WizardIO.askYesNo("Can this model see images (vision)?", default: true)
        if textOnly { printTextOnlyWarning() }
        saveProfile(.openrouter, apiKey: key, baseURL: nil, model: model,
                    effort: "high", textOnly: textOnly)
        print("  ✔ OpenRouter: \(model)")
        return true
    }

    /// Returns true when the profile was saved.
    private func configureOpenAIResponses() async -> Bool {
        let model = WizardIO.askNonEmpty("OpenAI model ID")
        let key = await WizardIO.askSecretValidated("OpenAI Platform API key",
            current: KeychainHelper.load(key: ProviderProfiles.openaiApiKeyKey),
            probe: { await Probes.responses(baseURL: "https://api.openai.com/v1", apiKey: $0, model: model) })
        let textOnly = !WizardIO.askYesNo("Can this model see images (vision)?", default: false)
        saveProfile(.openai, apiKey: key, baseURL: nil, model: model, effort: nil, textOnly: textOnly)
        return true
    }

    private func configureCustomEndpoint() async -> Bool {
        let baseURL = WizardIO.askNonEmpty("Base URL (e.g. https://api.example.com/v1)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = WizardIO.askNonEmpty("Model ID (as the endpoint expects it)")
        let protocolChoice: ProviderWireProtocol = WizardIO.askYesNo(
            "Use the Responses protocol? (No uses Chat Completions)",
            default: ProviderProfiles.wireProtocol(.custom) == .responses) ? .responses : .chatCompletions
        print("This provider needs an API key — for a keyless local server use the Local option instead.")
        let key = await WizardIO.askSecretValidated(
            "API key",
            current: KeychainHelper.load(key: ProviderProfiles.customApiKeyKey),
            probe: { key in
                if protocolChoice == .responses { return await Probes.responses(baseURL: baseURL, apiKey: key, model: model) }
                return await Probes.chatCompletion(baseURL: baseURL, apiKey: key, model: model)
            }
        )
        let textOnly = !WizardIO.askYesNo("Can this model see images (vision)?", default: false)
        if textOnly { printTextOnlyWarning() }
        saveProfile(.custom, apiKey: key, baseURL: baseURL, model: model,
                    effort: protocolChoice == .responses ? nil : "high", textOnly: textOnly, wireProtocol: protocolChoice)
        print("  ✔ Custom endpoint: \(model) at \(baseURL)")
        return true
    }

    /// Returns true when the profile was saved.
    private func configureLocalEndpoint() async -> Bool {
        let currentURL = KeychainHelper.load(key: KeychainHelper.lmStudioBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultURL = currentURL.isEmpty ? "http://localhost:1234/v1" : currentURL
        let baseURL = WizardIO.ask("Base URL [\(defaultURL)]", default: defaultURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = WizardIO.askNonEmpty("Model ID (as the server expects it)")

        print("  probing endpoint…", terminator: " ")
        if let failure = await Probes.chatCompletion(baseURL: baseURL, apiKey: nil, model: model) {
            print("✖ \(failure)")
            guard WizardIO.askYesNo("Save anyway?", default: false) else {
                print("  Not saved — run this section again when the server is reachable.")
                return false
            }
        } else {
            print("✔")
        }
        let textOnly = !WizardIO.askYesNo("Can this model see images (vision)?", default: false)
        if textOnly { printTextOnlyWarning() }
        saveProfile(.local, apiKey: nil, baseURL: baseURL, model: model,
                    effort: nil, textOnly: textOnly)
        print("  ✔ Local server: \(model) at \(baseURL)")
        return true
    }

    private func printTextOnlyWarning() {
        print("""
          ⚠ Text-only model: images and scanned PDFs will need the OCR
            preprocessor, which runs on your OpenAI key (next step).
        """)
    }

    /// saveProfile with the wizard's fail-fast persistence contract.
    private func saveProfile(
        _ profile: ProviderProfiles.Profile,
        apiKey: String?,
        baseURL: String?,
        model: String,
        effort: String?,
        textOnly: Bool,
        wireProtocol: ProviderWireProtocol? = nil
    ) {
        do {
            try ProviderProfiles.saveProfile(profile, apiKey: apiKey, baseURL: baseURL,
                                             model: model, effort: effort, textOnly: textOnly, wireProtocol: wireProtocol)
        } catch {
            reportFatalSaveFailure(error)
        }
    }

    // MARK: Step 2 — OpenAI

    private func stepOpenAI() async {
        print("""
        One OpenAI API key powers four things:
          • web research (planning, reading, and writing answers)
          • voice message transcription (gpt-transcribe)
          • image generation (GPT Image 2.5)
          • OCR of scanned documents
        Create a key at https://platform.openai.com/api-keys
        """)
        let key = await WizardIO.askSecretValidated(
            "OpenAI API key",
            current: KeychainHelper.load(key: KeychainHelper.openAITranscriptionApiKeyKey),
            probe: { await Probes.openAI(apiKey: $0) }
        )

        UserDefaults.standard.set(WebSearchBackend.openai.rawValue, forKey: WebSearchBackend.selectionKey)
        save(KeychainHelper.webSearchOpenAIApiKeyKey, key)
        save(KeychainHelper.voiceTranscriptionProviderKey, VoiceTranscriptionProvider.openAI.rawValue)
        save(KeychainHelper.openAITranscriptionApiKeyKey, key)
        save(KeychainHelper.imageGenerationProviderKey, ImageGenerationProvider.openAI.rawValue)
        save(KeychainHelper.openAIImageApiKeyKey, key)
        save(KeychainHelper.visionPreprocessorBackendKey, "openai")
        print("  ✔ OpenAI configured for research, voice, images and OCR")
    }

    // MARK: Steps 3–4 — Serper & Jina

    private func stepSerper() async {
        print("Serper gives Briglia Google search. Free tier: 2,500 queries — https://serper.dev")
        let key = await WizardIO.askSecretValidated(
            "Serper API key",
            current: KeychainHelper.load(key: KeychainHelper.serperApiKeyKey),
            probe: { await Probes.serper(apiKey: $0) }
        )
        save(KeychainHelper.serperApiKeyKey, key)
        print("  ✔ Web search enabled")
    }

    private func stepJina() async {
        print("Jina Reader lets Briglia read web pages. Free tier available — https://jina.ai/reader")
        let key = await WizardIO.askSecretValidated(
            "Jina API key",
            current: KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey),
            probe: { await Probes.jina(apiKey: $0) }
        )
        save(KeychainHelper.jinaApiKeyKey, key)
        print("  ✔ Page reading enabled")
    }

    // MARK: Step 5 — name

    private func stepName() async {
        let current = KeychainHelper.load(key: KeychainHelper.userNameKey) ?? ""
        let prompt = current.isEmpty ? "What should Bree call you?" : "What should Bree call you? [\(current)]"
        var name = WizardIO.ask(prompt)
        if name.isEmpty { name = current }
        if !name.isEmpty {
            save(KeychainHelper.userNameKey, name)
        }
        save(KeychainHelper.assistantNameKey, "Bree")
        print("  ✔ Nice to meet you\(name.isEmpty ? "" : ", \(name)")! I'm Bree.")
    }

    // MARK: Step 6 — permissions

    #if os(macOS)
    private func stepPermissions() async {
        // Keep-awake: Briglia holds an idle-sleep assertion while it runs
        // (chat, daemon, quick setup), so no Energy Settings change is
        // needed. Display sleep is harmless; a closed lid or a manual sleep
        // still stops it — say so, once.
        print("  ✔ Keep-awake: Briglia prevents idle system sleep while it runs (display may sleep; a closed lid or manual sleep still stops it)")

        // Full Disk Access for the hosting terminal (the CLI inherits it).
        if PermissionsService.fullDiskAccessGranted() {
            print("  ✔ Full Disk Access granted")
        } else {
            print("""
            Briglia needs Full Disk Access to work on your files. Grant it to the
            TERMINAL app you run `briglia` from (Terminal, iTerm, …):
              1. Opening System Settings → Privacy & Security → Full Disk Access…
              2. Add your terminal app and enable it.
              3. macOS asks to relaunch the terminal — do it, then run
                 `briglia setup` again; it offers to resume from this step,
                 keeping everything you already entered.
            """)
            _ = await GoogleWorkspaceService.runProcessAsync(
                executable: "/usr/bin/open",
                args: ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"],
                timeoutSeconds: 10
            )
            while !PermissionsService.fullDiskAccessGranted() {
                let answer = WizardIO.ask("Press Enter to re-check (or 's' to skip)")
                if answer.lowercased() == "s" { break }
            }
            print(PermissionsService.fullDiskAccessGranted()
                  ? "  ✔ Full Disk Access granted"
                  : "  ⚠ Skipped — Briglia will fail on protected folders until granted")
        }
    }
    #else
    private func stepPermissions() async {
        // No TCC on Linux — file access is plain Unix permissions.
        print("  ✔ Full Disk Access: not needed on Linux (ordinary file permissions apply)")

        // Ubuntu Touch suspends the whole phone on screen-off through
        // repowerd — desktop sleep settings and systemd sleep targets are
        // the wrong lever there. The keep-awake kernel wakelock is offered
        // in the background-service step instead.
        if AgentServiceSupport.isUbuntuTouch() {
            print("""
              ⚠ Ubuntu Touch: the phone suspends when the screen turns off.
                The final setup step handles this with a keep-awake service —
                nothing to do here.
            """)
            return
        }

        // Keep-awake: automatic suspend is the one thing that silently stops
        // an unattended agent. The verdict is evidence-based (plan §4.6):
        // it never infers safety from missing information, so an unknown
        // desktop says "may suspend" instead of silently passing.
        let verdict = PermissionsService.autoSuspendVerdict()
        if verdict.isOK {
            print("  ✔ \(verdict.summary)")
            return
        }
        print("""
        ⚠ This machine \(verdict.summary).
          A suspended machine stops Briglia completely — reminders, Telegram and
          background tasks all go silent.
        """)

        if case .maySuspend(let reason) = verdict, reason.hasPrefix("GNOME auto-suspend is on") {
            // GNOME with readable gsettings: offer the one-command fix.
            if WizardIO.askYesNo("Disable automatic suspend now (gsettings, no sudo needed)?", default: true) {
                if PermissionsService.disableGnomeAutoSuspend() {
                    let after = PermissionsService.autoSuspendVerdict()
                    print(after.isOK ? "  ✔ \(after.summary)" : "  ✖ still \(after.summary)")
                } else {
                    print("  ✖ gsettings write failed — disable suspend manually in your desktop's power settings.")
                }
                return
            }
        }

        print("""
          Options:
          • Desktop: disable automatic suspend in your power settings.
          • Dedicated/headless box: mask the systemd sleep targets so the
            machine can never suspend (recommended for an always-on Briglia):
              \(AutoSuspendCensus.Verdict.maskCommand)
        """)
        if WizardIO.askYesNo("Mask the systemd sleep targets now (asks for sudo)?", default: false) {
            if PermissionsService.maskLinuxSleepTargets() {
                print("  ✔ Sleep targets masked — this machine will not suspend")
            } else {
                print("  ✖ Masking failed (sudo declined?) — run the command above manually.")
            }
        } else {
            print("  ⚠ Left as-is — Briglia will stop whenever the machine suspends.")
        }
    }
    #endif

    // MARK: Step 9 (Linux) — always-on background service

    #if os(Linux)
    private func stepService() async {
        guard TelegramConfig.isConfigured else {
            print("""
              Skipped — the service runs `briglia daemon`, which needs the Telegram
              channel (previous step). Set it up any time later with:
                briglia service install
            """)
            return
        }
        let isUT = AgentServiceSupport.isUbuntuTouch()
        if isUT {
            print("""
              Recommended on Ubuntu Touch: the Terminal app's processes are
              frozen when the screen turns off, so Briglia must run as a systemd
              service to stay reachable over Telegram.
            """)
        } else {
            print("""
              Runs `briglia daemon` as a systemd user service: starts at boot,
              restarts after crashes, keeps working after you log out.
              Ideal for a Raspberry Pi or an always-on box.
            """)
        }
        guard WizardIO.askYesNo("Install and start the service now?", default: isUT) else {
            print("  Skipped — set it up any time with: briglia service install")
            return
        }
        _ = AgentServiceSupport.installUserService()
        AgentServiceSupport.offerUbuntuTouchKeepAwake()
    }
    #endif

    // MARK: Step 7 — toolchain (optional)

    private func stepToolchain() async {
        #if os(Linux)
        // Not optional on Linux: the media pipeline (PDF reading/OCR, image
        // downscaling) runs on poppler and ImageMagick instead of PDFKit;
        // ffmpeg covers audio extraction for transcription and video work.
        let popplerOK = ["pdfinfo", "pdftotext", "pdftoppm", "pdfseparate", "pdfunite"]
            .allSatisfy { PlatformBinary.find($0) != nil }
        let magickOK = PlatformBinary.find("magick") != nil
            || (PlatformBinary.find("identify") != nil && PlatformBinary.find("convert") != nil)
        let ffmpegOK = PlatformBinary.find("ffmpeg") != nil
            && PlatformBinary.find("ffprobe") != nil
        if AgentServiceSupport.isUbuntuTouch() {
            // Ubuntu Touch: ~3 GB read-only rootfs that apt can fill and
            // OTA updates wipe. The userdata-prefix installer avoids all of
            // that (no sudo, nothing on the rootfs, survives OTA), so the
            // core trio installs AUTOMATICALLY — no question, nothing to
            // approve (the owner's decision 2026-08-29). Optional extras
            // (pandoc, LibreOffice) stay opt-in.
            if popplerOK && magickOK && ffmpegOK {
                print("  ✔ Media pipeline ready (poppler-utils + ImageMagick + ffmpeg)")
            } else {
                print("""
                  Installing Briglia's media tools (PDF reading, images, audio/video for
                  transcription) to the USERDATA partition: no sudo, the tiny
                  read-only rootfs is never touched, and they survive OS updates.
                """)
                let report = await Task.detached(priority: .userInitiated) {
                    UserdataToolchain.installSync(includePandoc: false) {
                        print("  \($0)")
                    }
                }.value
                if report.ok {
                    print("  ✔ Media toolchain ready"
                          + (report.wrappers.isEmpty ? ""
                             : " (\(report.wrappers.count) tools on userdata)"))
                } else {
                    for failure in report.failures { print("  ✖ \(failure)") }
                    print("  Retry any time with: briglia toolchain install")
                }
            }
        } else if popplerOK && magickOK {
            print("  ✔ Media pipeline ready (poppler-utils + ImageMagick)")
        } else {
            var needed: [String] = []
            if !popplerOK { needed.append("poppler-utils") }
            if !magickOK { needed.append("imagemagick") }
            print("""
            ⚠ Briglia needs \(needed.joined(separator: " and ")) on Linux — without them
              it cannot read PDFs or handle images.
            """)
            if let manager = ToolchainService.linuxPackageManager(),
                      WizardIO.askYesNo("Install now via \(manager.name) (asks for sudo)?", default: true) {
                for pkg in needed {
                    print("  installing \(pkg)…")
                    if let failure = await ToolchainService.installLinuxPackage(pkg) {
                        print("  ✖ \(pkg): \(failure)")
                    } else {
                        print("  ✔ \(pkg)")
                    }
                }
            } else {
                print("  ⚠ Skipped — install manually, e.g. sudo apt install \(needed.joined(separator: " "))")
            }
        }
        #endif
        await configureEmailCalendar()
        print("""
        Optional helpers for documents and media (PDF/DOCX/XLSX generation,
        video editing). Briglia works without them; install now or any time later.
        """)
        guard WizardIO.askYesNo("Check the toolchain now?", default: false) else {
            print("  Skipped.")
            return
        }
        guard let report = ToolchainService.runDoctor() else {
            #if os(macOS)
            print("  ⚠ python3 not found — install Xcode Command Line Tools or Homebrew python first.")
            #else
            print("  ⚠ python3 not found — install it first, e.g. sudo apt install python3 python3-pip.")
            #endif
            return
        }
        for entry in report.present { print("  ✔ \(ToolchainService.displayName(for: entry))") }
        for entry in report.missing { print("  ✖ \(ToolchainService.displayName(for: entry)) — \(entry.impact)") }
        let installable = ToolchainService.uniqueInstallTargets(report.missing.filter { ToolchainService.autoInstallable($0) })
        if !installable.isEmpty,
           WizardIO.askYesNo("Install the \(installable.count) missing item(s) automatically?", default: true) {
            for entry in installable {
                print("  installing \(ToolchainService.displayName(for: entry))…", terminator: " ")
                if let failure = await ToolchainService.install(entry, pipBreakSystemPackages: true) {
                    print("✖ \(failure)")
                } else {
                    print("✔")
                }
            }
        }
        if !ToolchainService.libreOfficePresent(),
           WizardIO.askYesNo("Install LibreOffice too (~600 MB, used to render DOCX/XLSX)?", default: false) {
            print("  installing LibreOffice…", terminator: " ")
            if let failure = await ToolchainService.installLibreOffice() {
                print("✖ \(failure)")
            } else {
                print("✔")
            }
        }
    }

    /// Optional email + calendar. Three providers: AgentMail (dedicated agent
    /// inbox + Briglia's local calendar, recommended), Google Workspace via the
    /// `gws` CLI (user's own Gmail/Calendar, user-provided OAuth client), or
    /// none (the default — no email/calendar context, polling, or tool).
    private func configureEmailCalendar() async {
        let current = EmailCalendarProvider.current
        print("""

        Email & calendar (optional). Briglia can watch an inbox (new-mail alerts,
        unread snapshot in its context) and keep a calendar (daily agenda).
          1) AgentMail — a dedicated inbox for Briglia (recommended, easy):
             sign up at https://agentmail.to, create an inbox + API key,
             paste the key here. Includes Briglia's own calendar tool.
          2) Google Workspace — YOUR Gmail/Calendar via Google's `gws` CLI
             (advanced: requires your own Google Cloud OAuth client).
          3) None — no email or calendar context.
          Current: \(current.displayName)
        """)
        let defaultChoice: String
        switch current {
        case .agentmail: defaultChoice = "1"
        case .gws: defaultChoice = "2"
        case .none: defaultChoice = "3"
        }
        var choice = ""
        while true {
            choice = WizardIO.ask("Choose [1/2/3]", default: defaultChoice)
            if ["1", "2", "3"].contains(choice) { break }
            print("  Enter 1, 2 or 3.")
        }
        switch choice {
        case "1":
            await configureAgentMail()
        case "2":
            await configureGoogleWorkspace()
        default:
            save(KeychainHelper.emailCalendarProviderKey, EmailCalendarProvider.none.rawValue)
            if current != .none {
                print("  ✔ email/calendar disabled — takes effect the next time Briglia starts")
            } else {
                print("  ✔ no email/calendar — enable any time by rerunning `briglia setup`")
            }
        }
    }

    private func configureAgentMail() async {
        print("""
          AgentMail gives Briglia its own inbox. If you don't have a key yet:
          https://agentmail.to → create an inbox → API keys → create one.
        """)
        let key = await WizardIO.askSecretValidated(
            "AgentMail API key",
            current: KeychainHelper.load(key: KeychainHelper.agentMailApiKeyKey),
            probe: { await AgentMailService.probeKey($0).failure }
        )
        // Re-probe once to capture the inbox address (cheap; also covers the
        // Enter-keeps-saved-key path, which skips the probe).
        let (failure, inboxes) = await AgentMailService.probeKey(key)
        if let failure {
            print("  ⚠ could not list inboxes right now (\(failure)) — continuing; Briglia retries at runtime")
        }
        save(KeychainHelper.agentMailApiKeyKey, key)
        if let inbox = inboxes.first {
            save(KeychainHelper.agentMailInboxAddressKey, inbox)
            print("  ✔ Briglia's inbox: \(inbox)")
        }
        save(KeychainHelper.emailCalendarProviderKey, EmailCalendarProvider.agentmail.rawValue)

        if AgentMailService.agentMailBrokerInstalled() {
            print("  ✔ agentmail CLI (key broker) already installed")
        } else {
            // A bare `agentmail` binary here (pre-broker install, npm, brew)
            // cannot authenticate — Briglia never puts the key in bash envs. The
            // installer overwrites ~/.local/bin/agentmail with the broker
            // wrapper, migrating any legacy Briglia install in place.
            if WizardIO.askYesNo("Install the agentmail CLI (~5 MB, lets Briglia read/send email)?", default: true) {
                if let installFailure = await AgentMailService.installAgentMailBinary(progress: { print("  \($0)") }) {
                    print("  ✖ agentmail CLI install failed: \(installFailure)")
                    print("    Inbox alerts and context still work (Briglia polls the API directly);")
                    print("    rerun `briglia setup` later to retry the CLI install.")
                } else {
                    print("  ✔ agentmail CLI installed to ~/.local/bin/agentmail (key broker + binary)")
                }
            } else {
                print("  Skipped the CLI — inbox alerts and context still work; Briglia can use the REST API via curl for actions.")
            }
        }
        let foreign = AgentMailService.foreignAgentMailInstalls()
        if !foreign.isEmpty {
            print("""
              ⚠ another agentmail install exists at \(foreign.joined(separator: ", ")) —
                it has no access to Briglia's key and may shadow Briglia's wrapper
                depending on PATH order. Consider removing it.
            """)
        }
        print("  ✔ AgentMail + calendar configured — activates the next time Briglia starts")
    }

    private func configureGoogleWorkspace() async {
        // 1. OAuth client: Briglia no longer ships one — the user provides their own.
        let secretFileExists = FileManager.default.fileExists(atPath: GoogleWorkspaceService.clientSecretFileURL.path)
        if secretFileExists {
            print("  ✔ found existing ~/.config/gws/client_secret.json — keeping it")
        } else {
            print("""
              gws needs YOUR OWN Google OAuth client (Briglia does not ship one):
                1. console.cloud.google.com → create or select a project
                2. Enable the Gmail API and the Google Calendar API
                3. OAuth consent screen → External → add yourself as a test user
                4. Credentials → Create credentials → OAuth client ID → Desktop app
                5. Paste the client ID and client secret here.
            """)
            let currentID = KeychainHelper.load(key: KeychainHelper.gwsOAuthClientIDKey) ?? ""
            var clientID = ""
            while true {
                clientID = WizardIO.ask(
                    currentID.isEmpty ? "OAuth client ID" : "OAuth client ID [\(currentID)]",
                    default: currentID.isEmpty ? nil : currentID
                )
                if !clientID.isEmpty { break }
                print("  A value is required.")
            }
            let clientSecret = await WizardIO.askSecretValidated(
                "OAuth client secret",
                current: KeychainHelper.load(key: KeychainHelper.gwsOAuthClientSecretKey),
                probe: { _ in nil }  // no offline validation exists; gws auth login is the real probe
            )
            save(KeychainHelper.gwsOAuthClientIDKey, clientID)
            save(KeychainHelper.gwsOAuthClientSecretKey, clientSecret)
            installClientSecret()
        }

        // 2. Binary + authorization.
        if GoogleWorkspaceService.gwsInstalled() {
            if await GoogleWorkspaceService.shared.verifyGwsAccess() {
                print("  ✔ Google Workspace (gws) installed and authorized — email/calendar context enabled")
            } else {
                print("""
                  ⚠ Google Workspace (gws) is installed but not authorized.
                    Run `gws auth login` in another terminal to enable
                    email/calendar context, or ignore this to go without.
                """)
            }
        } else if WizardIO.askYesNo("Install gws now (~6 MB)?", default: true) {
            if let failure = await GoogleWorkspaceService.installGwsBinary() {
                print("  ✖ gws install failed: \(failure)")
                print("    Briglia will run without email/calendar context until it's installed.")
            } else {
                print("""
                  ✔ gws installed. To authorize it, run `gws auth login` in
                    another terminal (opens a browser). Email/calendar context
                    activates the next time Briglia starts.
                """)
            }
        } else {
            print("  Skipped the gws install — rerun `briglia setup` any time.")
        }
        save(KeychainHelper.emailCalendarProviderKey, EmailCalendarProvider.gws.rawValue)
    }

    /// Returns true when the OAuth client file is in place (pre-existing or
    /// freshly written from the stored user-provided credentials).
    @discardableResult
    private func installClientSecret() -> Bool {
        do {
            try GoogleWorkspaceService.installAdaClientSecretIfMissing()
            return true
        } catch {
            print("  ⚠ could not write the gws OAuth client (\(error.localizedDescription)) — `gws auth login` will fail until ~/.config/gws/client_secret.json exists")
            return false
        }
    }

    // MARK: Step 8 — Telegram (optional)

    private func stepTelegram() async {
        if TelegramConfig.isConfigured {
            guard WizardIO.askYesNo("Telegram is already configured — change it?", default: false) else {
                print("  ✔ keeping the current Telegram bot")
                return
            }
        }
        print("""
        Optional: talk to Briglia from your phone via a Telegram bot, and run
        `briglia daemon` for a headless always-on Briglia.
          1. In Telegram, message @BotFather → /newbot → copy the token.
          2. Message @userinfobot to get your numeric chat ID.
        """)
        guard WizardIO.askYesNo("Set up Telegram now?", default: false) else {
            print("  Skipped — rerun `briglia setup` any time to add it.")
            return
        }
        let token = await WizardIO.askSecretValidated(
            "Bot token",
            current: KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey),
            probe: { await Probes.telegram(token: $0) }
        )
        var chatId = ""
        let currentChatId = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey) ?? ""
        while true {
            let prompt = currentChatId.isEmpty
                ? "Your numeric chat ID"
                : "Your numeric chat ID [\(currentChatId)]"
            chatId = WizardIO.ask(prompt, default: currentChatId.isEmpty ? nil : currentChatId)
            if chatId.isEmpty {
                print("  A value is required.")
                continue
            }
            switch TelegramPairing.parseChatId(chatId) {
            case .success:
                break
            case .failure(.notNumeric):
                print("  ✖ A Telegram chat ID is a number (e.g. 164130…). Letters mean it's a username — use @userinfobot.")
                continue
            case .failure(.notPrivate):
                print("  ✖ \(TelegramPairing.privateChatExplanation)")
                continue
            }
            break
        }
        save(KeychainHelper.telegramBotTokenKey, token)
        save(KeychainHelper.telegramChatIdKey, chatId)
        print("  ✔ Telegram connected — messages to your bot reach Briglia while `briglia` or `briglia daemon` is running")
    }

    // MARK: Summary + helpers

    private func printSummary() { Self.printSummaryStatic() }

    /// Shared with `briglia quicksetup`.
    nonisolated static func printSummaryStatic() {
        func mask(_ key: String) -> String {
            guard let value = KeychainHelper.load(key: key), !value.isEmpty else { return "—" }
            return WizardIO.masked(value)
        }
        ProviderProfiles.ensureMigrated()
        let telegram = TelegramConfig.isConfigured ? "configured" : "not configured"
        let providerLines = ProviderProfiles.statusLines()
            .map { "  \($0)" }
            .joined(separator: "\n")
        print("""

        ── Current configuration ─────────────────────────────────
        \(providerLines)
          Text-only mode  \(KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "true" ? "on (OCR via OpenAI)" : "off (native vision)")
          OpenAI key      \(mask(KeychainHelper.openAITranscriptionApiKeyKey))
          Serper key      \(mask(KeychainHelper.serperApiKeyKey))
          Jina key        \(mask(KeychainHelper.jinaApiKeyKey))
          Your name       \(KeychainHelper.load(key: KeychainHelper.userNameKey) ?? "—")
          Email/calendar  \(EmailCalendarProvider.current.displayName)\(EmailCalendarProvider.current == .agentmail && !EmailCalendarProvider.agentMailInboxAddress.isEmpty ? " (\(EmailCalendarProvider.agentMailInboxAddress))" : "")
          Telegram        \(telegram)
          Data            \(StoragePaths.dataRootDisplay)   Config: \(StoragePaths.configRootDisplay)
        """)
    }

    /// A save that fails means NOTHING can persist (read-only config dir,
    /// full disk) — every later step would silently produce a broken install
    /// that only surfaces after restart. Fail fast and loudly instead.
    private func save(_ key: String, _ value: String) {
        do {
            try KeychainHelper.save(key: key, value: value)
        } catch {
            reportFatalSaveFailure(error)
        }
    }

    private func reportFatalSaveFailure(_ error: Error) -> Never {
        print("""

        ✖ Could not write configuration to \(StoragePaths.configRootDisplay)/secrets.json:
          \(error.localizedDescription)
          Fix the directory permissions (or free disk space) and run `briglia setup` again.
          Nothing from this run was saved.
        """)
        Foundation.exit(1)
    }
}

/// The OpenCode Go catalog (carried over from Ada.app's onboarding, where it
/// lived in OnboardingView).
enum OpenCodeGo {
    static let baseURL = "https://opencode.ai/zen/go/v1"
    /// Default since 2026-08-31 (was kimi-k2.6). The wizard's "Model [1]"
    /// default is choices[0], so the default model MUST stay first in the list.
    static let defaultModel = "glm-5.3-flash"
    /// Key-probe fallbacks when the default model's upstream is down
    /// (observed live 2026-08-17: kimi-k2.6 503 while the rest served fine).
    /// Different upstream providers on purpose (Moonshot, MiniMax — neither is
    /// Zhipu like the default); excludes the China-gated one.
    static let probeFallbacks = ["kimi-k2.6", "minimax-m3"]
    /// Ids OpenCode still serves under a name that has since been renamed.
    /// Installs that selected the model before the rename keep the old id
    /// stored; resolve it for catalog lookups (vision state) and doctor hints.
    static let legacyAliases: [String: String] = [
        // v0.2.17 catalog id → models.dev canonical id (renamed 2026-09-10).
        "deepseek-flash": "deepseek-v4.1-flash",
    ]
    /// Catalog entry for an id, following legacy aliases.
    static func catalogEntry(for id: String) -> (id: String, label: String, textOnly: Bool)? {
        let canonical = legacyAliases[id.lowercased()] ?? id
        return choices.first(where: { $0.id == canonical })
    }
    static let choices: [(id: String, label: String, textOnly: Bool)] = [
        // Multimodal sibling of GLM 5.3 with the same reasoning contract:
        // reasoning_content on plain + tool-call turns, replay accepted,
        // implicit prefix caching, reasoning_tokens/cached_tokens in usage,
        // effort restricted to low/high/max. Briglia's 5.3 effort remap and
        // thinking-flag omission match on the "glm-5.3" substring, so both
        // apply automatically. Full vision through the Go gateway (data-URL
        // image parts, layout-describe verified) — verified 2026-08-26.
        ("glm-5.3-flash", "GLM 5.3 Flash", false),
        ("kimi-k2.6", "Kimi K2.6", false),
        // reasoning_content on plain + tool-call turns, replay accepted,
        // implicit prefix caching; effort restricted to low/high/max (Briglia
        // remaps minimal/medium/xhigh), thinking flag must stay omitted,
        // images rejected — verified 2026-08-14, replacing glm-5.2.
        ("glm-5.3", "GLM 5.3", true),
        ("deepseek-v4-pro", "DeepSeek V4 Pro", true),
        // Hosted only in China: without the per-workspace "Chinese models"
        // opt-in on opencode.ai the gateway returns a RegionError. With the
        // opt-in it behaves exactly like V4 Pro (reasoning_content, tool
        // replay, all effort levels; images rejected — verified 2026-08-05).
        ("deepseek-v4-flash", "DeepSeek V4 Flash (requires China opt-in)", true),
        // NOT China-gated, unlike its -flash/-pro siblings. Full vision
        // (data-URL image parts), reasoning_content on plain/tool-call/
        // post-tool turns, tool + reasoning replay accepted, all six effort
        // levels unchanged, thinking:{enabled} honored, implicit prefix
        // caching — verified 2026-08-22. "-exp" = experimental upstream:
        // may be renamed, repriced, or gated later.
        ("deepseek-v4-flash-vision-exp", "DeepSeek V4 Flash Vision (experimental)", false),
        // DeepSeek V4.1 Flash (models.dev opencode-go, released 2026-09-10).
        // It first appeared as the unversioned "deepseek-flash"; models.dev
        // renamed the entry to "deepseek-v4.1-flash" later the same day and
        // the gateway serves both ids (verified: same prompt_tokens, reasoning
        // and vision on both). Installs that picked the model before the
        // rename keep "deepseek-flash" stored; the reasoning predicates still
        // recognize it and `briglia doctor` nudges them to re-select.
        // Same contract as the V4 entries, verified live 2026-09-10 side by side with
        // deepseek-v4-flash-vision-exp: reasoning_content on plain and
        // tool-call turns, replay with/without reasoning_content accepted,
        // all six effort levels unchanged, thinking:{enabled} honored,
        // prefix caching (cached_tokens), full vision through data-URL image
        // parts, reasoning_tokens in usage. $0.15/$0.60 per M tokens, 1M
        // context. Region gating unverified: probed from a workspace that
        // already has the "Chinese models" opt-in.
        ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash", false),
        // Multimodal upstream, but the Go gateway short-circuits image parts
        // (empty synthetic completion, no usage) as of 2026-08-02.
        ("gpt-5.6-luna", "GPT 5.6 Luna", true),
        ("kimi-k2.7-code", "Kimi K2.7 Code", false),
        ("kimi-k3", "Kimi K3", false),
        ("minimax-m3", "MiniMax M3", false),
        // Full vision through the Go gateway (unlike Luna), reasoning_content
        // on plain and tool-call turns, replay with/without reasoning, all
        // effort levels accepted unchanged, long-prefix implicit caching —
        // verified 2026-08-11.
        ("qwen3.8-max", "Qwen 3.8 Max", false),
    ]
}
