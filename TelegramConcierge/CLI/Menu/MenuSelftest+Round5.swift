import Foundation

/// Round 5 (2026-09-25): a saved server's key is bound to its address, a
/// late ChatGPT sign-in never overrides a lane chosen elsewhere, and a
/// server's saved protocol is exactly the one its check used. The server
/// rows run against the REAL secret store and the real setup-api (the
/// battery's temp XDG roots); only network listings and probes are faked.
extension MenuSelftestContext {
    func round5() async {
        await round5SignInExternalLane()
        await round5SignInAwayFromChatGPT()
        await round5SignInControls()
        await round5StaleCredential()
        await round5RemovedServer()
        await round5ProtocolOnAddressChange()
        await round5ProtocolControls()
    }

    /// Starts a device sign-in that pauses before its commit; `during` runs
    /// while it is paused. Returns the world after the commit settled.
    private func round5SignIn(seed: (MenuFakeWorld) -> Void, during: (MenuFakeWorld) -> Void) async -> MenuFakeWorld {
        let w = world()
        seed(w)
        var e = env(w)
        let gate = MenuGate()
        e.deviceLogin = { show, commit in
            show("https://auth.example/device", "CODE")
            await gate.wait()
            _ = try await commit { pre in
                try pre?()
                w.loginCommits += 1
                if case .signedIn(let active, _, _, _) = w.snap.chatgpt, active { return "new" }
                w.snap.chatgpt = .signedIn(active: false, model: "gpt-6-sol", effort: "high", generation: "new")
                return "new"
            }
        }
        let wf = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
        await wf.start(); await wf.settle()
        _ = await wf.handle(["action": "chatgpt_code"])
        for _ in 0..<400 where !gate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
        during(w)
        gate.open()
        await wf.settle()
        for _ in 0..<200 where w.loginCommits == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        await wf.settle()
        await wf.shutdown()
        return w
    }

    private func round5SignInExternalLane() async {
        let w = await round5SignIn(seed: { _ in }, during: { w in
            w.snap.activeProfile = "openrouter"
            w.snap.otherProvider = "OpenRouter"
            w.snap.providers["openrouter"] = .init(configured: true, model: "chosen-main", effort: "high")
        })
        var inactive = false
        if case .signedIn(let active, _, _, _) = w.snap.chatgpt { inactive = !active }
        check("R5 sign-in: a lane chosen elsewhere during sign-in stays in use", w.snap.activeProfile == "openrouter",
              "active=\(w.snap.activeProfile ?? "nil"), commits=\(w.loginCommits)")
        check("R5 sign-in: the login is still saved, as a lane not in use", w.loginCommits == 1 && inactive, "commits=\(w.loginCommits) chatgpt=\(w.snap.chatgpt)")
    }

    private func round5SignInAwayFromChatGPT() async {
        let w = await round5SignIn(seed: { w in
            w.snap.activeProfile = "chatgpt"
            w.snap.chatgpt = .loginRequired
        }, during: { w in
            w.snap.activeProfile = "openrouter"
            w.snap.otherProvider = "OpenRouter"
            w.snap.providers["openrouter"] = .init(configured: true, model: "chosen-main", effort: "high")
        })
        check("R5 sign-in: re-signing ChatGPT after switching away elsewhere doesn't switch back", w.snap.activeProfile == "openrouter" && w.loginCommits == 1,
              "active=\(w.snap.activeProfile ?? "nil"), commits=\(w.loginCommits)")
    }

    private func round5SignInControls() async {
        let fresh = await round5SignIn(seed: { _ in }, during: { _ in })
        check("R5 control: a fresh setup with nothing chosen meanwhile switches to ChatGPT", fresh.snap.activeProfile == "chatgpt" && fresh.snap.chatgptReady)

        let recover = await round5SignIn(seed: { w in
            w.snap.activeProfile = "chatgpt"
            w.snap.chatgpt = .loginRequired
        }, during: { _ in })
        check("R5 control: signing in again to the ChatGPT lane in use keeps it in use", recover.snap.activeProfile == "chatgpt" && recover.snap.chatgptReady,
              "active=\(recover.snap.activeProfile ?? "nil") chatgpt=\(recover.snap.chatgpt)")

        let other = await round5SignIn(seed: { w in
            w.snap.activeProfile = "openrouter"
            w.snap.otherProvider = "OpenRouter"
            w.snap.providers["openrouter"] = .init(configured: true, model: "or-main", effort: "high")
        }, during: { _ in })
        check("R5 control: adding ChatGPT while another lane runs saves without switching", other.snap.activeProfile == "openrouter" && other.loginCommits == 1)
    }

    /// A MenuEnvironment on the real store with recording network closures.
    private func round5Env(sent: @escaping (String, String?) -> Void, probed: @escaping ([String: Any]) -> [String: Any]) -> MenuEnvironment {
        var env = MenuEnvironment()
        env.language = "en"
        env.toolchainStatus = { ToolchainService.DesktopStatus(doctorRan: true, missing: [], libreOffice: true, mandatoryMissing: []) }
        env.localModels = { base, key in sent(base, key); return .success(["model"]) }
        env.probe = { probed($0) }
        env.markComplete = {}
        return env
    }

    private func round5StaleCredential() async {
        wipeStore()
        let oldBase = "https://old.example.com/v1", newBase = "https://new.example.com/v1"
        let oldKey = "sk-old-synthetic-123456789", newKey = "sk-new-synthetic-987654321"
        do {
            let s = try ProviderServers.save(.init(name: "Review", baseURL: oldBase, apiKey: oldKey, model: "model", textOnly: false))
            var sent: [(String, String?)] = []
            var probes: [[String: Any]] = []
            let env = round5Env(sent: { sent.append(($0, $1)) }, probed: { probes.append($0); return ["ok": true] })
            let wf = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
            await wf.start(); await wf.settle()
            let wfProbe = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
            await wfProbe.start(); await wfProbe.settle()
            _ = await act(wf, ["action": "local_models", "server_id": s.id, "base_url": oldBase])
            check("R5 control: an unchanged address lists with its own saved key", sent.last?.0 == oldBase && sent.last?.1 == oldKey)
            try ProviderServers.save(.init(id: s.id, name: s.name, baseURL: newBase, apiKey: newKey, model: s.model, textOnly: false))
            let listed = await act(wf, ["action": "local_models", "server_id": s.id, "base_url": oldBase])
            check("R5 stale listing: the new host's key is never sent to the old host", !sent.contains { $0.0 == oldBase && $0.1 == newKey })
            check("R5 stale listing: refused with nothing sent", !ok(listed) && sent.count == 1, "sent=\(sent.count)")
            let saved = await act(wfProbe, ["action": "server_save", "id": s.id, "name": s.name, "base_url": oldBase, "model": "different-model"])
            check("R5 stale probe: the new host's key is never probed at the old host",
                  !probes.contains { $0["base_url"] as? String == oldBase && $0["api_key"] as? String == newKey })
            check("R5 stale probe: refused with no probe and the record unchanged",
                  !ok(saved) && probes.isEmpty && ProviderServers.list()?.first { $0.id == s.id }?.baseURL == newBase)
            // Refreshed page: the current address works with its own key.
            let fresh = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
            await fresh.start(); await fresh.settle()
            _ = await act(fresh, ["action": "local_models", "server_id": s.id, "base_url": newBase])
            check("R5 control: after a refresh the new address lists with its own key", sent.last?.0 == newBase && sent.last?.1 == newKey)
            await wf.shutdown(); await wfProbe.shutdown(); await fresh.shutdown()
        } catch { check("R5 stale credential setup", false, "\(error)") }
    }

    private func round5RemovedServer() async {
        wipeStore()
        let base = "https://gone.example.com/v1"
        do {
            let s = try ProviderServers.save(.init(name: "Gone", baseURL: base, apiKey: "sk-gone-synthetic-12345", model: "model", textOnly: false))
            var sent: [(String, String?)] = []
            var probes: [[String: Any]] = []
            let env = round5Env(sent: { sent.append(($0, $1)) }, probed: { probes.append($0); return ["ok": true] })
            let wf = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
            await wf.start(); await wf.settle()
            try ProviderServers.remove(s.id)
            let listed = await act(wf, ["action": "local_models", "server_id": s.id, "base_url": base])
            let saved = await act(wf, ["action": "server_save", "id": s.id, "name": s.name, "base_url": base, "model": "other"])
            check("R5 removed server: no listing and no probe carry its key", !ok(listed) && !ok(saved) && sent.isEmpty && probes.isEmpty,
                  "sent=\(sent.count) probes=\(probes.count)")
            await wf.shutdown()
        } catch { check("R5 removed server setup", false, "\(error)") }
    }

    /// Edits a saved Responses server to `newBase` with a new key; the
    /// probe answers only the listed kinds. Returns (probe kinds, save ok,
    /// stored record).
    private func round5ProtocolEdit(newBase: String?, answers: Set<String>, model: String = "model") async -> ([String], Bool, ProviderServers.Server?) {
        wipeStore()
        do {
            let s = try ProviderServers.save(.init(name: "Responses server", baseURL: "https://responses.example.com/v1", apiKey: "sk-old-123456789",
                                                   model: "model", textOnly: false, wireProtocol: "responses", nativeToolMedia: true))
            var kinds: [String] = []
            let env = round5Env(sent: { _, _ in }, probed: { req in
                let kind = req["kind"] as? String ?? ""
                kinds.append(kind)
                return answers.contains(kind) ? ["ok": true] : ["ok": false, "reason": "HTTP 404"]
            })
            let wf = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
            await wf.start(); await wf.settle()
            let base = newBase ?? s.baseURL
            if newBase != nil {
                _ = await act(wf, ["action": "local_models", "server_id": s.id, "base_url": base, "api_key": "sk-new-987654321"])
            }
            let result = await act(wf, ["action": "server_save", "id": s.id, "name": s.name, "base_url": base, "model": model])
            await wf.shutdown()
            return (kinds, ok(result), ProviderServers.list()?.first { $0.id == s.id })
        } catch { check("R5 protocol setup", false, "\(error)"); return ([], false, nil) }
    }

    private func round5ProtocolOnAddressChange() async {
        let (kinds, saved, stored) = await round5ProtocolEdit(newBase: "https://both.example.com/v1", answers: ["responses", "custom"])
        check("R5 address edit: the saved protocol matches the successful probe",
              saved && kinds.last == "responses" && stored?.responses == true, "probe=\(kinds), saved responses=\(stored?.responses ?? false), ok=\(saved)")
        let (k2, s2, st2) = await round5ProtocolEdit(newBase: "https://chat-only.example.com/v1", answers: ["custom"])
        check("R5 address edit: a chat-only new host is saved as Chat Completions, as probed",
              s2 && k2 == ["responses", "custom"] && st2?.responses == false && st2?.baseURL == "https://chat-only.example.com/v1",
              "probe=\(k2), saved responses=\(st2?.responses ?? false), ok=\(s2)")
        let (k3, s3, st3) = await round5ProtocolEdit(newBase: "https://nothing.example.com/v1", answers: [])
        check("R5 address edit: a host answering neither is refused and nothing changes",
              !s3 && k3 == ["responses", "custom"] && st3?.baseURL == "https://responses.example.com/v1" && st3?.responses == true)
    }

    private func round5ProtocolControls() async {
        let (kinds, saved, stored) = await round5ProtocolEdit(newBase: nil, answers: ["responses"], model: "model-b")
        check("R5 control: a same-address edit probes and keeps Responses with its native-media setting",
              saved && kinds == ["responses"] && stored?.responses == true && stored?.nativeToolMedia == true && stored?.model == "model-b",
              "probe=\(kinds) stored=\(String(describing: stored))")
        wipeStore()
        do {
            let s = try ProviderServers.save(.init(name: "Chat server", baseURL: "https://chat.example.com/v1", apiKey: "sk-chat-123456789", model: "model", textOnly: false))
            var kinds: [String] = []
            let env = round5Env(sent: { _, _ in }, probed: { kinds.append($0["kind"] as? String ?? ""); return ["ok": true] })
            let wf = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
            await wf.start(); await wf.settle()
            _ = await act(wf, ["action": "local_models", "server_id": s.id, "base_url": "https://chat2.example.com/v1", "api_key": "sk-chat2-123456789"])
            let r = await act(wf, ["action": "server_save", "id": s.id, "name": s.name, "base_url": "https://chat2.example.com/v1", "model": "model"])
            let st = ProviderServers.list()?.first { $0.id == s.id }
            check("R5 control: a Chat Completions server moved to a new address is probed and saved as Chat Completions",
                  ok(r) && kinds == ["custom"] && st?.responses == false)
            await wf.shutdown()
        } catch { check("R5 chat control setup", false, "\(error)") }
    }
}
