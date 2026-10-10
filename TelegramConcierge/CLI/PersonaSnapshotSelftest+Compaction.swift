import Foundation

/// P3 and P9: the snapshot holds through mid-loop pruning (prune summary
/// and its retry, the post-prune estimates and rounds), active-turn
/// compaction (its estimates, request and retry) and the forced final.
extension MidturnHarness {

    /// Budget settings shared by the long rows; restored by the returned closure.
    func ppLongTurnSettings(mainRounds: Int?) throws -> () -> Void {
        try KeychainHelper.saveBatch([KeychainHelper.maxContextTokensKey: "250000", KeychainHelper.targetContextTokensKey: "70000",
                                      KeychainHelper.archiveChunkSizeKey: "1000000"].mapValues { Optional($0) })
        if let mainRounds { try AgentTurnOverrides.setOverride(mainRounds, forAgent: "main") }
        return {
            for key in [KeychainHelper.maxContextTokensKey, KeychainHelper.targetContextTokensKey, KeychainHelper.archiveChunkSizeKey] {
                try? KeychainHelper.delete(key: key)
            }
            try? AgentTurnOverrides.setOverride(nil, forAgent: "main")
        }
    }

    /// P3: turn 1 leaves three large reads in history; in turn 2 the
    /// profile changes at the first request, then reads trigger a mid-loop
    /// prune (first summary rejected → retry), an active-turn compaction
    /// (first summary rejected → retry) and finally the round-limit forced
    /// final. Everything after the write carries the turn's persona.
    func ppCompactionSection() async throws {
        let tag = "P3"
        let restoreSettings = try ppLongTurnSettings(mainRounds: 16)
        defer { restoreSettings() }
        let large = try ppLargeFile()
        let a = Self.ppSentinel("A"), b = Self.ppSentinel("B")
        let (manager, router, capture, done) = try await ppStart()
        try ppSetProfile(Self.ppProfile(a))
        for i in 1...3 { router.push([(id: "\(tag)-t1-\(i)", name: "read_file", args: ["path": large, "limit": 200])]) }
        router.pushText("turn one done")
        await ppTurn(manager, "\(tag) turn one: read the file three times")
        let turnTwoFirst = router.mainRequests + 1
        let written = PPBox(false)
        router.onMain = { n, _ in
            if n == turnTwoFirst { try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: Self.ppProfile(b)); written.value = true }
        }
        router.rejectFirstPrune = true
        router.rejectFirstCompaction = true
        router.readUntilCompaction = large
        router.fallbackCall = (id: "\(tag)-echo-", name: "bash", args: ["command": "echo after compaction"])
        let mark = capture.mark()
        await ppTurn(manager, "\(tag) turn two: read the file many times", timeout: 300)
        router.readUntilCompaction = nil; router.fallbackCall = nil; router.onMain = nil
        let main = capture.main(since: mark.requests)
        let texts = main.map(Self.ppText)
        let pruneRequests = texts.filter { $0.contains("[PRUNE SUMMARY") }
        let compactionRequests = texts.filter { $0.contains("ACTIVE TURN COMPACTION") }
        let forced = texts.filter { $0.contains("[ROUND LIMIT]") }
        check("\(tag)0 the turn crossed a mid-loop prune with its retry, a compaction with its retry and the forced final",
              written.value && pruneRequests.count >= 2 && compactionRequests.count >= 2 && forced.count >= 1,
              "prune \(pruneRequests.count), compaction \(compactionRequests.count), forced \(forced.count), written \(written.value)")
        // The profile store now holds only B: anything carrying A after the
        // write came from the snapshot.
        check("\(tag)s prune summary + retry, compaction + retry and the forced final carry the snapshot, not the new profile",
              !pruneRequests.isEmpty && !compactionRequests.isEmpty && !forced.isEmpty
                && (pruneRequests + compactionRequests + forced).allSatisfy { $0.contains(a) && !$0.contains(b) })
        ppAssertTurnFrozen(tag, capture, since: mark, old: a, new: b, minRequests: 6, sameSystem: false)
        let estimates = Array(capture.estimates.dropFirst(mark.estimates))
        let maintenanceEstimates = estimates.filter { !$0.contains("Documents are NOT") }
        check("\(tag)d the compaction-summary estimates (no-tools prompt) were among them and used the snapshot",
              !maintenanceEstimates.isEmpty && maintenanceEstimates.allSatisfy { $0.contains(a) && !$0.contains(b) },
              "maintenance estimates \(maintenanceEstimates.count) of \(estimates.count)")
        router.pushText("turn three done")
        let next = capture.mark()
        await ppTurn(manager, "\(tag) turn three")
        let first = capture.main(since: next.requests).first.map(Self.ppSystem) ?? ""
        check("\(tag)e the next turn adopts the new profile", first.contains(b) && !first.contains(a))
        done()
    }

    /// P3i: the INITIAL prune at turn start (budget lowered between turns)
    /// already runs under the turn's snapshot: the profile written while
    /// its summary request is in flight reaches neither that request nor
    /// the rest of the turn (capture precedes the initial prune).
    func ppInitialPruneSection() async throws {
        let tag = "P3i"
        let restoreSettings = try ppLongTurnSettings(mainRounds: nil)
        defer { restoreSettings() }
        let large = try ppLargeFile()
        let a = Self.ppSentinel("A"), b = Self.ppSentinel("B")
        let (manager, router, capture, done) = try await ppStart()
        try ppSetProfile(Self.ppProfile(a))
        for i in 1...3 { router.push([(id: "\(tag)-t1-\(i)", name: "read_file", args: ["path": large, "limit": 200])]) }
        router.pushText("turn one done")
        await ppTurn(manager, "\(tag) turn one: read the file three times")
        try KeychainHelper.save(key: KeychainHelper.maxContextTokensKey, value: "120000")
        let written = PPBox(false)
        let previous = server.router
        server.router = { request in
            let text = String(decoding: request.body, as: UTF8.self)
            if !written.value, text.contains("[PRUNE SUMMARY") || text.contains("ACTIVE TURN COMPACTION") {
                try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: Self.ppProfile(b))
                written.value = true
            }
            return previous?(request)
        }
        router.push([(id: "\(tag)-t2-1", name: "bash", args: ["command": "echo after the initial prune"])])
        router.pushText("turn two done")
        let firstMain = router.mainRequests
        let mark = capture.mark()
        await ppTurn(manager, "\(tag) turn two")
        server.router = previous
        let main = capture.main(since: mark.requests)
        let texts = main.map(Self.ppText)
        // Turn one's rounds exceed the input ceiling, so the initial prune
        // summarizes them on the bounded path (generatePrunedContextSummary
        // → summarizeActivePrefix: its estimates and fragment requests).
        let pruneIndex = texts.firstIndex { $0.contains("[PRUNE SUMMARY") || $0.contains("ACTIVE TURN COMPACTION") }
        let firstRound = main.firstIndex { ((try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["tools"] as? [Any])?.isEmpty == false }
        check("\(tag)0 the initial prune ran before the turn's first round and the profile changed during it",
              written.value && pruneIndex != nil && firstRound.map { $0 > pruneIndex! } == true && router.mainRequests > firstMain,
              "written \(written.value), prune \(pruneIndex.map(String.init) ?? "none")")
        ppAssertTurnFrozen(tag, capture, since: mark, old: a, new: b, minRequests: 3, sameSystem: false)
        done()
    }

    /// P9: a real mid-loop prune after a profile-maintenance commit that
    /// finished before it. The original persona survives the prune summary,
    /// the post-prune estimates and the next tool round; the next turn
    /// adopts the maintained profile. No threshold or maintenance change.
    func ppMidLoopPruneSection() async throws {
        let tag = "P9"
        let restoreSettings = try ppLongTurnSettings(mainRounds: nil)
        defer { restoreSettings() }
        let large = try ppLargeFile()
        let a = Self.ppSentinel("A"), c = Self.ppSentinel("C")
        let (manager, router, capture, done) = try await ppStart()
        try? FileManager.default.removeItem(at: UserContextMaintenance.stateURL)
        let profile = Self.ppProfile(a, facts: 420)
        try ppSetProfile(profile)
        router.maintenanceReply = "{\"drop\":[\((1...380).map(String.init).joined(separator: ","))],\"add\":[{\"text\":\"\(c) kept by maintenance\"}]}"
        for i in 1...3 { router.push([(id: "\(tag)-t1-\(i)", name: "read_file", args: ["path": large, "limit": 200])]) }
        router.pushText("turn one done")
        await ppTurn(manager, "\(tag) turn one: read the file three times")
        let turnTwoFirst = router.mainRequests + 1
        let committed = PPBox(false)
        router.onMain = { n, _ in
            guard n == turnTwoFirst else { return }
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                await ConversationArchiveService().maintainUserContextIfNeeded(event: .archive)
                finished.signal()
            }
            _ = finished.wait(timeout: .now() + 60)
            committed.value = Self.ppStoredProfile().contains(c)
        }
        for i in 1...4 { router.push([(id: "\(tag)-t2-\(i)", name: "read_file", args: ["path": large, "limit": 200])]) }
        router.push([(id: "\(tag)-t2-echo", name: "bash", args: ["command": "echo after prune"])])
        router.pushText("turn two done")
        let mark = capture.mark()
        await ppTurn(manager, "\(tag) turn two", timeout: 300)
        router.onMain = nil
        let main = capture.main(since: mark.requests)
        let texts = main.map(Self.ppText)
        guard let pruneIndex = texts.firstIndex(where: { $0.contains("[PRUNE SUMMARY") }) else {
            check("\(tag)0 a mid-loop prune ran after the maintenance commit", false, "committed \(committed.value), requests \(main.count)")
            done(); return
        }
        check("\(tag)0 the maintenance commit finished before a real mid-loop prune",
              committed.value && pruneIndex > 0, "committed \(committed.value)")
        let after = Array(main.dropFirst(pruneIndex))
        let escaped = MarkerNeutralizer.escape(profile)
        check("\(tag)a the prune summary and every later request (next tool round included) keep the original persona",
              after.count >= 2 && after.allSatisfy { Self.ppSystem($0).contains(escaped) && !Self.ppText($0).contains(c) },
              "after \(after.count)")
        let estimates = Array(capture.estimates.dropFirst(mark.estimates))
        check("\(tag)b every estimate of the turn, post-prune ones included, uses the original persona (\(estimates.count))",
              estimates.count >= 4 && estimates.allSatisfy { $0.contains(escaped) && !$0.contains(c) })
        router.pushText("turn three done")
        let next = capture.mark()
        await ppTurn(manager, "\(tag) turn three")
        let first = capture.main(since: next.requests).first.map(Self.ppSystem) ?? ""
        check("\(tag)c the next turn adopts the maintained profile", first.contains(c) && !first.contains(escaped))
        try? FileManager.default.removeItem(at: UserContextMaintenance.stateURL)
        done()
    }
}
