import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Hidden deterministic test of the `briglia setup-api` surface
/// (JSON over stdio for the companion app). Fully offline — network probe KINDS are
/// validated for request shape only, never executed. Isolation: XDG roots
/// and TMPDIR point at a temp directory BEFORE anything touches
/// KeychainHelper/StoragePaths (locations freeze at first access), the
/// legacy setup flag is suppressed via BRIGLIA_IGNORE_LEGACY_SETUP_FLAG, and
/// UserDefaults writes go to a throwaway suite through the SetupAPICore
/// seam — the machine's real preferences are never read or written, and a
/// crash mid-run leaves only a uniquely-named orphan suite that nothing
/// else reads.
struct SetupAPISelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__setup-api-selftest",
        abstract: "Internal: verify the machine-readable setup surface (status/probe/apply/service).",
        shouldDisplay: false
    )

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-setup-api-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_CONFIG_HOME", tempRoot.path, 1)
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path + "/", 1)
        setenv("BRIGLIA_IGNORE_LEGACY_SETUP_FLAG", "1", 1)

        let suiteName = "ada-setup-api-selftest-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            print("✖ could not create isolated UserDefaults suite")
            throw ExitCode(1)
        }
        SetupAPICore.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            TestPrefsDomains.purge(suiteName)
            TestPrefsDomains.finalSweep()   // incl. the empty plist shell cfprefsd writes later
        }

        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled {
                print("WATCHDOG: setup-api selftest exceeded 120s — hung; aborting")
                Foundation.exit(3)
            }
        }
        defer { watchdog.cancel() }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func errorCode(_ payload: [String: Any]) -> String {
            ((payload["error"] as? [String: Any])?["code"] as? String) ?? ""
        }
        func isOK(_ payload: [String: Any]) -> Bool {
            payload["ok"] as? Bool == true
        }

        // 1. Response plumbing.
        do {
            let transport = SetupAPICore.transportError("nope")
            check("transport error: schema 2, ok false, code transport",
                  transport["schema"] as? Int == 2 && transport["ok"] as? Bool == false
                  && errorCode(transport) == "transport")
            check("argv refusal message names stdin",
                  SetupAPICore.argvRefusalMessage.contains("stdin"))
        }

        // 2. Virgin status.
        do {
            let status = await SetupAPICore.status()
            check("virgin status: ok, schema 2",
                  isOK(status) && status["schema"] as? Int == 2)
            check("virgin status: version + platform present",
                  status["version"] as? String == adaCLIVersion
                  && !((status["platform"] as? String) ?? "").isEmpty)
            let setup = status["setup"] as? [String: Any]
            check("virgin status: setup incomplete, no step in progress",
                  setup?["complete"] as? Bool == false && setup?["step_in_progress"] == nil)
            let providers = status["providers"] as? [String: Any]
            let profiles = providers?["profiles"] as? [String: Any]
            let allUnconfigured = [ProviderProfiles.Profile.opencode, .openrouter, .custom, .local].allSatisfy {
                (profiles?[$0.rawValue] as? [String: Any])?["configured"] as? Bool == false
            }
            check("virgin status: all four profiles present and unconfigured",
                  profiles?.count == 4 && allUnconfigured && providers?["active"] == nil)
            let catalog = status["opencode_catalog"] as? [[String: Any]]
            check("status: catalog mirrors OpenCodeGo.choices",
                  catalog?.count == OpenCodeGo.choices.count
                  && catalog?.contains { $0["id"] as? String == OpenCodeGo.defaultModel } == true
                  && status["opencode_default_model"] as? String == OpenCodeGo.defaultModel)
            let keys = status["keys"] as? [String: Any]
            check("virgin status: no keys set",
                  ["openai", "serper", "jina", "agentmail"].allSatisfy {
                      (keys?[$0] as? [String: Any])?["set"] as? Bool == false
                  })
            check("virgin status: telegram unconfigured, daemon not running",
                  (status["telegram"] as? [String: Any])?["configured"] as? Bool == false
                  && status["daemon_running"] as? Bool == false)
            let service = status["service"] as? [String: Any]
            #if os(Linux)
            check("status: service block supported on Linux",
                  service?["supported"] as? Bool == true
                  && service?["unit_installed"] as? Bool == false)
            #else
            check("status: service block unsupported on macOS",
                  service?["supported"] as? Bool == false)
            #endif
            let toolchain = status["toolchain"] as? [String: Any]
            let toolRows = toolchain?["tools"] as? [[String: Any]] ?? []
            check("status: toolchain block lists every tool incl. pandoc",
                  toolRows.contains { $0["name"] as? String == "pdftotext" }
                  && toolRows.contains { $0["name"] as? String == "pandoc" }
                  && toolRows.allSatisfy {
                      $0["present"] is Bool && $0["source"] is String })
            check("status: toolchain block advertises upgrade support",
                  toolchain?["upgrade_supported"] as? Bool == true)
            check("status: JSON-encodable", JSONSerialization.isValidJSONObject(status))
        }

        // 2b. Toolchain apply: full fake-backed round trip (the fakes mirror
        //     the __toolchain-selftest harness — no network, no real apt).
        do {
            let fakeRoot = tempRoot.appendingPathComponent("tc")
            let payloadDir = fakeRoot.appendingPathComponent("payload")
            let binDir = fakeRoot.appendingPathComponent("bin")
            let sysDir = fakeRoot.appendingPathComponent("sys")
            for tool in ["pdftotext", "pdftoppm", "pdfinfo", "pdfseparate",
                         "pdfunite", "ffmpeg", "ffprobe", "convert",
                         "identify", "mogrify"] {
                let url = payloadDir.appendingPathComponent("usr/bin/\(tool)")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "#!/bin/sh\necho 1.0\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: url.path)
            }
            for dir in [binDir, sysDir] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let fakeApt = fakeRoot.appendingPathComponent("apt-get")
            try """
            #!/bin/sh
            cache=""
            for a in "$@"; do case "$a" in Dir::Cache=*) cache="${a#Dir::Cache=}";; esac; done
            for a in "$@"; do
                if [ "$a" = "install" ]; then
                    mkdir -p "$cache/archives"; touch "$cache/archives/fake_1.0_all.deb"
                fi
            done
            exit 0
            """.write(to: fakeApt, atomically: true, encoding: .utf8)
            let fakeDpkg = fakeRoot.appendingPathComponent("dpkg")
            try """
            #!/bin/sh
            mkdir -p "$3"
            cp -R "\(payloadDir.path)/." "$3/"
            exit 0
            """.write(to: fakeDpkg, atomically: true, encoding: .utf8)
            for script in [fakeApt, fakeDpkg] {
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: script.path)
            }
            let statusFile = fakeRoot.appendingPathComponent("dpkg-status")
            try "".write(to: statusFile, atomically: true, encoding: .utf8)
            setenv("BRIGLIA_TOOLCHAIN_ROOT", fakeRoot.appendingPathComponent("root").path, 1)
            setenv("BRIGLIA_TOOLCHAIN_BIN", binDir.path, 1)
            setenv("BRIGLIA_TOOLCHAIN_PATH", "\(binDir.path):\(sysDir.path)", 1)
            setenv("BRIGLIA_TOOLCHAIN_APT", fakeApt.path, 1)
            setenv("BRIGLIA_TOOLCHAIN_DPKG", fakeDpkg.path, 1)
            setenv("BRIGLIA_TOOLCHAIN_DPKG_STATUS", statusFile.path, 1)
            defer {
                for key in ["BRIGLIA_TOOLCHAIN_ROOT", "BRIGLIA_TOOLCHAIN_BIN",
                            "BRIGLIA_TOOLCHAIN_PATH", "BRIGLIA_TOOLCHAIN_APT",
                            "BRIGLIA_TOOLCHAIN_DPKG", "BRIGLIA_TOOLCHAIN_DPKG_STATUS"] {
                    unsetenv(key)
                }
            }

            let badSection = await SetupAPICore.apply(["toolchain": ["nonsense": true]])
            check("apply toolchain: unrecognized shape → invalid_value",
                  errorCode(badSection) == "invalid_value")
            let bothOps = await SetupAPICore.apply(
                ["toolchain": ["install": true, "upgrade": true]])
            check("apply toolchain: install+upgrade together → invalid_value",
                  errorCode(bothOps) == "invalid_value")

            // upgrade on a fresh root (no manifest): honest no-op, still ok
            let upgradeFresh = await SetupAPICore.apply(["toolchain": ["upgrade": true]])
            check("apply toolchain: upgrade before any install is an ok no-op",
                  upgradeFresh["ok"] as? Bool == true
                  && (upgradeFresh["applied"] as? [String])?.contains("toolchain") == true
                  && (upgradeFresh["warnings"] as? [String])?.contains(where: {
                      $0.contains("no userdata toolchain recorded") }) == true,
                  String(describing: upgradeFresh))

            let installed = await SetupAPICore.apply(["toolchain": ["install": true]])
            let statusAfter = await SetupAPICore.status()
            let rowsAfter = (statusAfter["toolchain"] as? [String: Any])?["tools"]
                as? [[String: Any]] ?? []
            check("apply toolchain: installs via fakes and reports applied",
                  installed["ok"] as? Bool == true
                  && (installed["applied"] as? [String])?.contains("toolchain") == true,
                  String(describing: installed))
            check("apply toolchain: status now shows prefix-sourced tools",
                  rowsAfter.contains {
                      $0["name"] as? String == "pdftotext"
                      && $0["source"] as? String == "prefix" })
        }

        // 3. Probe request validation (shape only — no network).
        do {
            let noKind = await SetupAPICore.probe([:])
            check("probe: missing kind → missing_field", errorCode(noKind) == "missing_field")
            let unknown = await SetupAPICore.probe(["kind": "carrier-pigeon"])
            check("probe: unknown kind → unknown_kind", errorCode(unknown) == "unknown_kind")
            let noKey = await SetupAPICore.probe(["kind": "openai"])
            check("probe: openai without api_key → missing_field",
                  errorCode(noKey) == "missing_field")
            let noBase = await SetupAPICore.probe(["kind": "custom", "model": "m", "api_key": "k"])
            check("probe: custom without base_url → missing_field",
                  errorCode(noBase) == "missing_field")
        }

        // 4. Apply validation.
        do {
            let empty = await SetupAPICore.apply([:])
            check("apply: empty request → empty_request",
                  errorCode(empty) == "empty_request"
                  && (empty["applied"] as? [String])?.isEmpty == true)
            let noModel = await SetupAPICore.apply(["provider": ["profile": "opencode"]])
            check("apply provider: missing model → missing_field",
                  errorCode(noModel) == "missing_field")
            let noKey = await SetupAPICore.apply(
                ["provider": ["profile": "opencode", "model": "glm-5.3"]])
            check("apply provider: no key and none stored → missing_field naming api_key",
                  errorCode(noKey) == "missing_field"
                  && ((noKey["error"] as? [String: Any])?["message"] as? String ?? "").contains("api_key"))
            let badProfile = await SetupAPICore.apply(
                ["provider": ["profile": "closedai", "model": "m"]])
            check("apply provider: unknown profile → invalid_value",
                  errorCode(badProfile) == "invalid_value")
            let badChat = await SetupAPICore.apply(
                ["telegram": ["token": "123:abc", "chat_id": "@sofia"]])
            check("apply telegram: non-numeric chat_id → invalid_chat_id",
                  errorCode(badChat) == "invalid_chat_id")
            let groupChat = await SetupAPICore.apply(
                ["telegram": ["token": "123:abc", "chat_id": "-1001234567890"]])
            check("apply telegram: negative (group) chat_id → invalid_chat_id naming private chats",
                  errorCode(groupChat) == "invalid_chat_id"
                  && ((groupChat["error"] as? [String: Any])?["message"] as? String ?? "").contains("private"))
            let zeroChat = await SetupAPICore.apply(
                ["telegram": ["token": "123:abc", "chat_id": "0"]])
            check("apply telegram: zero chat_id → invalid_chat_id", errorCode(zeroChat) == "invalid_chat_id")

            // TelegramPairing units: the parser both setup paths share, and the poll gate.
            check("pairing: positive id parses (whitespace tolerated)",
                  TelegramPairing.parseChatId(" 5551234567 ") == .success(5551234567))
            check("pairing: negative id → notPrivate",
                  TelegramPairing.parseChatId("-100123") == .failure(.notPrivate))
            check("pairing: zero → notPrivate", TelegramPairing.parseChatId("0") == .failure(.notPrivate))
            check("pairing: username → notNumeric", TelegramPairing.parseChatId("@sofia") == .failure(.notNumeric))
            check("poll gate: private chat from the paired user passes",
                  TelegramPairing.acceptsPolledMessage(chatId: 5551234567, chatType: "private", fromId: 5551234567, pairedChatId: 5551234567))
            check("poll gate: supergroup with a forged positive id fails",
                  !TelegramPairing.acceptsPolledMessage(chatId: 5551234567, chatType: "supergroup", fromId: 5551234567, pairedChatId: 5551234567))
            check("poll gate: message without a sender fails",
                  !TelegramPairing.acceptsPolledMessage(chatId: 5551234567, chatType: "private", fromId: nil, pairedChatId: 5551234567))
            check("poll gate: another sender in the paired chat fails",
                  !TelegramPairing.acceptsPolledMessage(chatId: 5551234567, chatType: "private", fromId: 5551234568, pairedChatId: 5551234567))
            check("poll gate: different chat fails",
                  !TelegramPairing.acceptsPolledMessage(chatId: 5551234568, chatType: "private", fromId: 5551234567, pairedChatId: 5551234567))
            check("poll gate: unpaired instance accepts nothing",
                  !TelegramPairing.acceptsPolledMessage(chatId: 5551234567, chatType: "private", fromId: 5551234567, pairedChatId: nil))
            let badBackend = await SetupAPICore.apply(["web_search_backend": "bing"])
            check("apply: unknown web_search_backend → invalid_value",
                  errorCode(badBackend) == "invalid_value")
            let noName = await SetupAPICore.apply(["identity": [:] as [String: Any]])
            check("apply identity: missing user_name → missing_field",
                  errorCode(noName) == "missing_field")
        }

        // 5. Provider apply: first profile auto-activates, catalog fills
        // text_only, runtime slots switch.
        do {
            let result = await SetupAPICore.apply(
                ["provider": ["profile": "opencode", "api_key": "sk-test-0123456789abcdef",
                              "model": "glm-5.3"]])
            check("apply provider: opencode accepted", isOK(result),
                  errorCode(result))
            check("apply provider: first profile auto-activated",
                  ProviderProfiles.activeProfile() == .opencode)
            check("apply provider: catalog derived text_only for glm-5.3",
                  ProviderProfiles.textOnly(.opencode) == true
                  && KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "true")
            check("apply provider: runtime slots point at OpenCode",
                  (KeychainHelper.load(key: KeychainHelper.openAICompatibleBaseURLKey) ?? "")
                      .contains("opencode.ai")
                  && KeychainHelper.load(key: KeychainHelper.openAICompatibleModelKey) == "glm-5.3")
            let status = await SetupAPICore.status()
            let providers = status["providers"] as? [String: Any]
            let entry = (providers?["profiles"] as? [String: Any])?["opencode"] as? [String: Any]
            check("status reflects applied provider (active, masked key, effort)",
                  providers?["active"] as? String == "opencode"
                  && entry?["configured"] as? Bool == true
                  && entry?["model"] as? String == "glm-5.3"
                  && entry?["effort"] as? String == "high"
                  && (entry?["masked_key"] as? String ?? "").contains("…"))
        }

        // 6. Keep-current-key semantics + vision re-derivation on model change.
        do {
            let before = KeychainHelper.load(key: ProviderProfiles.opencodeApiKeyKey)
            let result = await SetupAPICore.apply(
                ["provider": ["profile": "opencode", "model": "kimi-k3"]])
            check("apply provider: omitted key keeps the stored one",
                  isOK(result)
                  && KeychainHelper.load(key: ProviderProfiles.opencodeApiKeyKey) == before
                  && ProviderProfiles.configuredModel(.opencode) == "kimi-k3")
            check("apply provider: vision model flips text_only off after activation",
                  ProviderProfiles.textOnly(.opencode) == false
                  && KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "false")
        }

        // 7. Second profile does NOT hijack the active one by default; an
        // explicit activate:true switches.
        do {
            let saved = await SetupAPICore.apply(
                ["provider": ["profile": "local", "base_url": "http://localhost:1234/v1",
                              "model": "qwen-local", "text_only": true]])
            check("apply provider: second profile saved without activation",
                  isOK(saved) && ProviderProfiles.activeProfile() == .opencode
                  && ProviderProfiles.isConfigured(.local))
            let switched = await SetupAPICore.apply(
                ["provider": ["profile": "local", "model": "qwen-local",
                              "text_only": true, "activate": true]])
            check("apply provider: explicit activate switches (base_url kept from store)",
                  isOK(switched) && ProviderProfiles.activeProfile() == .local
                  && KeychainHelper.load(key: KeychainHelper.llmProviderKey)
                      == LLMProvider.lmStudio.rawValue)
            check("apply provider: non-catalog model without text_only → missing_field",
                  errorCode(await SetupAPICore.apply(
                      ["provider": ["profile": "openrouter", "api_key": "sk-or-x",
                                    "model": "some/model"]])) == "missing_field")
        }

        // 8. OpenAI fan-out (wizard step 2 parity) through the defaults seam.
        do {
            let result = await SetupAPICore.apply(["openai": ["api_key": "sk-openai-test-123456"]])
            let fanOutKeys = [
                KeychainHelper.webSearchOpenAIApiKeyKey,
                KeychainHelper.openAITranscriptionApiKeyKey,
                KeychainHelper.openAIImageApiKeyKey,
            ]
            check("apply openai: key fans out to research/voice/images",
                  isOK(result) && fanOutKeys.allSatisfy {
                      KeychainHelper.load(key: $0) == "sk-openai-test-123456"
                  })
            check("apply openai: providers + OCR backend set",
                  KeychainHelper.load(key: KeychainHelper.voiceTranscriptionProviderKey) == "openai"
                  && KeychainHelper.load(key: KeychainHelper.visionPreprocessorBackendKey) == "openai")
            check("apply openai: web-search backend stored via seam (not real defaults)",
                  suite.string(forKey: WebSearchBackend.selectionKey) == "openai")
            let status = await SetupAPICore.status()
            let web = status["web_search"] as? [String: Any]
            check("status: web_search explicit + active openai",
                  web?["active"] as? String == "openai" && web?["explicit"] as? Bool == true)
        }

        // 9. Remaining sections in one request — fixed order, all committed.
        do {
            let result = await SetupAPICore.apply([
                "serper": ["api_key": "serper-test-key-123"],
                "jina": ["api_key": "jina-test-key-1234"],
                "identity": ["user_name": "Sofia"],
                "telegram": ["token": "12345:test-token-abcdef", "chat_id": "5551234567"],
                "email_calendar": ["provider": "none"],
                "mark_complete": true,
            ])
            check("apply multi-section: ok with fixed order",
                  isOK(result) && result["applied"] as? [String]
                  == ["serper", "jina", "identity", "telegram", "email_calendar", "mark_complete"])
            check("apply multi-section: values persisted",
                  KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) == "serper-test-key-123"
                  && KeychainHelper.load(key: KeychainHelper.userNameKey) == "Sofia"
                  && KeychainHelper.load(key: KeychainHelper.assistantNameKey) == "Bree"
                  && KeychainHelper.load(key: KeychainHelper.emailCalendarProviderKey) == "none"
                  && TelegramConfig.isConfigured)
            let status = await SetupAPICore.status()
            let telegram = status["telegram"] as? [String: Any]
            check("status: setup complete, telegram configured + masked",
                  (status["setup"] as? [String: Any])?["complete"] as? Bool == true
                  && telegram?["configured"] as? Bool == true
                  && (telegram?["masked_token"] as? String ?? "").contains("…")
                  && telegram?["chat_id"] as? String == "5551234567")
        }

        // 10. Service verb: platform gate on macOS, Telegram gate on Linux
        // (checked before any systemd call, so it holds in containers too).
        do {
            #if os(Linux)
            try? KeychainHelper.delete(key: KeychainHelper.telegramBotTokenKey)
            let refused = await SetupAPICore.service(["action": "install"])
            check("service install: refuses without Telegram",
                  errorCode(refused) == "telegram_required")
            try? KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey,
                                     value: "12345:test-token-abcdef")
            let badAction = await SetupAPICore.service(["action": "explode"])
            check("service: unknown action → invalid_value", errorCode(badAction) == "invalid_value")
            let noAction = await SetupAPICore.service([:])
            check("service: no action and no script request → missing_field",
                  errorCode(noAction) == "missing_field")
            let scripts = await SetupAPICore.service(["keepawake_script": true])
            check("service: keepawake_script alone returns the bundle",
                  isOK(scripts) && scripts["wakelock_install_script"] is String
                  && scripts["wakelock_unit_text"] is String)
            // No unit + no user bus (this container): uninstall must answer
            // "unverified", never success (Codex round 3).
            if !AgentServiceSupport.systemdUserSessionAvailable() {
                let unverified = await SetupAPICore.service(["action": "uninstall"])
                check("service uninstall: no-unit-no-bus reports unverified",
                      errorCode(unverified) == "unverified")
            } else {
                print("• uninstall-unverified check skipped (user bus reachable here)")
            }
            #else
            let refused = await SetupAPICore.service(["action": "install"])
            check("service verb: unsupported on macOS",
                  errorCode(refused) == "unsupported_platform")
            #endif
        }

        // 11. Wakelock scripts mirror installWakelockService() step for step.
        // The read-only restore MUST be an EXIT/signal trap installed after
        // the rw remount and before any mutating step — with `set -e`, a
        // trailing remount line would be skipped on failure and leave the
        // system partition writable.
        do {
            let trapLine = "trap 'mount -o remount,ro / || echo "
            func trapGuardsMutations(_ script: String, firstMutation: String) -> Bool {
                guard let rw = script.range(of: "mount -o remount,rw /"),
                      let trap = script.range(of: trapLine),
                      let mutate = script.range(of: firstMutation) else { return false }
                return rw.lowerBound < trap.lowerBound
                    && trap.upperBound < mutate.lowerBound
                    && script.contains("EXIT INT TERM HUP")
            }
            let install = SetupAPICore.wakelockInstallScript()
            check("wakelock install script: remount rw, unit heredoc, enable",
                  install.contains("cat > \(AgentServiceSupport.wakelockUnitPath) <<'BRIGLIA_UNIT'")
                  && install.contains("ConditionPathExists=/sys/power/wake_lock")
                  && install.contains("\nBRIGLIA_UNIT\n")
                  && install.contains("chmod 644 \(AgentServiceSupport.wakelockUnitPath)")
                  && install.contains("systemctl daemon-reload")
                  && install.contains("systemctl enable --now \(AgentServiceSupport.wakelockUnitName)"))
            check("wakelock install script: ro-restore trap guards every mutating step",
                  trapGuardsMutations(install, firstMutation: "cat > "))
            let uninstall = SetupAPICore.wakelockUninstallScript()
            check("wakelock uninstall script: disable, rm, daemon-reload",
                  uninstall.contains("systemctl disable --now \(AgentServiceSupport.wakelockUnitName)")
                  && uninstall.contains("rm -f \(AgentServiceSupport.wakelockUnitPath)")
                  && uninstall.contains("systemctl daemon-reload"))
            check("wakelock uninstall script: ro-restore trap guards every mutating step",
                  trapGuardsMutations(uninstall, firstMutation: "systemctl disable"))
        }

        // 11b. Post-restart health verdict: only a settled "active" is
        // success — "activating" after the settle window means the first
        // exec already died and systemd is cycling toward a crash loop.
        do {
            check("restart health: 'active' (with noise) is healthy",
                  SetupAPICore.restartLeftUnitHealthy(isActiveOutput: "active\n"))
            check("restart health: activating/failed/inactive/empty are NOT healthy",
                  !SetupAPICore.restartLeftUnitHealthy(isActiveOutput: "activating")
                  && !SetupAPICore.restartLeftUnitHealthy(isActiveOutput: "failed\n")
                  && !SetupAPICore.restartLeftUnitHealthy(isActiveOutput: "inactive")
                  && !SetupAPICore.restartLeftUnitHealthy(isActiveOutput: ""))
        }

        // 12. save_failed: a read-only config dir surfaces as a structured
        // error, not a wizard-style exit(1). Root ignores permission bits,
        // so skip (loudly) when running as root — CI containers.
        do {
            if geteuid() == 0 {
                print("• save_failed injection skipped (running as root — chmod is ineffective)")
            } else {
                let configDir = StoragePaths.configRoot.path
                let fm = FileManager.default
                try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: configDir)
                let result = await SetupAPICore.apply(["serper": ["api_key": "will-not-save"]])
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDir)
                check("apply: unwritable config dir → save_failed, value not cached",
                      errorCode(result) == "save_failed"
                      && KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) == "serper-test-key-123")
            }
        }

        // 13. Delete semantics (the Settings screen's remove paths).
        do {
            let serperGone = await SetupAPICore.apply(["serper": ["remove": true]])
            check("remove serper: key deleted",
                  isOK(serperGone) && KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) == nil)
            let status = await SetupAPICore.status()
            check("status: removed serper reads as unset",
                  ((status["keys"] as? [String: Any])?["serper"] as? [String: Any])?["set"] as? Bool == false)

            let openaiGone = await SetupAPICore.apply(["openai": ["remove": true]])
            check("remove openai: all three fan-out slots deleted",
                  isOK(openaiGone)
                  && KeychainHelper.load(key: KeychainHelper.webSearchOpenAIApiKeyKey) == nil
                  && KeychainHelper.load(key: KeychainHelper.openAITranscriptionApiKeyKey) == nil
                  && KeychainHelper.load(key: KeychainHelper.openAIImageApiKeyKey) == nil)

            let nameGone = await SetupAPICore.apply(["identity": ["remove": true]])
            check("remove identity: user_name deleted, assistant stays Briglia",
                  isOK(nameGone)
                  && KeychainHelper.load(key: KeychainHelper.userNameKey) == nil
                  && KeychainHelper.load(key: KeychainHelper.assistantNameKey) == "Bree")

            let telegramGone = await SetupAPICore.apply(["telegram": ["remove": true]])
            check("remove telegram: token + chat id deleted",
                  isOK(telegramGone) && !TelegramConfig.isConfigured)

            let activeRefused = await SetupAPICore.apply(
                ["provider": ["profile": "local", "remove": true]])
            check("remove provider: ACTIVE profile refused (profile_active)",
                  errorCode(activeRefused) == "profile_active"
                  && ProviderProfiles.isConfigured(.local))
            let opencodeGone = await SetupAPICore.apply(
                ["provider": ["profile": "opencode", "remove": true]])
            check("remove provider: non-active profile forgotten",
                  isOK(opencodeGone) && !ProviderProfiles.isConfigured(.opencode)
                  && KeychainHelper.load(key: ProviderProfiles.opencodeApiKeyKey) == nil)

            // remove_credentials severs email access via the canonical
            // EmailCredentialWipe — including the gws config/token
            // DIRECTORY, exercised against the seam (the real one is
            // HOME-derived and must never be touched by a selftest).
            try? KeychainHelper.saveBatch([
                KeychainHelper.agentMailApiKeyKey: "am-test-key-123456",
                KeychainHelper.agentMailInboxAddressKey: "ada@agentmail.to",
                KeychainHelper.gwsOAuthClientIDKey: "id-123",
                KeychainHelper.gwsOAuthClientSecretKey: "secret-123",
            ])
            let fakeGwsDir = tempRoot.appendingPathComponent("gws-config", isDirectory: true)
            try? FileManager.default.createDirectory(at: fakeGwsDir, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: fakeGwsDir.appendingPathComponent("client_secret.json").path,
                contents: Data("{}".utf8))
            SetupAPICore.gwsConfigDirectoryOverride = fakeGwsDir
            defer { SetupAPICore.gwsConfigDirectoryOverride = nil }

            let kept = await SetupAPICore.apply(["email_calendar": ["provider": "none"]])
            check("email none: credentials + gws directory kept without remove_credentials",
                  isOK(kept)
                  && KeychainHelper.load(key: KeychainHelper.agentMailApiKeyKey) == "am-test-key-123456"
                  && FileManager.default.fileExists(atPath: fakeGwsDir.path))
            let forgotten = await SetupAPICore.apply(
                ["email_calendar": ["provider": "none", "remove_credentials": true]])
            check("email none + remove_credentials: agentmail + gws credentials AND gws directory deleted",
                  isOK(forgotten)
                  && KeychainHelper.load(key: KeychainHelper.agentMailApiKeyKey) == nil
                  && KeychainHelper.load(key: KeychainHelper.agentMailInboxAddressKey) == nil
                  && KeychainHelper.load(key: KeychainHelper.gwsOAuthClientIDKey) == nil
                  && KeychainHelper.load(key: KeychainHelper.gwsOAuthClientSecretKey) == nil
                  && KeychainHelper.load(key: KeychainHelper.emailCalendarProviderKey) == "none"
                  && !FileManager.default.fileExists(atPath: fakeGwsDir.path))
        }

        print(failures == 0 ? "\nsetup-api selftest: all checks passed"
                            : "\nsetup-api selftest: \(failures) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}
