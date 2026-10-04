import Foundation

/// A per-run request counter enforced where requests actually leave the
/// process (USER_CONTEXT_EDIT_OPS_PLAN §7.5). Only user-profile maintenance
/// creates one; every other caller leaves the context's budgets `nil` and
/// keeps its exact v0.2.48 behaviour (retries, refreshes, re-asks).
final class SendBudget: @unchecked Sendable {
    let limit: Int
    private let lock = NSLock()
    private var used = 0
    private let makeError: @Sendable (Int) -> Error

    init(limit: Int, exhausted: @escaping @Sendable (Int) -> Error = { SendBudgetExhausted(limit: $0) }) {
        self.limit = limit
        self.makeError = exhausted
    }

    /// Consume one unit immediately before a request goes out; throws when
    /// none is left (nothing is sent).
    func consume() throws {
        lock.lock()
        defer { lock.unlock() }
        guard used < limit else { throw makeError(limit) }
        used += 1
    }

    /// Throws the exhaustion error when nothing is left, without consuming.
    func requireCapacity() throws {
        lock.lock()
        defer { lock.unlock() }
        guard used < limit else { throw makeError(limit) }
    }

    var consumed: Int { lock.lock(); defer { lock.unlock() }; return used }
    var remaining: Int { lock.lock(); defer { lock.unlock() }; return limit - used }
}

struct SendBudgetExhausted: Error, LocalizedError {
    let limit: Int
    var errorDescription: String? { "request budget exhausted (\(limit) model requests per maintenance run)" }
}

/// Not a login problem: nothing is written to the login store and the
/// login stays valid; the maintenance run ends as a transient failure.
struct AuthBudgetExhausted: Error, LocalizedError {
    let limit: Int
    var errorDescription: String? { "login-refresh budget exhausted (\(limit) per maintenance run)" }
}

/// Whether the Responses adapter may retry transient failures internally.
/// `.none` is for budgeted callers whose own outer loop owns retries.
enum AdapterRetryPolicy {
    case standard
    case none
}
