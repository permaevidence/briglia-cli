import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Owner request 2026-10-15: new users are steered to OpenRouter (not the
/// ChatGPT subscription); the setup says the default model is DeepSeek V4.1
/// Flash hosted on Together, and a NEW OpenRouter setup is pinned to
/// `together` after the `/orprovider` host-list check. Existing installs,
/// their provider, model and any stored pin are never changed blindly.
/// Round 2 (Codex 2026-10-15): every OpenRouter save goes through ONE
/// model/pin rule (`OpenRouterProviderPin.reconcile`) committed in the same
/// locked write as the model; conditional pin writes read their condition
/// under the store lock; a default host that can't be confirmed is said.
@MainActor
extension MenuSelftestContext {

    func lastOpenRouterSection(_ w: MenuFakeWorld) -> [String: Any] {
        (w.applied.last { ($0["provider"] as? [String: Any])?["profile"] as? String == "openrouter" }?["provider"] as? [String: Any]) ?? [:]
    }

    func openRouterDefault() async {
        // 1. Fresh install: OpenRouter is the lane shown and recommended.
        do {
            let w = world()
            let wf = await make(w)
            check("or-default: a fresh install recommends OpenRouter and names the default model and host",
                  ai(wf)["lane"] as? String == "openrouter" && ai(wf)["recommended_lane"] as? String == "openrouter"
                  && ai(wf)["openrouter_default"] as? String == "deepseek/deepseek-v4.1-flash"
                  && ai(wf)["openrouter_default_label"] as? String == "DeepSeek V4.1 Flash"
                  && ai(wf)["openrouter_default_host"] as? String == "Together"
                  && (ai(wf)["openrouter_pin"] as? [String]) == [])

            // 2. Fresh OpenRouter setup → the host list rides with the profile, pinned to together.
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            let sec = lastOpenRouterSection(w)
            check("or-default: the first OpenRouter setup asks for the default host and hands over the host list read before the save",
                  ok(r) && sec["model"] as? String == MenuWorkflow.openRouterDefaultModel && sec["default_host_pin"] as? Bool == true
                  && (sec["host_listing"] as? [String: Any])?["model"] as? String == MenuWorkflow.openRouterDefaultModel
                  && ((sec["host_listing"] as? [String: Any])?["hosts"] as? [String])?.contains("together") == true
                  && w.snap.openRouterPin == ["together"] && (ai(wf)["openrouter_pin"] as? [String]) == ["together"]
                  && w.orHostAsks == [MenuWorkflow.openRouterDefaultModel])
            check("or-default: the confirmation says where it runs", msg(r).contains("on Together") && msg(r).contains("/orprovider"))

            // 3. Model change on the pinned lane: served → kept; not served → released.
            w.orHosts["z-ai/glm-5.3-flash"] = ["z-ai", "together"]
            var r2 = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "z-ai/glm-5.3-flash"])
            check("or-default: a new model the pinned host serves keeps the pin",
                  ok(r2) && w.snap.openRouterPin == ["together"] && !msg(r2).contains("released"))
            r2 = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "anthropic/claude-haiku-5.5"])
            check("or-default: a new model the pinned host doesn't serve releases the pin and says so",
                  ok(r2) && w.snap.openRouterPin.isEmpty && msg(r2).contains("released")
                  && (lastOpenRouterSection(w)["host_listing"] as? [String: Any])?["model"] as? String == "anthropic/claude-haiku-5.5")
        }

        // 4. Pinned lane, host list unreadable during a model change: kept + warning.
        do {
            let w = world()
            w.snap.providers["openrouter"] = MenuSnapshot.Provider(configured: true, model: MenuWorkflow.openRouterDefaultModel, effort: "high", keyMasked: "sk-or…cdef")
            w.snap.activeProfile = "openrouter"
            w.snap.openRouterPin = ["together"]
            let wf = await make(w)
            w.orHostsFail = true
            let r = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "anthropic/claude-haiku-5.5"])
            check("or-default: an unreadable host list keeps the pin and warns", ok(r) && w.snap.openRouterPin == ["together"]
                  && msg(r).contains("/orprovider off") && msg(r).contains("HTTP 503"))
        }

        // 5. Existing installs are untouched.
        do {
            let w = world()
            w.snap.chatgpt = .signedIn(active: true, model: "gpt-6.1-sol", effort: "high", generation: "g1")
            w.snap.activeProfile = "chatgpt"
            let wf = await make(w)
            check("or-default: an install on ChatGPT stays on ChatGPT, nothing written", ai(wf)["lane"] as? String == "chatgpt"
                  && ai(wf)["active"] as? String == "chatgpt" && w.applied.isEmpty && w.orHostAsks.isEmpty)
        }
        do {
            let w = world()
            w.snap.activeProfile = "custom"
            w.snap.otherProvider = "Custom endpoint"
            let wf = await make(w)
            check("or-default: an install on a setup-made provider keeps the ChatGPT fallback lane, nothing written",
                  ai(wf)["lane"] as? String == "chatgpt" && w.applied.isEmpty)
        }
        do {
            let w = world()
            w.snap.chatgpt = .loginRequired
            let wf = await make(w)
            check("or-default: an expired ChatGPT login is not a fresh install", ai(wf)["lane"] as? String == "chatgpt")
        }
        do {
            // OpenRouter already configured without a pin (never pinned, or /orprovider off).
            let w = world()
            w.snap.providers["openrouter"] = MenuSnapshot.Provider(configured: true, model: MenuWorkflow.openRouterDefaultModel, effort: "high", keyMasked: "sk-or…cdef")
            w.snap.activeProfile = "openrouter"
            let wf = await make(w)
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]! + "-alt"])
            check("or-default: an existing OpenRouter setup (pin off) gets no pin on a new key, no host list read",
                  ok(r) && w.snap.openRouterPin.isEmpty && w.orHostAsks.isEmpty
                  && (lastOpenRouterSection(w)["host_listing"] as? [String: Any])?["skip"] as? Bool == true)
        }
        do {
            // An explicit pin stored before OpenRouter is (re)added: never overwritten.
            let w = world()
            w.snap.openRouterPin = ["deepinfra"]
            w.orHosts[MenuWorkflow.openRouterDefaultModel] = ["novita/fp8", "together", "deepinfra/fp8"]
            let wf = await make(w)
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            check("or-default: an explicit stored pin is never overwritten by a new setup",
                  ok(r) && w.snap.openRouterPin == ["deepinfra"] && !msg(r).contains("on Together"))
        }

        // 6. Fresh setup but Together can't be confirmed: routing automatic, and SAID (EN + IT).
        for (label, configure) in [("Together no longer serves the model", { (w: MenuFakeWorld) in w.orHosts[MenuWorkflow.openRouterDefaultModel] = ["novita/fp8"] }),
                                   ("the host list can't be read", { (w: MenuFakeWorld) in w.orHostsFail = true })] {
            let w = world()
            configure(w)
            let wf = await make(w)
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            check("or-default: no pin when \(label), and the confirmation says Together couldn't be selected",
                  ok(r) && ai(wf)["active"] as? String == "openrouter" && w.snap.openRouterPin.isEmpty
                  && msg(r).contains("Together couldn\u{2019}t be selected") && msg(r).contains("OpenRouter chooses the host"))
        }
        do {
            let w = world()
            w.orHostsFail = true
            let wf = await make(w)
            await act(wf, ["action": "lang", "lang": "it"])
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            check("or-default: the Italian confirmation says Together couldn't be chosen",
                  ok(r) && msg(r).contains("Non è stato possibile scegliere Together") && msg(r).contains("lo sceglie OpenRouter"))
        }

        // Round 3 (Codex answer 1): every OpenRouter save the menu makes hands
        // setup-api a host list or an explicit skip, so setup-api never
        // fetches inside the menu's barrier.
        do {
            let w = world()
            let wf = await make(w)
            _ = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            _ = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "anthropic/claude-haiku-5.5"])
            _ = await act(wf, ["action": "effort", "effort": "medium"])
            _ = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]! + "-alt"])
            let sections = w.applied.compactMap { $0["provider"] as? [String: Any] }.filter { $0["profile"] as? String == "openrouter" }
            check("or-default: every menu OpenRouter save (key, model, effort) carries host_listing (list or skip)",
                  sections.count == 4 && sections.allSatisfy { $0["host_listing"] is [String: Any] }, "\(sections.map { $0["host_listing"] != nil })")
        }

        do {
            // Switching to a saved OpenRouter lane (no model change) also hands over a skip.
            let w = world()
            w.snap.providers["openrouter"] = MenuSnapshot.Provider(configured: true, model: MenuWorkflow.openRouterDefaultModel, effort: "high", keyMasked: "sk-or…cdef")
            w.snap.providers["opencode"] = MenuSnapshot.Provider(configured: true, model: OpenCodeGo.defaultModel, effort: "high", keyMasked: "oc…cdef")
            w.snap.activeProfile = "opencode"
            w.snap.openAIMasked = "sk-…ghij"
            w.snap.openRouterPin = ["together"]
            let wf = await make(w)
            let r = await act(wf, ["action": "provider_use", "profile": "openrouter"])
            let sec = lastOpenRouterSection(w)
            check("or-default: switching to the saved OpenRouter lane hands setup-api an explicit skip, pin kept",
                  ok(r) && (sec["host_listing"] as? [String: Any])?["skip"] as? Bool == true && w.snap.openRouterPin == ["together"] && w.orHostAsks.isEmpty, "\(sec)")
        }

        // 7. The decision helpers.
        let together = OpenRouterProviderPin.Endpoint(providerName: "Together", tag: "together", promptUSDPerM: nil, completionUSDPerM: nil,
                                                      cacheReadUSDPerM: nil, contextLength: nil, uptimeLast30m: nil, status: 0)
        check("or-default: decision pins together for the default model when served",
              OpenRouterProviderPin.newSetupDecision(model: ProviderProfiles.openRouterSetupDefaultModel, listing: .success([together])) == .pin("together"))
        if case .skip = OpenRouterProviderPin.newSetupDecision(model: "moonshotai/kimi-k3", listing: .success([together])) {
            check("or-default: decision never pins another model", true)
        } else { check("or-default: decision never pins another model", false) }
        if case .skip = OpenRouterProviderPin.newSetupDecision(model: ProviderProfiles.openRouterSetupDefaultModel, listing: .failure(CancellationError())) {
            check("or-default: a cancelled host check doesn't pin", true)
        } else { check("or-default: a cancelled host check doesn't pin", false) }
        do {
            var fetched = 0
            OpenRouterProviderPin.fetchOverride = { _, _ in fetched += 1; throw OpenRouterProviderPin.FetchError(description: "must not be called") }
            var probeStore: [String: String] = [OpenRouterProviderPin.storageKey: "together"]
            _ = OpenRouterProviderPin.reconcile(&probeStore, keyBefore: "", modelBefore: "", newModel: MenuWorkflow.openRouterDefaultModel, listing: nil, newSetupDefault: true)
            _ = OpenRouterProviderPin.reconcile(&probeStore, keyBefore: "k", modelBefore: "a/b", newModel: "c/d", listing: nil, newSetupDefault: false)
            OpenRouterProviderPin.fetchOverride = nil
            check("or-default rule: reconcile performs no I/O (never fetches a host list)", fetched == 0)
            var store: [String: String] = [OpenRouterProviderPin.storageKey: "together"]
            let out = OpenRouterProviderPin.reconcile(&store, keyBefore: "k", modelBefore: MenuWorkflow.openRouterDefaultModel,
                                                      newModel: "x/y", listing: nil, newSetupDefault: false)
            check("or-default rule: a model change with no host list keeps the pin unverified",
                  store[OpenRouterProviderPin.storageKey] == "together" && out == .keptUnverified(["together"], reason: "the host list wasn't checked"))
            let stale = OpenRouterProviderPin.HostListing(model: "other/model", result: .success([]))
            var store2: [String: String] = [OpenRouterProviderPin.storageKey: "together"]
            let out2 = OpenRouterProviderPin.reconcile(&store2, keyBefore: "k", modelBefore: MenuWorkflow.openRouterDefaultModel,
                                                       newModel: "x/y", listing: stale, newSetupDefault: false)
            check("or-default rule: a host list for another model is never used to release a pin",
                  store2[OpenRouterProviderPin.storageKey] == "together" && out2 == .keptUnverified(["together"], reason: "the host list wasn't checked"))
        }

        // 8. Quick Setup: fresh + OpenRouter key → OpenRouter runs with the default host; OpenCode-only stays usable.
        do {
            let base: [String: Any] = ["name": "x", "openai": ["value": "a"], "serper": ["value": "a"], "jina": ["value": "a"], "telegram": ["token": "t", "chat_id": "1"]]
            var orOnly = base; orOnly["openrouter"] = ["value": "or-key"]
            let parsed = try? QuickSetupRequest.parse(orOnly)
            check("or-default quick: an OpenRouter key alone is a valid main provider", parsed != nil)
            var neither = base
            neither["custom"] = ["api_key": "k", "base_url": "u", "model": "m"]
            check("or-default quick: without OpenCode, ChatGPT or OpenRouter the main provider is still required",
                  (try? QuickSetupRequest.parse(neither)) == nil)
            if let parsed {
                check("or-default quick: fresh install + OpenRouter key prefers OpenRouter", QuickSetupWorkflow.prefersOpenRouter(parsed, activeProfile: nil))
                check("or-default quick: an existing install (provider saved) keeps its provider", !QuickSetupWorkflow.prefersOpenRouter(parsed, activeProfile: "opencode"))
                let main = QuickSetupWorkflow.applyPayload(section: "provider", request: parsed, preferOpenRouter: true)?["provider"] as? [String: Any]
                check("or-default quick: the main provider is OpenRouter on DeepSeek V4.1 Flash, active, asking for the default host",
                      main?["profile"] as? String == "openrouter" && main?["model"] as? String == ProviderProfiles.openRouterSetupDefaultModel
                      && main?["activate"] as? Bool == true && main?["default_host_pin"] as? Bool == true)
            }
            var both = base; both["openrouter"] = ["value": "or-key"]; both["opencode"] = ["value": "oc-key"]
            if let parsedBoth = try? QuickSetupRequest.parse(both) {
                let main = QuickSetupWorkflow.applyPayload(section: "provider", request: parsedBoth, preferOpenRouter: true)?["provider"] as? [String: Any]
                let alt = QuickSetupWorkflow.applyPayload(section: "opencode", request: parsedBoth, preferOpenRouter: true)?["provider"] as? [String: Any]
                check("or-default quick: on a fresh setup the OpenRouter key isn't also saved a second time as an alternative",
                      QuickSetupWorkflow.applyPayload(section: "openrouter", request: parsedBoth, preferOpenRouter: true) == nil)
                check("or-default quick: both keys on a fresh setup → OpenRouter runs, OpenCode is saved inactive",
                      main?["profile"] as? String == "openrouter" && alt?["profile"] as? String == "opencode" && alt?["activate"] as? Bool == false)
                let keepMain = QuickSetupWorkflow.applyPayload(section: "provider", request: parsedBoth, preferOpenRouter: false)?["provider"] as? [String: Any]
                check("or-default quick: on an existing setup OpenCode stays the main provider",
                      keepMain?["profile"] as? String == "opencode" && keepMain?["activate"] as? Bool == true)
            } else { check("or-default quick: both keys parse", false) }
            // Round 3: the OpenAI key is optional when OpenRouter may run Briglia.
            var noOpenAI = orOnly; noOpenAI.removeValue(forKey: "openai")
            check("or-default quick: an OpenRouter form without an OpenAI key parses", (try? QuickSetupRequest.parse(noOpenAI)) != nil)
            var ocNoOpenAI = base; ocNoOpenAI.removeValue(forKey: "openai"); ocNoOpenAI["opencode"] = ["value": "oc-key"]
            check("or-default quick: an OpenCode form without an OpenAI key is still refused", (try? QuickSetupRequest.parse(ocNoOpenAI)) == nil)
            var chatNoOpenAI = noOpenAI; chatNoOpenAI["chatgpt"] = ["model": "gpt-6.1-sol", "effort": "high", "generation": UUID().uuidString]
            check("or-default quick: with ChatGPT chosen the OpenAI key stays required", (try? QuickSetupRequest.parse(chatNoOpenAI)) == nil)
            // The final check requires what the running provider needs (Codex round 2 P1).
            let orKeys = QuickSetupWorkflow.requiredStoredKeys(activeProfile: "openrouter")
            check("or-default quick: the final check on OpenRouter needs its key and model, not OpenCode or OpenAI",
                  orKeys.contains(KeychainHelper.openRouterApiKeyKey) && orKeys.contains(KeychainHelper.openRouterModelKey)
                  && !orKeys.contains(ProviderProfiles.opencodeApiKeyKey) && !orKeys.contains(KeychainHelper.openAITranscriptionApiKeyKey))
            let ocKeys = QuickSetupWorkflow.requiredStoredKeys(activeProfile: "opencode")
            check("or-default quick: the final check on OpenCode still needs the OpenCode and OpenAI keys",
                  ocKeys.contains(ProviderProfiles.opencodeApiKeyKey) && ocKeys.contains(KeychainHelper.openAITranscriptionApiKeyKey))
            let gptKeys = QuickSetupWorkflow.requiredStoredKeys(activeProfile: "chatgpt")
            check("or-default quick: the final check on ChatGPT keeps its model and the OpenAI key",
                  gptKeys.contains(ProviderProfiles.subscriptionModelKey) && gptKeys.contains(KeychainHelper.openAITranscriptionApiKeyKey) && !gptKeys.contains(ProviderProfiles.opencodeApiKeyKey))
            var keptOR = base; keptOR["openrouter"] = ["kept": true]
            if let parsedKept = try? QuickSetupRequest.parse(keptOR) {
                check("or-default quick: a kept (already stored) OpenRouter key is not a new setup", !QuickSetupWorkflow.prefersOpenRouter(parsedKept, activeProfile: nil))
            }
        }

        // 9. The real setup-api path (isolated XDG roots set by the battery).
        await setupAPIPinChecks()
    }

    // MARK: setup-api, real store

    private func storeURL() -> URL { StoragePaths.configRoot.appendingPathComponent("secrets.json") }

    /// Replace one key in the store file the way another process would,
    /// atomically, while the caller holds the sidecar lock.
    private func externalWrite(_ key: String, _ value: String?) {
        let url = storeURL()
        var dict = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: String]) ?? [:]
        if let value { dict[key] = value } else { dict.removeValue(forKey: key) }
        let tmp = url.deletingLastPathComponent().appendingPathComponent("secrets.json.ext-\(UUID().uuidString)")
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = rename(tmp.path, url.path)
    }

    /// Codex's interleaving: hold `secrets.lock`, start `operation`, let it
    /// block on its write, change the store meanwhile, release.
    private func whileStoreLocked(_ during: () -> Void, _ operation: @escaping @Sendable () async -> [String: Any]) async -> [String: Any] {
        let lockPath = StoragePaths.configRoot.appendingPathComponent("secrets.lock").path
        let fd = open(lockPath, O_CREAT | O_WRONLY, 0o600)
        _ = flock(fd, LOCK_EX)
        let task = Task.detached { await operation() }
        try? await Task.sleep(nanoseconds: 700_000_000)
        during()
        _ = flock(fd, LOCK_UN)
        close(fd)
        return await task.value
    }

    private func resetOpenRouter() {
        try? KeychainHelper.saveBatch([KeychainHelper.openRouterApiKeyKey: String?.none, KeychainHelper.openRouterModelKey: String?.none,
                                       OpenRouterProviderPin.storageKey: String?.none])
    }

    private func setupAPIPinChecks() async {
        let model = ProviderProfiles.openRouterSetupDefaultModel
        func hostPin(_ r: [String: Any]) -> [String: Any] { r["openrouter_host_pin"] as? [String: Any] ?? [:] }
        func provider(_ m: String, key: String? = "sk-or-fixture", extra: [String: Any] = [:]) -> [String: Any] {
            var p: [String: Any] = ["profile": "openrouter", "model": m, "activate": false]
            if let key { p["api_key"] = key }
            p.merge(extra) { _, n in n }
            return ["provider": p]
        }
        let served: [String: Any] = ["model": model, "hosts": ["novita/fp8", "together", "deepinfra/fp8"]]

        // Conditional pin section: sequential semantics.
        resetOpenRouter()
        var res = await SetupAPICore.apply(["openrouter_pin": ["set_if_unset": ["Together"]]])
        check("or-default api: set_if_unset stores the normalized slug when no pin is stored",
              res["ok"] as? Bool == true && res["openrouter_pin_written"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["together"])
        try? OpenRouterProviderPin.setPin(["deepinfra"])
        res = await SetupAPICore.apply(["openrouter_pin": ["set_if_unset": ["together"]]])
        check("or-default api: set_if_unset never overwrites a stored pin",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["deepinfra"] && res["openrouter_pin_written"] as? Bool == false)
        res = await SetupAPICore.apply(["openrouter_pin": ["release_if": ["together"]]])
        check("or-default api: release_if leaves a different pin alone", res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["deepinfra"])
        res = await SetupAPICore.apply(["openrouter_pin": ["release_if": ["deepinfra"]]])
        check("or-default api: release_if clears the pin it names", res["ok"] as? Bool == true && res["openrouter_pin_written"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs().isEmpty)
        res = await SetupAPICore.apply(["openrouter_pin": ["set_if_unset": ["two words"]]])
        check("or-default api: a malformed slug is refused, nothing stored", res["ok"] as? Bool != true && OpenRouterProviderPin.pinnedSlugs().isEmpty)
        res = await SetupAPICore.apply(["openrouter_pin": ["set_if_unset": ["together"], "release_if": ["together"]]])
        check("or-default api: both operations at once are refused", res["ok"] as? Bool != true && OpenRouterProviderPin.pinnedSlugs().isEmpty)

        // Codex round 1, P1: the interleavings (another writer stores
        // `deepinfra` while the conditional write waits for the lock).
        resetOpenRouter()
        _ = await SetupAPICore.apply(provider(model))
        res = await whileStoreLocked({ externalWrite(OpenRouterProviderPin.storageKey, "deepinfra") }) {
            await SetupAPICore.apply(["openrouter_pin": ["set_if_unset": ["together"]]])
        }
        check("or-default race: set_if_unset racing another writer's pin keeps that pin and reports not written",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["deepinfra"] && res["openrouter_pin_written"] as? Bool == false, "\(res)")
        try? OpenRouterProviderPin.setPin(["together"])
        res = await whileStoreLocked({ externalWrite(OpenRouterProviderPin.storageKey, "deepinfra") }) {
            await SetupAPICore.apply(["openrouter_pin": ["release_if": ["together"]]])
        }
        check("or-default race: release_if racing another writer's pin never deletes the newer pin",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["deepinfra"] && res["openrouter_pin_written"] as? Bool == false, "\(res)")
        // The same interleaving on a whole new-setup save.
        resetOpenRouter()
        res = await whileStoreLocked({ externalWrite(OpenRouterProviderPin.storageKey, "deepinfra") }) {
            await SetupAPICore.apply(provider(model, extra: ["default_host_pin": true, "host_listing": served]))
        }
        check("or-default race: a new-setup save racing another writer's pin keeps that pin (verified against the list)",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["deepinfra"] && hostPin(res)["result"] as? String == "kept", "\(res)")

        // New setup through setup-api (UT app, Quick Setup).
        resetOpenRouter()
        res = await SetupAPICore.apply(provider(model, extra: ["default_host_pin": true, "host_listing": served]))
        check("or-default api: a new OpenRouter setup asking for the default host is pinned to together with the profile",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["together"] && hostPin(res)["result"] as? String == "pinned_default"
              && KeychainHelper.load(key: KeychainHelper.openRouterModelKey) == model)
        resetOpenRouter()
        res = await SetupAPICore.apply(provider(model, extra: ["default_host_pin": true, "host_listing": ["model": model, "error": "OpenRouter answered HTTP 503"]]))
        check("or-default api: an unreadable host list on a new setup writes no pin and warns that OpenRouter chooses the host",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs().isEmpty && hostPin(res)["result"] as? String == "default_skipped"
              && ((res["warnings"] as? [String]) ?? []).contains { $0.contains("couldn't be selected") && $0.contains("OpenRouter chooses the host") })
        // setup-api reads the list itself when the caller gives none (fetch seam, no network).
        resetOpenRouter()
        var asked: [String] = []
        OpenRouterProviderPin.fetchOverride = { m, _ in
            asked.append(m)
            let tags = m == model ? ["novita/fp8", "together"] : ["novita/fp8"]
            return try JSONSerialization.data(withJSONObject: ["data": ["endpoints": tags.map { ["tag": $0, "provider_name": $0] }]])
        }
        defer { OpenRouterProviderPin.fetchOverride = nil }
        res = await SetupAPICore.apply(provider(model, extra: ["default_host_pin": true]))
        check("or-default api: without a host list setup-api reads it before saving and pins the new setup",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["together"] && asked == [model])
        asked = []
        res = await SetupAPICore.apply(provider(model, key: nil, extra: ["default_host_pin": true]))
        check("or-default api: re-saving the same lane (key kept, same model) reads no list and keeps the pin",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["together"] && asked.isEmpty)

        // Codex round 1, P1: a model change through setup-api re-checks the hard pin.
        asked = []
        res = await SetupAPICore.apply(provider("review-model-not-on-together", key: nil))
        check("or-default api: a model change the pinned host doesn't serve releases the pin with a notice (setup-api reads the list)",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs().isEmpty && hostPin(res)["result"] as? String == "released"
              && asked == ["review-model-not-on-together"] && ((res["warnings"] as? [String]) ?? []).contains { $0.contains("released") }
              && KeychainHelper.load(key: KeychainHelper.openRouterModelKey) == "review-model-not-on-together", "\(res)")
        try? OpenRouterProviderPin.setPin(["together"])
        res = await SetupAPICore.apply(provider("z-ai/glm-5.3-flash", key: nil, extra: ["host_listing": ["model": "z-ai/glm-5.3-flash", "hosts": ["z-ai", "together"]]]))
        check("or-default api: a model change the pinned host serves keeps the pin", res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["together"]
              && hostPin(res)["result"] as? String == "kept")
        res = await SetupAPICore.apply(provider("x/unknown", key: nil, extra: ["host_listing": ["model": "x/unknown", "error": "OpenRouter answered HTTP 503"]]))
        check("or-default api: a model change with an unreadable host list keeps the pin and warns",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["together"] && hostPin(res)["result"] as? String == "kept_unverified"
              && ((res["warnings"] as? [String]) ?? []).contains { $0.contains("not verified") })
        // A model change racing another writer's pin: the decision uses the pin under the lock.
        res = await whileStoreLocked({ externalWrite(OpenRouterProviderPin.storageKey, "novita") }) {
            await SetupAPICore.apply(provider("y/model", key: nil, extra: ["host_listing": ["model": "y/model", "hosts": ["novita/fp8"]]]))
        }
        check("or-default race: a model change racing another writer's pin decides on the newer pin (served → kept)",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["novita"] && hostPin(res)["result"] as? String == "kept", "\(res)")
        res = await SetupAPICore.apply(provider("y/model", key: nil, extra: ["host_listing": "nope"]))
        check("or-default api: a malformed host_listing is refused before anything is saved", res["ok"] as? Bool != true)
        res = await SetupAPICore.apply(["provider": ["profile": "opencode", "api_key": "oc", "model": OpenCodeGo.defaultModel, "default_host_pin": true, "activate": false]])
        check("or-default api: default_host_pin on another profile is refused", res["ok"] as? Bool != true)
        resetOpenRouter()
    }
}
