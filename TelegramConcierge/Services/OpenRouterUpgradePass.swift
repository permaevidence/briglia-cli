import Foundation

/// D10 (owner decision 2026-10-18, option B): at upgrade, the OpenRouter
/// model in use gets its preset host when it is a preset with one. Migration
/// only records an `upgrade_preset` marker; this pass applies it later
/// (plan §13.5/§13.6/§13.7):
/// - runs DETACHED: `start()` returns immediately, startup never awaits it;
/// - the host list is read outside every lock;
/// - the commit is a synchronous main-actor step: an idle check (no turn
///   running) and a NON-blocking store transaction with no suspension in
///   between, so a turn can't start halfway and nothing waits on a lock;
/// - temporary trouble (no key, failed listing, uncertain tier, busy store,
///   a running turn, a write failure) keeps the marker and retries
///   (1 → 10 min, and again at every startup); only the outcomes in
///   `OpenRouterProviderPin.commitUpgradeAttempt` end the operation.
@MainActor
final class OpenRouterUpgradePass {
    typealias Fetch = (String, String) async throws -> [OpenRouterProviderPin.Endpoint]

    private let isIdle: () -> Bool
    private let onCommitted: (OpenRouterProviderPin.UpgradeAttempt) -> Void
    private let fetch: Fetch
    private var task: Task<Void, Never>?
    private(set) var attempts = 0
    /// Seconds before the first retry and the cap (tests shorten them).
    var firstRetryDelay: Double = 60
    var maxRetryDelay: Double = 600

    init(isIdle: @escaping () -> Bool,
         onCommitted: @escaping (OpenRouterProviderPin.UpgradeAttempt) -> Void,
         fetch: @escaping Fetch = { try await OpenRouterProviderPin.fetchEndpoints(model: $0, apiKey: $1) }) {
        self.isIdle = isIdle
        self.onCommitted = onCommitted
        self.fetch = fetch
    }

    var isRunning: Bool { task != nil }

    /// One in-flight loop per process; returns immediately.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var delay = self?.firstRetryDelay ?? 60
            while !Task.isCancelled {
                guard let self else { return }
                let result = await self.attemptOnce()
                switch result {
                case .nothing, .pinned, .notServed:
                    self.task = nil
                    return
                case .retry:
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay = min(delay * 2, self.maxRetryDelay)
                }
            }
        }
    }

    func cancel() { task?.cancel(); task = nil }

    /// One attempt (also the selftest entry point).
    func attemptOnce() async -> OpenRouterProviderPin.UpgradeAttempt {
        attempts += 1
        guard let store = KeychainHelper.tryLoadSnapshot() else { return .retry("store busy") }
        guard let model = OpenRouterProviderPin.upgradeCandidate(store) else {
            // A marker that isn't applicable right now (no key yet, another
            // model current, a legacy pin pending) stays; no marker = done.
            return OpenRouterPinMap.state(store).map?.upgrade != nil ? .retry("not applicable now") : .nothing
        }
        let key = OpenRouterPinMap.trimmed(store[KeychainHelper.openRouterApiKeyKey])
        guard !key.isEmpty else { return .retry("no OpenRouter key yet") }
        let expected = OpenRouterPinMap.RoutingBasis.of(store)
        let listing: OpenRouterProviderPin.HostListing
        do {
            listing = try await OpenRouterProviderPin.hostListing(model: model, apiKey: key, fetch: fetch)
        } catch {
            return .retry("cancelled")  // ends the attempt, not the operation
        }
        return commit(model: model, listing: listing, expected: expected)
    }

    /// Synchronous on the main actor: idle admission + non-blocking write.
    private func commit(model: String, listing: OpenRouterProviderPin.HostListing,
                        expected: OpenRouterPinMap.RoutingBasis) -> OpenRouterProviderPin.UpgradeAttempt {
        guard isIdle() else { return .retry("a turn is running") }
        let result: OpenRouterProviderPin.UpgradeAttempt
        do {
            result = try OpenRouterProviderPin.commitUpgradeAttempt(model: model, listing: listing, expected: expected)
        } catch {
            return .retry("write failed: \(error.localizedDescription)")
        }
        switch result {
        case .pinned, .notServed: onCommitted(result)
        case .nothing, .retry: break
        }
        return result
    }
}
