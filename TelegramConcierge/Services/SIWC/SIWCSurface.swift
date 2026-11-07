import Foundation

// What every user surface says about Sign in with ChatGPT (SIWC plan §3.10,
// §5, §5.1, D2): labels, the opt-in during the opt-in release, the one-time
// invitation for legacy ChatGPT users, /status and doctor lines, and the
// sign-out entry every surface shares. Nothing here prints a token, the
// host ID or an email address.

enum SIWCSurface {
    static let label = "ChatGPT (Sign in with ChatGPT)"
    static let legacyLabel = "ChatGPT (legacy Codex sign-in)"
    static let chooseMethodLabel = "Choose sign-in method"
    static let continueLabel = "Continue with ChatGPT"
    static let manageUsageURL = "https://chatgpt.com/settings/usage"

    /// Per assistant (`other` role): the user chose to try Sign in with
    /// ChatGPT during the opt-in release (the menu's "Choose sign-in method",
    /// the hidden `--official` / `official` commands, setup-api `siwc_start`).
    static let optInKey = "subscription_siwc_optin"
    /// Per assistant (`other`): the one-time Telegram invitation was sent.
    static let invitedKey = "subscription_siwc_invited"
    static let invitationText = "Use your ChatGPT plan in this app · Continue with ChatGPT"

    /// Opted in, or already on the SIWC route (every UI honours the same
    /// state during the opt-in release, D2).
    static func optedIn(_ stored: [String: String] = KeychainHelper.loadSnapshot()) -> Bool {
        stored[optInKey] == "1" || stored[ChatGPTRoute.routeKey] == "siwc"
    }

    /// The route of THIS assistant's ChatGPT selection ("siwc" | "legacy"),
    /// nil when ChatGPT is not the selected provider.
    static func route(_ stored: [String: String] = KeychainHelper.loadSnapshot()) -> String? {
        switch ChatGPTRoute.resolve(stored: stored) {
        case .notChatGPT: return nil
        case .legacy: return "legacy"
        case .siwc, .ambiguous, .disabled: return "siwc"
        }
    }

    static func legacyLoginPresent() -> Bool {
        guard let state = try? SubscriptionAuthStore().read() else { return false }
        return state.credential != nil && state.requiresLogin != true
    }

    /// D2: ChatGPT on the legacy route, opted in, not yet on SIWC.
    static func invitation(_ stored: [String: String] = KeychainHelper.loadSnapshot()) -> String? {
        guard ChatGPTRoute.resolve(stored: stored) == .legacy, stored[optInKey] == "1" else { return nil }
        return invitationText
    }

    // MARK: State of this assistant's SIWC login

    struct Info: Equatable {
        /// signed_in | sign_in_required | plan_usage_off | invalid_client | signed_out | ambiguous | disabled | none
        var login = "none"
        var selected = false
        var planState: SIWCPlanEntry.State? = nil
        var planReason: String? = nil
        var registrations = 0
        var pendingSignIn = false
        var twoEntriesNote = false
    }

    static func info(stored: [String: String] = KeychainHelper.loadSnapshot(), store: SIWCStore = SIWCStore.resolved()) -> Info {
        var out = Info()
        let resolved = ChatGPTRoute.resolve(stored: stored)
        if case .ambiguous = resolved { out.login = "ambiguous"; out.selected = true; return out }
        if case .disabled = resolved { out.login = "disabled"; out.selected = true; return out }
        if case .siwc = resolved { out.selected = true }
        let tokens = try? store.readTokens(), registrations = try? store.readRegistrations()
        out.registrations = registrations?.registrations.count ?? 0
        out.pendingSignIn = (tokens?.pendingLogin != nil) && (tokens?.pendingExpiresAt ?? 0) > Int(Date().timeIntervalSince1970)
        let clientId = registrations?.active
        guard let clientId, let registration = registrations?.registration(clientId) else {
            out.login = out.registrations > 0 ? "signed_out" : "none"
            return out
        }
        let key = try? store.integrityKey(create: false)
        switch store.usability(tokens?.record(clientId), registration: registration, key: key) {
        case .usable: out.login = "signed_in"
        case .planUsageOff: out.login = "plan_usage_off"
        case .invalidClient: out.login = "invalid_client"
        case .signInRequired(let why): out.login = why == "signed out" || why == "no record" ? "signed_out" : "sign_in_required"
        }
        if let entry = SIWCPlanState.entry(store, clientId: clientId) {
            out.planState = entry.state; out.planReason = entry.reason
            if entry.state == .signInRequired, out.login == "signed_in" { out.login = "sign_in_required" }
        } else if out.selected { out.planState = .ok }
        // D22: one account, two Briglia entries (an own login on the account
        // the shared login also uses).
        if CoordinationMode.multi, SubscriptionSharing.scope() == .own,
           let machine = try? SIWCStore(directory: MachinePaths.defaultConfigRoot()).readRegistrations(),
           machine.registrations.contains(where: { $0.sub == registration.sub && $0.clientId != clientId }) {
            out.twoEntriesNote = true
        }
        return out
    }

    static let twoEntriesMessage = "This account now has two Briglia entries in ChatGPT Settings → Usage, one per login."

    static func loginText(_ login: String) -> String {
        switch login {
        case "signed_in": return "signed in"
        case "sign_in_required": return "sign in again"
        case "plan_usage_off": return "signed in without plan usage (sign in again and allow it)"
        case "invalid_client": return "registration broken (register Briglia again)"
        case "signed_out": return "signed out"
        case "ambiguous": return "choose ChatGPT again"
        case "disabled": return "disabled in this build"
        default: return "not signed in"
        }
    }

    /// /status lines (no tokens, no host ID, no email).
    static func statusLines(stored: [String: String] = KeychainHelper.loadSnapshot(), store: SIWCStore = SIWCStore.resolved(),
                            waiting: Bool = false) -> [String] {
        var lines: [String] = []
        if let invite = invitation(stored) { lines.append("💡 " + invite + " (/subscription login)") }
        let info = info(stored: stored, store: store)
        if info.selected {
            switch info.login {
            case "ambiguous": lines.append("ChatGPT: " + ChatGPTRoute.chooseAgainMessage)
            case "disabled": lines.append("ChatGPT: " + SIWCEndpoint.disabledMessage)
            default:
                lines.append("ChatGPT route: \(label) — \(loginText(info.login))")
                if info.login == "signed_in", let state = info.planState {
                    var entry = SIWCPlanEntry(); entry.state = state; entry.reason = info.planReason
                    lines.append(SIWCPlanState.statusText(entry))
                }
            }
            if let scope = SubscriptionSharing.scopeStatus() { lines.append("ChatGPT login: " + scope) }
            if info.twoEntriesNote { lines.append(twoEntriesMessage) }
        } else if info.login != "none", optedIn(stored) {
            lines.append("Sign in with ChatGPT: \(loginText(info.login)) (not in use)")
        }
        if waiting || info.pendingSignIn { lines.append("ChatGPT sign-in waiting for you.") }
        return lines
    }

    // MARK: Doctor (§3.10)

    struct DoctorLine: Equatable { var problem: Bool; var text: String; var hint: String? }

    /// Both SIWC files of every protected store (owner-only, readable,
    /// integrity status), and the host file's consistency with every
    /// registration. Never prints tokens, the host ID or an email.
    static func doctorLines(storeDirectories: [URL] = SubscriptionSharing.protectedStoreDirectories(),
                            hostPaths: SIWCHost.Paths = .live) -> [DoctorLine] {
        var out: [DoctorLine] = []
        var anyRegistration = false
        var seen = Set<String>()
        for dir in storeDirectories where seen.insert(dir.standardizedFileURL.path).inserted {
            let store = SIWCStore(directory: dir)
            let names = [SIWCEndpoint.tokenFileName, SIWCEndpoint.registrationsFileName]
            let present = names.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
            guard !present.isEmpty else { continue }
            let where_ = dir.path == MachinePaths.defaultConfigRoot().path ? "shared store" : "own store (\(dir.lastPathComponent))"
            for name in present {
                let url = dir.appendingPathComponent(name)
                var info = stat()
                let ok = lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_mode & 0o077 == 0
                if !ok { out.append(DoctorLine(problem: true, text: "Sign in with ChatGPT \(where_): \(name) is not an owner-only file",
                                               hint: "chmod 600 it, or sign out and sign in again")) }
            }
            let tokens: SIWCTokenFile?, registrations: SIWCRegistrationsFile?
            do { tokens = try store.readTokens(); registrations = try store.readRegistrations() } catch {
                out.append(DoctorLine(problem: true, text: "Sign in with ChatGPT \(where_): files unreadable",
                                      hint: "sign out and sign in again from briglia menu")); continue
            }
            let key = try? store.integrityKey(create: false)
            for registration in registrations?.registrations ?? [] {
                anyRegistration = true
                let label = registration.clientId == registrations?.active ? "active login" : "saved login"
                let state: String
                switch store.usability(tokens?.record(registration.clientId), registration: registration, key: key) {
                case .usable: state = "usable"
                case .planUsageOff: state = "no plan usage"
                case .invalidClient: state = "registration broken"
                case .signInRequired(let why): state = why == "signed out" || why == "no record" ? "signed out" : "sign-in required"
                }
                let plan = SIWCPlanState.entry(store, clientId: registration.clientId)?.state ?? .ok
                let problem = state == "sign-in required" || state == "registration broken" || (label == "active login" && plan != .ok)
                out.append(DoctorLine(problem: problem, text: "Sign in with ChatGPT \(where_), \(label): \(state); plan \(plan.rawValue)",
                                      hint: problem ? "sign in again: /subscription login or briglia menu" : nil))
            }
        }
        switch SIWCHost.readHost(hostPaths) {
        case .absent:
            if anyRegistration { out.append(DoctorLine(problem: true, text: "Sign in with ChatGPT: this computer's app ID is missing while logins exist",
                                                       hint: "Briglia refuses new sign-ins until it is restored; sign out everywhere to reset")) }
        case .unreadable:
            out.append(DoctorLine(problem: true, text: "Sign in with ChatGPT: this computer's app ID is unreadable", hint: "check the file's permissions"))
        case .present(let id):
            guard let fingerprints = SIWCHost.registrationHostFingerprints(hostPaths) else {
                out.append(DoctorLine(problem: true, text: "Sign in with ChatGPT: a login store can't be read", hint: nil)); break
            }
            let current = SIWCHost.fingerprint(id)
            let consistent = fingerprints.allSatisfy { $0 == current }
            out.append(DoctorLine(problem: !consistent, text: consistent ? "Sign in with ChatGPT: computer app ID consistent with \(fingerprints.count) login\(fingerprints.count == 1 ? "" : "s")"
                                                                     : "Sign in with ChatGPT: computer app ID disagrees with a saved login",
                                  hint: consistent ? nil : "sign out of that login and sign in again"))
        }
        return out
    }

    // MARK: Opt-in and invitation writes (immediate: `other` role)

    @MainActor
    static func setOptIn(_ on: Bool, origin: String) async -> SettingsCommitResult {
        await writeOther(origin: origin, label: "Sign in with ChatGPT preview") {
            if on { try KeychainHelper.save(key: optInKey, value: "1") } else { try KeychainHelper.delete(key: optInKey) }
        }
    }

    @MainActor
    static func markInvited(origin: String) async {
        _ = await writeOther(origin: origin, label: "Sign in with ChatGPT invitation") { try KeychainHelper.save(key: invitedKey, value: "1") }
    }

    @MainActor
    private static func writeOther(origin: String, label: String, _ body: @escaping () throws -> Void) async -> SettingsCommitResult {
        do {
            let (change, _) = try await SettingsCapture.prepareThrowing(origin: origin, label: label) { try body() }
            if change.isNoop { return SettingsCommitResult(state: .applied, message: nil) }
            return await SettingsClient.commit(change)
        } catch { return .refused(error.localizedDescription) }
    }

    // MARK: Sign-out (every surface)

    /// The interrupting SIWC sign-out of this assistant's store (§3.6, §3.9
    /// R2): sharing sentence before and after, the stopped-work line, the
    /// several-assistants line. Runs in the writer of this process (the
    /// daemon, or a short offline commit when none runs).
    @MainActor
    static func logout(store: SIWCStore = SIWCStore.resolved(), writer: SIWCWriterAccess = .live) async -> (ok: Bool, message: String) {
        guard let registrations = try? store.readRegistrations(), registrations.active != nil else {
            return (false, "Not signed in with Sign in with ChatGPT.")
        }
        let sentence = SubscriptionSharing.sharingSentence(signOut: true)
        var outcome: SIWCLogoutOutcome = .refused("Nothing changed.")
        var stopped = 0
        if let refusal = await writer.run({ w in
            outcome = await w.commitSIWCLogout(store: store, revoke: { tombstone in
                SIWCActivity.shared.beginRevoke(); defer { SIWCActivity.shared.endRevoke() }
                return await SIWCSignIn(store: store).revokeAll(tombstone)
            })
            stopped = w.lastLogoutStoppedJobs
        }) { return (false, refusal) }
        var parts = [outcome.message]
        if stopped > 0 { parts.append(SIWCLogoutOutcome.stoppedJobsMessage) }
        if case .signedOut = outcome {
            if CoordinationMode.multi, sentence != nil { parts.append(SIWCLogoutOutcome.othersMessage) }
            if let sentence { parts.append(sentence) }
            return (true, parts.joined(separator: " "))
        }
        return (false, parts.joined(separator: " "))
    }
}
