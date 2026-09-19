import ArgumentParser
import Foundation

/// Hidden deterministic test of the cheap subagent model lanes: per-provider
/// storage, hint resolution, the Agent tool's dynamic model enum, the loud
/// hint gate, watcher lane round-trips, FireRecord snapshot compatibility,
/// and frontmatter model parsing (retired cheapFast = unrecognized →
/// inherit, in both the runtime loader and the serializer's editing parse).
/// Self-isolates into temp
/// XDG roots (set BEFORE the lazy StoragePaths statics are first touched) so
/// it never disturbs a real installation.
struct LaneSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__lane-selftest",
        abstract: "Internal: verify subagent model lanes, /subagentmodels storage and hint resolution.",
        shouldDisplay: false
    )

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-lane-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // Pin the active provider so resolution is deterministic.
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openRouter.rawValue)

        // 1. Unconfigured store: inherit-family hints resolve to inherit,
        //    lane names are unconfigured, everything else (including the
        //    retired sonnet/opus/haiku hints) is unknown.
        check("nil/empty/'inherit' resolve to inherit",
              SubagentModelLanes.resolve(hint: nil) == .inherit
              && SubagentModelLanes.resolve(hint: "") == .inherit
              && SubagentModelLanes.resolve(hint: "  Inherit ") == .inherit)
        check("lane names without config are unconfigured",
              SubagentModelLanes.resolve(hint: "cheap-vision") == .unconfigured(.cheapVision)
              && SubagentModelLanes.resolve(hint: "cheap-text") == .unconfigured(.cheapText))
        check("retired 'sonnet' hint is unknown",
              SubagentModelLanes.resolve(hint: "sonnet") == .unknown("sonnet"))

        // 2. The loud gate: valid hints pass, unset/unknown hints produce
        //    errors that point at /subagentmodels instead of silently
        //    inheriting at full price.
        check("gate passes inherit", ToolExecutor.agentModelHintError(nil) == nil
              && ToolExecutor.agentModelHintError("inherit") == nil)
        let unconfiguredError = ToolExecutor.agentModelHintError("cheap-text") ?? ""
        check("gate fails loudly on unconfigured lane",
              unconfiguredError.contains("error") && unconfiguredError.contains("/subagentmodels"))
        let unknownError = ToolExecutor.agentModelHintError("haiku") ?? ""
        check("gate fails loudly on unknown hint",
              unknownError.contains("Unknown model hint") && unknownError.contains("'inherit'"))

        // 3. Agent tool enum: only 'inherit' offered while nothing is configured.
        let bareEnum = AvailableTools.agentTool.function.parameters.properties["model"]?.enumValues
        check("Agent tool offers only inherit when no lane is configured", bareEnum == ["inherit"])

        // 4. Configure the text lane → resolution, text-only semantics, enum
        //    and description all reflect it.
        try SubagentModelLanes.setModel(.cheapText, model: "glm-5.3")
        check("configured text lane resolves with its model",
              SubagentModelLanes.resolve(hint: "cheap-text") == .lane(.cheapText, model: "glm-5.3"))
        check("text lane is text-only by definition", SubagentModelLane.cheapText.isTextOnly
              && !SubagentModelLane.cheapVision.isTextOnly)
        let textEnum = AvailableTools.agentTool.function.parameters.properties["model"]?.enumValues
        check("Agent tool offers inherit + the configured lane only", textEnum == ["inherit", "cheap-text"])
        let modelDesc = AvailableTools.agentTool.function.parameters.properties["model"]?.description ?? ""
        check("Agent tool description names the lane's model", modelDesc.contains("glm-5.3"))
        check("gate passes the configured lane", ToolExecutor.agentModelHintError("cheap-text") == nil)

        // 4b. Host-pin bypass (owner decision 2026-09-19): while /orprovider
        //     pins OpenRouter to one host, every subagent runs the main model
        //     there — lane hints resolve to inherit, the schema offers only
        //     inherit, the picks stay stored and return on release. Other
        //     providers' lanes are untouched.
        try OpenRouterProviderPin.setPin(["deepinfra"])
        check("pinned: lane hint resolves to inherit, not to the lane and not to unconfigured",
              SubagentModelLanes.resolve(hint: "cheap-text") == .inherit
              && SubagentModelLanes.resolve(hint: "cheap-vision") == .inherit)
        check("pinned: configuredModel is nil while storedModel keeps the pick",
              SubagentModelLanes.configuredModel(.cheapText) == nil
              && SubagentModelLanes.storedModel(.cheapText) == "glm-5.3")
        let pinnedEnum = AvailableTools.agentTool.function.parameters.properties["model"]?.enumValues
        let pinnedDesc = AvailableTools.agentTool.function.parameters.properties["model"]?.description ?? ""
        check("pinned: Agent tool offers only inherit and names the pin as the reason",
              pinnedEnum == ["inherit"] && pinnedDesc.contains("/orprovider"))
        check("pinned: the gate passes a lane hint quietly (runs the main model)",
              ToolExecutor.agentModelHintError("cheap-text") == nil)
        check("pinned: other providers are not bypassed",
              !SubagentModelLanes.hostPinBypass(provider: .openAICompatible)
              && !SubagentModelLanes.hostPinBypass(provider: .lmStudio))
        try OpenRouterProviderPin.setPin(nil)
        check("released: the lane is back exactly as configured",
              SubagentModelLanes.resolve(hint: "cheap-text") == .lane(.cheapText, model: "glm-5.3")
              && AvailableTools.agentTool.function.parameters.properties["model"]?.enumValues == ["inherit", "cheap-text"])

        // 5. Lanes are stored PER PROVIDER: the OpenCode/custom provider has
        //    its own (empty) slots; configuring there does not leak back.
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openAICompatible.rawValue)
        check("other provider starts unconfigured",
              SubagentModelLanes.resolve(hint: "cheap-text") == .unconfigured(.cheapText))
        try SubagentModelLanes.setModel(.cheapText, model: "minimax-m3")
        check("other provider stores its own pick",
              SubagentModelLanes.resolve(hint: "cheap-text") == .lane(.cheapText, model: "minimax-m3"))
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openRouter.rawValue)
        check("original provider's pick survives the round-trip",
              SubagentModelLanes.resolve(hint: "cheap-text") == .lane(.cheapText, model: "glm-5.3"))

        // 6. Both lanes configured → stable enum order; clearing one removes
        //    exactly it.
        try SubagentModelLanes.setModel(.cheapVision, model: "qwen3.8-max")
        let bothEnum = AvailableTools.agentTool.function.parameters.properties["model"]?.enumValues
        check("both lanes appear in stable order", bothEnum == ["inherit", "cheap-vision", "cheap-text"])
        try SubagentModelLanes.setModel(.cheapText, model: nil)
        let visionEnum = AvailableTools.agentTool.function.parameters.properties["model"]?.enumValues
        check("clearing one lane removes exactly it", visionEnum == ["inherit", "cheap-vision"]
              && SubagentModelLanes.resolve(hint: "cheap-text") == .unconfigured(.cheapText))

        // 7. Watcher round-trip: the lane lands on the row, update_triage
        //    semantics ('inherit' clears, nil leaves), moving to main clears.
        let service = ReminderService.shared
        let watcher = await service.createExternalTriggerReminder(
            prompt: "Lane selftest watcher",
            deleteAfterFire: false,
            notifyMode: "subagent",
            triageInstructions: "Notify on anything unusual.",
            triageModelLane: "cheap-vision"
        )
        check("creation stores the triage lane",
              await service.reminder(withId: watcher.id)?.triageModelLane == "cheap-vision")
        _ = await service.updateTriageRouting(id: watcher.id, notifyMode: nil, triageInstructions: "Higher bar. Notify on anything unusual.", triageModelLane: nil)
        check("lane survives an instructions-only update",
              await service.reminder(withId: watcher.id)?.triageModelLane == "cheap-vision")
        _ = await service.updateTriageRouting(id: watcher.id, notifyMode: nil, triageInstructions: nil, triageModelLane: "inherit")
        check("'inherit' clears the lane",
              await service.reminder(withId: watcher.id)?.triageModelLane == nil)
        _ = await service.updateTriageRouting(id: watcher.id, notifyMode: nil, triageInstructions: nil, triageModelLane: "cheap-text")
        _ = await service.updateTriageRouting(id: watcher.id, notifyMode: "main", triageInstructions: nil, triageModelLane: nil)
        check("moving to notify=main clears the lane",
              await service.reminder(withId: watcher.id)?.triageModelLane == nil)

        // 8. FireRecord snapshot: the lane is captured and persisted, and
        //    records written before this feature (no lane key) still decode.
        let record = FireRecord(
            watcherId: watcher.id,
            source: .external,
            content: "test fire",
            notifyMode: "subagent",
            triageInstructions: "bar",
            triageModelLane: "cheap-vision"
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(FireRecord.self, from: encoded)
        check("FireRecord round-trips the lane snapshot", decoded.triageModelLane == "cheap-vision")
        var legacyJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyJSON.removeValue(forKey: "triageModelLane")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacyDecoded = try? JSONDecoder().decode(FireRecord.self, from: legacyData)
        check("pre-lane FireRecords decode with nil lane",
              legacyDecoded != nil && legacyDecoded?.triageModelLane == nil)

        // 9. Frontmatter parsing: the lane names parse; the retired cheapFast
        //    value is unrecognized like any junk and falls back to inherit
        //    (with a stderr warning) — never a silent remap to cheap-vision.
        let agentsDir = StoragePaths.configRoot.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        func writeAgent(_ name: String, model: String) throws {
            let md = "---\nname: \(name)\ndescription: lane selftest agent\nmodel: \(model)\n---\nBody."
            try md.write(to: agentsDir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        try writeAgent("legacy-fast", model: "cheapFast")
        try writeAgent("new-text", model: "cheap-text")
        try writeAgent("junk-model", model: "gpt-9000")
        let loaded = UserAgentLoader.loadAll()
        func preferred(_ name: String) -> SubagentModelChoice? {
            loaded.first { $0.name == name }?.preferredModel
        }
        check("retired cheapFast is unrecognized and inherits", preferred("legacy-fast")?.lane == nil)
        check("cheap-text frontmatter parses", preferred("new-text")?.lane == .cheapText)
        check("unknown frontmatter model falls back to inherit", preferred("junk-model")?.lane == nil)

        // 9b. The serializer's editing parse stays aligned with the runtime
        //     loader on the retired value: unrecognized → inherit, never a
        //     silent remap to cheap-vision. Valid lane values round-trip.
        func editorModel(_ modelLine: String) -> String? {
            SubagentSerializer.parseForEditing("""
            ---
            name: lane-parse-probe
            description: probe
            model: \(modelLine)
            ---
            body
            """)?.model
        }
        check("editor parse: retired cheapFast shows as inherit",
              editorModel("cheapFast") == "inherit"
              && editorModel("cheap_fast") == "inherit")
        check("editor parse: lane values survive",
              editorModel("cheap-vision") == "cheap-vision"
              && editorModel("cheap-text") == "cheap-text"
              && editorModel("inherit") == "inherit")

        // 10. Group drains run the captured lane only when it is UNIFORM
        //     across the batches; any mix (lanes aren't orderable — inherit
        //     may itself be a text-only model) runs on inherit, the
        //     pre-triage system baseline.
        func rec(_ lane: String?) -> FireRecord {
            FireRecord(watcherId: UUID(), source: .external, content: "x",
                       notifyMode: "subagent:g", triageInstructions: "bar", triageModelLane: lane)
        }
        check("group drain: uniform lane runs that lane",
              ConversationManager.effectiveTriageLane(records: [rec("cheap-text"), rec("cheap-text")]) == "cheap-text"
              && ConversationManager.effectiveTriageLane(records: [rec("cheap-vision")]) == "cheap-vision")
        check("group drain: mixed lanes run inherit",
              ConversationManager.effectiveTriageLane(records: [rec("cheap-text"), rec("cheap-vision")]) == nil
              && ConversationManager.effectiveTriageLane(records: [rec("cheap-vision"), rec(nil)]) == nil
              && ConversationManager.effectiveTriageLane(records: []) == nil)

        // 10b. A lane change on a group member applies GROUP-WIDE (one model
        //      per drain — per-member divergence would just be overridden).
        let g1 = await service.createExternalTriggerReminder(
            prompt: "group member 1", deleteAfterFire: false,
            notifyMode: "subagent:lane-g", triageInstructions: "bar", triageModelLane: "cheap-text")
        let g2 = await service.createExternalTriggerReminder(
            prompt: "group member 2", deleteAfterFire: false,
            notifyMode: "subagent:lane-g", triageInstructions: "bar", triageModelLane: "cheap-text")
        _ = await service.updateTriageRouting(id: g1.id, notifyMode: nil, triageInstructions: nil, triageModelLane: "cheap-vision")
        let g1After = await service.reminder(withId: g1.id)?.triageModelLane
        let g2After = await service.reminder(withId: g2.id)?.triageModelLane
        check("group lane change applies to every member",
              g1After == "cheap-vision" && g2After == "cheap-vision")

        // 11. The Agent result reports which model actually served the run.
        var runResult = SubagentRunner.RunResult(
            sessionId: "s", isNewSession: true, finalMessage: "done", turnsUsed: 1,
            toolsCalled: [], filesTouched: [], spendUSD: 0, error: nil)
        runResult.modelUsed = "glm-5.3"
        check("run result surfaces model_used", runResult.asJSON().contains("\"model_used\""))

        // 12. Custom-provider lanes are namespaced by the FULL endpoint
        //     (host + hash): a different gateway — or the same host on a
        //     different port/path — has its own (empty) lane config, and the
        //     original returns with its URL.
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openAICompatible.rawValue)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: "https://opencode.ai/zen/go/v1")
        let ns = SubagentModelLanes.endpointNamespace(provider: .openAICompatible)
        check("endpoint namespace is host + hash", ns.hasPrefix("opencode.ai-") && ns.count == "opencode.ai-".count + 8)
        try SubagentModelLanes.setModel(.cheapText, model: "kimi-k2.6")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: "https://gateway.example.com/v1")
        check("other gateway starts unconfigured",
              SubagentModelLanes.resolve(hint: "cheap-text") == .unconfigured(.cheapText))
        try SubagentModelLanes.setModel(.cheapText, model: "some-other-model")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: "https://opencode.ai/zen/go/v1")
        check("original gateway's pick returns with its URL",
              SubagentModelLanes.resolve(hint: "cheap-text") == .lane(.cheapText, model: "kimi-k2.6"))
        // Same host, different port → different namespace (the ssh-tunnel /
        // multi-local-runtime case Codex flagged).
        try KeychainHelper.save(key: KeychainHelper.lmStudioBaseURLKey, value: "http://127.0.0.1:1234/v1")
        let nsPort1 = SubagentModelLanes.endpointNamespace(provider: .lmStudio)
        try KeychainHelper.save(key: KeychainHelper.lmStudioBaseURLKey, value: "http://127.0.0.1:11434/v1")
        let nsPort2 = SubagentModelLanes.endpointNamespace(provider: .lmStudio)
        check("same host on different ports gets distinct namespaces", nsPort1 != nsPort2)
        // Normalization: scheme/host are case-insensitive by spec and fold;
        // the path is case-sensitive and must stay distinguishing.
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: "https://host.example.com/API")
        let nsPathUpper = SubagentModelLanes.endpointNamespace(provider: .openAICompatible)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: "https://host.example.com/api")
        let nsPathLower = SubagentModelLanes.endpointNamespace(provider: .openAICompatible)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: "https://HOST.example.com/api")
        let nsHostUpper = SubagentModelLanes.endpointNamespace(provider: .openAICompatible)
        check("path case distinguishes endpoints, host case folds",
              nsPathUpper != nsPathLower && nsHostUpper == nsPathLower)

        // /subagents gating: the Agent + subagent_manage tools are present by
        // default and vanish when ada.subagentsEnabled is false. Uses the
        // test seam instead of the machine's real UserDefaults — a crash
        // mid-test can't leave real delegation preferences flipped.
        defer { AvailableTools.subagentsStoredFlagOverrideForTesting = nil }

        // Serializes every "Agent" mention across the full tool surface —
        // descriptions and parameter texts included — so a stale reference
        // to the removed tool anywhere in the schema fails the check.
        func agentMentions(_ tools: [ToolDefinition]) -> Bool {
            let encoder = JSONEncoder()
            let blob = tools
                .filter { $0.function.name != "Agent" && $0.function.name != "subagent_manage" }
                .compactMap { try? encoder.encode($0) }
                .map { String(decoding: $0, as: UTF8.self) }
                .joined()
            return blob.contains("Agent tool") || blob.contains("the Agent ")
        }

        AvailableTools.subagentsStoredFlagOverrideForTesting = { nil }
        let defaultTools = AvailableTools.all(includeWebSearch: false)
        let defaultNames = defaultTools.map { $0.function.name }
        check("subagent tools present with no stored flag (default on)",
              defaultNames.contains("Agent") && defaultNames.contains("subagent_manage"))
        check("Agent references present in descriptions when subagents on",
              agentMentions(defaultTools))

        AvailableTools.subagentsStoredFlagOverrideForTesting = { false }
        let offTools = AvailableTools.all(includeWebSearch: false)
        let offNames = offTools.map { $0.function.name }
        check("subagent tools removed when ada.subagentsEnabled=false",
              !offNames.contains("Agent") && !offNames.contains("subagent_manage"))
        check("no stale Agent references in any schema when subagents off",
              !agentMentions(offTools))

        AvailableTools.subagentsStoredFlagOverrideForTesting = { true }
        let onTools = AvailableTools.all(includeWebSearch: false)
        let onNames = onTools.map { $0.function.name }
        check("subagent tools restored when re-enabled",
              onNames.contains("Agent") && onNames.contains("subagent_manage"))
        check("Agent references restored when re-enabled",
              agentMentions(onTools))

        // Runtime watcher envelopes (not covered by the schema sweep): the
        // triage-session pointers in NOTIFY escalations and runaway-backstop
        // notes must stop recommending the Agent tool while subagents are
        // off, and must name the session either way.
        AvailableTools.subagentsStoredFlagOverrideForTesting = { true }
        let notifyOn = FireRecord.notifySessionHint(sessionId: "sess-1")
        let backstopOn = ConversationManager.backstopSessionNote(sessionId: "sess-1")
        check("envelopes recommend Agent-tool resume when subagents on",
              notifyOn.contains("resume it with the Agent tool")
              && backstopOn.contains("resume it with the Agent tool"))
        AvailableTools.subagentsStoredFlagOverrideForTesting = { false }
        let notifyOff = FireRecord.notifySessionHint(sessionId: "sess-1")
        let backstopOff = ConversationManager.backstopSessionNote(sessionId: "sess-1")
        check("envelopes stop recommending Agent resume when subagents off",
              !notifyOff.contains("resume it with the Agent tool")
              && !backstopOff.contains("resume it with the Agent tool")
              && notifyOff.contains("re-enables") && backstopOff.contains("re-enables"))
        check("envelopes still name the triage session in both states",
              notifyOn.contains("sess-1") && notifyOff.contains("sess-1")
              && backstopOn.contains("sess-1") && backstopOff.contains("sess-1"))

        print(failures == 0 ? "ALL LANE CHECKS PASSED" : "\(failures) LANE CHECK(S) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}
