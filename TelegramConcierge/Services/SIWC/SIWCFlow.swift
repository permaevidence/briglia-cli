import Foundation

// The Sign in with ChatGPT sign-in session of THIS process (SIWC plan §3.2,
// §3.4, §3.10, stage D). The process that owns the attempt owns its PKCE
// verifier, its 127.0.0.1 listener and its paste-back: the running daemon
// when there is one (the menu's live hub, Telegram, and forwarded terminal
// and setup-api requests), otherwise the menu / terminal / setup-api process
// itself, which publishes through a short offline commit.
//
// The flow: start (pending marker, host reservation, listener on an
// OS-chosen port) → the user signs in (browser callback, or a pasted
// address) → exchange + ID-token check → `commitSIWCSave` (route-neutral) →
// a FRESHLY prepared activation through the one settings writer (D: now when
// idle, staged when busy). No hints are ever put in the authorize link.

/// Where the settings writer of this process is (daemon or a short offline
/// lease). Save, cancel and sign-out are writer entry points that are never
/// a `PreparedChange`, so they cannot be forwarded as one.
@MainActor
struct SIWCWriterAccess {
    var run: (_ body: (SettingsWriter) async -> Void) async -> String?

    /// The daemon's writer, or the offline owner under a short lease. A
    /// daemon that started during the sign-in wait makes the short lease
    /// fail: the save is refused (nothing written, tokens revoked best
    /// effort) and the user signs in again in the running Briglia.
    static let live = SIWCWriterAccess(run: { body in
        if let writer = SettingsClient.inProcessWriter { await body(writer); return nil }
        await OfflineCommitQueue.acquire()
        defer { OfflineCommitQueue.release() }
        func local() async -> String? {
            do { try SettingsRecovery.run() } catch { return "The waiting settings changes can't be read (\(error)); nothing was saved." }
            let installed = KeychainHelper.writeObserver == nil
            if installed { SettingsSupersede.install() }
            defer { if installed { SettingsSupersede.uninstall() } }
            await body(OfflineOwner.writer)
            return nil
        }
        if InstanceLease.isHeldInThisProcess { return await local() }
        let replacement: ProfileFileLock?
        switch MemoryReplacementLock.shared(waitSeconds: MemoryReplacementLock.standaloneWaitSeconds) {
        case .admitted(let lock): replacement = lock
        case .busy: return MemoryReplacementLock.busyMessage
        case .failed(let why): return why
        }
        defer { replacement?.release() }
        switch await InstanceLease.acquire(label: "settings-commit", waitSeconds: 2) {
        case .success(let lease):
            defer { lease.release() }
            return await local()
        case .failure:
            return SIWCFlow.ownerChangedMessage
        }
    })
}

@MainActor
final class SIWCFlow {
    static let shared = SIWCFlow()
    init() {}

    enum Mode: String { case browser, paste }

    /// What every surface shows. `message` is always a fixed string.
    struct Status: Equatable {
        /// idle | waiting | finishing | done | failed | cancelled
        var state = "idle"
        var mode: Mode? = nil
        var url: String? = nil
        var expiresAt: Int? = nil
        var message: String? = nil
        /// signed_in | pending | saved | plan_usage_off | browser_error | browser_failed | expired | refused | error
        var outcome: String? = nil
        /// First sign-in with plan usage (§3.2 step 10): show "You're using your ChatGPT plan".
        var firstUse = false
        /// A legacy ChatGPT login exists in this store (offer its local sign-out).
        var legacyLoginKept = false
        /// The store's pending sign-in id (not a secret; the verifier never leaves this process).
        var pending: String? = nil

        var json: [String: Any] {
            var out: [String: Any] = ["state": state, "first_use": firstUse]
            if let pending { out["pending"] = pending }
            if let mode { out["mode"] = mode.rawValue }
            if let url { out["url"] = url }
            if let expiresAt { out["expires_at"] = expiresAt }
            if let message { out["message"] = message }
            if let outcome { out["outcome"] = outcome }
            if legacyLoginKept { out["legacy_login_kept"] = true }
            return out
        }
    }

    // MARK: Fixed messages (§2.1, §3.2, §3.4)

    static let ownerChangedMessage = "Briglia started while you were signing in, so this sign-in wasn't saved. Sign in again from the running Briglia (briglia menu or /subscription login)."
    static let alreadyWaitingMessage = "A ChatGPT sign-in is already waiting; finish it or cancel it first."
    static let browserFailedHelp = "If ChatGPT showed an error page, the message there explains why (for example an account or workspace policy). Briglia didn't receive a reason. You can try again, use another account, or choose a different route in settings."
    static let cancelledInBrowser = "Sign-in was cancelled in the browser."
    static let policyDenied = "ChatGPT refused this sign-in because of an account or workspace policy (3p_delegated_access_policy_denied). Briglia hasn't changed anything. You can try another ChatGPT account, ask your workspace admin, or choose a different route in settings."
    static let unrecognizedRefusal = "ChatGPT refused this sign-in (unrecognized reason). Briglia hasn't changed anything."
    static let pasteHint = "Paste the address within about 5 minutes."
    static let cancelledMessage = "ChatGPT sign-in cancelled."
    static let savedNotSwitchedMessage = "Sign-in cancelled. ChatGPT had already returned the login, so it is saved, but Briglia did not switch to it. Use /subscription use or “Use ChatGPT” in briglia menu if you want it."
    static let cancelledElsewhere = "This ChatGPT sign-in was cancelled (a memory operation or a reset stopped it). Start it again."
    static let firstUseNotice = "You're using your ChatGPT plan. Briglia appears in ChatGPT Settings → Usage, where you can set its limit (Manage usage: chatgpt.com/settings/usage). " + SIWCPlanState.creditsNote
    static let telegramCaveat = "The sign-in code passes through Telegram's servers; the menu on the computer (or the phone app) avoids that when you can use it."

    static func refusalMessage(_ recognized: String?) -> String {
        switch recognized {
        case "access_denied": return cancelledInBrowser
        case "3p_delegated_access_policy_denied": return policyDenied
        case let code?: return "ChatGPT refused this sign-in (\(code)). Briglia hasn't changed anything."
        case nil: return unrecognizedRefusal
        }
    }

    // MARK: Seams (selftests)

    var makeSignIn: () -> SIWCSignIn = { SIWCSignIn(store: SIWCStore.resolved()) }
    var writer = SIWCWriterAccess.live
    /// The activation commit; `stillValid` reaches the writer's decision
    /// point (a cancelled or superseded sign-in never activates, Codex D-R2).
    var commitActivation: (PreparedChange, (@Sendable () throws -> Void)?) async -> SettingsCommitResult = {
        await SettingsClient.commit($0, stillValid: $1)
    }
    /// Exchange + ID-token check (stage A); a selftest may answer it.
    var exchange: (SIWCSignIn, SIWCAttempt, String, String) async throws -> SIWCSignInResult = { signIn, attempt, code, clientId in
        try await signIn.exchange(attempt, code: code, clientId: clientId)
    }
    var startListener: Bool = true
    var pollNanos: UInt64 = 200_000_000
    var clock: () -> Int = { Int(Date().timeIntervalSince1970) }

    // MARK: Session

    /// Lock-protected: read at the writer's decision point (any actor).
    final class Validity: @unchecked Sendable {
        private let lock = NSLock()
        private var revoked = false
        func revoke() { lock.lock(); revoked = true; lock.unlock() }
        var isRevoked: Bool { lock.lock(); defer { lock.unlock() }; return revoked }
        func check() throws { if isRevoked { throw SIWCError(.local, SIWCFlow.cancelledMessage) } }
    }

    private final class Session {
        let validity = Validity()
        let id = UUID()
        let attempt: SIWCAttempt
        let signIn: SIWCSignIn
        let listener: SIWCCallbackListener?
        let mode: Mode
        let epoch: Int
        var task: Task<Void, Never>?
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var onFinish: ((Status) -> Void)?
        init(attempt: SIWCAttempt, signIn: SIWCSignIn, listener: SIWCCallbackListener?, mode: Mode, epoch: Int) {
            self.attempt = attempt; self.signIn = signIn; self.listener = listener; self.mode = mode; self.epoch = epoch
        }
    }

    private var session: Session?
    private(set) var status = Status()
    /// The last session that ended had a finish callback (its own result
    /// message), so a paste that ended it needs no second reply.
    private(set) var lastFinishNotified = false
    /// The pending sign-in of this process is still waiting for the user.
    var isWaiting: Bool { session != nil && status.state == "waiting" }

    /// Start a sign-in. `consent` = "enable plan usage" (prompt=consent);
    /// `newRegistration` = "register Briglia again" / another account.
    func start(mode: Mode, consent: Bool = false, newRegistration: Bool = false,
               onFinish: ((Status) -> Void)? = nil) async -> Status {
        if session != nil, ["waiting", "finishing", "cancelling"].contains(status.state) {
            return fail(Self.alreadyWaitingMessage, outcome: "refused", keepSession: true)
        }
        if SIWCEndpoint.disabledByEnvironment() { return fail(SIWCEndpoint.disabledMessage, outcome: "refused") }
        let epoch: Int
        do { epoch = try ReplacementEpoch.read() } catch { return fail("Briglia's settings can't be read; nothing was started.", outcome: "refused") }
        let signIn = makeSignIn()
        // A returning sign-in reuses the store's active registration (unless
        // it is broken, or the user asked for a new one).
        var expected: String? = nil
        if !newRegistration, let target = SIWCSurface.savedTarget(signIn.store),
           (try? signIn.store.readTokens())?.record(target)?.invalidClient != true {
            expected = target
        }
        var listener: SIWCCallbackListener? = nil
        var port = 0
        if startListener {
            let l = SIWCCallbackListener()
            do { port = try await l.start() } catch { return fail("Briglia couldn't open its local sign-in address; nothing was started.", outcome: "refused") }
            listener = l
        } else {
            port = Int.random(in: 49152...65000)
        }
        let attempt: SIWCAttempt
        do { attempt = try await signIn.start(port: port, expectedClientId: expected, consent: consent) } catch {
            await listener?.stop()
            return fail((error as? SIWCError)?.message ?? "\(error)", outcome: "refused")
        }
        await listener?.arm(attempt.expectation)
        let s = Session(attempt: attempt, signIn: signIn, listener: listener, mode: mode, epoch: epoch)
        s.onFinish = onFinish
        session = s
        status = Status(state: "waiting", mode: mode, url: SIWCSignIn.authorizeURL(attempt), expiresAt: attempt.expiresAt,
                        message: mode == .paste ? Self.pasteHint : nil)
        status.pending = attempt.pending
        s.task = Task { @MainActor [weak self] in await self?.watch(s) }
        return status
    }

    /// Poll the listener until a callback, the expiry or a cancel.
    private func watch(_ s: Session) async {
        while !Task.isCancelled, session === s, !s.finished {
            // Cancelled from outside (Mind import / wipe quiescence).
            if !SIWCActivity.shared.has(s.attempt.id) {
                await end(s, state: "cancelled", message: Self.cancelledElsewhere, outcome: "cancelled", cancelAttempt: false)
                return
            }
            if clock() >= s.attempt.expiresAt {
                await end(s, state: "failed", message: CallbackPaste.Rejection.expired.rawValue + " " + Self.browserFailedHelp, outcome: "expired")
                return
            }
            if let outcome = await s.listener?.take() {
                await handle(outcome, s)
                return
            }
            try? await Task.sleep(nanoseconds: pollNanos)
        }
    }

    /// A pasted callback address (Telegram, terminal, setup-api). Returns the
    /// fixed reply; the text itself is never echoed, logged or stored.
    func paste(_ text: String) async -> String {
        guard let s = session, status.state == "waiting" else {
            // Caught with no attempt pending (never started, expired,
            // cancelled, superseded, or after a restart).
            if case .rejected(let r) = CallbackPaste.parse(text, expectation: nil), r != .noneWaiting { return r.rawValue }
            return status.outcome == "expired" ? CallbackPaste.Rejection.expired.rawValue + " Start again with /subscription login."
                                               : CallbackPaste.Rejection.noneWaiting.rawValue
        }
        if !SIWCActivity.shared.has(s.attempt.id) {
            await end(s, state: "cancelled", message: Self.cancelledElsewhere, outcome: "cancelled", cancelAttempt: false)
            return CallbackPaste.Rejection.noneWaiting.rawValue
        }
        if clock() >= s.attempt.expiresAt {
            await end(s, state: "failed", message: CallbackPaste.Rejection.expired.rawValue, outcome: "expired")
            return CallbackPaste.Rejection.expired.rawValue + " Start again with /subscription login."
        }
        let outcome = CallbackPaste.parse(text, expectation: s.attempt.expectation)
        if case .rejected(let reason) = outcome { return reason.rawValue }
        s.task?.cancel()
        await handle(outcome, s)
        return status.message ?? "Done."
    }

    private func handle(_ outcome: SIWCCallbackOutcome, _ s: Session) async {
        guard session === s, !s.finished, !s.validity.isRevoked else { return }
        switch outcome {
        case .rejected: return
        case .error(let recognized):
            await end(s, state: "failed", message: Self.refusalMessage(recognized), outcome: "browser_error")
        case .code(let code, let clientId, _):
            status.state = "finishing"
            await s.listener?.stop()
            let result: SIWCSignInResult
            do { result = try await exchange(s.signIn, s.attempt, code, clientId) } catch {
                await end(s, state: "failed", message: (error as? SIWCError)?.message ?? "ChatGPT sign-in failed; nothing was saved. Try again.", outcome: "error")
                return
            }
            // Cancelled while exchanging: nothing is saved; the issued
            // refresh token is revoked best effort.
            if s.validity.isRevoked {
                if let refresh = result.tokens?.refresh { await s.signIn.revokeBestEffort(refresh, clientId: result.clientId) }
                await end(s, state: "cancelled", message: Self.cancelledMessage, outcome: "cancelled")
                return
            }
            await publish(result, s)
        }
    }

    /// Save, then a freshly prepared activation (two commits, §3.9).
    private func publish(_ result: SIWCSignInResult, _ s: Session) async {
        var commit: SIWCSaveCommit = .refused(Self.ownerChangedMessage)
        let request = SIWCSaveRequest(result: result, attempt: s.attempt, signIn: s.signIn, epoch: s.epoch)
        if let refusal = await writer.run({ commit = await $0.commitSIWCSave(request) }) {
            await s.signIn.cancel(s.attempt)
            if let refresh = result.tokens?.refresh { await s.signIn.revokeBestEffort(refresh, clientId: result.clientId) }
            await end(s, state: "failed", message: refusal, outcome: "refused")
            return
        }
        switch commit {
        case .saved, .savedUnconfirmed: break
        case .refused(let why), .failed(let why):
            await end(s, state: "failed", message: "ChatGPT sign-in not saved: " + why, outcome: "refused"); return
        case .uncertain(let why):
            await end(s, state: "failed", message: why, outcome: "error"); return
        }
        let store = s.signIn.store
        // Cancelled while the save ran: the published login stays (a save
        // is route-neutral) but nothing is activated, and the user is told.
        if s.validity.isRevoked {
            await end(s, final: Status(state: "cancelled", mode: s.mode, message: Self.savedNotSwitchedMessage, outcome: "saved"))
            return
        }
        guard result.tokens != nil else {
            await end(s, state: "done", message: SIWCError.planUsageOffMessage, outcome: "plan_usage_off")
            return
        }
        SIWCPlanState.signedIn(store, clientId: result.clientId)
        var message: String
        var outcome = "signed_in"
        switch await activate(store: store, clientId: result.clientId, origin: "siwc", validity: s.validity) {
        case .success(let applied):
            message = applied ? "Signed in. Briglia now uses ChatGPT (Sign in with ChatGPT)."
                              : "Signed in. Briglia is busy with a task, so it switches to Sign in with ChatGPT when the task finishes."
            if !applied { outcome = "pending" }
        case .failure(let why):
            if s.validity.isRevoked {
                await end(s, final: Status(state: "cancelled", mode: s.mode, message: Self.savedNotSwitchedMessage, outcome: "saved"))
                return
            }
            message = "Your ChatGPT sign-in is saved, but switching to it was not applied: \(why) Use /subscription use, or Use ChatGPT in briglia menu."
            outcome = "saved"
        }
        if case .savedUnconfirmed = commit { message += " (The disk did not confirm the save; if ChatGPT asks you to sign in again, do so.)" }
        var final = Status(state: "done", mode: s.mode, message: message, outcome: outcome)
        final.firstUse = result.newRegistration
        final.legacyLoginKept = SIWCSurface.legacyLoginPresent()
        await end(s, final: final)
    }

    enum ActivationResult: Equatable { case success(applied: Bool), failure(String) }

    /// Activate the store's saved login for this assistant (D): applied now,
    /// or staged until idle. Model/effort: this assistant's SIWC choices, or
    /// the default for new sign-ins.
    func activate(store: SIWCStore = SIWCStore.resolved(), clientId: String? = nil, origin: String,
                  model newModel: String? = nil, effort newEffort: String? = nil, validity: Validity? = nil) async -> ActivationResult {
        let stored = KeychainHelper.loadSnapshot()
        let model = newModel ?? stored[ChatGPTRoute.siwcModelKey] ?? ResponsesAdapter.subscriptionDefaultModel
        var effort = newEffort ?? stored[ChatGPTRoute.siwcEffortKey] ?? "high"
        if !ResponsesAdapter.allowedEfforts(model: model).contains(effort) { effort = ResponsesAdapter.allowedEfforts(model: model).first ?? "high" }
        let change: PreparedChange
        do {
            change = try SIWCSettings.prepareActivation(store: store, clientId: clientId ?? SIWCSurface.savedTarget(store), model: model, effort: effort,
                                                        textOnly: stored[ChatGPTRoute.siwcTextOnlyKey] == "true",
                                                        origin: origin, acceptPending: true)
        } catch { return .failure((error as? SIWCError)?.message ?? "\(error)") }
        let r = await commitActivation(change, validity.map { v in { try v.check() } })
        if let validity, validity.isRevoked, r.state != .applied, r.state != .pending { return .failure(Self.savedNotSwitchedMessage) }
        switch r.state {
        case .applied:
            if let id = clientId ?? SIWCSurface.savedTarget(store) { SIWCPlanState.userAction(store, clientId: id) }
            return .success(applied: true)
        case .pending: return .success(applied: false)
        default: return .failure(r.message ?? "not applied.")
        }
    }

    /// Cancel this process's waiting sign-in through the writer (S).
    func cancel(browserFailed: Bool = false) async -> Status {
        guard let s = session, !s.finished else {
            return Status(state: "idle", message: "No ChatGPT sign-in is waiting.")
        }
        // First: a save or activation still running for this session can no
        // longer switch Briglia to it (Codex D-R2).
        s.validity.revoke()
        // A publication in flight (exchange, save, activation) settles the
        // ONE definitive outcome itself — saved-not-switched or not saved —
        // and every consumer gets that result (Codex D-R2 round 2).
        if status.state == "finishing" || status.state == "cancelling" {
            return await waitForEnd()
        }
        status.state = "cancelling"   // a paste arriving now is refused
        s.task?.cancel()
        await s.listener?.stop()
        var result = SettingsCommitResult(state: .applied, message: nil)
        if let refusal = await writer.run({ result = await $0.commitSIWCCancel(store: s.signIn.store) }) {
            result = .refused(refusal)
        }
        // The attempt of this process is cancelled whatever the writer said
        // (its marker may stay until expiry; a late callback is inert).
        await s.signIn.cancel(s.attempt)
        let message = browserFailed ? Self.browserFailedHelp
            : (result.state == .applied || result.state == .partial ? "ChatGPT sign-in cancelled." : (result.message ?? "ChatGPT sign-in cancelled."))
        await end(s, state: browserFailed ? "failed" : "cancelled", message: message,
                  outcome: browserFailed ? "browser_failed" : "cancelled", cancelAttempt: false)
        return status
    }

    /// Wait until the current session ends (setup-api wait mode).
    func waitForEnd() async -> Status {
        guard let s = session, !s.finished else { return status }
        await withCheckedContinuation { s.waiters.append($0) }
        return status
    }

    // MARK: End

    private func fail(_ message: String, outcome: String, keepSession: Bool = false) -> Status {
        let failed = Status(state: "failed", message: message, outcome: outcome)
        if !keepSession { status = failed }
        return failed
    }

    private func end(_ s: Session, state: String, message: String, outcome: String, cancelAttempt: Bool = true) async {
        await end(s, final: Status(state: state, mode: s.mode, message: message, outcome: outcome), cancelAttempt: cancelAttempt)
    }

    private func end(_ s: Session, final: Status, cancelAttempt: Bool = false) async {
        guard !s.finished else { return }
        s.finished = true
        s.task?.cancel()
        await s.listener?.stop()
        if cancelAttempt { await s.signIn.cancel(s.attempt) }
        SIWCActivity.shared.finish(s.attempt.id)
        if session === s { status = final; lastFinishNotified = s.onFinish != nil }
        for w in s.waiters { w.resume() }
        s.waiters = []
        s.onFinish?(final)
    }

    /// Selftests: forget the session (its attempt must already be ended).
    func resetForTests() { session?.task?.cancel(); session = nil; status = Status() }
}
