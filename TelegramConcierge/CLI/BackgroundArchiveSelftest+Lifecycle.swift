import Foundation

/// Plan §13 tests 1–6 and 14–16 (lifecycle, failure/cooldown, modes).
extension BackgroundArchiveHarness {

    /// BA1–BA6: start without waiting, frozen view, one job, commit at the
    /// next turn before context, no second summary.
    func lifecycleSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let history = archiveSizedHistory()
        // Five earlier chunks: this job's chunk makes six, so the job also
        // consolidates (A..D → G) after publishing its own chunk F.
        let manager = await freshManager(channel: channel, history: history, seed: { try await self.seedTemporaryChunks(5) })
        let seededSummaries = router.summaries
        let pause = ConsolidationPause()
        ConversationArchiveService.afterConsolidationPublishForTesting = { await pause.gate.wait() }
        let started = await startBackgroundJob(manager, hold: [seededSummaries + 1])
        check("BA1 the archive turn finished while its summary request is still held (not awaited)",
              started && router.gate.arrived == 1 && manager._baJobOutcome == "running",
              "idle+job \(started), held \(router.gate.arrived), job \(manager._baJobOutcome ?? "nil")")
        check("BA1 its reply was delivered", channel.delivered.contains("reply while archiving"), "\(channel.delivered)")
        let first = mainRequests.last
        check("BA1 the conversation was sent unchanged (the oldest message is still in the request)",
              first.map { conversation($0).contains("end of old-0.") } == true)
        check("BA1 no 🧠 notice in background mode (owner decision D1)",
              !channel.delivered.contains { $0.hasPrefix("🧠") }, "\(channel.delivered)")
        check("BA1 the job's activity is listed while it runs",
              manager._baMaintenanceKinds.contains(.summarizingHistory))
        let status = await manager._baCommand("/status")
        check("BA2 /status: in the background, still finishing",
              status.contains("🧠 Memory archiving: in the background (a background archive is still finishing)"), status)
        let batch = manager._baJobBatchIds
        check("BA2 the job selected the oldest messages", batch.first == history.first?.id && batch.count < history.count,
              "\(batch.count) of \(history.count)")

        // Let the job publish its chunk and consolidate, then pause it.
        router.gate.release()
        let paused = await waitUntil(timeout: 30) { pause.gate.arrived > 0 }
        let indexed = await manager._testArchiveService.getAllChunks()
        check("BA3 setup: mid-job, the new chunk and the consolidated replacement are published",
              paused && indexed.contains { $0.type == .consolidated } && indexed.count == 3, "\(indexed.count) chunks")
        // A second turn while the job runs: frozen view, no second job.
        let sectionBefore = first.map(archiveSection) ?? "?"
        await turn(manager, "second request during the job", reply: "second reply")
        let second = mainRequests.last
        check("BA3 a turn during the job reuses the frozen view (archive section byte-identical, five rows, \"Showing all 5\")",
              second.map(archiveSection) == sectionBefore && sectionBefore.contains("Showing all 5 archived chunk(s)"),
              "\(second.map(archiveSection) ?? "nil")")
        check("BA3 the new chunk and the consolidation are absent from automatic context",
              second.map { !system($0).contains("Fixture summary #\(seededSummaries + 1)") && !system($0).contains("Fixture summary #\(seededSummaries + 2)") } == true)
        check("BA3 no second archive job: only the chunk and its consolidation were summarized",
              router.summaries == seededSummaries + 2 && manager._baJobBatchIds == batch, "summaries \(router.summaries - seededSummaries)")
        check("BA3 the batch is still live during the job", contains(manager, batch))

        pause.gate.release()
        ConversationArchiveService.afterConsolidationPublishForTesting = nil
        let finished = await waitForJob(manager, "succeeded")
        check("BA4 the job finished in the background and its activity ended", finished,
              "job \(manager._baJobOutcome ?? "nil"), activities \(manager._baMaintenanceKinds)")
        let chunks = await manager._testArchiveService.getAllChunks()
        check("BA4 the chunk is published but nothing is committed while idle (no idle commit)",
              chunks.count == 3 && contains(manager, batch) && batch.allSatisfy(diskIds().contains),
              "chunks \(chunks.count)")
        let waiting = await manager._baCommand("/status")
        check("BA4 /status: archived messages waiting to be removed",
              waiting.contains("(archived messages waiting to be removed)"), waiting)

        server.clear()
        await turn(manager, "third request after the job", reply: "third reply")
        let third = mainRequests.first
        check("BA5 the next turn committed before building its context: the batch is gone from its request",
              third.map { !conversation($0).contains("end of old-0.") } == true)
        check("BA5 ...and its archive section shows the new chunk and the consolidation (fresh view, \"Showing all 3\")",
              third.map { system($0).contains("Fixture summary #\(seededSummaries + 1) of the archived segment.")
                  && system($0).contains("Fixture summary #\(seededSummaries + 2) of the archived segment.")
                  && archiveSection($0).contains("Showing all 3 archived chunk(s)") } == true)
        check("BA5 the batch left memory and disk; the job is cleared",
              containsNone(manager, batch) && batch.allSatisfy { !diskIds().contains($0) } && manager._baJobOutcome == nil)
        check("BA6 no further summary request after the job", router.summaries == seededSummaries + 2, "\(router.summaries - seededSummaries)")
        check("BA6 the job's lease and the turn leases settle to the current turn's only",
              await manager._testArchiveService._testLeaseCount == 1, "\(await manager._testArchiveService._testLeaseCount)")
        let snapshotIds = Set(((try? PruneArchiveStore.entries()) ?? []).map(\.reference.id))
        check("BA6 no detail in the batch, so no chunk-archive snapshot was needed", snapshotIds.isEmpty, "\(snapshotIds.count)")
    }

    /// Plan tests 5–6: failure → cooldown from completion; deterministic
    /// failure → one attempt, same alert.
    func failureSection() async {
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(channel: channel, history: archiveSizedHistory())
        router.failSummaries = "transient"
        router.holdSummaries = [1]
        let startedOK = await startBackgroundJob(manager, hold: [1])
        let startedAt = manager._baJobStartedAt ?? .distantFuture
        await sleep(1.5)
        router.gate.release()
        let failed = await waitForJob(manager, "failed", timeout: 60)
        check("BA7 a transient failure: three attempts in the background, then the job fails",
              startedOK && failed && router.summaries == 3, "summaries \(router.summaries), job \(manager._baJobOutcome ?? "nil")")
        check("BA7 the same give-up alert as today (conversation summarization)",
              channel.delivered.contains { $0.contains("conversation summarization") }, "\(channel.delivered)")
        let before = router.summaries
        await turn(manager, "after the failure", reply: "ok")
        let until = manager._baBackoffUntil
        check("BA7 cooldown counts from the job's completion, not its start",
              until.timeIntervalSince(startedAt) > 600 + 1.4, "start→until \(until.timeIntervalSince(startedAt))")
        check("BA7 the job is dropped and the turn inside the cooldown starts nothing",
              manager._baJobOutcome == nil && router.summaries == before, "summaries \(router.summaries)")
        check("BA7 the raw messages stay in the conversation", manager._testMessages.count > 20)
        manager._svSetArchiveBackoff(until: Date().addingTimeInterval(-1))
        router.failSummaries = nil
        router.holdSummaries = []
        await turn(manager, "after the cooldown", reply: "ok")
        let restarted = await waitForJob(manager, "succeeded")
        check("BA7 a turn after the cooldown starts a new job", restarted && router.summaries == before + 1,
              "summaries \(router.summaries)")

        let det = SVRecordingChannel(kind: .telegram)
        let manager2 = await freshManager(channel: det, history: archiveSizedHistory())
        router.failSummaries = "deterministic"
        _ = await startBackgroundJob(manager2, hold: [])
        let failed2 = await waitForJob(manager2, "failed")
        check("BA8 a deterministic failure: one attempt only", failed2 && router.summaries == 1, "summaries \(router.summaries)")
        check("BA8 same alert (deterministic wording)", det.delivered.contains { $0.contains("conversation summarization") }, "\(det.delivered)")
    }

    /// Plan tests 14 (mode switch) and 15–16 (inline path in this build).
    func modeSection() async {
        // Inline: today's notice, phase and same-turn commit.
        let channel = SVRecordingChannel(kind: .telegram)
        let history = archiveSizedHistory()
        let manager = await freshManager(channel: channel, history: history, inline: true)
        let idle = await turn(manager, "inline archive", reply: "inline reply")
        let main = mainRequests.last
        check("BM1 inline: the 🧠 notice is sent", channel.delivered.contains("🧠 Summarizing and archiving the oldest part of the conversation…"),
              "\(channel.delivered)")
        check("BM1 inline: archived in the same turn — the request no longer carries the batch, and shows the new row",
              idle && main.map { !conversation($0).contains("end of old-0.") && system($0).contains("Fixture summary #1") } == true)
        check("BM1 inline: no background job is left behind", manager._baJobOutcome == nil && !contains(manager, [history[0].id]))
        let status = await manager._baCommand("/status")
        check("BM1 /status in inline mode", status.contains("🧠 Memory archiving: waits before replying"), status)

        // Switch while a background job runs: it stays in the background.
        let switching = SVRecordingChannel(kind: .telegram)
        let manager2 = await freshManager(channel: switching, history: archiveSizedHistory())
        _ = await startBackgroundJob(manager2)
        let reply = await manager2._baCommand("/archiveinline on")
        check("BM2 /archiveinline on during a background job: accepted, the running job stays in the background",
              reply.contains("now waits before replying") && reply.contains("finishes there") && manager2._baJobOutcome == "running", reply)
        await turn(manager2, "turn while the switched job runs", reply: "ok")
        check("BM2 a turn after the switch neither waits nor starts an inline archive (one job at a time)",
              manager2._baJobOutcome == "running" && router.summaries == 1, "summaries \(router.summaries)")
        router.gate.release()
        _ = await waitForJob(manager2, "succeeded")
        let batch = manager2._baJobBatchIds
        await turn(manager2, "turn after the switched job", reply: "ok")
        check("BM3 the switched job still commits at the next turn", containsNone(manager2, batch) && manager2._baJobOutcome == nil)
        let off = await manager2._baCommand("/archiveinline off")
        check("BM4 /archiveinline off", off.contains("now runs in the background") && !ConversationManager.archiveInlineEnabled, off)
        let usage = await manager2._baCommand("/archiveinline sometimes")
        check("BM4 /archiveinline with a bad argument shows usage", usage.contains("Usage: /archiveinline on|off"), usage)
        let listed = ChatCommandRegistry.commandsListText()
        check("BM5 /archiveinline is listed in /commands (no menu entry)",
              listed.contains("/archiveinline") && !ChatCommandRegistry.menuCommands.contains { $0.command == "archiveinline" }, listed)
    }
}
