import Foundation

/// Stage D: the sign-in flow every surface uses (SIWC plan §2.1, §3.2,
/// §3.4, §3.4.1, §3.9 save-then-activate). Exchange answered in process (its
/// JWT path is stage A); the writer is a real `SettingsWriter`.
extension SIWCSelftest {
    @MainActor
    static func flowFixture(_ owner: FakeSettingsOwner, fake: FakeAuth, exchanged: @escaping (String, String) -> Void = { _, _ in },
                            tokens t: @escaping () -> SIWCTokens? = { tokens("flow") }, sub: String = "sub-flow") -> SIWCFlow {
        let writer = SettingsWriter(host: owner)
        let flow = SIWCFlow()
        flow.startListener = false
        flow.pollNanos = 20_000_000
        flow.makeSignIn = { SIWCSignIn(store: SIWCStore.resolved(), auth: fake.client, hostPaths: .live, ownerLease: { nil }) }
        flow.writer = SIWCWriterAccess(run: { body in await body(writer); return nil })
        flow.commitActivation = { await writer.commit($0) }
        flow.exchange = { _, attempt, code, clientId in
            exchanged(code, clientId)
            return SIWCSignInResult(clientId: clientId, newRegistration: attempt.newRegistration, tokens: t(), claims: claims(sub: sub))
        }
        return flow
    }

    /// The address the browser ends on (iPhone form: no scheme). A new
    /// registration's callback carries the issued client (P1/P5).
    static func callbackURL(_ status: SIWCFlow.Status, code: String = "CODE-1", extra: String = "", issued: String = "oaiappFlowIssued") -> String {
        let q = URLComponents(string: status.url ?? "")?.queryItems ?? []
        let redirect = q.first { $0.name == "redirect_uri" }?.value ?? ""
        let state = q.first { $0.name == "state" }?.value ?? ""
        let client = q.first { $0.name == "client_id" }?.value == SIWCEndpoint.dynamicClient ? "&client_id=\(issued)" : ""
        return redirect.replacingOccurrences(of: "http://", with: "") + "?code=\(code)&state=\(state)" + client + extra
    }

    static func query(_ url: String?) -> [String: String] {
        Dictionary(((URLComponents(string: url ?? "")?.queryItems) ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    @MainActor
    static func stageDFlowTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        SIWCPlanState.destination = { nil }
        let owner = FakeSettingsOwner()
        let fake = FakeAuth()
        var exchanges: [(String, String)] = []
        let flow = flowFixture(owner, fake: fake, exchanged: { exchanges.append(($0, $1)) })
        let store = SIWCStore.resolved()

        // 1. Start (paste mode): a waiting attempt, a link with no hints.
        let started = await flow.start(mode: .paste)
        let q = query(started.url)
        c.check("flow: start → waiting, a pending marker and a host reservation exist",
                started.state == "waiting" && (try? store.readTokens())?.pendingLogin != nil
                && ((try? SIWCHost.readReservations(.live))?.reservations.count ?? 0) == 1)
        c.check("flow: the link carries the host ID and Briglia's name, never an id_token_hint or login_hint",
                q["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true && q["agent_name_hint"] == "Briglia"
                && q["id_token_hint"] == nil && q["login_hint"] == nil && q["client_id"] == SIWCEndpoint.dynamicClient)
        let dup = await flow.start(mode: .browser)
        c.check("flow: a second start while waiting is refused, the first stays", dup.state == "failed" && flow.isWaiting
                && dup.message == SIWCFlow.alreadyWaitingMessage)

        // 2. Rejected pastes keep the attempt; replies are fixed and never echo.
        let secretish = "SECRET-PASTE-\(UUID().uuidString.prefix(6))"
        let wrongState = callbackURL(started, code: secretish).replacingOccurrences(of: "state=", with: "state=X")
        let r1 = await flow.paste(wrongState)
        let wrongPort = callbackURL(started).replacingOccurrences(of: ":\(q["redirect_uri"].flatMap { URLComponents(string: $0)?.port }.map(String.init) ?? "0")/", with: ":1/")
        let r2 = await flow.paste(wrongPort)
        c.check("flow: a wrong state / wrong port is rejected with a fixed reply, the attempt stays, no exchange",
                r1 == CallbackPaste.Rejection.notThisSignIn.rawValue && r2 == CallbackPaste.Rejection.notSignInAddress.rawValue
                && flow.isWaiting && exchanges.isEmpty)
        c.check("flow: no reply echoes the pasted text", !r1.contains(secretish) && !r2.contains("CODE-1"))

        // 3. Accepted (iPhone form: no scheme): exchange, save, activation.
        let r3 = await flow.paste(callbackURL(started, code: "CODE-OK"))
        let stored = KeychainHelper.loadSnapshot()
        c.check("flow: an accepted paste exchanges exactly once with the code and the issued client",
                exchanges.count == 1 && exchanges[0].0 == "CODE-OK")
        c.check("flow: saved then activated while idle (one step for the user): route siwc, selection bound",
                flow.status.state == "done" && flow.status.outcome == "signed_in" && stored[ChatGPTRoute.routeKey] == "siwc"
                && (try? ChatGPTRoute.currentSource()) != nil, "\(flow.status.json) reply \(r3)")
        c.check("flow: a new registration shows the one-time “You're using your ChatGPT plan” notice", flow.status.firstUse)
        c.check("flow: the pending marker and reservation are gone", (try? store.readTokens())?.pendingLogin == nil
                && ((try? SIWCHost.readReservations(.live))?.reservations.isEmpty ?? true))
        c.check("flow: the activation went through the D barrier", owner.barriersTaken >= 1)
        let pendingDoc = (try? String(contentsOf: SettingsPendingStore.url, encoding: .utf8)) ?? ""
        let secrets = secretsText()
        c.check("flow: neither the code nor a token reaches secrets or settings-pending",
                !pendingDoc.contains("CODE-OK") && !secrets.contains("CODE-OK") && !secrets.contains("synthetic-access") && !pendingDoc.contains("synthetic-"))
        let late = await flow.paste(callbackURL(started, code: "CODE-LATE"))
        c.check("flow: a paste after the sign-in finished is answered “no sign-in is waiting”, no exchange",
                late == CallbackPaste.Rejection.noneWaiting.rawValue && exchanges.count == 1)

        // 4. Returning sign-in reuses the active registration; consent asks again.
        let back = await flow.start(mode: .browser, consent: true)
        let bq = query(back.url)
        c.check("flow: returning sign-in uses the issued client, no agent_name_hint, prompt=consent when enabling plan usage",
                bq["client_id"] == (try? store.readRegistrations())?.active && bq["agent_name_hint"] == nil && bq["prompt"] == "consent")
        // Busy: the re-sign-in is saved as a staged replacement and its activation waits.
        owner.busy = true
        _ = await flow.paste(callbackURL(back, code: "CODE-2"))
        c.check("flow: Briglia busy → saved, “switches when the task finishes” (activation staged)",
                flow.status.outcome == "pending" && (try? SettingsPendingStore.read())?.slots["ai"]?.staged != nil, "\(flow.status.json)")
        owner.busy = false
        _ = await SettingsWriter(host: owner).applyStaged(category: "ai")

        // 5. Callback errors (§2.1 path a): only after state validation.
        for (code, expect) in [("access_denied", SIWCFlow.cancelledInBrowser), ("3p_delegated_access_policy_denied", SIWCFlow.policyDenied),
                               ("weird_secret_code_\(UUID().uuidString.prefix(4))", SIWCFlow.unrecognizedRefusal)] {
            let s = await flow.start(mode: .paste)
            let before = exchanges.count
            let wrong = await flow.paste(callbackURL(s).replacingOccurrences(of: "code=CODE-1", with: "error=\(code)").replacingOccurrences(of: "state=", with: "state=Z"))
            c.check("flow: error=\(code.prefix(12)) with a wrong state is ignored, attempt stays", wrong == CallbackPaste.Rejection.notThisSignIn.rawValue && flow.isWaiting)
            _ = await flow.paste(callbackURL(s).replacingOccurrences(of: "code=CODE-1", with: "error=\(code)&error_description=SECRET-DESC"))
            c.check("flow: error=\(code.prefix(12)) ends the attempt with its fixed message, no exchange, never echoes the code or description",
                    flow.status.state == "failed" && flow.status.message == expect && exchanges.count == before
                    && !(flow.status.message ?? "").contains("SECRET-DESC") && (try? store.readTokens())?.pendingLogin == nil)
        }

        // 6. No callback (§2.1 path b): "sign-in failed in the browser", expiry.
        _ = await flow.start(mode: .browser)
        let failed = await flow.cancel(browserFailed: true)
        c.check("flow: “Sign-in failed in the browser” cancels with the generic help, never a policy claim",
                failed.outcome == "browser_failed" && failed.message == SIWCFlow.browserFailedHelp && !failed.message!.contains("policy (")
                && (try? store.readTokens())?.pendingLogin == nil)
        var now = Int(Date().timeIntervalSince1970)
        flow.clock = { now }
        let exp = await flow.start(mode: .paste)
        now += 601
        try? await Task.sleep(nanoseconds: 120_000_000)
        let afterExpiry = await flow.paste(callbackURL(exp, code: "CODE-EXP"))
        c.check("flow: the 10-minute expiry ends the attempt; a later paste gets “expired”, OpenAI is not contacted",
                flow.status.outcome == "expired" && afterExpiry.hasPrefix(CallbackPaste.Rejection.expired.rawValue)
                && !exchanges.contains { $0.0 == "CODE-EXP" })
        // The paste path enforces the expiry itself (no poll in between).
        flow.pollNanos = 30_000_000_000
        now = Int(Date().timeIntervalSince1970)
        let exp2 = await flow.start(mode: .paste)
        try? await Task.sleep(nanoseconds: 50_000_000)   // the watcher is now asleep
        now += 601
        let pastedLate = await flow.paste(callbackURL(exp2, code: "CODE-EXP2"))
        c.check("flow: a paste after the expiry is refused by the paste path itself (“expired”), no exchange",
                pastedLate.hasPrefix(CallbackPaste.Rejection.expired.rawValue) && flow.status.outcome == "expired"
                && !exchanges.contains { $0.0 == "CODE-EXP2" })
        flow.pollNanos = 20_000_000
        flow.clock = { Int(Date().timeIntervalSince1970) }

        // Cancelled from outside (Mind import / wipe quiescence cancel this
        // process's own attempts): the flow ends, a later paste is inert.
        let ext = await flow.start(mode: .paste)
        await SIWCActivity.shared.cancelOwned()
        let extReply = await flow.paste(callbackURL(ext, code: "CODE-EXT"))
        c.check("flow: an attempt cancelled by quiescence ends the flow; the paste is not exchanged",
                flow.status.state == "cancelled" && flow.status.message == SIWCFlow.cancelledElsewhere
                && extReply == CallbackPaste.Rejection.noneWaiting.rawValue && !exchanges.contains { $0.0 == "CODE-EXT" })

        // 7. Identity only (no plan usage): saved, not activated.
        try resetLive()
        let noPlan = flowFixture(owner, fake: fake, tokens: { nil }, sub: "sub-noplan")
        let s7 = await noPlan.start(mode: .paste)
        _ = await noPlan.paste(callbackURL(s7))
        c.check("flow: a grant without plan usage is saved with plan usage off and nothing is activated",
                noPlan.status.outcome == "plan_usage_off" && KeychainHelper.load(key: ChatGPTRoute.routeKey) == nil
                && (try? SIWCStore.resolved().readTokens())?.records.first?.planUsageOff == true)

        // 8. A writer that can't be reached (a daemon started meanwhile): refused, revoked.
        try resetLive()
        let refused = flowFixture(owner, fake: fake, sub: "sub-refused")
        refused.writer = SIWCWriterAccess(run: { _ in SIWCFlow.ownerChangedMessage })
        let s8 = await refused.start(mode: .paste)
        let revokes0 = fake.revoked.count
        _ = await refused.paste(callbackURL(s8))
        c.check("flow: publication refused → nothing saved, the issued refresh token revoked best effort, marker cleared",
                refused.status.state == "failed" && refused.status.message == SIWCFlow.ownerChangedMessage
                && fake.revoked.count == revokes0 + 1 && (try? SIWCStore.resolved().readTokens())?.records.isEmpty ?? true
                && (try? SIWCStore.resolved().readTokens())?.pendingLogin == nil)

        // 9. Cancel through the writer (S).
        let s9 = await refused.start(mode: .paste)
        let cancelled = await refused.cancel()
        refused.writer = SIWCWriterAccess(run: { body in await body(SettingsWriter(host: owner)); return nil })
        let latePaste = await refused.paste(callbackURL(s9))
        c.check("flow: cancel ends the attempt; a late paste is inert", s9.state == "waiting" && cancelled.state == "cancelled"
                && latePaste == CallbackPaste.Rejection.noneWaiting.rawValue)
    }
}
