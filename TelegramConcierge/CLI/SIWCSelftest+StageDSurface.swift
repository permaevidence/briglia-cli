import Foundation

/// Stage D: what the surfaces show and accept (SIWC plan §3.10, §5, D2):
/// /status lines, the invitation, doctor, setup-api `siwc_*`, the menu card,
/// the interceptor's recognizer, and the `/model` mirror on the SIWC route.
extension SIWCSelftest {
    @MainActor
    static func stageDSurfaceTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        SIWCPlanState.destination = { nil }
        // Invitation (D2): legacy ChatGPT users who opted in only.
        var s: [String: String] = [ProviderProfiles.activeProfileKey: "chatgpt"]
        c.check("invitation: legacy ChatGPT without the opt-in → none (opt-in release)", SIWCSurface.invitation(s) == nil)
        s[SIWCSurface.optInKey] = "1"
        c.check("invitation: legacy ChatGPT, opted in → “Use your ChatGPT plan in this app · Continue with ChatGPT”",
                SIWCSurface.invitation(s) == SIWCSurface.invitationText)
        s[ProviderProfiles.activeProfileKey] = "openrouter"
        c.check("invitation: never for another provider", SIWCSurface.invitation(s) == nil)

        // A live SIWC selection.
        let (source, _) = try await liveSelection(clientId: "oaiappSurfA", sub: "sub-surf-A")
        let lines = SIWCSurface.statusLines()
        c.check("status: route label and “Using ChatGPT plan · Manage usage”",
                lines.contains { $0.contains("ChatGPT (Sign in with ChatGPT) — signed in") } && lines.contains { $0.hasPrefix("Using ChatGPT plan · Manage usage") },
                lines.joined(separator: " | "))
        try await source.store.requireLogin("oaiappSurfA", generation: source.generation)
        c.check("status: a dead login says “sign in again”", SIWCSurface.statusLines().contains { $0.contains("sign in again") })
        // setup-api status fields.
        let fields = SIWCSetupAPI.statusFields()
        c.check("setup-api status: chatgpt_route and chatgpt_plan_state from the same saved state",
                fields["chatgpt_route"] as? String == "siwc" && fields["chatgpt_plan_state"] as? String == "sign_in_required")

        // Doctor: integrity status, host consistency, never a token, the host ID or an email.
        let doctor = SIWCSurface.doctorLines()
        let hostId: String? = { if case .present(let id) = SIWCHost.readHost(.live) { return id }; return nil }()
        let text = doctor.map { $0.text + ($0.hint ?? "") }.joined(separator: "\n")
        c.check("doctor: the active login is reported as sign-in required (a problem); the host ID is consistent",
                doctor.contains { $0.problem && $0.text.contains("active login: sign-in required") }
                && doctor.contains { !$0.problem && $0.text.contains("consistent") }, text)
        c.check("doctor: no token, host ID or email in any line", !text.contains("synthetic-") && !text.contains("@example.invalid")
                && !(hostId.map { text.contains($0) } ?? true))
        chmod(source.store.tokenFile.path, 0o644)
        c.check("doctor: a token file that isn't owner-only is a problem", SIWCSurface.doctorLines().contains { $0.problem && $0.text.contains("not an owner-only file") })
        chmod(source.store.tokenFile.path, 0o600)

        // /model and /effort on the SIWC route keep the SIWC keys (never the
        // legacy model key an older binary would act on).
        try resetLive()
        _ = try await liveSelection(clientId: "oaiappSurfB", sub: "sub-surf-B")
        ProviderProfiles.recordModelChange("gpt-6-luna", textOnly: true)
        ProviderProfiles.recordEffortChange("medium")
        let after = KeychainHelper.loadSnapshot()
        c.check("model: /model and /effort on the SIWC route write the SIWC keys only; the route stays resolvable",
                after[ChatGPTRoute.siwcModelKey] == "gpt-6-luna" && after[ChatGPTRoute.siwcEffortKey] == "medium"
                && after[ProviderProfiles.subscriptionModelKey] == nil && after[ProviderProfiles.subscriptionEffortKey] == nil
                && { if case .siwc = ChatGPTRoute.resolve(stored: after) { return true }; return false }())

        // The interceptor's recognizer catches every accepted paste form.
        let forms = ["http://127.0.0.1:62602/auth/callback?code=C&state=S", "127.0.0.1:62602/auth/callback?code=C&state=S",
                     "?code=C&state=S", "code=C&state=S", "/auth/callback?code=C&state=S", "<http://localhost:1/auth/callback?error=x&state=S>",
                     "[::1]:62602/auth/callback?code=C&state=S", "HTTP://LOCALHOST:62602/auth/callback?code=C&state=S", "state=S&code=C",
                     "…?c%6Fde=C&state=S".replacingOccurrences(of: "…", with: "127.0.0.1:1/auth/callback")]
        c.check("interceptor: every accepted paste form is recognised (held back before persistence)", forms.allSatisfy(CallbackPaste.looksLikeCallback))
        c.check("interceptor: ordinary messages are not", !CallbackPaste.looksLikeCallback("Can you check the code in auth.swift?")
                && !CallbackPaste.looksLikeCallback("ciao, come va?"))

        try await stageDSetupAPITests(c)
        try await stageDMenuTests(c)
    }

    @MainActor
    static func stageDSetupAPITests(_ c: Checks) async throws {
        try resetLive()
        // Forwarded to a running owner: the reply is the owner's; the pasted
        // text is only inside the request.
        var forwarded: [[String: Any]] = []
        let paste = "127.0.0.1:1/auth/callback?code=SETUPAPI-SECRET&state=S"
        let reply = await SIWCSetupAPI.perform(["action": "siwc_paste", "text": paste], forward: { body in
            forwarded.append(body)
            return .reply(["state": "waiting", "reply": CallbackPaste.Rejection.notThisSignIn.rawValue])
        })
        let replyText = String(data: try JSONSerialization.data(withJSONObject: reply), encoding: .utf8) ?? ""
        c.check("setup-api: with a daemon every siwc action is forwarded (it owns the attempt)",
                forwarded.first?["action"] as? String == "paste" && reply["owner"] as? String == "daemon")
        c.check("setup-api: siwc_paste's text never appears in the answer", !replyText.contains("SETUPAPI-SECRET"))
        for action in ["siwc_paste", "siwc_status", "siwc_cancel"] {
            let r = await SIWCSetupAPI.perform(["action": action, "text": "x"], forward: { _ in .noOwner })
            c.check("setup-api: \(action) with no daemon → no_owner", (r["error"] as? [String: Any])?["code"] as? String == "no_owner")
        }
        let noWait = await SIWCSetupAPI.perform(["action": "siwc_start"], forward: { _ in .noOwner })
        c.check("setup-api: siwc_start with no daemon and no wait → no_owner", (noWait["error"] as? [String: Any])?["code"] as? String == "no_owner")
        // Wait mode: this process owns the attempt; one progress event first.
        let owner = FakeSettingsOwner()
        let flow = flowFixture(owner, fake: FakeAuth(), sub: "sub-setupapi")
        var events: [String] = []
        SIWCSetupAPI.progressForTesting = { events.append($0) }
        defer { SIWCSetupAPI.progressForTesting = nil }
        let task = Task { @MainActor in await SIWCSetupAPI.perform(["action": "siwc_start", "wait": true, "mode": "paste"], forward: { _ in .noOwner }, flow: flow) }
        var waited = 0
        while events.isEmpty, waited < 100 { try? await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        let event = (try? JSONSerialization.jsonObject(with: Data((events.first ?? "{}").utf8))) as? [String: Any] ?? [:]
        c.check("setup-api wait: one parseable progress event with the link and expiry, before the answer",
                events.count == 1 && event["event"] as? String == "siwc_authorize" && (event["url"] as? String)?.hasPrefix(SIWCEndpoint.authorizeURL) == true
                && event["expires_at"] != nil)
        _ = await flow.paste(callbackURL(flow.status, code: "WAIT-CODE"))
        let final = await task.value
        let finalText = String(data: try JSONSerialization.data(withJSONObject: final), encoding: .utf8) ?? ""
        c.check("setup-api wait: one final answer, signed in, owner = this process, no code in it",
                final["state"] as? String == "done" && final["ok"] as? Bool == true && final["owner"] as? String == "this_process"
                && !finalText.contains("WAIT-CODE"), finalText)
    }

    @MainActor
    static func stageDMenuTests(_ c: Checks) async throws {
        try resetLive()
        let world = MenuFakeWorld(toolMarker: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-d-tool-\(UUID().uuidString)"))
        var env = MenuEnvironment()
        env.language = "en"
        env.browserLikely = false
        env.snapshot = { await MenuEnvironment.liveSnapshot() }
        env.toolchainStatus = { world.toolchain() }
        env.security = { [:] }
        let wf = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
        let owner = FakeSettingsOwner()
        wf.siwcFlow = flowFixture(owner, fake: FakeAuth(), sub: "sub-menu")
        await wf.reload()
        func card() -> [String: Any] { ((wf.status()["chatgpt"] as? [String: Any])?["siwc"] as? [String: Any]) ?? [:] }
        c.check("menu: the card names both methods with the exact labels",
                card()["label"] as? String == "ChatGPT (Sign in with ChatGPT)" && card()["legacy_label"] as? String == "ChatGPT (legacy Codex sign-in)")
        let writes0 = KeychainHelper._testWriteCount
        let chose = await wf.handle(["action": "siwc_method", "route": "siwc"])
        c.check("menu: “Choose sign-in method” → Sign in with ChatGPT records the opt-in only; no route or login changes",
                chose?["ok"] as? Bool == true && card()["opted_in"] as? Bool == true && KeychainHelper.load(key: ChatGPTRoute.routeKey) == nil
                && KeychainHelper._testWriteCount == writes0 + 1)
        let cont = await wf.handle(["action": "siwc_continue"])
        let flow = card()["flow"] as? [String: Any] ?? [:]
        c.check("menu: “Continue with ChatGPT” starts a sign-in (paste-back when no local browser) with its link",
                cont?["ok"] as? Bool == true && flow["state"] as? String == "waiting" && flow["mode"] as? String == "paste"
                && (flow["url"] as? String)?.hasPrefix(SIWCEndpoint.authorizeURL) == true)
        let pasted = await wf.handle(["action": "siwc_paste", "text": callbackURL(wf.siwcFlow.status, code: "MENU-CODE")])
        let after = card()
        c.check("menu: the pasted address finishes the sign-in; the card shows the plan line",
                pasted?["ok"] as? Bool == true && after["login"] as? String == "signed_in" && after["selected"] as? Bool == true
                && (after["plan_text"] as? String)?.hasPrefix("Using ChatGPT plan") == true, "\(after)")
        let modelChange = await wf.handle(["action": "chatgpt_model", "model": "gpt-6-luna"])
        c.check("menu: a model change on the SIWC route stays on the route (SIWC keys, no legacy model key)",
                modelChange?["ok"] as? Bool == true && KeychainHelper.load(key: ChatGPTRoute.siwcModelKey) == "gpt-6-luna"
                && KeychainHelper.load(key: ProviderProfiles.subscriptionModelKey) == nil && KeychainHelper.load(key: ChatGPTRoute.routeKey) == "siwc")
        let payload = String(data: try JSONSerialization.data(withJSONObject: wf.status()), encoding: .utf8) ?? ""
        c.check("menu: the page data carries no token, code, email or host ID", !payload.contains("synthetic-") && !payload.contains("MENU-CODE")
                && !payload.contains("@example.invalid") && !payload.contains("urn:uuid:"))
        let out = await wf.handle(["action": "siwc_logout"])
        c.check("menu: Sign out signs this login out (tombstone durable) and says so", out?["ok"] as? Bool == true
                && card()["login"] as? String == "signed_out", "\(out ?? [:])")
        _ = await wf.handle(["action": "lang", "lang": "it"])
        var entry = SIWCPlanEntry(); entry.state = .limitReached
        c.check("menu: Italian text for the plan banner", wf.planText(entry).hasPrefix("Limite di utilizzo raggiunto"))
    }
}
