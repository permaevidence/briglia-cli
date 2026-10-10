import Foundation

/// P5: one persona per subagent run, captured before the eager resume
/// compaction, used by all five request sites (rounds, the context-limit
/// retry, the forced final, the ordinary and the emergency summarizer); a
/// resume recaptures; the Web researcher gets no profile.
final class PSRouter: @unchecked Sendable {
    typealias Call = (id: String, name: String, args: [String: Any])
    private let lock = NSLock()
    private var rounds: [(calls: [Call], text: String?, prompt: Int)] = []
    private var _bodies: [String] = []
    private var _onRequest: ((Int, String) -> Void)?
    private var _contextLimitCalls = false
    var bodies: [String] { lock.lock(); defer { lock.unlock() }; return _bodies }
    var onRequest: ((Int, String) -> Void)? { get { lock.lock(); defer { lock.unlock() }; return _onRequest } set { lock.lock(); _onRequest = newValue; lock.unlock() } }
    /// The in-loop "[CONTEXT LIMIT]" final answers with tool calls once, so
    /// the retry site runs.
    var contextLimitCalls: Bool { get { lock.lock(); defer { lock.unlock() }; return _contextLimitCalls } set { lock.lock(); _contextLimitCalls = newValue; lock.unlock() } }
    func push(_ calls: [Call], text: String? = nil, prompt: Int) { lock.lock(); rounds.append((calls, text, prompt)); lock.unlock() }
    func reset() { lock.lock(); rounds = []; _bodies = []; _onRequest = nil; _contextLimitCalls = false; lock.unlock() }

    static let summarizerMarker = "0. DIALOGUE WITH THE MAIN AGENT"
    static let oversizedMarker = "[OVERSIZED BATCH SUMMARY"
    static let retryMarker = "[CONTEXT LIMIT SUMMARY RETRY"
    static let roundLimitMarker = "[ROUND LIMIT SUMMARY REQUEST"
    static let contextLimitMarker = "[CONTEXT LIMIT]"

    func route(_ request: CapturedHTTPRequest) -> (body: String, delay: TimeInterval)? {
        let text = MidturnHarness.ppText(request.body)
        func reply(_ t: String?, _ calls: [Call] = [], prompt: Int = 100) -> (body: String, delay: TimeInterval) {
            (MidturnHarness.CompactionScript.reply(responses: false, text: t, calls: calls, tokens: prompt), 0)
        }
        lock.lock()
        _bodies.append(text)
        let n = _bodies.count
        let callback = _onRequest
        lock.unlock()
        callback?(n, text)
        if text.contains(Self.summarizerMarker) { return reply("PS_SUMMARY of the evicted work.") }
        if text.contains(Self.oversizedMarker) { return reply("PS_OVERSIZED summary.\n## Dialogue with the main agent\nTask.\n## Current progress and next action\nDone.") }
        if text.contains(Self.retryMarker) { return reply("PS_RETRY_FINAL") }
        if text.contains(Self.roundLimitMarker) { return reply("PS_ROUND_FINAL") }
        if text.contains(Self.contextLimitMarker) {
            lock.lock(); let calls = _contextLimitCalls; _contextLimitCalls = false; lock.unlock()
            return calls ? reply(nil, [(id: "ps-cl-\(n)", name: "read_file", args: ["path": "/nonexistent"])], prompt: 2000) : reply("PS_CONTEXT_FINAL")
        }
        lock.lock()
        let step = rounds.isEmpty ? nil : rounds.removeFirst()
        lock.unlock()
        guard let step else { return reply("PS_UNSCRIPTED") }
        return reply(step.text, step.calls, prompt: step.prompt)
    }
}

extension MidturnHarness {

    func ppSubagentSection() async throws {
        try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "1000")
        try AgentTurnOverrides.setOverride(4, forAgent: "general-purpose")
        defer {
            try? KeychainHelper.delete(key: KeychainHelper.subagentTurnTokenBudgetKey)
            try? AgentTurnOverrides.setOverride(nil, forAgent: "general-purpose")
            try? KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: "Fixture Assistant")
            AvailableTools.webSubagentStoredFlagOverrideForTesting = nil
            server.router = nil
        }
        await resetState()
        let router = PSRouter()
        server.router = { router.route($0) }
        let runner = SubagentRunner()
        let service = OpenRouterService(); await service.configure(apiKey: apiKey)
        let executor = ToolExecutor(outputMode: .subagent)
        let images = StoragePaths.dataRoot.appendingPathComponent("images")
        let documents = StoragePaths.dataRoot.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: StoragePaths.dataRoot, withIntermediateDirectories: true)
        let big = StoragePaths.dataRoot.appendingPathComponent("ps-big.txt")
        try Data(String(repeating: "PS_WORK_LINE padding padding padding\n", count: 55).utf8).write(to: big)
        let tiny = StoragePaths.dataRoot.appendingPathComponent("ps-tiny.txt")
        try Data("tiny\n".utf8).write(to: tiny)
        func readBig(_ id: String) -> PSRouter.Call { (id: id, name: "read_file", args: ["path": big.path]) }
        func run(_ type: String = "general-purpose", task: String, session: String? = nil) async -> SubagentRunner.RunResult {
            let invocation = SubagentRunner.Invocation(subagentType: type, description: "Persona fixture", taskPrompt: task,
                modelOverride: nil, runInBackground: false, deliverable: type == "Web" ? .short : nil)
            return await runner.run(invocation: invocation, sessionId: session, openRouterService: service, toolExecutor: executor,
                                    imagesDirectory: images, documentsDirectory: documents,
                                    parentTools: [AvailableTools.readFile] + AvailableTools.all(includeWebSearch: true))
        }
        func writeOnFirst(_ key: String, _ value: String) {
            router.onRequest = { n, _ in if n == 1 { try? KeychainHelper.save(key: key, value: value) } }
        }

        // S1: rounds, the ordinary summarizer (mid-run compaction) and the
        // round-limit forced final; the profile changes at the first round.
        let a = Self.ppSentinel("A"), b = Self.ppSentinel("B"), c = Self.ppSentinel("C")
        try ppSetProfile(Self.ppProfile(a))
        router.reset()
        writeOnFirst(KeychainHelper.structuredUserContextKey, Self.ppProfile(b))
        router.push([readBig("s1-1")], prompt: 100)
        router.push([readBig("s1-2")], prompt: 900)
        router.push([readBig("s1-3")], prompt: 100)
        router.push([readBig("s1-4")], prompt: 100)
        let s1 = await run(task: "Persona fixture task one")
        let b1 = router.bodies
        let roundBodies = b1.filter { !$0.contains(PSRouter.summarizerMarker) && !$0.contains(PSRouter.roundLimitMarker) }
        let summarizer = b1.filter { $0.contains(PSRouter.summarizerMarker) }
        let forced = b1.filter { $0.contains(PSRouter.roundLimitMarker) }
        check("P5a S1 crossed rounds, the ordinary summarizer and the round-limit forced final",
              s1.sessionPersisted && roundBodies.count >= 3 && summarizer.count >= 1 && forced.count == 1,
              "rounds \(roundBodies.count), summarizer \(summarizer.count), forced \(forced.count), error \(s1.error ?? "-")")
        check("P5b S1: every request of the run carries the run's persona, none the mid-run write",
              !b1.isEmpty && b1.allSatisfy { $0.contains(a) && !$0.contains(b) })
        let roundSystems = Set(roundBodies.compactMap { $0.data(using: .utf8).map(Self.ppSystem) })
        check("P5c S1: round requests share one system prompt", roundSystems.count == 1, "distinct \(roundSystems.count)")

        // S1': a resume recaptures (the store now holds B).
        router.reset()
        router.push([], text: "resumed answer", prompt: 100)
        let s1r = await run(task: "Persona fixture follow-up", session: s1.sessionId)
        check("P5d a resumed run sees the profile written during the previous run",
              s1r.error == nil && router.bodies.first.map { $0.contains(b) && !$0.contains(a) } == true, s1r.error ?? "")

        // S4: capture precedes the eager resume compaction. The resumed
        // session is oversized; the profile changes while the eager
        // summarizer runs; that summarizer and the continuation keep B.
        let rounds = (0..<10).map { i in
            ToolInteraction(assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: [
                ToolCall(id: "ps-eager-\(i)", type: "function", function: FunctionCall(name: "read_file", arguments: "{\"p\":\"\(i)\"}"))]),
                results: [ToolResultMessage(toolCallId: "ps-eager-\(i)", content: String(repeating: "e", count: 360))])
        }
        let exchanges = (0..<4).map { Message(role: $0 % 2 == 0 ? .user : .assistant, content: "eager exchange \($0)") }
        await SubagentSessionRegistry.shared.applyCompaction(sessionId: s1.sessionId, messages: exchanges, toolInteractions: rounds)
        router.reset()
        router.onRequest = { _, text in
            if text.contains(PSRouter.summarizerMarker) {
                try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: Self.ppProfile(c))
            }
        }
        router.push([], text: "eager continuation answer", prompt: 100)
        let s4 = await run(task: "Persona fixture eager resume", session: s1.sessionId)
        let b4 = router.bodies
        let eagerSummary = b4.first { $0.contains(PSRouter.summarizerMarker) }
        let continuation = b4.last { !$0.contains(PSRouter.summarizerMarker) }
        check("P5e eager resume compaction ran and carries the run's snapshot",
              s4.error == nil && eagerSummary.map { $0.contains(b) && !$0.contains(c) } == true, s4.error ?? "summarizer \(eagerSummary != nil)")
        check("P5f the continuation after it keeps the snapshot (the write during compaction is next run's)",
              continuation.map { $0.contains(b) && !$0.contains(c) } == true)

        // S2: the emergency summarizer (newest batch summarized), then the
        // context-limit forced final (no room left).
        try ppSetProfile(Self.ppProfile(a))
        router.reset()
        writeOnFirst(KeychainHelper.structuredUserContextKey, Self.ppProfile(b))
        router.push([readBig("s2-1")], prompt: 600)                                         // → emergency summary
        router.push([(id: "s2-2", name: "read_file", args: ["path": tiny.path])], prompt: 990)  // → context-limit final
        let s2 = await run(task: "Persona fixture task two")
        let b2 = router.bodies
        let oversized = b2.filter { $0.contains(PSRouter.oversizedMarker) }
        let contextFinal = b2.filter { $0.contains(PSRouter.contextLimitMarker) && !$0.contains(PSRouter.oversizedMarker) }
        check("P5g S2 crossed the emergency summarizer and the context-limit forced final",
              oversized.count >= 1 && contextFinal.count >= 1, "oversized \(oversized.count), final \(contextFinal.count), error \(s2.error ?? "-")")
        check("P5h S2: both carry the run's persona, none the mid-run write",
              !b2.isEmpty && b2.allSatisfy { $0.contains(a) && !$0.contains(b) })

        // S3: the Web researcher — the context-limit forced final and its
        // retry; a mid-run rename never reaches it; no profile at all.
        try ppSetProfile(Self.ppProfile(a))
        await executor.configure(openRouterKey: "", serperKey: "synthetic-serper-key", jinaKey: "synthetic-jina-key")
        AvailableTools.webSubagentStoredFlagOverrideForTesting = { true }
        let renamed = "Renamed-" + Self.ppSentinel("R")
        router.reset()
        router.contextLimitCalls = true
        writeOnFirst(KeychainHelper.assistantNameKey, renamed)
        router.push([], text: "answer without any retrieval", prompt: 2000)
        let s3 = await run("Web", task: "What is alpha?")
        let b3 = router.bodies
        let retries = b3.filter { $0.contains(PSRouter.retryMarker) }
        check("P5i Web: the nudge, the context-limit final and its retry ran",
              b3.count >= 3 && retries.count >= 1, "requests \(b3.count), retries \(retries.count), error \(s3.error ?? "-")")
        let webSystems = Set(b3.compactMap { $0.data(using: .utf8).map(Self.ppSystem) })
        check("P5j Web: one research prompt for the whole run, with the name captured at its start",
              webSystems.count == 1 && webSystems.first?.contains("You are the web research subagent of Fixture Assistant.") == true
                && b3.allSatisfy { !$0.contains(renamed) }, "distinct \(webSystems.count)")
        check("P5k Web: no profile line reaches the researcher", b3.allSatisfy { !$0.contains(a) })
        try KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: "Fixture Assistant")
        try ppSetProfile(nil)
    }
}
