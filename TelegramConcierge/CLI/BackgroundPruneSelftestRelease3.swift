import Foundation

/// Release coverage required by Codex's implementation review round 3
/// (R3-3): the combined forced-final path B4b(i), the second completion
/// order of B17 with salvage ownership, an apply refused by the evidence
/// gate with the switch ON, and B16's ON/OFF retry bytes.
enum BackgroundPruneSelftestRelease3 {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        await combinedFinalPath(h)
        await receiptOwnershipMainFirst(h)
        await evidenceGateRefusal(h)
        await retryBytesOnOff(h)
    }

    /// Executions of one tool call (its `tool.execute` enter records).
    @MainActor static func toolExecutions(_ call: String) -> Int {
        _ = StageMarkers.flush(timeout: 5)
        let text = (try? String(contentsOf: StageMarkers.logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter {
            $0.contains("\"stage\":\"tool.execute\"") && $0.contains("\"ev\":\"enter\"") && $0.contains("\"call\":\"\(call)\"")
        }.count
    }

    @MainActor static func salvageBytes() -> Data? {
        try? Data(contentsOf: StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json"))
    }

    // MARK: B4b(i)

    static let compactionMarker = "[ACTIVE TURN COMPACTION — maintenance]"
    static let summaryNote = "Summary of earlier completed work in this turn"

    /// §16.3 B4b(i), part 1 — compaction: a job retiring in the slot; the
    /// boundary that prepares the forced final's request runs today's inline
    /// block with an active-turn compaction (the job's debt, the final's one
    /// inline allowance). Refusals on attempts 0–2 build the suffix; attempt
    /// 3 fails in band → convergence reduces without a second inline block
    /// and the original error surfaces (B4b(h)).
    @MainActor static func combinedFinalPath(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        let worker = BackgroundPruneSelftestGate()
        ConversationManager.bgPruneHoldForTesting = { point in if point == "worker.summary" { await worker.awaitRelease() } }
        // A job frozen in the previous turn; its deadline passes while the
        // worker ignores cancellation (retiring, slot occupied).
        ConversationManager.bgPruneDeadlineSecondsForTesting = 0.5
        _ = await h.frozenRunningJob(manager, holdSummary: false)
        let retiring = await h.waitUntil(timeout: 20) { manager.bgPruneTestPhase.hasPrefix("retiring") }
        h.clearEvents()
        h.server.clear()
        try? AgentTurnOverrides.setOverride(2, forAgent: "main")
        let log = h.log
        let router = h.router
        // Active-turn compaction requests carry the tool list; they are
        // answered here, never from the main-agent script.
        h.server.router = { request in
            let text = String(data: request.body, encoding: .utf8) ?? ""
            if text.contains(compactionMarker) {
                log.append("request.compaction")
                return (BackgroundPruneSelftestHarness.chat("Compacted fixture work: the large file was read.", prompt: 100), 0)
            }
            if BackgroundPruneSelftestRouter.isMain(request) { log.append("request.main") }
            return router.route(request)
        }
        let big = h.filesRoot.appendingPathComponent("bi-big.txt")
        try? ("combined fixture file\n" + String(repeating: "current-turn line\n", count: 2_000)).write(to: big, atomically: true, encoding: .utf8)
        let small = h.filesRoot.appendingPathComponent("bi-small.txt")
        try? "a small file\n".write(to: small, atomically: true, encoding: .utf8)
        manager.bgPruneTestSetLastPromptTokens(1_000)
        h.server.script([BackgroundPruneSelftestHarness.tools([(id: "bi-read", name: "read_file", args: ["path": big.path])], prompt: 1_000),
                         BackgroundPruneSelftestHarness.tools([(id: "bi-read-2", name: "read_file", args: ["path": small.path])], prompt: 120_000),
                         refusal("bi-ref-0"), refusal("bi-ref-1"), refusal("bi-ref-2"), BackgroundPruneSelftestRelease.contextBody],
                        statuses: [200, 200, 200, 200, 200, 400])
        manager._testStartTurn(for: Message(role: .user, content: "combined forced final with a compaction"))
        _ = await manager._testAwaitIdle(timeout: 90)
        h.server.router = { router.route($0) }
        let mains = h.mainRequests.map { h.bodyText($0) }.filter { !$0.contains(compactionMarker) }
        // Every compaction request falls between round 2 and attempt 0.
        let compactedBetween: Bool = {
            var mainsSeen = 0
            var between = 0
            for item in h.log.all {
                if item == "request.main" { mainsSeen += 1 }
                if item == "request.compaction" { if mainsSeen != 2 { return false }; between += 1 }
            }
            return between >= 1
        }()
        h.check("B4b(i) compaction precondition: a retiring job; six main requests; the final error is attempt 3's 400",
                retiring && mains.count == 6 && (manager._testLastError ?? "").contains("400"),
                "retiring \(retiring) main \(mains.count) error \(String(describing: manager._testLastError)) events \(h.allEvents)")
        h.check("B4b(i) compaction: one inline block with an active-turn compaction, before attempt 0 was sent",
                BackgroundPruneSelftestRound2.helperEntries(h) == 1 && BackgroundPruneSelftestRound2.helperEntriesBeforeRequest(h, 3) == 1
                && compactedBetween, "events \(h.allEvents) log \(h.log.all.filter { $0.hasPrefix("request.") })")
        h.check("B4b(i) compaction projection: every final attempt carries the compaction summary, not the compacted round or the pruned output",
                mains.count == 6 && mains.dropFirst(2).allSatisfy { $0.contains(summaryNote) && !$0.contains("current-turn line") && !$0.contains("RESULT-h-call-0 ") }
                && mains[0].contains("RESULT-h-call-0 ") && mains[1].contains("current-turn line"))
        h.check("B4b(i) compaction suffix and attempt index: attempts 0 → 1 → 2 → 3, each refusal kept once",
                mains.count == 6 && !mains[2].contains("FORCE-FINISH RETRY") && mains[3].contains(retry(1)) && mains[4].contains(retry(2))
                && mains[5].contains(retry(3)) && mains[3].contains("bi-ref-0") && mains[4].contains("bi-ref-1") && mains[5].contains("bi-ref-2")
                && mains[5].components(separatedBy: "bi-ref-0").count == mains[3].components(separatedBy: "bi-ref-0").count)
        h.check("B4b(i) compaction allowance: convergence at attempt 3 reduced without a second inline block or a resend",
                h.eventCount("bgprune.converge.reduce") == 1 && h.eventCount("bgprune.converge.resent") == 0, "events \(h.allEvents)")
        h.check("B4b(i) compaction: no refused tool executed; each round tool executed once",
                toolExecutions("bi-ref-0") + toolExecutions("bi-ref-1") + toolExecutions("bi-ref-2") == 0
                && toolExecutions("bi-read") == 1 && toolExecutions("bi-read-2") == 1)
        worker.release()
        _ = await h.waitUntil { manager.bgPruneTestPhase == "none" }
        try? AgentTurnOverrides.setOverride(nil, forAgent: "main")
        ConversationManager.bgPruneHoldForTesting = nil
        ConversationManager.bgPruneDeadlineSecondsForTesting = nil
        await imageThenConvergenceAtFinal(h)
    }

    /// The forced final's retry tail as it appears in a JSON body ('/' escaped).
    static func retry(_ n: Int) -> String { "[FORCE-FINISH RETRY \(n)\\/4]" }

    static func refusal(_ id: String) -> String {
        BackgroundPruneSelftestHarness.tools([(id: id, name: "read_file", args: ["path": String(repeating: "y", count: 60_000)])], prompt: 1_000)
    }

    /// §16.3 B4b(i), part 2 — image and convergence in one forced final: the
    /// trigger image is rejected on attempt 1 (marked, rebuilt, resent);
    /// attempt 3 fails in band and converges (one inline prune, rebuild,
    /// resend, success). The refusal suffix survives both rebuilds exactly
    /// once, the mark survives the R rebuild, the image retry uses no
    /// allowance. (Combining this with part 1 in one final is not possible:
    /// after an active-turn compaction the final's requests carry no image,
    /// and nothing prunable is left for a convergence to change.)
    @MainActor static func imageThenConvergenceAtFinal(_ h: BackgroundPruneSelftestHarness) async {
        let name = "bi-trigger.png"
        let images = StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
        let manager = await h.freshManager(history: h.prunableHistory())
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try? IRFixtures.png.write(to: images.appendingPathComponent(name))
        try? AgentTurnOverrides.setOverride(1, forAgent: "main")
        let small = h.filesRoot.appendingPathComponent("bi-small.txt")
        try? "a small file\n".write(to: small, atomically: true, encoding: .utf8)
        manager.bgPruneTestSetLastPromptTokens(1_000)
        h.observeMainRequests()
        h.server.script([BackgroundPruneSelftestHarness.tools([(id: "bj-read", name: "read_file", args: ["path": small.path])], prompt: 1_000),
                         refusal("bj-ref-0"), IRFixtures.openAIChatBMP, refusal("bj-ref-1"), refusal("bj-ref-2"),
                         BackgroundPruneSelftestRelease.contextBody, BackgroundPruneSelftestHarness.chat("final after both recoveries", prompt: 100)],
                        statuses: [200, 200, 400, 200, 200, 400, 200])
        manager._testStartTurn(for: Message(role: .user, content: "image and convergence in one forced final", imageFileNames: [name]))
        _ = await manager._testAwaitIdle(timeout: 90)
        h.server.requestObserver = nil
        let mains = h.mainRequests.map { h.bodyText($0) }
        let image = IRFixtures.png.base64EncodedString()
        let marked = manager._testMessages.first { $0.imageFileNames == [name] }?.providerRejectedImageFileNames ?? []
        // mains: round 1, a0, a1 (rejected), a1 resend, a2, a3 (in-band 400), a3 resend.
        h.check("B4b(i) image + convergence precondition: seven main requests, success",
                mains.count == 7 && manager._testLastError == nil,
                "main \(mains.count) error \(String(describing: manager._testLastError)) events \(h.allEvents)")
        h.check("B4b(i) image mark: sent until attempt 1's rejection, never after (also after the convergence rebuild); kept on the message",
                mains.count == 7 && mains[0].contains(image) && mains[1].contains(image) && mains[2].contains(image)
                && mains[3...].allSatisfy { !$0.contains(image) } && marked == [name], "marked \(marked)")
        h.check("B4b(i) attempt index: 0 → 1 (image retry, same attempt) → 2 → 3 (convergence resend, same attempt)",
                mains.count == 7 && !mains[1].contains("FORCE-FINISH RETRY") && mains[2].contains(retry(1)) && mains[3].contains(retry(1))
                && mains[4].contains(retry(2)) && mains[5].contains(retry(3)) && mains[6].contains(retry(3)))
        h.check("B4b(i) suffix after both rebuilds: every refusal present exactly as before the convergence rebuild",
                mains.count == 7 && ["bj-ref-0", "bj-ref-1", "bj-ref-2"].allSatisfy {
                    mains[6].components(separatedBy: $0).count == mains[5].components(separatedBy: $0).count && mains[6].contains($0)
                } && mains[3].components(separatedBy: "bj-ref-0").count == mains[6].components(separatedBy: "bj-ref-0").count)
        h.check("B4b(i) projection: the convergence resend was rebuilt from the reduced history (pruned output gone)",
                mains.count == 7 && mains[5].contains("RESULT-h-call-0 ") && !mains[6].contains("RESULT-h-call-0 "))
        h.check("B4b(i) allowances: the image retry used none; convergence used the final's one inline block and resent once",
                BackgroundPruneSelftestRound2.helperEntries(h) == 1 && h.eventCount("bgprune.converge.reduce") == 1
                && h.eventCount("bgprune.converge.resent") == 1, "events \(h.allEvents)")
        h.check("B4b(i) no refused tool executed",
                toolExecutions("bj-ref-0") + toolExecutions("bj-ref-1") + toolExecutions("bj-ref-2") == 0 && toolExecutions("bj-read") == 1)
        try? AgentTurnOverrides.setOverride(nil, forAgent: "main")
    }

    // MARK: B17, the other completion order

    /// The main Responses request carrying a mid-turn note completes first
    /// (the note is acknowledged), then the summary completes: no
    /// redelivery, the note once in history, and the worker leaves the
    /// salvage file untouched.
    @MainActor static func receiptOwnershipMainFirst(_ h: BackgroundPruneSelftestHarness) async {
        let manager = await h.freshManager(history: h.prunableHistory())
        BackgroundPruneSelftestRelease.useResponses(h)
        h.router.holdSummaries = [1]
        let mainGate = BackgroundPruneSelftestGate()
        let router = h.router
        let count = BackgroundPruneSelftestLog()
        h.server.router = { request in
            if BackgroundPruneSelftestRouter.isMain(request) {
                count.append("x")
                if count.all.count == 2 { mainGate.wait() }
                return nil
            }
            return router.route(request)
        }
        manager.bgPruneTestSetLastPromptTokens(60_000)
        h.server.script([BackgroundPruneSelftestHarness.rTools([(id: "rx2-bash", name: "bash", args: ["command": "sleep 1.5; echo rx2"])]),
                         BackgroundPruneSelftestHarness.rText("answered with the note"),
                         BackgroundPruneSelftestHarness.rText("spare")])
        manager._testStartTurn(for: Message(role: .user, content: "start a short command"))
        await h.sleep(0.4)
        let note = "mid-turn note for the main-first receipt test"
        await manager._testDispatchUser(Message(role: .user, content: note))
        let held = await h.waitUntil(timeout: 30) { mainGate.arrived == 1 }
        let runningWhileHeld = manager.bgPruneTestPhase == "running"
        mainGate.release()
        _ = await manager._testAwaitIdle(timeout: 60)
        let salvageBefore = salvageBytes()
        let summariesBefore = h.router.summaries
        h.router.gate.release()
        let ready = await h.waitPhase(manager, "ready", timeout: 30)
        let salvageAfter = salvageBytes()
        await h.sleep(0.5)
        _ = await manager._testAwaitIdle(timeout: 30)
        let mains = h.server.completeRequests.filter(BackgroundPruneSelftestRouter.isMain)
        let delivered = mains.filter { h.bodyText($0).contains(note) }.count
        let inHistory = manager._testMessages.filter { $0.content == note }.count
        h.check("B17 (main first) precondition: the main request closed before the summary",
                held && runningWhileHeld && ready && summariesBefore == 1,
                "held \(held) running \(runningWhileHeld) ready \(ready) phase \(manager.bgPruneTestPhase)")
        h.check("B17 (main first) the note reached the model once, is in history once, no redelivery after the summary closed",
                delivered == 1 && inHistory == 1 && mains.count == 2 && manager._testLastError == nil,
                "delivered \(delivered) history \(inHistory) main \(mains.count)")
        h.check("B17 (main first) the worker left the salvage file untouched", salvageBefore == salvageAfter)
        BackgroundPruneSelftestRelease.useChat(h)
    }

    // MARK: apply refused by the evidence gate (ON)

    /// §8.3 step 2 with the switch ON: a frozen message carries a snapshot
    /// route; the crash records become unreadable before the apply, so the
    /// gate refuses: abandon("evidence"), nothing written, no description
    /// saved, the inline fallback owed.
    @MainActor static func evidenceGateRefusal(_ h: BackgroundPruneSelftestHarness) async {
        var history = h.prunableHistory()
        if let route = try? PruneArchiveReference(id: UUID(), basename: "2026-01-01_000000Z_" + String(repeating: "a", count: 32) + ".txt") {
            history[1].pruneArchiveReferences = [route]
        }
        let manager = await h.freshManager(history: history)
        _ = await h.frozenRunningJob(manager, holdSummary: false)
        let ready = await h.waitPhase(manager, "ready")
        let frozen = manager._testMessages.prefix(history.count).map { $0 }
        let diskBefore = h.diskHistory()
        try? FileManager.default.createDirectory(at: DetachedJobStore.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("unreadable crash records".utf8).write(to: DetachedJobStore.fileURL)
        let descriptionsBefore = h.router.descriptions
        h.clearEvents()
        manager.bgPruneTestSetLastPromptTokens(1_000)
        _ = await h.turn(manager, "apply refused by the evidence gate")
        let after = manager._testMessages.prefix(history.count).map { $0 }
        h.check("§8.3 evidence gate (ON): the apply is refused, nothing written, the fallback owed",
                ready && h.eventCount("bgprune.abandon.evidence") == 1 && h.eventCount("bgprune.applied") == 0
                && h.encoded(Array(after)) == h.encoded(Array(frozen)) && h.prunedIds(manager).isEmpty
                && manager.bgPruneTestFallbackDue && manager.bgPruneTestPhase == "none",
                "ready \(ready) events \(h.allEvents) fallback \(manager.bgPruneTestFallbackDue) phase \(manager.bgPruneTestPhase)")
        h.check("§8.3 evidence gate (ON): no description saved, the saved history keeps the frozen range",
                h.router.descriptions == descriptionsBefore && h.diskHistory().prefix(diskBefore.count).map { $0.id } == diskBefore.map { $0.id }
                && h.encoded(Array(h.diskHistory().prefix(history.count))) == h.encoded(Array(diskBefore.prefix(history.count))))
        try? FileManager.default.removeItem(at: DetachedJobStore.fileURL)
    }

    // MARK: B16, ON vs OFF retry bytes

    /// The same inputs with the switch OFF (inline prune) and ON (worker):
    /// the first summary attempt and its tool-refusal retry are byte-identical.
    @MainActor static func retryBytesOnOff(_ h: BackgroundPruneSelftestHarness) async {
        let history = h.prunableHistory()
        let triggerTime = Date()
        let triggerId = UUID()
        func run(on: Bool) async -> [String] {
            let manager = await h.freshManager(history: history, switchOn: on)
            h.router.summaryReply = { n, _ in
                n == 1 ? BackgroundPruneSelftestHarness.tools([(id: "sum-refused", name: "list_dir", args: ["path": "/"])], prompt: 100) : nil
            }
            manager.bgPruneTestSetLastPromptTokens(60_000)
            h.server.script([BackgroundPruneSelftestHarness.chat("done", prompt: 100)])
            manager._testStartTurn(for: Message(id: triggerId, role: .user, content: "same inputs, both modes", timestamp: triggerTime))
            _ = await manager._testAwaitIdle(timeout: 40)
            if on { _ = await h.waitPhase(manager, "ready", timeout: 40) }
            h.router.summaryReply = nil
            return h.server.completeRequests.map { h.bodyText($0) }.filter {
                $0.contains(BackgroundPruneSelftestRouter.summaryMarker) || $0.contains(BackgroundPruneSelftestRouter.summaryRetryMarker)
            }
        }
        let off = await run(on: false)
        let on = await run(on: true)
        let firstDiff: String = {
            for (i, (a, b)) in zip(off, on).enumerated() where a != b {
                let idx = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
                return "attempt \(i + 1) differs at \(idx): …\(a.dropFirst(max(0, idx - 60)).prefix(140)) vs …\(b.dropFirst(max(0, idx - 60)).prefix(140))"
            }
            return ""
        }()
        h.check("B16 ON vs OFF: the summary attempt and its refusal retry are byte-identical (\(off.count) / \(on.count) sends)",
                off.count == 2 && on.count == 2 && off == on, firstDiff)
    }
}
