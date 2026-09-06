import Foundation

enum ResponsesOperation: String, Codable {
    case conversation, pruneSummary, subagentCompaction, archive, fileDescription, userContext, probe, webResearch
}

/// A single operation's ephemeral routing state. Value copies of an execution
/// snapshot deliberately share this owner; a new snapshot gets a new owner.
/// Never persisted, placed in model input, or reused by another turn/account.
final class ResponsesTurn: @unchecked Sendable {
    static let header = "x-codex-turn-state"
    let id = UUID()
    private let lock = NSLock()
    private var scope: ResponsesScope?
    private var token: String?
    private var closed = false

    func value(for requested: ResponsesScope) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, requested.endpoint == SubscriptionEndpoint.inference else { return nil }
        if scope == nil { scope = requested }
        guard scope == requested else { return nil }
        return token
    }

    func receive(_ value: String?, scope requested: ResponsesScope) {
        guard let value, !value.isEmpty, value.utf8.count <= 8192,
              value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed, requested.endpoint == SubscriptionEndpoint.inference else { return }
        if scope == nil { scope = requested }
        // First server value wins, as in Codex's per-turn OnceLock contract.
        guard scope == requested, token == nil else { return }
        token = value
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; token = nil
    }
}

extension ProviderExecutionContext {
    func forOperation(_ operation: ResponsesOperation) -> Self {
        var copy = self
        copy.responsesTurn = ResponsesTurn()
        copy.responsesOperation = operation
        return copy
    }
}
