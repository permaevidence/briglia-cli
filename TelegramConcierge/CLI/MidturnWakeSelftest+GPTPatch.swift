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
        try? FileManager.default.removeItem(atPath: dir)
    }
}
