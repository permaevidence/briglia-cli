import Foundation

/// §5.4.1, §5.4.4, §15 items 3b (bounded history, quiet overflow, size cap)
/// and 3d (one writer: state-only transactions, merges, deadlines).
extension UpdateNoticeSelftest {
    static func manyEntries(_ n: Int, offset: Int = 0, fixed: Int = 135) -> [Entry] {
        (0..<n).map { adv(["CVE-2027-\(10000 + offset + $0)"], .recommended, 1, fixed) }
    }

    static func boundedGroup(_ t: Tally) {
        boundedSaturation(t)
        boundedFloorOnlyCapacity(t)
        boundedManyReleases(t)
        boundedThreeNotices(t)
        boundedSize(t)
    }

    static func boundedSaturation(_ t: Tally) {
        var w = World(installed: 100)
        // 256 advisories over 4 releases (64 per manifest, the list limit).
        for r in 0..<4 {
            _ = w.observe(130 + r, block(manyEntries(64, offset: 64 * r, fixed: 130 + r)))
            w.step()
            w.advance(hour)
        }
        t.check("3b 256 classes stored", w.s.classes.count == 256 && w.s.saturated == nil, "\(w.s.classes.count)")
        let notices = w.securityNotices.count
        _ = w.observe(134, block([adv(["CVE-2027-99999"], .recommended, 1, 134)]))
        t.check("3b 257th unresolved advisory → saturated (persisted state-only), no security notice",
                w.s.saturated != nil && w.step().allSatisfy { if case .security = $0.proposal { return false }; return true })
        w.restart()
        for seq in 135...137 {
            w.advance(day)
            _ = w.observe(seq, block([adv(["CVE-2027-99999"], .recommended, 1, 134)]))
            w.step()
        }
        t.check("3b same-fix feature releases afterwards (and restart) → no security notice, no new reminder cycle",
                w.securityNotices.count == notices && w.s.saturated != nil)
        w.installed = 132
        w.advance(hour); w.confirm()
        let fresh = w.step()
        t.check("3b upgrade clears saturation and classifies afresh (one notice for the new install)",
                w.s.saturated == nil && fresh.contains { if case .security = $0.proposal { return true }; return false })
    }

    /// Round-1 N1: a floor-only notice must not create row 257.
    static func boundedFloorOnlyCapacity(_ t: Tally) {
        var w = World(installed: 130)
        for (n, fixed) in [131, 133, 135, 137].enumerated() {
            _ = w.observe(fixed, block(manyEntries(64, offset: 64 * n, fixed: fixed), floorR: fixed - 2 < 130 ? 0 : fixed - 2))
            w.step()
            w.advance(hour)
            _ = w.observe(fixed + 1, block([], floorR: fixed))
            w.step()
            w.advance(hour)
        }
        t.check("N1 256 classes from four introduce/retire pairs", w.s.classes.count == 256, "\(w.s.classes.count)")
        _ = w.observe(139, block([], floorR: 137, floorC: 137))
        let sent = w.step()
        t.check("N1 a critical floor with a full table → saturated, no 257th row, no security notice",
                w.s.classes.count == 256 && w.s.saturated != nil && !sent.contains { if case .security = $0.proposal { return true }; return false })
    }

    static func boundedManyReleases(_ t: Tally) {
        var w = World(installed: 100)
        for seq in 101...140 { _ = w.observe(seq); w.step(); w.advance(8 * day) }
        let size = (try? UpdateNoticeStore.encodeState(w.s).count) ?? .max
        t.check("3b 40 release notices without an upgrade → no repeat, storage bounded",
                w.releaseNotices.count == 40 && Set(w.releaseNotices.map(\.proposal.sequence)).count == 40 && w.s.attempts.isEmpty && size < 8192, "\(size)")
    }

    static func boundedThreeNotices(_ t: Tally) {
        var w = World(installed: 100)
        for d in 0..<3 {
            _ = w.observe(130 + d, block((0...d).map { adv(["CVE-2027-\(500 + $0)"], .recommended, 1, 130 + $0) }))
            w.step()
            w.advance(day)
        }
        t.check("3b three security notices on three consecutive days", w.securityNotices.count == 3)
        w.advance(3 * day); w.confirm()
        let sent = w.step()
        t.check("3b …reminders due together merge into one message", sent.filter { if case .reminder = $0.proposal { return true }; return false }.count == 1)
        _ = w.run(hours: 24 * 8)
        t.check("3b …each class reminded once", w.reminders.count == 1 && w.s.classes.allSatisfy(\.reminderAttempted))
        w.advance(hour)
        _ = w.observe(140, block([adv(["CVE-2027-500", "GHSA-zz-500"], .recommended, 1, 130)]))
        t.check("3b re-observation of the same fix with an alias (still unfixed) → no new cycle", w.step().allSatisfy {
            if case .security = $0.proposal { return false }; return true })
    }

    static func boundedSize(_ t: Tally) {
        // Worst case: 4 domains with a ≤ 64 KiB payload's metadata each, 256
        // classes of 16 × 64-byte IDs, three full attempt records.
        var s = UpdateNoticeState()
        let longId = { (i: Int, j: Int) in String(format: "GHSA-%059d", i * 16 + j) }
        let fat = (0..<64).map { i in adv((0..<16).map { longId(i, $0) }, .critical, 1, 9_000_000_000_000) }
        let b = block(fat, floorR: 1, floorC: 1, summary: String(repeating: "s", count: 200))
        for d in 0..<4 {
            s.domains.append(DomainRecord(domain: String(repeating: "d", count: 200) + "\(d)", observed: ObservedRelease(
                sequence: 9_000_000_000_000, version: "999.999.999", contentId: String(repeating: "c", count: 64),
                manifestDigest: String(repeating: "m", count: 64), expires: t0, firstSeenAt: t0, lastConfirmedAt: t0,
                security: SecurityRecord(.known(b)), components: .none, hasBuild: true),
                lowerSince: t0, lastLowerSequence: 1, inconsistentSince: t0, touchedAt: t0))
        }
        s.classes = (0..<256).map { i in AdvisoryClass(classId: String(format: "%016x", i), ordinal: i, members: (0..<16).map { longId(i, $0) },
                                                       floor: nil, level: .critical, affectsFrom: 1, fixedIn: 9_000_000_000_000,
                                                       firstNoticeAt: t0, reminderDueAt: t0, reminderAttempted: false, supersededBy: "floor:critical") }
        s.attempts = [AttemptRecord.Kind.release, .reminder, .release].map { k in
            AttemptRecord(kind: k, sequence: 9_000_000_000_000, classIds: (0..<256).map { String(format: "%016x", $0) },
                          domain: String(repeating: "d", count: 200), observedContentId: String(repeating: "c", count: 64),
                          installedBaseline: 1, noticeGeneration: .max, channelKind: "telegram", chatId: "-1001234567890",
                          channelGeneration: .max, text: String(repeating: "é", count: 1024), attempt: 3, firstAttemptAt: t0,
                          deadline: t0, state: .refused, retryAfter: t0) }
        let size = (try? UpdateNoticeStore.encoder().encode(s).count) ?? .max
        t.check("3b worst-case state stays under 2 MiB (\(size) bytes)", size < UpdateNotice.maxStateBytes)
        var huge = s
        huge.lastCheckProblem = String(repeating: "x", count: UpdateNotice.maxStateBytes)
        t.check("3b the writer refuses a state above 2 MiB", (try? UpdateNoticeStore.encodeState(huge)) == nil)
    }

    // MARK: - 3d writer and timing

    static func writerGroup(_ t: Tally) {
        writerAliasMergeThenRetire(t)
        writerEscalationVsMerge(t)
        writerDeadlines(t)
        writerStateOnly(t)
    }

    static func writerAliasMergeThenRetire(_ t: Tally) {
        for restart in [false, true] {
            var w = World(installed: 130)
            _ = w.observe(135, block([adv(["CVE-2026-601"], fixed: 135), adv(["CVE-2026-602"], fixed: 135)]))
            w.step()
            t.check("3d two classes before linking", w.s.classes.count == 2)
            w.advance(hour)
            _ = w.observe(136, block([adv(["CVE-2026-601", "CVE-2026-602"], fixed: 135)]))
            t.check("3d alias-only merge persisted at the linking observation (state-only)", w.s.classes.count == 1 && w.s.attempts.isEmpty)
            if restart { w.restart() }
            w.advance(hour)
            _ = w.observe(137, block([adv(["CVE-2026-602"], fixed: 135)]))
            t.check("3d linking entry gone in 137\(restart ? " (restart between)" : "") → still one class, 137 not news",
                    w.s.classes.count == 1 && w.step().allSatisfy { if case .security = $0.proposal { return false }; return true })
        }
    }

    static func writerEscalationVsMerge(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-701"], fixed: 135), adv(["CVE-2026-702"], fixed: 135)]))
        w.step()
        _ = w.run(hours: 73)   // both reminded (one message)
        w.advance(hour)
        _ = w.observe(136, block([adv(["CVE-2026-701", "CVE-2026-702"], .critical, 101, 135)]))
        let sent = w.step()
        t.check("3d merge of recommended classes with an observed-critical entry → exactly one critical notice",
                sent.filter(isCritical).count == 1 && w.s.classes.count == 1 && w.s.classes[0].level == .critical)
        var m = World(installed: 130)
        _ = m.observe(135, block([adv(["CVE-2026-711"], fixed: 135)]))
        m.step()
        _ = m.run(hours: 73)
        m.advance(day)
        _ = m.observe(136, block([adv(["CVE-2026-711"], fixed: 135), adv(["CVE-2026-712"], fixed: 136)]))
        m.step()
        m.advance(hour)
        _ = m.observe(137, block([adv(["CVE-2026-711", "CVE-2026-712"], fixed: 136)]))
        _ = m.run(hours: 24 * 8)
        t.check("3d merge with an already-reminded class suppresses the other's pending reminder", m.reminders.count == 1)
        // The reminded class is the LATER one (the survivor is pending).
        var l = World(installed: 130)
        _ = l.observe(135, block([adv(["CVE-2026-721"], fixed: 135)]))
        l.step()
        l.advance(hour)
        _ = l.observe(136, block([adv(["CVE-2026-721"], fixed: 135), adv(["CVE-2026-722"], .critical, 101, 136)]))
        l.step()
        _ = l.run(hours: 26)
        t.check("3d (later class reminded first at +1 day)", l.reminders.count == 1 && l.cls("CVE-2026-721")?.reminderAttempted == false)
        l.advance(hour)
        _ = l.observe(137, block([adv(["CVE-2026-721", "CVE-2026-722"], .critical, 101, 136)]))
        _ = l.run(hours: 24 * 4)
        t.check("3d merging a pending survivor with an already-reminded class → no second reminder", l.reminders.count == 1,
                "\(l.reminders.map(\.at))")
    }

    static func writerDeadlines(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-801"], fixed: 135), adv(["CVE-2026-802"], .critical, 101, 135)]))
        w.step()
        let sent = w.run(hours: 24 * 5)
        let r = sent.filter { if case .reminder = $0.proposal { return true }; return false }
        t.check("3d one notice with recommended A and critical B → one reminder at +1 day, none at +3 days",
                r.count == 1 && abs(r[0].at.timeIntervalSince(t0) - day) <= hour, "\(r.map(\.at))")
        var sep = World(installed: 130)
        _ = sep.observe(135, block([adv(["CVE-2026-811"], fixed: 135)]))
        sep.step()
        sep.advance(day)
        _ = sep.observe(136, block([adv(["CVE-2026-811"], fixed: 135), adv(["CVE-2026-812"], fixed: 136)]))
        sep.step()
        _ = sep.run(hours: 24 * 5)
        t.check("3d separate notices with different deadlines → separate reminders, each once",
                sep.reminders.count == 2 && sep.s.classes.allSatisfy(\.reminderAttempted))
    }

    static func writerStateOnly(_ t: Tally) {
        var w = World(installed: 130)
        _ = w.observe(135, block([adv(["CVE-2026-901"], fixed: 135)]))
        w.step()
        w.advance(11 * day)        // no checks: stale, then past the 7-day window
        UpdateNotice.stateOnlyPass(&w.s, env: w.env)
        t.check("3d unsendable reminder past its window → attempted by a state-only change (no attempt record)",
                w.cls("CVE-2026-901")?.reminderAttempted == true && w.s.attempts.isEmpty && w.reminders.isEmpty)
        w.installed = 136
        UpdateNotice.stateOnlyPass(&w.s, env: w.env)
        t.check("3d resolution cleanup after an upgrade is state-only", w.s.classes.isEmpty && w.s.attempts.isEmpty)
    }
}
