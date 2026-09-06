import Foundation

/// Device-flow state is stored with the credentials, never in a GUI or argv.
struct SubscriptionDeviceChallenge: Codable {
    var deviceID: String
    var userCode: String
    var expires: Date
    var nextPoll: Date
    var interval: Double
    var valid: Bool {
        !deviceID.isEmpty && deviceID.count < 4096 && !userCode.isEmpty && userCode.count < 64
            && interval.isFinite && interval >= 1 && interval <= 900
            && expires.timeIntervalSince1970.isFinite && nextPoll.timeIntervalSince1970.isFinite
    }
}

/// Shared native setup interface. The GUI receives no access/refresh token or
/// device authorization ID. Every state mutation is checked under the auth lock.
struct SubscriptionSetup {
    var login = SubscriptionLogin()
    static func checkLoginReplacement() throws {
        if ProviderProfiles.activeProfile() == .chatgpt,
           let state = try SubscriptionAuthStore().read(), state.credential != nil, state.requiresLogin != true {
            throw SubscriptionError("Sign out or switch away from ChatGPT before replacing its active login.")
        }
    }

    func perform(_ request: [String: Any], ownsLease: Bool = false,
                 checkpoint: () throws -> Void = {}) async -> [String: Any] {
        do {
            let allowed: Set<String> = ["action", "pending", "model", "effort", "activate", "generation"]
            guard Set(request.keys).isSubset(of: allowed), let action = request["action"] as? String else {
                throw SubscriptionError("Invalid subscription setup request")
            }
            let fields: Set<String>
            switch action {
            case "status", "start", "logout": fields = ["action"]
            case "poll", "cancel": fields = ["action", "pending"]
            case "probe": fields = ["action", "model", "effort", "generation"]
            case "select": fields = ["action", "model", "effort", "generation", "activate"]
            default: throw SubscriptionError("Unknown subscription action")
            }
            guard Set(request.keys).isSubset(of: fields) else { throw SubscriptionError("Unexpected subscription fields") }
            for key in ["model", "effort", "generation", "pending"] where request[key] != nil {
                guard let text = request[key] as? String, !text.isEmpty, text.count <= 200,
                      !text.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else {
                    throw SubscriptionError("Invalid subscription field: \(key)")
                }
            }
            if let value = request["activate"] {
                guard let n = value as? NSNumber, String(cString: n.objCType) == "c" else { throw SubscriptionError("activate must be a Boolean") }
            }
            try checkpoint(); try Task.checkCancellation()
            let store = login.store
            if action == "status" {
                let state = try store.read()
                let usable = state?.credential != nil && state?.requiresLogin != true
                return ok(["state": usable ? "signed_in" : state?.requiresLogin == true ? "login_required" : "signed_out",
                           "pending": state?.pendingLogin != nil, "quota": "unknown",
                           "generation": usable ? state!.generation : "",
                           "model": ProviderProfiles.configuredModel(.chatgpt) ?? "gpt-5.6-luna",
                           "effort": ProviderProfiles.configuredEffort(.chatgpt) ?? "high"])
            }
            try IdentityMigration.gateMutatingEntry()
            if action == "start" {
                try Self.checkLoginReplacement()
                // Publish an inert pending ID before suspending: a wipe/cancel
                // during the network exchange must prevent later publication.
                let pending = try await store.locked {
                    try checkpoint(); try Task.checkCancellation()
                    var state = try store.read() ?? SubscriptionAuthState(generation: UUID().uuidString)
                    let id = UUID().uuidString
                    state.pendingLogin = id; state.deviceChallenge = nil
                    try store.write(state); return id
                }
                do {
                let (data, status) = try await login.post("/api/accounts/deviceauth/usercode", ["client_id": SubscriptionEndpoint.clientID], false)
                try checkpoint(); try Task.checkCancellation()
                guard status == 200 else { throw SubscriptionError("Device login unavailable. Enable device login in ChatGPT security settings, or use terminal browser login.") }
                let o = try SubscriptionLogin.object(data)
                guard let device = o["device_auth_id"] as? String, let code = o["user_code"] as? String,
                      let interval = Double(String(describing: o["interval"] ?? "5")) else { throw SubscriptionError("Invalid device authorization response") }
                let challenge = SubscriptionDeviceChallenge(deviceID: device, userCode: code,
                    expires: Date().addingTimeInterval(900), nextPoll: Date().addingTimeInterval(interval), interval: interval)
                guard challenge.valid else { throw SubscriptionError("Invalid device authorization response") }
                return try await store.locked {
                    try checkpoint(); try Task.checkCancellation()
                    guard var state = try store.read(), state.pendingLogin == pending else { throw SubscriptionError("Login cancelled or superseded") }
                    state.deviceChallenge = challenge
                    try store.write(state)
                    return ok(["state": "pending", "pending": pending, "url": SubscriptionEndpoint.verificationURL,
                               "code": code, "interval": interval, "expires_in": 900])
                }
                } catch {
                    try? await store.cancelLogin(pending)
                    throw error
                }
            }
            if action == "poll" || action == "cancel" {
                guard let pending = request["pending"] as? String else { throw SubscriptionError("Missing login handle") }
                return try await store.locked {
                    try checkpoint(); try Task.checkCancellation()
                    guard var state = try store.read(), state.pendingLogin == pending else {
                        throw SubscriptionError("Login cancelled or superseded; start again")
                    }
                    if action == "cancel" {
                        state.pendingLogin = nil; state.deviceChallenge = nil
                        try store.write(state); return ok(["state": "cancelled"])
                    }
                    guard var challenge = state.deviceChallenge else { throw SubscriptionError("Login belongs to another interface") }
                    if Date() >= challenge.expires {
                        state.pendingLogin = nil; state.deviceChallenge = nil; try store.write(state)
                        throw SubscriptionError("Device login expired; start again")
                    }
                    if Date() < challenge.nextPoll { return ok(["state": "pending", "interval": challenge.interval]) }
                    let (data, status) = try await login.post("/api/accounts/deviceauth/token",
                        ["device_auth_id": challenge.deviceID, "user_code": challenge.userCode], false)
                    try checkpoint(); try Task.checkCancellation()
                    if status == 200 {
                        let o = try SubscriptionLogin.object(data)
                        guard let code = o["authorization_code"] as? String, let verifier = o["code_verifier"] as? String else {
                            throw SubscriptionError("Device login omitted authorization fields")
                        }
                        let (tokens, tokenStatus) = try await login.post("/oauth/token", ["grant_type": "authorization_code", "code": code,
                            "code_verifier": verifier, "client_id": SubscriptionEndpoint.clientID, "redirect_uri": SubscriptionEndpoint.deviceCallback], true)
                        try checkpoint(); try Task.checkCancellation()
                        guard tokenStatus == 200 else { throw SubscriptionError("Device token exchange failed") }
                        state.credential = try SubscriptionLogin.token(tokens)
                        state.generation = UUID().uuidString; state.requiresLogin = nil
                        state.pendingLogin = nil; state.deviceChallenge = nil
                        try store.write(state)
                        return ok(["state": "signed_in"])
                    }
                    let reason = (try? SubscriptionLogin.object(data)["error"] as? String) ?? ""
                    if ["access_denied", "expired_token"].contains(reason) {
                        state.pendingLogin = nil; state.deviceChallenge = nil; try store.write(state)
                        throw SubscriptionError("Device login denied or expired")
                    }
                    guard [403, 404, 429].contains(status) || ["authorization_pending", "slow_down"].contains(reason) else {
                        throw SubscriptionError("Device authorization request failed")
                    }
                    if status == 429 || reason == "slow_down" { challenge.interval = min(900, challenge.interval + 5) }
                    challenge.nextPoll = Date().addingTimeInterval(challenge.interval)
                    state.deviceChallenge = challenge; try store.write(state)
                    return ok(["state": "pending", "interval": challenge.interval])
                }
            }
            if action == "logout" { try await store.logout(checkpoint: checkpoint); return ok(["state": "signed_out"]) }
            guard action == "select" || action == "probe" else { throw SubscriptionError("Unknown subscription action") }
            let model = request["model"] as? String ?? ProviderProfiles.configuredModel(.chatgpt) ?? "gpt-5.6-luna"
            let effort = request["effort"] as? String ?? ProviderProfiles.configuredEffort(.chatgpt) ?? "high"
            guard !model.isEmpty, ResponsesAdapter.allowedEfforts(model: model).contains(effort) else { throw SubscriptionError("Unsupported model/effort") }
            guard let state = try store.read(), state.credential != nil, state.requiresLogin != true else { throw SubscriptionError("Sign in first") }
            if let expected = request["generation"] as? String, expected != state.generation { throw SubscriptionError("Login changed; verify again") }
            if action == "probe" {
                var context = ProviderExecutionContext.responsesAPI(baseURL: SubscriptionEndpoint.inference,
                    key: state.generation, model: model, lane: .probe(UUID()), effort: ResponsesAdapter.probeEffort(model: model))
                context.profileIdentity = "chatgpt"; context.subscriptionGeneration = state.generation; context.nativeToolMedia = false
                _ = try await ResponsesAuxiliary.text(context: context, messages: [("user", "Reply OK.")], maxOutputTokens: 2048)
                try checkpoint(); try Task.checkCancellation(); try store.validate(generation: state.generation)
                return ok(["state": "verified", "generation": state.generation])
            }
            var lease: InstanceLease?
            if !ownsLease {
                switch InstanceLease.acquire(label: "ChatGPT setup selection") {
                case .success(let held): lease = held
                case .failure: throw SubscriptionError("Stop Briglia before selecting this provider, then restart it after saving. From Telegram use /provider chatgpt while idle.")
                }
            }
            defer { lease?.release() }
            return try await store.locked {
                try checkpoint(); try Task.checkCancellation(); try store.validate(generation: state.generation)
                try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: model, effort: effort, textOnly: false)
                if request["activate"] as? Bool != false { try ProviderProfiles.activate(.chatgpt) }
                return ok(["state": "signed_in", "model": model, "effort": effort])
            }
        } catch {
            return ["schema": SetupAPICore.schemaVersion, "ok": false,
                    "error": ["code": "subscription", "message": error.localizedDescription]]
        }
    }
    private func ok(_ payload: [String: Any]) -> [String: Any] {
        payload.merging(["schema": SetupAPICore.schemaVersion, "ok": true]) { _, new in new }
    }
}
