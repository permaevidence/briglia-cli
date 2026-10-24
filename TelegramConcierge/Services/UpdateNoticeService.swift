import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Runtime of the update-available notice (security plan v8 §5): runs only
/// inside the process that holds the instance lock (the one that polls).
/// A detached loop ticks once a minute: a check when due (one HTTPS GET of
/// the signed manifest, read-only — never the anti-rollback store), then,
/// when no turn is running, at most one notice per kind. Notices are
/// re-derived from durable state on every tick, so a crash while a notice
/// is only "queued" loses nothing and repeats nothing.
@MainActor
final class UpdateNoticeService {
    struct Deps {
        var paths: UpdateNoticeStore.Paths
        var now: () -> Date
        var installed: Int
        var installedVersion: String
        var policy: ReleasePolicy
        var platform: String?
        var fetch: () async throws -> ReleaseSigning.Manifest
        /// Persisted anti-rollback sequence for this policy (read-only).
        var trustFloor: () -> Int?
        var jitter: () -> TimeInterval
        var newClassId: () -> String
        var language: () -> String
        var isIdle: () -> Bool
        /// Where a new notice goes now (nil kind = terminal/local surface).
        var destination: () -> UpdateNotice.Destination
        var channelGeneration: (String?) -> UInt64
        /// ONE transport attempt for a consumed record.
        var send: (AttemptRecord) async -> UpdateNotice.SendOutcome
        var log: (String) -> Void
    }

    /// The running service, STRONGLY owned for the polling process's
    /// lifetime (round-1 R1: a weak reference let the starter's local go out
    /// of scope before the loop's first tick). `stop()` releases it.
    private(set) static var current: UpdateNoticeService?

    /// The production owner path: create, retain in `current`, start.
    /// No-op while one is already running.
    @discardableResult
    static func launch(deps: Deps, tickNanoseconds: UInt64 = 60_000_000_000) -> UpdateNoticeService {
        if let running = current { return running }
        let service = UpdateNoticeService(deps: deps)
        current = service
        service.start(tickNanoseconds: tickNanoseconds)
        return service
    }

    let deps: Deps
    let domain: String
    private(set) var saveFailed = false {
        didSet { Self.saveFailedFlag.set(saveFailed) }
    }
    /// Process-wide copy for readers outside the main actor (/status, menu).
    nonisolated static let saveFailedFlag = UpdateNoticeFlag()
    private let startedAt: Date
    private var startupCheckWanted = false
    private var loop: Task<Void, Never>?
    private var checkInFlight = false
    /// Test seam / status: number of verified fetches started by this object.
    private(set) var fetchesStarted = 0

    init(deps: Deps) {
        self.deps = deps
        self.domain = Self.noticeDomain(deps.policy)
        self.startedAt = deps.now()
    }

    /// Trust domain of the notice record: pinned key set + channel + URL
    /// prefix (§5.2).
    nonisolated static func noticeDomain(_ policy: ReleasePolicy) -> String {
        let keys = policy.keys.map(\.keyId).sorted().joined(separator: ",")
        let keySet = ReleaseSecurity.hex(SHA256.hash(data: Data(keys.utf8))).prefix(16)
        return "\(keySet)|\(policy.trustDomain)"
    }

    var env: UpdateNotice.Env { UpdateNotice.Env(now: deps.now(), installed: deps.installed, domain: domain) }

    // MARK: - Lifecycle

    /// Settles attempts a crashed process left in flight (lost, terminal),
    /// decides the startup extra check, starts the loop. Returns at once.
    func start(tickNanoseconds: UInt64 = 60_000_000_000) {
        guard loop == nil else { return }
        let now = deps.now()
        _ = try? UpdateNoticeStore.transaction(deps.paths, now: now) { setting, s in
            let changed = UpdateNotice.settleCrashedAttempts(&s, env: env)
            startupCheckWanted = setting.enabled && UpdateNotice.wantsStartupCheck(s, now: now)
            return (changed, ())
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: tickNanoseconds)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if Self.current === self { Self.current = nil }
        LocalToolsService.current?.stop()
    }

    // MARK: - One tick

    func tick() async {
        let checked = shouldCheckNow()
        if checked { await runCheck() }
        await deliverDue()
        // The local-tools check (§9.5) shares this window and this loop:
        // its daily list fetch happens only right after a release check.
        await LocalToolsService.current?.tick(afterCheck: checked)
    }

    func shouldCheckNow() -> Bool {
        let now = deps.now()
        guard now.timeIntervalSince(startedAt) >= UpdateNotice.startupDelay else { return false }
        let (setting, state) = UpdateNoticeStore.snapshot(deps.paths)
        guard setting.enabled else { return false }
        if startupCheckWanted { return true }
        return UpdateNotice.checkDue(state ?? UpdateNoticeState(), now: now)
    }

    // MARK: - Check (§5.1)

    /// One read-only check. The lock is never held across the network call;
    /// the result is written only if the setting is still ON and the notice
    /// generation unchanged (a concurrent OFF or /deleteuserdata wins).
    func runCheck() async {
        guard !checkInFlight else { return }
        checkInFlight = true
        defer { checkInFlight = false }
        startupCheckWanted = false
        let start = deps.now()
        let jitter = deps.jitter()
        let generation: UInt64?
        do {
            generation = try UpdateNoticeStore.transaction(deps.paths, now: start) { setting, s in
                guard setting.enabled else { return (false, nil) }
                UpdateNotice.scheduleNextCheck(&s, now: start, jitter: jitter)
                return (true, setting.generation)
            }
        } catch {
            saveFailed = true
            deps.log("update check: state cannot be saved (\(error.localizedDescription))")
            return
        }
        guard let generation else { return }
        fetchesStarted += 1
        let manifest: ReleaseSigning.Manifest
        do {
            manifest = try await deps.fetch()
        } catch {
            let problem = String(error.localizedDescription.prefix(200))
            _ = try? UpdateNoticeStore.transaction(deps.paths, now: deps.now()) { setting, s in
                guard setting.enabled, setting.generation == generation else { return (false, ()) }
                s.lastCheckProblem = problem
                return (true, ())
            }
            return
        }
        apply(manifest, generation: generation)
    }

    /// Applies one verified manifest as an observation (state-only).
    func apply(_ manifest: ReleaseSigning.Manifest, generation: UInt64) {
        let env = self.env
        let trust = deps.trustFloor()
        let floor = max(deps.installed, trust ?? 0)
        let parsed = ReleaseSecurity.parse(payload: manifest.payload, sequence: manifest.sequence)
        let observation = UpdateNotice.Observation(
            domain: domain, sequence: manifest.sequence, version: manifest.version,
            contentId: ReleaseSecurity.contentId(payload: manifest.payload) ?? ReleaseSecurity.digest(manifest.payload),
            manifestDigest: ReleaseSecurity.digest(manifest.payload), expires: manifest.expires,
            security: parsed.security, components: parsed.components,
            hasBuild: deps.platform.map { manifest.platforms[$0] != nil } ?? false)
        do {
            try UpdateNoticeStore.transaction(deps.paths, now: env.now) { setting, s in
                guard setting.enabled, setting.generation == generation else { return (false, ()) }
                if manifest.sequence < floor {
                    // Below max(installed, persisted trust): always a lower
                    // observation (§5.3), also when it equals the observed
                    // record — never a renewal (round-1 R4).
                    UpdateNotice.observeBelowTrustFloor(&s, domain: domain, sequence: manifest.sequence, env: env)
                } else {
                    UpdateNotice.observe(&s, observation, env: env)
                }
                UpdateNotice.stateOnlyPass(&s, env: env)
                return (true, ())
            }
            saveFailed = false
        } catch {
            saveFailed = true
            deps.log("update check: state cannot be saved (\(error.localizedDescription))")
        }
    }

    // MARK: - Delivery (§5.5)

    func deliverDue() async {
        guard deps.isIdle() else { return }
        for kind in [AttemptRecord.Kind.release, .reminder] { await retryIfDue(kind) }
        // At most one new notice per kind per tick.
        for _ in 0..<2 {
            guard deps.isIdle(), let record = consumeNext() else { return }
            let outcome = await deps.send(record)
            settle(record, outcome)
        }
    }

    /// Lock → re-read → state-only pass → recheck (proposals are re-derived
    /// against the CURRENT state) → consume + `in-flight` record in ONE
    /// write. Returns the record to send once, or nil (nothing due, OFF, or
    /// the write failed — then nothing is sent).
    func consumeNext() -> AttemptRecord? {
        let env = self.env
        do {
            let record: AttemptRecord? = try UpdateNoticeStore.transaction(deps.paths, now: env.now) { setting, s in
                guard setting.enabled else { return (false, nil) }
                UpdateNotice.stateOnlyPass(&s, env: env)
                guard let p = UpdateNotice.proposals(s, env: env).first,
                      let o = UpdateNotice.observedForRunning(s, env: env) else { return (true, nil) }
                let destination = deps.destination()
                let surface: UpdateNoticeText.Surface = destination.channelKind == nil ? .terminal
                    : destination.channelKind == ChannelKind.app.rawValue ? .app : .chat
                var critical = false
                var summary: String? = nil
                if case .known(let block) = o.security.parsed { summary = block.summary }
                if case .reminder(_, let ids) = p {
                    critical = s.classes.contains { ids.contains($0.classId) && $0.level == .critical }
                }
                let text = UpdateNoticeText.message(p, version: o.version, critical: critical, summary: summary,
                                                    lang: deps.language(), surface: surface)
                UpdateNotice.consume(&s, p, text: text, env: env, destination: destination,
                                     noticeGeneration: setting.generation, newClassId: deps.newClassId)
                return (true, s.attempt(p.kind))
            }
            if record != nil { saveFailed = false }
            return record
        } catch {
            saveFailed = true
            deps.log("update notice: state cannot be saved — nothing sent (\(error.localizedDescription))")
            return nil
        }
    }

    func settle(_ record: AttemptRecord, _ outcome: UpdateNotice.SendOutcome) {
        let env = self.env
        do {
            try UpdateNoticeStore.transaction(deps.paths, now: env.now) { setting, s in
                // After /deleteuserdata nothing is written back.
                guard setting.generation == record.noticeGeneration else { return (false, ()) }
                UpdateNotice.recordOutcome(&s, kind: record.kind, outcome, env: env)
                return (true, ())
            }
        } catch {
            saveFailed = true
            deps.log("update notice: outcome cannot be saved (\(error.localizedDescription))")
        }
    }

    func retryIfDue(_ kind: AttemptRecord.Kind) async {
        let env = self.env
        let record: AttemptRecord?
        do {
            record = try UpdateNoticeStore.transaction(deps.paths, now: env.now) { setting, s in
                guard setting.enabled else { return (false, nil) }
                switch UpdateNotice.retryDecision(s, kind: kind, env: env, noticeGeneration: setting.generation,
                                                  channelGeneration: deps.channelGeneration) {
                case .notYet:
                    return (false, nil)
                case .drop:
                    UpdateNotice.dropAttempt(&s, kind: kind)
                    return (true, nil)
                case .retry:
                    UpdateNotice.markRetryInFlight(&s, kind: kind)
                    return (true, s.attempt(kind))
                }
            }
        } catch {
            saveFailed = true
            return
        }
        guard let record else { return }
        let outcome = await deps.send(record)
        settle(record, outcome)
    }

    // MARK: - Status

    func status() -> UpdateNoticeText.Status {
        let (setting, state) = UpdateNoticeStore.snapshot(deps.paths)
        return UpdateNoticeText.status(setting: setting, state: state, installed: deps.installed,
                                       installedVersion: deps.installedVersion, domain: domain,
                                       now: deps.now(), saveFailed: saveFailed)
    }

    /// Status from any process (doctor, menu, a second terminal): reads only.
    nonisolated static func liveStatus(now: Date = Date()) -> UpdateNoticeText.Status {
        let (setting, state) = UpdateNoticeStore.snapshot(.live)
        return UpdateNoticeText.status(setting: setting, state: state, installed: adaCLIReleaseSequence,
                                       installedVersion: adaCLIVersion, domain: noticeDomain(.effective),
                                       now: now, saveFailed: saveFailedFlag.value)
    }
}

final class UpdateNoticeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ v: Bool) { lock.lock(); stored = v; lock.unlock() }
}
