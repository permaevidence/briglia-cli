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
    
    // MARK: - Background archiving (BACKGROUND_ARCHIVE_PLAN v3)

    /// The archive job body, identical in both modes (the code that used to
    /// live inline in the detached task): the pinned chunk-archive snapshot
    /// when detail is present, up to three attempts with 5 s / 10 s backoff,
    /// the deterministic break and the same give-up alert.
    nonisolated static func runArchiveJobBody(messagesToArchive: [Message],
                                              summarizationContext: ConversationArchiveService.SummarizationContext,
                                              snapshotSource: [Message],
                                              archiveSvc: ConversationArchiveService,
                                              notifyStatus: Bool) async -> (Bool, PruneArchiveReference?) {
        var lastError: Error? = nil
        let receipt: PruneArchiveReference?
        do {
            receipt = PruneArchiveStore.needsSnapshot(messagesToArchive)
                ? try PruneArchiveStore.write(messages: snapshotSource, trigger: "chunk-archive", removedIDs: messagesToArchive.map(\.id), pin: true) : nil
        } catch {
            await MaintenanceAlertCenter.shared.reportFailure(.conversationSummary, error: error.localizedDescription, deterministic: true)
            return (false, nil)
        }
        for attempt in 1...3 {
            do {
                _ = try await archiveSvc.archiveMessages(messagesToArchive, context: summarizationContext, snapshot: receipt,
                                                          notifyStatus: notifyStatus)
                print("[ConversationManager] Archived \(messagesToArchive.count) messages successfully")
                return (true, receipt)
            } catch {
                lastError = error
                print("[ConversationManager] Archive failed (attempt \(attempt)): \(error)")
                if ArchiveError.isDeterministicFailure(error) { break }
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(5 * attempt) * 1_000_000_000)
                }
            }
        }
        await MaintenanceAlertCenter.shared.reportFailure(
            .conversationSummary,
            error: lastError.map { $0.localizedDescription } ?? "unknown error",
            deterministic: lastError.map { ArchiveError.isDeterministicFailure($0) } ?? false
        )
        return (false, receipt)
    }

    /// Why no archive may start now (nil: it may). One job at a time; no
    /// new batch while published rows still overlap live messages (they
    /// would select an overlapping or superset batch) or while /restart or
    /// /upgrade is on its way out. Background mode also waits for startup
    /// recovery, which holds the chunk writer for its whole pass.
    func archiveStartRefusal(view: ArchivePromptView) -> String? {
        // BGPRUNE{ A-ARCR
        if backgroundPruneEngaged {
            if archiveInlineEnabled, backgroundPruneJob != nil {
                return "background prune running"
            }
        }
        // }BGPRUNE
        if archiveJob != nil { return "an archive job is still running or awaiting its commit" }
        if archiveExitPending { return "a restart or upgrade is in progress" }
        if view.hasHiddenRows { return "archived rows still await their commit" }
        if !archiveInlineEnabled, archiveRecoveryTask != nil { return "startup archive recovery is still running" }
        return nil
    }

    /// Starts the background job: registered with its activity BEFORE the
    /// first suspension; the activity ends only after the outcome is
    /// installed. No 🧠 notice (owner decision D1), and none from the
    /// consolidation it runs either (quiet background notices, 0.2.63: the
    /// job passes `notifyStatus: false`); /status shows it.
    func startBackgroundArchiveJob(batch: [Message],
                                           summarizationContext: ConversationArchiveService.SummarizationContext,
                                           snapshotSource: [Message], view: ArchivePromptView) async {
        let id = UUID()
        let generation = archiveGeneration
        let activityId = beginMaintenance(.summarizingHistory)
        archiveJob = ArchiveJob(id: id, batch: batch, generation: generation, startedAt: Date(), frozenView: view)
        let archiveSvc = archiveService
        // The job owns its own reference on the frozen view's lease (the
        // turn's reference keeps it alive across this await).
        await archiveSvc.retainLease(view.leaseId)
        guard archiveJob?.id == id else { endMaintenance(activityId); return }
        archiveJob?.task = Task.detached { [weak self] in
            if let hold = Self.backgroundArchiveHoldForTesting { await hold() }
            let (archived, receipt) = await Self.runArchiveJobBody(
                messagesToArchive: batch, summarizationContext: summarizationContext,
                snapshotSource: snapshotSource, archiveSvc: archiveSvc, notifyStatus: false)
            if archived { await MaintenanceAlertCenter.shared.reportSuccess(.conversationSummary) }
            await MainActor.run {
                guard let self else { PruneArchiveStore.release(receipt); return }
                self.installArchiveOutcome(jobId: id, archived: archived, receipt: receipt)
                self.endMaintenance(activityId)
            }
        }
    }

    private func installArchiveOutcome(jobId: UUID, archived: Bool, receipt: PruneArchiveReference?) {
        guard var job = archiveJob, job.id == jobId, job.generation == archiveGeneration else {
            // Discarded meanwhile (wipe / import): nothing of it may land.
            PruneArchiveStore.release(receipt)
            if let stale = archiveJob, stale.id == jobId {
                archiveJob = nil
                let lease = stale.frozenView.leaseId
                Task { await archiveService.releaseLease(lease) }
            }
            return
        }
        job.receipt = receipt
        job.outcome = archived ? .succeeded : .failed(Date())
        job.task = nil
        archiveJob = job
        print("[ConversationManager] Background archive \(archived ? "finished — committing at the next turn" : "gave up — raw messages stay; cooldown from now")")
    }

    /// Drops the job: its snapshot pin and its own lease reference.
    private func disposeArchiveJob() async {
        guard let job = archiveJob else { return }
        archiveJob = nil
        PruneArchiveStore.release(job.receipt)
        await archiveService.releaseLease(job.frozenView.leaseId)
    }

    /// Wipe / Mind import (§9): invalidate the job of the replaced history.
    /// A running job cannot exist here (those commands refuse while its
    /// activity is listed); a finished one is discarded before any commit.
    func invalidateArchiveJobForReplacedHistory() async {
        archiveGeneration &+= 1
        if let job = archiveJob, job.outcome != .running {
            archiveJob = nil
            PruneArchiveStore.release(job.receipt)
        }
        turnViewLeaseId = nil
        lastTurnArchiveView = nil
        await archiveService.releaseAllLeases()
        // A commit failure of the replaced history is moot; the imported
        // state's own overlap (if any) re-opens it at the next turn.
        await MaintenanceAlertCenter.shared.discardEpisode(.archiveCommit)
    }

    /// §4.3: the view this turn uses. Registers the new lease before
    /// releasing the previous turn's.
    func adoptTurnArchiveView() async -> ArchivePromptView {
        let previous = turnViewLeaseId
        var view: ArchivePromptView
        if let job = archiveJob, job.generation == archiveGeneration,
           await archiveService.retainLease(job.frozenView.leaseId) {
            view = job.frozenView
        } else {
            view = await captureFreshArchiveView()
        }
        turnViewLeaseId = view.leaseId
        lastTurnArchiveView = view
        await archiveService.releaseLease(previous)
        await archiveService.setMainTurnVisibleChunkIds(view.visibleChunkIds)
        return view
    }

    /// Diagnostics (§4.6): the adopted turn view, else a read-only one.
    func diagnosticArchiveView() async -> ArchivePromptView {
        if let lastTurnArchiveView { return lastTurnArchiveView }
        return await archiveService.readOnlyPromptView(recentConsolidatedCount: 5, liveIDs: Set(messages.map(\.id)))
    }

    /// A fresh view, adopted only if the generation and the live id set
    /// did not change across its await (the meta refresh may call the
    /// model); otherwise released and captured again.
    func captureFreshArchiveView() async -> ArchivePromptView {
        var attempt = 0
        while true {
            attempt += 1
            let generation = archiveGeneration
            let liveIDs = messages.map(\.id)
            let view = await archiveService.promptView(recentConsolidatedCount: 5, liveIDs: Set(liveIDs))
            Self.viewCaptureHookForTesting?(self)
            if (generation == archiveGeneration && messages.map(\.id) == liveIDs) || attempt >= 5 { return view }
            await archiveService.releaseLease(view.leaseId)
        }
    }

    /// Inline mode after a successful archive: today's refresh, as a view
    /// of the now-shorter conversation (no overlap → today's items).
    func refreshTurnArchiveViewAfterInlineArchive() async -> ArchivePromptView {
        let previous = turnViewLeaseId
        let view = await captureFreshArchiveView()
        turnViewLeaseId = view.leaseId
        lastTurnArchiveView = view
        await archiveService.releaseLease(previous)
        await archiveService.setMainTurnVisibleChunkIds(view.visibleChunkIds)
        return view
    }

    /// §3 commit: the first step of every turn. A running job: nothing.
    /// A failed job: cooldown from its completion, job dropped. A finished
    /// job, or (no job) published chunks whose messages are still the
    /// oldest live ones after a restart: checked reconciliation, then
    /// removal. Never calls the model.
    func commitArchiveIfReady() async {
        guard !isRestoringMind else { return }
        // BGPRUNE{ A-ARCC
        if backgroundPruneEngaged {
            if backgroundPruneJob != nil {
                print("[ConversationManager] Archive removal deferred: a background prune is in progress")
                return
            }
        }
        // }BGPRUNE
        if let job = archiveJob {
            guard job.generation == archiveGeneration else { await disposeArchiveJob(); return }
            switch job.outcome {
            case .running:
                return
            case .failed(let at):
                archiveRetryBackoffUntil = at.addingTimeInterval(600)
                print("[ConversationManager] Background archive gave up — next attempt after \(archiveRetryBackoffUntil)")
                await disposeArchiveJob()
            case .succeeded:
                let step = await commitArchivedPart(ids: job.batch.map(\.id), baseline: .batchStart(job.batch),
                                                    receipt: job.receipt, generation: job.generation)
                guard step == .committed else { return }
                await disposeArchiveJob()
                await MaintenanceAlertCenter.shared.reportSuccess(.archiveCommit)
            }
            return
        }
        // Restart (§6.5): the contiguous oldest prefix covered by published
        // chunks, never across a gap, one covering chunk's part at a time.
        let owners = await archiveService.coveringChunkIds(for: messages.map(\.id))
        guard !owners.isEmpty else { return }
        var parts: [(chunk: UUID, ids: [UUID])] = []
        for message in messages {
            guard let chunk = owners[message.id] else { break }
            if parts.last?.chunk == chunk { parts[parts.count - 1].ids.append(message.id) }
            else { parts.append((chunk, [message.id])) }
        }
        guard !parts.isEmpty else { return }
        let generation = archiveGeneration
        for part in parts {
            let step = await commitArchivedPart(ids: part.ids, baseline: .archivedRaw, receipt: nil, generation: generation)
            guard step == .committed else { return }
        }
        // Only when every part is settled: an unresolved remainder keeps
        // its alert open.
        await MaintenanceAlertCenter.shared.reportSuccess(.archiveCommit)
    }

    /// One covering part: checked reconciliation (always, even for equal
    /// bytes), then — after re-reading the exact live versions — removal.
    private func commitArchivedPart(ids: [UUID], baseline: ArchiveCommitBaseline,
                                    receipt: PruneArchiveReference?, generation: UInt64) async -> ArchiveCommitStep {
        let wanted = Set(ids)
        let live = messages.filter { wanted.contains($0.id) }
        guard !live.isEmpty else { return .committed }   // already settled
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let liveBytes = try? encoder.encode(live) else { return .deferred }
        let owner = activeRunId
        let result: ArchiveReconcileResult
        do {
            result = try await archiveService.reconcileCommittedBatch(live: live, baseline: baseline, jobReceipt: receipt)
        } catch {
            print("[ConversationManager] Archive commit refused: \(error.localizedDescription)")
            await MaintenanceAlertCenter.shared.reportFailure(.archiveCommit, error: error.localizedDescription, deterministic: false)
            return .failed
        }
        guard result == .reconciled else {
            print("[ConversationManager] Archive commit deferred: the archive writer is busy")
            return .deferred
        }
        // Revalidate after every await (§6.4).
        guard generation == archiveGeneration, !isRestoringMind, activeRunId == owner else { return .deferred }
        let now = messages.filter { wanted.contains($0.id) }
        guard let nowBytes = try? encoder.encode(now), nowBytes == liveBytes else {
            // Changed in between (a prune): reconcile again next turn.
            return .deferred
        }
        do { try settleJobEvidenceBeforeRemoval(of: now) } catch {
            print("[ConversationManager] Archive commit postponed — crash-record evidence not settled: \(error.localizedDescription)")
            return .deferred
        }
        let candidate = messages.filter { !wanted.contains($0.id) }
        do {
            try writeHistoryFile(try encoder.encode(candidate))
        } catch {
            await MaintenanceAlertCenter.shared.reportFailure(.archiveCommit,
                error: "could not save the conversation without the archived messages: \(error.localizedDescription)", deterministic: false)
            return .failed
        }
        messages = candidate
        committedMessages = candidate
        lastPromptTokens = nil
        lastCompletionTokens = nil
        cleanupOrphanedToolAttachmentSnapshots()
        do { try PruneArchiveStore.retainLatest() }
        catch { showMaintenanceNotice("Snapshot retention: \(error.localizedDescription)") }
        print("[ConversationManager] Committed archived batch: removed \(now.count) message(s)")
        return .committed
    }

    /// /status line (§10).
    func archiveModeStatusLine() async -> String {
        var line = "🧠 Memory archiving: " + (archiveInlineEnabled ? "waits before replying" : "in the background")
        if let job = archiveJob, job.generation == archiveGeneration {
            line += job.outcome == .running ? " (a background archive is still finishing)"
                : job.outcome == .succeeded ? " (archived messages waiting to be removed)" : ""
        } else if !(await archiveService.coveringChunkIds(for: messages.map(\.id))).isEmpty {
            line += " (archived messages waiting to be removed)"
        }
        return line
    }

    /// `/archiveinline on|off` (§10): persisted, default off. Affects the
    /// next job only; a job already running stays in the background.
    func handleArchiveInlineCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let enabled = archiveInlineEnabled
        let normalized = argument.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            try? await sendText("""
                Memory archiving waits before replying: \(enabled ? "ON" : "OFF") (default: off).
                Off: when the conversation gets long, its oldest part is summarized in the background while I keep working; the summary replaces those messages at the start of a later message.
                On: I wait for the summary before replying (for local servers that can't run two requests at once). Switch with /archiveinline on or /archiveinline off.
                """)
            return
        }
        guard normalized == "on" || normalized == "off" else {
            try? await sendText("Usage: /archiveinline on|off (currently \(enabled ? "on" : "off")).")
            return
        }
        let target = normalized == "on"
        guard target != enabled else {
            try? await sendText("Memory archiving already \(target ? "waits before replying" : "runs in the background").")
            return
        }
        switchDefaults.set(target, forKey: Self.archiveInlineDefaultsKey)
        let running = archiveJob?.outcome == .running ? " An archive already running in the background finishes there." : ""
        try? await sendText(target
            ? "✅ Memory archiving now waits before replying, from the next archive.\(running)"
            : "✅ Memory archiving now runs in the background, from the next archive.")
    }

    /// `/keepsummaries [N|all]` (KEEP_SUMMARIES_PLAN §9): how many past-turn
    /// summaries the model sees in full. Applies from the next request; never
    /// touches persisted bytes or running jobs. No idle guard.
    func handleKeepSummariesCommand(argument: String) async {
        guard replyAddress != nil else { return }
        try? await sendText(keepSummariesReply(argument: argument))
    }

    /// The reply (and the setting change) for one `/keepsummaries` command.
    func keepSummariesReply(argument: String) -> String {
        let current = KeepSummariesSetting.current()
        let text = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Legacy pointers the one-time restore could not prove exact can
        // only ever be shown as pointers, whatever the setting.
        let legacy = messages.reduce(0) { $0 + $1.demotedPruneSummaries.count }
        let legacyNote = legacy > 0
            ? "\nNote: \(legacy) older summar\(legacy == 1 ? "y" : "ies") can only be shown as a pointer (the full text is in its snapshot)."
            : ""
        if text.isEmpty {
            return """
                Past-turn summaries kept in full: \(current) (default: 3).
                Older ones are shown as a one-line pointer to a snapshot with the full text; nothing is deleted.
                Change it with /keepsummaries <1–50> or /keepsummaries all; /keepsummaries 3 returns to the default.
                \(Self.keepSummariesCostLine)
                """ + legacyNote
        }
        guard let target = KeepSummariesSetting.parseArgument(text) else {
            return "Usage: /keepsummaries [1–50|all] (currently \(current); default 3)."
        }
        // The default always removes the key, before any "already" reply.
        if target == .defaultValue { KeepSummariesSetting.store(target) }
        guard target != current else {
            return "Past-turn summaries kept in full: already \(target) (default: 3)."
        }
        KeepSummariesSetting.store(target)
        return "✅ Past-turn summaries kept in full: \(target) (default is 3; send /keepsummaries 3 to return to it). Applies from the next request; full texts are kept either way, so you can change it back at any time." + legacyNote
    }

    // MARK: - Summarization Context Builder
    
    /// Build full context for summarization so the LLM can properly understand
    /// relationships, references, and meaning in the chunk being archived.
    /// Note: Calendar is deliberately excluded - it contains future events not relevant to historical summarization.
    func buildSummarizationContext(
        chunkSummaries: [ArchivedSummaryItem],
        currentMessages: [Message]
    ) -> ConversationArchiveService.SummarizationContext {
        // Get persona settings
        let personaContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey)
        let assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey)
        let userName = KeychainHelper.load(key: KeychainHelper.userNameKey)
        
        // Format previous summaries chronologically
        let previousSummaries = chunkSummaries.filter { $0.kind != .liveOverlapDisclosure }
            .sorted { $0.startDate < $1.startDate }.map { $0.summary }
        
        // Preserve only the immediate continuation after the archived chunk.
        // It is appended after the source segment in archive prompts, so it can
        // clarify dangling references without becoming part of the reusable
        // prefix or dumping unrelated future conversation into summarization.
        let recentMessages = currentMessages.prefix(2)
        let currentContext: String?
        if !recentMessages.isEmpty {
            currentContext = recentMessages.map { msg in
                let role = msg.role == .user ? "User" : "Assistant"
                return "[\(role)]: \(msg.content.prefix(500))"
            }.joined(separator: "\n")
        } else {
            currentContext = nil
        }
        
        return ConversationArchiveService.SummarizationContext(
            personaContext: personaContext,
            assistantName: assistantName,
            userName: userName,
            previousSummaries: previousSummaries,
            currentConversationContext: currentContext
        )
    }
    
    // MARK: - File Description Helpers
    
    /// Generate file descriptions at the exact pruning event that removes the
    /// original bytes from prompt replay. Context is anchored to the file's own
    /// turn: up to 8 previous messages plus the file-bearing message itself, and
    /// never later conversation.
    func generateDescriptionsBeforePruning(
        messageIndex: Int,
        includeInlineMedia: Bool,
        includeToolAttachments: Bool,
        sourceMessages: [Message]
    ) async {
        guard sourceMessages.indices.contains(messageIndex) else { return }

        let message = sourceMessages[messageIndex]
        var files: [(filename: String, data: Data, mimeType: String)] = []

        if includeInlineMedia {
            files.append(contentsOf: collectInlineMediaFilesForDescription(from: message))
        }
        if includeToolAttachments {
            files.append(contentsOf: collectToolAttachmentFilesForDescription(from: message))
        }

        files = await filesWithoutStoredDescriptions(files)
        guard !files.isEmpty else { return }

        // ── Per-file limits: skip oversized files, cap PDF pages ──
        var cappedFiles: [(filename: String, data: Data, mimeType: String)] = []
        var fallbackDescriptions: [String: String] = [:]

        for file in files {
            if file.data.count > Self.descriptionMaxFileSizeBytes {
                fallbackDescriptions[file.filename] = "Large file (\(file.data.count / 1024)KB)"
                print("[ConversationManager] Skipping \(file.filename) for description: \(file.data.count) bytes exceeds \(Self.descriptionMaxFileSizeBytes) limit")
                continue
            }
            if file.mimeType.lowercased() == "application/pdf",
               let doc = AdaPDF(data: file.data),
               doc.pageCount > Self.descriptionMaxPDFPages {
                if let slicedData = doc.sliceData(pages: 1...Self.descriptionMaxPDFPages) {
                    cappedFiles.append((filename: file.filename, data: slicedData, mimeType: file.mimeType))
                    print("[ConversationManager] Capped \(file.filename) from \(doc.pageCount) to \(Self.descriptionMaxPDFPages) pages for description")
                } else {
                    fallbackDescriptions[file.filename] = "PDF document (\(doc.pageCount) pages)"
                }
            } else {
                cappedFiles.append(file)
            }
        }

        // ── Batch limit: cap total files per API call ──
        if cappedFiles.count > Self.descriptionMaxFiles {
            for file in cappedFiles[Self.descriptionMaxFiles...] {
                fallbackDescriptions[file.filename] = "File skipped (batch limit of \(Self.descriptionMaxFiles) reached)"
            }
            cappedFiles = Array(cappedFiles.prefix(Self.descriptionMaxFiles))
        }

        if !fallbackDescriptions.isEmpty {
            await FileDescriptionService.shared.saveMultiple(fallbackDescriptions)
        }

        guard !cappedFiles.isEmpty else { return }

        let context = descriptionContextMessages(
            forMessageAt: messageIndex,
            in: sourceMessages,
            previousLimit: 8
        )

        do {
            let descriptions = try await openRouterService.generateFileDescriptions(
                files: cappedFiles,
                conversationContext: context
            )
            await FileDescriptionService.shared.saveMultiple(descriptions)
        } catch {
            print("[ConversationManager] Failed to generate prune-time file descriptions: \(error)")
        }
    }

    func descriptionContextMessages(
        forMessageAt index: Int,
        in sourceMessages: [Message],
        previousLimit: Int
    ) -> [Message] {
        guard sourceMessages.indices.contains(index) else { return [] }
        let start = max(0, index - previousLimit)
        return Array(sourceMessages[start...index])
    }

    private func filesWithoutStoredDescriptions(
        _ files: [(filename: String, data: Data, mimeType: String)]
    ) async -> [(filename: String, data: Data, mimeType: String)] {
        var seen = Set<String>()
        var filtered: [(filename: String, data: Data, mimeType: String)] = []

        for file in files {
            guard seen.insert(file.filename).inserted else { continue }
            if await FileDescriptionService.shared.get(filename: file.filename) == nil {
                filtered.append(file)
            }
        }

        return filtered
    }

    /// Collect inline user/referenced media from a message for description generation.
    func collectInlineMediaFilesForDescription(from message: Message) -> [(filename: String, data: Data, mimeType: String)] {
        var files: [(filename: String, data: Data, mimeType: String)] = []
        
        for imageFileName in message.imageFileNames + message.referencedImageFileNames {
            let imageURL = imagesDirectory.appendingPathComponent(imageFileName)
            if let imageData = try? Data(contentsOf: imageURL) {
                files.append((filename: imageFileName, data: imageData, mimeType: mimeTypeForAttachmentFile(imageFileName)))
            }
        }
        
        for documentFileName in message.documentFileNames + message.referencedDocumentFileNames {
            let documentURL = documentsDirectory.appendingPathComponent(documentFileName)
            if let documentData = try? Data(contentsOf: documentURL) {
                files.append((filename: documentFileName, data: documentData, mimeType: mimeTypeForAttachmentFile(documentFileName)))
            }
        }
        
        return files
    }

    func collectToolAttachmentFilesForDescription(from message: Message) -> [(filename: String, data: Data, mimeType: String)] {
        var files: [(filename: String, data: Data, mimeType: String)] = []

        for interaction in message.toolInteractions {
            let toolNames = Set(interaction.assistantMessage.toolCalls.map { $0.function.name })
            guard !toolNames.isDisjoint(with: Self.describableToolNames) else { continue }

            // Map toolCallId → tool name so we only collect attachments from allowed tools
            let callIdToName = Dictionary(
                interaction.assistantMessage.toolCalls.map { ($0.id, $0.function.name) },
                uniquingKeysWith: { first, _ in first }
            )

            // Collect FileAttachmentReferences only from allowed tool results
            for result in interaction.results {
                guard let name = callIdToName[result.toolCallId],
                      Self.describableToolNames.contains(name) else { continue }
                for reference in result.fileAttachmentReferences {
                    guard let data = dataForAttachmentReference(reference) else { continue }
                    files.append((filename: reference.filename, data: data, mimeType: reference.mimeType))
                }
            }

            // send_document_to_chat doesn't produce FileAttachmentReferences —
            // extract the filename from the tool arguments and load from disk.
            for call in interaction.assistantMessage.toolCalls where call.function.name == "send_document_to_chat" {
                guard let argsData = call.function.arguments.data(using: .utf8),
                      let args = try? JSONDecoder().decode(SendDocumentToChatArguments.self, from: argsData) else { continue }
                let url = URL(fileURLWithPath: args.filePath)
                guard let data = try? Data(contentsOf: url) else { continue }
                let filename = url.lastPathComponent
                files.append((filename: filename, data: data, mimeType: mimeTypeForAttachmentFile(filename)))
            }
        }

        return files
    }

    private func dataForAttachmentReference(_ reference: FileAttachmentReference) -> Data? {
        guard let url = reference.resolvedURL(
            imagesDirectory: imagesDirectory,
            documentsDirectory: documentsDirectory
        ) else {
            return nil
        }

        if let snapshotPath = reference.snapshotPath, url.path == snapshotPath {
            return try? Data(contentsOf: url)
        }

        guard normalizedMimeType(reference.mimeType) == "application/pdf",
              let pageRange = reference.pageRange,
              let doc = AdaPDF(url: url),
              let requestedRange = parsePersistedPageRange(pageRange, totalPages: doc.pageCount) else {
            return try? Data(contentsOf: url)
        }

        return doc.sliceData(pages: requestedRange)
    }

    private func parsePersistedPageRange(_ raw: String, totalPages: Int) -> ClosedRange<Int>? {
        let parts = raw.split(separator: "-", maxSplits: 1)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.count == 1, let page = Int(parts[0]), page >= 1, page <= totalPages {
            return page...page
        }
        guard parts.count == 2,
              let lower = Int(parts[0]),
              let upper = Int(parts[1]),
              lower >= 1,
              upper >= lower,
              upper <= totalPages else {
            return nil
        }
        return lower...upper
    }

    private func mimeTypeForAttachmentFile(_ fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "xml": return "application/xml"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "zip": return "application/zip"
        default: return FilesystemTools.mimeType(forPath: fileName)
        }
    }
}
