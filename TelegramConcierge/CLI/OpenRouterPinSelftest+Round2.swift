import Foundation

/// Codex implementation review of ac26cd4 (2026-10-18): each reproduced
/// finding as a permanent check through the PUBLIC surfaces (real
/// `SetupAPICore.apply`, the real store, the real `MenuWorkflow`, the real
/// upgrade worker). These checks fail on ac26cd4 and pass after the fix.
/// Checks that need the new helper signatures live in `+Round2New.swift`.
@MainActor
extension ORPinSuite {

    func endpointsJSON(_ tags: [String]) -> Data {
        let list = tags.map { ["tag": $0, "provider_name": $0] }
        return (try? JSONSerialization.data(withJSONObject: ["data": ["endpoints": list]])) ?? Data()
    }

    func reviewRound2() async {
        await r2SetupAPIOlderListing()
        await r2MenuSettingsBasis()
        await r2UpgradeMigrationRetry()
        await r2Cancellation()
        await r2ActiveVision()
        await r2Notes()
        await reviewRound2NewAPI()
        Pin.fetchOverride = nil
    }

    // MARK: Finding 1: an older listing never releases a newer choice (non-menu saves)

    func r2SetupAPIOlderListing() async {
        // Codex's interleaving: setup-api looks up B's hosts; meanwhile a
        // second writer pins B to deepinfra (a newer explicit choice); the
        // older listing (google-vertex only) must not release it.
        func seed() {
            reset(orStore(model: dflt))
            PM.ensureMigrated()
            setEntry(haiku, ["google-vertex"], by: .user)
        }
        seed()
        Pin.fetchOverride = { _, _ in
            _ = try? Pin.commitHostChoice(model: self.haiku, choice: .pin(["deepinfra"]), listing: nil, expected: self.basis(), now: self.now)
            return self.endpointsJSON(["google-vertex"])
        }
        var r = await SetupAPICore.apply(["provider": ["profile": "openrouter", "model": haiku, "preset_host_pin": true]])
        Pin.fetchOverride = nil
        check("V1 setup-api: an older listing never releases a newer user pin",
              entry(haiku)?.hosts == ["deepinfra"] && entry(haiku)?.by == .user
              && (r["openrouter_host_pin"] as? [String: Any])?["result"] as? String != "released", "\(r) \(String(describing: entry(haiku)))")

        // A caller-supplied listing (browser settings, Quick Setup) carries
        // the basis it was read against; an unknown basis is never trusted.
        seed()
        let before = basis()
        _ = host(haiku, .pin(["deepinfra"]))
        r = await SetupAPICore.apply(["provider": ["profile": "openrouter", "model": haiku, "preset_host_pin": true,
                                                   "host_listing": ["model": haiku, "hosts": ["google-vertex"]],
                                                   "listing_basis": SetupAPICore.basisJSON(before)] as [String: Any]])
        let withBasis = entry(haiku)?.hosts == ["deepinfra"] && r["ok"] as? Bool == true
        seed()
        _ = host(haiku, .pin(["deepinfra"]))
        r = await SetupAPICore.apply(["provider": ["profile": "openrouter", "model": haiku, "preset_host_pin": true,
                                                   "host_listing": ["model": haiku, "hosts": ["google-vertex"]]] as [String: Any]])
        check("V1 setup-api: a supplied older listing (with its basis, or with none) never releases a newer user pin",
              withBasis && entry(haiku)?.hosts == ["deepinfra"], "\(r) \(String(describing: entry(haiku)))")

        // A source change during the lookup refuses the save.
        seed()
        Pin.fetchOverride = { _, _ in
            _ = try? Pin.commitModelChange(destination: self.glm, textOnly: false, listing: nil, expected: self.basis(), now: self.now)
            return self.endpointsJSON(["google-vertex"])
        }
        r = await SetupAPICore.apply(["provider": ["profile": "openrouter", "model": haiku, "preset_host_pin": true]])
        Pin.fetchOverride = nil
        check("V1 setup-api: a model switched during the lookup refuses the save (nothing overwritten)",
              r["ok"] as? Bool == false && (r["error"] as? [String: Any])?["code"] as? String == "stale"
              && snap()[KeychainHelper.openRouterModelKey] == glm, "\(r)")

        // Unchanged basis: the fresh listing still releases / pins normally.
        seed()
        Pin.fetchOverride = { _, _ in self.endpointsJSON(["novita"]) }
        r = await SetupAPICore.apply(["provider": ["profile": "openrouter", "model": haiku, "preset_host_pin": true]])
        Pin.fetchOverride = nil
        check("V1 setup-api control: an unchanged basis still releases a pin the host list doesn't serve",
              entry(haiku)?.by == .released && (r["openrouter_host_pin"] as? [String: Any])?["result"] as? String == "released", "\(r)")
    }

    // MARK: Finding 2: the menu's full settings basis is enforced in the transaction

    func realMenuSnapshot(_ base: MenuSnapshot) -> MenuSnapshot {
        let st = KeychainHelper.loadSnapshot()
        var s = base
        s.activeProfile = st[ProviderProfiles.activeProfileKey]
        var p = MenuSnapshot.Provider(configured: true, model: st[KeychainHelper.openRouterModelKey] ?? "",
                                      effort: st[KeychainHelper.openRouterReasoningEffortKey] ?? "", keyMasked: "sk-or…ture")
        p.textOnly = st[ProviderProfiles.openrouterTextOnlyKey] == "true"
        s.providers["openrouter"] = p
        s.orStore = MenuSnapshot.orStore(from: st)
        return s
    }

    func r2MenuSettingsBasis() async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("or-pin-menu-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ctx = MenuSelftestContext(tempRoot: tmp)
        for (label, concurrent, survives) in [
            ("effort", [KeychainHelper.openRouterReasoningEffortKey: "max"], { (s: [String: String]) in s[KeychainHelper.openRouterReasoningEffortKey] == "max" }),
            ("text_only", [ProviderProfiles.openrouterTextOnlyKey: "true", KeychainHelper.textOnlyModelEnabledKey: "true"],
             { (s: [String: String]) in s[ProviderProfiles.openrouterTextOnlyKey] == "true" && s[KeychainHelper.textOnlyModelEnabledKey] == "true" }),
        ] {
            reset(orStore(model: dflt, extra: [KeychainHelper.openRouterReasoningEffortKey: "high",
                                               ProviderProfiles.openrouterTextOnlyKey: "false", KeychainHelper.textOnlyModelEnabledKey: "false"]))
            PM.ensureMigrated()
            let w = ctx.world()
            var e = ctx.env(w)
            e.snapshot = { self.realMenuSnapshot(w.snap) }
            e.openRouterHosts = { _, _ in .success([self.ep("google-vertex")]) }
            e.providerKey = { _ in w.good["openrouter"] }
            var injected = false
            // After the menu's barrier comparison, before the real setup-api write.
            e.apply = { req, checkpoint in
                if !injected, req["provider"] != nil { injected = true; try? KeychainHelper.saveBatch(concurrent.mapValues { Optional($0) }) }
                return await SetupAPICore.apply(req, ownsLease: true, checkpoint: checkpoint)
            }
            let wf = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
            await wf.start(); await wf.settle()
            let r = await ctx.act(wf, ["action": "provider_model", "profile": "openrouter", "model": haiku])
            let s = snap()
            check("V2 menu: a concurrent \(label) edit after the barrier is refused, never overwritten",
                  injected && r["ok"] as? Bool != true && survives(s) && s[KeychainHelper.openRouterModelKey] == dflt,
                  "\(r["ok"] ?? "nil") \(r["message"] ?? "") \(s.filter { $0.key.contains("effort") || $0.key.contains("text_only") || $0.key == KeychainHelper.openRouterModelKey })")
        }
        // Control: no concurrent edit, the same menu action saves.
        reset(orStore(model: dflt, extra: [KeychainHelper.openRouterReasoningEffortKey: "high", ProviderProfiles.openrouterTextOnlyKey: "false"]))
        PM.ensureMigrated()
        let w = ctx.world()
        var e = ctx.env(w)
        e.snapshot = { self.realMenuSnapshot(w.snap) }
        e.openRouterHosts = { _, _ in .success([self.ep("google-vertex")]) }
        e.providerKey = { _ in w.good["openrouter"] }
        e.apply = { req, checkpoint in await SetupAPICore.apply(req, ownsLease: true, checkpoint: checkpoint) }
        let wf = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
        await wf.start(); await wf.settle()
        let r = await ctx.act(wf, ["action": "provider_model", "profile": "openrouter", "model": haiku])
        check("V2 menu control: with nothing changed meanwhile the real save goes through (model + preset host)",
              r["ok"] as? Bool == true && snap()[KeychainHelper.openRouterModelKey] == haiku && entry(haiku)?.hosts == ["google-vertex"], "\(r["message"] ?? "")")
    }

    // MARK: Finding 3: D10 retries a deferred migration and settles a late legacy pin

    func r2UpgradeMigrationRetry() async {
        let together: OpenRouterUpgradePass.Fetch = { _, _ in [self.ep("together")] }
        // Startup migration deferred by a held lock (Codex's sequence).
        reset(orStore(model: dflt))
        let holder = Thread { KeychainHelper._testHoldInProcessLock(seconds: 0.4) }
        holder.start()
        Thread.sleep(forTimeInterval: 0.1)
        let startup = PM.ensureMigrated()
        Thread.sleep(forTimeInterval: 0.45)
        let p = OpenRouterUpgradePass(isIdle: { true }, onCommitted: { _ in }, fetch: together)
        let r = await p.attemptOnce()
        check("V3 a startup migration deferred by a busy lock is retried by the pass, which then pins",
              startup == .busy && r == .pinned(model: dflt, slug: "together") && entry(dflt)?.by == .preset && map()?.upgrade == nil,
              "\(String(describing: startup)) \(r) \(snap())")

        // The running loop keeps retrying while the lock stays busy.
        reset(orStore(model: dflt))
        let holder2 = Thread { KeychainHelper._testHoldInProcessLock(seconds: 0.5) }
        holder2.start()
        Thread.sleep(forTimeInterval: 0.1)
        _ = PM.ensureMigrated()
        let loop = OpenRouterUpgradePass(isIdle: { true }, onCommitted: { _ in }, fetch: together)
        loop.firstRetryDelay = 0.2
        loop.maxRetryDelay = 0.2
        loop.start()
        let deadline = Date().addingTimeInterval(5)
        while loop.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        check("V3 the worker loop retries a deferred migration instead of finishing with nothing",
              !loop.isRunning && entry(dflt)?.hosts == ["together"] && loop.attempts >= 2, "\(loop.attempts) \(snap())")

        // A legacy pin arriving after the marker settles through the pass
        // itself (no helper migration): m1 writes the entry, clears the marker.
        reset(orStore(model: dflt)); PM.ensureMigrated()
        try? KeychainHelper.save(key: PM.legacyKey, value: "deepinfra")
        let q = OpenRouterUpgradePass(isIdle: { true }, onCommitted: { _ in }, fetch: together)
        let a1 = await q.attemptOnce()
        let a2 = await q.attemptOnce()
        check("V3 a late legacy pin is settled by the pass (m1 entry, marker cleared, never overwritten)",
              entry(dflt)?.hosts == ["deepinfra"] && map()?.upgrade == nil && snap()[PM.legacyKey] == nil && a2 == .nothing,
              "\(a1) \(a2) \(snap())")

        // Settling waits for idle: a running turn writes nothing.
        reset(orStore(model: dflt))
        let busyBytes = snap()
        let idleRefused = OpenRouterUpgradePass(isIdle: { false }, onCommitted: { _ in }, fetch: together)
        let rr = await idleRefused.attemptOnce()
        check("V3 a deferred migration waits for idle (no write during a turn)",
              { if case .retry = rr { return true }; return false }() && snap() == busyBytes, "\(rr)")
    }

    // MARK: Finding 4: cancellation never commits

    func r2Cancellation() async {
        reset(orStore(model: dflt, extra: [KeychainHelper.openRouterReasoningEffortKey: "high"]))
        PM.ensureMigrated()
        let before = snap()
        let model = dflt
        let result = await Task { () -> [String: Any] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await SetupAPICore.apply(["provider": ["profile": "openrouter", "model": model, "effort": "max",
                                                          "host_listing": ["skip": true]] as [String: Any]])
        }.value
        check("V4 setup-api: an already-cancelled same-model save writes nothing",
              result["ok"] as? Bool != true && snap() == before, "\(result) \(snap()[KeychainHelper.openRouterReasoningEffortKey] ?? "nil")")

        // Cancelled after a supplied listing, before the commit.
        let haikuID = haiku
        let r2 = await Task { () -> [String: Any] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await SetupAPICore.apply(["provider": ["profile": "openrouter", "model": haikuID, "preset_host_pin": true,
                                                          "host_listing": ["model": haikuID, "hosts": ["google-vertex"]]] as [String: Any]])
        }.value
        check("V4 setup-api: a cancelled model change with a supplied listing writes nothing",
              r2["ok"] as? Bool != true && snap() == before, "\(r2)")

        // The /model commit itself refuses on a cancelled task.
        let expected = basis()
        let committed: Bool = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return (try? Pin.commitModelChange(destination: haikuID, textOnly: false, listing: nil, expected: expected)) != nil
        }.value
        check("V4 commitModelChange on a cancelled task writes nothing", !committed && snap() == before)
    }

    // MARK: Finding 5: an active profile's runtime vision follows the save

    func r2ActiveVision() async {
        for (from, to) in [("false", true), ("true", false)] {
            reset(orStore(model: dflt, extra: [ProviderProfiles.openrouterTextOnlyKey: from, KeychainHelper.textOnlyModelEnabledKey: from]))
            PM.ensureMigrated()
            let r = await SetupAPICore.apply(["provider": ["profile": "openrouter", "model": dflt, "text_only": to, "activate": false,
                                                           "host_listing": ["skip": true]] as [String: Any]])
            let s = snap()
            check("V5 active OpenRouter, activate:false, text_only \(to): both vision slots agree",
                  r["ok"] as? Bool == true && s[ProviderProfiles.openrouterTextOnlyKey] == String(to) && s[KeychainHelper.textOnlyModelEnabledKey] == String(to),
                  "\(r) \(s)")
        }
        // Inactive profile: the runtime slot belongs to the running provider.
        reset(orStore(model: dflt, active: false, extra: [ProviderProfiles.activeProfileKey: "opencode",
                                                          KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
                                                          KeychainHelper.textOnlyModelEnabledKey: "false"]))
        let r = await SetupAPICore.apply(["provider": ["profile": "openrouter", "model": dflt, "text_only": true, "activate": false,
                                                       "host_listing": ["skip": true]] as [String: Any]])
        check("V5 control: an inactive OpenRouter edit leaves the running provider's vision slot alone",
              r["ok"] as? Bool == true && snap()[KeychainHelper.textOnlyModelEnabledKey] == "false" && snap()[ProviderProfiles.openrouterTextOnlyKey] == "true", "\(r)")
    }

    // MARK: Non-blocking notes

    func r2Notes() async {
        reset(orStore(model: dflt)); PM.ensureMigrated()
        _ = modelChange(haiku, failed(haiku))
        let status = OpenRouterPresets.hostStatus(model: haiku, store: snap())
        check("V6 a failed auto-pin on the model in use shows as not applied",
              entry(haiku) == nil && status.state == .autoUnavailable && !OpenRouterPresets.hostClause(status).contains("pinned automatically"),
              "\(status.state) \(OpenRouterPresets.hostClause(status))")
        let other = OpenRouterPresets.hostStatus(model: glm, store: snap())
        check("V6 control: a preset not in use still says its host is pinned when picked", other.state == .autoWillPin)

        reset(orStore(model: dflt)); PM.ensureMigrated()
        let before = snap()
        let r = await SetupAPICore.apply(["provider": ["profile": "openrouter", "model": "bad model", "host_listing": ["skip": true]] as [String: Any]])
        check("V7 setup-api refuses an invalid OpenRouter model id before any write", r["ok"] as? Bool == false && snap() == before, "\(r)")
    }
}
