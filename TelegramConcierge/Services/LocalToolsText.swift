import Foundation

/// Wording of the local-tool messages and Security-line states (security
/// plan v16 §9.5.4, §9.5.5). Fixed templates compiled into Briglia; the only
/// variable parts are local names (re-validated here), versions read from
/// this machine, and advisory IDs that passed the ID pattern. Never "safe".
enum LocalToolsText {
    static func L(_ lang: String, _ en: String, _ it: String) -> String { lang == "it" ? it : en }
    static func T(_ lang: String, _ t: LocalTools.Text) -> String { lang == "it" ? t.it : t.en }

    #if os(macOS)
    static let machineEN = "this Mac", machineIT = "questo Mac"
    #else
    static let machineEN = "this computer", machineIT = "questo computer"
    #endif

    static func toolName(_ id: String) -> String { LocalTools.tool(id)?.name ?? id }

    /// The name shown for a report; the renderer's browser is named by what
    /// was actually found (Chromium, Google Chrome, Edge, a deb source).
    static func displayName(_ r: LocalTools.ToolReport) -> String {
        guard LocalTools.tool(r.toolId)?.rendererBrowser == true, let key = r.identityKey else { return toolName(r.toolId) }
        let p = key.split(separator: ":").map(String.init)
        switch p.first {
        case "vendor"? where p.count >= 3:
            switch (p[1], p[2]) {
            case ("google", "chrome"): return "Google Chrome"
            case ("chromium.org", _): return "Chromium"
            case ("microsoft", "edge"): return "Microsoft Edge"
            default: return p[2]
            }
        case "deb"? where p.count >= 4: return p[3]
        case "brew"? where p.count >= 3: return p[p.count - 2]
        default: return toolName(r.toolId)
        }
    }

    static func vendorName(_ vendor: String, _ product: String) -> (String, String) {
        switch (vendor, product) {
        case ("nodejs.org", _): return ("Node.js", "nodejs.org")
        case ("python.org", _): return ("Python", "python.org")
        case ("google", "chrome"): return ("Google Chrome", "Google")
        case ("documentfoundation", _): return ("LibreOffice", "libreoffice.org")
        default: return (product, vendor)
        }
    }

    /// The fix instruction, or nil when no locally valid command exists.
    static func fixInstruction(_ a: LocalTools.FixAction?, lang: String) -> String? {
        switch a {
        case .apt(let names)?:
            let valid = names.filter(LocalTools.validDebName)
            guard !valid.isEmpty, valid.count == names.count else { return nil }
            return L(lang, "To fix it, run: `sudo apt-get install --only-upgrade \(valid.joined(separator: " "))`",
                     "Per correggerlo, esegui: `sudo apt-get install --only-upgrade \(valid.joined(separator: " "))`")
        case .brew(let f)?:
            guard LocalTools.validBrewName(f) else { return nil }
            return L(lang, "To fix it, run: `brew upgrade \(f)` (or ask me to run it).", "Per correggerlo, esegui: `brew upgrade \(f)` (oppure chiedimi di farlo).")
        case .cask(let t)?:
            guard LocalTools.validBrewName(t) else { return nil }
            return L(lang, "To fix it, run: `brew upgrade --cask \(t)` (or ask me to run it).", "Per correggerlo, esegui: `brew upgrade --cask \(t)` (oppure chiedimi di farlo).")
        case .vendor(let vendor, let product, let minimum)?:
            let (p, v) = vendorName(vendor, product)
            return L(lang, "Update \(p) from \(v) (version \(minimum) or later).", "Aggiorna \(p) da \(v) (versione \(minimum) o successiva).")
        case nil:
            return nil
        }
    }

    static func idList(_ results: [LocalTools.AdvisoryResult]) -> String {
        var unique: [String] = []
        for i in results.map(\.primaryId) where !unique.contains(i) { unique.append(i) }
        let shown = unique.prefix(3).joined(separator: ", ")
        return unique.count > 3 ? shown + ", …" : shown
    }

    static func ids(_ r: LocalTools.ToolReport, kevOnly: Bool = false) -> String {
        idList(r.affected.filter { !kevOnly || $0.kev })
    }

    static func mitigation(_ r: LocalTools.ToolReport, lang: String) -> String {
        T(lang, LocalTools.tool(r.toolId)?.mitigation ?? LocalTools.noWorkaround)
    }

    /// Advisories an update fixes / KEV advisories it does not (R5: a fix
    /// for one advisory never implies the others are fixed).
    static func fixable(_ r: LocalTools.ToolReport) -> [LocalTools.AdvisoryResult] { r.affected.filter { $0.fix == .installable } }
    static func kevUnfixed(_ r: LocalTools.ToolReport) -> [LocalTools.AdvisoryResult] { r.affected.filter { $0.kev && $0.fix != .installable } }

    /// "To fix it, run: …" when the update fixes every applicable
    /// advisory, else "To fix CVE-…, run: …".
    static func fixSentence(_ r: LocalTools.ToolReport, only: [LocalTools.AdvisoryResult]? = nil, lang: String) -> String? {
        guard let instr = fixInstruction(r.action, lang: lang) else { return nil }
        let covered = only ?? fixable(r)
        guard !covered.isEmpty else { return nil }
        if covered.count == r.affected.count && only == nil { return instr }
        let scoped = idList(covered)
        return instr
            .replacingOccurrences(of: "To fix it, run:", with: "To fix \(scoped), run:")
            .replacingOccurrences(of: "Per correggerlo, esegui:", with: "Per correggere \(scoped), esegui:")
            .replacingOccurrences(of: "Update ", with: "To fix \(scoped), update ", options: .anchored)
            .replacingOccurrences(of: "Aggiorna ", with: "Per correggere \(scoped), aggiorna ", options: .anchored)
    }

    /// The compiled mitigation for KEV advisories still without an
    /// installable fix (N16-3: combined with any independently useful fix).
    static func kevMitigationSentence(_ r: LocalTools.ToolReport, lang: String, also: Bool) -> String? {
        let open = kevUnfixed(r)
        guard !open.isEmpty else { return nil }
        let lead = also
            ? L(lang, "\(idList(open)) is also actively exploited and has no installable fix yet.",
                "anche \(idList(open)) è sfruttato attivamente e non ha ancora una correzione installabile.")
            : L(lang, "\(idList(open)) is actively exploited and has no installable fix yet.",
                "\(idList(open)) è sfruttato attivamente e non ha ancora una correzione installabile.")
        return lead + " " + mitigation(r, lang: lang)
    }

    /// One message line for one proposal.
    static func line(_ p: LocalVuln.Proposal, lang: String) -> String {
        let r = p.report
        let name = displayName(r), ver = r.installedVersion ?? "?"
        let noFix = L(lang, "Briglia does not update it for you.", "Briglia non lo aggiorna per te.")
        switch p.kind {
        case .followUp:
            // Only the KEV advisories that gained an installable fix are
            // named as fixed; any other exploited one keeps its mitigation.
            let kevFixed = r.affected.filter { $0.kev && $0.fix == .installable }
            var s = L(lang, "A fix is now available for the actively exploited security problem \(idList(kevFixed)) in \(name) \(ver).",
                      "Ora è disponibile una correzione per il problema di sicurezza sfruttato attivamente \(idList(kevFixed)) in \(name) \(ver).")
            if let fix = fixSentence(r, only: kevFixed.count == r.affected.count ? nil : fixable(r), lang: lang) { s += " " + fix }
            if let m = kevMitigationSentence(r, lang: lang, also: true) { s += " " + m }
            return s
        case .escalation:
            let what = r.kevAffected
                ? L(lang, "is now known to be actively exploited", "risulta ora sfruttato attivamente")
                : L(lang, "is now rated critical", "è ora classificato come critico")
            var s = L(lang, "Update on \(name) \(ver) on \(machineEN): its known security problem (\(ids(r))) \(what).",
                      "Aggiornamento su \(name) \(ver) su \(machineIT): il suo problema di sicurezza noto (\(ids(r))) \(what).")
            if let fix = fixSentence(r, lang: lang) { s += " " + fix }
            if let m = kevMitigationSentence(r, lang: lang, also: !fixable(r).isEmpty) { s += " " + m }
            return s
        case .initial:
            if r.hasInstallableFix {
                let serious = r.level == .critical
                var s = serious
                    ? L(lang, "\(name) \(ver) on \(machineEN) has a serious known security problem (\(ids(r))).",
                        "\(name) \(ver) su \(machineIT) ha un grave problema di sicurezza noto (\(ids(r))).")
                    : L(lang, "\(name) \(ver) on \(machineEN) has a known security problem (\(ids(r))).",
                        "\(name) \(ver) su \(machineIT) ha un problema di sicurezza noto (\(ids(r))).")
                if r.kevAffected { s += " " + L(lang, "It is being actively exploited.", "È sfruttato attivamente.") }
                s += " " + noFix
                if let fix = fixSentence(r, lang: lang) { s += " " + fix }
                if let m = kevMitigationSentence(r, lang: lang, also: true) { s += " " + m }
                return s
            }
            let detail: String
            if let unfixable = kevUnfixed(r).first {
                switch unfixable.fix {
                case .noFix:
                    detail = L(lang, "No fix is available from the distribution or vendor yet.", "Non è ancora disponibile una correzione dalla distribuzione o dal produttore.")
                case .notInstallable(let why), .unknown(let why):
                    detail = L(lang, "A fix exists, but it is not installable here: ", "Esiste una correzione, ma qui non è installabile: ") + T(lang, why) + "."
                case .installable:
                    detail = ""
                }
            } else {
                detail = ""
            }
            return L(lang, "\(name) \(ver) on \(machineEN) has a security problem that is being actively exploited (\(ids(r, kevOnly: true))).",
                     "\(name) \(ver) su \(machineIT) ha un problema di sicurezza sfruttato attivamente (\(ids(r, kevOnly: true))).")
                + (detail.isEmpty ? "" : " " + detail) + " " + mitigation(r, lang: lang)
        }
    }

    /// One message for one check: ≤ 5 named lines, then "and N more".
    static func message(_ lines: [LocalVuln.Proposal], lang: String) -> String {
        guard lines.count > 1 else { return lines.first.map { "⚠️ " + line($0, lang: lang) } ?? "" }
        var out = [L(lang, "⚠️ Briglia found known security problems in tools on \(machineEN):",
                     "⚠️ Briglia ha trovato problemi di sicurezza noti in strumenti su \(machineIT):")]
        for p in lines.prefix(LocalVuln.maxNamedLines) { out.append("• " + line(p, lang: lang)) }
        if lines.count > LocalVuln.maxNamedLines {
            let n = lines.count - LocalVuln.maxNamedLines
            out.append(L(lang, "…and \(n) more: see /status.", "…e altri \(n): vedi /status."))
        }
        return UpdateNotice.capped(out.joined(separator: "\n"), bytes: 3800)
    }

    // MARK: - Security line

    struct Status: Equatable {
        var part: String
        var reasons: [SecurityStatus.Reason]
        var details: [String]
    }

    static func stateText(_ r: LocalTools.ToolReport, lang: String) -> String {
        switch r.state {
        case .affectedFixInstallable:
            return L(lang, "known security problem (\(ids(r)))", "problema di sicurezza noto (\(ids(r)))")
                + (fixInstruction(r.action, lang: lang).map { " — " + $0 } ?? "")
        case .affectedNotInstallable:
            let why = r.affected.compactMap { a -> LocalTools.Text? in
                if case .notInstallable(let t) = a.fix { return t }
                if case .unknown(let t) = a.fix { return t }
                return nil
            }.first
            return L(lang, "known security problem (\(ids(r))); a fix exists but is not installable here", "problema di sicurezza noto (\(ids(r))); esiste una correzione ma qui non è installabile")
                + (why.map { " (" + T(lang, $0) + ")" } ?? "")
        case .affectedNoFix:
            return L(lang, "known security problem (\(ids(r))); no fix from the distribution or vendor yet",
                     "problema di sicurezza noto (\(ids(r))); ancora nessuna correzione dalla distribuzione o dal produttore")
        case .noKnownIssue:
            let when = r.checkedAt.map { UpdateNoticeText.day($0) } ?? "?"
            return L(lang, "no known security issues in this tool (checked \(when))", "nessun problema di sicurezza noto in questo strumento (controllato il \(when))")
        case .unknown:
            return L(lang, "unknown", "sconosciuto") + (r.reason.map { " — " + T(lang, $0) } ?? "")
        case .absent:
            return L(lang, "not installed", "non installato")
        }
    }

    /// The Security-line part, attention reasons and doctor details.
    static func status(setting: UpdateNoticeStore.SettingRead, policy: AdvisoryPolicy,
                       observation: LocalAdvisoryStore.ObservationState?, vuln: LocalVulnState?, now: Date) -> Status {
        guard policy.isProvisioned else {
            return Status(part: "tool advisories: not available yet in this build",
                          reasons: [],
                          details: ["Known-vulnerability check of your own tools: not available yet in this build (the advisory list's signing key is not provisioned); tool states are unknown, nothing is fetched"])
        }
        guard setting.enabled else {
            return Status(part: "tool advisories: off", reasons: [],
                          details: ["Known-vulnerability check of your own tools: off (it shares /upgradecheck); nothing is fetched"])
        }
        var reasons: [SecurityStatus.Reason] = []
        var details: [String] = []
        func reason(_ en: String, _ it: String) { reasons.append(SecurityStatus.Reason(en: en, it: it)) }
        let domain = policy.trustDomain
        let record = observation?.domain(domain)
        if observation?.lastSuccess == nil {
            details.append("Advisory list: not received yet" + (observation?.lastProblem.map { " (last problem: \($0))" } ?? ""))
        } else if let last = observation?.lastSuccess, now.timeIntervalSince(last) > UpdateNotice.freshness {
            reason("the tool-advisory check is stale (last success \(SecurityStatus.age(last, now: now)))",
                   "il controllo degli avvisi sugli strumenti non è aggiornato (ultimo successo \(SecurityStatus.age(last, now: now)))")
        }
        if let d = record {
            details.append("Advisory list: sequence \(d.sequence), published \(UpdateNoticeText.day(d.published)), expires \(UpdateNoticeText.day(d.expires))")
            if d.expires <= now {
                reason("the tool-advisory list has expired; tool states are unknown", "l'elenco degli avvisi sugli strumenti è scaduto; lo stato degli strumenti è sconosciuto")
            }
            if let since = d.conflictSince, now.timeIntervalSince(since) >= 0 {
                reason("advisory list conflict (two different lists with the same sequence); no tool messages until a newer list",
                       "conflitto nell'elenco degli avvisi (due elenchi diversi con la stessa sequenza); nessun messaggio finché non arriva un elenco più recente")
            }
            if let since = d.lowerSince, now.timeIntervalSince(since) > UpdateNotice.attentionAfter {
                reason("the advisory list Briglia receives is older than one it already saw", "l'elenco degli avvisi ricevuto è più vecchio di uno già visto")
            }
        }
        if vuln?.saturated != nil {
            reason("many tool security problems are waiting; see briglia doctor", "molti problemi di sicurezza degli strumenti sono in attesa; vedi briglia doctor")
        }
        let reports = (vuln?.report?.reports ?? []).filter { $0.state != .absent }
        let expired = record.map { $0.expires <= now } ?? true
        for r in reports {
            let state = expired && r.state != .unknown ? "unknown — the advisory list has expired" : stateText(r, lang: "en")
            details.append("\(displayName(r)) \(r.installedVersion ?? "")".trimmingCharacters(in: .whitespaces)
                           + (r.identityKey.map { " [\($0)]" } ?? "") + ": " + state
                           + (r.statusOnly.map { " (" + $0.en + ")" } ?? ""))
        }
        if !expired {
            for r in reports where [.affectedFixInstallable, .affectedNotInstallable, .affectedNoFix].contains(r.state) {
                let name = "\(displayName(r)) \(r.installedVersion ?? "")"
                reasons.append(SecurityStatus.Reason(en: "\(name) has a known security problem (\(ids(r)))" + (fixInstruction(r.action, lang: "en").map { ": " + $0 } ?? ""),
                                                     it: "\(name) ha un problema di sicurezza noto (\(ids(r)))" + (fixInstruction(r.action, lang: "it").map { ": " + $0 } ?? "")))
            }
        }
        if let o = vuln?.lastOutcome {
            details.append("Last tool-security message: " + (o.outcome == .accepted ? "sent" : "may not have arrived (\(o.outcome.rawValue))")
                           + " \(SecurityStatus.age(o.at, now: now))")
        }
        let affected = expired ? 0 : reports.filter { [.affectedFixInstallable, .affectedNotInstallable, .affectedNoFix].contains($0.state) }.count
        let clean = expired ? 0 : reports.filter { $0.state == .noKnownIssue }.count
        let unknown = reports.count - affected - clean
        let part: String
        if reports.isEmpty {
            part = "tool advisories: not checked yet"
        } else {
            let at = vuln?.report.map { SecurityStatus.age($0.evaluatedAt, now: now) } ?? "?"
            part = "tool advisories: \(affected) with known issues, \(clean) none known, \(unknown) unknown (checked \(at))"
        }
        return Status(part: part, reasons: reasons, details: details)
    }

    static func liveStatus(now: Date = Date()) -> Status {
        let (obs, vuln) = LocalAdvisoryStore.snapshot()
        return status(setting: UpdateNoticeStore.snapshot(.live).0, policy: .effective, observation: obs, vuln: vuln, now: now)
    }
}
