import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// One request/answer exchange with the running owner over the app socket
/// (peer-UID verified, JSON lines).
enum OwnerSocket {
    enum Failure: Error, CustomStringConvertible, Equatable {
        /// No socket, connection refused, wrong peer: nothing was sent.
        case unavailable
        /// The request may have been delivered; the answer was lost.
        case lost
        /// The owner refused the request type (an older daemon).
        case nack(String)

        var description: String {
            switch self {
            case .unavailable: return "the running Briglia's socket is unavailable"
            case .lost: return "the connection to the running Briglia was lost after the request was sent"
            case .nack(let m): return m
            }
        }
    }

    /// Selftest seam: answers requests in place of a socket.
    nonisolated(unsafe) static var transportForTesting: (([String: Any]) throws -> [String: Any])?

    static func request(_ object: [String: Any], timeout: Double = 45) throws -> [String: Any] {
        if let transport = transportForTesting { return try transport(object) }
        var addr = sockaddr_un()
        let path = AppChatSocketServer.socketURL.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.unavailable }
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in path.withUnsafeBytes { dst.copyBytes(from: $0) } }
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0, AppChatSocketServer.peerUID(of: fd) == getuid() else { throw Failure.unavailable }
        let ref = UUID().uuidString
        var body = object
        body["ref"] = ref
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw Failure.unavailable }
        do { try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data + Data([10])) } catch { throw Failure.lost }
        var buffer = Data(); var chunk = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw Failure.lost }
            buffer.append(contentsOf: chunk.prefix(n))
            guard buffer.count < 8 * 1024 * 1024 else { throw Failure.lost }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any], reply["ref"] as? String == ref else { continue }
                if reply["type"] as? String == "nack" { throw Failure.nack(reply["error"] as? String ?? "refused") }
                return reply
            }
        }
        throw Failure.lost
    }

    /// The owner answers `ping` (any daemon).
    static func reachable() -> Bool {
        (try? request(["type": "ping"], timeout: 3))?["type"] as? String == "pong"
    }
}

/// The offline owner: a process that holds the instance lease for the
/// commit only (plan B.6). No turn can run, so a route change applies now.
@MainActor
final class OfflineSettingsHost: SettingsOwnerHost {
    var isDaemon: Bool { false }
    func beginRouteBarrier() async -> Bool { true }
    func endRouteBarrier() {}
    func admissionRefusal() -> String? { nil }
    func reconcile(after change: PreparedChange, routeChanged: Bool) async {}
    var toolSwitches: SettingsToolSwitches { SettingsToolSwitches.current() }
}

/// The single offline owner of this process: one host, one writer, one
/// commit token for every local commit (R1-1).
@MainActor
enum OfflineOwner {
    static let host = OfflineSettingsHost()
    static let writer = SettingsWriter(host: host)
}

/// FIFO mutual exclusion for local commits of this process (main actor).
@MainActor
enum OfflineCommitQueue {
    private static var busy = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []
    static var isBusyForTesting: Bool { busy }
    static var waitingForTesting: Int { waiters.count }

    static func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    static func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// The writer side of every process that is NOT a running owner: the
/// standalone menu, `setup-api`, `briglia setup`, `briglia subscription`
/// (plan B.6). It forwards a prepared change to the running daemon, or —
/// when none runs — takes the instance lease for the commit only.
enum SettingsClient {
    /// Short commits in progress in this process (the upgrade exit waits).
    /// Commits are serialized (at most one), and a lease release requested
    /// while one runs is deferred until it ends (`releaseAfterLocalCommits`).
    static var shortCommitsInProgress: Int { localLock.lock(); defer { localLock.unlock() }; return localInFlight }
    private static let localLock = NSLock()
    nonisolated(unsafe) private static var localInFlight = 0
    nonisolated(unsafe) private static var deferredReleases: [() -> Void] = []

    /// Runs `release` (an instance lease this process holds: the menu's
    /// pairing lease, a legacy lease) now, or — while a local commit that
    /// borrowed it is running — right after that commit ends, so a commit
    /// never continues without the lease (Codex live-menu review R1-1).
    static func releaseAfterLocalCommits(_ release: @escaping () -> Void) {
        localLock.lock()
        if localInFlight > 0 { deferredReleases.append(release); localLock.unlock(); return }
        localLock.unlock()
        release()
    }

    private static func beginLocal() { localLock.lock(); localInFlight += 1; localLock.unlock() }
    private static func endLocal() {
        localLock.lock()
        localInFlight -= 1
        let run = localInFlight == 0 ? deferredReleases : []
        if localInFlight == 0 { deferredReleases = [] }
        localLock.unlock()
        for release in run { release() }
    }
    nonisolated(unsafe) private static var lastShortLease: TimeInterval = 0
    /// Selftest seam: the lease acquisition wait.
    nonisolated(unsafe) static var leaseWaitSecondsForTesting: Double?
    /// Selftest seam: how long the owner socket is retried while a daemon starts.
    nonisolated(unsafe) static var socketRetrySecondsForTesting: Double?

    static let unsupportedMessage = "The running Briglia is older than this command. Update it with /upgrade, or stop it and retry."

    /// `menuHandover`: the menu falls back to the old daemon's live hub
    /// instead of refusing (`owner_protocol_unsupported` is returned with
    /// code "owner_protocol_unsupported" so the menu can hand over).
    /// The running owner of THIS process (the daemon / terminal chat): its
    /// writer is used directly, never a second, offline writer.
    nonisolated(unsafe) static var inProcessOwner: (@MainActor (PreparedChange, (@Sendable () throws -> Void)?) async -> SettingsCommitResult)?
    /// The running owner's writer itself (SIWC save, cancel and sign-out are
    /// writer entry points that are never a `PreparedChange`).
    nonisolated(unsafe) static var inProcessWriter: SettingsWriter?

    /// `stillValid` reaches the decision point of an in-process commit (the
    /// running owner of this process, or a short offline commit); a
    /// forwarded commit checks it right before sending.
    @MainActor
    static func commit(_ change: PreparedChange, stillValid: (@Sendable () throws -> Void)? = nil) async -> SettingsCommitResult {
        // A commit never runs inside a preparation overlay (a wizard step
        // that commits a nested sign-in first): it reads and writes the store.
        if SettingsCapture.current != nil {
            return await SettingsCapture.$current.withValue(nil) { await commit(change, stillValid: stillValid) }
        }
        if let owner = inProcessOwner { return await owner(change, stillValid) }
        // One local commit at a time in this process (R1-1): the lease
        // decision, recovery, observer, commit and the short lease's release
        // run as one unit; a second save waits its turn and then decides
        // again (forward or local) on what is true at that moment.
        await OfflineCommitQueue.acquire()
        var queueHeld = true
        defer { if queueHeld { OfflineCommitQueue.release() } }
        // A process already holding the lease (the menu's Telegram pairing
        // step, quick setup) is the owner for this moment; its release waits
        // for this commit (`releaseAfterLocalCommits`).
        if InstanceLease.isHeldInThisProcess {
            return await commitLocally(change, stillValid: stillValid)
        }
        // Offline prefix (B.4b): replacement lock shared → short lease.
        let replacement: ProfileFileLock?
        switch MemoryReplacementLock.shared(waitSeconds: MemoryReplacementLock.standaloneWaitSeconds) {
        case .admitted(let lock): replacement = lock
        case .busy: return .refused(MemoryReplacementLock.busyMessage)
        case .failed(let why): return .refused(why)
        }
        // Starvation guard: at most one short lease per 2 s per process.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastShortLease < 2 { try? await Task.sleep(nanoseconds: UInt64((2 - (now - lastShortLease)) * 1_000_000_000)) }
        lastShortLease = ProcessInfo.processInfo.systemUptime
        switch await InstanceLease.acquire(label: "settings-commit", waitSeconds: leaseWaitSecondsForTesting ?? 2) {
        case .success(let lease):
            defer { lease.release(); replacement?.release() }
            return await commitLocally(change, stillValid: stillValid)
        case .failure:
            // Release the replacement lock and the queue BEFORE waiting on
            // the owner.
            replacement?.release()
            queueHeld = false
            OfflineCommitQueue.release()
            return await forward(change, stillValid: stillValid)
        }
    }

    /// Local commit under a held lease (same code: admission, epoch,
    /// preconditions, classification; no turn, so D applies now).
    @MainActor
    static func commitLocally(_ change: PreparedChange, stillValid: (@Sendable () throws -> Void)? = nil) async -> SettingsCommitResult {
        beginLocal()
        defer { endLocal() }
        do { try SettingsRecovery.run() } catch {
            return .refused("The waiting settings changes can't be read (\(error)).")
        }
        let installed = KeychainHelper.writeObserver == nil
        if installed { SettingsSupersede.install() }
        defer { if installed { SettingsSupersede.uninstall() } }
        // One writer (one commit token) per process for every local commit.
        return await OfflineOwner.writer.commit(change, stillValid: stillValid)
    }

    /// Forward to the live owner; retried up to 20 s while a daemon starts
    /// (its lease precedes its socket). Never falls back to a local write.
    /// `stillValid` is checked before EVERY attempt known not to have sent
    /// anything (R1-8). Submission = the request was written to a connected
    /// owner socket; after that a local revocation can no longer cancel it,
    /// and the answer (or a single lookup) is the outcome.
    static func forward(_ change: PreparedChange, stillValid: (@Sendable () throws -> Void)? = nil) async -> SettingsCommitResult {
        guard let data = try? change.encoded(), let object = try? JSONSerialization.jsonObject(with: data) else {
            return .refused("settings change could not be encoded")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + (socketRetrySecondsForTesting ?? 20)
        while true {
            do { try stillValid?() } catch { return .refused("this action was superseded; nothing was saved") }
            do {
                let reply = try await Task.detached {
                    try OwnerSocket.request(["type": "settings_commit", "change": object], timeout: 300)
                }.value
                return SettingsCommitResult(json: reply) ?? SettingsCommitResult(state: .error, message: "malformed owner answer")
            } catch OwnerSocket.Failure.unavailable {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    return .refused("Briglia is starting or stopping; nothing was saved — try again in a moment.")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            } catch OwnerSocket.Failure.nack(let why) {
                if why.contains("unknown request type") {
                    var r = SettingsCommitResult.refused(unsupportedMessage)
                    r.code = "owner_protocol_unsupported"
                    return r
                }
                return .refused(why)
            } catch {
                // Lost after sending: never resubmit; one lookup by id.
                if let looked = try? await Task.detached(operation: {
                    try OwnerSocket.request(["type": "settings_result", "request_id": change.id], timeout: 10)
                }).value, let result = SettingsCommitResult(json: looked) {
                    return result
                }
                return SettingsCommitResult(state: .uncertain,
                    message: "The connection to Briglia was lost after the change was sent; the result is unknown (request \(change.id.prefix(8))). Check the setting before saving it again.")
            }
        }
    }

    // MARK: setup-api reply shape

    /// The commit result in setup-api's reply shape.
    static func reply(_ result: SettingsCommitResult, prepared: [String: Any]) -> [String: Any] {
        switch result.state {
        case .applied:
            var r = result.reply ?? prepared
            r["daemon_running"] = SetupAPICore.daemonRunning()
            r["restart_needed"] = false
            return r
        case .pending:
            var r = prepared
            r["state"] = "pending"
            r["ticket"] = result.ticket ?? ""
            if let m = result.message { r["message"] = m }
            r["restart_needed"] = false
            return r
        case .busy:
            var r = SetupAPICore.errorResponse(code: "agent_busy", message: result.message ?? "Briglia is busy.")
            r["applied"] = [String]()
            return r
        default:
            var r = SetupAPICore.errorResponse(code: result.code ?? (result.state == .refused ? "refused" : result.state.rawValue),
                                               message: result.message ?? "not saved")
            r["applied"] = [String]()
            return r
        }
    }

    /// Prepare `body` (setup-api request code) and commit it (forward or
    /// short lease). A failed preparation commits nothing.
    @MainActor
    static func prepareAndCommit(origin: String, label: String, acceptPending: Bool,
                                 checkpoint: @escaping () throws -> Void = {},
                                 commit: @MainActor (PreparedChange, (@Sendable () throws -> Void)?) async -> SettingsCommitResult = { change, _ in await SettingsClient.commit(change) },
                                 _ body: () async -> [String: Any]) async -> [String: Any] {
        let (change, prepared) = await SettingsCapture.prepare(origin: origin, label: label, acceptPending: acceptPending, body)
        guard let change else { return prepared }
        if change.isNoop { return prepared }
        do { try checkpoint() } catch {
            var r = SetupAPICore.errorResponse(code: "superseded", message: (error as? SetupAPICore.CheckpointRevoked)?.message ?? "\(error)")
            r["applied"] = [String]()
            return r
        }
        let sendableCheckpoint = UncheckedCheckpoint(checkpoint)
        return reply(await commit(change, { try sendableCheckpoint.call() }), prepared: prepared)
    }
}

/// Carries a (main-actor) checkpoint closure into the writer's decision
/// point, which runs synchronously on the same actor.
final class UncheckedCheckpoint: @unchecked Sendable {
    private let body: () throws -> Void
    init(_ body: @escaping () throws -> Void) { self.body = body }
    func call() throws { try body() }
}
