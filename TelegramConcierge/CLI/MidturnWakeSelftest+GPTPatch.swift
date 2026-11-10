import Foundation

/// GPT apply_patch S2, Codex round 1 R2 (GPT_APPLY_PATCH_PLAN §12.2): owner-
/// level `/stop` while a GPT patch is committing. The patch worker is held
/// after the engine committed; the run is stopped; then the worker is
/// released. The interrupted history must carry the patch's real result
/// (never "outcome unknown" or a lost batch), and the cancelled round must
/// earn no GPT evidence — an older GPT record stays as it was (§21 note 3).
extension MidturnHarness {

    func gptPatchOwnerSection() async throws {
        // Earlier sections may leave another profile (Responses, SIWC) active.
        try ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                         model: "gpt-6-luna", effort: nil, textOnly: false, wireProtocol: .chatCompletions)
        try ProviderProfiles.activate(.custom)
        try configureProvider()
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "gpt-6-luna")
        GPTPatchSwitch.storedOverrideForTesting = { nil }
        defer {
            try? KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "glm-5.3")
            ToolExecutor.gptPatchWorkerHookForTesting = nil
            GPTPatchSwitch.storedOverrideForTesting = nil
        }
        let dir = StoragePaths.dataRoot.deletingLastPathComponent().appendingPathComponent("gp-owner-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path

        func patch(_ name: String) -> String { "*** Begin Patch\n*** Update File: \(resolved)/\(name)\n@@\n-old\n+new\n*** End Patch" }

        /// Seeds `name` and an older GPT record for it; returns that record's identity.
        func seed(_ name: String) async -> FileIdentity? {
            let path = resolved + "/" + name
            try? Data("old\n".utf8).write(to: URL(fileURLWithPath: path))
            let key = CodexPatch.evidenceKey(path)
            guard let id = (try? FileIdentity.lstatPath(key)) ?? nil else { return nil }
            await FileTimeTracker.shared.publishGPT(GPTEvidence.Receipt(key: key, identity: id, source: .gptReadFile))
            return id
        }

        /// One stopped run: returns the manager after it went idle.
        func stoppedRun(_ replies: [String], file: String, label: String, callID: String) async -> ConversationManager {
            let manager = await freshManager()
            let gate = GPTProfileSelftest.GateBox()
            ToolExecutor.gptPatchWorkerHookForTesting = { await gate.wait() }
            server.script(replies)
            manager._testStartTurn(for: user("edit \(label)"))
            let committed = await waitUntil(timeout: 30) {
                GPTPatchSettlement.shared.isCommitting && (try? String(contentsOfFile: resolved + "/" + file, encoding: .utf8)) == "new\n"
            }
            check("gptpatch \(label): the patch committed and is held in its worker", committed)
            await manager._testStop()
            await gate.open()
            _ = await manager._testAwaitIdle(timeout: 60)
            // The stopped task records its interrupted outcome after the run
            // is no longer active: wait for that salvage (bounded).
            _ = await waitUntil(timeout: 30) {
                if self.results(manager).contains(where: { $0.toolCallId == callID }) { return true }
                let sessions = await SubagentSessionRegistry.shared.list(limit: 50).sessions
                return sessions.contains { $0.toolInteractions.contains { $0.results.contains { $0.toolCallId == callID } } }
            }
            ToolExecutor.gptPatchWorkerHookForTesting = nil
            return manager
        }

        // 1. Chat Completions, direct apply_patch: the batch used to be lost.
        do {
            let older = await seed("a.txt")
            let manager = await stoppedRun([Self.chatTools([("gp_c1", "apply_patch", ["input": patch("a.txt")])]), Self.chatText("done")],
                                           file: "a.txt", label: "chat direct", callID: "gp_c1")
            let r = results(manager).first { $0.toolCallId == "gp_c1" }
            check("gptpatch chat direct: the interrupted history carries the real patch result (Codex S2 R2)",
                  r?.content.hasPrefix("Success. Updated the following files:") == true, r?.content ?? "no result")
            let record = await FileTimeTracker.shared.gptRecord(forKey: CodexPatch.evidenceKey(resolved + "/a.txt"))
            check("gptpatch chat direct: the cancelled round earned no evidence; the older record is not refreshed",
                  older != nil && record?.identity == older && record?.source == .gptReadFile)
        }
        // 2. Chat Completions, intercepted heredoc.
        do {
            _ = await seed("b.txt")
            let heredoc = "apply_patch <<'EOF'\n\(patch("b.txt"))\nEOF"
            let manager = await stoppedRun([Self.chatTools([("gp_c2", "bash", ["command": heredoc])]), Self.chatText("done")],
                                           file: "b.txt", label: "chat heredoc", callID: "gp_c2")
            let r = results(manager).first { $0.toolCallId == "gp_c2" }
            check("gptpatch chat heredoc: the interrupted history carries the real patch result",
                  r?.content.hasPrefix("Success. Updated the following files:") == true, r?.content ?? "no result")
        }
        // 3. Responses: the "outcome unknown" placeholder is replaced.
        do {
            try ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                             model: "gpt-6-luna", effort: nil, textOnly: false, wireProtocol: .responses)
            try ProviderProfiles.activate(.custom)
            defer {
                try? ProviderProfiles.saveProfile(.custom, apiKey: apiKey, baseURL: "http://127.0.0.1:\(server.port)/v1",
                                                  model: "gpt-6-luna", effort: nil, textOnly: false, wireProtocol: .chatCompletions)
                try? ProviderProfiles.activate(.custom)
                try? configureProvider()
                try? KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "gpt-6-luna")
            }
            _ = await seed("c.txt")
            let call: [String: Any] = ["type": "function_call", "id": "fc_gp", "status": "completed", "call_id": "gp_c3",
                                       "name": "apply_patch", "arguments": GPTFreeform.canonicalArguments(patch("c.txt")) ?? "{}"]
            let manager = await stoppedRun([GPTProfileSelftest.reply([call]), GPTProfileSelftest.reply([GPTProfileSelftest.doneText])],
                                           file: "c.txt", label: "responses", callID: "gp_c3")
            let r = results(manager).first { $0.toolCallId == "gp_c3" }
            check("gptpatch responses: the placeholder is replaced by the real patch result",
                  r?.content.hasPrefix("Success. Updated the following files:") == true && r?.outcomeBinding?.kind != .interruptedIntent,
                  r?.content ?? "no result")
        }
        // 4. A child: the parent's stop cancels the child's batch while its
        // patch worker is held; the child joins the worker and records it.
        do {
            _ = await seed("d.txt")
            await SubagentSessionRegistry.shared.removeAll()
            let manager = await stoppedRun([
                Self.chatTools([("gp_a1", "Agent", ["subagent_type": "general-purpose", "description": "patch d", "prompt": "patch d.txt"])]),
                Self.chatTools([("gp_c4", "apply_patch", ["input": patch("d.txt")])]),
                Self.chatText("child done"), Self.chatText("done")], file: "d.txt", label: "child", callID: "gp_c4")
            _ = manager
            let sessions = await SubagentSessionRegistry.shared.list(limit: 50).sessions
            let childResult = sessions.flatMap { $0.toolInteractions.flatMap(\.results) }.first { $0.toolCallId == "gp_c4" }
            check("gptpatch child: the child's committed patch reaches its session history (Codex S2 R2)",
                  childResult?.content.hasPrefix("Success. Updated the following files:") == true,
                  childResult?.content ?? "no child result in \(sessions.count) session(s)")
        }
        // 5. Fast completion (Codex S2 round 2): the worker is released while
        // /stop waits in its grace period; the run ends within it, so the
        // stop reply itself must name the applied edit.
        do {
            _ = await seed("e.txt")
            let manager = await freshManager()
            let gate = GPTProfileSelftest.GateBox()
            ToolExecutor.gptPatchWorkerHookForTesting = { await gate.wait() }
            let box = ReplyBox()
            ConversationManager.stopReplyObserverForTesting = { box.set($0) }
            defer { ConversationManager.stopReplyObserverForTesting = nil; ToolExecutor.gptPatchWorkerHookForTesting = nil }
            server.script([Self.chatTools([("gp_c5", "apply_patch", ["input": patch("e.txt")])]), Self.chatText("done")])
            manager._testStartTurn(for: user("edit fast"))
            let committed = await waitUntil(timeout: 30) {
                GPTPatchSettlement.shared.isCommitting && (try? String(contentsOfFile: resolved + "/e.txt", encoding: .utf8)) == "new\n"
            }
            let stopTask = Task { await manager._testStop() }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await gate.open()
            await stopTask.value
            _ = await manager._testAwaitIdle(timeout: 30)
            let reply = box.value ?? ""
            check("gptpatch fast completion: the stop reply names the applied edit (Codex S2 round 2)",
                  committed && reply.contains("The file edit was applied to 1 file") && !reply.contains("still finishing"), reply)
        }
        // 6. Pre-release review B1: two patches in one round run one after
        // the other. /stop while the first is held: it keeps its real result;
        // the second, still waiting for its turn, never runs and is recorded
        // as not started (typed not_executed), not "outcome unknown".
        do {
            _ = await seed("f.txt")
            _ = await seed("g.txt")
            let manager = await stoppedRun([Self.chatTools([("gp_c6a", "apply_patch", ["input": patch("f.txt")]),
                                                            ("gp_c6b", "apply_patch", ["input": patch("g.txt")])]),
                                            Self.chatText("done")],
                                           file: "f.txt", label: "queued", callID: "gp_c6b")
            let first = results(manager).first { $0.toolCallId == "gp_c6a" }
            let second = results(manager).first { $0.toolCallId == "gp_c6b" }
            check("gptpatch queued: the held first patch keeps its real result",
                  first?.content.hasPrefix("Success. Updated the following files:") == true, first?.content ?? "no result")
            check("gptpatch queued: the second patch never ran and is recorded as not started (pre-release review B1)",
                  second?.content == GPTPatchSettlement.notStartedText && second?.outcomeBinding?.kind == .notExecuted
                  && (try? String(contentsOfFile: resolved + "/g.txt", encoding: .utf8)) == "old\n",
                  "\(second?.content ?? "no result") \(String(describing: second?.outcomeBinding?.kind))")
        }
        try? FileManager.default.removeItem(atPath: dir)
    }
}

final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    func set(_ v: String) { lock.lock(); _value = v; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return _value }
}
