import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The machine's one `ext_agent_host_id` (§3.1, §3.8 "Host lifetime across
/// stores", round-1 correction R5, D24). It lives in default's config root
/// beside the shared store; pending attempts hold short **reservations** in
/// `machine/chatgpt-host-reservations.json`, all under `chatgpt-share.lock`.
///
/// Rules: created only when no registration and no live reservation exists
/// anywhere on the machine; missing/corrupt/disagreeing host state while a
/// user exists is a refusal, never a new ID; removed only with no
/// registration left in any store and no live reservation.
enum SIWCHost {
    struct HostFile: Codable, Equatable {
        var version = 1
        var extAgentHostId: String
    }

    struct Reservation: Codable, Equatable {
        var attemptId: String
        var profile: String
        var storePath: String
        var hostFingerprint: String
        /// The owning process's member-lease lock path (never the short
        /// settings instance lease). nil when the process holds none: the
        /// reservation then lives until expiry.
        var ownerLease: String?
        var expiresAt: Int
    }

    struct ReservationsFile: Codable, Equatable {
        var version = 1
        var reservations: [Reservation] = []
    }

    /// Where everything lives. `.live` = the machine paths; selftests pass
    /// temporary directories.
    struct Paths {
        var machineConfigRoot: URL
        var machineDir: URL
        /// Every store directory on the machine that may hold registrations:
        /// the machine store and every extra's own config root. nil = the
        /// census is uncertain (counts as "a user exists", fail safe).
        var storeDirectories: () -> [URL]?
        var shareLock: URL

        static var live: Paths {
            Paths(machineConfigRoot: MachinePaths.defaultConfigRoot(), machineDir: MachinePaths.machineDir(),
                  storeDirectories: { liveStoreDirectories() },
                  shareLock: ChatGPTShare.lockURL)
        }
        var hostFile: URL { machineConfigRoot.appendingPathComponent(SIWCEndpoint.hostFileName) }

        /// The conservative census (Codex round 1 R8): every directory under
        /// the extras root, whether or not its profile metadata is readable
        /// (the profile picker's `listExtras` filter is not used here). An
        /// absent extras root is no extras; any other enumeration error is
        /// uncertain.
        static func liveStoreDirectories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL]? {
            var out = [MachinePaths.defaultConfigRoot()]
            let root = AssistantProfile.configBase(environment).appendingPathComponent(AssistantProfile.extrasDirName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return out }
            guard isDirectory.boolValue, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = root.appendingPathComponent(name, isDirectory: true)
                guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { return nil }
                if type == .typeDirectory { out.append(url) }
            }
            return out
        }
        var reservationsFile: URL { machineDir.appendingPathComponent(SIWCEndpoint.reservationsFileName) }
    }

    static let unreadableMessage = "Briglia can't read this computer's ChatGPT app ID; nothing was changed."
    static let expiredMessage = "This sign-in expired or the computer's ChatGPT app ID changed; sign in again."

    static func fingerprint(_ hostId: String) -> String {
        SIWCEndpoint.hex(SHA256.hash(data: Data("chatgpt-siwc-host:\(hostId)".utf8)))
    }

    static func wellFormed(_ hostId: String) -> Bool {
        guard hostId.hasPrefix("urn:uuid:"), let uuid = UUID(uuidString: String(hostId.dropFirst(9))) else { return false }
        return hostId == "urn:uuid:" + uuid.uuidString.lowercased()
    }

    /// The share lock, bounded (ChatGPTShare's wait and Busy error).
    static func withShareLock<T>(_ paths: Paths, _ body: () throws -> T) throws -> T {
        try PrivateStorage.ensureDirectory(paths.machineDir)
        let lock = try ChatGPTShare.takeLock(url: paths.shareLock)
        defer { lock?.release() }
        return try body()
    }

    static func withShareLockAsync<T>(_ paths: Paths, _ body: () async throws -> T) async throws -> T {
        try PrivateStorage.ensureDirectory(paths.machineDir)
        let lock = try ChatGPTShare.takeLock(url: paths.shareLock)
        defer { lock?.release() }
        return try await body()
    }

    // MARK: Reads (caller holds the share lock)

    enum HostRead: Equatable { case absent, present(String), unreadable }

    static func readHost(_ paths: Paths) -> HostRead {
        do {
            guard let data = try SIWCStore.readOwnerOnly(paths.hostFile, cap: 4096) else { return .absent }
            guard let file = try? JSONDecoder().decode(HostFile.self, from: data), file.version == 1,
                  wellFormed(file.extAgentHostId) else { return .unreadable }
            return .present(file.extAgentHostId)
        } catch { return .unreadable }
    }

    static func readReservations(_ paths: Paths) throws -> ReservationsFile {
        guard let data = try SIWCStore.readOwnerOnly(paths.reservationsFile, cap: 131072) else { return ReservationsFile() }
        guard let file = try? JSONDecoder().decode(ReservationsFile.self, from: data), file.version == 1 else {
            throw SIWCError(.local, unreadableMessage)
        }
        return file
    }

    static func writeReservations(_ paths: Paths, _ file: ReservationsFile) throws {
        if file.reservations.isEmpty {
            if FileManager.default.fileExists(atPath: paths.reservationsFile.path) {
                try FileManager.default.removeItem(at: paths.reservationsFile)
                try PrivateStorage.fsyncDirectory(paths.machineDir.path)
            }
            return
        }
        _ = try PrivateStorage.writeAtomically(try SIWCStore.encode(file), to: paths.reservationsFile)
    }

    /// Live = unexpired and its owner lease not provably gone. An owner that
    /// cannot be probed keeps its reservation until expiry.
    static func isLive(_ reservation: Reservation, now: Int) -> Bool {
        guard reservation.expiresAt > now else { return false }
        if let lease = reservation.ownerLease, ProfileFileLock.probe(URL(fileURLWithPath: lease)) == .dead { return false }
        return true
    }

    /// Host fingerprints of every registration on the machine; nil when any
    /// store's registrations cannot be read ("a user exists", fail safe).
    static func registrationHostFingerprints(_ paths: Paths) -> [String]? {
        var out: [String] = []
        guard let directories = paths.storeDirectories() else { return nil }
        for directory in directories {
            do {
                guard let file = try SIWCStore(directory: directory).readRegistrations() else { continue }
                out += file.registrations.map(\.hostFingerprint)
            } catch { return nil }
        }
        return out
    }

    // MARK: Reservation (before the authorize link)

    /// Read or create the host ID and take a reservation for one attempt, in
    /// one short critical section under `chatgpt-share.lock`. Expired or
    /// dead-owner reservations are removed on the way.
    static func reserve(_ paths: Paths = .live, attemptId: String, profile: String, storePath: String,
                        ownerLease: String?, now: Int, lifetime: Int = Int(SIWCEndpoint.attemptLifetime)) throws -> (hostId: String, fingerprint: String) {
        try withShareLock(paths) {
            var reservations = try readReservations(paths)
            let before = reservations.reservations.count
            reservations.reservations.removeAll { !isLive($0, now: now) }
            let users = registrationHostFingerprints(paths)
            let hostId: String
            switch readHost(paths) {
            case .unreadable:
                throw SIWCError(.local, unreadableMessage)
            case .present(let id):
                // Every registration on the machine must carry this host.
                guard let users, users.allSatisfy({ $0 == fingerprint(id) }) else {
                    throw SIWCError(.local, unreadableMessage)
                }
                hostId = id
            case .absent:
                guard let users, users.isEmpty, reservations.reservations.isEmpty else {
                    throw SIWCError(.local, unreadableMessage)
                }
                let id = "urn:uuid:" + UUID().uuidString.lowercased()
                try PrivateStorage.ensureDirectory(paths.machineConfigRoot)
                _ = try PrivateStorage.writeAtomically(try SIWCStore.encode(HostFile(extAgentHostId: id)), to: paths.hostFile)
                hostId = id
            }
            reservations.reservations.removeAll { $0.attemptId == attemptId }
            reservations.reservations.append(Reservation(attemptId: attemptId, profile: profile, storePath: storePath,
                hostFingerprint: fingerprint(hostId), ownerLease: ownerLease, expiresAt: now + lifetime))
            _ = before
            try writeReservations(paths, reservations)
            return (hostId, fingerprint(hostId))
        }
    }

    /// Publication check (§3.8): the caller holds `chatgpt-share.lock`. The
    /// reservation must exist, be unexpired and name `hostFingerprint`, and
    /// the host file must still be that host.
    static func validateReservationLocked(_ paths: Paths, attemptId: String, hostFingerprint: String, now: Int) throws {
        let reservations = try readReservations(paths)
        guard let reservation = reservations.reservations.first(where: { $0.attemptId == attemptId }),
              reservation.expiresAt > now, reservation.hostFingerprint == hostFingerprint,
              case .present(let id) = readHost(paths), fingerprint(id) == hostFingerprint else {
            throw SIWCError(.local, expiredMessage)
        }
    }

    /// Remove one attempt's reservation (caller holds the share lock).
    static func releaseLocked(_ paths: Paths, attemptId: String) throws {
        var reservations = try readReservations(paths)
        let count = reservations.reservations.count
        reservations.reservations.removeAll { $0.attemptId == attemptId }
        if reservations.reservations.count != count { try writeReservations(paths, reservations) }
    }

    static func release(_ paths: Paths = .live, attemptId: String) throws {
        try withShareLock(paths) { try releaseLocked(paths, attemptId: attemptId) }
    }

    // MARK: Wipe (D24)

    enum WipeOutcome: Equatable { case removed, keptInUse, absent, unreadable }

    /// Remove the host file (and the reservation file) only when the machine
    /// has no host user left: no registration in any store and no live
    /// reservation. An unreadable store or reservation file counts as a user.
    static func removeIfUnused(_ paths: Paths = .live, now: Int) throws -> WipeOutcome {
        try withShareLock(paths) {
            let reservations: ReservationsFile
            do { reservations = try readReservations(paths) } catch { return .unreadable }
            if reservations.reservations.contains(where: { isLive($0, now: now) }) { return .keptInUse }
            guard let users = registrationHostFingerprints(paths) else { return .unreadable }
            guard users.isEmpty else { return .keptInUse }
            let fm = FileManager.default
            guard fm.fileExists(atPath: paths.hostFile.path) || fm.fileExists(atPath: paths.reservationsFile.path) else { return .absent }
            if fm.fileExists(atPath: paths.hostFile.path) {
                try fm.removeItem(at: paths.hostFile)
                try PrivateStorage.fsyncDirectory(paths.machineConfigRoot.path)
            }
            try writeReservations(paths, ReservationsFile())
            return .removed
        }
    }

    static let keptMessage = "This computer's ChatGPT app ID was kept because another assistant still uses it."
}
