import Foundation

/// Quiet background notices (0.2.63, docs/QUIET_BACKGROUND_NOTICES_PLAN.md):
/// a background archive job sends no routine 🧠 notice, including the
/// "Tidying long-term memory" one from the consolidation it runs; the
/// inline archive keeps both of today's notices; failures still alert.
extension BackgroundArchiveHarness {

    static let tidyingNotice = "🧠 Tidying long-term memory…"
    static let inlineArchiveNotice = "🧠 Summarizing and archiving the oldest part of the conversation…"

    func quietNoticeSection() async {
        // QA1: background job that also consolidates (five seeded chunks +
        // this job's chunk = six), through the commit at the next turn.
        let quiet = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: quiet, history: archiveSizedHistory(), seed: { try await self.seedTemporaryChunks(5) })
        let seeded = router.summaries
        let started = await startBackgroundJob(manager, hold: [])
        let finished = await waitForJob(manager, "succeeded")
        let consolidated = await manager._testArchiveService.getAllChunks().contains { $0.type == .consolidated }
        await turn(manager, "commit turn", reply: "ok")
        await sleep(0.5)
        check("QA1 setup: the background job archived and consolidated, then committed",
              started && finished && consolidated && router.summaries == seeded + 2 && manager._baJobOutcome == nil,
              "started \(started), finished \(finished), consolidated \(consolidated), summaries \(router.summaries - seeded)")
        check("QA1 no \"Tidying long-term memory\" notice from a background job's consolidation",
              !quiet.delivered.contains(Self.tidyingNotice), "\(quiet.delivered)")
        check("QA1 no 🧠 notice at all in background mode", !quiet.delivered.contains { $0.hasPrefix("🧠") }, "\(quiet.delivered)")

        // QA2: inline mode, same seed: today's two notices, unchanged text.
        let loud = SVRecordingChannel(kind: .telegram)
        let inline = await freshManager(channel: loud, history: archiveSizedHistory(), inline: true,
                                        seed: { try await self.seedTemporaryChunks(5) })
        let inlineSeeded = router.summaries
        let idle = await turn(inline, "inline archive with consolidation", reply: "inline reply")
        let tidied = await waitUntil(timeout: 10) { loud.delivered.contains(Self.tidyingNotice) }
        let inlineConsolidated = await inline._testArchiveService.getAllChunks().contains { $0.type == .consolidated }
        check("QA2 setup: the inline archive consolidated", idle && inlineConsolidated && router.summaries == inlineSeeded + 2,
              "summaries \(router.summaries - inlineSeeded)")
        check("QA2 inline: the 🧠 archive notice is still sent", loud.delivered.contains(Self.inlineArchiveNotice), "\(loud.delivered)")
        check("QA2 inline: the \"Tidying long-term memory\" notice is still sent, once", tidied
              && loud.delivered.filter { $0 == Self.tidyingNotice }.count == 1, "\(loud.delivered)")

        // QA3: a background job whose consolidation fails still alerts.
        let failing = SVRecordingChannel(kind: .telegram)
        let manager3 = await freshManager(channel: failing, history: archiveSizedHistory(), seed: { try await self.seedTemporaryChunks(5) })
        router.failSummariesFrom = router.summaries + 2
        router.failSummaries = "deterministic"
        let started3 = await startBackgroundJob(manager3, hold: [])
        let finished3 = await waitForJob(manager3, "succeeded")
        let alerted = await waitUntil(timeout: 10) { failing.delivered.contains { $0.contains("memory chunk consolidation") } }
        router.failSummaries = nil
        router.failSummariesFrom = nil
        check("QA3 a failed background consolidation still raises its maintenance alert",
              started3 && finished3 && alerted, "started \(started3), finished \(finished3), delivered \(failing.delivered)")
        check("QA3 ...and still no \"Tidying long-term memory\" notice", !failing.delivered.contains(Self.tidyingNotice),
              "\(failing.delivered)")

        // QA4 (plan C3): a job started in the background stays quiet after
        // /archiveinline on (the mode is the job's, captured at start).
        let switched = SVRecordingChannel(kind: .telegram)
        let manager4 = await freshManager(channel: switched, history: archiveSizedHistory(), seed: { try await self.seedTemporaryChunks(5) })
        let seeded4 = router.summaries
        let started4 = await startBackgroundJob(manager4, hold: [seeded4 + 1])
        let reply = await manager4._baCommand("/archiveinline on")
        router.gate.release()
        let finished4 = await waitForJob(manager4, "succeeded")
        await sleep(0.5)
        check("QA4 setup: /archiveinline on during the job, which then consolidated in the background",
              started4 && finished4 && reply.contains("now waits before replying") && router.summaries == seeded4 + 2,
              "reply \(reply), summaries \(router.summaries - seeded4)")
        check("QA4 the switched job's consolidation sent no \"Tidying\" notice", !switched.delivered.contains(Self.tidyingNotice),
              "\(switched.delivered)")
    }
}
