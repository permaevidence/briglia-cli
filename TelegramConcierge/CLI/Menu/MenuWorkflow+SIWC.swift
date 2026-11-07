import Foundation

// The menu's Sign in with ChatGPT card (SIWC plan §2.1, §3.2 step 10, §3.10,
// §5, §5.1). The flow lives in the process that serves the page: the
// running daemon (live hub) or, with no daemon, this menu process (it then
// publishes through a short offline commit). Nothing here sends a token,
// the host ID or an email to the page.

extension MenuWorkflow {
    static let siwcActions: Set<String> = ["siwc_method", "siwc_continue", "siwc_paste", "siwc_cancel", "siwc_failed",
                                           "siwc_logout", "siwc_use", "siwc_switch_legacy"]

    /// The card's data (merged into `chatgpt.siwc`).
    func siwcPayload() -> [String: Any] {
        let stored = KeychainHelper.loadSnapshot()
        let info = SIWCSurface.info(stored: stored)
        var out: [String: Any] = [
            "label": SIWCSurface.label, "legacy_label": SIWCSurface.legacyLabel,
            "opted_in": SIWCSurface.optedIn(stored), "route": SIWCSurface.route(stored) ?? "",
            "login": info.login, "selected": info.selected, "registrations": info.registrations,
            "manage_usage": SIWCSurface.manageUsageURL,
            "flow": siwcFlow.status.json,
        ]
        // The flow's own outcome in the page's language, so a callback error,
        // the timeout or "saved but not switched" shows after polling too
        // (Codex D-R6), not only as an action's answer.
        if let message = siwcMessage(siwcFlow.status.message) { out["flow_message"] = message }
        if let invite = SIWCSurface.invitation(stored) { out["invitation"] = invite }
        if let state = info.planState, info.selected {
            var entry = SIWCPlanEntry(); entry.state = state; entry.reason = info.planReason
            out["plan_state"] = state.rawValue
            out["plan_text"] = planText(entry)
        }
        if info.twoEntriesNote { out["two_entries"] = L(SIWCSurface.twoEntriesMessage, "Questo account ora ha due voci Briglia in Impostazioni ChatGPT → Utilizzo, una per accesso.") }
        if info.login == "ambiguous" { out["notice"] = L(ChatGPTRoute.chooseAgainMessage, "Scegli di nuovo ChatGPT: la selezione di questo assistente è incompleta o è stata cambiata da un Briglia più vecchio. Non è stato inviato nulla.") }
        if let sharing = SubscriptionSharing.scopeStatus() { out["scope"] = sharing }
        out["legacy_login"] = SIWCSurface.legacyLoginPresent()
        return out
    }

    func planText(_ entry: SIWCPlanEntry) -> String {
        switch entry.state {
        case .ok: return L("Using ChatGPT plan", "Usa il piano ChatGPT")   // the Manage usage link follows
        case .limitReached: return L("Usage limit reached. Briglia is paused until your plan has room again. Review your plan or this app's limit in ChatGPT settings.",
                                     "Limite di utilizzo raggiunto. Briglia è in pausa finché il piano non ha di nuovo spazio. Controlla il piano o il limite di questa app nelle impostazioni di ChatGPT.")
        case .signInRequired: return L("Your ChatGPT sign-in for Briglia has expired or was revoked. Sign in again.",
                                       "L\u{2019}accesso a ChatGPT per Briglia è scaduto o è stato revocato. Accedi di nuovo.")
        case .notAvailable: return L("ChatGPT says this account or workspace can't use its plan in Briglia. Nothing will be retried.",
                                     "ChatGPT dice che questo account o spazio di lavoro non può usare il piano in Briglia. Non verrà ritentato nulla.")
        }
    }

    /// Fixed English/Italian text for a flow message (the flow's own strings
    /// are English; known ones are translated, the rest shown as is).
    func siwcMessage(_ text: String?) -> String? {
        guard let text else { return nil }
        let it: [String: String] = [
            SIWCFlow.browserFailedHelp: "Se ChatGPT ha mostrato una pagina di errore, il messaggio lì spiega il motivo (per esempio una regola dell\u{2019}account o dello spazio di lavoro). Briglia non ha ricevuto un motivo. Puoi riprovare, usare un altro account o scegliere un altro metodo nelle impostazioni.",
            SIWCFlow.cancelledInBrowser: "L\u{2019}accesso è stato annullato nel browser.",
            SIWCFlow.policyDenied: "ChatGPT ha rifiutato questo accesso per una regola dell\u{2019}account o dello spazio di lavoro (3p_delegated_access_policy_denied). Briglia non ha cambiato nulla. Puoi provare un altro account ChatGPT, chiedere all\u{2019}amministratore o scegliere un altro metodo nelle impostazioni.",
            SIWCFlow.unrecognizedRefusal: "ChatGPT ha rifiutato questo accesso (motivo non riconosciuto). Briglia non ha cambiato nulla.",
            SIWCFlow.firstUseNotice: "Stai usando il tuo piano ChatGPT. Briglia compare in Impostazioni ChatGPT → Utilizzo, dove puoi impostarne il limite. Se “usa i crediti dopo aver raggiunto i limiti del piano” è attivo per Briglia, ChatGPT può continuare a rispondere con i crediti e Briglia non può saperlo.",
            "Signed in. Briglia now uses ChatGPT (Sign in with ChatGPT).": "Accesso fatto. Ora Briglia usa ChatGPT (Accedi con ChatGPT).",
            SIWCError.planUsageOffMessage: "Questo accesso a ChatGPT non include l\u{2019}uso del piano. Attiva l\u{2019}uso del piano (accedi di nuovo e consentilo) o scegli un altro metodo.",
            "ChatGPT sign-in cancelled.": "Accesso a ChatGPT annullato.",
            CallbackPaste.Rejection.expired.rawValue + " " + SIWCFlow.browserFailedHelp: "Questo link di accesso è scaduto. Se ChatGPT ha mostrato una pagina di errore, il messaggio lì spiega il motivo. Briglia non ha ricevuto un motivo. Puoi riprovare, usare un altro account o scegliere un altro metodo nelle impostazioni.",
            CallbackPaste.Rejection.expired.rawValue: "Questo link di accesso è scaduto.",
            SIWCFlow.savedNotSwitchedMessage: "Accesso annullato. ChatGPT aveva già restituito l\u{2019}accesso, quindi è salvato, ma Briglia non è passata a usarlo. Usa “Usa ChatGPT per Briglia” se lo vuoi.",
            SIWCFlow.cancelledElsewhere: "Questo accesso a ChatGPT è stato annullato (da un\u{2019}operazione sulla memoria o da un ripristino). Ricomincia.",
            SIWCFlow.ownerChangedMessage: "Briglia si è avviata mentre accedevi, quindi questo accesso non è stato salvato. Accedi di nuovo dal Briglia in funzione.",
            "Signed in. Briglia is busy with a task, so it switches to Sign in with ChatGPT when the task finishes.": "Accesso fatto. Briglia è occupata, quindi passerà ad Accedi con ChatGPT quando finisce il lavoro in corso.",
            "Signed out of ChatGPT (Sign in with ChatGPT).": "Disconnesso da ChatGPT (Accedi con ChatGPT).",
            SIWCLogoutOutcome.unconfirmedMessage: "Disconnesso su questo computer; la disconnessione remota non è confermata. Scollega Briglia in Impostazioni ChatGPT → Utilizzo (chatgpt.com/settings/usage).",
        ]
        return lang == "it" ? (it[text] ?? text) : text
    }

    /// ChatGPT model/effort/use on the SIWC route (nil = not this route).
    func performSIWCRouteEdit(_ action: String, _ body: [String: Any]) async -> (Bool, String?)? {
        guard SIWCSurface.route() == "siwc" else { return nil }
        let result: SIWCFlow.ActivationResult
        switch action {
        case "chatgpt_model":
            let model = str(body, "model")
            guard ResponsesAdapter.subscriptionModelChoices.contains(where: { $0.id == model }) else { return (false, L("Unknown model.", "Modello sconosciuto.")) }
            result = await siwcFlow.activate(origin: "menu", model: model)
        case "effort" where activeLane == .chatgpt:
            let effort = str(body, "effort")
            let model = KeychainHelper.load(key: ChatGPTRoute.siwcModelKey) ?? ResponsesAdapter.subscriptionDefaultModel
            guard ResponsesAdapter.allowedEfforts(model: model).contains(effort) else { return (false, L("This model doesn\u{2019}t take that effort.", "Questo modello non accetta quel livello.")) }
            result = await siwcFlow.activate(origin: "menu", effort: effort)
        case "chatgpt_use", "chatgpt_browser", "chatgpt_code":
            guard action == "chatgpt_use" else { return nil }
            result = await siwcFlow.activate(origin: "menu")
        default: return nil
        }
        await reload()
        switch result {
        case .success(let applied):
            return (true, applied ? L("Saved.", "Salvato.") : L("Saved. Briglia applies it when its current task finishes.", "Salvato. Briglia lo applica quando finisce il lavoro in corso."))
        case .failure(let why): return (false, why)
        }
    }

    func performSIWC(_ action: String, _ body: [String: Any]) async -> (Bool, String?) {
        switch action {
        case "siwc_method":
            // Opening the selector or choosing in it switches nothing: it
            // only shows that method's sign-in (§2.1 "Choose sign-in method").
            let route = str(body, "route")
            guard route == "siwc" || route == "legacy" else { return (false, L("Unknown choice.", "Scelta sconosciuta.")) }
            // On the SIWC route, choosing legacy only shows its sign-in; the
            // route and the login stay until the user completes the switch
            // there (Codex D-R7).
            if route == "legacy", SIWCSurface.route() == "siwc" { return (true, nil) }
            let r = await SIWCSurface.setOptIn(route == "siwc", origin: "menu")
            await reload()
            return r.state == .applied ? (true, nil) : (false, r.message ?? L("Not saved.", "Non salvato."))
        case "siwc_continue":
            let mode: SIWCFlow.Mode = str(body, "mode") == "paste" || !env.browserLikely ? .paste : .browser
            let status = await siwcFlow.start(mode: mode, consent: body["consent"] as? Bool == true,
                                              newRegistration: body["new"] as? Bool == true)
            if status.state == "waiting" { _ = await SIWCSurface.setOptIn(true, origin: "menu") }
            await reload()
            return status.state == "waiting" ? (true, nil) : (false, siwcMessage(status.message))
        case "siwc_paste":
            let reply = await siwcFlow.paste(str(body, "text"))
            await reload()
            switch siwcFlow.status.state {
            case "waiting": return (false, siwcMessage(reply))
            case "done": return (siwcFlow.status.outcome != "plan_usage_off", siwcMessage(siwcFlow.status.message))
            default: return (false, siwcMessage(siwcFlow.status.message ?? reply))
            }
        case "siwc_cancel", "siwc_failed":
            let status = await siwcFlow.cancel(browserFailed: action == "siwc_failed")
            await reload()
            return (true, siwcMessage(status.message))
        case "siwc_logout":
            let r = await SIWCSurface.logout(writer: siwcFlow.writer)
            await reload()
            return (r.ok, siwcMessage(r.message))
        case "siwc_use":
            let r = await siwcFlow.activate(origin: "menu")
            await reload()
            switch r {
            case .success(let applied):
                return (true, applied ? L("Briglia now uses ChatGPT (Sign in with ChatGPT).", "Ora Briglia usa ChatGPT (Accedi con ChatGPT).")
                                      : L("Saved. Briglia switches when its current task finishes.", "Salvato. Briglia passa al nuovo accesso quando finisce il lavoro in corso."))
            case .failure(let why): return (false, why)
            }
        case "siwc_switch_legacy":
            // The explicit switch back: the legacy selection (it removes the
            // SIWC selection keys, stage C), then the opt-in is cleared.
            guard SIWCSurface.legacyLoginPresent() else {
                return (false, L("Sign in with the legacy method first.", "Accedi prima con il metodo precedente."))
            }
            let stored = KeychainHelper.loadSnapshot()
            let saved = stored[ChatGPTRoute.siwcModelKey] ?? ResponsesAdapter.subscriptionDefaultModel
            let model = ResponsesAdapter.subscriptionModelChoices.contains { $0.id == saved } ? saved : ResponsesAdapter.subscriptionDefaultModel
            var effort = stored[ChatGPTRoute.siwcEffortKey] ?? "high"
            if !ResponsesAdapter.allowedEfforts(model: model).contains(effort) { effort = "high" }
            let result = await env.subscription(["action": "select", "model": model, "effort": effort], {})
            guard result["ok"] as? Bool == true else { await reload(); return (false, applyError(result)) }
            _ = await SIWCSurface.setOptIn(false, origin: "menu")
            await reload()
            return (true, result["state"] as? String == "pending"
                    ? L("Saved. Briglia switches to the legacy sign-in when its current task finishes.", "Salvato. Briglia passa all\u{2019}accesso precedente quando finisce il lavoro in corso.")
                    : L("Briglia now uses ChatGPT (legacy Codex sign-in).", "Ora Briglia usa ChatGPT (accesso Codex precedente)."))
        default:
            return (false, L("Unknown action.", "Azione sconosciuta."))
        }
    }
}
