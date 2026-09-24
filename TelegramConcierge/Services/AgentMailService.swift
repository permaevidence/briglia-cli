import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// AgentMail-backed data source for ambient email context and the unread-mail
/// poller — the `agentmail` provider's counterpart to GoogleWorkspaceService.
///
/// The harness talks to the REST API (api.agentmail.to) directly over
/// URLSession — no CLI subprocess, no Node — so polling and system-prompt
/// context work even when the native `agentmail` CLI binary was never
/// installed. The CLI exists for the MODEL's follow-up actions via bash
/// (read/reply/send), with AGENTMAIL_API_KEY preset in its environment.
///
/// Emits the same `GoogleWorkspaceService.UnreadEmail` rows and the same
/// formatted context block shape as the gws path, so ConversationManager's
/// frozen-context cache and `processNewUnreadEmails` pipeline are shared
/// verbatim between providers.
actor AgentMailService {
    static let shared = AgentMailService()

    // MARK: - State

    private var cachedUnread: [GoogleWorkspaceService.UnreadEmail] = []

    /// Watermark for the arrival poll (`after=` is an ISO-8601 instant).
    /// Advanced only after a successful fetch so a failed tick widens the
    /// next window instead of dropping arrivals.
    private var lastArrivalPollTime: Date?

    /// Defense-in-depth dedupe across the deliberate query overlap and
    /// pagination bursts. Bounded to 1000.
    private var recentlyNotifiedIds: [String] = []

    private var pollerTask: Task<Void, Never>?
    /// Poll generation: bumped by resetForWipe()/stopBackgroundPoll()/
    /// startBackgroundPoll(). A tick captures the generation when it starts
    /// and re-checks it after EVERY suspension point before committing to
    /// actor state (drain cursors, dedupe, watermark, handler delivery,
    /// checkpoint file). The actor is reentrant, so a tick suspended in a
    /// network await or the notification handler can resume AFTER a wipe
    /// cleared state — without this token it would deliver pre-wipe mail,
    /// resurrect cursors, and recreate the checkpoint file (Codex round 7).
    private var pollGeneration: UInt64 = 0
    /// Number of poll ticks currently between entry and exit — including
    /// suspensions in network awaits or the notification handler.
    /// resetForWipe() deadline-polls this for genuine quiescence.
    private var ticksInFlight = 0
    /// Returns whether the event was made DURABLE (conversation record or
    /// the mirrored ambient queue). The persisted checkpoint advances only
    /// on true — a crash after a false return redelivers instead of losing
    /// the notification behind an advanced cursor (Codex round 6).
    private var newEmailHandler: (@Sendable ([GoogleWorkspaceService.UnreadEmail]) async -> Bool)?

    /// Inbox ids for this key, discovered once per process (a key is usually
    /// inbox-scoped, so this is a single address).
    private var cachedInboxIds: [String]?

    private let pollIntervalSeconds: UInt64 = 300
    private let maxUnread = 10
    private let maxInboxes = 5

    private static let apiBase = DevProbeOverride.url("https://api.agentmail.to/v0", dev: "/agentmail/v0")

    // MARK: - Configuration

    static func apiKey() -> String? {
        guard let key = KeychainHelper.load(key: KeychainHelper.agentMailApiKeyKey),
              !key.isEmpty else { return nil }
        return key
    }

    static func isConfigured() -> Bool { apiKey() != nil }

    /// Which account a persisted poll checkpoint belongs to: a one-way hash
    /// of the API key and inbox address (never the key itself). A checkpoint
    /// is restored only by the account that wrote it, so a failed cleanup
    /// after an account change can't hand the old account's watermark and
    /// drain cursors to the new one (Codex, menu round 3).
    static func accountFingerprint(key: String, inbox: String) -> String {
        let digest = SHA256.hash(data: Data("briglia-agentmail-poll-v1\u{0}\(key)\u{0}\(inbox)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static func currentAccountFingerprint() -> String? {
        guard let key = apiKey() else { return nil }
        return accountFingerprint(key: key, inbox: EmailCalendarProvider.agentMailInboxAddress)
    }
    /// The account the running poller was started for (stamped into every
    /// checkpoint it writes).
    private var pollAccount: String?
    /// Checkpoints from before accounts were stamped are adopted only by the
    /// first start in a process. After a live account change they can't be
    /// attributed to either account, so they are never adopted.
    private var legacyCheckpointAdoptable = true

    // MARK: - Public API — polling lifecycle (mirrors GoogleWorkspaceService)

    func setNewEmailHandler(_ handler: @escaping @Sendable ([GoogleWorkspaceService.UnreadEmail]) async -> Bool) {
        newEmailHandler = handler
    }

    /// Stop the poller and drop ALL in-memory poll state — watermark, drain
    /// cursors, dedupe buffer, unread/inbox caches. Called by /deleteuserdata
    /// BEFORE deletion (so a live tick can't recreate the state file or
    /// deliver a pre-wipe backlog mid-wipe) and by reloadAfterMindRestore.
    /// Credentials/provider config are untouched — they're configuration,
    /// not user data; the caller restarts the poller afterwards.
    ///
    /// Quiescence: the generation bump makes every in-flight tick discard
    /// its results at its next commit point (the hard guarantee), and the
    /// deadline-polled in-flight counter below reports whether GENUINE
    /// quiescence was reached so the wipe can abort before deleting
    /// anything. A task-group race against the loop task's `value` is NOT a
    /// real bound — leaving a task group awaits all children, and awaiting a
    /// nonthrowing task's value cannot be interrupted (Codex round 8,
    /// reproduced) — hence the counter. Returns false when a tick is still
    /// in flight at the deadline; its late commits are refused by the stale
    /// generation either way.
    @discardableResult
    func resetForWipe(timeoutSeconds: Double = 10) async -> Bool {
        pollGeneration &+= 1
        pollerTask?.cancel()
        pollerTask = nil
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while ticksInFlight > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let quiesced = ticksInFlight == 0
        lastArrivalPollTime = nil
        drainStates.removeAll()
        recentlyNotifiedIds.removeAll()
        cachedUnread.removeAll()
        cachedInboxIds = nil
        return quiesced
    }

    func startBackgroundPoll() async {
        guard Self.isConfigured() else { return }
        pollGeneration &+= 1
        let generation = pollGeneration
        pollerTask?.cancel()
        pollAccount = Self.currentAccountFingerprint()
        let intervalNs: UInt64 = pollIntervalSeconds * 1_000_000_000
        // Seed the watermark to "now": pre-existing unread must not flood the
        // session at launch — it is surfaced by the snapshot context instead.
        lastArrivalPollTime = Date()
        // …then restore the persisted watermark + drain cursors when they
        // are fresh (<48h): a restart mid-drain must not abandon the backlog
        // tail, and arrivals during a brief downtime should still notify
        // (Codex round 5, 2026-08-22). Stale state keeps the anti-flood seed.
        // Make the baseline durable IMMEDIATELY when nothing was restored
        // (Codex round 10): without this, nothing persists until the first
        // successful poll, so a restart before then — the wipe's
        // timeout-abort recovery, a crash — re-seeds the watermark to a
        // LATER "now" and mail arriving in between (beyond the 60s overlap)
        // loses its proactive notification. The persist is CONDITIONAL
        // (Codex round 11): re-persisting restored state would refresh
        // savedAt, and restarting at least once every 48h could then keep a
        // never-advancing watermark restore-eligible forever — replaying
        // weeks of backlog on recovery, exactly what the 48h stale gate
        // exists to prevent. A restored checkpoint is already durable on
        // disk with its original savedAt; leave it untouched.
        if !restorePollStateIfFresh() {
            persistPollState()
        }
        pollerTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { break }
                await self?.pollOnce(generation: generation)
            }
        }
        print("[AgentMailService] Arrival poll started (every \(pollIntervalSeconds)s, query: labels=unread&after=<lastPollTime>)")
    }

    /// Forgets the persisted arrival checkpoint (watermark + drain cursors).
    /// Called after a live AgentMail account change, once the poller is
    /// quiesced: cursors discovered under the old key must not be restored
    /// for the new one.
    /// False when the file exists but couldn't be removed. Harmless for
    /// correctness — the checkpoint is account-stamped, so another account
    /// never restores it — but reported so the stale file is visible.
    @discardableResult
    func discardPersistedPollState() -> Bool {
        legacyCheckpointAdoptable = false
        do {
            try FileManager.default.removeItem(at: Self.pollStateURL)
            return true
        } catch {
            if !FileManager.default.fileExists(atPath: Self.pollStateURL.path) { return true }
            print("[AgentMailService] WARNING: couldn't remove the old account's poll checkpoint (\(error.localizedDescription)); it stays inert (account-stamped)")
            return false
        }
    }

    func stopBackgroundPoll() {
        // Bump so a tick already in flight discards its commits — a plain
        // stop must be as final as a wipe (the caller may delete state next).
        pollGeneration &+= 1
        pollerTask?.cancel()
        pollerTask = nil
    }

    // MARK: - Public API — system-prompt context builder

    /// Email context block for the system prompt: snapshot of current unread
    /// (top N by date, no time window). Returns "" on any failure so the
    /// caller simply skips the block.
    func getEmailContextForSystemPrompt() async -> String {
        guard Self.isConfigured() else { return "" }
        _ = await fetchUnreadSnapshotWithRetry()
        return Self.formatUnreadEmails(cachedUnread)
    }

    /// One inboxes fetch, no retries — for doctor's online probe.
    func verifyAccess() async -> Bool {
        await fetchInboxIdsOnce() != nil
    }

    // MARK: - Test seams (wipe/poll race selftest)

    func currentGenerationForTesting() -> UInt64 { pollGeneration }
    func ticksInFlightForTesting() -> Int { ticksInFlight }
    func watermarkForTesting() -> Date? { lastArrivalPollTime }
    func seedWatermarkForTesting(_ date: Date?) { lastArrivalPollTime = date }
    static var pollStateURLForTesting: URL { pollStateURL }

    // MARK: - Poll tick

    /// Query overlap behind the watermark: absorbs `after` boundary
    /// inclusivity AND the API's observed indexing lag (~5s seen live on
    /// label filters). Repeats are suppressed by the id dedupe buffer.
    private let arrivalOverlapSeconds: TimeInterval = 60

    private func pollOnce(generation: UInt64) async {
        await pollTick(
            generation: generation,
            fetch: { since, startedAt in
                await self.fetchArrivedSinceWithRetry(since: since, pollStartedAt: startedAt, generation: generation)
            },
            handler: newEmailHandler
        )
    }

    /// One poll tick with injected fetch/handler so the wipe-race selftest
    /// can deliberately suspend a tick mid-fetch or mid-handler and prove a
    /// concurrent resetForWipe() wins. Every commit to actor state re-checks
    /// `generation` after the awaits that precede it; a superseded tick
    /// discards its results — no delivery, no watermark, no checkpoint file.
    func pollTick(
        generation: UInt64,
        fetch: @Sendable (Date, Date) async -> ArrivalFetchResult?,
        handler: (@Sendable ([GoogleWorkspaceService.UnreadEmail]) async -> Bool)?
    ) async {
        guard generation == pollGeneration else { return }
        // In-flight accounting for resetForWipe's quiescence poll. The
        // increment is after the generation guard (a refused entry touches
        // nothing) and both run synchronously on the actor, so a reset
        // observing 0 either sees no tick, or a tick whose entry guard will
        // refuse the already-bumped generation.
        ticksInFlight += 1
        defer { ticksInFlight -= 1 }
        let watermark = lastArrivalPollTime ?? Date().addingTimeInterval(-TimeInterval(pollIntervalSeconds))
        let since = watermark.addingTimeInterval(-arrivalOverlapSeconds)
        let pollStartedAt = Date()

        guard let result = await fetch(since, pollStartedAt) else { return }
        // The fetch suspended: a wipe/restart may have superseded this tick.
        // Bail BEFORE delivery — handing pre-wipe mail to the handler here
        // would push a wiped backlog into the fresh conversation.
        guard generation == pollGeneration else { return }
        let arrived = result.emails

        let notifiedSet = Set(recentlyNotifiedIds)
        let fresh = arrived.filter { !notifiedSet.contains($0.id) }

        // DELIVER FIRST, CHECKPOINT SECOND: the persisted watermark/cursors
        // may only advance once the handler reports the notification durable
        // (conversation record or the mirrored ambient queue) — persisting
        // the checkpoint first meant a crash between checkpoint and delivery
        // silently lost the mail (Codex round 6). The in-memory dedupe is
        // still recorded on a non-durable delivery: the event lives in this
        // process's queue, so re-notifying in-process would duplicate it —
        // while after a crash the un-advanced PERSISTED state refetches
        // everything (at-least-once).
        var durable = true
        if !fresh.isEmpty {
            recentlyNotifiedIds.append(contentsOf: fresh.map { $0.id })
            // 1000, not 200: the 60s query overlap plus paginated bursts can
            // legitimately re-serve far more boundary ids than the gws path.
            if recentlyNotifiedIds.count > 1000 {
                recentlyNotifiedIds = Array(recentlyNotifiedIds.suffix(1000))
            }
            if let handler {
                durable = await handler(fresh)
                // The handler suspended too. Its own enqueue (if any) landed
                // before the wipe's buffer clear — resetForWipe() awaits the
                // in-flight tick — but THIS tick must not advance post-wipe
                // state on the strength of a pre-wipe delivery.
                guard generation == pollGeneration else { return }
            }
        }

        guard durable else {
            print("[AgentMailService] notification not yet durable — holding the persisted checkpoint; a crash now redelivers instead of losing mail")
            return
        }

        // Advance only when every inbox is fully drained — and only to the
        // VERIFIED time (a completing multi-tick drain advances to the tick
        // that started it, so mail arriving mid-drain gets re-queried by the
        // next window regardless of the API's cursor semantics). Mid-drain
        // the watermark holds; cursor progress still persists.
        if let advance = result.advanceTo {
            lastArrivalPollTime = advance
        }
        persistPollState()
    }

    // MARK: - Failure accounting (mirrors the gws maintenance-alert pattern)

    private var consecutiveFailures = 0
    private let failureAlertThreshold = 5
    private var lastFailureDetail: String?

    private func noteFetchOutcome(success: Bool, context: String) async {
        if success {
            consecutiveFailures = 0
            lastFailureDetail = nil
            await MaintenanceAlertCenter.shared.reportSuccess(.agentMail)
        } else {
            consecutiveFailures += 1
            if consecutiveFailures % failureAlertThreshold == 0 {
                var errorText = "\(context): all retries exhausted (\(consecutiveFailures) consecutive failed fetch passes)"
                if let detail = lastFailureDetail {
                    errorText += ". Underlying error: \(detail)"
                }
                await MaintenanceAlertCenter.shared.reportFailure(
                    .agentMail,
                    error: errorText,
                    deterministic: false
                )
            }
        }
    }

    // MARK: - Fetch (with retry)

    private func fetchUnreadSnapshotWithRetry() async -> [GoogleWorkspaceService.UnreadEmail]? {
        let generation = pollGeneration
        var delayNs: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            if let emails = await fetchUnreadSnapshotOnce() {
                // A wipe raced this snapshot — don't repopulate the unread
                // cache with pre-wipe mail (the caller re-fetches next time).
                guard generation == pollGeneration else { return nil }
                cachedUnread = emails
                await noteFetchOutcome(success: true, context: "fetchUnreadSnapshot")
                return emails
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }
        print("[AgentMailService] fetchUnreadSnapshot: all retries exhausted — continuing without email context")
        await noteFetchOutcome(success: false, context: "fetchUnreadSnapshot")
        return nil
    }

    private func fetchArrivedSinceWithRetry(since: Date, pollStartedAt: Date, generation: UInt64) async -> ArrivalFetchResult? {
        var delayNs: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            // A wipe/restart superseded this tick — stop retrying on its behalf.
            guard generation == pollGeneration else { return nil }
            if let result = await fetchArrivedSinceOnce(since: since, pollStartedAt: pollStartedAt, generation: generation) {
                await noteFetchOutcome(success: true, context: "fetchArrivedSince")
                return result
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }
        print("[AgentMailService] fetchArrivedSince: all retries exhausted — skipping this tick")
        await noteFetchOutcome(success: false, context: "fetchArrivedSince")
        return nil
    }

    // MARK: - Fetch (single attempt)

    private struct InboxesResponse: Decodable {
        struct Inbox: Decodable { let inboxId: String }
        let inboxes: [Inbox]
    }

    /// Wire shape of a message row (list endpoint). Field names arrive in
    /// snake_case; decoded via .convertFromSnakeCase.
    struct MessageRow: Decodable {
        let messageId: String
        let threadId: String?
        let from: String?
        let subject: String?
        let preview: String?
        let timestamp: String?
        let labels: [String]?
    }

    // Internal (not private) so the selftest can pin the next_page_token
    // decode — a silent field-name mismatch would disable pagination.
    struct MessagesResponse: Decodable {
        let messages: [MessageRow]
        let nextPageToken: String?
    }

    struct ArrivalFetchResult {
        let emails: [GoogleWorkspaceService.UnreadEmail]
        /// Where the watermark may advance to, or nil to hold (a drain is
        /// still in progress — progress is carried by the persisted page
        /// cursors; rewinding timestamps cannot make progress through >cap
        /// messages sharing one second). When a multi-tick drain completes,
        /// this is the pollStartedAt of the tick that STARTED it, not the
        /// completing tick: the cursor's coverage of mail that arrived
        /// during the drain is not guaranteed (a snapshot-style cursor
        /// would miss it), so that span must be re-queried by the next
        /// normal window (Codex round 5, 2026-08-22).
        let advanceTo: Date?
    }

    /// A backlog drain in progress for one inbox: the `after` bound the
    /// cursor was minted against (page tokens continue a specific query),
    /// the next page cursor itself, and the verified watermark the poll may
    /// advance to once this drain completes (the pollStartedAt of the tick
    /// that started the drain — everything after it gets re-queried).
    struct DrainState: Equatable, Codable {
        let afterISO: String
        var token: String
        let completionWatermark: Date
    }

    /// Per-inbox drain loop, extracted with an injected page fetcher so the
    /// selftest can drive a simulated >cap equal-timestamp backlog through
    /// multiple ticks and prove message N+1 is reached (no livelock).
    /// `fetchPage(afterISO, pageToken)` returns nil on failure.
    /// On completion, `completedWatermark` is where the poll may advance to
    /// for this inbox: the creating tick's pollStartedAt for a drain that
    /// spanned ticks, or the current tick's for a same-tick drain.
    /// Returns nil when a page fetch failed; a failure mid-drain also drops
    /// the drain state (page cursors are query-bound — safer to restart the
    /// window next tick and let id-dedupe suppress the repeats).
    static func drainInbox(
        existingDrain: DrainState?,
        sinceISO: String,
        pollStartedAt: Date,
        maxPages: Int,
        fetchPage: (String, String?) async -> (rows: [MessageRow], nextPageToken: String?)?
    ) async -> (rows: [MessageRow], drain: DrainState?, completedWatermark: Date?)? {
        // A drain in progress continues its ORIGINAL query bounds; a fresh
        // tick starts from the caller's window.
        let afterISO = existingDrain?.afterISO ?? sinceISO
        let completionWatermark = existingDrain?.completionWatermark ?? pollStartedAt
        var pageToken = existingDrain?.token
        var rows: [MessageRow] = []
        var pages = 0
        repeat {
            guard let page = await fetchPage(afterISO, pageToken) else { return nil }
            rows.append(contentsOf: page.rows)
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < maxPages
        if let pageToken {
            return (rows, DrainState(afterISO: afterISO, token: pageToken, completionWatermark: completionWatermark), nil)
        }
        return (rows, nil, completionWatermark)
    }

    private func fetchInboxIds() async -> [String]? {
        if let cachedInboxIds { return cachedInboxIds }
        guard let ids = await fetchInboxIdsOnce() else { return nil }
        cachedInboxIds = ids
        return ids
    }

    private func fetchInboxIdsOnce() async -> [String]? {
        guard let data = await request(path: "/inboxes", query: [URLQueryItem(name: "limit", value: "\(maxInboxes)")]) else { return nil }
        guard let decoded = try? Self.snakeDecoder().decode(InboxesResponse.self, from: data) else {
            lastFailureDetail = "undecodable /inboxes response"
            return nil
        }
        return decoded.inboxes.map { $0.inboxId }
    }

    private func fetchUnreadSnapshotOnce() async -> [GoogleWorkspaceService.UnreadEmail]? {
        guard let inboxes = await fetchInboxIds() else { return nil }
        var all: [(row: MessageRow, date: Date)] = []
        for inbox in inboxes {
            guard let page = await fetchMessagesPage(inbox: inbox, query: [
                URLQueryItem(name: "labels", value: "unread"),
                URLQueryItem(name: "limit", value: "\(maxUnread)"),
            ]) else { return nil }
            all.append(contentsOf: page.rows.map { ($0, Self.parseTimestamp($0.timestamp) ?? .distantPast) })
        }
        let newestFirst = all.sorted { $0.date > $1.date }.prefix(maxUnread)
        return newestFirst.map { Self.toUnreadEmail($0.row) }
    }

    /// Oldest-first paginated arrival fetch (`ascending=true`, `page_token`
    /// continuation — both verified live 2026-08-22). Bounded to
    /// `maxArrivalPages` pages per inbox per tick; when the cap cuts a
    /// backlog short, the page cursor persists in `drainStates` and the next
    /// tick CONTINUES from it instead of re-querying by timestamp — the only
    /// way to make progress through >cap messages sharing one second.
    private let maxArrivalPages = 10
    private let arrivalPageLimit = 50

    /// Per-inbox backlog cursors. Persisted together with the watermark
    /// (agentmail_poll_state.json) so a restart mid-drain continues the
    /// backlog instead of abandoning its tail; a stale file (>48h) is
    /// ignored in favor of the anti-flood seed.
    private var drainStates: [String: DrainState] = [:]

    // MARK: - Poll-state persistence

    struct PollState: Codable, Equatable {
        var watermark: Date
        var drains: [String: DrainState]
        var savedAt: Date
        /// `accountFingerprint` of the writer; nil in checkpoints written
        /// before accounts were stamped.
        var account: String? = nil
    }

    private static var pollStateURL: URL {
        StoragePaths.dataRoot.appendingPathComponent("agentmail_poll_state.json")
    }

    /// Restore gate, pure for the selftest: state older than 48h is stale —
    /// restoring it would replay days of backlog into the session, so the
    /// anti-flood seed (watermark = now) wins. A savedAt from the future
    /// (clock rollback) is also refused.
    static func shouldRestorePollState(savedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= -60 && age < 48 * 3600
    }

    /// Consecutive checkpoint-write failures; surfaced as a maintenance
    /// alert at the fetch-failure threshold instead of being suppressed —
    /// a silently unwritable checkpoint degrades restart durability.
    private var consecutivePersistFailures = 0

    private func persistPollState() {
        guard let watermark = lastArrivalPollTime else { return }
        let state = PollState(watermark: watermark, drains: drainStates, savedAt: Date(), account: pollAccount)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try PrivateStorage.writeAtomically(data, to: Self.pollStateURL)
            consecutivePersistFailures = 0
        } catch {
            consecutivePersistFailures += 1
            print("[AgentMailService] FAILED to persist poll state (\(consecutivePersistFailures)x): \(error) — restart durability degraded until this recovers")
            if consecutivePersistFailures % failureAlertThreshold == 0 {
                Task {
                    await MaintenanceAlertCenter.shared.reportFailure(
                        .agentMail,
                        error: "poll-state checkpoint cannot be written (\(consecutivePersistFailures) consecutive failures): \(error.localizedDescription). Restart durability is degraded — check disk space/permissions on the data directory.",
                        deterministic: false
                    )
                }
            }
        }
    }

    /// Returns whether a fresh checkpoint was actually restored, so the
    /// caller persists a new baseline ONLY when it wasn't (round 11).
    @discardableResult
    private func restorePollStateIfFresh() -> Bool {
        guard let data = try? Data(contentsOf: Self.pollStateURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var state = try? decoder.decode(PollState.self, from: data),
              Self.shouldRestorePollState(savedAt: state.savedAt, now: Date()),
              let account = pollAccount else { return false }
        if let owner = state.account {
            // Another account's checkpoint: never adopted (the caller then
            // persists a fresh baseline for this account over it).
            guard owner == account else {
                print("[AgentMailService] Ignored a poll checkpoint written for a different AgentMail account")
                return false
            }
        } else {
            guard legacyCheckpointAdoptable else {
                print("[AgentMailService] Ignored an unstamped poll checkpoint after an account change")
                return false
            }
            // A pre-stamp checkpoint belongs to the account configured when
            // it is first read after the upgrade: stamp it now, keeping its
            // original savedAt (re-dating it would defeat the 48h gate).
            state.account = account
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Unstamped and unwritable: don't adopt it (the anti-flood seed
            // wins), so it can never later pass to another account either.
            guard let stamped = try? encoder.encode(state),
                  (try? PrivateStorage.writeAtomically(stamped, to: Self.pollStateURL)) != nil else { return false }
        }
        lastArrivalPollTime = state.watermark
        drainStates = state.drains
        print("[AgentMailService] Restored poll state (watermark \(state.watermark), \(state.drains.count) drain cursor(s)) — downtime arrivals will be caught up")
        return true
    }

    private func fetchArrivedSinceOnce(since: Date, pollStartedAt: Date, generation: UInt64) async -> ArrivalFetchResult? {
        guard let inboxes = await fetchInboxIds() else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let after = iso.string(from: since)
        var all: [GoogleWorkspaceService.UnreadEmail] = []
        var advanceTo: Date? = pollStartedAt
        for inbox in inboxes {
            let existingDrain = drainStates[inbox]
            let outcome = await Self.drainInbox(
                existingDrain: existingDrain,
                sinceISO: after,
                pollStartedAt: pollStartedAt,
                maxPages: maxArrivalPages
            ) { [weak self] afterISO, pageToken in
                guard let self else { return nil }
                var query = [
                    URLQueryItem(name: "labels", value: "unread"),
                    URLQueryItem(name: "after", value: afterISO),
                    URLQueryItem(name: "ascending", value: "true"),
                    URLQueryItem(name: "limit", value: "\(self.arrivalPageLimit)"),
                ]
                if let pageToken {
                    query.append(URLQueryItem(name: "page_token", value: pageToken))
                }
                return await self.fetchMessagesPage(inbox: inbox, query: query)
            }
            // The pages suspended: a superseded tick must not touch the drain
            // cursors at all — writing here would resurrect pre-wipe cursor
            // state that resetForWipe() just cleared.
            guard generation == pollGeneration else { return nil }
            guard let outcome else {
                // Page fetch failed — drop any drain cursor (it is bound to
                // the failed query) and fail the tick; the watermark holds,
                // next tick restarts the window and dedupe eats the repeats.
                drainStates[inbox] = nil
                return nil
            }
            if let drain = outcome.drain {
                print("[AgentMailService] arrival backlog in \(inbox) exceeds \(maxArrivalPages * arrivalPageLimit) messages this tick — keeping the page cursor to continue next poll")
                drainStates[inbox] = drain
                advanceTo = nil
            } else {
                drainStates[inbox] = nil
                if let advance = advanceTo, let completed = outcome.completedWatermark {
                    advanceTo = min(advance, completed)
                }
            }
            all.append(contentsOf: outcome.rows.map { Self.toUnreadEmail($0) })
        }
        return ArrivalFetchResult(emails: all, advanceTo: advanceTo)
    }

    private func fetchMessagesPage(inbox: String, query: [URLQueryItem]) async -> (rows: [MessageRow], nextPageToken: String?)? {
        // Inbox ids are email addresses — percent-encode for the path segment.
        let encodedInbox = inbox.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? inbox
        guard let data = await request(path: "/inboxes/\(encodedInbox)/messages", query: query) else { return nil }
        guard let decoded = try? Self.snakeDecoder().decode(MessagesResponse.self, from: data) else {
            lastFailureDetail = "undecodable /messages response"
            return nil
        }
        return (decoded.messages, decoded.nextPageToken)
    }

    /// Authenticated GET with a 20s timeout. Non-200 or transport failure →
    /// nil, with the cause captured for maintenance alerts.
    private func request(path: String, query: [URLQueryItem]) async -> Data? {
        guard let key = Self.apiKey() else {
            lastFailureDetail = "no API key configured"
            return nil
        }
        var components = URLComponents(string: Self.apiBase + path)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            lastFailureDetail = "malformed request URL for \(path)"
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastFailureDetail = "no HTTP response for \(path)"
                return nil
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(140) ?? ""
                lastFailureDetail = "HTTP \(http.statusCode) for \(path)\(body.isEmpty ? "" : " — \(body)")"
                return nil
            }
            return data
        } catch {
            lastFailureDetail = "\(path): \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Mapping + formatting

    private static func snakeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func toUnreadEmail(_ row: MessageRow) -> GoogleWorkspaceService.UnreadEmail {
        let dateDisplay: String
        if let date = parseTimestamp(row.timestamp) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            dateDisplay = formatter.string(from: date)
        } else {
            dateDisplay = row.timestamp ?? ""
        }
        return GoogleWorkspaceService.UnreadEmail(
            id: row.messageId,
            threadId: row.threadId,
            from: row.from ?? "(unknown sender)",
            subject: row.subject ?? "(no subject)",
            date: dateDisplay,
            snippet: (row.preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Same block shape as the gws formatter so the frozen-context cache and
    /// prompt layout are provider-independent; only the follow-up hint differs.
    static func formatUnreadEmails(_ emails: [GoogleWorkspaceService.UnreadEmail]) -> String {
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
        lines.append(EmailCalendarProvider.agentmail.emailFollowUpHint)
        return lines.joined(separator: "\n")
    }

    // MARK: - Key probe + inbox discovery (wizard/doctor, static)

    /// Validates an API key against /v0/inboxes. Returns nil on success or a
    /// human-readable failure. On success also reports the discovered inbox
    /// addresses through `inboxes`.
    static func probeKey(_ key: String) async -> (failure: String?, inboxes: [String]) {
        guard let url = URL(string: apiBase + "/inboxes?limit=5") else {
            return ("internal error: malformed probe URL", [])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return ("no HTTP response", []) }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(140) ?? ""
                return ("AgentMail returned HTTP \(http.statusCode)\(body.isEmpty ? "" : " — \(body)")", [])
            }
            guard let decoded = try? snakeDecoder().decode(InboxesResponse.self, from: data) else {
                return ("unexpected /inboxes response shape", [])
            }
            let ids = decoded.inboxes.map { $0.inboxId }
            guard !ids.isEmpty else {
                return ("key is valid but has no inboxes — create one at agentmail.to first", [])
            }
            return (nil, ids)
        } catch {
            return ("AgentMail unreachable: \(error.localizedDescription)", [])
        }
    }
}

// MARK: - Native CLI binary install (model-facing bash surface)

extension AgentMailService {
    /// Content check for the broker wrapper, parameterized so the selftest
    /// can exercise it against temp files.
    static func isBrokerWrapper(at url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let data = try? Data(contentsOf: url),
              data.count < 4096,
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.hasPrefix("#!/bin/sh") && text.contains("__agentmail-key")
    }

    /// Foreign `agentmail` executables on the standard prefix dirs. These
    /// have no access to Briglia's key and — depending on the user's PATH — can
    /// shadow Briglia's wrapper; surfaced as a warning by setup and doctor.
    static func foreignAgentMailInstalls() -> [String] {
        ["/opt/homebrew/bin/agentmail", "/usr/local/bin/agentmail", "/usr/bin/agentmail"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The broker wrapper installed as `agentmail`. Pure so the selftest can
    /// pin its shape. Respects a caller-provided AGENTMAIL_API_KEY (a user
    /// testing another account), falls back to Briglia's stored key, and execs
    /// the real binary so no extra process lingers.
    static func wrapperScript(adaPath: String, realBinaryPath: String) -> String {
        """
        #!/bin/sh
        # Installed by Briglia CLI. Launches the AgentMail CLI with Briglia's stored
        # API key fetched at exec time, so the key never rides ambiently in
        # other processes' environments.
        if [ -z "${AGENTMAIL_API_KEY:-}" ]; then
            AGENTMAIL_API_KEY="$('\(adaPath)' __agentmail-key 2>/dev/null || true)"
            export AGENTMAIL_API_KEY
        fi
        exec '\(realBinaryPath)' "$@"
        """
    }
}
