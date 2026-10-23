import Foundation

/// A simulated installation for the state-machine traces: the state, a
/// fake clock, the installed sequence, and every notice "sent". `observe`
/// and `step` mirror what the service does on a check and on an idle tick.
extension UpdateNoticeSelftest {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let dom = "test-domain"
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400

    typealias Entry = ReleaseSecurity.Entry
    typealias Level = ReleaseSecurity.Level

    static func adv(_ ids: [String], _ level: Level = .recommended, _ from: Int = 101, fixed: Int) -> Entry {
        Entry(ids: ids.map { $0.uppercased() }, level: level, affectsFrom: from, fixedIn: fixed)
    }

    static func adv(_ ids: [String], _ level: Level, _ from: Int, _ fixed: Int) -> Entry {
        adv(ids, level, from, fixed: fixed)
    }

    static func block(_ entries: [Entry] = [], floorR: Int = 0, floorC: Int = 0, summary: String? = nil) -> ReleaseSecurity.Block {
        ReleaseSecurity.Block(cumulative: entries, introduces: [], floorRecommended: floorR, floorCritical: floorC, summary: summary)
    }

    struct Sent: Equatable {
        var proposal: UpdateNotice.Proposal
        var text: String
        var at: Date
    }

    struct World {
        var s = UpdateNoticeState()
        var now: Date = UpdateNoticeSelftest.t0
        var installed: Int
        var sent: [Sent] = []
        var nextId = 0
        var outcome: UpdateNotice.SendOutcome = .accepted
        var noticeGeneration: UInt64 = 0
        var channelGeneration: UInt64 = 0

        init(installed: Int) { self.installed = installed }

        var env: UpdateNotice.Env { UpdateNotice.Env(now: now, installed: installed, domain: dom) }

        mutating func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

        /// A verified observation, then the service's state-only pass.
        mutating func observe(_ seq: Int, _ security: ReleaseSecurity.Parsed = .absent, content: String? = nil,
                              expiresIn: TimeInterval = 180 * 86_400, hasBuild: Bool = true,
                              domain: String = dom) -> UpdateNotice.ObservationEffect {
            let o = UpdateNotice.Observation(
                domain: domain, sequence: seq, version: "0.3.\(seq)",
                contentId: content ?? "content-\(seq)", manifestDigest: "digest-\(seq)-\(expiresIn)",
                expires: now.addingTimeInterval(expiresIn), security: security, components: .none, hasBuild: hasBuild)
            let effect = UpdateNotice.observe(&s, o, env: env)
            UpdateNotice.stateOnlyPass(&s, env: env)
            return effect
        }

        mutating func observe(_ seq: Int, _ b: ReleaseSecurity.Block, content: String? = nil) -> UpdateNotice.ObservationEffect {
            observe(seq, .known(b), content: content)
        }

        /// One idle tick: state-only pass, then at most one notice per kind,
        /// each consumed and settled with `outcome`. Returns what was sent.
        @discardableResult
        mutating func step() -> [Sent] {
            UpdateNotice.stateOnlyPass(&s, env: env)
            var out: [Sent] = []
            for _ in 0..<2 {
                guard let p = UpdateNotice.proposals(s, env: env).first,
                      let o = UpdateNotice.observedForRunning(s, env: env) else { break }
                var critical = false
                if case .reminder(_, let ids) = p { critical = s.classes.contains { ids.contains($0.classId) && $0.level == .critical } }
                let text = UpdateNoticeText.message(p, version: o.version, critical: critical, summary: nil, lang: "en", surface: .chat)
                var counter = nextId
                UpdateNotice.consume(&s, p, text: text, env: env,
                                     destination: .init(channelKind: "telegram", chatId: "1", channelGeneration: channelGeneration),
                                     noticeGeneration: noticeGeneration,
                                     newClassId: { counter += 1; return String(format: "%016x", counter) })
                nextId = counter
                let x = Sent(proposal: p, text: text, at: now)
                out.append(x)
                sent.append(x)
                UpdateNotice.recordOutcome(&s, kind: p.kind, outcome, env: env)
            }
            return out
        }

        /// Persist and reload (JSON round trip) plus the startup settlement.
        mutating func restart() {
            let data = try! UpdateNoticeStore.encodeState(s)
            s = try! UpdateNoticeStore.decoder().decode(UpdateNoticeState.self, from: data)
            _ = UpdateNotice.settleCrashedAttempts(&s, env: env)
        }

        /// Steps once per hour for `hours` (sending whatever becomes due).
        mutating func run(hours: Int) -> [Sent] {
            var all: [Sent] = []
            for _ in 0..<hours { advance(3600); confirm(); all += step() }
            return all
        }

        /// Keeps the observed record fresh (a same-content renewal), as the
        /// 6-hourly checks would.
        mutating func confirm() {
            guard let o = s.domain(dom)?.observed else { return }
            let obs = UpdateNotice.Observation(domain: dom, sequence: o.sequence, version: o.version, contentId: o.contentId,
                                               manifestDigest: o.manifestDigest, expires: o.expires,
                                               security: o.security.parsed, components: o.components, hasBuild: o.hasBuild)
            UpdateNotice.observe(&s, obs, env: env)
        }

        var reminders: [Sent] { sent.filter { if case .reminder = $0.proposal { return true }; return false } }
        var securityNotices: [Sent] { sent.filter { if case .security = $0.proposal { return true }; return false } }
        var releaseNotices: [Sent] { sent.filter { if case .release = $0.proposal { return true }; return false } }

        func cls(_ id: String) -> AdvisoryClass? { s.classes.first { $0.members.contains(id.uppercased()) } }
        var floorCritical: AdvisoryClass? { s.classes.first { $0.floor == .critical } }
        var floorRecommended: AdvisoryClass? { s.classes.first { $0.floor == .recommended } }
    }

    static func isCritical(_ x: Sent) -> Bool { x.text.contains("important security fix") }
}
