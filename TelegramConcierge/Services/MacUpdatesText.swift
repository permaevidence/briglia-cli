import Foundation

/// Wording of the macOS weekly message and its Security-line part (§9.5.9).
/// Compiled templates; the only variable parts are names read from this Mac
/// (validated) and versions from Homebrew's catalogue. It states that an
/// update is available — never "vulnerable", "safe", a fix or a CVE.
enum MacUpdatesText {
    static func L(_ lang: String, _ en: String, _ it: String) -> String { lang == "it" ? it : en }

    static func names(_ items: [MacUpdates.Item], lang: String) -> String {
        var n: [String] = []
        for i in items where !n.contains(i.name) { n.append(i.name) }
        let shown = n.prefix(MacUpdates.maxNamed).joined(separator: ", ")
        return n.count > MacUpdates.maxNamed ? shown + L(lang, " and \(n.count - MacUpdates.maxNamed) more", " e altri \(n.count - MacUpdates.maxNamed)") : shown
    }

    /// `brew upgrade a b && brew upgrade --cask c` from validated names (≤ 20).
    static func command(_ items: [MacUpdates.Item]) -> (String, Int)? {
        let formulae = items.filter { $0.kind == .formula }.compactMap(\.command).filter(LocalTools.validBrewName)
        let casks = items.filter { $0.kind == .cask }.compactMap(\.command).filter(LocalTools.validBrewName)
        var f: [String] = [], c: [String] = []
        for x in formulae where !f.contains(x) { f.append(x) }
        for x in casks where !c.contains(x) { c.append(x) }
        let total = f.count + c.count
        guard total > 0 else { return nil }
        let keepF = Array(f.prefix(MacUpdates.maxCommandNames))
        let keepC = Array(c.prefix(max(0, MacUpdates.maxCommandNames - keepF.count)))
        var parts: [String] = []
        if !keepF.isEmpty { parts.append("brew upgrade " + keepF.joined(separator: " ")) }
        if !keepC.isEmpty { parts.append("brew upgrade --cask " + keepC.joined(separator: " ")) }
        return (parts.joined(separator: " && "), total - keepF.count - keepC.count)
    }

    static func message(_ waiting: [MacUpdates.Item], lang: String) -> String {
        let brew = waiting.filter { $0.kind == .formula || $0.kind == .cask }
        let apps = waiting.filter { $0.kind == .app }
        let macos = waiting.filter { $0.kind == .macos }
        var lines: [String] = []
        if !brew.isEmpty {
            var s = L(lang, "⬆️ Updates are waiting for tools Briglia runs on untrusted files (\(names(brew, lang: lang)))",
                      "⬆️ Ci sono aggiornamenti in attesa per strumenti che Briglia usa su file non affidabili (\(names(brew, lang: lang)))")
            if let (cmd, more) = command(brew) {
                s += ": `\(cmd)`" + L(lang, " (or ask me to run it).", " (oppure chiedimi di farlo).")
                if more > 0 { s += L(lang, " …and \(more) more: see /status.", " …e altri \(more): vedi /status.") }
            } else {
                s += "."
            }
            lines.append(s)
        }
        for a in apps {
            let inst = a.installed ?? "?"
            let lead = brew.isEmpty ? "⬆️ " : ""
            lines.append(lead + L(lang,
                "LibreOffice \(inst) (installed from libreoffice.org): a newer version is available\(a.available.map { " (\($0))" } ?? ""). In LibreOffice choose Help → Check for Updates, or download it from https://www.libreoffice.org/download/.",
                "LibreOffice \(inst) (installato da libreoffice.org): è disponibile una versione più recente\(a.available.map { " (\($0))" } ?? ""). In LibreOffice scegli Aiuto → Controlla aggiornamenti, oppure scaricalo da https://www.libreoffice.org/download/."))
        }
        if !macos.isEmpty {
            let only = brew.isEmpty && apps.isEmpty
            let what = names(macos, lang: lang)
            lines.append(only
                ? L(lang, "⬆️ macOS has updates waiting (\(what)): System Settings → General → Software Update.",
                    "⬆️ macOS ha aggiornamenti in attesa (\(what)): Impostazioni di Sistema → Generali → Aggiornamento Software.")
                : L(lang, "macOS also has updates waiting (\(what)): System Settings → General → Software Update.",
                    "Anche macOS ha aggiornamenti in attesa (\(what)): Impostazioni di Sistema → Generali → Aggiornamento Software."))
        }
        guard !lines.isEmpty else { return "" }
        lines.append(L(lang, "Briglia never installs these itself. /upgradecheck off stops these messages.",
                       "Briglia non li installa mai da solo. /upgradecheck off disattiva questi messaggi."))
        return UpdateNotice.capped(lines.joined(separator: "\n"), bytes: 3800)
    }

    // MARK: - Security line

    static func status(setting: UpdateNoticeStore.SettingRead, state: MacUpdatesState?, now: Date) -> LocalToolsText.Status {
        guard setting.enabled else {
            return .init(part: "Homebrew/app updates: check off", reasons: [],
                         details: ["Weekly 'updates are waiting' message: off (it shares /upgradecheck)"])
        }
        guard let e = state?.report else {
            return .init(part: "Homebrew/app updates: not checked yet", reasons: [], details: [])
        }
        var details: [String] = []
        for t in e.tools {
            let v = t.installed.map { " \($0)" } ?? ""
            let src = t.kind == .cask ? " (Homebrew cask)" : t.kind == .app ? " (libreoffice.org)" : t.kind == .formula ? " (Homebrew)" : ""
            switch t.state {
            case .waiting:
                let how: String = {
                    switch t.kind {
                    case .formula?: return t.command.map { " — `brew upgrade \($0)`" } ?? ""
                    case .cask?: return t.command.map { " — `brew upgrade --cask \($0)`" } ?? ""
                    case .app?: return " — Help → Check for Updates"
                    default: return ""
                    }
                }()
                details.append("\(t.name)\(v)\(src): update waiting" + (t.available.map { " → \($0)" } ?? "") + how)
            case .current:
                let when = e.catalogueAsOf.map { UpdateNoticeText.day($0) } ?? "?"
                switch t.kind {
                case .app?:
                    details.append("\(t.name)\(v)\(src): no newer release in Homebrew's LibreOffice reference versions (catalogue \(when))")
                case .cask? where t.reason != nil:
                    details.append("\(t.name)\(v)\(src): \(t.reason!.en) (Homebrew does not upgrade it)")
                default:
                    details.append("\(t.name)\(v)\(src): matches Homebrew's current version (catalogue \(when))")
                }
            case .pinned:
                details.append("\(t.name)\(v)\(src): pinned in Homebrew (`brew upgrade` skips it)")
            case .unknown:
                details.append("\(t.name)\(v)\(src): unknown" + (t.reason.map { " — \($0.en)" } ?? ""))
            }
        }
        for m in e.waiting where m.kind == .macos { details.append("macOS: \(m.name) waiting (Software Update)") }
        for p in e.problems { details.append("Homebrew/macOS updates: " + p.en) }
        if let o = state?.lastOutcome {
            details.append("Last 'updates are waiting' message: " + (o.outcome == .accepted ? "sent" : "may not have arrived (\(o.outcome.rawValue))")
                           + " \(SecurityStatus.age(o.at, now: now))")
        }
        let n = e.waiting.count
        let age = e.catalogueAsOf.map { SecurityStatus.age($0, now: now) } ?? "no catalogue"
        let part: String
        if now.timeIntervalSince(e.at) > MacUpdates.freshness || e.at.timeIntervalSince(now) > MacUpdates.futureSkew {
            // Impl round-1 note: an obsolete evaluation is never a current conclusion.
            part = "Homebrew/app updates: unknown (last checked \(SecurityStatus.age(e.at, now: now)))"
        } else if !e.complete {
            part = "Homebrew/app updates: \(n) waiting, some unknown (catalogue \(age))"
        } else {
            part = n == 0 ? "Homebrew/app updates: none waiting (catalogue \(age))" : "Homebrew/app updates: \(n) waiting (catalogue \(age))"
        }
        return .init(part: part, reasons: [], details: details)
    }

    static func liveStatus(now: Date = Date()) -> LocalToolsText.Status {
        status(setting: UpdateNoticeStore.snapshot(.live).0, state: MacUpdatesStore.snapshot(), now: now)
    }
}
