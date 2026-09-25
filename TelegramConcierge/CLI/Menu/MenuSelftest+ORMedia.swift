import Foundation

/// Owner decision 2026-09-25: on the OpenRouter lane Briglia needs only the
/// OpenRouter key. The menu must not require (or ask first for) an OpenAI
/// key there, must show voice & images as working "via OpenRouter", and must
/// keep the OpenAI key required on OpenCode Go and the local/other lane.
@MainActor
extension MenuSelftestContext {

    func openRouterLaneWithoutOpenAI() async {
        let w = world()
        let wf = await make(w)
        var r = await act(wf, ["action": "lane", "lane": "openrouter"])
        check("or-media: choosing OpenRouter does not make the OpenAI key required",
              ok(r) && ai(wf)["planned"] as? String == "openrouter" && ai(wf)["openai_required"] as? Bool == false
              && step(wf, "openai")["required"] as? Bool == false && !wf.missingRequired.contains(.openai)
              && step(wf, "openai")["title"] as? String == "Voice & images")
        check("or-media: before OpenRouter runs, voice & images are not claimed as working",
              ai(wf)["media_via"] is NSNull && !done(wf, "openai"))

        r = await act(wf, ["action": "provider_key", "profile": "openrouter", "key": w.good["openrouter"]!])
        check("or-media: with OpenRouter running and no OpenAI key, voice & images show as done via OpenRouter",
              ok(r) && ai(wf)["active"] as? String == "openrouter" && ai(wf)["media_via"] as? String == "openrouter"
              && done(wf, "openai") && step(wf, "openai")["summary"] as? String == "Via OpenRouter"
              && step(wf, "openai")["required"] as? Bool == false)
        await act(wf, ["action": "lang", "lang": "it"])
        check("or-media: the Italian dashboard says Tramite OpenRouter",
              step(wf, "openai")["summary"] as? String == "Tramite OpenRouter" && step(wf, "openai")["title"] as? String == "Voce e immagini")
        await act(wf, ["action": "lang", "lang": "en"])

        r = await act(wf, ["action": "key", "kind": "openai", "key": w.good["openai"]!])
        check("or-media: an optional OpenAI key can still be added on OpenRouter; it then serves voice & images",
              ok(r) && ai(wf)["media_via"] as? String == "openai" && (step(wf, "openai")["summary"] as? String ?? "").hasPrefix("Key ")
              && msg(r).contains("Voice messages") && !msg(r).contains("Web research"))
        r = await act(wf, ["action": "key_remove", "kind": "openai"])
        check("or-media: the OpenAI key can be removed on OpenRouter, and voice & images fall back to OpenRouter",
              ok(r) && msg(r).contains("through OpenRouter") && ai(wf)["media_via"] as? String == "openrouter" && done(wf, "openai"))

        // The other paid lanes keep the OpenAI key required.
        for lane in ["opencode", "local"] {
            let w2 = world()
            let wf2 = await make(w2)
            let r2 = await act(wf2, ["action": "lane", "lane": lane])
            check("or-media: \(lane) still requires the OpenAI key",
                  ok(r2) && ai(wf2)["openai_required"] as? Bool == true && wf2.missingRequired.contains(.openai))
        }
        check("or-media: lane rule — only OpenCode Go and local/other need OpenAI",
              MenuLane.allCases.filter(\.needsOpenAI) == [.opencode, .local])
    }
}
