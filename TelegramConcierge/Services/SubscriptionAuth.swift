import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct SubscriptionError: Error, LocalizedError {
    let message: String
    var requiresLogin: Bool
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

    /// Inspect only fixed error codes; provider body text may contain secrets or
    /// echoed inputs and never becomes a user-facing authentication exception.
    static func providerError(status: Int, body: Data) -> SubscriptionError? {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? error?["type"] as? String ?? ""
        if ["usage_limit_reached", "usage_not_included", "insufficient_quota"].contains(code) {
            return SubscriptionError("ChatGPT subscription usage is exhausted or not included. Check your plan/usage before retrying; no API billing fallback was attempted.")
        }
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

struct SubscriptionAuthState: Codable {
    var version = 1
    var generation: String
    var pendingLogin: String?
    var credential: SubscriptionCredential?
    var requiresLogin: Bool? = nil
    var deviceChallenge: SubscriptionDeviceChallenge? = nil
    var valid: Bool {
        version == 1 && UUID(uuidString: generation) != nil
            && (pendingLogin == nil || UUID(uuidString: pendingLogin!) != nil)
            && (credential == nil || credential!.valid)
            && (deviceChallenge == nil || (pendingLogin != nil && deviceChallenge!.valid))
    }
}

/// Atomic records, no credential cache. The same sidecar serializes refresh,
/// logout and login commit across all processes. A pending login never holds it.
struct SubscriptionAuthStore {
    let directory: URL
    init(directory: URL = StoragePaths.configRoot) { self.directory = directory }
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
            state.pendingLogin = pending
            state.deviceChallenge = nil
            try write(state)
            return pending
        }
    }

    func commitLogin(_ credential: SubscriptionCredential, pending: String) async throws -> String {
        try await locked {
            guard var state = try read(), state.pendingLogin == pending else {
                throw SubscriptionError("Login was cancelled or superseded; start login again")
            }
            state.generation = UUID().uuidString
            state.pendingLogin = nil
            state.deviceChallenge = nil
            state.credential = credential
            state.requiresLogin = nil
            try Task.checkCancellation()
            try write(state)
            return state.generation
        }
    }

    func cancelLogin(_ pending: String) async throws {
        try await locked {
            guard var state = try read(), state.pendingLogin == pending else { return }
            state.pendingLogin = nil
            state.deviceChallenge = nil
            try write(state)
        }
    }

    func logout() async throws {
        try await locked {
            _ = try read()
            // A durable tombstone prevents late callbacks from recreating auth.
            try write(SubscriptionAuthState(generation: UUID().uuidString))
        }
    }

    func credential(generation: String, rejectedAccess: String? = nil,
                    refresh: (String) async throws -> SubscriptionCredential) async throws -> SubscriptionCredential {
        try await locked {
            guard var state = try read(), state.generation == generation, let old = state.credential else {
                throw SubscriptionError("ChatGPT login changed or ended. Select the profile again after login.")
            }
            guard state.requiresLogin != true else { throw SubscriptionError("ChatGPT requires a new login; use subscription login") }
            if old.expires > Date().addingTimeInterval(60), rejectedAccess == nil || rejectedAccess != old.access { return old }
            let updated: SubscriptionCredential
            do { updated = try await refresh(old.refresh) }
            catch {
                if (error as? SubscriptionError)?.requiresLogin == true {
                    state.requiresLogin = true
                    try write(state)
                }
                throw error
            }
            try Task.checkCancellation()
            guard updated.account == old.account, updated.residency == old.residency else {
                throw SubscriptionError("Refresh changed the ChatGPT account/workspace; sign in again explicitly")
            }
            state.credential = updated
            try write(state)
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
final class SubscriptionAuthHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Reply = (Data, Int)
    private let lock = NSLock()
    private var bytes = Data()
    private var status = 0
    private var continuation: CheckedContinuation<Reply, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    func post(path: String, fields: [String: String], form: Bool = false) async throws -> Reply {
        guard ["/oauth/token", "/api/accounts/deviceauth/usercode", "/api/accounts/deviceauth/token"].contains(path) else {
            throw SubscriptionError("Unreviewed authentication endpoint")
        }
        var request = URLRequest(url: URL(string: SubscriptionEndpoint.issuer + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
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
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForResource = 30
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                task = session.dataTask(with: request); task!.resume()
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
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        if let error { continuation?.resume(throwing: error is CancellationError ? error : SubscriptionError("Authentication network request failed; retry login")) }
        else { continuation?.resume(returning: (bytes, status)) }
        session.invalidateAndCancel(); self.session = nil
    }
}

struct SubscriptionLogin {
    typealias Post = (String, [String: String], Bool) async throws -> SubscriptionAuthHTTP.Reply
    var store = SubscriptionAuthStore()
    var deviceTimeout: TimeInterval = 900
    var post: Post = { try await SubscriptionAuthHTTP().post(path: $0, fields: $1, form: $2) }

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
                    return try await store.commitLogin(Self.token(tokens), pending: pending)
                }
                let reason = (try? Self.object(reply)["error"] as? String) ?? ""
                if reason == "slow_down" || codeStatus == 429 { interval = min(900, interval + 5); continue }
                if ["access_denied", "expired_token"].contains(reason) { throw SubscriptionError("Device login denied or expired") }
                guard codeStatus == 403 || codeStatus == 404 || reason == "authorization_pending" else { throw SubscriptionError("Device login failed (HTTP \(codeStatus))") }
            }
            throw SubscriptionError("Device login expired; start again")
        } catch {
            // Cleanup is best effort on cancellation only; pending IDs are inert
            // and a later login/logout supersedes them durably.
            try? await store.cancelLogin(pending)
            throw error
        }
    }
}
