import Foundation

/// Continuity fields of the opt-in request log (private-docs
/// BRIGLIA_0253_PLAN v3 §4 with Codex v3 correction 2 and answer 8):
/// `prev_input_preserved` (input items only), `boundary_preserved` (system,
/// tools, settings AND the input up to the previous last non-system item),
/// `continuity_unknown` reasons whenever evidence is incomplete (never a
/// guessed true), `tail_roles`, `ambient`, `ambient_role`. Retained-state
/// truncation never redefines the previous request's boundary.
extension MidturnHarness {

    func cpBoundarySection() async {
        let log = CacheDiagnostics.logURL
        CacheDiagnostics.enabledOverrideForTesting = true
        CacheDiagnostics.reset()
        defer {
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = nil
            CacheDiagnostics.enabledOverrideForTesting = nil
            CacheDiagnostics.reset()
            ASFixtures.resetSeams()
        }
        func lastLine() -> [String: Any] {
            let last = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").last.map(String.init) ?? ""
            return (try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]) ?? [:]
        }
        func flags(_ line: [String: Any]) -> String {
            "prev \(String(describing: line["prev_input_preserved"])) boundary \(String(describing: line["boundary_preserved"])) unknown \(String(describing: line["continuity_unknown"])) tail \(String(describing: line["tail_roles"])) ambient \(String(describing: line["ambient"]))/\(String(describing: line["ambient_role"]))"
        }
        func isTrue(_ v: Any?) -> Bool { (v as? Bool) == true }
        func isFalse(_ v: Any?) -> Bool { (v as? Bool) == false }
        func reasons(_ line: [String: Any]) -> [String] { line["continuity_unknown"] as? [String] ?? [] }

        // D1 — real request bodies (Chat and Responses) through the shipped
        // serializers, aborted before any transport; the log reads them.
        let service = OpenRouterService()
        let task = Message(role: .user, content: "Synthetic task")
        let rounds = (1...3).map(ASFixtures.round)
        for (name, base) in [("Responses · OpenAI API", ASFixtures.routes[0].context),
                             ("Chat · api.openai.com", ASFixtures.routes[4].context),
                             ("Chat · OpenCode chat model", ASFixtures.routes[8].context)] {
            var context = base
            context = ASFixtures.context(base.provider, endpoint: base.endpoint, model: base.model, wire: base.wireProtocol,
                                         profile: base.profileIdentity, lane: .ephemeral(UUID()))
            let family = AmbientStatus.role(for: context) == "system"
            ASFixtures.install(bash: [], subagents: [])
            _ = await ASFixtures.capture(service, ASFixtures.conversation([task], rounds: Array(rounds.prefix(1))), context)
            let first = lastLine()
            check("D2 \(name): first request on a stream → both flags null with the reason, no ambient",
                  first["prev_input_preserved"] is NSNull && first["boundary_preserved"] is NSNull
                    && reasons(first) == [CacheDiagnostics.unknownNoPrevious] && isFalse(first["ambient"]) && first["ambient_role"] is NSNull,
                  flags(first))
            _ = await ASFixtures.capture(service, ASFixtures.conversation([task], rounds: Array(rounds.prefix(2))), context)
            let s1 = lastLine()
            check("D1 \(name) S1 (no tail → one more round): whole input and boundary preserved, no unknowns, tail_roles []",
                  isTrue(s1["prev_input_preserved"]) && isTrue(s1["boundary_preserved"]) && s1["continuity_unknown"] == nil
                    && (s1["tail_roles"] as? [String]) == [], flags(s1))
            ASFixtures.install(bash: [ASFixtures.bash("bash_1", "make", ago: 12)], subagents: [])
            _ = await ASFixtures.capture(service, ASFixtures.conversation([task], rounds: Array(rounds.prefix(2))), context)
            let s5 = lastLine()
            ASFixtures.install(bash: [ASFixtures.bash("bash_1", "make", ago: 13)], subagents: [])
            _ = await ASFixtures.capture(service, ASFixtures.conversation([task], rounds: rounds), context)
            let s3 = lastLine()
            let role = family ? "system" : "user"
            check("D1 \(name) S5 (job started → ambient): flags true, ambient \(role), tail_roles [\(role)]",
                  isTrue(s5["boundary_preserved"]) && isTrue(s5["ambient"]) && s5["ambient_role"] as? String == role
                    && (s5["tail_roles"] as? [String]) == [role], flags(s5))
            check("D1 \(name) S3 (ambient replaced): input not whole-preserved; boundary \(family ? "preserved" : "broken")",
                  isFalse(s3["prev_input_preserved"]) && (family ? isTrue(s3["boundary_preserved"]) : isFalse(s3["boundary_preserved"]))
                    && s3["continuity_unknown"] == nil, flags(s3))
        }
        ASFixtures.resetSeams()

        // Synthetic chat bodies for the evidence rules.
        func ctx() -> ProviderExecutionContext {
            ASFixtures.context(.openAICompatible, endpoint: "http://127.0.0.1/v1", model: "m", wire: .chatCompletions, profile: "custom",
                               lane: .ephemeral(UUID()))
        }
        func body(system: String = "S", items: [(String, String)], tools: Int = 0, effort: String? = nil) -> Data {
            var root: [String: Any] = ["model": "m", "messages": [["role": "system", "content": system]]
                + items.map { ["role": $0.0, "content": $0.1] }]
            if tools > 0 {
                root["tools"] = (0..<tools).map { ["type": "function", "function": ["name": "tool_\($0)", "description": String(repeating: "d", count: 40)]] }
            }
            if let effort { root["reasoning_effort"] = effort }
            return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        }
        func pair(_ a: Data, _ aTail: Int, _ b: Data, _ bTail: Int, retain: Int? = nil) -> [String: Any] {
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = retain
            let c = ctx()
            CacheDiagnostics.observe(context: c, protocolName: "chat", body: a, tailCount: aTail, ambientRole: aTail > 0 ? "system" : nil)
            CacheDiagnostics.observe(context: c, protocolName: "chat", body: b, tailCount: bTail, ambientRole: bTail > 0 ? "system" : nil)
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = nil
            return lastLine()
        }
        let history = (0..<6).map { ($0 % 2 == 0 ? "user" : "assistant", "turn \($0) " + String(repeating: "h", count: 60)) }
        let prevItems = history + [("system", "ambient 12s")]
        let nextItems = history + [("user", "new"), ("system", "ambient 13s")]

        // D3 — full hashes (raw too large, hashes fit): exact verdicts.
        let bigSystem = String(repeating: "S", count: 6_000)
        let d3 = pair(body(system: bigSystem, items: prevItems), 1, body(system: bigSystem, items: nextItems), 1, retain: 2_000)
        var mismatched = nextItems; mismatched[3].1 += " changed"
        let d3b = pair(body(system: bigSystem, items: prevItems), 1, body(system: bigSystem, items: mismatched), 1, retain: 2_000)
        check("D3 hashed retention: replaced trailing system item → boundary true, input false; a changed history item → boundary false",
              isTrue(d3["boundary_preserved"]) && isFalse(d3["prev_input_preserved"]) && d3["continuity_unknown"] == nil
                && isFalse(d3b["boundary_preserved"]) && d3b["continuity_unknown"] == nil, flags(d3) + " | " + flags(d3b))

        // D4 — truncated hashes: the boundary lies beyond the retained
        // prefix → unknown, never true; a mismatch inside the prefix → false.
        // Hashed retention keeps: system HMAC (32) + the "model" setting
        // (5 + 32) + one byte per item role, then tool/item HMACs (32 each).
        let fixed = { (items: Int) in 32 + 5 + 32 + items }
        let truncatedBound = fixed(prevItems.count) + 3 * 32   // three item hashes, no tools
        let d4 = pair(body(system: bigSystem, items: prevItems), 1, body(system: bigSystem, items: nextItems), 1, retain: truncatedBound)
        var early = nextItems; early[1].1 += " changed"
        let d4b = pair(body(system: bigSystem, items: prevItems), 1, body(system: bigSystem, items: early), 1, retain: truncatedBound)
        check("D4 truncated retention: unchanged prefix but boundary beyond it → null with reason; mismatch inside the prefix → false",
              d4["boundary_preserved"] is NSNull && d4["prev_input_preserved"] is NSNull && reasons(d4).contains(CacheDiagnostics.unknownItems)
                && isFalse(d4b["boundary_preserved"]) && isFalse(d4b["prev_input_preserved"]), flags(d4) + " | " + flags(d4b))

        // D9 — a change BEYOND the retained prefix is reported unknown, not true.
        var late = nextItems; late[5].1 += " changed"
        let d9 = pair(body(system: bigSystem, items: prevItems), 1, body(system: bigSystem, items: late), 1, retain: truncatedBound)
        check("D9 a change beyond the retained prefix → null (not a false 'preserved')",
              d9["boundary_preserved"] is NSNull && !isTrue(d9["prev_input_preserved"]), flags(d9))

        // D5 — dropped state (system hash alone exceeds the bound).
        let d5 = pair(body(system: bigSystem, items: prevItems), 1, body(system: bigSystem, items: nextItems), 1, retain: 8)
        check("D5 dropped retained state → both null with the reason",
              d5["boundary_preserved"] is NSNull && d5["prev_input_preserved"] is NSNull && reasons(d5) == [CacheDiagnostics.unknownDropped],
              flags(d5))

        // D6 — a changed initial system prompt (e.g. persona): the
        // input-only flag can be true, the boundary is false.
        let d6 = pair(body(system: "Persona A", items: history), 0, body(system: "Persona B", items: history + [("user", "x")]), 0)
        check("D6 changed system text: prev_input_preserved (input items only) true, boundary_preserved false",
              isTrue(d6["prev_input_preserved"]) && isFalse(d6["boundary_preserved"]), flags(d6))

        // D7 — tools: a change → false; equal retained prefix but tools cut
        // by the bound → unknown.
        let d7 = pair(body(items: history, tools: 3), 0, body(items: history + [("user", "x")], tools: 4), 0)
        let toolBound = fixed(history.count) + 448   // room/64 = 7 of 40 tool hashes, then (448 - 224)/32 = 7 ≥ 6 item hashes
        let d7b = pair(body(system: bigSystem, items: history, tools: 40), 0, body(system: bigSystem, items: history + [("user", "x")], tools: 40), 0,
                       retain: toolBound)
        check("D7 tools changed → boundary false; tools beyond the retained prefix (prefix equal) → null with reason",
              isFalse(d7["boundary_preserved"]) && d7b["boundary_preserved"] is NSNull && reasons(d7b).contains(CacheDiagnostics.unknownTools)
                && isTrue(d7b["prev_input_preserved"]), flags(d7) + " | " + flags(d7b))

        // D8 — settings changed.
        let d8 = pair(body(items: history, effort: "low"), 0, body(items: history + [("user", "x")], effort: "high"), 0)
        check("D8 settings changed (reasoning effort) → boundary false", isFalse(d8["boundary_preserved"]), flags(d8))

        // D10 — an evicted stream: its next request has no evidence.
        let evicted = ctx()
        CacheDiagnostics.observe(context: evicted, protocolName: "chat", body: body(items: history), tailCount: 0)
        for _ in 0..<(CacheDiagnostics.maxLanes + 1) {
            CacheDiagnostics.observe(context: ctx(), protocolName: "chat", body: body(items: history), tailCount: 0)
        }
        CacheDiagnostics.observe(context: evicted, protocolName: "chat", body: body(items: history + [("user", "x")]), tailCount: 0)
        let d10 = lastLine()
        check("D10 evicted stream → both null with the reason", d10["boundary_preserved"] is NSNull
              && reasons(d10) == [CacheDiagnostics.unknownNoPrevious], flags(d10))

        // D12 — roles come from a fixed allowlist; arbitrary role strings never reach the log.
        let odd = pair(body(items: history), 0, body(items: history + [("evil-role-CANARY", "x")]), 1)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check("D12 an unknown role is logged as 'other'; the raw string never reaches the log",
              (odd["tail_roles"] as? [String]) == ["other"] && !text.contains("evil-role-CANARY"), flags(odd))

        // D13 — retained roles count toward the per-stream bound.
        do {
            CacheDiagnostics.reset()
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = 512
            let many = (0..<400).map { _ in ("user", "x") }
            CacheDiagnostics.observe(context: ctx(), protocolName: "chat", body: body(system: bigSystem, items: many), tailCount: 0)
            let stats = CacheDiagnostics.retainedStats
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = nil
            check("D13 retained state incl. item roles stays within the per-stream bound", stats.bytes <= 512, "\(stats.bytes)")
        }

        // D11 — diagnostics on vs off with background work running: identical
        // request bytes (clock, rows and persona held constant), both protocols.
        ASFixtures.install(bash: [ASFixtures.bash("bash_1", "make test", "build", ago: 20)],
                           subagents: [ASFixtures.subagent("subagent_1", "general-purpose", "scan", ago: 40)])
        for route in [ASFixtures.routes[0], ASFixtures.routes[4], ASFixtures.routes[8]] {
            var bodies: [Data] = []
            for on in [false, true] {
                CacheDiagnostics.enabledOverrideForTesting = on
                if let b = await ASFixtures.capture(service, ASFixtures.conversation([task], rounds: rounds), route.context) { bodies.append(b) }
            }
            CacheDiagnostics.enabledOverrideForTesting = true
            check("D11 \(route.name): request bytes identical with diagnostics off and on while background work runs",
                  bodies.count == 2 && bodies[0] == bodies[1] && String(decoding: bodies[0], as: UTF8.self).contains("Ambient status"))
        }
    }
}
