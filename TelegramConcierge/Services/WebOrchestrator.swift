import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OpenRouter Configuration for Web Search Pipeline
enum ORModel {
    // Agent loop and final answer run on the configured main model (default
    // GPT-5.6 Luna) in BOTH modes. The mechanical stages below also run on
    // Luna, at medium effort: benchmarked 2026-08-01 against gpt-oss-120b on
    // Groq, Luna is ~2x faster on 90k-token extraction inputs (prefill-bound)
    // and missed fewer excerpts. (Priced $0.10/$0.60 at benchmark time;
    // OpenAI doubled it to $0.20/$1.20 + a >272K-input surcharge on
    // 2026-08-03 — see openAIInputUSDPerMTok below.)
    // Its 1M window also lifts the 131k ceiling that forced small chunks.
    static let webExcerpts       = "openai/gpt-5.6-luna"
    static let deepExcerpt       = "openai/gpt-5.6-luna"
    /// web_fetch page compression: what this model drops from a page is
    /// invisible to the calling agent, so selection judgment matters here.
    static let webFetchCompression = "openai/gpt-5.6-luna"
    static let defaultMainModel  = KeychainHelper.defaultWebSearchModel
}

enum Endpoints {
    static let openrouter     = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    /// Agent rounds on the OpenAI backend: Luna rejects function tools +
    /// reasoning_effort on chat completions, so they go through Responses.
    static let openaiResponses = URL(string: "https://api.openai.com/v1/responses")!
    static let serperSearch   = URL(string: "https://google.serper.dev/search")!
    static let jinaReaderBase = "https://r.jina.ai/"
}

// MARK: - Web Search Backend
/// Which gateway serves every LLM call in the web pipeline. Selected in
/// onboarding and Settings ("Ricerca e lettura") via `selectionKey`.
enum WebSearchBackend: String {
    case openrouter   // current OpenRouter envelope, models as configured
    case openai       // api.openai.com — same models, native slugs (no "openai/" prefix)
    case opencode     // default — OpenCode Go, mimo-v2.5 on every stage (huge usage limits, slower)

    static let selectionKey = "ada.webSearchBackend"

    /// Process-local override for the __web-live-test harness. Never
    /// persisted, so a killed test run cannot leave the machine's stored
    /// selection flipped (the old UserDefaults set/restore dance could).
    static var processOverride: WebSearchBackend?

    static var active: WebSearchBackend {
        resolve(
            override: processOverride,
            stored: UserDefaults.standard.string(forKey: selectionKey),
            hasOpenAIKey: !storedKey(for: .openai).isEmpty,
            hasLegacyOpenRouterKey: !(KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? "").isEmpty
        )
    }

    /// The VALID saved choice, or nil when the backend is being inferred.
    /// An unparseable stored value is not explicit — resolve() ignores it,
    /// so /websearch and doctor must not present it as a saved choice.
    static var explicitlyStored: WebSearchBackend? {
        UserDefaults.standard.string(forKey: selectionKey)
            .flatMap(WebSearchBackend.init(rawValue:))
    }

    /// Pure resolution logic, separated so the selftest can exercise every
    /// combination without touching the machine's real preferences.
    ///
    /// No stored choice means the wizard's write went missing (prefs loss,
    /// partial restore, install predating the backend picker). Infer what
    /// the wizard would have stored: step 2 (mandatory OpenAI key) writes
    /// "openai", so an OpenAI key is the strongest signal — checking only
    /// the legacy OpenRouter key here used to silently downgrade such
    /// machines to OpenCode/mimo (hit live, 2026-08-16).
    static func resolve(
        override: WebSearchBackend?,
        stored: String?,
        hasOpenAIKey: Bool,
        hasLegacyOpenRouterKey: Bool
    ) -> WebSearchBackend {
        if let override { return override }
        if let stored, let parsed = WebSearchBackend(rawValue: stored) { return parsed }
        if hasOpenAIKey { return .openai }
        return hasLegacyOpenRouterKey ? .openrouter : .opencode
    }

    /// The credential each backend would use, from stored settings alone.
    /// Mirrors WebOrchestrator.apiKey(for:) minus that instance's in-memory
    /// OpenRouter key (which can carry an env-var override for live tests).
    static func storedKey(for backend: WebSearchBackend) -> String {
        func first(_ keys: String...) -> String {
            for key in keys {
                if let value = KeychainHelper.load(key: key), !value.isEmpty { return value }
            }
            return ""
        }
        switch backend {
        case .openrouter:
            return first(KeychainHelper.openRouterApiKeyKey)
        case .openai:
            return first(KeychainHelper.webSearchOpenAIApiKeyKey,
                         KeychainHelper.openAITranscriptionApiKeyKey,
                         KeychainHelper.openAIImageApiKeyKey)
        case .opencode:
            let dedicated = first(KeychainHelper.webSearchOpenCodeApiKeyKey)
            if !dedicated.isEmpty { return dedicated }
            // The saved OpenCode provider profile is the durable credential:
            // the runtime slot below only holds it while OpenCode is the
            // ACTIVE main provider, so an opencode web selection must not
            // lose its key when the main agent hops to another provider.
            let profileKey = first(ProviderProfiles.opencodeApiKeyKey)
            if !profileKey.isEmpty { return profileKey }
            let mainBase = KeychainHelper.load(key: KeychainHelper.openAICompatibleBaseURLKey) ?? ""
            if SessionAffinity.isOpenCodeBaseURL(mainBase) {
                return first(KeychainHelper.openAICompatibleApiKeyKey)
            }
            return ""
        }
    }

    var displayName: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .openai:     return "OpenAI"
        case .opencode:   return "OpenCode Go"
        }
    }

    /// What actually answers searches on this backend — shown by /websearch.
    var modelSummary: String {
        switch self {
        case .openrouter: return "configured models via openrouter.ai"
        case .openai:     return "GPT-5.6 Luna via api.openai.com"
        case .opencode:   return "mimo-v2.5 (slower, huge usage limits)"
        }
    }

    var endpoint: URL {
        // Development builds may point a backend at a local capture server
        // (affinity selftest); release builds ignore the variables.
        if adaCLIVersion.hasSuffix("-dev") {
            let env = ProcessInfo.processInfo.environment
            switch self {
            case .opencode:
                if let raw = env["BRIGLIA_DEV_AFFINITY_OPENCODE_BASE"], !raw.isEmpty, let url = URL(string: raw + "/zen/go/v1/chat/completions") { return url }
            case .openrouter:
                if let raw = env["BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE"], !raw.isEmpty, let url = URL(string: raw + "/api/v1/chat/completions") { return url }
            case .openai:
                break
            }
        }
        switch self {
        case .openrouter: return Endpoints.openrouter
        case .openai:     return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .opencode:   return URL(string: "https://opencode.ai/zen/go/v1/chat/completions")!
        }
    }

    /// Whether extraction stages attach strict `response_format`. OpenAI
    /// enforces it (verified), OpenRouter forwards it to supporting
    /// providers; OpenCode's mimo ignores it (probed 2026-08-16), so sending
    /// it there is pointless.
    var supportsResponseFormat: Bool { self != .opencode }
}

struct ProviderSettings {
    static let only = ["groq", "google-vertex"]
    static let order: [String]? = nil
    static let allowFallbacks = true
}

// MARK: - Reasoning Configuration
enum ReasoningEffort {
    case off
    case minimal, low, medium, high
    case budgetTokens(Int)
}

struct ReasoningSettings {
    static var agent:    ReasoningEffort = .medium
    static var excerpts: ReasoningEffort = .medium
    static var finalAns: ReasoningEffort = .medium
}

func makeReasoning(_ r: ReasoningEffort) -> ORChatReq.Reasoning? {
    switch r {
    case .off: return nil
    case .minimal: return .init(effort: "minimal", max_tokens: nil, exclude: true)
    case .low:    return .init(effort: "low",    max_tokens: nil, exclude: true)
    case .medium: return .init(effort: "medium", max_tokens: nil, exclude: true)
    case .high:   return .init(effort: "high",   max_tokens: nil, exclude: true)
    case .budgetTokens(let n): return .init(effort: nil, max_tokens: n, exclude: true)
    }
}

private func parseReasoningEffort(_ rawValue: String?) -> ReasoningEffort {
    let value = (rawValue ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    switch value {
    case "minimal":
        return .minimal
    case "low":
        return .low
    case "medium":
        return .medium
    case "high":
        return .high
    default:
        // Keep aligned with OpenRouterService fallback when setting is missing.
        return .high
    }
}

enum ResearchMode {
    case webSearch
    case deepResearch
}

// MARK: - OpenRouter Types for Pipeline
struct ORChatReq: Encodable {
    struct Msg: Encodable {
        let role: String
        /// Nil on assistant messages that carry only tool calls. Synthesized
        /// Encodable omits nil optionals, which is what the gateways expect.
        let content: String?
        var tool_calls: [ORToolCall]? = nil
        var tool_call_id: String? = nil
        /// Reasoning replay: OpenRouter returns/accepts `reasoning` and
        /// structured `reasoning_details` (which can carry provider
        /// signatures that MUST be replayed unchanged during tool use);
        /// OpenCode-style gateways use `reasoning_content`. All are kept as
        /// JSONValue and replayed verbatim, mirroring the main-agent
        /// transport (OpenRouterAPIMessage).
        var reasoning: JSONValue? = nil
        var reasoning_details: JSONValue? = nil
        var reasoning_content: JSONValue? = nil
    }
    struct Reasoning: Encodable {
        let effort: String?
        let max_tokens: Int?
        let exclude: Bool?
    }
    struct Provider: Encodable {
        let order: [String]?
        let only: [String]?
        let allow_fallbacks: Bool?
        let sort: String?
    }
    let model: String
    let messages: [Msg]
    let max_tokens: Int?
    /// OpenAI-direct only: their reasoning models reject max_tokens.
    let max_completion_tokens: Int?
    let temperature: Double?
    let stream: Bool?
    let reasoning: Reasoning?
    /// OpenAI/OpenCode shape: top-level effort string instead of the object.
    let reasoning_effort: String?
    let provider: Provider?
    /// Native function calling for agent rounds (see WebAgentLoop.swift).
    var tools: [ORToolDef]? = nil
    var tool_choice: String? = nil
    /// Strict structured outputs for the extraction stages.
    var response_format: ORResponseFormat? = nil
}

struct ORChatResp: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: String?
            let tool_calls: [ORToolCall]?
            let reasoning: JSONValue?
            let reasoning_details: JSONValue?
            let reasoning_content: JSONValue?
        }
        let message: Message
        let finish_reason: String?
        let native_finish_reason: String?
    }
    let choices: [Choice]
    let usage: OpenRouterUsage?
    /// OpenRouter names the upstream provider that served the call; OpenAI
    /// and OpenCode omit it.
    let provider: String?
}

struct ScrapeRequest: Codable {
    let url: String
    let focus: String
}

// MARK: - Serper Types
struct SerperSearchReq: Encodable { let q: String; let num: Int; let autocorrect: Bool = true }
struct SerperSearchResp: Decodable {
    struct Organic: Decodable { let title: String?; let link: String?; let snippet: String?; let date: String? }
    struct PAA: Decodable { let question: String?; let snippet: String?; let title: String?; let link: String? }
    struct Top: Decodable { let title: String?; let link: String?; let source: String?; let date: String? }
    struct AnswerBox: Decodable { let answer: String?; let snippet: String?; let title: String?; let link: String?; let type: String? }
    struct KG: Decodable { let title: String?; let type: String?; let description: String?; let source: String?; let url: String? }
    let organic: [Organic]?
    let peopleAlsoAsk: [PAA]?
    let topStories: [Top]?
    let answerBox: AnswerBox?
    let knowledgeGraph: KG?
}

struct ExcerptOut: Decodable { let excerpts: [String] }

struct RelevantAssetOut: Decodable {
    struct Link: Decodable {
        let text: String?
        let url: String?
    }

    struct Image: Decodable {
        let caption: String?
        let url: String?
    }

    let links: [Link]?
    let images: [Image]?
}

// MARK: - Web Context Types
struct WebContext: Codable {
    var queries_used: [QueryRecord]
    var results: [WebResult]
    var answerBox: WebAnswerBox?
    var knowledgeGraph: WebKG?
    var peopleAlsoAsk: [WebPAA]?
    var topStories: [WebTop]?
    var scraped: [ScrapedDoc]
    
    static func empty() -> WebContext {
        WebContext(queries_used: [], results: [], answerBox: nil, knowledgeGraph: nil, peopleAlsoAsk: nil, topStories: nil, scraped: [])
    }
    
    func clamped(to maxBytes: Int) -> WebContext {
        var t = self
        func size(_ x: WebContext) -> Int { (try? JSONEncoder().encode(x).count) ?? .max }
        if size(t) <= maxBytes { return t }
        if t.results.count > 8 { t.results = Array(t.results.prefix(8)) }
        if size(t) <= maxBytes { return t }
        t.peopleAlsoAsk = nil; t.topStories = nil
        if size(t) <= maxBytes { return t }
        t.results = Array(t.results.prefix(5))
        return t
    }
    
    mutating func merge(with other: WebContext, maxBytes: Int) {
        let have = Set(self.results.map { $0.link })
        let add = other.results.filter { !have.contains($0.link) }
        self.results.append(contentsOf: add.prefix(40 - self.results.count))
        self.queries_used.append(contentsOf: other.queries_used)
        if self.answerBox == nil { self.answerBox = other.answerBox }
        if self.knowledgeGraph == nil { self.knowledgeGraph = other.knowledgeGraph }
        var paa = (self.peopleAlsoAsk ?? []) + (other.peopleAlsoAsk ?? [])
        if paa.count > 8 { paa = Array(paa.prefix(8)) }
        self.peopleAlsoAsk = paa.isEmpty ? nil : paa
        var ts = (self.topStories ?? []) + (other.topStories ?? [])
        if ts.count > 8 { ts = Array(ts.prefix(8)) }
        self.topStories = ts.isEmpty ? nil : ts
        self = self.clamped(to: maxBytes)
    }
}

struct QueryRecord: Codable { let query: String; let retrievedAtStep: Int }
struct WebResult: Codable { let title: String; let snippet: String; let link: String; let source: String; let date: String?; let retrievedAtStep: Int }
struct WebAnswerBox: Codable { let answer: String?; let snippet: String?; let title: String?; let link: String?; let type: String?
    init(_ x: SerperSearchResp.AnswerBox) { answer = x.answer; snippet = x.snippet; title = x.title; link = x.link; type = x.type }
}
struct WebKG: Codable { let title: String?; let type: String?; let description: String?; let source: String?; let url: String?
    init(_ x: SerperSearchResp.KG) { title = x.title; type = x.type; description = x.description; source = x.source; url = x.url }
}
struct WebPAA: Codable { let question: String?; let snippet: String?; let title: String?; let link: String?
    init(_ x: SerperSearchResp.PAA) { question = x.question; snippet = x.snippet; title = x.title; link = x.link }
}
struct WebTop: Codable { let title: String?; let link: String?; let source: String?; let date: String?
    init(_ x: SerperSearchResp.Top) { title = x.title; link = x.link; source = x.source; date = x.date }
}
struct ScrapedDoc: Codable {
    let url: String
    let source: String
    let title: String?
    let excerpts: [String]
    let links: [ExtractedLink]
    let images: [ExtractedImage]
    let retrievedAtStep: Int

    enum CodingKeys: String, CodingKey {
        case url, source, title, excerpts, links, images, retrievedAtStep
    }

    init(
        url: String,
        source: String,
        title: String?,
        excerpts: [String],
        links: [ExtractedLink] = [],
        images: [ExtractedImage] = [],
        retrievedAtStep: Int
    ) {
        self.url = url
        self.source = source
        self.title = title
        self.excerpts = excerpts
        self.links = links
        self.images = images
        self.retrievedAtStep = retrievedAtStep
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.source = try container.decode(String.self, forKey: .source)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.excerpts = try container.decodeIfPresent([String].self, forKey: .excerpts) ?? []
        self.links = try container.decodeIfPresent([ExtractedLink].self, forKey: .links) ?? []
        self.images = try container.decodeIfPresent([ExtractedImage].self, forKey: .images) ?? []
        self.retrievedAtStep = try container.decode(Int.self, forKey: .retrievedAtStep)
    }
}

// MARK: - URL Reading Types (for web_fetch tool)

struct JinaReaderResult: Codable {
    let url: String
    let title: String?
    let content: String
    let links: [ExtractedLink]
    let images: [ExtractedImage]

    func asJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"url\": \"\(url)\", \"error\": \"Failed to encode result\"}"
        }
        return json
    }
}

struct ExtractedLink: Codable {
    let text: String
    let url: String
}

struct ExtractedImage: Codable {
    let caption: String
    let url: String?
}

// MARK: - Web Orchestrator
struct ResearchExecutionError: LocalizedError {
    let underlyingError: Error
    let spendUSD: Double

    var errorDescription: String? {
        underlyingError.localizedDescription
    }
}

actor WebOrchestrator {
    enum ProgressStage: String {
        case planning   = "Planning..."
        case searching  = "Searching..."
        case scraping   = "Scraping..."
        case analyzing  = "Analyzing..."
        case answering  = "Generating Answer..."
    }
    
    var onProgress: ((ProgressStage) -> Void)?
    
    private var openRouterApiKey: String = ""
    private var serperApiKey: String = ""
    private var jinaApiKey: String = ""
    
    private let maxWebSearchSteps = 5
    private let maxDeepResearchSteps = 6
    private let perQueryDepth = 10
    private let maxContextBytes = 300_000
    private let excerptThreshold = 8_000
    private let chunkSizeChars = 800_000
    private let maxChunksForExtraction = 5
    private let chunkOverlapChars = 4_000
    /// web_fetch chunking: 800K chars ≈ 230k tokens — comfortable in Luna's 1M
    /// window with prompt and output. (Was 300K under gpt-oss's 131k window.)
    private let webFetchChunkChars = 800_000
    private let webFetchMaxChunks = 5
    private let webFetchNoContentSentinel = "NO_RELEVANT_CONTENT"
    
    private struct ExecutionState {
        var queriesUsed: [String] = []
        var spendUSD: Double = 0
    }

    private var executionStates: [UUID: ExecutionState] = [:]

    // MARK: - web_fetch Cache
    // Two-tier LRU cache with 15-minute TTL (matches Claude Code WebFetch behavior).
    // Tier 1: url -> raw Jina markdown (shared across different prompts on same URL).
    // Tier 2: (url, prompt) -> compressed excerpt (fast repeat hits).
    private struct CachedMarkdown {
        let title: String?
        let markdown: String
        let cachedAt: Date
    }
    private struct CachedExcerpt {
        let payload: JinaReaderResult
        let cachedAt: Date
    }
    private let webFetchCacheTTL: TimeInterval = 15 * 60
    private let webFetchCacheCapacity = 64
    private var markdownCache: [String: CachedMarkdown] = [:]
    private var excerptCache: [String: CachedExcerpt] = [:]

    private func prunedMarkdownCache() {
        let now = Date()
        markdownCache = markdownCache.filter { now.timeIntervalSince($0.value.cachedAt) < webFetchCacheTTL }
        if markdownCache.count > webFetchCacheCapacity {
            let sorted = markdownCache.sorted { $0.value.cachedAt < $1.value.cachedAt }
            for (k, _) in sorted.prefix(markdownCache.count - webFetchCacheCapacity) {
                markdownCache.removeValue(forKey: k)
            }
        }
    }
    private func prunedExcerptCache() {
        let now = Date()
        excerptCache = excerptCache.filter { now.timeIntervalSince($0.value.cachedAt) < webFetchCacheTTL }
        if excerptCache.count > webFetchCacheCapacity {
            let sorted = excerptCache.sorted { $0.value.cachedAt < $1.value.cachedAt }
            for (k, _) in sorted.prefix(excerptCache.count - webFetchCacheCapacity) {
                excerptCache.removeValue(forKey: k)
            }
        }
    }

    // MARK: - Configuration
    
    func configure(openRouterKey: String, serperKey: String, jinaKey: String) {
        self.openRouterApiKey = openRouterKey
        self.serperApiKey = serperKey
        self.jinaApiKey = jinaKey
    }
    
    // MARK: - Tool Interface
    
    /// Execute web search as a tool and return a condensed result for the main LLM
    func executeForTool(query: String) async throws -> WebSearchResult {
        try await executeForTool(query: query, mode: .webSearch)
    }

    /// Execute deep research as a tool and return a detailed result for the main LLM
    func executeDeepResearchForTool(query: String) async throws -> WebSearchResult {
        try await executeForTool(query: query, mode: .deepResearch)
    }

    private func executeForTool(query: String, mode: ResearchMode) async throws -> WebSearchResult {
        let executionID = UUID()
        executionStates[executionID] = ExecutionState()

        do {
            let answer = try await answer(
                userPrompt: query,
                historyPairs: [],
                mode: mode,
                executionID: executionID
            )
            let state = executionStates.removeValue(forKey: executionID) ?? ExecutionState()

            // Extract source URLs from the answer (angle brackets, markdown
            // links, or bare URLs — the extractor accepts all three)
            let sources = extractSourceURLs(from: answer)

            return WebSearchResult(
                summary: answer,
                sources: sources,
                searchQueriesUsed: state.queriesUsed,
                spendUSD: state.spendUSD > 0 ? state.spendUSD : nil
            )
        } catch {
            let state = executionStates.removeValue(forKey: executionID) ?? ExecutionState()
            throw ResearchExecutionError(underlyingError: error, spendUSD: state.spendUSD)
        }
    }
    
    private func extractSourceURLs(from text: String) -> [String] {
        // The prompts ask for <https://…>, but models routinely emit markdown
        // links or bare URLs instead — accept all three so `sources` doesn't
        // depend on prompt compliance. (Field-found by Briglia: web_search answers
        // used [title](url) and the angle-only regex returned zero sources on
        // every search.)
        let patterns = [
            "<(https?://[^>\\s]+)>",              // <https://example.com>
            "\\]\\((https?://[^)\\s]+)\\)",       // [title](https://example.com)
            "(?<![<(\\]])(https?://[^\\s<>()\\[\\]\"']+)"  // bare URL in prose
        ]
        var seen = Set<String>()
        var ordered: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let urlRange = Range(match.range(at: 1), in: text) else { continue }
                var url = String(text[urlRange])
                // Sentence punctuation glued to bare URLs ("…vedi example.com.")
                while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
                if seen.insert(url).inserted { ordered.append(url) }
            }
        }
        return ordered
    }
    
    // MARK: - Main Entry Point
    //
    // Native tool-calling agent loop. The model
    // drives real function calls; a text response without tool calls IS the
    // final answer. The old JSON-in-content protocol, its scratchpad, and the
    // separate final-answer stage are gone — the transcript is the memory.
    func answer(
        userPrompt: String,
        historyPairs: [(user: String, assistant: String)],
        mode: ResearchMode = .webSearch,
        executionID: UUID
    ) async throws -> String {
        let backend = WebSearchBackend.active
        let userContent = buildConversationContext(historyPairs: historyPairs, currentQuestion: userPrompt)
        let maxRounds = maxSteps(for: mode)
        let systemPrompt = agentSystemPrompt(mode: mode, maxRounds: maxRounds)

        // One transcript per transport: Responses API for OpenAI (function
        // tools + reasoning are chat-completions-incompatible for Luna, and
        // Responses adds encrypted-reasoning continuity), chat completions
        // with tools for OpenRouter/OpenCode.
        let chat: WebAgentChatTranscript?
        let responses: WebAgentResponsesTranscript?
        if backend == .openai {
            chat = nil
            responses = WebAgentResponsesTranscript(instructions: systemPrompt, user: userContent)
        } else {
            chat = WebAgentChatTranscript(system: systemPrompt, user: userContent)
            responses = nil
        }
        func appendUser(_ text: String) {
            chat?.appendUser(text)
            responses?.appendUser(text)
        }

        // Distinguishes "searched and found nothing" (a valid outcome) from
        // "never searched at all" (the empty-report bug class).
        var webActionsAttempted = false
        var nudgedForZeroSearches = false
        var anyResultsRetrieved = false
        var pipelineFailures: [String] = []
        var seenLinks = Set<String>()

        var round = 0
        while round < maxRounds {
            round += 1
            try Task.checkCancellation()
            onProgress?(round == 1 ? .planning : .analyzing)

            let agentRound: WebAgentRound
            do {
                agentRound = try await callAgentRound(
                    chat: chat,
                    responses: responses,
                    mode: mode,
                    toolChoice: nil,
                    stage: "agent.round\(round)",
                    executionID: executionID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A failed round after context has been gathered should not
                // discard that work: salvage by forcing the final answer.
                guard anyResultsRetrieved else { throw error }
                webLog("[WebOrchestrator] agent.round\(round) failed (\(error.localizedDescription)); forcing final answer from gathered context")
                appendUser("(A research step failed: \(error.localizedDescription). Write the final answer now using everything gathered so far; no more tool calls are available.)")
                return try await forcedFinalAnswer(chat: chat, responses: responses, mode: mode, executionID: executionID)
            }

            if agentRound.toolCalls.isEmpty {
                // Text without tool calls: the final answer — subject to the
                // zero-search and broken-plumbing guards.
                if !webActionsAttempted {
                    if !nudgedForZeroSearches && round < maxRounds {
                        nudgedForZeroSearches = true
                        webLog("[WebOrchestrator] agent.round\(round) ZERO_SEARCHES: concluded without attempting any search — re-prompting once")
                        appendUser("(No search has been attempted yet. You must issue at least one search tool call before the final answer can be produced.)")
                        continue
                    }
                    webLog("[WebOrchestrator] ZERO_SEARCHES: \(modeLabel(mode)) ended without any search attempted — failing instead of answering")
                    throw NSError(domain: "WebOrchestrator", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "The research agent ended without attempting a single web search, even after a re-prompt. Retry the operation."
                    ])
                }
                try throwIfOnlyFailures(anyResultsRetrieved: anyResultsRetrieved, pipelineFailures: pipelineFailures)
                return agentRound.visibleText
            }

            // Execute this round's tool calls CONCURRENTLY (each also fans
            // out internally), then render results sequentially in call
            // order so cross-round dedup stays deterministic.
            let calls = agentRound.toolCalls
            if calls.contains(where: { $0.name.lowercased() == WebAgentTools.searchName }) { onProgress?(.searching) }
            if calls.contains(where: { $0.name.lowercased() == WebAgentTools.fetchName }) { onProgress?(.scraping) }
            var networkResults = [AgentToolNetworkResult?](repeating: nil, count: calls.count)
            try await withThrowingTaskGroup(of: (Int, AgentToolNetworkResult).self) { group in
                for (index, call) in calls.enumerated() {
                    group.addTask {
                        (index, try await self.performAgentToolNetwork(call, round: round, mode: mode, executionID: executionID))
                    }
                }
                for try await (index, result) in group {
                    networkResults[index] = result
                }
            }
            for (index, call) in calls.enumerated() {
                guard let network = networkResults[index] else { continue }
                let outcome = renderAgentToolOutcome(network, seenLinks: seenLinks, executionID: executionID)
                seenLinks = outcome.seenLinks
                if outcome.attemptedWebAction { webActionsAttempted = true }
                if outcome.gotResults { anyResultsRetrieved = true }
                pipelineFailures.append(contentsOf: outcome.failures)
                chat?.appendToolResult(callID: call.id, content: outcome.payload)
                responses?.appendToolResult(callID: call.id, content: outcome.payload)
            }
        }

        // Round budget exhausted with the model still calling tools: force
        // the final answer over everything gathered.
        if !webActionsAttempted {
            webLog("[WebOrchestrator] ZERO_SEARCHES: \(modeLabel(mode)) exhausted rounds without any search attempted — failing instead of answering")
            throw NSError(domain: "WebOrchestrator", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "The research agent ended without attempting a single web search. Retry the operation."
            ])
        }
        try throwIfOnlyFailures(anyResultsRetrieved: anyResultsRetrieved, pipelineFailures: pipelineFailures)
        appendUser("(Research budget exhausted. Write the final answer now using everything gathered so far; no more tool calls are available.)")
        return try await forcedFinalAnswer(chat: chat, responses: responses, mode: mode, executionID: executionID)
    }

    /// Nothing was retrieved AND at least one action failed: answering now
    /// would fabricate an "I found nothing" from broken plumbing. Report the
    /// real failures instead so the caller (and the user) can see the cause.
    private func throwIfOnlyFailures(anyResultsRetrieved: Bool, pipelineFailures: [String]) throws {
        guard !anyResultsRetrieved, !pipelineFailures.isEmpty else { return }
        let summary = pipelineFailures.prefix(5).joined(separator: "; ")
        throw NSError(domain: "WebOrchestrator", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "No web results could be retrieved. Failures: \(summary)"
        ])
    }

    /// Final answer with tool calls disabled (`tool_choice: "none"`), used
    /// when the round budget runs out or a round fails after context exists.
    private func forcedFinalAnswer(
        chat: WebAgentChatTranscript?,
        responses: WebAgentResponsesTranscript?,
        mode: ResearchMode,
        executionID: UUID
    ) async throws -> String {
        onProgress?(.answering)
        let round = try await callAgentRound(
            chat: chat,
            responses: responses,
            mode: mode,
            toolChoice: "none",
            stage: "agent.final",
            executionID: executionID
        )
        let text = round.visibleText
        guard !text.isEmpty else {
            throw NSError(domain: "WebOrchestrator", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "The research agent produced no final answer after its tool budget was exhausted."
            ])
        }
        return text
    }

    private func appendQueriesUsed(_ queries: [String], executionID: UUID) {
        guard !queries.isEmpty else { return }
        var state = executionStates[executionID] ?? ExecutionState()
        state.queriesUsed.append(contentsOf: queries)
        executionStates[executionID] = state
    }

    private func addSpend(_ amountUSD: Double?, executionID: UUID) {
        guard let amountUSD, amountUSD.isFinite, amountUSD > 0 else { return }
        var state = executionStates[executionID] ?? ExecutionState()
        state.spendUSD += amountUSD
        executionStates[executionID] = state
    }
    
    // MARK: - Agent System Prompts

    private func agentSystemPrompt(mode: ResearchMode, maxRounds: Int) -> String {
        if mode == .deepResearch {
            return """
            **Today is: \(nowStamp())**

            You are a deep research agent. Research the user's question thoroughly with the tools, then write the final report.

            ## HOW TO WORK
            - You have a budget of \(maxRounds) tool rounds; several tool calls fit in one round.
            - With every tool call, write a one-line visible note on what you are doing and why — it stays in the conversation and keeps the research coherent.
            - When research is complete, write the final report as a normal message with NO tool calls. A message without tool calls ends the research.
            - You must attempt at least one search before writing the report.

            ## DEEP RESEARCH STRATEGY
            1. Create a broad plan, then systematically cover subtopics.
            2. Seek primary/high-quality sources and triangulate key claims.
            3. Actively search for conflicting or limiting evidence.
            4. Keep collecting until major gaps are resolved across scope, evidence quality, and recency.

            ## FINAL REPORT CONTRACT
            - Detailed, complete, and long (not concise); cover the topic comprehensively across major subtopics.
            - Explain important nuance, caveats, and uncertainty; compare conflicting evidence when present.
            - Prefer recent and high-quality sources where appropriate.
            - Cite source URLs in angle brackets like <https://example.com> so claims can be verified. Never invent citations — only URLs that appeared in tool results.
            - End with a substantial "Sources" section listing all cited URLs.
            """
        }

        return """
        **Today is: \(nowStamp())**

        You are a research agent. Answer the user's question by researching the live web with the tools, then write the final answer.

        ## HOW TO WORK
        - You have a budget of \(maxRounds) tool rounds; use as few as the question needs. Several tool calls fit in one round.
        - With every tool call, write a one-line visible note on what you are doing and why — it stays in the conversation and keeps the research coherent.
        - When you have enough information, write the final answer as a normal message with NO tool calls. A message without tool calls ends the research.
        - You must attempt at least one search before answering.

        ## FINAL ANSWER CONTRACT
        - Concise and direct; if sources conflict, note it briefly.
        - Prefer recent sources when appropriate.
        - Cite source URLs in angle brackets like <https://example.com> so claims can be verified. Never invent citations — only URLs that appeared in tool results.
        - End with a "Sources" list of all cited URLs.
        """
    }

    private func buildConversationContext(historyPairs: [(user: String, assistant: String)], currentQuestion: String) -> String {
        var context = ""
        if !historyPairs.isEmpty {
            context += "### Previous Conversation\n\n"
            for (i, pair) in historyPairs.enumerated() {
                context += "User (\(i + 1)): \(pair.user)\nAssistant (\(i + 1)): \(pair.assistant)\n\n"
            }
        }
        context += "### Current Question\n\n\(currentQuestion)"
        return context
    }
    
    // MARK: - Agent Rounds (native tool calling)

    private func callAgentRound(
        chat: WebAgentChatTranscript?,
        responses: WebAgentResponsesTranscript?,
        mode: ResearchMode,
        toolChoice: String?,
        stage: String,
        executionID: UUID
    ) async throws -> WebAgentRound {
        if let stub = agentRoundStubForTesting {
            return try await stub(stage, toolChoice)
        }
        if let responses {
            return try await callResponsesRound(
                responses, mode: mode, toolChoice: toolChoice, stage: stage, executionID: executionID)
        }
        guard let chat else {
            throw NSError(domain: "WebOrchestrator", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Internal error: no agent transcript for backend \(WebSearchBackend.active.rawValue)"
            ])
        }
        return try await callChatRound(
            chat, mode: mode, toolChoice: toolChoice, stage: stage, executionID: executionID)
    }

    /// Agent round over chat completions (openrouter / opencode backends).
    /// A valid round has tool calls and/or non-empty content; anything else
    /// is retried, then thrown.
    private func callChatRound(
        _ transcript: WebAgentChatTranscript,
        mode: ResearchMode,
        toolChoice: String?,
        stage: String,
        executionID: UUID
    ) async throws -> WebAgentRound {
        let backend = WebSearchBackend.active
        let agentMdl = agentModel(for: mode)
        // Deep-research rounds and the forced final answer reason over a
        // large transcript — same generous non-retried ceiling as before;
        // standard rounds keep the fast retried default.
        let generous = mode == .deepResearch || stage == "agent.final"

        // Agent rounds REPLAY reasoning across tool calls, so it must come
        // back in the response: strip the exclude flag the mechanical stages
        // use (on OpenRouter, exclude:true lets the model reason but returns
        // nothing to replay — reasoning continuity would silently die).
        var body = buildChatBody(
            backend: backend,
            stage: stage,
            mode: mode,
            model: agentMdl,
            messages: transcript.messages,
            maxTokens: 32000,
            reasoning: WebAgentSupport.includedInResponse(agentReasoning(for: mode)),
            provider: providerPreferences(forModel: agentMdl),
            temperature: 0.7,
            responseFormat: nil
        )
        body.tools = WebAgentTools.chatTools
        body.tool_choice = toolChoice

        let maxAttempts = 3
        var attempt = 1
        var droppedReasoning = false
        while true {
            let data: Data
            do {
                data = try await httpJSONPostWithRetry(
                    url: backend.endpoint,
                    body: body,
                    headers: try requestHeaders(for: backend, url: backend.endpoint, lane: .ephemeral(executionID)),
                    timeout: generous ? 600 : 120,
                    label: "\(backend.rawValue) \(stage)",
                    retryTimeouts: !generous
                )
            } catch let httpError as HTTPError where httpError.statusCode == 400 && !droppedReasoning {
                // Some gateways reject function tools combined with reasoning
                // parameters (OpenAI chat completions does for Luna). Retry
                // once without reasoning rather than failing the research.
                let detail = httpError.localizedDescription.lowercased()
                guard detail.contains("reasoning"), body.reasoning != nil || body.reasoning_effort != nil else {
                    throw httpError
                }
                droppedReasoning = true
                webLog("[WebOrchestrator] \(stage) REASONING_DROPPED_FOR_TOOLS backend=\(backend.rawValue): \(httpError.localizedDescription.prefix(200))")
                body = ORChatReq(
                    model: body.model, messages: body.messages, max_tokens: body.max_tokens,
                    max_completion_tokens: body.max_completion_tokens, temperature: body.temperature,
                    stream: body.stream, reasoning: nil, reasoning_effort: nil, provider: body.provider,
                    tools: body.tools, tool_choice: body.tool_choice, response_format: nil)
                continue
            }

            if let resp = try? JSONDecoder().decode(ORChatResp.self, from: data),
               let choice = resp.choices.first {
                let message = choice.message
                let content = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let toolCalls = (message.tool_calls ?? []).map {
                    WebAgentToolCall(id: $0.id, name: $0.function.name, argumentsJSON: $0.function.arguments)
                }
                let finish = choice.finish_reason ?? "nil"
                let promptTok = resp.usage?.promptTokens.map(String.init) ?? "?"
                let completionTok = resp.usage?.completionTokens.map(String.init) ?? "?"
                webLog("[WebOrchestrator] \(backend.rawValue) response stage=\(stage) mode=\(modeLabel(mode)) content_chars=\(content.count) tool_calls=\(toolCalls.count) finish=\(finish) provider=\(resp.provider ?? "-") tokens=\(promptTok)/\(completionTok)")
                if !content.isEmpty || !toolCalls.isEmpty {
                    addSpend(callSpendUSD(for: backend, usage: resp.usage), executionID: executionID)
                    if let finishReason = choice.finish_reason, finishReason != "stop", finishReason != "tool_calls" {
                        webLog("[WebOrchestrator] TRUNCATED_GENERATION stage=\(stage) finish=\(finishReason) completion_tokens=\(completionTok)")
                    }
                    transcript.appendAssistant(message)
                    return WebAgentRound(visibleText: content, toolCalls: toolCalls)
                }
            }

            let detail: String
            if let apiError = try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data) {
                detail = apiError.error.composedMessage
            } else {
                let snippet = String(data: data.prefix(300), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                detail = snippet.isEmpty ? "empty response body" : "unexpected response: \(snippet)"
            }
            guard attempt < maxAttempts else {
                throw NSError(domain: "WebOrchestrator", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "\(backend.rawValue) returned no usable agent round for '\(stage)' (model \(resolvedModel(for: backend, requested: agentMdl))): \(detail)"
                ])
            }
            webLog("[WebOrchestrator] \(backend.rawValue) stage=\(stage) empty agent round (attempt \(attempt)/\(maxAttempts)): \(detail). Retrying...")
            try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 1_500_000_000))
            attempt += 1
        }
    }

    /// Agent round over the OpenAI Responses API: function tools + reasoning
    /// coexist there, and encrypted reasoning items are replayed for true
    /// chain-of-thought continuity across rounds (store:false — stateless).
    private func callResponsesRound(
        _ transcript: WebAgentResponsesTranscript,
        mode: ResearchMode,
        toolChoice: String?,
        stage: String,
        executionID: UUID
    ) async throws -> WebAgentRound {
        let generous = mode == .deepResearch || stage == "agent.final"
        let model = resolvedModel(for: .openai, requested: agentModel(for: mode))
        let effort = agentReasoning(for: mode)?.effort

        let req = OAIResponsesReq(
            model: model,
            instructions: transcript.instructions,
            input: transcript.input,
            tools: WebAgentTools.responsesTools,
            tool_choice: toolChoice,
            reasoning: effort.map { OAIResponsesReq.Reasoning(effort: $0) },
            max_output_tokens: 32000
        )
        webLog("[WebOrchestrator] openai request stage=\(stage) mode=\(modeLabel(mode)) model=\(model) api=responses reasoning=\(effort ?? "default") input_items=\(transcript.input.count) tool_choice=\(toolChoice ?? "auto")")

        let maxAttempts = 3
        var attempt = 1
        while true {
            let data = try await httpJSONPostWithRetry(
                url: Endpoints.openaiResponses,
                body: req,
                headers: try requestHeaders(for: .openai, url: Endpoints.openaiResponses, lane: .ephemeral(executionID)),
                timeout: generous ? 600 : 120,
                label: "openai \(stage)",
                retryTimeouts: !generous,
                usageRecord: ResponsesUsageStore.Record(requestID: UUID(), operationID: executionID,
                    provider: .openaiAPI, model: String(model.prefix(128)), lane: "ephemeral", operation: .webResearch, attempt: 1)
            )

            var detail = "empty response body"
            if let resp = try? JSONDecoder().decode(OAIResponsesResp.self, from: data) {
                if let apiError = resp.error, let message = apiError.message {
                    detail = "\(apiError.code ?? "error"): \(message)"
                } else {
                    let output = resp.output ?? []
                    let round = WebAgentResponsesTranscript.parseRound(outputItems: output)
                    let inTok = resp.usage?.input_tokens
                    let outTok = resp.usage?.output_tokens
                    webLog("[WebOrchestrator] openai response stage=\(stage) mode=\(modeLabel(mode)) status=\(resp.status ?? "nil") output_items=\(output.count) content_chars=\(round.visibleText.count) tool_calls=\(round.toolCalls.count) tokens=\(inTok.map(String.init) ?? "?")/\(outTok.map(String.init) ?? "?")")
                    if resp.status == "incomplete" {
                        webLog("[WebOrchestrator] TRUNCATED_GENERATION stage=\(stage) status=incomplete output_tokens=\(outTok.map(String.init) ?? "?") max=32000")
                    }
                    if !round.visibleText.isEmpty || !round.toolCalls.isEmpty {
                        addSpend(estimatedOpenAISpendUSD(promptTokens: inTok, completionTokens: outTok), executionID: executionID)
                        transcript.appendOutputItems(output)
                        return round
                    }
                    detail = "no message or tool call in \(output.count) output items (status \(resp.status ?? "nil"))"
                }
            } else {
                let snippet = String(data: data.prefix(300), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !snippet.isEmpty { detail = "unexpected response: \(snippet)" }
            }

            guard attempt < maxAttempts else {
                throw NSError(domain: "WebOrchestrator", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "openai returned no usable agent round for '\(stage)' (model \(model)): \(detail)"
                ])
            }
            webLog("[WebOrchestrator] openai stage=\(stage) empty agent round (attempt \(attempt)/\(maxAttempts)): \(detail). Retrying...")
            try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 1_500_000_000))
            attempt += 1
        }
    }

    // MARK: - Agent Tool Dispatch
    //
    // Two phases: the NETWORK phase (Serper/Jina/extraction — safe to run
    // concurrently across a round's calls) and the RENDER phase (pure,
    // sequential in call order, so the cross-round `seenLinks` dedup is
    // deterministic regardless of network completion order).

    /// Network-phase result of one tool call. Internal so the selftest can
    /// stub the network phase and exercise the orchestration state machine.
    /// `queriesRun` rides along so the render phase records query history in
    /// deterministic call order (recording inside the concurrent phase made
    /// the ordering depend on network completion).
    enum AgentToolNetworkResult {
        case search(context: WebContext, failures: [String], dropped: Int, queriesRun: [String])
        case fetch(docs: [ScrapedDoc], failures: [String], dropped: Int)
        /// Bad arguments or unknown tool — reported to the model, does not
        /// count as an attempted web action.
        case toolError(message: String)
    }

    private struct AgentToolOutcome {
        let payload: String
        let attemptedWebAction: Bool
        let gotResults: Bool
        let failures: [String]
        let seenLinks: Set<String>
    }

    /// Per-fetch excerpt budget entering the transcript. Matches the old
    /// behavior's practical bound (a 32k-token extraction output).
    private static let fetchPayloadExcerptBudget = 120_000

    private func performAgentToolNetwork(
        _ call: WebAgentToolCall,
        round: Int,
        mode: ResearchMode,
        executionID: UUID
    ) async throws -> AgentToolNetworkResult {
        if let stub = toolNetworkStubForTesting {
            return try await stub(call)
        }
        switch call.name.lowercased() {
        case WebAgentTools.searchName:
            guard let args = try? JSONDecoder().decode(SearchToolArgs.self, from: Data(call.argumentsJSON.utf8)),
                  !args.queries.isEmpty else {
                return .toolError(message: "Could not parse arguments. Expected {\"queries\": [\"...\"]} with at least one query.")
            }
            let (queriesToRun, dropped) = WebAgentSupport.capped(args.queries, to: WebAgentTools.maxQueriesPerCall)
            let outcome = try await executeSearch(queries: queriesToRun, atStep: round, executionID: executionID)
            return .search(context: outcome.context, failures: outcome.failures, dropped: dropped, queriesRun: queriesToRun)

        case WebAgentTools.fetchName:
            guard let args = try? JSONDecoder().decode(FetchToolArgs.self, from: Data(call.argumentsJSON.utf8)),
                  !args.requests.isEmpty else {
                return .toolError(message: "Could not parse arguments. Expected {\"requests\": [{\"url\": \"...\", \"focus\": \"...\"}]} with at least one request.")
            }
            let (requestsToRun, dropped) = WebAgentSupport.capped(args.requests, to: WebAgentTools.maxFetchRequestsPerCall)
            let outcome = try await executeScrape(requests: requestsToRun, atStep: round, mode: mode, executionID: executionID)
            return .fetch(docs: outcome.docs, failures: outcome.failures, dropped: dropped)

        default:
            return .toolError(message: "Unknown tool '\(call.name)'. Available tools: \(WebAgentTools.searchName), \(WebAgentTools.fetchName).")
        }
    }

    private func renderAgentToolOutcome(
        _ network: AgentToolNetworkResult,
        seenLinks: Set<String>,
        executionID: UUID
    ) -> AgentToolOutcome {
        func encodePayload<T: Encodable>(_ value: T) -> String {
            (try? String(data: JSONEncoder().encode(value), encoding: .utf8) ?? "{}") ?? "{}"
        }
        struct ToolErrorPayload: Encodable { let error: String }

        switch network {
        case .search(let context, let failures, let dropped, let queriesRun):
            appendQueriesUsed(queriesRun, executionID: executionID)
            var seen = seenLinks
            let (fresh, omitted) = WebAgentSupport.dedupeAgainstSeen(context.results, seen: &seen)
            let payload = SearchToolPayload(
                results: fresh,
                answer_box: context.answerBox,
                knowledge_graph: context.knowledgeGraph,
                people_also_ask: context.peopleAlsoAsk,
                top_stories: context.topStories,
                failed_queries: failures.isEmpty ? nil : failures,
                dropped_queries: dropped > 0 ? dropped : nil,
                omitted_repeats: omitted > 0 ? omitted : nil
            )
            let gotResults = !context.results.isEmpty
                || context.answerBox != nil
                || context.knowledgeGraph != nil
            return AgentToolOutcome(
                payload: encodePayload(payload),
                attemptedWebAction: true,
                gotResults: gotResults,
                failures: failures.map { "search — \($0)" },
                seenLinks: seen)

        case .fetch(let docs, let failures, let dropped):
            let perDocBudget = Self.fetchPayloadExcerptBudget / max(1, docs.count)
            let pages = docs.map { doc -> FetchToolPayload.Page in
                let (kept, truncated) = WebAgentSupport.clampExcerpts(doc.excerpts, totalBudget: perDocBudget)
                if truncated {
                    webLog("[WebOrchestrator] fetch payload truncated url=\(doc.url) budget=\(perDocBudget)")
                }
                return FetchToolPayload.Page(
                    url: doc.url,
                    title: doc.title,
                    excerpts: kept,
                    relevant_links: doc.links.isEmpty ? nil : doc.links,
                    relevant_images: doc.images.isEmpty ? nil : doc.images,
                    excerpts_truncated: truncated ? true : nil
                )
            }
            let payload = FetchToolPayload(
                pages: pages,
                failed_urls: failures.isEmpty ? nil : failures,
                dropped_requests: dropped > 0 ? dropped : nil
            )
            return AgentToolOutcome(
                payload: encodePayload(payload),
                attemptedWebAction: true,
                gotResults: !docs.isEmpty,
                failures: failures.map { "scrape — \($0)" },
                seenLinks: seenLinks)

        case .toolError(let message):
            return AgentToolOutcome(
                payload: encodePayload(ToolErrorPayload(error: message)),
                attemptedWebAction: false,
                gotResults: false,
                failures: [],
                seenLinks: seenLinks)
        }
    }

    // MARK: - Test Seams
    //
    // Selftest-only stubs replacing the model round and the tool network
    // phase, so the orchestration state machine (zero-search guard, salvage,
    // budget exhaustion, only-failures) can be exercised hermetically.
    // Never set in production.

    private var agentRoundStubForTesting: (@Sendable (_ stage: String, _ toolChoice: String?) async throws -> WebAgentRound)?
    private var toolNetworkStubForTesting: (@Sendable (_ call: WebAgentToolCall) async throws -> AgentToolNetworkResult)?

    func setTestStubs(
        agentRound: (@Sendable (_ stage: String, _ toolChoice: String?) async throws -> WebAgentRound)?,
        toolNetwork: (@Sendable (_ call: WebAgentToolCall) async throws -> AgentToolNetworkResult)?
    ) {
        agentRoundStubForTesting = agentRound
        toolNetworkStubForTesting = toolNetwork
    }

    // MARK: - Tool Execution
    private func executeSearch(queries: [String], atStep: Int, executionID: UUID) async throws -> (context: WebContext, failures: [String]) {
        var seen = Set<String>()
        var results: [WebResult] = []
        var queryRecords: [QueryRecord] = []
        var firstAB: SerperSearchResp.AnswerBox?
        var firstKG: SerperSearchResp.KG?
        var paa: [SerperSearchResp.PAA] = []
        var top: [SerperSearchResp.Top] = []
        var failures: [String] = []

        // One failed query must not sink its siblings: collect per-query
        // outcomes instead of letting the first error cancel the group.
        await withTaskGroup(of: (query: String, response: SerperSearchResp?, errorText: String?).self) { group in
            for q in queries {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return (q, try await self.serperSearch(q), nil)
                    } catch is CancellationError {
                        return (q, nil, nil)
                    } catch {
                        return (q, nil, error.localizedDescription)
                    }
                }
            }
            for await item in group {
                guard let r = item.response else {
                    if let errorText = item.errorText {
                        failures.append("\(item.query): \(errorText)")
                    }
                    continue
                }
                queryRecords.append(QueryRecord(query: item.query, retrievedAtStep: atStep))
                if firstAB == nil { firstAB = r.answerBox }
                if firstKG == nil { firstKG = r.knowledgeGraph }
                if let p = r.peopleAlsoAsk { paa.append(contentsOf: p.prefix(6)) }
                if let t = r.topStories { top.append(contentsOf: t.prefix(6)) }
                if let org = r.organic {
                    for item in org.prefix(perQueryDepth) {
                        guard let link = item.link, let title = item.title else { continue }
                        let key = normalize(link)
                        if seen.contains(key) { continue }
                        seen.insert(key)
                        results.append(WebResult(title: title, snippet: (item.snippet ?? "").prefixing(460), link: link, source: URL(string: link)?.host?.lowercased() ?? "", date: item.date, retrievedAtStep: atStep))
                    }
                }
            }
        }
        try Task.checkCancellation()

        let context = WebContext(queries_used: queryRecords, results: results, answerBox: firstAB.map(WebAnswerBox.init), knowledgeGraph: firstKG.map(WebKG.init), peopleAlsoAsk: paa.map(WebPAA.init), topStories: top.map(WebTop.init), scraped: []).clamped(to: maxContextBytes)
        return (context, failures)
    }
    
    private func executeScrape(
        requests: [ScrapeRequest],
        atStep: Int,
        mode: ResearchMode,
        executionID: UUID
    ) async throws -> (docs: [ScrapedDoc], failures: [String]) {
        await withTaskGroup(of: (url: String, doc: ScrapedDoc?, errorText: String?).self) { group in
            for req in requests {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let doc = try await self.scrapeAndExtract(
                            url: req.url,
                            focus: req.focus,
                            atStep: atStep,
                            mode: mode,
                            executionID: executionID
                        )
                        return (req.url, doc, nil)
                    } catch is CancellationError {
                        return (req.url, nil, nil)
                    } catch {
                        return (req.url, nil, error.localizedDescription)
                    }
                }
            }
            var docs: [ScrapedDoc] = []
            var failures: [String] = []
            for await item in group {
                if let doc = item.doc {
                    docs.append(doc)
                } else if let errorText = item.errorText {
                    failures.append("\(item.url): \(errorText)")
                }
            }
            return (docs, failures)
        }
    }
    
    // MARK: - API Calls

    /// Per-backend chat-completions body. Shared by the mechanical stages
    /// (via callOpenRouter) and the chat agent rounds (which add tools).
    /// `responseFormat` is attached on openai (enforced) and openrouter
    /// (forwarded) but never on opencode (mimo ignores it — probed
    /// 2026-08-16).
    private func buildChatBody(
        backend: WebSearchBackend,
        stage: String,
        mode: ResearchMode,
        model: String,
        messages: [ORChatReq.Msg],
        maxTokens: Int,
        reasoning: ORChatReq.Reasoning?,
        provider: ORChatReq.Provider?,
        temperature: Double,
        responseFormat: ORResponseFormat?
    ) -> ORChatReq {
        let resolvedModel = self.resolvedModel(for: backend, requested: model)
        let effortString = reasoning?.effort
        let attachedFormat = backend.supportsResponseFormat ? responseFormat : nil

        let reasoningLabel: String = {
            guard let reasoning else { return "none" }
            if let effort = reasoning.effort, !effort.isEmpty { return effort }
            if let budget = reasoning.max_tokens { return "budget:\(budget)" }
            return "configured"
        }()
        let formatLabel = attachedFormat.map { "rf=\($0.json_schema.name)" } ?? "rf=none"

        switch backend {
        case .openrouter:
            let providerToUse = provider ?? .init(
                order: ProviderSettings.order,
                only: ProviderSettings.only,
                allow_fallbacks: ProviderSettings.allowFallbacks,
                sort: nil
            )
            let providerOrder = providerToUse.order?.joined(separator: ",") ?? "nil"
            let providerOnly = providerToUse.only?.joined(separator: ",") ?? "nil"
            let providerFallbacks = providerToUse.allow_fallbacks.map(String.init) ?? "nil"
            webLog("[WebOrchestrator] OpenRouter request stage=\(stage) mode=\(modeLabel(mode)) model=\(resolvedModel) reasoning=\(reasoningLabel) \(formatLabel) max_tokens=\(maxTokens) provider_order=\(providerOrder) provider_only=\(providerOnly) provider_allow_fallbacks=\(providerFallbacks)")
            return ORChatReq(
                model: resolvedModel,
                messages: messages,
                max_tokens: maxTokens,
                max_completion_tokens: nil,
                temperature: temperature,
                stream: false,
                reasoning: reasoning,
                reasoning_effort: nil,
                provider: providerToUse,
                response_format: attachedFormat
            )
        case .openai:
            // OpenAI-native shape: reasoning models take max_completion_tokens
            // plus a top-level reasoning_effort, and reject max_tokens,
            // non-default temperature, and the OpenRouter provider block.
            webLog("[WebOrchestrator] OpenAI request stage=\(stage) mode=\(modeLabel(mode)) model=\(resolvedModel) reasoning=\(reasoningLabel) \(formatLabel) max_completion_tokens=\(maxTokens)")
            return ORChatReq(
                model: resolvedModel,
                messages: messages,
                max_tokens: nil,
                max_completion_tokens: maxTokens,
                temperature: nil,
                stream: false,
                reasoning: nil,
                reasoning_effort: effortString,
                provider: nil,
                response_format: attachedFormat
            )
        case .opencode:
            webLog("[WebOrchestrator] OpenCode request stage=\(stage) mode=\(modeLabel(mode)) model=\(resolvedModel) reasoning=\(reasoningLabel) max_tokens=\(maxTokens)")
            return ORChatReq(
                model: resolvedModel,
                messages: messages,
                max_tokens: maxTokens,
                max_completion_tokens: nil,
                temperature: temperature,
                stream: false,
                reasoning: nil,
                reasoning_effort: effortString,
                provider: nil
            )
        }
    }

    private func callOpenRouter(
        stage: String,
        mode: ResearchMode,
        model: String,
        messages: [ORChatReq.Msg],
        maxTokens: Int,
        reasoning: ORChatReq.Reasoning? = nil,
        provider: ORChatReq.Provider? = nil,
        temperature: Double = 0.7,
        timeout: TimeInterval = 120,
        retryTimeouts: Bool = true,
        responseFormat: ORResponseFormat? = nil,
        executionID: UUID
    ) async throws -> String {
        let backend = WebSearchBackend.active
        let resolvedModel = self.resolvedModel(for: backend, requested: model)
        var body = buildChatBody(
            backend: backend,
            stage: stage,
            mode: mode,
            model: model,
            messages: messages,
            maxTokens: maxTokens,
            reasoning: reasoning,
            provider: provider,
            temperature: temperature,
            responseFormat: responseFormat
        )
        let maxCompletionAttempts = 3
        var completionAttempt = 1
        while true {
            let data: Data
            do {
                data = try await httpJSONPostWithRetry(
                    url: backend.endpoint,
                    body: body,
                    headers: try requestHeaders(for: backend, url: backend.endpoint, lane: .ephemeral(executionID)),
                    timeout: timeout,
                    label: "\(backend.rawValue) \(stage)",
                    retryTimeouts: retryTimeouts
                )
            } catch let httpError as HTTPError where httpError.statusCode == 400 && body.response_format != nil {
                // An OpenRouter upstream provider may reject response_format.
                // The prompt already demands the same JSON and the repair pass
                // still guards the decode — drop the format and continue.
                let detail = httpError.localizedDescription.lowercased()
                guard detail.contains("response_format") || detail.contains("json_schema") else { throw httpError }
                webLog("[WebOrchestrator] \(stage) RESPONSE_FORMAT_DROPPED backend=\(backend.rawValue): \(httpError.localizedDescription.prefix(200))")
                body.response_format = nil
                continue
            }

            if let resp = try? JSONDecoder().decode(ORChatResp.self, from: data),
               let choice = resp.choices.first,
               let rawContent = choice.message.content,
               !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let content = rawContent
                addSpend(callSpendUSD(for: backend, usage: resp.usage), executionID: executionID)
                let finish = choice.finish_reason ?? "nil"
                let native = choice.native_finish_reason ?? "nil"
                let promptTok = resp.usage?.promptTokens.map(String.init) ?? "?"
                let completionTok = resp.usage?.completionTokens.map(String.init) ?? "?"
                let served = resp.provider ?? "-"
                webLog("[WebOrchestrator] \(backend.rawValue) response stage=\(stage) mode=\(modeLabel(mode)) chars=\(content.count) finish=\(finish) native=\(native) provider=\(served) tokens=\(promptTok)/\(completionTok)")
                // A finish_reason other than "stop" means the SERVER ended the
                // generation early (output-token cap exhausted — including
                // hidden reasoning — or provider-side cutoff): the content is a
                // truncated prefix even though the HTTP envelope is complete.
                // This is the signature behind mid-JSON truncated agent steps.
                if let finishReason = choice.finish_reason, finishReason != "stop" {
                    webLog("[WebOrchestrator] TRUNCATED_GENERATION stage=\(stage) finish=\(finishReason) native=\(native) provider=\(served) content_chars=\(content.count) completion_tokens=\(completionTok) max_tokens=\(maxTokens)")
                }
                return content
            }

            // HTTP 2xx without a usable completion: OpenRouter (or the upstream
            // provider) put an error object in the body, or returned an empty
            // choice. Previously this surfaced as an opaque DecodingError
            // ("The data couldn't be read because it is missing") and killed
            // the whole pipeline; these failures are typically transient
            // provider errors, so retry, and name the real cause if we give up.
            let detail: String
            if let apiError = try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data) {
                detail = apiError.error.composedMessage
            } else {
                let snippet = String(data: data.prefix(300), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                detail = snippet.isEmpty ? "empty response body" : "unexpected response: \(snippet)"
            }

            guard completionAttempt < maxCompletionAttempts else {
                throw NSError(domain: "WebOrchestrator", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "\(backend.rawValue) returned no completion for stage '\(stage)' (model \(resolvedModel)): \(detail)"
                ])
            }
            webLog("[WebOrchestrator] \(backend.rawValue) stage=\(stage) returned no completion (attempt \(completionAttempt)/\(maxCompletionAttempts)): \(detail). Retrying...")
            try await Task.sleep(nanoseconds: UInt64(Double(completionAttempt) * 1_500_000_000))
            completionAttempt += 1
        }
    }
    
    /// gpt-5.6-luna pricing (verified 2026-08-03 — DOUBLED from the Aug 1
    /// rates): $0.20/M input, $1.20/M output (hidden reasoning bills as
    /// output, so completion_tokens already includes it). Requests whose
    /// input exceeds 272K tokens bill the FULL request at 2x input/1.5x
    /// output — our 800K-char extraction chunks cross that line, so the
    /// estimator must model it. Cached input is cheaper in reality but is
    /// billed here at the full input rate — erring high is the safe
    /// direction for a spend limit. A non-Luna override configured for the
    /// OpenAI backend is also estimated at these rates.
    private static let openAIInputUSDPerMTok = 0.20
    private static let openAIOutputUSDPerMTok = 1.20
    static let openAILargeRequestInputTokens = 272_000
    static let openAILargeRequestInputMultiplier = 2.0
    static let openAILargeRequestOutputMultiplier = 1.5

    /// OpenRouter reports each call's cost directly. The OpenAI API returns
    /// only token counts, so estimate from published rates — otherwise paid
    /// OpenAI-direct searches would register as $0 and bypass the per-turn/
    /// daily/monthly tool spend limits. OpenCode Go is a flat subscription,
    /// so $0 there is accurate.
    private func callSpendUSD(for backend: WebSearchBackend, usage: OpenRouterUsage?) -> Double? {
        switch backend {
        case .openrouter:
            let directCost = usage?.cost?.value
            let upstreamInferenceCost = usage?.costDetails?.upstreamInferenceCost?.value
            return [directCost, upstreamInferenceCost]
                .compactMap { $0 }
                .filter { $0.isFinite && $0 >= 0 }
                .max()
        case .openai:
            guard let usage else { return nil }
            return estimatedOpenAISpendUSD(
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens)
        case .opencode:
            return nil
        }
    }

    /// Shared by chat completions (usage.prompt/completion_tokens) and the
    /// Responses API (usage.input/output_tokens).
    private func estimatedOpenAISpendUSD(promptTokens: Int?, completionTokens: Int?) -> Double? {
        let prompt = Double(promptTokens ?? 0)
        let completion = Double(completionTokens ?? 0)
        let isLarge = Int(prompt) > Self.openAILargeRequestInputTokens
        let inputRate = Self.openAIInputUSDPerMTok
            * (isLarge ? Self.openAILargeRequestInputMultiplier : 1)
        let outputRate = Self.openAIOutputUSDPerMTok
            * (isLarge ? Self.openAILargeRequestOutputMultiplier : 1)
        let estimate = (prompt * inputRate + completion * outputRate) / 1_000_000
        return estimate > 0 ? estimate : nil
    }

    private func serperSearch(_ q: String) async throws -> SerperSearchResp {
        let req = SerperSearchReq(q: q, num: perQueryDepth)
        let data: Data
        do {
            data = try await httpJSONPostWithRetry(url: Endpoints.serperSearch, body: req, headers: ["X-API-KEY": serperApiKey], timeout: 60, label: "serper search")
        } catch {
            await ToolServiceHealth.shared.recordFailure(.webSearch, error: error.localizedDescription)
            throw error
        }
        await ToolServiceHealth.shared.recordSuccess(.webSearch)
        do {
            let resp = try JSONDecoder().decode(SerperSearchResp.self, from: data)
            let organicCount = resp.organic?.count ?? 0
            if organicCount == 0 {
                // Not retried: some queries genuinely have zero results — but
                // a burst of empties across varied queries in the log is the
                // signature of quota exhaustion, so leave the trail.
                let extras = "answerBox=\(resp.answerBox != nil) knowledgeGraph=\(resp.knowledgeGraph != nil) topStories=\(resp.topStories?.count ?? 0)"
                webLog("[WebPipeline] serper EMPTY (0 organic) query=\"\(q)\" \(extras)")
            } else {
                webLog("[WebPipeline] serper ok organic=\(organicCount) query=\"\(q)\"")
            }
            return resp
        } catch {
            let snippet = String(data: data.prefix(200), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "WebOrchestrator", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Serper returned an unexpected response: \(snippet.isEmpty ? "empty body" : snippet)"
            ])
        }
    }
    
    private func fetchWithJinaReader(originalURL: String, includeImageCaptions: Bool = false) async throws -> (title: String?, content: String) {
        let target = (originalURL.hasPrefix("http://") || originalURL.hasPrefix("https://")) ? originalURL : "https://\(originalURL)"
        guard let proxyURL = URL(string: Endpoints.jinaReaderBase + target) else { throw URLError(.badURL) }
        var req = URLRequest(url: proxyURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 120
        if !jinaApiKey.isEmpty {
            req.setValue("Bearer \(jinaApiKey)", forHTTPHeaderField: "Authorization")
        }
        // Enable image captioning for vision model context
        if includeImageCaptions {
            req.setValue("true", forHTTPHeaderField: "x-with-generated-alt")
        }
        let data: Data
        do {
            data = try await httpDataWithRetry(request: req, label: "jina reader", maxAttempts: 3)
        } catch {
            await ToolServiceHealth.shared.recordFailure(.webFetch, error: error.localizedDescription)
            throw error
        }
        await ToolServiceHealth.shared.recordSuccess(.webFetch)
        let text = String(data: data, encoding: .utf8) ?? ""
        let contentLength = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if contentLength < 200 {
            // Not retried: a page can genuinely be empty — but the length and
            // URL in the log distinguish paywalls/bot-blocks from real content.
            webLog("[WebPipeline] jina THIN content (\(contentLength) chars) url=\(target)")
        } else {
            webLog("[WebPipeline] jina ok chars=\(text.count) url=\(target)")
        }
        let lines = text.split(separator: "\n", maxSplits: 20, omittingEmptySubsequences: true)
        var title: String? = nil
        for line in lines.prefix(8) {
            if line.hasPrefix("# ") { title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines); break }
        }
        return (title, text)
    }
    
    // MARK: - Public URL Reading (for web_fetch tool)

    /// Fetch URL content via Jina Reader, then compress against a user prompt:
    /// mandatory prompt, post-compression cap (~30 KB), two-tier 15-minute LRU
    /// cache (url->markdown, (url,prompt)->excerpt). Pages up to ~100 KB are
    /// compressed in one call; larger pages are chunked with overlap and judged
    /// in parallel, so the tail of a long page is read rather than cut.
    func readUrlContent(url: String, prompt: String, sectionOffset: Int = 0) async throws -> JinaReaderResult {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw NSError(domain: "WebOrchestrator", code: 1, userInfo: [NSLocalizedDescriptionKey: "web_fetch requires a non-empty prompt describing what to extract from the page."])
        }
        let sectionOffset = max(0, sectionOffset)
        // One execution (= one affinity lane) for the whole fetch: the
        // one-shot compression, every parallel chunk and the merge pass
        // share it (Codex round 1).
        let executionID = UUID()

        let normalizedURL = normalize(url)

        // Tier 2 cache: exact (url, offset, prompt) hit.
        prunedExcerptCache()
        let excerptKey = "\(normalizedURL)|s\(sectionOffset)|\(trimmedPrompt)"
        if let hit = excerptCache[excerptKey], Date().timeIntervalSince(hit.cachedAt) < webFetchCacheTTL {
            webLog("[WebOrchestrator] web_fetch excerpt cache hit url=\(normalizedURL)")
            return hit.payload
        }

        // Tier 1 cache: url -> raw Jina markdown (reused across different prompts).
        prunedMarkdownCache()
        let rawTitle: String?
        let rawMarkdown: String
        if let md = markdownCache[normalizedURL], Date().timeIntervalSince(md.cachedAt) < webFetchCacheTTL {
            rawTitle = md.title
            rawMarkdown = md.markdown
            webLog("[WebOrchestrator] web_fetch markdown cache hit url=\(normalizedURL)")
        } else {
            let (title, content) = try await fetchWithJinaReader(originalURL: url, includeImageCaptions: true)
            rawTitle = title
            rawMarkdown = content
            markdownCache[normalizedURL] = CachedMarkdown(title: title, markdown: content, cachedAt: Date())
        }

        let links = extractLinksFromMarkdown(rawMarkdown)
        let images = extractImageReferences(rawMarkdown)

        // Pages within the single-call budget keep the original one-shot path.
        // Larger pages are chunked and fanned out so the tail of the page is
        // judged for relevance, not amputated.
        let preCap = 100_000
        let postCap = 30_000
        let finalContent: String
        if rawMarkdown.utf8.count <= preCap {
            var excerpt: String
            do {
                excerpt = try await compressPageForPrompt(
                    pageURL: url,
                    pageTitle: rawTitle,
                    markdown: rawMarkdown,
                    prompt: trimmedPrompt,
                    executionID: executionID
                )
            } catch {
                webLog("[WebOrchestrator] web_fetch compression failed, returning truncated raw markdown: \(error.localizedDescription)")
                // Fall back to truncated raw markdown so the agent still gets something.
                excerpt = String(rawMarkdown.prefix(postCap))
            }
            if excerpt.count > postCap {
                let endIdx = excerpt.index(excerpt.startIndex, offsetBy: postCap)
                excerpt = String(excerpt[..<endIdx]) + "\n\n[...truncated; response exceeded 30KB...]"
            }
            finalContent = excerpt
        } else {
            finalContent = try await compressLargePageForPrompt(
                pageURL: url,
                pageTitle: rawTitle,
                markdown: rawMarkdown,
                prompt: trimmedPrompt,
                sectionOffset: sectionOffset,
                postCap: postCap,
                executionID: executionID
            )
        }

        let result = JinaReaderResult(
            url: url,
            title: rawTitle,
            content: finalContent,
            links: links,
            images: images
        )

        excerptCache[excerptKey] = CachedExcerpt(payload: result, cachedAt: Date())
        return result
    }

    /// Small-model compression of a page's markdown against the user's prompt.
    /// Mirrors Claude Code's WebFetch small-model stage.
    func compressPageForPrompt(
        pageURL: String,
        pageTitle: String?,
        markdown: String,
        prompt: String,
        section: (index: Int, total: Int)? = nil,
        executionID: UUID
    ) async throws -> String {
        let titleLine = pageTitle.map { "Page title: \($0)\n" } ?? ""
        var systemMsg = """
        You extract information from a web page to answer the user's specific prompt.

        Rules:
        - Use ONLY the page content below; do not invent facts.
        - Quote verbatim when the user asks for exact text, code, commands, or steps.
        - Preserve code blocks, command examples, tables, and numeric values exactly.
        - Organise the output with short headings or bullets when helpful.
        - If the page does not answer the prompt, say so plainly and mention the closest related content (1–2 sentences).
        - Keep the response under ~25,000 characters. Prefer density over prose.
        - Do not add conversational preambles ("Sure", "Here's what I found"). Start with the answer.
        """
        if let section {
            systemMsg += """


            Note: the content below is section \(section.index) of \(section.total) of a larger page, split for processing. Other sections are handled separately — extract only from this one. If this section contains NOTHING relevant to the user prompt, respond with exactly \(webFetchNoContentSentinel) and nothing else.
            """
        }
        let userMsg = """
        URL: \(pageURL)
        \(titleLine)User prompt: \(prompt)

        --- PAGE CONTENT (markdown) ---
        \(markdown)
        --- END PAGE CONTENT ---

        Extract the information relevant to the user prompt, following the rules above.
        """
        let messages = [
            ORChatReq.Msg(role: "system", content: systemMsg),
            ORChatReq.Msg(role: "user", content: userMsg)
        ]
        return try await callOpenRouter(
            stage: section.map { "web_fetch_compression.chunk\($0.index)" } ?? "web_fetch_compression",
            mode: .webSearch,
            model: ORModel.webFetchCompression,
            messages: messages,
            maxTokens: 8_000,
            reasoning: makeReasoning(.medium),
            // Never nil here: callOpenRouter's nil-fallback pins to
            // Groq/Vertex, which don't host Luna.
            provider: providerPreferences(forModel: ORModel.webFetchCompression),
            temperature: 0.1,
            executionID: executionID
        )
    }

    /// Chunked compression for pages beyond the single-call budget. Splits the
    /// full markdown with overlap, compresses every chunk in parallel against
    /// the same prompt, drops chunks that report nothing relevant, and stitches
    /// the rest in page order. Falls back to truncated raw markdown only when
    /// every chunk fails. The returned text always ends with a coverage line so
    /// the caller knows whether the whole page was judged.
    func compressLargePageForPrompt(
        pageURL: String,
        pageTitle: String?,
        markdown: String,
        prompt: String,
        sectionOffset: Int,
        postCap: Int,
        executionID: UUID
    ) async throws -> String {
        let totalChars = markdown.count
        let step = webFetchChunkChars - chunkOverlapChars
        let totalChunks = totalChars <= webFetchChunkChars
            ? 1
            : 1 + Int(ceil(Double(totalChars - webFetchChunkChars) / Double(step)))

        if sectionOffset >= totalChunks {
            return "[section_offset \(sectionOffset) is past the end of this page: it has \(totalChunks) section(s) (\(totalChars) chars). Valid offsets are 0–\(totalChunks - 1).]"
        }

        var chunks: [String] = []
        for i in sectionOffset..<min(sectionOffset + webFetchMaxChunks, totalChunks) {
            let startOffset = i * step
            let endOffset = min(startOffset + webFetchChunkChars, totalChars)
            let sIdx = markdown.index(markdown.startIndex, offsetBy: startOffset)
            let eIdx = markdown.index(markdown.startIndex, offsetBy: endOffset)
            chunks.append(String(markdown[sIdx..<eIdx]))
        }
        let lastSection = sectionOffset + chunks.count
        let coveredEnd = min(totalChars, (lastSection - 1) * step + webFetchChunkChars)

        struct ChunkOutcome {
            let index: Int
            let text: String?   // nil = extraction failed
        }

        var outcomes: [ChunkOutcome] = []
        await withTaskGroup(of: ChunkOutcome.self) { group in
            for (i, chunk) in chunks.enumerated() {
                let absoluteSection = sectionOffset + i + 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let out = try await self.compressPageForPrompt(
                            pageURL: pageURL,
                            pageTitle: pageTitle,
                            markdown: chunk,
                            prompt: prompt,
                            section: (index: absoluteSection, total: totalChunks),
                            executionID: executionID
                        )
                        return ChunkOutcome(index: i, text: out)
                    } catch {
                        webLog("[WebOrchestrator] web_fetch chunk \(absoluteSection)/\(totalChunks) failed: \(error.localizedDescription)")
                        return ChunkOutcome(index: i, text: nil)
                    }
                }
            }
            for await outcome in group { outcomes.append(outcome) }
        }
        try Task.checkCancellation()
        outcomes.sort { $0.index < $1.index }

        let failedCount = outcomes.filter { $0.text == nil }.count
        let relevant: [(index: Int, text: String)] = outcomes.compactMap { outcome in
            guard let text = outcome.text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.uppercased().hasPrefix(webFetchNoContentSentinel) else { return nil }
            return (outcome.index, trimmed)
        }

        // Every chunk failed: keep the same failure shape as the one-shot path,
        // returning raw markdown from the start of the requested window.
        if failedCount == chunks.count {
            let windowStart = markdown.index(markdown.startIndex, offsetBy: sectionOffset * step)
            return String(markdown[windowStart...].prefix(postCap)) + "\n\n[...compression failed for all sections; raw markdown of the requested window truncated at 30KB...]"
        }

        var stitched: String
        if relevant.isEmpty {
            stitched = sectionOffset == 0
                ? "No content relevant to the prompt was found in the judged sections of this page."
                : "No content relevant to the prompt was found in sections \(sectionOffset + 1)–\(lastSection) of this page."
        } else if relevant.count == 1 {
            stitched = relevant[0].text
        } else {
            stitched = relevant
                .map { "— page section \(sectionOffset + $0.index + 1) of \(totalChunks) —\n\($0.text)" }
                .joined(separator: "\n\n")
        }

        // Adaptive merge: only when several dense sections overflow the output
        // cap does a second compression pass fire.
        if stitched.count > postCap {
            do {
                stitched = try await compressPageForPrompt(
                    pageURL: pageURL,
                    pageTitle: pageTitle,
                    markdown: stitched,
                    prompt: prompt,
                    executionID: executionID
                )
            } catch {
                webLog("[WebOrchestrator] web_fetch merge pass failed, hard-truncating stitched result: \(error.localizedDescription)")
            }
            if stitched.count > postCap {
                let endIdx = stitched.index(stitched.startIndex, offsetBy: postCap)
                stitched = String(stitched[..<endIdx]) + "\n\n[...truncated; merged sections exceeded 30KB...]"
            }
        }

        var coverage = "[Coverage: page is \(totalChars) chars in \(totalChunks) section(s); judged section(s) \(sectionOffset + 1)–\(lastSection)"
        if sectionOffset == 0 && lastSection == totalChunks {
            coverage += " — the full page"
        }
        if failedCount > 0 {
            coverage += "; \(failedCount) section(s) failed extraction and were skipped"
        }
        if lastSection < totalChunks {
            let pctEnd = Int((Double(coveredEnd) / Double(totalChars)) * 100)
            coverage += ". Sections \(lastSection + 1)–\(totalChunks) (beyond the \(pctEnd)% mark) were NOT read — to judge them, call web_fetch again with the same url and prompt plus section_offset: \(lastSection)"
            let remainderStart = markdown.index(markdown.startIndex, offsetBy: coveredEnd)
            let headings = extractMarkdownHeadings(from: markdown[remainderStart...], limit: 8)
            if !headings.isEmpty {
                coverage += ". Unread portion contains headings: " + headings.map { "'\($0)'" }.joined(separator: ", ")
            }
        }
        coverage += "]"

        return stitched + "\n\n" + coverage
    }

    /// Cheap heading scan of an unread page remainder so the caller can decide
    /// whether paginating further is worth it. No LLM involved.
    private func extractMarkdownHeadings(from text: Substring, limit: Int) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let stripped = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            out.append(String(stripped.prefix(80)))
            if out.count >= limit { break }
        }
        return out
    }
    
    private func extractLinksFromMarkdown(_ text: String) -> [ExtractedLink] {
        // Match markdown links: [text](url)
        let pattern = #"\[([^\]]+)\]\((https?://[^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        
        return matches.compactMap { match -> ExtractedLink? in
            guard let textRange = Range(match.range(at: 1), in: text),
                  let urlRange = Range(match.range(at: 2), in: text) else { return nil }
            return ExtractedLink(
                text: String(text[textRange]),
                url: String(text[urlRange])
            )
        }.prefix(50).map { $0 } // Limit to 50 links
    }
    
    private func extractImageReferences(_ text: String) -> [ExtractedImage] {
        // Match markdown images: ![alt](url) and Jina's Image [n]: caption format
        var images: [ExtractedImage] = []
        
        // Standard markdown images
        let mdPattern = #"!\[([^\]]*)\]\((https?://[^)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: mdPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                if let altRange = Range(match.range(at: 1), in: text),
                   let urlRange = Range(match.range(at: 2), in: text) {
                    images.append(ExtractedImage(
                        caption: String(text[altRange]),
                        url: String(text[urlRange])
                    ))
                }
            }
        }
        
        // Jina's captioned images: "Image [1]: description"
        let jinaPattern = #"Image \[(\d+)\]: ([^\n]+)"#
        if let regex = try? NSRegularExpression(pattern: jinaPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                if let captionRange = Range(match.range(at: 2), in: text) {
                    images.append(ExtractedImage(
                        caption: String(text[captionRange]),
                        url: nil // Jina captions don't always include the URL
                    ))
                }
            }
        }
        
        return Array(images.prefix(20)) // Limit to 20 images
    }
    
    private func scrapeAndExtract(
        url: String,
        focus: String,
        atStep: Int,
        mode: ResearchMode,
        executionID: UUID
    ) async throws -> ScrapedDoc {
        let (maybeTitle, rawContent) = try await fetchWithJinaReader(originalURL: url, includeImageCaptions: true)
        let host = URL(string: url)?.host?.lowercased() ?? ""

        if rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ScrapedDoc(url: url, source: host, title: maybeTitle, excerpts: [], links: [], images: [], retrievedAtStep: atStep)
        }

        let candidateLinks = extractLinksFromMarkdown(rawContent)
        let candidateImages = extractImageReferences(rawContent)
        let relevantAssets = try? await extractRelevantLinksAndImages(
            page: rawContent,
            focus: focus,
            candidateLinks: candidateLinks,
            candidateImages: candidateImages,
            mode: mode,
            executionID: executionID
        )
        let relevantLinks = relevantAssets?.links ?? []
        let relevantImages = relevantAssets?.images ?? []

        if rawContent.count <= excerptThreshold {
            return ScrapedDoc(
                url: url,
                source: host,
                title: maybeTitle,
                excerpts: [rawContent],
                links: relevantLinks,
                images: relevantImages,
                retrievedAtStep: atStep
            )
        }

        if rawContent.count <= chunkSizeChars {
            let ex = try await extractExcerpts(
                page: rawContent,
                focus: focus,
                mode: mode,
                executionID: executionID
            )
            return ScrapedDoc(
                url: url,
                source: host,
                title: maybeTitle,
                excerpts: ex,
                links: relevantLinks,
                images: relevantImages,
                retrievedAtStep: atStep
            )
        }

        let chunks = makeChunks(for: rawContent, chunk: chunkSizeChars, maxChunks: maxChunksForExtraction, overlap: chunkOverlapChars)
        var allExcerpts: [String] = []

        for chunk in chunks {
            do {
                let ex = try await extractExcerpts(
                    page: chunk,
                    focus: focus,
                    mode: mode,
                    executionID: executionID
                )
                if !ex.isEmpty { allExcerpts.append(contentsOf: ex) }
            } catch is CancellationError { throw CancellationError() }
            catch { /* continue */ }
        }

        return ScrapedDoc(
            url: url,
            source: host,
            title: maybeTitle,
            excerpts: dedupeExcerpts(allExcerpts),
            links: relevantLinks,
            images: relevantImages,
            retrievedAtStep: atStep
        )
    }
    
    private func extractExcerpts(
        page: String,
        focus: String,
        mode: ResearchMode,
        executionID: UUID
    ) async throws -> [String] {
        let sys = """
        Cite verbatim and in full the most relevant parts of the provided TEXT for the given FOCUS.
        OUTPUT STRICT JSON ONLY: { "excerpts": ["...", "..."] }
        """
        let msgs: [ORChatReq.Msg] = [
            .init(role: "system", content: sys),
            .init(role: "user", content: "FOCUS:\n\(focus)\n\nTEXT:\n\(page.prefix(chunkSizeChars))")
        ]
        let raw = try await callOpenRouter(
            stage: "extract.excerpts",
            mode: mode,
            model: excerptModel(for: mode),
            messages: msgs,
            // Luna's 1M window fits an 800K-char chunk plus a 32k output
            // budget with room to spare (the old 16k cap existed for
            // gpt-oss-120b's 131k window).
            maxTokens: 32000,
            reasoning: excerptReasoning(for: mode),
            provider: providerPreferences(forModel: excerptModel(for: mode)),
            temperature: 0.1,
            responseFormat: WebExtractionSchemas.excerpts,
            executionID: executionID
        )
        if let d = extractFirstJSONObjectData(from: raw),
           let out = try? JSONDecoder().decode(ExcerptOut.self, from: d) {
            return out.excerpts
        }
        // This site used to silently drop the whole chunk's excerpts on a
        // malformed payload — try the structural repair before giving up.
        if let repair = repairFirstJSONObjectData(from: raw),
           let out = try? JSONDecoder().decode(ExcerptOut.self, from: repair.data) {
            webLog("[WebOrchestrator] extract.excerpts REPAIRED_JSON \(repair.note) chars=\(raw.count)")
            return out.excerpts
        }
        return []
    }

    private func extractRelevantLinksAndImages(
        page: String,
        focus: String,
        candidateLinks: [ExtractedLink],
        candidateImages: [ExtractedImage],
        mode: ResearchMode,
        executionID: UUID
    ) async throws -> (links: [ExtractedLink], images: [ExtractedImage]) {
        guard !candidateLinks.isEmpty || !candidateImages.isEmpty else { return ([], []) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let linksJSON = String(
            data: (try? encoder.encode(candidateLinks)) ?? Data("[]".utf8),
            encoding: .utf8
        ) ?? "[]"
        let imagesJSON = String(
            data: (try? encoder.encode(candidateImages)) ?? Data("[]".utf8),
            encoding: .utf8
        ) ?? "[]"

        let sys = """
        You extract focus-relevant page assets from provided candidates.
        Return STRICT JSON only in this schema:
        {
          "links": [{ "text": "...", "url": "https://..." }],
          "images": [{ "caption": "...", "url": "https://..." | null }]
        }

        Rules:
        - Select only items relevant to FOCUS.
        - Use only URLs and items that appear in candidates; do not invent.
        - Keep URLs exact.
        - Return at most 8 links and 8 images.
        """

        let msgs: [ORChatReq.Msg] = [
            .init(role: "system", content: sys),
            .init(
                role: "user",
                content: """
                FOCUS:
                \(focus)

                CANDIDATE_LINKS_JSON:
                \(linksJSON)

                CANDIDATE_IMAGES_JSON:
                \(imagesJSON)

                PAGE_CONTEXT:
                \(page.prefixing(60000))
                """
            )
        ]

        let raw = try await callOpenRouter(
            stage: "extract.assets",
            mode: mode,
            model: excerptModel(for: mode),
            messages: msgs,
            maxTokens: 8000,
            reasoning: excerptReasoning(for: mode),
            provider: providerPreferences(forModel: excerptModel(for: mode)),
            temperature: 0.1,
            responseFormat: WebExtractionSchemas.assets,
            executionID: executionID
        )

        var decoded: RelevantAssetOut?
        if let d = extractFirstJSONObjectData(from: raw) {
            decoded = try? JSONDecoder().decode(RelevantAssetOut.self, from: d)
        }
        if decoded == nil, let repair = repairFirstJSONObjectData(from: raw),
           let out = try? JSONDecoder().decode(RelevantAssetOut.self, from: repair.data) {
            webLog("[WebOrchestrator] extract.assets REPAIRED_JSON \(repair.note) chars=\(raw.count)")
            decoded = out
        }
        guard let out = decoded else {
            return ([], [])
        }

        let linkLookup: [String: ExtractedLink] = Dictionary(
            candidateLinks.map { ($0.url, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let imageURLPairs: [(String, ExtractedImage)] = candidateImages.compactMap { image in
            guard let url = image.url else { return nil }
            return (url, image)
        }
        let imageURLLookup: [String: ExtractedImage] = Dictionary(
            imageURLPairs,
            uniquingKeysWith: { first, _ in first }
        )
        let imageCaptionLookup: [String: ExtractedImage] = Dictionary(
            candidateImages.map { ($0.caption.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let modelLinks = out.links ?? []
        let modelImages = out.images ?? []

        let filteredLinks = modelLinks.compactMap { item -> ExtractedLink? in
            guard let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty,
                  let candidate = linkLookup[url] else { return nil }
            let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedText: String
            if let text, !text.isEmpty {
                resolvedText = text
            } else {
                resolvedText = candidate.text
            }
            return ExtractedLink(text: resolvedText, url: candidate.url)
        }

        let filteredImages = modelImages.compactMap { item -> ExtractedImage? in
            let caption = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if let rawURL = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawURL.isEmpty,
               let candidate = imageURLLookup[rawURL] {
                return ExtractedImage(caption: caption.isEmpty ? candidate.caption : caption, url: candidate.url)
            }

            if !caption.isEmpty, let candidate = imageCaptionLookup[caption.lowercased()] {
                return candidate
            }

            return nil
        }

        return (
            links: dedupeLinks(filteredLinks).prefix(8).map { $0 },
            images: dedupeImages(filteredImages).prefix(8).map { $0 }
        )
    }
    
    private func configuredMainModel() -> String {
        // Dedicated web-search / deep-research model, configurable in Settings →
        // "Ricerca sul web". Falls back to the default when the field is empty.
        let configured = (KeychainHelper.load(key: KeychainHelper.openRouterWebSearchModelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? ORModel.defaultMainModel : configured
    }

    private func configuredReasoning() -> ORChatReq.Reasoning? {
        let configuredEffort = parseReasoningEffort(
            KeychainHelper.load(key: KeychainHelper.openRouterReasoningEffortKey)
        )
        return makeReasoning(configuredEffort)
    }

    private func configuredProviderOrder() -> [String]? {
        guard let providersString = KeychainHelper.load(key: KeychainHelper.openRouterProvidersKey),
              !providersString.isEmpty else {
            return nil
        }
        let providers = providersString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return providers.isEmpty ? nil : providers
    }

    /// mimo-v2.5: chosen for its very high usage limits on OpenCode Go.
    /// Probed 2026-08-01: swallows 312k-token inputs (so the 800K-char chunks
    /// fit), accepts reasoning_effort, accurate on extraction — but ~5-10x
    /// slower than Luna (11-27s per large call), the price of the headroom.
    private static let opencodeModel = "mimo-v2.5"

    private func resolvedModel(for backend: WebSearchBackend, requested: String) -> String {
        switch backend {
        case .openrouter:
            return requested
        case .openai:
            // Same models as on OpenRouter, native slugs (no gateway prefix).
            if requested.hasPrefix("openai/") { return String(requested.dropFirst("openai/".count)) }
            // A non-OpenAI model was configured (e.g. a Gemini override): fall
            // back to the default so the call still works on this backend.
            let fallback = KeychainHelper.defaultWebSearchModel
            return fallback.hasPrefix("openai/") ? String(fallback.dropFirst("openai/".count)) : fallback
        case .opencode:
            return Self.opencodeModel
        }
    }

    private func apiKey(for backend: WebSearchBackend) -> String {
        // The instance's OpenRouter key wins for that backend (it can carry
        // the BRIGLIA_TEST_OPENROUTER_KEY env override); everything else comes
        // from stored settings via the shared resolver.
        if backend == .openrouter { return openRouterApiKey }
        return WebSearchBackend.storedKey(for: backend)
    }

    /// Model-request headers for `url`: the backend's credential plus the
    /// affinity decorator's output (User-Agent always; the OpenCode session
    /// header when the URL is OpenCode's — required, so a failed affinity
    /// load throws; OpenRouter's optional session header). One
    /// `.ephemeral(executionID)` lane per web run (plan §7.1 site 8).
    func requestHeaders(for backend: WebSearchBackend, url: URL, lane: AffinityLane) throws -> [String: String] {
        let key = apiKey(for: backend)
        var headers = ["Authorization": "Bearer \(key)"]
        for (name, value) in try SessionAffinity.headers(url: url, apiKey: key, lane: lane) {
            headers[name] = value
        }
        return headers
    }

    private func providerPreferences(forModel model: String) -> ORChatReq.Provider {
        // gpt-oss models: restrict to Groq/Vertex (where they're hosted)
        if model.contains("gpt-oss") {
            return .init(
                order: ProviderSettings.order,
                only: ProviderSettings.only,
                allow_fallbacks: ProviderSettings.allowFallbacks,
                sort: nil
            )
        }

        // All other models (Gemini, user-configured): use user's provider order, no restriction
        return .init(
            order: configuredProviderOrder(),
            only: nil,
            allow_fallbacks: true,
            sort: nil
        )
    }

    private func agentModel(for mode: ResearchMode) -> String {
        _ = mode
        return configuredMainModel()
    }

    private func excerptModel(for mode: ResearchMode) -> String {
        mode == .deepResearch ? ORModel.deepExcerpt : ORModel.webExcerpts
    }

    private func agentReasoning(for mode: ResearchMode) -> ORChatReq.Reasoning? {
        _ = mode
        return configuredReasoning()
    }

    private func excerptReasoning(for mode: ResearchMode) -> ORChatReq.Reasoning? {
        mode == .deepResearch ? makeReasoning(.medium) : makeReasoning(ReasoningSettings.excerpts)
    }

    private func maxSteps(for mode: ResearchMode) -> Int {
        mode == .deepResearch ? maxDeepResearchSteps : maxWebSearchSteps
    }

    private func modeLabel(_ mode: ResearchMode) -> String {
        switch mode {
        case .webSearch: return "web_search"
        case .deepResearch: return "web_research_sweep"
        }
    }
    
    // MARK: - Utilities
    private func normalize(_ link: String) -> String {
        guard var c = URLComponents(string: link) else { return link }
        c.queryItems = c.queryItems?.filter { !["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "gclid", "fbclid", "igshid"].contains($0.name.lowercased()) }
        c.fragment = nil
        return c.string ?? link
    }
    
    private func makeChunks(for s: String, chunk: Int, maxChunks: Int, overlap: Int) -> [String] {
        guard !s.isEmpty, chunk > 0, maxChunks > 0 else { return [] }
        let n = s.count
        var result: [String] = []
        let step = max(1, chunk - max(0, overlap))
        var startOffset = 0
        for _ in 0..<maxChunks {
            if startOffset >= n { break }
            let endOffset = min(startOffset + chunk, n)
            let startIdx = s.index(s.startIndex, offsetBy: startOffset)
            let endIdx = s.index(s.startIndex, offsetBy: endOffset)
            result.append(String(s[startIdx..<endIdx]))
            if endOffset == n { break }
            startOffset += step
        }
        return result
    }
    
    private func dedupeExcerpts(_ arr: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in arr {
            let key = x.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, seen.insert(key).inserted { out.append(x) }
        }
        return out
    }

    private func dedupeLinks(_ arr: [ExtractedLink]) -> [ExtractedLink] {
        var seen = Set<String>()
        var out: [ExtractedLink] = []
        for x in arr {
            let key = x.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, seen.insert(key).inserted { out.append(x) }
        }
        return out
    }

    private func dedupeImages(_ arr: [ExtractedImage]) -> [ExtractedImage] {
        var seen = Set<String>()
        var out: [ExtractedImage] = []
        for x in arr {
            let key = (x.url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                ?? "caption:\(x.caption.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            if !key.isEmpty, seen.insert(key).inserted { out.append(x) }
        }
        return out
    }
}
