import ArgumentParser
import Foundation

/// Hidden maintenance command: run a REAL web_search / web_research_sweep
/// end-to-end through the tool-calling agent loop with the configured keys.
/// Not part of CI (network + paid API calls) — used to verify the pipeline
/// against live gateways after changes. Prints the answer, sources, queries,
/// spend, and elapsed time.
struct WebLiveTest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__web-live-test",
        abstract: "Internal: run a live web research query through the agent loop.",
        shouldDisplay: false
    )

    @Argument(help: "The research question.")
    var query: String

    @Flag(name: .customLong("deep"), help: "Run web_research_sweep instead of web_search.")
    var deep = false

    @Flag(name: .customLong("researcher"), help: "Run the Web researcher subagent (the R2 default path) instead of the legacy loop.")
    var researcher = false

    @Option(name: .customLong("backend"), help: "Force a backend for this run (openai|opencode|openrouter); process-local, the stored selection is untouched.")
    var backend: String?

    func run() async throws {
        if let backend {
            guard let parsed = WebSearchBackend(rawValue: backend) else {
                throw ValidationError("Unknown backend '\(backend)'. Valid: openai, opencode, openrouter.")
            }
            // Process-local override: the old set/restore of the persisted
            // selection left the machine flipped if the test was killed
            // mid-run (and real searches during the window used the flipped
            // backend). This never touches stored prefs.
            WebSearchBackend.processOverride = parsed
        }

        let serperKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        let jinaKey = KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) ?? ""
        // BRIGLIA_TEST_OPENROUTER_KEY lets a one-off OpenRouter verification run
        // without persisting a key into secrets.json.
        let openRouterKey = ProcessInfo.processInfo.environment["BRIGLIA_TEST_OPENROUTER_KEY"]
            ?? KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? ""
        guard !serperKey.isEmpty else {
            throw ValidationError("No Serper key configured — run `briglia setup` first.")
        }

        let orchestrator = WebOrchestrator()
        await orchestrator.configure(openRouterKey: openRouterKey, serperKey: serperKey, jinaKey: jinaKey)

        if researcher {
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.webOrchestrator.configure(openRouterKey: openRouterKey, serperKey: serperKey, jinaKey: jinaKey)
            let service = OpenRouterService()
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-web-live-\(UUID().uuidString)")
            let images = scratch.appendingPathComponent("images"), documents = scratch.appendingPathComponent("documents")
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            print("=== Web researcher on backend \(WebSearchBackend.active.rawValue) ===")
            print("Q: \(query)\n")
            let start = Date()
            let result = await SubagentRunner().run(
                invocation: SubagentRunner.Invocation(subagentType: "Web", description: "live test", taskPrompt: query,
                                                      modelOverride: nil, runInBackground: false, deliverable: .short),
                sessionId: nil, openRouterService: service, toolExecutor: executor,
                imagesDirectory: images, documentsDirectory: documents,
                parentTools: AvailableTools.all(includeWebSearch: true))
            print(result.asJSON())
            print("\nelapsed: \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            if result.error != nil { throw ExitCode.failure }
            return
        }

        let mode = deep ? "web_research_sweep" : "web_search"
        print("=== \(mode) on backend \(WebSearchBackend.active.rawValue) ===")
        print("Q: \(query)\n")
        let start = Date()
        do {
            let result = deep
                ? try await orchestrator.executeDeepResearchForTool(query: query)
                : try await orchestrator.executeForTool(query: query)
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            print(result.summary)
            print("\n--- meta ---")
            print("elapsed: \(elapsed)s")
            print("queries (\(result.searchQueriesUsed.count)): \(result.searchQueriesUsed.joined(separator: " | "))")
            print("sources: \(result.sources.count)")
            if let spend = result.spendUSD {
                print(String(format: "spend: $%.4f", spend))
            }
        } catch {
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            print("FAILED after \(elapsed)s: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
