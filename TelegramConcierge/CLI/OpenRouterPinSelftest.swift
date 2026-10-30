import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden deterministic test of the per-model OpenRouter host pins and the
/// model picker (plan `OPENROUTER_MODEL_PICKER_PLAN.md` v5): the map codec,
/// capacity, migration m1–m7 + D9, the precedence rows, the guarded
/// transactions and their races, cancellation, unreadable maps, the
/// write-path contract, the service-tier matcher, the Telegram encoding,
/// BYOK accounting, native reasoning replay, the D10 upgrade pass (U1–U19)
/// and a deliberate-break battery. Self-isolates into temp XDG roots (set
/// before StoragePaths is first touched); no network, no credentials.
struct OpenRouterPinSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__or-pin-selftest",
        abstract: "Internal: verify per-model OpenRouter host pins, the picker and the upgrade pass.",
        shouldDisplay: false
    )

    @MainActor
    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-or-pin-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        UserDefaults.standard.setVolatileDomain(["should_resume_polling_on_launch": false], forName: UserDefaults.argumentDomain)

        let suite = ORPinSuite()
        await suite.runAll()
        let baseline = suite.failures
        print(baseline.isEmpty ? "✔ all \(suite.passes) per-model pin checks pass" : "✖ \(baseline.count) per-model pin check(s) failed")

        // Deliberate breaks: each must make its named check fail.
        let breaks: [(Int, String)] = [
            (1, "E row 6: an explicit automatic entry blocks the preset"),
            (2, "H /orprovider off records an empty entry (explicit automatic)"),
            (3, "C D9: legacy together on the historical default model migrates as preset"),
            (4, "D migration attaches the legacy pin to the SOURCE model, never the destination"),
            (5, "C implicit model: a key-only legacy pin attaches to the Gemini default"),
            (6, "E A→B→A request bodies: only the main model's own pin is sent"),
            (7, "H an unreadable map never auto-pins (model saved, raw kept)"),
            (8, "N lanes bypass only with a non-empty pin on the CURRENT model"),
            (10, "E row 4b: a released user pin becomes a durable released entry"),
            (11, "B capacity: the 257th remembered model is refused, nothing evicted"),
            (12, "F-b a same-model choice written after validation wins (stale refusal)"),
            (13, "G hostListing rethrows CancellationError"),
            (14, "M HostListing JSON keeps absent / null / value tiers"),
            (15, "M Luna listing: openai never covers openai/flex or openai/fast"),
            (16, "M an eligible open-weight priority endpoint is uncertain and never releases a user pin"),
            (17, "M mixed listing tier-first: the standard endpoint is the representative"),
            (18, "R profile removal clears the per-model map, the legacy pin and the backup"),
            (20, "F-c an older listing never releases a newer positive destination pin"),
            (21, "P a model change is refused while an unresolved legacy pin exists (m6)"),
            (22, "P an m3 legacy pin applies only to its own (current) model"),
            (25, "U2 a failed listing keeps the marker, no write"),
            (26, "U11 an unrelated map change aborts the attempt and keeps the marker"),
            (27, "U17 a legacy pin arriving during the listing is never overwritten by the preset"),
            (28, "U16 a stale worker never recreates a removed map"),
            (31, "D11 OpenRouter offers max; other providers keep their lists"),
            (29, "V1 setup-api: an older listing never releases a newer user pin"),
            (30, "V2 menu: a concurrent effort edit after the barrier is refused, never overwritten"),
            (32, "V4 setup-api: an already-cancelled same-model save writes nothing"),
            (33, "V5 active OpenRouter, activate:false, text_only true: both vision slots agree"),
            (34, "V3 a startup migration deferred by a busy lock is retried by the pass, which then pins"),
            (35, "V6 a failed auto-pin on the model in use shows as not applied"),
            (36, "Z D10 frozen: an upgrading install on 1017 gets no upgrade marker (no host pinned on upgrade)"),
        ]
        var caught = 0
        for (n, label) in breaks {
            OpenRouterPinMap._testBreaks = [n]
            let s = ORPinSuite(quiet: true)
            await s.runAll()
            OpenRouterPinMap._testBreaks = []
            let hit = s.failures.contains { $0.hasPrefix(label) }
            print("\(hit ? "✔" : "✖") deliberate break \(n) caught by \"\(label)\"\(hit ? "" : " — failures: \(s.failures.prefix(3))")")
            if hit { caught += 1 }
        }
        print("deliberate breaks caught: \(caught)/\(breaks.count)")
        if !baseline.isEmpty || caught != breaks.count { throw ExitCode.failure }
    }
}

@MainActor
final class ORPinSuite {
    typealias Pin = OpenRouterProviderPin
    typealias PM = OpenRouterPinMap
    var failures: [String] = []
    var passes = 0
    let quiet: Bool
    init(quiet: Bool = false) { self.quiet = quiet }

    let dflt = "deepseek/deepseek-v4.1-flash", ds1017 = "deepseek/deepseek-v4.1-flash-1017"
    let haiku = "anthropic/claude-haiku-5.5", luna = "openai/gpt-6-luna", glm = "z-ai/glm-5.3-flash"
    let gemini = "google/gemini-3-flash-preview"
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures.append(label) }
        if !quiet { print("\(ok ? "✔" : "✖") \(label)\(ok ? "" : " — \(detail())")") }
    }

    // MARK: store helpers

    func reset(_ dict: [String: String] = [:]) {
        KeychainHelper._testFailWrites = false
        try? KeychainHelper.transaction { $0 = dict }
    }
    func snap() -> [String: String] { KeychainHelper.loadSnapshot() }
    func map() -> PM.Map? { PM.state(snap()).map }
    func entry(_ m: String) -> PM.Entry? { map()?.models[m] }
    func basis() -> PM.RoutingBasis { PM.RoutingBasis.of(snap()) }
    func ep(_ tag: String, _ tier: Pin.TierInfo = .absent) -> Pin.Endpoint {
        Pin.Endpoint(providerName: tag, tag: tag, promptUSDPerM: nil, completionUSDPerM: nil, cacheReadUSDPerM: nil,
                     contextLength: nil, uptimeLast30m: nil, status: 0, serviceTier: tier)
    }
    func listing(_ model: String, _ tags: [String]) -> Pin.HostListing {
        Pin.HostListing(model: model, result: .success(tags.map { ep($0) }))
    }
    func failed(_ model: String) -> Pin.HostListing { Pin.HostListing(model: model, result: .failure(.init(description: "HTTP 503"))) }
    func orStore(model: String? = nil, key: Bool = true, active: Bool = true, extra: [String: String] = [:]) -> [String: String] {
        var d: [String: String] = extra
        if key { d[KeychainHelper.openRouterApiKeyKey] = "sk-or-fixture" }
        if let model { d[KeychainHelper.openRouterModelKey] = model }
        if active {
            d[ProviderProfiles.activeProfileKey] = "openrouter"
            d[KeychainHelper.llmProviderKey] = LLMProvider.openRouter.rawValue
        }
        return d
    }
    func setEntry(_ m: String, _ hosts: [String]?, by: PM.Provenance = .user, was: [String]? = nil) {
        try? KeychainHelper.transaction { st in
            try PM.migrate(&st, now: self.now)
            var mp = PM.state(st).map ?? { var x = PM.Map.fresh(iid: "fixture"); x.rev = 0; return x }()
            mp.models[m] = hosts.map { PM.Entry(hosts: $0, by: by, was: was, at: "2026-10-18T00:00:00Z") }
            try PM.store(mp, into: &st)
        }
    }
    func modelChange(_ dest: String, _ l: Pin.HostListing?, expected: PM.RoutingBasis? = nil, textOnly: Bool? = false) -> Result<Pin.PinOutcome, Error> {
        Result { try Pin.commitModelChange(destination: dest, textOnly: textOnly, listing: l, expected: expected ?? basis(), now: now) }
    }
    func host(_ m: String, _ c: Pin.HostChoice, _ l: Pin.HostListing? = nil, expected: PM.RoutingBasis? = nil) -> Result<Pin.HostCommit, Error> {
        Result { try Pin.commitHostChoice(model: m, choice: c, listing: l, expected: expected ?? basis(), now: now) }
    }

    func runAll() async {
        codec()
        capacity()
        migration()
        migrationInSave()
        await precedence()
        races()
        await cancellation()
        unreadable()
        writePath()
        matcher()
        telegram()
        byokAndReplay()
        pendingLegacy()
        lanes()
        await managerFlow()
        await maxEffort()
        removal()
        await upgradePass()
        await reviewRound2()
        setupDefault0265()
        reset()
    }

    // MARK: Z. 0.2.65 setup default = the 1017 snapshot (owner 2026-10-30)

    func setupDefault0265() {
        let together = listing(ds1017, ["together", "inference-net/fp8"])
        check("Z the setup default is the 1017 snapshot, first preset, auto-pinning Together; key 'default' stays the undated model",
              ProviderProfiles.openRouterSetupDefaultModel == ds1017 && OpenRouterPresets.all.first?.id == ds1017
              && OpenRouterPresets.all.first?.autoHost == "together" && OpenRouterPresets.preset(forKey: "default")?.id == dflt
              && OpenRouterPresets.preset(forModel: dflt)?.autoHost == "together" && MenuWorkflow.openRouterDefaultLabel == "DeepSeek V4.1 Flash 1017")
        // Fresh store: a first setup on the default model pins Together for 1017.
        reset([:])
        let fresh = Result { try Pin.saveOpenRouterProfile(apiKey: "sk-or", model: ProviderProfiles.openRouterSetupDefaultModel, effort: "high", textOnly: false,
                                                           listing: together, presetHostPin: true, activate: true, listingBasis: basis(), now: now) }
        check("Z a fresh setup saves the 1017 snapshot pinned to Together",
              (try? fresh.get())?.outcome == .pinnedPreset(model: ds1017, slug: "together")
              && snap()[KeychainHelper.openRouterModelKey] == ds1017 && entry(ds1017)?.hosts == ["together"] && entry(ds1017)?.by == .preset
              && PM.effectivePin(snap(), model: ds1017) == ["together"], "\(fresh) \(snap())")
        // 0.2.56–0.2.64 install on the undated default with its preset pin: startup migration and a key-only save change nothing.
        reset(orStore(model: dflt))
        setEntry(dflt, ["together"], by: .preset)
        let before = snap()
        PM.ensureMigrated()
        let unchangedAtStart = snap() == before
        let keySave = Result { try Pin.saveOpenRouterProfile(apiKey: "sk-or-new", model: dflt, effort: "high", textOnly: false,
                                                             listing: nil, presetHostPin: true, activate: true, listingBasis: basis(), now: now) }
        var expectStore = before
        expectStore[KeychainHelper.openRouterApiKeyKey] = "sk-or-new"
        check("Z an existing install on the undated V4.1 Flash keeps its model and Together pin (startup + key change)",
              unchangedAtStart && (try? keySave.get()) != nil && snap()[KeychainHelper.openRouterModelKey] == dflt
              && snap()[PM.storageKey] == before[PM.storageKey] && PM.effectivePin(snap(), model: dflt) == ["together"]
              && PM.effectivePin(snap(), model: ds1017) == nil, "\(keySave) \(snap())")
        // ≤0.2.55 install on the undated default with the legacy Together pin: D9 migration, model unchanged.
        reset(orStore(model: dflt, extra: [PM.legacyKey: "together"]))
        PM.ensureMigrated()
        check("Z a pre-0.2.56 install on the undated V4.1 Flash migrates its legacy Together pin and keeps its model",
              snap()[KeychainHelper.openRouterModelKey] == dflt && entry(dflt)?.hosts == ["together"] && entry(dflt)?.by == .preset
              && entry(ds1017) == nil && map()?.upgrade == nil)
        // 0.2.56–0.2.64 install already on 1017 (no host decided): nothing written, requests still unpinned.
        reset(orStore(model: ds1017))
        setEntry("x/placeholder", nil)
        let before1017 = snap()
        PM.ensureMigrated()
        check("Z an existing install on 1017 without a host decision stays unpinned (no write, no request pin)",
              snap() == before1017 && PM.effectivePin(snap(), model: ds1017) == nil)
        // ≤0.2.55 install on 1017 with no pin: the frozen D10 rule gives no upgrade marker.
        reset(orStore(model: ds1017)); PM.ensureMigrated()
        check("Z D10 frozen: an upgrading install on 1017 gets no upgrade marker (no host pinned on upgrade)",
              map()?.upgrade == nil && map()?.models.isEmpty == true && PM.effectivePin(snap(), model: ds1017) == nil, "\(String(describing: map()))")
    }

    // MARK: A. codec

    func codec() {
        var m = PM.Map.fresh(iid: "abc")
        m.models[haiku] = .init(hosts: ["google-vertex"], by: .preset, at: "t")
        m.models["x/y"] = .init(hosts: [], by: .released, was: ["novita"], at: "t")
        m.upgrade = .init(model: dflt, state: "pending")
        let raw = PM.encode(m)
        check("A codec round-trip and deterministic encoding", PM.state([PM.storageKey: raw]) == .valid(m) && PM.encode(m) == raw && !raw.contains(" "), raw)
        var store: [String: String] = [:]
        try? PM.store(m, into: &store)
        check("A every map write increments rev", PM.state(store).map?.rev == m.rev + 1)
        check("A absent / corrupt / unsupported classification",
              PM.state([:]) == .absent && PM.state([PM.storageKey: "{x"]) == .corrupt("{x")
              && PM.state([PM.storageKey: #"{"v":2,"x":1}"#]) == .unsupported(2, #"{"v":2,"x":1}"#)
              && PM.state([PM.storageKey: #"{"v":true,"rev":1,"iid":"a","models":{}}"#]) == .corrupt(#"{"v":true,"rev":1,"iid":"a","models":{}}"#))
        let badReleased = #"{"iid":"a","models":{"m/x":{"at":"t","by":"released","hosts":[]}},"rev":1,"v":1}"#
        let nineHosts = #"{"iid":"a","models":{"m/x":{"at":"t","by":"user","hosts":["a","b","c","d","e","f","g","h","i"]}},"rev":1,"v":1}"#
        let upper = #"{"iid":"a","models":{"m/x":{"at":"t","by":"user","hosts":["Together"]}},"rev":1,"v":1}"#
        check("A released without was, nine hosts, or an unnormalized slug are corrupt",
              [badReleased, nineHosts, upper].allSatisfy { if case .corrupt = PM.state([PM.storageKey: $0]) { return true }; return false })
        reset(orStore(model: glm, extra: [PM.storageKey: #"{"v":2,"future":true}"#]))
        _ = modelChange(haiku, nil)
        check("A an unknown version is preserved byte-for-byte across a model save", snap()[PM.storageKey] == #"{"v":2,"future":true}"#)
        reset(orStore(model: glm))
        let nine = host(glm, .pin(["a", "b", "c", "d", "e", "f", "g", "h", "i"]))
        let long = host(String(repeating: "x", count: 301), .automatic)
        check("A writers enforce the validators (nine hosts, overlong model id)",
              (try? nine.get()) == nil && (try? long.get()) == nil)
    }

    // MARK: B. capacity

    func capacity() {
        reset(orStore(model: glm))
        var m = PM.Map.fresh(iid: "cap")
        for i in 0..<256 { m.models["v/m\(i)"] = .init(hosts: ["novita"], by: .user, at: String(format: "2026-%04d", i)) }
        m.models[haiku] = .init(hosts: [], by: .user, at: "2020")  // old explicit automatic for a preset
        try? KeychainHelper.transaction { st in try PM.store(m, into: &st) }
        let writes = KeychainHelper._testWriteCount
        let refused = host("v/new", .pin(["novita"]), expected: { var b = basis(); b = PM.RoutingBasis(activeProfile: b.activeProfile, llmProvider: b.llmProvider, effectiveModel: b.effectiveModel, mapTag: b.mapTag, legacyRaw: b.legacyRaw); return b }())
        check("B capacity: the 257th remembered model is refused, nothing evicted",
              (try? refused.get()) == nil && KeychainHelper._testWriteCount == writes && entry("v/m0") != nil && entry(haiku)?.hosts == [], "\(refused)")
        check("B capacity: replacing an existing remembered entry is allowed at the limit",
              (try? host("v/m5", .automatic).get()) != nil && entry("v/m5")?.hosts == [])
        check("B capacity: a catalog model uses its reserved slot at the limit",
              (try? host(glm, .pin(["together"])).get()) != nil && entry(glm)?.hosts == ["together"])
        // The old explicit automatic for Haiku survives and still suppresses the preset.
        let back = modelChange(haiku, listing(haiku, ["google-vertex/global"]))
        check("B capacity: an old non-current explicit automatic still blocks Haiku's preset",
              (try? back.get()) == .automaticKept && entry(haiku)?.hosts == [], "\(back)")
    }

    // MARK: C. migration m1–m7 + D9

    func migration() {
        reset(orStore(model: glm, extra: [PM.legacyKey: "novita"]))
        PM.ensureMigrated()
        check("C m1: a legacy pin moves to the effective model as migrated, legacy removed",
              entry(glm) == .init(hosts: ["novita"], by: .migrated, at: entry(glm)?.at ?? "") && snap()[PM.legacyKey] == nil)
        reset(orStore(model: dflt, extra: [PM.legacyKey: "together"]))
        PM.ensureMigrated()
        let d9 = entry(dflt)?.by
        var others: [PM.Provenance?] = []
        for (model, legacy) in [(glm, "together"), (dflt, "together,novita"), (dflt, "together,together"), (dflt, "together/fp8")] {
            reset(orStore(model: model, extra: [PM.legacyKey: legacy]))
            PM.ensureMigrated()
            others.append(entry(model)?.by)
        }
        check("C D9: legacy together on the historical default model migrates as preset",
              d9 == .preset && others == [.migrated, .migrated, .migrated, .migrated] && PM.legacyPresetHost(glm) == nil
              && OpenRouterPresets.preset(forModel: glm)?.autoHost == "together", "\(String(describing: d9)) \(others)")
        reset(orStore(model: dflt, extra: [PM.legacyKey: "Together"]))
        PM.ensureMigrated()
        check("C D9: an uppercase legacy value is not migrated (m3) and is sent verbatim",
              snap()[PM.legacyKey] == "Together" && PM.effectivePin(snap(), model: dflt) == ["Together"])
        // Implicit model.
        reset(orStore(model: nil, extra: [PM.legacyKey: "novita, deepinfra"]))
        PM.ensureMigrated()
        check("C implicit model: a key-only legacy pin attaches to the Gemini default",
              entry(gemini)?.hosts == ["novita", "deepinfra"] && Pin.pinnedSlugs() == ["novita", "deepinfra"], "\(snap())")
        // m3 scope.
        reset(orStore(model: glm, extra: [PM.legacyKey: "a b"]))
        check("C m3: a non-migratable legacy value applies verbatim to the effective model only",
              PM.effectivePin(snap(), model: glm) == ["a b"] && PM.effectivePin(snap(), model: haiku) == nil)
        // m1 override.
        reset(orStore(model: glm))
        setEntry(glm, ["novita"])
        try? KeychainHelper.save(key: PM.legacyKey, value: "deepinfra")
        PM.ensureMigrated()
        check("C m1: a legacy value overrides the current model's entry (downgrade writer)", entry(glm)?.hosts == ["deepinfra"] && entry(glm)?.by == .migrated)
        // m6.
        reset(orStore(model: glm, extra: [PM.storageKey: "{bad", PM.legacyKey: "novita"]))
        PM.ensureMigrated()
        check("C m6: corrupt map + legacy → nothing migrated, raw kept, legacy applies to the current model",
              snap()[PM.storageKey] == "{bad" && snap()[PM.legacyKey] == "novita" && PM.effectivePin(snap(), model: glm) == ["novita"])
        // m4 / m5.
        reset(orStore(model: dflt)); PM.ensureMigrated()
        let m4 = map()
        reset(orStore(model: ds1017)); PM.ensureMigrated()
        let m4b = map()
        reset(orStore(model: nil)); PM.ensureMigrated()
        let m4c = map()
        reset([:])
        let w5 = KeychainHelper._testWriteCount
        PM.ensureMigrated()
        let m5 = PM.state(snap()) == .absent && KeychainHelper._testWriteCount == w5 ? PM.Map.fresh(iid: "none") : nil
        check("C m4: the current preset model gets no entry and an upgrade marker only with a frozen D10 host",
              m4?.models.isEmpty == true && m4?.upgrade == .init(model: dflt, state: "pending")
              && m4b?.upgrade == nil && m4b?.models.isEmpty == true && m4c?.upgrade == nil, "\(String(describing: m4)) \(String(describing: m4b))")
        check("C m5: a fresh store writes nothing (the map stays absent)", m5 != nil)
        reset(orStore(model: glm, extra: [PM.legacyKey: "novita"]))
        PM.ensureMigrated()
        let w = KeychainHelper._testWriteCount
        let second = PM.ensureMigrated()
        check("C migration is idempotent (second run writes nothing)", second == .unchanged && KeychainHelper._testWriteCount == w)
        // m2: key-less, model-less store with a legacy pin: settled by the first save.
        for (label, l, expect) in [("served", listing(glm, ["novita/fp8"]), ["novita"]), ("unserved", listing(glm, ["together"]), [] as [String]),
                                   ("failed", failed(glm), ["novita"])] {
            reset([PM.legacyKey: "novita"])
            PM.ensureMigrated()
            let r = Result { try Pin.saveOpenRouterProfile(apiKey: "sk-or", model: glm, effort: "high", textOnly: false, listing: l, presetHostPin: true, activate: false, listingBasis: basis(), now: now) }
            check("C m2 (\(label)): the legacy pin becomes the destination's entry, validated",
                  (try? r.get()) != nil && entry(glm)?.hosts == expect && snap()[PM.legacyKey] == nil, "\(r) \(snap())")
        }
    }

    // MARK: D. migration inside the save, write failure, pre-migration basis

    func migrationInSave() {
        reset(orStore(model: glm, extra: [PM.legacyKey: "novita"]))
        let r = Result { try Pin.saveOpenRouterProfile(apiKey: "sk-or", model: haiku, effort: "high", textOnly: false,
                                                       listing: listing(haiku, ["google-vertex/global"]), presetHostPin: true, activate: false, listingBasis: basis(), now: now) }
        check("D migration attaches the legacy pin to the SOURCE model, never the destination",
              (try? r.get()) != nil && entry(glm)?.hosts == ["novita"] && entry(haiku)?.hosts == ["google-vertex"] && entry(haiku)?.by == .preset, "\(r) \(snap())")
        reset(orStore(model: glm, extra: [PM.legacyKey: "novita", ProviderProfiles.openrouterTextOnlyKey: "true", KeychainHelper.textOnlyModelEnabledKey: "true"]))
        let before = snap()
        KeychainHelper._testFailWrites = true
        let failedSave = modelChange(haiku, listing(haiku, ["google-vertex"]))
        KeychainHelper._testFailWrites = false
        check("D an atomic-write failure leaves every byte unchanged (model, both vision slots, map, legacy)",
              (try? failedSave.get()) == nil && snap() == before)
        reset(orStore(model: glm, extra: [PM.legacyKey: "novita"]))
        let b = basis()
        let own = host(glm, .automatic, expected: b)
        check("D a command's own migration doesn't make it stale (pre-migration basis)",
              (try? own.get()) != nil && entry(glm)?.hosts == [] && snap()[PM.legacyKey] == nil, "\(own)")
    }

    // MARK: E. precedence

    func precedence() async {
        func decideOn(_ entry: PM.Entry?, _ dest: String, _ l: PM.ListingResult, preset: Bool = true, reset r: Bool = false, stale: Bool = false) -> (PM.Map, Pin.PinOutcome) {
            var m = PM.Map.fresh(iid: "p")
            if let entry { m.models[dest] = entry }
            let o = PM.decide(map: &m, destination: dest, listing: l, flags: .init(presetHostPin: preset, explicitReset: r), staleListing: stale, now: now)
            return (m, o)
        }
        let together: PM.ListingResult = .served([ep("together"), ep("novita/fp8")])
        let r1 = decideOn(nil, dflt, together)
        check("E row 1: no entry + preset host served → pinned preset", r1.1 == .pinnedPreset(model: dflt, slug: "together") && r1.0.models[dflt]?.by == .preset)
        let r2 = [decideOn(nil, dflt, .failed("x")).0, decideOn(nil, dflt, .notFetched).0, decideOn(nil, dflt, .served([ep("novita")])).0]
        check("E row 2: failed / not fetched / not served → automatic, nothing written", r2.allSatisfy { $0.models.isEmpty })
        let user = PM.Entry(hosts: ["novita"], by: .user, at: "t"), preset = PM.Entry(hosts: ["together"], by: .preset, at: "t")
        check("E row 3: served user and preset entries are kept",
              decideOn(user, dflt, together).1 == .kept(["novita"]) && decideOn(preset, dflt, together).1 == .kept(["together"]))
        let r4a = decideOn(preset, dflt, .served([ep("novita")]))
        check("E row 4a: an unserved preset entry is deleted", r4a.0.models[dflt] == nil && { if case .released = r4a.1 { return true }; return false }())
        let r4b = decideOn(user, glm, .served([ep("together")]))
        check("E row 4b: a released user pin becomes a durable released entry",
              r4b.0.models[glm]?.by == .released && r4b.0.models[glm]?.was == ["novita"] && r4b.0.models[glm]?.hosts == [])
        check("E row 5: an unreadable listing keeps the pin unverified",
              { if case .keptUnverified(["novita"], _) = decideOn(user, glm, .failed("x")).1 { return true }; return false }())
        let r6 = decideOn(.init(hosts: [], by: .user, at: "t"), dflt, together)
        check("E row 6: an explicit automatic entry blocks the preset", r6.1 == .automaticKept && r6.0.models[dflt]?.hosts == [])
        check("E rows 8/10: another model, or preset pin off → nothing",
              decideOn(nil, "v/other", together).0.models.isEmpty
              && decideOn(nil, dflt, together, preset: false).0.models.isEmpty && decideOn(nil, ds1017, together, preset: false).0.models.isEmpty)
        let r1017 = decideOn(nil, ds1017, together)
        check("E row 1 (0.2.65): the 1017 snapshot pins Together like the old default",
              r1017.1 == .pinnedPreset(model: ds1017, slug: "together") && r1017.0.models[ds1017]?.by == .preset)
        let partial = decideOn(.init(hosts: ["together", "novita"], by: .user, at: "t"), glm, .served([ep("together")]))
        check("E a partially served multi-host entry is released whole", partial.0.models[glm]?.by == .released && partial.0.models[glm]?.was == ["together", "novita"])
        // Row 9 + reset through the public path.
        reset(orStore(model: dflt))
        PM.ensureMigrated()
        _ = Result { try Pin.saveOpenRouterProfile(apiKey: nil, model: dflt, effort: "medium", textOnly: false, listing: listing(dflt, ["together"]), presetHostPin: true, activate: false, listingBasis: basis(), now: now) }
        check("E row 9: a same-model save decides nothing (even with a listing)", entry(dflt) == nil)
        let reset1 = host(dflt, .reset, listing(dflt, ["together"]))
        check("E an explicit reset bypasses row 9 and applies the preset", (try? reset1.get())?.outcome == .pinnedPreset(model: dflt, slug: "together") && entry(dflt)?.by == .preset)
        // A→B→A request bodies through the real OpenRouterService.
        reset(orStore(model: glm))
        setEntry(glm, ["novita", "deepinfra"])
        func only() async -> [String]? { await OpenRouterService().researcherExecutionContext(modelOverride: nil, textOnlyOverride: nil, lane: .subagent("t")).providerPreferences?.only }
        let a = await only()
        _ = modelChange(dflt, listing(dflt, ["together"]))
        let b = await only()
        _ = modelChange(glm, nil)
        let a2 = await only()
        _ = host(glm, .automatic)
        let auto = await only()
        check("E A→B→A request bodies: only the main model's own pin is sent",
              a == ["novita", "deepinfra"] && b == ["together"] && a2 == ["novita", "deepinfra"] && auto == nil, "\(String(describing: a)) \(String(describing: b)) \(String(describing: a2)) \(String(describing: auto))")
    }

    // MARK: F. races (deterministic interleavings)

    func races() {
        // (a) /orprovider validated for M, model changed to N before commit.
        reset(orStore(model: glm)); PM.ensureMigrated()
        var b = basis()
        try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: haiku)
        let a = host(glm, .pin(["novita"]), expected: b)
        check("F-a model changed after validation → no write to either model", (try? a.get()) == nil && entry(glm) == nil && entry(haiku) == nil)
        // (b) same-model automatic written by another writer after validation.
        reset(orStore(model: glm)); PM.ensureMigrated()
        b = basis()
        _ = host(glm, .automatic)
        let bb = host(glm, .pin(["novita"]), expected: b)
        check("F-b a same-model choice written after validation wins (stale refusal)", (try? bb.get()) == nil && entry(glm)?.hosts == [])
        // (c) destination positive pin Y arriving during /model's listing.
        reset(orStore(model: dflt)); PM.ensureMigrated()
        setEntry(glm, ["old"])
        b = basis()
        setEntry(glm, ["newer"])
        let c = modelChange(glm, listing(glm, ["old"]), expected: b)
        check("F-c an older listing never releases a newer positive destination pin",
              entry(glm)?.hosts == ["newer"] && { if case .success(.keptUnverified(["newer"], _)) = c { return true }; return false }(), "\(c)")
        reset(orStore(model: dflt)); PM.ensureMigrated()
        b = basis()
        setEntry(glm, [])
        let c2 = modelChange(glm, listing(glm, ["together"]), expected: b)
        check("F-c a newer explicit automatic destination entry is honoured", (try? c2.get()) == .automaticKept && entry(glm)?.hosts == [])
        // (d) absent destination + changed revision → no pin from the old listing.
        reset(orStore(model: glm)); PM.ensureMigrated()
        b = basis()
        setEntry("v/unrelated", ["x"])
        let d = modelChange(haiku, listing(haiku, ["google-vertex"]), expected: b)
        check("F-d an old listing never pins after a revision change", entry(haiku) == nil && { if case .success(.presetSkipped) = d { return true }; return false }())
        // (e) reset race.
        reset(orStore(model: haiku)); PM.ensureMigrated()
        setEntry(haiku, ["anthropic"])
        b = basis()
        setEntry(haiku, ["anthropic", "google-vertex"])
        let e = host(haiku, .reset, listing(haiku, ["google-vertex"]), expected: b)
        check("F-e a reset racing another write is refused; the previous entry stays", (try? e.get()) == nil && entry(haiku)?.hosts == ["anthropic", "google-vertex"])
        // (f) source change during /model.
        reset(orStore(model: glm)); PM.ensureMigrated()
        b = basis()
        try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: ds1017)
        let f = modelChange(haiku, nil, expected: b)
        check("F-f a source model change during /model is refused", (try? f.get()) == nil && snap()[KeychainHelper.openRouterModelKey] == ds1017)
        // (g) ABA X→off→X.
        reset(orStore(model: glm)); PM.ensureMigrated()
        setEntry(glm, ["x"])
        b = basis()
        setEntry(glm, []); setEntry(glm, ["x"])
        let g = host(glm, .pin(["y"]), expected: b)
        check("F-g same-value ABA is refused through the revision", (try? g.get()) == nil && entry(glm)?.hosts == ["x"])
        // (h) migration + a concurrent save with the same pre-migration basis.
        reset(orStore(model: glm, extra: [PM.legacyKey: "novita"]))
        b = basis()
        let h1 = modelChange(haiku, nil, expected: b)
        let h2 = host(glm, .automatic, expected: b)
        check("F-h migration + concurrent writer: the first commits (with migration), the second is stale",
              (try? h1.get()) != nil && (try? h2.get()) == nil && entry(glm)?.hosts == ["novita"])
        // Recovery / recreate boundary.
        reset(orStore(model: glm, extra: [PM.storageKey: "{bad"]))
        let pre = basis()
        _ = host(glm, .automatic)
        let after = host(glm, .pin(["x"]), expected: pre)
        check("F recovery changes the map incarnation: an old basis is stale", (try? after.get()) == nil && entry(glm)?.hosts == [])
    }

    // MARK: G. cancellation

    func cancellation() async {
        var outcomes: [String] = []
        for fetch in [{ (_: String, _: String) async throws -> [Pin.Endpoint] in throw CancellationError() },
                      { (_: String, _: String) async throws -> [Pin.Endpoint] in throw URLError(.cancelled) }] {
            do { _ = try await Pin.hostListing(model: haiku, apiKey: "k", fetch: fetch); outcomes.append("returned") }
            catch is CancellationError { outcomes.append("cancel") } catch { outcomes.append("other") }
        }
        let inFlight: String = await Task {
            do {
                _ = try await Pin.hostListing(model: self.haiku, apiKey: "k", fetch: { _, _ in withUnsafeCurrentTask { $0?.cancel() }; return [] })
                return "returned"
            } catch is CancellationError { return "cancel" } catch { return "other" }
        }.value
        check("G hostListing rethrows CancellationError", outcomes == ["cancel", "cancel"] && inFlight == "cancel", "\(outcomes) \(inFlight)")
        reset(orStore(model: glm)); PM.ensureMigrated()
        let w = KeychainHelper._testWriteCount
        let viaNeeded: String
        do { _ = try await Pin.listingIfNeeded(store: snap(), newModel: haiku, apiKey: "k", presetHostPin: true, fetch: { _, _ in throw CancellationError() }); viaNeeded = "returned" }
        catch { viaNeeded = error is CancellationError ? "cancel" : "other" }
        check("G listingIfNeeded propagates cancellation; nothing is written", viaNeeded == "cancel" && KeychainHelper._testWriteCount == w)
    }

    // MARK: H. unreadable map

    func unreadable() {
        reset(orStore(model: glm, extra: [PM.storageKey: "{bad"]))
        let r = modelChange(dflt, listing(dflt, ["together"]))
        check("H an unreadable map never auto-pins (model saved, raw kept)",
              (try? r.get()) == .unreadable && snap()[PM.storageKey] == "{bad" && snap()[KeychainHelper.openRouterModelKey] == dflt, "\(r)")
        check("H the host state says unreadable", OpenRouterPresets.hostStatus(model: dflt, store: snap()).state == .corrupt)
        let rec = host(dflt, .automatic)
        let m = map()
        check("H explicit recovery backs the raw value up, recreates the map (new incarnation) and applies the choice",
              (try? rec.get())?.recovered == true && snap()[PM.corruptBackupKey] == "{bad" && m?.models[dflt]?.hosts == [] && m?.iid != "fixture")
        reset(orStore(model: glm)); PM.ensureMigrated()
        _ = host(glm, .automatic)
        check("H /orprovider off records an empty entry (explicit automatic)", entry(glm) == .init(hosts: [], by: .user, at: entry(glm)?.at ?? ""))
    }

    // MARK: K. write-path contract

    func writePath() {
        reset(orStore(model: glm, extra: [KeychainHelper.openRouterReasoningEffortKey: "low", ProviderProfiles.openrouterTextOnlyKey: "true",
                                          KeychainHelper.textOnlyModelEnabledKey: "true"]))
        _ = modelChange(haiku, listing(haiku, ["google-vertex"]), textOnly: false)
        let s = snap()
        check("K /model writes model + both vision slots (OpenRouter active), never key or effort",
              s[KeychainHelper.openRouterModelKey] == haiku && s[ProviderProfiles.openrouterTextOnlyKey] == "false"
              && s[KeychainHelper.textOnlyModelEnabledKey] == "false" && s[KeychainHelper.openRouterReasoningEffortKey] == "low"
              && s[KeychainHelper.openRouterApiKeyKey] == "sk-or-fixture")
        reset(orStore(model: glm, active: false, extra: [KeychainHelper.textOnlyModelEnabledKey: "true",
                                                         ProviderProfiles.activeProfileKey: "opencode", KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue]))
        _ = modelChange(haiku, nil, textOnly: false)
        check("K an inactive OpenRouter profile edit leaves the runtime vision slot alone",
              snap()[KeychainHelper.textOnlyModelEnabledKey] == "true" && snap()[ProviderProfiles.openrouterTextOnlyKey] == "false")
        reset([:])
        let w = KeychainHelper._testWriteCount
        let first = Result { try Pin.saveOpenRouterProfile(apiKey: "sk-or", model: dflt, effort: "high", textOnly: false, listing: listing(dflt, ["together"]),
                                                           presetHostPin: true, activate: nil, listingBasis: basis(), now: now) }
        check("K first setup with activate omitted activates in the same single write as model and pin",
              (try? first.get())?.activated == true && KeychainHelper._testWriteCount == w + 1 && ProviderProfiles.activeProfile() == .openrouter
              && entry(dflt)?.hosts == ["together"], "\(first)")
    }

    // MARK: M. matcher

    func matcher() {
        let lunaListing = [ep("openai/flex", .value("flex")), ep("openai", .null), ep("azure", .null), ep("openai/fast", .value("priority")),
                           ep("amazon-bedrock/us-east-1", .null)]
        check("M Luna listing: openai never covers openai/flex or openai/fast",
              Pin.validate(pin: "openai", endpoints: lunaListing) == .served([lunaListing[1]])
              && !Pin.matches(pin: "openai", endpoint: lunaListing[0]) && !Pin.matches(pin: "openai", endpoint: lunaListing[3]))
        let noMeta = [ep("openai/flex"), ep("openai/fast")]
        check("M suffix fallback without metadata: tier endpoints are not covered by the base slug",
              Pin.validate(pin: "openai", endpoints: noMeta) == .notServed(available: []) && Pin.baseChoices(noMeta).isEmpty)
        check("M aliases: openai/priority targets openai/fast", Pin.matches(pin: "openai/priority", endpoint: ep("openai/fast")))
        check("M mixed listing tier-first: the standard endpoint is the representative",
              Pin.baseChoices([ep("openai/flex", .value("flex")), ep("openai", .null)]).map(\.tag) == ["openai"])
        check("M variant/region prefixes: baseten/fp4 matches baseten/fp4/us; vertex regions under google-vertex",
              Pin.matches(pin: "baseten/fp4", endpoint: ep("baseten/fp4/us")) && !Pin.matches(pin: "baseten/fp4", endpoint: ep("baseten/fp8"))
              && ["google-vertex/global", "google-vertex/europe", "google-vertex/us"].allSatisfy { Pin.matches(pin: "google-vertex", endpoint: ep($0)) })
        let openWeight = [ep("deepinfra/priority", .value("priority"))]
        var m = PM.Map.fresh(iid: "u"); m.models[glm] = .init(hosts: ["deepinfra"], by: .user, at: "t")
        let o = PM.decide(map: &m, destination: glm, listing: .served(openWeight), flags: .init(presetHostPin: true, explicitReset: false), staleListing: false, now: now)
        check("M an eligible open-weight priority endpoint is uncertain and never releases a user pin",
              Pin.eligibility(pin: "deepinfra", endpoint: openWeight[0]) == .uncertain && m.models[glm]?.hosts == ["deepinfra"]
              && { if case .keptUnverified = o { return true }; return false }(), "\(o)")
        check("M nested unknown tier on a non-first-party provider is uncertain", Pin.eligibility(pin: "x", endpoint: ep("x/fp8/flex")) == .uncertain)
        let l = Pin.HostListing(model: luna, result: .success([ep("a"), ep("b", .null), ep("c", .value("flex"))]))
        let round = Pin.HostListing(json: l.json)
        let tiers = (try? round?.result.get())?.map(\.serviceTier) ?? []
        check("M HostListing JSON keeps absent / null / value tiers", tiers == [.absent, .null, .value("flex")], "\(tiers)")
        if case .notFetched = l.listingResult(for: haiku) { check("M a listing for another model is never used", true) } else { check("M a listing for another model is never used", false) }
        check("M legacy hosts JSON is accepted (tiers unknown) and oversize is refused",
              Pin.HostListing(json: ["model": "m", "hosts": ["a"]]) != nil
              && Pin.HostListing(json: ["model": "m", "hosts": Array(repeating: "a", count: 501)]) == nil)
    }

    // MARK: L. Telegram encoding

    func telegram() {
        let data = TelegramCommandMenu.encode(.openRouterPreset(key: "haiku55"))
        check("L preset buttons: bm1:r:<key>, decoded back, command is /model <full id>",
              data == "bm1:r:haiku55" && TelegramCommandMenu.decode("bm1:r:haiku55") == .openRouterPreset(key: "haiku55")
              && TelegramCommandMenu.commandText(for: .openRouterPreset(key: "haiku55")) == "/model anthropic/claude-haiku-5.5")
        check("L unknown keys, extra components and encodings of unknown keys are refused",
              TelegramCommandMenu.decode("bm1:r:nope") == nil && TelegramCommandMenu.decode("bm1:r:haiku55:x") == nil
              && TelegramCommandMenu.encode(.openRouterPreset(key: "nope")) == nil)
        let rows = ConversationManager.openRouterRows(store: orStore(model: dflt))
        let menu = TelegramCommandMenu.modelMenu(catalog: .openrouter(rows), profile: "openrouter", current: dflt)
        check("L the OpenRouter menu: five preset buttons in order + Other, each naming its host behaviour",
              menu.rows.count == 6 && menu.rows.prefix(5).map { $0[0].data } == OpenRouterPresets.all.map { "bm1:r:\($0.key)" }
              && menu.rows[5][0].data == "bm1:m:?" && menu.rows[0][0].label.contains("Together") && menu.rows[1][0].label.contains("chosen by OpenRouter")
              && menu.rows.allSatisfy { $0[0].data.utf8.count <= 64 }, "\(menu.rows.map { $0[0].label })")
    }

    // MARK: O/P. BYOK accounting and native replay

    func byokAndReplay() {
        let context = ProviderExecutionContext(provider: .openRouter, model: haiku, endpoint: "http://127.0.0.1:9/v1/chat/completions",
            authorization: "Bearer x", affinityKey: "x", lane: .main, provenance: "\(haiku)#openrouter", providerPreferences: nil,
            reasoning: nil, reasoningEffort: nil, thinkingType: nil, useReasoningContent: false, textOnly: false, anthropicCacheControl: true,
            renderPDFAsImages: true)
        let details = #"[{"type":"reasoning.text","text":"think","signature":"sig==","format":"anthropic-claude-v1","index":0,"future_field":{"a":1}},{"type":"reasoning.encrypted","data":"ENC","id":"rs_1","index":1}]"#
        let body = #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"grep","arguments":"{}"}}],"reasoning":"think","reasoning_details":"# + details + #"},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"cost":0,"cost_details":{"upstream_inference_cost":0.0042}}}"#
        guard let response = try? ChatCompletionsAdapter(context: context).decodeResponse(Data(body.utf8)),
              case .toolCalls(let assistant, _, _, _, let spend) = response else {
            check("O BYOK: upstream cost is charged on the main path", false, "decode failed"); return
        }
        check("O BYOK: upstream cost is charged on the main path (cost 0 + upstream_inference_cost)", spend.map { abs($0 - 0.0042) < 1e-12 } == true, "\(String(describing: spend))")
        // Store (Codable round trip) then replay to the same model.
        func detailsJSON(_ msg: OpenRouterAPIMessage) -> Any? {
            guard let data = try? JSONEncoder().encode(msg), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["reasoning_details"]
        }
        let stored = (try? JSONEncoder().encode(assistant)).flatMap { try? JSONDecoder().decode(AssistantToolCallMessage.self, from: $0) }
        let api = OpenRouterAPIMessage(role: "assistant", content: nil, toolCalls: stored?.toolCalls, reasoning: stored?.reasoning,
                                       reasoningDetails: stored?.reasoningDetails, producedByModel: stored?.producedByModel)
        let same = api.sanitizedForProvider(.openRouter, useReasoningContent: false, reasoningFromCurrentModel: true)
        let expected = try? JSONSerialization.jsonObject(with: Data(details.utf8))
        check("P signed and encrypted reasoning_details survive decode → store → same-model replay exactly (unknown fields, order)",
              stored != nil && NSDictionary(dictionary: ["d": detailsJSON(same.message) ?? NSNull()]).isEqual(to: ["d": expected ?? 0]) && same.reasoningNote == nil)
        let foreign = api.sanitizedForProvider(.openRouter, useReasoningContent: false, reasoningFromCurrentModel: false)
        check("P a cross-model replay drops native details into the historical note", detailsJSON(foreign.message) == nil && foreign.reasoningNote != nil)
    }

    // MARK: §13.3 pending legacy

    func pendingLegacy() {
        reset(orStore(model: glm, extra: [PM.storageKey: "{bad", PM.legacyKey: "novita"]))
        let before = snap()
        let r = modelChange(haiku, listing(haiku, ["google-vertex"]))
        check("P a model change is refused while an unresolved legacy pin exists (m6)", (try? r.get()) == nil && snap() == before
              && { if case .failure(let e) = r { return e is Pin.PendingLegacyRefusal }; return false }(), "\(r)")
        let same = modelChange(glm, nil)
        check("P a same-model edit is still allowed with a pending legacy pin", (try? same.get()) != nil)
        let resolve = host(glm, .pin(["deepinfra"]))
        check("P an explicit host choice for the current model resolves it (recovery + legacy removed)",
              (try? resolve.get())?.recovered == true && snap()[PM.legacyKey] == nil && entry(glm)?.hosts == ["deepinfra"])
        reset(orStore(model: glm, extra: [PM.legacyKey: "Bad Slug"]))
        let m3 = modelChange(haiku, nil)
        check("P an m3 legacy pin applies only to its own (current) model",
              (try? m3.get()) == nil && PM.effectivePin(snap(), model: haiku) == nil && PM.effectivePin(snap(), model: glm) == ["Bad Slug"])
        reset(orStore(model: glm, extra: [PM.legacyKey: "Bad Slug"]))
        KeychainHelper._testFailWrites = true
        let before3 = snap()
        let failing = host(glm, .automatic)
        KeychainHelper._testFailWrites = false
        check("P a failing resolve write keeps every byte", (try? failing.get()) == nil && snap() == before3)
    }

    // MARK: Manager flow (Telegram/terminal commands)

    func managerFlow() async {
        reset(orStore(model: "or/model-a"))
        UserDefaults.standard.setVolatileDomain(["should_resume_polling_on_launch": false], forName: UserDefaults.argumentDomain)
        let manager = ConversationManager()
        Pin.fetchOverride = { model, _ in
            let tags = model == "or/model-a" ? ["novita/fp8", "deepinfra/fp4"] : ["z-ai/fp8"]
            return try JSONSerialization.data(withJSONObject: ["data": ["endpoints": tags.map { ["tag": $0, "provider_name": $0] }]])
        }
        defer { Pin.fetchOverride = nil }
        func say(_ t: String) async -> String { (await manager.handleTerminalCommand(t) ?? []).joined(separator: "\n") }
        let pinA = await say("/orprovider novita")
        let toB = await say("/model or/model-b")
        let pinB = await say("/orprovider Z-AI")
        let backA = await say("/model or/model-a")
        let off = await say("/orprovider off")
        let remembered = await say("/orprovider remembered")
        check("MF /orprovider and /model on the manager: per-model pins, A→B→A, off recorded",
              pinA.contains("for or/model-a pinned to novita") && toB.contains("Model switched to or/model-b")
              && pinB.contains("for or/model-b pinned to z-ai") && backA.contains("your earlier choice") && off.contains("OpenRouter chooses the host for or/model-a")
              && entry("or/model-a")?.hosts == [] && entry("or/model-b")?.hosts == ["z-ai"] && remembered.contains("or/model-b: z-ai"),
              [pinA, toB, pinB, backA, off, remembered].joined(separator: " | "))
        let listingMenu = await say("/model")
        check("MF terminal /model on OpenRouter lists the presets with their host behaviour",
              listingMenu.contains("anthropic/claude-haiku-5.5") && listingMenu.contains("Google Vertex")
              && listingMenu.contains("deepseek/deepseek-v4.1-flash-1017") && listingMenu.contains("Together"), listingMenu)
    }

    // MARK: D11. max effort on OpenRouter

    func maxEffort() async {
        check("D11 OpenRouter offers max; other providers keep their lists",
              ConversationManager.effortLevels(for: .openRouter) == ["minimal", "low", "medium", "high", "xhigh", "max"]
              && ConversationManager.effortLevels(for: .openAICompatible) == ["minimal", "low", "medium", "high", "xhigh"]
              && !ConversationManager.effortLevels(for: .lmStudio).contains("max"))
        reset(orStore(model: glm, extra: [KeychainHelper.openRouterReasoningEffortKey: "max"]))
        let ctx = await OpenRouterService().researcherExecutionContext(modelOverride: nil, textOnlyOverride: nil, lane: .subagent("t"))
        check("D11 max is sent verbatim as reasoning.effort on OpenRouter", ctx.reasoning?.effort == "max" && ctx.reasoningEffort == nil, "\(String(describing: ctx.reasoning))")
    }

    // MARK: N. lanes

    func lanes() {
        reset(orStore(model: glm)); PM.ensureMigrated()
        setEntry(haiku, ["google-vertex"])
        let otherOnly = SubagentModelLanes.hostPinBypass()
        setEntry(glm, ["together"])
        let current = SubagentModelLanes.hostPinBypass()
        try? KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openAICompatible.rawValue)
        let otherProvider = SubagentModelLanes.hostPinBypass()
        check("N lanes bypass only with a non-empty pin on the CURRENT model", !otherOnly && current && !otherProvider)
    }

    // MARK: R. removal

    func removal() {
        reset(orStore(model: glm, active: false, extra: [PM.legacyKey: "novita", PM.corruptBackupKey: "{x",
                                                         ProviderProfiles.activeProfileKey: "opencode", KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue]))
        setEntry(haiku, ["google-vertex"])
        try? KeychainHelper.save(key: PM.legacyKey, value: "Bad Slug")  // not migratable: only the removal clears it
        let sem = DispatchSemaphore(value: 0)
        var res: [String: Any] = [:]
        Task.detached { res = await SetupAPICore.apply(["provider": ["profile": "openrouter", "remove": true]]); sem.signal() }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let s = snap()
        check("R profile removal clears the per-model map, the legacy pin and the backup",
              res["ok"] as? Bool == true && s[PM.storageKey] == nil && s[PM.legacyKey] == nil && s[PM.corruptBackupKey] == nil, "\(res) \(s)")
    }

    // MARK: U. upgrade pass

    func upgradePass() async {
        func pass(idle: Bool = true, fetch: @escaping OpenRouterUpgradePass.Fetch) -> (OpenRouterUpgradePass, () -> Int) {
            var commits = 0
            let p = OpenRouterUpgradePass(isIdle: { idle }, onCommitted: { _ in commits += 1 }, fetch: fetch)
            return (p, { commits })
        }
        let together: OpenRouterUpgradePass.Fetch = { _, _ in [self.ep("together"), self.ep("novita/fp8")] }
        func upgradeStore() { reset(orStore(model: dflt)); PM.ensureMigrated() }

        upgradeStore()
        var (p, commits) = pass(fetch: together)
        var r = await p.attemptOnce()
        check("U1 the current preset model gets its host once; marker gone; one commit notice",
              r == .pinned(model: dflt, slug: "together") && entry(dflt)?.by == .preset && map()?.upgrade == nil && commits() == 1 && Pin.pinnedSlugs() == ["together"])
        upgradeStore()
        var w = KeychainHelper._testWriteCount
        (p, commits) = pass(fetch: { _, _ in throw Pin.FetchError(description: "HTTP 503") })
        r = await p.attemptOnce()
        check("U2 a failed listing keeps the marker, no write", { if case .retry = r { return true }; return false }() && map()?.upgrade != nil && KeychainHelper._testWriteCount == w)
        (p, commits) = pass(fetch: together)
        r = await p.attemptOnce()
        check("U2 the next attempt pins", r == .pinned(model: dflt, slug: "together"))
        upgradeStore()
        (p, _) = pass(idle: false, fetch: together)
        r = await p.attemptOnce()
        let busy = r
        (p, _) = pass(fetch: { _, _ in throw CancellationError() })
        r = await p.attemptOnce()
        check("U3 a running turn or a cancelled listing defers (marker kept, no pin)",
              { if case .retry = busy { return true }; return false }() && { if case .retry = r { return true }; return false }() && map()?.upgrade != nil && entry(dflt) == nil)
        upgradeStore()
        _ = host(dflt, .automatic)
        (p, commits) = pass(fetch: together)
        w = KeychainHelper._testWriteCount
        r = await p.attemptOnce()
        check("U4 an explicit choice for the model retires the marker in its own write; the pass then writes nothing",
              r == .nothing && entry(dflt)?.hosts == [] && KeychainHelper._testWriteCount == w && commits() == 0)
        upgradeStore()
        (p, _) = pass(fetch: { _, _ in _ = self.modelChange(self.glm, nil); return [self.ep("together")] })
        r = await p.attemptOnce()
        check("U5 a model switch during the listing: no pin on either model", entry(dflt) == nil && entry(glm) == nil && map()?.upgrade == nil, "\(r)")
        upgradeStore()
        (p, commits) = pass(fetch: { _, _ in [self.ep("novita")] })
        r = await p.attemptOnce()
        check("U6 a host that definitely doesn't serve the model ends the operation without a pin", r == .notServed(model: dflt, host: "Together") && map()?.upgrade == nil && entry(dflt) == nil && commits() == 1)
        upgradeStore()
        let slowGate = DispatchSemaphore(value: 0)
        let slow = OpenRouterUpgradePass(isIdle: { true }, onCommitted: { _ in }, fetch: { _, _ in
            await withCheckedContinuation { c in DispatchQueue.global().async { _ = slowGate.wait(timeout: .now() + 30); c.resume() } }
            return []
        })
        let t0 = Date()
        slow.start()
        let startCost = Date().timeIntervalSince(t0)
        check("U7 start() returns immediately even when the listing blocks", startCost < 0.2 && slow.isRunning, "\(startCost)")
        slow.cancel(); slowGate.signal()
        reset(orStore(model: dflt))
        KeychainHelper._testFailWrites = false
        PM.ensureMigrated()
        let beforeFail = snap()
        KeychainHelper._testFailWrites = true
        (p, _) = pass(fetch: together)
        r = await p.attemptOnce()
        KeychainHelper._testFailWrites = false
        check("U9 a write failure keeps the marker and every byte", { if case .retry = r { return true }; return false }() && snap() == beforeFail)
        reset(orStore(model: dflt, extra: [PM.storageKey: "{bad"]))
        _ = host(dflt, .automatic)
        check("U10 recovery creates no upgrade marker", map()?.upgrade == nil)
        upgradeStore()
        (p, _) = pass(fetch: { _, _ in self.setEntry("v/n", ["x"]); _ = self.host("v/n", .forget); return [self.ep("together")] })
        r = await p.attemptOnce()
        let keptAfterUnrelated = map()?.upgrade != nil && entry(dflt) == nil
        (p, _) = pass(fetch: together)
        let r2 = await p.attemptOnce()
        check("U11 an unrelated map change aborts the attempt and keeps the marker", { if case .retry = r { return true }; return false }() && keptAfterUnrelated && r2 == .pinned(model: dflt, slug: "together"), "\(r) \(r2)")
        reset(orStore(model: dflt, key: false)); PM.ensureMigrated()
        (p, _) = pass(fetch: together)
        r = await p.attemptOnce()
        let noKey = map()?.upgrade != nil
        try? KeychainHelper.save(key: KeychainHelper.openRouterApiKeyKey, value: "sk-or-later")
        let r12 = await p.attemptOnce()
        check("U12 a stored preset model without a key keeps the marker; adding the key lets a later attempt pin", noKey && { if case .retry = r { return true }; return false }() && r12 == .pinned(model: dflt, slug: "together"))
        upgradeStore()
        (p, _) = pass(fetch: { _, _ in try? KeychainHelper.save(key: ProviderProfiles.activeProfileKey, value: "opencode"); return [self.ep("together")] })
        r = await p.attemptOnce()
        check("U13 an active-profile change during the listing defers without losing the marker", { if case .retry = r { return true }; return false }() && map()?.upgrade != nil && entry(dflt) == nil)
        upgradeStore()
        let snapshotBasis = basis()
        let workerA = OpenRouterUpgradePass(isIdle: { true }, onCommitted: { _ in }, fetch: together)
        var notices = 0
        let workerB = OpenRouterUpgradePass(isIdle: { true }, onCommitted: { _ in notices += 1 }, fetch: together)
        _ = await workerA.attemptOnce()
        w = KeychainHelper._testWriteCount
        let late = (try? Pin.commitUpgradeAttempt(model: dflt, listing: listing(dflt, ["together"]), expected: snapshotBasis, now: now)) ?? .retry("x")
        let rb = await workerB.attemptOnce()
        check("U14 two workers: one pin transition, no clobber, no extra revision or notice",
              late == .nothing && rb == .nothing && KeychainHelper._testWriteCount == w && notices == 0 && entry(dflt)?.by == .preset)
        upgradeStore()
        (p, _) = pass(fetch: { _, _ in _ = self.modelChange(self.glm, nil); _ = self.modelChange(self.dflt, nil); return [self.ep("together")] })
        r = await p.attemptOnce()
        check("U15 A→B→A during the listing retires the operation; nothing revived", map()?.upgrade == nil && { if case .pinned = r { return false }; return true }(), "\(r)")
        upgradeStore()
        (p, _) = pass(fetch: { _, _ in try? KeychainHelper.delete(key: PM.storageKey); return [self.ep("together")] })
        r = await p.attemptOnce()
        check("U16 a stale worker never recreates a removed map", snap()[PM.storageKey] == nil, "\(r)")
        upgradeStore()
        (p, _) = pass(fetch: { _, _ in try? KeychainHelper.save(key: PM.legacyKey, value: "deepinfra"); return [self.ep("together"), self.ep("deepinfra")] })
        r = await p.attemptOnce()
        let untouched = entry(dflt) == nil && map()?.upgrade != nil
        (p, _) = pass(fetch: together)
        let after = await p.attemptOnce()
        check("U17 a legacy pin arriving during the listing is never overwritten by the preset",
              untouched && { if case .retry = r { return true }; return false }()
              && entry(dflt)?.hosts == ["deepinfra"] && map()?.upgrade == nil && after == .nothing, "\(r) \(after) \(snap())")
        upgradeStore()
        try? KeychainHelper.save(key: PM.legacyKey, value: "Bad Slug")
        (p, _) = pass(fetch: together)
        r = await p.attemptOnce()
        check("U17 an m3 legacy pin pending: the pass never pins", { if case .retry = r { return true }; return false }() && entry(dflt) == nil)
        upgradeStore()
        (p, _) = pass(fetch: { _, _ in [self.ep("together/priority", .value("priority"))] })
        r = await p.attemptOnce()
        check("U18 uncertain eligibility keeps the marker (never 'not served')", { if case .retry = r { return true }; return false }() && map()?.upgrade != nil)
        // U19: contention never blocks.
        upgradeStore()
        let holder = Thread { KeychainHelper._testHoldInProcessLock(seconds: 1.0) }
        holder.start()
        Thread.sleep(forTimeInterval: 0.1)
        var t = Date()
        let snapBusy = KeychainHelper.tryLoadSnapshot()
        let txBusy = (try? KeychainHelper.tryTransaction { $0["x"] = "y" }) ?? .wrote
        (p, _) = pass(fetch: together)
        let rBusy = await p.attemptOnce()
        let inProcCost = Date().timeIntervalSince(t)
        Thread.sleep(forTimeInterval: 1.0)
        let lockPath = StoragePaths.configRoot.appendingPathComponent("secrets.lock").path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'a'); fcntl.flock(f, fcntl.LOCK_EX); print('L', flush=True); time.sleep(2)", lockPath]
        let out = Pipe(); proc.standardOutput = out
        try? proc.run()
        _ = out.fileHandleForReading.availableData  // wait for "L"
        t = Date()
        let crossBusy = (try? KeychainHelper.tryTransaction { $0["x"] = "y" }) ?? .wrote
        let rCross = await p.attemptOnce()
        let crossCost = Date().timeIntervalSince(t)
        proc.waitUntilExit()
        check("U19 contention (in-process lock, cross-process flock) returns busy at once, never waits",
              snapBusy == nil && txBusy == .busy && { if case .retry = rBusy { return true }; return false }() && inProcCost < 0.3
              && crossBusy == .busy && { if case .retry = rCross { return true }; return false }() && crossCost < 0.3 && entry(dflt) == nil,
              "\(String(describing: snapBusy)) \(txBusy) \(rBusy) \(inProcCost) \(crossBusy) \(rCross) \(crossCost)")
    }
}
