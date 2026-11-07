import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Records (§3.1, §3.8, §3.9)

/// One token set as issued. Times are whole epoch seconds so the integrity
/// binding's canonical bytes never depend on floating-point formatting.
struct SIWCTokens: Codable, Equatable {
    var access: String
    var refresh: String
    var idToken: String?
    var tokenType: String
    var scopes: [String]
    var expiresAt: Int
    var earliestRefreshAt: Int?

    var planUsage: Bool { scopes.contains(SIWCEndpoint.planScope) }

    var valid: Bool {
        func token(_ t: String) -> Bool { !t.isEmpty && t.utf8.count < 32768 && t.utf8.allSatisfy { $0 > 32 && $0 < 127 } }
        return token(access) && token(refresh) && (idToken.map(token) ?? true)
            && tokenType.utf8.count < 64 && scopes.count <= 32 && scopes.allSatisfy { $0.utf8.count < 128 && token($0) }
            && expiresAt > 0 && (earliestRefreshAt.map { $0 > 0 } ?? true)
    }
}

/// Keyed fingerprints of the verified identity of ONE credential (§3.1
/// v2.8): never a raw `sub`, written in the same atomic record as the tokens.
struct SIWCIdentity: Codable, Equatable {
    var subKey: String
    var accountKey: String?
    var valid: Bool { SIWCStore.wellFormedMAC(subKey) && (accountKey.map(SIWCStore.wellFormedMAC) ?? true) }
}

/// Settings-writer evidence of one durable effect (§3.9 "Recovery evidence").
struct SIWCEffectMark: Codable, Equatable {
    var attempt: String
    var effectId: String
    var valid: Bool { UUID(uuidString: attempt) != nil && UUID(uuidString: effectId) != nil }
}

/// A same-registration sign-in saved while the record is in use (§3.9 R3):
/// unusable until activation promotes it. Covered by the record's binding;
/// never promoted by refresh or restart recovery.
struct SIWCStagedReplacement: Codable, Equatable {
    var replacementId: String
    var tokens: SIWCTokens
    var identity: SIWCIdentity
    var hostFingerprint: String
    var generationToBe: String
    var valid: Bool {
        UUID(uuidString: replacementId) != nil && UUID(uuidString: generationToBe) != nil
            && tokens.valid && identity.valid && SIWCStore.wellFormedMAC(hostFingerprint)
    }
}

/// §7 checkpoint for the SIWC record: unusable, carrying its own MAC so a
/// tampered checkpoint is never promoted.
struct SIWCPendingRotation: Codable, Equatable {
    var generation: String
    var replaces: String
    var tokens: SIWCTokens
    var identity: SIWCIdentity
    var mac: String
    var wellFormed: Bool {
        UUID(uuidString: generation) != nil && SubscriptionRefreshFingerprint.wellFormed(replaces)
            && tokens.valid && identity.valid && SIWCStore.wellFormedMAC(mac)
    }
}

/// §7.1 operation record of the SIWC route. Whole-second time, and inside
/// the record binding (Codex round 1 R7): it decides whether another
/// refresh may be sent, so it is not an informational field.
struct SIWCRefreshOp: Codable, Equatable {
    var opId: String
    var tokenFingerprint: String
    var generation: String
    var startedAt: Int
    var state: String
    var valid: Bool {
        UUID(uuidString: opId) != nil && UUID(uuidString: generation) != nil
            && SubscriptionRefreshFingerprint.wellFormed(tokenFingerprint) && SubscriptionRefreshOp.states.contains(state)
    }
}

struct SIWCTokenRecord: Codable {
    var clientId: String
    var generation: String
    var tokens: SIWCTokens? = nil
    var identity: SIWCIdentity? = nil
    var requiresLogin: Bool? = nil
    var invalidClient: Bool? = nil
    var staged: SIWCStagedReplacement? = nil
    var signedInBy: String? = nil
    /// A verified identity-only grant (§3.2 step 7, P4a): the registration is
    /// saved, plan usage is off, and there are no tokens to send with.
    var planUsageOff: Bool? = nil
    /// §7.1 records: they decide whether a refresh may be sent, so they are
    /// bound (Codex round 1 R7), presence and absence alike.
    var refreshOp: SIWCRefreshOp? = nil
    var refreshRecovery: SubscriptionRefreshRecovery? = nil
    var bindingVersion: Int? = nil
    var binding: String? = nil
    // ---- Outside the binding (explicit, audited list: `unboundCleared`) ----
    /// Unusable checkpoint with its own MAC (bound to client, generation,
    /// replaced token and the identity verified for ITS tokens).
    var pendingRotation: SIWCPendingRotation? = nil
    /// Old refresh tokens kept only to be revoked; never sent as a credential.
    var cleanup: [String]? = nil
    var lastEffect: SIWCEffectMark? = nil
    var savedAt: Int? = nil

    /// The record with every field OUTSIDE the binding cleared. A field added
    /// later is bound unless it is added here, deliberately.
    var unboundCleared: SIWCTokenRecord {
        var copy = self
        copy.binding = nil
        copy.pendingRotation = nil
        copy.cleanup = nil; copy.lastEffect = nil; copy.savedAt = nil
        return copy
    }

    var structurallyValid: Bool {
        SIWCStore.wellFormedClientId(clientId) && UUID(uuidString: generation) != nil
            && (tokens?.valid ?? true) && (identity?.valid ?? true) && (staged?.valid ?? true)
            && (signedInBy.map(AssistantProfile.isValidName) ?? true)
            && (binding.map { $0.utf8.count <= 128 } ?? true)   // format judged per record (bindingProblem)
            && (pendingRotation?.wellFormed ?? true) && (refreshOp?.valid ?? true) && (refreshRecovery?.valid ?? true)
            && (cleanup.map { $0.count <= 64 && $0.allSatisfy { !$0.isEmpty && $0.utf8.count < 32768 } } ?? true)
            && (lastEffect?.valid ?? true)
    }
}

struct SIWCTokenFile: Codable {
    var version = 1
    var records: [SIWCTokenRecord] = []
    /// At most one pending SIWC sign-in per store (§3.8). The verifier,
    /// state and nonce stay in the owning process's memory.
    var pendingLogin: String? = nil
    var pendingLoginBy: String? = nil
    var pendingExpiresAt: Int? = nil
    /// Tooling hint only; never recovery evidence (§3.9).
    var lastAttempt: String? = nil

    var valid: Bool {
        version == 1 && records.count <= 64 && Set(records.map(\.clientId)).count == records.count
            && records.allSatisfy(\.structurallyValid)
            && (pendingLogin.map { UUID(uuidString: $0) != nil } ?? true)
            && (pendingLoginBy == nil || (pendingLogin != nil && AssistantProfile.isValidName(pendingLoginBy!)))
            && (pendingExpiresAt == nil || pendingLogin != nil)
            && (lastAttempt.map { UUID(uuidString: $0) != nil } ?? true)
    }
    func record(_ clientId: String) -> SIWCTokenRecord? { records.first { $0.clientId == clientId } }
    mutating func update(_ clientId: String, _ change: (inout SIWCTokenRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.clientId == clientId }) else { return }
        change(&records[index])
    }
}

struct SIWCRegistration: Codable, Equatable {
    var clientId: String
    var issuer: String
    var sub: String
    var email: String?
    var label: String
    var planUsageEnabled: Bool
    var createdAt: Int
    var hostFingerprint: String
    var valid: Bool {
        SIWCStore.wellFormedClientId(clientId) && issuer == SIWCEndpoint.issuer && !sub.isEmpty && sub.utf8.count <= 512
            && (email.map { $0.utf8.count <= 512 } ?? true) && label.utf8.count <= 128 && SIWCStore.wellFormedMAC(hostFingerprint)
    }
}

struct SIWCRegistrationsFile: Codable, Equatable {
    var version = 1
    var registrations: [SIWCRegistration] = []
    /// D21: the store's one active registration, followed by every sharer.
    var active: String? = nil
    var activeLastEffect: SIWCEffectMark? = nil
    var lastAttempt: String? = nil
    var valid: Bool {
        version == 1 && registrations.count <= 64 && Set(registrations.map(\.clientId)).count == registrations.count
            && registrations.allSatisfy(\.valid)
            && (active.map { a in registrations.contains { $0.clientId == a } } ?? true)
            && (activeLastEffect?.valid ?? true) && (lastAttempt.map { UUID(uuidString: $0) != nil } ?? true)
    }
    func registration(_ clientId: String) -> SIWCRegistration? { registrations.first { $0.clientId == clientId } }
}

// MARK: - Store

/// The SIWC files of ONE store directory (`SubscriptionSharing.storeDirectory()`
/// resolves which: the machine store or an extra's own). Atomic owner-only
/// writes, a separate cross-process lock (`subscription-siwc.lock`, 45 s
/// bounded wait), and a per-store integrity key. The legacy
/// `subscription-auth.json` and its lock are never touched here.
struct SIWCStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    /// The store this assistant resolves (prefs_lint: the only resolver).
    static func resolved() -> SIWCStore { SIWCStore(directory: SubscriptionSharing.storeDirectory()) }

    var tokenFile: URL { directory.appendingPathComponent(SIWCEndpoint.tokenFileName) }
    var registrationsFile: URL { directory.appendingPathComponent(SIWCEndpoint.registrationsFileName) }
    var lockFile: URL { directory.appendingPathComponent(SIWCEndpoint.lockFileName) }
    var keyFile: URL { directory.appendingPathComponent(SIWCEndpoint.keyFileName) }

    // Injection only on an explicitly constructed store (selftests).
    var clock: () -> Date = Date.init
    var beforeTokenWrite: (() throws -> Void)? = nil
    var afterTokenWrite: (() throws -> Void)? = nil
    var lockWait: TimeInterval = 45

    var nowSeconds: Int { Int(clock().timeIntervalSince1970) }

    static func wellFormedMAC(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func wellFormedClientId(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value != SIWCEndpoint.dynamicClient
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    // MARK: File IO (same discipline as SubscriptionAuthStore.readStored)

    static func readOwnerOnly(_ url: URL, cap: Int = 262144) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw SIWCError(.local, "Cannot read the ChatGPT sign-in files; repair file access. Nothing was changed.")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, Int(info.st_size) <= cap, info.st_mode & 0o077 == 0 else {
            throw SIWCError(.local, "A ChatGPT sign-in file must be an owner-only regular file. Nothing was changed.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: min(4096, cap + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= cap else { throw SIWCError(.local, "A ChatGPT sign-in file exceeded its size limit.") }
        }
        return data
    }

    func readTokens() throws -> SIWCTokenFile? {
        guard let data = try Self.readOwnerOnly(tokenFile) else { return nil }
        guard let file = try? JSONDecoder().decode(SIWCTokenFile.self, from: data), file.valid else {
            throw SIWCError(.local, "The ChatGPT sign-in records are malformed; they were preserved for repair. Nothing was overwritten.")
        }
        return file
    }

    func readRegistrations() throws -> SIWCRegistrationsFile? {
        guard let data = try Self.readOwnerOnly(registrationsFile) else { return nil }
        guard let file = try? JSONDecoder().decode(SIWCRegistrationsFile.self, from: data), file.valid else {
            throw SIWCError(.local, "The ChatGPT registrations file is malformed; it was preserved for repair. Nothing was overwritten.")
        }
        return file
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func writeTokens(_ file: SIWCTokenFile) throws {
        guard file.valid else { throw SIWCError(.local, "Invalid ChatGPT sign-in state; nothing was written.") }
        _ = try readTokens()   // never replace an unreadable/malformed target
        try beforeTokenWrite?()
        _ = try PrivateStorage.writeAtomically(try Self.encode(file), to: tokenFile)
        try afterTokenWrite?()
    }

    func writeRegistrations(_ file: SIWCRegistrationsFile) throws {
        guard file.valid else { throw SIWCError(.local, "Invalid ChatGPT registrations; nothing was written.") }
        _ = try readRegistrations()
        _ = try PrivateStorage.writeAtomically(try Self.encode(file), to: registrationsFile)
    }

    // MARK: Integrity key and binding (§3.1 v2.8/v2.9)

    /// The store's 32-byte key. Created only together with the first record
    /// (`create`); a missing key with records present leaves every record
    /// unbound (sign-in required), never re-keyed silently.
    func integrityKey(create: Bool) throws -> SymmetricKey? {
        if let data = try Self.readOwnerOnly(keyFile, cap: 64) {
            guard data.count == 32 else { throw SIWCError(.local, "The ChatGPT integrity key is malformed. Nothing was changed.") }
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try PrivateStorage.writeExclusive(bytes, to: keyFile)
        return SymmetricKey(data: bytes)
    }

    static func mac(_ key: SymmetricKey, _ domain: String, _ data: Data) -> String {
        var message = Data(domain.utf8); message.append(0); message.append(data)
        return SIWCEndpoint.hex(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    static func identity(key: SymmetricKey, sub: String, accountId: String?) -> SIWCIdentity {
        SIWCIdentity(subKey: mac(key, "siwc-sub", Data(sub.utf8)),
                     accountKey: accountId.map { mac(key, "siwc-account", Data($0.utf8)) })
    }

    static let bindingVersion = 2

    /// The binding over every bound field of `record` (the record itself with
    /// `unboundCleared` applied, canonical sorted-key JSON).
    static func binding(key: SymmetricKey, record: SIWCTokenRecord) throws -> String {
        var bound = record.unboundCleared
        bound.bindingVersion = bindingVersion
        return mac(key, "briglia-siwc-binding-v1", try encode(bound))
    }

    static func bind(_ record: inout SIWCTokenRecord, key: SymmetricKey) throws {
        record.bindingVersion = bindingVersion
        record.binding = nil
        record.binding = try binding(key: key, record: record)
    }

    /// The checkpoint MAC also names the registration it belongs to.
    static func rotationMAC(key: SymmetricKey, clientId: String, _ rotation: SIWCPendingRotation) throws -> String {
        var copy = rotation; copy.mac = String(repeating: "0", count: 64)
        return mac(key, "briglia-siwc-rotation-v2|" + clientId, try encode(copy))
    }

    /// Nil when `record` carries a valid binding for `registration`; else why
    /// not (claim-free text). Never repaired (§3.1 v2.8).
    static func bindingProblem(_ record: SIWCTokenRecord, registration: SIWCRegistration?, key: SymmetricKey?) -> String? {
        guard let key else { return "integrity key missing" }
        guard let mac = record.binding, record.bindingVersion == bindingVersion else { return "binding missing" }
        guard let expected = try? binding(key: key, record: record) else { return "binding malformed" }
        guard SIWCJWT.constantTimeEqual(mac, expected) else { return "binding does not match the record" }
        guard let registration, registration.clientId == record.clientId else { return "registration missing" }
        if let identity = record.identity {
            guard identity.subKey == Self.mac(key, "siwc-sub", Data(registration.sub.utf8)) else { return "identity disagrees with the registration" }
        }
        if let staged = record.staged {
            guard staged.identity.subKey == Self.mac(key, "siwc-sub", Data(registration.sub.utf8)) else { return "staged identity disagrees" }
        }
        return nil
    }

    // MARK: Lock

    func locked<T>(_ operation: () async throws -> T) async throws -> T {
        try PrivateStorage.ensureDirectory(directory)
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw SIWCError(.local, "Cannot open the ChatGPT sign-in lock") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw SIWCError(.local, "Invalid ChatGPT sign-in lock owner/type/permissions")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + lockWait
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw SIWCError(.local, "Cannot acquire the ChatGPT sign-in lock")
            }
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw SIWCError(.busy, "ChatGPT sign-in is busy; try again shortly.")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { flock(fd, LOCK_UN) }
        try Task.checkCancellation()
        return try await operation()
    }

    // MARK: Usability (§3.1, §5.1)

    enum Usability: Equatable {
        case usable
        case signInRequired(String)
        case planUsageOff
        case invalidClient
    }

    /// Judge one record against its registration, on the record alone.
    func usability(_ record: SIWCTokenRecord?, registration: SIWCRegistration?, key: SymmetricKey?) -> Usability {
        guard let record else { return .signInRequired("no record") }
        if let problem = Self.bindingProblem(record, registration: registration, key: key) { return .signInRequired(problem) }
        if record.invalidClient == true { return .invalidClient }
        guard record.requiresLogin != true else { return .signInRequired("sign-in required") }
        guard let tokens = record.tokens, record.identity != nil else {
            return record.planUsageOff == true ? .planUsageOff : .signInRequired("signed out")
        }
        guard tokens.planUsage else { return .planUsageOff }
        return .usable
    }

    /// The pre-send validation (§3.7 item 2, §4.1): the captured generation is
    /// still the record's, and the record is usable. Throws before any send.
    func validate(clientId: String, generation: String) throws {
        let tokens = try readTokens(), registrations = try readRegistrations()
        let record = tokens?.record(clientId)
        guard let record, record.generation == generation else {
            throw SIWCError(.signInRequired, "ChatGPT login changed; request cancelled.")
        }
        switch usability(record, registration: registrations?.registration(clientId), key: try integrityKey(create: false)) {
        case .usable: return
        case .planUsageOff: throw SIWCError(.planUsageOff, SIWCError.planUsageOffMessage)
        case .invalidClient: throw SIWCError(.invalidClient, SIWCError.invalidClientMessage)
        case .signInRequired: throw SIWCError(.signInRequired, SIWCError.signInMessage)
        }
    }

    // MARK: Pending sign-in ownership (§3.8 "Pending sign-ins")

    static let foreignPendingMessage = "This ChatGPT sign-in was started by another assistant; finish or cancel it there."

    /// Start the store's one pending SIWC sign-in. An expired marker is
    /// cleared; a live one owned by another profile is refused; a live one
    /// owned by this profile is superseded.
    func beginPending(owner: String?) async throws -> String {
        try await locked {
            var file = try readTokens() ?? SIWCTokenFile()
            if let pending = file.pendingLogin, let expires = file.pendingExpiresAt, expires > nowSeconds,
               (file.pendingLoginBy ?? AssistantProfile.defaultName) != (owner ?? AssistantProfile.defaultName) {
                _ = pending
                throw SIWCError(.busy, Self.foreignPendingMessage)
            }
            let id = UUID().uuidString
            file.pendingLogin = id
            file.pendingLoginBy = owner
            file.pendingExpiresAt = nowSeconds + Int(SIWCEndpoint.attemptLifetime)
            try writeTokens(file)
            return id
        }
    }

    enum OwnedCancel: Equatable { case none, cancelled, foreign }

    /// Clear exactly `pending` (late cleanup of the caller's own attempt).
    func cancelPending(_ pending: String) async throws {
        try await locked {
            guard var file = try readTokens(), file.pendingLogin == pending else { return }
            file.pendingLogin = nil; file.pendingLoginBy = nil; file.pendingExpiresAt = nil
            try writeTokens(file)
        }
    }

    /// Cancel the store's pending sign-in only when `profile` owns it (§25.12).
    @discardableResult
    func cancelOwnedPending(profile: String) async throws -> OwnedCancel {
        try await locked {
            guard var file = try readTokens(), file.pendingLogin != nil else { return .none }
            guard (file.pendingLoginBy ?? AssistantProfile.defaultName) == profile else { return .foreign }
            file.pendingLogin = nil; file.pendingLoginBy = nil; file.pendingExpiresAt = nil
            try writeTokens(file)
            return .cancelled
        }
    }

    /// Whether the store still holds an unexpired `pending` (inside the lock).
    func pendingIsCurrent(_ file: SIWCTokenFile?, _ pending: String) -> Bool {
        guard let file, file.pendingLogin == pending, let expires = file.pendingExpiresAt else { return false }
        return expires > nowSeconds
    }
}
