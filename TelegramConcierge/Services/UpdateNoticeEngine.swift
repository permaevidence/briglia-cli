import Foundation

/// The pure rules of the update-available notice (security plan v8 §5.2–
/// §5.5). No I/O: every function maps (state, inputs) to state and
/// proposals, so the selftest can drive every trace with a fake clock.
///
/// Transactions (§5.4 opening): `observe` and `stateOnlyPass` are
/// state-only (nothing is sent, nothing consumed); `consume` is the single
/// write that precedes one send; `recordOutcome` / the retry helpers settle
/// an attempt. The caller performs each under the state lock.
enum UpdateNotice {
    static let checkInterval: TimeInterval = 6 * 3600
    static let checkJitter: TimeInterval = 30 * 60
    static let startupDelay: TimeInterval = 5 * 60
    static let freshness: TimeInterval = 48 * 3600
    static let attentionAfter: TimeInterval = 24 * 3600
    static let releaseCadence: TimeInterval = 7 * 86_400
    static let reminderRecommended: TimeInterval = 3 * 86_400
    static let reminderCritical: TimeInterval = 86_400
    static let reminderWindow: TimeInterval = 7 * 86_400
    static let retryWindow: TimeInterval = 3600
    static let maxAttempts = 3
    static let maxClasses = 256
    static let maxMembers = 16
    static let maxDomains = 4
    static let maxStateBytes = 2 * 1024 * 1024
    static let maxTextBytes = 2048

    struct Env {
        var now: Date
        /// The running binary's embedded sequence `I`.
        var installed: Int
        /// The running binary's trust domain (key set, channel, URL prefix).
        var domain: String
    }

    /// One verified manifest (§5.2).
    struct Observation {
        var domain: String
        var sequence: Int
        var version: String
        var contentId: String
        var manifestDigest: String
        var expires: Date
        var security: ReleaseSecurity.Parsed
        var components: ReleaseSecurity.Components
        var hasBuild: Bool
    }

    enum ObservationEffect: Equatable { case first, newer, renewal, conflict, lower, otherDomain }

    // MARK: - Observation (§5.2), state-only

    @discardableResult
    static func observe(_ s: inout UpdateNoticeState, _ o: Observation, env: Env) -> ObservationEffect {
        s.lastSuccess = env.now
        s.lastCheckProblem = nil
        let fresh = ObservedRelease(
            sequence: o.sequence, version: o.version, contentId: o.contentId, manifestDigest: o.manifestDigest,
            expires: o.expires, firstSeenAt: env.now, lastConfirmedAt: env.now,
            security: SecurityRecord(o.security), components: o.components, hasBuild: o.hasBuild)
        var effect = ObservationEffect.first
        s.withDomain(o.domain, now: env.now) { d in
            guard let current = d.observed else {
                d.observed = fresh
                d.lowerSince = nil
                d.inconsistentSince = nil
                effect = .first
                return
            }
            if o.sequence > current.sequence {
                d.observed = fresh
                d.lowerSince = nil
                d.inconsistentSince = nil
                effect = .newer
            } else if o.sequence == current.sequence, o.contentId == current.contentId {
                var renewed = current
                if o.expires > current.expires {
                    renewed.expires = o.expires
                    renewed.manifestDigest = o.manifestDigest
                }
                renewed.lastConfirmedAt = env.now
                renewed.hasBuild = current.hasBuild || o.hasBuild
                d.observed = renewed
                d.lowerSince = nil
                d.inconsistentSince = nil
                effect = .renewal
            } else if o.sequence == current.sequence {
                if d.inconsistentSince == nil { d.inconsistentSince = env.now }
                effect = .conflict
            } else {
                if d.lowerSince == nil { d.lowerSince = env.now }
                d.lastLowerSequence = o.sequence
                effect = .lower
            }
        }
        if o.domain != env.domain { effect = .otherDomain }
        return effect
    }

    /// A verified manifest the anti-rollback decision refused (below this
    /// install's trust floor): handled like a lower observation (§5.3).
    static func observeBelowTrustFloor(_ s: inout UpdateNoticeState, domain: String, sequence: Int, env: Env) {
        s.lastSuccess = env.now
        s.lastCheckProblem = nil
        s.withDomain(domain, now: env.now) { d in
            if d.lowerSince == nil { d.lowerSince = env.now }
            d.lastLowerSequence = sequence
        }
    }

    // MARK: - State-only pass

    /// Installed-sequence / domain reconciliation (§5.4.2 rule 5).
    static func reconcile(_ s: inout UpdateNoticeState, env: Env) {
        if s.runningDomain != env.domain {
            if s.runningDomain != nil {
                s.classes = []
                s.saturated = nil
                s.announcedThrough = 0
                s.attempts = s.attempts.filter { $0.state == .inFlight }
            }
            s.runningDomain = env.domain
            s.installedBaseline = env.installed
        }
        guard let baseline = s.installedBaseline else { s.installedBaseline = env.installed; return }
        if env.installed > baseline {
            s.classes.removeAll { $0.fixedIn <= env.installed }
            s.saturated = nil
            s.installedBaseline = env.installed
        } else if env.installed < baseline {
            // Reinstall of an older build: fresh-state residual (§5.2).
            s.classes = []
            s.saturated = nil
            s.announcedThrough = 0
            s.installedBaseline = env.installed
        }
    }

    /// The observed record of the running domain, when its release is newer
    /// than the installed one.
    static func observedForRunning(_ s: UpdateNoticeState, env: Env) -> ObservedRelease? {
        s.domain(env.domain)?.observed
    }

    /// Everything that changes without sending (§5.4): reconciliation, alias
    /// merges and range growth, floor-value raises, saturation, unsendable
    /// reminders past their 7-day window, terminal attempt records.
    static func stateOnlyPass(_ s: inout UpdateNoticeState, env: Env) {
        reconcile(&s, env: env)
        if let observed = observedForRunning(s, env: env), case .known(let block) = observed.security.parsed {
            for entry in block.cumulative { mergeEntry(&s, entry) }
            raiseFloor(&s, .critical, to: block.floorCritical)
            raiseFloor(&s, .recommended, to: block.floorRecommended)
            if observed.sequence > env.installed {
                let a = analyze(s, observed: observed, block: block, env: env)
                let incoming = a.newEntries.count + (a.floorCriticalNews ? 1 : 0) + (a.floorRecommendedNews ? 1 : 0)
                // Every class the notice would create counts, synthetic
                // floor classes included (round-1 N1: a floor-only notice
                // must not create row 257).
                if incoming > 0, s.classes.count + incoming > maxClasses {
                    if s.saturated == nil {
                        s.saturated = Saturation(since: env.now, droppedCount: incoming)
                    } else if s.saturated!.droppedCount != incoming {
                        s.saturated!.droppedCount = incoming
                    }
                }
            }
        }
        for i in s.classes.indices {
            if let due = s.classes[i].reminderDueAt, !s.classes[i].reminderAttempted,
               env.now >= due.addingTimeInterval(reminderWindow) {
                s.classes[i].reminderAttempted = true
            }
        }
        // Retries whose window closed end as refused (already recorded).
        s.attempts.removeAll { r in
            r.state == .refused && (r.attempt >= maxAttempts || env.now >= r.deadline)
        }
    }

    /// §5.4.2 rule 1: an entry intersecting stored classes is the same
    /// advisory; the matching classes merge into the earliest-created one.
    static func mergeEntry(_ s: inout UpdateNoticeState, _ entry: ReleaseSecurity.Entry) {
        let matching = s.classes.indices.filter { i in
            s.classes[i].floor == nil && !Set(s.classes[i].members).isDisjoint(with: entry.ids)
        }
        guard !matching.isEmpty else { return }
        let ordered = matching.sorted { s.classes[$0].ordinal < s.classes[$1].ordinal }
        var survivor = s.classes[ordered[0]]
        let before = survivor
        var older: [String] = []
        for i in ordered {
            let c = s.classes[i]
            for m in c.members where !older.contains(m) { older.append(m) }
            if i == ordered[0] { continue }
            survivor.level = max(survivor.level, c.level)
            survivor.affectsFrom = min(survivor.affectsFrom, c.affectsFrom)
            survivor.fixedIn = max(survivor.fixedIn, c.fixedIn)
            survivor.firstNoticeAt = min(survivor.firstNoticeAt, c.firstNoticeAt)
            if c.reminderAttempted {
                survivor.reminderAttempted = true
            } else if let due = c.reminderDueAt {
                survivor.reminderDueAt = survivor.reminderDueAt.map { min($0, due) } ?? due
            }
            survivor.supersededBy = survivor.supersededBy ?? c.supersededBy
        }
        // The entry's complete set first, then the earliest older members.
        var members = entry.ids
        for m in older where !members.contains(m) && members.count < maxMembers { members.append(m) }
        survivor.members = Array(members.prefix(maxMembers))
        survivor.affectsFrom = min(survivor.affectsFrom, entry.affectsFrom)
        survivor.fixedIn = max(survivor.fixedIn, entry.fixedIn)
        let losers = Set(ordered.dropFirst().map { s.classes[$0].classId })
        if survivor == before && losers.isEmpty { return }
        s.classes[ordered[0]] = survivor
        if !losers.isEmpty {
            s.classes.removeAll { losers.contains($0.classId) }
            // Round-8 note 1: in the same transaction, a reminder attempt
            // that referenced a merged-away class now references the
            // survivor (deduplicated) — never a new consume.
            for i in s.attempts.indices where s.attempts[i].kind == .reminder {
                var ids: [String] = []
                for id in s.attempts[i].classIds {
                    let mapped = losers.contains(id) ? survivor.classId : id
                    if !ids.contains(mapped) { ids.append(mapped) }
                }
                s.attempts[i].classIds = ids
            }
        }
    }

    static func raiseFloor(_ s: inout UpdateNoticeState, _ level: ReleaseSecurity.Level, to value: Int) {
        guard let i = s.classes.firstIndex(where: { $0.floor == level }), value > s.classes[i].fixedIn else { return }
        s.classes[i].fixedIn = value
    }

    // MARK: - What is news (§5.4.2)

    struct Analysis: Equatable {
        var newEntries: [ReleaseSecurity.Entry] = []
        var escalated: [String] = []
        var floorCriticalNews = false
        var floorRecommendedNews = false
        var isEmpty: Bool { newEntries.isEmpty && escalated.isEmpty && !floorCriticalNews && !floorRecommendedNews }
        var anyCritical: Bool {
            floorCriticalNews || !escalated.isEmpty || newEntries.contains { $0.level == .critical }
        }
    }

    /// Run on the table AFTER the state-only pass (merges never raise a
    /// stored level, so the stored levels are the pre-observation notified
    /// levels the rules compare against).
    static func analyze(_ s: UpdateNoticeState, observed: ObservedRelease, block: ReleaseSecurity.Block, env: Env) -> Analysis {
        let I = env.installed
        var a = Analysis()
        let notified = s.classes.map(\.level).max()
        for entry in block.cumulative where entry.affectsFrom <= I && I < entry.fixedIn {
            if let c = s.classes.first(where: { $0.floor == nil && !Set($0.members).isDisjoint(with: entry.ids) }) {
                if entry.level == .critical, c.level == .recommended, !a.escalated.contains(c.classId) {
                    a.escalated.append(c.classId)
                }
            } else {
                a.newEntries.append(entry)
            }
        }
        if I < block.floorCritical, !s.classes.contains(where: { $0.floor == .critical }), notified != .critical {
            a.floorCriticalNews = true
        }
        if I < block.floorRecommended, !s.classes.contains(where: { $0.floor == .recommended }), s.classes.isEmpty {
            a.floorRecommendedNews = true
        }
        return a
    }

    // MARK: - Proposals (§5.4.3)

    enum Proposal: Equatable {
        /// `New` non-empty: immediate security notice naming L.
        case security(sequence: Int, analysis: Analysis)
        /// Plain or "includes security fixes" release notice (N1 cadence).
        case release(sequence: Int, classification: ReleaseSecurity.Classification)
        /// One reminder covering every due class.
        case reminder(sequence: Int, classIds: [String])

        var kind: AttemptRecord.Kind {
            if case .reminder = self { return .reminder }
            return .release
        }
        var sequence: Int {
            switch self {
            case .security(let s, _), .release(let s, _), .reminder(let s, _): return s
            }
        }
    }

    /// Delivery preconditions shared by every notice (§5.5 step 2): the
    /// observed record is not expired, `lastSuccess` and `lastConfirmedAt`
    /// are ≤ 48 h old, and a build exists for this platform.
    static func deliverable(_ s: UpdateNoticeState, _ o: ObservedRelease, env: Env) -> Bool {
        guard o.expires > env.now, o.hasBuild,
              let success = s.lastSuccess, env.now.timeIntervalSince(success) <= freshness,
              env.now.timeIntervalSince(o.lastConfirmedAt) <= freshness else { return false }
        return true
    }

    /// The notices due now, at most one per kind; empty while a kind's
    /// earlier attempt is still unsettled (§5.4.4: a newer intent replaces
    /// a record only after its outcome is final).
    static func proposals(_ s: UpdateNoticeState, env: Env) -> [Proposal] {
        guard let o = observedForRunning(s, env: env), deliverable(s, o, env: env) else { return [] }
        var out: [Proposal] = []
        let I = env.installed
        if s.attempt(.release) == nil, o.sequence > I {
            var analysis = Analysis()
            if case .known(let block) = o.security.parsed { analysis = analyze(s, observed: o, block: block, env: env) }
            if !analysis.isEmpty, s.saturated == nil {
                out.append(.security(sequence: o.sequence, analysis: analysis))
            } else if o.sequence > s.announcedThrough,
                      s.lastReleaseNoticeAt.map({ env.now.timeIntervalSince($0) >= releaseCadence }) ?? true {
                out.append(.release(sequence: o.sequence,
                                    classification: ReleaseSecurity.classify(o.security.parsed, installed: I)))
            }
        }
        if s.attempt(.reminder) == nil {
            let due = s.classes.filter { c in
                guard let d = c.reminderDueAt, !c.reminderAttempted else { return false }
                return d <= env.now
            }
            if !due.isEmpty, due.contains(where: { $0.fixedIn <= o.sequence }), o.sequence > I {
                out.append(.reminder(sequence: o.sequence, classIds: due.sorted { $0.ordinal < $1.ordinal }.map(\.classId)))
            }
        }
        return out
    }

    /// When the next release notice held by the N1 cadence becomes due
    /// (status only).
    static func heldReleaseNoticeDue(_ s: UpdateNoticeState, env: Env) -> Date? {
        guard let o = observedForRunning(s, env: env), o.sequence > env.installed,
              o.sequence > s.announcedThrough, let last = s.lastReleaseNoticeAt else { return nil }
        let due = last.addingTimeInterval(releaseCadence)
        return due > env.now ? due : nil
    }

    // MARK: - Consume (§5.5 step 3)

    struct Destination: Equatable {
        var channelKind: String?
        var chatId: String?
        var channelGeneration: UInt64
    }

    /// Applies every state change the proposal makes plus its `in-flight`
    /// attempt record. The caller writes the result in ONE atomic
    /// replacement before the single send.
    static func consume(_ s: inout UpdateNoticeState, _ p: Proposal, text: String, env: Env,
                        destination: Destination, noticeGeneration: UInt64,
                        newClassId: () -> String) {
        guard let o = observedForRunning(s, env: env) else { return }
        switch p {
        case .security(let seq, let a):
            let due = env.now.addingTimeInterval(a.anyCritical ? reminderCritical : reminderRecommended)
            for entry in a.newEntries {
                s.classes.append(AdvisoryClass(
                    classId: newClassId(), ordinal: s.nextOrdinal, members: Array(entry.ids.prefix(maxMembers)),
                    floor: nil, level: entry.level, affectsFrom: entry.affectsFrom, fixedIn: entry.fixedIn,
                    firstNoticeAt: env.now, reminderDueAt: due, reminderAttempted: false, supersededBy: nil))
                s.nextOrdinal += 1
            }
            for id in a.escalated {
                if let i = s.classes.firstIndex(where: { $0.classId == id }) {
                    s.classes[i].level = .critical
                    s.classes[i].reminderDueAt = due
                    s.classes[i].reminderAttempted = false
                    s.classes[i].supersededBy = nil
                }
            }
            var floors: [(ReleaseSecurity.Level, Int)] = []
            if case .known(let block) = o.security.parsed {
                if a.floorRecommendedNews { floors.append((.recommended, block.floorRecommended)) }
                if a.floorCriticalNews { floors.append((.critical, block.floorCritical)) }
            }
            for (level, value) in floors {
                s.classes.append(AdvisoryClass(
                    classId: newClassId(), ordinal: s.nextOrdinal, members: [AdvisoryClass.floorKey(level)],
                    floor: level, level: level, affectsFrom: 0, fixedIn: value, firstNoticeAt: env.now,
                    reminderDueAt: due, reminderAttempted: false, supersededBy: nil))
                s.nextOrdinal += 1
            }
            if a.floorCriticalNews {
                // R7-1: the critical floor covers the whole installation; its
                // one +1-day reminder replaces every other pending reminder
                // (prior open classes and any created in this same notice).
                let key = AdvisoryClass.floorKey(.critical)
                for i in s.classes.indices where s.classes[i].floor != .critical && !s.classes[i].reminderAttempted {
                    s.classes[i].reminderAttempted = true
                    s.classes[i].supersededBy = key
                }
            }
            s.announcedThrough = max(s.announcedThrough, seq)
            s.lastReleaseNoticeAt = env.now
        case .release(let seq, _):
            s.announcedThrough = max(s.announcedThrough, seq)
            s.lastReleaseNoticeAt = env.now
        case .reminder(_, let ids):
            for i in s.classes.indices where ids.contains(s.classes[i].classId) {
                s.classes[i].reminderAttempted = true
            }
        }
        var classIds: [String] = []
        if case .reminder(_, let ids) = p { classIds = ids }
        s.attempts.removeAll { $0.kind == p.kind }
        s.attempts.append(AttemptRecord(
            kind: p.kind, sequence: p.sequence, classIds: classIds, domain: env.domain,
            observedContentId: o.contentId, installedBaseline: env.installed, noticeGeneration: noticeGeneration,
            channelKind: destination.channelKind, chatId: destination.chatId,
            channelGeneration: destination.channelGeneration, text: capped(text, bytes: maxTextBytes),
            attempt: 1, firstAttemptAt: env.now, deadline: env.now.addingTimeInterval(retryWindow),
            state: .inFlight, retryAfter: nil))
    }

    // MARK: - Outcomes and retries (§5.5 steps 4-5)

    enum SendOutcome: Equatable {
        case accepted
        /// Non-delivery proven for the whole attempt (Telegram 4xx ok:false,
        /// or a failure before any request byte was written).
        case refused(retryAfter: TimeInterval)
        /// Telegram may have shown it: never retried.
        case ambiguous
        /// The channel's credentials changed before any byte was built.
        case dropped
    }

    static func recordOutcome(_ s: inout UpdateNoticeState, kind: AttemptRecord.Kind, _ outcome: SendOutcome, env: Env) {
        guard let i = s.attempts.firstIndex(where: { $0.kind == kind && $0.state == .inFlight }) else { return }
        let state: AttemptRecord.State
        switch outcome {
        case .accepted: state = .accepted
        case .ambiguous: state = .ambiguous
        case .dropped: state = .dropped
        case .refused(let after):
            state = .refused
            s.attempts[i].retryAfter = env.now.addingTimeInterval(max(after, 1))
        }
        s.lastOutcome = OutcomeRecord(kind: kind, at: env.now, outcome: state, sequence: s.attempts[i].sequence)
        if state == .refused, s.attempts[i].attempt < maxAttempts, env.now < s.attempts[i].deadline {
            s.attempts[i].state = .refused
        } else {
            s.attempts.remove(at: i)
        }
    }

    /// At startup: an attempt still `in-flight` belongs to a process that
    /// died before recording its outcome → lost (terminal, never resent).
    static func settleCrashedAttempts(_ s: inout UpdateNoticeState, env: Env) -> Bool {
        let crashed = s.attempts.filter { $0.state == .inFlight }
        guard !crashed.isEmpty else { return false }
        for r in crashed {
            s.lastOutcome = OutcomeRecord(kind: r.kind, at: env.now, outcome: .lost, sequence: r.sequence)
        }
        s.attempts.removeAll { $0.state == .inFlight }
        return true
    }

    enum RetryDecision: Equatable { case notYet, retry(AttemptRecord), drop(AttemptRecord) }

    /// A retry is the CONSUMED notice, matched against its own record — the
    /// first-send predicates (`announcedThrough`, `reminderAttempted`) are
    /// deliberately not applied (§5.5 step 4).
    static func retryDecision(_ s: UpdateNoticeState, kind: AttemptRecord.Kind, env: Env,
                              noticeGeneration: UInt64, channelGeneration: (String?) -> UInt64) -> RetryDecision {
        guard let r = s.attempt(kind), r.state == .refused else { return .notYet }
        if r.attempt >= maxAttempts || env.now >= r.deadline { return .drop(r) }
        guard let after = r.retryAfter, env.now >= after else { return .notYet }
        guard r.noticeGeneration == noticeGeneration, channelGeneration(r.channelKind) == r.channelGeneration,
              env.installed == r.installedBaseline, env.domain == r.domain,
              let o = s.domain(r.domain)?.observed, o.sequence == r.sequence, o.contentId == r.observedContentId,
              deliverable(s, o, env: env) else { return .drop(r) }
        if kind == .reminder {
            let present = r.classIds.filter { id in s.classes.contains { $0.classId == id } }
            if present.isEmpty { return .drop(r) }
        }
        return .retry(r)
    }

    /// Durable re-mark before each retry: a crash before its outcome makes
    /// it lost, never a replay of the earlier refusal.
    static func markRetryInFlight(_ s: inout UpdateNoticeState, kind: AttemptRecord.Kind) {
        guard let i = s.attempts.firstIndex(where: { $0.kind == kind && $0.state == .refused }) else { return }
        s.attempts[i].attempt += 1
        s.attempts[i].state = .inFlight
        s.attempts[i].retryAfter = nil
    }

    static func dropAttempt(_ s: inout UpdateNoticeState, kind: AttemptRecord.Kind) {
        s.attempts.removeAll { $0.kind == kind }
    }

    /// `text` cut at a character boundary to at most `bytes` UTF-8 bytes.
    static func capped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var out = ""
        for ch in text {
            if out.utf8.count + String(ch).utf8.count > bytes { break }
            out.append(ch)
        }
        return out
    }

    // MARK: - Cadence (§5.1)

    static func scheduleNextCheck(_ s: inout UpdateNoticeState, now: Date, jitter: TimeInterval) {
        s.lastAttempt = now
        s.nextCheckAt = now.addingTimeInterval(checkInterval + max(-checkJitter, min(checkJitter, jitter)))
    }

    /// The startup extra check: only if `lastAttempt` is ≥ 1 h old AND
    /// `lastSuccess` is ≥ 6 h old (so restart loops cannot cause a storm).
    static func wantsStartupCheck(_ s: UpdateNoticeState, now: Date) -> Bool {
        let attemptOld = s.lastAttempt.map { now.timeIntervalSince($0) >= 3600 } ?? true
        let successOld = s.lastSuccess.map { now.timeIntervalSince($0) >= checkInterval } ?? true
        return attemptOld && successOld
    }

    static func checkDue(_ s: UpdateNoticeState, now: Date) -> Bool {
        guard let next = s.nextCheckAt else { return s.lastAttempt == nil }
        return now >= next
    }
}
