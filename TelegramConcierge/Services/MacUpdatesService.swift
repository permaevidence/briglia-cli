import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `macupdates.json` (§9.5.9): written only under the shared
/// `update-check.lock`, atomically, ≤ 64 KiB; quarantined when corrupt.
enum MacUpdatesStore {
    static let maxBytes = 64 * 1024

    static func url(_ p: UpdateNoticeStore.Paths) -> URL {
        p.state.deletingLastPathComponent().appendingPathComponent("macupdates.json")
    }

    static func transaction<R>(_ p: UpdateNoticeStore.Paths, now: Date,
                               _ body: (UpdateNoticeStore.SettingRead, inout MacUpdatesState) throws -> R) throws -> R {
        try UpdateNoticeStore.withLock(p) {
            let setting = UpdateNoticeStore.readSetting(p)
            var s = LocalAdvisoryStore.read(MacUpdatesState.self, at: url(p), maxBytes: maxBytes, quarantine: true, now: now) ?? MacUpdatesState()
            if s.schema != 1 { s = MacUpdatesState() }
            let s0 = s
            let r = try body(setting, &s)
            if s != s0 { try LocalAdvisoryStore.write(s, to: url(p), maxBytes: maxBytes) }
            return r
        }
    }

    static func snapshot(_ p: UpdateNoticeStore.Paths = .live) -> MacUpdatesState? {
        LocalAdvisoryStore.read(MacUpdatesState.self, at: url(p), maxBytes: maxBytes, quarantine: false, now: Date())
    }
}

/// Runtime of the weekly message, ticked by the update notice's loop in the
/// process that holds the instance lock. Independent of the advisory key.
@MainActor
final class MacUpdatesService {
    struct Deps {
        var paths: UpdateNoticeStore.Paths
        var now: () -> Date
        /// Read-only evaluation, off the main actor.
        var evaluate: () async -> MacUpdates.Evaluation
        var language: () -> String
        var isIdle: () -> Bool
        var destination: () -> UpdateNotice.Destination
        var channelGeneration: (String?) -> UInt64
        var send: (String?, String?, UInt64, String) async -> UpdateNotice.SendOutcome
        var log: (String) -> Void
    }

    private(set) static var current: MacUpdatesService?

    @discardableResult
    static func launch(deps: Deps) -> MacUpdatesService {
        if let running = current { return running }
        let s = MacUpdatesService(deps: deps)
        current = s
        s.start()
        return s
    }

    let deps: Deps
    private(set) var evaluations = 0
    private(set) var saveFailed = false
    private var busy = false

    init(deps: Deps) { self.deps = deps }

    func start() {
        _ = try? MacUpdatesStore.transaction(deps.paths, now: deps.now()) { _, s in
            _ = MacUpdates.settleCrashed(&s, now: deps.now())
        }
    }

    func stop() { if Self.current === self { Self.current = nil } }

    func tick() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if evaluationDue() { await evaluateAndStore() }
        await deliver()
    }

    func evaluationDue() -> Bool {
        guard UpdateNoticeStore.snapshot(deps.paths).0.enabled else { return false }
        guard let at = MacUpdatesStore.snapshot(deps.paths)?.report?.at else { return true }
        return deps.now().timeIntervalSince(at) >= MacUpdates.evaluationInterval || deps.now() < at
    }

    /// State-only: reconcile (positive resolution), clamp the clock, keep
    /// the report for display.
    func evaluateAndStore() async {
        let e = await deps.evaluate()
        evaluations += 1
        do {
            try MacUpdatesStore.transaction(deps.paths, now: deps.now()) { setting, s in
                guard setting.enabled else { return }
                MacUpdates.reconcile(&s, e)
                MacUpdates.clampClock(&s, now: deps.now())
                s.report = e
            }
            saveFailed = false
        } catch {
            saveFailed = true
            deps.log("weekly updates: state cannot be saved (\(error.localizedDescription))")
        }
    }

    func deliver() async {
        guard deps.isIdle() else { return }
        if await retryIfDue() { return }
        let (setting, _) = UpdateNoticeStore.snapshot(deps.paths)
        guard setting.enabled, let s = MacUpdatesStore.snapshot(deps.paths), let report = s.report,
              MacUpdates.sendDue(s, report, now: deps.now()) else { return }
        // Pre-send recheck: a FRESH evaluation; the message describes it.
        let fresh = await deps.evaluate()
        guard deps.isIdle() else { return }
        let now = deps.now()
        let generation = setting.generation
        var record: (text: String, destination: UpdateNotice.Destination)?
        do {
            record = try MacUpdatesStore.transaction(deps.paths, now: now) { setting, s in
                guard setting.enabled, setting.generation == generation else { return nil }
                MacUpdates.reconcile(&s, fresh)
                MacUpdates.clampClock(&s, now: now)
                s.report = fresh
                guard MacUpdates.sendDue(s, fresh, now: now) else { return nil }
                let destination = deps.destination()
                let text = MacUpdatesText.message(fresh.waiting, lang: deps.language())
                guard !text.isEmpty else { return nil }
                MacUpdates.consume(&s, fresh, text: text, noticeGeneration: setting.generation, destination: destination, now: now)
                return (text, destination)
            }
        } catch {
            saveFailed = true
            deps.log("weekly updates: state cannot be saved — nothing sent (\(error.localizedDescription))")
            return
        }
        guard let record else { return }
        let outcome = await deps.send(record.destination.channelKind, record.destination.chatId,
                                      record.destination.channelGeneration, record.text)
        settle(outcome, generation: generation)
    }

    func settle(_ outcome: UpdateNotice.SendOutcome, generation: UInt64) {
        do {
            try MacUpdatesStore.transaction(deps.paths, now: deps.now()) { setting, s in
                guard setting.generation == generation else { return }
                MacUpdates.recordOutcome(&s, outcome, now: deps.now())
            }
        } catch {
            saveFailed = true
        }
    }

    /// A proven refusal: retried (≤ 3 within 1 h) only while every consumed
    /// key is still waiting in a fresh evaluation; otherwise dropped.
    func retryIfDue() async -> Bool {
        let now = deps.now()
        let (setting, _) = UpdateNoticeStore.snapshot(deps.paths)
        guard let s = MacUpdatesStore.snapshot(deps.paths), let a = s.attempt else { return false }
        switch MacUpdates.retryDecision(s, now: now, noticeGeneration: setting.generation, channelGeneration: deps.channelGeneration) {
        case .none: return false
        case .notYet: return true
        case .drop:
            _ = try? MacUpdatesStore.transaction(deps.paths, now: now) { _, s in if s.attempt == a { s.attempt = nil } }
            return true
        case .retry:
            break
        }
        let fresh = await deps.evaluate()
        let now2 = deps.now()
        guard deps.isIdle() else { return true }
        let record: MacUpdatesAttempt?
        do {
            record = try MacUpdatesStore.transaction(deps.paths, now: now2) { setting, s in
                guard setting.enabled, let cur = s.attempt, cur == a,
                      MacUpdates.retryDecision(s, now: now2, noticeGeneration: setting.generation,
                                               channelGeneration: deps.channelGeneration) == .retry else { return nil }
                guard MacUpdates.stillValid(cur, fresh) else { s.attempt = nil; return nil }
                MacUpdates.markRetryInFlight(&s)
                return s.attempt
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
