import Foundation

/// v6.2: profile maintenance carries the same shared archive context block as
/// fact extraction (SC rows). The block must be byte-identical to the
/// extraction request's in the same archive event and in the same position
/// (right after the archive prefix), so the provider prefix cache on the
/// archive affinity lane can hit; without a context the request carries none.
extension UserContextMaintenanceSelftest {

    static func contentList(_ body: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
        if let messages = object["messages"] as? [[String: Any]] {
            return messages.map { "\($0["role"] as? String ?? "?"):" + ($0["content"] as? String ?? "") }
        }
        return (object["input"] as? [[String: Any]] ?? []).map { item in
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            return "\(item["role"] as? String ?? "?"):" + text
        }
    }

    static func sharedContextRows(_ h: UCMHarness) async throws {
        let p45 = UCMHarness.profile(size: 45_000)
        for proto in ["chat", "responses"] {
            if proto == "chat" { try h.useChat() } else { try h.useResponses() }
            let archive = try h.fresh(profile: p45)
            _ = await archive.clearAllArchives()
            h.resetHooks()
            let context = ConversationArchiveService.SummarizationContext(
                personaContext: p45, assistantName: "Fixture Assistant", userName: "Fixture User",
                previousSummaries: ["Summary A: the user planned a trip and asked about brokers once.",
                                    "Summary B: the user keeps working on the Briglia CLI with Codex reviews."],
                currentConversationContext: nil)
            h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
            _ = try await archive.archiveMessages(chunkMessages("sc-\(proto)"), context: context)
            let extraction = h.server.requests.first { UCMHarness.systemText($0.body).contains(h.extractionMarker) }
            let maintenance = h.maintenanceRequests.first
            let x = extraction.map { contentList($0.body) } ?? []
            let m = maintenance.map { contentList($0.body) } ?? []
            let expected = await archive.maintenanceSharedContextPrompt(for: context) ?? "<none>"
            h.check("SC1 \(proto): the cleanup request carries the shared archive block (summaries included)",
                    m.count == 4 && m[1].contains("PREVIOUS CONVERSATION SUMMARIES") && m[1].contains("Summary B"), "\(m.map { String($0.prefix(60)) })")
            h.check("SC2 \(proto): its leading prefix (archive prefix + shared block) is byte-identical to the extraction request's in the same event",
                    x.count >= 2 && m.count >= 2 && Array(x[0].utf8) == Array(m[0].utf8) && Array(x[1].utf8) == Array(m[1].utf8))
            h.check("SC2 \(proto): the shared block is exactly archiveSharedContextPrompt(for: context), placed before the task prompt",
                    m.count == 4 && m[1] == "system:" + MarkerNeutralizerIfResponses(proto, expected) && m[2].contains(h.maintenanceMarker) && m[3].hasPrefix("user:"))
        }
        try h.useChat()

        // SC3: no context available → no shared block, run proceeds, logged.
        var archive = try h.fresh(profile: p45)
        var report: UserContextMaintenanceReport?
        UserContextMaintenance.testHooks?.onReport = { report = $0 }
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        _ = await h.event(archive)
        let bare = h.maintenanceRequests.first.map { contentList($0.body) } ?? []
        h.check("SC3 without a context the request has no shared block (prefix, task, user) and the run still completes",
                bare.count == 3 && bare[1].contains(h.maintenanceMarker) && report?.sharedContextChars == 0 && h.profile.count <= 30_000)

        // SC4: startup recovery uses the context the manager built for recovery.
        archive = try h.fresh(profile: p45)
        _ = await archive.clearAllArchives()
        h.resetHooks()
        var state = UserContextMaintenanceState()
        state.failure = .init(kind: .transient, count: 1, nextEligibleAt: h.clock.now.addingTimeInterval(-1))
        try h.writeState(state)
        let recovery = ConversationArchiveService.SummarizationContext(
            personaContext: p45, assistantName: "Fixture Assistant", userName: "Fixture User",
            previousSummaries: ["Recovery summary R."], currentConversationContext: nil)
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        await archive.recoverPendingChunks(defaultContext: recovery)
        let startup = h.maintenanceRequests.first.map { contentList($0.body) } ?? []
        let expected = await archive.maintenanceSharedContextPrompt(for: recovery) ?? "<none>"
        h.check("SC4 startup recovery (a due failure retry) sends the recovery context's shared block",
                startup.count == 4 && startup[1] == "system:" + expected, "\(startup.map { String($0.prefix(60)) })")
        h.check("SC5 an empty context (no profile, names or summaries) yields no block",
                await archive.maintenanceSharedContextPrompt(for: .empty) == nil)
    }

    /// Responses requests pass every message through MarkerNeutralizer (as
    /// extraction's do); the fixture text contains no reserved marker, so the
    /// expected block is unchanged on both protocols.
    static func MarkerNeutralizerIfResponses(_ proto: String, _ text: String) -> String {
        proto == "responses" ? MarkerNeutralizer.escape(text) : text
    }
}
