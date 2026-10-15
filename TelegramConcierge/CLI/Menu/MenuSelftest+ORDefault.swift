import Foundation

/// Owner request 2026-10-15: new users are steered to OpenRouter (not the
/// ChatGPT subscription); the setup says the default model is DeepSeek V4.1
/// Flash hosted on Together, and a NEW OpenRouter setup is pinned to
/// `together` through the same normalize → host-list check → setPin path
/// `/orprovider together` uses. Existing installs, their provider, model
/// and any stored pin are never changed; a model change the pinned host
/// doesn't serve releases the pin instead of breaking every request.
@MainActor
extension MenuSelftestContext {

    func pinSections(_ w: MenuFakeWorld) -> [[String: Any]] { w.applied.compactMap { $0["openrouter_pin"] as? [String: Any] } }

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

            // 2. Fresh OpenRouter setup → pinned to together in the same apply.
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            let last = w.applied.last ?? [:]
            check("or-default: the first OpenRouter setup pins together in the same apply as the profile",
                  ok(r) && (last["provider"] as? [String: Any])?["model"] as? String == MenuWorkflow.openRouterDefaultModel
                  && ((last["openrouter_pin"] as? [String: Any])?["set_if_unset"] as? [String]) == ["together"]
                  && w.snap.openRouterPin == ["together"] && (ai(wf)["openrouter_pin"] as? [String]) == ["together"]
                  && w.orHostAsks == [MenuWorkflow.openRouterDefaultModel])
            check("or-default: the confirmation says where it runs", msg(r).contains("on Together") && msg(r).contains("/orprovider"))

            // 3. Model change on the pinned lane: served → kept; not served → released.
            w.orHosts["z-ai/glm-5.3-flash"] = ["z-ai", "together"]
            var r2 = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "z-ai/glm-5.3-flash"])
            check("or-default: a new model the pinned host serves keeps the pin (no release sent)",
                  ok(r2) && w.snap.openRouterPin == ["together"] && w.applied.last?["openrouter_pin"] == nil)
            r2 = await act(wf, ["action": "provider_model", "profile": "openrouter", "model": "anthropic/claude-haiku-5.5"])
            check("or-default: a new model the pinned host doesn't serve releases the pin (conditional release) and says so",
                  ok(r2) && w.snap.openRouterPin.isEmpty
                  && ((w.applied.last?["openrouter_pin"] as? [String: Any])?["release_if"] as? [String]) == ["together"]
                  && msg(r2).contains("released"))
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
                  && pinSections(w).isEmpty && msg(r).contains("/orprovider off"))
        }

        // 5. Existing installs are untouched.
        do {
            // ChatGPT in use: the old fallback lane, nothing written by loading.
            let w = world()
            w.snap.chatgpt = .signedIn(active: true, model: "gpt-6.1-sol", effort: "high", generation: "g1")
            w.snap.activeProfile = "chatgpt"
            let wf = await make(w)
            check("or-default: an install on ChatGPT stays on ChatGPT, nothing written", ai(wf)["lane"] as? String == "chatgpt"
                  && ai(wf)["active"] as? String == "chatgpt" && w.applied.isEmpty && w.orHostAsks.isEmpty)
        }
        do {
            // Provider set up by briglia setup (shown as "other"), not a menu lane.
            let w = world()
            w.snap.activeProfile = "custom"
            w.snap.otherProvider = "Custom endpoint"
            let wf = await make(w)
            check("or-default: an install on a setup-made provider keeps the ChatGPT fallback lane, nothing written",
                  ai(wf)["lane"] as? String == "chatgpt" && w.applied.isEmpty)
        }
        do {
            // Signed out of ChatGPT but signed in before (login expired): not fresh.
            let w = world()
            w.snap.chatgpt = .loginRequired
            let wf = await make(w)
            check("or-default: an expired ChatGPT login is not a fresh install", ai(wf)["lane"] as? String == "chatgpt")
        }
        do {
            // OpenRouter already configured without a pin (never pinned, or
            // /orprovider off): a new key is saved, no pin is added.
            let w = world()
            w.snap.providers["openrouter"] = MenuSnapshot.Provider(configured: true, model: MenuWorkflow.openRouterDefaultModel, effort: "high", keyMasked: "sk-or…cdef")
            w.snap.activeProfile = "openrouter"
            let wf = await make(w)
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]! + "-alt"])
            check("or-default: an existing OpenRouter setup (pin off) gets no pin on a new key",
                  ok(r) && pinSections(w).isEmpty && w.snap.openRouterPin.isEmpty && w.orHostAsks.isEmpty)
        }
        do {
            // An explicit pin stored before OpenRouter is (re)added: never overwritten.
            let w = world()
            w.snap.openRouterPin = ["deepinfra"]
            let wf = await make(w)
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            check("or-default: an explicit stored pin is never overwritten by a new setup",
                  ok(r) && pinSections(w).isEmpty && w.snap.openRouterPin == ["deepinfra"])
        }

        // 6. Fresh setup but Together can't be confirmed: routing stays automatic.
        for (label, configure) in [("Together no longer serves the model", { (w: MenuFakeWorld) in w.orHosts[MenuWorkflow.openRouterDefaultModel] = ["novita/fp8"] }),
                                   ("the host list can't be read", { (w: MenuFakeWorld) in w.orHostsFail = true })] {
            let w = world()
            configure(w)
            let wf = await make(w)
            let r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
            check("or-default: no pin when \(label) (OpenRouter saved, automatic routing)",
                  ok(r) && ai(wf)["active"] as? String == "openrouter" && pinSections(w).isEmpty && w.snap.openRouterPin.isEmpty && !msg(r).contains("Together"))
        }

        // 7. The decision helper: only the setup default model, only when served.
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

        // 8. The real setup-api write (isolated XDG roots set by the battery).
        do {
            try? OpenRouterProviderPin.setPin(nil)
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
        }
    }
}
