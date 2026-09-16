import Foundation

// MARK: - Web evidence ledger (WEB_SUBAGENT_PLAN §4.2, §4.5)
//
// Replaces the pipeline's `seenLinks` set for the Web researcher subagent:
// one record PER RETRIEVAL RESULT (not per URL), persisted with the
// session, so evicting one of several extracts of a URL never marks the
// others absent. `inContext` flips to false only when a COMMITTED
// compaction evicts the round that held the result (a declined or failed
// compaction changes nothing). The ledger is an audit trail of what was
// retrieved, never a claim that the cited pages support every statement.

/// One retrieval result of a URL, as persisted in the session file.
struct WebEvidenceRecord: Codable, Equatable {
    /// Normalized URL (the pipeline's `normalize`).
    let url: String
    /// When the reader obtained the source bytes (`fetched_at`), or, for a
    /// search hit, when the search ran. Never the conversation time.
    let fetchedAt: Date
    /// The tool call that produced this result (round reference for the
    /// in-context bookkeeping).
    let toolCallId: String
    /// Whether the bytes came from the web_fetch cache rather than a new
    /// reader request.
    var servedFromCache: Bool = false
    /// Whether the result's round is still in the session context (true
    /// until a committed compaction evicts it).
    var inContext: Bool = true
    /// Whether this record is a page extract (web_extract / web_fetch) as
    /// opposed to a search hit listing.
    var isExtract: Bool = true
    /// Whether the retrieval returned usable content.
    var usable: Bool = true
    /// Search-hit records only (Codex R1a review R3): the query that
    /// surfaced this hit. A hit is evidence the run SAW (title, snippet,
    /// answer box, knowledge graph) — never that the page was read; the
    /// `url` is the hit's link, or empty for URL-less answer-box /
    /// knowledge-graph evidence (no URL is ever invented).
    var query: String? = nil
}

/// `(inContext, total)` over one class of usable records.
struct WebEvidenceCounts: Equatable {
    var inContext: Int
    var total: Int
}

/// Earlier evidence in the session, by class (§4.5): page extracts (read)
/// and search results (seen). Both classes count as evidence; the parent
/// gets both figures so "n of m" never conflates reading with seeing.
struct WebPriorEvidence: Equatable {
    var extracts: WebEvidenceCounts
    var searchResults: WebEvidenceCounts
    var total: Int { extracts.total + searchResults.total }
    static let none = WebPriorEvidence(extracts: .init(inContext: 0, total: 0), searchResults: .init(inContext: 0, total: 0))
}

/// One search result the run saw, for `search_results_seen`.
struct WebSearchEvidenceSummary: Equatable {
    /// Distinct hit URLs in first-seen order, each with the first query that
    /// surfaced it and when that search ran.
    var hits: [(url: String, query: String, retrievedAt: Date)]
    /// URL-less evidence (answer boxes, knowledge graphs) seen.
    var urlless: Int
    static func == (a: WebSearchEvidenceSummary, b: WebSearchEvidenceSummary) -> Bool {
        a.urlless == b.urlless && a.hits.count == b.hits.count
            && zip(a.hits, b.hits).allSatisfy { $0.url == $1.url && $0.query == $1.query && $0.retrievedAt == $1.retrievedAt }
    }
}

/// Per-run retrieval activity, for the mechanical provenance label
/// (§4.5). Counts describe activity only.
struct WebRetrievalActivity: Equatable {
    /// Executed web tool calls that reached the network (bad-argument tool
    /// errors do not count).
    var attempted = 0
    /// Calls that returned usable evidence (`gotResults`: organic results,
    /// answer box or knowledge graph for a search; a non-empty extract for
    /// a page read).
    var usable = 0
    /// Calls where every request failed (nothing retrieved).
    var failed = 0
    /// First failure strings, for the `web_tools_failed` error.
    var failureMessages: [String] = []
}

/// The Web researcher's per-session ledger, shared between the runner
/// (which persists it with the session and applies compaction evictions)
/// and the child executor's web tools (which consult and extend it).
/// Class with a lock because both sides are actors of different kinds;
/// every method is a short critical section.
final class WebEvidenceLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [WebEvidenceRecord]
    private var queries: [String]
    private var activity = WebRetrievalActivity()
    /// The run's deliverable (drives excerpt-extraction depth in the tools).
    let deliverable: WebDeliverable

    init(records: [WebEvidenceRecord] = [], queries: [String] = [], deliverable: WebDeliverable = .standard) {
        self.records = records
        self.queries = queries
        self.deliverable = deliverable
    }

    // MARK: Reads

    var allRecords: [WebEvidenceRecord] { lock.lock(); defer { lock.unlock() }; return records }
    var queriesUsed: [String] { lock.lock(); defer { lock.unlock() }; return queries }
    var runActivity: WebRetrievalActivity { lock.lock(); defer { lock.unlock() }; return activity }

    /// Earlier retrievals of `url` (any tool), oldest first.
    func priorRetrievals(of url: String) -> [WebEvidenceRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.filter { $0.url == url && $0.usable }
    }

    /// `(inContext, total)` over the usable page extracts of the session —
    /// the "n of m earlier extracts still in context" figure.
    var extractCounts: (inContext: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        let extracts = records.filter { $0.isExtract && $0.usable }
        return (extracts.filter(\.inContext).count, extracts.count)
    }

    /// `(inContext, total)` over the usable search-hit records — evidence
    /// seen in search results (R3), tracked separately from page reads.
    var searchCounts: (inContext: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        let hits = records.filter { !$0.isExtract && $0.usable }
        return (hits.filter(\.inContext).count, hits.count)
    }

    /// Both classes of earlier evidence, for the provenance label and the
    /// parent's "n of m" figures.
    var priorEvidence: WebPriorEvidence {
        let e = extractCounts, s = searchCounts
        return WebPriorEvidence(extracts: .init(inContext: e.inContext, total: e.total),
                                searchResults: .init(inContext: s.inContext, total: s.total))
    }

    /// The search results the session saw (`search_results_seen`): distinct
    /// hit URLs in first-seen order plus the count of URL-less evidence.
    var searchEvidence: WebSearchEvidenceSummary {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        var hits: [(url: String, query: String, retrievedAt: Date)] = []
        var urlless = 0
        for record in records where !record.isExtract && record.usable {
            if record.url.isEmpty { urlless += 1; continue }
            if seen.insert(record.url).inserted { hits.append((record.url, record.query ?? "", record.fetchedAt)) }
        }
        return WebSearchEvidenceSummary(hits: hits, urlless: urlless)
    }

    /// Per-session bound on search-hit records (R3): the newest
    /// `maxSearchRecords` are kept, the oldest dropped first; page extracts
    /// are never dropped. Each `web_query` call adds at most
    /// `maxSearchRecordsPerQuery` hits per query plus one record per
    /// URL-less answer box / knowledge graph.
    static let maxSearchRecords = 400
    static let maxSearchRecordsPerQuery = 10

    /// URLs whose retrieval returned content, in first-retrieved order,
    /// each with its first retrieval time (`sources_consulted`).
    var sourcesConsulted: [(url: String, retrievedAt: Date)] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        var out: [(String, Date)] = []
        for record in records where record.usable && record.isExtract && !seen.contains(record.url) {
            seen.insert(record.url)
            out.append((record.url, record.fetchedAt))
        }
        return out
    }

    // MARK: Writes (tools)

    func appendQueries(_ new: [String]) {
        guard !new.isEmpty else { return }
        lock.lock(); queries.append(contentsOf: new); lock.unlock()
    }

    func append(_ new: [WebEvidenceRecord]) {
        guard !new.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        records.append(contentsOf: new)
        let searchCount = records.filter { !$0.isExtract }.count
        var excess = searchCount - Self.maxSearchRecords
        if excess > 0 {
            records.removeAll { record in
                guard excess > 0, !record.isExtract else { return false }
                excess -= 1
                return true
            }
        }
    }

    /// One executed web tool call: `usable` = it returned usable evidence,
    /// `allFailed` = every request in it failed.
    func recordAttempt(usable: Bool, allFailed: Bool, failures: [String]) {
        lock.lock(); defer { lock.unlock() }
        activity.attempted += 1
        if usable { activity.usable += 1 }
        if allFailed {
            activity.failed += 1
            for failure in failures where activity.failureMessages.count < 5 {
                activity.failureMessages.append(failure)
            }
        }
    }

    // MARK: Writes (runner)

    /// Applied after a COMMITTED compaction: results whose round is no
    /// longer in the session context lose their flag. `keptToolCallIds` is
    /// the set of tool-call ids still present in the compacted context.
    func markEvicted(keeping keptToolCallIds: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for index in records.indices where records[index].inContext && !keptToolCallIds.contains(records[index].toolCallId) {
            records[index].inContext = false
        }
    }
}

/// The Web researcher's answer size (§4.3). Bounds the answer, never the
/// research.
enum WebDeliverable: String, Codable, CaseIterable {
    case short, standard, report

    /// The line appended to the task message.
    var taskLine: String {
        switch self {
        case .short: return "Deliverable: short — a few sentences (about 1,500 characters at most), citations inline, Sources list at the end."
        case .standard: return "Deliverable: standard — one or two screens (about 6,000 characters), citations inline, Sources list at the end."
        case .report: return "Deliverable: report — as long as the material warrants, structured with headings, citations inline and a Sources section."
        }
    }
}

/// Mechanical provenance of one Web run (§4.5). Describes retrieval
/// activity only, never completeness or support.
enum WebEvidenceProvenance: String {
    /// At least one outcome in this run returned usable evidence.
    case retrievedThisRun = "retrieved_this_run"
    /// Lookups ran in this run but none returned usable evidence.
    case attemptedNoResults = "attempted_no_results"
    /// No lookup in this run; the session holds earlier evidence.
    case priorSourcesOnly = "prior_sources_only"
    /// No lookup in this run and no prior evidence in the session.
    case noEvidence = "no_evidence"

    /// `prior` counts BOTH classes of earlier evidence (page extracts and
    /// search results): a session whose only evidence is search snippets is
    /// `prior_sources_only`, never `no_evidence` (Codex R1a review R3).
    static func classify(activity: WebRetrievalActivity, prior: WebPriorEvidence) -> WebEvidenceProvenance {
        if activity.usable > 0 { return .retrievedThisRun }
        if activity.attempted > 0 { return .attemptedNoResults }
        return prior.total > 0 ? .priorSourcesOnly : .noEvidence
    }

    /// Guidance prefix for the parent's `final_message`, or nil.
    func finalMessagePrefix(prior: WebPriorEvidence) -> String? {
        switch self {
        case .retrievedThisRun: return nil
        case .noEvidence, .attemptedNoResults: return "[NO USABLE EVIDENCE RETRIEVED IN THIS RUN]"
        case .priorSourcesOnly:
            return "[FROM RETAINED HISTORY — no new retrieval in this run; \(prior.extracts.inContext) of \(prior.extracts.total) earlier extracts and \(prior.searchResults.inContext) of \(prior.searchResults.total) earlier search results still in context]"
        }
    }
}
