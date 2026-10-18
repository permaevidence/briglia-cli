import Foundation

/// Per-round wall-clock deadline for the Web researcher's own model requests
/// (WEB_OFFLINE_HANG fix, 2026-10-18).
///
/// Why: the researcher's model rounds had no deadline of their own. Each
/// round inherited the main-agent transport budget: 360 s without a byte on
/// hosted endpoints (1200 s overall while bytes trickle) and up to three
/// adapter retries after a timeout, so one stalled provider response could
/// hold a research run for ~24 minutes (4 × 360 s) — the v4 benchmark's
/// 24-minute stall, and the three 300 s watchdog kills in the Thread v5
/// timing trials, where a round-2 request got no answer at all. The 120 s
/// deadlines elsewhere only bound page reading (web_query/web_extract/
/// web_fetch backends), the 20-minute staleness timer only races TOOL
/// batches, and `web_tools_failed` is only decided after the loop ends; none
/// of them ever sees a model request that never returns.
///
/// The deadline wraps one whole `generateResponse` call (including the
/// adapter's own retries). On expiry the request task is cancelled (the
/// transports cancel their URLSession task on Task cancellation) and the
/// caller decides whether to retry. The race uses an unstructured task and a
/// resolve-once continuation, so the deadline returns even if the request
/// ignores cancellation (same pattern as the tool-batch staleness race).
enum WebRoundDeadline {
    /// Hosted APIs (OpenRouter, OpenAI, ChatGPT subscription, OpenCode, any
    /// remote OpenAI-compatible API). The trials' rounds took 1–8 s; 180 s is
    /// far above a healthy round, report finals included, and still
    /// detects a stall in half the time of the 360 s transport idle clock.
    static let hostedSeconds: TimeInterval = 180
    /// Local inference (LM Studio-style profiles, loopback or private-LAN
    /// hosts): slow hardware can legitimately need minutes for one round;
    /// one round never exceeds the transport's own 1200 s per-request budget.
    static let localSeconds: TimeInterval = 1200
    /// Round deadlines tolerated per run: the first expiry retries the same
    /// round once; the second ends the run with `web_model_timeout`.
    static let maxTimeoutsPerRun = 2

    /// Selftest seam: forces the deadline (seconds) for every Web run.
    nonisolated(unsafe) static var overrideForTesting: TimeInterval?

    struct Expired: Error, LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { "the research model did not answer within \(Int(seconds)) s" }
    }

    static func seconds(for context: ProviderExecutionContext?) -> TimeInterval {
        if let overrideForTesting { return overrideForTesting }
        guard let context else { return hostedSeconds }
        if context.subscriptionGeneration != nil { return hostedSeconds }
        switch context.provider {
        case .openRouter: return hostedSeconds
        case .lmStudio: return localSeconds
        case .openAICompatible: return isLocalHost(context.endpoint) ? localSeconds : hostedSeconds
        }
    }

    /// Loopback, link-local, private-LAN and mDNS hosts (a home inference
    /// server reached through an OpenAI-compatible profile).
    static func isLocalHost(_ endpoint: String) -> Bool {
        guard let host = URL(string: endpoint)?.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".lan")
            || host.hasSuffix(".home.arpa") || host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fd") && host.contains(":") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, let b) where (16...31).contains(b): return true
        case (100, let b) where (64...127).contains(b): return true  // CGNAT / Tailscale
        default: return false
        }
    }

    /// Runs `operation`, throwing `Expired` once `seconds` elapse first. The
    /// operation's task is cancelled on expiry and on caller cancellation.
    /// `operation` unchanged when `seconds` is nil (every non-Web run).
    static func bounded<T>(_ seconds: TimeInterval?, _ operation: @escaping () async throws -> T) async throws -> T {
        guard let seconds else { return try await operation() }
        return try await race(seconds: seconds, operation)
    }

    static func race<T>(seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
        let box = RaceBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                guard box.install(continuation) else { return }
                let work = Task {
                    do { box.resolve(.success(try await operation())) }
                    catch { box.resolve(.failure(error)) }
                }
                let timer = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) } catch { return }
                    box.resolve(.failure(Expired(seconds: seconds)))
                }
                box.attach(work: work, timer: timer)
            }
        } onCancel: {
            box.resolve(.failure(CancellationError()))
        }
    }

    private final class RaceBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var pending: Result<T, Error>?
        private var work: Task<Void, Never>?
        private var timer: Task<Void, Never>?
        private var resolved = false

        /// False when the race was already resolved (cancelled before start).
        func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
            lock.lock()
            if resolved, let pending {
                lock.unlock(); continuation.resume(with: pending); return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func attach(work: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock()
            let late = resolved
            if !late { self.work = work; self.timer = timer }
            lock.unlock()
            if late { work.cancel(); timer.cancel() }
        }

        func resolve(_ result: Result<T, Error>) {
            lock.lock()
            guard !resolved else { lock.unlock(); return }
            resolved = true
            let continuation = continuation; self.continuation = nil
            if continuation == nil { pending = result }
            let work = work, timer = timer
            self.work = nil; self.timer = nil
            lock.unlock()
            timer?.cancel()
            // The winner is either the operation (its task is finished) or the
            // deadline / caller cancellation: stop the in-flight request.
            work?.cancel()
            continuation?.resume(with: result)
        }
    }
}

/// The run-level outcome after `WebRoundDeadline.maxTimeoutsPerRun` expiries.
struct WebModelRoundTimeoutError: Error, LocalizedError {
    let seconds: TimeInterval
    let timeouts: Int
    var errorDescription: String? {
        "the research model did not answer within \(Int(seconds)) s (\(timeouts) round deadlines in this run); research stopped"
    }
}

/// Counts round-deadline expiries across one run: the first retries the
/// round, the `maxTimeoutsPerRun`-th throws `WebModelRoundTimeoutError`.
final class WebRoundTimeoutTally: @unchecked Sendable {
    private(set) var count = 0
    func expired(_ expiry: WebRoundDeadline.Expired) throws {
        count += 1
        print("[SubagentRunner] Web researcher model round got no answer within \(Int(expiry.seconds)) s (\(count)/\(WebRoundDeadline.maxTimeoutsPerRun)); request cancelled\(count < WebRoundDeadline.maxTimeoutsPerRun ? ", retrying the round once" : "")")
        if count >= WebRoundDeadline.maxTimeoutsPerRun {
            throw WebModelRoundTimeoutError(seconds: expiry.seconds, timeouts: count)
        }
    }
}
