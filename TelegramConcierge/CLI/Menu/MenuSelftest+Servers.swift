import Foundation

/// Round 3 (2026-09-25): lane-centric menu and named servers. Everything
/// here runs against the REAL secret store (the battery's temp XDG roots)
/// and its real lock: ProviderServers' migration, CRUD and activation, the
/// legacy writers that still write the carrier slots, the /provider listing
/// and stale-button refusal, and the menu page driven with the real
/// snapshot and the real setup-api (only network probes are faked).
extension MenuSelftestContext {
    /// The runtime slots a model request reads — what must be identical
    /// whether a carrier was activated the old way or through a server.
    static let runtimeKeys = [
        KeychainHelper.openAICompatibleBaseURLKey, KeychainHelper.openAICompatibleModelKey, KeychainHelper.openAICompatibleApiKeyKey,
        KeychainHelper.openAICompatibleReasoningEffortKey, KeychainHelper.llmProviderKey, KeychainHelper.textOnlyModelEnabledKey,
        ProviderProfiles.runtimeProtocolKey, ProviderProfiles.runtimeNativeMediaKey, ProviderProfiles.activeProfileKey,
        KeychainHelper.lmStudioBaseURLKey, KeychainHelper.lmStudioModelKey,
    ]

    func wipeStore() { try? KeychainHelper.transaction { $0 = [:] } }
    func runtime() -> [String: String] {
        let s = KeychainHelper.loadSnapshot()
        return Self.runtimeKeys.reduce(into: [:]) { out, key in out[key] = s[key] }
    }
    func servers() -> [ProviderServers.Server] { ProviderServers.list() ?? [] }
    func named(_ name: String) -> ProviderServers.Server? { servers().first { $0.name == name } }

    func namedServers() async {
        let key = "sk-cloud-0123456789abcdefghij"

        // MARK: Migration
        wipeStore()
        do {
            try ProviderProfiles.saveProfile(.local, apiKey: nil, baseURL: "http://localhost:1234/v1", model: "qwen3.8-27b", effort: nil, textOnly: false)
            try ProviderProfiles.saveProfile(.custom, apiKey: key, baseURL: "https://api.example.com/v1", model: "acme-large", effort: "medium", textOnly: true)
            try ProviderProfiles.activate(.custom)
        } catch { check("seed legacy profiles", false, "\(error)") }
        let runtimeBefore = runtime()
        ProviderProfiles.ensureMigrated()
        let migrated = servers()
        let local = named("Local server"), custom = named("Custom endpoint")
        check("migration: the local server and custom endpoint become two named servers",
              migrated.count == 2 && local?.baseURL == "http://localhost:1234/v1" && local?.keyed == false
              && custom?.apiKey == key && custom?.effort == "medium" && custom?.textOnly == true, "\(migrated)")
        check("migration: the active selection is kept (custom endpoint → its server) and the runtime slots are untouched",
              ProviderServers.activeServer()?.id == custom?.id && ProviderProfiles.activeProfile() == .custom && runtime() == runtimeBefore)
        let afterFirst = KeychainHelper.loadSnapshot()
        ProviderProfiles.ensureMigrated()
        ProviderProfiles.ensureMigrated()
        check("migration: running it again changes nothing (idempotent)", KeychainHelper.loadSnapshot() == afterFirst)

        // MARK: Byte-identical activation
        do {
            try ProviderProfiles.activate(.local)
            let viaProfile = runtime()
            try ProviderProfiles.activate(.custom)
            try ProviderServers.use(local!.id)
            check("activation: a keyless server writes exactly what activating the local profile writes", runtime() == viaProfile,
                  "\(runtime()) vs \(viaProfile)")
            try ProviderProfiles.activate(.custom)
            let viaCustom = runtime()
            try ProviderProfiles.activate(.local)
            try ProviderServers.use(custom!.id)
            check("activation: a keyed server writes exactly what activating the custom endpoint writes", runtime() == viaCustom,
                  "\(runtime()) vs \(viaCustom)")
            try KeychainHelper.saveBatch([ProviderProfiles.customProtocolKey: "responses", ProviderProfiles.customNativeMediaKey: "false"])
            try ProviderProfiles.activate(.custom)
            let viaResponses = runtime()
            try ProviderServers.use(local!.id)
            try ProviderServers.use(custom!.id)
            check("activation: a Responses server writes exactly what the custom Responses profile writes",
                  runtime() == viaResponses && viaResponses[ProviderProfiles.runtimeProtocolKey] == "responses", "\(runtime()) vs \(viaResponses)")
            try KeychainHelper.saveBatch([ProviderProfiles.customProtocolKey: String?.none, ProviderProfiles.customNativeMediaKey: String?.none])
            try ProviderProfiles.activate(.custom)
        } catch { check("activation rows", false, "\(error)") }

        // MARK: CRUD
        do {
            let lab = try ProviderServers.save(.init(id: nil, name: "Lab box", baseURL: "192.168.1.20:8000/v1/", apiKey: "", model: "gemma-4-12b", textOnly: false))
            check("add: a new server is saved (address normalized) without taking over", lab.baseURL == "http://192.168.1.20:8000/v1"
                  && servers().count == 3 && ProviderServers.activeServer()?.id == custom?.id && lab.id.hasPrefix(ProviderServers.idPrefix))
            let runtimeBeforeUse = runtime()
            try ProviderServers.use(lab.id)
            let store = KeychainHelper.loadSnapshot()
            check("use: the new server takes the local carrier and runs; the one it displaced keeps its record",
                  ProviderServers.activeServer()?.id == lab.id && store[KeychainHelper.lmStudioModelKey] == "gemma-4-12b"
                  && store[ProviderServers.localBindingKey] == lab.id && named("Local server")?.model == "qwen3.8-27b" && runtime() != runtimeBeforeUse)
            do { try ProviderServers.remove(lab.id); check("remove: the server in use is refused", false) } catch {
                check("remove: the server in use is refused", (error as? ProviderServers.Failure) == .active && servers().count == 3)
            }
            try ProviderServers.use(custom!.id)
            try ProviderServers.remove(lab.id)
            let after = KeychainHelper.loadSnapshot()
            check("remove: a server not in use goes, and its carrier slots with it",
                  servers().count == 2 && after[ProviderServers.localBindingKey] == nil && after[KeychainHelper.lmStudioBaseURLKey] == nil
                  && !ProviderProfiles.isConfigured(.local))
            try ProviderServers.remove(named("Local server")!.id)
            check("remove: an unbound server not in use is removed", servers().map(\.name) == ["Custom endpoint"])
        } catch { check("CRUD rows", false, "\(error)") }

        // MARK: /model and /effort land in the running server
        do {
            let running = ProviderServers.activeServer()!
            try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "acme-xl")
            ProviderProfiles.recordModelChange("acme-xl", textOnly: false)
            ProviderProfiles.recordEffortChange("low")
            let now = ProviderServers.activeServer()
            check("/model and /effort write back into the running server", now?.id == running.id && now?.model == "acme-xl" && now?.effort == "low" && now?.textOnly == false)
            try ProviderServers.save(.init(id: running.id, name: "Acme cloud", baseURL: running.baseURL, apiKey: nil, model: "acme-large", textOnly: false))
            let store = KeychainHelper.loadSnapshot()
            check("edit: renaming/changing the running server applies to the runtime at once and keeps its key",
                  store[KeychainHelper.openAICompatibleModelKey] == "acme-large" && store[KeychainHelper.openAICompatibleApiKeyKey] == key
                  && named("Acme cloud")?.effort == "low" && ProviderServers.activeServer()?.name == "Acme cloud")
            _ = try ProviderServers.save(.init(id: nil, name: "Home", baseURL: "http://localhost:1234/v1", apiKey: "", model: "qwen3.8-27b", textOnly: true, activate: true))
            let home = named("Home")!
            try ProviderServers.save(.init(id: home.id, name: "Home", baseURL: "https://gpu.example.org/v1", apiKey: "sk-home-0123456789abcdef", model: "qwen3.8-27b", textOnly: true))
            let moved = KeychainHelper.loadSnapshot()
            check("edit: giving the running keyless server a key moves it to the keyed carrier (local slots cleared)",
                  ProviderProfiles.activeProfile() == .custom && ProviderServers.activeServer()?.id == home.id
                  && moved[KeychainHelper.lmStudioBaseURLKey] == nil && moved[KeychainHelper.llmProviderKey] == LLMProvider.openAICompatible.rawValue
                  && moved[KeychainHelper.textOnlyModelEnabledKey] == "true" && named("Acme cloud")?.apiKey == key)
            try ProviderServers.save(.init(id: home.id, name: "Home", baseURL: "https://gpu2.example.org/v1", apiKey: nil, model: "qwen3.8-27b", textOnly: true))
            check("edit: a new address without a new key drops the saved key (never sent to another host)",
                  named("Home")?.keyed == false && ProviderProfiles.activeProfile() == .local)
        } catch { check("mirror/edit rows", false, "\(error)") }

        // MARK: Validation
        func refusal(_ input: ProviderServers.Input) -> ProviderServers.Failure? {
            do { try ProviderServers.save(input); return nil } catch { return error as? ProviderServers.Failure }
        }
        let count = servers().count
        check("names: empty, duplicate (any case), reserved and too-long names are refused",
              refusal(.init(name: "  ", baseURL: "http://localhost:1/v1", apiKey: "", model: "m", textOnly: false)) != nil
              && refusal(.init(name: "home", baseURL: "http://localhost:1/v1", apiKey: "", model: "m", textOnly: false)) != nil
              && refusal(.init(name: "OpenRouter", baseURL: "http://localhost:1/v1", apiKey: "", model: "m", textOnly: false)) != nil
              && refusal(.init(name: String(repeating: "x", count: 41), baseURL: "http://localhost:1/v1", apiKey: "", model: "m", textOnly: false)) != nil
              && servers().count == count)
        check("keys: a key is never saved for plain http over the internet",
              refusal(.init(name: "Remote", baseURL: "http://api.example.com/v1", apiKey: "sk-x-0123456789abcdef", model: "m", textOnly: false)) != nil)
        do {
            var added = 0
            while servers().count < ProviderServers.maxServers {
                added += 1
                try ProviderServers.save(.init(name: "Box \(added)", baseURL: "http://localhost:\(2000 + added)/v1", apiKey: "", model: "m", textOnly: false))
            }
            check("cap: the list stops at \(ProviderServers.maxServers) servers",
                  refusal(.init(name: "One more", baseURL: "http://localhost:3999/v1", apiKey: "", model: "m", textOnly: false)) == .full)
            for s in servers() where s.name.hasPrefix("Box ") { try ProviderServers.remove(s.id) }
        } catch { check("cap rows", false, "\(error)") }

        // MARK: Legacy writers keep working through the carriers
        do {
            let acme = named("Acme cloud")!
            try ProviderServers.use(acme.id)
            let result = await SetupAPICore.apply(["provider": ["profile": "custom", "model": "acme-small", "effort": "high"]], ownsLease: true)
            check("setup-api: a provider edit of the custom endpoint lands in the server it carries",
                  result["ok"] as? Bool == true && named("Acme cloud")?.model == "acme-small" && named("Acme cloud")?.effort == "high", "\(result)")
            try ProviderServers.use(named("Home")!.id)
            let removed = await SetupAPICore.apply(["provider": ["profile": "custom", "remove": true]], ownsLease: true)
            check("setup-api: removing the custom endpoint removes the server it carried", removed["ok"] as? Bool == true && named("Acme cloud") == nil, "\(removed)")
            let sv = await SetupAPICore.apply(["server": ["action": "save", "name": "Cloud", "base_url": "https://api.example.com/v1", "api_key": key, "model": "acme-large"]], ownsLease: true)
            let bad = await SetupAPICore.apply(["server": ["action": "save", "name": "Cloud 2", "base_url": "https://api.example.com/v1", "model": "m", "text_only": "true"]], ownsLease: true)
            check("setup-api: the server section saves, and refuses a non-boolean text_only",
                  sv["ok"] as? Bool == true && named("Cloud")?.keyed == true && (bad["error"] as? [String: Any])?["code"] as? String == "invalid_value")
            let status = await SetupAPICore.status()
            let listed = ((status["providers"] as? [String: Any])?["servers"] as? [[String: Any]]) ?? []
            check("setup-api status lists the servers with masked keys only",
                  listed.count == servers().count && !String(describing: status).contains(key) && listed.contains { $0["name"] as? String == "Cloud" && $0["masked_key"] != nil })
        } catch { check("legacy writer rows", false, "\(error)") }

        // MARK: /provider on Telegram
        do {
            let cloud = named("Cloud")!, home = named("Home")!
            let choices = ConversationManager.providerChoices()
            check("/provider: each server is its own button, by name, active one ticked",
                  choices.contains { $0.id == cloud.id && $0.displayName == "Cloud" } && choices.contains { $0.id == home.id && $0.active }
                  && !choices.contains { $0.id == "custom" || $0.id == "local" })
            let menu = TelegramCommandMenu.providerMenu(statusLines: ProviderProfiles.statusLines(), configured: choices)
            let button = menu.rows.flatMap { $0 }.first { $0.label == "Cloud" }
            let decoded = button.flatMap { TelegramCommandMenu.decode($0.data) }
            check("/provider: a server button decodes to /provider <its id>, which resolves to that server",
                  decoded == .provider(cloud.id) && decoded.flatMap(TelegramCommandMenu.commandText) == "/provider \(cloud.id)"
                  && ProviderServers.resolve(cloud.id) == .server(cloud.id))
            check("/provider: typed names resolve case-insensitively; the old custom/local names stay profiles",
                  ProviderServers.resolve("cLoUd") == .server(cloud.id) && ProviderServers.resolve("custom") == .profile(.custom)
                  && ProviderServers.resolve("nobody") == nil)
            check("/provider: the listing shows every server by name", ProviderProfiles.statusLines().contains { $0.hasPrefix("• Cloud [server]") }
                  && ProviderProfiles.statusLines().contains { $0.hasPrefix("• Home [server] — ACTIVE") })
            let homeContext = ProviderProfiles.menuContextIdentity()
            try ProviderServers.use(cloud.id)
            check("/effort menus are bound to the server, not just the carrier", homeContext != ProviderProfiles.menuContextIdentity()
                  && ProviderProfiles.menuContextIdentity() == "custom#\(cloud.id)")
            check("/provider: a live server button is not stale", ProviderServers.staleProviderTap(home.id) == nil)
            try ProviderServers.remove(home.id)
            check("/provider: a button for a removed server is refused as outdated",
                  ProviderServers.staleProviderTap(home.id)?.contains("outdated") == true && ProviderServers.resolve(home.id) == nil)
        } catch { check("/provider rows", false, "\(error)") }

        // MARK: Damaged list
        do {
            try KeychainHelper.save(key: ProviderServers.listKey, value: "{not json")
            let before = KeychainHelper.loadSnapshot()
            ProviderProfiles.ensureMigrated()
            let refused = (try? ProviderServers.save(.init(name: "X", baseURL: "http://localhost:1/v1", apiKey: "", model: "m", textOnly: false))) == nil
            check("damaged list: kept byte-for-byte, every operation refuses, listing reports it",
                  KeychainHelper.loadSnapshot() == before && refused && ProviderServers.list() == nil
                  && ProviderProfiles.statusLines().contains { $0.contains("damaged") })
            try KeychainHelper.delete(key: ProviderServers.listKey)
        } catch { check("damaged rows", false, "\(error)") }

        // MARK: Mind and /deleteuserdata leave servers alone (like profiles)
        if let root = Self.repoRoot() {
            let mind = (try? String(contentsOf: root.appendingPathComponent("TelegramConcierge/Services/MindExportService.swift"), encoding: .utf8)) ?? ""
            let cm = (try? String(contentsOf: root.appendingPathComponent("TelegramConcierge/Services/ConversationManager.swift"), encoding: .utf8)) ?? ""
            let wipe = cm.components(separatedBy: "func deleteAllMemory()").dropFirst().first?.prefix(20000) ?? ""
            check("Mind export/import and /deleteuserdata never touch the server list or its keys (same rule as profiles)",
                  !mind.isEmpty && !wipe.isEmpty && !mind.contains("ProviderServers") && !mind.contains("ProviderProfiles.")
                  && !wipe.contains("ProviderServers") && !wipe.contains("provider_servers"))
        } else {
            print("skip Mind/deleteuserdata source scan (repo root not found)")
        }

        await menuWithRealStore(key: key)
        wipeStore()
    }

    static func repoRoot() -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: dir.appendingPathComponent("TelegramConcierge").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// The page, with the real snapshot and the real setup-api writing the
    /// real store; only the network checks are fakes.
    func menuWithRealStore(key: String) async {
        wipeStore()
        var env = MenuEnvironment()
        env.language = "en"
        env.toolchainStatus = { ToolchainService.DesktopStatus(doctorRan: true, missing: [], libreOffice: true, mandatoryMissing: []) }
        env.probe = { _ in ["ok": true] }
        env.localModels = { _, apiKey in apiKey == nil || apiKey == key ? .success(["acme-large", "acme-small"]) : .failure(.http(401)) }
        env.markComplete = {}
        env.openURL = { _ in }
        let wf = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
        await wf.start()
        await wf.settle()
        func act(_ body: [String: Any]) async -> [String: Any] { await self.act(wf, body) }
        func aiServers() -> [[String: Any]] { ai(wf)["servers"] as? [[String: Any]] ?? [] }

        await act(["action": "lane", "lane": "local"])
        await act(["action": "local_models", "base_url": "https://api.example.com/v1", "api_key": key])
        var r = await act(["action": "server_save", "name": "Acme cloud", "base_url": "https://api.example.com/v1", "model": "acme-large", "text_only": false])
        let saved = named("Acme cloud")
        check("page (real store): adding a keyed server saves it with its key and makes it the one in use",
              ok(r) && saved?.apiKey == key && ProviderServers.activeServer()?.id == saved?.id
              && KeychainHelper.load(key: KeychainHelper.openAICompatibleApiKeyKey) == key, "\(r)")
        check("page (real store): the key never reaches the page", !json(wf.status()).contains(key) && (aiServers().first?["key"] as? String)?.isEmpty == false)
        await act(["action": "local_models", "base_url": "http://localhost:1234/v1"])
        r = await act(["action": "server_save", "name": "Home GPU", "base_url": "http://localhost:1234/v1", "model": "acme-small"])
        check("page (real store): a second, keyless server is added and runs", ok(r) && named("Home GPU")?.keyed == false && ai(wf)["active_server"] as? String == named("Home GPU")?.id)
        r = await act(["action": "server_use", "id": saved?.id ?? ""])
        check("page (real store): Use switches back to the first server", ok(r) && ProviderServers.activeServer()?.name == "Acme cloud")

        // A /model sent on Telegram while the page is open: the page's
        // next save on that server is refused, nothing written.
        try? KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "acme-xl")
        ProviderProfiles.recordModelChange("acme-xl", textOnly: nil)
        let serversAfterTelegram = servers(), runtimeAfterTelegram = runtime()
        r = await act(["action": "server_save", "id": saved?.id ?? "", "name": "Acme renamed", "base_url": "https://api.example.com/v1", "model": "acme-large"])
        check("page (real store): an edit based on settings changed from Telegram is refused and saves nothing",
              !ok(r) && msg(r).contains("changed elsewhere") && servers() == serversAfterTelegram && runtime() == runtimeAfterTelegram
              && named("Acme cloud")?.model == "acme-xl", "\(r)")
        r = await act(["action": "server_save", "id": saved?.id ?? "", "name": "Acme renamed", "base_url": "https://api.example.com/v1", "model": "acme-xl"])
        check("page (real store): after the refresh the same edit goes through", ok(r) && named("Acme renamed")?.model == "acme-xl" && ProviderServers.activeServer()?.name == "Acme renamed")
        r = await act(["action": "lane_remove", "lane": "server", "id": saved?.id ?? ""])
        check("page (real store): the server in use can't be removed", !ok(r) && named("Acme renamed") != nil)
        r = await act(["action": "lane_remove", "lane": "server", "id": named("Home GPU")?.id ?? ""])
        check("page (real store): a server not in use is removed", ok(r) && named("Home GPU") == nil && aiServers().count == 1)
        await wf.shutdown()
    }
}
