import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Later cost lookup for OpenRouter extraction requests Briglia stopped
/// waiting for at their total deadline (ToolChargeLedger's cut-request
/// incidents). OpenRouter keeps generating and billing a non-streaming
/// request after the client leaves; its generation record
/// (GET /api/v1/generation?id=…) reports `total_cost` once it exists.
/// Until a lookup finds a cost the amount stays UNKNOWN (an open or
/// accepted incident) — never an estimate. Zero only on evidence: a record
/// that says the request was CANCELLED and reports `total_cost` exactly 0
/// (owner decision 2026-09-29; both field cuts of that day read
/// `cancelled:true`, upstream status 499, `total_cost 0`). A reported 0
/// without `cancelled:true`, or no record, stays unknown.
///
/// Also looks up the record of a FAILED extractor attempt, off the critical
/// path, only to log its host, tokens and cost (a non-streamed request's
/// deadline cut otherwise logs `provider=-`).
///
/// Driven by the daemon's idle poll, at most once per `minInterval`, one
/// run at a time; looks only at incidents younger than seven days.
enum CutRequestCostLookup {
    static let minInterval: TimeInterval = 300
    /// Selftest seam: replaces the HTTP lookup (cost only; no cancellation
    /// evidence, so a 0 it returns never settles an incident).
    nonisolated(unsafe) static var lookupOverride: ((String) async -> Double?)?
    /// Selftest seam: replaces the HTTP lookup with a whole record.
    nonisolated(unsafe) static var recordOverride: ((String) async -> OpenRouterGenerationRecord?)?
    /// Pauses before each failure-log lookup try (the record appears a few
    /// seconds after the request ends). Selftests shrink them.
    nonisolated(unsafe) static var failureLookupDelays: [TimeInterval] = [3, 10, 30]

    private actor Gate {
        var running = false
        var lastStart: TimeInterval = -.infinity
        func runIfDue() async {
            let now = ProcessInfo.processInfo.systemUptime
            guard !running, now - lastStart >= CutRequestCostLookup.minInterval,
                  !ToolChargeLedger.pendingCutRequests().isEmpty else { return }
            running = true; lastStart = now
            await ToolChargeLedger.reconcileCutRequestRecords(lookupRecord: CutRequestCostLookup.lookupRecord)
            running = false
        }
    }
    private static let gate = Gate()

    /// Idle hook (non-blocking).
    static func kickIfDue() {
        Task.detached { await gate.runIfDue() }
    }

    /// The generation's reported cost, or nil when unavailable (no key,
    /// not found yet, error, no cost field).
    static func lookup(_ generationId: String) async -> Double? {
        await lookupRecord(generationId)?.totalCost
    }

    /// The generation record, or nil when unavailable (no key, not found
    /// yet, error, unparseable).
    static func lookupRecord(_ generationId: String) async -> OpenRouterGenerationRecord? {
        if let recordOverride { return await recordOverride(generationId) }
        if let lookupOverride { return await lookupOverride(generationId).map { OpenRouterGenerationRecord(totalCost: $0) } }
        guard let key = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, var components = URLComponents(string: "https://openrouter.ai/api/v1/generation") else { return nil }
        components.queryItems = [URLQueryItem(name: "id", value: generationId)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseRecord(data)
    }

    /// `data.total_cost` of a generation record.
    static func parseTotalCost(_ data: Data) -> Double? {
        parseRecord(data)?.totalCost
    }

    /// The fields Briglia uses from `GET /api/v1/generation` (`data` object).
    static func parseRecord(_ data: Data) -> OpenRouterGenerationRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = object["data"] as? [String: Any] else { return nil }
        // Darwin bridges numbers as NSNumber; corelibs may hand back Double/Int.
        func number(_ raw: Any?) -> Double? {
            guard let raw, !(raw is NSNull) else { return nil }
            if let b = raw as? Bool, !(raw is NSNumber) { return b ? 1 : 0 }
            let value = (raw as? Double) ?? (raw as? Int).map(Double.init) ?? (raw as? NSNumber)?.doubleValue
            guard let value, value.isFinite else { return nil }
            return value
        }
        func int(_ raw: Any?) -> Int? { number(raw).flatMap { $0 >= 0 && $0 < 1e12 ? Int($0) : nil } }
        func bool(_ raw: Any?) -> Bool? {
            if let b = raw as? Bool { return b }
            if let n = raw as? NSNumber { return n.boolValue }
            return nil
        }
        var out = OpenRouterGenerationRecord()
        if let cost = number(record["total_cost"]), cost >= 0 { out.totalCost = cost }
        out.cancelled = bool(record["cancelled"])
        out.provider = (record["provider_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        out.promptTokens = int(record["native_tokens_prompt"]) ?? int(record["tokens_prompt"])
        out.completionTokens = int(record["native_tokens_completion"]) ?? int(record["tokens_completion"])
        out.reasoningTokens = int(record["native_tokens_reasoning"])
        out.finishReason = record["native_finish_reason"] as? String ?? record["finish_reason"] as? String
        out.generationTimeMs = number(record["generation_time"])
        if let responses = record["provider_responses"] as? [[String: Any]], let last = responses.last {
            out.upstreamStatus = int(last["status"])
        }
        return out
    }

    // MARK: Failure logging (off the critical path)

    private actor FailureLog {
        var inFlight = 0
        var seen: [String] = []
        func admit(_ id: String) -> Bool {
            guard inFlight < 4, !seen.contains(id) else { return false }
            inFlight += 1
            seen.append(id); if seen.count > 256 { seen.removeFirst(seen.count - 256) }
            return true
        }
        func done() { inFlight -= 1 }
    }
    private static let failureLog = FailureLog()

    /// After a failed OpenRouter attempt whose generation id is known (a
    /// deadline cut, an empty or starved completion, a dropped connection),
    /// look its record up in the background and log the host, tokens and
    /// cost. Never awaited by the stage; bounded (at most 4 lookups at a
    /// time, each id once, a few tries over ~45 s, 30 s per request).
    /// Logging only: settlement stays with the idle reconcile.
    static func logAfterFailure(stage: String, generationId: String?, after kind: String) {
        guard let generationId, !generationId.isEmpty else { return }
        let delays = failureLookupDelays
        Task.detached(priority: .utility) {
            guard await failureLog.admit(generationId) else { return }
            var found: OpenRouterGenerationRecord?
            for delay in delays {
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                if let record = await lookupRecord(generationId) { found = record; break }
            }
            if let found {
                webLog("[WebOrchestrator] openrouter stage=\(stage) GENERATION_LOOKUP gen=\(generationId) after=\(kind) \(found.logFields)")
            } else {
                webLog("[WebOrchestrator] openrouter stage=\(stage) GENERATION_LOOKUP gen=\(generationId) after=\(kind) not_found tries=\(delays.count)")
            }
            await failureLog.done()
        }
    }
}

/// The parts of an OpenRouter generation record Briglia uses.
struct OpenRouterGenerationRecord: Equatable {
    var totalCost: Double?
    var cancelled: Bool?
    var provider: String?
    var upstreamStatus: Int?
    var promptTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    var finishReason: String?
    var generationTimeMs: Double?

    init(totalCost: Double? = nil, cancelled: Bool? = nil, provider: String? = nil) {
        self.totalCost = totalCost; self.cancelled = cancelled; self.provider = provider
    }

    /// The amount that settles a cut request's unknown-amount incident, or
    /// nil (it stays unknown): a positive reported cost, or exactly 0 when
    /// the record also says the request was cancelled.
    var settlementCost: Double? {
        guard let cost = totalCost, cost.isFinite, cost >= 0 else { return nil }
        if cost > 0 { return cost }
        return cancelled == true ? 0 : nil
    }

    var logFields: String {
        func s<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "-" }
        let time = generationTimeMs.map { String(format: "%.1f", $0 / 1000) } ?? "-"
        return "provider=\(provider ?? "-") upstream_status=\(s(upstreamStatus)) cancelled=\(s(cancelled)) finish=\(finishReason ?? "-") prompt_tokens=\(s(promptTokens)) completion_tokens=\(s(completionTokens)) reasoning_tokens=\(s(reasoningTokens)) generation_s=\(time) cost=\(totalCost.map { SpendGate.formatUSD($0) } ?? "-")"
    }
}
