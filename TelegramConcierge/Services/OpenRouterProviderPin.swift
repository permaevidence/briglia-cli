import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `/orprovider` — pin the main agent's OpenRouter requests to one upstream
/// host (owner request 2026-09-19). OpenRouter serves most models from many
/// hosts and load-balances between them; a pin makes the host, the caching
/// and the billing deterministic.
///
/// Storage: the pre-existing `openrouter_providers` value (comma-separated
/// OpenRouter provider slugs), which `OpenRouterService.providers(for:)` has
/// always sent as `provider.only` + `allow_fallbacks: false` on main-agent
/// requests — a HARD pin: when the host is down or the account cannot use
/// it, the request fails with OpenRouter's error instead of hopping. Before
/// this command the value could only be edited by hand. Scope is the main
/// agent only: the web pipeline runs a different model, so a pin that fits
/// the chat model would break research there (WebOrchestrator no longer
/// reads the key).
///
/// Slugs follow OpenRouter's provider-routing rules: a base slug
/// (`deepinfra`) matches every endpoint of that provider, a full tag
/// (`deepinfra/turbo`, `google-vertex/us-east5`) targets one variant. The
/// menu offers base slugs read live from `GET /models/{id}/endpoints`;
/// anything typed is validated against the same list when it can be fetched.
enum OpenRouterProviderPin {
    static let storageKey = KeychainHelper.openRouterProvidersKey
    /// Test seam (smoke): `BRIGLIA_OPENROUTER_API_BASE` redirects the
    /// endpoint listing to a mock server, like `BRIGLIA_TELEGRAM_API_BASE`.
    static var apiBase: String {
        if let override = ProcessInfo.processInfo.environment["BRIGLIA_OPENROUTER_API_BASE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override.hasSuffix("/") ? String(override.dropLast()) : override
        }
        return "https://openrouter.ai/api/v1"
    }

    struct Endpoint: Equatable {
        let providerName: String
        /// Full OpenRouter endpoint tag, e.g. "novita/fp8", "z-ai/fp8", "deepseek".
        let tag: String
        let promptUSDPerM: Double?
        let completionUSDPerM: Double?
        let cacheReadUSDPerM: Double?
        let contextLength: Int?
        let uptimeLast30m: Double?
        let status: Int?

        /// The part before the first "/", which `provider.only` treats as
        /// "every endpoint of this provider".
        var baseSlug: String { OpenRouterProviderPin.baseSlug(tag) }
    }

    struct FetchError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Slugs

    static func baseSlug(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = trimmed.firstIndex(of: "/") { return String(trimmed[..<slash]) }
        return trimmed
    }

    private static let slugScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-/")

    /// Lowercased, charset-checked slug, or nil when the text cannot be an
    /// OpenRouter provider slug (spaces, quotes, JSON, a second command…).
    static func normalizedSlug(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.count <= 64,
              !value.hasPrefix("/"), !value.hasSuffix("/"), !value.contains("//"),
              value.unicodeScalars.allSatisfy({ slugScalars.contains($0) }) else { return nil }
        return value
    }

    /// Does a pin (base slug or full tag) select this endpoint? Mirrors
    /// OpenRouter's base-slug matching: `deepinfra` matches `deepinfra` and
    /// `deepinfra/turbo`; `deepinfra/turbo` matches only itself.
    static func matches(pin: String, endpoint: Endpoint) -> Bool {
        let pinValue = pin.lowercased()
        let tag = endpoint.tag.lowercased()
        if pinValue.contains("/") { return tag == pinValue }
        return endpoint.baseSlug == pinValue
    }

    // MARK: Storage

    /// The stored pin as slugs (empty when routing is automatic).
    static func pinnedSlugs() -> [String] {
        guard let raw = KeychainHelper.load(key: storageKey) else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static var isPinned: Bool { !pinnedSlugs().isEmpty }

    /// A stored pin only means anything while OpenRouter is the active
    /// provider: `providers(for:)` never reads it on a custom endpoint, and
    /// the lane bypass below must not touch OpenCode/local lane picks.
    static var appliesToActiveProvider: Bool {
        isPinned && LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey)) == .openRouter
    }

    /// Scope (owner decision 2026-09-19 03:03 EDT): the pin governs the
    /// MAIN MODEL wherever it runs — the main agent, and every subagent,
    /// which runs on exactly the main model while a pin is set because the
    /// cheap-vision/cheap-text lanes are bypassed (`SubagentModelLanes`;
    /// the picks stay stored and return on release). Anything on another
    /// model keeps OpenRouter's automatic routing: the Web researcher and
    /// the legacy web pipeline (their own backend and key), a configured
    /// description model, the OCR/vision preprocessor (own ZDR routing).
    static let scopeNote = "Applies to the main model: the main agent and every subagent, the Web researcher included (cheap lanes are bypassed while pinned)."

    /// Persist a pin (nil or empty clears it). Slugs are stored verbatim
    /// after normalization — the caller validates them first.
    static func setPin(_ slugs: [String]?) throws {
        let cleaned = (slugs ?? []).compactMap(normalizedSlug)
        if cleaned.isEmpty {
            try KeychainHelper.delete(key: storageKey)
        } else {
            try KeychainHelper.save(key: storageKey, value: cleaned.joined(separator: ","))
        }
    }

    /// One line for /status and doctor when a pin is set; nil otherwise.
    static func statusLine() -> String? {
        let slugs = pinnedSlugs()
        guard !slugs.isEmpty else { return nil }
        return "📌 OpenRouter host pin: \(slugs.joined(separator: ", ")) (main model: main agent + subagents, not web research; /orprovider off to release)"
    }

    // MARK: Endpoint listing

    /// Parse `GET /models/{id}/endpoints`. Tolerant of missing fields — the
    /// listing is informational; only `tag`/`provider_name` are required.
    static func parseEndpoints(_ data: Data) throws -> [Endpoint] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let list = payload["endpoints"] as? [[String: Any]] else {
            throw FetchError(description: "unexpected /endpoints response shape")
        }
        var seen = Set<String>()
        var result: [Endpoint] = []
        for item in list {
            let name = (item["provider_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawTag = ((item["tag"] as? String) ?? name).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !rawTag.isEmpty, seen.insert(rawTag).inserted else { continue }
            let pricing = item["pricing"] as? [String: Any] ?? [:]
            result.append(Endpoint(
                providerName: name.isEmpty ? rawTag : name,
                tag: rawTag,
                promptUSDPerM: perMillion(pricing["prompt"]),
                completionUSDPerM: perMillion(pricing["completion"]),
                cacheReadUSDPerM: perMillion(pricing["input_cache_read"]),
                contextLength: (item["context_length"] as? NSNumber)?.intValue,
                uptimeLast30m: (item["uptime_last_30m"] as? NSNumber)?.doubleValue,
                status: (item["status"] as? NSNumber)?.intValue))
        }
        return result
    }

    private static func perMillion(_ value: Any?) -> Double? {
        let perToken: Double?
        if let number = value as? NSNumber { perToken = number.doubleValue }
        else if let text = value as? String { perToken = Double(text) }
        else { perToken = nil }
        guard let perToken, perToken.isFinite, perToken >= 0 else { return nil }
        return perToken * 1_000_000
    }

    /// Base-slug view of a listing: one row per provider, keeping the first
    /// (OpenRouter lists cheapest first) endpoint's figures.
    static func baseChoices(_ endpoints: [Endpoint]) -> [Endpoint] {
        var seen = Set<String>()
        return endpoints.filter { seen.insert($0.baseSlug).inserted }
    }

    /// "Novita (novita) · $0.13/$0.44 per M · cache $0.03 · up 99.7%"
    static func describe(_ endpoint: Endpoint, pinned: Bool = false) -> String {
        var parts: [String] = []
        if let p = endpoint.promptUSDPerM, let c = endpoint.completionUSDPerM {
            parts.append("$\(money(p))/$\(money(c)) per M")
        }
        if let cache = endpoint.cacheReadUSDPerM { parts.append("cache $\(money(cache))") }
        if let uptime = endpoint.uptimeLast30m { parts.append("up \(String(format: "%.1f", uptime))%") }
        if let status = endpoint.status, status < 0 { parts.append("degraded") }
        let head = "\(pinned ? "📌 " : "")\(endpoint.providerName) (\(endpoint.baseSlug))"
        return parts.isEmpty ? head : head + " · " + parts.joined(separator: " · ")
    }

    private static func money(_ value: Double) -> String {
        if value == 0 { return "0" }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Test seam: replaces the network fetch (model, apiKey) → raw JSON.
    nonisolated(unsafe) static var fetchOverride: ((String, String) async throws -> Data)? = nil

    /// Live listing for a model. Never retries auth errors; one retry on
    /// 429/5xx. Throws `FetchError` with a user-facing description.
    /// Cancellation is propagated as `CancellationError` — whether it
    /// arrives as the task flag (checked on entry AND again after every
    /// suspension, because a cooperative cancellation can land while the
    /// transport is completing normally or failing for its own reasons), a
    /// `URLError.cancelled` from the session, or during the retry pause —
    /// never converted into a retry or a `FetchError` (Codex R3 rounds 1–2:
    /// a cancelled lookup must not look like a successful or a failed one,
    /// because the caller treats failure as "save anyway").
    static func fetchEndpoints(model: String, apiKey: String) async throws -> [Endpoint] {
        try Task.checkCancellation()
        if let fetchOverride {
            do {
                let endpoints = try parseEndpoints(try await fetchOverride(model, apiKey))
                try Task.checkCancellation()
                return endpoints
            } catch {
                if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
        guard let encoded = model.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))),
              let url = URL(string: "\(apiBase)/models/\(encoded)/endpoints") else {
            throw FetchError(description: "model id \"\(model)\" cannot be encoded in a URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var lastError: Error = FetchError(description: "no response")
        for attempt in 1...2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                try Task.checkCancellation()
                switch http.statusCode {
                case 200:
                    return try parseEndpoints(data)
                case 404:
                    throw FetchError(description: "OpenRouter has no model \"\(model)\" (HTTP 404)")
                case 401, 403:
                    throw FetchError(description: "OpenRouter refused the API key (HTTP \(http.statusCode))")
                case 429, 500...599:
                    lastError = FetchError(description: "OpenRouter answered HTTP \(http.statusCode)")
                default:
                    throw FetchError(description: "OpenRouter answered HTTP \(http.statusCode)")
                }
            } catch let error as FetchError {
                if Task.isCancelled { throw CancellationError() }
                throw error
            } catch {
                if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
                lastError = FetchError(description: error.localizedDescription)
            }
            if attempt < 2 {
                // A cancelled pause ends the lookup as cancelled, not as
                // the previous attempt's error.
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw lastError
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Validation verdict for a requested pin against a listing.
    enum Verdict: Equatable {
        /// Matching endpoints, e.g. one base slug covering two variants.
        case served([Endpoint])
        case notServed(available: [String])
    }

    static func validate(pin: String, endpoints: [Endpoint]) -> Verdict {
        let hits = endpoints.filter { matches(pin: pin, endpoint: $0) }
        if hits.isEmpty {
            return .notServed(available: baseChoices(endpoints).map(\.baseSlug))
        }
        return .served(hits)
    }
}
