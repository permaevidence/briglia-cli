import Foundation

/// v6.4 (Codex round 3, R1): the cleanup request carries the run's local
/// date, so "keep upcoming events until their date has passed" has a clock.
/// DT rows. The date sits in the maintenance task prompt only, after the
/// archive prefix and the shared block, which stay byte-identical to the
/// extraction request's.
extension UserContextMaintenanceSelftest {

    static func dateRows(_ h: UCMHarness) async throws {
        let rome = TimeZone(identifier: "Europe/Rome")!
        let newYork = TimeZone(identifier: "America/New_York")!
        func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

        // DT1: local day around midnight and DST changes, fractional offsets.
        let table: [(TimeInterval, TimeZone, String, String)] = [
            (1_791_151_199, rome, "Sunday, 4 October 2026 (Europe/Rome, UTC+02:00)", "Rome 23:59:59 the evening before midnight"),
            (1_791_151_200, rome, "Monday, 5 October 2026 (Europe/Rome, UTC+02:00)", "Rome midnight (still 4 Oct in UTC)"),
            (1_791_151_200, newYork, "Sunday, 4 October 2026 (America/New_York, UTC-04:00)", "same instant in New York"),
            (1_792_889_999, rome, "Sunday, 25 October 2026 (Europe/Rome, UTC+02:00)", "Rome just before the DST end"),
            (1_792_890_000, rome, "Sunday, 25 October 2026 (Europe/Rome, UTC+01:00)", "Rome just after the DST end"),
            (1_792_969_199, rome, "Sunday, 25 October 2026 (Europe/Rome, UTC+01:00)", "Rome 23:59:59 on the DST-change day"),
            (1_792_969_200, rome, "Monday, 26 October 2026 (Europe/Rome, UTC+01:00)", "Rome midnight after the DST-change day"),
            (1_793_512_799, newYork, "Sunday, 1 November 2026 (America/New_York, UTC-04:00)", "New York before its DST end"),
            (1_793_512_800, newYork, "Sunday, 1 November 2026 (America/New_York, UTC-05:00)", "New York after its DST end"),
            (1_791_108_000, TimeZone(identifier: "Asia/Kolkata")!, "Sunday, 4 October 2026 (Asia/Kolkata, UTC+05:30)", "half-hour offset"),
            (1_791_108_000, TimeZone(identifier: "America/St_Johns")!, "Sunday, 4 October 2026 (America/St_Johns, UTC-02:30)", "negative half-hour offset"),
        ]
        for (seconds, zone, expected, label) in table {
            let line = UserContextMaintenance.todayLine(now: at(seconds), timeZone: zone)
            h.check("DT1 local date: \(label)", line == expected, line)
        }

        // DT2: the task prompt carries the date next to the rule that needs it.
        let prompt = UserContextMaintenance.systemPrompt(document: UserProfileDocument(UCMHarness.profile(size: 36_622)),
            assistantName: "Bree", userName: "Matteo", policy: .standard, pass: 1, now: at(1_791_151_199), timeZone: rome)
        h.check("DT2 the prompt says TODAY with weekday, local day and offset, and points the upcoming-events rule at it",
                prompt.contains("TODAY: Sunday, 4 October 2026 (Europe/Rome, UTC+02:00)")
                && prompt.contains("Keep upcoming commitments and events until their date has passed; today's date is given below, and if an event's date is unclear, don't assume it has passed."))

        // DT3: a real archive event on both transports, on either side of
        // Rome's midnight. The date reaches the model in the task prompt; the
        // archive prefix and shared block are unchanged and still match
        // extraction's; no other archive request carries it.
        let p45 = UCMHarness.profile(size: 45_000)
        let context = ConversationArchiveService.SummarizationContext(
            personaContext: p45, assistantName: "Fixture Assistant", userName: "Fixture User",
            previousSummaries: ["Summary A: the user booked a race for 10–11 October."], currentConversationContext: nil)
        for proto in ["chat", "responses"] {
            var captured: [(maintenance: [String], extraction: [String], others: [String])] = []
            for instant in [1_791_151_199.0, 1_791_151_200.0] {
                if proto == "chat" { try h.useChat() } else { try h.useResponses() }
                let archive = try h.fresh(profile: p45)
                _ = await archive.clearAllArchives()
                h.resetHooks()
                h.clock.set(at(instant))
                UserContextMaintenance.testHooks?.timeZone = rome
                h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
                _ = try await archive.archiveMessages(chunkMessages("dt-\(proto)-\(Int(instant))"), context: context)
                let m = h.maintenanceRequests.first.map { contentList($0.body) } ?? []
                let x = h.server.requests.first { UCMHarness.systemText($0.body).contains(h.extractionMarker) }.map { contentList($0.body) } ?? []
                let others = h.server.requests.filter { !h.isMaintenance($0) }.map { String(decoding: $0.body, as: UTF8.self) }
                captured.append((m, x, others))
            }
            let (before, after) = (captured[0], captured[1])
            h.check("DT3 \(proto): 23:59:59 Rome → the cleanup request's task prompt says Sunday, 4 October 2026",
                    before.maintenance.count == 4 && before.maintenance[2].contains("TODAY: Sunday, 4 October 2026 (Europe/Rome, UTC+02:00)"),
                    "\(before.maintenance.map { String($0.prefix(60)) })")
            h.check("DT3 \(proto): one second later (Rome midnight) it says Monday, 5 October 2026",
                    after.maintenance.count == 4 && after.maintenance[2].contains("TODAY: Monday, 5 October 2026 (Europe/Rome, UTC+02:00)"))
            h.check("DT3 \(proto): archive prefix and shared block are byte-identical across the two dates and to extraction's",
                    before.maintenance.count == 4 && after.maintenance.count == 4 && before.extraction.count >= 2
                    && Array(before.maintenance[0].utf8) == Array(after.maintenance[0].utf8)
                    && Array(before.maintenance[1].utf8) == Array(after.maintenance[1].utf8)
                    && Array(before.maintenance[0].utf8) == Array(before.extraction[0].utf8)
                    && Array(before.maintenance[1].utf8) == Array(before.extraction[1].utf8)
                    && !before.maintenance[0].contains("TODAY:") && !before.maintenance[1].contains("TODAY:"))
            h.check("DT3 \(proto): no summary or extraction request carries the date",
                    !before.others.isEmpty && !(before.others + after.others).contains { $0.contains("TODAY:") || $0.contains("October 2026 (Europe/Rome") })
        }
        try h.useChat()

        // DT4: one date per run — a second pass after midnight keeps the date
        // the run started with.
        let archive = try h.fresh(profile: p45)
        h.clock.set(at(1_791_151_199))
        UserContextMaintenance.testHooks?.timeZone = rome
        UserContextMaintenance.testHooks?.afterSnapshot = { [clock = h.clock] pass in
            if pass == 2 { clock.set(Date(timeIntervalSince1970: 1_791_151_260)) }
        }
        h.script([UCMHarness.dropOps(for: p45, toBelow: 38_000), UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        _ = await h.event(archive)
        let passes = h.maintenanceRequests.map { UCMHarness.systemText($0.body) }
        h.check("DT4 both passes of one run carry the run's start date, even when pass 2 starts after midnight",
                passes.count == 2 && passes.allSatisfy { $0.contains("TODAY: Sunday, 4 October 2026 (Europe/Rome, UTC+02:00)") },
                "\(passes.count) passes")
    }
}
