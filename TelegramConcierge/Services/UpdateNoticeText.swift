import Foundation

/// Wording of the update-available notice (§5.4.5) and its Security-line
/// states (§5.3, §8.1). English and Italian; pure.
enum UpdateNoticeText {
    enum Surface { case chat, app, terminal }

    static func L(_ lang: String, _ en: String, _ it: String) -> String { lang == "it" ? it : en }

    private static func action(_ lang: String, _ surface: Surface, soon: Bool) -> String {
        switch (surface, soon) {
        case (.app, false): return L(lang, "Send /upgrade or tap Update in the app to install.", "Invia /upgrade o tocca Aggiorna nell'app per installarla.")
        case (.app, true): return L(lang, "Please send /upgrade or tap Update in the app soon.", "Invia /upgrade o tocca Aggiorna nell'app appena puoi.")
        case (_, false): return L(lang, "Send /upgrade to install.", "Invia /upgrade per installarla.")
        case (_, true): return L(lang, "Please send /upgrade soon.", "Invia /upgrade appena puoi.")
        }
    }

    /// The message for a proposal, named for `version` (the observed release
    /// at consume time). `summary` is the signed plain-text line, if any.
    static func message(_ p: UpdateNotice.Proposal, version: String, critical: Bool, summary: String?,
                        lang: String, surface: Surface) -> String {
        var text: String
        switch p {
        case .security(_, let analysis):
            text = analysis.anyCritical
                ? L(lang, "Briglia \(version) includes an important security fix for your version.",
                    "Briglia \(version) contiene una correzione di sicurezza importante per la tua versione.") + " " + action(lang, surface, soon: true)
                : L(lang, "Briglia \(version) is available and includes security fixes for your version.",
                    "È disponibile Briglia \(version), con correzioni di sicurezza per la tua versione.") + " " + action(lang, surface, soon: false)
        case .release(_, let classification):
            switch classification {
            case .critical:
                text = L(lang, "Briglia \(version) includes an important security fix for your version.",
                         "Briglia \(version) contiene una correzione di sicurezza importante per la tua versione.") + " " + action(lang, surface, soon: true)
            case .recommended:
                text = L(lang, "Briglia \(version) is available and includes security fixes for your version.",
                         "È disponibile Briglia \(version), con correzioni di sicurezza per la tua versione.") + " " + action(lang, surface, soon: false)
            case .none, .noneKnown, .unknown:
                return L(lang, "Briglia \(version) is available.", "È disponibile Briglia \(version).") + " " + action(lang, surface, soon: false)
            }
        case .reminder:
            text = critical
                ? L(lang, "Reminder: Briglia \(version), with an important security fix for your version, is not installed yet.",
                    "Promemoria: Briglia \(version), con una correzione di sicurezza importante per la tua versione, non è ancora installata.") + " " + action(lang, surface, soon: true)
                : L(lang, "Reminder: Briglia \(version), with security fixes for your version, is not installed yet.",
                    "Promemoria: Briglia \(version), con correzioni di sicurezza per la tua versione, non è ancora installata.") + " " + action(lang, surface, soon: false)
            text += " " + L(lang, "(This is the only reminder.)", "(È l'unico promemoria.)")
            return text
        }
        if let line = ReleaseSecurity.plainSummary(summary) { text += "\n" + line }
        return text
    }

    // MARK: - Security line (§5.3 precedence, §8.1)

    struct Status: Equatable {
        /// Part of the one-line summary.
        var part: String
        var reasons: [SecurityStatus.Reason]
        /// Doctor / `/upgradecheck` detail lines.
        var details: [String]
    }

    static func age(_ date: Date?, now: Date) -> String { SecurityStatus.age(date, now: now) }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// `saveFailed`: the last consume write failed in this process.
    static func status(setting: UpdateNoticeStore.SettingRead, state: UpdateNoticeState?, installed: Int,
                       installedVersion: String, domain: String, now: Date, saveFailed: Bool = false) -> Status {
        var reasons: [SecurityStatus.Reason] = []
        var details: [String] = []
        func reason(_ en: String, _ it: String) { reasons.append(SecurityStatus.Reason(en: en, it: it)) }
        let part: String
        let s = state ?? UpdateNoticeState()
        let record = s.domain(domain)
        let observed = record?.observed
        if case .unreadable = setting {
            part = "update checks: OFF (setting unreadable)"
            reason("update check setting unreadable; send /upgradecheck on to re-enable",
                   "impostazione del controllo aggiornamenti illeggibile; invia /upgradecheck on per riattivarlo")
        } else if !setting.enabled {
            part = "update checks: off"
            reason("update checks are off (/upgradecheck on)", "controllo aggiornamenti disattivato (/upgradecheck on)")
        } else if s.lastSuccess == nil {
            part = "update check: never succeeded yet"
            reason("the update check has not succeeded yet", "il controllo aggiornamenti non è ancora riuscito")
        } else if let success = s.lastSuccess, now.timeIntervalSince(success) > UpdateNotice.freshness {
            part = "update check stale (last success \(age(success, now: now)))"
            reason("update check stale (last success \(age(success, now: now)))",
                   "controllo aggiornamenti non recente (ultimo riuscito \(age(success, now: now)))")
        } else if let o = observed, o.expires <= now {
            part = "Briglia \(o.version) was seen on \(day(o.firstSeenAt)); current release information cannot be confirmed"
            reason("release information expired (stale)", "informazioni sulla versione scadute (non aggiornate)")
        } else if let o = observed, o.sequence > installed, !o.hasBuild {
            part = "Briglia \(o.version) published; no build for this platform yet"
        } else if let o = observed, o.sequence > installed {
            let c = ReleaseSecurity.classify(o.security.parsed, installed: installed)
            part = "Briglia \(o.version) is available\(c.includesSecurityFixes ? " (includes security fixes)" : ""). Send /upgrade to install."
            if c.includesSecurityFixes, now.timeIntervalSince(o.firstSeenAt) > 7 * 86_400 {
                reason("Briglia \(o.version) with security fixes has been waiting more than 7 days — send /upgrade",
                       "Briglia \(o.version) con correzioni di sicurezza attende da più di 7 giorni: invia /upgrade")
            }
            if c == .unknown {
                reason("the security information of Briglia \(o.version) could not be read",
                       "le informazioni di sicurezza di Briglia \(o.version) non sono leggibili")
            }
        } else if observed != nil {
            part = "binary up to date (checked \(age(s.lastSuccess, now: now)))"
        } else {
            part = "no release information yet"
            reason("no verified release information yet", "nessuna informazione verificata sulle versioni")
        }
        if setting.enabled, let r = record {
            if let since = r.lowerSince, now.timeIntervalSince(since) > UpdateNotice.attentionAfter {
                reason("the release information Briglia receives is older than what it already saw (GitHub may be lagging, or the check is being replayed)",
                       "le informazioni ricevute sono più vecchie di quelle già viste (GitHub potrebbe essere in ritardo, o il controllo viene ripetuto)")
            }
            if let since = r.inconsistentSince, now.timeIntervalSince(since) > UpdateNotice.attentionAfter {
                reason("release information inconsistent", "informazioni sulla versione incoerenti")
            }
        }
        if s.saturated != nil {
            reason("many security fixes are waiting for your version; send /upgrade",
                   "molte correzioni di sicurezza attendono la tua versione: invia /upgrade")
        }
        if saveFailed {
            reason("update state cannot be saved", "lo stato degli aggiornamenti non può essere salvato")
        }
        details.append("update checks: \(setting.enabled ? "on — every 6 hours Briglia downloads the signed release manifest from GitHub (reveals this machine's IP address and timing); it never installs anything by itself" : "off — no requests")")
        details.append("last successful check: \(s.lastSuccess.map { age($0, now: now) } ?? "never")" + (s.lastCheckProblem.map { "; last problem: \($0)" } ?? ""))
        if let o = observed {
            details.append("newest release seen: \(o.version) (sequence \(o.sequence), first seen \(day(o.firstSeenAt)), information valid until \(day(o.expires)))")
        }
        if let out = s.lastOutcome {
            let word: String
            switch out.outcome {
            case .accepted: word = "sent"
            case .refused: word = "refused by the channel"
            case .ambiguous, .lost, .inFlight: word = "may not have arrived"
            case .dropped: word = "not sent (channel changed)"
            }
            details.append("last update notice (\(out.kind.rawValue)) \(age(out.at, now: now)): \(word)")
        }
        let pending = s.classes.filter { !$0.reminderAttempted && $0.reminderDueAt != nil }.compactMap(\.reminderDueAt).min()
        if let due = pending { details.append("one security reminder is scheduled for \(day(due))") }
        _ = installedVersion
        return Status(part: part, reasons: reasons, details: details)
    }
}
