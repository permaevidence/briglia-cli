import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// gws-backed data source for email/calendar ambient context and the unread-email poller.
///
/// Wraps the `gws` (Google Workspace CLI) subprocess. Exposes the same two system-prompt
/// context builders that EmailService / CalendarService used to expose, formatted
/// byte-identically so the frozen-context cache in ConversationManager continues to
/// hit. Also owns the 5-minute background poller for unread mail — it queries
/// `is:unread` so mail the user has already dismissed on another device does not
/// re-trigger ambient notifications.
///
/// All gws calls run with retry + graceful fallback: if the binary is missing or
/// every attempt fails, the context builders return "" and the poller silently
/// no-ops. The turn never breaks on a missing CLI.
actor GoogleWorkspaceService {
    static let shared = GoogleWorkspaceService()

    // MARK: - Public types

    struct UnreadEmail: Codable, Sendable, Equatable {
        let id: String
        let threadId: String?
        let from: String
        let subject: String
        let date: String
        let snippet: String
    }

    // MARK: - State

    private var cachedUnread: [UnreadEmail] = []
    private var lastSuccessfulFetch: Date?

    /// Watermark for the arrival-notification poll. Gmail's `after:<epoch>` only
    /// returns messages delivered strictly after that timestamp, so we use this
    /// as a high-water mark and advance it after each successful poll. On a
    /// failed poll we leave it alone so the window widens to cover the gap.
    /// Nil before the first successful poll — initialized to startBackgroundPoll
    /// time so we don't notify on pre-existing unread mail at launch.
    private var lastArrivalPollTime: Date?

    /// Defense-in-depth dedupe across overlapping window edges (`after:` is
    /// inclusive of second-boundary matches in practice). Bounded to last 200.
    private var recentlyNotifiedIds: [String] = []

    private var pollerTask: Task<Void, Never>?
    /// Bumped by start/stop/resetForWipe. Every operation captures it on
    /// entry and re-checks it after each await before touching caches,
    /// watermarks or the delivery handler, so a gws subprocess that outlives
    /// a provider switch (they ignore task cancellation) finishes inertly —
    /// its result is dropped, it launches no retry, and nothing reaches the
    /// agent (Codex, menu round 3).
    private var stateEpoch: UInt64 = 0
    func stateEpochForTesting() -> UInt64 { stateEpoch }
    /// Test seam: replaces the gws arrival query (no subprocess, no Gmail).
    private var arrivalFetchForTesting: (@Sendable (Int) async -> [UnreadEmail]?)?
    func setArrivalFetchForTesting(_ fetch: (@Sendable (Int) async -> [UnreadEmail]?)?) { arrivalFetchForTesting = fetch }
    /// Test seam: replaces every gws subprocess (args in, result out).
    private var runGwsForTesting: (@Sendable ([String]) async -> ProcessRunResult)?
    func setRunGwsForTesting(_ run: (@Sendable ([String]) async -> ProcessRunResult)?) { runGwsForTesting = run }
    /// Test seam: the maintenance counter the late-result rows check.
    func consecutiveFailuresForTesting() -> Int { consecutiveGwsFailures }
    func setConsecutiveFailuresForTesting(_ n: Int) { consecutiveGwsFailures = n }
    /// Test seam: one real snapshot fetch (retries + outcome), epoch-stamped.
    func fetchUnreadSnapshotForTesting() async -> [UnreadEmail]? {
        await trackedOp { await fetchUnreadSnapshotWithRetry(epoch: stateEpoch) }
    }
    /// One real poll tick (tracked, epoch-stamped) on demand.
    func pollOnceForTesting() async { await pollOnce() }
    func arrivalWatermarkForTesting() -> Date? { lastArrivalPollTime }
    /// Returns whether the event was made durable — the gws poller ignores
    /// it (its watermark is in-memory only, so a crash naturally redelivers),
    /// but the shared handler signature lets the AgentMail poller gate its
    /// persisted checkpoint on it.
    private var newEmailHandler: (@Sendable ([UnreadEmail]) async -> Bool)?

    /// Calendar context cache with day-rollover semantics, mirroring the old
    /// CalendarService behavior. The cached string stays valid until either the
    /// frozen-context helper forces a refresh or the local day changes.
    private var cachedCalendarContext: String?
    private var cachedCalendarDay: Date?

    private let pollIntervalSeconds: UInt64 = 300
    private let maxUnread = 10
    private let agendaDaysAhead = 30

    // MARK: - Public API — polling lifecycle

    func setNewEmailHandler(_ handler: @escaping @Sendable ([UnreadEmail]) async -> Bool) {
        newEmailHandler = handler
    }

    /// Memoized per process: is gws installed AND authorized? Checked once
    /// via `gws auth status` (local, no network). An installed-but-
    /// unauthorized gws must NOT enable polling or context building — every
    /// fetch would fail, burning ~3s retry ladders per prompt build and
    /// eventually raising "run gws auth login" maintenance alerts for a tool
    /// the user never finished setting up. Authorizing (or installing) later
    /// takes effect on the next Briglia start.
    private var cachedGwsUsable: Bool?
    /// Number of top-level gws operations currently between entry and exit —
    /// including their retry ladders' sleeps and the blocking subprocesses
    /// (which ignore Swift task cancellation and can run up to their own
    /// timeout). resetForWipe deadline-polls this for genuine quiescence:
    /// counting whole operations, not individual subprocess calls, is what
    /// makes "counter == 0" mean no retry can launch a fresh gws process
    /// after the wipe deletes ~/.config/gws (Codex, 2026-08-22).
    private var gwsOpsInFlight = 0

    private func trackedOp<T: Sendable>(_ body: () async -> T) async -> T {
        gwsOpsInFlight += 1
        defer { gwsOpsInFlight -= 1 }
        return await body()
    }

    // Test seams for the wipe-quiescence selftest.
    func opsInFlightForTesting() -> Int { gwsOpsInFlight }
    func performTrackedOpForTesting(_ body: @Sendable () async -> Void) async {
        await trackedOp { await body() }
    }

    func gwsUsable() async -> Bool {
        await trackedOp { await gwsUsableBody() }
    }

    private func gwsUsableBody() async -> Bool {
        if let cachedGwsUsable { return cachedGwsUsable }
        let epoch = stateEpoch
        var usable = false
        if Self.gwsInstalled(),
           let out = await runGws(args: ["auth", "status"], timeoutSeconds: 10, epoch: epoch),
           let data = out.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let method = json["auth_method"] as? String {
            usable = method != "none"
        }
        guard epoch == stateEpoch else { return false }
        cachedGwsUsable = usable
        if !usable {
            print("[GoogleWorkspaceService] gws \(Self.gwsInstalled() ? "installed but not authorized" : "not installed") — email/calendar disabled (optional; `briglia setup` toolchain step, then restart Briglia)")
        }
        return usable
    }

    func startBackgroundPoll() async {
        guard await gwsUsable() else { return }
        pollerTask?.cancel()
        let intervalNs: UInt64 = pollIntervalSeconds * 1_000_000_000
        // Seed the arrival watermark to "now" so the first poll only surfaces
        // truly fresh mail — a mailbox with hundreds of pre-existing unread
        // would otherwise flood the session.
        lastArrivalPollTime = Date()
        pollerTask = Task.detached { [weak self] in
            // First poll after the seed interval: don't tick at T=0 or we'll
            // query a zero-width window and miss nothing intended anyway.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { break }
                await self?.pollOnce()
            }
        }
        print("[GoogleWorkspaceService] Arrival poll started (every \(pollIntervalSeconds)s, query: is:unread after:<lastPollTime>)")
    }

    func stopBackgroundPoll() {
        pollerTask?.cancel()
        pollerTask = nil
        stateEpoch &+= 1
    }

    /// Stop the poller, wait for GENUINE quiescence, and drop cached
    /// email/calendar content. Called by /deleteuserdata BEFORE any deletion
    /// (Codex, 2026-08-22): cancelling the poller task is not quiescence —
    /// gws subprocesses run through a blocking dispatch-queue helper that
    /// ignores Swift task cancellation and can keep running for up to its
    /// own timeout, after which the operation's retry ladder could launch
    /// ANOTHER process and repopulate caches or recreate token-cache
    /// artifacts after ~/.config/gws was deleted. The in-flight counter
    /// spans whole operations (retries included), so counter == 0 means no
    /// gws process is running and none can be launched by an in-flight op.
    /// Returns false when quiescence wasn't reached — the wipe ABORTS before
    /// deleting anything in that case.
    @discardableResult
    func resetForWipe(timeoutSeconds: Double = 10) async -> Bool {
        stopBackgroundPoll()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while gwsOpsInFlight > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let quiesced = gwsOpsInFlight == 0
        cachedUnread.removeAll()
        recentlyNotifiedIds.removeAll()
        lastArrivalPollTime = nil
        lastSuccessfulFetch = nil
        cachedCalendarContext = nil
        cachedCalendarDay = nil
        cachedGwsUsable = nil
        return quiesced
    }

    /// Best-effort `gws auth logout` for /deleteuserdata, run AFTER gws
    /// quiescence and BEFORE ~/.config/gws is deleted: gws encrypts its
    /// token cache with an OS-keyring key, so logout releases what directory
    /// deletion alone cannot. Bounded (the process helper terminates then
    /// SIGKILLs at the deadline, so an unexpected confirmation prompt can't
    /// hang the wipe) and failure-tolerant — the directory deletion that
    /// follows is the backstop.
    static func authLogoutForWipe() async {
        guard let binary = locateGws(),
              FileManager.default.fileExists(atPath: gwsConfigDirectory.path) else { return }
        _ = await runProcessAsync(executable: binary, args: ["auth", "logout"], timeoutSeconds: 15)
    }

    // MARK: - Public API — system-prompt context builders

    /// Email context block for the system prompt. Byte-stable between explicit
    /// refreshes so the provider prompt cache holds. Returns "" on any failure
    /// so the caller can simply skip the block.
    ///
    /// This fetches the snapshot of current unread mail (top N by date, no
    /// time-window filter) — distinct from the poll path which only reports
    /// NEW arrivals since the last watermark.
    func getEmailContextForSystemPrompt() async -> String {
        await trackedOp {
            let epoch = stateEpoch
            guard await gwsUsable(), epoch == stateEpoch else { return "" }
            _ = await fetchUnreadSnapshotWithRetry(epoch: epoch)
            guard epoch == stateEpoch else { return "" }
            return formatUnreadEmails(cachedUnread)
        }
    }

    /// Calendar context block for the system prompt. Cache hits are byte-stable;
    /// refreshes on force, local-day rollover, or first miss. Returns "" on any
    /// failure so the caller can simply skip the block.
    func getCalendarContextForSystemPrompt(forceRefresh: Bool = false) async -> String {
        await trackedOp { await getCalendarContextBody(forceRefresh: forceRefresh) }
    }

    private func getCalendarContextBody(forceRefresh: Bool) async -> String {
        let epoch = stateEpoch
        guard await gwsUsable(), epoch == stateEpoch else { return "" }
        let today = Calendar.current.startOfDay(for: Date())
        if !forceRefresh,
           let cached = cachedCalendarContext,
           cachedCalendarDay == today {
            return cached
        }
        if let events = await fetchAgendaWithRetry(epoch: epoch) {
            guard epoch == stateEpoch else { return "" }
            let formatted = formatAgenda(events: events)
            cachedCalendarContext = formatted
            cachedCalendarDay = today
            return formatted
        }
        // Retry exhausted — surface empty so the system prompt skips the block.
        return ""
    }

    func invalidateCalendarCache() {
        cachedCalendarContext = nil
        cachedCalendarDay = nil
    }

    /// Post-login smoke test for the guided onboarding flow: one agenda fetch,
    /// no retries. True means gws answered with a decodable (possibly empty)
    /// result — i.e. the CLI is installed, authenticated, and the token works.
    func verifyGwsAccess() async -> Bool {
        await trackedOp { await fetchAgendaOnce(epoch: stateEpoch) != nil }
    }

    // MARK: - Poll tick (arrival-only — does NOT surface pre-existing unread)

    private func pollOnce() async {
        await trackedOp { await pollOnceBody(epoch: stateEpoch) }
    }

    private func pollOnceBody(epoch: UInt64) async {
        // Watermark was seeded at startBackgroundPoll time. On a failed fetch we
        // leave it untouched so the next successful poll widens the window to
        // cover the gap — no missed arrivals.
        let since = lastArrivalPollTime ?? Date().addingTimeInterval(-TimeInterval(pollIntervalSeconds))
        let sinceEpoch = Int(since.timeIntervalSince1970)
        let pollStartedAt = Date()

        guard let arrived = await fetchEmailsArrivedSinceWithRetry(sinceEpoch: sinceEpoch, epoch: epoch),
              epoch == stateEpoch else {
            return
        }

        // Deduplicate against the last 200 notified IDs — belt-and-braces for
        // boundary conditions (same-second delivery, clock drift, etc.).
        let notifiedSet = Set(recentlyNotifiedIds)
        let fresh = arrived.filter { !notifiedSet.contains($0.id) }

        // Advance the watermark only on a successful fetch. Use pollStartedAt
        // (captured before the fetch) to avoid creating a gap while the request
        // was in flight.
        lastArrivalPollTime = pollStartedAt

        if !fresh.isEmpty {
            // Bound the dedupe buffer to the most recent 200 IDs.
            recentlyNotifiedIds.append(contentsOf: fresh.map { $0.id })
            if recentlyNotifiedIds.count > 200 {
                recentlyNotifiedIds = Array(recentlyNotifiedIds.suffix(200))
            }
            if let handler = newEmailHandler {
                _ = await handler(fresh)
            }
        }
    }

    // MARK: - Fetch helpers (with retry)

    /// Consecutive fully-exhausted fetch passes across all gws fetchers. A
    /// single flaky pass stays quiet (email/calendar context just degrades for
    /// one tick); a PERSISTENT failure — the classic case is an expired OAuth
    /// token, which silently killed email alerts for weeks in June 2026 —
    /// surfaces a maintenance alert telling the user to run `gws auth login`.
    private var consecutiveGwsFailures = 0
    private let gwsFailureAlertThreshold = 5

    /// Head of the most recent underlying gws failure (exit code + stderr,
    /// timeout, or decode mismatch), captured so maintenance alerts can say
    /// WHY a pass failed instead of just "all retries exhausted". Without it
    /// the entry alert's "run gws auth login" hint is a guess — a network
    /// outage produces the same alert as an expired token.
    private var lastGwsFailureDetail: String?

    /// stderr head of the most recent gws run, kept even on exit 0 — the
    /// July 2 incident was gws exiting 0 with EMPTY stdout, where stderr was
    /// the only place the cause could have appeared.
    private var lastGwsStderrHead: String?

    /// Last self-heal reinstall attempt, so persistent failures trigger at
    /// most one re-download per day.
    private var lastGwsSelfUpdateAttempt: Date?

    /// If the active gws binary is the one Briglia installed (~/.local/bin/gws),
    /// re-run the installer: a persistent failure can be a stale binary that
    /// Google's APIs no longer accept, and unlike Homebrew installs nobody
    /// ever runs `brew upgrade` on ours. Cheap (~6 MB), idempotent, and a
    /// no-op for auth failures — the maintenance alert still fires either way.
    private func attemptGwsSelfHealIfManaged(epoch: UInt64) async {
        guard epoch == stateEpoch else { return }
        let managedPath = "\(NSHomeDirectory())/.local/bin/gws"
        guard Self.locateGws() == managedPath else { return }
        if let last = lastGwsSelfUpdateAttempt, Date().timeIntervalSince(last) < 86_400 { return }
        lastGwsSelfUpdateAttempt = Date()
        if let failure = await Self.installGwsBinary() {
            print("[GoogleWorkspaceService] gws self-update failed: \(failure)")
        } else {
            print("[GoogleWorkspaceService] gws reinstalled at latest release (self-heal after persistent failures)")
        }
    }

    /// Every completion side effect — clearing or opening a maintenance
    /// episode, the failure counter, the self-heal reinstall — belongs to
    /// the operation's epoch: a result that outlives a stop or provider
    /// switch changes nothing (Codex, menu round 4).
    private func noteGwsFetchOutcome(success: Bool, context: String, epoch: UInt64) async {
        guard epoch == stateEpoch else { return }
        if success {
            // Unconditional: the in-memory failure counter resets on app
            // restart while the alert-center episode persists on disk. Gating
            // this on the counter left such episodes open forever, so a later
            // transient blip escalated a long-recovered outage ("Still
            // failing" hours after the user fixed auth). reportSuccess is a
            // cheap no-op when no episode exists.
            consecutiveGwsFailures = 0
            lastGwsFailureDetail = nil
            await MaintenanceAlertCenter.shared.reportSuccess(.googleWorkspace)
        } else {
            consecutiveGwsFailures += 1
            if consecutiveGwsFailures % gwsFailureAlertThreshold == 0 {
                await attemptGwsSelfHealIfManaged(epoch: epoch)
                guard epoch == stateEpoch else { return }
                var errorText = "\(context): all retries exhausted (\(consecutiveGwsFailures) consecutive failed fetch passes)"
                if let detail = lastGwsFailureDetail {
                    errorText += ". Underlying error: \(detail)"
                }
                await MaintenanceAlertCenter.shared.reportFailure(
                    .googleWorkspace,
                    error: errorText,
                    deterministic: false
                )
            }
        }
    }

    /// Snapshot fetch: "top N unread right now" for the system-prompt block.
    /// Not time-windowed — always returns the user's freshest unread mail.
    private func fetchUnreadSnapshotWithRetry(epoch: UInt64) async -> [UnreadEmail]? {
        var delayNs: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            guard epoch == stateEpoch else { return nil }
            if let emails = await fetchUnreadSnapshotOnce(epoch: epoch) {
                guard epoch == stateEpoch else { return nil }
                cachedUnread = emails
                lastSuccessfulFetch = Date()
                await noteGwsFetchOutcome(success: true, context: "fetchUnreadSnapshot", epoch: epoch)
                return emails
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }
        guard epoch == stateEpoch else { return nil }
        print("[GoogleWorkspaceService] fetchUnreadSnapshot: all retries exhausted — continuing without email context")
        await noteGwsFetchOutcome(success: false, context: "fetchUnreadSnapshot", epoch: epoch)
        return nil
    }

    /// Arrival fetch: "unread mail delivered after <epoch>" for the poller.
    /// Returns ONLY new arrivals; a mailbox with 500 pre-existing unread will
    /// return 0 rows if nothing new landed in the poll window.
    private func fetchEmailsArrivedSinceWithRetry(sinceEpoch: Int, epoch: UInt64) async -> [UnreadEmail]? {
        var delayNs: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            guard epoch == stateEpoch else { return nil }
            if let emails = await fetchEmailsArrivedSinceOnce(sinceEpoch: sinceEpoch, epoch: epoch) {
                guard epoch == stateEpoch else { return nil }
                await noteGwsFetchOutcome(success: true, context: "fetchEmailsArrivedSince", epoch: epoch)
                return emails
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }
        guard epoch == stateEpoch else { return nil }
        print("[GoogleWorkspaceService] fetchEmailsArrivedSince(\(sinceEpoch)): all retries exhausted — skipping this tick")
        await noteGwsFetchOutcome(success: false, context: "fetchEmailsArrivedSince", epoch: epoch)
        return nil
    }

    private func fetchAgendaWithRetry(epoch: UInt64) async -> [AgendaEvent]? {
        var delayNs: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            guard epoch == stateEpoch else { return nil }
            if let events = await fetchAgendaOnce(epoch: epoch) {
                guard epoch == stateEpoch else { return nil }
                await noteGwsFetchOutcome(success: true, context: "fetchAgenda", epoch: epoch)
                return events
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }
        guard epoch == stateEpoch else { return nil }
        print("[GoogleWorkspaceService] fetchAgenda: all retries exhausted — continuing without calendar context")
        await noteGwsFetchOutcome(success: false, context: "fetchAgenda", epoch: epoch)
        return nil
    }

    // MARK: - Fetch helpers (single attempt)

    private struct TriageResponse: Decodable {
        let messages: [TriageMessage]
    }
    private struct TriageMessage: Decodable {
        let id: String
        let from: String?
        let subject: String?
        let date: String?
    }

    private func fetchUnreadSnapshotOnce(epoch: UInt64) async -> [UnreadEmail]? {
        return await triageAndEnrich(query: "is:unread", maxResults: maxUnread, epoch: epoch)
    }

    /// The arrival path uses a wider cap (50) because the realistic worst case
    /// — a dormant account suddenly receiving a burst — is still bounded, and
    /// triage + snippet fetches are cheap.
    private func fetchEmailsArrivedSinceOnce(sinceEpoch: Int, epoch: UInt64) async -> [UnreadEmail]? {
        if let arrivalFetchForTesting { return await arrivalFetchForTesting(sinceEpoch) }
        return await triageAndEnrich(query: "is:unread after:\(sinceEpoch)", maxResults: 50, epoch: epoch)
    }

    /// Runs `gws gmail +triage` for the given query, then enriches each result
    /// with `users.messages.get(format=metadata).snippet` so the preview lines
    /// match the legacy EmailService format.
    private func triageAndEnrich(query: String, maxResults: Int, epoch: UInt64) async -> [UnreadEmail]? {
        let triageArgs = [
            "gmail", "+triage",
            "--query", query,
            "--max", "\(maxResults)",
            "--format", "json",
        ]
        guard let out = await runGws(args: triageArgs, timeoutSeconds: 20, epoch: epoch) else { return nil }
        let stripped = stripLogPreamble(out)
        if isZeroResultNotice(stdout: stripped, marker: "No messages found") {
            return []
        }
        guard let data = stripped.data(using: .utf8),
              let triage = try? JSONDecoder().decode(TriageResponse.self, from: data) else {
            print("[GoogleWorkspaceService] triage decode failed; raw head: \(stripped.prefix(200))")
            let stdoutNote = stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty stdout)" : "stdout head: \(stripped.prefix(120))"
            let stderrNote = lastGwsStderrHead.map { "; stderr head: \($0)" } ?? ""
            lastGwsFailureDetail = "triage JSON decode failed; \(stdoutNote)\(stderrNote)"
            return nil
        }

        // Serial snippet fetch — latency is irrelevant for a 5-min poller, and
        // parallelizing would risk burning through OAuth rate limits on bursts.
        var results: [UnreadEmail] = []
        for msg in triage.messages {
            // A stop/provider switch mid-loop: launch no further snippet
            // subprocesses for a result nobody will use (round 4).
            guard epoch == stateEpoch else { return nil }
            let snippet = await fetchSnippet(messageId: msg.id, epoch: epoch) ?? ""
            results.append(UnreadEmail(
                id: msg.id,
                threadId: nil,
                from: msg.from ?? "(unknown sender)",
                subject: msg.subject ?? "(no subject)",
                date: msg.date ?? "",
                snippet: snippet
            ))
        }
        return results
    }

    private struct MessageMetadata: Decodable {
        let snippet: String?
        let threadId: String?
    }

    private func fetchSnippet(messageId: String, epoch: UInt64) async -> String? {
        let paramsJSON = "{\"userId\":\"me\",\"id\":\"\(messageId)\",\"format\":\"metadata\"}"
        let args = ["gmail", "users", "messages", "get", "--params", paramsJSON]
        guard let out = await runGws(args: args, timeoutSeconds: 15, epoch: epoch) else { return nil }
        let stripped = stripLogPreamble(out)
        guard let data = stripped.data(using: .utf8),
              let meta = try? JSONDecoder().decode(MessageMetadata.self, from: data) else {
            return nil
        }
        return meta.snippet
    }

    // MARK: - Agenda fetch + types

    struct AgendaEvent: Sendable {
        let id: String
        let summary: String
        let startDate: Date
        let isAllDay: Bool
        let notes: String?
    }

    private struct AgendaResponse: Decodable {
        let events: [RawEvent]
    }
    private struct RawEvent: Decodable {
        let id: String?
        let summary: String?
        let description: String?
        let start: TimeMark?
        let location: String?
    }
    private struct TimeMark: Decodable {
        let dateTime: String?
        let date: String?
        let timeZone: String?
    }

    private func fetchAgendaOnce(epoch: UInt64) async -> [AgendaEvent]? {
        let args = [
            "calendar", "+agenda",
            "--days", "\(agendaDaysAhead)",
            "--format", "json",
        ]
        guard let out = await runGws(args: args, timeoutSeconds: 20, epoch: epoch) else { return nil }
        let stripped = stripLogPreamble(out)
        if isZeroResultNotice(stdout: stripped, marker: "No events found") {
            return []
        }
        guard let data = stripped.data(using: .utf8),
              let response = try? JSONDecoder().decode(AgendaResponse.self, from: data) else {
            print("[GoogleWorkspaceService] agenda decode failed; raw head: \(stripped.prefix(200))")
            let stdoutNote = stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty stdout)" : "stdout head: \(stripped.prefix(120))"
            let stderrNote = lastGwsStderrHead.map { "; stderr head: \($0)" } ?? ""
            lastGwsFailureDetail = "agenda JSON decode failed; \(stdoutNote)\(stderrNote)"
            return nil
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone.current

        var events: [AgendaEvent] = []
        for raw in response.events {
            guard let start = raw.start else { continue }
            let date: Date?
            let allDay: Bool
            if let dt = start.dateTime {
                date = iso.date(from: dt) ?? isoNoFrac.date(from: dt)
                allDay = false
            } else if let d = start.date {
                date = dateOnly.date(from: d)
                allDay = true
            } else {
                continue
            }
            guard let resolved = date else { continue }
            let notes = [raw.description, raw.location]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            events.append(AgendaEvent(
                id: raw.id ?? UUID().uuidString,
                summary: raw.summary?.isEmpty == false ? raw.summary! : "(untitled)",
                startDate: resolved,
                isAllDay: allDay,
                notes: notes.isEmpty ? nil : notes
            ))
        }
        return events.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Formatters (match legacy output byte-for-byte where it matters)

    private func formatUnreadEmails(_ emails: [UnreadEmail]) -> String {
        guard !emails.isEmpty else { return "" }

        var lines: [String] = ["📧 **Your Inbox** (last \(emails.count) unread emails):", ""]
        for email in emails {
            var line = "• **\(email.subject)** from \(email.from)"
            if !email.date.isEmpty {
                line += " (\(email.date))"
            }
            line += " [id: \(email.id)]"
            if !email.snippet.isEmpty {
                let preview = email.snippet
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(100)
                line += "\n  └ \(preview)..."
            }
            lines.append(line)
        }
        lines.append("")
        lines.append("Use `bash` with `gws gmail +read`, `gws gmail +reply`, `gws gmail +send` etc. to act on these emails.")
        return lines.joined(separator: "\n")
    }

    /// Matches CalendarService.generateCalendarContext progressive-detail layout:
    /// full detail for today+near (≤7 days), title+date for 8–30 days, no far bucket
    /// because gws +agenda is already capped at the requested horizon.
    private func formatAgenda(events: [AgendaEvent]) -> String {
        guard !events.isEmpty else { return "📅 **Your Calendar**: No upcoming events." }

        let now = Date()
        let calendar = Calendar.current
        let sevenDaysOut = calendar.date(byAdding: .day, value: 7, to: now)!

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        let near = events.filter { $0.startDate < sevenDaysOut }
        let mid  = events.filter { $0.startDate >= sevenDaysOut }

        var lines: [String] = ["📅 **Your Calendar**:", ""]
        var currentDateString = ""

        for event in near {
            let eventDateString = dateFormatter.string(from: event.startDate)
            if eventDateString != currentDateString {
                if !currentDateString.isEmpty { lines.append("") }
                if calendar.isDateInToday(event.startDate) {
                    lines.append("**TODAY - \(eventDateString)**")
                } else if calendar.isDateInTomorrow(event.startDate) {
                    lines.append("**TOMORROW - \(eventDateString)**")
                } else {
                    lines.append("**\(eventDateString)**")
                }
                currentDateString = eventDateString
            }

            var eventLine: String
            if event.isAllDay {
                eventLine = "• (all day): \(event.summary)"
            } else {
                let timeStr = timeFormatter.string(from: event.startDate)
                eventLine = "• \(timeStr): \(event.summary)"
            }
            if let notes = event.notes, !notes.isEmpty {
                eventLine += " — \(notes)"
            }
            let shortId = String(event.id.prefix(8))
            eventLine += " [id: \(shortId)...]"
            lines.append(eventLine)
        }

        if !mid.isEmpty {
            lines.append("")
            lines.append("**Next 8-30 days:**")
            for event in mid {
                let dateStr = dateFormatter.string(from: event.startDate)
                let shortId = String(event.id.prefix(8))
                lines.append("• \(dateStr): \(event.summary) [id: \(shortId)...]")
            }
        }

        // Cap to roughly the same budget as CalendarService (4000 tokens ≈ 16000 chars).
        var result = lines.joined(separator: "\n")
        let maxChars = 16_000
        if result.count > maxChars {
            result = String(result.prefix(maxChars - 80)) +
                "\n... [calendar truncated — run `bash gws calendar +agenda` for full agenda]"
        }
        return result
    }

    // MARK: - gws subprocess invocation

    /// Fast, subprocess-free probe for UI status rows (onboarding gate, chat
    /// header): is the Google Workspace CLI installed at a known path?
    static func gwsInstalled() -> Bool {
        let candidates = [
            "/opt/homebrew/bin/gws",
            "/usr/local/bin/gws",
            "\(NSHomeDirectory())/.cargo/bin/gws",
            "\(NSHomeDirectory())/.local/bin/gws",
            "/usr/bin/gws",
        ]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Locates the `gws` binary across common install paths. Returns nil if missing —
    /// callers must treat that as a non-fatal "no context available".
    static func locateGws() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gws",
            "/usr/local/bin/gws",
            "\(NSHomeDirectory())/.cargo/bin/gws",
            "\(NSHomeDirectory())/.local/bin/gws",
            "/usr/bin/gws",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last-ditch: ask `which`. We intentionally pass an augmented PATH so it can
        // see Homebrew etc., mirroring the pattern in LSPRegistry.
        if let out = runBlockingProcess(
            executable: "/usr/bin/env",
            args: ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.cargo/bin",
                   "which", "gws"],
            timeoutSeconds: 3
        ).stdout, !out.isEmpty {
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Returns stdout on success, nil on any failure (missing binary, non-zero exit,
    /// timeout, or I/O error). Stale-epoch runs (a stop/provider switch
    /// happened) launch nothing, and a run that outlives one returns nil
    /// without touching the diagnostic state (round 4).
    private func runGws(args: [String], timeoutSeconds: Int, epoch: UInt64) async -> String? {
        guard epoch == stateEpoch else { return nil }
        let result: ProcessRunResult
        if let runGwsForTesting {
            result = await runGwsForTesting(args)
        } else {
            guard let binary = Self.locateGws() else {
                // Soft-fail: the user may not have gws installed on this machine. That's
                // fine — the system prompt simply skips the gws-backed blocks.
                return nil
            }
            result = await Self.runProcessAsync(
                executable: binary,
                args: args,
                timeoutSeconds: timeoutSeconds
            )
        }
        guard epoch == stateEpoch else { return nil }
        if let detail = result.failureDetail {
            lastGwsFailureDetail = detail
        }
        lastGwsStderrHead = result.stderrHead
        return result.stdout
    }

    /// Some gws versions report an empty result set as a human notice on stderr
    /// ("No messages found matching query: …") with exit 0 and NO JSON on stdout.
    /// That is a successful zero-result run, not a failure — without this check
    /// every quiet-mailbox poll counts as a failed pass and eventually trips the
    /// maintenance alert. Gate on the explicit stderr marker: empty stdout alone
    /// is NOT proof of success (gws has been observed exiting 0 with empty stdout
    /// on genuine errors, with stderr holding the only evidence).
    private func isZeroResultNotice(stdout: String, marker: String) -> Bool {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) else { return false }
        guard let stderr = lastGwsStderrHead else { return false }
        return stderr.localizedCaseInsensitiveContains(marker)
    }

    /// The `gws` CLI prints a "Using keyring backend: keyring" line to stdout before
    /// the JSON body. JSONDecoder chokes on it. Strip any preamble up to the first
    /// `{` or `[`.
    private func stripLogPreamble(_ text: String) -> String {
        if let brace = text.firstIndex(where: { $0 == "{" || $0 == "[" }) {
            return String(text[brace...])
        }
        return text
    }

    // MARK: - Process helpers (static so they can be reused / tested)

    /// stdout on success; on failure, a one-line human-readable cause (launch
    /// error, timeout, or exit code + stderr head) so callers can surface WHY
    /// instead of a bare nil. stderrHead is captured even on exit 0: gws has
    /// been observed exiting 0 with empty stdout, where stderr held the only
    /// evidence of what went wrong.
    struct ProcessRunResult: Sendable {
        let stdout: String?
        let failureDetail: String?
        let stderrHead: String?
    }

    static func runProcessAsync(executable: String, args: [String], timeoutSeconds: Int) async -> ProcessRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let out = runBlockingProcess(executable: executable, args: args, timeoutSeconds: timeoutSeconds)
                continuation.resume(returning: out)
            }
        }
    }

    static func runBlockingProcess(executable: String, args: [String], timeoutSeconds: Int) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        // Augment PATH so `gws` can find its own helpers (some versions invoke
        // git/etc.) and so `#!/usr/bin/env node` shims resolve ~/.local/bin.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BashTools.augmentedPath(env["PATH"])
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            print("[GoogleWorkspaceService] failed to launch \(executable): \(error)")
            return ProcessRunResult(stdout: nil, failureDetail: "failed to launch \(executable): \(error.localizedDescription)", stderrHead: nil)
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            print("[GoogleWorkspaceService] \(executable) timed out after \(timeoutSeconds)s")
            return ProcessRunResult(stdout: nil, failureDetail: "timed out after \(timeoutSeconds)s", stderrHead: nil)
        }

        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let head = stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        let stderrHead = head.isEmpty ? nil : String(head)
        guard process.terminationStatus == 0 else {
            print("[GoogleWorkspaceService] \(executable) exit=\(process.terminationStatus); stderr head: \(head)")
            return ProcessRunResult(stdout: nil, failureDetail: "exit \(process.terminationStatus)\(head.isEmpty ? "" : ": \(head)")", stderrHead: stderrHead)
        }
        return ProcessRunResult(stdout: stdout, failureDetail: nil, stderrHead: stderrHead)
    }
}

// MARK: - User-provided OAuth client (gws login)

/// The Google OAuth Desktop client `gws auth login` authenticates against.
/// Briglia no longer ships an embedded client — each user creates their own in
/// their Google Cloud project (the wizard's gws path collects the id/secret
/// and stores them in secrets.json so ~/.config/gws/client_secret.json can be
/// rewritten if it's ever deleted). `isConfigured == false` means the user
/// hasn't provided one yet; a pre-existing client_secret.json written by an
/// older Briglia or by hand keeps working regardless.
enum AdaOAuthClient {
    static var clientID: String {
        KeychainHelper.load(key: KeychainHelper.gwsOAuthClientIDKey) ?? ""
    }
    static var clientSecret: String {
        KeychainHelper.load(key: KeychainHelper.gwsOAuthClientSecretKey) ?? ""
    }
    /// GCP project id hosting the client. gws's client_secret.json parser
    /// REQUIRES the key to exist but tolerates an empty value (its own
    /// env-var login path writes ""). Only used for quota attribution and
    /// the interactive scope picker, neither of which the guided flow hits.
    static let projectID = ""

    static var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty &&
        !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Accumulates interleaved stdout/stderr from `gws auth login` and yields the
/// Google consent URL exactly once. NSLock-guarded because Pipe readability
/// handlers fire on arbitrary dispatch queues.
private final class GuidedLoginOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var urlDelivered = false

    /// Appends a chunk; returns the consent URL if this chunk completed it and
    /// it hasn't been delivered yet.
    func append(_ chunk: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
        guard !urlDelivered,
              let range = text.range(of: #"https://accounts\.google\.com/[^\s"'<>]+"#,
                                     options: .regularExpression),
              let url = URL(string: String(text[range]))
        else { return nil }
        urlDelivered = true
        return url
    }

    var tail: String {
        lock.lock()
        defer { lock.unlock() }
        return String(text.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension GoogleWorkspaceService {
    static var gwsConfigDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/gws", isDirectory: true)
    }

    static var clientSecretFileURL: URL {
        gwsConfigDirectory.appendingPathComponent("client_secret.json")
    }

    /// Thrown when no user-provided OAuth client is stored and none exists on
    /// disk — `gws auth login` cannot work until the user supplies one.
    struct MissingOAuthClient: LocalizedError {
        var errorDescription: String? {
            "no Google OAuth client configured — rerun `briglia setup` (email step) and provide your own client ID + secret"
        }
    }

    /// Writes the user-provided OAuth client where `gws` looks for it
    /// (~/.config/gws/client_secret.json). An existing file is left untouched —
    /// the user may have configured their own client via the manual path, and
    /// clobbering it would orphan the refresh token minted against it.
    static func installAdaClientSecretIfMissing() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: clientSecretFileURL.path) else { return }
        guard AdaOAuthClient.isConfigured else { throw MissingOAuthClient() }
        try fm.createDirectory(at: gwsConfigDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "installed": [
                "client_id": AdaOAuthClient.clientID,
                "client_secret": AdaOAuthClient.clientSecret,
                // Required key: gws's serde model has no default for project_id
                // and rejects the whole file when it's absent.
                "project_id": AdaOAuthClient.projectID,
                "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                "token_uri": "https://oauth2.googleapis.com/token",
                "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
                "redirect_uris": ["http://localhost"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: clientSecretFileURL, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clientSecretFileURL.path)
    }

    /// Streams a download while reporting coarse progress through `progress`
    /// ("<label>… 45%", or "<label>… 12 MB" when the server sends no
    /// Content-Length). URLSession.data(from:) gives no feedback, and a
    /// 50 MB pull on slow Wi-Fi looks frozen without one.
    static func downloadReportingProgress(
        from url: URL,
        label: String,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> Data {
        #if !canImport(Darwin)
        // corelibs FoundationNetworking has no URLSession.bytes — download in
        // one shot with a start/end notice instead of incremental progress.
        progress?("\(label)…")
        let (blob, resp) = try await URLSession.shared.data(from: url)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
            throw NSError(domain: "GoogleWorkspaceService.download", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        progress?("\(label)… \(blob.count / 1_048_576) MB")
        return blob
        #else
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
            throw NSError(domain: "GoogleWorkspaceService.download", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        let expected = response.expectedContentLength // -1 when unknown
        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        var lastStep = -1
        for try await byte in bytes {
            data.append(byte)
            guard let progress else { continue }
            if expected > 0 {
                // Report in 5% increments.
                let step = Int((Double(data.count) / Double(expected)) * 20)
                if step != lastStep {
                    lastStep = step
                    progress("\(label)… \(min(step * 5, 100))%")
                }
            } else {
                // No Content-Length: report every 5 MB.
                let step = data.count / (5 * 1_048_576)
                if step != lastStep {
                    lastStep = step
                    progress("\(label)… \(data.count / 1_048_576) MB")
                }
            }
        }
        return data
        #endif
    }

    /// Downloads the official `gws` release binary from GitHub (Google publishes
    /// prebuilt, checksummed binaries per OS/arch), verifies the SHA-256,
    /// and installs it to ~/.local/bin/gws — a path both `locateGws()` and the
    /// agent's bash PATH already cover. No Homebrew, no sudo. Returns nil on
    /// success, or a human-readable failure detail.
    static func installGwsBinary(progress: (@Sendable (String) -> Void)? = nil) async -> String? {
        // Release asset targets, verified against the published asset list:
        // {x86_64,aarch64}-apple-darwin and {x86_64,aarch64}-unknown-linux-gnu
        // (musl variants exist too, but Briglia CLI only supports glibc distros).
        #if os(Linux)
        #if arch(arm64)
        let target = "aarch64-unknown-linux-gnu"
        #else
        let target = "x86_64-unknown-linux-gnu"
        #endif
        #else
        #if arch(arm64)
        let target = "aarch64-apple-darwin"
        #else
        let target = "x86_64-apple-darwin"
        #endif
        #endif
        let asset = "google-workspace-cli-\(target).tar.gz"
        let base = "https://github.com/googleworkspace/cli/releases/latest/download/"
        guard let tarURL = URL(string: base + asset),
              let shaURL = URL(string: base + asset + ".sha256") else {
            return "internal error: malformed release URL"
        }

        do {
            let tarData = try await downloadReportingProgress(
                from: tarURL, label: "Downloading Google's gws CLI", progress: progress)
            let (shaData, shaResp) = try await URLSession.shared.data(from: shaURL)
            if let code = (shaResp as? HTTPURLResponse)?.statusCode, code != 200 {
                return "checksum download failed (HTTP \(code))"
            }
            progress?("Installing gws…")
            // Checksum file format: "<hex>  <filename>"
            guard let expected = String(data: shaData, encoding: .utf8)?
                .split(separator: " ").first.map(String.init)?.lowercased(),
                  expected.count == 64 else {
                return "unreadable checksum file"
            }
            let actual = SHA256.hash(data: tarData).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                return "checksum mismatch — download corrupted or release changed mid-flight, retry"
            }

            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory.appendingPathComponent("gws-install-\(UUID().uuidString)")
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmpDir) }
            let tarPath = tmpDir.appendingPathComponent(asset)
            try tarData.write(to: tarPath)

            let untar = await runProcessAsync(
                executable: "/usr/bin/tar",
                args: ["-xzf", tarPath.path, "-C", tmpDir.path],
                timeoutSeconds: 30
            )
            if let detail = untar.failureDetail {
                return "extraction failed: \(detail)"
            }
            let extracted = tmpDir.appendingPathComponent("gws")
            guard fm.fileExists(atPath: extracted.path) else {
                return "archive did not contain the gws binary"
            }

            let destDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin", isDirectory: true)
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent("gws")
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: extracted, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            #if os(macOS)
            // Belt-and-braces: tar propagates com.apple.quarantine from the
            // archive if present; a quarantined unnotarized binary won't exec.
            _ = await runProcessAsync(
                executable: "/usr/bin/xattr",
                args: ["-d", "com.apple.quarantine", dest.path],
                timeoutSeconds: 5
            )
            #endif

            // Smoke test: the binary must actually run on this machine.
            let probe = await runProcessAsync(executable: dest.path, args: ["--version"], timeoutSeconds: 10)
            guard probe.stdout != nil else {
                return "installed binary failed to run: \(probe.failureDetail ?? "unknown error")"
            }
            return nil
        } catch {
            return "install failed: \(error.localizedDescription)"
        }
    }

    /// Runs `gws auth login`, watches its output for the Google consent URL and
    /// hands it to `openURL` (exactly once), then waits for the CLI to receive
    /// the localhost OAuth callback and store credentials. The generous timeout
    /// covers the human in the loop: account picker, password, consent screen.
    /// Returns nil on success, or a human-readable failure detail.
    static func runGuidedLogin(
        timeoutSeconds: Int = 300,
        openURL: @escaping @Sendable (URL) -> Void
    ) async -> String? {
        guard let binary = locateGws() else {
            return "gws binary not found"
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runGuidedLoginBlocking(binary: binary, timeoutSeconds: timeoutSeconds, openURL: openURL)
                continuation.resume(returning: result)
            }
        }
    }

    private static func runGuidedLoginBlocking(
        binary: String,
        timeoutSeconds: Int,
        openURL: @escaping @Sendable (URL) -> Void
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["auth", "login"]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        // gws must never stall on an interactive prompt we can't answer.
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let buffer = GuidedLoginOutputBuffer()
        let scan: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            if let url = buffer.append(chunk) { openURL(url) }
        }
        outPipe.fileHandleForReading.readabilityHandler = scan
        errPipe.fileHandleForReading.readabilityHandler = scan
        defer {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try process.run()
        } catch {
            return "failed to launch gws: \(error.localizedDescription)"
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return "login not completed within \(timeoutSeconds / 60) minutes"
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = buffer.tail
            return "gws auth login exited with code \(process.terminationStatus)\(tail.isEmpty ? "" : ": \(tail)")"
        }
        return nil
    }
}
