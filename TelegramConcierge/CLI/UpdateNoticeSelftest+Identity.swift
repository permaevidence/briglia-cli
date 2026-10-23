import Foundation

/// §5.4.2, §15 items 3a (identity across releases) and 3c (client side of
/// the no-reintroduction rule).
extension UpdateNoticeSelftest {
    static func identityGroup(_ t: Tally) {
        for restart in [false, true] { identityAlias(t, restart: restart, afterDue: false); identityAlias(t, restart: restart, afterDue: true) }
        identityLink(t)
        identityRetire(t)
        identityPartialUpgrade(t)
        identityEscalation(t)
    }

    static func identityAlias(_ t: Tally, restart: Bool, afterDue: Bool) {
        let tag = " (\(afterDue ? "after" : "before") due\(restart ? ", restart" : ""))"
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-100"], fixed: 135)]))
        w.step()
        let due = w.cls("CVE-2026-100")?.reminderDueAt
        if afterDue { _ = w.run(hours: 73) }
        let remindersBefore = w.reminders.count
        if restart { w.restart() }
        w.advance(hour)
        _ = w.observe(136, block([adv(["CVE-2026-100", "GHSA-yyyy-1111-2222"], fixed: 135)]))
        var sent = w.step()
        t.check("3a alias GHSA added in 136\(tag): no security notice", !sent.contains { if case .security = $0.proposal { return true }; return false })
        t.check("3a …original due time and attempted flag kept\(tag)",
                w.cls("GHSA-yyyy-1111-2222")?.reminderDueAt == due && w.cls("CVE-2026-100")?.reminderAttempted == afterDue)
        w.advance(hour)
        _ = w.observe(137, block([adv(["GHSA-yyyy-1111-2222", "CVE-2026-100"], fixed: 135)]))
        sent = w.step()
        t.check("3a preferred ID changes to the GHSA\(tag): same advisory, no notice", w.securityNotices.count == 1 && w.s.classes.count == 1)
        _ = w.run(hours: 24 * 10)
        t.check("3a exactly one reminder in total\(tag)", w.reminders.count == 1 && (afterDue ? remindersBefore == 1 : true))
    }

    static func identityLink(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-201"], fixed: 135)]))
        w.step()
        let firstDue = w.cls("CVE-2026-201")!.reminderDueAt!
        w.advance(day)
        _ = w.observe(136, block([adv(["CVE-2026-201"], fixed: 135), adv(["GHSA-aaaa-bbbb-0001"], fixed: 136)]))
        w.step()
        t.check("3a two advisories notified separately → two classes", w.s.classes.count == 2 && w.securityNotices.count == 2)
        w.advance(hour)
        _ = w.observe(137, block([adv(["CVE-2026-201", "GHSA-aaaa-bbbb-0001"], fixed: 136)]))
        t.check("3a later linked by an alias → merged into one class at the earliest due time",
                w.s.classes.count == 1 && w.s.classes[0].reminderDueAt == firstDue, "\(w.s.classes)")
        _ = w.run(hours: 24 * 9)
        t.check("3a …one reminder", w.reminders.count == 1)
    }

    static func identityRetire(_ t: Tally) {
        for attemptedFirst in [false, true] {
            var w = World(installed: 130)
            _ = w.observe(135, block([adv(["CVE-2026-301"], fixed: 135)]))
            w.step()
            let due = w.cls("CVE-2026-301")!.reminderDueAt!
            if attemptedFirst { _ = w.run(hours: 73) }
            w.advance(hour)
            _ = w.observe(136, block([], floorR: 135))
            let sent = w.step()
            t.check("3a retired into floor:recommended (\(attemptedFirst ? "after" : "before") the reminder): no floor notice, no new class",
                    !sent.contains { if case .security = $0.proposal { return true }; return false } && w.floorRecommended == nil)
            _ = w.run(hours: 24 * 9)
            t.check("3a …reminder sent exactly once\(attemptedFirst ? "" : " at the original time")",
                    w.reminders.count == 1 && (attemptedFirst || abs(w.reminders[0].at.timeIntervalSince(due)) <= hour))
        }
    }

    static func identityPartialUpgrade(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(140, block([adv(["CVE-2026-401"], fixed: 133), adv(["CVE-2026-402"], fixed: 140)]))
        w.step()
        w.installed = 134
        w.advance(hour); w.confirm()
        t.check("3a partial upgrade resolving one advisory: no new cycle", w.step().isEmpty && w.s.classes.count == 1)
        _ = w.run(hours: 24 * 9)
        t.check("3a …the open one is reminded once", w.reminders.count == 1)
    }

    static func identityEscalation(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-501"], fixed: 135)]))
        w.step()
        _ = w.run(hours: 73)
        t.check("3a recommended reminder sent", w.reminders.count == 1)
        w.advance(hour)
        _ = w.observe(136, block([adv(["CVE-2026-501"], .critical, 101, 135)]))
        let sent = w.step()
        t.check("3a escalation to critical → one immediate critical notice", sent.count == 1 && isCritical(sent[0]))
        let due = w.cls("CVE-2026-501")?.reminderDueAt
        t.check("3a …with a 1-day reminder", due.map { abs($0.timeIntervalSince(w.now) - day) < 1 } ?? false)
        _ = w.run(hours: 24 * 10)
        _ = w.observe(137, block([adv(["CVE-2026-501"], .critical, 101, 135)]))
        _ = w.run(hours: 24 * 5)
        t.check("3a never a third reminder (one after the escalation)", w.reminders.count == 2 && w.securityNotices.count == 2)
    }

    // MARK: - 3c client side (hand-built manifests bypassing the tooling)

    static func reintroductionClientGroup(_ t: Tally) {
        // Without the publication rule the client WOULD repeat: the reason the rule exists.
        var naive = World(installed: 130)
        _ = naive.observe(135, block([adv(["CVE-2026-12345"], fixed: 135)]))
        naive.step()
        naive.advance(day); _ = naive.observe(136, block([], floorR: 135))
        naive.advance(day); _ = naive.observe(137, block([adv(["GHSA-only-reintro"], fixed: 135)], floorR: 135))
        t.check("3c hand-built 137 re-adding the retired fix as GHSA only → a second notice (why the tooling refuses it)",
                naive.step().contains { if case .security = $0.proposal { return true }; return false })
        for history in ["notified", "floorOnly"] {
            for afterDue in [false, true] {
                for restart in [false, true] {
                    reintroCompliant(t, history: history, afterDue: afterDue, restart: restart)
                }
            }
        }
        var corr = World(installed: 136)
        _ = corr.observe(136, block([], floorR: 135))
        corr.advance(day)
        _ = corr.observe(138, block([adv(["CVE-2026-12345"], fixed: 138)], floorR: 135))
        _ = corr.step()
        corr.advance(hour)
        _ = corr.observe(139, block([adv(["CVE-2026-12345"], fixed: 138)], floorR: 135))
        t.check("3c above-floor re-entry (range correction) → news exactly once for a client it newly concerns",
                corr.securityNotices.count == 1 && corr.step().isEmpty)
    }

    /// Published 135 → 136 (retired into floor 135) → 138 (feature release,
    /// keeps the floor, does not reintroduce).
    static func reintroCompliant(_ t: Tally, history: String, afterDue: Bool, restart: Bool) {
        let tag = " [\(history), \(afterDue ? "after" : "before") due\(restart ? ", restart" : "")]"
        var w = World(installed: 130)
        if history == "notified" {
            _ = w.observe(135, block([adv(["CVE-2026-12345"], fixed: 135)]))
            w.step()
            w.advance(day)
        }
        _ = w.observe(136, block([], floorR: 135))
        w.step()
        let due = w.s.classes.first?.reminderDueAt
        if afterDue { _ = w.run(hours: 24 * 4) }
        if restart { w.restart() }
        w.advance(hour)
        _ = w.observe(138, block([], floorR: 135))
        _ = w.run(hours: 24 * 8)
        t.check("3c compliant 138\(tag): one security notice, one reminder in total",
                w.securityNotices.count == 1 && w.reminders.count == 1, "\(w.sent.map(\.proposal))")
        t.check("3c …original deadline kept\(tag)", w.s.classes.first?.reminderDueAt == due)
    }
}
