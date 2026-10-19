import Foundation

// Opt-in background pruning (BACKGROUND_PRUNE_PLAN v4.1). Types and pure
// helpers only; every behaviour lives in the marked `ConversationManager`
// extension (region A-EXT), which can reach the manager's private prune
// helpers. Nothing here is reachable from OFF code.

/// Why a running job stopped being usable (§4.1).
enum BackgroundPruneReason: String {
    case stop, off, deadline, generation, abandon, failure
}

/// Owner of one apply (§8.3): the applying run and the apply's own
/// `.pruning` maintenance activity.
struct BackgroundPruneApplyToken: Equatable {
    let id: UUID
    let ownerRunId: UUID
    let activityId: UUID
}

/// The worker's summary (§6.1): `text(nil)` is today's "no summary" (the
/// prune still happens); `cancelled` is never applied.
enum BackgroundPruneSummaryOutcome: Equatable {
    case text(String?)
    case cancelled
}

/// One plan action's descriptions, in today's save order (fallbacks first).
struct BackgroundPruneActionDescriptions: Equatable {
    var fallback: [String: String] = [:]
    var generated: [String: String] = [:]
}

struct BackgroundPruneWorkerResult {
    let summary: BackgroundPruneSummaryOutcome
    let descriptions: [BackgroundPruneActionDescriptions]
}

enum BackgroundPrunePhase {
    case running
    case retiring(BackgroundPruneReason)
    case ready(BackgroundPruneWorkerResult)
    case applying(BackgroundPruneApplyToken)

    var name: String {
        switch self {
        case .running: return "running"
        case .retiring(let reason): return "retiring:\(reason.rawValue)"
        case .ready: return "ready"
        case .applying: return "applying"
        }
    }
}

/// Where the job was frozen; the raw value is today's snapshot trigger.
enum BackgroundPruneSite: String {
    case preRequest = "automatic"
    case midLoop = "mid-turn"
}

/// A plan action as plain values (the manager's `PrunePlan` is private).
struct BackgroundPrunePlanAction: Equatable {
    let isTool: Bool
    let index: Int
    let savedTokens: Int
}

/// Freeze-time values of the summary request (§6.1). `execution` is the
/// context resolved at the freeze (Responses: the turn's; Chat: lane main).
struct BackgroundPruneSummaryInputs {
    let currentTurnInteractions: [ToolInteraction]?
    let tools: [ToolDefinition]
    let calendarContext: String?
    let emailContext: String?
    let chunkSummaries: [ArchivedSummaryItem]
    let totalChunkCount: Int
    let currentUserMessageId: UUID?
    let turnStartDate: Date
    let deferredMCPSummaries: [(name: String, description: String, toolCount: Int)]
    let persona: PromptPersona?
    var execution: ProviderExecutionContext? = nil
}

/// Values captured before the freeze's first await (§5 step 1).
struct BackgroundPruneCapture {
    let runId: UUID
    let generation: UInt64
    let messagesCount: Int
    let messagesLast: UUID?
    let sourceCount: Int
    let sourceLast: UUID?
}

enum BackgroundPruneApplyOutcome: Equatable {
    case applied
    case abandoned(String)
    case revoked
    case cancelled
    case writeFailed
}

/// The last apply's outcome, for exact /stop and OFF replies (§8.3).
struct BackgroundPruneApplyRecord {
    let jobId: UUID
    let outcome: BackgroundPruneApplyOutcome
    let savedDescriptions: Int
    let committed: Bool
}

/// What /stop found (region A-STOP1), worded in A-STOP2.
struct BackgroundPruneStopNote {
    let phase: String
    let jobId: UUID
}

/// Result of the reduction step R (§7.7 step 4). `changed` is the
/// effective-change fact, kept separate from "the inline block ran"
/// (Codex round-4 note 2).
enum BackgroundPruneReduction: Equatable {
    case noChange
    case applied
    case inlineHandled(changed: Bool)

    var changed: Bool {
        switch self {
        case .noChange: return false
        case .applied: return true
        case .inlineHandled(let changed): return changed
        }
    }
}

/// The single background job (§4.1). Main-actor state; one slot.
@MainActor
final class BackgroundPruneJob {
    let id: UUID
    let historyGeneration: UInt64
    let freezeRunId: UUID?
    let site: BackgroundPruneSite
    let frozenPreimage: [Message]
    let source: [Message]
    let summaryRounds: [ToolInteraction]
    let planActions: [BackgroundPrunePlanAction]
    let planBoundary: Int
    let compressedIndices: [Int]
    let safeBoundary: Int
    let anchor: Int
    let manifestIDs: [UUID]
    let triggerMessageID: UUID?
    let snapshotRef: PruneArchiveReference
    let totalTokens: Int
    let targetTokens: Int
    let deadline: ContinuousClock.Instant
    let startedAtWall: Date

    var activityId: UUID?
    var worker: Task<BackgroundPruneWorkerResult, Never>?
    var monitor: Task<Void, Never>?
    var watchdog: Task<Void, Never>?
    var phase: BackgroundPrunePhase = .running
    var workerTerminated = false
    var revoked = false
    var inlineDebtConsumed = false
    var released = false
    var committed = false
    var savedDescriptionCount = 0
    var phaseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(historyGeneration: UInt64, freezeRunId: UUID?, site: BackgroundPruneSite,
         frozenPreimage: [Message], source: [Message], summaryRounds: [ToolInteraction],
         planActions: [BackgroundPrunePlanAction], planBoundary: Int, compressedIndices: [Int],
         safeBoundary: Int, anchor: Int, manifestIDs: [UUID], triggerMessageID: UUID?,
         snapshotRef: PruneArchiveReference, totalTokens: Int, targetTokens: Int,
         deadline: ContinuousClock.Instant) {
        self.id = UUID()
        self.historyGeneration = historyGeneration
        self.freezeRunId = freezeRunId
        self.site = site
        self.frozenPreimage = frozenPreimage
        self.source = source
        self.summaryRounds = summaryRounds
        self.planActions = planActions
        self.planBoundary = planBoundary
        self.compressedIndices = compressedIndices
        self.safeBoundary = safeBoundary
        self.anchor = anchor
        self.manifestIDs = manifestIDs
        self.triggerMessageID = triggerMessageID
        self.snapshotRef = snapshotRef
        self.totalTokens = totalTokens
        self.targetTokens = targetTokens
        self.deadline = deadline
        self.startedAtWall = Date()
    }

    var isApplying: Bool {
        if case .applying = phase { return true }
        return false
    }
    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }
    var isRetiring: Bool {
        if case .retiring = phase { return true }
        return false
    }
    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }
    /// The single predicate /restart and /upgrade use (§4.2).
    var isBusy: Bool { !workerTerminated || isApplying }
}

/// Ceiling arithmetic (§9.1, v4.1): C = min(maximum + 100k, W − 32,768),
/// further lowered by a learned bound for the identity. Saturating, so an
/// absurd stored maximum can never trap (v4.1 review note).
enum BackgroundPruneCeiling {
    static let headroom = 100_000
    static let windowReserve = 32_768
    static let minimumHeadroom = 25_000
    static let metadataAllowance = 4_096

    static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? Int.max : Int.min) : value
    }

    static func saturatingSubtract(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? (b > 0 ? Int.min : Int.max) : value
    }

    static func ceiling(maximum: Int, window: Int?, observed: Int?) -> Int {
        var c = saturatingAdd(maximum, headroom)
        if let window { c = min(c, saturatingSubtract(window, windowReserve)) }
        if let observed { c = min(c, observed) }
        return c
    }

    /// Background work is allowed only with at least 25k of room.
    static func backgroundAllowed(maximum: Int, ceiling: Int) -> Bool {
        saturatingSubtract(ceiling, maximum) >= minimumHeadroom
    }
}

/// Context-window lookup per request identity (§9.2). No catalog value
/// could be verified from provider documentation offline, and 0.2.56 keeps
/// no OpenRouter endpoint-listing cache, so the catalog is empty: every
/// identity is "window unknown" (owner decision Q2: maximum + 100k), and a
/// learned bound (§9.2) can still lower C. `overrides` is a test seam.
enum BackgroundPruneContextWindow {
    static let catalog: [String: Int] = [:]
    nonisolated(unsafe) static var overrides: [String: Int] = [:]

    static func identity(provider: String, profile: String, wire: String, model: String, pin: String) -> String {
        [profile, provider, wire, model, pin].joined(separator: "|")
    }

    static func window(identity: String, model: String) -> Int? {
        overrides[identity] ?? overrides[model] ?? catalog[model.lowercased()]
    }
}

/// §10.2: the exact typed signals that may trigger one in-band reduction
/// and resend. Status alone never qualifies outside the band.
enum BackgroundPruneErrors {
    static func isEligibleInBand(_ error: Error) -> Bool {
        if let failure = error as? ResponsesFailure {
            switch failure {
            case .http(let status, _): return status == 400 || status == 413
            case .failed(let code): return code == "context_length_exceeded"
            default: return false
            }
        }
        if let routerError = error as? OpenRouterError, case .apiError(let description) = routerError {
            return description.hasPrefix("HTTP 400: ") || description.hasPrefix("HTTP 413: ")
        }
        return false
    }
}
