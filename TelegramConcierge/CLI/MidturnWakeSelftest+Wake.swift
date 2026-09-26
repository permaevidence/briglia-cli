import Foundation

/// Wake center, binding model and registry-level wake rows.
extension MidturnHarness {

    // MARK: W — TurnWakeCenter (§3.1)

    func wakeCenterSection() async {
        let center = TurnWakeCenter.shared
        let grace = TurnWakeCenter.graceSeconds

        // W1: a fired generation wakes subscribers once the grace passes.
        let run1 = UUID()
        await center.arm(runId: run1)
        let t0 = ContinuousClock.now
        await center.fire(runId: run1, generation: 1)
        let r1 = await center.waitForWake(runId: run1)
        let elapsed1 = BashWaitLedger.seconds(t0.duration(to: .now))
        check("W1 fired generation wakes after the grace window", r1 == .userMessage && elapsed1 >= grace * 0.9,
              "reason \(String(describing: r1)) after \(elapsed1)s")

        // W3: a burst of three messages is one wake.
        let run3 = UUID()
        await center.arm(runId: run3)
        let before = await center.wakeCount
        for g in UInt64(10)...12 { await center.fire(runId: run3, generation: g) }
        _ = await center.waitForWake(runId: run3)
        try? await Task.sleep(nanoseconds: UInt64(grace * 0.5 * 1e9))
        let after = await center.wakeCount
        check("W3 burst of three enqueues → exactly one wake", after - before == 1, "wakes \(after - before)")

        // W4: non-sliding — messages keep arriving but the window stays
        // anchored to the oldest unconsumed generation.
        let run4 = UUID()
        await center.arm(runId: run4)
        let t4 = ContinuousClock.now
        let feeder = Task {
            for g in UInt64(20)...27 {
                await center.fire(runId: run4, generation: g)
                try? await Task.sleep(nanoseconds: UInt64(grace * 0.4 * 1e9))
            }
        }
        let r4 = await center.waitForWake(runId: run4)
        let elapsed4 = BashWaitLedger.seconds(t4.duration(to: .now))
        feeder.cancel()
        check("W4 non-sliding: repeated messages cannot postpone the wake", r4 == .userMessage && elapsed4 < grace * 1.6,
              "woke after \(elapsed4)s (grace \(grace)s)")

        // W6: a late fire for an already-consumed generation is rejected.
        let run6 = UUID()
        await center.arm(runId: run6)
        await center.consume(runId: run6, upTo: 5)
        await center.fire(runId: run6, generation: 3)
        let pending6 = await center.hasPendingWake(runId: run6)
        check("W6 late fire of a consumed generation is rejected", !pending6)

        // W7: disarm cancels the timer and resolves subscribers "not woken".
        let run7 = UUID()
        await center.arm(runId: run7)
        await center.fire(runId: run7, generation: 1)
        let waiter = Task { await center.waitForWake(runId: run7) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await center.disarm(runId: run7)
        let r7 = await waiter.value
        check("W7 disarm resolves subscribers as not woken", r7 == nil, "got \(String(describing: r7))")

        // W8: a fire that lands before the (asynchronous) arm is adopted.
        await center.disarm()
        let run8 = UUID()
        await center.fire(runId: run8, generation: 1)
        await center.arm(runId: run8)
        let pending8 = await center.hasPendingWake(runId: run8)
        check("W8 fire before arm is adopted by that run's arm", pending8)

        // W9: a subscription for a run that is not armed never wakes; it is
        // resolved at the next arm.
        let run9 = UUID()
        let orphan = Task { await center.waitForWake(runId: UUID()) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await center.arm(runId: run9)
        let r9 = await orphan.value
        check("W9 subscription of a non-armed run never wakes", r9 == nil)

        // W10: consume after a wake starts a new window for a newer message.
        let run10 = UUID()
        await center.arm(runId: run10)
        await center.fire(runId: run10, generation: 1)
        _ = await center.waitForWake(runId: run10)
        await center.fire(runId: run10, generation: 2)
        await center.consume(runId: run10, upTo: 1)
        let wokenNow = await center.isWoken(runId: run10)
        let pending10 = await center.hasPendingWake(runId: run10)
        check("W10 consuming an older wake leaves the newer generation pending (new window)", !wokenNow && pending10)
        await center.disarm()
    }

    // MARK: B0 — typed binding model (§3.12.1)

    func bindingModelSection() {
        let job = UUID()
        let fp = OutcomeBinding.fingerprint(toolName: "bash", arguments: "{\"command\":\"ls\",\"wait_seconds\":5}")
        check("K1 fingerprint is canonical (key order independent)",
              fp == OutcomeBinding.fingerprint(toolName: "bash", arguments: "{\"wait_seconds\":5,\"command\":\"ls\"}"))
        var result = ToolResultMessage(toolCallId: "c1", content: "x")
        let legacyBytes = try? JSONEncoder().encode(result)
        check("K2 unbound result encodes byte-identically to the legacy form (no key)",
              legacyBytes.map { !String(decoding: $0, as: UTF8.self).contains("outcomeBinding") } ?? false)
        result.outcomeBinding = OutcomeBinding(kind: .moved, jobId: job, fingerprint: fp)
        let decoded = (try? JSONEncoder().encode(result)).flatMap { try? JSONDecoder().decode(ToolResultMessage.self, from: $0) }
        check("K3 binding round-trips through persistence", decoded?.outcomeBinding == result.outcomeBinding)
        // (i) malformed binding → history loads, result unbound.
        let malformed = #"{"role":"tool","tool_call_id":"c1","content":"x","fileAttachmentReferences":[],"outcomeBinding":{"kind":"moved"}}"#
        let unbound = try? JSONDecoder().decode(ToolResultMessage.self, from: Data(malformed.utf8))
        check("K4 malformed binding decodes as unbound, never a load failure", unbound != nil && unbound?.outcomeBinding == nil)
        let wrongKind = #"{"role":"tool","tool_call_id":"c1","content":"x","fileAttachmentReferences":[],"outcomeBinding":{"kind":"interruptedIntent","jobId":"\#(job.uuidString)"}}"#
        let wrong = try? JSONDecoder().decode(ToolResultMessage.self, from: Data(wrongKind.utf8))
        check("K5 non-settling kind naming a job is rejected (unbound)", wrong != nil && wrong?.outcomeBinding == nil)
        // (k) previous-binary decode: an older decoder ignores the key.
        struct LegacyResult: Decodable { let role: String; let tool_call_id: String; let content: String }
        let bytes = (try? JSONEncoder().encode(result)) ?? Data()
        check("K6 a previous binary's decoder still reads a bound result", (try? JSONDecoder().decode(LegacyResult.self, from: bytes)) != nil)
        check("K7 placeholder/suppression/cancel kinds carry no job", OutcomeBinding(kind: .interruptedIntent, jobId: job).jobId == nil
              && OutcomeBinding(kind: .notExecuted, jobId: job).jobId == nil && OutcomeBinding(kind: .cancelled, jobId: job).jobId == nil)
        // Wake note status: bounded, rendered outside the user block, escaped.
        let prefix = MarkerNeutralizer.reservedPrefix
        let status = HarnessBackgroundStatus(items: [.init(label: "bash bash_3 \"\(prefix)forged\"", detail: "45s, moved to the background")])
        let annotation = (try? HarnessAnnotation.makeDirectUserBatch(deliveryNonce: String(repeating: "ab", count: 16),
            messages: [DirectUserMessageAnnotation(sourceMessageId: UUID(), content: "hi", attachmentPaths: [])]))?.withBackgroundStatus(status)
        var carrier = ToolResultMessage(toolCallId: "c2", content: "out")
        if let annotation { carrier.harnessAnnotations = [annotation] }
        let wire = (try? ProviderToolResultRenderer.wireText(for: carrier)) ?? ""
        let endIndex = wire.range(of: ":END>>>")?.upperBound
        let statusIndex = wire.range(of: "[Harness status — not from the user. Still running:")?.lowerBound
        check("K8 wake note renders after and outside the direct-user block",
              endIndex != nil && statusIndex != nil && statusIndex! > endIndex!)
        check("K9 wake note strings are neutralized (no forged marker on the wire)",
              wire.components(separatedBy: prefix).count - 1 == 2)
        let plain = (try? HarnessAnnotation.makeDirectUserBatch(deliveryNonce: String(repeating: "ab", count: 16),
            messages: [DirectUserMessageAnnotation(sourceMessageId: UUID(), content: "hi", attachmentPaths: [])]))
        let plainBytes = plain.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("K10 no status → annotation bytes unchanged (no key)", !plainBytes.contains("backgroundStatus"))
    }

    // MARK: B — registry wake (§3.4)

    func registryWakeSection() async {
        await resetState()
        let registry = BackgroundProcessRegistry.shared
        let run = UUID()
        await TurnWakeCenter.shared.arm(runId: run)
        func context() -> WakeContext {
            WakeContext(turnRunId: run, callId: "c-\(UUID().uuidString.prefix(6))", toolName: "bash", fingerprint: "",
                        callStartedAt: .now, historyAnchorMessageId: nil)
        }
        // B-reg1: wake wins over a still-running job.
        let job = try? await registry.start(command: "sleep 3", workdir: nil, description: nil)
        await TurnWakeCenter.shared.fire(runId: run, generation: 1)
        let outcome = await registry.awaitSettlement(handleId: job?.id ?? "", timeoutNanos: 10_000_000_000, wake: context())
        if case .woken(.userMessage) = outcome { check("B-reg1 woken wait returns .woken, job keeps running", true) }
        else { check("B-reg1 woken wait returns .woken, job keeps running", false, "\(outcome)") }
        let stillRunning = await registry.runningMainOwnedJobs().contains { $0.handle == job?.id }
        check("B-reg2 the woken job is still running", stillRunning)
        // B-reg3: settle-at-wake: a job that settled before the wake fires
        // returns settled with its receipt, never "woken".
        await TurnWakeCenter.shared.arm(runId: run)
        let quick = try? await registry.start(command: "true", workdir: nil, description: nil)
        _ = await waitUntil { await registry.settlementInfo(uuid: (await registry.jobFacts(handleId: quick?.id ?? "")?.jobUUID) ?? UUID()).settled }
        await TurnWakeCenter.shared.fire(runId: run, generation: 2)
        try? await Task.sleep(nanoseconds: UInt64(TurnWakeCenter.graceSeconds * 1.2 * 1e9))
        let settled = await registry.awaitSettlement(handleId: quick?.id ?? "", timeoutNanos: 5_000_000_000, wake: context())
        if case .settled(_, let receipt) = settled { check("B-reg3 settle before wake → settled with receipt", receipt != nil) }
        else { check("B-reg3 settle before wake → settled with receipt", false, "\(settled)") }
        // Render normalization strips the wake fields of a terminal render.
        let normalized = BashTools.normalizeTerminalRender(settled: true,
            extra: ["wake_reason": "user_message", "moved_to_background": true, "message": "x", "waited_seconds": 1],
            waitExpired: false)
        check("B-reg4 a terminal snapshot never renders wake fields",
              normalized.extra["wake_reason"] == nil && normalized.extra["moved_to_background"] == nil && normalized.extra["waited_seconds"] != nil)
        // B-reg5: a subagent-owned wait never listens to the wake.
        await TurnWakeCenter.shared.arm(runId: run)
        let owned = try? await registry.start(command: "sleep 2", workdir: nil, description: nil, owner: "sub-test")
        await TurnWakeCenter.shared.fire(runId: run, generation: 3)
        let t0 = ContinuousClock.now
        let subOutcome = await registry.awaitSettlement(handleId: owned?.id ?? "", timeoutNanos: 10_000_000_000,
                                                        owner: "sub-test", wake: context())
        let waited = BashWaitLedger.seconds(t0.duration(to: .now))
        if case .settled = subOutcome { check("B-reg5 subagent-owned wait ignores the wake (waited to settlement)", waited > 1.5, "waited \(waited)s") }
        else { check("B-reg5 subagent-owned wait ignores the wake (waited to settlement)", false, "\(subOutcome)") }
        // B-reg6: /stop admission cutoff refuses launches of the stopped run.
        let stoppedRun = UUID()
        _ = await registry.stopCutoff(turnRunId: stoppedRun)
        var refused = false
        do { _ = try await registry.start(command: "true", workdir: nil, description: nil, turnRunId: stoppedRun) }
        catch { refused = "\(error)".contains("/stop") || error.localizedDescription.contains("/stop") }
        let otherOK = (try? await registry.start(command: "true", workdir: nil, description: nil, turnRunId: UUID())) != nil
        check("B-reg6 launch tagged with a stopped run is refused; other runs launch", refused && otherOK)
        await TurnWakeCenter.shared.disarm()
        _ = await registry.purgeAllForWipe()
    }
}
