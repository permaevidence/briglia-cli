import Foundation

/// Process-local sign-out machinery (§3.7, §3.9 R2): a per-registration
/// revocation epoch, a fence that refuses every further send for a
/// registration from this process, and a registry of in-flight SIWC
/// requests that a sign-out cancels. Cross-process the durable tombstone
/// generation is the guarantee (§3.7 item 7).
final class SIWCFence: @unchecked Sendable {
    static let shared = SIWCFence()

    private let lock = NSLock()
    private var epochs: [String: Int] = [:]
    private var fenced: Set<String> = []
    private var inflight: [String: [UUID: () -> Void]] = [:]

    /// Key = store directory + client (one registration in one store).
    static func key(store: URL, clientId: String) -> String { store.standardizedFileURL.path + "\u{0}" + clientId }

    func epoch(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return epochs[key, default: 0] }

    func isFenced(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return fenced.contains(key) }

    /// Step 2 of the interrupting logout: one step bumps the epoch and fences.
    @discardableResult
    func fenceAndBump(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        fenced.insert(key)
        epochs[key, default: 0] += 1
        return epochs[key]!
    }

    /// Cleared only by a successful logout or an admitted activation of a
    /// NEW generation (§3.9 step 6).
    func unfence(_ key: String) { lock.lock(); fenced.remove(key); lock.unlock() }

    /// Register a running request; returns a token to unregister. A request
    /// started while fenced is refused here too.
    func register(_ key: String, epoch: Int, cancel: @escaping () -> Void) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard !fenced.contains(key), epochs[key, default: 0] == epoch else {
            throw SIWCError(.signedOut, SIWCError.signedOutMessage)
        }
        let id = UUID()
        inflight[key, default: [:]][id] = cancel
        return id
    }

    func unregister(_ key: String, _ id: UUID) {
        lock.lock(); inflight[key]?[id] = nil; lock.unlock()
    }

    /// Cancel every registered request of `key` (after the fence).
    @discardableResult
    func cancelAll(_ key: String) -> Int {
        lock.lock(); let cancels = Array((inflight[key] ?? [:]).values); lock.unlock()
        for cancel in cancels { cancel() }
        return cancels.count
    }

    func inflightCount(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return inflight[key]?.count ?? 0 }

    /// The pre-send check (§3.7 item 2): fenced or a changed epoch → signed out.
    func check(_ key: String, capturedEpoch: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard !fenced.contains(key), epochs[key, default: 0] == capturedEpoch else {
            throw SIWCError(.signedOut, SIWCError.signedOutMessage)
        }
    }

    /// Run `operation` as a registered in-flight request of `key` (Codex
    /// round 1 R3/R4). Admission happens BEFORE the operation can start:
    /// a fenced registration never starts it. A sign-out that lands between
    /// admission and the task's installation is not missed: the handle
    /// cancels the task when it is installed, and the operation itself
    /// re-checks the handle before it does anything. A result that arrives
    /// after a sign-out is never delivered (`signedOut`).
    func runRegistered<T>(_ key: String, epoch: Int, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let handle = SendHandle()
        let token = try register(key, epoch: epoch) { handle.cancel() }
        defer { unregister(key, token) }
        let task = Task<T, Error> {
            guard !handle.isCancelled else { throw CancellationError() }
            return try await operation()
        }
        handle.install(task)
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try check(key, capturedEpoch: epoch)
            return value
        } catch {
            if !Task.isCancelled, (try? check(key, capturedEpoch: epoch)) == nil {
                throw SIWCError(.signedOut, SIWCError.signedOutMessage)
            }
            throw error
        }
    }

    final class SendHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var cancelTask: (() -> Void)?
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() {
            lock.lock(); cancelled = true; let c = cancelTask; lock.unlock()
            c?()
        }
        func install<T>(_ task: Task<T, Error>) {
            lock.lock()
            cancelTask = { task.cancel() }
            let already = cancelled
            lock.unlock()
            if already { task.cancel() }
        }
    }

    // MARK: Jobs (Codex stage-C round 1: §3.7/§3.9 R2 "cancel and drain
    // every job whose captured source names that registration")

    /// Operations that captured an SIWC source and may be between model
    /// requests (a main turn in tool work, a subagent run): their task is
    /// cancelled by a sign-out of that registration and the sign-out waits
    /// (bounded) for them to end. The task reference is only used while the
    /// job is registered, and the job unregisters from inside its own task
    /// before that task can finish, under this lock.
    private var jobs: [String: [UUID: UnsafeCurrentTask]] = [:]

    struct JobToken { let key: String; let id: UUID }

    /// Register the CURRENT task as a job of `source` (nil source = no job).
    /// A fenced registration refuses at once (signed out).
    func registerCurrentTask(_ source: SIWCCredentialSource?) throws -> JobToken? {
        guard let source else { return nil }
        return try withUnsafeCurrentTask { task -> JobToken? in
            guard let task else { return nil }
            lock.lock(); defer { lock.unlock() }
            guard !fenced.contains(source.fenceKey), epochs[source.fenceKey, default: 0] == source.epoch else {
                throw SIWCError(.signedOut, SIWCError.signedOutMessage)
            }
            let id = UUID()
            jobs[source.fenceKey, default: [:]][id] = task
            return JobToken(key: source.fenceKey, id: id)
        }
    }

    func unregisterJob(_ token: JobToken?) {
        guard let token else { return }
        lock.lock(); jobs[token.key]?[token.id] = nil; lock.unlock()
    }

    /// Cancel every registered job of `key` (after the fence).
    @discardableResult
    func cancelJobs(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let tasks = Array((jobs[key] ?? [:]).values)
        for task in tasks { task.cancel() }
        return tasks.count
    }

    func jobCount(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return jobs[key]?.count ?? 0 }

    /// Selftests only.
    func resetForTests() { lock.lock(); epochs = [:]; fenced = []; inflight = [:]; jobs = [:]; lock.unlock() }
}
