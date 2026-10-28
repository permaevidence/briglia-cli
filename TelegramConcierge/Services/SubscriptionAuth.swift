import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

struct SubscriptionError: Error, LocalizedError {
    let message: String
    var requiresLogin: Bool
    /// The subscription reported its usage limit. Never retried, and never
    /// moved to API billing: the main agent is on the same allowance, so web
    /// research fails with this message like every other subscription request.
    var usageExhausted = false
    init(_ message: String, requiresLogin: Bool = false) { self.message = message; self.requiresLogin = requiresLogin }
    var errorDescription: String? { message }
}

/// Own credentials only; never imports or modifies any other client's login.
/// Public OAuth client compatibility follows the pinned Pi/OpenCode adapters.
/// Briglia identifies itself as Briglia; this is not a client-registration claim.
enum SubscriptionEndpoint {
    static let issuer = "https://auth.openai.com"
    static let inference = "https://chatgpt.com/backend-api/codex/responses"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let verificationURL = issuer + "/codex/device"
    static let deviceCallback = issuer + "/deviceauth/callback"
    static let storeName = "subscription-auth.json"

    /// Allowlisted usage-exhaustion codes. Ordinary transient rate limits
    /// (`rate_limit_exceeded`, bare 429s) are not in this set and stay retryable.
    static let usageCodes: Set<String> = ["usage_limit_reached", "usage_not_included", "insufficient_quota"]

    static func usageExhaustedError() -> SubscriptionError {
        var failure = SubscriptionError("ChatGPT subscription usage is exhausted or not included. Check your plan/usage before retrying; no API billing fallback was attempted.")
        failure.usageExhausted = true
        return failure
    }

    /// The same classification for errors delivered INSIDE an HTTP-200 stream:
    /// a top-level SSE `error` (`code`, or nested `error.code`/`error.type`)
    /// or a `response.failed` whose `response.error` carries the code. Only
    /// the allowlisted codes are read; message text never escapes.
    static func streamedUsageError(_ event: [String: JSONValue]) -> SubscriptionError? {
        func codes(_ object: [String: JSONValue]?) -> [String] {
            guard let object else { return [] }
            return [object["code"]?.responsesString, object["type"]?.responsesString].compactMap { $0 }
        }
        var candidates = [event["code"]?.responsesString].compactMap { $0 }
        candidates += codes(event["error"]?.responsesObject)
        candidates += codes(event["response"]?.responsesObject?["error"]?.responsesObject)
        return candidates.contains(where: usageCodes.contains) ? usageExhaustedError() : nil
    }

    /// Inspect only fixed error codes; provider body text may contain secrets or
    /// echoed inputs and never becomes a user-facing authentication exception.
    static func providerError(status: Int, body: Data) -> SubscriptionError? {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? error?["type"] as? String ?? ""
        if usageCodes.contains(code) { return usageExhaustedError() }
        if ["model_not_found", "model_not_available", "unsupported_model"].contains(code) {
            return SubscriptionError("This model is unavailable for the selected ChatGPT account. Choose another subscription model.")
        }
        if code.lowercased().contains("residency") {
            return SubscriptionError("ChatGPT rejected workspace compute residency. This adapter cannot select an unverified region.")
        }
        if status == 403 {
            return SubscriptionError("ChatGPT denied this account/workspace access. Check subscription eligibility and workspace permissions.")
        }
        return nil
    }
}

struct SubscriptionCredential: Codable {
    var access: String
    var refresh: String
    var expires: Date
    var account: String
    var residency: String?

    var valid: Bool {
        !access.isEmpty && !refresh.isEmpty && !account.isEmpty
            && access.utf8.allSatisfy { $0 > 32 && $0 < 127 } && refresh.utf8.allSatisfy { $0 > 32 && $0 < 127 }
            && access.utf8.count < 32768 && refresh.utf8.count < 32768
            && account.utf8.count < 512 && !account.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true })
            && expires.timeIntervalSince1970.isFinite
    }
}

/// Refresh settlement records (SIWC plan §7, §7.1). All three live in the
/// same atomic credential file, so every write is all-or-nothing and the lock
/// that serializes refresh, login and logout also serializes them. Older
/// binaries ignore the extra keys (and drop them on their next write).
///
/// `pendingRotation`: a token set received with HTTP 200 and not yet
/// validated/committed. Unusable for inference; promoted under the lock by
/// the next refresh-and-settle only while its generation is current, the
/// login isn't blocked, it replaces the current refresh token and it
/// re-validates (same account and residency). Otherwise it is discarded.
struct SubscriptionPendingRotation: Codable {
    var generation: String
    /// Fingerprint of the refresh token this rotation replaces.
    var replaces: String
    var credential: SubscriptionCredential
    var valid: Bool { UUID(uuidString: generation) != nil && SubscriptionRefreshFingerprint.wellFormed(replaces) && credential.valid }
}

/// Written durably before every refresh send. `sending` left on disk means
/// the process died (or the outcome was lost) after the request may have
/// left; `ambiguous` means the send ended without a usable outcome. Either
/// one, for the current generation and refresh token, makes the next refresh
/// a recovery attempt (§7.1).
struct SubscriptionRefreshOp: Codable {
    var opId: String
    var tokenFingerprint: String
    var generation: String
    var startedAt: Date
    var state: String
    static let states: Set<String> = ["sending", "ambiguous"]
    var valid: Bool {
        UUID(uuidString: opId) != nil && UUID(uuidString: generation) != nil
            && SubscriptionRefreshFingerprint.wellFormed(tokenFingerprint) && Self.states.contains(state)
            && startedAt.timeIntervalSince1970.isFinite
    }
}

/// The one recovery retry for (generation, refresh token), reserved durably
/// before it is sent. Once present, no process and no later call gets
/// another attempt for that token; only a new sign-in clears it.
struct SubscriptionRefreshRecovery: Codable {
    var tokenFingerprint: String
    var generation: String
    var state: String
    static let states: Set<String> = ["reserved", "exhausted"]
    var valid: Bool {
        UUID(uuidString: generation) != nil && SubscriptionRefreshFingerprint.wellFormed(tokenFingerprint) && Self.states.contains(state)
    }
}

enum SubscriptionRefreshFingerprint {
    static func of(_ refreshToken: String) -> String {
        SHA256.hash(data: Data(("briglia-refresh-op\u{0}" + refreshToken).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func wellFormed(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct SubscriptionAuthState: Codable {
    var version = 1
    var generation: String
    var pendingLogin: String?
    var credential: SubscriptionCredential?
    var requiresLogin: Bool? = nil
    var deviceChallenge: SubscriptionDeviceChallenge? = nil
    var pendingRotation: SubscriptionPendingRotation? = nil
    var refreshOp: SubscriptionRefreshOp? = nil
    var refreshRecovery: SubscriptionRefreshRecovery? = nil
    /// Multi-assistant owners (MULTI_ASSISTANT_PLAN §25.12): the profile that
    /// signed in / started the pending login. Omitted in never-multi mode
    /// (byte-identical file); older binaries ignore and drop them.
    var signedInBy: String? = nil
    var pendingLoginBy: String? = nil
    var valid: Bool {
        version == 1 && UUID(uuidString: generation) != nil
            && (pendingLogin == nil || UUID(uuidString: pendingLogin!) != nil)
            && (signedInBy == nil || AssistantProfile.isValidName(signedInBy!))
            && (pendingLoginBy == nil || (pendingLogin != nil && AssistantProfile.isValidName(pendingLoginBy!)))
            && (credential == nil || credential!.valid)
            && (deviceChallenge == nil || (pendingLogin != nil && deviceChallenge!.valid))
            && (pendingRotation == nil || pendingRotation!.valid)
            && (refreshOp == nil || refreshOp!.valid)
            && (refreshRecovery == nil || refreshRecovery!.valid)
    }
    /// Every refresh-settlement record cleared (new login, logout).
    mutating func clearRefreshRecords() { pendingRotation = nil; refreshOp = nil; refreshRecovery = nil }

    // Centralised pending-login transitions (§25.12): callable inside an
    // existing `store.locked` closure, the owner written with the id.
    mutating func startPending(_ id: String, owner: String? = SubscriptionSharing.ownerTag) {
        pendingLogin = id; pendingLoginBy = owner; deviceChallenge = nil
    }
    mutating func clearPending() { pendingLogin = nil; pendingLoginBy = nil; deviceChallenge = nil }
    /// A new credential and generation; `signedInBy` from the pending owner.
    mutating func commitPending(_ credential: SubscriptionCredential) {
        let owner = pendingLoginBy
        generation = UUID().uuidString
        self.credential = credential
        requiresLogin = nil
        clearPending()
        clearRefreshRecords()
        signedInBy = owner
    }
}

/// What the caller of a refresh-and-settle sees. The settle runs detached;
/// a cancelled caller stops waiting at once and never receives the result,
/// while the settle itself finishes (or, if nothing was sent yet, stops
/// before sending).
final class SubscriptionRefreshCaller: @unchecked Sendable {
    typealias Outcome = Result<SubscriptionCredential, Error>
    private let lock = NSLock()
    private var isCancelled = false
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }
    func cancel() {
        lock.lock(); isCancelled = true
        if outcome == nil { outcome = .failure(CancellationError()) }
        let waiting = continuation; continuation = nil; let result = outcome!
        lock.unlock()
        waiting?.resume(returning: result)
    }
    func finish(_ result: Outcome) {
        lock.lock()
        if outcome == nil { outcome = result }
        let waiting = continuation; continuation = nil; let delivered = outcome!
        lock.unlock()
        waiting?.resume(returning: delivered)
    }
    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome { lock.unlock(); continuation.resume(returning: outcome); return }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// Atomic records, no credential cache. The same sidecar serializes refresh,
/// logout and login commit across all processes. A pending login never holds it.
struct SubscriptionAuthStore {
    let directory: URL
    /// The default store is the one this assistant uses: the machine store
    /// (default's config root) unless an extra chose its own (§25.2–§25.3).
    /// For default this is exactly `StoragePaths.configRoot`, as before.
    init(directory: URL = SubscriptionSharing.storeDirectory()) { self.directory = directory }
    var file: URL { directory.appendingPathComponent(SubscriptionEndpoint.storeName) }
    var lockFile: URL { directory.appendingPathComponent("subscription-auth.lock") }

    // Injection only on an explicitly constructed store; never global/env-driven.
    var beforeWrite: (() throws -> Void)? = nil
    var afterWrite: (() throws -> Void)? = nil

    func read() throws -> SubscriptionAuthState? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw SubscriptionError("Cannot read subscription credentials; repair file access or sign out. Credentials were preserved.")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 131072,
              info.st_mode & 0o077 == 0 else {
            throw SubscriptionError("Subscription credential file must be an owner-only regular file.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: min(4096, 131073 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 131072 else { throw SubscriptionError("Subscription credential file exceeded its size limit") }
        }
        guard let state = try? JSONDecoder().decode(SubscriptionAuthState.self, from: data), state.valid else {
            throw SubscriptionError("Subscription credentials are malformed; preserved for repair. No login data was overwritten.")
        }
        return state
    }

    func write(_ state: SubscriptionAuthState) throws {
        guard state.valid else { throw SubscriptionError("Invalid subscription state") }
        // Validate the existing target even when the caller is replacing it.
        _ = try read()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try beforeWrite?()
        _ = try PrivateStorage.writeAtomically(try encoder.encode(state), to: file)
        try afterWrite?()
    }

    func locked<T>(_ operation: () async throws -> T) async throws -> T {
        try PrivateStorage.ensureDirectory(directory)
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw SubscriptionError("Cannot open subscription lock") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw SubscriptionError("Invalid subscription lock owner/type/permissions")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw SubscriptionError("Cannot acquire subscription lock")
            }
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SubscriptionError("Subscription authentication is busy; retry shortly") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { flock(fd, LOCK_UN) }
        try Task.checkCancellation()
        return try await operation()
    }

    func beginLogin() async throws -> String {
        try await locked {
            var state = try read() ?? SubscriptionAuthState(generation: UUID().uuidString)
            let pending = UUID().uuidString
            state.startPending(pending)
            try write(state)
            return pending
        }
    }

    /// `precondition` runs under the acquired lock, right before the write:
    /// a caller whose own validity can change while this waits for the lock
    /// (the menu's action ticket) gets a last say, and throwing writes nothing.
    func commitLogin(_ credential: SubscriptionCredential, pending: String,
                     precondition: (@Sendable () throws -> Void)? = nil) async throws -> String {
        try await locked {
            guard var state = try read(), state.pendingLogin == pending else {
                throw SubscriptionError("Login was cancelled or superseded; start login again")
            }
            try precondition?()
            state.commitPending(credential)
            try Task.checkCancellation()
            try write(state)
            return state.generation
        }
    }

    /// `cancelLogin` that still runs when the calling task was cancelled
    /// (it only clears this exact pending ID).
    func cancelLoginDetached(_ pending: String) async {
        let store = self
        await Task.detached { try? await store.cancelLogin(pending) }.value
    }

    func cancelLogin(_ pending: String) async throws {
        try await locked {
            guard var state = try read(), state.pendingLogin == pending else { return }
            state.clearPending()
            state.deviceChallenge = nil
            try write(state)
        }
    }

    enum OwnedCancel: Equatable { case none, cancelled, foreign }

    /// Cancel the pending login only when the calling profile owns it
    /// (§25.12): the owner filter and the cancelled id are one operation.
    @discardableResult
    func cancelOwnedPending(profile: String = AssistantProfile.selectedName) async throws -> OwnedCancel {
        try await locked {
            guard var state = try read(), state.pendingLogin != nil else { return .none }
            guard SubscriptionSharing.pendingOwned(state, by: profile) else { return .foreign }
            state.clearPending()
            try write(state)
            return .cancelled
        }
    }

    func logout(checkpoint: () throws -> Void = {}) async throws {
        try await locked {
            _ = try read()
            // A durable tombstone prevents late callbacks from recreating auth.
            try checkpoint()
            try write(SubscriptionAuthState(generation: UUID().uuidString))
        }
    }

    static let refreshExhaustedMessage = "ChatGPT sign-in may need to be repeated: the login refresh did not complete and its one recovery attempt is used up. Use subscription login. No API fallback was attempted."
    static let accountChangedMessage = "Refresh changed the ChatGPT account/workspace; sign in again explicitly"
    static let refreshNotSavedMessage = "ChatGPT sign-in may need to be repeated: the refreshed login could not be saved. Briglia will try to recover it on the next request; if that fails, use subscription login."

    /// Refresh-and-settle (SIWC plan §7, §7.1). Returns the stored credential
    /// when it is still fresh; otherwise refreshes it under the cross-process
    /// lock in a detached task that does not inherit the caller's
    /// cancellation. Once a refresh request may have left, the response is
    /// validated and persisted even when the caller was cancelled (`/stop`);
    /// cancellation is honoured by the caller only, which stops waiting and
    /// never uses the result.
    func credential(generation: String, rejectedAccess: String? = nil,
                    refresh: @escaping (String) async throws -> SubscriptionCredential) async throws -> SubscriptionCredential {
        try Task.checkCancellation()
        let caller = SubscriptionRefreshCaller()
        let store = self
        Task.detached {
            do { caller.finish(.success(try await store.settle(generation: generation, rejectedAccess: rejectedAccess, caller: caller, refresh: refresh))) }
            catch { caller.finish(.failure(error)) }
        }
        let outcome = await withTaskCancellationHandler { await caller.wait() } onCancel: { caller.cancel() }
        try Task.checkCancellation()
        return try outcome.get()
    }

    enum RefreshDisposition { case terminal, notSent, ambiguous }
    /// Only errors that prove what happened are anything but ambiguous: an
    /// explicit refusal (terminal) or a budget refusal raised before the
    /// request was built. Any other reply — 429, 500, 503 or an unfamiliar
    /// status — does not prove the token was left unrotated, so it is
    /// ambiguous and bounded by the one recovery.
    static func disposition(_ error: Error) -> RefreshDisposition {
        if let failure = error as? SubscriptionError, failure.requiresLogin { return .terminal }
        if error is AuthBudgetExhausted || error is SendBudgetExhausted { return .notSent }
        return .ambiguous
    }

    private func settle(generation: String, rejectedAccess: String?, caller: SubscriptionRefreshCaller,
                        refresh: (String) async throws -> SubscriptionCredential) async throws -> SubscriptionCredential {
        try await locked {
            guard var state = try read(), state.generation == generation, var old = state.credential else {
                throw SubscriptionError("ChatGPT login changed or ended. Select the profile again after login.")
            }
            guard state.requiresLogin != true else { throw SubscriptionError("ChatGPT requires a new login; use subscription login") }
            // §7 step 4 / §7.1 step 3: disk first. A checkpoint left by an
            // earlier settle (crash, failed final write) is promoted before
            // anything is sent. One bound to this login and this refresh
            // token that fails revalidation (another account or residency) is
            // evidence the rotation already happened for the wrong account:
            // the login is blocked, and the old token is never sent again —
            // even when saving the block fails, because the checkpoint stays
            // on disk and refuses again next time. A checkpoint bound to
            // another generation or token is unrelated and discarded.
            if let pending = state.pendingRotation {
                state.pendingRotation = nil
                if pending.generation == generation, pending.replaces == SubscriptionRefreshFingerprint.of(old.refresh) {
                    guard pending.credential.account == old.account, pending.credential.residency == old.residency else {
                        state.refreshOp = nil
                        state.requiresLogin = true
                        try? write(state)
                        throw SubscriptionError(Self.accountChangedMessage, requiresLogin: true)
                    }
                    state.credential = pending.credential
                    state.refreshOp = nil
                    state.refreshRecovery = nil
                    old = pending.credential
                }
                try write(state)
            }
            if old.expires > Date().addingTimeInterval(60), rejectedAccess == nil || rejectedAccess != old.access { return old }
            let fingerprint = SubscriptionRefreshFingerprint.of(old.refresh)
            if let recovery = state.refreshRecovery, recovery.generation == generation, recovery.tokenFingerprint == fingerprint {
                throw SubscriptionError(Self.refreshExhaustedMessage)
            }
            let recovering = state.refreshOp.map { $0.generation == generation && $0.tokenFingerprint == fingerprint } ?? false
            // Nothing has been sent yet: a cancelled caller still stops it here.
            if caller.cancelled { throw CancellationError() }
            // §7.1 steps 1 and 4: the operation record (and, for a recovery,
            // the reservation) is durable before the send, or nothing is sent.
            // The records they replace are kept aside: an attempt proven never
            // sent puts them back, so the earlier uncertain send still makes
            // the next attempt the (one) recovery.
            let priorOp = state.refreshOp, priorRecovery = state.refreshRecovery
            if recovering { state.refreshRecovery = SubscriptionRefreshRecovery(tokenFingerprint: fingerprint, generation: generation, state: "reserved") }
            state.refreshOp = SubscriptionRefreshOp(opId: UUID().uuidString, tokenFingerprint: fingerprint, generation: generation,
                                                    startedAt: Date(), state: "sending")
            try write(state)
            // The write may have blocked while the caller was stopped: admit
            // the send only now. Undoing the records is best effort; if that
            // write fails the reservation stays spent (conservative).
            if caller.cancelled {
                state.refreshOp = priorOp; state.refreshRecovery = priorRecovery
                try? write(state)
                throw CancellationError()
            }
            let updated: SubscriptionCredential
            do { updated = try await refresh(old.refresh) }
            catch {
                switch Self.disposition(error) {
                case .terminal:
                    state.requiresLogin = true
                    state.refreshOp = nil
                    try? write(state)
                    throw error
                case .notSent:
                    state.refreshOp = priorOp; state.refreshRecovery = priorRecovery
                    try? write(state)
                    throw error
                case .ambiguous:
                    // Credentials are kept; the record says the outcome is
                    // unknown. A failed write leaves `sending`, which means
                    // the same to the next settle.
                    state.refreshOp?.state = "ambiguous"
                    if recovering { state.refreshRecovery?.state = "exhausted" }
                    try? write(state)
                    if recovering { throw SubscriptionError(Self.refreshExhaustedMessage) }
                    throw error
                }
            }
            // HTTP 200: §7 step 3. Checkpoint first (unusable, bound to this
            // generation and the replaced token), then validate, then one
            // atomic write commits it. A failed checkpoint still tries the
            // commit; neither failure ever hands out an unsaved token.
            state.pendingRotation = SubscriptionPendingRotation(generation: generation, replaces: fingerprint, credential: updated)
            try? write(state)
            guard updated.account == old.account, updated.residency == old.residency else {
                // The server already rotated the old refresh token away, so it
                // is not offered again: the login is blocked until an
                // explicit sign-in, and the other account's tokens are dropped.
                state.pendingRotation = nil
                state.refreshOp = nil
                state.requiresLogin = true
                try? write(state)
                throw SubscriptionError(Self.accountChangedMessage, requiresLogin: true)
            }
            state.credential = updated
            state.clearRefreshRecords()
            do { try write(state) } catch {
                // A final-write or fsync error doesn't prove the replacement
                // is absent: the next settle re-reads disk and promotes it
                // (or the checkpoint) before considering any retry.
                throw SubscriptionError(Self.refreshNotSavedMessage)
            }
            return updated
        }
    }

    func requireLogin(generation: String, rejectedAccess: String?) async throws {
        try await locked {
            guard var state = try read(), state.generation == generation,
                  state.credential?.access == rejectedAccess else { return }
            state.requiresLogin = true
            try write(state)
        }
    }

    func validate(generation: String) throws {
        guard let state = try read(), state.generation == generation, state.credential != nil, state.requiresLogin != true else {
            throw SubscriptionError("ChatGPT login changed; request cancelled")
        }
    }
}

/// Auth response bodies and URLs containing codes are never included in errors.
/// Redirects are refused even on the same host. Separate from model transport.
final class SubscriptionAuthHTTP: NSObject, URLSessionDataDelegate, RoutedDataTaskDelegate, @unchecked Sendable {
    let refusesRedirects = true
    typealias Reply = (Data, Int)
    private let lock = NSLock()
    private var bytes = Data()
    private var status = 0
    private var continuation: CheckedContinuation<Reply, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var deadlineTimer: DispatchWorkItem?
    /// Overall bound for one auth request, whichever session carries it.
    /// The private macOS session also has a 30 s resource timeout, but the
    /// process-wide shared session (Linux) only has a week-long backstop and
    /// a per-chunk idle timeout, so a reply that keeps trickling would never
    /// end. The timer cancels only this request's task; it is independent
    /// of the caller (a detached refresh is never cancelled by `/stop`).
    let deadline: TimeInterval
    /// Selftests only: a loopback issuer. Production always uses the
    /// reviewed `SubscriptionEndpoint.issuer`.
    let issuer: String
    init(deadline: TimeInterval = 30, issuer: String = SubscriptionEndpoint.issuer) {
        self.deadline = deadline; self.issuer = issuer
        super.init()
    }
    func post(path: String, fields: [String: String], form: Bool = false) async throws -> Reply {
        guard ["/oauth/token", "/api/accounts/deviceauth/usercode", "/api/accounts/deviceauth/token"].contains(path) else {
            throw SubscriptionError("Unreviewed authentication endpoint")
        }
        var request = URLRequest(url: URL(string: issuer + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = deadline
        request.setValue(SessionAffinity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("briglia", forHTTPHeaderField: "originator")
        if form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
                $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
            }.joined(separator: "&").utf8)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                if let shared = SharedDataTaskSession.active {
                    // Linux: never one session per request (see SharedDataTaskSession).
                    task = shared.dataTask(with: request, delegate: self)
                } else {
                    let config = URLSessionConfiguration.ephemeral
                    config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForResource = deadline
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    self.session = session
                    task = session.dataTask(with: request)
                }
                let running = task!
                let timer = DispatchWorkItem { running.cancel() }
                deadlineTimer = timer
                DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: timer)
                running.resume()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock()
            task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if bytes.count + data.count > 131072 { dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil
        deadlineTimer?.cancel(); deadlineTimer = nil; lock.unlock()
        if let error { continuation?.resume(throwing: error is CancellationError ? error : SubscriptionError("Authentication network request failed; retry login")) }
        else { continuation?.resume(returning: (bytes, status)) }
        // Only this request's own session; the shared one is never invalidated.
        if let own = self.session, own === session { own.invalidateAndCancel() }
        self.session = nil
    }
}

struct SubscriptionLogin {
    typealias Post = (String, [String: String], Bool) async throws -> SubscriptionAuthHTTP.Reply
    var store = SubscriptionAuthStore()
    var deviceTimeout: TimeInterval = 900
    var post: Post = { try await SubscriptionAuthHTTP().post(path: $0, fields: $1, form: $2) }
    /// Wraps the final credential commit (default: commit directly). The
    /// live menu runs it inside the running agent's settings barrier, with
    /// its own validity and replacement checks, so the new login and the
    /// agent's switch to it happen together.
    /// The hook's `commit` takes a precondition that the store re-checks
    /// under its lock immediately before writing the credential.
    typealias Commit = (_ precondition: (@Sendable () throws -> Void)?) async throws -> String
    typealias CommitHook = (_ commit: Commit) async throws -> String
    var commitHook: CommitHook? = nil
    func commit(_ credential: SubscriptionCredential, pending: String) async throws -> String {
        let direct: Commit = { try await store.commitLogin(credential, pending: pending, precondition: $0) }
        if let commitHook { return try await commitHook(direct) }
        return try await direct(nil)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 131072, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubscriptionError("Malformed authentication response")
        }
        return object
    }
    static func token(_ data: Data) throws -> SubscriptionCredential {
        let object = try object(data)
        if let number = object["expires_in"] as? NSNumber, String(cString: number.objCType) == "c" {
            throw SubscriptionError("Invalid authentication expiry")
        }
        guard let access = object["access_token"] as? String, let refresh = object["refresh_token"] as? String,
              let seconds = object["expires_in"] as? Double, seconds > 0, seconds <= 31_536_000 else {
            throw SubscriptionError("Authentication response omitted required credentials or expiry")
        }
        // Claims are used only from the token returned over the reviewed TLS
        // exchange. Decoding a JWT is not signature verification or entitlement.
        func claims(_ token: String) -> [String: Any]? {
            let parts = token.split(separator: "."); guard parts.count == 3 else { return nil }
            var part = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            part += String(repeating: "=", count: (4 - part.count % 4) % 4)
            guard let data = Data(base64Encoded: part), data.count < 65536 else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let payload = claims(access) ?? [:]
        let auth = payload["https://api.openai.com/auth"] as? [String: Any] ?? payload
        guard let account = auth["chatgpt_account_id"] as? String, !account.isEmpty else {
            throw SubscriptionError("Authentication returned no explicit ChatGPT account/workspace")
        }
        let residencyValue = auth["chatgpt_compute_residency"] ?? payload["chatgpt_compute_residency"]
        let residency = residencyValue as? String
        guard residencyValue == nil || residency == "no_constraint" else {
            throw SubscriptionError("This workspace requires compute residency that this subscription adapter has not verified")
        }
        let credential = SubscriptionCredential(access: access, refresh: refresh,
            expires: Date().addingTimeInterval(seconds), account: account, residency: residency)
        guard credential.valid else { throw SubscriptionError("Invalid authentication credential fields") }
        return credential
    }
    func refresh(_ token: String) async throws -> SubscriptionCredential {
        let (data, status) = try await post("/oauth/token", ["grant_type": "refresh_token", "refresh_token": token,
            "client_id": SubscriptionEndpoint.clientID], true)
        guard status == 200 else { throw SubscriptionError("ChatGPT refresh failed (HTTP \(status)); sign in again. No API fallback was attempted.", requiresLogin: [400, 401, 403].contains(status)) }
        return try Self.token(data)
    }
    func device(show: (String, String) async throws -> Void) async throws -> String {
        let pending = try await store.beginLogin()
        do {
            let (data, status) = try await post("/api/accounts/deviceauth/usercode", ["client_id": SubscriptionEndpoint.clientID], false)
            guard status == 200 else { throw SubscriptionError("Device login unavailable (HTTP \(status)); enable device login in ChatGPT security settings or use browser login") }
            let object = try Self.object(data)
            guard let device = object["device_auth_id"] as? String, let code = object["user_code"] as? String,
                  !device.isEmpty, !code.isEmpty, code.count < 64 else { throw SubscriptionError("Invalid device authorization response") }
            guard let offeredInterval = Double(String(describing: object["interval"] ?? "5")),
                  offeredInterval.isFinite, offeredInterval >= 1, offeredInterval <= 900 else {
                throw SubscriptionError("Invalid device polling interval")
            }
            var interval = offeredInterval
            try await show(SubscriptionEndpoint.verificationURL, code)
            let deadline = Date().addingTimeInterval(deviceTimeout)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard try store.read()?.pendingLogin == pending else { throw SubscriptionError("Login cancelled or superseded") }
                let (reply, codeStatus) = try await post("/api/accounts/deviceauth/token", ["device_auth_id": device, "user_code": code], false)
                if codeStatus == 200 {
                    let result = try Self.object(reply)
                    guard let code = result["authorization_code"] as? String, let verifier = result["code_verifier"] as? String else { throw SubscriptionError("Device login omitted the authorization code") }
                    let (tokens, tokenStatus) = try await post("/oauth/token", ["grant_type": "authorization_code", "code": code,
                        "code_verifier": verifier, "client_id": SubscriptionEndpoint.clientID, "redirect_uri": SubscriptionEndpoint.deviceCallback], true)
                    guard tokenStatus == 200 else { throw SubscriptionError("Device token exchange failed (HTTP \(tokenStatus))") }
                    return try await commit(Self.token(tokens), pending: pending)
                }
                let reason = (try? Self.object(reply)["error"] as? String) ?? ""
                if reason == "slow_down" || codeStatus == 429 { interval = min(900, interval + 5); continue }
                if ["access_denied", "expired_token"].contains(reason) { throw SubscriptionError("Device login denied or expired") }
                guard codeStatus == 403 || codeStatus == 404 || reason == "authorization_pending" else { throw SubscriptionError("Device login failed (HTTP \(codeStatus))") }
            }
            throw SubscriptionError("Device login expired; start again")
        } catch {
            // Cleanup is best effort; pending IDs are inert and a later
            // login/logout supersedes them durably. It runs outside this
            // task's cancellation, so a cancelled sign-in doesn't leave a
            // pending ID that blocks selecting ChatGPT until the next login.
            await store.cancelLoginDetached(pending)
            throw error
        }
    }
}
