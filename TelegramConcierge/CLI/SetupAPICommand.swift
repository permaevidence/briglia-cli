import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif

// MARK: - `briglia setup-api` — machine-readable setup surface for GUI frontends
//
// Hidden JSON-over-stdio counterpart of the interactive wizard, built for the
// Ubuntu Touch companion app. Contract:
//
//   • argv carries ONLY the verb (status | probe | apply | service). Request
//     documents — and any secrets in them — arrive as one JSON object on
//     stdin: argv is visible in /proc/*/cmdline and `ps` even for an
//     unconfined caller, so a key on argv would leak.
//   • stdout carries exactly one JSON response object; every human-readable
//     progress line from reused wizard/service code goes to stderr.
//   • Every response has {"schema": 1, "ok": Bool}. Failures add
//     "error": {"code", "message"}; probe verdicts use "reason" instead
//     (a failed probe is a result, not an API error). Exit code is 0
//     whenever a response was produced; 64 only for transport-level
//     failures (argv payload, unparseable stdin, unknown verb).
//   • Validation, probing and persistence are the wizard's own code paths
//     (Probes, KeychainHelper, ProviderProfiles), so GUI setup can never
//     drift from `briglia setup`. Where the wizard would exit(1) on a failed
//     save, this returns {"error": {"code": "save_failed"}} instead.
//   • Every apply section is re-applicable at any time — there are no
//     "first run only" semantics (this backs the app's Settings screen).

struct SetupAPI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup-api",
        abstract: "Internal: machine-readable setup (JSON on stdin/stdout) for GUI frontends.",
        shouldDisplay: false
    )

    @Argument(help: "status | probe | apply | service | migrate")
    var verb: String

    @Argument(parsing: .remaining, help: .hidden)
    var extra: [String] = []

    func run() async throws {
        AdaCLI.prepareIO()
        // stdout purity: reused wizard/service code prints progress lines
        // (Probes' fallback notice, installUserService, AgentMail install).
        // Redirect fd 1 → stderr for the whole run and write the JSON
        // response to the ORIGINAL stdout at the end, so callers always
        // read exactly one JSON object no matter what the internals print.
        fflush(stdout)
        let realStdout = dup(1)
        dup2(2, 1)
        func respond(_ payload: [String: Any], exitCode: Int32 = 0) -> Never {
            fflush(stdout)
            SetupAPICore.emit(payload, toFileDescriptor: realStdout)
            Foundation.exit(exitCode)
        }

        guard extra.isEmpty else {
            respond(SetupAPICore.transportError(SetupAPICore.argvRefusalMessage), exitCode: 64)
        }
        switch verb {
        case "status":
            respond(await SetupAPICore.status())
        case "migrate":
            // Optional request object ({"rollback": true}); an empty stdin
            // means a forward migration/recovery.
            let data = FileHandle.standardInput.readDataToEndOfFile()
            var request: [String: Any] = [:]
            if !data.isEmpty {
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    respond(SetupAPICore.transportError(
                        "stdin must carry one JSON request object (or nothing)"), exitCode: 64)
                }
                request = object
            }
            respond(SetupAPICore.migrate(request))
        case "probe", "apply", "service", "subscription":
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                respond(SetupAPICore.transportError(
                    "stdin must carry exactly one JSON request object"), exitCode: 64)
            }
            switch verb {
            case "subscription": respond(await SubscriptionSetup().perform(object))
            case "probe": respond(await SetupAPICore.probe(object))
            case "apply": respond(await SetupAPICore.apply(object))
            default: respond(await SetupAPICore.service(object))
            }
        default:
            respond(SetupAPICore.transportError(
                "unknown verb '\(verb)' — expected status | probe | apply | service | migrate"), exitCode: 64)
        }
    }
}

// MARK: - Core (selftest-callable, no process I/O of its own)

enum SetupAPICore {
    static let schemaVersion = 2

    static let argvRefusalMessage =
        "unexpected extra arguments — requests (and any secrets in them) must arrive "
        + "as JSON on stdin, never on argv (argv is world-readable via /proc)"

    /// UserDefaults seam: the selftest points this at a throwaway suite so
    /// web-search-backend and legacy-flag reads/writes never touch the
    /// machine's real preferences (the FileDescriptionsStore lesson —
    /// defer-based restore of real keys does not survive a watchdog exit).
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// gws-directory seam: EmailCredentialWipe deletes ~/.config/gws, which
    /// is HOME-derived — the selftest's XDG redirect does NOT cover it, so
    /// without this seam a selftest run would wipe the machine's REAL gws
    /// tokens. Production leaves it nil (canonical directory).
    nonisolated(unsafe) static var gwsConfigDirectoryOverride: URL?

    struct APIError: Error {
        let code: String
        let message: String
    }

    /// Thrown by an `apply` checkpoint whose authorization was revoked.
    struct CheckpointRevoked: Error {
        let message: String
        init(_ message: String = "this operation was superseded") { self.message = message }
    }

    // MARK: Response plumbing

    private static func base(ok: Bool) -> [String: Any] {
        ["schema": schemaVersion, "ok": ok]
    }

    static func errorResponse(code: String, message: String) -> [String: Any] {
        var payload = base(ok: false)
        payload["error"] = ["code": code, "message": message]
        return payload
    }

    static func transportError(_ message: String) -> [String: Any] {
        errorResponse(code: "transport", message: message)
    }

    private static func saveFailed(_ error: Error) -> APIError {
        APIError(code: "save_failed",
                 message: "could not write \(StoragePaths.configRootDisplay)/secrets.json: "
                 + "\(error.localizedDescription) — fix directory permissions or free disk "
                 + "space; nothing from this section was saved")
    }

    static func emit(_ payload: [String: Any], toFileDescriptor fd: Int32) {
        let data = (try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("""
                {"schema":\(schemaVersion),"ok":false,"error":{"code":"encode_failed",\
                "message":"response was not JSON-encodable"}}
                """.utf8)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data("\n".utf8))
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: status

    static var platformKey: String {
        #if os(Linux)
        #if arch(arm64)
        return "linux-arm64"
        #else
        return "linux-x64"
        #endif
        #else
        return "macos-arm64"
        #endif
    }

    /// Non-destructive probe of the chat/daemon instance lock. There is a
    /// microsecond window where holding the probe lock could make a daemon
    /// starting at that exact instant fail its acquire — it exits and
    /// systemd restarts it 5 s later, acceptable for a status read.
    static func daemonRunning() -> Bool {
        let url = StoragePaths.dataRoot.appendingPathComponent("instance.lock")
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return false }  // never created ⇒ no daemon ever ran
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    static func status() async -> [String: Any] {
        ProviderProfiles.ensureMigrated()
        var payload = base(ok: true)
        payload["version"] = adaCLIVersion
        payload["subscription_setup"] = ["supported": true, "auth": "device_code", "quota": "unknown"]
        payload["platform"] = platformKey
        payload["is_ubuntu_touch"] = AgentServiceSupport.isUbuntuTouch()
        payload["wakelock_supported"] = AgentServiceSupport.wakeLockSupported()
        payload["paths"] = ["config": StoragePaths.configRootDisplay,
                            "data": StoragePaths.dataRootDisplay]
        payload["daemon_running"] = daemonRunning()
        payload["migration"] = migrationBlock()
        // Where a running agent serves the companion-app chat protocol.
        // Existence of the socket file ≠ liveness (a crashed process leaves
        // it behind); the app must treat a failed connect as "not running".
        payload["chat_socket"] = [
            "path": AppChatSocketServer.socketURL.path,
            "protocol": AppChatSocketServer.protocolVersion,
        ] as [String: Any]

        var setup: [String: Any] = ["complete": SetupWizard.setupComplete(legacyDefaults: defaults)]
        if let step = KeychainHelper.load(key: SetupWizard.progressKey), !step.isEmpty {
            setup["step_in_progress"] = step
        }
        payload["setup"] = setup

        var profiles: [String: Any] = [:]
        for profile in ProviderProfiles.Profile.allCases {
            if (profile == .openai || profile == .chatgpt) && !ProviderProfiles.isConfigured(profile) { continue }
            var entry: [String: Any] = ["configured": ProviderProfiles.isConfigured(profile)]
            if let model = ProviderProfiles.configuredModel(profile) { entry["model"] = model }
            if let endpoint = ProviderProfiles.configuredEndpoint(profile) { entry["endpoint"] = endpoint }
            if let effort = ProviderProfiles.configuredEffort(profile) { entry["effort"] = effort }
            if let masked = ProviderProfiles.maskedKey(profile) { entry["masked_key"] = masked }
            if let textOnly = ProviderProfiles.textOnly(profile) { entry["text_only"] = textOnly }
            if ProviderProfiles.wireProtocol(profile) == .responses {
                entry["protocol"] = "responses"
                entry["capabilities"] = ["auth": profile == .chatgpt ? "oauth" : "apiKey", "streaming": true,
                    "encrypted_reasoning_replay": true,
                    "native_tool_media": profile != .chatgpt && (profile != .custom || KeychainHelper.load(key: ProviderProfiles.customNativeMediaKey) != "false")] as [String: Any]
            }
            profiles[profile.rawValue] = entry
        }
        var providers: [String: Any] = ["profiles": profiles]
        if let active = ProviderProfiles.activeProfile() { providers["active"] = active.rawValue }
        payload["providers"] = providers

        // Catalog served here so no GUI ever hardcodes the model list.
        payload["opencode_catalog"] = OpenCodeGo.choices.map {
            ["id": $0.id, "label": $0.label, "text_only": $0.textOnly] as [String: Any]
        }
        payload["opencode_default_model"] = OpenCodeGo.defaultModel

        func keyStatus(_ storageKey: String) -> [String: Any] {
            guard let value = KeychainHelper.load(key: storageKey), !value.isEmpty else {
                return ["set": false]
            }
            return ["set": true, "masked": WizardIO.masked(value)]
        }
        payload["keys"] = [
            "openai": keyStatus(KeychainHelper.openAITranscriptionApiKeyKey),
            "serper": keyStatus(KeychainHelper.serperApiKeyKey),
            "jina": keyStatus(KeychainHelper.jinaApiKeyKey),
            "agentmail": keyStatus(KeychainHelper.agentMailApiKeyKey),
        ]

        payload["identity"] = [
            "user_name": KeychainHelper.load(key: KeychainHelper.userNameKey) ?? "",
            "assistant_name": KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? "Bree",
        ]

        var email: [String: Any] = ["provider": EmailCalendarProvider.current.rawValue]
        let inbox = EmailCalendarProvider.agentMailInboxAddress
        if !inbox.isEmpty { email["agentmail_inbox"] = inbox }
        email["agentmail_broker_installed"] = AgentMailService.agentMailBrokerInstalled()
        let foreign = AgentMailService.foreignAgentMailInstalls()
        if !foreign.isEmpty { email["agentmail_foreign_installs"] = foreign }
        email["gws_installed"] = GoogleWorkspaceService.gwsInstalled()
        email["gws_client_secret_present"] = FileManager.default.fileExists(
            atPath: GoogleWorkspaceService.clientSecretFileURL.path)
        payload["email_calendar"] = email

        var telegram: [String: Any] = ["configured": TelegramConfig.isConfigured]
        if let token = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey), !token.isEmpty {
            telegram["masked_token"] = WizardIO.masked(token)
        }
        if let chatId = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey), !chatId.isEmpty {
            telegram["chat_id"] = chatId
        }
        payload["telegram"] = telegram

        let storedBackend = defaults.string(forKey: WebSearchBackend.selectionKey)
        let resolvedBackend = WebSearchBackend.resolve(
            override: nil,
            stored: storedBackend,
            hasOpenAIKey: !WebSearchBackend.storedKey(for: .openai).isEmpty,
            hasLegacyOpenRouterKey: !(KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? "").isEmpty)
        payload["web_search"] = [
            "active": resolvedBackend.rawValue,
            "explicit": storedBackend.flatMap(WebSearchBackend.init(rawValue:)) != nil,
        ] as [String: Any]
        payload["text_only_mode"] = KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "true"
        payload["toolchain"] = [
            "tools": UserdataToolchain.status().map {
                ["name": $0.name, "package": $0.package,
                 "present": $0.present, "source": $0.source,
                 "optional": $0.optional] as [String: Any]
            },
            // capability marker for the app: this CLI accepts
            // {toolchain: {upgrade: true}}
            "upgrade_supported": true,
        ] as [String: Any]

        #if os(Linux)
        payload["service"] = serviceStatusBlock()
        #else
        payload["service"] = ["supported": false]
        #endif
        if includeDesktopEvidence {
            for (key, value) in QuickSetupEvidence.statusAdditions() { payload[key] = value }
        }
        return payload
    }

    /// Desktop quick-setup additions (§6.2) run the toolchain doctor and
    /// statvfs; the UT app's status calls do not need them.
    nonisolated(unsafe) static var includeDesktopEvidence = !AgentServiceSupport.isUbuntuTouch()

    // MARK: probe

    static func probe(_ request: [String: Any]) async -> [String: Any] {
        guard let kind = nonEmptyString(request["kind"]) else {
            return errorResponse(code: "missing_field", message: "probe needs a 'kind'")
        }
        func require(_ field: String) throws -> String {
            guard let value = nonEmptyString(request[field]) else {
                throw APIError(code: "missing_field", message: "probe kind '\(kind)' needs '\(field)'")
            }
            return value
        }
        func verdict(_ failure: String?) -> [String: Any] {
            var payload = base(ok: failure == nil)
            if let failure { payload["reason"] = failure }
            return payload
        }
        do {
            switch kind {
            case "opencode":
                let key = try require("api_key")
                return verdict(await Probes.chatCompletion(
                    baseURL: OpenCodeGo.baseURL, apiKey: key,
                    model: OpenCodeGo.defaultModel, fallbackModels: OpenCodeGo.probeFallbacks))
            case "openrouter":
                let key = try require("api_key")
                let model = nonEmptyString(request["model"]) ?? "google/gemini-3-flash-preview"
                return verdict(await Probes.chatCompletion(
                    baseURL: "https://openrouter.ai/api/v1", apiKey: key, model: model))
            case "custom":
                let base = try require("base_url")
                let model = try require("model")
                let key = try require("api_key")
                return verdict(await Probes.chatCompletion(baseURL: base, apiKey: key, model: model))
            case "responses":
                let base = nonEmptyString(request["base_url"]) ?? "https://api.openai.com/v1"
                return verdict(await Probes.responses(baseURL: base, apiKey: try require("api_key"), model: try require("model")))
            case "local":
                let base = try require("base_url")
                let model = try require("model")
                return verdict(await Probes.chatCompletion(baseURL: base, apiKey: nil, model: model))
            case "openai":
                return verdict(await Probes.openAI(apiKey: try require("api_key")))
            case "serper":
                return verdict(await Probes.serper(apiKey: try require("api_key")))
            case "jina":
                return verdict(await Probes.jina(apiKey: try require("api_key")))
            case "telegram":
                let token = try require("token")
                let failure = await Probes.telegram(token: token)
                var payload = verdict(failure)
                // Best-effort enrichment so the GUI can show which bot the
                // token belongs to; the verdict itself is the shared probe's.
                if failure == nil, let username = await telegramBotUsername(token: token) {
                    payload["bot_username"] = username
                }
                return payload
            case "telegram_chat":
                // Coupled token + chat-ID verification (quick setup's one
                // Telegram row): getMe, then getChat — private chats only.
                let token = try require("token")
                let chatId = try require("chat_id")
                let result = await telegramChatProbe(token: token, chatId: chatId)
                var payload = verdict(result.failure)
                if let code = result.reasonCode { payload["reason_code"] = code }
                if let u = result.botUsername { payload["bot_username"] = u }
                if let t = result.chatTitle { payload["chat_title"] = t }
                if let u = result.chatUsername { payload["chat_username"] = u }
                return payload
            case "agentmail":
                let key = try require("api_key")
                let (failure, inboxes) = await AgentMailService.probeKey(key)
                var payload = verdict(failure)
                if failure == nil { payload["inboxes"] = inboxes }
                return payload
            default:
                return errorResponse(code: "unknown_kind", message: "unknown probe kind '\(kind)'")
            }
        } catch let error as APIError {
            return errorResponse(code: error.code, message: error.message)
        } catch {
            return errorResponse(code: "internal", message: error.localizedDescription)
        }
    }

    struct TelegramChatProbe {
        var failure: String?
        var reasonCode: String?
        var botUsername: String?
        var chatTitle: String?
        var chatUsername: String?
    }

    /// Selftest seam: replaces the network calls.
    nonisolated(unsafe) static var telegramChatProbeOverride: ((String, String) async -> TelegramChatProbe)?

    static func telegramChatProbe(token: String, chatId: String) async -> TelegramChatProbe {
        if let telegramChatProbeOverride { return await telegramChatProbeOverride(token, chatId) }
        var out = TelegramChatProbe()
        switch TelegramPairing.parseChatId(chatId) {
        case .failure(.notNumeric):
            out.failure = "chat ID must be numeric (letters mean it's a username — use @userinfobot to get the numeric ID)"
            out.reasonCode = "not_numeric"
            return out
        case .failure(.notPrivate):
            out.failure = TelegramPairing.privateChatExplanation
            out.reasonCode = "not_private"
            return out
        case .success: break
        }
        if let failure = await Probes.telegram(token: token) {
            out.failure = failure
            out.reasonCode = "bad_token"
            return out
        }
        out.botUsername = await telegramBotUsername(token: token)
        guard let url = URL(string: DevProbeOverride.url("https://api.telegram.org/bot\(token)/getChat?chat_id=\(chatId)", dev: "/telegram/bot\(token)/getChat?chat_id=\(chatId)")) else {
            out.failure = "invalid token format"; return out
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 || json?["ok"] as? Bool != true {
                let description = (json?["description"] as? String) ?? "HTTP \(code)"
                if description.lowercased().contains("chat not found") {
                    out.failure = "chat not found — open @\(out.botUsername ?? "yourbot") in Telegram, send /start, then tap Retry"
                    out.reasonCode = "chat_not_found"
                } else {
                    out.failure = "Telegram getChat failed: \(description)"
                    out.reasonCode = "getchat_failed"
                }
                return out
            }
            let result = json?["result"] as? [String: Any] ?? [:]
            guard result["type"] as? String == "private" else {
                out.failure = TelegramPairing.privateChatExplanation
                out.reasonCode = "not_private"
                return out
            }
            let first = result["first_name"] as? String ?? ""
            let last = result["last_name"] as? String ?? ""
            out.chatTitle = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            out.chatUsername = result["username"] as? String
        } catch {
            out.failure = "Telegram unreachable: \(error.localizedDescription)"
            out.reasonCode = "unreachable"
        }
        return out
    }

    private static func telegramBotUsername(token: String) async -> String? {
        guard let url = URL(string: DevProbeOverride.url("https://api.telegram.org/bot\(token)/getMe", dev: "/telegram/bot\(token)/getMe")) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = json["result"] as? [String: Any] else { return nil }
        return result["username"] as? String
    }

    // MARK: apply

    /// Sections process in a fixed order; each commits independently (its own
    /// atomic batch), so a failure aborts the REMAINING sections and reports
    /// what already committed via "applied".
    /// `checkpoint` (plan §6.5): called by the sections that await between
    /// writes — after the AgentMail probe, immediately before its
    /// `saveBatch`, and before the CLI install — so a caller whose
    /// authorization was revoked mid-section aborts with nothing further
    /// written. A throw surfaces as `superseded` with `applied` listing what
    /// committed before it. `setup-api` and the UT app pass nothing.
    static func apply(_ request: [String: Any], ownsLease: Bool = false, checkpoint: () throws -> Void = {}) async -> [String: Any] {
        if let refusal = migrationRefusal() { return refusal }
        ProviderProfiles.ensureMigrated()
        var applied: [String] = []
        var warnings: [String] = []
        do {
            try checkpoint()
            if let section = request["provider"] as? [String: Any] {
                try applyProvider(section, ownsLease: ownsLease, checkpoint: checkpoint)
                applied.append("provider")
            }
            if let section = request["openai"] as? [String: Any] {
                try applyOpenAI(section)
                applied.append("openai")
            }
            if let section = request["serper"] as? [String: Any] {
                try applySimpleKey(section, storageKey: KeychainHelper.serperApiKeyKey, sectionName: "serper")
                applied.append("serper")
            }
            if let section = request["jina"] as? [String: Any] {
                try applySimpleKey(section, storageKey: KeychainHelper.jinaApiKeyKey, sectionName: "jina")
                applied.append("jina")
            }
            if let section = request["identity"] as? [String: Any] {
                try applyIdentity(section)
                applied.append("identity")
            }
            if let section = request["telegram"] as? [String: Any] {
                try applyTelegram(section)
                applied.append("telegram")
            }
            if let section = request["email_calendar"] as? [String: Any] {
                try await applyEmailCalendar(section, warnings: &warnings, checkpoint: checkpoint)
                applied.append("email_calendar")
            }
            if let backend = request["web_search_backend"] {
                guard let raw = nonEmptyString(backend),
                      let parsed = WebSearchBackend(rawValue: raw) else {
                    throw APIError(code: "invalid_value",
                                   message: "web_search_backend must be openrouter|openai|opencode")
                }
                defaults.set(parsed.rawValue, forKey: WebSearchBackend.selectionKey)
                applied.append("web_search_backend")
            }
            if let section = request["toolchain"] as? [String: Any] {
                let wantsInstall = section["install"] as? Bool == true
                let wantsUpgrade = section["upgrade"] as? Bool == true
                guard wantsInstall != wantsUpgrade else {
                    throw APIError(code: "invalid_value",
                                   message: "toolchain section supports {install: true, pandoc: bool, libreoffice: bool} OR {upgrade: true}")
                }
                // Long-running (apt on phone networks) — progress to stderr,
                // stdout stays reserved for the single JSON response.
                func stderrProgress(_ line: String) {
                    FileHandle.standardError.write(Data(("toolchain: \(line)\n").utf8))
                }
                let report: UserdataToolchain.InstallReport
                if wantsUpgrade {
                    report = await Task.detached(priority: .userInitiated) {
                        UserdataToolchain.upgradeSync(progress: stderrProgress)
                    }.value
                } else {
                    let pandoc = section["pandoc"] as? Bool == true
                    let libreoffice = section["libreoffice"] as? Bool == true
                    report = await Task.detached(priority: .userInitiated) {
                        UserdataToolchain.installSync(includePandoc: pandoc,
                                                      includeLibreOffice: libreoffice,
                                                      progress: stderrProgress)
                    }.value
                }
                guard report.ok else {
                    throw APIError(code: wantsUpgrade ? "toolchain_upgrade_failed"
                                                      : "toolchain_install_failed",
                                   message: report.failures.joined(separator: "; "))
                }
                if !report.wrappers.isEmpty {
                    warnings.append((wantsUpgrade ? "toolchain rebuilt on userdata: "
                                                  : "toolchain installed to userdata: ")
                                    + report.wrappers.joined(separator: ", "))
                }
                if wantsUpgrade {
                    // the outcome lives in the notes ("everything up to
                    // date…" / "upgraded: …") — surface them to the app
                    warnings.append(contentsOf: report.notes.filter {
                        !$0.contains("cleaned up")
                    })
                }
                applied.append("toolchain")
            }
            if request["mark_complete"] as? Bool == true {
                do {
                    try KeychainHelper.delete(key: SetupWizard.progressKey)
                    try KeychainHelper.save(key: SetupWizard.completeKey, value: "true")
                } catch { throw saveFailed(error) }
                applied.append("mark_complete")
            }
            guard !applied.isEmpty else {
                throw APIError(code: "empty_request",
                               message: "no recognized sections — expected any of: provider, openai, "
                               + "serper, jina, identity, telegram, email_calendar, "
                               + "web_search_backend, toolchain, mark_complete")
            }
        } catch let error as APIError {
            var payload = errorResponse(code: error.code, message: error.message)
            payload["applied"] = applied  // sections committed before the failure
            return payload
        } catch let error as CheckpointRevoked {
            var payload = errorResponse(code: "superseded", message: error.message)
            payload["applied"] = applied
            return payload
        } catch {
            var payload = errorResponse(code: "internal", message: error.localizedDescription)
            payload["applied"] = applied
            return payload
        }
        var payload = base(ok: true)
        payload["applied"] = applied
        if !warnings.isEmpty { payload["warnings"] = warnings }
        let running = daemonRunning()
        payload["daemon_running"] = running
        payload["restart_needed"] = running
        return payload
    }

    private static func applyProvider(_ section: [String: Any], ownsLease: Bool = false, checkpoint: () throws -> Void = {}) throws {
        guard let raw = nonEmptyString(section["profile"]),
              let profile = ProviderProfiles.Profile(rawValue: raw.lowercased()) else {
            throw APIError(code: "invalid_value",
                           message: "provider.profile must be opencode|openrouter|openai|custom|local")
        }
        if profile == .chatgpt {
            throw APIError(code: "native_login_required", message: "Configure ChatGPT with briglia subscription login/select. This client cannot edit OAuth profiles.")
        }
        // Hold the lease through all synchronous profile mutations. A probe
        // of daemonRunning alone has a check/write race with daemon startup.
        let affectsResponses = profile == .openai || section["protocol"] as? String == "responses"
            || ProviderProfiles.wireProtocol(profile) == .responses || ProviderProfiles.usesResponses
        var lease: InstanceLease?
        if affectsResponses && !ownsLease {
            try StoragePaths.ensureRootsChecked()
            switch InstanceLease.acquire(label: "Responses profile configuration") {
            case .success(let held): lease = held
            case .failure: throw APIError(code: "agent_running", message: "Stop Briglia before changing a Responses profile through Setup API.")
            }
        }
        defer { lease?.release() }
        if section["remove"] as? Bool == true {
            try checkpoint()
            try removeProvider(profile)
            return
        }
        guard let model = nonEmptyString(section["model"]) else {
            throw APIError(code: "missing_field", message: "provider.model is required")
        }

        // Omitted api_key mirrors the wizard's "Enter keeps the saved key":
        // reuse the stored profile key, which was validated when stored.
        var apiKey = nonEmptyString(section["api_key"])
        if apiKey == nil {
            switch profile {
            case .chatgpt: throw APIError(code: "native_login_required", message: "Use subscription login")
            case .opencode: apiKey = nonEmptyString(KeychainHelper.load(key: ProviderProfiles.opencodeApiKeyKey))
            case .openrouter: apiKey = nonEmptyString(KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey))
            case .openai: apiKey = nonEmptyString(KeychainHelper.load(key: ProviderProfiles.openaiApiKeyKey))
            case .custom: apiKey = nonEmptyString(KeychainHelper.load(key: ProviderProfiles.customApiKeyKey))
            case .local: break
            }
        }
        if profile != .local, apiKey == nil {
            throw APIError(code: "missing_field",
                           message: "provider.api_key is required (no stored key to keep)")
        }

        var baseURL = nonEmptyString(section["base_url"])
        switch profile {
        case .custom:
            if baseURL == nil {
                baseURL = nonEmptyString(KeychainHelper.load(key: ProviderProfiles.customBaseURLKey))
            }
            guard baseURL != nil else {
                throw APIError(code: "missing_field", message: "provider.base_url is required")
            }
        case .local:
            if baseURL == nil {
                baseURL = nonEmptyString(KeychainHelper.load(key: KeychainHelper.lmStudioBaseURLKey))
            }
            guard baseURL != nil else {
                throw APIError(code: "missing_field", message: "provider.base_url is required")
            }
        case .chatgpt: throw APIError(code: "native_login_required", message: "Use subscription login")
        case .opencode, .openrouter, .openai:
            baseURL = nil  // fixed endpoints
        }

        // Vision state: explicit wins; the OpenCode catalog fills it for
        // known models; anything else must say so — a silently-guessed
        // wrong value would break image handling until noticed.
        let textOnly: Bool
        if let explicit = section["text_only"] as? Bool {
            textOnly = explicit
        } else if profile == .opencode,
                  let entry = OpenCodeGo.choices.first(where: { $0.id == model }) {
            textOnly = entry.textOnly
        } else {
            throw APIError(code: "missing_field",
                           message: profile == .opencode
                           ? "provider.text_only is required for a model outside the OpenCode catalog"
                           : "provider.text_only is required (can the model see images?)")
        }

        let requestedProtocol: ProviderWireProtocol?
        if let rawProtocol = section["protocol"] {
            guard let text = rawProtocol as? String, let parsed = ProviderWireProtocol(rawValue: text),
                  profile == .custom || (profile == .openai && parsed == .responses) else {
                throw APIError(code: "invalid_value", message: "protocol must be chatCompletions|responses; only custom profiles select a protocol")
            }
            requestedProtocol = parsed
        } else { requestedProtocol = nil }
        if profile == .openai || requestedProtocol == .responses || ProviderProfiles.wireProtocol(profile) == .responses {
            if profile == .custom { _ = try ResponsesAdapter.endpoint(baseURL ?? "") }
        }
        if let media = section["native_tool_media"], !(media is Bool) || profile != .custom {
            throw APIError(code: "invalid_value", message: "native_tool_media must be a boolean for a custom Responses profile")
        }
        let protocolForSave = requestedProtocol ?? ProviderProfiles.wireProtocol(profile)
        // Responses also supports models without a reasoning parameter. Only
        // send an effort explicitly requested by the owner; no model-name sniff.
        let effort: String? = profile == .local ? nil
            : (nonEmptyString(section["effort"]) ?? (protocolForSave == .responses ? nil : "high"))
        try checkpoint()
        do {
            try ProviderProfiles.saveProfile(profile, apiKey: profile == .local ? nil : apiKey,
                                             baseURL: baseURL, model: model,
                                             effort: effort, textOnly: textOnly, wireProtocol: requestedProtocol,
                                             nativeToolMedia: section["native_tool_media"] as? Bool)
        } catch { throw saveFailed(error) }

        // Default mirrors the wizard's activateAfterConfiguring: the first
        // configured provider becomes active automatically, and re-saving
        // the ACTIVE profile re-activates so edits reach the runtime slots.
        // A Settings edit of a non-active profile does not hijack the
        // runtime unless it asks (activate: true).
        let current = ProviderProfiles.activeProfile()
        let activate = (section["activate"] as? Bool) ?? (current == nil || current == profile)
        if activate {
            do { try ProviderProfiles.activate(profile) } catch {
                throw APIError(code: "activation_failed",
                               message: ProviderProfiles.describeActivationError(error))
            }
        }
    }

    /// The companion app Settings screen's delete path:
    /// forget a profile's stored configuration. The ACTIVE profile is
    /// refused — Briglia cannot run without a main agent, so the caller must
    /// activate another profile first.
    private static func removeProvider(_ profile: ProviderProfiles.Profile) throws {
        guard ProviderProfiles.activeProfile() != profile else {
            throw APIError(code: "profile_active",
                           message: "\(profile.rawValue) is the active provider — activate "
                           + "another profile before removing it")
        }
        var changes: [String: String?] = [:]
        switch profile {
        case .chatgpt: throw APIError(code: "native_login_required", message: "Use subscription logout")
        case .openai:
            changes[ProviderProfiles.openaiApiKeyKey] = String?.none
            changes[ProviderProfiles.openaiModelKey] = String?.none
            changes[ProviderProfiles.openaiEffortKey] = String?.none
            changes[ProviderProfiles.openaiTextOnlyKey] = String?.none
        case .opencode:
            changes[ProviderProfiles.opencodeApiKeyKey] = String?.none
            changes[ProviderProfiles.opencodeModelKey] = String?.none
            changes[ProviderProfiles.opencodeReasoningEffortKey] = String?.none
            changes[ProviderProfiles.opencodeTextOnlyKey] = String?.none
        case .openrouter:
            changes[KeychainHelper.openRouterApiKeyKey] = String?.none
            changes[KeychainHelper.openRouterModelKey] = String?.none
            changes[KeychainHelper.openRouterReasoningEffortKey] = String?.none
            changes[ProviderProfiles.openrouterTextOnlyKey] = String?.none
        case .custom:
            changes[ProviderProfiles.customProtocolKey] = String?.none
            changes[ProviderProfiles.customNativeMediaKey] = String?.none
            changes[ProviderProfiles.customBaseURLKey] = String?.none
            changes[ProviderProfiles.customApiKeyKey] = String?.none
            changes[ProviderProfiles.customModelKey] = String?.none
            changes[ProviderProfiles.customReasoningEffortKey] = String?.none
            changes[ProviderProfiles.customTextOnlyKey] = String?.none
        case .local:
            changes[KeychainHelper.lmStudioBaseURLKey] = String?.none
            changes[KeychainHelper.lmStudioModelKey] = String?.none
            changes[ProviderProfiles.localTextOnlyKey] = String?.none
        }
        do { try KeychainHelper.saveBatch(changes) } catch { throw saveFailed(error) }
    }

    /// Wizard step 2's exact fan-out, as one atomic batch: a single OpenAI
    /// key powers web research, voice, image generation and OCR.
    /// remove:true deletes the key from all three slots it fans out to; the
    /// provider selections stay (harmless without a key — the web-search
    /// resolver and voice/image paths degrade to their keyless behavior).
    private static func applyOpenAI(_ section: [String: Any]) throws {
        if section["remove"] as? Bool == true {
            do {
                try KeychainHelper.saveBatch([
                    KeychainHelper.webSearchOpenAIApiKeyKey: String?.none,
                    KeychainHelper.openAITranscriptionApiKeyKey: String?.none,
                    KeychainHelper.openAIImageApiKeyKey: String?.none,
                ])
            } catch { throw saveFailed(error) }
            return
        }
        guard let key = nonEmptyString(section["api_key"]) else {
            throw APIError(code: "missing_field", message: "openai.api_key is required")
        }
        do {
            try KeychainHelper.saveBatch([
                KeychainHelper.webSearchOpenAIApiKeyKey: key,
                KeychainHelper.voiceTranscriptionProviderKey: VoiceTranscriptionProvider.openAI.rawValue,
                KeychainHelper.openAITranscriptionApiKeyKey: key,
                KeychainHelper.imageGenerationProviderKey: ImageGenerationProvider.openAI.rawValue,
                KeychainHelper.openAIImageApiKeyKey: key,
                KeychainHelper.visionPreprocessorBackendKey: "openai",
            ])
        } catch { throw saveFailed(error) }
        defaults.set(WebSearchBackend.openai.rawValue, forKey: WebSearchBackend.selectionKey)
    }

    private static func applySimpleKey(
        _ section: [String: Any], storageKey: String, sectionName: String
    ) throws {
        if section["remove"] as? Bool == true {
            do { try KeychainHelper.delete(key: storageKey) } catch { throw saveFailed(error) }
            return
        }
        guard let key = nonEmptyString(section["api_key"]) else {
            throw APIError(code: "missing_field", message: "\(sectionName).api_key is required")
        }
        do { try KeychainHelper.save(key: storageKey, value: key) } catch { throw saveFailed(error) }
    }

    private static func applyIdentity(_ section: [String: Any]) throws {
        if section["remove"] as? Bool == true {
            do { try KeychainHelper.delete(key: KeychainHelper.userNameKey) } catch {
                throw saveFailed(error)
            }
            return
        }
        guard let name = nonEmptyString(section["user_name"]) else {
            throw APIError(code: "missing_field", message: "identity.user_name is required")
        }
        do {
            try KeychainHelper.saveBatch([
                KeychainHelper.userNameKey: name,
                KeychainHelper.assistantNameKey: "Bree",  // fixed, same as the wizard
            ])
        } catch { throw saveFailed(error) }
    }

    private static func applyTelegram(_ section: [String: Any]) throws {
        if section["remove"] as? Bool == true {
            do {
                try KeychainHelper.saveBatch([
                    KeychainHelper.telegramBotTokenKey: String?.none,
                    KeychainHelper.telegramChatIdKey: String?.none,
                ])
            } catch { throw saveFailed(error) }
            return
        }
        guard let token = nonEmptyString(section["token"]) else {
            throw APIError(code: "missing_field", message: "telegram.token is required")
        }
        guard let chatId = nonEmptyString(section["chat_id"]) else {
            throw APIError(code: "missing_field", message: "telegram.chat_id is required")
        }
        switch TelegramPairing.parseChatId(chatId) {
        case .success:
            break
        case .failure(.notNumeric):
            throw APIError(code: "invalid_chat_id",
                           message: "chat_id must be numeric (letters mean it's a username — "
                           + "use @userinfobot to get the numeric ID)")
        case .failure(.notPrivate):
            throw APIError(code: "invalid_chat_id",
                           message: TelegramPairing.privateChatExplanation)
        }
        do {
            try KeychainHelper.saveBatch([
                KeychainHelper.telegramBotTokenKey: token,
                KeychainHelper.telegramChatIdKey: chatId,
            ])
        } catch { throw saveFailed(error) }
    }

    private static func applyEmailCalendar(
        _ section: [String: Any], warnings: inout [String], checkpoint: () throws -> Void = {}
    ) async throws {
        guard let raw = nonEmptyString(section["provider"]),
              let provider = EmailCalendarProvider(rawValue: raw) else {
            throw APIError(code: "invalid_value",
                           message: "email_calendar.provider must be none|agentmail|gws")
        }
        switch provider {
        case .none:
            // remove_credentials severs email ACCESS via the canonical
            // /deleteuserdata wipe (EmailCredentialWipe): AgentMail key +
            // inbox, gws OAuth client fields, AND the whole ~/.config/gws
            // directory (client_secret.json + gws's OAuth token store —
            // Codex, 2026-08-27: deleting only Briglia's stored fields left the
            // live Google tokens behind). Plain provider:none keeps
            // credentials so re-enabling is one tap.
            if section["remove_credentials"] as? Bool == true {
                let failures = EmailCredentialWipe.execute(
                    gwsConfigDir: gwsConfigDirectoryOverride
                        ?? GoogleWorkspaceService.gwsConfigDirectory)
                guard failures.isEmpty else {
                    throw APIError(code: "remove_failed",
                                   message: "credential removal incomplete: "
                                   + failures.joined(separator: "; "))
                }
            } else {
                do {
                    try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey,
                                            value: EmailCalendarProvider.none.rawValue)
                } catch { throw saveFailed(error) }
            }

        case .agentmail:
            var key = nonEmptyString(section["api_key"])
            if key == nil {
                key = nonEmptyString(KeychainHelper.load(key: KeychainHelper.agentMailApiKeyKey))
            }
            guard let key else {
                throw APIError(code: "missing_field",
                               message: "email_calendar.api_key is required for agentmail "
                               + "(no stored key to keep)")
            }
            // Same as the wizard: capture the inbox address from a live
            // probe when reachable; an offline probe is nonfatal.
            let (failure, inboxes) = await AgentMailService.probeKey(key)
            try checkpoint()   // after the await, before any write
            var changes: [String: String?] = [
                KeychainHelper.agentMailApiKeyKey: key,
                KeychainHelper.emailCalendarProviderKey: EmailCalendarProvider.agentmail.rawValue,
            ]
            if let inbox = inboxes.first {
                changes[KeychainHelper.agentMailInboxAddressKey] = inbox
            }
            try checkpoint()   // immediately before the saveBatch
            do { try KeychainHelper.saveBatch(changes) } catch { throw saveFailed(error) }
            if let failure {
                warnings.append("agentmail: could not list inboxes (\(failure)) — continuing; "
                                + "Briglia retries at runtime")
            }
            if section["install_cli"] as? Bool == true, !AgentMailService.agentMailBrokerInstalled() {
                try checkpoint()   // immediately before the install
                if let installFailure = await AgentMailService.installAgentMailBinary(checkpoint: checkpoint) {
                    warnings.append("agentmail CLI install failed: \(installFailure) — inbox "
                                    + "alerts and context still work; retry the install later")
                }
            }

        case .gws:
            let providedID = nonEmptyString(section["gws_client_id"])
            let providedSecret = nonEmptyString(section["gws_client_secret"])
            if let providedID, let providedSecret {
                do {
                    try KeychainHelper.saveBatch([
                        KeychainHelper.gwsOAuthClientIDKey: providedID,
                        KeychainHelper.gwsOAuthClientSecretKey: providedSecret,
                    ])
                } catch { throw saveFailed(error) }
            }
            let secretFilePresent = FileManager.default.fileExists(
                atPath: GoogleWorkspaceService.clientSecretFileURL.path)
            let storedID = nonEmptyString(KeychainHelper.load(key: KeychainHelper.gwsOAuthClientIDKey))
            if !secretFilePresent && storedID == nil {
                throw APIError(code: "missing_field",
                               message: "gws needs your own Google OAuth client — provide "
                               + "gws_client_id and gws_client_secret")
            }
            if !secretFilePresent {
                do { try GoogleWorkspaceService.installAdaClientSecretIfMissing() } catch {
                    warnings.append("could not write ~/.config/gws/client_secret.json "
                                    + "(\(error.localizedDescription)) — `gws auth login` will "
                                    + "fail until it exists")
                }
            }
            if section["install_cli"] as? Bool == true, !GoogleWorkspaceService.gwsInstalled() {
                if let failure = await GoogleWorkspaceService.installGwsBinary() {
                    warnings.append("gws install failed: \(failure)")
                }
            }
            do {
                try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey,
                                        value: EmailCalendarProvider.gws.rawValue)
            } catch { throw saveFailed(error) }
        }
    }

    // MARK: service

    static func service(_ request: [String: Any]) async -> [String: Any] {
        if let refusal = migrationRefusal() { return refusal }
        #if os(Linux)
        let action = nonEmptyString(request["action"])
        let wantScripts = request["keepawake_script"] as? Bool == true
        var payload: [String: Any]
        switch action {
        case "install":
            guard TelegramConfig.isConfigured else {
                return errorResponse(code: "telegram_required",
                                     message: "the service runs `briglia daemon`, which needs the "
                                     + "Telegram channel — apply the telegram section first")
            }
            // Non-interactive: a GUI has no terminal to lend sudo, so the
            // linger root-fallback is skipped; the response carries the
            // exact command for the caller to run under its own sudo.
            let ok = AgentServiceSupport.installUserService(interactiveSudoFallback: false)
            payload = ok ? base(ok: true)
                : errorResponse(code: "install_failed",
                                message: "service installation failed — see the stderr log")
            if ok, AgentServiceSupport.systemdUserSessionAvailable(),
               !AgentServiceSupport.lingerEnabled() {
                payload["linger_command"] = "sudo loginctl enable-linger \(NSUserName())"
            }
        case "uninstall":
            // Checked, best-effort, and RETRY-SAFE: none of the steps is
            // gated on the unit FILE existing (Codex, 2026-08-27 round 2 —
            // if a first attempt removed the file but disable/daemon-reload
            // failed, a file-gated retry skipped the remaining cleanup and
            // reported success while a stale unit stayed loaded). Every
            // step always runs; "unit doesn't exist" answers count as the
            // step's idempotent success, real failures are named.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let unitPath = AgentServiceSupport.userUnitDirectory(home: home)
                + "/" + AgentServiceSupport.userUnitName
            // No unit file and no reachable systemd user bus: we cannot
            // confirm whether a previously loaded service was stopped and
            // unloaded (Codex round 3 — a retry in this state after a
            // partial first attempt would otherwise claim success over a
            // possibly still-loaded unit). Report unverified, not success;
            // a genuinely never-installed container gets the same honest
            // answer, and the message says why it is safe there.
            if !FileManager.default.fileExists(atPath: unitPath),
               !AgentServiceSupport.systemdUserSessionAvailable() {
                payload = errorResponse(
                    code: "unverified",
                    message: "no unit file remains, but no systemd user bus is reachable "
                    + "from here, so a previously loaded service (if any) could not be "
                    + "verified stopped — re-run from a normal login session; if the "
                    + "service was never installed there is nothing left to do")
                payload["service"] = serviceStatusBlock()
                if wantScripts { attachWakelockScripts(&payload) }
                return payload
            }
            var stepFailures: [String] = []
            let disable = AgentServiceSupport.run(
                "systemctl", ["--user", "disable", "--now", AgentServiceSupport.userUnitName])
            let disableUnknownUnit = disable.output.contains("does not exist")
                || disable.output.contains("not-found")
                || disable.output.contains("not loaded")
            if disable.status != 0 && !disableUnknownUnit {
                stepFailures.append("disable --now: \(disable.output.isEmpty ? "exit \(disable.status)" : disable.output)")
            }
            if FileManager.default.fileExists(atPath: unitPath) {
                do { try FileManager.default.removeItem(atPath: unitPath) } catch {
                    stepFailures.append("remove \(unitPath): \(error.localizedDescription)")
                }
            }
            let reload = AgentServiceSupport.run("systemctl", ["--user", "daemon-reload"])
            if reload.status != 0 {
                stepFailures.append("daemon-reload: \(reload.output.isEmpty ? "exit \(reload.status)" : reload.output)")
            }
            payload = stepFailures.isEmpty ? base(ok: true)
                : errorResponse(code: "uninstall_failed",
                                message: stepFailures.joined(separator: "; "))
            // wakelock is script-only (root) — see keepawake_script
        case "restart":
            let result = AgentServiceSupport.run(
                "systemctl", ["--user", "restart", AgentServiceSupport.userUnitName])
            guard result.status == 0 else {
                return errorResponse(code: "restart_failed",
                                     message: result.output.isEmpty
                                     ? "systemctl --user restart failed" : result.output)
            }
            // `systemctl restart` returning 0 only means the start job was
            // queued (Type=simple: "started" = exec'd) — a daemon that dies
            // immediately still reported success here. Settle, then verify
            // the unit is actually active; anything else is an honest
            // failure, not a success with a broken daemon behind it.
            Thread.sleep(forTimeInterval: 2.0)
            let state = AgentServiceSupport.run(
                "systemctl", ["--user", "is-active", AgentServiceSupport.userUnitName]).output
            if !restartLeftUnitHealthy(isActiveOutput: state) {
                var unhealthy = errorResponse(
                    code: "restart_unhealthy",
                    message: "the service restarted but is '\(state)' instead of 'active' — "
                    + "the daemon likely crashed on startup; check "
                    + "`journalctl --user -u \(AgentServiceSupport.userUnitName) -n 40`")
                unhealthy["service"] = serviceStatusBlock()
                if wantScripts { attachWakelockScripts(&unhealthy) }
                return unhealthy
            }
            payload = base(ok: true)
        case nil:
            guard wantScripts else {
                return errorResponse(code: "missing_field",
                                     message: "service needs an 'action' (install|uninstall|restart) "
                                     + "or keepawake_script:true")
            }
            payload = base(ok: true)
        default:
            return errorResponse(code: "invalid_value",
                                 message: "unknown service action '\(action!)'")
        }
        payload["service"] = serviceStatusBlock()
        if wantScripts { attachWakelockScripts(&payload) }
        return payload
        #else
        _ = request
        return errorResponse(code: "unsupported_platform",
                             message: "`briglia setup-api service` manages a systemd service — Linux "
                             + "only; on macOS run `briglia daemon` in a terminal")
        #endif
    }

    /// Pure verdict for the post-restart health probe, selftest-covered on
    /// every platform. Only a settled "active" counts: "activating" two
    /// seconds after a restart means the first exec already died and
    /// systemd is cycling (RestartSec=5), "failed"/"inactive" speak for
    /// themselves.
    static func restartLeftUnitHealthy(isActiveOutput: String) -> Bool {
        isActiveOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "active"
    }

    // MARK: identity migration (rename plan §4.2 — explicit, never implicit)

    /// Read-only detection for the status payload: the companion app shows
    /// its consent flow and calls the `migrate` verb; nothing here writes.
    static func migrationBlock() -> [String: Any] {
        let status = IdentityMigration.status()
        var block: [String: Any] = [
            "needed": status.pending,
            "conflict": status.conflict,
            "old_roots_present": status.oldRootsPresent,
            "new_roots_present": status.newRootsPresent,
            "recovery_command": IdentityMigration.recoveryCommand,
        ]
        if let state = status.journalState {
            block["journal_state"] = state
            block["in_progress"] = status.migrationRunning
            block["new_install_ready"] = status.newInstallReady
        }
        return block
    }

    /// Mutating verbs refuse while a migration is pending: writing the new
    /// roots now would mask detection and strand the old install.
    static func migrationRefusal() -> [String: Any]? {
        let status = IdentityMigration.status()
        guard status.pending else { return nil }
        return errorResponse(code: "migration_needed",
                             message: IdentityMigration.pendingMessage(status))
    }

    /// The explicit migration, as a setup-api verb for GUI frontends. Same
    /// engine and spec as `briglia migrate`; the response carries the
    /// engine's outcome verbatim.
    static func migrate(_ request: [String: Any]) -> [String: Any] {
        let rollback = request["rollback"] as? Bool ?? false
        let status = IdentityMigration.status()
        guard status.pending else {
            var payload = base(ok: true)
            payload["outcome"] = "nothing_to_do"
            payload["migration"] = migrationBlock()
            return payload
        }
        var log: [String] = []
        let outcome = MigrationEngine.run(spec: IdentityMigration.productionSpec(),
                                          mode: rollback ? .rollback : .auto) { log.append($0) }
        switch outcome {
        case .ok(let notes):
            var payload = base(ok: true)
            payload["outcome"] = rollback ? "rolled_back" : "migrated"
            payload["notes"] = notes
            payload["log"] = log
            payload["migration"] = migrationBlock()
            return payload
        case .refused(let why):
            var payload = errorResponse(code: "migration_refused", message: why)
            payload["log"] = log
            return payload
        case .corrupt(let why):
            var payload = errorResponse(code: "migration_journal_corrupt", message: why)
            payload["log"] = log
            return payload
        case .failed(let why):
            var payload = errorResponse(code: "migration_failed", message: why)
            payload["log"] = log
            return payload
        }
    }

    #if os(Linux)
    static func serviceStatusBlock() -> [String: Any] {
        var block: [String: Any] = ["supported": true]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let unitPath = AgentServiceSupport.userUnitDirectory(home: home)
            + "/" + AgentServiceSupport.userUnitName
        let installed = FileManager.default.fileExists(atPath: unitPath)
        block["unit_installed"] = installed
        let session = AgentServiceSupport.systemdUserSessionAvailable()
        block["systemd_user_session"] = session
        if installed && session {
            block["enabled"] = AgentServiceSupport.run(
                "systemctl", ["--user", "is-enabled", AgentServiceSupport.userUnitName]).output
            block["active"] = AgentServiceSupport.run(
                "systemctl", ["--user", "is-active", AgentServiceSupport.userUnitName]).output
        }
        if session {
            let linger = AgentServiceSupport.lingerEnabled()
            block["linger"] = linger
            // Served on EVERY status so a GUI can offer "enable start at
            // boot" at any time — not only in the moment right after
            // install (an interrupted first attempt must be resumable).
            if !linger {
                block["linger_command"] = "sudo loginctl enable-linger \(NSUserName())"
            }
        }
        if AgentServiceSupport.isUbuntuTouch() {
            let wlInstalled = AgentServiceSupport.wakelockUnitInstalled()
            block["wakelock_unit_installed"] = wlInstalled
            if wlInstalled {
                block["wakelock_active"] = AgentServiceSupport.run(
                    "systemctl", ["is-active", AgentServiceSupport.wakelockUnitName]).output
            }
        }
        return block
    }
    #endif

    static func attachWakelockScripts(_ payload: inout [String: Any]) {
        payload["wakelock_supported"] = AgentServiceSupport.wakeLockSupported()
        payload["wakelock_unit_text"] = AgentServiceSupport.wakelockUnitText()
        payload["wakelock_install_script"] = wakelockInstallScript()
        payload["wakelock_uninstall_script"] = wakelockUninstallScript()
    }

    // MARK: wakelock scripts (root steps the caller runs under its own sudo)
    //
    // The command sequence mirrors AgentServiceSupport.installWakelockService()
    // step for step and embeds the SAME unit text, so the two paths can never
    // drift. Emitted as scripts because a GUI collects the passcode itself
    // and runs `sudo -S sh <file>` — piping a password through ada into sudo
    // would add a process hop for zero benefit.

    // The read-only remount lives in an EXIT/signal trap installed right
    // after the rw remount succeeds: with `set -e`, a failing middle step
    // would otherwise exit the script with / left writable (the interactive
    // installWakelockService() already restores unconditionally).

    static func wakelockInstallScript() -> String {
        """
        #!/bin/sh
        # Briglia keep-awake unit installer (Ubuntu Touch). Run as root: sudo sh <this-file>
        set -e
        mount -o remount,rw /
        trap 'mount -o remount,ro / || echo "note: / stays read-write until reboot (busy)"' EXIT INT TERM HUP
        cat > \(AgentServiceSupport.wakelockUnitPath) <<'BRIGLIA_UNIT'
        \(AgentServiceSupport.wakelockUnitText())BRIGLIA_UNIT
        chmod 644 \(AgentServiceSupport.wakelockUnitPath)
        systemctl daemon-reload
        systemctl enable --now \(AgentServiceSupport.wakelockUnitName)
        """
    }

    static func wakelockUninstallScript() -> String {
        """
        #!/bin/sh
        # Briglia keep-awake unit removal (Ubuntu Touch). Run as root: sudo sh <this-file>
        set -e
        mount -o remount,rw /
        trap 'mount -o remount,ro / || echo "note: / stays read-write until reboot (busy)"' EXIT INT TERM HUP
        systemctl disable --now \(AgentServiceSupport.wakelockUnitName) || true
        rm -f \(AgentServiceSupport.wakelockUnitPath)
        systemctl daemon-reload
        """
    }
}
