import Foundation

/// Stage D, Codex round 1 regressions (R1–R7), each reproducing the review's
/// probe without network: R2 cancellation at the save/exchange/activation
/// boundaries, R4 one recovery send per user turn (through the real adapter),
/// R5 a saved login that is not the active pointer, R6 the flow outcome in
/// the menu data, R7 choosing legacy from the SIWC route. R1 and R3 rows are
/// in the Telegram child (`d-telegram`).
extension SIWCSelftest {
    @MainActor
    static func stageDRound1Tests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        SIWCPlanState.destination = { nil }
        let owner = FakeSettingsOwner()
        let fake = FakeAuth()

        // R2a: cancel while the save completes → the login stays saved, but
        // nothing is activated, and the status says so.
        final class Gate: @unchecked Sendable { var cont: CheckedContinuation<Void, Never>?; var armed = true }
        let gate = Gate()
        let flow = flowFixture(owner, fake: fake, sub: "sub-r2")
        let realWriter = flow.writer
        flow.writer = SIWCWriterAccess(run: { body in
            let r = await realWriter.run(body)
            if gate.armed { gate.armed = false; await withCheckedContinuation { gate.cont = $0 } }
            return r
        })
        let s1 = await flow.start(mode: .paste)
        let pasteTask = Task { @MainActor in await flow.paste(callbackURL(s1, code: "R2-SAVE")) }
        for _ in 0..<200 where gate.cont == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        let cancelled = await flow.cancel()
        let routeAtCancel = KeychainHelper.load(key: ChatGPTRoute.routeKey)
        gate.cont?.resume()
        _ = await pasteTask.value
        c.check("R2: cancelled while the save returned → saved but never activated; the status says so",
                cancelled.state == "cancelled" && routeAtCancel == nil && KeychainHelper.load(key: ChatGPTRoute.routeKey) == nil
                && flow.status.message == SIWCFlow.savedNotSwitchedMessage
                && (try? SIWCStore.resolved().readTokens())?.records.isEmpty == false, "\(flow.status.json)")

        // R2b: cancel while exchanging → nothing saved, the issued token revoked.
        try resetLive()
        let gate2 = Gate()
        let flow2 = flowFixture(owner, fake: fake, sub: "sub-r2b")
        let realExchange = flow2.exchange
        flow2.exchange = { signIn, attempt, code, client in
            let r = try await realExchange(signIn, attempt, code, client)
            await withCheckedContinuation { gate2.cont = $0 }
            return r
        }
        let s2 = await flow2.start(mode: .paste)
        let revokes0 = fake.revoked.count
        let t2 = Task { @MainActor in await flow2.paste(callbackURL(s2, code: "R2-EXCH")) }
        for _ in 0..<200 where gate2.cont == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        _ = await flow2.cancel()
        gate2.cont?.resume()
        _ = await t2.value
        c.check("R2: cancelled during the exchange → nothing saved, no route, the issued refresh token revoked",
                (try? SIWCStore.resolved().readTokens())?.records.isEmpty ?? true && KeychainHelper.load(key: ChatGPTRoute.routeKey) == nil
                && fake.revoked.count == revokes0 + 1)

        // R2c: cancel right before the activation's decision point → refused there.
        try resetLive()
        let flow3 = flowFixture(owner, fake: fake, sub: "sub-r2c")
        let realActivate = flow3.commitActivation
        flow3.commitActivation = { change, stillValid in
            _ = await flow3.cancel()
            return await realActivate(change, stillValid)
        }
        let s3 = await flow3.start(mode: .paste)
        _ = await flow3.paste(callbackURL(s3, code: "R2-ACT"))
        c.check("R2: cancelled at activation admission → the writer's decision point refuses; route unchanged",
                KeychainHelper.load(key: ChatGPTRoute.routeKey) == nil && flow3.status.message == SIWCFlow.savedNotSwitchedMessage, "\(flow3.status.json)")

        // R5: a first identity-only login stays reachable (display, consent, use), also after a restart.
        try resetLive()
        let noPlan = flowFixture(owner, fake: fake, tokens: { nil }, sub: "sub-r5")
        let s5 = await noPlan.start(mode: .paste)
        _ = await noPlan.paste(callbackURL(s5, issued: "oaiappR5"))
        let info5 = SIWCSurface.info()
        let restarted = flowFixture(owner, fake: fake, sub: "sub-r5")   // a new process's flow
        let consent = await restarted.start(mode: .paste, consent: true)
        let cq = query(consent.url)
        c.check("R5: a first identity-only login shows as “no plan usage” (not signed out)", info5.login == "plan_usage_off", info5.login)
        c.check("R5: “Allow plan usage” re-consents the SAVED registration (not a new one), also from a new process",
                cq["client_id"] == "oaiappR5" && cq["prompt"] == "consent" && cq["agent_name_hint"] == nil)
        _ = await restarted.cancel()
        // A saved login whose activation failed: "Use ChatGPT" activates it.
        try resetLive()
        let failing = flowFixture(owner, fake: fake, sub: "sub-r5b")
        failing.commitActivation = { _, _ in .refused("synthetic refusal") }
        let s5b = await failing.start(mode: .paste)
        _ = await failing.paste(callbackURL(s5b, issued: "oaiappR5b"))
        let infoSaved = SIWCSurface.info()
        failing.commitActivation = { await SettingsWriter(host: owner).commit($0, stillValid: $1) }
        let used = await failing.activate(origin: "selftest")
        c.check("R5: a saved login whose activation failed shows as signed in (not in use) and “Use ChatGPT” activates it",
                infoSaved.login == "signed_in" && !infoSaved.selected && used == .success(applied: true)
                && KeychainHelper.load(key: ChatGPTRoute.routeKey) == "siwc")

        try await stageDRound1RetryTests(c)
        try await stageDRound1MenuTests(c, owner: owner, fake: fake)
    }

    /// R4 through the real adapter: one recovery send per user turn.
    @MainActor
    static func stageDRound1RetryTests(_ c: Checks) async throws {
        try resetLive()
        SIWCPlanState.profileForTesting = "default"
        defer { SIWCPlanState.profileForTesting = nil }
        let (source, _) = try await liveSelection(clientId: "oaiappR4", sub: "sub-r4")
        let fp = SIWCEndpoint.registrationFingerprint(clientId: "oaiappR4")
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        ResponsesAdapter.siwcSendOverride = { _ in count.n += 1; throw ResponsesFailure.http(500, 0) }
        let ctx = ProviderExecutionContext.siwcContext(source: source, model: "gpt-6.1-sol", effort: nil, lane: .main, textOnly: false, nativeToolMedia: false)
        func turn() async -> Int {
            let before = count.n
            await Task { @MainActor in
                let job = try? SIWCFence.shared.registerCurrentTask(source, userTurn: true)
                defer { SIWCFence.shared.unregisterJob(job) }
                _ = try? await ResponsesAdapter(context: ctx).send(input: [user("x")], tools: nil, receipt: receipt())
            }.value
            return count.n - before
        }
        // limit_reached: four HTTP 500s would be four sends; only one goes out.
        let t = try SIWCPlanState.admit(source, userTurn: false)
        SIWCPlanState.observe(t, .failure(SIWCError(.limitReached, SIWCError.limitMessage)))
        let limitSends = await turn()
        let nextTurn = await turn()
        c.check("R4: limit_reached → a user turn makes exactly one send, retries included (unclassified 500s)", limitSends == 1, "\(limitSends)")
        c.check("R4: the next user turn gets its own single attempt", nextTurn == 1, "\(nextTurn)")
        // not_available: the allowance is consumed at admission, whatever the failure.
        clearPlanState(source.store)
        let t2 = try SIWCPlanState.admit(source, userTurn: false)
        SIWCPlanState.observe(t2, .failure(SIWCError(.notAvailable, SIWCError.notEligibleMessage)))
        SIWCPlanState.userAction(source.store, clientId: "oaiappR4")
        let naSends = await turn()
        let entry = (try? SIWCPlanState.read(source.store))?.entries[fp]
        let again = await turn()
        c.check("R4: not_available after a user action → one send, the allowance is used up even on an unclassified failure",
                naSends == 1 && entry?.retryAllowed == nil && again == 0, "sends \(naSends) again \(again)")
        ResponsesAdapter.siwcSendOverride = { _ in throw SIWCError(.local, "selftest: network disabled") }
    }

    /// R6 (flow outcome in the menu data) and R7 (legacy from the SIWC route).
    @MainActor
    static func stageDRound1MenuTests(_ c: Checks, owner: FakeSettingsOwner, fake: FakeAuth) async throws {
        try resetLive()
        let world = MenuFakeWorld(toolMarker: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-d-r1-\(UUID().uuidString)"))
        var env = MenuEnvironment()
        env.language = "it"; env.browserLikely = false
        env.snapshot = { await MenuEnvironment.liveSnapshot() }
        env.toolchainStatus = { world.toolchain() }
        env.security = { [:] }
        let wf = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
        wf.siwcFlow = flowFixture(owner, fake: fake, sub: "sub-r6")
        await wf.reload()
        func card() -> [String: Any] { ((wf.status()["chatgpt"] as? [String: Any])?["siwc"] as? [String: Any]) ?? [:] }
        let s6 = await wf.siwcFlow.start(mode: .paste)
        // The listener path: a policy refusal arrives with no page action.
        _ = await wf.siwcFlow.paste(callbackURL(s6).replacingOccurrences(of: "code=CODE-1", with: "error=3p_delegated_access_policy_denied"))
        c.check("R6: a callback refusal reaches the page data as its fixed, translated message (shown after polling)",
                (card()["flow_message"] as? String)?.hasPrefix("ChatGPT ha rifiutato questo accesso per una regola") == true
                && (card()["flow"] as? [String: Any])?["state"] as? String == "failed")
        // R7: a valid SIWC selection, a saved legacy login; choose legacy.
        _ = try await liveSelection(clientId: "oaiappR7", sub: "sub-r7")
        var legacy = SubscriptionAuthState(generation: UUID().uuidString)
        legacy.credential = SubscriptionCredential(access: "synthetic-legacy-access-r7", refresh: "synthetic-legacy-refresh-r7",
                                                   expires: Date().addingTimeInterval(86_400), account: "acct-r7", residency: nil)
        try SubscriptionAuthStore().write(legacy)
        let chose = await wf.handle(["action": "siwc_method", "route": "legacy"])
        c.check("R7: choosing legacy on the SIWC route is accepted and changes nothing yet",
                chose?["ok"] as? Bool == true && KeychainHelper.load(key: ChatGPTRoute.routeKey) == "siwc")
        let switched = await wf.handle(["action": "siwc_switch_legacy"])
        let after = KeychainHelper.loadSnapshot()
        c.check("R7: “Switch to the legacy sign-in” selects legacy explicitly (SIWC keys removed, opt-in cleared)",
                switched?["ok"] as? Bool == true && ChatGPTRoute.resolve(stored: after) == .legacy
                && after[ChatGPTRoute.siwcRegistrationKey] == nil && after[SIWCSurface.optInKey] == nil, "\(switched ?? [:])")
    }
}
