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
    /// The legacy single-pin key (0.2.30–0.2.55), migrated into `OpenRouterPinMap`.
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
        /// `/endpoints` `service_tier`: absent (old listing), explicit null
        /// (standard) or a tier name (plan §2, Codex round 3).
        var serviceTier: TierInfo = .absent

        /// The part before the first "/", which `provider.only` treats as
        /// "every endpoint of this provider".
        var baseSlug: String { OpenRouterProviderPin.baseSlug(tag) }
    }

    enum TierInfo: Equatable {
        case absent
        case null
        case value(String)
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

    // MARK: Eligibility (plan §2 v3 + §13.4)

    enum Eligibility: Equatable {
        case matched
        case notMatched
        /// The client can't establish whether OpenRouter routes this pin to
        /// the endpoint (a tiered non-first-party endpoint): never releases
        /// a user pin and never authorizes an automatic pin.
        case uncertain
    }

    /// Canonical tier names; `fast` and `priority` are interchangeable.
    static let tierAliases: [String: String] = ["flex": "flex", "priority": "priority", "fast": "priority", "ultrafast": "ultrafast"]
    static let firstPartyTierProviders: Set<String> = ["openai", "google-vertex", "google-ai-studio"]

    static func canonicalSegment(_ segment: String) -> String {
        tierAliases[segment] ?? segment
    }

    /// The endpoint's tier (canonical), nil = standard. Metadata first; a
    /// listing without the field falls back to the tag's LAST segment.
    static func tier(of endpoint: Endpoint) -> String? {
        switch endpoint.serviceTier {
        case .null: return nil
        case .value(let raw):
            let t = raw.lowercased()
            if t.isEmpty || t == "standard" || t == "default" { return nil }
            return tierAliases[t] ?? t
        case .absent:
            if OpenRouterPinMap.broken(14) { return nil }
            guard let last = endpoint.tag.lowercased().split(separator: "/").last.map(String.init),
                  endpoint.tag.contains("/") else { return nil }
            return tierAliases[last]
        }
    }

    /// Segment-prefix matching (a base slug is the one-segment case; a
    /// variant matches its regions) plus service-tier rules.
    static func eligibility(pin: String, endpoint: Endpoint) -> Eligibility {
        let pinSegs = pin.lowercased().split(separator: "/").map { canonicalSegment(String($0)) }
        let tagSegs = endpoint.tag.lowercased().split(separator: "/").map { canonicalSegment(String($0)) }
        guard !pinSegs.isEmpty, pinSegs.count <= tagSegs.count, Array(tagSegs.prefix(pinSegs.count)) == pinSegs else { return .notMatched }
        guard let t = tier(of: endpoint) else { return .matched }
        if pinSegs.contains(t) { return .matched }
        if OpenRouterPinMap.broken(15) { return .matched }
        if firstPartyTierProviders.contains(tagSegs[0]) || OpenRouterPinMap.broken(16) { return .notMatched }
        return .uncertain
    }

    /// Does a pin certainly select this endpoint (display, auto-pin)?
    static func matches(pin: String, endpoint: Endpoint) -> Bool {
        eligibility(pin: pin, endpoint: endpoint) == .matched
    }

    // MARK: Storage (per model since v0.2.56 — OpenRouterPinMap)


    /// The effective stored pin for the CURRENT OpenRouter model (empty when
    /// routing is automatic), from one store snapshot.
    static func pinnedSlugs() -> [String] {
        pinnedSlugs(store: KeychainHelper.loadSnapshot())
    }

    static func pinnedSlugs(store: [String: String]) -> [String] {
        guard let model = OpenRouterPinMap.effectiveORModel(store) else { return [] }
        return OpenRouterPinMap.effectivePin(store, model: model) ?? []
    }

    static func pinnedSlugs(for model: String, store: [String: String]) -> [String] {
        OpenRouterPinMap.effectivePin(store, model: model) ?? []
    }

    static var isPinned: Bool {
        if OpenRouterPinMap.broken(8) { return OpenRouterPinMap.state(KeychainHelper.loadSnapshot()).map?.models.values.contains { !$0.hosts.isEmpty } ?? false }
        return !pinnedSlugs().isEmpty
    }

    /// Selftest helper: set (nil/empty = remove) the CURRENT OpenRouter
    /// model's user pin directly; with no OpenRouter model it writes the
    /// legacy single pin (what older builds stored).
    static func _testSetPin(_ slugs: [String]?) throws {
        let cleaned = (slugs ?? []).compactMap(normalizedSlug)
        try KeychainHelper.transaction { store in
            try OpenRouterPinMap.migrate(&store)
            guard let model = OpenRouterPinMap.effectiveORModel(store) else {
                if cleaned.isEmpty { store.removeValue(forKey: OpenRouterPinMap.legacyKey) }
                else { store[OpenRouterPinMap.legacyKey] = cleaned.joined(separator: ",") }
                return
            }
            var map = OpenRouterPinMap.state(store).map ?? { var m = OpenRouterPinMap.Map.fresh(iid: OpenRouterPinMap.newIID()); m.rev = 0; return m }()
            map.models[model] = cleaned.isEmpty ? nil : .init(hosts: cleaned, by: .user, at: OpenRouterPinMap.timestamp(Date()))
            store.removeValue(forKey: OpenRouterPinMap.legacyKey)
            try OpenRouterPinMap.store(map, into: &store)
        }
    }

    /// A stored pin only means anything while OpenRouter is the active
    /// provider: `providers(for:)` never reads it on a custom endpoint, and
    /// the lane bypass below must not touch OpenCode/local lane picks.
    static var appliesToActiveProvider: Bool {
        let store = KeychainHelper.loadSnapshot()
        return LLMProvider.fromStoredValue(store[KeychainHelper.llmProviderKey]) == .openRouter && !pinnedSlugs(store: store).isEmpty
    }

    /// Scope (owner decision 2026-09-19 03:03 EDT): the pin governs the
    /// MAIN MODEL wherever it runs — the main agent, and every subagent,
    /// which runs on exactly the main model while a pin is set because the
    /// cheap-vision/cheap-text lanes are bypassed (`SubagentModelLanes`;
    /// the picks stay stored and return on release). Anything on another
    /// model keeps OpenRouter's automatic routing: the Web researcher and
    /// the legacy web pipeline (their own backend and key), a configured
    /// description model, the OCR/vision preprocessor (own ZDR routing).
    static let scopeNote = "Applies to the main model: the main agent and every subagent, the Web researcher included (cheap lanes are bypassed while pinned). Each OpenRouter model remembers its own host."

    /// One line for /status and doctor; nil when nothing worth saying.
    static func statusLine(store: [String: String] = KeychainHelper.loadSnapshot()) -> String? {
        guard let model = OpenRouterPinMap.effectiveORModel(store) else { return nil }
        var lines: [String] = []
        let status = OpenRouterPresets.hostStatus(model: model, store: store)
        let slugs = pinnedSlugs(store: store)
        if !slugs.isEmpty {
            lines.append("📌 OpenRouter host for \(model): \(slugs.joined(separator: ", ")) (\(status.state == .autoPinned ? "pinned automatically" : "your choice"); main agent + subagents, not web research; /orprovider off lets OpenRouter choose)")
        } else if [.corrupt, .unsupported, .upgradePending, .released, .pendingLegacy].contains(status.state) {
            lines.append("OpenRouter: " + OpenRouterPresets.hostClause(status))
        }
        if let map = OpenRouterPinMap.state(store).map {
            let others = map.models.filter { $0.key != model && !$0.value.hosts.isEmpty }.count
            if others > 0, !lines.isEmpty { lines.append("   \(others) other OpenRouter model\(others == 1 ? "" : "s") remember\(others == 1 ? "s" : "") a host") }
        }
        if !lines.isEmpty, case .corrupt = OpenRouterPinMap.state(store) {
            lines.append("   ⚠ Saved OpenRouter hosts are unreadable: stored pins for other models are not applied until you choose a host again (/orprovider <slug>|off|default).")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
                status: (item["status"] as? NSNumber)?.intValue,
                serviceTier: tierInfo(item)))
        }
        return result
    }

    static func tierInfo(_ item: [String: Any]) -> TierInfo {
        guard item.keys.contains("service_tier") else { return .absent }
        if let text = item["service_tier"] as? String { return .value(text) }
        return .null
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
        if OpenRouterPinMap.broken(17) { return endpoints.filter { seen.insert($0.baseSlug).inserted } }
        // The representative is chosen among endpoints the base slug really
        // selects BEFORE de-duplicating (so the standard OpenAI row shows
        // the standard price, not flex); a provider reachable only through
        // tier endpoints is offered as full tags in text listings only.
        return endpoints.filter { eligibility(pin: $0.baseSlug, endpoint: $0) == .matched && seen.insert($0.baseSlug).inserted }
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
        /// Only endpoints whose eligibility can't be established.
        case uncertain([Endpoint])
        case notServed(available: [String])
    }

    static func validate(pin: String, endpoints: [Endpoint]) -> Verdict {
        let hits = endpoints.filter { eligibility(pin: pin, endpoint: $0) == .matched }
        if !hits.isEmpty { return .served(hits) }
        let maybe = endpoints.filter { eligibility(pin: pin, endpoint: $0) == .uncertain }
        if !maybe.isEmpty { return .uncertain(maybe) }
        return .notServed(available: baseChoices(endpoints).map(\.baseSlug))
    }

    // MARK: Preset host (0.2.54 default generalized to every preset)

    /// The default preset's host, kept for the existing setup texts.
    static let setupDefaultHost = "together"
    static let setupDefaultHostName = "Together"

    /// Live listing as a Result. Cancellation is NOT a result: callers use
    /// `fetchEndpoints` / `listingIfNeeded`, which rethrow it.
    static func listing(model: String, apiKey: String) async -> Result<[Endpoint], Error> {
        do { return .success(try await fetchEndpoints(model: model, apiKey: apiKey)) }
        catch { return .failure(error) }
    }

    /// The stored legacy pin value as slugs (shipped `pinnedSlugs` split).
    static func slugs(from raw: String?) -> [String] {
        (raw ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Host listing across the setup-api boundary

    /// A model's host list as fetched BEFORE a save (network never runs
    /// under the store lock). JSON: `{"model", "endpoints":[{"tag",
    /// "service_tier"?}]}` (tier metadata preserved: missing / null /
    /// string), the legacy `{"model","hosts":[tag…]}` (tiers unknown), or
    /// `{"model","error"}`. Cancellation never crosses this boundary.
    struct HostListing {
        let model: String
        let result: Result<[Endpoint], FetchError>

        static let maxEndpoints = 500

        var json: [String: Any] {
            switch result {
            case .success(let endpoints):
                return ["model": model, "endpoints": endpoints.map { e -> [String: Any] in
                    var obj: [String: Any] = ["tag": e.tag]
                    switch e.serviceTier {
                    case .absent: break
                    case .null: obj["service_tier"] = NSNull()
                    case .value(let t): obj["service_tier"] = t
                    }
                    if OpenRouterPinMap.broken(14) { obj.removeValue(forKey: "service_tier") }
                    return obj
                }]
            case .failure(let error): return ["model": model, "error": error.description]
            }
        }

        /// nil for a malformed object (the caller refuses the request).
        init?(json: [String: Any]) {
            guard let model = json["model"] as? String, !model.isEmpty else { return nil }
            self.model = model
            func endpoint(_ tag: String, _ tier: TierInfo) -> Endpoint {
                Endpoint(providerName: tag, tag: tag.lowercased(), promptUSDPerM: nil, completionUSDPerM: nil,
                         cacheReadUSDPerM: nil, contextLength: nil, uptimeLast30m: nil, status: nil, serviceTier: tier)
            }
            if let list = json["endpoints"] as? [[String: Any]], json["error"] == nil, json["hosts"] == nil, list.count <= Self.maxEndpoints {
                var out: [Endpoint] = []
                for item in list {
                    guard let tag = item["tag"] as? String, !tag.isEmpty, Set(item.keys).isSubset(of: ["tag", "service_tier"]) else { return nil }
                    let tier = OpenRouterProviderPin.tierInfo(item)
                    if item.keys.contains("service_tier"), !(item["service_tier"] is NSNull), !(item["service_tier"] is String) { return nil }
                    out.append(endpoint(tag, tier))
                }
                result = .success(out)
            } else if let hosts = json["hosts"] as? [String], json["error"] == nil, json["endpoints"] == nil, hosts.count <= Self.maxEndpoints {
                result = .success(hosts.map { endpoint($0, .absent) })
            } else if let error = json["error"] as? String, json["hosts"] == nil, json["endpoints"] == nil {
                result = .failure(FetchError(description: error))
            } else {
                return nil
            }
        }

        init(model: String, result: Result<[Endpoint], FetchError>) {
            self.model = model
            self.result = result
        }

        /// The decision input for `destination`: a listing for another model
        /// never authorizes a pin or a release (it is `.notFetched`).
        func listingResult(for destination: String) -> OpenRouterPinMap.ListingResult {
            guard model == destination else { return .notFetched }
            switch result {
            case .success(let e): return .served(e)
            case .failure(let error): return .failed(error.description)
            }
        }
    }

    /// Fetch a listing, turning ordinary failures into a `HostListing`
    /// failure and RETHROWING cancellation (plan §4: cancellation aborts the
    /// whole operation on every caller).
    static func hostListing(model: String, apiKey: String?,
                            fetch: (String, String) async throws -> [Endpoint] = { try await fetchEndpoints(model: $0, apiKey: $1) }) async throws -> HostListing {
        guard let apiKey, !apiKey.isEmpty else {
            return HostListing(model: model, result: .failure(FetchError(description: "no OpenRouter key to ask with")))
        }
        do {
            let endpoints = try await fetch(model, apiKey)
            try Task.checkCancellation()
            return HostListing(model: model, result: .success(endpoints))
        } catch {
            if (isCancellation(error) || Task.isCancelled) && !OpenRouterPinMap.broken(13) { throw CancellationError() }
            return HostListing(model: model, result: .failure((error as? FetchError) ?? FetchError(description: "\(error)")))
        }
    }

    // MARK: Outcomes

    /// What a save did to the host pin. `json` is the setup-api reply.
    enum PinOutcome: Equatable {
        case unchanged
        case pinnedPreset(model: String, slug: String)
        case presetSkipped(model: String, reason: String)
        case kept([String])
        case released([String], hosts: [String])
        case keptUnverified([String], reason: String)
        /// An empty (automatic) entry was honoured; no preset applied.
        case automaticKept
        /// The per-model map is unreadable: model saved, routing automatic.
        case unreadable

        var json: [String: Any] {
            switch self {
            case .unchanged, .automaticKept: return ["result": "unchanged"]
            case .pinnedPreset(let model, let slug):
                // Legacy token for the default preset (UT app compatibility).
                return ["result": model == ProviderProfiles.openRouterSetupDefaultModel ? "pinned_default" : "pinned_preset",
                        "pins": [slug], "host_name": OpenRouterPresets.hostName(slug)]
            case .presetSkipped(let model, let reason):
                let host = OpenRouterPresets.preset(forModel: model)?.autoHostName ?? ""
                return ["result": model == ProviderProfiles.openRouterSetupDefaultModel ? "default_skipped" : "preset_skipped",
                        "reason": reason, "host_name": host]
            case .kept(let pins): return ["result": "kept", "pins": pins]
            case .released(let pins, let hosts): return ["result": "released", "pins": pins, "hosts": hosts]
            case .keptUnverified(let pins, let reason): return ["result": "kept_unverified", "pins": pins, "reason": reason]
            case .unreadable: return ["result": "hosts_unreadable"]
            }
        }

        /// One plain line for the terminal wizard (nil when nothing to say).
        var terminalLine: String? {
            switch self {
            case .unchanged, .kept, .automaticKept: return nil
            case .pinnedPreset(_, let slug): return "  ✔ Host pinned: \(OpenRouterPresets.hostName(slug)) (/orprovider changes or releases it)"
            case .presetSkipped(let model, let reason):
                let host = OpenRouterPresets.preset(forModel: model)?.autoHostName ?? "Briglia's host"
                return "  ⚠ \(host) couldn't be selected (\(reason)) — no host pinned, OpenRouter chooses the host. /orprovider default retries."
            case .released(let pins, _):
                return "  ⚠ Host pin \(pins.joined(separator: ", ")) released: that host doesn't serve the new model, so OpenRouter chooses the host."
            case .keptUnverified(let pins, let reason):
                return "  ⚠ Host pin \(pins.joined(separator: ", ")) kept but not verified for this model (\(reason)). If replies fail, send /orprovider off."
            case .unreadable:
                return "  ⚠ Saved OpenRouter hosts are unreadable, so routing is automatic until you choose a host again (/orprovider)."
            }
        }

        /// Sentence appended to a Telegram /model confirmation.
        var chatNote: String {
            switch self {
            case .unchanged: return ""
            case .automaticKept: return " Host: chosen by OpenRouter (your choice for this model)."
            case .pinnedPreset(_, let slug): return " Host: \(OpenRouterPresets.hostName(slug)) (pinned automatically; /orprovider changes it, /orprovider off lets OpenRouter choose)."
            case .presetSkipped(let model, let reason):
                let host = OpenRouterPresets.preset(forModel: model)?.autoHostName ?? "Briglia's host"
                return " \(host) wasn't pinned (\(reason)); OpenRouter chooses the host. /orprovider default retries."
            case .kept(let pins): return " Host: \(pins.joined(separator: ", ")) (your earlier choice for this model)."
            case .released(let pins, let hosts):
                return " Host \(pins.joined(separator: ", ")) released: it doesn't serve this model (hosts: \(hosts.joined(separator: ", "))). /orprovider picks another."
            case .keptUnverified(let pins, let reason): return " ⚠️ Host \(pins.joined(separator: ", ")) kept but not verified (\(reason)); if replies fail, send /orprovider off."
            case .unreadable: return " ⚠️ Saved OpenRouter hosts are unreadable, so routing is automatic until you choose a host again (/orprovider <slug>|off|default)."
            }
        }
    }

    /// One plain English sentence for a setup-api `openrouter_host_pin`
    /// reply worth telling the user (Quick Setup, browser settings).
    static func noticeText(fromReply reply: [String: Any]?) -> String? {
        guard let reply, let result = reply["result"] as? String else { return nil }
        let pins = (reply["pins"] as? [String] ?? []).joined(separator: ", ")
        let reason = reply["reason"] as? String ?? ""
        let hostName = (reply["host_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? setupDefaultHostName
        switch result {
        case "pinned_default", "pinned_preset": return "OpenRouter runs on \(hostName) (host pinned; /orprovider changes it)."
        case "default_skipped", "preset_skipped": return "\(hostName) couldn't be selected (\(reason)), so no host is pinned and OpenRouter chooses the host. /orprovider default retries."
        case "released": return "The OpenRouter host pin (\(pins)) was released: that host doesn't serve the new model, so OpenRouter chooses the host."
        case "kept_unverified": return "The OpenRouter host pin (\(pins)) was kept but not verified for the new model (\(reason)). If replies fail, send /orprovider off."
        case "hosts_unreadable": return "Saved OpenRouter hosts are unreadable, so routing is automatic until you choose a host again (/orprovider)."
        default: return nil
        }
    }

    /// Pins a model change would break: stored pins DEFINITELY not served.
    static func unservedPins(_ pins: [String], endpoints: [Endpoint]) -> [String] {
        pins.filter { pin in
            if case .notServed = validate(pin: pin, endpoints: endpoints) { return true }
            return false
        }
    }

    // MARK: Listing need (outside any lock)

    /// Whether a save to `newModel` needs its host list, decided on a
    /// snapshot; the locked decision treats a missing listing conservatively.
    static func listingNeeded(store: [String: String], newModel: String, presetHostPin: Bool, explicitReset: Bool = false) -> Bool {
        let source = OpenRouterPinMap.effectiveORModel(store)
        if !explicitReset, source == newModel { return false }
        if source == nil, !OpenRouterPinMap.legacySlugs(store).isEmpty { return true }  // m2
        switch OpenRouterPinMap.state(store) {
        case .corrupt, .unsupported: return false
        case .absent:
            return presetHostPin && OpenRouterPresets.preset(forModel: newModel)?.autoHost != nil
        case .valid(let map):
            if let entry = map.models[newModel], !explicitReset { return !entry.hosts.isEmpty }
            return presetHostPin && OpenRouterPresets.preset(forModel: newModel)?.autoHost != nil
        }
    }

    static func listingIfNeeded(store: [String: String], newModel: String, apiKey: String?, presetHostPin: Bool,
                                fetch: (String, String) async throws -> [Endpoint] = { try await fetchEndpoints(model: $0, apiKey: $1) }) async throws -> HostListing? {
        guard listingNeeded(store: store, newModel: newModel, presetHostPin: presetHostPin) else { return nil }
        return try await hostListing(model: newModel, apiKey: apiKey, fetch: fetch)
    }

    // MARK: Errors

    struct PendingLegacyRefusal: Error, LocalizedError, Equatable {
        let pending: OpenRouterPinMap.PendingLegacy
        var errorDescription: String? {
            "Your current model \(pending.model) still has an old host pin (\(pending.value)) that Briglia couldn't move to the new per-model format (\(pending.reason)). Choose a host for \(pending.model) first: /orprovider <slug>, /orprovider off or /orprovider default. Then switch model."
        }
    }

    struct StaleBasis: Error, LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }

    // MARK: OpenRouter profile save (setup-api, terminal wizard)

    /// Save the OpenRouter profile and decide the destination's pin in ONE
    /// store write. `expected` (the menu's routing basis) is compared with
    /// the locked pre-migration dictionary. `activate` nil = setup-api's
    /// default (`current == nil || current == openrouter`); activation joins
    /// the same transaction.
    static func saveOpenRouterProfile(apiKey: String?, model: String, effort: String?, textOnly: Bool,
                                      listing: HostListing?, presetHostPin: Bool, activate: Bool? = false,
                                      expected: OpenRouterPinMap.RoutingBasis? = nil, now: Date = Date()) throws -> (outcome: PinOutcome, activated: Bool) {
        let changes = try ProviderProfiles.profileChanges(.openrouter, apiKey: apiKey, baseURL: nil, model: model,
                                                      effort: effort, textOnly: textOnly)
        var result: (outcome: PinOutcome, activated: Bool) = (.unchanged, false)
        try KeychainHelper.conditionalTransaction { store in
            result = try applyOpenRouterSave(&store, changes: changes, model: model, textOnly: textOnly, listing: listing,
                                             presetHostPin: presetHostPin, activate: activate, expected: expected, now: now)
        }
        return result
    }

    /// The pure body of `saveOpenRouterProfile` (also run on the menu
    /// selftest's fake store): basis check against the pre-migration
    /// dictionary, pending-legacy refusal, migration, profile changes,
    /// per-model decision, activation.
    static func applyOpenRouterSave(_ store: inout [String: String], changes: [String: String?], model: String, textOnly: Bool,
                                    listing: HostListing?, presetHostPin: Bool, activate: Bool?,
                                    expected: OpenRouterPinMap.RoutingBasis?, now: Date) throws -> (outcome: PinOutcome, activated: Bool) {
        if let expected, OpenRouterPinMap.RoutingBasis.of(store) != expected {
            throw StaleBasis(reason: "the OpenRouter settings changed while this was being saved")
        }
        let source = OpenRouterPinMap.effectiveORModel(store)
        if source != nil, source != model, let pending = OpenRouterPinMap.pendingLegacy(store), !OpenRouterPinMap.broken(21) {
            throw PendingLegacyRefusal(pending: pending)
        }
        if OpenRouterPinMap.broken(4) {
            for (key, value) in changes { if let value { store[key] = value } else { store.removeValue(forKey: key) } }
        }
        try OpenRouterPinMap.migrate(&store, now: now)
        let legacyForDestination = source == nil ? OpenRouterPinMap.legacySlugs(store) : []
        for (key, value) in changes {
            if let value { store[key] = value } else { store.removeValue(forKey: key) }
        }
        let outcome = try OpenRouterPinMap.decideSave(&store, source: source, destination: model,
                                                      listing: listing?.listingResult(for: model) ?? .notFetched,
                                                      flags: .init(presetHostPin: presetHostPin, explicitReset: false),
                                                      staleListing: false, m2Legacy: legacyForDestination, now: now)
        var activated = false
        let current = store[ProviderProfiles.activeProfileKey].flatMap(ProviderProfiles.Profile.init(rawValue:))
        if activate ?? (current == nil || current == .openrouter) {
            store[KeychainHelper.llmProviderKey] = LLMProvider.openRouter.rawValue
            store[KeychainHelper.textOnlyModelEnabledKey] = textOnly ? "true" : "false"
            store.removeValue(forKey: ProviderProfiles.runtimeProtocolKey)
            store.removeValue(forKey: ProviderProfiles.runtimeNativeMediaKey)
            store[ProviderProfiles.activeProfileKey] = ProviderProfiles.Profile.openrouter.rawValue
            activated = true
        }
        return (outcome, activated)
    }

    // MARK: /model on OpenRouter (Telegram, terminal, app socket)

    /// The model, both vision slots (profile always; runtime only while
    /// OpenRouter is the active provider) and the destination's pin in one
    /// guarded write. Key and effort are never touched. `expected` is the
    /// basis read BEFORE the listing: the source (profile, provider,
    /// effective model) must be unchanged; a changed map revision makes the
    /// listing stale for destructive use (§13.2).
    static func commitModelChange(destination: String, textOnly: Bool?, listing: HostListing?,
                                  expected: OpenRouterPinMap.RoutingBasis, now: Date = Date()) throws -> PinOutcome {
        var outcome = PinOutcome.unchanged
        try KeychainHelper.conditionalTransaction { store in
            let pre = OpenRouterPinMap.RoutingBasis.of(store)
            guard pre.activeProfile == expected.activeProfile, pre.llmProvider == expected.llmProvider,
                  pre.effectiveModel == expected.effectiveModel else {
                throw StaleBasis(reason: "the provider or model changed while checking OpenRouter's host list")
            }
            let source = pre.effectiveModel
            if source != destination, let pending = OpenRouterPinMap.pendingLegacy(store), !OpenRouterPinMap.broken(21) {
                throw PendingLegacyRefusal(pending: pending)
            }
            let stale = pre.mapTag != expected.mapTag || pre.legacyRaw != expected.legacyRaw
            try OpenRouterPinMap.migrate(&store, now: now)
            let legacyForDestination = source == nil ? OpenRouterPinMap.legacySlugs(store) : []
            store[KeychainHelper.openRouterModelKey] = destination
            if let textOnly {
                store[ProviderProfiles.openrouterTextOnlyKey] = textOnly ? "true" : "false"
                if LLMProvider.fromStoredValue(store[KeychainHelper.llmProviderKey]) == .openRouter {
                    store[KeychainHelper.textOnlyModelEnabledKey] = textOnly ? "true" : "false"
                }
            }
            outcome = try OpenRouterPinMap.decideSave(&store, source: source, destination: destination,
                                                      listing: listing?.listingResult(for: destination) ?? .notFetched,
                                                      flags: .init(presetHostPin: true, explicitReset: false),
                                                      staleListing: stale && !OpenRouterPinMap.broken(20), m2Legacy: legacyForDestination, now: now)
        }
        return outcome
    }

    // MARK: Host choices (/orprovider, menu toggle, setup-api openrouter_pin)

    enum HostChoice: Equatable {
        case pin([String])
        case automatic
        /// Back to Briglia's preset behaviour (delete + rows 1/2/7/8).
        case reset
        /// Delete the remembered entry, no re-pin.
        case forget
    }

    struct HostCommit: Equatable {
        var outcome: PinOutcome
        /// The map was unreadable and was backed up + recreated.
        var recovered: Bool
    }

    /// One guarded write for an explicit host decision on `model`. Refused
    /// (StaleBasis) unless the whole basis (profile, provider, effective
    /// model, map `(iid, rev)` or corrupt hash, legacy raw) is unchanged.
    static func commitHostChoice(model: String, choice: HostChoice, listing: HostListing?,
                                 expected: OpenRouterPinMap.RoutingBasis, now: Date = Date()) throws -> HostCommit {
        guard OpenRouterPinMap.isValidModelID(model) else { throw OpenRouterPinMap.PinMapError.invalidModel }
        if case .pin(let slugs) = choice, slugs.isEmpty || !OpenRouterPinMap.isValidHostList(slugs) {
            throw OpenRouterPinMap.PinMapError.invalidHosts
        }
        var result = HostCommit(outcome: .unchanged, recovered: false)
        try KeychainHelper.conditionalTransaction { store in
            result = try applyHostChoice(&store, model: model, choice: choice, listing: listing, expected: expected, now: now)
        }
        return result
    }

    /// The pure body of `commitHostChoice` (also run on fake stores).
    static func applyHostChoice(_ store: inout [String: String], model: String, choice: HostChoice, listing: HostListing?,
                                expected: OpenRouterPinMap.RoutingBasis, now: Date) throws -> HostCommit {
        var result = HostCommit(outcome: .unchanged, recovered: false)
        do {
            let pre = OpenRouterPinMap.RoutingBasis.of(store)
            let same = OpenRouterPinMap.broken(12) ? pre.effectiveModel == expected.effectiveModel : pre == expected
            guard same else { throw StaleBasis(reason: "the OpenRouter host settings changed meanwhile") }
            switch OpenRouterPinMap.state(store) {
            case .corrupt(let raw), .unsupported(_, let raw):
                store[OpenRouterPinMap.corruptBackupKey] = raw
                store.removeValue(forKey: OpenRouterPinMap.storageKey)
                var fresh = OpenRouterPinMap.Map.fresh(iid: OpenRouterPinMap.newIID())
                fresh.rev = 0
                try OpenRouterPinMap.store(fresh, into: &store)
                result.recovered = true
            case .absent, .valid: break
            }
            try OpenRouterPinMap.migrate(&store, now: now)
            if OpenRouterPinMap.state(store) == .absent {  // m3 with no map yet
                var fresh = OpenRouterPinMap.Map.fresh(iid: OpenRouterPinMap.newIID())
                fresh.rev = 0
                try OpenRouterPinMap.store(fresh, into: &store)
            }
            guard var map = OpenRouterPinMap.state(store).map else { throw StaleBasis(reason: "the saved OpenRouter hosts couldn't be read") }
            // An explicit decision for the effective model resolves a
            // pending legacy pin (m3/m6) in the same write.
            if OpenRouterPinMap.effectiveORModel(store) == model { store.removeValue(forKey: OpenRouterPinMap.legacyKey) }
            let ts = OpenRouterPinMap.timestamp(now)
            switch choice {
            case .pin(let slugs):
                map.models[model] = .init(hosts: slugs, by: .user, at: ts)
                result.outcome = .kept(slugs)
            case .automatic:
                if OpenRouterPinMap.broken(2) { map.models[model] = nil } else { map.models[model] = .init(hosts: [], by: .user, at: ts) }
                result.outcome = .automaticKept
            case .forget:
                map.models[model] = nil
                result.outcome = .unchanged
            case .reset:
                result.outcome = OpenRouterPinMap.decide(map: &map, destination: model,
                                                         listing: listing?.listingResult(for: model) ?? .notFetched,
                                                         flags: .init(presetHostPin: true, explicitReset: true), staleListing: false, now: now)
            }
            if map.upgrade?.model == model { map.upgrade = nil }
            try OpenRouterPinMap.store(map, into: &store)
        }
        return result
    }

    // MARK: D10 upgrade-preset pass (§13.5/§13.6)

    enum UpgradeAttempt: Equatable {
        /// Nothing to do (no pending marker for a current, unchosen model).
        case nothing
        /// Pinned; the marker is gone.
        case pinned(model: String, slug: String)
        /// The host definitely doesn't serve the model; marker gone, no pin.
        case notServed(model: String, host: String)
        /// No write; keep the marker and retry later.
        case retry(String)
    }

    /// Snapshot predicate for the pass (step 1): the model to look up, or nil.
    static func upgradeCandidate(_ store: [String: String]) -> String? {
        guard let map = OpenRouterPinMap.state(store).map, let marker = map.upgrade,
              OpenRouterPinMap.effectiveORModel(store) == marker.model, map.models[marker.model] == nil,
              OpenRouterPinMap.pendingLegacy(store) == nil, OpenRouterPinMap.legacyRaw(store) == nil,
              OpenRouterPresets.preset(forModel: marker.model)?.autoHost != nil else { return nil }
        return marker.model
    }

    /// The commit of one attempt: non-blocking store admission, full basis
    /// and marker re-checked against the locked pre-migration dictionary.
    static func commitUpgradeAttempt(model: String, listing: HostListing, expected: OpenRouterPinMap.RoutingBasis,
                                     now: Date = Date()) throws -> UpgradeAttempt {
        var attempt = UpgradeAttempt.retry("busy")
        let tried = try KeychainHelper.tryTransaction { store in
            let st = OpenRouterPinMap.state(store)
            if OpenRouterPinMap.broken(28), st.map == nil {
                var m = OpenRouterPinMap.Map.fresh(iid: OpenRouterPinMap.newIID()); m.rev = 0
                try OpenRouterPinMap.store(m, into: &store)
            }
            guard var map = st.map, let marker = map.upgrade, marker.model == model else { attempt = .nothing; return }
            let pre = OpenRouterPinMap.RoutingBasis.of(store)
            let sameIgnoringLegacy = pre.activeProfile == expected.activeProfile && pre.llmProvider == expected.llmProvider
                && pre.effectiveModel == expected.effectiveModel && pre.mapTag == expected.mapTag
            guard OpenRouterPinMap.broken(26) || (OpenRouterPinMap.broken(27) ? sameIgnoringLegacy : pre == expected) else {
                attempt = .retry("settings changed during the host check"); return
            }
            guard OpenRouterPinMap.broken(27) || pre.legacyRaw == nil else { attempt = .retry("a legacy pin appeared"); return }
            guard OpenRouterPinMap.effectiveORModel(store) == model, map.models[model] == nil,
                  let preset = OpenRouterPresets.preset(forModel: model), let host = preset.autoHost else {
                attempt = .retry("not applicable now"); return
            }
            guard !OpenRouterPinMap.trimmed(store[KeychainHelper.openRouterApiKeyKey]).isEmpty else { attempt = .retry("no OpenRouter key yet"); return }
            switch listing.listingResult(for: model) {
            case .notFetched: attempt = .retry("host list not for this model")
            case .failed(let r):
                if OpenRouterPinMap.broken(25) { map.upgrade = nil; try OpenRouterPinMap.store(map, into: &store) }
                attempt = .retry(r)
            case .served(let endpoints):
                switch validate(pin: host, endpoints: endpoints) {
                case .served:
                    map.models[model] = .init(hosts: [host], by: .preset, at: OpenRouterPinMap.timestamp(now))
                    map.upgrade = nil
                    try OpenRouterPinMap.store(map, into: &store)
                    attempt = .pinned(model: model, slug: host)
                case .uncertain:
                    attempt = .retry("eligibility uncertain")
                case .notServed:
                    map.upgrade = nil
                    try OpenRouterPinMap.store(map, into: &store)
                    attempt = .notServed(model: model, host: preset.autoHostName ?? host)
                }
            }
        }
        if tried == .busy { return .retry("store busy") }
        return attempt
    }
}

// MARK: - Decision (§4 + §13.2)

extension OpenRouterPinMap {
    enum ListingResult {
        case served([OpenRouterProviderPin.Endpoint])
        case failed(String)
        case notFetched
    }

    struct Flags {
        var presetHostPin: Bool
        var explicitReset: Bool
    }

    /// Rows 1–10 for `destination` on a valid map (evaluation order steps
    /// 2 and 4; step 3, same-model, is the caller's).
    static func decide(map: inout Map, destination: String, listing: ListingResult, flags: Flags,
                       staleListing: Bool, now: Date) -> OpenRouterProviderPin.PinOutcome {
        typealias Pin = OpenRouterProviderPin
        if flags.explicitReset { map.models[destination] = nil }
        if let entry = map.models[destination] {
            if entry.hosts.isEmpty && !broken(1) { return .automaticKept }  // row 6
            if !entry.hosts.isEmpty {
                if staleListing { return .keptUnverified(entry.hosts, reason: "saved hosts changed while checking") }
                switch listing {
                case .notFetched: return .keptUnverified(entry.hosts, reason: "the host list wasn't checked")
                case .failed(let r): return .keptUnverified(entry.hosts, reason: "couldn't read OpenRouter's host list (\(r))")
                case .served(let endpoints):
                    let unserved = Pin.unservedPins(entry.hosts, endpoints: endpoints)
                    if !unserved.isEmpty {
                        let hosts = Pin.baseChoices(endpoints).map(\.baseSlug)
                        if entry.by == .preset || broken(10) {
                            map.models[destination] = nil                            // 4a
                        } else {
                            map.models[destination] = Entry(hosts: [], by: .released, was: entry.hosts, at: timestamp(now))  // 4b
                        }
                        return .released(entry.hosts, hosts: hosts)
                    }
                    let uncertain = entry.hosts.contains { pin in
                        if case .uncertain = Pin.validate(pin: pin, endpoints: endpoints) { return true }
                        return false
                    }
                    return uncertain ? .keptUnverified(entry.hosts, reason: "OpenRouter's listing doesn't confirm the tier") : .kept(entry.hosts)  // row 3
                }
            }
        }
        guard let preset = OpenRouterPresets.preset(forModel: destination), let host = preset.autoHost else { return .unchanged }  // rows 7, 8
        guard flags.presetHostPin else { return .unchanged }  // row 10
        if staleListing { return .presetSkipped(model: destination, reason: "saved hosts changed while checking") }
        switch listing {
        case .notFetched: return .presetSkipped(model: destination, reason: "the host list wasn't checked")
        case .failed(let r): return .presetSkipped(model: destination, reason: "couldn't read OpenRouter's host list (\(r))")
        case .served(let endpoints):
            if case .served = Pin.validate(pin: host, endpoints: endpoints) {
                map.models[destination] = Entry(hosts: [host], by: .preset, at: timestamp(now))  // row 1
                return .pinnedPreset(model: destination, slug: host)
            }
            let hosts = Pin.baseChoices(endpoints).map(\.baseSlug).joined(separator: ", ")
            return .presetSkipped(model: destination, reason: "\(preset.autoHostName ?? host) doesn't serve \(destination) (hosts: \(hosts))")
        }
    }

    /// The save-side wrapper: evaluation order (corrupt → same model →
    /// table), m2 attachment, marker retirement on a model change.
    static func decideSave(_ store: inout [String: String], source: String?, destination: String, listing: ListingResult,
                           flags: Flags, staleListing: Bool, m2Legacy: [String], now: Date) throws -> OpenRouterProviderPin.PinOutcome {
        switch state(store) {
        case .corrupt, .unsupported:
            if !broken(7) { return source == destination ? .unchanged : .unreadable }
            store.removeValue(forKey: storageKey)
        case .absent, .valid: break
        }
        if source == destination && !flags.explicitReset { return .unchanged }  // row 9
        var map = state(store).map ?? { var m = Map.fresh(iid: newIID()); m.rev = 0; return m }()
        let before = map
        // m2: a key-less, model-less store's valid legacy pin is the
        // destination's pre-existing entry (validated by rows 3/4/5).
        if source == nil, isMigratable(m2Legacy), state(store).isReadable {
            map.models[destination] = Entry(hosts: m2Legacy, by: migratedProvenance(slugs: m2Legacy, model: destination), at: timestamp(now))
            store.removeValue(forKey: legacyKey)
        }
        // A successful model-changing save retires an upgrade operation for
        // the model it leaves (and one for the destination is superseded by
        // this decision).
        if let marker = map.upgrade, marker.model == source || marker.model == destination { map.upgrade = nil }
        let outcome = decide(map: &map, destination: destination, listing: listing, flags: flags, staleListing: staleListing, now: now)
        if map != before || state(store) == .absent { try OpenRouterPinMap.store(map, into: &store) }
        return outcome
    }
}
