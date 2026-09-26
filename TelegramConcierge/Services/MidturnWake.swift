import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Mid-turn early wake (MIDTURN_EARLY_WAKE plan v7, release 1a).
//
// The queue (`ConversationManager.pendingMidTurnMessages`) stays the only
// truth about user messages. Everything in this file only ACCELERATES what the
// queue already decides: a user message that arrives while a long bash wait
// is blocking the tool round wakes that wait after a short, non-sliding grace
// window, the job moves to the background (it keeps running and its
// completion is delivered later), and the round ends so the model reads the
// message now instead of minutes from now.

/// Why a wait stopped early. Rendered as `wake_reason` in the moved result.
enum MidturnWakeReason: String, Sendable {
    /// A user message arrived and its grace window passed.
    case userMessage = "user_message"
    /// The hidden BRIGLIA_MIDTURN_FORCE_DETACH test setting (§3.13).
    case testForced = "test_forced"
}

/// Per-call wake scope, bound as a task-local by the MAIN executor's
/// `executeParallel` around each call (depth 0 only: subagents, nested Web
/// runs and watcher triage never wake). Captured when the call starts, never
/// read later from long-lived executor state, so a leftover task from an
/// older turn can never be woken by — or detach into — a newer turn.
struct WakeContext: Sendable {
    let turnRunId: UUID
    let callId: String
    let toolName: String
    /// Launch-call fingerprint (tool name + canonical arguments).
    let fingerprint: String
    let callStartedAt: ContinuousClock.Instant
    /// The last history message when the batch started: the search boundary
    /// for this job's settlement evidence (a crash record's anchor).
    let historyAnchorMessageId: UUID?

    @TaskLocal static var current: WakeContext?
}

/// Hidden field-trial switch (§3.13): `BRIGLIA_MIDTURN_FORCE_DETACH=1`, read
/// once at process start. Off = a constant `false`: no code path differs and
/// no request byte changes. On = every eligible depth-0 bash wait gets a
/// per-call synthetic wake `TurnWakeCenter.defaultGraceSeconds` (3 s) after the call STARTED, without any fake user
/// message, generation, annotation or suppression. Deliberately an env var:
/// neither the agent nor a copied config can switch it on, and it never
/// travels in a Mind export. Absent from help, menus, /commands and setup.
enum ForceDetach {
    static let environmentKey = "BRIGLIA_MIDTURN_FORCE_DETACH"
    static let isEnabled: Bool = {
        let raw = ProcessInfo.processInfo.environment[environmentKey] ?? ""
        return raw == "1" || raw.lowercased() == "true"
    }()
    /// Test seam: overrides `isEnabled` in-process (selftests only).
    nonisolated(unsafe) static var overrideForTesting: Bool?
    static var active: Bool { overrideForTesting ?? isEnabled }
}

/// One wake center per process; one armed turn at a time (turns are
/// serialized by the manager). All state transitions are actor-isolated, so
/// arm/fire/consume/disarm and every subscription resolve exactly once.
actor TurnWakeCenter {
    static let shared = TurnWakeCenter()

    /// Grace window: 3 s, non-sliding wait-then-check (owner decision O4;
    /// shortened from 8 s by the owner, 2026-09-26). The forced-detach
    /// test setting uses the same value. Test seam below.
    static let defaultGraceSeconds: Double = 3
    nonisolated(unsafe) static var graceSecondsForTesting: Double?
    static var graceSeconds: Double { graceSecondsForTesting ?? defaultGraceSeconds }

    private var armedRunId: UUID?
    /// Fired but not yet consumed generations with their enqueue instants,
    /// oldest first. The grace window is anchored to the OLDEST one and is
    /// never reset by later messages (non-sliding).
    private var pending: [(generation: UInt64, enqueuedAt: ContinuousClock.Instant)] = []
    private var windowDeadline: ContinuousClock.Instant?
    private var woken = false
    private var highestConsumedGeneration: UInt64 = 0
    private var timerTask: Task<Void, Never>?
    private var subscribers: [UUID: CheckedContinuation<MidturnWakeReason?, Never>] = [:]
    /// Counters for tests and /status diagnostics.
    private(set) var wakeCount = 0

    func arm(runId: UUID) {
        resolveAll(nil)
        armedRunId = runId
        pending = []
        windowDeadline = nil
        woken = false
        // Consumption is per run (fires carry their run id, so a late fire
        // of an older run is rejected by the run check).
        highestConsumedGeneration = 0
        timerTask?.cancel(); timerTask = nil
        // A message enqueued between the manager claiming the run and this
        // (asynchronous) arm must not lose its wake.
        let early = earlyFires.filter { $0.runId == runId }
        earlyFires.removeAll()
        for fire in early { self.fire(runId: runId, generation: fire.generation, at: fire.at) }
    }

    /// Turn end, /stop, wipe, Mind import: cancel any pending grace timer and
    /// resolve every subscriber as "not woken".
    func disarm(runId: UUID? = nil) {
        if let runId, armedRunId != runId { return }
        armedRunId = nil
        pending = []
        windowDeadline = nil
        woken = false
        timerTask?.cancel(); timerTask = nil
        resolveAll(nil)
    }

    /// A `.userText` was enqueued (after it was persisted) with this
    /// in-memory generation. Late fires for consumed generations are ignored.
    func fire(runId: UUID, generation: UInt64, at instant: ContinuousClock.Instant = .now) {
        if armedRunId == nil {
            earlyFires.append((runId, generation, instant))
            if earlyFires.count > 64 { earlyFires.removeFirst() }
            return
        }
        guard armedRunId == runId, generation > highestConsumedGeneration,
              !pending.contains(where: { $0.generation == generation }) else { return }
        pending.append((generation, instant))
        scheduleWindowIfNeeded()
    }

    /// The drain's history save succeeded for every generation <= `upTo`.
    /// A newer unconsumed generation starts its own window (anchored to its
    /// own enqueue time) only now, after the older wake.
    func consume(runId: UUID, upTo generation: UInt64) {
        guard armedRunId == runId else { return }
        highestConsumedGeneration = max(highestConsumedGeneration, generation)
        let before = pending.count
        pending.removeAll { $0.generation <= highestConsumedGeneration }
        guard pending.count != before else { return }
        timerTask?.cancel(); timerTask = nil
        windowDeadline = nil
        woken = false
        scheduleWindowIfNeeded()
    }

    /// Suspend until the armed turn's grace window passes (→ `.userMessage`)
    /// or the turn is disarmed / the caller cancelled (→ nil). Atomic
    /// check-and-register: an already-woken window returns at once.
    func waitForWake(runId: UUID) async -> MidturnWakeReason? {
        // A subscription for a run that is not armed never wakes (it resolves
        // nil at the next arm/disarm or when the caller is cancelled).
        let orphan = armedRunId != runId
        if !orphan && woken { return .userMessage }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<MidturnWakeReason?, Never>) in
                if Task.isCancelled { cont.resume(returning: nil); return }
                if !orphan && woken { cont.resume(returning: .userMessage); return }
                subscribers[token] = cont
                if orphan { orphanTokens.insert(token) }
            }
        } onCancel: {
            Task { await self.cancelSubscription(token) }
        }
    }

    /// True while a wake window is running or has fired for the armed turn.
    func hasPendingWake(runId: UUID) -> Bool {
        armedRunId == runId && !pending.isEmpty
    }

    func isWoken(runId: UUID) -> Bool { armedRunId == runId && woken }

    // MARK: private

    private var orphanTokens: Set<UUID> = []
    private var earlyFires: [(runId: UUID, generation: UInt64, at: ContinuousClock.Instant)] = []

    private func cancelSubscription(_ token: UUID) {
        orphanTokens.remove(token)
        subscribers.removeValue(forKey: token)?.resume(returning: nil)
    }

    private func resolveAll(_ reason: MidturnWakeReason?) {
        let current = subscribers
        subscribers.removeAll()
        orphanTokens.removeAll()
        for (_, cont) in current { cont.resume(returning: reason) }
    }

    private func scheduleWindowIfNeeded() {
        guard windowDeadline == nil, !woken, let oldest = pending.first, let runId = armedRunId else { return }
        let deadline = oldest.enqueuedAt.advanced(by: .milliseconds(Int64(Self.graceSeconds * 1000)))
        windowDeadline = deadline
        timerTask = Task { [weak self] in
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
            if Task.isCancelled { return }
            await self?.windowExpired(runId: runId, deadline: deadline)
        }
    }

    private func windowExpired(runId: UUID, deadline: ContinuousClock.Instant) {
        guard armedRunId == runId, windowDeadline == deadline, !pending.isEmpty else { return }
        woken = true
        wakeCount += 1
        let current = subscribers.filter { !orphanTokens.contains($0.key) }
        for (token, cont) in current {
            subscribers.removeValue(forKey: token)
            cont.resume(returning: .userMessage)
        }
    }
}

/// The wake signal one blocked depth-0 wait listens to: the armed turn's
/// grace window, or — with the hidden test setting on — a per-call synthetic
/// wake after the same grace (3 s) from the call start. Whichever resolves first wins; the
/// registry actor then decides wake vs finish exactly once.
enum MidturnWakeSignal {
    /// Forced-detach delay after the call started (test seam).
    nonisolated(unsafe) static var forcedDelaySecondsForTesting: Double?
    static var forcedDelaySeconds: Double { forcedDelaySecondsForTesting ?? TurnWakeCenter.defaultGraceSeconds }

    static func next(_ context: WakeContext) async -> MidturnWakeReason? {
        await withTaskGroup(of: MidturnWakeReason?.self) { group in
            group.addTask { await TurnWakeCenter.shared.waitForWake(runId: context.turnRunId) }
            if ForceDetach.active {
                group.addTask {
                    let deadline = context.callStartedAt.advanced(by: .milliseconds(Int64(forcedDelaySeconds * 1000)))
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    if remaining > .zero {
                        do { try await Task.sleep(for: remaining) } catch { return nil }
                    }
                    return Task.isCancelled ? nil : .testForced
                }
            }
            var result: MidturnWakeReason?
            for await value in group {
                if let value { result = value; break }
            }
            group.cancelAll()
            return result
        }
    }
}

enum SHA256Hex {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
