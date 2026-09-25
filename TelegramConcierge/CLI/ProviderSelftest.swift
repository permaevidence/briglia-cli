import ArgumentParser
import Foundation

/// Hidden deterministic test of the multi-provider profile system: legacy
/// migration into profiles, activation slot copies, per-profile vision state
/// restore, /model + /effort mirrors, unconfigured-hop guards, and masked
/// key listings. Self-isolates into temp XDG roots (set BEFORE the lazy
/// StoragePaths statics are first touched) so it never disturbs a real
/// installation.
/// Mutable cell for values a test seam closure records.
final class SeamBox: @unchecked Sendable {
    var value: String = ""
}

struct ProviderSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__provider-selftest",
        abstract: "Internal: verify provider profiles, migration and /provider hop semantics.",
        shouldDisplay: false
    )

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-provider-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func load(_ key: String) -> String? { KeychainHelper.load(key: key) }
        func wipe(_ keys: [String]) { for key in keys { try? KeychainHelper.delete(key: key) } }
        let allKeys = [
            ProviderProfiles.activeProfileKey,
            ProviderProfiles.opencodeApiKeyKey, ProviderProfiles.opencodeModelKey,
            ProviderProfiles.opencodeReasoningEffortKey, ProviderProfiles.opencodeTextOnlyKey,
            ProviderProfiles.customBaseURLKey, ProviderProfiles.customApiKeyKey,
            ProviderProfiles.customModelKey, ProviderProfiles.customReasoningEffortKey,
            ProviderProfiles.customTextOnlyKey,
            ProviderProfiles.openrouterTextOnlyKey, ProviderProfiles.localTextOnlyKey,
            KeychainHelper.llmProviderKey,
            KeychainHelper.openAICompatibleBaseURLKey, KeychainHelper.openAICompatibleModelKey,
            KeychainHelper.openAICompatibleApiKeyKey, KeychainHelper.openAICompatibleReasoningEffortKey,
            KeychainHelper.openRouterApiKeyKey, KeychainHelper.openRouterModelKey,
            KeychainHelper.openRouterReasoningEffortKey,
            KeychainHelper.lmStudioBaseURLKey, KeychainHelper.lmStudioModelKey,
            KeychainHelper.textOnlyModelEnabledKey,
        ]

        // 1. Fresh install: no llm_provider stored → migration is a no-op.
        wipe(allKeys)
        ProviderProfiles.ensureMigrated()
        check("fresh install: migration is a no-op",
              ProviderProfiles.activeProfile() == nil)
        check("fresh install: nothing is configured",
              ProviderProfiles.Profile.allCases.allSatisfy { !ProviderProfiles.isConfigured($0) })

        // 2. Legacy OpenCode shape migrates to the opencode profile.
        wipe(allKeys)
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openAICompatible.rawValue)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: OpenCodeGo.baseURL)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "kimi-k3")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleApiKeyKey, value: "oc-key-1234567890")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleReasoningEffortKey, value: "high")
        try KeychainHelper.save(key: KeychainHelper.textOnlyModelEnabledKey, value: "false")
        ProviderProfiles.ensureMigrated()
        check("legacy OpenCode install migrates to opencode profile",
              ProviderProfiles.activeProfile() == .opencode
              && load(ProviderProfiles.opencodeModelKey) == "kimi-k3"
              && load(ProviderProfiles.opencodeApiKeyKey) == "oc-key-1234567890"
              && load(ProviderProfiles.opencodeReasoningEffortKey) == "high"
              && ProviderProfiles.textOnly(.opencode) == false)
        // Idempotence: a second run must not clobber later profile edits.
        try KeychainHelper.save(key: ProviderProfiles.opencodeModelKey, value: "glm-5.3")
        ProviderProfiles.ensureMigrated()
        check("migration is idempotent",
              load(ProviderProfiles.opencodeModelKey) == "glm-5.3")

        // 3. Legacy custom-endpoint shape migrates to the custom profile.
        wipe(allKeys)
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openAICompatible.rawValue)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: "https://api.example.com/v1")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "my-model")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleApiKeyKey, value: "cust-key-1234567890")
        try KeychainHelper.save(key: KeychainHelper.textOnlyModelEnabledKey, value: "true")
        ProviderProfiles.ensureMigrated()
        check("legacy custom install migrates to custom profile",
              ProviderProfiles.activeProfile() == .custom
              && load(ProviderProfiles.customBaseURLKey) == "https://api.example.com/v1"
              && load(ProviderProfiles.customModelKey) == "my-model"
              && ProviderProfiles.textOnly(.custom) == true)

        // 4. Legacy OpenRouter shape (Ada.app heritage) migrates in place.
        wipe(allKeys)
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openRouter.rawValue)
        try KeychainHelper.save(key: KeychainHelper.openRouterApiKeyKey, value: "sk-or-v1-1234567890abcdef")
        try KeychainHelper.save(key: KeychainHelper.textOnlyModelEnabledKey, value: "false")
        ProviderProfiles.ensureMigrated()
        check("legacy OpenRouter install migrates (key only, default model)",
              ProviderProfiles.activeProfile() == .openrouter
              && ProviderProfiles.isConfigured(.openrouter)
              && ProviderProfiles.configuredModel(.openrouter) == "google/gemini-3-flash-preview"
              && ProviderProfiles.textOnly(.openrouter) == false)

        // 5. Legacy local shape migrates to the local profile.
        wipe(allKeys)
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.lmStudio.rawValue)
        try KeychainHelper.save(key: KeychainHelper.lmStudioBaseURLKey, value: "http://localhost:1234/v1")
        try KeychainHelper.save(key: KeychainHelper.lmStudioModelKey, value: "qwen-local")
        ProviderProfiles.ensureMigrated()
        check("legacy local install migrates to local profile",
              ProviderProfiles.activeProfile() == .local
              && ProviderProfiles.isConfigured(.local))

        // 5b. `reasoning_history` is gone from the wire: the Fireworks/Kimi flag
        // was inert on every OpenCode backend (measured 2026-09-10 on kimi-k2.6,
        // glm-5.3-flash, qwen3.8-max, deepseek-flash: identical behaviour and
        // billing with or without it) and rejected outright by the backends
        // that serve Kimi K3 (since 2026-09-01) and GLM ("Console Go", since
        // 2026-09-10). The request type has no such field any more, so no
        // model-specific rule can bring it back.
        for model in ["kimi-k2.6", "kimi-k2.7-code", "kimi-k3", "glm-5.3-flash", "qwen3.8-max", "deepseek-v4.1-flash", "deepseek-flash", "minimax-m3"] {
            let body = OpenRouterRequest(model: model, messages: [], tools: nil, provider: nil,
                                         reasoning: nil, reasoningEffort: "high", thinking: nil)
            let encoded = String(decoding: (try? JSONEncoder().encode(body)) ?? Data(), as: UTF8.self)
            check("no reasoning_history in the encoded request for \(model)",
                  !encoded.isEmpty && !encoded.contains("reasoning_history"))
        }

        // 5c. Every curated OpenCode model except Luna emits/replays
        // reasoning_content; a catalog entry the predicate does not recognize
        // would be driven without reasoning_history and with its reasoning
        // dropped from replay (the shape that would have missed the
        // unversioned "deepseek-flash" id).
        // The curated catalog IS the OpenCode runtime, so the scoped rule is
        // asked (MiMo is recognized there only — Codex R2, 2026-09-22).
        for choice in OpenCodeGo.choices {
            let expected = !choice.id.hasPrefix("gpt-")
            check("curated OpenCode model \(choice.id) reasoning_content recognition on the OpenCode runtime is \(expected)",
                  OpenRouterService.usesReasoningContent(model: choice.id, onOpenCodeRuntime: true) == expected)
        }
        // 5d. The catalog now carries the canonical "deepseek-v4.1-flash"
        // (models.dev rename, 2026-09-10), but installs that selected DeepSeek
        // V4.1 Flash on v0.2.17 keep the legacy alias "deepseek-flash" stored
        // and OpenCode still serves it. The alias must stay recognized even
        // though it is no longer a catalog entry (5c would not catch its loss).
        check("catalog carries the canonical DeepSeek V4.1 Flash id",
              OpenCodeGo.choices.contains(where: { $0.id == "deepseek-v4.1-flash" && !$0.textOnly })
              && !OpenCodeGo.choices.contains(where: { $0.id == "deepseek-flash" }))
        for legacy in ["deepseek-flash", "DeepSeek-Flash"] {
            check("legacy OpenCode alias \(legacy) still recognized as a reasoning_content model",
                  OpenRouterService.isOpenCodeReasoningContentModel(legacy))
            check("legacy OpenCode alias \(legacy) resolves to the canonical catalog entry (vision)",
                  OpenCodeGo.catalogEntry(for: legacy)?.id == "deepseek-v4.1-flash"
                  && OpenCodeGo.catalogEntry(for: legacy)?.textOnly == false)
        }
        check("catalogEntry(for:) is exact for non-aliased ids",
              OpenCodeGo.catalogEntry(for: "deepseek-v4.1-flash")?.id == "deepseek-v4.1-flash"
              && OpenCodeGo.catalogEntry(for: "not-a-model") == nil)
        // 5d'. Curated picker trim + company grouping (owner, 2026-09-19).
        // The retired ids are out of every picker but stay typeable into
        // /model with their verified capability facts (Codex R2: the
        // capability lookup keeps them), and the reasoning predicates must
        // keep recognizing them.
        for retired in ["glm-5.3", "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            check("retired OpenCode id \(retired) is out of the picker but still known to the capability lookup",
                  !OpenCodeGo.choices.contains(where: { $0.id == retired })
                  && OpenCodeGo.catalogEntry(for: retired)?.id == retired
                  && OpenCodeGo.retired.contains(where: { $0.id == retired }))
            check("retired OpenCode id \(retired) still drives reasoning_content when typed",
                  OpenRouterService.isOpenCodeReasoningContentModel(retired))
        }
        let curatedIds = OpenCodeGo.choices.map(\.id)
        check("curated catalog keeps the default first",
              curatedIds.first == OpenCodeGo.defaultModel)
        check("curated catalog has no duplicate ids",
              Set(curatedIds).count == curatedIds.count)
        let kimiPositions = curatedIds.indices.filter { curatedIds[$0].hasPrefix("kimi-") }
        check("curated catalog groups Kimi together, newest first",
              curatedIds.filter { $0.hasPrefix("kimi-") } == ["kimi-k3", "kimi-k2.7-code", "kimi-k2.6"]
              && kimiPositions.count == 3 && kimiPositions[2] - kimiPositions[0] == 2)
        check("DeepSeek V4.1 Flash is the only curated DeepSeek entry",
              curatedIds.filter { $0.hasPrefix("deepseek") } == ["deepseek-v4.1-flash"])
        check("no curated entry is text-only any more (Luna sees images over the Responses API, v0.2.31)",
              OpenCodeGo.choices.filter(\.textOnly).isEmpty && OpenCodeGo.catalogEntry(for: "gpt-5.6-luna")?.textOnly == false)

        // 5e′. /orprovider (0.2.30): slug rules, live-pinListing parse, matching,
        // storage in the pre-existing openrouter_providers key, fetch seam.
        typealias Pin = OpenRouterProviderPin
        let pinListing = """
        {"data":{"id":"z-ai/glm-5.3-flash","endpoints":[
          {"provider_name":"DeepInfra","tag":"deepinfra/fp4","context_length":1048576,"pricing":{"prompt":"0.000000075","completion":"0.00000025","input_cache_read":"0.000000015"},"status":0,"uptime_last_30m":98.9},
          {"provider_name":"Novita","tag":"novita/fp8","context_length":1048576,"pricing":{"prompt":"0.000000132","completion":"0.00000044","input_cache_read":"0.0000000264"},"status":0,"uptime_last_30m":99.7},
          {"provider_name":"DeepInfra","tag":"DeepInfra/Turbo","context_length":1048576,"pricing":{"prompt":"0.0000002","completion":"0.0000006"},"status":-2,"uptime_last_30m":92.1},
          {"provider_name":"Z.AI","tag":"z-ai/fp8","context_length":1048576,"pricing":{"prompt":"0.00000015","completion":"0.0000005","input_cache_read":"0.00000003"},"status":0,"uptime_last_30m":99.8},
          {"provider_name":"Novita","tag":"novita/fp8","pricing":{}}
        ]}}
        """
        let pinEndpoints = try Pin.parseEndpoints(Data(pinListing.utf8))
        check("orprovider parse: 4 endpoints (duplicate tag dropped), tags lowercased, $/M scaled, missing fields nil",
              pinEndpoints.map(\.tag) == ["deepinfra/fp4", "novita/fp8", "deepinfra/turbo", "z-ai/fp8"]
              && pinEndpoints[1].promptUSDPerM.map { abs($0 - 0.132) < 1e-9 } == true
              && pinEndpoints[2].cacheReadUSDPerM == nil && pinEndpoints[2].status == -2)
        check("orprovider parse: bad shape throws", (try? Pin.parseEndpoints(Data("{\"data\":{}}".utf8))) == nil)
        check("orprovider slugs: base slug, normalization, refusals",
              Pin.baseSlug("DeepInfra/Turbo") == "deepinfra" && Pin.baseSlug("z-ai") == "z-ai"
              && Pin.normalizedSlug(" Z-AI ") == "z-ai" && Pin.normalizedSlug("deepinfra/turbo") == "deepinfra/turbo"
              && Pin.normalizedSlug("deep infra") == nil && Pin.normalizedSlug("/novita") == nil
              && Pin.normalizedSlug("a//b") == nil && Pin.normalizedSlug("") == nil && Pin.normalizedSlug("x\"y") == nil)
        check("orprovider matching: base slug covers variants, full tag targets one, unknown lists hosts",
              Pin.validate(pin: "deepinfra", endpoints: pinEndpoints) == .served([pinEndpoints[0], pinEndpoints[2]])
              && Pin.validate(pin: "deepinfra/turbo", endpoints: pinEndpoints) == .served([pinEndpoints[2]])
              && Pin.validate(pin: "deepseek", endpoints: pinEndpoints) == .notServed(available: ["deepinfra", "novita", "z-ai"]))
        check("orprovider base choices: one row per provider in listing order",
              Pin.baseChoices(pinEndpoints).map(\.baseSlug) == ["deepinfra", "novita", "z-ai"])
        check("orprovider describe: figures per M, trailing zeros trimmed, degraded flag, pin marker",
              Pin.describe(pinEndpoints[1]) == "Novita (novita) · $0.132/$0.44 per M · cache $0.0264 · up 99.7%"
              && Pin.describe(pinEndpoints[2], pinned: true) == "📌 DeepInfra (deepinfra) · $0.2/$0.6 per M · up 92.1% · degraded",
              Pin.describe(pinEndpoints[1]))
        try Pin.setPin(["Novita", "deepinfra/turbo"])
        check("orprovider storage: normalized comma list in openrouter_providers, statusLine, isPinned",
              load(KeychainHelper.openRouterProvidersKey) == "novita,deepinfra/turbo"
              && Pin.pinnedSlugs() == ["novita", "deepinfra/turbo"] && Pin.isPinned
              && Pin.statusLine()?.contains("novita, deepinfra/turbo") == true)
        try Pin.setPin(nil)
        check("orprovider storage: cleared → automatic",
              load(KeychainHelper.openRouterProvidersKey) == nil && !Pin.isPinned && Pin.statusLine() == nil)
        try Pin.setPin(["bad slug", "z-ai"])
        check("orprovider storage: invalid items are dropped, valid ones kept",
              Pin.pinnedSlugs() == ["z-ai"])
        try Pin.setPin(nil)
        let seenArgs = SeamBox()
        Pin.fetchOverride = { model, key in
            seenArgs.value = "\(model)|\(key)"
            return Data(pinListing.utf8)
        }
        let fetched = try await Pin.fetchEndpoints(model: "z-ai/glm-5.3-flash", apiKey: "or-key")
        Pin.fetchOverride = nil
        check("orprovider fetch seam: model + key forwarded, parsed through the same decoder",
              seenArgs.value == "z-ai/glm-5.3-flash|or-key" && fetched == pinEndpoints)
        // 5e. The doctor's legacy-alias nudge is OpenCode-only (Codex S1): a
        // custom or local server may serve its own "deepseek-flash".
        let opencodeURL = OpenCodeGo.baseURL
        check("doctor alias advisory fires on the OpenCode profile",
              Doctor.legacyOpenCodeAliasAdvisory(model: "deepseek-flash", baseURL: opencodeURL, activeProfile: .opencode)?.contains("deepseek-v4.1-flash") == true)
        check("doctor alias advisory fires for a custom profile pointed at OpenCode",
              Doctor.legacyOpenCodeAliasAdvisory(model: "deepseek-flash", baseURL: opencodeURL, activeProfile: .custom) != nil)
        check("doctor alias advisory is silent for a custom endpoint serving its own deepseek-flash",
              Doctor.legacyOpenCodeAliasAdvisory(model: "deepseek-flash", baseURL: "https://llm.example.net/v1", activeProfile: .custom) == nil)
        check("doctor alias advisory is silent for a local server",
              Doctor.legacyOpenCodeAliasAdvisory(model: "deepseek-flash", baseURL: "http://127.0.0.1:1234/v1", activeProfile: .local) == nil)
        check("doctor alias advisory is silent without a profile and a non-OpenCode URL",
              Doctor.legacyOpenCodeAliasAdvisory(model: "deepseek-flash", baseURL: "", activeProfile: nil) == nil)
        check("doctor alias advisory is silent for the canonical id on OpenCode",
              Doctor.legacyOpenCodeAliasAdvisory(model: "deepseek-v4.1-flash", baseURL: opencodeURL, activeProfile: .opencode) == nil)

        // 6. Multi-profile world: save all four, hop between them, verify the
        //    runtime slots and vision state follow each hop.
        wipe(allKeys)
        try ProviderProfiles.saveProfile(.opencode, apiKey: "oc-key-1234567890", baseURL: nil,
                                         model: "kimi-k3", effort: "high", textOnly: false)
        try ProviderProfiles.saveProfile(.openrouter, apiKey: "sk-or-v1-1234567890abcdef", baseURL: nil,
                                         model: "moonshotai/kimi-k3", effort: "high", textOnly: false)
        try ProviderProfiles.saveProfile(.custom, apiKey: "cust-key-1234567890", baseURL: "https://api.example.com/v1",
                                         model: "my-model", effort: nil, textOnly: true)
        try ProviderProfiles.saveProfile(.local, apiKey: nil, baseURL: "http://localhost:1234/v1",
                                         model: "qwen-local", effort: nil, textOnly: true)
        check("all four legacy profiles configured simultaneously",
              [ProviderProfiles.Profile.opencode, .openrouter, .custom, .local].allSatisfy { ProviderProfiles.isConfigured($0) })

        try ProviderProfiles.activate(.opencode)
        check("activate(opencode) fills runtime slots + pins the Go base URL",
              load(KeychainHelper.llmProviderKey) == LLMProvider.openAICompatible.rawValue
              && load(KeychainHelper.openAICompatibleBaseURLKey) == OpenCodeGo.baseURL
              && load(KeychainHelper.openAICompatibleModelKey) == "kimi-k3"
              && load(KeychainHelper.openAICompatibleApiKeyKey) == "oc-key-1234567890"
              && load(KeychainHelper.textOnlyModelEnabledKey) == "false")

        try ProviderProfiles.activate(.custom)
        check("activate(custom) swaps the shared slots to the custom endpoint",
              load(KeychainHelper.openAICompatibleBaseURLKey) == "https://api.example.com/v1"
              && load(KeychainHelper.openAICompatibleModelKey) == "my-model"
              && load(KeychainHelper.openAICompatibleApiKeyKey) == "cust-key-1234567890"
              && load(KeychainHelper.textOnlyModelEnabledKey) == "true")

        try ProviderProfiles.activate(.openrouter)
        check("activate(openrouter) selects the native provider",
              load(KeychainHelper.llmProviderKey) == LLMProvider.openRouter.rawValue
              && load(KeychainHelper.textOnlyModelEnabledKey) == "false")

        try ProviderProfiles.activate(.local)
        check("activate(local) selects the local provider + restores text-only",
              load(KeychainHelper.llmProviderKey) == LLMProvider.lmStudio.rawValue
              && load(KeychainHelper.textOnlyModelEnabledKey) == "true")

        // Hop back: OpenCode's config must be exactly what it was before the
        // custom profile overwrote the shared runtime slots.
        try ProviderProfiles.activate(.opencode)
        check("hop away and back restores the OpenCode runtime slots",
              load(KeychainHelper.openAICompatibleBaseURLKey) == OpenCodeGo.baseURL
              && load(KeychainHelper.openAICompatibleModelKey) == "kimi-k3"
              && load(KeychainHelper.textOnlyModelEnabledKey) == "false")

        // 7. /model mirror: a model switch on the active profile survives a
        //    round-trip through another profile.
        ProviderProfiles.recordModelChange("glm-5.3", textOnly: true)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "glm-5.3")
        try ProviderProfiles.activate(.custom)
        try ProviderProfiles.activate(.opencode)
        check("/model mirror survives a provider round-trip",
              load(KeychainHelper.openAICompatibleModelKey) == "glm-5.3"
              && load(KeychainHelper.textOnlyModelEnabledKey) == "true")

        // 8. /effort mirror.
        ProviderProfiles.recordEffortChange("low")
        check("/effort mirror lands in the active profile",
              load(ProviderProfiles.opencodeReasoningEffortKey) == "low")
        ProviderProfiles.recordEffortChange(nil)
        check("/effort off clears the active profile's effort",
              load(ProviderProfiles.opencodeReasoningEffortKey) == nil)

        // 9. Unconfigured hop fails loudly (never a silent half-switch).
        wipe([ProviderProfiles.customBaseURLKey, ProviderProfiles.customApiKeyKey,
              ProviderProfiles.customModelKey])
        do {
            try ProviderProfiles.activate(.custom)
            check("activating an unconfigured profile throws", false)
        } catch {
            check("activating an unconfigured profile throws",
                  ProviderProfiles.describeActivationError(error).contains("not configured"))
        }
        check("failed activation leaves the active profile untouched",
              ProviderProfiles.activeProfile() == .opencode
              && load(KeychainHelper.llmProviderKey) == LLMProvider.openAICompatible.rawValue)

        // 10. saveBatch: one call writes values AND records deletions.
        try KeychainHelper.save(key: "batch_probe_keep", value: "old")
        try KeychainHelper.save(key: "batch_probe_drop", value: "old")
        let dropped: String? = nil
        try KeychainHelper.saveBatch([
            "batch_probe_keep": "new",
            "batch_probe_drop": dropped,
        ])
        check("saveBatch writes and deletes in one atomic commit",
              load("batch_probe_keep") == "new" && load("batch_probe_drop") == nil)

        // 11. Reasoning provenance is model + GATEWAY: the same model id on
        //     two different gateways must not compare equal (a /provider hop
        //     downgrades prior reasoning to transcript instead of replaying
        //     provider-specific fields cross-gateway).
        try ProviderProfiles.activate(.opencode)
        let provenanceOpenCode = OpenRouterService.reasoningProvenance(
            model: "kimi-k3", provider: .openAICompatible)
        try KeychainHelper.save(key: ProviderProfiles.customBaseURLKey, value: "https://api.example.com/v1")
        try KeychainHelper.save(key: ProviderProfiles.customApiKeyKey, value: "cust-key-1234567890")
        try KeychainHelper.save(key: ProviderProfiles.customModelKey, value: "kimi-k3")
        try ProviderProfiles.activate(.custom)
        let provenanceCustom = OpenRouterService.reasoningProvenance(
            model: "kimi-k3", provider: .openAICompatible)
        let provenanceOpenRouter = OpenRouterService.reasoningProvenance(
            model: "kimi-k3", provider: .openRouter)
        check("provenance embeds the model and differs per gateway",
              provenanceOpenCode.hasPrefix("kimi-k3#")
              && provenanceOpenCode != provenanceCustom
              && provenanceOpenRouter == "kimi-k3#openrouter"
              && provenanceCustom != provenanceOpenRouter)
        check("legacy bare-model provenance mismatches the qualified form",
              provenanceOpenCode != "kimi-k3")
        try ProviderProfiles.activate(.opencode)
        let provenanceOpenCodeAgain = OpenRouterService.reasoningProvenance(
            model: "kimi-k3", provider: .openAICompatible)
        check("provenance is stable for the same profile across hops",
              provenanceOpenCodeAgain == provenanceOpenCode)

        // 12. Listings mask keys and never leak the full value. (Re-wipe
        // custom, which section 11 reconfigured, so the unconfigured-profile
        // line is exercised.)
        wipe([ProviderProfiles.customBaseURLKey, ProviderProfiles.customApiKeyKey,
              ProviderProfiles.customModelKey, ProviderProfiles.customReasoningEffortKey,
              ProviderProfiles.customTextOnlyKey])
        let listing = ProviderProfiles.statusLines().joined(separator: "\n")
        check("status lines mask API keys",
              !listing.contains("oc-key-1234567890")
              && !listing.contains("sk-or-v1-1234567890abcdef")
              && listing.contains("…"))
        check("status lines mark the active profile",
              listing.contains("• opencode — ACTIVE"))
        check("status lines flag unconfigured profiles; servers replace the custom/local profile lines",
              listing.contains("• openai — not configured") && !listing.contains("• custom") && !listing.contains("• local"))

        // 13. Web backend credential lookup must survive main-provider hops:
        // the opencode web backend's key comes from the saved OpenCode
        // PROFILE, not just the runtime slots (which a hop to custom
        // repopulates with the custom endpoint's key).
        wipe(allKeys + [KeychainHelper.webSearchOpenCodeApiKeyKey])
        try KeychainHelper.save(key: ProviderProfiles.opencodeApiKeyKey, value: "oc-profile-key-123456")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: "https://my-custom-endpoint.example/v1")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleApiKeyKey, value: "custom-key-123456")
        check("web opencode key falls back to the saved OpenCode profile",
              WebSearchBackend.storedKey(for: .opencode) == "oc-profile-key-123456")
        try KeychainHelper.save(key: KeychainHelper.webSearchOpenCodeApiKeyKey, value: "dedicated-key-123456")
        check("web opencode dedicated slot outranks the profile key",
              WebSearchBackend.storedKey(for: .opencode) == "dedicated-key-123456")
        wipe([KeychainHelper.webSearchOpenCodeApiKeyKey, ProviderProfiles.opencodeApiKeyKey])
        check("web opencode without profile ignores a non-opencode runtime key",
              WebSearchBackend.storedKey(for: .opencode).isEmpty)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: OpenCodeGo.baseURL)
        check("web opencode legacy runtime fallback still works when main IS opencode",
              WebSearchBackend.storedKey(for: .opencode) == "custom-key-123456")
        wipe(allKeys + [KeychainHelper.webSearchOpenCodeApiKeyKey])

        // 14. Downgraded reasoning rides a SYSTEM note, never assistant
        // content (models imitate wrapper text arriving in their own voice —
        // live incident 2026-08-16 after the provenance upgrade).
        let reasoned = OpenRouterAPIMessage(
            role: "assistant",
            content: .text("visible answer"),
            toolCalls: nil,
            toolCallId: nil,
            reasoning: .string("secret chain of thought"),
            producedByModel: "kimi-k3#other-gateway"
        )
        let (downgraded, note) = reasoned.sanitizedForProvider(
            .openAICompatible, useReasoningContent: true, reasoningFromCurrentModel: false)
        var contentUntouched = false
        if case .text(let text) = downgraded.content { contentUntouched = text == "visible answer" }
        check("downgrade: assistant content untouched (no spliced wrapper)",
              contentUntouched)
        check("downgrade: native reasoning fields stripped",
              downgraded.reasoning == nil && downgraded.reasoningContent == nil
              && downgraded.reasoningDetails == nil)
        check("downgrade: note carries reasoning in harness voice w/ no-imitate rule",
              note?.contains("[reasoning record") == true
              && note?.contains("secret chain of thought") == true
              && note?.contains("never reproduce this note's bracketed format") == true)
        let (native, noNote) = reasoned.sanitizedForProvider(
            .openAICompatible, useReasoningContent: true, reasoningFromCurrentModel: true)
        check("same-provenance: native replay, no note",
              native.reasoningContent != nil && noNote == nil)
        let (orDowngraded, orNote) = reasoned.sanitizedForProvider(
            .openRouter, useReasoningContent: false, reasoningFromCurrentModel: false)
        check("downgrade on openrouter: same note contract",
              orDowngraded.reasoning == nil && orNote?.contains("secret chain of thought") == true)

        // 15. Full request assembly: provider-A history under provider B —
        // the note lands BEFORE its assistant message and tool messages stay
        // directly adjacent to their tool_calls assistant message (real
        // ToolCall fixture, asserted on the ENCODED wire shape); the
        // same-provenance assistant replays natively with no note.
        let reasonedToolCall = OpenRouterAPIMessage(
            role: "assistant",
            content: .text("calling a tool"),
            toolCalls: [ToolCall(id: "call1", type: "function",
                                 function: FunctionCall(name: "do_thing", arguments: "{}"))],
            toolCallId: nil,
            reasoning: .string("secret chain of thought"),
            producedByModel: "kimi-k3#other-gateway"
        )
        let history: [OpenRouterAPIMessage] = [
            OpenRouterAPIMessage(role: "user", content: .text("q1"), toolCalls: nil, toolCallId: nil),
            reasonedToolCall,  // producedByModel ≠ effective → downgrade
            OpenRouterAPIMessage(role: "tool", content: .text("tool result"), toolCalls: nil, toolCallId: "call1"),
            OpenRouterAPIMessage(role: "assistant", content: .text("current answer"),
                                 toolCalls: nil, toolCallId: nil,
                                 reasoning: .string("fresh reasoning"),
                                 producedByModel: "kimi-k3#current-gateway"),
        ]
        let assembled = OpenRouterService.assembleRequestMessages(
            history, provider: .openAICompatible, useReasoningContent: true,
            effectiveProvenance: "kimi-k3#current-gateway")
        let roles = assembled.map(\.role)
        check("assembly: note precedes its message, tool stays adjacent",
              roles == ["user", "system", "assistant", "tool", "assistant"])
        var noteBeforeAssistant = false
        if case .text(let noteText)? = assembled[1].content {
            noteBeforeAssistant = noteText.contains("secret chain of thought")
        }
        check("assembly: system note carries the downgraded reasoning",
              noteBeforeAssistant)
        check("assembly: same-provenance tail message replays natively, no extra note",
              assembled[4].reasoningContent != nil)
        // Encoded wire shape: the downgraded assistant message must still
        // carry its tool_calls (id intact) and be immediately followed by
        // the tool message answering that id — the sequence a gateway
        // validates. Also proves producedByModel never reaches the wire.
        let wireData = try JSONEncoder().encode(assembled)
        let wire = try JSONSerialization.jsonObject(with: wireData) as? [[String: Any]] ?? []
        let wireAssistant = wire[2]
        let wireToolCalls = wireAssistant["tool_calls"] as? [[String: Any]] ?? []
        let wireTool = wire[3]
        check("assembly wire: tool_calls survive downgrade, tool answers adjacent id",
              wireToolCalls.count == 1
              && wireToolCalls.first?["id"] as? String == "call1"
              && wireTool["role"] as? String == "tool"
              && wireTool["tool_call_id"] as? String == "call1"
              && wire.allSatisfy { $0["producedByModel"] == nil && $0["produced_by_model"] == nil })

        // 16. Legacy provenance requalification is narrow: only a bare
        // record matching the CURRENTLY configured model earns the current
        // gateway; anything else stays unattributed (downgrade path).
        wipe(allKeys)
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openAICompatible.rawValue)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: OpenCodeGo.baseURL)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "kimi-k3")
        let requalified = OpenRouterService.requalifiedLegacyProvenance(bareModelId: "kimi-k3")
        let expected = OpenRouterService.reasoningProvenance(model: "kimi-k3", provider: .openAICompatible)
        check("legacy migration: current-model record gets the current gateway",
              requalified == expected && requalified?.contains("#") == true)
        // The one-shot gate: the first requalification in this process must
        // have persisted the done-flag, closing the gate for later launches
        // (the per-launch static caches true in THIS process — the
        // cross-launch refusal is exactly what the persisted flag encodes).
        check("legacy migration: one-shot flag persisted on first use",
              load(KeychainHelper.legacyReasoningMigrationDoneKey) == "1")
        check("legacy migration: other-model record stays unattributed",
              OpenRouterService.requalifiedLegacyProvenance(bareModelId: "glm-5.3") == nil)
        wipe([KeychainHelper.openAICompatibleModelKey])
        check("legacy migration: no configured model → no guess",
              OpenRouterService.requalifiedLegacyProvenance(bareModelId: "kimi-k3") == nil)
        wipe(allKeys)

        // 16. Setup key-probe failure classes: a single model's 503 outage
        // must steer the probe to a fallback model instead of refusing the
        // key (live incident 2026-08-17: kimi-k2.6 upstream down bricked the
        // OpenCode key step on a fresh phone install).
        check("probe classify: 401 is an auth failure (terminal)",
              Probes.classifyFailure("endpoint returned HTTP 401 — bad key") == .auth)
        check("probe classify: 403 is an auth failure (terminal)",
              Probes.classifyFailure("endpoint returned HTTP 403") == .auth)
        check("probe classify: 503 is server-side (try the next model)",
              Probes.classifyFailure("endpoint returned HTTP 503 — Upstream request failed") == .serverSide)
        check("probe classify: 500 is server-side (try the next model)",
              Probes.classifyFailure("endpoint returned HTTP 500") == .serverSide)
        check("probe classify: 400 is a plain refusal (no fallback)",
              Probes.classifyFailure("endpoint returned HTTP 400 — unknown model") == .other)
        check("probe classify: transport errors are a plain refusal",
              Probes.classifyFailure("endpoint unreachable: timed out") == .other)
        check("probe classify: HTTP codes in the body don't confuse the class",
              Probes.classifyFailure("endpoint returned HTTP 404 — try HTTP 503 later") == .other)
        check("probe fallbacks: configured, distinct from the default, not China-gated",
              !OpenCodeGo.probeFallbacks.isEmpty
              && !OpenCodeGo.probeFallbacks.contains(OpenCodeGo.defaultModel)
              && !OpenCodeGo.probeFallbacks.contains("deepseek-v4-flash")
              && OpenCodeGo.probeFallbacks.allSatisfy { id in OpenCodeGo.choices.contains { $0.id == id } })

        // 17. DeepSeek requires `reasoning_content` on EVERY current-turn
        // assistant message (OpenCode "Console Go", verified 2026-09-12:
        // missing → HTTP 400, null → 400, "" → 200). The harness-authored
        // active-turn compaction note has nothing to replay and killed real
        // turns. DeepSeek targets get "" where nothing is stored; every
        // other model/provider and every non-assistant role are byte-identical.
        for id in ["deepseek-v4.1-flash", "deepseek-flash", "deepseek-v4-pro", "DeepSeek-V4-Flash-Vision-Exp"] {
            check("deepseek predicate: \(id) requires reasoning_content",
                  OpenRouterService.isOpenCodeDeepSeekReasoningModel(id))
        }
        for id in ["kimi-k3", "kimi-k2.6", "glm-5.3-flash", "qwen3.8-max", "minimax-m3", "gpt-5.6-luna"] {
            check("deepseek predicate: \(id) does not",
                  !OpenRouterService.isOpenCodeDeepSeekReasoningModel(id))
        }
        func rc(_ value: JSONValue?) -> String? {
            switch value {
            case nil: return nil
            case .string(let text)?: return text
            case .null?: return "<null>"
            default: return "<other>"
            }
        }
        let bareNote = OpenRouterAPIMessage(role: "assistant", content: .text("[compaction summary]"),
                                            toolCalls: nil, toolCallId: nil)
        let (dsNote, dsNoteNote) = bareNote.sanitizedForProvider(
            .openAICompatible, useReasoningContent: true, reasoningFromCurrentModel: true,
            requiresReasoningContent: true)
        check("deepseek: bare assistant message gets reasoning_content \"\"",
              rc(dsNote.reasoningContent) == "" && dsNoteNote == nil)
        let (otherNote, _) = bareNote.sanitizedForProvider(
            .openAICompatible, useReasoningContent: true, reasoningFromCurrentModel: true)
        check("non-deepseek: bare assistant message stays without the field",
              rc(otherNote.reasoningContent) == nil)
        let storedReasoning = OpenRouterAPIMessage(role: "assistant", content: .text("x"), toolCalls: nil,
                                                   toolCallId: nil, reasoning: .string("thought"))
        check("deepseek: stored reasoning replays unchanged",
              rc(storedReasoning.sanitizedForProvider(.openAICompatible, useReasoningContent: true,
                  requiresReasoningContent: true).message.reasoningContent) == "thought")
        let storedEmpty = OpenRouterAPIMessage(role: "assistant", content: .text("x"), toolCalls: nil,
                                               toolCallId: nil, reasoning: .string(""))
        check("deepseek: stored empty reasoning replays as \"\" (was already so)",
              rc(storedEmpty.sanitizedForProvider(.openAICompatible, useReasoningContent: true,
                  requiresReasoningContent: true).message.reasoningContent) == "")
        let storedNull = OpenRouterAPIMessage(role: "assistant", content: .text("x"), toolCalls: nil,
                                              toolCallId: nil, reasoning: .null)
        check("deepseek: stored JSON null becomes \"\" (null is rejected too)",
              rc(storedNull.sanitizedForProvider(.openAICompatible, useReasoningContent: true,
                  requiresReasoningContent: true).message.reasoningContent) == "")
        check("non-deepseek: stored JSON null still replays as null (unchanged shape)",
              rc(storedNull.sanitizedForProvider(.openAICompatible, useReasoningContent: true)
                  .message.reasoningContent) == "<null>")
        for role in ["user", "tool", "system"] {
            let other = OpenRouterAPIMessage(role: role, content: .text("t"), toolCalls: nil,
                                             toolCallId: role == "tool" ? "c" : nil)
            check("deepseek: \(role) message never gets the field",
                  rc(other.sanitizedForProvider(.openAICompatible, useReasoningContent: true,
                      requiresReasoningContent: true).message.reasoningContent) == nil)
        }
        let (dsDowngraded, dsDowngradeNote) = reasoned.sanitizedForProvider(
            .openAICompatible, useReasoningContent: true, reasoningFromCurrentModel: false,
            requiresReasoningContent: true)
        check("deepseek: foreign-provenance downgrade keeps the note and carries \"\"",
              rc(dsDowngraded.reasoningContent) == "" && dsDowngraded.reasoning == nil
              && dsDowngradeNote?.contains("secret chain of thought") == true)
        check("openrouter/lmstudio: flag is inert",
              rc(bareNote.sanitizedForProvider(.openRouter, useReasoningContent: false,
                  requiresReasoningContent: true).message.reasoningContent) == nil
              && rc(bareNote.sanitizedForProvider(.lmStudio, useReasoningContent: true,
                  requiresReasoningContent: true).message.reasoningContent) == nil)
        // The field shape that failed live: user task → compaction note →
        // retained tool round → tool result. Asserted on the ENCODED wire.
        let compactionShape: [OpenRouterAPIMessage] = [
            OpenRouterAPIMessage(role: "system", content: .text("prompt"), toolCalls: nil, toolCallId: nil),
            OpenRouterAPIMessage(role: "user", content: .text("task"), toolCalls: nil, toolCallId: nil),
            bareNote,
            OpenRouterAPIMessage(role: "assistant", content: nil,
                                 toolCalls: [ToolCall(id: "c1", type: "function",
                                                      function: FunctionCall(name: "read_file", arguments: "{}"))],
                                 toolCallId: nil, reasoning: .string("call it"),
                                 producedByModel: "deepseek-v4.1-flash#opencode"),
            OpenRouterAPIMessage(role: "tool", content: .text("result"), toolCalls: nil, toolCallId: "c1"),
        ]
        func wireKeys(_ messages: [OpenRouterAPIMessage]) throws -> [String?] {
            let data = try JSONEncoder().encode(messages)
            let wire = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            return wire.map { $0["reasoning_content"] as? String }
        }
        let dsWire = try wireKeys(OpenRouterService.assembleRequestMessages(
            compactionShape, provider: .openAICompatible, useReasoningContent: true,
            effectiveProvenance: "deepseek-v4.1-flash#opencode", requiresReasoningContent: true))
        check("deepseek compaction shape: note carries \"\", round keeps its reasoning, others untouched",
              dsWire == [nil, nil, "", "call it", nil])
        let otherWire = try wireKeys(OpenRouterService.assembleRequestMessages(
            compactionShape, provider: .openAICompatible, useReasoningContent: true,
            effectiveProvenance: "deepseek-v4.1-flash#opencode"))
        check("same shape without the flag is byte-identical to before (note has no field)",
              otherWire == [nil, nil, nil, "call it", nil])

        failures += try await hostPinScopeChecks()
        failures += try await openCodeProtocolChecks()
        failures += try await mimoChecks()
        failures += try await mimoAuxiliaryChecks()

        print(failures == 0
              ? "\nAll provider-profile checks passed."
              : "\n\(failures) provider-profile check(s) FAILED.")
        if failures > 0 { throw ExitCode(1) }
    }

    /// 5e″ — Codex review of e3a0b38 (2026-09-19), three corrections:
    ///   R1 pin scope: the /orprovider pin applies to requests on the MAIN
    ///      model only (main agent + subagents, whose cheap lanes are
    ///      bypassed while pinned — owner decision; the Web researcher too
    ///      since it runs the main model, 2026-09-25); any other model keeps
    ///      automatic routing.
    ///   R2 retired catalog entries keep their capability facts when typed.
    ///   R3 /orprovider and the /model revalidation re-check state after
    ///      the listing await; a cancelled lookup never writes.
    /// Drives the real command handlers and execution-context builders
    /// with the fetch seam standing in for OpenRouter; storage is the
    /// selftest's temp roots.
    @MainActor
    private func hostPinScopeChecks() async throws -> Int {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        typealias Pin = OpenRouterProviderPin
        UserDefaults.standard.setVolatileDomain(["should_resume_polling_on_launch": false], forName: UserDefaults.argumentDomain)
        defer {
            WebSearchBackend.processOverride = nil
            Pin.fetchOverride = nil
            try? Pin.setPin(nil)
        }
        let mainModel = "deepseek/deepseek-chat"
        try ProviderProfiles.saveProfile(.openrouter, apiKey: "synthetic-review-key", baseURL: nil, model: mainModel, effort: "high", textOnly: false)
        try ProviderProfiles.activate(.openrouter)
        try Pin.setPin(["deepinfra"])
        try KeychainHelper.save(key: KeychainHelper.openRouterWebSearchModelKey, value: "openai/gpt-5.6-luna")
        WebSearchBackend.processOverride = .openrouter
        let service = OpenRouterService()

        // R1 — scope of the pin across execution contexts.
        // Owner decision 2026-09-25: the Web researcher runs the MAIN model,
        // so while pinned it carries the main pin like every other subagent
        // (the configured web model no longer picks the researcher's model).
        let web = await service.researcherExecutionContext(modelOverride: nil, textOnlyOverride: nil, lane: .subagent("review-web"))
        check("R1 web researcher runs the main model and carries the main pin (only + no fallbacks), whatever the web model setting",
              web.model == mainModel && web.providerPreferences?.only == ["deepinfra"] && web.providerPreferences?.allow_fallbacks == false
              && web.reasoning?.effort == "high" && web.usageLaneLabel == "subagent:web" && web.lane == .subagent("review-web"),
              "model=\(web.model) prefs=\(String(describing: web.providerPreferences))")
        try KeychainHelper.save(key: KeychainHelper.openRouterWebSearchModelKey, value: "openai/gpt-5.6-luna")
        let main = await service.executionContext(modelOverride: nil, providerOverride: nil, reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main)
        check("R1 main-model request carries the pin as only + no fallbacks",
              main.providerPreferences?.only == ["deepinfra"] && main.providerPreferences?.allow_fallbacks == false)
        let sameModelChild = await service.executionContext(modelOverride: mainModel, providerOverride: nil, reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .subagent("review-same"))
        check("R1 subagent on the main model inherits the pin (intended: every subagent runs the main model while pinned)",
              sameModelChild.providerPreferences?.only == ["deepinfra"])
        let otherChild = await service.executionContext(modelOverride: "other/child-model", providerOverride: nil, reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .subagent("review-child"))
        check("R1 a request on any other model never inherits the pin",
              otherChild.providerPreferences == nil, "prefs=\(String(describing: otherChild.providerPreferences))")
        // Lane bypass while pinned — picks stay stored, routing ignores them.
        try SubagentModelLanes.setModel(.cheapText, model: "cheap/text-model", provider: .openRouter)
        try SubagentModelLanes.setModel(.cheapVision, model: "cheap/vision-model", provider: .openRouter)
        check("R1 lanes bypassed while pinned: configuredLanes empty, picks still stored, hint resolves to inherit, gate passes",
              SubagentModelLanes.configuredLanes(provider: .openRouter).isEmpty
              && SubagentModelLanes.storedModel(.cheapText, provider: .openRouter) == "cheap/text-model"
              && SubagentModelLanes.resolve(hint: "cheap-vision") == .inherit
              && ToolExecutor.agentModelHintError("cheap-text") == nil)
        let agentEnum = AvailableTools.agentTool.function.parameters.properties["model"]?.enumValues
        let agentDesc = AvailableTools.agentTool.function.parameters.properties["model"]?.description ?? ""
        check("R1 Agent schema offers only inherit and says why while pinned",
              agentEnum == ["inherit"] && agentDesc.contains("/orprovider"), agentDesc)
        let manager = ConversationManager()
        let laneStatus = (await manager.handleTerminalCommand("/subagentmodels") ?? []).joined(separator: "\n")
        check("R1 /subagentmodels shows the stored picks as bypassed with the reason",
              laneStatus.contains("cheap/text-model — bypassed") && laneStatus.contains("Bypassed while the OpenRouter host pin"), laneStatus)
        let laneSet = (await manager.handleTerminalCommand("/subagentmodels text cheap/text-two") ?? []).joined(separator: "\n")
        check("R1 setting a lane while pinned stores it and says it is bypassed",
              SubagentModelLanes.storedModel(.cheapText, provider: .openRouter) == "cheap/text-two" && laneSet.contains("Bypassed"), laneSet)
        try Pin.setPin(nil)
        check("R1 releasing the pin restores the lanes without re-entry",
              SubagentModelLanes.configuredLanes(provider: .openRouter).map(\.model) == ["cheap/vision-model", "cheap/text-two"]
              && SubagentModelLanes.resolve(hint: "cheap-vision") == .lane(.cheapVision, model: "cheap/vision-model"))
        let unpinnedMain = await service.executionContext(modelOverride: nil, providerOverride: nil, reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main)
        check("R1 no pin → no preferences on a non-Gemini main model (Briglia's default is Gemini-only)",
              unpinnedMain.providerPreferences == nil)
        // The OpenCode/custom provider's lanes are untouched by an OpenRouter pin.
        try SubagentModelLanes.setModel(.cheapText, model: "kimi-k2.6", provider: .openAICompatible)
        try Pin.setPin(["deepinfra"])
        check("R1 a pin never bypasses another provider's lanes",
              !SubagentModelLanes.hostPinBypass(provider: .openAICompatible)
              && SubagentModelLanes.configuredModel(.cheapText, provider: .openAICompatible) == "kimi-k2.6")
        try Pin.setPin(nil)
        try SubagentModelLanes.setModel(.cheapText, model: nil, provider: .openAICompatible)
        try SubagentModelLanes.setModel(.cheapText, model: nil, provider: .openRouter)
        try SubagentModelLanes.setModel(.cheapVision, model: nil, provider: .openRouter)

        // R2 — retired ids keep their capability facts; pickers unchanged.
        try ProviderProfiles.saveProfile(.opencode, apiKey: "synthetic-opencode-key", baseURL: nil, model: "glm-5.3-flash", effort: "high", textOnly: false)
        try ProviderProfiles.activate(.opencode)
        check("R2 catalogEntry finds retired ids (case-insensitive) and aliases; the picker does not list them",
              OpenCodeGo.catalogEntry(for: "GLM-5.3")?.textOnly == true
              && OpenCodeGo.catalogEntry(for: "deepseek-v4-pro")?.textOnly == true
              && OpenCodeGo.catalogEntry(for: "deepseek-v4-flash-vision-exp")?.textOnly == false
              && OpenCodeGo.catalogEntry(for: "deepseek-flash")?.id == "deepseek-v4.1-flash"
              && OpenCodeGo.catalogEntry(for: "some/unknown") == nil
              && !OpenCodeGo.choices.contains { $0.id == "glm-5.3" }
              && Set(OpenCodeGo.retired.map(\.id)).isDisjoint(with: OpenCodeGo.choices.map(\.id)))
        for retired in ["glm-5.3", "deepseek-v4-pro", "deepseek-v4-flash"] {
            _ = await manager.handleTerminalCommand("/model glm-5.3-flash")
            let reply = (await manager.handleTerminalCommand("/model " + retired) ?? []).joined()
            check("R2 typing retired text-only \(retired) turns OCR preprocessing on",
                  KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "true"
                  && KeychainHelper.load(key: KeychainHelper.openAICompatibleModelKey) == retired
                  && reply.contains("Text-only model"), reply)
        }
        _ = await manager.handleTerminalCommand("/model deepseek-v4-flash-vision-exp")
        check("R2 typing the retired vision id turns OCR preprocessing off",
              KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == nil)
        let aliasReply = (await manager.handleTerminalCommand("/model deepseek-flash") ?? []).joined()
        check("R2 typing the legacy alias stores the canonical id and says so",
              KeychainHelper.load(key: KeychainHelper.openAICompatibleModelKey) == "deepseek-v4.1-flash"
              && aliasReply.contains("legacy alias"), aliasReply)
        try SubagentModelLanes.setModel(.cheapVision, model: nil)
        let laneRefusal = (await manager.handleTerminalCommand("/subagentmodels vision glm-5.3") ?? []).joined()
        check("R2 a retired text-only id stays refused in the vision lane",
              SubagentModelLanes.configuredModel(.cheapVision) == nil && laneRefusal.contains("text-only"), laneRefusal)
        _ = await manager.handleTerminalCommand("/subagentmodels text glm-5.3")
        check("R2 …and accepted in the text lane", SubagentModelLanes.configuredModel(.cheapText) == "glm-5.3")
        try SubagentModelLanes.setModel(.cheapText, model: nil)
        try KeychainHelper.delete(key: KeychainHelper.textOnlyModelEnabledKey)

        // R3 — state re-check after the listing await; cancellation never writes.
        try ProviderProfiles.activate(.openrouter)
        try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: mainModel)
        try Pin.setPin(nil)
        let listed = Data(#"{"data":{"endpoints":[{"provider_name":"DeepInfra","tag":"deepinfra"}]}}"#.utf8)
        Pin.fetchOverride = { _, _ in listed }
        let plainPin = (await manager.handleTerminalCommand("/orprovider deepinfra") ?? []).joined()
        check("R3 control: an undisturbed lookup pins and names the scope",
              Pin.pinnedSlugs() == ["deepinfra"] && plainPin.contains("every subagent, the Web researcher included"), plainPin)
        _ = await manager.handleTerminalCommand("/orprovider off")
        check("R3 control: off releases", !Pin.isPinned)
        // Another channel switches the model while the listing is in flight.
        Pin.fetchOverride = { _, _ in
            _ = await manager.handleTerminalCommand("/model other/new-model")
            return listed
        }
        let raceReply = (await manager.handleTerminalCommand("/orprovider deepinfra") ?? []).joined()
        check("R3 model switch during the lookup → nothing pinned, reason given",
              !Pin.isPinned && raceReply.contains("model changed to other/new-model"), raceReply)
        try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: mainModel)
        // A newer explicit OFF arrives while an older pin lookup waits (key already absent).
        try Pin.setPin(nil)
        Pin.fetchOverride = { _, _ in
            _ = await manager.handleTerminalCommand("/orprovider off")
            return listed
        }
        let offReply = (await manager.handleTerminalCommand("/orprovider deepinfra") ?? []).joined()
        check("R3 a newer /orprovider off wins over the older pending pin",
              !Pin.isPinned && offReply.contains("Not pinned"), offReply)
        // A newer pin arrives from outside this process (direct store edit) during the lookup.
        Pin.fetchOverride = { _, _ in
            try Pin.setPin(["novita"])
            return listed
        }
        let externalReply = (await manager.handleTerminalCommand("/orprovider deepinfra") ?? []).joined()
        check("R3 a pin written outside the manager during the lookup is not overwritten",
              Pin.pinnedSlugs() == ["novita"] && externalReply.contains("Not pinned"), externalReply)
        try Pin.setPin(nil)
        // Cancellation: task flag, and URLError.cancelled from the session.
        Pin.fetchOverride = { _, _ in throw CancellationError() }
        let cancelledReply = (await manager.handleTerminalCommand("/orprovider deepinfra") ?? []).joined()
        check("R3 a cancelled lookup never saves the pin",
              !Pin.isPinned && cancelledReply.contains("cancelled"), cancelledReply)
        Pin.fetchOverride = { _, _ in throw URLError(.cancelled) }
        let urlCancelled = (await manager.handleTerminalCommand("/orprovider deepinfra") ?? []).joined()
        check("R3 URLError.cancelled is cancellation too — never 'saved anyway'",
              !Pin.isPinned && urlCancelled.contains("cancelled") && !urlCancelled.contains("saved anyway"), urlCancelled)
        var seamHit = false
        Pin.fetchOverride = { _, _ in seamHit = true; throw URLError(.cancelled) }
        do {
            _ = try await Pin.fetchEndpoints(model: "m", apiKey: "k")
            check("R3 fetchEndpoints maps URLError.cancelled to CancellationError", false, "no throw")
        } catch {
            check("R3 fetchEndpoints maps URLError.cancelled to CancellationError", seamHit && error is CancellationError, "\(error)")
        }
        // A genuine listing failure still saves with the note (unchanged behavior).
        Pin.fetchOverride = { _, _ in throw Pin.FetchError(description: "HTTP 503") }
        let failedReply = (await manager.handleTerminalCommand("/orprovider deepinfra") ?? []).joined()
        check("R3 an ordinary listing failure still saves the pin with the note",
              Pin.pinnedSlugs() == ["deepinfra"] && failedReply.contains("saved anyway"), failedReply)
        // /model revalidation: a newer pin stored during the lookup survives.
        try Pin.setPin(["old-host"])
        Pin.fetchOverride = { _, _ in
            try Pin.setPin(["deepinfra"])
            return listed
        }
        let revalReply = (await manager.handleTerminalCommand("/model other/model-three") ?? []).joined()
        check("R3 /model revalidation cannot delete a newer pin",
              Pin.pinnedSlugs() == ["deepinfra"] && revalReply.contains("left as is"), revalReply)
        // /model revalidation cancelled: pin kept, said so.
        try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: mainModel)
        try Pin.setPin(["old-host"])
        Pin.fetchOverride = { _, _ in throw CancellationError() }
        let revalCancelled = (await manager.handleTerminalCommand("/model other/model-four") ?? []).joined()
        check("R3 a cancelled revalidation keeps the pin and says so",
              Pin.pinnedSlugs() == ["old-host"] && revalCancelled.contains("cancelled"), revalCancelled)
        // /model revalidation undisturbed: unserved pin released (unchanged behavior).
        Pin.fetchOverride = { _, _ in listed }
        let revalReleased = (await manager.handleTerminalCommand("/model other/model-five") ?? []).joined()
        check("R3 control: an undisturbed revalidation still releases an unserved pin",
              !Pin.isPinned && revalReleased.contains("released: it doesn't serve"), revalReleased)
        try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: mainModel)

        // Codex round 2: cooperative cancellation that lands while the
        // listing completes NORMALLY, or fails for its own reasons, must be
        // seen by the task flag — not only by a thrown error. Each command
        // runs in its own task; the seam cancels that task from inside the
        // lookup, then returns valid JSON / throws an ordinary failure.
        try Pin.setPin(nil)
        Pin.fetchOverride = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return listed
        }
        let cancelledThenListed = await Task { @MainActor in
            let reply = await manager.handleTerminalCommand("/orprovider deepinfra")
            return (Task.isCancelled, (reply ?? []).joined())
        }.value
        check("R3.2 task cancelled during a lookup that returns normally → nothing pinned, says cancelled",
              cancelledThenListed.0 && !Pin.isPinned && cancelledThenListed.1.contains("cancelled"),
              "taskCancelled=\(cancelledThenListed.0) stored=\(Pin.pinnedSlugs()) reply=\(cancelledThenListed.1)")
        try Pin.setPin(nil)
        Pin.fetchOverride = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw Pin.FetchError(description: "synthetic HTTP 503 after cancellation")
        }
        let cancelledThenFailed = await Task { @MainActor in
            let reply = await manager.handleTerminalCommand("/orprovider deepinfra")
            return (Task.isCancelled, (reply ?? []).joined())
        }.value
        check("R3.2 task cancelled during a lookup that fails ordinarily → nothing pinned, never 'saved anyway'",
              cancelledThenFailed.0 && !Pin.isPinned && cancelledThenFailed.1.contains("cancelled") && !cancelledThenFailed.1.contains("saved anyway"),
              "taskCancelled=\(cancelledThenFailed.0) stored=\(Pin.pinnedSlugs()) reply=\(cancelledThenFailed.1)")
        try Pin.setPin(["old-host"])
        Pin.fetchOverride = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return listed
        }
        let cancelledRevalidation = await Task { @MainActor in
            let reply = await manager.handleTerminalCommand("/model other/model-six")
            return (Task.isCancelled, (reply ?? []).joined())
        }.value
        check("R3.2 task cancelled during a revalidation that returns normally → pin preserved, says cancelled",
              cancelledRevalidation.0 && Pin.pinnedSlugs() == ["old-host"] && cancelledRevalidation.1.contains("cancelled"),
              "taskCancelled=\(cancelledRevalidation.0) stored=\(Pin.pinnedSlugs()) reply=\(cancelledRevalidation.1)")
        try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: mainModel)
        // Pre-cancelled control: the flag is set before the command starts.
        try Pin.setPin(nil)
        var seamReached = false
        Pin.fetchOverride = { _, _ in seamReached = true; return listed }
        let preCancelled = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let reply = await manager.handleTerminalCommand("/orprovider deepinfra")
            return (Task.isCancelled, (reply ?? []).joined())
        }.value
        check("R3.2 control: a pre-cancelled task never reaches the transport and pins nothing",
              preCancelled.0 && !seamReached && !Pin.isPinned && preCancelled.1.contains("cancelled"),
              "seamReached=\(seamReached) stored=\(Pin.pinnedSlugs()) reply=\(preCancelled.1)")
        // Helper-level: a normal delivery on a cancelled task is cancellation.
        Pin.fetchOverride = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return listed
        }
        let helperOutcome: String = await Task {
            do { _ = try await Pin.fetchEndpoints(model: "m", apiKey: "k"); return "returned" }
            catch is CancellationError { return "cancellation" }
            catch { return "other: \(error)" }
        }.value
        check("R3.2 fetchEndpoints reports cancellation when the flag lands during a normal delivery",
              helperOutcome == "cancellation", helperOutcome)
        Pin.fetchOverride = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw Pin.FetchError(description: "HTTP 503")
        }
        let helperFailure: String = await Task {
            do { _ = try await Pin.fetchEndpoints(model: "m", apiKey: "k"); return "returned" }
            catch is CancellationError { return "cancellation" }
            catch { return "other: \(error)" }
        }.value
        check("R3.2 fetchEndpoints reports cancellation, not the ordinary failure, when the flag lands during a failure",
              helperFailure == "cancellation", helperFailure)
        // Not-cancelled control through the same task shape: pins normally.
        Pin.fetchOverride = { _, _ in listed }
        let plainTask = await Task { @MainActor in
            let reply = await manager.handleTerminalCommand("/orprovider deepinfra")
            return (Task.isCancelled, (reply ?? []).joined())
        }.value
        check("R3.2 control: the same task shape without cancellation pins normally",
              !plainTask.0 && Pin.pinnedSlugs() == ["deepinfra"] && plainTask.1.contains("the Web researcher included"), plainTask.1)
        try Pin.setPin(nil)
        return failures
    }

    /// v0.2.31 — OpenCode Go per-model protocol. The Go gateway serves its
    /// GPT models (today: Luna) over the Responses API and everything else
    /// over chat completions, as OpenCode's own client does. Briglia decides
    /// per request from the EFFECTIVE model (main model or lane override),
    /// keeps the runtime protocol slot in step through activation and
    /// /model, and never lets a stale slot pair GLM with Responses or Luna
    /// with chat completions. Every other profile keeps its stored protocol
    /// untouched.
    @MainActor
    private func openCodeProtocolChecks() async throws -> Int {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        UserDefaults.standard.setVolatileDomain(["should_resume_polling_on_launch": false], forName: UserDefaults.argumentDomain)
        let mainLane = AffinityLane.main
        func context(_ service: OpenRouterService, model: String? = nil, effort: String? = nil,
                     textOnly: Bool? = nil, lane: AffinityLane = mainLane) async -> ProviderExecutionContext {
            await service.executionContext(modelOverride: model, providerOverride: nil,
                reasoningEffortOverride: effort, textOnlyOverride: textOnly, lane: lane)
        }

        // P1 — the rule and the catalog.
        check("P1 usesResponses: every gpt-* id (case/whitespace tolerant), never gpt-oss-*, never the chat-completions families or an alias",
              OpenCodeGo.usesResponses("gpt-5.6-luna") && OpenCodeGo.usesResponses(" GPT-5.6-Luna ")
              && OpenCodeGo.usesResponses("gpt-6-astra") && !OpenCodeGo.usesResponses("gpt-oss-120b")
              && !OpenCodeGo.usesResponses("glm-5.3-flash") && !OpenCodeGo.usesResponses("kimi-k3")
              && !OpenCodeGo.usesResponses("deepseek-flash") && !OpenCodeGo.usesResponses("qwen3.8-max")
              && !OpenCodeGo.usesResponses(""))
        check("P1 wireProtocol(profile, model): OpenCode follows the model, the fixed profiles ignore it",
              ProviderProfiles.wireProtocol(.opencode, model: "gpt-5.6-luna") == .responses
              && ProviderProfiles.wireProtocol(.opencode, model: "glm-5.3-flash") == .chatCompletions
              && ProviderProfiles.wireProtocol(.opencode, model: nil) == .chatCompletions
              && ProviderProfiles.wireProtocol(.openai, model: "glm-5.3-flash") == .responses
              && ProviderProfiles.wireProtocol(.chatgpt, model: "glm-5.3-flash") == .responses
              && ProviderProfiles.wireProtocol(.openrouter, model: "gpt-5.6-luna") == .chatCompletions
              && ProviderProfiles.wireProtocol(.local, model: "gpt-5.6-luna") == .chatCompletions)
        check("P1 the Responses effort list for Luna is the one the Go gateway accepts (none…max, no minimal)",
              ResponsesAdapter.allowedEfforts(model: "gpt-5.6-luna") == ["none", "low", "medium", "high", "xhigh", "max"])
        check("P1 GPT-6 Sol/Luna take the live-verified subscription efforts (none…max, no minimal); GPT-6 Sol is the subscription default and first in the catalog",
              ["gpt-6-sol", "gpt-6-luna", "gpt-6-sol-2026-09-22"].allSatisfy {
                  ResponsesAdapter.allowedEfforts(model: $0) == ["none", "low", "medium", "high", "xhigh", "max"]
              }
              && ResponsesAdapter.subscriptionDefaultModel == "gpt-6-sol"
              && ResponsesAdapter.subscriptionModelChoices.first?.id == "gpt-6-sol"
              && ResponsesAdapter.subscriptionModelChoices.contains { $0.id == "gpt-6-luna" })

        // P2 — activation stamps the slot; requests resolve per effective model.
        try ProviderProfiles.saveProfile(.opencode, apiKey: "oc-synthetic-key-1234567890", baseURL: nil,
                                         model: "gpt-5.6-luna", effort: "high", textOnly: false)
        try ProviderProfiles.activate(.opencode)
        var snap = KeychainHelper.loadSnapshot()
        check("P2 activating OpenCode on Luna stamps the runtime protocol slot, vision on, no native-media override, profile reports Responses",
              snap[ProviderProfiles.runtimeProtocolKey] == "responses" && snap[KeychainHelper.textOnlyModelEnabledKey] != "true"
              && snap[ProviderProfiles.runtimeNativeMediaKey] == nil && ProviderProfiles.usesResponses
              && ProviderProfiles.wireProtocol(.opencode) == .responses
              && ProviderProfiles.statusLines().contains(where: { $0.contains("opencode — ACTIVE") && $0.contains("Responses API") }),
              ProviderProfiles.statusLines().joined(separator: "\n"))
        let service = OpenRouterService()
        let main = await context(service)
        check("P2 main request on Luna: Responses at the Go endpoint, stored effort, vision, native tool media, opencode identity, no subscription generation",
              main.wireProtocol == .responses && main.endpoint == OpenCodeGo.baseURL && main.model == "gpt-5.6-luna"
              && main.reasoningEffort == "high" && !main.textOnly && main.nativeToolMedia && main.renderPDFAsImages
              && main.subscriptionGeneration == nil && main.profileIdentity == "opencode"
              && main.provenance == "gpt-5.6-luna#responses" && main.configurationError == nil,
              "\(main.wireProtocol) \(main.endpoint) \(main.model) \(main.reasoningEffort ?? "-") \(main.profileIdentity)")
        let built = try ResponsesAdapter(context: main).request(input: [ResponsesAdapter.message(role: "user", text: "hi")], tools: nil)
        check("P2 the built request targets the Go gateway's /responses route with the key and no subscription headers",
              built.url?.absoluteString == OpenCodeGo.baseURL + "/responses"
              && built.value(forHTTPHeaderField: "Authorization") == "Bearer oc-synthetic-key-1234567890"
              && built.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil,
              built.url?.absoluteString ?? "nil")
        let glmLane = await context(service, model: "glm-5.3-flash", effort: "medium", textOnly: false, lane: .subagent("lane-glm"))
        check("P2 a cheap lane on GLM under a Luna main runs chat completions with the reasoning_content contract and GLM's effort remap",
              glmLane.wireProtocol == .chatCompletions && glmLane.model == "glm-5.3-flash" && glmLane.useReasoningContent
              && glmLane.reasoningEffort == "high" && glmLane.endpoint == OpenCodeGo.baseURL + "/chat/completions"
              && glmLane.provenance == OpenRouterService.reasoningProvenance(model: "glm-5.3-flash", provider: .openAICompatible),
              "\(glmLane.wireProtocol) \(glmLane.reasoningEffort ?? "-") \(glmLane.provenance) endpoint=\(glmLane.endpoint) static=\(OpenRouterService.reasoningProvenance(model: "glm-5.3-flash", provider: .openAICompatible)) rc=\(glmLane.useReasoningContent) model=\(glmLane.model)")
        let kimiLane = await context(service, model: "kimi-k3", lane: .subagent("lane-kimi"))
        check("P2 a cheap lane on Kimi under a Luna main runs chat completions too",
              kimiLane.wireProtocol == .chatCompletions && kimiLane.useReasoningContent)
        let aux = ResponsesAuxiliary.inheritedSnapshot(lane: .archive)
        check("P2 archive/description work on the main model inherits Responses at the Go endpoint with the opencode identity and native media",
              aux?.wireProtocol == .responses && aux?.endpoint == OpenCodeGo.baseURL && aux?.model == "gpt-5.6-luna"
              && aux?.profileIdentity == "opencode" && aux?.nativeToolMedia == true && aux?.subscriptionGeneration == nil
              && aux?.responsesOperation == .archive)
        let probe = ResponsesAuxiliary.inheritedSnapshot(lane: .probe(UUID()), effortOverride: ResponsesAdapter.probeEffort(model: "gpt-5.6-luna"))
        check("P2 the doctor's probe snapshot is a Responses probe on Luna at low effort",
              probe?.wireProtocol == .responses && probe?.responsesOperation == .probe && probe?.reasoningEffort == "low")

        // P3 — the /model handler flips the slot in the same write and fixes
        // an effort the new transport rejects.
        let manager = ConversationManager()
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleReasoningEffortKey, value: "minimal")
        try KeychainHelper.save(key: ProviderProfiles.opencodeReasoningEffortKey, value: "minimal")
        let toGLM = (await manager.handleTerminalCommand("/model glm-5.3-flash") ?? []).joined(separator: "\n")
        snap = KeychainHelper.loadSnapshot()
        check("P3 /model to GLM clears the protocol slot, mirrors the profile, keeps a chat-completions effort, says nothing about Responses",
              snap[ProviderProfiles.runtimeProtocolKey] == nil && snap[KeychainHelper.openAICompatibleModelKey] == "glm-5.3-flash"
              && snap[ProviderProfiles.opencodeModelKey] == "glm-5.3-flash" && snap[KeychainHelper.openAICompatibleReasoningEffortKey] == "minimal"
              && snap[ProviderProfiles.opencodeReasoningEffortKey] == "minimal" && !ProviderProfiles.usesResponses
              && !toGLM.contains("Responses API") && toGLM.contains("Vision model"), toGLM)
        let glmMain = await context(service)
        let lunaLane = await context(service, model: "gpt-5.6-luna", lane: .subagent("lane-luna"))
        check("P3 main request on GLM is chat completions; a Luna lane under it is Responses; no auxiliary Responses snapshot",
              glmMain.wireProtocol == .chatCompletions && glmMain.useReasoningContent && glmMain.model == "glm-5.3-flash"
              && lunaLane.wireProtocol == .responses && lunaLane.model == "gpt-5.6-luna" && lunaLane.provenance == "gpt-5.6-luna#responses"
              && ResponsesAuxiliary.inheritedSnapshot(lane: .archive) == nil)
        let toLuna = (await manager.handleTerminalCommand("/model gpt-5.6-luna") ?? []).joined(separator: "\n")
        snap = KeychainHelper.loadSnapshot()
        check("P3 /model to Luna stamps the slot, turns vision on, replaces the unsupported effort 'minimal' with 'low' in both slots, and says so",
              snap[ProviderProfiles.runtimeProtocolKey] == "responses" && snap[KeychainHelper.textOnlyModelEnabledKey] == nil
              && snap[KeychainHelper.openAICompatibleModelKey] == "gpt-5.6-luna"
              && snap[KeychainHelper.openAICompatibleReasoningEffortKey] == "low" && snap[ProviderProfiles.opencodeReasoningEffortKey] == "low"
              && toLuna.contains("Responses API") && toLuna.contains("set to low") && toLuna.contains("Vision model")
              && ProviderProfiles.usesResponses, toLuna)
        let effortHelp = (await manager.handleTerminalCommand("/effort") ?? []).joined(separator: "\n")
        check("P3 /effort on Luna offers the Responses levels of the model",
              effortHelp.contains("none|low|medium|high|xhigh|max"), effortHelp)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleReasoningEffortKey, value: "max")
        let toLunaAgain = (await manager.handleTerminalCommand("/model gpt-5.6-luna") ?? []).joined(separator: "\n")
        check("P3 an effort Luna accepts ('max') is left alone by a re-switch",
              KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) == "max" && !toLunaAgain.contains("isn't available"), toLunaAgain)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleReasoningEffortKey, value: "none")
        try KeychainHelper.save(key: ProviderProfiles.opencodeReasoningEffortKey, value: "none")
        let backToGLM = (await manager.handleTerminalCommand("/model glm-5.3-flash") ?? []).joined(separator: "\n")
        snap = KeychainHelper.loadSnapshot()
        check("P3 /model back to GLM clears a Responses-only effort ('none') in both slots and says so",
              snap[ProviderProfiles.runtimeProtocolKey] == nil && snap[KeychainHelper.openAICompatibleReasoningEffortKey] == nil
              && snap[ProviderProfiles.opencodeReasoningEffortKey] == nil && backToGLM.contains("cleared"), backToGLM)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleReasoningEffortKey, value: "max")
        let glmMax = (await manager.handleTerminalCommand("/model glm-5.3-flash") ?? []).joined(separator: "\n")
        check("P3 a chat-completions effort GLM accepts ('max') survives a re-switch",
              KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) == "max" && !glmMax.contains("cleared"), glmMax)

        // P4 — derivation on read beats a stale slot (hand edits, external writers).
        try KeychainHelper.save(key: ProviderProfiles.runtimeProtocolKey, value: "responses")
        let staleSlot = await context(service)
        check("P4 a stale 'responses' slot on a GLM main never sends GLM to /responses",
              staleSlot.wireProtocol == .chatCompletions && !ProviderProfiles.usesResponses
              && ResponsesAuxiliary.inheritedSnapshot(lane: .archive) == nil)
        try KeychainHelper.delete(key: ProviderProfiles.runtimeProtocolKey)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "gpt-5.6-luna")
        let handEdited = await context(service)
        check("P4 a hand-edited runtime model 'gpt-5.6-luna' with the slot absent still runs Responses",
              handEdited.wireProtocol == .responses && ProviderProfiles.usesResponses
              && ResponsesAuxiliary.inheritedSnapshot(lane: .archive)?.wireProtocol == .responses)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "glm-5.3-flash")
        let laneSet = (await manager.handleTerminalCommand("/subagentmodels vision gpt-5.6-luna") ?? []).joined(separator: "\n")
        check("P4 the vision lane accepts Luna on OpenCode (it sees images over Responses)",
              SubagentModelLanes.storedModel(.cheapVision, provider: .openAICompatible) == "gpt-5.6-luna" && !laneSet.contains("text-only"), laneSet)
        try SubagentModelLanes.setModel(.cheapVision, model: nil, provider: .openAICompatible)

        // P5 — the per-model rule is OpenCode-only: other profiles keep their stored protocol.
        try ProviderProfiles.saveProfile(.custom, apiKey: "custom-synthetic-key-1234567890", baseURL: "https://example.invalid/v1",
                                         model: "gpt-5.6-luna", effort: "high", textOnly: false, wireProtocol: .chatCompletions)
        try ProviderProfiles.activate(.custom)
        let customLuna = await context(service)
        check("P5 a custom profile on a gpt-* id keeps its explicit chat-completions protocol",
              customLuna.wireProtocol == .chatCompletions && !ProviderProfiles.usesResponses
              && KeychainHelper.loadSnapshot()[ProviderProfiles.runtimeProtocolKey] == nil
              && ProviderProfiles.wireProtocol(.custom, model: "gpt-5.6-luna") == .chatCompletions)
        try ProviderProfiles.saveProfile(.openai, apiKey: "sk-synthetic-openai-key-1234567890", baseURL: nil,
                                         model: "glm-5.3-flash", effort: nil, textOnly: false)
        try ProviderProfiles.activate(.openai)
        let openaiOther = await context(service)
        check("P5 the OpenAI profile stays Responses whatever the model id, slot stamped as before",
              openaiOther.wireProtocol == .responses && openaiOther.profileIdentity == "openai"
              && KeychainHelper.loadSnapshot()[ProviderProfiles.runtimeProtocolKey] == "responses" && ProviderProfiles.usesResponses)

        // ---- Codex round 1 on e8f528d (2026-09-21) ----
        // C1 — R1: the stored effort is resolved per effective model at
        // request time (main, lanes, auxiliary work), never rewritten there.
        check("C1 compatibleEffort: Responses model keeps an accepted value, minimal→low, max→xhigh only where max is not accepted, junk dropped; chat model drops none and keeps the rest verbatim",
              OpenCodeGo.compatibleEffort("high", for: "gpt-5.6-luna") == "high"
              && OpenCodeGo.compatibleEffort(" Max ", for: "gpt-5.6-luna") == " Max "
              && OpenCodeGo.compatibleEffort("minimal", for: "gpt-5.6-luna") == "low"
              && OpenCodeGo.compatibleEffort("max", for: "gpt-7-preview") == "xhigh"
              && OpenCodeGo.compatibleEffort("ultra", for: "gpt-5.6-luna") == nil
              && OpenCodeGo.compatibleEffort("", for: "gpt-5.6-luna") == nil
              && OpenCodeGo.compatibleEffort("none", for: "glm-5.3-flash") == nil
              && OpenCodeGo.compatibleEffort("Minimal", for: "glm-5.3-flash") == "Minimal"
              && OpenCodeGo.compatibleEffort("max", for: "kimi-k2.6") == "max")
        // GLM main on minimal (accepted on chat) → a Luna lane inherits it: builds and sends low, stored value untouched.
        try ProviderProfiles.saveProfile(.opencode, apiKey: "oc-synthetic-key-1234567890", baseURL: nil,
                                         model: "glm-5.3-flash", effort: "minimal", textOnly: false)
        try ProviderProfiles.activate(.opencode)
        let lunaLaneMinimal = await context(service, model: "gpt-5.6-luna", lane: .subagent("c1-luna-lane"))
        let lunaLaneRequest = try? ResponsesAdapter(context: lunaLaneMinimal).request(input: [ResponsesAdapter.message(role: "user", text: "hi")], tools: nil)
        let glmMainMinimal = await context(service)
        check("C1 a Luna lane under a GLM main on 'minimal' resolves to Responses at 'low', its request builds, the stored main effort stays 'minimal' and the GLM main still remaps it (low)",
              lunaLaneMinimal.wireProtocol == .responses && lunaLaneMinimal.reasoningEffort == "low" && lunaLaneRequest != nil
              && KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) == "minimal"
              && KeychainHelper.load(key: ProviderProfiles.opencodeReasoningEffortKey) == "minimal"
              && glmMainMinimal.wireProtocol == .chatCompletions && glmMainMinimal.reasoningEffort == "low",
              "\(lunaLaneMinimal.reasoningEffort ?? "-") built=\(lunaLaneRequest != nil)")
        // An upgraded Luna profile: minimal + text-only + no protocol slot, activated by the migration guard only.
        try KeychainHelper.saveBatch([ProviderProfiles.opencodeModelKey: "gpt-5.6-luna", KeychainHelper.openAICompatibleModelKey: "gpt-5.6-luna",
                                      ProviderProfiles.opencodeReasoningEffortKey: "minimal", KeychainHelper.openAICompatibleReasoningEffortKey: "minimal",
                                      ProviderProfiles.opencodeTextOnlyKey: "true", KeychainHelper.textOnlyModelEnabledKey: "true",
                                      ProviderProfiles.runtimeProtocolKey: String?.none])
        ProviderProfiles.ensureMigrated()
        let upgradedMain = await context(service)
        let upgradedAux = ResponsesAuxiliary.inheritedSnapshot(lane: .archive)
        let upgradedRequest = try? ResponsesAdapter(context: upgradedMain).request(input: [ResponsesAdapter.message(role: "user", text: "hi")], tools: nil)
        let upgradedAuxRequest = upgradedAux.flatMap { try? ResponsesAdapter(context: $0).request(input: [ResponsesAdapter.message(role: "user", text: "hi")], tools: nil) }
        check("C1 an upgraded Luna profile (minimal, no slot) builds main AND archive requests over Responses at 'low' without any /model re-selection; stored minimal untouched",
              upgradedMain.wireProtocol == .responses && upgradedMain.reasoningEffort == "low" && upgradedRequest != nil
              && upgradedAux?.reasoningEffort == "low" && upgradedAuxRequest != nil
              && KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) == "minimal",
              "\(upgradedMain.reasoningEffort ?? "-") aux=\(upgradedAux?.reasoningEffort ?? "-")")
        check("C3 the doctor nudges an upgraded Luna profile still flagged text-only, and only that case",
              Doctor.openCodeStaleTextOnlyAdvisory(model: "gpt-5.6-luna", textOnly: true, activeProfile: .opencode)?.contains("/model gpt-5.6-luna") == true
              && Doctor.openCodeStaleTextOnlyAdvisory(model: "gpt-5.6-luna", textOnly: false, activeProfile: .opencode) == nil
              && Doctor.openCodeStaleTextOnlyAdvisory(model: "glm-5.3-flash", textOnly: true, activeProfile: .opencode) == nil
              && Doctor.openCodeStaleTextOnlyAdvisory(model: "gpt-5.6-luna", textOnly: true, activeProfile: .custom) == nil
              && Doctor.openCodeStaleTextOnlyAdvisory(model: "gpt-5.6-luna", textOnly: true, activeProfile: nil) == nil)
        // Reverse: Luna main on 'none' → a GLM lane must not carry 'none'; a Kimi lane likewise; the doctor probe override still wins.
        try KeychainHelper.saveBatch([KeychainHelper.openAICompatibleReasoningEffortKey: "none", ProviderProfiles.opencodeReasoningEffortKey: "none",
                                      KeychainHelper.textOnlyModelEnabledKey: String?.none, ProviderProfiles.opencodeTextOnlyKey: "false"])
        let glmLaneNone = await context(service, model: "glm-5.3-flash", lane: .subagent("c1-glm-lane"))
        let kimiLaneNone = await context(service, model: "kimi-k2.6", lane: .subagent("c1-kimi-lane"))
        let lunaMainNone = await context(service)
        check("C1 a GLM or Kimi lane under a Luna main on 'none' sends no effort field (chat completions), the Luna main keeps 'none' on Responses, stored value untouched",
              glmLaneNone.wireProtocol == .chatCompletions && glmLaneNone.reasoningEffort == nil && glmLaneNone.thinkingType == nil
              && kimiLaneNone.wireProtocol == .chatCompletions && kimiLaneNone.reasoningEffort == nil
              && lunaMainNone.wireProtocol == .responses && lunaMainNone.reasoningEffort == "none"
              && KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) == "none",
              "glm=\(glmLaneNone.reasoningEffort ?? "nil") kimi=\(kimiLaneNone.reasoningEffort ?? "nil") luna=\(lunaMainNone.reasoningEffort ?? "nil")")
        let probeOverride = ResponsesAuxiliary.inheritedSnapshot(lane: .probe(UUID()), effortOverride: "low")
        check("C1 an explicit auxiliary effort override is resolved the same way (low stays low)", probeOverride?.reasoningEffort == "low")
        // An explicit lane override that the lane's transport rejects is adapted too.
        let lunaLaneOverride = await context(service, model: "gpt-5.6-luna", effort: "minimal", lane: .subagent("c1-luna-override"))
        check("C1 an explicit per-call 'minimal' on a Luna lane is adapted to 'low'", lunaLaneOverride.reasoningEffort == "low")

        // C2 — R2: /model honours the resolver's profile boundary.
        let manager2 = ConversationManager()
        for (savedProtocol, target, expectSlot) in [(ProviderWireProtocol.chatCompletions, "gpt-5.6-luna", String?.none),
                                                     (ProviderWireProtocol.responses, "glm-5.3-flash", "responses")] {
            try ProviderProfiles.saveProfile(.custom, apiKey: "custom-synthetic-key-1234567890", baseURL: "https://opencode.ai/zen/v1",
                                             model: "kimi-k3", effort: "high", textOnly: false, wireProtocol: savedProtocol)
            try ProviderProfiles.activate(.custom)
            try KeychainHelper.save(key: KeychainHelper.openAICompatibleReasoningEffortKey, value: "none")
            let reply = (await manager2.handleTerminalCommand("/model \(target)") ?? []).joined(separator: "\n")
            let after = KeychainHelper.loadSnapshot()
            check("C2 a custom profile at an OpenCode host with explicit \(savedProtocol.rawValue): /model \(target) keeps the runtime slot (\(expectSlot ?? "absent")), the saved protocol, the effort, and says nothing about Responses",
                  after[ProviderProfiles.runtimeProtocolKey] == expectSlot
                  && after[ProviderProfiles.customProtocolKey] == (savedProtocol == .responses ? "responses" : nil)
                  && after[KeychainHelper.openAICompatibleModelKey] == target && after[ProviderProfiles.customModelKey] == target
                  && after[KeychainHelper.openAICompatibleReasoningEffortKey] == "none"
                  && !reply.contains("Responses API") && !reply.contains("cleared")
                  && ProviderProfiles.wireProtocol(.custom, model: target) == savedProtocol,
                  "slot=\(after[ProviderProfiles.runtimeProtocolKey] ?? "nil") saved=\(after[ProviderProfiles.customProtocolKey] ?? "nil") \(reply)")
            let customContext = await context(service)
            check("C2 …and its requests follow the saved protocol (\(savedProtocol.rawValue)) for \(target)",
                  customContext.wireProtocol == savedProtocol)
        }
        // Pre-profile compatibility path: no active profile, OpenCode runtime URL → host inference applies.
        try KeychainHelper.saveBatch([ProviderProfiles.activeProfileKey: String?.none, ProviderProfiles.customProtocolKey: String?.none,
                                      KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
                                      KeychainHelper.openAICompatibleBaseURLKey: OpenCodeGo.baseURL,
                                      KeychainHelper.openAICompatibleModelKey: "glm-5.3-flash",
                                      KeychainHelper.openAICompatibleApiKeyKey: "oc-synthetic-key-1234567890",
                                      ProviderProfiles.runtimeProtocolKey: String?.none])
        let preProfileLuna = await context(service, model: "gpt-5.6-luna", lane: .subagent("c2-pre"))
        check("C2 pre-profile install on the OpenCode URL: identified as OpenCode by the host, Luna resolves to Responses",
              ProviderProfiles.isOpenCodeRuntime(stored: KeychainHelper.loadSnapshot())
              && preProfileLuna.wireProtocol == .responses
              && ProviderProfiles.runtimeProtocolValue(stored: KeychainHelper.loadSnapshot(), model: "gpt-5.6-luna") == "responses")
        return failures
    }

    /// v0.2.32 — Xiaomi MiMo 2.6 (Flash/Pro) on the Go gateway. Facts
    /// verified live 2026-09-21: reasoning_content emitted and replayed on
    /// plain and tool-call turns and READ back (own-altered-code, in-turn and
    /// across turns), missing reasoning tolerated, effort low/medium/high
    /// only (minimal/xhigh/max = HTTP 400), full vision, prefix caching.
    /// The rows pin the three things Briglia needs for that: the
    /// reasoning_content predicate, the effort fold, and the catalog entries
    /// (vision on, Xiaomi block newest first, every picker derived from it).
    @MainActor
    private func mimoChecks() async throws -> Int {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        UserDefaults.standard.setVolatileDomain(["should_resume_polling_on_launch": false], forName: UserDefaults.argumentDomain)
        func context(_ service: OpenRouterService, model: String? = nil, effort: String? = nil,
                     lane: AffinityLane = .main) async -> ProviderExecutionContext {
            await service.executionContext(modelOverride: model, providerOverride: nil,
                reasoningEffortOverride: effort, textOnlyOverride: nil, lane: lane)
        }

        // X1 — predicate: both 2.6 ids, the web backend's 2.5, case/whitespace
        // tolerant; never a non-MiMo id.
        // Codex R2 (2026-09-22): MiMo drives reasoning_content on the OpenCode
        // runtime ONLY; the bare predicate (any OpenAI-compatible endpoint)
        // leaves it out, the established families keep their scope.
        check("X1 MiMo ids drive reasoning_content on the OpenCode runtime only (2.6 flash/pro, 2.5, case-insensitive); off-runtime and the bare predicate leave them out; Kimi keeps its any-endpoint scope; non-MiMo ids untouched",
              OpenRouterService.usesReasoningContent(model: "mimo-v2.6-flash", onOpenCodeRuntime: true)
              && OpenRouterService.usesReasoningContent(model: "mimo-v2.6-pro", onOpenCodeRuntime: true)
              && OpenRouterService.usesReasoningContent(model: "MiMo-V2.6-Pro", onOpenCodeRuntime: true)
              && OpenRouterService.usesReasoningContent(model: "mimo-v2.5", onOpenCodeRuntime: true)
              && !OpenRouterService.usesReasoningContent(model: "mimo-v2.6-flash", onOpenCodeRuntime: false)
              && !OpenRouterService.usesReasoningContent(model: "mimo-v2.6-pro", onOpenCodeRuntime: false)
              && !OpenRouterService.isOpenCodeReasoningContentModel("mimo-v2.6-flash")
              && OpenRouterService.usesReasoningContent(model: "kimi-k2.6", onOpenCodeRuntime: false)
              && OpenRouterService.usesReasoningContent(model: "glm-5.3-flash", onOpenCodeRuntime: false)
              && OpenRouterService.isOpenCodeMiMoModel("mimo-v2.6-flash")
              && !OpenRouterService.isOpenCodeMiMoModel("minimax-m3")
              && !OpenRouterService.isOpenCodeMiMoModel("gpt-5.6-luna"))

        // X2 — catalog: both entries curated, vision on, Xiaomi block newest
        // first and contiguous, default still first, every picker derived.
        let ids = OpenCodeGo.choices.map(\.id)
        let mimoPositions = ids.indices.filter { ids[$0].hasPrefix("mimo-") }
        check("X2 catalog carries MiMo 2.6 Pro then Flash as one contiguous Xiaomi block, both vision, default still first",
              ids.filter { $0.hasPrefix("mimo-") } == ["mimo-v2.6-pro", "mimo-v2.6-flash"]
              && mimoPositions.count == 2 && mimoPositions[1] - mimoPositions[0] == 1
              && ids.first == OpenCodeGo.defaultModel
              && OpenCodeGo.catalogEntry(for: "mimo-v2.6-flash")?.textOnly == false
              && OpenCodeGo.catalogEntry(for: " MiMo-v2.6-Pro ")?.id == "mimo-v2.6-pro"
              && OpenCodeGo.catalogEntry(for: "mimo-v2.5") == nil,
              "\(ids)")
        check("X2 MiMo stays on chat completions (never Responses) and compatibleEffort passes chat values through except 'none'",
              !OpenCodeGo.usesResponses("mimo-v2.6-flash") && !OpenCodeGo.usesResponses("mimo-v2.6-pro")
              && OpenCodeGo.compatibleEffort("max", for: "mimo-v2.6-pro") == "max"
              && OpenCodeGo.compatibleEffort("none", for: "mimo-v2.6-pro") == nil)

        // X3 — request-time effort fold on the OpenCode profile: main model
        // and cheap lanes, all six tiers.
        let service = OpenRouterService()
        try ProviderProfiles.saveProfile(.opencode, apiKey: "oc-synthetic-key-1234567890", baseURL: nil,
                                         model: "mimo-v2.6-flash", effort: "max", textOnly: false)
        try ProviderProfiles.activate(.opencode)
        let mainMax = await context(service)
        check("X3 MiMo main on stored 'max' builds at 'high' on chat completions with reasoning_content replay, no thinking flag, stored value untouched",
              mainMax.wireProtocol == .chatCompletions && mainMax.useReasoningContent && mainMax.reasoningEffort == "high"
              && mainMax.thinkingType == nil && mainMax.model == "mimo-v2.6-flash"
              && KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) == "max",
              "effort=\(mainMax.reasoningEffort ?? "nil") thinking=\(mainMax.thinkingType ?? "nil") rc=\(mainMax.useReasoningContent)")
        for (stored, sent) in [("minimal", "low"), ("low", "low"), ("medium", "medium"), ("high", "high"), ("xhigh", "high"), ("max", "high")] {
            let lane = await context(service, model: "mimo-v2.6-pro", effort: stored, lane: .subagent("x3-\(stored)"))
            check("X3 a MiMo Pro lane on explicit '\(stored)' sends '\(sent)'",
                  lane.reasoningEffort == sent && lane.useReasoningContent && lane.thinkingType == nil,
                  "effort=\(lane.reasoningEffort ?? "nil")")
        }
        // A MiMo lane under a Luna main (Responses, 'none'): the Responses-only
        // value is dropped before the fold → no effort field, thinking:enabled
        // (the model's default reasoning mode), still chat completions.
        try ProviderProfiles.saveProfile(.opencode, apiKey: "oc-synthetic-key-1234567890", baseURL: nil,
                                         model: "gpt-5.6-luna", effort: "none", textOnly: false)
        try ProviderProfiles.activate(.opencode)
        let mimoUnderLuna = await context(service, model: "mimo-v2.6-flash", lane: .subagent("x3-under-luna"))
        check("X3 a MiMo lane under a Luna main on 'none' sends no effort field, thinking:enabled, chat completions, reasoning_content",
              mimoUnderLuna.wireProtocol == .chatCompletions && mimoUnderLuna.reasoningEffort == nil
              && mimoUnderLuna.thinkingType == "enabled" && mimoUnderLuna.useReasoningContent,
              "effort=\(mimoUnderLuna.reasoningEffort ?? "nil") thinking=\(mimoUnderLuna.thinkingType ?? "nil")")
        // Other families keep their own folds (the MiMo rule must not leak).
        let glmLane = await context(service, model: "glm-5.3-flash", effort: "xhigh", lane: .subagent("x3-glm"))
        let kimiLane = await context(service, model: "kimi-k2.6", effort: "xhigh", lane: .subagent("x3-kimi"))
        check("X3 the MiMo fold does not leak: GLM 5.3 xhigh → max, Kimi K2.6 xhigh unchanged",
              glmLane.reasoningEffort == "max" && kimiLane.reasoningEffort == "xhigh",
              "glm=\(glmLane.reasoningEffort ?? "nil") kimi=\(kimiLane.reasoningEffort ?? "nil")")

        // X4 — the wire: a MiMo request replays stored reasoning as
        // reasoning_content (native), not as the downgraded system note.
        let stored = OpenRouterAPIMessage(role: "assistant", content: .text("Done."), toolCalls: nil, toolCallId: nil,
                                          reasoning: JSONValue.string("CODE=4827"), reasoningDetails: nil, reasoningContent: JSONValue.string("CODE=4827"))
        let (native, note) = stored.sanitizedForProvider(.openAICompatible, useReasoningContent: mainMax.useReasoningContent)
        var nativeReplay = false
        if case .string(let replayed)? = native.reasoningContent, replayed == "CODE=4827" { nativeReplay = true }
        check("X4 a stored MiMo assistant message replays reasoning_content natively with no downgrade note",
              nativeReplay && note == nil)

        // X5 — /model to a MiMo id from the Telegram/terminal handler: vision on,
        // effort fold applied visibly, chat completions slot.
        let manager = ConversationManager()
        try ProviderProfiles.saveProfile(.opencode, apiKey: "oc-synthetic-key-1234567890", baseURL: nil,
                                         model: "glm-5.3-flash", effort: "high", textOnly: false)
        try ProviderProfiles.activate(.opencode)
        try KeychainHelper.save(key: KeychainHelper.textOnlyModelEnabledKey, value: "true")
        let reply = (await manager.handleTerminalCommand("/model mimo-v2.6-pro") ?? []).joined(separator: "\n")
        let snap = KeychainHelper.loadSnapshot()
        check("X5 /model mimo-v2.6-pro: stored, vision on, runtime slot not Responses, effort kept",
              snap[KeychainHelper.openAICompatibleModelKey] == "mimo-v2.6-pro"
              && snap[ProviderProfiles.opencodeModelKey] == "mimo-v2.6-pro"
              && snap[KeychainHelper.textOnlyModelEnabledKey] != "true"
              && snap[ProviderProfiles.runtimeProtocolKey] != "responses"
              && snap[KeychainHelper.openAICompatibleReasoningEffortKey] == "high"
              && !reply.contains("Responses API"),
              "slot=\(snap[ProviderProfiles.runtimeProtocolKey] ?? "nil") textOnly=\(snap[KeychainHelper.textOnlyModelEnabledKey] ?? "nil") \(reply)")
        return failures
    }

    /// Codex review of 2269ec8 (2026-09-22), two corrections:
    ///   R1 the auxiliary chat-completions builders — archive maintenance
    ///      (`ConversationArchiveService.callLLM`), user-context structuring
    ///      (`UserContextStructurer.structure`) and file descriptions
    ///      (`generateFileDescriptions`) — go through the same request-time
    ///      rule as the main turn. Asserted on the HTTP body each REAL
    ///      builder sends to a loopback fixture, never on a helper.
    ///   R2 the MiMo rule is scoped to the OpenCode runtime: a custom profile
    ///      (unrelated host, or the OpenCode URL itself) keeps its
    ///      pre-0.2.32 bytes on every builder; a pre-profile install on the
    ///      OpenCode base URL is OpenCode.
    @MainActor
    private func mimoAuxiliaryChecks() async throws -> Int {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        UserDefaults.standard.setVolatileDomain(["should_resume_polling_on_launch": false], forName: UserDefaults.argumentDomain)
        let server = try WebFixtureServer()
        defer { server.stop() }
        server.route = { _ in .init(body: WebFixtureServer.chatBody("note.txt: Brief description.")) }
        let endpoint = "http://127.0.0.1:\(server.port)/v1"
        let service = OpenRouterService()
        let archive = ConversationArchiveService()

        struct Sent: Equatable, CustomStringConvertible {
            var model: String; var effort: String?; var thinking: String?; var path: String
            var description: String { "model=\(model) effort=\(effort ?? "nil") thinking=\(thinking ?? "nil") path=\(path)" }
        }
        func last() -> Sent {
            guard let req = server.requests.last,
                  let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
                return Sent(model: "NO REQUEST", effort: nil, thinking: nil, path: "")
            }
            return Sent(model: obj["model"] as? String ?? "nil", effort: obj["reasoning_effort"] as? String,
                        thinking: (obj["thinking"] as? [String: Any])?["type"] as? String, path: req.path)
        }
        /// Runs the three real builders in turn and returns what each sent.
        func auxiliaryBodies() async throws -> (archive: Sent, userContext: Sent, description: Sent) {
            server.clear()
            _ = try await archive.callLLM(systemPrompt: "Summarize.", userPrompt: "Synthetic archive input.")
            let a = last()
            server.clear()
            _ = try await UserContextStructurer.structure(assistantName: "Review", userName: "Test",
                rawContext: "Prefers concise answers.", existingContext: "", config: .fromKeychain())
            let u = last()
            server.clear()
            _ = try await service.generateFileDescriptions(files: [(filename: "note.txt", data: Data("Test".utf8), mimeType: "text/plain")])
            let d = last()
            return (a, u, d)
        }
        func namedOpenCode(model: String, effort: String?) throws {
            try ProviderProfiles.saveProfile(.opencode, apiKey: "oc-synthetic-key-1234567890", baseURL: nil,
                                             model: model, effort: effort, textOnly: false)
            try ProviderProfiles.activate(.opencode)
            // Local capture only: the NAMED profile is what identifies the
            // OpenCode runtime; its runtime URL is redirected to the fixture.
            try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: endpoint)
            try? KeychainHelper.delete(key: KeychainHelper.lmStudioDescriptionModelKey)
            try? KeychainHelper.delete(key: KeychainHelper.lmStudioDescriptionBaseURLKey)
        }

        // X6 — R1: every stored tier through all three auxiliary builders on
        // the named OpenCode profile with MiMo Flash: the three folded values
        // arrive folded, the accepted ones untouched, no thinking field,
        // stored value never rewritten.
        for (stored, sent) in [("minimal", "low"), ("xhigh", "high"), ("max", "high"), ("high", "high"), ("medium", "medium"), ("low", "low")] {
            try namedOpenCode(model: "mimo-v2.6-flash", effort: stored)
            let bodies = try await auxiliaryBodies()
            let expected = Sent(model: "mimo-v2.6-flash", effort: sent, thinking: nil, path: "/v1/chat/completions")
            check("X6 archive body on stored '\(stored)' sends '\(sent)' (MiMo Flash, named OpenCode profile)",
                  bodies.archive == expected, "\(bodies.archive)")
            check("X6 user-context body on stored '\(stored)' sends '\(sent)'",
                  bodies.userContext == expected, "\(bodies.userContext)")
            check("X6 file-description body on stored '\(stored)' sends '\(sent)'",
                  bodies.description == expected, "\(bodies.description)")
            check("X6 stored effort '\(stored)' is never rewritten by request-time resolution",
                  KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) == stored)
        }
        // MiMo Pro on the archive (the same predicate/fold, the other id).
        try namedOpenCode(model: "mimo-v2.6-pro", effort: "max")
        let pro = try await auxiliaryBodies()
        check("X6 MiMo Pro: all three auxiliary bodies fold 'max' to 'high'",
              pro.archive.effort == "high" && pro.userContext.effort == "high" && pro.description.effort == "high"
              && [pro.archive, pro.userContext, pro.description].allSatisfy { $0.model == "mimo-v2.6-pro" && $0.thinking == nil },
              "\(pro)")
        // No stored effort: the archive (which carries the thinking toggle)
        // sends thinking:enabled and no effort, as the main transport does
        // for a MiMo request with no effort (X3); the two builders that never
        // sent a thinking field still send neither.
        try namedOpenCode(model: "mimo-v2.6-flash", effort: nil)
        try? KeychainHelper.delete(key: KeychainHelper.openAICompatibleReasoningEffortKey)
        let none = try await auxiliaryBodies()
        check("X6 no stored effort: archive sends thinking:enabled and no effort; user-context and description send neither",
              none.archive.effort == nil && none.archive.thinking == "enabled"
              && none.userContext.effort == nil && none.userContext.thinking == nil
              && none.description.effort == nil && none.description.thinking == nil,
              "\(none)")
        // Effective target model: a separate description MODEL on the same
        // OpenCode runtime resolves the stored value against THAT model
        // (GLM 5.3 accepts 'max' unchanged) while the archive, on the main
        // MiMo model, still folds.
        try namedOpenCode(model: "mimo-v2.6-flash", effort: "max")
        try KeychainHelper.save(key: KeychainHelper.lmStudioDescriptionModelKey, value: "glm-5.3-flash")
        let separateModel = try await auxiliaryBodies()
        check("X6 a separate description model (GLM 5.3) on the OpenCode runtime is resolved against ITS fold ('max' kept) while the archive on MiMo folds to 'high'",
              separateModel.description == Sent(model: "glm-5.3-flash", effort: "max", thinking: nil, path: "/v1/chat/completions")
              && separateModel.archive.effort == "high",
              "description=\(separateModel.description) archive=\(separateModel.archive)")
        try KeychainHelper.save(key: KeychainHelper.lmStudioDescriptionModelKey, value: "kimi-k2.6")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleReasoningEffortKey, value: "minimal")
        let separateKimi = try await auxiliaryBodies()
        check("X6 a separate description model (Kimi K2.6) on the OpenCode runtime folds 'minimal' to 'low' (its own rule), archive on MiMo too",
              separateKimi.description == Sent(model: "kimi-k2.6", effort: "low", thinking: nil, path: "/v1/chat/completions")
              && separateKimi.archive.effort == "low",
              "description=\(separateKimi.description) archive=\(separateKimi.archive)")
        // A separately configured description ENDPOINT is a foreign host:
        // the stored value goes there raw, the archive on the runtime folds.
        try namedOpenCode(model: "mimo-v2.6-flash", effort: "max")
        try KeychainHelper.save(key: KeychainHelper.lmStudioDescriptionBaseURLKey, value: "http://127.0.0.1:\(server.port)/foreign/v1")
        let foreign = try await auxiliaryBodies()
        check("X6 an explicitly configured separate description endpoint is not the OpenCode runtime: 'max' sent raw there, archive still folds to 'high'",
              foreign.description == Sent(model: "mimo-v2.6-flash", effort: "max", thinking: nil, path: "/foreign/v1/chat/completions")
              && foreign.archive.effort == "high" && foreign.userContext.effort == "high",
              "description=\(foreign.description) archive=\(foreign.archive)")
        try? KeychainHelper.delete(key: KeychainHelper.lmStudioDescriptionBaseURLKey)
        // The established families are untouched by the MiMo work on the
        // auxiliary builders: GLM 5.3 'xhigh' → 'max' (its own map), and a
        // non-MiMo family's accepted value passes through.
        try namedOpenCode(model: "glm-5.3-flash", effort: "xhigh")
        let glm = try await auxiliaryBodies()
        check("X6 the MiMo fold does not leak into other families on the auxiliary builders: GLM 5.3 'xhigh' → 'max' on all three",
              glm.archive.effort == "max" && glm.userContext.effort == "max" && glm.description.effort == "max", "\(glm)")

        // X7 — R2: custom profiles keep their pre-0.2.32 bytes for a MiMo id,
        // at an unrelated host AND at the OpenCode URL (an explicit custom
        // profile pointed at the Go gateway is not the OpenCode runtime —
        // the same rule /model and the protocol derivation use).
        func context(_ lane: AffinityLane = .main) async -> ProviderExecutionContext {
            await service.executionContext(modelOverride: nil, providerOverride: nil,
                reasoningEffortOverride: nil, textOnlyOverride: nil, lane: lane)
        }
        for base in [endpoint, OpenCodeGo.baseURL] {
            let label = base == endpoint ? "unrelated host" : "OpenCode URL"
            try ProviderProfiles.saveProfile(.custom, apiKey: "custom-synthetic-key-1234567890", baseURL: base,
                                             model: "mimo-v2.6-flash", effort: "max", textOnly: false)
            try ProviderProfiles.activate(.custom)
            try? KeychainHelper.delete(key: KeychainHelper.lmStudioDescriptionModelKey)
            try? KeychainHelper.delete(key: KeychainHelper.lmStudioDescriptionBaseURLKey)
            let pinned = await context()
            check("X7 custom profile at \(label), MiMo on 'max': main context keeps 'max', no native replay, no thinking",
                  pinned.reasoningEffort == "max" && !pinned.useReasoningContent && pinned.thinkingType == nil
                  && pinned.wireProtocol == .chatCompletions,
                  "effort=\(pinned.reasoningEffort ?? "nil") rc=\(pinned.useReasoningContent) thinking=\(pinned.thinkingType ?? "nil")")
            let lane = await service.executionContext(modelOverride: "mimo-v2.6-pro", providerOverride: nil,
                reasoningEffortOverride: "minimal", textOnlyOverride: nil, lane: .subagent("x7-\(label)"))
            check("X7 custom profile at \(label): a MiMo Pro lane on 'minimal' keeps 'minimal', no native replay",
                  lane.reasoningEffort == "minimal" && !lane.useReasoningContent && lane.thinkingType == nil,
                  "effort=\(lane.reasoningEffort ?? "nil") rc=\(lane.useReasoningContent)")
            if base == endpoint {
                // Real bodies only against the loopback host.
                let bodies = try await auxiliaryBodies()
                check("X7 custom profile at \(label): all three auxiliary bodies send 'max' raw, no thinking",
                      bodies.archive.effort == "max" && bodies.userContext.effort == "max" && bodies.description.effort == "max"
                      && [bodies.archive, bodies.userContext, bodies.description].allSatisfy { $0.thinking == nil && $0.model == "mimo-v2.6-flash" },
                      "\(bodies)")
                // Replay on the wire: a stored MiMo message is downgraded to
                // the historical note, exactly as before v0.2.32.
                let storedMessage = OpenRouterAPIMessage(role: "assistant", content: .text("Done."), toolCalls: nil, toolCallId: nil,
                    reasoning: JSONValue.string("CODE=4827"), reasoningDetails: nil, reasoningContent: JSONValue.string("CODE=4827"))
                let (downgraded, note) = storedMessage.sanitizedForProvider(.openAICompatible, useReasoningContent: pinned.useReasoningContent)
                check("X7 custom profile at \(label): stored MiMo reasoning replays as the historical note, not reasoning_content",
                      downgraded.reasoningContent == nil && note != nil)
            }
            try KeychainHelper.delete(key: KeychainHelper.openAICompatibleReasoningEffortKey)
            let noEffort = await context()
            check("X7 custom profile at \(label), MiMo with no effort: no thinking field appears",
                  noEffort.reasoningEffort == nil && noEffort.thinkingType == nil && !noEffort.useReasoningContent,
                  "thinking=\(noEffort.thinkingType ?? "nil")")
            if base == endpoint {
                let bodies = try await auxiliaryBodies()
                check("X7 custom profile at \(label), no effort: no auxiliary body gains a thinking field",
                      bodies.archive.thinking == nil && bodies.archive.effort == nil
                      && bodies.userContext.thinking == nil && bodies.description.thinking == nil, "\(bodies)")
            }
        }
        // Pre-profile install (no active profile yet): the OpenCode base URL
        // identifies the runtime, so the MiMo rule applies; an unrelated
        // base URL without a profile does not.
        try namedOpenCode(model: "mimo-v2.6-flash", effort: "max")
        try KeychainHelper.delete(key: ProviderProfiles.activeProfileKey)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: OpenCodeGo.baseURL)
        let preProfile = await context()
        check("X7 pre-profile install on the OpenCode base URL: MiMo 'max' → 'high' with native replay (context only)",
              preProfile.reasoningEffort == "high" && preProfile.useReasoningContent && preProfile.thinkingType == nil,
              "effort=\(preProfile.reasoningEffort ?? "nil") rc=\(preProfile.useReasoningContent)")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: endpoint)
        let preProfileForeign = await context()
        let preProfileBodies = try await auxiliaryBodies()
        check("X7 pre-profile install on an unrelated base URL: MiMo keeps 'max' raw on the main context and all three auxiliary bodies",
              preProfileForeign.reasoningEffort == "max" && !preProfileForeign.useReasoningContent
              && preProfileBodies.archive.effort == "max" && preProfileBodies.userContext.effort == "max" && preProfileBodies.description.effort == "max",
              "context=\(preProfileForeign.reasoningEffort ?? "nil") \(preProfileBodies)")
        // Named OpenCode again, so the rule and the main context agree (the
        // positive control for the X7 rows): same profile, same builders.
        try namedOpenCode(model: "mimo-v2.6-flash", effort: "max")
        let named = await context()
        check("X7 positive control — named OpenCode profile: main context 'max' → 'high' with native replay",
              named.reasoningEffort == "high" && named.useReasoningContent && named.thinkingType == nil,
              "effort=\(named.reasoningEffort ?? "nil") rc=\(named.useReasoningContent)")
        return failures
    }
}
