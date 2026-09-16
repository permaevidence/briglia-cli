import Foundation

// MARK: - Web researcher tools (WEB_SUBAGENT_PLAN §4.2, R1a)
//
// `web_query` and `web_extract` are the pipeline's internal `search` and
// `fetch_and_extract` tools as first-class tools of the `Web` subagent
// preset: same shapes, same per-call caps, same in-tool compression,
// dispatched to `WebOrchestrator.executeWebQuery` / `executeWebExtract`.
// Differences from the loop, exactly as planned: a search never hides a
// result already retrieved in the session (it is listed with its earlier
// retrieval time and in-context flag instead of the loop's
// `omitted_repeats`), and every page read reports `fetched_at` = the time
// of THAT reader request (no cache on this path). Tool-internal spend rides
// on `ToolResultMessage.spendUSD` as for the legacy tools.

/// Rendered result of one `web_query` call.
struct WebQueryPayload: Encodable {
    struct Hit: Encodable {
        let title: String
        let snippet: String
        let link: String
        let source: String
        let date: String?
        /// Set when a page extract of this URL exists in the session's
        /// evidence ledger: when it was retrieved and whether that extract
        /// is still in the model's context. Never used to hide the hit.
        var previously_retrieved: String? = nil
        var extract_in_context: Bool? = nil
    }
    let results: [Hit]
    var answer_box: WebAnswerBox? = nil
    var knowledge_graph: WebKG? = nil
    var people_also_ask: [WebPAA]? = nil
    var top_stories: [WebTop]? = nil
    var failed_queries: [String]? = nil
    var dropped_queries: Int? = nil
}

/// Rendered result of one `web_extract` call.
struct WebExtractPayload: Encodable {
    struct Page: Encodable {
        let url: String
        let title: String?
        let excerpts: [String]
        var relevant_links: [ExtractedLink]? = nil
        var relevant_images: [ExtractedImage]? = nil
        var excerpts_truncated: Bool? = nil
        /// Time of this call's reader request ("new reader request").
        let fetched_at: String
        /// "<earlier fetched_at> (in context: yes/no); new reader request at <fetched_at>"
        var previously_fetched: String? = nil
    }
    let pages: [Page]
    var failed_urls: [String]? = nil
    var dropped_requests: Int? = nil
}

struct WebQueryArguments: Decodable { let queries: [String] }
struct WebExtractArguments: Decodable { let requests: [ScrapeRequest] }

extension ToolExecutor {
    private func encodeWebPayload<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(value), encoding: .utf8) ?? "{}") ?? "{}"
    }

    func executeWebQuery(_ call: ToolCall) async -> ToolResultMessage {
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebQueryArguments.self, from: data),
              !args.queries.isEmpty else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Could not parse arguments. Expected {\\\"queries\\\": [\\\"...\\\"]} with at least one query.\"}")
        }
        do {
            let outcome = try await webOrchestrator.executeWebQuery(queries: args.queries)
            let ledger = webEvidenceLedger
            ledger?.appendQueries(outcome.queriesRun)
            var hits: [WebQueryPayload.Hit] = []
            for result in outcome.context.results {
                var hit = WebQueryPayload.Hit(title: result.title, snippet: result.snippet, link: result.link,
                                              source: result.source, date: result.date)
                if let ledger {
                    let normalized = await webOrchestrator.normalizedURL(result.link)
                    if let prior = ledger.priorRetrievals(of: normalized).filter(\.isExtract).last {
                        hit.previously_retrieved = Self.webTimestamp(prior.fetchedAt)
                        hit.extract_in_context = prior.inContext
                    }
                }
                hits.append(hit)
            }
            let payload = WebQueryPayload(
                results: hits,
                answer_box: outcome.context.answerBox,
                knowledge_graph: outcome.context.knowledgeGraph,
                people_also_ask: outcome.context.peopleAlsoAsk,
                top_stories: outcome.context.topStories,
                failed_queries: outcome.failures.isEmpty ? nil : outcome.failures,
                dropped_queries: outcome.dropped > 0 ? outcome.dropped : nil)
            let allFailed = !outcome.gotResults && !outcome.failures.isEmpty && outcome.failures.count >= outcome.queriesRun.count
            ledger?.recordAttempt(usable: outcome.gotResults, allFailed: allFailed,
                                  failures: outcome.failures.map { "search — \($0)" })
            return ToolResultMessage(toolCallId: call.id, content: encodeWebPayload(payload))
        } catch is CancellationError {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"web_query cancelled\"}")
        } catch {
            webEvidenceLedger?.recordAttempt(usable: false, allFailed: true, failures: ["search — \(error.localizedDescription)"])
            return ToolResultMessage(toolCallId: call.id,
                                     content: jsonObjectString(["error": webPipelineFailureText("web_query failed", error: error)]))
        }
    }

    func executeWebExtract(_ call: ToolCall) async -> ToolResultMessage {
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebExtractArguments.self, from: data),
              !args.requests.isEmpty else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Could not parse arguments. Expected {\\\"requests\\\": [{\\\"url\\\": \\\"...\\\", \\\"focus\\\": \\\"...\\\"}]} with at least one request.\"}")
        }
        for request in args.requests where !(request.url.hasPrefix("http://") || request.url.hasPrefix("https://")) {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Invalid URL '\(request.url)': must start with http:// or https://\"}")
        }
        let ledger = webEvidenceLedger
        // Report deliverables get the deeper excerpt pass (the pipeline's
        // deep-research extraction); short/standard the lighter one.
        let mode: ResearchMode = ledger?.deliverable == .report ? .deepResearch : .webSearch
        do {
            let outcome = try await webOrchestrator.executeWebExtract(requests: args.requests, mode: mode)
            let fetchedAtLabel = Self.webTimestamp(outcome.fetchedAt)
            let perDocBudget = WebOrchestrator.webExtractPayloadBudget / max(1, outcome.docs.count)
            var pages: [WebExtractPayload.Page] = []
            var records: [WebEvidenceRecord] = []
            // Concurrent fetches complete in any order: render (and record)
            // in the model's request order, deterministic across runs.
            let requestOrder = args.requests.map(\.url)
            let orderedDocs = outcome.docs.sorted { (requestOrder.firstIndex(of: $0.url) ?? .max) < (requestOrder.firstIndex(of: $1.url) ?? .max) }
            for doc in orderedDocs {
                let (kept, truncated) = WebAgentSupport.clampExcerpts(doc.excerpts, totalBudget: perDocBudget)
                var page = WebExtractPayload.Page(url: doc.url, title: doc.title, excerpts: kept,
                                                  relevant_links: doc.links.isEmpty ? nil : doc.links,
                                                  relevant_images: doc.images.isEmpty ? nil : doc.images,
                                                  excerpts_truncated: truncated ? true : nil,
                                                  fetched_at: fetchedAtLabel)
                let normalized = await webOrchestrator.normalizedURL(doc.url)
                if let prior = ledger?.priorRetrievals(of: normalized).last {
                    page.previously_fetched = "\(Self.webTimestamp(prior.fetchedAt)) (in context: \(prior.inContext ? "yes" : "no")); new reader request at \(fetchedAtLabel)"
                }
                pages.append(page)
                records.append(WebEvidenceRecord(url: normalized, fetchedAt: outcome.fetchedAt, toolCallId: call.id,
                                                 servedFromCache: false, isExtract: true, usable: !doc.excerpts.isEmpty))
            }
            let payload = WebExtractPayload(pages: pages,
                                            failed_urls: outcome.failures.isEmpty ? nil : outcome.failures,
                                            dropped_requests: outcome.dropped > 0 ? outcome.dropped : nil)
            let usable = outcome.docs.contains { !$0.excerpts.isEmpty }
            ledger?.append(records)
            ledger?.recordAttempt(usable: usable, allFailed: outcome.docs.isEmpty && !outcome.failures.isEmpty,
                                  failures: outcome.failures.map { "scrape — \($0)" })
            return ToolResultMessage(toolCallId: call.id, content: encodeWebPayload(payload),
                                     spendUSD: outcome.spendUSD > 0 ? outcome.spendUSD : nil)
        } catch is CancellationError {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"web_extract cancelled\"}")
        } catch {
            ledger?.recordAttempt(usable: false, allFailed: true, failures: ["scrape — \(error.localizedDescription)"])
            return ToolResultMessage(toolCallId: call.id,
                                     content: jsonObjectString(["error": webPipelineFailureText("web_extract failed", error: error)]))
        }
    }
}
