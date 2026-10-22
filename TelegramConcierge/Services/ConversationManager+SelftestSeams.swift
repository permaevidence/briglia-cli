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

// MARK: - Mid-turn early wake selftest seams
//
// Explicit, test-only entry points for `__midturn-wake-selftest` (which runs
// in private scratch roots). They call the production paths; none replaces
// an implementation, a branch or a durability rule.
extension ConversationManager {
    /// Persona-snapshot selftest seam: fires when the tool loop's
    /// active-turn scope changed between two rounds (measured prompt tokens
    /// are then discarded). nil in production.
    nonisolated(unsafe) static var promptScopeResetForTesting: (() -> Void)?
    func _testPrepareScriptedProvider(apiKey: String) async {
        frozenCalendarContext = ""
        frozenEmailContext = ""
        frozenContextDay = Calendar.current.startOfDay(for: Date())
        await openRouterService.configure(apiKey: apiKey)
        await toolExecutor.setArchiveService(archiveService)
        await toolExecutor.configureOpenRouter(openRouterService, imagesDirectory: imagesDirectory,
                                               documentsDirectory: documentsDirectory)
    }
    /// The production Telegram update handler (media, voice, safety net).
    func _testProcessUpdate(_ update: TelegramUpdate) async { await processUpdate(update) }
    /// The production WhatsApp inbound handler.
    func _testProcessWhatsApp(_ inbound: WhatsAppInboundMessage) async { await processWhatsAppInbound(inbound) }
    var _testPendingDocumentCount: Int { pendingDocuments.count }
    var _testPendingAttachmentNotes: [String] { pendingAttachmentNotes }
    func _testSeedHistory(_ history: [Message]) {
        messages = history
        _ = saveConversation()
    }
    func _testSetPolling(_ on: Bool) { isPolling = on }
    func _testStartTurn(for message: Message) {
        messages.append(message)
        _ = saveConversation()
        startActiveProcessing(for: message)
    }
    func _testDispatchUser(_ message: Message) async { await dispatchUserTurn(message) }
    func _testProcessEmails(_ emails: [GoogleWorkspaceService.UnreadEmail]) async -> Bool {
        await processNewUnreadEmails(emails)
    }
    func _testQueueAmbient(_ message: Message) {
        pendingAmbientTriggers.append(message)
        _ = persistPendingAmbientTriggers()
    }
    func _testDrainAmbient() { drainPendingAmbientTriggers() }
    var _testPendingAmbientURL: URL { pendingAmbientFileURL }
    func _testCheckDueReminders() async { await checkDueReminders() }
    func _testStartTurnOnly(for message: Message) { startActiveProcessing(for: message) }
    var _testHoldNoticeSent: Bool { historyHoldNoticeSent }
    var _testInboundDurabilityFailure: Bool { inboundDurabilityFailure }
    func _testClearInboundDurabilityFailure() { inboundDurabilityFailure = false }
    var _testHeldQueueProblem: String? { heldQueueFileProblem }
    var _testHeldQueueRefusalNoticeSent: Bool { heldQueueRefusalNoticeSent }
    func _testBackgroundStatus() async -> String? { await backgroundStatusSection() }
    func _testAwaitIdle(timeout: TimeInterval = 60) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if activeProcessingTask == nil && activeRunId == nil { return true }
            if let task = activeProcessingTask { _ = await Task { await task.value }.value }
            else { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        return activeProcessingTask == nil && activeRunId == nil
    }
    var _testMessages: [Message] { messages }
    var _testQueue: [Message] { pendingMidTurnMessages }
    var _testIsActive: Bool { activeRunId != nil || activeProcessingTask != nil }
    var _testLastError: String? { error }
    var _testStoppedJobIds: Set<UUID> { stoppedJobIds }
    var _testRecoveredWakeTrigger: Message? { recoveredWakeTrigger }
    func _testStop() async { await stopActiveExecution(notify: nil) }
    func _testIdleDrains() async {
        await checkBackgroundBashCompletions()
        await checkBashWatchMatches()
    }
    func _testSave() -> Bool { saveConversation() }
    func _testReconcileJobsOnly() { reconcileJobRecords() }
    func _testSubagentDrainOnly() async { await checkBackgroundSubagentCompletions() }
    func _testReplaceMessages(_ history: [Message]) { messages = history }
    func _testStopPassOnly() { applyPersistedStopMarker() }
    func _testStartupPasses() {
        restorePendingInboundBuffers()
        applyPersistedStopMarker()
        recoverPersistedMidTurnMessages()
        reconcileJobRecords()
        if let trigger = recoveredWakeTrigger, activeRunId == nil, activeProcessingTask == nil, !stopIntent.isUnknown {
            recoveredWakeTrigger = nil
            startActiveProcessing(for: trigger)
        }
        resumeInterruptedActiveTurnIfNeeded()
    }
    func _testSettleBeforeRemoval(_ removed: [Message]) throws { try settleJobEvidenceBeforeRemoval(of: removed) }
    func _testResetEarlyWakeState() throws { try resetEarlyWakeStateForReplacedHistory() }
    func _testSettleToolCharges() { settleToolCharges() }
    var _testActiveTurnMarkerURL: URL { activeTurnMarkerFileURL }
    var _testPendingMidTurnURL: URL { pendingMidTurnFileURL }
    var _testSalvageURL: URL { turnSalvageFileURL }
    var _testRecoveryBlocked: Bool { recoveryBlocked }
    var _testHistoryLoadFailure: String? { historyLoadFailure }
    func _testExpectCompletionAck(messageId: UUID, jobId: UUID) { pendingCompletionAcks[messageId] = jobId }
    func _testWriteActiveTurnMarker(for message: Message) { _ = writeActiveTurnMarker(for: message) }
    func _testPersistQueue(_ queue: [Message]) { pendingMidTurnMessages = queue; _ = persistPendingMidTurnQueue() }
    var _testSeenGeneration: UInt64 { seenGenerationAtRequest }
    var _testToolLog: [(label: String, failed: Bool)] { currentTurnToolLog.map { ($0.label, $0.failed) } }
}

// MARK: - Summary retention (Part B) selftest seams
//
// Test-only entry points for `__prune-retention-selftest` (private scratch
// roots). They call the production commit, loader and estimators.
extension ConversationManager {
    /// The real `commitPrune` over a tool-interaction plan for `affected`
    /// indices of the current history, with a scripted summary text.
    /// `sourceCount` limits the source to a prefix of history (as a mid-loop
    /// prune's request view can be); `currentRounds` are the in-flight rounds.
    func _testRetentionPrune(affected: [Int], compressed: [Int] = [], trigger: String, noSnapshot: Bool = false,
                             sourceCount: Int? = nil, currentRounds: [ToolInteraction] = [],
                             summary: String?) async throws -> [Message] {
        let plan = PrunePlan(actions: affected.map { .toolInteractions(index: $0, savedTokens: 0) },
                             pruningBoundary: (affected.max() ?? -1) + 1)
        let source = sourceCount.map { Array(messages.prefix($0)) } ?? messages
        return try await commitPrune(plan: plan, compressedIndices: compressed, safeBoundary: 0, source: source,
                                     currentRounds: currentRounds, trigger: trigger, noSnapshot: noSnapshot) { _ in summary }
    }
    func _testMetadataNote(_ message: Message) async -> String? { await openRouterService.historyMetadataNote(for: message) }
    func _testManualPrune(noSnapshot: Bool = false) async { await manualPruneToolInteractions(notify: nil, noSnapshot: noSnapshot) }
    func _testSummaryNoteTokens(_ message: Message) -> Int { prunedContextSummaryTokens(for: message) }
    func _testPromptTokens(_ message: Message) -> Int { estimatedPromptTokens(for: message, isLMStudio: false) }
    var _testMaintenanceNotice: String? { maintenanceNotice }
    // /keepsummaries (`__keep-summaries-selftest`).
    var _testPromptRenderKey: String { lastPromptRenderKey }
    var _testLastPromptTokens: Int? { lastPromptTokens }
    var _testLastCompletionTokens: Int? { lastCompletionTokens }
    func _testSetPromptMeasurement(_ tokens: Int?, key: String) { lastPromptRenderKey = key; lastPromptTokens = tokens }
    func _testBeginMaintenance() -> UUID { beginMaintenance(.pruning) }
    func _testEndMaintenance(_ id: UUID) { endMaintenance(id) }
    func _testSetArchiveRecoveryPlaceholder(_ on: Bool) {
        if on { archiveRecoveryTask = Task {} } else { archiveRecoveryTask = nil }
    }
    func _testSetActiveRunPlaceholder(_ on: Bool) { activeRunId = on ? UUID() : nil }
    /// A finished (succeeded, uncommitted) archive job holding the slot.
    func _testSetArchiveJobPlaceholder(_ on: Bool) {
        if on {
            let view = ArchivePromptView(items: [], totalChunkCount: 0, hiddenRowIds: [], visibleChunkIds: [], leaseId: UUID())
            var job = ArchiveJob(id: UUID(), batch: [], generation: archiveGeneration, startedAt: Date(), frozenView: view)
            job.outcome = .succeeded
            archiveJob = job
        } else { archiveJob = nil }
    }
    func _testScheduleIdlePass() { scheduleSummaryRetentionIdlePass() }
    func _testMarkScanPending() { summaryRetentionScanPending = true }
    var _testArchiveService: ConversationArchiveService { archiveService }
}

// MARK: - /stop visibility selftest seams
//
// Test-only entry points for `__stop-visibility-selftest` (private scratch
// roots). They call the production paths; none replaces an implementation.
extension ConversationManager {
    func _svRegisterChannel(_ channel: any ChatChannel) { channels[channel.kind] = channel }
    func _svUnregisterChannel(_ kind: ChannelKind) { channels.removeValue(forKey: kind) }
    func _svSetLastUserAddress(_ address: ChannelAddress?) { lastUserChannelAddress = address }
    func _svStop(notify address: ChannelAddress?) async { await stopActiveExecution(notify: address) }
    func _svSendOrdinary(_ text: String, to address: ChannelAddress) async { try? await sendText(text, to: address) }
    var _svParkedTexts: [String] { parkedOutbound.items.map(\.text) }
    var _svLiveSeries: [NoticeSeries] { Array(noticeSeriesRegistry.values) }
    func _svSeries(ofRun run: UUID) -> [NoticeSeries.Target: UUID] { stoppedRunsFinishing[run]?.series ?? [:] }
    func _svSeries(id: UUID) -> NoticeSeries? { noticeSeriesRegistry[id] }
    func _svRunPhase(_ run: UUID) -> RunPhase? { runPhases[run] }
    var _svActiveRunId: UUID? { activeRunId }
    var _svWatcherCount: Int { stoppedRunWatchers.count }
    func _svCutOverTelegramBot(to token: String) async { await cutOverTelegramBot(to: token) }
    func _svRetireForWipe() { retireVisibilityNoticesForWipe() }
    func _svArchivePhase(_ phase: ConversationArchiveService.MaintenancePhase, began: Bool) {
        handleArchiveMaintenancePhase(phase, began: began)
    }
    func _svBeginMaintenance(_ kind: MaintenanceActivity.Kind) -> UUID { beginMaintenance(kind) }
    func _svEndMaintenance(_ id: UUID) { endMaintenance(id) }
    func _svRunEnded(_ run: UUID) { stoppedRunEnded(run) }
    func _svRegisterTelegram() async { await updateTelegramChannelRegistration() }
    func _svSetArchiveBackoff(until date: Date) { archiveRetryBackoffUntil = date }
    // A3 (disk-saving pause/recovery notices)
    func _svSetPairedChatId(_ id: Int?) { pairedChatId = id }
    func _svSetStalledConfirm(_ updateId: Int?) { stalledConfirmUpdateId = updateId }
    var _svStalledConfirm: Int? { stalledConfirmUpdateId }
    func _svDurabilityTick() async {
        if let stalled = stalledConfirmUpdateId { await retryDurabilityStall(stalled) }
    }
    func _svStallBeganThenRecoveredSynchronously() {
        noteDurabilityStallBegan()
        noteDurabilityStallRecovered()
    }
}

// MARK: - Background archiving selftest seams
//
// Test-only entry points for `__background-archive-selftest` (private
// scratch roots). They read state or call production paths; none replaces
// an implementation.
extension ConversationManager {
    var _baJobOutcome: String? {
        guard let job = archiveJob else { return nil }
        switch job.outcome {
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
    }
    var _baJobStartedAt: Date? { archiveJob?.startedAt }
    var _baJobBatchIds: [UUID] { archiveJob?.batch.map(\.id) ?? [] }
    var _baJobReceipt: PruneArchiveReference? { archiveJob?.receipt }
    var _baJobFrozenLease: UUID? { archiveJob?.frozenView.leaseId }
    var _baBackoffUntil: Date { archiveRetryBackoffUntil }
    var _baExitPending: Bool { archiveExitPending }
    var _baTurnLeaseId: UUID? { turnViewLeaseId }
    var _baGeneration: UInt64 { archiveGeneration }
    var _baMaintenanceKinds: [MaintenanceActivity.Kind] { maintenanceActivities.map(\.kind) }
    var _baRecoveryRunning: Bool { archiveRecoveryTask != nil }
    func _baExecuteMainTool(_ name: String, _ arguments: String) async -> String {
        let call = ToolCall(id: "ba-\(UUID().uuidString.prefix(8))", type: "function", function: FunctionCall(name: name, arguments: arguments))
        return (try? await toolExecutor.execute(call))?.content ?? "<tool threw>"
    }
    func _baCommand(_ text: String) async -> String {
        await handleTerminalCommand(text)?.joined(separator: "\n") ?? ""
    }
    /// `_testStartTurn` with a hook that runs after the user message is
    /// saved and before the turn starts (arms one-shot faults).
    func _baStartTurn(for message: Message, afterSave: () -> Void) {
        messages.append(message)
        _ = saveConversation()
        afterSave()
        startActiveProcessing(for: message)
    }
    func _baScheduleRecovery() {
        scheduleArchiveRecovery(defaultContext: .empty)
    }
    func _baAwaitRecovery() async { await archiveRecoveryTask?.value }
}
