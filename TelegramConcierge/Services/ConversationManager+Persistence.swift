import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
import OpenCombineDispatch
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
extension ConversationManager {


    /// Process new Gmail emails (Gmail API version of processNewEmails)

    // MARK: - Persistence
    
    func loadConversation(clearWhenMissing: Bool = false) {
        guard FileManager.default.fileExists(atPath: conversationFileURL.path) else {
            // After a Mind restore from a backup that had no conversation yet,
            // the file is gone but the old messages would otherwise survive in
            // memory and resurrect at the next save.
            if clearWhenMissing {
                messages = []
            }
            committedMessages = []
            noteHistoryLoaded()
            noteSummaryHistoryReplaced()
            return
        }

        do {
            let data = try Data(contentsOf: conversationFileURL)
            messages = try JSONDecoder().decode([Message].self, from: data)
            // What is on disk, before any load-time cleanup below (a failed
            // cleanup save leaves the disk content as the committed view).
            committedMessages = messages
            noteHistoryLoaded()
            var dirty = false
            // Cleanup old compact tool logs from previous runs to keep context lean.
            if pruneOldToolLogMessages() > 0 { dirty = true }
            if migrateLegacyReasoningProvenance() > 0 { dirty = true }
            // Canonical-message check (MIDTURN_NONCE_PLAN §5): persisted or
            // Mind-imported annotations that reference no genuine top-level
            // HUMAN message (.userText; id + content + attachment basenames)
            // are dropped, and kept ones are rebuilt from canonical data and
            // the current storage directories — a syntactically valid orphan
            // must never render as the user, and supplied paths never survive.
            let sanitized = MidTurnDrainSupport.sanitizeOrphanAnnotations(
                in: &messages,
                imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory
            )
            if sanitized.changed {
                // Re-save on ANY mutation — drops AND normalization-only
                // rebuilds. Otherwise supplied paths replaced in memory would
                // survive in conversation.json and leak into Mind exports or
                // a downgraded build (Codex round-3).
                print("[ConversationManager] sanitized harness annotations (\(sanitized.dropped) dropped, canonical reconstruction applied)")
                dirty = true
            }
            if dirty { saveConversation() }
            noteSummaryHistoryReplaced()
        } catch {
            print("Failed to load conversation: \(error)")
            noteHistoryUnreadable(error)
        }
    }

    /// History replaced (startup load, Mind import, wipe): the idle pass's
    /// attempt caches belong to the old history; the next pass also scans
    /// stub snapshots for completeness.
    private func noteSummaryHistoryReplaced() {
        summaryRestoreAttempts = []
        summaryStubRepairUnsupported = []
        summaryRetentionScanPending = true
        scheduleSummaryRetentionIdlePass()
    }

    /// A successful load (or a known-absent file) ends any unreadable-history
    /// episode; the all-clear is sent only if the user was alerted.
    private func noteHistoryLoaded() {
        let wasFailing = historyLoadFailure != nil
        historyLoadFailure = nil
        historyHoldNoticeSent = false
        // The held-message file's state is independent of history (1a
        // round 6): a history load never clears `heldQueueFileProblem`.
        if wasFailing { print("[ConversationManager] Conversation history readable again") }
        Task { await MaintenanceAlertCenter.shared.reportSuccess(.conversationHistory) }
    }

    /// Fail closed (§3.10.2): the file is kept byte-for-byte for repair and
    /// the committed view is marked invalid rather than empty.
    private func noteHistoryUnreadable(_ error: Error) {
        let reason = error.localizedDescription
        historyLoadFailure = reason
        showMaintenanceNotice("Conversation history could not be read (\(reason)); it is preserved and nothing will overwrite it.")
        Task { await MaintenanceAlertCenter.shared.reportFailure(.conversationHistory, error: reason, deterministic: false) }
    }

    /// The only way history bytes reach disk: refused while the existing
    /// file could not be loaded, so an unreadable history is never replaced.
    func writeHistoryFile(_ data: Data) throws {
        if let historyLoadFailure { throw HistoryUnreadable(reason: historyLoadFailure) }
        try Self.historyWriteFaultForTesting?()
        try PrivateStorage.writeAtomically(data, to: conversationFileURL)
        try Self.historyPostWriteFaultForTesting?()
    }

    /// Requalify pre-v0.1.28 reasoning provenance (bare model ids) for
    /// records matching the currently configured model — see
    /// OpenRouterService.requalifiedLegacyProvenance for the attribution
    /// rule and its ONE-SHOT first-launch gate. Without this, a whole
    /// pre-upgrade conversation downgrades to reasoning-note form at once
    /// (live on two machines 2026-08-16). Bare records that don't qualify
    /// on that first launch stay unattributed forever → note path.
    private func migrateLegacyReasoningProvenance() -> Int {
        var migrated = 0
        for index in messages.indices {
            guard let bare = messages[index].finalReasoningModel, !bare.contains("#"),
                  let qualified = OpenRouterService.requalifiedLegacyProvenance(bareModelId: bare)
            else { continue }
            messages[index].finalReasoningModel = qualified
            migrated += 1
        }
        return migrated
    }
    
    /// Returns whether the write actually reached disk — callers persisting
    /// an inbound message consult this to decide if the Telegram update may
    /// be acknowledged (an unacknowledged update re-delivers after restart).
    @discardableResult
    func saveConversation() -> Bool {
        do {
            let data = try JSONEncoder().encode(messages)
            // Atomic so a Mind export copying this file mid-save can never
            // capture a torn JSON.
            try writeHistoryFile(data)
            noteDurableSave()
            return true
        } catch {
            print("Failed to save conversation: \(error)")
            return false
        }
    }

    /// After every successful history save (mid-turn early wake §3.10.2):
    /// everything in `messages` is now durable. Acknowledge completion
    /// notices whose messages were carried, and certify crash records whose
    /// typed bindings reached durable history (a certificate is only a cache
    /// of that search; a failed write changes nothing unsafe).
    private func noteDurableSave() {
        committedMessages = messages
        resolveRoundDeliveries()
        let durableAcks = pendingCompletionAcks.filter { lastSavedMessageIDs.contains($0.key) }
        if !durableAcks.isEmpty {
            for id in durableAcks.keys { pendingCompletionAcks.removeValue(forKey: id) }
            let jobs = Set(durableAcks.values)
            Task { await BackgroundProcessRegistry.shared.acknowledgeDelivered(jobUUIDs: jobs) }
            do {
                try DetachedJobStore.mutate("delivered") { records in
                    for i in records.indices where jobs.contains(records[i].jobId) && records[i].completion == .owed {
                        records[i].completion = .delivered
                        records[i].deliveredAt = Date()
                    }
                    records.removeAll { $0.isSettled }
                }
            } catch {
                // Startup reconciliation finds the notice in history by its
                // id and settles the record then.
                print("[ConversationManager] Could not mark delivered crash records: \(error.localizedDescription)")
            }
        }
        let durableSubagentAcks = pendingSubagentAcks.filter { lastSavedMessageIDs.contains($0.key) }
        if !durableSubagentAcks.isEmpty {
            for id in durableSubagentAcks.keys { pendingSubagentAcks.removeValue(forKey: id) }
            let messageIds = Set(durableSubagentAcks.keys)
            Task { await SubagentBackgroundRegistry.shared.acknowledgeDelivered(messageIds: messageIds) }
            let jobs = Set(durableSubagentAcks.values.compactMap { $0 })
            if !jobs.isEmpty {
                do {
                    try DetachedJobStore.mutate("delivered") { records in
                        for i in records.indices where jobs.contains(records[i].jobId) && records[i].completion == .owed {
                            records[i].completion = .delivered
                            records[i].deliveredAt = Date()
                        }
                        records.removeAll { $0.isSettled }
                    }
                } catch {
                    print("[ConversationManager] Could not mark delivered subagent records: \(error.localizedDescription)")
                }
            }
        }
        certifyDurableBindings()
    }

    /// Runtime certification (§3.12 commit protocol step 2) with monotonic
    /// upgrades (Codex V7 gate 1): a durable `receiptObserved` settles the
    /// job — its notice is withdrawn from the registry and nothing is owed —
    /// even when an earlier `moved` was already certified. Only bound
    /// outcomes are acted on here; `absent`/`unverifiable` belong to the
    /// startup pass (a live job's notice is still in the registry).
    private func certifyDurableBindings() {
        guard FileManager.default.fileExists(atPath: DetachedJobStore.fileURL.path),
              let records = try? DetachedJobStore.load(), records.contains(where: { $0.completion == .owed }) else { return }
        var upgrades: [UUID: OutcomeBinding.Kind] = [:]
        for record in records where record.completion == .owed {
            if case .bound(let kind) = SettlementEvidence.locate(record, history: committedMessages),
               Self.certificateRank(kind) > Self.certificateRank(record.certifiedKind) {
                upgrades[record.jobId] = kind
            }
        }
        guard !upgrades.isEmpty else { return }
        let observed = Set(upgrades.filter { $0.value == .receiptObserved }.keys)
        if !observed.isEmpty {
            Task { await BackgroundProcessRegistry.shared.acknowledgeDelivered(jobUUIDs: observed) }
        }
        do {
            try DetachedJobStore.mutate("certify") { records in
                for i in records.indices {
                    guard let kind = upgrades[records[i].jobId] else { continue }
                    records[i].certifiedKind = kind
                    records[i].certifiedAt = Date()
                    // A durable receipt (bash) or real result (a subagent
                    // that finished while its detach was being committed)
                    // settles the job: nothing is owed.
                    if kind == .receiptObserved || kind == .real { records[i].completion = .notOwed }
                }
                records.removeAll { $0.isSettled }
            }
        } catch {
            // Nothing unsafe: every later decision searches durable evidence.
            print("[ConversationManager] Certificate write failed (evidence stays in history): \(error.localizedDescription)")
        }
    }

    static func certificateRank(_ kind: OutcomeBinding.Kind?) -> Int {
        switch kind {
        case .receiptObserved?: return 3
        case .real?: return 2
        case .moved?: return 1
        default: return 0
        }
    }

    /// Mirrors the in-progress turn's salvage buffer to disk after every
    /// mutation, so a hard crash or force-quit mid-turn cannot lose completed
    /// tool rounds. Cleared once the turn's outcome (success, error, or
    /// cancellation) has been written to conversation.json.
    ///
    /// Checked and owner-scoped (round delivery v3 §2.5, Codex acceptance
    /// check 2): returns whether this run's rounds reached the recovery file.
    /// A run whose ownership passed to a newer run (a /stop, then a new
    /// message) never overwrites or clears that run's file; a failed write
    /// is recorded per run instead of only logged. No delivery is ever
    /// acknowledged on the strength of this file: only saved history counts
    /// (a newer run may clear the file before the stopped run's outcome is
    /// saved).
    @discardableResult
    func persistTurnSalvage(_ interactions: [ToolInteraction], runId: UUID) -> Bool {
        guard activeRunId == nil || activeRunId == runId else {
            salvageWritesRefusedForOwnership += 1
            print("[ConversationManager] Turn salvage not written: a newer turn owns the recovery file")
            return false
        }
        if var checkpoint = activeTurnCheckpoints[runId], checkpoint.isEnvelope {
            checkpoint.retainedInteractions = interactions
            do { try writeTurnCheckpoint(checkpoint); return true }
            catch { checkpointWriteFailure = "Checkpoint write failed: \(error.localizedDescription)"; return false }
        }
        guard !interactions.isEmpty else {
            clearTurnSalvageFile()
            return true
        }
        do {
            try Self.plainSalvageFaultForTesting?()
            let data = try JSONEncoder().encode(interactions)
            try PrivateStorage.writeAtomically(data, to: turnSalvageFileURL)
            turnSalvageWriteFailedRuns.remove(runId)
            return true
        } catch {
            turnSalvageWriteFailedRuns.insert(runId)
            print("[ConversationManager] Failed to persist turn salvage: \(error)")
            return false
        }
    }

    func clearTurnSalvageFile() {
        do {
            if FileManager.default.fileExists(atPath: turnSalvageFileURL.path) {
                try FileManager.default.removeItem(at: turnSalvageFileURL)
                try PrivateStorage.fsyncDirectory(turnSalvageFileURL.deletingLastPathComponent().path)
            }
            recoveryBlocked = false
        } catch { showMaintenanceNotice("Could not clear committed turn checkpoint: \(error.localizedDescription)") }
    }

    /// Turn-outcome clear for `runActiveProcessing`. /stop nils `activeRunId`
    /// immediately, so a follow-up turn can start (and write its own mirror)
    /// while the cancelled run is still unwinding — an unconditional clear
    /// from the old run would delete the new run's crash protection. Only
    /// clear while no newer run owns the file.
    func clearTurnSalvageFile(ifStillOwnedBy runId: UUID) {
        guard activeRunId == nil || activeRunId == runId else { return }
        clearTurnSalvageFile()
    }

    /// A turn_salvage.json left on disk means the previous process died
    /// mid-turn before any outcome reached conversation.json. Convert it into
    /// the same salvaged-work message the cancellation and error paths
    /// produce, so the next turn's prompt replays the completed rounds.
    func recoverInterruptedTurnSalvageIfNeeded() {
        let unpublished = activeTurnCheckpoints.values.filter { $0.pendingRecovery }
        if !unpublished.isEmpty {
            guard activeRunId == nil else { return }
            for checkpoint in unpublished {
                do {
                    try writeTurnCheckpoint(checkpoint)
                    recoverTurnCheckpoint(try JSONEncoder().encode(checkpoint))
                    guard !recoveryBlocked else { return }
                    activeTurnCheckpoints.removeValue(forKey: checkpoint.runID)
                } catch {
                    activeTurnCheckpoints[checkpoint.runID] = checkpoint
                    recoveryBlocked = true
                    showMaintenanceNotice("Unpublished turn work remains in memory: \(error.localizedDescription). Free storage and retry before restarting.")
                    return
                }
            }
            return
        }
        let data: Data
        do {
            guard let stored = try TurnCheckpointStore.read(turnSalvageFileURL) else { return }
            data = stored
        } catch {
            recoveryBlocked = true; showMaintenanceNotice("Turn recovery preserved: \(error.localizedDescription)"); return
        }
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 {
            recoverTurnCheckpoint(data)
            return
        }
        guard let interactions = try? JSONDecoder().decode([ToolInteraction].self, from: data) else {
            recoveryBlocked = true
            showMaintenanceNotice("Invalid turn recovery file preserved; repair it before another turn")
            return
        }
        if interactions.isEmpty { clearTurnSalvageFile(); return }
        if interactions.reduce(0, { $0 + ActiveTurnBudget.round($1) }) > ActiveTurnBudget(maximum: configuredMaxContextTokens()).inputCeiling {
            var checkpoint = TurnCheckpoint(runID: UUID(), taskMessageID: messages.last(where: { $0.role == .user })?.id ?? UUID())
            checkpoint.retainedInteractions = interactions; checkpoint.pendingRecovery = true
            do {
                try writeTurnCheckpoint(checkpoint)
                recoverTurnCheckpoint(try JSONEncoder().encode(checkpoint))
            } catch { recoveryBlocked = true; showMaintenanceNotice("Oversized legacy recovery preserved: \(error.localizedDescription)") }
            return
        }
        // A crash in the window between saveConversation() and
        // clearTurnSalvageFile() leaves a file whose content already reached
        // history on the turn's final message — re-appending it would
        // duplicate the turn. Tool-call IDs are unique per call, so matching
        // ID sequences means the same interactions.
        let recoveredCallIds = interactions.flatMap { $0.assistantMessage.toolCalls.map(\.id) }
        if let last = messages.last,
           last.toolInteractions.flatMap({ $0.assistantMessage.toolCalls.map(\.id) }) == recoveredCallIds {
            if saveConversation() { clearTurnSalvageFile() }
            print("[ConversationManager] Turn salvage already present in history; skipping recovery")
            return
        }
        let recovered = Message(
            role: .assistant,
            content: "⛔ Work interrupted by shutdown after \(interactions.count) operation\(interactions.count == 1 ? "" : "s").",
            toolInteractions: interactions
        )
        messages.append(recovered)
        let recoveredSaved = saveConversation()
        if recoveredSaved { clearTurnSalvageFile() } else { recoveryBlocked = true }
        print("[ConversationManager] Recovered \(interactions.count) tool interaction(s) from a turn interrupted by app termination")
    }

    func loadContextUsageSnapshot(clearWhenMissing: Bool = false) {
        guard FileManager.default.fileExists(atPath: contextUsageFileURL.path) else {
            guard clearWhenMissing else { return }
            isRestoringContextUsageSnapshot = true
            lastPromptTokens = nil
            lastCompletionTokens = nil
            isRestoringContextUsageSnapshot = false
            return
        }

        do {
            let data = try Data(contentsOf: contextUsageFileURL)
            let snapshot = try JSONDecoder().decode(ContextUsageSnapshot.self, from: data)
            isRestoringContextUsageSnapshot = true
            lastPromptRenderKey = snapshot.effectiveRenderKey
            lastPromptTokens = snapshot.lastPromptTokens
            lastCompletionTokens = snapshot.lastCompletionTokens
            isRestoringContextUsageSnapshot = false
        } catch {
            isRestoringContextUsageSnapshot = false
            print("Failed to load context usage snapshot: \(error)")
        }
    }

    func saveContextUsageSnapshot() {
        guard !isRestoringContextUsageSnapshot else { return }

        do {
            let snapshot = ContextUsageSnapshot(
                lastPromptTokens: lastPromptTokens,
                lastCompletionTokens: lastCompletionTokens,
                updatedAt: Date(),
                lastPromptRenderKey: lastPromptTokens == nil ? nil : lastPromptRenderKey
            )
            let data = try JSONEncoder().encode(snapshot)
            try PrivateStorage.writeAtomically(data, to: contextUsageFileURL)
        } catch {
            print("Failed to save context usage snapshot: \(error)")
        }
    }
    
    func clearConversation() {
        messages = []
        summaryRestoreAttempts = []
        summaryStubRepairUnsupported = []
        pendingMidTurnMessages.removeAll()
        inFlightMidTurnBatch = nil
        persistPendingMidTurnQueue()
        lastPromptTokens = nil
        lastCompletionTokens = nil
        saveConversation()
        
        // Also clear images
        try? FileManager.default.removeItem(at: imagesDirectory)
        try? PrivateStorage.ensureDirectory(imagesDirectory)
        try? FileManager.default.removeItem(at: toolAttachmentsDirectory)
        try? PrivateStorage.ensureDirectory(toolAttachmentsDirectory)
    }
    
    /// Delete all memory: conversation, chunks, summaries, user context,
    /// user name, reminders/watchers, files ledger, todos, subagent session
    /// histories, logs, and tool-output/spill artifacts. Background work is
    /// stopped FIRST so nothing repopulates the wiped conversation
    /// afterward (Codex review, 2026-08-20). Keeps: credentials, provider
    /// profiles, settings, skills, channel pairing — and Google-side
    /// Calendar/Contacts, which hold no local Briglia data.
    ///
    /// Returns the failures the wipe could observe (file removals, secret
    /// deletes, the conversation save). Service-internal clears (archives,
    /// ledger, todos, sessions) remain best-effort — they swallow their own
    /// I/O errors today; surfacing those would mean changing each service's
    /// contract.
    /// Restart the active provider's email poller after an ABORTED wipe: the
    /// quiescence steps stopped it, and "nothing was deleted" must also mean
    /// "nothing stays silently broken until the next app restart".
    private func restartEmailPollingAfterAbortedWipe() async {
        switch EmailCalendarProvider.current {
        case .agentmail:
            await AgentMailService.shared.startBackgroundPoll()
        case .none:
            break
        }
    }

    func deleteAllMemory() async -> [String] {
        var failures: [String] = []
        func removeAndRecreate(_ dir: URL, label: String) {
            if let failure = UserDataWipe.remove(dir.path, label: label) { failures.append(failure) }
            try? PrivateStorage.ensureDirectory(dir)
        }
        func deleteSecret(_ key: String, label: String) {
            do { try KeychainHelper.delete(key: key) }
            catch { failures.append("\(label): \(error.localizedDescription)") }
        }

        // 0a. Gate intake for the whole wipe: the Mind-restore flag idles
        //     the poll loop (no reminder dispatch, no completion injection,
        //     no buffer persists) and makes the app composer refuse — the
        //     same barrier a restore uses so nothing writes state mid-swap.
        //     The handler verified idleness; this re-checks atomically.
        guard beginMindRestore() else {
            return ["ABORTED: a turn or memory maintenance became active — nothing was deleted; try again"]
        }
        defer { endMindRestore() }

        if let why = await quiesceSubscriptionLogin(timeoutSeconds: 10) {
            return ["ABORTED: \(why) — nothing was deleted"]
        }

        // 0a-bis. Several assistants (owner decision 2026-10-29, Codex
        //     stage-3 rounds 6–9): refuse — before anything is cancelled or
        //     deleted — while background work or an open claim scope could
        //     still need this assistant's file claims. Checked again below,
        //     after the last suspending quiescence step.
        if let why = await Self.multiAssistantBackgroundWorkRefusal() {
            return ["ABORTED: " + why]
        }

        // 0b. Quiesce background work — cancelling is not enough (Codex
        //     round 2): a cancelled subagent still runs to its commit point
        //     and could re-persist its session or queue a completion AFTER
        //     the wipe. Wait for actual exit, bounded — and if quiescence
        //     cannot be obtained, ABORT before anything is deleted (Codex
        //     round 3): proceeding would leave a live producer that
        //     repopulates memory the moment the gate lifts. Nothing has
        //     been erased at either abort point; the cancelled background
        //     work is the only side effect.
        let unquiesced = await SubagentBackgroundRegistry.shared.cancelAllAndQuiesce(timeoutSeconds: 10)
        guard unquiesced.isEmpty else {
            return ["ABORTED: background subagents still shutting down after 10s (\(unquiesced.joined(separator: ", "))) — nothing was deleted; try again in a minute"]
        }

        // 0c. In-flight scripted watcher checks run in untracked tasks and
        //     write FireOutbox records (or the in-memory fallback queue)
        //     when they finish — wait them out, and ABORT if one is stuck:
        //     a check finishing after the wipe would mint a stale fire.
        let watcherDeadline = Date().addingTimeInterval(10)
        while !watcherChecksInFlight.isEmpty && Date() < watcherDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard watcherChecksInFlight.isEmpty else {
            return ["ABORTED: \(watcherChecksInFlight.count) watcher check(s) still running after 10s — nothing was deleted; try again in a minute"]
        }

        // 0c-bis. Triage runs (Codex, 2026-08-27 — the CLI shared Ada.app's
        //     gap): detached Tasks NOT owned by SubagentBackgroundRegistry,
        //     so step 0b missed them. One resuming after the wipe would
        //     persist FireOutbox verdicts, session bindings, and telemetry
        //     for watchers that no longer exist. No cancellation handle
        //     exists — bounded wait or abort, before 0d so the abort needs
        //     no poller restart.
        guard await awaitTriageRunsQuiesced(timeoutSeconds: triageQuiesceTimeoutForTesting ?? 10) else {
            return ["ABORTED: \(triageRunsInFlight.count) watcher triage run(s) still in flight — nothing was deleted; try again in a minute"]
        }

        // 0c-ter. Pending tool charges (mid-turn early wake §3.6.4): the wipe
        //     keeps spend totals, so every charge held in a crash record (or
        //     only in memory) is recorded in the charge ledger BEFORE the
        //     records are deleted — or the wipe aborts with nothing deleted.
        if let why = ToolChargeLedger.settleAllBeforeReplacingHistory() {
            return ["ABORTED: pending spend couldn't be saved (\(why)) — nothing was deleted; fix it with `briglia doctor` and try again"]
        }

        // 0d. Quiesce the AgentMail poller BEFORE the last abort point and
        //     BEFORE the buffer clears below: cancelling is not quiescence
        //     here either — the actor is reentrant, so a tick suspended in a
        //     network await (or in the email handler, which the restore gate
        //     now refuses) resumes later. resetForWipe bumps the poll
        //     generation (all late commits are discarded), then deadline-
        //     polls an in-flight tick counter; if genuine quiescence isn't
        //     reached, ABORT with nothing deleted (Codex round 8). The
        //     final reloadAfterMindRestore restarts the poller cleanly.
        guard await AgentMailService.shared.resetForWipe() else {
            // The abort must not leave proactive email notifications silently
            // dead until the next app restart (Codex round 9): restart the
            // poller before reporting. startBackgroundPoll mints a fresh
            // generation (the stuck tick stays refused), the handler
            // installed at startup survives resetForWipe, and the preserved
            // checkpoint file (<48h) restores watermark + drain cursors over
            // the anti-flood seed.
            await restartEmailPollingAfterAbortedWipe()
            return ["ABORTED: an AgentMail poll tick is still in flight after 10s — nothing was deleted, and email polling was restarted; try again in a minute"]
        }

        // 0d-bis. The refusal again, at the destructive step: work started
        //     while the wipe was suspended above refuses too. No suspension
        //     follows before the claims are removed except the purge, which
        //     then has nothing of a several-assistant install to stop.
        if let hook = Self.wipeBeforeSecondBackgroundCheckForTesting { await hook() }
        if let why = await Self.multiAssistantBackgroundWorkRefusal() {
            await restartEmailPollingAfterAbortedWipe()
            return ["ABORTED: " + why]
        }

        // Past the last abort point: only now discard the cancelled
        // subagents' queued results — an abort above must leave them
        // deliverable, or "nothing was deleted" would be a lie
        // (Codex round 4).
        _ = await SubagentBackgroundRegistry.shared.drainCompletions()

        // 0e. Purge bash jobs: kill everything and drop registry state —
        //     the already-queued completion notices must die too. A job
        //     still stopping after the join limit is kept and reported
        //     rather than silently dropped (with several assistants the
        //     refusal above means there is none).
        let bashPurge = await BackgroundProcessRegistry.shared.purgeAllForWipeReporting()
        if bashPurge.retained > 0 {
            failures.append("\(bashPurge.retained) background command(s) were still stopping after 60 s and were kept; run /deleteuserdata again in a minute to clear them")
        }

        // 0f. Clear every inbound/outbound buffer that could re-persist or
        //     resurface old content: captionless-media attachment buffers
        //     (the poll loop mirrors them back to disk), forward/reply
        //     context, the /continue tail of the last long reply, and
        //     parked undeliverable replies. Ordered AFTER poller quiescence
        //     (0d) so no suspended email handler can re-enqueue into the
        //     ambient queue after this clear (Codex round 8).
        pendingImages.removeAll()
        pendingDocuments.removeAll()
        pendingReferencedImages.removeAll()
        pendingReferencedDocuments.removeAll()
        pendingForwardContext = nil
        pendingReplyContext = nil
        pendingAttachmentNotes.removeAll()
        persistPendingInboundBuffers()
        setPendingContinuation(nil)
        parkedOutbound.removeAll()
        retireVisibilityNoticesForWipe()
        // Update notice (§5.6): under its lock, bump the notice generation
        // (a check or send in progress cannot write back), then delete the
        // derived state. An explicit /upgradecheck off survives.
        // Machine-level notice state (MULTI_ASSISTANT_PLAN §5.5) is wiped
        // only by default and only while no extra assistant exists.
        if AssistantProfile.isDefault && !AssistantRegistry.exists() {
            do { try UpdateNoticeStore.wipeDerivedState(paths: .live, now: Date()) }
            catch { failures.append("update notice state: \(error.localizedDescription)") }
        }
        pendingAmbientTriggers.removeAll()
        _ = persistPendingAmbientTriggers()
        pendingWatcherFireMessages.removeAll()
        pendingUserNameProposal = nil
        pendingMindImport = nil
        ToolExecutor.clearPendingToolOutputs()
        // Rendered pages of user PDFs must not outlive the wipe in memory.
        RenderedPDFPageCache.shared.removeAll()
        ModelImageCache.shared.removeAll()
        CacheDiagnostics.reset()
        // Several assistants (§11): this assistant's own board entry,
        // notices and claims (idle: no edit is reserved). Nothing with one.
        // The refusal above guarantees no claim scope is open and no job or
        // subagent is live; the open-scope test is only a synchronous belt.
        if MultiAssistant.context() != nil || AssistantRegistry.presence() != .absent {
            AssistantBoard.removeFiles(profile: AssistantProfile.selectedName, includeClaims: false)
            BoardWriter.shared.reset()
            if !ClaimScopes.shared.hasOpenScopes {
                try? FileManager.default.removeItem(at: MultiAssistant.Paths.live.claimsFile(AssistantProfile.selectedName))
            }
        }

        // Quiescence passed: an explicit wipe also discards unpublished
        // recovery held in memory, so no later retry can resurrect old work.
        activeTurnCheckpoints.removeAll(); checkpointWriteFailure = nil
        pendingCompactionCalibration = nil; recoveryBlocked = false

        // 1. Clear conversation and images; verify the empty conversation
        //    actually reached disk (clearConversation's own save is silent),
        //    and re-remove the media directories with CHECKED deletion —
        //    clearConversation's own removals are try? and could silently
        //    leave files behind.
        // An explicit wipe is the reset path for an unreadable history: the
        // user asked for it to be replaced.
        if historyLoadFailure != nil {
            historyLoadFailure = nil
            Task { await MaintenanceAlertCenter.shared.reportSuccess(.conversationHistory) }
        }
        setHeldQueueProblem(nil)  // explicit discard: the user asked for it
        clearConversation()
        if !saveConversation() { failures.append("conversation file: write failed") }
        removeAndRecreate(imagesDirectory, label: "images directory")
        removeAndRecreate(toolAttachmentsDirectory, label: "tool attachments directory")
        for (url, label) in [(turnSalvageFileURL, "turn salvage file"),
                             (pendingAttachmentsFileURL, "pending attachments file"),
                             (pendingMidTurnFileURL, "mid-turn queue file"),
                             (pendingAmbientFileURL, "ambient-trigger queue file"),
                             (pendingContinuationFileURL, "pending continuation file"),
                             (activeTurnMarkerFileURL, "active-turn marker")] {
            if let f = UserDataWipe.remove(url.path, label: label) { failures.append(f) }
        }

        // Shared ChatGPT login (§25.6): never-multi unchanged; with several
        // assistants only the last sharer signs the machine store out.
        let chatgptWipe = await SubscriptionSharing.wipe()
        failures.append(contentsOf: chatgptWipe.failures)
        for note in chatgptWipe.notes { print("[deleteuserdata] \(note)") }
        lastWipeNotes = chatgptWipe.notes

        if let failure = UserDataWipe.remove(PruneArchiveStore.root.path, label: "conversation snapshots") { failures.append(failure) }

        // 2. Clear all archived chunks (a finished-but-uncommitted
        //    background archive of the old history is discarded first).
        await invalidateArchiveJobForReplacedHistory()
        // BGPRUNE{ A-GEN1
        if backgroundPruneEngaged {
            backgroundPruneHistoryReplaced()
        }
        // }BGPRUNE
        failures += await archiveService.clearAllArchives()

        // 3. Clear all reminders (also clears the trigger spool, fire
        //    outbox, watcher scripts/state, and pinned-session refs).
        await ReminderService.shared.clearAllReminders()

        // 4. Clear user context from the secret store
        deleteSecret(KeychainHelper.userContextKey, label: "user context")
        deleteSecret(KeychainHelper.structuredUserContextKey, label: "structured user context")

        // 5. Clear documents directory
        removeAndRecreate(documentsDirectory, label: "documents directory")

        // 6. Clear file descriptions and text-only vision proxy cache.
        await FileDescriptionService.shared.clearAll()
        await VisionPreprocessorCache.shared.clearAll()

        // 7. Clear files ledger (history of every file the agent has touched).
        await FilesLedger.shared.clearAll()

        // 8. Clear persistent todo list.
        await TodoStore.shared.clearAll()

        // 9. Clear all subagent session histories (full transcripts + spend).
        await SubagentSessionRegistry.shared.removeAll()

        // 10. Clear the stored user name. Ada.app's button historically
        // treated the name as a setting and kept it; the /deleteuserdata
        // contract (owner, 2026-08-20) is total amnesia about the person,
        // so the name goes too. (The assistant's own name stays — that's
        // configuration, not user data.)
        deleteSecret(KeychainHelper.userNameKey, label: "stored user name")

        // Email credentials (user decision, 2026-08-22): a handoff wipe must
        // sever email ACCESS too — AgentMail key + inbox address (and any
        // leftover copy of the retired gws OAuth client) go, and the provider
        // resets to an explicit "none". The poller is already quiescent
        // (step 0d, abort-guarded). Briglia no longer runs or touches gws
        // (removed 2026-10-24); the warning text tells the user how to sign
        // it out when ~/.config/gws exists. The frozen system-prompt context
        // is cleared too — it holds pre-wipe inbox snippets that would
        // otherwise survive until the next day-roll.
        // Several assistants (§5.6, Codex stage-2 R4): the inbox removal is a
        // registry transaction; the poller is already quiescent, so it is
        // released right after the wipe.
        do {
            let ticket = try IdentityChange.begin(kind: .inbox, rawValue: nil, mode: .assistant)
            var wipeFailures: [String] = []
            do {
                try ticket.commit {
                    wipeFailures = EmailCredentialWipe.execute()
                }
                ticket.finish()
            } catch { ticket.abort(); wipeFailures.append("email reservation: \(error)") }
            failures.append(contentsOf: wipeFailures)
        } catch {
            failures.append("email removal refused: \(error)")
        }
        frozenEmailContext = nil
        frozenCalendarContext = nil

        // 11. Web-pipeline log (search queries) + temp tool-output dir
        //     (truncated outputs and bash spill files).
        failures.append(contentsOf: UserDataWipe.wipeSharedArtifacts())

        // 12. Checked deletion of every remaining user-data state file the
        //     Mind exporter classifies as user data (+ git checkpoint refs
        //     and the reminders file the service-level clear rewrote as
        //     []). Directory-level removal catches orphaned or corrupt
        //     entries the service-level clears can miss — clearAllArchives
        //     only walks its index, removeAll only successfully-loaded
        //     sessions. The projects folder is deliberately KEPT: it holds
        //     work product (sites, code), not memory.
        for name in ["context_usage.json", "contacts.json", "calendar.json",
                     "reminders.json", "reminder-notices.json",
                     "files_ledger.json", "files_ledger.json.tmp",
                     "documents_last_opened.json", "todos.json", "git_checkpoints.json",
                     "agentmail_poll_state.json"] {
            if let f = UserDataWipe.remove(appFolder.appendingPathComponent(name).path, label: name) {
                failures.append(f)
            }
        }
        // Recovery copies the per-entry reminder loader set aside (0.2.63):
        // user data.
        failures.append(contentsOf: ReminderService.removeRecoveryFilesForWipe(in: appFolder))
        // Session affinity (harness state, plan §5/§9): the file and every
        // quarantined sibling, deleted under affinity.lock with a checked
        // directory fsync; the next start mints a new salt and main ID.
        do { try ResponsesUsageStore().clearForWipe() }
        catch { failures.append("Could not clear Responses cache statistics") }
        failures.append(contentsOf: SessionAffinity.deleteForUserDataWipe())
        // Mid-turn early wake state (crash records, /stop marker, snapshot
        // settlement evidence) — harness state about the wiped history.
        for (url, label) in [(DetachedJobStore.fileURL, "background-job crash records"),
                             (StopMarkerStore.fileURL, "stop marker"),
                             (SettlementEvidence.directory(), "snapshot settlement evidence")] {
            if let f = UserDataWipe.remove(url.path, label: label) { failures.append(f) }
        }
        stoppedJobIds.removeAll(); stopEntries.removeAll(); stoppedSubagentHandles.removeAll()
        stopIntent = .none; pendingCompletionAcks.removeAll(); pendingSubagentAcks.removeAll(); recoveredWakeTrigger = nil
        midTurnGeneration.removeAll(); roundDeliveryReservations.removeAll(); roundDeliveryRecordRetries.removeAll()
        for (dir, label) in [
            (appFolder.appendingPathComponent("archive", isDirectory: true), "archive directory"),
            (appFolder.appendingPathComponent("subagent_sessions", isDirectory: true), "subagent sessions directory"),
            // Web researcher report files (WEB_SUBAGENT_PLAN O6, Codex R1a
            // review N2): derived from the user's questions — user data,
            // deleted like documents (projects, by contrast, are kept).
            (appFolder.appendingPathComponent("research", isDirectory: true), "research reports directory"),
            (appFolder.appendingPathComponent("trigger-events", isDirectory: true), "trigger spool directory"),
            (appFolder.appendingPathComponent("fire-outbox", isDirectory: true), "fire outbox directory"),
        ] {
            if let f = UserDataWipe.remove(dir.path, label: label) { failures.append(f) }
        }
        // reminder-scripts/ is removed at directory level — that catches
        // orphaned or corrupt scripts and seen-state that clearAllReminders
        // (which walks its loaded rows) can miss — then recreated with its
        // state/ subdir, which check scripts expect to `touch` files in.
        if let f = UserDataWipe.remove(appFolder.appendingPathComponent("reminder-scripts", isDirectory: true).path,
                                       label: "reminder scripts directory") {
            failures.append(f)
        }
        try? PrivateStorage.ensureDirectory(
            appFolder.appendingPathComponent("reminder-scripts/state", isDirectory: true))

        // 13. Straggler sweep: if a watcher check outlived its 10s wait
        //     (reported above), its fire may have landed after step 3 —
        //     clear the outbox and spool once more so it can't dispatch.
        FireOutbox.removeAll()
        TriggerSpool.removeAll()

        // 14. Rehydrate every service from the now-empty disk — the same
        //     reload a Mind restore uses. This resets in-memory caches
        //     (archive index, reminder list, ledger, calendar, sessions)
        //     without requiring the recommended /restart to be honest.
        await reloadAfterMindRestore()

        print(failures.isEmpty
              ? "[ConversationManager] All memory deleted"
              : "[ConversationManager] Memory wipe finished with issues: \(failures.joined(separator: "; "))")
        return failures
    }
    
    /// Build a human-readable text snapshot of the full context the LLM would see.
    func buildContextSnapshot() async -> String {
        let frozenContext = await getFrozenSystemContext()
        // Read-only (§4.6): the current turn's view when one exists, else a
        // view without meta refresh or lease. Never starts or commits.
        let diagnosticView = await diagnosticArchiveView()
        let chunkSummaries = diagnosticView.items
        let totalChunkCount = diagnosticView.totalChunkCount

        await MCPAgentRouting.refreshFromRegistry()
        let allMcpTools = await MCPRegistry.shared.allToolDefinitions()
        let mainMcpTools = MCPAgentRouting.filterMcpTools(
            forAgent: "main", allTools: allMcpTools, fallbackPatterns: nil
        )
        let deferredServerNames = MCPAgentRouting.deferredServers(
            forAgent: "main", allTools: allMcpTools, fallbackPatterns: nil
        )
        let deferredSummaries = await MCPRegistry.shared.serverSummaries(for: deferredServerNames)
        let serperKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        let nativeTools = AvailableTools.all(
            includeWebSearch: !serperKey.isEmpty,
            hasDeferredMCPs: !deferredSummaries.isEmpty
        )
        let allTools = nativeTools + mainMcpTools

        // Composed (/keepsummaries): this diagnostic shows what the model sees.
        return await openRouterService.renderContextSnapshot(
            messages: PruneSummaryRetention.compose(messages, limit: KeepSummariesSetting.current()).messages,
            tools: allTools,
            calendarContext: frozenContext.calendar,
            emailContext: frozenContext.email,
            chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
            totalChunkCount: totalChunkCount,
            deferredMCPSummaries: deferredSummaries.isEmpty ? nil : deferredSummaries
        )
    }

    /// Reload all data from disk after Mind restore
    /// This refreshes the conversation and archive service to pick up restored data
    /// Quiescence barrier for a Mind import (ported from the Ada.app arc,
    /// Codex rounds 1–2, 2026-08-26): cancels and awaits background
    /// subagents — detached tasks the restore gate does not cover — and
    /// refuses the import if quiescence can't be reached. In-flight
    /// scripted watcher checks and watcher-triage runs are waited out too:
    /// a check finishing after the import would mint a fire for a
    /// pre-restore watcher, and a triage run would settle a pre-restore
    /// batch over restored state. Call only inside the restore gate;
    /// returns a user-facing reason on failure (nothing was mutated), nil
    /// when the import may proceed — the caller then runs
    /// discardPreImportBackgroundOutputs() before mutating anything, so
    /// outputs queued by now-quiescent producers cannot surface inside the
    /// restored Mind.
    /// Cancel pending authorization under its cross-process lock before allowing
    /// restored/deleted state to become live. Await the owner task's real exit.
    private func quiesceSubscriptionLogin(timeoutSeconds: Double) async -> String? {
        subscriptionLoginTask?.cancel()
        // Only this assistant's own pending sign-in (§25.12): another
        // assistant's sign-in to the shared login is never cancelled here.
        do { try await SubscriptionAuthStore().cancelOwnedPending() }
        catch { return "cannot cancel ChatGPT login: \(error.localizedDescription)" }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while subscriptionLoginTask != nil && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return subscriptionLoginTask == nil ? nil : "ChatGPT login is still shutting down"
    }

    /// Selftests: runs between the wipe's two background-work checks.
    nonisolated(unsafe) static var wipeBeforeSecondBackgroundCheckForTesting: (() async -> Void)?

    /// Owner decision 2026-10-29 (MULTI_ASSISTANT_PLAN A2; replaces the
    /// per-path claim guards of Codex stage-3 S3-R7-1…S3-R9-1): with several
    /// assistants, `/deleteuserdata` and a Mind import refuse while any
    /// background Bash job is running, unsettled or still being stopped,
    /// any subagent run is live, or any claim scope (current, ending,
    /// pending) is still open — instead of killing that work and then
    /// deciding which claims it still needs. An open scope with no live
    /// work gets a short settling window (a turn that just ended closes in
    /// milliseconds); one that cannot close (e.g. the assistants list is
    /// unreadable or being rewritten) refuses. Nil = proceed. A never-multi
    /// install (no registry, nothing claimed) is unchanged: nil at once.
    static func multiAssistantBackgroundWorkRefusal(settleSeconds: Double = 2,
                                                    outcome: (en: String, it: String) = (" Nothing was deleted.", " Non è stato cancellato nulla.")) async -> String? {
        guard MultiAssistant.contextOverrideForTesting != nil || AssistantRegistry.presence() != .absent
              || ClaimScopes.shared.hasOpenScopes else { return nil }
        let deadline = Date().addingTimeInterval(settleSeconds)
        while true {
            let bash = await BackgroundProcessRegistry.shared.unsettledEntryIds()
            let agents = await SubagentBackgroundRegistry.shared.liveRunIds()
            if bash.isEmpty && agents.isEmpty {
                await ClaimScopes.shared.tick()
                if !ClaimScopes.shared.hasOpenScopes { return nil }
                if Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
            }
            var what: [String] = []
            if !bash.isEmpty { what.append("\(bash.count) background command(s)") }
            if !agents.isEmpty { what.append("\(agents.count) subagent(s)") }
            if what.isEmpty { what.append("file claims still in use") }
            let list = what.joined(separator: ", ")
            return "Background jobs are still running (\(list)); stop them first (or use /stop) and try again.\(outcome.en) / Ci sono ancora lavori in background (\(list)); fermali prima (o usa /stop) e riprova.\(outcome.it)"
        }
    }

    func quiesceBackgroundWorkForMindRestore(timeoutSeconds: Double = 10) async -> String? {
        if let why = await quiesceSubscriptionLogin(timeoutSeconds: timeoutSeconds) { return why }
        // Several assistants: the same refusal as the wipe, before any
        // subagent is cancelled (owner decision 2026-10-29).
        if let why = await Self.multiAssistantBackgroundWorkRefusal(outcome: ("", "")) { return why }
        let unquiesced = await SubagentBackgroundRegistry.shared.cancelAllAndQuiesce(timeoutSeconds: timeoutSeconds)
        guard unquiesced.isEmpty else {
            return "background subagents still shutting down (\(unquiesced.joined(separator: ", ")))"
        }
        let watcherDeadline = Date().addingTimeInterval(timeoutSeconds)
        while !watcherChecksInFlight.isEmpty && Date() < watcherDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard watcherChecksInFlight.isEmpty else {
            return "\(watcherChecksInFlight.count) watcher check(s) still running"
        }
        // Triage runs are a third producer class: plain detached Tasks —
        // NOT owned by SubagentBackgroundRegistry — that settle batches
        // after their subagent returns, persisting FireOutbox
        // verdicts/receipts and triage-session state. One finishing after
        // the import would overwrite restored watcher or session state.
        // They hold no cancellation handle, so bounded wait is the only
        // quiescence available.
        guard await awaitTriageRunsQuiesced(timeoutSeconds: timeoutSeconds) else {
            return "\(triageRunsInFlight.count) watcher triage run(s) still in flight"
        }
        // Stage A prerequisite (§3.6.4): every pending charge recorded before
        // the point of no return — spend is not part of a Mind, and Stage B
        // discards the replaced conversation's crash records.
        if let why = ToolChargeLedger.settleAllBeforeReplacingHistory() {
            return "pending spend couldn't be saved (\(why)); fix it with `briglia doctor` and retry"
        }
        // …and again after the suspending steps above, right before the
        // import's point of no return.
        if let why = await Self.multiAssistantBackgroundWorkRefusal(outcome: ("", "")) { return why }
        return nil
    }

    /// Bounded wait for in-flight watcher-triage lanes (shared by the wipe
    /// and the Mind-import barrier). True = quiescent, safe to proceed.
    private func awaitTriageRunsQuiesced(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !triageRunsInFlight.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return triageRunsInFlight.isEmpty
    }

    /// Point of no return for a Mind import: discard every queued OUTPUT a
    /// pre-import producer left behind, so nothing produced against the
    /// replaced state surfaces inside the restored one. Call ONLY after
    /// quiesceBackgroundWorkForMindRestore() returned nil and the import is
    /// committed — an abort must leave these deliverable.
    /// - Cancelled background subagents still queue their final result
    ///   (markCompleted); undrained, the poll loop would inject it as a
    ///   [SUBAGENT COMPLETE] turn into the restored conversation.
    /// - Background bash jobs belong to the replaced conversation — the
    ///   restored one has no record of launching them, so their completion
    ///   notices (and spill files) would be noise from a vanished context.
    ///   Purged like the wipe does, not merely drained: a job finishing
    ///   AFTER this discard would otherwise queue a fresh notice. Exception
    ///   (Codex stage-3 S3-R6-1): a job still stopping when the purge's join
    ///   limit expires is kept; its late completion notice can then reach
    ///   the restored conversation. With several assistants the import
    ///   refuses while any job is live (owner decision 2026-10-29).
    /// - A watcher check that finished during the barrier persisted a fire
    ///   (or queued an in-memory fallback message); the Mind archive carries
    ///   no outbox/spool, so pending records are pre-import by definition.
    func discardPreImportBackgroundOutputs() async {
        _ = await SubagentBackgroundRegistry.shared.drainCompletions()
        _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()
        pendingWatcherFireMessages.removeAll()
        TriggerSpool.removeAll()
        FireOutbox.removeAll()
    }

    /// Full Mind-import orchestration, in the ONLY safe order (Codex round
    /// 3 on the Ada.app arc): gate → STAGE/VALIDATE (read-only; a corrupt
    /// or non-Mind archive rejects here with all current work — running
    /// subagents, bash jobs, queued outputs — intact) → quiesce producers
    /// (first destructive step: cancels subagents) → discard pre-import
    /// outputs (point of no return) → apply the staged Mind → reload.
    /// Staging must precede even the barrier, because the barrier itself
    /// destroys work; validation is the cheapest step and runs first.
    /// The archive is first copied into a PRIVATE staging file, and both
    /// the fingerprint check (the /importmind confirm pin) and the unzip
    /// run against that copy (Codex round 2, 2026-08-27): hashing and
    /// extracting the user-supplied path directly left a window where the
    /// file changes during extraction and is restored before a re-hash —
    /// both hashes pass while the staged tree came from the transient
    /// content. Hashing the copy and unzipping the same copy makes the
    /// verified bytes and the extracted bytes provably identical. A copy
    /// torn by a concurrent writer simply fails the pin and refuses.
    func performMindImport(
        from url: URL,
        quiesceTimeoutSeconds: Double = 10,
        expectedSHA256: String? = nil,
        expectedBytes: Int64? = nil
    ) async -> MindImportOutcome {
        guard beginMindRestore() else { return .refusedGate }
        defer { endMindRestore() }

        let privateCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("mind-import-\(UUID().uuidString).mind")
        defer { try? FileManager.default.removeItem(at: privateCopy) }
        do {
            try FileManager.default.copyItem(at: url, to: privateCopy)
        } catch {
            return .rejectedArchive("Cannot read \(url.path): \(error.localizedDescription). Nothing was changed.")
        }
        if expectedSHA256 != nil || expectedBytes != nil {
            let changedMessage = "The backup file changed since you inspected it (or became unreadable) — nothing was imported. Re-run /importmind <path> to review the current file."
            guard let actual = Self.mindArchiveFingerprint(path: privateCopy.path) else {
                return .rejectedArchive(changedMessage)
            }
            if let expectedSHA256, actual.sha256 != expectedSHA256 {
                return .rejectedArchive(changedMessage)
            }
            if let expectedBytes, actual.bytes != expectedBytes {
                return .rejectedArchive(changedMessage)
            }
        }

        let staged: MindExportService.StagedMind
        do {
            staged = try await MindExportService.shared.stageMind(from: privateCopy)
        } catch {
            return .rejectedArchive(error.localizedDescription)
        }

        // Rebase + QUARANTINE the staged watcher rows IN THE STAGED FILE,
        // before anything destructive (Codex round 4, 2026-08-27): the
        // previous post-apply mutation saved fire-and-forget, so a silent
        // write failure left the archive's unpaused rows on disk — a
        // restart would then run unreviewed imported scripts. Mutating the
        // staged reminders.json with checked persistence makes the
        // quarantine part of the applied bytes; any failure here rejects
        // the archive with current data fully intact.
        let pausedWatchers: Int
        do {
            pausedWatchers = try ReminderService.prepareStagedReminders(stagedRoot: staged.tempDir)
        } catch {
            await MindExportService.shared.discardStagedMind(staged)
            return .rejectedArchive("\(error.localizedDescription) Nothing was changed.")
        }

        if let busy = await quiesceBackgroundWorkForMindRestore(timeoutSeconds: quiesceTimeoutSeconds) {
            await MindExportService.shared.discardStagedMind(staged)
            return .refusedBusy(busy)
        }

        // Session affinity (plan §8): the importing device's main
        // conversation gets a new ID, written after successful quiescence and
        // BEFORE anything is discarded, so a failure here aborts with the
        // old Mind intact. Failure before the rename leaves the old state;
        // failure at the directory fsync leaves the complete new state.
        do {
            try SessionAffinity.replaceMainConversationId()
        } catch let failure as SessionAffinity.WriteFailure {
            await MindExportService.shared.discardStagedMind(staged)
            return .failedBeforeApply(failure.description, affinityAdvanced: failure.phase == .afterRename)
        } catch {
            await MindExportService.shared.discardStagedMind(staged)
            return .failedBeforeApply("\(error)", affinityAdvanced: false)
        }

        await discardPreImportBackgroundOutputs()
        do {
            try discardTurnRecoveryForReplacement()
            // Private runtimes (security plan v24 §7.8.1 step 10): an import
            // invalidates any AgentMail/Node/Python commit in flight.
            RuntimeSelectionStore.bumpGeneration()
            try await MindExportService.shared.applyStagedMind(staged)
            // Stage B (mid-turn early wake §3.12.3): every crash record and
            // /stop entry of the replaced conversation is discarded, and the
            // imported snapshots join the legacy list (no live record can
            // predate them).
            try resetEarlyWakeStateForReplacedHistory()
        } catch {
            return .failedApply(error.localizedDescription)
        }
        await reloadAfterMindRestore()
        // No post-apply watcher mutation: the reloaded reminders.json IS
        // the staged file prepareStagedReminders already rebased and
        // quarantined (with checked persistence) before the barrier ran.
        return .success(pausedWatchers: pausedWatchers)
    }

    // Test seams for the Mind-import barrier/discard selftests. Real triage
    // lanes enter via dispatchTriageRuns and leave via runTriageLane's
    // defer; real fallback messages via the FireOutbox persist-failure path.
    func _testSetTriageLane(_ lane: String, inFlight: Bool) {
        if inFlight { triageRunsInFlight.insert(lane) } else { triageRunsInFlight.remove(lane) }
    }
    func _testSeedPendingWatcherFire() {
        pendingWatcherFireMessages.append(Message(role: .user, content: "[test fire]", kind: .reminderFired))
    }
    func _testPendingWatcherFireCount() -> Int { pendingWatcherFireMessages.count }
    func _testSetBrowserSettingsPollIngress(_ count: Int) { browserSettingsPollIngress = count }

    /// Shares the existing ingress/maintenance barrier, without cancelling work
    /// or replacing memory. Only a short mutation + service reload holds it.
    func beginBrowserSettingsMutation() async -> Bool {
        // Parked for an update (MULTI_ASSISTANT_PLAN §6.4): no settings work
        // may start until the barrier ends (Codex stage-2 R2).
        guard !admissionPaused else { return false }
        guard subscriptionLoginTask == nil, watcherChecksInFlight.isEmpty,
              triageRunsInFlight.isEmpty, activeProcessingTask == nil,
              browserSettingsCommandIngress == 0, beginMindRestore() else { return false }
        browserSettingsMutation = true
        // An app attachment copy or Telegram long poll may have crossed its
        // ingress check before we raised the gate. Let it exit, then recheck
        // every producer. A newly started turn wins; settings returns busy.
        let deadline = ProcessInfo.processInfo.systemUptime + 35
        while browserSettingsPollIngress > 0 || browserSettingsAppIngress > 0 {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                endBrowserSettingsMutation(); return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let subagents = await SubagentBackgroundRegistry.shared.activeRunIds()
        guard subagents.isEmpty, !isTurnActive, activeProcessingTask == nil,
              watcherChecksInFlight.isEmpty, triageRunsInFlight.isEmpty,
              maintenanceActivities.isEmpty, archiveRecoveryTask == nil,
              subscriptionLoginTask == nil else {
            endBrowserSettingsMutation(); return false
        }
        return true
    }

    func endBrowserSettingsMutation() {
        browserSettingsMutation = false
        endMindRestore()
    }

    func reloadBrowserSettings() async {
        let key = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? ""
        await openRouterService.configure(apiKey: key)
        await archiveService.configure(apiKey: key)
        await toolExecutor.configure(openRouterKey: key,
            serperKey: KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? "",
            jinaKey: KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) ?? "")
        if let imageKey = KeychainHelper.load(key: KeychainHelper.openAIImageApiKeyKey), !imageKey.isEmpty {
            await OpenAIImageService.shared.configure(apiKey: imageKey,
                model: KeychainHelper.load(key: KeychainHelper.openAIImageModelKey),
                preciseModel: KeychainHelper.load(key: KeychainHelper.openAIImagePreciseModelKey),
                quality: KeychainHelper.load(key: KeychainHelper.openAIImageQualityKey),
                outputFormat: KeychainHelper.load(key: KeychainHelper.openAIImageOutputFormatKey),
                moderation: KeychainHelper.load(key: KeychainHelper.openAIImageModerationKey))
        }
        NotificationCenter.default.post(name: .adaLLMProviderDidChange, object: nil,
            userInfo: ["provider": LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey)).rawValue])
        await applyEmailSettingsChange()
    }

    /// Starts the poller of the configured email provider (startup, restore,
    /// and a live settings change) and records what it was started for.
    func startEmailProvider() async {
        let state = AppliedEmailState.current
        appliedEmailState = state
        // Ambient inbox + calendar awareness, routed by the email/calendar
        // provider setting: agentmail (dedicated agent inbox via REST) or
        // none (no polling, no context). The service retries + fails
        // gracefully when unconfigured, so startup never blocks on it.
        switch state.provider {
        case .agentmail:
            // One inbox per assistant (MULTI_ASSISTANT_PLAN §5.6, D9).
            if let inbox = KeychainHelper.load(key: KeychainHelper.agentMailInboxAddressKey),
               !inbox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !Self.registryAllowsChannel(.inbox, value: inbox) {
                return
            }
            await AgentMailService.shared.setNewEmailHandler { [weak self] newEmails in
                // nil self = manager gone (shutdown race) → NOT durable:
                // fail-safe false holds the checkpoint so the mail redelivers
                // on the next launch instead of being silently skipped.
                guard EmailCalendarProvider.current == .agentmail else { return false }
                return await self?.processNewUnreadEmails(newEmails) ?? false
            }
            await AgentMailService.shared.startBackgroundPoll()
        case .none:
            break
        }
    }

    /// A live settings change (briglia menu / browser settings, under the
    /// settings barrier) that touched the email provider or the AgentMail
    /// account: quiesce both pollers and drop their in-memory state, forget
    /// the old account's persisted drain checkpoint when the account
    /// changed, drop the frozen inbox/agenda prompt context, then start the
    /// selected provider. No-op when nothing email-related changed, so an
    /// ordinary save doesn't reseed the pollers.
    func applyEmailSettingsChange() async {
        let current = AppliedEmailState.current
        guard current != appliedEmailState else { return }
        let previous = appliedEmailState
        lastEmailResetQuiescent = await AgentMailService.shared.resetForWipe()
        if !lastEmailResetQuiescent {
            print("[ConversationManager] WARNING: AgentMail poller not quiescent at provider change — late ticks are discarded by the generation token")
        }
        if let previous, previous.agentMailKey != current.agentMailKey || previous.inbox != current.inbox {
            // A failed removal is safe: checkpoints are account-stamped and
            // the new account never restores the old one's.
            _ = await AgentMailService.shared.discardPersistedPollState()
        }
        frozenEmailContext = nil
        frozenCalendarContext = nil
        await startEmailProvider()
        print("[ConversationManager] Email provider applied live: \(current.provider.rawValue)")
    }

    func beginMindRestore() -> Bool {
        guard !admissionPaused, !isRestoringMind,
              !isTurnActive,
              maintenanceActivities.isEmpty,
              archiveRecoveryTask == nil else { return false }
        isRestoringMind = true
        return true
    }

    func endMindRestore() {
        isRestoringMind = false
        // After a Mind import: repair stubs and restore at the next idle point.
        scheduleSummaryRetentionIdlePass()
    }

    func reloadAfterMindRestore() async {
        await invalidateArchiveJobForReplacedHistory()
        // BGPRUNE{ A-GEN2
        if backgroundPruneEngaged {
            backgroundPruneHistoryReplaced()
        }
        // }BGPRUNE
        loadConversation(clearWhenMissing: true)
        // The continuation buffer belongs to the replaced conversation; a
        // /continue after restore must not replay the old reply's tail.
        setPendingContinuation(nil)
        loadContextUsageSnapshot(clearWhenMissing: true)
        await archiveService.reloadFromDisk()
        await ReminderService.shared.reloadFromDisk()
        await CalendarService.shared.reloadFromDisk()
        await FilesLedger.shared.reloadFromDisk()
        await TodoStore.shared.reloadFromDisk()
        await FileDescriptionService.shared.reloadFromStorage()
        await VisionPreprocessorCache.shared.reloadFromStorage()
        // Rendered pages of the replaced Mind's documents must not survive
        // into the restored one.
        RenderedPDFPageCache.shared.removeAll()
        ModelImageCache.shared.removeAll()
        CacheDiagnostics.reset()
        // Registry reload re-hydrates pins from the restored reminders.json
        // itself (ordering above matters: reminders restored first); the
        // publish afterwards keeps ReminderService as the ongoing source of
        // truth for later mutations.
        await SubagentSessionRegistry.shared.reloadFromDisk()
        await ReminderService.shared.publishPinnedSessions()
        // Ambient email triggers belong to the replaced conversation, and
        // the AgentMail poller's live state must not survive a wipe/restore
        // (it would resurface a pre-reset backlog). Quiesce the poller FIRST,
        // then clear the ambient buffer — clearing before quiescence left a
        // window where a handler suspended mid-tick re-enqueued afterward
        // (Codex round 8; processNewUnreadEmails also refuses during the
        // restore gate). A quiescence timeout here doesn't abort — the data
        // swap already happened — but late ticks are refused by the bumped
        // generation regardless. Then restart the poller when AgentMail is
        // the active provider (fresh anti-flood seed; a surviving fresh
        // poll-state file restores normally).
        if !(await AgentMailService.shared.resetForWipe()) {
            print("[ConversationManager] WARNING: AgentMail poller not quiescent after restore reset — late ticks will be discarded by the generation token")
        }
        pendingAmbientTriggers.removeAll()
        _ = persistPendingAmbientTriggers()
        // The frozen system-prompt context belongs to the replaced
        // conversation's day — drop it so the next turn refetches under the
        // restored state instead of serving stale inbox/agenda snippets.
        frozenEmailContext = nil
        frozenCalendarContext = nil
        if EmailCalendarProvider.current == .agentmail {
            await AgentMailService.shared.setNewEmailHandler { [weak self] newEmails in
                // nil self = manager gone (shutdown race) → NOT durable:
                // fail-safe false holds the checkpoint so the mail redelivers
                // on the next launch instead of being silently skipped.
                await self?.processNewUnreadEmails(newEmails) ?? false
            }
            await AgentMailService.shared.startBackgroundPoll()
        }
        appliedEmailState = .current
        print("[ConversationManager] Reloaded data after Mind restore")
    }
    
    // MARK: - Helpers
    
    func formattedTime() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }

    func capAssistantMessageForHistoryAndTelegram(_ text: String) -> String {
        // A reply that fits is delivered whole, and any unread tail from an
        // earlier truncated reply is dropped — the conversation has moved on,
        // and history must only contain what actually reached the user.
        guard text.utf16.count > maxAssistantMessageChars else {
            setPendingContinuation(nil)
            return text
        }
        // Reserve room for the truncation notice so visible + notice stays
        // under Telegram's 4096 UTF-16 limit.
        let (visible, remainder) = Self.splitByUTF16(text, limit: maxAssistantMessageChars - Self.continuationNoticeReserve)
        setPendingContinuation(remainder)
        print("[ConversationManager] Assistant message capped (original: \(text.utf16.count) UTF-16 units, \(remainder?.utf16.count ?? 0) pending for /continue)")
        guard let remainder else { return visible }
        return visible + Self.continuationNotice(remainingUTF16: remainder.utf16.count)
    }

    private static func continuationNotice(remainingUTF16: Int) -> String {
        "\n\n[MESSAGE TRUNCATED — \(remainingUTF16) more characters. Send /continue to receive the next part.]"
    }

    /// Split a string so the head's UTF-16 length fits within `limit`
    /// (Telegram counts message length in UTF-16 code units), never breaking
    /// inside a grapheme cluster. Returns nil rest when everything fits.
    private static func splitByUTF16(_ text: String, limit: Int) -> (head: String, rest: String?) {
        guard text.utf16.count > limit else { return (text, nil) }
        var used = 0
        var endIndex = text.startIndex
        for idx in text.indices {
            let charUTF16Len = text[idx].utf16.count
            if used + charUTF16Len > limit { break }
            used += charUTF16Len
            endIndex = text.index(after: idx)
        }
        let rest = String(text[endIndex...])
        return (String(text[text.startIndex..<endIndex]), rest.isEmpty ? nil : rest)
    }

    private func setPendingContinuation(_ text: String?) {
        pendingContinuationText = text
        if let text, !text.isEmpty {
            try? PrivateStorage.writeAtomically(Data(text.utf8), to: pendingContinuationFileURL)
        } else {
            try? FileManager.default.removeItem(at: pendingContinuationFileURL)
        }
    }

    func loadPendingContinuation() {
        guard let data = try? Data(contentsOf: pendingContinuationFileURL),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return }
        pendingContinuationText = text
    }

    /// Deliver the next chunk of a truncated reply. The chunk is appended to
    /// history as its own assistant message so history always mirrors exactly
    /// what reached the user's chat — never the undelivered tail.
    func sendPendingContinuationChunk() async {
        guard activeRunId == nil else {
            try? await sendText("⏳ I'm still working on a task — send /continue again once it finishes.")
            return
        }
        guard let remainder = pendingContinuationText, !remainder.isEmpty else {
            try? await sendText("Nothing to continue — the last reply was delivered in full.")
            return
        }
        let prefix = "[…continued]\n"
        let visible: String
        if prefix.utf16.count + remainder.utf16.count <= maxAssistantMessageChars {
            setPendingContinuation(nil)
            visible = prefix + remainder
        } else {
            let (chunk, rest) = Self.splitByUTF16(
                remainder,
                limit: maxAssistantMessageChars - Self.continuationNoticeReserve - prefix.utf16.count
            )
            setPendingContinuation(rest)
            visible = prefix + chunk + (rest.map { Self.continuationNotice(remainingUTF16: $0.utf16.count) } ?? "")
        }
        messages.append(Message(role: .assistant, content: visible))
        saveConversation()
        try? await sendText(visible)
    }
    
    // MARK: - Image Access (for UI)
    
    func imageURL(for message: Message) -> URL? {
        guard let fileName = message.imageFileName else { return nil }
        let url = imagesDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    /// Returns all image URLs for a message (primary attachments)
    func imageURLs(for message: Message) -> [URL] {
        message.imageFileNames.compactMap { fileName in
            let url = imagesDirectory.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
    
    /// Returns all referenced image URLs for a message (from replied-to messages)
    func referencedImageURLs(for message: Message) -> [URL] {
        message.referencedImageFileNames.compactMap { fileName in
            let url = imagesDirectory.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
    
    /// Returns the URL for a document file
    func documentURL(fileName: String) -> URL? {
        let url = documentsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    // MARK: - Context for Settings Structuring
    
    /// Get conversation context for the "Process & Save" feature in Settings.
    /// Returns recent messages and chunk summaries so Gemini has full awareness.
    func getContextForStructuring() async -> (recentMessages: [Message], chunkSummaries: [ArchivedSummaryItem]) {
        let chunkSummaries = await diagnosticArchiveView().items.filter { $0.kind != .liveOverlapDisclosure }
        // Return last 20 messages for recent context
        let recentMessages = Array(messages.suffix(20))
        return (recentMessages, chunkSummaries)
    }
    
    /// Load the full archived text for a specific chunk.
    func getArchivedChunkContent(chunkId: UUID) async throws -> String {
        try await archiveService.getChunkContent(chunkId: chunkId)
    }
}
