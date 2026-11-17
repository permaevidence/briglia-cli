import Foundation

/// 0.2.71: the two OpenRouter presets for GPT-6.2 Sol and GPT-6.2 Astra
/// (owner, 2026-11-17). Probed that day on OpenRouter's chat route with the
/// OpenAI host pinned as Briglia pins it (private-docs
/// docs/research/GPT_62_PROBE_2026-11-17.md).
extension ORPinSuite {
    func gpt62Presets() {
        let sol = "openai/gpt-6.2-sol", astra = "openai/gpt-6.2-astra"
        let all = OpenRouterPresets.all
        check("W62 the two new presets: keys, ids, labels and the OpenAI host; right after GPT-6 Luna, Sol before Astra",
              OpenRouterPresets.preset(forKey: "sol62") == OpenRouterPresets.Preset(key: "sol62", id: sol, label: "GPT-6.2 Sol", autoHost: "openai", autoHostName: "OpenAI")
              && OpenRouterPresets.preset(forKey: "astra62") == OpenRouterPresets.Preset(key: "astra62", id: astra, label: "GPT-6.2 Astra", autoHost: "openai", autoHostName: "OpenAI")
              && all.map(\.key) == ["dsflash1017", "default", "haiku55", "luna", "sol62", "astra62", "glm53flash"])
        check("W62 the five older presets keep their keys, ids, labels and hosts, in the same relative order",
              all.filter { !["sol62", "astra62"].contains($0.key) } == [
                OpenRouterPresets.Preset(key: "dsflash1017", id: ds1017, label: "DeepSeek V4.1 Flash 1017", autoHost: "together", autoHostName: "Together"),
                OpenRouterPresets.Preset(key: "default", id: dflt, label: "DeepSeek V4.1 Flash", autoHost: "together", autoHostName: "Together"),
                OpenRouterPresets.Preset(key: "haiku55", id: haiku, label: "Claude Haiku 5.5", autoHost: "google-vertex", autoHostName: "Google Vertex"),
                OpenRouterPresets.Preset(key: "luna", id: luna, label: "GPT-6 Luna", autoHost: "openai", autoHostName: "OpenAI"),
                OpenRouterPresets.Preset(key: "glm53flash", id: glm, label: "GLM 5.3 Flash", autoHost: "together", autoHostName: "Together")])
        check("W62 the setup default is still the first preset (the 1017 snapshot), not a GPT model",
              ProviderProfiles.openRouterSetupDefaultModel == ds1017 && all.first?.id == ds1017)
        check("W62 preset keys and ids are unique", Set(all.map(\.key)).count == all.count && Set(all.map(\.id)).count == all.count)
        for (key, id) in [("sol62", sol), ("astra62", astra)] {
            check("W62 Telegram button bm1:r:\(key): decoded back, command is /model \(id)",
                  TelegramCommandMenu.encode(.openRouterPreset(key: key)) == "bm1:r:\(key)"
                  && TelegramCommandMenu.decode("bm1:r:\(key)") == .openRouterPreset(key: key)
                  && TelegramCommandMenu.commandText(for: .openRouterPreset(key: key)) == "/model \(id)")
        }

        // The hosts OpenRouter listed for both models on 2026-11-17, with
        // their service tiers. The preset's `openai` pin is the standard
        // endpoint only: never the Fast or Ultrafast tier (not offered by
        // Briglia; 2x and 6x the price).
        let real = [ep("openai", .null), ep("azure", .null), ep("amazon-bedrock/global", .null), ep("azure/us", .null),
                    ep("amazon-bedrock/us-east-1", .null), ep("azure/eu", .null),
                    ep("openai/fast", .value("priority")), ep("openai/ultrafast", .value("ultrafast"))]
        check("W62 today's listing: the openai pin is served by the standard endpoint only, never openai/fast or openai/ultrafast",
              Pin.validate(pin: "openai", endpoints: real) == .served([real[0]])
              && !Pin.matches(pin: "openai", endpoint: real[6]) && !Pin.matches(pin: "openai", endpoint: real[7]))
        check("W62 today's listing without tier metadata: the tier endpoints are still not covered by the base slug",
              !Pin.matches(pin: "openai", endpoint: ep("openai/fast")) && !Pin.matches(pin: "openai", endpoint: ep("openai/ultrafast")))

        for model in [sol, astra] {
            let served = Pin.HostListing(model: model, result: .success(real))
            // A first pick on an install that never chose a host for it.
            reset(orStore(model: dflt))
            let picked = modelChange(model, served)
            check("W62 \(model): a first pick pins the OpenAI host (Briglia's preset host) in the same save as the model",
                  (try? picked.get()) == .pinnedPreset(model: model, slug: "openai")
                  && snap()[KeychainHelper.openRouterModelKey] == model && entry(model)?.hosts == ["openai"] && entry(model)?.by == .preset
                  && PM.effectivePin(snap(), model: model) == ["openai"], "\(picked) \(snap())")
            check("W62 \(model): the pin is per model; the model left behind gets no entry and no pin from this pick",
                  entry(dflt) == nil && PM.effectivePin(snap(), model: dflt) == nil && map()?.models.count == 1)
            // OpenRouter does not list the OpenAI host: the model is saved, nothing is pinned.
            reset(orStore(model: dflt))
            let unserved = modelChange(model, Pin.HostListing(model: model, result: .success([ep("azure", .null), ep("openai/fast", .value("priority"))])))
            check("W62 \(model): without the standard OpenAI host in the listing nothing is pinned (not the Fast tier either); the model still switches",
                  (try? unserved.get()) != nil && (try? unserved.get()) != .pinnedPreset(model: model, slug: "openai")
                  && snap()[KeychainHelper.openRouterModelKey] == model && entry(model) == nil && PM.effectivePin(snap(), model: model) == nil,
                  "\(unserved) \(snap())")
            // A user's own host choice wins over the preset.
            reset(orStore(model: dflt))
            setEntry(model, ["azure"], by: .user)
            let kept = modelChange(model, served)
            check("W62 \(model): a host the user chose is kept; the preset never replaces it",
                  (try? kept.get()) == .kept(["azure"]) && entry(model)?.hosts == ["azure"] && entry(model)?.by == .user, "\(kept)")
            // An install already on the model (typed through "Other…" on
            // 0.2.70, the day the models came out) with no host decision:
            // the upgrade writes nothing and requests stay unpinned.
            reset(orStore(model: model))
            setEntry("x/placeholder", nil)
            let before = snap()
            PM.ensureMigrated()
            check("W62 \(model): an existing install already on it without a host decision stays unpinned after the upgrade (no write, no request pin)",
                  snap() == before && PM.effectivePin(snap(), model: model) == nil)
            reset(orStore(model: model)); PM.ensureMigrated()
            check("W62 \(model): the frozen upgrade rule gives no upgrade marker (no host pinned on upgrade)",
                  !PM.d10UpgradeModels.contains(model) && map()?.upgrade == nil && map()?.models.isEmpty == true
                  && PM.effectivePin(snap(), model: model) == nil, "\(String(describing: map()))")
            // Menu wording for the row.
            check("W62 \(model): the picker row says the host is pinned automatically when picked",
                  OpenRouterPresets.hostClause(OpenRouterPresets.hostStatus(model: model, store: orStore(model: dflt)))
                  == "Host: OpenAI, pinned automatically when picked")
        }

        // The Telegram picker with seven presets.
        let rows = ConversationManager.openRouterRows(store: orStore(model: dflt))
        let menu = TelegramCommandMenu.modelMenu(catalog: .openrouter(rows), profile: "openrouter", current: sol)
        check("W62 the OpenRouter menu: seven preset buttons in order + Other; the text stays inside Telegram's 4096 characters",
              menu.rows.count == 8 && menu.rows.prefix(7).map { $0[0].data } == all.map { "bm1:r:\($0.key)" }
              && menu.rows[7][0].data == "bm1:m:?" && menu.rows[4][0].label.contains("GPT-6.2 Sol") && menu.rows[5][0].label.contains("GPT-6.2 Astra")
              && menu.rows.allSatisfy { $0[0].data.utf8.count <= 64 } && menu.text.count < 4096
              && menu.text.contains("• GPT-6.2 Sol — openai/gpt-6.2-sol") && menu.text.contains("• GPT-6.2 Astra — openai/gpt-6.2-astra"),
              "\(menu.rows.map { $0[0].label }) \(menu.text.count)")
        reset()
    }
}
