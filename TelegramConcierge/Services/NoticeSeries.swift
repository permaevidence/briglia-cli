import Foundation

// MARK: - Visibility notices (/stop visibility plan v3 §4.1, §9)
//
// The "still finishing" reply of a stopped request, its repeats and its one
// completion notice — and, separately, the disk-saving pause/recovery notices
// — are ORDERED status notices. They deliberately do not ride on
// `ParkedOutboundQueue`: a parked item can leave that queue (capacity trim,
// explicit removal) while its resend is still on the wire, so queue
// membership says nothing about delivery (Codex round 2). Each series
// instead keeps its own FIFO with exactly one send in flight; the next item
// goes out only after its predecessor's send SETTLED (the transport call
// returned), or the series gave up or was invalidated — a later item never
// jumps ahead. Ordinary replies (`sendText`, parking, flushing) are unchanged.

/// Transport-identity generations, per channel kind. Bumped on the main
/// actor by `/switchbot`'s bot replacement, by `/deleteuserdata` and by any
/// Telegram token change at registration. Lock-protected (not actor state) so
/// the Telegram actor can read it SYNCHRONOUSLY at the instant it captures
/// its credentials for a notice send: the check and the request construction
/// happen with no suspension between them (Codex round-3 transport-boundary
/// requirement).
enum NoticeChannelGenerations {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var values: [ChannelKind: UInt64] = [:]

    static func current(_ kind: ChannelKind) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return values[kind] ?? 0
    }

    static func bump(_ kind: ChannelKind) {
        lock.lock(); values[kind, default: 0] &+= 1; lock.unlock()
    }
}

/// A notice send refused at the transport because the channel's credentials
/// (generation) changed since the series was created. Never retried: the
/// series is invalidated.
enum NoticeTransportError: Error {
    case credentialsChanged
}

/// One ordered series of visibility notices to one destination.
@MainActor
final class NoticeSeries {
    enum Target: Hashable {
        /// Telegram/WhatsApp chat.
        case wire(ChannelAddress)
        /// Terminal and app socket: an undeduplicated local event stream.
        case local
    }

    /// Monotonic time and an interruptible wait (injectable for tests).
    struct Clock {
        var nowNanos: @MainActor () -> UInt64
        var sleep: @MainActor (UInt64) async -> Void

        static let live = Clock(
            nowNanos: { StageMarkers.monotonicNanos() },
            sleep: { nanos in try? await Task.sleep(nanoseconds: nanos) }
        )
    }

    /// Test seam: a fake clock for series created while it is set.
    nonisolated(unsafe) static var clockOverrideForTesting: Clock?

    /// Pause after the n-th failed attempt of the head (1-based): the same
    /// 2 s / 4 s as `sendText`'s three quick attempts, then the series' own
    /// backoff 30 s, 60 s, 120 s … capped at 10 minutes.
    static func pauseSeconds(afterFailedAttempt n: Int) -> UInt64 {
        switch n {
        case ..<1: return 0
        case 1: return 2
        case 2: return 4
        default:
            let exponent = min(n - 3, 5)
            return min(30 << UInt64(exponent), 600)
        }
    }

    /// Give-up age of the head, measured from its first attempt (monotonic).
    static let giveUpNanos: UInt64 = 3_600 * 1_000_000_000

    let id = UUID()
    let target: Target
    /// Channel generation captured at creation; every attempt re-checks it.
    let generation: UInt64

    private(set) var pending: [String] = []
    /// Texts whose send settled successfully, in order (status and tests).
    private(set) var delivered: [String] = []
    private(set) var inFlight = false
    private(set) var anySendBegun = false
    private(set) var invalidated = false
    private(set) var gaveUp = false
    /// The completion (or recovery) notice is queued: nothing may follow it.
    private(set) var terminalQueued = false
    /// Local series of a captured socket/terminal command: later items wait
    /// until the command's own result has been handed to its client.
    private var captureHolds: Int

    private let attempt: @MainActor (String) async throws -> Void
    private let isCurrent: @MainActor () -> Bool
    private let afterDelivery: @MainActor () async -> Void
    private let localEmit: (@MainActor (String) -> Void)?
    private let clock: Clock
    private var headFirstAttemptNanos: UInt64?
    private var pumpTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var settledReported = false
    /// Called once when the series has nothing left to do (registry release).
    var onFinished: (@MainActor (NoticeSeries) -> Void)?
    /// Diagnostics hook (log lines).
    var log: (@MainActor (String) -> Void)?

    /// A wire series: `attempt` performs ONE transport send.
    init(wire address: ChannelAddress, generation: UInt64,
         attempt: @escaping @MainActor (String) async throws -> Void,
         isCurrent: @escaping @MainActor () -> Bool,
         afterDelivery: @escaping @MainActor () async -> Void) {
        self.target = .wire(address)
        self.generation = generation
        self.attempt = attempt
        self.isCurrent = isCurrent
        self.afterDelivery = afterDelivery
        self.localEmit = nil
        self.captureHolds = 0
        self.clock = Self.clockOverrideForTesting ?? .live
    }

    /// A local series: delivery is a synchronous emit that settles at once.
    init(localEmit: @escaping @MainActor (String) -> Void, awaitingCapture: Bool) {
        self.target = .local
        self.generation = 0
        self.attempt = { _ in }
        self.isCurrent = { true }
        self.afterDelivery = {}
        self.localEmit = localEmit
        self.captureHolds = awaitingCapture ? 1 : 0
        self.clock = Self.clockOverrideForTesting ?? .live
    }

    /// Invalidated (intentional clearing) or given up: permanently closed.
    var isClosed: Bool { invalidated || gaveUp }
    var isAwaitingCapture: Bool { captureHolds > 0 }

    /// Appends one notice; false when the series is closed or its terminal
    /// notice is already queued. Check-and-append is synchronous on the main
    /// actor.
    @discardableResult
    func append(_ text: String, terminal: Bool = false) -> Bool {
        guard !isClosed, !terminalQueued else { return false }
        pending.append(text)
        if terminal { terminalQueued = true }
        pump()
        return true
    }

    /// A captured command's result is about to be delivered by another
    /// caller: hold later items until `releaseCapture()`.
    func holdForCapture() { captureHolds += 1 }

    func releaseCapture() {
        guard captureHolds > 0 else { return }
        captureHolds -= 1
        pump()
    }

    /// Intentional clearing (/switchbot, /deleteuserdata, generation
    /// change): drop pending items, cancel a waiting retry. A send already on
    /// the wire cannot be recalled; nothing after it is sent and its late
    /// success never restarts the series.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        pending.removeAll()
        waitTask?.cancel()
        log?("notice series \(id.uuidString.prefix(8)) invalidated")
        reportFinishedIfDone()
    }

    private func pump() {
        guard !isClosed, captureHolds == 0, !pending.isEmpty else { reportFinishedIfDone(); return }
        if let localEmit {
            // Local delivery cannot fail and settles immediately.
            while captureHolds == 0, !isClosed, !pending.isEmpty {
                let head = pending.removeFirst()
                anySendBegun = true
                localEmit(head)
                delivered.append(head)
            }
            reportFinishedIfDone()
            return
        }
        guard pumpTask == nil else { return }
        pumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
            // Synchronous with the drain's final emptiness check: an append
            // that raced it either was drained or starts a new pump below.
            self.pumpTask = nil
            if !self.isClosed, self.captureHolds == 0, !self.pending.isEmpty { self.pump() }
            self.reportFinishedIfDone()
        }
    }

    private func drain() async {
        while !isClosed, captureHolds == 0, let head = pending.first {
            if headFirstAttemptNanos == nil { headFirstAttemptNanos = clock.nowNanos() }
            var failedAttempts = 0
            var sent = false
            while !isClosed {
                if failedAttempts > 0, let first = headFirstAttemptNanos,
                   clock.nowNanos() &- first >= Self.giveUpNanos {
                    // Give-up closes the series permanently: the head and
                    // every later item are dropped, never sent out of order.
                    gaveUp = true
                    log?("notice series \(id.uuidString.prefix(8)) gave up after \(failedAttempts) attempt(s); \(pending.count) notice(s) dropped")
                    pending.removeAll()
                    break
                }
                // Generation / registration re-checked before EVERY attempt.
                guard isCurrent() else { invalidate(); break }
                anySendBegun = true
                inFlight = true
                do {
                    try await attempt(head)
                    inFlight = false
                    sent = true
                    break
                } catch NoticeTransportError.credentialsChanged {
                    inFlight = false
                    invalidate()
                    break
                } catch {
                    inFlight = false
                    failedAttempts += 1
                    log?("notice series \(id.uuidString.prefix(8)) attempt \(failedAttempts) failed: \(error.localizedDescription)")
                }
                if isClosed { break }
                let nanos = Self.pauseSeconds(afterFailedAttempt: failedAttempts) * 1_000_000_000
                let wait = Task { @MainActor [clock] in await clock.sleep(nanos) }
                waitTask = wait
                await wait.value
                waitTask = nil
            }
            // A late success after invalidation must not advance or append.
            guard sent, !isClosed, pending.first == head else { break }
            pending.removeFirst()
            delivered.append(head)
            headFirstAttemptNanos = nil
            await afterDelivery()
        }
    }

    private func reportFinishedIfDone() {
        guard !settledReported, pumpTask == nil, !inFlight else { return }
        let done = isClosed || (terminalQueued && pending.isEmpty)
        guard done else { return }
        settledReported = true
        onFinished?(self)
    }
}
