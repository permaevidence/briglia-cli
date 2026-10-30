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

    func orEntry(_ w: MenuFakeWorld, _ model: String) -> OpenRouterPinMap.Entry? {
        OpenRouterPinMap.state(w.snap.orStore).map?.models[model]
    }

    func presetRows(_ wf: MenuWorkflow) -> [[String: Any]] { ai(wf)["openrouter_presets"] as? [[String: Any]] ?? [] }

    /// Seed a configured, active OpenRouter lane on `model`.
    func orLane(_ w: MenuFakeWorld, model: String = MenuWorkflow.openRouterDefaultModel) {
        w.snap.providers["openrouter"] = MenuSnapshot.Provider(configured: true, model: model, effort: "high", keyMasked: "sk-or…cdef")
        w.snap.activeProfile = "openrouter"
        w.syncOR()
    }

    func openRouterDefault() async {
        let haiku = "anthropic/claude-haiku-5.5", luna = "openai/gpt-6-luna", glm = "z-ai/glm-5.3-flash", ds1017 = "deepseek/deepseek-v4.1-flash-1017"
        let plain = "deepseek/deepseek-v4.1-flash"
        // 1. Fresh install: OpenRouter recommended; the picker lists the presets in order with their host state.
        do {
            let w = world()
            let wf = await make(w)
            let rows = presetRows(wf)
            check("or-picker: a fresh install recommends OpenRouter and names the default model and host",
                  ai(wf)["lane"] as? String == "openrouter" && ai(wf)["recommended_lane"] as? String == "openrouter"
                  && ai(wf)["openrouter_default"] as? String == ds1017
                  && ai(wf)["openrouter_default_label"] as? String == "DeepSeek V4.1 Flash 1017"
                  && ai(wf)["openrouter_default_host"] as? String == "Together"
                  && (ai(wf)["openrouter_pin"] as? [String]) == [])
            check("or-picker: five presets in the owner's order, each saying whether/which host is pinned automatically",
                  rows.map { $0["id"] as? String ?? "" } == [MenuWorkflow.openRouterDefaultModel, plain, haiku, luna, glm]
                  && MenuWorkflow.openRouterDefaultModel == ds1017
                  && rows.map { $0["host_state"] as? String ?? "" } == ["auto_will_pin", "auto_will_pin", "auto_will_pin", "auto_will_pin", "auto_will_pin"]
                  && rows.map { ($0["hosts"] as? [String]) ?? [] } == [["Together"], ["Together"], ["Google Vertex"], ["OpenAI"], ["Together"]], "\(rows)")

            // 2. First setup → the default preset's host, with the host list and the page's basis.
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            let sec = lastOpenRouterSection(w)
            check("or-picker: the first setup asks for the preset host, hands over the host list and the expected basis",
                  ok(r) && sec["model"] as? String == MenuWorkflow.openRouterDefaultModel && sec["preset_host_pin"] as? Bool == true
                  && (sec["expected_basis"] as? [String: Any])?["map"] as? String == "absent"
                  && (sec["host_listing"] as? [String: Any])?["model"] as? String == MenuWorkflow.openRouterDefaultModel
                  && orEntry(w, MenuWorkflow.openRouterDefaultModel) == .init(hosts: ["together"], by: .preset, at: orEntry(w, MenuWorkflow.openRouterDefaultModel)?.at ?? "")
                  && (ai(wf)["openrouter_pin"] as? [String]) == ["together"], "\(sec) \(w.snap.orStore)")
            check("or-picker: the confirmation says where it runs", msg(r).contains("on Together") && msg(r).contains("pinned automatically"))
            let orEfforts = (((ai(wf)["providers"] as? [String: Any])?["openrouter"] as? [String: Any])?["efforts"] as? [String]) ?? []
            check("or-picker D11: the menu offers max on OpenRouter", orEfforts == ["low", "medium", "high", "max"], "\(orEfforts)")

            // 3. Haiku preset: Google Vertex (base slug covers the regions); presets are sent as vision.
            w.orHosts[haiku] = ["google-vertex/global", "anthropic", "google-vertex/europe"]
            var r2 = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": haiku, "text_only": true])
            check("or-picker: picking Claude Haiku 5.5 pins google-vertex automatically (all regions) and sends it as a vision model",
                  ok(r2) && orEntry(w, haiku)?.hosts == ["google-vertex"] && orEntry(w, haiku)?.by == .preset
                  && lastOpenRouterSection(w)["text_only"] as? Bool == false && msg(r2).contains("Google Vertex"), msg(r2))

            // 4. Per-model memory: Haiku → automatic (toggle), switch to DeepSeek (Together kept), back → still automatic.
            r2 = await act(wf, ["action": "provider_host", "model": haiku, "choice": "automatic"])
            check("or-picker: the menu toggle records 'let OpenRouter choose' for Haiku",
                  ok(r2) && orEntry(w, haiku)?.hosts == [] && orEntry(w, haiku)?.by == .user
                  && (w.orPinRequests.last?["expected_basis"] as? [String: Any]) != nil, msg(r2))
            w.orHostAsks = []
            r2 = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": MenuWorkflow.openRouterDefaultModel])
            check("or-picker: back on DeepSeek V4.1 Flash its own host (Together) is restored",
                  ok(r2) && (ai(wf)["openrouter_pin"] as? [String]) == ["together"], "\(w.snap.orStore)")
            w.orHostAsks = []
            r2 = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": haiku])
            check("or-picker: A→B→A — Haiku comes back with its remembered automatic choice, no host list read, no preset override",
                  ok(r2) && orEntry(w, haiku)?.hosts == [] && (ai(wf)["openrouter_pin"] as? [String]) == [] && w.orHostAsks.isEmpty
                  && (ai(wf)["openrouter_current_host"] as? [String: Any])?["host_state"] as? String == "user_automatic")
            // 5. "Briglia's host" toggle = reset to the preset.
            r2 = await act(wf, ["action": "provider_host", "model": haiku, "choice": "default"])
            check("or-picker: the 'Briglia's host' toggle re-applies Google Vertex and shows the committed outcome",
                  ok(r2) && orEntry(w, haiku)?.hosts == ["google-vertex"] && orEntry(w, haiku)?.by == .preset && msg(r2).contains("Google Vertex"), msg(r2))
            // 6. Other model: no automatic host; the vision choice is kept.
            r2 = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "moonshotai/kimi-k3", "text_only": true])
            check("or-picker: another model gets no automatic host and keeps the page's vision choice",
                  ok(r2) && orEntry(w, "moonshotai/kimi-k3") == nil && (ai(wf)["openrouter_pin"] as? [String]) == []
                  && lastOpenRouterSection(w)["text_only"] as? Bool == true)
            // 7. Luna: OpenAI's standard endpoint, never the flex tier (listing tier-first, no metadata → suffix rule).
            w.orHosts[luna] = ["openai/flex", "openai/fast", "azure", "openai"]
            r2 = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": luna])
            check("or-picker: GPT-6 Luna pins openai (the base slug excludes openai/flex and openai/fast)",
                  ok(r2) && orEntry(w, luna)?.hosts == ["openai"] && msg(r2).contains("OpenAI"), msg(r2))
            w.orHosts[plain] = ["deepinfra/fp8", "together"]
            r2 = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": plain])
            check("or-picker: the undated DeepSeek V4.1 Flash keeps its automatic Together host",
                  ok(r2) && orEntry(w, plain)?.hosts == ["together"] && orEntry(w, plain)?.by == .preset && (ai(wf)["openrouter_pin"] as? [String]) == ["together"], msg(r2))
        }

        // 8. A preset whose host can't be confirmed: automatic, SAID (EN + IT); unreadable list too.
        for (label, configure) in [("Together no longer serves the model", { (w: MenuFakeWorld) in w.orHosts[MenuWorkflow.openRouterDefaultModel] = ["novita/fp8"] }),
                                   ("the host list can't be read", { (w: MenuFakeWorld) in w.orHostsFail = true })] {
            let w = world()
            configure(w)
            let wf = await make(w)
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            check("or-picker: no pin when \(label), the confirmation says Together couldn't be selected, retry offered",
                  ok(r) && ai(wf)["active"] as? String == "openrouter" && w.snap.openRouterPin.isEmpty
                  && orEntry(w, MenuWorkflow.openRouterDefaultModel) == nil
                  && msg(r).contains("Together couldn\u{2019}t be selected") && msg(r).contains("OpenRouter chooses the host"), msg(r))
        }
        do {
            let w = world()
            w.orHostsFail = true
            let wf = await make(w)
            await act(wf, ["action": "lang", "lang": "it"])
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            check("or-picker: the Italian confirmation says Together couldn't be chosen",
                  ok(r) && msg(r).contains("Non è stato possibile scegliere Together") && msg(r).contains("lo sceglie OpenRouter"))
        }

        // 9. Stale basis: another writer decides the destination's host while the page reads the list → refused, nothing written.
        do {
            let w = world()
            orLane(w)
            let wf = await make(w)
            w.orHosts[haiku] = ["google-vertex/global"]
            w.duringORListing = {
                var store = w.snap.orStore
                _ = try? OpenRouterProviderPin.applyHostChoice(&store, model: haiku, choice: .pin(["anthropic"]),
                                                               listing: nil, expected: OpenRouterPinMap.RoutingBasis.of(store), now: Date())
                w.snap.orStore = store
            }
            let before = w.snap.orStore
            let r = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": haiku])
            w.duringORListing = nil
            check("or-picker: a host decision written elsewhere during the page's host check makes the save stale; the newer choice stays",
                  !ok(r) && msg(r) == wf.staleMessage && orEntry(w, haiku)?.hosts == ["anthropic"]
                  && w.snap.providers["openrouter"]?.model == MenuWorkflow.openRouterDefaultModel && before != w.snap.orStore, msg(r))
        }

        // 10. Unreadable map: model save works with the warning; with an old pin pending, a model change is refused.
        do {
            let w = world()
            orLane(w)
            w.snap.orStore[OpenRouterPinMap.storageKey] = "{broken"
            let wf = await make(w)
            check("or-picker: an unreadable map shows the 'corrupt' host state", (ai(wf)["openrouter_current_host"] as? [String: Any])?["host_state"] as? String == "corrupt")
            let r = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": haiku])
            check("or-picker: a model save with unreadable hosts still works and says routing is automatic",
                  ok(r) && msg(r).contains("unreadable") && w.snap.orStore[OpenRouterPinMap.storageKey] == "{broken", msg(r))
        }
        do {
            let w = world()
            orLane(w)
            w.snap.orStore[OpenRouterPinMap.storageKey] = "{broken"
            w.snap.orStore[OpenRouterPinMap.legacyKey] = "together"
            let wf = await make(w)
            let r = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": haiku])
            check("or-picker: with an old pin that couldn't be migrated, switching model is refused with guidance (EN)",
                  !ok(r) && msg(r).contains("old host pin") && w.snap.providers["openrouter"]?.model == MenuWorkflow.openRouterDefaultModel, msg(r))
        }

        // 11. Every OpenRouter save carries host_listing (list or skip) and the expected basis.
        do {
            let w = world()
            let wf = await make(w)
            _ = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            _ = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": haiku])
            _ = await act(wf, ["action": "effort", "effort": "medium"])
            _ = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]! + "-alt"])
            let sections = w.applied.compactMap { $0["provider"] as? [String: Any] }.filter { $0["profile"] as? String == "openrouter" }
            check("or-picker: every menu OpenRouter save (key, model, effort) carries host_listing and expected_basis",
                  sections.count == 4 && sections.allSatisfy { $0["host_listing"] is [String: Any] && $0["expected_basis"] is [String: Any] },
                  "\(sections.map { ($0["host_listing"] != nil, $0["expected_basis"] != nil) })")
        }
        do {
            let w = world()
            orLane(w)
            w.snap.providers["opencode"] = MenuSnapshot.Provider(configured: true, model: OpenCodeGo.defaultModel, effort: "high", keyMasked: "oc…cdef")
            w.snap.activeProfile = "opencode"
            w.snap.openAIMasked = "sk-…ghij"
            w.syncOR()
            var store = w.snap.orStore
            _ = try? OpenRouterProviderPin.applyHostChoice(&store, model: MenuWorkflow.openRouterDefaultModel, choice: .pin(["together"]), listing: nil,
                                                           expected: OpenRouterPinMap.RoutingBasis.of(store), now: Date())
            w.snap.orStore = store
            let wf = await make(w)
            let r = await act(wf, ["action": "provider_use", "profile": "openrouter"])
            let sec = lastOpenRouterSection(w)
            check("or-picker: switching to the saved OpenRouter lane hands setup-api an explicit skip, the model's host kept",
                  ok(r) && (sec["host_listing"] as? [String: Any])?["skip"] as? Bool == true && w.snap.openRouterPin == ["together"] && w.orHostAsks.isEmpty, "\(sec)")
        }
        // 0.2.65: an existing install on the undated V4.1 Flash (0.2.54–0.2.64 default) is not moved to 1017.
        do {
            let w = world()
            orLane(w, model: plain)
            var store = w.snap.orStore
            _ = try? OpenRouterProviderPin.applyHostChoice(&store, model: plain, choice: .pin(["together"]), listing: nil,
                                                           expected: OpenRouterPinMap.RoutingBasis.of(store), now: Date())
            w.snap.orStore = store
            let before = w.snap.orStore
            let wf = await make(w)
            let opened = w.applied.isEmpty && w.orHostAsks.isEmpty && w.snap.orStore == before
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]! + "-alt"])
            let sec = lastOpenRouterSection(w)
            check("or-default 0.2.65: an existing install on the undated V4.1 Flash keeps model and Together pin (menu opened, key replaced)",
                  opened && ok(r) && sec["model"] as? String == plain && w.snap.providers["openrouter"]?.model == plain
                  && orEntry(w, plain)?.hosts == ["together"] && orEntry(w, ds1017) == nil && (ai(wf)["openrouter_pin"] as? [String]) == ["together"], "\(sec) \(w.snap.orStore)")
        }
        // Existing installs on other providers are untouched.
        do {
            let w = world()
            w.snap.chatgpt = .signedIn(active: true, model: "gpt-6.1-sol", effort: "high", generation: "g1")
            w.snap.activeProfile = "chatgpt"
            let wf = await make(w)
            check("or-picker: an install on ChatGPT stays on ChatGPT, nothing written", ai(wf)["lane"] as? String == "chatgpt"
                  && ai(wf)["active"] as? String == "chatgpt" && w.applied.isEmpty && w.orHostAsks.isEmpty)
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
                      && main?["activate"] as? Bool == true && main?["default_host_pin"] as? Bool == true && main?["preset_host_pin"] as? Bool == true)
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
            let orKeys = QuickSetupWorkflow.requiredStoredKeys(activeProfile: "openrouter") ?? []
            check("or-default quick: the final check on OpenRouter needs its key and model, not OpenCode or OpenAI",
                  orKeys.contains(KeychainHelper.openRouterApiKeyKey) && orKeys.contains(KeychainHelper.openRouterModelKey)
                  && !orKeys.contains(ProviderProfiles.opencodeApiKeyKey) && !orKeys.contains(KeychainHelper.openAITranscriptionApiKeyKey))
            let ocKeys = QuickSetupWorkflow.requiredStoredKeys(activeProfile: "opencode") ?? []
            check("or-default quick: the final check on OpenCode still needs the OpenCode and OpenAI keys",
                  ocKeys.contains(ProviderProfiles.opencodeApiKeyKey) && ocKeys.contains(KeychainHelper.openAITranscriptionApiKeyKey))
            let gptKeys = QuickSetupWorkflow.requiredStoredKeys(activeProfile: "chatgpt") ?? []
            check("or-default quick: the final check on ChatGPT keeps its model and the OpenAI key",
                  gptKeys.contains(ProviderProfiles.subscriptionModelKey) && gptKeys.contains(KeychainHelper.openAITranscriptionApiKeyKey) && !gptKeys.contains(ProviderProfiles.opencodeApiKeyKey))
            // Round 4 R1: every non-OpenRouter/OpenCode/ChatGPT provider is
            // checked against its own configuration, never against OpenCode;
            // no stored provider is refused.
            let customKeys = QuickSetupWorkflow.requiredStoredKeys(activeProfile: "custom") ?? []
            check("or-default quick: the final check on a custom endpoint needs its URL, key and model plus OpenAI, not OpenCode",
                  customKeys.contains(ProviderProfiles.customBaseURLKey) && customKeys.contains(ProviderProfiles.customApiKeyKey)
                  && customKeys.contains(ProviderProfiles.customModelKey) && customKeys.contains(KeychainHelper.openAITranscriptionApiKeyKey)
                  && !customKeys.contains(ProviderProfiles.opencodeApiKeyKey))
            let localKeys = QuickSetupWorkflow.requiredStoredKeys(activeProfile: "local") ?? []
            check("or-default quick: the final check on a local server needs its URL and model plus OpenAI, no key and no OpenCode",
                  localKeys.contains(KeychainHelper.lmStudioBaseURLKey) && localKeys.contains(KeychainHelper.lmStudioModelKey)
                  && localKeys.contains(KeychainHelper.openAITranscriptionApiKeyKey)
                  && !localKeys.contains(ProviderProfiles.opencodeApiKeyKey) && !localKeys.contains(ProviderProfiles.customApiKeyKey))
            let platformKeys = QuickSetupWorkflow.requiredStoredKeys(activeProfile: "openai") ?? []
            check("or-default quick: the final check on the OpenAI API profile needs its key and model, not OpenCode",
                  platformKeys.contains(ProviderProfiles.openaiApiKeyKey) && platformKeys.contains(ProviderProfiles.openaiModelKey)
                  && !platformKeys.contains(ProviderProfiles.opencodeApiKeyKey))
            check("or-default quick: no stored provider (or an unknown one) is refused, not treated as OpenCode",
                  QuickSetupWorkflow.requiredStoredKeys(activeProfile: nil) == nil
                  && QuickSetupWorkflow.requiredStoredKeys(activeProfile: "") == nil
                  && QuickSetupWorkflow.requiredStoredKeys(activeProfile: "bogus") == nil)
            check("or-default quick: every profile has its own explicit requirement list",
                  ProviderProfiles.Profile.allCases.allSatisfy { p in
                      let k = QuickSetupWorkflow.providerRequiredKeys(p)
                      return !k.isEmpty && (p == .opencode || !k.contains(ProviderProfiles.opencodeApiKeyKey))
                  })
            let incompleteCustom: [String: String] = [ProviderProfiles.customBaseURLKey: "http://127.0.0.1:9/v1", ProviderProfiles.customApiKeyKey: "k"]
            check("or-default quick: an incomplete custom endpoint reports its missing model",
                  QuickSetupWorkflow.missingProviderValue(.custom, stored: { incompleteCustom[$0] }) == ProviderProfiles.customModelKey)
            var completeCustom = incompleteCustom; completeCustom[ProviderProfiles.customModelKey] = "m"
            check("or-default quick: a complete custom endpoint needs nothing more",
                  QuickSetupWorkflow.missingProviderValue(.custom, stored: { completeCustom[$0] }) == nil)
            check("or-default quick: the OpenAI key is optional only with OpenRouter",
                  !QuickSetupWorkflow.openAIRequired(main: .openrouter)
                  && ProviderProfiles.Profile.allCases.filter { $0 != .openrouter }.allSatisfy { QuickSetupWorkflow.openAIRequired(main: $0) }
                  && QuickSetupWorkflow.openAIRequired(main: nil))
            var keptOR = base; keptOR["openrouter"] = ["kept": true]
            if let parsedKept = try? QuickSetupRequest.parse(keptOR) {
                check("or-default quick: a kept (already stored) OpenRouter key is not a new setup", !QuickSetupWorkflow.prefersOpenRouter(parsedKept, activeProfile: nil))
            }
        }

        // 9. The real setup-api path (isolated XDG roots set by the battery).
        await setupAPIPinChecks()
    }

    // MARK: setup-api, real store

    private func resetOpenRouter() {
        try? KeychainHelper.saveBatch([KeychainHelper.openRouterApiKeyKey: String?.none, KeychainHelper.openRouterModelKey: String?.none,
                                       OpenRouterProviderPin.storageKey: String?.none, OpenRouterPinMap.storageKey: String?.none,
                                       OpenRouterPinMap.corruptBackupKey: String?.none, ProviderProfiles.openrouterTextOnlyKey: String?.none])
    }

    private func setupAPIPinChecks() async {
        let model = ProviderProfiles.openRouterSetupDefaultModel
        let haiku = "anthropic/claude-haiku-5.5"
        func hostPin(_ r: [String: Any]) -> [String: Any] { r["openrouter_host_pin"] as? [String: Any] ?? [:] }
        func code(_ r: [String: Any]) -> String? { (r["error"] as? [String: Any])?["code"] as? String }
        func provider(_ m: String, key: String? = "sk-or-fixture", extra: [String: Any] = [:]) -> [String: Any] {
            var p: [String: Any] = ["profile": "openrouter", "model": m, "activate": false]
            if let key { p["api_key"] = key }
            p.merge(extra) { _, n in n }
            return ["provider": p]
        }
        func basis() -> [String: Any] { SetupAPICore.basisJSON(OpenRouterPinMap.RoutingBasis.of(KeychainHelper.loadSnapshot())) }
        func entry(_ m: String) -> OpenRouterPinMap.Entry? { OpenRouterPinMap.state(KeychainHelper.loadSnapshot()).map?.models[m] }
        let served: [String: Any] = ["model": model, "endpoints": [["tag": "novita/fp8", "service_tier": NSNull()], ["tag": "together", "service_tier": NSNull()]]]

        // New setup through setup-api (UT app payload: legacy default_host_pin).
        resetOpenRouter()
        var res = await SetupAPICore.apply(provider(model, extra: ["default_host_pin": true, "host_listing": served, "listing_basis": basis()]))
        check("or-picker api: the UT/Quick Setup payload (default_host_pin) pins Together on a new setup, legacy token kept",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs() == ["together"] && hostPin(res)["result"] as? String == "pinned_default"
              && entry(model)?.by == .preset && KeychainHelper.load(key: KeychainHelper.openRouterModelKey) == model, "\(res)")
        resetOpenRouter()
        res = await SetupAPICore.apply(provider(model, extra: ["preset_host_pin": true, "host_listing": ["model": model, "error": "OpenRouter answered HTTP 503"]]))
        check("or-picker api: an unreadable host list on a new setup writes no pin and warns",
              res["ok"] as? Bool == true && OpenRouterProviderPin.pinnedSlugs().isEmpty && hostPin(res)["result"] as? String == "default_skipped"
              && entry(model) == nil && ((res["warnings"] as? [String]) ?? []).contains { $0.contains("couldn't be selected") })
        res = await SetupAPICore.apply(provider(model, extra: ["preset_host_pin": true, "default_host_pin": false]))
        check("or-picker api: preset_host_pin and default_host_pin disagreeing is refused", code(res) == "invalid_value")
        res = await SetupAPICore.apply(provider(model, extra: ["preset_host_pin": "true"]))
        check("or-picker api: a non-boolean preset_host_pin is refused", code(res) == "invalid_value")

        // Per-model memory through setup-api, with the host list read by setup-api itself (seam).
        resetOpenRouter()
        var asked: [String] = []
        OpenRouterProviderPin.fetchOverride = { m, _ in
            asked.append(m)
            let tags: [[String: Any]] = m == model ? [["tag": "novita/fp8"], ["tag": "together"]]
                : m == haiku ? [["tag": "google-vertex/global", "service_tier": NSNull()], ["tag": "anthropic"]] : [["tag": "novita/fp8"]]
            return try JSONSerialization.data(withJSONObject: ["data": ["endpoints": tags.map { $0.merging(["provider_name": $0["tag"]!]) { a, _ in a } }]])
        }
        defer { OpenRouterProviderPin.fetchOverride = nil }
        res = await SetupAPICore.apply(provider(model, extra: ["preset_host_pin": true]))
        res = await SetupAPICore.apply(provider(haiku, key: nil, extra: ["preset_host_pin": true]))
        check("or-picker api: a model change to a preset with no decision pins its own host (Vertex), the first model keeps Together",
              res["ok"] as? Bool == true && entry(haiku)?.hosts == ["google-vertex"] && entry(model)?.hosts == ["together"], "\(res)")
        res = await SetupAPICore.apply(["openrouter_pin": ["model": haiku, "choice": "automatic", "expected_basis": basis()]])
        check("or-picker api: openrouter_pin automatic records the explicit choice for that model",
              res["ok"] as? Bool == true && entry(haiku)?.hosts == [] && entry(haiku)?.by == .user && res["openrouter_pin_written"] as? Bool == true)
        _ = await SetupAPICore.apply(provider(model, key: nil, extra: ["preset_host_pin": true]))
        asked = []
        res = await SetupAPICore.apply(provider(haiku, key: nil, extra: ["preset_host_pin": true]))
        check("or-picker api: A→B→A keeps Haiku automatic (no list read, no preset override)",
              res["ok"] as? Bool == true && entry(haiku)?.hosts == [] && OpenRouterProviderPin.pinnedSlugs().isEmpty && asked.isEmpty, "\(asked)")
        // Stale basis on openrouter_pin: refused, nothing written.
        let stale = basis()
        try? OpenRouterProviderPin._testSetPin(["anthropic"])
        let writes = KeychainHelper._testWriteCount
        res = await SetupAPICore.apply(["openrouter_pin": ["model": haiku, "choice": "automatic", "expected_basis": stale]])
        check("or-picker api: an openrouter_pin with an outdated basis is refused as stale; the newer pin stays; no store write",
              code(res) == "stale" && entry(haiku)?.hosts == ["anthropic"] && KeychainHelper._testWriteCount == writes, "\(res)")
        res = await SetupAPICore.apply(["openrouter_pin": ["set_if_unset": ["together"]]])
        check("or-picker api: the old set_if_unset/release_if forms are refused", res["ok"] as? Bool != true)
        res = await SetupAPICore.apply(["openrouter_pin": ["model": haiku, "choice": "pin", "hosts": ["two words"], "expected_basis": basis()]])
        check("or-picker api: a malformed slug is refused", res["ok"] as? Bool != true)
        res = await SetupAPICore.apply(["openrouter_pin": ["model": haiku, "choice": "automatic"]])
        check("or-picker api: openrouter_pin without expected_basis is refused", code(res) == "missing_field")
        // Stale provider save (menu basis) refused.
        res = await SetupAPICore.apply(provider(model, key: nil, extra: ["expected_basis": stale]))
        check("or-picker api: a provider save with an outdated expected_basis is refused as stale", code(res) == "stale")
        // Removal clears map, legacy and backup in the same write.
        try? KeychainHelper.saveBatch([OpenRouterPinMap.legacyKey: "novita", OpenRouterPinMap.corruptBackupKey: "{x"])
        _ = try? ProviderProfiles.activate(.opencode)
        res = await SetupAPICore.apply(["provider": ["profile": "openrouter", "remove": true]])
        let after = KeychainHelper.loadSnapshot()
        check("or-picker api: removing the OpenRouter profile clears the per-model hosts, the legacy pin and the backup",
              res["ok"] as? Bool == true && after[OpenRouterPinMap.storageKey] == nil && after[OpenRouterPinMap.legacyKey] == nil
              && after[OpenRouterPinMap.corruptBackupKey] == nil, "\(res)")
        // Computed activation joins the save: first setup with activate omitted.
        resetOpenRouter()
        try? KeychainHelper.saveBatch([ProviderProfiles.activeProfileKey: String?.none, KeychainHelper.llmProviderKey: String?.none])
        res = await SetupAPICore.apply(["provider": ["profile": "openrouter", "api_key": "sk-or-fixture", "model": model, "preset_host_pin": true,
                                                     "host_listing": served, "listing_basis": basis()]])
        check("or-picker api: first setup with activate omitted activates OpenRouter in the same write as the model and the pin",
              res["ok"] as? Bool == true && ProviderProfiles.activeProfile() == .openrouter
              && KeychainHelper.load(key: KeychainHelper.llmProviderKey) == LLMProvider.openRouter.rawValue && OpenRouterProviderPin.pinnedSlugs() == ["together"], "\(res)")
        res = await SetupAPICore.apply(["provider": ["profile": "opencode", "api_key": "oc", "model": OpenCodeGo.defaultModel, "preset_host_pin": true, "activate": false]])
        check("or-picker api: preset_host_pin on another profile is refused", res["ok"] as? Bool != true)
        resetOpenRouter()
    }
}
