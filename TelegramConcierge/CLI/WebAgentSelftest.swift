import ArgumentParser
import Foundation

/// Hidden deterministic test of the native tool-calling web agent plumbing:
/// request-encoding shapes for the chat and
/// Responses transports, replay fidelity, response parsing, per-call cap
/// enforcement, cross-round dedup, excerpt clamping, and strict-schema
/// validity of every schema constant. Pure in-memory checks — no network,
/// no storage.
struct WebAgentSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__web-agent-selftest",
        abstract: "Internal: verify the web agent's tool-calling request/response plumbing.",
        shouldDisplay: false
    )

    func run() async throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        func encodeJSON<T: Encodable>(_ value: T) -> [String: Any] {
            guard let data = try? JSONEncoder().encode(value),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return obj
        }

        // MARK: 1. Chat message encoding

        let plain = encodeJSON(ORChatReq.Msg(role: "system", content: "hello"))
        check("plain message encodes only role+content",
              plain.count == 2 && plain["role"] as? String == "system" && plain["content"] as? String == "hello",
              "keys: \(plain.keys.sorted())")

        let assistantCall = ORChatReq.Msg(
            role: "assistant",
            content: nil,
            tool_calls: [ORToolCall(id: "call_1", function: .init(name: "search", arguments: "{\"queries\":[\"q\"]}"))],
            reasoning_content: .string("thinking..."))
        let assistantJSON = encodeJSON(assistantCall)
        let encodedCalls = assistantJSON["tool_calls"] as? [[String: Any]] ?? []
        let fn = encodedCalls.first?["function"] as? [String: Any] ?? [:]
        check("assistant tool-call message omits nil content, carries calls + reasoning_content",
              assistantJSON["content"] == nil
              && encodedCalls.first?["id"] as? String == "call_1"
              && encodedCalls.first?["type"] as? String == "function"
              && fn["name"] as? String == "search"
              && (fn["arguments"] as? String)?.contains("queries") == true
              && assistantJSON["reasoning_content"] as? String == "thinking...")

        let toolMsg = encodeJSON(ORChatReq.Msg(role: "tool", content: "{}", tool_call_id: "call_1"))
        check("tool result message carries tool_call_id",
              toolMsg["tool_call_id"] as? String == "call_1" && toolMsg["role"] as? String == "tool")

        // MARK: 2. Chat request encoding

        let baseReq = ORChatReq(
            model: "m", messages: [.init(role: "user", content: "hi")], stream: false,
            reasoning: nil, reasoning_effort: nil, provider: nil)
        let baseJSON = encodeJSON(baseReq)
        check("request without tools omits tools/tool_choice/response_format",
              baseJSON["tools"] == nil && baseJSON["tool_choice"] == nil && baseJSON["response_format"] == nil)
        check("chat request carries no output-token cap (no max_tokens / max_completion_tokens)",
              baseJSON["max_tokens"] == nil && baseJSON["max_completion_tokens"] == nil)
        check("chat request carries no temperature (the field no longer exists: host/model default sampling)",
              baseJSON["temperature"] == nil)

        var toolReq = baseReq
        toolReq.tools = WebAgentTools.chatTools
        toolReq.tool_choice = "none"
        let toolJSON = encodeJSON(toolReq)
        let toolDefs = toolJSON["tools"] as? [[String: Any]] ?? []
        let firstFn = toolDefs.first?["function"] as? [String: Any] ?? [:]
        check("request with tools encodes both defs + tool_choice",
              toolDefs.count == 2
              && toolDefs.allSatisfy { $0["type"] as? String == "function" }
              && firstFn["name"] as? String == WebAgentTools.searchName
              && (firstFn["parameters"] as? [String: Any])?["type"] as? String == "object"
              && toolJSON["tool_choice"] as? String == "none")

        var rfReq = baseReq
        rfReq.response_format = WebExtractionSchemas.excerpts
        let rfJSON = encodeJSON(rfReq)
        let rf = rfJSON["response_format"] as? [String: Any] ?? [:]
        let rfSchema = rf["json_schema"] as? [String: Any] ?? [:]
        check("response_format encodes json_schema strict envelope",
              rf["type"] as? String == "json_schema"
              && rfSchema["name"] as? String == "page_blocks"
              && rfSchema["strict"] as? Bool == true
              && rfSchema["schema"] != nil)

        // MARK: 3. Backend response_format policy

        check("response_format policy: openai+openrouter yes, opencode no",
              WebSearchBackend.openai.supportsResponseFormat
              && WebSearchBackend.openrouter.supportsResponseFormat
              && !WebSearchBackend.opencode.supportsResponseFormat)

        // MARK: 3a. Backend resolution (pure resolve() — the machine's real
        // preferences are never touched here).

        check("resolve: stored choice wins over key inference",
              WebSearchBackend.resolve(override: nil, stored: "opencode",
                                       hasOpenAIKey: true, hasLegacyOpenRouterKey: true) == .opencode)
        check("resolve: process override wins over stored choice",
              WebSearchBackend.resolve(override: .openrouter, stored: "openai",
                                       hasOpenAIKey: true, hasLegacyOpenRouterKey: false) == .openrouter)
        check("resolve: missing choice + OpenAI key infers openai (Luna default)",
              WebSearchBackend.resolve(override: nil, stored: nil,
                                       hasOpenAIKey: true, hasLegacyOpenRouterKey: true) == .openai)
        check("resolve: missing choice + only legacy OpenRouter key infers openrouter",
              WebSearchBackend.resolve(override: nil, stored: nil,
                                       hasOpenAIKey: false, hasLegacyOpenRouterKey: true) == .openrouter)
        check("resolve: no choice, no keys falls back to opencode",
              WebSearchBackend.resolve(override: nil, stored: nil,
                                       hasOpenAIKey: false, hasLegacyOpenRouterKey: false) == .opencode)
        check("resolve: unparseable stored value falls through to inference",
              WebSearchBackend.resolve(override: nil, stored: "garbage",
                                       hasOpenAIKey: true, hasLegacyOpenRouterKey: false) == .openai)

        // MARK: 3b. Agent-round reasoning must come back for replay
        // Mechanical stages keep exclude:true (never replayed); agent rounds
        // flip it to false so OpenRouter actually returns reasoning /
        // reasoning_details to replay across tool calls.

        let excluded = makeReasoning(.medium)
        let included = WebAgentSupport.includedInResponse(excluded)
        let includedJSON = encodeJSON(["reasoning": included])["reasoning"] as? [String: Any] ?? [:]
        check("agent-round reasoning keeps effort but drops the exclude flag",
              excluded?.exclude == true
              && included?.effort == "medium"
              && included?.exclude == false
              && includedJSON["effort"] as? String == "medium"
              && includedJSON["exclude"] as? Bool == false)
        check("includedInResponse preserves nil (no reasoning configured)",
              WebAgentSupport.includedInResponse(nil) == nil)

        // MARK: 4. Chat response decoding

        // reasoning_details carries an OpenRouter-style structured block with
        // a provider signature — it must survive decode → replay byte-equal.
        let chatRespJSON = """
        {"choices":[{"message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"c9","type":"function","function":{"name":"fetch_and_extract","arguments":"{\\"requests\\":[]}"}}],
          "reasoning_content":"rc",
          "reasoning_details":[{"type":"reasoning.encrypted","data":"SIGNEDBLOB","id":"rd_1","format":"anthropic-claude-v1"}]},
          "finish_reason":"tool_calls"}],
         "usage":{"prompt_tokens":10,"completion_tokens":5}}
        """
        let chatResp = try? JSONDecoder().decode(ORChatResp.self, from: Data(chatRespJSON.utf8))
        let respMsg = chatResp?.choices.first?.message
        check("chat response with null content + tool_calls decodes",
              respMsg?.content == nil
              && respMsg?.tool_calls?.first?.id == "c9"
              && respMsg?.tool_calls?.first?.function.name == "fetch_and_extract"
              && respMsg?.reasoning_content?.stringValue == "rc")

        // MARK: 5. Chat transcript replay

        let transcript = WebAgentChatTranscript(system: "sys", user: "question")
        if let respMsg { transcript.appendAssistant(respMsg) }
        transcript.appendToolResult(callID: "c9", content: "{\"pages\":[]}")
        transcript.appendUser("nudge")
        let roles = transcript.messages.map { $0.role }
        check("chat transcript sequence system→user→assistant→tool→user",
              roles == ["system", "user", "assistant", "tool", "user"]
              && transcript.messages[2].tool_calls?.count == 1
              && transcript.messages[2].reasoning_content?.stringValue == "rc"
              && transcript.messages[3].tool_call_id == "c9")

        // Structured reasoning_details must be replayed verbatim (OpenRouter
        // requires unchanged blocks during tool use for signed reasoning).
        let replayedAssistant = encodeJSON(transcript.messages[2])
        let replayedDetails = (replayedAssistant["reasoning_details"] as? [[String: Any]])?.first
        check("reasoning_details replayed verbatim incl. signature fields",
              replayedDetails?["type"] as? String == "reasoning.encrypted"
              && replayedDetails?["data"] as? String == "SIGNEDBLOB"
              && replayedDetails?["id"] as? String == "rd_1"
              && replayedDetails?["format"] as? String == "anthropic-claude-v1")

        // MARK: 6. Responses API request encoding

        let rTranscript = WebAgentResponsesTranscript(instructions: "inst", user: "q")
        let req = OAIResponsesReq(
            model: "gpt-5.6-luna", instructions: rTranscript.instructions,
            input: rTranscript.input, tools: WebAgentTools.responsesTools,
            tool_choice: nil, reasoning: .init(effort: "high"))
        let reqJSON = encodeJSON(req)
        let rTools = reqJSON["tools"] as? [[String: Any]] ?? []
        check("responses request: store=false, include=encrypted reasoning, flat strict tools",
              reqJSON["store"] as? Bool == false
              && (reqJSON["include"] as? [String]) == ["reasoning.encrypted_content"]
              && rTools.count == 2
              && rTools.allSatisfy { $0["strict"] as? Bool == true && $0["type"] as? String == "function" }
              && rTools.first?["name"] as? String == WebAgentTools.searchName
              && (reqJSON["reasoning"] as? [String: Any])?["effort"] as? String == "high"
              && reqJSON["tool_choice"] == nil && reqJSON["max_output_tokens"] == nil)

        // MARK: 7. Responses output parsing + verbatim replay

        let outputJSON = """
        [{"type":"reasoning","id":"rs_1","encrypted_content":"SEALED","summary":[]},
         {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Plan: check docs."}]},
         {"type":"function_call","name":"search","arguments":"{\\"queries\\":[\\"a\\"]}","call_id":"call_77"}]
        """
        let outputItems = (try? JSONDecoder().decode([JSONValue].self, from: Data(outputJSON.utf8))) ?? []
        let parsed = WebAgentResponsesTranscript.parseRound(outputItems: outputItems)
        check("responses round parses message text + function call, skips reasoning",
              parsed.visibleText == "Plan: check docs."
              && parsed.toolCalls.count == 1
              && parsed.toolCalls.first?.id == "call_77"
              && parsed.toolCalls.first?.name == "search"
              && parsed.toolCalls.first?.argumentsJSON.contains("queries") == true)

        rTranscript.appendOutputItems(outputItems)
        rTranscript.appendToolResult(callID: "call_77", content: "{\"results\":[]}")
        let replayed = encodeJSON(["input": rTranscript.input])["input"] as? [[String: Any]] ?? []
        let reasoningReplay = replayed.first { $0["type"] as? String == "reasoning" }
        let fnOutput = replayed.first { $0["type"] as? String == "function_call_output" }
        // 1 initial user item + 3 replayed output items + 1 function_call_output
        check("responses replay keeps encrypted reasoning verbatim + appends function_call_output",
              replayed.count == 5
              && reasoningReplay?["encrypted_content"] as? String == "SEALED"
              && fnOutput?["call_id"] as? String == "call_77"
              && fnOutput?["output"] as? String == "{\"results\":[]}")

        // MARK: 8. Support helpers

        let (kept, dropped) = WebAgentSupport.capped(["a", "b", "c", "d", "e", "f"], to: 4)
        check("query cap keeps 4, reports 2 dropped", kept == ["a", "b", "c", "d"] && dropped == 2)
        let (keptExact, droppedExact) = WebAgentSupport.capped(["a"], to: 4)
        check("cap under limit is untouched", keptExact == ["a"] && droppedExact == 0)

        var seen: Set<String> = ["https://old.example"]
        let results = [
            WebResult(title: "old", snippet: "s", link: "https://old.example", source: "e", date: nil, retrievedAtStep: 2),
            WebResult(title: "new", snippet: "s", link: "https://new.example", source: "e", date: nil, retrievedAtStep: 2),
        ]
        let (fresh, omitted) = WebAgentSupport.dedupeAgainstSeen(results, seen: &seen)
        check("cross-round dedup filters seen links and counts them",
              fresh.count == 1 && fresh.first?.link == "https://new.example"
              && omitted == 1 && seen.contains("https://new.example"))

        let (clamped, truncated) = WebAgentSupport.clampExcerpts(["12345", "67890"], totalBudget: 7)
        check("excerpt clamp keeps whole then truncates with marker",
              clamped.count == 2 && clamped[0] == "12345"
              && clamped[1].hasPrefix("67") && clamped[1].hasSuffix("…[truncated]") && truncated)
        let (unclamped, untruncated) = WebAgentSupport.clampExcerpts(["ab"], totalBudget: 100)
        check("excerpt clamp under budget is untouched", unclamped == ["ab"] && !untruncated)

        // MARK: 9. Strict-schema validity
        // Every schema sent with strict:true must list ALL properties as
        // required and forbid additionalProperties at every object level.

        func validateStrictObject(_ value: JSONValue, path: String) -> String? {
            guard let obj = value.objectValue else { return nil }
            if obj["type"]?.stringValue == "object" {
                let props = obj["properties"]?.objectValue ?? [:]
                let required = Set((obj["required"]?.arrayValue ?? []).compactMap { $0.stringValue })
                if Set(props.keys) != required {
                    return "\(path): required \(required.sorted()) ≠ properties \(props.keys.sorted())"
                }
                if case .bool(false)? = obj["additionalProperties"] {} else {
                    return "\(path): additionalProperties not false"
                }
            }
            for (key, nested) in obj {
                if let err = validateStrictObject(nested, path: "\(path).\(key)") { return err }
            }
            if let arr = value.arrayValue {
                for (i, nested) in arr.enumerated() {
                    if let err = validateStrictObject(nested, path: "\(path)[\(i)]") { return err }
                }
            }
            return nil
        }

        let strictSchemas: [(String, JSONValue)] = [
            ("search params", WebAgentTools.searchParameters),
            ("fetch params", WebAgentTools.fetchParameters),
            ("excerpts rf", WebExtractionSchemas.excerpts.json_schema.schema),
        ]
        for (name, schema) in strictSchemas {
            let err = validateStrictObject(schema, path: name)
            check("strict schema valid: \(name)", err == nil, err ?? "")
        }

        // The strict decode targets must accept a schema-conforming payload.
        let picksPayload = "{\"blocks\":[\"P2-P4\",\"P9\"],\"links\":[3,1],\"images\":[2]}"
        let picks = try? JSONDecoder().decode(BlockPicksOut.self, from: Data(picksPayload.utf8))
        check("BlockPicksOut decodes the schema-shaped payload (block ranges plus link/image numbers)",
              picks?.blocks == [BlockPick(first: 2, last: 4), BlockPick(first: 9, last: 9)] && picks?.links == [.number(3), .number(1)] && picks?.images == [.number(2)])

        // MARK: 10. Tool argument decoding (the loop's parse of model calls)

        check("SearchToolArgs decodes",
              (try? JSONDecoder().decode(SearchToolArgs.self, from: Data("{\"queries\":[\"x\"]}".utf8)))?.queries == ["x"])
        let fetchArgs = try? JSONDecoder().decode(FetchToolArgs.self, from: Data("{\"requests\":[{\"url\":\"https://e\",\"focus\":\"f\"}]}".utf8))
        check("FetchToolArgs decodes", fetchArgs?.requests.first?.focus == "f")

        // MARK: 11. Orchestration state machine (stubbed transports)
        // The model round and the tool network phase are stubbed, so these
        // exercise the REAL answer() loop: natural completion, zero-search
        // nudge and hard fail, budget exhaustion → forced finalization,
        // salvage after a failed round, only-failures propagation, and
        // same-round tool-call concurrency.

        actor StageRecorder {
            var stages: [(stage: String, toolChoice: String?)] = []
            func record(_ stage: String, _ toolChoice: String?) { stages.append((stage, toolChoice)) }
        }

        func searchCall(_ id: String) -> WebAgentToolCall {
            WebAgentToolCall(id: id, name: WebAgentTools.searchName, argumentsJSON: "{\"queries\":[\"q\"]}")
        }
        func contextWithOneResult() -> WebContext {
            WebContext(
                queries_used: [QueryRecord(query: "q", retrievedAtStep: 1)],
                results: [WebResult(title: "t", snippet: "s", link: "https://r.example", source: "e", date: nil, retrievedAtStep: 1)],
                answerBox: nil, knowledgeGraph: nil, peopleAlsoAsk: nil, topStories: nil, scraped: [])
        }
        let okSearch = WebOrchestrator.AgentToolNetworkResult.search(
            context: contextWithOneResult(), failures: [], dropped: 0, queriesRun: ["q"])

        func runScenario(
            agentRound: @escaping @Sendable (String, String?) async throws -> WebAgentRound,
            toolNetwork: @escaping @Sendable (WebAgentToolCall) async throws -> WebOrchestrator.AgentToolNetworkResult
        ) async -> Result<String, Error> {
            let orch = WebOrchestrator()
            await orch.setTestStubs(agentRound: agentRound, toolNetwork: toolNetwork)
            do {
                return .success(try await orch.answer(
                    userPrompt: "test question", historyPairs: [], mode: .webSearch, executionID: UUID()))
            } catch {
                return .failure(error)
            }
        }
        func errorCode(_ result: Result<String, Error>) -> Int? {
            if case .failure(let error) = result { return (error as NSError).code }
            return nil
        }

        // A. Search round → text round = natural final answer.
        let recA = StageRecorder()
        let resultA = await runScenario(
            agentRound: { stage, toolChoice in
                await recA.record(stage, toolChoice)
                return stage == "agent.round1"
                    ? WebAgentRound(visibleText: "Checking.", toolCalls: [searchCall("s1")])
                    : WebAgentRound(visibleText: "The answer <https://r.example>", toolCalls: [])
            },
            toolNetwork: { _ in okSearch })
        let aCount = await recA.stages.count
        check("state: natural completion returns the final text",
              (try? resultA.get()) == "The answer <https://r.example>" && aCount == 2)

        // B. Text-first (no search) → nudged once → search → answer.
        let recB = StageRecorder()
        let resultB = await runScenario(
            agentRound: { stage, toolChoice in
                await recB.record(stage, toolChoice)
                let count = await recB.stages.count
                switch count {
                case 1: return WebAgentRound(visibleText: "I already know this.", toolCalls: [])
                case 2: return WebAgentRound(visibleText: "Fine, searching.", toolCalls: [searchCall("s1")])
                default: return WebAgentRound(visibleText: "Verified answer.", toolCalls: [])
                }
            },
            toolNetwork: { _ in okSearch })
        let bCount = await recB.stages.count
        check("state: zero-search nudge recovers into a real research",
              (try? resultB.get()) == "Verified answer." && bCount == 3)

        // C. Text-only forever → nudge once, then fail loudly (code 5).
        let recC = StageRecorder()
        let resultC = await runScenario(
            agentRound: { stage, toolChoice in
                await recC.record(stage, toolChoice)
                return WebAgentRound(visibleText: "No search needed.", toolCalls: [])
            },
            toolNetwork: { _ in okSearch })
        let cCount = await recC.stages.count
        check("state: zero-search concludes with code 5 after exactly one nudge",
              errorCode(resultC) == 5 && cCount == 2)

        // D. Tool calls every round → budget exhausted → forced final with
        //    tool_choice "none" on stage agent.final.
        let recD = StageRecorder()
        let resultD = await runScenario(
            agentRound: { stage, toolChoice in
                await recD.record(stage, toolChoice)
                return stage == "agent.final"
                    ? WebAgentRound(visibleText: "Forced summary.", toolCalls: [])
                    : WebAgentRound(visibleText: "More digging.", toolCalls: [searchCall("s\(stage)")])
            },
            toolNetwork: { _ in okSearch })
        let dStages = await recD.stages
        check("state: budget exhaustion forces finalization with tool_choice none",
              (try? resultD.get()) == "Forced summary."
              && dStages.count == 6  // 5 web rounds + agent.final
              && dStages.last?.stage == "agent.final"
              && dStages.last?.toolChoice == "none")

        // E. A round throws AFTER results were gathered → salvage via forced
        //    finalization instead of losing the work.
        let recE = StageRecorder()
        let resultE = await runScenario(
            agentRound: { stage, toolChoice in
                await recE.record(stage, toolChoice)
                let count = await recE.stages.count
                if count == 1 { return WebAgentRound(visibleText: "", toolCalls: [searchCall("s1")]) }
                if stage == "agent.final" { return WebAgentRound(visibleText: "Salvaged.", toolCalls: []) }
                throw NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "transport died"])
            },
            toolNetwork: { _ in okSearch })
        let eLastStage = await recE.stages.last?.stage
        check("state: failed round after gathered context salvages a final answer",
              (try? resultE.get()) == "Salvaged." && eLastStage == "agent.final")

        // E2. A round throws with NOTHING gathered → the error propagates.
        let resultE2 = await runScenario(
            agentRound: { _, _ in
                throw NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "transport died"])
            },
            toolNetwork: { _ in okSearch })
        check("state: failed round with no context propagates the error",
              errorCode(resultE2) == 99)

        // F. Searches attempted but EVERYTHING failed and nothing retrieved →
        //    code 3 (broken plumbing must not become a "found nothing" answer).
        let resultF = await runScenario(
            agentRound: { stage, _ in
                stage == "agent.round1"
                    ? WebAgentRound(visibleText: "", toolCalls: [searchCall("s1")])
                    : WebAgentRound(visibleText: "Nothing works, so: no results found.", toolCalls: [])
            },
            toolNetwork: { _ in
                .search(context: WebContext.empty(), failures: ["q: serper 500"], dropped: 0, queriesRun: ["q"])
            })
        check("state: only-failures research throws code 3, not a fabricated answer",
              errorCode(resultF) == 3)

        // G. Two tool calls in one round run CONCURRENTLY: call A's network
        //    phase blocks until call B's has started — sequential execution
        //    would deadlock (bounded by the watchdog below).
        // Polling (not continuations) so a sequential-execution deadlock is
        // broken by task cancellation instead of hanging the group forever.
        actor Gate {
            var bStarted = false
            func markBStarted() { bStarted = true }
            func waitForB() async {
                for _ in 0..<600 { // 30s cap
                    if bStarted { return }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if Task.isCancelled { return }
                }
            }
        }
        let gate = Gate()
        let concurrencyResult: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let result = await runScenario(
                    agentRound: { stage, _ in
                        stage == "agent.round1"
                            ? WebAgentRound(visibleText: "", toolCalls: [searchCall("A"), searchCall("B")])
                            : WebAgentRound(visibleText: "Both ran.", toolCalls: [])
                    },
                    toolNetwork: { call in
                        if call.id == "A" { await gate.waitForB() } else { await gate.markBStarted() }
                        return okSearch
                    })
                return try? result.get()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        check("state: same-round tool calls execute concurrently",
              concurrencyResult == "Both ran.",
              concurrencyResult == nil ? "deadlock — outer calls ran sequentially" : "unexpected: \(concurrencyResult ?? "nil")")

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        if failures > 0 { throw ExitCode.failure }
    }
}
