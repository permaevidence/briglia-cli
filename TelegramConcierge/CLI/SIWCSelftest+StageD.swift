import Foundation

/// Stage D: plan state and its notices (SIWC plan §5.1, D23). Offline, temp
/// XDG roots, synthetic tokens.
extension SIWCSelftest {
    /// Older rows that deliberately trigger a plan-state answer and then test
    /// the transport itself start from a fresh plan state.
    static func clearPlanState(_ store: SIWCStore) {
        try? FileManager.default.removeItem(at: SIWCPlanState.url(store))
    }

    static func stageDPlanTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        SIWCPlanState.profileForTesting = "default"
        SIWCPlanState.destination = { "dest-A" }
        var notices = 0
        SIWCPlanState.onNotice = { notices += 1 }
        defer { SIWCPlanState.profileForTesting = nil; SIWCPlanState.destination = { nil }; SIWCPlanState.onNotice = nil }
        let (source, _) = try await liveSelection(clientId: "oaiappPlanA", sub: "sub-plan-A")
        let store = source.store
        let fp = SIWCEndpoint.registrationFingerprint(clientId: "oaiappPlanA")
        func entry() -> SIWCPlanEntry { (try? SIWCPlanState.read(store))?.entries[fp] ?? SIWCPlanEntry() }
        let limit = SIWCError(.limitReached, SIWCError.limitMessage)

        // 1. ok: admitted; a success writes nothing.
        let t0 = try SIWCPlanState.admit(source, userTurn: false)
        SIWCPlanState.observe(t0, .success)
        c.check("plan: ok admits; a success in ok writes no plan file",
                !FileManager.default.fileExists(atPath: SIWCPlanState.url(store).path) && t0.episode == 0)

        // 2. A limit answer opens one episode, owned by this assistant.
        let opened = SIWCPlanState.observe(t0, .failure(limit))
        c.check("plan: a usage-limit answer opens episode 1, opener = this assistant, entry notice queued for its destination",
                opened == .opened(episode: 1, state: .limitReached) && entry().openedBy == "default"
                && entry().destination == "dest-A" && entry().entryNotice == "queued" && notices == 1)
        let again = SIWCPlanState.observe(t0, .failure(limit))
        let t1 = try SIWCPlanState.admit(source, userTurn: true)
        _ = SIWCPlanState.observe(t1, .failure(limit))
        c.check("plan: more limit answers in the same state add nothing (one notice per state change)",
                again == .none && entry().episode == 1 && notices == 1)
        c.check("plan: the episode and its notice survive a reload (on disk)",
                SIWCPlanState.pendingNotices(store, destination: "dest-A").map(\.episode) == [1])

        // 3. Gate: background lanes send nothing; a user turn makes one attempt.
        await c.rejectsKind("plan: limit_reached → a background lane is refused before any send", .limitReached) {
            _ = try SIWCPlanState.admit(source, userTurn: false)
        }
        c.check("plan: limit_reached → a user turn is admitted (one attempt)", (try? SIWCPlanState.admit(source, userTurn: true)) != nil)

        // 4. Late results: an answer from an older episode never rolls the state back.
        let late = SIWCPlanState.observe(t0, .success)
        c.check("plan: a late success from episode 0 doesn't clear episode 1, no recovery notice",
                late == .none && entry().state == .limitReached && entry().recoveryNotice == nil)

        // 5. Recovery: claimed once, by the observer.
        let t2 = try SIWCPlanState.admit(source, userTurn: true)
        let recovered = SIWCPlanState.observe(t2, .success)
        c.check("plan: the next success ends the alerted episode; this assistant claims the one recovery notice",
                recovered == .recovered(episode: 1, claimed: true) && entry().state == .ok && entry().recoveryClaimedBy == "default"
                && entry().recoveryNotice == "queued" && notices == 2)
        SIWCPlanState.profileForTesting = "Health"
        let second = SIWCPlanState.observe(t2, .success)
        c.check("plan: a second observer of the same recovery claims nothing (D23)", second == .none && entry().recoveryClaimedBy == "default")
        c.check("plan: a sharer that did not open/claim has no notice to push",
                SIWCPlanState.pendingNotices(store, destination: "dest-A").isEmpty)
        SIWCPlanState.profileForTesting = "default"

        // 6. Delivery bookkeeping: at-least-once, never through another destination.
        var pending = SIWCPlanState.pendingNotices(store, destination: "dest-A")
        c.check("notices: the queued entry (now stale) and the recovery: only the recovery is due",
                pending.count == 1 && pending.first?.recovery == true && pending.first?.text == SIWCPlanState.recoveryNotice)
        // A crash between the send and the mark repeats at most this one.
        pending = SIWCPlanState.pendingNotices(store, destination: "dest-A")
        c.check("notices: not marked → the same single notice is due again after a restart", pending.count == 1)
        c.check("notices: marked delivered once", SIWCPlanState.markDelivered(store, pending[0]) && !SIWCPlanState.markDelivered(store, pending[0])
                && SIWCPlanState.pendingNotices(store, destination: "dest-A").isEmpty)

        // 7. A replaced bot (another destination): the queued notice is dropped.
        let t3 = try SIWCPlanState.admit(source, userTurn: false)
        _ = SIWCPlanState.observe(t3, .failure(limit))
        c.check("notices: after a bot replacement the queued notice is dropped, never sent through the new bot",
                SIWCPlanState.pendingNotices(store, destination: "dest-B").isEmpty && entry().entryNotice == "dropped"
                && SIWCPlanState.pendingNotices(store, destination: "dest-A").isEmpty)

        // 8. Generation: a request of an older generation changes nothing.
        let t4 = try SIWCPlanState.admit(source, userTurn: true)
        try rewriteBound(store, "oaiappPlanA") { $0.generation = UUID().uuidString }
        c.check("plan: a success from an older credential generation is ignored", SIWCPlanState.observe(t4, .success) == .none
                && entry().state == .limitReached)
    }

    static func stageDPlanStatesTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        SIWCPlanState.profileForTesting = "default"
        SIWCPlanState.destination = { nil }
        defer { SIWCPlanState.profileForTesting = nil }
        let (source, _) = try await liveSelection(clientId: "oaiappPlanB", sub: "sub-plan-B")
        let store = source.store
        let fp = SIWCEndpoint.registrationFingerprint(clientId: "oaiappPlanB")
        func entry() -> SIWCPlanEntry { (try? SIWCPlanState.read(store))?.entries[fp] ?? SIWCPlanEntry() }

        // sign_in_required is entered only when the record is really unusable.
        let t0 = try SIWCPlanState.admit(source, userTurn: true)
        let changed = SIWCPlanState.observe(t0, .failure(SIWCError(.signInRequired, "ChatGPT login changed; request cancelled.")))
        c.check("plan: a sign-in answer while the record is still usable (a changed login) is not a plan state", changed == .none && entry().state == .ok)
        try await store.requireLogin("oaiappPlanB", generation: source.generation)
        let opened = SIWCPlanState.observe(t0, .failure(SIWCError(.signInRequired, SIWCError.signInMessage)))
        c.check("plan: a terminal answer on an unusable record opens sign_in_required; no push channel → terminal line only",
                opened == .opened(episode: 1, state: .signInRequired) && entry().entryNotice == "local")
        await c.rejectsKind("plan: sign_in_required → a user turn sends nothing and gets the sign-in offer", .signInRequired) {
            _ = try SIWCPlanState.admit(source, userTurn: true)
        }
        do { _ = try SIWCPlanState.admit(source, userTurn: true) } catch let e as SIWCError {
            c.check("plan: the offer names /subscription login and says nothing was sent",
                    e.message.contains("/subscription login") && e.message.contains("Nothing was sent"))
        }
        SIWCPlanState.signedIn(store, clientId: "oaiappPlanB")
        c.check("plan: a successful sign-in clears sign_in_required directly (no recovery notice)",
                entry().state == .ok && entry().recoveryNotice == nil)

        // not_available: only a user action allows one more attempt.
        let t1 = try SIWCPlanState.admit(source, userTurn: false)
        try rewriteBound(store, "oaiappPlanB") { $0.requiresLogin = nil }
        _ = SIWCPlanState.observe(t1, .failure(SIWCError(.notAvailable, SIWCError.notEnabledMessage)))
        c.check("plan: not_available entered with its recognized reason only", entry().state == .notAvailable && entry().reason == "v2_client_not_enabled")
        await c.rejectsKind("plan: not_available → even a user turn sends nothing before a user action", .notAvailable) {
            _ = try SIWCPlanState.admit(source, userTurn: true)
        }
        SIWCPlanState.userAction(store, clientId: "oaiappPlanB")
        await c.rejectsKind("plan: after a user action a background lane still sends nothing", .notAvailable) {
            _ = try SIWCPlanState.admit(source, userTurn: false)
        }
        let t2 = try? SIWCPlanState.admit(source, userTurn: true)
        c.check("plan: after a user action the next user turn is admitted once", t2 != nil && entry().retryAllowed == true)
        _ = SIWCPlanState.observe(t2, .failure(SIWCError(.notAvailable, SIWCError.notEligibleMessage)))
        await c.rejectsKind("plan: the one attempt failed again → no further attempt", .notAvailable) {
            _ = try SIWCPlanState.admit(source, userTurn: true)
        }

        // Pause classification (archive, memory, maintenance alerts).
        c.check("pause: the gate's and the plan's fixed texts are pauses, ordinary errors are not",
                SIWCPlanState.isPause(SIWCPlanState.pausedLimitMessage) && SIWCPlanState.isPause("x " + SIWCError.limitMessage)
                && SIWCPlanState.isPause(SIWCError(.signedOut, "x")) && !SIWCPlanState.isPause("HTTP 500 upstream")
                && !SIWCPlanState.isPause(SIWCError(.transient, "x")))
        await MaintenanceAlertCenter.shared._testReset()
        let alerted = await MaintenanceAlertCenter.shared.reportFailure(.conversationSummary, error: SIWCPlanState.pausedLimitMessage, deterministic: true)
        let alertedOther = await MaintenanceAlertCenter.shared.reportFailure(.conversationSummary, error: "HTTP 401 bad key", deterministic: true)
        c.check("pause: a paused plan raises no maintenance alert (an ordinary deterministic failure still does)", !alerted && alertedOther)
        await MaintenanceAlertCenter.shared._testReset()

        // The user-turn marker: only the registered main-turn task.
        let job = try SIWCFence.shared.registerCurrentTask(source, userTurn: true)
        let inside = SIWCFence.shared.currentTaskIsUserTurn(source.fenceKey)
        let child = await Task { SIWCFence.shared.currentTaskIsUserTurn(source.fenceKey) }.value
        SIWCFence.shared.unregisterJob(job)
        let sub = try SIWCFence.shared.registerCurrentTask(source)
        let subagent = SIWCFence.shared.currentTaskIsUserTurn(source.fenceKey)
        SIWCFence.shared.unregisterJob(sub)
        c.check("gate: only the main turn's own task is a user turn (not other tasks, not subagent jobs)", inside && !child && !subagent)
    }

    /// End to end through the real web transport: a limit answer from one
    /// lane pauses every background lane before any send (§5.1 item 2).
    static func stageDPlanTransportTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        SIWCPlanState.profileForTesting = "default"
        SIWCPlanState.destination = { nil }
        defer { SIWCPlanState.profileForTesting = nil }
        let (source, _) = try await liveSelection(clientId: "oaiappPlanC", sub: "sub-plan-C")
        final class Box: @unchecked Sendable { var sends = 0; var limit = true }
        let box = Box()
        ResponsesAdapter.siwcSendOverride = { _ in
            box.sends += 1
            if box.limit { throw SIWCError(.limitReached, SIWCError.limitMessage) }
            return Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n".utf8)
        }
        let body: [String: JSONValue] = ["input": .array([]), "stream": .bool(true)]
        do { _ = try await SubscriptionWebTransport.postSIWC(body: body, source: source, lane: .ephemeral(UUID()), timeout: 5, deadline: nil) } catch {}
        let sendsAfterLimit = box.sends
        let state = SIWCPlanState.entry(source.store, clientId: "oaiappPlanC")?.state
        do { _ = try await SubscriptionWebTransport.postSIWC(body: body, source: source, lane: .ephemeral(UUID()), timeout: 5, deadline: nil) } catch {}
        c.check("transport: a web stage's limit answer opens limit_reached; the next web stage sends nothing",
                state == .limitReached && sendsAfterLimit == 1 && box.sends == 1, "sends \(box.sends) state \(String(describing: state))")
        box.limit = false
        // Background never probes; only a user turn may (not reachable here).
        do { _ = try await SubscriptionWebTransport.postSIWC(body: body, source: source, lane: .ephemeral(UUID()), timeout: 5, deadline: nil) } catch {}
        c.check("transport: still paused for background lanes after the server would answer again (no probing from idle work)", box.sends == 1)
    }
}
