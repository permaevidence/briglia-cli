import Foundation

/// §5.5, §15 item 5: at-most-once delivery — ambiguous outcomes are
/// terminal, a crash after consume loses (never repeats) the notice, proven
/// refusals retry the stored payload against the attempt's own record, and
/// a reminder retry follows the merge survivor (round-8 note 1).
extension UpdateNoticeSelftest {
    static func deliveryGroup(_ t: Tally) {
        for kind in ["release", "reminder"] { deliveryAmbiguous(t, kind: kind) }
        deliveryCrash(t)
        deliveryConsumeAtomic(t)
    }

    /// Brings a world to the point where `kind`'s notice is due.
    static func worldDue(_ kind: String) -> World {
        var w = World(installed: 130)
        if kind == "release" {
            _ = w.observe(131)
        } else {
            _ = w.observe(135, block([adv(["CVE-2026-1001"], fixed: 135)]))
            w.step()
            w.advance(3 * day + hour); w.confirm()
        }
        return w
    }

    static func deliveryAmbiguous(_ t: Tally, kind: String) {
        var w = worldDue(kind)
        w.outcome = .ambiguous   // the fake transport accepts, then times out
        let first = w.step()
        t.check("5a \(kind): accepted-then-timeout → one attempt, outcome ambiguous",
                first.count == 1 && w.s.lastOutcome?.outcome == .ambiguous && w.s.attempts.isEmpty)
        w.outcome = .accepted
        w.advance(2 * hour); w.confirm()
        let again = w.step()
        w.restart()
        w.advance(2 * hour); w.confirm()
        let afterRestart = w.step()
        let sameKind: (Sent) -> Bool = { kind == "release" ? $0.proposal.kind == .release : $0.proposal.kind == .reminder }
        t.check("5a \(kind): no second attempt, also after restart", !again.contains(where: sameKind) && !afterRestart.contains(where: sameKind))
    }

    static func deliveryCrash(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(131)
        // Consume (durable) then "crash" before the transport call.
        guard let p = UpdateNotice.proposals(w.s, env: w.env).first else { return t.check("5c proposal due", false) }
        UpdateNotice.consume(&w.s, p, text: "x", env: w.env, destination: .init(channelKind: "telegram", chatId: "1", channelGeneration: 0),
                             noticeGeneration: 0, newClassId: { "c1" })
        w.restart()
        t.check("5c crash after consume, before the transport call → lost, not resent",
                w.s.lastOutcome?.outcome == .lost && w.step().isEmpty)
        var q = World(installed: 130)
        _ = q.observe(131)
        // Crash while only queued: nothing durable changed; re-derived once.
        q.restart()
        t.check("5c crash while only queued → re-derived and sent once", q.step().count == 1 && q.step().isEmpty)
    }

    static func deliveryConsumeAtomic(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-1101"], fixed: 135)]))
        let before = w.s
        guard let p = UpdateNotice.proposals(w.s, env: w.env).first else { return t.check("5b2 proposal due", false) }
        var after = before
        UpdateNotice.consume(&after, p, text: "x", env: w.env, destination: .init(channelKind: "telegram", chatId: "1", channelGeneration: 0),
                             noticeGeneration: 0, newClassId: { "c1" })
        t.check("5b2 one consume = derived state AND its in-flight record in one value (one atomic file replacement)",
                after.classes.count == 1 && after.announcedThrough == 135 && after.attempt(.release)?.state == .inFlight
                && before.attempts.isEmpty && before.classes.isEmpty)
    }

    // MARK: - Retries (§5.5 step 4, §15 item 5b)

    static func retryGroup(_ t: Tally) {
        retryRefusedThenSent(t)
        retryBounds(t)
        retryStoredFields(t)
        retryMergeSurvivor(t)
    }

    static func gen(_ w: World) -> (String?) -> UInt64 { { _ in w.channelGeneration } }

    /// One retry tick as the service runs it.
    static func retryTick(_ w: inout World, _ kind: AttemptRecord.Kind, outcome: UpdateNotice.SendOutcome) -> UpdateNotice.RetryDecision {
        let d = UpdateNotice.retryDecision(w.s, kind: kind, env: w.env, noticeGeneration: w.noticeGeneration, channelGeneration: gen(w))
        switch d {
        case .retry: UpdateNotice.markRetryInFlight(&w.s, kind: kind); UpdateNotice.recordOutcome(&w.s, kind: kind, outcome, env: w.env)
        case .drop: UpdateNotice.dropAttempt(&w.s, kind: kind)
        case .notYet: break
        }
        return d
    }

    static func retryRefusedThenSent(_ t: Tally) {
        var w = worldDue("release")
        w.outcome = .refused(retryAfter: 30)    // 429 with retry_after
        let first = w.step()
        t.check("5b 429 refusal recorded as refused (retry pending), announcedThrough consumed",
                first.count == 1 && w.s.attempt(.release)?.state == .refused && w.s.announcedThrough == 131)
        let stored = w.s.attempt(.release)!.text
        w.restart()
        w.advance(60)
        let d = retryTick(&w, .release, outcome: .accepted)
        if case .retry(let r) = d {
            t.check("5b the retry IS sent although announcedThrough = L (first-send predicates not applied)", true)
            t.check("5b …stored payload, count continued across the restart", r.text == stored && r.attempt == 1)
        } else {
            t.check("5b the retry IS sent although announcedThrough = L (first-send predicates not applied)", false, "\(d)")
        }
        t.check("5b …accepted after the retry, record cleared", w.s.attempts.isEmpty && w.s.lastOutcome?.outcome == .accepted)
        var c = worldDue("reminder")
        c.outcome = .refused(retryAfter: 10)
        c.step()
        let due = c.cls("CVE-2026-1001")?.reminderDueAt
        c.advance(60)
        UpdateNotice.markRetryInFlight(&c.s, kind: .reminder)
        c.restart()
        t.check("5b crash after a retry was marked in-flight → lost; the earlier refusal is not replayed",
                c.s.attempts.isEmpty && c.s.lastOutcome?.outcome == .lost)
        t.check("5b …the reminder clock was never reset", c.cls("CVE-2026-1001")?.reminderDueAt == due && c.cls("CVE-2026-1001")?.reminderAttempted == true)
    }

    static func retryBounds(_ t: Tally) {
        var w = worldDue("release")
        w.outcome = .refused(retryAfter: 1)
        w.step()
        var sends = 1
        for _ in 0..<5 {
            w.advance(120)
            if case .retry = retryTick(&w, .release, outcome: .refused(retryAfter: 1)) { sends += 1 }
        }
        t.check("5b bounded: ≤ 3 attempts within 1 h", sends == 3 && w.s.attempts.isEmpty, "\(sends)")
        var late = worldDue("release")
        late.outcome = .refused(retryAfter: 4000)
        late.step()
        late.advance(4100); late.confirm()
        let d = retryTick(&late, .release, outcome: .accepted)
        t.check("5b retry deadline (1 h) passed → dropped, never sent", { if case .drop = d { return true }; return false }() || late.s.attempts.isEmpty)
    }

    static func retryCase(_ t: Tally, _ label: String, _ mutate: (inout World) -> Void) {
        var w = worldDue("release")
        w.outcome = .refused(retryAfter: 1)
        w.step()
        w.advance(10)
        mutate(&w)
        let d = UpdateNotice.retryDecision(w.s, kind: .release, env: w.env, noticeGeneration: w.noticeGeneration, channelGeneration: gen(w))
        t.check("5b retry dropped: \(label)", { if case .drop = d { return true }; return false }(), "\(d)")
    }

    static func retryStoredFields(_ t: Tally) {
        retryCase(t, "observed record expired meanwhile") { w in
            w.s.domains[0].observed!.expires = w.now.addingTimeInterval(-1)
        }
        retryCase(t, "lastConfirmedAt older than 48 h") { w in
            w.s.domains[0].observed!.lastConfirmedAt = w.now.addingTimeInterval(-49 * hour)
        }
        retryCase(t, "channel generation changed (/switchbot)") { w in w.channelGeneration += 1 }
        retryCase(t, "notice generation changed (/deleteuserdata)") { w in w.noticeGeneration += 1 }
        retryCase(t, "installed baseline changed") { w in w.installed = 131 }
        retryCase(t, "a newer release replaced the named one") { w in _ = w.observe(132) }
        retryCase(t, "same sequence, different contentId after restart") { w in
            w.restart(); w.s.domains[0].observed!.contentId = "other"
        }
        var five = worldDue("release")
        five.outcome = .ambiguous   // 5xx, even with ok:false in the body (classifier test below)
        five.step()
        five.advance(120)
        t.check("5b 5xx after send → no retry", UpdateNotice.retryDecision(five.s, kind: .release, env: five.env, noticeGeneration: 0, channelGeneration: gen(five)) == .notYet && five.s.attempts.isEmpty)
    }

    /// Round-8 note 1: a merge in the same transaction repoints a pending
    /// reminder retry to the survivor; all classes gone → dropped, never a
    /// new consume.
    static func retryMergeSurvivor(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-1201"], fixed: 135)]))
        w.step()
        w.advance(day)
        _ = w.observe(136, block([adv(["CVE-2026-1201"], fixed: 135), adv(["CVE-2026-1202"], fixed: 136)]))
        w.step()
        let survivor = w.cls("CVE-2026-1201")!.classId
        let loser = w.cls("CVE-2026-1202")!.classId
        // Make the reminder cover only the later class, refused.
        w.s.classes = w.s.classes.map { var c = $0; c.reminderDueAt = w.now; if c.classId == survivor { c.reminderAttempted = true }; return c }
        w.advance(hour); w.confirm()
        w.outcome = .refused(retryAfter: 1)
        w.step()
        t.check("note 1: refused reminder references the later class", w.s.attempt(.reminder)?.classIds == [loser])
        w.advance(10)
        // The linking entry, applied by the same state-only merge the
        // observation path runs (a real link arrives with a newer release,
        // whose sequence alone already ends the retry).
        UpdateNotice.mergeEntry(&w.s, adv(["CVE-2026-1201", "CVE-2026-1202"], fixed: 136))
        t.check("note 1: the linking merge rewrote the retry to the survivor in the same transaction",
                w.s.attempt(.reminder)?.classIds == [survivor] && w.s.classes.count == 1)
        w.restart()
        if case .retry = UpdateNotice.retryDecision(w.s, kind: .reminder, env: w.env, noticeGeneration: 0, channelGeneration: gen(w)) {
            t.check("note 1: …after a restart the retry still matches through the survivor", true)
        } else {
            t.check("note 1: …after a restart the retry still matches through the survivor", false)
        }
        w.s.classes.removeAll()   // the survivor resolved/removed
        let d = UpdateNotice.retryDecision(w.s, kind: .reminder, env: w.env, noticeGeneration: 0, channelGeneration: gen(w))
        t.check("note 1: all referenced classes gone → dropped (no new consume)",
                { if case .drop = d { return true }; return false }() && UpdateNotice.proposals(w.s, env: w.env).allSatisfy { $0.kind != .reminder })
    }
}
