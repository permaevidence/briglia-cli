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

/// The writer side of every process that is NOT a running owner: the
/// standalone menu, `setup-api`, `briglia setup`, `briglia subscription`
/// (plan B.6). It forwards a prepared change to the running daemon, or —
/// when none runs — takes the instance lease for the commit only.
enum SettingsClient {
    /// Short commits in progress in this process (the upgrade exit waits).
    nonisolated(unsafe) static var shortCommitsInProgress = 0
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
    nonisolated(unsafe) static var inProcessOwner: (@MainActor (PreparedChange) async -> SettingsCommitResult)?

    @MainActor
    static func commit(_ change: PreparedChange) async -> SettingsCommitResult {
        // A commit never runs inside a preparation overlay (a wizard step
        // that commits a nested sign-in first): it reads and writes the store.
        if SettingsCapture.current != nil {
            return await SettingsCapture.$current.withValue(nil) { await commit(change) }
        }
        if let owner = inProcessOwner { return await owner(change) }
        // A process already holding the lease (the menu's Telegram pairing
        // step, quick setup) is the owner for this moment.
        if InstanceLease.isHeldInThisProcess {
            return await commitLocally(change)
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
            return await commitLocally(change)
        case .failure:
            // Release the replacement lock BEFORE waiting on the owner.
            replacement?.release()
            return await forward(change)
        }
    }

    /// Local commit under a held lease (same code: admission, epoch,
    /// preconditions, classification; no turn, so D applies now).
    @MainActor
    static func commitLocally(_ change: PreparedChange) async -> SettingsCommitResult {
        shortCommitsInProgress += 1
        defer { shortCommitsInProgress -= 1 }
        do { try SettingsRecovery.run() } catch {
            return .refused("The waiting settings changes can't be read (\(error)).")
        }
        let installed = KeychainHelper.writeObserver == nil
        if installed { SettingsSupersede.install() }
        defer { if installed { SettingsSupersede.uninstall() } }
        let host = OfflineSettingsHost()
        let writer = SettingsWriter(host: host)
        let result = await writer.commit(change)
        withExtendedLifetime(host) {}
        return result
    }

    /// Forward to the live owner; retried up to 20 s while a daemon starts
    /// (its lease precedes its socket). Never falls back to a local write.
    static func forward(_ change: PreparedChange) async -> SettingsCommitResult {
        guard let data = try? change.encoded(), let object = try? JSONSerialization.jsonObject(with: data) else {
            return .refused("settings change could not be encoded")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + (socketRetrySecondsForTesting ?? 20)
        while true {
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
                                 checkpoint: () throws -> Void = {},
                                 commit: (PreparedChange) async -> SettingsCommitResult = { await SettingsClient.commit($0) },
                                 _ body: () async -> [String: Any]) async -> [String: Any] {
        let (change, prepared) = await SettingsCapture.prepare(origin: origin, label: label, acceptPending: acceptPending, body)
        guard let change else { return prepared }
        if change.isEmpty { return prepared }
        do { try checkpoint() } catch {
            var r = SetupAPICore.errorResponse(code: "superseded", message: (error as? SetupAPICore.CheckpointRevoked)?.message ?? "\(error)")
            r["applied"] = [String]()
            return r
        }
        return reply(await commit(change), prepared: prepared)
    }
}
