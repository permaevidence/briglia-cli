import Foundation

extension SelftestContext {
    func subscriptionWorkflow() async throws {
        var (env, store) = stubEnv()
        let originalProbe = env.probe
        let loginGeneration = UUID().uuidString
        var selected = 0
        env.probe = { request in
            if request["kind"] as? String == "chatgpt" { return ["ok": request["generation"] as? String == loginGeneration] }
            return await originalProbe(request)
        }
        env.subscription = { request, checkpoint in
            do { try checkpoint() } catch { return ["ok": false] }
            if request["action"] as? String == "select" {
                guard request["generation"] as? String == loginGeneration else { return ["ok": false] }
                selected += 1
                store.values[ProviderProfiles.subscriptionModelKey] = "gpt-5.6-luna"
                store.values[ProviderProfiles.subscriptionGenerationKey] = loginGeneration
                store.values[ProviderProfiles.activeProfileKey] = "chatgpt"
                return ["ok": true]
            }
            return ["ok": true, "state": "signed_in", "generation": loginGeneration]
        }
        let (wf, _) = try makeWorkflow(env)
        let g = await wf.generation
        var req = goodRequest()
        req.values[.opencode] = nil
        req.values[.chatgpt] = .subscription(model: "gpt-5.6-luna", effort: "high", generation: loginGeneration)
        let before = try await wf.save(req, generation: g)
        check("subscription cannot save without verification", before.0 == 409 && selected == 0)
        let verified = try await wf.verify(req, generation: g)
        let verifiedPhase = await wf.phase
        check("subscription verifies in place of OpenCode key", verified.0 == 200 && verifiedPhase == .verified)
        var altered = req
        altered.values[.chatgpt] = .subscription(model: "gpt-5.6-sol", effort: "high", generation: loginGeneration)
        let refused = try await wf.save(altered, generation: g)
        check("subscription model edit invalidates verification", refused.0 == 409 && selected == 0)
        _ = try await wf.verify(req, generation: g)
        let saved = try await wf.save(req, generation: g)
        check("subscription selects only after verify and keeps API tools", saved.0 == 200 && selected == 1 && store.applied.contains("openai") && !store.applied.contains("opencode"))
        let status = await wf.status()
        check("subscription enters normal system steps", status["phase"] as? String == "system")
        let lateLogin = try await wf.subscription(["action": "start"], generation: g)
        check("cannot replace login after saving setup", lateLogin.0 == 409)
        // Resume loses lastRequest by design; the stored active profile drives
        // final validation, and a revoked login must prevent completion.
        store.seedConfigured()
        store.values.removeValue(forKey: ProviderProfiles.opencodeApiKeyKey)
        store.values[ProviderProfiles.activeProfileKey] = "chatgpt"
        store.values[ProviderProfiles.subscriptionModelKey] = "gpt-5.6-luna"
        store.values[ProviderProfiles.subscriptionGenerationKey] = loginGeneration
        func complete(_ workflow: QuickSetupWorkflow) async throws {
            let generation = await workflow.generation
            let rows = await workflow.systemRows
            for row in rows {
                _ = try await workflow.systemRun(row: row.id, option: nil, generation: generation)
                for _ in 0..<50 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    if (await workflow.systemRows).first(where: { $0.id == row.id })?.state != "running" { break }
                }
            }
            _ = try await workflow.finish(generation: generation)
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 10_000_000)
                if await workflow.isDone { break }
                if (await workflow.finishSteps).contains(where: { $0.state == "failed" }) { break }
            }
        }
        let (resumed, _) = try makeWorkflow(env, resume: .system)
        try await complete(resumed)
        check("subscription setup resumes without an OpenCode key", await resumed.isDone)
        var expiredEnv = env
        expiredEnv.subscription = { _, _ in ["ok": true, "state": "signed_out"] }
        let (expired, _) = try makeWorkflow(expiredEnv, resume: .system)
        try await complete(expired)
        check("signed-out subscription blocks resumed completion", !(await expired.isDone))
        let raw: [String: Any] = ["name": "Sofia", "chatgpt": ["model": "gpt-5.6-luna", "effort": "high", "generation": loginGeneration],
            "openai": ["value": "a"], "serper": ["value": "s"], "jina": ["value": "j"], "telegram": ["token": "t", "chat_id": "1"]]
        check("subscription request does not require OpenCode", (try? QuickSetupRequest.parse(raw)) != nil)
        var ambiguous = raw; ambiguous["opencode"] = ["value": "key"]
        check("ambiguous main provider rejected", (try? QuickSetupRequest.parse(ambiguous)) == nil)
        var forged = raw; forged["chatgpt"] = ["kept": true]
        check("subscription cannot forge kept-login status", (try? QuickSetupRequest.parse(forged)) == nil)
    }
}
