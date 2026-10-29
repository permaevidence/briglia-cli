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
    
    // MARK: - Configuration
    
    func configure() async {
        // Seed provider profiles from pre-profile runtime slots (idempotent)
        // so /provider works immediately after an upgrade.
        ProviderProfiles.ensureMigrated()
        // Per-model OpenRouter hosts (v0.2.56): non-blocking; a busy store
        // just defers it (every pin/model mutation migrates first anyway).
        OpenRouterPinMap.ensureMigrated()
        let currentLLMProvider = LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey))
        // No messaging channel is required: the app's own chat window is
        // always a valid transport. Telegram remains the optional remote
        // for using the agent away from this machine.
        let apiKey = (KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch currentLLMProvider {
        case .openRouter:
            guard !apiKey.isEmpty else {
                error = "Please configure your OpenRouter API key"
                return
            }
        case .lmStudio:
            let model = (KeychainHelper.load(key: KeychainHelper.lmStudioModelKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                error = "Please configure your local model name"
                return
            }
        case .openAICompatible:
            let baseURL = (KeychainHelper.load(key: KeychainHelper.openAICompatibleBaseURLKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (KeychainHelper.load(key: KeychainHelper.openAICompatibleModelKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let compatibleKey = (KeychainHelper.load(key: KeychainHelper.openAICompatibleApiKeyKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseURL.isEmpty else {
                error = "Please configure your OpenAI-compatible endpoint URL"
                return
            }
            guard !model.isEmpty else {
                error = "Please configure your OpenAI-compatible model name"
                return
            }
            guard !compatibleKey.isEmpty else {
                error = "Please configure your OpenAI-compatible API key"
                return
            }
        }
        // Get optional web search keys
        let serperKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        let jinaKey = KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) ?? ""

        await updateTelegramChannelRegistration()

        // The in-app chat window is always routable. Text replies are no-ops
        // (history is the UI); media the agent explicitly sends is persisted
        // and appended to history so it shows in the window.
        channels[.app] = AppLocalChannel(
            onPhoto: { [weak self] data, caption, mimeType in
                await self?.appendAppChannelPhoto(data: data, caption: caption, mimeType: mimeType)
            },
            onDocument: { [weak self] data, filename, caption, _ in
                await self?.appendAppChannelDocument(data: data, filename: filename, caption: caption)
            }
        )

        await openRouterService.configure(apiKey: apiKey)
        
        // Configure tool executor if web search keys are available
        if !serperKey.isEmpty {
            await toolExecutor.configure(openRouterKey: apiKey, serperKey: serperKey, jinaKey: jinaKey)
        }

        // Explicit archive reads use THIS archive service (live index,
        // retained children) — background archiving §4.4.
        await toolExecutor.setArchiveService(archiveService)

        // Wire the Agent (subagent) tool so it can drive its own LLM loop.
        await toolExecutor.configureOpenRouter(
            openRouterService,
            imagesDirectory: imagesDirectory,
            documentsDirectory: documentsDirectory
        )

        // Pin watcher-bound triage sessions against LRU eviction before any
        // session churn can happen this process lifetime.
        await ReminderService.shared.publishPinnedSessions()
        
        // Configure archive service. Pending recovery can call the model and must
        // not block startup; otherwise a stale archive failure prevents listening.
        await archiveService.configure(apiKey: apiKey)
        let recoveryChunkSummaries = await archiveService.getPromptSummaryItems(recentConsolidatedCount: 5)
        let recoveryContext = buildSummarizationContext(
            chunkSummaries: recoveryChunkSummaries,
            currentMessages: messages
        )
        scheduleArchiveRecovery(defaultContext: recoveryContext)
        
        // Ambient inbox + calendar awareness, routed by the email/calendar
        // provider setting: gws (user's Gmail via the CLI), agentmail
        // (dedicated agent inbox via REST), or none (no polling, no context).
        // Both services retry + fail gracefully when unconfigured, so startup
        // never blocks on them.
        await startEmailProvider()
        
        // Configure Gemini image service if API key is available
        if let geminiApiKey = KeychainHelper.load(key: KeychainHelper.geminiApiKeyKey), !geminiApiKey.isEmpty {
            await GeminiImageService.shared.configure(
                apiKey: geminiApiKey,
                model: configuredGeminiImageModel(),
                pricing: configuredGeminiImagePricing()
            )
        }
        if let openAIImageApiKey = KeychainHelper.load(key: KeychainHelper.openAIImageApiKeyKey), !openAIImageApiKey.isEmpty {
            await OpenAIImageService.shared.configure(
                apiKey: openAIImageApiKey,
                model: KeychainHelper.load(key: KeychainHelper.openAIImageModelKey),
                preciseModel: KeychainHelper.load(key: KeychainHelper.openAIImagePreciseModelKey),
                quality: KeychainHelper.load(key: KeychainHelper.openAIImageQualityKey),
                outputFormat: KeychainHelper.load(key: KeychainHelper.openAIImageOutputFormatKey),
                moderation: KeychainHelper.load(key: KeychainHelper.openAIImageModerationKey)
            )
        }
        
        error = nil
    }

    func scheduleArchiveRecovery(defaultContext: ConversationArchiveService.SummarizationContext) {
        guard archiveRecoveryTask == nil else { return }
        // The intake stop (owner decision 2026-10-29): no producer starts
        // while a wipe / Mind import holds the restore gate. The context
        // built now may describe the history about to be replaced, so it is
        // rebuilt when the gate drops (endMindRestore). Never-multi installs
        // are unchanged.
        if isRestoringMind && Self.multiAssistantGateApplies {
            archiveRecoveryDeferredByRestoreGate = true
            return
        }
        let archiveService = self.archiveService
        Self.archiveRecoveriesScheduledForTesting += 1
        archiveRecoveryTask = Task { [weak self] in
            await archiveService.recoverPendingChunks(defaultContext: defaultContext)
            await MainActor.run {
                self?.archiveRecoveryTask = nil
                self?.scheduleSummaryRetentionIdlePass()
            }
        }
    }
    
    // MARK: - Polling Control
    
    /// Selftests: runs right after startup's configure(); counts how often
    /// startup recovery waited for the restore gate.
    nonisolated(unsafe) static var startupAfterConfigureForTesting: (() async -> Void)?
    nonisolated(unsafe) static var startupRecoveryWaitsForTesting = 0
    /// Selftests: how often a startup waited at the intake stop (before
    /// configure) for the restore gate.
    nonisolated(unsafe) static var startupHeldBeforeConfigureForTesting = 0
    /// Selftests: archive recovery tasks actually created.
    nonisolated(unsafe) static var archiveRecoveriesScheduledForTesting = 0

    func startPolling() async {
        // Prevent duplicate polling tasks. The flag must be claimed BEFORE
        // the configure() await: launch fires two near-simultaneous callers
        // (the resume-on-launch task and the terminal session), and a guard
        // checked before a suspension point let both through — two live poll
        // loops, every incoming message fetched and processed twice. (That
        // long-standing duplication was misattributed to the HTTP transport;
        // the doubled getUpdates timelines were the two loops in lockstep.)
        guard !isPolling, !isStartingPolling else {
            print("[ConversationManager] Polling already running, ignoring duplicate start")
            return
        }
        isStartingPolling = true
        defer { isStartingPolling = false }

        // The intake stop (owner decision 2026-10-29; Codex stage-3
        // S3-R12-1): with several assistants, a startup that begins while a
        // /deleteuserdata wipe or Mind import holds the restore gate does
        // NOTHING until the gate drops — no settings migration, no
        // configure() (archive recovery, email poller, pinned sessions), no
        // crash recovery. Held here it is not "starting up" for the wipe's
        // busy check. A startup already past this point when the gate rises
        // is counted as in progress and refuses the wipe.
        if isRestoringMind && Self.multiAssistantGateApplies {
            startupHeldByRestoreGate = true
            while isRestoringMind && Self.multiAssistantGateApplies {
                Self.startupHeldBeforeConfigureForTesting += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            startupHeldByRestoreGate = false
        }

        // gws / WhatsApp retirement (2026-10-24): settings and Briglia's own
        // leftovers, before configure() reads them; notices come later.
        applyRetiredIntegrationsMigration()

        await configure()
        if let hook = Self.startupAfterConfigureForTesting { await hook() }

        guard error == nil else { return }

        isPolling = true
        shouldResumePollingOnLaunch = true
        statusMessage = "Polling for messages..."
        // D10: the one-time preset host for the model in use at upgrade
        // (detached; never blocks startup or a turn).
        startUpgradePresetPass()
        // Update-available notice (security plan v8 §5): detached, one
        // signed-manifest check every 6 h, never installs anything.
        startUpdateNoticeService()
        startRetiredIntegrationsNotices()

        // Crash-recovery passes, in dependency order, before the first poll
        // tick: buffered attachments first (a recovered turn may reference
        // them), then mid-turn queue (already-acknowledged messages that
        // never reached history), then the active-turn marker (skipped when
        // the queue recovery just started a turn — the unanswered message is
        // part of that turn's context).
        // Several assistants (Codex stage-3 S3-R11-1): recovery below can
        // resume a turn; never while a /deleteuserdata wipe or Mind import
        // holds the restore gate (it ends with the operation). A startup
        // begun under the gate already waited at the top; this covers one
        // that was in configure() when the gate rose (the wipe refuses it as
        // "starting up"). Never-multi installs are unchanged.
        while isRestoringMind && Self.multiAssistantGateApplies {
            Self.startupRecoveryWaitsForTesting += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        restorePendingInboundBuffers()
        // Startup stop pass (§3.9.3) BEFORE queue recovery and turn resume:
        // messages held by an earlier /stop reach history without being
        // answered, and a stopped turn is never resumed.
        applyPersistedStopMarker()
        recoverPersistedMidTurnMessages()
        recoverPersistedAmbientTriggers()
        // Recovered crash-record notices that wake (§3.10.4) start their turn
        // here; a resume below then finds the run active and only clears
        // its marker (the unanswered trigger is in this turn's context).
        reconcileJobRecords()
        if let trigger = recoveredWakeTrigger, activeRunId == nil, activeProcessingTask == nil, !stopIntent.isUnknown {
            recoveredWakeTrigger = nil
            statusMessage = "Processing background task completion..."
            startActiveProcessing(for: trigger)
        }
        resumeInterruptedActiveTurnIfNeeded()
        
        // Warm up Whisper only when local transcription is active.
        if currentVoiceTranscriptionProvider() == .local {
            Task {
                await WhisperKitService.shared.checkModelStatus()
            }
        }
        
        pollingTask = Task {
            while !Task.isCancelled && isPolling {
                do {
                    // While a Mind restore replaces the on-disk state, take in
                    // nothing: a turn started now would finish holding the old
                    // conversation and save it over the restored files.
                    // Channel messages stay queued server-side and are picked
                    // up on the first tick after the restore completes.
                    // Parked for an update (§6.4): same top-of-loop idle, so a
                    // pause never splits a fetched batch.
                    if isRestoringMind || admissionPaused {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        continue
                    }

                    // Settings waits for a tick already suspended in a channel
                    // fetch to finish before it can change runtime credentials.
                    browserSettingsPollIngress += 1
                    defer { browserSettingsPollIngress -= 1 }

                    // Start deferred ambient turns (email arrivals that landed
                    // while a run was active) as soon as the agent is idle.
                    drainPendingAmbientTriggers()

                    // Check for due reminders first
                    await checkDueReminders()

                    // Surface harness-authored notices about newly created
                    // check-script reminders (the agent cannot suppress these).
                    // Notices are persisted and only removed after a confirmed
                    // send, so restarts and transient channel failures retry
                    // instead of losing the audit trail.
                    let creationNotices = await ReminderService.shared.pendingCreationNotices()
                    if !creationNotices.isEmpty {
                        var sentCount = 0
                        for notice in creationNotices {
                            do {
                                try await sendText(notice)
                                sentCount += 1
                            } catch {
                                break
                            }
                        }
                        if sentCount > 0 {
                            await ReminderService.shared.confirmCreationNoticesSent(count: sentCount)
                        }
                    }

                    // Nag the agent to clean the scratch dir if it's over threshold
                    await checkScratchDiskPressure()

                    // Check for completed background bash processes
                    await checkBackgroundBashCompletions()

                    // Retry pending tool charges and register the unknown
                    // spend of jobs lost in a restart (§3.6.3), before the
                    // completions they belong to are delivered.
                    settleToolCharges()

                    // Check for completed background subagents
                    await checkBackgroundSubagentCompletions()

                    // Check for pending bash_manage watch matches (mid-stream output triggers)
                    await checkBashWatchMatches()

                    if DebugTelemetry.shared.verbose {
                        DebugTelemetry.log(.pollTick, summary: "poll tick")
                    }

                    // Execute a confirmed /switchbot at this clean boundary:
                    // no getUpdates batch is in flight here, so every confirm
                    // for the OLD bot is already persisted under its own
                    // token hash before the swap.
                    await performPendingBotSwitchIfReady()

                    if isTelegramConfigured {
                        if let stalledId = stalledConfirmUpdateId {
                            // Durability stall: processed-but-unconfirmed
                            // updates exist and polling MUST pause — the
                            // offset of any getUpdates request is itself the
                            // acknowledgment, so one more fetch would confirm
                            // (and server-side delete) exactly the updates
                            // the skipped confirm was protecting. Retry the
                            // writes each tick; confirm and resume when they
                            // land. A crash while stalled re-delivers.
                            await retryDurabilityStall(stalledId)
                        } else {
                        let polled = try await telegramService.getUpdates()

                        // Confirm PER UPDATE, not per batch: each update is
                        // acknowledged (and the offset persisted) only after
                        // ITS processing put it into durable state — appended
                        // to conversation history or written to the persisted
                        // mid-turn queue. A batch-level confirm meant a crash
                        // (or /upgrade's exec-restart) after the first update
                        // of a batch permanently skipped the rest.
                        //
                        // Acknowledgment is also conditional on the durable
                        // writes succeeding: on a failed write the update —
                        // and the rest of the batch, since a higher confirm
                        // would implicitly cover it — stays unconfirmed and
                        // the loop enters the polling stall above. (The
                        // batch's remaining updates are still processed from
                        // memory; the stall id follows to the batch's end so
                        // the eventual confirm covers them all.)
                        var confirmBlocked = false
                        for item in polled {
                            inboundDurabilityFailure = false
                            if let update = item.update {
                                processingTelegramUpdateId = item.updateId
                                await processUpdate(update)
                                processingTelegramUpdateId = nil
                            }
                            if !persistPendingInboundBuffers() {
                                inboundDurabilityFailure = true
                            }
                            if inboundDurabilityFailure { confirmBlocked = true }
                            if confirmBlocked {
                                stalledConfirmUpdateId = item.updateId
                                print("[ConversationManager] NOT confirming update \(item.updateId) — a durable write failed; polling pauses until writes recover")
                            } else {
                                await telegramService.confirmProcessed(updateId: item.updateId)
                            }
                        }
                        }
                    }

                    statusMessage = "Listening... (Last check: \(formattedTime()))"

                    // A tick succeeded — end any polling-degraded episode and
                    // redeliver replies parked by earlier send failures. The
                    // first-tick sweep also closes episodes persisted by a
                    // previous process (the counter resets on restart, so the
                    // threshold check alone would never fire for them).
                    if consecutivePollFailures >= Self.pollFailureAlertThreshold || !staleChannelEpisodeSwept {
                        staleChannelEpisodeSwept = true
                        Task { await MaintenanceAlertCenter.shared.reportSuccess(.channelPolling) }
                    }
                    consecutivePollFailures = 0
                    lastLoggedPollError = nil
                    await flushParkedOutbound()

                    // Poll every 1 second
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    if !Task.isCancelled {
                        // Visible in the CLI terminal (statusMessage only
                        // reaches the app UI) — a silently failing poll loop
                        // is indistinguishable from a deaf agent. Deduped so
                        // a persistent failure prints once, not every 5s.
                        // Foreign (non-Telegram) errors could still render a
                        // request URL; scrub token shapes before printing.
                        let errText = TelegramBotService.redactBotTokens(in: "\(error)")
                        if errText != lastLoggedPollError {
                            lastLoggedPollError = errText
                            print("[ConversationManager] Poll tick failed: \(errText)")
                        }
                        statusMessage = "Error: \(error.localizedDescription)"
                        // Transient network errors self-heal and stay quiet, but a
                        // PERSISTENT failure (revoked bot token → 401 forever) used
                        // to be silent-forever: the status string lives only in the
                        // macOS UI, so a remote user just experienced a deaf agent.
                        // Alert once per threshold crossing; the alert center
                        // handles escalation and queues delivery if Telegram itself
                        // is the broken channel (flushes via another channel or
                        // once the network recovers).
                        consecutivePollFailures += 1
                        if consecutivePollFailures % Self.pollFailureAlertThreshold == 0 {
                            let errText = error.localizedDescription
                            let failures = consecutivePollFailures
                            Task {
                                await MaintenanceAlertCenter.shared.reportFailure(
                                    .channelPolling,
                                    error: "\(errText) (\(failures) consecutive failures)",
                                    deterministic: false
                                )
                            }
                        }
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds before retry
                    }
                }
            }
        }
    }
    
    func stopPolling() {
        activeProcessingTask?.cancel()
        let hasCheckpointOwner = activeRunId.flatMap { activeTurnCheckpoints[$0]?.isEnvelope } == true
        if !hasCheckpointOwner { activeProcessingTask = nil; activeRunId = nil }
        turnActivity = nil
        Task { await toolExecutor.cancelAllRunningProcesses() }
        ToolExecutor.clearPendingToolOutputs()
        
        isPolling = false
        shouldResumePollingOnLaunch = false
        pollingTask?.cancel()
        pollingTask = nil
        statusMessage = "Stopped"
    }

    var shouldResumePollingOnLaunch: Bool {
        get {
            if Prefs.store.object(forKey: shouldResumePollingDefaultsKey) == nil {
                return true
            }
            return Prefs.store.bool(forKey: shouldResumePollingDefaultsKey)
        }
        set {
            Prefs.store.set(newValue, forKey: shouldResumePollingDefaultsKey)
        }
    }

    func hasRequiredPollingConfiguration() -> Bool {
        func stored(_ key: String) -> String {
            (KeychainHelper.load(key: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let telegramReady = !stored(KeychainHelper.telegramBotTokenKey).isEmpty
            && !stored(KeychainHelper.telegramChatIdKey).isEmpty
        guard telegramReady else { return false }

        // The LLM credential requirement depends on the chosen provider —
        // local servers need no key, OpenAI-compatible has its own key.
        switch LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey)) {
        case .openRouter:
            return !stored(KeychainHelper.openRouterApiKeyKey).isEmpty
        case .openAICompatible:
            return !stored(KeychainHelper.openAICompatibleBaseURLKey).isEmpty
                && !stored(KeychainHelper.openAICompatibleModelKey).isEmpty
                && !stored(KeychainHelper.openAICompatibleApiKeyKey).isEmpty
        case .lmStudio:
            return !stored(KeychainHelper.lmStudioModelKey).isEmpty
        }
    }

    private func formatMegabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// Record an attachment the agent will never see on disk, so the next turn knows it existed.
    /// For attachments on the triggering message (not referenced ones), also notify the user
    /// immediately on Telegram — a captionless oversized file would otherwise fail in silence.
    private func noteUnavailableAttachment(name: String, detail: String, notifyUser: String? = nil) async {
        let note = "[Attachment '\(name)' could not be retrieved: \(detail) The file is NOT available on disk.]"
        pendingAttachmentNotes.append(note)
        print("[ConversationManager] \(note)")
        if let notice = notifyUser {
            try? await sendText(notice)
        }
    }

    private func noteOversizedAttachment(name: String, sizeBytes: Int, referenced: Bool) async {
        let size = formatMegabytes(sizeBytes)
        let detail = "it is \(size), and Telegram bots can only download files up to 20 MB. Ask the user to provide it another way (a shared link, a path on this machine, or a split archive)."
        let notice = referenced ? nil :
            "⚠️ '\(name)' is \(size) — Telegram only lets bots download files up to 20 MB, so it never reached me. Send a download link, a path on this machine, or a split archive instead."
        await noteUnavailableAttachment(name: name, detail: detail, notifyUser: notice)
    }

    private func noteFailedAttachmentDownload(name: String, error: Error, referenced: Bool) async {
        let detail = "the download failed (\(error.localizedDescription))."
        let notice = referenced ? nil :
            "⚠️ I couldn't download '\(name)' from Telegram: \(error.localizedDescription)"
        await noteUnavailableAttachment(name: name, detail: detail, notifyUser: notice)
    }

    /// Items the Telegram path buffers for the next turn (files and
    /// attachment notes), for the per-update outcome.
    private var telegramBufferedItemCount: Int {
        pendingImages.count + pendingDocuments.count + pendingReferencedImages.count
            + pendingReferencedDocuments.count + pendingAttachmentNotes.count
    }

    private func replyUnreadableTelegramMessage(_ message: TelegramMessage, updateId: Int) async {
        var keys = ["u:\(updateId)", "m:\(message.chat.id):\(message.messageId)"]
        if let group = message.mediaGroupId { keys.append("g:\(message.chat.id):\(group)") }
        guard !keys.contains(where: unreadableReplyKeys.contains) else { return }
        let kind = TelegramMessage.UnreadableKind(rawValue: message.unreadableKinds[0])?.displayName ?? "this kind of"
        // Recorded when the reply is handled (sent, or parked by sendText for
        // redelivery), not before the attempt.
        do { try await sendText("⚠️ I can't read \(kind) messages yet. Send it as a file, a photo or text.") }
        catch { print("[ConversationManager] Unreadable-message reply not sent now: \(error.localizedDescription)") }
        unreadableReplyKeys.append(contentsOf: keys)
        if unreadableReplyKeys.count > Self.unreadableReplyKeyLimit {
            unreadableReplyKeys.removeFirst(unreadableReplyKeys.count - Self.unreadableReplyKeyLimit)
        }
    }

    /// Download an audio file / video note as a document (≤ 20 MB, the Bot
    /// API limit; larger → the existing oversize notice). Never transcribed.
    private func bufferTelegramAudioFile(fileId: String, fileSize: Int?, displayName: String, ext: String,
                                         referenced: Bool, details: String? = nil) async {
        if let declared = fileSize, declared > Self.telegramBotDownloadLimitBytes {
            await noteOversizedAttachment(name: displayName, sizeBytes: declared, referenced: referenced)
            return
        }
        statusMessage = referenced ? "Downloading referenced audio..." : "Downloading audio file..."
        do {
            let data = try await telegramService.downloadDocument(fileId: fileId)
            let fileName = "\(referenced ? "ref_" : "")\(UUID().uuidString.prefix(8)).\(ext)"
            let fileURL = documentsDirectory.appendingPathComponent(fileName)
            try PrivateStorage.writeAtomically(data, to: fileURL)
            if referenced {
                pendingReferencedDocuments.append((fileName: fileName, fileSize: data.count))
            } else {
                pendingDocuments.append((fileName: fileName, fileSize: data.count))
                let about = details.map { ", \(MarkerNeutralizer.escape($0))" } ?? ""
                pendingAttachmentNotes.append("[Audio file '\(MarkerNeutralizer.escape(displayName))'\(about) received as a file: \(fileURL.path) — not transcribed; use transcribe_media if the user asks about its content]")
            }
            print("[ConversationManager] Buffered audio file: \(fileName) (\(displayName), \(data.count) bytes)")
        } catch {
            await noteFailedAttachmentDownload(name: displayName, error: error, referenced: referenced)
        }
    }

    static func audioDisplayName(_ audio: TelegramAudio) -> String {
        if let name = audio.fileName, !name.isEmpty { return name }
        let title = [audio.performer, audio.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " – ")
        return title.isEmpty ? "audio file" : title
    }

    static func audioDetails(_ audio: TelegramAudio) -> String {
        var parts = [clockDuration(audio.duration)]
        let title = [audio.performer, audio.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " – ")
        if !title.isEmpty, title != audio.fileName { parts.append(title) }
        return parts.joined(separator: ", ")
    }

    static func clockDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// File extension from the original name, else the MIME type, else m4a.
    static func audioExtension(fileName: String?, mimeType: String?) -> String {
        let fromName = URL(fileURLWithPath: fileName ?? "").pathExtension.lowercased()
        if !fromName.isEmpty, fromName.count <= 5, fromName.allSatisfy({ $0.isLetter || $0.isNumber }) { return fromName }
        switch mimeType?.lowercased() {
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/ogg", "audio/opus": return "ogg"
        case "audio/x-wav", "audio/wav", "audio/wave": return "wav"
        case "audio/flac", "audio/x-flac": return "flac"
        default: return "m4a"
        }
    }

    func processUpdate(_ update: TelegramUpdate) async {
        // Clear any previous error when starting to process a new message
        error = nil

        if let query = update.callbackQuery {
            await processCallbackQuery(query)
            return
        }
        
        guard let telegramMessage = update.message else {
            return
        }
        
        // Only process messages from the paired private chat, sent by the
        // paired user (TelegramPairing.acceptsPolledMessage: chat id, chat
        // type "private" and sender id must all match; fail closed).
        guard TelegramPairing.acceptsPolledMessage(
            chatId: telegramMessage.chat.id,
            chatType: telegramMessage.chat.type,
            fromId: telegramMessage.from?.id,
            pairedChatId: pairedChatId
        ) else {
            return
        }
        
        // Skip messages from the bot itself
        if telegramMessage.from?.isBot == true {
            return
        }

        // Record Telegram as the active user channel so command replies and
        // ambient output route here until the user writes on another channel.
        if let address = telegramAddress {
            noteUserActivity(on: address)
        }

        if let text = telegramMessage.text,
           await handleControlCommandIfNeeded(text) {
            return
        }
        
        // NOTE: messages arriving during an active turn are no longer dropped
        // here. They flow through the normal media/voice pipeline below and
        // dispatchUserTurn() queues them for mid-turn delivery to the model.

        // Per-update outcome (plan v2 §3.3 step 3): did THIS update add
        // anything (a buffered file, an attachment note, a trigger)? Counted
        // as a delta, never by looking at buffers an earlier update filled.
        let bufferedBefore = telegramBufferedItemCount

        // Extract forward context if this is a forwarded message (accumulate with pending)
        if telegramMessage.isForwarded {
            var forwardSource = "unknown"
            
            if let origin = telegramMessage.forwardOrigin {
                forwardSource = origin.description
            } else if let fromUser = telegramMessage.forwardFrom {
                let name = [fromUser.firstName, fromUser.lastName].compactMap { $0 }.joined(separator: " ")
                forwardSource = name.isEmpty ? "a user" : name
            } else if let fromChat = telegramMessage.forwardFromChat {
                forwardSource = fromChat.title ?? "a chat"
            }
            
            let newForwardContext = "[Forwarded from \(forwardSource)]"
            if let existing = pendingForwardContext {
                pendingForwardContext = existing + "\n" + newForwardContext
            } else {
                pendingForwardContext = newForwardContext
            }
            print("[ConversationManager] User forwarded message from: \(forwardSource)")
        }
        
        // Extract reply context if user is replying to a previous message
        if let replyToMsg = telegramMessage.replyToMessage {
            var replyContent = ""
            
            if let text = replyToMsg.text, !text.isEmpty {
                replyContent = text
            } else if let caption = replyToMsg.caption, !caption.isEmpty {
                replyContent = caption
            } else if replyToMsg.photo != nil {
                replyContent = "[Image]"
            } else if let doc = replyToMsg.document {
                replyContent = "[Document: \(doc.fileName ?? "file")]"
            } else if replyToMsg.voice != nil {
                replyContent = "[Voice message]"
            } else if let video = replyToMsg.video {
                replyContent = "[Video: \(video.duration)s]"
            } else if let audio = replyToMsg.audio {
                replyContent = "[Audio: \(MarkerNeutralizer.escape(Self.audioDisplayName(audio))), \(Self.clockDuration(audio.duration))]"
            } else if replyToMsg.audioState == .presentUndecodable {
                replyContent = "[Audio: unavailable]"
            } else if let note = replyToMsg.videoNote {
                replyContent = "[Video note: \(note.duration)s]"
            } else if replyToMsg.videoNoteState == .presentUndecodable {
                replyContent = "[Video note: unavailable]"
            }
            
            if !replyContent.isEmpty {
                let senderInfo: String
                if replyToMsg.from?.isBot == true {
                    senderInfo = "your previous message"
                } else {
                    senderInfo = "their previous message"
                }
                let newReplyContext = "[Replying to \(senderInfo): \"\(replyContent)\"]"
                if let existing = pendingReplyContext {
                    pendingReplyContext = existing + "\n" + newReplyContext
                } else {
                    pendingReplyContext = newReplyContext
                }
                print("[ConversationManager] User replied to: \(replyContent.prefix(100))")
            }
            
            // Download attachments from replied-to message (add to pending referenced)
            if let photos = replyToMsg.photo, !photos.isEmpty {
                statusMessage = "Downloading referenced image..."
                let largestPhoto = photos.max(by: { $0.width * $0.height < $1.width * $1.height })!
                
                do {
                    let imageData = try await telegramService.downloadPhoto(fileId: largestPhoto.fileId)
                    let fileName = "ref_\(UUID().uuidString.prefix(8)).jpg"
                    let fileURL = imagesDirectory.appendingPathComponent(fileName)
                    try PrivateStorage.writeAtomically(imageData, to: fileURL)
                    
                    pendingReferencedImages.append((fileName: fileName, fileSize: imageData.count))
                    print("[ConversationManager] Buffered referenced image: \(fileName) (\(imageData.count) bytes)")
                } catch {
                    await noteFailedAttachmentDownload(name: "referenced photo", error: error, referenced: true)
                }
            }
            
            if let document = replyToMsg.document {
                let originalName = document.fileName ?? "document"

                if let declaredSize = document.fileSize, declaredSize > Self.telegramBotDownloadLimitBytes {
                    await noteOversizedAttachment(name: originalName, sizeBytes: declaredSize, referenced: true)
                } else {
                    statusMessage = "Downloading referenced document..."

                    do {
                        let documentData = try await telegramService.downloadDocument(fileId: document.fileId)
                        let ext = URL(fileURLWithPath: originalName).pathExtension
                        let fileName = "ref_\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "bin" : ext)"
                        let fileURL = documentsDirectory.appendingPathComponent(fileName)
                        try PrivateStorage.writeAtomically(documentData, to: fileURL)

                        pendingReferencedDocuments.append((fileName: fileName, fileSize: documentData.count))
                        print("[ConversationManager] Buffered referenced document: \(fileName) (\(originalName), \(documentData.count) bytes)")
                    } catch {
                        await noteFailedAttachmentDownload(name: originalName, error: error, referenced: true)
                    }
                }
            }
            
            // Download referenced video if user replied to a video message
            if let video = replyToMsg.video {
                let displayName = video.fileName ?? "video"

                if let declaredSize = video.fileSize, declaredSize > Self.telegramBotDownloadLimitBytes {
                    await noteOversizedAttachment(name: displayName, sizeBytes: declaredSize, referenced: true)
                } else {
                    statusMessage = "Downloading referenced video..."

                    do {
                        let videoData = try await telegramService.downloadDocument(fileId: video.fileId)
                        let ext: String
                        if let mimeType = video.mimeType {
                            switch mimeType {
                            case "video/mp4": ext = "mp4"
                            case "video/quicktime": ext = "mov"
                            case "video/webm": ext = "webm"
                            default: ext = "mp4"
                            }
                        } else {
                            ext = "mp4"
                        }
                        let fileName = "ref_\(UUID().uuidString.prefix(8)).\(ext)"
                        let fileURL = documentsDirectory.appendingPathComponent(fileName)
                        try PrivateStorage.writeAtomically(videoData, to: fileURL)

                        pendingReferencedDocuments.append((fileName: fileName, fileSize: videoData.count))
                        print("[ConversationManager] Buffered referenced video: \(fileName) (\(videoData.count) bytes)")
                    } catch {
                        await noteFailedAttachmentDownload(name: displayName, error: error, referenced: true)
                    }
                }
            }

            // Referenced audio file / video note: a file, never transcribed.
            if let audio = replyToMsg.audio {
                await bufferTelegramAudioFile(fileId: audio.fileId, fileSize: audio.fileSize,
                                              displayName: Self.audioDisplayName(audio),
                                              ext: Self.audioExtension(fileName: audio.fileName, mimeType: audio.mimeType),
                                              referenced: true)
            } else if let note = replyToMsg.videoNote {
                await bufferTelegramAudioFile(fileId: note.fileId, fileSize: note.fileSize, displayName: "video note",
                                              ext: "mp4", referenced: true)
            }
        }
        
        // Determine what type of message this is and whether to trigger processing
        var triggerText: String? = nil
        
        // Text message → triggers processing
        if let text = telegramMessage.text, !text.isEmpty {
            triggerText = text
        }
        // Photo message
        else if let photos = telegramMessage.photo, !photos.isEmpty {
            statusMessage = "Downloading image..."
            
            let largestPhoto = photos.max(by: { $0.width * $0.height < $1.width * $1.height })!
            
            do {
                let imageData = try await telegramService.downloadPhoto(fileId: largestPhoto.fileId)
                
                let fileName = "\(UUID().uuidString.prefix(8)).jpg"
                let fileURL = imagesDirectory.appendingPathComponent(fileName)
                try PrivateStorage.writeAtomically(imageData, to: fileURL)
                
                // Also save to documents directory for email attachments
                let documentsFileURL = documentsDirectory.appendingPathComponent(fileName)
                try PrivateStorage.writeAtomically(imageData, to: documentsFileURL)
                
                pendingImages.append((fileName: fileName, fileSize: imageData.count))
                print("[ConversationManager] Buffered image: \(fileName) (\(imageData.count) bytes)")
            } catch {
                await noteFailedAttachmentDownload(name: "photo", error: error, referenced: false)
                self.error = "Failed to download image: \(error.localizedDescription)"
                statusMessage = "Image download failed"
            }

            // Caption triggers processing; no caption means buffer only
            if let caption = telegramMessage.caption, !caption.isEmpty {
                triggerText = caption
            }
        }
        // Voice message → transcription triggers processing
        else if let voice = telegramMessage.voice {
            let transcriptionProvider = currentVoiceTranscriptionProvider()
            statusMessage = transcriptionProvider == .openAI
                ? "Transcribing audio with \(MediaRouting.transcription.viaOpenRouter ? "OpenRouter" : "OpenAI")..."
                : "Transcribing audio locally..."
            
            // Every failure path below must TELL THE SENDER before returning.
            // These used to set a macOS-UI-only error string and silently drop
            // the message — from Telegram, indistinguishable from being ignored.
            do {
                let audioURL = try await telegramService.downloadVoiceFile(fileId: voice.fileId)
                defer { try? FileManager.default.removeItem(at: audioURL) }

                let transcription: String?
                var transcriptionFailureReason: String?
                switch transcriptionProvider {
                case .openAI:
                    let transcriptionRoute = MediaRouting.transcription
                    let apiKey = transcriptionRoute.key
                    guard !apiKey.isEmpty else {
                        self.error = "OpenAI API key not set. Run `briglia setup` (section 2) to add it."
                        statusMessage = "OpenAI API key missing"
                        try? await sendText("⚠️ I couldn't process your voice message: the OpenAI transcription key isn't configured (run `briglia setup`, step 2). Type the message as text, or fix the key.")
                        return
                    }
                    do {
                        transcription = try await OpenAITranscriptionService.shared.transcribeAudioFile(url: audioURL, apiKey: apiKey, prompt: TranscriptionVocabulary.chatHint(), endpoint: .init(transcriptionRoute))
                    } catch {
                        transcription = nil
                        transcriptionFailureReason = error.localizedDescription
                    }
                case .local:
                    guard WhisperKitService.shared.isModelReady else {
                        self.error = "Voice model not ready. Please download it in Settings."
                        statusMessage = "Voice model not ready"
                        try? await sendText("⚠️ I couldn't process your voice message: local transcription isn't available in Briglia CLI — switch to OpenAI transcription (run `briglia setup`, step 2), or type the message as text.")
                        return
                    }
                    transcription = await WhisperKitService.shared.transcribeAudioFile(url: audioURL)
                }

                if let transcription {
                    triggerText = transcription
                    print("[ConversationManager] Transcribed voice: \(transcription)")
                } else {
                    self.error = "Failed to transcribe audio"
                    statusMessage = "Transcription failed"
                    try? await sendText("⚠️ I couldn't transcribe your voice message (\(transcriptionFailureReason ?? "transcription failed")). Try again, or type it as text.")
                    return
                }
            } catch {
                self.error = "Failed to download voice file: \(error.localizedDescription)"
                statusMessage = "Voice download failed"
                try? await sendText("⚠️ I couldn't download your voice message from Telegram (\(error.localizedDescription)). Please try again or send it as text.")
                return
            }
        }
        // Document message
        else if let document = telegramMessage.document {
            let originalName = document.fileName ?? "document"

            if let declaredSize = document.fileSize, declaredSize > Self.telegramBotDownloadLimitBytes {
                // Telegram won't serve this file to a bot at all — skip the doomed download,
                // tell the user immediately, and let any caption still reach the agent.
                await noteOversizedAttachment(name: originalName, sizeBytes: declaredSize, referenced: false)
                statusMessage = "Document too large for Telegram bot download"
            } else {
                statusMessage = "Downloading document..."

                do {
                    let documentData = try await telegramService.downloadDocument(fileId: document.fileId)

                    let ext = URL(fileURLWithPath: originalName).pathExtension
                    let fileName = "\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "bin" : ext)"
                    let fileURL = documentsDirectory.appendingPathComponent(fileName)
                    try PrivateStorage.writeAtomically(documentData, to: fileURL)

                    pendingDocuments.append((fileName: fileName, fileSize: documentData.count))
                    print("[ConversationManager] Buffered document: \(fileName) (\(originalName), \(documentData.count) bytes)")
                } catch {
                    await noteFailedAttachmentDownload(name: originalName, error: error, referenced: false)
                    self.error = "Failed to download document: \(error.localizedDescription)"
                    statusMessage = "Document download failed"
                }
            }

            // Caption triggers processing; no caption means buffer only
            if let caption = telegramMessage.caption, !caption.isEmpty {
                triggerText = caption
            }
        }
        // Audio file (.m4a/.mp3 from Files) or round video note: a FILE, like
        // a document — never transcribed automatically (owner rule: only
        // voice notes are). The agent transcribes it with transcribe_media
        // when asked. A malformed field still gets a visible outcome.
        else if let audio = telegramMessage.audio {
            await bufferTelegramAudioFile(fileId: audio.fileId, fileSize: audio.fileSize,
                                          displayName: Self.audioDisplayName(audio),
                                          ext: Self.audioExtension(fileName: audio.fileName, mimeType: audio.mimeType),
                                          referenced: false, details: Self.audioDetails(audio))
            if let caption = telegramMessage.caption, !caption.isEmpty { triggerText = caption }
        }
        else if telegramMessage.audioState == .presentUndecodable {
            await noteUnavailableAttachment(
                name: "audio file",
                detail: "Telegram sent it in a form Briglia could not read.",
                notifyUser: "⚠️ I couldn't read the audio file you sent (Telegram delivered it in an unexpected form). Please send it again as a file (📎 → File).")
            if let caption = telegramMessage.caption, !caption.isEmpty { triggerText = caption }
        }
        else if let note = telegramMessage.videoNote {
            await bufferTelegramAudioFile(fileId: note.fileId, fileSize: note.fileSize, displayName: "video note",
                                          ext: "mp4", referenced: false, details: "\(note.duration)s round video")
            if let caption = telegramMessage.caption, !caption.isEmpty { triggerText = caption }
        }
        else if telegramMessage.videoNoteState == .presentUndecodable {
            await noteUnavailableAttachment(
                name: "video note",
                detail: "Telegram sent it in a form Briglia could not read.",
                notifyUser: "⚠️ I couldn't read the video note you sent (Telegram delivered it in an unexpected form). Please send it again as a file (📎 → File).")
            if let caption = telegramMessage.caption, !caption.isEmpty { triggerText = caption }
        }
        // Video message - treated as a document for storage and email purposes
        else if let video = telegramMessage.video {
            let displayName = video.fileName ?? "video"

            if let declaredSize = video.fileSize, declaredSize > Self.telegramBotDownloadLimitBytes {
                await noteOversizedAttachment(name: displayName, sizeBytes: declaredSize, referenced: false)
                statusMessage = "Video too large for Telegram bot download"
            } else {
                statusMessage = "Downloading video..."

                do {
                    let videoData = try await telegramService.downloadDocument(fileId: video.fileId)

                    // Use original filename if available, otherwise generate one with proper extension
                    let ext: String
                    if let mimeType = video.mimeType {
                        switch mimeType {
                        case "video/mp4": ext = "mp4"
                        case "video/quicktime": ext = "mov"
                        case "video/webm": ext = "webm"
                        case "video/x-matroska": ext = "mkv"
                        default: ext = "mp4"
                        }
                    } else {
                        ext = "mp4"
                    }

                    let fileName = video.fileName ?? "\(UUID().uuidString.prefix(8)).\(ext)"
                    let fileURL = documentsDirectory.appendingPathComponent(fileName)
                    try PrivateStorage.writeAtomically(videoData, to: fileURL)

                    pendingDocuments.append((fileName: fileName, fileSize: videoData.count))
                    print("[ConversationManager] Buffered video: \(fileName) (\(videoData.count) bytes, \(video.duration)s, \(video.width)x\(video.height))")
                } catch {
                    await noteFailedAttachmentDownload(name: displayName, error: error, referenced: false)
                    self.error = "Failed to download video: \(error.localizedDescription)"
                    statusMessage = "Video download failed"
                }
            }

            // Caption triggers processing; no caption means buffer only
            if let caption = telegramMessage.caption, !caption.isEmpty {
                triggerText = caption
            }
        }
        
        // If no trigger text, just show status and return (media is buffered)
        guard let promptText = triggerText else {
            // Safety net (plan v2 §3.3 step 5): THIS update produced nothing
            // and carried a user-content kind Briglia cannot read → one
            // visible reply instead of silence.
            if telegramBufferedItemCount == bufferedBefore, !telegramMessage.unreadableKinds.isEmpty {
                await replyUnreadableTelegramMessage(telegramMessage, updateId: update.updateId)
            }
            let imageCount = pendingImages.count
            let docCount = pendingDocuments.count
            if imageCount > 0 || docCount > 0 {
                var parts: [String] = []
                if imageCount > 0 { parts.append("\(imageCount) image\(imageCount > 1 ? "s" : "")") }
                if docCount > 0 { parts.append("\(docCount) file\(docCount > 1 ? "s" : "")") }
                statusMessage = "📎 \(parts.joined(separator: ", ")) waiting for your message..."
            }
            return
        }
        
        // Build message content with forward and reply context
        var messageContent = promptText
        if let fwdContext = pendingForwardContext {
            messageContent = fwdContext + "\n\n" + messageContent
        }
        if let replyCtx = pendingReplyContext {
            messageContent = replyCtx + "\n\n" + messageContent
        }
        if !pendingAttachmentNotes.isEmpty {
            messageContent = pendingAttachmentNotes.joined(separator: "\n") + "\n\n" + messageContent
        }
        
        // Combine all pending media into the message
        let userMessage = Message(
            role: .user,
            content: messageContent,
            imageFileNames: pendingImages.map { $0.fileName },
            documentFileNames: pendingDocuments.map { $0.fileName },
            imageFileSizes: pendingImages.map { $0.fileSize },
            documentFileSizes: pendingDocuments.map { $0.fileSize },
            referencedImageFileNames: pendingReferencedImages.map { $0.fileName },
            referencedDocumentFileNames: pendingReferencedDocuments.map { $0.fileName },
            referencedDocumentFileSizes: pendingReferencedDocuments.map { $0.fileSize },
            originChannel: telegramAddress
        )
        
        // Clear all buffers
        pendingImages.removeAll()
        pendingDocuments.removeAll()
        pendingReferencedImages.removeAll()
        pendingReferencedDocuments.removeAll()
        pendingForwardContext = nil
        pendingReplyContext = nil
        pendingAttachmentNotes.removeAll()
        
        await dispatchUserTurn(userMessage, telegramMessageId: telegramMessage.messageId)
    }

    /// Route a fully-built user message: start a turn when idle, or queue it
    /// for mid-turn delivery when one is already running. Queued messages are
    /// NOT appended to history here — they enter `messages` at the moment they
    /// are actually shown to the model (next tool-round boundary, or the
    /// follow-up turn launched when this one ends), so history order always
    /// matches what the model saw.
    func dispatchUserTurn(_ userMessage: Message, telegramMessageId: Int? = nil) async {
        // Unreadable history (1a round 4): hold, never run. The message goes
        // to the durable mid-turn queue file — the update is then confirmed
        // like any queued message, so polling (and /status, /restart,
        // /deleteuserdata) keeps working. If even that write fails, the
        // update stays unconfirmed and the existing durability stall
        // re-delivers it after a restart. No history append, no marker.
        if historyLoadFailure != nil {
            guard holdInboundWhileHistoryUnreadable(userMessage) else {
                inboundDurabilityFailure = true
                return
            }
            if !historyHoldNoticeSent {
                historyHoldNoticeSent = true
                try? await sendText(Self.historyHoldNotice)
            } else if userMessage.kind == .userText, let telegramMessageId, let chatId = pairedChatId {
                let service = telegramService
                Task { try? await service.setMessageReaction(chatId: chatId, messageId: telegramMessageId, emoji: "👀") }
            }
            return
        }
        // Unreadable held-message file with readable history (1a round 6):
        // the same refusal as round 5 — the update stays unconfirmed (the
        // existing durability stall re-delivers it after repair and a
        // restart); nothing reaches history, the queue file or a turn. One
        // explanation per process.
        if heldQueueFileProblem != nil {
            inboundDurabilityFailure = true
            if !heldQueueRefusalNoticeSent {
                heldQueueRefusalNoticeSent = true
                try? await sendText(Self.heldQueueRefusalNotice)
            }
            return
        }
        if activeRunId != nil || activeProcessingTask != nil {
            pendingMidTurnMessages.append(userMessage)
            let persisted = persistPendingMidTurnQueue()
            if !persisted {
                inboundDurabilityFailure = true
            }
            DebugTelemetry.log(
                .info,
                summary: "queued msg during active turn",
                detail: String(userMessage.content.prefix(200))
            )
            // Mid-turn early wake (§3.1, §3.8): mint the generation and fire
            // the wake after the append and persist. No text acknowledgement
            // (owner decision): a silent 👀 reaction on Telegram, one attempt,
            // errors ignored, never parked.
            noteMidTurnEnqueued(userMessage)
            if userMessage.kind == .userText, let telegramMessageId, let chatId = pairedChatId {
                let service = telegramService
                Task { try? await service.setMessageReaction(chatId: chatId, messageId: telegramMessageId, emoji: "👀") }
            }
            statusMessage = "Message queued for in-flight turn"
            return
        }

        messages.append(userMessage)
        if !saveConversation() {
            inboundDurabilityFailure = true
        }

        statusMessage = "Generating response..."
        startActiveProcessing(for: userMessage)
    }

    /// Hold an inbound message while history is unreadable: append to the
    /// mid-turn queue and mirror it to disk (the queue file is kept, and only
    /// recovered, once history loads — `recoverPersistedMidTurnMessages`).
    /// No wake is fired (there is no run), nothing touches history or the
    /// active-turn marker. Returns false (and rolls back) if the mirror
    /// write fails.
    func holdInboundWhileHistoryUnreadable(_ message: Message) -> Bool {
        // The queue file may hold messages acknowledged by an earlier
        // process: merge it first, and never replace a file that cannot be
        // read (the caller then refuses / leaves the update unconfirmed).
        guard hydrateHeldQueueFromDisk() else {
            print("[ConversationManager] Refusing to hold a new message: the held-message queue file can't be read (\(heldQueueFileProblem ?? "unknown")) — it is kept as is")
            return false
        }
        if pendingMidTurnMessages.contains(where: { $0.id == message.id }) { return true }
        let before = pendingMidTurnMessages
        pendingMidTurnMessages.append(message)
        guard persistPendingMidTurnQueue() else {
            // Atomic write: the file still holds `before` unless the
            // failure came after the rename — rewrite it to be sure. Every
            // earlier entry stays in memory and on disk.
            pendingMidTurnMessages = before
            _ = persistPendingMidTurnQueue()
            return false
        }
        print("[ConversationManager] Held inbound message (history unreadable) — \(pendingMidTurnMessages.count) waiting for history to load")
        statusMessage = "Message held — conversation history can't be read"
        return true
    }

    /// Drain queued mid-turn user messages into the last tool result of the
    /// current round so the model sees them before its next LLM call. The
    /// drained messages are appended to conversation history at this moment —
    /// they land just before the turn's final assistant message, matching what
    /// the model actually saw. Attachments can't ride inline mid-turn, so the
    /// envelope lists their absolute paths for read_file.
    /// Returns the highest wake generation whose message reached durable
    /// history in this drain (the caller consumes the wake up to it), or nil
    /// when nothing was delivered.
    @discardableResult
    func deliverMidTurnMessages(into results: inout [ToolResultMessage],
                                        backgroundStatus: HarnessBackgroundStatus? = nil) -> UInt64? {
        guard !pendingMidTurnMessages.isEmpty, !results.isEmpty else { return nil }
        let queued = pendingMidTurnMessages
        let delivered: Bool
        if MidTurnDelivery.typedAnnotationsEnabled {
            delivered = deliverMidTurnMessagesTyped(into: &results, backgroundStatus: backgroundStatus)
        } else {
            delivered = deliverMidTurnMessagesLegacy(into: &results, backgroundStatus: backgroundStatus)
        }
        guard delivered else { return nil }
        return noteAppendedToHistory(queued)
    }

    /// Typed mid-turn delivery: peek the queue, build a
    /// validated batch annotation with a fresh per-delivery nonce, and only
    /// then commit — append history (id-deduplicated for redelivery after an
    /// aborted request), clear the queue, attach the annotation to the final
    /// tool result. Construction failure (RNG, validation) fails closed: no
    /// annotation is emitted and the messages stay queued for a later
    /// boundary. The marker itself is rendered exclusively at the provider
    /// serialization boundary — never appended to `content`.
    @discardableResult
    private func deliverMidTurnMessagesTyped(into results: inout [ToolResultMessage],
                                             backgroundStatus: HarnessBackgroundStatus? = nil) -> Bool {
        let drained = pendingMidTurnMessages  // peek — do not clear yet

        guard let built = MidTurnDrainSupport.buildBatchAnnotation(
            for: drained,
            imagesDirectory: imagesDirectory,
            documentsDirectory: documentsDirectory
        ) else {
            statusMessage = "Mid-turn delivery deferred (will retry at the next boundary)"
            return false  // fail closed: queue and its durable mirror stay untouched
        }
        // The wake note (§3.11): harness status of work still running,
        // rendered after and outside the direct-user block.
        let annotation = built.withBackgroundStatus(backgroundStatus)

        pendingMidTurnMessages.removeAll()
        defer { persistPendingMidTurnQueue() }  // after saveConversation below

        for message in drained {
            // Id-dedup: a batch requeued after an aborted request already has
            // its history copy from the first attempt.
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
            if let origin = message.originChannel {
                lastMidTurnUserAddress = origin
            }
            DebugTelemetry.log(
                .info,
                summary: "delivered mid-turn msg to model (typed annotation)",
                detail: String(message.content.prefix(200))
            )
        }
        guard saveConversation() else {
            pendingMidTurnMessages = drained + pendingMidTurnMessages
            statusMessage = "Mid-turn history could not be saved; delivery remains pending"
            return false
        }

        results[results.count - 1].harnessAnnotations.append(annotation)
        inFlightMidTurnBatch = InFlightMidTurnBatch(nonce: annotation.deliveryNonce, messages: drained)
        return true
    }

    /// Legacy flattened delivery — reachable only through the rollback flag
    /// (BRIGLIA_MIDTURN_TYPED_ANNOTATIONS=0 / ada.midturnLegacyDelivery). Restores
    /// the weaker static-marker behavior documented in the plan's Phase D.
    @discardableResult
    private func deliverMidTurnMessagesLegacy(into results: inout [ToolResultMessage],
                                              backgroundStatus: HarnessBackgroundStatus? = nil) -> Bool {
        let drained = pendingMidTurnMessages
        pendingMidTurnMessages.removeAll()
        defer { persistPendingMidTurnQueue() }  // after saveConversation below

        var blocks: [String] = []
        for message in drained {
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
            if let origin = message.originChannel {
                lastMidTurnUserAddress = origin
            }
            var block = """
            [USER MESSAGE — arrived while you were working. This is the user speaking, with the same authority as any chat message. Factor it into the current task — adjust course if it asks you to, and make sure your final reply addresses it. If it needs an answer before your work completes, reply right away with the mid_turn_message_user tool.]
            \(message.content)
            """
            let attachmentPaths =
                message.imageFileNames.map { imagesDirectory.appendingPathComponent($0).path }
                + message.documentFileNames.map { documentsDirectory.appendingPathComponent($0).path }
                + message.referencedImageFileNames.map { imagesDirectory.appendingPathComponent($0).path }
                + message.referencedDocumentFileNames.map { documentsDirectory.appendingPathComponent($0).path }
            if !attachmentPaths.isEmpty {
                block += "\n[Attached files (use read_file to view): \(attachmentPaths.joined(separator: ", "))]"
            }
            blocks.append(block)
            DebugTelemetry.log(
                .info,
                summary: "delivered mid-turn msg to model (legacy)",
                detail: String(message.content.prefix(200))
            )
        }
        saveConversation()

        if let backgroundStatus, backgroundStatus.isValid {
            blocks.append(HarnessAnnotationRenderer.renderBackgroundStatus(backgroundStatus))
        }
        results[results.count - 1].content += "\n\n" + blocks.joined(separator: "\n\n")
        return true
    }
}
