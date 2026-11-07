import ArgumentParser
import Foundation

struct SubscriptionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "subscription",
        abstract: "Connect your own ChatGPT subscription. API credentials and billing stay separate.")
    @Argument(help: "login, status, select, cancel, logout, or models") var action: String = "status"
    @Flag(help: "Use a local browser callback instead of device login") var browser = false
    @Option(help: "Model to save; availability depends on your subscription") var model: String?
    @Option(help: "Reasoning effort") var effort: String?
    @Flag(help: "Activate after login (requires stopped Briglia)") var activate = false
    @Flag(name: .customLong("accept-pending"), help: "If Briglia is busy, save the change and apply it when it is idle") var acceptPending = false
    /// Sign in with ChatGPT during the opt-in release (SIWC plan §3.10).
    @Flag(name: .customLong("official"), help: .hidden) var official = false
    /// The legacy Codex sign-in explicitly (when Sign in with ChatGPT is in use).
    @Flag(name: .customLong("legacy"), help: .hidden) var legacyRoute = false
    @Argument(help: .hidden) var scopeValue: String?
    var scopeArgument: SubscriptionSharing.Scope? { scopeValue.flatMap(SubscriptionSharing.Scope.init(rawValue:)) }

    func run() async throws {
        AdaCLI.prepareIO()
        let store = SubscriptionAuthStore()
        if try await runSIWCIfChosen() { return }
        switch action {
        case "status":
            if let state = try store.read(), state.credential != nil, state.requiresLogin != true {
                print("ChatGPT subscription: signed in. Account scope: " + String(ResponsesReplayEnvelope.hash(Data(state.credential!.account.utf8)).prefix(12)))
                print("Billing: subscription. Quota: unknown (not unlimited). API tools keep their separate configuration.")
            } else { print("ChatGPT subscription: signed out") }
        case "models":
            print("Known compatibility candidates (not live entitlement discovery): \(ResponsesAdapter.subscriptionModelChoices.map(\.id).joined(separator: ", ")). Availability is verified by requests; catalog freshness is unknown.")
        case "scope":
            // `briglia --profile <n> subscription scope [shared|own]` (§25.7).
            guard let target = scopeArgument else {
                print("ChatGPT: " + (SubscriptionSharing.scope() == .own ? "this assistant's own login" : "the shared login"))
                if let s = SubscriptionSharing.sharingSentence() { print(s) }
                return
            }
            try IdentityMigration.gateMutatingEntry()
            // The intake stop across processes (S3-R15-1 audit): the login
            // scope is replaced by a wipe/import too.
            let scopeLock: ProfileFileLock?
            switch MemoryReplacementLock.shared(waitSeconds: MemoryReplacementLock.standaloneWaitSeconds) {
            case .admitted(let lock): scopeLock = lock
            case .busy: print("✖ " + MemoryReplacementLock.busyMessage); throw ExitCode(75)
            case .failed(let why): print("✖ \(why)"); throw ExitCode(1)
            }
            defer { scopeLock?.release() }
            // The scope change is a short commit of this process (plan B.6):
            // it holds the instance lease for its local work only.
            let lease: InstanceLease
            switch await InstanceLease.acquire(label: "settings-commit", waitSeconds: 2) {
            case .success(let held): lease = held
            case .failure: print("✖ Stop this assistant before changing its ChatGPT login."); throw ExitCode(1)
            }
            defer { lease.release() }
            do { try SettingsRecovery.run() } catch { print("✖ \(error)"); throw ExitCode(1) }
            do { print(try await SubscriptionSharing.changeScope(to: target)) } catch {
                print("✖ \(error.localizedDescription)"); throw ExitCode(1)
            }
        case "login", "select", "cancel", "logout":
            try IdentityMigration.gateMutatingEntry()
            // KEYLESS_WEB_AND_LIVE_MENU plan B.6: the network/device flow runs
            // first, outside any lock; every local mutation — the login's
            // publication, select, cancel, logout — is one prepared change
            // committed by the settings writer (forwarded to a running
            // Briglia, or under a short instance lease). A route change while
            // Briglia is busy is refused (`--accept-pending` stages it).
            switch MemoryReplacementLock.shared(waitSeconds: MemoryReplacementLock.standaloneWaitSeconds) {
            case .admitted(let lock): lock.release()
            case .busy: print("✖ " + MemoryReplacementLock.busyMessage); throw ExitCode(75)
            case .failed(let why): print("✖ \(why)"); throw ExitCode(1)
            }
            let model = model ?? ProviderProfiles.configuredModel(.chatgpt) ?? ResponsesAdapter.subscriptionDefaultModel
            let effort = effort ?? ProviderProfiles.configuredEffort(.chatgpt) ?? "high"
            if action == "login" || action == "select" {
                guard ResponsesAdapter.allowedEfforts(model: model).contains(effort) else { throw ValidationError("Unsupported reasoning effort") }
            }
            func commit(_ label: String, _ body: () async throws -> Void) async throws -> SettingsCommitResult? {
                let (change, _) = try await SettingsCapture.prepareThrowing(origin: "subscription", label: label,
                                                                           acceptPending: acceptPending) { try await body() }
                guard !change.isNoop else { return nil }
                return await SettingsClient.commit(change)
            }
            func report(_ result: SettingsCommitResult?, done: String) throws {
                guard let result else { print(done); return }
                switch result.state {
                case .applied: print(done)
                case .pending: print("Saved. Briglia is busy, so this applies when it finishes its current task.")
                case .busy: print("✖ Briglia is busy with a task and this changes what it uses. Try again when it is idle, or add --accept-pending."); throw ExitCode(75)
                default: print("✖ \(result.message ?? "not saved")"); throw ExitCode(1)
                }
            }
            if action == "cancel" {
                var outcome: SubscriptionAuthStore.OwnedCancel = .none
                let result = try await commit("ChatGPT login cancel") { outcome = try await store.cancelOwnedPending() }
                if outcome == .foreign { print(SubscriptionSharing.foreignPendingMessage); return }
                try report(result, done: "Pending ChatGPT login cancelled; existing credentials preserved.")
                return
            }
            if action == "logout" {
                if let sentence = SubscriptionSharing.sharingSentence(signOut: true) { print(sentence) }
                let result = try await commit("ChatGPT sign-out") { try await store.logout() }
                try report(result, done: "ChatGPT signed out locally. Saved history remains; queued requests cannot reuse this login.")
                return
            }
            if action == "login" {
                if let sentence = SubscriptionSharing.sharingSentence() { print(sentence) }
                // The publication is prepared inside the login's final step
                // and committed right after the network flow ends.
                var login = SubscriptionLogin()
                let box = PublishBox()
                login.commitHook = { direct in
                    let (change, generation) = try await SettingsCapture.prepareThrowing(origin: "subscription", label: "ChatGPT sign-in",
                                                                                        acceptPending: acceptPending) { try await direct(nil) }
                    box.change = change
                    return generation
                }
                if browser {
                    _ = try await login.browser { print("Open this login link on this computer (expires in 5 minutes):\n" + $0) }
                } else {
                    _ = try await login.device { print("Open " + $0 + " and enter code: " + $1 + "\nWaiting for your authorization (15 minutes maximum).") }
                }
                if let change = box.change {
                    try report(await SettingsClient.commit(change), done: "ChatGPT login saved. No API key was changed.")
                }
            }
            // Saving never implicitly activates, except when ChatGPT is
            // already the active lane (the new login takes effect) or asked.
            let activates = activate || action == "select" || ProviderProfiles.activeProfile() == .chatgpt
            let result = try await commit(activates ? "ChatGPT selection" : "ChatGPT model") {
                try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: model, effort: effort, textOnly: false)
                if activates { try ProviderProfiles.activate(.chatgpt) }
            }
            try report(result, done: activates ? "ChatGPT subscription selected." : "Use /provider chatgpt while idle, or briglia subscription select.")
        default: throw ValidationError("Use login, status, select, cancel, logout, or models")
        }
    }
}

extension SubscriptionCommand {
    /// Sign in with ChatGPT: `--official`, or this assistant already on that
    /// route / opted in (never with `--legacy`). True = handled.
    func runSIWCIfChosen() async throws -> Bool {
        guard !legacyRoute, ["login", "logout", "cancel", "failed", "use", "status"].contains(action) else { return false }
        let stored = KeychainHelper.loadSnapshot()
        let onRoute = SIWCSurface.route(stored) == "siwc"
        let chosen: Bool
        switch action {
        case "login": chosen = official || SIWCSurface.optedIn(stored)
        case "logout": chosen = official || onRoute
        case "status": chosen = official || SIWCSurface.optedIn(stored)
        default: chosen = official || action == "use" || action == "failed"
        }
        guard chosen else { return false }
        if action != "status" {
            try IdentityMigration.gateMutatingEntry()
            switch MemoryReplacementLock.shared(waitSeconds: MemoryReplacementLock.standaloneWaitSeconds) {
            case .admitted(let lock): lock.release()
            case .busy: print("✖ " + MemoryReplacementLock.busyMessage); throw ExitCode(75)
            case .failed(let why): print("✖ \(why)"); throw ExitCode(1)
            }
        }
        let code: Int32 = action == "login" ? await SIWCTerminal.login() : await SIWCTerminal.simple(action)
        if action == "status" {
            let legacy = try? store().read()
            print("\(SIWCSurface.legacyLabel): " + (legacy?.credential == nil ? "signed out" : "signed in"))
        }
        if code != 0 { throw ExitCode(code) }
        return true
    }

    private func store() -> SubscriptionAuthStore { SubscriptionAuthStore() }
}

/// The sign-in's prepared publication, handed out of the login hook.
private final class PublishBox: @unchecked Sendable { var change: PreparedChange? }
