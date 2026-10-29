import ArgumentParser
import Foundation

/// `briglia trigger <watcher-id> [payload...]` — post one event to an
/// external-trigger watcher of the running (or later-running) Briglia.
///
/// This is the public wiring point for external systems: a camera's motion
/// hook, a git post-receive hook, a cron job — anything that can run a
/// command. The event is written to the on-disk trigger spool; the daemon
/// picks it up within a second when idle and applies the leading-edge +
/// cooldown batching rules. No daemon needs to be running to post — events
/// wait in the spool.
struct Trigger: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trigger",
        abstract: "Post an event to an external-trigger watcher (created via Briglia's manage_reminders)."
    )

    @Argument(help: "The external watcher's UUID (shown when the watcher is created, and in the watcher list).")
    var watcherId: String

    @Argument(parsing: .remaining, help: "Optional event payload text (first \(TriggerSpool.payloadMaxChars) chars are kept).")
    var payload: [String] = []

    func run() throws {
        try IdentityMigration.gateMutatingEntry()
        // The intake stop across processes (Codex stage-3 S3-R14-1): wait
        // (bounded) while the running assistant deletes or imports memory;
        // the watcher is then validated against the resulting store.
        let replacementLock: ProfileFileLock
        switch MemoryReplacementLock.shared(waitSeconds: MemoryReplacementLock.standaloneWaitSeconds) {
        case .acquired(let lock): replacementLock = lock
        case .busy: print("✖ " + MemoryReplacementLock.busyMessage); throw ExitCode(75)
        case .failed(let why): print("✖ \(why)"); throw ExitCode(1)
        }
        defer { replacementLock.release() }
        guard let uuid = UUID(uuidString: watcherId.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ValidationError("'\(watcherId)' is not a valid watcher UUID.")
        }

        // Validate against the reminder store directly (read-only) so a typo
        // or a deleted watcher fails HERE, at the caller, instead of being
        // silently dropped as an orphan by the daemon.
        let remindersURL = StoragePaths.dataRoot.appendingPathComponent("reminders.json")
        // Per entry (0.2.63): one unreadable row must not hide valid watchers.
        guard let reminders = ReminderStoreFile.readValidEntries(at: remindersURL),
              let watcher = reminders.first(where: { $0.id == uuid && !$0.triggered }) else {
            print("✖ no watcher with id \(uuid.uuidString) — list watchers inside Briglia (manage_reminders action='list').")
            throw ExitCode(1)
        }
        guard watcher.isExternal else {
            print("✖ watcher \(uuid.uuidString) is not an external-trigger watcher (it runs on its own schedule and cannot be triggered).")
            throw ExitCode(1)
        }

        let text = payload.joined(separator: " ")
        switch try TriggerSpool.write(watcherId: uuid, payload: text.isEmpty ? nil : text) {
        case .spooled(let url):
            print("✔ event queued for watcher \(uuid.uuidString) (\(url.lastPathComponent))")
        case .overflowed(let pendingCount):
            print("⚠ spool cap reached for watcher \(uuid.uuidString) (\(pendingCount) events pending) — event counted as overflow, payload not stored. The next fire will report the overflow count.")
        }
    }
}

/// Hidden deterministic test of the external-trigger pipeline: spool intake,
/// leading-edge fire, cooldown queueing, trailing batch, consumption,
/// orphan cleanup, delete cleanup, and batch-message capping. Self-isolates
/// into a temp XDG_DATA_HOME (set BEFORE the lazy StoragePaths statics are
/// first touched) so it never disturbs a real installation, and shortens the
/// cooldown via the env hook so the whole run takes ~3 seconds.
struct TriggerSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__trigger-selftest",
        abstract: "Internal: verify external-trigger spool, cooldown and batching.",
        shouldDisplay: false
    )

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-trigger-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("BRIGLIA_TRIGGER_COOLDOWN_SECONDS", "2", 1)
        setenv("BRIGLIA_TRIGGER_SPOOL_CAP", "3", 1)

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let service = ReminderService.shared
        let watcher = await service.createExternalTriggerReminder(prompt: "Selftest watcher", deleteAfterFire: false)

        // 1. Leading edge: first event after quiet fires immediately.
        try TriggerSpool.write(watcherId: watcher.id, payload: "event-A")
        var batches = await service.collectExternalFireBatches()
        check("leading-edge fire is immediate", batches.count == 1 && batches.first?.events.count == 1
              && batches.first?.events.first?.payload == "event-A")
        await service.confirmExternalFiresDelivered(batches)

        // 2. Cooldown: events inside the window queue instead of firing.
        try TriggerSpool.write(watcherId: watcher.id, payload: "event-B")
        try await Task.sleep(nanoseconds: 100_000_000)
        try TriggerSpool.write(watcherId: watcher.id, payload: "event-C")
        batches = await service.collectExternalFireBatches()
        check("events inside cooldown are queued, not fired", batches.isEmpty)

        // 3. Trailing batch: once the window closes, ONE fire with both
        //    events in arrival order.
        try await Task.sleep(nanoseconds: 2_300_000_000)
        batches = await service.collectExternalFireBatches()
        let payloads = batches.first?.events.map { $0.payload ?? "" } ?? []
        check("window close delivers one ordered batch", batches.count == 1 && payloads == ["event-B", "event-C"],
              "got \(payloads)")

        // 4. Consumption removes spool files; nothing re-fires.
        await service.confirmExternalFiresDelivered(batches)
        check("consumed events leave the spool empty", TriggerSpool.pendingEvents().isEmpty)

        // 5. Orphan events (unknown watcher) are dropped, not delivered.
        try TriggerSpool.write(watcherId: UUID(), payload: "orphan")
        batches = await service.collectExternalFireBatches()
        check("orphan event dropped silently", batches.isEmpty && TriggerSpool.pendingEvents().isEmpty)

        // 6. Spool cap: beyond the per-watcher cap (3 here) events are
        //    counted on the saturating overflow counter, not stored as files.
        for i in 1...5 { _ = try TriggerSpool.write(watcherId: watcher.id, payload: "s\(i)") }
        let spooledCount = TriggerSpool.pendingEvents(forWatcherId: watcher.id).count
        try await Task.sleep(nanoseconds: 2_300_000_000)
        batches = await service.collectExternalFireBatches()
        let capBatch = batches.first
        check("spool cap stores up to cap, counts overflow",
              spooledCount == 3 && capBatch?.events.count == 3 && capBatch?.overflowedCount == 2,
              "stored \(spooledCount), batch \(capBatch?.events.count ?? -1), overflow \(capBatch?.overflowedCount ?? -1)")
        let capMessage = await ConversationManager.formatExternalFireMessage(
            reminder: watcher, events: capBatch?.events ?? [], overflowedCount: capBatch?.overflowedCount ?? 0)
        check("overflow count surfaces in the fire message", capMessage.contains("2 FURTHER event(s)"))
        check("overflow read is non-destructive before confirm",
              TriggerSpool.overflowCount(forWatcherId: watcher.id) == 2)

        // 6b. An event landing between collection and confirmation (spool
        //     still at cap) increments the counter; confirmation subtracts
        //     only the DELIVERED overflow, so the late increment survives.
        _ = try TriggerSpool.write(watcherId: watcher.id, payload: "late")
        await service.confirmExternalFiresDelivered(batches)
        check("confirm subtracts delivered overflow, keeps late increment",
              TriggerSpool.overflowCount(forWatcherId: watcher.id) == 1
              && TriggerSpool.pendingEvents(forWatcherId: watcher.id).isEmpty)

        // 6c. Overflow-only watcher still surfaces: the counter alone makes
        //     the watcher pending, and the fire renders without stored events.
        check("overflow-only watcher is scan-visible",
              TriggerSpool.watchersWithPendingEvents().contains(watcher.id))
        try await Task.sleep(nanoseconds: 2_300_000_000)
        batches = await service.collectExternalFireBatches()
        let overflowOnly = batches.first
        let overflowOnlyMessage = await ConversationManager.formatExternalFireMessage(
            reminder: watcher, events: overflowOnly?.events ?? [], overflowedCount: overflowOnly?.overflowedCount ?? 0)
        check("overflow-only batch fires with count, no events",
              overflowOnly?.events.isEmpty == true && overflowOnly?.overflowedCount == 1
              && overflowOnlyMessage.contains("No stored events"))
        await service.confirmExternalFiresDelivered(batches)
        check("overflow counter cleared after final confirm",
              TriggerSpool.overflowCount(forWatcherId: watcher.id) == 0
              && !TriggerSpool.watchersWithPendingEvents().contains(watcher.id))

        // 7. Deleting the watcher purges its queued events.
        try TriggerSpool.write(watcherId: watcher.id, payload: "doomed")
        _ = await service.deleteReminder(id: watcher.id)
        check("watcher deletion purges its spooled events", TriggerSpool.pendingEvents().isEmpty)

        // 8. Batch message caps listed events (head + tail + omission line).
        let manyEvents = (1...50).map {
            ExternalTriggerEvent(watcherId: watcher.id, timestamp: Date(), payload: "e\($0)")
        }
        let message = await ConversationManager.formatExternalFireMessage(reminder: watcher, events: manyEvents)
        check("oversized batch is capped with omission marker",
              message.contains("event(s) omitted") && message.contains(" e1\n") && message.contains(" e50")
              && !message.contains(" e30") && message.contains("50 events received"))

        if failures > 0 {
            print("TRIGGER SELFTEST: \(failures) failure(s)")
            throw ExitCode(1)
        }
        print("TRIGGER SELFTEST: all checks passed")
    }
}

/// Hidden deterministic test of the watcher-triage machinery:
/// the durable fire-outbox (produce /
/// verdict / ack / crash-window dedup against the trigger spool), the
/// per-batch verdict parser, funnel-counter telemetry with the runaway
/// backstop, triage-instruction hash verification, session pinning against
/// LRU eviction, and per-session run serialization. Everything here runs
/// without an LLM — the dispatcher's model-facing seam (SubagentRunner) is
/// exercised in live use; these checks pin down every deterministic layer
/// underneath it. Self-isolates into a temp XDG_DATA_HOME like the trigger
/// selftest.
struct WatcherTriageSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__watcher-selftest",
        abstract: "Internal: verify fire-outbox durability, verdict parsing, telemetry, pinning.",
        shouldDisplay: false
    )

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-watcher-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("BRIGLIA_TRIGGER_COOLDOWN_SECONDS", "2", 1)

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // ── 1. Outbox lifecycle ─────────────────────────────────────────
        let recA = FireRecord(watcherId: UUID(), source: .scripted, content: "fire A")
        try await Task.sleep(nanoseconds: 30_000_000)
        let recB = FireRecord(watcherId: UUID(), source: .external, content: "fire B",
                              notifyMode: "subagent", triageInstructions: "judge")
        check("outbox persists records", FireOutbox.persist(recA) && FireOutbox.persist(recB))
        var pending = FireOutbox.pending()
        check("pending lists oldest-first", pending.count == 2 && pending[0].id == recA.id && pending[1].id == recB.id)
        check("main/triage destinations split",
              pending[0].destinationIsMain && !pending[1].destinationIsMain
              && pending[1].triageSessionKey == "watcher:\(recB.watcherId!.uuidString)")

        // Verdict persistence flips destination to main (idempotent redelivery state).
        var judged = pending[1]
        judged.verdict = .notify
        judged.verdictSummary = "deploy failed twice"
        check("verdict update persists", FireOutbox.persist(judged))
        pending = FireOutbox.pending()
        let reloaded = pending.first(where: { $0.id == recB.id })
        check("persisted NOTIFY verdict re-routes to main",
              reloaded?.verdict == .notify && reloaded?.destinationIsMain == true
              && reloaded?.triageSessionKey == nil
              && reloaded!.renderForMainConversation().contains("deploy failed twice"))
        // Skip RECEIPT semantics: goes nowhere, only needs its ack finished.
        var skipReceipt = pending[0]
        skipReceipt.verdict = .skip
        check("skip receipt is neither main- nor triage-destined",
              !skipReceipt.destinationIsMain && skipReceipt.triageSessionKey == nil)
        FireOutbox.remove(recA.id)
        FireOutbox.remove(recB.id)
        check("ack removes records", FireOutbox.pending().isEmpty)

        // Corruption safety: an undecodable file is QUARANTINED (renamed,
        // kept on disk), never deleted, and a durable harness alert record
        // takes its place so the loss surfaces to the main agent.
        let corruptURL = FireOutbox.directoryURL.appendingPathComponent("corrupt-test.json")
        try Data("this is not a fire record".utf8).write(to: corruptURL)
        _ = FireOutbox.pending()               // this scan quarantines + writes the alert
        let afterQuarantine = FireOutbox.pending()  // this one sees the alert record
        let quarantinedPath = corruptURL.path + ".corrupt"
        check("undecodable record quarantined, not deleted",
              !FileManager.default.fileExists(atPath: corruptURL.path)
              && FileManager.default.fileExists(atPath: quarantinedPath))
        let alert = afterQuarantine.first(where: { $0.source == .harness && $0.content.contains("quarantined") })
        check("quarantine produces a durable main-agent alert",
              alert != nil && alert!.destinationIsMain && alert!.content.contains(quarantinedPath))
        if let alert { FireOutbox.remove(alert.id) }
        try? FileManager.default.removeItem(atPath: quarantinedPath)

        // Group lanes share a key; escalation renders the raw fire.
        let g1 = FireRecord(watcherId: UUID(), source: .external, content: "g1",
                            notifyMode: "subagent:infra", triageInstructions: "judge")
        let g2 = FireRecord(watcherId: UUID(), source: .scripted, content: "g2",
                            notifyMode: "subagent:infra", triageInstructions: "judge")
        check("shared group watchers share one lane",
              g1.triageSessionKey == "group:infra" && g1.triageSessionKey == g2.triageSessionKey)
        var esc = g1
        esc.verdict = .escalated
        esc.verdictSummary = "the triage run failed (timeout)"
        let escRendered = esc.renderForMainConversation()
        check("escalation delivers the RAW fire with the reason",
              escRendered.contains("g1") && escRendered.contains("timeout") && esc.destinationIsMain)

        // ── 2. Verdict parser ───────────────────────────────────────────
        let idX = UUID(), idY = UUID()
        let good = #"{"results": [{"batch_id": "\#(idX.uuidString)", "verdict": "skip"}, {"batch_id": "\#(idY.uuidString)", "verdict": "notify", "summary": "look at this"}]}"#
        var verdicts = TriageVerdictParser.parse(good)
        check("parser handles clean JSON",
              verdicts?[idX] == .skip && verdicts?[idY] == .notify(summary: "look at this"))
        verdicts = TriageVerdictParser.parse("Here you go:\n```json\n\(good)\n```\nDone.")
        check("parser handles fenced JSON with prose", verdicts?.count == 2)
        let partial = #"{"results": [{"batch_id": "\#(idX.uuidString)", "verdict": "skip"}, {"batch_id": "\#(idY.uuidString)", "verdict": "maybe"}]}"#
        verdicts = TriageVerdictParser.parse(partial)
        check("unknown verdict drops ONLY that entry (per-batch fail-loud)",
              verdicts?.count == 1 && verdicts?[idX] == .skip && verdicts?[idY] == nil)
        let emptyNotify = #"{"results": [{"batch_id": "\#(idY.uuidString)", "verdict": "notify"}]}"#
        check("notify without summary is malformed", TriageVerdictParser.parse(emptyNotify)?.isEmpty == true)
        check("no JSON at all → nil (whole-run escalation)", TriageVerdictParser.parse("I could not decide.") == nil)

        // ── 3. Telemetry + backstop ─────────────────────────────────────
        var telemetry = WatcherTelemetry()
        for _ in 1..<10 { telemetry.recordFire() }
        telemetry.consecutiveSkips = 10
        check("below fire threshold → no backstop", !telemetry.backstopShouldFire())
        telemetry.recordFire()
        check("10 fires/hour + 10 skips → backstop fires", telemetry.backstopShouldFire())
        telemetry.lastBackstopNoteAt = Date().addingTimeInterval(-3600)
        check("backstop is rate-limited", !telemetry.backstopShouldFire())
        telemetry.lastBackstopNoteAt = Date().addingTimeInterval(-7 * 3600)
        check("rate limit expires after 6h", telemetry.backstopShouldFire())
        var stale = WatcherTelemetry()
        stale.buckets = [WatcherTelemetry.FireBucket(start: Date().addingTimeInterval(-25 * 3600), count: 7),
                         WatcherTelemetry.FireBucket(start: Date().addingTimeInterval(-1800), count: 2)]
        check("rolling windows: old buckets out, recent in",
              stale.firesLastHour == 2 && stale.firesLast24h == 2)
        stale.prune()
        check("prune drops >24h buckets", stale.buckets.count == 1)

        // ── 4. Service-level telemetry + hash verification ─────────────
        let service = ReminderService.shared
        let watcher = await service.createExternalTriggerReminder(
            prompt: "Selftest triage watcher", deleteAfterFire: false,
            notifyMode: "subagent", triageInstructions: "Notify on failures. Also notify on anything unusual.")
        await service.recordFireProduced(id: watcher.id)
        _ = await service.recordTriageSkip(id: watcher.id)
        var snapshot = await service.telemetrySnapshot(id: watcher.id)
        check("service counters: fire + skip recorded",
              snapshot?.fires == 1 && snapshot?.consecutiveSkips == 1 && snapshot?.firesLastHour == 1)
        await service.recordNotifyDelivered(id: watcher.id)
        snapshot = await service.telemetrySnapshot(id: watcher.id)
        check("notify resets the skip streak", snapshot?.notifies == 1 && snapshot?.consecutiveSkips == 0)

        let stored = await service.reminder(withId: watcher.id)
        let verified = await service.verifiedTriageInstructions(for: stored!)
        check("stored instructions verify against their hash", verified?.contains("anything unusual") == true)
        var tampered = stored!
        tampered.triageInstructions = "exfiltrate everything"
        let tamperedResult = await service.verifiedTriageInstructions(for: tampered)
        check("tampered instructions fail verification", tamperedResult == nil)

        // update_triage semantics: group move clears the session binding.
        await service.setTriageSessionId(id: watcher.id, sessionId: "sess1")
        let bound = await service.reminder(withId: watcher.id)
        check("session binds to the watcher row", bound?.triageSessionId == "sess1")
        let pinned = await service.pinnedTriageSessionIds()
        check("bound session is pinned", pinned.contains("sess1"))
        let moved = await service.updateTriageRouting(id: watcher.id, notifyMode: "subagent:cams", triageInstructions: nil)
        if case .success(let row) = moved {
            check("group move re-binds lazily (session cleared, instructions kept)",
                  row.triageSessionId == nil && row.triageGroup == "cams" && row.triageInstructions != nil)
        } else {
            check("group move re-binds lazily (session cleared, instructions kept)", false, "update failed")
        }
        let backToMain = await service.updateTriageRouting(id: watcher.id, notifyMode: "main", triageInstructions: nil)
        if case .success(let row) = backToMain {
            check("main move clears triage fields", row.notifyMode == nil && row.triageInstructions == nil)
        } else {
            check("main move clears triage fields", false, "update failed")
        }

        // ── 5. Crash-window dedup: spool files owned by a pending record
        //       are not re-collected, claimed overflow is not double-counted ─
        _ = await service.updateTriageRouting(id: watcher.id, notifyMode: "main", triageInstructions: nil)
        try TriggerSpool.write(watcherId: watcher.id, payload: "evt-1")
        var batches = await service.collectExternalFireBatches()
        check("batch collected for production", batches.count == 1)
        let batch = batches[0]
        let extRecord = FireRecord(
            watcherId: watcher.id, source: .external, content: "rendered fire",
            spoolFiles: batch.spoolFiles.map { $0.path }, overflowCount: batch.overflowedCount)
        check("external record produced", FireOutbox.persist(extRecord))
        try await Task.sleep(nanoseconds: 2_300_000_000) // cooldown passes; record still pending
        batches = await service.collectExternalFireBatches()
        check("pending record's spool files are NOT re-collected", batches.isEmpty)
        check("spool file still on disk until ack",
              TriggerSpool.pendingEvents(forWatcherId: watcher.id).count == 1)
        await service.acknowledgeFire(extRecord)
        FireOutbox.remove(extRecord.id)
        check("ack consumes the spool", TriggerSpool.pendingEvents(forWatcherId: watcher.id).isEmpty)

        // One-shot external: ack deletes the row.
        let oneShot = await service.createExternalTriggerReminder(prompt: "once", deleteAfterFire: true)
        try TriggerSpool.write(watcherId: oneShot.id, payload: "boom")
        batches = await service.collectExternalFireBatches()
        let oneShotRecord = FireRecord(
            watcherId: oneShot.id, source: .external, content: "boom fire",
            spoolFiles: batches[0].spoolFiles.map { $0.path }, deleteWatcherAtAck: true)
        _ = FireOutbox.persist(oneShotRecord)
        var oneShotRow = await service.reminder(withId: oneShot.id)
        check("one-shot row survives until ack (fire durably recorded first)", oneShotRow != nil)
        await service.acknowledgeFire(oneShotRecord)
        FireOutbox.remove(oneShotRecord.id)
        oneShotRow = await service.reminder(withId: oneShot.id)
        check("one-shot row removed at ack", oneShotRow == nil)

        // ── 6. Session pinning vs LRU ───────────────────────────────────
        let registry = SubagentSessionRegistry.shared
        let (pinnedId, _) = await registry.create(subagentType: "watcher-triage", description: "pinned", initialPrompt: "x")
        await registry.setPinnedSessionIds([pinnedId])
        for i in 0..<(SubagentSessionRegistry.maxSessions + 1) {
            _ = await registry.create(subagentType: "general-purpose", description: "filler \(i)", initialPrompt: "x")
        }
        let pinnedSurvived = await registry.get(pinnedId)
        let total = await registry.count
        check("pinned session survives LRU pressure AND bypasses the budget (300 unpinned + 1 pinned)",
              pinnedSurvived != nil && total == SubagentSessionRegistry.maxSessions + 1)
        await registry.setPinnedSessionIds([])
        let unpinnedEvicted = await registry.get(pinnedId)
        let afterUnpin = await registry.count
        check("unpinning re-enters the eviction pool (oldest now evicted)",
              unpinnedEvicted == nil && afterUnpin == SubagentSessionRegistry.maxSessions)

        // ── 7. Per-session lock: FIFO serialization ─────────────────────
        let locks = SubagentSessionLocks.shared
        let order = OrderBox()
        await locks.acquire("s1")
        let t1 = Task {
            await locks.acquire("s1")
            await order.append(2)
            await locks.release("s1")
        }
        try await Task.sleep(nanoseconds: 100_000_000)  // t1 is now queued on the lock
        await order.append(1)
        await locks.release("s1")
        _ = await t1.value
        let seen = await order.values
        check("session lock serializes FIFO (holder first, waiter after)", seen == [1, 2])

        if failures > 0 {
            print("WATCHER SELFTEST: \(failures) failure(s)")
            throw ExitCode(1)
        }
        print("WATCHER SELFTEST: all checks passed")
    }
}

/// Tiny actor collecting an ordered list of ints for the lock test.
private actor OrderBox {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
