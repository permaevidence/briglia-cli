import Foundation

/// Pre-release review fixes, continued: nothing GPT can see names a tool it
/// does not have (S2), and the relative-path hint only names a directory it
/// is certain of (L1).
extension GPTProfileSelftest {

    static let staleNames = ["edit_file", "write_file", "old_string"]
    static func staleIn(_ text: String) -> [String] { staleNames.filter { text.contains($0) } }

    // MARK: S2 — every GPT request body, every route

    static func staleNameTests(_ t: CPTest) async {
        // Tool lists, every combination, both forms.
        for editing in [EditingConfig.gptJSON, .gptFreeform] {
            for web in [true, false] {
                for deferred in [true, false] {
                    let found = staleIn(encoded(AvailableTools.all(includeWebSearch: web, hasDeferredMCPs: deferred, editing: editing)))
                    t.check("Z.11 GPT tool list names no tool GPT lacks (\(editing), web \(web), deferred \(deferred))", found.isEmpty, "\(found)")
                }
            }
        }
        // System prompts.
        let service = OpenRouterService()
        let root = URL(fileURLWithPath: t.dir("z11"))
        for editing in [EditingConfig.gptJSON, .gptFreeform] {
            let tools = AvailableTools.all(includeWebSearch: true, editing: editing)
            let prompt = await service.prepareConversation(messages: [Message(role: .user, content: "hi")], imagesDirectory: root, documentsDirectory: root,
                tools: tools, toolResultMessages: nil, calendarContext: nil, emailContext: nil, chunkSummaries: nil, totalChunkCount: 0,
                turnStartDate: Date(timeIntervalSince1970: 1_800_000_000), finalResponseInstruction: nil, tailSystemMessage: nil,
                tailUserMessage: nil, deferredMCPSummaries: nil, persona: nil, editing: editing).systemPrompt
            t.check("Z.11b GPT system prompt names no tool GPT lacks (\(editing))", staleIn(prompt).isEmpty, "\(staleIn(prompt))")
        }
        // GPT children: built-in types and a read-only child with bash.
        let parent = AvailableTools.all(includeWebSearch: true)
        for type in [SubagentTypes.generalPurpose, SubagentTypes.browse, SubagentTypes.watcherTriage] {
            let inventory = SubagentRunner.nativeToolInventory(parentTools: parent, type: type, editing: .gptJSON)
            t.check("Z.11c GPT child \(type.name): its tools name no tool GPT lacks", staleIn(encoded(inventory)).isEmpty, "\(staleIn(encoded(inventory)))")
        }
        let readOnly = SubagentType(name: "fixture-reader", description: "fixture", systemPromptSuffix: "", allowedToolNames: ["read_file", "bash"],
                                    defaultMaxTurns: 10, preferredModel: .inherit)
        let roBash = SubagentRunner.nativeToolInventory(parentTools: parent, type: readOnly, editing: .gptJSON).first { $0.function.name == "bash" }
        t.check("Z.11d a GPT child without apply_patch is not told to edit with it (review L6)",
                roBash.map { !$0.function.description.contains("apply_patch") && $0.function.description.contains(AvailableTools.gptReadOnlyNote) } == true)
        for variant in [AvailableTools.bashSubagentManaged, AvailableTools.bashForegroundOnly] {
            t.check("Z.11e subagent bash variants: read-only note without apply_patch, edit note with it",
                    !AvailableTools.gptVariant(variant, canPatch: false).function.description.contains("apply_patch")
                    && AvailableTools.gptVariant(variant, canPatch: true).function.description.contains(AvailableTools.gptReadNote))
        }
        // Real request bodies: Chat Completions (JSON), Responses (JSON and
        // freeform), the legacy ChatGPT body (built offline).
        guard let server = try? CaptureServer() else { t.check("Z.11 fixture server", false); return }
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)/v1"
        let human = Message(role: .user, content: "Please fix the typo in /Users/me/project/README.md")
        func send(_ label: String, _ ctx: ProviderExecutionContext, freeform: Bool) async -> Data? {
            GPTPatchRoute.freeformHostsOverrideForTesting = freeform ? ["127.0.0.1"] : []
            defer { GPTPatchRoute.freeformHostsOverrideForTesting = nil }
            let run = EditingRun.start(ctx)
            let tools = AvailableTools.all(includeWebSearch: true, editing: run.config)
            let before = server.completeRequests.count
            if ctx.wireProtocol == .responses { server.script([reply([doneText])]) }
            _ = try? await service.generateResponse(messages: [human], imagesDirectory: root, documentsDirectory: root, tools: tools,
                                                    toolResultMessages: nil, execution: ctx, lane: .main, editingRun: run)
            guard server.completeRequests.count > before else { return nil }
            return server.completeRequests.last?.body
        }
        let bodies: [(String, Data?)] = [
            ("Chat Completions (JSON)", await send("chat", chat("openai/gpt-6-luna", endpoint: base + "/chat/completions"), freeform: false)),
            ("Responses (JSON)", await send("rjson", responses("gpt-6-sol", base: base), freeform: false)),
            ("Responses (freeform)", await send("rff", responses("openai/gpt-6-luna", base: base), freeform: true)),
        ]
        for (label, body) in bodies {
            let text = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            t.check("Z.11f \(label): the whole GPT request body names no tool GPT lacks", !text.isEmpty && staleIn(text).isEmpty,
                    text.isEmpty ? "no body captured" : "\(staleIn(text))")
        }
        if let ffBody = bodies[2].1, let value = try? JSONDecoder().decode(JSONValue.self, from: ffBody),
           case .object(let object) = value, case .array(let input)? = object["input"] {
            var legacy = responses("gpt-6.1-sol", base: SubscriptionEndpoint.inference)
            legacy.subscriptionGeneration = "g1"
            let run = EditingRun.start(legacy)
            legacy.editing = run.config
            let tools = AvailableTools.all(includeWebSearch: true, editing: run.config)
            let request = try? ResponsesAdapter(context: legacy).request(input: input, tools: tools)
            let text = String(decoding: request?.httpBody ?? Data(), as: UTF8.self)
            t.check("Z.11g legacy ChatGPT (freeform): the request body names no tool GPT lacks",
                    run.config == .gptFreeform && !text.isEmpty && staleIn(text).isEmpty, "\(staleIn(text))")
        } else { t.check("Z.11g legacy ChatGPT body built", false) }
        // GPT-visible results the engine writes.
        let refusal = CodexPatch.placeholderRefusal(display: "/x", addedText: ["[REDACTED:K]"], placeholders: ["[REDACTED:K]"])?.text ?? ""
        let texts = [GPTPatchSettlement.notStartedText, CodexPatch.cancelledText, HarnessSecretStore.patchWholeFileRewriteRefusal,
                     HarnessSecretStore.patchDeleteOrMoveRefusal, refusal,
                     CodexPatch.SourceFile.DecodeError.invalidUTF8.description, CodexPatch.SourceFile.DecodeError.otherUnicode("UTF-16LE").description]
        t.check("Z.11h the engine's own result texts name no tool GPT lacks", !refusal.isEmpty && texts.allSatisfy { staleIn($0).isEmpty },
                texts.filter { !staleIn($0).isEmpty }.joined(separator: " | "))
    }

    // MARK: L1 — the relative-path hint

    static func hintTests(_ t: CPTest) async {
        let table: [(String, String?, String?)] = [
            ("ls", "/a", "/a"), ("ls", nil, nil), ("cd /b && ls", "/a", "/b"), ("cd '/b c' && ls", nil, "/b c"),
            ("cd /b && cd c && ls", nil, nil), ("cd rel && ls", "/a", nil), ("make; cd x", "/a", nil),
            ("(cd /x && ls)", "/a", nil), ("ls && cd /tmp", "/a", nil), ("pushd /x && ls", "/a", nil),
            ("echo cd", "/a", "/a"), ("git commit -m 'fix cd handling'", "/a", "/a"), ("x=$(cd /y; pwd)", "/a", nil),
            ("if true; then cd /z; fi", "/a", nil), ("cd", "/a", nil), ("ls\ncd /q", "/a", nil),
        ]
        for (command, workdir, expected) in table {
            let got = GPTShellIntercept.workdirAfter(command: command, workdir: workdir)
            t.check("Z.12 working directory after `\(command.replacingOccurrences(of: "\n", with: "⏎"))` (workdir \(workdir ?? "none")) is \(expected ?? "unknown")",
                    got == expected, "\(got ?? "nil")")
        }
        let executor = ToolExecutor()
        let d = t.dir("z12"), e = t.dir("z12e")
        let relative = "*** Begin Patch\n*** Add File: rel.txt\n+x\n*** End Patch"
        func hint() async -> String {
            let r = await exec(executor, call("apply_patch", ["input": relative], editing: .gptJSON))
            return r.content
        }
        _ = await exec(executor, call("bash", ["command": "true", "workdir": d], editing: .gptJSON))
        let h1 = await hint()
        t.check("Z.12b after a bash command with an absolute workdir the hint names it", h1.contains("ran in \(d);") && h1.contains("\(d)/rel.txt"), h1)
        _ = await exec(executor, call("bash", ["command": "cd \(e) && true"], editing: .gptJSON))
        let h2 = await hint()
        t.check("Z.12c after `cd <abs> && …` the hint names that directory, not the older workdir (review L1)",
                h2.contains("ran in \(e);") && !h2.contains(d), h2)
        _ = await exec(executor, call("bash", ["command": "cd sub && true", "workdir": d], editing: .gptJSON))
        let h3 = await hint()
        t.check("Z.12d after a relative `cd` no directory is suggested", !h3.contains("ran in") && h3.contains("is not an absolute path"), h3)
        _ = await exec(executor, call("bash", ["command": "true", "workdir": d], editing: .gptJSON))
        _ = await exec(executor, call("bash", ["command": "true"], editing: .gptJSON))
        let h4 = await hint()
        t.check("Z.12e after a command without a workdir no directory is suggested", !h4.contains("ran in"), h4)
        _ = await exec(executor, call("bash", ["command": "true", "workdir": d], editing: .gptJSON))
        await executor.setGPTSettlementScope("next-run-\(UUID().uuidString.prefix(6))")
        let h5 = await hint()
        t.check("Z.12f a new run forgets the previous run's directory", !h5.contains("ran in"), h5)
        t.check("Z.12g nothing was created from a relative path", !t.exists(d + "/rel.txt") && !t.exists(e + "/rel.txt"))
    }
}
