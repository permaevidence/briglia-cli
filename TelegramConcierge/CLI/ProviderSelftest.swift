import ArgumentParser
import Foundation

/// Hidden deterministic test of the multi-provider profile system: legacy
/// migration into profiles, activation slot copies, per-profile vision state
/// restore, /model + /effort mirrors, unconfigured-hop guards, and masked
/// key listings. Self-isolates into temp XDG roots (set BEFORE the lazy
/// StoragePaths statics are first touched) so it never disturbs a real
/// installation.
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
        for model in ["kimi-k2.6", "kimi-k2.7-code", "kimi-k3", "glm-5.3-flash", "qwen3.8-max", "deepseek-flash", "minimax-m3"] {
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
        for choice in OpenCodeGo.choices {
            let expected = !choice.id.hasPrefix("gpt-")
            check("curated OpenCode model \(choice.id) reasoning_content recognition is \(expected)",
                  OpenRouterService.isOpenCodeReasoningContentModel(choice.id) == expected)
        }

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
        check("status lines flag unconfigured profiles",
              listing.contains("• custom — not configured"))

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

        print(failures == 0
              ? "\nAll provider-profile checks passed."
              : "\n\(failures) provider-profile check(s) FAILED.")
        if failures > 0 { throw ExitCode(1) }
    }
}
