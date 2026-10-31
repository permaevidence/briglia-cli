import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// What the settings writer needs from the process it runs in
/// (KEYLESS_WEB_AND_LIVE_MENU plan B.3): the daemon (the live owner) or a
/// short offline commit that holds the instance lease.
@MainActor
protocol SettingsOwnerHost: AnyObject {
    var isDaemon: Bool { get }
    /// The D barrier (B.4a step 2): no turn, command or producer may start
    /// until `endRouteBarrier`. Offline (no turn can run) it is always held.
    func beginRouteBarrier() async -> Bool
    func endRouteBarrier()
    /// Restore / shutdown / upgrade admission, checked at the decision point.
    func admissionRefusal() -> String?
    /// Runtime reconciliation after a durable commit (reload of keys, email
    /// poller transition, identity finish after poller quiescence).
    func reconcile(after change: PreparedChange, routeChanged: Bool) async
    var toolSwitches: SettingsToolSwitches { get }
}

/// The single settings writer (plan B.3–B.5). `commit` runs the admitted
/// commit transaction of B.4a in the owner: token → (D barrier) → identity
/// reservation → subscription locks → a write-free decision point inside
/// the secrets-lock section → durable effects in order → reconciliation.
@MainActor
final class SettingsWriter {
    nonisolated static let attemptMarkerPrefix = "ada.attempt."
    nonisolated static let scopePublishedKey = "ada.scope.published"
    nonisolated static func attemptMarkerKey(_ category: String) -> String { attemptMarkerPrefix + category }

    nonisolated static let epochMessage = "Briglia's data was replaced (memory deleted or imported) while this was open; nothing was saved — reopen the menu and try again."
    nonisolated static func conflictMessage(_ keys: [String]) -> String {
        "Your settings changed elsewhere after this was prepared (\(keys.prefix(6).joined(separator: ", "))); nothing was saved — check the current settings and try again."
    }
    nonisolated static let supersededMessage = "changed after you saved it; not applied"

    enum Policy {
        /// Classify at the decision point: S now, D under the barrier or staged.
        case classify
        /// The agent's own field edits (D21): applied now even when they
        /// change a route. Derived only from the internal tool caller.
        case immediate
    }

    let gate = SettingsCommitGate()
    weak var host: SettingsOwnerHost?

    init(host: SettingsOwnerHost?) { self.host = host }

    /// Outcomes by client request id (the last 50), for `settings_result`.
    private var outcomes: [(id: String, result: SettingsCommitResult)] = []

    func lookup(_ clientRequestId: String) -> SettingsCommitResult? {
        guard let index = outcomes.lastIndex(where: { $0.id == clientRequestId }) else { return nil }
        let cached = outcomes[index].result
        guard cached.state == .pending else { return cached }
        // A remembered "pending" answer is superseded by the staged change's
        // terminal result once it was applied, dropped or cancelled; it is
        // only an answer while a slot still holds that change.
        let doc = (try? SettingsPendingStore.read()) ?? .init()
        if let r = doc.lastResults.last(where: { $0.clientRequestId == clientRequestId }) {
            let terminal: SettingsCommitResult
            switch r.state {
            case "applied", "persisted": terminal = SettingsCommitResult(state: .applied, message: r.message)
            case "partial": terminal = SettingsCommitResult(state: .partial, message: r.message)
            case "uncertain": terminal = SettingsCommitResult(state: .uncertain, message: r.message)
            default: terminal = SettingsCommitResult(state: .refused, message: r.message ?? r.state)
            }
            outcomes[index].result = terminal
            return terminal
        }
        if doc.slots.values.contains(where: { $0.staged?.change.id == clientRequestId || $0.active?.change.id == clientRequestId }) {
            return cached
        }
        outcomes.remove(at: index)
        return nil
    }

    private func remember(_ id: String, _ result: SettingsCommitResult) {
        outcomes.append((id, result))
        if outcomes.count > 50 { outcomes.removeFirst(outcomes.count - 50) }
    }

    /// Selftest seams.
    var beforeDecisionPointForTesting: (() async -> Void)?
    var duringReconciliationForTesting: (() async -> Void)?

    // MARK: Commit (B.4a)

    /// `stillValid`: the in-process caller's own validity (the menu's action
    /// ticket), re-checked at the decision point — a revoked or superseded
    /// action writes nothing even after it reached the writer.
    func commit(_ change: PreparedChange, policy: Policy = .classify,
                stillValid: (@Sendable () throws -> Void)? = nil) async -> SettingsCommitResult {
        if SettingsCapture.current != nil {
            return await SettingsCapture.$current.withValue(nil) { await commit(change, policy: policy, stillValid: stillValid) }
        }
        guard let token = await gate.acquire() else {
            let r = SettingsCommitResult.refused(gate.admissionClosedReason ?? "Briglia is busy; try again in a moment.")
            remember(change.id, r); return r
        }
        defer { gate.release(token); afterRelease() }
        let r = await commitHolding(token, change, policy: policy, stillValid: stillValid)
        remember(change.id, r)
        return r
    }

    /// The same transaction for a caller that already holds the token (a
    /// lifecycle operation's own writes, B.4b step 5).
    func commitHolding(_ token: SettingsCommitGate.Token, _ change: PreparedChange, policy: Policy,
                       stillValid: (@Sendable () throws -> Void)? = nil) async -> SettingsCommitResult {
        var r = await commitHoldingCore(token, change, policy: policy, stillValid: stillValid)
        if r.state == .applied, SettingsSupersede.hasUnflushedInvalidations {
            // This write is saved and visible; the waiting change it
            // superseded could not be marked on disk (R1-4, R2-2).
            let note = "Saved. " + SettingsSupersede.unflushedMessage
            r.message = note
            if r.reply != nil { r.reply?["note"] = note }
        }
        return r
    }

    private func commitHoldingCore(_ token: SettingsCommitGate.Token, _ change: PreparedChange, policy: Policy,
                                   stillValid: (@Sendable () throws -> Void)? = nil) async -> SettingsCommitResult {
        guard change.subscription == nil || change.identity == nil else {
            return .refused("one settings change cannot combine an inbox change with a ChatGPT login change")
        }
        do { try SettingsSupersede.flushUnflushedInvalidations() } catch {
            return .refused(SettingsSupersede.unflushedMessage)
        }
        if change.isNoop, change.expected.isEmpty, change.subscriptionExpectations.isEmpty, let reply = change.replyObject {
            return SettingsCommitResult(state: .applied, reply: reply)
        }
        var dMode = policy == .immediate
        for _ in 0..<2 {
            var barrier = false
            if dMode, policy == .classify {
                guard let host else { return .refused("settings owner gone") }
                barrier = await cancellable(token) { await host.beginRouteBarrier() } ?? false
                guard barrier else {
                    if gate.admissionClosedReason != nil { return .refused(gate.admissionClosedReason!) }
                    return stageOrBusy(change)
                }
            }
            let outcome = await run(token, change, attempt: UUID().uuidString, holdsBarrier: barrier || policy == .immediate,
                                    immediate: policy == .immediate, pending: nil, stillValid: stillValid)
            switch outcome {
            case .needsBarrier:
                if barrier { host?.endRouteBarrier() }
                dMode = true
                continue
            case .finished(let result, let routeChanged, let wrote):
                if wrote, let host {
                    // The agent's own immediate edits (D21) run mid-turn with
                    // no barrier: only the light reconciliation (credentials;
                    // routes are read live by the next request).
                    await host.reconcile(after: change, routeChanged: routeChanged && barrier)
                    await duringReconciliationForTesting?()
                }
                if barrier { host?.endRouteBarrier() }
                return result
            }
        }
        return .refused("settings change could not be classified")
    }

    /// Runs `body` as a child task the lifecycle protocol can cancel
    /// (B.4b step 3). nil = cancelled.
    private func cancellable<T: Sendable>(_ token: SettingsCommitGate.Token, _ body: @escaping @MainActor () async -> T) async -> T? {
        let task = Task { @MainActor () -> T? in
            let value = await body()
            return Task.isCancelled ? nil : value
        }
        gate.setCancelHandler(token) { task.cancel() }
        let value = await task.value
        return value
    }

    private func afterRelease() {
        if let host = host as? SettingsApplyKicking { host.kickSettingsApply() }
    }

    // MARK: Staging (B.5)

    private func stageOrBusy(_ change: PreparedChange) -> SettingsCommitResult {
        guard change.acceptPending else {
            return SettingsCommitResult(state: .busy, message: "Briglia is busy with a task right now; this change switches what it uses, so it waits until Briglia is idle. Try again then.")
        }
        do {
            let ticket = try Self.stage(change)
            return SettingsCommitResult(state: .pending, message: "Saved. Briglia is busy, so this applies when it finishes its current task.", ticket: ticket)
        } catch {
            return .refused("Could not save the waiting change: \(error)")
        }
    }

    /// Newest wins: a staged change of the same category is replaced (its
    /// client gets "replaced" in the results); an active attempt is never
    /// replaced.
    nonisolated static func stage(_ change: PreparedChange) throws -> String {
        let ticket = UUID().uuidString
        try SettingsPendingStore.update { doc in
            var slot = doc.slots[change.category] ?? SettingsPendingStore.Slot()
            if let old = slot.staged {
                doc.appendResult(.init(ticket: old.ticket, clientRequestId: old.change.id, category: change.category,
                                       label: old.change.label, state: "dropped", message: "replaced by a newer change", at: Date()))
            }
            slot.staged = .init(ticket: ticket, change: change, stagedAt: Date())
            doc.slots[change.category] = slot
        }
        return ticket
    }

    /// Cancel by ticket, staged only.
    nonisolated static func cancelStaged(ticket: String) throws -> String {
        try SettingsPendingStore.update { doc in
            for (category, var slot) in doc.slots {
                if slot.active?.ticket == ticket { return "already applying" }
                if let staged = slot.staged, staged.ticket == ticket {
                    slot.staged = nil
                    doc.slots[category] = slot.isEmpty ? nil : slot
                    doc.appendResult(.init(ticket: ticket, clientRequestId: staged.change.id, category: category,
                                           label: staged.change.label, state: "cancelled", message: nil, at: Date()))
                    return "cancelled"
                }
            }
            return "not found"
        }
    }

    // MARK: Pending apply (B.5)

    /// Applies the staged change of `category` at an idle point: the B.4a
    /// recipe in D mode. A refused barrier leaves the slot staged.
    func applyStaged(category: String) async -> SettingsCommitResult? {
        guard let peek = try? SettingsPendingStore.read(), peek.slots[category]?.staged != nil,
              peek.slots[category]?.active == nil else { return nil }
        guard let token = await gate.acquire() else { return nil }
        defer { gate.release(token) }
        guard let host else { return nil }
        // A failed invalidation is retried first; never apply on top of it
        // (nor a change whose invalidation is only recorded as a tombstone).
        do { try SettingsSupersede.flushUnflushedInvalidations() } catch { return nil }
        guard let tombstoned = try? SettingsSupersede.readTombstonesStrict() else { return nil }
        if let staged = peek.slots[category]?.staged, tombstoned.contains(staged.change.id) { return nil }
        guard await cancellable(token, { await host.beginRouteBarrier() }) == true else { return nil }
        defer { host.endRouteBarrier() }
        // Claim (step 3): only now, with the barrier held.
        let attempt = UUID().uuidString
        let claimed: SettingsPendingStore.Active?
        do {
            claimed = try SettingsPendingStore.update { doc -> SettingsPendingStore.Active? in
                guard var slot = doc.slots[category], let staged = slot.staged, slot.active == nil else { return nil }
                let active = SettingsPendingStore.Active(ticket: staged.ticket, attempt: attempt, change: staged.change,
                                                         state: "claimed", claimedAt: Date())
                slot.staged = nil; slot.active = active
                doc.slots[category] = slot
                return active
            }
        } catch { return nil }
        guard let claimed else { return nil }
        let outcome = await run(token, claimed.change, attempt: attempt, holdsBarrier: true, immediate: false,
                                pending: (category, claimed.ticket))
        switch outcome {
        case .needsBarrier:
            // Impossible with the barrier held; leave it staged.
            Self.unclaim(category: category, attempt: attempt)
            return nil
        case .finished(let result, let routeChanged, let wrote):
            if wrote {
                await host.reconcile(after: claimed.change, routeChanged: routeChanged)
                await duringReconciliationForTesting?()
            }
            // Cancellation or an admission refusal after the claim and
            // before intent: back to staged (plan B.5). A precondition or
            // epoch refusal drops it with its reason.
            if result.state == .refused, !wrote,
               result.preDecision || ["admission", "busy"].contains(result.code ?? "") || gate.admissionClosedReason != nil {
                guard Self.unclaim(category: category, attempt: attempt) else {
                    // The slot could not be put back: keep it claimed (the
                    // journal shows no intent, so recovery restages it).
                    return result
                }
                return nil
            }
            Self.finishPending(category: category, attempt: attempt, change: claimed.change,
                               ticket: claimed.ticket, result: result)
            return result
        }
    }

    /// Cancellation or refusal after the claim and before `intent`: back to staged.
    @discardableResult
    nonisolated static func unclaim(category: String, attempt: String) -> Bool {
        do {
            try SettingsPendingStore.update { doc in
                guard var slot = doc.slots[category], let active = slot.active, active.attempt == attempt,
                      doc.attempts[attempt] == nil else { return }
                if slot.staged == nil { slot.staged = .init(ticket: active.ticket, change: active.change, stagedAt: active.claimedAt) }
                slot.active = nil
                doc.slots[category] = slot
            }
            return true
        } catch {
            print("[Settings] could not return a claimed change to staged: \(error)")
            return false
        }
    }

    /// After step 10: remove `active` and its attempt, append the result —
    /// one write.
    nonisolated static func finishPending(category: String, attempt: String, change: PreparedChange, ticket: String,
                              result: SettingsCommitResult) {
        _ = try? SettingsPendingStore.update { doc in
            if var slot = doc.slots[category], slot.active?.attempt == attempt {
                slot.active = nil
                doc.slots[category] = slot.isEmpty ? nil : slot
            }
            doc.attempts.removeValue(forKey: attempt)
            let state: String
            switch result.state {
            case .applied: state = "applied"
            case .refused: state = ["conflict", "epoch"].contains(result.code ?? "") ? "dropped" : "failed"
            case .partial: state = "partial"
            case .uncertain: state = "uncertain"
            default: state = "failed"
            }
            doc.appendResult(.init(ticket: ticket, clientRequestId: change.id, category: category, label: change.label,
                                   state: state, message: result.state == .applied ? nil : result.message, at: Date()))
        }
    }

    // MARK: The transaction body (B.4a steps 4–8)

    enum Outcome {
        case needsBarrier
        case finished(SettingsCommitResult, routeChanged: Bool, wrote: Bool)
    }

    private struct DecisionAbort: Error { let outcome: SectionOutcome }

    enum SectionOutcome {
        case needsBarrier
        case refused(String, code: String? = nil)
        case done(routeChanged: Bool, wroteSecrets: Bool, authWritten: Bool, note: String?)
        case partial(String)
        case failed(String)
    }

    private func run(_ token: SettingsCommitGate.Token, _ change: PreparedChange, attempt: String,
                     holdsBarrier: Bool, immediate: Bool, pending: (category: String, ticket: String)?,
                     stillValid: (@Sendable () throws -> Void)? = nil) async -> Outcome {
        let switches = host?.toolSwitches ?? SettingsToolSwitches.current()
        let hostAdmission: () -> String? = { [weak self] in self?.host?.admissionRefusal() }
        let admission: () -> String? = {
            if let why = hostAdmission() { return why }
            do { try stillValid?() } catch {
                return (error as? SetupAPICore.CheckpointRevoked)?.message ?? "this action was superseded; nothing was saved"
            }
            return nil
        }
        let gate = self.gate
        await beforeDecisionPointForTesting?()
        // Step 5: identity reservation.
        var ticket: IdentityChange.Ticket?
        if let identity = change.identity {
            guard let kind = AssistantRegistry.Kind(rawValue: identity.kind) else {
                return .finished(.refused("unknown identity change"), routeChanged: false, wrote: false)
            }
            do { ticket = try IdentityChange.begin(kind: kind, rawValue: identity.value) } catch {
                // setup-api's code for an identity refusal (running assistant,
                // identity lock held, value owned by another assistant).
                var r = SettingsCommitResult.refused("\(error)"); r.code = "identity_refused"; r.preDecision = true
                return .finished(r, routeChanged: false, wrote: false)
            }
        }
        // Step 6: subscription locks (sharing lock, then auth stores in the
        // fixed own → shared order), all outside secrets.lock.
        let stores = Self.storesToLock(change)
        let needsShare = !stores.isEmpty && CoordinationMode.multi
        let section: SectionOutcome
        let reached = DecisionReached()
        do {
            // The lock waits run in a child the gate can cancel (closing
            // admission) until the durable phase starts; `enterDurable`
            // clears that handler, and a cancellation of the CALLER's task
            // never reaches this child (Codex R1-5).
            let ticketBox = TicketBox(ticket)
            let locked = Task { @MainActor () throws -> SectionOutcome in
              // The sharing lock (multi mode) is taken here too, by
              // non-blocking attempts between cancellable sleeps (Codex R2-4).
              let shareLock = needsShare ? try await Self.takeShareLockCancellable() : nil
              defer { shareLock?.release() }
              return try await Self.withAuthLocks(stores) { () throws -> SectionOutcome in
                let ticket = ticketBox.ticket
                reached.value = true
                if Task.isCancelled { return .refused(gate.admissionClosedReason ?? "cancelled", code: "admission") }
                if let ticket {
                    var inner: SectionOutcome = .refused("identity commit did not run")
                    do {
                        try ticket.commit {
                            inner = try Self.decisionAndEffects(change, attempt: attempt, holdsBarrier: holdsBarrier,
                                immediate: immediate, pending: pending, switches: switches, admission: admission,
                                enterDurable: { gate.enterDurablePhase(token) })
                            if case .done = inner { return }
                            if case .partial = inner { return }
                            throw DecisionAbort(outcome: inner)
                        }
                    } catch let abort as DecisionAbort {
                        return abort.outcome
                    }
                    return inner
                }
                return try Self.decisionAndEffects(change, attempt: attempt, holdsBarrier: holdsBarrier, immediate: immediate,
                    pending: pending, switches: switches, admission: admission,
                    enterDurable: { gate.enterDurablePhase(token) })
              }
            }
            gate.setCancelHandler(token) { locked.cancel() }
            section = try await locked.value
        } catch is ShareLockBusy {
            ticket?.abort()
            var r = SettingsCommitResult.refused(ChatGPTShare.busyMessage); r.code = "busy"; r.preDecision = true
            return .finished(r, routeChanged: false, wrote: false)
        } catch {
            ticket?.abort()
            var r = SettingsCommitResult.refused(error is CancellationError
                ? (gate.admissionClosedReason ?? "cancelled; nothing was saved") : "\(error.localizedDescription)")
            if error is CancellationError { r.code = "admission" }
            // A lock that could not be taken: nothing was evaluated.
            r.preDecision = !reached.value
            return .finished(r, routeChanged: false, wrote: false)
        }
        switch section {
        case .needsBarrier:
            ticket?.abort()
            return .needsBarrier
        case .refused(let why, let code):
            ticket?.abort()
            var r = SettingsCommitResult.refused(why)
            r.code = code
            return .finished(r, routeChanged: false, wrote: false)
        case .failed(let why):
            ticket?.abort()
            Self.finishAttempt(attempt, change: change, pending: pending, state: "failed", message: why)
            return .finished(SettingsCommitResult(state: .error, message: why), routeChanged: false, wrote: false)
        case .partial(let why):
            if let ticket { if IdentityChange.processMode == .assistant { IdentityChange.deferFinish(ticket) } else { ticket.finish() } }
            Self.finishAttempt(attempt, change: change, pending: pending, state: "partial", message: why)
            return .finished(SettingsCommitResult(state: .partial, message: why), routeChanged: true, wrote: true)
        case .done(let routeChanged, let wroteSecrets, let authWritten, let note):
            if let ticket { if IdentityChange.processMode == .assistant { IdentityChange.deferFinish(ticket) } else { ticket.finish() } }
            if change.wipeAgentMailInstall {
                do { try AgentMailService.wipePrivateInstall() } catch {
                    return .finished(SettingsCommitResult(state: .partial, message: "credential removal incomplete: Briglia's private AgentMail CLI copy: \(error)"),
                                     routeChanged: routeChanged, wrote: true)
                }
            }
            if let mirror = change.webBackendMirror { Prefs.store.set(mirror, forKey: WebSearchBackend.selectionKey) }
            if pending == nil, change.hasAuthEffect {
                Self.finishAttempt(attempt, change: change, pending: nil, state: "applied", message: nil)
            }
            var reply = change.replyObject ?? ["schema": SetupAPICore.schemaVersion, "ok": true]
            if let note { reply["note"] = note }
            return .finished(SettingsCommitResult(state: .applied, reply: reply),
                             routeChanged: routeChanged, wrote: wroteSecrets || authWritten || change.identity != nil)
        }
    }

    /// Immediate commits with an auth effect remove their attempt and add
    /// their result in one write (pending applies do it in `finishPending`).
    nonisolated static func finishAttempt(_ attempt: String, change: PreparedChange, pending: (category: String, ticket: String)?,
                              state: String, message: String?) {
        guard pending == nil else { return }
        _ = try? SettingsPendingStore.update { doc in
            guard doc.attempts.removeValue(forKey: attempt) != nil else { return }
            doc.appendResult(.init(ticket: nil, clientRequestId: change.id, category: change.category, label: change.label,
                                   state: state, message: message, at: Date()))
        }
    }

    nonisolated static func storesToLock(_ change: PreparedChange) -> [String] {
        var dirs = Set(change.subscriptionExpectations.map(\.store))
        if let op = change.subscription { dirs.insert(op.store) }
        let own = StoragePaths.configRoot.standardizedFileURL.path
        return dirs.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.sorted { a, b in
            if a == own { return b != own }
            if b == own { return false }
            return a < b
        }
    }

    struct ShareLockBusy: Error {}

    /// `ChatGPTShare.takeLock` polls synchronously; this takes the same lock
    /// with non-blocking attempts and cancellable sleeps, within the same
    /// overall wait.
    nonisolated static func takeShareLockCancellable() async throws -> ProfileFileLock? {
        let deadline = ProcessInfo.processInfo.systemUptime + ChatGPTShare.waitSeconds
        while true {
            try Task.checkCancellation()
            do { return try ChatGPTShare.takeLock(wait: 0) } catch is ChatGPTShare.Busy {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ShareLockBusy() }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    nonisolated static func withAuthLocks<T>(_ stores: [String], _ body: () async throws -> T) async throws -> T {
        guard let first = stores.first else { return try await body() }
        let store = SubscriptionAuthStore(directory: URL(fileURLWithPath: first, isDirectory: true))
        return try await store.locked { try await withAuthLocks(Array(stores.dropFirst()), body) }
    }

    /// Selftest seams for the durable steps.
    nonisolated(unsafe) static var authStoreForTesting: ((String) -> SubscriptionAuthStore)?
    nonisolated(unsafe) static var afterIntentForTesting: (() throws -> Void)?
    nonisolated(unsafe) static var afterAuthWriteForTesting: (() throws -> Void)?
    nonisolated(unsafe) static var afterSecretsWriteForTesting: (() throws -> Void)?

    nonisolated static func authStore(_ path: String) -> SubscriptionAuthStore {
        authStoreForTesting?(path) ?? SubscriptionAuthStore(directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Steps 7–8: the decision point and the durable effects, inside ONE
    /// synchronous secrets-lock section (no await).
    nonisolated static func decisionAndEffects(_ change: PreparedChange, attempt: String, holdsBarrier: Bool, immediate: Bool,
                                   pending: (category: String, ticket: String)?, switches: SettingsToolSwitches,
                                   admission: () -> String?, enterDurable: () -> Void) throws -> SectionOutcome {
        try KeychainHelper.withStoreLock { holding -> SectionOutcome in
            // 7. Decision point — write-free.
            let epoch: Int
            do { epoch = try ReplacementEpoch.read() } catch { return .refused("\(error)") }
            guard epoch == change.epoch else { return .refused(epochMessage, code: "epoch") }
            if let why = admission() { return .refused(why, code: "admission") }
            let current = holding.store
            var conflicts: [String] = []
            for (key, digest) in change.expected where SettingsDigest.of(current[key]) != digest { conflicts.append(key) }
            if let digest = change.storeDigest, SettingsDigest.ofStore(current) != digest, conflicts.isEmpty {
                conflicts.append("other settings")
            }
            if let digest = change.routeDigest, SettingsKeyRoles.routeDigest(current) != digest, conflicts.isEmpty {
                conflicts.append("other settings")
            }
            guard conflicts.isEmpty else { return .refused(conflictMessage(conflicts.sorted()), code: "conflict") }
            // The live hub keeps refusing Telegram actions (plan B.9): a
            // running daemon's bot changes only through /switchbot.
            if ProcessKind.isDaemon, !change.touchedKeys.isDisjoint(with: [KeychainHelper.telegramBotTokenKey, KeychainHelper.telegramChatIdKey]) {
                return .refused("Briglia is using this Telegram bot right now; use /switchbot to change it.")
            }
            for expectation in change.subscriptionExpectations {
                let state: SubscriptionAuthState?
                do { state = try authStore(expectation.store).read() } catch { return .refused(error.localizedDescription) }
                if expectation.generation.isEmpty {
                    // Prepared against an absent store: still absent.
                    guard state == nil else {
                        return .refused("The ChatGPT login changed after this was prepared; nothing was saved — try again.", code: "conflict")
                    }
                    continue
                }
                guard let state, state.generation == expectation.generation else {
                    return .refused("The ChatGPT login changed after this was prepared; nothing was saved — try again.", code: "conflict")
                }
                if expectation.requireUsable, state.credential == nil || state.requiresLogin == true {
                    return .refused("Sign in to ChatGPT first.", code: "conflict")
                }
                if expectation.requireNoPending, state.pendingLogin != nil {
                    return .refused("Finish the pending ChatGPT login or cancel it first.", code: "conflict")
                }
            }
            var oldAuth: SubscriptionAuthState?
            var newAuth: SubscriptionAuthState?
            var authNote: String?
            if let op = change.subscription {
                do { oldAuth = try authStore(op.store).read() } catch { return .refused(error.localizedDescription) }
                switch op.kind {
                case .publish:
                    guard var state = oldAuth, let pendingId = op.pending, state.pendingLogin == pendingId,
                          let credential = op.credential, let generation = op.projectedGeneration else {
                        return .refused("Login was cancelled or superseded; start login again", code: "conflict")
                    }
                    if let deviceAttempt = op.deviceAttempt, state.deviceChallenge?.pollAttempt != deviceAttempt {
                        return .refused("Login cancelled or superseded; start again")
                    }
                    if op.guardActiveLogin, current[ProviderProfiles.activeProfileKey] == ProviderProfiles.Profile.chatgpt.rawValue,
                       state.credential != nil, state.requiresLogin != true {
                        return .refused("Sign out or switch away from ChatGPT before replacing its active login.", code: "conflict")
                    }
                    state.commitPending(credential, generation: generation)
                    state.lastAttempt = attempt
                    newAuth = state
                    authNote = "ChatGPT login published"
                case .cancel:
                    guard var state = oldAuth, let pendingId = op.pending, state.pendingLogin == pendingId else {
                        return .refused("Login cancelled or superseded; start again")
                    }
                    guard SubscriptionSharing.pendingOwned(state) else { return .refused(SubscriptionSharing.foreignPendingMessage) }
                    state.clearPending()
                    state.lastAttempt = attempt
                    newAuth = state
                    authNote = "pending login cancelled"
                case .logout:
                    guard let generation = op.projectedGeneration else { return .refused("malformed sign-out") }
                    var tomb = SubscriptionAuthState(generation: generation)
                    tomb.lastAttempt = attempt
                    newAuth = tomb
                    authNote = "signed out"
                }
            }
            // A login published while ChatGPT is the active lane moves the
            // runtime binding with it, in the same secrets mutation: running
            // requests validate the bound generation, so the new login and
            // Briglia's switch to it land together (never a binding left on
            // the replaced generation).
            var secretsDelta = change.secretsDelta
            if let op = change.subscription, op.kind == .publish, let oldGen = oldAuth?.generation, let newGen = newAuth?.generation,
               current[ProviderProfiles.activeProfileKey] == ProviderProfiles.Profile.chatgpt.rawValue {
                if current[KeychainHelper.openAICompatibleApiKeyKey] == oldGen, secretsDelta[KeychainHelper.openAICompatibleApiKeyKey] == nil {
                    secretsDelta[KeychainHelper.openAICompatibleApiKeyKey] = .some(newGen)
                }
                if current[ProviderProfiles.subscriptionGenerationKey] == oldGen, secretsDelta[ProviderProfiles.subscriptionGenerationKey] == nil {
                    secretsDelta[ProviderProfiles.subscriptionGenerationKey] = .some(newGen)
                }
            }
            var projected = current
            for (k, v) in secretsDelta { if let v { projected[k] = v } else { projected.removeValue(forKey: k) } }
            let factsOld = change.subscription == nil ? SubscriptionRouteFacts.absent : SubscriptionRouteFacts(oldAuth)
            let factsNew = change.subscription == nil ? SubscriptionRouteFacts.absent : SubscriptionRouteFacts(newAuth)
            let routeChanged = RouteSnapshot.of(stored: current, subscription: factsOld, switches: switches)
                != RouteSnapshot.of(stored: projected, subscription: factsNew, switches: switches)
            if routeChanged && !holdsBarrier && !immediate { return .needsBarrier }

            // 8. Durable effects, in order. After 8.1 nothing restarts.
            enterDurable()
            let journal = change.hasAuthEffect || pending != nil
            let category = pending?.category ?? change.category
            if journal {
                let record = SettingsPendingStore.Attempt(
                    attempt: attempt, operation: pending == nil ? "commit" : "pending-apply", category: category,
                    ticket: pending?.ticket, clientRequestId: change.id, label: change.label,
                    authEffect: change.hasAuthEffect, authKind: change.subscription?.kind.rawValue,
                    storePath: change.subscription?.store,
                    oldEvidence: change.subscription.map { _ in SettingsPendingStore.AuthEvidence(oldAuth) },
                    projectedEvidence: newAuth.map { SettingsPendingStore.AuthEvidence($0) },
                    secretsKeys: change.touchedKeys.sorted(), steps: ["intent"], direction: nil, retirement: nil,
                    startedAt: Date())
                do {
                    try SettingsPendingStore.update { doc in doc.attempts[attempt] = record }
                } catch {
                    return .refused("The settings change couldn't be recorded (\(error)); nothing was saved.")
                }
                do { try afterIntentForTesting?() } catch { return .failed("interrupted before saving (\(error))") }
            }
            var authWritten = false
            // "Visible" vs "confirmed durable" (round-7 note): a replaced but
            // unconfirmed write is handled as written and reported as such.
            var unconfirmed = false
            if let op = change.subscription, let newAuth {
                switch authStore(op.store).writePhased(newAuth) {
                case .written: authWritten = true
                case .writtenUnconfirmed: authWritten = true; unconfirmed = true
                case .notWritten(let error):
                    return .failed("interrupted before saving: \(error.localizedDescription)")
                }
                SettingsSupersede.subscriptionChanged(store: op.store, excludingAttempt: attempt)
                do { try afterAuthWriteForTesting?() } catch {
                    return .partial("partly applied: ChatGPT login \(authNote ?? "changed"); settings not saved")
                }
            }
            var delta = secretsDelta
            if journal { delta[attemptMarkerKey(category)] = .some(attempt) }
            do {
                try holding.mutateHolding(delta)
            } catch is PrivateStorage.ReplacedButNotDurable {
                // Visible: handled as written.
                unconfirmed = true
            } catch {
                if authWritten { return .partial("partly applied: ChatGPT login \(authNote ?? "changed"); settings not saved (\(error.localizedDescription))") }
                return .failed("interrupted before saving: \(error.localizedDescription)")
            }
            do { try afterSecretsWriteForTesting?() } catch { return .done(routeChanged: routeChanged, wroteSecrets: true, authWritten: authWritten, note: nil) }
            if journal {
                _ = try? SettingsPendingStore.update { doc in
                    doc.attempts[attempt]?.steps.append("secrets-done")
                    if let category = pending?.category, var slot = doc.slots[category], slot.active?.attempt == attempt {
                        slot.active?.state = "persisted"
                        doc.slots[category] = slot
                    }
                }
            }
            return .done(routeChanged: routeChanged, wroteSecrets: holding.wrote, authWritten: authWritten,
                         note: unconfirmed ? "saved; the disk did not confirm the write is durable" : nil)
        }
    }
}

/// Hosts that want a scheduler kick when the token is released.
@MainActor
protocol SettingsApplyKicking: AnyObject {
    func kickSettingsApply()
}

/// Which kind of process runs (the decision point refuses a bot change in a
/// running daemon: use /switchbot).
enum ProcessKind {
    nonisolated(unsafe) static var isDaemon = false
}

// MARK: - Superseding observer (B.5)

/// Drops staged changes a later write invalidates. Registered by the owner
/// (`KeychainHelper.writeObserver`); runs synchronously in write order,
/// inside the writer's locks, and persists each drop before returning.
/// Carries the identity ticket into the lock child (same actor).
final class TicketBox: @unchecked Sendable {
    let ticket: IdentityChange.Ticket?
    init(_ ticket: IdentityChange.Ticket?) { self.ticket = ticket }
}

/// Set once the transaction reached its decision point (inside every lock).
final class DecisionReached: @unchecked Sendable { var value = false }

enum SettingsSupersede {
    /// Same-account automatic rebinding and other maintenance writes
    /// (route-neutral) never supersede.
    @TaskLocal static var maintenanceWrite = false

    /// Selftest seam: observed drops.
    nonisolated(unsafe) static var onDropForTesting: ((String) -> Void)?

    static func install() {
        KeychainHelper.preWriteGuard = { keys, after in try guardSecretsWrite(keys, after: after) }
        KeychainHelper.writeObserver = { keys, after in secretsChanged(keys, after: after) }
    }

    static func uninstall() { KeychainHelper.writeObserver = nil; KeychainHelper.preWriteGuard = nil }

    /// A write of a key in a staged change's preconditions or write set
    /// invalidates it — by the EVENT, so A→B→A supersedes too. A change
    /// prepared from the whole store is also invalidated when the store's
    /// route state (route values, credential presence) or, for a
    /// transaction basis, its values no longer match.
    static func invalidation(_ keys: Set<String>, after: [String: String]) -> ((PreparedChange) -> Bool)? {
        let relevant = keys.filter { !$0.hasPrefix(SettingsWriter.attemptMarkerPrefix) }
        guard !relevant.isEmpty else { return nil }
        let routeAfter = SettingsKeyRoles.routeDigest(after)
        let storeAfter = SettingsDigest.ofStore(after)
        return { change in
            if !relevant.isDisjoint(with: Set(change.expected.keys).union(change.touchedKeys)) { return true }
            if let basis = change.storeDigest, storeAfter != basis { return true }
            if let basis = change.routeDigest { return routeAfter != basis }
            return false
        }
    }

    struct InvalidationNotRecorded: Error, LocalizedError, CustomStringConvertible {
        enum Cause { case notRecordable, pendingUnreadable }
        var cause: Cause = .notRecordable
        var description: String {
            switch cause {
            case .notRecordable:
                return "this would supersede a waiting settings change, and that can't be recorded on disk right now (the settings-pending and settings-invalidated files can't be written); nothing was saved"
            case .pendingUnreadable:
                return "the waiting settings changes can't be read (\(SettingsPendingStore.url.path)), so it isn't known whether this would supersede one; nothing was saved"
            }
        }
        var errorDescription: String? { description }
    }

    /// BEFORE a secrets write (inside the store locks, Codex R3-2): every
    /// staged change the write invalidates is dropped durably first; when
    /// the pending file can't be written its id goes to the tombstone file;
    /// when neither can be written the write is refused — so an invalidation
    /// is never only in memory. A damaged pending file (staged state
    /// unknown) refuses too.
    static func guardSecretsWrite(_ keys: Set<String>, after: [String: String]) throws {
        guard !maintenanceWrite, let invalidated = invalidation(keys, after: after),
              FileManager.default.fileExists(atPath: SettingsPendingStore.url.path) else { return }
        let doc: SettingsPendingStore.Document
        do { doc = try SettingsPendingStore.read() } catch { throw InvalidationNotRecorded(cause: .pendingUnreadable) }
        let hit = doc.slots.values.compactMap { $0.staged?.change }.filter(invalidated).map(\.id)
        guard !hit.isEmpty else { return }
        do { try applyDrops(invalidated); return } catch {
            print("[Settings] could not record a superseded waiting change: \(error)")
        }
        do { try writeTombstonesStrict(readTombstonesStrict().union(hit)) } catch { throw InvalidationNotRecorded() }
        unflushedLock.lock(); unflushed.append(invalidated); unflushedLock.unlock()
    }

    /// After a write: anything the guard did not already settle (the guard
    /// is the authority; this is the same rule, best effort).
    static func secretsChanged(_ keys: Set<String>, after: [String: String]) {
        guard !maintenanceWrite, let invalidated = invalidation(keys, after: after) else { return }
        dropStaged(invalidated)
    }

    /// A user-requested login, logout or scope change of `store`.
    static func subscriptionChanged(store: String, excludingAttempt: String? = nil) {
        guard !maintenanceWrite else { return }
        let path = URL(fileURLWithPath: store).standardizedFileURL.path
        dropStaged { change in
            if let op = change.subscription, URL(fileURLWithPath: op.store).standardizedFileURL.path == path { return true }
            return change.subscriptionExpectations.contains { URL(fileURLWithPath: $0.store).standardizedFileURL.path == path }
        }
    }

    // Invalidations that could not be persisted (Codex live-menu R1-4,
    // R2-2). Until they are, every commit, every Telegram settings command
    // and every pending apply first retries them and refuses when that still
    // fails: a stale staged change is never applied and no later write
    // (A→B→A) can make it look valid again. The ids of the staged changes
    // they hit are also kept in `dataRoot/settings-invalidated.json` (a
    // different folder than the pending file), so an owner that exits and
    // a new one that starts keep honouring them. A write whose invalidation
    // can be recorded in neither file is refused before it happens
    // (`guardSecretsWrite`), so no invalidation lives only in memory.
    private static let unflushedLock = NSLock()
    nonisolated(unsafe) private static var unflushed: [(PreparedChange) -> Bool] = []

    static var tombstoneURL: URL { StoragePaths.dataRoot.appendingPathComponent("settings-invalidated.json") }

    /// Absent = no invalidations; an existing file that can't be read or
    /// decoded is UNKNOWN and throws (Codex R3-1): never "empty".
    static func readTombstonesStrict() throws -> Set<String> {
        // Only a verified "not found" is absence (Codex R4-1): a path that
        // can't be looked up (an unsearchable data folder, EACCES) is unknown.
        var st = stat()
        if lstat(tombstoneURL.path, &st) != 0 {
            let err = errno
            if err == ENOENT { return [] }
            throw TombstoneUnknown(reason: String(cString: strerror(err)))
        }
        let data = try Data(contentsOf: tombstoneURL)
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    struct TombstoneUnknown: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "the settings-invalidated file can't be checked (\(reason))" }
    }

    /// True unless the tombstone is verified absent.
    private static var tombstoneMaybePresent: Bool {
        var st = stat()
        return lstat(tombstoneURL.path, &st) == 0 || errno != ENOENT
    }

    /// Best-effort view for tests and /status (unknown → empty).
    static func tombstonedIds() -> Set<String> { (try? readTombstonesStrict()) ?? [] }

    private static func writeTombstonesStrict(_ ids: Set<String>) throws {
        if ids.isEmpty {
            if unlink(tombstoneURL.path) != 0, errno != ENOENT {
                throw TombstoneUnknown(reason: String(cString: strerror(errno)))
            }
            return
        }
        let data = try JSONEncoder().encode(ids.sorted())
        try PrivateStorage.ensureDirectory(StoragePaths.dataRoot)
        _ = try PrivateStorage.writeAtomically(data, to: tombstoneURL, mode: 0o600)
    }

    static var hasUnflushedInvalidations: Bool {
        unflushedLock.lock()
        let inMemory = !unflushed.isEmpty
        unflushedLock.unlock()
        return inMemory || tombstoneMaybePresent
    }

    static let unflushedMessage = "A waiting settings change could not be cancelled on disk (the settings-pending file can't be written), so nothing more is saved until that is fixed. Check the configuration folder's permissions and free space, then try again."

    /// Retries the failed invalidations; throws when they still can't be saved.
    static func flushUnflushedInvalidations() throws {
        unflushedLock.lock()
        let pending = unflushed
        unflushedLock.unlock()
        let ids = try readTombstonesStrict()
        guard !pending.isEmpty || !ids.isEmpty || tombstoneMaybePresent else { return }
        if FileManager.default.fileExists(atPath: SettingsPendingStore.url.path) {
            try applyDrops { change in ids.contains(change.id) || pending.contains { $0(change) } }
        }
        try writeTombstonesStrict([])
        unflushedLock.lock()
        unflushed.removeFirst(min(pending.count, unflushed.count))
        unflushedLock.unlock()
    }

    /// Selftest seam: a new owner process (the in-memory record is gone).
    static func _testForgetInMemory() { unflushedLock.lock(); unflushed = []; unflushedLock.unlock() }

    /// `/deleteuserdata` and Mind import: the pending file is gone, so are
    /// the invalidations that referred to it.
    static func discardInvalidations() {
        unflushedLock.lock(); unflushed = []; unflushedLock.unlock()
        try? FileManager.default.removeItem(at: tombstoneURL)
    }

    private static func dropStaged(_ invalidated: @escaping (PreparedChange) -> Bool) {
        guard FileManager.default.fileExists(atPath: SettingsPendingStore.url.path) else { return }
        do { try applyDrops(invalidated) } catch {
            print("[Settings] could not record a superseded waiting change: \(error)")
            unflushedLock.lock(); unflushed.append(invalidated); unflushedLock.unlock()
            // Reads still work when writes don't: remember WHICH staged
            // changes were invalidated, outside the pending file.
            if let doc = try? SettingsPendingStore.read() {
                let hit = doc.slots.values.compactMap { $0.staged?.change }.filter(invalidated).map(\.id)
                if !hit.isEmpty, let known = try? readTombstonesStrict() { try? writeTombstonesStrict(known.union(hit)) }
            }
        }
    }

    private static func applyDrops(_ invalidated: (PreparedChange) -> Bool) throws {
        try SettingsPendingStore.update { doc in
            for (category, var slot) in doc.slots {
                guard let staged = slot.staged, invalidated(staged.change) else { continue }
                slot.staged = nil
                doc.slots[category] = slot.isEmpty ? nil : slot
                doc.appendResult(.init(ticket: staged.ticket, clientRequestId: staged.change.id, category: category,
                                       label: staged.change.label, state: "dropped",
                                       message: SettingsWriter.supersededMessage, at: Date()))
                onDropForTesting?(staged.ticket)
            }
        }
    }
}
