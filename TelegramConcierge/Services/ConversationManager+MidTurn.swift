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

    // MARK: - Mid-turn early wake (plan v7, release 1a)

    /// Append → persist → mint → fire (§3.1): called by both enqueue sites
    /// after the queue mirror was written. Only `.userText` mints a
    /// generation and fires; ambient kinds never do.
    func noteMidTurnEnqueued(_ message: Message) {
        guard message.kind == .userText, let runId = activeRunId else { return }
        nextMidTurnGeneration += 1
        let generation = nextMidTurnGeneration
        midTurnGeneration[message.id] = generation
        let at = ContinuousClock.now
        Task { await TurnWakeCenter.shared.fire(runId: runId, generation: generation, at: at) }
    }

    /// Record that queued messages entered history (every later request
    /// renders them). Returns the highest generation among them.
    @discardableResult
    func noteAppendedToHistory(_ batch: [Message]) -> UInt64? {
        let generations = batch.compactMap { midTurnGeneration[$0.id] }
        guard let highest = generations.max() else { return nil }
        appendedMidTurnGeneration = max(appendedMidTurnGeneration, highest)
        for message in batch { midTurnGeneration.removeValue(forKey: message.id) }
        return highest
    }

    /// Stale-batch test (§3.2): a queued `.userText` whose generation is
    /// higher than the highest generation rendered into the transmitted
    /// request that produced this batch. Messages without a generation
    /// (recovered from disk, seeded by tests) never suppress.
    func batchIsStale() -> Bool {
        pendingMidTurnMessages.contains {
            $0.kind == .userText && (midTurnGeneration[$0.id] ?? 0) > seenGenerationAtRequest
        }
    }

    /// The synthetic result of one call of a suppressed batch.
    static func notExecutedResult(for call: ToolCall) -> ToolResultMessage {
        var result = ToolResultMessage(toolCallId: call.id, content: notExecutedResultContent)
        result.outcomeBinding = OutcomeBinding(kind: .notExecuted)
        return result
    }

    /// Harness status for the wake note (§3.11): main-owned bash jobs still
    /// running when the batch is drained. nil when nothing runs (nothing is
    /// rendered and the annotation bytes are unchanged).
    func wakeNoteStatus(movedThisRound: Set<UUID>) async -> HarnessBackgroundStatus? {
        let running = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
        let subagents = await SubagentBackgroundRegistry.shared.runningHandles()
        guard !running.isEmpty || !subagents.isEmpty else { return nil }
        var items = running.map { job -> HarnessBackgroundStatus.Item in
            let command = job.command.count > 80 ? String(job.command.prefix(80)) + "…" : job.command
            var detail = Self.formatShortDuration(job.runningForSeconds)
            if let workdir = job.workdir, !workdir.isEmpty { detail += ", in \(Self.abbreviatedPath(workdir))" }
            detail += movedThisRound.contains(job.jobUUID) ? ", moved to the background" : ", running in the background"
            return .init(label: "bash \(job.handle) \(Self.jsonQuoted(command))", detail: detail)
        }
        // Background and wake-detached subagents (1b). Descriptions are
        // model-authored: JSON-quoted here, neutralized by the renderer.
        for handle in subagents {
            let description = handle.description.count > 80 ? String(handle.description.prefix(80)) + "…" : handle.description
            let kind = SubagentTypes.find(name: handle.subagentType)?.isWebResearcher == true
                ? "Web research \(handle.id)" : "subagent \(handle.id) (\(handle.subagentType))"
            var detail = Self.formatShortDuration(Int(Date().timeIntervalSince(handle.startedAt)))
            detail += handle.jobId.map { movedThisRound.contains($0) } == true ? ", moved to the background" : ", running in the background"
            items.append(.init(label: "\(kind) \(Self.jsonQuoted(description))", detail: detail))
        }
        let status = HarnessBackgroundStatus(items: Array(items.prefix(HarnessBackgroundStatus.maxItems)))
        return status.isValid ? status : nil
    }

    static func jsonQuoted(_ text: String) -> String {
        (try? String(data: JSONEncoder().encode(text), encoding: .utf8) ?? nil) ?? "\"\""
    }

    static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func formatShortDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }

    /// A provider request was fully constructed and successfully transmitted.
    /// The guard stands down ONLY if that request's interaction chain
    /// actually carried the in-flight annotation (nonce match) — a request
    /// whose interactions lost the annotation (context-exhaustion discard,
    /// spend-limit force-finish) leaves the guard armed so teardown recovery
    /// requeues the batch (Codex round-1 finding 1).
    func clearInFlightMidTurnBatchIfCarried(by interactions: [ToolInteraction]?) {
        guard let batch = inFlightMidTurnBatch else { return }
        if MidTurnDrainSupport.interactionsCarryAnnotation(nonce: batch.nonce, in: interactions) {
            recordDeliveredUserMessages(batch.messages)
            inFlightMidTurnBatch = nil
        }
    }

    func clearResponsesMidTurnBatch(_ response: LLMResponse) {
        let receipt: PreparedRequestReceipt?
        switch response {
        case .text(_, _, _, _, _, _, let metadata, _): receipt = metadata?.receipt
        case .toolCalls(let assistant, _, _, _, _): receipt = assistant.responsesReceipt
        }
        if let batch = inFlightMidTurnBatch, receipt?.deliveryNonces.contains(batch.nonce) == true {
            recordDeliveredUserMessages(batch.messages)
            inFlightMidTurnBatch = nil
        }
    }

    /// Image-rejection recovery, main agent (plan v2 §2.4 steps 3–4, Codex
    /// round 2 persistence requirement): check stop and run ownership BEFORE
    /// writing anything, apply the marks to every live copy (canonical
    /// history, the request copy, the current rounds — in-memory bytes and
    /// persisted references alike), then persist: the turn checkpoint first
    /// (it carries the current rounds' reference marks; an ordinary
    /// checkpoint write is enough because the marks live inside the rounds),
    /// then conversation.json (user and historical marks). Returns false when
    /// a write failed: the caller does not resend and the turn fails as
    /// today. A crash between the two writes repeats at most one free 400.
    func commitImageRejectionMarks(_ scope: Set<ImageSlot>, runId: UUID?, responses: Bool,
                                           messagesForLLM: inout [Message], rounds: inout [ToolInteraction]) throws -> Bool {
        try Task.checkCancellation()
        try requireSalvageOwnership(runId)
        var history = messages
        _ = ImageRejectionMarks.apply(scope, to: &history)
        var copy = messagesForLLM
        _ = ImageRejectionMarks.apply(scope, to: &copy)
        var current = rounds
        _ = ImageRejectionMarks.apply(scope, toCurrent: &current)
        if let runId, activeTurnCheckpoints[runId] != nil {
            if responses {
                do { try persistResponsesSalvage(current) } catch {
                    print("[ImageRejection] checkpoint write failed: \(error.localizedDescription)")
                    return false
                }
            } else {
                guard persistTurnSalvage(current, runId: runId) else { return false }
            }
        }
        // The checkpoint (when any) now holds the marked rounds: every live
        // copy follows it from here on, even if the conversation write below
        // fails, so ordinary failure handling (error salvage, a later save)
        // never republishes an unmarked copy over the durable one (Codex
        // implementation review R1). A failed write still means no resend.
        rounds = current
        if let runId { activeTurnCheckpoints[runId]?.retainedInteractions = current }
        messagesForLLM = copy
        Self.imageRejectionBoundaryForTesting?("afterCheckpoint")
        // History marks stay in memory even if this save fails: a failure
        // after the file was replaced (post-rename fsync) has published them,
        // and a later save must not roll them back.
        messages = history
        guard saveConversation() else {
            print("[ImageRejection] conversation write failed; not resending")
            return false
        }
        Self.imageRejectionBoundaryForTesting?("afterConversation")
        CacheDiagnostics.noteTransition("image-rejection", lane: .main)
        return true
    }

    /// Owner check before a Responses salvage write (round delivery v3,
    /// Codex acceptance check 2): a run stopped while a newer run owns the
    /// recovery file must not replace that file with its own rounds. Before
    /// a batch runs, a stopped run starts nothing (cancellation); after it,
    /// the completed round stays in memory and is saved through the stopped
    /// run's interrupted-outcome path.
    func requireSalvageOwnership(_ runId: UUID?) throws {
        guard ownsSalvageFile(runId) else { throw CancellationError() }
    }

    /// Whether `runId` may write the recovery file (no newer run owns it);
    /// a refusal is counted.
    func ownsSalvageFile(_ runId: UUID?) -> Bool {
        if let runId, let owner = activeRunId, owner != runId {
            salvageWritesRefusedForOwnership += 1
            return false
        }
        return true
    }

    func persistResponsesSalvage(_ interactions: [ToolInteraction]) throws {
        if let runID = activeRunId, var checkpoint = activeTurnCheckpoints[runID], checkpoint.isEnvelope {
            checkpoint.retainedInteractions = interactions
            try writeTurnCheckpoint(checkpoint)
        } else {
            try PrivateStorage.writeAtomically(try JSONEncoder().encode(interactions), to: turnSalvageFileURL)
        }
    }

    /// Remove every attached annotation from an interaction chain that is
    /// about to be retried or persisted after an aborted render.
    func stripCurrentTurnAnnotations(in toolInteractions: inout [ToolInteraction]) {
        for i in toolInteractions.indices {
            for j in toolInteractions[i].results.indices {
                toolInteractions[i].results[j].harnessAnnotations.removeAll()
            }
        }
    }

    /// Request construction aborted on a render-invariant violation before
    /// any network transmission (plan §8 step 13): strip the undeliverable
    /// annotation from the current interaction chain and requeue the batch at
    /// the front so the messages reach the model at a later boundary. History
    /// keeps the copies appended at drain time; the id-dedup in the typed
    /// drain prevents duplicates on redelivery.
    func restoreInFlightMidTurnBatch(in toolInteractions: inout [ToolInteraction]) {
        guard let batch = inFlightMidTurnBatch else { return }
        inFlightMidTurnBatch = nil
        stripCurrentTurnAnnotations(in: &toolInteractions)
        var queue = pendingMidTurnMessages
        MidTurnDrainSupport.requeue(batch.messages, into: &queue)
        pendingMidTurnMessages = queue
        persistPendingMidTurnQueue()
        DebugTelemetry.log(
            .info,
            summary: "mid-turn annotation render aborted — batch requeued",
            detail: "\(batch.messages.count) message(s) restored to the queue",
            isError: true
        )
    }

    /// Turn-teardown safety net (Codex round-1 finding 1): a drained batch
    /// whose annotation never rode a successfully transmitted request —
    /// exhaustion discarded its interaction, the turn hit a spend limit, was
    /// cancelled, or failed before/at transport — is requeued here so the
    /// follow-up drain that runs immediately after starts a turn that
    /// actually answers it. History already holds the message copies; every
    /// redelivery path id-dedups against history, so this is at-least-once,
    /// never loss.
    private func recoverStrandedMidTurnBatch() {
        guard let stranded = inFlightMidTurnBatch else { return }
        inFlightMidTurnBatch = nil
        var queue = pendingMidTurnMessages
        MidTurnDrainSupport.requeue(stranded.messages, into: &queue)
        pendingMidTurnMessages = queue
        persistPendingMidTurnQueue()
        DebugTelemetry.log(
            .info,
            summary: "stranded mid-turn batch requeued at turn end",
            detail: "\(stranded.messages.count) message(s) — annotation never reached a transmitted request",
            isError: true
        )
    }

    /// Read pending_midturn.json without side effects. `absent` only when
    /// the path provably does not exist (ENOENT); any other stat, read or
    /// decode failure is `unreadable`.
    func readHeldQueueFile() -> QueueFileState {
        let path = pendingMidTurnFileURL.path
        var st = stat()
        if lstat(path, &st) != 0 {
            return errno == ENOENT ? .absent : .unreadable(String(cString: strerror(errno)))
        }
        guard let data = try? Data(contentsOf: pendingMidTurnFileURL) else { return .unreadable("could not be read") }
        guard let decoded = try? JSONDecoder().decode([Message].self, from: data) else { return .unreadable("could not be decoded") }
        return .readable(decoded)
    }

    /// While history is unreadable the durable queue file is the held
    /// state: load it into memory (file order first, then anything only in
    /// memory, id-deduplicated) WITHOUT admitting it to history. Returns
    /// false — and records the problem — when the file exists but cannot
    /// be read; the file is then left untouched.
    @discardableResult
    func hydrateHeldQueueFromDisk() -> Bool {
        switch readHeldQueueFile() {
        case .absent:
            setHeldQueueProblem(nil)
            return true
        case .unreadable(let reason):
            setHeldQueueProblem(reason)
            return false
        case .readable(let onDisk):
            setHeldQueueProblem(nil)
            var seen = Set<UUID>()
            var merged: [Message] = []
            for message in onDisk + pendingMidTurnMessages where seen.insert(message.id).inserted {
                merged.append(message)
            }
            if merged.map(\.id) != pendingMidTurnMessages.map(\.id) { pendingMidTurnMessages = merged }
            return true
        }
    }

    /// Record (or clear) an unreadable held-message file, alerting on the
    /// transition. Callers clear it only after taking the file's contents
    /// into custody (see `heldQueueFileProblem`).
    func setHeldQueueProblem(_ reason: String?) {
        let was = heldQueueFileProblem
        heldQueueFileProblem = reason
        if let reason, was == nil {
            print("[ConversationManager] Held-message file can't be read (\(reason)) — kept as is; no new work starts")
            Task { await MaintenanceAlertCenter.shared.reportFailure(.heldMessageQueue, error: reason, deterministic: false) }
        } else if reason == nil {
            if was != nil { heldQueueRefusalNoticeSent = false }
            Task { await MaintenanceAlertCenter.shared.reportSuccess(.heldMessageQueue) }
        }
    }

    func readActiveTurnMarkerState() -> TurnMarkerState {
        let path = activeTurnMarkerFileURL.path
        var st = stat()
        if lstat(path, &st) != 0 { return errno == ENOENT ? .absent : .unreadable }
        guard let data = try? Data(contentsOf: activeTurnMarkerFileURL),
              let marker = try? JSONDecoder().decode(ActiveTurnMarker.self, from: data) else { return .unreadable }
        return .readable(marker)
    }

    /// Every known /stop entry (in memory and as loaded at startup).
    var allStopEntries: [StopEntry] {
        var seen = Set(stopEntries.map(\.stopId))
        return stopEntries + stopIntent.entries.filter { seen.insert($0.stopId).inserted }
    }

    /// Write the mid-turn queue to disk (or remove the file when empty).
    /// Called on every queue mutation — enqueue, drain, follow-up drain,
    /// clear — so the file always mirrors memory. Returns false when the
    /// mirror could not be written (the caller decides whether that blocks
    /// the Telegram acknowledgment).
    @discardableResult
    func persistPendingMidTurnQueue() -> Bool {
        // Backstop: a held-message file that could not be read holds
        // acknowledged messages and is never replaced or removed — whether
        // or not history loads, and even when the in-memory queue is empty
        // (1a round 6).
        if heldQueueFileProblem != nil { return false }
        if pendingMidTurnMessages.isEmpty {
            try? FileManager.default.removeItem(at: pendingMidTurnFileURL)
            return true
        }
        do {
            if Self.heldQueueWriteFaultForTesting { throw CocoaError(.fileWriteUnknown) }
            let data = try JSONEncoder().encode(pendingMidTurnMessages)
            try PrivateStorage.writeAtomically(data, to: pendingMidTurnFileURL)
            return true
        } catch {
            print("[ConversationManager] FAILED to mirror mid-turn queue to disk: \(error)")
            return false
        }
    }

    /// Durable mirror of the deferred ambient-trigger queue (same pattern as
    /// persistPendingMidTurnQueue). Empty queue → file removed.
    func persistPendingAmbientTriggers() -> Bool {
        if pendingAmbientTriggers.isEmpty {
            try? FileManager.default.removeItem(at: pendingAmbientFileURL)
            return true
        }
        do {
            let data = try JSONEncoder().encode(pendingAmbientTriggers)
            try PrivateStorage.writeAtomically(data, to: pendingAmbientFileURL)
            return true
        } catch {
            print("[ConversationManager] FAILED to mirror ambient-trigger queue to disk: \(error)")
            return false
        }
    }

    /// Consume an ambient-trigger queue left behind by a crashed process:
    /// the poller had already checkpointed past these arrivals (they were
    /// durable in THIS file), so without recovery they would never surface.
    /// Runs once at startPolling after the conversation is loaded; id-dedup
    /// against history covers a crash between a drain's saveConversation and
    /// the queue-file clear. An undecodable file is deleted (poison entry
    /// must not wedge startup).
    func recoverPersistedAmbientTriggers() {
        guard historyLoadFailure == nil else { return }  // queue file kept until history loads
        guard let data = try? Data(contentsOf: pendingAmbientFileURL) else { return }
        guard let recovered = try? JSONDecoder().decode([Message].self, from: data) else {
            try? FileManager.default.removeItem(at: pendingAmbientFileURL)
            return
        }
        let historyIds = Set(messages.map { $0.id })
        let fresh = recovered.filter { !historyIds.contains($0.id) }
        // Remove the file only when every entry is COMMITTED, not merely
        // present in memory (a failed save keeps the file as the durable copy).
        guard recovered.contains(where: { !lastSavedMessageIDs.contains($0.id) }) else {
            try? FileManager.default.removeItem(at: pendingAmbientFileURL)
            return
        }
        guard !fresh.isEmpty else { return }
        pendingAmbientTriggers.append(contentsOf: fresh)
        print("[ConversationManager] Recovered \(fresh.count) ambient trigger(s) from a previous process — will start an ambient turn when idle")
        // The file stays until the drain's saveConversation succeeds; the
        // id-dedup above makes a re-consumed file harmless.
    }

    /// Consume a mid-turn queue left behind by a crashed process: the
    /// messages were acknowledged to Telegram (never re-served) but had not
    /// reached conversation history. Runs once at startPolling, after the
    /// conversation is loaded and before the first poll tick. Messages whose
    /// id already exists in history are skipped — that covers a crash in the
    /// window between a drain's saveConversation and the queue-file clear.
    /// The queue file is deleted only after the conversation save succeeds;
    /// the id-dedup makes a re-consumed file harmless. A file that exists
    /// but cannot be read or decoded is NEVER deleted or overwritten (it may
    /// hold acknowledged messages): it is kept byte for byte, reported, and
    /// no new work starts until it reads or the owner moves it aside
    /// (mid-turn early wake 1a, round 6).
    func recoverPersistedMidTurnMessages() {
        // While history is unreadable the queue file is kept and NOT
        // admitted to history — but it is loaded into memory, so a new
        // hold appends to it (never replaces it), and /stop and /status
        // see every held message, including ones acknowledged before a
        // restart.
        if historyLoadFailure != nil {
            if !hydrateHeldQueueFromDisk() {
                showMaintenanceNotice("The file of messages held while history is unreadable can't be read (\(heldQueueFileProblem ?? "unknown")). It is kept as is; new messages are not accepted until it reads again.")
            }
            return
        }
        // History loaded: the queue file's validity is classified on its own
        // (1a round 6). An unreadable file — permission, read or decode
        // failure — holds acknowledged messages: it is kept byte for byte
        // and reported, and no new work starts, until it reads again (repair
        // + restart) or /deleteuserdata. It is never deleted as a poison
        // entry.
        let recovered: [Message]
        switch readHeldQueueFile() {
        case .absent:
            setHeldQueueProblem(nil)
            return
        case .unreadable(let reason):
            setHeldQueueProblem(reason)
            showMaintenanceNotice("The file of messages you sent that I haven't answered yet can't be read (\(reason)). It is kept as is; no new work starts and new messages are not accepted until it reads again.")
            return
        case .readable(let list):
            recovered = list
        }
        // Readable: the contents are taken into custody below (admitted to
        // history, the file removed only once committed).
        setHeldQueueProblem(nil)
        // The file may go only when every queued message is COMMITTED
        // (Codex 1a R1): a message the startup stop pass appended in memory
        // before a failed save is not yet durable — the queue file is then
        // its only durable copy.
        let inMemory = Set(messages.map(\.id))
        let fresh = recovered.filter { !inMemory.contains($0.id) }
        let uncommitted = recovered.filter { !lastSavedMessageIDs.contains($0.id) }
        guard !uncommitted.isEmpty else {
            try? FileManager.default.removeItem(at: pendingMidTurnFileURL)
            return
        }
        print("[ConversationManager] Recovered \(uncommitted.count) queued mid-turn message(s) from before restart")
        messages.append(contentsOf: fresh)
        let held = appendHeldPreStopNotes(for: uncommitted)
        if saveConversation() {
            try? FileManager.default.removeItem(at: pendingMidTurnFileURL)
        } else {
            print("[ConversationManager] Conversation save failed during mid-turn recovery — keeping the queue file for the next startup")
        }
        // Held pre-stop messages are never answered (§3.9.3); an unreadable
        // stop marker means nothing recovered starts work (fail closed).
        guard !stopIntent.isUnknown else { return }
        if activeRunId == nil, activeProcessingTask == nil, let trigger = uncommitted.last(where: { !held.contains($0.id) }) {
            statusMessage = "Generating response..."
            startActiveProcessing(for: trigger)
        }
    }

    /// Mirror the inbound attachment buffers to disk (or remove the file when
    /// they are all empty). Called by the poll loop after every processed
    /// inbound message — the buffers only mutate inside that processing.
    /// Returns false when a non-empty state could not be written.
    @discardableResult
    func persistPendingInboundBuffers() -> Bool {
        // Deterministic fault injection for the durability-stall smoke test:
        // while the flag file exists, this write "fails". Inert in normal
        // operation (env var unset).
        if let flag = ProcessInfo.processInfo.environment["BRIGLIA_TEST_DURABILITY_FAULT_FLAG"],
           FileManager.default.fileExists(atPath: flag) {
            print("[ConversationManager] FAILED to mirror pending attachment buffers to disk: injected test fault")
            return false
        }
        let state = PendingInboundBuffers(
            images: pendingImages.map { PendingFileRecord(fileName: $0.fileName, fileSize: $0.fileSize) },
            documents: pendingDocuments.map { PendingFileRecord(fileName: $0.fileName, fileSize: $0.fileSize) },
            referencedImages: pendingReferencedImages.map { PendingFileRecord(fileName: $0.fileName, fileSize: $0.fileSize) },
            referencedDocuments: pendingReferencedDocuments.map { PendingFileRecord(fileName: $0.fileName, fileSize: $0.fileSize) },
            forwardContext: pendingForwardContext,
            replyContext: pendingReplyContext,
            attachmentNotes: pendingAttachmentNotes
        )
        if state.isEmpty {
            try? FileManager.default.removeItem(at: pendingAttachmentsFileURL)
            return true
        }
        do {
            let data = try JSONEncoder().encode(state)
            try PrivateStorage.writeAtomically(data, to: pendingAttachmentsFileURL)
            return true
        } catch {
            print("[ConversationManager] FAILED to mirror pending attachment buffers to disk: \(error)")
            return false
        }
    }

    /// Restore attachment buffers a crashed process left behind, so a photo
    /// sent without a caption still attaches to the text that arrives after
    /// the restart. Runs once at startPolling; empty in-memory buffers are a
    /// precondition (nothing has been received yet), so restoring is a plain
    /// assignment.
    func restorePendingInboundBuffers() {
        guard let data = try? Data(contentsOf: pendingAttachmentsFileURL),
              let state = try? JSONDecoder().decode(PendingInboundBuffers.self, from: data),
              !state.isEmpty else { return }
        pendingImages = state.images.map { (fileName: $0.fileName, fileSize: $0.fileSize) }
        pendingDocuments = state.documents.map { (fileName: $0.fileName, fileSize: $0.fileSize) }
        pendingReferencedImages = state.referencedImages.map { (fileName: $0.fileName, fileSize: $0.fileSize) }
        pendingReferencedDocuments = state.referencedDocuments.map { (fileName: $0.fileName, fileSize: $0.fileSize) }
        pendingForwardContext = state.forwardContext
        pendingReplyContext = state.replyContext
        pendingAttachmentNotes = state.attachmentNotes
        let count = pendingImages.count + pendingDocuments.count
            + pendingReferencedImages.count + pendingReferencedDocuments.count
        print("[ConversationManager] Restored \(count) buffered attachment(s) / pending context from before restart")
    }

    /// A user-message turn's trigger is in durable history and its update is
    /// confirmed before the turn's work begins — a power failure mid-turn
    /// leaves the question permanently unanswered unless startup notices.
    /// The marker is written when such a turn starts and removed in the
    /// turn's defer, after its outcome (answer, interruption note, or error)
    /// reached conversation state.
    ///
    /// Marked kinds: real user text AND reminder/watcher fires. "Saved is
    /// not processed" (§3b): a watcher-fire note saved to history whose turn
    /// never starts would sit there unacted-on forever — the fire outbox
    /// keeps such batches pending until this marker is durably written, and
    /// the marker makes the turn itself resumable after a crash. Other
    /// ambient kinds (emails, bash/subagent completions) still re-derive
    /// from their own sources and must not resurrect as ghost turns.
    /// Returns whether the marker reached disk (vacuously true for turns
    /// that need no marker). A failure participates in the durability-stall
    /// contract via the caller — the update stays unconfirmed and, because
    /// the stall retry re-runs remarkActiveTurnIfNeeded, the confirm cannot
    /// happen until the marker actually exists.
    @discardableResult
    func writeActiveTurnMarker(for message: Message) -> Bool {
        guard message.kind == .userText || message.kind == .reminderFired else { return true }
        // Shares the durability fault hook so the stall tests cover the
        // marker path too. Inert in normal operation.
        if let flag = ProcessInfo.processInfo.environment["BRIGLIA_TEST_DURABILITY_FAULT_FLAG"],
           FileManager.default.fileExists(atPath: flag) {
            print("[ConversationManager] FAILED to write active-turn marker: injected test fault")
            return false
        }
        let marker = ActiveTurnMarker(triggerMessageId: message.id, startedAt: Date())
        do {
            let data = try JSONEncoder().encode(marker)
            try PrivateStorage.writeAtomically(data, to: activeTurnMarkerFileURL)
            return true
        } catch {
            print("[ConversationManager] FAILED to write active-turn marker: \(error)")
            return false
        }
    }

    /// Stall-recovery leg for the active-turn marker: if a user-text turn is
    /// running but its marker never reached disk (possibly the very write
    /// failure that triggered the stall), recreate it before confirming —
    /// otherwise the recovery could confirm the update while leaving a turn
    /// in flight that a later power failure couldn't resume.
    func remarkActiveTurnIfNeeded() -> Bool {
        guard let trigger = activeTurnTriggerMessage else { return true }
        return writeActiveTurnMarker(for: trigger)
    }

    /// Unconditional removal — reserved for the startup resume path, which
    /// consumes the marker it just read.
    func clearActiveTurnMarker() {
        try? FileManager.default.removeItem(at: activeTurnMarkerFileURL)
    }

    /// Ownership-scoped removal for a finishing turn: a stale defer from a
    /// cancelled turn that unwinds AFTER a newer turn started must not
    /// delete the newer turn's marker. A file that no longer decodes is
    /// removed regardless — it protects nothing.
    func clearActiveTurnMarker(ownedBy triggerId: UUID) {
        guard let data = try? Data(contentsOf: activeTurnMarkerFileURL) else { return }
        if let marker = try? JSONDecoder().decode(ActiveTurnMarker.self, from: data),
           marker.triggerMessageId != triggerId {
            return
        }
        try? FileManager.default.removeItem(at: activeTurnMarkerFileURL)
    }

    /// Resume a turn a crashed process left mid-flight: the trigger message
    /// is in history (already acknowledged to Telegram, so it will never
    /// re-deliver) but no outcome ever landed. Runs at startPolling AFTER
    /// mid-turn queue recovery — if that recovery already started a turn, the
    /// unanswered message is part of its context and a second turn would
    /// answer twice, so the marker is just cleared.
    func resumeInterruptedActiveTurnIfNeeded() {
        guard workHeldReason == nil else { return }  // marker kept until history and the held-message file load
        guard let data = try? Data(contentsOf: activeTurnMarkerFileURL) else { return }
        // A turn started by an earlier startup pass (e.g. queue recovery of
        // messages held while history was unreadable) has already replaced
        // the file with its OWN marker — keep it, so that turn stays
        // crash-resumable (1a round 4).
        if activeRunId != nil || activeProcessingTask != nil,
           let own = try? JSONDecoder().decode(ActiveTurnMarker.self, from: data),
           own.triggerMessageId == activeTurnTriggerMessage?.id {
            return
        }
        clearActiveTurnMarker()
        guard activeRunId == nil, activeProcessingTask == nil, !recoveryBlocked else { return }
        guard let marker = try? JSONDecoder().decode(ActiveTurnMarker.self, from: data),
              let trigger = messages.last(where: { $0.id == marker.triggerMessageId }) else { return }
        // A turn stopped by /stop is never resumed; with an unreadable stop
        // marker nothing is resumed (§3.9.3).
        guard !stopIntent.isUnknown,
              !allStopEntries.contains(where: { $0.coversInterruptedTurn(triggerId: marker.triggerMessageId, startedAt: marker.startedAt) }) else {
            print("[ConversationManager] Not resuming the interrupted turn: it was stopped by /stop (or the stop marker is unreadable)")
            return
        }
        print("[ConversationManager] Resuming turn interrupted by shutdown (trigger message \(marker.triggerMessageId.uuidString.prefix(8)))")
        statusMessage = "Generating response..."
        startActiveProcessing(for: trigger)
    }

    func startActiveProcessing(for userMessage: Message) {
        guard activeRunId == nil, activeProcessingTask == nil else {
            print("[ConversationManager] Ignoring startActiveProcessing because a run is already active")
            return
        }
        // Central admission rule (1a round 4): no model/tool work and no new
        // active-turn marker while history is unreadable — the preserved
        // marker is the only record of an interrupted request. Every caller
        // also holds its input before reaching here; this is the backstop.
        if let workHeldReason {
            print("[ConversationManager] Not starting a turn: \(workHeldReason)")
            return
        }

        // Retry unpublished in-memory recovery before a new owner can replace
        // its disk record. If storage is still unavailable, the normal local
        // error path below refuses model work.
        if recoveryBlocked { recoverInterruptedTurnSalvageIfNeeded() }
        let runId = UUID()
        activeRunId = runId
        activeTurnTriggerMessage = userMessage
        if !writeActiveTurnMarker(for: userMessage) {
            inboundDurabilityFailure = true
        }

        activeProcessingTask = Task { [weak self] in
            await self?.runActiveProcessing(for: userMessage, runId: runId)
        }
    }

    private func runActiveProcessing(
        for userMessage: Message,
        runId: UUID
    ) async {
        defer {
            // Every non-crash exit passes here — answer delivered, /stop,
            // error, context exhaustion — and each of those persisted its
            // outcome, so the power-failure marker comes off. Only a hard
            // kill leaves it for startup to find. Ownership-scoped: a stale
            // defer unwinding after a newer turn started must not delete
            // that turn's marker.
            clearActiveTurnMarker(ownedBy: userMessage.id)
            // Round delivery (v3 §2.5): this run's appended background
            // results that no saved history carries are released to idle
            // delivery; those still carried by unsaved history stay reserved
            // until a later save. Run-scoped: never a newer run's items.
            releaseRoundDeliveryReservations(ofRun: runId)
            // /stop visibility: this run's own phase record (run-keyed; a
            // newer run's entry is never touched).
            runPhases.removeValue(forKey: runId)
            if activeRunId == runId {
                activeRunId = nil
                activeProcessingTask = nil
                activeTurnTriggerMessage = nil
                currentTurnLogIsActive = false
                turnActivity = nil
            }
            // /keepsummaries: end of a turn is an idle-pass trigger.
            scheduleSummaryRetentionIdlePass()
            // Mid-turn early wake: this run can no longer be woken; a newer
            // run's arm/scope is never touched (run-id scoped).
            let executor = toolExecutor
            Task {
                await TurnWakeCenter.shared.disarm(runId: runId)
                await executor.clearWakeTurn(ifRunId: runId)
            }
            // Stranded-batch recovery must run before the follow-up drain:
            // a drained mid-turn batch whose annotation never reached a
            // transmitted request re-enters the queue here, so the follow-up
            // turn below picks it up and answers it.
            if activeRunId == nil, activeProcessingTask == nil {
                recoverStrandedMidTurnBatch()
            }
            // User messages that arrived too late to steer this turn (during
            // final text generation, after /stop, or after an error) start a
            // fresh follow-up turn now so they are never silently dropped.
            // All queued messages enter history; the last one is the trigger
            // (the new turn's context window includes them all).
            if isPolling, activeRunId == nil, activeProcessingTask == nil,
               workHeldReason == nil, !pendingMidTurnMessages.isEmpty {
                let queued = pendingMidTurnMessages
                pendingMidTurnMessages.removeAll()
                // Id-dedup: a batch requeued after an aborted annotation
                // render already has its history copies from the drain.
                messages.append(contentsOf: queued.filter { queuedMessage in
                    !messages.contains(where: { $0.id == queuedMessage.id })
                })
                // Messages sent BEFORE a /stop (O-S1) are kept in history
                // unchanged, followed by one id-deduplicated harness note,
                // and do not start a turn (§3.9.3). Only messages that
                // arrived after the cutoff start the follow-up.
                let held = appendHeldPreStopNotes(for: queued)
                noteAppendedToHistory(queued)
                saveConversation()
                persistPendingMidTurnQueue()
                retireSettledStopEntries()
                if let trigger = queued.last(where: { !held.contains($0.id) }) {
                    print("[ConversationManager] Starting follow-up turn for \(queued.count) queued mid-turn message(s)")
                    statusMessage = "Generating response..."
                    startActiveProcessing(for: trigger)
                } else {
                    print("[ConversationManager] Kept \(queued.count) message(s) sent before /stop for the next request (no turn started)")
                }
            }
            // Deferred ambient triggers wait behind user messages; the drain
            // no-ops if the follow-up turn above just started.
            if isPolling {
                drainPendingAmbientTriggers()
            }
        }

        // Reset the per-turn tool log so /status shows only this turn.
        currentTurnToolLog = []
        currentTurnLogIsActive = true
        turnActivity = TurnActivity(kind: .thinking, startedAt: Date())
        runPhases[runId] = .model(Date())

        // Mid-turn early wake (§3.1): arm this run and give the main
        // executor its wake scope (run id + history anchor for crash-record
        // evidence searches). Disarmed in the teardown below.
        consecutiveSuppressions = 0
        seenGenerationAtRequest = appendedMidTurnGeneration
        await TurnWakeCenter.shared.arm(runId: runId)
        await toolExecutor.setWakeTurn(runId: runId, anchor: messages.last?.id)

        let turnStartedAt = Date()
        DebugTelemetry.log(
            .turnStart,
            summary: "turn for msg \(userMessage.id.uuidString.prefix(8))",
            detail: String(userMessage.content.prefix(200))
        )

        // Tell the executor whether this turn's trigger is the human typing —
        // gates writes that create persistent agent-authored code (check-script
        // reminders) out of ambient turns.
        await toolExecutor.setTurnTriggeredByUserText(userMessage.kind == .userText)

        // Wire the mid_turn_message_user tool to this turn's reply channel so
        // the agent can answer messages that arrive while it is still working.
        // The runId guard keeps a cancelled turn's in-flight tool call from
        // messaging the user after a newer turn has taken over.
        lastMidTurnUserAddress = nil
        let midTurnAddress = userMessage.originChannel ?? replyAddress
        await toolExecutor.setMidTurnMessageSender { [weak self] text in
            guard let self else { return }
            try await self.deliverAgentMidTurnMessage(text, for: runId, to: midTurnAddress)
        }

        do {
            let turnStartDate = turnStartedAt
            try Task.checkCancellation()
            let response = try await generateResponseWithTools(
                currentUserMessageId: userMessage.id,
                turnStartDate: turnStartDate,
                salvageRunId: runId
            )
            try Task.checkCancellation()
            
            guard activeRunId == runId else {
                activeTurnCheckpoints.removeValue(forKey: runId)
                clearTurnSalvageFile(ifStillOwnedBy: runId)
                return
            }
            
            var didMutateHistory = false

            // Agent can stay silent on ambient triggers (email arrivals, subagent
            // completions, reminders) by returning [SKIP] or empty text. We still
            // record the turn in history for diagnostics but suppress the Telegram
            // push so the user isn't pinged for every ad, newsletter, or
            // inconsequential background event. User-initiated turns never silently
            // skip — a missing reply there would be a bug.
            let trimmedResponse = response.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAmbientTrigger = userMessage.kind != .userText
            let agentChoseSilence = isAmbientTrigger && (trimmedResponse.isEmpty || trimmedResponse == "[SKIP]")

            // Add assistant message with tool interactions, compact log, downloaded files, and accessed projects
            let finalResponseRaw: String
            if agentChoseSilence {
                finalResponseRaw = "[SKIP]"
            } else if trimmedResponse.isEmpty {
                finalResponseRaw = "I've completed the requested operations."
            } else {
                finalResponseRaw = response.finalText
            }
            // [SKIP] turns send nothing visible, so they must not disturb a
            // pending /continue tail — only delivered replies supersede it.
            let finalResponse = agentChoseSilence
                ? finalResponseRaw
                : capAssistantMessageForHistoryAndTelegram(finalResponseRaw)
            let downloadedFilenames = ToolExecutor.getPendingDownloadedFilenames()
            // Store measured token count on the user message that triggered this turn
            if let measuredUser = response.measuredUserTokens,
               let idx = messages.lastIndex(where: { $0.id == userMessage.id }) {
                messages[idx].measuredTokens = measuredUser
            }
            // Update final-text completion tokens for next-turn delta attribution.
            // Tool replay is already included in the prior prompt; subtracting it
            // here would undercount the next user message, especially after heavy
            // tool/file turns.
            if let assistantCompletionTokens = response.measuredAssistantCompletionTokens {
                lastCompletionTokens = assistantCompletionTokens
            }
            var assistantMessage = Message(
                id: activeTurnCheckpoints[runId].flatMap { $0.isEnvelope ? $0.outcomeMessageID : nil } ?? UUID(),
                role: .assistant,
                content: finalResponse,
                downloadedDocumentFileNames: downloadedFilenames,
                editedFilePaths: response.editedFilePaths,
                generatedFilePaths: response.generatedFilePaths,
                accessedProjectIds: response.accessedProjects ?? [],
                subagentSessionEvents: response.subagentSessionEvents,
                toolInteractions: response.toolInteractions,
                // Compact log is generated lazily at prune time, not stored
                // upfront — the full interactions already carry the same info.
                compactToolLog: nil,
                finalReasoning: response.finalReasoning,
                finalReasoningDetails: response.finalReasoningDetails,
                finalReasoningModel: response.finalReasoningModel,
                measuredToolTokens: response.measuredToolTokens,
                measuredTokens: response.measuredAssistantTokens
            )
            assistantMessage.responsesReplay = response.responsesReplay
            if let checkpoint = activeTurnCheckpoints[runId], checkpoint.isEnvelope {
                assistantMessage.activeTurnCompaction = checkpoint.activeTurnCompaction
                assistantMessage.accessedProjectIds = Array(Set(assistantMessage.accessedProjectIds + checkpoint.accessedProjects)).sorted()
                if let ref = checkpoint.overflowReference { assistantMessage.pruneArchiveReferences.append(ref) }
                assistantMessage.compactToolLog = checkpoint.overflowLog
            }
            messages.append(assistantMessage)
            didMutateHistory = true

            var finalHistorySaved = false
            if didMutateHistory {
                let saved = saveConversation()
                finalHistorySaved = saved
                // Completion-receipt acknowledgement (BASH_V2_PLAN §8.3):
                // a tool result that observed a bash settlement suppresses
                // the automatic completion notice ONLY once the turn that
                // carries it is durably on disk. On save failure,
                // cancellation, or any earlier error path the receipts are
                // simply never redeemed and the notice injects normally —
                // at-least-once, never silent loss. Awaited here, before
                // the active run clears, so the idle drain can't race the
                // withdrawal.
                if saved {
                    let receipts = (activeTurnCheckpoints[runId]?.completionReceipts ?? []) + assistantMessage.toolInteractions
                        .flatMap { $0.results.compactMap(\.bashReceipt) }
                    if !receipts.isEmpty {
                        await BackgroundProcessRegistry.shared.acknowledgeCompletions(receipts)
                    }
                }
            }
            activeTurnCheckpoints.removeValue(forKey: runId)
            // A failed final save must not duplicate completed tool rounds in
            // the error path or suppress delivery. Keep native recovery evidence.
            if finalHistorySaved {
                clearTurnSalvageFile(ifStillOwnedBy: runId)
            } else { recoveryBlocked = true }

            let turnReplyAddress = userMessage.originChannel ?? replyAddress
            if let replyTo = turnReplyAddress {
                if !agentChoseSilence {
                    try Task.checkCancellation()
                    guard activeRunId == runId else { return }
                    try await sendText(finalResponse, to: replyTo)
                }

                // Media drains even on [SKIP] turns: a send_document_to_chat
                // call is an explicit delivery request, and leaving the queue
                // populated would leak the files into whatever turn happens to
                // run next. Generated images are not queued: generate_image
                // never sends; the agent shares one with send_document_to_chat.
                let stillCurrent = try await Self.deliverQueuedTurnMedia(
                    stillCurrent: { [weak self] in self?.activeRunId == runId },
                    sendPhoto: { [weak self] data, caption, mimeType in
                        try await self?.sendPhoto(data, caption: caption, mimeType: mimeType, to: replyTo)
                    },
                    sendDocument: { [weak self] data, filename, caption, mimeType in
                        try await self?.sendDocument(data, filename: filename, caption: caption, mimeType: mimeType, to: replyTo)
                    }
                )
                guard stillCurrent else { return }
            } else {
                // No reply channel configured — nowhere to deliver; drop queued
                // media so it can't leak into a later turn.
                let dropped = ToolExecutor.getPendingDocuments().count
                if dropped > 0 {
                    print("[ConversationManager] Dropped \(dropped) queued media item(s): no reply channel")
                }
            }

            // Descriptions are generated lazily at Watermark prune time, just
            // before inline media/tool attachments leave prompt context. Drain the
            // legacy pending-data queue so large blobs do not leak across turns.
            _ = ToolExecutor.getPendingFilesForDescription()
            
            guard activeRunId == runId else { return }
            let turnMs = Int(Date().timeIntervalSince(turnStartedAt) * 1000)
            DebugTelemetry.log(.turnEnd, summary: "turn complete", durationMs: turnMs)
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        } catch let caught where Self.isCancellation(caught) {
            ToolExecutor.clearPendingToolOutputs()
            DebugTelemetry.log(.turnCancelled, summary: "turn cancelled")
            if activeRunId == runId {
                statusMessage = "Cancelled"
            }

            // Salvage partial tool interactions from the interrupted turn so
            // the agent can see what it did on the next turn.
            let partialCheckpoint = preserveInterruptedCheckpoint(runID: runId)
            let partialInteractions = partialCheckpoint?.pendingRecovery == true ? [] : (partialCheckpoint?.retainedInteractions ?? [])
            var salvageSaved = true
            if !partialInteractions.isEmpty || partialCheckpoint?.isEnvelope == true {
                var assistantMessage = Message(
                    role: .assistant,
                    content: "⛔ Work interrupted after \(partialInteractions.count) operation\(partialInteractions.count == 1 ? "" : "s").",
                    toolInteractions: partialInteractions
                )
                if let checkpoint = partialCheckpoint, checkpoint.isEnvelope {
                    assistantMessage = checkpoint.outcome(text: assistantMessage.content)
                }
                if !messages.contains(where: { $0.id == assistantMessage.id }) { messages.append(assistantMessage) }
                salvageSaved = saveConversation()
                print("[ConversationManager] Saved \(partialInteractions.count) partial tool interaction(s) from cancelled turn")
                // Cancel-salvage receipt fix, narrowed (§3.12, V4-R1): only
                // receipts whose result is in the outcome ACTUALLY saved, and
                // only after that save returned true — never `salvageSaved`
                // alone (it starts true) and never a pendingRecovery outcome
                // (it carries no results). Removes the duplicate
                // [BACKGROUND BASH COMPLETE] after a cancelled turn.
                if salvageSaved, partialCheckpoint?.pendingRecovery != true {
                    let receipts = assistantMessage.toolInteractions.flatMap { $0.results.compactMap(\.bashReceipt) }
                    if !receipts.isEmpty { await BackgroundProcessRegistry.shared.acknowledgeCompletions(receipts) }
                }
            }
            if salvageSaved && partialCheckpoint != nil && partialCheckpoint?.pendingRecovery != true {
                clearTurnSalvageFile(ifStillOwnedBy: runId)
            }

            print("[ConversationManager] Active run cancelled")
        } catch {
            ToolExecutor.clearPendingToolOutputs()
            // Salvage partial tool interactions exactly like the cancellation
            // path: a failed LLM round (rate limit, provider outage, parse
            // error) must not discard the completed rounds' tool calls,
            // results, and reasoning — the next turn needs them to avoid
            // redoing the work.
            let partialCheckpoint = preserveInterruptedCheckpoint(runID: runId)
            let partialInteractions = partialCheckpoint?.pendingRecovery == true ? [] : (partialCheckpoint?.retainedInteractions ?? [])
            DebugTelemetry.log(
                .turnError,
                summary: "turn failed",
                detail: String(describing: error),
                isError: true
            )
            if activeRunId == runId {
                self.error = "Failed to generate response: \(error.localizedDescription)"
                statusMessage = "Error generating response"
            }

            // Surface the failure to the user. Previously a thrown turn just
            // updated a local `error` property and died silently — from the
            // user's side that looks identical to "stuck", because no Telegram
            // reply ever arrives. Append a visible error message to history
            // AND send a Telegram ping so the user knows the turn is dead and
            // a retry is needed. The text includes enough detail to diagnose
            // common cases (rate limit, network, provider outage) without
            // leaking internal stack details.
            var errText = "❌ Something went wrong: \(error.localizedDescription). Send another message to retry."
            let nativePartial = partialInteractions.contains { $0.assistantMessage.responsesReplay != nil }
            if !partialInteractions.isEmpty && !nativePartial {
                errText += " The work done so far (\(partialInteractions.count) operation\(partialInteractions.count == 1 ? "" : "s")) has been saved."
            }
            var errMessage = Message(
                role: .assistant,
                content: errText,
                toolInteractions: partialInteractions
            )
            if let checkpoint = partialCheckpoint, checkpoint.isEnvelope { errMessage = checkpoint.outcome(text: errText) }
            if !messages.contains(where: { $0.id == errMessage.id }) { messages.append(errMessage) }
            let salvageSaved = saveConversation()
            // Same narrowed receipt rule on the error salvage (§3.12).
            if salvageSaved, partialCheckpoint?.pendingRecovery != true {
                let receipts = errMessage.toolInteractions.flatMap { $0.results.compactMap(\.bashReceipt) }
                if !receipts.isEmpty { await BackgroundProcessRegistry.shared.acknowledgeCompletions(receipts) }
            }
            if salvageSaved && partialCheckpoint != nil && partialCheckpoint?.pendingRecovery != true {
                clearTurnSalvageFile(ifStillOwnedBy: runId)
            }
            if nativePartial {
                errText += salvageSaved ? " Completed tool work has been saved." : " Saving conversation failed; the recovery record has been retained."
            }
            if !partialInteractions.isEmpty {
                print("[ConversationManager] Partial tool interactions persisted: \(salvageSaved)")
            }
            do {
                try await sendText(errText, to: userMessage.originChannel ?? replyAddress)
            } catch {
                print("[ConversationManager] Also failed to send error reply: \(TelegramBotService.redactBotTokens(in: "\(error)"))")
            }
        }
    }
    
    /// True for any error representing user/Task cancellation (/stop). URLSession
    /// surfaces cancellation of an in-flight request as `URLError.cancelled`
    /// rather than `CancellationError`, so both must route to the salvage path —
    /// otherwise stopping while the model is generating discards the turn's
    /// partial tool interactions instead of preserving them in history.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    func commandToken(from text: String) -> String {
        let firstToken = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .lowercased() ?? ""
        return firstToken.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// Route a slash command typed in the terminal (or sent by the companion
    /// app) through the SAME command set the messaging channels use, so the
    /// surfaces never drift. Returns the response lines, or nil for an
    /// unknown command.
    ///
    /// Deliberately does NOT touch `lastUserChannelAddress`: running /status
    /// from the app or terminal must not redirect ambient output (reminders,
    /// email alerts) away from the user's phone. The capture window instead
    /// makes `replyAddress` resolve to the wireless app channel for the
    /// command's own task only.
    func handleTerminalCommand(_ text: String) async -> [String]? {
        var result: [String]? = nil
        await handleTerminalCommand(text) { result = $0 }
        return result
    }

    /// Delivery-aware variant (/stop visibility §4.2): `deliver` runs
    /// synchronously on the main actor with the response lines (nil for an
    /// unknown command) and must hand them to the client (enqueue the
    /// socket `command_result`, print the terminal lines); only THEN are
    /// follow-up notices of this command (e.g. a stopped request's completion)
    /// released, so they can never precede the command's own result.
    func handleTerminalCommand(_ text: String, deliver: ([String]?) -> Void) async {
        let capture = CommandResponseCapture()
        let handled = await Self.$commandCapture.withValue(capture) {
            await handleControlCommandIfNeeded(text)
        }
        capture.close()
        deliver(handled ? capture.lines : nil)
        capture.markDelivered()
    }
}


// MARK: - Mid-turn round delivery of background results (plan v3)
//
// While a turn runs, a finished background bash job or background/moved
// subagent is appended as ordinary tool output to the round that just ran
// (see `RoundDelivery`). Acknowledgement waits for a saved history that
// carries it; idle delivery is unchanged and skips reserved ids.
extension ConversationManager {

    /// Selftest seam: awaited at the drain's suspension points with the
    /// stage name ("bash-read", "subagent-read", "after-reads").
    nonisolated(unsafe) static var roundDeliveryInterleaveForTesting: ((String) async -> Void)?
    /// Selftest seam: awaited before the registry withdrawal of acknowledged
    /// round deliveries (holds the in-flight window open).
    nonisolated(unsafe) static var roundWithdrawalHoldForTesting: (() async -> Void)?
    /// Selftest seam: awaited by the idle drains right after their registry
    /// read ("idle-bash", "idle-subagent"), so a test can finish a
    /// withdrawal between that read and the eligibility checks.
    nonisolated(unsafe) static var idleDrainAfterReadForTesting: ((String) async -> Void)?

    private func roundDeliveryAllowed(runId: UUID) -> Bool {
        activeRunId == runId && !Task.isCancelled && workHeldReason == nil && !isRestoringMind
            && !recoveryBlocked && checkpointWriteFailure == nil && !stopIntent.isUnknown
    }

    /// Append every eligible finished background result to the last result
    /// of this round (v3 §2.4). Nothing is acknowledged here.
    func deliverBackgroundResultsIntoRound(runId: UUID, into results: inout [ToolResultMessage],
                                           currentRounds: [ToolInteraction], nextRequestFollows: Bool) async {
        guard RoundDelivery.isEnabled, nextRequestFollows, !results.isEmpty, roundDeliveryAllowed(runId: runId) else { return }
        if let hook = Self.roundDeliveryInterleaveForTesting { await hook("bash-read") }
        let bash = await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery()
        if let hook = Self.roundDeliveryInterleaveForTesting { await hook("subagent-read") }
        let subagents = await SubagentBackgroundRegistry.shared.pendingCompletionsForDelivery()
        if let hook = Self.roundDeliveryInterleaveForTesting { await hook("after-reads") }
        // A /stop, a newer turn or a hold may have interleaved at the awaits.
        guard !bash.isEmpty || !subagents.isEmpty, roundDeliveryAllowed(runId: runId) else { return }

        // Bash jobs the model already observed this turn (a settled
        // `bash_manage wait/output` receipt, retained, compacted or in this
        // very round): their notice is not owed, never appended.
        var observed = Set((currentRounds.flatMap(\.results) + results).compactMap(\.bashReceipt?.jobUUID))
        observed.formUnion(activeTurnCheckpoints[runId]?.completionReceipts.map(\.jobUUID) ?? [])
        for result in currentRounds.flatMap(\.results) + results
        where result.outcomeBinding?.kind == .receiptObserved {
            if let job = result.outcomeBinding?.jobId { observed.insert(job) }
        }
        // Stopped jobs never arrive mid-turn (§2.8), in this or any turn.
        var stopped = stoppedJobIds
        for entry in allStopEntries { stopped.formUnion(entry.affectedJobIds) }
        let inHistory = Set(messages.map(\.id))
        let anchor = committedMessages.last?.id

        var items: [RoundDelivery.Item] = []
        var reservations: [RoundDeliveryReservation] = []
        for item in bash {
            let id = item.messageId
            guard roundDeliveryReservations[id] == nil, !roundDeliveredIds.contains(id), pendingCompletionAcks[id] == nil, !inHistory.contains(id),
                  !stopped.contains(item.jobUUID), !observed.contains(item.jobUUID) else { continue }
            items.append(.init(messageId: id, body: BashCompletionNotice.body(for: item.completion)))
            reservations.append(RoundDeliveryReservation(messageId: id, runId: runId, kind: .bash(jobUUID: item.jobUUID),
                                                          unrecordedSpendUSD: 0, anchor: anchor))
            DebugTelemetry.log(.bashComplete, summary: "bash \(item.completion.handleId) \(BashCompletionNotice.statusLabel(item.completion)) (mid-turn)",
                               detail: "command: \(item.completion.command)", durationMs: item.completion.durationSeconds * 1000)
        }
        for completion in subagents {
            let id = completion.messageId
            let job = completion.handle.jobId
            guard roundDeliveryReservations[id] == nil, !roundDeliveredIds.contains(id), pendingSubagentAcks[id] == nil, !inHistory.contains(id),
                  !stoppedSubagentHandles.contains(completion.handle.id), !(job.map { stopped.contains($0) } ?? false) else { continue }
            let duration = completion.completedAt.timeIntervalSince(completion.handle.startedAt)
            items.append(.init(messageId: id, body: Self.backgroundSubagentCompletionBody(completion, durationStr: String(format: "%.1fs", duration))))
            let unrecorded = (!completion.chargeCaptured && completion.result.spendUSD.isFinite && completion.result.spendUSD > 0)
                ? completion.result.spendUSD : 0
            reservations.append(RoundDeliveryReservation(messageId: id, runId: runId,
                                                          kind: .subagent(jobId: job, handleId: completion.handle.id),
                                                          unrecordedSpendUSD: unrecorded, anchor: anchor))
            DebugTelemetry.log(.subagentComplete, summary: "subagent \(completion.handle.id) (\(completion.handle.subagentType)) done (mid-turn)",
                               detail: "description: \(completion.handle.description)", durationMs: Int(duration * 1000))
        }
        guard !items.isEmpty else { return }
        let last = results.count - 1
        results[last].content = RoundDelivery.append(items, to: results[last].content)
        results[last].deliveredCompletions.append(contentsOf: items.map(\.messageId))
        for reservation in reservations { roundDeliveryReservations[reservation.messageId] = reservation }
        BashJobsStats.log("completions.midturn", by: items.count)
        print("[ConversationManager] Appended \(items.count) background result(s) to the tool round (mid-turn delivery)")
        if let hook = Self.roundDeliveryInterleaveForTesting { await hook("after-append") }
    }

    /// After every successful history save: acknowledge each reserved item
    /// that the SAVED history now carries (typed evidence, inline or via a
    /// reachable snapshot sidecar). Also retries failed record writes.
    func resolveRoundDeliveries() {
        if !roundDeliveryRecordRetries.isEmpty { markRoundDeliveryRecords(roundDeliveryRecordRetries) }
        let pending = roundDeliveryReservations.values.filter { $0.state == .reserved }
        guard !pending.isEmpty else { return }
        let found = roundDeliveryCarried(Set(pending.map(\.messageId)), in: committedMessages, anchors: pending.map(\.anchor)).found
        guard !found.isEmpty else { return }
        acknowledgeRoundDeliveries(found)
    }

    /// Ids among `wanted` that `history` carries. Roots start after the
    /// earliest reservation anchor still present (all messages otherwise).
    private func roundDeliveryCarried(_ wanted: Set<UUID>, in history: [Message], anchors: [UUID?]) -> (found: Set<UUID>, problem: String?) {
        var start = 0
        let indices = anchors.map { anchor in anchor.flatMap { id in history.firstIndex { $0.id == id } } }
        if !indices.contains(where: { $0 == nil }), let first = indices.compactMap({ $0 }).min() { start = first + 1 }
        return SettlementEvidence.deliveredIds(wanted, roots: Array(history[min(start, history.count)...]))
    }

    private func acknowledgeRoundDeliveries(_ ids: Set<UUID>) {
        var bashJobs = Set<UUID>()
        var subagentMessages = Set<UUID>()
        var recordJobs = Set<UUID>()
        var acknowledged = Set<UUID>()
        for id in ids {
            guard var reservation = roundDeliveryReservations[id], reservation.state == .reserved else { continue }
            reservation.state = .acknowledging
            switch reservation.kind {
            case .bash(let job): bashJobs.insert(job); recordJobs.insert(job)
            case .subagent(let job, _):
                subagentMessages.insert(id)
                if let job { recordJobs.insert(job) }
            }
            // Unrecorded run: charged exactly once, here (D6: day/month
            // totals; the per-turn cap is unaffected).
            if !reservation.charged, reservation.unrecordedSpendUSD > 0 {
                KeychainHelper.recordOpenRouterSpend(reservation.unrecordedSpendUSD)
                reservation.charged = true
                print("[ConversationManager] Background subagent spend (delivered mid-turn): +$\(formatUSD(reservation.unrecordedSpendUSD))")
            }
            roundDeliveryReservations[id] = reservation
            roundDeliveredIds.insert(id)
            acknowledged.insert(id)
        }
        guard !acknowledged.isEmpty else { return }
        if !recordJobs.isEmpty { markRoundDeliveryRecords(recordJobs) }
        // The reservation stays (state .acknowledging) until the registry
        // withdrawal has completed, so an idle drain can never append a
        // second copy in between.
        Task { [weak self] in
            if let hold = Self.roundWithdrawalHoldForTesting { await hold() }
            await BackgroundProcessRegistry.shared.acknowledgeDelivered(jobUUIDs: bashJobs)
            await SubagentBackgroundRegistry.shared.acknowledgeDelivered(messageIds: subagentMessages)
            await MainActor.run {
                guard let self else { return }
                for id in acknowledged where self.roundDeliveryReservations[id]?.state == .acknowledging {
                    self.roundDeliveryReservations.removeValue(forKey: id)
                }
                self.retireSettledStopEntries()
            }
        }
    }

    /// Checked `.delivered` write for the crash records of acknowledged
    /// items; a failure keeps them for a retry after the next save (and
    /// startup reconciliation finds the typed evidence regardless).
    private func markRoundDeliveryRecords(_ jobs: Set<UUID>) {
        guard !jobs.isEmpty, FileManager.default.fileExists(atPath: DetachedJobStore.fileURL.path) else {
            roundDeliveryRecordRetries.subtract(jobs); return
        }
        do {
            try DetachedJobStore.mutate("delivered-midturn") { records in
                for i in records.indices where jobs.contains(records[i].jobId) && records[i].completion == .owed {
                    records[i].completion = .delivered
                    records[i].deliveredAt = Date()
                }
                records.removeAll { $0.isSettled }
            }
            roundDeliveryRecordRetries.subtract(jobs)
        } catch {
            roundDeliveryRecordRetries.formUnion(jobs)
            print("[ConversationManager] Could not mark mid-turn deliveries in crash records (retried after the next save): \(error.localizedDescription)")
        }
    }

    /// Run teardown (v3 §2.5): each reserved item of `runId` is resolved
    /// against saved history; one still carried by unsaved history or an
    /// in-memory checkpoint stays reserved (a later save resolves it, a
    /// restart finds the recovery evidence); every other one is released,
    /// so idle delivery delivers it (at-least-once). Never touches a newer
    /// run's reservations.
    func releaseRoundDeliveryReservations(ofRun runId: UUID) {
        turnSalvageWriteFailedRuns.remove(runId)
        guard roundDeliveryReservations.values.contains(where: { $0.runId == runId && $0.state == .reserved }) else { return }
        resolveRoundDeliveries()
        let mine = roundDeliveryReservations.values.filter { $0.runId == runId && $0.state == .reserved }
        guard !mine.isEmpty else { return }
        var roots = messages
        var checkpoints = Array(activeTurnCheckpoints.values)
        // The recovery file (a pendingRecovery checkpoint or plain rounds)
        // is published by startup/next-turn recovery: still a carrier.
        if let data = try? TurnCheckpointStore.read(turnSalvageFileURL) {
            if let checkpoint = try? JSONDecoder().decode(TurnCheckpoint.self, from: data) { checkpoints.append(checkpoint) }
            else if let rounds = try? JSONDecoder().decode([ToolInteraction].self, from: data) {
                roots.append(Message(role: .assistant, content: "", toolInteractions: rounds))
            }
        }
        for checkpoint in checkpoints {
            var carrier = Message(role: .assistant, content: "", toolInteractions: checkpoint.retainedInteractions)
            carrier.activeTurnCompaction = checkpoint.activeTurnCompaction
            if let ref = checkpoint.overflowReference { carrier.pruneArchiveReferences = [ref] }
            roots.append(carrier)
        }
        let carried = roundDeliveryCarried(Set(mine.map(\.messageId)), in: roots, anchors: mine.map(\.anchor)).found
        for reservation in mine where !carried.contains(reservation.messageId) {
            roundDeliveryReservations.removeValue(forKey: reservation.messageId)
            print("[ConversationManager] Mid-turn background result \(reservation.messageId) not saved with its round; left for idle delivery")
        }
    }

    // Selftest seams (round delivery).
    var _testRoundReservations: [UUID: RoundDeliveryReservation] { roundDeliveryReservations }
    var _testRoundDeliveredIds: Set<UUID> { roundDeliveredIds }
    var _testRoundRecordRetries: Set<UUID> { roundDeliveryRecordRetries }
    var _testSalvageWriteFailedRuns: Set<UUID> { turnSalvageWriteFailedRuns }
    var _testActiveRunId: UUID? { activeRunId }
    var _testSalvageRefusals: Int { salvageWritesRefusedForOwnership }
    func _testSetRecoveryBlocked(_ on: Bool) { recoveryBlocked = on }
    func _testSetHeldQueueProblem(_ reason: String?) { heldQueueFileProblem = reason }
    func _testCompactLogLabel(_ result: ToolResultMessage) -> String { summarizeToolOutcome(result) }
    func _testSetCheckpointReceipts(_ receipts: [BashCompletionReceipt]) {
        if let run = activeRunId { activeTurnCheckpoints[run]?.completionReceipts = receipts }
    }
}
