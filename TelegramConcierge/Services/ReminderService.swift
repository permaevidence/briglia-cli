#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Reminder Service

/// Singleton actor that manages reminder persistence and scheduling
actor ReminderService {
    static let shared = ReminderService()

    /// A scripted reminder chain stops (fires one final error message, no
    /// reschedule) after this many consecutive script failures.
    static let maxConsecutiveScriptFailures = 3
    /// Wall-clock cap for one check-script run, in seconds.
    static let scriptTimeoutSeconds = 60
    /// Tail cap applied to script stdout/stderr before it enters the envelope.
    static let scriptOutputTailChars = 4_000
    /// Floor for `every_X_minutes` recurrence on scripted reminders.
    static let minScriptedIntervalMinutes = 5
    /// External-trigger cooldown: after a fire, further events queue and are
    /// delivered as ONE batched fire once this window has passed (leading-edge
    /// fire + trailing batch). Env override is an internal test hook only.
    static let externalTriggerCooldownSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["BRIGLIA_TRIGGER_COOLDOWN_SECONDS"],
           let value = TimeInterval(raw), value > 0 {
            return value
        }
        return 300
    }()

    private var reminders: [Reminder] = []

    /// Harness-authored one-line notices about scripted-reminder creation,
    /// sent to the user's chat by ConversationManager's poll loop. The agent
    /// cannot suppress these — they exist so a check script created during a
    /// compromised turn is always surfaced. Persisted to disk and removed only
    /// after confirmed delivery, so a restart or a transient send failure
    /// cannot lose the audit trail.
    private var creationNotices: [String] = []

    private let remindersFileURL: URL = {
        let folder = StoragePaths.dataRoot
        try? PrivateStorage.ensureDirectory(folder)
        return folder.appendingPathComponent("reminders.json")
    }()

    private let scriptsDirectoryURL: URL = {
        let folder = StoragePaths.dataRoot.appendingPathComponent("reminder-scripts", isDirectory: true)
        try? PrivateStorage.ensureDirectory(folder)
        return folder
    }()

    /// Directory the tool description points check scripts at for their own
    /// seen-state files. Created eagerly so scripts can `touch` files in it.
    private let scriptStateDirectoryURL: URL = {
        let folder = StoragePaths.dataRoot.appendingPathComponent("reminder-scripts/state", isDirectory: true)
        try? PrivateStorage.ensureDirectory(folder)
        return folder
    }()

    private let noticesFileURL: URL = {
        let folder = StoragePaths.dataRoot
        try? PrivateStorage.ensureDirectory(folder)
        return folder.appendingPathComponent("reminder-notices.json")
    }()

    private init() {
        // Notices first: a load problem queues a notice, which the notice
        // load would otherwise overwrite.
        loadNotices()
        loadReminders()
    }

    // MARK: - Public API

    /// Add a new plain (time-based) reminder and persist it.
    func addReminder(triggerDate: Date, prompt: String, recurrence: RecurrenceType? = nil) -> Reminder {
        let reminder = Reminder(triggerDate: triggerDate, prompt: prompt, recurrence: recurrence)
        reminders.append(reminder)
        saveReminders()
        print("[ReminderService] Added reminder \(reminder.id) for \(triggerDate)\(recurrence != nil ? " (recurring: \(recurrence!.description))" : "")")
        return reminder
    }

    /// Registration-time validation failure for a scripted reminder.
    struct ScriptValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Create a script-backed reminder. The script is written to disk and then
    /// VALIDATED by running it twice against its real (harness-owned) state
    /// file: the first run seeds the baseline, the second must exit 0 and
    /// print nothing. Registration is rejected — and the script and state
    /// removed — if either run fails, so the "test before registering"
    /// contract is enforced rather than advisory. Returns the reminder plus
    /// an optional warning when the seed run printed output (a baseline-rule
    /// violation that is tolerated but worth surfacing to the agent).
    func createScriptedReminder(
        triggerDate: Date,
        prompt: String,
        recurrence: RecurrenceType,
        scriptSource: String,
        deleteAfterFire: Bool,
        notifyMode: String? = nil,
        triageInstructions: String? = nil,
        triageModelLane: String? = nil
    ) async throws -> (reminder: Reminder, seedOutputWarning: String?) {
        let id = UUID()
        let fileURL = scriptsDirectoryURL.appendingPathComponent("\(id.uuidString).sh")
        do {
            try PrivateStorage.writeAtomically(Data(scriptSource.utf8), to: fileURL, mode: 0o700)
        } catch {
            throw ScriptValidationError(message: "Failed to store script: \(error.localizedDescription)")
        }

        func cleanupAndThrow(_ message: String) throws -> Never {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: stateFileURL(forReminderId: id))
            throw ScriptValidationError(message: message)
        }

        // Seed run: establishes the baseline in the real state file. Must
        // exit 0; output is tolerated but reported back as a warning.
        let seed = await executeScript(atPath: fileURL.path, reminderId: id)
        if seed.timedOut || seed.exitCode != 0 {
            try cleanupAndThrow("Validation failed on the seed run (\(seed.timedOut ? "timeout" : "exit \(seed.exitCode)")). stderr: \(seed.stderrTail)")
        }
        // Silent run: steady-state with no news must exit 0 and print nothing.
        var silent = await executeScript(atPath: fileURL.path, reminderId: id)
        if silent.timedOut || silent.exitCode != 0 {
            try cleanupAndThrow("Validation failed on the second run (\(silent.timedOut ? "timeout" : "exit \(silent.exitCode)")). stderr: \(silent.stderrTail)")
        }
        if !silent.stdoutTrimmed.isEmpty {
            // A busy source can emit a REAL new event between the seed and the
            // silent run — indistinguishable, on one sample, from a broken
            // seen-state. One immediate re-run disambiguates: a correct script
            // has marked the event seen and now prints nothing; a broken one
            // re-reports it.
            let retry = await executeScript(atPath: fileURL.path, reminderId: id)
            if retry.timedOut || retry.exitCode != 0 {
                try cleanupAndThrow("Validation failed on the third run (\(retry.timedOut ? "timeout" : "exit \(retry.exitCode)")). stderr: \(retry.stderrTail)")
            }
            if !retry.stdoutTrimmed.isEmpty {
                try cleanupAndThrow("Validation failed: two consecutive runs printed output, so the script re-reports already-seen events instead of deltas. Fix the seen-state logic (use $WATCHER_STATE) — a steady-state run must print nothing. Output: \(String(retry.stdoutTrimmed.prefix(500)))")
            }
            silent = retry
        }

        let reminder = Reminder(
            id: id,
            triggerDate: triggerDate,
            prompt: prompt,
            recurrence: recurrence,
            scriptPath: fileURL.path,
            deleteAfterFire: deleteAfterFire ? true : nil,
            scriptSHA256: Self.sha256Hex(of: scriptSource),
            notifyMode: notifyMode,
            triageInstructions: triageInstructions,
            triageInstructionsSHA256: triageInstructions.map(Self.sha256Hex(of:)),
            triageModelLane: triageModelLane
        )
        reminders.append(reminder)
        saveReminders()
        let promptSnippet = String(prompt.prefix(80))
        let routingNote = (notifyMode?.hasPrefix("subagent") == true)
            ? " Fires go to a triage subagent first; only escalations reach the main conversation."
            : ""
        creationNotices.append("🔭 Check-script reminder created, \(recurrence.description): \"\(promptSnippet)\".\(routingNote) If you didn't ask for this, tell me to delete it.")
        saveNotices()
        print("[ReminderService] Added scripted reminder \(reminder.id) (recurring: \(recurrence.description))")

        let warning = seed.stdoutTrimmed.isEmpty ? nil
            : "Note: the seed run printed output. With a correct baseline rule the first run is silent too — the current script would have dumped pre-existing state as news on its first real check. Validation seeded the baseline anyway, so this is now harmless, but review the FIRST-run branch."
        return (reminder, warning)
    }

    // MARK: - External-trigger watchers

    /// Create an external-trigger watcher: no schedule, no script — it fires
    /// when an external process posts an event via `briglia trigger <id>`.
    /// `triggerDate` is pinned to the distant future so the clock-based due
    /// check never selects the row.
    func createExternalTriggerReminder(
        prompt: String,
        deleteAfterFire: Bool,
        notifyMode: String? = nil,
        triageInstructions: String? = nil,
        triageModelLane: String? = nil
    ) -> Reminder {
        let reminder = Reminder(
            triggerDate: .distantFuture,
            prompt: prompt,
            deleteAfterFire: deleteAfterFire ? true : nil,
            externalTrigger: true,
            notifyMode: notifyMode,
            triageInstructions: triageInstructions,
            triageInstructionsSHA256: triageInstructions.map(Self.sha256Hex(of:)),
            triageModelLane: triageModelLane
        )
        reminders.append(reminder)
        saveReminders()
        let promptSnippet = String(prompt.prefix(80))
        let routingNote = (notifyMode?.hasPrefix("subagent") == true)
            ? " Fires go to a triage subagent first; only escalations reach the main conversation."
            : ""
        creationNotices.append("📡 External-trigger watcher created: \"\(promptSnippet)\". It fires when a local command posts an event to it.\(routingNote) If you didn't ask for this, tell me to delete it.")
        saveNotices()
        print("[ReminderService] Added external-trigger reminder \(reminder.id)")
        return reminder
    }

    /// One deliverable external fire: a watcher plus every event currently
    /// spooled for it. The whole batch must be handed back via
    /// `confirmExternalFiresDelivered` only after the fire message has been
    /// appended to durable history — a crash in between re-delivers.
    struct ExternalFireBatch {
        let reminder: Reminder
        let events: [ExternalTriggerEvent]
        let spoolFiles: [URL]
        /// Events beyond the per-watcher spool cap: counted, not stored.
        let overflowedCount: Int
    }

    /// Scan the trigger spool and return the batches ready to fire now.
    /// Per watcher: fire when events are pending AND the cooldown since the
    /// last fire has passed (or there was no previous fire) — that single
    /// condition yields the owner's semantics: an event after ≥5 quiet minutes
    /// fires immediately; events landing inside the window queue and are
    /// delivered together when it closes. `lastExternalFireDate` is advanced
    /// and persisted here, so a re-scan before consumption confirms cannot
    /// double-fire the same batch on the next tick (it queues instead).
    /// Events addressed to unknown or non-external watcher ids are dropped.
    ///
    /// This runs on every idle poll tick, so the scan is filename-only
    /// (`watchersWithPendingEvents`) — event files are decoded exclusively
    /// for watchers that actually fire now.
    func collectExternalFireBatches() -> [ExternalFireBatch] {
        let pendingIds = TriggerSpool.watchersWithPendingEvents()
        guard !pendingIds.isEmpty else { return [] }

        // Sources already owned by a pending outbox record must not mint a
        // second batch: a crash between record production and ack leaves both
        // the record and its spool files on disk, and the record alone owns
        // re-delivery. Same for the overflow counter — subtract the counts
        // already claimed by pending records from what a new batch may claim.
        let pendingRecords = FireOutbox.pending()
        let referencedFiles = Set(pendingRecords.flatMap { $0.spoolFiles })
        var claimedOverflow: [UUID: Int] = [:]
        for record in pendingRecords {
            if let id = record.watcherId {
                claimedOverflow[id, default: 0] += record.overflowCount
            }
        }

        var batches: [ExternalFireBatch] = []
        let now = Date()
        for watcherId in pendingIds {
            guard let index = reminders.firstIndex(where: { $0.id == watcherId && $0.isExternal && !$0.triggered }) else {
                print("[ReminderService] Dropping spooled event(s) for unknown watcher \(watcherId)")
                TriggerSpool.removeEvents(forWatcherId: watcherId)
                continue
            }
            if let lastFire = reminders[index].lastExternalFireDate,
               now.timeIntervalSince(lastFire) < Self.externalTriggerCooldownSeconds {
                continue // window still open — keep queueing
            }
            // Keep spool-file (arrival) order: filenames lead with a
            // millisecond timestamp, whereas the encoded event timestamp has
            // only second granularity — re-sorting on it would scramble
            // same-second bursts. The overflow read is NON-destructive: the
            // counter is only decremented on delivery confirmation, so a
            // failed save can never lose the count. A batch may be
            // overflow-only (every event in the window exceeded the cap).
            let items = TriggerSpool.pendingEvents(forWatcherId: watcherId)
                .filter { !referencedFiles.contains($0.url.path) }
            let overflowed = max(0, TriggerSpool.overflowCount(forWatcherId: watcherId) - (claimedOverflow[watcherId] ?? 0))
            guard !items.isEmpty || overflowed > 0 else { continue } // all owned by pending records, or corrupt
            reminders[index].lastExternalFireDate = now
            batches.append(ExternalFireBatch(
                reminder: reminders[index],
                events: items.map { $0.event },
                spoolFiles: items.map { $0.url },
                overflowedCount: overflowed
            ))
        }
        if !batches.isEmpty { saveReminders() }
        return batches
    }

    /// Consume one fire batch's sources after its FINAL destination durably
    /// acknowledged it (outbox §3b): delete the referenced spool files,
    /// subtract the claimed overflow count, and remove a one-shot external
    /// watcher row. Idempotent — crash between this and the outbox-record
    /// removal just re-runs harmless deletes.
    func acknowledgeFire(_ record: FireRecord) {
        if !record.spoolFiles.isEmpty {
            TriggerSpool.remove(record.spoolFiles.map { URL(fileURLWithPath: $0) })
        }
        if let watcherId = record.watcherId {
            TriggerSpool.confirmOverflowDelivered(forWatcherId: watcherId, count: record.overflowCount)
            if record.deleteWatcherAtAck {
                _ = deleteReminder(id: watcherId)
            }
        }
    }

    /// Settle delivered batches once their fire messages are durably stored:
    /// delete the consumed spool files and subtract the reported overflow
    /// counts (increments that landed mid-delivery survive for the next
    /// fire). Never called when the conversation save failed — the spool and
    /// counters then re-deliver after the cooldown.
    func confirmExternalFiresDelivered(_ batches: [ExternalFireBatch]) {
        for batch in batches {
            TriggerSpool.remove(batch.spoolFiles)
            TriggerSpool.confirmOverflowDelivered(forWatcherId: batch.reminder.id, count: batch.overflowedCount)
        }
    }

    // MARK: - Watcher telemetry (funnel counters)

    private func withTelemetry(id: UUID, _ mutate: (inout WatcherTelemetry) -> Void) -> WatcherTelemetry? {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return nil }
        var telemetry = reminders[index].telemetry ?? WatcherTelemetry()
        mutate(&telemetry)
        telemetry.prune()
        reminders[index].telemetry = telemetry
        saveReminders()
        return telemetry
    }

    /// Count one polled script run (scripted watchers).
    func recordWatcherCheck(id: UUID) {
        _ = withTelemetry(id: id) { $0.checks += 1 }
    }

    /// Count one produced fire batch (the §5 definition of "fire").
    func recordFireProduced(id: UUID) {
        _ = withTelemetry(id: id) { $0.recordFire() }
    }

    /// Count a fire reaching the main agent (notify:main delivery or a
    /// triage NOTIFY verdict); resets the SKIP streak.
    func recordNotifyDelivered(id: UUID) {
        _ = withTelemetry(id: id) {
            $0.notifies += 1
            $0.consecutiveSkips = 0
        }
    }

    /// Count a triage SKIP verdict. Returns the updated counters so the
    /// caller can evaluate the deterministic backstop.
    func recordTriageSkip(id: UUID) -> WatcherTelemetry? {
        withTelemetry(id: id) { $0.consecutiveSkips += 1 }
    }

    /// Stamp the backstop rate limit after its note was produced.
    func markBackstopNoted(id: UUID) {
        _ = withTelemetry(id: id) { $0.lastBackstopNoteAt = Date() }
    }

    func telemetrySnapshot(id: UUID) -> WatcherTelemetry? {
        reminders.first(where: { $0.id == id })?.telemetry
    }

    // MARK: - Triage routing (phase 2)

    /// Return triage instructions ONLY when the row still matches the hash
    /// recorded through manage_reminders — instructions edited out-of-band
    /// decide what silently disappears, so a mismatch escalates instead.
    func verifiedTriageInstructions(for reminder: Reminder) -> String? {
        guard let instructions = reminder.triageInstructions,
              let expected = reminder.triageInstructionsSHA256,
              Self.sha256Hex(of: instructions) == expected else { return nil }
        return instructions
    }

    /// Update a watcher's routing and/or triage instructions (the
    /// `update_triage` action — gating to user-typed turns happens in the
    /// tool layer). Routing changes re-bind sessions lazily: the session id
    /// is cleared here and re-resolved on the next dispatched fire; the old
    /// group keeps its own history (no migration).
    /// `newLane`: nil = leave unchanged, "inherit" = clear (run triage on the
    /// main model), a lane name = set. Moving the watcher to notify='main'
    /// always clears the lane — it has no meaning without triage.
    func updateTriageRouting(id: UUID, notifyMode newMode: String?, triageInstructions newInstructions: String?, triageModelLane newLane: String? = nil) -> Result<Reminder, ScriptValidationError> {
        guard let index = reminders.firstIndex(where: { $0.id == id && !$0.triggered }) else {
            return .failure(ScriptValidationError(message: "No reminder found with that ID."))
        }
        guard reminders[index].isScripted || reminders[index].isExternal else {
            return .failure(ScriptValidationError(message: "Only watchers (script-backed or external-trigger reminders) support triage routing — plain reminders always notify you directly."))
        }
        // Validate the RESULTING state before touching the row — a failure
        // must leave the in-memory store exactly as it was.
        let resultingMode = newMode.map { $0 == "main" ? nil : $0 } ?? reminders[index].notifyMode
        let resultingInstructions = newMode == "main"
            ? nil
            : (newInstructions ?? reminders[index].triageInstructions)
        if (resultingMode?.hasPrefix("subagent") == true) && (resultingInstructions ?? "").isEmpty {
            return .failure(ScriptValidationError(message: "Routing to a triage subagent requires triage_instructions."))
        }
        if resultingMode == nil && newInstructions != nil && newMode == nil {
            return .failure(ScriptValidationError(message: "This watcher notifies the main conversation — set notify='subagent' (or a group) before giving it triage_instructions."))
        }
        if let newMode {
            if newMode != reminders[index].notifyMode {
                reminders[index].triageSessionId = nil
            }
            reminders[index].notifyMode = newMode == "main" ? nil : newMode
            if newMode == "main" {
                reminders[index].triageInstructions = nil
                reminders[index].triageInstructionsSHA256 = nil
            }
        }
        if let newInstructions, reminders[index].routesToTriage {
            reminders[index].triageInstructions = newInstructions
            reminders[index].triageInstructionsSHA256 = Self.sha256Hex(of: newInstructions)
        }
        if newMode == "main" {
            reminders[index].triageModelLane = nil
        } else if let newLane {
            let resolved: String? = newLane == "inherit" ? nil : newLane
            // A lane change on a group member applies GROUP-WIDE (the mode
            // was applied above, so triageGroup reflects the resulting
            // state): a shared session runs one model per drain, and a
            // per-member divergence would just be silently overridden at
            // dispatch. Mirrors setTriageSessionId's group-wide binding.
            if let group = reminders[index].triageGroup {
                for i in reminders.indices where reminders[i].triageGroup == group {
                    reminders[i].triageModelLane = resolved
                }
            } else {
                reminders[index].triageModelLane = resolved
            }
        }
        saveReminders()
        refreshPinnedSessions()
        let promptSnippet = String(reminders[index].prompt.prefix(60))
        creationNotices.append("🔀 Watcher triage routing updated for \"\(promptSnippet)\" → \(reminders[index].notifyMode ?? "main"). If you didn't ask for this, tell me to revert it.")
        saveNotices()
        return .success(reminders[index])
    }

    /// Bind a triage session to a watcher — and, for a shared group, to every
    /// row of that group, so the whole group resolves to one session.
    func setTriageSessionId(id: UUID, sessionId: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        if let group = reminders[index].triageGroup {
            for i in reminders.indices where reminders[i].triageGroup == group {
                reminders[i].triageSessionId = sessionId
            }
        } else {
            reminders[index].triageSessionId = sessionId
        }
        saveReminders()
        refreshPinnedSessions()
    }

    /// Resolve the session bound to a watcher's triage lane: its own row, or
    /// any row sharing its group.
    func resolveTriageSessionId(for reminder: Reminder) -> String? {
        if let own = reminder.triageSessionId { return own }
        guard let group = reminder.triageGroup else { return nil }
        return reminders.first(where: { $0.triageGroup == group && $0.triageSessionId != nil })?.triageSessionId
    }

    func reminder(withId id: UUID) -> Reminder? {
        reminders.first(where: { $0.id == id && !$0.triggered })
    }

    /// Triage sessions that must survive LRU eviction: any session bound to a
    /// live watcher (§4). Pushed to SubagentSessionRegistry on every change.
    func pinnedTriageSessionIds() -> Set<String> {
        Set(reminders.compactMap { $0.triggered ? nil : $0.triageSessionId })
    }

    /// Prospective pinned-session lanes if one more were added: dedicated
    /// subagent watchers each own a lane; shared groups own one lane each.
    /// Enforces the pinned-session cap (§4) at watcher creation.
    func triageLaneCount() -> Int {
        var lanes = Set<String>()
        for reminder in reminders where !reminder.triggered && reminder.routesToTriage {
            if let group = reminder.triageGroup {
                lanes.insert("group:\(group)")
            } else {
                lanes.insert("watcher:\(reminder.id.uuidString)")
            }
        }
        return lanes.count
    }

    /// Hard cap on triage session lanes (pinned sessions bypass the normal
    /// 300-session LRU budget, so they get their own bound).
    static let maxTriageLanes = 50

    private func refreshPinnedSessions() {
        let pinned = pinnedTriageSessionIds()
        Task { await SubagentSessionRegistry.shared.setPinnedSessionIds(pinned) }
    }

    /// Push the pinned set to the session registry (startup hydration).
    func publishPinnedSessions() {
        refreshPinnedSessions()
    }

    /// Pending harness-authored creation notices, oldest first. The caller
    /// sends them and confirms delivery with `confirmCreationNoticesSent` —
    /// notices are only removed after a successful send, and they persist
    /// across restarts.
    func pendingCreationNotices() -> [String] {
        creationNotices
    }

    /// Remove the first `count` notices after they were successfully sent.
    func confirmCreationNoticesSent(count: Int) {
        guard count > 0 else { return }
        creationNotices.removeFirst(min(count, creationNotices.count))
        saveNotices()
    }
    
    /// Get all reminders that are due (past trigger time and not yet triggered).
    /// Paused watchers keep their row but are never due until resumed.
    func getDueReminders() -> [Reminder] {
        let now = Date()
        // External-trigger rows are pinned to .distantFuture; the isExternal
        // exclusion is belt-and-braces so they can never enter the clock path.
        return reminders.filter { !$0.triggered && !$0.isPaused && !$0.isExternal && $0.triggerDate <= now }
    }
    
    /// Complete a due plain reminder's occurrence: one-shots are removed,
    /// recurring ones have their single row advanced in place to the next
    /// FUTURE occurrence. Called BEFORE the reminder message is appended, so
    /// the next poll tick can't double-fire. Skipping past-due occurrences
    /// means a reminder that was due repeatedly while the app was closed
    /// fires once on relaunch instead of replaying the whole backlog; rows
    /// are reused in place so triggered occurrences no longer accumulate in
    /// reminders.json. Returns the next trigger date, or nil if the reminder
    /// ended.
    func completePlainOccurrence(id: UUID) -> Date? {
        guard let index = reminders.firstIndex(where: { $0.id == id }),
              !reminders[index].isScripted else { return nil }
        guard let recurrence = reminders[index].recurrence else {
            reminders.remove(at: index)
            saveReminders()
            return nil
        }
        var nextDate = recurrence.nextTriggerDate(from: reminders[index].triggerDate)
        while nextDate <= Date() {
            nextDate = recurrence.nextTriggerDate(from: nextDate)
        }
        reminders[index].triggerDate = nextDate
        saveReminders()
        return nextDate
    }

    /// Advance a scripted reminder's single standing row to its next future
    /// occurrence, mutating in place. Called BEFORE the check script runs, so
    /// a crash mid-check leaves the watcher pending at the next occurrence
    /// instead of lost. Missed occurrences (app closed) are skipped, never
    /// fired as a backlog. A scripted row without recurrence (should not
    /// exist — creation requires one) is deleted as a completed one-shot.
    func advanceScriptedOccurrence(id: UUID) {
        guard let index = reminders.firstIndex(where: { $0.id == id }),
              reminders[index].isScripted else { return }
        guard let recurrence = reminders[index].recurrence else {
            let removed = reminders.remove(at: index)
            saveReminders()
            removeScriptFileIfOrphaned(removed.scriptPath)
            try? FileManager.default.removeItem(at: stateFileURL(forReminderId: removed.id))
            return
        }
        var nextDate = recurrence.nextTriggerDate(from: reminders[index].triggerDate)
        while nextDate <= Date() {
            nextDate = recurrence.nextTriggerDate(from: nextDate)
        }
        reminders[index].triggerDate = nextDate
        saveReminders()
    }

    /// Update a scripted reminder's consecutive-failure streak in place.
    /// A reset to 0 records a successful run, which also clears the
    /// resume-without-success counter (the watcher proved healthy again).
    func setScriptFailures(id: UUID, count: Int) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        let stored = reminders[index].consecutiveFailures ?? 0
        let clearsResumes = count == 0 && reminders[index].resumesSinceLastSuccess != nil
        guard stored != count || clearsResumes else { return }
        reminders[index].consecutiveFailures = count == 0 ? nil : count
        if count == 0 { reminders[index].resumesSinceLastSuccess = nil }
        saveReminders()
    }

    /// Pause a scripted watcher in place (failure cap reached): the row,
    /// script file and seen-state survive so the watcher can be re-armed.
    /// Returns the resume-without-success count at pause time so the failure
    /// envelope can tell the agent whether resuming again is reasonable.
    func pauseScriptedReminder(id: UUID) -> Int {
        guard let index = reminders.firstIndex(where: { $0.id == id }),
              reminders[index].isScripted else { return 0 }
        reminders[index].paused = true
        saveReminders()
        print("[ReminderService] Paused scripted reminder \(id)")
        return reminders[index].resumesSinceLastSuccess ?? 0
    }

    /// Re-arm a paused watcher. Deliberately allowed from ANY turn (including
    /// the ambient failure turn): resuming only re-arms hash-verified code
    /// that was created in a user-typed turn — it cannot introduce or alter
    /// code, so an injected instruction gains nothing beyond re-running a
    /// script the user already approved. The script hash is re-verified here
    /// so a file tampered while paused can never be re-armed. Returns the
    /// next check date on success, or a human-readable error.
    ///
    /// EXCEPTION (Codex round 4, 2026-08-27): a watcher quarantined by a Mind
    /// import REFUSES here. The any-turn rationale above rests on "the user
    /// already approved this script" — imported scripts were never approved
    /// on this installation (the archive carries script and hash together),
    /// so an injected instruction resuming one WOULD gain arbitrary code
    /// execution. Only the user-typed /resumewatcher command clears the
    /// quarantine (`resumeImportedWatcher`).
    func resumeScriptedReminder(id: UUID) -> Result<Date, ScriptValidationError> {
        let outcome = resumeScriptedReminderInMemory(id: id)
        if case .success(let nextCheck) = outcome {
            saveReminders()
            print("[ReminderService] Resumed scripted reminder \(id), next check \(nextCheck)")
        }
        return outcome
    }

    /// Shared validate+mutate core of the resume — NO persistence. Callers
    /// decide how to save: fire-and-forget for the ordinary failure-cap
    /// path (`resumeScriptedReminder`), one checked atomic save for the
    /// /resumewatcher approval (`resumeImportedWatcher` — Codex round 5:
    /// two saves in that transaction meant the first, unchecked one could
    /// land an active watcher on disk while the failed checked save made
    /// memory and the reply claim it stayed quarantined).
    private func resumeScriptedReminderInMemory(id: UUID) -> Result<Date, ScriptValidationError> {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else {
            return .failure(ScriptValidationError(message: "No reminder found with that ID."))
        }
        guard reminders[index].isScripted else {
            return .failure(ScriptValidationError(message: "That reminder has no check script — only paused watchers can be resumed."))
        }
        if reminders[index].isImportQuarantined {
            return .failure(ScriptValidationError(message: "This watcher was restored from a Mind backup and is security-quarantined: its check script was never approved on this installation, so it cannot be resumed from any agent or ambient turn. Only the user can re-arm it, by typing /resumewatcher \(reminders[index].id.uuidString) themselves — tell them, and do not attempt any other resume path."))
        }
        guard reminders[index].isPaused else {
            return .failure(ScriptValidationError(message: "That watcher is not paused — it is already running on its schedule."))
        }
        guard verifiedScriptSource(for: reminders[index]) != nil else {
            return .failure(ScriptValidationError(message: "The stored script no longer matches its creation hash (modified on disk while paused) — refusing to re-arm it. Delete the watcher and have the user request it again."))
        }
        guard let recurrence = reminders[index].recurrence else {
            return .failure(ScriptValidationError(message: "The watcher has no recurrence and cannot be rescheduled — delete it and have the user request it again."))
        }
        reminders[index].paused = nil
        reminders[index].consecutiveFailures = nil
        reminders[index].resumesSinceLastSuccess = (reminders[index].resumesSinceLastSuccess ?? 0) + 1
        // Next check: the earlier of "one polling interval from now" and the
        // row's own next future occurrence — so a 5-min watcher checks again
        // within 5 minutes, and a daily watcher doesn't fire off-schedule
        // sooner than its next natural slot… but never later than one full
        // interval either, whichever comes first.
        var nextDate = reminders[index].triggerDate
        while nextDate <= Date() {
            nextDate = recurrence.nextTriggerDate(from: nextDate)
        }
        let oneIntervalFromNow = recurrence.nextTriggerDate(from: Date())
        reminders[index].triggerDate = min(nextDate, oneIntervalFromNow)
        return .success(reminders[index].triggerDate)
    }

    /// Watchers quarantined by a Mind import, awaiting user review
    /// (the /resumewatcher listing).
    func importQuarantinedWatchers() -> [Reminder] {
        reminders.filter { $0.isImportQuarantined }
    }

    /// User approval of ONE import-quarantined watcher — reachable only from
    /// the user-typed /resumewatcher command, never from `manage_reminders`.
    /// A single checked transaction (Codex round 5): clear the flag and run
    /// the resume validation+mutation IN MEMORY ONLY (hash re-verified,
    /// nothing persisted), then perform exactly ONE checked atomic save.
    /// If that save throws, the in-memory row rolls back to quarantined and
    /// disk — never written in this flow — still holds the quarantined row,
    /// so memory, disk, and the user-facing reply agree in every failure
    /// path. (The previous shape saved twice: an unchecked save inside the
    /// shared resume could land an active watcher on disk while the failed
    /// checked save reported it as still quarantined.)
    func resumeImportedWatcher(id: UUID) -> Result<Date, ScriptValidationError> {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else {
            return .failure(ScriptValidationError(message: "No reminder found with that ID."))
        }
        guard reminders[index].isImportQuarantined else {
            return .failure(ScriptValidationError(message: "That watcher is not import-quarantined — nothing to approve. (A watcher paused after script failures is resumed by asking Briglia.)"))
        }
        let original = reminders[index]
        reminders[index].importQuarantined = nil
        switch resumeScriptedReminderInMemory(id: id) {
        case .failure(let error):
            // Hash mismatch / missing recurrence: the approval does not
            // apply — restore the quarantine so the row stays reviewable
            // (nothing was saved anywhere).
            reminders[index] = original
            return .failure(error)
        case .success(let nextCheck):
            do {
                try saveRemindersChecked()
            } catch {
                reminders[index] = original
                return .failure(ScriptValidationError(message: "Could not save the approval to disk (\(error.localizedDescription)) — the watcher stays quarantined. Check disk space and retry /resumewatcher."))
            }
            print("[ReminderService] User approved import-quarantined watcher \(id)")
            return .success(nextCheck)
        }
    }

    /// Return the script source for a reminder, but ONLY when the file still
    /// matches the hash recorded at creation — tampered content must never be
    /// re-embedded into the conversation as trusted agent-authored text.
    func verifiedScriptSource(for reminder: Reminder) -> String? {
        guard let path = reminder.scriptPath,
              let expected = reminder.scriptSHA256,
              let source = try? String(contentsOfFile: path, encoding: .utf8),
              Self.sha256Hex(of: source) == expected else { return nil }
        return source
    }

    /// Delete a reminder by ID
    /// Returns true if successful, false if not found
    func deleteReminder(id: UUID) -> Bool {
        if let index = reminders.firstIndex(where: { $0.id == id }) {
            let removed = reminders.remove(at: index)
            saveReminders()
            removeScriptFileIfOrphaned(removed.scriptPath)
            if removed.isScripted {
                try? FileManager.default.removeItem(at: stateFileURL(forReminderId: id))
            }
            if removed.isExternal {
                TriggerSpool.removeEvents(forWatcherId: id)
            }
            if removed.triageSessionId != nil {
                // Unpin the (possibly shared) session: it re-enters the
                // normal LRU pool once no live watcher points at it, so its
                // history stays discoverable until ordinary eviction.
                refreshPinnedSessions()
            }
            print("[ReminderService] Deleted reminder \(id)")
            return true
        }
        return false
    }

    /// Remove a check-script file once no PENDING reminder references it.
    /// Scripted reminders live on a single in-place row, so normally the one
    /// deletion orphans the file immediately; ignoring triggered rows also
    /// covers any legacy per-occurrence rows from before the in-place model.
    private func removeScriptFileIfOrphaned(_ scriptPath: String?) {
        guard let scriptPath else { return }
        guard !reminders.contains(where: { !$0.triggered && $0.scriptPath == scriptPath }) else { return }
        // Only ever delete inside our own scripts directory.
        guard scriptPath.hasPrefix(scriptsDirectoryURL.path) else { return }
        try? FileManager.default.removeItem(atPath: scriptPath)
    }
    
    /// Get all pending (not triggered) reminders
    func getPendingReminders() -> [Reminder] {
        reminders.filter { !$0.triggered }
    }
    
    /// Get count of pending reminders
    func pendingCount() -> Int {
        reminders.filter { !$0.triggered }.count
    }
    
    /// Clear all reminders (for memory reset)
    func clearAllReminders() {
        let scriptPaths = Set(reminders.compactMap { $0.scriptPath })
        let scriptedIds = reminders.filter { $0.isScripted }.map { $0.id }
        reminders.removeAll()
        // A full reset replaces whatever is on disk, readable or not (the
        // user asked for everything gone): no reconcile, no merge. The wipe
        // removes the recovery copies separately.
        storeBaseline = []
        clearStoreBlock()
        discardDiskRowsUntilWritten = true
        do { try writeRemindersFile() } catch { print("[ReminderService] Failed to save reminders: \(error)") }
        for path in scriptPaths where path.hasPrefix(scriptsDirectoryURL.path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        for id in scriptedIds {
            try? FileManager.default.removeItem(at: stateFileURL(forReminderId: id))
        }
        // Creation notices are the durable audit trail of watcher creation;
        // after a full memory reset there is nothing left to audit, and a
        // surviving notice would be delivered by the poll loop AFTER the
        // wipe (Codex round 4). Clear memory and the on-disk mirror both.
        creationNotices.removeAll()
        try? FileManager.default.removeItem(at: noticesFileURL)
        TriggerSpool.removeAll()
        FireOutbox.removeAll()
        refreshPinnedSessions()
        print("[ReminderService] Cleared all reminders")
    }

    // MARK: - Check-script execution

    /// Outcome of running a due scripted reminder's check script.
    enum ScriptCheckOutcome {
        /// Script ran clean and printed nothing: no news, reschedule silently.
        case noNews
        /// Script printed output: fire the reminder with the output attached.
        case fired(output: String)
        /// Script failed (nonzero exit or timeout). `newFailureCount` is the
        /// consecutive-failure count including this run; `giveUp` is true when
        /// the cap is reached and the chain must fire an error and stop.
        case failed(error: String, newFailureCount: Int, giveUp: Bool)
    }

    /// Harness-owned seen-state file for a watcher, keyed by reminder id.
    /// Exposed to the script as `$WATCHER_STATE`; created empty on first use
    /// by the script itself, deleted together with the reminder. Keying by id
    /// makes collisions between watchers impossible and re-creation start
    /// from a fresh baseline.
    private func stateFileURL(forReminderId id: UUID) -> URL {
        scriptStateDirectoryURL.appendingPathComponent("\(id.uuidString).txt")
    }

    /// One raw script execution, parsed. Reuses BashTools' foreground runner
    /// so PATH augmentation, secret redaction, and process-tree cleanup match
    /// agent-run bash exactly. Note deliberately absent: `service_key_env` —
    /// watcher scripts always run without injected secrets and must rely on
    /// persistent auth (gh login, files on disk).
    private struct ScriptRunResult {
        let exitCode: Int
        let timedOut: Bool
        let stdoutTrimmed: String
        let stderrTail: String
    }

    private func executeScript(atPath scriptPath: String, reminderId: UUID) async -> ScriptRunResult {
        func shellQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let statePath = stateFileURL(forReminderId: reminderId).path
        // umask 077: whatever the script creates under the data root (its
        // state file, scratch files) is owner-only from the start instead
        // of waiting for the next startup sweep.
        let command = "umask 077; WATCHER_STATE=\(shellQuote(statePath)) \(PlatformShell.path) \(shellQuote(scriptPath))"
        let result = await BashTools.runAttached(command: command, killAfterSeconds: Self.scriptTimeoutSeconds)

        func tail(_ text: String) -> String {
            text.count > Self.scriptOutputTailChars ? "…" + String(text.suffix(Self.scriptOutputTailChars)) : text
        }
        guard let data = result.content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ScriptRunResult(exitCode: -1, timedOut: false, stdoutTrimmed: "", stderrTail: "could not parse script runner result")
        }
        return ScriptRunResult(
            exitCode: json["exit_code"] as? Int ?? -1,
            timedOut: json["execution_timed_out"] as? Bool ?? false,
            stdoutTrimmed: tail((json["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
            stderrTail: tail((json["stderr"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    /// Run a scripted reminder's check script and classify the result.
    func runCheckScript(for reminder: Reminder) async -> ScriptCheckOutcome {
        guard let scriptPath = reminder.scriptPath else {
            return .failed(error: "reminder has no script", newFailureCount: Self.maxConsecutiveScriptFailures, giveUp: true)
        }
        let priorFailures = reminder.consecutiveFailures ?? 0

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            return .failed(error: "check script missing at \(scriptPath)", newFailureCount: Self.maxConsecutiveScriptFailures, giveUp: true)
        }

        // Integrity gate: the creation taint-gate and notice only cover
        // manage_reminders. If the file on disk no longer matches the hash
        // recorded at creation, it was edited through some other path
        // (edit_file, bash, external) — refuse to execute it.
        if let expected = reminder.scriptSHA256 {
            let current = (try? String(contentsOfFile: scriptPath, encoding: .utf8)).map(Self.sha256Hex(of:))
            if current != expected {
                return .failed(
                    error: "check script at \(scriptPath) was modified outside manage_reminders (hash mismatch) — refusing to run it. If the change was intended, delete this reminder and re-create it with the new script.",
                    newFailureCount: Self.maxConsecutiveScriptFailures,
                    giveUp: true
                )
            }
        }

        let run = await executeScript(atPath: scriptPath, reminderId: reminder.id)

        if run.timedOut || run.exitCode != 0 {
            let count = priorFailures + 1
            var errorText = run.timedOut
                ? "script timed out after \(Self.scriptTimeoutSeconds)s"
                : "script exited with code \(run.exitCode)"
            if !run.stderrTail.isEmpty { errorText += "\nstderr: \(run.stderrTail)" }
            return .failed(error: errorText, newFailureCount: count, giveUp: count >= Self.maxConsecutiveScriptFailures)
        }

        if run.stdoutTrimmed.isEmpty {
            return .noNews
        }
        return .fired(output: run.stdoutTrimmed)
    }

    /// Reload reminders after a Mind restore replaces the backing JSON file.
    func reloadFromDisk() {
        reminders.removeAll()
        loadReminders()
    }

    /// STAGED-archive watcher preparation (Codex rounds 1–4, 2026-08-27).
    /// Mutates the reminders.json inside a validated staged Mind BEFORE it
    /// is applied, and THROWS on any read/decode/write problem so the
    /// import rejects with current data untouched. Round 4 moved this from
    /// a post-apply live mutation to the staged file precisely because the
    /// live path saved fire-and-forget: a silent write failure meant the
    /// next restart loaded the archive's original unpaused rows and ran
    /// unreviewed scripts. The mutated staged file IS the file
    /// applyStagedMind copies into place, so the quarantine cannot be lost
    /// between apply and reload.
    ///
    /// 1. REBASE — restored script paths may point at the SOURCE
    ///    installation's root (another machine, user account, or product:
    ///    the layout under reminder-scripts/ is shared, the prefix is not).
    ///    Every managed-layout path (`<reminder-id>.sh`) is rewritten onto
    ///    THIS install's scripts directory when the script rides in the
    ///    staged archive's reminder-scripts/ (which apply copies locally) —
    ///    without this, every restored watcher failed with "check script
    ///    missing" at its first due check. The stored SHA-256 is verified
    ///    against the staged script for an early loud warning, but a
    ///    mismatch still rebases: the run-time integrity gate then refuses
    ///    execution with the precise tamper message, which beats a
    ///    misleading "missing at <old path>".
    ///
    /// 2. QUARANTINE — every scripted watcher is PAUSED with durable
    ///    `importQuarantined` provenance. The archive is untrusted input:
    ///    its scripts AND their expected hashes travel together, so the
    ///    hash proves integrity, never authenticity — a malicious .mind can
    ///    carry a due watcher with matching arbitrary shell code that would
    ///    otherwise run automatically at the next due check. Quarantined
    ///    rows keep their script, state, and schedule, but only the
    ///    user-typed /resumewatcher command can re-arm them
    ///    (`manage_reminders` resume refuses on the provenance flag).
    ///    External-trigger and plain time-based reminders carry no code and
    ///    stay armed.
    ///
    /// static (non-actor-isolated): pure file work on the staged tree — it
    /// must not touch (or wait on) the live actor state, which still
    /// belongs to the pre-import Mind at this point.
    ///
    /// Returns the number of scripted watchers quarantined, for the
    /// /importmind completion message.
    static func prepareStagedReminders(stagedRoot: URL) throws -> Int {
        let file = stagedRoot.appendingPathComponent("reminders.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        var rows: [Reminder]
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            rows = try decoder.decode([Reminder].self, from: Data(contentsOf: file))
        } catch {
            throw ScriptValidationError(message: "The backup's reminders.json cannot be read (\(error.localizedDescription)) — its watchers could not be quarantined for review, so the archive is refused.")
        }
        let stagedScriptsDir = stagedRoot.appendingPathComponent("reminder-scripts", isDirectory: true)
        let localScriptsDir = StoragePaths.dataRoot.appendingPathComponent("reminder-scripts", isDirectory: true)
        var quarantinedCount = 0
        for index in rows.indices {
            guard let path = rows[index].scriptPath else { continue }
            let expectedName = "\(rows[index].id.uuidString).sh"
            if URL(fileURLWithPath: path).lastPathComponent == expectedName {
                let stagedScript = stagedScriptsDir.appendingPathComponent(expectedName)
                let localPath = localScriptsDir.appendingPathComponent(expectedName).path
                if path != localPath, FileManager.default.fileExists(atPath: stagedScript.path) {
                    if let expected = rows[index].scriptSHA256,
                       let current = (try? String(contentsOf: stagedScript, encoding: .utf8)).map(Self.sha256Hex(of:)),
                       current != expected {
                        print("[ReminderService] WARNING: restored script for watcher \(rows[index].id) fails its hash check — rebasing anyway; the integrity gate will refuse to run it")
                    }
                    rows[index].scriptPath = localPath
                }
            }
            rows[index].paused = true
            rows[index].importQuarantined = true
            quarantinedCount += 1
        }
        if quarantinedCount > 0 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            do {
                try (try encoder.encode(rows)).write(to: file, options: .atomic)
            } catch {
                throw ScriptValidationError(message: "Could not write the quarantined watcher list into the staged backup (\(error.localizedDescription)) — the archive is refused; nothing was changed.")
            }
            print("[ReminderService] Staged import: paths rebased, \(quarantinedCount) scripted watcher(s) quarantined")
        }
        return quarantinedCount
    }
    
    // MARK: - Persistence

    private static func sha256Hex(of text: String) -> String {
        sha256Hex(of: Data(text.utf8))
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func loadNotices() {
        guard FileManager.default.fileExists(atPath: noticesFileURL.path),
              let data = try? Data(contentsOf: noticesFileURL),
              let notices = try? JSONDecoder().decode([String].self, from: data) else { return }
        creationNotices = notices
    }

    private func saveNotices() {
        if creationNotices.isEmpty {
            try? FileManager.default.removeItem(at: noticesFileURL)
            return
        }
        // Best effort (unchanged contract): a failed write keeps the notices
        // in memory; it is logged now rather than swallowed.
        do {
            try PrivateStorage.writeAtomically(try JSONEncoder().encode(creationNotices), to: noticesFileURL)
        } catch {
            print("[ReminderService] Could not persist reminder notices (kept in memory): \(error)")
        }
    }

    // MARK: - Store state (0.2.63, REMINDERS_LOAD_AND_ARG_HINT_PLAN §2.3)
    //
    // Invariant: Briglia never overwrites bytes of reminders.json it has not
    // loaded or preserved. `storeBaseline` = ids memory took from (or last
    // wrote to) disk, so a row deleted in memory is never resurrected by a
    // later merge; `lastKnownDiskHash` detects edits made outside Briglia.

    /// Why writes to reminders.json are refused right now (nil = allowed).
    private var storeBlockReason: String?
    private var blockNoticeQueued = false
    private var storeBaseline: Set<UUID> = []
    /// SHA-256 of the bytes last read or written; nil = unknown.
    private var lastKnownDiskHash: String?
    /// Set by the wipe until its `[]` write succeeds: a failed wipe write
    /// must never let a later save merge the wiped rows back as "unseen".
    private var discardDiskRowsUntilWritten = false

    // Test seams (reminders-load selftest).
    private var injectPreservationFailure = false
    private var injectPreRenameFailure = false
    private var forcedRecoverySuffix: String?
    private var injectRejectedListFailure = false
    func _testForceRecoverySuffix(_ suffix: String?) { forcedRecoverySuffix = suffix }
    func _testInjectRejectedListFailure(_ enabled: Bool) { injectRejectedListFailure = enabled }
    func _testSaveChecked() throws { try saveRemindersChecked() }
    private var reminderFileWrites = 0
    func _testInjectPreservationFailure(_ enabled: Bool) { injectPreservationFailure = enabled }
    func _testInjectPreRenameFailure(_ enabled: Bool) { injectPreRenameFailure = enabled }
    /// The real writer's post-rename directory barrier fails (PrivateStorage seam).
    func _testInjectPostRenameFailure(_ enabled: Bool) {
        let target = remindersFileURL.standardizedFileURL.path
        PrivateStorage.failPostRenameBarrierForTesting = enabled ? { $0 == target } : nil
    }
    func _testStoreBlockReason() -> String? { storeBlockReason }
    func _testReminderFileWrites() -> Int { reminderFileWrites }
    func _testAllReminders() -> [Reminder] { reminders }
    func _testRemoveReminderRow(id: UUID) { reminders.removeAll { $0.id == id } }

    /// Startup and Mind restore (`reloadFromDisk`): memory becomes the file's
    /// valid rows; every bit of reconciliation state is reset first.
    private func loadReminders() {
        reminders = []
        storeBaseline = []
        storeBlockReason = nil
        blockNoticeQueued = false
        lastKnownDiskHash = nil
        discardDiskRowsUntilWritten = false
        let data: Data
        switch ReminderStoreFile.read(remindersFileURL) {
        case .absent:
            print("[ReminderService] Loaded 0 reminders (no reminders.json)")
            return
        case .unreadable(let why):
            blockStore("reminders.json could not be read: \(why)")
            return
        case .data(let bytes):
            data = bytes
        }
        let valid: [Reminder]
        var rejected: [Data] = []
        var notAnArray = false
        switch ReminderStoreFile.decode(data) {
        case .notAnArray:
            valid = []
            notAnArray = true
        case .entries(let rows, let bad):
            valid = rows
            rejected = bad
        }
        var rewrite = false
        if notAnArray || !rejected.isEmpty {
            guard let copies = preserveOriginal(data, rejected: rejected) else {
                // Keep the valid rows working, but never rewrite a file whose
                // contents were not set aside.
                adoptLoaded(valid)
                blockStore(notAnArray
                    ? "reminders.json is not a valid reminder list and could not be backed up"
                    : "\(Self.entries(rejected.count)) in reminders.json could not be read and the file could not be backed up")
                return
            }
            rewrite = true
            queueStoreNotice(notAnArray
                ? "⚠️ reminders.json was not a valid reminder list, so no saved reminders could be loaded. The original file was saved unchanged on this machine as \(copies.original.path). Ask me to look at it if you need those reminders back."
                : "⚠️ \(Self.entries(rejected.count)) in reminders.json could not be read. The original file was saved unchanged on this machine as \(copies.original.path)\(copies.rejected.map { "; the unreadable entr\(rejected.count == 1 ? "y is" : "ies are") also listed in \($0.path)" } ?? ""). The other \(valid.count) loaded normally. Ask me to look at it if you need it back.")
        }
        if adoptLoaded(valid) { rewrite = true }
        lastKnownDiskHash = Self.sha256Hex(of: data)
        if rewrite {
            do { try writeRemindersFile() } catch { print("[ReminderService] Failed to save reminders: \(error)") }
        }
        print("[ReminderService] Loaded \(reminders.count) reminders")
    }

    /// Memory = `valid` minus legacy triggered rows (reminders now reuse their
    /// row in place, so triggered rows are artifacts of the old
    /// occurrence-per-row model); all their ids join the baseline. Returns
    /// whether legacy rows were purged.
    @discardableResult
    private func adoptLoaded(_ valid: [Reminder]) -> Bool {
        reminders = valid.filter { !$0.triggered }
        storeBaseline = Set(valid.map { $0.id })
        let purged = valid.count - reminders.count
        if purged > 0 { print("[ReminderService] Purged \(purged) legacy triggered reminder row(s)") }
        return purged > 0
    }

    /// Before every write (§2.3 commit step 1): when the store is blocked or
    /// the file changed since Briglia last read/wrote it, read it, preserve
    /// it, and merge its never-loaded rows into memory. Never writes
    /// reminders.json itself. Throws (store blocked) when the file cannot be
    /// read or preserved.
    private func reconcileBeforeWrite() throws {
        let data: Data
        switch ReminderStoreFile.read(remindersFileURL) {
        case .absent:
            clearStoreBlock()
            return
        case .unreadable(let why):
            blockStore("reminders.json could not be read: \(why)")
            throw ScriptValidationError(message: "reminders.json was not saved: it could not be read (\(why)) — the change is kept in memory only")
        case .data(let bytes):
            data = bytes
        }
        let hash = Self.sha256Hex(of: data)
        if storeBlockReason == nil, hash == lastKnownDiskHash { return }
        if hash == (try? Self.encodeReminders(reminders)).map({ Self.sha256Hex(of: $0) }) {
            // Disk already equals memory: nothing to preserve or merge.
            lastKnownDiskHash = hash
            clearStoreBlock()
            return
        }
        if discardDiskRowsUntilWritten {
            // A wipe whose `[]` write failed: the user asked for these rows to
            // be gone — never copy or merge them back.
            lastKnownDiskHash = hash
            clearStoreBlock()
            return
        }
        var diskValid: [Reminder] = []
        var rejected: [Data] = []
        var notAnArray = false
        switch ReminderStoreFile.decode(data) {
        case .notAnArray: notAnArray = true
        case .entries(let rows, let bad): diskValid = rows; rejected = bad
        }
        guard let copies = preserveOriginal(data, rejected: rejected) else {
            blockStore("reminders.json changed or could not be fully read, and could not be backed up")
            throw ScriptValidationError(message: "reminders.json was not saved: its current contents could not be backed up first — the change is kept in memory only")
        }
        let inMemory = Set(reminders.map { $0.id })
        let neverLoaded = diskValid.filter { !inMemory.contains($0.id) && !storeBaseline.contains($0.id) && !$0.triggered }
        reminders.append(contentsOf: neverLoaded)
        storeBaseline.formUnion(diskValid.map { $0.id })
        storeBaseline.formUnion(reminders.map { $0.id })
        lastKnownDiskHash = hash
        let wasBlocked = storeBlockReason != nil
        clearStoreBlock()
        var detail = ""
        if notAnArray {
            detail = " It was not a valid reminder list."
        } else if !rejected.isEmpty {
            detail = " \(Self.entries(rejected.count)) in it could not be read\(copies.rejected.map { " (listed in \($0.path))" } ?? "")."
        }
        let merged = neverLoaded.isEmpty ? "" : " \(neverLoaded.count) reminder\(neverLoaded.count == 1 ? "" : "s") found in it \(neverLoaded.count == 1 ? "was" : "were") added to the current list."
        queueStoreNotice(wasBlocked
            ? "⚠️ reminders.json can be read again. Its contents were saved unchanged on this machine as \(copies.original.path) before Briglia wrote its own list.\(detail)\(merged)"
            : "⚠️ reminders.json was changed outside Briglia. That version was saved unchanged on this machine as \(copies.original.path) before Briglia wrote its own list.\(detail)\(merged)")
        print("[ReminderService] reminders.json reconciled before write (preserved at \(copies.original.path); \(neverLoaded.count) row(s) merged)")
    }

    private static func entries(_ count: Int) -> String {
        count == 1 ? "1 reminder" : "\(count) reminders"
    }

    private func blockStore(_ reason: String) {
        storeBlockReason = reason
        print("[ReminderService] \(reason) — reminders.json is left untouched; changes are kept in memory only")
        if !blockNoticeQueued {
            blockNoticeQueued = true
            queueStoreNotice("⚠️ \(reason). I left the file untouched; reminder changes are kept in memory only (lost on restart) until it can be read.")
        }
    }

    private func clearStoreBlock() {
        storeBlockReason = nil
        blockNoticeQueued = false
    }

    private func queueStoreNotice(_ text: String) {
        creationNotices.append(text)
        saveNotices()
    }

    /// Exact copy of the whole original file, created exclusively (never
    /// replaces an earlier copy), plus a best-effort list of the rejected
    /// entries (re-serialised, not byte-exact). nil when the exact copy could
    /// not be made durably.
    private func preserveOriginal(_ data: Data, rejected: [Data]) -> (original: URL, rejected: URL?)? {
        if injectPreservationFailure {
            print("[ReminderService] preservation failed: injected (test seam)")
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: Date())
        let folder = remindersFileURL.deletingLastPathComponent()
        for attempt in 0..<8 {
            let suffix = (attempt == 0 ? forcedRecoverySuffix : nil) ?? UUID().uuidString.prefix(8).lowercased()
            let original = folder.appendingPathComponent("reminders.recovered-\(stamp)-\(suffix).json")
            do {
                try PrivateStorage.writeExclusive(data, to: original)
            } catch {
                if FileManager.default.fileExists(atPath: original.path) || (error as? PrivateStorage.StorageError)?.description.contains("already exists") == true {
                    continue
                }
                print("[ReminderService] preservation failed: \(error)")
                return nil
            }
            var rejectedURL: URL? = nil
            if !rejected.isEmpty {
                var joined = Data("[\n".utf8)
                for (i, raw) in rejected.enumerated() {
                    if i > 0 { joined.append(Data(",\n".utf8)) }
                    joined.append(raw)
                }
                joined.append(Data("\n]\n".utf8))
                let url = folder.appendingPathComponent("reminders.rejected-\(stamp)-\(suffix).json")
                if !injectRejectedListFailure, (try? PrivateStorage.writeExclusive(joined, to: url)) != nil { rejectedURL = url }
            }
            return (original, rejectedURL)
        }
        print("[ReminderService] preservation failed: no free recovery file name")
        return nil
    }

    /// Recovery copies made by the per-entry loader (user data:
    /// /deleteuserdata removes them). nil when the folder cannot be listed.
    static func recoveryFileURLs(in folder: URL = StoragePaths.dataRoot) -> [URL]? {
        guard case .success(let urls) = listRecoveryFiles(in: folder) else { return nil }
        return urls
    }

    /// `.failure(nil)` = the folder is confirmed absent (ENOENT from lstat on
    /// the path itself); `.failure(message)` = it could not be listed.
    private static func listRecoveryFiles(in folder: URL) -> Result<[URL], RecoveryListingError> {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return .success(names.filter {
                ($0.hasPrefix("reminders.recovered-") || $0.hasPrefix("reminders.rejected-")) && $0.hasSuffix(".json")
            }.sorted().map { folder.appendingPathComponent($0) })
        } catch {
            var st = stat()
            if lstat(folder.path, &st) != 0, errno == ENOENT { return .failure(RecoveryListingError(message: nil)) }
            return .failure(RecoveryListingError(message: error.localizedDescription))
        }
    }

    private struct RecoveryListingError: Error { let message: String? }

    /// /deleteuserdata step 12: remove every recovery copy; failures (one per
    /// file, or the listing itself) are returned for the wipe's report.
    static func removeRecoveryFilesForWipe(in folder: URL) -> [String] {
        switch listRecoveryFiles(in: folder) {
        case .success(let urls):
            return urls.compactMap { UserDataWipe.remove($0.path, label: $0.lastPathComponent) }
        case .failure(let failure):
            // Only a confirmed-absent folder is "nothing to remove"; a
            // permission or I/O failure (including an unsearchable ancestor,
            // which also makes fileExists false) is reported.
            guard let message = failure.message else { return [] }
            return ["Could not list the data folder to remove reminder recovery copies (\(message))"]
        }
    }

    private func saveReminders() {
        do {
            try saveRemindersChecked()
        } catch {
            print("[ReminderService] Failed to save reminders: \(error)")
        }
    }

    /// Test seam: force the next checked save(s) to throw — injected-write-
    /// failure coverage for the /resumewatcher approval transaction.
    private var injectCheckedSaveFailure = false
    func _testInjectCheckedSaveFailure(_ enabled: Bool) { injectCheckedSaveFailure = enabled }

    /// Throwing save for callers that must not proceed on a silent write
    /// failure (quarantine approval — disk and memory may never disagree
    /// about a quarantine). The ONLY path that writes reminders.json besides
    /// the startup load's one rewrite and the wipe: reconcile (no write),
    /// then exactly one atomic write.
    private func saveRemindersChecked() throws {
        if injectCheckedSaveFailure {
            throw ScriptValidationError(message: "injected write failure (test seam)")
        }
        try reconcileBeforeWrite()
        try writeRemindersFile()
    }

    private static func encodeReminders(_ rows: [Reminder]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(rows)
    }

    private func writeRemindersFile() throws {
        let attempted = reminders
        let data = try Self.encodeReminders(attempted)
        if injectPreRenameFailure {
            // Test seam: a final-writer failure AFTER reconciliation/adoption,
            // before anything is replaced.
            storeBaseline.formUnion(attempted.map { $0.id })
            throw ScriptValidationError(message: "injected failure before the rename (test seam)")
        }
        do {
            // Atomic: `briglia trigger` reads this file from a separate process
            // to validate watcher ids — a torn in-place write would make it
            // spuriously reject valid triggers (and a crash mid-write could
            // corrupt the whole store).
            try PrivateStorage.writeAtomicallyPhased(data, to: remindersFileURL)
        } catch let replaced as PrivateStorage.ReplacedButNotDurable {
            // The rename happened (writer phase, not a re-read): the change IS
            // in place, only its durability is unconfirmed. Callers see
            // success, so nobody rolls back to a state disk no longer holds
            // (Codex R2-1/R3-1); the warning is real.
            committed(attempted, data: data)
            print("[ReminderService] reminders.json was replaced but its durability could not be confirmed: \(replaced)")
            queueStoreNotice("⚠️ Reminders were saved, but the disk could not confirm the write is durable (\(replaced.underlying)). If the machine loses power soon, the latest reminder change could be lost.")
            return
        } catch {
            // Not replaced: disk still holds its previous bytes. Every id of
            // this attempt is still treated as known from now on (a later
            // merge must never call them unseen — Codex R2-2).
            storeBaseline.formUnion(attempted.map { $0.id })
            throw error
        }
        committed(attempted, data: data)
    }

    private func committed(_ attempted: [Reminder], data: Data) {
        reminderFileWrites += 1
        lastKnownDiskHash = Self.sha256Hex(of: data)
        discardDiskRowsUntilWritten = false
        storeBaseline = Set(attempted.map { $0.id })
    }
}
