import Foundation

/// §5.4.2 rule 3, §5.4.3 rule 1, §15 item 3e: the critical-floor escalation
/// (R7-1) with Codex's trace, both histories, before/after the original
/// reminder, across restart; quiet later rises; the two upgrade histories
/// split as the round-8 note asks; and a new named advisory arriving with
/// the critical floor in the same observation.
extension UpdateNoticeSelftest {
    static func floorGroup(_ t: Tally) {
        for history in ["notified", "floorOnly"] {
            for afterReminder in [false, true] {
                for restart in [false, true] { floorTrace(t, history: history, afterReminder: afterReminder, restart: restart) }
            }
        }
        floorAlreadyCritical(t)
        floorKnownCriticalRetired(t)
        floorUpgradeHistories(t)
        floorSameObservation(t)
    }

    /// installed 130; 135 recommended CVE-2026-12345 [101,135); 136 retires
    /// it (floor.recommended 135, critical 0); 137 raises floor.critical to
    /// 135 with cumulative empty.
    static func floorPrefix(history: String) -> World {
        var w = World(installed: 130)
        if history == "notified" {
            _ = w.observe(135, block([adv(["CVE-2026-12345"], fixed: 135)]))
            w.step()
            w.advance(hour)
        }
        _ = w.observe(136, block([], floorR: 135, floorC: 0))
        w.step()
        return w
    }

    static func floorTrace(_ t: Tally, history: String, afterReminder: Bool, restart: Bool) {
        let tag = " [\(history), \(afterReminder ? "after" : "before") the 3-day reminder\(restart ? ", restart" : "")]"
        var w = floorPrefix(history: history)
        let recommendedDue = w.s.classes.first?.reminderDueAt
        if afterReminder { _ = w.run(hours: 24 * 4) }
        let remindersBefore = w.reminders.count
        w.advance(hour)
        _ = w.observe(137, block([], floorR: 135, floorC: 135))
        let sent = w.step()
        let at137 = w.now
        t.check("3e 137 → one immediate critical notice\(tag)",
                sent.count == 1 && isCritical(sent[0]) && { if case .security = sent[0].proposal { return true }; return false }(),
                "\(sent.map(\.text))")
        t.check("3e …floor:critical gets the +1-day reminder\(tag)",
                w.floorCritical.map { $0.reminderDueAt.map { abs($0.timeIntervalSince(at137) - day) < 1 } ?? false } ?? false)
        t.check("3e …the pending recommended reminder is superseded\(tag)",
                w.s.classes.filter { $0.floor != .critical }.allSatisfy { $0.reminderAttempted }
                && (afterReminder || w.s.classes.contains { $0.supersededBy == "floor:critical" }))
        if restart { w.restart() }
        let later = w.run(hours: 24 * 5)
        let reminders = later.filter { if case .reminder = $0.proposal { return true }; return false }
        t.check("3e …exactly one reminder after 137, critical wording, at +1 day\(tag)",
                reminders.count == 1 && isCritical(reminders[0]) && abs(reminders[0].at.timeIntervalSince(at137) - day) <= hour,
                "\(reminders.map(\.at))")
        if !afterReminder, let due = recommendedDue {
            t.check("3e …no message at the old day-3 deadline\(tag)",
                    !later.contains { abs($0.at.timeIntervalSince(due)) <= hour && { if case .reminder = $0.proposal { return true }; return false }($0) })
        }
        t.check("3e …two reminders at most in total (the recommended one only if it had already gone)\(tag)",
                w.reminders.count == remindersBefore + 1)
        w.advance(hour)
        _ = w.observe(138, block([], floorR: 135, floorC: 137))
        let quiet = w.run(hours: 24 * 4)
        t.check("3e 138 raises floor.critical to 137 → no security notice, no reminder (state-only fixedIn raise)\(tag)",
                !quiet.contains { if case .release = $0.proposal { return false }; return true } && w.floorCritical?.fixedIn == 137)
    }

    static func floorAlreadyCritical(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-777"], .critical, 101, 135)]))
        w.step()
        w.advance(hour)
        _ = w.observe(137, block([adv(["CVE-2026-777"], .critical, 101, 135)], floorR: 135, floorC: 135))
        t.check("3e client already notified critical by a named entry → 137's critical floor is not news",
                w.step().isEmpty && w.floorCritical == nil)
    }

    static func floorKnownCriticalRetired(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-778"], .critical, 101, 135)]))
        w.step()
        w.advance(hour)
        _ = w.observe(136, block([], floorR: 135, floorC: 135))
        t.check("3e a known critical named entry retired into the critical floor → no notice", w.step().isEmpty)
    }

    /// Round-8 note 3: two independent histories.
    static func floorUpgradeHistories(_ t: Tally) {
        // (A) 138 raised floor:critical's fixedIn to 137: upgrading to 136
        // does not resolve it, so a later floor 140 only extends it quietly.
        var a = floorPrefix(history: "notified")
        a.advance(hour); _ = a.observe(137, block([], floorR: 135, floorC: 135)); a.step()
        a.advance(hour); _ = a.observe(138, block([], floorR: 135, floorC: 137)); a.step()
        a.installed = 136
        a.advance(hour); a.confirm(); a.step()
        let before = a.securityNotices.count
        a.advance(hour); _ = a.observe(140, block([], floorR: 135, floorC: 140))
        let sentA = a.step()
        t.check("3e (A) upgrade to 136 below floor:critical 137 keeps the class; floor 140 is quiet",
                a.floorCritical != nil && a.floorCritical?.fixedIn == 140 && a.securityNotices.count == before
                && !sentA.contains { if case .security = $0.proposal { return true }; return false })
        // (B) the last recorded critical fixedIn was 135: upgrading to 136
        // removes every critical class; floor 140 is true news for 136.
        var b = floorPrefix(history: "notified")
        b.advance(hour); _ = b.observe(137, block([], floorR: 135, floorC: 135)); b.step()
        b.installed = 136
        b.advance(hour); b.confirm(); b.step()
        t.check("3e (B) upgrade to 136 resolves floor:critical 135", b.floorCritical == nil)
        b.advance(hour); _ = b.observe(140, block([], floorR: 135, floorC: 140))
        let sentB = b.step()
        t.check("3e (B) later critical floor 140 above the new install → one critical notice",
                sentB.count == 1 && isCritical(sentB[0]))
    }

    static func floorSameObservation(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-901"], fixed: 135)]))
        w.step()
        w.advance(hour)
        _ = w.observe(137, block([adv(["CVE-2026-902"], fixed: 137)], floorR: 0, floorC: 135))
        let sent = w.step()
        let at = w.now
        t.check("3e new named advisory + floor:critical in one observation → one critical notice",
                sent.count == 1 && isCritical(sent[0]))
        t.check("3e …only floor:critical keeps a pending reminder (new named class created superseded)",
                w.s.classes.filter { !$0.reminderAttempted }.map(\.floor) == [.critical]
                && w.cls("CVE-2026-902")?.supersededBy == "floor:critical")
        let later = w.run(hours: 24 * 5)
        let r = later.filter { if case .reminder = $0.proposal { return true }; return false }
        t.check("3e …a single replacement deadline: one reminder at +1 day", r.count == 1 && abs(r[0].at.timeIntervalSince(at) - day) <= hour)
    }
}
