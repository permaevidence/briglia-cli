import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Per-model OpenRouter host pins (plan `OPENROUTER_MODEL_PICKER_PLAN.md`
/// v5, Codex-accepted 2026-10-18). Each OpenRouter model remembers its own
/// host choice in one deterministic JSON value
/// (`openrouter_providers_by_model`); the 0.2.30–0.2.55 global pin
/// (`openrouter_providers`) is migrated into it.
///
/// Everything here is PURE over a store dictionary (no KeychainHelper call),
/// so the same functions run inside `KeychainHelper.transaction` (the lock is
/// not recursive) and against the menu selftest's fake store.
enum OpenRouterPinMap {
    static let storageKey = "openrouter_providers_by_model"
    static let corruptBackupKey = "openrouter_providers_by_model_corrupt"
    static var legacyKey: String { KeychainHelper.openRouterProvidersKey }
    /// The model a key-only OpenRouter profile runs (ProviderProfiles.
    /// configuredModel / OpenRouterService runtime fallback).
    static let implicitDefaultModel = "google/gemini-3-flash-preview"
    static let maxHosts = 8
    static let maxModelIDLength = 300
    /// Non-catalog remembered entries (user/migrated/released). The five
    /// catalog preset models have reserved slots on top (plan §13.4).
    static let maxNonCatalogRemembered = 256

    // MARK: Schema

    enum Provenance: String {
        case user, preset, migrated, released
        var remembered: Bool { self != .preset }
    }

    struct Entry: Equatable {
        var hosts: [String]
        var by: Provenance
        var was: [String]? = nil
        var at: String
    }

    /// D10 upgrade operation: created only by migration row m4.
    struct UpgradeMarker: Equatable {
        var model: String
        var state: String  // "pending" is the only persisted state
    }

    struct Map: Equatable {
        var rev: Int
        var iid: String
        var models: [String: Entry]
        var upgrade: UpgradeMarker?

        static func fresh(iid: String) -> Map { Map(rev: 1, iid: iid, models: [:], upgrade: nil) }

        var nonCatalogRememberedCount: Int {
            models.filter { !OpenRouterPresets.isCatalogModel($0.key) && $0.value.by.remembered }.count
        }
    }

    enum State: Equatable {
        case absent
        case valid(Map)
        case corrupt(String)
        case unsupported(Int, String)

        var map: Map? { if case .valid(let m) = self { return m }; return nil }
        var isReadable: Bool { if case .corrupt = self { return false }; if case .unsupported = self { return false }; return true }
    }

    /// Test-only break switches for the deliberate-break battery (plan §9);
    /// only the selftest ever sets them.
    nonisolated(unsafe) static var _testBreaks: Set<Int> = []
    static func broken(_ n: Int) -> Bool { _testBreaks.contains(n) }

    // MARK: Validation helpers

    static func isValidModelID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maxModelIDLength
            && !id.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    /// Hosts accepted in the map: 0–8 slugs, each already in its normalized
    /// form (so storing never rewrites what the user/legacy value sends).
    static func isValidHostList(_ hosts: [String]) -> Bool {
        hosts.count <= maxHosts && hosts.allSatisfy { OpenRouterProviderPin.normalizedSlug($0) == $0 }
    }

    // MARK: Codec

    static func state(_ store: [String: String]) -> State {
        guard let raw = store[storageKey] else { return .absent }
        guard let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .corrupt(raw) }
        guard let v = jsonInt(root["v"]) else { return .corrupt(raw) }
        guard v == 1 else { return .unsupported(v, raw) }
        guard let map = decodeV1(root), validate(map) else { return .corrupt(raw) }
        return .valid(map)
    }

    /// A JSON integer (not a JSON boolean, which NSNumber also bridges).
    static func jsonInt(_ value: Any?) -> Int? {
        guard let value, !BashTools.isJSONBoolean(value), let n = value as? NSNumber else { return nil }
        let d = n.doubleValue
        guard d.rounded() == d, abs(d) < 1e15 else { return nil }
        return n.intValue
    }

    private static func decodeV1(_ root: [String: Any]) -> Map? {
        let allowed: Set<String> = ["v", "rev", "iid", "models", "upgrade"]
        guard Set(root.keys).isSubset(of: allowed),
              let rev = jsonInt(root["rev"]), rev >= 1,
              let iid = root["iid"] as? String, !iid.isEmpty, iid.count <= 64,
              let modelsRaw = root["models"] as? [String: Any] else { return nil }
        var models: [String: Entry] = [:]
        for (id, value) in modelsRaw {
            guard let obj = value as? [String: Any],
                  Set(obj.keys).isSubset(of: ["hosts", "by", "was", "at"]),
                  let hosts = obj["hosts"] as? [String],
                  let byRaw = obj["by"] as? String, let by = Provenance(rawValue: byRaw),
                  let at = obj["at"] as? String, at.count <= 40 else { return nil }
            var entry = Entry(hosts: hosts, by: by, at: at)
            if let was = obj["was"] {
                guard let list = was as? [String] else { return nil }
                entry.was = list
            }
            models[id] = entry
        }
        var upgrade: UpgradeMarker?
        if let up = root["upgrade"] {
            guard let obj = up as? [String: Any], Set(obj.keys) == ["model", "state"],
                  let m = obj["model"] as? String, let s = obj["state"] as? String else { return nil }
            upgrade = UpgradeMarker(model: m, state: s)
        }
        return Map(rev: rev, iid: iid, models: models, upgrade: upgrade)
    }

    static func validate(_ map: Map) -> Bool {
        guard map.rev >= 1, !map.iid.isEmpty else { return false }
        for (id, e) in map.models {
            guard isValidModelID(id), isValidHostList(e.hosts) else { return false }
            switch e.by {
            case .released:
                guard e.hosts.isEmpty, let was = e.was, !was.isEmpty, isValidHostList(was) else { return false }
            default:
                guard e.was == nil else { return false }
            }
        }
        if let up = map.upgrade {
            guard up.state == "pending", isValidModelID(up.model) else { return false }
        }
        return map.nonCatalogRememberedCount <= maxNonCatalogRemembered
    }

    /// Deterministic encoding (sorted keys, no whitespace).
    static func encode(_ map: Map) -> String {
        var models: [String: Any] = [:]
        for (id, e) in map.models {
            var obj: [String: Any] = ["hosts": e.hosts, "by": e.by.rawValue, "at": e.at]
            if let was = e.was { obj["was"] = was }
            models[id] = obj
        }
        var root: [String: Any] = ["v": 1, "rev": map.rev, "iid": map.iid, "models": models]
        if let up = map.upgrade { root["upgrade"] = ["model": up.model, "state": up.state] }
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Write `map` with `rev` bumped. Throws when the result would not
    /// validate (capacity), so a write can never produce a map the next read
    /// calls corrupt.
    static func store(_ map: Map, into store: inout [String: String]) throws {
        var next = map
        next.rev += 1
        if broken(11), next.nonCatalogRememberedCount > maxNonCatalogRemembered,
           let victim = next.models.filter({ !OpenRouterPresets.isCatalogModel($0.key) }).min(by: { $0.value.at < $1.value.at })?.key {
            next.models[victim] = nil
        }
        guard validate(next) else { throw PinMapError.capacity }
        store[storageKey] = encode(next)
    }

    enum PinMapError: Error, LocalizedError, Equatable {
        case capacity
        case invalidHosts
        case invalidModel
        var errorDescription: String? {
            switch self {
            case .capacity:
                return "Briglia remembers host choices for up to \(maxNonCatalogRemembered) OpenRouter models (plus the preset models). Forget one with /orprovider forget <model-id> (/orprovider remembered lists them), then try again."
            case .invalidHosts: return "a host list must be 0–\(maxHosts) OpenRouter provider slugs"
            case .invalidModel: return "not a valid OpenRouter model id"
            }
        }
    }

    // MARK: Effective model / legacy

    static func trimmed(_ v: String?) -> String { (v ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The OpenRouter model the profile runs, from ONE store snapshot: the
    /// stored model, else the implicit Gemini default for a key-only
    /// profile, else nil (OpenRouter unconfigured).
    static func effectiveORModel(_ store: [String: String]) -> String? {
        let model = trimmed(store[KeychainHelper.openRouterModelKey])
        if !model.isEmpty { return model }
        if broken(5) { return nil }
        return trimmed(store[KeychainHelper.openRouterApiKeyKey]).isEmpty ? nil : implicitDefaultModel
    }

    static func legacyRaw(_ store: [String: String]) -> String? {
        store[legacyKey]
    }

    /// Legacy slugs exactly as shipped `pinnedSlugs()` sent them.
    static func legacySlugs(_ store: [String: String]) -> [String] {
        OpenRouterProviderPin.slugs(from: store[legacyKey])
    }

    static func isMigratable(_ slugs: [String]) -> Bool {
        !slugs.isEmpty && isValidHostList(slugs)
    }

    /// D9 (frozen historical rule, plan §13.7): the only host 0.2.54/0.2.55
    /// auto-pinned, for the only model it did so. Never follows the catalog.
    static func legacyPresetHost(_ model: String) -> [String]? {
        model == "deepseek/deepseek-v4.1-flash" ? ["together"] : nil
    }

    /// D10 (frozen historical rule): the preset models that had an
    /// automatic host when the per-model map shipped (0.2.56–0.2.64). Only
    /// these get the m4 upgrade marker, so a preset that gains a host later
    /// (the 1017 snapshot in 0.2.65) never pins an existing install on
    /// upgrade. Never follows the catalog.
    static let d10UpgradeModels: Set<String> = [
        "deepseek/deepseek-v4.1-flash", "anthropic/claude-haiku-5.5", "openai/gpt-6-luna", "z-ai/glm-5.3-flash",
    ]

    static func migratedProvenance(slugs: [String], model: String) -> Provenance {
        slugs == legacyPresetHost(model) ? .preset : .migrated
    }

    /// A non-empty legacy value that migration could not attach to the
    /// effective current model (m3 non-migratable, or m6 unreadable map).
    /// While one exists, model-changing saves are refused (§13.3).
    struct PendingLegacy: Equatable {
        let value: String
        let reason: String
        let model: String
    }

    static func pendingLegacy(_ store: [String: String]) -> PendingLegacy? {
        let slugs = legacySlugs(store)
        guard !slugs.isEmpty, let model = effectiveORModel(store) else { return nil }
        let raw = store[legacyKey] ?? ""
        if !isMigratable(slugs) {
            return PendingLegacy(value: raw, reason: slugs.count > maxHosts ? "more than \(maxHosts) hosts" : "not a normalized provider slug", model: model)
        }
        switch state(store) {
        case .corrupt: return PendingLegacy(value: raw, reason: "the saved per-model hosts are unreadable", model: model)
        case .unsupported(let v, _): return PendingLegacy(value: raw, reason: "the saved per-model hosts use an unknown format (v\(v))", model: model)
        case .absent, .valid:
            // Migratable with a readable map: migration attaches it on the
            // next transaction, unless capacity refuses it.
            if case .valid(let m) = state(store), m.models[model] == nil, !OpenRouterPresets.isCatalogModel(model),
               m.nonCatalogRememberedCount >= maxNonCatalogRemembered {
                return PendingLegacy(value: raw, reason: "the per-model host list is full", model: model)
            }
            return nil
        }
    }

    // MARK: Request-time pin (§3.2, §13.3)

    /// The stored per-model pin for `model` (nil = none stored). Legacy
    /// fallback only for the effective current model.
    static func effectivePin(_ store: [String: String], model: String) -> [String]? {
        let legacy = legacySlugs(store)
        if !legacy.isEmpty, let current = effectiveORModel(store),
           (broken(22) || model == current) {
            return legacy
        }
        guard let map = state(store).map else { return nil }
        if broken(6), let any = map.models.values.first(where: { !$0.hosts.isEmpty }) { return any.hosts }
        guard let entry = map.models[model], !entry.hosts.isEmpty else { return nil }
        return entry.hosts
    }

    // MARK: Migration (§3.3, §13.1)

    struct MigrationOutcome: Equatable {
        var changed = false
        var note: String?
    }

    static func timestamp(_ now: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: now)
    }

    static func newIID() -> String { UUID().uuidString.lowercased() }

    /// Pure migration; the first statement of every pin/model mutation
    /// transaction (before the model slot changes).
    @discardableResult
    static func migrate(_ store: inout [String: String], now: Date = Date(), iid: () -> String = newIID) throws -> MigrationOutcome {
        let st = state(store)
        guard st.isReadable else { return MigrationOutcome() }  // m6
        let legacy = legacySlugs(store)
        let model = effectiveORModel(store)
        if !legacy.isEmpty {
            guard isMigratable(legacy) else { return MigrationOutcome() }  // m3
            guard let model else { return MigrationOutcome() }  // m2: settled by the first save
            var map = st.map ?? Map.fresh(iid: iid())
            if st.map == nil { map.rev = 0 }
            let provenance = broken(3) ? .migrated : migratedProvenance(slugs: legacy, model: model)
            // m1 overrides an existing entry (a legacy value can only
            // reappear after a downgrade, so it is the newer choice).
            map.models[model] = Entry(hosts: legacy, by: provenance, at: timestamp(now))
            if map.upgrade?.model == model { map.upgrade = nil }
            if !OpenRouterPresets.isCatalogModel(model), map.nonCatalogRememberedCount > maxNonCatalogRemembered {
                return MigrationOutcome()  // full: stays pending legacy
            }
            try OpenRouterPinMap.store(map, into: &store)
            store.removeValue(forKey: legacyKey)
            return MigrationOutcome(changed: true, note: "migrated")
        }
        guard st == .absent else { return MigrationOutcome() }  // m7
        // m5: nothing configured → no write (an absent map is the fresh
        // state; the first save creates it).
        guard model != nil else { return MigrationOutcome() }
        var map = Map.fresh(iid: iid())
        map.rev = 0
        if let model {
            // m4 (D10, option B): no entry for M ("not chosen"); only the
            // frozen 0.2.56 host presets (d10UpgradeModels) get the upgrade
            // marker. A preset that gained a host later (1017) stays "not
            // chosen" until /orprovider default.
            if d10UpgradeModels.contains(model) || (broken(36) && OpenRouterPresets.preset(forModel: model)?.autoHost != nil) {
                map.upgrade = UpgradeMarker(model: model, state: "pending")
            }
        }
        try OpenRouterPinMap.store(map, into: &store)  // m4
        return MigrationOutcome(changed: true, note: "m4")
    }

    /// Standalone migration (startup, setup-api, menu): its own NON-blocking
    /// transaction, never nested. Busy or failed → deferred; reads fall back.
    @discardableResult
    static func ensureMigrated() -> KeychainHelper.TryResult? {
        // Read-only pre-check: nothing to migrate → no lock, no write, no
        // directory created.
        guard let snapshot = KeychainHelper.tryLoadSnapshot() else { return .busy }
        var probe = snapshot
        guard (try? migrate(&probe, iid: { "probe" })).map({ $0.changed }) == true else { return .unchanged }
        return try? KeychainHelper.tryTransaction { try migrate(&$0) }
    }

    // MARK: Routing basis (§5)

    struct RoutingBasis: Equatable {
        let activeProfile: String?
        let llmProvider: String?
        let effectiveModel: String?
        let mapTag: String
        let legacyRaw: String?

        static func of(_ store: [String: String]) -> RoutingBasis {
            RoutingBasis(activeProfile: store[ProviderProfiles.activeProfileKey],
                         llmProvider: store[KeychainHelper.llmProviderKey],
                         effectiveModel: effectiveORModel(store),
                         mapTag: OpenRouterPinMap.mapTag(store),
                         legacyRaw: store[legacyKey])
        }
    }

    static func mapTag(_ store: [String: String]) -> String {
        switch state(store) {
        case .absent: return "absent"
        case .valid(let m): return "rev:\(m.iid):\(m.rev)"
        case .corrupt(let raw): return "corrupt:" + sha256(raw)
        case .unsupported(_, let raw): return "unsupported:" + sha256(raw)
        }
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `(iid, rev)` of a valid map, else the tag.
    static func revisionKey(_ store: [String: String]) -> String { mapTag(store) }
}
