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

    // MARK: New-setup default host (owner request 2026-10-15)

    /// A NEW OpenRouter setup on the setup default model
    /// (`ProviderProfiles.openRouterSetupDefaultModel`, DeepSeek V4.1 Flash)
    /// is pinned to this host, so a non-technical user gets the host the
    /// owner chose without running `/orprovider together`. Existing setups
    /// and any stored pin are never touched; `/orprovider off` or another
    /// slug changes it later like any pin.
    static let setupDefaultHost = "together"
    static let setupDefaultHostName = "Together"

    /// The default pin for a new OpenRouter setup, decided against the
    /// model's live host list with the same check `/orprovider <slug>` runs
    /// (`normalizedSlug` + `validate`). Pins only the setup default model,
    /// only when the listing was read and serves the host: an unreadable
    /// listing or a host that stopped serving the model leaves routing
    /// automatic (a hard pin there could fail every request).
    enum NewSetupDecision: Equatable {
        case pin(String)
        case skip(String)
    }

    static func newSetupDecision(model: String, listing: Result<[Endpoint], Error>) -> NewSetupDecision {
        guard model == ProviderProfiles.openRouterSetupDefaultModel else {
            return .skip("not the setup default model")
        }
        guard let slug = normalizedSlug(setupDefaultHost) else { return .skip("invalid default host") }
        switch listing {
        case .failure(let error):
            if isCancellation(error) { return .skip("the host check was cancelled") }
            return .skip("couldn't read OpenRouter's host list (\(error))")
        case .success(let endpoints):
            switch validate(pin: slug, endpoints: endpoints) {
            case .served: return .pin(slug)
            case .notServed(let available):
                return .skip("\(setupDefaultHostName) doesn't serve \(model) (hosts: \(available.joined(separator: ", ")))")
            }
        }
    }

    /// Live listing as a Result (for `newSetupDecision`).
    static func listing(model: String, apiKey: String) async -> Result<[Endpoint], Error> {
        do { return .success(try await fetchEndpoints(model: model, apiKey: apiKey)) }
        catch { return .failure(error) }
    }

    /// The stored pin value as slugs (same parsing as `pinnedSlugs`), for
    /// decisions taken on a store dictionary inside a transaction.
    static func slugs(from raw: String?) -> [String] {
        (raw ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The write for a new-setup default: stores `slugs` only when no pin
    /// is stored at that moment (an explicit pin set meanwhile, from
    /// Telegram, another process or by hand, always wins). The condition is
    /// read from the dictionary held under the secret store's lock, in the
    /// same atomic write as the change (Codex round 1: a separate read then
    /// write let another process's pin be overwritten). Returns whether it
    /// wrote.
    @discardableResult
    static func setPinIfUnset(_ slugs: [String]) throws -> Bool {
        let cleaned = slugs.compactMap(normalizedSlug)
        guard !cleaned.isEmpty else { return false }
        var wrote = false
        try KeychainHelper.transaction { store in
            guard Self.slugs(from: store[storageKey]).isEmpty else { return }
            store[storageKey] = cleaned.joined(separator: ",")
            wrote = true
        }
        return wrote
    }

    /// Release the stored pin only while it still equals `expected` (a
    /// decision taken before a network await must not delete a pin stored
    /// meanwhile — the /model revalidation rule), checked and written under
    /// one lock. Returns whether it wrote.
    @discardableResult
    static func releasePin(ifStill expected: [String]) throws -> Bool {
        guard !expected.isEmpty else { return false }
        var wrote = false
        try KeychainHelper.transaction { store in
            guard Self.slugs(from: store[storageKey]) == expected else { return }
            store.removeValue(forKey: storageKey)
            wrote = true
        }
        return wrote
    }

    // MARK: Model/pin coherence for every OpenRouter save (Codex round 1)

    /// A model's host list as fetched BEFORE a save (network never runs
    /// under the store lock). Crosses the setup-api JSON boundary as
    /// `{"model": m, "hosts": [tag…]}` or `{"model": m, "error": "…"}`.
    struct HostListing {
        let model: String
        let result: Result<[Endpoint], FetchError>

        var json: [String: Any] {
            switch result {
            case .success(let endpoints): return ["model": model, "hosts": endpoints.map(\.tag)]
            case .failure(let error): return ["model": model, "error": error.description]
            }
        }

        /// nil for a malformed object (the caller refuses the request).
        init?(json: [String: Any]) {
            guard let model = json["model"] as? String, !model.isEmpty else { return nil }
            self.model = model
            if let hosts = json["hosts"] as? [String], json["error"] == nil, hosts.count <= 500 {
                result = .success(hosts.map { Endpoint(providerName: $0, tag: $0.lowercased(), promptUSDPerM: nil, completionUSDPerM: nil,
                                                        cacheReadUSDPerM: nil, contextLength: nil, uptimeLast30m: nil, status: nil) })
            } else if let error = json["error"] as? String, json["hosts"] == nil {
                result = .failure(FetchError(description: error))
            } else {
                return nil
            }
        }

        init(model: String, result: Result<[Endpoint], Error>) {
            self.model = model
            switch result {
            case .success(let endpoints): self.result = .success(endpoints)
            case .failure(let error):
                self.result = .failure(isCancellation(error) ? FetchError(description: "the host check was cancelled")
                                                             : (error as? FetchError) ?? FetchError(description: "\(error)"))
            }
        }
    }

    /// What a save did to the host pin. `json` is the setup-api reply.
    enum PinOutcome: Equatable {
        /// No pin involved (no pin stored and no new-setup default).
        case unchanged
        /// A new setup was pinned to the default host.
        case pinnedDefault(String)
        /// A new setup could NOT be pinned: OpenRouter chooses the host.
        case defaultSkipped(String)
        /// A stored pin serves the new model.
        case kept([String])
        /// A stored pin doesn't serve the new model and was released.
        case released([String], hosts: [String])
        /// A stored pin was kept without proof that it serves the new model.
        case keptUnverified([String], reason: String)

        var json: [String: Any] {
            switch self {
            case .unchanged: return ["result": "unchanged"]
            case .pinnedDefault(let slug): return ["result": "pinned_default", "pins": [slug]]
            case .defaultSkipped(let reason): return ["result": "default_skipped", "reason": reason]
            case .kept(let pins): return ["result": "kept", "pins": pins]
            case .released(let pins, let hosts): return ["result": "released", "pins": pins, "hosts": hosts]
            case .keptUnverified(let pins, let reason): return ["result": "kept_unverified", "pins": pins, "reason": reason]
            }
        }

        /// One plain line for the terminal wizard (nil when nothing to say).
        var terminalLine: String? {
            switch self {
            case .unchanged, .kept: return nil
            case .pinnedDefault: return "  ✔ Host pinned: \(setupDefaultHostName) (/orprovider changes or releases it)"
            case .defaultSkipped(let reason):
                return "  ⚠ \(setupDefaultHostName) couldn't be selected (\(reason)) — no host pinned, OpenRouter chooses the host. Pin one later with /orprovider."
            case .released(let pins, _):
                return "  ⚠ Host pin \(pins.joined(separator: ", ")) released: that host doesn't serve the new model, so OpenRouter chooses the host."
            case .keptUnverified(let pins, let reason):
                return "  ⚠ Host pin \(pins.joined(separator: ", ")) kept but not verified for this model (\(reason)). If replies fail, send /orprovider off."
            }
        }
    }

    /// One plain English sentence for a setup-api `openrouter_host_pin`
    /// reply worth telling the user (Quick Setup, browser settings); nil
    /// when nothing happened worth saying.
    static func noticeText(fromReply reply: [String: Any]?) -> String? {
        guard let reply, let result = reply["result"] as? String else { return nil }
        let pins = (reply["pins"] as? [String] ?? []).joined(separator: ", ")
        let reason = reply["reason"] as? String ?? ""
        switch result {
        case "pinned_default": return "OpenRouter runs on \(setupDefaultHostName) (host pinned; /orprovider changes it)."
        case "default_skipped": return "\(setupDefaultHostName) couldn't be selected (\(reason)), so no host is pinned and OpenRouter chooses the host. Pin one later with /orprovider."
        case "released": return "The OpenRouter host pin (\(pins)) was released: that host doesn't serve the new model, so OpenRouter chooses the host."
        case "kept_unverified": return "The OpenRouter host pin (\(pins)) was kept but not verified for the new model (\(reason)). If replies fail, send /orprovider off."
        default: return nil
        }
    }

    /// A new OpenRouter setup: no OpenRouter key, no OpenRouter model and no
    /// pin stored before this save. Replacing the key of an existing lane or
    /// editing an unpinned lane (pin off) is never a new setup.
    static func isNewSetup(keyBefore: String, modelBefore: String, pins: [String]) -> Bool {
        keyBefore.isEmpty && modelBefore.isEmpty && pins.isEmpty
    }

    /// Whether a save needs the new model's host list: a new setup on the
    /// default model asking for the default host, or a stored pin with a
    /// model change. Decided on a snapshot; `reconcile` re-decides under the
    /// lock and treats a missing listing conservatively.
    static func listingNeeded(keyBefore: String, modelBefore: String, pins: [String], newModel: String, newSetupDefault: Bool) -> Bool {
        if newSetupDefault, newModel == ProviderProfiles.openRouterSetupDefaultModel,
           isNewSetup(keyBefore: keyBefore, modelBefore: modelBefore, pins: pins) { return true }
        return !pins.isEmpty && newModel != modelBefore
    }

    static func listingNeeded(store: [String: String], newModel: String, newSetupDefault: Bool) -> Bool {
        listingNeeded(keyBefore: trimmed(store[KeychainHelper.openRouterApiKeyKey]), modelBefore: trimmed(store[KeychainHelper.openRouterModelKey]),
                      pins: slugs(from: store[storageKey]), newModel: newModel, newSetupDefault: newSetupDefault)
    }

    private static func trimmed(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The one model/pin decision, applied to the store dictionary INSIDE
    /// the transaction that writes the new model (`keyBefore`/`modelBefore`
    /// are the values in that same dictionary before the profile changes).
    /// Pure: no I/O, so the menu selftest's fake store runs the same rule.
    /// - new setup + default model + `newSetupDefault`: pin the default host
    ///   when the listing shows it serves the model, else leave routing
    ///   automatic and say why;
    /// - stored pin + model change: keep it when served, release it when not
    ///   (a hard pin on an unserved model fails every request), keep it with
    ///   a warning when the listing is missing or unreadable.
    static func reconcile(_ store: inout [String: String], keyBefore: String, modelBefore: String, newModel: String,
                          listing: HostListing?, newSetupDefault: Bool) -> PinOutcome {
        let pins = slugs(from: store[storageKey])
        let usable = listing.flatMap { $0.model == newModel ? $0 : nil }
        if newSetupDefault, newModel == ProviderProfiles.openRouterSetupDefaultModel,
           isNewSetup(keyBefore: keyBefore, modelBefore: modelBefore, pins: pins) {
            guard let usable else { return .defaultSkipped("the host list wasn't checked") }
            switch newSetupDecision(model: newModel, listing: usable.result.mapError { $0 as Error }) {
            case .pin(let slug):
                store[storageKey] = slug
                return .pinnedDefault(slug)
            case .skip(let reason):
                return .defaultSkipped(reason)
            }
        }
        guard !pins.isEmpty, newModel != modelBefore else { return pins.isEmpty ? .unchanged : .kept(pins) }
        guard let usable else { return .keptUnverified(pins, reason: "the host list wasn't checked") }
        switch usable.result {
        case .failure(let error):
            return .keptUnverified(pins, reason: "couldn't read OpenRouter's host list (\(error.description))")
        case .success(let endpoints):
            guard !unservedPins(pins, endpoints: endpoints).isEmpty else { return .kept(pins) }
            store.removeValue(forKey: storageKey)
            return .released(pins, hosts: baseChoices(endpoints).map(\.baseSlug))
        }
    }

    /// Fetch the listing a save needs (nil when it needs none), outside any
    /// lock. `fetch` is a seam (the menu's env, a selftest).
    static func listingIfNeeded(store: [String: String], newModel: String, apiKey: String?, newSetupDefault: Bool,
                                fetch: (String, String) async -> Result<[Endpoint], Error> = { await listing(model: $0, apiKey: $1) }) async -> HostListing? {
        guard listingNeeded(store: store, newModel: newModel, newSetupDefault: newSetupDefault) else { return nil }
        guard let apiKey, !apiKey.isEmpty else {
            return HostListing(model: newModel, result: .failure(FetchError(description: "no OpenRouter key to ask with")))
        }
        return HostListing(model: newModel, result: await fetch(newModel, apiKey))
    }

    /// Save the OpenRouter profile and reconcile the pin in ONE atomic
    /// store write (setup-api, the terminal wizard). The condition and the
    /// change read the same locked dictionary, so a pin or model written by
    /// another process meanwhile is decided on, never overwritten blindly.
    static func saveOpenRouterProfile(apiKey: String?, model: String, effort: String?, textOnly: Bool,
                                      listing: HostListing?, newSetupDefault: Bool) throws -> PinOutcome {
        let changes = try ProviderProfiles.profileChanges(.openrouter, apiKey: apiKey, baseURL: nil, model: model,
                                                      effort: effort, textOnly: textOnly)
        var outcome = PinOutcome.unchanged
        try KeychainHelper.transaction { store in
            let keyBefore = trimmed(store[KeychainHelper.openRouterApiKeyKey])
            let modelBefore = trimmed(store[KeychainHelper.openRouterModelKey])
            for (key, value) in changes {
                if let value { store[key] = value } else { store.removeValue(forKey: key) }
            }
            outcome = reconcile(&store, keyBefore: keyBefore, modelBefore: modelBefore, newModel: model,
                                listing: listing, newSetupDefault: newSetupDefault)
        }
        return outcome
    }

    /// Pins a model change would break: the stored pins the new model's
    /// host list doesn't serve (empty = keep the pin).
    static func unservedPins(_ pins: [String], endpoints: [Endpoint]) -> [String] {
        pins.filter { pin in
            if case .notServed = validate(pin: pin, endpoints: endpoints) { return true }
            return false
        }
    }
}
