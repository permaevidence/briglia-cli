import Foundation

/// R2 rows (WEB_SUBAGENT_PLAN §4.9 + §16, 2026-09-17): default ON with the
/// legacy implementation retained, the reply-policy line for "find" requests,
/// the researcher's find-task bullet, and the role-derived /status labels.
/// Its own file so no selftest function grows past the Linux frontend's
/// memory budget (feedback_linux_selftest_size_split).
extension WebSubagentSelftest {
    static func runR2Groups(_ h: Harness) async throws {
        let state = h.state, images = h.images, documents = h.documents, service = h.service
        func check(_ name: String, _ value: Bool, _ detail: String = "") { h.check(name, value, detail) }
        func toolNames(_ tools: [ToolDefinition]) -> [String] { h.toolNames(tools) }
        func toolJSON(_ tools: [ToolDefinition]) throws -> Data { try h.toolJSON(tools) }
        func agentArguments(_ arguments: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)
        }
        func messagingPrompt(tools: [ToolDefinition]?) async -> String {
            await service.prepareConversation(messages: [Message(role: .user, content: "hello", timestamp: state.clock)], imagesDirectory: images, documentsDirectory: documents,
                tools: tools, toolResultMessages: nil, calendarContext: nil, emailContext: nil, chunkSummaries: nil, totalChunkCount: 0,
                turnStartDate: state.clock, finalResponseInstruction: nil, tailSystemMessage: nil, tailUserMessage: nil, deferredMCPSummaries: nil, promptStyle: .messaging).systemPrompt
        }
        func occurrences(_ text: String, _ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }

        print("17. R2: default on, legacy retained, find-task reply policy, /status labels")
        do {
            // ---- §4.9: the stored flag's absence now means ON; both seams nil = a fresh install.
            state.subagentsFlag = nil; state.webFlag = nil
            check("17.1 fresh install (no stored flags): the Web switch is ON and active; an explicit false still wins",
                  AvailableTools.webSubagentEnabled && AvailableTools.webSubagentActive
                  && { state.webFlag = false; defer { state.webFlag = nil }; return !AvailableTools.webSubagentEnabled && !AvailableTools.webSubagentActive }()
                  && { state.subagentsFlag = false; defer { state.subagentsFlag = nil }; return AvailableTools.webSubagentEnabled && !AvailableTools.webSubagentActive }())
            // Default-on surfaces equal the explicit-on surfaces (main, general, custom, triage, Web).
            let custom = SubagentType(name: "analyst", description: "custom", systemPromptSuffix: "", allowedToolNames: ["read_file", "web_search", "web_fetch"], defaultMaxTurns: 10, preferredModel: .inherit)
            func inventories() throws -> [Data] {
                let parent = AvailableTools.all(includeWebSearch: true)
                return try [toolJSON(parent)] + [SubagentTypes.generalPurpose, custom, SubagentTypes.watcherTriage].map {
                    try toolJSON(SubagentRunner.nativeToolInventory(parentTools: parent, type: $0))
                } + [toolJSON(SubagentRunner.nativeToolInventory(parentTools: parent, type: SubagentTypes.webResearcher))]
            }
            let byDefault = try inventories()
            state.webFlag = true; state.subagentsFlag = true
            let explicitOn = try inventories()
            check("17.2 default on: every inventory (main, general-purpose, custom naming web_search, triage, Web) is byte-identical to explicit /websubagent on",
                  byDefault == explicitOn && toolNames(AvailableTools.all(includeWebSearch: true)).first == "web_fetch")
            // ---- §4.6.1 R2 row: /websubagent off restores the baseline column for every executor.
            state.webFlag = false
            let offParent = AvailableTools.all(includeWebSearch: true)
            let legacyBytes = try toolJSON([AvailableTools.webSearch, AvailableTools.webResearchSweep, AvailableTools.webFetch] + AvailableTools.coreToolsWithoutWebSearch)
            let offGeneral = toolNames(SubagentRunner.nativeToolInventory(parentTools: offParent, type: SubagentTypes.generalPurpose))
            let offCustom = toolNames(SubagentRunner.nativeToolInventory(parentTools: offParent, type: custom))
            let offTriage = toolNames(SubagentRunner.nativeToolInventory(parentTools: offParent, type: SubagentTypes.watcherTriage))
            check("17.3 /websubagent off on an R2 build: main = legacy statics byte for byte; general-purpose = main minus Agent/mid_turn with the legacy research tools; custom keeps web_search; triage read-only; Web type unknown",
                  try toolJSON(offParent) == legacyBytes
                  && offGeneral == toolNames(offParent).filter { $0 != "Agent" && $0 != "mid_turn_message_user" } && offGeneral.prefix(2) == ["web_search", "web_research_sweep"]
                  && offCustom == ["web_search", "web_fetch", "read_file"] && offTriage == ["read_file", "grep", "list_dir", "list_recent_files"]
                  && SubagentTypes.find(name: "Web") == nil, offGeneral.prefix(3).joined(separator: ",") + " | " + offCustom.joined(separator: ","))

            // ---- §16.1: the reply-policy line — unconditional, once, in both messaging-prompt branches, never in the research prompt.
            let line = OpenRouterService.findTaskReplyPolicyLine
            state.webFlag = false
            let offWithTools = await messagingPrompt(tools: AvailableTools.all(includeWebSearch: true))
            let offNoTools = await messagingPrompt(tools: [])
            state.webFlag = true
            let onWithTools = await messagingPrompt(tools: AvailableTools.all(includeWebSearch: true))
            let research = await service.prepareConversation(messages: [Message(role: .user, content: "q", timestamp: state.clock)], imagesDirectory: images, documentsDirectory: documents,
                tools: [], toolResultMessages: nil, calendarContext: nil, emailContext: nil, chunkSummaries: nil, totalChunkCount: 0,
                turnStartDate: state.clock, finalResponseInstruction: nil, tailSystemMessage: nil, tailUserMessage: nil, deferredMCPSummaries: nil, promptStyle: .research).systemPrompt
            check("17.4 reply-policy line: exactly once, right after the Markdown line, in the messaging prompt with tools (switch off and on) and without tools; absent from the research prompt",
                  [offWithTools, offNoTools, onWithTools].allSatisfy { occurrences($0, line) == 1 && $0.contains("no markdown links).\n" + line + "\n") }
                  && !research.contains(line), String(offWithTools.prefix(1200)))
            check("17.5 wording (Codex 2026-09-17): link or location WHEN AVAILABLE, disclosure when it could not be established, never a guessed URL or address, no unnecessary links, short message; bare URL because Markdown links stay forbidden",
                  line.contains("when available") && line.contains("say when it could not be established") && line.contains("never guess a URL or an address")
                  && line.contains("Don't add unnecessary links") && line.contains("keep the message short") && line.contains("bare URL")
                  && !line.contains("must") && !line.contains("always"))
            // Switch off: the only difference from the pre-R2 messaging prompt is that one line (legacy web bullet intact).
            check("17.6 switch off: the legacy web bullet is intact and the delegation bullet absent; switch on: the reverse — the reply-policy line is the one unconditional addition",
                  offWithTools.contains("- Use web tools for current or unstable facts, and cite sources when useful.") && !offWithTools.contains("delegate web research to the Web subagent")
                  && onWithTools.contains("delegate web research to the Web subagent") && !onWithTools.contains("- Use web tools for current or unstable facts")
                  && offWithTools.replacingOccurrences(of: line + "\n", with: "") != offWithTools)

            // ---- §16.1 researcher side (switch-on only) and the usage-notes pointer.
            let bullet = OpenRouterService.researchFindTaskBullet
            let onAgent = AvailableTools.all(includeWebSearch: true).first { $0.function.name == "Agent" }!
            state.webFlag = false
            let offAgent = AvailableTools.all(includeWebSearch: true).first { $0.function.name == "Agent" }!
            state.webFlag = true
            check("17.7 research prompt: the find-task bullet once, in the research discipline, after the retrieval/Sources bullet; direct URL (never a search page), address or coordinates, when the page gives them, otherwise said — never invented",
                  occurrences(research, bullet) == 1 && research.contains("say plainly what could not be verified.\n" + bullet + "\n")
                  && bullet.contains("direct URL") && bullet.contains("never a search page") && bullet.contains("street address or coordinates")
                  && bullet.contains("when the page gives them") && bullet.contains("rather than inventing one") && bullet.contains("Sources list stays"))
            check("17.8 Agent usage notes (switch on only): the main agent is told the researcher's final_message carries each item's direct URL / address or says the page had none",
                  onAgent.function.description.contains("For a find task (a product, a place, a service, a document, an offer) its final_message gives each recommended item's direct URL and, for places, the address, or says when the page had none")
                  && !offAgent.function.description.contains("For a find task"))

            // ---- §16.2: /status labels derived from the resolved type's ROLE, never the name.
            let label = ConversationManager.toolLogLabel
            state.webFlag = true
            check("17.9 built-in Web researcher → Agent (Web research): <description>",
                  label("Agent", agentArguments(["subagent_type": "Web", "description": "parking in Villach", "prompt": "Find parking near the centre of Villach.", "deliverable": "short"]), { SubagentTypes.find(name: $0) })
                  == "Agent (Web research): parking in Villach")
            check("17.10 built-in Browse → Agent (Browser use); general-purpose → Agent (general-purpose); a resume carries the session id's short form",
                  label("Agent", agentArguments(["subagent_type": "Browse", "description": "log into the portal", "prompt": "…"]), { $0 == "Browse" ? SubagentTypes.browse : nil }) == "Agent (Browser use): log into the portal"
                  && label("Agent", agentArguments(["subagent_type": "general-purpose", "description": "scan the repo", "prompt": "…"]), { SubagentTypes.find(name: $0) }) == "Agent (general-purpose): scan the repo"
                  && label("Agent", agentArguments(["subagent_type": "Web", "description": "follow-up on parking", "prompt": "…", "session_id": "abcdef1234567890"]), { SubagentTypes.find(name: $0) })
                  == "Agent (Web research, resume abcdef12): follow-up on parking")
            // A REAL user-defined agent named Web, loaded through UserAgentLoader with the switch off (same trap as R1a round 2).
            let agentsDir = StoragePaths.configRoot.appendingPathComponent("agents", isDirectory: true)
            try PrivateStorage.ensureDirectory(agentsDir)
            let definition = agentsDir.appendingPathComponent("custom-web-status.md")
            try "---\nname: Web\ndescription: User-defined offline reader\ntools: read_file\nmodel: inherit\n---\nAnswer from the supplied task only.\n".write(to: definition, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: definition) }
            state.webFlag = false
            let customLabel = label("Agent", agentArguments(["subagent_type": "Web", "description": "read the brief", "prompt": "…"]), { SubagentTypes.find(name: $0) })
            state.webFlag = true
            let researcherLabel = label("Agent", agentArguments(["subagent_type": "web", "description": "read the brief", "prompt": "…"]), { SubagentTypes.find(name: $0) })
            check("17.11 a user agent named Web (switch off) reads Agent (Web): …, never Web research; the built-in researcher (switch on, any case) reads Agent (Web research): …",
                  customLabel == "Agent (Web): read the brief" && researcherLabel == "Agent (Web research): read the brief", customLabel + " | " + researcherLabel)
            check("17.12 fallbacks: unknown type, unparsable arguments, missing subagent_type, and every non-Agent tool keep the bare tool name; empty description drops the colon",
                  label("Agent", agentArguments(["subagent_type": "nonexistent", "description": "x", "prompt": "…"]), { SubagentTypes.find(name: $0) }) == "Agent"
                  && label("Agent", "{not json", { SubagentTypes.find(name: $0) }) == "Agent"
                  && label("Agent", agentArguments(["description": "x", "prompt": "…"]), { SubagentTypes.find(name: $0) }) == "Agent"
                  && label("bash", "{\"command\":\"ls\"}", { SubagentTypes.find(name: $0) }) == "bash"
                  && label("subagent_manage", agentArguments(["mode": "list_sessions"]), { SubagentTypes.find(name: $0) }) == "subagent_manage"
                  && label("Agent", agentArguments(["subagent_type": "Web", "description": "  ", "prompt": "…"]), { SubagentTypes.find(name: $0) }) == "Agent (Web research)")
            check("17.13 description hygiene: newlines collapsed, long text capped at 80 characters; the label is display-only (no request bytes involved)",
                  label("Agent", agentArguments(["subagent_type": "Web", "description": "line one\nline two", "prompt": "…"]), { SubagentTypes.find(name: $0) }) == "Agent (Web research): line one line two"
                  && label("Agent", agentArguments(["subagent_type": "Web", "description": String(repeating: "x", count: 200), "prompt": "…"]), { SubagentTypes.find(name: $0) })
                  == "Agent (Web research): " + String(repeating: "x", count: 80))
            // Scope (plan §16.2): the label describes the main agent's own call. A general-purpose
            // parent that delegates to Web keeps its own label; the nested run is not a main-agent
            // log entry (it executes inside the child's batch), so nothing here changes for it.
            let parentLabel = label("Agent", agentArguments(["subagent_type": "general-purpose", "description": "audit the docs", "prompt": "Use Agent(Web) for anything you must look up."]), { SubagentTypes.find(name: $0) })
            check("17.14 nested delegation: the parent's label is its own (Agent (general-purpose): …), unaffected by the Web child it launches",
                  parentLabel == "Agent (general-purpose): audit the docs")
            state.webFlag = false; state.subagentsFlag = true
        }
    }
}
