import Foundation

/// Stage C: the interrupting SIWC sign-out (SIWC plan §3.9 R2, §3.7).
extension SIWCSelftest {
    /// A request registered as in flight for `source` that runs until it is
    /// cancelled (a stream that never ends by itself).
    final class Hanging: @unchecked Sendable {
        let lock = NSLock()
        var started = false, ended: Error? = nil, finished = false
        var task: Task<Void, Never>?
        func start(_ source: SIWCCredentialSource) {
            task = Task {
                do {
                    _ = try await SIWCFence.shared.runRegistered(source.fenceKey, epoch: source.epoch) { () async throws -> Int in
                        self.lock.lock(); self.started = true; self.lock.unlock()
                        while true { try await Task.sleep(nanoseconds: 20_000_000) }
                    }
                } catch {
                    self.lock.lock(); self.ended = error; self.lock.unlock()
                }
                self.lock.lock(); self.finished = true; self.lock.unlock()
            }
        }
        var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        func waitStarted() async { for _ in 0..<200 where !isStarted { try? await Task.sleep(nanoseconds: 10_000_000) } }
    }

    @MainActor
    static func stageCLogoutTests(_ root: URL, _ c: Checks) async throws {
        try resetLive()
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        var revokes = 0
        var gateHeldDuringRevoke = true
        let revoke: (SIWCStore.Tombstone) async -> Bool = { _ in
            revokes += 1
            gateHeldDuringRevoke = writer.gate.isHeld
            return true
        }

        // 1. A running ChatGPT request is cancelled and drained; the sign-out is durable.
        var (source, _) = try await liveSelection(clientId: "oaiappLogoutA", sub: "sub-lA")
        let running = Hanging(); running.start(source); await running.waitStarted()
        // Unrelated work on ANOTHER registration keeps running.
        let otherStore = SIWCStore(directory: root.appendingPathComponent("logout-other"))
        let unrelatedSource = SIWCCredentialSource(storeDirectory: otherStore.directory, clientId: "oaiappUnrelated", generation: UUID().uuidString,
                                                   epoch: 0, identityFingerprint: String(repeating: "e", count: 64))
        let unrelated = Hanging(); unrelated.start(unrelatedSource); await unrelated.waitStarted()
        let outcome = await writer.commitSIWCLogout(store: source.store, revoke: revoke)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let record = (try? source.store.readTokens())?.record(source.clientId)
        c.check("logout: signed out (durable tombstone, revoke confirmed)", outcome == .signedOut(remoteConfirmed: true))
        c.check("logout: the running request was cancelled and drained", running.isFinished
                && (running.ended as? SIWCError)?.kind == .signedOut || running.ended is CancellationError)
        c.check("logout: the tombstone cleared the tokens with a new generation", record?.tokens == nil && record?.generation != source.generation
                && record?.lastEffect != nil)
        c.check("logout: no further send from an operation that captured the old source",
                (try? SIWCFence.shared.check(source.fenceKey, capturedEpoch: source.epoch)) == nil
                && (try? source.store.validate(clientId: source.clientId, generation: source.generation)) == nil)
        c.check("logout: unrelated work keeps running and is not fenced", !unrelated.isFinished && !SIWCFence.shared.isFenced(unrelatedSource.fenceKey))
        c.check("logout: the remote revoke runs after the commit token is released", revokes == 1 && !gateHeldDuringRevoke)
        c.check("logout: a successful sign-out clears the fence", !SIWCFence.shared.isFenced(source.fenceKey))
        c.check("logout: the journal is clean and the selection keys stay (sign in again)",
                ((try? SettingsPendingStore.read())?.attempts.isEmpty ?? false) && KeychainHelper.load(key: ChatGPTRoute.routeKey) == "siwc")
        unrelated.task?.cancel()
        // 2. A stale sign-out (another generation) is refused and interrupts nothing.
        (source, _) = try await liveSelection(clientId: "oaiappLogoutA", sub: "sub-lA")
        let running2 = Hanging(); running2.start(source); await running2.waitStarted()
        let epoch2 = SIWCFence.shared.epoch(source.fenceKey)
        let refused = await writer.commitSIWCLogout(store: source.store, expectedGeneration: UUID().uuidString, revoke: revoke)
        c.check("logout: a stale sign-out is refused with nothing changed", { if case .refused = refused { return true }; return false }())
        c.check("logout: a refused sign-out interrupted nothing (no fence, no epoch bump)", !running2.isFinished
                && !SIWCFence.shared.isFenced(source.fenceKey) && SIWCFence.shared.epoch(source.fenceKey) == epoch2)
        running2.task?.cancel()
        // 3. Tombstone not durable → partial: fence kept, never "signed out".
        SettingsWriter.siwcBeforeTombstoneForTesting = { throw SIWCError(.local, "synthetic write failure") }
        let partial = await writer.commitSIWCLogout(store: source.store, revoke: revoke)
        SettingsWriter.siwcBeforeTombstoneForTesting = nil
        c.check("logout: a tombstone failure is partial, never 'signed out'", partial == .partial(SIWCLogoutOutcome.partialMessage))
        c.check("logout: partial keeps the fence (this process sends nothing more with it)", SIWCFence.shared.isFenced(source.fenceKey)
                && (try? source.store.readTokens())?.record(source.clientId)?.tokens != nil)
        c.check("logout: partial says a restart could revive the saved login", SIWCLogoutOutcome.partialMessage.contains("after a restart"))
        // A retry succeeds and clears the fence.
        let retried = await writer.commitSIWCLogout(store: source.store, revoke: revoke)
        c.check("logout: a retry after a partial result signs out", retried == .signedOut(remoteConfirmed: true) && !SIWCFence.shared.isFenced(source.fenceKey))
        // 4. Lifecycle (wipe/import/upgrade) arriving during the drain: the holder is not cancelled; the result is partial.
        (source, _) = try await liveSelection(clientId: "oaiappLogoutA", sub: "sub-lA")
        var phaseWhenClosed = false
        SettingsWriter.siwcAfterFenceForTesting = { @MainActor in
            writer.gate.closeAdmission(reason: "Briglia is deleting its memory")
            phaseWhenClosed = writer.gate.holderInterrupting
        }
        let lifecycle = await writer.commitSIWCLogout(store: source.store, revoke: revoke)
        SettingsWriter.siwcAfterFenceForTesting = nil
        writer.gate.reopenAdmission()
        c.check("logout: a lifecycle operation during the drain does not cancel the holder", phaseWhenClosed)
        c.check("logout: admission closed during the drain → partial, tokens kept", { if case .partial = lifecycle { return true }; return false }()
                && (try? source.store.readTokens())?.record(source.clientId)?.tokens != nil)
        _ = await writer.commitSIWCLogout(store: source.store, revoke: revoke)
        // 5. Remote revoke not confirmed: signed out locally, says so.
        (source, _) = try await liveSelection(clientId: "oaiappLogoutA", sub: "sub-lA")
        let unconfirmed = await writer.commitSIWCLogout(store: source.store, revoke: { _ in false })
        c.check("logout: unconfirmed revoke → signed out locally with the ChatGPT-settings hint",
                unconfirmed == .signedOut(remoteConfirmed: false) && unconfirmed.message.contains("chatgpt.com/settings/usage")
                && (try? source.store.readTokens())?.record(source.clientId)?.tokens == nil)
        // 6. A job that captured SIWC before a /provider switch is still fenced (whatever provider is selected now).
        (source, _) = try await liveSelection(clientId: "oaiappLogoutA", sub: "sub-lA")
        try KeychainHelper.saveBatch([ProviderProfiles.activeProfileKey: "openrouter"])
        let captured = Hanging(); captured.start(source); await captured.waitStarted()
        let switched = await writer.commitSIWCLogout(store: source.store, revoke: revoke)
        try? await Task.sleep(nanoseconds: 100_000_000)
        c.check("logout: a job captured before a provider switch is cancelled too", switched == .signedOut(remoteConfirmed: true) && captured.isFinished)
        // 7. The drain is bounded: a request that ignores cancellation does not block the sign-out forever.
        (source, _) = try await liveSelection(clientId: "oaiappLogoutA", sub: "sub-lA")
        let stubborn = Task {
            _ = try? await SIWCFence.shared.runRegistered(source.fenceKey, epoch: source.epoch) { () async throws -> Int in
                let deadline = Date().addingTimeInterval(1.5)
                while Date() < deadline { usleep(20_000) }   // never checks cancellation
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        let bounded = await writer.commitSIWCLogout(store: source.store, revoke: revoke, drainTimeout: 0.3)
        c.check("logout: the drain wait is bounded", bounded == .signedOut(remoteConfirmed: true) && Date().timeIntervalSince(started) < 1.4)
        c.check("logout: a drain that timed out keeps the fence (late results suppressed)", SIWCFence.shared.isFenced(source.fenceKey))
        _ = await stubborn.value
        // 8. A wipe/import that advanced the replacement epoch during the drain → partial.
        (source, _) = try await liveSelection(clientId: "oaiappLogoutA", sub: "sub-lA")
        SettingsWriter.siwcAfterFenceForTesting = { try? ReplacementEpoch.advance() }
        let replaced = await writer.commitSIWCLogout(store: source.store, revoke: revoke)
        SettingsWriter.siwcAfterFenceForTesting = nil
        c.check("logout: data replaced during the drain → partial, nothing tombstoned", replaced == .partial(SIWCLogoutOutcome.partialMessage)
                && (try? source.store.readTokens())?.record(source.clientId)?.tokens != nil)
        try resetLive()
    }
}
