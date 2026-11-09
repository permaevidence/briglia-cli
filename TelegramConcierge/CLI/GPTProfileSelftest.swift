import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// GPT apply_patch, stage S2 (GPT_APPLY_PATCH_PLAN §3–§12 as amended by A1,
/// §14.6–14.10b): the model matcher, editing-configuration resolution, the
/// `.gpt` tool surface and prompt, the run lease, dispatch, typed outcome,
/// ledger, shell reads, heredoc interception, the freeform wire form on the
/// verified route and the §5.6 fallback.
///
/// Isolation: re-executes itself in a private scratch home (same pattern as
/// `__codex-patch-selftest`), so no real install's state or preferences are touched.
struct GPTProfileSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__gpt-profile-selftest",
        abstract: "Internal: verify the GPT editing profile (apply_patch for GPT models).",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var fixtures: String?
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-gptprofile-selftest"
    static let rootPrefix = "briglia-gpt-profile-"

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let fixtureDir = fixtures ?? CodexPatchSelftest.defaultFixtures
        guard child else { try Self.reexecIsolated(fixtures: fixtureDir, only: only); return }
        UserDefaults.standard.setVolatileDomain([
            "ada.applyPatchEnabled": false, "ada.shortcutsEnabled": false,
            KeychainHelper.serviceKeysMetadataDefaultsKey: Data("[]".utf8)
        ], forName: UserDefaults.argumentDomain)
        let t = CPTest(fixtures: fixtureDir, only: only.map { Set($0.split(separator: ",").map(String.init)) })
        await Self.battery(t)
        print("GPT profile selftest: \(t.total - t.failures)/\(t.total) passed")
        if t.failures > 0 { throw ExitCode(1) }
    }

    static func reexecIsolated(fixtures: String, only: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("BRIGLIA_") || key.hasPrefix("ADA_") { env.removeValue(forKey: key) }
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["XDG_STATE_HOME"] = home + "/.local/state"
        env["XDG_CACHE_HOME"] = home + "/.cache"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__gpt-profile-selftest", "--child", "--fixtures", fixtures] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        if TestPrefsDomains.candidatePaths(linkName).contains(where: { fm.fileExists(atPath: $0) }) {
            TestPrefsDomains.purge(linkName)
            TestPrefsDomains.finalSweep()
        }
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }

    static func battery(_ t: CPTest) async {
        GPTPatchSwitch.storedOverrideForTesting = { nil }
        if t.runs("M") { matcherTests(t) }
        if t.runs("R") { resolutionTests(t) }
        if t.runs("U") { surfaceTests(t) }
        if t.runs("P") { await promptTests(t) }
        if t.runs("L") { await leaseTests(t) }
        if t.runs("D") { await dispatchTests(t); claimAndClassificationTests(t) }
        if t.runs("I") { await interceptTests(t) }
        if t.runs("K") { await ledgerTests(t) }
        if t.runs("H") { shellReadTests(t) }
        if t.runs("W") { await wireTests(t) }
        if t.runs("X") { await transitionTests(t) }
        GPTPatchSwitch.storedOverrideForTesting = nil
        GPTPatchRoute.freeformHostsOverrideForTesting = nil
        GPTPatchFormStore.fileURLOverrideForTesting = nil
    }

    // MARK: Contexts

    static func chat(_ model: String, provider: LLMProvider = .openRouter, endpoint: String = "https://openrouter.ai/api/v1") -> ProviderExecutionContext {
        ProviderExecutionContext(provider: provider, model: model, endpoint: endpoint, authorization: "Bearer synthetic",
            affinityKey: "synthetic", lane: .main, provenance: model, providerPreferences: nil, reasoning: nil,
            reasoningEffort: nil, thinkingType: nil, useReasoningContent: false, textOnly: false,
            anthropicCacheControl: false, renderPDFAsImages: true)
    }

    static func responses(_ model: String, base: String) -> ProviderExecutionContext {
        ProviderExecutionContext.responsesAPI(baseURL: base, key: "synthetic-key", model: model, lane: .main)
    }

    // MARK: M — matcher (amendment A1)

    static func matcherTests(_ t: CPTest) {
        let positives = ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.1", "gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5-codex",
                         "gpt-5.4", "gpt-5.5", "gpt-5.6", "gpt-5.6-luna", "gpt-5.6-sol-2026-08-01", "gpt-5-pro",
                         "gpt-6-sol", "gpt-6-luna", "gpt-6-astra", "gpt-6.1-sol", "gpt-7", "gpt-7.2-nova-mini", "gpt-10",
                         "gpt-12.3-codex-2027-01-01",
                         "openai/gpt-5.6-luna", "openai/gpt-6-luna:nitro", "openai/gpt-5:online", "opencode/gpt-5.1-codex",
                         "azure/openai/gpt-6-sol", "GPT-6-SOL", "  gpt-6-luna  ", "OpenAI/GPT-5.6-Luna"]
        for id in positives { t.check("M matcher accepts \(id)", GPTModelMatcher.isGPT(id)) }
        let negatives = ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4", "gpt-4-turbo", "gpt-3.5-turbo",
                         "chatgpt-4o-latest", "chatgpt-5", "gpt-oss-120b", "gpt-oss-20b", "openai/gpt-oss-120b",
                         "gpt-image-2", "gpt-image-1", "gpt-realtime", "gpt-4o-mini-tts", "gpt-audio",
                         "o3", "o4-mini", "o3-pro", "claude-sonnet-4", "anthropic/claude-opus-5", "deepseek/deepseek-v4.1-flash-1017",
                         "kimi-k3", "glm-5.3", "my-gpt-6-finetune", "gpt6", "gpt-6o", "gpt-5x", "xgpt-5", "gpt-", "gpt--5",
                         "gpt-5_1", "openai/gpt-5/extra", "", "gpt-99999", "local-model", "custom-model"]
        for id in negatives { t.check("M matcher refuses \(id.isEmpty ? "(empty)" : id)", !GPTModelMatcher.isGPT(id)) }
        t.check("M model-name part after the last provider prefix", GPTModelMatcher.modelName("azure/openai/GPT-6-Sol") == "gpt-6-sol")
        // Drift: every model the ChatGPT subscription offers is matched.
        let choices = ResponsesAdapter.subscriptionModelChoices.map(\.id)
        t.check("M every subscription model choice is a GPT model (drift)",
                !choices.isEmpty && choices.allSatisfy(GPTModelMatcher.isGPT), "\(choices.filter { !GPTModelMatcher.isGPT($0) })")
    }

    // MARK: R — resolution (§3.1, §5.1 as amended)

    static func resolutionTests(_ t: CPTest) {
        let none: (String) -> Bool = { _ in false }
        func resolve(_ c: ProviderExecutionContext, on: Bool = true, rejected: @escaping (String) -> Bool = { _ in false }) -> EditingConfig {
            EditingConfig.resolve(c, switchOn: on, rejected: rejected)
        }
        // Every provider and route; freeform only on OpenRouter's Responses endpoint.
        t.check("R OpenRouter chat GPT → JSON", resolve(chat("openai/gpt-6-luna")) == .gptJSON)
        t.check("R OpenRouter Responses server GPT → freeform", resolve(responses("openai/gpt-6-luna", base: "https://openrouter.ai/api/v1")) == .gptFreeform)
        t.check("R OpenRouter Responses host match ignores case", resolve(responses("openai/gpt-6-luna", base: "https://OpenRouter.ai/api/v1")) == .gptFreeform)
        t.check("R OpenAI key (api.openai.com Responses) → JSON", resolve(responses("gpt-6-sol", base: "https://api.openai.com/v1")) == .gptJSON)
        t.check("R OpenCode Responses → JSON", resolve(responses("gpt-5.6-luna", base: "https://opencode.ai/zen/go/v1")) == .gptJSON)
        t.check("R custom endpoint Responses → JSON", resolve(responses("gpt-6-sol", base: "https://llm.example.com/v1")) == .gptJSON)
        t.check("R custom endpoint chat → JSON", resolve(chat("gpt-6-sol", provider: .openAICompatible, endpoint: "https://llm.example.com/v1")) == .gptJSON)
        t.check("R OpenRouter host spoof in a path is not OpenRouter",
                resolve(responses("gpt-6-sol", base: "https://evil.example.com/openrouter.ai/v1")) == .gptJSON)
        var legacy = responses("gpt-6.1-sol", base: "https://openrouter.ai/api/v1")
        legacy.subscriptionGeneration = "g1"
        t.check("R legacy ChatGPT route → JSON (even on an OpenRouter-looking endpoint)", resolve(legacy) == .gptJSON)
        var siwc = responses("gpt-6.1-sol", base: "https://openrouter.ai/api/v1")
        siwc.siwcFailure = "fixture"
        t.check("R Sign in with ChatGPT route → JSON", resolve(siwc) == .gptJSON)
        t.check("R non-GPT model on the freeform route → standard", resolve(responses("deepseek/deepseek-v4.1-flash", base: "https://openrouter.ai/api/v1")) == .standard)
        t.check("R gpt-oss → standard", resolve(chat("openai/gpt-oss-120b")) == .standard)
        t.check("R unknown model → standard", resolve(chat("vendor/mystery-1")) == .standard)
        // Switch and environment (P29, P30).
        t.check("R switch off → standard on every route",
                resolve(chat("openai/gpt-6-luna"), on: false) == .standard
                && resolve(responses("openai/gpt-6-luna", base: "https://openrouter.ai/api/v1"), on: false) == .standard)
        GPTPatchSwitch.storedOverrideForTesting = { false }
        t.check("R stored off read by the switch", !GPTPatchSwitch.isOn && EditingConfig.resolveAtRunStart(chat("openai/gpt-6-luna")) == .standard)
        GPTPatchSwitch.storedOverrideForTesting = { nil }
        t.check("R absent switch = on", GPTPatchSwitch.isOn)
        setenv(GPTPatchSwitch.environmentKey, "0", 1)
        t.check("R BRIGLIA_GPT_PATCH=0 forces off", !GPTPatchSwitch.isOn && EditingConfig.resolveAtRunStart(chat("openai/gpt-6-luna")) == .standard)
        setenv(GPTPatchSwitch.environmentKey, "1", 1)
        t.check("R BRIGLIA_GPT_PATCH=1 leaves it on", GPTPatchSwitch.isOn)
        unsetenv(GPTPatchSwitch.environmentKey)
        // Recorded rejection (§5.6): only its own route key, only this version.
        let store = URL(fileURLWithPath: t.dir("formstore")).appendingPathComponent("gpt-patch-form.json")
        GPTPatchFormStore.fileURLOverrideForTesting = store
        GPTPatchFormStore.shared.resetCacheForTesting()
        let freeformCtx = responses("openai/gpt-6-luna", base: "https://openrouter.ai/api/v1")
        let otherModel = responses("openai/gpt-6-sol", base: "https://openrouter.ai/api/v1")
        t.check("R first rejection is recorded once", GPTPatchFormStore.shared.recordRejection(GPTPatchRoute.key(freeformCtx))
                && !GPTPatchFormStore.shared.recordRejection(GPTPatchRoute.key(freeformCtx)))
        t.check("R a recorded route starts in JSON", EditingConfig.resolveAtRunStart(freeformCtx) == .gptJSON)
        t.check("R another model's route is unaffected", EditingConfig.resolveAtRunStart(otherModel) == .gptFreeform)
        t.check("R form file is 0600", t.mode(store.path).map { $0 & 0o777 } == 0o600)
        if let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "rejections": [GPTPatchRoute.key(freeformCtx): "0.0.1-older"]]) {
            try? data.write(to: store)
        }
        GPTPatchFormStore.shared.resetCacheForTesting()
        t.check("R a record from another Briglia version retries freeform once", EditingConfig.resolveAtRunStart(freeformCtx) == .gptFreeform)
        try? GPTPatchFormStore.shared.deleteAll()
        t.check("R deleteAll removes the file (P31 /deleteuserdata)", !t.exists(store.path))
        _ = none
    }

    // MARK: U — tool surface (§4.1–4.3, I1)

    static func encoded(_ tools: [ToolDefinition]) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(tools)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// SHA-256 of today's standard `filesystemTools` (sorted-key JSON,
    /// legacy preference off), recorded at wip/gpt-patch on top of v0.2.70.
    static let standardFileToolsSHA256 = "8624edfa6a98173b49e4f230706270361de5c13aee111a8264adc7c7025676a7"

    static func surfaceTests(_ t: CPTest) {
        for web in [true, false] {
            for deferred in [true, false] {
                let standard = AvailableTools.all(includeWebSearch: web, hasDeferredMCPs: deferred)
                t.check("U .standard list is byte-identical (web \(web), deferred \(deferred)) (I1, P13/P14)",
                        encoded(AvailableTools.all(includeWebSearch: web, hasDeferredMCPs: deferred, editing: .standard)) == encoded(standard))
                let gpt = AvailableTools.all(includeWebSearch: web, hasDeferredMCPs: deferred, editing: .gptJSON)
                let names = gpt.map(\.function.name)
                t.check("U .gpt list has no edit_file/write_file and exactly one apply_patch (web \(web))",
                        !names.contains("edit_file") && !names.contains("write_file") && names.filter { $0 == "apply_patch" }.count == 1)
                let standardNames = standard.map(\.function.name)
                let expected = standardNames.compactMap { n -> String? in
                    n == "write_file" ? "apply_patch" : (n == "edit_file" ? nil : n)
                }
                t.check("U apply_patch takes write_file's slot; every other tool keeps its place (web \(web))", names == expected, "\(names)")
                let patch = gpt.first { $0.function.name == "apply_patch" }
                t.check("U GPT apply_patch has one required string `input`",
                        patch?.function.parameters.required == ["input"] && patch?.function.parameters.properties.keys.sorted() == ["input"])
            }
        }
        // I1/P14: the standard file-tool definitions are frozen (any byte
        // change to a standard description or schema fails here; the
        // chat-wire fixtures hold the full requests).
        let frozen = CodexPatchFS.sha256(Data(encoded(AvailableTools.filesystemTools).utf8))
        t.check("U standard file-tool definitions match the frozen hash (I1, P14)", frozen == standardFileToolsSHA256, frozen)
        // Legacy preference on: .standard keeps the legacy patch_text tool;
        // .gpt ignores it (D7).
        UserDefaults.standard.setVolatileDomain(["ada.applyPatchEnabled": true, "ada.shortcutsEnabled": false,
            KeychainHelper.serviceKeysMetadataDefaultsKey: Data("[]".utf8)], forName: UserDefaults.argumentDomain)
        let legacyStandard = AvailableTools.all(includeWebSearch: true)
        let legacyGPT = AvailableTools.all(includeWebSearch: true, editing: .gptJSON)
        t.check("U legacy preference: .standard exposes the patch_text apply_patch",
                legacyStandard.first { $0.function.name == "apply_patch" }?.function.parameters.required == ["patch_text"])
        t.check("U legacy preference: .gpt exposes only the GPT apply_patch",
                legacyGPT.filter { $0.function.name == "apply_patch" }.count == 1
                && legacyGPT.first { $0.function.name == "apply_patch" }?.function.parameters.required == ["input"])
        UserDefaults.standard.setVolatileDomain(["ada.applyPatchEnabled": false, "ada.shortcutsEnabled": false,
            KeychainHelper.serviceKeysMetadataDefaultsKey: Data("[]".utf8)], forName: UserDefaults.argumentDomain)
        // §4.3 rewrites: each standard text occurs exactly once and is gone.
        let standardByName = Dictionary(AvailableTools.all(includeWebSearch: true).map { ($0.function.name, $0) }, uniquingKeysWith: { a, _ in a })
        let bashVariants = [AvailableTools.bash, AvailableTools.bashSubagentManaged, AvailableTools.bashForegroundOnly]
        for rewrite in AvailableTools.gptDescriptionRewrites {
            let sources: [ToolDefinition] = rewrite.tool == "bash"
                ? bashVariants.filter { $0.function.description.contains(rewrite.from) }
                : [standardByName[rewrite.tool]].compactMap { $0 }
            let once = sources.count == 1 && sources[0].function.description.components(separatedBy: rewrite.from).count == 2
            let variant = sources.first.map(AvailableTools.gptVariant)
            t.check("U rewrite of \(rewrite.tool) matches its standard text exactly once and replaces it: \(rewrite.from.prefix(40))…",
                    once && variant.map { !$0.function.description.contains(rewrite.from) && $0.function.description.contains(rewrite.to) } == true)
        }
        for variant in bashVariants {
            t.check("U every bash variant gets the GPT note", AvailableTools.gptVariant(variant).function.description.contains(AvailableTools.gptReadNote))
        }
        t.check("U GPT read_file no longer mentions edit_file",
                !(AvailableTools.applyEditing([AvailableTools.readFile], .gptJSON).first?.function.description.contains("edit_file") ?? true))
        // JSON description = vendored Codex text with exactly the documented substitutions.
        let specPath = t.fixtures + "/json-spec/apply_patch_spec_cf941ede.rs"
        if let source = try? String(contentsOfFile: specPath, encoding: .utf8),
           let start = source.range(of: "APPLY_PATCH_JSON_TOOL_DESCRIPTION: &str = r#\""),
           let end = source.range(of: "\"#;", range: start.upperBound..<source.endIndex) {
            var text = String(source[start.upperBound..<end.lowerBound])
            for (a, b) in AvailableTools.gptApplyPatchJSONSubstitutions { text = text.replacingOccurrences(of: a, with: b) }
            t.check("U JSON description = vendored cf941ede text + documented substitutions only",
                    text == AvailableTools.gptApplyPatchJSONDescription)
            t.check("U JSON description never says paths are relative", !AvailableTools.gptApplyPatchJSONDescription.contains("relative, NEVER ABSOLUTE"))
        } else { t.check("U vendored JSON spec readable", false) }
        let grammarFile = t.fixtures + "/pinned/assets/apply_patch.lark"
        let vendored = (try? Data(contentsOf: URL(fileURLWithPath: grammarFile))).map(CodexPatchFS.sha256)
        t.check("U grammar = vendored apply_patch.lark byte for byte (P32)",
                vendored == GPTFreeform.grammarSHA256 && CodexPatchFS.sha256(Data(GPTFreeform.grammar.utf8)) == GPTFreeform.grammarSHA256)
        t.check("U grammar carries no harness marker", !GPTFreeform.grammar.contains(MarkerNeutralizer.reservedPrefix))
        // Subagent inventories and whitelists (§3.3).
        func custom(_ whitelist: Set<String>?) -> SubagentType {
            SubagentType(name: "fixture-agent", description: "fixture", systemPromptSuffix: "", allowedToolNames: whitelist,
                         defaultMaxTurns: 10, preferredModel: .inherit)
        }
        let parent = AvailableTools.all(includeWebSearch: true)
        func inv(_ w: Set<String>?, _ e: EditingConfig) -> [String] {
            SubagentRunner.nativeToolInventory(parentTools: parent, type: custom(w), editing: e).map(\.function.name)
        }
        t.check("U standard child inventory unchanged by the editing parameter",
                encoded(SubagentRunner.nativeToolInventory(parentTools: parent, type: custom(nil)))
                == encoded(SubagentRunner.nativeToolInventory(parentTools: parent, type: custom(nil), editing: .standard)))
        t.check("U GPT child (no whitelist) gets apply_patch, no edit_file/write_file",
                inv(nil, .gptJSON).contains("apply_patch") && !inv(nil, .gptJSON).contains("edit_file"))
        t.check("U GPT child whitelist naming edit_file grants apply_patch", inv(["read_file", "edit_file"], .gptJSON) == ["read_file", "apply_patch"])
        t.check("U GPT child whitelist naming apply_patch grants it", inv(["apply_patch"], .gptJSON) == ["apply_patch"])
        t.check("U GPT child whitelist without edit tools gets none", inv(["read_file", "grep"], .gptJSON) == ["read_file", "grep"])
        t.check("U standard child whitelist naming apply_patch: unchanged (legacy off → none)", inv(["apply_patch"], .standard) == [])
        t.check("U Web researcher inventory unaffected",
                encoded(SubagentRunner.nativeToolInventory(parentTools: parent, type: SubagentTypes.webResearcher, editing: .gptJSON))
                == encoded(SubagentRunner.nativeToolInventory(parentTools: parent, type: SubagentTypes.webResearcher)))
    }

    // MARK: P — prompt (§4.4)

    static func promptTests(_ t: CPTest) async {
        let oldBullet = "- Use dedicated filesystem tools for code work; prefer `edit_file` (batched edits) for code edits; when a task requires renaming or deleting files, use bash and prefer git mv / git rm inside repos so changes stay recoverable).\n"
        t.check("P standard bullet is byte-identical to the previous line",
                OpenRouterService.editingBullets(editing: .standard, tools: AvailableTools.all(includeWebSearch: true)) == oldBullet.replacingOccurrences(of: "recoverable).", with: "recoverable."))
        let gptTools = AvailableTools.all(includeWebSearch: true, editing: .gptJSON)
        let json = OpenRouterService.editingBullets(editing: .gptJSON, tools: gptTools)
        let freeform = OpenRouterService.editingBullets(editing: .gptFreeform, tools: gptTools)
        t.check("P GPT JSON bullet: apply_patch, `input`, absolute paths, no edit_file",
                json.contains("Edit files with `apply_patch`") && json.contains("Put the whole patch in the `input` string.")
                && json.contains("Paths must be absolute") && !json.contains("edit_file"))
        t.check("P GPT freeform bullet says FREEFORM", freeform.contains("It is a FREEFORM tool") && !freeform.contains("`input` string"))
        t.check("P GPT run without apply_patch in the list gets neither bullet",
                OpenRouterService.editingBullets(editing: .gptJSON, tools: [AvailableTools.readFile]) == "")
        let service = OpenRouterService()
        let base = URL(fileURLWithPath: t.dir("prompt"))
        func prompt(_ e: EditingConfig, _ tools: [ToolDefinition]) async -> String {
            await service.prepareConversation(messages: [Message(role: .user, content: "hi")], imagesDirectory: base, documentsDirectory: base,
                tools: tools, toolResultMessages: nil, calendarContext: nil, emailContext: nil, chunkSummaries: nil, totalChunkCount: 0,
                turnStartDate: Date(timeIntervalSince1970: 1_800_000_000), finalResponseInstruction: nil, tailSystemMessage: nil,
                tailUserMessage: nil, deferredMCPSummaries: nil, persona: nil, editing: e).systemPrompt
        }
        let standardTools = AvailableTools.all(includeWebSearch: true)
        let standardPrompt = await prompt(.standard, standardTools)
        t.check("P standard system prompt carries the old bullet", standardPrompt.contains(oldBullet.replacingOccurrences(of: "recoverable).", with: "recoverable.")))
        let gptPrompt = await prompt(.gptJSON, gptTools)
        t.check("P GPT system prompt: no `edit_file` anywhere, apply_patch bullet present", !gptPrompt.contains("`edit_file`") && gptPrompt.contains("Edit files with `apply_patch`"))
        t.check("P GPT and standard prompts differ only in the bullet",
                gptPrompt.replacingOccurrences(of: json, with: "") == standardPrompt.replacingOccurrences(of: OpenRouterService.standardEditingBullet(), with: ""))
        t.check("P multi-assistant GPT section names only apply_patch",
                MultiAssistantHooks.promptSectionGPT != MultiAssistantHooks.promptSection
                && !MultiAssistantHooks.promptSectionGPT.contains("write_file") && MultiAssistantHooks.promptSectionGPT.contains("with apply_patch"))
    }

    // MARK: L — run lease (§3.2 F1, §5.6)

    static func leaseTests(_ t: CPTest) async {
        let gptChat = chat("openai/gpt-6-luna")
        let other = chat("deepseek/deepseek-v4.1-flash-1017")
        let run = EditingRun(context: gptChat, config: EditingConfig.resolve(gptChat, switchOn: true, rejected: { _ in false }), switchOn: true)
        t.check("L GPT run: same-config fresh request is used (today's behaviour)",
                run.admit(fresh: gptChat).model == "openai/gpt-6-luna" && run.admit(fresh: gptChat).editing == .gptJSON)
        let crossed = run.admit(fresh: other)
        t.check("L GPT run: a mid-run switch to a non-GPT model keeps the run's model and surface (P43)",
                crossed.model == "openai/gpt-6-luna" && crossed.editing == .gptJSON)
        let standardRun = EditingRun(context: other, config: .standard, switchOn: true)
        let toGPT = standardRun.admit(fresh: gptChat)
        t.check("L standard run: a mid-run switch to a GPT model keeps the standard model and surface",
                toGPT.model == "deepseek/deepseek-v4.1-flash-1017" && toGPT.editing == .standard)
        let otherStandard = chat("moonshotai/kimi-k3")
        t.check("L standard → standard mid-run change applies (baseline behaviour)",
                standardRun.admit(fresh: otherStandard).model == "moonshotai/kimi-k3")
        let offRun = EditingRun(context: gptChat, config: .standard, switchOn: false)
        t.check("L switch captured off at run start: GPT fresh stays compatible",
                offRun.admit(fresh: gptChat).editing == .standard && offRun.admit(fresh: gptChat).model == "openai/gpt-6-luna")
        GPTPatchSwitch.storedOverrideForTesting = { false }
        t.check("L a pending switch change never alters a running lease", run.admit(fresh: gptChat).editing == .gptJSON)
        GPTPatchSwitch.storedOverrideForTesting = { nil }
        let freeformCtx = responses("openai/gpt-6-luna", base: "https://openrouter.ai/api/v1")
        let freeRun = EditingRun(context: freeformCtx, config: .gptFreeform, switchOn: true)
        t.check("L stamped context carries the run's config", freeRun.stamped(freeformCtx).editing == .gptFreeform)
        t.check("L transition is monotonic: once (P19 precondition)", freeRun.transitionToJSON() && !freeRun.transitionToJSON())
        t.check("L after the transition the run is JSON and stays JSON", freeRun.config == .gptJSON && freeRun.stamped(freeformCtx).editing == .gptJSON
                && freeRun.admit(fresh: freeformCtx).editing == .gptJSON)
        t.check("L a JSON run never transitions", !run.transitionToJSON() && run.config == .gptJSON)
        // Codex S2 R3: an explicit context never bypasses the compatibility check.
        let claude = chat("anthropic/claude-sonnet-4")
        t.check("L an explicit cross-profile context is replaced by the run's own (Codex S2 R3)",
                run.admitExplicit(claude).model == "openai/gpt-6-luna" && run.admitExplicit(claude).editing == .gptJSON)
        t.check("L an explicit compatible context is used and stamped",
                run.admitExplicit(gptChat).model == "openai/gpt-6-luna" && run.admitExplicit(gptChat).editing == .gptJSON)
        let toResponses = responses("deepseek/deepseek-v4.1-flash", base: "https://openrouter.ai/api/v1")
        t.check("L a Chat-to-Responses change to a non-GPT model keeps the run's chat context",
                run.admit(fresh: toResponses).model == "openai/gpt-6-luna" && run.admit(fresh: toResponses).wireProtocol == .chatCompletions)
        t.check("L standard run: an explicit GPT context is replaced by the run's own",
                !GPTModelMatcher.isGPT(standardRun.admitExplicit(gptChat).model) && standardRun.admitExplicit(gptChat).editing == .standard)
        // Codex S2 R4: the settlement registry is scoped and retains outcomes.
        let reg = GPTPatchSettlement()
        let applied = GPTPatchSettlement.Settled(text: "Success.", outcome: .init(status: .applied, changed: ["/old"]))
        reg.begin(scope: "run-A", callID: "reused"); reg.finish(scope: "run-A", callID: "reused", applied)
        reg.begin(scope: "run-A", callID: "reused")
        t.check("L a reused call id: the new call is running and the old outcome is gone (R4)",
                reg.isCommitting(scope: "run-A", callID: "reused") && reg.outcome(scope: "run-A", callID: "reused") == nil)
        reg.finish(scope: "run-A", callID: "reused", applied)
        reg.begin(scope: "run-B", callID: "reused")
        t.check("L the same call id in another scope never collides (R4)",
                reg.outcome(scope: "run-A", callID: "reused") == applied.outcome && reg.isCommitting(scope: "run-B", callID: "reused")
                && !reg.isCommitting(scope: "run-A", callID: "reused"))
        for i in 0..<300 { reg.begin(scope: "run-C", callID: "c\(i)"); reg.finish(scope: "run-C", callID: "c\(i)", applied) }
        t.check("L hundreds of outcomes in one scope never drop another scope's (R4)",
                reg.outcome(scope: "run-A", callID: "reused") == applied.outcome && reg.outcome(scope: "run-C", callID: "c299") == applied.outcome)
        // Codex S2 round 2: a pinned (owed) scope is never evicted; only
        // released scopes are bounded; the last release retires a scope.
        reg.pin(scope: "owed")
        reg.begin(scope: "owed", callID: "p"); reg.finish(scope: "owed", callID: "p", applied)
        for i in 0..<(GPTPatchSettlement.retainedScopes + 4) { reg.begin(scope: "old-\(i)", callID: "x"); reg.finish(scope: "old-\(i)", callID: "x", applied) }
        t.check("L an unconsumed (pinned) scope survives any number of other scopes (R4 round 2)",
                reg.outcome(scope: "owed", callID: "p") == applied.outcome && reg.isCommitting(scope: "run-B", callID: "reused"))
        t.check("L released scopes beyond the bound are evicted oldest first",
                reg.outcome(scope: "old-0", callID: "x") == nil && reg.outcome(scope: "old-\(GPTPatchSettlement.retainedScopes + 3)", callID: "x") != nil)
        reg.pin(scope: "owed")
        reg.unpin(scope: "owed")
        t.check("L a scope with another consumer pin is kept", reg.outcome(scope: "owed", callID: "p") == applied.outcome)
        reg.unpin(scope: "owed")
        t.check("L the last release retires the scope", reg.outcome(scope: "owed", callID: "p") == nil)
        let settledOwed = await reg.settle(scope: "owed", callIDs: ["p"])
        t.check("L settle after retirement finds nothing (consumed)", settledOwed.isEmpty)
        t.check("L the stamp copies the producing context's editing",
                {
                    let response = LLMResponse.toolCalls(assistantMessage: AssistantToolCallMessage(content: "", toolCalls: []),
                        calls: [ToolCall(id: "c1", type: "function", function: .init(name: "apply_patch", arguments: "{}"))],
                        promptTokens: nil, completionTokens: nil, spendUSD: nil)
                    if case .toolCalls(_, let calls, _, _, _) = ToolCallRouting.stamp(response, setup: .otherProvider, editing: .gptFreeform) {
                        return calls.first?.editing == .gptFreeform
                    }
                    return false
                }())
    }
}
