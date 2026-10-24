import Foundation

/// Runtime of the known-vulnerability check of the user's own tools
/// (security plan v16 §9.5). Lives in the process that holds the instance
/// lock and is driven by the update notice's tick (§5.1): the advisory list
/// is fetched at most once a day, inside the regular check window, with one
/// GET of the same URL for every client; the inventory is read-only; at most
/// one message per check, consumed durably before its single send, never
/// retried after an ambiguous outcome. Shares `/upgradecheck` and the
/// notice generation with the update notice.
@MainActor
final class LocalToolsService {
    struct Deps {
        var paths: LocalAdvisoryStore.Paths
        var now: () -> Date
        var policy: AdvisoryPolicy
        /// ONE bounded GET of `policy.url` (raw envelope bytes).
        var fetch: () async throws -> Data
        /// Read-only inventory, off the main actor.
        var inventory: () async -> [LocalTools.Resolution]
        var language: () -> String
        var isIdle: () -> Bool
        var destination: () -> UpdateNotice.Destination
        var channelGeneration: (String?) -> UInt64
        /// ONE transport attempt: (channel kind, chat, channel generation, text).
        var send: (String?, String?, UInt64, String) async -> UpdateNotice.SendOutcome
        var log: (String) -> Void
    }

    static let fetchInterval: TimeInterval = 24 * 3600 - UpdateNotice.checkJitter
    static let evaluationInterval: TimeInterval = 6 * 3600

    private(set) static var current: LocalToolsService?

    @discardableResult
    static func launch(deps: Deps) -> LocalToolsService {
        if let running = current { return running }
        let s = LocalToolsService(deps: deps)
        current = s
        s.start()
        return s
    }

    let deps: Deps
    /// Test seams / status.
    private(set) var fetchesStarted = 0
    private(set) var evaluations = 0
    private(set) var saveFailed = false
    private var busy = false

    init(deps: Deps) { self.deps = deps }

    func start() {
        _ = try? LocalAdvisoryStore.transaction(deps.paths, now: deps.now()) { _, _, v in
            _ = LocalVuln.settleCrashed(&v, now: deps.now())
        }
    }

    func stop() { if Self.current === self { Self.current = nil } }

    // MARK: - Tick

    /// `afterCheck`: the update check just ran (the §5.1 window).
    func tick(afterCheck: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var fetched = false
        if afterCheck, fetchDue() { fetched = await runFetch() }
        if fetched || evaluationDue() { await evaluate() }
        await deliver()
    }

    func fetchDue() -> Bool {
        guard deps.policy.isProvisioned else { return false }
        let (setting, _) = UpdateNoticeStore.snapshot(deps.paths.notice)
        guard setting.enabled else { return false }
        let (obs, _) = LocalAdvisoryStore.snapshot(deps.paths)
        guard let last = obs?.lastAttempt else { return true }
        return deps.now().timeIntervalSince(last) >= Self.fetchInterval || deps.now() < last
    }

    func evaluationDue() -> Bool {
        guard deps.policy.isProvisioned, UpdateNoticeStore.snapshot(deps.paths.notice).0.enabled else { return false }
        let (_, vuln) = LocalAdvisoryStore.snapshot(deps.paths)
        guard let at = vuln?.report?.evaluatedAt else { return true }
        return deps.now().timeIntervalSince(at) >= Self.evaluationInterval || deps.now() < at
    }

    // MARK: - Fetch (§9.5.3)

    /// Returns true when a verified list was recorded. No lock across the
    /// network call; the result is written only if the setting is still ON
    /// and the generation unchanged.
    func runFetch() async -> Bool {
        let start = deps.now()
        let generation: UInt64?
        do {
            generation = try LocalAdvisoryStore.transaction(deps.paths, now: start) { setting, obs, _ in
                guard setting.enabled else { return nil }
                obs.lastAttempt = start
                return setting.generation
            }
        } catch {
            saveFailed = true
            return false
        }
        guard let generation else { return false }
        fetchesStarted += 1
        let outcome: Result<LocalAdvisory.Verified, Error>
        do {
            let raw = try await deps.fetch()
            outcome = .success(try LocalAdvisory.verify(raw, policy: deps.policy, now: deps.now()))
        } catch {
            outcome = .failure(error)
        }
        do {
            return try LocalAdvisoryStore.transaction(deps.paths, now: deps.now()) { setting, obs, _ in
                guard setting.enabled, setting.generation == generation else { return false }
                switch outcome {
                case .success(let v):
                    LocalAdvisoryStore.observe(&obs, v, domain: deps.policy.trustDomain, now: deps.now())
                    return true
                case .failure(let e):
                    obs.lastProblem = String(e.localizedDescription.prefix(200))
                    return false
                }
            }
        } catch {
            saveFailed = true
            return false
        }
    }

    // MARK: - Evaluation (§9.5.4)

    /// Matches a fresh inventory against the current list; persists the
    /// report (display) and the positive-evidence row cleanup (state-only).
    func evaluate() async {
        let resolutions = await deps.inventory()
        evaluations += 1
        let now = deps.now()
        do {
            try LocalAdvisoryStore.transaction(deps.paths, now: now) { setting, obs, vuln in
                guard setting.enabled else { return }
                let (doc, record) = Self.currentList(obs, policy: deps.policy, now: now)
                let reports = resolutions.map { LocalTools.match($0, list: doc, now: now) }
                vuln.report = LocalToolsSnapshot(evaluatedAt: now, listSequence: record?.sequence,
                                                 listContentId: doc == nil ? nil : record?.contentId, reports: reports)
                LocalVuln.reconcile(&vuln, resolutions)
                if LocalVuln.proposals(vuln, reports: reports).overflow > 0, vuln.saturated == nil {
                    vuln.saturated = Saturation(since: now, droppedCount: LocalVuln.proposals(vuln, reports: reports).overflow)
                }
            }
            saveFailed = false
        } catch {
            saveFailed = true
            deps.log("tool advisories: state cannot be saved (\(error.localizedDescription))")
        }
    }

    /// The document to match with: unexpired, readable. An expired or
    /// missing list gives nil (every state unknown).
    nonisolated static func currentList(_ obs: LocalAdvisoryStore.ObservationState, policy: AdvisoryPolicy,
                                        now: Date) -> (LocalAdvisory.Document?, LocalAdvisoryStore.DomainRecord?) {
        switch LocalAdvisoryStore.view(obs, domain: policy.trustDomain, now: now) {
        case .current(let doc, let d): return (doc, d)
        case .expired(let d): return (nil, d)
        case .none: return (nil, nil)
        }
    }

    // MARK: - Delivery (§9.5.5)

    func deliver() async {
        guard deps.isIdle() else { return }
        if await retryIfDue() { return }
        // Derive from the persisted evaluation.
        let (setting, _) = UpdateNoticeStore.snapshot(deps.paths.notice)
        guard setting.enabled else { return }
        let (obs, vuln) = LocalAdvisoryStore.snapshot(deps.paths)
        guard let vuln, let report = vuln.report, let contentId = report.listContentId,
              vuln.attempt == nil, let obs, Self.messagingAllowed(obs, policy: deps.policy, contentId: contentId, now: deps.now())
        else { return }
        let first = LocalVuln.proposals(vuln, reports: report.reports).lines
        guard !first.isEmpty else { return }
        // Re-establish everything with a FRESH probe immediately before the
        // send: any change drops the intent (state-only), nothing is sent.
        let resolutions = await deps.inventory()
        let now = deps.now()
        guard deps.isIdle() else { return }
        let generation = setting.generation
        var record: (lines: [LocalVuln.Proposal], text: String, destination: UpdateNotice.Destination)?
        do {
            record = try LocalAdvisoryStore.transaction(deps.paths, now: now) { setting, obs, v in
                guard setting.enabled, setting.generation == generation, v.attempt == nil,
                      Self.messagingAllowed(obs, policy: deps.policy, contentId: contentId, now: now) else { return nil }
                let (doc, _) = Self.currentList(obs, policy: deps.policy, now: now)
                let reports = resolutions.map { LocalTools.match($0, list: doc, now: now) }
                LocalVuln.reconcile(&v, resolutions)
                v.report = LocalToolsSnapshot(evaluatedAt: now, listSequence: v.report?.listSequence,
                                              listContentId: contentId, reports: reports)
                let fresh = LocalVuln.proposals(v, reports: reports).lines
                guard fresh.map({ "\($0.key)|\($0.kind.rawValue)" }) == first.map({ "\($0.key)|\($0.kind.rawValue)" }) else {
                    return nil   // changed since derivation: drop, state-only
                }
                let destination = deps.destination()
                let text = LocalToolsText.message(fresh, lang: deps.language())
                LocalVuln.consume(&v, fresh, text: text, listContentId: contentId, noticeGeneration: setting.generation,
                                  destination: destination, now: now)
                return (fresh, text, destination)
            }
        } catch {
            saveFailed = true
            deps.log("tool advisories: state cannot be saved — nothing sent (\(error.localizedDescription))")
            return
        }
        guard let record else { return }
        let outcome = await deps.send(record.destination.channelKind, record.destination.chatId,
                                      record.destination.channelGeneration, record.text)
        settle(outcome, generation: generation)
    }

    nonisolated static func messagingAllowed(_ obs: LocalAdvisoryStore.ObservationState, policy: AdvisoryPolicy,
                                             contentId: String, now: Date) -> Bool {
        guard let d = obs.domain(policy.trustDomain) else { return false }
        return d.contentId == contentId && d.expires > now && d.conflictSince == nil
    }

    func settle(_ outcome: UpdateNotice.SendOutcome, generation: UInt64) {
        do {
            try LocalAdvisoryStore.transaction(deps.paths, now: deps.now()) { setting, _, v in
                guard setting.generation == generation else { return }
                LocalVuln.recordOutcome(&v, outcome, now: deps.now())
            }
        } catch {
            saveFailed = true
        }
    }

    /// A proven refusal may be retried (≤ 3 within 1 h) after re-validating
    /// every line with a fresh probe; returns true when it handled a record.
    func retryIfDue() async -> Bool {
        let now = deps.now()
        let (setting, _) = UpdateNoticeStore.snapshot(deps.paths.notice)
        let (obs, vuln) = LocalAdvisoryStore.snapshot(deps.paths)
        guard let vuln, let a = vuln.attempt else { return false }
        let contentId = obs?.domain(deps.policy.trustDomain)?.contentId
        let decision = LocalVuln.retryDecision(vuln, now: now, noticeGeneration: setting.generation,
                                               channelGeneration: deps.channelGeneration, listContentId: contentId)
        switch decision {
        case .none, .notYet: return decision == .notYet
        case .drop:
            _ = try? LocalAdvisoryStore.transaction(deps.paths, now: now) { _, _, v in
                if v.attempt == a { v.attempt = nil }
            }
            return true
        case .retry:
            break
        }
        let resolutions = await deps.inventory()
        let now2 = deps.now()
        guard deps.isIdle() else { return true }
        let record: LocalVulnAttempt?
        do {
            record = try LocalAdvisoryStore.transaction(deps.paths, now: now2) { setting, obs, v in
                guard setting.enabled, let current = v.attempt, current == a,
                      Self.messagingAllowed(obs, policy: deps.policy, contentId: a.listContentId, now: now2),
                      LocalVuln.retryDecision(v, now: now2, noticeGeneration: setting.generation,
                                              channelGeneration: deps.channelGeneration,
                                              listContentId: obs.domain(deps.policy.trustDomain)?.contentId) == .retry
                else { return nil }
                let (doc, _) = Self.currentList(obs, policy: deps.policy, now: now2)
                let reports = resolutions.map { LocalTools.match($0, list: doc, now: now2) }
                guard LocalVuln.linesStillValid(current, reports: reports) else {
                    v.attempt = nil
                    return nil
                }
                LocalVuln.markRetryInFlight(&v)
                return v.attempt
            }
        } catch {
            saveFailed = true
            return true
        }
        guard let record else { return true }
        let outcome = await deps.send(record.channelKind, record.chatId, record.channelGeneration, record.text)
        settle(outcome, generation: record.noticeGeneration)
        return true
    }
}
