import Foundation

/// Existing users (plan §12): U1–U13 on scratch roots with fixtures in the
/// formats every supported version writes (the profile secret, the
/// `ada.archive.restructureRetryPending` preference, the extraction queue).
/// U14–U16 (a real v0.2.48 binary on the same roots) run in
/// scripts/user_context_wire_test.py. Also W5/W3 (request bodies and
/// default-path retry behaviour).
extension UserContextMaintenanceSelftest {

    static func exactly(_ size: Int) -> String {
        var text = UCMHarness.profile(size: size - 200)
        let pad = size - text.count - 1
        text += "- " + String(repeating: "p", count: max(pad - 2, 1)) + "\n"
        return text
    }

    static func existingUserRows(_ h: UCMHarness) async throws {
        // U1: legacy flag true / false / absent → never read, no rewrite at startup or archive, key removed.
        for flag in [true, false, nil] as [Bool?] {
            let archive = try h.fresh(profile: UCMHarness.profile(size: 25_000))
            if let flag { UserDefaults.standard.set(flag, forKey: UserContextMaintenance.legacyRetryFlagKey) }
            else { UserDefaults.standard.removeObject(forKey: UserContextMaintenance.legacyRetryFlagKey) }
            await archive.recoverPendingChunks(defaultContext: .empty)
            _ = try await archive.archiveMessages(chunkMessages("u1"))
            let rewrite = h.server.requests.contains { UCMHarness.systemText($0.body).contains("reorganizing an AI assistant") }
            h.check("U1 legacy flag \(flag.map(String.init) ?? "absent"): no rewrite at startup or archive, 0 maintenance sends, key removed",
                    !rewrite && h.maintenanceSends == 0 && UserDefaults.standard.object(forKey: UserContextMaintenance.legacyRetryFlagKey) == nil)
        }

        // U2: no state, 45k → startup 0; first archive event one cleanup run (≤ 6 sends).
        let p45 = UCMHarness.profile(size: 45_000)
        var archive = try h.fresh(profile: p45)
        h.check("U2 startup after the upgrade makes 0 sends on size", await h.event(archive, .startupRecovery) == 0)
        h.script([UCMHarness.dropOps(for: p45, toBelow: 35_000), UCMHarness.dropOps(for: UCMHarness.profile(size: 35_000), toBelow: 29_000)])
        let u2 = await h.event(archive)
        h.check("U2 first archive event: one cleanup run within the budget", u2 >= 1 && u2 <= 6 && h.validState?.cleanupV1 == .done, "\(u2)")

        // U3: 35k → one cleanup run, afterwards threshold-only.
        let p35 = UCMHarness.profile(size: 35_000)
        archive = try h.fresh(profile: p35)
        h.defaultMaintenanceReply = "{\"drop\":[1]}"
        let u3 = await h.event(archive)
        var later = 0
        for _ in 0..<3 { later += await h.event(archive) }
        h.check("U3 35k: one cleanup run at the first archive event, then none under 40k", u3 == 2 && later == 0, "\(u3)/\(later)")

        // U4: 25k and exactly 30,000 → done, 0 sends.
        for (label, text) in [("25k", UCMHarness.profile(size: 25_000)), ("exactly 30,000", exactly(30_000))] {
            archive = try h.fresh(profile: text)
            let sends = await h.event(archive)
            h.check("U4 \(label) (size \(text.count)): cleanup marked done, 0 sends", sends == 0 && h.validState?.cleanupV1 == .done, "\(text.count)")
        }

        // U5: absent and empty profile.
        for (label, text) in [("absent", nil), ("empty", "")] as [(String, String?)] {
            archive = try h.fresh(profile: text)
            h.extractionReply = "First fact learned"
            _ = try await archive.archiveMessages(chunkMessages("u5"))
            h.check("U5 \(label) profile: 0 maintenance sends; extraction appends as today",
                    h.maintenanceSends == 0 && h.profile == "First fact learned")
        }

        // U6: no bullets, no headings.
        let plain = (0..<500).map { $0 % 3 == 0 ? "LABEL\($0): value number \($0) for the user profile" : "Plain paragraph \($0) about the user, appended by extraction long ago." }.joined(separator: "\n")
        archive = try h.fresh(profile: plain)
        let plainDoc = UserProfileDocument(plain)
        h.script(["{\"drop\":[1,2,3],\"edit\":[{\"id\":4,\"text\":\"Plain 3\"}]}"])
        _ = await h.event(archive)
        let expectedPlain = plainDoc.apply(try UserProfileDocument.parseReply("{\"drop\":[1,2,3],\"edit\":[{\"id\":4,\"text\":\"Plain 3\"}]}", factCount: plainDoc.factCount)).text
        h.check("U6 no bullets/headings: every non-blank line is a fact; ops apply per line through the real run",
                plainDoc.factCount == 500 && h.profile == expectedPlain && h.retired().count == 4)

        // U7: CRLF, mixed, no trailing newline — real run.
        for (label, text) in [("CRLF", UCMHarness.profile(size: 45_000, lineEnding: "\r\n")),
                              ("mixed", p45.replacingOccurrences(of: "Section 2\n", with: "Section 2\r\n")),
                              ("no trailing newline", String(p45.dropLast()))] {
            archive = try h.fresh(profile: text)
            let doc = UserProfileDocument(text)
            h.script(["{\"drop\":[2,4],\"add\":[{\"text\":\"Added fact\",\"after\":1}]}"])
            h.defaultMaintenanceReply = "{}"
            _ = await h.event(archive)
            let expected = doc.apply(try UserProfileDocument.parseReply("{\"drop\":[2,4],\"add\":[{\"text\":\"Added fact\",\"after\":1}]}", factCount: doc.factCount)).text
            let retired = h.retired()
            h.check("U7 \(label): untouched lines byte-identical; retired records reproduce the original bytes",
                    Array(h.profile.utf8) == Array(expected.utf8)
                    && retired.count == 2 && retired.map(\.line) == [doc.lines[doc.factLineIndices[1]].raw, doc.lines[doc.factLineIndices[3]].raw])
        }

        // U8: one 45,000-char single line; one 12,000-char line among short ones.
        let single = "- " + String(repeating: "y", count: 45_000)
        archive = try h.fresh(profile: single)
        h.check("U8 a 45,000-char single line is one fact", UserProfileDocument(single).factCount == 1)
        h.script(["{\"edit\":[{\"id\":1,\"text\":\"short summary of a very long line\"}]}"])
        _ = await h.event(archive)
        h.check("U8 shorter edit accepted, original retired whole", h.profile == "- short summary of a very long line" && h.retired().first?.line == single)
        archive = try h.fresh(profile: single)
        h.defaultMaintenanceReply = "{}"
        _ = await h.event(archive)
        var again = 0
        for _ in 0..<3 { again += await h.event(archive) }
        h.check("U8 non-convergence on a single huge line → deferral, no loop", again == 0 && h.validState?.deferral != nil)
        let mixedLong = UCMHarness.profile(size: 30_000) + "- " + String(repeating: "z", count: 12_000) + "\n"
        archive = try h.fresh(profile: mixedLong)
        let longID = UserProfileDocument(mixedLong).factCount
        h.script(["{\"drop\":[\(longID)]}"])
        _ = await h.event(archive)
        h.check("U8 a 12,000-char line is never split: drop retires it whole", h.retired().first?.line.count == 12_002 && !h.profile.contains("zzzz"))

        // U9: only headings.
        let headings = (0..<2_000).map { "## Heading number \($0)" }.joined(separator: "\n")
        archive = try h.fresh(profile: headings)
        let u9 = await h.event(archive)
        h.check("U9 only headings (41k+): 0 facts → completed no-change run without a model request; deferral recorded",
                u9 == 0 && h.profile == headings && h.validState?.deferral != nil && h.validState?.cleanupV1 == .done, "\(u9)")

        // U10: pending chunk recovered at startup → extraction as today, then no run on size alone.
        archive = try h.fresh(profile: p45)
        let rawName = UUID().uuidString + ".json"
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(chunkMessages("u10")), to: h.archiveDir.appendingPathComponent(rawName))
        let pending = PendingChunkIndex(pendingChunks: [PendingChunk(id: UUID(), startDate: Date(timeIntervalSince1970: 1_790_000_000),
            endDate: Date(timeIntervalSince1970: 1_790_000_180), tokenCount: 50, messageCount: 4, rawContentFileName: rawName, createdAt: Date())])
        try PrivateStorage.writeAtomically(try JSONEncoder().encode(pending), to: h.archiveDir.appendingPathComponent("pending_chunks.json"))
        h.extractionReply = "Recovered fact"
        let restarted = ConversationArchiveService()
        await restarted.recoverPendingChunks(defaultContext: .empty)
        let extractions = h.server.requests.filter { UCMHarness.systemText($0.body).contains(h.extractionMarker) }
        let summaries = h.server.requests.filter { UCMHarness.systemText($0.body).contains(h.summaryMarker) }
        // v0.2.48 recovery summarizes a pending chunk and does not extract
        // facts from it; that stays exactly so. Size alone never runs at startup.
        h.check("U10 startup recovery: the pending chunk is summarized as before (no extraction, as in v0.2.48); no maintenance on size",
                summaries.count >= 1 && extractions.isEmpty && h.maintenanceSends == 0 && h.profile == p45,
                "summaries \(summaries.count) extractions \(extractions.count) sends \(h.maintenanceSends)")
        try? FileManager.default.removeItem(at: h.archiveDir.appendingPathComponent("pending_chunks.json"))

        // U11: a v0.2.48-format extraction backlog is drained exactly as before, then maintenance.
        archive = try h.fresh(profile: "- small\n")
        _ = await archive.clearAllArchives()   // no temporaries left over from earlier rows (no consolidation here)
        h.resetHooks()
        h.extractionReply = "@HTTP:500"
        let queued = try await archive.archiveMessages(chunkMessages("u11a"))
        let queueURL = h.archiveDir.appendingPathComponent("pending_context_extractions.json")
        let queueBefore = (try? Data(contentsOf: queueURL)) ?? Data()
        let decoded = (try? JSONDecoder().decode([ConversationArchiveService.PendingContextExtraction].self, from: queueBefore)) ?? []
        h.check("U11 the queue file keeps the v0.2.48 format", decoded.count == 1 && decoded.first?.chunkId == queued.id)
        try h.setProfile(p45)
        h.extractionReply = "NO_CHANGES"
        h.server.clear()
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        _ = try await archive.archiveMessages(chunkMessages("u11b", start: Date(timeIntervalSince1970: 1_790_100_000)))
        let order = h.server.requests.map { UCMHarness.systemText($0.body).contains(h.maintenanceMarker) ? "M" : UCMHarness.systemText($0.body).contains(h.extractionMarker) ? "X" : "S" }.joined()
        let queueAfter = (try? JSONDecoder().decode([ConversationArchiveService.PendingContextExtraction].self, from: Data(contentsOf: queueURL))) ?? [ConversationArchiveService.PendingContextExtraction(chunkId: UUID(), rawContentFileName: "", startDate: Date(), endDate: Date(), createdAt: Date())]
        h.check("U11 backlog drained (fresh + backlog extraction), queue emptied, then maintenance in the same event",
                order == "SXXM" && queueAfter.isEmpty, order)

        // U13: a damaged state file inside an imported Mind is preserved and suspends maintenance.
        archive = try h.fresh(profile: p45)
        try PrivateStorage.writeAtomically(Data("{\"version\":9}".utf8), to: h.stateURL)
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("ucm-u13-\(UUID().uuidString).mind")
        try await MindExportService.shared.exportMind(to: backup)
        try FileManager.default.removeItem(at: h.stateURL)
        try await MindExportService.shared.applyStagedMind(try await MindExportService.shared.stageMind(from: backup))
        await archive.reloadFromDisk()
        let u13Sends = await h.event(archive)
        h.check("U13 imported damaged state preserved byte-identical and maintenance suspended",
                (try? Data(contentsOf: h.stateURL)) == Data("{\"version\":9}".utf8) && u13Sends == 0)
        try? FileManager.default.removeItem(at: backup)
    }

    static func wireRows(_ h: UCMHarness) async throws {
        // W5: the budgeted Chat request body equals callLLM's body for the same prompts.
        let archive = try h.fresh(profile: "- x\n")
        h.defaultMaintenanceReply = "{}"
        let system = "You maintain the user profile — body equality probe."
        _ = try await archive.callLLM(systemPrompt: system, userPrompt: "probe")
        _ = try await archive.callLLMDetailed(systemPrompt: system, userPrompt: "probe", budget: SendBudget(limit: 1))
        let bodies = h.server.requests.suffix(2).map(\.body)
        // Swift's JSONEncoder does not fix object key order (Darwin varies it
        // per encode), so archive Chat bodies are compared as parsed JSON:
        // every field and value equal, array order included.
        func canonical(_ data: Data) -> Data? {
            (try? JSONSerialization.jsonObject(with: data)).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        }
        h.check("W5 maintenance Chat body equals callLLM's for the same prompts (same fields, values and message order)",
                bodies.count == 2 && canonical(bodies[0]) != nil && canonical(bodies[0]) == canonical(bodies[1]),
                bodies.count == 2 ? bodies.map { String(decoding: $0, as: UTF8.self) }.map { body in
                    let start = body.range(of: "\"model\"")?.lowerBound ?? body.startIndex
                    return String(body[start...].prefix(300)) + " … " + String(body.suffix(300))
                }.joined(separator: "\n---\n") : "")
        let headers = h.server.requests.suffix(2).map { $0.headers.filter { $0.key.lowercased() != "content-length" } }
        h.check("W5 and carries the same archive-lane headers (affinity included)", headers.count == 2 && headers[0] == headers[1])

        // W3: default (non-budgeted) paths keep their v0.2.48 retry behaviour.
        h.server.clear()
        h.script(["@TOOLS", "@TOOLS", "@TOOLS", "@TOOLS", "{}"])
        let reply = try await archive.callLLM(systemPrompt: system, userPrompt: "probe")
        h.check("W3 Chat callLLM still re-asks after tool-call replies (5 sends, then the text)", h.server.requests.count == 5 && reply == "{}", "\(h.server.requests.count)")
        try h.useResponses()
        h.server.clear()
        h.script(["@HTTP:503", "@HTTP:503", "{}"])
        let responsesReply = (try? await archive.callLLM(systemPrompt: system, userPrompt: "probe")) ?? "<threw>"
        h.check("W3 Responses default context still retries 503 inside the adapter (3 sends, then the text)",
                h.server.requests.count == 3 && responsesReply == "{}", "\(h.server.requests.count)")
        var context = ProviderExecutionContext.responsesAPI(baseURL: "http://127.0.0.1:\(h.server.port)/v1", key: "k", model: "m", lane: .archive)
        h.check("W3 a default context carries no budgets and standard retries",
                context.sendBudget == nil && context.authBudget == nil && context.adapterRetries == .standard)
        context.adapterRetries = .none
        h.server.clear(); h.script(["@HTTP:503", "{}"])
        var failed = false
        do { _ = try await ResponsesAuxiliary.text(context: context, messages: [("system", h.maintenanceMarker), ("user", "x")]) } catch { failed = true }
        h.check("W3 adapterRetries = .none sends once on 503", failed && h.server.requests.count == 1)
        try h.useChat()
    }
}
