import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// User-profile maintenance with edit operations (USER_CONTEXT_EDIT_OPS_PLAN
/// v6 + v6.1). Replaces the old full-profile rewrite: the model sees the
/// profile as numbered facts and replies with `drop` / `edit` / `add`
/// operations; Briglia applies them, untouched lines stay byte-identical, and
/// every removed or replaced original goes word for word into
/// `retired_user_facts.jsonl` before the profile is swapped.
///
/// Runs only from the archive service at the position of the old rewrite
/// retry (after extraction and its backlog, before consolidation) and at
/// startup recovery — both already inside the archive operation that
/// `/deleteuserdata`, Mind import and export wait for.
enum UserContextMaintenanceEvent: String {
    case archive
    case startupRecovery
}

struct UserContextMaintenancePolicy {
    var thresholdChars = 40_000
    var targetChars = 30_000
    var maxPasses = 2
    var deferralGrowthBase = 4_000
    var deferralGrowthMax = 32_000
    var deferralExponentMax = 3
    var maxModelSendsPerRun = 6
    var maxAuthRequestsPerRun = 2
    var attemptsPerPass = 3
    /// Pause before the 2nd and 3rd attempt of a pass (the archive lane's
    /// existing 2 s / 4 s backoff).
    var attemptDelays: [TimeInterval] = [2, 4]

    static let standard = UserContextMaintenancePolicy()

    /// Transient failures: 1 h, 6 h, then 24 h.
    func transientBackoff(count: Int) -> TimeInterval {
        switch count {
        case ...1: return 3600
        case 2: return 6 * 3600
        default: return 24 * 3600
        }
    }
    let deterministicBackoff: TimeInterval = 24 * 3600

    /// Growth the profile must show past `sizeAtDeferral` before a
    /// non-converging threshold run may repeat: 4k, 8k, 16k, then 32k.
    func growth(consecutive: Int) -> Int {
        let exponent = min(max(consecutive - 1, 0), deferralExponentMax)
        let (shifted, overflow) = deferralGrowthBase.multipliedReportingOverflow(by: 1 << exponent)
        return overflow ? deferralGrowthMax : min(shifted, deferralGrowthMax)
    }
}

/// `~/.local/share/briglia/archive/user_context_state.json` (§7.1).
struct UserContextMaintenanceState: Equatable {
    enum Cleanup: String { case pending, done }
    enum Reason: String { case threshold, cleanup, failureRetry }
    enum FailureKind: String { case transient, deterministic }

    struct Deferral: Equatable { var sizeAtDeferral: Int; var consecutive: Int; var at: Date }
    struct Failure: Equatable { var kind: FailureKind; var count: Int; var nextEligibleAt: Date }
    struct Attempt: Equatable { var startedAt: Date; var reason: Reason }

    var cleanupV1: Cleanup = .pending
    var deferral: Deferral? = nil
    var failure: Failure? = nil
    var attempt: Attempt? = nil

    static let version = 1

    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    func encoded() throws -> Data {
        let f = Self.formatter()
        var object: [String: Any] = ["version": Self.version, "cleanupV1": cleanupV1.rawValue]
        object["deferral"] = deferral.map { ["sizeAtDeferral": $0.sizeAtDeferral, "consecutive": $0.consecutive, "at": f.string(from: $0.at)] as [String: Any] } ?? NSNull()
        object["failure"] = failure.map { ["kind": $0.kind.rawValue, "count": $0.count, "nextEligibleAt": f.string(from: $0.nextEligibleAt)] as [String: Any] } ?? NSNull()
        object["attempt"] = attempt.map { ["startedAt": f.string(from: $0.startedAt), "reason": $0.reason.rawValue] as [String: Any] } ?? NSNull()
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        data.append(0x0A)
        return data
    }

    struct Damaged: Error { let reason: String }

    /// Strict decode: anything unexpected is damage, never a default.
    static func decode(_ data: Data) throws -> UserContextMaintenanceState {
        guard let text = String(data: data, encoding: .utf8) else { throw Damaged(reason: "not UTF-8") }
        let value: StrictJSON.Value
        do { value = try StrictJSON.parse(text) } catch { throw Damaged(reason: "not valid JSON (\(error))") }
        guard case .object(let pairs) = value else { throw Damaged(reason: "not a JSON object") }
        let fields = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        guard case .int(let version)? = fields["version"] else { throw Damaged(reason: "missing version") }
        guard version == Self.version else { throw Damaged(reason: "unknown version \(version)") }
        var state = UserContextMaintenanceState()
        let f = formatter()
        func date(_ v: StrictJSON.Value?, _ name: String) throws -> Date {
            guard case .string(let s)? = v, let d = f.date(from: s), d.timeIntervalSince1970.isFinite else {
                throw Damaged(reason: "invalid \(name)")
            }
            return d
        }
        func int(_ v: StrictJSON.Value?, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
            guard case .int(let i)? = v, range.contains(i) else { throw Damaged(reason: "invalid \(name)") }
            return i
        }
        func object(_ v: StrictJSON.Value?) -> [String: StrictJSON.Value]? {
            guard case .object(let p)? = v else { return nil }
            return Dictionary(p, uniquingKeysWith: { a, _ in a })
        }
        func isAbsent(_ v: StrictJSON.Value?) -> Bool {
            if v == nil { return true }
            if case .null? = v { return true }
            return false
        }
        if let raw = fields["cleanupV1"] {
            guard case .string(let s) = raw, let c = Cleanup(rawValue: s) else { throw Damaged(reason: "invalid cleanupV1") }
            state.cleanupV1 = c
        }
        if !isAbsent(fields["deferral"]) {
            guard let d = object(fields["deferral"]) else { throw Damaged(reason: "invalid deferral") }
            state.deferral = Deferral(sizeAtDeferral: try int(d["sizeAtDeferral"], "deferral.sizeAtDeferral", 0...Int(Int32.max)),
                                      consecutive: try int(d["consecutive"], "deferral.consecutive", 1...1_000_000),
                                      at: try date(d["at"], "deferral.at"))
        }
        if !isAbsent(fields["failure"]) {
            guard let d = object(fields["failure"]) else { throw Damaged(reason: "invalid failure") }
            guard case .string(let k)? = d["kind"], let kind = FailureKind(rawValue: k) else { throw Damaged(reason: "invalid failure.kind") }
            state.failure = Failure(kind: kind, count: try int(d["count"], "failure.count", 1...1_000_000),
                                    nextEligibleAt: try date(d["nextEligibleAt"], "failure.nextEligibleAt"))
        }
        if !isAbsent(fields["attempt"]) {
            guard let d = object(fields["attempt"]) else { throw Damaged(reason: "invalid attempt") }
            guard case .string(let r)? = d["reason"], let reason = Reason(rawValue: r) else { throw Damaged(reason: "invalid attempt.reason") }
            state.attempt = Attempt(startedAt: try date(d["startedAt"], "attempt.startedAt"), reason: reason)
        }
        return state
    }
}

enum UserContextStateLoad: Equatable {
    case absent
    case valid(UserContextMaintenanceState)
    case damaged(String)
}

/// Optional fault-injection and clock seams; nil (always, outside the
/// selftest) = production behaviour.
struct UserContextMaintenanceHooks {
    var now: (() -> Date)? = nil
    /// The time zone the run's date is rendered in (v6.4); nil = current.
    var timeZone: TimeZone? = nil
    var beforeStateWrite: (() throws -> Void)? = nil
    var beforeRetiredAppend: (() throws -> Void)? = nil
    var afterRetiredAppend: (() throws -> Void)? = nil
    var beforeProfileCommit: (() throws -> Void)? = nil
    /// Runs after the snapshot read, before the model request (I1/I4).
    var afterSnapshot: ((Int) async -> Void)? = nil
    /// Receives each completed run's report (the developer preview).
    var onReport: ((UserContextMaintenanceReport) -> Void)? = nil
}

/// What one maintenance run did; also the source of the telemetry line.
struct UserContextMaintenanceReport {
    enum Outcome: Equatable {
        case completed
        case failed(UserContextMaintenanceState.FailureKind, String)
        case conflict
        case cancelled
    }
    var reason: UserContextMaintenanceState.Reason
    var outcome: Outcome = .completed
    /// Size of the shared archive context block sent (0 = none).
    var sharedContextChars = 0
    var passes = 0
    var sends = 0
    var authRequests = 0
    var seconds: Double = 0
    var passSeconds: [Double] = []
    var promptTokens = 0
    var completionTokens = 0
    var sizeBefore = 0
    var sizeAfter = 0
    var charsDropped = 0
    var charsEditedDelta = 0
    var charsAdded = 0
    var opsApplied = 0
    var opsIgnored: [String] = []
    var finishReasons: [String] = []
    var drops: [(content: String, section: String, pass: Int)] = []
    var edits: [(old: String, new: String, section: String, pass: Int)] = []
    var adds: [(line: String, pass: Int)] = []
}

/// Process-local maintenance memory held by the archive actor.
final class UserContextMaintenanceRuntime {
    /// A state write failed in this process: no run until one succeeds again.
    var suppressed = false
    /// The authoritative state while suppressed (its write failed).
    var inMemoryState: UserContextMaintenanceState?
    var damaged = false
    var damagedAlerted = false
    var storageAlerted = false
    var legacyFlagRemoved = false
    /// A run is in flight in this process (both entry points already hold
    /// the archive's chunk writer; this is a second, local guard).
    var running = false
}

enum UserContextMaintenance {
    /// The v0.2.48 rewrite-retry flag. Never read; removed from the
    /// preference domain on the first successful state load.
    static let legacyRetryFlagKey = "ada.archive.restructureRetryPending"
    static let stateFileName = "user_context_state.json"

    static var stateURL: URL {
        StoragePaths.dataRoot.appendingPathComponent("archive", isDirectory: true).appendingPathComponent(stateFileName)
    }

    nonisolated(unsafe) static var testPolicy: UserContextMaintenancePolicy?
    nonisolated(unsafe) static var testHooks: UserContextMaintenanceHooks?

    static var policy: UserContextMaintenancePolicy { testPolicy ?? .standard }
    static func now() -> Date { testHooks?.now?() ?? Date() }
    static func timeZone() -> TimeZone { testHooks?.timeZone ?? TimeZone.current }

    /// v6.4: the run's local date for the upcoming-events rule, e.g.
    /// "Sunday, 4 October 2026 (Europe/Rome, UTC+02:00)". Built from
    /// calendar components (no DateFormatter, no locale), so it is the same
    /// on every platform and language setting.
    static func todayLine(now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let months = ["January", "February", "March", "April", "May", "June", "July",
                      "August", "September", "October", "November", "December"]
        let weekday = weekdays[min(max((c.weekday ?? 1) - 1, 0), 6)]
        let month = months[min(max((c.month ?? 1) - 1, 0), 11)]
        let seconds = timeZone.secondsFromGMT(for: now)
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        let offset = "UTC\(sign)\(String(format: "%02d:%02d", minutes / 60, minutes % 60))"
        return "\(weekday), \(c.day ?? 1) \(month) \(c.year ?? 0) (\(timeZone.identifier), \(offset))"
    }

    static func loadState(at url: URL = stateURL) -> UserContextStateLoad {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT { return .absent }
            return .damaged("cannot be inspected: \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .damaged("not a regular file") }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .damaged("unreadable: \(error.localizedDescription)") }
        do { return .valid(try UserContextMaintenanceState.decode(data)) }
        catch let damaged as UserContextMaintenanceState.Damaged { return .damaged(damaged.reason) }
        catch { return .damaged("\(error)") }
    }

    static func writeState(_ state: UserContextMaintenanceState, to url: URL = stateURL) throws {
        try testHooks?.beforeStateWrite?()
        try PrivateStorage.ensureDirectory(url.deletingLastPathComponent())
        try PrivateStorage.writeAtomically(try state.encoded(), to: url, mode: 0o600)
    }

    static func growthGateOpen(_ deferral: UserContextMaintenanceState.Deferral?, size: Int,
                               policy: UserContextMaintenancePolicy) -> Bool {
        guard let deferral else { return true }
        let (needed, overflow) = deferral.sizeAtDeferral.addingReportingOverflow(policy.growth(consecutive: deferral.consecutive))
        return size >= (overflow ? Int.max : needed)
    }

    /// §7.6: deterministic = retrying the same request cannot succeed.
    static func classify(_ error: Error) -> UserContextMaintenanceState.FailureKind {
        let deterministicStatuses: Set<Int> = [400, 401, 402, 403, 404, 405, 413, 422]
        if let archive = error as? ArchiveError {
            switch archive {
            case .notConfigured: return .deterministic
            case .apiHTTPError(let status, _): return deterministicStatuses.contains(status) ? .deterministic : .transient
            default: return .transient
            }
        }
        if case ResponsesFailure.http(let status, _) = ProviderImageRejection.unwrap(error) {
            return deterministicStatuses.contains(status) ? .deterministic : .transient
        }
        if error is SubscriptionError || error is ConfigurationError { return .deterministic }
        return .transient
    }

    struct ConfigurationError: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "provider configuration: \(reason)" }
    }

    struct ToolCallReply: Error, LocalizedError {
        var errorDescription: String? { "the model replied with tool calls (tools are disabled for this request)" }
    }

    struct CutOffReply: Error, LocalizedError {
        let finishReason: String
        var errorDescription: String? { "the provider cut the reply off (finish_reason: \(finishReason))" }
    }

    struct CommitConflict: Error, LocalizedError {
        var errorDescription: String? { "the profile changed while the model was answering" }
    }

    // MARK: - Prompt (§5, v6.1)

    static func systemPrompt(document: UserProfileDocument, assistantName: String, userName: String,
                             policy: UserContextMaintenancePolicy, pass: Int,
                             now: Date = UserContextMaintenance.now(),
                             timeZone: TimeZone = UserContextMaintenance.timeZone()) -> String {
        let size = document.characterCount
        let over = max(size - policy.targetChars, 0)
        let status = pass == 1
            ? "Profile: \(grouped(size)) characters, \(document.factCount) facts. Aim for about \(grouped(policy.targetChars)) characters. Don't go much below it: removing a lasting fact just to save space is worse than staying near the target."
            : "Still \(grouped(over)) characters above the target of about \(grouped(policy.targetChars)) (profile now \(grouped(size)) characters, \(document.factCount) facts). Remove more of what does not serve the profile's purpose, but don't go much below the target."
        return """
        You maintain the user profile that an AI assistant keeps about the user.

        What the profile is for: it is included in the assistant's context on every turn, so the assistant always knows the lasting facts about the user — who they are, the people in their life (family, friends, colleagues, with names and relationships), their life situation, their ongoing projects, and their persistent preferences and ways of working. It is not a record of tasks. Recent work is already visible to the assistant through the conversation itself and its summaries, and older work stays in the long-term archive (chunk summaries and raw transcripts), which the assistant can search whenever it needs details. So results of one-off research, task details, prices, logistics, version histories and anything finished or no longer true do not belong here, however detailed or carefully written they are.

        Nothing removed here is lost: every fact you remove or shorten is also kept word for word in a retired-facts file.

        If an ARCHIVE MEMORY CONTEXT with previous conversation summaries appears above, use it only to judge what still matters to the user: topics the user keeps returning to are lasting; one-off searches or tasks that were never mentioned again are not. Its USER PROFILE copy may be older than the numbered PROFILE below, which is the one you edit. Take every fact and edit only from the PROFILE below; never add anything from the summaries.

        Go through the whole profile and remove or shorten what does not serve that purpose. Prefer removing whole topics that are finished or tied to one task before trimming single facts. A finished one-off investigation or task goes entirely: don't keep a one-line summary of it; it stays in the archive. A topic that keeps coming back in the summaries because the user is still working on it is not finished. Keep upcoming commitments and events until their date has passed; today's date is given below, and if an event's date is unclear, don't assume it has passed. Keep facts about people, relationships, life context and persistent preferences, even when they are short or old. Use your judgment.

        Each fact is shown as `[id] (length) text`. Lines starting with `#` are section headings; they are structure, not facts. A section left empty is removed automatically.

        TODAY: \(todayLine(now: now, timeZone: timeZone))

        IDENTITY (current, authoritative):
        Assistant name: \(assistantName.isEmpty ? "not specified" : assistantName)
        User name: \(userName.isEmpty ? "not specified" : userName)

        PROFILE
        \(document.numberedListing())
        END PROFILE

        \(status)

        What counts is the size of the WHOLE profile after all your operations, so what you drop and shorten must outweigh what you add.

        Reply with one JSON object and nothing else: {"drop":[ids],"edit":[{"id":id,"text":"..."}],"add":[{"text":"...","after":id}]}. `drop` removes facts. `edit` replaces a fact's text (without its bullet) with a shorter version. `add` adds a new one-line fact; to group several facts, drop them and add one fact that covers them. `after` is optional. Facts you don't mention stay exactly as they are.
        """
    }

    static let userPrompt = "Return the JSON operations for the profile above."

    static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out += "," }
            out.append(character)
        }
        return (value < 0 ? "-" : "") + out
    }

    // MARK: - Doctor

    struct DoctorFinding { let text: String; let problem: Bool; let hint: String? }

    static func doctorFindings(profileSize: Int, url: URL = stateURL,
                               policy: UserContextMaintenancePolicy = .standard, now: Date = Date()) -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        let sizeText = "profile \(grouped(profileSize)) characters (maintenance above \(grouped(policy.thresholdChars)), aims for ~\(grouped(policy.targetChars)))"
        switch loadState(at: url) {
        case .damaged(let reason):
            findings.append(DoctorFinding(text: "user profile maintenance: state file damaged (\(reason)): \(url.path)", problem: true,
                hint: "Profile cleanup is paused; new facts are still learned. Move the file aside or delete it (or ask the assistant to); maintenance restarts from defaults at the next archive. /deleteuserdata also clears it."))
            findings.append(DoctorFinding(text: sizeText, problem: false, hint: nil))
        case .absent:
            findings.append(DoctorFinding(text: "user profile maintenance: no state yet (one-time cleanup pending); " + sizeText, problem: false, hint: nil))
        case .valid(let state):
            var parts = [sizeText, "one-time cleanup \(state.cleanupV1.rawValue)"]
            if let deferral = state.deferral {
                parts.append("deferred after \(deferral.consecutive) non-converging run\(deferral.consecutive == 1 ? "" : "s"); next at \(grouped(deferral.sizeAtDeferral + policy.growth(consecutive: deferral.consecutive))) characters")
            }
            if let failure = state.failure {
                let wait = failure.nextEligibleAt.timeIntervalSince(now)
                parts.append("\(failure.kind.rawValue) failure ×\(failure.count), " + (wait > 0 ? "next try in \(Int(wait / 60)) min" : "retry due at the next archive"))
            }
            if state.attempt != nil { parts.append("an interrupted run will count as one failure") }
            findings.append(DoctorFinding(text: "user profile maintenance: " + parts.joined(separator: "; "), problem: false, hint: nil))
        }
        if RetiredUserFacts.hasRecords() {
            findings.append(DoctorFinding(text: "retired facts kept in \(RetiredUserFacts.url.path)", problem: false, hint: nil))
        }
        return findings
    }
}

// MARK: - The run (actor-isolated: extraction's load → append → save has no
// await, so nothing in this actor can interleave with it; other writers are
// caught by the commit's compare-and-swap under the secrets flock).

extension ConversationArchiveService {

    /// The ordered decision procedure (§7.2) and, when it says so, one run.
    func maintainUserContextIfNeeded(event: UserContextMaintenanceEvent, sharedContext: SummarizationContext? = nil) async {
        let runtime = userContextMaintenanceRuntime
        guard !runtime.running else { return }
        runtime.running = true
        defer { runtime.running = false }
        let policy = UserContextMaintenance.policy
        let now = UserContextMaintenance.now()

        // 1. State health (re-read at every event; repair = fresh defaults).
        var state: UserContextMaintenanceState
        switch UserContextMaintenance.loadState() {
        case .damaged(let reason):
            runtime.damaged = true
            if !runtime.damagedAlerted {
                runtime.damagedAlerted = true
                let path = UserContextMaintenance.stateURL.path
                print("[ArchiveService] User profile maintenance paused: state file damaged (\(reason)): \(path)")
                await MaintenanceAlertCenter.shared.reportFailure(.userContextRestructure,
                    error: "The profile-maintenance state file can't be read (\(reason)): \(path). Profile cleanup is paused; new facts are still learned. To recover, move the file aside or delete it — or ask me to — and maintenance restarts from defaults at the next archive",
                    deterministic: true)
            }
            return
        case .absent:
            state = UserContextMaintenanceState()
        case .valid(let loaded):
            state = loaded
        }
        if runtime.damaged {
            runtime.damaged = false
            runtime.damagedAlerted = false
            print("[ArchiveService] User profile maintenance: state file readable again; maintenance resumes")
            await MaintenanceAlertCenter.shared.reportSuccess(.userContextRestructure)
        }
        if !runtime.legacyFlagRemoved {
            UserDefaults.standard.removeObject(forKey: UserContextMaintenance.legacyRetryFlagKey)
            runtime.legacyFlagRemoved = true
        }

        // 2. Process-local suppression after a failed state write: one local
        // write per archive event, never a model call while it persists.
        if runtime.suppressed {
            guard event == .archive else { return }
            let authoritative = runtime.inMemoryState ?? state
            guard await persistMaintenanceState(authoritative) else { return }
            runtime.suppressed = false
            runtime.inMemoryState = nil
            state = authoritative
        }

        // 3. An interrupted attempt (crash or kill mid-run) is one transient failure.
        if state.attempt != nil {
            let count = (state.failure?.count ?? 0) + 1
            state.failure = .init(kind: .transient, count: count, nextEligibleAt: now.addingTimeInterval(policy.transientBackoff(count: count)))
            state.attempt = nil
            print("[ArchiveService] User profile maintenance: an earlier run was interrupted — counted as a transient failure (#\(count))")
            guard await persistMaintenanceState(state) else { return }
        }

        // 4. Failure gate: before every trigger, whatever the size.
        var failureDue = false
        if let failure = state.failure {
            if now < failure.nextEligibleAt { return }
            if failure.kind == .deterministic && event == .startupRecovery { return }
            failureDue = true
        }

        // 5. Need.
        let size = (KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? "").count
        let cleanupTrigger = state.cleanupV1 == .pending && size > policy.targetChars
        let thresholdTrigger = size > policy.thresholdChars
            && UserContextMaintenance.growthGateOpen(state.deferral, size: size, policy: policy)
        var trigger = cleanupTrigger || thresholdTrigger
        if event == .startupRecovery && !failureDue { trigger = false }   // size alone never runs at startup
        guard trigger else {
            var updated = state
            if size <= policy.thresholdChars { updated.failure = nil; updated.deferral = nil }
            if size <= policy.targetChars { updated.cleanupV1 = .done }
            if updated != state { _ = await persistMaintenanceState(updated) }
            return
        }

        // 6. Run. The attempt record is durable before any model call; if
        // it cannot be written, no model call happens and the state without
        // the attempt stays authoritative in memory.
        let reason: UserContextMaintenanceState.Reason = failureDue ? .failureRetry : (cleanupTrigger ? .cleanup : .threshold)
        let beforeAttempt = state
        state.attempt = .init(startedAt: now, reason: reason)
        guard await persistMaintenanceState(state, authoritativeOnFailure: beforeAttempt) else { return }

        maintenancePhase(.restructuringUserContext, true)
        let shared = sharedContext.flatMap { maintenanceSharedContextPrompt(for: $0) }
        if shared == nil {
            print("[ArchiveService] User profile maintenance: no shared archive context available (\(event.rawValue)); running on the profile alone")
        }
        let report = await runUserContextMaintenance(reason: reason, policy: policy, sharedContextPrompt: shared)
        maintenancePhase(.restructuringUserContext, false)
        UserContextMaintenance.testHooks?.onReport?(report)
        logMaintenanceReport(report)

        let end = UserContextMaintenance.now()
        state.attempt = nil
        var alert: (String, Bool)? = nil
        var recovered = false
        switch report.outcome {
        case .completed:
            state.failure = nil
            state.cleanupV1 = .done
            if report.sizeAfter <= policy.thresholdChars {
                state.deferral = nil
                recovered = true
            } else {
                let consecutive = (state.deferral?.consecutive ?? 0) + 1
                state.deferral = .init(sizeAtDeferral: report.sizeAfter, consecutive: min(consecutive, 1_000_000), at: end)
                if consecutive >= 2 {
                    alert = ("the user profile stays above its \(UserContextMaintenance.grouped(policy.thresholdChars))-character maintenance threshold after \(consecutive) runs (now \(UserContextMaintenance.grouped(report.sizeAfter))); it will be tried again once it has grown further. Nothing is lost: removed facts are in the retired-facts file", false)
                }
            }
        case .failed(let kind, let why):
            let count = min((state.failure?.count ?? 0) + 1, 1_000_000)
            let wait = kind == .deterministic ? policy.deterministicBackoff : policy.transientBackoff(count: count)
            state.failure = .init(kind: kind, count: count, nextEligibleAt: end.addingTimeInterval(wait))
            alert = (why, kind == .deterministic)
        case .conflict, .cancelled:
            break
        }
        _ = await persistMaintenanceState(state)
        if let alert {
            await MaintenanceAlertCenter.shared.reportFailure(.userContextRestructure, error: alert.0, deterministic: alert.1)
        } else if recovered {
            await MaintenanceAlertCenter.shared.reportSuccess(.userContextRestructure)
        }
    }

    /// Checked state write. A failure suppresses runs in this process
    /// (the in-memory state stays authoritative) and alerts once.
    private func persistMaintenanceState(_ state: UserContextMaintenanceState,
                                         authoritativeOnFailure: UserContextMaintenanceState? = nil) async -> Bool {
        let runtime = userContextMaintenanceRuntime
        do {
            try UserContextMaintenance.writeState(state)
            if runtime.storageAlerted {
                runtime.storageAlerted = false
            }
            return true
        } catch {
            runtime.suppressed = true
            runtime.inMemoryState = authoritativeOnFailure ?? state
            print("[ArchiveService] User profile maintenance: state write failed (\(error.localizedDescription)); no maintenance request until a state write succeeds")
            if !runtime.storageAlerted {
                runtime.storageAlerted = true
                await MaintenanceAlertCenter.shared.reportFailure(.userContextRestructure,
                    error: "the profile-maintenance state could not be saved (\(error.localizedDescription)) at \(UserContextMaintenance.stateURL.path); profile cleanup is paused in this session",
                    deterministic: false)
            }
            return false
        }
    }

    /// At most `maxPasses` passes; every model send and login refresh
    /// counted at the transport; never a loop.
    private func runUserContextMaintenance(reason: UserContextMaintenanceState.Reason,
                                           policy: UserContextMaintenancePolicy,
                                           sharedContextPrompt: String?) async -> UserContextMaintenanceReport {
        var report = UserContextMaintenanceReport(reason: reason)
        report.sharedContextChars = sharedContextPrompt?.count ?? 0
        let started = Date()
        // v6.4: one date for the whole run (every pass and retry).
        let runNow = UserContextMaintenance.now()
        let runTimeZone = UserContextMaintenance.timeZone()
        let budget = SendBudget(limit: policy.maxModelSendsPerRun)
        let auth = SendBudget(limit: policy.maxAuthRequestsPerRun, exhausted: { AuthBudgetExhausted(limit: $0) })
        let assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? ""
        let userName = KeychainHelper.load(key: KeychainHelper.userNameKey) ?? ""
        report.sizeBefore = (KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? "").count
        func finish(_ outcome: UserContextMaintenanceReport.Outcome) -> UserContextMaintenanceReport {
            report.outcome = outcome
            report.sends = budget.consumed
            report.authRequests = auth.consumed
            report.seconds = Date().timeIntervalSince(started)
            report.sizeAfter = (KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? "").count
            return report
        }

        for pass in 1...max(policy.maxPasses, 1) {
            let passStarted = Date()
            let snapshot = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
            if pass > 1 && snapshot.count <= policy.targetChars { break }
            let document = UserProfileDocument(snapshot)
            if document.factCount == 0 { break }   // only structure: nothing a model could change
            report.passes = pass
            await UserContextMaintenance.testHooks?.afterSnapshot?(pass)
            let system = UserContextMaintenance.systemPrompt(document: document, assistantName: assistantName,
                                                             userName: userName, policy: policy, pass: pass,
                                                             now: runNow, timeZone: runTimeZone)
            var operations: UserProfileDocument.Operations?
            var lastError: Error?
            var failureKind: UserContextMaintenanceState.FailureKind = .transient
            attempts: for attempt in 1...max(policy.attemptsPerPass, 1) {
                if budget.remaining == 0 { lastError = SendBudgetExhausted(limit: budget.limit); break }
                if attempt > 1 {
                    let delay = policy.attemptDelays.indices.contains(attempt - 2) ? policy.attemptDelays[attempt - 2] : (policy.attemptDelays.last ?? 0)
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                }
                if Task.isCancelled { return finish(.cancelled) }
                do {
                    let reply = try await maintenanceModelCall(systemPrompt: system, userPrompt: UserContextMaintenance.userPrompt,
                                                               sharedContextPrompt: sharedContextPrompt,
                                                               budget: budget, authBudget: auth)
                    report.promptTokens += reply.promptTokens ?? 0
                    report.completionTokens += reply.completionTokens ?? 0
                    if let finish = reply.finishReason { report.finishReasons.append(finish) }
                    if CompactionSummaryPolicy.isCutOff(reply.finishReason) {
                        throw UserContextMaintenance.CutOffReply(finishReason: reply.finishReason ?? "")
                    }
                    operations = try UserProfileDocument.parseReply(reply.text, factCount: document.factCount)
                    break attempts
                } catch is CancellationError {
                    return finish(.cancelled)
                } catch {
                    if Task.isCancelled { return finish(.cancelled) }
                    lastError = error
                    print("[ArchiveService] User profile maintenance pass \(pass) attempt \(attempt) failed: \(error)")
                    if UserContextMaintenance.classify(error) == .deterministic { failureKind = .deterministic; break attempts }
                    if error is SendBudgetExhausted || error is AuthBudgetExhausted { break attempts }
                }
            }
            guard let operations else {
                report.passSeconds.append(Date().timeIntervalSince(passStarted))
                let why = lastError.map { ($0 as? LocalizedError)?.errorDescription ?? "\($0)" } ?? "no usable reply"
                return finish(.failed(failureKind, why))
            }
            let result = document.apply(operations)
            report.opsIgnored += result.ignored
            if result.changed {
                do {
                    try commitUserContext(result, expected: snapshot, pass: pass)
                } catch is UserContextMaintenance.CommitConflict {
                    report.passSeconds.append(Date().timeIntervalSince(passStarted))
                    print("[ArchiveService] User profile maintenance pass \(pass): the profile changed while the model answered — nothing saved; next eligible archive retries")
                    return finish(.conflict)
                } catch {
                    report.passSeconds.append(Date().timeIntervalSince(passStarted))
                    return finish(.failed(.transient, "could not save the maintained profile: \(error.localizedDescription)"))
                }
                report.charsDropped += result.charsDropped
                report.charsEditedDelta += result.charsEditedDelta
                report.charsAdded += result.charsAdded
                report.opsApplied += result.appliedDrops + result.appliedEdits + result.appliedAdds
                report.drops += result.drops.map { ($0.content, $0.section, pass) }
                report.edits += result.edits.map { ($0.old, $0.new, $0.section, pass) }
                report.adds += result.addedLines.map { ($0, pass) }
            }
            report.passSeconds.append(Date().timeIntervalSince(passStarted))
            if result.sizeAfter <= policy.targetChars { break }
        }
        return finish(.completed)
    }

    /// §10.2: fresh read == snapshot, retired lines appended and fsynced,
    /// then the profile swapped by compare-and-swap under the secrets flock.
    /// Every fact is always in the profile, the retired file, or both.
    private func commitUserContext(_ result: UserProfileDocument.Result, expected snapshot: String, pass: Int) throws {
        let key = KeychainHelper.structuredUserContextKey
        guard (KeychainHelper.load(key: key) ?? "") == snapshot else { throw UserContextMaintenance.CommitConflict() }
        let hooks = UserContextMaintenance.testHooks
        try hooks?.beforeRetiredAppend?()
        try RetiredUserFacts.append(RetiredUserFacts.records(from: result.retired, pass: pass, at: UserContextMaintenance.now()))
        try hooks?.afterRetiredAppend?()
        try hooks?.beforeProfileCommit?()
        try KeychainHelper.transaction { store in
            guard (store[key] ?? "") == snapshot else { throw UserContextMaintenance.CommitConflict() }
            store[key] = result.text
        }
    }

    private func logMaintenanceReport(_ r: UserContextMaintenanceReport) {
        let outcome: String
        switch r.outcome {
        case .completed: outcome = "completed"
        case .failed(let kind, let why): outcome = "failed-\(kind.rawValue) (\(why))"
        case .conflict: outcome = "conflict"
        case .cancelled: outcome = "cancelled"
        }
        let passTimes = r.passSeconds.map { String(format: "%.1f", $0) }.joined(separator: "/")
        print("[ArchiveService] User profile maintenance: reason=\(r.reason.rawValue) passes=\(r.passes) sends=\(r.sends) auth=\(r.authRequests) seconds=\(String(format: "%.1f", r.seconds)) pass_seconds=\(passTimes.isEmpty ? "-" : passTimes) tokens_in=\(r.promptTokens) tokens_out=\(r.completionTokens) size=\(r.sizeBefore)->\(r.sizeAfter) dropped_chars=\(r.charsDropped) edit_saved_chars=\(r.charsEditedDelta) added_chars=\(r.charsAdded) ops_applied=\(r.opsApplied) ops_ignored=\(r.opsIgnored.count) shared_context_chars=\(r.sharedContextChars) outcome=\(outcome)")
    }
}
