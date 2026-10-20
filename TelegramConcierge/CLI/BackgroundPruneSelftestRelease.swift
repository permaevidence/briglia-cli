import Foundation

/// Release coverage required by Codex's implementation review round 2
/// (answer 4): real Responses error plumbing (E, §16.4), image recovery
/// followed by convergence, concurrent main/summary receipt ownership on
/// Responses (B17), attachment lifetime after a freeze at M and at T0 (F4),
/// a suffix-bearing forced-final D (B4b d-ff), B16's held first attempt
/// with a configuration change and a refusal retry on both protocols, and
/// the Mind-import / local-setting matrix (B19).
enum BackgroundPruneSelftestRelease {
    static let contextBody = "{\"error\":{\"message\":\"This model's maximum context length was exceeded\",\"code\":400}}"

    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        await responsesErrors(h)
        await imageRecoveryThenConvergence(h)
        await responsesReceiptOwnership(h)
        await attachmentLifetime(h, atM: true)
        await attachmentLifetime(h, atM: false)
        await suffixBearingFinalAdmission(h)
        for responses in [false, true] { await frozenExecutionTemporal(h, responses: responses) }
        await mindAndSettingMatrix(h)
    }

    // MARK: protocol helpers

    @MainActor static func useResponses(_ h: BackgroundPruneSelftestHarness) {
        try? ProviderProfiles.saveProfile(.custom, apiKey: h.apiKey, baseURL: "http://127.0.0.1:\(h.server.port)/v1",
                                          model: h.model, effort: nil, textOnly: false, wireProtocol: .responses)
        try? ProviderProfiles.activate(.custom)
    }

    @MainActor static func useChat(_ h: BackgroundPruneSelftestHarness) {
        try? ProviderProfiles.saveProfile(.custom, apiKey: h.apiKey, baseURL: "http://127.0.0.1:\(h.server.port)/v1",
                                          model: h.model, effort: nil, textOnly: false, wireProtocol: .chatCompletions)
        try? ProviderProfiles.activate(.custom)
        try? h.configureProvider()
    }

    @MainActor static func pngFile(_ h: BackgroundPruneSelftestHarness, _ name: String) -> String {
        let url = h.filesRoot.appendingPathComponent(name)
        try? IRFixtures.png.write(to: url)
        return url.path
    }

    // MARK: E — Responses HTTP/SSE plumbing

    /// §16.4: Responses HTTP 400 (context body and generic body) and SSE
    /// `error` with `context_length_exceeded` converge in band; SSE with
    /// another code and 401/429/503 surface the original error.
    @MainActor static func responsesErrors(_ h: BackgroundPruneSelftestHarness) async {
        let sse = { (code: String) in "data: {\"type\":\"error\",\"code\":\"\(code)\",\"message\":\"stream failure \(code)\"}\n\n" }
        let cases: [(label: String, status: Int, body: String, eligible: Bool)] = [
            ("HTTP 400 context-length body", 400, "{\"error\":{\"message\":\"Your input exceeds the context window of this model.\",\"type\":\"invalid_request_error\",\"code\":\"context_length_exceeded\"}}", true),
            ("HTTP 400 generic body", 400, "{\"error\":{\"message\":\"Invalid request.\",\"type\":\"invalid_request_error\"}}", true),
            ("SSE error context_length_exceeded", 200, sse("context_length_exceeded"), true),
            ("SSE error server_error", 200, sse("server_error"), false),
            ("HTTP 401", 401, "{\"error\":{\"message\":\"bad key\"}}", false),
            ("HTTP 429", 429, "{\"error\":{\"message\":\"slow down\"}}", false),
            ("HTTP 503", 503, "{\"error\":{\"message\":\"unavailable\"}}", false),
        ]
        for c in cases {
            let manager = await h.freshManager(history: h.prunableHistory())
            useResponses(h)
            manager.bgPruneTestSetLastPromptTokens(1_000)
            h.observeMainRequests()
            if c.eligible {
                h.server.script([c.body, BackgroundPruneSelftestHarness.rText("recovered after convergence")], statuses: [c.status, 200])
            } else {
                h.server.script(Array(repeating: c.body, count: 8), statuses: Array(repeating: c.status, count: 8))
            }
            manager._testStartTurn(for: Message(role: .user, content: "Responses in band: \(c.label)"))
            _ = await manager._testAwaitIdle(timeout: 90)
            h.server.requestObserver = nil
            if c.eligible {
                h.check("E Responses \(c.label) → one reduction (inline) and one resend",
                        manager._testLastError == nil && h.eventCount("bgprune.converge.reduce") == 1
                        && h.eventCount("bgprune.converge.resent") == 1 && h.eventCount(prefix: "bgprune.helper.") == 1
                        && h.server.completeRequests.allSatisfy { !BackgroundPruneSelftestRouter.isMain($0) || $0.target.hasSuffix("/responses") },
                        "error \(String(describing: manager._testLastError)) events \(h.allEvents)")
            } else {
                h.check("E Responses \(c.label) → original error, no convergence",
                        manager._testLastError != nil && h.eventCount(prefix: "bgprune.converge") == 0 && h.router.summaries == 0,
                        "error \(String(describing: manager._testLastError)) events \(h.allEvents)")
            }
            server(h, reset: true)
        }
        useChat(h)
    }

    @MainActor static func server(_ h: BackgroundPruneSelftestHarness, reset: Bool) {
        h.server.clear()
        h.server.script([])
    }

    // MARK: image recovery followed by convergence

    /// §16.4: an image rejection is recovered first (the image is marked,
    /// the request rebuilt without it, one notice); the rebuilt request then
    /// fails in band and converges once. The image resend does not consume
    /// the convergence allowance, the mark survives the reduction and the
    /// final request carries neither the image nor the pruned output.
    @MainActor static func imageRecoveryThenConvergence(_ h: BackgroundPruneSelftestHarness) async {
        let name = "bgprune-old.png"
        let images = StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
        var history = [Message(role: .user, content: "look at this earlier picture", imageFileNames: [name]),
                       Message(role: .assistant, content: "seen")]
        history += h.prunableHistory()
        let manager = await h.freshManager(history: history)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try? IRFixtures.png.write(to: images.appendingPathComponent(name))
        manager.bgPruneTestSetLastPromptTokens(1_000)
        h.observeMainRequests()
        h.server.script([IRFixtures.openAIChatBMP, contextBody, BackgroundPruneSelftestHarness.chat("done after both recoveries", prompt: 100)],
                        statuses: [400, 400, 200])
        manager._testStartTurn(for: Message(role: .user, content: "image rejection, then an in-band failure"))
        _ = await manager._testAwaitIdle(timeout: 60)
        h.server.requestObserver = nil
        let bodies = h.mainRequests.map { h.bodyText($0) }
        let image = IRFixtures.png.base64EncodedString()
        let marked = manager._testMessages.first { $0.imageFileNames == [name] }?.providerRejectedImageFileNames ?? []
        let saved = (try? String(contentsOf: StoragePaths.dataRoot.appendingPathComponent("conversation.json"), encoding: .utf8)) ?? ""
        h.check("E image recovery, then convergence: three main requests, one reduction, one resend, success",
                manager._testLastError == nil && bodies.count == 3 && h.eventCount("bgprune.converge.reduce") == 1
                && h.eventCount("bgprune.converge.resent") == 1 && h.eventCount(prefix: "bgprune.helper.") == 1,
                "error \(String(describing: manager._testLastError)) main \(bodies.count) events \(h.allEvents)")
        h.check("E the image mark survives the reduction (memory and disk); later requests carry no image",
                marked == [name] && saved.contains("\"providerRejectedImageFileNames\":[\"\(name)\"]")
                && bodies.count == 3 && bodies[0].contains(image) && !bodies[1].contains(image) && !bodies[2].contains(image))
        h.check("E the convergence resend was rebuilt from the reduced history (pruned output gone)",
                bodies.count == 3 && bodies[1].contains("RESULT-h-call-0 ") && !bodies[2].contains("RESULT-h-call-0 "))
        // The image notice follows a successful image-recovery retry; here that
        // retry fails in band (as in 0.2.56, where the turn then fails), so no
        // image notice is sent and none is duplicated (disclosed).
        h.check("E no duplicate image notice across the image retry and the convergence resend",
                h.channel.delivered.filter { $0.hasPrefix("⚠️ The provider rejected an image") }.count <= 1, "\(h.channel.delivered)")
    }

    // MARK: B17 — receipts on Responses with a concurrent summary

    /// A mid-turn message is delivered in the main request that is in
    /// flight while the background summary (also Responses) completes: the
    /// summary's receipt never settles or requeues the main batch, so the
    /// message reaches the model once and is not delivered again.
    @MainActor static func responsesReceiptOwnership(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        useResponses(h)
        h.router.holdSummaries = [1]
        let mainGate = BackgroundPruneSelftestGate()
        let router = h.router
        let log = h.log
        let count = BackgroundPruneSelftestLog()
        h.server.router = { request in
            if BackgroundPruneSelftestRouter.isMain(request) {
                log.append("request.main")
                count.append("x")
                if count.all.count == 2 { mainGate.wait() }
                return nil
            }
            return router.route(request)
        }
        manager.bgPruneTestSetLastPromptTokens(60_000)
        h.server.script([BackgroundPruneSelftestHarness.rTools([(id: "rx-bash", name: "bash", args: ["command": "sleep 1.5; echo rx"])]),
                         BackgroundPruneSelftestHarness.rText("answered with the note"),
                         BackgroundPruneSelftestHarness.rText("spare")])
        manager._testStartTurn(for: Message(role: .user, content: "start a short command"))
        await h.sleep(0.4)
        let note = "mid-turn note for the receipt test"
        await manager._testDispatchUser(Message(role: .user, content: note))
        let held = await h.waitUntil(timeout: 30) { mainGate.arrived == 1 }
        h.router.gate.release()
        let ready = await h.waitPhase(manager, "ready", timeout: 30)
        mainGate.release()
        _ = await manager._testAwaitIdle(timeout: 60)
        await h.sleep(0.5)
        _ = await manager._testAwaitIdle(timeout: 30)
        let mains = h.server.completeRequests.filter(BackgroundPruneSelftestRouter.isMain)
        let delivered = mains.filter { h.bodyText($0).contains(note) }.count
        let inHistory = manager._testMessages.filter { $0.content == note }.count
        h.check("B17 precondition: the summary completed while the main Responses request was in flight", held && ready,
                "held \(held) ready \(ready) phase \(manager.bgPruneTestPhase)")
        h.check("B17 the mid-turn note reached the model once and was not redelivered after the summary completed",
                delivered == 1 && inHistory == 1 && mains.count == 2 && manager._testLastError == nil,
                "delivered \(delivered) history \(inHistory) main \(mains.count) error \(String(describing: manager._testLastError))")
        useChat(h)
    }

    // MARK: F4 — attachment lifetime

    /// A file attached after the freeze stays readable after the apply,
    /// at M (current rounds passed as live) and at T0 (round in history).
    @MainActor static func attachmentLifetime(_ h: BackgroundPruneSelftestHarness, atM: Bool) async {
        let site = atM ? "M" : "T0"
        let manager = await h.freshManager(history: h.prunableHistory())
        h.router.holdSummaries = [1]
        let png = pngFile(h, "f4-\(site).png")
        let toolGate = BackgroundPruneSelftestGate()
        if atM { ToolExecutor.toolBodyHoldForTesting = { name in if name == "read_file" { toolGate.wait() } } }
        manager.bgPruneTestSetLastPromptTokens(60_000)
        h.server.script([BackgroundPruneSelftestHarness.tools([(id: "f4-read", name: "read_file", args: ["path": png])], prompt: 1_000),
                         BackgroundPruneSelftestHarness.chat("looked at it", prompt: 1_000)])
        manager._testStartTurn(for: Message(role: .user, content: "attach a file after the freeze (\(site))"))
        if atM {
            _ = await h.waitUntil { toolGate.arrived == 1 }
            h.router.gate.release()
            _ = await h.waitPhase(manager, "ready")
            toolGate.release()
            _ = await manager._testAwaitIdle(timeout: 40)
            ToolExecutor.toolBodyHoldForTesting = nil
        } else {
            _ = await manager._testAwaitIdle(timeout: 40)
            h.router.gate.release()
            _ = await h.waitPhase(manager, "ready")
            manager.bgPruneTestSetLastPromptTokens(1_000)
            _ = await h.turn(manager, "apply at the next turn start")
        }
        let snapshots = manager._testMessages.flatMap { $0.toolInteractions }.flatMap { $0.results }
            .flatMap { $0.fileAttachmentReferences }.compactMap { $0.snapshotPath }
        let present = snapshots.filter { FileManager.default.fileExists(atPath: $0) }
        h.check("F4 a file attached after the freeze stays readable after the apply at \(site)",
                h.eventCount("bgprune.applied") == 1 && !snapshots.isEmpty && present.count == snapshots.count,
                "applied \(h.eventCount("bgprune.applied")) snapshots \(snapshots.count) present \(present.count) events \(h.allEvents) rounds \(manager._testMessages.map { "\($0.role):\($0.toolInteractions.map { $0.results.map { "\($0.toolCallId)/\($0.fileAttachmentReferences.count)/\($0.content.prefix(80))" } })" })")
    }

    // MARK: B4b(d-ff) with a refusal suffix

    /// Forced final: attempt 0 is below C; its tool-refusal response adds
    /// the refusal interaction, which takes attempt 1 to ≥ C. D at attempt
    /// 1 must count the suffix (apply then), and the suffix-free estimate
    /// (attempt 0) would not have crossed C.
    @MainActor static func suffixBearingFinalAdmission(_ h: BackgroundPruneSelftestHarness) async {
        final class Estimates: @unchecked Sendable {
            let lock = NSLock(); var items: [(key: String, estimate: Int, ceiling: Int)] = []
            func add(_ detail: String) {
                let parts = detail.split(separator: " ")
                guard parts.count == 3, let e = Int(parts[1]), let c = Int(parts[2]) else { return }
                lock.lock(); items.append((String(parts[0]), e, c)); lock.unlock()
            }
            var all: [(key: String, estimate: Int, ceiling: Int)] { lock.lock(); defer { lock.unlock() }; return items }
        }
        let refusal = BackgroundPruneSelftestHarness.tools([(id: "ff-refused", name: "read_file",
                                                             args: ["file_path": String(repeating: "y", count: 60_000)])], prompt: 1_000)
        func scenario(window: Int?) async -> (ConversationManager, [(key: String, estimate: Int, ceiling: Int)]) {
            let manager = await h.freshManager(history: h.prunableHistory())
            try? AgentTurnOverrides.setOverride(1, forAgent: "main")
            let estimates = Estimates()
            ConversationManager.bgPruneDetailForTesting = { name, detail in if name == "admit.estimate" { estimates.add(detail) } }
            let admitGate = BackgroundPruneSelftestGate()
            let arrivals = BackgroundPruneSelftestLog()
            ConversationManager.bgPruneHoldForTesting = { point in
                guard point.hasPrefix("admit.") else { return }
                arrivals.append(point)
                if arrivals.all.count == 2 { await admitGate.awaitRelease() }
            }
            h.router.holdSummaries = [1]
            manager.bgPruneTestSetLastPromptTokens(60_000)
            h.server.script([BackgroundPruneSelftestHarness.tools([BackgroundPruneSelftestMidLoop.readCall(h, "ff-read-1")], prompt: 1_000),
                             refusal, BackgroundPruneSelftestHarness.chat("final after refusal", prompt: 100)])
            manager._testStartTurn(for: Message(role: .user, content: "forced final with a refusal suffix"))
            _ = await h.waitUntil(timeout: 40) { admitGate.arrived == 1 }
            if let window { BackgroundPruneContextWindow.overrides = [h.model: window] }
            h.router.gate.release()
            _ = await h.waitPhase(manager, "ready")
            admitGate.release()
            _ = await manager._testAwaitIdle(timeout: 60)
            try? AgentTurnOverrides.setOverride(nil, forAgent: "main")
            ConversationManager.bgPruneHoldForTesting = nil
            ConversationManager.bgPruneDetailForTesting = nil
            BackgroundPruneContextWindow.overrides = [:]
            return (manager, estimates.all)
        }
        // Calibration (default ceiling): the two final attempts' estimates.
        let (_, calibration) = await scenario(window: nil)
        let finals = calibration.filter { $0.key != "round1" }
        guard finals.count >= 2, finals[1].estimate > finals[0].estimate + 2_000 else {
            h.check("B4b(d-ff) calibration: two final attempts, the refusal suffix raises the estimate", false, "\(calibration)")
            return
        }
        let ceiling = (finals[0].estimate + finals[1].estimate) / 2
        h.check("B4b(d-ff) calibration: the refusal suffix raises the final estimate (\(finals[0].estimate) → \(finals[1].estimate))", true)
        h.clearEvents()
        let (manager, observed) = await scenario(window: ceiling + BackgroundPruneCeiling.windowReserve)
        let finalObserved = observed.filter { $0.key != "round1" }
        h.check("B4b(d-ff) attempt 0 below C (suffix-free estimate does not cross), attempt 1 with the suffix ≥ C → apply there",
                finalObserved.count >= 2 && finalObserved[0].estimate < finalObserved[0].ceiling
                && finalObserved[1].estimate >= finalObserved[1].ceiling && h.eventCount("bgprune.admit.reduce") == 1
                && h.eventCount("bgprune.applied") == 1 && manager._testLastError == nil,
                "observed \(observed) events \(h.allEvents) error \(String(describing: manager._testLastError))")
        h.check("B4b(d-ff) the refused tool was not executed and one final logical request kept one allowance",
                finalObserved.allSatisfy { $0.key == finalObserved[0].key } && h.eventCount(prefix: "bgprune.helper.") <= 1,
                "\(observed) \(h.allEvents)")
    }

    // MARK: B16 — held first attempt, configuration change, refusal retry

    /// The first summary attempt is held, the parent turn finishes, the
    /// model setting changes, the held attempt returns tool calls and the
    /// retry is sent: both summary sends use the frozen model and protocol.
    @MainActor static func frozenExecutionTemporal(_ h: BackgroundPruneSelftestHarness, responses: Bool) async {
        let proto = responses ? "Responses" : "Chat Completions"
        let manager = await h.freshManager(history: h.prunableHistory())
        if responses { useResponses(h) }
        h.router.holdSummaries = [1]
        h.router.summaryReply = { n, isResponses in
            guard n == 1 else { return nil }
            // Chat: a tool-call reply provokes the tool-refusal retry. The
            // Responses summary is sent without tools (as in 0.2.56), so its
            // retry is provoked by a rejected (empty) reply instead.
            return isResponses
                ? BackgroundPruneSelftestHarness.rText("")
                : BackgroundPruneSelftestHarness.tools([(id: "sum-refused", name: "list_dir", args: ["path": "/"])], prompt: 100)
        }
        manager.bgPruneTestSetLastPromptTokens(60_000)
        let main = responses ? BackgroundPruneSelftestHarness.rText("parent done") : BackgroundPruneSelftestHarness.chat("parent done", prompt: 100)
        h.startTurn(manager, "freeze, finish, then change the model", replies: [main])
        let idle = await manager._testAwaitIdle(timeout: 40)
        if responses {
            try? ProviderProfiles.saveProfile(.custom, apiKey: h.apiKey, baseURL: "http://127.0.0.1:\(h.server.port)/v1",
                                              model: "changed-model-b", effort: "low", textOnly: false, wireProtocol: .chatCompletions)
            try? ProviderProfiles.activate(.custom)
        }
        try? KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "changed-model-b")
        h.router.gate.release()
        let ready = await h.waitPhase(manager, "ready", timeout: 40)
        let summaries = h.server.completeRequests.filter {
            h.bodyText($0).contains(BackgroundPruneSelftestRouter.summaryMarker) || h.bodyText($0).contains(BackgroundPruneSelftestRouter.summaryRetryMarker)
        }
        let expectedTarget = responses ? "/responses" : "/chat/completions"
        let frozen = summaries.allSatisfy { h.bodyText($0).contains("\"model\":\"\(h.model)\"") && !h.bodyText($0).contains("changed-model-b")
            && $0.target.hasSuffix(expectedTarget) }
        h.check("B16 \(proto): held first attempt, finished turn, changed model/protocol, retry → both sends frozen",
                idle && ready && summaries.count == 2 && frozen,
                "idle \(idle) ready \(ready) summaries \(summaries.map { $0.target }) phase \(manager.bgPruneTestPhase)")
        h.router.summaryReply = nil
        try? KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: h.model)
        useChat(h)
    }

    // MARK: B19 — Mind import and the local setting

    /// §12.4: the switch is a local preference. A Mind carrying a crafted
    /// field cannot turn it on; an import keeps the local value either way;
    /// an import with a ready job releases it (generation bump).
    @MainActor static func mindAndSettingMatrix(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory(pairs: 2, size: 200), switchOn: nil)
        let exportReply = await manager.bgPruneTestCommand("/exportmind lite")
        guard let path = firstMindPath(exportReply) else {
            h.check("B19 export a Mind to craft from", false, exportReply)
            return
        }
        let crafted = craftMind(source: path, extra: ["ada.pruneBackground": true, "pruneBackground": true, "backgroundPrune": true])
        h.check("B19 crafted Mind built (extra fields true)", crafted != nil)
        let cases: [(label: String, local: Bool?, archive: String?, expected: Bool?)] = [
            ("local absent + crafted extra field true", nil, crafted, nil),
            ("local OFF + crafted extra field true", false, crafted, false),
            ("local ON + plain Mind (field absent)", true, path, true),
            ("local ON + crafted Mind", true, crafted, true),
        ]
        for c in cases {
            guard let archive = c.archive else { continue }
            let target = await h.freshManager(history: h.prunableHistory(), switchOn: c.local)
            var released = true
            if c.local == true {
                _ = await h.frozenRunningJob(target, holdSummary: false)
                _ = await h.waitPhase(target, "ready")
                released = false
            }
            let generation = target.bgPruneTestGeneration
            let propose = await target.bgPruneTestCommand("/importmind \(archive)")
            let confirm = await target.bgPruneTestCommand("/importmind confirm")
            let stored = UserDefaults.standard.object(forKey: ConversationManager.backgroundPruneDefaultsKey) as? Bool
            if c.local == true { released = target.bgPruneTestPhase == "none" && target.bgPruneTestGeneration > generation }
            h.check("B19 \(c.label): the local switch is unchanged (\(String(describing: c.expected)))",
                    stored == c.expected, "stored \(String(describing: stored)) propose \(propose.prefix(200)) confirm \(confirm.prefix(300))")
            h.check("B19 \(c.label): import completed\(c.local == true ? " and released the ready job" : "")",
                    confirm.lowercased().contains("restor") || confirm.lowercased().contains("import") , confirm)
            if c.local == true { h.check("B19 \(c.label): ready job released by the import", released, "phase \(target.bgPruneTestPhase)") }
        }
    }

    static func firstMindPath(_ text: String) -> String? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) where token.hasSuffix(".mind") {
            return String(token)
        }
        return nil
    }

    /// Unzip a Mind archive, add `extra` to mind_config.json, zip it again.
    static func craftMind(source: String, extra: [String: Any]) -> String? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("bgprune-mind-" + UUID().uuidString)
        defer { try? fm.removeItem(at: work) }
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        guard run("/usr/bin/unzip", ["-q", source, "-d", work.path]) == 0 else { return nil }
        let config = work.appendingPathComponent("mind_config.json")
        guard let data = try? Data(contentsOf: config),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for (k, v) in extra { object[k] = v }
        guard let updated = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        try? updated.write(to: config)
        let out = URL(fileURLWithPath: source).deletingLastPathComponent().appendingPathComponent("crafted-\(UUID().uuidString.prefix(8)).mind")
        let zip = fm.fileExists(atPath: "/usr/bin/zip") ? "/usr/bin/zip" : "/bin/zip"
        guard run(zip, ["-q", "-r", out.path, "."], cwd: work) == 0 else { return nil }
        return out.path
    }

    static func run(_ tool: String, _ args: [String], cwd: URL? = nil) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
