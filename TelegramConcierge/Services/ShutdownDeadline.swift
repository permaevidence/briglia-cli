import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A point on the monotonic clock by which a shutdown must have returned.
///
/// Every wait in the child-shutdown path (`TerminalSession.shutdownChildProcesses`
/// → `MCPRegistry.shutdownForExit` → `MCPClient.shutdown` → `settle`) is bounded
/// by ONE of these rather than by nominal sleep counts: a poll that sleeps
/// 50 ms twenty times has slept a second only on an idle machine. Under load
/// (Codex round 2: 3.13–3.17 s on a 3 s forced-exit budget, one server still
/// alive at return) the nominal accounting undercounts real time and the
/// SIGKILL escalation arrives after the caller has already given up.
struct ShutdownDeadline: Sendable, Equatable {
    /// `DispatchTime` uptime nanoseconds: monotonic on macOS and Linux, and
    /// what `DispatchSemaphore.wait(timeout:)` compares against, so the
    /// semaphore in `shutdownChildProcesses` and the polls below it agree.
    let uptimeNanos: UInt64

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func after(seconds: Double) -> ShutdownDeadline {
        ShutdownDeadline(uptimeNanos: now() + UInt64(max(0, seconds) * 1_000_000_000))
    }

    static func after(nanos: UInt64) -> ShutdownDeadline {
        ShutdownDeadline(uptimeNanos: now() + nanos)
    }

    var remainingNanos: UInt64 {
        let t = Self.now()
        return uptimeNanos > t ? uptimeNanos - t : 0
    }

    var hasPassed: Bool { Self.now() >= uptimeNanos }

    var dispatchTime: DispatchTime { DispatchTime(uptimeNanoseconds: uptimeNanos) }

    /// The earlier of the two.
    func earliest(_ other: ShutdownDeadline?) -> ShutdownDeadline {
        guard let other else { return self }
        return other.uptimeNanos < uptimeNanos ? other : self
    }

    /// This deadline moved earlier by `nanos` (never before now).
    func minus(nanos: UInt64) -> ShutdownDeadline {
        let t = Self.now()
        let target = uptimeNanos > nanos ? uptimeNanos - nanos : 0
        return ShutdownDeadline(uptimeNanos: max(target, t))
    }

    /// Sleep one poll step, never past the deadline.
    func sleepStep(_ step: UInt64) async {
        let remaining = remainingNanos
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: min(step, remaining))
    }
}

/// The two instants that drive one client's shutdown: when to stop waiting
/// for SIGTERM to work and SIGKILL (`killAt`), and when to stop waiting for
/// collection and return (`giveUpAt`). Shared between the task that performs
/// the shutdown and every later caller that joins it: a joiner with an
/// EARLIER deadline (a forced exit landing on a shutdown that a bootstrap
/// failure had already started) tightens the plan in place, so the running
/// cleanup escalates and returns by the tighter deadline instead of the
/// joiner returning while the cleanup is still waiting out its own grace.
final class ShutdownPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var _killAt: ShutdownDeadline
    private var _giveUpAt: ShutdownDeadline

    /// How much of a caller's budget is reserved for SIGKILL collection: the
    /// grace period is cut short so that termination is INITIATED for every
    /// process with at least this long left for the exit to be collected.
    static let collectionReserveNanos: UInt64 = 1_000_000_000

    /// `grace`: how long SIGTERM gets when nothing tighter is asked;
    /// `reap`: how long collection gets after SIGKILL when nothing tighter is
    /// asked; `deadline`: the caller's hard bound, if any.
    init(graceNanos: UInt64, reapNanos: UInt64, deadline: ShutdownDeadline?) {
        let start = ShutdownDeadline.now()
        var kill = ShutdownDeadline(uptimeNanos: start + graceNanos)
        var giveUp = ShutdownDeadline(uptimeNanos: kill.uptimeNanos + reapNanos)
        if let deadline {
            giveUp = giveUp.earliest(deadline)
            kill = kill.earliest(deadline.minus(nanos: Self.collectionReserveNanos))
        }
        _killAt = kill
        _giveUpAt = giveUp
    }

    var killAt: ShutdownDeadline { lock.lock(); defer { lock.unlock() }; return _killAt }
    var giveUpAt: ShutdownDeadline { lock.lock(); defer { lock.unlock() }; return _giveUpAt }

    /// Pull both instants earlier to honour `deadline`; never later.
    func tighten(to deadline: ShutdownDeadline?) {
        guard let deadline else { return }
        lock.lock(); defer { lock.unlock() }
        _giveUpAt = _giveUpAt.earliest(deadline)
        _killAt = _killAt.earliest(deadline.minus(nanos: Self.collectionReserveNanos))
    }
}
