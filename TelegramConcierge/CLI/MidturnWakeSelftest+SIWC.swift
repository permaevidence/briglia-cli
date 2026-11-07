import Foundation

/// Sign in with ChatGPT (SIWC plan §3.7, §3.9 R2; Codex stage-C round 2):
/// a REAL turn over the SIWC route is a job of its login until its final
/// delivery decision. A sign-out while the turn waits on a tool, or after
/// its model answer and before delivery, stops it; nothing more is sent
/// with that login and the answer is not delivered.
extension MidturnHarness {
    func siwcTurnSection() async throws {
        let offline = SIWCError(.local, "selftest: network disabled")
        SIWCAuthClient.sendOverride = { _, _ in throw offline }
        defer {
            ResponsesAdapter.siwcSendOverride = nil
            ConversationManager.beforeFinalDeliveryForTesting = nil
            for key in SIWCSelection.selectionKeys { try? KeychainHelper.delete(key: key) }
            try? configureProvider()
        }
        // A usable SIWC login selected on the SIWC route (scratch roots).
        let store = SIWCStore.resolved()
        _ = try? store.removeFiles()
        let outcome = try await SIWCSelftest.signIn(store, .live, clientId: "oaiappTurn", sub: "sub-turn", new: true,
                                                    tokens: SIWCSelftest.tokens("turn"))
        guard case .saved(_, let g0) = outcome else { check("SIWC0 fixture", false); return }
        let generation = try await store.activate(.init(clientId: "oaiappTurn", generation: g0, replacementId: nil))
        try KeychainHelper.saveBatch(SIWCSelection.activationDelta(.init(clientId: "oaiappTurn", sub: "sub-turn",
            generation: generation, model: "gpt-6.1-sol", effort: nil, textOnly: false)))
        check("SIWC0 the turn's provider is the SIWC route", (try? ChatGPTRoute.currentSource()) != nil)
        let key = SIWCFence.key(store: store.directory, clientId: "oaiappTurn")
        final class Wire: @unchecked Sendable { let lock = NSLock(); var count = 0; var replies: [Data] = [] }
        let wire = Wire()
        ResponsesAdapter.siwcSendOverride = { _ in
            wire.lock.lock(); wire.count += 1; let r = wire.replies.isEmpty ? nil : wire.replies.removeFirst(); wire.lock.unlock()
            guard let r else { throw ResponsesFailure.disconnected }
            return r
        }
        let address = ChannelAddress(kind: .app, chatId: "siwc-selftest")
        func userAt(_ text: String) -> Message { var m = user(text); m.originChannel = address; return m }

        // Positive control: an ordinary SIWC turn delivers its answer.
        var manager = await freshManager()
        wire.replies = [Data(Self.responsesText("SIWC-CONTROL-ANSWER").utf8)]
        let control = ConversationManager.CommandResponseCapture()
        ConversationManager.$commandCapture.withValue(control) { manager._testStartTurn(for: userAt("control")) }
        _ = await manager._testAwaitIdle(timeout: 20)
        check("SIWC1 control: an SIWC turn delivers its answer", control.lines.contains { $0.contains("SIWC-CONTROL-ANSWER") },
              "\(control.lines)")

        // A. Sign-out after the model answer, before final delivery.
        manager = await freshManager()
        wire.replies = [Data(Self.responsesText("SIWC-LATE-ANSWER").utf8)]
        final class Gate: @unchecked Sendable { var reached = false; var release: CheckedContinuation<Void, Never>? }
        let gate = Gate()
        ConversationManager.beforeFinalDeliveryForTesting = { @MainActor in
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in gate.reached = true; gate.release = k }
        }
        let captureA = ConversationManager.CommandResponseCapture()
        ConversationManager.$commandCapture.withValue(captureA) { manager._testStartTurn(for: userAt("late sign-out")) }
        _ = await waitUntil(timeout: 20) { gate.reached }
        check("SIWC2 the turn is still a job of its login before final delivery", SIWCFence.shared.jobCount(key) == 1)
        let writer = SettingsWriter(host: FakeSettingsOwner())
        let logout = await writer.commitSIWCLogout(store: store, revoke: { _ in true }, drainTimeout: 0.5)
        ConversationManager.beforeFinalDeliveryForTesting = nil
        gate.release?.resume()
        _ = await manager._testAwaitIdle(timeout: 20)
        check("SIWC3 the sign-out stopped the turn's final delivery (answer not sent)", !captureA.lines.contains { $0.contains("SIWC-LATE-ANSWER") }
              && writer.lastLogoutStoppedJobs == 1, "\(logout) \(captureA.lines)")
        check("SIWC4 the turn unregistered after its cleanup", SIWCFence.shared.jobCount(key) == 0)

        // B. Sign-out while the turn waits on a tool: no further model request.
        SIWCFence.shared.unfence(key)
        guard case .staged(_, let replacement, let toBe) = try await SIWCSelftest.signIn(store, .live, clientId: "oaiappTurn",
                sub: "sub-turn", new: false, tokens: SIWCSelftest.tokens("turn-2")) else { check("SIWC5 fixture", false); return }
        _ = try await store.activate(.init(clientId: "oaiappTurn", generation: nil, replacementId: replacement))
        try KeychainHelper.save(key: ChatGPTRoute.siwcGenerationKey, value: toBe)
        manager = await freshManager()
        wire.lock.lock(); wire.count = 0; wire.lock.unlock()
        let toolCall: [String: Any] = ["type": "function_call", "id": "fc_siwcw1", "call_id": "siwcw1", "status": "completed",
            "name": "bash", "namespace": SIWCEndpoint.namespace, "arguments": #"{"command":"sleep 2; echo done","wait_seconds":2}"#]
        let toolBody: [String: Any] = ["id": "resp_siwcw1", "status": "completed", "output": [toolCall],
            "usage": ["input_tokens": 100, "input_tokens_details": ["cached_tokens": 0], "output_tokens": 10,
                      "output_tokens_details": ["reasoning_tokens": 0]]]
        wire.replies = [try JSONSerialization.data(withJSONObject: toolBody),
                        Data(Self.responsesText("SIWC-AFTER-TOOL").utf8)]
        let captureB = ConversationManager.CommandResponseCapture()
        ConversationManager.$commandCapture.withValue(captureB) { manager._testStartTurn(for: userAt("tool wait")) }
        _ = await waitUntil(timeout: 20) { wire.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)   // inside the tool's wait
        let toolLogout = await writer.commitSIWCLogout(store: store, revoke: { _ in true }, drainTimeout: 5)
        _ = await manager._testAwaitIdle(timeout: 30)
        try await Task.sleep(nanoseconds: 2_500_000_000)   // past the tool's natural end
        check("SIWC5 a sign-out during a tool wait stops the turn: no further model request, no answer",
              wire.count == 1 && !captureB.lines.contains { $0.contains("SIWC-AFTER-TOOL") } && writer.lastLogoutStoppedJobs == 1,
              "\(toolLogout) count=\(wire.count) \(captureB.lines)")
        check("SIWC6 the sign-out drained the turn (signed out, job gone)", toolLogout == .signedOut(remoteConfirmed: true)
              && SIWCFence.shared.jobCount(key) == 0)
    }
}
