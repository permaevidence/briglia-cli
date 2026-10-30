import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Keyless Jina page reading (KEYLESS_WEB_AND_LIVE_MENU_PLAN A.6)

/// Jina's shared per-domain block for anonymous readers (a 403 whose body
/// names `AbuseAlleviationError` / "Anonymous access to domain … blocked").
/// Only for a request actually sent WITHOUT a key. A per-page message, never
/// a health failure or success.
struct JinaKeylessDomainBlocked: LocalizedError, Equatable {
    let domain: String?
    let until: String?

    var errorDescription: String? {
        "Jina temporarily blocks keyless reading of \(domain ?? "this site")\(until.map { " (until \($0))" } ?? ""). Adding a free Jina.ai key in briglia menu may avoid this."
    }

    /// Classifies a keyless reader failure; nil when it isn't the typed block.
    /// The body may be truncated (HTTPError keeps 500 bytes): domain and time
    /// are parsed best effort.
    static func classify(_ error: Error) -> JinaKeylessDomainBlocked? {
        guard let http = error as? HTTPError, http.statusCode == 403 else { return nil }
        guard case .badStatus(_, let body, _) = http, let text = body else { return nil }
        guard text.contains("AbuseAlleviationError") || text.contains("Anonymous access to domain") else { return nil }
        var domain: String?
        var until: String?
        if let range = text.range(of: "Anonymous access to domain ") {
            let rest = text[range.upperBound...]
            let token = rest.prefix { !$0.isWhitespace && $0 != "\"" && $0 != "," }
            if !token.isEmpty, token.contains(".") { domain = String(token) }
            if let u = rest.range(of: "blocked until ") {
                let after = rest[u.upperBound...]
                let end = after.range(of: " due")?.lowerBound ?? after.firstIndex(of: "\"") ?? after.endIndex
                let value = after[..<end].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, value.count <= 64 { until = value }
            }
        }
        return JinaKeylessDomainBlocked(domain: domain, until: until)
    }
}

/// Free page reading at its own rate cap: the slot could not be had in time.
struct JinaKeylessRateLimited: LocalizedError {
    var errorDescription: String? { "Free page reading is at its rate limit; try again shortly (or add a Jina.ai key in briglia menu)." }
}

/// Keyless pacing: a rolling 60-second window, at most 18 HTTP ATTEMPTS per
/// process (retries are charged too). Each attempt reserves the earliest
/// slot that keeps the window under the cap; a reservation further away than
/// `maxWait` fails at once. Waits are cancellable. Several assistant
/// processes on one IP can still exceed Jina's 20/min — the existing 429
/// handling covers that; no guarantee is claimed.
actor JinaKeylessPacer {
    static let shared = JinaKeylessPacer()

    var window: TimeInterval = 60
    var maxAttempts = 18
    var maxWait: TimeInterval = 45
    private var clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Start times of attempts in (or reserved for) the current window, sorted.
    private var slots: [TimeInterval] = []
    private(set) var charged = 0

    func configureForTesting(window: TimeInterval = 60, maxAttempts: Int = 18, maxWait: TimeInterval = 45,
                             clock: (@Sendable () -> TimeInterval)? = nil) {
        self.window = window; self.maxAttempts = maxAttempts; self.maxWait = maxWait
        self.clock = clock ?? { ProcessInfo.processInfo.systemUptime }
        slots = []; charged = 0
    }

    /// Reserve one attempt slot and wait for it.
    func acquire() async throws {
        let now = clock()
        slots.removeAll { $0 <= now - window }
        var start = now
        if slots.count >= maxAttempts {
            start = max(now, slots[slots.count - maxAttempts] + window)
        }
        guard start - now <= maxWait else { throw JinaKeylessRateLimited() }
        slots.append(start)
        slots.sort()
        charged += 1
        let wait = start - now
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}
