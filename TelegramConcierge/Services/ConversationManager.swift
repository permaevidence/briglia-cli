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

@MainActor
class ConversationManager: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isPolling: Bool = false
    @Published var statusMessage: String = "Not started"
    @Published var error: String?
    @Published var isPrivacyModeEnabled: Bool = false
    
    let telegramService = TelegramBotService()
    let openRouterService = OpenRouterService()
    let toolExecutor = ToolExecutor()
    let archiveService = ConversationArchiveService()
    
    var pollingTask: Task<Void, Never>?
    /// Claimed synchronously at the top of startPolling, before its first
    /// await — closes the reentrancy window that used to let two concurrent
    /// startPolling calls both pass the isPolling guard and run two loops.
    var isStartingPolling = false
    var archiveRecoveryTask: Task<Void, Never>?
    var activeProcessingTask: Task<Void, Never>?
    var subscriptionLoginTask: Task<Void, Never>?
    /// A /subscription login from Telegram is waiting for the user.
    var subscriptionLoginInProgress: Bool { subscriptionLoginTask != nil }
    var subscriptionLoginRunID: UUID?
    var activeRunId: UUID? {
        didSet { isTurnActive = activeRunId != nil }
    }
    /// Published mirror of `activeRunId` so the in-app chat composer can show
    /// a stop control / working indicator while a turn runs.
    @Published private(set) var isTurnActive: Bool = false

    /// What the active turn is doing right now, for the app chat's live
    /// one-line activity indicator: either the model is generating
    /// ("thinking") or a batch of tool calls is executing. `startedAt` resets
    /// on every transition so the UI can show a per-step elapsed counter —
    /// the user always sees that something is moving, even in long turns.
    struct TurnActivity: Equatable {
        enum Kind: Equatable {
            case thinking
            case tools([String])
        }
        let kind: Kind
        let startedAt: Date
    }
    @Published var turnActivity: TurnActivity?

    /// Origin channel of the most recent user message drained into the
    /// current turn's mid-turn queue. The mid_turn_message_user tool prefers
    /// this over the turn's origin: an answer to a mid-turn message belongs
    /// on the channel the user asked from, while progress updates (no
    /// mid-turn message this turn) go to the turn's origin. Reset at turn
    /// start; turns are serialized so a plain var is safe.
    var lastMidTurnUserAddress: ChannelAddress?

    /// Background memory-maintenance work currently in flight, surfaced in the
    /// app chat so the user knows the app is busy (and mustn't be quit).
    /// Multiple operations can overlap — e.g. user-context extraction runs
    /// inside an archive pass.
    struct MaintenanceActivity: Identifiable, Equatable {
        enum Kind: Equatable {
            case summarizingHistory   // archiving old conversation into LTM
            case consolidating        // merging old memory chunks
            case userContext          // learning/reorganizing the user profile
            case pruning              // compressing old tool outputs
        }
        let id: UUID
        let kind: Kind
        let startedAt: Date
    }
    @Published private(set) var maintenanceActivities: [MaintenanceActivity] = []

    // MARK: /stop visibility (STOP_VISIBILITY_PLAN v3 §3) — in memory only

    /// A stopped request whose turn task has not ended yet. Created by the
    /// /stop that captured the running task; `ended` is set only by that
    /// run's single watcher, which then drops the entry. Keyed by run id, so
    /// a newer turn never touches it.
    struct StoppedRunFinishing: Equatable {
        let runId: UUID
        /// Recognises a repeated /stop that reaches the interrupted-turn
        /// marker branch (no envelope checkpoint owner).
        let triggerMessageId: UUID?
        let stoppedAt: Date
        /// A "still finishing" reply was issued for this run.
        var announced = false
        var ended: Date? = nil
        /// At most one completion notice per run (per notice series).
        var completionQueued = false
        /// The run's notice series, one per destination.
        var series: [NoticeSeries.Target: UUID] = [:]
    }
    @Published var stoppedRunsFinishing: [UUID: StoppedRunFinishing] = [:]
    var stoppedRunWatchers: [UUID: Task<Void, Never>] = [:]

    /// What a run is doing, written by the run's own code next to the
    /// existing activity updates and keyed by ITS run id — the only source
    /// used to name a stopped request's remaining work (process-wide
    /// activity can belong to a newer turn).
    enum RunPhase: Equatable {
        case model(Date)
        case tools(callIds: [String], labels: [String], Date)
        case archiveWait(Date)
        // BGPRUNE{ A-CASE
        case pruneWait(Date)
        // }BGPRUNE
    }
    var runPhases: [UUID: RunPhase] = [:]
    // BGPRUNE{ A-STORE
    static let backgroundPruneDefaultsKey = "ada.pruneBackground"
    // Background pruning (BACKGROUND_PRUNE_PLAN v4.1 §4.1): manager-owned
    // state with inert initial values; read only behind backgroundPruneEngaged.
    var backgroundPruneJob: BackgroundPruneJob? = nil
    var backgroundPruneFallbackDue: Bool = false
    var backgroundPruneGeneration: UInt64 = 0
    var backgroundPrunePendingOff: Bool = false
    var backgroundPruneObservedBounds: [String: Int] = [:]
    var backgroundPruneT0AppliedRun: UUID? = nil
    var backgroundPruneRequestLedger: [String: Int] = [:]
    var backgroundPruneCounters: [String: Int] = [:]
    var backgroundPruneLastApply: BackgroundPruneApplyRecord? = nil
    var backgroundPruneStopNote: BackgroundPruneStopNote? = nil
    var backgroundPruneNextRound: [String: Int] = [:]
    // }BGPRUNE

    /// Undeduplicated local notices (terminal and app socket): ordinary /stop
    /// replies of local stops and the ordered follow-ups of local series.
    let stopNoticeEvents = PassthroughSubject<String, Never>()
    /// Every live visibility-notice series (for invalidation).
    var noticeSeriesRegistry: [UUID: NoticeSeries] = [:]
    /// Fingerprint of the Telegram token registered last (a change bumps the
    /// Telegram notice generation).
    var registeredTelegramTokenIdentity: String?
    /// Stage-marker tokens of open archive maintenance phases (diagnostics).
    private var archivePhaseMarkerTokens: [ConversationArchiveService.MaintenancePhase: StageMarkers.Token] = [:]
    /// Test seam: replaces `StageMarkers.openStages()` for attribution.
    nonisolated(unsafe) static var openStagesProviderForTesting: (() -> [(stage: String, callId: String?, tool: String?, elapsedMs: Int)])?

    /// True while a Mind backup is being restored. The poll loop and turn
    /// entry points check this so no channel intake, reminder, background
    /// completion or user turn can run against in-memory state that is about
    /// to be replaced — a turn finishing mid-restore would save the OLD
    /// conversation right over the freshly restored files.
    @Published var isRestoringMind: Bool = false

    /// Transient completion notice for the app UI (e.g. manual prune result).
    /// Auto-clears after a few seconds.
    @Published private(set) var maintenanceNotice: String?
    /// One demotion-snapshot failure notice per episode (Part B §4.4).
    var demotionSnapshotNoticeShown = false
    /// /keepsummaries idle pass: refused/unsupported restores, keyed by
    /// (message id, legacy snapshot id); cleared on history replacement.
    var summaryRestoreAttempts: Set<String> = []
    /// Stub repairs too large for an empty pass, keyed by (message id, digest).
    var summaryStubRepairUnsupported: Set<String> = []
    /// The next pass also checks stub snapshots for completeness (startup
    /// and after a history replacement).
    var summaryRetentionScanPending = true
    var summaryRetentionPassScheduled = false
    private var maintenanceNoticeClearTask: Task<Void, Never>?
    /// Maps archive-service phases to activity ids so begin/end pairs match.
    private var maintenancePhaseActivityIds: [ConversationArchiveService.MaintenancePhase: UUID] = [:]

    @discardableResult
    func beginMaintenance(_ kind: MaintenanceActivity.Kind) -> UUID {
        let activity = MaintenanceActivity(id: UUID(), kind: kind, startedAt: Date())
        maintenanceActivities.append(activity)
        return activity.id
    }

    func endMaintenance(_ id: UUID) {
        maintenanceActivities.removeAll { $0.id == id }
        if maintenanceActivities.isEmpty { scheduleSummaryRetentionIdlePass() }
    }

    func showMaintenanceNotice(_ text: String) {
        maintenanceNoticeClearTask?.cancel()
        maintenanceNotice = text
        maintenanceNoticeClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.maintenanceNotice = nil
        }
    }

    /// Bridge for archive-service maintenance phases (they arrive on the
    /// actor's context via the @Sendable handler, hopped to MainActor here).
    func handleArchiveMaintenancePhase(_ phase: ConversationArchiveService.MaintenancePhase, began: Bool) {
        if began {
            let kind: MaintenanceActivity.Kind
            switch phase {
            case .consolidating: kind = .consolidating
            case .extractingUserContext, .restructuringUserContext: kind = .userContext
            }
            // A phase can re-begin (consolidation loop iterations) — end the
            // stale entry first so the banner never shows duplicates.
            if let stale = maintenancePhaseActivityIds.removeValue(forKey: phase) {
                endMaintenance(stale)
            }
            // Diagnostics only (§5): the re-begin path closes the stale
            // stage marker first, like the stale banner entry above.
            if let staleToken = archivePhaseMarkerTokens.removeValue(forKey: phase) {
                StageMarkers.exit(staleToken, .ok, detail: "re-begin")
            }
            archivePhaseMarkerTokens[phase] = StageMarkers.enter(Self.archivePhaseMarkerName(phase), call: nil)
            maintenancePhaseActivityIds[phase] = beginMaintenance(kind)
        } else {
            if let token = archivePhaseMarkerTokens.removeValue(forKey: phase) {
                StageMarkers.exit(token, .ok)
            }
            if let id = maintenancePhaseActivityIds.removeValue(forKey: phase) {
                endMaintenance(id)
            }
        }
    }

    static func archivePhaseMarkerName(_ phase: ConversationArchiveService.MaintenancePhase) -> String {
        switch phase {
        case .consolidating: return "archive.phase.consolidating"
        case .extractingUserContext: return "archive.phase.extract"
        case .restructuringUserContext: return "archive.phase.restructure"
        }
    }

    /// Per-turn tool-use log. Populated as the tool loop runs; cleared at turn
    /// start. Surfaces via /status so the user can ask "what's going on?"
    /// instead of being bombarded by a progress ping per tool call.
    /// `failed` flips to true when the call's result carries a top-level
    /// "error" key, so /status can mark failed calls with a ❌.
    /// `label` is the display form (`toolLogLabel`): the tool name, or for
    /// Agent calls the subagent's role and description (plan §16.2).
    var currentTurnToolLog: [(id: String, name: String, label: String, startedAt: Date, failed: Bool)] = []
    /// Whether the current log belongs to an actively-running turn or the
    /// most recently completed one. /status uses this to label its output.
    var currentTurnLogIsActive: Bool = false
    /// Accumulates tool interactions for active user-triggered runs so they
    /// can be salvaged on cancellation (/stop). Keying by run id prevents a
    /// cancelled task from clearing or stealing a newer turn's partial work.
    var activeTurnCheckpoints: [UUID: TurnCheckpoint] = [:]
    var checkpointWriteFailure: String?
    var recoveryBlocked = false
    /// Set when conversation.json EXISTS but could not be read or decoded.
    /// A failed load is not an empty history (§3.10.2): while this is set,
    /// nothing may treat the committed view as evidence of absence — job
    /// reconciliation, stop-entry retirement, queue recovery and turn resume
    /// are deferred, removal gates refuse, and no write may replace the
    /// unreadable file (it is preserved for repair). Independent of
    /// `recoveryBlocked`: checkpoint recovery can never clear it. Cleared
    /// only by a successful (re)load — restart after repair, or the file
    /// moved aside — or by an explicit /deleteuserdata reset.
    var historyLoadFailure: String?
    /// One Telegram notice per unreadable-history episode (round 4).
    var historyHoldNoticeSent = false
    /// Set when the held-message queue file (pending_midturn.json) EXISTS
    /// but cannot be read or decoded (stat, permission, read or decode
    /// failure), whether or not history loads (1a round 6): its contents
    /// are acknowledged messages that never reached history, so it is never
    /// deleted or overwritten (`persistPendingMidTurnQueue` backstop), no
    /// new work starts (`workHeldReason`) and new intake is refused (left
    /// unconfirmed / not accepted). Cleared only by a read that also takes
    /// the contents into custody — hydration into memory while history is
    /// unreadable, admission to history at startup recovery — or a
    /// known-absent file, or /deleteuserdata. Never by a history load.
    var heldQueueFileProblem: String?
    /// Why no new work may start (1a rounds 4 and 6): conversation history
    /// or the held-message file exists but cannot be read. Both hold
    /// recovery state that a new turn would bypass or overwrite.
    var workHeldReason: String? {
        if let historyLoadFailure { return "conversation history could not be read (\(historyLoadFailure))" }
        if let heldQueueFileProblem { return "the held-message file could not be read (\(heldQueueFileProblem))" }
        return nil
    }
    var promptEstimateCorrections: [String: Double] = [:]
    var pendingCompactionCalibration: (scope: String, estimated: Int, generation: Int)?
    var latestEstimateScope = ""
    /// User messages that arrived while a turn was already running. They are
    /// delivered to the model at the next tool-round boundary (so it can steer
    /// mid-task) and enter conversation history at that moment; anything still
    /// queued when the turn ends starts a fresh follow-up turn. Messages are
    /// never dropped. Published (read-only) so the app's chat view can render
    /// queued messages immediately — they enter `messages` only when shown to
    /// the model, which can lag the send by a whole tool round.
    @Published var pendingMidTurnMessages: [Message] = []
    /// Narrow failure guard for typed mid-turn deliveries (plan §8 step 14):
    /// the drained batch and its delivery nonce are retained here from the
    /// moment the annotation is attached until a successfully transmitted
    /// request is verified to have actually CARRIED that annotation (checked
    /// by nonce — success of a request that lost the interaction, e.g. via
    /// context-exhaustion discard or a spend-limit force-finish, does not
    /// stand the guard down). Any turn exit that leaves the guard armed —
    /// render abort, cancellation, transport failure, exhaustion — requeues
    /// the batch at teardown so a follow-up turn answers it. Not a durable
    /// exactly-once transaction — that stays with the structural plan
    /// (USER_MESSAGE_AUTHORITY_PLAN.md).
    struct InFlightMidTurnBatch {
        let nonce: String
        let messages: [Message]
    }
    var inFlightMidTurnBatch: InFlightMidTurnBatch? = nil
    /// Ambient triggers (email arrivals) deferred because a run was active.
    /// Kept separate from pendingMidTurnMessages on purpose: mid-turn injection
    /// frames content as the user speaking with full authority, which is wrong
    /// for third-party email bodies, and a [SKIP] decision is only honored when
    /// the turn's trigger message is ambient. These start their own follow-up
    /// turn once the agent goes idle.
    var pendingAmbientTriggers: [Message] = []

    // MARK: Mid-turn early wake state (plan v7, release 1a)
    //
    // Generations are IN MEMORY ONLY (§3.1): the queue file holds plain
    // `Message`s that land in conversation.json unchanged, so nothing new is
    // persisted and history bytes stay the same.

    /// Monotonic generation of every `.userText` enqueued mid-turn, keyed by
    /// message id; ambient kinds never get one. Messages recovered from the
    /// queue file at startup go straight into history (they never need one:
    /// no batch of theirs can be stale).
    var midTurnGeneration: [UUID: UInt64] = [:]
    var nextMidTurnGeneration: UInt64 = 0
    /// Highest generation whose message had entered history when the
    /// current request body was frozen, and the value for the request that
    /// was actually TRANSMITTED (set only after a successful response).
    var appendedMidTurnGeneration: UInt64 = 0
    var seenGenerationAtRequest: UInt64 = 0
    /// Stale-batch suppression flood cap (§3.2): after 3 consecutive
    /// suppressed batches the next one is admitted.
    var consecutiveSuppressions = 0
    static let maxConsecutiveSuppressions = 3
    /// The history exactly as last committed to disk: as loaded, or as
    /// covered by the last successful save / checked rewrite (§3.10.2).
    /// Every durability decision (record settlement, queue-file removal,
    /// stop-entry retirement) consults THIS view, never `messages`, which
    /// can hold appends whose save failed — and whose content, under an
    /// existing id, may differ from what is on disk.
    var committedMessages: [Message] = [] {
        didSet { lastSavedMessageIDs = Set(committedMessages.map(\.id)) }
    }
    /// Ids of `committedMessages` — "durably in history" (mere presence in
    /// `messages` is not).
    var lastSavedMessageIDs: Set<UUID> = []
    /// Completion notices appended but not yet acknowledged: message id →
    /// job. Acknowledged (registry + crash record) only after a save that
    /// carried the message succeeded (§3.10.3).
    var pendingCompletionAcks: [UUID: UUID] = [:]
    /// Subagent completions appended to `messages` awaiting a durable save
    /// (release 1b): message id → the run's job id (nil for an unrecorded
    /// run). Acknowledged in the registry by message id after the save.
    var pendingSubagentAcks: [UUID: UUID?] = [:]
    /// Background results appended to a tool round mid-turn (round delivery
    /// v3 §2.4–§2.5), keyed by completion message id, owned by the run that
    /// appended them. Acknowledged only after a saved history carries them;
    /// the idle drains skip every id listed here.
    var roundDeliveryReservations: [UUID: RoundDeliveryReservation] = [:]
    /// Completion ids acknowledged as delivered mid-turn (inserted when the
    /// reservation turns `.acknowledging`, never removed for the life of
    /// the process). A drain that read the registry queue BEFORE the
    /// withdrawal may resume after the reservation is gone; the delivered
    /// copy lives in a tool result's `deliveredCompletions`, not as a
    /// top-level message id, so this set is what stops it from appending
    /// the same completion again (Codex round-delivery review R1). Tiny
    /// (one UUID per mid-turn delivery) and deliberately kept across Mind
    /// import / data deletion: completion ids are never reused.
    var roundDeliveredIds: Set<UUID> = []
    /// Crash records of acknowledged round deliveries whose `.delivered`
    /// write failed: retried after later saves (startup reconciliation finds
    /// the typed evidence anyway).
    var roundDeliveryRecordRetries: Set<UUID> = []
    /// Runs whose latest plain salvage write failed (checked, not only
    /// logged): their in-progress rounds exist only in memory until the
    /// turn's outcome is saved.
    var turnSalvageWriteFailedRuns: Set<UUID> = []
    /// Plain/envelope salvage writes refused because a newer run owned the
    /// recovery file (diagnostics and selftests).
    var salvageWritesRefusedForOwnership = 0
    /// Items a /stop affected (§3.9.2): their completions and watch matches
    /// are appended to history WITHOUT starting a turn, until settled —
    /// never cleared by a new user turn.
    var stoppedJobIds: Set<UUID> = []
    /// Startup knowledge of earlier /stops, loaded FIRST in init (§3.9.3).
    var stopIntent: StopIntent = .none
    /// A waking item appended by startup job reconciliation; its turn starts
    /// once polling begins.
    var recoveredWakeTrigger: Message?
    /// One maintenance notice per process when a detach record fails.
    var detachRecordFailureShown = false
    var pairedChatId: Int?
    /// The Telegram update_id whose processUpdate call is currently on the
    /// stack. Lets /upgrade — which exec-restarts and never returns — confirm
    /// exactly its own update instead of the whole fetched batch (later
    /// batch updates must re-deliver to the restarted process). nil for
    /// terminal-typed commands.
    var processingTelegramUpdateId: Int?

    // MARK: - Channel routing
    //
    // Outbound messages are routed per-address instead of hardwired to Telegram.
    // Each user message records the channel it arrived on (Message.originChannel);
    // that turn's replies go back there. Ambient output (reminders, email alerts,
    // background completions, status pings) goes to the last active user channel,
    // falling back to the Telegram pairing.
    var channels: [ChannelKind: any ChatChannel] = [:]
    var lastUserChannelAddress: ChannelAddress?
    let lastUserChannelDefaultsKey = "last_user_channel_address"

    /// Whether the Telegram channel was configured at the last configure().
    /// False without a Telegram pairing — the poll loop then skips getUpdates.
    var isTelegramConfigured = false

    /// Replies whose delivery failed after retries, awaiting redelivery.
    /// See `ParkedOutboundQueue` for the reentrancy contract (two callers
    /// can overlap on the main actor: the poll loop's success path and any
    /// successful send).
    let parkedOutbound = ParkedOutboundQueue()

    // MARK: - In-app chat channel

    /// Address for turns started from the app's own chat composer. Never
    /// recorded as `lastUserChannelAddress`: ambient output (reminders, email
    /// alerts, background completions) must keep reaching the user's phone —
    /// it also lands in history, so the app window shows it regardless.
    static let appChannelAddress = ChannelAddress(kind: .app, chatId: "local")

    /// Outcome of an app-composer submission. `.accepted` is a DURABILITY
    /// promise: the message is either persisted in conversation history or in
    /// the mid-turn queue's disk mirror — the socket server acks only on this,
    /// so the app can safely clear its composer.
    enum AppSubmitOutcome {
        case accepted
        /// Accepted AND queued for the running turn (§3.8): the socket ack
        /// gains `"queued_mid_turn": true`, the terminal prints a local dim
        /// status line. Same durability promise as `.accepted`.
        case queuedMidTurn
        /// Durably held (in the mid-turn queue file) because conversation
        /// history could not be read: no turn starts until history loads.
        /// Same durability promise as `.accepted`; the string explains why.
        case heldForRecovery(String)
        case refused(String)
    }

    /// Entry point for the app's chat composer. Copies picked files into the
    /// conversation media folders (originals stay untouched), builds a user
    /// message addressed to the in-app channel, and dispatches it exactly like
    /// a Telegram turn — including mid-turn queueing while a run is active.
    ///
    /// Attachment intake is deliberately paranoid: only regular files are
    /// accepted (revalidated on the OPEN descriptor, so a FIFO or /dev/zero
    /// can neither hang the open nor exhaust memory), and bytes are streamed
    /// off the main actor with the size cap enforced during the copy rather
    /// than trusted from a pre-copy stat.
    /// Attachment acceptance rules per front-end. The app socket keeps its
    /// remote-client discipline (100 MB cap, no empty files — Codex app-chat
    /// rounds 1–2). The local terminal restores its pre-socket semantics:
    /// the user is attaching their own file from their own disk, so there is
    /// no size cap and an empty file is accepted rather than refused —
    /// capping a local /attach was a regression, not a protection
    /// (Codex regression audit, 2026-08-29).
    struct AttachmentPolicy {
        let maxBytes: Int
        let allowEmpty: Bool
        static let appSocket = AttachmentPolicy(
            maxBytes: AppChatSocketServer.maxAttachmentBytes, allowEmpty: false)
        static let terminal = AttachmentPolicy(maxBytes: Int.max, allowEmpty: true)
    }

    /// The exclusive destination create lost the race to a concurrent copy
    /// picking the same name. Not a failure — the caller re-picks and
    /// retries.
    struct CopyDestinationExists: Error {}

    enum AppVoiceTranscriptionError: Error {
        case notConfigured(String)
        case failed(String)

        var userMessage: String {
            switch self {
            case .notConfigured(let reason): return reason
            case .failed(let reason): return "transcription failed: \(reason)"
            }
        }
    }
    
    // Pending media buffer - media is buffered until text triggers processing.
    // Mirrored to pending_attachments.json after every inbound message (a
    // captionless attachment's update is offset-confirmed while its only
    // association lives here — without the mirror, a crash orphaned the
    // downloaded file).
    var pendingImages: [(fileName: String, fileSize: Int)] = []
    var pendingDocuments: [(fileName: String, fileSize: Int)] = []
    var pendingReferencedImages: [(fileName: String, fileSize: Int)] = []
    var pendingReferencedDocuments: [(fileName: String, fileSize: Int)] = []
    var pendingForwardContext: String?
    var pendingReplyContext: String?
    var pendingAttachmentNotes: [String] = []

    /// Set when a durable write backing an inbound message fails (conversation
    /// save, mid-turn queue mirror, attachment-buffer mirror, active-turn
    /// marker). The poll loop then refuses to confirm the update — and every
    /// later update in the same batch, since confirming update N+1 implicitly
    /// confirms N — so a restart re-delivers instead of losing the message to
    /// a disk that was full or read-only at the wrong moment. In-process
    /// handling continues from memory either way.
    var inboundDurabilityFailure = false
    /// Highest processed-but-unconfirmed update id after a durability
    /// failure. While set, Telegram polling PAUSES entirely: the offset
    /// parameter of any getUpdates request is itself the acknowledgment, so
    /// one more fetch at fetchedThroughId+1 would confirm (and server-side
    /// delete) exactly the updates the skipped confirm was protecting. Each
    /// tick retries the writes; when they land, the update is confirmed and
    /// polling resumes. Cleared by restart implicitly (in-memory).
    var stalledConfirmUpdateId: Int? = nil
    var durabilityStallAnnounced = false
    /// The disk-saving pause/recovery notice series (/stop visibility §9,
    /// A3): one ordered series per Telegram chat, reused by consecutive
    /// episodes while it still has notices queued (Codex impl review R2).
    var durabilityStallSeries: NoticeSeries?
    /// A pause notice of the current episode is queued or was sent and its
    /// recovery notice is still owed.
    var durabilityStallPauseOwed = false
    /// The user message whose turn is currently running — lets the stall
    /// recovery recreate a failed active-turn marker for the LIVE turn
    /// before confirming its update.
    var activeTurnTriggerMessage: Message?
    let toolRunLogPrefix = "[TOOL RUN LOG - compact]"
    let maxRetainedToolRunLogs = 5
    let maxAssistantMessageChars = 4000
    /// Undelivered tail of the last truncated assistant reply, served chunk by
    /// chunk via /continue. Replaced (or cleared) whenever a newer visible reply
    /// is recorded — history must only ever contain what actually reached the
    /// user's chat, so an unread tail is dropped once the conversation moves on.
    var pendingContinuationText: String?
    // No per-turn tool-spend cap unless the user sets one (`/spend turn`).
    // The old $0.20 default — an OpenRouter-era safety net — silently cut
    // turns after a single high-quality generated image (≈ $0.19) and was
    // unreachable from the CLI (2026-09-01).
    let minimumToolSpendLimitPerTurnUSD = 0.001
    let shouldResumePollingDefaultsKey = "should_resume_polling_on_launch"
    let privacyModeDefaultsKey = "telegram_privacy_mode_enabled"
    let systemPromptTimestampKey = "system_prompt_cache_epoch"
    let defaultMaxContextTokens = 250_000
    let defaultTargetContextTokens = 70_000

    // Frozen calendar/email context — populated on first turn of a session, refreshed
    // only on Watermark prune events or local-day rollover. Between refreshes, the
    // system-prompt block stays byte-identical so the provider prompt cache holds.
    // New emails arrive as ambient channel messages via the poller; the snapshot in
    // the system prompt is a post-context-loss refresh point, not live awareness.
    var frozenCalendarContext: String?
    var frozenEmailContext: String?
    var frozenContextDay: Date?
    var isRestoringContextUsageSnapshot = false

    /// Actual prompt_tokens from the most recent API response. Used as the
    /// real HIGH watermark trigger for pruning instead of rough estimates.
    /// Also exposed (read-only) to the UI for the context gauge.
    @Published var lastPromptTokens: Int? {
        didSet { saveContextUsageSnapshot() }
    }
    /// The composition key of the request that produced `lastPromptTokens`
    /// (KEEP_SUMMARIES_PLAN §4.4): the measurement is used only under the
    /// same composition. Always assigned BEFORE `lastPromptTokens`, whose
    /// observer then saves both together.
    var lastPromptRenderKey: String = PruneSummaryRetention.emptyRenderKey
    /// Completion tokens from the most recent turn's final API response.
    /// Used to compute per-message measured tokens via delta arithmetic.
    var lastCompletionTokens: Int? {
        didSet { saveContextUsageSnapshot() }
    }

    /// Memoized vision-proxy content hashes, keyed by file identity (path/size/mtime/mime),
    /// so repeated budgeting passes don't re-read and re-base64 the same attachment.
    var budgetContentHashCache: [String: String] = [:]

    struct ContextUsageSnapshot: Codable {
        let lastPromptTokens: Int?
        let lastCompletionTokens: Int?
        let updatedAt: Date
        /// Absent in snapshots written by ≤0.2.57, which never composed
        /// pointers: exactly the empty-set key (§4.4).
        var lastPromptRenderKey: String? = nil
        /// Decoding detail, never encoded: a key of the wrong type.
        var renderKeyUnreadable = false

        enum CodingKeys: String, CodingKey { case lastPromptTokens, lastCompletionTokens, updatedAt, lastPromptRenderKey }

        init(lastPromptTokens: Int?, lastCompletionTokens: Int?, updatedAt: Date, lastPromptRenderKey: String?) {
            self.lastPromptTokens = lastPromptTokens; self.lastCompletionTokens = lastCompletionTokens
            self.updatedAt = updatedAt; self.lastPromptRenderKey = lastPromptRenderKey
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastPromptTokens = try c.decodeIfPresent(Int.self, forKey: .lastPromptTokens)
            lastCompletionTokens = try c.decodeIfPresent(Int.self, forKey: .lastCompletionTokens)
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
            if c.contains(.lastPromptRenderKey) {
                if let key = try? c.decode(String.self, forKey: .lastPromptRenderKey) { lastPromptRenderKey = key }
                else { renderKeyUnreadable = true }
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(lastPromptTokens, forKey: .lastPromptTokens)
            try c.encodeIfPresent(lastCompletionTokens, forKey: .lastCompletionTokens)
            try c.encode(updatedAt, forKey: .updatedAt)
            try c.encodeIfPresent(lastPromptRenderKey, forKey: .lastPromptRenderKey)
        }

        /// The key the loaded measurement may be used under.
        var effectiveRenderKey: String {
            if renderKeyUnreadable { return PruneSummaryRetention.unknownRenderKey }
            guard let key = lastPromptRenderKey else { return PruneSummaryRetention.emptyRenderKey }
            return PruneSummaryRetention.isValidRenderKey(key) ? key : PruneSummaryRetention.unknownRenderKey
        }
    }

    struct ToolAwareResponse {
        let finalText: String
        /// Reasoning emitted alongside the final visible text (no-tool-call
        /// round). Stored on the assistant Message and replayed in history.
        let finalReasoning: JSONValue?
        let finalReasoningDetails: JSONValue?
        /// Model that produced finalReasoning/-Details (nil when no reasoning).
        var finalReasoningModel: String? = nil
        var responsesReplay: ResponsesReplayEnvelope? = nil
        let compactToolLog: String?
        let toolInteractions: [ToolInteraction]
        let accessedProjects: [String]?
        /// Sum of measured token costs across all tool interactions in this turn.
        let measuredToolTokens: Int?
        /// Measured token cost of the user message that triggered this turn,
        /// derived from prompt_tokens delta between turns.
        let measuredUserTokens: Int?
        /// Stored-history token cost for the assistant message: final visible
        /// text plus replayable tool interaction cost.
        let measuredAssistantTokens: Int?
        /// Completion tokens for only the assistant's final visible text.
        /// Unlike measuredAssistantTokens, this excludes replayed tool messages
        /// and is used for next-turn prompt delta attribution.
        let measuredAssistantCompletionTokens: Int?
        /// Absolute paths of pre-existing files modified during the turn (FilesLedger diff).
        let editedFilePaths: [String]
        /// Absolute paths of files newly created during the turn (FilesLedger diff).
        let generatedFilePaths: [String]
        /// Subagent session events that occurred during this turn.
        var subagentSessionEvents: [SubagentSessionEvent]
    }

    enum PruneAction {
        case toolInteractions(index: Int, savedTokens: Int)
        case media(index: Int, savedTokens: Int)

        var index: Int {
            switch self {
            case .toolInteractions(let index, _), .media(let index, _):
                return index
            }
        }

        var savedTokens: Int {
            switch self {
            case .toolInteractions(_, let savedTokens), .media(_, let savedTokens):
                return savedTokens
            }
        }
    }

    struct PrunePlan {
        let actions: [PruneAction]
        let pruningBoundary: Int

        var affectedIndices: [Int] {
            Array(Set(actions.map(\.index))).sorted()
        }

        var toolActionCount: Int {
            actions.filter {
                if case .toolInteractions = $0 { return true }
                return false
            }.count
        }

        var mediaActionCount: Int {
            actions.filter {
                if case .media = $0 { return true }
                return false
            }.count
        }

        var savedTokens: Int {
            actions.reduce(0) { $0 + $1.savedTokens }
        }

        var isEmpty: Bool { actions.isEmpty }
    }

    struct SpendLimitStatus {
        let todaySpentUSD: Double
        let monthSpentUSD: Double
        let dailyBaseLimitUSD: Double?
        let monthlyBaseLimitUSD: Double?
        let dailyExtraUSD: Double
        let monthlyExtraUSD: Double
        /// Tool-charge accounting completeness (mid-turn early wake §3.6.3).
        var accounting = ToolChargeLedger.Snapshot()

        /// A configured daily/monthly cap cannot be verified while accounting
        /// is incomplete: new paid work pauses as if the cap were reached.
        var unverifiable: Bool {
            (dailyBaseLimitUSD != nil || monthlyBaseLimitUSD != nil) && !accounting.isComplete
        }

        var effectiveDailyLimitUSD: Double? {
            dailyBaseLimitUSD.map { $0 + dailyExtraUSD }
        }

        var effectiveMonthlyLimitUSD: Double? {
            monthlyBaseLimitUSD.map { $0 + monthlyExtraUSD }
        }

        var dailyExceeded: Bool {
            effectiveDailyLimitUSD.map { todaySpentUSD >= $0 } ?? false
        }

        var monthlyExceeded: Bool {
            effectiveMonthlyLimitUSD.map { monthSpentUSD >= $0 } ?? false
        }
    }

    let appFolder: URL = {
        let folder = StoragePaths.dataRoot
        try? PrivateStorage.ensureDirectory(folder)
        return folder
    }()
    
    /// Cooldown after the archive gate gives up: while active, turns skip archive
    /// attempts entirely (raw messages stay in context) instead of paying bounded
    /// retries against an API that just failed. Cleared implicitly by time.
    var archiveRetryBackoffUntil: Date = .distantPast

    // MARK: Background archiving (BACKGROUND_ARCHIVE_PLAN v3) — in memory only

    /// The one archive job (running, or finished and not yet committed).
    /// Nothing about it is persisted: after a restart the committed chunk's
    /// still-live messages are found by coverage instead (§6.5).
    struct ArchiveJob {
        enum Outcome: Equatable { case running, failed(Date), succeeded }
        let id: UUID
        let batch: [Message]
        let generation: UInt64
        let startedAt: Date
        /// The view of the turn that started the job: every turn reuses it
        /// until the commit (the new chunk and anything that absorbed it
        /// stay out of automatic context meanwhile).
        let frozenView: ArchivePromptView
        var receipt: PruneArchiveReference?
        var outcome: Outcome = .running
        var task: Task<Void, Never>?
    }
    var archiveJob: ArchiveJob?
    /// Bumped by /deleteuserdata and Mind import: a job of an older
    /// generation is discarded before any commit side effect.
    var archiveGeneration: UInt64 = 0
    /// Set by /restart and /upgrade after their guards; blocks a new job
    /// across their awaits; reset on every path that does not exec (§9).
    var archiveExitPending = false
    /// Lease of the view the current (or last) main turn adopted.
    var turnViewLeaseId: UUID?
    /// Last adopted view, for read-only diagnostics (§4.6).
    var lastTurnArchiveView: ArchivePromptView?

    /// Test seam: runs right after each fresh view capture's await.
    nonisolated(unsafe) static var viewCaptureHookForTesting: (@MainActor (ConversationManager) -> Void)?
    /// Test seam: awaited by the background job before its body runs.
    nonisolated(unsafe) static var backgroundArchiveHoldForTesting: (@Sendable () async -> Void)?
    static let archiveInlineDefaultsKey = "ada.archiveInline"
    /// `/archiveinline on` keeps today's waiting archive; default off
    /// (background for everyone, owner decision D3).
    /// Read through `switchDefaults` like the other chat switches.
    var archiveInlineEnabled: Bool { switchDefaults.bool(forKey: Self.archiveInlineDefaultsKey) }

    /// Consecutive poll-tick failures (getUpdates). At the threshold (~5 min of
    /// solid failures at the 5s retry cadence) a maintenance alert fires.
    var consecutivePollFailures = 0
    /// Last poll-loop error printed to the terminal — dedupes the repeating
    /// failure case so it logs on change, not on every 5s retry.
    var lastLoggedPollError: String? = nil
    static let pollFailureAlertThreshold = 60

    /// The failure counter above is in-memory, but alert-center episodes
    /// persist on disk across restarts. Without a sweep, an episode opened by
    /// a previous process stays open forever (the counter guard never passes)
    /// and a later blip escalates a long-recovered outage. The first healthy
    /// tick after launch closes any such stale episode.
    var staleChannelEpisodeSwept = false

    init() {
        isPrivacyModeEnabled = Prefs.store.bool(forKey: privacyModeDefaultsKey)
        loadConversation()
        // Mid-turn early wake (§3.9.3, §3.10.4): the stop intent is loaded
        // FIRST — nothing is classified or delivered before it. The loaded
        // history is durable by definition (loadConversation sets the
        // committed view from the decoded file).
        loadStopIntent()
        // The held-message file is classified before anything can write it
        // or publish background results (1a round 6): an unreadable file is
        // protected from the first moment.
        if case .unreadable(let reason) = readHeldQueueFile() { setHeldQueueProblem(reason) }
        recoverInterruptedTurnSalvageIfNeeded()
        // Snapshot evidence bookkeeping (§3.12.3): the legacy list exists
        // before any new job or snapshot; orphan sidecars are swept.
        do { try SettlementEvidence.ensureLegacyListInitialized() }
        catch { print("[ConversationManager] Settlement evidence not initialized yet: \(error.localizedDescription)") }
        SettlementEvidence.sweepOrphanSidecars()
        if ForceDetach.isEnabled {
            print("[MidturnWake] ⚠️ \(ForceDetach.environmentKey) is set: every long bash wait and eligible subagent call (not Browse) moves to the background \(Int(TurnWakeCenter.defaultGraceSeconds)) s after it starts (test setting)")
        }
        // The job pass ends canonical recovery, against the history it just
        // saved (deferred while recovery is unresolved).
        reconcileJobRecords()
        loadContextUsageSnapshot()
        loadLastUserChannelAddress()
        loadPendingContinuation()

        // Wire up archive status notifications to the active channel
        let archiveSvc = archiveService
        Task { @MainActor [weak self] in
            guard let self else { return }
            await archiveSvc.setStatusNotificationHandler { [weak self] message in
                Task { @MainActor [weak self] in
                    try? await self?.sendText(message)
                }
            }
            // Typed begin/end phase signals feed the app chat's maintenance
            // banner ("don't quit while I'm archiving").
            await archiveSvc.setMaintenancePhaseHandler { [weak self] phase, began in
                Task { @MainActor [weak self] in
                    self?.handleArchiveMaintenancePhase(phase, began: began)
                }
            }
            // Maintenance alerts report delivery success back so undelivered
            // alerts persist and re-attempt instead of vanishing on a failed send.
            // Single raw channel attempt — deliberately NOT sendText, whose
            // park-on-failure queue would duplicate the alert center's own
            // undelivered persistence.
            await MaintenanceAlertCenter.shared.setDeliveryHandler { [weak self] message in
                guard let self else { return false }
                guard let address = await self.replyAddress,
                      let channel = await self.channels[address.kind] else { return false }
                do {
                    try await channel.sendText(chatId: address.chatId, text: message)
                    return true
                } catch {
                    return false
                }
            }
            // Proactive low-credit warnings for the metered web services
            // (OpenRouter / Serper / Jina). Same delivery contract as the
            // maintenance alerts: undelivered warnings persist and re-attempt.
            await BalanceMonitor.shared.setDeliveryHandler { [weak self] message in
                guard let self else { return false }
                guard let address = await self.replyAddress,
                      let channel = await self.channels[address.kind] else { return false }
                do {
                    try await channel.sendText(chatId: address.chatId, text: message)
                    return true
                } catch {
                    return false
                }
            }
            await BalanceMonitor.shared.start()
        }

        if shouldResumePollingOnLaunch && hasRequiredPollingConfiguration() {
            Task { [weak self] in
                await self?.startPolling()
            }
        }
    }

    func currentVoiceTranscriptionProvider() -> VoiceTranscriptionProvider {
        VoiceTranscriptionProvider.fromStoredValue(
            KeychainHelper.load(key: KeychainHelper.voiceTranscriptionProviderKey)
        )
    }

    func openAITranscriptionAPIKey() -> String {
        (KeychainHelper.load(key: KeychainHelper.openAITranscriptionApiKeyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func configuredGeminiImageModel() -> String {
        let configuredModel = (KeychainHelper.load(key: KeychainHelper.geminiImageModelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configuredModel.isEmpty ? GeminiImagePricing.defaultModel : configuredModel
    }

    func configuredGeminiImagePricing() -> GeminiImagePricing {
        func configuredRate(for key: String, defaultValue: Double) -> Double {
            guard let rawValue = KeychainHelper.load(key: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = Double(rawValue),
                  parsed.isFinite,
                  parsed >= 0 else {
                return defaultValue
            }
            return parsed
        }

        return GeminiImagePricing(
            inputCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.inputCostPerMillionTokensUSD
            ),
            outputTextCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.outputTextCostPerMillionTokensUSD
            ),
            outputImageCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.outputImageCostPerMillionTokensUSD
            )
        )
    }
    
    // MARK: - Message Processing

    /// Telegram's Bot API refuses getFile downloads above 20 MB; larger files never reach the bot.
    static let telegramBotDownloadLimitBytes = 20 * 1024 * 1024

    /// Handled unreadable-message keys (update id, chat+message id, chat+album
    /// id): a redelivered update or a second album item gets no second reply.
    /// Bounded; only consulted by the unreadable-message reply, so it can
    /// never suppress any other processing.
    var unreadableReplyKeys: [String] = []
    static let unreadableReplyKeyLimit = 512

    /// Shown to the user (once per episode on Telegram; on every app/terminal
    /// submission) when a message is held because history can't be read.
    /// Shown when a message is refused because the held-message file (earlier
    /// unanswered messages) exists but can't be read (1a round 6).
    static let heldQueueRefusalNotice = "⚠️ I can't read the file of messages you sent earlier that I haven't answered yet, so I'm not accepting new messages or starting any work — nothing in that file is overwritten. Repair pending_midturn.json (or move it aside), then /restart; /deleteuserdata discards it. /status shows the details."
    var heldQueueRefusalNoticeSent = false

    static let historyHoldNotice = "⚠️ I can't read my conversation history, so I'm not starting any work. Your message is saved and will be answered once the history loads again: repair the conversation file (or move it aside), then /restart. /status shows the details."

    static let notExecutedResultContent = #"{"status":"not_executed","reason":"a user message arrived before this batch started — read it below and re-issue this call if it is still wanted"}"#

    /// Cache diagnosis bookkeeping (main lane): the previous request's tool
    /// signature and frozen system-prompt date.
    var cacheDiagnosticsToolSignature: String?
    var cacheDiagnosticsSystemDate: Date?

    /// Selftest seam: observe the commit's save boundaries ("afterCheckpoint",
    /// "afterConversation") to capture the on-disk state a crash would leave.
    nonisolated(unsafe) static var imageRejectionBoundaryForTesting: ((String) -> Void)?

    /// Selftest seam: throw to simulate a failed Responses salvage write —
    /// stage "placeholder" (before the batch runs) or "completed" (after).
    nonisolated(unsafe) static var responsesSalvageFaultForTesting: ((String) throws -> Void)?

    enum QueueFileState {
        case absent
        case readable([Message])
        case unreadable(String)
    }

    enum TurnMarkerState {
        case absent
        case readable(ActiveTurnMarker)
        case unreadable
    }

    /// Selftest seam: while set, the non-empty queue write fails before
    /// touching the file (as a failed atomic write does).
    nonisolated(unsafe) static var heldQueueWriteFaultForTesting = false

    // MARK: - Pending attachment buffer persistence

    struct PendingFileRecord: Codable {
        let fileName: String
        let fileSize: Int
    }

    struct PendingInboundBuffers: Codable {
        var images: [PendingFileRecord]
        var documents: [PendingFileRecord]
        var referencedImages: [PendingFileRecord]
        var referencedDocuments: [PendingFileRecord]
        var forwardContext: String?
        var replyContext: String?
        var attachmentNotes: [String]

        var isEmpty: Bool {
            images.isEmpty && documents.isEmpty && referencedImages.isEmpty
                && referencedDocuments.isEmpty && forwardContext == nil
                && replyContext == nil && attachmentNotes.isEmpty
        }
    }

    // MARK: - Active-turn marker (power-failure resume)

    struct ActiveTurnMarker: Codable {
        let triggerMessageId: UUID
        let startedAt: Date
    }
    
    /// Response collector for ONE local command invocation (terminal REPL or
    /// app socket). Task-local, so concurrent commands each capture only the
    /// sends made from their own task — ambient sends from unrelated tasks
    /// (reminder fires, watcher notices) are never swallowed, and two clients
    /// issuing commands at once cannot mix responses. `close()` ends the
    /// window: a straggler task that inherited the task-local (unstructured
    /// Tasks copy it at creation) falls through to normal delivery.
    @MainActor
    final class CommandResponseCapture {
        private(set) var lines: [String] = []
        private(set) var isOpen = true
        /// Returns whether the line was captured (false once closed).
        func append(_ line: String) -> Bool {
            guard isOpen else { return false }
            lines.append(line)
            return true
        }
        func close() { isOpen = false }

        /// /stop visibility (§4.2): follow-ups that must come AFTER this
        /// command's result wait until the caller handed the result to its
        /// client (`markDelivered`).
        private var deliveredHandlers: [() -> Void] = []
        private(set) var isDelivered = false
        func onDelivered(_ handler: @escaping () -> Void) {
            if isDelivered { handler() } else { deliveredHandlers.append(handler) }
        }
        func markDelivered() {
            guard !isDelivered else { return }
            isDelivered = true
            let handlers = deliveredHandlers
            deliveredHandlers = []
            for handler in handlers { handler() }
        }
    }
    @TaskLocal static var commandCapture: CommandResponseCapture?

    /// Proposed-but-unconfirmed `/setname` value. In-memory only on
    /// purpose: the confirmation exists to catch fat-thumbed sends, not to
    /// survive restarts — re-proposing after a restart costs one message.
    var pendingUserNameProposal: String?

    /// Proposed-but-unconfirmed `/importmind` target. In-memory only on
    /// purpose (same rationale as pendingUserNameProposal): the confirmation
    /// exists to catch fat-thumbed sends, not to survive restarts.
    /// The fingerprint pins the confirmation to the archive the user
    /// actually inspected (Codex, 2026-08-27): if the file is swapped for a
    /// different valid .mind between proposal and confirm, the import
    /// refuses instead of silently restoring the replacement.
    struct PendingMindImport {
        let path: String
        let exportDate: Date
        let sha256: String
        let bytes: Int64
    }
    var pendingMindImport: PendingMindImport?

    // MARK: - /switchbot (move Briglia to a different Telegram bot)

    /// In-flight `/switchbot` state. In-memory only on purpose: the flow is
    /// short (10-minute discovery window) and interactive, the old bot stays
    /// fully functional until the final confirm, and after a restart the user
    /// simply re-runs the command — nothing durable is at stake before the
    /// cutover, which persists atomically.
    struct PendingBotSwitch {
        let newToken: String
        let botDisplay: String
        let code: String
        var discovered: BotSwitchFlow.DiscoveredChat?
        /// Set by the idle-guarded confirm; the poll loop executes the actual
        /// cutover at its next clean boundary (see performPendingBotSwitchIfReady).
        var readyForCutover = false
        /// When the code arrived; an unconfirmed switch expires after
        /// `BotSwitchFlow.confirmTimeoutSeconds` (it holds the bot's
        /// reservation and blocks `profiles add`; Codex stage-1 note 3).
        var discoveredAt: Date?
        var reminded = false
    }
    var pendingBotSwitch: PendingBotSwitch? {
        // Clearing the switch (cancel, timeout, failure, cutover) drops this
        // process's hold on machine/identity-tx.lock (MULTI_ASSISTANT_PLAN
        // §5.6, Codex stage-1 R2) and aborts its registry reservation (a
        // committed one was finished at cutover); a still-running discovery
        // task keeps its own reference until its last request returns.
        didSet {
            if pendingBotSwitch == nil {
                botSwitchTicket?.abort()
                botSwitchTicket = nil
                botSwitchIdentityLock = nil
            }
        }
    }
    /// The /switchbot reservation (multi mode; nil otherwise).
    var botSwitchTicket: IdentityChange.Ticket?
    /// Notes of the last /deleteuserdata (shared ChatGPT login, §25.6).
    var lastWipeNotes: [String] = []
    /// Default's hold on machine/identity-tx.lock for the lifetime of a
    /// /switchbot (nil when no switch is pending, and always nil in extras).
    var botSwitchIdentityLock: ProfileFileLock?
    var botSwitchDiscoveryTask: Task<Void, Never>?
    /// True while performPendingBotSwitchIfReady() executes. The cutover
    /// awaits network sends after committing credentials, and the reentrant
    /// MainActor lets other-surface commands interleave there — this flag
    /// makes every /switchbot variant refuse until the cutover concludes.
    var botSwitchCutoverInProgress = false

    static let durabilityStallEntryText = "⚠️ I can't save to disk right now, so I've paused reading new Telegram messages. New Telegram messages and commands will wait until saving works again; the terminal and app still accept /stop. I'll tell you when saving works again."
    static let durabilityStallRecoveryText = "✅ Saving works again; I'm reading Telegram messages again."

    static let validReasoningEfforts = ["minimal", "low", "medium", "high", "xhigh"]


    /// Bumped by every routing-relevant settings write this manager makes
    /// (/model, /provider hop, /orprovider set/release, pin release on
    /// revalidation). `/orprovider` and the /model revalidation await a
    /// network listing; a write that lands during that await (another
    /// channel, the app socket, a menu tap) makes the pending decision
    /// stale, so both compare this generation — plus the stored model and
    /// pin, which also catch edits from outside this process — before they
    /// commit (Codex R3, 2026-09-19).
    var modelRoutingGeneration = 0

    // MARK: D10 upgrade-preset pass

    /// Owned by the running manager (only the process that polls runs it).
    var upgradePresetPass: OpenRouterUpgradePass?
    /// Shown once by /status after the pass committed an outcome.
    var pendingHostNotice: String?
    
    /// Selftest seam: runs between the registry cutoffs and the final
    /// run-identity check of /stop (simulates main-actor work interleaving
    /// at those awaits, e.g. an idle drain starting a turn).
    nonisolated(unsafe) static var stopCutoffInterleaveForTesting: (@MainActor () async -> Void)?

    // MARK: - /stop visibility (STOP_VISIBILITY_PLAN v3)

    /// Test seam (SV10d): runs synchronously right after a "still
    /// finishing" decision was delivered. nil in production.
    nonisolated(unsafe) static var afterStopDecisionForTesting: (@MainActor (ConversationManager, UUID) -> Void)?

    static let stopBashConfirmSeconds: TimeInterval = 3
    /// A repeated /stop whose request ended during its wait (Codex impl
    /// review R1): the run's completion follows on the same surface…
    static let repeatEndedWithCompletionLead = "⛔ Already stopping."
    /// …or, with no reserved place, the reply itself says it ended.
    static let repeatEndedLead = "⛔ Already stopping; the stopped request has now ended."
    static let stopTurnObserveSeconds: TimeInterval = 2.5

    /// A repeated /stop's reserved place in its run's ordered notices.
    enum RepeatSlot {
        /// Captured command window: the run's local series holds every
        /// later item until the command's own result was handed over.
        case capture
        /// A reserved position in a wire or local series.
        case series(NoticeSeries, UUID)
    }

    /// Ids of series that gave up (kept so a run never restarts them).
    var gaveUpNoticeSeries: Set<UUID> = []

    // MARK: - /stop dispositions (mid-turn early wake §3.9)

    /// Unsettled /stop entries of this process (and those loaded at start).
    var stopEntries: [StopEntry] = []
    /// Background subagents running when /stop ran: their (cancelled)
    /// completions are appended without waking.
    var stoppedSubagentHandles: Set<String> = []

    // MARK: /keepsummaries idle pass (KEEP_SUMMARIES_PLAN §5.2, §5.3, §6)

    /// What one idle pass did (tests and logs).
    struct SummaryRetentionPassReport: Equatable {
        var blocked: String? = nil
        var stubsRepaired = 0
        var restored = 0
        var refused = 0
        var deferred = 0
        var bytes = 0
        var measurementClearFailed = false
        var historyWriteFailed = false
    }

    /// Result of a mid-loop pruning attempt.
    enum MidLoopPruneResult {
        /// Context is within budget — no pruning needed.
        case underBudget
        /// Pruning occurred and freed some space.
        case pruned
        /// Context exceeds the budget but nothing is left to prune.
        case exhausted
    }

    // MARK: - Compressible synthetic-user-message pruning

    /// The set of message kinds that the Watermark pruner is allowed to collapse
    /// into a one-line stub. Hard constraint: `.userText` is deliberately NOT in
    /// this set — everything else is synthetic and safe to compact.
    static let compressibleSyntheticKinds: Set<MessageKind> = [
        .emailArrived, .subagentComplete, .reminderFired, .bashComplete
    ]
    nonisolated static let compressibleSyntheticKindsList: Set<MessageKind> = [
        .emailArrived, .subagentComplete, .reminderFired, .bashComplete
    ]
    
    // MARK: - Reminder Processing

    /// Watcher checks currently running in a background task, keyed by
    /// reminder id. The row is advanced before dispatch so a re-run can't be
    /// scheduled anyway; this set is a belt-and-braces guard for the window
    /// where a check outlives its polling interval.
    var watcherChecksInFlight: Set<UUID> = []
    /// LAST-RESORT fallback only: watcher outcomes whose durable outbox
    /// write FAILED (disk trouble). Normal watcher fires flow through
    /// `FireOutbox`; these in-memory messages exist so a fire still reaches
    /// the agent even when the outbox cannot be written — accepting, for
    /// that degraded case, the old crash-loss window.
    var pendingWatcherFireMessages: [Message] = []

    /// Cap on individually listed events in one external fire message; a
    /// larger batch is summarized with head + tail so a runaway caller can't
    /// flood the context (payloads are already capped at intake).
    static let externalEventsShownPerFire = 30

    // MARK: - Watcher triage dispatch

    /// Triage lanes with a run currently executing. Per-session
    /// serialization layer one: the dispatcher never starts a second run for
    /// a lane while one is in flight (SubagentSessionLocks additionally
    /// serializes against main-agent resumes of the same session).
    var triageRunsInFlight: Set<String> = []
    /// Test seam: shortens the bounded triage-quiescence waits in the wipe
    /// and the Mind-import barrier so their abort paths don't stall the
    /// selftest suite for the real 10s deadline.
    var triageQuiesceTimeoutForTesting: Double?
    /// Lane → last run start. The session-level window (§5 layer 1): the
    /// first fire after a quiet period triages immediately (leading edge);
    /// further fires — including fires from OTHER watchers sharing the lane
    /// — stay queued in the outbox and are drained together by ONE run when
    /// the window closes. This is the group-level durable aggregator: the
    /// outbox is the pending-fires queue, filtered by lane.
    var lastTriageRunStart: [String: Date] = [:]

    /// Pure routing decision for an arrived-email event, extracted so the
    /// selftest can pin the matrix — above all that a wipe/restore in
    /// progress refuses delivery as NOT durable no matter what else holds
    /// (Codex round 8: a handler suspended across the wipe's buffer clears
    /// must not append pre-wipe mail to history or start a turn mid-wipe).
    enum EmailDeliveryRoute: Equatable {
        case refuseNotDurable
        case nothingToDeliver
        case deferToAmbientQueue
        case startTurn
    }

    struct HistoryUnreadable: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Conversation history could not be read (\(reason)); it is preserved for repair and will not be overwritten"
        }
    }

    /// Selftest seam: throw to simulate a failed plain salvage write.
    nonisolated(unsafe) static var plainSalvageFaultForTesting: (() throws -> Void)?
    /// Selftest seam: throw to simulate a failed history write (before the
    /// file is touched, as a failed atomic write leaves it).
    nonisolated(unsafe) static var historyWriteFaultForTesting: (() throws -> Void)?
    /// /keepsummaries K8b: fault points of the durable measurement clear
    /// ("before-write", "after-rename"). Test-only.
    nonisolated(unsafe) static var usageClearFaultForTesting: ((String) throws -> Void)?
    /// The idle pass runs from its triggers unless a selftest turns it off
    /// to drive it explicitly. Always true in production.
    nonisolated(unsafe) static var summaryRetentionIdlePassEnabled = true
    /// /keepsummaries K7: observes each request view as it is built. Test-only.
    nonisolated(unsafe) static var requestViewObserverForTesting: ((ComposedHistory) -> Void)?
    /// Selftest seam: throw to simulate a failed turn-checkpoint write.
    nonisolated(unsafe) static var checkpointWriteFaultForTesting: (() throws -> Void)?
    /// Selftest seam: throw AFTER the history file was replaced (a failed
    /// post-rename fsync: the disk holds the new state, the call fails).
    nonisolated(unsafe) static var historyPostWriteFaultForTesting: (() throws -> Void)?
    /// Selftest seams (summary retention Part B).
    nonisolated(unsafe) static var beforePruneHistoryWriteForTesting: (() -> Void)?
    nonisolated(unsafe) static var afterDemotionSnapshotForTesting: ((PruneArchiveReference) -> Void)?
    nonisolated(unsafe) static var coverageRecordingDisabledForTesting = false

    /// Outcome of a full Mind import, for the /importmind handler to map to
    /// user-facing strings. The distinction that matters: every case except
    /// `.failedApply` leaves current data untouched; `.failedApply` can only
    /// come from applyStagedMind, where partial replacement is possible.
    enum MindImportOutcome: Equatable {
        /// Imported. `pausedWatchers` = scripted watchers quarantined for
        /// review (untrusted archives can carry executable check scripts).
        case success(pausedWatchers: Int)
        /// A turn or memory maintenance is running — nothing was touched.
        case refusedGate
        /// Producers would not quiesce (reason inside) — nothing was touched.
        case refusedBusy(String)
        /// Stage/validate error (localized description) — nothing was touched.
        case rejectedArchive(String)
        /// applyStagedMind error: the replacement may be partial.
        case failedApply(String)
        /// The session-affinity write after quiescence failed (plan §8):
        /// nothing was discarded or replaced; the old Mind is intact.
        /// `affinityAdvanced` says whether the new main conversation ID is
        /// nevertheless in place (post-rename directory-fsync failure).
        case failedBeforeApply(String, affinityAdvanced: Bool)
    }

    /// Gate a Mind restore against everything that could write memory state
    /// back to disk mid-import. Returns false (and restores nothing) if a
    /// turn is running or memory maintenance is in flight — the caller shows
    /// the user why. On success the poll loop idles and new turns are
    /// refused until `endMindRestore()`.
    var browserSettingsMutation = false
    /// Upgrade barrier (MULTI_ASSISTANT_PLAN §6.4): new work is not admitted
    /// while parked for an update. Reversible; never touches the polling
    /// preference.
    var admissionPaused = false
    var upgradeMonitorTask: Task<Void, Never>?
    /// The barrier this assistant is parked for (nil = not parked).
    var upgradeParkedFor: String?
    var browserSettingsPollIngress = 0
    var browserSettingsAppIngress = 0
    var browserSettingsCommandIngress = 0

    /// The email provider and AgentMail account the running pollers were
    /// started for. nil = not started by this process yet.
    struct AppliedEmailState: Equatable {
        var provider: EmailCalendarProvider
        var agentMailKey: String
        var inbox: String
        static var current: AppliedEmailState {
            AppliedEmailState(provider: EmailCalendarProvider.current,
                              agentMailKey: AgentMailService.apiKey() ?? "",
                              inbox: EmailCalendarProvider.agentMailInboxAddress)
        }
    }
    var appliedEmailState: AppliedEmailState?

    // MARK: - Truncated-reply continuation (/continue)

    /// UTF-16 headroom kept for the truncation notice and the continuation
    /// prefix, so a chunk plus its decorations never exceeds the channel limit.
    static let continuationNoticeReserve = 150

    enum ArchiveCommitStep: Equatable { case committed, deferred, failed }

    static let keepSummariesCostLine = "More summaries = larger context: each is ~1.3–2.7k tokens (10 ≈ 15–25k, 20 ≈ 30–50k)."

    /// Limits for the file-description API call made at prune time.
    static let descriptionMaxPDFPages = 10
    static let descriptionMaxFiles = 8
    static let descriptionMaxFileSizeBytes = 5 * 1024 * 1024 // 5 MB

    /// Tools whose output files deserve a persisted description. Everything
    /// else (read_file, grep, etc.) is transient working data that doesn't
    /// need a natural-language summary.
    static let describableToolNames: Set<String> = [
        "generate_image", "edit_image", "run_shortcut", "send_document_to_chat"
    ]
}

/// `/spend <scope> <usd|off>` parsing — pure, so the selftest pins it.
enum SpendLimitCommand {
    enum Scope: String, CaseIterable {
        case turn, daily, monthly
        var label: String {
            switch self {
            case .turn: return "Per-turn"
            case .daily: return "Daily"
            case .monthly: return "Monthly"
            }
        }
        var noun: String {
            switch self {
            case .turn: return "per-turn"
            case .daily: return "daily"
            case .monthly: return "monthly"
            }
        }
    }
    struct Edit: Equatable {
        let scope: Scope
        /// nil = remove the limit.
        let limitUSD: Double?
    }
    struct ParseError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    static let minimumUSD = 0.001
    static let usage = "Set with /spend turn|daily|monthly <usd|off> (e.g. /spend daily 5, /spend turn off). /more1 /more5 /more10 raise a reached daily/monthly limit for today/this month only."

    static func parse(_ argument: String) -> Result<Edit, ParseError> {
        let parts = argument.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 2 else {
            return .failure(ParseError("Expected a scope and a value."))
        }
        guard let scope = Scope(rawValue: parts[0].lowercased()) else {
            return .failure(ParseError("Unknown scope '\(parts[0])' — use turn, daily or monthly."))
        }
        let raw = parts[1].lowercased()
        if ["off", "none", "unlimited", "0"].contains(raw) {
            return .success(Edit(scope: scope, limitUSD: nil))
        }
        var number = raw
        if number.hasPrefix("$") { number.removeFirst() }
        if number.hasSuffix("$") { number.removeLast() }
        number = number.replacingOccurrences(of: ",", with: ".")
        guard let usd = Double(number), usd.isFinite else {
            return .failure(ParseError("'\(parts[1])' is not an amount in USD."))
        }
        guard usd >= minimumUSD else {
            return .failure(ParseError("The minimum is $\(storedValue(minimumUSD)); use `off` to remove the limit."))
        }
        return .success(Edit(scope: scope, limitUSD: usd))
    }

    /// Plain decimal text, never locale-formatted — the store is parsed with Double().
    static func storedValue(_ usd: Double) -> String {
        var text = String(format: "%.3f", usd)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
