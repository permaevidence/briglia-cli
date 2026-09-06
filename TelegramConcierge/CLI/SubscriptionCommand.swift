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

    func run() async throws {
        AdaCLI.prepareIO()
        let store = SubscriptionAuthStore()
        switch action {
        case "status":
            if let state = try store.read(), state.credential != nil, state.requiresLogin != true {
                print("ChatGPT subscription: signed in. Account scope: " + String(ResponsesReplayEnvelope.hash(Data(state.credential!.account.utf8)).prefix(12)))
                print("Billing: subscription. Quota: unknown (not unlimited). API tools keep their separate configuration.")
            } else { print("ChatGPT subscription: signed out") }
        case "models":
            print("Known compatibility candidates (not live entitlement discovery): gpt-5.6-luna, gpt-5.6-terra, gpt-5.6-sol, gpt-6-astra. Availability is verified by requests; catalog freshness is unknown.")
        case "login", "select", "cancel", "logout":
            try IdentityMigration.gateMutatingEntry()
            // Profile changes need daemon exclusion. Logout may invalidate an
            // active session; each queued dispatch checks its captured generation.
            let model = model ?? ProviderProfiles.configuredModel(.chatgpt) ?? "gpt-5.6-luna"
            let effort = effort ?? ProviderProfiles.configuredEffort(.chatgpt) ?? "high"
            if action == "login" || action == "select" {
                guard ResponsesAdapter.allowedEfforts(model: model).contains(effort) else { throw ValidationError("Unsupported reasoning effort") }
            }
            var lease: InstanceLease?
            if action == "select" || activate || (action == "login" && ProviderProfiles.activeProfile() == .chatgpt) {
                switch InstanceLease.acquire(label: "ChatGPT subscription selection") {
                case .success(let held): lease = held
                case .failure: throw ValidationError("Stop Briglia before activating a subscription profile; login without --activate can run separately.")
                }
            }
            defer { lease?.release() }
            if action == "cancel" {
                if let pending = try store.read()?.pendingLogin { try await store.cancelLogin(pending) }
                print("Pending ChatGPT login cancelled; existing credentials preserved.")
                return
            }
            if action == "logout" {
                try await store.logout()
                print("ChatGPT signed out locally. Saved history remains; queued requests cannot reuse this login.")
                return
            }
            if action == "login" {
                let login = SubscriptionLogin()
                if browser {
                    _ = try await login.browser { print("Open this login link on this computer (expires in 5 minutes):\n" + $0) }
                } else {
                    _ = try await login.device { print("Open " + $0 + " and enter code: " + $1 + "\nWaiting for your authorization (15 minutes maximum).") }
                }
                print("ChatGPT login saved. No API key was changed.")
            }
            // Saving never implicitly activates. A stopped daemon can be selected
            // here; a running daemon uses its existing /provider idle guard.
            try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: model, effort: effort, textOnly: false)
            if activate || action == "select" || (lease != nil && ProviderProfiles.activeProfile() == .chatgpt) { try ProviderProfiles.activate(.chatgpt); print("ChatGPT subscription selected.") }
            else { print("Use /provider chatgpt while idle, or briglia subscription select while stopped.") }
        default: throw ValidationError("Use login, status, select, cancel, logout, or models")
        }
    }
}
