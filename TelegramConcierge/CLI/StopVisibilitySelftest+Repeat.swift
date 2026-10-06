import Foundation

/// Codex implementation review R1 (2026-10-05): a repeated /stop for an
/// already-announced run whose task ENDS DURING the repeat's own grace
/// wait. The repeat reserves its place in the run's ordered notices before
/// it awaits, so the run's completion queues behind it; the wording never
/// falls back to the fresh-stop or interrupted-request text.
///
/// SR1 wire (Chat Completions, the interrupted-turn marker branch) with the
/// first reply suspended on the wire — Codex's reproduction 1; SR2 captured
/// local command — Codex's reproduction 2; SR3/SR4 the same two over the
/// Responses ENVELOPE-CHECKPOINT OWNER branch (a real active-turn
/// compaction keeps the run active after /stop), including a repeat that
/// still finds the request running (the previously untested owner-branch
/// SV5 path); SR5 the reserved place vanishes (/deleteuserdata) → the reply
/// itself says it ended; SR6 series reservation units.
extension StopVisibilityHarness {

    func repeatSection() async {
        await reservationUnitRows()
        await repeatEndsInGraceWireRows(label: "SR1", envelope: false)
        await repeatEndsInGraceLocalRows(label: "SR2", envelope: false)
        await withEnvelopeProvider {
            await self.repeatEndsInGraceWireRows(label: "SR3", envelope: true)
            await self.repeatEndsInGraceLocalRows(label: "SR4", envelope: true)
        }
        await reservationVanishedRows()
    }

    // MARK: Units

    /// SR6: reserve / resolve / withdraw on a local series (synchronous
    /// emit): nothing passes an unresolved reservation, a terminal notice
    /// queued behind it waits, and an invalidated series refuses the fill.
    private func reservationUnitRows() async {
        let log = SVNoticeLog()
        let series = NoticeSeries(localEmit: { log.items.append($0) }, awaitingCapture: false)
        series.append("first")
        let slot = series.reserve()
        series.append("✅ done", terminal: true)
        check("SR6 nothing passes an unresolved reservation (a terminal notice waits behind it)",
              slot != nil && log.items == ["first"], "\(log.items)")
        check("SR6 a reservation can be added only before the terminal notice", series.reserve() == nil)
        let filled = slot.map { series.resolve($0, text: "repeat reply") } ?? false
        check("SR6 resolving releases the reservation, then the terminal notice, in order",
              filled && log.items == ["first", "repeat reply", "✅ done"], "\(log.items)")
        let withdrawn = NoticeSeries(localEmit: { log.items.append($0) }, awaitingCapture: false)
        let w = withdrawn.reserve()
        withdrawn.append("after", terminal: true)
        let before = log.items.count
        _ = w.map { withdrawn.resolve($0, text: nil) }
        check("SR6 a withdrawn reservation lets the next item go", log.items.count == before + 1 && log.items.last == "after")
        let closed = NoticeSeries(localEmit: { log.items.append($0) }, awaitingCapture: false)
        let c = closed.reserve()
        closed.invalidate()
        check("SR6 an invalidated series refuses the fill (caller falls back)",
              c.map { closed.resolve($0, text: "late") } == false && log.items.last == "after")
    }

    // MARK: Wire

    /// Codex reproduction 1 (+ its envelope-owner variant): the first reply
    /// is suspended on the wire; a repeat starts; the task ends during the
    /// repeat's grace. Nothing may overtake the suspended reply; final order
    /// is reply → repeat → one completion, with no interrupted-request or
    /// fresh-stop wording. Over the envelope owner, a middle repeat also
    /// finds the request still running ("Already stopping … still finishing").
    private func repeatEndsInGraceWireRows(label: String, envelope: Bool) async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        defer { hold.release(); channel.release(call: 1); server.router = nil; server.concurrent = false }
        let run = envelope ? await startEnvelopeHeldTurn(manager, hold: hold, tag: label)
                           : await startHeldTurn(manager, hold: hold, callId: "\(label.lowercased())-repeat")
        guard let run else { check("\(label) setup", false); return }
        channel.hold(call: 1)
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.hasStarted(call: 1) }
        if envelope {
            check("\(label) envelope checkpoint owner: the stopped run stays active after /stop (owner branch exercised)",
                  manager._svActiveRunId == run, "active \(String(describing: manager._svActiveRunId)) run \(run)")
            // The previously untested owner-branch repeat that still finds
            // the request running: decided "still finishing", queued behind.
            _ = await timedStop(manager)
        }
        Task { @MainActor in
            await self.sleep(0.25)
            hold.release()
        }
        _ = await timedStop(manager)
        await sleep(0.3)
        check("\(label) a repeat whose request ended during its wait cannot overtake the suspended first reply",
              channel.stopTexts.isEmpty && !channel.hasStarted(call: 2), "\(channel.events)")
        channel.release(call: 1)
        let expected = envelope ? 4 : 3
        _ = await waitUntil(timeout: 15) { channel.stopTexts.count >= expected }
        await finish(manager, nil)
        await sleep(0.5)
        let texts = channel.stopTexts
        let repeatReply = texts.count == expected ? texts[expected - 2] : ""
        check("\(label) final order: first reply\(envelope ? ", still-finishing repeat" : ""), repeat, one completion last",
              texts.count == expected && texts[0].hasPrefix("⛔ Stop requested.")
                && (!envelope || texts[1].hasPrefix("⛔ Already stopping. The request is still finishing: bash"))
                && texts[expected - 1].hasPrefix("✅ The stopped request has ended.")
                && texts.filter { $0.hasPrefix("✅") }.count == 1, "\(texts)")
        check("\(label) the repeat reply is \"Already stopping.\" — never the interrupted-request or fresh-stop wording",
              repeatReply.hasPrefix(ConversationManager.repeatEndedWithCompletionLead)
                && !repeatReply.contains("still finishing") && !repeatReply.contains("won't resume")
                && !repeatReply.contains("I stopped the current work"), repeatReply)
        check("\(label) the repeat joined the run's one series and nothing was parked",
              manager._svParkedTexts.isEmpty && manager.stoppedRunsFinishing.isEmpty, "\(manager._svParkedTexts)")
    }

    // MARK: Local (captured command)

    /// Codex reproduction 2 (+ envelope variant): both stops through the
    /// delivery-aware `handleTerminalCommand`; the task ends during the
    /// repeat's grace. Order: first result → repeat result → completion.
    private func repeatEndsInGraceLocalRows(label: String, envelope: Bool) async {
        let manager = await freshManager()
        let order = SVNoticeLog()
        manager.stopNoticeEvents.sink { order.items.append("notice:" + $0) }.store(in: &cancellables)
        let hold = SVToolHold(tool: "bash")
        defer { hold.release(); server.router = nil; server.concurrent = false }
        let run = envelope ? await startEnvelopeHeldTurn(manager, hold: hold, tag: label)
                           : await startHeldTurn(manager, hold: hold, callId: "\(label.lowercased())-local")
        guard let run else { check("\(label) setup", false); return }
        await manager.handleTerminalCommand("/stop") { lines in
            order.items.append("first-result:" + (lines ?? []).joined(separator: "|"))
        }
        if envelope {
            check("\(label) envelope checkpoint owner: the stopped run stays active after the captured /stop",
                  manager._svActiveRunId == run)
        }
        Task { @MainActor in
            await self.sleep(0.25)
            hold.release()
        }
        await manager.handleTerminalCommand("/stop") { lines in
            order.items.append("repeat-result:" + (lines ?? []).joined(separator: "|"))
        }
        await finish(manager, nil)
        await sleep(0.3)
        let items = order.items
        let firstIndex = items.firstIndex { $0.hasPrefix("first-result:⛔ Stop requested.") }
        let repeatIndex = items.firstIndex { $0.hasPrefix("repeat-result:") }
        let completionIndex = items.firstIndex { $0.hasPrefix("notice:✅") }
        check("\(label) local order: first result, repeat result, then the completion",
              firstIndex != nil && repeatIndex != nil && completionIndex != nil
                && firstIndex! < repeatIndex! && repeatIndex! < completionIndex!, "\(items)")
        let repeatLine = repeatIndex.map { items[$0] } ?? ""
        check("\(label) local repeat reply is \"Already stopping.\", one completion",
              repeatLine.hasPrefix("repeat-result:" + ConversationManager.repeatEndedWithCompletionLead)
                && !repeatLine.contains("won't resume") && !repeatLine.contains("I stopped the current work")
                && items.filter { $0.hasPrefix("notice:✅") }.count == 1, "\(items)")
    }

    // MARK: Reservation vanished

    /// SR5: the repeat reserved its place, then /deleteuserdata retired the
    /// series during the wait and the task ended: the reply goes out on the
    /// ordinary path and itself says the request ended; nothing else from
    /// the retired series.
    private func reservationVanishedRows() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel)
        let hold = SVToolHold(tool: "bash")
        defer { hold.release() }
        guard await startHeldTurn(manager, hold: hold, callId: "sr5-repeat") != nil else { check("SR5 setup", false); return }
        _ = await timedStop(manager)
        _ = await waitUntil(timeout: 5) { channel.stopTexts.count == 1 }
        Task { @MainActor in
            await self.sleep(0.15)
            manager._svRetireForWipe()
            await self.sleep(0.15)
            hold.release()
        }
        _ = await timedStop(manager)
        await finish(manager, nil)
        await sleep(0.5)
        let texts = channel.stopTexts
        check("SR5 reserved place gone: the repeat says the request ended, no completion from the retired series",
              texts.count == 2 && texts[1].hasPrefix(ConversationManager.repeatEndedLead), "\(texts)")
    }

    // MARK: Envelope-checkpoint owner fixture

    /// Runs `body` with the provider on the Responses protocol and a context
    /// budget small enough for a real active-turn compaction; restores the
    /// chat-completions provider afterwards.
    private func withEnvelopeProvider(_ body: () async -> Void) async {
        do {
            try ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                             model: "fixture-model", effort: nil, textOnly: false, wireProtocol: .responses)
            try ProviderProfiles.activate(.custom)
            try KeychainHelper.saveBatch([KeychainHelper.maxContextTokensKey: "250000",
                                          KeychainHelper.targetContextTokensKey: "70000",
                                          KeychainHelper.archiveChunkSizeKey: "1000000"].mapValues { Optional($0) })
        } catch { check("SR envelope provider setup", false, "\(error)"); return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sv-envelope-\(UUID().uuidString).txt")
        try? Data(((0..<100).map { _ in String(repeating: "ENVELOPE_EVIDENCE ", count: 46) }.joined(separator: "\n")).utf8).write(to: file)
        envelopeSourcePath = file.path
        await body()
        try? FileManager.default.removeItem(at: file)
        for key in [KeychainHelper.maxContextTokensKey, KeychainHelper.targetContextTokensKey, KeychainHelper.archiveChunkSizeKey] {
            try? KeychainHelper.delete(key: key)
        }
        try? ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                          model: "glm-5.3", effort: nil, textOnly: false, wireProtocol: .chatCompletions)
        try? ProviderProfiles.activate(.custom)
        try? configureProvider()
    }

    /// A Responses turn that reads a large file every round until a real
    /// active-turn compaction ran (the checkpoint becomes an envelope), then
    /// issues one bash call held in its body. Returns the run id once held.
    private func startEnvelopeHeldTurn(_ manager: ConversationManager, hold: SVToolHold, tag: String) async -> UUID? {
        guard ProviderProfiles.usesResponses, let path = envelopeSourcePath else { return nil }
        let script = SVEnvelopeScript(path: path, bashCallId: "\(tag.lowercased())-env-bash")
        server.concurrent = true
        server.router = { script.route($0) }
        let before = hold.arrived
        manager._testStartTurn(for: user("\(tag) read the file until compacted, then run the held command"))
        let run = manager._svActiveRunId
        guard await waitUntil(timeout: 120, { hold.arrived > before }) else { return nil }
        check("\(tag) fixture: a real active-turn compaction ran before the held command", script.compactions > 0,
              "compactions \(script.compactions), rounds \(script.rounds)")
        return run
    }
}

/// Scripted Responses main agent for the envelope fixture.
final class SVEnvelopeScript: @unchecked Sendable {
    private let lock = NSLock()
    let path: String
    let bashCallId: String
    private var _rounds = 0
    private var _compactions = 0
    private var bashIssued = false
    init(path: String, bashCallId: String) { self.path = path; self.bashCallId = bashCallId }
    var rounds: Int { lock.lock(); defer { lock.unlock() }; return _rounds }
    var compactions: Int { lock.lock(); defer { lock.unlock() }; return _compactions }

    func route(_ request: CapturedHTTPRequest) -> (body: String, delay: TimeInterval)? {
        let text = String(decoding: request.body, as: UTF8.self)
        let tokens = request.body.count / 3
        lock.lock(); defer { lock.unlock() }
        func reply(_ text: String?, _ calls: [(id: String, name: String, args: [String: Any])]) -> String {
            MidturnHarness.CompactionScript.reply(responses: true, text: text, calls: calls, tokens: tokens)
        }
        if text.contains("ACTIVE TURN COMPACTION") {
            _compactions += 1
            return (reply("Goal: read the file, then run the held command.", []), 0)
        }
        if text.contains("[PRUNE SUMMARY") { return (reply("Earlier turn summary.", []), 0) }
        _rounds += 1
        if bashIssued || _rounds >= 60 { return (reply("SR_ENVELOPE_FINAL", []), 0.05) }
        if _compactions > 0 {
            bashIssued = true
            return (reply(nil, [(id: bashCallId, name: "bash", args: ["command": "true"])]), 0.05)
        }
        return (reply(nil, [(id: "read\(_rounds)", name: "read_file", args: ["path": path, "limit": 200])]), 0.05)
    }
}
