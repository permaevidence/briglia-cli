import Foundation

/// §5.2, §5.3, §15 items 1 and 4: the observed-release record, replay and
/// pointer lag, renewal vs conflict, expiry, other domains; basic notice
/// behaviour and cadence.
extension UpdateNoticeSelftest {
    static func status(_ w: World) -> UpdateNoticeText.Status {
        UpdateNoticeText.status(setting: .defaultOn, state: w.s, installed: w.installed, installedVersion: "0.3.\(w.installed)",
                                domain: dom, now: w.now)
    }

    static func observationGroup(_ t: Tally) {
        obsReplay(t)
        obsUnseenOlder(t)
        obsFirstReplay(t)
        obsRenewalConflict(t)
        obsExpiry(t)
        obsDomains(t)
    }

    static func obsReplay(_ t: Tally) {
        for restartBetween in [false, true] {
            let tag = restartBetween ? " (restart between)" : ""
            var w = World(installed: 130)
            _ = w.observe(135)
            w.step()
            if restartBetween { w.restart() }
            let effect = w.observe(130)
            let after = w.step()
            t.check("4a 130→135→130\(tag): lower observation, no message", effect == .lower && after.isEmpty)
            t.check("4a\(tag): 135 kept as observed", w.s.domain(dom)?.observed?.sequence == 135)
            let st = status(w)
            t.check("4a\(tag): Security line keeps 'available', never 'up to date'", st.part.contains("0.3.135 is available") && !st.part.contains("up to date"), st.part)
            w.advance(25 * hour)
            _ = w.observe(130)
            t.check("4a\(tag): attention after 24 h of lower observations",
                    status(w).reasons.contains { $0.en.contains("older than what it already saw") })
        }
    }

    static func obsUnseenOlder(_ t: Tally) {
        for restartBetween in [false, true] {
            let tag = restartBetween ? " (restart between)" : ""
            var w = World(installed: 130)
            _ = w.observe(135, block([adv(["CVE-2026-5"], fixed: 135)]))
            w.step()
            let before = w.s.classes
            if restartBetween { w.restart() }
            _ = w.observe(133, block([adv(["CVE-2026-7"], .critical, 101, 133)]))
            t.check("4b 130→135→unseen 133 with its own metadata\(tag): no notice", w.step().isEmpty)
            t.check("4b\(tag): classes unchanged", w.s.classes == before)
        }
    }

    static func obsFirstReplay(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(133)
        let first = w.step()
        t.check("4d replay before the first observation: older valid 133 announced once (residual 1)", first.count == 1 && first[0].proposal.sequence == 133)
        w.advance(8 * day)
        _ = w.observe(135)
        let second = w.step()
        t.check("4d …a later real 135 is announced normally", second.count == 1 && second[0].proposal.sequence == 135)
        w.advance(8 * day)
        _ = w.observe(133)
        _ = w.observe(134)
        t.check("4d …nothing ≤ 135 afterwards", w.step().isEmpty)
    }

    static func obsRenewalConflict(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135)
        w.step()
        let firstExpiry = w.s.domain(dom)!.observed!.expires
        w.advance(hour)
        let e1 = w.observe(135, expiresIn: 200 * day)
        t.check("4e same sequence, same content, new expires → renewal", e1 == .renewal && w.s.domain(dom)!.observed!.expires > firstExpiry)
        let grown = w.s.domain(dom)!.observed!.expires
        _ = w.observe(135, expiresIn: 10 * day)
        t.check("4e an older still-valid envelope cannot shorten the known validity", w.s.domain(dom)!.observed!.expires == grown)
        let e2 = w.observe(135, content: "other-content")
        t.check("4e same sequence, different content → conflict, record kept, no message",
                e2 == .conflict && w.s.domain(dom)!.observed!.contentId == "content-135" && w.step().isEmpty)
        let since = w.s.domain(dom)!.inconsistentSince
        w.advance(25 * hour)
        _ = w.observe(135, content: "other-content")
        t.check("4e a repeated conflict never clears its own flag", w.s.domain(dom)!.inconsistentSince == since && since != nil)
        t.check("4e conflict attention after 24 h", status(w).reasons.contains { $0.en == "release information inconsistent" })
        _ = w.observe(134)
        t.check("4e a lower observation never clears inconsistentSince", w.s.domain(dom)!.inconsistentSince != nil)
        _ = w.observe(135)
        t.check("4e only an accepted observation (renewal) clears it", w.s.domain(dom)!.inconsistentSince == nil)
    }

    static func obsExpiry(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, expiresIn: 3 * day)
        w.step()
        // Only the installed release's manifest keeps arriving (lower).
        for _ in 0..<5 { w.advance(6 * hour); _ = w.observe(130) }
        t.check("4f residual 2: while valid older data keeps arriving and the record is valid, no stale state",
                !status(w).part.contains("cannot be confirmed"), status(w).part)
        w.advance(2 * day)
        _ = w.observe(130)
        let st = status(w)
        t.check("4f observed record expired → stale at once, never 'up to date'",
                st.part.contains("cannot be confirmed") && !st.part.contains("up to date"), st.part)
        t.check("4f expired record: no notices", w.step().isEmpty)
    }

    static func obsDomains(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(140, domain: "other-domain")
        t.check("4g observation from another trust domain ignored for this domain", w.s.domain(dom)?.observed == nil && w.step().isEmpty)
        _ = w.observe(130 + 1_000_000)
        let sent = w.step()
        t.check("4g signed sequence +10^6 → announced (the record is not a trust floor)", sent.count == 1)
        for i in 0..<6 { _ = w.observe(200, domain: "extra-\(i)") }
        t.check("4g at most 4 trust domains kept, the running one never dropped",
                w.s.domains.count == 4 && w.s.domain(dom) != nil, "\(w.s.domains.map(\.domain))")
    }

    // MARK: - Basics and cadence (§15 item 1)

    static func basicsGroup(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(131)
        t.check("1 new version → exactly one message", w.step().count == 1)
        w.advance(6 * hour)
        _ = w.observe(131)
        t.check("1 re-check of the same version → none", w.step().isEmpty)
        w.restart()
        t.check("1 restart → none (persisted)", w.step().isEmpty)
        let fresh = UpdateNoticeState()
        t.check("1 startup check wanted on a fresh install", UpdateNotice.wantsStartupCheck(fresh, now: t0))
        var s = fresh
        UpdateNotice.scheduleNextCheck(&s, now: t0, jitter: 0)
        s.lastSuccess = t0
        t.check("1 startup check skipped when lastAttempt < 1 h", !UpdateNotice.wantsStartupCheck(s, now: t0.addingTimeInterval(1800)))
        t.check("1 startup check skipped when lastSuccess < 6 h", !UpdateNotice.wantsStartupCheck(s, now: t0.addingTimeInterval(2 * hour)))
        var failing = fresh
        UpdateNotice.scheduleNextCheck(&failing, now: t0, jitter: 99_999)
        t.check("1 jitter clamped to ±30 min", failing.nextCheckAt == t0.addingTimeInterval(6 * hour + 1800))
        t.check("1 persistent failures do not shorten the interval (not due before 6 h)",
                !UpdateNotice.checkDue(failing, now: t0.addingTimeInterval(5 * hour)) && UpdateNotice.checkDue(failing, now: t0.addingTimeInterval(7 * hour)))
        var noBuild = World(installed: 130)
        _ = noBuild.observe(131, hasBuild: false)
        t.check("1 no build for this platform → no message, 'no build' line",
                noBuild.step().isEmpty && status(noBuild).part.contains("no build for this platform"))
    }

    // MARK: - Rate state machine (§15 item 3)

    static func rateGroup(_ t: Tally) {
        rateCadence(t)
        rateSecurityBreaksCadence(t)
        rateReminders(t)
        rateUpgradeAndReset(t)
    }

    static func rateCadence(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(131); w.step()
        w.advance(day); _ = w.observe(132)
        t.check("3 N1: a feature release 1 day after a notice is held", w.step().isEmpty)
        w.advance(2 * day); _ = w.observe(133)
        t.check("3 N1: still held at 3 days", w.step().isEmpty)
        w.advance(4 * day + hour); _ = w.observe(133)
        let due = w.step()
        t.check("3 N1: after 7 days one notice naming the then-current release (133)",
                due.count == 1 && due[0].proposal.sequence == 133 && due[0].text.contains("0.3.133"))
        t.check("3 N1: ≤ 1 release notice per 7 days overall", w.releaseNotices.count == 2)
    }

    static func rateSecurityBreaksCadence(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(131); w.step()
        w.advance(day); _ = w.observe(132)
        w.step()
        _ = w.observe(133, block([adv(["CVE-2026-11"], fixed: 133)]))
        let sent = w.step()
        t.check("3 new advisory → immediate security notice despite the 7-day window",
                sent.count == 1 && { if case .security = sent[0].proposal { return true }; return false }())
        t.check("3 the queued coalesced release notice is dropped (announcedThrough = 133)", w.s.announcedThrough == 133)
        w.advance(day); _ = w.observe(134, block([adv(["CVE-2026-11"], fixed: 133)]))
        w.advance(7 * day); w.confirm()
        let later = w.step()
        t.check("3 later same-fix release: plain-cadence release notice with security wording, no new security cycle",
                later.contains { if case .release(_, .recommended) = $0.proposal { return true }; return false } && w.securityNotices.count == 1,
                "\(later.map(\.proposal))")
    }

    static func rateReminders(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-21"], fixed: 135)]))
        w.step()
        let clockBefore = w.cls("CVE-2026-21")?.reminderDueAt
        w.advance(day); _ = w.observe(136, block([adv(["CVE-2026-21"], fixed: 135)]))
        t.check("3 a later same-fix release does not reset the reminder clock", w.cls("CVE-2026-21")?.reminderDueAt == clockBefore && clockBefore != nil)
        let sent = w.run(hours: 3 * 24)
        t.check("3 reminder at 3 days, sent once", w.reminders.count == 1 && sent.filter { if case .reminder = $0.proposal { return true }; return false }.count == 1)
        t.check("3 reminder names the current observed release (136)", w.reminders.first?.text.contains("0.3.136") == true)
        _ = w.run(hours: 10 * 24)
        t.check("3 never a second reminder", w.reminders.count == 1)
        // Stale cache delays; unsent after 7 days.
        var s = World(installed: 130)
        _ = s.observe(135, block([adv(["CVE-2026-22"], fixed: 135)]))
        s.step()
        s.advance(4 * day)   // no checks: lastSuccess > 48 h
        t.check("3 stale cache (> 48 h) delays the reminder", s.step().isEmpty)
        s.advance(7 * day)
        s.step()
        t.check("3 …unsent after 7 days: marked attempted without a message",
                s.reminders.isEmpty && s.cls("CVE-2026-22")?.reminderAttempted == true)
    }

    static func rateUpgradeAndReset(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(140, block([adv(["CVE-2026-31"], fixed: 135), adv(["CVE-2026-32"], fixed: 140)]))
        w.step()
        let due32 = w.cls("CVE-2026-32")?.reminderDueAt
        w.installed = 136
        w.advance(hour); w.confirm()
        let after = w.step()
        t.check("3 partial upgrade to 136: no re-announcement of announcedThrough", after.isEmpty && w.s.announcedThrough == 140)
        t.check("3 …the resolved class removed, the remaining one keeps its clock",
                w.cls("CVE-2026-31") == nil && w.cls("CVE-2026-32")?.reminderDueAt == due32)
        w.installed = 120
        w.advance(hour); w.confirm()
        w.step()
        t.check("3 installed-sequence decrease resets the tables and the watermark (fresh-state residual)",
                w.s.installedBaseline == 120 && w.sent.count >= 2)
    }
}
